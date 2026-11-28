# 全局无装饰边框 Implementation Plan

> Workers follow subagent-driven-development. No commits. Lead owns shared seam and one acceptance layer. Each brief has maximum3 runs total.

**Goal:** 全应用去掉装饰框体与高光，保留必要交互反馈。
**Architecture:** Hybrid。Lead先冻结共享材质/主题，再并行清理互不重叠的内容页面、设置/独立浮层、播放器自绘边线；Lead负责集成验收和文档。
**Tech Stack:** Flutter Material3, dart:ui, existing window_manager。
**Spec:** docs/superpowers/specs/2026-11-27-global-borderless-design.md

## Constraints
- 现有wt/dev3脏改保留；不commit/reset/clean，不加依赖，不改业务。
- Flutter/Dart统一flock -w600 .local/glass-rollout-flutter.lock；超时放在锁内部；TMPDIR使用.local/build-logs/global-borderless/<group>-tmp。
- Before/After相同场景/主题/视口，加载FixtureCJK及组件字体别名；真实图片用已有确定性PNG；不以坏图证明解码效果。

## Task1 Lead共享材质与主题
Files: lib/ui/{glass_surface,glass_widgets,glass_chrome,tokens,theme}.dart, test/global_borderless_core_test.dart, test/full_glass_root_test.dart。
- [ ] 写默认描边/高光绘制、控件焦点/错误/选中交互RED，捕获明暗Before。
- [ ] 共享玻璃无描边无洗光；面板染底略减弱；主题普通边线none，焦点/错误仍语义着色；divider空间不变只透明。
- [ ] GREEN与已有chromeframe/dialog测试（旧“玻璃必须有rim”按用户新要求更新），冻结API通知各组。

## Task2 普通内容与详情
Files由brief逐文件冻结（home/browse/live/search/library/following/TMDB/folder/AI内容）。
- [ ] 逐处判断Border/自绘Shape/Divider属于装饰或当前状态；前者删除，后者留可见语义反馈。
- [ ] 不改回调/尺寸，清理菜单paint sheen，搜索范围/海报普通边框移除；代表实际状态回归与明暗截图。

## Task3 设置管理与独立浮层
Files由brief冻结（settings/config/diagnostics/AI设置/来源/独立dialog），不写共享材质/主题。
- [ ] 移除局部OutlineInputBorder普通边线、菜单side、状态badge冗余边线；焦点/错误不失效。
- [ ] 继续保持已修复设置固定面板与滚动分离，不再次裁切/移动布局；宽窄、取消与Tab回归。

## Task4 播放器
Files由brief冻结player_*及专属sheet/AI控件；不写controller/window_mode。
- [ ] 普通chip/集数/队列菜单静态边线清除，当前集/选择/悬停反馈优先底色/图标。
- [ ] 保留进度/OSD信息与视频无采样，验证焦点长列表/键盘/回退/直播/全屏。

## Task5 Lead接受与交付
- [ ] 独立diff+视觉审查逐项路由问题；真实交互回归和边线残留清单，不以全局outline颜色清零掩盖语义。
- [ ] 更新DESIGN.md及现有sidecar材质规则；保留历史试点证据标为过时，不伪造新版零差。
- [ ] 复跑UI分析/风险测试，Linux Release构建，新PID映射AOT和实际截图；只替换已验证旧测试实例。
