# 详情页选集卡片集级手动匹配设计

状态：已实现并验收（2026-11-21）。实现与验收记录见 §10。四条产品决策由用户拍板：顺延**跨季继续**；同集冲突**允许并存**；入口走**卡片右键/长按菜单**；综艺**按 TMDB 类型显示「第 N 期」**。

## 1. 问题与现状（读代码得到的事实）

- 卡片集号与元数据**只有自动推导**：`TmdbEpisodeCards.build` 用「源集名解析集号（`第X集/话/回/期/章节`），解析失败回退线路位置 +1」，再按**当前选中季**取同号 TMDB 集（`TmdbState.episodeCardsForEpisodes` → `episodeMetadataByNumber`）。源站命名整体偏移一位、缺号、前几集是预告时，整条线路的集号/剧照/标题全错。
- 人工纠正只有两级：作品级（`MetaMatchDialog` / `matchTmdbManual`，手动结论锁死不被自动覆盖）、季度级（`TmdbSeasonDialog` 手动绑定 + AI 整批识别 `ai_season_episode_mappings`）。**集级没有**——用户明明知道「这张卡是第 10 集」，却只能整批重跑 AI 或忍受错位。
- 安卓参考实现同类能力也只有作品级（`TmdbMatchCache`）与季度/分段级（`EpisodeSeasonSegments`，见 `docs/tmdb-season-manual-match-design.md`），**没有集级** → 本特性没有上游合同，契约由本设计自定。
- 最近的可复用落点：`AiEpisodeBinding(sourceIndex, seasonNumber, episodeNumber)`、`applyAiEpisodeBindings`（写 `tmdb_season_number`/`tmdb_episode_number`/`episode_identity_confirmed`/`display_name`）、`hasAiMappings` 渲染分支与季节 chips、以及 `EpisodeAggregation`（卡片=聚合组）。

## 2. 已定要求

1. **粒度 = 卡片**：一张卡（聚合开启时的「同集多版本」组）算一集；组内**所有**版本共享同一绑定，播放仍取原 `VodEpisode`/URL。
2. **默认顺延**：把第 i 张卡指定为目标 (S,E) 后，其后每张卡 +1（综艺同构：+1 = 下一期），直到下一个锚点或线路末尾。弹窗另给「仅此一集」。
3. **跨季继续**：`episode+1 > seasonEpisodeCounts[season]` 时进入下一季 E1；季集数缺失/为 0 时**不跨季**、超出部分不绑定（退回自动），绝不造不存在的集号。
4. **冲突并存**：两个源集落到同一目标时如实显示（卡面标「重复」）；不跳号、不覆盖、不丢集。
5. **入口 = 卡片菜单**：右键或长按在指针处弹出「播放 / 剧集详情 / 手动匹配… / 恢复自动匹配（仅已绑定时）」。区块头**不加**第 5 个图标按钮，只在存在绑定时多一行「已手动匹配 N 处 · 清除」。
6. **综艺文案**：TMDB `genres` 命中 {真人秀, 脱口秀, Reality, Talk} 时卡面角标/副标题/选择器用「第 N 期」（多季时为 `S2 第 3 期`），语义不变；判错只影响文案。
7. **优先级**：手动锚点 > AI 逐集绑定 > 自动号解析；AI 重跑**不清除**手动锚点；作品身份（`tmdb_id`/`media_type`）变化时手动行与 AI 行同规则清除。
8. **不改变播放事实**：URL、历史 key、续播身份、聚合分组依据（只信 `episode_identity_confirmed`）、区间/倒序/网格语义一律不动。
9. **只在当前线路可用**：卡片只为当前线路渲染；纯 TMDB 导航页无站源集，无入口。
10. **可撤销可解释**：单卡「恢复自动匹配」；区块头「清除全部」；失效锚点显式提示，不静默丢。

## 3. 纯逻辑契约（冻结）

文件 `lib/core/episode_manual_match.dart`（只依赖 `episode_aggregation.dart` 的 `EpisodeGroup`，无 IO、无 Flutter）：

