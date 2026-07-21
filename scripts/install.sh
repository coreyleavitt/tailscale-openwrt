#!/bin/sh
# scripts/install.sh
#
# Single install dispatcher for Tailscale on OpenWrt (RFC
# docs/rfc-apk-builds.md §4.4, slice D1). Detects the OpenWrt release +
# arch ONCE, then dispatches to exactly one of three install paths:
#
#   apk    -- OpenWrt 25.12+ (signed EC feed, `apk add tailscale`, no
#             --allow-untrusted)
#   ipk    -- OpenWrt <=24.10 (`opkg install` a downloaded .ipk)
#   glinet -- GL.iNet firmware 4.x (binary swap + gl_tailscale restart;
#             gl-sdk4-tailscale conflicts with the full ipk/apk package)
#
# This file is deliberately a thin MODULE, not a three-way if/elif with the
# differences smeared across it (§4.4's own warning: "a module hiding the
# differences, not three tangled branches"). All the genuinely reusable
# behavior -- colored log_*, arch detection, /dev/tty confirmation prompts,
# the service-startup poll, and latest-release-version lookup -- lives in
# ONE place, scripts/lib-install.sh, sourced below. Each _path() function
# here holds ONLY what's actually different about that path:
#   ipk_path()    -- opkg install
#   apk_path()    -- ca-bundle preflight, pubkey + feed wiring, apk add
#   glinet_path() -- delegates to scripts/install-glinet.sh (NOT
#                    reimplemented here -- its binary-swap/gl_tailscale
#                    mechanics are already hard-won and already share the
#                    same lib-install.sh primitives; duplicating them in
#                    this file would recreate exactly the "three divergent
#                    scripts" problem this slice exists to avoid).
#
# Usage:
#   wget -qO- https://raw.githubusercontent.com/coreyleavitt/tailscale-openwrt/master/scripts/install.sh | sh
#   ... | sh -s -- -v 1.94.1     # specific version (ipk/glinet paths)
#   ... | sh -s -- -y            # auto-confirm (non-interactive)
#   ... | sh -s -- --path apk    # force a path instead of auto-detecting
#
# Like install-glinet.sh, this script is meant to work standalone via a
# single curl|sh / wget-O-|sh invocation (no other files on disk) AND from
# a repo checkout. See the loader block below for how lib-install.sh is
# located either way.
#
# For automated testing, this file can be SOURCED instead of executed:
# setting INSTALL_SH_NO_MAIN=1 before sourcing skips the argv-parsing
# main() call at the bottom, so a test can source it and call
# choose_path/apk_path/ipk_path/detect_release directly against a fixture
# environment. See tests/apk/install-dispatch.sh.

set -eu

REPO="coreyleavitt/tailscale-openwrt"

# Feed host, per RFC §4.3 layout apk.leavitt.dev/apk/<arch>/{packages.adb,
# *.apk} + apk.leavitt.dev/apk/keys/tailscale.pem. Scheme/host are
# overridable (APK_FEED_SCHEME/APK_FEED_HOST) so tests/apk/install-dispatch.sh
# can point the apk path at a local `python3 -m http.server` instead of the
# real feed -- production installs never need to set either.
APK_FEED_SCHEME="${APK_FEED_SCHEME:-https}"
APK_FEED_HOST="${APK_FEED_HOST:-apk.leavitt.dev}"

# SCRIPT_DIR is normally auto-detected from $0; overridable so a test can
# source this file (where $0 is the invoking shell, not this file) and
# still point the loader at a real scripts/ directory.
SCRIPT_DIR="${SCRIPT_DIR:-}"
if [ -z "${SCRIPT_DIR}" ]; then
    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || SCRIPT_DIR=""
fi

