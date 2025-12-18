# Tailscale Installation Guide for OpenWrt

## Prerequisites

- OpenWrt 22.x, 23.x, or 24.x router
- SSH access to the router
- Physical/console access recommended for initial setup

## Installation

### Option 1: Download from Releases

```bash
# SSH into your router
ssh root@<router-ip>

# Download the package for your architecture
cd /tmp

# For mips_24kc (GL.iNet E750, AR750S, etc.)
wget https://github.com/coreyleavitt/tailscale-openwrt/releases/latest/download/tailscale_1.92.3_mips_24kc.ipk

# For aarch64_cortex-a53 (Cudy TR3000, etc.)
wget https://github.com/coreyleavitt/tailscale-openwrt/releases/latest/download/tailscale_1.92.3_aarch64_cortex-a53.ipk

# Install
opkg install tailscale_*.ipk
```

### Option 2: Build from Source

```bash
git clone https://github.com/coreyleavitt/tailscale-openwrt.git
cd tailscale-openwrt/tailscale-package
./build.sh 1.92.3

# Transfer to router
scp packages/tailscale_1.92.3_*.ipk root@<router-ip>:/tmp/

# Install on router
ssh root@<router-ip> "opkg install /tmp/tailscale_*.ipk"
```

## What Gets Installed

The package automatically configures:

- **Network interface**: `tailscale` (device: tailscale0)
- **Firewall zone**: `tailscale` with masquerading
- **Forwarding rules**: LAN <-> Tailscale bidirectional
- **Memory tuning**: Auto-detected based on available RAM

No manual network or firewall configuration needed.

## Initial Setup

### Step 1: Enable and Start Service

```bash
uci set tailscale.config.enabled='1'
uci commit tailscale
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
```

Or use the setup helper:
```bash
tailscale-setup
```

### Step 2: Authenticate

**Do this from a LAN connection, not remotely!**

```bash
tailscale up --ssh
```

Follow the URL shown to authenticate with your Tailscale account.

The `--ssh` flag is important - it allows SSH access via Tailscale if you get locked out.

### Step 3: Verify Connection

```bash
tailscale status
```

You should see your router listed along with other devices on your tailnet.

## Exit Node Configuration

### Finding Your Exit Node

On another device or in the Tailscale admin console, find the IP of your exit node:

```bash
tailscale status
# Look for a device marked as "offers exit node"
```

### Configuring the Router

```bash
tailscale up --exit-node=100.x.x.x --exit-node-allow-lan-access --ssh
```

**Important flags:**
- `--exit-node=100.x.x.x` - The Tailscale IP of your exit node (use IP, not hostname)
- `--exit-node-allow-lan-access` - **Required!** Allows LAN devices to still access the router
- `--ssh` - Allows SSH recovery via Tailscale

### Verify Exit Node

```bash
# Check that exit node is active
tailscale status
# Should show "exit node; ..." for your exit node

# Test from a LAN device
curl ifconfig.me
# Should show the exit node's public IP, not your ISP's
```

## Killswitch

The killswitch provides leak protection by blocking all WAN traffic except through Tailscale.

### Enable Killswitch

```bash
tailscale-killswitch enable
```

This does three things:
1. **Blocks all LAN -> WAN traffic** - No direct internet access
2. **Blocks DNS to WAN** - Prevents DNS leaks from LAN clients
3. **Redirects router DNS to MagicDNS** - Prevents DNS leaks from the router itself

### Check Status

```bash
tailscale-killswitch status

# For detailed info
tailscale-killswitch status --verbose
```

### Disable Killswitch

```bash
tailscale-killswitch disable
```

This restores normal WAN routing and your original DNS configuration.

### How It Protects You

| Traffic Type | Killswitch OFF | Killswitch ON |
|-------------|----------------|---------------|
| LAN -> Internet | Via WAN | Blocked (must use Tailscale) |
| LAN -> Tailscale | Allowed | Allowed |
| LAN DNS queries | Via WAN DNS | Blocked to WAN |
| Router DNS queries | Via WAN DNS | Via MagicDNS (100.100.100.100) |

