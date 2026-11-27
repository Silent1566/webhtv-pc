#include "fullscreen_frame.h"

#include <dwmapi.h>

FullscreenFrame::~FullscreenFrame() { End(); }

bool FullscreenFrame::Begin(HWND window) {
  if (active())
    return true;
  if (!IsWindowVisible(window) || IsIconic(window))
    return false;

  RECT bounds{};
  if (!GetWindowRect(window, &bounds))
    return false;
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  if (width <= 0 || height <= 0)
    return false;

  DWORD cloaked = 0;
  if (SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked,
      sizeof(cloaked))) && cloaked != 0)
    return false;

  HDC source = GetWindowDC(window);
  if (!source)
    return false;
  HDC memory = CreateCompatibleDC(source);
  bitmap_ = CreateCompatibleBitmap(source, width, height);
  if (!memory || !bitmap_) {
    if (memory) DeleteDC(memory);
    ReleaseDC(window, source);
    End();
    return false;
  }
  HGDIOBJ previous = SelectObject(memory, bitmap_);
  const bool captured = previous && previous != HGDI_ERROR &&
                        PrintWindow(window, memory, 2) != FALSE;
  SelectObject(memory, previous);
  DeleteDC(memory);
  ReleaseDC(window, source);
  if (!captured) {
    End();
    return false;
  }

  // An independent, non-activating popup remains visible when the real window
  // is cloaked. It contains only this window's last complete frame.
  cover_ = CreateWindowEx(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"STATIC", L"",
      WS_POPUP | WS_DISABLED | SS_BITMAP, bounds.left, bounds.top, width, height,
      nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
  if (!cover_) {
    End();
    return false;
  }
  SendMessage(cover_, STM_SETIMAGE, IMAGE_BITMAP,
              reinterpret_cast<LPARAM>(bitmap_));
  const bool topmost = (GetWindowLongPtr(window, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
  const HWND above = GetWindow(window, GW_HWNDPREV);
  if (!SetWindowPos(cover_, topmost ? HWND_TOPMOST : (above ? above : HWND_TOP),
      bounds.left, bounds.top, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW)) {
    End();
    return false;
  }
  UpdateWindow(cover_);
  DwmFlush();
  const BOOL cloak = TRUE;
  if (FAILED(DwmSetWindowAttribute(window, DWMWA_CLOAK, &cloak, sizeof(cloak)))) {
    End();
    return false;
  }
  window_ = window;
  return true;
}

void FullscreenFrame::End() {
  if (window_ && IsWindow(window_)) {
    const BOOL cloak = FALSE;
    DwmSetWindowAttribute(window_, DWMWA_CLOAK, &cloak, sizeof(cloak));
    DwmFlush();
  }
  window_ = nullptr;
  if (cover_) {
    DestroyWindow(cover_);
    cover_ = nullptr;
  }
  if (bitmap_) {
    DeleteObject(bitmap_);
    bitmap_ = nullptr;
  }
}
