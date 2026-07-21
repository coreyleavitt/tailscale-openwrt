#!/bin/sh
# GL.iNet Tailscale Updater
# Installs/updates Tailscale binary on GL.iNet routers (firmware 4.x)
# This script is for devices with gl-sdk4-tailscale where the full IPK conflicts.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/coreyleavitt/tailscale-openwrt/master/install-glinet.sh | sh
#   curl -sL ... | sh -s -- -v 1.94.1    # specific version
#   curl -sL ... | sh -s -- -l           # list releases
#
# scripts/install.sh (RFC docs/rfc-apk-builds.md §4.4, slice D1) is now the
# recommended front door -- it detects OpenWrt release + arch and dispatches
# here automatically for GL.iNet devices, sharing the primitives below
# rather than reimplementing them. This script remains a fully standalone,
# curl-pipeable entry point in its own right (unchanged usage above);
# its log_*/detect_arch/prompt/poll primitives now live in the single
# shared scripts/lib-install.sh module (see the loader block below) instead
# of being defined inline, so install.sh's ipk/apk paths and this GL path
# share one authored copy of each -- but sourcing that module can't break
# the single-command curl|sh usage above, so it's loaded from a local
# sibling file when one is on disk (repo checkout) and self-fetched from
# the same repo/branch otherwise (standalone pipe execution, no sibling
# file present).

set -e

REPO="coreyleavitt/tailscale-openwrt"
API_URL="https://api.github.com/repos/${REPO}/releases"

# --- load shared install primitives (scripts/lib-install.sh) --------------
# log_info/log_warn/log_error, detect_arch, prompt_confirm, poll_for_service,
# get_latest_version. See scripts/lib-install.sh's own header for what each
# one carries forward from this script's history (recent commits 8a2d260,
# b3ac95d, 943b911).
LIB_INSTALL_URL="${LIB_INSTALL_URL:-https://raw.githubusercontent.com/${REPO}/master/scripts/lib-install.sh}"
# SCRIPT_DIR is normally auto-detected from $0; overridable so a test can
# source this file (where $0 is the invoking shell, not this file) and
# still point the loader at a real scripts/ directory.
SCRIPT_DIR="${SCRIPT_DIR:-}"
if [ -z "${SCRIPT_DIR}" ]; then
    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || SCRIPT_DIR=""
fi
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

usage() {
    cat <<EOF
GL.iNet Tailscale Updater

Usage: $0 [OPTIONS]

Options:
    -v, --version VERSION   Install specific version (e.g., 1.94.1)
    -y, --yes               Don't prompt for confirmation
    -l, --list              List available releases
    -h, --help              Show this help message

Examples:
    $0                      Install latest version
    $0 -v 1.94.1            Install version 1.94.1
    $0 -y                   Install latest version, no prompts
    $0 -l                   List all available releases
EOF
}

list_releases() {
    log_info "Fetching available releases..."
    releases=$(wget -qO- "${API_URL}" 2>/dev/null | \
        grep -o '"tag_name": *"[^"]*"' | \
        sed 's/"tag_name": *"//;s/"//' | \
        head -20)

    if [ -z "$releases" ]; then
        log_error "Failed to fetch releases"
        exit 1
    fi

    echo ""
    echo "Available releases:"
    echo "$releases" | while read -r tag; do
        echo "  $tag"
    done
    echo ""
    echo "Install with: $0 -v <version>"
}

check_prerequisites() {
    # Check for GL.iNet firmware
    if [ ! -f /etc/glversion ]; then
        log_warn "GL.iNet firmware not detected"
        log_warn "This script is designed for GL.iNet routers with gl-sdk4-tailscale"
        if ! prompt_confirm "Continue anyway?" n; then
            exit 1
        fi
    fi

    # Check for gl_tailscale service
    if [ ! -x /usr/bin/gl_tailscale ]; then
        log_error "gl_tailscale not found - is gl-sdk4-tailscale installed?"
        exit 1
    fi

    # Check for wget
    if ! command -v wget >/dev/null 2>&1; then
        log_error "wget is required but not installed"
        exit 1
    fi

    # Check disk space (need ~15MB)
    available=$(df /usr/sbin | awk 'NR==2 {print $4}')
    if [ "$available" -lt 15000 ]; then
        log_error "Insufficient disk space (need ~15MB, have ${available}KB)"
        exit 1
    fi
}