```dart
class EpisodeMatchAnchor {
  final int sourceIndex;   // 锚点所在组任一版本的原始线路下标（存储用代表值）
  final String sourceName; // 该版本源集名，用于顺序变化后重定位
  final int seasonNumber;
  final int episodeNumber;
  final bool spread;       // true=从此集起顺延；false=仅此一集
}

class EpisodeMatchTarget {
  final int seasonNumber;
  final int episodeNumber;
}

abstract final class EpisodeManualMatch {
  /// 原始线路 → 逐 sourceIndex 目标（覆盖组内所有版本）。
  static Map<int, EpisodeMatchTarget> resolve({
    required List<EpisodeGroup> groups,        // 原始线路（未套任何绑定）的聚合组
    required List<EpisodeMatchAnchor> anchors,
    required Map<int, int> seasonEpisodeCounts,
  });

  /// 顺序/集名变化后重定位：能唯一按 sourceName 找回就改绑新组，否则丢弃并计入 dropped。
  static List<EpisodeMatchAnchor> relocate({
    required List<EpisodeGroup> groups,
    required List<EpisodeMatchAnchor> anchors,
    required Set<int> dropped,
  });

  /// 落到同一目标的 sourceIndex（卡面「重复」标记用）。
  static Set<int> duplicateIndexes(Map<int, EpisodeMatchTarget> targets);

  /// genres 命中真人秀/脱口秀（中英）即视为综艺。
  static bool isVariety(List<String> genres);

  /// 「第 3 期」/「S2 第 3 期」/「S1E3」/「E3」。
  static String unitLabel({
    required bool variety,
    required int seasonNumber,
    required int episodeNumber,
    bool compact = false,
  });
}
```

规则细则：

- **身份 = 组**：锚点 `sourceIndex` 落在哪个组就绑哪一组，组内所有 `version.sourceIndex` 都拿到同一目标；组的划分来自 `EpisodeAggregation.build(原始线路)`，与聚合开关、倒序、区间、名称切换无关。
- **顺序 = 源序**：顺延永远按 `groups` 的源顺序（`sourceIndex` 升序），UI 的「倒序」只影响渲染；倒序视图里「下一张」不是「下一集」。
- **解析必须早于绑定应用**：`resolve` 只吃**原始线路**的组。先解析 → 合并（手动覆盖 AI）→ 再写 extra → 再交给 UI 建显示组，禁止拿已写 extra 的集去算锚点（会自指）。
- **锚点让位**：某锚点顺延到下一个锚点所在组即停止，后者接管。
- **不可绑定**：无法确定季/集的目标、季集数缺失导致的越界、被丢弃的锚点，全部退回自动，不猜测。

## 4. 持久化与状态

新表（加法式迁移，不动既有表），`lib/services/storage.dart`：

```sql
CREATE TABLE IF NOT EXISTS episode_manual_bindings (
  config_id INTEGER NOT NULL DEFAULT 0,
  site_key TEXT NOT NULL,
  vod_id TEXT NOT NULL,
  source_title TEXT NOT NULL DEFAULT '',
  flag_key TEXT NOT NULL DEFAULT '',
  tmdb_id INTEGER NOT NULL DEFAULT 0,
  media_type TEXT NOT NULL DEFAULT '',
  anchors TEXT NOT NULL DEFAULT '[]',   -- [{sourceIndex,sourceName,seasonNumber,episodeNumber,spread}]
  updated_at INTEGER NOT NULL,
  UNIQUE(config_id, site_key, vod_id, source_title, flag_key)
);
```

不存全局 snapshot：锚点自带 `sourceName` 自校验，失效按 §3 `relocate` 逐条判定（与 AI 表「整批 stale」语义不同，这里逐条更稳）。

`lib/services/episode_manual_match_service.dart`：

```dart
class EpisodeManualMatchService {
  EpisodeManualMatchService({required AppDatabase database});
  List<EpisodeMatchAnchor> load({required int configId, required String siteKey,
      required String vodId, required String sourceTitle, required String flagKey});
  void save({required int configId, required String siteKey, required String vodId,
      required String sourceTitle, required String flagKey, required int tmdbId,
      required String mediaType, required List<EpisodeMatchAnchor> anchors});
  void clear({required int configId, required String siteKey, required String vodId,
      required String sourceTitle, required String flagKey});
}
```

`AppState`（沿用 AI 绑定那一套键/容量/代际写法）：

- `Map<String, List<EpisodeMatchAnchor>> _manualEpisodeAnchors`，键与 `_aiLineKey` 同口径，容量同 128、同淘汰顺序。
- `refreshManualEpisodeMatches(vod, {siteKey})`：读库 → `relocate`（丢弃的写回库并计数）→ 缓存 → notify。
- `Map<int, EpisodeMatchTarget>? episodeBindingsFor(vod, line)`：手动覆盖 AI；`hasEpisodeBindings` 取代 `hasAiMappings`（手动也走同一渲染分支与季节 chips）。
- `applyEpisodeBindingsToLine(vod, line)` 取代 `applyAiMappingsToLine`（后者保留为同义别名，避免一次性大改调用点）。
- `matchEpisodeManually({...})` / `clearManualEpisodeMatch({...})`：写库 + 刷缓存 + notify。
- 身份守卫与 AI 同处同规则：`tmdb_id`/`media_type` 变了 → 清除本线路手动行。

