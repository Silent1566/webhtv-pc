# 推送与常用设置顶栏 Implementation Plan

> Lead-Core: respect the user’s ordered push → settings rollout; freeze the shared settings seam before the small page adapters. Keep existing dirty work intact; no commits or dependency changes.

**Goal:** Cover the missing Push dialog and let configuration management and common first-level settings routes use the same glass material as the main shell.

**Spec:** DESIGN.md §Glass, extended only for the named routes. Both themes, one filter per surface, unchanged form/control layout and business logic. Settings share the existing decoded-config-wallpaper rule and an opaque fallback (no invented image, no wallpaper requirement for push). Only the bar samples wall art; settings content stays opaque. Do not touch player, WebView, lower-level management tools or native title bars.

- [x] **Push:** Extend the existing real-shell wallpaper fixture with a dual-theme before/after, one-panel-filter and barrier gate. Change app.dart’s push presentation and push_dialog.dart’s surface without changing address, file picker, cancel, focus, error or PushDetail routing; run push_dialog_test.dart.
- [x] **Settings core and routes:** Reuse the wallpaper decoder from app.dart and the existing glass chrome. Add a shared settings route scaffold in settings_layout.dart; opt in ConfigPage, PlaybackOptions, SubtitleSettings, DanmakuSettings, LiveSettings, TmdbSettings, AndroidSettings, OutboundProxy and DoH. Preserve existing AppBar geometry, body color and scrolling on decode/load/error; use the theme’s standard no-art AppBar.
- [x] **Review:** Check real entry points with a deterministic wall fixture, delayed and failed decode, narrow-window layout, contrast and keyboard behavior. Same-scenario before/after with opt-in captures under .local/glass-rollout-captures/push-settings/. Update DESIGN.md by anchor and run scoped analyze and established config/settings/shell regressions.
- [x] **Hand-off:** Use the local SDK and build environment to compile Linux Release and launch the current worktree bundle; match mapped AOT and desktop window PID. Serialize Flutter commands with .local/glass-rollout-flutter.lock.

## Lead acceptance

Push 2 + representative settings 4 tests went RED for the missing backdrop filter and then GREEN. All nine settings routes have a single clipped bar filter; art failure, title/body geometry, and original picker/management flow pass. Scoped analyze clean; 99 focused tests passed, four skipped. Reviewed twelve paired captures under .local/glass-rollout-captures/push-settings/. Rebuilt Linux Release using local SDK, confirmed new settings types in the AOT, and matched the live WebHTV PC window to that bundle. Build log: .local/build-logs/glass-push-settings-release-kb7V1Q.log.