# --- load shared install primitives (scripts/lib-install.sh) --------------
# log_info/log_warn/log_error, detect_arch, detect_release, prompt_confirm,
# poll_for_service, get_latest_version -- see that file's header for what
# each one carries forward from install-glinet.sh's history. Sourced from a
# local sibling file when present (repo checkout / this script copied
# alongside its lib); self-fetched from the same repo/branch otherwise
# (standalone single-file curl|sh execution). This loader is the one bit of
# bootstrap logic intentionally duplicated with install-glinet.sh's own
# copy -- it's the mechanism BY WHICH sharing happens, so it can't itself
# be sourced from the module it's about to load.
LIB_INSTALL_URL="${LIB_INSTALL_URL:-https://raw.githubusercontent.com/${REPO}/master/scripts/lib-install.sh}"
if [ -n "${SCRIPT_DIR}" ] && [ -f "${SCRIPT_DIR}/lib-install.sh" ]; then
    # shellcheck source=scripts/lib-install.sh
    . "${SCRIPT_DIR}/lib-install.sh"
else
    _lib_tmp=$(mktemp)
    if ! wget -qO "${_lib_tmp}" "${LIB_INSTALL_URL}" 2>/dev/null; then
        echo "[ERROR] failed to load shared install primitives from ${LIB_INSTALL_URL}" >&2
        rm -f "${_lib_tmp}"
        exit 1
    fi
    # shellcheck source=scripts/lib-install.sh
    . "${_lib_tmp}"
    rm -f "${_lib_tmp}"
fi

GLINET_SCRIPT_URL="${GLINET_SCRIPT_URL:-https://raw.githubusercontent.com/${REPO}/master/scripts/install-glinet.sh}"

# AUTO_YES / should_reinstall() (set by main()'s -y/--yes flag; the one place
# ipk_path/apk_path decide whether to re-run against an already-installed
# tailscale) now live in lib-install.sh, shared with install-glinet.sh's
# glinet path too (M9 fix) -- see that file's header for the rationale.

# --- H1: pinned usign public key for verifying signed .ipk releases -------
# CI signs every .ipk via imprimatur's `/sign/usign` (Ed-prefixed usign
# format, key-id 260114ce974e57e5) and attaches the resulting
# `<pkg>.ipk.sig` to the GitHub Release alongside the .ipk itself (see
# .github/workflows/build-tailscale.yaml's `release` job). `opkg install
# <localfile>` has NO per-file signature mechanism of its own, so
# ipk_path() below must run an explicit `usign -V` BEFORE opkg ever sees
# the file. The public key verifying that signature MUST NOT be fetched
# from the same host it's meant to authenticate -- so it is baked in
# byte-for-byte, the SAME content as the git-tracked repo-root file
# `signing.pub` (verified key-id 260114ce974e57e5), so a single `curl|sh`
# invocation of install.sh never has to trust a second network fetch just
# to authenticate the first.
#
# TAILSCALE_USIGN_PUBKEY itself now lives in scripts/lib-install.sh (round-3
# FIX4 promotion), sourced above -- install-glinet.sh's raw-binary path
# needs the SAME pinned key to verify SHA256SUMS.sig, so this is one shared
# constant rather than two copies that could silently drift. See
# lib-install.sh's own comment for the full provenance.

# --- H2: pinned fingerprint of the apk feed's EC signing key ---------------
# apk_path() below TOFU-fetches the feed's pubkey from the feed host itself
# (apk.leavitt.dev) -- that fetch is over the SAME channel it's meant to
# authenticate, so an unpinned TOFU is worthless against a compromised or
# spoofed feed host.
#
# DEVIATION FROM THE LETTER OF THE H2 FINDING -- flagged for Corey: the
# finding asked for this to match apk's OWN internal key-id derivation
# (scripts/adb-sign.py's key_id(): SHA512(i2d_PublicKey(pubkey))[:16], via
# the openssl CLI) so it could be cross-checked against that tool's output.
# Empirically (extracted and grepped the actual pinned OpenWrt 25.12
# rootfs images this repo tests against --
# tests/apk/.cache/openwrt-25.12.0-{armsr-armv7,armsr-armv8,malta-be,malta-le}
# -default-rootfs.tar.gz, ALL FOUR arches) the stock device ships NEITHER
# an `openssl` binary NOR any SHA-512 tool at all (its TLS stack is
# libustream-mbedtls, not OpenSSL/libcrypto) -- only `sha256sum`/`md5sum`.
# An openssl/SHA512-based check would therefore ALWAYS hit the
# "cannot verify" abort branch on every real device this ships to,
# permanently disabling the apk install path instead of fixing it -- worse
# than the original unpinned TOFU. `usign` (H1) IS present on all four
# images, confirmed the same way -- that check is unaffected.
#
# This pins a plain SHA256 (sha256sum IS present on every pinned image) of
# the committed repo-root apk-signing.pem's raw PEM bytes instead. This is
# a DIFFERENT derivation than apk's internal key-id, but the same security
# property: any byte-level difference from the committed key is rejected,
# fails closed if sha256sum is somehow missing, and needs no ASN.1/EC-point
# parsing (or openssl) at all. Recompute with: sha256sum apk-signing.pem
APK_FEED_KEY_SHA256="6c35a1064cebee0456e7b99114ccd8f793c04664f36a6ee413ca5f399bb40229"

