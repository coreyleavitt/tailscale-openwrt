# RFC: Generic OpenWrt-arch coverage for the apk feed

> **Architect round 1 applied (2026-07-21).** Key changes from review: unified
> single-table `arches.json` with a *computed* family (§5.2); kill the Dockerfile
> string-`case` GOARCH derivation, which is a **live latent bug** (§5.1/S2);
> decouple compile (14 Docker builds) from packaging (host-side `package-apk.sh`,
> §5.1/§5.3); correct the CI-verifiability facts (§5.6 — 9 families bootable, 5
> not); per-arch bootstrap-force for the first publish (§5.4); retry + parallelism
> on the 30-sign loop (§5.4); `arm_cortex-a7` (bare) moved to softfloat (§4, also a
> live bug); plus two **pre-existing live bugs to fix separately** (§9).

> **Architect round 2 applied (2026-07-21).** Round 2 hunted what round 1 left
> weak. Key changes: (1) the mnemonic **family id is now a tested pure function**
> with a hard-fail on unmapped tuples + a `families==14` / vocab-enum CI assertion
> (§5.2) — positional `group_by` ids were insertion-order-fragile. (2) **CI-policy
> is lifted off the per-arch row into a derived `families.sh` view** with an
> "exactly one bootable `verify` per family" invariant (§5.2). (3) A per-arch
> **`tier` field (`core` | `extended` | `infeasible`)** now unifies three concerns
> that round 1 had as separate ad-hoc mechanisms: **publish atomicity domain**
> (§5.4 — a flaky *extended* arch no longer blocks the live *core* feed ⚠ this
> revises round 1's flat "atomicity holds"; see §5.4/§5.8), bootstrap-force permit,
> and depublish-guard. (4) A **migration-safety gate** (§5.8) keeps CI pinned to
> the historical arches until S5, so the daily release cron can't publish
> wrong binaries mid-migration. (5) `install.sh`'s infeasible list is **codegen'd**
> from `arches.json` (§5.5), not hand-maintained. (6) Re-slicing for
> implementability: S1→S1a/S1b/S1c, S5→S5a/S5b, FPU-SIGILL smoke → S7a (§Slices).
> The two §9 live bugs are now **FIXED and verified on the live r2 release**.

## Summary

Make `apk add tailscale` work on **any** OpenWrt 25.12 device, not just the four
arches we currently publish. apk requires an **exact** arch match and a stock
device's `/etc/apk/arch` is a single specific string, so "generic" means
publishing a signed feed for every arch string a device can report. Because
tailscale is a `CGO_ENABLED=0` static Go binary, this is **~14 unique builds**
re-tagged across **30 feasible arch strings** — the binary is the expensive
part; per-arch packaging is a cheap host-side metadata step driven by one data
table.

Five OpenWrt arches are **infeasible** (Go cannot target them); those get a clear
"unsupported" message from the installer.

The installer half already landed (commit `15ca380`: `apk_path` selects the feed
from the device's own `/etc/apk/arch`). This RFC is the **feed/build** half.

## Goal / non-goals

**Goal:** a fresh OpenWrt 25.12 box of any Go-targetable arch runs the one-liner
(or the manual steps) and gets a **trusted** `apk add tailscale` with no
`--allow-untrusted`, no arch to look up, and **hardfloat performance where the
silicon guarantees an FPU**.

**Non-goals:**
- The 5 infeasible arches — detected + messaged, not built.
- OpenWrt ≤24.10 (stays ipk). **The ipk build must NOT widen with the apk arch
  set** — today `build-ipk` and `build-apk` share one matrix source, so §S1.5
  decouples them (feasibility H1).
- Booting all 30 arches in CI (see §5.6 — 9 bootable families verified, 5
  documented-unverified; representative + event-conditional).
- **Continuous availability of the 4 live production arches must NOT regress**
  during the 4→30 rollout (round-2 addition; the migration gate in §5.8 and the
  core/extended atomicity split in §5.4 are how this is held).

## Background — why exact-arch coverage is required

- apk-tools matches a package's `arch` field against the device's `/etc/apk/arch`
  **exactly**; a stock device lists a single arch with no family fallback.
- tailscale is a compiled binary → cannot ship as `all`/`noarch`. The escape
  hatches (`--allow-untrusted`, `apk add --arch`) discard signed trust and
  reintroduce arch fiddling. Rejected.
- Saving grace: **static Go binaries are portable within a CPU family + float
  ABI**, so one build serves many arch tags.

**Alternatives considered (and rejected):**
- *Single base-URL feed with apk appending the arch* — OpenWrt's apk consumes the
  full `.../packages.adb` URL, not a base dir (confirmed during rfc-apk-builds).
- *Softfloat-everywhere (fewer builds)* — Corey's decision is hardfloat where the
  silicon guarantees it; we keep the hardfloat variants.
- *Lazy / on-demand per-request builds* — would add a live compute+signing
  dependency on the request path, the exact coupling the imprimatur outage
  post-mortem removed; it breaks the static-Pages/TOFU simplicity. Eager fan-out
  keeps the host a dumb static mirror. Rejected.

## The arch → Go-build mapping (authoritative)

Source: shared feed index `downloads.openwrt.org/releases/25.12.0/packages/`
cross-checked against real rootfs `/etc/apk/arch`, `readelf` on downloaded
rootfs binaries, OpenWrt `include/target.mk`, and Go port minimums. `float` = the
ABI OpenWrt encodes in the arch name (FPU suffix ⇒ hard; absent ⇒ soft).
`GOARM/GOMIPS/GO386` = the **crash-safe** build for that silicon. Full 35-arch
table in the Appendix; the **14 family builds** covering the 30 feasible arches:

| family | GOARCH / flags | arch strings served | # | CI-bootable rootfs? |
|---|---|---|---|---|
| A64 | arm64 | aarch64_generic, aarch64_cortex-a53, -a72, -a76 | 4 | ✅ armsr/armv8 |
| A7HF | arm GOARM=7 (VFPv3+ hard) | cortex-a5_vfpv4, cortex-a7_vfpv4, cortex-a7_neon-vfpv4, cortex-a8_vfpv3, cortex-a9_neon, cortex-a9_vfpv3-d16, cortex-a15_neon-vfpv4 | 7 | ✅ armsr/armv7 |
| A6HF | arm GOARM=6 (VFPv2 hard) | arm1176jzf-s_vfp | 1 | ❌ (Pi1 image only) |
| ASOFT | arm GOARM=5 softfloat | **arm_cortex-a7 (bare)**, arm_cortex-a9 (bare), arm926ej-s, xscale | 4 | ❌ |
| M32BE | mips GOMIPS=softfloat | mips_24kc, mips_mips32 | 2 | ✅ malta/be |
| M32LE | mipsle GOMIPS=softfloat | mipsel_24kc, mipsel_74kc, mipsel_mips32 | 3 | ✅ malta/le |
| M32LEHF | mipsle GOMIPS=hardfloat | mipsel_24kc_24kf | 1 | ❌ |
| M64BE | mips64 GOMIPS64=hardfloat | mips64_mips64r2, mips64_octeonplus | 2 | ✅ malta/be64 (r2 only; octeon ❌) |
| M64LE | mips64le GOMIPS64=hardfloat | mips64el_mips64r2 | 1 | ✅ malta/le64 |
| X86SSE2 | 386 GO386=sse2 | i386_pentium4 | 1 | ✅ x86/generic |
| X86SOFT | 386 GO386=softfloat | i386_pentium-mmx | 1 | ⚠ re-check (§5.6 — same x86 target as X86SSE2) |
| AMD64 | amd64 | x86_64 | 1 | ✅ x86/64 (native, no qemu) |
| RV64 | riscv64 | riscv64_generic | 1 | ❌ (board SD images only) |
| LOONG64 | loong64 (NOT loongarch64) | loongarch64_generic | 1 | ✅ loongarch64/generic |

**Decision (Corey):** all 30 feasible, hardfloat where the silicon guarantees an
FPU. 14 builds total.

**Correctness catches (verified against upstream, some corrected in round 1):**
- **`arm_cortex-a7` (bare) is softfloat → ASOFT/GOARM=5, NOT A7HF.** OpenWrt's
  bare `cortex-a7` arch exists for FPU-less silicon (`CPU_CFLAGS_cortex-a7` has no
  `-mfpu`, unlike `cortex-a7_vfpv4`/`_neon-vfpv4`); a GOARM=7 binary SIGILLs there.
  This matches the already-correct treatment of bare `cortex-a9`. **✅ FIXED live
  (r2): the 4-arch feed now ships `arm_cortex-a7` at GOARM=5, see §9.**
- `loong64` is Go's spelling (not `loongarch64`).
- MIPS64 is hardfloat (r2 mandates an FPU); Go `GOMIPS64` default is hardfloat.
- `GO386=softfloat` (Pentium-MMX) and `sse2` (Pentium4) both current-Go-supported.
- MIPS `24kc`/`74kc`/`mips32` share one binary safely — Go's MIPS backend targets
  a fixed conservative baseline regardless of microarch (verified at ISA level).
- ASOFT groups ARMv5TE (`arm926ej-s`/`xscale`) with bare ARMv7 (`cortex-a9`/`-a7`)
  — GOARM=5 code is a strict subset runnable on all later ARM cores (correct).
- `CGO_ENABLED=0` static ⇒ **no per-arch C toolchain**; the only question is
  whether the CPU can execute Go's emitted instructions.

## Design

### 5.1 Decouple compile (per family) from packaging (per arch)

Two separated modules with one clean interface (a binary path in, an `.apk` out):

- **Compile (Docker, 14 invocations):** the Go build stage takes **explicit**
  `GOARCH/GOARM/GOMIPS/GOMIPS64/GO386` build-args sourced from the family row —
  `CGO_ENABLED=0`, `GOOS=linux`. Produces 14 static `tailscaled` binaries,
  extracted as CI artifacts. **The current Dockerfile derives GOARCH by
  string-`case` on the arch name with a `*) → mips` default and a hardcoded
  `GOMIPS=softfloat` (Dockerfile ~133-138); that silently mis-builds every arch
  outside `aarch64*`/`arm_cortex*`/`mipsel*` (x86_64, riscv64, loong64, mips64,
  a6hf… → 32-bit MIPS). S2 DELETES that block and drives the build from the family
  fields, with a negative test: an unrecognized/new arch must hard-fail, never
  silently fall through.** S2 also adds the missing `ARG GOARCH` (+ GOMIPS64/GO386)
  to the Dockerfile `build` stage — until those `ARG`s exist, a `--build-arg
  GOARCH=…` is silently *ignored* by Docker (warn, not error), so the wiring and
  the `ARG` declarations must land in the same slice (feasibility, S2).
- **Package (host-side shell, 30 invocations):** a new
  `scripts/package-apk.sh --binary <family-binary> --arch <arch-name>
  --version <ver-with-release> --payload <src-dir> --out <outfile>` wraps
  `apk mkpkg --info arch:<name> --files … --script …` using the already-extracted
  static host `apk` binary — **no Docker, no toolchain**. Binary bytes are
  identical across a family's arches; only `.PKGINFO`'s `arch:` differs.
  Unit-testable in `tests/apk/mkpkg.sh` without any qemu/Docker round-trip.
  - **Named flags, not bare positionals (round-2 D-SEV3).** Round 3 of
    rfc-apk-builds already learned this lesson on `publish-arch.sh` (an
    implicitly-derived filename was made an explicit named arg). `package-apk.sh`
    applies it from the start: 5 transposable positionals (esp. adjacent
    `version`/`pkg-release`) are a silent-mispackage class in a 30× loop.
    `--version` takes the **already-joined** `1.98.9-r2` string (the one value apk's
    `--info version:` actually wants), computed once by the caller — killing the
    third independent copy of that string-join (today in `build-apk.sh` and the
    Dockerfile).
  - **One payload source of truth (round-2 P-SEV3/F-SEV3).** The on-device payload
    tree (`tailscale-package/src/*` + maintainer scripts + perms + conffiles) is
    assembled today *inside* the Docker `apk`/`ipk` stages. Moving apk packaging
    host-side would create a **second** independently-maintained copy of that
    staging logic. S3 instead factors the payload manifest into one
    `scripts/stage-payload.sh` (or a declared file list) consumed by **both**
    `package-apk.sh` and the Dockerfile `ipk` stage, and the `--payload` arg makes
    the CWD/relative-path assumption explicit (testable from a non-repo-root CWD).
  - **Retire the code it replaces.** S3/S4 make the Dockerfile `apk` stage and the
    current `docker build --target apk`-based `tests/apk/mkpkg.sh` dead code; S4
    deletes them so two "package the apk" implementations can't drift.

### 5.2 Data model — per-arch table + derived family view

Reject a 3-table (families/arches/unsupported) split: "family" is not an
independent fact, it's a **computed grouping key** over each arch's own build
tuple, and authoring it as an FK invents an invariant that needs a test to guard.
`arches.json` is the **Appendix's single 35-row shape** — one row per arch
carrying its own raw tuple and *per-arch* facts only:

```
{ "name": "mipsel_24kc_24kf", "goarch": "mipsle", "goarm": "", "gomips": "hardfloat",
  "gomips64": "", "go386": "", "endian": "little", "float": "hard",
  "reason": null,                       // non-null ⇒ infeasible (the "unsupported" set)
  "container_arch": "mipsel",           // RETAINED — select-matrix.sh + tests/apk/install.sh depend on it
  "canary": false,                      // PR-signal arch (per-arch)
  "tier": "extended" }                  // "core" | "extended" | "infeasible" — see below
```

- **Family is derived**, never authored: `jq 'group_by(.goarch,.goarm,.gomips,.gomips64,.go386)'`
  yields the 14 build groups. Adding an arch is **one row** whether or not it
  reuses a family — no second table to remember.
- **The mnemonic family id (A64…) is a tested pure function, not positional
  (round-2 D-SEV1/F-SEV3).** `group_by` orders groups by the tuple's lexicographic
  sort, so a *positional* id assignment silently renames every family after a
  newly-inserted tuple — renaming compile jobs, `apk-<family>` artifacts, and any
  cross-run correlation (re-run-failed-jobs, an S5 checkpoint). Instead
  `scripts/families.sh --id-for <goarch> <goarm> <gomips> <gomips64> <go386>`
  is a small pure function mapping a build tuple → a stable mnemonic, which:
  1. **hard-fails** on an unmapped tuple (mirrors S2's Dockerfile negative test —
     a new family must be a deliberate, reviewed addition, never a silent generic);
  2. is **insertion-order-independent** by construction (content-derived).
  The mnemonic table lives in exactly one place (this function); it is cosmetic
  (naming only), *not* a membership-defining FK, so it does not reintroduce the
  authored-FK anti-pattern — membership is still the computed `group_by`.
- **Schema is CI-guarded (round-2 P-SEV3).** `group_by` can't tell "deliberately
  distinct" from "accidentally distinct" (`"5"` vs `5`, `"soft-float"` typo → a
  spurious 1-arch family). S1 adds a validator: **the derived family count is
  exactly 14**, and `goarch`/`float`/`endian`/`gomips`/`go386`/`tier` are
  **enum-validated** against a fixed vocabulary. A typo hard-fails CI, not the feed.
- **CI-verification policy is a derived families *view*, not per-arch columns
  (round-2 D-SEV2).** `verify`/`rootfs_target`/`rootfs_url`/`rootfs_sha256` are
  per-*family* facts ("the CI-boot representative for family X"), not build-tuple
  facts — smearing them across 30 rows (mostly null) invents an unenforced
  "exactly one verify row per family" convention. Instead
  `scripts/families.sh --with-ci` emits **one row per family (14)** carrying the
  boot representative + rootfs pin. That view is where two structural invariants
  live: **(a) exactly one `verify` arch per family, and (b) it MUST be a bootable
  arch string** (e.g. `mips64_mips64r2`, not `octeonplus`; §5.6). `canary` stays
  per-arch (it names a specific arch string for the PR signal); every `canary`
  arch's family must be `verify`-able (canary ⊆ verify).
- **`tier` unifies three round-1 mechanisms (round-2, see §5.4/§5.8).** Instead of
  a separate external `published-arches` list (round 1) + an ad-hoc atomicity note
  + no depublish guard, one per-arch `tier` drives all three: `core` = protected
  production arches (all-or-nothing publish, depublish-guarded); `extended` =
  best-effort new arches (bootstrap-force permitted until promoted); `infeasible`
  = `reason != null`, never built. Promotion `extended`→`core` is a deliberate,
  reviewed `arches.json` edit after an arch has published cleanly (§5.8).

### 5.3 Packaging + build fan-out (workflow)

One matrix over the **14 families** (compile). **Within each family's job**, a
plain shell loop over that family's arches (derived via `families.sh`) calls
`package-apk.sh`, uploading arch-namespaced `apk-<archname>` artifacts — no second
matrix stage, no redundant artifact re-fetch (design F4). Artifact/asset naming
stays arch-namespaced (`tailscale-<ver>-r<rel>-<archname>.apk`).

**`select-matrix.sh` becomes a multi-output selector (round-2 F-SEV2/P-SEV2).**
Today it emits ONE array consumed identically by `build-ipk`, `build-apk`,
`qemu-verify`, `apk-install-verify`. Post-widening those need **different shapes**,
so S1 defines an explicit multi-output contract (each a named workflow output):
- `ipk_arches` — the historical/legacy set (S1.5; ipk must not widen).
- `compile_families` — the 14 family build tuples (build-apk matrix).
- `publish_arches` — event-conditional; PR = canary subset, release = all
  feasible; each row's `tier` carried through for the §5.4 atomicity split.
- `verify_families` — the bootable representative per family (S7a), from the
  `--with-ci` view.
- **PR-canary keys strictly on `canary == true`.** The current
  `select(.canary == true or .container_arch == "aarch64")` (`select-matrix.sh:43`)
  matches exactly one row today, but once A64 has four `aarch64` rows it pulls
  **all four** into every PR emulation leg (round-2 P-SEV2). The
  `container_arch`-OR clause is **deleted**; a test asserts PR selection is
  independent of how many arches share a `container_arch`.

### 5.4 Feed publish fan-out

`publish-feed` loops arches → `publish-arch.sh` per arch (30 signed
`packages.adb`). Required changes at 30×:

- **Two atomicity domains, not one (round-2 B-SEV1/P-SEV2 — revises round 1).**
  Round 1 said "atomicity holds" (single `deploy-pages` after the whole loop). At
  4 hand-curated arches that was safe; at 30 (26 of them new / less-proven) a
  *single* flaky arch — a failed `build-apk` leg, a transient sign error — aborts
  the whole step **before** `deploy-pages`, so the 4 **live production** arches
  stop getting the new version purely because an immature arch broke. Fix: the
  publish loop is split by `tier`:
  - **`core` arches publish all-or-nothing** (unchanged strong guarantee): if any
    `core` arch fails to build+sign+guard, the deploy aborts — production is never
    half-updated. This preserves the round-1 property *for the arches that matter*.
  - **`extended` arches are best-effort**: a failed `extended` arch is
    `log()`-ged loudly, dropped from *this* publish, and does **not** abort the
    deploy. The deploy carries `core` + all `extended` arches that succeeded.
  - The single `deploy-pages` stays (one atomic tree swap); "which arches are in
    it" is what varies. **⚠ This is the one round-2 change that revises a round-1
    property; called out for Corey's veto in the handoff.** (Alternative if strict
    all-30-or-nothing is preferred: a promotion gate where an `extended` arch must
    build green N times before its failures become fatal — heavier, deferred.)
