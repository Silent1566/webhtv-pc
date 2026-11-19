# 02 · 首页数据合同、测试矩阵与分阶段计划

## 1. 数据合同（新增 `lib/core/home_feed.dart`，纯 Dart、无 Flutter 依赖）

```dart
enum HomeItemKind { resume, following, recommend }

/// 一张卡 / 一张幻灯片。hero 与轨道**共用同一个类型**：
/// 少一次转换，也就少一处「hero 与卡片对同一部剧说法不一致」的机会。
class HomeItem {
  final HomeItemKind kind;
  final String key;            // 去重键：history → sourceKey|siteKey|vodId；following → identityKey；recommend → entry.key
  final String title;
  final String? poster;        // 2:3
  final String? backdrop;      // 16:9（可空 → 用 poster 兜底）
  final String subtitle;       // 「年份 · 评分」口径见 recommendation_meta.dart
  final String reason;         // 理由行（§3）
  final double progress;       // 0..1；非续播为 0
  final String episodeLabel;   // 「第08集」/「更新至 第12集」
  final PlaybackHistory? history;
  final Following? following;
  final RecommendationEntry? entry;
}

enum HomeRailKind { resume, following, recommendTmdb, recommendDouban }
enum HomeSeeAll { history, following }

class HomeRail {
  final HomeRailKind kind;
  final String title;
  final List<HomeItem> items;   // ≤ 20
  final HomeSeeAll? seeAll;     // 推荐行没有去向，就是 null（01 §4）
}

class HomeFeed {
  final List<HomeItem> hero;    // 0..6
  final List<HomeRail> rails;
  bool get isEmpty => hero.isEmpty && rails.isEmpty;
}

HomeFeed buildHomeFeed({
  required List<PlaybackHistory> history,
  required List<Following> followings,
  List<RecommendationEntry> tmdbRecommendations = const [],
  List<RecommendationEntry> doubanRecommendations = const [],
});
```

**不变量**（每一条都要有对应单测）：

| # | 不变量 |
|---|---|
| I1 | hero ≤ 6，rail ≤ 20，hero 内 `key` 唯一，rail 内 `key` 唯一 |
| I2 | 推荐非空 ⇒ hero 里至少有 1 个 `recommend` |
| I3 | 续播条目 `0 < progress < 0.95`（看完的、没开始的都不进 hero/轨道） |
| I4 | 同一部作品在**四条轨道之间**最多出现一次，优先 `following`（它带「更新」信息）> `resume` > `recommend`；**hero 是轨道的子集**（同一部作品在 hero 与自己那条轨道里各出现一次，这是有意的：hero 是「今天最值得点的三张」，轨道是完整列表；hero 里出现一个下面找不到的作品才是错的） |
| I5 | `isEmpty` ⇔ hero 与 rails 都空（页面据此决定画不画空态） |
| I6 | 输入为空/字段缺失不抛异常：`vodPic` 空、`episodeName` 空、`durationMs == 0` 都必须产出可渲染条目 |

**为什么是纯函数**：排序、去重、理由行都是本页最容易被写歪的部分（跨源同名、看完没看完、更新没更新），而它们不需要 Flutter。做成纯函数后可以用 `flutter test` 直接钉死，与仓库里 `hot_rank_layout.dart` / `recommendation_target.dart` 的分层一致。

## 2. 排序与理由行（确定性，无学习权重）

### 2.1 hero 取哪 6 张

1. **追剧有更新**：`latestReleasedEpisode > watchedEpisode` 的 `Following`，按 `updatedAtMs` 降序，最多 **3** 张。
2. **未看完的续播**：`0 < progress < 0.95`，按 `updatedAt` 降序，同标题只留最新一条，最多 **6** 张。
3. **个性推荐**：TMDB 与豆瓣**交替**取（tmdb, douban, tmdb, …），最多 **3** 张。
4. 三类预算之和 = 总数 **12**，所以**没有**「排满再裁员」这一步，也没有「推荐被挤掉就换回来」的补偿：推荐位结构上就占着 3 个（I2 从「要照顾」变成「不可能违反」）。2026-11-19 由用户要求从 6 放大到 12 时删掉了那两段死代码。
5. 总数 < 3 ⇒ **就按真实数量渲染**，不凑数、不循环。
6. **首次使用兜底**：本机三类全空时，hero 用**热门三榜轮流**取前 12 条（电影/剧集/综艺交替，避免「12 张电影海报＝这是个电影站」的错觉）；点主按钮 = 带着标题去搜索。

