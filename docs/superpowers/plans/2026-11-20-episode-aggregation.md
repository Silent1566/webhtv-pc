# 同集多版本聚合 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax for tracking.

**Goal:** 默认收纳同线路重复版本，显示真实大小摘要并可靠选版播放和连播。
**Architecture:** 三个 disjoint 任务并行，共享 interface 冻结在 spec；规则藏于纯 Dart 模块，详情和播放器只消费其结果。现有原始资源与协议为事实来源。Lead 负责文档、接口约束和最终验收，不编辑 active child 的文件。
**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4；无新增依赖。
**Spec:** `docs/superpowers/specs/2026-11-20-episode-aggregation-design.md`

## Global Constraints
- 默认聚合，仅存在可聚合重复的当前线路显示开关；关后仍可开启。
- 不跨线路聚合，不丢资源，不修改来源地址和历史身份，不额外网络请求，不按大小推选版本。
- 不破坏普通卡片1:1不变量；UI延用现有深浅主题与紧凑标题行。
- 先写失败测试再实现；Flutter 命令使用工作树根 `.tools/flutter/bin/flutter`，在 apps/desktop-flutter 运行测试；日志过滤保存至 `.local/episode-aggregation/`。
- 子任务 attempts 上限3次累计；不自动提交/合并；Lead 逐项独立验收。

## Task 1: 共享分组、大小及选版规则（run 3/3，另有 Lead 单点收尾）
Files: create lib/core/episode_aggregation.dart and test/episode_aggregation_test.dart; modify lib/services/ai_integration.dart; test marker in existing AI tests or new focused test.
Consumes: VodEpisode.name/url/extra, sourceEpisodeNumber/sourceSeasonNumber; no UI/network.
Produces: spec 中全部 core interface（不得改名）；AI可信绑定 marker。
- [x] 写表驱动测试：`[5.37G] 01.mkv`/`(1.2 TB) Episode 03`；普通标题与分辨率不识别大小；strip 只移除合法大小。
- [x] 写测试：`S01E01.1080p[1GB]`、`S01E01.2160p[3GB]` 两条应有一个组、sourceIndex `[0,1]`、sizeSummary `1–3 GB`；其他季/上下篇/花絮/未知/位置extra不能合并。
- [x] 运行失败测试，最小实现；补不同单位/部分缺失/全缺失、资源守恒、顺序、唯一同版与歧义及季边界测试。
- [x] 运行新增和既有 AI/TMDB title 测试与定向 analyze；报告确切结果、源码范围及接口确认。

## Task 2: 详情UI、偏好与选择弹窗（run 1/3）
Files: lib/ui/browse_pages.dart; lib/ui/tmdb_detail_view.dart; lib/core/tmdb_detail_model.dart; lib/ui/episode_version_dialog.dart; lib/state/app_state.dart; lib/services/ui_preferences_store.dart; owned UI/preferences/detail integration tests.
Consumes: core spec interface，逐版本原始 sourceIndex；existing TmdbEpisodeCards 仍1:1。
Produces: spec 中 dialog 和 AppState/Store interface。卡片可添加默认无效果的字段如 `variantCount=1`/`fileSizeLabel=''`，不改既有调用语义。
- [x] 先用未改UI的重复资源场景拍深浅主题 Before；编写开关可见性和原始资源点击目标测试。
- [x] 偏好先测默认/持久化/非法值回退，按现有 name-mode 接入。
- [x] 详情先按原始线路判定是否存在可聚合组，季过滤后建立展示分组，之后倒序、区间与焦点定位；已关闭开关不能消失。
- [x] 接入卡片角标/大小摘要/名称分离，单资源不弹窗，多资源确认才解析；聚合原名不随便借首个文件完整名。
- [x] dialog 测试初始选择、修改、确认、取消、长名和键盘；调用返回必须检查 mounted/线路仍同。
- [x] 拍同场景After与弹窗、跑既有 episode_name_mode / preferences / source index / relevant detail tests，检查1024宽和1.5字体、深浅主题。

## Task 3: 上下集与同版本连播（run 2/3）
Files: lib/ui/player_page.dart; 可选 player part 文件；owned player tests，不编辑详情/偏好/core/dialog。
Consumes: core interface，dialog interface，AppState.episodeAggregateVersions。
- [x] 编写失败测试证明下一集跳过同集版本、上一集逻辑组、季边界、关闭聚合回原逻辑。
- [x] 从当前具体 episode 推导版本特征，adjacentGroup 定位组、preferredVersion 唯一匹配或弹窗；取消不换集不写错进度。
- [x] 沿用 _openTarget 原 sourceIndex/flag/URL/lineRoutes；检查异步期间媒体代次和 mounted；对话框防重入。
- [x] 保留直播、catchup、显式queue和本地等原有guard；请求本身带AI marker的列表直接使用，不能把普通富集extra当可信。
- [x] 跑聚合播放器测试与相关 player_episode_panel / autoplay / TMDB/history tests，定向analyze。

## Lead Acceptance（run 1/1）
- [x] 阅读最终 diff、各任务 Red/Green 输出，检查 spec 每项覆盖。
- [x] 风险相关测试合并运行并 analyze；新增缺陷退回原 child，累计最多3 runs。
- [x] 实际打开深浅 Before/After、dialog After，检查布局与字号，确认资源守恒和原URL播放。
- [x] 更新本计划与 task book，交付实现范围、测试结果与已处理风险；不自动commit。

## 验收记录（2026-11-20）

- Lead 独立合并回归：25 个相关测试文件 **541 项通过**（`--no-pub --concurrency=1`，本地 libmpv 前缀），日志 `.local/episode-aggregation/lead/final-acceptance.log`。
- 全部改动/新增 16 个 Dart 文件 `dart analyze`：**No issues found**（`final-analyze.log`）；`git diff --check` 无输出。
- 视觉证据（1024×700，同场景）：`before-dark/light.png`、`after-dark/light.png`、`modal-after-dark/light.png`，位于 `.local/episode-aggregation/detail/`。
- 只读审查两轮：core 内容混淆（【上下】、OP/正片、下划线 Part/trailer）、组内历史预选、手动歧义弹窗未暂停均已 RED→GREEN 关闭；最终快速扫描无新增可复现缺陷。
- R8 fallback：reviewer 在 task1 第三轮后发现 `S01E01上1080p / S01E01下2160p` 仍误并；因 core 已用满 3 次重派，Lead 按 R8 做单点后缀 lookahead 修复并补失败测试（修前 1 组，修后 2 组），201 项 core/回归通过。
- 上述为实现验收时记录；后续用户已明确要求提交、同步最新 beta、推送并创建中文 PR。
- 发布前再次运行同一组 25 个测试文件：541 项通过；16 个改动 Dart 文件静态分析无问题（`.local/episode-aggregation/release/precommit-*.log`）。
