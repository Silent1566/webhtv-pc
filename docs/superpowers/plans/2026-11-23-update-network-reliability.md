# 更新检查可靠性与 GitHub 下载代理 Implementation Plan

> For agentic workers: use subagent-driven-development. Task scopes are disjoint; Lead owns acceptance.

**Goal:** Remove routine unauthenticated Releases API dependency, add opt-out configurable public GitHub download acceleration with direct fallback, retain verification/install boundaries.
**Architecture:** Hybrid: Lead freezes pure model/network settings seam, then parallel client, publisher and UI adapters. Existing AppUpdateService.check/download/install signatures remain compatible; only constructor options grow. Index content reuses GitHub release-list schema so channel/version/OS selection is unchanged.
**Tech Stack:** Flutter/Dart 3.47.5/3.13.4, package:http, crypto, Python stdlib, GitHub Actions.
**Spec:** User approved static-index-first recommendation and additionally requested GitHub proxy for reliability and download speed; evidence docs/reference/android-update-distribution.md (protected pre-existing file).

## Global constraints / rulings

- Preserve Android repo and pre-existing untracked research note. No push, publish, token setup, or remote mutation.
- Source precedence: direct static index, configured proxy static index (if enabled), then REST API once if not in cooldown. Metadata retry uses bounded timeouts; no polling loops.
- Ruling: use Android default HTTPS proxy https://gh-proxy.com/, with alternative https://ghfast.top/ and custom HTTPS base; default enabled like Setting.java:813-814. This is best effort, not a speed/SLA promise. UI discloses third-party visibility of public download URLs; opt-out exists.
- Package download uses configured proxy first then direct; no automatic random/public proxy discovery. Only public GitHub release URLs for Silent1566/webhtv-pc are rewritten, never api.github.com/non-GitHub URLs, credentials, cookies, or authorization.
- SHA-256 expected value is resolved once from release metadata/checksum before routes; validate full size and digest on every downloaded candidate. Failed route removes its partial file; no concatenation of different candidates; bounded one attempt per route.
- Preserve autoCheck=false default, 24h automatic check frequency, stable filter and beta including stable; no data/channel isolation change, no automatic install or installer changes.
- No new dependencies or full-file formatting on AppState/large incumbent UI files. Tests first for each behavior. Existing unit fakes may need explicit disabled static/proxy options to isolate API-only tests, never relax production assertions.

## Frozen pure seam (Lead)

Files: lib/core/app_update.dart, new lib/core/app_update_network.dart, test/app_update_network_test.dart (all paths under apps/desktop-flutter).

- app_update.dart imports and exports app_update_network.dart.
- Constants: appUpdateIndexAssetName='releases.json', appUpdateIndexTag='update-channel'; final Uri appUpdateIndexUri=https://github.com/Silent1566/webhtv-pc/releases/download/update-channel/releases.json.
- class AppUpdateProxySettings: const constructor({bool enabled=true, String baseUrl=defaultAppUpdateProxyUrl}); fields enabled/baseUrl; defaults; normalizeBaseUrl(String)->String?; fromJson(Object?); toJson(); copyWith({bool? enabled,String? baseUrl}); equality/hashCode.
- Constants defaultAppUpdateProxyUrl='https://gh-proxy.com/'; appUpdateProxyPresets=const ['https://gh-proxy.com/','https://ghfast.top/'].
- List<Uri> routesFor(Uri original,{bool proxyFirst=true}) returns configured proxy + original (dedup), or original only when disabled/invalid/noneligible. Only HTTPS github.com/Silent1566/webhtv-pc/releases/{download/... or latest/download/...} is eligible; enforce no userinfo, fragments, unsafe delimiters or traversal. Proxy base requires HTTPS/no credentials/query/fragment, normalize trailing slash.
- AppUpdatePreferences gets githubProxy (AppUpdateProxySettings, defaults); copyWith/fromJson/toJson/equality preserve nested update.githubProxy={enabled,baseUrl}.
- AppUpdateCheck gets additive optional final fields: bool fromCache=false; DateTime? cachedAt; DateTime? retryAt; String? source. Failure with cached release keeps verdict=failed (install disabled), message notes old result; 304 using cache remains successful and fromCache=true.

## Task A: client transport, cache and downloads (child, <=5 files)

Files: services/app_update_service.dart; optional services/app_update_cache.dart; test/app_update_service_test.dart; test/app_update_transport_test.dart; optional test/app_update_cache_test.dart.

Produces constructor options (named and additive): Uri? indexUri (default appUpdateIndexUri), bool useStaticIndex=true, Directory? cacheDirectory, AppUpdateProxySettings Function()? proxySettings (default () => AppUpdateProxySettings.defaults), bool ownsClient=false (existing client==null still owned). Preserve current clock/timeout/http injection and check/download/install overrides.

