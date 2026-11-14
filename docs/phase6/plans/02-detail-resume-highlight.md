# 详情页续播与高亮（首屏按钮读历史 + 线路/选集高亮）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 详情页首屏按钮从硬编码「播放第一集」改为读历史记录续播（文案与目标集都跟着历史走），并在线路 chip 与选集卡片上高亮「最近播放」的线路与集数。

**Architecture:** 历史解析（线路三级匹配 + 集匹配 + 歧义判定）抽成**纯逻辑**函数放 `lib/core/history_view.dart`，先用 L1 单测锁死语义；`DetailPage` 只负责取历史、应用解析结果、渲染标记。

**Tech Stack:** Flutter 3.47 / Dart 3.13、`flutter_test`、Material 3。

**Spec:** `docs/phase6/design/02-detail-resume-and-highlight.md`（配套 `00` 总索引 §3.2、§3.3）

## Global Constraints

- 字重只用 400 / 700，**禁止 `w500` / `w600`**。
- **禁止改动 Material 3 的字号与行高**（会挤出 800×600 测试视口）。
- 圆角只用 `AppRadius`；间距只用 `AppSpace`；不引入新散值。
- 不使用阴影、`surfaceTint`；`elevation: 0`。
- 颜色从 `Theme.of(context).colorScheme` / `context.semanticColors` 取，不写死十六进制。
- 海报 2:3、剧照 **16:9**（测试断言 ±0.1）。
- **`ValueKey('detail-hero-play')` 必须保留**（`test/phase3_detail_page_test.dart` 断言 `findsOneWidget`）。
- **选集卡片外壳必须仍是 `OutlinedButton`**，key 必须仍是
  `ValueKey('episode-<flag>-<index>')`（集成门禁按
  `widget is OutlinedButton && key.startsWith('episode-<flag>-')` 计数，断言「不补集」）。
- **线路 chip 必须仍是 `ChoiceChip`**，key 必须仍是 `ValueKey('tmdb-line-<flag>')`。
- 播放必须用**线路原始下标**（`VodPlayLine.episodes` 的下标），不是渲染下标。
- 测试命令（清掉损坏的 git 环境变量，用绝对路径）：

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

---

## File Structure

| 文件 | 职责 | 动作 |
| --- | --- | --- |
| `lib/core/history_view.dart` | 追加：历史解析（线路三级匹配 + 集匹配）与按钮文案决策（纯逻辑） | 修改 |
| `lib/ui/browse_pages.dart` | `DetailPage` 新增两个参数、自动选线路、首屏按钮接历史、传高亮标记 | 修改 |
| `lib/ui/tmdb_detail_view.dart` | `TmdbLineSelector` 加 `recentFlag`；`TmdbEpisodeCardTile` 加 `isRecent` | 修改 |
| `test/phase6_detail_resume_test.dart` | 解析与文案的 L1 测试 + 详情页的 L2 测试 | 创建 |

> **与计划 1 的接口契约**：`DetailPage` 新增的两个参数
> `historyFlag` / `historyEpisodeId` 由本计划 **Task 3** 定义，
> 计划 1 的 Task 8 消费它们。**先执行本计划的 Task 3**，再执行计划 1 的 Task 8。

---

### Task 1: 历史解析（纯逻辑）

**Files:**
- Modify: `lib/core/history_view.dart`
- Test: `test/phase6_detail_resume_test.dart`

**Interfaces:**
- Consumes: `VodPlayLine` / `VodEpisode`（`lib/core/protocol.dart`）
- Produces:
  - `class HistoryResumeTarget`，字段 `flag`（`String`）、`episodeIndex`（`int`）、`episodeName`（`String`）、`matched`（`bool`）；工厂 `HistoryResumeTarget.firstEpisodeOf(List<VodPlayLine> lines)`
  - `HistoryResumeTarget resolveHistoryTarget({required String historyFlag, required String historyEpisodeId, required String historyEpisodeName, required List<VodPlayLine> lines})`

> **分层约束（不得违反）**：`lib/core/` 是**纯逻辑层**——全仓库 `core/` 下**没有任何
> 文件** import `../services/`，多个 core 模块明写「不依赖 Flutter，也不依赖
> `dart:io`」。因此本函数**不得**收 `PlaybackHistory`（它定义在
> `services/storage.dart`），只收它真正需要的三个标量字段。
> 调用方（`DetailPage`）自己从 `PlaybackHistory` 取字段传进来。

- [ ] **Step 1: 写失败的测试**

创建 `test/phase6_detail_resume_test.dart`：

