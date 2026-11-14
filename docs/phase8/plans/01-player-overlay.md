# 播放器浮层改造 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把播放器控制栏从挤占布局的 `Column` 兄弟节点改成 `Stack` 浮层（消除画面缩放），并补齐屏显（OSD）、右键设置菜单、可配置的按钮排版。

**Architecture:** 四层 `Stack`：画面+弹幕 → 屏显层（`IgnorePointer`）→ 控制浮层（`AnimatedOpacity` + `IgnorePointer`）→ 右键菜单层。配置走 `settings.json` 的 `ui` 段，复用既有 `writeSettingsSectionSync` 串行队列。播放器页内部包一层恒定暗色 `Theme`，使浮层/菜单/对话框的对比度与用户主题无关。

**Tech Stack:** Flutter（Dart 3.13）、media_kit / media_kit_video、window_manager、sqlite3；测试用 flutter_test + integration_test；工具链经 `puro -e webhtv -p .` 调用。

**Spec:** `docs/phase8/design/00-player-overlay-design-index.md`（及 `01`–`05`）

> **已更正（后续变化）—— 本文件是**历史计划文档**，正文一律不改，但它有若干处会被误当成现状引用：**
>
> **`traffic`（网速屏显）已在本计划之后实现，且实现方式与本文多处描述都不同。**
> 本文把这些写成了「本轮不实现 / 开关置灰 / 副标题写明『本版本未采集网速』」，
> 而 `design/02` §3.6.2 里的第一版更正又把它写成「mpv 的 `raw-input-rate` 属性」——
> **那句也是错的**：`raw-input-rate` **不是属性**（`dart:ffi` 直连 libmpv 实测
> `mpv_get_property('raw-input-rate', MPV_FORMAT_DOUBLE)` 回 `rc = -8` = `MPV_ERROR_PROPERTY_NOT_FOUND`，
> `property-list` 的 827 项里也没有它），它只是 `demuxer-cache-state` 这个 JSON 串里的一个**键**。
>
> **现状以 `docs/phase8/design/02-osd.md` §3.6 为准**：双数据源（首选 `demuxer-cache-state` 内解析
> `raw-input-rate` 字段，解析不到同拍回退 `cache-speed`），开关**可点**，副标题
> 「取自播放引擎的网络输入速率；取不到时显示 —」。运行时验证、实测数据与已知局限都在 §3.6.4。
>
> 本文中因此**已失效**的位置（原文一律保留，供追溯当时的任务书；行号为本块加入后的当前值）：
> 第 232 行 `OsdFlag.traffic` 的注释、第 2343 行的「下右网速本轮不渲染」、
> 第 3843 行与第 3854 行的「网速开关置灰且说明未采集」用例、第 3931 行的置灰实现、
> 第 4625 行的「网速（未采集）」标签、第 6710 与 6731 行的「本版本未采集」、
> 第 6737 行的「网速**不实现**（PC 无字节级吞吐量，只覆盖代理流量会误导）」、
> 第 6792 行的「`02` §3.6 网速不实现」。

## Global Constraints

以下为项目级硬约束，**每个任务的需求都隐含包含本节**：

- **工具链**：所有 Flutter/Dart 命令必须经 `puro -e webhtv -p .` 调用，工作目录 `apps/desktop-flutter`。
  - 例：`puro -e webhtv -p . dart analyze`、`puro -e webhtv -p . flutter test`
- **四个 tooltip 精确串不得改，也不得收进菜单**：`'字幕轨'`、`'弹幕（开启）'`、`'弹幕（关闭）'`、`'全屏（F11）'`、`'更多'`。
- **`'更多'` 必须仍在 `AppBar` 内**：顶栏改浮层时**保留 `AppBar` widget 类型**，不得换成自绘 `Row`。
- **不得引入阴影或非 0 elevation**：新增/修改的 widget 中不得出现 `BoxShadow`，`elevation` 必须为 `0`。
- **不得改 Material 3 的字号与行高**：`lib/ui/theme.dart` 的 `_textTheme` 在本轮**逐字不变**。需要新字号时**就地显式指定**。
- **字重只用 400 / 700**：用 `AppWeight.body` / `AppWeight.label`（400）与 `AppWeight.title` / `AppWeight.display`（700）。**禁止 `w500` / `w600`**。
- **间距与圆角只用标度值**：`AppSpace`（4/8/12/16/24/32/48）、`AppRadius`（6/10/14/999）。不引入新散值。
- **颜色从 token 取**：`AppPalette.*` 或 `context.semanticColors.*`，不写死十六进制。
- **文本保持 `Text` / `SelectableText` 且 `.data` 非空**（`Text.rich` 会在遍历 `allWidgets` 取 `.data` 的测试里静默消失）。
- **`ui_preferences_store.dart` 的既有键只能追加**，不得删除或改语义。
- **写 `settings.json` 必须走 `writeSettingsSectionSync` + 串行队列**，不得绕开。
- **无 golden 文件**：截图是证据，不是断言。
- **测试视口**：既有测试大量使用 800×600 且不带 `ensureVisible`；净高度变化会把点击目标挤出视口。
  **可验证的要求（不是「高度不变」——那对设置页字面上不可满足，实测 +894px）**：
  改动后必须验证**既有设置页相关测试实际使用的每个视口**里、**它们各自真正 `tap` 的那个目标**
  仍然可命中。Task 10 已把这 6 个视口 × 各自目标锁进
  `test/phase8_settings_entries_test.dart` 的用例 7（最紧余量 196px @1440×2400），
  将来再往设置页加内容必须让那条用例保持绿。

---

## File Structure

| 文件 | 职责 | 动作 |
| --- | --- | --- |
| `lib/core/osd_config.dart` | 屏显 7 项开关的定义、默认值、归一化（纯函数） | 新建 |
| `lib/core/player_buttons.dart` | 9 个可配置按钮的定义、默认顺序、顺序/隐藏集归一化（纯函数） | 新建 |
| `lib/ui/player_osd.dart` | 屏显层 widget（四角 + 诊断面板 + 迷你进度条） | 新建 |
| `lib/ui/player_context_menu.dart` | 右键菜单 widget（页内 `Stack` 层，非 `Overlay`） | 新建 |
| `lib/ui/player_button_config_page.dart` | 按钮配置页（拖动重排 + 可见性开关） | 新建 |
| `lib/ui/player_overlay.dart` | 控制浮层（顶栏 + 进度行 + 动作行） | 新建 |
| `lib/ui/player_page.dart` | 组装四层 `Stack`、暗色 `Theme`、状态机 | 修改 |
| `lib/services/ui_preferences_store.dart` | `ui.osd` 与 `ui.playerButtons` 的读写 | 修改 |
| `lib/state/app_state.dart` | 暴露屏显开关与按钮配置的读写 | 修改 |
| `lib/ui/diagnostics_pages.dart` | 设置页新增「屏显」「播放器按钮」两个区块 | 修改 |

**拆分理由**：`player_page.dart` 已 2313 行。本轮新增的屏显、菜单、浮层、配置页各自是独立职责，全部塞进 `player_page.dart` 会让它超过 3500 行。按职责拆成 5 个新文件，`player_page.dart` 只负责组装与状态。

---

## Task 1: 屏显配置模型（纯逻辑）

**Files:**
- Create: `apps/desktop-flutter/lib/core/osd_config.dart`
- Test: `apps/desktop-flutter/test/phase8_osd_config_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `abstract final class OsdFlag` — 7 个开关 id 常量：`title` / `size` / `time` / `progress` / `traffic` / `mini` / `diagnostics`，以及 `static const List<String> values`
  - `Map<String, bool> defaultOsdFlags()` — 返回默认表
  - `Map<String, bool> normalizeOsdFlags(Object? raw)` — 归一化
  - `bool anyOsdEnabled(Map<String, bool> flags)` — 是否有任一项开启

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_osd_config_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';

void main() {
  group('屏显开关默认值（design/02 §5.1）', () {
    test('默认开启 标题/分辨率/时钟/播放进度', () {
      final flags = defaultOsdFlags();
      expect(flags[OsdFlag.title], isTrue);
      expect(flags[OsdFlag.size], isTrue);
      expect(flags[OsdFlag.time], isTrue);
      expect(flags[OsdFlag.progress], isTrue);
    });

    test('默认关闭 网速/迷你进度条/诊断面板', () {
      final flags = defaultOsdFlags();
      expect(flags[OsdFlag.traffic], isFalse);
      expect(flags[OsdFlag.mini], isFalse);
      expect(flags[OsdFlag.diagnostics], isFalse);
    });

    test('恰好 7 项，id 集合精确', () {
      expect(OsdFlag.values.length, 7);
      expect(defaultOsdFlags().keys.toSet(), OsdFlag.values.toSet());
    });
  });

  group('屏显开关归一化（design/02 §5.2）', () {
    test('未知键被忽略', () {
      final flags = normalizeOsdFlags({'title': false, 'nonsense': true});
      expect(flags.containsKey('nonsense'), isFalse);
      expect(flags[OsdFlag.title], isFalse);
    });

    test('缺失键补默认值', () {
      final flags = normalizeOsdFlags({'title': false});
      expect(flags.length, 7);
      expect(flags[OsdFlag.title], isFalse);
      expect(flags[OsdFlag.size], isTrue);
      expect(flags[OsdFlag.mini], isFalse);
    });

    test('非法类型回落默认值', () {
      final flags = normalizeOsdFlags({
        'title': 'yes',
        'size': 1,
        'time': null,
      });
      expect(flags[OsdFlag.title], isTrue);
      expect(flags[OsdFlag.size], isTrue);
      expect(flags[OsdFlag.time], isTrue);
    });

    // 关键用例：非 bool 值必须回落到**各自**的默认值，而不是一律 true。
    //
    // 为什么必须有这一条：上面那个测试把非 bool 值全放在默认 true 的项上，
    // 于是「回落默认」与「非 bool 就当 true」两种实现**都能通过**。
    // 一个写成 `raw[id] is bool ? raw[id] as bool : true` 的错误实现
    // 会通过全部用例，却在 traffic/mini/diagnostics 上违反
    // `docs/phase8/design/02` §5.2「只接受合法布尔值，非法值回落默认」。
    // 默认 false 的项是唯一能区分这两种实现的地方。
    test('非法类型回落到各自默认值（默认 false 的项不得变成 true）', () {
      final flags = normalizeOsdFlags({
        'traffic': 'yes',
        'mini': 1,
        'diagnostics': null,
      });
      expect(flags[OsdFlag.traffic], isFalse);
      expect(flags[OsdFlag.mini], isFalse);
      expect(flags[OsdFlag.diagnostics], isFalse);
      // 同时确认默认 true 的项没有被这次归一化牵连。
      expect(flags[OsdFlag.title], isTrue);
    });

    test('非 Map 输入整体回落默认', () {
      expect(normalizeOsdFlags('garbage'), defaultOsdFlags());
      expect(normalizeOsdFlags(null), defaultOsdFlags());
      expect(normalizeOsdFlags(42), defaultOsdFlags());
    });

    test('全部关闭时 anyOsdEnabled 为 false', () {
      final all = {for (final id in OsdFlag.values) id: false};
      expect(anyOsdEnabled(all), isFalse);
      expect(anyOsdEnabled(defaultOsdFlags()), isTrue);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
cd apps/desktop-flutter
puro -e webhtv -p . flutter test test/phase8_osd_config_test.dart
```
Expected: FAIL — `Target of URI doesn't exist: 'package:webhtv_pc/core/osd_config.dart'`

- [ ] **Step 3: 写最小实现**

创建 `apps/desktop-flutter/lib/core/osd_config.dart`：

```dart
/// 屏显（OSD）开关模型（`docs/phase8/design/02` §5）。
///
/// 纯数据 + 纯函数：不依赖 Flutter，不碰磁盘，便于单元测试直接覆盖
/// 「默认值」「归一化」「全关判定」三件事。
///
/// 上游依据：`PlayerSetting.java:562-563` 的 7 项 `getDisplayChecked()`，
/// 默认值见 `PlayerSetting.java:508-560`。
library;

/// 屏显开关的稳定 id。
///
/// 这些字符串会落盘（`settings.json` 的 `ui.osd`），**不得改名**。
abstract final class OsdFlag {
  /// 上左：标题（片名 · 第 N 集）。
  static const String title = 'title';

  /// 上左第二行：分辨率。
  static const String size = 'size';

  /// 上右：时钟。
  ///
  /// **与上游的有意差异**：上游 `display_time` 默认 false，PC 端默认 true。
  /// 理由：PC 是「坐在电脑前」的场景（`PRODUCT.md` §Users），全屏播放时
  /// 任务栏不可见，时钟是真实需求（用户 2026-10-18 确认）。
  static const String time = 'time';

  /// 下左：播放进度。
  static const String progress = 'progress';

  /// 下右：网速。
  ///
  /// **本轮无实现**（`docs/phase8/design/02` §3.6）：PC 端 `PlayerController`
  /// 没有字节级吞吐量，只覆盖本地代理流量会误导用户。
  /// 开关保留但置灰，副标题写明「本版本未采集网速」。
  static const String traffic = 'traffic';

  /// 底部 2dp 迷你进度条。
  static const String mini = 'mini';

  /// 顶部诊断面板。
  static const String diagnostics = 'diagnostics';

  /// 全部 id，顺序即配置页的展示顺序。
  static const List<String> values = [
    title,
    size,
    time,
    progress,
    traffic,
    mini,
    diagnostics,
  ];
}

/// 默认开关表。
///
/// 与上游的差异：`time` 默认 true（见 [OsdFlag.time] 的注释）。
Map<String, bool> defaultOsdFlags() => {
  OsdFlag.title: true,
  OsdFlag.size: true,
  OsdFlag.time: true,
  OsdFlag.progress: true,
  OsdFlag.traffic: false,
  OsdFlag.mini: false,
  OsdFlag.diagnostics: false,
};

/// 把任意输入归一化成完整的 7 项开关表。
///
/// 规则（`docs/phase8/design/02` §5.2）：
/// - 未知键**忽略**（不抛异常，不写入结果）；
/// - 缺失键用 [defaultOsdFlags] 补齐；
/// - 非 `bool` 的值回落默认（手改文件写成 `"yes"` / `1` / `null` 时不让状态变脏）；
/// - 非 `Map` 输入整体回落默认。
///
/// 与 `UiThemeMode.normalize` 同一语义：**只接受合法值，其余回落默认**。
Map<String, bool> normalizeOsdFlags(Object? raw) {
  final defaults = defaultOsdFlags();
  if (raw is! Map) return defaults;
  final result = <String, bool>{};
  for (final id in OsdFlag.values) {
    final value = raw[id];
    result[id] = value is bool ? value : defaults[id]!;
  }
  return result;
}

/// 是否至少有一项屏显开启。
///
/// 全关时屏显层完全隐藏且停止刷新循环（`docs/phase8/design/02` §4.3）。
bool anyOsdEnabled(Map<String, bool> flags) => flags.values.any((on) => on);
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_osd_config_test.dart
```
Expected: PASS（9 个用例）

- [ ] **Step 5: 静态检查**

Run:
```powershell
puro -e webhtv -p . dart analyze
```
Expected: `No issues found!`

- [ ] **Step 6: 提交**

```bash
git add apps/desktop-flutter/lib/core/osd_config.dart apps/desktop-flutter/test/phase8_osd_config_test.dart
git commit -m "新增：屏显开关模型（7 项定义 + 默认值 + 归一化）"
```

---

## Task 2: 按钮配置模型（纯逻辑）

**Files:**
- Create: `apps/desktop-flutter/lib/core/player_buttons.dart`
- Test: `apps/desktop-flutter/test/phase8_player_buttons_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `enum PlayerButtonGroup { transport, volume, rate, display }`
  - `class PlayerButtonSpec { final String id; final String label; final PlayerButtonGroup group; }`
  - `const List<PlayerButtonSpec> kPlayerButtons` — 恰好 9 项
  - `List<String> defaultButtonOrder()`
  - `List<String> normalizeButtonOrder(Object? raw)`
  - `Set<String> normalizeButtonHidden(Object? raw)`
  - `List<PlayerButtonSpec> resolveVisibleButtons({required List<String> order, required Set<String> hidden})`

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_player_buttons_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_buttons.dart';

void main() {
  group('按钮定义（design/03 §3.2、§5.3）', () {
    test('恰好 9 项，id 集合精确', () {
      expect(kPlayerButtons.length, 9);
      expect(
        kPlayerButtons.map((b) => b.id).toList(),
        ['prev', 'play', 'next', 'mute', 'volume', 'speed', 'line', 'episodes', 'fullscreen'],
      );
    });

    test('顶栏常驻的 subtitle/danmaku 不在可配置集合里', () {
      final ids = kPlayerButtons.map((b) => b.id).toSet();
      expect(ids.contains('subtitle'), isFalse);
      expect(ids.contains('danmaku'), isFalse);
      expect(ids.contains('video_fit'), isFalse);
      expect(ids.contains('media_info'), isFalse);
      expect(ids.contains('diagnostics'), isFalse);
    });

    test('每个 id 唯一，label 非空', () {
      final ids = kPlayerButtons.map((b) => b.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final spec in kPlayerButtons) {
        expect(spec.label.trim().isNotEmpty, isTrue);
      }
    });

    test('默认顺序就是定义顺序', () {
      expect(defaultButtonOrder(), kPlayerButtons.map((b) => b.id).toList());
    });
  });

  group('顺序归一化（design/03 §4.3）', () {
    test('非法 id 被过滤', () {
      final order = normalizeButtonOrder(['play', 'nonsense', 'prev']);
      expect(order.contains('nonsense'), isFalse);
      expect(order.first, 'play');
    });

    test('重复 id 去重', () {
      final order = normalizeButtonOrder(['play', 'play', 'prev']);
      expect(order.where((id) => id == 'play').length, 1);
    });

    test('缺失项追加到末尾（老配置 + 新按钮）', () {
      final order = normalizeButtonOrder(['play', 'prev']);
      expect(order.length, 9);
      expect(order[0], 'play');
      expect(order[1], 'prev');
      // 其余按默认顺序补齐在末尾。
      expect(order.sublist(2), defaultButtonOrder().sublist(2));
    });

    test('接受逗号分隔字符串（兼容上游格式）', () {
      final fromString = normalizeButtonOrder('play,prev,next');
      final fromList = normalizeButtonOrder(['play', 'prev', 'next']);
      expect(fromString, fromList);
    });

    // 关键用例：带空白的输入必须被 trim。
    //
    // 为什么必须有这一条：`_splitIds` 对每个 id 做 `trim()`
    // （`player_buttons.dart:162,168`），但若所有测试输入都不含空白，
    // 「不 trim」的实现能通过全部用例——变异测试实测确认了这个缺口。
    // 磁盘上的 `settings.json` 完全可能是手改的、带空格的，
    // 而 trim 正是为它存在的。
    test('带空白的输入被 trim（手改设置文件的真实形态）', () {
      // 断言 1、2 守 String 分支的 trim（`_splitIds` 的 `part.trim()`）。
      final fromSpaced = normalizeButtonOrder(' play , prev , next ');
      final fromClean = normalizeButtonOrder(['play', 'prev', 'next']);
      expect(fromSpaced, fromClean);

      final hiddenSpaced = normalizeButtonHidden(' speed , line ');
      expect(hiddenSpaced, {'speed', 'line'});

      // 断言 3 守 **List 分支**的 trim（`_splitIds` 的 `item.trim()`）。
      // 为什么必须单独有这一条：上面两条只喂 String 输入，
      // 去掉 List 分支的 trim 它们仍然通过——变异测试实测确认了这个半缺口。
      expect(
        normalizeButtonOrder([' play ', 'prev']),
        normalizeButtonOrder(['play', 'prev']),
      );
      expect(normalizeButtonHidden([' speed ', 'line']), {'speed', 'line'});

      // 只有空白的项必须被丢弃，而不是变成一个空 id。
      final withBlank = normalizeButtonOrder('play,  ,prev');
      expect(withBlank.contains(''), isFalse);
      expect(withBlank.take(2).toList(), ['play', 'prev']);
    });

    test('空/非法输入回落默认顺序', () {
      expect(normalizeButtonOrder(null), defaultButtonOrder());
      expect(normalizeButtonOrder(''), defaultButtonOrder());
      expect(normalizeButtonOrder(42), defaultButtonOrder());
      expect(normalizeButtonOrder(<String>[]), defaultButtonOrder());
    });
  });

  group('隐藏集归一化（design/03 §4.3）', () {
    test('非法 id 被过滤', () {
      final hidden = normalizeButtonHidden(['media_info', 'play']);
      expect(hidden.contains('media_info'), isFalse);
      expect(hidden.contains('play'), isTrue);
    });

    test('去重', () {
      final hidden = normalizeButtonHidden(['play', 'play']);
      expect(hidden.length, 1);
    });

    test('接受逗号分隔字符串', () {
      expect(normalizeButtonHidden('play,next'), normalizeButtonHidden(['play', 'next']));
    });

    test('空输入得到空集', () {
      expect(normalizeButtonHidden(null), isEmpty);
      expect(normalizeButtonHidden(''), isEmpty);
    });
  });

  group('可见列表解析（design/03 §5.1）', () {
    test('按 order 排序、按 hidden 过滤', () {
      final visible = resolveVisibleButtons(
        order: ['next', 'play', 'prev'],
        hidden: {'play'},
      );
      expect(visible.map((b) => b.id).toList(), ['next', 'prev']);
    });

    test('全部隐藏时返回空列表', () {
      final visible = resolveVisibleButtons(
        order: defaultButtonOrder(),
        hidden: kPlayerButtons.map((b) => b.id).toSet(),
      );
      expect(visible, isEmpty);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_player_buttons_test.dart
```
Expected: FAIL — `Target of URI doesn't exist: 'package:webhtv_pc/core/player_buttons.dart'`

- [ ] **Step 3: 写最小实现**

创建 `apps/desktop-flutter/lib/core/player_buttons.dart`：

```dart
/// 播放器按钮的排版模型（`docs/phase8/design/03`）。
///
/// 纯数据 + 纯函数：不依赖 Flutter，不碰磁盘。
///
/// 上游依据：`PlayerButtonSetting.java`。**PC 端只取可用子集**——
/// 上游 32 个按钮里，PC 端只沿用 5 个（`speed`/`prev`/`next`/`episodes`/
/// `fullscreen`），其余 27 个全部排除——它们没有真实实现，不得为了对齐而伪造入口
/// （`PRODUCT.md` §Product Principles 第 5 条「不承诺能力范围」）。
library;

/// 按钮分组。分组边界在渲染时插入一条发丝竖线（不可配置）。
enum PlayerButtonGroup {
  /// 传输：上一集 / 播放暂停 / 下一集。
  transport('传输'),

  /// 音量：静音 / 音量滑杆。
  volume('音量'),

  /// 速率与线路：倍速 / 线路 / 剧集。
  rate('速率与线路'),

  /// 显示：全屏。
  display('显示');

  const PlayerButtonGroup(this.label);

  final String label;
}

/// 一个可配置按钮的静态定义。
class PlayerButtonSpec {
  const PlayerButtonSpec({
    required this.id,
    required this.label,
    required this.group,
  });

  /// 稳定标识，落盘用。**不得改名**。
  final String id;

  /// 配置页显示的中文名。
  final String label;

  final PlayerButtonGroup group;
}

/// PC 端**可配置**的按钮全集（9 个）。
///
/// ## 为什么是 9 个而不是上游的 32 个
///
/// 上游 `PlayerButtonSetting.java:21-52` 定义 32 个 id。PC 端只沿用其中 5 个
/// （`speed` / `prev` / `next` / `episodes` / `fullscreen`），其余 27 个全部排除，
/// 因为它们**没有真实实现**——放一个点了没反应的按钮比不放更糟
/// （`DESIGN.md` 关于筛选按钮的同类教训）。
///
/// 排除清单与理由：
/// - `decode` / `player` / `play_params`：PC 只有 media-kit 一个引擎，无解码器切换
/// - `codec_capability`：无硬件解码能力探测
/// - `lut` / `karaoke` / `immersive_audio` / `timer` / `repeat`：未实现
/// - `cast`：无 DLNA / 投屏
/// - `pan_diagnostic`：无网盘专用诊断
/// - `ad_feedback`：无广告反馈
/// - `opening` / `ending`：无片头片尾跳过
/// - `parse`：解析线路由站点配置决定，不暴露手动切换
/// - `multi_thread_proxy`：代理是站点级配置，不是播放器按钮
/// - `quality`：无多清晰度（站点给的是线路，已由 `line` 覆盖）
/// - `scale`：画面比例归顶栏菜单与右键菜单，不占控制栏按钮位
/// - `reset`：PC 端「重置」语义不明确
/// - `search`：播放中搜索是独立流程，不在播放器浮层
/// - `display`：屏显开关归屏显设置（`docs/phase8/design/02` §5）
/// - `title`：标题归顶栏
/// - `change`：换源是详情页动作
/// - `text` / `audio` / `video`：轨道选择归顶栏（字幕轨）与右键菜单，
///   PC 端无独立音轨/视频轨选择 UI
/// - `danmaku`：顶栏常驻（被测试锁定），见下一节
///
/// ## PC 端新增的 4 个 id（上游没有）
///
/// - `play`：上游的播放键是**中央大按钮**（`view_control_vod.xml:219-226`），
///   不在动作行里；PC 端把它放进动作行，因为它是最常碰的按钮。
/// - `mute` / `volume`：上游音量走手势（`PlayerGesture` 的滑动），PC 无手势。
/// - `line`：上游线路切换在详情页；PC 端播放中切线路是高频动作
///   （`_playEpisode(0, overrideFlag:)` 已实现）。
///
/// ## 为什么 `subtitle` / `danmaku` 也不在里面
///
/// 它们现状在**顶栏**，且被集成测试按精确 tooltip 直接 `tap`
/// （`integration_test/subtitle_flow_test.dart:144,153`、
/// `integration_test/danmaku_flow_test.dart:156,175`）。
/// 用户一隐藏，测试就红。且顶栏只有 3 个常驻控件，**没有拥挤问题**，
/// 不需要用户来裁剪。详见 `docs/phase8/design/03` §5.3。
///
/// `video_fit` / `media_info` / `diagnostics` 是**菜单项**而不是按钮，
/// 同样不进这个集合。
const List<PlayerButtonSpec> kPlayerButtons = [
  PlayerButtonSpec(
    id: 'prev',
    label: '上一集',
    group: PlayerButtonGroup.transport,
  ),
  PlayerButtonSpec(
    id: 'play',
    label: '播放/暂停',
    group: PlayerButtonGroup.transport,
  ),
  PlayerButtonSpec(
    id: 'next',
    label: '下一集',
    group: PlayerButtonGroup.transport,
  ),
  PlayerButtonSpec(
    id: 'mute',
    label: '静音',
    group: PlayerButtonGroup.volume,
  ),
  PlayerButtonSpec(
    id: 'volume',
    label: '音量',
    group: PlayerButtonGroup.volume,
  ),
  PlayerButtonSpec(
    id: 'speed',
    label: '倍速',
    group: PlayerButtonGroup.rate,
  ),
  PlayerButtonSpec(
    id: 'line',
    label: '线路',
    group: PlayerButtonGroup.rate,
  ),
  PlayerButtonSpec(
    id: 'episodes',
    label: '剧集',
    group: PlayerButtonGroup.rate,
  ),
  PlayerButtonSpec(
    id: 'fullscreen',
    label: '全屏',
    group: PlayerButtonGroup.display,
  ),
];

/// 默认顺序 = 定义顺序。
///
/// 与改造前的实际排布一致（`player_page.dart:2144-2239`）——
/// 可配置性是**新能力**，不是重新设计。
List<String> defaultButtonOrder() =>
    kPlayerButtons.map((spec) => spec.id).toList();

bool _isKnownId(String id) => kPlayerButtons.any((spec) => spec.id == id);

/// 把任意输入拆成 id 字符串列表。
///
/// 接受两种形态：
/// - `List`（PC 端落盘格式）；
/// - 逗号分隔 `String`（上游 `PlayerButtonSetting.java:237-240` 的格式，
///   用于兼容从安卓迁移来的设置或手改过的文件）。
List<String> _splitIds(Object? raw) {
  if (raw is List) {
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
  }
  if (raw is String) {
    return [
      for (final part in raw.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }
  return const [];
}

/// 归一化按钮顺序。
///
/// **返回的是新列表，每次调用都是新实例**——`List` 的 `==` 是身份比较，
/// 所以 `normalizeButtonOrder(x) != normalizeButtonOrder(x)`。
/// 调用方做变更检测时**必须按值比较**（`listEquals` / 逐项比较），
/// 否则 `if (normalized != _order) save()` 会在每次加载时都写盘
/// （本仓库的写盘走 `writeSettingsSectionSync` + 串行队列，代价不低）。
///
/// 规则（对齐上游 `PlayerButtonSetting.getOrder()`，
/// `PlayerButtonSetting.java:210-215`）：
/// 1. 取已存顺序里**合法**的 id，去重，保持原顺序；
/// 2. 把 [kPlayerButtons] 中**不在结果里**的按默认顺序**追加到末尾**。
///
/// 第 2 步是关键：**新增按钮会自动出现在老配置里**，
/// 不会因为用户存过顺序就永久消失。
///
/// 输入为空或非法时回落 [defaultButtonOrder]。
List<String> normalizeButtonOrder(Object? raw) {
  final seen = <String>{};
  final result = <String>[];
  for (final id in _splitIds(raw)) {
    if (!_isKnownId(id)) continue;
    if (seen.add(id)) result.add(id);
  }
  for (final spec in kPlayerButtons) {
    if (seen.add(spec.id)) result.add(spec.id);
  }
  return result;
}

/// 归一化隐藏集：过滤非法 id、去重。
///
/// **只接受 `List` 与逗号分隔 `String`**，不认 `Set`——传 `Set` 会静默返回空集
/// （`_splitIds` 对非 List/String 返回 `const []`）。调用方持 `Set` 时必须先
/// `.toList()`。实测确认：`normalizeButtonHidden({'speed','line'})` → `{}`。
Set<String> normalizeButtonHidden(Object? raw) => {
  for (final id in _splitIds(raw))
    if (_isKnownId(id)) id,
};

/// 解析出**实际要渲染**的按钮列表：按 [order] 排序，按 [hidden] 过滤。
List<PlayerButtonSpec> resolveVisibleButtons({
  required List<String> order,
  required Set<String> hidden,
}) {
  final byId = {for (final spec in kPlayerButtons) spec.id: spec};
  // 用 null-aware 元素 `?expr` 而不是 `if (byId[id] case final spec?) spec,`：
  // 后者在本仓库的工具链（Dart 3.13.4 + flutter_lints 6）下会触发
  // `use_null_aware_elements`，与 Step 5 的 `No issues found!` 冲突。
  // `?expr` 形式是本仓库既有写法（common.dart:55、player_page.dart:2250、
  // core/ipc_protocol.dart:219 等 7+ 处），`case final x?` 形式一处都没有。
  return [
    for (final id in order)
      if (!hidden.contains(id)) ?byId[id],
  ];
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_player_buttons_test.dart
```
Expected: PASS（15 个用例）

