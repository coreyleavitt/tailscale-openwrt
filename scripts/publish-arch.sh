#!/bin/sh
# scripts/publish-arch.sh
#
# H6 (code-review finding): the per-arch "assemble + sign + guard + retain"
# pipeline used to be duplicated byte-for-byte between the `publish-feed`
# and `republish-feed` workflow jobs (RFC docs/rfc-apk-builds.md §4.3/§4.6
# slice C3/C5) -- two independent copies of the same six-step sequence, a
# drift risk (a fix/tweak to one copy silently not applied to the other).
# Extracted here so both jobs call ONE implementation.
#
# Pipeline (per arch), matching the RFC §4.3 Design-1 signing recipe:
#   1. apk mkndx --compression none    -> unsigned per-arch index
#   2. adb-sign.py preimage            -> 86-byte pre-image (B0 spike)
#   3. POST <SIGN_URL>                 -> DER signature (real imprimatur
#                                          round-trip in CI; a hermetic
#                                          test-key round-trip in tests
#                                          below)
#   4. adb-sign.py assemble            -> signed packages.adb
#   5. H7 HARD GATE: adb-sign.py verify the just-assembled signature
#      immediately, BEFORE anything below this point can reach a Pages
#      deploy. Fails closed (non-zero exit, nothing written that a caller
#      could still ship) rather than fail-open -- previously nothing
#      verified a freshly assembled signature until the (not-yet-existing)
#      daily cron probe, up to a 24h live-but-unverifiable-feed window.
#   6. feed-guard.sh check-monotonic   -- refuse a signed downgrade unless
#      --force (RFC §4.3/§8)
#   7. feed-guard.sh plan-retention + retained-blob carry-forward from the
#      still-live tree (GH Pages replaces the whole tree on deploy, so a
#      blob dropped here would 404 a client holding a briefly-stale cached
#      index).
#
# H3 (parallel imprimatur auth-token batch): if IMPRIMATUR_AUTH_TOKEN is set
# (repo secret, human deploy step -- see the workflow jobs that source it),
# it is sent as `Authorization: Bearer <token>` on the /sign/ec POST. This is
# backward-compatible -- an empty token produces a harmless empty-bearer
# header, and imprimatur ignores auth entirely until ITS OWN env enables it.
#
# Usage:
#   publish-arch.sh <arch> <apk-file> <published-filename> <pages-root> [--force]
#
# <published-filename> (round-3 fix: previously derived implicitly as
# basename(<apk-file>), which forced callers with a different on-disk source
# name -- e.g. republish-feed's release asset
# tailscale-<ver>-r<rel>-<arch>.apk, which must be published WITHOUT the arch
# suffix -- to build a whole rename/copy side-pipeline just to satisfy this
# script's naming convention, with nothing here validating that the derived
# basename actually matched the feed convention) is now an explicit,
# required argument: the exact filename this script writes the apk under in
# the feed tree (<pages-root>/apk/<arch>/<published-filename>). A normal
# publish passes basename(<apk-file>) (no rename needed); republish-feed
# passes the de-arch-suffixed name directly and does its own rename/copy
# scaffolding. Must be a bare filename (no `/`).
#
# Overridable via environment (defaults match the original inline
# workflow-step behavior byte-for-byte; tests override these to stub out
# apk/adb-sign.py/feed-guard.sh/the live signer without a real Docker/
# network round-trip):
#   APK_BIN                apk-tools binary to invoke for mkndx (default: apk,
#                           resolved via PATH)
#   ADB_SIGN_PY             path to adb-sign.py (default:
#                           <repo-root>/scripts/adb-sign.py)
#   FEED_GUARD              path to feed-guard.sh (default:
#                           <repo-root>/scripts/feed-guard.sh)
#   PUBKEY_PATH             committed EC public key (default:
#                           <repo-root>/apk-signing.pem)
#   SIGN_URL                signer endpoint (default:
#                           https://sign.leavitt.info/sign/ec)
#   LIVE_BASE_URL           live feed base, arch appended (default:
#                           https://apk.leavitt.dev/apk)
#   IMPRIMATUR_AUTH_TOKEN   optional bearer token (H3), default empty
#   RETAIN_N                last-N retention count (default: 2 -- S5b
#                           deliberate choice, RFC §5.7 retention
#                           measurement, revised DOWN from the pre-widening
#                           default of 3 now that the feed covers 30 arches
#                           instead of 4). Worst case is
#                           RETAIN_N * 30 arches * (per-arch apk size), and
#                           every retained blob is arch-tagged so none of it
#                           dedups across arches (apk bakes `arch:` into
#                           each signed package). Measured source: the LIVE
#                           feed's real 1.98.9-r2 `.apk` sizes across all 4
#                           current core arches (apk.leavitt.dev, fetched
#                           2026-07-21) -- 7.69-8.10 MB, aarch64_cortex-a53
#                           the largest observed at 8.10 MB. Using that as
#                           the representative worst-case single-arch size:
#                             RETAIN_N=3 (old default): 8.10MB * 30 * 3 =~ 729 MB
#                             RETAIN_N=2 (this default): 8.10MB * 30 * 2 =~ 486 MB
#                             RETAIN_N=1:                8.10MB * 30 * 1 =~ 243 MB
#                           against GH Pages' ~1 GB soft limit, N=3 leaves
#                           under 30% headroom BEFORE counting index/key/
#                           retained-manifest overhead or any of the 26 new
#                           extended arches (several families -- amd64,
#                           loongarch64 -- plausibly compiling LARGER than
#                           the ARM/MIPS samples measured above) or future
#                           Tailscale releases growing the binary further;
#                           N=1 drops the safety margin the mechanism exists
#                           for entirely (a client holding a briefly-stale
#                           cached index has zero fallback if it needed the
#                           immediately-prior version). N=2 keeps that
#                           one-version-back safety margin while leaving
#                           ~50% headroom for exactly that growth. Revisit
#                           if a future measurement (S9 arch-drift-adjacent
#                           monitoring) shows real per-arch sizes trending
#                           meaningfully above ~8-9 MB.
#   SIGN_RETRIES            /sign/ec POST retry count (S5a, RFC §5.4 round-2
#                           P-SEV2 -- mirrors the ipk `release` job's own
#                           3x-retry sign loop), default: 3
#   SIGN_RETRY_DELAY        seconds slept between sign retries (default: 5;
#                           tests set 0)
set -eu