usage() {
    cat <<EOF
Tailscale for OpenWrt -- installer

Usage: $0 [OPTIONS]

Detects your OpenWrt release + architecture and installs Tailscale via the
apk feed (25.12+), an ipk download (<=24.10), or the GL.iNet binary-swap
path (gl-sdk4-tailscale devices), in that priority order.

Options:
    -v, --version VERSION   Install specific version (ipk/glinet paths only;
                             the apk path always installs the feed's latest)
    -y, --yes                Don't prompt for confirmation
    --path PATH              Force a path instead of auto-detecting:
                             apk | ipk | glinet
    -h, --help               Show this help message
EOF
}

# --- dispatcher -------------------------------------------------------
# Detects the release ONCE and returns exactly one of apk/ipk/glinet on
# stdout. GL.iNet firmware is checked first (its /etc/glversion marker is
# unambiguous and independent of the OpenWrt release string -- GL.iNet 4.x
# ships an OpenWrt base whose own release number is irrelevant here, since
# gl-sdk4-tailscale's binary-swap requirement applies regardless of it).
choose_path() {
    if [ -f /etc/glversion ]; then
        echo "glinet"
        return 0
    fi

    if _release=$(detect_release); then
        log_info "Detected OpenWrt release: ${_release}"
    else
        log_warn "Could not detect OpenWrt release (/etc/openwrt_release missing or malformed)"
        log_warn "Falling back to the ipk path (widest compatibility)."
        log_warn "If this is actually an OpenWrt 25.12+ apk-based system, re-run with: --path apk"
        echo "ipk"
        return 0
    fi

    _major="${_release%%.*}"
    case "${_major}" in
        ''|*[!0-9]*)
            log_warn "Could not parse a numeric release from '${_release}' -- falling back to the ipk path"
            echo "ipk"
            return 0
            ;;
    esac

    if [ "${_major}" -ge 25 ]; then
        if command -v apk >/dev/null 2>&1; then
            echo "apk"
            return 0
        fi
        # apk-tools missing on what looks like a 25.12+ release: a clear
        # hint, never a raw "apk: command not found" (RFC §4.4).
        log_warn "OpenWrt ${_release} detected (looks like 25.12+) but 'apk' was not found on PATH"
        log_warn "Falling back to the ipk path -- if apk-tools should be present, check your image"
        echo "ipk"
        return 0
    fi

    log_info "OpenWrt ${_release} (<=24.10) -- using the ipk path"
    echo "ipk"
}

# apk_feed_key_sha256 <pubkey.pem> -- prints the SHA256 (H2) of <pubkey.pem>'s
# raw bytes as lowercase hex on stdout and returns 0, or prints nothing and
# returns 1 if the file doesn't exist/isn't readable, or 'sha256sum' is
# missing. See APK_FEED_KEY_SHA256's own comment above for why this is a
# plain file-content SHA256 rather than apk's internal SHA512-based
# key-id (openssl/sha512 are not available on the real target devices).
# Extracted to its own function (pure: no exit, no global state) so it's
# directly unit-testable against a fixture pem -- see
# tests/apk/install-verify.sh -- independent of apk_path()'s /etc/apk/keys
# side effects.
apk_feed_key_sha256() {
    _afks_pem="$1"
    if ! command -v sha256sum >/dev/null 2>&1; then
        return 1
    fi
    if [ ! -f "${_afks_pem}" ]; then
        return 1
    fi
    sha256sum "${_afks_pem}" | awk '{print $1}'
    return 0
}

