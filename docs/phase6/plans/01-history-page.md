# 历史记录页（卡片网格 + 两种删除模式 + 点击行为设置）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把历史记录页从单列 `ListTile` 改成海报网格卡片，并加上「长按进删除态（点谁删谁）」与「新增按钮进多选批量删除」两种删除模式，同时新增「点击进详情页 / 直接播放」的设置开关。

**Architecture:** 删除模式的状态机与点击行为归一化抽成**纯逻辑**模块 `lib/core/history_view.dart`（不依赖 Flutter），先用 L1 单测锁死语义，再让 `HistoryPage` 只做渲染与事件转发。设置项复用 `UiPreferencesStore` 既有的「缺席 = 默认、只有显式选过才写盘」模式。

**Tech Stack:** Flutter 3.47 / Dart 3.13、`flutter_test`、SQLite（`sqlite3` 包）、Material 3。

**Spec:** `docs/phase6/design/01-history-page-and-delete-modes.md`（配套 `00` 总索引 §3.1、§4）

## 前置依赖

| 依赖 | 来自 | 为什么 |
| --- | --- | --- |
| `DetailPage` 的 `historyFlag` / `historyEpisodeId` | **计划 2 Task 3** | Task 8 的「点击进详情页」要传这两个参数 |

**执行顺序**：计划 2 Task 3 → 本计划的 Task 8。其余任务（Task 1–7）无外部依赖，
可先做。

## Global Constraints

- 平台：Windows 优先，Flutter 桌面。
- 字重只用 400 / 700，**禁止 `w500` / `w600`**（微软雅黑无真 Medium，会走合成加粗）。
- **禁止改动 Material 3 的字号与行高**：任何净高度变化会把控件挤出 800×600 测试视口，让不带 `ensureVisible` 的 `tester.tap` 打空。
- 圆角只用 `AppRadius`（6/10/14/999）；间距只用 `AppSpace`（4/8/12/16/24/32/48）；**不引入新的散值**。
- 不使用阴影、不使用 `surfaceTint`；全站 `elevation: 0`。
- 不用中性灰；颜色从 `Theme.of(context).colorScheme` 或 `context.semanticColors` 取，**不写死十六进制**。
- 海报比例固定 **2:3**。
- 每张历史卡片**只渲染一次**片名 `Text`（`integration_test/phase5_sync_flow_test.dart` 按 `find.text(name)` 断言 `findsOneWidget`）。
- 「清空历史」按钮文案**不得改动**（`integration_test/mvp_a_flow_test.dart` 按 `find.text('清空历史')` 断言）。
- 批量删除必须**逐条**调 `AppState.deleteHistory(id)`，**不得**新增批量 SQL 删除路径（否则漏写 `history_deletions` 标记，安卓下次推来旧记录会复活）。
- **widget 测试的前置条件**（plans/02 的教训，同一类缺陷出现过 5 次）：  - `HistoryPage` **没有**满屏 hero，列表紧接搜索行，且测试视口充裕
    （1200×1600 / 1400×1000）、条目数少（3–5 条）→ **本计划不需要滚动**。
  - 但**若**你把列表改到视口外（例如加了高区块），必须补
    「找不到就继续拖」的循环（见 `phase3_detail_page_test.dart` 的 `scrollPastHero`）。
  - 需要注入假数据时用既有 `seedListingForTest` / `seedDetailForTest`
    （`app_state.dart`），**不要**靠真实网络。
- **「默认选中 X」型断言的普遍盲区**（Task 4 的变异自检发现，对 Task 5–8 同样适用）：
  **默认值断言无法区分「读 AppState 的默认值」与「硬编码常量」** ——
  在一个新 state 上，两种实现的观察结果完全相同。
  因此凡「默认选中 X / 默认是某模式」的用例，必须**再加一条**：
  先用 `tester.runAsync` 把偏好改成**非默认值**，再 pump 页面，断言反映的是**那个值**。
  否则「用户改过设置、重启后回到默认」这类回归无人拦截。
- 测试命令（本机 Flutter 不在 PATH，需用绝对路径；并须清掉损坏的 git 环境变量）：

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_view_test.dart
```

---

## File Structure

| 文件 | 职责 | 动作 |
| --- | --- | --- |
| `lib/core/history_view.dart` | 删除模式状态机 + 点击行为归一化（纯逻辑，不依赖 Flutter） | **创建或追加**（见下） |
| `lib/services/ui_preferences_store.dart` | 新增 `historyClickAction` 的读 / 写 / 落盘 | 修改 |
| `lib/state/app_state.dart` | 暴露 `historyClickAction` 与 setter | 修改 |
| `lib/ui/diagnostics_pages.dart` | 设置页新增「历史记录」区块 | 修改 |
| `lib/ui/library_pages.dart` | `HistoryPage` 改网格卡片 + 两种删除模式 + 点击分流 | 修改 |
| `test/phase6_history_view_test.dart` | 状态机与归一化的 L1 测试 | 创建 |
| `test/phase6_history_page_test.dart` | 历史页交互的 L2 测试 | 创建 |

---

### Task 1: 删除模式状态机与点击行为归一化（纯逻辑）

**Files:**
- Create or append: `lib/core/history_view.dart`
- Test: `test/phase6_history_view_test.dart`

> **文件归属**：`lib/core/history_view.dart` 由**本任务与 plans/02 Task 1 共用**——
> 本任务写「删除模式状态机 + 点击行为归一化」，plans/02 Task 1 写「历史解析 + 按钮文案」。
> 两份计划都**追加**到同一文件，因此执行先后顺序不影响结果：
> - 文件不存在 → 创建它（并写本任务的内容）；
> - 文件已存在（plans/02 先执行过）→ **只在 import 区补 `library;` 之后的声明、在末尾追加**，
>   不要改动 plans/02 已写入的 `HistoryResumeTarget` / `resolveHistoryTarget` 等。
>
> 相应地，Step 2 的 RED 预期分两种：
> - 文件不存在 → `Target of URI doesn't exist: 'package:webhtv_pc/core/history_view.dart'`
> - 文件已存在 → `Undefined name 'HistoryViewState'` / `Undefined name 'HistoryViewMode'`
>
> 两种都算 RED 成立。

**Interfaces:**
- Consumes: 无（纯逻辑，零依赖）
- Produces:
  - `enum HistoryViewMode { none, singleDelete, multiSelect }`
  - `class HistoryViewState`，字段 `mode`、`selectedIds`（`Set<int>`）、`keyword`（`String`）
  - `HistoryViewState.initial`（静态常量：`none` / 空集 / 空串）
  - 方法：`enterSingleDelete()`、`enterMultiSelect()`、`exitMode()`、`toggleSelection(int id)`、`selectAll(List<int> visibleIds)`、`clearSelection()`、`withKeyword(String next)`，全部返回 `HistoryViewState`
  - 只读属性：`canDeleteSelected`（`bool`）、`selectedInOrder`（`List<int>`，升序）
  - `abstract final class UiHistoryClickAction`：常量 `detail` / `play`、`values`、`normalize(String?)`

- [ ] **Step 1: 写失败的测试**

创建 `test/phase6_history_view_test.dart`：

