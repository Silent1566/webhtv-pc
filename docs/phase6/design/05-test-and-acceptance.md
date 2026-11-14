# 05 · 测试与验收设计

- 状态：设计指导，**待评审**
- 日期：2026-10-14
- 上游参考：Phase 1–5 的门禁与证据机制（`docs/phase1/README.md` §7、
  `docs/phase2/README.md` §3、`docs/phase3/README.md` §3、
  `docs/phase4/design/05`、`docs/phase5/design/03`）
- 关联：`00`、`01`、`02`、`03`、`04`
- PC 端落点：`apps/desktop-flutter/test/phase6_*.dart`、
  `apps/desktop-flutter/integration_test/phase6_*_flow_test.dart`、
  `tools/phase6/**`、`docs/phase6/evidence/**`

---

## 1. 测试分层

沿用 Phase 3/4/5 的三层结构，**不引入新机制**：

| 层 | 位置 | 真实网络 | 真实窗口 | 运行命令 |
| --- | --- | --- | --- | --- |
| L1 纯逻辑单测 | `test/phase6_*_test.dart` | ❌（全内存） | ❌ | `flutter test` |
| L2 契约与服务 | `test/phase6_*_test.dart`（注入 fake HTTP client） | ❌ | ❌ | `flutter test` |
| L3 集成 | `integration_test/phase6_*_flow_test.dart` | ✅（本地 fixture 服务） | ✅（`-d windows`） | `flutter test integration_test/... -d windows` |

**分层原则**（对齐 Phase 3/4/5）：

- L1 必须能在**无网络、无窗口**下全绿，覆盖全部算法与边界；
- L2 用**请求捕获**断言请求形态（URL、方法、请求体字段、鉴权头），不只断言最终结果；
- L3 只验证「真实窗口 + 真实 HTTP + 真实 SQLite」的端到端串联，**不重复** L1/L2 的边界用例。

### 1.1 本轮特有的分层约束

| 约束 | 理由 |
| --- | --- |
| AI 相关测试**一律不得**发真实请求 | 门禁必须能离线全绿；用注入的 `http.Client` 捕获请求 |
| AI 提示词与响应解析必须有 L1 覆盖 | 硬校验逻辑多、边界密，是最容易出错的部分 |
| 删除模式状态机必须有 L1 覆盖 | 纯逻辑，且是"点谁删谁 vs 只勾选"这类易错语义 |
| 选集分页必须有 L1 覆盖 | `remainder` 倒序逻辑与阶梯分组是纯算法 |
| 历史解析（线路/集匹配）必须有 L1 覆盖 | 三级匹配 + 歧义判定是纯逻辑 |
| 截图证据必须**多宽高比** | `DESIGN.md` 的验证纪律：背景/铺满类改动必须在 1.6:1 / 2.0:1 / 2.35:1 各出一张 |

---

## 2. 新增测试文件

| 文件 | 层 | 覆盖 |
| --- | --- | --- |
| `test/phase6_history_view_test.dart` | L1 | 删除模式状态机 + 卡片模型 + 点击行为归一化 |
| `test/phase6_history_resume_test.dart` | L1 | 线路三级匹配 + 集匹配 + 歧义判定 + 按钮文案决策 |
| `test/phase6_episode_range_test.dart` | L1 | 区间分组阶梯 + 倒序 `remainder` + 切片 + 选中定位 |
| `test/phase6_ai_config_test.dart` | L1 | 配置归一化 + 端点归一化 + 就绪判定 + 脱敏 |
| `test/phase6_ai_completion_test.dart` | L2 | 4 协议请求体与鉴权头 + 4 种响应抽取 + 交叉兜底 |
| `test/phase6_ai_season_test.dart` | L1/L2 | 采样 + 提示词 + 响应解析 + 5 类硬校验 + 取消 |
| `test/phase6_history_page_test.dart` | L2 | 网格渲染 + 长按进删除态 + 点卡即删 + 多选批量删 |
| `test/phase6_detail_resume_test.dart` | L2 | 首屏按钮文案与目标 + 自动选线路 + 高亮标记 |
| `test/phase6_season_controls_test.dart` | L2 | 季度按钮常驻与文案 + 弹窗 AI 项 + 区间条 |
| `integration_test/phase6_history_flow_test.dart` | L3 | 真实 SQLite：写入历史 → 历史页卡片 → 删除 → 落盘 |
| `integration_test/phase6_detail_resume_flow_test.dart` | L3 | 真实 HTTP：历史 → 详情页 → 按钮文案 → 播放目标 |
| `integration_test/phase6_ai_season_flow_test.dart` | L3 | 真实 HTTP：假 AI 服务端 → 弹窗 → 分析 → 预览 → 应用 |

