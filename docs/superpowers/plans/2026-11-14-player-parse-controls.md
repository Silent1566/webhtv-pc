# Player Parse Controls Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the delegated UI task; core is implemented by the dispatcher under Hybrid topology.

**Goal:** Only expose switchable parser choices for the current parsed playback and separate them from episode selection.

**Architecture:** `SiteService` emits parser selection metadata in `PlaybackDecision`. Proxy reconstruction and `PlaybackRequest` preserve it. Playback adapters copy fresh metadata on each result, and the player renders an independent conditional parser strip. No UI inference from global configuration or diagnostic reason strings.

**Tech Stack:** Dart / Flutter 3.47.5, existing Flutter tests and RepaintBoundary captures.

**Spec:** `docs/superpowers/specs/2026-11-14-player-parse-controls-design.md`

## Global Constraints

- Keep branch `dev1`, upstream `origin/dev1`, and existing remote URL. No commit or push.
- Only change parser display/selection plumbing and its tests/documentation.
- Default parser metadata is empty on direct playback; fixed `json:` / `parse:<名称>` directives retain their existing semantics and expose no ineffective selector.
- Preserve source ownership, quality metadata, headers, subtitles, danmaku, and episode semantics.
- UI uses existing tokens, zero elevation, dark player theme, and horizontal mouse drag.
- Capture Before and After under the same scenarios, viewport and theme; no after-only acceptance.

## Task 1: Core metadata seam (dispatcher, run 1)

**Files:** `lib/core/protocol.dart`, `lib/core/playback_request.dart`, `lib/services/site_service.dart`, `lib/state/app_state.dart`, `test/playback_parse_context_test.dart` under `apps/desktop-flutter`.

**Produces:** The same public properties in `PlaybackDecision` and `PlaybackRequest`:

```dart
final List<String> parseSources; // constructor default const []
final String parseSource; // constructor default empty string
// copyWith accepts List<String>? parseSources and String? parseSource
```

- [ ] Write tests for configured-but-direct results, normal and preferred parser results, fixed prefix results, proxy preservation, and explicit metadata replacement during request updates.
- [ ] Run `flutter test --no-pub test/playback_parse_context_test.dart` and record the missing-contract failure.
- [ ] Add the two metadata fields, preserving them through both copyWith methods and proxy reconstruction.
- [ ] `_runParser` returns current configuration parser names and `spec.selection.entry.name` for normal selectable targets; prefix-fixed targets expose an empty list.
- [ ] Run core tests plus existing parse sniff / parser / playback quality tests; freeze the seam.

## Task 2: Playback adapters and independent UI (one delegated implementer, run 0)

**Boundary:** `lib/ui/player_page.dart`, `lib/ui/player_episode_panel.dart`, new `lib/ui/player_parse_source_strip.dart`, playback request-producing adapters `lib/ui/browse_pages.dart`, `lib/ui/playback_resume.dart`, `lib/ui/history_cross_source.dart`, `lib/ui/web_home_page.dart`, `lib/ui/app.dart`, `lib/state/folder_playback_queue.dart`; task tests under `test/` only.

**Consumes:** Task 1 properties. Every adapter that receives a decision copies:

```dart
parseSources: decision.parseSources,
parseSource: decision.parseSource,
```

- [ ] Capture current baseline at 1280x800 and 800x600, dark player theme: direct playback with configured parsers and parsed playback with the same config, both normal controls and episode dialog. Store artifacts under `.superpowers/parse-controls/evidence/`.
- [ ] Add failing behavior tests for correct visibility, fresh result replacement, source-specific metadata, and parser switch on current episode.
- [ ] Pass metadata through all actual decision-to-request adapters and result updates.
- [ ] Remove parser fields/row from the episode panel and its invocation.
- [ ] Render the independent strip in the player control overlay, gated by current request metadata and route state; preserve tokens, horizontal mouse dragging, and video dimensions.
- [ ] Preserve the existing transient override and re-resolution path, with no inactive choices or retained options on direct results.
- [ ] Run focused tests and analyze; capture matching After scenarios and report paths.

## Task 3: Independent review and acceptance (run 0)

- [ ] Dispatch a read-only review against the confirmed spec and bounded diff.
- [ ] Read key diffs, run acceptance checks independently, and inspect Before/After images.
- [ ] Route every finding back to its owner (at most three task runs total); no silent deferred defects.
- [ ] Verify `HEAD == origin/beta`, `dev1@{upstream} == origin/dev1`, and unchanged remote URL before handoff; report uncommitted changes.

## Decision and run ledger

- Reset run 1: HEAD `559ad544a95a2f3faf1e73ba2e1643d5fe13ad1c`; branch and remote verified.
- Requirements: Q1-parser-scope confirmed by user.
- Topology: Hybrid; tightly coupled core owned by lead; one UI/adapters owner after seam freeze.
- Route discovery: tool returned `deepseek-official/deepseek-v4.1-flash`; no Session allowlist trailer was recorded.
- Core run 1 in progress; UI run 0; review run 0.
- Impeccable launcher: failed with illegal instruction (exit 132); existing PRODUCT/DESIGN read directly, no retry or drift repair.
