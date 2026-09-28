#!/usr/bin/env python3
"""Phase 0 画面渲染证据采集。

启动 Flutter 原型 Release 程序加载指定媒体，截取主窗口，并统计视频区域像素分布，
用于证明"播放器已内嵌主窗口且真的渲染出画面"，而不只是控件存在于 widget 树。

用法：
    py tools/phase0/capture_render_evidence.py \
        --exe prototypes/flutter_media_kit/build/windows/x64/runner/Release/webhtv_phase0.exe \
        --media http://127.0.0.1:18080/media/sample.m3u8 \
        --header Referer:http://127.0.0.1:18080/ \
        --header User-Agent:WebHTV-PC-Phase0 \
        --output docs/phase0/evidence/flutter-header-hls.png
"""

from __future__ import annotations

import argparse
import ctypes
import json
import subprocess
import sys
import time
from pathlib import Path

import win32con
import win32gui
import win32process
from PIL import Image, ImageStat

ROOT = Path(__file__).resolve().parents[2]


def find_window(pid: int, timeout: float = 30.0) -> int:
    deadline = time.time() + timeout
    while time.time() < deadline:
        found: list[int] = []

        def callback(hwnd, _):
            _, window_pid = win32process.GetWindowThreadProcessId(hwnd)
            if window_pid == pid and win32gui.IsWindowVisible(hwnd):
                if win32gui.GetClientRect(hwnd)[2] > 200:
                    found.append(hwnd)

        win32gui.EnumWindows(callback, None)
        if found:
            return found[0]
        time.sleep(0.25)
    raise TimeoutError(f"在 {timeout} 秒内未找到进程 {pid} 的可见主窗口")


def capture(hwnd: int) -> Image.Image:
    """把窗口置于前台后从桌面 DC 抓取窗口矩形。

    Flutter Windows 使用 ANGLE/D3D 渲染，`PrintWindow` 往往只能拿到空白/黑屏，
    因此这里必须走真实的屏幕合成结果。
    """
    win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
    try:
        win32gui.SetForegroundWindow(hwnd)
    except Exception:
        # Windows 会限制非前台进程抢占焦点；借用输入线程的附加技巧绕过。
        foreground = win32gui.GetForegroundWindow()
        current = ctypes.windll.kernel32.GetCurrentThreadId()
        target_thread = win32process.GetWindowThreadProcessId(foreground)[0]
        ctypes.windll.user32.AttachThreadInput(current, target_thread, True)
        try:
            win32gui.BringWindowToTop(hwnd)
            win32gui.SetForegroundWindow(hwnd)
        finally:
            ctypes.windll.user32.AttachThreadInput(current, target_thread, False)
    time.sleep(1.0)

    left, top, right, bottom = win32gui.GetWindowRect(hwnd)
    width, height = right - left, bottom - top

    desktop_dc = win32gui.GetWindowDC(win32gui.GetDesktopWindow())
    mfc_dc = ctypes.windll.gdi32.CreateCompatibleDC(desktop_dc)
    bitmap = ctypes.windll.gdi32.CreateCompatibleBitmap(desktop_dc, width, height)
    ctypes.windll.gdi32.SelectObject(mfc_dc, bitmap)
    # SRCCOPY = 0x00CC0020, CAPTUREBLT = 0x40000000
    ctypes.windll.gdi32.BitBlt(mfc_dc, 0, 0, width, height, desktop_dc, left, top, 0x40CC0020)

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [
            ("biSize", ctypes.c_uint32),
            ("biWidth", ctypes.c_int32),
            ("biHeight", ctypes.c_int32),
            ("biPlanes", ctypes.c_uint16),
            ("biBitCount", ctypes.c_uint16),
            ("biCompression", ctypes.c_uint32),
            ("biSizeImage", ctypes.c_uint32),
            ("biXPelsPerMeter", ctypes.c_int32),
            ("biYPelsPerMeter", ctypes.c_int32),
            ("biClrUsed", ctypes.c_uint32),
            ("biClrImportant", ctypes.c_uint32),
        ]

    header = BITMAPINFOHEADER()
    header.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    header.biWidth = width
    header.biHeight = -height
    header.biPlanes = 1
    header.biBitCount = 32
    header.biCompression = 0
    buffer = ctypes.create_string_buffer(width * height * 4)
    ctypes.windll.gdi32.GetDIBits(mfc_dc, bitmap, 0, height, buffer, ctypes.byref(header), 0)

    image = Image.frombuffer("RGBA", (width, height), buffer, "raw", "BGRA", 0, 1).convert("RGB")

    ctypes.windll.gdi32.DeleteObject(bitmap)
    ctypes.windll.gdi32.DeleteDC(mfc_dc)
    win32gui.ReleaseDC(win32gui.GetDesktopWindow(), desktop_dc)
    return image


def video_region(image: Image.Image) -> Image.Image:
    """裁掉顶部标题栏与底部控制区，只保留中间的播放区域。"""
    width, height = image.size
    return image.crop((0, int(height * 0.12), width, int(height * 0.68)))


def describe(image: Image.Image) -> dict:
    region = video_region(image)
    gray = region.convert("L")
    stat = ImageStat.Stat(gray)
    colors = region.getcolors(maxcolors=1 << 24) or []
    non_black = sum(count for count, color in colors if sum(color) > 24)
    total = region.width * region.height
    return {
        "window_size": list(image.size),
        "video_region_size": list(region.size),
        "distinct_colors": len(colors),
        "non_black_ratio": round(non_black / total, 4),
        "mean_luma": round(stat.mean[0], 2),
        "extrema": list(gray.getextrema()),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True)
    parser.add_argument("--media", required=True)
    parser.add_argument("--header", action="append", default=[])
    parser.add_argument("--seek", type=float, default=None)
    parser.add_argument("--fullscreen", action="store_true")
    parser.add_argument("--output", required=True)
    parser.add_argument("--wait", type=float, default=8.0)
    parser.add_argument("--min-distinct-colors", type=int, default=16)
    parser.add_argument("--min-non-black-ratio", type=float, default=0.02)
    args = parser.parse_args()

    exe = Path(args.exe)
    if not exe.is_file():
        print(f"错误：可执行文件不存在：{exe}", file=sys.stderr)
        return 2

    command = [str(exe), f"--phase0-media={args.media}"]
    for header in args.header:
        command.append(f"--phase0-header={header}")
    if args.seek is not None:
        command.append(f"--phase0-seek={args.seek}")
    if args.fullscreen:
        command.append("--phase0-fullscreen=true")

    process = subprocess.Popen(command, cwd=exe.parent)
    try:
        hwnd = find_window(process.pid, timeout=30.0)
        time.sleep(args.wait)
        image = capture(hwnd)
        output = ROOT / args.output if not Path(args.output).is_absolute() else Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        image.save(output)
        facts = describe(image)
        facts["screenshot"] = str(output.relative_to(ROOT)).replace("\\", "/")
        facts["media"] = args.media
        facts["seek_seconds"] = args.seek
        facts["fullscreen"] = args.fullscreen
        print(json.dumps(facts, ensure_ascii=False, indent=2))

        if facts["distinct_colors"] < args.min_distinct_colors:
            print("渲染证据不足：颜色数过少，可能仍是黑屏", file=sys.stderr)
            return 1
        if facts["non_black_ratio"] < args.min_non_black_ratio:
            print("渲染证据不足：非黑像素比例过低，可能仍是黑屏", file=sys.stderr)
            return 1
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    raise SystemExit(main())