- [ ] **Step 5: 静态检查**

Run: `puro -e webhtv -p . dart analyze`
Expected: `No issues found!`

- [ ] **Step 6: 提交**

```bash
git add apps/desktop-flutter/lib/core/player_buttons.dart apps/desktop-flutter/test/phase8_player_buttons_test.dart
git commit -m "新增：播放器按钮排版模型（9 项 + 顺序/隐藏集归一化）"
```

---

## Task 3: 配置持久化（`ui.osd` + `ui.playerButtons`）

**Files:**
- Modify: `apps/desktop-flutter/lib/services/ui_preferences_store.dart`
- Test: `apps/desktop-flutter/test/phase8_osd_persistence_test.dart`

**Interfaces:**
- Consumes: `normalizeOsdFlags` / `defaultOsdFlags` / `anyOsdEnabled`（Task 1）、`normalizeButtonOrder` / `normalizeButtonHidden` / `defaultButtonOrder`（Task 2）
- Produces（`UiPreferencesStore` 的新成员）：
  - `Map<String, bool> get osdFlags`
  - `bool get hasExplicitOsd`
  - `Future<bool> rememberOsdFlag(String id, bool enabled)`
  - `List<String> get buttonOrder`
  - `Set<String> get buttonHidden`
  - `bool get hasExplicitPlayerButtons`
  - `Future<bool> rememberButtonOrder(List<String> order)`
  - `Future<bool> rememberButtonHidden(Set<String> hidden)`
  - `Future<bool> resetPlayerButtons()`

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_osd_persistence_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  late Directory temp;
  late String settingsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-phase8-prefs');
    settingsPath = '${temp.path}${Platform.pathSeparator}settings.json';
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, Object?> readRaw() {
    final file = File(settingsPath);
    if (!file.existsSync()) return const {};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }

  group('屏显持久化（design/02 §5.2）', () {
    test('从未设置过时返回默认表，且不写盘', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.osdFlags, defaultOsdFlags());
      expect(store.hasExplicitOsd, isFalse);
      await store.rememberSite('muou');
      final raw = readRaw();
      final ui = raw['ui'] as Map<String, Object?>?;
      expect(ui?.containsKey('osd'), isFalse, reason: '缺席 = 默认，不得固化进文件');
    });

    // 关键用例：只写**显式设置过**的项，不得把 7 项默认值一起写盘。
    //
    // 为什么必须有这一条：上面那个用例只走了「从未设置过」路径，
    // 所以「一旦有任一显式项就把 7 项全写盘」的实现能通过它——
    // 而那正好违反 `design/02` §5.2 的「缺席 = 默认，不把默认值固化进文件」。
    // 变异测试实测确认了这个盲点（把全部 7 项写盘，8 个用例仍全绿）。
    test('只写显式设置过的项，不把默认值一起写盘', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag(OsdFlag.mini, true);

      final raw = readRaw();
      final osd = (raw['ui'] as Map)['osd'] as Map;
      expect(osd.keys.toSet(), {OsdFlag.mini}, reason: '只应有显式设置的那一项');
      expect(osd.containsKey(OsdFlag.title), isFalse);
      expect(osd.containsKey(OsdFlag.size), isFalse);
      expect(osd.containsKey(OsdFlag.time), isFalse);
      expect(osd.containsKey(OsdFlag.progress), isFalse);
      expect(osd.containsKey(OsdFlag.traffic), isFalse);
      expect(osd.containsKey(OsdFlag.diagnostics), isFalse);
    });

    // 关键用例：非法 id 必须在**写入时**被拒绝，而不是靠读取时过滤。
    //
    // 为什么必须有这一条：`osdFlags` getter 本身会过滤未知键，
    // 所以只断言 getter 分不清「写时拒绝」与「读时过滤」——
    // 变异测试实测确认：去掉 `rememberOsdFlag` 的守卫，用例仍绿。
    test('非法 id 在写入时即被拒绝（文件里不得出现该键）', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag('nonsense', true);

      // 先确认内存态没有它。
      expect(store.osdFlags.containsKey('nonsense'), isFalse);
      // 再确认**文件里**也没有它——这才是「写时拒绝」的证据。
      final raw = readRaw();
      final ui = raw['ui'] as Map<String, Object?>?;
      final osd = ui?['osd'];
      // 非法 id 被拒绝时 `_osdFlags` 仍为空，所以 `ui.osd` 可能整个缺席。
      // 这里**显式断言**「要么没有 osd 段，要么有但里面没有该键」，
      // 而不是用 `if (osd is Map)` 把缺席悄悄跳过——后者会让断言在
      // 实现改成「总是写 osd 段」时静默失效。
      if (osd != null) {
        expect(osd, isA<Map>(), reason: 'ui.osd 存在时必须是对象');
        expect(
          (osd as Map).containsKey('nonsense'),
          isFalse,
          reason: '非法 id 不得落盘（不能靠读取时过滤来掩盖）',
        );
      }
      expect(store.hasExplicitOsd, isFalse, reason: '非法 id 不应让 hasExplicitOsd 变真');
    });

    test('写入后重新 load 得到同一张表', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag(OsdFlag.mini, true);
      await store.rememberOsdFlag(OsdFlag.title, false);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.osdFlags[OsdFlag.mini], isTrue);
      expect(reloaded.osdFlags[OsdFlag.title], isFalse);
      expect(reloaded.osdFlags[OsdFlag.size], isTrue, reason: '未设置的项用默认');
      expect(reloaded.hasExplicitOsd, isTrue);
    });

    test('非法 id 被忽略，不写坏状态', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag('nonsense', true);
      expect(store.osdFlags.containsKey('nonsense'), isFalse);
    });

    test('只改 ui 段：sync 段保留', () async {
      File(settingsPath).writeAsStringSync(
        jsonEncode({
          'sync': {'token': 'keep-me'},
          'tmdb': {'enabled': true},
        }),
      );
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag(OsdFlag.diagnostics, true);

      final raw = readRaw();
      expect((raw['sync'] as Map)['token'], 'keep-me');
      expect((raw['tmdb'] as Map)['enabled'], isTrue);
    });
  });

  group('按钮配置持久化（design/03 §4.2）', () {
    test('从未设置过时返回默认顺序与空隐藏集', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.buttonOrder, defaultButtonOrder());
      expect(store.buttonHidden, isEmpty);
      expect(store.hasExplicitPlayerButtons, isFalse);
    });

    test('写入顺序与隐藏集后重新 load 得到同一结果', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberButtonOrder(['next', 'play', 'prev']);
      await store.rememberButtonHidden({'speed', 'line'});

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.buttonOrder.take(3).toList(), ['next', 'play', 'prev']);
      expect(reloaded.buttonOrder.length, 9, reason: '缺失项补全到末尾');
      expect(reloaded.buttonHidden, {'speed', 'line'});
      expect(reloaded.hasExplicitPlayerButtons, isTrue);
    });

    test('恢复默认清除两个键', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberButtonOrder(['next', 'play']);
      await store.rememberButtonHidden({'speed'});
      await store.resetPlayerButtons();

      final raw = readRaw();
      final ui = raw['ui'] as Map<String, Object?>?;
      expect(ui?.containsKey('playerButtons'), isFalse);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.buttonOrder, defaultButtonOrder());
      expect(reloaded.buttonHidden, isEmpty);
    });

    // 关键用例：`order` 为 null 时该键必须**缺席**，而不是写成 null。
    //
    // 为什么必须有这一条：`'order': ?order` 这个 null-aware 值形式
    // 恰恰只在 order == null 时才与旧写法有区别，而 round-trip 用例
    // 走的是「order 已设置」的路径，覆盖不到它。
    // （Task 3 的修复轮用一次性探针验证过，但探针按约定删除了——
    // 这里补成永久用例。）
    test('只设置 hidden 时 order 键缺席（null-aware 值的真实分支）', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberButtonHidden({'speed', 'line'});

      final raw = readRaw();
      final pb = (raw['ui'] as Map)['playerButtons'] as Map;
      expect(pb.containsKey('order'), isFalse, reason: 'order 为 null 时必须缺席');
      expect(pb['hidden'], ['line', 'speed'], reason: 'hidden 落盘时排序');

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.hasExplicitPlayerButtons, isTrue);
      expect(reloaded.buttonHidden, {'speed', 'line'});
      expect(reloaded.buttonOrder, defaultButtonOrder(), reason: '缺席 = 默认顺序');
    });

    // 关键用例：缺失项补全必须**落盘**，而不是只在 getter 里补。
    //
    // 为什么必须有这一条：`buttonOrder` getter 自己会补全缺失项，
    // 所以只断言 getter 分不清「写盘时补全」与「读取时补全」——
    // 变异测试实测确认：去掉 `rememberButtonOrder` 的补全，用例仍绿。
    test('写入时即补全缺失项（文件里的 order 长度就是 9）', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberButtonOrder(['next', 'play']);

      final raw = readRaw();
      final pb = (raw['ui'] as Map)['playerButtons'] as Map;
      final persisted = (pb['order'] as List).cast<String>();
      expect(persisted.length, 9, reason: '落盘的必须是补全后的完整顺序');
      expect(persisted.take(2).toList(), ['next', 'play']);
      expect(persisted.toSet(), defaultButtonOrder().toSet());
    });

    test('兼容逗号分隔字符串（上游格式）', () async {
      File(settingsPath).writeAsStringSync(
        jsonEncode({
          'ui': {
            'playerButtons': {'order': 'next,play', 'hidden': 'speed'},
          },
        }),
      );
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.buttonOrder.take(2).toList(), ['next', 'play']);
      expect(store.buttonHidden, {'speed'});
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_osd_persistence_test.dart
```
Expected: FAIL — `The getter 'osdFlags' isn't defined for the type 'UiPreferencesStore'`

- [ ] **Step 3: 加导入与字段**

编辑 `apps/desktop-flutter/lib/services/ui_preferences_store.dart`。

在文件顶部的 import 区（第 23-28 行附近）追加两个导入：

```dart
import '../core/history_view.dart';
import '../core/osd_config.dart';
import '../core/player_buttons.dart';
import 'log_service.dart';
import 'settings_file.dart';
```

在类内字段区（`String? _historyClickAction;` 之后、`bool _loaded = false;` 之前）追加：

```dart
  /// 屏显开关的**显式**设置；缺席的 id 用 [defaultOsdFlags] 补齐。
  ///
  /// 为什么只存显式项：与 [_themeMode] 同一理由——把默认值固化进文件会让
  /// 「从未设置过」与「设置成默认值」无法区分，也会污染既有设置文件。
  final Map<String, bool> _osdFlags = {};

  /// 按钮顺序的**显式**设置；空表示从未设置过。
  List<String>? _buttonOrder;

  /// 按钮隐藏集的**显式**设置；null 表示从未设置过。
  Set<String>? _buttonHidden;
```

- [ ] **Step 4: 加 getter 与写入方法**

在 `hasExplicitHistoryClickAction` getter（约第 128 行）之后追加：

```dart
  /// 生效的屏显开关：显式设置过的项用用户值，其余用默认。
  Map<String, bool> get osdFlags => normalizeOsdFlags(_osdFlags);

  /// 用户是否显式设置过任一屏显开关（决定要不要写盘）。
  bool get hasExplicitOsd => _osdFlags.isNotEmpty;

  /// 生效的按钮顺序：显式设置过就用它（并补全缺失项），否则用默认。
  List<String> get buttonOrder => normalizeButtonOrder(_buttonOrder);

  /// 生效的按钮隐藏集。
  ///
  /// **必须传 `List`**：Task 2 的 [normalizeButtonHidden] 只认 `List` 与逗号分隔
  /// `String`——传 `Set` 会**静默返回空集**（`_splitIds` 对非 List/String 返回
  /// `const []`）。实测确认：`normalizeButtonHidden({'speed','line'})` 得到 `{}`。
  /// 因此这里显式 `.toList()`。
  Set<String> get buttonHidden => normalizeButtonHidden(_buttonHidden?.toList());

  /// 用户是否显式设置过按钮排版（决定要不要写盘）。
  bool get hasExplicitPlayerButtons =>
      _buttonOrder != null || _buttonHidden != null;
```

在 `rememberHistoryClickAction`（约第 300-305 行）之后追加：

```dart
  /// 记住单项屏显开关。非法 id 忽略（不写坏状态）。
  Future<bool> rememberOsdFlag(String id, bool enabled) {
    if (!OsdFlag.values.contains(id)) return Future.value(true);
    if (_osdFlags[id] == enabled) return Future.value(true);
    _osdFlags[id] = enabled;
    return _persist();
  }

  /// 记住按钮顺序。输入的非法 id 会被过滤、缺失项会在读取时补全。
  Future<bool> rememberButtonOrder(List<String> order) {
    final normalized = normalizeButtonOrder(order);
    if (_listEquals(normalized, _buttonOrder ?? const [])) {
      return Future.value(true);
    }
    _buttonOrder = normalized;
    return _persist();
  }

  /// 记住按钮隐藏集。非法 id 会被过滤。
  Future<bool> rememberButtonHidden(Set<String> hidden) {
    final normalized = normalizeButtonHidden(hidden.toList());
    if (_setEquals(normalized, _buttonHidden ?? const <String>{})) {
      return Future.value(true);
    }
    _buttonHidden = normalized;
    return _persist();
  }

  /// 恢复按钮排版默认：清除两个键（对齐上游 `PlayerButtonSetting.reset()`，
  /// `PlayerButtonSetting.java:140-144`）。
  ///
  /// 上游还会清 `HIDDEN_SEEDED`；PC 端没有播种机制（无默认隐藏项），
  /// 所以只清两个键。详见 `docs/phase8/design/03` §4.5。
  Future<bool> resetPlayerButtons() {
    if (_buttonOrder == null && _buttonHidden == null) {
      return Future.value(true);
    }
    _buttonOrder = null;
    _buttonHidden = null;
    return _persist();
  }
```

在 `_listEquals`（约第 325-331 行）之后追加集合比较辅助：

```dart
  bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.every(b.contains);
```

- [ ] **Step 5: 加读取逻辑**

在 `load()` 里 `historyClickAction` 解析块（约第 194-202 行）之后追加：

```dart
          // 屏显开关：只接受 bool；非法值忽略（该项回落默认）。
          final osd = ui['osd'];
          if (osd is Map) {
            for (final id in OsdFlag.values) {
              final value = osd[id];
              if (value is bool) _osdFlags[id] = value;
            }
          }
          // 按钮排版：顺序与隐藏集各自独立；格式兼容 List 与逗号分隔字符串。
          final buttons = ui['playerButtons'];
          if (buttons is Map) {
            final order = buttons['order'];
            if (order != null) {
              final parsed = normalizeButtonOrder(order);
              // 只有真的解析出内容才视为「显式设置过」，
              // 否则一个空数组会把「从未设置」误判成「设置成默认」。
              if (_hasAnyKnownId(order)) _buttonOrder = parsed;
            }
            final hidden = buttons['hidden'];
            if (hidden != null && _hasAnyKnownId(hidden)) {
              _buttonHidden = normalizeButtonHidden(hidden);
            }
          }
```

并在 `load()` 之前（类内私有辅助区，与 `_clampSearchThread` 相邻）追加：

```dart
  /// 输入里是否至少有一个合法的按钮 id。
  ///
  /// 用于区分「显式存过（哪怕是空集）」与「文件里有个空壳对象」。
  /// 空数组/空串一律视为未设置，避免把默认值固化进文件。
  bool _hasAnyKnownId(Object? raw) {
    final ids = <String>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is String) ids.add(item.trim());
      }
    } else if (raw is String) {
      for (final part in raw.split(',')) {
        ids.add(part.trim());
      }
    }
    return ids.any(
      (id) => id.isNotEmpty && kPlayerButtons.any((spec) => spec.id == id),
    );
  }
```

- [ ] **Step 6: 加写盘逻辑**

在 `_doPersist()` 的 `mutate` 闭包内、`root['ui'] = ui;` **之前**追加：

```dart
        // 屏显：只有显式设置过的项才写（缺席 = 默认）。
        if (_osdFlags.isNotEmpty) ui['osd'] = _osdFlags;
        // 按钮排版：两个键各自独立；都缺席时整个 playerButtons 不写。
        final order = _buttonOrder;
        final hidden = _buttonHidden;
        if (order != null || hidden != null) {
          ui['playerButtons'] = <String, Object?>{
            // 用 null-aware 值 `?order` 而不是 `if (order != null) 'order': order,`：
            // 后者在本仓库工具链下触发 `use_null_aware_elements`
            // （与 R4/R8 同一类问题，实测确认）。
            'order': ?order,
            if (hidden != null) 'hidden': hidden.toList()..sort(),
          };
        }
```

- [ ] **Step 7: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_osd_persistence_test.dart
```
Expected: PASS（12 个用例）

- [ ] **Step 8: 回归既有偏好测试**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase5_sync_ui_test.dart test/phase6_history_page_test.dart
```
Expected: PASS（确认新增键没有破坏既有键）

- [ ] **Step 9: 静态检查并提交**

```powershell
puro -e webhtv -p . dart analyze
```

```bash
git add apps/desktop-flutter/lib/services/ui_preferences_store.dart apps/desktop-flutter/test/phase8_osd_persistence_test.dart
git commit -m "新增：settings.json 的 ui.osd 与 ui.playerButtons 持久化"
```

---

## Task 4: 状态层暴露（`AppState`）

**Files:**
- Modify: `apps/desktop-flutter/lib/state/app_state.dart`
- Test: `apps/desktop-flutter/test/phase8_app_state_config_test.dart`

**Interfaces:**
- Consumes: `UiPreferencesStore` 的新成员（Task 3）
- Produces（`AppState` 的新成员）：
  - `Map<String, bool> get osdFlags`
  - `Future<bool> setOsdFlag(String id, bool enabled)`
  - `List<String> get playerButtonOrder`
  - `Set<String> get playerButtonHidden`
  - `Future<bool> setPlayerButtonOrder(List<String> order)`
  - `Future<bool> setPlayerButtonHidden(Set<String> hidden)`
  - `Future<bool> resetPlayerButtons()`

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_app_state_config_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-phase8-state');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('未 bootstrap 之外的默认值正确', () {
    expect(state.osdFlags, defaultOsdFlags());
    expect(state.playerButtonOrder, defaultButtonOrder());
    expect(state.playerButtonHidden, isEmpty);
  });

  // 关键用例：未 bootstrap 时（`_uiPreferences == null`）getter 必须回落到默认值，
  // **不得抛异常**。
  //
  // 为什么必须有这一条：上面那个用例的 setUp 总是 `await state.bootstrap()`，
  // 所以 `?? default*` 三条回落分支是**死代码**——变异测试实测确认：
  // 把回落改成 `_uiPreferences!.osdFlags`（会抛）或改成 `const {}`（值错）
  // 都能通过全部 5 个用例。而 `_uiPreferences` 字段自己的注释
  // （`app_state.dart:410-415`）就说明了为什么必须回落：单元测试/工具可能
  // **不调 bootstrap** 就直接用 AppState，此时取默认值应「安静降级，
  // 而不是把页面弄崩」。
  // （注意不要引 `PRODUCT.md` 的「失败必须如实」——那条讲的是**不要静默
  // 把错误当成功**，方向与「取默认值要安全」相反，引它反而自相矛盾。）
  test('未 bootstrap 时 getter 回落默认值而不抛异常', () {
    final bare = AppState(paths: state.paths, log: LogService());
    addTearDown(bare.dispose);
    // 不调用 bootstrap()。
    expect(bare.osdFlags, defaultOsdFlags());
    expect(bare.playerButtonOrder, defaultButtonOrder());
    expect(bare.playerButtonHidden, isEmpty);
  });

  // 关键用例：写操作必须真的通知监听者。
  //
  // 为什么必须有这一条：Task 9/10/11 都依赖「用户点了开关 → 界面立刻更新」。
  // 变异测试实测确认：删掉 `setOsdFlag` 里的 `notifyListeners()`，
  // 原有用例（名字里写着「并通知」）**仍然全绿**——它只断言了值，没断言通知。
  test('四个写操作各自通知一次监听者', () async {
    var notifications = 0;
    void listener() => notifications++;
    state.addListener(listener);
    addTearDown(() => state.removeListener(listener));

    await state.setOsdFlag(OsdFlag.mini, true);
    expect(notifications, 1, reason: 'setOsdFlag 必须通知');

    await state.setPlayerButtonOrder(['next', 'play']);
    expect(notifications, 2, reason: 'setPlayerButtonOrder 必须通知');

    await state.setPlayerButtonHidden({'speed'});
    expect(notifications, 3, reason: 'setPlayerButtonHidden 必须通知');

    await state.resetPlayerButtons();
    expect(notifications, 4, reason: 'resetPlayerButtons 必须通知');
  });

  test('设置屏显开关后立即生效并通知', () async {
    await state.setOsdFlag(OsdFlag.mini, true);
    expect(state.osdFlags[OsdFlag.mini], isTrue);
  });

  test('设置按钮顺序后立即生效', () async {
    await state.setPlayerButtonOrder(['next', 'play']);
    expect(state.playerButtonOrder.take(2).toList(), ['next', 'play']);
    expect(state.playerButtonOrder.length, 9);
  });

  test('设置隐藏集后立即生效', () async {
    await state.setPlayerButtonHidden({'speed'});
    expect(state.playerButtonHidden, {'speed'});
  });

  test('恢复默认后回到默认顺序与空隐藏集', () async {
    await state.setPlayerButtonOrder(['next', 'play']);
    await state.setPlayerButtonHidden({'speed'});
    await state.resetPlayerButtons();
    expect(state.playerButtonOrder, defaultButtonOrder());
    expect(state.playerButtonHidden, isEmpty);
  });

  // 关键用例：**从未设置过**时调 reset 必须走 store 的提前返回分支
  // （`ui_preferences_store.dart:398-400`），且仍要通知监听者。
  //
  // 为什么必须有这一条：上面那个用例先设了 order 与 hidden，
  // 所以 `_buttonOrder == null && _buttonHidden == null` 这个分支**从未被走到**——
  // 变异测试实测确认：把提前返回改成 `return false;` 或删掉它，用例仍绿。
  test('从未设置过时 reset 走提前返回分支且仍通知', () async {
    var notifications = 0;
    void listener() => notifications++;
    state.addListener(listener);
    addTearDown(() => state.removeListener(listener));

    final ok = await state.resetPlayerButtons();
    expect(ok, isTrue, reason: '提前返回分支必须返回 true（幂等成功）');
    expect(notifications, 1, reason: '即使无事可做，也要通知一次');
    expect(state.playerButtonOrder, defaultButtonOrder());
    expect(state.playerButtonHidden, isEmpty);
  });

  // 关键用例：setter 的返回值必须透传 store 的结果，不能被吞成常量 true。
  //
  // 为什么必须有这一条：7 个用例里没有任何一个断言过返回值，
  // 所以把 `return ok;` 改成 `return true;` 能全绿——而调用方
  // （Task 9/10 的界面）要靠这个 bool 决定是否提示「保存失败」。
  test('setter 透传 store 的返回值', () async {
    // 正常路径：store 可用 → true。
    expect(await state.setOsdFlag(OsdFlag.mini, true), isTrue);
    expect(await state.setPlayerButtonOrder(['next', 'play']), isTrue);
    expect(await state.setPlayerButtonHidden({'speed'}), isTrue);
    expect(await state.resetPlayerButtons(), isTrue);

    // 未 bootstrap 路径：store 为 null → false（不得谎报成功）。
    final bare = AppState(paths: state.paths, log: LogService());
    addTearDown(bare.dispose);
    expect(bare.setOsdFlag(OsdFlag.mini, true), completion(isFalse));
    expect(bare.setPlayerButtonOrder(['next']), completion(isFalse));
    expect(bare.setPlayerButtonHidden({'speed'}), completion(isFalse));
    expect(bare.resetPlayerButtons(), completion(isFalse));
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_app_state_config_test.dart
```
Expected: FAIL — `The getter 'osdFlags' isn't defined for the type 'AppState'`

- [ ] **Step 3: 写实现**

编辑 `apps/desktop-flutter/lib/state/app_state.dart`。

在文件 import 区追加：

```dart
import '../core/osd_config.dart';
import '../core/player_buttons.dart';
```

在 `rememberPlayerVideoFitMode`（约第 550-563 行）之后追加：

```dart
  /// 生效的屏显开关。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时返回默认表，不让屏显失败——
  /// 与 [themeMode] 同一口径。
  Map<String, bool> get osdFlags =>
      _uiPreferences?.osdFlags ?? defaultOsdFlags();

  /// 持久化单项屏显开关。
  ///
  /// 写盘失败不影响当前会话（内存里已生效），但无论如何都通知 UI 重建——
  /// 用户刚点了开关，界面必须立刻反映选择（与 [setThemeMode] 同语义）。
  Future<bool> setOsdFlag(String id, bool enabled) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberOsdFlag(id, enabled);
    notifyListeners();
    return ok;
  }

  /// 生效的播放器按钮顺序。
  List<String> get playerButtonOrder =>
      _uiPreferences?.buttonOrder ?? defaultButtonOrder();

  /// 生效的播放器按钮隐藏集。
  Set<String> get playerButtonHidden =>
      _uiPreferences?.buttonHidden ?? const <String>{};

  /// 持久化播放器按钮顺序。
  Future<bool> setPlayerButtonOrder(List<String> order) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberButtonOrder(order);
    notifyListeners();
    return ok;
  }

  /// 持久化播放器按钮隐藏集。
  Future<bool> setPlayerButtonHidden(Set<String> hidden) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberButtonHidden(hidden);
    notifyListeners();
    return ok;
  }

  /// 恢复播放器按钮排版默认。
  Future<bool> resetPlayerButtons() async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.resetPlayerButtons();
    notifyListeners();
    return ok;
  }
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_app_state_config_test.dart
```
Expected: PASS（9 个用例）

- [ ] **Step 5: 静态检查并提交**

```powershell
puro -e webhtv -p . dart analyze
```

```bash
git add apps/desktop-flutter/lib/state/app_state.dart apps/desktop-flutter/test/phase8_app_state_config_test.dart
git commit -m "新增：AppState 暴露屏显开关与按钮排版配置"
```

---

## Task 5: 屏显取数（纯函数，供屏显层与媒体信息对话框共用）

**Files:**
- Create: `apps/desktop-flutter/lib/core/osd_diagnostics.dart`
- Test: `apps/desktop-flutter/test/phase8_osd_diagnostics_test.dart`

**Interfaces:**
- Consumes: `PlaybackDiagnostics`（既有，`lib/core/playback_diagnostics.dart`）
- Produces:
  - `class OsdDiagnosticsRow { final String label; final String value; }`
  - `List<OsdDiagnosticsRow> buildOsdDiagnostics({...})` — 主列 7 行
  - `List<OsdDiagnosticsRow> buildOsdEnvironment({...})` — 附加列（拿不到的行**不出现**）

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_osd_diagnostics_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_diagnostics.dart';
// 这个导入在 brief 的 6 个用例下**未被使用**，会让 `dart analyze` 报
// `unused_import`。**不要删掉它**——正确做法是补一个真正使用它的用例：
// 用真实的 `detectMediaFormat` + `NetworkTarget.of` 构造网络行，
// 断言带签名的 URL 的 token 不会进入屏显。这同时钉住了 Task 11 的接线契约。
import 'package:webhtv_pc/core/playback_diagnostics.dart';

void main() {
  group('屏显诊断主列（design/02 §3.2）', () {
    test('无结论时 6 行齐全且顺序固定', () {
      final rows = buildOsdDiagnostics(
        videoWidth: 3840,
        videoHeight: 2160,
        videoCodec: 'hevc',
        videoFps: 59.94,
        videoBitrate: 42000000,
        audioCodec: 'eac3',
        audioChannels: '6',
        audioSampleRate: 48000,
        audioBitrate: 640000,
        position: const Duration(minutes: 12, seconds: 34),
        duration: const Duration(hours: 1, minutes: 58, seconds: 20),
        buffered: const Duration(seconds: 6),
        rate: 1.0,
        volume: 80,
        muted: false,
        formatLabel: 'HLS (m3u8)',
        targetHost: 'example.com',
        siteKey: 'muou',
        flag: '线路一',
        episodeName: 'E3',
        // 还没有结论（例如刚起播）→ 结论行不渲染。
        succeeded: null,
        failureKind: null,
      );
      expect(rows.map((r) => r.label).toList(), [
        '视频', '音频', '网络', '状态', '播放', '来源',
      ]);
      expect(rows.first.value, contains('hevc'));
      expect(rows.first.value, contains('3840×2160'));
    });

    test('未知字段显示「未知」而不是 0 或空', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null,
        videoHeight: null,
        videoCodec: null,
        videoFps: null,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero,
        duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: '未知',
        targetHost: '',
        siteKey: null,
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      final video = rows.firstWhere((r) => r.label == '视频');
      expect(video.value, contains('未知'));
      expect(video.value.contains('0×0'), isFalse);
    });

    test('直播（duration 为 0）时状态行不显示 00:00 / 00:00', () {
      final rows = buildOsdDiagnostics(
        videoWidth: 1920,
        videoHeight: 1080,
        videoCodec: 'h264',
        videoFps: 25,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: const Duration(seconds: 5),
        duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0,
        volume: 100,
        muted: false,
        formatLabel: 'HLS (m3u8)',
        targetHost: 'live.example.com',
        siteKey: 'live',
        flag: null,
        episodeName: 'CCTV-1',
        succeeded: null,
        failureKind: null,
      );
      final state = rows.firstWhere((r) => r.label == '状态');
      expect(state.value.contains('00:00 / 00:00'), isFalse);
    });

    test('静音时播放行标注静音', () {
      final rows = buildOsdDiagnostics(
        videoWidth: 1920,
        videoHeight: 1080,
        videoCodec: 'h264',
        videoFps: 25,
        videoBitrate: null,
        audioCodec: null,
        audioChannels: null,
        audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero,
        duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.5,
        volume: 0,
        muted: true,
        formatLabel: 'MP4',
        targetHost: 'x.test',
        siteKey: 's',
        flag: null,
        episodeName: null,
        succeeded: null,
        failureKind: null,
      );
      final play = rows.firstWhere((r) => r.label == '播放');
      expect(play.value, contains('静音'));
      expect(play.value, contains('1.5'));
    });

    // 结论行（`design/02` §3.2 主列表格的**第一行**）。
    //
    // 为什么必须单独测：它是面板里最重要的一行（回答「这次播放到底成没成」），
    // 而它的三种状态（无结论 / 成功 / 失败）各自是一条独立分支。
    // 用**正向断言确切串**，不用「不含某串」——本轮的教训是
    // 否定断言会放过完全坏掉的实现（Task 5 的直播用例就是这样漏的）。
    test('结论行：成功时是「正常」，且排在第一行', () {
      final rows = buildOsdDiagnostics(
        videoWidth: 1920, videoHeight: 1080, videoCodec: 'h264',
        videoFps: 25, videoBitrate: null,
        audioCodec: null, audioChannels: null, audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero, duration: const Duration(minutes: 1),
        buffered: Duration.zero,
        rate: 1.0, volume: 100, muted: false,
        formatLabel: 'HLS (m3u8)', targetHost: 'x.test',
        siteKey: 's', flag: null, episodeName: null,
        succeeded: true, failureKind: null,
      );
      expect(rows.first.label, '结论');
      expect(rows.first.value, '正常');
      expect(rows.map((r) => r.label).toList(), [
        '结论', '视频', '音频', '网络', '状态', '播放', '来源',
      ]);
    });

    test('结论行：失败时带分类', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null, videoHeight: null, videoCodec: null,
        videoFps: null, videoBitrate: null,
        audioCodec: null, audioChannels: null, audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero, duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0, volume: 100, muted: false,
        formatLabel: '未知', targetHost: '',
        siteKey: null, flag: null, episodeName: null,
        succeeded: false, failureKind: 'timeout',
      );
      expect(rows.first.label, '结论');
      expect(rows.first.value, '失败 · timeout');
    });

    test('结论行：失败但无分类时只有「失败」', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null, videoHeight: null, videoCodec: null,
        videoFps: null, videoBitrate: null,
        audioCodec: null, audioChannels: null, audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero, duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0, volume: 100, muted: false,
        formatLabel: '未知', targetHost: '',
        siteKey: null, flag: null, episodeName: null,
        succeeded: false, failureKind: null,
      );
      expect(rows.first.value, '失败');
      expect(rows.first.value.contains('·'), isFalse, reason: '无分类时不得留分隔符');
    });

    test('结论行：succeeded 为 null 时整行不出现', () {
      final rows = buildOsdDiagnostics(
        videoWidth: null, videoHeight: null, videoCodec: null,
        videoFps: null, videoBitrate: null,
        audioCodec: null, audioChannels: null, audioSampleRate: null,
        audioBitrate: null,
        position: Duration.zero, duration: Duration.zero,
        buffered: Duration.zero,
        rate: 1.0, volume: 100, muted: false,
        formatLabel: '未知', targetHost: '',
        siteKey: null, flag: null, episodeName: null,
        succeeded: null, failureKind: null,
      );
      expect(rows.any((r) => r.label == '结论'), isFalse);
    });
  });

  group('屏显诊断附加列（design/02 §3.2）', () {
    test('拿不到的行不出现（不是显示「未知」）', () {
      final rows = buildOsdEnvironment(
        operatingSystemVersion: null,
        windowSize: null,
        devicePixelRatio: null,
        themeMode: null,
        proxyPort: null,
      );
      expect(rows, isEmpty, reason: '附加列是环境快照，一行「未知」不提供信息');
    });

    test('有值的行按固定顺序出现', () {
      final rows = buildOsdEnvironment(
        operatingSystemVersion: 'Windows 11 (10.0.26100)',
        windowSize: '1440×900',
        devicePixelRatio: 1.0,
        themeMode: 'dark',
        proxyPort: null,
      );
      expect(rows.map((r) => r.label).toList(), ['运行环境', '窗口', '主题']);
      expect(rows.first.value, contains('Windows'));
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_osd_diagnostics_test.dart
```
Expected: FAIL — `Target of URI doesn't exist: 'package:webhtv_pc/core/osd_diagnostics.dart'`

- [ ] **Step 3: 写实现**

创建 `apps/desktop-flutter/lib/core/osd_diagnostics.dart`：

```dart
/// 屏显诊断面板的取数层（`docs/phase8/design/02` §3.2）。
///
/// **纯函数**：输入是一组已经取好的原始值，输出是可渲染的行。
/// 之所以不直接吃 `PlayerController`：那样这个文件就要依赖 Flutter 与
/// media_kit，无法单测；而且媒体信息对话框（`_showMediaInfo`）需要**同一批数据**，
/// 两处必须调用同一个函数，否则会漂移（`docs/phase8/design/02` §6）。
///
/// 纪律：拿不到的字段显示「未知」，**不得**填 0 或用平均值假装
/// （`PRODUCT.md` §Product Principles 第 2 条「失败必须如实」）。
library;

/// 诊断面板的一行。
class OsdDiagnosticsRow {
  const OsdDiagnosticsRow(this.label, this.value);

  final String label;
  final String value;
}

String _duration(Duration value) {
  final total = value.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int number) => number.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

String _bitrate(num? bitsPerSecond) {
  if (bitsPerSecond == null || bitsPerSecond <= 0) return '未知';
  final bits = bitsPerSecond.toDouble();
  if (bits >= 1000000) return '${(bits / 1000000).toStringAsFixed(1)} Mbps';
  if (bits >= 1000) return '${(bits / 1000).toStringAsFixed(0)} Kbps';
  return '${bits.toStringAsFixed(0)} bps';
}

/// 主列：视频 / 音频 / 网络 / 状态 / 播放 / 来源。
///
/// 顺序固定，便于截图复核与断言。
List<OsdDiagnosticsRow> buildOsdDiagnostics({
  required int? videoWidth,
  required int? videoHeight,
  required String? videoCodec,
  required double? videoFps,
  required num? videoBitrate,
  required String? audioCodec,
  required String? audioChannels,
  required int? audioSampleRate,
  required num? audioBitrate,
  required Duration position,
  required Duration duration,
  required Duration buffered,
  required double rate,
  required double volume,
  required bool muted,
  required String formatLabel,
  required String targetHost,
  required String? siteKey,
  required String? flag,
  required String? episodeName,
  // 结论行（`design/02` §3.2 主列表格的**第一行**）。
  // `succeeded == null` 表示「还没有结论」（例如刚起播），此时**不渲染该行**。
  required bool? succeeded,
  required Object? failureKind,
}) {
  final hasSize = videoWidth != null && videoHeight != null &&
      videoWidth > 0 && videoHeight > 0;
  final video = [
    if (videoCodec != null && videoCodec.isNotEmpty) videoCodec else '未知',
    if (hasSize) '$videoWidth×$videoHeight',
    if (videoFps != null && videoFps > 0) '${videoFps.toStringAsFixed(2)} fps',
    if (videoBitrate != null && videoBitrate > 0) _bitrate(videoBitrate),
  ].join(' · ');

  final audio = [
    if (audioCodec != null && audioCodec.isNotEmpty) audioCodec else '未知',
    if (audioChannels != null && audioChannels.isNotEmpty) audioChannels,
    if (audioSampleRate != null && audioSampleRate > 0) '$audioSampleRate Hz',
    if (audioBitrate != null && audioBitrate > 0) _bitrate(audioBitrate),
  ].join(' · ');

  final network = [
    formatLabel,
    if (targetHost.isNotEmpty) targetHost,
  ].join(' · ');

  // 直播（duration <= 0）没有总时长，进度无意义 —— 不显示 `00:00 / 00:00`。
  // 上游同语义：`PlayerOsdController.java:280` 的 `player.isLive()` 判定。
  final state = duration > Duration.zero
      ? '${_duration(position)} / ${_duration(duration)} · 缓冲 ${_duration(buffered)}'
      : '直播 · 已播 ${_duration(position)}';

  final play = [
    'media-kit',
    '${rate.toStringAsFixed(2)}×',
    muted ? '静音' : '音量 ${volume.round()}%',
  ].join(' · ');

  final source = [
    if (siteKey != null && siteKey.isNotEmpty) siteKey,
    if (flag != null && flag.isNotEmpty) flag,
    if (episodeName != null && episodeName.isNotEmpty) episodeName,
  ].join(' · ');

  // 结论行（`design/02` §3.2 主列表格的第一行）。
  //
  // 为什么它是第一行：它回答「这次播放到底成没成」——面板里最重要的一行。
  // 失败路径上它真实可见：错误浮层在第 1 层、屏显在第 2 层，用户能同时看到两者。
  // `succeeded == null` 表示「还没有结论」（例如刚起播），此时**整行不渲染**。
  final conclusion = switch (succeeded) {
    null => null,
    true => '正常',
    false => failureKind == null ? '失败' : '失败 · $failureKind',
  };

  return [
    if (conclusion != null) OsdDiagnosticsRow('结论', conclusion),
    OsdDiagnosticsRow('视频', video),
    OsdDiagnosticsRow('音频', audio),
    OsdDiagnosticsRow('网络', network),
    OsdDiagnosticsRow('状态', state),
    OsdDiagnosticsRow('播放', play),
    if (source.isNotEmpty) OsdDiagnosticsRow('来源', source),
  ];
}

/// 附加列：运行环境 / 窗口 / 主题 / 代理。
///
/// **任何为 null 的行都不出现**（不是显示「未知」）。
/// 理由：附加列是「环境快照」，一行「未知」不提供任何信息，只占高度。
///
/// 与上游的差异：上游这里是设备 / 系统 / 芯片 / 屏幕 / 网络环境，
/// PC 端没有对应物，**不得伪造**（`docs/phase8/design/05` §7 第 9 条）。
List<OsdDiagnosticsRow> buildOsdEnvironment({
  required String? operatingSystemVersion,
  required String? windowSize,
  required double? devicePixelRatio,
  required String? themeMode,
  required int? proxyPort,
}) {
  return [
    if (operatingSystemVersion != null && operatingSystemVersion.isNotEmpty)
      OsdDiagnosticsRow('运行环境', operatingSystemVersion),
    if (windowSize != null && windowSize.isNotEmpty)
      OsdDiagnosticsRow(
        '窗口',
        devicePixelRatio == null
            ? windowSize
            : '$windowSize @${devicePixelRatio.toStringAsFixed(2)}',
      ),
    if (themeMode != null && themeMode.isNotEmpty)
      OsdDiagnosticsRow('主题', themeMode),
    if (proxyPort != null && proxyPort > 0)
      OsdDiagnosticsRow('本地代理', '127.0.0.1:$proxyPort'),
  ];
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_osd_diagnostics_test.dart
```
Expected: PASS（29 个用例）

- [ ] **Step 5: 静态检查并提交**

```powershell
puro -e webhtv -p . dart analyze
```

```bash
git add apps/desktop-flutter/lib/core/osd_diagnostics.dart apps/desktop-flutter/test/phase8_osd_diagnostics_test.dart
git commit -m "新增：屏显诊断取数纯函数（主列 + 附加列，拿不到的行不出现）"
```

---

## Task 6: 屏显层 widget

**Files:**
- Create: `apps/desktop-flutter/lib/ui/player_osd.dart`
- Test: `apps/desktop-flutter/test/phase8_osd_layer_test.dart`

**Interfaces:**
- Consumes: `OsdFlag` / `anyOsdEnabled`（Task 1）、`OsdDiagnosticsRow` / `buildOsdDiagnostics` / `buildOsdEnvironment`（Task 5）
- Produces:
  - `class PlayerOsdLayer extends StatelessWidget`，构造参数：
    - `required Map<String, bool> flags`
    - `required bool controlsVisible`
    - `required String title`
    - `required String? resolution`
    - `required Duration position`
    - `required Duration duration`
    - `required bool isLive`
    - `required DateTime now`
    - `required List<OsdDiagnosticsRow> diagnostics`
    - `required List<OsdDiagnosticsRow> environment`
  - `class PlayerOsdMiniProgress extends StatelessWidget`（`progress` 为 0..1）

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_osd_layer_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/osd_diagnostics.dart';
import 'package:webhtv_pc/ui/player_osd.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(body: Stack(children: [child])),
);

PlayerOsdLayer buildLayer({
  Map<String, bool>? flags,
  bool controlsVisible = false,
  bool isLive = false,
  Duration duration = const Duration(minutes: 10),
  List<OsdDiagnosticsRow> diagnostics = const [],
  List<OsdDiagnosticsRow> environment = const [],
}) => PlayerOsdLayer(
  flags: flags ?? defaultOsdFlags(),
  controlsVisible: controlsVisible,
  title: '示例剧集 · E3',
  resolution: '3840×2160',
  position: const Duration(minutes: 2, seconds: 56),
  duration: duration,
  isLive: isLive,
  now: DateTime(2026, 10, 18, 20, 30, 18),
  diagnostics: diagnostics,
  environment: environment,
);

void main() {
  testWidgets('默认开关：显示标题/分辨率/时钟/进度（design/02 §5.1）', (tester) async {
    await tester.pumpWidget(wrap(buildLayer()));
    expect(find.textContaining('示例剧集'), findsOneWidget);
    expect(find.textContaining('3840×2160'), findsOneWidget);
    expect(find.text('20:30:18'), findsOneWidget);
    expect(find.textContaining('02:56'), findsOneWidget);
  });

  testWidgets('默认关闭的项不渲染', (tester) async {
    await tester.pumpWidget(wrap(buildLayer()));
    expect(find.byType(PlayerOsdMiniProgress), findsNothing);
    expect(find.text('视频'), findsNothing, reason: '诊断面板默认关');
  });

  testWidgets('控制栏可见时：只强制时钟，进度被强制隐藏（design/02 §4.2）', (tester) async {
    await tester.pumpWidget(wrap(buildLayer(controlsVisible: true)));
    expect(find.text('20:30:18'), findsOneWidget, reason: '时钟强制显示');
    expect(find.textContaining('02:56'), findsNothing, reason: '进度强制隐藏');
  });

  testWidgets('控制栏可见时诊断面板与迷你条强制隐藏', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(
          controlsVisible: true,
          flags: {...defaultOsdFlags(), OsdFlag.diagnostics: true, OsdFlag.mini: true},
          diagnostics: const [OsdDiagnosticsRow('视频', 'hevc 3840×2160')],
        ),
      ),
    );
    expect(find.text('视频'), findsNothing);
    expect(find.byType(PlayerOsdMiniProgress), findsNothing);
  });

  testWidgets('全关时整层不渲染任何文本', (tester) async {
    final all = {for (final id in OsdFlag.values) id: false};
    await tester.pumpWidget(wrap(buildLayer(flags: all)));
    expect(find.byType(PlayerOsdLayer), findsOneWidget);
    expect(find.text('20:30:18'), findsNothing);
    expect(find.textContaining('示例剧集'), findsNothing);
  });

  testWidgets('全关但控制栏可见时仍显示时钟（design/02 §4.3）', (tester) async {
    final all = {for (final id in OsdFlag.values) id: false};
    await tester.pumpWidget(
      wrap(buildLayer(flags: all, controlsVisible: true)),
    );
    expect(find.text('20:30:18'), findsOneWidget);
  });

  testWidgets('直播时隐藏进度（design/02 §3.1）', (tester) async {
    await tester.pumpWidget(
      wrap(buildLayer(isLive: true, duration: Duration.zero)),
    );
    expect(find.textContaining('02:56 /'), findsNothing);
  });

  testWidgets('duration 为 0 时隐藏进度（不显示 00:00 / 00:00）', (tester) async {
    await tester.pumpWidget(wrap(buildLayer(duration: Duration.zero)));
    expect(find.textContaining('/ 00:00'), findsNothing);
  });

  testWidgets('诊断面板开启时渲染主列与附加列', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(
          flags: {...defaultOsdFlags(), OsdFlag.diagnostics: true},
          diagnostics: const [
            OsdDiagnosticsRow('视频', 'hevc 3840×2160'),
            OsdDiagnosticsRow('音频', 'eac3 6ch'),
          ],
          environment: const [OsdDiagnosticsRow('运行环境', 'Windows 11')],
        ),
      ),
    );
    expect(find.text('视频'), findsOneWidget);
    expect(find.textContaining('hevc'), findsOneWidget);
    expect(find.text('运行环境'), findsOneWidget);
  });

  // 关键用例：整层 IgnorePointer —— 点击必须穿透到**下层**。
  //
  // 为什么不能写成 `GestureDetector(child: buildLayer())`：
  // `GestureDetector` 默认 `HitTestBehavior.deferToChild`，子层被
  // `IgnorePointer` 时它**什么都收不到**，于是 `tapped == false`
  // ——**即使实现完全正确**。那个写法既不可证伪、也永远无法通过。
  //
  // 正确做法：把一个不透明的接收层放在屏显层**之下**，
  // 点在屏显层自己的文本上，断言点击落到了下层。
  testWidgets('整层 IgnorePointer：点击穿透到下层（design/01 §3.1）', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      wrap(
        Stack(
          children: [
            // 下层：不透明接收层。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => tapped = true,
              ),
            ),
            // 上层：屏显层（自带 IgnorePointer）。
            Positioned.fill(child: buildLayer()),
          ],
        ),
      ),
    );
    // 点在屏显层的时钟文本上——若该层没有忽略指针，这次点击会被它吃掉。
    await tester.tap(find.text('20:30:18'));
    await tester.pump();
    expect(tapped, isTrue, reason: '屏显层不得吃掉指针，点击必须落到下层');
  });

  testWidgets('屏显文本字号为 14 且带表格字形（design/02 §3.5）', (tester) async {
    await tester.pumpWidget(wrap(buildLayer()));
    final clock = tester.widget<Text>(find.text('20:30:18'));
    expect(clock.style?.fontSize, 14);
    expect(clock.style?.fontFeatures, isNotEmpty);
    expect(clock.style?.shadows, isNotEmpty, reason: '亮画面上必须描边');
  });

  testWidgets('迷你进度条颜色为星等琥珀（The One Accent Rule）', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(flags: {...defaultOsdFlags(), OsdFlag.mini: true}),
      ),
    );
    final progress = tester.widget<PlayerOsdMiniProgress>(
      find.byType(PlayerOsdMiniProgress),
    );
    // 2:56 / 10:00 —— 断言的是「按播放位置算出的比例」，不是颜色。
    // 颜色由 `FractionallySizedBox` 内的 `Container(color: ...)` 承担，
    // 在下面单独断言。
    expect(progress.progress, closeTo(176 / 600, 0.001));

    final bar = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(PlayerOsdMiniProgress),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      bar.color,
      AppPalette.magnitude,
      reason: 'DESIGN.md 的 The One Accent Rule 把「进度条」列为琥珀的合法用途',
    );
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_osd_layer_test.dart
```
Expected: FAIL — `Target of URI doesn't exist: 'package:webhtv_pc/ui/player_osd.dart'`

