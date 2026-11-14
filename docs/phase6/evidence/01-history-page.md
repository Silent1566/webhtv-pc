# Phase 6 · plans/01 验收证据

- 计划：`docs/phase6/plans/01-history-page.md`
- 设计：`docs/phase6/design/01-history-page-and-delete-modes.md`、
  `design/05-test-and-acceptance.md`
- 提交范围：`656e5a4`（Task 1 起点）→ `2248e0e`（证据）
- 测试文件：
  - `apps/desktop-flutter/test/phase6_history_view_test.dart`（**35 个纯逻辑用例**）
  - `apps/desktop-flutter/test/phase6_history_page_test.dart`（**43 个 widget 用例**）
  - `apps/desktop-flutter/integration_test/phase6_history_visual_flow_test.dart`（4 个截图用例）

## 1. 任务与提交

| Task | 内容 | 提交 | 本套件用例 |
| --- | --- | --- | --- |
| 1 | 删除模式状态机 + 点击行为归一化（纯逻辑） | `656e5a4` | 35 |
| 2 | `historyClickAction` 偏好持久化 | `ca7b303` | — |
| 3 | `AppState` 暴露点击历史行为偏好 | `8320c8c` | — |
| 4 | 设置页新增「历史记录」区块 | `8e64b30` | 4 |
| 5 | 历史页改海报网格卡片 | `e93a2e6` + 修复轮 `3ccef0b` | 12 |
| 6 | 长按进入删除态（点谁删谁） | `8f8014d` | 21 |
| 7 | 多选批量删除态 | `fc6a88f` | 35 |
| 8 | 点击分流（进详情页 / 直接播放） | `79a1f34` | 43 |

各任务的「文档收尾」提交：`2035f24`、`6a5cf90`、`9bea13a`、`f1b7475`、`4dff68e`。

## 2. 门禁结果（独立复跑核实，非采信报告）

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| 聚焦测试（widget） | `flutter test test/phase6_history_page_test.dart` | **43/43 通过** |
| 全量单测 | `flutter test` | **1764 通过 / 0 失败** |
| 静态分析 | `flutter analyze` | `No issues found!` |
| 回归门禁 | `flutter test test/phase3_detail_page_test.dart test/phase2_playback_target_test.dart test/phase5_sync_ui_test.dart` | **39/39 通过** |
| L3 集成（历史页片名门禁） | `flutter test integration_test/phase5_sync_flow_test.dart -d windows` | **1/1 通过**（`step=4 history-page-shows=3`） |
| L3 集成（截图） | `flutter test integration_test/phase6_history_visual_flow_test.dart -d windows` | **4/4 通过** |

全量门禁判定按 `design/05` §7.1：本阶段两次全量（1756/0、1764/0）均**零失败**，
无需援引 flaky 集合。

### 2.1 L3 集成里的一个既有红（与本轮无关）

`integration_test/mvp_a_flow_test.dart` 在 **`:520`** 失败
（`Found 0 widgets with text containing fixture`，是**详情页**断言），
**在执行到历史页断言（`:531`）之前**就中止了。

**已用定向回退实验证明是既有失败**：把 `lib/ui/library_pages.dart`
`git checkout` 回本 session 之前（`e93a2e6~1`，即旧 `ListView` 列表版），
重跑同一用例 → **完全相同的 `:520`、相同的报错**。
另经 `git diff` 核实：`browse_pages.dart`（详情页）在 `e93a2e6~1..HEAD` 区间
**零改动**（`git diff --stat` 为空），因此这条红不可能由本轮引入。

为拿到「清空历史」文案门禁的直接证据，本文件所附的
`phase6_history_visual_flow_test.dart` 在**真实 WINDOWS runner** 上跑了
真实壳层的「最近观看」页（`openHistory` 走 `AppShell` → 点「最近观看」），
4 条用例全部通过 —— 即真实壳层里的历史页渲染正常。

## 3. 验收标准 A1–A16