## 5. UI 契约

- `lib/ui/episode_match_dialog.dart`：

```dart
class EpisodeMatchChoice {
  final int seasonNumber, episodeNumber;
  final bool spread;
}
Future<EpisodeMatchChoice?> showEpisodeMatchDialog(BuildContext context, {
  required String title,                       // 剧名（弹窗标题）
  required Map<int, int> seasonEpisodeCounts,  // 季号 → 集数
  required int initialSeason, required int initialEpisode,
  required bool variety,
  required Future<List<TmdbEpisode>?> Function(int season) loadSeason, // 按需拉取并缓存
});
```

打开即定位到初始目标；按季分组列目标集（剧照缩略 + `S1E3`/「第 3 期」+ 标题 + 日期 + 当前标记）；顶部季度切换；底部「从此集起顺延」（主）/「仅此一集」（次）/ 取消。该季集列表拉不到时显示「该季集列表不可用」并可重试，**不猜集号、不阻塞其它季**。行样式与「整行可点」沿用 `MetaMatchDialog`。

- 卡片菜单：`TmdbEpisodeStrip` 新增 `onEpisodeMenu(int index, TmdbEpisodeCard card, Offset position)`；`browse_pages` 用 `showMenu` 渲染四项，长按改用同一菜单（剧集详情移入菜单），右键只对卡片生效。
- 卡面（`TmdbEpisodeCardTile`）：绑定命中 → 角标加「手动」；重复目标 → 角标追加「重复」；综艺文案走 `unitLabel`。倒序/网格/区间/名称切换不得改变这些标记。
- 区块头（`TmdbEpisodeHeader`）：新增可选 `matchSummary`（`已手动匹配 3 处 · 清除` / `2 处已失效 · 清理`），不加第 5 个图标按钮。

## 6. 边界与失效

- 读不到库/解析失败 → 视为无绑定，静默降级，不阻塞渲染与播放。
- 源线路重排：按 `sourceName` 唯一重定位；重名或找不到 → 丢弃该锚点并计入失效提示。
- 换线路：按 `flagKey` 隔离，互不影响；换站/换作品自然不同键。
- 迟到响应：写入/刷新沿用 `tmdb.generation` + `_detailRunId` 双重校验（与 `refreshAiSeasonMappings` 同款）。
- 跨季顺延会多打一次目标季剧集请求：只在确实跨季时触发，失败则该季卡片退化为源名（诚实降级）。

## 7. 非目标

不改站源协议、不新增依赖、不碰 URL/历史/续播身份、不做跨线路批量匹配、不做「按集数自动对齐」（AI 的职责）、不实现 TMDB episode group/绝对集号、不改聚合/区间/倒序/网格既有语义、不改变作品级与季度级手动匹配行为。

## 8. 影响面

- 新增：`lib/core/episode_manual_match.dart`、`lib/services/episode_manual_match_service.dart`、`lib/ui/episode_match_dialog.dart`、`test/episode_manual_match_test.dart`、`test/episode_match_dialog_test.dart`、`integration_test/episode_manual_match_flow_test.dart`
- 修改：`lib/services/storage.dart`（新表 + 读写 + 迁移）、`lib/state/app_state.dart`（读取/应用/写入/缓存/身份守卫）、`lib/ui/browse_pages.dart`（菜单、弹窗接线、区块头 summary）、`lib/ui/tmdb_detail_view.dart`（菜单回调、卡面标记、header summary）、`lib/services/ai_integration.dart`（`applyEpisodeBindings` 泛化，保留旧名别名）
- 不动：站源协议、播放器、历史、聚合核心、AI 识别服务。

## 9. 验收

- **逻辑单测**：顺延 +1；跨季（S1E10 满 → S2E1）；仅此一集；锚点让位；季集数缺失不跨季；冲突标记；重定位（重排后按名找回）；找不到则丢弃；倒序显示不影响源序顺延；聚合组内多版本同目标。
- **服务/存储**：JSON 往返、按 `flagKey` 隔离、身份变化清除、重进详情页仍生效、无库时静默降级。
- **Widget**：卡片菜单四项与「恢复自动」只在有绑定时出现；弹窗初始定位、两个按钮返回值、季列表不可用时的禁用与重试；卡面「手动」「重复」标记；综艺文案「期」。
- **集成**：真 fixture 匹配第 10 张卡为 S1E10 后，第 10/11/12 张卡依次为 S1E10/11/12；重启/重进详情页仍生效；切到另一条线路不串。
- **视觉**：Before / After 同场景、同视口、同主题截图（菜单、弹窗、卡面标记各一张）。
- **回滚**：删表迁移与新增文件即可回到原行为，不改既有表结构与既有绑定数据。

