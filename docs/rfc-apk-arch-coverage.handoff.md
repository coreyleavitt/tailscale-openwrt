# RFC: Generic OpenWrt-arch coverage — handoff

- **Stage:** 3 /tdd slice grind — **6/14 done** (S1a/S1b/S1c/S2/S3/S4)   •   **RFC:** `docs/rfc-apk-arch-coverage.md`
- **Branch:** `rfc-apk-arch-coverage` (off master; keep.d fix `92f6b97` is the base). Commits: `8c70672`
  RFC doc · `6bbbcc0` S1 · `f41fd43` S2 · `a6b12dc` S3 · S4 committing now. NOT pushed yet. Handoff docs
  untracked (working docs). Next: S5a.
- **S4 verified:** `select-matrix.sh --families` emits one row per gated family (4 core: A64/ASOFT/M32BE/
  M32LE), each carrying its build tuple + sorted gated arch list; order-independent. `build-apk` job
  rewritten: matrix over `families`, `docker build --target build` once per family, then a shell loop over
  `matrix.family.arches` calls `package-apk.sh` per arch (compile-once/package-loop). Dockerfile `apk` stage
  DELETED (only `apk-tools`/`build`/`ipk` remain); `--target apk` appears nowhere in workflow/tests except
  deletion-comments (asserted by apk-matrix.sh). All `--target apk` callers migrated to `--target build` +
  `package-apk.sh` via new `build_apk_host` helper in tests/apk/lib.sh. M32BE/mips_24kc proven end-to-end via
  real docker build + adbdump (arch/version/deps/conffiles/keep.d/3 maintainer scripts all correct).
  **⚠ S5a follow-up (guarded, not a bug):** GHA static upload steps can't fan out over a runtime-sized arch
  list, so the per-arch upload uses `matrix.family.arches[0]`, guarded by a step that HARD-FAILS the job if a
  family ever carries >1 gated arch. Safe today (core = 1 arch/family); S5a's gate-flip must generalize this.
- **S2 verified:** old case-path builds byte-identical to new explicit-arg path (exact sha256, all 4 core);
  compile-negative + compile-smoke(7/14 local, 14 in CI) green. build-tailscale.yaml inline docker builds
  also pass GOARCH/GOMIPS64/GO386 (would else hard-fail next release).
