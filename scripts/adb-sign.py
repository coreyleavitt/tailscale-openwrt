#!/usr/bin/env python3
"""adb-sign.py -- CI-side ADB index signing framing (RFC docs/rfc-apk-builds.md
Design 1, slice C2; exact byte layout from docs/rfc-apk-builds.b0-spike.md).

apk v3's `packages.adb` signed-index format (apk-tools 3.0.2 source,
src/adb.h + src/adb.c, cross-checked empirically against a real
`apk mkndx --compression none` output -- see the C2 handoff notes):

    file := magic(4="ADB.") schema(4, LE32) block+

    block := type_size(4, LE32) payload(rawsize-4) padding(to 8-byte align)
      where type_size = (block_type << 30) | (4 + len(payload))
            block_type 0 = ADB_BLOCK_ADB   (the index data; payload = db->adb)
            block_type 1 = ADB_BLOCK_SIG   (one per signing key, appended)

This module ONLY understands the **uncompressed** on-disk form ("ADB."
magic) -- our own `apk mkndx --compression none` invocation guarantees that,
sidestepping the compressed ADB_BLOCK_ADB-payload-extraction problem the RFC
flagged as a C2 detail to resolve (§4.2a). A compressed input (magic
"ADBd"/"ADBc") is a hard error here, not a silent mis-parse.

Two subcommands, matching the two places a private key is NOT needed (the
imprimatur round-trip sits between them):

  preimage <unsigned.adb> <pubkey.pem> <preimage.bin>
      Extracts the ADB_BLOCK_ADB payload, computes the 86-byte pre-image
      (LE32(schema) || {sign_ver=0x00, hash_alg=0x04(SHA512), id[16]} ||
      SHA512(payload)) per the B0 spike, and writes it to <preimage.bin>.
      `id` = SHA512(i2d_PublicKey(pubkey))[:16], derived independently from
      the PUBLIC key file (never trusts imprimatur's self-reported
      fingerprint) -- this is CI's own half of the Design-1 trust boundary:
      CI already holds the committed pubkey, so it computes the key id
      itself (RFC §4.2a: "CI holds the public key already ... so it can
      compute the key id and frame the pre-image itself").

  assemble <unsigned.adb> <pubkey.pem> <sig.der> <signed.adb>
      Re-derives the same id, builds the 18-byte adb_sign_v0 header+id,
      appends an ADB_BLOCK_SIG block (header || id || DER sig, padded to 8
      bytes) to the unsigned index, and writes the result to <signed.adb>.

Both subcommands re-derive `id` from the pubkey file independently (no
caching between calls) so a mismatched pubkey argument between the two
invocations fails loudly rather than silently reusing a stale id.

  key-id <pubkey.pem>
      Prints the derived id as lowercase hex (32 chars) to stdout. A thin
      wrapper around the same key_id() used internally -- exists so a
      caller (e.g. tests/apk/sign-verify.sh) can cross-check CI's own
      independently-derived id against imprimatur's self-reported
      /health fingerprint without reaching into this module's internals.

  verify <signed.adb> <pubkey.pem>
      RFC §4.6 slice C5 -- the synthetic post-publish feed probe
      (scripts/probe-feed.sh) needs to confirm a SERVED index still
      cryptographically verifies against the pinned public key, without
      spinning up a full apk-tools container (that is C2/C3's heavier,
      install-time proof; this is a cheap, frequent, standalone check for
      "has the static feed silently rotted between releases"). Walks the
      ADB block list (not just block 0, unlike preimage/assemble above) to
      find the ADB_BLOCK_SIG block, re-derives the same 86-byte pre-image
      independently from the ADB_BLOCK_ADB payload, and verifies the
      embedded DER signature against it via `openssl dgst -verify` -- the
      exact EVP_DigestVerify(sha512) path apk itself uses (B0 spike). Exits
      0 and prints VALID on a good signature; exits 1 and prints a reason
      (NO_SIG_BLOCK / KEY_ID_MISMATCH / INVALID) on anything cryptographically
      wrong; exits 2 on a malformed/unparseable sig block (distinct from "the
      signature is wrong" -- a framing bug, not a trust failure).
"""
import hashlib
import re
import subprocess
import struct
import sys
import tempfile

ADB_MAGIC_NONE = b"ADB."
ADB_BLOCK_ADB = 0
ADB_BLOCK_SIG = 1
ADB_BLOCK_ALIGNMENT = 8
SIGN_VER = 0x00
HASH_ALG_SHA512 = 0x04


