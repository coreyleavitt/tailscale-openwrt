#!/bin/sh
#
# Tailscale Exit Node Killswitch for OpenWrt 22.x, 23.x, and 24.x
# Automatically detects the OpenWrt version and applies the correct firewall logic.
#

# --- Configuration ---
TAILSCALE_INTERFACE="tailscale0"
TAILSCALE_ZONE_NAME="ts"
LAN_ZONE_NAME="lan"
WAN_ZONE_NAME="wan"

# --- Functions ---

get_openwrt_version() {
    # Source the os-release file to get version info and extract the major version number
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OPENWRT_MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d'.' -f1)
    else
        # Fallback for very old versions, default to 22
        OPENWRT_MAJOR_VERSION="22"
    fi
}

enable_killswitch() {
    echo "Enabling Tailscale exit node killswitch..."
    get_openwrt_version
    echo "Detected OpenWrt major version: ${OPENWRT_MAJOR_VERSION}"

    # 1. Delete old settings individually to prevent batch failure on first run.
    uci -q delete firewall.${TAILSCALE_ZONE_NAME} || true
    uci -q delete firewall.lan_to_ts_forwarding || true
    uci -q delete firewall.lan_to_wan_block || true # For v23+ cleanup

    # 2. Create all new settings in a single, efficient batch operation.
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

    # --- Version-Specific Killswitch Logic ---
    if [ "${OPENWRT_MAJOR_VERSION}" -ge "23" ]; then
        echo "Applying firewall4 (nftables) compatible killswitch for OpenWrt 23.x+"
        uci set firewall.lan_to_wan_block=rule
        uci set firewall.lan_to_wan_block.name='Block LAN to WAN'
        uci set firewall.lan_to_wan_block.src="${LAN_ZONE_NAME}"
        uci set firewall.lan_to_wan_block.dest="${WAN_ZONE_NAME}"
        uci set firewall.lan_to_wan_block.target='REJECT'
    else
        echo "Applying firewall3 (iptables) compatible killswitch for OpenWrt 22.x"
        uci set firewall.@forwarding[0].target='REJECT'
    fi

    echo "Applying firewall changes..."
    uci commit firewall
    /etc/init.d/firewall reload

    echo "Killswitch enabled."
}

disable_killswitch() {
    echo "Disabling Tailscale exit node killswitch..."
    get_openwrt_version

    # --- Version-Specific Disable Logic ---
    if [ "${OPENWRT_MAJOR_VERSION}" -ge "23" ]; then
        uci -q delete firewall.lan_to_wan_block || true
    else
        # For v22, delete the target option to restore default 'ACCEPT' behavior.
        uci -q delete firewall.@forwarding[0].target || true
    fi

    # The rest of the cleanup is the same for all versions
    uci -q delete firewall.${TAILSCALE_ZONE_NAME} || true
    uci -q delete firewall.lan_to_ts_forwarding || true

    echo "Applying firewall changes..."
    uci commit firewall
    /etc/init.d/firewall reload

    echo "Killswitch disabled."
}

check_status() {
    # This check works for all versions as it just looks for the custom zone
    if uci -q get firewall.${TAILSCALE_ZONE_NAME} >/dev/null 2>&1; then
        echo "Killswitch status: ENABLED"
        return 0
    else
        echo "Killswitch status: DISABLED"
        return 1
    fi
}

check_status_verbose() {
    # First, run the basic check. If it's disabled, stop here.
    check_status
    if [ $? -ne 0 ]; then
        return 1
    fi

    echo ""
    echo "--- Detailed Firewall Configuration ---"

    # Show the Tailscale zone configuration
    echo "Tailscale Zone (firewall.${TAILSCALE_ZONE_NAME}):"
    uci show firewall.${TAILSCALE_ZONE_NAME}
    echo ""

    # Show the LAN -> Tailscale forwarding rule
    echo "LAN to Tailscale Forwarding (firewall.lan_to_ts_forwarding):"
    uci show firewall.lan_to_ts_forwarding
    echo ""

    # Show the version-specific killswitch implementation details
    get_openwrt_version
    if [ "${OPENWRT_MAJOR_VERSION}" -ge "23" ]; then
        echo "Killswitch Rule (firewall.lan_to_wan_block) [v23+ Method]:"
        uci show firewall.lan_to_wan_block
    else
        LAN_WAN_TARGET=$(uci -q get firewall.@forwarding[0].target)
        echo "Killswitch State (@forwarding[0].target) [v22 Method]:"
        if [ -z "$LAN_WAN_TARGET" ]; then
            echo "   Current state: Not set (Implies ACCEPT - Normal)"
        else
            echo "   Current state: ${LAN_WAN_TARGET}"
        fi

        if [ "$LAN_WAN_TARGET" = "REJECT" ]; then
            echo "   Killswitch is correctly set to REJECT."
        else
            echo "   Warning: State is not REJECT. Killswitch may not be active."
        fi
    fi
    echo "-------------------------------------"
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
        echo "Usage: $0 {enable|disable|status [--verbose|-v]}"
        exit 1
        ;;
esac

exit 0
