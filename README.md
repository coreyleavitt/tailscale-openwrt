# Tailscale for OpenWrt

Complete Tailscale packaging solution for OpenWrt routers with exit node killswitch support and modern LuCI web interface.

## Project Structure

```
.
├── tailscale-package/      # Core Tailscale IPK packages
│   ├── Dockerfile          # Docker build for Tailscale binary
│   ├── build.sh            # Build script for GL.iNet and Cudy variants
│   └── src/                # Init scripts, configs, killswitch
├── luci-app-tailscale/     # Modern JavaScript LuCI web interface
│   ├── htdocs/             # JavaScript views
│   ├── root/               # RPC backend, ACL, menu
│   ├── Dockerfile          # Docker build for LuCI app
│   └── build.sh            # Build script
├── docs/                   # Documentation
│   ├── INSTALL.md          # Installation guide
│   └── reset-firewall.sh   # Emergency firewall reset utility
└── packages/               # Build output (gitignored)
```

## Components

### 1. Tailscale Package (`tailscale-package/`)

Pre-built Tailscale binaries packaged for specific OpenWrt architectures:
- **GL.iNet AR750S** - `mips_24kc`
- **Cudy TR3000** - `aarch64_cortex-a53`

**Includes:**
- Tailscale v1.88.3 (compressed with UPX)
- procd init scripts
- UCI configuration
- Killswitch script

**Build:**
```bash
cd tailscale-package
./build.sh 1.88.3
```

### 2. LuCI Web Interface (`luci-app-tailscale/`)

Modern JavaScript-based LuCI application for managing Tailscale killswitch.

**Features:**
- Real-time status display
- One-click enable/disable
- JSON-RPC backend (ubus)
- Compatible with OpenWrt 22.x, 23.x, 24.x+

**Build:**
```bash
cd luci-app-tailscale
docker build -t luci-app-tailscale .
docker run --rm luci-app-tailscale cat /luci-app-tailscale_1.0.ipk > luci-app-tailscale_1.0.ipk
```

## Quick Start

### Installation

1. **Install Tailscale package:**
```bash
scp packages/tailscale-*.ipk root@<router-ip>:/tmp/
ssh root@<router-ip>
opkg install /tmp/tailscale-*.ipk
```

2. **Install LuCI app (optional):**
```bash
scp luci-app-tailscale/luci-app-tailscale_1.0.ipk root@<router-ip>:/tmp/
ssh root@<router-ip>
opkg install /tmp/luci-app-tailscale_1.0.ipk
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

### Setup

See [docs/INSTALL.md](docs/INSTALL.md) for detailed setup instructions including:
- Tailscale authentication
- Exit node configuration
- Killswitch setup
- DNS configuration
- Troubleshooting

## Features

- Direct binary builds (no SDK overhead)
- Multi-architecture support
- Exit node with WWAN compatibility
- Leak-proof killswitch
- Modern LuCI web interface
- DNS leak prevention
- UCI configuration
- Auto-start on boot

## Supported Devices

- GL.iNet E750 / AR750S (mips_24kc)
- Cudy TR3000 (aarch64_cortex-a53)
- Other OpenWrt routers (build for your architecture)

## Requirements

- OpenWrt 22.x, 23.x, or 24.x
- Kernel modules: `kmod-tun`, `ca-bundle`
- For LuCI app: `luci-base`, `rpcd`

## License

Apache-2.0

## Contributing

Pull requests welcome. Please test on actual hardware before submitting.