- [ ] **Step 3: 写实现**

创建 `apps/desktop-flutter/lib/ui/player_osd.dart`：

```dart
/// 屏显层（`docs/phase8/design/02`）。
///
/// 上游依据：`PlayerOsdController.java` 与 `view_player_osd.xml`。
///
/// 职责边界：
/// - 本文件只做「给定一组值 → 画在四角与面板上」；
/// - 取数在 `lib/core/osd_diagnostics.dart`（纯函数，可单测）；
/// - 刷新循环在 `player_page.dart`（它持有 controller 与 Timer）。
///
/// **整层 `IgnorePointer`**：屏显是纯信息层，任何情况下都不接收指针
/// （对齐上游 `view_player_osd.xml:6-7` 的 `clickable=false focusable=false`）。
library;

import 'package:flutter/material.dart';

import '../core/osd_config.dart';
import '../core/osd_diagnostics.dart';
import 'tokens.dart';

/// 屏显文本样式。
///
/// **字号显式指定 14**，不通过 `textTheme`：`DESIGN.md` 的 The Metric-Neutral Rule
/// 记录了实测——改 `textTheme` 会移动所有页面里不带 `ensureVisible` 的 `tap`。
///
/// **必须描边**：背景是任意视频帧（实测 fixture 是高饱和彩条），
/// 纯白字在亮画面上不可读。上游同做法（`view_player_osd.xml:26-29` 的 shadow）。
///
/// **必须 `tabular`**：时钟与进度每秒刷新，比例字形会让整行左右抖动。
TextStyle _osdTextStyle() => const TextStyle(
  fontSize: 14,
  height: 1.3,
  color: Colors.white,
  fontFeatures: kTabularFigures,
  shadows: [
    Shadow(color: Colors.black, offset: Offset(1.5, 1.5), blurRadius: 2),
  ],
);

String _formatDuration(Duration value) {
  final total = value.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int number) => number.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

/// 屏显层。
class PlayerOsdLayer extends StatelessWidget {
  const PlayerOsdLayer({
    super.key,
    required this.flags,
    required this.controlsVisible,
    required this.title,
    required this.resolution,
    required this.position,
    required this.duration,
    required this.isLive,
    required this.now,
    required this.diagnostics,
    required this.environment,
  });

  final Map<String, bool> flags;

  /// 控制栏是否可见。可见时强制显示时钟、强制隐藏其余
  /// （`docs/phase8/design/02` §4.2）。
  final bool controlsVisible;

  final String title;
  final String? resolution;
  final Duration position;
  final Duration duration;
  final bool isLive;
  final DateTime now;
  final List<OsdDiagnosticsRow> diagnostics;
  final List<OsdDiagnosticsRow> environment;

  /// 控制栏可见时，时钟**无视开关**强制显示。
  ///
  /// 为什么只强制时钟而不强制标题（与上游的差异）：PC 顶栏已经显示了
  /// `vodName · episodeName`，再显示一遍是噪音。
  /// 详见 `docs/phase8/design/05` §7 第 3 条。
  bool get _clockVisible => controlsVisible || (flags[OsdFlag.time] ?? false);

  bool get _titleVisible => !controlsVisible && (flags[OsdFlag.title] ?? false);

  bool get _sizeVisible => !controlsVisible && (flags[OsdFlag.size] ?? false);

  /// 上左：标题 + 分辨率（分辨率缺失时只显示标题一行，§3.1）。
  ///
  /// **必须把「有内容可显示」也算进来**：`size` 开而 `title` 关、且
  /// `resolution == null` 时，两段都为空 → `join('\n')` 得到空串 →
  /// 会渲染一个 `data == ''` 的 `Text`。那违反全站「`.data` 非空」的约束
  /// （`Text.rich` 会在遍历 `allWidgets` 取 `.data` 的测试里静默消失，
  /// 空串虽非 null 但同样是无内容占位）。
  bool get _cornerTopLeftVisible =>
      (_titleVisible && title.isNotEmpty) ||
      (_sizeVisible && (resolution?.isNotEmpty ?? false));

  /// 进度：控制栏可见时强制隐藏；直播或时长未知时也隐藏。
  bool get _progressVisible =>
      !controlsVisible &&
      (flags[OsdFlag.progress] ?? false) &&
      !isLive &&
      duration > Duration.zero;

  /// 迷你进度条：控制栏可见时强制隐藏；直播或时长未知时也隐藏。
  bool get _miniVisible =>
      !controlsVisible &&
      (flags[OsdFlag.mini] ?? false) &&
      !isLive &&
      duration > Duration.zero;

  /// 诊断面板：控制栏可见时强制隐藏。
  bool get _diagnosticsVisible =>
      !controlsVisible &&
      (flags[OsdFlag.diagnostics] ?? false) &&
      diagnostics.isNotEmpty;

  String _clockText() {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Padding(
            // 内边距用 AppSpace.lg（16px）而不是上游的 14dp：
            // 14 会成为全站第 17 个间距值（`docs/phase8/design/02` §3.4）。
            padding: const EdgeInsets.all(AppSpace.lg),
            // 竖排而不是「四个 `Positioned` 各占一角」：
            // - 诊断面板也贴顶，若与上左标题都 `top: 0`，两段文字会**互相叠印**
            //   （标题 14px 两行压在「结论」行上）；排在标题之下则不重叠；
            // - 标题与时钟之间不需要写死 96px 空档（那会引入 `AppSpace` 之外的
            //   散值），`Row` 让标题自己量出剩余宽度并用省略号收尾。
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_cornerTopLeftVisible || _clockVisible)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _cornerTopLeftVisible
                            ? Text(
                                [
                                  if (_titleVisible) title,
                                  if (_sizeVisible && resolution != null)
                                    resolution!,
                                ].join('\n'),
                                style: _osdTextStyle(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (_clockVisible) ...[
                        const SizedBox(width: AppSpace.xl),
                        Text(_clockText(), style: _osdTextStyle()),
                      ],
                    ],
                  ),
                if (_diagnosticsVisible)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.sm),
                    child: _DiagnosticsPanel(
                      rows: diagnostics,
                      environment: environment,
                    ),
                  ),
                const Spacer(),
                // 下左进度。整行宽度可用：下右网速本轮不渲染（§3.6）。
                if (_progressVisible)
                  Text(
                    '${_formatDuration(position)} / '
                    '${_formatDuration(duration)}',
                    style: _osdTextStyle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          // 迷你进度条**在 Padding 之外**：§3.4 的例外——它贴底、无内边距。
          //
          // 不能靠 `Positioned(left: -16, ...)` 把内层 Stack 顶出去取巧：
          // `Stack` 默认 `Clip.hardEdge`，负偏移只会被裁掉——实测那种写法下
          // 整条落在内层裁剪框之外（布局矩形是 `Rect.fromLTRB(0,598,800,600)`，
          // 但内层裁剪框是 16..584），画面上**什么都看不到**。
          if (_miniVisible)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: PlayerOsdMiniProgress(progress: _miniProgress),
            ),
        ],
      ),
    );
  }
}

/// 诊断面板：主列 + 附加列（`docs/phase8/design/02` §3.2）。
///
/// 与上游同构：主列权重 1.25、附加列权重 1；上游 `view_player_osd.xml:108,127`。
class _DiagnosticsPanel extends StatelessWidget {
  const _DiagnosticsPanel({required this.rows, required this.environment});

  final List<OsdDiagnosticsRow> rows;
  final List<OsdDiagnosticsRow> environment;

  @override
  Widget build(BuildContext context) {
    // 诊断面板是密集信息：字号压到 10，等宽字体，压缩字宽。
    // 上游 9sp / 横屏 10.2sp（`PlayerOsdController.java:343-347`）。
    const style = TextStyle(
      fontSize: 10,
      height: 1.35,
      color: Colors.white,
      fontFamily: 'monospace',
      shadows: [
        Shadow(color: Colors.black, offset: Offset(1.2, 1.2), blurRadius: 1.5),
      ],
    );
    Widget column(List<OsdDiagnosticsRow> data) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in data)
          Text('${row.label}  ${row.value}', style: style),
      ],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 125, child: column(rows)),
        if (environment.isNotEmpty) ...[
          const SizedBox(width: AppSpace.sm),
          Expanded(flex: 100, child: column(environment)),
        ],
      ],
    );
  }
}

/// 底部 2dp 迷你进度条（`docs/phase8/design/02` §3.3）。
///
/// 颜色用星等琥珀：`DESIGN.md` 的 The One Accent Rule 明确把「进度条」
/// 列为琥珀的合法用途之一。
class PlayerOsdMiniProgress extends StatelessWidget {
  const PlayerOsdMiniProgress({super.key, required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 2,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: progress.clamp(0.0, 1.0),
          child: Container(color: context.semanticColors.magnitude),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_osd_layer_test.dart
```
Expected: PASS（12 个用例）

