# 01 · 历史记录页：卡片网格与两种删除模式

- 状态：设计指导，**待评审**
- 日期：2026-10-14
- 上游参考：`webhtv/默影视` 的 `HistoryActivity`、`HistoryAdapter`、`res/layout/adapter_vod.xml`
- 关联：`00`（总索引 §3.1）、`02`（详情页续播）、`05`（测试与验收）
- PC 端落点：`lib/ui/library_pages.dart`、`lib/core/history_view.dart`（新增）、
  `lib/services/ui_preferences_store.dart`、`lib/state/app_state.dart`、
  `lib/ui/diagnostics_pages.dart`

---

## 1. 现状与缺口

| 项 | 现状（`lib/ui/library_pages.dart`） | 目标 |
| --- | --- | --- |
| 列表形态 | `ListTile` 单列列表，左侧 64×84 海报 | 海报网格卡片，列数随窗口自适应 |
| 单条删除 | 每行一个 `IconButton`，点击即删（无确认） | 长按进删除态 → 点卡片即删 |
| 批量删除 | **无** | 工具栏按钮 → 多选态 → 确认后批量删 |
| 点击行为 | 固定「直接续播」 | 可配置：进详情页（默认）/ 直接播放 |
| 季度进度区块 | 独立的一段 `ListTile` 列表 | 保持不变（本轮不改造） |

---

## 2. 卡片设计

### 2.1 结构（对齐 `adapter_vod.xml`）

```text
┌─────────────────────┐
│ [站点角标]          │  ← 左上角，仅当站点名可读时显示
│                     │
│      海报 2:3        │
│                     │
│ [已看 32%] [已看完]  │  ← 左下角，进度角标
├─────────────────────┤
│ ▓▓▓▓▓▓░░░░░░░░░░░░  │  ← 2px 进度条，紧贴海报下沿
│      片名（一行）     │  ← 居中，超长省略
│      集名（一行）     │  ← 居中，弱化色
└─────────────────────┘
```

上游把片名/集名放在半透明黑底上压在壁纸上，PC 端**不这么做**：PC 的卡片落在
`surfaceContainerLow` 上（`DESIGN.md` 的 Cards 规范），文字直接用 `onSurface` /
`onSurfaceVariant`，对比度由主题保证，不依赖图片明暗。

### 2.2 网格度量

复用首页海报墙的算法（`browse_pages.dart` 的 `_gridDelegate`）：
按可用宽度定列数（`clamp(2, 12)`），再由列宽推出格子高度
（`cellWidth * 1.5 + 8 + captionHeight`）。**不引入新的度量常量**——
`DESIGN.md` 的「固定比例」纪律要求海报全站共用 2:3 与同一套尺度。

**「复用」包含三样东西，缺一不可**（2026-10-14 修订，实现时发现 brief 漏了后两样）：

1. **同一套常量语义（含卡片文字度量）**：目标卡宽、间距、
   `cellWidth * 1.5 + 间距 + captionHeight` 的形状（历史页可用自己的常量名，
   但**取值必须与首页一致**）；**文字度量（`fontSize`/`height`）同属此列**
   ——首页是 13/1.2（片名）+ 11/1.2（副行），历史页必须照抄，理由见第 3 条。
2. **宽度基准必须是内容区，不是整窗**：首页用
   `LayoutBuilder(constraints.maxWidth)`（`browse_pages.dart:623`、`:652`），
   历史页也**必须**如此。用 `MediaQuery.sizeOf(context).width` 会拿到**整窗宽**，
   而壳层有 76px 左栏 + 1px 分隔线 → 同一窗口下列数比首页**偏多约 0.5 列**，
   两处卡片大小不一致。
3. **文字缩放必须夹住，且度量必须对齐**：首页在文字区包了
   `MediaQuery.withClampedTextScaling(maxScaleFactor: 1.25)`
   （`browse_pages.dart:836-839`），其注释写明理由——
   「放大字号（无障碍）时只缩不放：**文字区高度是固定值，不夹住就会溢出格子**」。
   历史页的 caption 高度**同样是固定值**，因此**必须**包同样的一层。

   **但 clamp 单独不成立**（修复轮实测）：1.25 能不能装进 40px 文字区，
   取决于文字的本征高度：

   | 度量 | 本征高度 | ×1.25 | 40px 文字区 |
   | --- | --- | --- | --- |
   | 首页 13/1.2 + 11/1.2 | 28.8px | 36.0px | ✅ 余 4px |
   | M3 默认 14/1.43 + 12/1.33 | 35.98px | 44.98px | ❌ **溢出 5px** |

   即：**clamp 1.25 + M3 默认字号仍会溢出 5px**（在 textScale 1.5 与 2.0 下
   均实测 5px）——这正是把「度量必须对齐」并入第 1 条的原因。
   去掉 clamp 时（首页度量）：textScale 1.5 溢出 3px、2.0 溢出 17px。

