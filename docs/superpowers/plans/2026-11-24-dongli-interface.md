# Dongli interface adaptation plan

**Goal:** Adapt the user-supplied https://16151.kstore.space/ configuration to the existing desktop Spider pipeline; verify real site results.
**Architecture:** Hybrid. Lead implements the coupled source-aware cache seam first. Existing child C1 then integrates background provisioning into AppState. C2 investigates the independently reproducible dex class-format failure. Direct source registration is checked separately.
**Tech stack:** Dart/Flutter 3.47.5, JDK 17+ (local JDK 21), existing dex2jar/ASM and Python/Node sidecars.
**Spec:** User request plus PRODUCT.md and docs/adr/0002-android-csp-jar-compat.md. No UI redesign, no new runtime ABI.

## Facts and decisions
- Endpoint returns salt + ** + Base64 JSON: 93 sites, 78 csp sites, 47 unique csp classes, 11 direct py/js sites and 4 HTTP collection sites.
- Shared jar SHA-256 ecd497ec1f3314b2bd9267ce74d1c3ca8eadde971d67fe69648d3b85868f9418; 1,133,745 bytes, classes.dex only.
- Before: import triggers read-only shell discovery, not materialize; foreign-source Douban/Bili caches are accepted by key alone.
- Real host reproduction fails at 00OoOoO.o00O0oo()Ljava/lang/String;: non-native/non-abstract class method lacks Code. Translation-only success does not satisfy acceptance.
- Keep main process free of untrusted code. Preserve manual imports and previous-source caches. No placeholder/default data or guessed Android stubs. No broad model/config changes, commits, publishing or user-data cleanup.
- Background provisioning handles at most four distinct jar URLs, logs skipped remainder, does not download shell runtime; existing manual action remains available.

## Task book
### S: Source-aware cache seam (Lead-Core, run 1)
Files: lib/services/spider_registry.dart, csp_jar_probe.dart, spider_router.dart; tests/csp_cache_identity_test.dart and a focused source-binding regression test.
Contract: add CspJvmBinding.forConfig(AppConfig) -> immutable view under the same root. Normalize jar URL (ignore ;md5 metadata); retain manual unscoped imports. Different automatic sources must never resolve to or overwrite each other's directories. The AppState probe factory passes a binding scoped to the input config for materialize/discover/unpack. Add SpiderRouter.setCspConfig(AppConfig) and invalidate runtime/table generation on rebind. Pass api-derived className to regular JarIntake.install, not display key-derived name.
- [ ] Add deterministic tests: different sources/same key retain both caches, same source reuse, manual override preserved, per-site jar overrides global spider, Unicode display key uses csp api class.
- [ ] Run targeted tests and capture red.
- [ ] Implement seam; run green plus csp-cache/probe/router tests; freeze public signatures for C1.

### S2: Registry rescan keeps generated direct manifests (Lead-Core, run 1, done)
Files: lib/services/spider_registry.dart; test/spider_registry_scan_test.dart.
scan() now also scans root/direct/<hash>/manifest.json (one level, root and local still take priority) and ignores the root accounts.json helper file that used to log a bogus "manifest 校验失败 缺少 key; 缺少 name; 缺少 entry". DexTranslate.repairVersion synced to the new DexRepair.VERSION 7 so old translation products are invalidated.

### C1: Background provisioning (child csp-autoprovision)
Boundary: lib/state/app_state.dart and test/csp_auto_provision_test.dart. Run 1 clean hand_back, no production mutations; source seam was out of boundary. Resume warm child after S; at most 3 runs total. Commands/test runs unlimited inside boundary, files cap 2.
Use scoped binding for availability, diagnostics/manual action and router context. Trigger from import/activation, single-flight per config, ignore obsolete completion, bound unique jars, exception-isolated summary and notification. Ensure direct-source registration completion belongs to the current config. Keep first frame and import nonblocking; no shell runtime download.
- [ ] Resume on frozen S contract and tests.
- [ ] Verify new tests and existing import/progress tests, independently review diff.

### C2: Dex failure evidence (child dongli-host-evidence)
Read-only repository, scratch only in system temp; run 1 proved real home failure. Run 2 checks original dex method code_off/instructions and callers before prescribing repair. File edits cap 0, commands unlimited. A separate bounded repair brief follows the evidence, not a blanket stub.
- [ ] Compare original dex body and class output; confirm actual invocation/callers.
- [ ] Repair with original-dex evidence and regression tests; bump repair/cache version if needed; build host.jar; no default-return substitution.
- [ ] Replay original host home/category and disclose concrete external-site limitations without claiming all sites work.

### C3: Direct registration evidence (child direct-registration-evidence)
Read-only repository; scratch-only runner. Fetches alone return 200 for all eleven direct source files, so exercise the actual registrar and surface concrete registration failures. No Flutter widget HTTP override and no AppData mutations.
- [ ] Capture count, runtime and registration diagnostics using the real registrar.
- [ ] Route a confirmed implementation defect to its owning module; do not guess from logs.

