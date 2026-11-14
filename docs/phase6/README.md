# Phase 6 计划（历史记录 / 详情页续播 / 季度与选集控件 / AI 集季识别）

- 状态：**已完成**（2026-10-16）
- 日期：2026-10-14（设计）／2026-10-17（实现与验收）
- 验收结论：四项能力（历史记录卡片化 / 点击行为可配置 / 详情页读历史续播 /
  季度与选集控件 + AI 集季识别）均已实现并取得证据。
  - `flutter test`：通过数随并发波动（**≈1960–1972 通过**），每次 4–5 条失败；
    失败**全部**落在既知 flaky 集合内（`phase2_ipc_test`、`phase5_sync_ui_test`、
    `cat_bundle_test` 的回环端口/子进程争用；`phase2_last_site_test` 文件锁；
    `phase3_jvm_spider_test` 的 JVM sidecar 争用），
    **均已逐条单独复跑核实全绿**（如 31/31、26/26、16/16、8/8、18/18）。
    判定按 `design/05` §7.1「失败集合 ⊆ 已知 flaky 集合」，
    本仓库全量门禁**无法达到 0 失败**，原文即如此修订。
    末次全量原始输出：`evidence/test-run.txt`。
  - `flutter analyze`：1 issue（既有、非本阶段引入，且在 plans/04 未改的文件里）；
    plans/04 改动文件单独 analyze：`No issues found!`。原文：`evidence/analyze.txt`。
  - L3：`phase6_ai_season_flow_test` 7/7（真窗口 + 真 HTTP + 真 SQLite）、
    `phase6_history_visual_flow_test` 6/6、`tmdb_detail_flow_test` 1/1。
  - 证据：`evidence/01-history-page.md`、`evidence/02-detail-resume-highlight.md`、
    `evidence/03-season-controls-paging.md`、`evidence/ai-ui-screenshots.md`、
    `evidence/ai-season-flow.md`（含判定与截图）、`evidence/ai-season-flow.txt`。
  - 实现过程中修正的既有缺陷：季度弹窗选择结果丢失（Phase 4 起，
    `showDialog<TmdbSeasonChoice>` 与弹窗 `pop` 类型不符导致结果恒为 `null`，
    详见 `evidence/ai-season-flow.md` §5）。
- 对应设计文档章节：本目录 `design/00`–`design/05`、`docs/webhtv-pc-design.md`
  §15（历史记录与收藏）、§17.2（页面清单）、§27.12（与上游的取舍，本轮修订）
- 上游：`docs/phase5/README.md`（Phase 5 已完成：安卓桥接）
- 上游参考工程：`webhtv/默影视`（Android，`F:\Workspace\webtv3\webhtv`）

---

## 0. 本阶段目标

把「历史记录页」「详情页续播」「季度与选集控件」三处对齐上游安卓的交互，
并补上 PC 端此前完全没有的 **AI 集季结构识别**能力。

四项能力：

| # | 能力 | 说明 |
| --- | --- | --- |
| 1 | **历史记录卡片化** | 海报网格卡片；长按进删除态（点谁删谁）；新增按钮进多选批量删除 |
| 2 | **点击行为可配置** | 新增设置：进详情页（默认）/ 直接播放 |
| 3 | **详情页读历史续播** | 首屏按钮从「播放第一集」改为读历史；线路与选集高亮最近播放 |
| 4 | **季度与选集控件** | 季度按钮常驻 + 选集分页 + AI 识别集季结构 |

**不可退让的边界**（详见 `design/00` §4）：

- **P1 AI 可选**：未配置时绝不阻塞任何现有路径。
- **P2 AI 必经确认**：不存在"自动应用 AI 判断"的路径。
- **P3 注入防护**：集名是不可信数据，提示词必须显式声明。
- **P4 删除态有出口**：任何模式都不得出现"无法退出"的状态。
- **P5 批量删除必确认**：一次删多条必须写明条数并二次确认。
- **P6 不破坏测试锁定结构**：`OutlinedButton` 剧集卡、`ChoiceChip` 线路 chip、
  `detail-hero-play` 等 `ValueKey` 字面值。

---

## 1. 现状盘点

### 1.1 缺口

| 缺口 | 设计依据 | 现状 |
| --- | --- | --- |
| 历史页是单列 `ListTile` | `design/01` §1 | `library_pages.dart` 的 `ListView.builder` |
| 无长按删除态 | `design/01` §3 | 每行一个删除 `IconButton`，点击即删 |
| 无批量删除 | `design/01` §3 | 无任何多选机制 |
| 点击行为不可配 | `design/01` §4 | 固定直接续播 |
| 首屏按钮硬编码「播放第一集」 | `design/02` §3 | `browse_pages.dart` 第 1306–1315 行 |
| 选集卡片无历史标记 | `design/02` §6 | `TmdbEpisodeCardTile` 无 `isRecent` |
| 线路 chip 无「最近播放」标记 | `design/02` §5 | `TmdbLineSelector` 只有 `selected` |
| 季度按钮只在未确定时出现 | `design/03` §2 | `tmdb_widgets.dart` 第 246 行 |
| 无选集分页 | `design/03` §4 | `TmdbEpisodeStrip` 只有横向滚动 |
| 两页季度 UI 不一致 | `design/03` §3 | 站点页 chip 条 / 纯 TMDB 页海报卡片条 |
| 无 AI 配置 | `design/04` §3 | 全仓库无 AI 相关代码 |
| 无 AI 补全客户端 | `design/04` §5 | 无 |
| 无 AI 集季分析 | `design/04` §6 | 无 |

