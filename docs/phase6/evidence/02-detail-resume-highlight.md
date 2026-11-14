# Phase 6 · plans/02 验收证据

- 计划：`docs/phase6/plans/02-detail-resume-highlight.md`
- 设计：`docs/phase6/design/02-detail-resume-and-highlight.md`
- 提交范围：`622ea85`（基线）→ `eded0bc`（Task 6 实现）→ `6157a4c`（Task 6 收尾文档）
- 测试文件：`apps/desktop-flutter/test/phase6_detail_resume_test.dart`（**33 个用例**）

## 1. 任务与提交

| Task | 内容 | 提交 | 测试 |
| --- | --- | --- | --- |
| 1 | 历史解析（线路三级匹配 + 集匹配，纯逻辑） | `9a1c24c` + 修复 `9772d16` | 12 |
| 2 | 首屏按钮文案决策（纯逻辑） | `6d6fcf5` | 16 |
| 3 | `DetailPage` 接受历史参数并自动选线路 | `71c8ba2` + 修复 `078a251` + 钉子 `1e6b852` | 22 |
| 4 | 首屏按钮接历史（文案 + 目标集） | `e606e19` + 钉子 `657e7cc` | 26 |
| 5 | 线路 chip 的「最近播放」标记 | `ead72e0` | 29 |
| 6 | 选集卡片的「最近播放」标记 | `eded0bc` | 33 |

## 2. 门禁结果（独立复跑核实，非采信 implementer 报告）

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| 聚焦测试 | `flutter test test/phase6_detail_resume_test.dart` | **33/33 通过** |
| 回归（详情页 + TMDB UI） | `flutter test test/phase4_tmdb_detail_view_test.dart test/phase4_tmdb_ui_test.dart test/phase3_detail_page_test.dart` | **64/64 通过** |
| 全量 | `flutter test` | **1686 通过 / 0 失败** |
| 静态分析 | `flutter analyze` | `No issues found!` |

全量门禁判定按 `design/05` §7.1 的裁定：**失败集合 ⊆ 已知 flaky 集合
且每项单独跑通过**。本阶段观察到 7 次全量运行的失败数漂移
2 → 4 → 0 → 0 → 0 → 1 → 0，已知 flaky 四个文件（见 `design/05` §7.1 表）。

## 3. 验收标准 B1–B12

| # | 断言 | 状态 | 证据 |
| --- | --- | --- | --- |
| B1 | 无历史 → 「播放第一集」，点击播第 0 集 | ✅ | Task 4 用例 1；点击路径与 B2 同一段代码 |
| B2 | 有历史且命中 → 「继续播放 · <集名>」，点击播**那一集** | ✅ | Task 4 用例 2 + 用例 4（变异钉子） |
| B3 | 已看完 → 回到「播放第一集」 | ✅ | Task 4 用例 3 |
| B4 | 位置过短 → 同上 | ✅ | **组合覆盖**（见 `design/02` §8.1） |
| B5 | 历史线路已不存在 → 退回第一条，不报错 | ✅ | Task 3 用例 2 |
| B6 | 集入口多线路出现 → 歧义 → 退回第一条 | ✅ | Task 1 用例（第二级歧义） |
| B7 | 自动切到历史线路 | ✅ | Task 3 用例 1 + §4.1 用例 |
| B8 | chip 有「最近播放」标记且仍可切换 | ✅ | Task 5 三个用例 |
| B9 | 选集卡有标记且外壳仍是 `OutlinedButton` | ✅ | Task 6 四个用例 |
| B10 | 剧照仍是 16:9 | ❌ **未达成** | 见 `design/02` §8.2（既有偏差） |
| B11 | `detail-hero-play` key 仍存在 | ✅ | Task 4 用例 1/2/3 + `phase3_detail_page_test` |
| B12 | 从历史页进详情页时站点已先切换 | ⏸ | 由 **plans/01 Task 8** 交付 |

## 4. 变异测试证据（本轮最有价值的产出）

四个任务各做了一次变异自检，**共抓到 5 处覆盖缺口**，都补了能杀死变异的钉子：

| Task | 变异 | brief 给的用例 | 补的钉子 |
| --- | --- | --- | --- |
| 3 | 删 `belongs &&` 守卫 | 全过 | 「详情未到达（残留别的影片详情）→ 不切线路」 |
| 4 | 点击目标改回硬编码 `0` | 全过 | 「点击播历史命中那一集」 |
| 5 | 删 `matched` 守卫 | 全过 | 「历史线路在但那一集已消失 → 不标」 |
| 6 | 删 `!target.matched` 守卫 | 全过 | 「matched=false 时任何集卡片都不标」 |
| 6 | 删 `rawLine.flag != target.flag` 守卫 | 全过 | 「切到非历史线路后不标」（**brief 未预见**） |

