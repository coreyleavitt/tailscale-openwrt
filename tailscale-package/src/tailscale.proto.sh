#!/bin/sh
#
# Tailscale netifd protocol handler
# Provides proper interface status for LuCI display
#

. /lib/functions.sh
. ../netifd-proto.sh

init_proto "$@"

proto_tailscale_init_config() {
    # No device binding - tailscale0 is created by tailscaled
    no_device=1
    # Interface can be brought up immediately
    available=1
}

proto_tailscale_setup() {
    local interface="$1"
    local ifname="tailscale0"

    # Wait for tailscaled to create the interface and get an IP
    local tries=0
    local max_tries=30
    local ipaddr=""

    while [ $tries -lt $max_tries ]; do
        # Check if tailscale0 exists
        if [ -d "/sys/class/net/$ifname" ]; then
            # Try to get the Tailscale IP
            ipaddr=$(/usr/bin/tailscale ip -4 2>/dev/null | head -1)
            if [ -n "$ipaddr" ]; then
                break
            fi
        fi
        tries=$((tries + 1))
        sleep 2
    done

    if [ -z "$ipaddr" ]; then
        proto_notify_error "$interface" "NO_TAILSCALE_IP"
        proto_block_restart "$interface"
        return 1
    fi

    # Report the interface to netifd
    # Note: We intentionally do NOT add routes here - Tailscale manages all
    # routing including the CGNAT range (100.64.0.0/10) and exit node routes.
    # Adding routes here interferes with Tailscale's routing table management.
    proto_init_update "$ifname" 1
    proto_add_ipv4_address "$ipaddr" 32
    proto_send_update "$interface"
}

proto_tailscale_teardown() {
    local interface="$1"
    # Nothing to do - tailscaled manages the interface lifecycle
}

add_protocol tailscale