die() {
    echo "publish-arch.sh: $1" >&2
    exit 1
}

[ $# -ge 4 ] || die "usage: publish-arch.sh <arch> <apk-file> <published-filename> <pages-root> [--force]"
ARCH="$1"; APK_FILE="$2"; PUBLISHED_FILENAME="$3"; PAGES_ROOT="$4"; shift 4

FORCE_FLAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE_FLAG="--force"; shift ;;
        *) die "unknown argument '$1'" ;;
    esac
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

APK_BIN="${APK_BIN:-apk}"
ADB_SIGN_PY="${ADB_SIGN_PY:-${REPO_ROOT}/scripts/adb-sign.py}"
FEED_GUARD="${FEED_GUARD:-${REPO_ROOT}/scripts/feed-guard.sh}"
PUBKEY_PATH="${PUBKEY_PATH:-${REPO_ROOT}/apk-signing.pem}"
SIGN_URL="${SIGN_URL:-https://sign.leavitt.info/sign/ec}"
LIVE_BASE_URL="${LIVE_BASE_URL:-https://apk.leavitt.dev/apk}"
IMPRIMATUR_AUTH_TOKEN="${IMPRIMATUR_AUTH_TOKEN:-}"
RETAIN_N="${RETAIN_N:-2}"
SIGN_RETRIES="${SIGN_RETRIES:-3}"
SIGN_RETRY_DELAY="${SIGN_RETRY_DELAY:-5}"

