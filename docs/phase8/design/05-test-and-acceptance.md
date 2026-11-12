# 05 · 测试与验收设计

- 状态：设计指导，**待评审**
- 日期：2026-10-18
- 上游参考：Phase 1–7 的门禁与证据机制（`docs/phase1/README.md` §7、
  `docs/phase2/README.md` §3、`docs/phase3/README.md` §3、`docs/phase4/design/05`、
  `docs/phase5/design/03`、`docs/phase6/design/05`、`docs/phase7/design/04`）
- 关联：`00`、`01`、`02`、`03`、`04`
- PC 端落点：`apps/desktop-flutter/test/phase8_*.dart`、
  `apps/desktop-flutter/integration_test/phase8_*_flow_test.dart`、
  `tools/phase8/**`、`docs/phase8/evidence/**`

---

## 1. 测试分层

沿用 Phase 3–7 的三层结构，**不引入新机制**：

| 层 | 位置 | 真实网络 | 真实窗口 | 运行命令 |
| --- | --- | --- | --- | --- |
| L1 纯逻辑单测 | `test/phase8_*_test.dart` | ❌（全内存） | ❌ | `flutter test` |
| L2 契约与 widget | `test/phase8_*_test.dart`（注入 fake / 裸 `MaterialApp`） | ❌ | ❌ | `flutter test` |
| L3 集成 | `integration_test/phase8_*_flow_test.dart` | ✅（本地 fixture 服务） | ✅（`-d windows`） | `flutter test integration_test/... -d windows` |

### 1.1 本轮特有的分层约束

| 约束 | 理由 |
| --- | --- |
| **视频区几何不变式必须在 L3 覆盖** | 它需要真实 `Video` widget 与真实 `RenderBox`；L2 里 `Video` 没有真实尺寸 |
| **浮层与屏显的显隐必须在 L2 覆盖** | 它们是纯 widget 状态，L2 足够且快得多 |
| **按钮归一化必须在 L1 覆盖** | 纯函数，是"新增按钮自动出现"的唯一闸门 |
| **屏显开关持久化必须在 L2 覆盖** | 涉及 `settings.json` 读写与串行队列 |
| **截图必须在 L3 且必须能拍到菜单** | `04` §3 的决策就是为了这一条 |
| **不得引入 golden 文件** | 沿用既有纪律（`.impeccable/surfaces/lib-ui-app-dart.md`："无 golden 文件：截图是证据，不是断言"） |

### 1.2 在 `testWidgets` 里写配置必须包 `tester.runAsync`

**这条是本轮实测踩出来的，不遵守会挂死 10 分钟（不是失败，是超时）。**

`setUp` 运行在**真实事件循环**的 zone；`testWidgets` 的函数体运行在 **`FakeAsync`** zone。
`UiPreferencesStore._persistQueue`（`ui_preferences_store.dart:469`）是在 `setUp` 的 zone 里
创建的 `Future`，所以在 `testWidgets` 里直接 `await` 任何写操作
（`setPlayerButtonOrder` / `setPlayerButtonHidden` / `resetPlayerButtons` / `setOsdFlag` …），
其**续体会被调度到真实事件循环**，而 `FakeAsync` 永远不推进它 → 测试挂死到 10 分钟超时，
后续用例还会连锁报 `Guarded function conflict. You must use "await" with all
Future-returning test APIs`（那个报错是**假象**，真正的问题是前一个用例没结束）。

正确写法：

```dart
await tester.runAsync(() async {
  await state.setPlayerButtonOrder(const ['fullscreen', 'episodes']);
});
await tester.pumpWidget(...);   // 之后的 pumpAndSettle 正常返回
```

**为什么容易漏**：普通 `test()`（非 `testWidgets`）**没有** `FakeAsync` zone，
所以同一段代码在 `test()` 里完全正常——`phase8_app_state_config_test.dart` 就是这样
（它全是 `test()`，因此从未暴露此问题）。只有「`setUp` 建 state + `testWidgets` 里写配置」
这个组合才会挂。

**实测排除记录**（逐个探针跑过，用于证明根因不是别的）：
裸 `ReorderableListView` + `pumpAndSettle` 通过；
`SingleChildScrollView` + `ReorderableListView(shrinkWrap)` + `pumpAndSettle` 通过；
页面 + 有界 `pump`（不 settle）通过；
页面 + `pumpAndSettle`（**不先写配置**）通过；
页面 + **先 `await` 写配置** + `pumpAndSettle` **挂死**；
同上但写配置包进 `runAsync` → **通过**。

### 1.3 两类已实测的「假绿」，必须避开

**(a) 只 `pump` 一次就断言动画/插值终值 —— 断言永久为绿。**

首帧 `elapsed == 0`（`ticker.dart:277`），所以任何 `lerp(a, b, t)` 在首帧都等于 `a`。
实测案例：`ReorderableListView` 的默认 `proxyDecorator` 会把 elevation 从 0 动到 6，
但「拖动过程中 elevation 必须为 0」这条断言在**只 pump 一次**时**恒真**——
把自定义 `proxyDecorator` 整个删掉，测试照样通过。
**要求**：断言动画结果必须 pump 到动画结束（`pumpAndSettle`，或至少第二次 `pump`），
并在注释里写明「首帧恰好是 0」这个陷阱。

**(b) 平台相关的假绿 —— 断言在默认测试平台下恒真。**

`flutter_test` 默认目标是 **android**。实测案例：`ReorderableListView` 的默认拖动手柄
**只在桌面平台**（linux/windows/macOS）插入 `Icons.drag_handle`；在 android 上插入的是
**不带图标**的 `ReorderableDelayedDragStartListener`
（`material/reorderable_list.dart:382-443`）。于是「按 `Icons.drag_handle` 数量断言手柄」
在默认平台下**恒真**，`buildDefaultDragHandles: true` 这个错误配置无法被抓到。
**要求**：凡断言依赖平台分支的桌面行为，测试里显式覆盖
`debugDefaultTargetPlatformOverride = TargetPlatform.windows`，并在 `finally` 里复位
（`debugAssertAllFoundationVarsUnset` 在 tearDown 之前运行，所以必须用 `finally`）。

### 1.4 读完配置后「界面刷新」也需要推进真实事件循环

§1.2 讲的是**写配置**要包 `runAsync`。实测还有第二半：**读完配置后让界面刷新**
同样需要推进真实事件循环，`pumpAndSettle` 一个人做不到。