**共同模式**：用例只覆盖判据的**肯定面**，守卫的反实现照样全绿。
教训已写进 `plans/02` 的 Task 5/6 说明。

## 5. 实现过程中的计划缺陷（共 12 处，全部核实并修好）

| # | 计划/任务 | 缺陷 | 谁发现 |
| --- | --- | --- | --- |
| 1 | plans/02 Task 1 | 实现第三级与测试用例 4 矛盾 | implementer |
| 2 | plans/01 Task 1 | 追加带 `library;` 的块 → `library_directive_not_first` | implementer |
| 3 | plans/02 Task 1 | `core/` 不得依赖 `services/`（收 `PlaybackHistory`） | controller pre-flight |
| 4 | plans/02 Task 1 | 角标 key 与测试断言不一致 | controller pre-flight |
| 5 | plans/02 Task 1 | 剧照 16:9 断言与实现不符 | controller pre-flight |
| 6 | plans/02 Task 3 | `vodPlayFrom` 未转义 `$$$` → 编译失败 | implementer |
| 7 | plans/02 Task 3 | 缺滚动（满屏 hero）→ 控件未挂载 | implementer |
| 8 | plans/02 Task 3 | 声称已有 `storage.dart` import，实际没有 | implementer |
| 9 | plans/02 Task 3 | 要求加未使用的 import | implementer |
| 10 | plans/02 Task 4 | 缺详情注入 + 要求加未使用 import | controller pre-flight |
| 11 | plans/02 Task 5 | 缺滚动 + 缺注入 + `$$$` 未转义 | controller pre-flight |
| 12 | plans/02 Task 6 | 缺注入 + 单次 `drag(-3000)` 太脆 | controller pre-flight |

第 6–12 处是**同一类**「`DetailPage` 全页 widget 测试的前置条件」缺陷。
已做**跨计划排查**：plans/03 四处 pump 的都是子组件（无需处理）、
plans/04 的 D19 已补 `revealEpisodeSection`。

## 6. 已知未闭合项（交最终验收裁定）

| # | 项 | 性质 | 影响 |
| --- | --- | --- | --- |
| 1 | **B10 剧照不是 16:9** | 既有偏差（先于 Phase 6） | 违反 `DESIGN.md` 固定比例纪律；修它需独立重构（卡片高度 + 网格 extent） |
| 2 | 展示 flag vs `playbackFlag` | 设计缺口 | 桥接站点下按钮文案可能与实际续播不一致（观感，不阻断） |
| 3 | 既有两个角标未用 `AppSpace`/`AppRadius` token | 既有偏差 | 与 `DESIGN.md` token 纪律不符 |
| 4 | `history_view.dart` 第三级内 URL 分支不可达 | 死代码 | 可读性 |
| 5 | `history_view.dart` flag 谓词两处重复 | DRY | 可读性 |
| 6 | `revealLineSelector` 循环静默返回 | 可诊断性 | 失败时报错信息不够清晰 |
| 7 | `build` 里重复同步 DB 查询（Task 4/5/6 各一处） | 性能 | 每帧几次带索引的同步 SELECT，实测可接受 |
| 8 | `Tooltip` 加在所有 chip 上（`design/02` §5 只要求标记的那个） | 过度指定（我的 brief） | 未标记 chip 的 tooltip 信息量低于可见标签 |
| 9 | 网格分支 `isRecent` 透传无用例覆盖 | 覆盖度 | 变异 C 只杀列表分支 |
| 10 | `-d windows` 集成测试与截图未跑 | 环境 | 本机无设备；角标 key 的门禁安全性已静态核实 |
| 11 | 新钉子通过 SnackBar 错误文案间接观察播放目标 | 观察边界 | 不证明真实站点下播放器收到的 `episodeIndex` 正确 |
| 12 | widget 测试依赖 `_siteService == null` | 脆弱前提 | 若 bootstrap 在临时目录产出配置，注入会被清空并静默改变用例语义 |

## 7. 执行方式记录

- **就地执行**（未建 worktree）：计划写在工作树之上（`lib/ui/tokens.dart` 等为未跟踪文件）。
- **审查**：Task 1–3 有独立审查；**Task 4–6 由 controller 自审** ——
  独立审查连续 3 次在「diff 含 25+ 个 widget 用例」时失败（无收尾消息）。
- **控制器裁定共 9 条**，全部记录在 `.superpowers/sdd/02-detail-resume-highlight/progress.md`
  （含每条的理由与「若错，代价是什么」）。