```dart
/// 历史页删除模式状态机与点击行为归一化（`docs/phase6/design/01` §3.4、§4）。
///
/// 纯逻辑，无 Flutter 依赖：这些语义（"长按进删除态后点谁删谁"、
/// "多选态点卡片只勾选"）是本轮最容易写错的地方，必须在无窗口环境下锁死。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/history_view.dart';

void main() {
  group('删除模式状态机', () {
    test('初始态是 none，无选中', () {
      expect(HistoryViewState.initial.mode, HistoryViewMode.none);
      expect(HistoryViewState.initial.selectedIds, isEmpty);
      expect(HistoryViewState.initial.canDeleteSelected, isFalse);
    });

    test('长按进删除态：singleDelete 且无选中集', () {
      final next = HistoryViewState.initial.enterSingleDelete();
      expect(next.mode, HistoryViewMode.singleDelete);
      expect(next.selectedIds, isEmpty, reason: '删除态没有"选中集"概念');
    });

    test('进多选态：清空已有选中', () {
      final dirty = HistoryViewState.initial
          .enterMultiSelect()
          .toggleSelection(7);
      final next = dirty.enterMultiSelect();
      expect(next.mode, HistoryViewMode.multiSelect);
      expect(next.selectedIds, isEmpty);
    });

    test('多选态点卡片只切换勾选，不删除', () {
      var state = HistoryViewState.initial.enterMultiSelect();
      state = state.toggleSelection(3);
      expect(state.selectedIds, {3});
      state = state.toggleSelection(3);
      expect(state.selectedIds, isEmpty, reason: '再点一次取消勾选');
    });

    test('singleDelete 下 toggleSelection 不产生选中', () {
      final state = HistoryViewState.initial
          .enterSingleDelete()
          .toggleSelection(5);
      expect(state.selectedIds, isEmpty);
    });

    test('全选只勾选传入的可见 id', () {
      final state = HistoryViewState.initial
          .enterMultiSelect()
          .selectAll(const [4, 9, 2]);
      expect(state.selectedIds, {2, 4, 9});
      expect(state.selectedInOrder, [2, 4, 9], reason: '稳定升序，便于断言');
    });

    test('退出模式清空选中，保留 keyword', () {
      final state = HistoryViewState.initial
          .withKeyword('剧名')
          .enterMultiSelect()
          .toggleSelection(1)
          .exitMode();
      expect(state.mode, HistoryViewMode.none);
      expect(state.selectedIds, isEmpty);
      expect(state.keyword, '剧名');
    });

    test('canDeleteSelected 仅多选态且有选中时为真', () {
      expect(HistoryViewState.initial.enterMultiSelect().canDeleteSelected, isFalse);
      expect(
        HistoryViewState.initial.enterMultiSelect().toggleSelection(1).canDeleteSelected,
        isTrue,
      );
      expect(
        HistoryViewState.initial.enterSingleDelete().toggleSelection(1).canDeleteSelected,
        isFalse,
      );
    });
  });

  group('搜索词变化（§3.4）', () {
    test('搜索词未变化时返回同一实例，不清空选中', () {
      final state = HistoryViewState.initial
          .withKeyword('剧名')
          .enterMultiSelect()
          .toggleSelection(8);
      final next = state.withKeyword('剧名');
      expect(identical(next, state), isTrue, reason: '否则每次 setState 都会清空勾选');
      expect(next.selectedIds, {8});
    });

    test('搜索词变化时清空选中', () {
      final state = HistoryViewState.initial
          .withKeyword('剧名')
          .enterMultiSelect()
          .toggleSelection(8);
      final next = state.withKeyword('另一部');
      expect(next.selectedIds, isEmpty);
      expect(next.keyword, '另一部');
    });

    test('搜索词变化不退出 singleDelete', () {
      final state = HistoryViewState.initial
          .withKeyword('剧名')
          .enterSingleDelete()
          .withKeyword('另一部');
      expect(state.mode, HistoryViewMode.singleDelete,
          reason: '删除态下点卡片即删，退出反而打断连续删除');
    });
  });

  group('点击行为归一化', () {
    test('合法值原样返回', () {
      expect(UiHistoryClickAction.normalize('detail'), UiHistoryClickAction.detail);
      expect(UiHistoryClickAction.normalize('play'), UiHistoryClickAction.play);
    });

    test('非法值与空值回落 detail（默认进详情页）', () {
      expect(UiHistoryClickAction.normalize(null), UiHistoryClickAction.detail);
      expect(UiHistoryClickAction.normalize(''), UiHistoryClickAction.detail);
      expect(UiHistoryClickAction.normalize('DETAIL'), UiHistoryClickAction.detail);
      expect(UiHistoryClickAction.normalize('play '), UiHistoryClickAction.play);
      expect(UiHistoryClickAction.normalize('nonsense'), UiHistoryClickAction.detail);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_view_test.dart
```

预期：编译失败。文件不存在时是
`Target of URI doesn't exist: 'package:webhtv_pc/core/history_view.dart'`；
文件已存在（plans/02 先执行过）时是 `Undefined name 'HistoryViewState'`。
两者都算 RED 成立。

- [ ] **Step 3: 写最小实现**

创建（或追加到）`lib/core/history_view.dart`：

> **追加时**：文件已有 `library;`（第 9 行）与 `import 'protocol.dart';`（第 11 行），
> 以及 plans/02 写入的历史解析代码。你只需把下面的
> `enum HistoryViewMode` / `class HistoryViewState` /
> `abstract final class UiHistoryClickAction` 三块**追加到文件末尾**。
>
> **⚠️ 必须去掉代码块开头的那三行**：
>
> ```dart
> /// 历史页的视图语义（…）   ← 删掉（文件头已有模块说明）
> /// …                        ← 删掉
> library;                    ← **必须删掉**
> ```
>
> 原因（实测）：`library;` 指令**必须出现在所有其他指令之前**。
> 文件第 11 行已有 `import 'protocol.dart';`，把带 `library;` 的块追加到末尾
> 会产生**第二个** `library;` 且位于 import 之后，编译直接失败：
>
> ```
> error - The library directive must appear before all other directives.
>         - lib/core/history_view.dart - library_directive_not_first
> ```
>
> 也不要重复写 `library;` 或改动 import 区。
> **不要**动 `HistoryResumeTarget` / `resolveHistoryTarget` / `_episodeIndexOf` / `_indexOfUrl`。

```dart
/// 历史页的三种模式。
enum HistoryViewMode {
  /// 默认：点卡片按「点击行为」设置分流。
  none,

  /// 长按进入的删除态：点卡片即删该条（对齐上游 `HistoryAdapter#setDelete`）。
  singleDelete,

  /// 「批量删除」按钮进入的多选态：点卡片切换勾选。
  multiSelect,
}

/// 不可变的历史页视图状态。
class HistoryViewState {
  const HistoryViewState({
    required this.mode,
    required this.selectedIds,
    required this.keyword,
  });

  /// 初始态。
  static const HistoryViewState initial = HistoryViewState(
    mode: HistoryViewMode.none,
    selectedIds: <int>{},
    keyword: '',
  );

  final HistoryViewMode mode;

  /// 已勾选的历史记录 id。仅 [HistoryViewMode.multiSelect] 有意义。
  final Set<int> selectedIds;

  /// **上一次已知的**搜索词。
  ///
  /// 它同时是 [withKeyword] 的比较基准：**任何**转移都不得重置它，
  /// 否则基准漂移会导致每次 `setState` 都清空用户的勾选。
  final String keyword;

  HistoryViewState copyWith({
    HistoryViewMode? mode,
    Set<int>? selectedIds,
    String? keyword,
  }) => HistoryViewState(
    mode: mode ?? this.mode,
    selectedIds: selectedIds ?? this.selectedIds,
    keyword: keyword ?? this.keyword,
  );

  /// 进入删除态（长按）。清空选中集——删除态没有"选中集"概念。
  HistoryViewState enterSingleDelete() =>
      copyWith(mode: HistoryViewMode.singleDelete, selectedIds: const <int>{});

  /// 进入多选态（批量删除按钮）。清空选中集，避免带上上一次的残留。
  HistoryViewState enterMultiSelect() =>
      copyWith(mode: HistoryViewMode.multiSelect, selectedIds: const <int>{});

  /// 退出到默认态。保留 [keyword]。
  HistoryViewState exitMode() =>
      copyWith(mode: HistoryViewMode.none, selectedIds: const <int>{});

  /// 切换某条记录的勾选。非多选态下**不产生**选中。
  HistoryViewState toggleSelection(int id) {
    if (mode != HistoryViewMode.multiSelect) return this;
    final next = <int>{...selectedIds};
    if (!next.remove(id)) next.add(id);
    return copyWith(selectedIds: next);
  }

  /// 全选：只勾选传入的**可见** id，不动已有的其他勾选。
  HistoryViewState selectAll(List<int> visibleIds) {
    if (mode != HistoryViewMode.multiSelect) return this;
    return copyWith(selectedIds: {...selectedIds, ...visibleIds});
  }

  /// 清空勾选。
  HistoryViewState clearSelection() =>
      copyWith(selectedIds: const <int>{});

  /// 更新搜索词。**变化时清空勾选**，未变化时返回同一实例。
  ///
  /// 为什么变化时必须清空：用户可能在多选态下搜索缩小范围，此时已勾选但
  /// **已不可见**的条目若仍留在 [selectedIds] 里，点「删除选中(N)」会删掉
  /// 用户看不见的条目。
  ///
  /// 为什么未变化时必须返回 `this`：调用方在 `setState` 里无条件调它，
  /// 每次都返回新实例会让用户刚勾的项被清空。
  HistoryViewState withKeyword(String next) {
    if (next == keyword) return this;
    return copyWith(keyword: next, selectedIds: const <int>{});
  }

  /// 是否可以执行批量删除。
  bool get canDeleteSelected =>
      mode == HistoryViewMode.multiSelect && selectedIds.isNotEmpty;

  /// 已勾选的 id，**升序**。稳定顺序便于测试断言与"全选"的幂等性。
  List<int> get selectedInOrder => selectedIds.toList()..sort();
}

/// 「点击历史记录」的行为（`docs/phase6/design/01` §4.1）。
///
/// 存字符串而不是 enum：本层是纯逻辑层，且要与 `settings.json` 的
/// 字面值一一对应（与 `UiThemeMode` 同样的分层理由）。
abstract final class UiHistoryClickAction {
  /// 打开该条对应的详情页（默认）。
  static const String detail = 'detail';

