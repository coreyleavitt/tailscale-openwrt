# LuCI App for Tailscale Killswitch

Modern JavaScript-based LuCI interface for managing Tailscale exit node killswitch on OpenWrt routers.

## Features

- Modern JavaScript UI (future-proof, no legacy Lua CBI)
- Real-time killswitch status display
- One-click enable/disable killswitch
- JSON-RPC backend via ubus
- Proper ACL permissions
- Compatible with OpenWrt 22.x, 23.x, 24.x+

## Prerequisites

- OpenWrt router with LuCI installed
- Tailscale package installed (`tailscale`)
- `tailscale-killswitch` script at `/usr/sbin/tailscale-killswitch`

### Package Dependencies

**Required:**
- `tailscale` - Tailscale VPN client (version 1.30+)
- `luci-base` - LuCI web interface framework

**Recommended:**
- `jsonfilter` - For efficient JSON parsing (falls back to grep/sed if unavailable)

**Note:** The package declares `+tailscale` as a dependency in the Makefile, which will be automatically installed. The `jsonfilter` package is recommended for better performance but the app will work without it using fallback text parsing methods.

## Building

### Using Docker (Recommended)

```bash
cd luci-app-tailscale
docker build -t luci-app-tailscale .
docker run --rm luci-app-tailscale cat /luci-app-tailscale_1.0.ipk > luci-app-tailscale_1.0.ipk
```

### Manual Build

```bash
cd luci-app-tailscale
chmod +x build-ipk.sh
./build-ipk.sh
```

## Installation

1. Copy IPK to router:
```bash
scp luci-app-tailscale_1.0.ipk root@<router-ip>:/tmp/
```

2. Install on router:
```bash
ssh root@<router-ip>
opkg install /tmp/luci-app-tailscale_1.0.ipk
```

3. Restart services:
```bash
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

4. Access via LuCI: **Services → Tailscale**

## Usage

The web interface provides:
- **Current Status**: Shows if killswitch is enabled/disabled
- **Enable/Disable Buttons**: Toggle killswitch with one click
- **Refresh**: Update status display

## Architecture

- **Frontend**: `/www/luci-static/resources/view/tailscale/killswitch.js` (Modern JS view)
- **Backend**: `/usr/libexec/rpcd/luci.tailscale` (ubus RPC handler)
- **ACL**: `/usr/share/rpcd/acl.d/luci-app-tailscale.json` (Permissions)
- **Menu**: `/usr/share/luci/menu.d/luci-app-tailscale.json` (Navigation)

## Uninstallation

```bash
opkg remove luci-app-tailscale
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

## Development

This app follows modern LuCI development practices:
- JavaScript views (no Lua CBI)
- JSON-RPC via ubus
- Promise-based async operations
- Proper error handling and notifications

## License

Apache-2.0
