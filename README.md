# Tailscale for OpenWrt

Pre-built Tailscale packages for OpenWrt routers with automatic network/firewall integration and exit node killswitch support.

## Features

- **Works out of the box** - Network interface and firewall zone created automatically on install
- **Exit node support** - Route all traffic through a Tailscale exit node
- **Killswitch** - Block all WAN traffic if exit node fails (no IP leaks)
- **DNS leak prevention** - Protects both LAN clients and router DNS queries
- **UCI configuration** - Standard OpenWrt config management
- **Auto-tuned** - Detects hardware and optimizes for available RAM
- **Fast builds** - UPX LZMA compression, ~2 minute CI builds

## Supported Architectures

| Architecture | Devices | OpenWrt Version |
|-------------|---------|-----------------|
| mips_24kc | GL.iNet E750, AR750S, and similar | 22.03+ |
| aarch64_cortex-a53 | Cudy TR3000 and similar | 24.10+ |

## Quick Start

### 1. Install

Download from [Releases](https://github.com/coreyleavitt/tailscale-openwrt/releases):

```bash
cd /tmp
wget https://github.com/coreyleavitt/tailscale-openwrt/releases/latest/download/tailscale_1.92.3_mips_24kc.ipk
opkg install tailscale_*.ipk
```

### 2. Enable and Start

```bash
uci set tailscale.config.enabled='1'
uci commit tailscale
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
```

### 3. Authenticate

```bash
tailscale up --ssh
# Follow the URL to log in
```

### 4. Configure Exit Node (Optional)

```bash
tailscale up --exit-node=<EXIT_NODE_IP> --exit-node-allow-lan-access --ssh
```

### 5. Enable Killswitch (Recommended for Privacy)

```bash
tailscale killswitch enable
```

The killswitch:
- Blocks all LAN to WAN traffic
- Redirects router DNS to Tailscale MagicDNS (100.100.100.100)
- If exit node fails, NO traffic leaks to your ISP

Check status: `tailscale killswitch status`

## Commands

| Command | Description |
|---------|-------------|
| `tailscale status` | Show connection status |
| `tailscale killswitch enable` | Enable WAN blocking killswitch |
| `tailscale killswitch disable` | Disable killswitch, restore normal routing |
| `tailscale killswitch status` | Check killswitch status |
| `tailscale exitnode enable` | Advertise this router as an exit node |
| `tailscale exitnode disable` | Stop advertising as exit node |
| `tailscale exitnode status` | Check exit node status |
| `tailscale-setup` | First-run setup helper |

## UCI Configuration

```bash
# View config
uci show tailscale

# Key options
uci set tailscale.config.enabled='1'      # Enable service
uci set tailscale.config.killswitch='1'   # Enable killswitch
uci set tailscale.config.port='41641'     # Listen port
uci commit tailscale
```

## Project Structure

```
.
├── tailscale-package/      # Core Tailscale IPK packages
│   ├── Dockerfile          # Docker build for cross-compilation
│   ├── build.sh            # Local build script
│   └── src/                # Init scripts, configs, killswitch
├── docs/                   # Documentation
│   └── INSTALL.md          # Detailed installation guide
└── .github/workflows/      # CI/CD automation
```

## Building from Source

```bash
cd tailscale-package
./build.sh 1.92.3
```

Output: `packages/tailscale_1.92.3_*.ipk`

## How It Works

### On Install (postinst)
- Creates `tailscale` network interface
- Creates `tailscale` firewall zone with masquerading
- Adds LAN <-> Tailscale forwarding rules
- Detects hardware and configures memory optimizations

### Killswitch Enabled
- Adds firewall rules blocking LAN -> WAN
- Redirects router DNS to Tailscale MagicDNS
- Traffic can ONLY flow through Tailscale
- Persists across reboots (stored in UCI)

### On Uninstall (postrm)
- Removes all firewall rules and zones
- Restores original DNS configuration
- Cleans up network interface

## Requirements

- OpenWrt 22.x, 23.x, or 24.x
- Packages: `kmod-tun`, `ca-bundle`, `ip-full`

## Documentation

- [Installation Guide](docs/INSTALL.md) - Detailed setup instructions
- [Killswitch Details](docs/INSTALL.md#killswitch) - How the killswitch protects you

## Related Projects

- [luci-app-tailscale](https://github.com/coreyleavitt/luci-app-tailscale) - LuCI web interface for Tailscale

## License

Apache-2.0

## Contributing

Pull requests welcome. Please test on actual hardware before submitting.