# ipk_control_field <ipk_file> <field> -- prints the value of a control
# field (e.g. "Version", "Architecture") read directly from <ipk_file>'s own
# control metadata via `opkg info <file>` -- opkg parses a LOCAL .ipk's
# control data directly (the same mechanism `opkg install <file>` itself
# uses to read Depends/Conflicts/etc before ever touching the package
# database), so this needs no unpacking of our own and works identically
# whether or not the package ends up installed. Prints nothing and returns 1
# if the field is absent or `opkg info` fails outright (a corrupt/non-ipk
# file, for instance). Pure (no exit, no global state) so it's directly
# unit-testable via a stubbed opkg -- see tests/apk/install-verify.sh.
#
# Round-3 fix (ipk downgrade/substitution binding): usign -V (H1, above)
# proves the BYTES were signed by CI at SOME point -- it carries no
# filename or version of its own, so nothing before this stopped a
# release-host attacker from serving an OLD signed .ipk in response to a
# request for a NEWER _version (same URL pattern:
# tailscale_<version>_<arch>.ipk) and having the device install a
# stale/vulnerable build while logging "verified OK". ipk_path() below
# calls this AFTER usign verification succeeds to bind the verified bytes
# to the REQUESTED identity (both _version and _arch), aborting on any
# mismatch -- see the "package identity" check there.
ipk_control_field() {
    _icf_file="$1"
    _icf_field="$2"
    _icf_val=$(opkg info "${_icf_file}" 2>/dev/null | awk -v f="${_icf_field}:" '$1 == f { $1=""; sub(/^ /, ""); print; exit }')
    if [ -z "${_icf_val}" ]; then
        return 1
    fi
    echo "${_icf_val}"
    return 0
}

