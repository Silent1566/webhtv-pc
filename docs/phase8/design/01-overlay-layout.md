# 01 · 浮层布局（消除画面缩放）

- 状态：设计指导，**待评审**
- 日期：2026-10-18
- 上游参考：`F:\Workspace\webtv4\webhtv\app\src\mobile\res\layout\activity_video.xml`
- 关联：`00` §3、`02`、`03`、`04`
- PC 端落点：`apps/desktop-flutter/lib/ui/player_page.dart`、
  新增 `apps/desktop-flutter/lib/ui/player_overlay.dart`

---

## 1. 目标

**视频区尺寸在控制栏显隐前后逐像素不变。**

这一条是本子系统的全部意义。其余（浮层底色、动画、自动隐藏时长）都是围绕它的实现细节。

---

## 2. 现状的问题结构

```dart
// 现状（player_page.dart:1400-1473）——控制条是兄弟节点
body: Column(
  children: [
    Expanded(child: GestureDetector(child: Stack([Video, DanmakuOverlay, ...]))),
    if (_controlsVisible) Listener(child: _ControlBar(...)),
  ],
),
```

`Expanded` 分配的是**剩余**高度。控制条出现 → 剩余高度减少 → `Video` 的
`BoxFit.contain` 在新容器里重新按比例居中 → 画面整体缩小并上移。

**注意**：这不是"控制条太宽"的问题，也不是"控制条该不该半透明"的问题。
即使把控制条做成全透明，只要它仍在 `Column` 里，画面照样跳。

---

## 3. 目标结构

```dart
// 目标——控制层与屏显层都是 Stack 的 Positioned 子项
body: Stack(
  children: [
    // 第 1 层：画面 + 弹幕 + 加载/错误（占满整个 body）
    Positioned.fill(child: GestureDetector(child: Stack([Video, DanmakuOverlay, ...]))),

    // 第 2 层：屏显（02）——不拦截指针
    Positioned.fill(child: IgnorePointer(child: PlayerOsdLayer(...))),

    // 第 3 层：控制浮层（顶栏 + 底栏）——会拦截指针
    Positioned.fill(child: IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        child: _PlayerControlOverlay(...),
      ),
    )),
  ],
),
```

### 3.1 三条实现纪律

| 纪律 | 理由 |
| --- | --- |
| 控制层用 `AnimatedOpacity` 而不是 `if (_controlsVisible)` | 条件插入会让 Flutter 在重建时改变子树结构，且 `Positioned.fill` 的命中测试范围随之跳变；`AnimatedOpacity` 保持结构稳定，只改透明度 |
| 隐藏时必须 `IgnorePointer` | 透明但仍在树里的按钮**依然可点**，会造成"看不见的按钮吃掉点击" |
| 屏显层必须 `IgnorePointer` | 屏显是纯信息层，任何情况下都不接收指针（对齐上游 `view_player_osd.xml:6-7` 的 `clickable=false focusable=false`） |

### 3.2 为什么不用 `AnimatedSlide` / `AnimatedPositioned`

`DESIGN.md` 的 `AppMotion.ease` 是**指数缓出**，用于"从已可见状态出发"的过渡。
控制栏的显隐是**状态切换**，用 `AnimatedOpacity` + `AppMotion.fast`（120ms）即可。
滑动入场会在画面边缘产生一条移动的色带，反而更抢眼。

**这不违反 The Flat-Field Rule**：`AnimatedOpacity` 不是阴影，也不是 elevation。

---

## 4. 控制浮层的内容结构

顶栏与底栏合并为一个浮层，**一起出现、一起消失**。

```
┌──────────────────────────────────────────────────────────┐
│ [返回] 片名 · 第 N 集            字幕轨 弹幕 更多         │  ← 顶栏（原 AppBar 内容）
│                                                          │
│                    （画面，无遮挡）                       │
│                                                          │
│ 02:56 ──────●────────────────────────────── 39:08        │  ← 进度行
│  ⏮  ⏯  ⏭ │ 🔊 ──── │ 倍速 1.0x │ 线路 │ 剧集(36) │ ⛶   │  ← 动作行（03 定义）
└──────────────────────────────────────────────────────────┘
```

