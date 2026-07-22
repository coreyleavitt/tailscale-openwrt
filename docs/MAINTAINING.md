# Maintaining tailscale-openwrt

Maintainer-facing procedures that don't belong in the user-facing
[Installation Guide](INSTALL.md). Currently: retiring an apk feed arch, and
what "SBOM per family" means for the release assets.

## Arch Decommission Runbook

`arches.json` is the single source of truth for what the apk feed publishes
(30 feasible arches today, `reason == null`). Removing (or infeasible-ing)
a row is **not a no-op** -- it is a live, user-facing depublish the moment
the next feed publish runs, because of how the feed is deployed:

**Note: this runbook is apk-only.** `scripts/select-matrix.sh --ipk-arches`
is pinned to `tier=="core"` (the four historical device-targeted arches)
permanently, by design -- ipk builds do not widen with the apk feed and
never will, so there is no equivalent "ipk decommission" concern: the ipk
matrix's gate is independent of everything below.

- **Why removal is destructive.** GitHub Pages deploys are a **full-tree
  replace** (RFC `docs/rfc-apk-arch-coverage.md` §5.4): each publish
  regenerates the whole `pages-root` tree from that run's arch set and
  swaps it in atomically. There is no incremental "leave old dirs alone" --
  an arch that isn't in the current run's assembled tree simply isn't in
  the tree GitHub Pages serves afterward. A device with
  `https://apk.leavitt.dev/apk/<arch>/packages.adb` already in
  `/etc/apk/repositories.d/customfeeds.list` gets a **404 on its next `apk
  update`** -- not a stale-but-working mirror, not a soft warning.
- **The guard, and its actual scope.** `scripts/publish-feed.sh`'s
  `assemble` step diffs the run's `tier=="core"` arch set against the
  arches committed as `tier=="core"` in `arches.json`, and **hard-fails**
  if a committed core arch is about to silently disappear -- unless every
  missing one is covered by an explicit, repeatable `--allow-depublish
  <arch>` flag. This guard exists **only for `tier=="core"`** (the four
  historical arches: `aarch64_cortex-a53`, `arm_cortex-a7`, `mips_24kc`,
  `mipsel_24kc`). Removing a `tier=="extended"` row (any of the other 26)
  has **no guard today** -- it is simply excluded from the next run's arch
  list and its `apk/<arch>/` directory disappears the same way, with no
  override required and no warning printed. Treat retiring an extended
  arch with the same review discipline as a core one; the script will not
  stop you.
- **What the override does NOT do.** `--allow-depublish <arch>` does not
  archive, redirect, or soft-deprecate anything -- it only silences the
  hard-fail and prints a `WARNING: deliberately depublishing committed core
  arch '<arch>'` line to the run's log. The depublish itself (directory
  gone from the deployed tree) happens exactly the same way as any other
  arch drop.

### Retiring an arch, step by step

1. **Remove the row** (or flip it to infeasible with a `reason`) in
   `arches.json`, in a reviewed PR -- state why (upstream target dropped,
   Go dropped support, discovered-broken, etc.).
2. **Re-run the publish step with the override**, once the PR merges. As of
   this writing `--allow-depublish` is a `publish-feed.sh` script flag, not
   yet threaded through as a `workflow_dispatch` input in
   `.github/workflows/build-tailscale.yaml`'s "Assemble + sign + guard +
   retain each arch" step -- retiring a `core` arch today means running the
   same command CI runs, but locally/manually, with the flag added:
   ```bash
   sh scripts/publish-feed.sh assemble <arches-json> <built-apks-dir> <pages-root> \
       --allow-depublish <arch>
   ```
   (Repeatable for multiple arches in one retirement.) Wiring a CI-facing
   input for this is natural follow-up work, out of scope here. Retiring an
   `extended` arch needs no flag at all -- dropping the row from
   `arches.json` and letting the next normal CI publish run is sufficient,
   which is exactly why the review discipline above matters more for
   extended arches, not less.
3. **Expect the 404.** Any device still pointed at the retired arch's feed
   URL will fail its next `apk update` with a 404. There is no
   deprecation window built into the feed mechanism; if a soft-landing
   period matters for a given retirement, coordinate it manually (e.g. an
   announcement) before merging step 1.
4. **Update the docs.** If the retired arch was in the
   [unverified tier](INSTALL.md#unverified-tier) list in `docs/INSTALL.md`,
   regenerate that list from `scripts/arches.sh --unverified-arches`
   before merging -- `tests/apk/docs-arch-coverage.sh` fails the build if it
   drifts from `arches.json`.

The weekly arch-drift check (RFC §5.7 slice S9) cross-references this
runbook: `.github/workflows/check-arch-drift.yaml` runs
`scripts/detect-arch-drift.sh` against the live OpenWrt packages index every
Monday and, on a REMOVAL (an arches.json name no longer present upstream),
its warning output points here. It is warn-only -- it never edits
`arches.json` or fires a publish itself; retiring an arch is still this
runbook's deliberate, reviewed step.

## SBOM Per Family

The RFC's intent (`docs/rfc-apk-arch-coverage.md` §5.7, round-2 B-SEV3): the
30 arch-tagged `.apk` release assets are only **14 distinct binaries** --
one build per family, re-tagged 30 ways because apk bakes an `arch:` field
into each signed package (no cross-arch dedup is possible on the feed
itself). Scanning all 30 near-duplicate `.apk`s for the release SBOM would
produce ~30 near-identical SPDX entries for what is genuinely 14 pieces of
software; the RFC's stated default is to generate the SBOM/attestation
**once per family** and have the release SBOM note the arch re-tags
explicitly, falling back to accepting 30x duplication only if per-family
proves fiddly to implement.

**As implemented today, this is not yet done.** The `release-apk-assets`
job in `.github/workflows/build-tailscale.yaml` runs `anchore/sbom-action`
once, scanning the whole `release-assets/` directory (all ipk assets plus
all 30 `.apk` assets) and producing a single combined
`release-assets/sbom.spdx.json` -- one SBOM run over the full asset tree,
not per family. This documents the RFC's intent accurately; implementing
the per-family generation (or a documented decision to accept the 30x
duplication instead) is unclaimed follow-up work, not a claim about current
behavior.