## 10. 实现与验收（2026-11-21）

### 10.1 落点

| 层 | 文件 | 说明 |
| --- | --- | --- |
| 纯逻辑 | `lib/core/episode_manual_match.dart` | 锚点/目标/铺开/重定位/冲突/综艺文案，零 IO、零 Flutter |
| 持久化 | `lib/services/storage.dart`（追加）、`lib/services/episode_manual_match_service.dart` | 新表 `episode_manual_bindings` + upsert/删除/读取；`loadScope` 供身份守卫 |
| 状态 | `lib/state/app_state.dart` | 合并绑定（手动 > AI）、读写、刷新重定位、身份变化清除、缓存淘汰 |
| 视图 | `lib/ui/episode_match_dialog.dart`、`lib/ui/tmdb_detail_view.dart`、`lib/ui/browse_pages.dart` | 匹配弹窗；卡片菜单/角标/摘要行；接线与调用 |

### 10.2 与设计稿的差异（实现层收敛，不改语义）

- 区块头摘要实现为独立组件 `TmdbEpisodeMatchSummary`（渲染在区块头与卡片条之间），未给 `TmdbEpisodeHeader` 加参数：区块头已有四个单位按钮，摘要是一整行可点内容，独立组件更好测也更好复用。
- `EpisodeManualMatchService` 增加 `loadScope()`：§4 要求"作品身份变化时清除"，需要读回行内 `tmdb_id`/`media_type`。
- `AppState` 保留 `applyAiMappingsToLine` / `hasAiMappings` 同义别名（既有渲染路径未改调用点），新代码用 `applyEpisodeBindingsToLine` / `hasEpisodeBindings`。
- `matchEpisodeManually` / `clearManualEpisodeMatch` 增加可选 `siteKey`：默认沿用 `_aiTmdbSiteKey`，显式传入便于测试与"站点还没走完 TMDB 装载"的场景。

### 10.3 验收证据

- 纯逻辑 `test/episode_manual_match_test.dart`：12 条（顺延/让位/仅此一集/跨季/季集数缺失/聚合组/冲突/重定位/丢弃/综艺判定/文案/JSON 往返）。
- 持久化 `test/episode_manual_match_service_test.dart`：11 条（往返、同键覆盖不新增行、五键隔离、清除、坏数据不抛、身份列原样）。
- 弹窗 `test/episode_match_dialog_test.dart`：10 条（初始定位、两个确认按钮、取消、不可用与重试、迟到响应、切季缓存、综艺文案）。
- 端到端 `test/episode_manual_match_page_test.dart`：4 条（长按→菜单→匹配→顺延到 S2E3..S2E9；仅此一集 + 恢复自动；落库后新 AppState 读回仍生效；**未覆盖的集保留自动刮削**，见 §10.4）。
- 回归：`episode_card_long_press_test`（长按契约改为"先出菜单"后全绿）、`episode_aggregation_ui_test`、`episode_name_mode_test`、`phase6_season_controls_test`、`phase4_tmdb_detail_view_test`、`detail_section_rhythm_test`、`ai_parity_season_ui_integration_test` 以及 13 个详情页相关测试全绿；`flutter analyze lib test` 0 issue。
- 环境说明：本机未安装 libmpv，`detail_interaction_feedback_test`、`detail_playback_resume_swap_test`、`detail_swap_resume_locator_test` 三个依赖 `media_kit` 的用例在本机失败（与本改动无关），需在有 libmpv 的机器复跑。

### 10.4 缺陷修复：未覆盖集丢刮削（用户实测 2026-11-21）

**症状**：手动匹配第 3 集并顺延后，第 1、2 集的刮削（剧照 / 集标题 / 日期）消失，卡面退回源名。

**根因**：卡片来源按**整条线路**二选一——`hasEpisodeBindings` 为真就整条线路走「绑定元数据」分支（`_aiEpisodeCard` 只读 `tmdb_season_number` / `tmdb_episode_number`）。手动匹配通常只覆盖一部分集，未被锚点覆盖的集没有这两个 extra，元数据因此为空。AI 整批映射能掩盖这个缺陷，因为它的绑定覆盖全部集。

**修复**：改为**逐集**挑来源（`_boundAwareCards`）：`episode_identity_confirmed == true` 的集用绑定元数据，其余集沿用自动刮削（`episodeCardsForEpisodes`）。详情页（`_buildEpisodes`）与播放器剧集面板（`_episodeCardsByFlag`）两处卡片映射同步改，避免面板与详情页卡片不一致。

**回归**：`test/episode_manual_match_page_test.dart` 新增「匹配第 3 集并顺延：前两集仍保留刮削元数据」——修复前红（`E1 元数据1` 找不到）、修复后绿。