### 1.2 已具备（可复用的基础）

| 能力 | 位置 | 本阶段如何复用 |
| --- | --- | --- |
| 季度解析器（14 级判定） | `lib/core/tmdb_season.dart` | 直接复用，AI 结果也走同一套绑定模式 |
| 季度绑定弹窗 | `lib/ui/tmdb_widgets.dart` | 加 AI 项 |
| 线路季度记忆 | `lib/state/tmdb_state.dart` | 不动 |
| 历史查询 | `lib/state/app_state.dart#findHistory` | 详情页读历史 |
| 续播位置判定 | `lib/state/app_state.dart#resumePositionFor` | 首屏按钮复用，不重复实现 |
| 海报网格度量 | `lib/ui/browse_pages.dart#_gridDelegate` | 历史页复用同一套算法 |
| 设置持久化模式 | `lib/services/ui_preferences_store.dart` | 新增 `historyClickAction`；AI 配置仿 `TmdbConfigStore` |
| 凭据脱敏 | `lib/core/tmdb_config.dart#redactCredential` | AI Key 脱敏 |
| 假 HTTP 客户端模式 | `test/phase4_tmdb_ui_test.dart#_FakeClient` | AI 补全测试 |

---

## 2. 实施顺序

**依赖关系**：A 与 C 独立；B 依赖 A（历史页要能进详情页）；D 依赖 C（季度控件先稳定）。

| # | 任务 | 依赖 | 产出 |
| --- | --- | --- | --- |
| T1 | `lib/core/history_view.dart`：删除模式状态机 + 卡片模型 + 点击行为归一化 | — | L1 测试绿 |
| T2 | `lib/core/history_view.dart`：历史解析（线路三级匹配 + 集匹配 + 歧义） | — | L1 测试绿 |
| T3 | `UiPreferencesStore` 新增 `historyClickAction` + `AppState` 暴露 | — | L1 测试绿 |
| T4 | 设置页新增「历史记录」区块 | T3 | L2 测试绿 |
| T5 | 历史页改卡片网格 | T1 | L2 测试绿 |
| T6 | 历史页两种删除模式 | T1、T5 | L2 测试绿 |
| T7 | 历史页点击分流（详情页 / 播放） | T3、T5 | L2 测试绿 |
| T8 | `DetailPage` 接受 `historyFlag` / `historyEpisodeId` | T2 | L2 测试绿 |
| T9 | 首屏按钮读历史（文案 + 目标集） | T2、T8 | L2 测试绿 |
| T10 | 打开详情页自动切历史线路 | T8 | L2 测试绿 |
| T11 | 线路 chip「最近播放」标记 | T2 | L2 测试绿 |
| T12 | 选集卡片「上次看到这里」标记 | T2 | L2 测试绿 |
| T13 | `lib/core/episode_range.dart`：区间分组 | — | L1 测试绿 |
| T14 | 季度按钮常驻 + 文案随上下文 | — | L2 测试绿 |
| T15 | 季度 UI 统一为 chip 条（含既有测试更新） | T14 | L2 测试绿 |
| T16 | 选集区间条 + 自动滚入视野 | T13 | L2 测试绿 |
| T17 | 切季行为（重置到第一集 + 过滤为空回退） | T16 | L2 测试绿 |
| T18 | `lib/core/ai_config.dart` + `ai_config_store.dart` | — | L1 测试绿 |
| T19 | `ai_completion_client.dart`（4 协议请求 + 响应抽取） | T18 | L2 测试绿 |
| T20 | `ai_episode_season_service.dart`（采样 + 提示词 + 解析 + 校验） | T19 | L1/L2 测试绿 |
| T21 | AI 设置页 | T18、T19 | L2 测试绿 |
| T22 | 季度弹窗加 AI 项 + 分析进度 + 预览确认 + 应用 | T20、T21 | L2 测试绿 |
| T23 | L3 集成测试三个 flow | 全部 | L3 测试绿 |
| T24 | 证据产出（截图多宽高比 + 测试输出） | T23 | `docs/phase6/evidence/` |
| T25 | 回填主设计文档 §27.12 取舍修订 + 本 README 状态 | T24 | 文档一致 |

### 2.1 建议的提交粒度

每个任务一个提交，提交信息用中文并带设计文档章节号，与既有风格一致：

```text
新增：历史视图状态机（design/01 §3）
修复：历史页卡片化后片名重复渲染（design/01 §2.3）
测试：锁定选集区间分组的倒序语义（design/03 §4.1）
```

---

## 3. 验收门禁

见 `design/05` §7。摘要：

1. `flutter analyze` 零警告；
2. `flutter test` 全绿（含全部回归门禁）；
3. `flutter test integration_test/ -d windows` 全绿；
4. 证据文件全部产出，截图多宽高比；
5. 主设计文档 §27.12 修订回填；
6. 本 README 状态更新。

---

## 4. 与 Phase 5 的衔接

Phase 5 引入的 `history_deletions` 删除标记表与本轮的历史删除直接相关：

- 单条删除（长按删除态）走既有 `database.deleteHistory(id)`，**已**会写删除标记；
- 批量删除必须**逐条**调 `deleteHistory(id)`，**不得**新增"批量 SQL 删除"路径——
  否则会漏写删除标记，安卓下次推来旧记录就会复活被删的条目
  （`docs/phase5/design/02` §4.5）。

这条是本轮与 Phase 5 唯一的耦合点，实现时必须遵守。
