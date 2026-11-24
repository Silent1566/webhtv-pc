# PanConfig Manual Accounts — Android-Informed Desktop Adaptation

**Goal:** Current PanConfig manual Quark/Baidu Cookie configuration and clear actions work on desktop, without a movie-detail page. Account values are application-wide for compatible JVM sources, as explicitly selected by the user.
**Topology:** Three disjoint implementation owners after a frozen JSON/storage seam: JVM legacy marker + read-through preferences; Dart validated account module + launch mount; UI configuration page + detail-route guard. Lead owns this plan, decisions and independent acceptance. No active-child boundary edits by Lead.
**Prior Art:** docs/reference/android-spider-actions.md (WebHomeTV commit4e30ffaf, FongMi e7e7dd062); actual legacy PanConfig evidence .probe/panconfig-action-diagnosis/run3-output.txt and report.md. Generic action(String) and newer Runtime/Dialog are separate protocols and are not claimed implemented.

## Decisions (settled)
- Current manual configuration first, not QR automatic login or generic declarative-dialog framework.
- Application-wide sharing for compatible sources selected explicitly; all other preference keys stay site-local.
- First provider set: proven Wex_quark_cookie and Wex_baidu_cookie. No arbitrary filename/key supplied by a remote Vod.
- Source and user-account operations only in explicitly initiated UI actions. Tests use temporary roots and synthetic credentials only.

## Frozen interface
### Account file
- Absolute application path: <configDir>/spiders/accounts.json. Supplied by host launch parameter -Dwebhtv.accountStore=<absolute path>; only the path, never Cookie values, on command line.
- UTF-8 JSON: {"version":1,"values":{"Wex_quark_cookie":"...","Wex_baidu_cookie":"..."}}.
- Missing file/key: keep old per-site fallback. Present empty string: explicit global clear, overrides any old site-local value. Unknown keys, malformed/schema-invalid data fail without leaking values.
- Values are strings, each at most32KiB UTF-8; maximum document128KiB. Save trims outer whitespace and optional leading Cookie: (case-insensitive), rejects embedded CR/LF; empty save requires the explicit clear action.
- Dart owner writes atomically through a bounded same-directory staging file, serializes writers/uses file lock; cancellation performs no write. JVM read-through reloads so already-created preference objects see completed new writes. Source-local editors remain local in this release.
### Source item marker
- JVM adapter only on actual PanConfig/PanConfigGuard source class adds item field _webhtv_accountAction={"version":1,"provider":"quark|baidu","operation":"edit|clear"}.
- Only IDs quarkmanual/quarkclear/baidumanual/baiduclear. Ordinary media with those IDs on any other source stays ordinary. No title/URL-regex heuristic.
- Dart validates marker version/provider/op against the original Vod ID and only supported combinations. Invalid/unrecognized markers stay ordinary and cannot write arbitrary preferences.
### Dart module
- New core/spider_account.dart exports enum SpiderAccountProvider {quark,baidu}, enum SpiderAccountOperation {edit,clear}, SpiderAccountAction(provider,operation) and static fromVod(Vod), plus provider label/preferenceKey derived internally.
- New services/spider_account_store.dart exports SpiderAccountStore({required String path}); Future<String?> read(SpiderAccountProvider), Future<void> save(SpiderAccountProvider,String), Future<void> clear(SpiderAccountProvider). No secret-bearing logs/exceptions.
- AppState exposes SpiderAccountStore get spiderAccounts and Future<void> refreshSpiderAccountCategory(); refresh selected current category after an explicitly completed write without switching source/config or making a media-detail request.
- LocalSpider optional accountStorePath defaultsnull, registry/CSP synthetic JVM sources mount shared application store via JVM flag; unrelated Python/JS args unchanged.
### JVM preferences
- WebhtvContext wraps only exact named preferences NewWexFnw_preferences when webhtv.accountStore supplied. Account overlay getters/getAll/contains merge just known string keys; other prefs/editors remain delegated site-local.
- Do not auto-migrate real old Cookies or make source editors silently write global state. Explicit UI global save wins; empty tombstone prevents stale local fallback. Cross-site propagation verified with temporary synthetic data and separately instantiated preferences.

## Tasks and scopes
1. JVM legacy accounts (run1/3): WebhtvContext.java, NEW SharedAccountPreferences.java, CatVodSpiderAdapter.java, NEW PanConfigAccountActions.java, NEW SharedAccountsContractTest.java, host.jar via existingbuild only at final source settlement. No Dart/UI edits.
2. Dart account module/launch (run1/3): NEW core/spider_account.dart, NEW services/spider_account_store.dart, spider_registry.dart, spider_router.dart, AppState account access/refresh only, NEW test/spider_account_store_test.dart, NEW test/spider_account_model_test.dart, phase3_jvm_spider_test.dart launch checks. No JVM/UI edits.
3. UI (run1/3): NEW ui/spider_account_page.dart, ui/browse_pages.dart:DetailPage marker branch before ordinary detail loading, NEW test/spider_account_page_test.dart; ordinary detail tests read/verify. No AppState/core/store edits.

## Execution limits
- Each brief at most3 runs total accumulating, commands/reads/searches/test runs unlimited inside boundary.
- No real user config/cache/account edits, cloud operations, browser login, QR session or commits.
- Flutter tests serialized: Dart module owner first; UI owner waits for callback/source APIs then testslot. JVM tests can run independently in own temporary roots.
- JVM build owner max2 total builds; persistent scratch cap stated in each brief, generated temporary fixture files confined to own/tmp and cleaned. Sidecar processes hard bounded and drain bothstreams.

## Acceptance
- Red→green: marked manual action bypasses source.detail/media metadata, actual UI shows secret input/explicit global-sharing notice, cancellation nofilechange, save/clear atomic, failure dismissible/retryable, duplicate submit blocked, mounted/lateness safe.
- Core marker rejects forged/unknown/schema-invalid combinations; ordinary media path stays unchanged.
- Independent JVM contract verifies two site contexts see the same completed global Quark/Baidu value and explicit clear, including objects made before file update; non-account keys, editors and unrelated namedprefs remain isolated.
- Final JVM host retains graphics/Dex/IPC regressions; manual provider consumer receives account via y0.e.I without network, do not claim live login or playback.
- Lead independently checks finaldiff/secrets/noarbitrarykey API, runs Dart+JVM contracts, visually inspects newAfter UI plus note Before was broken ordinarydetail screenshot.
- Fresh build/hash required for JVM behavior; desktopexe build not implied. Every review defect fixed or routed to userbeforecompletion.