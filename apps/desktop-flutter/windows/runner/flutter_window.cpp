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
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