原因：`AppState.setOsdFlag` 在 `await _persist()` **之后**才 `notifyListeners()`
（`ui_preferences_store.dart` 的写盘续体落在真实事件循环上），
所以假时钟推进再多帧，那次通知也发不出来。仓库里既有的正确写法是
`phase5_sync_ui_test.dart:190` 的 `settleIo`：

```dart
Future<void> settleIo(WidgetTester tester, {int rounds = 90}) async {
  for (var round = 0; round < rounds; round++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 16)),
    );
  }
  await tester.pumpAndSettle();
}
```

**还有一个更容易漏的前提**：`SettingsPage` 是 `StatelessWidget`，
它**自己不监听** `AppState`（真正的监听者在外层 `AppShell`）。所以在测试里裸
pump 一个 `SettingsPage` 会得到一个**永不重建**的页面——往返点击会重复发送
**陈旧值**。正确做法是照 `phase5_sync_refresh_test.dart:175` 用 `ListenableBuilder`
包一层：`home: ListenableBuilder(listenable: state, builder: ...)`。

### 1.5 「在视口内」必须先证明「被构建」——惰性列表会吞掉断言

Task 11 的回归阶段暴露了一个**既有**失败（由 Task 10 引入、Task 11 才暴露），
根因是一条很容易写错的判据。

设置页是**惰性 `ListView`**：只有进入视口（含 `cacheExtent`）的条目才被构建。
Task 10 新增的播放器区块把内容总高从 2000 推到约 2540，于是
`integration_test/ui_redesign_visual_flow_test.dart:991` 在 `1440×2400` 视口下
断言「站点健康入口必须被构建」时，`find.byKey` 返回 **0 个**。

**为什么实现者和审查者都没发现**：他们验证的是「既有 tap 目标仍在视口内」，
用的是 `tester.getRect(finder)`。而**没被构建的 widget 根本取不到 rect**——
`getRect` 会先抛「找不到」，或者在有 `findsOneWidget` 前置断言时直接红；
但若只写了 `getRect` 而没写 `findsOneWidget`，失败信息会指向别处，
看起来像别的问题。**「取不到」被误当成「通过了」。**

规则（本轮新增，必须遵守）：

```dart
// 错：只断言几何
final rect = tester.getRect(find.byKey(const ValueKey('settings-site-health-open')));

// 对：先证明被构建，再断言几何
final finder = find.byKey(const ValueKey('settings-site-health-open'));
expect(finder, findsOneWidget, reason: '必须被构建（不得被新增区块挤出惰性视口）');
final rect = tester.getRect(finder);
```

**两个推论**：

1. **新增 UI 必须放在长表单的末尾**。本页既有测试不带 `ensureVisible`，
   把新区块插在中间会把后面所有既有入口整体下推。放在末尾时，
   被下推的只有新区块自己。
2. **`Scrollable` 的偏移量存在 `PageStorage` 里**，重建同类型子树时会恢复。
   所以「先滚动到底部断言新入口」再「断言顶部入口」会红——实测红在
   `ui_redesign_visual 1440x2400：settings-theme-mode 必须被构建`。
   新增入口的可达性检查必须与既有入口的检查**分成两轮**。

### 1.6 播放器页上不能用「带时长」的 `pumpAndSettle`（第 9 类缺陷）

**现象**：3 个既有集成套件直到最终审查才红——而它们从未被任何门禁跑过。
根因有两层，修法不同。

**(a) 屏显时钟让带时长的 `pumpAndSettle` 永不返回。**

`OsdFlag.time` 默认 `true`（`lib/core/osd_config.dart:61`），
`lib/ui/player_osd.dart:86` 的 `_clockVisible = controlsVisible || flags[time]`
让时钟**永远**显示，于是 `_osdNeedsTicker` 恒为真：1 秒一次的 `Timer.periodic`
常驻，每秒 `setState`。`pumpAndSettle(const Duration(seconds: n))` 以 n 为步长，
只要 **n ≥ 1 秒**，每一步都必然跨过一次 tick，`hasScheduledFrame` 永远为真，
一直泵到 10 分钟默认超时才抛 `pumpAndSettle timed out`
（实测 `subtitle_flow_test.dart:148` 于 `10:09` 抛出）。

- **不带时长**的 `pumpAndSettle()` 不受影响：默认步长 100ms，能收敛。
- 要「等一段真实时间」→ `settlePlayerPage(tester, total: ...)`。
- 要「等某个条件成立」→ 显式轮询（套件里本来就有这个写法）。

**(b) 控制浮层 3 秒自动隐藏后 `IgnorePointer` 会吃掉点击。**

`tester.tap` 默认只 `warnIfMissed` 打一句警告，断言随后以「找不到 / 状态没变」
的形式失败，看不出真正原因。→ 点浮层上的按钮前先 `revealPlayerControls(tester)`；
它先读 `debugPlayerControlsVisible` 再决定唤不唤醒，唤醒走 `debugRevealPlayerControls`
（`_touchControls` 的测试缝）。**不能再点画面**：单击现在是暂停/播放（`01` §4.6），
点一下会顺带把视频暂停，后续「仍在播」的断言就全变了。

两个辅助都在 `integration_test/phase8_player_test_support.dart`。

**(c) 门禁为什么没抓到——这才是本轮的真正教训。**

G11 原稿写「含在 G2 里（全量 `flutter test`）」。但 `flutter test` 默认只跑
`test/`，**不跑 `integration_test/`**。挂载 `PlayerPage` 的既有集成套件有 12 个，
一个都没跑过。**「全量单元测试全绿」不等于「既有回归全绿」**——
把两类套件合并成一句话，等于给集成套件开了一张空头支票。

规则：**门禁条目必须点名到可执行的文件列表**，不能写「含在 X 里」。

### 1.7 「假绿」的第 10 类：观测缝撞上真实设备

给播放器页加鼠标悬停唤醒（`01` §4.5）后，测试里想模拟悬停。
`tester.createGesture(kind: PointerDeviceKind.mouse)` 是 widget 测试的标准写法，
但在 **`LiveTestWidgetsFlutterBinding`（真实窗口的集成测试）** 下会直接炸：

```
'mouse_tracker.dart': Failed assertion: line 220:
'(event is PointerAddedEvent) == (lastEvent is PointerRemovedEvent)': is not true.
```

