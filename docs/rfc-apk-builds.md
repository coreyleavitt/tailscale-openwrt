# RFC: OpenWrt 25 `.apk` build output + signed EC feed

- **Status:** Draft — architecture review **rounds 1 & 2 complete**; Stage 3 in
  progress. **B0 spike DONE** (`docs/rfc-apk-builds.b0-spike.md`); no open forks.
- **Author:** Corey Leavitt
- **Date:** 2026-07-19
- **Tracking:** `docs/rfc-apk-builds.handoff.md`

## 1. Summary

OpenWrt **25.12.0** (released 2026-03-08, now mainline) replaced `opkg`/`.ipk`
with the **apk** package manager (apk-tools 3, apk v3 ADB packages, a binary
`packages.adb` index). This repo currently produces `.ipk` only. This RFC adds
`.apk` build output **alongside** the existing `.ipk`, and publishes the `.apk`
artifacts as a **signed apk feed** so OpenWrt 25 users can run
`apk add tailscale` with no `--allow-untrusted`.

We keep building `.ipk` unchanged: OpenWrt 22.03–24.10 and **all** GL.iNet 4.x
firmware remain opkg/ipk. The two outputs are selected by **target OpenWrt
release**, not by device.

**Guiding constraint (from the outage post-mortem):** the ~2-month CI signing
outage was a *silent* failure — imprimatur reported `/health` 200 while every
`/sign` returned 503. Two design rules fall out of that and thread through this
RFC: (1) the new apk path must **never be able to block the working ipk path**
(failure isolation, §4.6), and (2) a signing failure must be **loud** —
detectable at deploy time and alerting at release time, not discoverable months
later.

## 2. Goals / Non-goals

**Goals**
- Produce a correct OpenWrt-25 `.apk` for the existing four arches
  (`aarch64_cortex-a53`, `arm_cortex-a7`, `mips_24kc`, `mipsel_24kc`), carrying
  the same payload (binary, init script, UCI config, wrappers, maintainer-script
  behavior) as the `.ipk`.
- Publish a **signed apk feed** (per-arch `packages.adb` signed with an EC
  `prime256v1` key) at a **stable, backend-portable HTTPS URL**, plus the public
  key and a one-line installer, so `apk add tailscale` is trusted with no flags.