> **为什么把这三条写死**：原文只说「复用首页的算法」，而 brief 落地时只复用了
> 第 1 条的**常量部分**（文字度量用了 M3 默认），漏了第 2、3 条与第 1 条的度量部分。
> 第 3 条是**用户可见缺陷**（无障碍放大时卡片溢出），第 2 条是**纪律违背**（同站两套尺度）。

### 2.3 卡片上的文字数量约束

每张卡片的片名**只渲染一次** `Text`。理由：`phase5_sync_flow_test` 用
`find.text(name)` 断言 `findsOneWidget`（该测试从安卓推 3 条历史后断言
历史页出现这 3 个片名）。渲染两次（例如标题 + tooltip 内的 `Text`）会让
`findsOneWidget` 失败。`Tooltip` 的 `message` 是字符串，不产生 `Text`，安全。

---

## 3. 删除模式状态机

### 3.1 三个模式

| 模式 | 入口 | 卡片点击行为 | 卡片外观 | 退出方式 |
| --- | --- | --- | --- | --- |
| `none` | 默认 | 按「点击行为」设置分流 | 正常 | — |
| `singleDelete` | **长按任意卡片** | **删除该条** | 盖删除遮罩，隐藏进度角标 | 再次长按 / Esc / 返回 / 顶部「完成」 |
| `multiSelect` | **工具栏「批量删除」按钮** | 切换勾选 | 左上角复选框，选中项加描边 | 「取消」/ Esc / 返回 |

### 3.2 状态转移

```text
none ──长按卡片──────────→ singleDelete
none ──点「批量删除」────→ multiSelect
singleDelete ──长按/完成/Esc/返回──→ none
singleDelete ──点卡片──→ singleDelete（删除一条，仍在删除态）
multiSelect ──点卡片──→ multiSelect（切换勾选）
multiSelect ──取消/Esc/返回──→ none
multiSelect ──点「删除选中(N)」──→ 确认框 ──确认──→ 删除 N 条 → none
multiSelect ──点「全选」──→ multiSelect（勾选当前可见全部）
```

**共同规则**：

- 列表为空时**两个入口都不渲染**（`DESIGN.md`：「一个点了什么也没有的按钮比
  没有按钮更糟」）。
- 列表为空时的空态文案要分情况：按源视图为空但全部来源有记录时，说「暂无播放
  记录 / 播放任意剧集后会自动记录进度」是**假话**（用户会反复播放却看不到新记录）。
  这一分支由 `library_pages.dart` 的 `_emptyHistory()` 处理，判据与文案见
  `phase5/design/05` §6.1。
- 进入任一模式时清空已选集合；搜索词变化时清空已选集合（否则会删到看不见的条目）。
- 搜索词变化**不退出**模式（用户可能想先筛再删），但已选集合必须清空。
- `singleDelete` 下删除最后一条 → 列表为空 → 自动回到 `none`（对齐上游
  `HistoryActivity#onItemDelete` 的 `getItemCount() == 0 → setDelete(false)`）。

**各模式下搜索词变化的行为**（逐模式明确，避免歧义）：

| 模式 | 搜索词变化时 | 理由 |
| --- | --- | --- |
| `none` | 只更新 `keyword` | 无选中集可清 |
| `singleDelete` | **保持** `singleDelete`，`keyword` 更新 | 删除态下点卡片即删，没有"选中集"概念；退出反而打断用户连续删除 |
| `multiSelect` | **保持** `multiSelect`，**清空** `selectedIds` | 见 §3.4 的 `withKeyword` |

**`singleDelete` 下删除最后一条的判定基准是"过滤后的可见列表"**：
可见列表为空就退出删除态。判定必须用 `_items`（过滤后）而不是
`state.recentHistory()`（全量）。