原因：真实窗口已经在跟踪真实的鼠标设备，再加一个指针就破了 MouseTracker 的
added/removed 配对不变式。**同一个 API 在 widget 测试里可靠、在集成测试里不可靠。**

规则：集成测试不要模拟指针设备；用 `@visibleForTesting` 的唤醒缝
（`debugRevealPlayerControls`，它调的就是产品自己的 `_touchControls()`），
并用状态观测缝（`debugPlayerControlsVisible`）判断「该不该唤醒」。
**不要用「单击画面」代替**：桌面语义下单击是暂停/播放（`01` §4.6），
会顺带改掉播放状态。`revealPlayerControls` 已按这个口径实现。

---

## 2. 新增测试文件

| 文件 | 层 | 覆盖 |
| --- | --- | --- |
| `test/phase8_osd_config_test.dart` | L1 | 7 项开关默认值、归一化（未知键/缺失键/非法类型/非 Map）、`anyOsdEnabled` |
| `test/phase8_player_buttons_test.dart` | L1 | 8 项定义、默认顺序、顺序归一化（`List`/`String` 双形态）、隐藏集归一化、可见列表解析 |
| `test/phase8_osd_diagnostics_test.dart` | L1 | 诊断主列 6 行、未知字段显示「未知」、直播不显示 `00:00 / 00:00`、附加列拿不到的行不出现 |
| `test/phase8_overlay_layout_test.dart` | L2 | 浮层不占布局、贴顶贴底、分组分隔线、单行溢出滚动、无 elevation |
| `test/phase8_context_menu_test.dart` | L2 | 位置 clamp（三边界）、分组渲染、禁用项、选中态琥珀、点击回调、无 elevation |
| `test/phase8_osd_persistence_test.dart` | L2 | `settings.json` 往返、缺席不写盘、非法值回落、`sync` 段保留、字符串格式兼容 |
| `test/phase8_app_state_config_test.dart` | L2 | `AppState` 的屏显与按钮配置读写、立即生效、恢复默认 |
| `test/phase8_osd_layer_test.dart` | L2 | 四角渲染与隐藏条件、控制栏联动、`IgnorePointer`、直播/`duration<=0`、字号与描边 |
| `test/phase8_button_config_page_test.dart` | L2 | 列出 8 项与分组、开关持久化、恢复默认二次确认、预览行、拖动重排 |
| `test/phase8_settings_entries_test.dart` | L2 | 设置页两个入口、7 项开关齐全、`traffic` **可点**（原文「置灰」，能力落地后更正）、切换持久化 |
| `test/phase8_player_page_overlay_test.dart` | L2 | 四层结构、`AppBar` 保留、四个 tooltip、`IgnorePointer`、右键菜单开关与 `Esc`、按钮配置生效、无 elevation |
| `integration_test/phase8_overlay_flow_test.dart` | L3 | **视频区几何不变式**、顶栏不占 56px |
| `integration_test/phase8_visual_flow_test.dart` | L3 | 多宽高比截图（含**菜单可见**）、菜单截图与关闭态字节不同、窄窗口不换行 |

**合计 13 个套件**（11 个单测 + 2 个集成）。

---

## 3. 关键用例清单（按设计文档逐条对应）

### 3.1 `01` 浮层布局

| # | 用例 | 层 | 断言 |
| --- | --- | --- | --- |
| V1 | **视频区几何不变式**：控制栏显隐前后 `Video` 矩形逐像素相同 | L3 | `tester.getRect(find.byType(Video))` 两次相等 |
| V2 | 进出全屏前后，同一窗口尺寸下 `Video` 矩形相同 | L3 | 同上 |
| V3 | 隐藏态点击控制栏原位置**不触发**任何按钮 | L2 | 计数器 = 0 |
| V4 | 指针移入浮层 → 取消隐藏计时 | L2 | `pump(5s)` 后仍可见 |
| V5 | 指针移出浮层 → 3 秒后隐藏 | L2 | `pump(3s)` 后不可见 |
| V6 | 指针在画面移动：隐藏态唤醒；可见态**不重置**计时 | L2 | 可见态下 `pump(3s)` 仍隐藏 |
| V7 | 打开对话框 → 控制栏不隐藏；关闭后恢复计时 | L2 | 对话框期间可见 |
| V8 | 顶栏 `AppBar` 仍在树里 | L2 | `find.byType(AppBar)` `findsOneWidget` |
| V9 | 播放器页在亮色主题下渲染暗色 | L2 | `Theme.of(playerContext).brightness == Brightness.dark` |
| V10 | 全屏时顶栏仍在浮层里（不再 `appBar: null`） | L2 | 全屏态下 `find.byType(AppBar)` 仍 `findsOneWidget` |

### 3.2 `02` 屏显

| # | 用例 | 层 | 断言 |
| --- | --- | --- | --- |
| B1 | 默认值：`title/size/time/progress` = true，其余 false | L1 | 逐项 |
| B2 | 归一化：未知键忽略 | L1 | 结果不含该键 |
| B3 | 归一化：缺失键补默认 | L1 | 结果含全部 7 键 |
| B4 | 归一化：非法类型（字符串/数字/null）回落到**各自**默认值 | L1 | 逐项；**必须含默认 false 的项**（traffic/mini/diagnostics），否则「回落默认」与「非 bool 即 true」两种实现无法区分 |
| B5 | 持久化往返 | L2 | 写入 → 重新 load → 相等 |
| B6 | 缺席不写盘：从未设置过时 `ui.osd` 不存在 | L2 | 读原始 JSON |
| B7 | 只改 `ui` 段：`sync` 段保留 | L2 | 读原始 JSON |
| B8 | 控制栏可见 → 时钟强制显示、进度/迷你/诊断强制隐藏 | L2 | 逐项 `findsOneWidget`/`findsNothing` |
| B9 | 屏显全关 + 控制栏隐藏 → 层隐藏且 Timer 停止 | L2 | `activeTimerCount == 0` |
| B10 | 屏显全关 + 控制栏**可见** → Timer 仍运行（为时钟） | L2 | `activeTimerCount == 1` |
| B11 | 直播（`directUrl=true`）→ 进度与迷你条隐藏 | L2 | `findsNothing` |
| B12 | `duration <= 0` → 进度项隐藏 | L2 | `findsNothing`（不是 `00:00 / 00:00`） |
| B13 | 屏显层 `IgnorePointer`：点击穿透 | L2 | 画面回调被触发 |
| B14 | 屏显文本字号 = 14 且带 `tabular` | L1 | 样式断言 |
| B15 | 诊断面板与 `_showMediaInfo` 用同一取数函数 | L1 | 函数级：同输入同输出 |
| B16 | `traffic` 开关**可点**且副标题写数据来源（原文「置灰 + 说明未采集」，能力落地后更正） | L2 | `onChanged != null` 且副标题**精确等于**「取自播放引擎的网络输入速率；取不到时显示 —」（**不含**任何属性名） |
| B17 | 迷你进度条只在控制栏隐藏时显示，且颜色为 `magnitude` | L2 | 样式断言 |