  /// 直接续播（既有行为）。
  static const String play = 'play';

  static const List<String> values = [detail, play];

  /// 把任意输入归一化成合法值；不认识的值回落到默认 [detail]。
  static String normalize(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    return values.contains(value) ? value : detail;
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_view_test.dart
```

预期：`All tests passed!`（20 个用例：brief 13 + 变异自检补的 7 个钉子）。

> **为什么是 20 而不是 13**（实现后回填）：**变异自检**跑了 17 个变异，发现 brief 自带的
> 13 个用例有 **7 处覆盖缺口**（brief 点名担心的三个变异都被杀死了，
> 但它未点名处有 7 个存活），包括 **`clearSelection()` 从未被执行过**、
> `selectAll` 的两个契约都没锁住、`canDeleteSelected` 只锁了选中集维没锁模式维、
> `normalize` 只喂了「已是小写」的输入。补钉后 **17/17 变异全杀**。
> 实现与 brief **逐字一致、未多加一行**。

- [ ] **Step 5: 提交**

```bash
git add lib/core/history_view.dart test/phase6_history_view_test.dart
git commit -m "新增：历史页删除模式状态机与点击行为归一化（design/01 §3.4、§4）"
```

---

### Task 2: 设置项持久化（`historyClickAction`）

**Files:**
- Modify: `lib/services/ui_preferences_store.dart`
- Test: `test/phase6_history_view_test.dart`（追加一个 group）

**Interfaces:**
- Consumes: `UiHistoryClickAction.normalize`（Task 1）
- Produces:
  - `UiPreferencesStore.historyClickAction`（`String` getter，返回归一化后的生效值）
  - `UiPreferencesStore.hasExplicitHistoryClickAction`（`bool` getter）
  - `UiPreferencesStore.rememberHistoryClickAction(String mode)` → `Future<bool>`

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_history_view_test.dart` 的 `main()` 末尾（最后一个 `}` 之前）追加：

```dart
  group('historyClickAction 持久化（settings.json 的 ui 段）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-history-click');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    UiPreferencesStore storeOf() =>
        UiPreferencesStore(path: p.join(dir.path, 'settings.json'));

    test('默认是 detail（缺席 = 默认，不写盘）', () async {
      final store = storeOf();
      await store.load();
      expect(store.historyClickAction, UiHistoryClickAction.detail);
      expect(store.hasExplicitHistoryClickAction, isFalse);
    });

    test('显式选择后落盘，重新 load 仍读到', () async {
      final store = storeOf();
      await store.load();
      await store.rememberHistoryClickAction(UiHistoryClickAction.play);

      final again = storeOf();
      await again.load();
      expect(again.historyClickAction, UiHistoryClickAction.play);
      expect(again.hasExplicitHistoryClickAction, isTrue);
    });

    test('非法值归一到 detail', () async {
      final store = storeOf();
      await store.load();
      await store.rememberHistoryClickAction('nonsense');
      expect(store.historyClickAction, UiHistoryClickAction.detail);
    });

    test('手改文件塞非法值时回落默认', () async {
      final file = File(p.join(dir.path, 'settings.json'));
      await file.writeAsString('{"ui":{"historyClickAction":"bogus"}}');
      final store = storeOf();
      await store.load();
      expect(store.historyClickAction, UiHistoryClickAction.detail);
    });

    test('不污染 ui 段的既有键（themeMode / searchKeywords 保留）', () async {
      final file = File(p.join(dir.path, 'settings.json'));
      await file.writeAsString(
        '{"ui":{"themeMode":"light","searchKeywords":["旧词"]},'
        '"tmdb":{"enabled":true},"sync":{"serverEnabled":true}}',
      );
      final store = storeOf();
      await store.load();
      await store.rememberHistoryClickAction(UiHistoryClickAction.play);

      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      final ui = raw['ui']! as Map<String, Object?>;
      expect(ui['themeMode'], 'light');
      expect(ui['searchKeywords'], ['旧词']);
      expect(ui['historyClickAction'], UiHistoryClickAction.play);
      expect(raw.containsKey('tmdb'), isTrue, reason: '不得覆盖其他段');
      expect(raw.containsKey('sync'), isTrue, reason: '不得覆盖其他段');
    });
  });
```

在文件顶部的 import 区加上：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/ui_preferences_store.dart';
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_view_test.dart
```

预期：编译失败，`The getter 'historyClickAction' isn't defined for the class 'UiPreferencesStore'`。

- [ ] **Step 3: 写最小实现**

在 `lib/services/ui_preferences_store.dart` 中：

(a) 文件头注释的「当前保存」列表末尾追加一行：

```dart
/// - `historyClickAction`：**点击历史记录的行为**（`detail` 进详情页 /
///   `play` 直接播放，上游 `HistoryActivity#onItemClick` 是直接播放，
///   PC 端默认改为进详情页，见 `docs/phase6/design/01` §4.1）。
```

(b) 在 `_searchThread` 字段之后加字段：

```dart
  /// 点击历史记录的行为。`null` = 从未设置过，用默认 [UiHistoryClickAction.detail]。
  String? _historyClickAction;
```

(c) 在 `hasExplicitSearchThread` getter 之后加 getter：

```dart
  /// 生效的点击历史行为：用户选过就用选的，否则默认进详情页。
  String get historyClickAction =>
      UiHistoryClickAction.normalize(_historyClickAction);

  /// 用户是否显式设置过（决定要不要写盘，与 `themeMode` 同理）。
  bool get hasExplicitHistoryClickAction => _historyClickAction != null;
```

(d) 在 `load()` 里 `searchThread` 的读取块之后加：

```dart
          final clickAction = ui['historyClickAction'];
          if (clickAction is String) {
            // 只接受合法值；手改成别的字符串时回落到默认，不写坏状态。
            if (UiHistoryClickAction.values.contains(
              clickAction.trim().toLowerCase(),
            )) {
              _historyClickAction = clickAction.trim().toLowerCase();
            }
          }
```

(e) 在 `rememberSearchThread` 方法之后加：

```dart
  /// 记住点击历史记录的行为。非法值归一化为默认。
  Future<bool> rememberHistoryClickAction(String mode) {
    final normalized = UiHistoryClickAction.normalize(mode);
    if (normalized == _historyClickAction) return Future.value(true);
    _historyClickAction = normalized;
    return _persist();
  }
```

(f) 在 `_doPersist()` 里 `searchThread` 的写入块之后加：

```dart
      // 点击行为同上：只有显式设置过才写，缺席 = 默认 detail。
      final clickAction = _historyClickAction;
      if (clickAction != null) ui['historyClickAction'] = clickAction;
```

(g) 在文件顶部 import 区加：

```dart
import '../core/history_view.dart';
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_view_test.dart
```

预期：`All tests passed!`（28 个用例：Task 1 的 20 + 本任务 brief 5 + 变异自检补的 3 个钉子）。

> **为什么是 28**（实现后回填）：brief 原文写「18」，它假设 Task 1 结束在 13 个用例——
> 实际 Task 1 因变异自检补到 **20**。本任务再做变异自检，又发现 **2 个存活变异**
> （**M4**：`load()` 不校验非法值；**M5**：无条件把默认值写盘），各补 1 个钉子。
> 故 20 + 5 + 3 = 28。

> **另一处 brief 事实性错误**（实现者报出）：brief 说「预期 18 个用例」，
> 实际动手前该文件已有 20 个。以**实际代码**为准。

再跑一次既有的偏好测试，确认没打破它：

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase2_last_site_test.dart
```

预期：`All tests passed!`。

- [ ] **Step 5: 提交**

```bash
git add lib/services/ui_preferences_store.dart test/phase6_history_view_test.dart
git commit -m "新增：historyClickAction 偏好持久化（design/01 §4.2）"
```

---

### Task 3: `AppState` 暴露点击行为

**Files:**
- Modify: `lib/state/app_state.dart`
- Test: `test/phase6_history_view_test.dart`（追加一个 group）

**Interfaces:**
- Consumes: `UiPreferencesStore.historyClickAction` / `rememberHistoryClickAction`（Task 2）
- Produces:
  - `AppState.historyClickAction`（`String` getter）
  - `AppState.setHistoryClickAction(String mode)` → `Future<bool>`

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_history_view_test.dart` 的 `main()` 末尾追加：

```dart
  group('AppState 暴露点击行为', () {
    late Directory dir;
    late AppState state;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-history-action');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': dir.path, 'local': dir.path},
        ),
        log: LogService(),
      );
      await state.bootstrap();
    });

    tearDown(() async {
      state.dispose();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('未 bootstrap 的默认值是 detail', () {
      final fresh = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': dir.path, 'local': dir.path},
        ),
        log: LogService(),
      );
      expect(fresh.historyClickAction, UiHistoryClickAction.detail);
      fresh.dispose();
    });

    test('设置后 getter 立刻反映（不依赖写盘成功）', () async {
      await state.setHistoryClickAction(UiHistoryClickAction.play);
      expect(state.historyClickAction, UiHistoryClickAction.play);
    });

    test('设置会通知监听者', () async {
      var notified = 0;
      state.addListener(() => notified++);
      await state.setHistoryClickAction(UiHistoryClickAction.play);
      expect(notified, greaterThan(0));
    });
  });
