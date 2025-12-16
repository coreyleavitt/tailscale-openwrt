# Tailscale for OpenWrt

Pre-built Tailscale packages for OpenWrt routers with exit node killswitch support.

## Project Structure

```
.
├── tailscale-package/      # Core Tailscale IPK packages
│   ├── Dockerfile          # Docker build for Tailscale binary
│   ├── build.sh            # Build script for GL.iNet and Cudy variants
│   └── src/                # Init scripts, configs, killswitch
├── docs/                   # Documentation
│   ├── INSTALL.md          # Installation guide
│   └── reset-firewall.sh   # Emergency firewall reset utility
└── packages/               # Build output (gitignored)
```

## Features

- Direct binary builds (no SDK overhead)
- Multi-architecture support
- Exit node with WWAN compatibility
- Leak-proof killswitch
- DNS leak prevention
- UCI configuration
- Auto-start on boot

## Supported Architectures

| Device | Architecture | OpenWrt Version | Notes |
|--------|-------------|-----------------|-------|
| GL.iNet E750/AR750S | mips_24kc | 22.03.4 | 128MB RAM |
| Cudy TR3000 | aarch64_cortex-a53 | 24.10.3 | Uses `--no-logs-no-support` |

## Installation

### From Release

Download the latest IPK for your architecture from [Releases](https://github.com/coreyleavitt/tailscale-openwrt/releases):

```bash
cd /tmp
wget https://github.com/coreyleavitt/tailscale-openwrt/releases/latest/download/tailscale-<variant>_<version>.ipk
opkg install tailscale-*.ipk
```

### From Source

```bash
cd tailscale-package
./build.sh 1.92.2
```

Output packages are written to `packages/` directory.

## Setup

See [docs/INSTALL.md](docs/INSTALL.md) for detailed setup instructions including:
- Tailscale authentication
- Exit node configuration
- Killswitch setup
- DNS configuration
- Troubleshooting

## LuCI Web Interface

For a modern web interface to manage Tailscale, see [luci-app-tailscale](https://github.com/coreyleavitt/luci-app-tailscale).

Works with this package or any other Tailscale installation (OpenWrt official package, custom builds, etc.).

## Requirements

- OpenWrt 22.x, 23.x, or 24.x
- Kernel modules: `kmod-tun`, `ca-bundle`

## License

Apache-2.0

## Contributing

Pull requests welcome. Please test on actual hardware before submitting.
