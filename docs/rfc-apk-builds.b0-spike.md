# B0 spike findings — apk v3 ADB index signing

- **Status:** complete. Resolves RFC §3 "Open item (B0)" and O2; unblocks B2/B3.
- **Method:** read the OpenWrt/Alpine `apk-tools` **v3.0.2** source (the version
  OpenWrt 25.12.0 ships — confirmed by `apk --version` inside the real
  `openwrt-25.12.0-x86-64-rootfs.tar.gz`), cross-checked against a real signed
  `packages.adb` from `downloads.openwrt.org/releases/25.12.0/.../packages/` and
  an OpenSSL EVP round-trip. Source files: `src/crypto_openssl.c`, `src/adb.c`,
  `src/adb.h`, `src/apk_crypto.h`.

## The three exit-criteria answers

### (a) Spliceable placeholder vs. re-invoke apk-tools — *neither; it is an appended block, and signing is cleanly separable*

`apk` does **not** reserve a fixed-offset placeholder that a raw signature drops
into, and it does **not** require re-running index generation to sign. The signed
index is `ADB_BLOCK_ADB` (the data) followed by one **appended** `ADB_BLOCK_SIG`
block per key (`adb.c:1348`, `adb_trust_write_signatures`). A standalone
**`adbsign` applet** (`src/app_adbsign.c`) exists precisely to sign an
already-built `.adb` — so index *build* and index *sign* are two separable steps.

**Consequence for imprimatur:** it can hold the EC key and produce the signature
**without any apk-tools dependency** (avoiding the buggy `.adb` C parser inside the
key-holding process — the §4.2a hazard). See "Recommended split" below.

### (b) Exact signed byte range

`adb_digest_v0_signature` (`adb.c:1301`) feeds the EVP context, in order:

| Field | Bytes | Value |
|---|---|---|
| `schema` | 4 | `htole32(db->schema)` — the index schema id, little-endian |
| `adb_sign_v0.hdr.sign_ver` | 1 | `0x00` |
| `adb_sign_v0.hdr.hash_alg` | 1 | `0x04` (`APK_DIGEST_SHA512`) |
| `adb_sign_v0.id` | 16 | key id = `SHA512(i2d_PublicKey(pubkey))[:16]` (`crypto_openssl.c:167`) |
| `md` | 64 | `SHA512(ADB_BLOCK_ADB payload)` — the **decompressed** data block, not the file, not the compressed on-disk bytes (`adb.c:1331`, `adb_digest_adb`) |

Total pre-image = **86 bytes**. It is signed with `EVP_DigestSign(sha512, …)`
(`apk_sign_start` pins `APK_DIGEST_SHA512`), i.e. the ECDSA signs `SHA512(the 86
bytes)`. `adb_sign_v0.sig` is a C flexible array (`uint8_t sig[0]`, `adb.h:117`),
so the 86-byte pre-image excludes the signature itself — no circularity.

### (c) Signature encoding apk's verifier consumes — *ASN.1 DER (variable length)*

Both sign and verify go through OpenSSL EVP with **no manual r/s handling**
(`crypto_openssl.c:220-241`): `EVP_DigestSignFinal` / `EVP_DigestVerifyFinal`.
For an EC key that is OpenSSL's default `ECDSA-Sig-Value` = **`SEQUENCE { INTEGER
r, INTEGER s }` in DER**, *not* fixed-width raw `r‖s`.

Empirically confirmed (same EVP path, prime256v1):

```
$ openssl dgst -sha512 -sign ec.pem -out sig.der preimage86.bin
$ stat -c %s sig.der            # 72  (P-256 DER is ~70–72 B, variable)
$ xxd -p -l1 sig.der            # 30  -> ASN.1 SEQUENCE
$ openssl asn1parse -inform DER -in sig.der
  0:d=0 hl=2 l=70 cons: SEQUENCE
  2:d=1 hl=2 l=33 prim:  INTEGER   (r)
 37:d=1 hl=2 l=33 prim:  INTEGER   (s)