```

顶部 import 追加：

```dart
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_view_test.dart
```

预期：编译失败，`The getter 'historyClickAction' isn't defined for the class 'AppState'`。

- [ ] **Step 3: 写最小实现**

在 `lib/state/app_state.dart` 中，紧接 `setThemeMode` 方法之后加：

```dart
  /// 点击历史记录的行为（`docs/phase6/design/01` §4）。
  ///
  /// `_uiPreferences` 为 null（未 bootstrap）时退回默认 `detail`，
  /// 不让历史页因偏好未装配而崩。
  String get historyClickAction =>
      _uiPreferences?.historyClickAction ?? UiHistoryClickAction.detail;

  /// 持久化点击历史行为。
  ///
  /// 与 [setThemeMode] 同构：写盘失败不影响当前会话（内存里已生效），
  /// 但无论如何都通知 UI 重建。
  Future<bool> setHistoryClickAction(String mode) async {
    final store = _uiPreferences;
    if (store == null) return false;
    final ok = await store.rememberHistoryClickAction(mode);
    notifyListeners();
    return ok;
  }
```

并在 `app_state.dart` 顶部 import 区确认存在（若缺则加）：

```dart
import '../core/history_view.dart';
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_view_test.dart
```

预期：`All tests passed!`（35 个用例：Task 1–2 的 28 + 本任务 brief 3 + 变异自检补的 4 个钉子）。

> **为什么是 35 而不是 21**（实现后回填）：brief 原文写「21」，它假设 Task 1 结束在 13——
> 实际 Task 1 补到 20、Task 2 补到 28。本任务再做变异自检，发现 **1 个存活变异**：
> **D**：把 `notifyListeners()` 挪到 `await` **之前** → 监听者收到通知时读到的是**旧值**，
> UI 会用旧模式重建且不再刷新。已补钉子「通知发出时 getter 已是新值」。
> 故 28 + 3 + 4 = 35。

> **brief 的另一处事实性错误**（实现者报出）：brief 的落盘用例假设 settings 在
> `<dir>/settings.json`，实测在 `<dir>/webhtv-pc/settings.json`
> （`configDir = p.join(roaming, appName)`）。应以
> `AppPaths.resolve(...).settingsPath` 取真实路径，**不要写死路径假设**。

> **一条值得后续注意的盲区**（实现者报出）：brief 的原始用例只**数通知次数**，
> 不校验**回调里读到的值**——所以「通知时机」错了也测不出来。
> 既有测试对 `themeMode` 等其它偏好转发有**同样的盲区**。
> 记入 ledger，交最终审查决定是否统一加固。

- [ ] **Step 5: 提交**

```bash
git add lib/state/app_state.dart test/phase6_history_view_test.dart
git commit -m "新增：AppState 暴露点击历史行为偏好（design/01 §4.2）"
```

---

### Task 4: 设置页新增「历史记录」区块

**Files:**
- Modify: `lib/ui/diagnostics_pages.dart`（在「外观」区块与「搜索」区块之间插入）
- Test: `test/phase6_history_page_test.dart`（新建）

**Interfaces:**
- Consumes: `AppState.historyClickAction` / `setHistoryClickAction`（Task 3）、`UiHistoryClickAction`（Task 1）
- Produces: 无新 API；新增 `ValueKey('settings-history-click-action')`

- [ ] **Step 1: 写失败的测试**

创建 `test/phase6_history_page_test.dart`：

```dart
/// 历史页与设置页的交互门禁（`docs/phase6/design/01` §4.3、§7）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-history-page');
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

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsPage(state: state))),
    );
    await tester.pump();
  }

  testWidgets('设置页有「历史记录」区块与两个选项', (tester) async {
    await pumpSettings(tester);
    expect(find.text('历史记录'), findsOneWidget);
    final selector = find.byKey(
      const ValueKey('settings-history-click-action'),
    );
    expect(selector, findsOneWidget);
    expect(find.text('进入详情页'), findsOneWidget);
    expect(find.text('直接播放'), findsOneWidget);
  });

  testWidgets('默认选中「进入详情页」', (tester) async {
    await pumpSettings(tester);
    final button = tester.widget<SegmentedButton<String>>(
      find.byKey(const ValueKey('settings-history-click-action')),
    );
    expect(button.selected, {UiHistoryClickAction.detail});
  });

  testWidgets('点「直接播放」写入偏好', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('直接播放'));
    await tester.pumpAndSettle();
    expect(state.historyClickAction, UiHistoryClickAction.play);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
```

预期：FAIL，`Expected: exactly one matching candidate` / `Actual: _TextWidgetFinder:<Found 0 widgets with text "历史记录">`。

- [ ] **Step 3: 写最小实现**

在 `lib/ui/diagnostics_pages.dart` 里，找到「外观」区块结尾的
`const Divider(height: 32),`（紧接在 `SegmentedButton<ThemeMode>` 的
`),` 之后、`// 搜索区块。` 注释之前），在 `const Divider(height: 32),`
**之后**插入：

```dart
        // 历史记录区块（`docs/phase6/design/01` §4.3）。
        //
        // 为什么放在设置页而不是历史页顶部：这是**一次定好、长期生效**的
        // 行为偏好，与主题、搜索线程同类；历史页顶部那排是每次操作的临时控件。
        Text('历史记录', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          key: const ValueKey('settings-history-click-action'),
          segments: const [
            ButtonSegment<String>(
              value: UiHistoryClickAction.detail,
              icon: Icon(Icons.article_outlined, size: 18),
              label: Text('进入详情页'),
            ),
            ButtonSegment<String>(
              value: UiHistoryClickAction.play,
              icon: Icon(Icons.play_arrow, size: 18),
              label: Text('直接播放'),
            ),
          ],
          selected: {state.historyClickAction},
          onSelectionChanged: (selection) {
            state.setHistoryClickAction(selection.first);
          },
        ),
        const SizedBox(height: 8),
        Text(
          '点击历史记录时的行为。长按卡片始终进入删除状态。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 32),
```

并在 `diagnostics_pages.dart` 顶部 import 区加：

```dart
import '../core/history_view.dart';
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
```

预期：`All tests passed!`（4 个用例：brief 3 + 变异自检补的 1 个钉子）。

> **为什么是 4 而不是 3**（实现后回填）：变异自检发现**变异 A 存活** ——
> 把初始选中项**硬编码**成 `UiHistoryClickAction.detail`（不读 `AppState`），
> brief 给的 3 个用例**全绿**。根因就是上面 Global Constraints 里那条盲区：
> 默认值断言区分不了「读默认值」与「硬编码默认值」。
> 补的钉子：先 `tester.runAsync` 把偏好写成 `play`，再 pump 页面，断言 `selected == {play}`。

再确认没打破设置页既有门禁：

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase5_sync_ui_test.dart
```

预期：`All tests passed!`。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/diagnostics_pages.dart test/phase6_history_page_test.dart
git commit -m "新增：设置页「历史记录」点击行为区块（design/01 §4.3）"
```

---

### Task 5: 历史页改海报网格卡片

**Files:**
- Modify: `lib/ui/library_pages.dart`（`_HistoryPageState.build` 的列表部分）
- Test: `test/phase6_history_page_test.dart`（追加）

**Interfaces:**
- Consumes: 既有 `AppState.recentHistory()` / `searchHistory()`、`PosterImage`、`PlaybackHistory`
- Produces: 无新 API；新增 `ValueKey('history-grid')`、`ValueKey('history-card-<id>')`；保留 `ValueKey('history-row-<id>')` 作为卡片外层 key 的别名不可行（一个 widget 一个 key），因此**卡片外层 key 沿用 `history-row-<id>`**