# --- ipk adapter --------------------------------------------------------
# The only genuine difference from the other paths: `opkg install` a
# downloaded .ipk. Arch detection, the reinstall confirm, and the
# service-startup poll are all the shared primitives.
ipk_path() {
    _version="$1"

    if ! command -v opkg >/dev/null 2>&1; then
        log_error "'opkg' not found on this system -- the ipk path requires opkg."
        exit 1
    fi

    _arch=$(detect_arch)
    log_info "Using the ipk install path (opkg) -- arch ${_arch}"

    if opkg list-installed 2>/dev/null | grep -q '^tailscale '; then
        log_info "tailscale is already installed via opkg"
        if ! should_reinstall; then
            log_info "Leaving the existing installation in place"
            return 0
        fi
    fi

    if [ -z "${_version}" ]; then
        if ! _version=$(get_latest_version "${REPO}"); then
            log_error "Failed to determine the latest release version"
            exit 1
        fi
        log_info "Latest version: ${_version}"
    else
        _version=$(echo "${_version}" | sed 's/^v//')
        log_info "Requested version: ${_version}"
    fi

    _url="https://github.com/${REPO}/releases/download/v${_version}/tailscale_${_version}_${_arch}.ipk"
    _sig_url="${_url}.sig"
    _tmpdir=$(mktemp -d)
    _pkgfile="${_tmpdir}/tailscale_${_version}_${_arch}.ipk"
    _sigfile="${_pkgfile}.sig"

    log_info "Downloading ${_url}..."
    if ! wget -qO "${_pkgfile}" "${_url}"; then
        rm -rf "${_tmpdir}"
        log_error "Failed to download ${_url}"
        exit 1
    fi

    log_info "Downloading ${_sig_url}..."
    if ! wget -qO "${_sigfile}" "${_sig_url}"; then
        rm -rf "${_tmpdir}"
        log_error "Failed to download ${_sig_url}"
        exit 1
    fi

    # H1: verify the signature BEFORE opkg ever sees the file -- opkg
    # install <localfile> has no per-file signature mechanism of its own.
    if ! command -v usign >/dev/null 2>&1; then
        rm -rf "${_tmpdir}"
        log_error "'usign' not found -- cannot verify the downloaded package's signature"
        log_error "Refusing to install an unverified package"
        exit 1
    fi

    _pubkeyfile="${_tmpdir}/tailscale-openwrt.pub"
    printf '%s\n' "${TAILSCALE_USIGN_PUBKEY}" > "${_pubkeyfile}"

    log_info "Verifying package signature (usign)..."
    if ! usign -V -q -m "${_pkgfile}" -p "${_pubkeyfile}" -x "${_sigfile}"; then
        rm -rf "${_tmpdir}"
        log_error "Signature verification FAILED for tailscale_${_version}_${_arch}.ipk -- refusing to install"
        exit 1
    fi
    log_info "Signature verified OK"

    # Round-3 fix: bind the usign-verified bytes to the REQUESTED identity
    # (version + arch) via the package's OWN control metadata -- see
    # ipk_control_field()'s header comment above for why usign -V alone
    # does not rule out a same-signer downgrade/substitution.
    if ! _pkg_version=$(ipk_control_field "${_pkgfile}" "Version"); then
        rm -rf "${_tmpdir}"
        log_error "Could not read the package's own Version from its control metadata -- refusing to install"
        exit 1
    fi
    case "${_pkg_version}" in
        "${_version}"|"${_version}-"*)
            ;;
        *)
            rm -rf "${_tmpdir}"
            log_error "Package identity MISMATCH: requested version ${_version} but tailscale_${_version}_${_arch}.ipk's own control metadata reports Version: ${_pkg_version}"
            log_error "Refusing to install -- a valid signature does not guarantee this is the version that was requested"
            exit 1
            ;;
    esac

    if ! _pkg_arch=$(ipk_control_field "${_pkgfile}" "Architecture"); then
        rm -rf "${_tmpdir}"
        log_error "Could not read the package's own Architecture from its control metadata -- refusing to install"
        exit 1
    fi
    if [ "${_pkg_arch}" != "${_arch}" ]; then
        rm -rf "${_tmpdir}"
        log_error "Package identity MISMATCH: requested arch ${_arch} but tailscale_${_version}_${_arch}.ipk's own control metadata reports Architecture: ${_pkg_arch}"
        log_error "Refusing to install -- a valid signature does not guarantee this is the arch that was requested"
        exit 1
    fi
    log_info "Package identity verified (Version: ${_pkg_version}, Architecture: ${_pkg_arch})"

    log_info "Installing via opkg..."
    if ! opkg install "${_pkgfile}"; then
        rm -rf "${_tmpdir}"
        log_error "opkg install failed"
        exit 1
    fi
    rm -rf "${_tmpdir}"

    log_info "Installation complete!"
    if ! poll_for_service tailscaled 30; then
        log_info "tailscale ships disabled by default. Enable it with:"
        log_info "  uci set tailscale.config.enabled='1'; uci commit tailscale"
        log_info "  /etc/init.d/tailscale enable; /etc/init.d/tailscale start"
    fi
}

