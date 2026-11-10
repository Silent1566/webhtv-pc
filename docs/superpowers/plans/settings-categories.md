# 设置分类导航 Implementation Plan

> 执行方式：subagent-driven-development；三组独立文件边界，先自检再独立审查。

**Goal:** 以左侧分类/右侧单列替代两个并排内容列，不改变设置功能。
**Architecture:** SettingsPage保存页面内类别选择和各类别滚动位置；原设置内容/回调不变，桌面分类栏与极窄顶部分类使用同一稳定类别key。应用外壳NavigationRail保持原样，不新增第二个NavigationRail。
**Tech Stack:** 现有Flutter/Material 3；不新增依赖。
**Spec:** `.impeccable/surfaces/settings-categories.md`，用户已确认。

## Global Constraints
- 原有字段、默认值、校验、保存时机、危险确认、控件key与类型、中文文案保留；类别选择不写AppState或settings.json。
- 四类为preferences偏好、playback播放、connections连接与增强、maintenance维护与说明；默认preferences。
- 分类控件key精确为 `settings-category-preferences`、`settings-category-playback`、`settings-category-connections`、`settings-category-maintenance`；宽窄都用原生可键盘激活控件；同一key运行时只出现一次。
- 正常桌面左侧分类、右侧只显示一类；极窄内容分类置顶；各类别独立滚动并保持位置。不得继续同时绘制两张内容列，也不得为测试展示所有类别。
- 不新增第二个NavigationRail；主外壳既有类型约束保持。
- 现有子页UI、服务、状态映射、全局主题和依赖不改；不提交/推送/发布。
- 测试导航助手由UNIT组独占：`Future<void> selectSettingsCategory(WidgetTester tester, String category)`，路径 `test/support/settings_navigation.dart`；只通过真实分类控件tap/有界pump选类，不操纵私有State或生产开关。

## Task UI：主页面实现
Boundary：只改lib/ui/diagnostics_pages.dart内SettingsPage及必要私有布局；新test/settings_categories_navigation_test.dart；不要改LogsPage/SiteHealthPage/共享设置组件/其他组测试。
- [x] 添加分类选择、当前类别内容独占、类别切换不写盘、键盘切换、各类滚动保留、480/720/1024及宽窗暗亮不溢出回归，先观察旧双内容列实现失败。
- [x] SettingsPage内部管理类别/滚动，默认偏好；复用旧内容/控制器/事件，不改健康摘要等业务事实。当前类别选中态明确，导航与正文有细线或表面层级，不堆卡片。
- [x] 自检自己新测试；尽早通知源码可编译和固定分类key已可消费；报告代码边界与配置不变证据。

## Task UNIT：单元入口回归
Boundary：test/phase8_settings_entries_test.dart、phase5_sync_ui_test.dart、phase6_ai_settings_page_test.dart、phase4_tmdb_entry_reachability_test.dart、phase5_sync_refresh_test.dart；新test/support/settings_navigation.dart。不改生产代码。
- [x] 实现固定助手；读取旧测试并增加正确类别选择，保留原业务/持久化/回显/精确中文/实际路由断言。
- [x] phase8默认进入playback后检验OSD/按钮；其他类别入口按目标选类。固定高视口用例改为“选类后可达”，不再要求不同类别同时在视口里。
- [x] Android/AI/TMDB及安卓状态回显选择connections；偏好/历史/搜索保持默认；不调整业务默认值，不屏蔽真实失败。
- [x] 独占时段自检以上测试；确认去重后的TMDB页仍无安卓嵌套入口。

## Task VISUAL：集成/主页面回归与截图
Boundary：test/settings_refresh_test.dart；integration_test/mvp_a_flow_test.dart、ui_redesign_visual_flow_test.dart、tmdb_shell_entry_flow_test.dart、settings_refresh_visual_test.dart；新integration_test/settings_categories_visual_test.dart。不改生产及UNIT组文件。
- [x] 旧“六个入口同时首屏可见/两列滚动”测试改为分类切换后的可达性与单列几何断言；保留原key类型和子页业务验证。
- [x] 集成流程在需要AI/TMDB/维护工具前通过固定助手选择对应类别，主题切换留在preferences；不得直接调用私有业务保存。
- [x] 新原生采集只面向修订后的SettingsPage：4类别×暗亮宽窗，代表类别窄窗，总PNG最多12独立文件，输出.local/settings-categories-visual；每张必须有实际分类选中态与对应内容，不用假布局。
- [x] 保留独立临时AppPaths、禁外部网络和真实AI保存完成态原集成用例。Windows测试统一协调者运行，不并行build。

## Acceptance
- [x] UI→UNIT→VISUAL单元串行自检，源码稳定后协调者统一targeted回归/analyze。
- [x] 真实Windows采集全部要求类别/主题/尺寸，逐图检查并新鲜子智能体审查，用户截图为primary反例。
- [x] 检查变更边界和持久化/回显/键鼠；发现缺陷最多2次返工，不仅记录后放行。
- [x] 更新交付记录并给路径、验证和未做项，保持全局设计世界。

## 预检与运行
UI/UNIT：固定4类别key接口，无共享写入。UI/VISUAL：同上，VISUAL不写生产。UNIT/VISUAL：仅固定助手接口，助手由UNIT独占。各Task界面/测试边界自洽。
首次运行：UI1/3、UNIT1/3、VISUAL1/3；每任务最多首次加两次返工。源码编辑并行，Flutter独占顺序UI→UNIT→VISUAL→协调者；等候年龄上限3协调回合，超出应处理阻塞而非轮询。

## 完成记录
UI：2/3；UNIT：1/3；VISUAL：2/3。164条相关回归、全应用analyze、12条Windows分类采集与1条AI保存验证通过；静态终审两finding已resolved，视觉终审ship/material0。12截图包括1072x728完整AppShell，未提交/推送/发布。
