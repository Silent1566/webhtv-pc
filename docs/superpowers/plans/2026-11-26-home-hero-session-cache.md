# 首页大推荐会话缓存 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 同次运行返回首页立即恢复完整大推荐，背景更新不清空现有内容。
**Architecture:** AppState拥有专用HomeHeroSession；HomePage只订阅。复用现有取数与磁盘图片实现，不建立通用缓存层。
**Tech Stack:** Flutter/Dart，现有flutter_test、Puro webhtv，无新依赖。
**Spec:** docs/superpowers/specs/2026-11-26-home-hero-session-design.md

## Global Constraints
- 不改变视觉布局、不保活其他页面、不增加依赖、不提交或推送。
- 完整轮播最多12项，默认启动快照最多3项。
- 保留高清门槛、稳定顺序/去重、等高占位、最新播放进度、配置隔离、旧generation拒收和豆瓣限流。
- 文件编辑范围由每个派发brief指定，最多3次派发运行；测试和只读检查不限。

### Task 1: 会话模块与首页接入（Lead-Core；run 1/1）
**Files:** Create lib/state/home_hero_session.dart；Modify lib/state/app_state.dart、lib/ui/home_page.dart；Test test/home_hd_hero_backfill_test.dart、test/home_hero_session_test.dart（全部位于apps/desktop-flutter）。
**Interface:** AppState.homeHeroSession；HomeHeroSession extends ChangeNotifier，提供首页数据投影、选中key、刷新/配置与图片失败处理，页面退出不dispose它。
- [ ] 在已有真实HomePage fixture增加卸载重建用例，先加载12项、选中第8项，第二次不完成图像检查，断言完整12项/同作品/检查数未增加；运行并确认因当前状态丢失变红。
- [ ] 提取现有页面编排到会话，保留纯buildHomeFeed投影；用AppState惰性所有权与页面监听接入，消除对已销毁BuildContext/mounted的依赖。
- [ ] 用语义签名及generation管理输入变化和刷新；进度不使图片/推荐失效；新增及更新保持当前作品，失败不清空。
- [ ] 增加进行中重入、上下文变化、过期失败与最新进度测试；运行聚焦测试，再运行所有home相关测试。
Run: puro -e webhtv flutter test --no-pub --reporter expanded test/home_hd_hero_backfill_test.dart test/home_hero_session_test.dart

### Task 2: 有界完整图片资源缓存（子代理；run 0/3）
**Files:** Modify apps/desktop-flutter/lib/services/home_hero_startup_cache.dart；Create apps/desktop-flutter/test/home_hero_session_image_cache_test.dart。
**Consumes/Produces:** 精确使用spec中的HomeHeroStartupCache.session构造器，现有read/save/clear不变。只扩展同一安全实现的每实例容量，默认启动实例仍最多3条；session独立目录最多12条。
- [ ] 以12张合格fixture图片写入session缓存，断言read长度12且文件真实可解码；证明默认实例仍最多3、两个命名空间不会相互清理；运行先红。
- [ ] 最小扩展构造器与容量参数，沿用所有实际解码、安全路径与generation逻辑。
- [ ] 测试越界截断、损坏/低清、符号链接、旧写/clear隔离；运行新测试及既有home_hero_startup_cache_test。
Run: puro -e webhtv flutter test --no-pub --reporter expanded test/home_hero_session_image_cache_test.dart test/home_hero_startup_cache_test.dart

### Task 3: 独立真实生命周期回归（子代理；run 0/3）
**Files:** Create apps/desktop-flutter/test/home_hero_session_navigation_test.dart；只读既有fixture及HomePage公开接口。
**Interface:** 只驱动HomePage、AppState、HomeHero、HomeBackdrop公开行为，不靠私有字段或另建假会话。
- [ ] 用mock网络/图片I/O固定外部输入；在同AppState中卸载HomePage到其他页面再重建，断言12项、当前第8作品、最新进度、元数据/图片调用未重复。
- [ ] 在批次未完成时切页，保留已有项、完成同一future后补齐；上下文切换后完成旧future不能污染结果。
- [ ] 如需新测试注入只使用既有heroImageLoader/元数据依赖；不修改生产接口来迁就测试。测试前后清理计时器/临时目录。
Run: puro -e webhtv flutter test --no-pub --reporter expanded test/home_hero_session_navigation_test.dart

### Task 4: 集成与Lead验收（run 0/1）
**Files:** Lead整合Task2图片缓存到HomeHeroSession；更新docs/phase11/design/02-home-feed-contract.md相关契约；本计划记录最终证据。
- [ ] 首次加载后台保存最多12项到session目录，展示优先安全本地文件；当前图更新延后，不增加默认启动读取成本。
- [ ] 审查最终diff逐项对应spec；对子代理输出独立运行目标测试，修复发现的问题，不带已知缺陷交付。
- [ ] 运行全部home相关测试、相关recommendation/cache/identity测试和flutter analyze lib test；Windows Debug build。
- [ ] git diff --check，核对只触及任务范围，无调试输出，无提交/推送。