```dart
/// 详情页从历史恢复播放的解析（`docs/phase6/design/02` §2）。
///
/// 纯逻辑，无 Flutter 依赖：线路三级匹配与"歧义就不猜"是本轮最容易写错的
/// 语义，必须在无窗口环境下锁死。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/core/protocol.dart';

void main() {
  VodPlayLine lineOf(
    String flag,
    List<(String, String)> episodes, {
    String? sourceFlag,
  }) => VodPlayLine(
    flag: flag,
    sourceFlag: sourceFlag,
    episodes: [
      for (final (name, url) in episodes) VodEpisode(name: name, url: url),
    ],
  );

  /// 调用助手：默认是「没有历史」（三个字段全空）。
  HistoryResumeTarget resolve({
    String flag = '',
    String episodeId = '',
    String episodeName = '',
    required List<VodPlayLine> lines,
  }) => resolveHistoryTarget(
    historyFlag: flag,
    historyEpisodeId: episodeId,
    historyEpisodeName: episodeName,
    lines: lines,
  );

  final twoLines = [
    lineOf('线路一', [('第1集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
    lineOf('线路二', [('第1集', 'http://y/e1'), ('第2集', 'http://y/e2')]),
  ];

  group('无历史', () {
    test('返回第一条线路第 0 集，matched=false', () {
      final target = resolve(lines: twoLines);
      expect(target.flag, '线路一');
      expect(target.episodeIndex, 0);
      expect(target.matched, isFalse);
    });

    test('没有线路时返回空目标，不抛异常', () {
      final target = resolve(lines: const []);
      expect(target.flag, '');
      expect(target.episodeIndex, 0);
      expect(target.matched, isFalse);
    });
  });

  group('第一级：flag 精确命中', () {
    test('flag 与集 URL 都对上 → 命中', () {
      final target = resolve(
        flag: '线路二',
        episodeId: 'http://y/e2',
        lines: twoLines,
      );
      expect(target.flag, '线路二');
      expect(target.episodeIndex, 1);
      expect(target.episodeName, '第2集');
      expect(target.matched, isTrue);
    });

    test('flag 命中但该线路不含这一集 → 降级到第二级', () {
      // 线路二不含 z/e9，但线路一也不含 → 最终退回第一条线路。
      final target = resolve(
        flag: '线路二',
        episodeId: 'http://z/e9',
        lines: twoLines,
      );
      expect(target.flag, '线路一');
      expect(target.episodeIndex, 0);
      expect(target.matched, isFalse);
    });

    test('playbackFlag（sourceFlag）也能命中', () {
      final lines = [
        lineOf('线路一', [('第1集', 'http://x/e1')]),
        lineOf('合并线路', [('第1集', 'http://y/e1')], sourceFlag: '原始flag'),
      ];
      final target = resolve(
        flag: '原始flag',
        episodeId: 'http://y/e1',
        lines: lines,
      );
      expect(target.flag, '合并线路', reason: '按 playbackFlag 匹配，返回展示 flag');
      expect(target.matched, isTrue);
    });
  });

  group('第二级：集 URL 唯一命中', () {
    test('flag 不认识但集 URL 唯一 → 命中那条线路', () {
      final target = resolve(
        flag: '已不存在的线路',
        episodeId: 'http://y/e2',
        lines: twoLines,
      );
      expect(target.flag, '线路二');
      expect(target.episodeIndex, 1);
      expect(target.matched, isTrue);
    });

    test('集 URL 在多条线路里都出现 → 歧义，不猜', () {
      final ambiguous = [
        lineOf('线路一', [('第1集', 'http://same/e1')]),
        lineOf('线路二', [('第1集', 'http://same/e1')]),
      ];
      final target = resolve(
        flag: '不存在的线路',
        episodeId: 'http://same/e1',
        lines: ambiguous,
      );
      expect(target.flag, '线路一', reason: '歧义时退回第一条，不猜');
      expect(target.matched, isFalse);
    });
  });

  group('第三级：线路名命中', () {
    test('flag 命中但集对不上 → 线路命中、不算完整命中', () {
      // 历史 episodeId 是空串（旧数据）→ 第一级因"不含该集"失败，
      // 第二级因 URL 为空无法匹配，第三级按 flag 命中。
      final target = resolve(flag: '线路二', lines: twoLines);
      expect(target.flag, '线路二');
      expect(target.episodeIndex, 0, reason: '集匹配不上时取第 0 集');
      expect(target.matched, isFalse, reason: '线路命中但集没命中 → 不算完整命中');
    });
  });

  group('集匹配', () {
    test('URL 优先于集名', () {
      final lines = [
        lineOf('线路一', [('第9集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
      ];
      final target = resolve(
        flag: '线路一',
        episodeId: 'http://x/e2',
        episodeName: '第9集',
        lines: lines,
      );
      expect(target.episodeIndex, 1, reason: 'URL 精确匹配优先于集名');
    });

    test('URL 匹配不上时退回集名', () {
      final lines = [
        lineOf('线路一', [('第1集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
      ];
      final target = resolve(
        flag: '线路一',
        episodeId: 'http://stale/old',
        episodeName: '第2集',
        lines: lines,
      );
      expect(target.episodeIndex, 1, reason: '集名兜底');
      // 集名兜底**也算完整命中**：线路对上了、集也对上了（只是靠名字而非 URL）。
      // 这条断言是 Task 3 的前提——`matched` 决定是否自动切线路
      // （`design/02` §4.1），不锁住它会让「集名兜底」的行为漂移。
      expect(target.matched, isTrue, reason: '集名命中也是完整命中');
      expect(target.episodeName, '第2集');
    });

    test('都不匹配时取第 0 集且 matched=false', () {
      final target = resolve(
        flag: '线路一',
        episodeId: 'http://stale/old',
        episodeName: '第99集',
        lines: twoLines,
      );
      expect(target.flag, '线路一');
      expect(target.episodeIndex, 0);
      expect(target.matched, isFalse);
    });
  });

  group('firstEpisodeOf', () {
    test('有线路时返回第一条线路第 0 集', () {
      final target = HistoryResumeTarget.firstEpisodeOf(twoLines);
      expect(target.flag, '线路一');
      expect(target.episodeIndex, 0);
      expect(target.matched, isFalse);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：编译失败，`Method not found: 'resolveHistoryTarget'`。

- [ ] **Step 3: 写最小实现**

在 `lib/core/history_view.dart` 顶部 import 区加：

```dart
import 'protocol.dart';
```

> **只 import `protocol.dart`**：`lib/core/` 是纯逻辑层，全仓库 `core/` 下
> 没有任何文件 import `../services/`。`PlaybackHistory` 定义在
> `services/storage.dart`，因此本模块**不得**引用它——只收它需要的三个标量字段。

在文件末尾追加：

```dart
/// 详情页从历史恢复播放的目标（`docs/phase6/design/02` §2）。
class HistoryResumeTarget {
  const HistoryResumeTarget({
    required this.flag,
    required this.episodeIndex,
    required this.episodeName,
    required this.matched,
  });

  /// 命中的线路 flag（展示用）。空串表示没有任何线路。
  final String flag;

  /// 该线路内剧集的**原始下标**（`VodPlayLine.episodes` 的下标）。
  ///
  /// 必须用原始下标：播放要的是它，而渲染下标经过季度过滤与倒序。
  final int episodeIndex;

  /// 命中的集名（用于按钮文案）。
  final String episodeName;

  /// 是否**完整**命中（线路与集都对上）。
  ///
  /// 只有完整命中才允许把按钮改成「继续播放」。
  final bool matched;

  /// 无历史时的目标：第一条线路第 0 集。
  factory HistoryResumeTarget.firstEpisodeOf(List<VodPlayLine> lines) {
    if (lines.isEmpty) {
      return const HistoryResumeTarget(
        flag: '',
        episodeIndex: 0,
        episodeName: '',
        matched: false,
      );
    }
    final first = lines.first;
    return HistoryResumeTarget(
      flag: first.flag,
      episodeIndex: 0,
      episodeName: first.episodes.isEmpty ? '' : first.episodes.first.name,
      matched: false,
    );
  }
}

/// 解析「用哪条线路、第几集」（`docs/phase6/design/02` §2.1、§2.2）。
///
/// 线路匹配三级顺序，任一级命中即返回；集匹配两级顺序。
/// **任何一级出现歧义都不猜**（对齐上游 `uniqueFlagForEpisodeUrl`）。
///
/// 收标量而不是 `PlaybackHistory`：后者在 `services/storage.dart`，
/// 而本模块属于纯逻辑层（`core/` 不得依赖 `services/`）。
HistoryResumeTarget resolveHistoryTarget({
  required String historyFlag,
  required String historyEpisodeId,
  required String historyEpisodeName,
  required List<VodPlayLine> lines,
}) {
  if (lines.isEmpty) return HistoryResumeTarget.firstEpisodeOf(lines);
  final hasHistory = historyFlag.isNotEmpty ||
      historyEpisodeId.isNotEmpty ||
      historyEpisodeName.isNotEmpty;
  if (!hasHistory) return HistoryResumeTarget.firstEpisodeOf(lines);

  // 第一级：flag 精确命中，且该线路**包含**这一集。
  for (final line in lines) {
    if (line.playbackFlag != historyFlag && line.flag != historyFlag) continue;
    final index = _episodeIndexOf(line, historyEpisodeId, historyEpisodeName);
    if (index >= 0) {
      return HistoryResumeTarget(
        flag: line.flag,
        episodeIndex: index,
        episodeName: line.episodes[index].name,
        matched: true,
      );
    }
  }

  // 第二级：集 URL 在所有线路里**唯一**命中。
  if (historyEpisodeId.isNotEmpty) {
    final hits = <(VodPlayLine, int)>[];
    for (final line in lines) {
      final index = _indexOfUrl(line, historyEpisodeId);
      if (index >= 0) hits.add((line, index));
    }
    if (hits.length == 1) {
      final (line, index) = hits.first;
      return HistoryResumeTarget(
        flag: line.flag,
        episodeIndex: index,
        episodeName: line.episodes[index].name,
        matched: true,
      );
    }
  }

  // 第三级：线路名命中——**仅当历史没有集入口目标**（旧数据）。
  //
  // 为什么必须加这个前提：历史带着集入口却一条线路都找不到时，说明那一集已
  // 从所有线路里消失，此时按线路名"猜"第 0 集会把用户送到错误的集上；按
  // 「歧义就不猜」退回第一条线路。只有历史**没有**集入口（`episodeId` 为空，
  // 旧数据）时，线路名命中才是可信的线路级命中。
  if (historyEpisodeId.isNotEmpty) {
    return HistoryResumeTarget.firstEpisodeOf(lines);
  }
  for (final line in lines) {
    if (line.playbackFlag != historyFlag && line.flag != historyFlag) continue;
    final index = _episodeIndexOf(line, historyEpisodeId, historyEpisodeName);
    return HistoryResumeTarget(
      flag: line.flag,
      episodeIndex: index < 0 ? 0 : index,
      episodeName: index < 0
          ? (line.episodes.isEmpty ? '' : line.episodes.first.name)
          : line.episodes[index].name,
      // 线路命中但集没命中 → 不是完整命中。
      matched: false,
    );
  }

  return HistoryResumeTarget.firstEpisodeOf(lines);
}