### 3.3 `03` 按钮排版

| # | 用例 | 层 | 断言 |
| --- | --- | --- | --- |
| D1 | `kPlayerButtons` 恰好 8 项 | L1 | 长度 + id 集合 |
| D2 | 默认顺序 = `prev,play,next,mute,volume,speed,line,episodes,fullscreen` | L1 | 逐项 |
| D3 | 顺序归一化：非法 id 过滤 | L1 | 结果不含 |
| D4 | 顺序归一化：去重 | L1 | 无重复 |
| D5 | 顺序归一化：缺失项**追加到末尾** | L1 | 老配置 + 新按钮 → 新按钮在末尾 |
| D6 | 顺序归一化：接受逗号分隔 `String` | L1 | 与 `List` 输入同结果 |
| D7 | 隐藏集归一化：非法 id 过滤、去重 | L1 | 集合相等 |
| D8 | 可见列表解析：按 order 排、按 hidden 过滤 | L1 | 逐项 |
| D9 | 持久化往返 | L2 | 写入 → load → 相等 |
| D10 | 恢复默认：清两键 | L2 | 读原始 JSON 无 `playerButtons` |
| D11 | 渲染顺序按配置 | L2 | 用 `tester.getTopLeft` 比较 x 坐标单调 |
| D12 | 分组边界插入分隔线 | L2 | 分隔线数量 = 组数 - 1 |
| D13 | 隐藏项不渲染 | L2 | `findsNothing` |
| D14 | 顶栏 `subtitle`/`danmaku` **不受**配置影响 | L2 | 隐藏全部可配置项后两者仍在 |
| D15 | 窄窗口不换行 | L2 | 控制栏高度 = 单行高度 |
| D16 | 配置页拖动 → 预览行更新 | L2 | 文字顺序变化 |
| D17 | 恢复默认需二次确认 | L2 | 首次点击不生效 |

### 3.4 `04` 右键菜单

| # | 用例 | 层 | 断言 |
| --- | --- | --- | --- |
| C1 | 右键 → 菜单出现 | L2 | `find.byType(PlayerContextMenu)` `findsOneWidget` |
| C2 | 菜单在 `Scaffold` 的 `RepaintBoundary` 内 | L3 | `find.descendant(of: 第一个 RepaintBoundary, matching: PlayerContextMenu)` `findsOneWidget` |
| C3 | 位置 clamp：右下角右键不溢出窗口 | L2 | `menuRect.right <= viewport.width` |
| C4 | 点击菜单外 → 关闭 | L2 | `findsNothing` |
| C5 | `Esc` → 只关菜单，全屏状态不变 | L2 | 菜单消失 + `_fullscreen` 不变 |
| C6 | 打开菜单 → 控制栏强制可见 | L2 | 可见 |
| C7 | 打开菜单 → 隐藏计时器取消 | L2 | `pump(5s)` 后控制栏仍可见 |
| C8 | 关闭菜单 → 3 秒后控制栏隐藏 | L2 | `pump(3s)` 后不可见 |
| C9 | 倍速菜单标出当前档位 | L2 | 选中态在 `1.0×` 上 |
| C10 | 屏显子菜单 7 项状态正确 | L2 | 逐项 |
| C11 | 单击暂停/播放、双击全屏、长按可配置倍速（默认 3×） | L1+L2 | `phase3_player_display_test.dart` + `player_click_gesture_test.dart` + `phase9_player_core_test.dart` |
| C12 | 每一项都有非右键等价路径 | L1 | 源码扫描（§4） |
| C13 | 设置页新增两个入口 | L2 | `ValueKey('settings-osd')` / `ValueKey('settings-player-buttons')` |

---

## 4. 反向验证（`tools/phase8/verify_reverse_checks.py`）

沿用 Phase 4–7 的机制：**故意破坏 → 必须按预期失败 → 还原 → 工作区干净**。

| # | 破坏方式 | 文件 | 必须失败的用例 |
| --- | --- | --- | --- |
| 1 | **视频区重新依赖控制栏可见性**（原始 bug 的几何本质） | `lib/ui/player_page.dart` | `phase8_overlay_flow_test.dart`（V1 几何不变式） |
| 2 | 去掉隐藏态的 `IgnorePointer` | `lib/ui/player_page.dart`（**不是** `player_overlay.dart`） | `phase8_player_page_overlay_test.dart` |
| 3 | 屏显层去掉 `IgnorePointer` | `lib/ui/player_osd.dart` | `phase8_osd_layer_test.dart` |
| 4 | 顺序归一化不再补全缺失项 | `lib/core/player_buttons.dart` | `phase8_player_buttons_test.dart` |
| 5 | 屏显默认值把 `title` 改为 false | `lib/core/osd_config.dart` | `phase8_osd_config_test.dart` |
| 6 | 屏显全关时不停 Timer | `lib/ui/player_page.dart` | `phase8_player_page_overlay_test.dart` |
| 7 | 右键菜单改用 Navigator 的 `Overlay`（等价于 `showMenu`） | `lib/ui/player_page.dart` | `phase8_visual_flow_test.dart`（C2 后代断言） |
| 8 | `Esc` 在菜单打开时仍绑到 `exitFullscreen` | `lib/ui/player_page.dart` | `phase8_player_page_overlay_test.dart` |
| 9 | 把 `subtitle`/`danmaku` 加入可配置集合 | `lib/core/player_buttons.dart` | `phase8_player_buttons_test.dart` |
| 10 | 控制栏改回 `Wrap`（窄窗口换行） | `lib/ui/player_overlay.dart` | `phase8_player_page_overlay_test.dart` |