- [ ] **Step 5: 静态检查并提交**

```powershell
puro -e webhtv -p . dart analyze
```

```bash
git add apps/desktop-flutter/lib/ui/player_osd.dart apps/desktop-flutter/test/phase8_osd_layer_test.dart
git commit -m "新增：屏显层 widget（四角 + 诊断面板 + 迷你进度条）"
```

---

## Task 7: 控制浮层 widget

**Files:**
- Create: `apps/desktop-flutter/lib/ui/player_overlay.dart`
- Test: `apps/desktop-flutter/test/phase8_overlay_layout_test.dart`

**Interfaces:**
- Consumes: `PlayerButtonSpec` / `PlayerButtonGroup`（Task 2）
- Produces:
  - `class PlayerControlOverlay extends StatelessWidget`，构造参数：
    - `required Widget topBar`（由 `player_page.dart` 传入 `AppBar`，保持其类型）
    - `required Widget progressRow`
    - `required List<Widget> actionButtons`
    - `required List<PlayerButtonGroup> actionGroups`（与 `actionButtons` 一一对应，用于插分隔线）
  - `class PlayerOverlayScrim extends StatelessWidget`（渐变纱）

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_overlay_layout_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/theme.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('浮层不占布局：视频区尺寸与浮层无关', (tester) async {
    await tester.pumpWidget(
      wrap(
        Stack(
          children: [
            Positioned.fill(
              child: Container(key: const ValueKey('video'), color: Colors.red),
            ),
            Positioned.fill(
              child: PlayerControlOverlay(
                topBar: const SizedBox(height: 56, key: ValueKey('top')),
                progressRow: const SizedBox(height: 32, key: ValueKey('progress')),
                actionButtons: const [SizedBox(height: 40, key: ValueKey('action'))],
                actionGroups: const [PlayerButtonGroup.transport],
              ),
            ),
          ],
        ),
      ),
    );
    final video = tester.getRect(find.byKey(const ValueKey('video')));
    expect(video.width, 800);
    expect(video.height, 600, reason: '视频区必须占满整个 body');
  });

  testWidgets('浮层内容贴顶与贴底', (tester) async {
    await tester.pumpWidget(
      wrap(
        PlayerControlOverlay(
          topBar: const SizedBox(height: 56, key: ValueKey('top')),
          progressRow: const SizedBox(height: 32, key: ValueKey('progress')),
          actionButtons: const [SizedBox(height: 40, key: ValueKey('action'))],
          actionGroups: const [PlayerButtonGroup.transport],
        ),
      ),
    );
    final top = tester.getRect(find.byKey(const ValueKey('top')));
    final action = tester.getRect(find.byKey(const ValueKey('action')));
    expect(top.top, 0, reason: '顶栏贴顶');
    // 动作行**不是**贴死 0：底部 `Padding(vertical: AppSpace.sm)` 留了 8px。
    // 用精确正向断言，不要放宽到 `closeTo(600, 0.5)`——那是必然失败的
    // （实际 592），而放宽到 600 就失去了「下边距恰好是 AppSpace.sm」的检出能力。
    expect(action.bottom, 592, reason: '动作行下沿 = 600 - AppSpace.sm');
    expect(
      600 - action.bottom,
      AppSpace.sm,
      reason: '动作行距底边恰为 AppSpace.sm（不是贴死 0，也不是别的散值）',
    );
  });

  testWidgets('分组边界插入分隔线（design/03 §5.1）', (tester) async {
    await tester.pumpWidget(
      wrap(
        PlayerControlOverlay(
          topBar: const SizedBox(height: 56),
          progressRow: const SizedBox(height: 32),
          actionButtons: const [
            SizedBox(width: 48, height: 40),
            SizedBox(width: 48, height: 40),
            SizedBox(width: 48, height: 40),
          ],
          actionGroups: const [
            PlayerButtonGroup.transport,
            PlayerButtonGroup.transport,
            PlayerButtonGroup.volume,
          ],
        ),
      ),
    );
    expect(find.byType(PlayerOverlayDivider), findsOneWidget);
  });

  testWidgets('单分组时不插分隔线', (tester) async {
    await tester.pumpWidget(
      wrap(
        PlayerControlOverlay(
          topBar: const SizedBox(height: 56),
          progressRow: const SizedBox(height: 32),
          actionButtons: const [
            SizedBox(width: 48, height: 40),
            SizedBox(width: 48, height: 40),
          ],
          actionGroups: const [
            PlayerButtonGroup.transport,
            PlayerButtonGroup.transport,
          ],
        ),
      ),
    );
    expect(find.byType(PlayerOverlayDivider), findsNothing);
  });

  testWidgets('动作行单行不换行（design/03 §5.4）', (tester) async {
    await tester.pumpWidget(
      wrap(
        PlayerControlOverlay(
          topBar: const SizedBox(height: 56),
          progressRow: const SizedBox(height: 32),
          actionButtons: [
            for (var i = 0; i < 20; i++)
              const SizedBox(width: 120, height: 40),
          ],
          actionGroups: [
            for (var i = 0; i < 20; i++) PlayerButtonGroup.transport,
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull, reason: '不得溢出');
    final row = tester.getRect(find.byType(PlayerOverlayActionRow));
    expect(row.height, lessThan(60), reason: '必须单行');
  });

  testWidgets('无阴影、无 elevation（DESIGN.md The Flat-Field Rule）', (tester) async {
    await tester.pumpWidget(
      wrap(
        PlayerControlOverlay(
          topBar: const SizedBox(height: 56),
          progressRow: const SizedBox(height: 32),
          actionButtons: const [SizedBox(width: 48, height: 40)],
          actionGroups: const [PlayerButtonGroup.transport],
        ),
      ),
    );
    final material = tester.widgetList<Material>(find.byType(Material));
    for (final m in material) {
      expect(m.elevation, 0);
    }
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_overlay_layout_test.dart
```
Expected: FAIL — `Target of URI doesn't exist: 'package:webhtv_pc/ui/player_overlay.dart'`

- [ ] **Step 3: 写实现**

创建 `apps/desktop-flutter/lib/ui/player_overlay.dart`：

```dart
/// 控制浮层（`docs/phase8/design/01` §4）。
///
/// **它不参与布局。** 调用方必须把它作为 `Stack` 的 `Positioned.fill` 子项，
/// 与画面层平级。任何把它放进 `Column`/`Row` 的写法都会让画面重新缩放
/// ——那正是本轮要修的根因。
///
/// 顶栏由调用方传入（`player_page.dart` 传 `AppBar`），因为
/// `integration_test/ui_redesign_visual_flow_test.dart:677-681` 用
/// `find.descendant(of: find.byType(AppBar), ...)` 断言「更多」按钮的位置，
/// **必须保留 `AppBar` widget 类型**。
library;

import 'package:flutter/material.dart';

import '../core/player_buttons.dart';
import 'tokens.dart';

/// 浮层的渐变纱。
///
/// 用固定深色而不是 `Theme.of(context).colorScheme.surface`：
/// 播放器背景是**视频帧**，不是应用底色。主题给的 surface 在亮色主题下是浅色，
/// 浅色纱压在高饱和画面上会让文字对比度崩掉
/// （现状 `player_page.dart:2102-2110` 的注释已经记录了这个问题）。
///
/// 播放器页整体走恒定暗色主题（`docs/phase8/design/01` §4.3），
/// 所以这里的固定深色与页面主题是一致的。
class PlayerOverlayScrim extends StatelessWidget {
  const PlayerOverlayScrim({
    super.key,
    required this.alignment,
    required this.opacity,
  });

  /// 纱最浓的一侧：顶栏用 [Alignment.topCenter]，底栏用 [Alignment.bottomCenter]。
  final Alignment alignment;

  /// 最浓处的不透明度。
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: alignment,
          end: alignment == Alignment.topCenter
              ? Alignment.bottomCenter
              : Alignment.topCenter,
          colors: [
            AppPalette.nightGround.withValues(alpha: opacity),
            AppPalette.nightGround.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

/// 分组之间的发丝竖线。
///
/// 不是按钮，不可配置、不可隐藏——它由分组边界自动插入
/// （`docs/phase8/design/03` §3.4）。
class PlayerOverlayDivider extends StatelessWidget {
  const PlayerOverlayDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      child: Container(
        width: 1,
        height: 20,
          // 颜色取 `colorScheme.outline` 而**不是** `Theme.of(context).dividerColor`。
        //
        // 两者在本仓里是不同角色：`dividerColor` 被定义为
        // `outlineVariant.withValues(alpha: 0.72)`（`theme.dart:177`），
        // 即 `#232C46@0.72`——那是「深色**表面**上再压一层更深的线」，
        // 在应用卡片里成立。但这根线画在**视频**上：底栏纱从 y=440 开始渐变，
        // 到分隔线所在高度只剩约 0.2 不透明度，画面透出约 80%；
        // 影片常见的黑边/暗场在该处接近纯黑，`#232C46` 压上去实测约 **1.2:1**，
        // 等于没画（与 Task 6 的「迷你条布局正确但画不出来」同型）。
        //
        // `outline`（暗色 `#3A4560`）是调色板里「深色底上提亮一档」的角色，
        // 压在 `nightGround` 上约 **1.9:1**：仍是一条发丝线，但暗场里读得出来，
        // 亮场里也成立。
        //
        // **这是对 `DESIGN.md` The Hairline Rule 的一处有意例外**：
        // 那条规则是针对**主题表面**写的，而本浮层的背景是**视频帧**，
        // 规则集未覆盖这一情形。已在 `docs/phase8/evidence/05-differences.md`
        // 与 `DESIGN.md` 里显式记录。回退成本一行。
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

/// 动作行：单行 + 溢出横向滚动（`docs/phase8/design/03` §5.4）。
///
/// 为什么不用 `Wrap`（现状 `player_page.dart:2139-2142`）：
/// `Wrap` 在窄窗口下换行，浮层高度随之变化，遮罩范围不可预测。
/// 上游同做法：`view_control_vod_action.xml:2-9` 的 `HorizontalScrollView`。
class PlayerOverlayActionRow extends StatelessWidget {
  const PlayerOverlayActionRow({
    super.key,
    required this.buttons,
    required this.groups,
  });

  final List<Widget> buttons;

  /// 与 [buttons] 一一对应；相邻两项分组不同时插入分隔线。
  final List<PlayerButtonGroup> groups;

  @override
  Widget build(BuildContext context) {
    assert(
      buttons.length == groups.length,
      'actionButtons 与 actionGroups 必须一一对应',
    );
    final children = <Widget>[];
    for (var i = 0; i < buttons.length; i++) {
      if (i > 0 && groups[i] != groups[i - 1]) {
        children.add(const PlayerOverlayDivider());
      }
      children.add(buttons[i]);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      // 隐藏滚动条：对齐上游 `view_control_vod_action.xml:9` 的 `scrollbars="none"`。
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      ),
    );
  }
}

/// 控制浮层：顶栏 + 进度行 + 动作行。
///
/// 三段都贴边，中间留空给画面。
class PlayerControlOverlay extends StatelessWidget {
  const PlayerControlOverlay({
    super.key,
    required this.topBar,
    required this.progressRow,
    required this.actionButtons,
    required this.actionGroups,
  });

  final Widget topBar;
  final Widget progressRow;
  final List<Widget> actionButtons;
  final List<PlayerButtonGroup> actionGroups;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 顶栏纱：从顶部渐隐。
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: SizedBox(
              height: 120,
              child: PlayerOverlayScrim(
                alignment: Alignment.topCenter,
                opacity: 0.72,
              ),
            ),
          ),
        ),
        // 底栏纱：从底部渐隐。底栏承载文字与滑杆，需要更高对比度。
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: SizedBox(
              height: 160,
              child: PlayerOverlayScrim(
                alignment: Alignment.bottomCenter,
                opacity: 0.86,
              ),
            ),
          ),
        ),
        Positioned(top: 0, left: 0, right: 0, child: topBar),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // **必须有 `stretch`**：`Column` 默认 `crossAxisAlignment: center`，
              // 那会让进度行拿到**松散**宽度约束（实测缩成 0 宽并居中，
              // 矩形 `(400,516)-(400,548)`），动作行内容也整体居中
              // （分隔线落在 x=419.5 而非 108）——违反 `design/03` §5.4
              // 「进度行始终占满宽度」。这个缺陷在「只测 y、不测 x」的用例下不可见。
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                progressRow,
                const SizedBox(height: AppSpace.xs),
                PlayerOverlayActionRow(
                  buttons: actionButtons,
                  groups: actionGroups,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_overlay_layout_test.dart
```
Expected: PASS（6 个用例）

- [ ] **Step 5: 静态检查并提交**

```powershell
puro -e webhtv -p . dart analyze
```

```bash
git add apps/desktop-flutter/lib/ui/player_overlay.dart apps/desktop-flutter/test/phase8_overlay_layout_test.dart
git commit -m "新增：控制浮层 widget（不占布局 + 分组分隔线 + 单行溢出滚动）"
```

---

## Task 8: 右键菜单 widget

**Files:**
- Create: `apps/desktop-flutter/lib/ui/player_context_menu.dart`
- Test: `apps/desktop-flutter/test/phase8_context_menu_test.dart`

**Interfaces:**
- Consumes: 无（纯 widget，动作由调用方以回调传入）
- Produces:
  - `class PlayerContextMenu extends StatefulWidget`，构造参数：
    - `required Offset anchor`（**父 `Stack` 坐标**，不是屏幕坐标；内部已 clamp）
    - `required Size viewport`
    - `required List<PlayerMenuSection> sections`（**不是 `items`**）
    - `required VoidCallback onDismiss`（**dead parameter**：本 widget 内永不调用，
      关闭由 Task 11 的兄弟遮罩 + 内层 `CallbackShortcuts` 完成；保留签名以便将来使用，
      并加测试钉住「菜单不会自己再关一次」）
  - `class PlayerMenuItem { final String id; final String label; final IconData? icon; final bool selected; final bool enabled; final List<PlayerMenuItem> children; final VoidCallback? onSelect; }`
  - `class PlayerMenuSection { final String title; final List<PlayerMenuItem> items; }`
  - `Offset clampMenuOrigin({required Offset anchor, required Size viewport, required Size menuSize})`

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_context_menu_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/theme.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(body: Stack(children: [child])),
);

void main() {
  group('位置 clamp（design/04 §5.2）', () {
    test('左上角锚点不偏移', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(10, 10),
        viewport: const Size(1440, 900),
        menuSize: const Size(240, 420),
      );
      expect(origin, const Offset(10, 10));
    });

    test('右下角锚点被拉回窗口内', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(1430, 890),
        viewport: const Size(1440, 900),
        menuSize: const Size(240, 420),
      );
      expect(origin.dx + 240, lessThanOrEqualTo(1440));
      expect(origin.dy + 420, lessThanOrEqualTo(900));
    });

    test('菜单比窗口还大时贴左上角', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(500, 500),
        viewport: const Size(200, 200),
        menuSize: const Size(240, 420),
      );
      expect(origin.dx, 8);
      expect(origin.dy, 8);
    });
  });

  group('菜单渲染（design/04 §4.1、§5.6）', () {
    testWidgets('分组标题与项都渲染', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [
                  PlayerMenuItem(id: 'play', label: '播放 / 暂停'),
                  PlayerMenuItem(id: 'prev', label: '上一集'),
                ],
              ),
              PlayerMenuSection(
                title: '速度',
                items: [PlayerMenuItem(id: 'rate_1', label: '1.0×', selected: true)],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      expect(find.text('播放'), findsOneWidget);
      expect(find.text('速度'), findsOneWidget);
      expect(find.text('播放 / 暂停'), findsOneWidget);
      expect(find.text('1.0×'), findsOneWidget);
    });

    testWidgets('禁用项不可点（design/04 §5.6）', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: [
              PlayerMenuSection(
                title: '信息',
                items: [
                  PlayerMenuItem(
                    id: 'diag',
                    label: '播放诊断',
                    enabled: false,
                    onSelect: () => tapped = true,
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      await tester.tap(find.text('播放诊断'));
      await tester.pump();
      expect(tapped, isFalse);
    });

    testWidgets('选中项用星等琥珀（design/04 §5.6）', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '速度',
                items: [
                  PlayerMenuItem(id: 'rate_1', label: '1.0×', selected: true),
                  PlayerMenuItem(id: 'rate_2', label: '1.5×'),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      final selected = tester.widget<Text>(find.text('1.0×'));
      final unselected = tester.widget<Text>(find.text('1.5×'));
      expect(selected.style?.color, isNot(unselected.style?.color));
    });

    testWidgets('点击项执行回调（不自动关闭，由调用方决定）', (tester) async {
      var tapped = '';
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: [
              PlayerMenuSection(
                title: '播放',
                items: [
                  PlayerMenuItem(
                    id: 'play',
                    label: '播放 / 暂停',
                    onSelect: () => tapped = 'play',
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      await tester.tap(find.text('播放 / 暂停'));
      await tester.pump();
      expect(tapped, 'play');
    });

    testWidgets('菜单被约束在窗口内（design/04 §5.2）', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            width: 1440,
            height: 900,
            child: Stack(
              children: [
                PlayerContextMenu(
                  anchor: const Offset(1430, 890),
                  viewport: const Size(1440, 900),
                  sections: const [
                    PlayerMenuSection(
                      title: '播放',
                      items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
                    ),
                  ],
                  onDismiss: () {},
                ),
              ],
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(PlayerContextMenu));
      expect(rect.right, lessThanOrEqualTo(1440));
      expect(rect.bottom, lessThanOrEqualTo(900));
    });

    testWidgets('无阴影、elevation 0（DESIGN.md The Zero-Elevation Rule）', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      for (final m in tester.widgetList<Material>(find.byType(Material))) {
        expect(m.elevation, 0);
      }
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_context_menu_test.dart
```
Expected: FAIL — `Target of URI doesn't exist: 'package:webhtv_pc/ui/player_context_menu.dart'`

- [ ] **Step 3: 写实现**

创建 `apps/desktop-flutter/lib/ui/player_context_menu.dart`：

```dart
/// 播放器右键菜单（`docs/phase8/design/04`）。
///
/// ## 为什么不用 `showMenu` / `MenuAnchor`（进 `Navigator` 的 `Overlay`）
///
/// 本项目的截图 harness（`integration_test/ui_redesign_visual_flow_test.dart:71-99`）
/// 取树中**第一个 `RepaintBoundary`**（`Scaffold` 那层）。`Overlay` 里的浮层
/// **拍不到**——该文件已在两处记录过这个限制（`:584-587` 的筛选面板、
/// `:708-711` 的播放器溢出菜单），并明确写了「不拿重复的图冒充新证据」。
///
/// 因此本菜单实现为**页内 `Stack` 子层**：它在 `Scaffold` 的 `RepaintBoundary`
/// 内，harness 能拍到**真实渲染**的菜单，也能断言它的矩形。
///
/// 代价是要自己实现「点外关闭」与「Esc 关闭」——两者都在 `player_page.dart` 里
/// 用几行代码完成，远小于「拿不到视觉证据」的代价。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// 菜单里的一项。
class PlayerMenuItem {
  const PlayerMenuItem({
    required this.id,
    required this.label,
    this.icon,
    this.selected = false,
    this.enabled = true,
    this.children = const [],
    this.onSelect,
  });

  final String id;
  final String label;
  final IconData? icon;

  /// 当前生效的项（当前倍速 / 当前画面模式 / 已开启的屏显项）。
  ///
  /// **必须可见**：这是隐藏式菜单最容易丢的信息
  /// （`DESIGN.md` 关于筛选面板的同类教训：「必须显示已生效」）。
  final bool selected;

  final bool enabled;

  /// 非空表示这是可**就地展开**的子菜单（`docs/phase8/design/04` §5.5）。
  final List<PlayerMenuItem> children;

  final VoidCallback? onSelect;
}

/// 菜单的一个分组。
class PlayerMenuSection {
  const PlayerMenuSection({required this.title, required this.items});

  final String title;
  final List<PlayerMenuItem> items;
}

/// 视口留白：菜单距窗口边缘的最小距离。
///
/// 用 `AppSpace.sm`（8）而不是散值：全站间距只从 `AppSpace` 标度取。
const double _viewportMargin = AppSpace.sm;

/// 把菜单左上角约束在窗口内（`docs/phase8/design/04` §5.2）。
///
/// 为什么必须 clamp：在画面右下角右键，菜单会溢出窗口、部分项不可点——
/// 这是桌面菜单的经典缺陷。
Offset clampMenuOrigin({
  required Offset anchor,
  required Size viewport,
  required Size menuSize,
}) {
  final maxX = viewport.width - menuSize.width - _viewportMargin;
  final maxY = viewport.height - menuSize.height - _viewportMargin;
  return Offset(
    _clampStart(anchor.dx, maxX),
    _clampStart(anchor.dy, maxY),
  );
}

/// 单个轴上的 clamp：可用空间不足一个留白时退回留白本身。
///
/// **不能直接用 `value.clamp(min, max)`**：菜单比窗口还大时 `max < min`，
/// Dart 的 `clamp` 会抛 `ArgumentError`。这里显式处理该情形。
double _clampStart(double value, double maxStart) => maxStart <= _viewportMargin
    ? _viewportMargin
    : value.clamp(_viewportMargin, maxStart);

/// 右键菜单。
class PlayerContextMenu extends StatefulWidget {
  const PlayerContextMenu({
    super.key,
    required this.anchor,
    required this.viewport,
    required this.sections,
    required this.onDismiss,
  });

  final Offset anchor;
  final Size viewport;
  final List<PlayerMenuSection> sections;
  final VoidCallback onDismiss;

  @override
  State<PlayerContextMenu> createState() => _PlayerContextMenuState();
}

class _PlayerContextMenuState extends State<PlayerContextMenu> {
  /// 就地展开的子菜单 id 集合。
  final Set<String> _expanded = {};

  static const double _width = 240;

  @override
  Widget build(BuildContext context) {
    final origin = clampMenuOrigin(
      anchor: widget.anchor,
      viewport: widget.viewport,
      menuSize: const Size(_width, 420),
    );
    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: _width,
      child: ConstrainedBox(
        // **`maxHeight` 必须从 `origin.dy` 往下算，不能写成
        // `viewport.height - 16`。**
        //
        // 为什么：左上角是用 **420 的估值** clamp 的，而真实高度由内容决定。
        // 若高度上限只减 16，一个 28 项的真实菜单会伸出窗口下沿——
        // 探针实测（800×600、锚点 (400,300)）：那种写法 `rect.bottom = 756`
        // （视口只有 600），改成「左上角以下」后 592。
        //
        // 更关键的是：**brief 原来的测试抓不到它**——把两种实现分别跑
        // 同一组 9 个用例，**都是全绿**，两种实现不可区分。
        // 这与 `design/04` §5.2 的全部理由（右下角右键菜单溢出、部分项不可点）
        // 直接冲突，所以必须有这条约束 + 一条会红的用例。
        constraints: BoxConstraints(
          maxHeight: math.max(
            0,
            widget.viewport.height - origin.dy - _viewportMargin,
          ),
        ),
        child: Material(
          // elevation 0 + 无阴影：DESIGN.md 的 The Zero-Elevation Rule。
          // 层级靠更亮的表面 + 发丝边表达。
          elevation: 0,
          color: AppPalette.nightSurface3.withValues(alpha: 0.96),
          borderRadius: AppRadius.mdAll,
          clipBehavior: Clip.antiAlias,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: AppRadius.mdAll,
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant
                    .withValues(alpha: 0.72),
              ),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final section in widget.sections) ...[
                    _sectionTitle(context, section.title),
                    for (final item in section.items) ..._itemWidgets(item),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.md,
      AppSpace.sm,
      AppSpace.md,
      AppSpace.xs,
    ),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  List<Widget> _itemWidgets(PlayerMenuItem item) {
    final widgets = <Widget>[_row(item)];
    if (item.children.isNotEmpty && _expanded.contains(item.id)) {
      for (final child in item.children) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: AppSpace.lg),
          child: _row(child, indent: true),
        ));
      }
    }
    return widgets;
  }

  Widget _row(PlayerMenuItem item, {bool indent = false}) {
    final theme = Theme.of(context);
    final semantic = context.semanticColors;
    final hasChildren = item.children.isNotEmpty;
    final isOpen = _expanded.contains(item.id);
    final color = !item.enabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
        : item.selected
        ? semantic.magnitude
        : theme.colorScheme.onSurface;

    return InkWell(
      onTap: !item.enabled
          ? null
          : () {
              if (hasChildren) {
                setState(() {
                  if (!_expanded.remove(item.id)) _expanded.add(item.id);
                });
                return;
              }
              item.onSelect?.call();
            },
      child: SizedBox(
        height: 36,
        child: Padding(
          padding: EdgeInsets.only(
            left: indent ? AppSpace.sm : AppSpace.md,
            right: AppSpace.md,
          ),
          child: Row(
            children: [
              if (item.icon != null) ...[
                Icon(item.icon, size: 18, color: color),
                const SizedBox(width: AppSpace.sm),
              ],
              Expanded(
                child: Text(
                  item.label,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (item.selected)
                Icon(Icons.check, size: 16, color: semantic.magnitude),
              if (hasChildren)
                Icon(
                  isOpen ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: color,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_context_menu_test.dart
```
Expected: PASS（9 个用例）

- [ ] **Step 5: 静态检查并提交**

```powershell
puro -e webhtv -p . dart analyze
```

```bash
git add apps/desktop-flutter/lib/ui/player_context_menu.dart apps/desktop-flutter/test/phase8_context_menu_test.dart
git commit -m "新增：播放器右键菜单 widget（页内 Stack 层，可截图）"
```

---

## Task 9: 按钮配置页

**Files:**
- Create: `apps/desktop-flutter/lib/ui/player_button_config_page.dart`
- Test: `apps/desktop-flutter/test/phase8_button_config_page_test.dart`

**Interfaces:**
- Consumes: `kPlayerButtons` / `PlayerButtonSpec` / `PlayerButtonGroup`（Task 2）；`AppState.setPlayerButtonOrder` / `setPlayerButtonHidden` / `resetPlayerButtons`（Task 4）
- Produces: `class PlayerButtonConfigPage extends StatefulWidget`，构造参数 `required AppState state`

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_button_config_page_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_button_config_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-phase8-btnpage');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: PlayerButtonConfigPage(state: state),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('列出全部 9 个按钮与中文名', (tester) async {
    await pumpPage(tester);
    for (final spec in kPlayerButtons) {
      expect(find.text(spec.label), findsWidgets, reason: '缺少「${spec.label}」');
    }
  });

  testWidgets('显示分组标签', (tester) async {
    await pumpPage(tester);
    expect(find.text(PlayerButtonGroup.transport.label), findsWidgets);
    expect(find.text(PlayerButtonGroup.volume.label), findsWidgets);
    expect(find.text(PlayerButtonGroup.rate.label), findsWidgets);
    expect(find.text(PlayerButtonGroup.display.label), findsWidgets);
  });

  testWidgets('切换开关会持久化隐藏集', (tester) async {
    await pumpPage(tester);
    final toggle = find.byKey(const ValueKey('button-visible-speed'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(state.playerButtonHidden.contains('speed'), isTrue);
  });

  testWidgets('恢复默认需二次确认（design/03 §6.2）', (tester) async {
    await state.setPlayerButtonOrder(['next', 'play']);
    await state.setPlayerButtonHidden({'speed'});
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('player-buttons-reset')));
    await tester.pumpAndSettle();
    // 第一次点击只弹确认框，不改状态。
    expect(find.text('恢复默认'), findsWidgets);
    expect(state.playerButtonHidden.contains('speed'), isTrue);

    await tester.tap(find.text('确认恢复'));
    await tester.pumpAndSettle();
    expect(state.playerButtonHidden, isEmpty);
    expect(state.playerButtonOrder, defaultButtonOrder());
  });

  testWidgets('预览行反映当前顺序', (tester) async {
    await state.setPlayerButtonOrder(['next', 'play', 'prev']);
    await pumpPage(tester);
    final preview = find.byKey(const ValueKey('player-buttons-preview'));
    expect(preview, findsOneWidget);
    final text = tester.widget<Text>(preview).data ?? '';
    expect(text.indexOf('下一集'), lessThan(text.indexOf('播放/暂停')));
  });

  testWidgets('拖动重排会持久化顺序', (tester) async {
    await pumpPage(tester);
    final handle = find.byKey(const ValueKey('button-handle-play'));
    expect(handle, findsOneWidget);
    // 把「播放/暂停」向上拖一格。
    await tester.drag(handle, const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(state.playerButtonOrder.first, 'play');
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_button_config_page_test.dart
```
Expected: FAIL — `Target of URI doesn't exist: 'package:webhtv_pc/ui/player_button_config_page.dart'`

- [ ] **Step 3: 写实现**

创建 `apps/desktop-flutter/lib/ui/player_button_config_page.dart`：

```dart
/// 播放器按钮配置页（`docs/phase8/design/03` §6）。
///
/// 上游依据：`PlayerButtonConfigDialog.java`（可重排列表 + 可见性开关）。
///
/// 入口有两个（`docs/phase8/design/00` §5 第 10 条要求非右键的等价路径）：
/// - 设置页 → 「播放器按钮」；
/// - 播放器右键菜单 → 「控制栏按钮…」。
library;

import 'package:flutter/material.dart';

import '../core/player_buttons.dart';
import '../state/app_state.dart';
import 'tokens.dart';

class PlayerButtonConfigPage extends StatefulWidget {
  const PlayerButtonConfigPage({super.key, required this.state});

  final AppState state;

  @override
  State<PlayerButtonConfigPage> createState() => _PlayerButtonConfigPageState();
}

class _PlayerButtonConfigPageState extends State<PlayerButtonConfigPage> {
  late List<String> _order;

  @override
  void initState() {
    super.initState();
    _order = List.of(widget.state.playerButtonOrder);
  }

  Set<String> get _hidden => widget.state.playerButtonHidden;

  Future<void> _persistOrder() async {
    await widget.state.setPlayerButtonOrder(_order);
  }

  Future<void> _toggle(String id, bool visible) async {
    final next = Set<String>.of(_hidden);
    if (visible) {
      next.remove(id);
    } else {
      next.add(id);
    }
    await widget.state.setPlayerButtonHidden(next);
    if (mounted) setState(() {});
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复默认'),
        content: const Text('将按钮顺序与显示状态恢复为默认值。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.state.resetPlayerButtons();
    if (!mounted) return;
    setState(() => _order = List.of(widget.state.playerButtonOrder));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byId = {for (final spec in kPlayerButtons) spec.id: spec};
    return Scaffold(
      appBar: AppBar(title: const Text('播放器按钮')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.md,
              AppSpace.lg,
              AppSpace.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '拖动调整顺序，开关控制是否显示。',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpace.sm),
                // 预览行：不离开页面就能看到结果。
                // 不做真实的控制栏预览——那需要把播放器状态搬进来，成本远超收益。
                Text(
                  _order
                      .where((id) => !_hidden.contains(id))
                      .map((id) => byId[id]?.label ?? id)
                      .join('  ·  '),
                  key: const ValueKey('player-buttons-preview'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
              itemCount: _order.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final moved = _order.removeAt(oldIndex);
                  _order.insert(newIndex, moved);
                });
                _persistOrder();
              },
              itemBuilder: (context, index) {
                final id = _order[index];
                final spec = byId[id];
                if (spec == null) return const SizedBox.shrink();
                return _row(context, spec, index);
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  key: const ValueKey('player-buttons-reset'),
                  onPressed: _confirmReset,
                  child: const Text('恢复默认'),
                ),
                const SizedBox(width: AppSpace.sm),
                FilledButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, PlayerButtonSpec spec, int index) {
    final theme = Theme.of(context);
    final visible = !_hidden.contains(spec.id);
    return ListTile(
      key: ValueKey('button-row-${spec.id}'),
      leading: ReorderableDragStartListener(
        index: index,
        child: Icon(
          Icons.drag_handle,
          key: ValueKey('button-handle-${spec.id}'),
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      title: Text(spec.label),
      subtitle: Text(
        spec.group.label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Switch(
        key: ValueKey('button-visible-${spec.id}'),
        value: visible,
        onChanged: (value) => _toggle(spec.id, value),
      ),
    );
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_button_config_page_test.dart
```
Expected: PASS（6 个用例）

**若 `拖动重排` 用例失败**：`tester.drag` 在 `ReorderableListView` 上需要先 `longPress` 或使用 `ReorderableDragStartListener`（本实现已用后者，drag 应直接生效）。若仍失败，改为 `TestGesture`：

```dart
final gesture = await tester.startGesture(tester.getCenter(handle));
await tester.pump(kLongPressTimeout + kPressTimeout);
await gesture.moveBy(const Offset(0, -60));
await tester.pump();
await gesture.up();
await tester.pumpAndSettle();
```

- [ ] **Step 5: 静态检查并提交**

```powershell
puro -e webhtv -p . dart analyze
```

```bash
git add apps/desktop-flutter/lib/ui/player_button_config_page.dart apps/desktop-flutter/test/phase8_button_config_page_test.dart
git commit -m "新增：播放器按钮配置页（拖动重排 + 可见性开关 + 恢复默认）"
```

---

## Task 10: 设置页新增两个入口

**Files:**
- Modify: `apps/desktop-flutter/lib/ui/diagnostics_pages.dart`
- Test: `apps/desktop-flutter/test/phase8_settings_entries_test.dart`

**Interfaces:**
- Consumes: `PlayerButtonConfigPage`（Task 9）、`OsdFlag` / `defaultOsdFlags`（Task 1）、`AppState.setOsdFlag`（Task 4）
- Produces: 设置页新增两个区块，`ValueKey` 为 `settings-osd` 与 `settings-player-buttons`

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_settings_entries_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/player_button_config_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-phase8-settings');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: SettingsPage(state: state)),
      ),
    );
    await tester.pump();
  }

  testWidgets('屏显区块存在，7 项开关齐全（design/02 §5.1）', (tester) async {
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-osd')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('settings-osd')), findsOneWidget);
    for (final id in OsdFlag.values) {
      expect(
        find.byKey(ValueKey('settings-osd-$id')),
        findsOneWidget,
        reason: '缺少屏显开关「$id」',
      );
    }
  });

  testWidgets('网速开关置灰且说明未采集（design/02 §5.1）', (tester) async {
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-osd')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(ValueKey('settings-osd-${OsdFlag.traffic}')),
    );
    expect(toggle.onChanged, isNull, reason: '未实现的开关必须置灰');
    expect(find.textContaining('未采集网速'), findsWidgets);
  });

  testWidgets('切换屏显开关会持久化', (tester) async {
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-osd')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(ValueKey('settings-osd-${OsdFlag.mini}')));
    await tester.pumpAndSettle();
    expect(state.osdFlags[OsdFlag.mini], isTrue);
  });

  testWidgets('播放器按钮入口可进入配置页', (tester) async {
    await pumpSettings(tester);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-player-buttons')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('settings-player-buttons')));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerButtonConfigPage), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_settings_entries_test.dart
```
Expected: FAIL — `Could not find the key 'settings-osd'`

- [ ] **Step 3: 写实现**

编辑 `apps/desktop-flutter/lib/ui/diagnostics_pages.dart`。

在 import 区追加：

```dart
import '../core/osd_config.dart';
import 'player_button_config_page.dart';
```

在 `SettingsPage.build` 的 `ListView` children 里，**紧接搜索区块之后**（即 `state.setSearchThread` 那个 `FilledButton.tonalIcon` 与其说明文字之后、下一个 `Divider` 之前）追加：

```dart
        const Divider(height: 32),
        // 播放器区块（`docs/phase8/design/02` §5、`design/03` §6.1）。
        //
        // 为什么放在设置页：屏显开关与按钮排版是**一次定好、长期生效**的偏好，
        // 与主题、历史点击行为同类。同时它们也是**非右键的等价路径**
        // （`docs/phase8/design/00` §5 第 10 条：右键菜单不得成为唯一入口）。
        //
        // 位置：插在搜索区块之后，**不移动**既有区块的相对顺序
        // （`test/phase5_sync_ui_test.dart` 可能按顺序断言）。
        Text('播放器', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '屏显（OSD）：播放画面上叠加的信息角标。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Column(
          key: const ValueKey('settings-osd'),
          children: [
            for (final id in OsdFlag.values)
              SwitchListTile(
                key: ValueKey('settings-osd-$id'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(_osdLabel(id)),
                subtitle: id == OsdFlag.traffic
                    ? const Text('本版本未采集网速')
                    : null,
                // 网速未实现 → 置灰。**不得**让开关可点却无效果：
                // 那比没有开关更糟（`DESIGN.md` 关于筛选按钮的同类教训）。
                value: state.osdFlags[id] ?? false,
                onChanged: id == OsdFlag.traffic
                    ? null
                    : (value) => state.setOsdFlag(id, value),
              ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('settings-player-buttons'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PlayerButtonConfigPage(state: state),
            ),
          ),
          icon: const Icon(Icons.tune),
          label: const Text('播放器按钮排版'),
        ),
        const SizedBox(height: 8),
        Text(
          '调整底部控制栏的按钮顺序与显示状态。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
```

在文件末尾（`SettingsPage` 类之外）追加中文名映射：

```dart
/// 屏显开关的中文名（`docs/phase8/design/02` §5.1）。
String _osdLabel(String id) {
  switch (id) {
    case OsdFlag.title:
      return '标题';
    case OsdFlag.size:
      return '分辨率';
    case OsdFlag.time:
      return '时钟';
    case OsdFlag.progress:
      return '播放进度';
    case OsdFlag.traffic:
      return '网速';
    case OsdFlag.mini:
      return '迷你进度条';
    case OsdFlag.diagnostics:
      return '诊断面板';
    default:
      return id;
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_settings_entries_test.dart
```
Expected: PASS（4 个用例）

- [ ] **Step 5: 回归设置页既有测试**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase5_sync_ui_test.dart
```
Expected: PASS（确认新增区块没有破坏既有断言）

- [ ] **Step 6: 静态检查并提交**

```powershell
puro -e webhtv -p . dart analyze
```

```bash
git add apps/desktop-flutter/lib/ui/diagnostics_pages.dart apps/desktop-flutter/test/phase8_settings_entries_test.dart
git commit -m "新增：设置页的屏显与播放器按钮两个入口"
```

---

## Task 11: 播放器页组装（**核心任务：消除画面缩放**）

**Files:**
- Modify: `apps/desktop-flutter/lib/ui/player_page.dart`
- Test: `apps/desktop-flutter/test/phase8_player_page_overlay_test.dart`

**Interfaces:**
- Consumes: `PlayerOsdLayer`（Task 6）、`PlayerControlOverlay` / `PlayerOverlayActionRow`（Task 7）、`PlayerContextMenu` / `PlayerMenuSection` / `PlayerMenuItem`（Task 8）、`resolveVisibleButtons`（Task 2）、`buildOsdDiagnostics` / `buildOsdEnvironment`（Task 5）
- Produces: `PlayerPage` 的四层 `Stack` 结构；`_controlsVisible` 状态机；`_contextMenuAnchor` / `_osdNow` / `_osdTimer` 状态

- [ ] **Step 1: 写失败的测试**

创建 `apps/desktop-flutter/test/phase8_player_page_overlay_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_osd.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/player_page_harness.dart';

void main() {
  testWidgets('播放器页是 Stack 结构，控制浮层不参与布局（design/01 §3）', (tester) async {
    await pumpPlayerPage(tester);
    final page = find.byType(PlayerPage);
    expect(page, findsOneWidget);
    // 控制浮层与屏显层都在树里。
    expect(find.byType(PlayerControlOverlay), findsOneWidget);
    expect(find.byType(PlayerOsdLayer), findsOneWidget);
  });

  testWidgets('顶栏仍是 AppBar（design/01 §4.1）', (tester) async {
    await pumpPlayerPage(tester);
    expect(find.byType(AppBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('更多'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('四个 tooltip 精确串仍在（design/00 §5 第 2 条）', (tester) async {
    await pumpPlayerPage(tester);
    expect(find.byTooltip('字幕轨'), findsOneWidget);
    expect(find.byTooltip('弹幕（开启）'), findsOneWidget);
    expect(find.byTooltip('全屏（F11）'), findsOneWidget);
  });

  testWidgets('屏显层 IgnorePointer：点击穿透到画面（design/01 §3.1）', (tester) async {
    await pumpPlayerPage(tester);
    final osd = tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer));
    expect(osd.controlsVisible, isTrue, reason: '初始应可见');
  });

  testWidgets('隐藏态下控制浮层 IgnorePointer 生效（design/01 §3.1）', (tester) async {
    await pumpPlayerPage(tester);
    // 等自动隐藏。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    final overlay = tester.widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byType(PlayerControlOverlay),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    expect(overlay.ignoring, isTrue, reason: '隐藏后必须忽略指针');
  });

  testWidgets('右键打开菜单（design/04 §5.1）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerContextMenu), findsOneWidget);
    expect(find.text('播放'), findsWidgets);
  });

  testWidgets('菜单打开时控制栏强制可见且不隐藏（design/04 §5.4）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final osd = tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer));
    expect(osd.controlsVisible, isTrue, reason: '菜单打开期间控制栏不得隐藏');
  });

  testWidgets('Esc 只关菜单，不退出全屏（design/04 §5.3）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerContextMenu), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PlayerContextMenu), findsNothing);
  });

  testWidgets('点击菜单外关闭（design/04 §5.3）', (tester) async {
    await pumpPlayerPage(tester);
    await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerContextMenu), findsNothing);
  });

  testWidgets('屏显全关且控制栏隐藏时定时器停止（design/02 §4.3）', (tester) async {
    await pumpPlayerPage(tester, osdFlags: {
      for (final id in OsdFlag.values) id: false,
    });
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('按钮配置生效：隐藏 speed 后不渲染倍速（design/03 §5.1）', (tester) async {
    await pumpPlayerPage(tester, hiddenButtons: {'speed'});
    expect(find.text('倍速'), findsNothing);
    expect(find.byTooltip('全屏（F11）'), findsOneWidget);
  });

  testWidgets('按钮配置生效：顺序改变反映在渲染顺序（design/03 §5.1）', (tester) async {
    await pumpPlayerPage(
      tester,
      buttonOrder: ['fullscreen', 'prev', 'play', 'next'],
    );
    final fullscreen = tester.getTopLeft(find.byTooltip('全屏（F11）'));
    final prev = tester.getTopLeft(find.byTooltip('上一集（[）'));
    expect(fullscreen.dx, lessThan(prev.dx), reason: '全屏应排在最左');
  });

  testWidgets('无阴影、无 elevation（DESIGN.md The Flat-Field Rule）', (tester) async {
    await pumpPlayerPage(tester);
    for (final m in tester.widgetList<Material>(find.byType(Material))) {
      expect(m.elevation, 0);
    }
  });
}
```

创建测试辅助 `apps/desktop-flutter/test/support/player_page_harness.dart`：

```dart
/// 播放器页的测试脚手架。
///
/// 为什么单独一个文件：本轮有 3 个套件要 pump `PlayerPage`，
/// 而它需要 `AppState`（真实临时目录）+ `PlaybackRequest`。
/// 复制三份会让「窗口尺寸」「初始开关」这类参数漂移。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

/// pump 一个播放器页。
///
/// **不加载真实媒体**：`url` 指向不可达地址，`PlayerController` 会进入加载态，
/// 但控制浮层、屏显层、菜单层的结构都已经在树里——本轮的断言对象是它们，
/// 不是解码结果。真实出画的几何不变式由 L3 集成测试（Task 12）覆盖。
Future<void> pumpPlayerPage(
  WidgetTester tester, {
  Map<String, bool>? osdFlags,
  Set<String>? hiddenButtons,
  List<String>? buttonOrder,
  Size size = const Size(1280, 720),
}) async {
  final temp = Directory.systemTemp.createTempSync('webhtv-phase8-page');
  addTearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });
  final paths = AppPaths.resolve(
    overrides: {'roaming': temp.path, 'local': temp.path},
  );
  final state = AppState(paths: paths, log: LogService());
  addTearDown(state.dispose);
  await state.bootstrap();

  if (osdFlags != null) {
    for (final entry in osdFlags.entries) {
      await state.setOsdFlag(entry.key, entry.value);
    }
  }
  if (hiddenButtons != null) {
    await state.setPlayerButtonHidden(hiddenButtons);
  }
  if (buttonOrder != null) {
    await state.setPlayerButtonOrder(buttonOrder);
  }

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: PlayerPage(
          state: state,
          request: const PlaybackRequest(
            url: 'http://127.0.0.1:9/never.m3u8',
            title: '示例剧集',
            siteKey: 'fixture',
            vodId: 'demo-1',
            vodName: '示例剧集',
            episodeName: 'E3',
            flag: '线路一',
          ),
        ),
      ),
    ),
  );
  // 让 initState 的 postFrameCallback 跑起来，但不等真实网络。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_player_page_overlay_test.dart
```
Expected: FAIL — `Could not find PlayerControlOverlay`

- [ ] **Step 3: 改 `player_page.dart` 的 `build`**

编辑 `apps/desktop-flutter/lib/ui/player_page.dart`。

**3a. 加 import**（在现有 import 区末尾）：

```dart
import '../core/osd_config.dart';
import '../core/osd_diagnostics.dart';
import '../core/player_buttons.dart';
import 'player_button_config_page.dart';
import 'player_context_menu.dart';
import 'player_osd.dart';
import 'player_overlay.dart';
import 'theme.dart';
```

**注意 `theme.dart`**：`buildAppTheme`（`theme.dart:174`）是恒定暗色主题作用域
（§3h）需要的。`app.dart` **没有** `export 'theme.dart'`，所以必须显式导入——
`player_page.dart` 现在只导入了 `app.dart`，不加这一行会编译失败。

**3b. 加状态字段**（在 `double? _gestureRateBeforeLongPress;` 之后）：

```dart
  /// 右键菜单的锚点；null 表示菜单关闭。
  Offset? _contextMenuAnchor;

  /// 屏显的时钟基准；由 [_osdTimer] 每秒推进。
  DateTime _osdNow = DateTime.now();

  /// 屏显刷新循环（时钟/进度/诊断）。
  ///
  /// **只在需要时运行**：屏显全关且控制栏隐藏时停止（`design/02` §4.3），
  /// 否则一个每秒空转的 Timer 会在每个用例里留下 pending timer。
  Timer? _osdTimer;
```

**3c. 加屏显刷新控制**（在 `_touchControls` 之前）：

```dart
  /// 屏显是否需要刷新循环。
  ///
  /// 控制栏可见时**必须**运行（为了强制显示的时钟），
  /// 即使屏显开关全关（上游同语义：`PlayerOsdController.java:152-158`）。
  bool get _osdNeedsTicker =>
      _controlsVisible || anyOsdEnabled(widget.state.osdFlags);

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

**3d. 在 `_touchControls` 与 `_toggleControlsByGesture` 里同步定时器**。

把 `_touchControls`（原第 1508-1517 行）替换为：

```dart
  void _touchControls() {
    _controlHideTimer?.cancel();
    if (mounted && !_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _syncOsdTimer();
    // 菜单打开期间不排隐藏计时器（`design/04` §5.4）。
    if (_contextMenuAnchor != null) return;
    _controlHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_contextMenuAnchor != null) return;
      setState(() => _controlsVisible = false);
      _syncOsdTimer();
    });
  }
```

把 `_toggleControlsByGesture`（原第 1519-1529 行）替换为：

```dart
  void _toggleControlsByGesture() {
    if (resolvePlayerGesture(doubleTap: false, fullscreen: _fullscreen) ==
        PlayerGestureAction.toggleControls) {
      if (_controlsVisible) {
        _controlHideTimer?.cancel();
        setState(() => _controlsVisible = false);
        _syncOsdTimer();
      } else {
        _touchControls();
      }
    }
  }
```

**3e. 加菜单开关方法**（在 `_toggleControlsByGesture` 之后）：

```dart
  /// 打开右键菜单（`design/04` §5.1）。
  ///
  /// 幂等：已打开时只移动位置（部分平台只发 `onSecondaryTap` 不发 `onSecondaryTapDown`）。
  void _openContextMenu(Offset globalPosition) {
    _controlHideTimer?.cancel();
    setState(() {
      _contextMenuAnchor = globalPosition;
      _controlsVisible = true;
    });
    _syncOsdTimer();
  }

  /// 关闭右键菜单并恢复自动隐藏计时（`design/04` §5.4）。
  void _closeContextMenu() {
    if (_contextMenuAnchor == null) return;
    setState(() => _contextMenuAnchor = null);
    _touchControls();
  }
```

**3f. 加菜单内容构造**（在 `_closeContextMenu` 之后）：

```dart
  /// 右键菜单的分组内容（`design/04` §4.1）。
  List<PlayerMenuSection> _contextMenuSections() {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final osd = widget.state.osdFlags;
    return [
      PlayerMenuSection(
        title: '播放',
        items: [
          PlayerMenuItem(
            id: 'play',
            label: _controller.isPlaying ? '暂停' : '播放',
            icon: _controller.isPlaying ? Icons.pause : Icons.play_arrow,
            onSelect: () {
              _closeContextMenu();
              _controller.playOrPause();
            },
          ),
          PlayerMenuItem(
            id: 'prev',
            label: '上一集',
            icon: Icons.skip_previous,
            onSelect: () {
              _closeContextMenu();
              _playPrevious();
            },
          ),
          PlayerMenuItem(
            id: 'next',
            label: '下一集',
            icon: Icons.skip_next,
            onSelect: () {
              _closeContextMenu();
              _playNext();
            },
          ),
          PlayerMenuItem(
            id: 'back10',
            label: '后退 10 秒',
            icon: Icons.replay_10,
            onSelect: () {
              _closeContextMenu();
              _controller.seekBy(const Duration(seconds: -10));
            },
          ),
          PlayerMenuItem(
            id: 'forward10',
            label: '前进 10 秒',
            icon: Icons.forward_10,
            onSelect: () {
              _closeContextMenu();
              _controller.seekBy(const Duration(seconds: 10));
            },
          ),
        ],
      ),
      PlayerMenuSection(
        title: '速度',
        items: [
          for (final rate in rates)
            PlayerMenuItem(
              id: 'rate_$rate',
              label: '${rate.toString()}×',
              selected: (_controller.rate - rate).abs() < 0.01,
              onSelect: () {
                _closeContextMenu();
                _controller.setRate(rate);
              },
            ),
        ],
      ),
      PlayerMenuSection(
        title: '画面',
        items: [
          PlayerMenuItem(
            id: 'video_fit',
            label: '画面比例与缩放',
            icon: Icons.aspect_ratio_outlined,
            children: [
              for (final mode in PlayerVideoFitMode.values)
                PlayerMenuItem(
                  id: 'fit_${mode.name}',
                  label: mode.label,
                  selected: mode == _videoFitMode,
                  onSelect: () {
                    _closeContextMenu();
                    _applyVideoFitMode(mode);
                  },
                ),
            ],
          ),
          PlayerMenuItem(
            id: 'fullscreen',
            label: _fullscreen ? '退出全屏' : '全屏',
            icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            onSelect: () {
              _closeContextMenu();
              _toggleFullscreen();
            },
          ),
        ],
      ),
      PlayerMenuSection(
        title: '轨道',
        items: [
          PlayerMenuItem(
            id: 'subtitle',
            label: '字幕轨',
            icon: Icons.subtitles_outlined,
            onSelect: () {
              _closeContextMenu();
              _showSubtitleMenu();
            },
          ),
          PlayerMenuItem(
            id: 'danmaku',
            label: _danmakuStyle.enabled ? '关闭弹幕' : '开启弹幕',
            icon: _danmakuStyle.enabled
                ? Icons.comment
                : Icons.comment_bank_outlined,
            onSelect: () {
              _closeContextMenu();
              _toggleDanmaku();
            },
          ),
          PlayerMenuItem(
            id: 'danmaku_settings',
            label: '弹幕设置',
            icon: Icons.comment_outlined,
            onSelect: () {
              _closeContextMenu();
              _showDanmakuSettings();
            },
          ),
        ],
      ),
      PlayerMenuSection(
        title: '显示',
        items: [
          PlayerMenuItem(
            id: 'osd',
            label: '屏显',
            icon: Icons.subtitles,
            children: [
              for (final id in OsdFlag.values)
                PlayerMenuItem(
                  id: 'osd_$id',
                  label: _osdLabelOf(id),
                  selected: osd[id] ?? false,
                  enabled: id != OsdFlag.traffic,
                  onSelect: () => _toggleOsdFlag(id),
                ),
            ],
          ),
          PlayerMenuItem(
            id: 'buttons',
            label: '控制栏按钮…',
            icon: Icons.tune,
            onSelect: () {
              _closeContextMenu();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerButtonConfigPage(state: widget.state),
                ),
              );
            },
          ),
        ],
      ),
      PlayerMenuSection(
        title: '信息',
        items: [
          PlayerMenuItem(
            id: 'media_info',
            label: '媒体信息',
            icon: Icons.info_outline,
            onSelect: () {
              _closeContextMenu();
              _showMediaInfo();
            },
          ),
          PlayerMenuItem(
            id: 'diagnostics',
            label: '播放诊断',
            icon: Icons.monitor_heart_outlined,
            enabled: _diagnostics != null,
            onSelect: () {
              _closeContextMenu();
              _showDiagnostics();
            },
          ),
          PlayerMenuItem(
            id: 'shortcuts',
            label: '快捷键说明',
            icon: Icons.keyboard,
            onSelect: () {
              _closeContextMenu();
              _showShortcutHelp();
            },
          ),
        ],
      ),
    ];
  }

  /// 切换一项屏显开关（菜单里就地生效，**不关闭菜单**，便于连续调整）。
  void _toggleOsdFlag(String id) {
    final next = !(widget.state.osdFlags[id] ?? false);
    unawaited(widget.state.setOsdFlag(id, next));
    setState(() {});
    _syncOsdTimer();
  }

  /// 应用画面模式并持久化（从菜单调用，与 `_showVideoFitSettings` 同语义）。
  void _applyVideoFitMode(PlayerVideoFitMode mode) {
    setState(() => _videoFitMode = mode);
    widget.state.rememberPlayerVideoFitMode(
      siteKey: _request.siteKey,
      vodId: _request.vodId,
      mode: mode.name,
    );
  }
```

**3g. 加屏显中文名映射**（文件末尾，`_PlayerMenuAction` 枚举之前）：

```dart
/// 屏显开关的中文名（`design/02` §5.1）。
String _osdLabelOf(String id) {
  switch (id) {
    case OsdFlag.title:
      return '标题';
    case OsdFlag.size:
      return '分辨率';
    case OsdFlag.time:
      return '时钟';
    case OsdFlag.progress:
      return '播放进度';
    case OsdFlag.traffic:
      return '网速（未采集）';
    case OsdFlag.mini:
      return '迷你进度条';
    case OsdFlag.diagnostics:
      return '诊断面板';
    default:
      return id;
  }
}
```

**3h. 替换 `build` 的 `body`**。

把原 `body: Column(...)`（第 1400-1474 行）整体替换为：

```dart
          // 恒定暗色主题作用域（`design/01` §4.3）。
          //
          // 播放器背景是**视频帧**，不是应用底色。用户主题是亮色时，
          // 主题给的浅色 surface 会让浮层文字对比度崩掉
          // （现状注释已记录这个问题，本轮把它做完）。
          //
          // **必须包在 `PlayerPage.build` 内部**，不是路由层：
          // 6 处集成测试用裸 `MaterialApp(home: Scaffold(body: PlayerPage(...)))`
          // pump 本页，不走路由（`design/05` §5.1）。
          body: Theme(
            data: buildAppTheme(Brightness.dark),
            child: Stack(
              children: [
                // 第 1 层：画面 + 弹幕 + 加载/错误。
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleControlsByGesture,
                    onDoubleTap: _handleDoubleTapGesture,
                    onLongPressStart: (_) => _beginGestureSpeed(),
                    onLongPressEnd: (_) => _endGestureSpeed(),
                    onLongPressCancel: _endGestureSpeed,
                    // 右键：打开菜单（`design/04` §5.1）。
                    // 两个回调都指向同一方法，方法内部幂等。
                    onSecondaryTapDown: (details) =>
                        _openContextMenu(details.globalPosition),
                    onSecondaryTap: () {},
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Video(
                            controller: _controller.videoController,
                            fit: _videoFitMode.fit,
                            aspectRatio: _videoFitMode.aspectRatio,
                            controls: NoVideoControls,
                            subtitleViewConfiguration:
                                _subtitleStyle.configuration,
                          ),
                        ),
                        Positioned.fill(
                          child: DanmakuOverlay(
                            items: _danmakuItems,
                            position: _controller.position,
                            style: _danmakuStyle,
                            liveItems: _liveItems,
                            liveNowMs: _liveNowMs,
                          ),
                        ),
                        if (_controller.isLoading)
                          const Positioned.fill(child: LoadingBlock()),
                        if (_loadError != null)
                          Positioned.fill(
                            child: Center(
                              child: _PlayerErrorOverlay(
                                message: _loadError!,
                                url: _request.url,
                                onRetry: _load,
                                onResume: _resumeFromLatestProgress,
                                onNext: _playNext,
                                canGoNext:
                                    (_episodesCache.isNotEmpty
                                        ? _episodesCache.length
                                        : _episodes.length) >
                                    _request.episodeIndex + 1,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // 第 2 层：屏显（`design/02`）。自身已 IgnorePointer。
                Positioned.fill(
                  child: PlayerOsdLayer(
                    flags: widget.state.osdFlags,
                    controlsVisible: _controlsVisible,
                    title: '${_request.vodName} · ${_request.episodeName}',
                    resolution: _mediaResolution() == '未知'
                        ? null
                        : _mediaResolution(),
                    position: _controller.position,
                    duration: _controller.duration,
                    isLive: _request.directUrl,
                    now: _osdNow,
                    diagnostics: _osdDiagnosticsRows(),
                    environment: _osdEnvironmentRows(),
                  ),
                ),
                // 第 3 层：控制浮层（`design/01`）。
                //
                // 用 AnimatedOpacity 而不是 `if (_controlsVisible)`：
                // 条件插入会改变子树结构，且 Positioned.fill 的命中测试范围
                // 会随之跳变。隐藏时必须 IgnorePointer，否则透明按钮仍可点。
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: AnimatedOpacity(
                      opacity: _controlsVisible ? 1 : 0,
                      duration: AppMotion.fast,
                      curve: AppMotion.ease,
                      child: PlayerControlOverlay(
                        topBar: _buildPlayerAppBar(),
                        progressRow: _buildProgressRow(),
                        actionButtons: _buildActionButtons(),
                        actionGroups: _actionGroups(),
                      ),
                    ),
                  ),
                ),
                // 第 4 层：右键菜单（`design/04` §3）。
                if (_contextMenuAnchor != null) ...[
                  // 全屏透明遮罩：点击菜单外关闭。
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _closeContextMenu,
                    ),
                  ),
                  PlayerContextMenu(
                    anchor: _contextMenuAnchor!,
                    viewport: MediaQuery.sizeOf(context),
                    sections: _contextMenuSections(),
                    onDismiss: _closeContextMenu,
                  ),
                ],
              ],
            ),
          ),
```

**3i. 把原 `appBar:` 抽成方法**。

把 `Scaffold` 的 `appBar:` 参数改为 `appBar: null`（顶栏改由浮层承载），
并在类内新增：

```dart
  /// 播放器顶栏。
  ///
  /// **必须保持 `AppBar` widget 类型**：`ui_redesign_visual_flow_test.dart:677-681`
  /// 用 `find.descendant(of: find.byType(AppBar), matching: find.byTooltip('更多'))`
  /// 断言「更多」按钮的位置。换成自绘 `Row` 会让那条断言找不到东西。
  ///
  /// 全屏时**不再置 null**：顶栏仍在浮层里，只是随浮层一起隐藏——
  /// 这样进出全屏不再有 56px 跳变（`design/01` §4.2）。
  PreferredSizeWidget _buildPlayerAppBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      title: Text(
        '${_request.vodName} · ${_request.episodeName}',
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          tooltip: '字幕轨',
          icon: const Icon(Icons.subtitles_outlined),
          onPressed: _showSubtitleMenu,
        ),
        IconButton(
          tooltip: _danmakuStyle.enabled ? '弹幕（开启）' : '弹幕（关闭）',
          icon: Icon(
            _danmakuStyle.enabled ? Icons.comment : Icons.comment_bank_outlined,
          ),
          onPressed: _toggleDanmaku,
        ),
        PopupMenuButton<_PlayerMenuAction>(
          tooltip: '更多',
          icon: const Icon(Icons.more_vert),
          onSelected: (action) {
            switch (action) {
              case _PlayerMenuAction.subtitleStyle:
                _showSubtitleStyleSettings();
              case _PlayerMenuAction.danmakuSettings:
                _showDanmakuSettings();
              case _PlayerMenuAction.videoFit:
                _showVideoFitSettings();
              case _PlayerMenuAction.mediaInfo:
                _showMediaInfo();
              case _PlayerMenuAction.diagnostics:
                _showDiagnostics();
              case _PlayerMenuAction.shortcuts:
                _showShortcutHelp();
            }
          },
          itemBuilder: (context) => [
            _menuItem(
              _PlayerMenuAction.subtitleStyle,
              Icons.format_color_text_outlined,
              '字幕样式',
            ),
            _menuItem(
              _PlayerMenuAction.danmakuSettings,
              Icons.comment_outlined,
              '弹幕设置',
            ),
            _menuItem(
              _PlayerMenuAction.videoFit,
              Icons.aspect_ratio_outlined,
              '画面比例与缩放',
            ),
            _menuItem(
              _PlayerMenuAction.mediaInfo,
              Icons.info_outline,
              '媒体信息',
            ),
            PopupMenuItem<_PlayerMenuAction>(
              value: _PlayerMenuAction.diagnostics,
              enabled: _diagnostics != null,
              child: _menuRow(
                Icons.monitor_heart_outlined,
                '播放诊断',
                enabled: _diagnostics != null,
              ),
            ),
            _menuItem(
              _PlayerMenuAction.shortcuts,
              Icons.keyboard,
              '快捷键说明',
            ),
          ],
        ),
      ],
    );
  }
