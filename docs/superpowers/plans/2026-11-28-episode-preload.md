# Episode Preload Implementation Plan

> **For agentic workers:** Use TDD for each step and independently verify the final diff before marking it complete.

**Goal:** Reduce HLS VOD episode-transition latency without stealing foreground playback resources.

**Architecture:** PlayerPage owns candidate selection and timing. AppState holds isolated prospective authorization; LocalProxyServer owns media admission, eviction, and reuse. Existing playback open/start and recovery mechanics stay authoritative.

**Tech Stack:** Flutter/Dart, media_kit/mpv, existing Dart loopback HTTP proxy.

**Spec:** [Episode preload design](../specs/2026-11-28-episode-preload-design.md)

## Global Constraints

Opt-in; no dependencies or new decoder. One background media request; same-session cache only. No speculative parser/bridge side effects. Preserve source, season, progress and existing fallback rules.

### 1. Schedule and select the opening

- [x] In `test/episode_preload_test.dart` test the lead time against an actual auto-skip finish, early short-video scheduling, buffer gating, and intro selection at zero.
- [x] Implement `episodePreloadBatch` and `episodePreloadStart` in `lib/core/episode_preload.dart`; run the new and existing skip tests.

### 2. Prepare and reuse media

- [x] In `test/episode_proxy_preload_test.dart` use a real HTTP fixture: warm after the intro without a foreground GET, then fetch the ordinary manifest and verify the landing segment is served without a second upstream request. Cover live, stale, private and cancelled windows.
- [x] In `lib/services/proxy_server.dart` use the shared request arbiter and same-session freshness checks; run the new fixture and `test/proxy_prefetch_test.dart`.

### 3. Link resolution and playback

- [x] In `test/episode_preload_handoff_test.dart` prove preparation keeps the active decision/token unchanged, promotion transfers the prepared token and lands at the chosen start, and cancellation/ordinary transitions cannot promote.
- [x] In `lib/services/site_service.dart` and `lib/state/app_state.dart` resolve direct HTTP VOD in isolation. In `lib/ui/player_page.dart` only consume exact next-episode matches; apply the confirmed intro through native `startAt`, not as a saved resume point. If warm opening fails, use normal resolve/open once without preload.
- [x] Remove foreground HEAD from the preference and update `player_options.dart` and `settings_detail_pages.dart`. Run playback, proxy, seek, line/version selection, and settings regressions; review cancellation, authorization and bounds.

## Acceptance

- The final focused Windows run passed 132 tests across 8 playback, proxy, skip and resolver suites, including native libmpv HLS startup and same-segment reuse.
- The independent review findings were reproduced and resolved: credentials are scoped to the manifest's original origin, abandoned site API requests are aborted, and unproxied foreground streams do not start episode preloading.
- This is controlled loopback evidence; it is not a measurement of real CDN hit rates or first-frame latency.
