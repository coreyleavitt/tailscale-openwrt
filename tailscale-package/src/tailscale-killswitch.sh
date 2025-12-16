#!/bin/sh
#
# Tailscale Exit Node Killswitch for OpenWrt 22.x, 23.x, and 24.x
# Blocks all WAN traffic except through Tailscale exit node.
# Includes DNS leak prevention.
#

# --- Configuration ---
TAILSCALE_INTERFACE="tailscale0"
TAILSCALE_ZONE_NAME="ts"
LAN_ZONE_NAME="lan"
WAN_ZONE_NAME="wan"

# --- Functions ---

get_openwrt_version() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        if [ -n "$VERSION_ID" ]; then
            OPENWRT_MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d'.' -f1)
        else
            OPENWRT_MAJOR_VERSION="22"
        fi
    else
        OPENWRT_MAJOR_VERSION="22"
    fi
}

verify_interface() {
    if ! ip link show "$TAILSCALE_INTERFACE" >/dev/null 2>&1; then
        echo "WARNING: $TAILSCALE_INTERFACE interface does not exist yet."
        echo "Killswitch config will be applied but won't be active until Tailscale starts."
        echo "Run: /etc/init.d/tailscale start"
        echo ""
    fi
}

reload_firewall() {
    echo "Applying firewall changes..."
    uci commit firewall

    if ! /etc/init.d/firewall reload; then
        echo "ERROR: Firewall reload failed!"
        echo "Check firewall config: uci show firewall"
        return 1
    fi
    return 0
}

enable_killswitch() {
    echo "Enabling Tailscale exit node killswitch..."
    get_openwrt_version
    echo "Detected OpenWrt major version: ${OPENWRT_MAJOR_VERSION}"

    verify_interface

    # 1. Clean up any existing killswitch rules
    uci -q delete firewall.${TAILSCALE_ZONE_NAME} || true
    uci -q delete firewall.lan_to_ts_forwarding || true
    uci -q delete firewall.lan_to_wan_block || true
    uci -q delete firewall.block_wan_dns || true
    uci -q delete firewall.allow_ts_dns || true

    # 2. Create Tailscale zone and forwarding rules
    uci batch <<EOF
set firewall.${TAILSCALE_ZONE_NAME}=zone
set firewall.${TAILSCALE_ZONE_NAME}.name='${TAILSCALE_ZONE_NAME}'
set firewall.${TAILSCALE_ZONE_NAME}.input='REJECT'
set firewall.${TAILSCALE_ZONE_NAME}.output='ACCEPT'
set firewall.${TAILSCALE_ZONE_NAME}.forward='REJECT'
set firewall.${TAILSCALE_ZONE_NAME}.masq='1'
set firewall.${TAILSCALE_ZONE_NAME}.mtu_fix='1'
add_list firewall.${TAILSCALE_ZONE_NAME}.device='${TAILSCALE_INTERFACE}'

set firewall.lan_to_ts_forwarding=forwarding
set firewall.lan_to_ts_forwarding.name='Allow LAN to Tailscale'
set firewall.lan_to_ts_forwarding.src='${LAN_ZONE_NAME}'
set firewall.lan_to_ts_forwarding.dest='${TAILSCALE_ZONE_NAME}'
EOF

    # 3. Block LAN to WAN traffic (works for both fw3 and fw4)
    echo "Adding LAN to WAN block rule..."
    uci set firewall.lan_to_wan_block=rule
    uci set firewall.lan_to_wan_block.name='Block LAN to WAN (Tailscale Killswitch)'
    uci set firewall.lan_to_wan_block.src="${LAN_ZONE_NAME}"
    uci set firewall.lan_to_wan_block.dest="${WAN_ZONE_NAME}"
    uci set firewall.lan_to_wan_block.target='REJECT'
    uci set firewall.lan_to_wan_block.family='any'

    # 4. DNS leak prevention - block DNS to WAN, allow to Tailscale
    echo "Adding DNS leak prevention rules..."
    uci set firewall.block_wan_dns=rule
    uci set firewall.block_wan_dns.name='Block WAN DNS (Prevent Leaks)'
    uci set firewall.block_wan_dns.src="${LAN_ZONE_NAME}"
    uci set firewall.block_wan_dns.dest="${WAN_ZONE_NAME}"
    uci set firewall.block_wan_dns.dest_port='53'
    uci set firewall.block_wan_dns.proto='tcp udp'
    uci set firewall.block_wan_dns.target='REJECT'
    uci set firewall.block_wan_dns.family='any'

    uci set firewall.allow_ts_dns=rule
    uci set firewall.allow_ts_dns.name='Allow Tailscale DNS'
    uci set firewall.allow_ts_dns.src="${LAN_ZONE_NAME}"
    uci set firewall.allow_ts_dns.dest="${TAILSCALE_ZONE_NAME}"
    uci set firewall.allow_ts_dns.dest_port='53'
    uci set firewall.allow_ts_dns.proto='tcp udp'
    uci set firewall.allow_ts_dns.target='ACCEPT'
    uci set firewall.allow_ts_dns.family='any'

    if reload_firewall; then
        echo "Killswitch enabled successfully."
    else
        echo "Killswitch configuration saved but firewall reload failed."
        return 1
    fi
}

