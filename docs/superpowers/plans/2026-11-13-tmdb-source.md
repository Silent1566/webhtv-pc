# TMDB Source Payload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development. Steps use checkbox syntax.

**Goal:** 实现已确认的安卓内嵌 TMDB 与配置 key 兼容。
**Architecture:** 三个 disjoint 模块并行，设计先冻结接口；A 提供纯协议/规划/合并，B 接入配置作用域，C 通过冻结接口接入详情。A 的接口不得擅自更名；公共 seam 变更 hand_back 给协调者。
**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4。
**Spec:** docs/superpowers/specs/2026-11-13-tmdb-source-design.md

## Global Constraints
不增加依赖；不提交/推送；来源数据不是播放事实；用户凭据优先；凭据不进入普通配置/导出/日志；Before/After 同 scenario/viewport/theme。

### Task A — Payload core
- [ ] 在 test/tmdb_source_payload_test.dart 写协议、身份、安全、complete、语言、缺口、合并测试并确认 RED。
- [ ] 创建 core/tmdb_source_payload.dart（可拆到 core/tmdb_source_*.dart）及 protocol.dart Vod.tmdb getter，按 spec 冻结签名。
- [ ] GREEN 目标与旧 protocol/TMDB model 测试，format/analyze。

### Task B — Subscription key ingress
- [ ] 在 test/tmdb_subscription_credentials_test.dart 及 test/tmdb_root_key_ingress_test.dart 写 root strip/invalid/duplicate/user precedence/scope/stale/failure 测试并确认 RED。
- [ ] 在 config_parser.dart/config_loader.dart、tmdb_config.dart、新的 tmdb_subscription*.dart、tmdb_config_store.dart、storage.dart/app_state.dart（必要时 android_bridge.dart）实现成功导入后内存作用域接收，迁移/导出卫生与统一有效配置。
- [ ] GREEN 目标与旧 config import/record/TMDB config 测试，format/analyze。

### Task C — State + service + detail
- [ ] 修改前建立 fixture 与捕捉 test/tmdb_source_capture_test.dart 真实现有详情路径 Before 到 .local/tmdb-source/before.png。
- [ ] 在 test/tmdb_source_state_test.dart 写无 key/完整零请求/按缺口/失败保底/迟到身份/季集/播放不变测试并确认 RED。
- [ ] 在 state/tmdb_state.dart/services/tmdb_service.dart（以及必要时 ui/browse_pages.dart）通过冻结接口同步发布 payload，跳过匹配搜索，定向补缺口，保留 generations；不改纯 TMDB 详情接口。
- [ ] 捕获同 fixture/视口/主题 After 到 .local/tmdb-source/after.png；目标/旧 TMDB 状态、编排、串剧、详情 UI 测试 GREEN 与 analyze。

### Acceptance
- [ ] A/B/C 自测报告与关键 diffs 独立复核，缺陷回原代理（每 brief 最多 3 runs）。
- [ ] 独立 reviewer 审 standards/spec/privacy/races；协调者复跑目标与旧回归、读取 Before/After。
- [ ] 更新 catalog 两行与独立证据文档，只描述实际验证。

