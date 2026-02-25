#!/bin/sh
# GL.iNet Tailscale Updater
# Installs/updates Tailscale binary on GL.iNet routers (firmware 4.x)
# This script is for devices with gl-sdk4-tailscale where the full IPK conflicts.
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/coreyleavitt/tailscale-openwrt/master/install-glinet.sh | sh
#   curl -sL ... | sh -s -- -v 1.94.1    # specific version
#   curl -sL ... | sh -s -- -l           # list releases

set -e

REPO="coreyleavitt/tailscale-openwrt"
API_URL="https://api.github.com/repos/${REPO}/releases"

# Colors (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$1" >&2; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

usage() {
    cat <<EOF
GL.iNet Tailscale Updater

Usage: $0 [OPTIONS]

Options:
    -v, --version VERSION   Install specific version (e.g., 1.94.1)
    -l, --list              List available releases
    -h, --help              Show this help message

Examples:
    $0                      Install latest version
    $0 -v 1.94.1            Install version 1.94.1
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

detect_arch() {
    machine=$(uname -m)
    case "$machine" in
        aarch64)
            echo "aarch64_cortex-a53"
            ;;
        armv7l)
            echo "arm_cortex-a7"
            ;;
        mips)
            echo "mips_24kc"
            ;;
        mipsel)
            echo "mipsel_24kc"
            ;;
        *)
            log_error "Unsupported architecture: $machine"
            log_error "This script supports aarch64, armv7l, mips, and mipsel"
            exit 1
            ;;
    esac
}

get_latest_version() {
    version=$(wget -qO- "${API_URL}/latest" 2>/dev/null | \
        grep -o '"tag_name": *"[^"]*"' | \
        sed 's/"tag_name": *"//;s/"//;s/^v//')

    if [ -z "$version" ]; then
        log_error "Failed to fetch latest version"
        exit 1
    fi

    echo "$version"
}

check_prerequisites() {
    # Check for GL.iNet firmware
    if [ ! -f /etc/glversion ]; then
        log_warn "GL.iNet firmware not detected"
        log_warn "This script is designed for GL.iNet routers with gl-sdk4-tailscale"
        printf "Continue anyway? [y/N] "
        read -r response
        case "$response" in
            [yY]|[yY][eE][sS]) ;;
            *) exit 1 ;;
        esac
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

    log_info "Downloading tailscaled ${version} for ${arch}..."

    tmpfile=$(mktemp)
    if ! wget -qO "$tmpfile" "$url" 2>/dev/null; then
        rm -f "$tmpfile"
        log_error "Failed to download binary"
        log_error "URL: $url"
        exit 1
    fi

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
    echo "Service status:"
    if pgrep -x tailscaled >/dev/null 2>&1; then
        echo "  tailscaled is running"
    else
        echo "  tailscaled is not running"
    fi
}

# Parse arguments
VERSION=""
LIST_ONLY=false

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version)
            VERSION="$2"
            shift 2
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

# Main
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
    VERSION=$(get_latest_version)
    log_info "Latest version: $VERSION"
else
    # Strip leading 'v' if present
    VERSION=$(echo "$VERSION" | sed 's/^v//')
    log_info "Requested version: $VERSION"
fi

# Check current version
if [ -x /usr/sbin/tailscaled ]; then
    current=$(/usr/sbin/tailscaled --version 2>/dev/null | head -1 | awk '{print $1}' || echo "unknown")
    log_info "Current version: $current"

    if [ "$current" = "$VERSION" ]; then
        log_info "Already running version $VERSION"
        printf "Reinstall anyway? [y/N] "
        read -r response
        case "$response" in
            [yY]|[yY][eE][sS]) ;;
            *) exit 0 ;;
        esac
    fi
fi

tmpfile=$(download_binary "$VERSION" "$ARCH")
install_binary "$tmpfile" "$VERSION"
show_status