### 4.1 顶栏：保留 `AppBar`

**这是硬约束，不是偏好。** `integration_test/ui_redesign_visual_flow_test.dart:677-681`：

```dart
Finder inAppBar(String tooltip) => find.descendant(
  of: find.byType(AppBar),
  matching: find.byTooltip(tooltip),
);
expect(inAppBar('更多'), findsOneWidget);
```

`find.byType(AppBar)` 要求树里**真的有一个 `AppBar`**。因此顶栏改浮层时：

- **保留 `AppBar` widget 类型**，把它放进浮层的顶部 `Positioned`；
- 通过 `AppBarTheme` 的 `backgroundColor: Colors.transparent` +
  `elevation: 0` + `scrolledUnderElevation: 0` 让它透明；
- 浮层自身提供半透明纱底（见 §4.3），而不是 `AppBar` 自己带底。

**不要**把 `AppBar` 换成自绘 `Row`——那会同时打破 `find.byType(AppBar)` 与
`phase4_tmdb_detail_hero_test.dart:177` 的 `tester.widget<AppBar>(...)` 用法模式
（虽然那个测的是详情页，但保持类型一致能避免同类断裂）。

### 4.2 全屏时的顶栏

现状：全屏时 `appBar: null`。目标：全屏时顶栏**仍在浮层里**，只是随浮层一起隐藏。

这带来一个额外收益：**进出全屏不再有 56px 跳变**（`00` §3.1 表格最后两行）。

### 4.3 浮层底色

| 层 | 底色 | 理由 |
| --- | --- | --- |
| 顶栏纱 | `AppPalette.nightGround @ 0.72` → 底部渐隐 | 从画面到纱的过渡要软，硬边会像贴了一条黑带 |
| 底栏纱 | `AppPalette.nightGround @ 0.86` → 顶部渐隐 | 底栏承载文字与滑杆，需要更高对比度 |

**为什么用固定深色而不是 `Theme.of(context).colorScheme.surface`**：
现状 `player_page.dart:2102-2110` 的注释已经点明这个问题——
"播放器背景是视频、不是应用底色……在亮色主题下，主题给的深色图标会压在深色纱上
（实测约 3.5:1，不足）。要做对需要在播放器页整体套一层暗色 Theme 作用域，
那是一次独立改动，不夹在这里半做。"

**本轮就把那次独立改动做掉**：在 `PlayerPage` 的根套一层
`Theme(data: buildAppTheme(Brightness.dark), child: ...)`，
让整个播放器页（含浮层、菜单、对话框）恒定走暗色主题。

| 收益 | 说明 |
| --- | --- |
| 对比度可控 | 纱是固定深色，文字固定浅色，与用户主题无关 |
| 菜单/对话框一致 | 右键菜单、字幕菜单、诊断对话框都在暗色下渲染，不会出现"亮色主题下白底菜单压暗画面" |
| 消除现有注释里的半成品 | 现状是"知道不对但没做"，本轮把它做完 |

**代价与缓解**：播放器页不再跟随用户的亮色主题。这是**有意的**——
全幅视频表面上的 UI 应当恒定暗色（VLC / mpv / PotPlayer / Netflix 全屏播放器都如此），
用户的亮色主题作用于**应用外壳**，不作用于播放器。

### 4.4 自动隐藏

| 参数 | 现状 | 目标 | 依据 |
| --- | --- | --- | --- |
| 隐藏延时 | 4 秒（`player_page.dart:1513`） | **3 秒** | 主流播放器 2–3 秒；4 秒偏长，配合浮层后更显迟钝 |
| 唤醒方式 | 单击画面 / 鼠标移入底栏 | **鼠标在画面上移动** / **鼠标移入浮层任意处**（单击画面改为暂停/播放，§4.6） | 桌面播放器惯例；单击让给传输控制 |
| 隐藏时机 | 定时器到点 | 定时器到点 **且** 指针不在浮层上 | 指针停在控制栏上时不该消失（现状已用 `Listener.onPointerDown` 部分处理，但只覆盖按下，不覆盖悬停） |
| 暂停时 | 仍会隐藏 | **仍会隐藏** | 与主流一致；暂停时用户往往正在看画面 |

