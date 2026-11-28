#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "native_trace.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  webhtv::NativeTrace::Mark("win32-on-create");

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  // `FlutterViewController` 构造内部会初始化 Dart VM 与渲染表面，是冷启动的
  // 主要分界点，因此单独打点。
  webhtv::NativeTrace::Mark("engine-created");
  RegisterPlugins(flutter_controller_->engine());
  webhtv::NativeTrace::Mark("plugins-registered");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  player_menu_popup_ = std::make_unique<PlayerMenuPopup>(
      GetHandle(), *flutter_controller_, project_);
  webhtv::NativeTrace::Mark("child-content-set");

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    webhtv::NativeTrace::Mark("native-first-frame");
    this->Show();
    webhtv::NativeTrace::Mark("window-shown-native");
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();
  webhtv::NativeTrace::Mark("force-redraw");

  return true;
}

void FlutterWindow::OnDestroy() {
  player_menu_popup_.reset();
  FinishWindowTransition();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  constexpr UINT begin_transition = WM_APP + 0x481;
  constexpr UINT finish_transition = WM_APP + 0x482;
  constexpr UINT request_target_frame = WM_APP + 0x483;
  constexpr UINT target_frame_presented = WM_APP + 0x484;
  constexpr UINT_PTR transition_timer = 0x485;
  if (message == begin_transition) {
    if (fullscreen_frame_.Begin(hwnd)) {
      ++frame_transition_generation_;
      // A recovery bound, not a delay: normal handoff is driven by presented frames.
      if (!SetTimer(hwnd, transition_timer, 1000, nullptr))
        FinishWindowTransition();
    }
    return fullscreen_frame_.active() ? 1 : 0;
  }
  if (message == finish_transition) {
    if (fullscreen_frame_.active()) {
      pending_frame_generation_ = frame_transition_generation_;
      pending_frame_phase_ = 0;
      RequestWindowTransitionFrame();
    }
    return 0;
  }
  if (message == request_target_frame || message == target_frame_presented) {
    frame_callback_pending_ = false;
    if (fullscreen_frame_.active()) {
      if (wparam == frame_transition_generation_) {
        if (message == target_frame_presented) {
          FinishWindowTransition();
          return 0;
        }
        pending_frame_generation_ = frame_transition_generation_;
        pending_frame_phase_ = 1;
      }
      RequestWindowTransitionFrame();
    }
    return 0;
  }
  if (message == WM_TIMER && wparam == transition_timer) {
    FinishWindowTransition();
    return 0;
  }
  if ((message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE) ||
      (message == WM_SHOWWINDOW && !wparam) ||
      (message == WM_SIZE && wparam == SIZE_MINIMIZED))
    FinishWindowTransition();

  // Reactivating the player dismisses a native menu without passing that click to playback.
  if (message == WM_MOUSEACTIVATE && HIWORD(lparam) == WM_LBUTTONDOWN &&
      player_menu_popup_ && player_menu_popup_->visible()) {
    webhtv::NativeTrace::Mark("player-menu-outside-click-consumed");
    return MA_ACTIVATEANDEAT;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::FinishWindowTransition() {
  ++frame_transition_generation_;
  if (GetHandle())
    KillTimer(GetHandle(), 0x485);
  fullscreen_frame_.End();
  if (GetHandle())
    SendMessage(GetHandle(), WM_APP + 0x486, 0, 0);
}

void FlutterWindow::RequestWindowTransitionFrame() {
  if (frame_callback_pending_ || !fullscreen_frame_.active() ||
      !flutter_controller_ || pending_frame_generation_ != frame_transition_generation_)
    return;
  const HWND hwnd = GetHandle();
  const auto generation = pending_frame_generation_;
  const UINT next = WM_APP + (pending_frame_phase_ == 0 ? 0x483 : 0x484);
  frame_callback_pending_ = true;
  // The SDK wrapper owns one slot; never replace it until its posted completion
  // has returned to this window, including after an aborted/overlapped request.
  flutter_controller_->engine()->SetNextFrameCallback([hwnd, generation, next]() {
    PostMessage(hwnd, next, generation, 0);
  });
  flutter_controller_->ForceRedraw();
}
