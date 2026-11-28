# 全应用玻璃覆盖 Implementation Plan

> **For agentic workers:** Use subagent-driven-development with the boundaries below. Lead owns one acceptance layer and shared seam; no commits. Each child has at most 3 runs total.

**Goal:** 完成侧栏到窗口标题栏的全应用统一材质，不再交付仅顶栏的局部改造。
**Architecture:** Hybrid：Lead 冻结默认底景、GlassSurface 的无滤镜分支和共享面板接口后，独立分组接入页面、浮层、播放器和窗框。沿用现有主题与业务，所有验收最终由 Lead 复跑。
**Tech Stack:** Flutter desktop / Material 3 / dart:ui / existing window_manager.
**Spec:** docs/superpowers/specs/2026-11-27-glass-full-application-design.md

## Global Constraints
- 工作树 wt/dev3 已隔离且有前轮大量未提交修改，不 reset/clean/commit，不改依赖和业务协议。
- 用户已定：默认底景且配置壁纸优先；播放器性能优先不强制视频模糊；系统标题栏也改。
- 不改视频/第三方网页正文和字幕弹幕内容；清晰表单与文字允许致密染底，仍须完成控件造型和状态统一。
- 所有 Flutter 命令串行持有 .local/glass-rollout-flutter.lock；TMPDIR 用工作树磁盘目录，避免 /tmp 满。
- 各组先写并运行失败测试再改生产代码；提供文件/行证据、测试输出和可复现的同场景截图。

## Task 1: 共享默认底景、低成本材质和左侧导航（Lead-Core，直接执行）
**Files:** lib/ui/wallpaper_backdrop.dart, glass_surface.dart, new glass_widgets.dart, theme.dart, app.dart; test/full_glass_foundation_test.dart and directly affected shell tests.
**Interfaces:** WallpaperBackdrop 继续接收 url 和 builder(context, hasArtwork)，无图/加载/失败也提供默认可采样底景；GlassSurface 新增 blurBackdrop=false 的完全无 BackdropFilter 分支；GlassPane(child,padding,borderRadius,blurBackdrop) 提供致密易读面板。接口冻结后发给各组。
- [x] 用真实 MaterialApp 写无图可见背景、两主题差异、图失败回退、无滤镜分支和 sidebar 材质测试，确认 RED。
- [x] 实现静态内置背景和稳定前景树，保留图片请求头及 logo 优先级；给 NavigationRail 挂真实玻璃且保留8项容量/焦点。
- [x] 更新主题透明 Scaffold 与清晰输入/卡片/菜单状态，运行基础测试、rail capacity、shell underlap/motion；确认 GREEN，再冻结接口。

## Task 2: 全部普通路由与设置管理（独立页面组）
**Boundary:** 普通页面、详情页、设置管理诊断路由；不写 app.dart/theme/tokens/glass shared/player/独立dialog。
**Consumes:** Task1 的 WallpaperBackdrop, GlassPane 和默认背景契约。
- [x] 根据只读盘点逐文件建立覆盖矩阵，不把 AppBar 变化算正文完成。
- [x] 先在真实入口测试主要正文和默认背景，保留表单 Rect/scroll/focus，再接入所有可达路由及直接配套控件。
- [x] 真实渲染首页/列表/设置/配置管理/罕用管理页的明暗对照；窄窗、无图与错误回退测试后提交报告。

## Task 3: 弹窗、菜单、通知（独立浮层组）
**Boundary:** 非播放器跨页 dialog/sheet/menu/toast 通用组件与调用点（排除页面组独占文件；边界由最终盘点按文件冻结）。
- [x] 先验证未迁移确认框/选择器及其取消/焦点行为，然后复用 GlassAlertDialog 和共享壳迁移；已有玻璃入口不得双重包裹。
- [x] 覆盖 popup/menu/custom overlays 和 toast/banner，可用低成本面板，但不得只改 theme 颜色来声称真实模糊。
- [x] 测试 barrier、自定义 DialogTheme、Tab/Escape、提交/取消和错误，附亮暗代表前后图。

## Task 4: 播放器全部应用控件（播放器组）
**Boundary:** player_*、播放专用面板/菜单与相关测试；不写共享玻璃或普通页面。
- [x] 写运行态/静态播放器控件材质与无 BackdropFilter 测试，确认 RED。
- [x] 控制栏、右键菜单、音轨字幕、选集/队列/直播/画面参数面板统一材质；字幕弹幕正文不动，不动 controller/解码/视频本体。
- [x] 验证全屏/锁定/键盘/悬浮/菜单层级，明暗两档静态夹具前后图并提交报告。

## Task 5: 自绘桌面标题栏（窗口组）
**Boundary:** new desktop_window_frame.dart、独立测试以及必要 native runner；app.dart 集成由 Lead 独占。
**Produces:** DesktopWindowFrame(child) 与窗口选项接入说明；使用现有 window_manager，不新增依赖。
- [x] 写窗口按钮、最大化切换、拖动区域不吞按钮、全屏隐藏和主题一致性测试，确认 RED。
- [x] 实现标题栏与窗口监听，向 Lead 指明隐藏原生 frame 的准确调用与平台例外；关闭仍走现有清理。
- [x] 以 mocked MethodChannel 验证原生命令，附两主题截图和实际可测平台限制。

## Task 6: Lead 全量覆盖验收与交付
- [x] 读最终差异逐项对照覆盖矩阵；任何发现的遗漏必须返回原组修复，不在总结里掩盖。
- [x] 补集成入口和 app.dart 窗框接线，更新 DESIGN.md 的范围和真实材质例外。
- [x] 复跑变动相关测试/静态检查、查前后图、检查滤镜数和文字；原有测试造成的证据图改动不覆盖用户旧改动。
- [x] Linux Release 构建与新进程/AOT/实际标题栏验收；未测 Windows/macOS 如实记录。