- **Depublish guard (round-2 B-SEV2).** GH Pages does a full-tree replace each
  deploy; a `core` arch silently dropped from `arches.json` (bad merge, typo'd
  rename, over-eager prune) would **un-publish a live arch** for real devices. The
  existing `ARCH_COUNT -ge 1` check only catches a fully-empty matrix. Add: before
  deploy, diff the run's `core` arch-name set against the committed `tier=="core"`
  set and **hard-fail** if a `core` arch is about to disappear, unless an explicit
  `--allow-depublish <arch>` override is passed (arch retirement is deliberate,
  §5.7/S9).
- **Parallelize the loop, but establish the signer's ceiling first (round-2
  B-SEV2/P-SEV2).** `publish-arch.sh` is per-arch isolated (per-arch `ARCH_DIR`,
  per-invocation `mktemp` — verified), so client-side `xargs -P<N>` is locally
  safe. But that says nothing about `sign.leavitt.info`: this is the service whose
  *silent-failure* trap caused the ~2-month outage. **S5a adds a spike** to
  establish imprimatur's safe concurrent-`/sign/ec` ceiling (thread-safety of the
  EC signer, Traefik pool limits, any rate limit) — or adds a server-side
  semaphore — before hardcoding `N`. Promote the timing check from "watch" to an
  S5a deliverable with an assertion against a stubbed signer (mirroring
  `tests/apk/feed-publish.sh`).
