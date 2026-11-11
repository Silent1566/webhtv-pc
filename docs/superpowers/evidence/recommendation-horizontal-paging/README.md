# Recommendation horizontal pagination evidence

The shared `DetailRecommendations` widget is used by both source DetailPage and TmdbDetailPage. All three horizontal rows now fetch their next page near the right end without an explicit “加载更多” control. Card width (130), poster height (180), spacing, styling, navigation, and feedback remain unchanged.

## True Before / After

The dedicated `horizontal paging capture` fixture in `apps/desktop-flutter/test/detail_recommendations_visual_test.dart` was added and run against the original button-based widget **before production edits**. It was then run against the new widget without changing the fixture, data, theme, font, padding, or gestures. Historical screenshots elsewhere were not overwritten; existing visual tests now run their geometry assertions without rewriting those historical files.

Capture setup:
- Dark `buildAppTheme`; FixtureCJK from `/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc`; SDK MaterialIcons.
- Viewports: 1280×1100 desktop and 420×1100 narrow, DPR 1, 16px padding.
- All three rows, 12 items/page, fixed numbered Chinese titles, ratings 8.4; empty poster URLs use real placeholder rendering (no network).
- `start`: settled initial view. `right`: two horizontal −2200px drags per row, settling after each.
- Before requests `[0]` and rightmost card 12; After requests `[0, 12]` and rightmost card 24, asserted for each row.

| Scenario | Before | After |
|---|---|---|
| Desktop start | [PNG](../../../../.local/recommendation-horizontal-paging/before-1280.0-start.png) | [PNG](../../../../.local/recommendation-horizontal-paging/after-1280.0-start.png) |
| Desktop right | [PNG](../../../../.local/recommendation-horizontal-paging/before-1280.0-right.png) | [PNG](../../../../.local/recommendation-horizontal-paging/after-1280.0-right.png) |
| Narrow start | [PNG](../../../../.local/recommendation-horizontal-paging/before-420.0-start.png) | [PNG](../../../../.local/recommendation-horizontal-paging/after-420.0-start.png) |
| Narrow right | [PNG](../../../../.local/recommendation-horizontal-paging/before-420.0-right.png) | [PNG](../../../../.local/recommendation-horizontal-paging/after-420.0-right.png) |

PNGs are local workspace artifacts, eight total. Do not regenerate Before against the new widget.

Capture command (from `apps/desktop-flutter`; `before` was run prior to implementation):
```sh
TMPDIR="$PWD/../../.local/recommendations-tmp" \
  /tmp/webhtv-linux-sdk/flutter-3.47.5/bin/flutter test --no-pub \
  test/detail_recommendations_visual_test.dart \
  --plain-name "horizontal paging capture" \
  --dart-define=PAGING_CAPTURE_PHASE=after
```

## Verification

- RED: `flutter test --no-pub test/detail_recommendations_scroll_test.dart` — 12 expected failures before implementation, missing next-offset requests. A later empty-first-page test was also observed RED before extending row rendering.
- GREEN: the three UI test files (`detail_recommendations_test.dart`, `detail_recommendations_scroll_test.dart`, `detail_recommendations_visual_test.dart`) — 62 passed. Dedicated horizontal suite: 17 cases.
- Broader related suites: `detail_recommendation_state_test.dart`, `recommendation_back_navigation_test.dart`, `recommendation_target_test.dart`, `recommendation_feedback_store_test.dart`, `tmdb_recommendation_service_test.dart`, `douban_recommendation_service_test.dart` — 110 passed.
- After capture fixture — 2 passed.
- Final combined run of all nine related suites — 172 passed.
- Focused `dart analyze` on the shared widget and the three UI test files — no issues found; `git diff --check` passed.

The dedicated suite additionally verifies that an empty first page, pending/failed subsequent page, non-progress empty page, and feedback removing the last entry leave no visible heading or row-height gap; a populated sibling retains its original vertical position. It exercises touch, mouse, and native trackpad pan/zoom; next offsets, appended-card navigation, position retention, in-flight deduplication, exhaustion, failure without passive retry loops and deliberate end-drag retry, short/empty first pages, successive underfilled pages, viewport growth, row independence, vertical isolation, refresh/stale completion, and disposal.

Passive fill stops once the row can scroll, or if a page adds no visible cards, or if a request fails. Completely empty rows remain offstage (no heading, card-height gap, hit testing, or retry control); their internal paging subtree stays alive to fill an initially empty page without exposing blank UI. Populated short rows accept a later deliberate right-end gesture to advance/retry via `AlwaysScrollableScrollPhysics`. Existing state guards still own loading, exhaustion, offset progression, and stale generations.

### Routed review correction (run 2/3)

Independent review identified a regression against the original “空行隐藏” contract: `hasMore` alone could expose a titled empty row after a second empty/failed page or feedback removing all visible entries. Four new regressions were first run RED (`+0 -4`, visible related heading found when none was expected), then fixed with an offstage section wrapping the existing internal pager. All 17 dedicated cases now pass, including initially empty→nonempty fill; all nine related suites pass (`+172`), and the focused analyzer reports no issues. The same four After paths were regenerated using the unchanged fixture. SHA-256 comparison confirms all four original Before PNGs unchanged. All eight README PNG links were resolved from the README directory and verified to exist; the four `../` levels are correct.

Environment issue handled: `/tmp` lacked space for the Flutter test compiler. Tests were rerun with the existing disk-backed workspace TMPDIR and `--no-pub`. The parent reverted Flutter’s incidental out-of-boundary analysis-options migration. No state, service, dependency, public API, or historical PNG was changed; no commit was created.

## Lead acceptance

Accepted after run 2/3. The lead independently inspected the production pagination lifecycle, Offstage empty-row correction, gesture/offset regression assertions and matched desktop/narrow Before/After evidence. Fresh independent execution of all nine related suites passed 172 tests (exit 0); focused analyzer returned “No issues found”; `git diff --check` passed. Independent test log: `.local/recommendation-horizontal-paging/lead-tests.log`. Before hashes match the original captures; populated After hashes are unchanged by the empty-row fix. The empty-row regression was routed back to the original child and corrected before acceptance; no known remaining scoped defect. Verification is fixture-based, not live-network end-to-end or the repository-wide suite.