---

## 3. 回归门禁（**必须继续绿**）

本轮会改动以下既有测试锁定的结构，逐条列出**不得破坏**的断言：

| 测试文件 | 锁定的内容 | 本轮风险 |
| --- | --- | --- |
| `test/phase3_detail_page_test.dart` | `ValueKey('detail-hero-play')` 存在 | 首屏按钮改造 |
| `test/phase4_tmdb_ui_test.dart` | `tmdb-season-context` / `tmdb-season-switcher` / `tmdb-season-N` / `tmdb-choose-season` / `tmdb-season-option-N` / `tmdb-season-auto` | 季度按钮常驻 + 弹窗加项 |
| `test/phase4_tmdb_detail_view_test.dart` | `tmdb-section-seasons` / `tmdb-episode-header` / `tmdb-episode-reverse` / `tmdb-episode-view-mode`（**仅这几个 key 与其交互**） | 季度 UI 统一 + 区间条 |
| `integration_test/tmdb_detail_flow_test.dart` | `tmdb-season-2` chip 可点 | 季度 UI 统一 |
| `integration_test/mvp_a_flow_test.dart` | `find.text('清空历史')` | 历史页改造 |
| `integration_test/phase5_sync_flow_test.dart` | 历史页 `find.text(name)` == `findsOneWidget` | 卡片化后文字数量 |
| `test/phase2_playback_target_test.dart` | `restoreHistoryPlaybackTarget` 行为 | 历史页改造 |
| `test/phase4_tmdb_progress_test.dart` | 季度进度与来源 history 的关系 | 不涉及（本轮不改进度写入） |

**已确认会变更的既有测试**（有意变更，需在提交信息写明理由）：

| 测试文件 | 变更 | 理由 |
| --- | --- | --- |
| `test/phase4_tmdb_detail_view_test.dart` | 季度**海报卡片条**断言（`tmdb-season-card-*` / `tmdb-season-strip`）→ chip 条断言 | 用户要求统一季度 UI |
| `integration_test/tmdb_detail_visual_flow_test.dart` | 截图基线更新 | 同上 |

> 上表与 §3 的「必须继续绿」表**不冲突**：同一文件里，`tmdb-section-seasons` /
> `tmdb-episode-*` 这些 key 与交互必须保留，只有季度卡片条的形态断言会变。

---

## 4. 关键验收用例

### 4.1 历史页（子系统 A）

| # | 用例 | 层 |
| --- | --- | --- |
| A1 | 网格渲染，卡片数 == 历史条数 | L2 |
| A2 | 每张卡片只渲染一次片名 `Text` | L2 |
| A3 | 长按 → 删除态（遮罩 + 顶部「完成」） | L2 |
| A4 | 删除态点卡片 → 删该条，仍在删除态 | L2 |
| A5 | 删除态删最后一条 → 自动退出 | L2 |
| A6 | Esc / 返回 / 再次长按 → 退出，不删 | L2 |
| A7 | 「批量删除」→ 多选态（复选框） | L2 |
| A8 | 多选态点卡片只勾选，不删 | L2 |
| A9 | 「全选」+「删除选中(N)」确认框写明 N | L2 |
| A10 | 确认后 N 条删除，退出多选态 | L2 |
| A11 | 搜索词变化清空已选 | L1+L2 |
| A11b | 搜索词未变化时不清空已选 | L1 |
| A11c | `singleDelete` 下搜索词变化不退出删除态 | L1 |
| A11d | 删除态删掉"过滤后最后一条"即退出（可见列表为空） | L2 |
| A12 | 空列表时两个入口都不渲染 | L2 |
| A13 | `historyClickAction=detail` → 进详情页 | L2 |
| A14 | `historyClickAction=play` → 直接续播 | L2 |
| A15 | 站点不在配置中 → 可见提示 | L2 |
| A16 | 真实 SQLite：删除后落盘且不复活 | L3 |

### 4.2 详情页续播与高亮（子系统 B/C）

| # | 用例 | 层 |
| --- | --- | --- |
| B1 | 无历史 → 「播放第一集」 | L1+L2 |
| B2 | 命中 → 「继续播放 · <集名>」+ 播那一集 | L1+L2 |
| B3 | 已看完 → 回到「播放第一集」 | L1 |
| B4 | 位置过短 → 同上 | L1 |
| B5 | 历史线路不存在 → 退回第一条 | L1 |
| B6 | 集 URL 多线路命中 → 歧义 → 退回第一条 | L1 |
| B7 | 打开详情页自动切到历史线路 | L2 |
| B8 | 线路 chip 有「最近播放」标记且仍可切换 | L2 |
| B9 | 选集卡片有「上次看到这里」标记，外壳仍 `OutlinedButton` | L2 |
| B10 | 剧照仍 16:9 | L2 |
| B11 | `detail-hero-play` key 仍存在 | L2 |
| B12 | 从历史页进详情页时站点已先切换 | L3 |