- **Retry + backoff + per-arch checkpoint (round-2 P-SEV2 — no longer
  aspirational).** Each `/sign/ec` POST gets 3× retry/backoff (mirror the
  `release` job's loop). A concrete **checkpoint**: an arch whose
  `ARCH_DIR/packages.adb` already verified in *this* run is skipped on re-dispatch,
  so a retry re-signs only the arch(es) that actually failed — at 30× the odds of
  ≥1 transient failure per run are ~7.5× a 4-arch run, so a bare "re-run re-signs
  all 30" is not acceptable.
- **Post-publish integrity verify: accumulate + settle (round-2 B-SEV3/P-SEV3).**
  The `feed-guard.sh verify-tree` walk runs *after* `deploy-pages` (detect-only —
  it can't roll back). At 30 near-simultaneous fetches right after a fresh Pages
  deploy, ordinary CDN propagation lag will trip it. Two fixes: (a) a bounded
  retry/settle before the first check (distinguish propagation lag from
  corruption), and (b) **accumulate failures across the whole loop** and report
  the *complete* failing set to `notify-alert.sh` — don't `set -e` out on arch #3
  and never check #4–30.

### 5.5 Installer — clean unsupported-arch UX

`apk_path` already reads `/etc/apk/arch`. Add, before `apk update`:
- **Infeasible arch** (in the `reason`-bearing set): print "tailscale can't be
  built for <arch> (Go has no support: <reason>)" and exit. **This block is
  codegen'd from `arches.json` at publish time (round-2 D-SEV2), not
  hand-maintained.** §5.2's own rule ("no authored duplicate + a drift-guard
  test") applies here too: a hand-written `case` block + a CI check that it matches
  the `reason != null` set is *three* artifacts that must agree. Instead the
  publish step generates the `case` block from `arches.json` and inlines the
  **result** into the published `install.sh` — the shipped script stays exactly as
  standalone as today (one self-contained fetched file, zero runtime dependency on
  `arches.json`), but there is only one source and one generation step, nothing to
  drift.
- **Feasible-but-not-published:** DON'T ship a 30-entry supported list (redundant,
  drifts, and `install.sh` is fetched standalone with no companion data). Let
  `apk update` 404 and translate it to "arch <x> isn't in the feed."
- **Hardware-capability caveat (depth SEV4):** `apk add` success ≠ runtime success
  (a VFP-needing binary on an FPU-less core installs then SIGILLs). The §4 softfloat
  assignments (esp. bare cortex-a7/-a9) are what prevent this; the regression check
  that guards it is a qemu-capability spike, moved to **S7a** (round-2 F-SEV4 — it's
  emulation-infra work, not installer-message work; and whether qemu-user will even
  SIGILL on an FPU-less CPU model is itself an open spike question). S6 tests must
  fixture a CRLF/multi-line `/etc/apk/arch` too.

### 5.6 CI verification strategy (corrected)

**9 of 14 families have a bootable generic 25.12 rootfs** (table §4): A64, A7HF,
M32BE, M32LE, M64BE (`mips64_mips64r2` via malta/be64), M64LE (malta/le64),
X86SSE2 (x86/generic), AMD64 (native), LOONG64 (loongarch64/generic). **4 do not**
(A6HF, ASOFT, M32LEHF, RV64) plus `mips64_octeonplus` within M64BE. **X86SOFT is
re-classified to "re-check" (round-2 P-SEV4):** `i386_pentium-mmx` is the *same x86
architecture* as the bootable X86SSE2 — bootability is a function of the rootfs
image + QEMU CPU model, not the `GO386` flag baked into the binary, so it is not
self-evident it can't boot off `x86/generic` (or `x86/legacy`) with a non-SSE2 CPU
model. S7a's spike resolves it; until then it ships in the S7b unverified tier.
So:
- **S7a** — native-arch qemu-boot verify (drop the `/etc/apk/arch` override that
  hid the original mismatch) for the bootable families, event-conditional
  (PR = canary subset; release = full set), reusing `select-matrix`'s policy.
  Spikes required first, **each with a defined failure fallback (round-2 F-SEV2):**
  - **M2** — does OpenWrt's 64-bit musl need custom `binfmt` like 32-bit MIPS did?
  - **M3** — does **loong64** exec under the runner's qemu-user? (riscv64 is
    *dropped* from M3 — RV64 has no bootable rootfs and is S7b, so probing its
    qemu-exec for S7a is scope drift.)
  - **FPU-SIGILL smoke** (moved from S6) — can qemu-user faithfully SIGILL a
    wrongly-hardfloat binary on an FPU-less ARM CPU model, so the softfloat
    assignments are actually regression-guarded? Its own spike question.
  - **Fallback rule:** a spike that fails (runner's pinned qemu can't exec a
    target that upstream nonetheless ships a rootfs for) ⇒ that family **moves to
    S7b's unverified tier**, and §4's ✅ becomes a footnoted "✅ rootfs exists,
    CI-unverifiable." S7a never stalls indefinitely on an unresolved spike.
