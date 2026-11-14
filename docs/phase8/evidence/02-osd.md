# 证据 02 · 屏显（OSD）

对应 `design/02-osd.md`。本文件记录**实测数值与落盘原文**。

---

## 1. 七项开关的默认值（源码为准）

`lib/core/osd_config.dart:58-66`：

```dart
Map<String, bool> defaultOsdFlags() => const {
      OsdFlag.title: true,
      OsdFlag.size: true,
      OsdFlag.time: true,        // PC 新增默认开（上游 false）
      OsdFlag.progress: true,
      OsdFlag.traffic: false,    // 本轮无实现
      OsdFlag.mini: false,
      OsdFlag.diagnostics: false,
    };
```

> **更正（后续变化）**：上面是当时的源码快照，`// 本轮无实现` 那句已失效。
> `traffic` 现在**已实现**（双数据源：`demuxer-cache-state` 内解析 `raw-input-rate` 字段，解析不到回退 `cache-speed`；见 `design/02` §3.6），默认值仍是 `false`，
> 但开关**可点**、下右**会渲染**。`osd_config.dart` 里那句注释也已改写为「已实现」。

与 `design/02` §5.1 的表格逐项一致（`verify_design_docs.py` 的契约快照检查会核对
`OsdFlag.values` 与该表）。

## 2. 落盘原文：缺席 = 默认，不固化

`lib/services/ui_preferences_store.dart:509-510`：

```dart
// 屏显：只有显式设置过的项才写（缺席 = 默认）。
if (_osdFlags.isNotEmpty) ui['osd'] = _osdFlags;
```

**实测**（`test/phase8_osd_persistence_test.dart`）：

| 场景 | `settings.json` 的 `ui` 段 |
| --- | --- |
| 全新安装，未动任何开关 | **没有 `osd` 键**（断言 `ui?.containsKey('osd')` 为 `isFalse`） |
| 只开了 `mini` | `"osd": {"mini": true}` —— 只有这一项，另外 6 项**都不写** |
| 写了一个非法 id `'nonsense'` | 要么没有 `osd` 段，要么有但里面没有该键（**显式断言**，不用 `if (osd is Map)` 把缺席悄悄跳过） |

第二条为什么重要：如果实现改成"总是把 7 项全写进去"，
那么默认值就被**固化**进文件了，以后改默认值对老用户无效。
测试逐项断言另外 6 个键不存在。

## 3. 与控制栏的联动（实测矩阵）

`lib/ui/player_osd.dart` 的可见性 getter：

| 元素 | 判据 | 控制栏可见时 | 控制栏隐藏时 |
| --- | --- | --- | --- |
| 时钟 | `controlsVisible \|\| flags[time]` | **强制显示** | 跟随开关 |
| 标题 | `!controlsVisible && flags[title]` | 强制隐藏 | 跟随开关 |
| 分辨率 | `!controlsVisible && flags[size]` | 强制隐藏 | 跟随开关 |
| 进度 | `!controlsVisible && flags[progress]` | 强制隐藏 | 跟随开关 |
| 迷你条 | `!controlsVisible && flags[mini]` | 强制隐藏 | 跟随开关 |
| 诊断面板 | `!controlsVisible && flags[diagnostics] && diagnostics.isNotEmpty` | 强制隐藏 | 跟随开关 |

**为什么只有时钟是"强制显示"**：见 `evidence/05-differences.md` 第 3 条。

**左上角还有一条额外的合并条件**（`player_osd.dart:99-101`）：

```dart
bool get _cornerTopLeftVisible =>
    (_titleVisible && title.isNotEmpty) || (_sizeVisible && (resolution?.isNotEmpty ?? false));
```

即：**开关开着但内容为空时，整个左上角不渲染**。
这条是 Task 6 审查时补的——原先只判开关，会在
「`size` 开 + `title` 关 + 分辨率未知」时渲染出一个空的 `Text`。

## 4. 迷你进度条：布局正确 ≠ 画得出来

`design/02` §3.3 要求底部 2dp 的进度条。**实测踩到的坑**：

