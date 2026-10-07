# Phase 4 计划（TMDB 元数据增强）

- 状态：**设计指导已补齐，待实施**
- 日期：2026-10-06
- 对应设计文档章节：本目录 `design/00`–`design/05`、`docs/webhtv-pc-design.md` §27（TMDB 元数据增强）、§21 Phase 4
- 上游：`docs/phase3/README.md`（Phase 3 已完成：直播 / 字幕 / 弹幕 / 解析器 / EPG / JS Spider / PC Java Spider / 猫源）
- 上游参考工程：`webhtv/默影视`（Android）

---

## 0. 本阶段目标

把 TMDB 从「PC 端完全没有」升级为「与 `webhtv/默影视` 等价的**元数据增强**能力」，
并**先把设计指导文档补齐**，再进入实施。设计文档是本阶段的第一等交付物。

四项能力：

1. **媒体身份匹配**：站源 `Vod` → TMDB 作品（`mediaType + tmdbId`），含手动匹配与持久化。
2. **季度解析与可播放季度**：线路级季度绑定、显式三态 `SeasonScope`、可播放季度过滤。
3. **季度进度与续播**：按季度保存/恢复播放位置，跨源换源续播。
4. **详情页元数据增强**：头部补位、季度选择器、剧集标题/剧照、演职人员、相关推荐与相关视频。

**不可退让的边界**（详见 `design/00` §3）：

- 元数据源 ≠ 播放事实源：TMDB 只丰富播放项，**不创建播放项**。
- 不确定即未知：`SeasonScope` 显式三态，**禁止默认第一季**。
- 安全退化优先：TMDB 失败不阻塞浏览与播放，不覆盖已保存绑定，不跨季恢复错误进度。
- 主进程不加载不可信代码；凭据不外泄。

---

## 1. 现状盘点

### 1.1 缺口（TMDB 完全缺失）

| 缺口 | 设计文档依据 | 现状 |
| --- | --- | --- |
| 无 TMDB 配置 | `design/03` §5 | `settings.json` 尚无用例；`TmdbConfig` 等价物不存在 |
| 无 TMDB 服务 | `design/03` §4 | 无端点封装、无 TTL、无熔断、无错误分类 |
| 无媒体身份 | `design/01` §2 | `Vod` 无 TMDB 字段；无匹配缓存 |
| 无标题清洗/评分 | `design/01` §3/§5 | 无标题归一、无相似度评分、无分季变体防护 |
| 无站点策略 | `design/01` §6 | 无 `enabledSites`/`disabledSites`/`allowedSites` |
| 无季度模型 | `design/02` §2 | 无 `SeasonScope`、无 `SeasonSegment`、无来源指纹 |
| 无季度解析 | `design/02` §3/§4 | 无解析器、无可播放季度、无切片 |
| 无季度绑定 | `design/02` §5 | 无线路级绑定、无失效与升级策略 |
| 无季度进度 | `design/02` §6 | `history` 只有来源维度，一个来源覆盖多季时只有一份进度 |
| 无 TMDB 存储 | `design/03` §6 | `schemaVersion = 1`，无 TMDB 表 |
| 无 TMDB UI | `design/04` | 详情页无 TMDB 区块、无季度选择器、无手动匹配入口 |
| 无相关视频 | `design/04` §7 | 无 `TmdbVideo` 模型与打开方式 |
| 无播放入口透传 | `design/04` §8 | 播放页不接收季度身份与 `episodeUrl` 消歧参数 |

### 1.2 已具备（可复用的基础）