# --- apk adapter ---------------------------------------------------------
# The genuine differences: verify apk exists (clear ipk hint otherwise,
# never "command not found"), a ca-bundle preflight (chicken/egg: our feed
# is HTTPS and needs ca-bundle for TLS trust, but ca-bundle is itself only
# a *dependency of* the tailscale package -- resolved by installing it from
# whatever feeds are ALREADY configured, before our own feed line is added),
# drop the pubkey, add the feed, `apk update && apk add tailscale` --
# TRUSTED, no --allow-untrusted anywhere in this path.
apk_path() {
    if ! command -v apk >/dev/null 2>&1; then
        log_error "'apk' not found on this system -- you appear to be on OpenWrt <=24.10"
        log_error "(apk-tools ships only on OpenWrt 25.12+). Use the ipk path instead:"
        log_error "  wget https://github.com/${REPO}/releases/latest/download/tailscale_<version>_<arch>.ipk"
        log_error "  opkg install tailscale_*.ipk"
        exit 1
    fi

    _arch=$(detect_arch)
    log_info "Using the apk install path -- arch ${_arch}"

    # ipk -> apk coexistence preflight (RFC docs/rfc-apk-builds.md
    # section 4.1/4.7, slice D3). apk and opkg are disjoint package databases --
    # apk cannot see an opkg-tracked "tailscale" at all, so without this a
    # stale ipk install surviving a 24.10 -> 25.12 sysupgrade (its
    # tailscaled/init/uci/firewall footprint) would silently collide with
    # this fresh apk install: opkg stays convinced it still owns files apk
    # is about to overwrite, and any cleanup only an ipk postrm would have
    # done (e.g. restoring DNS if the killswitch was enabled) never
    # happens. Detection/cleanup is filesystem/opkg-DB-level ONLY (never
    # apk `replaces:`/`conflicts:` metadata -- see lib-install.sh's own
    # header on opkg_tracked_tailscale/clean_opkg_tailscale for why).
    if opkg_tracked_tailscale; then
        clean_opkg_tailscale
    fi

    if apk info -e tailscale >/dev/null 2>&1; then
        log_info "tailscale is already installed via apk"
        if ! should_reinstall; then
            log_info "Leaving the existing installation in place"
            return 0
        fi
    fi

    # ca-bundle preflight -- MUST happen before our feed line is added
    # below, using only the feeds already on the device (stock OpenWrt
    # feeds, pre-trusted/pre-configured out of the box). If ca-bundle is
    # already present (true on the stock 25.12 image), this is a no-op.
    if apk info -e ca-bundle >/dev/null 2>&1; then
        log_info "ca-bundle already installed"
    else
        log_info "ca-bundle not yet installed -- installing it from the existing feeds first"
        log_info "(our own feed is HTTPS and needs ca-bundle for TLS trust before it can even be fetched)"
        if ! apk update || ! apk add ca-bundle; then
            log_warn "could not preflight ca-bundle from the existing feeds; continuing anyway"
            log_warn "-- 'apk update' below will fail with a clear TLS error if trust is genuinely unavailable"
        fi
    fi

    mkdir -p /etc/apk/keys
    _key_url="${APK_FEED_SCHEME}://${APK_FEED_HOST}/apk/keys/tailscale.pem"
    log_info "Fetching the feed signing key from ${_key_url}..."
    _key_tmp=$(mktemp)
    if ! wget -qO "${_key_tmp}" "${_key_url}"; then
        rm -f "${_key_tmp}"
        log_error "Failed to fetch the feed signing key from ${_key_url}"
        exit 1
    fi

    # H2: TOFU-fetching the pubkey from the feed host itself is worthless
    # on its own -- verify it against APK_FEED_KEY_SHA256 (pinned above,
    # baked into this script) BEFORE it is ever installed into
    # /etc/apk/keys and trusted by apk. See apk_feed_key_sha256() and
    # APK_FEED_KEY_SHA256's own comments above for why this is a plain
    # SHA256 rather than apk's internal key-id.
    if ! _key_sum=$(apk_feed_key_sha256 "${_key_tmp}"); then
        rm -f "${_key_tmp}"
        log_error "Fetched feed signing key from ${_key_url} could not be verified ('sha256sum' is missing)"
        log_error "Refusing to trust an unverified key"
        exit 1
    fi
    # Round-3 dedup (FIX2): the actual gating "compute sha256, compare to an
    # expected value, fail closed" decision now routes through the single
    # shared sha256_verify() primitive (lib-install.sh) -- the SAME one
    # install-glinet.sh's raw-binary check uses -- instead of reimplementing
    # the compare inline here. apk_feed_key_sha256() above is kept only to
    # obtain the human-readable digest for the log lines below.
    if ! sha256_verify "${_key_tmp}" "${APK_FEED_KEY_SHA256}"; then
        rm -f "${_key_tmp}"
        log_error "Feed signing key SHA256 MISMATCH: expected ${APK_FEED_KEY_SHA256}, got ${_key_sum}"
        log_error "Refusing to trust an unverified key fetched from ${_key_url}"
        exit 1
    fi

    log_info "Feed signing key verified (sha256 ${_key_sum})"
    mv "${_key_tmp}" /etc/apk/keys/tailscale.pem

    mkdir -p /etc/apk/repositories.d
    # repositories.d entries are literal URLs to the index FILE itself, not
    # a base directory apk suffixes on its own -- confirmed against the
    # pinned rootfs's own customfeeds.list template comment ("http://
    # www.example.com/path/to/files/packages.adb") and distfeeds.list
    # (every stock entry ends in .../packages.adb). Omitting the filename
    # here is the RFC-note's own shorthand for "the per-arch feed", but
    # what actually has to land in customfeeds.list is the full file URL.
    _feed_url="${APK_FEED_SCHEME}://${APK_FEED_HOST}/apk/${_arch}/packages.adb"
    if [ -f /etc/apk/repositories.d/customfeeds.list ] && grep -qF "${_feed_url}" /etc/apk/repositories.d/customfeeds.list; then
        log_info "Feed already present in /etc/apk/repositories.d/customfeeds.list"
    else
        log_info "Adding ${_feed_url} to /etc/apk/repositories.d/customfeeds.list"
        echo "${_feed_url}" >> /etc/apk/repositories.d/customfeeds.list
    fi

    log_info "apk update..."
    if ! apk update; then
        log_error "apk update failed"
        exit 1
    fi

    log_info "apk add tailscale (trusted -- no --allow-untrusted)..."
    if ! apk add tailscale; then
        log_error "apk add tailscale failed"
        exit 1
    fi

    log_info "Installation complete!"
    if ! poll_for_service tailscaled 30; then
        log_info "tailscale ships disabled by default. Enable it with:"
        log_info "  uci set tailscale.config.enabled='1'; uci commit tailscale"
        log_info "  /etc/init.d/tailscale enable; /etc/init.d/tailscale start"
    fi
}

