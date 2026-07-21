#!/bin/sh
# tests/apk/sign-verify.sh
#
# Slice C2 test -- the crux hermetic signing slice (RFC docs/rfc-apk-builds.md
# §4.2a Design 1, §4.3, §5 "Hermetic C2", §6 slice C2; exact byte layout from
# docs/rfc-apk-builds.b0-spike.md). Proves the WHOLE signing design end to
# end: an unsigned apk index gets signed by a CI-local imprimatur instance
# (ephemeral EC test key, never sign.leavitt.info) via the opaque-bytes
# `/sign/ec` contract, CI assembles the ADB_BLOCK_SIG framing itself, and a
# real `apk add tailscale` -- NO --allow-untrusted -- succeeds against the
# result in the pinned OpenWrt 25.12 aarch64 rootfs container.
#
# Pipeline (Design 1 -- imprimatur signs opaque bytes, CI does the ADB
# framing; see scripts/adb-sign.py for the byte-layout implementation):
#   1. `apk mkndx --compression none` over the real aarch64 tailscale.apk
#      PLUS three offline stub deps (kmod-tun/ip-full/conntrack, reusing the
#      A4/A5b stub-repo trick) -> ONE combined unsigned packages.adb.
#      --compression none sidesteps the compressed-ADB_BLOCK_ADB-payload
#      problem the RFC flagged as a C2-only detail (§4.2a) -- `apk verify`/
#      `apk add` accept the uncompressed "ADB." on-disk form exactly the same
#      as the compressed default (empirically confirmed this slice).
#      Everything goes in ONE index because `apk add` has no per-repository
#      trust flag -- if the stub deps' repo were unsigned, the whole
#      transaction would need --allow-untrusted regardless of tailscale's own
#      signature, defeating the test.
#   2. Ephemeral `openssl ecparam -genkey -name prime256v1` key -- generated
#      fresh in a scratch dir, mounted read-only into a CI-local imprimatur
#      container (built from the LOCAL working tree at
#      $IMPRIMATUR_REPO_DIR -- its B1-B3 EC code is uncommitted, so this
#      MUST NOT clone a pinned SHA; see the workflow wiring for the
#      committed-repo path's placeholder). Never written to this repo.
#   3. scripts/adb-sign.py preimage: extracts the ADB_BLOCK_ADB payload from
#      the unsigned index, computes the 86-byte pre-image (LE32(schema) ||
#      {sign_ver=0x00, hash_alg=0x04} || id[16] || SHA512(payload)), deriving
#      `id` independently from the ephemeral PUBLIC key (never trusting
#      imprimatur's self-reported fingerprint -- this is CI's own half of the
#      Design-1 trust boundary).
#   4. POST base64(pre-image) to the CI-local imprimatur's POST /sign/ec ->
#      DER signature.
#   5. scripts/adb-sign.py assemble: appends the ADB_BLOCK_SIG block (18-byte
#      adb_sign_v0 header+id || DER sig, padded to 8 bytes) -> signed
#      packages.adb.
#   6. Trust proof, in the pinned aarch64 rootfs container: drop the
#      (public-only) .pem in /etc/apk/keys/, reference the signed index via
#      `-X packages.adb` (A4's proven "additional repository" mechanism), and
#      assert a plain `apk add tailscale` -- NO --allow-untrusted -- succeeds
#      and installs the real arch-native binary.
#
# RED -> GREEN, with the required negative (task discipline: "demonstrate
# the negative"):
#   (a) the SAME command against the UNSIGNED combined index must FAIL
#       (untrusted) -- proves the positive assertion isn't vacuous.
#   (b) the SAME command against a signed index with a deliberately
#       corrupted signature byte must also FAIL -- proves apk is doing real
#       cryptographic verification, not just "a SIG block is present".
#   (c) only the correctly assembled signed index succeeds.
#
# Uses the shared tests/apk/lib.sh harness + the A4/A5b binfmt/exec-retry
# machinery (register_standard_qemu_binfmt / register_openwrt_mips_binfmt).
# Scope: aarch64 only (RFC §5's hermetic-C2 note; C1b/A5b already prove all
# four arches build/install -- C2 is about proving the SIGNING design once,
# not re-proving cross-arch packaging).
#
# Never commits/pushes anything. The ephemeral private key lives only in a
# mktemp scratch dir, destroyed on exit (trap), and is never written into
# this repo or into the imprimatur repo's working tree.
#
# Usage:
#   sh tests/apk/sign-verify.sh
#
# Env overrides:
#   IMPRIMATUR_REPO_DIR  -- path to the imprimatur working tree to build the
#                           CI-local signing image from (default: this
#                           machine's local clone). MUST be a working tree
#                           with the B1-B3 EC code (uncommitted upstream at
#                           time of writing) -- a pinned-SHA clone does not
#                           have it yet (see the workflow's TODO).
#   SIGN_VERIFY_TEST_VERSION / SIGN_VERIFY_TEST_PKG_RELEASE -- tailscale
#                           version to build (defaults match install.sh).

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_DIR="${REPO_ROOT}/tailscale-package"
ARCHES_JSON="${REPO_ROOT}/arches.json"
ADB_SIGN_PY="${REPO_ROOT}/scripts/adb-sign.py"
CACHE_DIR="${ROOTFS_CACHE_DIR:-${SCRIPT_DIR}/.cache}"