> **key 决策**：既有代码用 `ValueKey('history-row-${item.id}')` 挂在 `InkWell` 上。
> 本轮**保留这个字面值**（没有测试引用它，但改名无收益且增加 review 成本），
> 网格容器新增 `ValueKey('history-grid')`。

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_history_page_test.dart` 追加（并在 import 区加
`import 'package:webhtv_pc/ui/library_pages.dart';` 与
`import 'package:webhtv_pc/services/storage.dart';`）：

```dart
  /// 直接往库里塞一条历史，绕过播放器。
  void seedHistory({
    required int id,
    required String vodName,
    String episodeName = '第1集',
    String siteKey = 'site-a',
    String vodId = 'v1',
    String flag = '线路一',
    String episodeId = 'http://x/e1',
    int positionMs = 30000,
    int durationMs = 100000,
    int? updatedAt,
  }) {
    state.database!.upsertHistory(
      siteKey: siteKey,
      vodId: vodId,
      vodName: vodName,
      flag: flag,
      episodeName: episodeName,
      episodeId: episodeId,
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAt: updatedAt,
    );
  }

  Future<void> pumpHistory(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: HistoryPage(state: state))),
    );
    await tester.pump();
  }

  group('历史页卡片网格（design/01 §2）', () {
    testWidgets('渲染为网格，卡片数 == 历史条数', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲', updatedAt: 3000);
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 2000);
      seedHistory(id: 3, vodName: '剧集丙', updatedAt: 1000);
      await pumpHistory(tester);

      expect(find.byKey(const ValueKey('history-grid')), findsOneWidget);
      expect(find.byType(SliverGrid), findsWidgets);
      for (final name in const ['剧集甲', '剧集乙', '剧集丙']) {
        expect(find.text(name), findsOneWidget, reason: '$name 必须出现且只出现一次');
      }
    });

    testWidgets('每张卡片只渲染一次片名 Text', (tester) async {
      seedHistory(id: 1, vodName: '唯一片名');
      await pumpHistory(tester);
      expect(find.text('唯一片名'), findsOneWidget);
    });

    testWidgets('海报保持 2:3', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);
      final box = tester.getSize(
        find.descendant(
          of: find.byKey(const ValueKey('history-row-1')),
          matching: find.byType(AspectRatio),
        ).first,
      );
      expect(box.width / box.height, closeTo(2 / 3, 0.05));
    });

    testWidgets('空历史显示空态，不渲染网格', (tester) async {
      await pumpHistory(tester);
      expect(find.text('暂无播放记录'), findsOneWidget);
      expect(find.byKey(const ValueKey('history-grid')), findsNothing);
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
```

预期：FAIL，`Found 0 widgets with key [<'history-grid'>]`。

- [ ] **Step 3: 写最小实现**

在 `lib/ui/library_pages.dart` 中：

(a) 把 `Expanded(child: items.isEmpty ? ... : ListView.builder(...))` 整块
替换为下面的实现（`ListView.builder` 那一段全部删掉）：

```dart
        Expanded(
          child: items.isEmpty
              ? const EmptyState(
                  icon: Icons.history_outlined,
                  title: '暂无播放记录',
                  message: '播放任意剧集后会自动记录进度。',
                )
              // **必须用 `LayoutBuilder` 拿内容区宽度，不要用
              // `MediaQuery.sizeOf(context).width`**（`design/01` §2.2 第 2 条）：
              // 后者是**整窗宽**，而壳层有 76px 左栏 + 1px 分隔线，
              // 于是同一窗口下列数比首页海报墙**偏多约 0.5 列**，两处卡片大小不一致。
              // 首页用的就是 `LayoutBuilder(constraints.maxWidth)`
              // （`browse_pages.dart:623`、`:652`）。
              : LayoutBuilder(
                  builder: (context, constraints) => GridView.builder(
                    key: const ValueKey('history-grid'),
                    padding: const EdgeInsets.all(AppSpace.lg),
                    gridDelegate: _historyGridDelegate(constraints.maxWidth),
                    itemCount: items.length,
                    itemBuilder: (context, index) =>
                        _buildHistoryCard(context, items[index]),
                  ),
                ),
        ),
```

(b) 在 `_HistoryPageState` 类内（`_resume` 方法之前）加网格度量与卡片构造：

```dart
  /// 网格度量：与首页海报墙同一套算法（`browse_pages.dart#_gridDelegate`）。
  ///
  /// 为什么不用 `SliverGridDelegateWithMaxCrossAxisExtent`：它的
  /// `mainAxisExtent` 是固定值，窗口变窄时列宽变小、高度不变，海报会被
  /// 压成非 2:3 或被裁切。这里列宽已知，格子高度就能精确算成
  /// 「海报 2:3 + 文字区」。
  static SliverGridDelegate _historyGridDelegate(double maxWidth) {
    final usable = maxWidth - AppSpace.lg * 2;
    final columns = (usable / (_historyCardTargetWidth + _historyCardSpacing))
        .round()
        .clamp(2, 12);
    final cellWidth =
        (usable - (columns - 1) * _historyCardSpacing) / columns;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: _historyCardSpacing,
      mainAxisSpacing: AppSpace.sm,
      mainAxisExtent: cellWidth * 1.5 + AppSpace.sm + _historyCaptionHeight,
    );
  }

  /// 单张历史卡片（对齐上游 `res/layout/adapter_vod.xml`）。
  ///
  /// **片名只渲染一次 `Text`**：`phase5_sync_flow_test` 按
  /// `find.text(name)` 断言 `findsOneWidget`。
  Widget _buildHistoryCard(BuildContext context, PlaybackHistory item) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey('history-row-${item.id}'),
      onTap: () => _onCardTap(item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // `AspectRatio` 保证海报 2:3：文字区再高也不会把海报压变形。
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PosterImage(url: item.vodPic),
                  // 左下角进度角标（对齐上游 `@id/playback`）。
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: _HistoryBadge(
                      text: item.completed
                          ? '已看完'
                          : '已看 ${item.progressPercent}%',
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 2px 进度条紧贴海报下沿（对齐上游 `@id/progress`）。
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: LinearProgressIndicator(
              value: item.progress,
              minHeight: 2,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          // **必须夹住文字缩放**（`design/01` §2.2 第 3 条）：
          // caption 高度是**固定值**（`_historyCaptionHeight = 40`），不夹住时
          // 无障碍放大字号就会溢出格子。
          //
          // **光加 clamp 不够：字号/行高必须同时对齐首页 `_VodCard`**
          // （`fontSize: 13, height: 1.2` 与 `11 / 1.2`，而不是 M3 默认的 14/1.43
          // 与 12/1.33）。这是 1.25 能不能成立的**算术前提**：
          //   首页度量 13/1.2 + 11/1.2 → 本征 28.8px ×1.25 = 36.0px → 余 4px ✅
          //   M3 默认 14/1.43 + 12/1.33 → 本征 35.98px ×1.25 = 44.98px → 溢出 5px ❌
          // （后者已实测：clamp 1.25 + M3 默认度量在 textScale 1.5/2.0 下均溢出 5px。）
          // 两块海报墙要么度量与 clamp 都对齐，要么名义上复用、实际仍是两套尺度。
          //
          // 首页海报墙有同样的一层（`browse_pages.dart:836-839`，值同为 1.25），
          // 其注释写明理由：「放大字号（无障碍）时只缩不放：文字区高度是固定值，
          // 不夹住就会溢出格子」。**包文字区，不要包海报**。
          //
          // 去掉 clamp 时（首页度量）：textScale 1.5 溢出 3px、2.0 溢出 17px。
          Expanded(
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: _historyTextScaleMax,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    item.vodName,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13,
                      height: 1.2,
                    ),
                  ),
                  Text(
                    item.episodeName,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      height: 1.2,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
```

(c) 在 `library_pages.dart` 的顶层（`HistoryPage` 类之前）加常量：

```dart
/// 历史卡片的目标列宽（与首页海报墙同量级）。
const double _historyCardTargetWidth = 150;

/// 历史卡片列间距。
const double _historyCardSpacing = 14;

/// 历史卡片海报下方的文字区高度（片名 + 集名两行）。
const double _historyCaptionHeight = 40;

/// 文字区允许的**最大**放大倍数（无障碍字号只缩不放）。
///
/// 与首页 `_VodCard` 同值同理由：文字区是固定高度，放大时不让步就会溢出格子。
const double _historyTextScaleMax = 1.25;
```

> **`_historyGridPadding` 不新增**（实现时回填）：它与 `AppSpace.lg` 完全同值，
> 而 `library_pages.dart` 的既有代码本就用 `AppSpace`，再引入一个同义常量只是重复。
> 直接用 `AppSpace.lg`。

(d) 加进度角标组件（放在 `library_pages.dart` 顶层，`FavoritesPage` 之前）：

```dart
/// 海报左下角的小角标（对齐上游 `@id/playback` 的半透明底胶囊）。
class _HistoryBadge extends StatelessWidget {
  const _HistoryBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }
}
```

(e) 顶部 import 追加：

```dart
import 'tokens.dart';
```

(f) 临时加一个占位点击处理（Task 6/7/8 会替换它），放在 `_resume` 之前：

```dart
  /// 卡片点击（Task 8 会按设置分流；此处先保持既有行为）。
  void _onCardTap(PlaybackHistory item) => unawaited(_resume(item));
```

> 若 `library_pages.dart` 尚未 import `dart:async` 的 `unawaited`，文件顶部
> 已有 `import 'dart:async';`（第 4 行），无需新增。

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
```

预期：`All tests passed!`（12 个用例）。

> **计数回填（实现后）**：文件原有 4 个用例（Task 4 的「默认选中 X」组）→
> 本轮 +4（brief 给的 4 条）+3（变异自检补的钉子）= **12**。brief 写的「7」
> 与任何口径都对不上（4+4=8）。
>
> - 变异自检发现 **1 处真缺口**：把 `columns` 写死成 3 时，brief 给的 4 条
>   用例**全绿**（1400 宽下写死列数仍能给出精确 2:3 的海报，因为格子高度是按
>   `cellWidth` 算的）。补钉子「列数随窗口宽自适」应（1400→8 列、700→4 列）。
> - 首轮实现了 **`MediaQuery.sizeOf(context).width`**（brief 原文），
>   与 `design/01` §2.2 第 2 条冲突 → 修复轮改为
>   `LayoutBuilder(constraints.maxWidth)`，并补钉子「壳层下 1100 宽 → 6 列
>   而不是 7 列」（去掉 `LayoutBuilder` 时该用例如期转红）。
> - 首轮卡片**没有 clamp**（brief 原文）→ 修复轮补上，
>   并同时把字号/行高对齐首页（否则 1.25 仍溢出 5px，见上面 (b) 的注释）；
>   补 2 档钉子（textScale 1.5 / 2.0 不溢出）。
>
> 修复轮提交：`3ccef0b`。**首轮提交 `e93a2e6` 与修复轮 `3ccef0b`
> 应视为同一个 Task 5**（审阅时以 `3ccef0b` 为准）。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/library_pages.dart test/phase6_history_page_test.dart
git commit -m "新增：历史页改海报网格卡片（design/01 §2）"
```

---

### Task 6: 长按进入删除态（点谁删谁）

**Files:**
- Modify: `lib/ui/library_pages.dart`
- Test: `test/phase6_history_page_test.dart`（追加）

**Interfaces:**
- Consumes: `HistoryViewState` / `HistoryViewMode`（Task 1）
- Produces: 新增 `ValueKey('history-delete-done')`、`ValueKey('history-delete-overlay-<id>')`

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_history_page_test.dart` 追加：

```dart
  group('删除态（design/01 §3）', () {
    testWidgets('长按卡片进入删除态：出现遮罩与「完成」', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();

      expect(find.byKey(const ValueKey('history-delete-done')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('history-delete-overlay-1')),
        findsOneWidget,
      );
    });

    testWidgets('删除态下点卡片即删该条，仍在删除态', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.text('剧集甲'), findsNothing, reason: '该条被删除');
      expect(find.text('剧集乙'), findsOneWidget, reason: '另一条不受影响');
      expect(
        find.byKey(const ValueKey('history-delete-done')),
        findsOneWidget,
        reason: '还有条目时仍在删除态',
      );
      expect(state.recentHistory().length, 1, reason: '必须真的落盘');
    });

    testWidgets('删除态删掉最后一条后自动退出', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('暂无播放记录'), findsOneWidget);
    });

    testWidgets('点「完成」退出删除态且不删任何东西', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-delete-done')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('剧集甲'), findsOneWidget);
      expect(state.recentHistory().length, 1);
    });

    testWidgets('再次长按退出删除态', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('剧集甲'), findsOneWidget);
    });

    testWidgets('空历史时不渲染删除入口', (tester) async {
      await pumpHistory(tester);
      expect(find.byKey(const ValueKey('history-bulk-delete')), findsNothing);
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
```

预期：FAIL，`Found 0 widgets with key [<'history-delete-done'>]`。

- [ ] **Step 3: 写最小实现**

在 `lib/ui/library_pages.dart` 中：

(a) 给 `_HistoryPageState` 加字段：

```dart
  /// 删除模式状态机（`docs/phase6/design/01` §3）。
  HistoryViewState _view = HistoryViewState.initial;
```

(b) 把 `_onCardTap` 替换为完整的分流与删除处理：

```dart
  /// 卡片点击（`docs/phase6/design/01` §3）。
  ///
  /// 删除态下"点谁删谁"（对齐上游 `HistoryAdapter#setClickListener`）；
  /// 多选态下只切换勾选；默认态按设置分流（Task 8 补）。
  void _onCardTap(PlaybackHistory item) {
    switch (_view.mode) {
      case HistoryViewMode.singleDelete:
        _deleteOne(item);
      case HistoryViewMode.multiSelect:
        setState(() => _view = _view.toggleSelection(item.id));
      case HistoryViewMode.none:
        unawaited(_resume(item));
    }
  }

  /// 长按：进入 / 退出删除态（对齐上游 `OnClickListener#onLongClick`）。
  ///
  /// 多选态下长按**不切到**删除态：两个模式的入口互斥（§3.1 的状态图里
  /// 没有 `multiSelect → singleDelete` 这条边），否则用户在多选态误长按会
  /// 丢掉已勾选的集合。
  void _onCardLongPress() {
    setState(() {
      _view = switch (_view.mode) {
        HistoryViewMode.singleDelete => _view.exitMode(),
        HistoryViewMode.multiSelect => _view,
        HistoryViewMode.none => _view.enterSingleDelete(),
      };
    });
  }

  /// 删除一条。**必须逐条走 `deleteHistory`**：它同时写
  /// `history_deletions` 标记，否则安卓下次推来旧记录会复活
  /// （`docs/phase5/design/02` §4.5）。
  void _deleteOne(PlaybackHistory item) {
    _state.deleteHistory(item.id);
    setState(() {
      // 判定基准是**过滤后的可见列表**：可见列表为空即退出。
      // （`design/01` §3.2 原文此处自相矛盾，已按裁定改写，见该节修订说明。）
      final remaining = _items.where((row) => row.id != item.id).length;
      if (remaining == 0) _view = _view.exitMode();
    });
  }

  /// 退出删除态的按钮（顶部「完成」）。
  void _exitDeleteMode() => setState(() => _view = _view.exitMode());
```

(c) 在 `build` 里，搜索框那一行**之后**、`const Divider(height: 1),` **之前**
插入删除态提示条：

```dart
        if (_view.mode == HistoryViewMode.singleDelete)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text('删除模式：点击卡片即删除该条记录'),
                ),
                TextButton(
                  key: const ValueKey('history-delete-done'),
                  onPressed: _exitDeleteMode,
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
```

(d) 在 `_buildHistoryCard` 的 `InkWell` 上加 `onLongPress`，并在 `Stack`
里按模式叠加遮罩：

```dart
    return InkWell(
      key: ValueKey('history-row-${item.id}'),
      onTap: () => _onCardTap(item),
      onLongPress: _onCardLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PosterImage(url: item.vodPic),
                  // 删除态：盖一层删除遮罩（对齐上游 `@id/delete`）。
                  if (_view.mode == HistoryViewMode.singleDelete)
                    Container(
                      key: ValueKey('history-delete-overlay-${item.id}'),
                      color: theme.colorScheme.surface.withValues(alpha: 0.72),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.delete_outline,
                        size: 32,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  // 删除态下隐藏进度角标（对齐上游：删除态是"另一个模式"）。
                  if (_view.mode != HistoryViewMode.singleDelete)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: _HistoryBadge(
                        text: item.completed
                            ? '已看完'
                            : '已看 ${item.progressPercent}%',
                      ),
                    ),
                ],
              ),
            ),
          ),
          // …其余不变（进度条 + 片名 + 集名）
