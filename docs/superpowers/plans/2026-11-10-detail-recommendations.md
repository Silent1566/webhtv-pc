# Detail Recommendations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development; requirements and write boundaries below are binding.

**Goal:** Add all Android non-AI recommendations to both PC detail pages.
**Architecture:** Fan-out with a frozen document-level interface; three disjoint implementation briefs (TMDB/domain, Douban, UI/controller). Lead owns plan and independent acceptance, never edits active child files. UI may wait for domain file to be created before running compilation.
**Tech Stack:** Flutter/Dart, package:http, existing TMDB service/cache and PlaybackHistory.
**Spec:** docs/superpowers/specs/2026-11-10-detail-recommendations-design.md

## Global Constraints
No AI calls; no collections/tag rows; no new dependencies; no changes to TMDB identity semantics; no fabricated positive TMDB IDs for Douban. Themes from DESIGN.md. Each row fails independently. No commits/push/merge in children. Read Android files only. Test runs/inspection commands unlimited; implementation attempts at most 3 total per brief.

## Frozen shared interface (all tasks)
File lib/core/detail_recommendation.dart imports core/tmdb_identity.dart.

```dart
class RecommendationSeed {
  const RecommendationSeed({required this.title, this.mediaType, this.year = '', this.tmdbId = 0, this.isAudio = false, this.isShortDrama = false});
  final String title, year;
  final TmdbMediaType? mediaType;
  final int tmdbId;
  final bool isAudio, isShortDrama;
  TmdbIdentity? get identity;
}
enum RecommendationSource { tmdb, douban }
class RecommendationEntry {
  const RecommendationEntry({required this.item, required this.source, this.reason = '', this.doubanId, this.doubanRating = 0});
  final TmdbItem item;
  final RecommendationSource source;
  final String reason;
  final String? doubanId;
  final double doubanRating;
  String get key; // TMDB identity, else douban:id, else normalized title
}
class RecommendationPage {
  const RecommendationPage({this.items = const [], this.nextOffset = 0, this.hasMore = false});
  final List<RecommendationEntry> items;
  final int nextOffset;
  final bool hasMore;
}
String recommendationTitleKey(String title);
```

TmdbRecommendationService(TmdbService service, {Directory? cacheDirectory, DateTime Function()? clock}) in services/tmdb_recommendation_service.dart:
- Future<RecommendationPage> related({required RecommendationSeed current, Map<String,Object?>? detail, bool sourceOnly = false, int offset = 0, int pageSize = 12, Set<String> blockedTitles = const {}})
- Future<RecommendationPage> personal({required RecommendationSeed current, List<RecommendationSeed> history = const [], Map<String,Object?>? detail, int offset = 0, int pageSize = 12, Set<String> blockedTitles = const {}})

DoubanRecommendationService({http.Client? client, TmdbService? tmdb, Directory? cacheDirectory, DateTime Function()? clock, Future<void> Function(Duration)? delay}) in services/douban_recommendation_service.dart:
- Future<RecommendationPage> personal({required RecommendationSeed current, List<RecommendationSeed> history = const [], int offset = 0, int pageSize = 12, Set<String> blockedTitles = const {}})
- void close() closes only owned client.
blockedTitles contain recommendationTitleKey values, not raw title strings. No provider creates Flutter widgets or edits AppState. UI owns seed/history conversion, controller and feedback persistence.

### Task 1: TMDB recommendations and shared domain
**Goal:** Implement shared domain and Android-parity related and history-first TMDB personal recommendations.
**Boundary:** lib/core/detail_recommendation.dart; lib/services/tmdb_recommendation_service.dart; lib/services/tmdb_service.dart; test/detail_recommendation_model_test.dart; test/tmdb_recommendation_service_test.dart. Paths relative apps/desktop-flutter. At most 5 edited files per run total.
**Source pointers:** lib/core/tmdb_identity.dart:98; lib/services/tmdb_service.dart:397,711; Android service/PersonalRecommendationService.java:368-405,740-780,1254-1365; locate TmdbSourceAdapter.java:226-231.
**Acceptance:** Frozen API compiles. Related detail payload uses media type fallback when endpoint omits media_type; sourceOnly first-seen cap40/no network. Normal related 120/105 + rating*.8 + genre18/language10/country8 + duplicate12 stable ranking. Personal history-first, resolve missing identity with title/year/type matching, exclude current/history/feedback. Page12 stable offsets and hasMore; no page1 duplication on loadMore. TMDB unconfigured no requests. Existing TmdbService caching/auth/cancel semantics preserved. Persistent 7-day results if cacheDirectory supplied, fallback stale cache.
**Required evidence:** TDD red then green commands/results; new tests and existing TMDB service regressions; diff summary; full report .superpowers/sdd/detail-recommendations/task-1-report.md.
- [ ] Write focused failing tests for source cap/dedupe, context ranking, history-first, unconfigured, pagination and feedback exclusion. Example: expect((await service.personal(current: current, history: [watched])).items.first.item.title, '历史相关影片'); expected initial failure missing implementation.
- [ ] Run /tmp/webhtv-linux-sdk/flutter-3.47.5/bin/flutter test --no-pub test/tmdb_recommendation_service_test.dart; record intended RED.
- [ ] Implement exact frozen domain/provider contract and minimal ranking/selection/cache behavior.
- [ ] Rerun new and relevant existing TMDB service tests; flutter analyze scoped files; self-review and report.