IMPRIMATUR_REPO_DIR="${IMPRIMATUR_REPO_DIR:-/home/corey/homelab/stacks/infra/imprimatur/repo}"
ARCH="aarch64_cortex-a53"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker
require_cmd jq
require_cmd openssl
require_cmd curl
require_cmd python3
require_cmd base64

TEST_VERSION="${SIGN_VERIFY_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${SIGN_VERIFY_TEST_PKG_RELEASE:-1}"
EXPECT_VERSION="${TEST_VERSION}-r${TEST_PKG_RELEASE}"

if [ ! -f "${PKG_DIR}/Dockerfile" ]; then
    echo "FAIL: ${PKG_DIR}/Dockerfile not found" >&2
    exit 1
fi
if [ ! -d "${IMPRIMATUR_REPO_DIR}" ]; then
    echo "FAIL: IMPRIMATUR_REPO_DIR (${IMPRIMATUR_REPO_DIR}) not found -- this slice" >&2
    echo "      builds the LOCAL imprimatur working tree (its B1-B3 EC code is" >&2
    echo "      uncommitted upstream), not a clone. Set IMPRIMATUR_REPO_DIR." >&2
    exit 1
fi
if [ ! -f "${IMPRIMATUR_REPO_DIR}/src/ec_algo.nim" ]; then
    echo "FAIL: ${IMPRIMATUR_REPO_DIR}/src/ec_algo.nim not found -- IMPRIMATUR_REPO_DIR" >&2
    echo "      does not have the B2 EC signer code" >&2
    exit 1
fi

mkdir -p "${CACHE_DIR}"

WORKDIR=$(mktemp -d)
CLEANUP_CIDS=""
IMPRIMATUR_CID=""

cleanup() {
    for c in ${CLEANUP_CIDS}; do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
    if [ -n "${IMPRIMATUR_CID}" ]; then
        docker rm -f "${IMPRIMATUR_CID}" >/dev/null 2>&1 || true
    fi
    # Ephemeral private key never outlives this run.
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

track() { CLEANUP_CIDS="${CLEANUP_CIDS} $1"; }
untrack_and_remove() {
    docker rm -f "$1" >/dev/null 2>&1 || true
    CLEANUP_CIDS=$(echo "${CLEANUP_CIDS}" | sed "s/$1//")
}

BINFMT_DONE=0
ensure_binfmt() {
    if [ "${BINFMT_DONE}" -eq 1 ]; then return 0; fi
    BINFMT_DONE=1
    echo "Registering qemu-user binfmt emulators..." >&2
    register_standard_qemu_binfmt || echo "WARN: standard binfmt registration failed (continuing)" >&2
    register_openwrt_mips_binfmt || echo "WARN: OpenWrt mips binfmt registration failed (continuing)" >&2
}

exec_in_container() {
    _cid="$1"; shift
    _out=$(docker exec "${_cid}" "$@" 2>&1) && { printf '%s' "${_out}"; return 0; }
    case "${_out}" in
        *"exec format error"*)
            ensure_binfmt
            _out=$(docker exec "${_cid}" "$@" 2>&1) && { printf '%s' "${_out}"; return 0; }
            ;;
    esac
    printf '%s' "${_out}"
    return 1
}