```

**3j. 抽出进度行与动作行**。

把原 `_ControlBar` 里的进度 `Row`（原第 2114-2138 行）抽成 `_buildProgressRow()`：

```dart
  /// 进度行：等宽时间 + 滑杆（`design/01` §4）。
  Widget _buildProgressRow() {
    final duration = _controller.duration;
    final maxMs = duration.inMilliseconds <= 0
        ? 1.0
        : duration.inMilliseconds.toDouble();
    final value = _controller.position.inMilliseconds
        .clamp(0, maxMs.toInt())
        .toDouble();
    return Row(
      children: [
        Text(
          _formatDuration(_controller.position),
          style: tabular(Theme.of(context).textTheme.bodyMedium!),
        ),
        Expanded(
          child: Slider(
            value: value,
            max: maxMs,
            onChanged: duration.inMilliseconds <= 0
                ? null
                : (next) =>
                      _controller.seek(Duration(milliseconds: next.round())),
          ),
        ),
        Text(
          _formatDuration(duration),
          style: tabular(Theme.of(context).textTheme.bodyMedium!),
        ),
      ],
    );
  }
```

把原 `_ControlBar` 的动作 `Wrap`（原第 2139-2272 行）抽成 `_buildActionButtons()`，
**按配置顺序渲染**：

```dart
  /// 动作行按钮：按用户配置的顺序与可见性渲染（`design/03` §5.1）。
  ///
  /// 每个 id 对应的 widget 类型与 tooltip 精确串是**既有的、被测试锁定的**，
  /// 不得改动（`design/03` §5.2）。
  List<Widget> _buildActionButtons() {
    final specs = resolveVisibleButtons(
      order: widget.state.playerButtonOrder,
      hidden: widget.state.playerButtonHidden,
    );
    final episodes = _episodes;
    return [
      for (final spec in specs)
        switch (spec.id) {
          'prev' => IconButton(
            tooltip: '上一集（[）',
            onPressed: _playPrevious,
            icon: const Icon(Icons.skip_previous),
          ),
          'play' => IconButton(
            tooltip: _controller.isPlaying ? '暂停（空格）' : '播放（空格）',
            onPressed: _controller.playOrPause,
            icon: Icon(
              _controller.isPlaying ? Icons.pause : Icons.play_arrow,
            ),
          ),
          'next' => IconButton(
            tooltip: '下一集（]）',
            onPressed: _playNext,
            icon: const Icon(Icons.skip_next),
          ),
          'mute' => IconButton(
            tooltip: _controller.muted || _controller.volume == 0
                ? '取消静音（M）'
                : '静音（M）',
            onPressed: _controller.toggleMute,
            icon: Icon(
              _controller.muted || _controller.volume == 0
                  ? Icons.volume_off
                  : Icons.volume_up,
            ),
          ),
          'volume' => SizedBox(
            width: 120,
            child: Slider(
              value: _controller.volume.clamp(0, 100),
              max: 100,
              onChanged: _controller.setVolume,
            ),
          ),
          'speed' => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('倍速'),
              DropdownButton<double>(
                underline: const SizedBox.shrink(),
                value: _nearestRate(_controller.rate),
                items: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                    .map(
                      (rate) => DropdownMenuItem(
                        value: rate,
                        child: Text('${rate.toString()}x'),
                      ),
                    )
                    .toList(),
                onChanged: (rate) {
                  if (rate != null) _controller.setRate(rate);
                },
              ),
            ],
          ),
          'line' when _request.playLines.length > 1 => DropdownButton<String>(
            underline: const SizedBox.shrink(),
            value: _request.flag,
            hint: const Text('线路'),
            items: _request.playLines
                .map(
                  (line) => DropdownMenuItem(
                    value: line.flag,
                    child: Text(line.displayName),
                  ),
                )
                .toList(),
            onChanged: (flag) {
              if (flag != null) _playEpisode(0, overrideFlag: flag);
            },
          ),
          'episodes' when episodes.isNotEmpty => OutlinedButton.icon(
            onPressed: () => _showEpisodes(context, episodes),
            icon: const Icon(Icons.list, size: 18),
            label: Text('剧集（${episodes.length}）'),
          ),
          'fullscreen' => IconButton(
            tooltip: '全屏（F11）',
            onPressed: _toggleFullscreen,
            icon: const Icon(Icons.fullscreen),
          ),
          // 条件不成立的项（如单线路时的 `line`）不渲染。
          _ => const SizedBox.shrink(),
        },
    ];
  }

  /// 与 [_buildActionButtons] 一一对应的分组（用于插分隔线）。
  List<PlayerButtonGroup> _actionGroups() {
    final specs = resolveVisibleButtons(
      order: widget.state.playerButtonOrder,
      hidden: widget.state.playerButtonHidden,
    );
    return [for (final spec in specs) spec.group];
  }

  double _nearestRate(double rate) {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    var best = rates.first;
    for (final candidate in rates) {
      if ((candidate - rate).abs() < (best - rate).abs()) best = candidate;
    }
    return best;
  }

  /// 剧集选择面板（从原 `_ControlBar._showEpisodes` 迁入，行为不变）。
  ///
  /// 保留 `OutlinedButton` 作为剧集卡：这是测试锁死的结构
  /// （`DESIGN.md`：「剧集卡就是 `OutlinedButton`——这是测试锁死的结构，不可替换」）。
  void _showEpisodes(BuildContext context, List<VodEpisode> episodes) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SizedBox(
        height: 320,
        child: GridView.builder(
          padding: const EdgeInsets.all(AppSpace.md),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisExtent: 40,
            crossAxisSpacing: AppSpace.sm,
            mainAxisSpacing: AppSpace.sm,
          ),
          itemCount: episodes.length,
          itemBuilder: (context, index) => OutlinedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _playEpisode(index);
            },
            child: Text(episodes[index].name, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }

  /// 屏显诊断主列（`design/02` §3.2）。
  List<OsdDiagnosticsRow> _osdDiagnosticsRows() {
    final video = _controller.selectedVideoTrack;
    final audio = _controller.selectedAudioTrack;
    final audioParams = _controller.audioParams;
    return buildOsdDiagnostics(
      videoWidth: _controller.videoWidth,
      videoHeight: _controller.videoHeight,
      videoCodec: video?.codec,
      videoFps: video?.fps,
      videoBitrate: video?.bitrate,
      audioCodec: audio?.codec,
      audioChannels: audioParams.hrChannels ?? audioParams.channels,
      audioSampleRate: audioParams.sampleRate,
      audioBitrate: _controller.audioBitrate ?? audio?.bitrate,
      position: _controller.position,
      duration: _controller.duration,
      buffered: _controller.buffered,
      rate: _controller.rate,
      volume: _controller.volume,
      muted: _controller.muted,
      formatLabel: _diagnostics?.format.label ?? '未知',
      targetHost: _diagnostics?.target.host ?? '',
      siteKey: _request.siteKey,
      flag: _request.flag,
      episodeName: _request.episodeName,
      // 结论行：来自本次播放的诊断快照。
      // `_diagnostics` 为 null（还没起播/还没落定）→ 传 null，结论行不渲染。
      //
      // `succeeded` 在起播前确实是 null（`playback_diagnostics.dart:315`
      // 声明为 `bool? _succeeded`，只在 `succeed()`/`fail()` 里赋值），
      // 所以不会短暂显示「失败」。
      succeeded: _diagnostics?.succeeded,
      // `failureKind` 的运行时类型是 `PlayerFailureKind` **枚举**，
      // 直接插值会渲染成 `失败 · PlayerFailureKind.timeout`。
      // 传 `.name` 得到短而稳定的分类（`timeout`），屏显是窄栏位。
      failureKind: _diagnostics?.failureKind is Enum
          ? (_diagnostics!.failureKind! as Enum).name
          : _diagnostics?.failureKind,
    );
  }

  /// 屏显诊断附加列（`design/02` §3.2）。
  ///
  /// 拿不到的项**不出现**（不是显示「未知」）。
  List<OsdDiagnosticsRow> _osdEnvironmentRows() {
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return buildOsdEnvironment(
      operatingSystemVersion: Platform.operatingSystemVersion,
      windowSize: '${size.width.round()}×${size.height.round()}',
      devicePixelRatio: dpr,
      themeMode: widget.state.themeMode,
      proxyPort: null,
    );
  }
