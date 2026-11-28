#ifndef RUNNER_PLAYER_MENU_POPUP_H_
#define RUNNER_PLAYER_MENU_POPUP_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <cstdint>
#include <memory>

// The owned window only paints and receives input in the visible menu columns.
class PlayerMenuPopup {
 public:
  PlayerMenuPopup(HWND owner, flutter::FlutterViewController& player,
                  const flutter::DartProject& project);
  ~PlayerMenuPopup();

  bool visible() const { return visible_; }

 private:
  bool Open(flutter::EncodableMap data);
  bool EnsureWindow(const RECT& work_area);
  void SendSnapshot();
  void ApplyRegion(const flutter::EncodableList& rects);
  void NotifyPlayer(const char* method, flutter::EncodableMap data = {});
  void Close(bool notify, bool restore_focus);
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam);

  HWND owner_;
  HWND player_view_;
  HWND window_ = nullptr;
  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> host_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> view_channel_;
  flutter::EncodableMap snapshot_;
  int64_t session_ = 0;
  bool ready_ = false;
  bool visible_ = false;
};

#endif  // RUNNER_PLAYER_MENU_POPUP_H_