### 4.3 季度与选集分页（子系统 D 非 AI）

| # | 用例 | 层 |
| --- | --- | --- |
| C1 | 已匹配 tv → 季度按钮常驻 | L2 |
| C2 | 选中季之后仍可改绑 | L2 |
| C3 | 解析不出 → 「选择季度」 | L2 |
| C4 | 电影 → 不渲染 | L2 |
| C5 | 未匹配 → 不渲染 | L2 |
| C6 | 弹窗选项带集数 + 当前项高亮 | L2 |
| C7 | 两页季度 UI 都是 chip 条 | L2 |
| C8 | ≤60 集 → 每页 20 | L1 |
| C9 | 400 集 → 每页 50，8 个区间 | L1 |
| C10 | 倒序 `remainder` 落在最前 | L1 |
| C11 | 区间标签用真实集号 | L1 |
| C12 | 手动选区间后切集不重置 | L2 |
| C13 | 未手动选时区间跟随选中集 | L1 |
| C14 | 选中区间自动滚入视野 | L2 |
| C15 | 分页只改渲染，播放用原始下标 | L2 |
| C16 | 切季重置到该季第一集所在区间 | L2 |
| C17 | 过滤为空 → 回退全部集 | L1 |
| C18 | 区间数为 1 → 不渲染区间条 | L2 |

### 4.4 AI（子系统 D AI）

| # | 用例 | 层 |
| --- | --- | --- |
| D1 | 4 协议请求体与鉴权头正确 | L2 |
| D2 | 端点归一化 4 种形态 | L1 |
| D3 | 4 种响应结构各自抽取 | L2 |
| D4 | 协议选错时交叉兜底 | L2 |
| D5 | 采样上限 80 + 等距 + 截断 120 | L1 |
| D6 | `sourceTruncated` → 拒绝 `EXPLICIT_MAPPING` | L1 |
| D7 | 提示词首句含注入防护 | L1 |
| D8 | 季号非法 → `invalidSeason` | L1 |
| D9 | 映射不全 → `unsafeFlatMapping` | L1 |
| D10 | 季集号非递增 → `invalidMapping` | L1 |
| D11 | `EXPLICIT_MAPPING` 只预览 | L2 |
| D12 | 未配置 → 弹窗 AI 项引导去设置，**且不误清已有绑定** | L2 |
| D12b | `TmdbSeasonAiSettings` 不落进 `bindTmdbSeason`（`04` §7.1.1） | L2 |
| D13 | 快照不一致 → 拒绝应用 | L2 |
| D14 | `FLAT_BY_COUNTS` 应用前再校验 | L2 |
| D15 | 取消不改绑定 | L2 |
| D16 | Key 不进日志 | L1 |
| D17 | 落盘在 `ai` 段，不污染其他段 | L2 |
| D18 | 非法值归一 | L1 |
| D19 | 假 AI 服务端端到端：分析 → 预览 → 应用 | L3 |

---

## 5. fixture 设计

### 5.1 假 AI 服务端

`integration_test/fixture_ai.dart`：本地 `HttpServer`，按路径返回预置响应。

| 路径 | 行为 |
| --- | --- |
| `/v1/chat/completions` | 返回 OpenAI chat 形态，内容为预置 JSON |
| `/v1/responses` | 返回 OpenAI responses 形态 |
| `/v1/messages` | 返回 Anthropic 形态 |
| `/v1beta/models/<m>:generateContent` | 返回 Gemini 形态 |
| `/v1/models` | 返回模型列表 |
| 任意 + `?fail=1` | 返回 500 |

预置响应覆盖 4 种 mode 各一份，以及 5 类失败各一份。

### 5.2 历史 fixture

复用 `packages/test-fixtures/android/history-android.json`（Phase 5 已有），
它含真实 `History[]` 形态。新增一份 `history-multi-line.json`：
同一 `vodId` 下两条不同 `flag` 的记录，用于验证「历史线路 ≠ 当前线路」。

---

## 6. 证据产出