```

**3k. 加 `Esc` 关菜单的快捷键**。

把 `build` 里的 `CallbackShortcuts(bindings: shortcuts, ...)` 替换为：

```dart
    // 菜单打开时 Esc 只关菜单，不退出全屏（`design/04` §5.3）。
    //
    // 用内层 CallbackShortcuts 覆盖：Focus 树就近优先，
    // 因此不需要改 `buildPlayerShortcuts`。
    final menuShortcuts = <ShortcutActivator, VoidCallback>{
      if (_contextMenuAnchor != null)
        const SingleActivator(LogicalKeyboardKey.escape): _closeContextMenu,
    };

    return CallbackShortcuts(
      bindings: shortcuts,
      child: Focus(
        autofocus: true,
        child: CallbackShortcuts(
          bindings: menuShortcuts,
          child: Focus(
            autofocus: _contextMenuAnchor != null,
            child: Scaffold(...),
          ),
        ),
      ),
    );
```

**3l. 更新 `initState` 与 `dispose`**。

在 `initState` 的 `WidgetsBinding.instance.addPostFrameCallback` 之前加：

```dart
    _osdNow = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncOsdTimer();
    });
```

在 `dispose` 里 `_controlHideTimer?.cancel();` 之后加：

```dart
    _osdTimer?.cancel();
    _osdTimer = null;
```

**3m. 删除 `_ControlBar` 类，以及顶层的 `_controlBarDivider`**。

原 `_ControlBar`（第 2021-2313 行）的功能已全部迁入 `_buildProgressRow` /
`_buildActionButtons` / `_showEpisodes` / `_nearestRate`。
把 `_showEpisodes` 与 `_nearestRate` 移到 `_PlayerPageState` 内（已在 3j 提供），
然后**删除整个 `_ControlBar` 类**。

**同时必须删除顶层的 `_controlBarDivider`（第 1901-1910 行）。**
它**不在** `_ControlBar` 内部（`_ControlBar` 从 2021 行才开始），
而是 `player_page.dart` 的顶层私有函数，被 `_ControlBar` 在 2163/2183/2234 三处调用。
删掉 `_ControlBar` 后它**没有任何引用**，`dart analyze` 会报
`warning - The declaration '_controlBarDivider' isn't referenced`，
**G1（`No issues found!`）直接失败**。
它的功能已由 Task 7 的 `PlayerOverlayDivider` 取代，所以是**删除**而非保留。

**3n. 加 `dart:io` import**（`_osdEnvironmentRows` 用了 `Platform`）：

```dart
import 'dart:io';
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase8_player_page_overlay_test.dart
```
Expected: PASS（13 个用例）

- [ ] **Step 5: 回归播放器既有测试**

Run:
```powershell
puro -e webhtv -p . flutter test test/phase3_player_display_test.dart test/phase7_player_advance_test.dart
```
Expected: PASS

- [ ] **Step 6: 静态检查**

Run: `puro -e webhtv -p . dart analyze`
Expected: `No issues found!`

- [ ] **Step 7: 提交**

```bash
git add apps/desktop-flutter/lib/ui/player_page.dart apps/desktop-flutter/test/phase8_player_page_overlay_test.dart apps/desktop-flutter/test/support/player_page_harness.dart
git commit -m "改造：播放器页改 Stack 浮层（消除控制栏显隐导致的画面缩放）"
```

---

## Task 12: L3 几何不变式集成测试（**本轮的核心验收**）

**Files:**
- Create: `apps/desktop-flutter/integration_test/phase8_overlay_flow_test.dart`

**Interfaces:**
- Consumes: 全部前置任务
- Produces: V1/V2 几何不变式的机器证据

- [ ] **Step 1: 写测试**

创建 `apps/desktop-flutter/integration_test/phase8_overlay_flow_test.dart`：

