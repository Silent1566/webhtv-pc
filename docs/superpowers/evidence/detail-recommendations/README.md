# Detail recommendations acceptance

Task 6 identity fallback: recommendation fallback Vods now retain `tmdb_id`/`media_type`; no-playback loads may attach that known identity, validated against the typed fetched TMDB payload, without writing the match cache. Series fallbacks render all-season nav cards; movie/unconfigured/disabled/unverifiable cases retain the honest swap-only state. Final restored tree: canonical 17-file roster **+373 passed**, scoped 4-file analyzer **No issues found**, diff check clean. Readable 1280×800 dark FixtureCJK capture `task-6-known-series-fallback.png` (SHA 35f3e3c39ddcc7edfe12841e0d09c9e710ad28447eb655b6b759d447bc92ca67); Before at `.local/task6-before-known-series-fallback.png`. Details: `.superpowers/sdd/detail-recommendations/task-6-report.md`.

Task 5 back-navigation fix: preserve the originating source page layout while a recommendation detail owns shared state, then reload its own Vod/site/service before releasing the retained view; existing clear-on-leave remains. Reproduced source scroll 1188→162 before, exact 1188 preserved after; dialog/sheet dismissal and pure-page return were already correct. Final post-restore focused suite: **12 passed**; broader recommendation suites: **369 passed**; touched-file analyzer: **No issues found**; diff check clean. Four matched Before/After origin/back capture pairs (1280×800 dark, FixtureCJK) are test artifacts at .local/task5-{before,after}-cd-{source,pure}-{appbar,system}.png; full commands, cleanup-ordering RED/GREEN and hashes: .superpowers/sdd/detail-recommendations/task-5-report.md.

Both source DetailPage and pure TmdbDetailPage now share bottom rows: 猜你喜欢 / 个性推荐·TMDB / 个性推荐·豆瓣. No AI recommendation calls or collections/tag rows. History-first TMDB, Douban suggest+related, independent row failures, paging12, persistent90-day feedback, source payload first-seen/cap40 and working source-search navigation.

## Independent final commands
Flutter SDK /tmp/webhtv-linux-sdk/flutter-3.47.5/bin/flutter. Commands prefix TMPDIR=<repo>/.local/recommendations-tmp to avoid2.2G tmpfs exhaustion.
- Combined15testfiles (newproviders/state/feedback/pages/visual + TMDBservice/cache/title/match/detail + episode/calendar): **322 passed**, exit0. Log .local/final-acceptance.log.
- All20changedDartfiles analyzed: **No issues found**, exit0. Log .local/final-analyze.log.
- git diff --check clean.

## Visual evidence
PNG pairs before/after-{source,pure}.png and before/after-{source,pure}-bottom.png, 1280x800 dark with fixed fixture and fonts. Bottom scenario scroll430 shows readable Douban score and paging controls. These are shared-section render fixtures, **not live full-app screenshots**; real page insertion/navigation also covered by widget integration tests. Readable Before uses retained legacy recommendationBottom:null path; original pre-edit raster stored in original-before-audit.png.

## Routed risks
Implemented/fixed identity aliases, missing media_type, Douban enrichment dedupe, stable paging and concurrent snapshot commit, source payload ordering/history classification, SearchPage Material+return navigation, shared feedback through calendar/person paths, shutdown timers, scaled text overflow, and fixture font readability.
Pristine commit102440acd393a31856540f39764ec614fca0e015 (gitarchive copied baseline) runs old8suites75pass11fail; current76pass10fail. One incorrect test fixture isolation fixed. **User explicitly chose to leave remaining10pre-existing failures outside this request**; names recorded in task-3-report.md section7 and .superpowers/sdd/detail-recommendations/baseline-verification.md. No claim all repository tests pass.

## Technical decisions
- A Douban paging session fixes related-vs-suggest mode and append order; it re-evaluates when history/feedback/pageSize changes or the cached snapshot expires. Prevents mix/reorder while scrolling.
- Unresolved Douban items have no fabricated TMDB identity; title search remains available.
- Optional old constructor defaults retained; unbound standalone pages use memory feedback, AppState-backed entries share the persistentstore.
No commits/pushes/merges or new dependencies.