## Task Book / Decision Log
A/B/C：run 1/3；无外部依赖；文件边界见各派发 brief。设计一致性检查：A→C 签名与 spec 完全相同；B→C 使用既有有效 config getter，互不写对方文件；每项明确 RED/GREEN 与卫生/错误/视觉证据。
- A owner e84d59c2-f80d-4e8c-a092-64ebc4a68b1b：协议/规划/合并；run 1/3。
- B owner c2139f36-3ebf-45c5-985e-c562033857df：配置凭据 + 设置读取隔离；run 1/3。
- C owner 8c37b8f0-68c3-425e-8be3-8b36b708d259：状态/服务/详情；run 1/3。
- C 基线：.local/tmdb-source/before.png（1280×950 dark，无凭据，站源标题/简介 + 图片占位）；RED 1 pass / 5 fail（无首屏、走 search/multi 而非 /movie/42、缺季元数据）。
- 环境：/tmp 为 2.2G tmpfs 且仅余 157M；三个任务改用工作区 task-specific TMPDIR，不计失败。
- B clean hand_back：设置页读 tmdbConfig 会显示/写回订阅 key → boundary 扩至 config_pages/diagnostics_pages + 设置测试，新增 AppState.tmdbUserConfig；续跑 run 1/3，未计罚。
- A 冻结 API 可编译（tmdb_source_payload.dart + Vod.tmdb），聚焦源测试 37 passed；detail 规范化为 object-only。
- A 独立复核：协调者复跑 tmdb_source_payload/core/core_protocol → 115 passed，analyze 4 文件 clean；合并语义与 Android TmdbSourceMerger 对齐（complete 空数组/0 权威，嵌套缺键补齐同为安卓行为）。A 验收通过。
- 范围决定（用户）：单集详情弹窗纳入本轮；C boundary 扩至 tmdb_episode_detail.dart，文件上限 12→14，需 paired modal Before/After + 请求计数证据。
- C clean hand_back：回归证实 AppState 写 manual store 后 reload 被 payload 身份覆盖；boundary 扩至 tmdb_identity_service.dart 最小只读 accessor，文件上限 14→15；run 1/3 续跑不计罚。
- C 自修复：nav_source_detail_ui_test stub 仅补 preferredParseName，全套 18-suite 353/353 GREEN；另发现弹窗 movie 模式仍重复请求完整 source，补 RED 后 source movie core/credits/images/videos 复用 GREEN，旧弹窗 33/33。
- 事实核查：nav_source_detail_ui_test.dart:213 的 override 在 HEAD 即缺 preferredParseName（HEAD app_state:5421 已有），属基线缺陷；C 边界扩至该测试做最小 stub 修复（cap 15→16），保持该 required 回归可运行。
- A/B/C 完成状态：A 独立验收通过；B 报 ready 但我复核发现 ingress 对所有 malformed JSON 返回 {} → 丢失「JSON 解析失败+offset」，已令 B 返修（Android sanitizeMalformedJson 仅含根字段才返回 {}）；C 报 ready，我独立复跑 25 聚焦用例通过。
- B 返修 run2/3 已过：root分类 RED→GREEN，304 old regressions；协调者复跑凭据 23 passed。
- 联合验证：协调者跑19套件 363 passed；全仓 analyze 0 errors / 0 warnings / 95 baseline infos。
- R-AC：Spec 未全满足，HIGH F1 顶层 own-season episodes 未规划可用（A run2/3修）；MEDIUM F2 弹窗跨季污染、LOW F4 站点规则迟到填充、F5 双解析、F7 顶层season count（C run2/3修）；另收紧 _renderable 白名单。未验收最终交付。
- Ruling F3：episode complete 空值声明遵循安卓现规则（spec措辞对齐，不发明拒收）；F6：桌面首屏七组均有可达消费者，保留单次请求append缺口规划。Smells S1/S2/S4/S5/S6未构成强制标准缺陷，暂保留，不扩大重构。
- R-AC warm复审：F1/F2/F4/F5/F7 ADDRESSED；新 N1 IMPORTANT：own-first _sourceSeason 让顶层 title videos 遮蔽 seasons[N].videos，季度完整声明导致真实季度视频不出。C run3/3最终返修，分离 _sourceEpisodes 与 season object/videos 查找。
- 最终结果：A run2/3 / C run3/3 已通过 warm R-AC final（N1及前述所有回归均 addressed）；B run3/3 经 R-B final 对空白/token/OMDb/链式洗白反例、换库清空epoch与缓存候选剥离复审，Standards/Spec PASS；没有剩余 Important/Critical 缺陷。
- 最后协调者独立验证：凭据24/24，合并359/359，A+C聚焦82/82；全仓analyze0errors/0warnings/95infos。Before/After已读并保存docs/phase9/evidence/screenshots/tmdb-source六张；catalog两行、README统计45迁移/22未迁移与09证据文档已更新。未做真实联网/Windows build/全量test，未提交。
- B security裁定：畸形JSON中value含tmdb_api_key字段名token的保守清洗遵循Android sanitizeMalformedJson原行为；已记录验证边界。
- Ruling LOW N2：payload0集计数保留安卓语义；Ruling F5：单次load仅解析一次已修，不扩大为跨load缓存/协议重构。
- 观测但无法稳定复现的基线反馈测试失败：D最新整套62通过，协调者隔离复跑同一慢解析反馈用例3/3通过；不宣称非flaky，未改断言/生产行为。
- D：HEAD 上 invalid_override 共 7 处（4 测试 + 2 测试 + 1 integration_test），均为缺 preferredParseName；六文件修复后全仓 analyze 剩 1 error（integration_test:39），第 7 个文件在授权内。六文件单测 62 passed（需 sysroot LD_LIBRARY_PATH，属环境而非代码）。
- 基线缺陷（HEAD 即存在，非本次引入）：4 个指定测试的 resolvePlayback / resolvePlaybackForSource 共 5 个 override 缺 preferredParseName。D 做 test-only 参数修复（cap 4）；原「单引号导致字面路径」推断已撤回：D/native inspection 证实现有 Dart 字符串是正常插值，无路径改动。历史生成目录已清理。
- 已清理 D 运行前遗留的 apps/desktop-flutter/${temp.path} 生成目录（无凭据泄漏：grep tmdb_api_key/apiKey 零命中）。
- B 中间证据：171 个目标/旧用例 GREEN，12 文件 analyze clean；设置 Before/After 1100×900 dark 字节一致，未接受最终验收。
- B clean hand_back：bridge refresh 经 SyncState.importSites 在 await 后先写 host，原边界无法守候选 key/epoch；scope 扩至 sync_state.dart + bridge 回归，cap 17→20，优先可选 guards/callbacks 保持 SyncHost 兼容；run 1/3 不计罚。
