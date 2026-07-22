# RFC: OpenWrt 25 apk builds — handoff

- **RFC SHIPPED + LIVE — 2026-07-21.** Run **29851753339 SUCCESS** (all jobs green: build-ipk×4,
  build-apk×4, qemu-verify×4, apk-install-verify×4, apk-sign-verify, release, release-apk-assets,
  publish-feed). **Feed live at https://apk.leavitt.dev** — all 4 arches packages.adb HTTP 200,
  signature independently VERIFIED VALID against the live tailscale.pem (key-id
  5079908ab7ada08cbe4308cdf40a904f). Release **v1.98.9** has all 4 `.apk` + apk-signing.pem +
  SHA256SUMS + SHA256SUMS.sig. Auth enforced live on the signer. **Nothing outstanding** except
  the optional tailnet-grant tightening (Tailscale console, defense-in-depth).
- **Stage:** 4 **`/code-review` COMPLETE — floor reached (0 Critical/High/Medium) 2026-07-21.**
  3 fix rounds + 4 review passes. All C1–C4, H1–H7, M1–M11 + round-2/3 regressions FIXED and
  test-green in both repos (imprimatur 83 nimble; installer 97 + dispatch 44; instroot 64;
  upgrade-downgrade 25; publish-arch + guard-hardening + structural all green). Round-4
  verification (security + correctness/design) confirmed round-3 deltas sound against real
  tooling (opkg source, live curl, real nimble test). Remaining = **Lows only** (deferred per
  mandate): imprimatur no rate-limit on /sign; apk-feed rollback = documented v1-TOFU; ipk
  version compare uses case-glob (defense-in-depth, safe under threat model); openssl -text
  regex fragility; a few structural-only tests; compose secret mode 0444. publish-arch token
  tempfile trap Low was folded in inline.
  - **NOTHING COMMITTED YET.** Resume = commit + deploy (see Resume line). Deploy gates opened by
    fixes: create repo secret `IMPRIMATUR_AUTH_TOKEN`; redeploy imprimatur with it set (enforces
    H3 auth — code is backward-compat/off until then); tighten tailnet grant so only tag:ci
    reaches sign.leavitt.info. First-ever feed publish needs FORCE_PUBLISH=true once (M10).
- **(historical) Stage 4 Round 1 fix loop** — Mandate (Corey 2026-07-20):
  **fix everything incl. forks**; H1/H2 installer verification **folded into this RFC**; H3 =
  optional app-layer bearer auth in imprimatur (repo-controlled; network ACL can't scope to
  tag:ci) + documented homelab deploy gate. 5 parallel sonnet fix-batches dispatched (disjoint
  files, NO commits — control loop batches commits after a clean re-review round):
  A=imprimatur Nim (C1,M1,M3,M4,H3-auth,L1-3) · B=workflow (C2,H4,H6,H7,H3-wiring,M11) ·
  C=installer (H1,H2,M9,L9) · D=maintainer/killswitch (C3,H5,M5,M6,M8,L10,L12) ·
  E=CI-shell (M10,M7,L8,L11). After batches: re-review changed scope (incl. standing Security +
  Design), loop until 0 C/H/M. THEN: re-pin imprimatur SHA, commit both repos (imprimatur first
  → SHA → tailscale-openwrt bulk), push, dispatch first live feed. Deploy gates opened by fixes:
  create repo secret `IMPRIMATUR_AUTH_TOKEN` + redeploy imprimatur with it set (enforces H3);
  tighten tailnet grant so only tag:ci reaches sign.leavitt.info.