- **S7b** — the unverifiable families ship on **architectural certainty**,
  explicitly listed as an "unverified" tier and `log()`-ged at publish time (a
  named S7 acceptance criterion, depth SEV3) so coverage is never silently
  overstated; surfaced in docs (§S8).
- **Compile-smoke every family (M1):** loong64 has no Tailscale-official prior art
  (they don't ship it; riscv64/mips64 they do). S2 must compile-smoke all 14
  families (not just the 4 legacy) before S3/S4 publish them. **Cross-compilation
  needs no qemu** (it runs on the amd64 host regardless of target), so M1 is cheap
  and distinct from the S7a exec spikes.

### 5.7 Release assets, retention, drift (breadth)

- **C4 `release-apk-assets`** scales trivially: attach 30 renamed `.apk`s +
  combined `SHA256SUMS`/SBOM via the existing glob (GitHub allows ≫30 assets). No
  design change beyond the loop bound. **Its live signing bug is ✅ FIXED — §9.**
- **SBOM at 30× (round-2 B-SEV3):** the 30 arch-tagged `.apk`s are only **14
  distinct binaries** re-tagged. Generate the SBOM/attestation **once per family**
  (14) and cross-reference, rather than scanning 30 near-duplicate SPDX entries;
  the release SBOM notes the arch re-tags. (If per-family proves fiddly, accepting
  the duplication is documented-harmless — but per-family is the default.)
- **Retention/storage (S5b measurement):** `RETAIN_N=3` × 30 arches = up to 90
  `.apk` blobs live on Pages (apk bakes `arch:` into each signed package, so no
  cross-arch dedup). Measure real size × 30 × N against Pages' ~1 GB soft limit
  and set `RETAIN_N` deliberately; note why family binaries can't be deduped.
- **Arch-drift check (slice S9):** a low-frequency (weekly) CI job diffing the live
  OpenWrt packages index arch set against `arches.json` names, **warning** (not
  failing) on additions/removals — mirrors the existing version-drift cron so
  "which arches exist" can't silently rot.
- **Arch decommission runbook (round-2 B-SEV4/P-SEV2):** removing a row from
  `arches.json` is itself a silent depublish (§5.4 full-tree replace). S8/S9 docs
  carry a short runbook: retiring an arch is a deliberate, reviewed step requiring
  the `--allow-depublish` override, and states what it does to the live tree.

### 5.8 Migration safety — the 4→30 rollout ordering (round-2 F-SEV1/B-SEV2)

The rollout must never let a half-finished migration publish wrong binaries to the
live feed. Two concrete hazards and their gates:

- **The daily release cron is live.** `check-releases.yaml` fires
  `build-tailscale.yaml` on every new upstream Tailscale tag with the full
  build→sign→publish pipeline. If S1 widens `arches.json`/`select-matrix.sh`
  **before** S2 (Dockerfile fix) lands, a release landing in that window
  auto-publishes binaries built by the still-buggy string-`case` GOARCH block
  (every non-legacy arch → 32-bit MIPS). **Gate:** the `tier` field doubles as the
  migration gate — through S1–S4, `select-matrix.sh`'s `publish_arches`/
  `compile_families` outputs filter to `tier=="core"` (the 4 historical arches);
  the widen to include `tier=="extended"` is a **single, named, tail-end step in
  S5** (`compile_families` and `publish_arches` drop the `core`-only filter), after
  S2/S3/S4 have proven the pipeline on all 14 families in CI without publishing.
  Data (S1b) and behavior (the S5 gate flip) are separated so the widened rows sit
  **inert** until the pipeline is ready.
- **S1 is decomposed (feasibility F-SEV1).** Round 1's S1 bundled a schema rewrite
  with a lockstep migration of ~13 consumers — not atomically `/tdd`-able, and
  several consumers can't be *meaningfully* migrated until S2–S4 exist (e.g.
  `build-apk.sh` passing `--build-arg GOARCH` is a silent no-op until S2 adds the
  `ARG`). Split:
  - **S1a** — schema-only: add the v2 fields (`gomips64`/`go386`/`float`/`reason`/
    `tier`) to the *existing 4 rows*, ship `scripts/families.sh` (id-for +
    --with-ci + the family-count/vocab validator) + loader test. No widening, no CI
    rewiring.
  - **S1b** — widen `arches.json` to the 35-row table, all new rows `tier` =
    `extended`/`infeasible`, **gated inert** by the §5.8 filter (they compile-smoke
    in S2 but don't publish until the S5 gate flip).
  - **S1c** — migrate each consumer's schema-field references (`select-matrix.sh`
    multi-output + canary-only PR key; `check-releases.yaml` `.[0].name` →
    `canary`-keyed selection + an order-independence test; `republish-feed`
    `jq '.[].name'`; `build-apk.sh`; the flat-array assumptions in the 9 test
    files), one file per commit. Build-arg wiring is handed to **S2**; the
    `install.sh`/`qemu.sh`/`mkpkg.sh` packaging-invocation rewrites to **S3/S4**.
