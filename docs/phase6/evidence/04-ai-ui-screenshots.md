# Phase 6 · plans/04 阶段性证据（Task 5–8 + AI UI 截图）

- 计划：`docs/phase6/plans/04-ai-episode-season.md`
- 设计：`docs/phase6/design/04-ai-episode-season.md`
- 本轮范围：**Task 5–8**（响应解析与硬校验 → 分析服务与取消 → AI 设置页 → 季度弹窗 AI 项）
- 提交范围：`76292ad`（Task 5）→ `f8f6809`（Task 8）
- **尚未完成**：Task 9（端到端 L3）与收尾验证。本文件是阶段证据，不是 phase 终次验收。

## 1. 任务与提交

| Task | 内容 | 提交 | 该文件用例数 |
| --- | --- | --- | --- |
| 5 | 响应解析与 5 类硬校验（`§6.4`） | `76292ad` | 39 |
| 6 | 分析服务与取消（`§6.1`、`§6.6`） | `b5502bc` | 48 |
| 7 | AI 设置页与设置页入口（`§7.6`） | `16ee144` | 6 |
| 8 | 季度弹窗 AI 项 + 预览确认 + 应用（`§7`） | `f8f6809` | 11 |

## 2. 门禁结果

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| 全量单测 | `flutter test` | **1972 通过 / 0 失败** |
| 静态分析 | `flutter analyze` | 仅 1 条既有告警（`integration_test/phase6_history_visual_flow_test.dart` 未使用局部变量，非本轮引入、该文件本轮未改） |
| 季度弹窗既有门禁 | `flutter test test/phase4_tmdb_ui_test.dart` | **34/34 通过**（Task 8 曾一度打破，见 §4，已修实现、**未改门禁用例**） |
| 设置页既有门禁 | `flutter test test/phase5_sync_ui_test.dart` | 全绿 |
| phase6 AI 四文件 | `flutter test test/phase6_ai_config_test.dart test/phase6_ai_completion_test.dart test/phase6_ai_season_test.dart test/phase6_ai_settings_page_test.dart` | **152/152 通过** |

## 3. AI UI 截图复核（隔离 debug 实例）

按 `verify-webhtv-ui-by-screenshot` 流程执行：

- 环境：debug 包（`flutter build windows --debug`，**未打正式包**）
- 隔离：把 `%APPDATA%` / `%LOCALAPPDATA%` 重定向到临时副本；
  `sync.serverEnabled`/`pushEnabled` 置 false，清空 `devices`/`lastBridge`/`peers`
  与 `ui.lastSiteKey`；**移除 TMDB 凭据**（不借用用户 key）；缓存库删除
- 站点：`--config=packages/test-fixtures/config/config-e2e.json` +
  `--screenshot-ready-file`，上游为本地 fixture 服务（`127.0.0.1:18080`）
- 站点数据为真实 fixture 响应（首页渲染出「测试视频」卡片），非空态占位

| 截图 | 内容 | 结论 |
| --- | --- | --- |
| `ai-settings-entry.png` | 设置页「AI 助手」区块 | 位置在「历史记录」与「搜索」之间；标题层级与同级区块一致；摘要为「未配置：用于季度弹窗的「AI 识别剧集/季度」」；入口按钮为 tonal 样式，与「调整搜索线程」「打开 TMDB 设置」同构 |
| `ai-settings-page.png` | AI 设置页全字段 | AppBar「AI 助手」+ 返回；说明句完整；开关默认关；协议默认 OpenAI Responses，端点自动填 `https://api.openai.com/v1/responses`，模型自动填 `gpt-4.1-mini`（归一化生效）；API Key 空且带显示/隐藏切换；User-Agent（可选）空；三按钮为 2 outlined + 1 filled |

合规复核（Global Constraints）：无阴影、`elevation: 0`、颜色取自
`colorScheme`（无硬编码十六进制）、间距走 `AppSpace`、无 `w500`/`w600`。
两屏均**无溢出**、无布局跳动。

## 4. 本轮修正的设计/计划缺陷

1. **Task 5 成功用例夹具自相矛盾**：声明 5 集却把季号指向只有 3 集的 S1。
   `§6.4`「集数 > 该季集数」必判 `invalidSeason`，上游同实现
   （`expectedCount > seasonCounts.getOrDefault(...)`）→ 改夹具，实现不动。
2. **Task 6 同型夹具缺陷**（5 集 vs 3 集 S1）→ 改为 3 集恰好填满。
3. **Task 6 `_failureOf` 会把「HTTP 200 但无文本」谎报成 `http`** →
   对齐上游最终结论 `invalidJson`，并补用例钉住。
4. **Task 8 `line.displayName` 不存在**（`TmdbSourceLine` 只有 `sourceFlag`）。
5. **Task 8 返回值契约漏一处**：设计只列了 3 处，还需改 `tmdb_widgets.dart`
   的 `export ... show` 列表，否则类型静默解析不到。
6. **Task 8 取消路径会误弹详情页**：计划写「先 `maybePop()` 再判 canceled」，
   而取消时进度框已被取消按钮 pop 掉，`maybePop()` 弹掉的是详情页本身。
   改为仅非取消时才关闭进度框。
7. **弹窗内容区写死 `height: 360` 与新增 AI 项冲突**：AI 项把「各季」顶出可视区，
   打破 `phase4_tmdb_ui_test` 的「不滚动就能点到第 2 季」。
   改为 `shrinkWrap` 按内容定高、由 `AlertDialog` 可用空间封顶
   （800×600 下实测封顶 384px，第 2 季中心点仍在可视区内）。
   **未修改任何既有门禁用例。**

## 5. 尚未覆盖（明确缺口）

- **季度弹窗 AI 项 / 进度框 / 预览框的视觉与端到端行为未做真机复核**：
  进入季度弹窗需要 TMDB 匹配成功，而 fixture 站点标题是「测试视频」，
  不可被 TMDB 匹配；用真实 TMDB 又要借用用户凭据。
  该部分应由 **Task 9** 的 `integration_test/fixture_ai.dart`
  （兼作假 TMDB 服务端）覆盖，对应 `design/04` §8 的 D11–D15。
- Task 9 与收尾（全量门禁、回填 `docs/webhtv-pc-design.md` §27.12、更新阶段状态）未做。

## 6. 资源清理核实

- 隔离 debug 实例与 fixture 服务已停止；`18080` 无监听
- 临时隔离目录已删除
- **用户的 Release 实例 PID 自始至终为 16604（未被停止或改写数据）**
- 用户真实 `settings.json` 未被改动（`tmdb.apiKey` 仍在，`ai` 段仍不存在）