第一版把迷你条放在 `Positioned(bottom: -16)`，位于一个 `Clip.hardEdge` 的
`Stack` 内，而该 `Stack` 的边界已经被 `Padding(AppSpace.lg)` 内缩到 `16..584`。
探针复现的布局矩形是**正确的**：

```
Rect.fromLTRB(0.0, 598.0, 800.0, 600.0)
```

但它落在裁剪框（`16..584`）**之外**，**一个像素都没有画出来**。
测试只断言矩形时是全绿的。

现行断言（`test/phase8_osd_layer_test.dart`）用精确矩形：

```
left 0 / right 800 / bottom 600 / height 2
```

即"贴住视口底边、通栏、2dp"，与 `design/02` §3.4「flush-to-bottom，无内边距」一致。

## 5. 刷新循环的启停（`design/02` §4.3）

`lib/ui/player_page.dart`：

```dart
bool get _osdNeedsTicker => _controlsVisible || anyOsdEnabled(widget.state.osdFlags);

void _syncOsdTimer() {
  if (_osdNeedsTicker) {
    _osdTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _osdNow = DateTime.now());
    });
  } else {
    _osdTimer?.cancel();
    _osdTimer = null;
  }
}
```

**为什么需要一个测试观测缝**：这条要求（屏显全关 + 控制栏隐藏 → 循环停止）
在 widget 树里**没有任何可观测面**。三个候选全部实测失败：

| 候选观测面 | 实测结果 |
| --- | --- |
| `transientCallbackCount == 0` | 加载态常驻 `LoadingBlock` 的 `CircularProgressIndicator`，该计数**恒 ≥1**（推进到 25 秒仍为 1） |
| 时钟文本在跳动 | 屏显全关 + 控制栏隐藏时**时钟根本不渲染**，没有文本可断言 |
| 用例结束时的"待处理定时器"不变量 | `dispose()` 里 `_osdTimer?.cancel()`，所以**空转**不会留下待处理定时器 |

因此加了 `@visibleForTesting` 观测缝（`lib/ui/player_page.dart` 文件末尾）：

```dart
@visibleForTesting
bool debugOsdTickerRunning(State<PlayerPage> state) =>
    (state as _PlayerPageState)._osdTimer?.isActive ?? false;
```

用例（`test/phase8_player_page_overlay_test.dart`「屏显全关且控制栏隐藏时定时器停止」）
断言三段：控制栏可见时**在跑** → 4 秒后隐藏 → **停了** → 再点一下唤醒 → **又跑起来**。
最后一段是反向锁：只断言"停了"的实现可以永远不启动定时器。

## 6. 框架免费覆盖的部分

"定时器**泄漏**"不需要我们断言。框架在每个 `testWidgets` 结束时自动检查
`!timersPending`（`package:flutter_test/src/binding.dart:2543`）。实测：

| 场景 | 结果 |
| --- | --- |
| 测试体内裸起不 cancel 的 `Timer.periodic` | 失败：`A Timer is still pending even after the widget tree was disposed.` |
| widget 的 `initState` 起、`dispose` 不 cancel | 同样失败（`binding.dart:2543` 的 `'!timersPending'`） |
| 正常 cancel | 通过 |

所以 G12 的判据是「**空转**」，不是「泄漏」——见 `design/05` §6 G12 的说明。

## 7. 诊断面板实测内容

`docs/phase8/evidence/screenshots/player-osd-r16x10.png`（1440×900）实拍：

- 左上：`320×180`
- 诊断面板 7 行：`结论: 正常` / `视频: 未知 320×180` / `音频: 未知 · 48000 Hz · 74 Kbps` /
  `网络: HLS(m3u8) · 127.0.0.1` / `状态: 00:05 / 00:06 · 缓冲 00:06` /
  `播放: media-kit · 1.00× · 音量 100%` / `来源: fixture · 线路一 · E3`
- 右上：`运行环境 Windows 10 Pro 10.0 (Build 22631)` / `窗口 1440×900 @1.00` / `主题 dark`
- 右上角时钟：`03:53:48`
- 底部迷你条：`00:05 / 00:06`

主列 7 行与 `design/02` §3.2 的表格逐行对应（含首行"结论"，它是条件行，
只在 `succeeded != null` 时出现）。
