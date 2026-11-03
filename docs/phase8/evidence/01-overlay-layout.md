# 证据 01 · 浮层布局与几何不变式

对应 `design/01-overlay-layout.md` §5。本文件记录**实测数值**，不是设计意图。

---

## 1. 用户投诉的根因（改造前）

用户原话（`docs/phase8/README.md` §2）：

> 现在每次唤醒控制台都会导致画面缩放（应该是被上下的控制栏挤占了位置）

改造前 `lib/ui/player_page.dart:1400-1473` 的结构：

```dart
body: Column(
  children: [
    Expanded(child: GestureDetector(... child: Video(...))),   // 画面
    if (_controlsVisible) Listener(child: _ControlBar(...)),   // 控制条：Column 的兄弟节点
  ],
)
```

控制条一出现，`Expanded` 分给画面的高度就少一截，`Video` 的 `BoxFit.contain`
按新的框重新算缩放与居中 —— 这就是"画面缩放"。

对照上游 Android（`F:\Workspace\webtv4\webhtv`）的 `activity_video.xml:30-98`：
`control` 与 `osd` 都是视频 `FrameLayout` 的 `match_parent` 兄弟，**不占布局**。

---

## 2. 改造后的结构

`lib/ui/player_page.dart:1356-1475`：

```dart
Scaffold(
  appBar: null,                                   // 顶栏移进浮层，全屏切换不再跳 56px
  body: Theme(
    data: buildAppTheme(Brightness.dark),
    child: Stack(
      children: [
        Positioned.fill(child: GestureDetector(... Video ...)),   // 第 1 层：画面
        Positioned.fill(child: PlayerOsdLayer(...)),              // 第 2 层：屏显（自带 IgnorePointer）
        Positioned.fill(child: IgnorePointer(                     // 第 3 层：控制浮层
          ignoring: !_controlsVisible,
          child: AnimatedOpacity(... child: PlayerControlOverlay(...)),
        )),
        if (_contextMenuAnchor != null) ...[                     // 第 4 层：右键菜单
          Positioned.fill(child: GestureDetector(onTap: _closeContextMenu)),
          PlayerContextMenu(...),
        ],
      ],
    ),
  ),
)
```

四层全是 `Stack` 的 `Positioned` 子项，与画面**平级**，不参与布局。

---

## 3. V1 实测：控制栏显隐前后视频区矩形逐像素相同

套件：`integration_test/phase8_overlay_flow_test.dart`（V1）
命令：`puro -e webhtv -p . flutter test integration_test/phase8_overlay_flow_test.dart -d windows`
视口：1440×900，`devicePixelRatio = 1.0`

原始输出（`docs/phase8/evidence/windows-acceptance.txt` 内）：

```
PHASE8-OVERLAY-EVIDENCE rect-visible left=0.0 top=0.0 w=1440.0 h=900.0
PHASE8-OVERLAY-EVIDENCE rect-hidden left=0.0 top=0.0 w=1440.0 h=900.0
PHASE8-OVERLAY-EVIDENCE geometry-invariant PASS
```

| 状态 | 视频区矩形 |
| --- | --- |
| 控制栏可见 | `Rect.fromLTRB(0.0, 0.0, 1440.0, 900.0)` |
| 控制栏隐藏 | `Rect.fromLTRB(0.0, 0.0, 1440.0, 900.0)` |

两者**逐像素相同**，且等于整个 body（1440×900）—— 顶栏与底栏都没有吃掉高度。

## 4. V2 实测：视频区占满整个 body

```
PHASE8-OVERLAY-EVIDENCE rect-windowed h=900.0 viewport=900
```

`h == viewport`，即画面高度等于窗口高度。改造前顶栏是 `Scaffold.appBar`，
会稳定吃掉 `kToolbarHeight = 56px`。

---

## 5. 这条不变式**有牙**（变异验证）

只跑绿不足以证明测试有效。实测把实现换成"半修好"的形态 ——
第 1 层 `Positioned.fill` 的底边随控制栏可见性收缩：

```dart
// 变异：制造与原始缺陷等价的几何依赖
Positioned(left: 0, top: 0, right: 0, bottom: _controlsVisible ? 92 : 0, child: ...)
```

结果：

```
rect-visible h=808.0     ← 控制栏可见时画面被压掉 92px
rect-hidden  h=900.0
Expected: Rect.fromLTRB(0.0, 0.0, 1440.0, 900.0)
  Actual: Rect.fromLTRB(0.0, 0.0, 1440.0, 808.0)
```

V1 与 V2 **同时变红**，并打印套件自带的提示：

> 控制栏显隐不得改变视频区几何——这正是用户投诉的「画面缩放」根因。

还原后 `git hash-object apps/desktop-flutter/lib/ui/player_page.dart`
= `5f46912ca80dc834af95f6903917ee767a0d20e4`，与变异前一致。

**结论**：V1 能区分「真修好」与「半修好」，不是装饰性断言。

---

## 6. 为什么 `pumpAndSettle` 在本页不可用

`PlayerPage` 的加载态常驻 `LoadingBlock`（内含 `CircularProgressIndicator`），
`transientCallbackCount` **恒 ≥1**（实测推进到 25 秒仍为 1）；同时
`PlayerController.open` 起播时会挂一个 180 秒加载超时
（`lib/ui/player_controller.dart:830` 的 `loadCompleter.future.timeout`，
预算来自同文件 `:30` 的 `playerLoadTimeout`）。

因此本套件用**有界多帧推进**代替：

```dart
for (var i = 0; i < 60; i++) {
  await tester.pump(const Duration(milliseconds: 250));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
}
```

`pumpAndSettle` 只出现在**加载完成之后**（此时已无排队帧）。

---

## 7. 已知的合法例外

`design/01` §5.3 记录了允许改变视频区尺寸的情形（窗口尺寸变化、`fit` 模式切换）。
本文件记录的两条断言都在**同一窗口尺寸下**比较，不受影响。