> **2026-10-16 修订：原文这一节自相矛盾，已按裁定改写。**
> 原文同时写了两个相反结论：
> ① 「搜索出 1 条、删掉它之后，可见列表为空 → **退出**删除态」；
> ② 「若搜索前有 10 条、搜索后可见 1 条，删掉这 1 条**不应**退出删除态
> （还有 9 条被搜索词挡着）」。
>
> ①与②描述的是**同一个场景**（搜索后可见 1 条 → 删掉它），结论却相反。
> 且②与「判定必须用 `_items`」**不可兼得**：用 `_items` 判定 ⇒ 删掉可见
> 最后一条后必然为空 ⇒ 必然退出（= ①），永远达不到②。
>
> **裁定：退出**（可见列表为空即退出）。依据 3 条对 1 条：
> 1. `design/05` 的 A11d（**验收判据**）只保留了退出条款：
>    「删除态删掉"过滤后最后一条"才退出」；
> 2. 本节「判定必须用 `_items`」是实现指令，用 `_items` 必然导出退出；
> 3. 「判定基准是过滤后的可见列表」是本节**加粗的主规则**；
> 4. 上游 `HistoryActivity#onItemDelete` 是 `getItemCount() == 0 → setDelete(false)`
>    （上游无搜索，`getItemCount()` 等价于全量；全量==可见时与①一致）。
>
> **UX 判据（决定性）**：若取②，可见列表已空、删除态横幅仍在，屏幕会同时出现
> 「暂无播放记录」与「点击卡片即删除该条记录」——自相矛盾的界面，正是本文档
> 自己批判的反模式（「一个点了什么也没有的按钮比没有按钮更糟」）。
>
> 钉子：`test/phase6_history_page_test.dart` 的
> 「删掉过滤后最后一条即退出（裁定：§3.2 句3 与句5 冲突，取句5）」——
> 改用 `state.recentHistory()`（全量）判空会让它失败。

### 3.3 批量删除的确认文案

必须写明**条数**与**不可撤销**：

> 将删除选中的 N 条播放历史。
> 该操作不可撤销；已同步到安卓的删除标记会随下次同步生效。

第二条说明来自 `docs/phase5/design/02` §4.5：删除会写 `history_deletions` 标记，
避免远端旧记录复活。用户有权知道这件事。

### 3.4 纯逻辑落点

状态机与卡片模型放 `lib/core/history_view.dart`（**不依赖 Flutter**），
理由与 `hot_rank_layout.dart`、`search_result_filter.dart` 一致：
纯逻辑可单测、可在无窗口环境全绿。

```dart
enum HistoryViewMode { none, singleDelete, multiSelect }

class HistoryViewState {
  final HistoryViewMode mode;
  final Set<int> selectedIds;   // 仅 multiSelect 有意义
  final String keyword;         // 上一次已知的搜索词

  HistoryViewState enterSingleDelete();
  HistoryViewState enterMultiSelect();
  HistoryViewState exitMode();
  HistoryViewState toggleSelection(int id);
  HistoryViewState selectAll(List<int> visibleIds);
  HistoryViewState clearSelection();
  HistoryViewState withKeyword(String keyword);   // 变化时清空选中
  bool get canDeleteSelected;
  List<int> get selectedInOrder;                  // 稳定顺序，便于断言
}
```

`withKeyword` 的语义（**必须精确**，否则会误删）：

```dart
HistoryViewState withKeyword(String next) {
  if (next == keyword) return this;        // 未变化 → 原样返回（不清选中）
  return copyWith(keyword: next, selectedIds: const {});
}
```

- **比较基准是"上一次已知的搜索词"**（`keyword` 字段），不是"进入模式时的搜索词"；
- 未变化时**必须**返回 `this`（`identical` 级别），否则每次 `setState`
  都会清空用户的勾选——这是最容易写错的一处；
- `keyword` 字段在**所有**转移里都要保留（`enterMultiSelect` / `exitMode` /
  `toggleSelection` 都不得重置它），否则比较基准会漂移。

**为什么搜索词变化要清空选中**：用户可能在多选态下搜索缩小范围，
此时已勾选但**已不可见**的条目若仍留在 `selectedIds` 里，
点「删除选中(N)」会删掉用户看不见的条目。清空是唯一安全的选择。

---

## 4. 点击行为设置

### 4.1 取值

`ui` 段新增 `historyClickAction`，两个值：

| 值 | 行为 | 默认 |
| --- | --- | --- |
| `detail` | 打开该条对应的详情页 | ✅ |
| `play` | 直接续播（既有行为） | |

`detail` 为默认是用户明确要求（「历史记录点击优先进入对应的详情页」）。

### 4.2 存储

沿用 `UiPreferencesStore` 既有模式：**缺席 = 默认**，只有用户显式选过才写盘
（与 `themeMode`、`searchSimilarity` 相同）。非法值归一到 `detail`。
新增 `UiHistoryClickAction` 常量类（含 `normalize(String?)` 静态方法），
与 `UiThemeMode` 同构。

### 4.3 设置页入口

`SettingsPage` 在「外观」区块下方新增「历史记录」区块：

```text
历史记录
[ 进入详情页 ] [ 直接播放 ]     ← SegmentedButton
点击历史记录时的行为。长按卡片始终进入删除状态。
```

