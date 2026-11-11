# 设置页面与子页面优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development. 使用独立文件边界并行实施，各任务自检后由协调者独立审查。

**Goal:** 不改变功能的前提下，统一设置区布局、层级、反馈与键鼠交互。
**Architecture:** 只调整 Flutter UI，公共设置表现组件限定在新文件 settings_layout.dart。各页面保留原有 AppState、控制器、异步处理和路由，按照同一表单规范排列。
**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4 / Material 3。
**Spec:** `.impeccable/surfaces/settings-refresh.md`（用户已确认收口记录）。

## Global Constraints
- 保留 DESIGN.md 的深靛/琥珀、中文系统字体、400/700、无阴影和既有 token。
- 所有功能、配置字段、默认值、保存时机、校验与危险操作确认不变。
- 不改业务服务、首页、播放器、全局主题或依赖；不提交、推送或构建安装包。
- key 字面值及挂载类型、Text/SelectableText 文案保留；测试滚动定位可以完善但业务断言不可删除。
- 测试用临时 AppPaths，不触碰用户真实数据；禁止真正外发 AI/TMDB 请求。
- 截图检查首轮统一批量，必要时最多一轮修正确认；每任务最多三次实施运行。

### Task A：设置主页与共享布局
Boundary：lib/ui/diagnostics_pages.dart（SettingsPage、SiteHealthPage；不改 LogsPage 业务），lib/ui/player_button_config_page.dart，新 lib/ui/settings_layout.dart；相关 phase8_settings_entries_test.dart、phase8_button_config_page_test.dart 和新 settings_refresh_test.dart / integration_test/settings_refresh_visual_test.dart。
- [x] 读取相关页面与现有测试，增加/运行设置分组和窄窗不溢出回归测试。
- [x] 在 settings_layout.dart 提供 `SettingsPageHeader({required String title, String? description})`、`SettingsSection({required String title, String? description, required List<Widget> children})`、`SettingsActions({required List<Widget> children})`。均为 StatelessWidget。标题/分组使用主题和 AppSpace，操作区用 Wrap。公共组件不得接管保存/状态/导航。其他组只依赖此固定 API，禁止扩展其必填参数。
- [x] 重排主页面，紧凑组织偏好、播放、连接增强、维护与说明；保留全部 key 和功能；站点健康与按钮页适用相同限宽、间距和键鼠反馈。
- [x] 运行本组相关测试，生成所有目标页截图采集测试（包含主页面、TMDB、安卓、AI、高级、字幕、按钮、备份、注入、网盘、AI辅助、站点健康；暗/亮主题和宽/窄尺寸，隔离测试状态，不启动真实外部请求）。采集测试最后统一由协调者执行，避免竞争 Windows 构建。
- [x] 报告文件、差异和自检证据。

### Task B：偏好表单子页面
Boundary：lib/ui/advanced_settings_page.dart、lib/ui/ai_settings_page.dart、lib/ui/subtitle_settings_page.dart；相关 advanced_settings_switch_test.dart、phase6_ai_settings_page_test.dart；新 settings_forms_refresh_test.dart。
- [x] 读相关页面与测试，增加窄窗布局和编辑后状态反馈测试并执行基线。
- [x] 沿用 Task A 的三个公共组件固定 API（生成前可只添加 import，勿改该文件），统一页内标题说明、功能分组与换行操作区。高级页按类别建立清晰节奏、避免冗长密集或装饰性卡片堆叠；AI表单区分连接信息与操作状态；字幕页区分自动匹配、本地、HTTP源。
- [x] 保留全部控制器、配置映射、保存和验证；尤其保留高级页的 ListenableBuilder，避免开关回弹。
- [x] 用 `C:/dev/flutter/bin/flutter.bat test --no-pub <本组测试>` 自检，报告原始命令、退出码与失败原因；格式化仅自己文件。
- [x] 报告文件、差异和自检证据。

### Task C：连接与数据工具子页面
Boundary：lib/ui/config_pages.dart（只 TMDB 与 Android settings，ConfigPage 不改）、lib/ui/backup_page.dart、lib/ui/injected_sites_page.dart、lib/ui/pan_check_page.dart、lib/ui/ai_assist_page.dart；相关 phase5_sync_ui_test.dart；新 settings_tools_refresh_test.dart。
- [x] 读目标页面及关联测试，增加工具页窄窗、空态与操作可达测试，执行基线。
- [x] 使用三个共享组件固定 API统一标题、分组、操作反馈与限宽；凭据/服务/匹配/设备同步职责清晰，空结果与错误保持真实，注入工具保留列表与删除确认。
- [x] 不改 ConfigPage、配置切换函数和服务；所有原字段、默认值、保存时机和危险操作确认保持原样。不得真正扫描局域网或访问真实 AI/TMDB 服务。
- [x] 自检本组测试，格式化仅自己文件，报告证据。

### Acceptance：协调者独立验收
- [x] 读取每组关键差异，对照原保存/处理逻辑与业务约束；每组最多 1 首次运行 + 2 返工。
- [x] 执行 targeted Flutter analyze 与跨组单测，失败归属明确后发回责任组。
- [x] 运行截图采集，打开真实渲染图检查暗/亮、宽/窄布局与入口；最多两轮视觉检查。
- [x] 新鲜子智能体做 spec/quality 和截图审查，必须给出具体证据及 ship/fix 结论；发现缺陷不得仅记在总结里放行。
- [x] 汇总路径、验证、已处理风险、未做项；不自动 git commit/push。

## 预检
|任务/接口|检查结果|
|A/B|仅共享三个 StatelessWidget 的固定 API；B 不写 A 的文件|
|A/C|同上；config_pages.dart 只由 C 写|
|B/C|高级页链接 C 页但路由和构造器不变；无共享写入|
|A|页面与测试边界一致；采集统一由协调者运行|
|B|高级页状态监听属于不可删除约束；表单保存不变|
|C|备份恢复确认保留；ConfigPage 明确排除|

## 运行记录
A：2/3，已完成。B：1/3，已完成。C：3/3，已完成。独立静态终审通过；视觉终审 ship；220 条跨组回归、18 条 Windows 集成用例和全应用 analyze 通过，17 张截图有效。全部任务已收口，无等待项。
