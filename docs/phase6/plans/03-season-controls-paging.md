# 季度控件与选集分页实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 季度选择按钮改为常驻（文案随上下文变化，单季也能改绑），两页季度 UI 统一成 chip 条；选集区加上区间分页（每页上限 50，阶梯分组），长剧集不再靠横向滚到底。

**Architecture:** 区间分组逐条移植上游 `EpisodeRangePolicy` 到纯逻辑模块 `lib/core/episode_range.dart`，先用 L1 单测锁死阶梯与倒序语义；UI 只做渲染与滚动定位。季度按钮放在 `TmdbSeasonSelector` 行内（不新增行高），纯 TMDB 页的季度海报卡片条改为复用同一个 selector。

**Tech Stack:** Flutter 3.47 / Dart 3.13、`flutter_test`、Material 3。

**Spec:** `docs/phase6/design/03-season-controls-and-episode-paging.md`（配套 `00` 总索引 §3.4）

## 前置依赖

| 依赖 | 来自 | 为什么 |
| --- | --- | --- |
| `_recentRenderedIndex` | **计划 2 Task 6** | Task 5 的 `_focusIndex` 用它把「历史命中的集」换算成渲染下标 |
| `DetailPage` 的 `historyFlag` / `historyEpisodeId` | **计划 2 Task 3** | Task 5 的区间焦点依赖历史命中集 |

**执行顺序**：计划 2 → 计划 3。计划 1 与计划 2/3 无强依赖（计划 1 的 Task 8
需要计划 2 Task 3 的参数，见计划 1 的说明）。

## Global Constraints

- 字重只用 400 / 700，**禁止 `w500` / `w600`**。
- **禁止改动 Material 3 的字号与行高**：任何净高度变化会把控件挤出 800×600 测试视口，让不带 `ensureVisible` 的 `tester.tap` 打空。区间条**只在区间数 > 1 时渲染**。
- 圆角只用 `AppRadius`；间距只用 `AppSpace`；不引入新散值。
- 不使用阴影、`surfaceTint`；`elevation: 0`。
- 颜色从 `Theme.of(context).colorScheme` 取，不写死十六进制。
- 剧照 16:9、海报 2:3。
- **保留**这些既有 `ValueKey` 字面值：`tmdb-season-context`、`tmdb-season-switcher`、
  `tmdb-season-<n>`、`tmdb-choose-season`、`tmdb-season-dialog`、`tmdb-season-auto`、
  `tmdb-season-auto-slice`、`tmdb-season-keep-original`、`tmdb-season-option-<n>`、
  `tmdb-section-seasons`、`tmdb-episode-header`、`tmdb-episode-reverse`、
  `tmdb-episode-view-mode`、`tmdb-episode-card-<flag>-<index>`。
- **选集卡外壳必须仍是 `OutlinedButton`**（集成门禁按类型 + key 前缀计数）。
- 分页**只切渲染**：播放仍用 `VodPlayLine.episodes` 的原始下标。
- 测试命令（清掉损坏的 git 环境变量，用绝对路径）：

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_episode_range_test.dart
```

---

## File Structure

| 文件 | 职责 | 动作 |
| --- | --- | --- |
| `lib/core/episode_range.dart` | 区间分组 / 切片 / 选中定位（纯逻辑，逐条移植上游 `EpisodeRangePolicy`） | 创建 |
| `lib/ui/tmdb_widgets.dart` | `TmdbSeasonSelector` 加常驻季度按钮 + `padding` / `showManualEntry` 参数 | 修改 |
| `lib/ui/tmdb_detail_view.dart` | 纯 TMDB 页季度区块改用 `TmdbSeasonSelector`；`TmdbEpisodeStrip` 加区间条 | 修改 |
| `lib/ui/browse_pages.dart` | 站点详情页传季度按钮回调；区间条接线 | 修改 |
| `lib/state/tmdb_state.dart` | 新增 `seasonEpoch`（季度切换序号） | 修改 |
| `lib/core/tmdb_widgets`…（见上） | — | — |
| `test/phase6_episode_range_test.dart` | 区间算法的 L1 测试 | 创建 |
| `test/phase6_season_controls_test.dart` | 季度按钮与区间条的 L2 测试 | 创建 |

---

### Task 1: 区间分组算法（纯逻辑）

**Files:**
- Create: `lib/core/episode_range.dart`
- Test: `test/phase6_episode_range_test.dart`

**Interfaces:**
- Consumes: 无（零依赖纯逻辑）
- Produces:
  - `class EpisodeRange`，字段 `label`（`String`）、`start`（`int`，含）、`end`（`int`，不含）、`selected`（`bool`）；方法 `withSelected(bool)`
  - `abstract final class EpisodeRangePolicy`：
    - `static const int cardPageMaxSize = 50`
    - `static int defaultGroupSize(int size)`
    - `static int groupSize(int size, [int maxGroupSize = 0])`
    - `static List<EpisodeRange> build(int size, int selectedIndex, bool reverse, [int maxGroupSize = 0])`
    - `static List<T> slice<T>(List<T> items, EpisodeRange range)`
    - `static int selectedPosition(List<EpisodeRange> ranges)`
    - `static int segmentIndex(int size, int selectedIndex, int segmentSize)`
    - `static int segmentStart(int size, int selectedIndex, int segmentSize)`

- [ ] **Step 1: 写失败的测试**

创建 `test/phase6_episode_range_test.dart`：

```dart
/// 选集区间分组（`docs/phase6/design/03` §4.1）。
///
/// 逐条移植上游 `EpisodeRangePolicy`：阶梯分组与倒序的 `remainder` 逻辑
/// 都是纯算法，且倒序语义**不是**"反转区间顺序"的等价写法，必须锁死。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/episode_range.dart';