$ openssl dgst -sha512 -verify ecpub.pem -signature sig.der preimage86.bin  # Verified OK
```

**The raw-`r‖s` silent-verify-failure risk is averted by construction** iff
imprimatur produces the signature via `EVP_DigestSign` (as RFC §4.2b mandates for
`EcP256Algo`). It would only bite if someone hand-serialized r‖s to 64 fixed
bytes. `ADB_MAX_SIGNATURE_LEN = 2048` (`adb.h:101`), so variable DER length is a
non-issue for the block. **B2's unit test must assert the emitted signature is DER
(0x30 prefix, `asn1parse` yields two INTEGERs), not merely openssl
self-consistency** — and ideally assert a real `apk verify` accepts an index we
signed.

## Collision check (folds in §4.1)

OpenWrt 25.12's `packages` feed **does** ship `tailscale`:
`downloads.openwrt.org/releases/25.12.0/packages/x86_64/packages/tailscale-1.98.3-r1.apk`.
So a device with both the official feed and ours has **two `tailscale`
providers** — the §4.1 collision is real. Resolution stands: **documented
repo-priority pinning** (our feed's package chosen explicitly), not a
`provider-priority` grab that would hijack the official package. Note the official
build (`1.98.3-r1`) lacks this repo's netifd/GL integration payload — that is the
reason our package exists — and we track latest upstream, so our version is
usually higher; but version-ordering is not a guarantee, so pinning is the
deterministic answer. B0 confirms the collision empirically as the RFC required.

## Recommended imprimatur split (refines §4.2a)

Signing decomposes into: (1) locate + `SHA512` the `ADB_BLOCK_ADB` payload → `md`;
(2) build the 18-byte `adb_sign_v0` header from the pubkey's id; (3)
`EVP_DigestSign(sha512)` over `schema‖header‖md` → DER; (4) append the
`ADB_BLOCK_SIG` block. Only step 3 needs the private key. Three ways to place the
boundary:

- **Design 1 — imprimatur signs opaque bytes (recommended).** CI does steps 1, 2,
  4; imprimatur's `/sign/ec` is a pure `EVP_DigestSign(sha512, ec_key, <bytes>) →
  DER` over the 86-byte pre-image — **zero apk knowledge, identical trust boundary
  to today's usign `/sign`** (sign these bytes, never parse them). CI holds the
  public key already (committed to the repo), so it can compute the key id and
  frame the pre-image itself. **Loud-failure guard:** CI reassembles the signed
  index and runs a real `apk verify` / trusted `apk add` in the pinned 25.12
  container **before publish** (C2/C3 already do this), so a CI-side framing bug
  fails the run, not a device.
  - *One CI-side detail deferred to C2 (does not touch the key boundary):*
    extracting `md = SHA512(db->adb)` from the unsigned index. The on-disk ADB data
    block appears compressed (real index: 15,835 B file vs. 28,936 B `adbdump`
    size), so CI either uses its apk-tools build to emit the block digest or does a
    small block-framing parse + decompress. This lives in CI (has apk-tools, no
    key), so it is a C2 concern, not a trust-boundary one.
- **Design 3 — imprimatur parses ADB blocks itself (fallback if Design 1's CI
  extraction proves impractical).** imprimatur receives the whole unsigned `.adb`,
  does a minimal block-framing parse (find `ADB_BLOCK_ADB`, decompress, SHA512),
  signs, appends the SIG block. ~60 lines of Nim, still **apk-tools-free**, but
  couples imprimatur to the ADB on-disk format.
- **Design 2 — vendor OpenWrt `adbsign` into imprimatur (last resort, = RFC's
  B3a).** Simplest to write, but pulls apk-tools' `.adb` C parser into the
  key-holding process — the exact §4.2a hazard. Only if both above fail.

**Recommendation: Design 1**, Design 3 as fallback, Design 2 last. Either of the
first two keeps imprimatur apk-tools-free, so B3a (vendoring apk-tools) is **not**
expected to be needed. This is a confident recommendation (not a fork).

## Command / constant surface (for B2/B3/C2)

- Digest: **SHA-512** everywhere (`hash_alg = 0x04`).
- Signature: EC `prime256v1`, **DER** ECDSA-Sig-Value, via `EVP_DigestSign`.
- Key id in SIG block: `SHA512(i2d_PublicKey(pubkey))[:16]` (16 bytes).
- Pre-image: `LE32(schema) ‖ {0x00, 0x04, id[16]} ‖ SHA512(ADB_BLOCK_ADB)` (86 B).
- Block framing: `adb_block.type_size = htole32((1<<30) + 4 + payload_len)` for
  `ADB_BLOCK_SIG`; payload = `adb_sign_v0` (18 B) + DER sig; pad to 8-byte
  alignment (`ADB_BLOCK_ALIGNMENT = 8`).
- apk-tools pin: **v3.0.2** (OpenWrt 25.12.0 x86-64). Pin this across build /
  verify / (fallback) imprimatur per §5.