```

(e) 给 `HistoryPage` 的 `build` 外层加 `Shortcuts`/`Actions` 支持 Esc 退出
（放在 `Column` 之外包一层）：

```dart
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_view.mode != HistoryViewMode.none) _exitDeleteMode();
        },
      },
      child: Focus(
        autofocus: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [ /* 原有 children 全部搬进来 */ ],
        ),
      ),
    );
```

顶部 import 追加：

```dart
import 'package:flutter/services.dart';
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
```

预期：`All tests passed!`（21 个用例）。

> **计数回填（实现后）**：Task 5 结束时文件共 12 个用例 → 本轮 +9 = **21**。
> brief 写的「13」与任何口径都对不上（12 + brief 的 6 = 18）。
>
> **brief 的 3 处缺陷**（实现时发现，已在上方片段修正）：
>
> 1. **`_onCardLongPress` 缺 `multiSelect` 分支**：brief 写的是
>    `mode == singleDelete ? exitMode() : enterSingleDelete()`，于是**多选态下
>    长按会切进删除态**并清空已勾选集。而 §3.1 的状态图里**没有**
>    `multiSelect → singleDelete` 这条边（两个模式入口互斥）。已改为 `switch`。
> 2. **`_deleteOne` 的注释与 `design/01` §3.2 的句3 同源错误**：brief 的注释写
>    「全量还有条目但被搜索挡住时不退出」，与它自己的代码（用 `_items` 判定）
>    矛盾。§3.2 原文自相矛盾，已裁定为**退出**（详见 `design/01` §3.2 的
>    2026-10-16 修订说明）。
> 3. **brief 没给 Esc 的钉子**：`design/01` §3.1 与 A6 都要求 Esc 退出，
>    但 brief 的 6 条用例里没有一条按 Esc。已补「Esc 退出删除态」。
>
> **另补 3 条 brief 没有的钉子**（变异自检发现）：
> - 「删掉过滤后最后一条即退出」——**判定基准**的钉子（改用全量判空会失败）；
> - 「删除会写删除标记」——逐条走 `state.deleteHistory` 的钉子
>   （直接改本地列表会让远端旧记录复活，`phase5 design/02` §4.5）；
> - 「再次长按退出删除态」补了**进入态的前置断言**（否则「从未进入」时也绿）。
>
> **变异自检 6/6 全部杀死**：①长按空实现；②删除态点击走 `_resume`；
> ③判定改用 `state.recentHistory()`；④删除不走 `state.deleteHistory`；
> ⑤Esc 绑定换成 F12；⑥删除态不渲染遮罩。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/library_pages.dart test/phase6_history_page_test.dart
git commit -m "新增：历史页长按删除态（点谁删谁，design/01 §3.1）"
```