**#1 与 #7 是本轮最容易悄悄写错的两处**（它们直接对应根因与证据能力），
必须作为机器证据存在。

> **本表与脚本已逐行对齐（`R109`）**：上表的「文件」与「必须失败的用例」
> 两列就是 `tools/phase8/verify_reverse_checks.py` 里 `CHECKS` 表的实际取值。
> 设计稿先前有 3 行写错了归属——
> #6 曾写 `player_osd.dart`（实际 `_osdNeedsTicker`/`_syncOsdTimer`/`_osdTimer`
> 都在 `_PlayerPageState` 里，`player_osd.dart` 是**无状态纯 widget**，不持有定时器）、
> #10 曾写 `player_page.dart`（实际 `SingleChildScrollView` 在
> `player_overlay.dart` 的 `PlayerOverlayActionRow` 里）、
> #7 曾写 `player_context_menu.dart`（破坏点是**装配位置**，在 `player_page.dart`）。
> 另外 #1 的破坏方式也改过：落地后 `body` 整体变成 `Theme(...)`，
> 「放回 `Column` 兄弟节点」已无法用字符串替换表达，改成**产生同样可观测后果**
> 的最小破坏（让第 1 层 `Positioned.fill` 的底边随 `_controlsVisible` 收缩）——
> 这正是用户投诉的「唤醒控制台导致画面缩放」的几何本质。
>
> **迷你进度条不在这张表里**：它的几何由 `phase8_osd_layer_test.dart:317-327`
> 用精确矩形断言（`left 0` / `right 800` / `bottom 600` / `height 2`）覆盖，
> 不需要靠截图。原先设计稿把它列为「3a」并说「靠 G8 截图证明该条可见」，
> 那既与脚本的 10 项对不上，也低估了既有的断言强度。

---

## 5. 既有测试的处置（**必须逐条确认**）

本轮会改动被既有测试锁定的结构。下表列出**每一条**风险与处置：

| 测试文件 | 锁定的内容 | 本轮风险 | 处置 |
| --- | --- | --- | --- |
| `integration_test/ui_redesign_visual_flow_test.dart:671-693` | `find.byTooltip('字幕轨')` / `'弹幕（开启）'` / `'全屏（F11）'` 各 `findsOneWidget`；`'更多'` 在 `AppBar` 内；`'字幕样式'/'弹幕设置'/'画面比例与缩放（contain）'` 全局 `findsNothing` | **高**：顶栏改浮层 | **保留 `AppBar` 类型**（`01` §4.1）；四个 tooltip 精确串不变；`'更多'` 仍在 `AppBar.actions` |
| `integration_test/subtitle_flow_test.dart:144,153` | 直接 `tap(find.byTooltip('字幕轨'))` | **高** | 顶栏按钮常驻，不进可配置集合（`03` §5.3）；**另外两处已实测会红，见下方 §5.2** |
| `integration_test/danmaku_flow_test.dart:156,175` | 直接 `tap('弹幕（开启）'/'弹幕（关闭）')` | **高** | 同上（含 §5.2 的两处修正） |
| `integration_test/ui_redesign_visual_flow_test.dart:696-707` | `tap('更多')` 后 6 个菜单项文字存在 | 中 | 顶栏「更多」菜单**不删**（`04` §4.3） |
| `test/phase3_player_display_test.dart:6-40` | `PlayerVideoFitMode` 五枚举的 `fit`/`aspectRatio`/`label`；`resolvePlayerGesture` 四分支 | 中 | **不改**这些定义；右键是独立回调（`04` §6） |
| `test/phase3_player_display_test.dart:42-58` | `PlayerSubtitleStyle` 默认值（透明底、有描边、`bottomPadding=24`） | 低 | **不改** |
| `integration_test/danmaku_flow_test.dart:145-171` | `find.byType(DanmakuOverlay)` + `CustomPaint` 存在性 | 中 | 弹幕层仍在第 1 层内，位置与类型不变（`01` §6） |
| `integration_test/subtitle_flow_test.dart:120` / `danmaku_flow_test.dart:138` 等 | `Scaffold(body: PlayerPage(...))` 的 pump 形态 | 中 | `PlayerPage` 仍是 `Scaffold`；新增的暗色 `Theme` 包裹在 `PlayerPage` **内部**，不改外部 pump 形态 |
| `integration_test/mvp_a_flow_test.dart:345,359,362` | `tester.widget<PlayerPage>(...)`、`find.byType(PlayerPage)` | 低 | 类型不变 |
| `test/phase4_tmdb_detail_hero_test.dart:177` | `tester.widget<AppBar>(find.byType(AppBar).first)` | 低 | 那是详情页；播放器页保留 `AppBar` 类型可避免同类断裂 |

### 5.1 需要用户确认的一处

**`Scaffold(body: PlayerPage(...))` 的 pump 形态**：
`subtitle_flow_test.dart:120` 等 6 处用裸 `MaterialApp(home: Scaffold(body: PlayerPage(...)))`
pump 播放器页。本轮在 `PlayerPage` 内部包一层暗色 `Theme`（`01` §4.3），
**不改变外部形态**，因此这些测试不受影响。

**但**：如果实现时选择"在 `app.dart` 的路由层包暗色 Theme"，
则这 6 处测试会**看不到暗色**（它们不走路由），导致 `V9` 断言失败。

**决策：暗色 `Theme` 必须包在 `PlayerPage.build` 内部**，不是路由层。

### 5.2 已实测被打破的 5 处（本轮补修，非设计预期）

上表第一行的「顶栏按钮常驻」只解决了**位置**问题，没解决**可达性**问题。
实际跑下来，这几个套件红的根因都**不是**按钮被收进溢出菜单：

| 位置 | 实测现象 | 根因 | 修法 |
| --- | --- | --- | --- |
| `subtitle_flow_test.dart:148` | `pumpAndSettle timed out`，时间戳 `10:09` | 屏显时钟每秒 `setState`，`pumpAndSettle(2s)` 永不收敛（§1.6a） | 改为轮询 `track.subtitle.id == 'no'` |
| `danmaku_flow_test.dart:157,176` | 同上（`pumpAndSettle(1s)`） | 同上 | 改为单次 `pump()`（该开关只改本地状态，无真实异步） |
| `danmaku_flow_test.dart:175` | 点击打空 → `resumed.style.enabled` 仍为 false | 前面的轮询已耗掉 3 秒以上，浮层自动隐藏后 `IgnorePointer` 吃掉点击（§1.6b） | 点击前 `revealPlayerControls(tester)` |
| `phase7_resume_flow_test.dart:145` | `pumpAndSettle timed out` | 点剧集卡片后已落在 `PlayerPage` 上（§1.6a） | `settlePlayerPage(total: 10s)` |
| `phase7_resume_flow_test.dart:205` | 同上 | 路由退场动画期间播放器还在树里，ticker 还在跑 | `settlePlayerPage(total: 5s)` |