- [ ] RED tests for static success skipping API; static direct/proxy fallback; legacy API fallback; 304 cache and restart reuse; expired cached response labelled failure; API403 evidence vs forbidden,429 cooldown, network failures; proxy/size/hash failure falling to direct cleanly and non-GitHub bypass.
- [ ] Implement valid bounded JSON (2MiB metadata bound), filter out update-channel itself and reject malformed/non-release payloads (HTML/empty junk is not a fresh up-to-date result). Keep existing tag/version/channel policy.
- [ ] Cache raw successful release list with source-specific ETag/Last-Modified and UTC savedAt; atomic write; cold process load. Use source-specific conditional headers; 304 without body cache is not success. Best-effort cache read/write cannot break valid network result. API cooldown respects Retry-After / x-ratelimit-reset, defaults 60s for secondary evidence, doesn't prohibit static source attempts. Persist cooldown with cache. Normal forbidden isn't labelled rate limit; combined errors retain actionable reasons. Manual cached fallback must show age and no false latest/update notification.
- [ ] Package and checksum HTTP use settings callback current value. Proxy first/direct fallback; metadata direct then proxy; no Range/resume complexity in this change. Cancel/close failed streams; no full buffered package read; disk .part cleanup and exact expected bytes/sha.
- [ ] GREEN targeted old/new service tests and analyzer. Leave install scripts/flows unchanged.

## Task B: publish fixed update index (child, <=4 files)

Files: scripts/generate_update_index.py; tests/test_update_index.py; .github/workflows/desktop-release.yml; optional .github/workflows/desktop-ci.yml (only add focused Python gate).

- [ ] RED subprocess tests with fixture releases/metadata/checksums including stable,beta,old tags,draft,index-self,malformed assets and bad digest.
- [ ] Implement stdlib CLI --releases-json PATH --output PATH, optional --repository (default Silent1566/webhtv-pc); input may be JSON array or gh --paginate --slurp list of arrays; output release array understood by existing parser, preserve full notes + public tag-pinned browser URLs and digest; exclude drafts and index tag, retain up to 30 normal releases, validate strict version tags and matching platform filenames; refuse invalid current source rather than publishing bad/empty index. No manual second version source.
- [ ] Workflow after successful normal Release publish (only publish_release true) obtains authenticated release list, generates/validates index, creates dedicated prerelease update-channel if absent and uploads releases.json --clobber (no --latest true); never overwrites stable latest designation. Concurrency existing release group remains. Ensure index only after asset/sha publish succeeds and publish=false no remote index operations. No live workflow execution.
- [ ] GREEN Python tests and relevant existing workflow contract tests; parse YAML and run generated script with fixtures, don't assert only source strings.

## Task C: AppState and update page adapters (child, <=5 files)

Files: state/app_state.dart; ui/app_update_page.dart; test/app_state_update_test.dart; test/app_update_page_test.dart; tool/app_update_capture_test.dart.

Consumes constructor options from Task A and pure models above. AppState constructs service with cacheDirectory=Directory(paths.cacheDir/updates/metadata), proxySettings: () => updatePreferences.githubProxy, ownsClient:true for locally created outbound client; maintains injected fake priority. Add Future<bool> setUpdateGithubProxy(AppUpdateProxySettings settings) with validated URL and failure-safe disk persistence; changing while transfer in progress must not corrupt a captured route set; no UI direct networking. Expose in existing preferences only (no separate global proxy setting).

- [ ] Capture Before using existing tool before edits, preserve .local/update-network-visual/before/; same data/viewport/theme then After (480x640,1440x900 dark/light) and one download-progress/failure state.
- [ ] RED tests proxy toggle/address persists and affects callback, no request on page build, settings write failure doesn't pretend saved; retry/cached hints visible and stale install unavailable; channel changes during in-flight check don't publish previous-channel verdict; avoid stale downloaded package reuse after a new release check; preserve existing actions.
- [ ] Add section GitHub 下载加速: key settings-update-proxy-enabled SwitchListTile (default true), proxy selector/address key settings-update-proxy-url (HTTPS validation, immediate persistence using incumbent patterns), text public third-party service may see URL and speed varies, failure auto direct. Use Wrap/SettingsSection, no redesign/new dependencies. Render source/cache timestamp/retryAt near status with keys settings-update-source,settings-update-cache-hint,settings-update-retry-at where relevant. Busy check disables applicable channel controls or reject stale completion safely; stale cached verdict never shown as fresh available.
- [ ] GREEN UI/state + navigation tests/analyzer. No blanket dart format state/app_state.dart.

## Acceptance (Lead)

- Review final diffs against each task contract; at most3 dispatch runs per child, run counts in todo.
- Run full dart analyze --fatal-infos; combined update core/store/client/state/page/navigation regression; Python index and workflow tests; capture/inspect Before/After matching scenario.
- Independent read-only review of network fallback/security and publisher consistency; all found defects fixed or explicitly scoped via user decision, not summary-only shipping.
- Record actual proxy sampling limits and results without speed guarantee; no credentials or remote publication.
- Update ADR-0015 and README/release docs: why auto-generated index is now justified, migration first index unavailable uses API fallback, proxy default/optout/custom/security/cache behavior. State deployment needed: workflow change is local until next publish, no claim existing URL already live.
