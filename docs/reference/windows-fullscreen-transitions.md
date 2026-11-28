# Windows fullscreen frame handoff

## Problem and chosen boundary

Fullscreen has two independent correctness requirements: native geometry reaches the target once, and the displayed frame must not mix target bounds with the previous viewport. Geometry-only tests cannot establish the second requirement.

The first-round window_manager 0.5.2 patch changes caption/style and position/size in one SetWindowPos, keeps the normal/maximized restore state, and emits one fullscreen event. A subsequent real-monitor capture still found cropped fullscreen content during exit (4 detected mismatches in 16 transitions on the local fixture).

The second-round Windows runner retains a bitmap of **its own complete window**, displays it without activation, and temporarily cloaks the real window while its viewport changes. After an already queued frame drains, an explicitly requested target-viewport frame completes the handoff. No animation or fixed handoff delay is introduced. A 1,000 ms timer is recovery only; hide, minimize and destruction also clean up. Failure to acquire the bitmap/cover leaves the original window visible and uses the ordinary resize path.

The Flutter Windows C++ wrapper has one callback slot and clears it after invoking the closure. Accordingly, callbacks only post messages; the runner permits only one outstanding SDK callback and scopes completions to a generation. This prevents rapid requests, cancellation or reentrant platform-task pumping from overwriting the slot or releasing another transition's cover. Hidden/minimized startup requests never replace the initial callback that shows the window.

## Implementation pointers

- apps/desktop-flutter/lib/ui/window_mode.dart: Windows does not separately change the title bar.
- apps/desktop-flutter/windows/window_manager-0.5.2-fullscreen.patch: atomic geometry, event handling, and begin/end handoff messages.
- apps/desktop-flutter/windows/runner/fullscreen_frame.{h,cpp}: window-owned image capture and scoped cloak/cover cleanup.
- apps/desktop-flutter/windows/runner/flutter_window.{h,cpp}: single outstanding frame callback, generation checks, and cancellation.
- apps/desktop-flutter/windows/window_manager_fullscreen.cmake: build-tree-only patch; the hash of included window_manager.cpp is embedded in the compiled plugin.cpp to force MSVC to rebuild the actual translation unit. Never edit the shared pub cache.

## Acceptance evidence (2026-11-27, dev1 working tree)

- Native integration: 3 passed, covering normal/maximized bounds restoration, repeated requests, rapid enter/exit and hide/show cleanup.
- Existing Phase 8 real-video integration: 1 passed, fullscreen rectangle equals monitor and returns to the original rectangle.
- Related widget suites: 33 passed (window mode, player fullscreen, overlays, click gestures).
- Dart analysis: changed UI and tests reported no issues.
- Normal-window actual-monitor recording: 32 transitions, 0 detected intermediate cropped frames.
- Maximized-window actual-monitor recording: 16 transitions, 0 detected intermediate cropped frames.
- Normal-entry Windows Release build succeeded. Source/API safety review accepted after resolving callback-slot overlap, startup visibility and bounded cleanup.

Reproduce the screen check with tools/fixture_server/server.py running and Python packages numpy, opencv-python, pywin32, windows-capture==1.5.0 installed:

```powershell
python tools/phase8/verify_fullscreen_composition.py <release.exe> <evidence-dir> --rounds 16 --monitor --assert-clean
```

Add --maximize for the maximized scenario. The tool launches an isolated fixture-data player and gives it real foreground focus without pre-promoting it to topmost; it does not stop or control existing application windows. Captures and logs from this run are under .local/fullscreen-evidence and .local/fullscreen-phase2, not checked in.

The visual verifier samples fixture-video width in composed monitor frames; it is not a proof that every GPU, refresh rate or DPI combination is artifact-free. Window-only WGC captures can contain resize-buffer artifacts that are not monitor output, so they are diagnostic only. Readiness checks prevent an occluded/unready monitor capture from silently passing.

## Primary references

- mpv Win32 style/geometry and DWM boundary: https://github.com/mpv-player/mpv/blob/master/video/out/w32_common.c
- Chromium fullscreen restore geometry: https://chromium.googlesource.com/chromium/src/+/main/ui/views/win/fullscreen_handler.cc
- Win32 SetWindowPos copy/redraw semantics: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos
- Flutter resize waits for present: engine/src/flutter/shell/platform/windows/flutter_windows_view.cc (local SDK 3.47.5, OnWindowSizeChanged / OnFramePresented).
- Flutter callback-slot ownership: engine/src/flutter/shell/platform/windows/client_wrapper/flutter_engine.cc, SetNextFrameCallback.

Review routing note: no Session child-model allowlist was recorded; the independent read-only review used the explicit deepseek-official/deepseek-v4.1-flash route.

## Taskbar regression follow-up (2026-11-27)

The earlier geometry/composition evidence did not prove the real player was above the shell taskbar: the old visual probe pre-promoted its test window to topmost. That could conceal a production z-order defect. The taskbar-specific reproduction kept the player genuinely foreground without changing its topmost band and found taskbar overlap in all four fullscreen entries.

The fix uses ITaskbarList2::MarkFullscreenWindow on committed entry/exit and a foreground-only topmost band while fullscreen. On WA_INACTIVE the temporary promotion is removed and placed behind the newly active normal window; reactivation reapplies it. The existing user always-on-top setting is stored independently and can still be changed while fullscreen. No entire GWL_EXSTYLE snapshot is restored. Rollback restores previous bounds/band. The handoff cover is cleaned up on deactivation and stacking is reconciled after uncloak.

A directly reproduced late WA_INACTIVE also exposed the runner's unconditional SetFocus(child): it reactivated the old player after a different application gained foreground. The runner now focuses its child only when activated, never on WA_INACTIVE.

Taskbar verification is tools/phase8/verify_fullscreen_taskbar.py. It samples actual foreground and taskbar/player z-order, creates a separate non-topmost focus target, checks the target really stays above the inactive player, sends delayed deactivation, then switches back and exits. The composition probe now uses real child focus, no synthetic activation or pre-promotion; complete endpoints are calibrated from settled normal/fullscreen frames so a retained complete old frame is not mistaken for cropping.

Latest verification: native suite 4 passed (including live always-on-top preference), real-video suite 1 passed, focused widget suites 13 passed, real taskbar check 4 entries with zero covered samples plus four real focus switches, normal screen 24 transitions with zero detected mismatches, maximized screen 12 transitions with zero detected mismatches. Canonical Windows Release build succeeded. An independent read-only review's permanent-topmost, focus-order and test-foreground findings were resolved and reverified.

Primary shell contract: https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-itaskbarlist2-markfullscreenwindow
