# 设置分类导航修订

模式 Operate；平台 Flutter Windows desktop，键鼠优先。

用户截图明确否定设置页把两个内容列并排堆叠的布局。用户选择并确认：左侧分类导航，右侧单列当前内容；默认偏好，类别仅影响显示、不改变配置；保留各类别滚动位置；极窄内容区改顶部分类。

## Direction contract
THESIS：设置是一项项可定位的偏好，不是两张同时展开的表单。
OWN-WORLD：沿用现有中文字体、深靛与琥珀、Material控件、AppSpace/AppRadius及零阴影；不改全局主题。
STORY：用户先从偏好、播放、连接与增强、维护与说明选择类别，再在右侧单列编辑或打开子页面；切换类别不写配置，返回类别不丢滚动位置。
FIRST VIEWPORT：设置标题下，以设置页内层可用内容宽720逻辑像素为断点：达到断点时左侧分类栏196，发丝分隔线1、两侧间距各16，右侧只显示当前类别的限宽单列；低于断点时四类入口移到顶部。当前类别有原生清晰选中态，不再保留两个并排内容列。各类别独立ScrollController与offset记录，类别切换及子页返回保留分类/滚动；仅在本页State生命周期内保持，不是配置持久化。
FORM：用户指定分类导航，不重选艺术方向。默认偏好；全部已有字段、key、控件类型、保存/校验/返回/危险确认保留。
FINISH：unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance.

## 实现与已完成验收记录
- 本轮是普通设置表面扩展，保留全局设计世界；THESIS、OWN-WORLD、STORY、FORM、FINISH不变。数值及控制器实现见 `apps/desktop-flutter/lib/ui/diagnostics_pages.dart:97–138`；类别切换仅setState，不写配置。
- 静态终审以 `.superpowers/sdd/settings-categories/static-review.md:119–151` 为准：UI/UNIT/VISUAL最终Spec与Quality两轴PASS，范围分别为静态实现、业务断言保留、场景/技术取证；UI-Q1、V-S1已resolved，未关闭项0。原四组业务与回调对基线相等的证据见该报告第28行；不是本轮文档核对重新比较源码。
- 已有完成日志经终审核实：12文件相关回归164条全绿（含11条分类导航/独占/键鼠/各类滚动/子页返回/真实配置通知重建），全App analyze零问题；Windows分类矩阵12例及额外AI原生保存1例通过。AI保存为真实UI操作，反馈已保存，内存/磁盘精确值一致，HTTP请求0、PNG0；四项退出码均0。本轮仅借用报告，不重新运行。
- 全新视觉终审见 `.superpowers/sdd/settings-categories/visual-review.md`：disposition=ship，material问题0、修正无，已逐张查看12张新图及旧双内容列反例。本轮文档同步不是重新视觉验收，也不沿用旧双列ship。
- 真实视觉范围：8张standalone宽窗1440×900（四类×暗亮），2张standalone窄窗480×640；仅2张user图为完整AppShell用户尺寸1072×728（暗色偏好、亮色连接）。宽窗及两张user右正文实测639逻辑像素，窄窗448；user主NavigationRail恰1，其余standalone为0，全部Windows/selected=true/HTTP=0。完整AppShell不等于包含操作系统窗口边框；截图不复刻用户真实配置。
- 保留范围证据：静态报告原字段/key/值来源/回调/原生路由未变；视觉报告确认深靛/琥珀、中文400/700、原生Material、发丝边零阴影沿用。必要DESIGN tokens仍列AppSpace 4/8/12/16/24/32/48与AppRadius 6/10/14/999；本轮不改DESIGN、PRODUCT、主题、源码、测试或PNG，不把只读核对宣称为全主题源码审计。
- 未测范围：不宣称真实外部网络服务、全部hover/焦点外观、多显示器DPI、系统字体缩放或真实读屏软件已验；语义/键盘自动测试不能替代平台实测。亮色偏好图由采集器注入亮色主题、隔离AppState仍默认暗色，不能作为主题切换保存闭环截图证据。

## 验收与边界
只改设置主页面和必要测试导航步骤；不改设置子页功能/业务服务/全局主题。原屏显7项、按钮、AI、TMDB、安卓、站点健康、缓存维护都可从类别到达。原业务断言不删，仅增加显式选类步骤；验证持久化/回显、类别滚动保留、宽窄暗亮布局和真实Windows保存路径。用户截图为本次首要问题证据，上一轮视觉ship不代表本轮已完成。
