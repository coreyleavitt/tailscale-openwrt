#!/bin/sh
#
# Tailscale Exit Node Killswitch for OpenWrt 22.x, 23.x, and 24.x
# Blocks all WAN traffic except through Tailscale exit node.
# Includes DNS leak prevention for both LAN clients and router.
#
# The firewall zone is created by postinst and persists.
# This script only manages the blocking rules and router DNS config.
#

# --- Configuration ---
TAILSCALE_INTERFACE="tailscale0"
TAILSCALE_ZONE_NAME="tailscale"
LAN_ZONE_NAME="lan"
WAN_ZONE_NAME="wan"
DNS_BACKUP_FILE="/etc/tailscale/dns_backup"
MAGIC_DNS="100.100.100.100"
MAGIC_DNS_V6="fd7a:115c:a1e0::53"

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

verify_zone() {
    if ! uci -q get firewall.tailscale_zone >/dev/null; then
        echo "ERROR: Tailscale firewall zone not found."
        echo "This should have been created during package installation."
        echo "Try reinstalling the tailscale package."
        return 1
    fi
    return 0
}

reload_services() {
    echo "Applying changes..."
    uci commit firewall
    uci commit dhcp
    uci commit tailscale

    /etc/init.d/firewall reload 2>/dev/null || {
        echo "WARNING: Firewall reload failed"
    }
    /etc/init.d/dnsmasq restart 2>/dev/null || {
        echo "WARNING: dnsmasq restart failed"
    }
}

apply_blocking_rules() {
    # Add blocking rules (used by both enable and apply-rules)

    # 1. Block LAN to WAN traffic
    uci set firewall.lan_to_wan_block=rule
    uci set firewall.lan_to_wan_block.name='Block LAN to WAN (Killswitch)'
    uci set firewall.lan_to_wan_block.src="${LAN_ZONE_NAME}"
    uci set firewall.lan_to_wan_block.dest="${WAN_ZONE_NAME}"
    uci set firewall.lan_to_wan_block.target='REJECT'
    uci set firewall.lan_to_wan_block.family='any'

    # 2. Block DNS to WAN (prevent LAN client DNS leaks)
    uci set firewall.block_wan_dns=rule
    uci set firewall.block_wan_dns.name='Block WAN DNS (Killswitch)'
    uci set firewall.block_wan_dns.src="${LAN_ZONE_NAME}"
    uci set firewall.block_wan_dns.dest="${WAN_ZONE_NAME}"
    uci set firewall.block_wan_dns.dest_port='53'
    uci set firewall.block_wan_dns.proto='tcp udp'
    uci set firewall.block_wan_dns.target='REJECT'
    uci set firewall.block_wan_dns.family='any'

    # 3. Allow DNS to Tailscale zone
    uci set firewall.allow_ts_dns=rule
    uci set firewall.allow_ts_dns.name='Allow Tailscale DNS (Killswitch)'
    uci set firewall.allow_ts_dns.src="${LAN_ZONE_NAME}"
    uci set firewall.allow_ts_dns.dest="${TAILSCALE_ZONE_NAME}"
    uci set firewall.allow_ts_dns.dest_port='53'
    uci set firewall.allow_ts_dns.proto='tcp udp'
    uci set firewall.allow_ts_dns.target='ACCEPT'
    uci set firewall.allow_ts_dns.family='any'

    uci commit firewall
}

remove_blocking_rules() {
    # Remove blocking rules
    uci -q delete firewall.lan_to_wan_block
    uci -q delete firewall.block_wan_dns
    uci -q delete firewall.allow_ts_dns
    uci commit firewall
}

configure_router_dns() {
    # Redirect router's dnsmasq to use Tailscale MagicDNS
    echo "Configuring router DNS to use Tailscale MagicDNS..."

    # Backup current DNS servers
    uci -q get dhcp.@dnsmasq[0].server > "$DNS_BACKUP_FILE" 2>/dev/null || true

    # Point dnsmasq to Tailscale MagicDNS (both IPv4 and IPv6)
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server="$MAGIC_DNS"
    uci add_list dhcp.@dnsmasq[0].server="$MAGIC_DNS_V6"
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci commit dhcp
}