| # | 断言 | 状态 | 证据 |
| --- | --- | --- | --- |
| A1 | 渲染为网格，卡片数 == 历史条数 | ✅ | `渲染为网格，卡片数 == 历史条数` |
| A2 | 每张卡片只渲染一次片名 `Text` | ✅ | `每张卡片只渲染一次片名 Text` + L3 `step=4`（3 个片名各 `findsOneWidget`） |
| A3 | 长按进入删除态：遮罩 + 顶部「完成」 | ✅ | `长按卡片进入删除态：出现遮罩与「完成」` |
| A4 | 删除态下点卡片 → 删该条，仍在删除态 | ✅ | `删除态下点卡片即删该条，仍在删除态` |
| A5 | 删除态下删最后一条 → 自动退出 | ✅ | `删除态删掉最后一条后自动退出` |
| A6 | Esc / 再次长按 → 退出且不删 | ✅ | `Esc 退出删除态`、`再次长按退出删除态` |
| A7 | 点「批量删除」→ 多选态，出现复选框 | ✅ | `点「批量删除」进入多选态` |
| A8 | 多选态点卡片只切换勾选，不删除 | ✅ | `多选态点卡片只勾选，不删除` |
| A9 | 「全选」勾可见全部；「删除选中(N)」写明 N | ✅ | `全选后删除选中：确认框写明条数，确认后删除`、`全选只勾当前可见的` |
| A10 | 确认后 N 条被删除，退出多选态 | ✅ | 同上（含 A10 的退出断言，变异 ⑦ 补的钉子） |
| A11 | 搜索词变化清空已选 | ✅ | `搜索词变化清空已选` |
| A11b | 搜索词**未**变化时不清空已选 | ✅ | `搜索词未变化时不清空已选` |
| A11c | `singleDelete` 下搜索词变化不退出 | ✅ | **L1**：`phase6_history_view_test.dart:156` `搜索词变化不退出 singleDelete`（`design/05` 标注 A11c 为 L1） |
| A11d | 删掉「过滤后最后一条」即退出 | ✅ | `删掉过滤后最后一条即退出（裁定…）` |
| A12 | 列表为空时两个删除入口都不渲染 | ✅ | `空历史时不渲染删除入口`、`默认态不渲染多选工具栏` |
| A13 | `historyClickAction=detail` → 进详情页 | ✅ | `默认 detail：点卡片进详情页，不播放`、`详情页收到该条历史的线路与集入口` |
| A14 | `historyClickAction=play` → 直接续播 | ✅ | `play：点卡片直接续播，不进详情页`（断言真的发出了 `play=` 播放入口请求） |
| A15 | 站点不在配置中 → 可见提示，不静默失败 | ✅ | `站点不在配置中时给出可见提示，不静默失败`、`play 模式下站点不在配置中同样给提示` |
| A16 | 「清空历史」文案不变 | ✅ | `ValueKey('history-clear-all')` 的 `label: Text('清空历史')` 字面未改；L3 真实壳层渲染通过 |

额外覆盖（brief 没有、由变异自检/预检补的钉子）：
`进详情页前先切到该记录所属站点（不串站）`、`删除态下点卡片不跳详情页`、
`多选态下点卡片不跳详情页`、`删除会写删除标记`、`批量删除也写删除标记`、
`未勾选时「删除选中(0)」禁用`、`多选态下长按不切进删除态，已勾选不丢`、
`多选态下 Esc 退出并清空勾选`、`列数按内容区宽度算，不是整窗宽`、
`文字放大 1.5/2.0 倍时卡片不溢出`。

## 4. 变异测试证据（本轮最有价值的产出）

每个任务都做了变异自检。**Task 5/7 各抓到 1 个存活变异（真覆盖缺口）**，
其余为确认钉子有效。**合计 34 个变异，全部被杀死**。

| Task | 变异数 | 存活过的变异（已补钉子） |
| --- | --- | --- |
| 5 | 9 | **⑨ `columns` 写死成 3** — brief 的 4 条用例全绿（1400 宽下写死列数仍给出精确 2:3 海报）→ 补「列数随窗口宽自适应（1400→8、700→4）」 |
| 5 修复轮 | 3 | 无（A 去 clamp / B 换回 `MediaQuery` / C 只加 clamp 改回 M3 度量 —— 全部被杀，见 §5） |
| 6 | 6 | 无（①长按空实现 ②删除态走 `_resume` ③判定改用全量 ④不写删除标记 ⑤Esc 换 F12 ⑥不渲染遮罩） |
| 7 | 7 | **⑦ 批量删除后不退出多选态** — 原用例只断言 `recentHistory()` 空 + 空态文案 → 补「确认后退出多选态」（A10）+「列表空后两入口不渲染」（A12） |
| 8 | 6 | 无（①恒 detail ②恒 play ③不切站点 ④站点缺失静默 ⑤不传 flag/episodeId ⑥删除态也走分流） |

