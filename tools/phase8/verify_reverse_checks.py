#!/usr/bin/env python3
"""Phase 8 反向验证（G5）：10 项破坏必须按预期失败，还原后工作区干净。

机制沿用 Phase 4–7：每项做一次「破坏 → 跑指定套件 → 必须失败 → 还原」。
还原用内存里的原文回写，并在每项之后断言工作区干净。

**锚点全部取自 Task 11 落地后的真实源码**（`docs/phase8/plans/01-player-overlay.md`
里的初版锚点是按计划稿写的，落地后多处已变；见下方每项的注释）。

退出码：0 = 全部按预期失败且还原干净；1 = 有项未按预期失败。

用法：
    py -3 tools/phase8/verify_reverse_checks.py
    py -3 tools/phase8/verify_reverse_checks.py --only 1,7
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "desktop-flutter"

# (编号, 说明, 文件, 查找串, 替换串, 必须失败的套件)
CHECKS: list[tuple[str, str, str, str, str, str]] = [
    (
        "1",
        "视频区重新依赖控制栏可见性（原始 bug 形状）",
        "lib/ui/player_page.dart",
        # 原计划稿写的是「把浮层放回 Column 兄弟节点」，落地后 `body` 已整体
        # 变成 `Theme(...)`，直接替换 `body: Theme(` 无法表达该破坏。
        # 这里改成**产生同样可观测后果**的最小破坏：让第 1 层（画面）的
        # `Positioned.fill` 变成底边随 `_controlsVisible` 收缩——这正是
        # 用户投诉的「唤醒控制台导致画面缩放」的几何本质。
        "                    // 第 1 层：画面 + 弹幕 + 加载/错误。\n"
        "                    Positioned.fill(\n",
        "                    // 第 1 层：画面 + 弹幕 + 加载/错误。\n"
        "                    Positioned(\n"
        "                      left: 0,\n"
        "                      top: 0,\n"
        "                      right: 0,\n"
        "                      bottom: _controlsVisible ? 92 : 0,\n",
        "integration_test/phase8_overlay_flow_test.dart",
    ),
    (
        "2",
        "去掉隐藏态的 IgnorePointer",
        "lib/ui/player_page.dart",
        "ignoring: !_controlsVisible,",
        "ignoring: false,",
        "test/phase8_player_page_overlay_test.dart",
    ),
    (
        "3",
        "屏显层去掉 IgnorePointer",
        "lib/ui/player_osd.dart",
        # 计划稿写的是 `child: Padding(`，实际 `IgnorePointer` 与 `Padding`
        # 之间还隔着一层 `Stack`（`player_osd.dart:139-142`）。
        # 直接删 `IgnorePointer(` 会让括号失衡，所以改成把 `ignoring` 显式
        # 置 false（默认值是 true，于是效果等同于去掉这层）。
        "    return IgnorePointer(\n      child: Stack(\n",
        "    return IgnorePointer(\n      ignoring: false,\n      child: Stack(\n",
        "test/phase8_osd_layer_test.dart",
    ),
    (
        "4",
        "顺序归一化不再补全缺失项",
        "lib/core/player_buttons.dart",
        "  for (final spec in kPlayerButtons) {\n"
        "    if (seen.add(spec.id)) result.add(spec.id);\n"
        "  }\n"
        "  return result;",
        "  return result;",
        "test/phase8_player_buttons_test.dart",
    ),
    (
        "5",
        "屏显默认值把 title 改为 false",
        "lib/core/osd_config.dart",
        "OsdFlag.title: true,",
        "OsdFlag.title: false,",
        "test/phase8_osd_config_test.dart",
    ),
    (
        "6",
        "屏显全关时不停 Timer",
        "lib/ui/player_page.dart",
        "bool get _osdNeedsTicker =>",
        "bool get _osdNeedsTicker => true ||",
        "test/phase8_player_page_overlay_test.dart",
    ),
    (
        "7",
        "右键菜单改用 Navigator 的 Overlay（等价于 showMenu）",
        "lib/ui/player_page.dart",
        # 计划稿的 find/replace 是同一串（未实现）。这里用真实做法：
        # 把页内 Stack 里的菜单改成插进 `Overlay`——`showMenu` /
        # `MenuAnchor` 就是这么干的，菜单于是落在 `Scaffold` 子树之外。
        "                      PlayerContextMenu(\n"
        "                        anchor: _contextMenuAnchor!,\n"
        "                        viewport: MediaQuery.sizeOf(context),\n"
        "                        sections: _contextMenuSections(),\n"
        "                        onDismiss: _closeContextMenu,\n"
        "                      ),\n",
        "                      Positioned.fill(\n"
        "                        child: Builder(\n"
        "                          builder: (inner) {\n"
        "                            WidgetsBinding.instance.addPostFrameCallback((_) {\n"
        "                              Overlay.maybeOf(inner)?.insert(\n"
        "                                OverlayEntry(\n"
        "                                  builder: (_) => PlayerContextMenu(\n"
        "                                    anchor: _contextMenuAnchor!,\n"
        "                                    viewport: MediaQuery.sizeOf(inner),\n"
        "                                    sections: _contextMenuSections(),\n"
        "                                    onDismiss: _closeContextMenu,\n"
        "                                  ),\n"
        "                                ),\n"
        "                              );\n"
        "                            });\n"
        "                            return const SizedBox.shrink();\n"
        "                          },\n"
        "                        ),\n"
        "                      ),\n",
        "integration_test/phase8_visual_flow_test.dart",
    ),
    (
        "8",
        "Esc 在菜单打开时仍绑到 exitFullscreen",
        "lib/ui/player_page.dart",
        # 计划稿假设 Esc 覆盖写在 `CallbackShortcuts` 的 bindings 字面量里
        # （`const SingleActivator(...): _closeContextMenu,`）。落地时发现
        # 「内层 CallbackShortcuts 优先」是错的（键盘事件沿祖先冒泡），
        # 改成在同一张表里 `removeWhere` 再插入，锚点随之改变。
        "    if (_contextMenuAnchor != null) {\n"
        "      shortcuts.removeWhere(\n"
        "        (activator, _) =>\n"
        "            activator is SingleActivator &&\n"
        "            activator.trigger == LogicalKeyboardKey.escape,\n"
        "      );\n"
        "      shortcuts[const SingleActivator(LogicalKeyboardKey.escape)] =\n"
        "          _closeContextMenu;\n"
        "    }\n",
        "",
        "test/phase8_player_page_overlay_test.dart",
    ),
    (
        "9",
        "把 subtitle/danmaku 加入可配置集合",
        "lib/core/player_buttons.dart",
        "const List<PlayerButtonSpec> kPlayerButtons = [",
        "const List<PlayerButtonSpec> kPlayerButtons = [\n"
        "  PlayerButtonSpec(id: 'subtitle', label: '字幕轨',"
        " group: PlayerButtonGroup.track),",
        "test/phase8_player_buttons_test.dart",
    ),
    (
        "10",
        "控制栏改回 Wrap（窄窗口换行）",
        "lib/ui/player_overlay.dart",
        "    return SingleChildScrollView(\n"
        "      scrollDirection: Axis.horizontal,",
        "    return Wrap(\n"
        "      direction: Axis.horizontal,",
        "test/phase8_player_page_overlay_test.dart",
    ),
]


def run_suite(relative: str) -> int:
    args = ["puro", "-e", "webhtv", "-p", ".", "flutter", "test", relative]
    if relative.startswith("integration_test/"):
        args += ["-d", "windows"]
    result = subprocess.run(args, cwd=APP, capture_output=True, text=True)
    return result.returncode


def file_restored(path: Path) -> bool:
    """还原后**该文件**必须与 HEAD 逐字节一致。

    **不能要求整个工作区干净**：`docs/phase8/` 与 `tools/phase8/` 是本轮
    的交付物，在 Task 15 之前一直是未跟踪状态；要求 `git status --porcelain`
    为空会让 G5 永远失败（实测踩到过）。这里只断言被破坏的那个文件。
    """
    result = subprocess.run(
        ["git", "diff", "--quiet", "--", str(path.relative_to(ROOT))],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default="", help="只跑指定编号（逗号分隔）")
    options = parser.parse_args()
    wanted = {item for item in options.only.split(",") if item}

    failures: list[str] = []
    ran = 0
    for number, title, relative, find, replace, suite in CHECKS:
        if wanted and number not in wanted:
            continue
        path = APP / relative
        if not path.exists():
            failures.append(f"#{number} {title}: 文件不存在 {relative}")
            continue
        original = path.read_text(encoding="utf-8")
        if find not in original:
            failures.append(
                f"#{number} {title}: 未找到锚点（源码可能已变），跳过"
            )
            continue
        if find == replace:
            failures.append(f"#{number} {title}: 该检查尚未实现自动化破坏")
            continue
        ran += 1
        try:
            path.write_text(original.replace(find, replace, 1), encoding="utf-8")
            code = run_suite(suite)
            if code == 0:
                failures.append(
                    f"#{number} {title}: 破坏后套件仍通过（未按预期失败）"
                )
            else:
                print(f"PHASE8-REVERSE #{number} ok（按预期失败）")
        finally:
            path.write_text(original, encoding="utf-8")
        if not file_restored(path):
            failures.append(f"#{number} {title}: 还原后 {relative} 与 HEAD 不一致")

    if failures:
        print("PHASE8-REVERSE result=FAIL")
        for item in failures:
            print(f"  - {item}")
        return 1
    print(f"PHASE8-REVERSE result=PASS checks={ran}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