### Task 2: Douban recommendations
**Goal:** Real Douban personal recommendations with Android source flow, persistent cache and rate safety.
**Boundary:** lib/services/douban_recommendation_service.dart; test/douban_recommendation_service_test.dart; report .superpowers/sdd/detail-recommendations/task-2-report.md. At most 3 edited files per run total. Shared domain is owned by Task1; read it, do not edit it.
**Source pointers:** Android service/PersonalRecommendationService.java:416-521,627-669,715-718,844-925,1331-1348; PC lib/services/tmdb_service.dart:110; core/tmdb_identity.dart:98.
**Acceptance:** Frozen API. current + history excluding audio; suggest endpoint -> movie/tv related_items(count10), per-seed maximum1 success; suggest fallback only empty related; parse real nested responses and safe title/year/type subject match; exclude current/history/feedback. Current110/history88-7n/suggest45-n + rating*.8 + duplicate12; row-only dedupe. Douban id/score retained, unresolved item tmdbId0 and title searching usable. Best-effort TMDB merge cannot blank Douban row. 12 item offset paging/hasMore. 7-day disk cache, stale fallback, 750ms global spacing per service, 30min 403/429/captcha cooldown persisted; timeout/no credential leakage. No new dependencies.
**Required evidence:** RED/GREEN service tests with MockClient fixtures asserting returned data (not just calls), timestamp/cooldown/stale/paging/failure tests, scoped analyze, diff summary and report.
- [ ] Write failing tests e.g. expect((await service.personal(current: current)).items.single.doubanId, '1292052') with injected HTTP serving suggest + related JSON; intended missing feature RED.
- [ ] Run flutter test --no-pub test/douban_recommendation_service_test.dart using known SDK and record RED.
- [ ] Implement provider and safe persistent cache/cooldown; use optional tmdb only when configured, with bounded best-match enrichment.
- [ ] Run all new tests/scoped analyze and report.

### Task 3: Both detail pages, feedback and visual evidence
**Goal:** Shared bottom recommendation UI/controller for both detail pages, real watch history and navigation, persistent not-interested feedback.
**Boundary:** lib/ui/detail_recommendations.dart; lib/state/detail_recommendation_state.dart; lib/services/recommendation_feedback_store.dart; lib/ui/browse_pages.dart; lib/ui/tmdb_detail_page.dart; lib/ui/tmdb_detail_view.dart; lib/state/app_state.dart; other lib/ui files containing TmdbDetailPage constructors ONLY for propagating recommendation dependencies; test/detail_recommendations_test.dart; test/recommendation_feedback_store_test.dart; test/detail_recommendation_state_test.dart; test/phase4_tmdb_entry_reachability_test.dart ONLY baseline fixture correction; test/detail_recommendations_visual_test.dart; docs/superpowers/evidence/detail-recommendations/* PNG/scenario/report. At most 18 edited files per run total. Provider/domain files owned Tasks1/2 must not be edited.
**Source pointers:** lib/ui/browse_pages.dart:1188,2820-2895; ui/tmdb_detail_page.dart:135-150,319-365; ui/tmdb_detail_view.dart:436-535,1247-1262; state/app_state.dart:675,5136; services/storage.dart:37-110; Android TmdbHeaderView.java:542-617 and RecommendationFeedbackStore.java:24-37.
**Constraints:** Capture BEFORE prior to UI mutation using the same reproducible fixture as AFTER (1280x800 dark, both detail page bottom scenario; existing view through fixture acceptable, report clearly). Preserve old callbacks/default constructors for existing tests. Existing recommendation wall cannot remain duplicated in middle when new bottom is active. Pure page nested/item/person navigation receives shared history/providers/feedback; use AppState.recentHistory(sourceKey:'') for global watch seeds. Persist feedback 90 days and apply all rows immediately. No hardcoded palette/no AI.
**Acceptance:** Both pages show ordered three rows at very bottom after related videos; empty rows hidden. Independent asynchronous loading, errors nonfatal, stale generations, duplicate loadMore guard/dispose safe, history fingerprint change refresh. Row pagination near end or accessible loadMore; fixed 12 initial items. Context menu/longpress info reason/ratings/source + Not interested, hide same normalized title across rows. TMDB card can open existing TMDB detail/search flow; unbound Douban must global/source title search (no invalid identity route). Scope baseline fixture failure: test/phase4_tmdb_entry_reachability_test.dart:96 assumes service.config.isConfigured false but current config default true. Verify default and fix fixture to explicitly empty config; do not change production default.
**Required evidence:** Same-scenario Before/After PNGs from Flutter render captured before changes; source vs pure page integration tests; state history/paging/race/dispose/failure tests; feedback clock/persistence tests; new and related old tests, scoped analyze. Full report task-3-report.md.
- [ ] Create fixed visual fixture and capture BEFORE to docs/superpowers/evidence/detail-recommendations/before-*.png with page/theme/size metadata.
- [ ] Write failing widget/state tests e.g. expect(find.text('个性推荐·豆瓣'), findsOneWidget); prove RED from absent new rows.
- [ ] Implement shared controller/feedback/UI plus optional page injection and AppState provider/history plumbing; disable old related wall only when new bottom is supplied.
- [ ] Capture AFTER using identical fixture, run widget/state/integration and regression tests; report captures and exact commands.