---

### Task 7: 多选批量删除态

**Files:**
- Modify: `lib/ui/library_pages.dart`
- Test: `test/phase6_history_page_test.dart`（追加）

**Interfaces:**
- Consumes: `HistoryViewState.canDeleteSelected` / `selectAll` / `selectedInOrder`（Task 1）
- Produces: 新增 `ValueKey('history-bulk-delete')`、`ValueKey('history-select-all')`、`ValueKey('history-delete-selected')`、`ValueKey('history-cancel-select')`、`ValueKey('history-checkbox-<id>')`、`ValueKey('history-bulk-confirm')`

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_history_page_test.dart` 追加：

```dart
  group('多选批量删除（design/01 §3.1）', () {
    testWidgets('点「批量删除」进入多选态', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      expect(find.byKey(const ValueKey('history-bulk-delete')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();

      expect(find.byKey(const ValueKey('history-checkbox-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-select-all')), findsOneWidget);
    });

    testWidgets('多选态点卡片只勾选，不删除', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.text('剧集甲'), findsOneWidget, reason: '不得删除');
      expect(find.text('已选 1 条'), findsOneWidget);
      expect(state.recentHistory().length, 2, reason: '库中仍是 2 条');
    });

    testWidgets('全选后删除选中：确认框写明条数，确认后删除', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-select-all')));
      await tester.pump();
      expect(find.text('已选 2 条'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
      await tester.pumpAndSettle();
      expect(find.textContaining('将删除选中的 2 条'), findsOneWidget);
      expect(find.textContaining('不可撤销'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('history-bulk-confirm')));
      await tester.pumpAndSettle();

      expect(state.recentHistory(), isEmpty);
      expect(find.text('暂无播放记录'), findsOneWidget);
    });

    testWidgets('取消确认框不删除', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-select-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(state.recentHistory().length, 1);
    });

    testWidgets('「取消」退出多选态并清空勾选', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-cancel-select')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-checkbox-1')), findsNothing);
      expect(find.byKey(const ValueKey('history-bulk-delete')), findsOneWidget);
    });

    testWidgets('搜索词变化清空已选', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      expect(find.text('已选 1 条'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '剧集乙');
      await tester.pumpAndSettle();

      expect(find.text('已选 1 条'), findsNothing, reason: '搜索词变化必须清空已选');
      expect(find.byKey(const ValueKey('history-checkbox-2')), findsOneWidget);
    });

    testWidgets('搜索词未变化时不清空已选', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '剧集');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      // 再输入同一个词（onChanged 会被调用，但值未变）。
      await tester.enterText(find.byType(TextField), '剧集');
      await tester.pumpAndSettle();

      expect(find.text('已选 1 条'), findsOneWidget, reason: '值未变不得清空');
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
```

预期：FAIL，`Found 0 widgets with key [<'history-bulk-delete'>]`。

- [ ] **Step 3: 写最小实现**

在 `lib/ui/library_pages.dart` 中：

(a) 搜索框的 `onChanged` 改为走状态机：

```dart
                  onChanged: (value) => setState(() {
                    final next = value.trim();
                    _keyword = next;
                    _view = _view.withKeyword(next);
                  }),
```

(b) 工具栏那一行改为按模式渲染：

```dart
              const SizedBox(width: 12),
              if (_view.mode == HistoryViewMode.none) ...[
                if (items.isNotEmpty)
                  OutlinedButton.icon(
                    key: const ValueKey('history-bulk-delete'),
                    onPressed: () => setState(
                      () => _view = _view.enterMultiSelect(),
                    ),
                    icon: const Icon(Icons.checklist_outlined),
                    label: const Text('批量删除'),
                  ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const ValueKey('history-clear-all'),
                  onPressed: () => _confirmClearAll(),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('清空历史'),
                ),
              ],
```

> 「清空历史」的 `onPressed` 原本是内联的确认框代码，抽成
> `_confirmClearAll()`（**文案与逻辑一字不改**，只搬位置）。

(c) 删除态提示条之后，加多选态工具栏：

```dart
        if (_view.mode == HistoryViewMode.multiSelect)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _view.selectedIds.isEmpty
                        ? '批量删除：勾选要删除的记录'
                        : '已选 ${_view.selectedIds.length} 条',
                  ),
                ),
                TextButton(
                  key: const ValueKey('history-select-all'),
                  onPressed: () => setState(
                    () => _view = _view.selectAll(
                      [for (final item in items) item.id],
                    ),
                  ),
                  child: const Text('全选'),
                ),
                TextButton(
                  key: const ValueKey('history-delete-selected'),
                  onPressed: _view.canDeleteSelected
                      ? () => _confirmDeleteSelected()
                      : null,
                  child: Text('删除选中(${_view.selectedIds.length})'),
                ),
                TextButton(
                  key: const ValueKey('history-cancel-select'),
                  onPressed: () => setState(() => _view = _view.exitMode()),
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
```

(d) 在 `_buildHistoryCard` 的海报 `Stack` 里加复选框（多选态）：

```dart
                  if (_view.mode == HistoryViewMode.multiSelect)
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Icon(
                        key: ValueKey('history-checkbox-${item.id}'),
                        _view.selectedIds.contains(item.id)
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        color: _view.selectedIds.contains(item.id)
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
```

(e) 加两个确认方法（放在 `_deleteOne` 之后）：

```dart
  /// 批量删除确认（`docs/phase6/design/01` §3.3）。
  ///
  /// 必须写明**条数**与**不可撤销**：一次删多条是破坏性操作。
  Future<void> _confirmDeleteSelected() async {
    final ids = _view.selectedInOrder;
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('history-bulk-confirm-dialog'),
        title: const Text('批量删除播放历史'),
        content: Text(
          '将删除选中的 ${ids.length} 条播放历史。\n'
          '该操作不可撤销；已同步到安卓的删除标记会随下次同步生效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('history-bulk-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // **逐条**删除：走既有的 deleteHistory 才能写 history_deletions 标记。
    for (final id in ids) {
      _state.deleteHistory(id);
    }
    if (!mounted) return;
    setState(() => _view = _view.exitMode());
  }

  /// 清空历史确认（文案与既有实现一致，只搬位置）。
  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空播放历史'),
        content: const Text('该操作只清空播放历史，不会删除配置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _state.clearHistory();
    if (!mounted) return;
    setState(() => _view = _view.exitMode());
  }
```

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
```

预期：`All tests passed!`（35 个用例）。

> **计数回填（实现后）**：Task 6 结束时 21 个 → 本轮 +14 = **35**。
> brief 写的「20」与任何口径都对不上（21 + brief 的 7 = 28）。
>
> **brief 的 1 处事实性错误**（实现时发现，已在上方片段修正）：
>
> - 「取消确认框不删除」用例里的裸 `find.text('取消')` **会命中 2 个 widget**
>   —— 多选工具栏自己也有一个「取消」按钮。实测报
>   `ambiguously found multiple matching widgets`。已改为
>   `find.descendant(of: ValueKey('history-bulk-confirm-dialog'), matching: find.text('取消'))`。
>
> **另补 7 条 brief 没有的钉子**（变异自检发现）：
> - 「全选只勾当前可见的」（搜索后被挡住的不得被勾）；
> - 「只删选中的那一条，未选中的保留」；
> - 「批量删除也写删除标记」（`phase5 design/02` §4.5）；
> - 「未勾选时『删除选中(0)』禁用」；
> - 「多选态下长按不切进删除态，已勾选不丢」（§3.1 状态图无这条边）；
> - 「多选态下 Esc 退出并清空勾选」；
> - 「默认态不渲染多选工具栏」。
>
> **变异自检 7/7 全部杀死**：①全选改用全量 `recentHistory()`；
> ②批量删除不写删除标记；③去掉 `canDeleteSelected` 守卫；
> ④去掉 `withKeyword`（搜索词变化不清空）；⑤多选态长按切进删除态
> （退回 brief 原写法）；⑥不渲染复选框；⑦批量删除后不退出多选态。
>
> **变异 ⑦ 首轮存活 → 真覆盖缺口**：「全选后删除选中」原本只断言
> `recentHistory()` 为空与空态文案，而删除后**留在**多选态同样能全绿。
> 已补断言「确认后退出多选态」（`design/01` A10）与「列表空后两个入口都不渲染」（A12）。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/library_pages.dart test/phase6_history_page_test.dart
git commit -m "新增：历史页多选批量删除态（design/01 §3.1、§3.3）"
```

---

### Task 8: 点击分流（进详情页 / 直接播放）

**Files:**
- Modify: `lib/ui/library_pages.dart`
- Test: `test/phase6_history_page_test.dart`（追加）

**Interfaces:**
- Consumes: `AppState.historyClickAction`（Task 3）、`UiHistoryClickAction`（Task 1）、`DetailPage`（既有）
- Produces: 无新 API

- [ ] **Step 1: 写失败的测试**

在 `test/phase6_history_page_test.dart` 追加（import 区加
`import 'package:webhtv_pc/ui/browse_pages.dart';`）：

```dart
  group('点击分流（design/01 §4、§5）', () {
    testWidgets('默认 detail：点卡片进详情页，不播放', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.byType(DetailPage), findsOneWidget);
    });

    testWidgets('play：点卡片直接续播，不进详情页', (tester) async {
      await state.setHistoryClickAction(UiHistoryClickAction.play);
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();

      expect(find.byType(DetailPage), findsNothing);
    });

    testWidgets('站点不在配置中时给出可见提示，不静默失败', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲', siteKey: '已删除的站点');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('已不在当前配置中'), findsOneWidget);
      expect(find.byType(DetailPage), findsNothing);
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
```

预期：FAIL，`play` 用例与「站点不在配置中」用例失败（当前 `_onCardTap` 恒为 `_resume`）。

- [ ] **Step 3: 写最小实现**

在 `lib/ui/library_pages.dart` 中：

(a) 把 `_onCardTap` 的 `none` 分支改为分流：

```dart
      case HistoryViewMode.none:
        unawaited(_openBySetting(item));
```

(b) 加分流与详情页跳转方法（放在 `_resume` 之后）：

```dart
  /// 按「点击历史行为」设置分流（`docs/phase6/design/01` §4.1）。
  Future<void> _openBySetting(PlaybackHistory item) {
    return _state.historyClickAction == UiHistoryClickAction.play
        ? _resume(item)
        : _openDetail(item);
  }

  /// 打开该条历史对应的详情页。
  ///
  /// **必须先切站点**：`DetailPage` 的详情请求依赖「当前站点」，
  /// 不切会串到别的站点去取详情（与 `search_page.dart#_openResult` 同因）。
  ///
  /// 站点已不在当前配置中时**不静默失败**：历史可能来自旧配置或安卓推送。
  Future<void> _openDetail(PlaybackHistory item) async {
    final state = _state;
    final config = state.config;
    final site = config?.sites
        .where((candidate) => candidate.key == item.siteKey)
        .firstOrNull;
    if (site == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('该记录所属站点已不在当前配置中：${item.siteKey}')),
      );
      return;
    }
    await state.selectSite(site);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          state: state,
          vod: Vod(
            vodId: item.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
          ),
          historyFlag: item.flag,
          historyEpisodeId: item.episodeId,
        ),
      ),
    );
  }
