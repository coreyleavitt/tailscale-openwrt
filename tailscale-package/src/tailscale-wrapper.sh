#!/bin/sh
#
# Tailscale wrapper for OpenWrt
# Adds killswitch and exitnode subcommands, auto-manages firewall for exit node advertising
#

TAILSCALED="/usr/sbin/tailscaled"
KILLSWITCH="/usr/sbin/tailscale-killswitch"
EXITNODE="/usr/sbin/tailscale-exitnode"

# Show help with our extensions appended
show_help() {
    "$TAILSCALED" --help 2>&1
    cat <<'EOF'

OpenWrt Extensions:
  killswitch enable|disable|status   Manage exit node killswitch (blocks WAN if Tailscale fails)
  exitnode enable|disable|status     Manage exit node advertising (make this router an exit node)
EOF
}

# Enable exit node firewall rule with message
enable_exitnode_firewall() {
    if [ "$(uci -q get firewall.ts_wan_forward.enabled)" != "1" ]; then
        echo "Enabling exit node firewall rule..."
        uci set firewall.ts_wan_forward.enabled='1'
        uci commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1
    fi
}

# Disable exit node firewall rule with message
disable_exitnode_firewall() {
    if [ "$(uci -q get firewall.ts_wan_forward.enabled)" = "1" ]; then
        echo "Disabling exit node firewall rule..."
        uci set firewall.ts_wan_forward.enabled='0'
        uci commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1
    fi
}

# Check if args contain --advertise-exit-node (enabling)
check_advertise_exitnode() {
    for arg in "$@"; do
        case "$arg" in
            --advertise-exit-node|--advertise-exit-node=true)
                return 0
                ;;
        esac
    done
    return 1
}

# Check if args contain --advertise-exit-node=false (disabling)
check_advertise_exitnode_false() {
    for arg in "$@"; do
        case "$arg" in
            --advertise-exit-node=false)
                return 0
                ;;
        esac
    done
    return 1
}

# Main routing
case "$1" in
    killswitch)
        shift
        exec "$KILLSWITCH" "$@"
        ;;
    exitnode)
        shift
        exec "$EXITNODE" "$@"
        ;;
    --help|-h|help)
        show_help
        exit 0
        ;;
    up|set)
        # Check for exit node flags and auto-manage firewall
        if check_advertise_exitnode "$@"; then
            enable_exitnode_firewall
        elif check_advertise_exitnode_false "$@"; then
            disable_exitnode_firewall
        fi
        exec "$TAILSCALED" "$@"
        ;;
    *)
        exec "$TAILSCALED" "$@"
        ;;
esac
