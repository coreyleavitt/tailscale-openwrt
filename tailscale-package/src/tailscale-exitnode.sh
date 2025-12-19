#!/bin/sh
#
# Tailscale Exit Node Manager for OpenWrt
# Manages firewall rules and exit node advertising
#

TAILSCALE="/usr/bin/tailscale"

usage() {
    cat <<'EOF'
Usage: tailscale exitnode <command>

Commands:
  enable     Enable exit node (firewall rule + advertise)
  disable    Disable exit node (stop advertising + firewall rule)
  status     Show current exit node status

This router will advertise itself as an exit node, allowing other
Tailscale devices to route their internet traffic through it.
EOF
    exit 1
}

enable_exitnode() {
    echo "Enabling exit node..."

    # Enable firewall rule
    if [ "$(uci -q get firewall.ts_wan_forward.enabled)" != "1" ]; then
        echo "  Enabling firewall forwarding rule..."
        uci set firewall.ts_wan_forward.enabled='1'
        uci commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1
    else
        echo "  Firewall rule already enabled"
    fi

    # Advertise as exit node
    echo "  Advertising as exit node..."
    "$TAILSCALE" set --advertise-exit-node=true

    echo ""
    echo "Exit node enabled. Approve it in the Tailscale admin console:"
    echo "  https://login.tailscale.com/admin/machines"
}

disable_exitnode() {
    echo "Disabling exit node..."

    # Stop advertising
    echo "  Stopping exit node advertisement..."
    "$TAILSCALE" set --advertise-exit-node=false

    # Disable firewall rule
    if [ "$(uci -q get firewall.ts_wan_forward.enabled)" = "1" ]; then
        echo "  Disabling firewall forwarding rule..."
        uci set firewall.ts_wan_forward.enabled='0'
        uci commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1
    else
        echo "  Firewall rule already disabled"
    fi

    echo ""
    echo "Exit node disabled."
}

show_status() {
    echo "Exit Node Status"
    echo "================"

    # Check firewall rule
    fw_enabled=$(uci -q get firewall.ts_wan_forward.enabled)
    if [ "$fw_enabled" = "1" ]; then
        echo "Firewall rule:  enabled (tailscale -> wan forwarding allowed)"
    else
        echo "Firewall rule:  disabled (tailscale -> wan forwarding blocked)"
    fi

    # Check Tailscale status for exit node info
    echo ""
    echo "Tailscale status:"
    "$TAILSCALE" status 2>/dev/null | head -5

    # Check if we're advertising
    prefs=$("$TAILSCALE" debug prefs 2>/dev/null)
    if echo "$prefs" | grep -q '"AdvertiseRoutes".*"0.0.0.0/0"'; then
        echo ""
        echo "Advertising:    yes (offering as exit node)"
    else
        echo ""
        echo "Advertising:    no"
    fi
}

case "$1" in
    enable)
        enable_exitnode
        ;;
    disable)
        disable_exitnode
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