**鼠标移动唤醒的实现**：在画面层包一层 `MouseRegion(onHover: ...)`。
注意 `onHover` 在静止时也会随微动触发，需要节流（见 §4.5）。

### 4.5 指针悬停的实现细节

```dart
// 浮层自身：指针进入即视为"用户正在操作"，取消隐藏并暂停计时
MouseRegion(
  onEnter: (_) => _cancelHideTimer(),
  onExit:  (_) => _scheduleHide(),
  child: _PlayerControlOverlay(...),
)
```

**不要在 `onHover` 里调用 `_touchControls()`**：`onHover` 每次指针移动都触发，
会让 3 秒计时器被无限重置，控制栏永不隐藏。`onHover` 只用于**从隐藏态唤醒**，
且必须带"当前不可见才唤醒"的判断。

**落地状态**：

- **鼠标移动唤醒：已实现**。第 1 层（画面层）包 `MouseRegion(onHover:)`，
  守卫就是上面那句 `if (!_controlsVisible) _touchControls();`。
  两侧都有用例锁（`test/phase8_controls_hover_test.dart`）：
  去掉 `MouseRegion` → 第 1 条红；去掉守卫 → 第 2 条红。
- **「指针停在浮层上不隐藏」：未实现**，且原因是结构性的。控制浮层是
  `Positioned.fill`，它的 `onEnter` 实际等于「指针在窗口内」——无条件保持可见
  会让控制条**永不隐藏**（本轮第一版就是这么写的，实测后回退）。
  要做对，必须把 `MouseRegion` 收缩到顶栏/底栏两条**实际条面**上
  （`player_overlay.dart` 的两个 `Positioned`），属于独立改动。

### 4.6 状态机

```
         ┌──────────────┐  指针移动 / 单击画面 / 快捷键   ┌──────────────┐
         │   hidden     │ ─────────────────────────────► │   visible    │
         │ (opacity 0)  │                                │ (opacity 1)  │
         │ IgnorePointer│ ◄───────────────────────────── │ 可交互       │
         └──────────────┘   3s 到点 且 指针不在浮层上      └──────────────┘
```

| 事件 | 动作 |
| --- | --- |
| 进入页面 | `visible`，启动 3 秒计时 |
| 单击画面 | **暂停/播放**，并把浮层立即唤回 `visible`（`_onVideoTap`，§4.6） |
| 双击画面 | **切换全屏**（进入/退出）；第 2 击把播放状态拨回第 1 击前，因此**不改变**播放（`resolvePlayerGesture`） |
| 长按画面 | **临时快进到用户设置的长按倍速**（默认 3×，可选 2×/2.5×/3×/4×），松开恢复原速（`_beginGestureSpeed`） |
| 指针移入浮层 | 取消计时（保持 `visible`） |
| 指针移出浮层 | 启动 3 秒计时 |
| 指针在画面移动 | 若 `hidden` → 唤醒；若 `visible` → **不重置**计时 |
| 打开菜单/对话框 | 强制 `visible` 且**暂停**计时，关闭后恢复 |
| 窗口失焦 | 保持当前状态（不主动隐藏） |

**"打开菜单时暂停计时"是必须的**：否则用户打开右键菜单后 3 秒，控制栏在菜单背后消失，
关闭菜单时看到的是一个没有控制栏的画面。

**单击为什么不再显隐控制栏（2026-11 起）**：桌面播放器（PotPlayer / VLC /
MPC-HC）的单击是**传输控制**，显隐交给「指针移动唤醒 + 3 秒自动隐藏」。上游安卓
那套（`PlayerGesture.java`：单击显隐）是为触屏定的，搬到键鼠上会让最高频的
「点一下暂停」变成一次显隐——这是**有意的产品差异**，不是回退。