**共同模式**（与 plans/02 §4 同型）：用例只覆盖判据的**肯定面**，
「不做该动作」的反实现照样全绿（变异 ⑦ 最典型：不退出模式也满足原有断言）。

## 5. 修复轮的核心发现：`design/01` §2.2 的「复用」不止三条

首轮实现按 brief 原样落地后，**只复用了「同一套常量」这一条**，漏了另两条。
修复轮逐条补齐，并实测出**一条 brief 与专用文档都没写的事实**：

**只加 `withClampedTextScaling(1.25)` 不够 —— 文字度量必须同时对齐首页。**

| 度量 | 本征高度 | ×1.25 | 40px 文字区 |
| --- | --- | --- | --- |
| 首页 `_VodCard` 13/1.2 + 11/1.2 | 28.8px | 36.0px | ✅ 余 4px |
| M3 默认 14/1.43 + 12/1.33 | 35.98px | 44.98px | ❌ **溢出 5px** |

**独立复现**（controller 自跑，三轮变异）：

| 变异 | 实测结果 |
| --- | --- |
| A：去掉 clamp（`maxScaleFactor: 100.0`） | 1.5 溢出 **3px**、2.0 溢出 **17px** → 2 条用例失败 ✅ |
| B：`LayoutBuilder` → `MediaQuery.sizeOf` | 列数 6 → **7** → 列数用例失败 ✅ |
| C：**只**加 clamp 1.25、字号回 M3 默认 | 1.5 与 2.0 **都溢出 5px** → 2 条失败 ✅ |

变异 C 证明「偏离 brief 的字面值、改成首页的字号/行高」是**必要**的：
brief 原文的组合（clamp 1.25 + M3 度量）确实仍会溢出。
该结论已回填 `design/01` §2.2（把「文字度量同属第 1 条」写死）。

## 6. 实现过程中的计划缺陷（12 处，全部核实并修好）

| # | 任务 | 缺陷 | 谁发现 |
| --- | --- | --- | --- |
| 1 | T5 | `seedHistory` 默认 `vodId`/`episodeId` 恒定 → 3 次种子**塌成同一行**（唯一键 `(site_key,vod_id,flag,episode_id)`），RED 证据被污染 | implementer |
| 2 | T5 | `MediaQuery.sizeOf` 口径与 `design/01` §2.2 冲突（整窗 ≠ 内容区） | implementer + 审查裁定 |
| 3 | T5 | 卡片缺 `withClampedTextScaling`（无障碍放大溢出） | implementer + 审查裁定 |
| 4 | T5 | 「clamp 1.25 就够」是错的（见 §5） | 修复轮实测 |
| 5 | T6 | `_onCardLongPress` 缺 `multiSelect` 分支 → 多选态长按会切进删除态并清空已勾选（§3.1 状态图无这条边） | controller 预检 |
| 6 | T6 | **`design/01` §3.2 自相矛盾**（见 §7） | controller 预检 |
| 7 | T6 | brief 6 条用例无一条按 Esc（§3.1 与 A6 都要求） | controller 预检 |
| 8 | T7 | 「取消确认框不删除」的裸 `find.text('取消')` 命中 **2 个** widget（多选工具栏也有「取消」） | implementer |
| 9 | T8 | 三条用例都缺「配置前置」（`setUp` 无配置 → 第一条必红） | controller 预检 |
| 10 | T8 | `play` 用例挂死（`setHistoryClickAction` 真实写盘遇 fake-async） | implementer |
| 11 | T8 | 「没进详情页」是弱断言（「什么都没发生」也绿）→ 改断言真的发出 `play=` 请求 | controller |
| 12 | 各任务 | brief 的用例计数一律对不上（7/13/20/23 vs 实际 12/21/35/43） | 各任务 |

## 7. 关键裁定：`design/01` §3.2 自相矛盾（取「退出」）

**矛盾**：原文在同一节里对**同一场景**（搜索后可见 1 条 → 删掉它）给了两个相反结论：

- 句2：「可见列表为空 → **退出**删除态」；
- 句3：「删掉这 1 条**不应**退出（还有 9 条被搜索词挡着）」。

且句3 与句5「判定必须用 `_items`（过滤后）」**不可兼得**：
用 `_items` 判定 ⇒ 删掉可见最后一条后必然为空 ⇒ 必然退出。

**裁定：退出**。依据 3 条对 1 条：