Back from a recommendation detail restores the originating page: while the recommendation route owns the global detail slot, the origin keeps its rendered layout, then reloads its own Vod (same site/service context) after the route returns, so hero content, source lines and all three rows come back and the scroll offset is preserved instead of clamping to the shortened empty state. Route-completion ownership guard clears only while this page still owns the slot, once per origin, and works for app-bar back, system back/Esc and route removal. Evidence: 12 focused tests, 360-test canonical acceptance run, 23-file analyze clean, paired before/after captures.

Recommendation click routing: a shared pure rule (lib/core/recommendation_target.dart) searches the current page site by title with the user similarity threshold; a match opens that site DetailPage for the real Vod (directly playable), otherwise the same DetailPage opens in nav-source style for a synthetic Vod (empty vodId skips the site request, TMDB episode cards plus the existing 换源 flow); Douban entries without TMDB identity keep the title-search page. Verified by 348-test acceptance run, new nav-source fallback capture task-4-nav-source-fallback.png, and zero analyzer issues over 22 changed files.

Final release seam: both providers cancel when the last page releases. Shared TMDB service and feedback survive. Transport timeout timers cancel immediately; listener cleanup does not block widget completion. Already dispatched HTTP may complete, but late results cannot cache or start new recommendations.

Execution note: no Session child-model allowlist was recorded; explicit deepseek-official/deepseek-v4.1-flash routes used.



## Task 6 — no playable episode means the nav-source card view

A recommendation fallback page used to show only a 换源 button because the synthetic Vod dropped `tmdbId`/`mediaType`, so TMDB could only be reached by title matching. The fallback Vod now keeps that identity, and TMDB state accepts an optional, validated `knownIdentity` only for nav-source / no-playable loads (ordinary call sites still match by title). The seeded identity is validated against the typed fetched payload (endpoint, id, present media_type, name shape); any mismatch degrades to the honest swap-only state and writes no match-cache record. Same for a REAL source entry with no playable episodes and a known identity. Movies stay swap-only because TMDB has no episodes.

Evidence: real-route RED (empty title search, `/tv/1399` + seasons available, hasMatch expected true / actual false) then GREEN; 13 new contracts; canonical 17-file roster +373; 24-file analyze clean; capture `task-6-known-series-fallback.png` showing 选集 · 4 集 with S1E1/S1E2/S2E1/S2E2 cards.

## Task 4 — recommendation click: current-site match, else nav-source fallback

Clicking a bottom recommendation card now runs one shared rule (`core/recommendation_target.dart`):

- search the **current page site** by the item title (`searchResultMatches` + `AppState.searchSimilarity`, quick search, same as the 换源 sheet);
- matched (score ≥ user threshold) → push the real `DetailPage` for that `Vod` on the current site, directly playable;
- no match / empty result / search threw → push the same `DetailPage` in **nav-source style** for a synthetic `Vod` with an empty `vodId`: `AppState.loadDetail` skips the site detail request and only runs the existing TMDB chain, so the page shows TMDB episode cards and can only be played through the existing 换源 flow;
- Douban entry without TMDB identity → existing title-search page, unchanged.

Both detail pages share the handler: the source `DetailPage` searches its own `_pageSite`, the pure `TmdbDetailPage` searches `state.selectedSite`. No new page type, no duplicated swap sheet or nav-source judgement.

Evidence: `task-4-nav-source-fallback.png` — 1280x800 dark, same `FixtureCJK` font as the other captures, synthetic fallback page with the TMDB status row and 选集 · 2 集 cards (S1E1/S1E2). The 换源 entry is the card-tap dialog (`nav-source-swap-confirm`), which the widget test drives; the card's action is a Tooltip (`换源播放`), not visible body text. No line selector and no hero play button exist before swapping (both asserted in `detail_recommendations_test.dart`).