| 能力 | 位置 | TMDB 如何复用 |
| --- | --- | --- |
| HTTP 客户端与错误模型 | `lib/core/http_api.dart`、`lib/core/app_error.dart` | 新增 `tmdb*` 错误类别，沿用同一归一化与脱敏机制 |
| SQLite 与迁移机制 | `lib/services/storage.dart` | 新增 4 张表；`schemaVersion` 1 → 2，幂等建表 |
| 缓存目录与平台路径 | `lib/services/app_paths.dart` | `<cacheDir>/tmdb/`；`settingsPath` 首次启用 |
| 日志与脱敏 | `lib/services/log_service.dart` | 凭据脱敏、请求日志 |
| 详情页与竞态处理 | `lib/ui/browse_pages.dart`、Phase 3 的详情竞态门禁 | TMDB 区块挂在既有详情页；沿用代际（generation）机制 |
| 播放页与续播 | `lib/ui/player_page.dart`、`lib/state/app_state.dart` | 透传季度身份；沿用 `resumeThreshold` 与进度写入 |
| 历史与收藏 | `lib/services/storage.dart`、`lib/ui/library_pages.dart` | 新增季度投影，**不改** `history` 主键 |
| 搜索页 | `lib/ui/search_page.dart` | 纯 TMDB 详情页的"搜索站源"入口 |
| fixture 服务 | `tools/fixture_server/server.py` | 新增 `/tmdb/**` 路由与 `/tmdb/__stats` 计数器 |
| 一键验收脚本 | `tools/phase3/run_windows_acceptance.ps1` | 复制结构为 `tools/phase4/run_windows_acceptance.ps1` |

---

## 2. 实施顺序

### 2.1 文档阶段（本阶段先行，已完成）

| # | 任务 | 产出 | 验收 |
| --- | --- | --- | --- |
| D1 | 总索引与上游取舍 | `design/00-tmdb-design-index.md` | 四条原则、上游取舍表、章节映射、决策记录齐备 |
| D2 | 身份与匹配 | `design/01-tmdb-identity-and-matching.md` | 三层键、13 步清洗、三级选择、分季四档、站点 7 条判定 |
| D3 | 季度解析与进度 | `design/02-tmdb-season-resolution-and-progress.md` | 三态 `SeasonScope`、15 步解析、6 级可播放季度、8 条分段校验 |
| D4 | 服务、配置与存储 | `design/03-tmdb-service-config-storage.md` | 端点清单、TTL 表、熔断、13 条归一化、4 张表、迁移策略 |
| D5 | 详情页与播放 | `design/04-tmdb-detail-ui-and-playback.md` | 状态条 6 态、补位 8 字段、季集联动、播放入口 7 参数 |
| D6 | 测试与验收 | `design/05-tmdb-test-and-acceptance.md` | L1/L2/L3 分层、fixture 清单、门禁表、一键验收 |
| D7 | 主设计文档回填 | `docs/webhtv-pc-design.md` §27 + §21 Phase 4 + §17.2 + §22.1 + §23 + §26 | 章节号连续、交叉引用可解析 |
| D8 | TMDB 配置 Schema | `packages/protocol/schema/tmdb-config.schema.json` | 三个 fixture 校验通过（含反向验证） |

### 2.2 实施阶段（待评审通过后启动）

| # | 任务 | 产出 | 验收 |
| --- | --- | --- | --- |
| T1 | 纯逻辑：标题与评分 | `lib/core/tmdb_title.dart` | `phase4_tmdb_title_test.dart`、`phase4_tmdb_match_policy_test.dart` |
| T2 | 纯逻辑：身份与缓存键 | `lib/core/tmdb_identity.dart` | `phase4_tmdb_cache_test.dart` |
| T3 | 纯逻辑：站点策略 | `lib/core/tmdb_config.dart` | `phase4_tmdb_site_policy_test.dart`、`phase4_tmdb_config_test.dart` |
| T4 | 纯逻辑：季度模型与解析 | `lib/core/tmdb_season.dart` | `phase4_tmdb_season_resolver_test.dart`、`phase4_tmdb_available_seasons_test.dart`、`phase4_tmdb_segment_test.dart` |
| T5 | 纯逻辑：图片与视频模型 | `lib/core/tmdb_media.dart` | `phase4_tmdb_image_selector_test.dart` |
| T6 | 服务：HTTP 与缓存 | `lib/services/tmdb_service.dart`、`lib/services/tmdb_cache.dart` | `phase4_tmdb_service_test.dart` |
| T7 | 服务：匹配与季度编排 | `lib/services/tmdb_identity_service.dart`、`lib/services/tmdb_season_service.dart` | 组合用例 + 落盘断言 |
| T8 | 服务：元数据应用 | `lib/services/tmdb_enrichment_service.dart` | `phase4_tmdb_episode_metadata_test.dart` |
| T9 | 存储：4 张表与迁移 | `lib/services/storage.dart` | `phase4_tmdb_storage_test.dart` |
| T10 | 状态层 | `lib/state/tmdb_state.dart` | 代际、加载阶段、错误隔离 |
| T11 | 详情页 TMDB 区块 | `lib/ui/tmdb_widgets.dart` | `phase4_tmdb_ui_test.dart` 状态条与头部补位 |
| T12 | 季度选择器与选集联动 | `lib/ui/tmdb_widgets.dart`、`lib/ui/browse_pages.dart` | 选集数量断言；不补集、不丢集 |
| T13 | 手动匹配与季度绑定弹窗 | `lib/ui/tmdb_widgets.dart` | 弹窗用例 7/8 |
| T14 | 纯 TMDB 详情页 | `lib/ui/tmdb_detail_page.dart` | 无播放按钮；跳搜索页 |
| T15 | 播放入口透传与续播 | `lib/ui/player_page.dart`、`lib/state/app_state.dart` | `episodeUrl` 优先级；换源续播 |
| T16 | 设置页 TMDB 区块 | `lib/ui/config_pages.dart` | Key 掩码、测试连接、重置默认规则 |
| T17 | 历史/换源/删除的季度化 | `lib/ui/library_pages.dart`、`lib/state/app_state.dart` | `phase4_tmdb_progress_test.dart` |
| T18 | fixture 与验收脚本 | `packages/test-fixtures/tmdb/**`、`tools/phase4/**` | 一键验收全绿 |