- **S1 + S1.5 land as one deployment unit.** Merging S1 alone would widen
  `build-ipk`'s matrix to 30 (it shares the matrix source), violating the ipk
  non-goal for a live window. They are never separately shippable.
- **Rollback (round-2 B-SEV2).** `republish-feed` gains an optional
  **arch-allowlist input** so a bad `extended` arch can be rolled back (or an older
  release re-published) *without* looping the full `arches.json` and force-
  downgrading the healthy `core` arches past the monotonicity guard.

## Slices (for `/tdd`)

- **S1a** — schema-only `arches.json` v2 fields on the existing 4 rows;
  `scripts/families.sh` (`--id-for` pure fn with hard-fail on unmapped tuple;
  `--with-ci` families view with the one-bootable-`verify`-per-family invariant;
  a `families==14` + enum-vocab validator) + loader/deriver tests, including an
  **id-stability test** (a row-order shuffle and an added-arch-to-existing-family
  must not change any family id).
- **S1b** — widen `arches.json` to the 35-row table (new rows `tier` =
  `extended`/`infeasible`), **gated inert** (§5.8) so they don't publish yet.
- **S1c** — per-consumer schema-field migration, one file per commit:
  `select-matrix.sh` (multi-output contract; PR key on `canary` only, delete the
  `container_arch` OR-clause); `check-releases.yaml` (`.[0].name` → `canary`-keyed
  + order-independence test); `republish-feed`; `build-apk.sh`; the flat-array
  assumptions in `tests/apk/{apk-matrix,ipk-matrix,qemu,host-apk,rootfs,install,
  install-dispatch,sign-verify,upgrade-downgrade}.sh`.