# --- 1. resolve arch pins from arches.json -------------------------------
URL=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .rootfs_url' "${ARCHES_JSON}")
PIN=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .rootfs_sha256' "${ARCHES_JSON}")

ROOTFS_IMAGE_TAG="owrt2512-rootfs:${ARCH}"
BUILD_IMAGE_TAG="tailscale-apk-signverify-build:${ARCH}"

DEST="${CACHE_DIR}/$(basename "${URL}")"
if [ ! -f "${DEST}" ] || [ "$(sha256sum "${DEST}" | awk '{print $1}')" != "${PIN}" ]; then
    echo "Downloading ${URL}"
    curl -fsSL -o "${DEST}.part" "${URL}"
    mv "${DEST}.part" "${DEST}"
fi
ACTUAL=$(sha256sum "${DEST}" | awk '{print $1}')
if [ "${ACTUAL}" != "${PIN}" ]; then
    log_fail "rootfs sha256 mismatch for ${DEST} (expected ${PIN}, got ${ACTUAL})"
    harness_finish "tests/apk/sign-verify.sh"
fi
echo "rootfs sha256 OK (${ACTUAL})"
docker import "${DEST}" "${ROOTFS_IMAGE_TAG}" >/dev/null
echo "imported ${ROOTFS_IMAGE_TAG}"

# --- 2. build the real aarch64 tailscale .apk -----------------------------
echo "Building apk stage (arch=${ARCH}, version=${EXPECT_VERSION})..."
docker build \
    --target apk \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH="${ARCH}" \
    --build-arg SKIP_UPX=1 \
    -t "${BUILD_IMAGE_TAG}" -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}"

BUILD_CID=$(docker create "${BUILD_IMAGE_TAG}")
track "${BUILD_CID}"
mkdir -p "${WORKDIR}/repo"
docker cp "${BUILD_CID}:/out/${ARCH}/tailscale-${EXPECT_VERSION}.apk" "${WORKDIR}/repo/"
untrack_and_remove "${BUILD_CID}"
if [ ! -s "${WORKDIR}/repo/tailscale-${EXPECT_VERSION}.apk" ]; then
    log_fail ".apk missing/empty after extraction"
    harness_finish "tests/apk/sign-verify.sh"
fi
echo "OK: built tailscale-${EXPECT_VERSION}.apk"

# --- 3. combined unsigned index: real .apk + offline stub deps -----------
# Reuses the A4/A5b stub-dep trick (kmod-tun/ip-full/conntrack are not
# resolvable offline; ca-bundle is already in the base image), but ALL in
# ONE index this time -- `apk add` has no per-repository trust flag, so if
# the stub deps came from a second, unsigned repo, the whole transaction
# would need --allow-untrusted regardless of tailscale's own signature.
IDX_CID=$(docker create "${BUILD_IMAGE_TAG}" sh -c "sleep 600")
track "${IDX_CID}"
docker start "${IDX_CID}" >/dev/null
docker exec "${IDX_CID}" mkdir -p /stubwork/empty /repo
docker cp "${WORKDIR}/repo/tailscale-${EXPECT_VERSION}.apk" "${IDX_CID}:/repo/"
for dep in kmod-tun ip-full conntrack; do
    docker exec "${IDX_CID}" sh -c \
        "apk mkpkg --allow-untrusted --info 'name:${dep}' --info 'version:1-r1' --info 'arch:${ARCH}' --files /stubwork/empty --output /repo/${dep}-1-r1.apk"
done
# --compression none (this slice's finding): sidesteps the compressed
# ADB_BLOCK_ADB payload-extraction problem entirely -- scripts/adb-sign.py
# only ever has to understand the uncompressed on-disk layout.
docker exec "${IDX_CID}" sh -c \
    "apk mkndx --allow-untrusted --compression none --output /repo/packages.adb /repo/*.apk"
docker cp "${IDX_CID}:/repo/." "${WORKDIR}/repo/"
untrack_and_remove "${IDX_CID}"
UNSIGNED_SIZE=$(stat -c%s "${WORKDIR}/repo/packages.adb")
echo "OK: combined unsigned packages.adb built (${UNSIGNED_SIZE} bytes: tailscale + 3 stub deps)"

MAGIC=$(head -c4 "${WORKDIR}/repo/packages.adb")
assert_eq "unsigned index is the uncompressed 'ADB.' form" "ADB." "${MAGIC}"