restore_router_dns() {
    # Restore router's original DNS configuration
    echo "Restoring router DNS configuration..."

    if [ -f "$DNS_BACKUP_FILE" ]; then
        uci -q delete dhcp.@dnsmasq[0].server
        while IFS= read -r server || [ -n "$server" ]; do
            [ -n "$server" ] && uci add_list dhcp.@dnsmasq[0].server="$server"
        done < "$DNS_BACKUP_FILE"
        uci -q delete dhcp.@dnsmasq[0].noresolv
        rm -f "$DNS_BACKUP_FILE"
    else
        # No backup, just remove our config
        uci -q delete dhcp.@dnsmasq[0].noresolv
    fi
    uci commit dhcp
}

enable_killswitch() {
    echo "Enabling Tailscale exit node killswitch..."
    get_openwrt_version
    echo "Detected OpenWrt major version: ${OPENWRT_MAJOR_VERSION}"

    verify_zone || return 1
    verify_interface

    # Clean up any existing rules first
    remove_blocking_rules

    # Set UCI state
    uci set tailscale.config.killswitch='1'

    # Apply blocking rules
    echo "Adding firewall blocking rules..."
    apply_blocking_rules

    # Configure router DNS
    configure_router_dns

    # Reload services
    reload_services

    # Flush existing direct-to-WAN connections (not Tailscale-routed)
    # This prevents stateful connection leaks from before killswitch was enabled
    wan_iface=$(ip route | grep default | awk '{print $5}')
    if [ -n "$wan_iface" ]; then
        echo "Flushing existing direct-WAN connections..."
        # IPv4
        wan_ip=$(ip -4 addr show "$wan_iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
        [ -n "$wan_ip" ] && conntrack -D --reply-dst "$wan_ip" 2>/dev/null || true
        # IPv6 (exclude link-local fe80::)
        wan_ip6=$(ip -6 addr show "$wan_iface" 2>/dev/null | awk '/inet6 / && !/fe80/ {print $2}' | cut -d/ -f1 | head -1)
        [ -n "$wan_ip6" ] && conntrack -D --reply-dst "$wan_ip6" 2>/dev/null || true
    fi

    echo ""
    echo "Killswitch enabled successfully."
    echo "  - All LAN to WAN traffic blocked"
    echo "  - DNS redirected to Tailscale MagicDNS"
    echo "  - Traffic can only flow through Tailscale exit node"
}

disable_killswitch() {
    echo "Disabling Tailscale exit node killswitch..."

    # Set UCI state
    uci set tailscale.config.killswitch='0'

    # Remove blocking rules
    echo "Removing firewall blocking rules..."
    remove_blocking_rules

    # Restore router DNS
    restore_router_dns

    # Reload services
    reload_services

    echo ""
    echo "Killswitch disabled successfully."
    echo "  - Normal WAN routing restored"
    echo "  - Original DNS configuration restored"
}

apply_rules() {
    # Called by init script on startup if killswitch is enabled
    # Silently applies rules without full enable process
    local killswitch
    killswitch=$(uci -q get tailscale.config.killswitch)

    if [ "$killswitch" = "1" ]; then
        # Check if rules already exist
        if uci -q get firewall.lan_to_wan_block >/dev/null; then
            return 0  # Already applied
        fi

        logger -t tailscale "Applying killswitch rules on startup"
        apply_blocking_rules

        # Ensure DNS is configured
        if [ ! -f "$DNS_BACKUP_FILE" ]; then
            # First time after reboot, backup and configure DNS
            uci -q get dhcp.@dnsmasq[0].server > "$DNS_BACKUP_FILE" 2>/dev/null || true
        fi
        uci -q delete dhcp.@dnsmasq[0].server
        uci add_list dhcp.@dnsmasq[0].server="$MAGIC_DNS"
        uci add_list dhcp.@dnsmasq[0].server="$MAGIC_DNS_V6"
        uci set dhcp.@dnsmasq[0].noresolv='1'
        uci commit dhcp
        uci commit firewall

        /etc/init.d/firewall reload 2>/dev/null || true
        /etc/init.d/dnsmasq restart 2>/dev/null || true
    fi
}

check_status() {
    local killswitch
    killswitch=$(uci -q get tailscale.config.killswitch)

    if [ "$killswitch" = "1" ]; then
        echo "Killswitch: ENABLED (UCI)"

        # Check if rules are actually present
        if uci -q get firewall.lan_to_wan_block >/dev/null; then
            echo "Firewall rules: CONFIGURED"

            # Verify rules are loaded
            get_openwrt_version
            if [ "${OPENWRT_MAJOR_VERSION}" -ge "23" ]; then
                if command -v nft >/dev/null 2>&1; then
                    # Look for our specific rule comment containing "(Killswitch)"
                    if nft list ruleset 2>/dev/null | grep -qF "(Killswitch)"; then
                        echo "Firewall rules: ACTIVE"
                    else
                        echo "WARNING: Rules configured but may not be loaded. Try: /etc/init.d/firewall reload"
                    fi
                fi
            else
                if command -v iptables >/dev/null 2>&1; then
                    # Look for our specific rule comment containing "Killswitch"
                    if iptables -L FORWARD -nv 2>/dev/null | grep -qF "Killswitch"; then
                        echo "Firewall rules: ACTIVE"
                    else
                        echo "WARNING: Rules configured but may not be loaded. Try: /etc/init.d/firewall reload"
                    fi
                fi
            fi
        else
            echo "WARNING: Killswitch enabled but rules not present. Run: tailscale-killswitch enable"
        fi

        # Check DNS configuration
        local dns_server
        dns_server=$(uci -q get dhcp.@dnsmasq[0].server)
        if echo "$dns_server" | grep -qF "$MAGIC_DNS"; then
            echo "Router DNS: MagicDNS ($MAGIC_DNS, $MAGIC_DNS_V6)"
        else
            echo "WARNING: Router DNS not pointing to MagicDNS"
        fi

        return 0
    else
        echo "Killswitch: DISABLED"
        return 1
    fi
}

check_status_verbose() {
    check_status
    local status=$?

    echo ""
    echo "--- Detailed Configuration ---"

    echo ""
    echo "UCI State:"
    echo "  tailscale.config.killswitch = $(uci -q get tailscale.config.killswitch || echo '(not set)')"

    echo ""
    echo "Firewall Zone:"
    uci show firewall.tailscale_zone 2>/dev/null || echo "  (not configured - run postinst)"

    echo ""
    echo "LAN to WAN Block:"
    uci show firewall.lan_to_wan_block 2>/dev/null || echo "  (not configured)"

    echo ""
    echo "Block WAN DNS:"
    uci show firewall.block_wan_dns 2>/dev/null || echo "  (not configured)"

    echo ""
    echo "Allow Tailscale DNS:"
    uci show firewall.allow_ts_dns 2>/dev/null || echo "  (not configured)"

    echo ""
    echo "Router DNS Config:"
    echo "  Servers: $(uci -q get dhcp.@dnsmasq[0].server || echo '(default)')"
    echo "  noresolv: $(uci -q get dhcp.@dnsmasq[0].noresolv || echo '(not set)')"
    echo "  Backup exists: $([ -f "$DNS_BACKUP_FILE" ] && echo 'yes' || echo 'no')"

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
    return $status
}

# --- Main Logic ---
case "$1" in
    enable)
        enable_killswitch
        ;;
    disable)
        disable_killswitch
        ;;
    apply-rules)
        # Called by init script - silent operation
        apply_rules
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
        echo "  - Blocks all LAN to WAN traffic (IPv4 and IPv6)"
        echo "  - Redirects router DNS to Tailscale MagicDNS"
        echo "  - Prevents DNS leaks from both LAN clients and the router"
        echo "  - If Tailscale/exit node fails, NO traffic leaks to WAN"
        echo ""
        echo "State is stored in UCI: tailscale.config.killswitch"
        echo "Use 'uci show tailscale' to view configuration."
        exit 1
        ;;
esac

exit 0
