# Field report: GOMEMLIMIT is silently dropped by a procd bug — and applying it breaks tailscaled on low-RAM devices

*Source: field testing on a Cudy WR3000S (OpenWrt 25.12, mediatek/filogic, ~234 MB
RAM), tailscale 1.98.9 from this feed. Preserved here because the fix (drop
GOMEMLIMIT, tune with GOGC alone) is driven by these findings.*

## Two related problems in `start_service` memory tuning (`tailscale-package/src/tailscale.init`)

### Issue 1 — GOMEMLIMIT is never actually applied (procd bug)
The init set two env vars with `procd_set_param env` back-to-back:
```sh
[ -n "$mem_limit" ] && procd_set_param env GOMEMLIMIT="$mem_limit"
[ -n "$gogc" ]      && procd_set_param env GOGC="$gogc"
```
`procd_set_param env` **replaces** the env list on each call, so the second call
drops `GOMEMLIMIT`; only `GOGC` reaches tailscaled. Confirmed on the running
daemon: `tr '\0' '\n' < /proc/$(pidof tailscaled)/environ | grep -E 'GOMEMLIMIT|GOGC'`
→ `GOGC=75` only. So every tier that set both (e.g. `<96 MB` → 50MiB/50, `96–192 MB`
→ 75MiB) has effectively shipped **GOGC-only** tuning. The correct primitive for a
second env var is `procd_append_param env …`.

### Issue 2 — GOMEMLIMIT breaks tailscaled's data path when it *does* apply
After making `GOMEMLIMIT=80MiB` genuinely reach tailscaled on the 234 MB device,
tailscaled entered a broken-but-healthy-looking state:
- `tailscale status` connected, `netcheck` healthy, `tailscale ping <peer>` direct
  both directions — **but every TCP connection to a local service over the tunnel
  timed out** (SSH to the node's tailnet IP timed out from multiple peers).
- Confirmed **not** firewall (both `fw4 input_tailscale` and tailscale's `ts-input`
  accept `tailscale0` input).
- tailscaled RSS sat ~48 MB, well under the 80 MiB limit — not obviously starved.
- **Removing `GOMEMLIMIT` (keeping `GOGC=75`) restored it immediately and stably;**
  RSS stayed ~48–68 MB (vs ~90 MB fully uncapped).

Hypothesis (unconfirmed): the Go soft-memory-limit interferes with wgengine's
netmap/packet-filter processing (GC pressure during netmap application), stalling
the userspace packet filter for *local delivery* while low-rate keepalive/disco
keeps flowing. Working set scales with **netmap size**, not device RAM.

The dangerous part is the **silent, asymmetric failure signature**: ping/disco up,
status/netcheck healthy, RSS fine — but real traffic dropped. Easy to misattribute
to firewall/DNS/NAT.

*Causality caveat: strong empirical correlation (apply → broke; remove → fixed
immediately and stably), not a controlled A/B — not re-applied, to avoid re-losing
remote access. Worth reproducing on a bench device.*

## Why this mattered: Issue 1 masked Issue 2
The package accidentally shipped GOGC-only tuning (which works). Fixing the procd
bug **without** revisiting GOMEMLIMIT would enable GOMEMLIMIT on the low-RAM tiers
at 50MiB/75MiB — *more aggressive than the 80MiB that broke a 234 MB device* —
likely breaking tailscale on the smallest routers this feature exists to protect.

## Resolution (applied)
1. **Drop GOMEMLIMIT; tune with GOGC alone.** `GOGC=75` took RSS ~90 MB → ~48–68 MB,
   bounded, zero connectivity impact. GOGC is a growth-*rate* control with no hard
   ceiling to starve the working set — the safer lever for a latency/throughput-
   sensitive daemon.
2. **Fix the `set`→`append` procd bug regardless** — it's a genuine correctness bug
   for any case that sets 2+ env vars — landed together with (1) so it can't
   regress low-RAM devices.
3. **Docs note on the failure mode:** *disco/ping up, TCP-to-local-services dropped*
   → suspect the memory limit, not the firewall.