### 2.2 轨道排序

| 轨道 | 排序 |
|---|---|
| 继续观看 | 同 2.1-2，最多 20 |
| 追剧更新 | 先「有新集未看」，再按 `nextAirAtMs` 升序，再按 `createdAtMs` 降序 |
| 个性推荐 | 保持服务返回顺序；两行之间按 `recommendationTitleKey(title)` 去重，TMDB 行优先 |

### 2.3 理由行（一行，超出省略号）

| kind | 文案 | 降级 |
|---|---|---|
| resume | `继续观看 · {episodeName} · 剩 {M} 分钟` | `episodeName` 空 → 「继续观看 · 剩 M 分钟」；`durationMs == 0` → 「继续观看」 |
| following | `更新至 {latestEpisodeName}` +（air data 到达后）` · {平台} {播出时间}` | 无 air data → 只显示前半句 |
| recommend | `entry.reason` 非空直接用 | 空 → 「{年份} · {评分}」；再空 → 不显示理由行 |

剩余时间 `M = ((1 - progress) * durationMs / 60000).ceil()`，`M > 999` 不写分钟（异常数据不写成「剩 100000 分钟」）。

**两条降级分支在 I3 之后不可达**（落地时由实现者指出，此处记档）：`durationMs == 0 → 「继续观看」` 与 `M < 1 → 「不到 1 分钟」`——因为进续播的条件是 `durationMs > 0` 且 `progress < 0.95`，剩余量恒大于 0，`ceil` 的下界就是 1。实现保留这两句作为防御性格式化（纯字符串 helper 里两行），用例钉的是「不可达」这一事实而不是伪造一条能触发它的数据。

## 3. 首屏时序：本地先出，推荐后补，且**不重排**

```text
第一帧      recentHistory(sourceKey:'') + followings  ──► buildHomeFeed(...)  （同步、无网络）
            ⇒ hero + 继续观看 + 追剧更新 立刻可画
post-frame   acquire lease → personal(tmdb) → personal(douban)（串行）
            ⇒ 合并：hero 不足 3 张才追加到尾部；≥3 张则 hero 一动不动，只更新推荐轨道
失败        error ⇒ 该轨道消失，不 toast、不留红条
```

**追加不重排**是硬规则：推荐是异步来的，如果它到了就重排 hero，用户会在读第一张的时候被换掉一张图。落地实现比这条更严——**只追加、从不驱逐**：

```text
local.hero 为空              → 直接用带推荐的 feed（推荐可以当主角）
否则                          → [...local.hero, ...recommend-only 追加项].take(6)
```

`take(6)` 只截尾部，前缀顺序一个字都不动，所以「当前是第几张」天然不变；代价是本地已有 6 张时推荐进不了 hero（它们仍在轨道里）。`buildHomeFeed` 内部的 I2 替换只在「推荐一开始就在」的输入下才有意义，页面层不会触发它。

**为什么不用骨架屏**：本地读库是同步的（`AppState.recentHistory` 直接返回 `List<PlaybackHistory>`），第一帧就有真内容；骨架只在「其实没得显示」时才需要，这里反而是噪音。

## 4. 缓存与推荐取数（用户决策 3：优先缓存再刷新，与详情页同一机制）

不新建缓存层。首页直接走 `AppState.recommendationDependencies`（`app_state.dart:1425`），它已经是详情页在用的那一套：