**If exit node fails with killswitch ON:**
- All internet traffic stops
- NO traffic leaks to your ISP
- Your real IP is never exposed

### Killswitch Persists Across Reboots

The killswitch state is stored in UCI:

```bash
uci get tailscale.config.killswitch
# Returns: 1 (enabled) or 0 (disabled)
```

On boot, the init script automatically re-applies killswitch rules if enabled.

### Verify No Leaks

1. **IP Leak Test**: Visit whatismyip.com from a LAN device - should show exit node IP
2. **DNS Leak Test**: Visit dnsleaktest.com - should show exit node's DNS servers
3. **Kill Test**: Stop tailscaled and verify no internet access:
   ```bash
   /etc/init.d/tailscale stop
   # From LAN device: ping 8.8.8.8 should fail
   /etc/init.d/tailscale start
   ```

## UCI Configuration Reference

```bash
# View all configuration
uci show tailscale

# Main config options
tailscale.config.enabled='1'       # Enable service (0/1)
tailscale.config.port='41641'      # Listen port
tailscale.config.killswitch='0'    # Killswitch state (0/1)
tailscale.config.log_level=''      # Verbosity (empty for default)
tailscale.config.extra_args=''     # Additional tailscaled arguments

# Hardware-detected settings (set by postinst)
tailscale.hardware.mem_limit=''    # GOMEMLIMIT (e.g., '50MiB')
tailscale.hardware.gogc=''         # GOGC value (e.g., '50')
tailscale.hardware.no_logs='0'     # Use --no-logs-no-support
tailscale.hardware.has_wwan='0'    # Watch WWAN interfaces
```

## Troubleshooting

### Router Loses Internet After Exit Node

**Cause:** Exit node is unreachable or routing misconfigured

**Fix:**
```bash
# Remove exit node
tailscale up --exit-node= --ssh

# Or specify a different exit node
tailscale up --exit-node=100.x.x.x --exit-node-allow-lan-access --ssh
```

### Locked Out of Router

**Option 1: SSH via Tailscale** (if --ssh was used)
```bash
ssh root@<router-tailscale-ip>
```

**Option 2: Physical access**
1. Connect via serial console or physical ethernet
2. Disable tailscale: `/etc/init.d/tailscale disable`
3. Reboot and reconfigure

**Option 3: Factory reset** (last resort)
- Hold reset button for 10+ seconds

### Killswitch Blocks Everything

If you enabled killswitch but Tailscale isn't connected:

```bash
# Disable killswitch to restore WAN access
tailscale-killswitch disable

# Then fix Tailscale connection
tailscale up --ssh
```

### DNS Not Working

```bash
# Check DNS configuration
tailscale-killswitch status --verbose

# If killswitch is on, ensure MagicDNS is configured in Tailscale admin
# Visit: https://login.tailscale.com/admin/dns
```

### View Logs

```bash
logread | grep tailscale
```

## Common Commands

```bash
# Service management
/etc/init.d/tailscale start
/etc/init.d/tailscale stop
/etc/init.d/tailscale restart
/etc/init.d/tailscale enable
/etc/init.d/tailscale disable

# Tailscale CLI
tailscale status
tailscale up --exit-node=100.x.x.x --exit-node-allow-lan-access --ssh
tailscale down
tailscale ping <device>

# Killswitch
tailscale-killswitch enable
tailscale-killswitch disable
tailscale-killswitch status
tailscale-killswitch status --verbose

# Setup helper
tailscale-setup
```

## Uninstalling

```bash
opkg remove tailscale
```

This automatically:
- Removes all firewall rules and zones
- Removes the network interface
- Restores original DNS configuration (if killswitch was enabled)
- Preserves `/var/lib/tailscale` for reinstallation

To completely remove all state:
```bash
opkg remove tailscale
rm -rf /var/lib/tailscale
```

## Important Notes

- **Always use `--ssh` flag** - Allows recovery via Tailscale SSH
- **Use exit node IP, not hostname** - More reliable
- **Test from LAN first** - Don't configure remotely without a backup plan
- **Keep physical access** - During initial setup, have console access ready
- **MagicDNS required for killswitch** - Enable it in Tailscale admin console
