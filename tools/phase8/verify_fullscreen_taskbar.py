"""Verify taskbar coverage and real foreground switching on Windows.

Run from the repository root with fixture_server running:
    python tools/phase8/verify_fullscreen_taskbar.py <release.exe>
Requires pywin32. Launches and closes only an isolated test player and test
foreground window, briefly changing the foreground like a real user switch.
Unlike the composition probe this never pre-promotes the player to topmost.
"""
import ctypes
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import win32con as c
import win32gui as g
import win32process

ROOT = Path(__file__).resolve().parents[2]
exe = Path(sys.argv[1]).resolve()
ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
spec = importlib.util.spec_from_file_location('helpers', ROOT/'tools/phase1/capture_windows_evidence.py')
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
user32 = ctypes.windll.user32


def topmost_order():
    order, hwnd = [], g.GetTopWindow(0)
    while hwnd:
        if g.IsWindowVisible(hwnd):
            order.append(hwnd)
        hwnd = g.GetWindow(hwnd, c.GW_HWNDNEXT)
    return order


def taskbar_above(taskbar, hwnd):
    order = topmost_order()
    if taskbar not in order or hwnd not in order:
        return None
    return order.index(taskbar) < order.index(hwnd)


def force_foreground(hwnd):
    fg = g.GetForegroundWindow()
    current = ctypes.windll.kernel32.GetCurrentThreadId()
    attached = False
    if fg:
        attached = bool(user32.AttachThreadInput(current, win32process.GetWindowThreadProcessId(fg)[0], True))
    try:
        user32.BringWindowToTop(hwnd)
        user32.SetForegroundWindow(hwnd)
        user32.SetActiveWindow(hwnd)
        user32.SetFocus(g.GetWindow(hwnd, c.GW_CHILD) or hwnd)
    finally:
        if attached:
            user32.AttachThreadInput(current, win32process.GetWindowThreadProcessId(fg)[0], False)
    end = time.monotonic()+1.0
    while time.monotonic() < end:
        g.PumpWaitingMessages()
        if g.GetForegroundWindow() == hwnd:
            return True
        time.sleep(.01)
    return False


def key(h, code):
    g.SendMessage(h, c.WM_SETFOCUS, 0, 0)
    scan = user32.MapVirtualKeyW(code, 0)
    lp = (scan << 16) | 1
    g.PostMessage(h, c.WM_KEYDOWN, code, lp)
    time.sleep(.02)
    g.PostMessage(h, c.WM_KEYUP, code, lp | 0xc0000000)


def wait_for(predicate, seconds=3.0):
    end = time.monotonic()+seconds
    while time.monotonic() < end:
        g.PumpWaitingMessages()
        if predicate():
            return True
        time.sleep(.01)
    return predicate()


with tempfile.TemporaryDirectory(prefix='webhtv-taskbar-', ignore_cleanup_errors=True) as tmp:
    ready = Path(tmp)/'ready.txt'
    proc = subprocess.Popen([str(exe), f'--screenshot-ready-file={ready}',
        '--media=http://127.0.0.1:18080/media/sample.mp4',
        '--header=Referer:http://127.0.0.1:18080/',
        '--header=User-Agent:WebHTV-PC/0.1 (Windows)'],
        cwd=exe.parent, env={**os.environ, 'APPDATA':tmp, 'LOCALAPPDATA':tmp,
        'TEMP':tmp, 'TMP':tmp}, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        hwnd = helpers.find_window(proc.pid, timeout=25)
        assert wait_for(lambda: ready.is_file(), 15), 'player not ready'
        child = g.GetWindow(hwnd, c.GW_CHILD)
        time.sleep(2.0)
        assert force_foreground(hwnd), 'could not activate the test window'
        key(child, c.VK_SPACE)
        time.sleep(.4)
        taskbar = g.FindWindow('Shell_TrayWnd', None)
        original = g.GetWindowRect(hwnd)
        failures = 0
        for attempt in range(4):
            assert force_foreground(hwnd), "test player must have real foreground focus"
            key(child, c.VK_F11)
            assert wait_for(lambda: g.GetWindowRect(hwnd) != original), 'did not enter fullscreen'
            samples = []
            start = time.perf_counter()
            while time.perf_counter()-start < 1.2:
                g.PumpWaitingMessages()
                samples.append((taskbar_above(taskbar, hwnd), g.GetForegroundWindow() == hwnd))
                time.sleep(.01)
            covered = [s for s in samples if s[0] is not False]
            assert all(s[1] for s in samples), "fullscreen player lost real foreground focus"
            print(f'enter {attempt} exstyle={hex(g.GetWindowLong(hwnd, c.GWL_EXSTYLE))} '
                  f'foreground={g.GetForegroundWindow()==hwnd} samples={len(samples)} taskbar_covered={len(covered)} '
                  f'covered_ratio={len(covered)/len(samples):.3f}', flush=True)
            failures += 1 if covered else 0
            other = g.CreateWindowEx(0, 'STATIC', 'WebHTV fullscreen focus check',
                c.WS_OVERLAPPEDWINDOW | c.WS_VISIBLE, 500, 250, 520, 240,
                0, 0, 0, None)
            try:
                assert force_foreground(other), 'test foreground switch failed'
                g.SendMessage(hwnd, c.WM_ACTIVATE, c.WA_INACTIVE, other)
                assert g.GetForegroundWindow()==other, 'late deactivation stole foreground focus'
                assert wait_for(lambda: (g.GetWindowLong(hwnd,c.GWL_EXSTYLE) & c.WS_EX_TOPMOST) == 0), 'inactive player remains topmost'
                order = topmost_order()
                assert order.index(other) < order.index(hwnd), 'player covers foreground app'
                print(f'switch {attempt} other_above_player=True inactive_topmost=False', flush=True)
                assert force_foreground(hwnd), 'could not return to player'
                assert wait_for(lambda: taskbar_above(taskbar, hwnd) is False), 'taskbar covers reactivated player'
            finally:
                g.DestroyWindow(other)
            assert force_foreground(hwnd), "test player must have real foreground focus"
            key(child, c.VK_ESCAPE)
            assert wait_for(lambda: g.GetWindowRect(hwnd) == original), 'did not restore'
            time.sleep(.4)
            assert not (g.GetWindowLong(hwnd,c.GWL_EXSTYLE) & c.WS_EX_TOPMOST), 'windowed player remains topmost'
        print(f'TASKBAR_FAILURES={failures}', flush=True)
        sys.exit(0 if failures == 0 else 1)
    finally:
        proc.terminate()
        proc.wait(timeout=10)