download_binary() {
    version="$1"
    arch="$2"

    url="https://github.com/${REPO}/releases/download/v${version}/tailscaled_${version}_${arch}"
    sums_url="https://github.com/${REPO}/releases/download/v${version}/SHA256SUMS"
    sums_sig_url="${sums_url}.sig"

    log_info "Downloading tailscaled ${version} for ${arch}..."

    tmpfile=$(mktemp)
    if ! wget -qO "$tmpfile" "$url" 2>/dev/null; then
        rm -f "$tmpfile"
        log_error "Failed to download binary"
        log_error "URL: $url"
        exit 1
    fi

    # H1: CI signs only .ipk assets via imprimatur's /sign/usign -- loose
    # tailscaled_* binaries attached for this GL.iNet path are never signed
    # per-file, so there is no signature to verify on the binary itself
    # here.
    #
    # Round-3 FIX4: the release's SHA256SUMS was previously trusted as-is,
    # fetched from the SAME untrusted release host it's meant to help
    # verify -- circular, since an attacker controlling the host controls
    # both the binary AND the checksum file used to "verify" it. CI now
    # usign-signs SHA256SUMS itself the same way it signs .ipk files (same
    # pinned key, TAILSCALE_USIGN_PUBKEY -- lib-install.sh, shared with
    # install.sh's ipk_path(), one copy) and attaches a detached
    # SHA256SUMS.sig to the release. Verify THAT signature before trusting
    # SHA256SUMS's hashes at all -- this gives this path the same
    # cryptographic root as the ipk path, instead of a
    # same-host-verifies-itself checksum. Fail closed at every step: a
    # missing sha256sum/usign tool, a missing/unfetchable SHA256SUMS.sig, an
    # invalid signature, or a binary hash that doesn't match a
    # signature-verified SHA256SUMS all refuse to install.
    if ! command -v sha256sum >/dev/null 2>&1; then
        rm -f "$tmpfile"
        log_error "'sha256sum' not found -- cannot verify the downloaded binary's checksum"
        log_error "Refusing to install an unverified binary"
        exit 1
    fi
    if ! command -v usign >/dev/null 2>&1; then
        rm -f "$tmpfile"
        log_error "'usign' not found -- cannot verify SHA256SUMS's signature"
        log_error "Refusing to trust an unsigned/unverifiable SHA256SUMS"
        exit 1
    fi

    sumsfile=$(mktemp)
    if ! wget -qO "$sumsfile" "$sums_url" 2>/dev/null; then
        rm -f "$tmpfile" "$sumsfile"
        log_error "Failed to download SHA256SUMS from $sums_url"
        log_error "Refusing to install an unverified binary"
        exit 1
    fi

    sumssigfile=$(mktemp)
    if ! wget -qO "$sumssigfile" "$sums_sig_url" 2>/dev/null; then
        rm -f "$tmpfile" "$sumsfile" "$sumssigfile"
        log_error "Failed to download SHA256SUMS.sig from $sums_sig_url"
        log_error "Refusing to trust an unsigned SHA256SUMS"
        exit 1
    fi

    sumspubkeyfile=$(mktemp)
    printf '%s\n' "${TAILSCALE_USIGN_PUBKEY}" > "$sumspubkeyfile"

    log_info "Verifying SHA256SUMS signature (usign)..."
    if ! usign -V -q -m "$sumsfile" -p "$sumspubkeyfile" -x "$sumssigfile"; then
        rm -f "$tmpfile" "$sumsfile" "$sumssigfile" "$sumspubkeyfile"
        log_error "SHA256SUMS signature verification FAILED -- refusing to trust its checksums"
        exit 1
    fi
    rm -f "$sumssigfile" "$sumspubkeyfile"
    log_info "SHA256SUMS signature verified OK"

    expected_sum=$(awk -v f="tailscaled_${version}_${arch}" '$2 == f {print $1}' "$sumsfile")
    if [ -z "$expected_sum" ]; then
        rm -f "$tmpfile" "$sumsfile"
        log_error "No SHA256SUMS entry found for tailscaled_${version}_${arch}"
        log_error "Refusing to install an unverified binary"
        exit 1
    fi
    rm -f "$sumsfile"

    # Round-3 dedup (FIX2): route the actual "compute sha256, compare, fail
    # closed" decision through the single shared sha256_verify() primitive
    # (lib-install.sh) -- the SAME one install.sh's apk feed-key pin uses --
    # instead of reimplementing the compare inline here.
    if ! sha256_verify "$tmpfile" "$expected_sum"; then
        rm -f "$tmpfile"
        log_error "SHA256 verification FAILED for tailscaled_${version}_${arch} (expected ${expected_sum})"
        log_error "Refusing to install a binary that does not match the release's signed SHA256SUMS"
        exit 1
    fi
    log_info "SHA256 verified OK ($expected_sum)"

    # Verify it's actually a valid tailscale binary
    chmod +x "$tmpfile"
    if ! "$tmpfile" --version >/dev/null 2>&1; then
        rm -f "$tmpfile"
        log_error "Downloaded file is not a valid binary"
        exit 1
    fi

    echo "$tmpfile"
}

