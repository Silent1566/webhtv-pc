# 观影报告 v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 补齐 Android 四维偏好并新增三项可离线验证的桌面报告增强。
**Architecture:** 文档冻结 metadata→report→page seam；Fan-out 三个文件边界互不重叠，A 数据链路、B 纯统计、C UI 与截图。依赖是编译/最终验收顺序，不是共享写文件；A/B 新签名兼容旧调用，C 首先拍未改页面。
**Tech Stack:** Dart 3.13.4 / Flutter 3.47.5 / SQLite / existing Material tokens。
**Spec:** docs/phase9/design/10-viewing-report-v2.md

## Global Constraints
以 Spec 不变约束与冻结接口为合同；零新依赖/零报告网络请求；未知不猜、来源隔离、隐身不采集、历史进度/更新时间不改；不提交/不推送。

## Task 1: 元数据采集和离线提供（A，run 0/3）
**Files:** lib/core/viewing_metadata.dart, lib/services/storage.dart, lib/state/app_state.dart, lib/services/viewing_report_metadata.dart；如必要 lib/services/tmdb_service.dart / tmdb_cache.dart；test/viewing_report_metadata_test.dart。
**Produces:** Spec 冻结 ViewingMetadata 与 AppState.viewingReportMetadata。
- [ ] 红：迁移旧 schema10 库与两个来源相同 site/vod 的隔离测试；调用 cache-only 查询时客户端请求计数必须 0。
- [ ] 绿：加法式 schema11 与源详情快照、补缺纯转换、cache-only 提供器及受 runId/隐身约束的入口。
- [ ] 验证：重开、历史不变、空字段保留、隐身/过期/损坏缓存、同名异源；报告 A 路径/命令/结果。

## Task 2: 报告纯统计（B，run 0/3）
**Files:** lib/core/viewing_report.dart, test/viewing_report_v2_test.dart, test/phase9_viewing_report_test.dart。
**Consumes:** A ViewingMetadata；**Produces:** Spec 列出的报告字段、stat/comparison 类型及兼容 generateViewingReport。
- [ ] 红：四地区去重后 explorer、未知类型不归 TV；每条相同 actor 标签不重复计数。
- [ ] 绿：四维/覆盖率/源分布/7×24、上一周期统计、prompt 结构。
- [ ] 验证：黄金样本、全部/滚动/跨月季年半年/零基数/DST、不双计端点、原报告测试。

## Task 3: 报告界面与 Before/After（C，run 0/3）
**Files:** lib/ui/viewing_report_page.dart, lib/ui/viewing_report_sections.dart, test/viewing_report_v2_ui_test.dart, test/viewing_report_v2_capture_test.dart；screenshots/viewing-report-v2。
**Consumes:** A provider + B report fields；**Produces:** 可达离线界面、配对截图与 UI 断言。
- [ ] 在 UI 编辑前用固定同场景 fixture 拍 Before（1280×950 dark，top/lower）。
- [ ] 红：可见四维/覆盖率/图例/未知、宽窄布局、延迟 AI 切范围响应不能跨域。
- [ ] 绿：上述 Spec 页面方向，加入 metadataOverride，基础统计和已有 ValueKey 保留。
- [ ] 验证：同参数 After，真实渲染；亮/暗、窄屏、长文本和空态；报告截图路径。

## Task 4: 调度者独立验收与文档（run 0）
- [ ] 读关键 diff/新文件及配对截图，逐条检查 Spec 和各子任务证据。
- [ ] 复跑新增与基线报告/历史/隐身/TMDB 相关测试及 analyze。
- [ ] 若失败，用具体 file:line/输出发回原执行者；每 brief 至多 3 runs，clean hand_back 不计失败。
- [ ] 更新 catalog 观影报告状态、parity README 计数与独立 evidence 文档；说明未实测边界。