/// 在线路内定位历史那一集：URL 精确优先，集名兜底。
int _episodeIndexOf(VodPlayLine line, String episodeId, String episodeName) {
  if (episodeId.isNotEmpty) {
    final byUrl = _indexOfUrl(line, episodeId);
    if (byUrl >= 0) return byUrl;
  }
  if (episodeName.isNotEmpty) {
    for (var i = 0; i < line.episodes.length; i++) {
      if (line.episodes[i].name == episodeName) return i;
    }
  }
  return -1;
}

int _indexOfUrl(VodPlayLine line, String url) {
  for (var i = 0; i < line.episodes.length; i++) {
    if (line.episodes[i].url == url) return i;
  }
  return -1;
}
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：`All tests passed!`（12 个用例）。

- [ ] **Step 5: 提交**

```bash
git add lib/core/history_view.dart test/phase6_detail_resume_test.dart
git commit -m "新增：详情页历史解析（线路三级匹配 + 集匹配，design/02 §2）"
```

---

### Task 2: 首屏按钮文案决策（纯逻辑）

**Files:**
- Modify: `lib/core/history_view.dart`
- Test: `test/phase6_detail_resume_test.dart`（追加）

**Interfaces:**
- Consumes: `HistoryResumeTarget`（Task 1）
- Produces:
  - `String historyPlayLabel({required HistoryResumeTarget target, required Duration? resumePosition, String fallback = '播放第一集'})`

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_detail_resume_test.dart` 的 `main()` 末尾追加：

```dart
  group('首屏按钮文案（design/02 §3.1）', () {
    const matched = HistoryResumeTarget(
      flag: '线路一',
      episodeIndex: 1,
      episodeName: '第2集',
      matched: true,
    );
    const unmatched = HistoryResumeTarget(
      flag: '线路一',
      episodeIndex: 0,
      episodeName: '第1集',
      matched: false,
    );

    test('完整命中且有续播位置 → 继续播放 · 集名', () {
      expect(
        historyPlayLabel(
          target: matched,
          resumePosition: const Duration(seconds: 30),
        ),
        '继续播放 · 第2集',
      );
    });

    test('完整命中但无续播位置（已看完 / 位置过短）→ 播放第一集', () {
      // `resumePositionFor` 已把 completed 与位置过短一起处理成 null，
      // 因此这里传 null 就代表那两种情形——它的归一化在
      // `lib/state/app_state.dart` 的 `resumePositionFor` 里，不在本模块。
      expect(
        historyPlayLabel(target: matched, resumePosition: null),
        '播放第一集',
      );
    });

    test('未完整命中 → 播放第一集', () {
      expect(
        historyPlayLabel(
          target: unmatched,
          resumePosition: const Duration(seconds: 30),
        ),
        '播放第一集',
      );
    });

    test('命中但集名为空 → 用兜底文案', () {
      const noName = HistoryResumeTarget(
        flag: '线路一',
        episodeIndex: 1,
        episodeName: '',
        matched: true,
      );
      expect(
        historyPlayLabel(
          target: noName,
          resumePosition: const Duration(seconds: 30),
        ),
        '播放第一集',
        reason: '没有集名就无法表达"继续播放哪一集"',
      );
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：编译失败，`Method not found: 'historyPlayLabel'`。

- [ ] **Step 3: 写最小实现**

在 `lib/core/history_view.dart` 末尾追加：

```dart
/// 详情页首屏按钮的文案（`docs/phase6/design/02` §3.1）。
///
/// 对齐上游 `TmdbDetailActivity#updatePlayLabel`：命中当前集**且**有进度
/// 才叫"继续播放"，否则是"播放第一集"。
///
/// 为什么用 `resumePosition` 而不是自己判断 `completed` 与位置阈值：
/// `AppState.resumePositionFor`（`lib/state/app_state.dart`）已经把这两件事
/// 一起处理了，两处判断会漂移。
///
/// 注意这里用反引号而不是 dartdoc 的 `[]` 引用：本模块是纯逻辑层，
/// **不得** import `state/app_state.dart`，写成 `[AppState.resumePositionFor]`
/// 会是无法解析的悬空引用（当前 lint 未启用 `comment_references` 所以不报，
/// 但 dartdoc 不会生成链接）。
String historyPlayLabel({
  required HistoryResumeTarget target,
  required Duration? resumePosition,
  String fallback = '播放第一集',
}) {
  if (!target.matched) return fallback;
  if (resumePosition == null) return fallback;
  if (target.episodeName.isEmpty) return fallback;
  return '继续播放 · ${target.episodeName}';
}
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：`All tests passed!`（16 个用例：Task 1 的 12 + 本任务 4）。

- [ ] **Step 5: 提交**

```bash
git add lib/core/history_view.dart test/phase6_detail_resume_test.dart
git commit -m "新增：首屏按钮文案决策（design/02 §3.1）"
```

---

### Task 3: `DetailPage` 接受历史参数并自动选线路

**Files:**
- Modify: `lib/ui/browse_pages.dart`（`DetailPage` 与 `_DetailPageState`）
- Test: `test/phase6_detail_resume_test.dart`（追加）

**Interfaces:**
- Consumes: `resolveHistoryTarget`（Task 1）
- Produces:
  - `DetailPage({..., String historyFlag = '', String historyEpisodeId = ''})`
  - `_DetailPageState` 内的 `_history` getter（`PlaybackHistory?`）与 `_resumeTarget` getter（`HistoryResumeTarget`）

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_detail_resume_test.dart` 追加。该文件此时已有
`flutter_test` / `history_view` / `protocol` 三个 import（Task 1 加的），
本任务**再补四个**：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
```

> **不要**加 `import 'package:webhtv_pc/core/tmdb_detail_model.dart';`——
> 本任务的用例用不到它，加了会触发 `unused_import`。
>
> **也不要**假设 `browse_pages.dart` 已经 import 了 `services/storage.dart`：
> 实测它**没有**（既无 `PlaybackHistory` 引用也无该 import），
> 所以实现步骤里要显式补上（见 Step 3）。

```dart
  group('DetailPage 自动选历史线路（design/02 §4）', () {
    late Directory tempDir;
    late AppState state;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webhtv-detail-resume');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': tempDir.path, 'local': tempDir.path},
        ),
        log: LogService(),
      );
      await state.bootstrap();
    });

    tearDown(() async {
      state.dispose();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    Future<void> pumpDetail(
      WidgetTester tester, {
      required Vod vod,
      String historyFlag = '',
      String historyEpisodeId = '',
    }) async {
      tester.view.physicalSize = const Size(1400, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: state,
            vod: vod,
            historyFlag: historyFlag,
            historyEpisodeId: historyEpisodeId,
          ),
        ),
      );
      await tester.pump();
      // **必须滚过满屏 hero**：`DetailPage` 的背景 hero 是满屏的
      // （`TmdbDetailHeader` 在 1400×2000 视口下实测占满整屏），正文因此从
      // **第二屏**开始；而正文是懒加载 `ListView`，不滚过去线路条根本没被挂载，
      // `tester.widget<ChoiceChip>` 会抛 `Bad state: No element`。
      //
      // 这与 `phase3_detail_page_test.dart` 的 `scrollPastHero` 是同一件事
      // （那里的注释写着「背景 hero 现在是满屏的…正文因此从第二屏开始」）。
      await revealLineSelector(tester);
    }

    /// 按增量拖动外层 `Scrollable`，直到线路条挂载（最多 20 次）。
    ///
    /// 只会「找不到就继续拖」：真的找不到时下游
    /// `tester.widget<ChoiceChip>` 会直接失败，**不会**产生假通过。
    Future<void> revealLineSelector(WidgetTester tester) async {
      for (var attempt = 0; attempt < 20; attempt++) {
        if (find
            .byKey(const ValueKey('tmdb-line-selector'))
            .evaluate()
            .isNotEmpty) {
          return;
        }
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await tester.pump();
      }
    }

    final twoLineVod = Vod(
      vodId: 'demo-1',
      vodName: '剧集甲',
      // **`$$$` 必须转义**：`$` 在 Dart 字符串里是插值前缀，
      // 写成 `'线路一$$$线路二'` 会编译失败
      // （`A '$' has special meaning inside a string`）。
      // TVBox 的线路分隔符就是字面 `$$$`，转义不改变语义。
      vodPlayFrom: '线路一\$\$\$线路二',
      vodPlayUrl:
          '第1集\$http://x/e1#第2集\$http://x/e2'
          '\$\$\$'
          '第1集\$http://y/e1#第2集\$http://y/e2',
    );

    testWidgets('传入 historyFlag 时选中该线路的 chip', (tester) async {
      await pumpDetail(
        tester,
        vod: twoLineVod,
        historyFlag: '线路二',
        historyEpisodeId: 'http://y/e1',
      );

      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路二')),
      );
      expect(chip.selected, isTrue);
      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isFalse);
    });

    testWidgets('历史线路已不存在时退回第一条线路，不报错', (tester) async {
      await pumpDetail(
        tester,
        vod: twoLineVod,
        historyFlag: '已不存在的线路',
        historyEpisodeId: 'http://nowhere/e1',
      );

      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('历史线路在但那一集已消失 → 不切线路（design/02 §4.1）', (tester) async {
      // 线路二存在，但 http://stale/gone 不在任何线路上 →
      // §2.1 第 1 级降级、第 2 级因 URL 非空且无命中而止步、第 3 级被前提挡住
      // → matched == false → **不得**把用户切到线路二（切过去也没有那一集）。
      await pumpDetail(
        tester,
        vod: twoLineVod,
        historyFlag: '线路二',
        historyEpisodeId: 'http://stale/gone',
      );

      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isTrue, reason: 'matched=false 时保持第一条线路');
      final second = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路二')),
      );
      expect(second.selected, isFalse);
    });

    testWidgets('不传历史参数时行为不变（第一条线路）', (tester) async {
      await pumpDetail(tester, vod: twoLineVod);
      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isTrue);
    });

    testWidgets('旧数据（无集入口）按线路名命中但集未对上 → 不切线路', (tester) async {
      // **这个用例是 §4.1 裁定的唯一钉子。**
      //
      // 为什么必须单独有它：上面三个 `matched == false` 的场景里，
      // `resolveHistoryTarget` 返回的都是 `firstEpisodeOf(lines)`，
      // 其 `flag` 恰好就是第一条线路——于是「正确实现（`target.matched`）」
      // 与「错误实现（`target.flag.isNotEmpty`）」**行为完全一致**，无法区分。
      // 变异测试实测：把 `target.matched` 换成 `target.flag.isNotEmpty`，
      // 上面全部用例照样通过。
      //
      // 本用例走 §2.1 **第三级**（历史没有集入口 → 按线路名命中）：
      // `flag == '线路二'` 但 `matched == false`。
      // 正确实现不切（仍选线路一）；错误实现会切到线路二 → 本用例失败。
      await pumpDetail(tester, vod: twoLineVod, historyFlag: '线路二');

      final first = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(first.selected, isTrue, reason: 'matched=false 时保持第一条线路');
      final second = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路二')),
      );
      expect(second.selected, isFalse, reason: '不得切到只按线路名命中的线路');
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：编译失败，`No named parameter with the name 'historyFlag'`。

- [ ] **Step 3: 写最小实现**

在 `lib/ui/browse_pages.dart` 中：

(a) `DetailPage` 加两个参数：

```dart
class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.state,
    required this.vod,
    this.historyFlag = '',
    this.historyEpisodeId = '',
  });

  final AppState state;
  final Vod vod;

  /// 历史命中的线路 flag（空串 = 未传入）。
  ///
  /// 由历史页传入**用户点的那一条**记录，优先于页面自己查到的"最近一条"：
  /// 同一部剧有多条历史时，点旧记录却续新记录是错的
  /// （`docs/phase6/design/02` §7.1）。
  final String historyFlag;

  /// 历史命中的集入口目标（空串 = 未传入）。
  final String historyEpisodeId;
```

(b) 在 `_DetailPageState` 里加历史解析（放在 `_currentVod` getter 之前）：

```dart
  /// 本页要用的历史记录。
  ///
  /// 优先级：**构造参数 > 自己查**（`docs/phase6/design/02` §7.1）。
  PlaybackHistory? get _history {
    if (widget.historyFlag.isNotEmpty ||
        widget.historyEpisodeId.isNotEmpty) {
      return PlaybackHistory(
        id: 0,
        siteKey: widget.state.selectedSite?.key ?? '',
        vodId: widget.vod.vodId,
        vodName: widget.vod.vodName,
        vodPic: widget.vod.vodPic,
        flag: widget.historyFlag,
        episodeName: '',
        episodeId: widget.historyEpisodeId,
        positionMs: 0,
        durationMs: 0,
        updatedAt: 0,
      );
    }
    return widget.state.findHistory(
      siteKey: widget.state.selectedSite?.key ?? '',
      vodId: widget.vod.vodId,
    );
  }

  /// 本页的续播目标（线路 + 集下标）。
  ///
  /// 在详情到达后才解析：`_activeLine` 依赖 `lines`，而 `lines` 在详情请求
  /// 返回前可能是列表页传入的残缺数据，在残缺数据上解析会得出错误线路。
  ///
  /// 传三个标量而不是 `PlaybackHistory`：`resolveHistoryTarget` 在纯逻辑层
  /// （`core/`），不得依赖 `services/storage.dart`。
  HistoryResumeTarget _resumeTarget(List<VodPlayLine> lines) {
    final history = _history;
    return resolveHistoryTarget(
      historyFlag: history?.flag ?? '',
      historyEpisodeId: history?.episodeId ?? '',
      historyEpisodeName: history?.episodeName ?? '',
      lines: lines,
    );
  }
```

(c) 把历史线路应用到 `_selectedLineFlag`。在 `build` 里 `final lines = state.playLinesOf(vod);` **之后**插入：

```dart
    // 详情到达后自动切到历史线路（`docs/phase6/design/02` §4、§4.1）。
    //
    // **必须等 `belongs` 为真**（= 本页的详情结果已到达），不能只看
    // `lines.isNotEmpty`：后者在详情未到达时可能是**列表页传入条目的残缺线路**
    // （见上面 `belongs` 的注释：回退分支是列表条目，「其线路可能已由列表数据
    // 携带」）。在残缺集合上解析会得出错误线路——§2.1 第二级的「集 URL 唯一命中」
    // 在集合变小时可能**假唯一**；而且 `_selectedLineFlag` 一旦写入就**永久锁死**
    // （下面 `isEmpty` 守卫会让真详情到达后不再重解析）。
    //
    // 权衡：「列表条目自带完整线路、但详情请求始终失败」的场景不再自动切线路。
    // 这与 §4 的措辞一致——详情没到达就没有**已确认**的线路集。
    if (belongs && lines.isNotEmpty) {
      final target = _resumeTarget(lines);
      // 只在「用户还没手动选过」时应用（`_selectedLineFlag` 为空）。
      // 用户手动切过线路后，历史不得把选择抢回去。
      if (target.matched && _selectedLineFlag.isEmpty) {
        _selectedLineFlag = target.flag;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          state.tmdb.selectLine(target.flag);
          unawaited(state.reloadTmdb());
        });
      }
    }