`mvp_a_flow_test.dart:342,361` 是同一形态，同样已修；该套件在本机另有 2 条
**基线即红**的环境失败（见 §6 的 G11 说明），与本轮无关。

配套新增：

- `integration_test/phase8_player_test_support.dart`：`settlePlayerPage`、`revealPlayerControls`。
- `test/phase8_controls_hover_test.dart`：2 条，锁 `01` §4.5 悬停唤醒的**两侧**
  （去掉 `MouseRegion` → 第 1 条红；去掉 `if (!_controlsVisible)` 守卫 → 第 2 条红）。

---

## 6. 门禁表

| # | 门禁 | 命令 | 通过判据 |
| --- | --- | --- | --- |
| G1 | 静态检查 | `dart analyze` | 无问题 |
| G2 | 单元测试 | `flutter test` | 全绿（含 11 个 `phase8_*` 单测套件） |
| G3 | 套件存在性 | 脚本内清单核对 | 11 个单测 + 2 个集成套件均存在 |
| G4 | Windows 集成 | `flutter test integration_test/phase8_*_flow_test.dart -d windows` | 2 个套件全绿（**逐套件单独跑**） |
| G5 | 反向验证 | `py -3 tools/phase8/verify_reverse_checks.py` | 10 项全部"按预期失败"且还原后工作区干净 |
| G6 | 设计文档一致性 | `py -3 tools/phase8/verify_design_docs.py` | 章节号连续、交叉引用可解析、契约快照与源码一致 |
| G7 | 几何不变式专项 | `flutter test integration_test/phase8_overlay_flow_test.dart -d windows` | V1/V2 通过 |
| G8 | 截图证据 | `py -3 tools/phase8/verify_screenshots.py` | 13 张截图存在、非空，且与 `manifest.txt` **逐字节一致**（可复核） |
| G9 | 无阴影/无 elevation | `py -3 tools/phase8/verify_flat_field.py` | 新增文件中无 `BoxShadow` / 非 0 `elevation` |
| G10 | 字号未改 | `py -3 tools/phase8/verify_metric_neutral.py` | `theme.dart` 的 `_textTheme` 与基线逐字相同 |
| G11 | 既有测试回归 | 步骤 `player-integration-regression`：逐个 `flutter test integration_test/{subtitle,danmaku,phase7_resume}_flow_test.dart -d windows` | 3 个套件全绿 |
| G12 | 定时器无泄漏 | `flutter test test/phase8_player_page_overlay_test.dart` | 该套件全绿，且套件调 `osdTickerRunning`、包装走到 `debugOsdTickerRunning` 观测缝 |

> **G12 的判据为什么长这样**（`R108` + `R111`，两次实测换来的）：
>
> 1. **「活动定时器数 = 0」不需要我们断言**。框架在每个 `testWidgets` 结束时
>    自动检查 `!timersPending`（`package:flutter_test/src/binding.dart:2543`）。
>    实测：测试体内裸起一个不 cancel 的 `Timer.periodic` → 失败
>    `A Timer is still pending even after the widget tree was disposed.`；
>    在 widget 的 `initState` 起、`dispose` 不 cancel → 同样失败；
>    正常 cancel → 通过。所以**泄漏**由框架免费覆盖。
> 2. **但框架抓不到「空转」**。`_osdTimer` 在 `dispose()` 里被 cancel，
>    所以「该停时没停、每秒空转」这种缺陷**不会**触发 `!timersPending`。
>    这才是 G12 真正要防的东西，必须用观测缝断言。
> 3. **判据套件是 `phase8_player_page_overlay_test.dart`，不是
>    `phase8_osd_layer_test.dart`**。后者只 pump `PlayerOsdLayer`（纯 widget，
>    自身不持定时器），它在结构上**不可能**观测到 `_PlayerPageState._osdTimer`。
> 4. **不得改用 `transientCallbackCount`**：加载态常驻 `LoadingBlock` 的
>    `CircularProgressIndicator`，该计数**恒 ≥1**（实测推进到 25 秒仍为 1），
>    用它写的断言**永远为真**，门禁会退化成装饰。
> 5. **观测缝是两层的，两层都要查**（`R111`）：套件里调
>    `osdTickerRunning(tester)`（`test/support/player_page_harness.dart` 的包装），
>    包装里调 `debugOsdTickerRunning`（`lib/ui/player_page.dart` 的
>    `@visibleForTesting` 函数）。只查套件会漏掉「包装被改成返回常量」；
>    只查包装会漏掉「套件根本没调它」。
>    **实测踩到**：门禁原先只查套件里的 `debugOsdTickerRunning`，而套件用的是
>    包装名，于是**正确实现反而门禁红**——一次「门禁比实现更严」的假失败。
> 6. **查 `transientCallbackCount` 前必须先剥掉注释行**：套件里有一条注释
>    专门解释「为什么不能用它」（第 4 点），那是文档不是用法。只按裸串匹配
>    会把正确实现判红（同样实测踩到）。

> **G11 为什么只点名 3 个套件、另外两个为什么不进来**：
>
> 挂载 `PlayerPage` 的既有集成套件共 **12 个**。G11 收录的是「必须绿且确实
> 覆盖播放器行为」的 3 个：`subtitle_flow_test`（字幕菜单 → 关闭 → 重开）、
> `danmaku_flow_test`（弹幕开关）、`phase7_resume_flow_test`（详情页 → 播放页 → 弹出路由）。
>
> 两个被排除的，理由可复核：
>
> - `mvp_a_flow_test.dart`：**基线 `ec79422` 上同样 6 通过 / 2 失败**，失败名单一致
>   （`主界面可交互…` 是被一条*测试完成后*才冒出的 `SocketException`
>   连向真实内网 `192.168.50.2:9978` 牵连；`渲染 UI 页面…:525` 找不到 `fixture` 文本）。
>   属环境问题，不是回归。放进必绿清单会让门禁**永久红**，等于没有门禁。
> - `ui_redesign_visual_flow_test.dart`：它的产出是 `.impeccable/review/*.png`，
>   跑一次就改写工作区里**已提交**的图片，不适合当回归门禁（它是证据采集）。
>
> 代价必须写明：这两个套件里的播放器路径**不在门禁保护范围内**，改动播放器页后
> 要手动跑一次。本轮已经手动跑过（基线对照见上）。