`ValueKey('settings-history-click-action')`，与既有
`settings-theme-mode` 同构，便于测试定位。

---

## 5. 进详情页的路径

`detail` 模式下点击卡片需要打开 `DetailPage`，而历史记录只保存
`siteKey / vodId / vodName / vodPic / flag / episodeName / episodeId`。

**必须先切站点**：`DetailPage` 的详情请求依赖「当前站点」（`AppState.selectedSite`），
不切会串到别的站点去取详情。这与 `search_page.dart#_openResult` 的既有做法一致
（那里也先 `await _state.selectSite(site)` 再 push）。

站点已不在当前配置中时（历史可能来自旧配置或安卓推送）：
**不静默失败**，用 `SnackBar` 说明「该记录所属站点已不在当前配置中：<key>」，
与现有 `_resume` 的处理一致。

### 5.1 传给详情页的参数

`DetailPage` 新增两个可选参数（**定义与消费都在 `02` §4**，本节只说明
历史页负责传入什么）：

```dart
DetailPage(
  state: _state,
  vod: Vod(vodId: item.vodId, vodName: item.vodName, vodPic: item.vodPic),
  historyFlag: item.flag,          // 历史记录里的线路 flag
  historyEpisodeId: item.episodeId, // 历史记录里的集入口目标
)
```

**为什么传 `Vod` 而不是完整条目**：历史只保存 `vodId / vodName / vodPic`，
详情页自己会发详情请求补全线路与简介（`loadDetail`）。这与
`search_page.dart#_openResult` 的做法一致。

**为什么传 `historyFlag` / `historyEpisodeId` 而不是让详情页自己查**：
详情页确实也能自己调 `findHistory(siteKey, vodId)` 查到（`02` §7 就是这么做的，
用于「用户直接从列表页进详情页」的场景）。历史页**额外**传入的好处是：
历史页已经拿到了**用户点的那一条**（可能不是该剧最新的一条），
传入能保证「点哪条就续哪条」，而不是被 `findHistory` 的
`ORDER BY updated_at DESC LIMIT 1` 覆盖成另一条。

两者的优先级：**显式传入的参数 > 详情页自己查**。

---

## 6. 季度进度区块

**本轮不改造**，保持现有 `ListTile` 形态与两级删除语义（删季度 / 删整部）。
理由：

1. 它是**另一套数据源**（`tmdb_season_progress` 表）与另一套删除语义
   （`deleteSeasonProgress` / `deleteMediaProgress`），与 `history` 表的
   单条删除不是同一件事；
2. 把它并入多选态会让「删除选中」的语义分裂成两种；
3. 用户本轮诉求针对的是「历史记录」，没有提到季度进度区块。

**但**：季度进度区块的删除按钮**不参与**长按删除态——长按只作用于历史卡片。
这一点必须在实现时明确，否则会误把季度卡片也纳入删除态。

---

## 7. 验收

| # | 断言 |
| --- | --- |
| A1 | 历史页渲染为网格（`SliverGrid` 存在），卡片数量 == 历史条数 |
| A2 | 每张卡片只渲染一次片名 `Text` |
| A3 | 长按卡片进入删除态：卡片出现删除遮罩，顶部出现「完成」 |
| A4 | 删除态下点卡片 → 该条被删除，仍在删除态 |
| A5 | 删除态下删除最后一条 → 自动退出删除态 |
| A6 | Esc / 返回 / 再次长按 → 退出删除态，不删任何东西 |
| A7 | 点「批量删除」→ 进入多选态，卡片出现复选框 |
| A8 | 多选态下点卡片只切换勾选，**不删除** |
| A9 | 「全选」勾选当前可见全部；「删除选中(N)」弹确认框并写明 N |
| A10 | 确认后 N 条被删除，退出多选态 |
| A11 | 搜索词变化清空已选集合 |
| A11b | 搜索词**未**变化时不清空已选（`withKeyword` 返回 `this`） |
| A11c | `singleDelete` 下搜索词变化**不退出**删除态 |
| A11d | 删除态删掉"过滤后最后一条"即退出（可见列表为空）；判定用 `_items` 不用全量 |
| A12 | 列表为空时两个删除入口都不渲染 |
| A13 | 设置 `historyClickAction=detail` → 点卡片进详情页，不播放 |
| A14 | 设置 `historyClickAction=play` → 点卡片直接续播（既有行为不变） |
| A15 | 站点不在配置中时给出可见提示，不静默失败 |
| A16 | 「清空历史」按钮文案不变（`mvp_a_flow_test` 锁定） |