依赖关系：

```text
D1–D8（文档）
   ↓
T1 T2 T3 T4 T5（纯逻辑，可并行）
   ↓
T6（服务）← T3
   ↓
T7（编排）← T2 T4 T6
   ↓
T9（存储）
   ↓
T8（元数据应用）← T4 T6 T9
   ↓
T10（状态）← T7 T8 T9
   ↓
T11 T12 T13 T14 T16（UI）
   ↓
T15 T17（播放与历史）
   ↓
T18（fixture 与验收）
```

---

## 3. 验收门禁（本阶段完成判据）

> 完整判据、覆盖位置与关键断言见 `design/05` §6。此处为汇总视图。

| 门禁 | 判据 | 覆盖位置 |
| --- | --- | --- |
| 标题清洗与信号 | 13 步清洗、年份、季度信号、排序键、相似度公式 | `test/phase4_tmdb_title_test.dart` |
| 分季变体防护 | 四档得分（`+140` / `0` / `+160` / `-240`）+ 直接丢弃 | `test/phase4_tmdb_match_policy_test.dart` |
| 站点策略 | 7 条判定顺序、括号归一、`[书]` 不命中 `[小说]`、默认 11 条规则 | `test/phase4_tmdb_site_policy_test.dart` |
| 匹配缓存 | 三层键读取顺序、同 `vodId` 多作品、手动排他、冲突显式化 | `test/phase4_tmdb_cache_test.dart` |
| 季度解析 | 15 步顺序、三元组断言、`ambiguous` 零写入、不覆盖旧绑定 | `test/phase4_tmdb_season_resolver_test.dart` |
| 可播放季度 | 6 级顺序、UI 矩阵 7 行、不补集、不丢集 | `test/phase4_tmdb_available_seasons_test.dart` |
| 分段校验 | 8 条有效性（含不连续、未完整覆盖） | `test/phase4_tmdb_segment_test.dart` |
| 季度进度 | 写入规则、不覆盖、读取顺序、历史投影、换源 5 条、删除 4 条 | `test/phase4_tmdb_progress_test.dart` |
| 剧集元数据 | 未知季度**不应用**（反向验证）、代数校验、分段应用 | `test/phase4_tmdb_episode_metadata_test.dart` |
| 配置归一化 | 13 条规则、别名键、JWT 判定、往返幂等 | `test/phase4_tmdb_config_test.dart` |
| 图片选择 | 4 条排序键、方向回退、去重、`limit`、URL 拼接 | `test/phase4_tmdb_image_selector_test.dart` |
| 服务可靠性 | 鉴权形态、TTL 三级读路径、熔断（零请求）、取消不落盘、7 类错误映射 | `test/phase4_tmdb_service_test.dart` |
| 存储与迁移 | 4 张表、`schemaVersion` 1→2 幂等、往返、513→512 淘汰、清理边界 | `test/phase4_tmdb_storage_test.dart` |
| 契约 | TMDB 配置 Schema 校验（含反向验证）、fixture 完整性 | `tests/test_contracts.py` |
| UI 渲染 | 状态条 6 态、补位 8 字段、骨架尺寸、键盘全流程、失败隔离文案 | `test/phase4_tmdb_ui_test.dart` |
| 详情集成 | 真实窗口 + 真实 HTTP + 季度切换 | `integration_test/tmdb_detail_flow_test.dart` |
| 播放集成 | 真实播放器 + 季度身份透传 + 续播 + 换源续播 | `integration_test/tmdb_playback_flow_test.dart` |
| 手动匹配集成 | 持久化、仅选季度、清除绑定 | `integration_test/tmdb_manual_match_flow_test.dart` |
| 失败隔离集成 | 401 不阻塞播放、熔断生效（计数不增） | `integration_test/tmdb_failure_isolation_flow_test.dart` |
| 纯 TMDB 详情页 | 卡片不可播、跳搜索页 | `integration_test/tmdb_tmdb_only_detail_flow_test.dart` |
| 凭据不泄露 | 日志与诊断导出脱敏 | `tools/phase4/verify_tmdb_redaction.py` |
| 无回归 | `flutter test` + `dart analyze` 全绿 | 全量 |

