# 证据 04 · 右键菜单

对应 `design/04-context-menu.md`。本文件记录**菜单截图（可拍到）**、
**位置 clamp 的边界值**与 **`Esc` 行为**。

---

## 1. 菜单必须"拍得到"——这是本子系统最容易做错的地方

`docs/phase8/evidence/screenshots/` 的 13 张截图由
`integration_test/phase8_visual_flow_test.dart` 采集。它的 `captureBytes` 取的是
**树中第一个 `RepaintBoundary`**（`Scaffold` 那一层）：

```dart
final captured = find.byType(RepaintBoundary).first;
```

**推论**：如果右键菜单被实现成 `Overlay` 浮层（`showMenu` / `MenuAnchor` 的做法），
它渲染在 `Navigator` 的 `Overlay` 里，**不在**那个 `RepaintBoundary` 之内 ——
截出来的图与"菜单关闭"态**逐字节相同**，是一张**假证据**。

仓库里已有同类记录：`integration_test/ui_redesign_visual_flow_test.dart:708-711`
（顶栏「更多」菜单）明确写着"这里**不截图**"，理由同上。

**因此 `design/04` §3 决定：菜单做成页内 `Stack` 层。**
这条决策直接决定了本轮能拿出可复核的菜单截图。

### 1.1 现行判据（确定性，不依赖像素）

```dart
final captured = find.byType(RepaintBoundary).first;
expect(
  find.descendant(of: captured, matching: find.byType(PlayerContextMenu)),
  findsOneWidget,
  reason: '右键菜单不在 harness 拍到的 `RepaintBoundary` 之内 → 截图拍不到它。'
          '检查它是否被实现成了 `Overlay` 浮层（`design/04` §3）。',
);
```

它恰好能区分「页内 `Stack` 层」与「`Overlay` 浮层」两种实现 ——
也就是 `design/04` §3 这个决策本身。

### 1.2 一条**已废弃**的旧判据（留痕）

brief 原定判据是"菜单打开与关闭的两张截图**字节不同**"。**它是假绿的**：

两个状态之间至少有两处像素必然变化 —— 屏显时钟每秒跳动、视频在播放。
**实测**：r2x1 档位在**菜单根本没打开**的情况下，两张截图仍差 5 字节
（`menuBytes=363046` vs `closedBytes=363041`），断言照样通过。

已删除，换成上面那条结构判据。

---

## 2. 位置 clamp 的边界值（实测）

菜单真实高度由内容决定（6 个分组、21 项），**远超**
`design/04` §5.2 的 `Size(240, 420)` 估算值。实测内部滚动量：

| 宽高比 | 视口 | `maxScrollExtent` | `viewportDimension` |
| --- | --- | --- | --- |
| r16x10（1440×900） | 900 | 148.0 | 784.0 |
| r2x1（1600×800） | 800 | 236.0 | 696.0 |
| r235x1（1880×800） | 800 | 236.0 | 696.0 |

菜单被 `maxHeight` 约束在窗口内、超出部分**内部滚动** —— 这正是 §5.2 设计的行为。

### 2.1 一个真实的 brief 缺陷：底部溢出

brief 的 `maxHeight = viewport.height - 16`，但左上角用 **420 的估算值** clamp，
而真实高度来自内容。**探针实测**（800×600 视口，锚点 `(400, 300)`，28 项内容）：

| 实现 | `rect.bottom` | 视口高度 |
| --- | --- | --- |
| brief 原稿 | **756** | 600 ← 溢出 156px |
| 修正后 | 592 | 600 |

**brief 自带的 9 个用例测不出来**：实现者把 brief 的代码与测试原样跑（9 绿），
再把溢出修好的变体跑同一组测试（**同样 9 绿**）。

修法：

```dart
maxHeight = math.max(0, viewport.height - origin.dy - _viewportMargin);

double _clampStart(double value, double maxStart) =>
    maxStart <= _viewportMargin ? _viewportMargin : value.clamp(_viewportMargin, maxStart);
```

`_clampStart` 的 `maxStart <= _viewportMargin` 分支是必需的：
裸 `clamp` 在 `max < min` 时**抛 `ArgumentError`**（实测 `5.0.clamp(10.0, 2.0)` 确实抛）。

### 2.2 锚点不能落在顶栏上（实测踩到）

顶栏现在是浮层里的 `AppBar`，它的 `Material` 会**吸收命中测试**，
所以 `y < kToolbarHeight` 的右键到不了第 1 层的 `GestureDetector` ——
**菜单根本不打开**。

实测：锚点取 `Offset(width * 0.05, height * 0.05)` 时菜单没开，
两张截图逐字节相同。改用 `Offset(width * 0.5, height * 0.12)`（避开顶栏与底部控制栏）。

---

## 3. `Esc` 行为

### 3.1 需求

`design/04` §5.3：菜单打开时 `Esc` **只关菜单**，不退出全屏。
`buildPlayerShortcuts`（`lib/ui/app.dart:1154`）已把 `Esc` 绑定到 `exitFullscreen`。

### 3.2 设计稿原先的机制描述是**错的**（已修正）

原稿说「用一个更高优先级的 `CallbackShortcuts` 包住菜单层……
**内层优先于外层**（`Focus` 树的就近原则）」。

**实测反证**：菜单打开时按 `Esc`，菜单**不关**、反而退出了全屏。
`test/phase8_player_page_overlay_test.dart` 报：

```
Expected: no matching candidates
  Actual: Found 1 widget with type "PlayerContextMenu"
```

**SDK 层面的原因**（两处，都已核对源码）：

