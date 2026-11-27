"""Verify actual Windows fullscreen frames using an isolated fixture player.

Requirements: Python numpy, opencv-python, pywin32, windows-capture==1.5.0.
Start tools/fixture_server/server.py first. Example from the repository root:
  python tools/phase8/verify_fullscreen_composition.py <release.exe> <evidence-dir> \
      --rounds 12 --monitor --assert-clean

Monitor mode briefly brings an isolated test window to the foreground.
It does not drive or stop any existing application window.
"""
import argparse
import ctypes
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import time

import cv2
import numpy as np
import win32con as c
import win32gui as g
import win32process
from windows_capture import WindowsCapture

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('exe', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--rounds', type=int, default=8)
parser.add_argument('--maximize', action='store_true')
parser.add_argument('--assert-clean', action='store_true')
parser.add_argument('--monitor', action='store_true')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
exe = args.exe.resolve()
ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
spec = importlib.util.spec_from_file_location('capture_helpers', ROOT/'tools/phase1/capture_windows_evidence.py')
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)


def force_foreground(hwnd):
    fg = g.GetForegroundWindow()
    current = ctypes.windll.kernel32.GetCurrentThreadId()
    attached = False
    if fg:
        attached = bool(ctypes.windll.user32.AttachThreadInput(current, win32process.GetWindowThreadProcessId(fg)[0], True))
    try:
        ctypes.windll.user32.BringWindowToTop(hwnd)
        ctypes.windll.user32.SetForegroundWindow(hwnd)
        ctypes.windll.user32.SetActiveWindow(hwnd)
        ctypes.windll.user32.SetFocus(g.GetWindow(hwnd, c.GW_CHILD) or hwnd)
    finally:
        if attached:
            ctypes.windll.user32.AttachThreadInput(current, win32process.GetWindowThreadProcessId(fg)[0], False)
    end = time.monotonic()+1.0
    while time.monotonic() < end:
        g.PumpWaitingMessages()
        if g.GetForegroundWindow() == hwnd:
            return True
        time.sleep(.01)
    return False


def key(h, code):
    g.SendMessage(h, c.WM_SETFOCUS, 0, 0)
    scan = ctypes.windll.user32.MapVirtualKeyW(code, 0)
    lp = (scan << 16) | 1
    g.PostMessage(h, c.WM_KEYDOWN, code, lp)
    time.sleep(.02)
    g.PostMessage(h, c.WM_KEYUP, code, lp | 0xc0000000)


def size(r):
    return r[2] - r[0], r[3] - r[1]


def video_width_ratio(img):
    span = []
    for y in (0.39, 0.44, 0.49, 0.54, 0.59):
        row = img[int(img.shape[0]*y),:,:3].astype(np.int16)
        ix = np.flatnonzero((row.max(1)-row.min(1) > 92) & (row.max(1) > 130))
        span.append((1+ix[-1]-ix[0])/row.shape[0] if ix.size else 0)
    return float(np.median(span))


