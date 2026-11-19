# Phase 11 · 首页（观测台）设计索引

状态：设计已定稿，代码未动（用户 2026-11-19 决策：本轮终点是「评估 + 设计 + 分阶段计划」）。

## 这一轮要解决什么

用户需求原话（2026-11-19）：

> 想把现在的首页改名成点播，再重新新增一个首页分类，内容是全屏的大海报幻灯片，显示的可选内容主要是：最近观看，追剧，个性推荐这类续播，推荐等用户想点击即用有很大屏美化的 UI 和交互。

拆成三件事：

1. **改名**：侧栏第一项「首页」（按站点浏览的分类 + 海报墙）改叫「点播」，**行为一个字不改**。
2. **新增**：一个新的「首页」成为第一屏——全幅 hero 幻灯片 + 三条续播/推荐轨道。
3. **不改名只加页是不够的**：新首页要「点击即用」，所以它必须直接接到既有的三条播放/推荐链路（`resumeHistoryEntry`、详情页、`recommendationTargetFor`），而不是再造一套。

## 三个已定决策（用户 2026-11-19）

| # | 决策 | 结论 | 影响 |
|---|---|---|---|
| 1 | 本轮交付 | 评估 + 设计 + 分阶段计划 | 本轮只产出文档；代码要单独批准后落地 |
| 2 | 全屏边界 | hero 铺满**内容区**，保留顶栏 64px 与侧栏 76px | 不改外壳契约（`DESIGN.md:290`「顶栏与侧栏保持实底」），不做沉浸模式 |
| 3 | 推荐取数 | 优先缓存再刷新，与详情页推荐**同一条机制** | 不新建缓存层，直接复用 `DetailRecommendationDependencies` 的 7 天磁盘缓存 |

## 落地状态（2026-11-19）

**Phase A + B 已落地**（代码在本工作区，未提交）：

| 块 | 落点 | 证据 |
|---|---|---|
| 外壳：新增 `home` 段、`browse` 改标签「点播」、启动落首页、`scrollable: true` | `lib/ui/app.dart` | `test/shell_rail_capacity_test.dart`（3 例） |
| 排序 / 去重 / 理由行（纯逻辑） | `lib/core/home_feed.dart` | `test/home_feed_test.dart`（41 例） |
| 卡片与轨道 | `lib/ui/home_cards.dart` | `test/home_cards_test.dart`（10 例） |
| hero（轮播 / 悬停停表 / 指示点 / 进度线 / 减少动效） | `lib/ui/home_hero.dart` | `test/home_hero_test.dart`（10 例） |
| 页面装配与空态 | `lib/ui/home_page.dart` | `test/home_page_test.dart`（3 例） |
| `reducedMotionOf` 由私有转公开 | `lib/ui/app_motion.dart` | 壳层过渡与首页 hero 共用一处判据 |

**Phase C 已落地**（同日）：

| 块 | 落点 |
|---|---|
| 个性推荐接入（租约 + 只追加不驱逐） | `lib/ui/home_page.dart`（`acquire`/`release`、串行取 TMDB→豆瓣、`_merge`） |
| hero 键盘 `←/→/Enter/Space` | `lib/ui/home_hero.dart`（`Focus(autofocus, skipTraversal)`） |
| 遮罩提取，详情页与首页共用 | 新增 `lib/ui/backdrop_scrim.dart`，`tmdb_detail_view.dart` 改用它 |
| 轨道「纵轮转横」 | `WheelScroll` 由 `browse_pages` 提升到 `scroll_behavior.dart`，`HomeRailView` 接入 |
| 视觉取证（After） | `test/home_visual_capture_test.dart`（`HOME_CAPTURE=1`）→ `.impeccable/review/home-hero.png`、`home-empty.png` |
| `DESIGN.md` 回改 | 侧栏清单 / 首页构成 / `:187` 那两句的限定 |

**追加（同日，用户反馈后）**：① 热门轨道（电影/剧集/综艺，360kan 榜单）——用过也照样给，只去掉与本机重名的；点热门卡带着标题进搜索页。② 图片来源走元数据优先级：续播条目按已绑定的 `tmdbId` 取 TMDB 海报/背景（`services/home_art_service.dart`，命中缓存不发请求），取不到保留站点海报；不按标题去搜（N 次请求付不起）。③ hero 由「模糊底 + 小海报」改为「有背景图才铺图，否则夜空渐变 + 一张大而锐利的海报」，高度 0.68 → 0.62。

**截图复核真正改掉的三处**（看图像才发现，analyze 与断言都发现不了）：① 续播的进度线贴到窗口左右缘、读起来像按钮下面的一条分隔线 → 改成与内容同内边距 + 一条暗轨；② 轨道标题与卡片齐左在 0 → 改成左边距 24（右缘仍不设内边距，卡片可以溢出）；③ 没有背景图时 hero 与页面同色、像没加载完 → 改成夜空渐变。

两条落地时确认的口径（已写进 02 文档）：

1. **hero 是轨道的子集**——同一部作品在 hero 与自己那条轨道各出现一次，这是有意的；四条轨道之间才互斥。
2. **§2.3 的两条降级分支不可达**——I3 已经排除了能触发它们的输入，实现保留为防御性格式化，用例钉的是「不可达」这一事实。

## 文档清单

- `01-home-hero.md` —— 首页规格：外壳改动、三区结构、hero 尺寸/素材/遮罩/交互、三条轨道、状态矩阵、文案表、明确不做的事。
- `02-home-feed-contract.md` —— 数据合同、排序去重规则、首屏时序、租赁生命周期、测试矩阵、分阶段计划与文件级改动清单。
- `../adr/0011-home-is-the-first-screen.md` —— 记录这次对 `DESIGN.md` 两处既有结论的**修正**（不是无视）。

## 与既有文档的关系

- `DESIGN.md:185` 拒绝「深色海报墙 + 顶部主视觉横幅」，`DESIGN.md:187` 把首页定为「分类条 + 海报网格」——**这两条针对的是「源场要不要占首屏」**，不是「首屏能不能是内容本身」。本次不把源场搬回来（那个结论仍然有效），只是把首屏从「等用户挑分类」换成「已经知道你想看什么」。修正口径见 ADR 0011。
- `docs/webhtv-pc-design.md` §17.1.5（详情页 hero）与 `apps/desktop-flutter/lib/ui/tmdb_detail_view.dart` 的 `TmdbBackdropSlideshow` 是本次 hero 的**直接前身**：全幅 cover + 顶部对齐裁切 + 底部压暗遮罩 + 6px 琥珀指示点，都是已经过用户实测确认的（2026-10-13「我要的是全屏」、2026-10-23「全屏被截取不好看」）。本设计不发明新的视觉语言。