```

(d) 顶部 import 追加**两个**：

```dart
import '../core/history_view.dart';
import '../services/storage.dart';
```

> **必须显式加 `storage.dart`**：`_history` 的返回类型是
> `PlaybackHistory?`，它定义在 `services/storage.dart`。
> 不要假设该文件已经 import 了它——实测 `browse_pages.dart` 既没有
> `PlaybackHistory` 的任何引用，也没有这个 import（原计划此处写「已有、无需新增」，
> **是错的**）。

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：`All tests passed!`（22 个用例：Task 1–2 的 16 + 本任务 6）。

确认没打破详情页既有门禁：

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase3_detail_page_test.dart test/phase4_tmdb_ui_test.dart
```

预期：全绿。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/browse_pages.dart test/phase6_detail_resume_test.dart
git commit -m "新增：DetailPage 接受历史参数并自动选历史线路（design/02 §4）"
```

---

### Task 4: 首屏按钮接历史（文案 + 目标集）

**Files:**
- Modify: `lib/ui/browse_pages.dart`
- Test: `test/phase6_detail_resume_test.dart`（追加）

**Interfaces:**
- Consumes: `historyPlayLabel`（Task 2）、`_resumeTarget`（Task 3）、`AppState.resumePositionFor`（既有）
- Produces: 无新 API

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_detail_resume_test.dart` 追加（**无需新增任何 import**——
该文件已有 `dart:io` / `material` / `app_paths` / `log_service` / `app_state` /
`browse_pages` / `history_view` / `protocol` / `flutter_test`，本任务的用例只用这些；
**不要**加 `player_page.dart`，本任务的用例不引用播放器页）：