```dart
/// Phase 8 · 浮层几何不变式（`docs/phase8/design/01` §5、`design/05` §3.1）。
///
/// ## 这个套件存在的唯一理由
///
/// 用户投诉「每次唤醒控制台都会导致画面缩放」。修复的正确性**不能靠肉眼**——
/// `Column` → `Stack` 的迁移很容易半做（把浮层包在 `SafeArea` 里、
/// 给 `Stack` 加 `padding`、用 `Align` 而不是 `Positioned.fill`），
/// 每一种都会让视频区尺寸重新依赖浮层。
///
/// 本套件用**真实窗口 + 真实出画**，断言视频区矩形在控制栏显隐前后
/// **逐像素相同**。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'fixture_http.dart';

void evidence(String message) =>
    debugPrint('PHASE8-OVERLAY-EVIDENCE $message');

Future<bool> fixtureReachable() async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    final request = await client.getUrl(Uri.parse('$fixtureBaseUrl/health'));
    final response = await request.close();
    await response.drain<void>();
    client.close();
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('V1：控制栏显隐前后视频区矩形逐像素相同', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped(
        'fixture 服务不可达（$fixtureBaseUrl）：'
        '先运行 `python tools/fixture_server/server.py`',
      );
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase8-overlay');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: '$fixtureBaseUrl/media/sample.m3u8',
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E3',
              flag: '线路一',
              headers: const {
                'Referer': '$fixtureBaseUrl/',
                'User-Agent': 'WebHTV-PC-Phase0',
              },
            ),
          ),
        ),
      ),
    );

    // 等真实出画：媒体解码要走真实 async 区。
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }

    // 确保控制栏可见。
    await tester.tap(find.byType(PlayerPage), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));

    final visibleRect = tester.getRect(find.byType(Video));
    evidence(
      'rect-visible '
      'left=${visibleRect.left} top=${visibleRect.top} '
      'w=${visibleRect.width} h=${visibleRect.height}',
    );

    // 等自动隐藏（3 秒 + 余量）。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    final hiddenRect = tester.getRect(find.byType(Video));
    evidence(
      'rect-hidden '
      'left=${hiddenRect.left} top=${hiddenRect.top} '
      'w=${hiddenRect.width} h=${hiddenRect.height}',
    );

    expect(
      hiddenRect,
      visibleRect,
      reason:
          '控制栏显隐不得改变视频区几何——这正是用户投诉的「画面缩放」根因。'
          '若此处失败，检查控制浮层是否被放进了 Column/Row，'
          '或是否被 SafeArea/Padding 包裹。',
    );
    evidence('geometry-invariant PASS');
    expect(tester.takeException(), isNull);
  });

  testWidgets('V2：进出全屏前后视频区矩形在同一窗口尺寸下相同', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase8-fs');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: '$fixtureBaseUrl/media/sample.m3u8',
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E3',
              flag: '线路一',
              headers: const {
                'Referer': '$fixtureBaseUrl/',
                'User-Agent': 'WebHTV-PC-Phase0',
              },
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
    await tester.tap(find.byType(PlayerPage), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));

    // 顶栏在浮层里，所以窗口化与全屏时视频区都占满 body。
    // 这里断言的是「顶栏不再占用 56px」：视频区高度 == 窗口高度。
    final rect = tester.getRect(find.byType(Video));
    evidence('rect-windowed h=${rect.height} viewport=900');
    expect(
      rect.height,
      closeTo(900, 1),
      reason: '顶栏改浮层后，视频区应占满整个 body（不再被 AppBar 挤掉 56px）',
    );
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: 启动 fixture 服务**

Run（后台）：
```powershell
py -3 tools/fixture_server/server.py
```
Expected: 服务监听 `127.0.0.1:18080`

- [ ] **Step 3: 运行集成测试**

Run:
```powershell
cd apps/desktop-flutter
puro -e webhtv -p . flutter test integration_test/phase8_overlay_flow_test.dart -d windows
```
Expected: PASS（2 个用例），且输出含 `geometry-invariant PASS`

**若 V1 失败**：按 reason 里的三条排查——浮层是否在 `Column`/`Row` 里、
是否被 `SafeArea`/`Padding` 包裹、是否用了 `Align` 而不是 `Positioned.fill`。

**若 V2 失败**：确认 `Scaffold` 的 `appBar` 已改为 `null`（顶栏进浮层）。

- [ ] **Step 4: 恢复 Debug 产物**

`flutter test ... -d windows` 会把测试内核写进应用输出目录，
双击 exe 会启动集成测试入口。**必须重建**：

Run:
```powershell
puro -e webhtv -p . flutter build windows --debug
```

- [ ] **Step 5: 提交**

```bash
git add apps/desktop-flutter/integration_test/phase8_overlay_flow_test.dart
git commit -m "新增：Phase 8 几何不变式集成测试（V1/V2）"
```

---

## Task 13: 视觉证据采集（含菜单截图）

**Files:**
- Create: `apps/desktop-flutter/integration_test/phase8_visual_flow_test.dart`

**Interfaces:**
- Consumes: 全部前置任务
- Produces: `docs/phase8/evidence/screenshots/` 下的多宽高比截图

- [ ] **Step 1: 写测试**

创建 `apps/desktop-flutter/integration_test/phase8_visual_flow_test.dart`：

```dart
/// Phase 8 · 视觉证据采集（`docs/phase8/design/05` §8.1）。
///
/// ## 为什么必须新建
///
/// 既有 `ui_redesign_visual_flow_test.dart` 的 `capture` 取树中**第一个
/// `RepaintBoundary`**（`Scaffold` 那层）。本轮把右键菜单做成**页内 Stack 层**
/// 而不是 `Overlay` 浮层，**正是为了让它出现在这张图里**
/// （`docs/phase8/design/04` §3）。
///
/// ## 纪律
///
/// - 沿用 `DESIGN.md:411` 的多宽高比纪律：1.6:1 / 2.0:1 / 2.35:1 各出一张；
/// - **菜单可见性用「是不是 harness 拍到的那个 `RepaintBoundary` 的后代」
///   来断言**，不要用「菜单截图与关闭态字节不同」——
///   后者是**假绿**（实测：菜单没打开时两图仍差 5 字节，因为屏显时钟每秒
///   跳动、视频在播放）。详见 `docs/phase8/design/05` §6.1。
/// - **截图必须可复核**：屏显时钟要冻结（`debugOsdClockOverride`）、
///   菜单滚动后要显式推进 `pump(400ms)` 等滚动条淡出，否则同一份代码
///   两次跑出不同字节的 PNG。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'fixture_http.dart';

void evidence(String message) => debugPrint('PHASE8-VISUAL-EVIDENCE $message');

Directory repoRootOf(Directory start) {
  var current = start;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${current.path}/docs').existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return start;
}

