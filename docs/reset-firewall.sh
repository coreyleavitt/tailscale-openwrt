#!/bin/sh
# Aggressive firewall reset - removes all Tailscale killswitch config

echo "Aggressively resetting firewall..."

# Remove in REVERSE order to avoid index shifting issues
# Remove ALL zones named 'ts' (check all indices backwards)
for i in 9 8 7 6 5 4 3 2 1 0; do
    ZONE_NAME=$(uci -q get firewall.@zone[$i].name 2>/dev/null)
    if [ "$ZONE_NAME" = "ts" ]; then
        echo "Removing zone at index $i"
        uci delete firewall.@zone[$i]
    fi
done

# Remove ALL forwardings named 'lan_to_ts_forwarding' (backwards)
for i in 9 8 7 6 5 4 3 2 1 0; do
    FWD_NAME=$(uci -q get firewall.@forwarding[$i].name 2>/dev/null)
    if [ "$FWD_NAME" = "lan_to_ts_forwarding" ]; then
        echo "Removing forwarding at index $i"
        uci delete firewall.@forwarding[$i]
    fi
done

# Also check for forwardings with dest='ts' (catch any strays)
for i in 9 8 7 6 5 4 3 2 1 0; do
    FWD_DEST=$(uci -q get firewall.@forwarding[$i].dest 2>/dev/null)
    if [ "$FWD_DEST" = "ts" ]; then
        echo "Removing orphaned ts forwarding at index $i"
        uci delete firewall.@forwarding[$i]
    fi
done

# Ensure lan->wan forwarding exists and is enabled
if ! uci -q get firewall.@forwarding[0] >/dev/null 2>&1; then
    echo "Creating lan->wan forwarding rule"
    uci add firewall forwarding
    uci set firewall.@forwarding[0].src='lan'
    uci set firewall.@forwarding[0].dest='wan'
fi
uci set firewall.@forwarding[0].enabled='1'

# Commit and restart
echo "Committing changes..."
uci commit firewall
echo "Restarting firewall..."
/etc/init.d/firewall restart

echo ""
echo "Firewall reset complete. Checking config..."
echo ""
uci show firewall | grep -E "forwarding|zone.*name"
echo ""
echo "✓ Reset complete. You should only see lan/wan zones above."