> **为什么复用局部 `setUp`**：Dart 的 `group` 不共享 `setUp` 变量，
> 所以这一组要自己声明一套（与上一组结构相同）。

```dart
  group('首屏按钮接历史（design/02 §3）', () {
    // 复用上一组的 setUp/tearDown 结构：这里重新声明一套局部状态，
    // 因为 Dart 的 group 不共享 setUp 变量。
    late Directory dir;
    late AppState appState;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-hero-play');
      appState = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': dir.path, 'local': dir.path},
        ),
        log: LogService(),
      );
      await appState.bootstrap();
    });

    tearDown(() async {
      appState.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final vod = Vod(
      vodId: 'demo-1',
      vodName: '剧集甲',
      vodPlayFrom: '线路一',
      vodPlayUrl: '第1集\$http://x/e1#第2集\$http://x/e2',
    );

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: DetailPage(state: appState, vod: vod)),
      );
      await tester.pump();
      // **注入「本页详情已到达」**：否则 `state.detailResult` 为 null
      // （fake-async 区 HTTP 固定失败），`belongs` 恒为 false。
      //
      // 注：hero 按钮**本身**不依赖它（渲染条件只有 `lines.isNotEmpty`，
      // 而 `widget.vod` 自带两集），但本任务断言的是 `design/02` §3 描述的
      // 「详情到达后用历史决定文案」路径——不注入就是在测另一条路。
      // 依据：`loadDetail` 在无站点服务时**提前返回**（`app_state.dart:2116`，
      // 早于 `_detailResult = null`），注入不会被页面自身请求清掉。
      appState.seedDetailForTest(vod: vod);
      await tester.pump();
    }

    // **不要滚过 hero**：hero 按钮在**首屏**（`heroActions` 是 hero 的一部分），
    // `phase3_detail_page_test.dart` 也是先断言 `detail-hero-play` 存在、
    // **再** `scrollPastHero`。滚动反而会让懒加载列表销毁 hero，
    // 使 `findsOneWidget` 失败。

    testWidgets('无历史 → 文案「播放第一集」', (tester) async {
      await pump(tester);
      expect(find.text('播放第一集'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-hero-play')), findsOneWidget);
    });

    testWidgets('有历史且有进度 → 文案「继续播放 · <集名>」', (tester) async {
      appState.database!.upsertHistory(
        siteKey: appState.selectedSite?.key ?? '',
        vodId: 'demo-1',
        vodName: '剧集甲',
        flag: '线路一',
        episodeName: '第2集',
        episodeId: 'http://x/e2',
        positionMs: 30000,
        durationMs: 100000,
      );
      await pump(tester);
      expect(find.text('继续播放 · 第2集'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-hero-play')), findsOneWidget);
    });

    testWidgets('已看完 → 回到「播放第一集」', (tester) async {
      appState.database!.upsertHistory(
        siteKey: appState.selectedSite?.key ?? '',
        vodId: 'demo-1',
        vodName: '剧集甲',
        flag: '线路一',
        episodeName: '第2集',
        episodeId: 'http://x/e2',
        positionMs: 100000,
        durationMs: 100000,
        completed: true,
      );
      await pump(tester);
      expect(find.text('播放第一集'), findsOneWidget);
      expect(find.textContaining('继续播放'), findsNothing);
    });

    testWidgets('点击 hero 播的是历史那一集，不是第 0 集', (tester) async {
      // **这是 §3.2「点击目标」的唯一钉子。**
      //
      // 为什么必须单独有它：上面 3 个用例只断言**渲染的文案**，
      // 没有一个真的点下去。变异测试实测：把 `onPressed` 里的
      // `target.episodeIndex` 改回硬编码 `0`（文案保持正确），
      // 上面 3 个用例**全部照过**——§3.2 的要求一个钉子都没有。
      //
      // 探针原理：测试环境无站点服务 → `resolvePlayback` 返回 null →
      // `_play` 抛 `playbackUrlMissing`，其 `detail` 含
      // `episode=<集名>`（`browse_pages.dart` 的 `_play` 里），
      // 经 `userMessage` 渲染成 SnackBar。断言它含 `第2集`。
      //
      // 正确实现：`episodeIndex == 1` → detail 含 `第2集` → 通过。
      // 变异实现（改回 `0`）：detail 含 `第1集` → **失败**。
      appState.database!.upsertHistory(
        siteKey: appState.selectedSite?.key ?? '',
        vodId: 'demo-1',
        vodName: '剧集甲',
        flag: '线路一',
        episodeName: '第2集',
        episodeId: 'http://x/e2',
        positionMs: 30000,
        durationMs: 100000,
      );
      await pump(tester);

      await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
      await tester.pump(); // 让 async 的 _play 跑到抛错
      await tester.pump(const Duration(milliseconds: 100)); // 让 SnackBar 出现

      expect(
        find.textContaining('第2集'),
        findsWidgets,
        reason: '§3.2：点击必须播历史命中那一集，不是第 0 集',
      );
      expect(
        find.textContaining('第1集'),
        findsNothing,
        reason: '变异实现（硬编码 0）会在这里失败',
      );
    });
  });
```