| 文件 | 内容 |
| --- | --- |
| `docs/phase6/evidence/history-cards.png` | 历史页卡片网格（暗色，1440×900） |
| `docs/phase6/evidence/history-delete-mode.png` | 删除态（遮罩 + 完成按钮） |
| `docs/phase6/evidence/history-multi-select.png` | 多选态（复选框 + 已选 N） |
| `docs/phase6/evidence/history-cards-r235x1.png` | 2.35:1 宽高比（验证列数自适应） |
| `docs/phase6/evidence/detail-resume-button.png` | 详情页「继续播放 · <集名>」 |
| `docs/phase6/evidence/detail-recent-highlight.png` | 线路 chip + 选集卡片的「最近播放」标记 |
| `docs/phase6/evidence/season-button.png` | 季度按钮常驻 |
| `docs/phase6/evidence/episode-ranges.png` | 选集区间条（长剧集） |
| `docs/phase6/evidence/ai-settings.png` | AI 设置页 |
| `docs/phase6/evidence/ai-season-preview.png` | AI 分析结果预览确认框 |
| `docs/phase6/evidence/test-run.txt` | `flutter test` 完整输出 |
| `docs/phase6/evidence/analyze.txt` | `flutter analyze` 输出 |

截图由集成测试的 `RepaintBoundary → toImage → PNG` harness 产出
（与 Phase 0–5 一致），**不是** widget 树的重描述。

---

## 7. 验收门禁

实现完成的判定条件（缺一不可）：

1. `flutter analyze` **零警告**；
2. `flutter test` **通过**，判定标准是「**失败集合 ⊆ 已知 flaky 集合**」
   （见 §7.1），不是「0 失败」；
3. `flutter test integration_test/ -d windows` **通过**（同样按 §7.1 判定）；
4. 证据文件全部产出，截图**多宽高比**；
5. `docs/webhtv-pc-design.md` §27.12 的取舍修订已回填；
6. `docs/phase6/README.md` 状态更新为「已完成」并附验收结论。

### 7.1 全量门禁的判定标准（2026-10-14 修订）

**原标准「0 失败」在本仓库上无法达成**，实测证据（Phase 6 plans/02 Task 3）：

| 轮次 | 树状态 | 结果 |
| --- | --- | --- |
| 基线 | **干净**（`git stash` 掉全部改动） | 1667 通过 / **2 失败** |
| run 1 | 含改动 | 1669 / **4** |
| run 2 | 含改动 | 1673 / **0** |
| run 3 | 含改动 | 1674 / **0** |
| run 4 | 含改动 | 1674 / **0** |
| run 5 | 含改动（22 用例） | 1674 / **1** |

失败数在**同一份代码**上漂移 2 → 4 → 0 → 0 → 0 → 1，且失败的四个文件
（见下表）与本轮改动**无依赖**（不引用 `browse_pages` / `DetailPage` /
`history_view`），单独跑**全过**。全量跑约 6–10 分钟、并行度高，
这些用例对负载敏感。

**已知 flaky 集合及其证据**（每个失败项都单独复跑过）：

| 测试文件 | 观察到的失败 | 单独复跑 |
| --- | --- | --- |
| `phase2_last_site_test` | run 1、基线 | `+8` 全过 |
| `search_thread_test` | run 1 | `+11` 全过 |
| `phase2_ipc_test` | 基线 | 全过 |
| `phase5_sync_ui_test` | run 5（「导入时带回直播源并落进配置记录」） | `+26` 全过 |

**判定规则**：

```text
全量通过 ⟺ 失败集合 ⊆ {phase2_ipc_test, phase2_last_site_test,
                      search_thread_test, phase5_sync_ui_test}
          且每个失败测试「单独跑」通过
```

「单独跑通过」是必要条件——它把「真回归」与「flaky」区分开。
若某个失败测试单独跑**也**失败，那就是真回归，门禁不通过。

**为什么不用「0 失败」**：一个无法达成的标准会逼出「为了绿灯而改测试」的坏激励，
比允许一个已记录的 flaky 集合危险得多。

**已知 flaky 集合的维护**：发现新的 flaky 必须**在上表追加一行**
（测试文件 + 观察到的失败轮次 + 单独复跑结果），并附失败输出到证据文件。
不得只改判定而不留证据。

---

## 8. 已知风险

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 季度 UI 统一打破 `phase4_tmdb_detail_view_test` | 测试红 | 有意变更，同步更新断言并在提交信息写明理由 |
| 历史卡片化打破 `phase5_sync_flow_test` 的 `findsOneWidget` | 测试红 | 卡片只渲染一次片名 `Text`（§2.3 of `01`） |
| 区间条增加页面高度，把控件挤出 800×600 测试视口 | `tester.tap` 打空 | 区间条仅在区间数 > 1 时渲染；测试用 `ensureVisible` |
| AI 提示词注入 | 安全 | 首句声明不可信样本；本地扫描的集号序列作为可信输入 |
| AI 结果异步竞态 | 写错线路 | 应用前校验快照（`04` §7.5） |
| `settings.json` 并发写 | 丢配置 | 复用 `UiPreferencesStore` 的串行化写盘队列模式 |