- **S1.5** — decouple `build-ipk`'s matrix from `build-apk`'s: `select-matrix.sh`
  emits `ipk_arches` (historical set) so widening apk doesn't build 30 ipks
  (feasibility H1). **Ships atomically with S1a–S1c** (§5.8).
- **S2** — compile stage: add `ARG GOARCH/GOMIPS64/GO386` to the Dockerfile,
  data-driven explicit build-args, DELETE the string-`case` GOARCH block (+ negative
  test: unknown arch hard-fails), extract a per-family **binary artifact**;
  compile-smoke all 14 families; **byte-identical for the 4 legacy arches — an
  explicit empirical sha256-diff step** (old derive-by-case vs new explicit
  build-arg), with a documented fallback if it doesn't hold exactly (identical
  modulo one embedded build-id field; round-2 F-SEV3).
- **S3** — `scripts/package-apk.sh` (host-side, named flags, `--payload` arg) +
  `scripts/stage-payload.sh` shared with the Dockerfile ipk stage +
  `tests/apk/mkpkg.sh` (rewritten to exercise the host-side path).
- **S4** — build-apk = matrix over 14 families, package that family's arches
  in-job (shell loop), arch-namespaced artifacts; **delete the dead Dockerfile apk
  stage** and the old `docker build --target apk` test path.