install_binary() {
    tmpfile="$1"
    version="$2"

    log_info "Stopping Tailscale service..."
    /usr/bin/gl_tailscale stop 2>/dev/null || true
    sleep 2

    log_info "Installing binary..."
    mv "$tmpfile" /usr/sbin/tailscaled
    chmod 755 /usr/sbin/tailscaled

    # Create tailscale symlink if it doesn't exist or points elsewhere
    if [ ! -L /usr/sbin/tailscale ] || [ "$(readlink /usr/sbin/tailscale)" != "tailscaled" ]; then
        ln -sf tailscaled /usr/sbin/tailscale
    fi

    # Update opkg status so 'opkg list-installed' shows correct version
    if [ -f /usr/lib/opkg/status ]; then
        sed -i "/^Package: tailscale$/,/^$/s/^Version: .*/Version: ${version}/" /usr/lib/opkg/status
    fi

    log_info "Starting Tailscale service..."
    /usr/bin/gl_tailscale start

    # Configure persistence across firmware upgrades
    if ! grep -q "/usr/sbin/tailscaled" /etc/sysupgrade.conf 2>/dev/null; then
        log_info "Adding to sysupgrade.conf for persistence..."
        echo "/usr/sbin/tailscaled" >> /etc/sysupgrade.conf
        echo "/usr/sbin/tailscale" >> /etc/sysupgrade.conf
    fi
}

show_status() {
    echo ""
    log_info "Installation complete!"
    echo ""
    echo "Installed version:"
    /usr/sbin/tailscaled --version 2>/dev/null || echo "  (unable to determine)"
    echo ""
    # Poll for service startup (UPX-compressed binary can take time to
    # decompress) -- shared primitive, scripts/lib-install.sh. A timeout
    # here is not fatal (the service may just still be starting), so don't
    # let `set -e` turn poll_for_service's exit-1-on-timeout into a script
    # failure.
    poll_for_service tailscaled 30 || true
}

# tailscaled_current_version <path> -- prints the first whitespace-separated
# field of `<path> --version`'s output, or "unknown" if <path> isn't
# executable, produces no output, or errors. L9: the previous inline
# `... | awk '{print $1}' || echo "unknown"` bound the `||` fallback only to
# the last pipeline command (awk, which itself always exits 0 even on empty
# input), so a broken/non-responsive tailscaled silently left the caller's
# `current` variable EMPTY instead of "unknown". Extracted to its own
# function (parameterized on path, not hardcoded to /usr/sbin/tailscaled) so
# it's directly unit-testable -- see tests/apk/install-verify.sh.
tailscaled_current_version() {
    _tcv_bin="$1"
    if [ ! -x "${_tcv_bin}" ]; then
        echo "unknown"
        return 0
    fi
    _tcv_out=$("${_tcv_bin}" --version 2>/dev/null | head -1 | awk '{print $1}')
    if [ -z "${_tcv_out}" ]; then
        echo "unknown"
    else
        echo "${_tcv_out}"
    fi
}

main() {
    # Parse arguments
    VERSION=""
    LIST_ONLY=false

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
            -l|--list)
                LIST_ONLY=true
                shift
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

    if [ "$LIST_ONLY" = true ]; then
        list_releases
        exit 0
    fi

    log_info "GL.iNet Tailscale Updater"
    echo ""

    check_prerequisites

    ARCH=$(detect_arch)
    log_info "Detected architecture: $ARCH"

    if [ -z "$VERSION" ]; then
        if ! VERSION=$(get_latest_version "${REPO}"); then
            log_error "Failed to fetch latest version"
            exit 1
        fi
        log_info "Latest version: $VERSION"
    else
        # Strip leading 'v' if present
        VERSION=$(echo "$VERSION" | sed 's/^v//')
        log_info "Requested version: $VERSION"
    fi

    # Check current version
    if [ -x /usr/sbin/tailscaled ]; then
        current=$(tailscaled_current_version /usr/sbin/tailscaled)
        log_info "Current version: $current"

        if [ "$current" = "$VERSION" ]; then
            log_info "Already running version $VERSION"
            # M9: shared should_reinstall()/AUTO_YES convention
            # (lib-install.sh) instead of a separate inline prompt_confirm
            # with no -y equivalent.
            if ! should_reinstall; then
                exit 0
            fi
        fi
    fi

    tmpfile=$(download_binary "$VERSION" "$ARCH")
    install_binary "$tmpfile" "$VERSION"
    show_status
}

# Allows this file to be sourced for testing (functions only, no argv
# parsing / side effects) -- mirrors scripts/install.sh's own
# INSTALL_SH_NO_MAIN convention (see its header and
# tests/apk/install-dispatch.sh) so a test can source this file and call
# tailscaled_current_version/should_reinstall/etc directly against a fixture
# environment instead of running the full device flow. See
# tests/apk/install-verify.sh.
if [ -z "${INSTALL_GLINET_SH_NO_MAIN:-}" ]; then
    main "$@"
fi