def round_up(n, align):
    return (n + align - 1) // align * align


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def pubkey_point_bytes(pubkey_pem_path):
    """The raw i2d_PublicKey(EC point) bytes -- 0x04 || X || Y for the
    default uncompressed point-conversion form apk-tools/OpenSSL use.
    Extracted via `openssl ec -pubin -text -noout`'s "pub:" hex dump, which
    is empirically identical to i2d_PublicKey's output (verified against a
    dedicated libcrypto i2d_PublicKey C call during this slice's spike --
    both a tiny C EVP_PKEY program and Python's `cryptography` X962
    UncompressedPoint encoding produced byte-identical output). This keeps
    the framing script dependency-free (openssl CLI only, no compiled
    helper, no non-stdlib Python package)."""
    out = subprocess.run(
        ["openssl", "ec", "-pubin", "-in", pubkey_pem_path, "-text", "-noout"],
        check=True, capture_output=True, text=True,
    ).stdout
    m = re.search(r"pub:\s*\n((?:\s+[0-9a-f:]+\n)+)", out)
    if not m:
        raise SystemExit(f"adb-sign.py: could not find 'pub:' point dump in openssl output:\n{out}")
    hexdigits = re.sub(r"[^0-9a-f]", "", m.group(1))
    return bytes.fromhex(hexdigits)


def key_id(pubkey_pem_path):
    """apk's key id = SHA512(i2d_PublicKey(pubkey))[:16] (crypto_openssl.c
    apk_pkey_init, matched by imprimatur's EcP256Algo.fingerprint())."""
    point = pubkey_point_bytes(pubkey_pem_path)
    return hashlib.sha512(point).digest()[:16]


class AdbBlock:
    def __init__(self, block_type, payload, header_end, block_end):
        self.block_type = block_type
        self.payload = payload
        self.header_end = header_end   # offset just past this block's header+payload+padding start marker (unused externally)
        self.block_end = block_end     # offset of the next block (start of trailing padding-adjusted position)


def iter_blocks(data):
    """Yields (block_type, payload_bytes) for every block in file order,
    starting past the 8-byte file header, honoring each block's 8-byte
    alignment padding (the same layout cmd_assemble writes). Shared by
    parse_unsigned_adb (block 0 only, the preimage/assemble entry points)
    and find_sig_block (walks past block 0 to find the appended
    ADB_BLOCK_SIG, added by C5's `verify` subcommand -- preimage/assemble
    never needed to look past block 0 since a freshly-mkndx'd unsigned index
    has exactly one block)."""
    pos = 8
    while pos + 4 <= len(data):
        type_size = struct.unpack_from("<I", data, pos)[0]
        block_type = type_size >> 30
        if block_type == 3:
            raise SystemExit("adb-sign.py: unexpected ADB_BLOCK_EXT (unsupported)")
        rawsize = type_size & 0x3FFFFFFF
        hdrsize = 4
        payload_len = rawsize - hdrsize
        payload_start = pos + hdrsize
        payload_end = payload_start + payload_len
        if payload_len < 0 or payload_end > len(data):
            raise SystemExit("adb-sign.py: block runs past end of file (truncated?)")
        yield block_type, data[payload_start:payload_end]
        padded = round_up(rawsize, ADB_BLOCK_ALIGNMENT)
        if padded <= 0:
            raise SystemExit("adb-sign.py: non-advancing block size (corrupt file)")
        pos += padded


def parse_unsigned_adb(data):
    """Returns (schema_bytes[4], adb_block_payload[bytes]). Hard-fails if the
    file isn't the uncompressed 'ADB.' form, or the first block isn't
    ADB_BLOCK_ADB (mkndx always emits exactly that as block 0)."""
    if len(data) < 8 or data[0:4] != ADB_MAGIC_NONE:
        got = data[0:4]
        raise SystemExit(
            f"adb-sign.py: expected uncompressed 'ADB.' magic, got {got!r} "
            "-- was this built without --compression none?"
        )
    schema_bytes = data[4:8]

    try:
        block_type, payload = next(iter_blocks(data))
    except StopIteration:
        raise SystemExit("adb-sign.py: truncated file, no block header after file header")
    if block_type != ADB_BLOCK_ADB:
        raise SystemExit(f"adb-sign.py: expected ADB_BLOCK_ADB (0) as the first block, got type {block_type}")
    return schema_bytes, payload


def find_sig_block(data):
    """Returns the raw payload of the first ADB_BLOCK_SIG block found (the
    18-byte adb_sign_v0 header+id, followed by the DER signature -- exactly
    what cmd_assemble appended), or None if the file has no signature block
    at all (an unsigned index, or a NO_SIG_BLOCK verify failure)."""
    for block_type, payload in iter_blocks(data):
        if block_type == ADB_BLOCK_SIG:
            return payload
    return None


def build_preimage(schema_bytes, id_bytes, md):
    assert len(schema_bytes) == 4
    assert len(id_bytes) == 16
    assert len(md) == 64
    hdr = bytes([SIGN_VER, HASH_ALG_SHA512]) + id_bytes
    preimage = schema_bytes + hdr + md
    assert len(preimage) == 86, f"pre-image must be 86 bytes, got {len(preimage)}"
    return preimage


def cmd_preimage(args):
    unsigned_path, pubkey_path, out_path = args
    data = read_file(unsigned_path)
    schema_bytes, payload = parse_unsigned_adb(data)
    md = hashlib.sha512(payload).digest()
    id_bytes = key_id(pubkey_path)
    preimage = build_preimage(schema_bytes, id_bytes, md)
    with open(out_path, "wb") as f:
        f.write(preimage)
    sys.stderr.write(
        f"adb-sign.py preimage: schema={schema_bytes.hex()} id={id_bytes.hex()} "
        f"md={md.hex()} payload_len={len(payload)} -> {out_path} (86 bytes)\n"
    )