- **S5a** — publish fan-out mechanics: imprimatur safe-concurrency spike →
  parallelized loop, per-arch retry/backoff + concrete per-arch checkpoint,
  post-publish verify accumulate-all + settle/retry, timing assertion. **Then the
  migration gate flip (§5.8): `compile_families`/`publish_arches` drop the
  `core`-only filter** — the single step that makes the 30 arches go live.
- **S5b** — first-publish rollout: per-arch bootstrap-force via `tier=="extended"`,
  the core/extended atomicity split + depublish-guard, `republish-feed` rollback
  allowlist, retention measurement + deliberate `RETAIN_N`.
- **S6** — installer infeasible-arch message **codegen'd from `arches.json`** at
  publish time; drop supported list; CRLF/multi-line `/etc/apk/arch` test.
- **S7a** — native-arch qemu verify for the bootable families; spikes first (M2
  64-bit-musl binfmt; M3 loong64 exec; FPU-SIGILL smoke), **each with the
  spike-failure → S7b fallback**; resolve X86SOFT bootability; event-conditional.
- **S7b** — "unverified tier" list + publish-time `log()` of published-but-not-
  booted arches.
- **S8** — docs: README/INSTALL 30-arch table (dynamic `$(head -1 /etc/apk/arch)`
  in examples, not 30 rows), unverified-tier callout, mirroring note, **arch
  decommission runbook**, SBOM-per-family note.
- **S9** — weekly arch-drift check vs the OpenWrt packages index (warn-only);
  cross-reference the decommission runbook.

## §9 — Pre-existing LIVE bugs surfaced by this review — ✅ FIXED (verified on r2)

Both were fixed outside the RFC scope and **verified on the live 1.98.9-r2 release**
(build 29873239215, 2026-07-21):

1. **`SHA256SUMS.sig` mismatch → GL.iNet installs fail.** `release-apk-assets`
   regenerated a *combined* `SHA256SUMS` (ipk+apk+pem) but never re-signed; the
   `release` job's `.sig` covered the old ipk-only bytes, so `install-glinet.sh`'s
   `usign -V` failed on every release. **Fixed:** `release-apk-assets` now re-signs
   the combined file (join + `/sign/usign` + attach `.sig`). **Verified:** combined
   `SHA256SUMS` carries all 12 entries and `SHA256SUMS.sig` cryptographically
   verifies (ed25519, key-id `260114ce974e57e5`).
2. **`arm_cortex-a7` built GOARM=7 (hardfloat) but bare cortex-a7 can be FPU-less**
   → SIGILL after a "successful" install. **Fixed:** `arm_cortex-a7 → GOARM=5`
   (softfloat); the CI docker builds now honor `goarm`/`gomips` from `arches.json`.
   **Verified:** `arches.json` ships `goarm:5`; the r2 apk is live and the feed
   serves `1.98.9-r2` for all four arches.