> 若 `appState.selectedSite` 为 null（测试未导入站点配置），
> `upsertHistory` 的 `siteKey` 会是空串，而 `_history` 查的也是空串，
> 两者一致，测试仍成立。

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：FAIL，`有历史且有进度` 用例找不到 `继续播放 · 第2集`。

- [ ] **Step 3: 写最小实现**

在 `lib/ui/browse_pages.dart` 的 `build` 里，把首屏按钮那一块：

```dart
                            FilledButton.icon(
                              key: const ValueKey('detail-hero-play'),
                              onPressed: () => _play(
                                vod,
                                _activeLine(lines),
                                0,
                              ),
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('播放第一集'),
                            ),
```

替换为：

```dart
                            FilledButton.icon(
                              key: const ValueKey('detail-hero-play'),
                              onPressed: () {
                                final target = _resumeTarget(lines);
                                _play(
                                  vod,
                                  _activeLine(lines),
                                  // **原始下标**：_play 要的就是
                                  // VodPlayLine.episodes 的下标，
                                  // 不是渲染下标（见 design/02 §3.3）。
                                  target.episodeIndex,
                                );
                              },
                              icon: const Icon(Icons.play_arrow),
                              label: Text(_heroPlayLabel(lines, vod)),
                            ),
```

在 `_DetailPageState` 里加文案计算方法（放在 `_resumeTarget` 之后）：

```dart
  /// 首屏按钮文案（`docs/phase6/design/02` §3.1）。
  ///
  /// **不要**加 `if (!target.matched) return '播放第一集';` 这样的提前返回：
  /// `historyPlayLabel` 内部已按 `matched` 判断（`!matched` 时必定回落 `fallback`），
  /// 再加一次是「两处判断会漂移」（§3.1 的原文理由），而且白白多一次 DB 点查。
  String _heroPlayLabel(List<VodPlayLine> lines, Vod vod) {
    final target = _resumeTarget(lines);
    // 续播位置用既有判定：它已把 completed 与"位置过短"一起处理。
    final resume = widget.state.resumePositionFor(
      siteKey: widget.state.selectedSite?.key ?? '',
      vodId: vod.vodId,
      flag: target.flag,
      episodeId: _history?.episodeId,
    );
    return historyPlayLabel(target: target, resumePosition: resume);
  }
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：`All tests passed!`（26 个用例：Task 1–3 的 22 + 本任务 4）。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/browse_pages.dart test/phase6_detail_resume_test.dart
git commit -m "新增：详情页首屏按钮读历史续播（design/02 §3）"
```

---

### Task 5: 线路 chip 的「最近播放」标记

**Files:**
- Modify: `lib/ui/tmdb_detail_view.dart`（`TmdbLineSelector`）
- Modify: `lib/ui/browse_pages.dart`（传入 `recentFlag`）
- Test: `test/phase6_detail_resume_test.dart`（追加）