# --- glinet adapter -------------------------------------------------------
# Thin by construction: delegates to the existing, already-hard-won
# scripts/install-glinet.sh (binary swap + gl_tailscale restart) instead of
# reimplementing any of it here. Located the same way lib-install.sh is
# (local sibling, else self-fetched from the same repo/branch).
glinet_path() {
    _version="$1"
    log_info "GL.iNet firmware detected -- delegating to install-glinet.sh"

    # M9: forward -y/AUTO_YES through too -- not just -v -- so
    # `install.sh ... -y` is genuinely non-interactive end-to-end even when
    # dispatch lands on the glinet path.
    set --
    if [ -n "${_version}" ]; then
        set -- "$@" -v "${_version}"
    fi
    if [ "${AUTO_YES}" = "true" ]; then
        set -- "$@" -y
    fi

    if [ -n "${SCRIPT_DIR}" ] && [ -f "${SCRIPT_DIR}/install-glinet.sh" ]; then
        exec sh "${SCRIPT_DIR}/install-glinet.sh" "$@"
    fi

    _glinet_tmp=$(mktemp)
    if ! wget -qO "${_glinet_tmp}" "${GLINET_SCRIPT_URL}" 2>/dev/null; then
        log_error "failed to fetch install-glinet.sh from ${GLINET_SCRIPT_URL}"
        rm -f "${_glinet_tmp}"
        exit 1
    fi
    sh "${_glinet_tmp}" "$@"
    _rc=$?
    rm -f "${_glinet_tmp}"
    exit "${_rc}"
}

main() {
    VERSION=""
    FORCE_PATH=""

    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--version)
                VERSION="$2"
                shift 2
                ;;
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            --path)
                FORCE_PATH="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    log_info "Tailscale for OpenWrt -- installer"
    echo "" >&2

    if [ -n "${FORCE_PATH}" ]; then
        PATH_CHOICE="${FORCE_PATH}"
        log_info "Install path forced via --path: ${PATH_CHOICE}"
    else
        PATH_CHOICE=$(choose_path)
    fi

    case "${PATH_CHOICE}" in
        glinet) glinet_path "${VERSION}" ;;
        apk) apk_path ;;
        ipk) ipk_path "${VERSION}" ;;
        *)
            log_error "Internal error: unknown install path '${PATH_CHOICE}'"
            exit 1
            ;;
    esac
}

# Allows this file to be sourced for testing (functions only, no argv
# parsing / side effects) -- see tests/apk/install-dispatch.sh.
if [ -z "${INSTALL_SH_NO_MAIN:-}" ]; then
    main "$@"
fi