# --- 4. ephemeral EC key + CI-local imprimatur image (LOCAL working tree) -
echo "Generating ephemeral EC test key (never committed, discarded on exit)..."
mkdir -p "${WORKDIR}/keys"
openssl ecparam -genkey -name prime256v1 -noout -out "${WORKDIR}/keys/apk-signing.pem"
chmod 600 "${WORKDIR}/keys/apk-signing.pem"
openssl ec -in "${WORKDIR}/keys/apk-signing.pem" -pubout -out "${WORKDIR}/keys/apk-signing-pub.pem" 2>/dev/null
# imprimatur's Dockerfile USER 1000 needs read access to the mounted key.
chmod 644 "${WORKDIR}/keys/apk-signing.pem"

echo "Building CI-local imprimatur image from LOCAL working tree ${IMPRIMATUR_REPO_DIR}..."
IMPRIMATUR_IMAGE_TAG="imprimatur-c2-hermetic:local"
docker build -t "${IMPRIMATUR_IMAGE_TAG}" "${IMPRIMATUR_REPO_DIR}"

IMPRIMATUR_SIGNERS='[{"name":"ec","algo":"ec","source":"file","path":"/keys/apk-signing.pem","required":true}]'
IMPRIMATUR_CID=$(docker run -d -p 127.0.0.1::8080 \
    -v "${WORKDIR}/keys:/keys:ro" \
    -e IMPRIMATUR_SIGNERS="${IMPRIMATUR_SIGNERS}" \
    "${IMPRIMATUR_IMAGE_TAG}")
IMPRIMATUR_PORT=$(docker port "${IMPRIMATUR_CID}" 8080/tcp | head -1 | cut -d: -f2)
if [ -z "${IMPRIMATUR_PORT}" ]; then
    log_fail "could not determine CI-local imprimatur's published port"
    harness_finish "tests/apk/sign-verify.sh"
fi

# Poll /health rather than a fixed sleep -- loud-failure discipline (RFC
# guiding constraint #2): a slow/broken imprimatur boot should show up as an
# explicit timeout message, not a flaky race.
HEALTH_OK=0
i=0
while [ "$i" -lt 30 ]; do
    if HEALTH_BODY=$(curl -fsS "http://127.0.0.1:${IMPRIMATUR_PORT}/health" 2>/dev/null); then
        if echo "${HEALTH_BODY}" | jq -e '.signers.ec.loaded == true' >/dev/null 2>&1; then
            HEALTH_OK=1
            break
        fi
    fi
    i=$((i + 1))
    sleep 0.5
done
if [ "${HEALTH_OK}" -ne 1 ]; then
    log_fail "CI-local imprimatur never reported ec.loaded:true on /health (last body: ${HEALTH_BODY:-<none>})"
    docker logs "${IMPRIMATUR_CID}" >&2 || true
    harness_finish "tests/apk/sign-verify.sh"
fi
IMPRIMATUR_FINGERPRINT=$(echo "${HEALTH_BODY}" | jq -r '.signers.ec.fingerprint')
echo "OK: CI-local imprimatur up on 127.0.0.1:${IMPRIMATUR_PORT}, ec.loaded=true, fingerprint=${IMPRIMATUR_FINGERPRINT}"

# --- 5. frame the 86-byte pre-image (CI-side, per the B0 spike) ----------
python3 "${ADB_SIGN_PY}" preimage \
    "${WORKDIR}/repo/packages.adb" "${WORKDIR}/keys/apk-signing-pub.pem" "${WORKDIR}/preimage.bin"

PREIMAGE_SIZE=$(stat -c%s "${WORKDIR}/preimage.bin")
assert_eq "pre-image is exactly 86 bytes (B0 spike)" "86" "${PREIMAGE_SIZE}"

# CI independently derives `id` from the public key file (never trusts
# imprimatur's self-report) -- cross-check it against imprimatur's own
# /health fingerprint as a sanity assertion that the SAME key is in play on
# both sides (a mismatch here would mean the wrong pubkey/key pair, not a
# framing bug -- worth failing loudly and distinctly from the apk-side
# assertions below).
CI_ID_HEX=$(python3 "${ADB_SIGN_PY}" key-id "${WORKDIR}/keys/apk-signing-pub.pem")
assert_eq "CI-derived key id matches imprimatur's self-reported fingerprint" "${IMPRIMATUR_FINGERPRINT}" "${CI_ID_HEX}"