一键验收：

```powershell
pwsh -File tools/phase8/run_windows_acceptance.ps1
# 快速回归（跳过 Windows 集成测试）：
pwsh -File tools/phase8/run_windows_acceptance.ps1 -SkipIntegrationTests
```

### 6.1 G8 与 G9/G10 的必要性

**G8（截图必须可复核）**：`04` §3 的整个决策就是为了让菜单**可见于截图**。
如果实现时退回 `showMenu`，截图会与关闭态**逐字节相同**——
这是 `ui_redesign_visual_flow_test.dart:708-711` 已经记录过的"假证据"。

> **判据改过两次，两次都是实测换来的（`R108`、`R110`）。**
>
> **第一版**「菜单截图与关闭态不同字节」是**假绿**：两个状态之间至少有两处
> 像素必然变化——屏显时钟每秒跳动、视频在播放。实测 r2x1 档位在**菜单根本
> 没打开**的情况下两张截图仍差 5 字节（`menuBytes=363046 closedBytes=363041`），
> 断言照样通过。已删除。
>
> **第二版**换成「菜单必须是 harness 拍到的那个 `RepaintBoundary` 的后代」，
> 写在 `phase8_visual_flow_test.dart` 里。它不依赖像素，且恰好能区分
> 「页内 `Stack` 层」与「`Overlay` 浮层」两种实现——也就是 `04` §3 这个
> 决策本身。
>
> **第三版（现行）**补上"截图可复核"这一层：同一份代码两次跑出不同字节的
> PNG，就无法判断差异来自代码改动还是走时/滚动条。实测踩到两次——
> 屏显右上角**实时时钟**（`player-controls-r16x10.png` 的差异包围盒只有
> `(1390, 21, 1424, 31)`，约 34×10 像素，其余逐字节相同）、菜单滚到底后
> **滚动条淡出**（`jumpTo` 挂的是 300ms 的 `Timer`，而 `pumpAndSettle` 只等
> "有没有排队的帧"、立刻返回，把半透明滚动条拍进图里；r16x10 的差异是
> 菜单右缘 `(949, 232, 958, 892)` 一条 9px 宽的竖条）。
> 修法分别是 `debugOsdClockOverride` 冻结时钟、以及滚动后显式推进
> `pump(400ms)` 再截图。修好后连续两次跑 **13/13 逐字节相同**。
> `tools/phase8/verify_screenshots.py` + `manifest.txt` 把这件事变成机器检查。

**G9（平坦场）**：浮层天然诱使人加阴影。`DESIGN.md` 的 The Flat-Field Rule
明确禁止。机器扫描是唯一能防住"顺手加个 `BoxShadow`"的手段。

**G10（度量中性）**：屏显需要 14px 字号，最省事的做法是改 `textTheme`——
但那会移动所有页面里不带 `ensureVisible` 的 `tap`（`DESIGN.md` 的
The Metric-Neutral Rule 记录了实测：`bodySmall` 行高 1.33→1.65 会让
`phase5_sync_ui_test.dart` 挂 3 个用例）。门禁比对 `theme.dart` 基线。

---

## 7. 与上游的有意差异（必须逐条留痕）

| # | 差异 | 上游 | PC 端 | 理由 |
| --- | --- | --- | --- | --- |
| 1 | 时钟默认值 | `display_time` = false | **true** | PC 是"坐在电脑前"场景；全屏时任务栏不可见，时钟是真实需求（用户已确认） |
| 2 | 网速屏显 | `PlaybackSpeedMeter` 按秒采样 | **已实现**：双数据源——首选 `demuxer-cache-state` 内解析 `raw-input-rate` 字段，解析不到同拍回退 `cache-speed`；取不到显示 `—`（`02` §3.6） | **更正（两轮）**：①原文写「本轮不实现 / PC 端无字节级吞吐量 / 只覆盖代理流量会误导」，前提错在「media-kit 未暴露吞吐量」——`NativePlayer.getProperty` 能读 mpv 属性，它统计的是播放器输入流，不限于代理流量；②原实现直接读 `raw-input-rate` 也是错的——**它不是属性**（`dart:ffi` 直连 libmpv 实测 `mpv_get_property` 回 `rc = -8`，`property-list` 827 项里没有它），它只是 `demuxer-cache-state` 的 JSON 键，所以必须首选 JSON、回退 `cache-speed`。运行时验证已完成，见 `02` §3.6.4；已知局限随之改写为「仅桌面可用 / 起播首秒短暂 `—` / 是最近一次采样不是流量计」，同在该节 |
| 3 | 控制栏可见时的强制显示 | 强制显示 标题 + 分辨率 + 时钟 | **只强制时钟** | PC 顶栏已显示标题，重复是噪音（`02` §4.2） |
| 4 | 按钮配置格式 | 逗号分隔字符串 | JSON 数组（**兼容读字符串**） | PC 已有 JSON 设置文件（`03` §4.2） |
| 5 | 默认隐藏播种 | 首次运行播种 | **不播种** | PC 端 8 个可配置按钮无默认隐藏项，播种是空操作（`03` §4.5） |
| 6 | 可配置按钮数 | 32 | **9** | 只保留 PC 端有真实实现的（`03` §3.3） |
| 7 | 右键菜单 | 无 | **新增** | 桌面专属交互（`04` §2） |
| 8 | 屏显内边距 | 14dp | `AppSpace.lg` = 16px | 不引入全站第 17 个间距值（`02` §3.4） |
| 9 | 诊断面板附加列 | 设备/系统/芯片/屏幕 | 运行环境/窗口/主题 | PC 无对应物，不得伪造（`02` §3.2） |

**这 9 条必须原样出现在 `docs/phase8/evidence/` 里**，
不得让"对齐安卓"暗示逐项照搬。

---

