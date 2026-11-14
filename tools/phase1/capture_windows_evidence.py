#!/usr/bin/env python3
"""Phase 1 Windows 运行证据采集。

启动 Release 产品程序，等待主窗口出现并可选地加载指定媒体，然后截取窗口并统计
像素分布，用于证明：

1. 主界面真的渲染出来（不是黑屏、不是只存在于 widget 树）；
2. 播放器内嵌在主窗口内并真的出画（`--media` 模式）；
3. 主界面可交互（`--ready-file` 标记文件由应用自身写出）。

用法：

    py tools/phase1/capture_windows_evidence.py \
        --exe apps/desktop-flutter/build/windows/x64/runner/Release/webhtv_pc.exe \
        --media http://127.0.0.1:18080/media/sample.m3u8 \
        --header "Referer:http://127.0.0.1:18080/" \
        --header "User-Agent:WebHTV-PC/0.1 (Windows)" \
        --output docs/phase1/evidence/windows-header-hls.png

不带 `--media` 时采集主界面截图（启动页 + 初次使用边界提示）。
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import win32con
import win32gui
import win32process
from PIL import Image, ImageStat

ROOT = Path(__file__).resolve().parents[2]


def _visible_windows_for_pid(pid: int, min_client_width: int = 300) -> list[int]:
    """收集属于指定进程、可见且客户区足够宽的顶层窗口。

    必须在循环外定义并显式返回列表：在循环体内定义闭包去 append 外部变量，
    闭包不会绑定该变量，既容易被误读也违反静态检查规则。
    """
    found: list[int] = []

    def callback(hwnd, _):
        _, window_pid = win32process.GetWindowThreadProcessId(hwnd)
        if (
            window_pid == pid
            and win32gui.IsWindowVisible(hwnd)
            and win32gui.GetClientRect(hwnd)[2] > min_client_width
        ):
            found.append(hwnd)

    win32gui.EnumWindows(callback, None)
    return found


def find_window(pid: int, timeout: float = 40.0) -> int:
    deadline = time.time() + timeout
    while time.time() < deadline:
        found = _visible_windows_for_pid(pid)
        if found:
            return found[0]
        time.sleep(0.25)
    raise TimeoutError(f"在 {timeout} 秒内未找到进程 {pid} 的可见主窗口")


class _BitmapInfoHeader(ctypes.Structure):
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


def _bitmap_to_image(
    device_context: int, bitmap: int, width: int, height: int
) -> Image.Image:
    """把 GDI 位图读出为 RGB 图像。"""
    header = _BitmapInfoHeader()
    header.biSize = ctypes.sizeof(_BitmapInfoHeader)
    header.biWidth = width
    header.biHeight = -height
    header.biPlanes = 1
    header.biBitCount = 32
    header.biCompression = 0
    buffer = ctypes.create_string_buffer(width * height * 4)
    ctypes.windll.gdi32.GetDIBits(
        device_context, bitmap, 0, height, buffer, ctypes.byref(header), 0
    )
    return Image.frombuffer(
        "RGBA", (width, height), buffer, "raw", "BGRA", 0, 1
    ).convert("RGB")


def _distinct_colors(image: Image.Image) -> int:
    return len(image.getcolors(maxcolors=1 << 24) or [])


def _print_window_image(hwnd: int, width: int, height: int) -> Image.Image:
    """`PrintWindow(PW_RENDERFULLCONTENT)`：抓窗口自身的合成结果。

    Flutter Windows 使用 ANGLE/D3D 渲染，只有 `PW_RENDERFULLCONTENT`(2) 才能拿到
    完整画面；它不要求窗口位于前台，因此不依赖 `SetForegroundWindow`。
    """
    window_dc = win32gui.GetWindowDC(hwnd)
    memory_dc = ctypes.windll.gdi32.CreateCompatibleDC(window_dc)
    bitmap = ctypes.windll.gdi32.CreateCompatibleBitmap(window_dc, width, height)
    ctypes.windll.gdi32.SelectObject(memory_dc, bitmap)
    ctypes.windll.user32.PrintWindow(hwnd, memory_dc, 2)
    image = _bitmap_to_image(memory_dc, bitmap, width, height)
    ctypes.windll.gdi32.DeleteObject(bitmap)
    ctypes.windll.gdi32.DeleteDC(memory_dc)
    win32gui.ReleaseDC(hwnd, window_dc)
    return image


def _desktop_copy_image(hwnd: int, width: int, height: int) -> Image.Image:
    """从桌面 DC 复制窗口矩形；只有窗口确实未被遮挡时结果才可信。"""
    left, top, _, _ = win32gui.GetWindowRect(hwnd)
    desktop_dc = win32gui.GetWindowDC(win32gui.GetDesktopWindow())
    memory_dc = ctypes.windll.gdi32.CreateCompatibleDC(desktop_dc)
    bitmap = ctypes.windll.gdi32.CreateCompatibleBitmap(desktop_dc, width, height)
    ctypes.windll.gdi32.SelectObject(memory_dc, bitmap)
    # SRCCOPY = 0x00CC0020, CAPTUREBLT = 0x40000000
    ctypes.windll.gdi32.BitBlt(
        memory_dc, 0, 0, width, height, desktop_dc, left, top, 0x40CC0020
    )
    image = _bitmap_to_image(memory_dc, bitmap, width, height)
    ctypes.windll.gdi32.DeleteObject(bitmap)
    ctypes.windll.gdi32.DeleteDC(memory_dc)
    win32gui.ReleaseDC(win32gui.GetDesktopWindow(), desktop_dc)
    return image


def capture(hwnd: int) -> tuple[Image.Image, str]:
    """抓取窗口渲染结果，返回 `(image, method)`。

    必须优先使用 `PrintWindow(PW_RENDERFULLCONTENT)`。早期版本先调用
    `SetForegroundWindow` 再走桌面 BitBlt，但普通用户进程在前台锁存在时会收到
    `error 5 拒绝访问`，整个证据采集直接抛异常失败。PrintWindow 抓窗口自身的合成
    结果，既不需要抢焦点，也不会因为窗口被遮挡而拍到别的窗口。
    """
    if win32gui.IsIconic(hwnd):
        win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
    time.sleep(1.2)

    left, top, right, bottom = win32gui.GetWindowRect(hwnd)
    width, height = right - left, bottom - top

    image = _print_window_image(hwnd, width, height)
    method = "print-window-render-full-content"
    if _distinct_colors(image) <= 1:
        fallback = _desktop_copy_image(hwnd, width, height)
        if _distinct_colors(fallback) > 1:
            image, method = fallback, "desktop-bitblt-fallback"
    return image, method


def describe(image: Image.Image, mode: str) -> dict:
    width, height = image.size
    if mode == "player":
        # 播放器页：去掉顶部标题栏与底部控制区。
        # 用整数除法而不是 int(height * 0.1)：尺寸本身就是整数，
        # 整数运算直接得到整数，无需任何转换或异常处理。
        top = height // 10
        bottom = height * 7 // 10
        region = image.crop((0, top, width, bottom))
    else:
        # 主界面：整窗统计，避免边界提示遮挡导致区域性误判。
        region = image
    gray = region.convert("L")
    stat = ImageStat.Stat(gray)
    colors = region.getcolors(maxcolors=1 << 24) or []
    non_black = sum(count for count, color in colors if sum(color) > 24)
    total = region.width * region.height
    return {
        "window_size": list(image.size),
        "sampled_region": list(region.size),
        "distinct_colors": len(colors),
        "non_black_ratio": round(non_black / total, 4),
        "mean_luma": round(stat.mean[0], 2),
        "extrema": list(gray.getextrema()),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True)
    parser.add_argument("--media", default=None)
    parser.add_argument("--header", action="append", default=[])
    parser.add_argument("--seek", type=float, default=None)
    parser.add_argument("--fullscreen", action="store_true")
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--wait",
        type=float,
        default=None,
        help="截图前等待秒数；默认播放模式 10s、主界面模式 6s",
    )
    parser.add_argument("--min-distinct-colors", type=int, default=16)
    parser.add_argument("--min-non-black-ratio", type=float, default=0.02)
    parser.add_argument(
        "--no-ready-file",
        action="store_true",
        help="不写 --screenshot-ready-file 标记（默认写入并校验应用已可交互）",
    )
    args = parser.parse_args()

    exe = Path(args.exe)
    if not exe.is_file():
        print(f"错误：可执行文件不存在：{exe}", file=sys.stderr)
        return 2

    mode = "player" if args.media else "shell"
    wait = args.wait if args.wait is not None else (10.0 if args.media else 6.0)

    ready_file: Path | None = None
    command = [str(exe)]
    if not args.no_ready_file:
        ready_file = (
            Path(tempfile.gettempdir())
            / f"webhtv-ready-{os.getpid()}-{time.time_ns()}.txt"
        )
        if ready_file.exists():
            ready_file.unlink()
        command.append(f"--screenshot-ready-file={ready_file}")
    if args.media:
        command.append(f"--media={args.media}")
    for header in args.header:
        command.append(f"--header={header}")
    if args.seek is not None:
        command.append(f"--seek={args.seek}")
    if args.fullscreen:
        command.append("--fullscreen=true")

    process = subprocess.Popen(command, cwd=exe.parent)
    facts: dict = {"mode": mode, "command_args": command[1:]}
    try:
        hwnd = find_window(process.pid, timeout=40.0)
        # 先等应用写出“可交互”标记，再额外等待渲染稳定。
        if ready_file is not None:
            deadline = time.time() + 30.0
            while time.time() < deadline and not ready_file.exists():
                time.sleep(0.2)
            facts["ready_file_written"] = ready_file.exists()
            if ready_file.exists():
                facts["ready_file_content"] = (
                    ready_file.read_text(encoding="utf-8", errors="replace").strip()
                )
        time.sleep(wait)

        image, capture_method = capture(hwnd)
        facts["capture_method"] = capture_method
        output = Path(args.output)
        if not output.is_absolute():
            output = ROOT / output
        output.parent.mkdir(parents=True, exist_ok=True)
        image.save(output)

        facts.update(describe(image, mode))
        try:
            facts["screenshot"] = str(output.relative_to(ROOT)).replace("\\", "/")
        except ValueError:
            facts["screenshot"] = str(output)
        facts["media"] = args.media
        facts["seek_seconds"] = args.seek
        facts["fullscreen"] = args.fullscreen
        facts["exit_code"] = process.poll()
        print(json.dumps(facts, ensure_ascii=False, indent=2))

        if facts["distinct_colors"] < args.min_distinct_colors:
            print("渲染证据不足：颜色数过少，可能仍是黑屏", file=sys.stderr)
            return 1
        if facts["non_black_ratio"] < args.min_non_black_ratio:
            print("渲染证据不足：非黑像素比例过低，可能仍是黑屏", file=sys.stderr)
            return 1
        if not facts.get("ready_file_written", True):
            print("应用未在 30 秒内写出可交互标记", file=sys.stderr)
            return 1
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
        if ready_file is not None and ready_file.exists():
            ready_file.unlink()


if __name__ == "__main__":
    raise SystemExit(main())