| 层 | 行为 | 出处 |
|---|---|---|
| 内存池 | 同 key 复用同一 `_Pool` | `tmdb_recommendation_service.dart:444-447` |
| 磁盘 TTL | 7 天内直接用，**不发请求** | `:26`、`:448-452` |
| 过期 | 才取网络；取失败回退旧缓存 | `:454-460` |
| 豆瓣 | 7 天缓存；失败回退旧缓存；请求间隔 750ms；403/418 冷却 30 分钟 | `douban_recommendation_service.dart:622-690` |

**缓存键必须稳定**（本页最容易踩的坑）：`_key` 由 `current` + `seeds` + `detail` 拼成（`tmdb_recommendation_service.dart:463-488`）。首页固定用：

```
current = history[0]              // 最近一条，按 updatedAt 降序
seeds   = history[1..min(4, n)]   // 最多 3 条
detail  = null
```

只要用户没再看新的一集，这个键就不变 ⇒ 第二次启动命中磁盘缓存 ⇒ **一条请求都不发**。反过来，如果拿「全部历史」当种子，看一集就换一个键，首页每次启动都会重新打网络。

**`personal()` 需要 `current`**（`tmdb:125`、`douban:58`）：首页把 `history[0]` 当 current、其余当 history。**不改服务签名**——给首页加一个「无 current」的变体会让「种子怎么排、怎么排除已看」出现两份实现，而这两份一歪就是「推荐里出现你昨天刚看完的剧」。

**不做 stale-while-revalidate**：详情页也没有；首页在每次启动时都主动刷新，会把豆瓣请求从「进详情页才发」放大到「每次开应用都发」，750ms 串行 + 30 分钟冷却的机制就是为这个量级设的。

## 5. 生命周期与共享

- 进首页 `acquire()`，销毁 `release()`（`detail_recommendation_state.dart:112-135`）。**必须**：豆瓣 provider 的 750ms 间隔 Timer 不能活在 widget 树之外，否则 `flutter_test` 直接报 pending timer（这个 bug 仓库已经付过一次代价，见 `:16-22` 的注释）。
- 首页与详情页共用 `RecommendationFeedbackStore`：用户在详情页点过「不感兴趣」的作品，首页推荐里也不出现（`recommendation_feedback_store.dart`）。这条是免费得来的，但要有用例守住。
- `AppState` 本身是 `ChangeNotifier`（`historyChanges: this`）：播放结束回首页时，**重算本地 feed 但不重新请求推荐**（除非种子组变了 → 键变 → 自然没有缓存命中）。

## 6. 组件决策：不扩展 `TmdbBackdropSlideshow`

`TmdbBackdropSlideshow`（`tmdb_detail_view.dart:55`）的 `child` 是**静态**的、索引是私有的、key `tmdb-backdrop-slideshow` / `tmdb-backdrop-dots` 已被集成测试按名查找。首页要的是「每张幻灯片有自己的标题与按钮 + 悬停暂停 + 键盘」，硬塞进去就是把一个已锁死的组件改成双模式。

因此：

1. 新建 `lib/ui/home_hero.dart`（受控索引 + 每张自带内容 + 悬停暂停 + 键盘 + reduced motion）；
2. **只提取遮罩**：把 `tmdb_detail_view.dart:236-260` 那段 `LinearGradient` 抽成 `lib/ui/backdrop_scrim.dart` 的 `BackdropScrim(kind)`，两处共用。提取时颜色与 `stops` **逐字不动**，并跑 `test/phase4_tmdb_detail_view_test.dart` + `integration_test/tmdb_detail_visual_flow_test.dart` 确认详情页截图无差异；
3. 复用 `TmdbBackdropRotation` 的三个纯函数 `shouldRotate`/`next`/`clamp`（`tmdb_detail_model.dart:63-84`）；**间隔常量不复用**：详情页 5s 是给纯图片的，首页 8s（理由见 01 §3.5）。

## 7. 测试矩阵

### 新增