## 8. 证据落盘（`docs/phase8/evidence/`）

**实际落盘的文件**（2026-10-20 验收后核对）：

| 文件 | 内容 |
| --- | --- |
| `01-overlay-layout.md` | 根因结构对照、V1/V2 实测矩形、**变异验证**（808 vs 900）、`pumpAndSettle` 为何不可用 |
| `02-osd.md` | 7 项开关源码、落盘原文、控制栏联动矩阵、迷你条裁剪坑、刷新循环观测缝、框架免费覆盖的部分、诊断面板实拍内容 |
| `03-button-config.md` | 8 个可配置按钮、27 个排除 id、归一化输入/输出对照、`Set` 被静默吞掉、落盘格式、配置页实测、拖动方向差异 |
| `04-context-menu.md` | 为什么必须页内 `Stack`（`Overlay` 拍不到）、**已废弃的旧判据留痕**、位置 clamp 边界值、`Esc` 机制修正与 SDK 引证 |
| `05-differences.md` | §7 的 9 条差异逐条留痕 + 2 条本轮新增差异 |
| `windows-acceptance.txt` | 一键验收**完整**原始输出（约 547 KB，含 `dart analyze`、2503 个单测、两套集成、G5/G6/G8/G9/G10/G12 全部子步骤） |
| `screenshots/manifest.txt` | 13 张截图的 SHA-256 清单（G8 逐字节校验用） |
| `screenshots/*.png` | 13 张截图（见 §8.1） |

**与计划稿的偏离（如实记录）**：计划稿曾列出 `test-run.txt` / `analyze.txt` /
`reverse-checks.txt` 三个独立文件。实际**未单独落盘**——这三项的原始输出
已完整包含在 `windows-acceptance.txt` 里（验收脚本按步骤顺序把每一步的
stdout 都写进同一个日志）。拆成三个文件只会产生三份互相可能不一致的副本。
这是一处**有意收拢**，不是遗漏。

### 8.1 截图的强制要求

沿用 `DESIGN.md:411` 的验证纪律（"背景/铺满类改动必须在多个宽高比各出一张图"）：

**实际产出的 13 张**：

| 截图 | 宽高比 | 内容 |
| --- | --- | --- |
| `player-controls-r16x10.png` / `-r2x1.png` / `-r235x1.png` | 1.6:1 / 2.0:1 / 2.35:1 | 顶栏 + 进度行 + 动作行（控制栏可见） |
| `player-menu-r16x10.png` / `-r2x1.png` / `-r235x1.png` | 同上 | 右键菜单打开（前 5 组可见） |
| `player-menu-bottom-r16x10.png` / `-r2x1.png` / `-r235x1.png` | 同上 | 菜单滚到底（全部 6 组标题可见） |
| `player-osd-r16x10.png` / `-r2x1.png` / `-r235x1.png` | 同上 | 控制栏**隐藏**态：屏显四角 + 诊断面板 7 行 + 迷你进度条 |
| `player-narrow-1024x640.png` | 1024×640 | 控制栏单行不换行 |

**计划稿列了但未单独出图的 2 项（如实记录）**：

| 计划项 | 处置 |
| --- | --- |
| 「控制栏隐藏」单独一张 | **已由 `player-osd-*.png` 覆盖**——它就是在控制栏隐藏态下拍的（屏显四角与迷你条只在隐藏态出现）。再拍一张"隐藏但屏显全关"的图没有信息量。 |
| 「亮色主题」1.6:1 一张 | **未出图**。播放器页的暗色是 `PlayerPage.build` 内部硬包的 `buildAppTheme(Brightness.dark)`，与外壳主题无关；`test/phase8_player_page_overlay_test.dart` 的第 13 条用例（无阴影、无 elevation）在暗色 `MaterialApp` 下 pump 整页，已覆盖"页面能正常构建"。**若要补，需要一条新的集成用例**——列入遗留清单，本轮不做。 |

**"菜单打开"与"菜单关闭"的截图必须字节不同**——这条**已废弃**，见 §6.1：
它在"菜单根本没打开"时也能通过（实测差 5 字节）。现行判据是
「菜单必须是 harness 拍到的那个 `RepaintBoundary` 的后代」（写在
`phase8_visual_flow_test.dart` 里），外加 G8 的清单逐字节校验。

---

## 9. 回归门禁（**必须继续绿**）

除 §5 表格的 10 条外，以下既有套件**不得**因本轮改动而变红：

| 测试文件 | 为什么可能受影响 |
| --- | --- |
| `test/phase5_sync_ui_test.dart` | 设置页新增两个区块；`formPagePadding` 影响布局 |
| `test/phase6_history_page_test.dart` | 不涉及（除非改 `AppState`） |
| `integration_test/phase5_sync_flow_test.dart` | 端到端同步；设置页改动可能影响 |
| `integration_test/live_flow_test.dart` | 直播播放器；`directUrl` 语义被屏显使用 |
| `integration_test/live_danmaku_flow_test.dart` | 直播弹幕 + 播放器页 |
| `integration_test/tmdb_playback_flow_test.dart` | 播放器页的 `Video` 查找 |
| `integration_test/parser_flow_test.dart` | 播放器页的 `Video` 查找 |

**硬约束**：`ui_preferences_store.dart` 的既有键（`lastSiteKey`/`videoFitModes`/
`themeMode`/`searchKeywords`/`searchSimilarity`/`searchThread`/`historyClickAction`）
**只能追加**，不得删除或改语义（`phase5_sync_ui_test.dart` 等可能按存在性断言）。

---

## 10. 与 Phase 7 的衔接

Phase 7 引入的实时同步与本轮**无直接依赖**，但有两处交叉：

1. **设置页改动**：本轮在 `SettingsPage` 新增「屏显」与「播放器按钮」两个区块。
   Phase 7 的同步开关也在设置页。新增区块必须插在**同步区块之后**，
   避免移动既有区块的相对位置（`test/phase5_sync_ui_test.dart` 可能按顺序断言）。
2. **`ui` 段的并发写**：本轮的 `osd` 与 `playerButtons` 两个新键走
   `writeSettingsSectionSync` + 串行队列（`ui_preferences_store.dart:336-354`），
   与 `SyncState` 的写入共享同一临界区。**不得**绕开队列直接写文件
   （Phase 7 已修复过"双写盘者互相破坏"的缺陷，见 `c918f15` 提交）。