**Interfaces:**
- Consumes: `_resumeTarget`（Task 3）
- Produces: `TmdbLineSelector({..., String recentFlag = ''})`；新增 `ValueKey('tmdb-line-recent-<flag>')`

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_detail_resume_test.dart` 追加（**无需新增 import**——该文件已有
`dart:io` / `material` / `app_paths` / `log_service` / `app_state` / `browse_pages` /
`history_view` / `protocol` / `flutter_test`）：

```dart
  group('线路 chip 的「最近播放」标记（design/02 §5）', () {
    late Directory dir;
    late AppState appState;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-line-recent');
      appState = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': dir.path, 'local': dir.path},
        ),
        log: LogService(),
      );
      await appState.bootstrap();
    });

    tearDown(() async {
      appState.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final vod = Vod(
      vodId: 'demo-1',
      vodName: '剧集甲',
      // **`$$$` 必须转义**：`$` 在 Dart 字符串里是插值前缀，
      // 写成 `'线路一$$$线路二'` 会编译失败
      // （`A '$' has special meaning inside a string`）。
      vodPlayFrom: '线路一\$\$\$线路二',
      vodPlayUrl:
          '第1集\$http://x/e1\$\$\$第1集\$http://y/e1',
    );

    /// 装页面、注入详情、滚到线路条。
    ///
    /// **三件事缺一不可**（Task 3–4 的教训）：
    /// 1. `seedDetailForTest` —— 否则 `detailResult` 为 null、`belongs` 恒为 false，
    ///    走的不是 `design/02` §4 描述的「详情到达后」路径；
    /// 2. 放大视口 —— 800×600 下线路条会被挤出可见区；
    /// 3. **滚过满屏 hero** —— 线路条在正文（第二屏），而正文是懒加载
    ///    `ListView`，不滚过去 `tmdb-line-selector` 根本没挂载，
    ///    `tester.widget<ChoiceChip>` 会抛 `Bad state: No element`。
    Future<void> pumpLineStrip(
      WidgetTester tester, {
      String historyFlag = '线路二',
      String historyEpisodeId = 'http://y/e1',
    }) async {
      tester.view.physicalSize = const Size(1400, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: appState,
            vod: vod,
            historyFlag: historyFlag,
            historyEpisodeId: historyEpisodeId,
          ),
        ),
      );
      await tester.pump();
      appState.seedDetailForTest(vod: vod);
      await tester.pump();
      for (var attempt = 0; attempt < 20; attempt++) {
        if (find
            .byKey(const ValueKey('tmdb-line-selector'))
            .evaluate()
            .isNotEmpty) {
          return;
        }
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await tester.pump();
      }
    }

    testWidgets('历史线路的 chip 上有标记，其他线路没有', (tester) async {
      await pumpLineStrip(tester);

      expect(
        find.byKey(const ValueKey('tmdb-line-recent-线路二')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tmdb-line-recent-线路一')),
        findsNothing,
      );
    });

    testWidgets('标记不改变 chip 仍可点击切换', (tester) async {
      await pumpLineStrip(tester);

      await tester.tap(find.byKey(const ValueKey('tmdb-line-线路一')));
      await tester.pumpAndSettle();

      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(chip.selected, isTrue, reason: '用户手动切走必须生效');
      expect(
        find.byKey(const ValueKey('tmdb-line-recent-线路二')),
        findsOneWidget,
        reason: '切走后标记仍在，用户能切回来',
      );
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：FAIL，`Found 0 widgets with key [<'tmdb-line-recent-线路二'>]`。

- [ ] **Step 3: 写最小实现**

(a) `lib/ui/tmdb_detail_view.dart` 的 `TmdbLineSelector` 加参数：

```dart
  const TmdbLineSelector({
    super.key,
    required this.lines,
    required this.selectedFlag,
    this.episodeCounts = const {},
    this.onChanged,
    this.recentFlag = '',
  });

  /// 历史命中的线路 flag（空串 = 无标记）。
  ///
  /// 标记**不抢**选中态：用户手动切走线路后标记仍在，能切回来
  /// （`docs/phase6/design/02` §5）。
  final String recentFlag;
```

(b) 把 `ChoiceChip` 的 `label` 换成带标记的 Row：

```dart
                    ChoiceChip(
                      key: ValueKey('tmdb-line-${line.flag}'),
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (line.flag == recentFlag) ...[
                            Icon(
                              Icons.history,
                              key: ValueKey('tmdb-line-recent-${line.flag}'),
                              size: 14,
                            ),
                            // **必须用 `AppSpace.xs`（= 4），不要写字面量 `4`**：
                            // 绑定约束是「间距只用 `AppSpace`，不引入新散值」。
                            const SizedBox(width: AppSpace.xs),
                          ],
                          Text(
                            episodeCounts.containsKey(line.flag)
                                ? '${line.displayName}（${episodeCounts[line.flag]} 集）'
                                : line.displayName,
                          ),
                        ],
                      ),
                      selected: line.flag == selectedFlag,
                      onSelected: onChanged == null
                          ? null
                          : (_) => onChanged!.call(line),
                    ),
```

并在 `TmdbLineSelector` 的 build 里给该 chip 加 tooltip（用 `Tooltip` 包
`ChoiceChip`，`message: line.flag == recentFlag ? '最近播放' : line.displayName`）。
**注意**：`Tooltip` 的 `message` 是字符串，不产生 `Text` widget，安全。

(c) `lib/ui/browse_pages.dart` 里给 `TmdbLineSelector` 传 `recentFlag`：

```dart
                        TmdbLineSelector(
                          lines: lines,
                          selectedFlag: _activeLine(lines).flag,
                          recentFlag: _resumeTarget(lines).matched
                              ? _resumeTarget(lines).flag
                              : '',
                          episodeCounts: _episodeCountsByLine(lines),
                          onChanged: (line) => _selectLine(line, lines),
                        ),
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：`All tests passed!`（29 个用例：Task 1–4 的 26 + 本任务 3）。

> **为什么是 3 个而不是 2 个**：brief 原本只写 2 个用例，但实现阶段做**变异自检**
> 发现：去掉 `matched` 守卫（`recentFlag: _resumeTarget(lines).flag`）后，
> 那 2 个用例**全部照过**——因为它们都走 `matched == true`。
> 于是「`matched == false` 时不得标记」这条要求**一个钉子都没有**。
> 补的第 3 个用例（「历史线路在但那一集已消失 → 不标」）在变异下会失败。
>
> **教训（已第三次出现）**：用例要覆盖判据的**肯定面与否定面**。
> Task 3（`belongs` 守卫）、Task 4（点击目标）、Task 5（`matched` 守卫）
> 都是同一个模式：只写肯定路径 → 守卫的反实现照样全绿。

确认没打破线路 chip 的既有门禁：

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase4_tmdb_detail_view_test.dart
```

预期：全绿。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/tmdb_detail_view.dart lib/ui/browse_pages.dart test/phase6_detail_resume_test.dart
git commit -m "新增：线路 chip「最近播放」标记（design/02 §5）"
```

---

### Task 6: 选集卡片的「最近播放」标记

**Files:**
- Modify: `lib/ui/tmdb_detail_view.dart`（`TmdbEpisodeStrip` / `TmdbEpisodeCardTile`）
- Modify: `lib/ui/browse_pages.dart`（传入命中的集下标）
- Test: `test/phase6_detail_resume_test.dart`（追加）

**Interfaces:**
- Consumes: `_resumeTarget`（Task 3）
- Produces:
  - `TmdbEpisodeStrip({..., int recentIndex = -1})`
  - `TmdbEpisodeCardTile({..., bool isRecent = false})`；新增 `ValueKey('<keyPrefix>-recent-<index>')`

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_detail_resume_test.dart` 追加：

```dart
  group('选集卡片的「最近播放」标记（design/02 §6）', () {
    late Directory dir;
    late AppState appState;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-episode-recent');
      appState = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': dir.path, 'local': dir.path},
        ),
        log: LogService(),
      );
      await appState.bootstrap();
    });

    tearDown(() async {
      appState.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    final vod = Vod(
      vodId: 'demo-1',
      vodName: '剧集甲',
      vodPlayFrom: '线路一',
      vodPlayUrl: '第1集\$http://x/e1#第2集\$http://x/e2#第3集\$http://x/e3',
    );

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: appState,
            vod: vod,
            historyFlag: '线路一',
            historyEpisodeId: 'http://x/e2',
          ),
        ),
      );
      await tester.pump();
      // **必须注入「本页详情已到达」**：否则 `state.detailResult` 为 null、
      // `belongs` 恒为 false，走的不是 `design/02` §4 描述的路径
      // （与 Task 4/5 同一要求）。
      appState.seedDetailForTest(vod: vod);
      await tester.pump();
      // **滚过 hero，直到选集区挂载**。
      //
      // 用「找不到就继续拖」的循环而**不是**一次 `drag(-3000)`：
      // hero 是满屏的、正文是懒加载 `ListView`，一次固定位移的拖动在
      // 视口或 hero 高度变化时会拖不够（或拖过头），循环则与具体尺寸无关。
      // Task 3/5 用的是同一个模式。
      for (var attempt = 0; attempt < 20; attempt++) {
        if (find
            .byKey(const ValueKey('tmdb-episode-card-线路一-0'))
            .evaluate()
            .isNotEmpty) {
          return;
        }
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await tester.pump();
      }
    }

    testWidgets('命中的集卡片有标记，其他集没有', (tester) async {
      await pump(tester);
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-1')),
        findsOneWidget,
        reason: '第2集（下标 1）被标记',
      );
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-0')),
        findsNothing,
      );
    });

    testWidgets('外壳仍是 OutlinedButton（不补集门禁）', (tester) async {
      await pump(tester);
      final buttons = find.byWidgetPredicate(
        (widget) =>
            widget is OutlinedButton &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'tmdb-episode-card-线路一-',
            ),
      );
      expect(
        buttons,
        findsNWidgets(3),
        reason: '3 集就是 3 张卡，不得补集也不得丢集',
      );
    });

    // 第三条断言「剧照仍是 16:9」**不写**：见下方 Ruling。
  });
```

> **剧照 16:9 的断言不在本任务范围内——已删除，改为 parked 记录。**
>
> 原因（pre-flight 扫描时核实）：`TmdbEpisodeCardTile` 的剧照当前是
> `SizedBox(height: 110)`，**宽度随列宽变化**（150–300），因此它本来
> **就不是** 16:9 —— 这是 `DESIGN.md`「剧照 16:9」纪律的一处**既有偏差**，
> 与本轮「最近播放」标记无关。
>
> 修它需要同时改卡片高度（`mainAxisExtent`）与网格度量，否则会溢出；
> 而 `DESIGN.md` 的 Metric-Neutral Rule 明确警告净高度变化会把控件挤出
> 800×600 测试视口。因此：
>
> **Ruling**：本任务**不改卡片几何**，只加「最近播放」标记。
> 剧照比例偏差记入 ledger 作为 deferred minor，交最终整支审查裁定。
>
> 因此 Task 6 的测试只保留前两条（标记存在性 + `OutlinedButton` 不补集）。

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：FAIL，`Found 0 widgets with key [<'tmdb-episode-card-线路一-recent-1'>]`。

- [ ] **Step 3: 写最小实现**

(a) `TmdbEpisodeStrip` 加参数并透传：

```dart
  const TmdbEpisodeStrip({
    super.key,
    required this.cards,
    this.keyPrefix = 'tmdb-episode-card',
    this.actionLabel = '播放',
    this.onTap,
    this.cardWidth = 260,
    this.height = 196,
    this.gridMode = false,
    this.recentIndex = -1,
  });

  /// 「最近播放」的卡片下标（-1 = 无）。
  ///
  /// 注意是**渲染下标**：调用方已把线路原始下标换算过
  /// （`docs/phase6/design/02` §6）。
  final int recentIndex;
```

两处 `TmdbEpisodeCardTile(...)` 都加（**必须显式传 `recentKey`**：

```dart
            isRecent: index == recentIndex,
            recentKey: ValueKey('$keyPrefix-recent-$index'),
```

> **为什么用 `recentKey` 而不是从 `stillKey` 派生**：`stillKey` 是
> `'<keyPrefix>-still-<集号>'`，集号可能缺失或重复；测试按**渲染下标**
> 定位（`'<keyPrefix>-recent-<index>'`），下标才是稳定且唯一的。
> 派生 key 会让测试断言与实现不一致。

(b) `TmdbEpisodeCardTile` 加参数与视觉：

```dart
  const TmdbEpisodeCardTile({
    super.key,
    this.buttonKey,
    this.stillKey,
    this.recentKey,
    required this.card,
    this.actionLabel = '播放',
    this.onTap,
    this.isRecent = false,
  });

  /// 「最近播放」角标的 key。
  ///
  /// 与 [stillKey] 分开：角标的位置/存在性由**渲染下标**决定，
  /// 而 `stillKey` 用的是集号（可能缺失或重复）。
  final Key? recentKey;

  /// 是否是「最近播放」那一集（`docs/phase6/design/02` §6）。
  final bool isRecent;
```

把 `OutlinedButton.styleFrom(...)` 改为按 `isRecent` 加描边：

```dart
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          alignment: Alignment.centerLeft,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          side: isRecent
              ? BorderSide(color: theme.colorScheme.primary, width: 2)
              : null,
        ),
```

在剧照 `Stack` 里 `E<n>` 角标**之后**加「上次看到这里」角标：

```dart
                    if (isRecent)
                      Positioned(
                        left: 6,
                        bottom: 6,
                        child: Container(
                          key: recentKey,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.history,
                                size: 12,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '上次看到这里',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
```

(c) 在 `TmdbEpisodeStrip` 的卡片 key 上补 recent key。因为
`buttonKey` 必须留给 `OutlinedButton`（门禁要求），recent 标记用
**由渲染下标派生的 key**（`ValueKey('$keyPrefix-recent-$index')`）——
**不是**从剧照的 `stillKey` 派生。

> **为什么必须用渲染下标、不能用 `stillKey`**（本节原写「用 `stillKey` 派生」，
> 与 (a) 及测试断言矛盾，**是错的**）：`stillKey` 的形状是
> `'<keyPrefix>-still-<集号>'`，而集号可能缺失或重复；测试按
> `'<keyPrefix>-recent-<渲染下标>'` 定位，下标才是稳定唯一的。
> 派生 key 会让测试断言与实现不一致。

在 `_buildEpisodes` 的调用处生成：

`lib/ui/browse_pages.dart` 的 `_buildEpisodes` 里，把 `TmdbEpisodeStrip(...)`
改为：

```dart
        TmdbEpisodeStrip(
          key: ValueKey('tmdb-episode-strip-${rawLine.flag}'),
          cards: tmdb.episodeCardsForEpisodes(
            ordered,
            seasonNumber: tmdb.selectedSeason >= 0 ? tmdb.selectedSeason : null,
            includeMetadata: true,
          ),
          keyPrefix: 'tmdb-episode-card-${rawLine.flag}',
          actionLabel: '播放',
          cardWidth: _episodeCardWidth(context, episodes.length),
          gridMode: _episodeGridMode,
          recentIndex: _recentRenderedIndex(vod, rawLine, ordered),
          onTap: (index, _) =>
              _playEpisodeAt(vod, rawLine, line, ordered, index),
        ),
```

在 `_DetailPageState` 里加换算（**渲染下标 → 原始下标 → 再回渲染下标**）：

```dart
  /// 历史那一集在**渲染列表**里的下标（-1 = 无）。
  ///
  /// 走「原始下标 → 渲染下标」的换算：`resolveHistoryTarget` 给的是线路
  /// 原始下标，而卡片是按 `ordered`（已季度过滤 + 已倒序）渲染的。
  ///
  /// **只收三个参数**：原签名里的 `enrichedLine` 从未被用到（方法体只用
  /// `rawLine` 与 `ordered`），留着会触发「未使用的参数」这类噪音。
  int _recentRenderedIndex(
    Vod vod,
    VodPlayLine rawLine,
    List<VodEpisode> ordered,
  ) {
    final lines = widget.state.playLinesOf(vod);
    final target = _resumeTarget(lines);
    if (!target.matched) return -1;
    if (rawLine.flag != target.flag) return -1;
    if (target.episodeIndex < 0 ||
        target.episodeIndex >= rawLine.episodes.length) {
      return -1;
    }
    final episode = rawLine.episodes[target.episodeIndex];
    for (var i = 0; i < ordered.length; i++) {
      if (identical(ordered[i], episode) || ordered[i].url == episode.url) {
        return i;
      }
    }
    return -1;
  }
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_detail_resume_test.dart
```

预期：`All tests passed!`（33 个用例：Task 1–5 的 29 + 本任务 4）。

> **为什么是 4 个而不是 2 个**：brief 原本只写 2 个用例，但实现阶段的
> **变异自检**发现**两颗守卫都能存活**：
>
> | 变异 | 原 2 个用例的结果 | 补的钉子 |
> | --- | --- | --- |
> | **B**：删 `!target.matched` 守卫 | 全过 | 「历史线路在但那一集已消失 → 不标」 |
> | **B2**：删 `rawLine.flag != target.flag` 守卫 | 全过 | 「切到别的线路后不误标」（brief 未提到） |
>
> B2 是 brief **没有预见**的缺口：切线路后，历史命中的 `flag` 与当前
> `rawLine.flag` 不再相等，若不守这一条，选集卡片会把「另一条线路的历史」
> 标到当前线路上。
>
> **教训（第四次出现）**：用例要覆盖判据的**每一个合取项**。
> Task 3（`belongs`）、Task 4（点击目标）、Task 5（`matched`）、
> Task 6（`matched` + `rawLine.flag`）都是同一模式。

确认没打破剧集卡门禁：

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase4_tmdb_detail_view_test.dart
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test integration_test/tmdb_detail_flow_test.dart -d windows
```

预期：全绿。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/tmdb_detail_view.dart lib/ui/browse_pages.dart test/phase6_detail_resume_test.dart
git commit -m "新增：选集卡片「最近播放」标记（design/02 §6）"
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

- [ ] **确认三个回归门禁**

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test `
  test/phase3_detail_page_test.dart `
  test/phase4_tmdb_ui_test.dart `
  test/phase4_tmdb_detail_view_test.dart
```

预期：全绿（`detail-hero-play` key 仍在、线路 chip 仍是 `ChoiceChip`、
选集卡仍是 `OutlinedButton`）。

- [ ] **产出证据（`design/05` §6）**

| 文件 | 内容 |
| --- | --- |
| `docs/phase6/evidence/detail-resume-button.png` | 详情页首屏「继续播放 · <集名>」 |
| `docs/phase6/evidence/detail-recent-highlight.png` | 线路 chip 与选集卡片的「最近播放」标记 |

截图由集成测试的 `RepaintBoundary → toImage → PNG` harness 产出。

```bash
git add docs/phase6/evidence/
git commit -m "证据：详情页续播按钮与最近播放高亮截图（design/05 §6）"
```