```

> `DetailPage` 的 `historyFlag` / `historyEpisodeId` 两个参数由
> **计划 2 的 Task 3** 添加。本任务先加参数会编译失败，因此**本任务与
> 计划 2 Task 3 必须一起提交**；若按计划顺序执行，先执行计划 2 的 Task 3。

- [ ] **Step 4: 跑测试确认通过**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
```

预期：`All tests passed!`（43 个用例）。

> **计数回填（实现后）**：Task 7 结束时 35 个 → 本轮 +8 = **43**。
> brief 写的「23」与任何口径都对不上（35 + brief 的 3 = 38）。
>
> **brief 的 2 处缺陷**（实现时发现，已在上方片段修正）：
>
> 1. **三条用例都缺「配置前置」**：`setUp` 的 `state` 没有配置
>    （`bootstrap()` 不导入任何配置），而 `_openDetail` / `_resume` 都要求
>    「站点在配置里」——不导入配置时三条用例全部走「站点不在配置中」分支，
>    第一条（期望进详情页）必红。已加 `seedSite()` 辅助函数：
>    导入**内联 JSON** 配置（不联网；`configFor(url)` 是 URL 源，在
>    `testWidgets` 的 fake-async 区会拿到 400）。
> 2. **`play` 用例会挂死**（`did not complete`，无 Exception 日志）：
>    `setHistoryClickAction` 会真实写盘，而 `testWidgets` 是假时钟，
>    写盘回调不会被 `pump` 推进。同文件上方的
>    「已保存的偏好决定初始选中项」用例已踩过同一个坑。已改为
>    `tester.runAsync(() => state.setHistoryClickAction(...))`。
>
> **另补 5 条 brief 没有的钉子 + 2 处测试基建**（预检/变异自检发现）：
> - 「进详情页前先切到该记录所属站点（不串站）」——用双站点配置断言
>   `selectedSite.key` 真的变了（`search_page.dart#_openResult` 同因）；
> - 「详情页收到该条历史的线路与集入口」（`design/02` §7.1：点旧记录不得续新记录）；
> - 「删除态下点卡片不跳详情页」「多选态下点卡片不跳详情页」；
> - 「play 模式下站点不在配置中同样给提示」；
> - **测试基建 ①**：注入 `_RecordingSiteClient`（`http.BaseClient` 子类）
>   —— 避免 fake-async 区里的真实 socket I/O 挂死，同时让「是否真的发起了
>   播放入口请求（`play=` 参数）」可断言。只断言「没进详情页」是弱断言，
>   「什么都没发生」也能让它绿。
> - **测试基建 ②**：`runAsync` 之后要 `pump(Duration(milliseconds: 300))`
>   把 `LogService._enqueue` 的 0 延迟刷盘 `Timer` 泵完，否则报
>   `A Timer is still pending even after the widget tree was disposed`。
>
> **变异自检 6/6 全部杀死**：①分流恒为 detail（忽略设置）；②分流恒为 play；
> ③进详情页前不切站点；④站点缺失时静默返回；⑤不传历史的 flag/episodeId；
> ⑥删除态也走分流（点卡片会跳详情页）。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/library_pages.dart test/phase6_history_page_test.dart
git commit -m "新增：历史页点击分流（进详情页 / 直接播放，design/01 §4.1）"
```

---

## 收尾验证

- [ ] **跑全量单测**

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test
```

预期：除已知的 `phase2_last_site_test` 文件锁抖动（单独跑全绿）外全绿。

- [ ] **跑静态分析**

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' analyze
```

预期：`No issues found!`。

- [ ] **确认回归门禁**

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test `
  test/phase3_detail_page_test.dart `
  test/phase2_playback_target_test.dart `
  test/phase5_sync_ui_test.dart
```

预期：全绿。

- [ ] **跑 L3 集成测试**

```powershell
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test `
  integration_test/mvp_a_flow_test.dart integration_test/phase5_sync_flow_test.dart -d windows
```

预期：全绿（`mvp_a_flow_test` 断言 `find.text('清空历史')`；
`phase5_sync_flow_test` 断言历史页 3 个片名各 `findsOneWidget`）。

- [ ] **产出证据（`design/05` §6）**

按 `DESIGN.md` 的验证纪律，**背景/铺满类改动必须在多个宽高比各出一张图**。
历史页卡片是网格度量，因此至少出 1440×900（1.6:1）与 2.35:1 两张。

| 文件 | 内容 | 视口 |
| --- | --- | --- |
| `docs/phase6/evidence/history-cards.png` | 卡片网格（暗色） | 1440×900 |
| `docs/phase6/evidence/history-cards-r235x1.png` | 卡片网格（验证列数自适应） | 2.35:1 |
| `docs/phase6/evidence/history-delete-mode.png` | 删除态（遮罩 + 完成） | 1440×900 |
| `docs/phase6/evidence/history-multi-select.png` | 多选态（复选框 + 已选 N） | 1440×900 |

截图由集成测试的 `RepaintBoundary → toImage → PNG` harness 产出
（与 Phase 0–5 一致），**不是** widget 树的重描述。

```bash
git add docs/phase6/evidence/
git commit -m "证据：历史页卡片与两种删除模式截图（design/05 §6）"
```