- **Stage 3 COMPLETE** — ALL 21 `/tdd` slices DONE (B0; A0–A5b; B1–B3; C1a–C5; D1–D3).
- **B4/C0 human gates — BOTH FULLY DONE 2026-07-20. No open items.** imprimatur deployed +
  live-verified; feed live at `apk.leavitt.dev`; imprimatur made public so no CI token is
  needed. Next: `/compact` → `/code-review` (Stage 4).
  - **B4 — DEPLOYED + VERIFIED LIVE 2026-07-20.** imprimatur committed + pushed to `main`
    @ **`7b1fe92`** (68/68 nimble test, image builds). EC prime256v1 keypair generated:
    **public** `apk-signing.pem` at repo root (key-id **`5079908ab7ada08cbe4308cdf40a904f`**
    — the production apk-feed signing fingerprint), **private** at
    `homelab/stacks/infra/imprimatur/secrets/apk-signing.sec` (0600). Production
    `compose.yaml` → structured `IMPRIMATUR_SIGNERS` (usign+ec, both `required`, EC as a 2nd
    docker secret); README + example `docker-compose.yaml` rewritten for the registry model.
    **Deployed** (`docker compose up -d --build` on the host): `/health` → HTTP 200, both
    signers loaded (usign `260114ce974e57e5`, ec `5079908ab7ada08cbe4308cdf40a904f`);
    **live `/sign/ec` proven end-to-end** (DER verifies vs the pubkey, tampered msg rejected);
    **`/sign/usign` proven** (ipk path preserved). Workflow `apk-sign-verify` pinned to `7b1fe92`.
    - **Two workflow fixes found + made while wiring the live path (working-tree, ride with
      Stage-4 bulk):** (1) added the `tailscale/github-action@v4` join (tags `tag:ci`) to
      `publish-feed` + `republish-feed` before their `/sign/ec` curl — they were missing it and
      GitHub runners can't reach the tailscale-only `sign.leavitt.info` otherwise (the `release`
      job already had it for usign). (2) `/sign` → `/sign/:key` rename broke the ipk `release`
      job's bare `/sign` call; **hotfix committed + pushed to master as `f9e8805`** (isolated
      one-liner on pre-existing committed code, independent of the apk bulk) so the live ipk
      release path isn't broken by the imprimatur upgrade. `TS_OAUTH_CLIENT_ID`/`TS_AUDIENCE`
      repo secrets confirmed present.
    - **B4 fully done 2026-07-20** — the last item (imprimatur clone access) resolved by
      making `coreyleavitt/imprimatur` **public** and removing the `token:` line from the
      `apk-sign-verify` checkout step. No repo secret needed.
  - **C0 — DONE 2026-07-20.** Feed domain switched to **`apk.leavitt.dev`** (Corey's choice;
    was `.info`). Vultr CNAME `apk.leavitt.dev → coreyleavitt.github.io` created (id
    `c4aa56c7-cd48-47b8-b6e0-c23ba7ce375f`, ttl 300, resolving). GitHub Pages enabled via API
    (`build_type: workflow`), custom domain set to `apk.leavitt.dev`, Let's Encrypt cert
    **approved** (exp 2026-10-18), **HTTPS enforced**; `https://apk.leavitt.dev/` serves (404
    until the first publish-feed run — expected). Repo-wide rename `apk.leavitt.info →
    apk.leavitt.dev` (32 refs / 9 files: install scripts, both workflows, README, INSTALL, RFC,
    handoff, probe) done as working-tree prep (rides with Stage-4 bulk). `sign.leavitt.info`
    (signer) unchanged. No workflow perms changes needed.
  - **Commit state (Corey's 2026-07-20 decision = "leave as working-tree prep"):** the two
    B4-wiring changes in tailscale-openwrt — `apk-signing.pem` (untracked) + the `7b1fe92`
    SHA edit in `build-tailscale.yaml` — are **verified working-tree prep, NOT committed**;
    they ride with the Stage-4 bulk commit after `/code-review` (the SHA isn't cleanly
    separable from the uncommitted Stage-C workflow, and a live run needs the whole bulk
    pushed anyway). imprimatur (separate repo) IS committed+pushed.
  - **D3 DONE** — filesystem-level opkg detection+clean preflight (`lib-install.sh`) +
    `tests/apk/upgrade-downgrade.sh` GREEN both parts (coexistence leaves no residual
    ipk/killswitch state; documented `--allow-untrusted` downgrade works as-is). The
    grind is finished.
  - **D2 DONE** — README + INSTALL.md (decision table, apk install/uninstall/downgrade,
    luci scope, mirror note), reconciled to shipped code. **Next & FINAL /tdd: D3** —
    ipk→apk upgrade/coexistence via **filesystem-level** ipk detection (ipk/apk are
    disjoint DBs — apk can't see opkg installs, §4.1) so the installer detects+cleans a
    stale ipk tailscale before `apk add` (test: install ipk in container→simulate
    upgrade→apk add→assert no dup/residual state) + **tested downgrade** (§4.7): provision
    newer in container, run the D2-documented `apk add --allow-untrusted ./tailscale-<old>-r<rel>-<arch>.apk`
    against an older local `.apk`, assert it succeeds OR capture the real flags apk
    requires. After D3: Stage 3 done → **Stage 4 `/code-review`** (+ commit decision, B4/C0).
  - **D3 IN PROGRESS — Part B GREEN, Part A FAILING (fix delegated).** Files exist
    (`tests/apk/upgrade-downgrade.sh`, `lib-install.sh` opkg detect/clean fns). **Part B
    (downgrade) VERIFIED GREEN:** the documented `apk add --allow-untrusted ./tailscale-<old>...apk`
    works **as-is** (no extra flags), apk logs "Downgrading tailscale", installs 1.88.0 —
    §4.7 downgrade story confirmed. **Part A (ipk→apk coexistence) FAILS:** `install.sh`'s
    apk_path errored against the stale-ipk container (likely tried the real unreachable
    feed → exited before the opkg cleanup; residual `/usr/lib/opkg/info/tailscale.*` +
    killswitch DNS state remained). A fix subagent is running (reorder clean-before-add
    preflight + wire the test to a local served feed like D1's test). If resuming cold:
    re-run `sh tests/apk/upgrade-downgrade.sh` — D3 is done only when BOTH parts green.
  - **D1 DONE** — `scripts/lib-install.sh` (shared primitives) + `scripts/install.sh`
    (dispatcher→apk/ipk/glinet adapters) + `install-glinet.sh` refactored onto the lib;
    ca-bundle preflight; ≤24.10 ipk hint; `customfeeds.list`=full `packages.adb` URL
    (fixed). `tests/apk/install-dispatch.sh`. **Next: D2** — README/INSTALL.md docs
    (§4.4): decision table (OpenWrt version × detect → path), apk install steps, apk
    **uninstall** (`apk del tailscale` + remove feed line + `/etc/apk/keys/tailscale.pem`),
    downgrade procedure (§4.7), `luci-app-tailscale` scope note (separate ipk-only), and
    "Mirroring this feed" note. **Docs-only slice.** Then D3 (upgrade/coexistence +
    tested downgrade) is the last /tdd slice.
  - **C5 DONE** — failure isolation (`release` needs ipk only; apk jobs `if:!cancelled()`)
    + `notify-alert.sh` + republish dispatch (`republish-feed` job) + cron self-heal
    (`detect-apk-drift.sh`) + synthetic probe (`probe-feed.sh` + `adb-sign.py verify`).
    `tests/apk/failure-isolation.sh`. **Next: D1** — `scripts/install.sh` dispatcher
    (detect OpenWrt release + arch → apk/ipk/glinet) built from **shared primitives**
    (`detect_arch`, `prompt_confirm` /dev/tty, `poll_for_service`, `log_*`) + thin
    per-path adapters — NOT a 3-way if/elif (§4.4). apk path: verify `apk` exists (else
    "you're on ≤24.10, use ipk" hint), **ca-bundle preflight**, drop pubkey in
    `/etc/apk/keys/`, add feed to `customfeeds.list`, `apk update && apk add tailscale`.
    Carry forward `install-glinet.sh`'s hard-won `/dev/tty`+service-poll fixes (factor,
    don't copy). Test: trusted install in container; ≤24.10 path prints the ipk hint.
  - **C4 DONE** — new sibling job `release-apk-assets` in `build-tailscale.yaml`
    (`needs: [select-matrix, release, build-apk]`, perms `contents:write`/
    `id-token:write`/`attestations:write`; deliberately separate from both `release`
    (ipk, untouched) and `publish-feed` (pages-scoped only, no contents/attestations
    creep)). Downloads `apk-<arch>` artifacts + the ipk artifacts (ipk only for
    re-hashing/re-scanning into the combined SHA256SUMS/SBOM, never re-uploaded as
    release files -- `release` stays sole owner of the actual `.ipk`/`tailscaled_*`
    assets), renames each arch's identically-named `tailscale-<ver>-r<rel>.apk` to
    `tailscale-<ver>-r<rel>-<arch>.apk` (confirmed collision, per C1b), copies
    `apk-signing.pem`, and attaches `.apk`s + pubkey + a combined SHA256SUMS +
    combined SBOM to the release via a SECOND `softprops/action-gh-release` call
    against the same tag (upsert -- overwrites `release`'s ipk-only SHA256SUMS/
    sbom.spdx.json with combined versions; ipk lines are byte-identical since both
    re-hash the same underlying file bytes). New `scripts/release-checksums.sh`
    (factored out of `release`'s inline `sha256sum *.ipk tailscaled_*`, extended
    with `*.apk`/`*.pem`, guards against folding SHA256SUMS's own hash into itself
    on re-run) + `tests/apk/release-checksums.sh` (13/13 fixture assertions,
    RED→GREEN: script missing → implemented). **Attest subject-path finding
    (empirically checked against actions/attest's own docs via WebFetch):**
    `subject-path` DOES accept multiple glob patterns and a single glob CAN span
    extensions -- but a second `attest-build-provenance` step (scoped to
    `release-assets/*.apk`) was used instead of broadening `release`'s existing
    `packages/*.ipk` glob, because (1) `packages/*` in `release` would also sweep
    in SHA256SUMS/sbom.spdx.json themselves, and (2) more fundamentally the apk
    assets live in a DIFFERENT JOB by design (job-separation requirement below),
    so a shared single step spanning two jobs/runners isn't an option regardless
    of glob syntax. `release`'s own attest step is untouched (still exactly
    `packages/*.ipk`). New `tests/apk/release-attach.sh` (structural, python+yaml,
    asserts: exactly one non-release/non-publish-feed job downloads apk-* artifacts
    + calls gh-release; its files include `.apk`+`.pem`; attest covers both `.ipk`
    (unchanged) and `.apk`; its perms include contents+attestations write with no
    pages permission; publish-feed has no contents/attestations creep; `release`'s
    needs/perms/tag_name are byte-unchanged) -- RED (job didn't exist) → GREEN.
    Job boundary rationale: separate from `release` so a later slice (C5) can make
    apk-asset-attach best-effort without coupling ipk-release success to it (today
    it's a normal hard `needs: [release, ...]` dependency -- C5 adds the
    `if: !cancelled()` wiring, not this slice). **Next: C5** — failure isolation
    (`needs`/`if:!cancelled()` wiring on `release-apk-assets`/`apk-sign-verify`/
    `publish-feed`, two-call gh-release already in place) + release-time alerting +
    republish `workflow_dispatch` + cron self-heal + synthetic feed/cert probe.
  - **C3 DONE** — `publish-feed` job (atomic, concurrency, least-priv pages perms) +
    `scripts/feed-guard.sh` (monotonicity via `apk version -t` exit 0/1/2; last-N=3
    retention manifest; index-walk via `apk mkndx` oracle) + `tests/apk/feed-publish.sh`.
    **Cache-Control infeasible on Pages** (documented, dormant `_headers`). Prod signing
    + `apk-signing.pem` behind B4-gated TODOs.
  - **C2 DONE — the crux hermetic signing slice, proves B0→B1→B2→B3→C2 end to end.**
    New `scripts/adb-sign.py` (stdlib-only: hashlib/struct/subprocess+openssl CLI,
    no compiled helper) implements the CI-side ADB framing B0 deferred: `preimage`
    (parse the uncompressed `apk mkndx --compression none` output -- magic "ADB.",
    schema, the ADB_BLOCK_ADB block's payload -- and emit the 86-byte pre-image
    per the b0-spike), `assemble` (append the ADB_BLOCK_SIG block: 18-byte
    `adb_sign_v0`{sign_ver=0,hash_alg=4,id[16]} ‖ DER sig, padded to 8 bytes), and
    `key-id` (id = SHA512(i2d_PublicKey(pubkey))[:16], derived independently from
    the PUBLIC key via `openssl ec -pubin -text` -- never trusts imprimatur's
    self-reported fingerprint; the two were cross-checked byte-identical against a
    dedicated libcrypto `i2d_PublicKey` C program during the spike). **Finding:**
    `apk mkndx --compression none` (a global `-c`/`--compression` apk-tools flag)
    emits the uncompressed "ADB." on-disk form directly -- `apk verify`/`apk add`
    accept it identically to the compressed default, so the compressed-payload
    problem B0 flagged never had to be solved. New `tests/apk/sign-verify.sh`
    (aarch64-scoped, per RFC §5 "Hermetic C2"): builds the real tailscale.apk +
    three offline stub deps (kmod-tun/ip-full/conntrack, A4/A5b's trick) into ONE
    combined unsigned index (apk has no per-repo trust flag, so a second unsigned
    repo would force `--allow-untrusted` for the whole transaction regardless of
    tailscale's own signature); generates an ephemeral `openssl ecparam` test key
    (mktemp scratch dir, destroyed on exit, never committed); builds+runs the
    **CI-local imprimatur image from the LOCAL working tree**
    (`IMPRIMATUR_REPO_DIR`, default this machine's clone) with
    `IMPRIMATUR_SIGNERS` pointing at the ephemeral key; polls `/health` for
    `ec.loaded:true`; frames+POSTs to `/sign/ec`; assembles the signed index; and
    asserts, in the pinned aarch64 rootfs container (A4's `/etc/apk/arch`
    multi-line override + `-X <repo>/packages.adb`), that plain `apk add
    tailscale` (**no** `--allow-untrusted`) succeeds and installs the real
    binary. **RED→GREEN with the required negative, both proven this run:**
    (a) the same command against the UNSIGNED index fails (`UNTRUSTED signature`);
    (b) the same command against a signature with one bit flipped inside the real
    DER content (not the block's trailing zero-padding, which apk correctly
    ignores since block length comes from the header's rawsize) also fails; (c)
    only the correctly assembled signed index succeeds --
    `tailscaled --version` → `1.92.2`, post-install ran. All three verified via a
    live run (docker + a locally-built imprimatur image), not just structural
    assertions. **Workflow wiring:** new sibling job `apk-sign-verify` in
    `build-tailscale.yaml` (`needs: [select-matrix, build-apk]`, never feeds
    `release`'s `needs:`, so isolation holds by construction even before C5).
    Its "Checkout imprimatur" step clones `coreyleavitt/imprimatur` at a
    **placeholder SHA (all zeros)** with an explicit `TODO` comment -- imprimatur's
    B1–B3 EC code is still uncommitted upstream, so there is no real SHA to pin
    yet; this step will fail in a live Actions run until that lands (expected,
    documented, non-blocking to the ipk release). Files touched: new
    `scripts/adb-sign.py`, new `tests/apk/sign-verify.sh`, edited
    `.github/workflows/build-tailscale.yaml`. No RFC-doc deviation -- Design 1
    held throughout, no fallback to Design 3 or B3a needed. **Next: C3** (publish
    atomically + concurrency + monotonicity guard + last-N blob retention +
    differentiated Cache-Control, RFC §4.3).
  - **A5a DONE:** additive `pull_request` trigger + `select-matrix`/`qemu-verify`
    jobs + `scripts/select-matrix.sh` (jq, PR→canary+aarch64 else full) + custom MIPS
    binfmt extracted to `lib.sh` + `tests/apk/qemu.sh`. ipk path byte-identical.
    RED→GREEN, all 4 arches exec.
  - **B1 DONE** (imprimatur repo, uncommitted). Signer refactor (KeySource/SigAlgo
    + owning-method composition), `registry.nim`, `/sign/:key`, `/health` 503-fix,
    no-quit(1), `IMPRIMATUR_SIGNERS` config, `IMPRIMATUR_USIGN_KEY_PATH` rename.
    41/41 nimble test (nim 2.2.4-alpine container — NO host nim). `=destroy`→`destroy()`
    (Nim reserves =destroy; **B2 overrides `destroy()` for EVP_PKEY_free**). **B4 must
    update README/compose/docker-compose** (still ref old `IMPRIMATUR_KEY_PATH`+`/sign`).
    **B2 + B3 DONE — STAGE B CODE COMPLETE.** B2 = `ec_algo.nim` (EVP FFI, SHA-512, DER),
    registry `algo:"ec"`. B3 = `tests/test_sign_route.nim` HTTP integration test (real
    binary subprocess: /sign/ec 200+DER-verify, 503-unloaded, 404, /health). 68/68
    nimble test. imprimatur is apk-tools-free (Design 1 holds).
  - **B4 + C0 are HUMAN deploy gates — but they DO NOT block the /tdd grind.** B4 =
    deploy imprimatur to sign.leavitt.info (+ update README/compose for the
    `IMPRIMATUR_USIGN_KEY_PATH`/`/sign` rename); C0 = enable Pages + DNS CNAME + perms.
    Both are needed for the LIVE production release, but **C1a/C1b/C2/C3… are hermetic**
    (C2 uses a CI-local imprimatur image + ephemeral test key, not sign.leavitt.info;
    C3 testable against a local server). So the loop CONTINUES implementing Stage C/D
    slices; B4+C0 wait for Corey in parallel and are only required before an actual
    production release. **C1a DONE** (4 ipk jobs→`build-ipk` matrix, byte-identity
    verified, `tests/apk/ipk-matrix.sh`). **Next: C1b** — add a **separate** apk matrix
    job (sibling to `build-ipk`, NOT nested, so C5 isolation stays additive),
    arch-namespaced artifacts (no flat merge), keyed off the same select-matrix/arches.json,
    building the 4 `.apk`s via the `apk` Dockerfile stage. Test: 4 arch-separated `.apk`
    artifacts; ipk & apk independent DAG jobs.
  - **C1b DONE** — `build-apk` sibling matrix job, `apk-<arch>` artifacts,
    `tests/apk/apk-matrix.sh` (13/13). **Next: C2** — the crux hermetic signing slice.
    Per B0 Design 1: CI builds the unsigned `packages.adb` (apk mkndx), computes the
    86-byte pre-image (`docs/rfc-apk-builds.b0-spike.md`), sends to a **CI-local
    imprimatur image** `/sign/ec` (ephemeral test key), gets DER, assembles the
    `ADB_BLOCK_SIG` block, verifies **trusted `apk add tailscale` (no --allow-untrusted)**.
    ⚠ **Cross-repo dep:** imprimatur's B1–B3 EC code is **uncommitted** in its repo, so
    C2's local test must `docker build` the LOCAL imprimatur repo; the workflow's
    "clone @ pinned SHA" needs a real SHA only after imprimatur is committed+pushed
    (flag as TODO; §8 cross-repo drift). This slice implements the CI-side ADB framing
    B0 deferred to C2.
  - **A5b DONE — STAGE A COMPLETE.** `tests/apk/install.sh` iterates all 4 arches;
    verified GREEN (real `tailscaled --version`→1.92.2 under qemu for each; install
    ~47–48s/arch emulated). **Next: B1** — Stage B is the **imprimatur repo**
    (`/home/corey/homelab/stacks/infra/imprimatur/`, separate git repo, **Nim**, tests
    via `nimble test`) — a context/repo/language shift. B0 (spike) already done; B1 =
    Signer owning-methods + registry + `/health` 503 + no-quit(1) + structured
    `IMPRIMATUR_SIGNERS` config. B4 is a `[human]` deploy gate that will pause the loop.
  - **A4 DONE:** `tests/apk/install.sh` — aarch64 `.apk` installs in armsr/armv8,
    real `tailscaled --version`→1.92.2 under qemu, config present, rc.d symlinks
    asserted (start-fail tolerated). **Two RFC corrections (both folded in):**
    (1) `apk add --arch <foreign>` FAILS → use **multi-line `/etc/apk/arch`**
    (verification-container-only; real devices unaffected); (2) offline deps need a
    **local unsigned stub repo** (`-X stub packages.adb` for kmod-tun/ip-full/
    conntrack) — no force-flag alone works. Reuse both in A5b/C2. Intermittent
    qemu-user segfault-in-postinst seen once (unreproducible; qemu flake).
  - **Next: A5a** — `docker/setup-qemu-action` binfmt registration + the
    `on: pull_request` trigger + event-conditional matrix scoping. MUST include the
    custom ABIVERSION-wildcarded 32-bit MIPS binfmt entries (see [[qemu-mips-openwrt-binfmt]]
    + `tests/apk/rootfs.sh` reference impl) or MIPS canary/full runs can't exec.
  - **A3b DONE:** assertion-only — added `scripts:`-block assertions to
    `tests/apk/mkpkg.sh` (3 hook names as scoped keys). Mapping/conffile were
    already wired in A2. RED→GREEN (forced a missing `--script`). 16/16 pass.
  - **A3a DONE:** guarded `tailscale.{postinst,prerm,postrm}` on `$IPKG_INSTROOT`
    (redirect/no-op/skip) + meminfo deferral via new `hardware.detected` uci flag in
    `tailscale.init`/`.config` (RFC-mandated first-boot re-derive; a considered design
    call worth a nod). `tests/apk/instroot.sh` + fixtures (`uci-stub`, sandboxed in
    alpine). 41/41 pass, 17 failed pre-guard, live-install byte-equivalent. RED→GREEN.
  - **Next: A3b** — mostly covered by A2 already (script-name mapping done, conffile
    shipped). A3b is now largely a focused-assertion slice (metadata lists 3 scripts;
    conffile present w/ correct content). May be quick.
- **COMMITTED + PUSHED (coarse split, Corey's choice) — 2026-07-21:**
  - imprimatur `main`: **`9ed1008`** "Harden signer routes: crash-safe handlers, optional auth,
    strict config" (EC feature stays at prior 7b1fe92). Pushed 7b1fe92..9ed1008.
  - tailscale-openwrt `master`: **`e1c8827`** "Add OpenWrt 25 apk build output and a signed EC
    package feed" (apk-feature; workflow pinned to imprimatur 9ed1008) → **`11dfbde`** "Harden
    the on-device maintainer and killswitch scripts". Rebased onto remote's automated
    `0aefc90 chore(check): upstream v1.98.9` (conflict-free, only touched state/last-check.json),
    pushed 0aefc90..11dfbde. Integrity verified pre-push (tree == backup bar the SHA re-pin).
- **Gate 1 DONE (auth) — 2026-07-21:** 256-bit `IMPRIMATUR_AUTH_TOKEN` generated →
  `homelab/stacks/infra/imprimatur/secrets/auth.env` (0600) + set as the tailscale-openwrt repo
  secret (same value). compose.yaml gained `env_file: ./secrets/auth.env`. Redeployed
  (`docker compose up -d --build`, image now at 9ed1008). **Verified live:** /health 200;
  /sign/ec 401 without token, 200+DER with correct token, 401 with wrong token; startup log
  confirms auth enforced. Both signers loaded (ec 5079908…, usign 260114ce…).
  - **STILL OPEN (defense-in-depth, needs Tailscale admin console — no policy file in homelab):**
    tighten the tailnet grant so only `tag:ci` can reach sign.leavitt.info. The app-token is now
    the real gate; the grant is belt-and-suspenders.
- **Gate 2 run 1 FAILED + FIXED — 2026-07-21:** run 29850668516 failed. Root cause: the new
  scripts were committed at git mode **100644** (no +x; core.fileMode=false so the on-disk rwx
  was ignored), so the workflow's DIRECT `scripts/select-matrix.sh` call hit "Permission denied";
  the command substitution swallowed it, select-matrix emitted an EMPTY matrix, all build jobs
  were skipped, and publish-feed deployed a **keys-only** feed (tailscale.pem 200, all
  packages.adb 404) while reporting success. Fix commit **`bc5dc36`**: `git update-index
  --chmod=+x` on all CI-invoked scripts (now 100755) + hardened two silent-failure paths
  (select-matrix now fails loudly on error/empty-matrix; publish-feed refuses to deploy an empty
  matrix). Re-dispatched as **run 29851753339** (watch `bmkqlss1s`).
- **Gate 2 run 1 (superseded) —** `gh workflow run
  build-tailscale.yaml --ref master -f tailscale_version=1.98.9 -f pkg_release=1
  -f force_publish=true -f republish=false`. **Run 29850668516** (workflow_dispatch, master).
  Background watch `b7kaakyh1` (`gh run watch ... --exit-status`) → notifies on completion;
  log at scratchpad/run-watch.log. First run exercising: imprimatur clone @9ed1008 in
  apk-sign-verify, authenticated /sign/ec + /sign/usign (bearer token live), force_publish
  clearing the C3 monotonicity guard (no prior live version), fail-closed verify gate before
  Pages deploy, and the v1.98.9 ipk+apk release with signed SHA256SUMS.sig.
  - **If it fails:** likely spots = bearer-token auth on a /sign call (secret vs container env
    mismatch — both set from the same value, should match), the imprimatur clone SHA, or the
    first-publish path. Check `gh run view 29850668516 --log-failed`.
  - **On success:** first live feed at `https://apk.leavitt.dev/apk/<arch>/packages.adb`; RFC
    fully shipped + live. Then verify an on-device `apk add tailscale` (or `scripts/probe-feed.sh`).
- **Resume — remaining (human, optional):** tighten tailnet grant to tag:ci in the Tailscale
  admin console (defense-in-depth; app-token is the real gate).
- (historical) pre-commit resume plan:
  1. **imprimatur** (repo `/home/corey/homelab/stacks/infra/imprimatur/repo`): commit the
     round-1/3 working-tree diff (auth, /verify crash-fix, dup-name, error-template, rename) →
     push to `main` → capture the NEW commit SHA.
  2. **tailscale-openwrt**: re-pin the `apk-sign-verify` "Checkout imprimatur" step to that new
     SHA (currently 7b1fe92), then commit the whole bulk (apk-signing.pem, arches.json, all
     scripts/ + tests/, the apk.leavitt.dev rename, workflow, Dockerfile, maintainer scripts,
     signing.pub) + push to master. Consider splitting: (a) the apk-feature bulk, (b) the
     security-hardening fixes — or one squashed commit; Corey's call.
  3. **Human deploy gates:** create repo secret `IMPRIMATUR_AUTH_TOKEN`; redeploy imprimatur
     with that env set; tighten tailnet grant to tag:ci only.
  4. **Dispatch** the build with **FORCE_PUBLISH=true** (first bootstrap publish) → first live
     feed at apk.leavitt.dev.
- **Blocked on:** nothing. Stage 3 slices 100% done; B4/C0 gates done; no open forks.
- **A2 DONE:** `tailscale-package/Dockerfile` split into 3 named stages
  (`apk-tools` unchanged; `build` = shared Go/UPX prep, now also `COPY src/
  /tmp/files/` and keeps `tailscale.tar.gz` around for SOURCE_DATE_EPOCH;
  `apk` = NEW, branches off `build`, textually placed *before* `ipk` so a
  default `docker build` still resolves to `ipk` unchanged/unbuilt-apk-stage;
  `ipk` = old final stage, byte-for-byte same RUN steps as before). New
  `tailscale-package/build-apk.sh` (sibling to `build.sh`, targets `--target
  apk`). New `tests/apk/lib.sh` (shared harness: `log_info/log_fail/
  require_cmd/assert_eq/assert_contains/assert_not_contains/docker_run/
  harness_finish`) + `tests/apk/mkpkg.sh`; `host-apk.sh`/`rootfs.sh` refactored
  onto `lib.sh` (reverified GREEN, unchanged behavior). ipk path verified
  byte-intact: built old vs. new Dockerfile, `data.tar.gz`/`control.tar.gz`/
  `debian-binary` contents diff clean (raw `.ipk` bytes differ only from
  pre-existing gzip/tar mtime non-determinism, reproduced by rebuilding the
  *unmodified* old Dockerfile twice).
  **Q1 finding — corrects the RFC's own hypothesis (§4.1/A3b, and this
  slice's brief):** `apk mkpkg` has **no** `--info conffiles:` metadata key
  (`--info` only recognizes name/version/description/arch/license/maintainer/
  depends/provides/replaces/install-if/origin/triggers — confirmed via
  `strings` on the apk-tools 3.0.2 binary). `lib/apk/packages/<name>.conffiles`
  is **not excluded** from the shipped payload — apk mkpkg ships it as a real
  on-device file (verified via `apk adbdump`: a `files:` entry under the
  `lib/apk/packages` path, 22 bytes, matching `/etc/config/tailscale\n`
  exactly). Cross-checked against upstream `include/package-pack.mk`
  (git.openwrt.org, the RFC's own cited source): it does `mv -f
  $(ADIR)/conffiles $(IDIR)/lib/apk/packages/$(name).conffiles` — i.e.
  deliberately moves the conffiles list *into* the `--files` payload dir.
  **This is the correct, intentional apk v3 mechanism, not a leak** — apk's
  client-side conffile protection is payload-driven (the file must physically
  exist on the device), unlike ipk's build-metadata-only `CONTROL/conffiles`.
  `tests/apk/mkpkg.sh` asserts the file **is** present with the right content,
  not absent. **Action for future slices/RFC text:** §4.1's A3b line ("conffile
  not shipped as a file") and the A2 brief's Q1 phrasing are wrong and should
  be corrected if the RFC doc itself is touched again — the requirement is
  "shipped with correct content", not "excluded". No RFC-doc edit made here
  (out of this slice's scope per the task boundary); flagging for whoever
  next edits `docs/rfc-apk-builds.md` or scopes A3b.
  Empirical `apk adbdump` on the built aarch64 `.apk`: `name: tailscale`,
  `version: 1.92.2-r1`, `arch: aarch64_cortex-a53`, `depends: ca-bundle,
  conntrack, ip-full, kmod-tun` (4 items); `paths:` has 14 entries, none named
  `CONTROL` or `scripts`; `scripts:` block lists exactly `post-install`,
  `pre-deinstall`, `post-deinstall`. RED (no `apk` stage, `docker build
  --target apk` → "target stage \"apk\" could not be found") → GREEN,
  verified by `git stash`/`pop` of just the Dockerfile.
- **A1 DONE:** `tailscale-package/Dockerfile` (added `apk-tools` stage: extracts the
  25.12.0 SDK's `.apk.bin` v3.0.2, pinned URL+sha256; `fakeroot` redundant, dropped)
  + `tests/apk/host-apk.sh`. mkpkg/mkndx confirmed functional (real mkpkg→adbdump).
  Existing Go/ipk pipeline reverified intact.
- **A0 DONE:** `arches.json` (4 arches, §4.5 schema + rootfs pins + container_arch)
  + `tests/apk/rootfs.sh`, RED→GREEN. `armvirt`→**`armsr`** rename; targets
  `armsr/armv8`,`armsr/armv7`,`malta/be`,`malta/le`; `apk --print-arch` =
  `aarch64/armv7/mips/mipsel` (≠ our build arch → `apk add --arch` override). apk
  all = 3.0.2.
- **⚠ A0 surfaced for A5a — 32-bit MIPS binfmt:** stock `setup-qemu-action` omits
  32-bit mips/mipsel AND rejects OpenWrt musl ELFs (`EI_ABIVERSION=1` vs required
  `0`). A5a must register custom ABIVERSION-wildcarded binfmt entries (reference
  impl already in `tests/apk/rootfs.sh`). binfmt magic/mask with embedded `0x00`
  must be written as literal `\xHH` text. See [[qemu-mips-openwrt-binfmt]] memory.
- **B0 output:** `docs/rfc-apk-builds.b0-spike.md` (86-byte pre-image, DER,
  apk-tools-free Design 1; collision confirmed).

## Where we are
RFC drafted (Stage 1); architecture review rounds 1 **and** 2 both complete, each
a 4-agent team (depth / breadth / design-ergonomics / feasibility). All clear-best
fixes from both rounds applied to `docs/rfc-apk-builds.md`. No open forks (O4 feed
hosting resolved in round 1 = Pages + custom domain). Next: the Stage-3 `/loop`
slice grind, then `/code-review`.

## Round-2 outcome (what changed, on top of round 1)
- **B0 spike criteria expanded (was CRITICAL):** must report signature **encoding**
  (raw `r‖s` vs DER — EVP emits DER by default; apk may want raw), signed byte
  range, and whether "attach" re-invokes apk-tools (narrow middle ground: vendor a
  thin `adb-sign` op). B2 asserts against that encoding. B0 also empirically checks
  the **package-name collision** with OpenWrt's official `tailscale` apk.
- **imprimatur: no `quit(1)` after boot** — the round-1 "required→quit(1)" rule
  fired at *every* restart, so a transient EC-secret fault during an unrelated
  redeploy would crash the shared process and take usign/ipk down too. Now a broken
  key degrades only its own routes (503 + alert), never exits. Isolation is real at
  the process layer, not just routing — without a second container.
- **Signer gets owning methods** (`load/sign/fingerprint/isLoaded`, atomic load,
  `=destroy` for the EVP_PKEY handle) — was a data bag. **Route is `/sign/:key`**,
  not `/sign-adb-index` (registry-keyed, one reusable CI helper). **Config = one
  structured `IMPRIMATUR_SIGNERS` block.**
- **Feed monotonicity guard** — refuse publishing a version ≤ live without `force`
  (prevents a *signed downgrade* via republish/backfill order-inversion). **Retain
  last-N `.apk` blobs** + differentiated `Cache-Control` (Pages full-tree-replace
  would 404 a stale-cached index otherwise).
- **IPKG_INSTROOT guard = 3 categories** (redirect uci/rc.d, no-op live reloads,
  skip `/proc/meminfo`) — blanket no-op would ship a broken ImageBuilder image.
- **SOURCE_DATE_EPOCH from tarball mtime** — the `git log` recipe was unrunnable
  (no `.git` in build context). **Staging scripts are siblings of `$ADIR`** (were
  inside `--files` → would ship as payload).
- **`arches.json` = array of objects** (goarch/goarm/gomips/endian/rootfs_target/
  canary), not a bare string list. **`arches.json` A0 rootfs targets concretized.**
- **CI: `pull_request` trigger + test-harness convention are prerequisite infra**
  (neither exists today); **C1 split → C1a (ipk refactor) / C1b (apk sibling job)**;
  **failure-isolation DAG mechanics stated** (`needs`/`if:!cancelled()`, two-call
  gh-release upsert); **C2 clones+builds imprimatur at a pinned SHA** (no published
  image); **cron self-heal + synthetic feed/cert probe** added to C5.
- **New explicit non-goals:** `luci-app-tailscale` (separate ipk-only project),
  staged/canary rollout (v1 = single-shot to 100%). **install.sh = shared
  primitives, not 3-way if/elif.** Downgrade path now **tested**, not docs-only.

## Round-1 outcome (what changed in the RFC)
- **imprimatur `/health` bug is live today** (returns 200 unconditionally) +
  single global usign-typed signer → redesigned to a **multi-key `signers`
  registry**, per-key 503, **scoped** fatal-load (don't `quit(1)` the whole
  service for one optional key), config rename `IMPRIMATUR_USIGN_KEY_PATH`.
- **Trust boundary flipped:** CI builds the *unsigned* `packages.adb`; imprimatur
  signs only that blob (`/sign-adb-index`), staying apk-tools-free — **if** the
  B0 spike confirms apk supports unsigned-index + separate-sign. Fallback keeps
  server-side `mkndx --sign` (B3a vendors apk-tools).
- **Signer abstraction refactor:** factor `KeySource` × `SigAlgo`; no
  ed25519-specific code in any shared base. EC signer = libcrypto EVP FFI (O6).
- **O1 resolved = confirmed defect:** maintainer scripts are NOT
  `IPKG_INSTROOT`-safe (grep-verified) → new slice A3a guards them.
- **New prerequisite slices:** A0 (pin OpenWrt 25.12 rootfs container — none
  exists), A5a (qemu binfmt), B0 (spike), B4 (human deploy gate), C0 (human
  hosting/Pages setup), C5 (failure isolation + alerting).
- **Arch-filename collision** in the CI merge/release upload → arch-namespaced
  output paths, no flat `merge-multiple`.
- **CONTROL/ leak:** apk staging root must exclude the ipk `CONTROL/` tree.
- Failure isolation (apk can't block ipk), concurrency guard + atomic publish +
  index-walk C3 test, backend-portable custom-domain URL, ipk↔apk
  upgrade/rollback (§4.7), single `install.sh` dispatcher, uninstall docs,
  apk-tools version pin across all 3 sites, MIPS canary + release-only emulation,
  hermetic C2 (CI-local imprimatur), SOURCE_DATE_EPOCH=commit-time not 0.

## Slices (see RFC §6) — re-sliced round 1, refined round 2
- [x] B0 spike — **DONE** (`docs/rfc-apk-builds.b0-spike.md`): separable +
      apk-tools-free (Design 1); 86-byte pre-image; **DER** (not raw r‖s); SHA512;
      collision **confirmed** (25.12 ships `tailscale-1.98.3-r1`)
- [x] A0 — **DONE**: `arches.json` + `tests/apk/rootfs.sh` (RED→GREEN); targets
      armsr/armv8,armsr/armv7,malta/be,malta/le; pinned+checksum-verified; apk 3.0.2
- [x] A1 — **DONE**: SDK `.apk.bin` v3.0.2 (mkpkg/mkndx) into Dockerfile, pinned
      URL+sha256; fakeroot redundant/dropped; `tests/apk/host-apk.sh` (RED→GREEN)
- [x] A2 — **DONE**: `$PKGROOT` staging (files/ + sibling scripts/) + mkpkg
      aarch64; **established `tests/apk/lib.sh` harness** (+ refactored
      host-apk.sh/rootfs.sh onto it); asserts no CONTROL/, no scripts/, and
      (corrected finding, see above) conffiles IS shipped as a real file —
      RED→GREEN
- [x] A3a — **DONE**: INSTROOT guard (redirect/no-op/skip) + meminfo first-boot
      deferral (`hardware.detected` flag); `tests/apk/instroot.sh`; 41/41, RED→GREEN
- [x] A3b — **DONE** (assertion-only): `scripts:`-block assertions in mkpkg.sh; 16/16
- [x] A4 — **DONE**: `tests/apk/install.sh`; multi-line `/etc/apk/arch` + stub repo;
      real `tailscaled --version` under qemu; rc.d symlinks asserted. RED→GREEN
- [x] A5a — **DONE**: pull_request trigger + select-matrix/qemu-verify jobs +
      custom MIPS binfmt in lib.sh + `scripts/select-matrix.sh` + `tests/apk/qemu.sh`
- [x] A5b — **DONE**: install.sh iterates 4 arches; all GREEN under qemu (~47s/arch).
      **STAGE A COMPLETE**
- [x] B1 — **DONE** (imprimatur): Signer refactor + registry + /sign/:key + /health
      503-fix + no-quit(1) + IMPRIMATUR_SIGNERS config + rename. 41/41 nimble test
- [x] B2 — **DONE**: `ec_algo.nim` EcP256Algo (EVP FFI, SHA-512, DER-asserted), registry
      `algo:"ec"`, 64/64 nimble test
- [x] B3 — **DONE**: `/sign/ec` end-to-end (B1 route+B2 algo); HTTP integration test
      `test_sign_route.nim`; 68/68; apk-tools-free (no B3a). Stage B code complete
- [x] B4 [human] — DEPLOYED + VERIFIED LIVE 2026-07-20 (imprimatur @ 7b1fe92; EC key gen;
      /health 200 both signers; /sign/ec + /sign/usign proven; ipk-route hotfix f9e8805
      pushed). ONLY LEFTOVER: create the `IMPRIMATUR_CLONE_TOKEN` repo secret. See top-of-file.
- [x] C0 [human] — DONE 2026-07-20: Pages enabled (Actions source) + custom domain
      apk.leavitt.dev (Vultr CNAME live, cert approved, HTTPS enforced). See top-of-file.
- [x] C1a — **DONE**: 4 ipk jobs→`build-ipk` matrix (select-matrix/arches.json),
      release repointed, byte-identity verified (`tests/apk/ipk-matrix.sh`)
- [x] C1b — **DONE**: `build-apk` sibling matrix job, `apk-<arch>` artifacts, no flat
      merge, `tests/apk/apk-matrix.sh` (13/13)
- [x] C2 — **DONE**: hermetic sign+assemble (`scripts/adb-sign.py`) +
      `tests/apk/sign-verify.sh` (aarch64) -- CI-local imprimatur (LOCAL working
      tree) + ephemeral EC key, trusted `apk add tailscale` (no --allow-untrusted)
      GREEN, unsigned + corrupted-sig negatives RED. Workflow job
      `apk-sign-verify` wired with a placeholder-SHA TODO for imprimatur's clone
      (its B1-B3 EC code is still uncommitted upstream)
- [ ] C3 publish atomically + concurrency + **monotonicity guard** + last-N + cache
- [x] C4 — **DONE**: sibling job `release-apk-assets` (needs:
      [select-matrix, release, build-apk]; contents/id-token/attestations write,
      separate from publish-feed's pages-only perms) attaches arch-namespaced
      `.apk`s + `apk-signing.pem` to the same release tag via a second
      softprops/action-gh-release upsert call; `scripts/release-checksums.sh`
      (new, extends the ipk-only `sha256sum *.ipk tailscaled_*` with `*.apk`/
      `*.pem`) + `tests/apk/release-checksums.sh` (RED→GREEN); second
      `attest-build-provenance` step (`release-assets/*.apk`) -- confirmed via
      actions/attest docs that one glob CAN span extensions, but the job split
      (required so C5 can later decouple apk-attach from the ipk release)
      forces a second step regardless; `release`'s own ipk attest step
      untouched. `tests/apk/release-attach.sh` (structural, RED→GREEN).
- [ ] C5 failure-isolation DAG (needs/if:!cancelled, 2-call gh-release) + alerting
      + republish dispatch + **cron self-heal** + **synthetic feed/cert probe**
- [ ] D1 scripts/install.sh dispatcher — **shared primitives**, ca-bundle preflight
- [ ] D2 README/INSTALL.md: decision table, install/uninstall, downgrade,
      luci-app scope note, mirror note
- [ ] D3 ipk→apk upgrade/coexistence (filesystem detection) + **tested downgrade**

## Open forks (awaiting Corey)
- **None.** The imprimatur-clone fork is RESOLVED 2026-07-20: `coreyleavitt/imprimatur`
  made **public** (commits no secrets), and the `token:` line removed from the
  `apk-sign-verify` "Checkout imprimatur" step — the default `github.token` reads it, no
  PAT needed. Rationale locked: the apk feed MUST be a **public signed** static host (a
  tailnet-gated feed is a bootstrap paradox — a fresh box can't join the tailnet to fetch
  tailscale from a tailnet-only feed), so GitHub Pages stays (the signature, not the host,
  provides trust); self-hosting would only add a public homelab route + install SPOF for
  zero trust gain. imprimatur being public is likewise harmless (signing service, no
  committed secrets). B4 + C0 fully done.
- (O4 resolved 2026-07-19 → refined 2026-07-20: **GitHub Pages + custom domain**, now
  `apk.leavitt.dev/apk/<arch>/…`; C0 done.)

## Decisions locked (this session)
- Ship **both** .apk and .ipk (per firmware version, not per device).
- apk distribution = **signed EC feed** (`apk add tailscale`, no --allow-untrusted).
- CI verification = **apk-tools in a pinned OpenWrt 25.12 Docker container**.
- EC signer = **libcrypto EVP FFI** (O6). SDK host apk binary lean (O3).
- v1 = **TOFU pin-once** key model, latest-only retention; both documented.
- Feed hosting (O4) = **GitHub Pages + custom domain** (`apk.leavitt.dev`).
- **apk index signing (B0)** = **Design 1**: imprimatur `/sign/ec` signs an opaque
  86-byte pre-image via `EVP_DigestSign(sha512)` → **DER**; CI owns the apk framing
  + `ADB_BLOCK_SIG` assembly + pre-publish `apk verify`. imprimatur stays
  apk-tools-free; B3a fallback not expected. Full spec: `rfc-apk-builds.b0-spike.md`.

## Corrected assumptions (were wrong going in)
- apk signing is **EC prime256v1**, index-signed (signed `packages.adb`), not
  RSA/usign, not per-package. Lone `.apk` always UNTRUSTED.
- Target OpenWrt **25.12.0** (2026-03-08); 24.10 + GL.iNet 4.x stay ipk.
- imprimatur `/health` silent-failure bug is **still live** in the source today.

## Review ledger (stage 4) — Round 1 (7 reviewers + 2 adversarial verifiers, 2026-07-20)
Mandate not yet set (awaiting Corey). Sev after adversarial verification.
| id | sev | finding | status | proof / reason |
|----|-----|---------|--------|----------------|
| C1 | C | imprimatur `POST /verify` malformed-base64 → uncaught ValueError → whole-process crash (remote pre-auth 1-req DoS) | open | CONFIRMED empirically (docker build+curl → exit 1, /health then refused). imprimatur.nim ~60-89 |
| C2 | C | ipk `release` job unscoped `download-artifact@v4` (merge-multiple, `files: packages/*`) races a stray same-named `.apk` into the IPK release upload — breaks ipk/apk isolation | open | CONFIRMED. v4 no-name = all run artifacts; release needs [build-ipk] only; build-apk sibling uploads bare-named apk. yaml 611-615/679, 254-258 |
| C3 | C | killswitch `configure_router_dns` overwrites DNS backup unconditionally (boot path guards `[ ! -f ]`, CLI path doesn't); double-`enable` → restore/uninstall bricks LAN DNS | open | CONFIRMED inline. PRE-EXISTING — tailscale-killswitch.sh NOT in RFC diff. killswitch.sh 217-230 vs 333-335 |
| H1 | H | ipk install path (`ipk_path`, install-glinet) never verifies `.ipk.sig`/hash → HTTPS-only trust → root RCE on channel compromise; signing infra dead client-side | open | CONFIRMED inline (security agent rated CRITICAL). opkg has no per-file sig check → needs explicit usign -V. install.sh 209-225 |
| H2 | H | apk feed TOFU pubkey fetched from untrusted feed host, no fingerprint pin vs committed apk-signing.pem → first-install key substitution → fully-trusted malicious install | open | CONFIRMED inline. install.sh 294-300; no pin in install.sh |
| H3 | H | imprimatur signing oracle gated only by broad RFC1918+CGNAT IP ACL (not tag:ci) + zero app-layer auth → any private-net/tailnet host gets prod signatures | open | CONFIRMED inline. HOMELAB infra (security.yaml 50-57) + imprimatur. |
| H4 | H | PR runs: empty TAILSCALE_VERSION breaks every PR build + failure-webhook spam on non-fork PRs + `release` has no `if:` guard (PR-isolation only incidental) | open | CONFIRMED all 3 sub-parts. yaml 42/179/241/265-270/600; Dockerfile 9/96 |
| H5 | H | `has_wwan` detection ignores `$IPKG_INSTROOT` → ImageBuilder bakes has_wwan=0 permanently (init never re-derives it) | open | CONFIRMED via guard asymmetry. tailscale.postinst 167-172 |
| H6 | H | publish pipeline duplicated byte-identical between publish-feed & republish-feed → drift risk (the anti-pattern the code elsewhere avoids) | open | Design. Extract scripts/publish-arch.sh. yaml ~527-560 & ~980-1015 |
| H7 | H | adb-sign.py assemble never verifies its own signature before publish; verify only in daily cron → up-to-24h live unverifiable feed (fail-OPEN, breaks fail-closed discipline) | open | Design rated High / Security Medium. adb-sign.py cmd_assemble + publish steps |
| M1 | M | `/verify` route has ZERO test coverage (directly enabled C1) | open | test_sign_route.nim drives only /sign+/health |
| M2 | M | `/sign/:key` + `/verify` 400/500/405 error branches untested | open | Test |
| M3 | M | `/sign/:key` malformed base64 → 500 instead of spec'd 400 (contract violation, not crash) | open | imprimatur.nim 38-56 |
| M4 | M | duplicate signer names in IMPRIMATUR_SIGNERS silently collide (last wins), contradicts fail-loud config goal | open | registry.nim 54-75/106-108 |
| M5 | M | postrm leaves orphaned `firewall.allow_ts_traffic` (deletes 3 of 4 killswitch sections) | open | tailscale.postrm 31-34 |
| M6 | M | predictable authkey temp `/tmp/.tailscale_authkey.$$` (TOCTOU/disclosure) | open | tailscale.init 138 |
| M7 | M | notify-alert.sh fixed temp path, no trap cleanup (race on shared runner) | open | notify-alert.sh 62 |
| M8 | M | DNS-backup RESTORATION content not asserted (only presence) — misses reorder/drop in postrm restore loop | open | Test. upgrade-downgrade.sh Part A |
| M9 | M | `-y`/AUTO_YES doesn't propagate to glinet path → `-y` still blocks on GL.iNet | open | install.sh glinet_path + install-glinet.sh |
| M10 | M | monotonicity guard treats any 404 as "allow anything" w/o --force (feed host untrusted) | open | feed-guard.sh 189-198 |
| M11 | M | six CI jobs have no explicit `permissions:` block (least-priv inconsistency) | open | yaml select-matrix/qemu-verify/apk-install-verify/build-ipk/build-apk/apk-sign-verify |
| L1 | L | `/health` fingerprint() unguarded (H1-of-Nim, REFUTED as attacker-triggerable — not reachable via input) | open | Defense-in-depth; same catch-all fix as C1 |
| L2 | L | non-string JSON fields (getStr→"") silently accepted | open | imprimatur.nim 40/64-66 |
| L3 | L | IMPRIMATUR_PORT parseInt unguarded → ugly boot crash (pre-bind) | open | imprimatur.nim 124 |
| L4 | L | cast[seq[byte]](string) fragile reinterpret | open | imprimatur.nim 44, ed25519_algo.nim 30 |
| L5 | L | registry.entries exported + bypassed by main()'s hand-rolled loop | open | registry.nim/imprimatur.nim |
| L6 | L | file_key_source dual responsibility (env-var branch dead in prod) | open | file_key_source.nim |
| L7 | L | destroy() dead code in prod (speculative generality) | open | signer/ec_algo |
| L8 | L | unguarded `apk version -t` under set -eu breaks exit-code contract | open | feed-guard.sh 206, detect-apk-drift.sh 95 |
| L9 | L | install-glinet pipeline masks tailscaled --version failure (dead fallback) | open | install-glinet.sh 256 |
| L10 | L | extra_args glob-expands (not just word-split) in init | open | tailscale.init 99-103 |
| L11 | L | temp-dir leak in plan-retention on validation failure | open | feed-guard.sh 243-244 |
| L12 | L | `head -n -1` GNU-ism broken under BusyBox (killswitch verify_rule_order) — PRE-EXISTING | open | killswitch.sh 100 |
| L13 | L | compose secret mode 0444 vs 0400 (HOMELAB) | open | compose.yaml 22-24 |
| L14 | L | SignerConfig single `path` param won't generalize to multi-param sources (no consumer yet) | open | registry.nim |
| L15 | L | openssl `-text` regex fragility (fails loudly) + install-dispatch substring checks + YAML structural-only tests | open | informational |
| C4 | H | NEW (found in round-1 fix loop): `restore_router_dns` reads DNS backup line-by-line but real `uci get` space-joins a multi-value list on ONE line → 2+ DNS-server routers get list collapsed to one space-embedded entry on disable/uninstall → dnsmasq can't parse → broken upstream DNS | fixing | Batch D M8 test left RED as proof; fix = word-split to mirror uci join. killswitch.sh restore_router_dns |

## Round 1 fix results (all 5 batches complete + D follow-up)
- **A (imprimatur)** GREEN 83 tests: C1,M1,M3,M4,H3-auth,L1,L2,L3 all fixed RED-first. `/verify` crash-proof + covered; `/sign/:key` optional bearer auth (`IMPRIMATUR_AUTH_TOKEN`, off until set).
- **B (workflow)** GREEN (yaml valid + structural tests): C2 (pattern `tailscale-*` + explicit files: list keeping .sig/checksums/SBOM), H4 (version fallback 1.92.2/1 + notify gated off PR + `release` workflow_dispatch-only), H6+H7 (new `scripts/publish-arch.sh` dedups publish/republish, embeds fail-closed `adb-sign.py verify` gate), H3-wiring (`Authorization: Bearer` on /sign/ec + /sign/usign curls), M11 (6 jobs `permissions: contents:read`). New test `tests/apk/publish-arch.sh` (30 assert).
- **C (installer)** GREEN 44 assert: H1 (usign -V vs committed `signing.pub` key-id 260114ce974e57e5, baked in; glinet raw binary → SHA256 vs release SHA256SUMS), H2 (**deviation ACCEPTED**: rootfs has no openssl/SHA-512 → pinned **sha256sum** of apk-signing.pem instead of the i2d/SHA512 key-id; same fail-closed property, tool that exists on-device), M9 (`-y`→glinet via shared lib), L9. New test `tests/apk/install-verify.sh`.
- **D (maintainer/killswitch)** GREEN 62/62 instroot: C3 (DNS backup `[ ! -f ]` guard), H5 (has_wwan INSTROOT-gated + first-boot re-derive), M5 (delete allow_ts_traffic), M6 (mktemp authkey), L10 (set -f extra_args), L12 (sed '$d'). Surfaced **C4** (above) → follow-up fix in progress.
- **E (CI-shell)** GREEN: M10 (404 needs --force; NOTE: first-ever live publish needs FORCE_PUBLISH=true once), M7 (mktemp+trap), L8 (guard apk version -t), L11 (WORK trap). New test `tests/apk/guard-hardening.sh`.
- **Deploy gates opened by fixes (human, before H3 fully closes):** create repo secret `IMPRIMATUR_AUTH_TOKEN`; redeploy imprimatur with that env set; tighten tailnet grant so only tag:ci reaches sign.leavitt.info. All backward-compatible until done.
- **Round 1 complete** (all 5 batches + C4 follow-up green). Re-review Round 2 done (Security/Correctness/Design on changed scope) → 5 core fixes verified SOLID; found regressions FROM the fixes → **Round 3 fix loop IN PROGRESS** (4 batches, disjoint files, no commits):
  - **RA imprimatur:** R2-D2 except-cascade dup (High) → shared error-mapping helper; R2-D5 getRequiredStrField rename.
  - **RB tailscale.init:** R2-C1 stale-config-after-uci-commit (HIGH — first start on low-RAM device runs tailscaled unconstrained; config_get reads pre-detection shell snapshot, not disk) → assign live vars; R2-D1 has_wwan dedent out of the total_ram branch; + make instroot test faithful (stub was proxying config_get to live uci, hiding the bug).
  - **RC installer:** R2-C2 should_reinstall default y→n (Med-High regression — non-interactive re-run reinstalls by default → VPN disruption); R2-D4 sha256_verify helper dedup; R2-S2 ipk version/arch binding post-usign-V (anti-downgrade); R2-S1-consume GL.iNet verify SHA256SUMS.sig vs pinned usign key (factor TAILSCALE_USIGN_PUBKEY into lib-install).
  - **RD workflow/publish:** R2-D3 publish-arch explicit <published-filename> param (drops republish rename dance); R2-S1-produce usign-sign SHA256SUMS → attach SHA256SUMS.sig; R2-S3 bearer token out of curl argv (ps exposure); R2-S4 set -o pipefail on curl|jq sign.
  - Round-2 Lows deferred: imprimatur no rate-limit on /sign (residual); apk-feed rollback = documented v1-TOFU limitation.
- **After Round 3:** re-review changed scope again → loop until a round is 0 C/H/M → then re-pin imprimatur SHA + commit both repos (imprimatur first) + push + dispatch first feed (FORCE_PUBLISH=true first bootstrap).
- **Human deploy gates opened by fixes (before H3 + GL.iNet fully close live):** create repo secret `IMPRIMATUR_AUTH_TOKEN`; redeploy imprimatur with that env set; tighten tailnet grant so only tag:ci reaches sign.leavitt.info.