def cmd_assemble(args):
    unsigned_path, pubkey_path, sig_der_path, out_path = args
    data = read_file(unsigned_path)
    # Re-validates the unsigned index shape (and gets us the payload for a
    # sanity re-hash) even though assemble doesn't need `md` itself -- catches
    # a mismatched/corrupt unsigned index input early and loudly.
    parse_unsigned_adb(data)
    id_bytes = key_id(pubkey_path)
    sig_der = read_file(sig_der_path)

    hdr = bytes([SIGN_VER, HASH_ALG_SHA512]) + id_bytes   # adb_sign_v0{hdr, id} = 18 bytes
    sig_payload = hdr + sig_der

    rawsize = 4 + len(sig_payload)   # 4 = this block's own type_size field (non-ext hdrsize)
    type_size = ((ADB_BLOCK_SIG << 30) + rawsize) & 0xFFFFFFFF
    block_bytes = struct.pack("<I", type_size) + sig_payload
    padded_size = round_up(rawsize, ADB_BLOCK_ALIGNMENT)
    block_bytes += b"\x00" * (padded_size - rawsize)

    with open(out_path, "wb") as f:
        f.write(data + block_bytes)

    sys.stderr.write(
        f"adb-sign.py assemble: id={id_bytes.hex()} siglen={len(sig_der)} "
        f"sig_block_bytes={len(block_bytes)} -> {out_path} "
        f"({len(data)} + {len(block_bytes)} = {len(data) + len(block_bytes)})\n"
    )


def cmd_key_id(args):
    (pubkey_path,) = args
    print(key_id(pubkey_path).hex())


def cmd_verify(args):
    signed_path, pubkey_path = args
    data = read_file(signed_path)
    schema_bytes, payload = parse_unsigned_adb(data)
    md = hashlib.sha512(payload).digest()
    expected_id = key_id(pubkey_path)

    sig_payload = find_sig_block(data)
    if sig_payload is None:
        print("NO_SIG_BLOCK: index has no ADB_BLOCK_SIG (unsigned)", file=sys.stderr)
        sys.exit(1)
    if len(sig_payload) < 18:
        print(f"MALFORMED_SIG_BLOCK: payload only {len(sig_payload)} bytes, need >=18", file=sys.stderr)
        sys.exit(2)

    sign_ver, hash_alg = sig_payload[0], sig_payload[1]
    got_id = sig_payload[2:18]
    sig_der = sig_payload[18:]
    if sign_ver != SIGN_VER or hash_alg != HASH_ALG_SHA512:
        print(f"MALFORMED_SIG_BLOCK: unsupported sign_ver={sign_ver} hash_alg={hash_alg}", file=sys.stderr)
        sys.exit(2)
    if not sig_der:
        print("MALFORMED_SIG_BLOCK: empty DER signature", file=sys.stderr)
        sys.exit(2)
    if got_id != expected_id:
        print(
            f"KEY_ID_MISMATCH: signature id={got_id.hex()} does not match the "
            f"supplied pubkey's id={expected_id.hex()} -- signed with a different key",
            file=sys.stderr,
        )
        sys.exit(1)

    preimage = build_preimage(schema_bytes, expected_id, md)
    with tempfile.NamedTemporaryFile(suffix=".preimage") as pf, \
         tempfile.NamedTemporaryFile(suffix=".sig") as sf:
        pf.write(preimage)
        pf.flush()
        sf.write(sig_der)
        sf.flush()
        result = subprocess.run(
            ["openssl", "dgst", "-sha512", "-verify", pubkey_path, "-signature", sf.name, pf.name],
            capture_output=True, text=True,
        )

    if result.returncode == 0 and "Verified OK" in result.stdout:
        print("VALID")
        sys.exit(0)
    print(
        f"INVALID: signature does not verify against {pubkey_path} "
        f"(openssl: {result.stdout.strip()!r} {result.stderr.strip()!r})",
        file=sys.stderr,
    )
    sys.exit(1)


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd, rest = sys.argv[1], sys.argv[2:]
    if cmd == "preimage":
        if len(rest) != 3:
            raise SystemExit("usage: adb-sign.py preimage <unsigned.adb> <pubkey.pem> <preimage.bin>")
        cmd_preimage(rest)
    elif cmd == "assemble":
        if len(rest) != 4:
            raise SystemExit("usage: adb-sign.py assemble <unsigned.adb> <pubkey.pem> <sig.der> <signed.adb>")
        cmd_assemble(rest)
    elif cmd == "key-id":
        if len(rest) != 1:
            raise SystemExit("usage: adb-sign.py key-id <pubkey.pem>")
        cmd_key_id(rest)
    elif cmd == "verify":
        if len(rest) != 2:
            raise SystemExit("usage: adb-sign.py verify <signed.adb> <pubkey.pem>")
        cmd_verify(rest)
    else:
        raise SystemExit(f"unknown subcommand: {cmd}\n\n{__doc__}")


if __name__ == "__main__":
    main()