1. `design/05` A11d（**验收判据**）只保留了退出条款；
2. 句5 是实现指令，用 `_items` 必然导出退出；
3. 句2 是本节**加粗的主规则**；
4. 上游 `HistoryActivity#onItemDelete` 是 `getItemCount() == 0 → setDelete(false)`
   （上游无搜索，`getItemCount()` 等价于全量）。

**UX 判据（决定性）**：若取句3，可见列表已空而删除态横幅仍在，屏幕会同时出现
「暂无播放记录」与「点击卡片即删除该条记录」——自相矛盾的界面，正是本文档
自己批判的反模式（「一个点了什么也没有的按钮比没有按钮更糟」）。

钉子：`删掉过滤后最后一条即退出（裁定：§3.2 句3 与句5 冲突，取句5）`——
改用 `state.recentHistory()`（全量）判空会让它失败（变异 ③ 已复现）。

## 8. 已知未闭合项（交最终验收裁定）

| # | 项 | 性质 | 影响 |
| --- | --- | --- | --- |
| 1 | `mvp_a_flow_test.dart:520` 既有红 | 既有偏差（先于 Phase 6） | 详情页断言，与本轮无关（已用回退实验证明）；导致 `:531` 的「清空历史」门禁在集成里**执行不到**（已由本文件的真实壳层截图用例替代取证） |
| 2 | 卡片不再显示「更新 <时间>」与「重播/继续播放」按钮 | 设计取舍 | `design/01` §2.1 的结构图不含这三者；删除改由长按/多选承担、播放改由整卡点击承担。**若产品需要保留更新时间需另行裁定** |
| 3 | `_historyTextScaleMax` 是新的文件私有常量（首页那份是内联字面量） | 风格 | 值与首页相同；若要求与首页一样内联可改 |
| 4 | `SettingsPage` 内 19 处间距仍为字面量 | 既有偏差（全文件层面） | 非本任务引入；`diagnostics_pages.dart` 全文件既有风格 |
| 5 | `setHistoryClickAction` 的 `Future<bool>` 在设置页被丢弃 | 既有模式 | 写盘失败静默、UI 仍显示新选择；与相邻主题区块同构 |
| 6 | `phase2_last_site_test` / `search_thread_test` / `phase2_ipc_test` / `phase5_sync_ui_test` 负载敏感 flaky | 既有 | 本阶段两次全量均未触发（1756/0、1764/0） |

## 9. 执行方式记录

- **就地执行**（未建 worktree）。
- **审查**：本阶段独立子代理派发**全部失败**（host npm 依赖缺失：
  `@earendil-works/pi-coding-agent` 未提供 `pi-agent-core/node`、`chord`、
  `chord/context`；报错 `Failed to start async run`；一次 `reviewer` 派发成功
  启动但该子代理**无 shell 工具**，无法跑变异）。
  → 按既有裁定（与 plans/02 Task 4–6 同型）：**controller 直接执行 + 自审**，
  且**每条关键论断都由 controller 自己跑变异复现**（见 §5），不采信实现者报告。
- **裁定共 2 条**（§5 的「度量对齐」、§7 的「退出」），均记录在
  `.superpowers/sdd/01-history-page/progress.md`。

## 10. 复现命令

```powershell
$env:GIT_CONFIG_COUNT=$null; $env:GIT_CONFIG_VALUE_0=$null; $env:GIT_CONFIG_VALUE_1=$null
cd C:\Users\Maple\orca\workspaces\webhtv-pc\dev1\apps\desktop-flutter

# 纯逻辑（35）
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_view_test.dart
# widget（43）
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase6_history_page_test.dart
# 回归门禁（39）
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test test/phase3_detail_page_test.dart test/phase2_playback_target_test.dart test/phase5_sync_ui_test.dart
# 全量
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test
# 静态分析
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' analyze

# L3：历史页片名门禁（需先起 fixture 服务）
python ..\..\tools\fixture_server\server.py
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test integration_test/phase5_sync_flow_test.dart -d windows
# L3：截图证据（不需要 fixture 服务）
& 'C:\Users\Maple\.puro\envs\webhtv\flutter\bin\flutter.bat' test integration_test/phase6_history_visual_flow_test.dart -d windows
```

> 跑 L3 会改写 `docs/phase5/evidence/android-sync.png`（runner 重新生成）；
> 已 `git checkout` 还原，未带入提交。
