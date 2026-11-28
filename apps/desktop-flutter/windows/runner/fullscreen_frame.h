#ifndef RUNNER_FULLSCREEN_FRAME_H_
#define RUNNER_FULLSCREEN_FRAME_H_

#include <windows.h>

class FullscreenFrame {
 public:
  ~FullscreenFrame();
  bool Begin(HWND window);
  void End();
  bool active() const { return window_ != nullptr; }

 private:
  HWND window_ = nullptr;
  HWND cover_ = nullptr;
  HBITMAP bitmap_ = nullptr;
};

#endif
