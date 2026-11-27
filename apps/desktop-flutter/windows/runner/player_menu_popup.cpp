#include "player_menu_popup.h"

#include <flutter/standard_method_codec.h>

#include <cmath>
#include <utility>

#include "native_trace.h"

namespace {
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Channel = flutter::MethodChannel<EncodableValue>;
constexpr wchar_t kWindowClass[] = L"WebHtvPlayerMenuPopup";

const EncodableValue& Read(const EncodableMap& map, const char* key) {
  static const EncodableValue null;
  const auto it = map.find(EncodableValue(key));
  return it != map.end() ? it->second : null;
}

int64_t AsInt(const EncodableValue& value) {
  if (const auto* i = std::get_if<int32_t>(&value)) return *i;
  if (const auto* i = std::get_if<int64_t>(&value)) return *i;
  return 0;
}

int64_t Session(const EncodableMap& data) {
  return AsInt(Read(data, "session"));
}

int Width(const RECT& rect) { return rect.right - rect.left; }
int Height(const RECT& rect) { return rect.bottom - rect.top; }

std::unique_ptr<Channel> MakeChannel(flutter::FlutterViewController& controller,
                                     const char* name) {
  return std::make_unique<Channel>(controller.engine()->messenger(), name,
                                   &flutter::StandardMethodCodec::GetInstance());
}
}  // namespace

PlayerMenuPopup::PlayerMenuPopup(HWND owner, flutter::FlutterViewController& player,
                                 const flutter::DartProject& project)
    : owner_(owner), player_view_(player.view()->GetNativeWindow()), project_(project) {
  project_.set_dart_entrypoint("playerMenuPopupMain");
  project_.set_dart_entrypoint_arguments({});
  // The popup only draws static menu surfaces; don't initialize a second Impeller renderer.
  project_.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
  host_channel_ = MakeChannel(player, "webhtv/player_menu_host");
  host_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* data = std::get_if<EncodableMap>(call.arguments());
    if (!data || Session(*data) == 0) {
      result->Success(EncodableValue(false));
    } else if (call.method_name() == "open") {
      result->Success(EncodableValue(Open(*data)));
    } else if (Session(*data) != session_) {
      result->Success(EncodableValue(false));
    } else if (call.method_name() == "update") {
      snapshot_[EncodableValue("sections")] = Read(*data, "sections");
      SendSnapshot();
      result->Success(EncodableValue(true));
    } else if (call.method_name() == "close") {
      Close(false, true);
      result->Success(EncodableValue(true));
    } else {
      result->NotImplemented();
    }
  });
}

PlayerMenuPopup::~PlayerMenuPopup() {
  host_channel_->SetMethodCallHandler(nullptr);
  Close(false, false);
  if (view_channel_) view_channel_->SetMethodCallHandler(nullptr);
  view_channel_.reset();
  controller_.reset();
  if (window_ && IsWindow(window_)) DestroyWindow(window_);
}

bool PlayerMenuPopup::Open(EncodableMap data) {
  const auto* x = std::get_if<double>(&Read(data, "x"));
  const auto* y = std::get_if<double>(&Read(data, "y"));
  if (!x || !y || !std::isfinite(*x) || !std::isfinite(*y) ||
      IsIconic(owner_) || IsZoomed(owner_)) return false;

  POINT anchor{std::lround(*x), std::lround(*y)};
  if (!ClientToScreen(player_view_, &anchor)) return false;
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfoW(MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST), &monitor)) {
    return false;
  }
  Close(true, false);
  if (!EnsureWindow(monitor.rcWork)) return false;
  data[EncodableValue("x")] = EncodableValue(static_cast<double>(anchor.x - monitor.rcWork.left));
  data[EncodableValue("y")] = EncodableValue(static_cast<double>(anchor.y - monitor.rcWork.top));
  session_ = Session(data);
  snapshot_ = std::move(data);
  SendSnapshot();
  return true;
}