(A third field-reported issue — GOMEMLIMIT breaking tailscaled's data path on
low-RAM devices, masked by a procd `set`→`append` bug — was fixed in the same
batch: GOMEMLIMIT dropped, GOGC-only tuning; see `docs/gomemlimit-field-report.md`.)

## Appendix — full 35-arch table

(30 feasible + 5 infeasible; `family` empty ⇒ infeasible / `reason != null`.)

| arch string | GOARCH | GOARM | GOMIPS/64 | GO386 | endian | float | family | feasible |
|---|---|---|---|---|---|---|---|---|
| aarch64_generic | arm64 | — | — | — | little | hard | A64 | ✅ |
| aarch64_cortex-a53 | arm64 | — | — | — | little | hard | A64 | ✅ |
| aarch64_cortex-a72 | arm64 | — | — | — | little | hard | A64 | ✅ |
| aarch64_cortex-a76 | arm64 | — | — | — | little | hard | A64 | ✅ |
| arm_cortex-a5_vfpv4 | arm | 7 | — | — | little | hard | A7HF | ✅ |
| arm_cortex-a7_vfpv4 | arm | 7 | — | — | little | hard | A7HF | ✅ |
| arm_cortex-a7_neon-vfpv4 | arm | 7 | — | — | little | hard | A7HF | ✅ |
| arm_cortex-a8_vfpv3 | arm | 7 | — | — | little | hard | A7HF | ✅ |
| arm_cortex-a9_neon | arm | 7 | — | — | little | hard | A7HF | ✅ |
| arm_cortex-a9_vfpv3-d16 | arm | 7 | — | — | little | hard | A7HF | ✅ |
| arm_cortex-a15_neon-vfpv4 | arm | 7 | — | — | little | hard | A7HF | ✅ |
| arm_arm1176jzf-s_vfp | arm | 6 | — | — | little | hard | A6HF | ✅ |
| **arm_cortex-a7 (bare)** | arm | **5** | — | — | little | **soft** | **ASOFT** | ✅ |
| arm_cortex-a9 (bare) | arm | 5 | — | — | little | soft | ASOFT | ✅ |
| arm_arm926ej-s | arm | 5 | — | — | little | soft | ASOFT | ✅ |
| arm_xscale | arm | 5 | — | — | little | soft | ASOFT | ✅ |
| arm_fa526 | — | — | — | — | little | soft | — | ❌ ARMv4 < Go GOARM=5 |
| armeb_xscale | — | — | — | — | big | soft | — | ❌ no big-endian ARM in Go |
| mips_24kc | mips | — | softfloat | — | big | soft | M32BE | ✅ |
| mips_mips32 | mips | — | softfloat | — | big | soft | M32BE | ✅ |
| mipsel_24kc | mipsle | — | softfloat | — | little | soft | M32LE | ✅ |
| mipsel_74kc | mipsle | — | softfloat | — | little | soft | M32LE | ✅ |
| mipsel_mips32 | mipsle | — | softfloat | — | little | soft | M32LE | ✅ |
| mipsel_24kc_24kf | mipsle | — | hardfloat | — | little | hard | M32LEHF | ✅ |
| mips64_mips64r2 | mips64 | — | hardfloat | — | big | hard | M64BE | ✅ |
| mips64_octeonplus | mips64 | — | hardfloat | — | big | hard | M64BE | ✅ (unverified) |
| mips64el_mips64r2 | mips64le | — | hardfloat | — | little | hard | M64LE | ✅ |
| i386_pentium4 | 386 | — | — | sse2 | little | hard | X86SSE2 | ✅ |
| i386_pentium-mmx | 386 | — | — | softfloat | little | soft | X86SOFT | ✅ |
| x86_64 | amd64 | — | — | — | little | hard | AMD64 | ✅ |
| riscv64_generic | riscv64 | — | — | — | little | hard | RV64 | ✅ |
| loongarch64_generic | loong64 | — | — | — | little | hard | LOONG64 | ✅ |
| powerpc_8548 | — | — | — | — | big | hard | — | ❌ 32-bit PPC (Go: ppc64/le only) |
| powerpc_464fp | — | — | — | — | big | hard | — | ❌ 32-bit PPC (Go: ppc64/le only) |
| powerpc64_e5500 | — | — | — | — | big | hard | — | ❌ POWER7-class; Go ppc64 needs POWER8 |

Bare `arm_cortex-a7`/`-a9` FPUs are optional ⇒ GOARM=5 crash-safe. MIPS64
`octeonplus` (Cavium OCTEON+) ships unverified (no bootable rootfs; shares the
`mips64_mips64r2` binary, verified at Go-flag level only).

**CI-bootability reasons for the S7b unverified tier (round-2 P-SEV4 — one
citation standard for all):** A6HF — Pi1 image only, no generic armv6 rootfs;
ASOFT — no FPU-less generic ARM rootfs (armsr images assume VFP); M32LEHF — no
hardfloat 32-bit MIPS generic rootfs (malta/le is softfloat); RV64 — board SD
images only, no generic rootfs tarball; `mips64_octeonplus` — Cavium-specific, no
generic rootfs. **X86SOFT (`i386_pentium-mmx`) is *not* asserted unbootable** — it
shares x86 targets with the bootable X86SSE2 and is flagged for the S7a spike to
resolve (§5.6).