void main() {
  group('分组阶梯（defaultGroupSize）', () {
    test('≤60 → 20', () {
      expect(EpisodeRangePolicy.defaultGroupSize(1), 20);
      expect(EpisodeRangePolicy.defaultGroupSize(60), 20);
    });

    test('>60 且 ≤300 → 40', () {
      expect(EpisodeRangePolicy.defaultGroupSize(61), 40);
      expect(EpisodeRangePolicy.defaultGroupSize(300), 40);
    });

    test('>300 且 ≤500 → 50', () {
      expect(EpisodeRangePolicy.defaultGroupSize(301), 50);
      expect(EpisodeRangePolicy.defaultGroupSize(500), 50);
    });

    test('>500 且 ≤1000 → 100', () {
      expect(EpisodeRangePolicy.defaultGroupSize(501), 100);
      expect(EpisodeRangePolicy.defaultGroupSize(1000), 100);
    });

    test('>1000 且 ≤1500 → 150', () {
      expect(EpisodeRangePolicy.defaultGroupSize(1001), 150);
      expect(EpisodeRangePolicy.defaultGroupSize(1500), 150);
    });

    test('>1500 且 ≤2500 → 200', () {
      expect(EpisodeRangePolicy.defaultGroupSize(1501), 200);
      expect(EpisodeRangePolicy.defaultGroupSize(2500), 200);
    });

    test('>2500 → 300', () {
      expect(EpisodeRangePolicy.defaultGroupSize(2501), 300);
      expect(EpisodeRangePolicy.defaultGroupSize(9999), 300);
    });
  });

  group('每页上限（cardPageMaxSize = 50）', () {
    test('groupSize 与上限取 min', () {
      // 400 集：阶梯给 50，上限也是 50 → 50。
      expect(EpisodeRangePolicy.groupSize(400), 50);
      // 1000 集：阶梯给 100，被上限压到 50。
      expect(EpisodeRangePolicy.groupSize(1000), 50);
    });

    test('maxGroupSize 参数进一步压低', () {
      expect(EpisodeRangePolicy.groupSize(400, 10), 10);
    });

    test('maxGroupSize 为 0 表示不额外限制', () {
      expect(EpisodeRangePolicy.groupSize(400, 0), 50);
    });
  });

  group('build：正序', () {
    test('400 集 → 8 个区间，每段 50', () {
      final ranges = EpisodeRangePolicy.build(400, 0, false);
      expect(ranges.length, 8);
      expect(ranges.first.start, 0);
      expect(ranges.first.end, 50);
      expect(ranges.last.start, 350);
      expect(ranges.last.end, 400);
    });

    test('标签是 1-based 的闭区间', () {
      final ranges = EpisodeRangePolicy.build(400, 0, false);
      expect(ranges.first.label, '1-50');
      expect(ranges.last.label, '351-400');
    });

    test('单集区间标签不带连字符', () {
      final ranges = EpisodeRangePolicy.build(1, 0, false);
      expect(ranges.single.label, '1');
    });

    test('选中集决定哪个区间被标记', () {
      final ranges = EpisodeRangePolicy.build(400, 120, false);
      final selected = ranges.where((r) => r.selected).toList();
      expect(selected.length, 1);
      expect(selected.single.start, 100);
      expect(selected.single.end, 150);
    });

    test('size 为 0 → 空列表', () {
      expect(EpisodeRangePolicy.build(0, 0, false), isEmpty);
    });
  });

  group('build：倒序（remainder 落在最前）', () {
    test('不整除时第一个区间是余数段，且边界与正序一致', () {
      // 70 集、每段 20 → 余数 10。
      final ranges = EpisodeRangePolicy.build(70, 0, true);
      expect(ranges.length, 4);
      // 第一个区间在列表里的范围是 [0, 10)。
      expect(ranges.first.start, 0);
      expect(ranges.first.end, 10);
      // 标签按倒序显示：70 集里的最后 10 集是 61-70。
      expect(ranges.first.label, '61-70');
      // 第二个区间是 [10, 30)，标签 41-60。
      expect(ranges[1].start, 10);
      expect(ranges[1].end, 30);
      expect(ranges[1].label, '41-60');
      // 最后一个区间是 [50, 70)，标签 1-20。
      expect(ranges.last.start, 50);
      expect(ranges.last.end, 70);
      expect(ranges.last.label, '1-20');
    });

    test('整除时倒序区间与正序同样多且边界一致', () {
      final ranges = EpisodeRangePolicy.build(80, 0, true);
      expect(ranges.length, 4);
      expect(ranges.first.start, 0);
      expect(ranges.first.end, 20);
      expect(ranges.first.label, '61-80');
      expect(ranges.last.label, '1-20');
    });

    test('倒序时选中区间按列表下标判定', () {
      // 70 集、每段 20：列表下标 0..9 属于第一个区间。
      final ranges = EpisodeRangePolicy.build(70, 3, true);
      expect(ranges.first.selected, isTrue);
      final ranges2 = EpisodeRangePolicy.build(70, 15, true);
      expect(ranges2[1].selected, isTrue);
    });
  });

  group('build：兜底选中', () {
    test('没有任何区间被选中时，第一个被标记', () {
      // selectedIndex 越界（-1）→ 没有区间包含它 → 兜底第一个。
      final ranges = EpisodeRangePolicy.build(40, -1, false);
      expect(ranges.first.selected, isTrue);
      expect(ranges.where((r) => r.selected).length, 1);
    });
  });

  group('slice', () {
    test('按 [start, end) 切片', () {
      final items = List.generate(10, (i) => i);
      final range = EpisodeRange(
        label: '3-5',
        start: 2,
        end: 5,
        selected: true,
      );
      expect(EpisodeRangePolicy.slice(items, range), [2, 3, 4]);
    });

    test('越界时夹到合法范围，不抛异常', () {
      final items = List.generate(3, (i) => i);
      final range = EpisodeRange(
        label: '1-10',
        start: 0,
        end: 10,
        selected: true,
      );
      expect(EpisodeRangePolicy.slice(items, range), [0, 1, 2]);
    });

    test('空列表 → 空结果', () {
      final range = EpisodeRange(
        label: '1-10',
        start: 0,
        end: 10,
        selected: true,
      );
      expect(EpisodeRangePolicy.slice(<int>[], range), isEmpty);
    });
  });

  group('selectedPosition', () {
    test('返回被标记区间的下标', () {
      final ranges = EpisodeRangePolicy.build(400, 120, false);
      expect(EpisodeRangePolicy.selectedPosition(ranges), 2);
    });

    test('空列表 → 0', () {
      expect(EpisodeRangePolicy.selectedPosition(const []), 0);
    });
  });

  group('segmentIndex / segmentStart', () {
    test('按固定段长取段号与段首', () {
      expect(EpisodeRangePolicy.segmentIndex(100, 25, 20), 1);
      expect(EpisodeRangePolicy.segmentStart(100, 25, 20), 20);
      expect(EpisodeRangePolicy.segmentIndex(100, 99, 20), 4);
    });

    test('越界与零段长不抛异常', () {
      expect(EpisodeRangePolicy.segmentIndex(0, 5, 20), 0);
      expect(EpisodeRangePolicy.segmentIndex(10, 99, 20), 0);
      expect(EpisodeRangePolicy.segmentStart(10, -3, 0), 0);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_episode_range_test.dart
```

预期：编译失败，`Target of URI doesn't exist: 'package:webhtv_pc/core/episode_range.dart'`。

- [ ] **Step 3: 写最小实现**

创建 `lib/core/episode_range.dart`：

```dart
/// 选集区间分组（`docs/phase6/design/03` §4.1）。
///
/// 逐条移植上游 `EpisodeRangePolicy`（`app/src/main/java/com/fonggi/android/tv/
/// ui/helper/EpisodeRangePolicy.java`）。纯逻辑：不依赖 Flutter，也不依赖 IO。
///
/// 为什么必须移植而不是"写个差不多的"：两个语义在朴素实现里极易写错——
/// 1. **每页集数是阶梯的**（集数越多每页越大），不是固定值；
/// 2. **倒序时余数段落在最前**，使分组边界与正序一致（对齐列表尾部）。
///    这不是"反转区间顺序"的等价写法。
library;

/// 一个选集区间。
class EpisodeRange {
  const EpisodeRange({
    required this.label,
    required this.start,
    required this.end,
    required this.selected,
  });

  /// 展示标签。由调用方用**真实集号**修正（见 `03` §4.2），
  /// 这里的初值是 1-based 的闭区间文本。
  final String label;

  /// 起始下标（含）。
  final int start;

  /// 结束下标（**不含**）。
  final int end;

  final bool selected;

  EpisodeRange withSelected(bool value) =>
      EpisodeRange(label: label, start: start, end: end, selected: value);

  @override
  String toString() => 'EpisodeRange($label, [$start..$end), selected=$selected)';
}

abstract final class EpisodeRangePolicy {
  /// 每页集数的硬上限（对齐上游 `CARD_PAGE_MAX_SIZE`）。
  static const int cardPageMaxSize = 50;

  /// 按固定段长取段号。越界与非法段长都夹到合法值，不抛异常。
  static int segmentIndex(int size, int selectedIndex, int segmentSize) {
    if (size <= 0) return 0;
    final safeSegmentSize = segmentSize < 1 ? 1 : segmentSize;
    final safeIndex = selectedIndex.clamp(0, size - 1);
    return safeIndex ~/ safeSegmentSize;
  }

  /// 按固定段长取段首下标。
  static int segmentStart(int size, int selectedIndex, int segmentSize) =>
      segmentIndex(size, selectedIndex, segmentSize) *
      (segmentSize < 1 ? 1 : segmentSize);

  /// 分组。`reverse` 为真时余数段落在**最前**。
  static List<EpisodeRange> build(
    int size,
    int selectedIndex,
    bool reverse, [
    int maxGroupSize = 0,
  ]) {
    final ranges = <EpisodeRange>[];
    if (size <= 0) return ranges;
    final group = groupSize(size, maxGroupSize);
    final count = (size / group).ceil();
    final remainder = size % group;
    for (var i = 0; i < count; i++) {
      final int start;
      final int end;
      if (reverse && remainder != 0) {
        // 倒序保持与正序**相同**的集号分组边界，因此余数段落在最前
        // （分组对齐列表尾部）。
        start = i == 0 ? 0 : remainder + (i - 1) * group;
        end = i == 0
            ? remainder
            : (start + group < size ? start + group : size);
      } else {
        start = i * group;
        end = start + group < size ? start + group : size;
      }
      final labelStart = reverse ? size - start : start + 1;
      final labelEnd = reverse ? size - end + 1 : end;
      final single = labelStart == labelEnd;
      final selected = selectedIndex >= start && selectedIndex < end;
      ranges.add(
        EpisodeRange(
          label: single ? '$labelStart' : '$labelStart-$labelEnd',
          start: start,
          end: end,
          selected: selected,
        ),
      );
    }
    // 兜底：没有任何区间被标记时，第一个被标记。
    if (!ranges.any((range) => range.selected)) {
      ranges[0] = ranges[0].withSelected(true);
    }
    return ranges;
  }

  /// 切片。越界夹到合法范围，不抛异常。
  static List<T> slice<T>(List<T> items, EpisodeRange range) {
    if (items.isEmpty) return const [];
    final start = range.start.clamp(0, items.length);
    final end = range.end.clamp(start, items.length);
    return items.sublist(start, end);
  }

  /// 被标记区间的下标；无则 0。
  static int selectedPosition(List<EpisodeRange> ranges) {
    if (ranges.isEmpty) return 0;
    for (var i = 0; i < ranges.length; i++) {
      if (ranges[i].selected) return i;
    }
    return 0;
  }

  /// 生效的每页集数：阶梯值与上限取 min，再受 `maxGroupSize` 进一步压低。
  static int groupSize(int size, [int maxGroupSize = 0]) {
    var group = defaultGroupSize(size);
    if (group > cardPageMaxSize) group = cardPageMaxSize;
    if (maxGroupSize > 0 && maxGroupSize < group) group = maxGroupSize;
    return group < 1 ? 1 : group;
  }

  /// 阶梯分组（对齐上游 `defaultGroupSize`）。
  static int defaultGroupSize(int size) {
    if (size <= 60) return 20;
    if (size > 2500) return 300;
    if (size > 1500) return 200;
    if (size > 1000) return 150;
    if (size > 500) return 100;
    if (size > 300) return 50;
    return 40;
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_episode_range_test.dart
```

预期：`All tests passed!`（26 个用例）。

- [ ] **Step 5: 提交**

```bash
git add lib/core/episode_range.dart test/phase6_episode_range_test.dart
git commit -m "新增：选集区间分组算法（design/03 §4.1）"
```

---

### Task 2: 季度按钮常驻（文案随上下文）

**Files:**
- Modify: `lib/ui/tmdb_widgets.dart`（`TmdbSeasonSelector`）
- Test: `test/phase6_season_controls_test.dart`（新建）

**Interfaces:**
- Consumes: `TmdbState.selectedSeason` / `availableSeasons` / `hasMatch` / `item` / `seasonEpisodeCounts`（既有）
- Produces:
  - `TmdbSeasonSelector({..., EdgeInsets padding, bool showManualEntry})`
  - 新增 `ValueKey('tmdb-season-button')`
  - `String tmdbSeasonButtonLabel(TmdbState state)`（顶层函数，便于单测）

- [ ] **Step 1: 写失败的测试**

创建 `test/phase6_season_controls_test.dart`：

```dart
/// 季度按钮常驻与选集区间条（`docs/phase6/design/03` §2、§4.3）。
///
/// `TmdbState` 的构造方式与 `test/phase4_tmdb_ui_test.dart` 完全一致：
/// **直接构造**（`TmdbState(config:, service:, identityService:,
/// seasonService:, enrichmentService:)`），不走 `AppState`——
/// `TmdbState` 是独立可测的组件，`AppState` 里的那个实例需要 bootstrap
/// 才能装配，测起来更慢也更脆。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

> `InMemoryTmdbMatchStore` 在 `tmdb_identity_service.dart`，
> `InMemoryTmdbSeasonStore` 与 `TmdbSourceLine` 在 `tmdb_season_service.dart`
> ——**都不在 `tmdb_stores.dart`**（该文件是数据库版 store 的实现）。

/// 假 HTTP 客户端：按路径后缀返回预置 JSON（与 `phase4_tmdb_ui_test` 同构）。
class _FakeClient extends http.BaseClient {
  _FakeClient(this._routes);

  /// 路径后缀 → 响应体。
  final Map<String, Object?> _routes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    for (final entry in _routes.entries) {
      if (request.url.path.endsWith(entry.key)) {
        final body = entry.value;
        final text = body is String ? body : jsonEncode(body);
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(text)),
          200,
        );
      }
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"status_code":404}')),
      404,
    );
  }
}

TmdbConfig _ready() => const TmdbConfig(apiKey: 'k');

TmdbState _tmdbState({
  required TmdbConfig Function() config,
  required http.Client client,
}) {
  final service = TmdbService(config: config, client: client);
  return TmdbState(
    config: config,
    service: service,
    identityService: TmdbIdentityService(
      config: config,
      service: service,
      store: InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
    enrichmentService: TmdbEnrichmentService(service: service, config: config),
  );
}

Vod _vod() => const Vod(vodId: 'v1', vodName: '剧名');

/// `TmdbState.beginLoad` 收的是 `TmdbSourceLine`（不是 `VodPlayLine`）。
TmdbSourceLine _line({required int count}) => TmdbSourceLine(
  flagKey: 'f#0',
  sourceFlag: '线路一',
  episodeNames: List.generate(count, (i) => '第${i + 1}集'),
);

void main() {
  /// 走完整的匹配 + 详情流程，得到可渲染的 `TmdbState`。
  Future<TmdbState> matchedState({
    required int episodeCount,
    required List<int> tmdbSeasons,
    required Map<int, int> seasonCounts,
  }) async {
    final client = _FakeClient({
      '/search/multi': {
        'results': [
          {
            'id': 1399,
            'media_type': 'tv',
            'name': '剧名',
            'first_air_date': '2024-01-01',
          },
        ],
      },
      '/tv/1399': {
        'id': 1399,
        'name': '剧名',
        'seasons': [
          for (final season in tmdbSeasons)
            {
              'season_number': season,
              'episode_count': seasonCounts[season] ?? 0,
            },
        ],
      },
    });
    final state = _tmdbState(config: _ready, client: client);
    final generation = state.beginLoad(
      siteKey: 's',
      vodId: 'v1',
      sourceTitle: '剧名',
      vod: _vod(),
      line: _line(count: episodeCount),
    );
    await state.loadMatch(generation: generation, sourceTitle: '剧名');
    await state.loadDetail(
      generation: generation,
      tmdbSeasons: tmdbSeasons,
      seasonCounts: seasonCounts,
    );
    return state;
  }

  Future<void> pumpSelector(WidgetTester tester, TmdbState tmdb) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TmdbSeasonSelector(state: tmdb))),
    );
    await tester.pump();
  }

  group('季度按钮常驻（design/03 §2）', () {
    testWidgets('多季：按钮 + chip 条并存', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-switcher')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-2')), findsOneWidget);
      tmdb.dispose();
    });

    testWidgets('单季：按钮仍常驻（这是改绑的唯一入口）', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-context')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-switcher')), findsNothing);
      tmdb.dispose();
    });

    testWidgets('未确定季度：按钮文案是「选择季度」', (tester) async {
      // 7 集，而 S1=3、S2=2：既不能切片（3+2≠7），单季兼容也不成立
      // （S1 的 3 集 < 7），因此 availableSeasons 为空。
      final tmdb = await matchedState(
        episodeCount: 7,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await pumpSelector(tester, tmdb);

      expect(find.byKey(const ValueKey('tmdb-season-button')), findsOneWidget);
      expect(find.text('选择季度'), findsWidgets);
      tmdb.dispose();
    });

    testWidgets('点季度按钮触发 onSelectManual', (tester) async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      var opened = 0;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbSeasonSelector(
              state: tmdb,
              onSelectManual: () => opened++,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('tmdb-season-button')));
      await tester.pump();
      expect(opened, 1);
      tmdb.dispose();
    });
  });

  group('tmdbSeasonButtonLabel（纯函数）', () {
    test('有选中季 → 第 N 季', () async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [1],
        seasonCounts: const {1: 3},
      );
      expect(tmdbSeasonButtonLabel(tmdb), '第 1 季');
      tmdb.dispose();
    });

    test('特别篇 → 特别篇', () async {
      final tmdb = await matchedState(
        episodeCount: 3,
        tmdbSeasons: const [0],
        seasonCounts: const {0: 3},
      );
      expect(tmdbSeasonButtonLabel(tmdb), '特别篇');
      tmdb.dispose();
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_season_controls_test.dart
```

预期：编译失败，`Method not found: 'tmdbSeasonButtonLabel'` /
`The named parameter 'onSelectManual' isn't defined`（若已有则只报前者）。

- [ ] **Step 3: 写最小实现**

在 `lib/ui/tmdb_widgets.dart` 中：

(a) 在 `TmdbSeasonSelector` **之前**加顶层纯函数：

```dart
/// 季度按钮的文案（`docs/phase6/design/03` §2.2）。
///
/// 对齐上游 `TmdbDetailActivity#detailSeasonButtonLabel`：
/// 先看当前季度上下文，再看解析出的季度，都没有才用「选择季度」。
String tmdbSeasonButtonLabel(TmdbState state) {
  final season = state.selectedSeason;
  if (season >= 0) return _seasonLabel(season);
  return '选择季度';
}

String _seasonLabel(int season) => season == 0 ? '特别篇' : '第 $season 季';
```

> `TmdbSeasonSelector` 原本有一个私有静态 `_seasonLabel`，改为**顶层**
> `_seasonLabel` 以便两处共用（原静态方法删除，其调用点改为顶层函数）。

(b) `TmdbSeasonSelector` 加参数：

```dart
  const TmdbSeasonSelector({
    super.key,
    required this.state,
    this.onChanged,
    this.onSelectManual,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.showManualEntry = true,
  });

  /// 内容内边距（纯 TMDB 页传 `EdgeInsets.zero` 以贴合其内容列）。
  final EdgeInsets padding;

  /// 是否渲染手动改绑入口。默认 `true`；调用方已有独立入口时可关掉。
  final bool showManualEntry;
```

(c) 在 `build` 里，三个分支（未确定 / 单季 / 多季）都改为**先渲染季度按钮**。
把 `seasons.isEmpty` 分支替换为：

```dart
    if (seasons.isEmpty) {
      return SizedBox(
        height: tmdbSeasonSelectorHeight,
        child: Padding(
          padding: padding,
          child: Row(
            children: [
              _seasonButton(context),
              const SizedBox(width: 8),
              Text('未确定季度', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('tmdb-choose-season'),
                onPressed: onSelectManual,
                child: const Text('选择季度'),
              ),
            ],
          ),
        ),
      );
    }
```

单季分支替换为：

```dart
    if (seasons.length == 1) {
      return SizedBox(
        height: tmdbSeasonSelectorHeight,
        child: Padding(
          padding: padding,
          child: Row(
            children: [
              _seasonButton(context),
              const SizedBox(width: 12),
              Text(
                _seasonLabel(seasons.first),
                key: const ValueKey('tmdb-season-context'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }
```

多季分支替换为（按钮在左、chip 条在右）：

```dart
    return SizedBox(
      height: tmdbSeasonSelectorHeight,
      child: Row(
        children: [
          Padding(
            padding: EdgeInsets.only(left: padding.left),
            child: _seasonButton(context),
          ),
          Expanded(
            child: ListView.separated(
              key: const ValueKey('tmdb-season-switcher'),
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: padding.horizontal / 2,
                vertical: 6,
              ),
              itemCount: seasons.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final season = seasons[index];
                return ChoiceChip(
                  key: ValueKey('tmdb-season-$season'),
                  label: Text(_seasonLabel(season)),
                  selected: season == state.selectedSeason,
                  onSelected: (_) => onChanged?.call(season),
                );
              },
            ),
          ),
        ],
      ),
    );
```

(d) 加季度按钮构造方法（`TmdbSeasonSelector` 类内）：

```dart
  /// 常驻的季度按钮（`docs/phase6/design/03` §2）。
  ///
  /// 为什么必须常驻：单季剧集原先只显示一行上下文文字，**没有任何改绑入口**
  /// ——用户发现 TMDB 匹配错了季度也没法手动纠正。
  Widget _seasonButton(BuildContext context) => TextButton.icon(
    key: const ValueKey('tmdb-season-button'),
    onPressed: showManualEntry ? onSelectManual : null,
    iconAlignment: IconAlignment.end,
    icon: const Icon(Icons.expand_more, size: 18),
    label: Text(tmdbSeasonButtonLabel(state)),
  );
```

> **宽度风险**：该按钮放在季度选择器行内，**不新增行高**。
> `tmdbSeasonSelectorHeight` 是既有常量，测试按它断言，不得改动。

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_season_controls_test.dart
```

预期：`All tests passed!`（6 个用例）。

确认没打破季度选择器既有门禁：

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase4_tmdb_ui_test.dart
```

预期：全绿。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/tmdb_widgets.dart test/phase6_season_controls_test.dart
git commit -m "新增：季度按钮常驻 + 文案随上下文（design/03 §2）"
```

---

### Task 3: 季度 UI 统一为 chip 条

**Files:**
- Modify: `lib/ui/tmdb_detail_view.dart`（`TmdbDetailView` 的季度区块）
- Modify: `test/phase4_tmdb_detail_view_test.dart`（**有意变更**）
- Test: `test/phase6_season_controls_test.dart`（追加）

**Interfaces:**
- Consumes: `TmdbSeasonSelector`（Task 2）
- Produces:
  - `class SeasonChipStrip extends StatelessWidget`（定义在 `lib/ui/tmdb_widgets.dart`），
    构造参数 `seasons` / `selectedSeason` / `selectableSeasons` / `onChanged` /
    `padding` / `switcherKey`
  - `TmdbDetailView` 保留 `ValueKey('tmdb-section-seasons')`；
    删除 `tmdb-season-strip` 与 `tmdb-season-card-*`；
    季度区块改用 `SeasonChipStrip`（key 前缀 `tmdb-detail-season-switcher`）

> **这是有意的测试变更**（用户要求统一季度 UI）。提交信息必须写明理由。

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_season_controls_test.dart` 追加（import 区加
`import 'package:webhtv_pc/core/tmdb_detail_model.dart';`、
`import 'package:webhtv_pc/ui/tmdb_detail_view.dart';`）：

```dart
  group('季度 UI 统一（design/03 §3）', () {
    testWidgets('TmdbDetailView 的季度区块是 chip 条，不是海报卡片条', (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbDetailView(
              data: const TmdbDetailData(
                title: '剧名',
                overview: '',
                posterUrl: null,
                backdropUrls: [],
                rating: 0,
              ),
              seasons: const [
                TmdbSeasonInfo(number: 1, episodeCount: 3, name: '第 1 季'),
                TmdbSeasonInfo(number: 2, episodeCount: 2, name: '第 2 季'),
              ],
              selectedSeason: 1,
              selectableSeasons: const [1, 2],
              onSeasonChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tmdb-section-seasons')),
        findsOneWidget,
        reason: '区块 key 必须保留',
      );
      expect(
        find.byKey(const ValueKey('tmdb-season-strip')),
        findsNothing,
        reason: '海报卡片条已改为 chip 条',
      );
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_season_controls_test.dart
```

预期：FAIL，`Expected: no matching candidates` / `Actual: Found 1 widget with key [<'tmdb-season-strip'>]`。

- [ ] **Step 3: 写最小实现**

**设计决定（先读这条，它决定了后面所有代码的位置）**：
`TmdbDetailView` 是**纯展示组件**（只收 `seasons` / `selectedSeason` 等参数，
被纯 TMDB 页使用），而 `TmdbSeasonSelector` 需要 `TmdbState`。
因此**不把 `TmdbState` 耦合进展示组件**，而是抽出两页共用的
`SeasonChipStrip`（纯展示、零状态依赖）：

- `SeasonChipStrip` 定义在 **`lib/ui/tmdb_widgets.dart`**
  （不能放 `tmdb_detail_view.dart`：`TmdbSeasonSelector` 要用它，
  反过来会造成循环 import）；
- `TmdbSeasonSelector` 内部用它渲染 chip 条；
- `TmdbDetailView` 直接用它渲染季度区块。

(a) 在 `lib/ui/tmdb_widgets.dart` 顶层加组件：

```dart
/// 季度 chip 条（`docs/phase6/design/03` §3）。
///
/// 站点详情页与纯 TMDB 详情页**共用**这一个实现：同一个概念只有一种视觉。
/// 它是纯展示组件（不依赖 `TmdbState`），因此两页都能用。
class SeasonChipStrip extends StatelessWidget {
  const SeasonChipStrip({
    super.key,
    required this.seasons,
    required this.selectedSeason,
    this.selectableSeasons = const [],
    this.onChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.switcherKey = 'tmdb-season-switcher',
  });

  /// 全部季度号（升序）。
  final List<int> seasons;

  final int selectedSeason;

  /// 可切换的季度；为空表示全部可切换。
  final List<int> selectableSeasons;

  final ValueChanged<int>? onChanged;
  final EdgeInsets padding;

  /// chip 条容器的 key。站点页与纯 TMDB 页各用各的字面值，避免同树冲突。
  final String switcherKey;

  @override
  Widget build(BuildContext context) {
    if (seasons.length <= 1) return const SizedBox.shrink();
    return SizedBox(
      height: tmdbSeasonSelectorHeight,
      child: ListView.separated(
        key: ValueKey(switcherKey),
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: padding.horizontal / 2,
          vertical: 6,
        ),
        itemCount: seasons.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final season = seasons[index];
          final selectable =
              selectableSeasons.isEmpty || selectableSeasons.contains(season);
          return ChoiceChip(
            key: ValueKey('$switcherKey-$season'),
            label: Text(season == 0 ? '特别篇' : '第 $season 季'),
            selected: season == selectedSeason,
            onSelected: selectable && onChanged != null
                ? (_) => onChanged!(season)
                : null,
          );
        },
      ),
    );
  }
}
```

> 站点页的 chip 条 key 沿用 `tmdb-season-switcher`（`phase4_tmdb_ui_test`
> 按它断言），各季 chip 的 key 因此是 `tmdb-season-1` / `tmdb-season-2`
> ——**与既有测试一致，不用改**。

(b) `lib/ui/tmdb_detail_view.dart` 的 `TmdbDetailView` 里，把季度区块
（`_seasonSectionVisible` 那个 `if` 块，含 `SectionHeader` + `SizedBox(height: 214)`
+ `ListView.separated(key: tmdb-season-strip)`）整块替换为：

```dart
              if (_seasonSectionVisible) ...[
                const SizedBox(height: 16),
                SectionHeader(
                  title: '季度',
                  keyValue: 'tmdb-section-seasons',
                  trailing: selectedSeason < 0 && onSelectSeason != null
                      ? TextButton(
                          key: const ValueKey('tmdb-choose-season'),
                          onPressed: onSelectSeason,
                          child: const Text('选择季度'),
                        )
                      : null,
                ),
                // 季度 UI 统一为 chip 条（`docs/phase6/design/03` §3）：
                // 原先这里的海报卡片条与站点页的 chip 条是两套实现，
                // 同一概念两种视觉。现在两页共用 `SeasonChipStrip`。
                SeasonChipStrip(
                  seasons: [for (final season in seasons) season.number],
                  selectedSeason: selectedSeason,
                  selectableSeasons: selectableSeasons,
                  onChanged: onSeasonChanged,
                  padding: EdgeInsets.zero,
                  switcherKey: 'tmdb-detail-season-switcher',
                ),
              ],
```

(c) `TmdbSeasonSelector` 的多季分支改为复用 `SeasonChipStrip`
（把 Task 2 里的内联 `ListView.separated` 换掉）：

```dart
    return SizedBox(
      height: tmdbSeasonSelectorHeight,
      child: Row(
        children: [
          Padding(
            padding: EdgeInsets.only(left: padding.left),
            child: _seasonButton(context),
          ),
          Expanded(
            child: SeasonChipStrip(
              seasons: seasons,
              selectedSeason: state.selectedSeason,
              onChanged: onChanged,
              padding: padding,
              // 站点页沿用既有 key 字面值：phase4_tmdb_ui_test 按
              // tmdb-season-switcher / tmdb-season-<n> 断言，不得改名。
              switcherKey: 'tmdb-season-switcher',
            ),
          ),
        ],
      ),
    );
```

(d) 删除 `_SeasonCard` 类与 `seasonKeyPrefix` 参数（若改动后无调用点）。
`tmdbSeasonSelectorHeight` 常量保留。

(e) `lib/ui/tmdb_detail_view.dart` 顶部 import 追加：

```dart
import '../core/episode_range.dart';   // Task 4 用
```

> `SeasonChipStrip` 在 `tmdb_widgets.dart`，而 `tmdb_detail_view.dart`
> 已经 import 了它，无需新增 import。

- [ ] **Step 4: 跑测试确认通过 + 更新既有测试**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_season_controls_test.dart
```

预期：`All tests passed!`（7 个用例）。

再跑既有测试，**预期它失败**——这是有意的：

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase4_tmdb_detail_view_test.dart
```

把 `test/phase4_tmdb_detail_view_test.dart` 里所有
`ValueKey('tmdb-season-strip')` 改为 `ValueKey('tmdb-detail-season-switcher')`，
所有 `ValueKey('tmdb-season-card-<n>')` 改为
`ValueKey('tmdb-detail-season-switcher-<n>')`，然后在文件头注释里加一行说明：

```dart
/// 季度 UI 于 2026-10-14 统一为 chip 条（`docs/phase6/design/03` §3）：
/// 原 `tmdb-season-strip` / `tmdb-season-card-*` 已改为
/// `tmdb-detail-season-switcher` / `tmdb-detail-season-switcher-*`。
```

再跑：

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase4_tmdb_detail_view_test.dart
```

预期：`All tests passed!`。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/tmdb_widgets.dart lib/ui/tmdb_detail_view.dart test/phase4_tmdb_detail_view_test.dart test/phase6_season_controls_test.dart
git commit -m "重构：季度 UI 统一为 chip 条（design/03 §3，用户要求统一）" -m "有意变更既有测试 phase4_tmdb_detail_view_test：
原 tmdb-season-strip / tmdb-season-card-* 断言改为
tmdb-detail-season-switcher / tmdb-detail-season-switcher-*。
理由：站点页与纯 TMDB 页原先各有一套季度视觉，同一概念两种形态。"
```

---

### Task 4: 选集区间条

**Files:**
- Modify: `lib/ui/tmdb_detail_view.dart`（`TmdbEpisodeStrip`）
- Modify: `lib/ui/browse_pages.dart`（接线）
- Test: `test/phase6_season_controls_test.dart`（追加）

**Interfaces:**
- Consumes: `EpisodeRangePolicy` / `EpisodeRange`（Task 1）
- Produces:
  - `TmdbEpisodeStrip({..., List<EpisodeRange> ranges = const [], int rangeIndex = 0, ValueChanged<int>? onRangeChanged})`
  - 新增 `ValueKey('<keyPrefix>-range-strip')`、`ValueKey('<keyPrefix>-range-<i>')`

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_season_controls_test.dart` 追加（import 区加
`import 'package:webhtv_pc/core/episode_range.dart';`）：

```dart
  group('选集区间条（design/03 §4.3）', () {
    List<TmdbEpisodeCard> cardsOf(int count) => [
      for (var i = 1; i <= count; i++)
        TmdbEpisodeCard(number: i, title: '第$i集'),
    ];

    Future<void> pumpStrip(
      WidgetTester tester, {
      required int count,
      required List<EpisodeRange> ranges,
      int rangeIndex = 0,
      ValueChanged<int>? onRangeChanged,
    }) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbEpisodeStrip(
              keyPrefix: 'tmdb-episode-card-线路一',
              cards: cardsOf(count),
              ranges: ranges,
              rangeIndex: rangeIndex,
              onRangeChanged: onRangeChanged,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('区间数 > 1 时渲染区间条', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      await pumpStrip(tester, count: 70, ranges: ranges);

      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-range-strip')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-range-0')),
        findsOneWidget,
      );
      expect(find.text('1-20'), findsWidgets);
    });

    testWidgets('区间数为 1 时不渲染区间条', (tester) async {
      final ranges = EpisodeRangePolicy.build(10, 0, false);
      await pumpStrip(tester, count: 10, ranges: ranges);

      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-range-strip')),
        findsNothing,
      );
    });

    testWidgets('只渲染当前区间的卡片', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      await pumpStrip(tester, count: 70, ranges: ranges, rangeIndex: 0);

      // 区间 0 = [0, 20) → 20 张卡。
      final buttons = find.byWidgetPredicate(
        (widget) =>
            widget is OutlinedButton &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'tmdb-episode-card-线路一-',
            ) &&
            !(widget.key! as ValueKey<String>).value.contains('range'),
      );
      expect(buttons, findsNWidgets(20));
    });

    testWidgets('点区间 chip 回调下标', (tester) async {
      final ranges = EpisodeRangePolicy.build(70, 0, false);
      int? tapped;
      await pumpStrip(
        tester,
        count: 70,
        ranges: ranges,
        onRangeChanged: (index) => tapped = index,
      );

      await tester.tap(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-range-2')),
      );
      await tester.pump();
      expect(tapped, 2);
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_season_controls_test.dart
```

预期：编译失败，`No named parameter with the name 'ranges'`。

- [ ] **Step 3: 写最小实现**

(a) `lib/ui/tmdb_detail_view.dart` 的 `TmdbEpisodeStrip` 加参数：

```dart
    this.gridMode = false,
    this.recentIndex = -1,
    this.ranges = const [],
    this.rangeIndex = 0,
    this.onRangeChanged,
  });

  /// 区间分组（`docs/phase6/design/03` §4.3）。空或只有 1 个区间时不渲染区间条。
  final List<EpisodeRange> ranges;

  /// 当前区间下标。
  final int rangeIndex;

  final ValueChanged<int>? onRangeChanged;
```

(b) 在 `build` 开头（`if (cards.isEmpty)` 之后）加区间条，并把 `cards` 换成
`_visibleCards`：

```dart
  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) return const SizedBox.shrink();
    // 分页只切**渲染**：播放仍用线路原始下标，调用方负责换算
    // （`docs/phase6/design/03` §4.5）。
    final visible = ranges.length > 1
        ? EpisodeRangePolicy.slice(cards, ranges[rangeIndex])
        : cards;
    final strip = _buildStrip(context, visible);
    if (ranges.length <= 1) return strip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_buildRangeBar(context), const SizedBox(height: 8), strip],
    );
  }

  /// 区间 chip 条。**只在区间数 > 1 时渲染**（否则会白占一行高度，
  /// 把控件挤出 800×600 测试视口）。
  Widget _buildRangeBar(BuildContext context) => SizedBox(
    height: 36,
    child: ListView.separated(
      key: ValueKey('$keyPrefix-range-strip'),
      scrollDirection: Axis.horizontal,
      itemCount: ranges.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) => ChoiceChip(
        key: ValueKey('$keyPrefix-range-$index'),
        label: Text(ranges[index].label),
        selected: index == rangeIndex,
        onSelected:
            onRangeChanged == null ? null : (_) => onRangeChanged!(index),
      ),
    ),
  );
```

(c) 把原 `build` 的网格/横向条两个分支抽成 `_buildStrip`，并把
`itemCount: cards.length` 换成 `itemCount: visible.length`，
所有 `cards[index]` 换成 `visible[index]`。

(d) 自动滚入视野（对齐上游 `renderEpisodeRanges` 的 `smoothScrollTo`）。

**做法**：把 `TmdbEpisodeStrip` 从 `StatelessWidget` 改为 `StatefulWidget`，
用 `ScrollController` + `addPostFrameCallback` 按 `rangeIndex` 计算偏移滚动。

**为什么不用 `GlobalKey` + `Scrollable.ensureVisible`**：那要求把 `GlobalKey`
挂在**选中的那个** chip 上，而测试按 `ValueKey('<keyPrefix>-range-<i>')`
定位区间 chip——一个 widget 只能有一个 key，两者不能同时满足。
用 `ScrollController` 算偏移则所有 chip 都能保留各自的 `ValueKey`。

```dart
class TmdbEpisodeStrip extends StatefulWidget {
  // 参数与本节 (a) 里列出的完全一致（cards / keyPrefix / actionLabel / onTap /
  // cardWidth / height / gridMode / recentIndex / ranges / rangeIndex /
  // onRangeChanged），只是把 `const TmdbEpisodeStrip({...})` 原样搬过来。
  @override
  State<TmdbEpisodeStrip> createState() => _TmdbEpisodeStripState();
}

class _TmdbEpisodeStripState extends State<TmdbEpisodeStrip> {
  final ScrollController _rangeScroll = ScrollController();

  /// 单个区间 chip 的估算宽度（含间距）。用于把选中区间滚入视野。
  static const double _rangeChipExtent = 72;

  @override
  void initState() {
    super.initState();
    _scrollToRange();
  }

  @override
  void didUpdateWidget(covariant TmdbEpisodeStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rangeIndex != widget.rangeIndex) _scrollToRange();
  }

  @override
  void dispose() {
    _rangeScroll.dispose();
    super.dispose();
  }

  /// 把选中区间滚入视野。
  ///
  /// 在 post-frame 回调里做：`maxScrollExtent` 要等本帧布局完成才可用。
  void _scrollToRange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_rangeScroll.hasClients) return;
      final target = (widget.rangeIndex * _rangeChipExtent - 12)
          .clamp(0.0, _rangeScroll.position.maxScrollExtent);
      _rangeScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }
```

区间条的 `ListView.separated` 挂 `controller: _rangeScroll`，
所有 chip 用 `ValueKey('$keyPrefix-range-$index')`。
`build` 与 `_buildRangeBar` 搬进 State，用 `widget.xxx` 访问参数。

（以下为搬到 State 后的 `_buildRangeBar` 与 `build` 定稿：）

```dart
  /// 区间 chip 条。**只在区间数 > 1 时渲染**（否则白占一行高度，
  /// 把控件挤出 800×600 测试视口）。
  Widget _buildRangeBar(BuildContext context) => SizedBox(
    height: 36,
    child: ListView.separated(
      key: ValueKey('${widget.keyPrefix}-range-strip'),
      controller: _rangeScroll,
      scrollDirection: Axis.horizontal,
      itemCount: widget.ranges.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, index) => ChoiceChip(
        key: ValueKey('${widget.keyPrefix}-range-$index'),
        label: Text(widget.ranges[index].label),
        selected: index == widget.rangeIndex,
        onSelected: widget.onRangeChanged == null
            ? null
            : (_) => widget.onRangeChanged!(index),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.cards.isEmpty) return const SizedBox.shrink();
    // 分页只切**渲染**：播放仍用线路原始下标，调用方负责换算
    // （`docs/phase6/design/03` §4.5）。
    final visible = widget.ranges.length > 1
        ? EpisodeRangePolicy.slice(widget.cards, widget.ranges[widget.rangeIndex])
        : widget.cards;
    final strip = _buildStrip(context, visible);
    if (widget.ranges.length <= 1) return strip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_buildRangeBar(context), const SizedBox(height: 8), strip],
    );
  }

  /// 网格模式或横向滚动条（原 `build` 的两个分支搬到这里）。
  Widget _buildStrip(BuildContext context, List<TmdbEpisodeCard> visible) {
    if (widget.gridMode) {
      return GridView.builder(
        key: ValueKey('${widget.keyPrefix}-grid'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: widget.cardWidth + 12,
          mainAxisExtent: widget.height,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: visible.length,
        itemBuilder: (context, index) => TmdbEpisodeCardTile(
          buttonKey: ValueKey('${widget.keyPrefix}-$index'),
          stillKey: ValueKey('${widget.keyPrefix}-still-${visible[index].number}'),
          card: visible[index],
          actionLabel: widget.actionLabel,
          isRecent: index == widget.recentIndex,
          onTap: widget.onTap == null
              ? null
              : () => widget.onTap!.call(index, visible[index]),
        ),
      );
    }
    return SizedBox(
      height: widget.height,
      child: ListView.separated(
        key: ValueKey('${widget.keyPrefix}-strip'),
        scrollDirection: Axis.horizontal,
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) => SizedBox(
          width: widget.cardWidth,
          child: TmdbEpisodeCardTile(
            buttonKey: ValueKey('${widget.keyPrefix}-$index'),
            stillKey: ValueKey(
              '${widget.keyPrefix}-still-${visible[index].number}',
            ),
            card: visible[index],
            actionLabel: widget.actionLabel,
            isRecent: index == widget.recentIndex,
            onTap: widget.onTap == null
                ? null
                : () => widget.onTap!.call(index, visible[index]),
          ),
        ),
      ),
    );
  }
```

`lib/ui/tmdb_detail_view.dart` 顶部需要 import：

```dart
import '../core/episode_range.dart';
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_season_controls_test.dart
```

预期：`All tests passed!`（11 个用例）。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/tmdb_detail_view.dart test/phase6_season_controls_test.dart
git commit -m "新增：选集区间条与自动滚入视野（design/03 §4.3、§4.4）"
```

---

### Task 5: 站点页接线 + 切季行为 + 过滤为空回退

**Files:**
- Modify: `lib/state/tmdb_state.dart`（新增 `seasonEpoch`）
- Modify: `lib/ui/browse_pages.dart`（区间状态 + 切季重置 + 传入区间）
- Modify: `lib/ui/tmdb_widgets.dart`（`TmdbEpisodeRenderPolicy.filter` 空结果回退）
- Test: `test/phase6_episode_range_test.dart`（追加过滤回退的 L1）
- Test: `test/phase6_season_controls_test.dart`（追加切季的 L2）

**Interfaces:**
- Consumes: `EpisodeRangePolicy`（Task 1）、`TmdbEpisodeStrip.ranges`（Task 4）
- Produces:
  - `TmdbState.seasonEpoch`（`int` getter，每次 `selectSeason` 自增）
  - `TmdbEpisodeRenderPolicy.filter` 的空结果回退行为

- [ ] **Step 1: 写失败的测试**

(a) 在 `test/phase6_episode_range_test.dart` 追加（import 区加
`import 'package:webhtv_pc/core/protocol.dart';`、
`import 'package:webhtv_pc/ui/tmdb_widgets.dart';`）：

```dart
  group('季度过滤为空时回退全部集（design/03 §5.2）', () {
    VodEpisode episodeOf(String name) =>
        VodEpisode(name: name, url: 'http://x/$name');

    test('过滤结果非空时按季度过滤', () {
      final episodes = [
        episodeOf('第1季第1集'),
        episodeOf('第2季第1集'),
      ];
      final result = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [1, 2],
        selectedSeason: 1,
        seasonOf: (episode) => episode.name.startsWith('第2季') ? 2 : 1,
      );
      expect(result.length, 1);
      expect(result.single.name, '第1季第1集');
    });

    test('过滤结果为空时回退全部集，不显示空白', () {
      final episodes = [
        episodeOf('第1季第1集'),
        episodeOf('第1季第2集'),
      ];
      final result = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [1, 2],
        selectedSeason: 2,
        // 全部集都判为 S1 → 选 S2 时过滤结果为空。
        seasonOf: (_) => 1,
      );
      expect(
        result.length,
        2,
        reason: '宁可显示"可能不对季"的集，也不能显示空白（不丢集纪律）',
      );
    });

    test('availableSeasons 为空时返回全部', () {
      final episodes = [episodeOf('第1集')];
      final result = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [],
        selectedSeason: 1,
        seasonOf: (_) => -1,
      );
      expect(result.length, 1);
    });
  });
```

(b) 在 `test/phase6_season_controls_test.dart` 追加：

```dart
  group('切季行为（design/03 §5.1）', () {
    test('selectSeason 自增 seasonEpoch', () async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      final before = tmdb.seasonEpoch;
      tmdb.selectSeason(2);
      expect(tmdb.seasonEpoch, greaterThan(before));
    });

    test('重复选同一季不自增', () async {
      final tmdb = await matchedState(
        episodeCount: 5,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      final before = tmdb.seasonEpoch;
      tmdb.selectSeason(tmdb.selectedSeason);
      expect(tmdb.seasonEpoch, before);
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_episode_range_test.dart test/phase6_season_controls_test.dart
```

预期：FAIL，`过滤结果为空时回退全部集` 与 `selectSeason 自增 seasonEpoch` 失败。

- [ ] **Step 3: 写最小实现**

(a) `lib/ui/tmdb_widgets.dart` 的 `TmdbEpisodeRenderPolicy.filter` 末尾，
把 `return result;` 改为：

```dart
    // 过滤结果为空 → 回退全部集（`docs/phase6/design/03` §5.2）。
    //
    // 宁可显示"可能不对季"的集，也不能显示空白——用户会以为剧集丢了。
    // 这与 `DESIGN.md` 的「不丢集」纪律一致，也对齐上游
    // `computeVisibleEpisodes` 的 `visible.isEmpty() ? episodes : visible`。
    return result.isEmpty ? episodes : result;
```

(b) `lib/state/tmdb_state.dart` 加 `seasonEpoch`：

```dart
  /// 季度切换序号（`docs/phase6/design/03` §5.1）。
  ///
  /// 每次**真正**切换季度时自增。UI 侧据此重置选集区间下标：切季后
  /// 应回到该季第一集所在区间，而不是停在上一季的页码上。
  ///
  /// 为什么用序号而不是回调：详情页的 `build` 会被 `AppState` 与
  /// `TmdbState` 的多次通知触发，用回调链容易在时序上漏掉或多触发。
  int get seasonEpoch => _seasonEpoch;
  int _seasonEpoch = 0;
```

并在 `selectSeason` 里自增（在 `_selectedSeason = seasonNumber;` 之后）：

```dart
    _seasonEpoch++;
```

(c) `lib/ui/browse_pages.dart` 的 `_DetailPageState` 加区间状态：

```dart
  /// 当前选集区间下标（`docs/phase6/design/03` §4.4）。
  int _rangeIndex = 0;

  /// 用户是否**手动**点过区间 chip。
  ///
  /// 手动选过之后，切集不再重置区间（对齐上游 `manualEpisodeRange`）：
  /// 用户的显式意图优先于自动跟随。
  bool _manualRange = false;

  /// 上一次渲染时的季度序号，用于检测切季。
  int _lastSeasonEpoch = -1;
```

(d) 在 `build` 里检测切季并重置区间（放在 `_resumeTarget` 应用之后）：

```dart
    // 切季 → 区间回到该季第一集所在区间（`docs/phase6/design/03` §5.1）。
    if (_lastSeasonEpoch != state.tmdb.seasonEpoch) {
      _lastSeasonEpoch = state.tmdb.seasonEpoch;
      _rangeIndex = 0;
      _manualRange = false;
    }
```

(e) `_buildEpisodes` 里计算区间并传给 `TmdbEpisodeStrip`：

```dart
    // 区间分组（`docs/phase6/design/03` §4.1、§4.2）。
    final ranges = EpisodeRangePolicy.build(
      ordered.length,
      // 未手动选过时，区间跟随"当前关注的那一集"：优先历史命中的集，
      // 否则第 0 集。
      _manualRange
          ? _rangeIndex * EpisodeRangePolicy.groupSize(ordered.length)
          : _focusIndex(ordered),
      _episodesReversed,
    );
    final rangeIndex = _manualRange
        ? _rangeIndex.clamp(0, ranges.length - 1)
        : EpisodeRangePolicy.selectedPosition(ranges);
```

并在 `TmdbEpisodeStrip(...)` 里加：

```dart
          ranges: ranges,
          rangeIndex: rangeIndex,
          onRangeChanged: (index) => setState(() {
            _rangeIndex = index;
            _manualRange = true;
          }),
```

在 `_DetailPageState` 里加 `_focusIndex`：

```dart
  /// 自动跟随的焦点集在**渲染列表**里的下标。
  ///
  /// 优先「历史命中的那一集」，否则第 0 集：未手动选过区间时，
  /// 区间应停在用户关心的那一集所在页，而不是永远停在第 1 页。
  int _focusIndex(List<VodEpisode> ordered) {
    if (ordered.isEmpty) return 0;
    final lines = widget.state.playLinesOf(_currentVod ?? widget.vod);
    if (lines.isEmpty) return 0;
    final active = _activeLine(lines);
    // **三个参数**：`_recentRenderedIndex` 在计划 2 Task 6 落地时定为
    // `(Vod vod, VodPlayLine rawLine, List<VodEpisode> ordered)` ——
    // 原设计的 `enrichedLine` 参数从未被用到，已被删除（实现时发现）。
    final recent = _recentRenderedIndex(widget.vod, active, ordered);
    return recent < 0 ? 0 : recent;
  }
```

> **硬前置**：`_recentRenderedIndex` 由**计划 2 的 Task 6** 提供，
> 签名是 `(Vod, VodPlayLine, List<VodEpisode>)`（三参）。
> 本任务必须在计划 2 Task 6 完成之后执行，否则编译失败。

(f) 区间标签用**真实集号**修正（`docs/phase6/design/03` §4.2）。在
`_buildEpisodes` 里，算出 `ranges` 之后加：

```dart
    // 用**真实集号**修正区间标签（对齐上游 `buildCardEpisodeRanges`）。
    // 集号可能不连续（缺号、重复号），直接用列表下标会误导。
    final corrected = <EpisodeRange>[];
    for (final range in ranges) {
      final slice = EpisodeRangePolicy.slice(ordered, range);
      if (slice.isEmpty) {
        corrected.add(range);
        continue;
      }
      final first = _episodeNumberOf(slice.first, ordered);
      final last = _episodeNumberOf(slice.last, ordered);
      corrected.add(
        EpisodeRange(
          label: first == last ? '$first' : '$first-$last',
          start: range.start,
          end: range.end,
          selected: range.selected,
        ),
      );
    }
```

`_episodeNumberOf` 用 TMDB 富集的集号，取不到时退回列表下标 + 1：

```dart
  /// 集号：优先 TMDB 富集的 `tmdb_episode_number`，否则列表下标 + 1。
  int _episodeNumberOf(VodEpisode episode, List<VodEpisode> ordered) {
    final raw = episode.extra['tmdb_episode_number'];
    if (raw is int && raw > 0) return raw;
    if (raw is num && raw.toInt() > 0) return raw.toInt();
    final index = ordered.indexOf(episode);
    return index < 0 ? 1 : index + 1;
  }
```

把传给 `TmdbEpisodeStrip` 的 `ranges` 改为 `corrected`。

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_episode_range_test.dart test/phase6_season_controls_test.dart
```

预期：全绿（`phase6_episode_range_test` 29 个、`phase6_season_controls_test` 13 个）。

- [ ] **Step 5: 提交**

```bash
git add lib/state/tmdb_state.dart lib/ui/tmdb_widgets.dart lib/ui/browse_pages.dart test/phase6_episode_range_test.dart test/phase6_season_controls_test.dart
git commit -m "新增：切季重置区间 + 季度过滤空结果回退 + 站点页区间接线（design/03 §4.2、§5）"
```

---

## 收尾验证

- [ ] **跑全量单测**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test
```

预期：除已知的 `phase2_last_site_test` 文件锁抖动外全绿。

- [ ] **跑静态分析**

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' analyze
```

预期：`No issues found!`。

- [ ] **确认季度与选集门禁**

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test `
  test/phase4_tmdb_ui_test.dart `
  test/phase4_tmdb_detail_view_test.dart `
  test/phase4_tmdb_available_seasons_test.dart
```

预期：全绿。

- [ ] **跑 L3 集成测试（含截图基线更新）**

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test `
  integration_test/tmdb_detail_flow_test.dart `
  integration_test/tmdb_detail_visual_flow_test.dart -d windows
```

预期：全绿。`tmdb_detail_visual_flow_test` 的截图基线因季度 UI 变更需更新，
更新后的 PNG 覆盖到 `docs/phase4/evidence/`（既有证据目录）。

- [ ] **产出证据（`design/05` §6）**

| 文件 | 内容 |
| --- | --- |
| `docs/phase6/evidence/season-button.png` | 季度按钮常驻（单季场景） |
| `docs/phase6/evidence/episode-ranges.png` | 选集区间条（长剧集，验证阶梯分组） |

截图由集成测试的 `RepaintBoundary → toImage → PNG` harness 产出。

```bash
git add docs/phase6/evidence/
git commit -m "证据：季度按钮与选集区间条截图（design/05 §6）"
```
