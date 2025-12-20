#!/bin/sh
#
# Tailscale Setup Helper for OpenWrt
# Guides new users through initial setup
#

# Centralized path configuration
TAILSCALE_STATEDIR="/etc/tailscale"

echo "========================================"
echo "  Tailscale Setup Helper for OpenWrt"
echo "========================================"
echo ""

# Check if already configured
if [ -f "${TAILSCALE_STATEDIR}/tailscaled.state" ]; then
    echo "Tailscale appears to be already configured."
    echo ""
    tailscale status 2>/dev/null && {
        echo ""
        echo "Current status shown above. Run 'tailscale-setup' again if you need help."
        exit 0
    }
fi

echo "This helper will guide you through setting up Tailscale on your OpenWrt router."
echo ""
echo "STEP 1: Enable and start the Tailscale service"
echo "-----------------------------------------------"
echo "Run the following commands:"
echo ""
echo "  uci set tailscale.config.enabled='1'"
echo "  uci commit tailscale"
echo "  /etc/init.d/tailscale enable"
echo "  /etc/init.d/tailscale start"
echo ""

echo "STEP 2: Authenticate with Tailscale"
echo "------------------------------------"
echo "Run:"
echo ""
echo "  tailscale up"
echo ""
echo "Follow the URL shown to log in to your Tailscale account."
echo "The router will appear in your Tailscale admin console."
echo ""

echo "STEP 3: Configure exit node (recommended for privacy)"
echo "------------------------------------------------------"
echo "To route all traffic through a Tailscale exit node:"
echo ""
echo "  tailscale status                    # Find your exit node IP"
echo "  tailscale up --exit-node=<IP> --exit-node-allow-lan-access"
echo ""
echo "The --exit-node-allow-lan-access flag ensures you can still access"
echo "local LAN devices while using the exit node."
echo ""

echo "STEP 4: Enable killswitch (recommended for security)"
echo "-----------------------------------------------------"
echo "The killswitch blocks all WAN traffic except through Tailscale."
echo "If the exit node goes down, NO traffic leaks to your ISP."
echo ""
echo "  tailscale killswitch enable"
echo ""
echo "To check status:  tailscale killswitch status"
echo "To disable:       tailscale killswitch disable"
echo ""

echo "IMPORTANT NOTES"
echo "---------------"
echo "- Keep Tailscale SSH enabled (--ssh) so you can recover if locked out"
echo "- Test the killswitch by stopping tailscaled and verifying no internet"
echo "- Run DNS leak tests (dnsleaktest.com) to verify protection"
echo ""

echo "QUICK START (copy/paste all at once):"
echo "--------------------------------------"
echo ""
echo "uci set tailscale.config.enabled='1' && uci commit tailscale"
echo "/etc/init.d/tailscale enable && /etc/init.d/tailscale start"
echo "tailscale up --ssh"
echo ""

echo "For more help: https://tailscale.com/kb/1019/subnets"
echo "========================================"
