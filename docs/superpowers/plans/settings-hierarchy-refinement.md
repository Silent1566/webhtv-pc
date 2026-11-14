# 设置层级与排版优化

## 范围与决策
- 用户要求：再优化设置分类、排版，高级页拆分；具体设计由实现者决定，仅涉及 UI。
- 采用既有 Material / 深靛与琥珀 / 零阴影；不修改配置字段、默认值、业务服务、保存时机或校验确认。
- 首页保留四个稳定分类 ID 与独立滚动；连接类别显示名为「连接与服务」，正文去掉重复分类标题，采用行式入口。
- 高级页作为中枢，分为播放与观看、站点与搜索、网络、工具、隐私与诊断；多字段表单进入六个三级原生返回页，单开关仍直接可用。

## 执行拓扑：Hybrid
共享 UI seam 先冻结，再并行实现主页与高级中枢/详情；独立测试、静态审查与截图采集随后进行。

|任务|写入边界|运行次数/上限|状态|
|---|---|---|---|
|共享 seam|settings_layout.dart|主协调实现|已静态验证|
|B 高级中枢与详情|advanced_settings_page.dart、advanced_detail_pages.dart|1/3|自检返回，待独立验收|
|C 设置主页|diagnostics_pages.dart 的 SettingsPage|1/3|自检返回，待独立验收|
|D 回归|7 个既有 test 文件、support helper、新导航测试|1/3|执行中；持有 Flutter test 锁|
|CAPTURE|tool/settings_capture_test.dart|1/3|执行中；禁止并发测试|
|REVIEW|只读源码；.local 下单个报告|1/3|执行中|

路径均相对于 apps/desktop-flutter/lib/ui，测试与采集路径除外。任务 brief 是写入与验收契约，表格不是另一次分发。

## 验收标准
- 原设置回调、数值来源、对话框校验、危险操作确认和原控件 key 保留。进入子页的控件由按钮改为可聚焦列表行是有意的 UI 变更。
- 六个明细页真实可达、原生返回；独立路由监听状态，保存后开关和中枢摘要更新；分类切换不落盘且保留滚动。
- 相关回归与静态分析通过；新测试验证层级导航、键盘激活、保存回显/落盘与宽窄暗亮不溢出。
- Before 与 After 同场景、同尺寸、同主题、同字体对照。八张基线在 .local/settings-refactor-visual/before/；详情另补 After，不将其替代配对证据。
- 本机 Linux 原生集成构建失败：缺 clang++。渲染取证使用 Flutter widget-test + 已安装 Noto CJK 字体，不声称 Windows 真机验收。
- /tmp tmpfs 已满；测试 TMPDIR 使用 /home/maple/.cache/flutter-tmp，不清理非本任务临时目录。

## 开放事项
测试与静态审查结果、After 视觉对比、发现缺陷的归属/返工、最终验收记录。未提交、推送或打包。
## 运行与审查记录
- B（高级中枢 + 6 明细页）：run 2/3（F3 字面量 8px 改 AppSpace.sm；F5 出站规则行 key 加下标，避免同代理地址重复 ValueKey）。32 个旧 key 全部保留；state.set* 多重集合与 HEAD 一致（28 = hub 7 + 明细 21）。
- C（主页行式重排）：run 3/3（F4 类注释与事实对齐；F7 搜索按钮恢复固有宽度）。13 个关键 key 各 1 处；搜索线程对话框 minValue/maxValue/keyPrefix 与 HEAD 相同。
- REVIEW（只读静态审查）：.local/settings-refactor-visual/static-review.md，Spec 轴等价、Quality 轴 4 条 + 1 条 CI 门禁。F1/F2 由协调者在 seam 修掉（行零水平内边距、副标题间距走 AppSpace.xs）。
- CAPTURE（截图脚本）：run 2/3，tool/settings_capture_test.dart 扩到 360 行；RepaintBoundary 上移到 MaterialApp 外以拍到 push 出来的明细页；8 张 before 基线按名字/尺寸/主题/字体保留，并加 before 阶段覆盖保护。
- D（测试适配）：run 1/3 只落了 test/advanced_settings_navigation_test.dart 与 test/support/advanced_settings_navigation.dart（新套件全绿），7 个既有套件未改。
- 协调者实跑证据（10 个套件）：51 passed / 13 failed；13 条全部来自未适配的旧断言（分类标签、FilledButton 类型、旧分区标题、控件已下移到明细页、窄窗同宽断言），无生产逻辑失败。已把逐条真实断言发回 D（run 2/3）。
- 未完成：D 返工后的绿测、After 截图与 Before/After 逐张对比、交付总结。未提交/推送/打包。
## 最终验收（协调者）
- 测试：8 个套件（advanced_settings_switch / phase8_settings_entries / phase9_privacy_recovery / settings_forms_refresh / settings_refresh / settings_categories_navigation / browser_component_settings / advanced_settings_navigation）实跑 exit 0，69 passed / 1 skipped / 0 failed。
- 静态分析：settings_layout.dart、advanced_settings_page.dart、advanced_detail_pages.dart、diagnostics_pages.dart、tool/settings_capture_test.dart 全部 No issues found。
- 行式列表的对齐是量化校正过的：同一 SettingsRowList 里自绘行与 SwitchListTile 的标题左缘、标题/副标题字号（16/14）与行高现已一致（实测两者 left 均为 318、标题 h=24、副标题 h=20）。期间发现 ListTile 的 dense 布局会把标题压到 13px、leading 槽位比自绘行多 4px，因此在行内显式给了字号并用 8px 标题间距补正。
- 视觉：Before 8 张（.local/settings-refactor-visual/before/）与 After 24 张（after/）同场景、同视口、同主题、同字体；逐张检查 1440x900 / 1072x728 / 480x640 暗亮两套，无溢出、无缺字；截图根的 DEBUG 角标已关闭。
- 风险与未做：原生 Linux/Windows 集成跑不起来（本机缺 clang++，且 Linux 桌面构建缺 GTK 开发头），截图是 Flutter widget-test 渲染而非真机；未做多显示器 DPI、系统字体缩放、读屏软件实测；未提交、未推送、未打包。