| 文件 | 钉住什么 |
|---|---|
| `test/home_feed_test.dart` | I1–I6、§2.1 五条取数规则、§2.2 三条排序、§2.3 理由行与全部降级分支、空输入 |
| `test/home_page_test.dart` | 首帧就有内容（无骨架）；推荐未到时推荐轨道**不存在**；推荐到达后追加到尾部且 hero 首图不变；轨道空则隐藏；`isEmpty` 时出空态 |
| `test/home_hero_test.dart` | 4 个视口的 hero 高度取值；指针进入后 `pump(9s)` 不换图、离开后恢复；←/→ 切页；`≤2` 张不显示指示点；reduced motion 不自动轮播；**卸载后无 pending timer** |
| `test/shell_rail_capacity_test.dart` | 1024×640 下 11 项侧栏不溢出（`tester.takeException()` 为 null） |
| `integration_test/home_hero_visual_flow_test.dart` | 三张截图（首屏 / 第二条轨道 / 空态），口径见 01 §8 |

### 修改

| 文件 | 改什么 | 为什么 |
|---|---|---|
| `integration_test/ui_redesign_visual_flow_test.dart` | 外壳截图内容变为新首页；`_settleHome` 仍等 `contentPhase` | 状态层的站点首页加载没变（那是点播页的数据），只是首屏不是它 |
| `lib/ui/browse_pages.dart` | `_WheelScroll` 提升为 `lib/ui/scroll_behavior.dart` 的公开 `WheelScroll`，两处共用。**本轮未做**（见 §10 开放项） | 横向轨道要用同一条「纵轮转横」规则，不能再抄一遍 |

### 经核对**不需要改**（2026-11-19 落地时复核）

| 文件 | 为什么不用改 |
|---|---|
| `integration_test/mvp_a_flow_test.dart` | 那个用例的浏览页断言是**直接 `pumpWidget(Scaffold(body: BrowsePage(state)))`**（`:511-515`），根本不经过外壳；启动段的默认值变了不影响它。设计稿最初判断「要加一步 tap 点播」，实测核对后是错的。 |
| `integration_test/ui_redesign_visual_flow_test.dart` | 外壳截图的内容会变成新首页，但断言只有 `NavigationRail` 存在、`WebHTV` 存在、无异常；`_settleHome` 等的是状态层的 `contentPhase`，与首屏是哪个段无关。**截图需要重拍**，断言不用改。 |

### 不用改（但要跑）

`test/shell_motion_test.dart`（按枚举值选中，不看下标字面量）、`test/settings_categories_navigation_test.dart`（只允许一个 `NavigationRail`）、`test/phase6_history_page_test.dart`（列宽基准是内容区宽）、`test/phase9_following_unread_test.dart`（`find.descendant(of: NavigationRail)` 找角标）。

## 8. 分阶段计划

每个阶段独立可验收、可回退；**不做**一次性大改。

### Phase A · 改名 + 外壳（新首页只是空壳）

- 改动：`lib/ui/app.dart`（枚举 + 侧栏 + `scrollable: true` + 默认段 + 三个回调注入）；新增 `lib/ui/home_page.dart`（hero 只画本地续播 + 空态）；新增 `test/shell_rail_capacity_test.dart`；`integration_test/mvp_a_flow_test.dart` 加一步。
- 验收：`dart analyze` 干净；`flutter test test/shell_motion_test.dart test/shell_rail_capacity_test.dart`；`mvp_a_flow_test` 仍绿；外壳首屏 Before/After 截图。
- 回退：`app.dart` 一处枚举 + 一个 destination 即可退回。

### Phase B · 三条轨道 + 纯逻辑

- 改动：新增 `lib/core/home_feed.dart`、`lib/ui/home_cards.dart`；`lib/ui/home_page.dart` 铺三条轨道；`_WheelScroll` 提升到 `scroll_behavior.dart`；新增 `test/home_feed_test.dart`、`test/home_page_test.dart`。
- 验收：两个新测试文件全绿；`flutter test` 全量不回归；新增轨道 Before/After 截图。
- 回退：轨道各自独立，删一条只少一条。