disable_killswitch() {
    echo "Disabling Tailscale exit node killswitch..."

    # Remove all killswitch-related rules
    uci -q delete firewall.lan_to_wan_block || true
    uci -q delete firewall.block_wan_dns || true
    uci -q delete firewall.allow_ts_dns || true
    uci -q delete firewall.${TAILSCALE_ZONE_NAME} || true
    uci -q delete firewall.lan_to_ts_forwarding || true

    if reload_firewall; then
        echo "Killswitch disabled successfully."
    else
        echo "Killswitch configuration removed but firewall reload failed."
        return 1
    fi
}

check_status() {
    if uci -q get firewall.${TAILSCALE_ZONE_NAME} >/dev/null 2>&1; then
        echo "Killswitch status: ENABLED (config present)"

        # Verify rules are actually loaded in firewall
        get_openwrt_version
        if [ "${OPENWRT_MAJOR_VERSION}" -ge "23" ]; then
            # Check nftables for the rule
            if command -v nft >/dev/null 2>&1; then
                if nft list ruleset 2>/dev/null | grep -q "Block LAN to WAN"; then
                    echo "Firewall rules: ACTIVE"
                else
                    echo "WARNING: Config exists but rules may not be loaded. Try: /etc/init.d/firewall reload"
                fi
            fi
        else
            # Check iptables for reject rule
            if command -v iptables >/dev/null 2>&1; then
                if iptables -L FORWARD -n 2>/dev/null | grep -q "REJECT"; then
                    echo "Firewall rules: ACTIVE"
                else
                    echo "WARNING: Config exists but rules may not be loaded. Try: /etc/init.d/firewall reload"
                fi
            fi
        fi
        return 0
    else
        echo "Killswitch status: DISABLED"
        return 1
    fi
}

check_status_verbose() {
    check_status
    local status=$?

    if [ $status -ne 0 ]; then
        return 1
    fi

    echo ""
    echo "--- Detailed Firewall Configuration ---"

    echo ""
    echo "Tailscale Zone:"
    uci show firewall.${TAILSCALE_ZONE_NAME} 2>/dev/null || echo "  (not configured)"

    echo ""
    echo "LAN to Tailscale Forwarding:"
    uci show firewall.lan_to_ts_forwarding 2>/dev/null || echo "  (not configured)"

    echo ""
    echo "LAN to WAN Block Rule:"
    uci show firewall.lan_to_wan_block 2>/dev/null || echo "  (not configured)"

    echo ""
    echo "DNS Leak Prevention - Block WAN DNS:"
    uci show firewall.block_wan_dns 2>/dev/null || echo "  (not configured)"

    echo ""
    echo "DNS Leak Prevention - Allow Tailscale DNS:"
    uci show firewall.allow_ts_dns 2>/dev/null || echo "  (not configured)"

    echo ""
    echo "--- Interface Status ---"
    if ip link show "$TAILSCALE_INTERFACE" >/dev/null 2>&1; then
        echo "Tailscale interface ($TAILSCALE_INTERFACE): UP"
        ip addr show "$TAILSCALE_INTERFACE" 2>/dev/null | grep -E "inet |inet6 " | head -2
    else
        echo "Tailscale interface ($TAILSCALE_INTERFACE): NOT PRESENT"
        echo "  Tailscale may not be running. Check: /etc/init.d/tailscale status"
    fi

    echo "---------------------------------------"
}

# --- Main Logic ---
case "$1" in
    enable)
        enable_killswitch
        ;;
    disable)
        disable_killswitch
        ;;
    status)
        if [ "$2" = "--verbose" ] || [ "$2" = "-v" ]; then
            check_status_verbose
        else
            check_status
        fi
        ;;
    *)
        echo "Tailscale Exit Node Killswitch"
        echo ""
        echo "Usage: $0 {enable|disable|status [--verbose|-v]}"
        echo ""
        echo "Commands:"
        echo "  enable   - Block all WAN traffic except through Tailscale"
        echo "  disable  - Remove killswitch rules and restore normal routing"
        echo "  status   - Check if killswitch is enabled"
        echo ""
        echo "When enabled, this script:"
        echo "  - Creates a firewall zone for Tailscale"
        echo "  - Blocks all LAN to WAN traffic"
        echo "  - Allows LAN to Tailscale forwarding"
        echo "  - Prevents DNS leaks by blocking WAN DNS"
        exit 1
        ;;
esac

exit 0