**为什么不用 `GestureDetector.onDoubleTap`**：一旦注册，Flutter 会把单击挂起
整个双击判定窗（约 300ms）才落地，单击暂停会明显迟滞。实现改成「每一击立即执行、
再由 `PlayerDoubleClickGate` 判窗」：窗口（`kPlayerDoubleClickWindow`，与
`kDoubleTapTimeout` 同为 300ms）内的第 2 击把播放状态**拨回第 1 击前**的值并切换
全屏，于是双击不改变播放状态。第 3 击重新计一轮，不会被继续当成双击。

---

## 5. 视频区尺寸不变式

### 5.1 不变式

> 对任意 `t`，`Video` 所在 `RenderBox` 的 `size` 与 `localToGlobal(Offset.zero)`
> 在 `_controlsVisible` 为 `true` 与 `false` 时**完全相同**。

### 5.2 为什么这条必须机器验证

"看起来不跳了"是主观的。而 `Column` → `Stack` 的迁移**很容易半做**：
例如把浮层包在 `SafeArea` 里、或给 `Stack` 加 `padding`、
或用 `Align` 而不是 `Positioned.fill` —— 这些都会让视频区尺寸重新依赖浮层。

**验证方式**（`05` §3.1 的 V1）：

```dart
final before = tester.getRect(find.byType(Video));
// 触发控制栏隐藏
await tester.pump(const Duration(seconds: 4));
final after = tester.getRect(find.byType(Video));
expect(after, before, reason: '控制栏显隐不得改变视频区几何');
```

### 5.3 已知的合法例外

| 例外 | 说明 |
| --- | --- |
| 窗口尺寸变化 | 视频区当然会变——不变式只在**窗口尺寸固定**的前提下成立 |
| 进出全屏 | 全屏改变的是**窗口**尺寸，不是布局；不变式在"全屏状态固定"下成立 |
| `PlayerVideoFitMode` 改变 | 用户显式改画面模式，视频区尺寸不变（`fit` 只改内容绘制方式），但**内容**变了——这是预期行为 |

---

## 6. 与弹幕层的关系

`DanmakuOverlay` 现状是 `Stack` 里 `Video` 之上的 `Positioned.fill`
（`player_page.dart:1424-1432`）。迁移后它仍在**第 1 层**内部，位置不变。

**弹幕与屏显的层级顺序**：弹幕在下、屏显在上。理由：屏显是"关于播放的事实"，
弹幕是"内容"，事实层应当压住内容层，否则密集弹幕会盖住时钟与诊断面板。

**弹幕与屏显的避让**：屏显四角与弹幕轨道可能重叠。
上游的做法是弹幕轨道**整幅铺满**、屏显直接压上去（`view_player_osd.xml` 无避让逻辑）。
本轮沿用——**不做避让**，因为避让会让弹幕轨道数随屏显开关变化，
造成"开了屏显弹幕变少"的隐式耦合。

---

## 7. 验收清单

| # | 检查项 | 方式 |
| --- | --- | --- |
| A1 | 控制栏显隐前后 `Video` 矩形逐像素相同 | L3 集成（`05` §3.1 V1） |
| A2 | 进出全屏前后 `Video` 矩形在**同一窗口尺寸**下相同 | L3 集成 |
| A3 | 隐藏状态下点击控制栏原位置**不触发**任何按钮 | L2 widget 测试（`IgnorePointer` 生效） |
| A4 | 指针停在底栏上时控制栏不隐藏 | L2 widget 测试 |
| A5 | 打开对话框时控制栏不隐藏；关闭后恢复计时 | L2 widget 测试 |
| A6 | 顶栏 `AppBar` 仍在树里，四个 tooltip 精确串可查 | L3 集成（沿用现有断言） |
| A7 | 播放器页在亮色主题下仍渲染暗色浮层 | L3 截图 + 断言 `Theme.of(context).brightness == Brightness.dark` |
| A8 | 无阴影、无非 0 elevation | L1 源码扫描（`05` §4 反向验证） |