### Phase C · 推荐接入 + 交互打磨

- 改动：新增 `lib/ui/home_hero.dart`、`lib/ui/backdrop_scrim.dart`；`lib/ui/home_page.dart` 接 lease + 合并逻辑；新增 `test/home_hero_test.dart`、`integration_test/home_hero_visual_flow_test.dart`；`tmdb_detail_view.dart` 改用 `BackdropScrim`。
- 验收：三张截图；pending timer 为零；详情页截图无差异（遮罩提取的回归证据）。
- 回退：去掉推荐轨道即退化为 Phase B 的形态。

### 文档收尾（随 Phase C）

- `DESIGN.md`：侧栏清单加一项并改标签；`Layout` 一节补「首屏 hero 高度公式」与「横向轨道复用 `HorizontalMouseDrag`」；`Open Items` 记「缩略图条（>6 张时）未做」。
- ADR 0011 状态从「提议」改为「接受」。

## 9. 工作量

| 阶段 | 新增文件 | 改既有文件 | 代码行（估，含测试） |
|---|---|---|---|
| A | 2（页面 + 用例） | 1（app.dart）+ 1（mvp_a 用例） | ~300 |
| B | 4（core / cards / 2 用例） | 2（home_page / browse_pages+scroll_behavior） | ~900 |
| C | 4（hero / scrim / 2 用例） | 3（home_page / tmdb_detail_view / ui_redesign 集成用例） | ~800 |
| 合计 | 10 | 6 | **~2,000–2,400**（其中测试约 600） |

## 10. 开放项

**Phase C 已全部落地**（租约接入、hero 键盘、`BackdropScrim`、`WheelScroll` 提升），并追加了两块：热门轨道（`core/home_hot.dart`，360kan 三榜）与元数据优先级取图（`services/home_art_service.dart`）。仍然没做的只剩三项：

| 项 | 现状 | 影响 |
|---|---|---|
| hero 超过 6 张时的缩略图条 | 只有 6px 指示点 | 6 张以内够用；真要放更多，点会细到不好点 |
| 没有 TMDB 身份的历史/追番取图 | 仍是站点海报 | 按标题去 TMDB 搜一遍是 N 次请求，首屏付不起；要做得先有一层「标题→身份」的批量匹配与缓存 |
| 推荐卡的精确去向 | 点推荐卡/hero 主按钮去点播页 | 详情页的推荐行仍走 `recommendationTargetFor` 的三条去向；首页第一版不做第二条解析链 |

## 11. 风险登记（全部有归属）

| # | 风险 | 处理 |
|---|---|---|
| 1 | `DESIGN.md:185/187` 与本次首屏形态冲突，不改文档等于文档说谎 | ADR 0011 + Phase C 改 `DESIGN.md` 三处 |
| 2 | 侧栏第 11 项在最小窗口溢出 | 已实测；`scrollable: true`；新增容量回归用例 |
| 3 | 缓存键随历史变化 ⇒ 每次启动打网络 | 固定种子组（§4），并有用例断言「第二次进入首页不发请求」 |
| 4 | 推荐晚到导致 hero 重排 | 追加不重排 + 按 key 保持当前张 |
| 5 | 既有集成用例断言启动页 = 点播 | 已核对：`mvp_a` 直接 pump BrowsePage（不经外壳）、`ui_redesign` 只断言外壳骨架——**一条都不用改**，只需重拍截图 |
| 6 | 豆瓣节流被首页放大 | 串行、只在首页可见时发起、靠 7 天缓存挡住重复 |
| 7 | 遮罩提取动到已锁组件 | 数值逐字不变 + 详情页截图对比 |
| 8 | 「首页」二字在仓库里有歧义（站点首页 `homeResult` vs 侧栏入口） | 只改 UI 标签；`homeResult`/`contentPhase`/`loadHome` 等标识符**一律不动**（`test/` 97 处、`integration_test/` 30 处大多是站点首页语义，机械替换会造成大面积误改） |