门禁以 `flutter test` + `flutter test integration_test/*.dart -d windows`
为可复现入口，并封装为一键验收脚本 `tools/phase4/run_windows_acceptance.ps1`
（结果写入 `docs/phase4/evidence/windows-acceptance.txt`）。

---

## 4. 风险与开放问题

| # | 风险 | 影响 | 缓解 |
| --- | --- | --- | --- |
| R1 | TMDB 响应形态与 fixture 偏差 | 上线后解析失败 | fixture 取自真实响应脱敏快照；保留 `malformed`/`error-*` |
| R2 | 季度解析分支爆炸导致回归成本高 | 交付变慢 | 表驱动用例 + 统一三元组断言 |
| R3 | 详情页信息量过大导致布局复杂 | 体验下降 | 区块可折叠；简介默认 4 行折叠 |
| R4 | `settings.json` 首次引入带来的读写/并发问题 | 设置丢失 | 单写入点 + 原子写（临时文件 + rename）+ 单测覆盖往返 |
| R5 | `url_launcher` 新依赖 | 打包与 CI 影响 | 打开器可注入；CI 用假 opener |
| R6 | 多配置切换时 TMDB 绑定串号 | 进度错乱 | 所有 TMDB 表带 `config_id`；`02` §14 Q2 |
| R7 | 与上游语义漂移（例如重新引入"未知→第一季"） | 违反核心原则 | 反向验证用例（`design/05` §10）必须存在并通过 |

| # | 开放问题 | 结论 | 依据 |
| --- | --- | --- | --- |
| Q1 | TMDB 配置是否进配置 JSON？ | **不进**，放 `settings.json` | `design/03` §5.3 |
| Q2 | 是否需要"跨站同名作品沿用"？ | **需要** | `design/01` §11 Q1 |
| Q3 | 相关视频是否应用内播放？ | **不**，浏览器打开 | `design/04` §7.2 |
| Q4 | 未知季度是否兜底第一季？ | **不兜底** | `design/02` §9.1 |
| Q5 | 季度进度是否按配置隔离？ | **是**（`config_id`） | `design/02` §14 Q2 |
| Q6 | 手动匹配结论是否随缓存清理消失？ | **不消失** | `design/01` §11 Q4 |
| Q7 | 是否支持多套 TMDB 配置？ | **不支持** | `design/03` §10 Q5 |
| Q8 | 是否需要 AI 刮削 / 个人推荐？ | **本阶段不做** | `design/00` §4.3 |

---

## 5. 平台范围声明

本阶段仍**只交付 Windows**。Linux/macOS 的 TMDB 服务、存储与 UI 验证不在范围内。

发布文案不得声称已支持 TMDB 增强，除非 §3 门禁全绿且证据写入
`docs/phase4/evidence/windows-acceptance.txt`。

---

## 6. 与主设计文档的关系

本阶段对应主设计文档新增的 **§27 TMDB 元数据增强** 与 **§21 Phase 4**：

- §27 给出 TMDB 能力的定位、原则与模块边界（摘要级）；
- 本目录 `design/00`–`design/05` 给出可实施的完整语义（细节级）；
- 冲突时以本目录为准，并回填主设计文档。
