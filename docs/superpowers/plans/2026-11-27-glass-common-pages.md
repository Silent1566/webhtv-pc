# 常用页面玻璃扩展 Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the independent adapters, with Lead acceptance after self-verification. No unattended uploads or commits.

**Goal:** Make glass visible in the actual main desktop flows in both themes, without moving or replacing the controls.

**Architecture:** Keep a single backdrop filter per bar or dialog, using the existing AppGlass material. The shell and the two detail routes use artwork only after a frame is available; fixed controls and fallback geometry must not depend on decode state.

**Tech Stack:** Flutter desktop, Material 3, Flutter widget tests, Linux Release.

**Spec:** This scope record extends DESIGN.md §Glass; the project product and identity remain unchanged.

## Global Constraints

- Shell routes: 首页、点播、直播、搜索、最近观看、收藏、追剧、设置; other targets: both detail bars and the two topbar pickers. No video, WebView, or settings/config management subpages.
- No new packages or artwork, no per-card/list/input blur. If usable artwork is absent, pending or broken, bar stays opaque. Keep navigation, focus, search, activation and source switching unchanged.
- Preserve the existing light shell; dark chrome must achieve 4.5:1 for enabled ordinary-size text on representative demanding backdrops. Keep 0px no-art dark baseline without re-recording it. Retain unchanged source fixtures and historical evidence.
- Appearance changes require same-viewport/same-theme before and after or an explicit note when before is not reliable. Store this round's synthetic captures in .local/glass-rollout-captures, not the historical output directories. Do not use private real configuration or search results as fixtures.
- Flutter commands must serialize: from apps/desktop-flutter, use the local SDK in ../../.local/linux-build/flutter/bin and acquire flock on the absolute repo .local/glass-rollout-flutter.lock; use TMPDIR=/var/tmp for widget tests. Log only bounded output.

## A. Shared chrome (Lead-Core)

Files: lib/ui/glass_chrome.dart, lib/ui/glass_dialog.dart (obsolete chrome export), test/glass_shell_test.dart, test/glass_chrome_rollout_test.dart (all under apps/desktop-flutter).

- [x] RED: At a fixed viewport, mount a GlassTopBar over two visually distinct backdrops; require no filter for flatSurface, exactly one with content, and differing visible bar pixels for each brightness. Record the initial dark capture before changing production.
- [x] GREEN: Gate GlassTopBar on GlassTopBarBackdrop.content regardless of brightness. Export GlassChromeSurface({super.key, required Widget child}) as a flat, clipped single-filter paint surface; use it only if a caller already has a decoded backdrop. Preserve the old 64px shell and no-art branch. Use the same surface for detail AppBar.flexibleSpace; do not introduce a new app theme.
- [x] Verify contrast on both artwork contrasts with an in-bounds glyph-free sample; write down strictly what was tested. Update only obsolete light-only policy assertions; keep all no-art pixel baselines.

## B. Site/config picker adapters

Files: lib/ui/app.dart picker-only, lib/ui/config_pages.dart switcher-only, relevant site/config tests. Own .local/glass-rollout-captures/pickers.

- [x] RED: Open each actual picker in each theme and assert a single clipped BackdropFilter within its panel; verify autofocus/filter, modal scope, keyboard focus loop, and management activation path with existing test fixtures.
- [x] GREEN: Reuse GlassAlertDialog or a bounded GlassSurface inside the existing Material AlertDialog, preserving geometry, list scroll and controls. Use the paired barrier and ensure the panel is not opaque; use appropriate glass ink for helper subtitles. No app-wide theme change.
- [x] Measure 4.5:1 for both main and supporting ink in both themes at contrast-critical positions, preserve unchanged dialog layout in a narrow viewport, capture both before and after.

## C. Ordinary and TMDB detail bars

Files: lib/ui/browse_pages.dart, lib/ui/tmdb_detail_page.dart, lib/ui/tmdb_detail_view.dart, focused existing or new detail tests; own .local/glass-rollout-captures/detail.

- [x] RED: Mount both production routes and assert a decoded background yields one filter within the route's AppBar; prove missing/failed artwork remains opaque and controls/scroll origins remain fixed during decode. Check back and source action hit targets.
- [x] GREEN: Consume the existing backdrop's decoded image signal, not a nonempty URL or a parallel fetch. Paint the image under the AppBar without moving foreground content on load; use GlassChromeSurface only with available art. Preserve both routes' existing actions, title, page background, scroll anchors, error and loading behavior.
- [x] Capture both routes in the same theme and viewport before/after, check colors and no clipped foreground. Verify against existing backdrop, ordinary detail and TMDB flow tests.

## Lead rollout gate

- [x] Inspect diffs against entry state, ensure each task stayed within its bounds, verify image pairs and contract, and run focused shell/picker/detail suites serially plus targeted analyze.
- [x] Update the DESIGN.md glass contract by literal anchors (no whole-file rewrite), then run flutter pub get and flutter build linux --release --no-pub --dart-define=APP_VERSION=0.1.0 using .local/linux-build/environment.sh. Verify the release AOT, then launch only the new worktree bundle in the real X11 desktop and verify that its PID owns a viewable WebHTV PC window. No Windows/GPU performance claims.

## Acceptance and hand-off

- A: Verified the real shell with a wallpaper across all 8 destinations, including a no-wallpaper home hero and a no-art fallback. The validated black/white probe requires visible sampling and 4.5:1 contrast; changed enabled ink only inside active chrome to pass this floor.
- B: Pickers accepted in run 1/3; 40 independent focused checks passed, three optional historical captures skipped.
- C: Detail bars accepted in run 1/3; compared four matched pairs and checked stale-frame invalidation, opaque fallback, content geometry and navigation.
- Final gate: 137 related widget tests passed, scoped analyzer checked 14 files, git diff --check clean. Sourced local toolchain and rebuilt Release. Fresh libapp.so is present in the live process mappings, and its WebHTV PC X11 window is viewable.
- Evidence: .local/glass-rollout-captures/{chrome,shell,pickers,detail}/; build log .local/build-logs/glass-rollout-release-CA2Mrk.log. Windows runtime performance was not measured.