## Lead live acceptance (isolated data root F:/temp/dongli-appstate-accept/data-1795531327046088)
Real config, real network, real AppState: import ok 301 ms; first home failed with “缺少桌面 JVM 站源”; background provisioning installed 78 sites with 0 rejected/0 failed (~62 s); after that site table 68/68 available but home stayed failed; explicit loadHome(Douban) returned 20 items.
Confirmed defects to fix in one C1 run:
1. provisionCspJarsQuietly passes _cspProbe(config) with real shellRuntimeInstalled, so a shell jar would be auto-unpacked (5–30 s CPU) with the explicit confirmation dialog bypassed. It must keep shells at needsShellRuntime.
2. Completed provisioning only notifies; no single idempotent replay of the current site home (the direct path does replay). Verified above.
3. cspProbeRecordFor / cspDirectoryFor / importCspJar / removeCspJar still use the unscoped _cspBinding, so settings shows and deletes the previous source cache instead of the current one.

## Lead acceptance
- [ ] Read final diff and verify file scopes, no accidental generated/user-data edits.
- [ ] Run fatal-info analysis, targeted Dart tests, JVM repair/host tests, build risk-relevant artifacts.
- [ ] Run isolated real-configuration import/materialization and host calls; before/after are logic evidence (no visual layout change).
- [ ] Route every noticed defect to a fix/re-verification before delivery.

## Progress / run counts
S/S2 complete (Lead-Core). C1 runs 1-3 complete; runs 1 and 3 clean hand_back were non-penalized; shared manual-override provenance was closed by Lead-Core. C2 evidence runs 1-2 complete; JVM implementation/hardening runs 1-2 complete, final run 3 is closing stale subprocess report cleanup. C3 evidence run 1 complete. Dart scoped re-review run 2 clean. Lead full analysis: 0 issues; risk-relevant Dart tests: 204 passed, 2 conditional skips. JVM hardening contract: 21043 assertions, 0 failures. Windows release build exit 0 (100s); final portable package waits for the final host.jar.

## Final verified live scenario
On a fresh isolated F:/temp data root, the real 78-CSP-site subset of the public configuration imported in 124ms, background-installed all 78 sites (0 rejected/0 failed), and automatically replayed Douban home with 7 categories and 20 entries (1.577s home). Total cold preparation + home ~61.1s; visible table 68/68 available because ten configured sites are hidden. The separate real direct registrar test registered all eleven Python/JS sources. No user AppData was mutated.

## Review risks and routes
- Foreign-source/manual cache identity, existing Chinese-key manifests, directory lookup storms: fixed in source binding/consumer and locked by regression tests (classification lookup 8 -> <=2).
- Background unidbg, stale homepage state, crossed direct-registration flights, source management/removal: C1 run3 fixed; independent scoped re-review clean.
- Explicit manual imports after automatic cache: manualOverride provenance now takes precedence without deleting historical probe records; public import regression red -> green.
- Lost Code, recovered frame failures, MUTF-8 limit, missing generated helpers, records bound, subprocess parity: JVM hardening fixed and independently verified; stale success report on reused subprocess paths routed to final run3 before delivery.

## Final lead acceptance — ready

All implementation/review risks above were routed and closed. Final checks:
- Full desktop Flutter fatal-info analysis: no issues.
- Risk-relevant Dart suite: 204 passed, two conditional skips, exit 0.
- JVM recovery contract: ten cases, 21044 assertions, zero failures, exit 0. Reused subprocess failure removes both jar and prior methods.json.
- Final host.jar SHA-256: c0d717e6d8501ee4960efaf5b68a6fad605d96fcfdfb258b4a4bb361bedf7842 (238736 bytes).
- Real final host: home has seven categories and 20 items; category hot_gaia page one returns 20 items, no errors.
- Windows release builds succeeded; portable packaging succeeded without disabling native/security/data-exclusion checks.
- Packaging blockers were resolved by applying the repository-pinned full-FFmpeg libmpv (88504ee5560942a955405e99dfb5971368e4cf851321f36565bf2a667271db1b), and copying only compiled outputs into a clean physical build input. Existing development sidecar junctions were left untouched. Packager adds validated hosts/runtimes from source normally.

Delivery: dist/dongli-adapt/package/webhtv-pc-0.1.0-dev-windows-x64.zip (149865938 bytes).
ZIP SHA-256: 481179ef6d994fa77278d9efd5d2e024223a6c63622f66eff3621aa9a235f376.
Independent ZIP inspection: 1380 entries, expected exe/Node/Python present, final host/libmpv hashes match, no Spider fixtures/user config/databases.

This is a development worktree build, not a published release. No commits, pushes, user AppData updates or runtime ABI changes were made. Source playback/login coverage is intentionally not claimed beyond the concrete real home/category and registrar checks.

Final runs: C1 3/3 (clean hand_back routed to shared Lead-Core provenance fix); JVM recovery/hardening 3/3; both independent scoped re-reviews checked prior defects, final cleanup independently verified by Lead. No Session subagent model allowlist was recorded; explicit same-route child selection was used.
