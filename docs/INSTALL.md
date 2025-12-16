# Tailscale Installation Guide for OpenWrt

## Prerequisites

- OpenWrt router (GL.iNet E750/AR750S or Cudy TR3000)
- Built IPK package for your architecture
- SSH access to the router

## Installation Steps

### 1. Transfer IPK to Router

```bash
scp packages/tailscale-<variant>_<version>.ipk root@<router-ip>:/tmp/
```

### 2. Install Package

```bash
ssh root@<router-ip>
opkg install /tmp/tailscale-<variant>_<version>.ipk
```

### 3. Configure Tailscale (DO NOT ENABLE YET)

```bash
# Configure but keep disabled initially
uci set tailscale.config.enabled='1'
uci commit tailscale
```

### 4. Authenticate WITHOUT Exit Node First

**IMPORTANT: Do this from LAN/WiFi connection, not remote!**

```bash
# Start service manually (not enabled for boot yet)
service tailscale start

# Authenticate without exit node
tailscale up --ssh
```

This creates authentication state without modifying routes.

### 5. Verify Basic Connectivity

```bash
# Check status
tailscale status

# Ensure SSH still works from LAN
# Exit and reconnect via SSH to verify
```

### 6. Configure Exit Node (Optional)

**CRITICAL: Only do this after verifying step 5 works!**

Get valid exit node name from another device:
```bash
tailscale status  # Run on another device to see available exit nodes
```

Then on router, use the **IP address** (safer than hostname):
```bash
tailscale up --exit-node=100.x.x.x --exit-node-allow-lan-access --ssh
```

**Flags explained:**
- `--exit-node=100.x.x.x` - Use this device as exit node (use IP, not hostname!)
- `--exit-node-allow-lan-access` - REQUIRED: Allows LAN devices to still access router
- `--ssh` - Allows SSH access even when using exit node

### 7. Verify Exit Node Works

```bash
# Check routes are correct
ip route

# Verify SSH still works from LAN
# Exit and reconnect to confirm

# Check exit node is active
tailscale status
```

### 8. Enable Auto-Start (Only After Verification)

**ONLY enable auto-start after confirming everything works:**

```bash
/etc/init.d/tailscale enable
```

### 9. Test Reboot

```bash
reboot
```

After reboot, verify:
- Router comes back up
- SSH from LAN still works
- Tailscale reconnects automatically
- Exit node is active (if configured)

## Troubleshooting

### Router Hangs After Enabling Tailscale

**Cause:** Invalid exit node hostname or routing conflict

**Recovery:**
1. Power cycle router
2. Immediately SSH in before Tailscale starts
3. Disable: `/etc/init.d/tailscale disable`
4. Review configuration and use IP addresses instead of hostnames

### SSH Blocked After Exit Node

**Cause:** Missing `--exit-node-allow-lan-access` flag

**Recovery:**
1. Reset router (hold reset button 10+ seconds)
2. Reinstall and follow steps correctly

### Cannot Remove Package

```bash
opkg remove tailscale-<variant>
```

## Common Commands

```bash
# Start/stop service
service tailscale start
service tailscale stop
service tailscale restart

# Enable/disable auto-start
/etc/init.d/tailscale enable
/etc/init.d/tailscale disable

# Check status
tailscale status

# Change exit node
tailscale up --exit-node=100.x.x.x --exit-node-allow-lan-access --ssh

# Disable exit node
tailscale up --exit-node= --ssh

# View logs
logread | grep tailscale
```

## Important Notes

- **Always test from LAN/WiFi first, never remotely**
- **Use exit node IP addresses, not hostnames**
- **Always include `--exit-node-allow-lan-access --ssh` flags**
- **Only enable auto-start after full verification**
- **Keep physical access to router during initial setup**