# --- 6. POST to the CI-local imprimatur's /sign/ec ------------------------
MSG_B64=$(base64 -w0 "${WORKDIR}/preimage.bin")
SIGN_RESP=$(curl -fsS -X POST "http://127.0.0.1:${IMPRIMATUR_PORT}/sign/ec" \
    -H 'Content-Type: application/json' \
    -d "{\"message\": \"${MSG_B64}\"}")
SIGNATURE_B64=$(echo "${SIGN_RESP}" | jq -r '.signature')
if [ -z "${SIGNATURE_B64}" ] || [ "${SIGNATURE_B64}" = "null" ]; then
    log_fail "/sign/ec did not return a signature (response: ${SIGN_RESP})"
    harness_finish "tests/apk/sign-verify.sh"
fi
echo "${SIGNATURE_B64}" | base64 -d > "${WORKDIR}/sig.der"
SIG_LEN=$(stat -c%s "${WORKDIR}/sig.der")
DER_FIRST_BYTE=$(od -An -tx1 -N1 "${WORKDIR}/sig.der" | tr -d ' ')
assert_eq "signature is DER (0x30 SEQUENCE prefix)" "30" "${DER_FIRST_BYTE}"
echo "OK: /sign/ec returned a ${SIG_LEN}-byte DER signature"

# Signing key is no longer needed -- stop imprimatur now (nothing past this
# point touches the private key; CI does the rest of the framing itself).
docker rm -f "${IMPRIMATUR_CID}" >/dev/null 2>&1 || true
IMPRIMATUR_CID=""

# --- 7. assemble the signed index -----------------------------------------
mkdir -p "${WORKDIR}/repo-signed"
python3 "${ADB_SIGN_PY}" assemble \
    "${WORKDIR}/repo/packages.adb" "${WORKDIR}/keys/apk-signing-pub.pem" "${WORKDIR}/sig.der" \
    "${WORKDIR}/repo-signed/packages.adb"