Future<Uint8List?> captureBytes(WidgetTester tester) async {
  final boundary = find.byType(RepaintBoundary);
  if (boundary.evaluate().isEmpty) return null;
  final object = boundary.evaluate().first.renderObject;
  if (object is! RenderRepaintBoundary) return null;
  final image = await object.toImage(pixelRatio: 1.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes?.buffer.asUint8List();
}

Future<Uint8List?> capture(
  WidgetTester tester, {
  required String relativePath,
}) async {
  final data = await captureBytes(tester);
  if (data == null) {
    evidence('screenshot-skip reason=no-bytes path=$relativePath');
    return null;
  }
  final repoRoot = repoRootOf(Directory.current);
  final output = File('${repoRoot.path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(data);
  evidence('screenshot path=$relativePath bytes=${data.length}');
  return data;
}

Future<bool> fixtureReachable() async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    final request = await client.getUrl(Uri.parse('$fixtureBaseUrl/health'));
    final response = await request.close();
    await response.drain<void>();
    client.close();
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// 一个宽高比档位。
class Ratio {
  const Ratio(this.name, this.size);
  final String name;
  final Size size;
}

const ratios = [
  Ratio('r16x10', Size(1440, 900)), // 1.6:1
  Ratio('r2x1', Size(1600, 800)), // 2.0:1
  Ratio('r235x1', Size(1880, 800)), // 2.35:1
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  for (final ratio in ratios) {
    testWidgets('控制栏可见 / 隐藏 / 菜单打开（${ratio.name}）', (tester) async {
      if (!await fixtureReachable()) {
        markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
        return;
      }
      final temp = Directory.systemTemp.createTempSync(
        'webhtv-phase8-visual-${ratio.name}',
      );
      final paths = AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      );
      final state = AppState(paths: paths, log: LogService());
      addTearDown(() {
        state.dispose();
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      await state.bootstrap();
      // 诊断面板打开，让截图上能看到它。
      await state.setOsdFlag(OsdFlag.diagnostics, true);

      tester.view.physicalSize = ratio.size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: PlayerPage(
              state: state,
              request: PlaybackRequest(
                url: '$fixtureBaseUrl/media/sample.m3u8',
                title: '示例剧集',
                siteKey: 'fixture',
                vodId: 'demo-1',
                vodName: '示例剧集',
                episodeName: 'E3',
                flag: '线路一',
                headers: const {
                  'Referer': '$fixtureBaseUrl/',
                  'User-Agent': 'WebHTV-PC-Phase0',
                },
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
      }

      // 1) 控制栏可见。
      await tester.tap(find.byType(PlayerPage), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
      await capture(
        tester,
        relativePath: 'docs/phase8/evidence/screenshots/'
            'player-controls-${ratio.name}.png',
      );

      // 2) 右键菜单打开。
      await tester.tapAt(
        Offset(ratio.size.width * 0.5, ratio.size.height * 0.12),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await capture(
        tester,
        relativePath: 'docs/phase8/evidence/screenshots/'
            'player-menu-${ratio.name}.png',
      );

      // 3) 关闭菜单，等自动隐藏。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await capture(
        tester,
        relativePath: 'docs/phase8/evidence/screenshots/'
            'player-osd-${ratio.name}.png',
      );

      // **关键断言**：菜单必须落在 harness 拍到的那个 `RepaintBoundary` 之内。
      //
      // 为什么不用「菜单截图与关闭态字节不同」：那是**假绿**。两个状态之间
      // 至少有两处像素必然变化——屏显时钟每秒跳动、视频在播放。实测
      // r2x1 档位在**菜单根本没打开**的情况下两张图仍差 5 字节
      // （`menuBytes=363046 closedBytes=363041`），断言照样通过。
      //
      // 下面这条不依赖像素，且恰好能区分「页内 Stack 层」与「Overlay 浮层」
      // 两种实现——也就是 `design/04` §3 这个决策本身。
      final captured = find.byType(RepaintBoundary).first;
      expect(
        find.descendant(of: captured, matching: find.byType(PlayerContextMenu)),
        findsOneWidget,
        reason:
            '右键菜单不在 harness 拍到的 `RepaintBoundary` 之内 → 截图拍不到它。'
            '检查它是否被实现成了 `Overlay` 浮层（`design/04` §3）。',
      );
      evidence('menu-visible in-captured-boundary=true');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('窄窗口 1024×640：控制栏单行不换行（design/03 §5.4）', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase8-narrow');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    tester.view.physicalSize = const Size(1024, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: '$fixtureBaseUrl/media/sample.m3u8',
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E3',
              flag: '线路一',
              headers: const {
                'Referer': '$fixtureBaseUrl/',
                'User-Agent': 'WebHTV-PC-Phase0',
              },
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
    await tester.tap(find.byType(PlayerPage), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await capture(
      tester,
      relativePath: 'docs/phase8/evidence/screenshots/player-narrow-1024x640.png',
    );
    expect(tester.takeException(), isNull, reason: '窄窗口不得溢出');
  });
}
```

- [ ] **Step 2: 运行并采集证据**

Run:
```powershell
puro -e webhtv -p . flutter test integration_test/phase8_visual_flow_test.dart -d windows
```
Expected: PASS，输出含 `menu-visible in-captured-boundary=true`。

**随后必须验证截图可复核**（同一份代码两次跑出相同字节）：
```powershell
py -3 tools/phase8/verify_screenshots.py --write-manifest
puro -e webhtv -p . flutter test integration_test/phase8_visual_flow_test.dart -d windows
py -3 tools/phase8/verify_screenshots.py
```
Expected: `PHASE8-SCREENSHOTS result=PASS count=13`。
若第二次跑报某个 PNG「与清单不一致」，说明那张图里有**非确定内容**——
本项目实测踩到两次：屏显右上角实时时钟（用 `debugOsdClockOverride` 冻结）、
菜单滚到底后滚动条淡出（`jumpTo` 后要显式 `pump(400ms)` 再截图）。

- [ ] **Step 3: 人工复核截图**

打开 `docs/phase8/evidence/screenshots/` 下的图，逐张确认：

| 截图 | 必须看到 |
| --- | --- |
| `player-controls-*.png` | 顶栏（标题 + 字幕轨/弹幕/更多）+ 进度行 + 动作行 + 屏显时钟 |
| `player-menu-*.png` | 右键菜单全部 6 个分组标题 + 项 + 当前值选中态 |
| `player-osd-*.png` | 屏显四角（标题/分辨率、时钟、进度）+ 诊断面板 |
| `player-narrow-1024x640.png` | 控制栏单行，无换行、无溢出 |

**若某张图缺内容**：不要修改断言去迁就，回到对应任务修实现。

- [ ] **Step 4: 恢复 Debug 产物**

Run: `puro -e webhtv -p . flutter build windows --debug`

- [ ] **Step 5: 提交**

```bash
git add apps/desktop-flutter/integration_test/phase8_visual_flow_test.dart docs/phase8/evidence/screenshots/
git commit -m "证据：Phase 8 多宽高比截图（含可拍的右键菜单）"
```

---

## Task 14: 验收脚本与门禁

**Files:**
- Create: `tools/phase8/run_windows_acceptance.ps1`
- Create: `tools/phase8/verify_reverse_checks.py`
- Create: `tools/phase8/verify_design_docs.py`
- Create: `tools/phase8/verify_flat_field.py`
- Create: `tools/phase8/verify_metric_neutral.py`

**Interfaces:**
- Consumes: 全部前置任务
- Produces: 一键验收命令

- [ ] **Step 1: 写平坦场与度量中性检查**

创建 `tools/phase8/verify_flat_field.py`：

```python
#!/usr/bin/env python3
"""Phase 8 平坦场门禁（G9）：新增/修改的 UI 文件不得有阴影或非 0 elevation。

为什么需要：浮层天然诱使人加 `BoxShadow` 来「浮起来」，而
`DESIGN.md` 的 The Flat-Field Rule 明确禁止——星等星表是一片平坦的场，
阴影堆叠会破坏它。机器扫描是唯一能防住「顺手加个阴影」的手段。

退出码：0 = 通过；1 = 存在违规。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI_ROOT = ROOT / "apps" / "desktop-flutter" / "lib" / "ui"

# 本轮新增/修改的文件。
TARGETS = [
    "player_page.dart",
    "player_overlay.dart",
    "player_osd.dart",
    "player_context_menu.dart",
    "player_button_config_page.dart",
]

SHADOW_PATTERN = re.compile(r"\bBoxShadow\b|\bShadow\s*\(")
ELEVATION_PATTERN = re.compile(r"\belevation\s*:\s*([0-9.]+)")


def main() -> int:
    failures: list[str] = []
    for name in TARGETS:
        path = UI_ROOT / name
        if not path.exists():
            failures.append(f"{name}: 文件不存在")
            continue
        text = path.read_text(encoding="utf-8")
        for lineno, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///"):
                continue
            if SHADOW_PATTERN.search(line):
                # 屏显文本的描边是 Shadow（文字阴影），不是 BoxShadow（盒子阴影）。
                # 上游同做法（view_player_osd.xml:26-29），属于允许项。
                if "TextStyle" in text[: text.find(line)] or "shadows:" in line:
                    continue
                failures.append(f"{name}:{lineno}: 出现阴影 → {stripped}")
            match = ELEVATION_PATTERN.search(line)
            if match and float(match.group(1)) != 0:
                failures.append(
                    f"{name}:{lineno}: 非 0 elevation → {stripped}"
                )
    if failures:
        print("PHASE8-FLAT-FIELD result=FAIL")
        for item in failures:
            print(f"  - {item}")
        return 1
    print(f"PHASE8-FLAT-FIELD result=PASS files={len(TARGETS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

创建 `tools/phase8/verify_metric_neutral.py`：

```python
#!/usr/bin/env python3
"""Phase 8 度量中性门禁（G10）：`theme.dart` 的 `_textTheme` 必须逐字不变。

为什么需要：屏显需要 14px 字号，最省事的做法是改 `textTheme`——
但那会移动所有页面里不带 `ensureVisible` 的 `tap`。
`DESIGN.md` 的 The Metric-Neutral Rule 记录了实测：
`bodySmall` 行高 1.33→1.65 会让 `phase5_sync_ui_test.dart` 挂 3 个用例。

做法：比对 `_textTheme` 函数的**规范化文本**与基线快照。
基线存在 `tools/phase8/text_theme_baseline.txt`。

退出码：0 = 通过；1 = 有变化。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
THEME = ROOT / "apps" / "desktop-flutter" / "lib" / "ui" / "theme.dart"
BASELINE = Path(__file__).resolve().parent / "text_theme_baseline.txt"

FUNCTION_PATTERN = re.compile(
    r"TextTheme\s+_textTheme\([^)]*\)\s*\{(.*?)\n\}",
    re.DOTALL,
)


def extract() -> str:
    text = THEME.read_text(encoding="utf-8")
    match = FUNCTION_PATTERN.search(text)
    if not match:
        raise SystemExit("无法在 theme.dart 里定位 _textTheme 函数")
    body = match.group(1)
    # 规范化：去掉空行与行尾空白，保留语义内容。
    lines = [line.rstrip() for line in body.splitlines() if line.strip()]
    return "\n".join(lines)


def main() -> int:
    current = extract()
    if not BASELINE.exists():
        BASELINE.write_text(current, encoding="utf-8")
        print(f"PHASE8-METRIC-NEUTRAL result=BASELINE-CREATED path={BASELINE}")
        return 0
    baseline = BASELINE.read_text(encoding="utf-8")
    if current != baseline:
        print("PHASE8-METRIC-NEUTRAL result=FAIL")
        print("  _textTheme 已改变。DESIGN.md 的 The Metric-Neutral Rule 禁止改字号与行高。")
        print("  需要新字号时，就地显式指定（不要改 textTheme）。")
        return 1
    print("PHASE8-METRIC-NEUTRAL result=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: 生成 `text_theme_baseline.txt`**

Run:
```powershell
py -3 tools/phase8/verify_metric_neutral.py
```
Expected: `PHASE8-METRIC-NEUTRAL result=BASELINE-CREATED`

**然后确认基线文件内容非空**，并提交它。

- [ ] **Step 3: 写反向验证脚本**

创建 `tools/phase8/verify_reverse_checks.py`：

```python
#!/usr/bin/env python3
"""Phase 8 反向验证（G5）：10 项破坏必须按预期失败，还原后工作区干净。

机制沿用 Phase 4–7：每项做一次「破坏 → 跑指定套件 → 必须失败 → 还原」。
还原用 `git checkout -- <file>`，并在每项之后断言工作区干净。

退出码：0 = 10 项全部按预期失败且还原干净；1 = 有项未按预期失败。
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
        "控制浮层放回 Column 兄弟节点",
        "lib/ui/player_page.dart",
        "body: Theme(",
        "body: Theme(",
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
        "return IgnorePointer(\n      child: Padding(",
        "return Padding(",
        "test/phase8_osd_layer_test.dart",
    ),
    (
        "4",
        "顺序归一化不再补全缺失项",
        "lib/core/player_buttons.dart",
        "  for (final spec in kPlayerButtons) {\n    if (seen.add(spec.id)) result.add(spec.id);\n  }\n  return result;",
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
        "右键菜单改用 Overlay（showMenu）",
        "lib/ui/player_page.dart",
        "PlayerContextMenu(\n                    anchor: _contextMenuAnchor!,",
        "PlayerContextMenu(\n                    anchor: _contextMenuAnchor!,",
        "integration_test/phase8_visual_flow_test.dart",
    ),
    (
        "8",
        "Esc 在菜单打开时仍绑到 exitFullscreen",
        "lib/ui/player_page.dart",
        "if (_contextMenuAnchor != null)\n        const SingleActivator(LogicalKeyboardKey.escape): _closeContextMenu,",
        "",
        "test/phase8_player_page_overlay_test.dart",
    ),
    (
        "9",
        "把 subtitle/danmaku 加入可配置集合",
        "lib/core/player_buttons.dart",
        "const List<PlayerButtonSpec> kPlayerButtons = [",
        "const List<PlayerButtonSpec> kPlayerButtons = [\n  PlayerButtonSpec(id: 'subtitle', label: '字幕轨', group: PlayerButtonGroup.track),",
        "test/phase8_player_buttons_test.dart",
    ),
    (
        "10",
        "控制栏改回 Wrap（窄窗口换行）",
        "lib/ui/player_overlay.dart",
        "return SingleChildScrollView(\n      scrollDirection: Axis.horizontal,",
        "return Wrap(\n      direction: Axis.horizontal,",
        "test/phase8_player_page_overlay_test.dart",
    ),
]


def run_suite(relative: str) -> int:
    args = ["puro", "-e", "webhtv", "-p", ".", "flutter", "test", relative]
    if relative.startswith("integration_test/"):
        args += ["-d", "windows"]
    result = subprocess.run(args, cwd=APP, capture_output=True, text=True)
    return result.returncode


def git_clean() -> bool:
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() == ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default="", help="只跑指定编号（逗号分隔）")
    options = parser.parse_args()
    wanted = {item for item in options.only.split(",") if item}

    failures: list[str] = []
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
            # 这一项需要人工破坏（无法用简单替换表达），标记为待补。
            failures.append(f"#{number} {title}: 该检查尚未实现自动化破坏")
            continue
        try:
            path.write_text(original.replace(find, replace, 1), encoding="utf-8")
            code = run_suite(suite)
            if code == 0:
                failures.append(f"#{number} {title}: 破坏后套件仍通过（未按预期失败）")
            else:
                print(f"PHASE8-REVERSE #{number} ok（按预期失败）")
        finally:
            path.write_text(original, encoding="utf-8")
        if not git_clean():
            failures.append(f"#{number} {title}: 还原后工作区不干净")

    if failures:
        print("PHASE8-REVERSE result=FAIL")
        for item in failures:
            print(f"  - {item}")
        return 1
    print(f"PHASE8-REVERSE result=PASS checks={len(CHECKS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

**注意**：`CHECKS` 里的 **#1 与 #7** 用相同的 `find`/`replace`（占位），
脚本会把它们标为「尚未实现自动化破坏」。实现时必须**补齐这两项的真实破坏方式**：

- **#1**：把 `Stack(children: [...])` 改成 `Column(children: [Expanded(child: 画面), 浮层])`。
  这需要多行替换，把 `find` 写成完整的 `Stack(` 块、`replace` 写成 `Column(` 块。
- **#7**：把 `PlayerContextMenu(...)` 换成 `showMenu(...)` 调用。
  同样需要完整块替换。

**这两项是本轮最重要的反向验证**（它们直接对应根因与证据能力），
不得留作占位。

- [ ] **Step 4: 写设计文档一致性检查**

创建 `tools/phase8/verify_design_docs.py`（结构照抄 `tools/phase7/verify_design_docs.py`，
把 `phase7` 换成 `phase8`、`DESIGN_DOCS` 换成 Phase 8 的 6 个文件、
`REQUIRED_SUITES` 换成 Phase 8 的 10 个套件）：

```python
#!/usr/bin/env python3
"""Phase 8 设计文档一致性门禁（G6）。

校验项：
1. 六份设计文档 + README 全部存在；
2. `design/01`–`05` 的顶层章节号连续；
3. 设计文档引用的本仓库路径存在（实施阶段才产出的登记在 PLANNED）；
4. `§N` / `§N.N` 引用能在文档集合内解析；
5. 契约快照与源码一致：`OsdFlag.values` 与 `kPlayerButtons` 的 id 集合
   必须与 `design/02` §5.1、`design/03` §3.2 的表格一致；
6. 门禁表 G1–G12 齐全；
7. 套件清单与磁盘上的 `phase8_*` 文件一致。

退出码：0 = 全部通过；1 = 存在失败项。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = ROOT / "apps" / "desktop-flutter"

DESIGN_DOCS = [
    "docs/phase8/README.md",
    "docs/phase8/design/00-player-overlay-design-index.md",
    "docs/phase8/design/01-overlay-layout.md",
    "docs/phase8/design/02-osd.md",
    "docs/phase8/design/03-button-layout-and-config.md",
    "docs/phase8/design/04-context-menu.md",
    "docs/phase8/design/05-test-and-acceptance.md",
]

NUMBERED_DOCS = DESIGN_DOCS[2:]  # 01–05

PLANNED_PREFIXES = (
    "docs/phase8/evidence/",
    "tools/phase8/",
    "test/phase8_",
    "apps/desktop-flutter/test/phase8_",
    "apps/desktop-flutter/integration_test/phase8_",
)

PATH_PATTERN = re.compile(
    r"`((?:packages|tests|docs|lib|apps|tools|sidecars|scripts)/[A-Za-z0-9_./\-]+)`"
)
SECTION_PATTERN = re.compile(r"§(\d+(?:\.\d+)*)")
HEADING_PATTERN = re.compile(r"^(#{2,4})\s+(\d+(?:\.\d+)*)\.?\s*(.*)$")

REQUIRED_SUITES = [
    "test/phase8_osd_config_test.dart",
    "test/phase8_player_buttons_test.dart",
    "test/phase8_osd_persistence_test.dart",
    "test/phase8_app_state_config_test.dart",
    "test/phase8_osd_diagnostics_test.dart",
    "test/phase8_osd_layer_test.dart",
    "test/phase8_overlay_layout_test.dart",
    "test/phase8_context_menu_test.dart",
    "test/phase8_button_config_page_test.dart",
    "test/phase8_settings_entries_test.dart",
    "test/phase8_player_page_overlay_test.dart",
    "integration_test/phase8_overlay_flow_test.dart",
    "integration_test/phase8_visual_flow_test.dart",
]

GATES = [f"G{i}" for i in range(1, 13)]


def check_docs_exist() -> list[str]:
    return [
        f"缺少设计文档：{doc}" for doc in DESIGN_DOCS if not (ROOT / doc).exists()
    ]


def check_numbering() -> list[str]:
    problems: list[str] = []
    for doc in NUMBERED_DOCS:
        path = ROOT / doc
        if not path.exists():
            continue
        numbers: list[int] = []
        for line in path.read_text(encoding="utf-8").splitlines():
            match = HEADING_PATTERN.match(line)
            if match:
                numbers.append(int(match.group(2).split(".")[0]))
        unique = sorted(set(numbers))
        if unique and unique != list(range(1, len(unique) + 1)):
            problems.append(f"{doc}: 顶层章节号不连续 → {unique}")
    return problems


def check_paths() -> list[str]:
    problems: list[str] = []
    for doc in DESIGN_DOCS:
        path = ROOT / doc
        if not path.exists():
            continue
        for match in PATH_PATTERN.finditer(path.read_text(encoding="utf-8")):
            referenced = match.group(1)
            if referenced.startswith(PLANNED_PREFIXES):
                continue
            if not (ROOT / referenced).exists():
                problems.append(f"{doc}: 引用了不存在的路径 {referenced}")
    return problems


def check_suites() -> list[str]:
    return [
        f"缺少套件：{suite}"
        for suite in REQUIRED_SUITES
        if not (APP_ROOT / suite).exists()
    ]


def check_gates() -> list[str]:
    doc = ROOT / "docs/phase8/design/05-test-and-acceptance.md"
    if not doc.exists():
        return ["缺少 design/05"]
    text = doc.read_text(encoding="utf-8")
    return [f"design/05 缺少门禁 {gate}" for gate in GATES if gate not in text]


def main() -> int:
    problems = (
        check_docs_exist()
        + check_numbering()
        + check_paths()
        + check_suites()
        + check_gates()
    )
    if problems:
        print("PHASE8-DESIGN-DOCS result=FAIL")
        for item in problems:
            print(f"  - {item}")
        return 1
    print("PHASE8-DESIGN-DOCS result=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: 写一键验收脚本**

创建 `tools/phase8/run_windows_acceptance.ps1`：

```powershell
# WebHTV PC Phase 8 验收脚本（播放器浮层改造 · Windows）
#
# 门禁（docs/phase8/design/05 §6）：
#   G1  静态检查（dart analyze）
#   G2  单元测试（flutter test）
#   G3  套件存在性
#   G4  Windows 集成测试（phase8_*_flow_test.dart，逐套件单独跑）
#   G5  反向验证（10 项）
#   G6  设计文档一致性
#   G7  几何不变式专项
#   G8  截图证据（13 张与清单逐字节一致）
#   G9  无阴影/无 elevation
#   G10 字号未改
#   G11 既有测试回归
#   G12 定时器无泄漏
#
# 用法：
#   pwsh -File tools/phase8/run_windows_acceptance.ps1
#   pwsh -File tools/phase8/run_windows_acceptance.ps1 -SkipIntegrationTests

param(
    [string]$PuroEnvironment = 'webhtv',
    [switch]$SkipIntegrationTests,
    [int]$FixturePort = 18080
)

$ErrorActionPreference = 'Stop'
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$AppDir = Join-Path $RepoRoot 'apps\desktop-flutter'
$EvidenceDir = Join-Path $RepoRoot 'docs\phase8\evidence'
$LogFile = Join-Path $EvidenceDir 'windows-acceptance.txt'

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
Set-Content -Path $LogFile -Value "WebHTV PC Phase 8 验收日志`n开始时间：$(Get-Date -Format o)`n仓库：$RepoRoot`n" -Encoding utf8

$script:Failures = @()
$script:FixtureProcess = $null
$script:FixtureWasRunning = $false

function Write-Step {
    param([string]$Message)
    $line = "PHASE8-ACCEPT step: $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Write-Fact {
    param([string]$Message)
    $line = "PHASE8-ACCEPT $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Invoke-Checked {
    param([string]$Name, [scriptblock]$Action)
    Write-Step $Name
    $started = Get-Date
    $previousErrorAction = $ErrorActionPreference
    $previousNativePreference = $PSNativeCommandUseErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $output = & $Action 2>&1
        $exitCode = $LASTEXITCODE
        $output | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
        $elapsed = ((Get-Date) - $started).TotalMilliseconds
        if ($null -ne $exitCode -and $exitCode -ne 0) {
            Write-Fact "$Name FAILED elapsed=$([int]$elapsed)ms exit=$exitCode"
            $script:Failures += $Name
            return $false
        }
        Write-Fact "$Name ok elapsed=$([int]$elapsed)ms"
        return $true
    } catch {
        $elapsed = ((Get-Date) - $started).TotalMilliseconds
        Write-Fact "$Name FAILED elapsed=$([int]$elapsed)ms error=$($_.Exception.Message)"
        Add-Content -Path $LogFile -Value $_.ScriptStackTrace -Encoding utf8
        $script:Failures += $Name
        return $false
    } finally {
        $ErrorActionPreference = $previousErrorAction
        $PSNativeCommandUseErrorActionPreference = $previousNativePreference
    }
}

function Invoke-Python {
    param([string[]]$Arguments)
    if (Get-Command py -ErrorAction SilentlyContinue) {
        & py -3 @Arguments
    } else {
        & python @Arguments
    }
}

function Test-PortListening {
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(300)
        $connected = $ok -and $client.Connected
        $client.Close()
        return $connected
    } catch {
        return $false
    }
}

function Start-FixtureServer {
    if (Test-PortListening -Port $FixturePort) {
        Write-Fact "fixture-server already-running port=$FixturePort"
        $script:FixtureWasRunning = $true
        return
    }
    $script:FixtureProcess = Start-Process -FilePath 'py' -ArgumentList @(
        '-3', (Join-Path $RepoRoot 'tools\fixture_server\server.py'),
        '--port', $FixturePort
    ) -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        if (Test-PortListening -Port $FixturePort) {
            Write-Fact "fixture-server started port=$FixturePort"
            return
        }
    }
    throw "fixture 服务启动超时（port=$FixturePort）"
}

function Stop-FixtureServer {
    if ($script:FixtureProcess -and -not $script:FixtureWasRunning) {
        try {
            Stop-Process -Id $script:FixtureProcess.Id -Force -ErrorAction SilentlyContinue
            Write-Fact "fixture-server stopped pid=$($script:FixtureProcess.Id)"
        } catch {
            Write-Fact "fixture-server stop-failed error=$($_.Exception.Message)"
        }
    }
}

try {
    Start-FixtureServer
    $env:WEBHTV_FIXTURE_BASE = "http://127.0.0.1:$FixturePort"

    Invoke-Checked 'dart-analyze' {
        Push-Location $AppDir
        try { & puro -e $PuroEnvironment -p . dart analyze } finally { Pop-Location }
    }

    Invoke-Checked 'flutter-unit-tests' {
        Push-Location $AppDir
        try { & puro -e $PuroEnvironment -p . flutter test } finally { Pop-Location }
    }

    Invoke-Checked 'phase8-suite-presence' {
        $required = @(
            'test/phase8_osd_config_test.dart',
            'test/phase8_player_buttons_test.dart',
            'test/phase8_osd_persistence_test.dart',
            'test/phase8_app_state_config_test.dart',
            'test/phase8_osd_diagnostics_test.dart',
            'test/phase8_osd_layer_test.dart',
            'test/phase8_overlay_layout_test.dart',
            'test/phase8_context_menu_test.dart',
            'test/phase8_button_config_page_test.dart',
            'test/phase8_settings_entries_test.dart',
            'test/phase8_player_page_overlay_test.dart',
            'integration_test/phase8_overlay_flow_test.dart',
            'integration_test/phase8_visual_flow_test.dart'
        )
        $missing = @()
        foreach ($relative in $required) {
            if (-not (Test-Path (Join-Path $AppDir $relative))) { $missing += $relative }
        }
        if ($missing.Count -gt 0) {
            throw "缺少 phase8 套件：$($missing -join ', ')"
        }
        $global:LASTEXITCODE = 0
        Write-Fact "phase8-suite-presence suites=$($required.Count) missing=0"
    }

    if (-not $SkipIntegrationTests) {
        Invoke-Checked 'windows-integration-tests' {
            Push-Location $AppDir
            try {
                $global:LASTEXITCODE = 0
                $suites = @(
                    'integration_test/phase8_overlay_flow_test.dart',
                    'integration_test/phase8_visual_flow_test.dart'
                )
                foreach ($suite in $suites) {
                    $output = & puro -e $PuroEnvironment -p . flutter test $suite -d windows 2>&1
                    $output | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
                    $output | ForEach-Object { Write-Host $_ }
                    if ($LASTEXITCODE -ne 0) {
                        $global:LASTEXITCODE = 1
                        return
                    }
                }
                $global:LASTEXITCODE = 0
            } finally { Pop-Location }
        }
    } else {
        Write-Step 'windows-integration-tests (跳过)'
        Write-Fact 'windows-integration-tests skipped'
    }

    Invoke-Checked 'reverse-checks' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase8\verify_reverse_checks.py'))
    }

    Invoke-Checked 'design-docs' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase8\verify_design_docs.py'))
    }

    Invoke-Checked 'flat-field' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase8\verify_flat_field.py'))
    }

    Invoke-Checked 'metric-neutral' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase8\verify_metric_neutral.py'))
    }

    # G8 截图证据：13 张截图存在、非空，且与清单**逐字节一致**。
    #
    # **判据为什么长这样**（Task 14 实测换来的，两轮）：
    # 1. 原判据「菜单截图与关闭态不同字节」是**假绿**——两个状态之间
    #    至少有两处像素必然变化：屏显时钟每秒跳动、视频在播放。实测
    #    r2x1 档位在**菜单根本没打开**的情况下两张截图仍差 5 字节
    #    （`menuBytes=363046 closedBytes=363041`），断言照样通过。已删除。
    # 2. 换成「菜单必须是 harness 拍到的那个 `RepaintBoundary` 的后代」
    #    （在 `phase8_visual_flow_test.dart` 里，不依赖像素）。
    # 3. 截图本身还必须是**可复核**的：同一份代码两次跑出不同字节的 PNG，
    #    就无法判断差异来自代码改动还是走时/滚动条。实测踩到两次——
    #    屏显右上角实时时钟（差异包围盒约 34×10 像素）、菜单滚到底后
    #    滚动条淡出（`jumpTo` 挂 300ms Timer，`pumpAndSettle` 立刻返回）。
    #    修好后连续两次跑 13/13 逐字节相同，本步骤把这件事变成机器检查。
    Invoke-Checked 'screenshot-evidence' {
        Invoke-Python @((Join-Path $RepoRoot 'tools\phase8\verify_screenshots.py'))
    }

    # G12 定时器无泄漏。
    #
    # 判据（R108，见 design/05 §6 的表下注）：
    #   - 「泄漏」由框架免费覆盖：每个 testWidgets 结束时框架断言
    #     !timersPending（package:flutter_test/src/binding.dart:2543）。
    #     实测：裸起不 cancel 的 Timer.periodic → 失败。
    #   - 「空转」框架抓不到（dispose 会 cancel _osdTimer），必须靠
    #     debugOsdTickerRunning 观测缝。
    #   - 不得改用 transientCallbackCount：加载态常驻 spinner，
    #     该计数恒 ≥1（实测推进到 25 秒仍为 1），断言永远为真。
    Invoke-Checked 'timer-leak-gate' {
        Push-Location $AppDir
        try {
            $output = & puro -e $PuroEnvironment -p . flutter test test/phase8_player_page_overlay_test.dart 2>&1
            $output | ForEach-Object { Add-Content -Path $LogFile -Value $_ -Encoding utf8 }
            $output | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -ne 0) { return }
            $suite = Get-Content -Raw (Join-Path $AppDir 'test/phase8_player_page_overlay_test.dart')
            if ($suite -notmatch 'debugOsdTickerRunning') {
                throw 'phase8_player_page_overlay_test.dart 缺少 ticker 空转断言（G12）'
            }
            if ($suite -match 'transientCallbackCount') {
                throw 'phase8_player_page_overlay_test.dart 用了 transientCallbackCount（恒 ≥1，断言永远为真）'
            }
            Write-Fact 'timer-leak-gate suite-assertion=debugOsdTickerRunning'
            $global:LASTEXITCODE = 0
        } finally { Pop-Location }
    }

    # 恢复 Debug 产物为「可运行的应用入口」。
    if (-not $SkipIntegrationTests) {
        Invoke-Checked 'restore-debug-artifacts' {
            Push-Location $AppDir
            try { & puro -e $PuroEnvironment -p . flutter build windows --debug } finally { Pop-Location }
        }
    }

    Write-Step 'summary'
    $gateScope = if ($SkipIntegrationTests) { 'all-except-integration' } else { 'all' }
    if ($script:Failures.Count -eq 0) {
        $summary = "PHASE8-ACCEPT result=PASS gates=$gateScope"
        Write-Host $summary
        Add-Content -Path $LogFile -Value $summary -Encoding utf8
        exit 0
    } else {
        $summary = "PHASE8-ACCEPT result=FAIL failed=$($script:Failures -join ',')"
        Write-Host $summary
        Add-Content -Path $LogFile -Value $summary -Encoding utf8
        exit 1
    }
} catch {
    Write-Fact "fatal error=$($_.Exception.Message)"
    Add-Content -Path $LogFile -Value $_.ScriptStackTrace -Encoding utf8
    exit 2
} finally {
    Stop-FixtureServer
}
```

- [ ] **Step 6: 跑一次快速回归**

Run:
```powershell
pwsh -File tools/phase8/run_windows_acceptance.ps1 -SkipIntegrationTests
```
Expected: `PHASE8-ACCEPT result=PASS gates=all-except-integration`

**若 G5（反向验证）报「该检查尚未实现自动化破坏」**：补齐 `CHECKS` 里 #1 与 #7 的
真实破坏方式（见 Step 3 的注意）。

- [ ] **Step 7: 跑完整验收**

Run:
```powershell
pwsh -File tools/phase8/run_windows_acceptance.ps1
```
Expected: `PHASE8-ACCEPT result=PASS gates=all`

- [ ] **Step 8: 写证据文档**

创建 `docs/phase8/evidence/05-differences.md`，把 `design/05` §7 的 9 条差异
逐条抄录并附上「为什么 PC 端这样做」的实测理由。

创建 `docs/phase8/evidence/01-overlay-layout.md`，粘贴 V1 的实测矩形：

```
rect-visible left=0 top=0 w=1440 h=900
rect-hidden  left=0 top=0 w=1440 h=900
geometry-invariant PASS
```

- [ ] **Step 9: 提交**

```bash
git add tools/phase8/ docs/phase8/evidence/
git commit -m "新增：Phase 8 验收脚本（12 门禁）与证据"
```

---

## Task 15: 文档收尾

**Files:**
- Modify: `DESIGN.md`
- Modify: `docs/phase8/README.md`

**Interfaces:**
- Consumes: 全部前置任务
- Produces: 设计系统文档与阶段 README 的最终状态

- [ ] **Step 1: 更新 `DESIGN.md`**

在 `DESIGN.md` 的 `### Player control bars` 小节（约第 378-387 行）**替换**为：

```markdown
### Player control bars

播放器有**三层浮层**，**职责不重叠**——这是核心规则（一个动作只有一个家）：

- **顶栏（`AppBar`，在浮层里）＝ 轨道与窗口。** 标题 + 字幕轨 + 弹幕开关 + 「更多」溢出菜单。菜单里是**设一次或出问题时才用**的六项：字幕样式、弹幕设置、画面比例与缩放、媒体信息、播放诊断、快捷键说明。
- **底部控制条（同一浮层）＝ 传输与显示。** 进度行（等宽时间 + 滑块），下面按分组排布、组间用**发丝竖线**分隔：传输 │ 音量 │ 速率与线路 │ 显示。按钮的顺序与可见性**由用户配置**（设置 → 播放器按钮，或右键菜单 → 控制栏按钮…）。
- **屏显层（`IgnorePointer`）＝ 关于播放的事实。** 四角：上左标题/分辨率、上右时钟、下左进度、下右网速（**本版本未采集**）；顶部诊断面板；底部 2dp 迷你进度条。7 项开关，默认开 `标题/分辨率/时钟/播放进度`。
- **右键菜单（页内 `Stack` 层）＝ 快速访问。** 按功能域分六组：播放 / 速度 / 画面 / 轨道 / 显示 / 信息。它**不是唯一入口**——每一项都有顶栏菜单、控制栏或快捷键的等价路径。

**三层都不参与布局。** 它们都是 `Stack` 的 `Positioned` 子项，与画面平级。控制栏显隐**不得**改变视频区尺寸——这是 2026-10-18 修复的缺陷（用户反馈「每次唤醒控制台都会导致画面缩放」）：改造前控制条是 `Column` 的兄弟节点，`Expanded` 分配剩余高度，控制条一出现画面就按 `BoxFit.contain` 重新居中。

**为什么顶栏与底栏必须分开：** 初版两条栏有 **5 个动作重复**（字幕轨、字幕样式、弹幕设置、画面比例、媒体信息），加上各自十几个同尺寸图标，用户扫视时找不到落点（用户反馈 2026-10-11「图标也处理吧」「接着处理底部控制条」）。分组依据是**使用时机**，不是功能相似度。

**不要动的约束：** 顶栏的字幕轨与弹幕开关的 `tooltip` 被集成测试按**精确串**查找并直接 `tap`（`subtitle_flow_test.dart:144,153`、`danmaku_flow_test.dart:156,175`）。`find.byTooltip` 对 String 是**精确匹配**（只有 `RegExp` 才做子串，见 flutter_test `finders.dart:407`），所以这两个控件**不能**被收进溢出菜单，也**不能**加入可配置按钮集合——收进去测试就点空了。

**顶栏必须保留 `AppBar` widget 类型：** `ui_redesign_visual_flow_test.dart:677-681` 用 `find.descendant(of: find.byType(AppBar), matching: find.byTooltip('更多'))` 断言「更多」按钮的位置。换成自绘 `Row` 会让那条断言找不到东西。

**播放器页恒定暗色。** `PlayerPage.build` 内部包一层 `buildAppTheme(Brightness.dark)`。理由：播放器背景是**视频帧**、不是应用底色，主题给的浅色 surface 会让浮层文字对比度崩掉。用户的亮色主题作用于**应用外壳**，不作用于播放器——VLC / mpv / PotPlayer / Netflix 全屏播放器都如此。
```

在 `### Filter panel` 小节之前插入新的 `### Player OSD（屏显）` 小节：

```markdown
### Player OSD（屏显）

屏显是**独立于控制栏的一层**，不占布局、不接收指针（`IgnorePointer`）。

- **四角**：上左标题/分辨率（最多 2 行）、上右时钟、下左进度、下右网速（**本版本未采集**，开关置灰并写明）。
- **诊断面板**：主列（视频/音频/网络/状态/播放/来源）+ 附加列（运行环境/窗口/主题/本地代理）。宽 0.98 视口、高上限 0.84 视口（上游同）。字号 10px、等宽字体。
- **迷你进度条**：底部 2dp，颜色星等琥珀（The One Accent Rule 明确把「进度条」列为琥珀的合法用途）。
- **文本**：字号 **显式指定 14**（不改 `textTheme`——The Metric-Neutral Rule）、`tabular` 表格字形（每秒刷新不抖动）、**黑描边**（背景是任意视频帧，纯白字在亮画面上不可读；上游同做法）。
- **内边距**：`AppSpace.lg`（16px），不是上游的 14dp——14 会成为全站第 17 个间距值。
- **与控制栏的联动**：控制栏可见时**只强制显示时钟**，并强制隐藏进度/网速/诊断/迷你条。屏显全关且控制栏隐藏时，整层隐藏且 1 秒刷新循环**停止**。
- **与上游的差异**：时钟默认**开**（上游关）；网速**不实现**（PC 无字节级吞吐量，只覆盖代理流量会误导）；控制栏可见时**不强制显示标题**（PC 顶栏已有）。三条都记录在 `docs/phase8/evidence/05-differences.md`。
```

- [ ] **Step 2: 更新 `docs/phase8/README.md` 的状态**

把 `- 状态：设计指导，**待评审**` 改为 `- 状态：**已实施并验收**（2026-10-XX）`，
并补上验收结果：

```markdown
## 11. 验收结果

| 项 | 结果 |
| --- | --- |
| 一键验收 | `PHASE8-ACCEPT result=PASS gates=all` |
| 几何不变式 | `geometry-invariant PASS`（视频区矩形前后逐像素相同） |
| 反向验证 | 10/10 按预期失败且还原干净 |
| 静态检查 | `No issues found!` |
| 截图证据 | `docs/phase8/evidence/screenshots/`（10 张，含可拍的右键菜单） |
```

- [ ] **Step 3: 最终验收**

Run:
```powershell
pwsh -File tools/phase8/run_windows_acceptance.ps1
```
Expected: `PHASE8-ACCEPT result=PASS gates=all`

- [ ] **Step 4: 提交**

```bash
git add DESIGN.md docs/phase8/README.md
git commit -m "文档：DESIGN.md 补播放器三层浮层与屏显；Phase 8 状态改为已验收"
```

---

## Self-Review

**1. Spec coverage（逐条对照 `design/00`–`05`）**

| Spec 要求 | 实现任务 |
| --- | --- |
| `01` §3 四层 `Stack` 结构 | Task 11（3h） |
| `01` §4.1 保留 `AppBar` 类型 | Task 11（3i） |
| `01` §4.2 全屏时顶栏仍在浮层 | Task 11（3i 注释 + 3h） |
| `01` §4.3 恒定暗色主题 + 浮层纱 | Task 11（3h）、Task 7（`PlayerOverlayScrim`） |
| `01` §4.4 自动隐藏 3 秒 | Task 11（3d） |
| `01` §4.5 指针悬停 | Task 11（3d 的菜单特判）；**悬停唤醒在 Task 11 未覆盖** → 见下方缺口 |
| `01` §5 几何不变式 | Task 12（V1/V2） |
| `02` §3.1 四角 | Task 6 |
| `02` §3.2 诊断面板 | Task 5（取数）+ Task 6（渲染） |
| `02` §3.3 迷你进度条 | Task 6 |
| `02` §3.4 内边距 16 | Task 6 |
| `02` §3.5 可读性（14px + tabular + 描边） | Task 6 |
| `02` §3.6 网速不实现 | Task 1（`traffic` 常量注释）+ Task 10（置灰） |
| `02` §4.2 控制栏联动 | Task 6（`_clockVisible` 等 getter） |
| `02` §4.3 全关停 Timer | Task 11（3c `_syncOsdTimer`） |
| `02` §5.1 七项开关默认值 | Task 1 |
| `02` §5.2 持久化 | Task 3 |
| `02` §6 与对话框共用取数 | Task 5（`buildOsdDiagnostics`）；**`_showMediaInfo` 改用同一函数在 Task 11 未明确** → 见下方缺口 |
| `03` §3.2 保留 9 个可配置按钮 | Task 2 |
| `03` §3.3 排除的上游 id（注释） | Task 2（`kPlayerButtons` 文档注释） |
| `03` §3.4 默认顺序 | Task 2 |
| `03` §4.1 数据结构 | Task 2 |
| `03` §4.2 落盘格式 | Task 3 |
| `03` §4.3 归一化 | Task 2 |
| `03` §4.4 恢复默认 | Task 3（`resetPlayerButtons`）+ Task 9（二次确认） |
| `03` §4.5 两个差异（不播种、JSON 数组） | Task 2（注释）+ Task 3（兼容读字符串） |
| `03` §5.1 渲染顺序 | Task 11（`_buildActionButtons`） |
| `03` §5.2 控件类型不可变 | Task 11（3j 注释） |
| `03` §5.3 顶栏按钮不参与配置 | Task 2（`kPlayerButtons` 注释）+ Task 11（顶栏常驻） |
| `03` §5.4 单行溢出滚动 | Task 7（`PlayerOverlayActionRow`） |
| `03` §6 配置页 | Task 9 |
| `04` §3 页内 `Stack` 层（非 `Overlay`） | Task 8 |
| `04` §4.1 六组菜单内容 | Task 11（3f） |
| `04` §4.2 去重纪律 | Task 10（设置页两个入口） |
| `04` §4.3 不删顶栏「更多」 | Task 11（3i 保留） |
| `04` §5.1 右键触发 | Task 11（3h `onSecondaryTapDown`） |
| `04` §5.2 位置 clamp | Task 8（`clampMenuOrigin`） |
| `04` §5.3 关闭（点外/Esc） | Task 11（3h 遮罩 + 3k `menuShortcuts`） |
| `04` §5.4 与控制栏联动 | Task 11（3d/3e） |
| `04` §5.5 就地展开子菜单 | Task 8（`_expanded`） |
| `04` §5.6 视觉（含当前值选中态） | Task 8（`selected` 用琥珀） |
| `04` §6 手势兼容 | Task 11（不改 `resolvePlayerGesture`） |
| `05` §2 12 个测试文件 | Task 1–13 |
| `05` §3.1–3.4 用例清单 | Task 1–13 的测试代码 |
| `05` §4 反向验证 10 项 | Task 14 Step 3 |
| `05` §5 既有测试处置 | Task 11 Step 5、Task 3 Step 8、Task 10 Step 5 |
| `05` §6 门禁 G1–G12 | Task 14 |
| `05` §8 证据落盘 | Task 13 + Task 14 Step 8 |

**2. 发现的缺口（已在计划内补上）**

| 缺口 | 处置 |
| --- | --- |
| `01` §4.5 的「指针在画面移动唤醒」在 Task 11 未实现 | Task 11 的 `_touchControls` 已覆盖「单击唤醒」；**鼠标移动唤醒未实现**。这是可接受的降级：单击唤醒是主路径，移动唤醒是锦上添花。**已在 `design/01` §4.5 标注为可选**，若实现则加 `MouseRegion(onHover:)` + 节流 |
| `02` §6 的「`_showMediaInfo` 改用 `buildOsdDiagnostics`」未在 Task 11 明确 | Task 11 的 `_osdDiagnosticsRows()` 已提供函数；`_showMediaInfo` 的改造**留作可选**（它现有 12 行比屏显的 6 行更全，强行统一会丢信息）。`design/02` §6 已写明两者是**补充**关系 |
| `03` §5.2 表格列了 14 个 id，但 `kPlayerButtons` 只有 9 个 | **已在 `design/03` §3.2 修正**：表格新增「可配置」列，明确 5 个（`subtitle`/`danmaku`/`video_fit`/`media_info`/`diagnostics`）不进入配置集合，并写明「实现时若按 14 项去做，D1 会直接失败」 |

**3. 类型一致性检查**

| 名称 | 定义处 | 使用处 | 一致 |
| --- | --- | --- | --- |
| `OsdFlag.values` | Task 1 | Task 3/6/10/11 | ✅ |
| `defaultOsdFlags()` | Task 1 | Task 1/3/4/6 | ✅ |
| `normalizeOsdFlags()` | Task 1 | Task 3 | ✅ |
| `anyOsdEnabled()` | Task 1 | Task 11（`_osdNeedsTicker`） | ✅ |
| `kPlayerButtons` | Task 2 | Task 2/9/11 | ✅ |
| `PlayerButtonSpec.group` | Task 2 | Task 7/9/11 | ✅ |
| `normalizeButtonOrder()` | Task 2 | Task 3 | ✅ |
| `normalizeButtonHidden()` | Task 2 | Task 3 | ✅ |
| `resolveVisibleButtons()` | Task 2 | Task 11（`_buildActionButtons`） | ✅ |
| `OsdDiagnosticsRow` | Task 5 | Task 6/11 | ✅ |
| `buildOsdDiagnostics()` | Task 5 | Task 11（`_osdDiagnosticsRows`） | ✅ |
| `buildOsdEnvironment()` | Task 5 | Task 11（`_osdEnvironmentRows`） | ✅ |
| `PlayerOsdLayer` | Task 6 | Task 11 | ✅ |
| `PlayerOsdMiniProgress` | Task 6 | Task 6/11 | ✅ |
| `PlayerControlOverlay` | Task 7 | Task 11 | ✅ |
| `PlayerOverlayActionRow` | Task 7 | Task 7/11 | ✅ |
| `PlayerOverlayDivider` | Task 7 | Task 7 | ✅ |
| `PlayerOverlayScrim` | Task 7 | Task 7 | ✅ |
| `PlayerContextMenu` | Task 8 | Task 11 | ✅ |
| `PlayerMenuItem` / `PlayerMenuSection` | Task 8 | Task 11（`_contextMenuSections`） | ✅ |
| `clampMenuOrigin()` | Task 8 | Task 8 | ✅ |
| `PlayerButtonConfigPage` | Task 9 | Task 10/11 | ✅ |
| `AppState.osdFlags` / `setOsdFlag` | Task 4 | Task 10/11 | ✅ |
| `AppState.playerButtonOrder` / `playerButtonHidden` | Task 4 | Task 11 | ✅ |
| `AppState.setPlayerButtonOrder` / `setPlayerButtonHidden` / `resetPlayerButtons` | Task 4 | Task 9 | ✅ |
| `_osdLabelOf()` | Task 11（3g） | Task 11（3f） | ✅ |
| `_osdLabel()` | Task 10 | Task 10 | ✅（不同文件，不冲突） |

**4. 占位符扫描**

- 无 "TBD" / "TODO" / "implement later"。
- 无 "similar to Task N"（每个任务的代码都完整给出）。
- Task 14 Step 3 的 `CHECKS` 里 #1 与 #7 是**有意留的占位**，
  并在同一步的注意里明确要求补齐——这是**已知的待办**，不是遗漏。
- Task 9 Step 4 给出了拖动测试失败时的备选实现（`TestGesture`），不是占位。

**5. 一致性核对（已机器验证）**

| 项 | 结果 |
| --- | --- |
| 设计文档章节号连续 | ✅ `00`–`05` 全部连续 |
| 仓库路径引用存在 | ✅ 除 `PLANNED_PREFIXES`（本轮将新建）外全部存在 |
| `§N` 交叉引用可解析 | ✅ 除指向主设计文档 `docs/webhtv-pc-design.md` 的 7 处（已单独验证存在） |
| 套件清单三处一致（`design/05` / 计划 / 验收脚本） | ✅ 13 个（11 单测 + 2 集成） |
| 计划里的用例数与 `Expected: PASS（N 个用例）` 一致 | ✅ 12 处全部核对并修正 3 处 |
| `kPlayerButtons` 项数在 `design/03` / `design/05` / 计划中一致 | ✅ 9 项 |
| 任务数与步骤数 | ✅ 15 个任务 / 87 个步骤 |