1. **键盘事件从主焦点节点沿祖先向上冒泡**。
   `flutter/lib/src/widgets/focus_manager.dart:2276-2280`：

   ```dart
   for (final node in <FocusNode>[
     FocusManager.instance.primaryFocus!,
     ...FocusManager.instance.primaryFocus!.ancestors,
   ]) {
   ```

   而嵌套的那个 `CallbackShortcuts` 是主焦点的**后代**，根本不在冒泡路径上。
   `CallbackShortcuts.build`（`shortcuts.dart:1222`）返回的是
   `Focus(canRequestFocus: false, skipTraversal: true, ...)` ——
   它**永远不可能**成为主焦点。

2. **`Focus(autofocus:)` 不可靠**：只在 `_FocusState.initState` 里生效
   （`focus_scope.dart:625-628` 的 `_handleAutofocus` 要求 `!widget._didAutofocus`），
   而这里 widget 一直在树里、只是 `autofocus` 属性翻转，走不到那条分支。

### 3.3 现行修法：在**同一张表**里改

```dart
if (_contextMenuAnchor != null) {
  shortcuts.removeWhere(
    (activator, _) =>
        activator is SingleActivator &&
        activator.trigger == LogicalKeyboardKey.escape,
  );
  shortcuts[const SingleActivator(LogicalKeyboardKey.escape)] = _closeContextMenu;
}
```

为什么是 `removeWhere` 再插，而不是直接覆盖：`SingleActivator`
**没有重写 `==`/`hashCode`**（扫过 `shortcuts.dart:433-681` 全类，零命中），
直接覆盖能否命中取决于 `const` 规范化这个实现细节；
而 `CallbackShortcuts` 取**首个**命中的绑定，漏掉旧绑定就会让
`exitFullscreen` 继续赢。

（实测补充：Dart 跨库 `const` 规范化确实让两处的 `SingleActivator` 是**同一个对象**，
所以直接覆盖**会**生效。但仍选 `removeWhere` —— 依赖实现细节不如显式筛掉。）

### 3.4 用例有牙（变异验证）

原始用例只断言"菜单关了"。一个**既关菜单又退出全屏**的实现照样通过 ——
而用例标题写的正是「只关菜单，**不退出全屏**」。

现行用例加了两条反向断言，用 `window_manager` MethodChannel 的调用记录观测：

```dart
expect(find.byType(PlayerContextMenu), findsNothing, reason: 'Esc 必须关掉菜单');
expect(windowManagerCalls.where((c) => c.method == 'isFullScreen'), isEmpty,
    reason: 'Esc 不得触达全屏逻辑（否则菜单打开时按 Esc 会顺带退出全屏）');
expect(windowManagerCalls.where((c) => c.method == 'setFullScreen'), isEmpty,
    reason: 'Esc 不得真的切换全屏');
```

**变异验证**：把绑定换成

```dart
shortcuts[const SingleActivator(LogicalKeyboardKey.escape)] = () {
  _closeContextMenu();
  _exitFullscreen();
};
```

→ 用例**失败在新断言**（`isFullScreen` 那条），而旧的"菜单关了"断言**通过**。
这证明新断言抓到了旧断言抓不到的东西。

---

## 4. 菜单的六组内容

`lib/ui/player_page.dart` 的 `_contextMenuSections()`：

| 组 | 项 |
| --- | --- |
| 播放 | 播放/暂停、上一集、下一集、后退 10 秒、前进 10 秒 |
| 速度 | 0.5× / 0.75× / 1.0× / 1.25× / 1.5× / 2.0×（当前值带勾选） |
| 画面 | 画面比例与缩放（子菜单：5 种 `PlayerVideoFitMode`）、全屏 |
| 轨道 | 字幕轨、弹幕开关、弹幕设置 |
| 显示 | 屏显（子菜单：7 项开关）、控制栏按钮… |
| 信息 | 媒体信息、播放诊断、快捷键说明 |

**每一项都有非右键的等价路径**（`design/00` §5 第 10 条）：
顶栏「更多」菜单、控制栏按钮或快捷键。右键菜单**不是唯一入口**。

**屏显子菜单里 `traffic` 当时置灰**（`enabled: id != OsdFlag.traffic`），
标签写「网速（未采集）」—— 见 `evidence/05-differences.md` 第 2 条。

> **更正（后续变化）**：现在 7 项**全部可点**、标签统一为「网速」
> （`player_page.dart` 的 `for (final id in OsdFlag.values)` 直接建项，
> 没有 `enabled` 特判；中文名由 `_osdLabelOf` 给出，`traffic` → 「网速」）。
> 原因见 `evidence/05-differences.md` 第 2 条的「更正 2」。

## 5. 一级子菜单的构造期拒绝

`design/04` §4.1 规定**只支持一级子菜单**。原实现画了展开箭头但只渲染顶层项的子项，
于是二级项点了没反应（探针实测 `grandchild=0, expandMore=0, expandLess=2`——
箭头翻转了，界面什么都不显示）。

现行实现在构造期拒绝：

```dart
assert(child.children.isEmpty, '右键菜单只支持一级子菜单：项 "${child.id}" 自己还有 children（design/04 §4.1）');
```

**变异验证**：删掉这条 assert，新用例变红。

## 6. 截图清单

| 文件 | 内容 |
| --- | --- |
| `player-menu-r16x10.png` / `-r2x1.png` / `-r235x1.png` | 菜单打开（可见前 5 组） |
| `player-menu-bottom-r16x10.png` / `-r2x1.png` / `-r235x1.png` | 菜单滚到底（可见全部 6 组标题） |

逐字节校验：`docs/phase8/evidence/screenshots/manifest.txt` +
`tools/phase8/verify_screenshots.py`（G8）。