- Extend **imprimatur** with EC signing, keeping the private key server-side
  (mirrors today's usign model), **without dragging apk-tools into the
  key-holding process** if the two-phase signing split (§4.2) is available.
  Leave the usign/ipk path untouched and un-blockable by EC-path faults.
- Verify every `.apk` and the signed feed **in CI without hardware**, using
  apk-tools inside a pinned OpenWrt 25.12 rootfs container.
- Fix the imprimatur silent-failure trap: multi-key `/health` that returns 503
  when a *required* key is missing (§4.2), plus **release-time failure alerting**
  (§4.6) so an outage surfaces immediately.

**Non-goals**
- Replacing `.ipk`. It stays, unchanged, for ≤24.10 and GL.iNet 4.x.
- GL.iNet-on-apk. GL.iNet 4.x is ipk-based; a future GL firmware on 25.x is out
  of scope here (the binary-only `install-glinet.sh` path is untouched).
- **The LuCI web UI (`luci-app-tailscale`).** That is a separate, ipk-only
  project; this RFC ships only the netifd *protocol* handler JS in the package
  payload, as today. apk users wanting the web app have no apk path in v1
  (documented, §4.4).
- **Staged / canary rollout.** v1 publishes **single-shot to 100%** of subscribed
  devices; C3's per-publish index-walk + the §4.3 monotonicity guard are the sole
  pre-publish gates (no testing→stable two-tier feed, no staggered publish,
  no automatic hold-previous-good). This is an explicit decision given the small
  arch/user surface, not an oversight; a two-tier `apk/<arch>/testing/`→promote
  layout is a documented later-stage option.
- **Multi-version feed retention.** v1 feed carries **latest per arch**.
  Consequence: a trusted *downgrade* is not possible from the feed — the
  documented rollback path is `--allow-untrusted` against a pinned release asset
  (§4.7). Multi-version retention is revisited by the O4 hosting decision.
- **Automatic EC key rotation.** v1 is **TOFU / pin-once** (O7, §4.2). Rotation
  is a documented manual re-provision; overlapping-key rotation is a later stage.
- Migrating the whole project to an OpenWrt-SDK-based build.
- Reproducible/bit-identical builds as a *verified* property. We keep builds
  deterministic where cheap (§3) but do not add a double-build-diff gate in v1.

## 3. Background: how OpenWrt 25 apk differs from ipk

Verified against openwrt.org, git.openwrt.org, `include/package-pack.mk`, and the
openwrt-devel/lede-commits lists (see `## 9. References`). The corrections below
overturned two initial assumptions (RSA signing; per-package signing) and are
the crux of the design.

| Concern | ipk (today) | apk (OpenWrt 25.12) |
|---|---|---|
| Package format | ar+tar `.ipk` via `opkg-build` | apk v3 ADB `.apk` via `apk mkpkg` |
| Index | none (loose files) | binary `packages.adb` |
| Arch names | OpenWrt triplets | **same** OpenWrt triplets |
| Version string | `1.98.8-1` | `1.98.8-r1` (`-rN` suffix) |
| Control metadata | `CONTROL/control` file | `apk mkpkg --info "field:val"` (repeatable) |
| conffiles | `CONTROL/conffiles` | staged file `lib/apk/packages/<name>.conffiles` |
| Maintainer scripts | `postinst`/`prerm`/`postrm` | `post-install`/`pre-deinstall`/`post-deinstall` (`--script`) |
| **Signing key** | usign / **ed25519** | OpenSSL **EC `prime256v1`** `.pem` |
| **What is signed** | detached `.sig` per `.ipk` | the **index** `packages.adb` (not per-package) |
| Trust on device | `signing.pub` (usign) | pubkey `.pem` in `/etc/apk/keys/` |
| Install a lone file | `opkg install ./f.ipk` | `apk add --allow-untrusted ./f.apk` (else `UNTRUSTED`) |

Key consequence: **apk trust flows from a signed feed, not a signed file.** A
lone `.apk` is always `UNTRUSTED`. To deliver the "`apk add tailscale`, no flags"
UX, we must publish a signed `packages.adb` feed and have users install our
public key + feed URL once.

Canonical build/sign recipe we are productionizing (from `package-pack.mk` +
OpenWrt apk docs). **Three corrections vs. the round-0 draft** — the output path
is **arch-namespaced** (§4.3 finding: four arches emitting an identical
`tailscale-1.98.8-r1.apk` would collide during the CI artifact merge and the
release upload); the staging root is an **apk-specific tree** that excludes the
ipk `CONTROL/` directory (else it ships onto the router as payload); and build-only
inputs (scripts, conffiles list) live in **sibling** dirs, never *inside* the
`--files` payload tree — see §4.1 for the `$PKGROOT` layout that makes a
scripts-as-payload leak structurally impossible:

```sh
# $PKGROOT/                 build root, NOT shipped
#   files/     = $ADIR      on-device payload ONLY, no CONTROL/ (see §4.1)
#     lib/apk/packages/tailscale.conffiles   -> lists /etc/config/tailscale
#   scripts/                maintainer scripts, siblings of files/ (NOT under $ADIR)
#     post-install pre-deinstall post-deinstall
#
# SOURCE_DATE_EPOCH: the GitHub source tarball's mtime IS the upstream commit
# time (GitHub sets archive mtimes to the tagged commit) — so we read it from
# the already-fetched tarball, NOT `git log` (there is no .git in the build
# context; the Dockerfile curls a source tarball — see §3 note below and A2).
# NOT 0 (0 yields 1970 on-device mtimes, indistinguishable from an unsynced RTC).
ADIR="$PKGROOT/files"
SOURCE_DATE_EPOCH="$(stat -c %Y "$TARBALL")"

SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" fakeroot apk mkpkg \
  --info "name:tailscale" --info "version:1.98.8-r1" --info "arch:$ARCH" \
  --info "description:Tailscale VPN client for OpenWrt" \
  --info "license:BSD-3-Clause" --info "maintainer:Community Build" \
  --info "depends:kmod-tun ca-bundle ip-full conntrack" \
  --files "$ADIR" \
  --script "post-install:$PKGROOT/scripts/post-install" \
  --script "pre-deinstall:$PKGROOT/scripts/pre-deinstall" \
  --script "post-deinstall:$PKGROOT/scripts/post-deinstall" \
  --output "out/$ARCH/tailscale-1.98.8-r1.apk"   # arch in the PATH, not name

# Build the UNSIGNED per-arch index in CI (imprimatur signs it — §4.2):
apk mkndx --output "out/$ARCH/packages.adb" out/$ARCH/*.apk
```

**`fakeroot` context:** `apk mkpkg` runs **host-native** (x86_64 CI runner /
build image) — it packages files, it does not execute target-arch code, so it
never runs under qemu (the qemu path is A4/A5 *install verification* only, §5).
`fakeroot` is only needed if `mkpkg` records ownership from the live filesystem;
the existing Dockerfile `RUN` is already root-context (no `USER`). **A1 resolved
this empirically: `fakeroot` is REDUNDANT and is not installed** — `apk mkpkg`
records packaged files as `nobody:nobody` regardless of the source file's real
ownership (it never consults live-FS ownership), so there is nothing to fake.

**`SOURCE_DATE_EPOCH` semantics:** the tarball-mtime value tracks the *upstream
Tailscale tag's* commit time, which is stable across re-runs of the same
`tailscale_version` (unlike this repo's HEAD, which drifts on unrelated packaging
commits). A `workflow_dispatch` rebuild of the same version is therefore
deterministic. Settle the exact expression in **A2** (tarball `stat`, or a
runner-side `--build-arg` from the GitHub tag API if the tarball mtime proves
unreliable on the SDK path).

**Stage B spike (B0) — RESOLVED; full evidence in `docs/rfc-apk-builds.b0-spike.md`.**
The naive question ("does `apk mkndx` support unsigned-index + separate-sign?") was
not sufficient, and the spike (apk-tools **v3.0.2** source — the version OpenWrt
25.12.0 ships — cross-checked against a real signed `packages.adb` and an OpenSSL
round-trip) answered the three load-bearing sub-questions:
- **(a) Separable, and apk-tools-free is achievable.** The signature is an
  **appended `ADB_BLOCK_SIG` block** (not a spliced fixed-offset placeholder), and a
  standalone `adbsign` applet proves index-build and index-sign are decoupled.
  imprimatur can produce the signature with **no apk-tools dependency** (§4.2a).
- **(b) Signed pre-image = 86 bytes:** `LE32(schema) ‖ {sign_ver=0x00,
  hash_alg=0x04(SHA512), id[16]} ‖ SHA512(ADB_BLOCK_ADB payload)`, SHA512-then-ECDSA
  signed. `id = SHA512(i2d_PublicKey(pubkey))[:16]`.
- **(c) Encoding = ASN.1 DER** `SEQUENCE{r,s}` (variable, ~70–72 B for P-256), via
  `EVP_DigestSign`/`EVP_DigestVerifyFinal` — **not** fixed-width raw `r‖s`. The
  silent-verify-failure risk is averted **by construction** as long as imprimatur
  signs via EVP (§4.2b); it would bite only a hand-rolled raw `r‖s`. **B2's unit
  test asserts DER** (0x30 prefix, two INTEGERs) and, end-to-end, that a real `apk
  verify` accepts an index we signed — not merely openssl self-consistency.

The apk-tools-free split (Design 1, §4.2a) is available, so the server-side `apk
mkndx --sign` fallback (slice B3a, vendoring the OpenWrt apk fork into imprimatur)
is **not expected to be needed**.

## 4. Design

### 4.1 apk package build (`tailscale-package/`)

Reuse the existing payload and maintainer-script *logic* verbatim; change the
packaging tool, the metadata surface, and the **staging root**.

- **Build-root layout makes payload leaks structurally impossible.** Use a
  `$PKGROOT` build root with three **siblings**: `files/` (= `$ADIR`, the
  on-device payload, the *only* tree passed to `--files`), `scripts/` (the three
  maintainer scripts, referenced by `--script` via `$PKGROOT/scripts/…`), and the
  conffiles list staged *inside* `files/` at apk's magic path
  `lib/apk/packages/tailscale.conffiles`. Because scripts live **outside** `$ADIR`,
  `--files "$ADIR"` cannot payload-ify them regardless of `mkpkg` behavior — this
  closes the round-1 `CONTROL/`-leak class at the level below it (round-1 caught
  the ipk `CONTROL/` dir; the round-0 recipe still put `scripts/` *under* `$ADIR`,
  reintroducing the same leak one level down). *Test (A2):* the built `.apk`
  on-device file list contains **no `CONTROL`-shaped path and no `scripts/` path**.
  (The `lib/apk/packages/tailscale.conffiles` file **is** on-device — see the
  conffiles bullet below; that is correct apk v3 behavior, not a leak.)
- **Package-name collision with OpenWrt's own `tailscale`.** OpenWrt's official
  `packages` feed ships `net/tailscale` (≥23.05) from the same `package-pack.mk`
  machinery, so 25.12 very likely publishes an official `tailscale` `.apk` too. A
  device with both the stock OpenWrt feed and our `customfeeds.list` entry then has
  **two `tailscale` providers**; apk resolves by repo/`provider-priority` order,
  and our `mkpkg` sets none — so `apk add tailscale` could silently pick the wrong
  build. *Required:* **verify empirically** whether 25.12's feed carries
  `tailscale` (fold into the B0 research window — it's the same "inspect a real
  25.12 `packages.adb`" task), and resolve deterministically — prefer **documenting
  a pinned/repo-priority install** (our feed's package chosen explicitly) over
  setting a high `provider-priority` (which would instead hijack the official
  package). *Test (Stage C):* install against a stub two-repo setup and assert
  which provider wins. Note also that ipk and apk are **disjoint package
  databases** — this is why the ipk→apk detection in §4.7/D3 must be
  filesystem-level, not apk `replaces:`/`conflicts:` metadata (apk cannot see an
  opkg-tracked install).
- Payload is the same set already assembled for ipk (`usr/sbin/tailscaled`,
  `usr/bin/tailscale` wrapper, `etc/init.d/tailscale`, `etc/config/tailscale`,
  the `/usr/sbin/tailscale-*` scripts, the LuCI protocol JS).
- Add `lib/apk/packages/tailscale.conffiles` listing `/etc/config/tailscale`.
  **Correction (A2, evidence-backed):** unlike ipk's build-only `CONTROL/conffiles`,
  apk v3 conffile protection is **payload-driven** — `apk mkpkg` has **no**
  `--info conffiles:` key, and upstream `include/package-pack.mk` deliberately
  `mv`s the conffiles list to `$IDIR/lib/apk/packages/<name>.conffiles` so it ships
  **as a real on-device file**. So this file **must be present in the payload with
  exact content** (`/etc/config/tailscale\n`); it is *not* excluded. *Test (A3b):*
  the built `.apk`'s on-device list **contains** `lib/apk/packages/tailscale.conffiles`
  with that content (was mis-specified as "not shipped").
- Reuse `src/tailscale.{postinst,prerm,postrm}` logic as `post-install`,
  `pre-deinstall`, `post-deinstall`.
- **O1 resolved — the maintainer scripts are NOT install-root-safe (confirmed).**
  `grep IPKG_INSTROOT tailscale-package/` is empty; the scripts unconditionally
  run `uci commit network/firewall/tailscale`, `/etc/init.d/{network,firewall,
  tailscale,dnsmasq}` reload/start against whatever `/etc` they execute with.
  Under an offline/rootfs-relative install (e.g. ImageBuilder baking the package
  into a firmware image — a first-class apk use case) they would mutate the
  **build host's** live network/firewall. Real defect, promoted from open question
  to required fix (slice **A3a**). But the guard is **not** a blanket no-op — that
  would silently ship a *broken baked image* (maintainer scripts run once at
  install time, never at first boot, so skipping config means the firmware boots
  with no `network.tailscale` interface, no firewall zone, no killswitch, service
  disabled). Split the mutating commands into **three categories** by
  `$IPKG_INSTROOT` (apk/opkg both set it):
  1. **Root-relative persistent state — *redirect*, don't skip:** uci config
     writes (`network`/`firewall`/killswitch include) and `/etc/init.d/tailscale
     enable` (rc.d symlink) must land in `$IPKG_INSTROOT/etc/…`, e.g. via
     `uci -c "$IPKG_INSTROOT/etc/config"` and prefixed symlink paths — so a baked
     image boots correctly configured.
  2. **Live-system actions — *no-op* under a non-empty root:** `/etc/init.d/{network,
     firewall,tailscale} reload/start`, `dnsmasq` reload (no live system to signal).
  3. **Build-host-observable reads — *skip/defer*:** the hardware-detection block
     reads `/proc/meminfo` to set `mem_limit`/`gogc`; under a bake this reads the
     **CI host's** RAM, baking wrong tuning into every image. Skip when
     `$IPKG_INSTROOT` is set and re-derive at first real boot (e.g. from
     `/etc/init.d/tailscale start` when unset).
  *Test (A3a):* run each script with `IPKG_INSTROOT=$(mktemp -d)` and assert
  **both** negatives (no host `uci commit`, no service reload, no host meminfo
  tuning applied) **and** positives (the interface/zone/rc.d symlink exist
  *inside* the scratch root, correctly configured).
- Map version `${TAILSCALE_VERSION}-${PKG_RELEASE}` →
  `${TAILSCALE_VERSION}-r${PKG_RELEASE}` (note: `PKG_RELEASE` defaults to `1`, so
  this is always `-r1`, never Alpine's conventional `-r0`; harmless — apk's
  numeric comparator is start-value agnostic).
- Arch names reused verbatim from the centralized matrix (§4.5).

### 4.2 imprimatur EC signing

`imprimatur` (Nim, ed25519/libsodium, source at
`/home/corey/homelab/stacks/infra/imprimatur/`, a **separate repo/deploy** —
`git@github.com:coreyleavitt/imprimatur.git`) gains an EC signer. The usign path
stays untouched **and structurally un-blockable** by EC faults (per-key model
below). Confirmed live-code facts driving this section: `/health` currently
returns `Http200` unconditionally (the outage mechanism), and there is a single
global `activeSigner` typed to usign — so the additions below are refactors, not
pure adds.

**(a) Trust boundary — sign a digest, not a package set (preferred).**
The round-0 `POST /sign-apk-index` design shipped the full `.apk` set into the
key-holding process and ran `apk mkndx --sign` there. That is a strictly larger
trust boundary than today's `/sign` (which never parses its input — it
base64-decodes bytes and signs them), and it runs a C parser the RFC's own risk
list flags as buggy (apk-tools 3.0.5 `.adb` bug) inside the one process that must
never crash or leak key material. **Preferred design (B0-refined = Design 1, `docs/rfc-apk-builds.b0-spike.md`):**
the signature is `EVP_DigestSign(sha512)` over a fixed **86-byte** pre-image
(`LE32(schema) ‖ 18-byte sig header ‖ SHA512(data block)`) → DER. Only that EVP
call needs the private key, so **CI frames the 86-byte pre-image** (it holds the
committed public key → can compute the key id) and imprimatur's `/sign/ec` stays a
pure `sign-these-bytes → DER` service — an **identical trust boundary to today's
usign `/sign`**, no apk-tools, no ADB parsing in the key-holding process. CI then
appends the `ADB_BLOCK_SIG` block and, before publish, reassembles the index and
runs a real `apk verify` in the pinned 25.12 container (C2/C3) so a CI-side
framing bug fails loudly in CI, never on a device. *Fallback if CI-side digest
extraction proves impractical (Design 3): imprimatur does a minimal ADB
block-framing parse itself — still apk-tools-free.* Extracting `md =
SHA512(db->adb)` from the unsigned index is the one deferred detail (the on-disk
data block is compressed), and it lives entirely in CI (has apk-tools, no key) —
a C2 concern, not a trust-boundary one.
**Routing is by registry key, not by artifact:** `POST /sign/:key` (e.g.
`/sign/usign`, `/sign/ec`) with **one** narrow in/narrow-out shape for all
signers — *not* a hand-named `/sign-adb-index` route per payload type. A
route-per-artifact scheme re-buries the payload's identity in the URL and forces
a new route (and a near-duplicate CI shell block) for every future signer — the
same "accreting scripts" problem §4.4 fixes for `install.sh`, one layer up.
`/sign/:key` is a direct reflection of the `Table[string, Signer]` registry
(§4.2c): a new signer needs zero route code, and CI gets **one** reusable
`sign_via_imprimatur(bytes, key)` helper reused for both ipk (`/sign/usign`) and
apk (`/sign/ec`) — collapsing the existing 20-line retry/verify block in
`build-tailscale.yaml` to a single call site. This is a pre-ship breaking change
to imprimatur's one internal caller (our own workflow) — no back-compat cost.
Feasibility of the unsigned-then-sign split is the **B0 spike** (expanded exit
criteria in §3); if unavailable, fall back to server-side `apk mkndx --sign`
(slice B3a vendors the OpenWrt apk fork into imprimatur — it currently has only
Alpine's stock apk).

**(b) Signer abstraction — factor algorithm out of the base type.** Today's
`Signer` is not algorithm-generic: its base `sign()` calls `usign.sign()`
directly and it carries a usign-typed `secretKey` field, so a parallel
`EcSigner` would inherit a dead, wrong-typed field and a bombs-if-called default.
Before adding EC, make the abstraction honest — separate the two orthogonal axes
(how key bytes are sourced vs. what crypto runs on them):

```nim
type
  KeySource = ref object of RootObj          # HOW bytes load (file, sops, …)
  SigAlgo   = ref object of RootObj          # WHAT crypto runs (ed25519, ecP256)
method loadBytes*(k: KeySource): string {.base.}
method importKey*(a: SigAlgo, raw: string)  {.base.}
method sign*(a: SigAlgo, msg: openArray[uint8]): seq[byte] {.base.}
method fingerprint*(a: SigAlgo): string {.base.}
method `=destroy`*(a: SigAlgo) {.base.}       # frees C-owned handles (EVP_PKEY)

type Signer = object                          # composition, not a 2×N subclass grid
  source: KeySource
  algo:   SigAlgo
  loaded: bool                                # set only by load(), atomically
proc load*(s: var Signer)                     # loadBytes -> importKey; flips loaded last
proc sign*(s: Signer, msg: openArray[uint8]): seq[byte]   # requires loaded
proc fingerprint*(s: Signer): string
proc isLoaded*(s: Signer): bool
```

`Signer` **owns its methods** — callers touch only `load()/sign()/fingerprint()/
isLoaded()`; `.source`/`.algo` are private two-hop internals, never orchestrated
by the caller (the round-1 sketch was a data bag: every call site had to hand-run
`algo.importKey(source.loadBytes())`, an interface exactly as wide as the impl —
the opposite of a deep module). `load()` owns **atomicity**: it flips `loaded`
only after *both* `loadBytes` and `importKey` succeed, so "algo constructed,
`importKey` never called, `sign()` invoked" is unrepresentable, and `/health`'s
per-key `{loaded, fingerprint}` (§4.2c) reads `isLoaded()`/`fingerprint()` off the
`Signer` — the state has a definite home. This collapses the looming
`{File,Sops}×{Ed25519,EcP256}` subclass matrix to 2+2 pieces and keeps HTTP
dispatch algorithm-blind. `EcP256Algo` wraps libcrypto `EVP_DigestSign*`
(`libcrypto.so.3` is already in the image; the builder needs `openssl-dev`) — the
O6 "FFI vs shell-out" question collapses to FFI, matching the existing
native-libsodium style. **Key-handle lifecycle:** `importKey` constructs a
C-owned `EVP_PKEY*` that Nim's GC does not track; it is a **one-shot call per
process lifetime** (rotation is an out-of-band redeploy, O7, not a hot reload), and
the `=destroy` hook frees it — so no handle leaks even though re-import never
happens in steady state. Exact refactor depth is settled in Stage B TDD; the
invariant is: **no ed25519-specific code in any shared base.**

**(c) Multi-key `/health` + fatal-but-scoped load (the outage fix, done right).**
Replace the single `activeSigner` with a registry:

```nim
var signers: Table[string, Signer]     # "usign", "ec"
# /health JSON: per-key {loaded, required, fingerprint}; HTTP 503 iff a REQUIRED
#   key is unloaded, else 200. Routes resolve by registry key:
#   POST /sign/:key -> signers[key]   (404 unknown key, 503 that key unloaded)
```

- `/health` returns **503 when any required key is unloaded** (the compose
  `wget --spider` probe then fails correctly), with per-key detail in the body.
  A per-key **503 route + `/health` 503 + alert is the *only* failure signal for a
  broken key — never a process exit** (see below).
- **Blast-radius control — no `quit(1)` after first successful boot.** The
  round-1 rule ("required-key-missing → `quit(1)`") is re-evaluated at *every*
  restart, not just the B4 flip — so a routine usign-side redeploy or a host
  reboot that coincides with a transiently-broken EC secret (permissions drift,
  stale mount, botched rotation) would `quit(1)` the **whole process and take the
  battle-tested usign/ipk path down with it** — the mirror image of the outage
  this RFC exists to prevent, and a violation of guiding-constraint #1 (§1) at the
  *process-liveness* layer even though per-key 503 satisfies it at the routing
  layer. **Rule:** a broken/missing key — required or not — degrades only *that
  key's* routes (503) and trips `/health` 503 + alert; it never exits the process
  once the listener is up. (`quit(1)` remains acceptable only for a hard config
  error at cold start before serving — e.g. a required key that is *malformed*,
  distinct from *absent* — but even absence is better handled as 503 so a flapping
  secret doesn't crash-loop the container.) This keeps the two keys genuinely
  isolated inside one small process without needing a second container.
- **Config — a signers block, not per-key env sprawl.** Rename the unprefixed
  `IMPRIMATUR_KEY_PATH` → `IMPRIMATUR_USIGN_KEY_PATH` (cheap now, breaking later)
  and add `IMPRIMATUR_EC_KEY_PATH`; but drive the registry from a single
  structured declaration (`IMPRIMATUR_SIGNERS` as JSON/TOML listing
  `{name, algo, source, path, required}` per signer) parsed once at startup, so
  the `signers` table *is* the config and adding a signer is data, not two
  independently-typed env strings a human must keep in sync. The per-key env vars
  remain as the `source.path` values referenced from that block.

**(d) Key provisioning, rotation (O7), deploy ordering.**
- New EC keypair as a **second Docker secret** (host `secrets/apk-signing.pem` →
  `/run/secrets/apk_signing_key`). Public `.pem` committed to this repo (like
  `signing.pub`) and shipped to devices.
- **O7 / rotation stance (v1 = TOFU pin-once, documented):** `install-apk.sh`
  drops the pubkey once. apk supports **multiple** keys in `/etc/apk/keys/`, so
  the *documented* rotation is additive — publish an overlap window signing the
  index with old+new keys, have devices add the new pubkey (installer re-run),
  then retire the old. v1 ships the pin-once path and documents this rotation
  procedure; automating it is a later stage. A hard key loss with no overlap
  bricks `apk update` for provisioned devices — called out in §8.
- **Deploy ordering (clean cutover, and no false-red `/health`):** even though a
  missing key no longer exits the process (above), provision the EC secret and
  confirm it loads **before** marking EC required, so `/health` never flips 503
  during rollout and Stage C never assumes a signer that isn't live. Sequence:
  deploy binary with EC key *optional* → provision secret → confirm `/health`
  shows `ec.loaded:true` → flip EC to required. This is the human gate **B4**.

### 4.3 Feed publishing + release integration (`build-tailscale.yaml`)

- Add apk build via the centralized arch matrix (§4.5) producing arch-namespaced
  `.apk` (out/`<arch>`/…). **Keep arch subdirectories through the artifact
  upload/download merge** — do not `merge-multiple` into a flat dir (that
  collides identical filenames, see §3); flatten only under `apk/<arch>/` at
  publish time.
- Build the unsigned `packages.adb` per arch in CI, then call imprimatur
  `/sign-adb-index` (§4.2a) per arch for the signature.
- **Feed hosting = GitHub Pages behind a custom domain** (O4 resolved, e.g.
  `apk.leavitt.dev`). The custom domain keeps the device-facing URL
  **backend-portable** — once devices pin the feed in
  `/etc/apk/repositories.d/customfeeds.list`, the URL can never move without
  re-touching every device, so a CNAME (not a raw `*.github.io`) is mandatory.
  Layout: `apk.leavitt.dev/apk/<arch>/{packages.adb,*.apk}` and
  `apk.leavitt.dev/apk/keys/tailscale.pem`.
- **Atomic publish + concurrency.** Publish index + all referenced packages as a
  **single** deployment; add `concurrency: group: apk-feed-publish,
  cancel-in-progress: false` to the publish job so a re-dispatched run can't
  interleave with an in-flight one and leave `packages.adb` referencing
  half-uploaded packages. *Test (C3):* after publish, fetch the served
  `packages.adb`, assert its hash matches what was just built, and walk its
  entries asserting **every** referenced `.apk` resolves with a matching hash
  (guards CDN propagation skew — apk fails closed on mismatch, so this is a
  reliability gap, not a trust gap).
- **Monotonicity guard (prevents a signed downgrade).** The concurrency group
  serializes overlapping publishes but does **not** order them by content
  recency — GH Actions dequeues FIFO. With the republish/backfill path (§4.6)
  able to target an *older* version, a backfill of v1.98.8 dequeuing after a
  v1.99.0 release would leave the feed serving a **cryptographically valid, signed
  downgrade** to every device that runs `apk update` (C3's index-walk passes — the
  index correctly matches what was published; it just published the wrong thing).
  *Fix:* before overwriting `packages.adb` for an arch, fetch the currently-live
  index version and refuse to publish a version that is not **strictly greater**
  (compare with apk's own version comparator), unless an explicit `force` dispatch
  input is set. *Test (C3):* a publish of a lower version than live is rejected
  without `force`. This also catches plain operator error, not just the race.
- **Retain last-N package blobs; differentiated caching.** GitHub Pages deploys
  replace the whole published tree, so latest-only *index* retention would **delete
  old `.apk` blobs a stale-cached index still references** → a hard, non-self-healing
  404 (worse than propagation skew, and invisible to C3's one-shot post-publish
  check). Keep the last **N** package blobs in the tree (they are small) and only
  advance which one the index points at, so a client holding a briefly-stale index
  still resolves. Set differentiated `Cache-Control`: **short/no-cache** for
  `packages.adb` (mutates every release) vs. **long/immutable** for `*.apk`
  (filenames are version-qualified) — Pages' default won't distinguish them.
- **CI token least-privilege.** The isolated apk job (§4.6) must not accumulate
  `pages:write` + `contents:write` + `attestations:write` at once. Split feed
  publish (Pages-scoped: `pages:write`/`id-token:write`) from release-asset attach
  (`contents:write`/`attestations:write`) into separate jobs, mirroring the
  trust-boundary discipline applied to imprimatur (§4.2a).
- Also attach loose `.apk` + the pubkey to the GitHub release (for
  `--allow-untrusted` / offline installs and the documented downgrade path),
  alongside today's `.ipk` assets.
- Extend `SHA256SUMS`, SBOM, and provenance attestation to cover `.apk`. *Note
  (C4):* the existing `attest-build-provenance` uses `subject-path:
  packages/*.ipk`; confirm one glob can cover both extensions or add a second
  step.

### 4.4 Install UX + docs

- **Single dispatcher over shared primitives — not a three-way `if/elif`.** Add
  one `scripts/install.sh` that detects OpenWrt release + arch once and dispatches
  to apk / ipk / GL.iNet. It must be a **module hiding the differences**, not three
  tangled branches: factor **one** set of primitives (`detect_arch`,
  `prompt_confirm` reading `/dev/tty`, `poll_for_service name timeout`, `log_*`)
  used by all three paths, with thin per-path adapters holding only the genuine
  differences (ipk: `opkg install`; apk: ca-bundle preflight + key + feed +
  `apk add`; glinet: binary swap + `gl_tailscale` restart). `install-glinet.sh`
  today entangles these helpers with GL-specific mechanics in the same functions;
  D1 must **factor** the hard-won fixes into shared primitives, not copy-paste
  them, or it reproduces the "three scripts" problem inside one file.
- apk path: verify `apk` exists (else print a clear "you're on ≤24.10, use the
  ipk path" error, not `command not found`); **ensure `ca-bundle` is present
  before adding an HTTPS feed** (TLS trust is needed to fetch the feed, but
  `ca-bundle` is only a *dependency of the tailscale package* — chicken/egg);
  drop `tailscale.pem` in `/etc/apk/keys/`; add the per-arch feed URL to
  `/etc/apk/repositories.d/customfeeds.list`; `apk update && apk add tailscale`.
- **Carry forward the hard-won `install-glinet.sh` fixes** (recent commits):
  read prompts from `/dev/tty`; poll for service startup with a timeout. Reuse
  `detect_arch()`; release-detection (`. /etc/openwrt_release; echo
  $DISTRIB_RELEASE`) is new code and needs its own failure-path test.
- README/INSTALL.md: add a **decision table at the top** (OpenWrt version × how
  to detect it → which path), the OpenWrt 25 apk path, an **"Uninstalling
  (apk)"** section mirroring the existing ipk one (`apk del tailscale`, remove
  the feed line and `/etc/apk/keys/tailscale.pem`), the **downgrade procedure**
  (§4.7), a one-line note that the **web UI (`luci-app-tailscale`) is a separate,
  ipk-only project** this feed does not ship (so apk users don't expect it from
  `apk add tailscale`), and a short **"Mirroring this feed"** note (copy
  `apk/<arch>/{packages.adb,*.apk}` + pubkey to any HTTPS host and point
  `customfeeds.list` there — apk trust is index-content-based, so a re-host still
  verifies).

### 4.5 Arch matrix — single source of truth (pulled earlier)

The arch list is duplicated across three files that already disagree
(`build-tailscale.yaml` has 4 hand-written jobs; `build.sh` has only 2 —
stale/incomplete; `install-glinet.sh` has 4), and the `Dockerfile` separately
carries an order-dependent `case` mapping arch → `GOARCH/GOARM/GOMIPS`. Adding
apk would create a fifth/sixth divergent copy. **Introduce the single source
before Stage C consumers are added** (not last): a repo-root `arches.json`, but
as an **array of objects, not a bare string list** — a flat list would leave the
Dockerfile's Go-triplet `case`, the MIPS-canary selection (§5), and the
endianness the RFC itself calls out (MIPS big-endian) still hardcoded elsewhere,
i.e. the very duplication this closes, incompletely. Schema per arch:

```json
{ "name": "mips_24kc", "goarch": "mips", "goarm": "", "gomips": "softfloat",
  "endian": "big", "rootfs_target": "malta/be", "canary": true }
```

Consumed by shell via `jq -r '.[] | select(.name==env.ARCH) | .goarch'` (collapsing
the Dockerfile `case`), by the workflow via `matrix=$(jq -c . arches.json)` →
`strategy: matrix: fromJson(...)`, and by A5b's canary pick via
`jq -r '.[] | select(.canary) | .name'`. Collapses the four hand-copied build
jobs into one parameterized job; fixes `build.sh`'s 2-arch gap; carries A0's
`rootfs_target` (below). *Test:* every consumer reads the one file; CI asserts no
arch/triplet literal remains elsewhere.
- **Arch scope is deliberate, not expanded for v1.** apk arch coverage mirrors
  `arches.json` (the same four GL.iNet-era triplets), even though 25.12 being
  "now mainline" implies a wider hardware mix (e.g. `x86_64`). Widening the matrix
  is a mechanical follow-up (add rows), explicitly out of scope for v1 (§2).

### 4.6 Failure isolation + alerting (from the outage post-mortem)

- **Isolation — the DAG mechanics, stated.** apk build/sign/publish are **sibling
  jobs to the ipk release job, not steps inside it**, so an apk-path failure
  cannot block the `.ipk` release. GH Actions' default `needs:` *skips* a
  dependent when a dependency fails, so making the ipk release survive an apk
  failure is **not free**: the ipk-release job depends only on the ipk build jobs
  (never on apk jobs), and any job that must run "apk best-effort but don't fail
  the release" uses `if: ${{ !cancelled() }}`. Because apk publish/republish is
  decoupled from the ipk release step, release-asset attach uses **two
  `softprops/action-gh-release` calls against the same tag** (upsert), not one.
  The ipk path keeps its current hard-fail-on-sign-failure behavior. *Test (C5):*
  a forced apk-sign failure leaves the ipk release job green and its assets intact.
- **Alerting:** the 2-month outage was silent. Confirm/enable **failure
  notification** on the release workflow (GitHub's default owner-email on
  workflow failure, or an explicit ntfy/webhook step) so a signing failure is
  seen in hours, not months. imprimatur's own `/health` (now 503-accurate) is
  the other half.
- **Detect a soft apk failure after the fact (self-heal).** With isolation, the
  GitHub Release is created even when apk soft-fails — so `check-releases.yaml`'s
  `gh release view "$TAG"` gate concludes "done" and the missing-apk state is
  invisible forever (the outage class, relocated to the cron). Extend the daily
  cron to also fetch one arch's published `packages.adb`, compare its version to
  the latest release tag, and **auto-fire the republish dispatch on mismatch** —
  not rely solely on a human seeing the alert.
- **Post-launch feed observability (synthetic check).** Alerting covers the CI
  publish; nothing catches *silent decay* of the static feed between releases —
  DNS/CNAME drift, a Pages custom-domain cert-renewal failure, a Pages outage,
  none of which touch a CI job. Piggyback a synthetic probe on the same daily
  cron: curl the feed + pubkey, verify **TLS/cert validity** and that the served
  index still signature-verifies and matches the latest release; reuse the alert
  channel on failure.
- **Republish path:** add a narrow `workflow_dispatch` entry to re-run just
  feed-assemble+sign+publish against already-built release assets (retry after an
  imprimatur outage, or backfill apk for an existing release, without a full
  rebuild). Subject to the §4.3 monotonicity guard (a backfill of an older version
  needs explicit `force`). **Republish is version-string-invisible** to a device
  that already ran `apk update` against a broken first attempt (same version →
  `apk update` reports nothing new); republish fixes *new* installs. Documented
  limitation (§4.7/§8); a device that already attempted must be told to retry
  explicitly.

### 4.7 Upgrade / coexistence / rollback

- **ipk → apk upgrade (24.10 → 25.12).** The package-manager format changes
  across this boundary. Document the supported path (spike: does 25.12 support
  in-place `sysupgrade` preserving `/etc`, or reflash-only?). If in-place is
  possible, a stale ipk-installed `tailscaled`/init/firewall state can collide
  with a fresh `apk add tailscale` (duplicate files, orphaned firewall rules from
  an ipk `postrm` that never ran). Documented requirement: remove the ipk package
  first (or the installer detects and cleans it). *Test:* install ipk in a
  container, simulate the upgrade, `apk add`, assert no duplicate/residual state.
- **Rollback / downgrade.** A deliberate consequence of latest-only retention
  (§2): the feed cannot serve an older version, so a trusted downgrade is
  impossible from the feed. Documented path: fetch the prior `.apk` from the
  GitHub release and `apk add --allow-untrusted ./tailscale-<old>.apk`. Many
  package managers refuse a silent downgrade without a force flag, so this — the
  *one* documented recovery procedure — must be **tested, not just documented**:
  provision a newer version in the verification container, run the exact
  documented command against an older local `.apk`, and assert it succeeds (or
  capture whatever `--allow-untrusted`/force combination apk actually requires and
  document *that*). Fits D3 or its own slice; D2 stays docs-only otherwise. Noted
  in §8. (The O4 hosting decision can eliminate this gap — see §7.)

## 5. Test strategy (no hardware)

Every slice lands with an automated check; the flow's PhD-CS bar applies.

- **Test-harness convention is slice-zero (this repo has none today).** There is
  no `tests/` dir, framework, or CI test job in `tailscale-openwrt` — so A2/A3a's
  "assert no `CONTROL/`", "assert no host `uci commit`" checks would each silently
  also invent where tests live and how they run outside a full CI run (the
  `/tdd` RED-GREEN loop needs local invocation). **Fix the convention once, riding
  with A2:** self-contained `tests/apk/<name>.sh` scripts, runnable via `docker
  run` locally *and* as a CI step, so A2 isn't the slice that silently decides repo
  test conventions. (imprimatur already has `tests/test_all.nim` + `nimble test`;
  Stage B slots into it — this is a Stage A gap only.)
- **PR-vs-release trigger is prerequisite infrastructure.** The emulation policy
  below ("full 4-arch at release, MIPS canary on PR") presupposes an
  `on: pull_request` event that **does not exist** — `build-tailscale.yaml` is
  `workflow_dispatch`-only, fired by `check-releases.yaml`. Add the
  `pull_request` trigger + `if: github.event_name == 'pull_request'` matrix-scoping
  as an explicit early slice (rides with A5a, before A5b), or A5b's "canary on PR"
  test has no event to condition on.
- **apk-tools version pinning across all three sites.** Three independent copies
  of apk-tools exist — the build image (§4.1), imprimatur (only if B0 forces the
  fallback), and the OpenWrt 25.12 verification container. **Pin one version,
  matched to what OpenWrt 25.12.0 ships**, and use it in all three; a build/sign
  vs. verify skew is exactly the failure class the 3.0.5 aarch64 `.adb` bug
  describes. **Related now-load-bearing note:** the build image is
  `opensuse/tumbleweed:latest` (a rolling tag); `EcP256Algo`'s EVP FFI (§4.2b) is
  the first thing to depend on a specific `openssl-dev` ABI landing on that base,
  so pin the base image digest (or the `openssl-dev` version) alongside apk-tools —
  a moving `libcrypto` under the FFI is the same skew class.
- **Package build:** assert `apk mkpkg` exit 0 and that `apk`/`adumpk` parses the
  `.apk` with the expected `name`/`version`/`arch`/`depends`/scripts/conffiles,
  **and no `CONTROL/` payload** (§4.1).
- **`IPKG_INSTROOT` safety (A3a):** run each maintainer script with
  `IPKG_INSTROOT` set to a scratch dir; assert no host `uci commit` / service
  reload occurred.
- **Install (integration):** in the pinned **OpenWrt 25.12 rootfs container**
  (A0), assert install succeeds, `tailscaled --version` runs, `/etc/config/tailscale`
  exists, service registered. **Harness mechanism (A4, reused by A5b/C2):** append
  our build arch to the container's multi-line `/etc/apk/arch` (NOT `--arch`), and
  supply an offline **local unsigned stub repo** (`-X <stubrepo>/packages.adb`) with
  empty stubs for the unsatisfiable deps (`kmod-tun`/`ip-full`/`conntrack`) so the
  real payload lands + `post-install` runs without a network feed. Tolerate
  `/etc/init.d/tailscale start` failing (no procd/ubus in an unbooted rootfs) —
  assert the enable rc.d symlinks, "registered not running".
- **Signed feed (trust):** drop `tailscale.pem` in `/etc/apk/keys/`, serve the
  signed `packages.adb`, assert a plain `apk add tailscale` (no
  `--allow-untrusted`) succeeds.
- **imprimatur EC signer:** Nim unit — sign a known blob, verify with `openssl`;
  integration — a `packages.adb` signed via `/sign-adb-index` is accepted by
  `apk` in-container. **Hermetic C2:** run imprimatur's Docker image *locally in
  the CI job* with a **test-only** EC key rather than hitting production
  `sign.leavitt.info`; reserve the live round-trip for the B4 deploy smoke test.
  This keeps C2 hermetic and decouples it from the B4 deploy gate. The test EC
  key is **generated ephemerally at job start** (`openssl ecparam -genkey -name
  prime256v1`) and discarded at job end — never a standing credential committed to
  the repo or Actions secrets.
- **Health gating:** start imprimatur with the EC key required but absent →
  `/health` 503; with key → 200; usign-only fault does not 503 the EC route and
  vice-versa (per-key, §4.2c).
- **CI cost / emulation policy.** Today's build is native-arch cross-compilation
  with **no** emulation ("~2-min CI"). A4/A5 add running foreign-arch binaries
  under qemu-user binfmt — slower and, for **MIPS big-endian**, historically
  flakier than the aarch64 arch the RFC already flags as buggy. Policy: **full
  4-arch emulated integration runs at release time only**; PRs run the native
  aarch64 path plus a lightweight MIPS **canary** (A5-canary) so a red MIPS test
  has a known-good baseline to distinguish a real bug from a qemu mis-emulation.
  Estimate and record added wall-clock in A5.

## 6. Staged slice plan (`/tdd`-sized)

Dependency notes: **A0** and **A3a** are new prerequisites surfaced in review;
**B0** is a research spike that shapes B3 and **has no dependency on Stage A** —
run it **first or in parallel with A0** (it is the cheapest, highest-information
step and its outcome can double B3's cost, so front-load it); its expanded exit
criteria (§3) also fold in the §4.1 collision check against a real 25.12 index.
**B4** is a human deploy gate that Stage C depends on. Test-harness convention
and the `pull_request` trigger are prerequisite infra (§5), riding with A2 and
A5a respectively. `[human]` = not `/tdd`-able.

**Stage A — apk package build (unsigned, loose)**
- A0. Build/pin an OpenWrt 25.12 rootfs container per arch, checksum-pinned;
  native aarch64 first. **Concrete targets confirmed empirically (A0 research):**
  `armsr/armv8` (aarch64), `armsr/armv7` (arm32), `malta/be` (mips BE),
  `malta/le` (mipsel LE) — these four are the clean generic VM/QEMU targets that
  publish a bare `rootfs.tar.gz` in 25.12 (note: `armvirt` was **renamed to
  `armsr`**; device targets like `mediatek/filogic` ship only sysupgrade images).
  **Key finding — verification container arch ≠ our package arch (2 of 4).** The
  generic VM targets use *generic* package arches (`armsr/armv8` =
  `aarch64_generic`, `armsr/armv7` = `arm_cortex-a15_neon-vfpv4`), **not** the
  GL-device arches we build for (`aarch64_cortex-a53`, `arm_cortex-a7`); malta
  be/le match our `mips_24kc`/`mipsel_24kc` (confirm in-container). No stock 25.12
  target ships a clean rootfs for the GL cortex arches. This is **fine for
  verification**: the ISA is compatible (Go arm64/arm binaries are baseline
  ARMv8/ARMv7, run under any aarch64/armv7 qemu), and the container can be made to
  accept our foreign package arch. **Correction (A4): `apk add --arch <foreign>`
  does NOT work** — apk-tools 3.0.2 treats `--arch` as *replacing* the whole
  transaction's acceptable-arch set, which then conflicts with the ~130
  base packages tagged the container's native arch (`uninstallable`). The correct
  mechanism is **`/etc/apk/arch`, which accepts multiple lines**: append our build
  arch (e.g. `aarch64_cortex-a53`) alongside the native one, then a plain `apk add`
  (no `--arch`) resolves. This is a **CI-verification-container concern only** — a
  real GL device's native arch already *is* our build arch, so on-device `apk add
  tailscale` needs no such handling (D1 install UX is unaffected). *Test:* each pinned container reports `apk --version` =
  OpenWrt apk v3 (3.0.2), and `apk --print-arch` is recorded per arch; the
  container ISA-executes our target binary. (Replaces the original "container arch
  == build arch" assumption, which no stock target satisfies.) **DONE** — `arches.json`
  (repo root, array-of-objects per §4.5 + `rootfs_url`/`rootfs_sha256`/`container_arch`
  pinning fields) and `tests/apk/rootfs.sh` (checksum-verified import + `apk --version`
  ≥3 + `apk --print-arch` per arch) landed, RED→GREEN. Empirical `apk --print-arch`:
  `aarch64` / `armv7` / `mips` / `mipsel` (apk's generic vocabulary — note this
  differs from both our build arch *and* the OpenWrt feed arch `aarch64_generic`
  etc.; `--arch` override spans the gap). All four apk = 3.0.2. **32-bit MIPS qemu
  caveat surfaced for A5a (below).**
- A1. **DONE.** Host apk-tools **3.0.2** (with `mkpkg`/`mkndx`) added to the build
  image via SDK-extract (O3 lean): the 25.12.0 x86_64 SDK's `staging_dir/host/bin/apk`
  is a wrapper script over a hidden `.apk.bin` (glibc dynamic ELF, needs only
  libc/libpthread) — Dockerfile extracts **only `.apk.bin`** (pinned by SDK
  URL+sha256), runs unmodified on tumbleweed; no source build needed. `fakeroot`
  **redundant, dropped** (§3). Test `tests/apk/host-apk.sh` asserts `apk --version`
  = 3.0.2 and both applets present (greps `Mkpkg options:`/`Mkndx options:` — this
  apk build exits 1 on `--help` for *all* applets, so exit-code can't distinguish
  present vs unknown). Existing Go/ipk pipeline reverified intact. RED→GREEN.
- A2. **DONE.** `$PKGROOT` build root (`files/` payload + sibling `scripts/`) +
  `apk mkpkg` for aarch64, arch-namespaced output; SOURCE_DATE_EPOCH from tarball
  mtime. Dockerfile split into `apk-tools`/`build`/`apk`/`ipk` stages (default
  build still targets `ipk`, byte-verified intact); `build-apk.sh` added.
  **Established the shared `tests/apk/lib.sh` harness** (rootfs.sh/host-apk.sh
  refactored onto it) + `tests/apk/mkpkg.sh`. adbdump-verified name/version/arch/
  depends + no `CONTROL/`/`scripts/`. Surfaced the conffiles correction (§4.1).
  RED→GREEN.
- A3a. **DONE.** Guarded `tailscale.{postinst,prerm,postrm}` on `$IPKG_INSTROOT`
  via a single `INSTROOT` choke point + `uci_r()` wrapper (`uci -c
  "$INSTROOT/etc/config"`): redirect (uci writes + rc.d `S99`/`K10` symlinks under
  root), no-op (`/etc/init.d/* reload|start`, dnsmasq), skip (meminfo). **Category-3
  deferral (design call, RFC-mandated "re-derive at first boot"):** the `/proc/meminfo`
  RAM-tuning is skipped under a bake and re-derived once at first boot by
  `tailscale.init start_service`, gated on a new `hardware.detected` uci flag
  (default `0`, set `1` after live detection) — so `tailscale.init`/`.config` were
  touched too. *Test* `tests/apk/instroot.sh` (alpine sandbox + `uci-stub`, host
  untouched): 41/41 pass; 17 failed pre-guard; live-install (`INSTROOT` unset)
  byte-equivalent. RED→GREEN.
- A3b. **DONE** (assertion-only — mapping + conffile were already wired in A2,
  confirmed correct). Added `scripts:`-block assertions to `tests/apk/mkpkg.sh` that
  the three hook names appear as scoped YAML keys; conffile-shipped assertion already
  present. RED→GREEN verified by omitting a `--script` (real build-fail path). 16/16.
- A4. **DONE.** Integration install of the aarch64 `.apk` in the armsr/armv8
  container. `tests/apk/install.sh` (harness). Two empirical corrections: (1)
  `--arch` fails → use multi-line `/etc/apk/arch` (A0 above); (2) **offline dep
  resolution needs a local unsigned stub repo** (`-X <stubrepo>/packages.adb` with
  empty `kmod-tun`/`ip-full`/`conntrack` stubs built via the A1 host `apk
  mkpkg`/`mkndx`; `ca-bundle` already in base) — no force-flag alone works
  (`--force-broken-world` silently drops the package from world). Result: real
  aarch64 `tailscaled --version`→`1.92.2` under qemu; `/etc/config/tailscale`
  present; `/etc/init.d/tailscale enable` creates the rc.d symlinks (asserted);
  `start` failure tolerated (no procd/ubus — "registered, not running" per §5).
  Config default `enabled='0'` so postinst doesn't auto-enable. RED→GREEN. *Note:*
  an intermittent qemu-user segfault in a post-install subprocess was seen once
  (transaction still OK, all assertions passed; unreproducible) — qemu flakiness,
  not a package defect (§5/§8).
- A5a. **DONE.** Added (additive, ipk path byte-identical): `on: pull_request`
  trigger; `select-matrix` + `qemu-verify` jobs; `scripts/select-matrix.sh` (jq,
  testable — PR→canary+aarch64, else full, driven off `arches.json`);
  `setup-qemu-action` + the custom MIPS binfmt (extracted to `lib.sh`
  `register_openwrt_mips_binfmt`, reused by CI + `rootfs.sh`); `tests/apk/qemu.sh`.
  RED→GREEN; all 4 `uname -m` exec (mipsel also reports `mips` — Linux doesn't
  encode endianness); matrix logic asserted; custom MIPS entries proven load-bearing.
  Did **not** matrix-ify the ipk jobs (that's C1a).
  - **⚠ 32-bit MIPS binfmt gotcha (root-caused in A0; the RFC's "MIPS flakier"
    risk made concrete).** Stock `docker/setup-qemu-action` / `tonistiigi/binfmt`
    register **only mips64/mips64le**, not 32-bit mips/mipsel — and even
    `multiarch/qemu-user-static`'s stock mips/mipsel entries **reject OpenWrt's
    musl-softfloat binaries**: their ELF `e_ident[EI_ABIVERSION]` byte is `1` while
    the stock binfmt_misc entry requires `0`, so `docker run` fails "exec format
    error" though qemu handles the ISA fine. **Fix A5a must ship:** after the
    standard registration, register custom `qemu-mips`/`qemu-mipsel` binfmt_misc
    entries with the ABIVERSION byte **wildcarded** in the mask. `tests/apk/rootfs.sh`
    already implements the self-heal (lazy `--privileged` reset + custom entries) as
    the reference. **Registration caveat:** binfmt_misc magic/mask containing
    embedded `0x00` must be written as **literal `\xHH` text** (kernel decodes
    internally) — pre-decoding to raw bytes truncates at the first NUL (kernel field
    split is NUL-unsafe). CI's `setup-qemu-action` step needs this same custom
    registration or the MIPS canary/full runs silently can't exec.
- A5b. **DONE.** `tests/apk/install.sh` generalized to iterate all 4 arches from
  `arches.json` (per-arch stub repos via `--info arch:<arch>`; multi-line
  `/etc/apk/arch`). Verified GREEN: real `tailscaled --version`→1.92.2 under qemu
  for all four (aarch64/arm/mips/mipsel). Wall-clock (emulated): install ~47–48s/arch
  (aarch64 47s, arm 47s, mips 49s, mipsel 56s); Go builds native-cross (cached 0s,
  cold mipsel 9s). MIPS not notably flakier. **Stage A COMPLETE.**

**Stage B — imprimatur EC signing** *(separate repo)*
- B0. **Spike — DONE** (`docs/rfc-apk-builds.b0-spike.md`). Answered all three
  exit criteria from apk-tools v3.0.2 source + a real signed index + an OpenSSL
  round-trip: (a) appended `ADB_BLOCK_SIG`, separable, apk-tools-free via Design 1;
  (b) 86-byte pre-image `LE32(schema) ‖ {0x00,0x04,id[16]} ‖ SHA512(data block)`,
  SHA512-then-ECDSA; (c) **DER** (not raw `r‖s`). Collision confirmed (25.12 ships
  `tailscale-1.98.3-r1`). Command/constant surface recorded for B2/B3/C2.
- B1. **DONE** (imprimatur repo). `KeySource`/`SigAlgo` base + `Signer` composition
  owning `load/sign/fingerprint/isLoaded` (atomic load); ed25519/usign logic isolated
  in `ed25519_algo.nim` (base carries none). `registry.nim`: `Table[string,
  SignerEntry]`, `POST /sign/:key` (404/503/200 via pure `signRouteStatus`), `/health`
  per-key `{loaded,required,fingerprint}` → 503 iff a required key unloaded.
  `loadAll()` never raises → **no `quit(1)` after boot** (the only `quit(1)` is on
  malformed `IMPRIMATUR_SIGNERS` before `serve()` binds); readiness is structural
  (load fully before `serve()`). Config = `IMPRIMATUR_SIGNERS` JSON; renamed
  `IMPRIMATUR_KEY_PATH`→`IMPRIMATUR_USIGN_KEY_PATH`. 41/41 `nimble test`
  (nimlang/nim:2.2.4-alpine) + live binary smoke; RED→GREEN by reproducing the exact
  always-200 bug. **Impl notes:** `=destroy`→virtual `destroy()` (Nim 2.2.4 reserves
  `=destroy` for concrete-type magic; B2 overrides `destroy()` for `EVP_PKEY_free`);
  dropped the old per-request `comment` field (narrow in/out; wire sigs unchanged).
  **For B4:** `README.md`/`compose.yaml`/`docker-compose.yaml` still name the old
  `IMPRIMATUR_KEY_PATH` + bare `/sign` — B4 deploy must update them.
- B2. **DONE** (imprimatur). `src/ec_algo.nim` — `EcP256Algo` (SigAlgo) via libcrypto
  EVP FFI (`{.passl:"-lcrypto".}`, header-based like `sodium.nim`): `EVP_DigestSign*`
  with **SHA-512**, output **DER** (both per B0); `destroy()`→`EVP_PKEY_free`;
  `fingerprint`=`SHA512(i2d_PublicKey)[:16]` hex (apk key id). Registry `algo:"ec"`
  wired. Tests assert DER via a hand-written parser (rejects a raw-`r‖s` blob),
  SHA-512-sensitivity, and cross-verify through independent `EVP_DigestVerify` FFI
  (apk's exact path) + tamper negative. `openssl-dev` added to Dockerfile builder
  (RED without). **64/64 nimble test.** No deviation — DER+SHA512 held; no Design-3
  fallback.
- B3. **DONE** (imprimatur). `POST /sign/:key` was built in B1 + the EC algo in B2,
  so `/sign/ec` already signs end-to-end (Design 1 = **no apk-tools in imprimatur**,
  grep-confirmed; B0=yes, no B3a fallback). B3 added `tests/test_sign_route.nim` — an
  HTTP integration test driving the **real compiled binary** as a subprocess (the
  artifact B4 deploys), asserting: `/sign/ec` 200 + returned sig is DER & verifies via
  independent `EVP_DigestVerify(sha512)`; `/health` 200 w/ `ec.loaded:true`;
  unloaded→503 (route + `/health`); unknown key→404 + route isolation. 68/68 nimble
  test; RED→GREEN via the always-200 bug. *Note:* the "signed `packages.adb` accepted
  by `apk` in-container" end-to-end test is **C2's** (ADB assembly lives in CI, not
  imprimatur — §4.2a Design 1); C2's existing "trusted `apk add`" test covers it.
- B4. `[human]` Deploy to sign.leavitt.info per the §4.2d ordering; verify
  `/health` 200 with `ec.loaded:true` and a prod smoke `POST`. **Hard gate for
  Stage C's live round-trip** (C2 itself stays hermetic, §5).

**Stage C — feed publishing + release integration**
- C0. `[human]` Enable GitHub Pages (source: GitHub Actions), configure the
  **custom domain** CNAME (`apk.leavitt.dev`), grant the workflow
  `pages:write`/`id-token:write`. *Test:* the custom-domain URL serves a
  placeholder over HTTPS with a valid cert.
- C1a. **DONE.** 4 hand-written ipk jobs → one `build-ipk` matrix job
  (`matrix: arch: fromJson(needs.select-matrix.outputs.arches)`, reusing A5a's
  `select-matrix`/`arches.json`; release job repointed to `needs: [build-ipk]`,
  artifact names unchanged). Byte-identity **verified empirically** (aarch64 built
  old-way vs matrix-way → `data.tar.gz`/`control.tar.gz` contents `diff -rq` clean)
  + structural/matrix-equivalence checks in `tests/apk/ipk-matrix.sh`. RED→GREEN.
  (Note: OpenWrt `.ipk` = gzipped tar, not `ar` — extract with `tar`.)
- C1b. **DONE.** `build-apk` matrix job (`needs: [select-matrix]` only — DAG sibling
  of `build-ipk`, not nested, so C5 isolation is additive), per-arch `docker build
  --target apk`, artifacts `apk-<arch>` (name+path arch-namespaced, no `merge-multiple`
  flatten → no collision). `tests/apk/apk-matrix.sh` (13/13, structural: matrix source,
  sibling-not-nested via needs-graph, arch-namespacing, YAML-valid). RED→GREEN.
  Regression-fixed `ipk-matrix.sh`'s job-exclusion list. `build-ipk`/`release`/others
  byte-unchanged.
- C2. **DONE — independently verified (the whole signing chain works end-to-end).**
  `scripts/adb-sign.py` (stdlib + openssl CLI) implements B0's CI-side ADB framing:
  `preimage` (parse `apk mkndx --compression none` uncompressed "ADB." output → 86-byte
  pre-image), `assemble` (append the `ADB_BLOCK_SIG` block), `key-id`
  (`SHA512(i2d_PublicKey)[:16]` derived from the PUBLIC key, cross-checked vs a
  libcrypto C prog — never trusts imprimatur's self-reported fp). **Finding:** `apk
  mkndx --compression none` emits the uncompressed on-disk ADB form (accepted
  identically by `apk add`), so B0's compressed-data-block worry never had to be
  solved. `tests/apk/sign-verify.sh` (hermetic, aarch64): builds tailscale.apk + stub
  deps into one unsigned index, builds+runs the **CI-local imprimatur image from the
  LOCAL working tree** with an ephemeral EC key, frames+POSTs to `/sign/ec`, assembles
  the signed index. **Verified live:** trusted `apk add tailscale` (no
  `--allow-untrusted`) succeeds + installs+runs `tailscaled 1.92.2`; **both negatives
  fail** (unsigned → UNTRUSTED; one-bit-flipped DER content → rejected). Workflow: new
  `apk-sign-verify` sibling job (`needs:[select-matrix,build-apk]`, never feeds
  `release`). **⚠ Placeholder (all-zeros) imprimatur clone SHA + TODO** — imprimatur's
  B1–B3 is uncommitted upstream, so a live Actions run fails at that step until it's
  committed+pushed (expected, non-blocking to ipk; §8 cross-repo drift).
- C3. **DONE.** `publish-feed` job (single atomic job, not matrix; `needs:
  [select-matrix,build-apk,apk-sign-verify]`, dispatch-only, `concurrency:
  apk-feed-publish cancel-in-progress:false`, **least-priv `pages:write`/`id-token:write`
  only** — verified; separate from `release`). `scripts/feed-guard.sh`:
  `check-monotonic` (real `apk version -t`; exit 0/1/2 distinguishing bootstrap /
  downgrade-reject / hard-network-error — no conflation, force override),
  `plan-retention` (a `retained.json` manifest, last-N=3, since Pages has no dir
  listing), `verify-tree` (uses `apk mkndx` as the content-hash oracle). Tests
  `tests/apk/feed-publish.sh`: monotonicity (all exit codes), retention, index-walk vs
  a locally-served signed feed. RED→GREEN + least-priv-violation caught. **Finding —
  Cache-Control NOT achievable on GitHub Pages** (no `_headers`/per-path header
  support; confirmed): differentiation from §4.3 is dropped as infeasible on Pages;
  a dormant `_headers` file is written for a future `_headers`-aware mirror; the
  correctness risk is already covered by last-N retention + monotonicity. Production
  signing uses real `sign.leavitt.info` + committed `apk-signing.pem` — both behind
  loud TODOs (gated on B4, like C2).
- C4. **DONE.** New `release-apk-assets` job (`needs:[select-matrix,release,build-apk]`,
  perms `contents/id-token/attestations:write`, no `pages` — separate from
  `publish-feed`; `release` byte-unchanged). Downloads `apk-<arch>`, renames each to
  `tailscale-<ver>-r<rel>-<arch>.apk` (collision confirmed), attaches `.apk`s + pubkey
  + combined `SHA256SUMS`/SBOM via a **second** gh-release upsert. `scripts/release-checksums.sh`
  (factored, extended `*.apk`/`*.pem`, self-hash-guarded) + tests
  `release-checksums.sh` (13/13) + `release-attach.sh` (structural: job/perms/attest
  separation). Attest = **second `attest-build-provenance` step** for `.apk` (empirically:
  one glob *could* span both, but the apks are in a different job + `packages/*` would
  sweep SHA256SUMS/SBOM). RED→GREEN. ipk release path unchanged; `release-apk-assets`
  depends on `release` one-way so C5 can make it best-effort.
- C5. **DONE — STAGE C COMPLETE.** Isolation: `release` `needs:[build-ipk]` only
  (transitive-closure verified); apk jobs got `if: !cancelled()` (+ `release-apk-assets`
  re-checks `needs.release.result=='success'`) so an apk failure never blocks/greys the
  ipk release. `scripts/notify-alert.sh` (`ALERT_WEBHOOK_URL` env + `::error::`; `if:
  failure()` steps). Republish: `workflow_dispatch` `republish`/`republish_tag` inputs +
  `republish-feed` job (downloads a tag's `.apk`s, re-signs+publishes, monotonicity-guarded;
  fixed a missing `contents:read`). Cron self-heal: `scripts/detect-apk-drift.sh` +
  `feed-guard.sh read-version` → auto-dispatch republish on drift, extended in
  `check-releases.yaml` (keepalive untouched). Synthetic probe: `scripts/probe-feed.sh`
  (TLS/cert + signature via new `adb-sign.py verify` block-walker + version currency).
  `tests/apk/failure-isolation.sh` (DAG closure, guards, alert/republish shape, + live
  unit tests incl. a real self-signed-cert HTTPS server, tampered-sig/stale negatives).
  RED→GREEN. *Note:* GitHub owner-email-on-failure is an account setting, not repo-file
  toggleable (documented).

**Stage D — install UX + docs**
- D1. **DONE.** `scripts/lib-install.sh` = single copy of shared primitives
  (`log_*`, `detect_arch`, `detect_release` [new], `prompt_confirm` /dev/tty,
  `poll_for_service`, `get_latest_version`); `scripts/install.sh` sources it and
  dispatches once (`/etc/glversion`→glinet; else release≥25 + `apk` present→apk; else
  ipk) to three thin adapters; `install-glinet.sh` refactored to source the same lib
  (both work standalone incl. `curl|sh` self-fetch). ca-bundle chicken/egg handled
  (add from stock pre-trusted feeds before our HTTPS entry). ≤24.10 → clear ipk hint,
  never `command not found`. **Finding:** `customfeeds.list` must be the **full URL to
  `packages.adb`** (`…/apk/<arch>/packages.adb`), not a bare dir — fixed. Tests
  `tests/apk/install-dispatch.sh` (release-detect failure, ipk-hint, primitive-sharing
  structural, trusted apk install in real container + unsigned-negative). RED→GREEN.
- D2. **DONE.** `README.md` + `docs/INSTALL.md`: decision table (release × detect →
  path + the `install.sh` one-liner), apk install path (full-URL feed line, no
  `--allow-untrusted`), `Uninstalling (apk)`, `Downgrading (apk)` (arch-namespaced
  release asset per C4), luci-app ipk-only scope note, `Mirroring This Feed` note. All
  commands cross-checked against shipped `install.sh`/`lib-install.sh` + the C1b–C5
  workflow (feed URL, asset naming, `apk.leavitt.dev` paths). ipk/glinet docs verified
  intact (git diff = pure additions + widened version ranges). Docs-only, no test.
- D3. **DONE.** Filesystem-level ipk detection in `lib-install.sh`
  (`opkg_tracked_tailscale`/`clean_opkg_tailscale` — via `/usr/lib/opkg/info/tailscale.*`,
  NEVER apk metadata; §4.1); the pinned 25.12 rootfs has no `opkg`, so cleanup runs
  the *recorded* `prerm`/`postrm` live (undoes killswitch DNS/`noresolv`, removes
  `dns_backup`) + purges the info files + `opkg status` stanza. Wired as a preflight
  **before** `apk add` in `install.sh`'s `apk_path()`. `tests/apk/upgrade-downgrade.sh`
  (verified GREEN, both parts): **Part A** — ipk→apk transition leaves **no residual
  opkg/killswitch state**, tailscale apk-installed. **Part B** — the documented `apk
  add --allow-untrusted ./tailscale-<old>-r<rel>-<arch>.apk` downgrade succeeds
  **as-is** (no extra flags; apk logs "Downgrading tailscale" → 1.88.0), confirming
  §4.7. RED→GREEN. **← LAST /tdd SLICE. Stage 3 (grind) COMPLETE.**

## 7. Open questions for architecture review

- **O1 — RESOLVED (round 1):** maintainer scripts are not `IPKG_INSTROOT`-safe;
  fixed in slice A3a.
- **O2 — RESOLVED (B0, `docs/rfc-apk-builds.b0-spike.md`):** encoding = **DER**
  (not raw `r‖s`), signed pre-image = **86 bytes** (`LE32(schema) ‖ 18-byte header
  ‖ SHA512(data block)`), SHA512-then-ECDSA; signing is separable and
  **apk-tools-free** (Design 1). Collision **confirmed empirically** — OpenWrt
  25.12's feed ships `tailscale-1.98.3-r1.apk` (§4.1). B3a fallback not expected.
- **O3 — RESOLVED (A1):** SDK host binary. The 25.12.0 x86_64 SDK's
  `staging_dir/host/bin/.apk.bin` (v3.0.2, glibc-dynamic, mkpkg/mkndx present) is
  extracted into the build image, pinned by SDK URL+sha256. Byte-identical to
  OpenWrt's infra; no meson toolchain added. tumbleweed's own `apk-tools` pkg was
  rejected (3.0.6, no `mkpkg`).
- **O4 — RESOLVED:** **GitHub Pages behind a custom domain** (e.g.
  `apk.leavitt.dev`), clean per-arch layout `apk/<arch>/packages.adb` +
  `apk/keys/tailscale.pem`. One-time setup is slice **C0** (enable Pages, DNS
  CNAME, `pages:write`/`id-token:write` perms). Latest-only retention stands;
  downgrade is the documented `--allow-untrusted` release-asset path (§4.7).
- **O5 — RESOLVED:** latest-only retention (v1 non-goal); downgrade via release
  asset (§4.7). (O4 chose Pages, so retention stays latest-only by design.)
- **O6 — RESOLVED:** EC signer = libcrypto EVP FFI (matches native-libsodium
  style; §4.2b).
- **O7 — key rotation** (§4.2d): v1 = TOFU pin-once, documented additive-key
  rotation; automation deferred. Accepted risk in §8.
- **O8 — 24.10→25.12 migration mechanics** (§4.7): in-place sysupgrade vs.
  reflash — resolve in D3 spike.

## 8. Risks

- apk v3 ADB byte format is defined by the reference impl, not a formal spec —
  rely on `apk mkpkg`/`mkndx`, never hand-assemble.
- **apk-tools version skew across build/sign/verify/device** — pin one version
  everywhere (§5); the 3.0.5 aarch64 `.adb` bug is the cautionary case.
- **qemu-user MIPS-BE fidelity** — emulation flakiness could masquerade as a
  packaging bug; mitigated by the MIPS canary + release-only full emulation (§5).
  **Root-caused in A0:** the first MIPS failure is not fidelity but *registration* —
  stock binfmt omits 32-bit mips and rejects OpenWrt's `EI_ABIVERSION=1`
  musl-softfloat ELFs; A5a ships custom ABIVERSION-wildcarded binfmt entries (see
  A5a). Once registered, execution is correct.
- **Feed = new public surface + release-pipeline dependency** — mitigated by
  failure isolation (apk can't block ipk), atomic publish + concurrency guard,
  and the index-walk C3 test. Backend-portable URL guards against lock-in.
- **EC key loss with no overlap window bricks `apk update`** for provisioned
  devices (O7). v1 accepted risk; back up the `.pem` off-host; the additive
  rotation procedure is the mitigation if a rotation is planned.
- **Silent-failure regression** — the whole class that caused the outage;
  countered by 503-accurate multi-key `/health` (B1), **no-`quit(1)`-after-boot**
  (a broken key degrades only its own routes, never crashing the shared process —
  §4.2c), deploy ordering (B4), release-time alerting, cron self-heal, and the
  synthetic feed/cert probe (C5). These are prerequisites, not optional polish.
- **Signed downgrade via publish-order inversion** — a backfill/republish of an
  older version could serve a *trusted* downgrade; countered by the §4.3
  monotonicity guard (refuse a version ≤ live without explicit `force`).
- **Package-name collision with OpenWrt's official `tailscale`** — two providers
  on a device with both feeds; resolved by empirical verification (B0) + documented
  repo-priority pinning, not a `provider-priority` grab (§4.1).
- **Republish is version-invisible to already-attempted devices** — fixes new
  installs only; a device that ran `apk update` against a broken release must be
  told to retry (§4.6/§4.7).
- **Cross-repo drift — deploy *and* build artifact** — imprimatur merges don't
  deploy themselves (B4 human gate) and imprimatur has no published image, so C2
  clones+builds it at a pinned SHA bumped manually (§C2). Both are explicit so
  Stage C never assumes an undeployed endpoint or an unbuildable image.

## 9. References

- OpenWrt 25.12 release (apk replaces opkg): linuxiac.com/openwrt-25-12-released
- Package mgmt / `apk mkpkg` / lifecycle scripts: deepwiki openwrt 2.3;
  `include/package-pack.mk` (git.openwrt.org)
- EC signing keys (`prime256v1`, `/etc/apk/keys/*.pem`): lede-commits imagebuilder
  keys (2024-10); openwrt-devel "State of APK integration" (2024-08)
- Index-only signing decision: lede-commits "do not sign individual APK packages"
  (2025-10)
- Creating an apk feed / `apk mkndx`: forum.openwrt.org "Creating an APK OpenWrt
  repository"
- UNTRUSTED on lone `.apk` / `--allow-untrusted`: forum.openwrt.org "apk UNTRUSTED
  signature errors with packages compiled with SDK"