# The signed repo also needs the .apk files themselves (index references
# them by name/hash for resolution) -- copy the real package + stub deps
# alongside the signed index.
for f in "${WORKDIR}"/repo/*.apk; do
    cp "$f" "${WORKDIR}/repo-signed/"
done
SIGNED_SIZE=$(stat -c%s "${WORKDIR}/repo-signed/packages.adb")
echo "OK: signed packages.adb assembled (${UNSIGNED_SIZE} -> ${SIGNED_SIZE} bytes, +$((SIGNED_SIZE - UNSIGNED_SIZE)) byte SIG block)"

# --- 8. deliberately corrupted variant, for the required negative ---------
# Flip a byte inside the real (non-padding) DER signature content -- well
# past the unsigned index's own bytes and safely inside the ~70-byte DER
# blob, not the trailing 8-byte-alignment padding (which apk correctly
# ignores, since block length is derived from the block header's rawsize,
# not the padded on-disk size).
mkdir -p "${WORKDIR}/repo-corrupt"
python3 -c "
data = bytearray(open('${WORKDIR}/repo-signed/packages.adb', 'rb').read())
idx = ${UNSIGNED_SIZE} + 50
data[idx] ^= 0xFF
open('${WORKDIR}/repo-corrupt/packages.adb', 'wb').write(data)
"
for f in "${WORKDIR}"/repo/*.apk; do
    cp "$f" "${WORKDIR}/repo-corrupt/"
done
echo "OK: corrupted-signature variant prepared for the negative test"

# --- 9. trust proof in the pinned aarch64 rootfs container ----------------
# One helper, parameterized by which repo dir to trust-check against, run in
# a FRESH container each time (apk add mutates world state).
run_apk_add_trusted() {
    _label="$1"; _repo_dir="$2"
    _cid=$(docker create --network none "${ROOTFS_IMAGE_TAG}" sh -c "sleep 600")
    track "${_cid}"
    docker start "${_cid}" >/dev/null

    if ! exec_in_container "${_cid}" apk --print-arch >/dev/null; then
        log_fail "${_label}: apk --print-arch failed in target container"
        untrack_and_remove "${_cid}"
        return 1
    fi

    # A4's proven arch-override mechanism: append our build arch to the
    # container's multi-line /etc/apk/arch (NOT `apk add --arch`, which
    # A4 found replaces rather than extends the acceptable-arch set).
    NATIVE_ARCH_LINE=$(docker exec "${_cid}" cat /etc/apk/arch)
    docker exec "${_cid}" sh -c "printf '%s\n%s\n' '${NATIVE_ARCH_LINE}' '${ARCH}' > /etc/apk/arch"

    docker exec "${_cid}" mkdir -p /etc/apk/keys /repo
    docker cp "${WORKDIR}/keys/apk-signing-pub.pem" "${_cid}:/etc/apk/keys/tailscale.pem"
    docker cp "${_repo_dir}/." "${_cid}:/repo/"

    echo "=== apk add tailscale, NO --allow-untrusted (${_label}) ==="
    if OUT=$(exec_in_container "${_cid}" \
            apk add --force-missing-repositories -X /repo/packages.adb tailscale); then
        echo "${OUT}"
        untrack_and_remove "${_cid}"
        return 0
    else
        echo "${OUT}"
        untrack_and_remove "${_cid}"
        return 1
    fi
}

# (a) RED: unsigned index -> must FAIL (untrusted).
if run_apk_add_trusted "unsigned index" "${WORKDIR}/repo" >"${WORKDIR}/out-unsigned.log" 2>&1; then
    cat "${WORKDIR}/out-unsigned.log"
    log_fail "unsigned index: apk add tailscale (no --allow-untrusted) unexpectedly SUCCEEDED"
else
    cat "${WORKDIR}/out-unsigned.log"
    log_info "OK: unsigned index correctly rejected (untrusted) with no --allow-untrusted"
fi

# (b) RED (the required negative): corrupted signature -> must FAIL.
if run_apk_add_trusted "corrupted signature" "${WORKDIR}/repo-corrupt" >"${WORKDIR}/out-corrupt.log" 2>&1; then
    cat "${WORKDIR}/out-corrupt.log"
    log_fail "corrupted signature: apk add tailscale (no --allow-untrusted) unexpectedly SUCCEEDED -- verification is not real"
else
    cat "${WORKDIR}/out-corrupt.log"
    log_info "OK: corrupted signature correctly rejected -- proves real cryptographic verification, not a vacuous pass"
fi

# (c) GREEN: correctly assembled signed index -> must SUCCEED, and the real
# package must actually be installed (not just index-trust checked).
_cid=$(docker create --network none "${ROOTFS_IMAGE_TAG}" sh -c "sleep 600")
track "${_cid}"
docker start "${_cid}" >/dev/null
if ! exec_in_container "${_cid}" apk --print-arch >/dev/null; then
    log_fail "signed index: apk --print-arch failed in target container"
else
    NATIVE_ARCH_LINE=$(docker exec "${_cid}" cat /etc/apk/arch)
    docker exec "${_cid}" sh -c "printf '%s\n%s\n' '${NATIVE_ARCH_LINE}' '${ARCH}' > /etc/apk/arch"
    docker exec "${_cid}" mkdir -p /etc/apk/keys /repo
    docker cp "${WORKDIR}/keys/apk-signing-pub.pem" "${_cid}:/etc/apk/keys/tailscale.pem"
    docker cp "${WORKDIR}/repo-signed/." "${_cid}:/repo/"

    echo "=== apk add tailscale, NO --allow-untrusted (signed index, expect SUCCESS) ==="
    if OUT=$(exec_in_container "${_cid}" \
            apk add --force-missing-repositories -X /repo/packages.adb tailscale); then
        echo "${OUT}"
        log_info "OK: TRUSTED apk add tailscale (no --allow-untrusted) succeeded against the C2-signed index"
        assert_contains "apk add ran post-install" "${OUT}" "post-install"

        if ! VERSION_OUT=$(exec_in_container "${_cid}" /usr/sbin/tailscaled --version); then
            log_fail "tailscaled --version failed to execute after trusted install (${VERSION_OUT})"
        else
            assert_contains "tailscaled --version reports the built version" "${VERSION_OUT}" "${TEST_VERSION}"
        fi
    else
        echo "${OUT}"
        log_fail "signed index: apk add tailscale (no --allow-untrusted) FAILED -- this is the load-bearing assertion"
    fi
fi
untrack_and_remove "${_cid}"

harness_finish "tests/apk/sign-verify.sh"