[ -n "${ARCH}" ] || die "arch must not be empty"
[ -f "${APK_FILE}" ] || die "apk file not found: ${APK_FILE}"
[ -n "${PUBLISHED_FILENAME}" ] || die "published filename must not be empty"
case "${PUBLISHED_FILENAME}" in
    */*) die "published filename must not contain a path separator: ${PUBLISHED_FILENAME}" ;;
esac
[ -f "${PUBKEY_PATH}" ] || die "pubkey not found: ${PUBKEY_PATH} (set PUBKEY_PATH or commit apk-signing.pem)"
[ -f "${ADB_SIGN_PY}" ] || die "adb-sign.py not found: ${ADB_SIGN_PY}"
[ -f "${FEED_GUARD}" ] || die "feed-guard.sh not found: ${FEED_GUARD}"

ARCH_DIR="${PAGES_ROOT}/apk/${ARCH}"
mkdir -p "${ARCH_DIR}"
cp "${APK_FILE}" "${ARCH_DIR}/${PUBLISHED_FILENAME}"

"${APK_BIN}" mkndx --allow-untrusted --compression none \
    --output "${ARCH_DIR}/unsigned.adb" "${ARCH_DIR}/${PUBLISHED_FILENAME}"
python3 "${ADB_SIGN_PY}" preimage "${ARCH_DIR}/unsigned.adb" "${PUBKEY_PATH}" "${ARCH_DIR}/preimage.bin"

# FIX3 (round-3 code review): the imprimatur bearer token used to be
# interpolated straight into curl's argv (`-H "Authorization: Bearer
# ${TOKEN}"`), which is visible in cleartext to anything that can read this
# process's command line (e.g. `ps`) for as long as the curl process runs.
# Pass it via curl's `-H @<file>` form instead (confirmed: curl reads the
# header line's content from the file, never puts it on its own argv) --
# the token only ever touches a 0600 tempfile, never a process argument.
AUTH_HEADER_FILE=$(mktemp)
chmod 600 "${AUTH_HEADER_FILE}"
# Belt-and-suspenders: guarantee the 0600 token file is removed even if the
# script is killed by an external signal (job cancel/timeout/OOM) between the
# write below and the explicit rm -f calls -- matching the trap the workflow's
# own signing steps use for the same file.
trap 'rm -f "${AUTH_HEADER_FILE}"' EXIT
printf 'Authorization: Bearer %s\n' "${IMPRIMATUR_AUTH_TOKEN}" > "${AUTH_HEADER_FILE}"

# FIX4 (round-3 code review): this used to be `curl ... | jq -r .signature`
# with no pipefail -- a curl failure (401/5xx under `-f`) was silently
# swallowed by the pipe, only ever caught downstream by the empty/null
# signature check below (a correct but confusing symptom, not the real
# cause). `set -o pipefail` is not POSIX (this script runs under plain
# /bin/sh, e.g. dash/busybox, where `set -o pipefail` is a hard error, not a
# no-op) so the pipe is avoided altogether: curl writes the response body to
# a file via `-o`, and its own exit status is checked directly.
#
# S5a (RFC §5.4 round-2 P-SEV2): retry the POST itself with backoff -- at
# 30 arches the odds of >=1 transient signer failure per run are far higher
# than at today's 4, and a bare single-shot curl call would abort the whole
# publish (or, with S5a's publish-feed.sh orchestrator, just this one arch's
# round) on a blip that a second attempt would have sailed through. Mirrors
# the ipk `release` job's own 3x-retry `/sign/usign` loop.
SIGN_RESPONSE="${ARCH_DIR}/sign-response.json"
SIGN_ATTEMPT=1
SIGN_OK=0
while [ "${SIGN_ATTEMPT}" -le "${SIGN_RETRIES}" ]; do
    if curl -fsS -X POST "${SIGN_URL}" \
        -H 'Content-Type: application/json' \
        -H "@${AUTH_HEADER_FILE}" \
        -d "{\"message\": \"$(base64 -w0 "${ARCH_DIR}/preimage.bin")\"}" \
        -o "${SIGN_RESPONSE}"; then
        SIGN_OK=1
        break
    fi
    echo "publish-arch.sh: sign attempt ${SIGN_ATTEMPT}/${SIGN_RETRIES} failed for ${ARCH} (curl error, see above)" >&2
    if [ "${SIGN_ATTEMPT}" -lt "${SIGN_RETRIES}" ]; then
        sleep "${SIGN_RETRY_DELAY}"
    fi
    SIGN_ATTEMPT=$((SIGN_ATTEMPT + 1))
done
rm -f "${AUTH_HEADER_FILE}"
if [ "${SIGN_OK}" -ne 1 ]; then
    rm -f "${SIGN_RESPONSE}"
    die "sign request to ${SIGN_URL} failed for ${ARCH} after ${SIGN_RETRIES} attempts (curl error, see above -- aborting before the signature-content check)"
fi
SIG_B64=$(jq -r .signature "${SIGN_RESPONSE}")
rm -f "${SIGN_RESPONSE}"
if [ -z "${SIG_B64}" ] || [ "${SIG_B64}" = "null" ]; then
    die "${SIGN_URL} did not return a signature for ${ARCH}"
fi
echo "${SIG_B64}" | base64 -d > "${ARCH_DIR}/sig.der"

python3 "${ADB_SIGN_PY}" assemble "${ARCH_DIR}/unsigned.adb" "${PUBKEY_PATH}" \
    "${ARCH_DIR}/sig.der" "${ARCH_DIR}/packages.adb"
rm -f "${ARCH_DIR}/unsigned.adb" "${ARCH_DIR}/preimage.bin" "${ARCH_DIR}/sig.der"

# H7: hard, fail-closed gate -- verify the signature THIS run just produced
# before any caller can reach a Pages deploy with it. Never trust
# adb-sign.py assemble's own success alone (it only proves the framing was
# written, not that the bytes cryptographically verify).
if ! python3 "${ADB_SIGN_PY}" verify "${ARCH_DIR}/packages.adb" "${PUBKEY_PATH}"; then
    die "post-assemble signature verification FAILED for ${ARCH} -- refusing to publish an unverifiable index (H7 fail-closed gate). Nothing was deployed."
fi

LIVE_URL="${LIVE_BASE_URL}/${ARCH}"
sh "${FEED_GUARD}" check-monotonic "${ARCH_DIR}/packages.adb" "${LIVE_URL}/packages.adb" ${FORCE_FLAG}

RETAINED=$(sh "${FEED_GUARD}" plan-retention "${LIVE_URL}/retained.json" "${PUBLISHED_FILENAME}" --n "${RETAIN_N}")
echo "${RETAINED}" > "${ARCH_DIR}/retained.json"
for f in $(echo "${RETAINED}" | jq -r '.[]'); do
    if [ ! -f "${ARCH_DIR}/${f}" ]; then
        curl -fsS -o "${ARCH_DIR}/${f}" "${LIVE_URL}/${f}" \
            || echo "::warning::could not carry forward retained blob ${f} for ${ARCH} (already gone from the live tree?)"
    fi
done

echo "publish-arch.sh: ${ARCH} -> ${ARCH_DIR}/packages.adb (signature verified, monotonicity/retention OK)"