- **S3 verified (uncommitted):** `scripts/stage-payload.sh` (shared on-device tree, one definition) +
  `scripts/package-apk.sh` (host-side, named flags, no Docker) + `tests/apk/mkpkg.sh` rewritten to
  build via package-apk.sh (RED confirmed by hiding the new script first, then GREEN — all 20
  assertions pass), plus a new adbdump-level byte-identical check against the still-extant Dockerfile
  `apk` stage (identical modulo a documented user/group/xattrs/hashes/installed-size allowlist, with
  SOURCE_DATE_EPOCH pinned equal across both builds so mtimes match exactly too). The Dockerfile `ipk`
  stage now calls stage-payload.sh (COPY'd in via a named additional build context, `--build-context
  scripts=<repo-root>/scripts>`, since scripts/ sits outside the Dockerfile's tailscale-package/ build
  context) instead of its own inline cp+chmod block; `tests/apk/ipk-matrix.sh` run WITHOUT
  --skip-build proves the ipk payload is byte-identical after the rewiring (data.tar.gz +
  control.tar.gz diff clean). Every other caller that builds the `ipk` stage was updated to pass the
  new build-context flag: `tailscale-package/build.sh` (both invocations), the CI workflow's
  `build-ipk` job, and `tests/apk/upgrade-downgrade.sh`'s `--target ipk` call. The Dockerfile `apk`
  stage is untouched (still has its own inline duplicate) — S4 deletes it. Fast tests
  (families/select-matrix/release-checksums/release-attach/publish-arch/install-verify) all green.
- **Resume:** continue `/loop implement the next unimplemented RFC slice with /tdd ...`; then `/code-review`.
  After all slices: push branch + open PR (confirm w/ Corey), or fast-forward per his call.
- **⚠ ONE round-2 item flagged for Corey (not a blocker — has a recommendation applied):**
  §5.4 revises round 1's flat "atomicity holds" → **core/extended atomicity split** (a flaky new
  `extended` arch no longer aborts the live `core` feed). If Corey wants strict all-30-or-nothing
  instead, say so; otherwise the split stands.

## ✅ LIVE BUGS FIXED + VERIFIED on r2 (2026-07-21) — task closed
Build 29873239215 (1.98.9-r2) succeeded. Verified on live artifacts:
- **Fix-A** combined `SHA256SUMS` has all 12 entries; `SHA256SUMS.sig` cryptographically verifies
  (ed25519, key-id `260114ce974e57e5`) → GL.iNet `usign -V` passes.
- **Fix-B** `arm_cortex-a7` goarm=5 softfloat; r2 apk live.
- **Fix-C** GOMEMLIMIT dropped (GOGC-only), baked into r2 init.
- Feed `apk.leavitt.dev` serves `1.98.9-r2` for all 4 arches.
§9 of the RFC updated to reflect FIXED+verified.

## Architect round 2 — DONE (4 lenses: depth/breadth/design/feasibility), all clear-best fixes applied
Key changes to the RFC: (1) **family id = tested pure fn** w/ hard-fail on unmapped tuple +
`families==14`/vocab-enum CI assert + id-stability test (§5.2) — positional group_by ids were
insertion-fragile. (2) **CI-policy lifted to a derived `families.sh --with-ci` view** w/ "exactly
one bootable verify per family" invariant (§5.2). (3) **per-arch `tier` (core|extended|infeasible)**
unifies atomicity domain + bootstrap-force + depublish-guard. (4) **§5.4 atomicity split**
(core all-or-nothing / extended best-effort) + depublish hard-fail + concrete per-arch checkpoint
+ verify-tree accumulate/settle + imprimatur concurrency spike. (5) **§5.8 migration safety** (new):
tier gate keeps CI on core arches till S5; S1→S1a/S1b/S1c; S1+S1.5 atomic; rollback allowlist.
(6) **install.sh infeasible list codegen'd** from arches.json (§5.5). (7) SBOM per-family + arch
decommission runbook (§5.7). (8) Re-slice: S5→S5a/S5b, FPU-SIGILL smoke→S7a, drop riscv64 from M3
spike, spike-failure→S7b fallback, X86SOFT re-classified "re-check". Slices now S1a,S1b,S1c,S1.5,
S2,S3,S4,S5a,S5b,S6,S7a,S7b,S8,S9.

## Architect round 1 — DONE (4 lenses), all fixes applied to the RFC
Applied (clear-best, no genuine forks): unified single-table arches.json w/ COMPUTED family (drop
3-table split); retain container_arch; kill Dockerfile string-`case` GOARCH (+ negative test) —
it's a latent bug (x86_64/riscv64/loong64/mips64 → silently mips); decouple compile (14 Docker)
from packaging (new host-side scripts/package-apk.sh, 30); package within family job (no 2nd
matrix); parallelize publish + retry/backoff on /sign/ec; per-arch bootstrap-force via
`published-arches` list; corrected CI-boot facts (9 bootable families incl. M64BE/M64LE via
malta/be64+le64, X86SSE2 via x86/generic, LOONG64 via loongarch64/generic; 5 unbootable: A6HF,
ASOFT, X86SOFT, M32LEHF, RV64, + octeonplus) → S7 split S7a(verify)/S7b(unverified tier + log);
compile-smoke all 14; ipk/apk matrix decouple (new S1.5); drop redundant installer supported-list;
retention 30×3 measurement; arch-drift cron (new S9); alternatives (lazy builds) rejected;
family-id naming. Slices now S1, S1.5, S2, S3, S4, S5, S6, S7a, S7b, S8, S9.

## LIVE BUG FIXES — COMMITTED + PUSHED + RE-DISPATCHED (2026-07-21)
4 commits on master (pushed, 15ca380..4b460e7): `f2d87fa` SHA256SUMS.sig re-sign · `e3c8f75`
arm_cortex-a7 GOARM=5 softfloat + build honors goarm/gomips from arches.json · `4fcab0a`
GOMEMLIMIT drop (GOGC-only) + procd fix + inverted instroot Scenario 9 + field report ·
`4b460e7` forward GOARM/GOMIPS build-args in the CI docker builds (build-ipk+build-apk — without
this Fix-B was inert in CI). **Re-dispatched as 1.98.9-r2** (run 29873239215, watch bowm88ha6,
force_publish=false, clean increment) to correct the live feed+release. On success: verify
arm_cortex-a7 is softfloat, SHA256SUMS.sig verifies, feed serves r2. THEN safe /compact →
architect round 2.

## LIVE BUG FIXES (original notes, superseded by the commits above)
3 parallel sonnet fix-batches dispatched (disjoint files, NO commits — control loop batches
commit + push + re-dispatch to correct the live release):
- **Fix-A** SHA256SUMS.sig re-sign in `release-apk-assets` (build-tailscale.yaml + release-attach.sh).
- **Fix-B** arm_cortex-a7 GOARM=7→5 softfloat (arches.json + Dockerfile/build-apk.sh honor goarm + apk-matrix test).
- **Fix-C** GOMEMLIMIT field report (docs/gomemlimit-field-report.md, SAVED): drop GOMEMLIMIT
  (Issue 2 — breaks tailscaled data path on low-RAM: disco/ping up but TCP-to-local dropped),
  tune GOGC-only; fix procd set→append (Issue 1 — GOMEMLIMIT was silently dropped, masking #2);
  INVERT instroot.sh Scenario 9 (now assert GOMEMLIMIT ABSENT + GOGC present); INSTALL.md note.
  Touches tailscale.init/config + instroot test + INSTALL.md (NOT postinst).
After all 3 green: commit (3 separate commits) + push + **re-dispatch v1.98.9/next to correct the
live feed+release** (arm_cortex-a7 rebuild, SHA256SUMS re-sign, GOMEMLIMIT drop). THEN `/compact`
→ architect round 2.

## ⚠ THE 2 REVIEW-SURFACED LIVE BUGS (now being fixed as Fix-A / Fix-B above)
1. **SHA256SUMS.sig mismatch** — `release-apk-assets` regenerates combined SHA256SUMS but never
   re-signs; `release` job's `.sig` covers old ipk-only bytes → `install-glinet.sh` `usign -V`
   FAILS every release. CONFIRMED live on v1.98.9 (SHA256SUMS has 4 apk+4 ipk+1 pem+4 tailscaled).
   Fix: re-sign combined SHA256SUMS in release-apk-assets (join+/sign/usign+attach .sig).
2. **arm_cortex-a7 GOARM=7** but bare cortex-a7 can be FPU-less → SIGILL after "successful"
   install. arches.json ships goarm:7 today. Fix: arm_cortex-a7 → GOARM=5 softfloat + rebuild.
   Both need a rebuild+republish (re-dispatch) to correct the live feed/release.

## Decision (Corey, 2026-07-21)
- Cover **all 30 feasible** OpenWrt-25.12 arches, **hardfloat perf builds where the
  silicon supports it** (keep M32LEHF, M64*, A6HF, A7HF, X86SSE2 distinct — 14 family builds).
- 5 infeasible arches (arm_fa526 ARMv4, armeb_xscale big-endian, powerpc_8548/464fp 32-bit PPC,
  powerpc64_e5500 POWER7) → clean "unsupported" installer message, not built.

## Context
- This is the **feed/build half** of "generic install." The **installer half already shipped**
  (commit `15ca380`): `apk_path` reads the device's own `/etc/apk/arch` (NOT `apk --print-arch`,
  which returns the bare `aarch64`). See [[apk-feed-shipped-live]].
- The signed apk feed is **live** at apk.leavitt.dev (v1.98.9) for the current 4 arches; this RFC
  widens coverage to 30. imprimatur bearer auth is live; publish machinery (publish-arch.sh,
  monotonicity, retention, atomic deploy) already exists and just iterates more arches.
- Authoritative arch→Go/float-ABI mapping is in the RFC (Appendix, 35 arches) — from a research
  pass (downloads.openwrt.org packages/ index + rootfs readelf + target.mk + Go port minimums).

## Slices (see RFC §Slices)
- [ ] S1 arches.json v2 (families + arches + unsupported tables) + loader/test
- [ ] S2 Dockerfile/build refactor → build 14 family binaries (CGO_ENABLED=0), byte-identical to
      today's 4 for overlapping arches
- [ ] S3 packaging fan-out (per-arch `apk mkpkg --info arch:<name>` over family binary)
- [x] S4 build-apk matrix over families + packaging pass over arches (arch-namespaced artifacts)
- [ ] S5 publish fan-out → 30 signed feeds (publish-arch.sh loop; measure wall-clock/parallelize)
- [ ] S6 installer unsupported/not-published arch messaging + supported-list shipping
- [ ] S7 CI verify representative-per-family, NATIVE /etc/apk/arch (drop override), event-conditional
- [ ] S8 docs: README/INSTALL 30-arch table + mirroring note

## Open forks (awaiting Corey)
- None yet — architect rounds may surface some (e.g. verification depth for MIPS64-hf /
  bare-cortex-a9 which aren't empirically confirmable from downloads; publish wall-clock).

## Key decisions (this session)
- All 30 feasible, hardfloat where possible (above).
- Build per family, package per arch (decouple compile from packaging; 14 builds, 30 tags).
- Verify representative-per-family against native arch (can't qemu all 30).

## Stage 3 progress (slice grind)
- [x] **S1a** — arches.json v2 fields (4 rows) + `scripts/families.sh` (--id-for/--with-ci/--validate)
      + `tests/apk/families.sh` (43 assertions, id-stability, hard-fail on unmapped tuple). Green, uncommitted.
- [ ] **S1b** (in progress) — widen arches.json to 35 rows (extended/infeasible, rootfs null on new
      rows, pinning deferred to S7a) + minimal `select-matrix.sh` `tier==core` gate (§5.8; same output
      shape → no yaml churn) + `--validate` asserts family count==14. Matrix tests stay green (4 core).
- [ ] **S1c** (in progress) — remaining consumers survive the 35-row table: check-releases `.[0].name`→canary-key,
      republish-feed tier==core filter, build-apk.sh robustness, migrate the 6 flat-array docker tests
      (qemu/rootfs/install/sign-verify/upgrade-downgrade/install-dispatch) to the gated set.
- **Ordering realization:** S1.5 (separate `ipk_arches` output) + the full multi-output contract are
      DEFERRED to S5a's gate-flip — S1b's `tier==core` gate already protects the ipk matrix, so the
      §5.8 "S1+S1.5 atomic" hazard is neutralized; the separate ipk output only bites when apk widens at S5.
- [x] **S2** compile refactor — done, verified byte-identical (see above).
- [x] **S3** — `scripts/stage-payload.sh` + `scripts/package-apk.sh` (host-side, named flags) +
      `tests/apk/mkpkg.sh` rewritten (host-side, RED->GREEN) + Dockerfile `ipk` stage wired to
      stage-payload.sh via a named build context + `tests/apk/ipk-matrix.sh` byte-identical proof.
      Uncommitted. Next: S4 (build-apk matrix over families, in-job packaging loop, delete the dead
      Dockerfile `apk` stage + old `docker build --target apk` test path).
- [x] S4 build-apk fan-out (delete Dockerfile apk stage + old docker-based test path)
- [ ] S5a publish mechanics+gate-flip · S5b rollout/tier/retention
- [ ] S6 installer codegen · S7a qemu verify+spikes · S7b unverified tier · S8 docs · S9 drift cron
- **Note:** keep.d sysupgrade fix shipped separately (commit `92f6b97`, not part of the RFC slices).

## Review ledger (stage 4) — not started
| id | sev | finding | status | proof / reason |
|----|-----|---------|--------|----------------|
