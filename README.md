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

**apk feed (OpenWrt 25.12+):** the signed feed publishes every
Go-targetable OpenWrt architecture -- 30 arches across 14 build families --
so `apk add tailscale` works generically, keyed off the device's own
`/etc/apk/arch`:

```bash
apk add tailscale   # arch is read automatically from /etc/apk/arch
```

A `404` on `apk update` means either a handful of arches Go itself cannot
target (never published -- the installer detects and names these before
touching the feed) or a transient publish gap, not a hard cap on coverage.
See the [Installation Guide](docs/INSTALL.md#option-3-openwrt-2512-apk-feed)
for the full arch table (`arches.json`) and the
[unverified tier](docs/INSTALL.md#unverified-tier) (arches that are built
and published but not CI-boot-verified).

**ipk releases (OpenWrt 22.03-24.10):** four device-targeted arches, built
and downloadable from [Releases](https://github.com/coreyleavitt/tailscale-openwrt/releases)
(ipk does not widen with the apk feed -- see
[docs/MAINTAINING.md](docs/MAINTAINING.md)):

| Architecture | Devices | OpenWrt Version |
|-------------|---------|-----------------|
| aarch64_cortex-a53 | GL-MT2500, GL-MT3000, Cudy M3000 | 22.03+ |
| arm_cortex-a7 | GL-AR750, ipq40xx devices, RPi 2 | 22.03+ |
| mips_24kc | GL.iNet E750, AR750S | 22.03+ |
| mipsel_24kc | Cudy LT400E, WR1300S, MT7621/MT7628 | 22.03+ |

## Quick Start

### Which Install Path?

| OpenWrt release | How to detect | Install path |
|---|---|---|
| 25.12+ | `. /etc/openwrt_release; echo $DISTRIB_RELEASE` shows `25.x`, or `apk` exists on PATH | **apk** (signed feed, trusted `apk add`) |
| 22.03 - 24.10 | `$DISTRIB_RELEASE` shows `22.x`/`23.x`/`24.x`, or `apk` is absent | **ipk** (`opkg install` a downloaded package) |
| GL.iNet firmware 4.x | `/etc/glversion` exists | **glinet** (binary swap over the stock `gl-sdk4-tailscale` package) |

`scripts/install.sh` runs this detection for you and dispatches to the right
path automatically:

```bash
wget -qO- https://raw.githubusercontent.com/coreyleavitt/tailscale-openwrt/master/scripts/install.sh | sh
```

Force a path with `--path apk|ipk|glinet` if auto-detection picks the wrong
one, or add `-y` to skip confirmation prompts.

### Stock OpenWrt

Download from [Releases](https://github.com/coreyleavitt/tailscale-openwrt/releases):

```bash
cd /tmp
wget https://github.com/coreyleavitt/tailscale-openwrt/releases/latest/download/tailscale_1.94.1_mips_24kc.ipk
opkg install tailscale_*.ipk
```

### OpenWrt 25.12+ (apk)

OpenWrt 25.12 replaced `opkg`/`.ipk` with the `apk` package manager. This
repo publishes a **signed apk feed** so `apk add tailscale` works with no
`--allow-untrusted` flag:

```bash
wget -qO- https://raw.githubusercontent.com/coreyleavitt/tailscale-openwrt/master/scripts/install.sh | sh
```

Or manually:

```bash
mkdir -p /etc/apk/keys /etc/apk/repositories.d
wget -O /etc/apk/keys/tailscale.pem https://apk.leavitt.dev/apk/keys/tailscale.pem
# Arch is taken from the device itself (/etc/apk/arch, e.g. aarch64_cortex-a53)
# -- no need to look yours up. NB: use /etc/apk/arch, not `apk --print-arch`,
# which prints the bare CPU family ("aarch64") and matches no feed dir.
echo "https://apk.leavitt.dev/apk/$(head -n1 /etc/apk/arch)/packages.adb" >> /etc/apk/repositories.d/customfeeds.list
apk update && apk add tailscale
```

The feed publishes all Go-targetable OpenWrt arches (see
[Supported Architectures](#supported-architectures)); `apk update` 404s only
if your specific arch isn't published yet or isn't Go-targetable at all. See
the [Installation Guide](docs/INSTALL.md#option-3-openwrt-2512-apk-feed)
for uninstalling, downgrading, and mirroring the feed.

**Note:** the LuCI web UI ([luci-app-tailscale](https://github.com/coreyleavitt/luci-app-tailscale))
is a separate, ipk-only project. This feed does not ship it -- `apk add
tailscale` gets the CLI and netifd protocol handler only.

### GL.iNet Routers (Firmware 4.x)

GL.iNet firmware includes `gl-sdk4-tailscale` which conflicts with the full IPK. Use the install script to update just the binary:

```bash
wget -qO- https://raw.githubusercontent.com/coreyleavitt/tailscale-openwrt/master/scripts/install-glinet.sh | sh
```

Options:
```bash
# Install specific version
wget -qO- ... | sh -s -- -v 1.94.1

# List available versions
wget -qO- ... | sh -s -- -l
```

**Note:** Killswitch is not supported on GL.iNet firmware due to their mwan3-based routing infrastructure.

### Enable and Start (Stock OpenWrt)

```bash
uci set tailscale.config.enabled='1'
uci commit tailscale
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
```

### Authenticate

```bash
tailscale up --ssh
# Follow the URL to log in
```

Or for headless/automated setup, use an auth key:
```bash
uci set tailscale.config.authkey='tskey-auth-xxxxx'
uci commit tailscale
/etc/init.d/tailscale restart
```

### Configure Exit Node (Optional)

```bash
tailscale up --exit-node=<EXIT_NODE_IP> --exit-node-allow-lan-access --ssh
```

### Enable Killswitch (Recommended for Privacy, Stock OpenWrt Only)

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

- OpenWrt 22.x-24.10 (ipk path) or OpenWrt 25.12+ (apk path) -- see [Which
  Install Path?](#which-install-path)
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