with tempfile.TemporaryDirectory(prefix='webhtv-composition-', ignore_cleanup_errors=True) as tmp:
    ready = Path(tmp)/'ready.txt'
    cmd = [str(exe), f'--screenshot-ready-file={ready}', '--media=http://127.0.0.1:18080/media/sample.mp4',
           '--header=Referer:http://127.0.0.1:18080/', '--header=User-Agent:WebHTV-PC/0.1 (Windows)']
    proc = subprocess.Popen(cmd, cwd=exe.parent, env={**os.environ, 'APPDATA':tmp,'LOCALAPPDATA':tmp,'TEMP':tmp,'TMP':tmp},
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ctl = None
    try:
        hwnd = helpers.find_window(proc.pid, timeout=20)
        end = time.monotonic()+15
        while not ready.is_file() and time.monotonic() < end:
            time.sleep(.05)
        if not ready.is_file():
            raise RuntimeError('player not ready')
        child = g.GetWindow(hwnd, c.GW_CHILD)
        time.sleep(2.0)
        key(child, c.VK_SPACE)
        if args.monitor:
            g.SetWindowPos(hwnd, c.HWND_TOP, 640, 116, 1280, 800, c.SWP_NOACTIVATE)
            assert force_foreground(hwnd), "test window must be the real foreground"
        if args.maximize:
            g.PostMessage(hwnd, c.WM_SYSCOMMAND, c.SC_MAXIMIZE, 0)
            deadline = time.monotonic()+3
            while not ctypes.windll.user32.IsZoomed(hwnd) and time.monotonic() < deadline:
                time.sleep(.01)
            assert ctypes.windll.user32.IsZoomed(hwnd), 'test window did not maximize'
        time.sleep(.2)
        name = f'WebHTV Fullscreen Frame Probe {proc.pid}'
        g.SendMessage(hwnd, c.WM_SETTEXT, 0, name)
        assert g.GetWindowText(hwnd) == name, 'probe window name not set'
        recorder = WindowsCapture(cursor_capture=False, draw_border=False, **({"monitor_index":1} if args.monitor else {"window_name":name}))
        seq, collecting, stamps = [], False, []

        @recorder.event
        def on_frame_arrived(frame, capture_control):
            if not collecting:
                return
            stamp = time.perf_counter()
            mat = frame.frame_buffer[:frame.height,:frame.width,:3]
            if mat.size == 0:
                return
            thumb = cv2.resize(mat, (max(1, frame.width//3), max(1, frame.height//3)), interpolation=cv2.INTER_AREA)
            seq.append((stamp, frame.timespan, frame.width, frame.height, video_width_ratio(thumb), thumb))

        @recorder.event
        def on_closed():
            pass

        ctl = recorder.start_free_threaded()
        collecting = True
        before = g.GetWindowRect(hwnd)
        deadline = time.monotonic()+3
        while (not seq or seq[-1][4] <= .2) and time.monotonic() < deadline:
            time.sleep(.02)
        assert seq, 'WGC did not produce frames'
        first = seq[-1]
        if first[4] <= .2:
            cv2.imwrite(str(args.output/"capture-not-visible.png"), first[5])
        assert first[4] > .2, "The test video is not visible in the selected capture"
        print(f'windowed={before} captured={first[2:4]} videoWidth={first[4]:.3f}', flush=True)
        for r in range(args.rounds):
            for label, vk in [('enter',c.VK_F11),('exit',c.VK_ESCAPE)]:
                t0 = time.perf_counter()
                n0 = len(seq)
                assert force_foreground(hwnd), "test window lost foreground"
                key(child, vk)
                deadline = time.monotonic()+2
                while (g.GetWindowRect(hwnd) != before) != (label == 'enter') and time.monotonic() < deadline:
                    time.sleep(.01)
                time.sleep(.50)
                rect = g.GetWindowRect(hwnd)
                assert (rect != before) == (label == 'enter'), (label, rect, before)
                displayed = seq[n0:]
                assert displayed, 'no new frames'
                stamps.append((r,label,t0,n0,len(seq),size(rect)))
                print(f'{r} {label} target={size(rect)} ' + ', '.join(f'{(f[0]-t0)*1000:.1f}ms:{f[2]}x{f[3]}:{f[4]:.3f}' for f in displayed[:10]), flush=True)
            time.sleep(.06)
        collecting = False
        nbad = 0
        wrong_sizes = 0
        cv2.imwrite(str(args.output/'windowed.png'), first[5])
        fullscreen_ratio = next(seq[j-1][4] for _,label,_,_,j,_ in stamps if label == "enter")
        for r,label,t0,i,j,target in stamps:
            settled = seq[j-1]
            previous_ratio = first[4] if label == "enter" else fullscreen_ratio
            if r == 0:
                cv2.imwrite(str(args.output/f'settled-{label}.png'), settled[5])
            for k, f in enumerate(seq[i:j]):
                if not args.monitor and f[2:4] == seq[i-1][2:4]:
                    continue
                if args.monitor and min(abs(f[4]-settled[4]),abs(f[4]-previous_ratio)) <= .055:
                    continue
                if f[2:4] != settled[2:4]:
                    wrong_sizes += 1
                if f[2:4] != settled[2:4] or abs(f[4]-settled[4]) > .055:
                    if nbad < 12:
                        cv2.imwrite(str(args.output/f'mixed-{r}-{label}-{k}.png'), f[5])
                    nbad += 1
        print(f'DISPLAYED_MISMATCHES={nbad} SIZE_MISMATCHES={wrong_sizes} TRANSITIONS={len(stamps)}', flush=True)
        if args.assert_clean:
            assert nbad == 0, f'{nbad} composed frames retained the old window'
    finally:
        if ctl is not None:
            ctl.stop()
        proc.terminate()
        proc.wait(timeout=10)