bool PlayerMenuPopup::EnsureWindow(const RECT& work) {
  if (controller_) {
    return SetWindowPos(window_, nullptr, work.left, work.top, Width(work),
                        Height(work), SWP_NOZORDER | SWP_NOACTIVATE);
  }
  const HINSTANCE module = GetModuleHandleW(nullptr);
  WNDCLASSW wc{};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = module;
  wc.lpszClassName = kWindowClass;
  if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
  window_ = CreateWindowExW(WS_EX_TOOLWINDOW, kWindowClass, L"WebHTV Player Menu",
                            WS_POPUP, work.left, work.top, Width(work), Height(work),
                            owner_, nullptr, module, this);
  if (!window_) return false;
  webhtv::NativeTrace::Mark("player-menu-engine-start");
  controller_ = std::make_unique<flutter::FlutterViewController>(Width(work), Height(work), project_);
  webhtv::NativeTrace::Mark("player-menu-engine-created");
  if (!controller_->view() || !controller_->engine()) {
    controller_.reset();
    DestroyWindow(window_);
    return false;
  }
  const auto view = controller_->view()->GetNativeWindow();
  SetLastError(ERROR_SUCCESS);
  if (!SetParent(view, window_) && GetLastError() != ERROR_SUCCESS) {
    controller_.reset();
    DestroyWindow(window_);
    return false;
  }
  MoveWindow(view, 0, 0, Width(work), Height(work), FALSE);

  view_channel_ = MakeChannel(*controller_, "webhtv/player_menu_view");
  view_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "ready") {
      ready_ = true;
      SendSnapshot();
      result->Success();
      return;
    }
    const auto* data = std::get_if<EncodableMap>(call.arguments());
    if (!data || session_ == 0 || Session(*data) != session_) {
      result->Success();
      return;
    }
    if (call.method_name() == "layout") {
      const auto* rects = std::get_if<EncodableList>(&Read(*data, "rects"));
      if (rects) ApplyRegion(*rects);
    } else if (call.method_name() == "select") {
      NotifyPlayer("select", *data);
    } else if (call.method_name() == "dismiss") {
      Close(true, true);
    }
    result->Success();
  });
  return true;
}

void PlayerMenuPopup::SendSnapshot() {
  if (ready_ && session_ != 0) {
    view_channel_->InvokeMethod("snapshot", std::make_unique<EncodableValue>(snapshot_));
  }
}

void PlayerMenuPopup::ApplyRegion(const EncodableList& rects) {
  if (rects.empty()) return;
  const HRGN region = CreateRectRgn(0, 0, 0, 0);
  if (!region) return;
  for (const auto& item : rects) {
    const auto* rect = std::get_if<EncodableList>(&item);
    if (!rect || rect->size() != 4) continue;
    const HRGN part = CreateRectRgn(static_cast<int>(AsInt((*rect)[0])),
                                    static_cast<int>(AsInt((*rect)[1])),
                                    static_cast<int>(AsInt((*rect)[2])),
                                    static_cast<int>(AsInt((*rect)[3])));
    if (!part) continue;
    CombineRgn(region, region, part, RGN_OR);
    DeleteObject(part);
  }
  if (!SetWindowRgn(window_, region, TRUE)) {
    DeleteObject(region);
    return;
  }
  if (!visible_) {
    const HWND foreground = GetForegroundWindow();
    if (foreground != owner_ && foreground != window_) {
      Close(true, false);
      return;
    }
    visible_ = true;
    ShowWindow(window_, SW_SHOW);
    if (GetForegroundWindow() != window_) {
      Close(true, false);
      return;
    }
    SetFocus(controller_->view()->GetNativeWindow());
    NotifyPlayer("shown");
  }
}

void PlayerMenuPopup::NotifyPlayer(const char* method, EncodableMap data) {
  data[EncodableValue("session")] = EncodableValue(session_);
  host_channel_->InvokeMethod(method, std::make_unique<EncodableValue>(std::move(data)));
}

void PlayerMenuPopup::Close(bool notify, bool restore_focus) {
  if (session_ == 0) return;
  if (notify) NotifyPlayer("dismiss");
  session_ = 0;
  snapshot_.clear();
  if (std::exchange(visible_, false)) {
    const bool foreground = GetForegroundWindow() == window_;
    ShowWindow(window_, SW_HIDE);
    if (restore_focus && foreground) {
      SetForegroundWindow(owner_);
      SetFocus(player_view_);
    }
  }
}

LRESULT CALLBACK PlayerMenuPopup::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                         LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self = reinterpret_cast<PlayerMenuPopup*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) {
    if (message == WM_ACTIVATE && LOWORD(wparam) == WA_INACTIVE && self->visible_) {
      self->Close(true, false);
    } else if (message == WM_CLOSE) {
      self->Close(true, true);
      return 0;
    } else if (message == WM_NCDESTROY) {
      self->window_ = nullptr;
    }
    if (self->controller_) {
      if (const auto result = self->controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam)) {
        return *result;
      }
      if (message == WM_SIZE) {
        RECT rect{};
        GetClientRect(hwnd, &rect);
        MoveWindow(self->controller_->view()->GetNativeWindow(), 0, 0,
                   Width(rect), Height(rect), FALSE);
      }
    }
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
