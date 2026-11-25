# Dongli import preparation feedback — task book

**Goal:** Importing the existing Dongli interface immediately shows source preparation progress rather than a terminal missing-JAR error. No manual second click; homepage recovers once when ready, and real failures leave loading.
**Tier/topology:** L2-Clear, Hybrid: existing service progress seam is Lead-Core; AppState/UI adapter is one delegated module boundary. Preserve Flutter desktop styling; no redesign, no global modal, no automatic ARM-runtime installation.
**Basis:** User screenshot 1297x791 dark theme and supplied runtime log: import success 23:56:45 (93 sites / usable8), first home errored, actual preparation completed 23:57:44 (78 installed), home succeeded 23:57:48 (20 items). Thus preparation exists; feedback and early error state are broken.

## Frozen interfaces
- CspJarProbe.materialize(config, {onProgress, onEntry}): emits one CspProbeEntry per completed site, callback failure does not change installation outcome. Normal jars expose actual download/cache/check/translation stages while preserving shell-progress monotonicity.
- SpiderRouter.setProvisioningSiteKeys: renders preparing rather than misleading final missing-cache guidance for in-flight sites.
- UI model CspProvisionProgress active/done/total/stage/installed/rejected/failed/label/fraction; inline progress stays outside the collapsible form.

## Runs and ownership
- Lead-Core service seam: run1 green, 47 targeted tests; callback failure and missing normal-jar stage were red before correction.
- csp-provision-progress: run1 returned ready but not accepted; its first import home still emitted missing-JAR error, and all-failure could stay loading.
- Same warm child run2 (cap3 total): app_state.dart, config_pages.dart, test/csp_provision_progress_test.dart. Add queued-by-config marker before yield without site-list/disk inspection; suppress early Service call for eligible queued CSP; terminal completion on success/failure/none/deferred; guard callbacks by epoch+config identity; keep old override test compatibility.
- Child captures After PNG in F:/temp/dongli-progress-ui, 1297x791 dark. Before is user-provided screenshot; isolated fixture intentionally excludes user records/accounts.

## Acceptance
- Real AppState.importConfig produces no missing-JAR error during queued/preparing, progress active immediately then 0/N -> N/N and terminal; invalid/failed sources never hang loading.
- Fake clock/callback tests cover queue, progress, epoch, failure, no-work and one homepage replay.
- Callback/probe/import/auto tests and full fatal-info analysis pass.
- Inspect actual dark import-page capture, at most2 batched visual rounds; preserve fonts/tokens/controls.
- Isolated real cold import proves stage sequence, 78 completions and automatic home20; rebuild final portable package without skipping native/reparse/user-data gates.

## Decisions
- Existing source artifact is ordinary classes.dex, not an ARM guard shell: label conversion accurately; do not turn on global unidbg to satisfy colloquial “解包”.
- Existing native design world and semantic feedback language win over generic web tool defaults. The UI-context CLI misclassified desktop; repository native surface brief and theme remain authoritative.
- No fake percentage/remaining seconds; unknown total is indeterminate; source count is a work-count indicator, not a time estimate.

## Live verification (Lead)
Fresh isolated real import against current queued/progress logic completed with no premature homepage errors (NO_PREMATURE_ERROR=true). Real stages and entry milestones 1/78,12/78,39/78,77/78,78/78 were observed; stage names include download/cache/check/Android translation. Final active=false, done=78, total=78; report78 installed/0failed; home20 items and phase ready (~52.3s total on this run). Initial state and precise import timing are in F:/temp/dongli-appstate-accept/run-visible.log.

UI run2 model tests were independently rerun: 56 passed, 1 conditional skip. Captures showed the progress label but lacked filled input and actual import result row; final run3 is limited to accurate capture, known-zero indeterminate animation, and failed-import annotation correctness. This is a real acceptance gap, not permission to publish a static fake label.

## Final closure (Lead)
- Child run3 delivered 17 progress tests plus a readable After capture (1297x791 dark, 东篱 + URL + success result line + 12/78 · 转译 Android 站源, no overlap/placeholder glyphs).
- Lead found and fixed a completion defect the brief could not cover after its run budget: the result row kept the import-time ready count, so a finished preparation still showed the initial number. config_pages.dart now stores the imported config identity and recomputes the success line when progress flips active->inactive; red->green regression asserts 15 -> 93 and that the stale figure disappears.
- Lead verified: progress/import suite 108 passed (1 conditional skip); full desktop fatal-info analysis 0 issues.
- Known limits reported to the user: site-level playback/login and third-party availability remain per-site; the initial home request is intentionally deferred rather than failing.
