/// 首页（观测台）的数据投影：把「播放历史 + 追剧 + 推荐」折成 hero 与三条轨道。
///
/// 约束（见 `docs/phase11/design/02-home-feed-contract.md`）：
/// - **纯逻辑**：不依赖 Flutter、不发网络、不读数据库。输入的三个列表由
///   `AppState` 取好后传进来，排序与去重全在这里，因此可以用纯 Dart 单测钉死。
/// - **只做投影，不做取数**：与 `history_grouping.dart` 同一种分工。
/// - **不持有页面状态**：推荐是异步后到的，合并策略在页面层（追加不重排），
///   这里只保证「给定输入，输出是确定的」。
library;

import '../services/storage.dart';
import 'detail_recommendation.dart';
import 'episode_aggregation.dart' show EpisodeFileSize;
import 'following.dart';
import 'recommendation_meta.dart';
import 'skip_segments.dart';
import 'tmdb_identity.dart';
import 'tmdb_title.dart' show sourceEpisodeNumber, sourceSeasonNumber;

/// 一张卡 / 一张幻灯片的来源类别。
///
/// [hot] 与其余三类不同：它不来自本机数据，而来自 360kan 榜单（`searchHotRank`），
/// 因此**不参与** `buildHomeFeed` 的排序与去重——页面直接把它折成轨道，接在
/// 本机轨道后面（见 `core/home_hot.dart`）。
enum HomeItemKind { resume, following, recommend, hot }

/// 轨道的类别。推荐拆成两条（TMDB / 豆瓣），因为它们本来就是两行；
/// 热门按 360kan 的三个榜单拆成三条。
enum HomeRailKind {
  resume,
  following,
  recommendTmdb,
  recommendDouban,
  hotMovie,
  hotTv,
  hotVariety,
}

/// 轨道标题右侧「查看全部」的去向；推荐没有独立页，所以没有对应值。
enum HomeSeeAll { history, following }

/// 一部作品的展示条目。**hero 与轨道共用同一类型**：
/// 少一次转换，也就少一处「hero 与卡片对同一部剧说法不一致」的机会。
class HomeItem {
  const HomeItem({
    required this.kind,
    required this.key,
    required this.title,
    this.poster,
    this.backdrop,
    this.subtitle = '',
    this.overview = '',
    this.tags = const [],
    this.reason = '',
    this.progress = 0,
    this.episodeLabel = '',
    this.history,
    this.following,
    this.entry,
  });

  final HomeItemKind kind;

  /// 去重键。同一部作品在不同来源下必须得到同一个 key：
  /// 续播 → `sourceKey|siteKey|vodId`；追剧 → [Following.identityKey]；
  /// 推荐 → [RecommendationEntry.key]。
  final String key;

  final String title;

  /// 2:3 竖版海报。
  final String? poster;

  /// 16:9 背景图（可空：空则用海报兜底，见页面层的素材降级链）。
  final String? backdrop;

  /// 「年份 · 评分」，口径见 `recommendation_meta.dart`。
  final String subtitle;

  /// 剧情简介（TMDB `overview`，随取图那次 `detail()` 一起回来）。
  ///
  /// 只有**绑定了 TMDB 身份**的条目才有；空串表示没有，页面就不画这一行。
  final String overview;

  /// 类型标签（TMDB `genres`，最多 3 个）。空列表表示没有，页面不画标签行。
  final List<String> tags;

  /// 理由行：「继续观看 · 第08集 · 剩 12 分钟」/「更新至 第12集」/「因为你看过《…》」。
  final String reason;

  /// 0..1；非续播恒为 0。
  final double progress;

  /// 集标签（「第08集」/「更新至 第12集」）。空串表示这类条目没有集概念。
  final String episodeLabel;

  /// 续播类条目的原始历史行：点「继续播放」时整条交给 `resumeHistoryEntry`。
  final PlaybackHistory? history;

  /// 追剧类条目的原始追番记录。
  final Following? following;

  /// 推荐类条目的原始推荐结果。
  final RecommendationEntry? entry;

  /// 换掉图片地址与**刮削名**（元数据优先级解析出来的结果覆盖站点字段，见
  /// `services/home_art_service.dart`）。标题也允许换：详情页头部显示的就是刮削名，
  /// 首页不换会变成「同一部剧两个名字」。其余字段是身份与文案，换图不该顺手改掉它们。
  HomeItem copyWith({
    String? title,
    String? poster,
    String? backdrop,
    String? overview,
    String? subtitle,
    List<String>? tags,
    bool hidePoster = false,
    bool hideBackdrop = false,
  }) => HomeItem(
    kind: kind,
    key: key,
    title: title ?? this.title,
    poster: hidePoster ? null : poster ?? this.poster,
    backdrop: hideBackdrop ? null : backdrop ?? this.backdrop,
    subtitle: subtitle ?? this.subtitle,
    overview: overview ?? this.overview,
    tags: tags ?? this.tags,
    reason: reason,
    progress: progress,
    episodeLabel: episodeLabel,
    history: history,
    following: following,
    entry: entry,
  );
}

class HomeRail {
  const HomeRail({
    required this.kind,
    required this.title,
    this.items = const [],
    this.seeAll,
  });

  final HomeRailKind kind;
  final String title;
  final List<HomeItem> items;

  /// `null` = 不显示「查看全部」（推荐行就是这样）。
  final HomeSeeAll? seeAll;
}

class HomeFeed {
  const HomeFeed({this.hero = const [], this.rails = const []});

  /// 三者全空时的唯一实例：页面据此决定画空态。
  static const HomeFeed empty = HomeFeed();

  /// hero 幻灯片，0..6 张（见设计文档 §2.1）。
  final List<HomeItem> hero;

  /// 轨道，按展示顺序排列；空轨道不出现。
  final List<HomeRail> rails;

  bool get isEmpty => hero.isEmpty && rails.isEmpty;
}

/// 首屏 hero 的高度（`docs/phase11/design/01-home-hero.md` §3.1）。
///
/// **只有一档**：占满内容区（夹 360–1000）。
///
/// 旧版按「本轮有没有 16:9 背景图」分两档，没图就收到 62%。用户 2026-11-25 反馈
/// 「首页风格不统一，有的像右下角一张图」——高度随素材变化，没有背景图的那几张
/// 就成了半屏海报 + 半屏空。素材不足只该影响「画面里有什么」，不该影响「这一屏
/// 占多高」；缩图由 hero 自己的版式负责，不是把整条滑块压矮。
///
/// 上限 1000 保留：4K/超宽屏下让第一条轨道的标题露一条边，整屏纯图没有任何
/// 「往下还有内容」的线索。
double homeHeroHeight(double contentHeight) =>
    contentHeight.clamp(360.0, 1000.0);

/// 把三类输入折成首页要画的东西。
///
/// 排序、去重与降级规则**全部**写在 `docs/phase11/design/02-home-feed-contract.md`
/// §1–§2，实现必须逐条对应用例；不要在页面层再排一次序。
HomeFeed buildHomeFeed({
  required List<PlaybackHistory> history,
  required List<Following> followings,
  List<RecommendationEntry> tmdbRecommendations = const [],
  List<RecommendationEntry> doubanRecommendations = const [],
  /// 直播源名（`LiveSource.name`，与历史行的 `siteKey` 同一命名空间）。
  ///
  /// 直播没有可续播的时间轴：它的「继续观看 · 原画1080P30 · 剩 1 分钟」是一句
  /// 谎话（用户 2026-11-25 图一）。写入侧已改成不落历史，但旧库里已经有这类行，
  /// 所以投影层再判一次——首页读到的是跨源全量历史，不能指望库里干净。
  Set<String> liveSiteKeys = const <String>{},
}) {
  // 认领顺序就是 I4 的优先级：following 带「有新集」信息最值钱，resume 次之，
  // 推荐最便宜。先到的类别留下，后到的整条让位——比「先全排好再逐条比较谁优先」
  // 少一处「同一部作品被判断两次」的机会。
  final claimed = _Claimed();
  final followingRail = _claim(_followingItems(followings), claimed);
  final resumeRail = _claim(_resumeItems(history, liveSiteKeys), claimed);
  final tmdbRail = _claim(
    _recommendationItems(tmdbRecommendations),
    claimed,
    max: tmdbRecommendations.length,
  );
  final doubanRail = _claim(
    _recommendationItems(doubanRecommendations),
    claimed,
    max: doubanRecommendations.length,
  );

  return HomeFeed(
    hero: _hero(
      following: followingRail,
      resume: resumeRail,
      tmdb: tmdbRail,
      douban: doubanRail,
    ),
    rails: [
      if (resumeRail.isNotEmpty)
        HomeRail(
          kind: HomeRailKind.resume,
          title: '继续观看',
          items: resumeRail,
          seeAll: HomeSeeAll.history,
        ),
      if (followingRail.isNotEmpty)
        HomeRail(
          kind: HomeRailKind.following,
          title: '追剧更新',
          items: followingRail,
          seeAll: HomeSeeAll.following,
        ),
      // 推荐行没有 seeAll：推荐没有独立页，点了无处可去就不放这个入口（01 §4）。
      if (tmdbRail.isNotEmpty)
        HomeRail(
          kind: HomeRailKind.recommendTmdb,
          title: '个性推荐 · TMDB',
          items: tmdbRail,
        ),
      if (doubanRail.isNotEmpty)
        HomeRail(
          kind: HomeRailKind.recommendDouban,
          title: '个性推荐 · 豆瓣',
          items: doubanRail,
        ),
    ],
  );
}

/// hero 的容量与分配（02 §2.1）：总数 12，追剧 ≤3、续播 ≤6、推荐 ≤3。
///
/// 用户 2026-11-19：总数放大到 12。「每类多少」按原来的 1:2:1 等比放大，
/// 追剧位不跟着涨太多——「有更新」本来就受更新节奏限制，凑不满也不该硬凑。
const int _heroMax = 12;
const int _heroFollowingMax = 3;
const int _heroResumeMax = 6;
const int _heroRecommendMax = 3;

/// 单条轨道的容量（02 §1 I1）。
const int _railMax = 20;

/// 剩余分钟的上限：超过就不写分钟（02 §2.3）。
///
/// 源站偶尔给出明显错误的 duration（几十小时），照着算会写出「剩 100000 分钟」，
/// 那比不写更像故障。
const int _minuteCap = 999;

/// 续播的进度上界（02 §1 I3）。恰好等于它算「看完」，不进。
const double _resumeCeiling = 0.95;

/// 跨轨道的独占标记（02 §1 I1 + I4）。
///
/// 两个集合分开记：titles 管「同一部作品只出现一次」；keys 管「同一个 key
/// 不重复」——源站改名后的两行会得到不同标题却同一个 key，只按标题去重挡不住。
class _Claimed {
  final HomeWorkClaimer claimer = HomeWorkClaimer();
}

/// 「同一部作品只出现一次」的判据，hero 与轨道共用一份（与 [buildHomeFeed] 的
/// 认领同源）。
///
/// 两个键各管一件事：归一化片名（[homeWorkKey]）管「站名不同、其实是同一部剧」；
/// TMDB 身份管「站名完全不同、片名也没法比」。页面层在取回 TMDB 图、标题被换成
/// 刮削名之后还要用**这一个**判据再过一遍——两处各写一份，图到得早晚就会决定
/// 去重是否生效。
class HomeWorkClaimer {
  final Set<String> _keys = <String>{};
  final Set<String> _identities = <String>{};

  /// 归一化片名 → 认领过它的 TMDB 身份（空集合 = 只被「没有身份」的行认领过）。
  final Map<String, Set<String>> _works = <String, Set<String>>{};

  /// 第一次见到这部作品返回 true（并认领）；重复返回 false。
  bool claim(HomeItem item) {
    if (_keys.contains(item.key)) return false;
    final work = _workKey(item);
    final identity = _identityOf(item);
    if (identity != null && _identities.contains(identity)) {
      // 同一身份的另一个站名：把它登记成这部作品的别名，否则「A 有身份、B 同身份、
      // C 只有同名」会留下 A 和 C（A 的标题与 C 的标题不同，单靠片名收不掉 C）。
      _works.putIfAbsent(work, () => <String>{}).add(identity);
      return false;
    }
    final claimed = _works[work];
    if (claimed != null) {
      // 同一片名下已经有**另一个** TMDB 身份 —— 那是两部不同的作品（《三体》动画版
      // 与电视剧版）。标题归一化替用户判不了这个，宁可都留着。
      if (identity != null &&
          claimed.isNotEmpty &&
          !claimed.contains(identity)) {
        _keys.add(item.key);
        _identities.add(identity);
        return true;
      }
      if (identity != null) claimed.add(identity);
      return false;
    }
    _works[work] = <String>{?identity};
    _keys.add(item.key);
    if (identity != null) _identities.add(identity);
    return true;
  }
}

/// 按「作品」去重：保留第一次出现的条目。页面层取回元数据后用它把 hero 与轨道
/// 收一遍（见 [HomeWorkClaimer]）。
List<HomeItem> unifyHomeItems(Iterable<HomeItem> items) {
  final claimer = HomeWorkClaimer();
  return [for (final item in items) if (claimer.claim(item)) item];
}

/// 按 I4 的优先级认领条目，同时把这一刻的轨道容量（20）用完为止。
///
/// 先截断再认领会让「被截掉的第 21 条」白占一个标题；这里先判再收，
/// 没进轨道的条目不影响后面类别能不能用这个标题。
List<HomeItem> _claim(
  List<HomeItem> pool,
  _Claimed claimed, {
  int max = _railMax,
}) {
  final taken = <HomeItem>[];
  for (final item in pool) {
    if (taken.length >= max) break;
    if (!claimed.claimer.claim(item)) continue;
    taken.add(item);
  }
  return taken;
}

/// 同一部作品的比较键（02 §1 I4）：片名归一。
///
/// 归一后为空（标题全是标点、或干脆没有名字）时退回条目自己的 key，
/// 否则所有「没名字」的条目会互相吞掉，只剩一条。
String _workKey(HomeItem item) {
  final title = homeWorkKey(item.title);
  return title.isEmpty ? item.key : title;
}

/// 首页判断「这是同一部作品吗」的归一化片名。
///
/// 站点片名混着发行方噪声：网盘站写作
/// `《那一夜，我怀了社长的孩子》百度云网盘夸克下载.阿里云盘.中字.(2026)`，
/// 另一个站点只写 `那一夜我怀了社长的孩子`。直接比整串标题会把同一部剧当成两部
/// ——用户 2026-11-25 反馈「同一部剧首页两条」。规则只有一条：**有书名号就取
/// 书名号里的名字**（资源站/网盘的命名惯例），再按 [recommendationTitleKey]
/// 去标点、空白与大小写差异。
///
/// 公开而不是私有：页面层取回 TMDB 图后会把标题换成刮削名（`_withArt`），
/// 那时要按**同一个键**再收一次重复，两处各写一份就会漏。
String homeWorkKey(String title) {
  final text = title.trim();
  final bracketed = RegExp(r'《([^》]+)》').firstMatch(text);
  final name = bracketed == null ? text : bracketed.group(1)!;
  return recommendationTitleKey(name);
}

/// 条目的 TMDB 身份键；没有身份时返回 null（续播看历史行，推荐看 TMDB 条目）。
String? _identityOf(HomeItem item) {
  final history = item.history;
  if (history != null && history.hasTmdbIdentity) {
    return '${history.mediaType}:${history.tmdbId}';
  }
  return item.entry?.item.identity?.key;
}

/// 续播候选：过滤 + 按最近播放降序（02 §2.1-2）。
///
/// 「同标题留哪一条」与「轨道截到几条」都交给 [_claim] 统一处理，
/// 不在这里写成第二份规则——hero 与轨道对同一件事只会有一个答案。
List<HomeItem> _resumeItems(
  List<PlaybackHistory> history,
  Set<String> liveSiteKeys,
) {
  final rows = history
      .where((row) => !liveSiteKeys.contains(row.siteKey))
      .where(_isResumable)
      .toList()
    ..sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      // updatedAt 撞车时用行 id 兜底：List.sort 不稳定，同一批输入必须得到
      // 同一个顺序，否则「同一部剧有时在前有时在后」永远查不出来。
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
  return [for (final row in rows) _resumeItem(row)];
}

/// 0 < progress < 0.95 才算看到一半（02 §1 I3）。
///
/// durationMs <= 0 单独判否，而不是指望 progress 恰为 0：线上确实有只写了
/// position、duration 还没落库的行，让它进续播等于画一条 0% 的进度线。
bool _isResumable(PlaybackHistory row) {
  if (row.durationMs <= 0) return false;
  final ratio = row.positionMs / row.durationMs;
  return ratio > 0 && ratio < _resumeCeiling;
}

HomeItem _resumeItem(PlaybackHistory row) => HomeItem(
  kind: HomeItemKind.resume,
  key: homeHistoryKey(row),
  title: row.vodName.trim(),
  poster: _imageOrNull(row.vodPic),
  // 历史只有年份没有评分，但仍走同一个「年份 · 评分」口径，免得首页几条轨道
  // 出现两种副信息写法（recommendation_meta.dart）。
  subtitle: recommendationMeta(row.vodYear.trim()),
  reason: _resumeReason(row),
  progress: _progressOf(row),
  episodeLabel: row.episodeName.trim(),
  history: row,
);

/// 续播条目的 key：跨源唯一（02 §1 表）。空 sourceKey 是迁移前的行，
/// 仍按同一格式拼，不特殊处理。
///
/// 公开而不是私有：页面层要用**同一个 key** 把「按 TMDB 身份取回来的图」贴回条目
/// （`services/home_art_service.dart`）。这个格式一旦两处各写一份，图就会悄悄贴不上。
String homeHistoryKey(PlaybackHistory row) =>
    [row.sourceKey, row.siteKey, row.vodId].join('|');

/// 追剧候选：按 §2.2 排好，容量与去重交给 [_claim]。
List<HomeItem> _followingItems(List<Following> followings) {
  final rows = followings.toList()..sort(_compareFollowing);
  return [for (final row in rows) _followingItem(row)];
}

/// 「有更新」= 已发布集数超过已看集数（02 §2.1-1 的字面口径）。
///
/// 不用 readWatermarkEpisode：那是通知去重的水位，不代表看过。
bool _hasUpdate(Following row) =>
    row.latestReleasedEpisode > row.watchedEpisode;

/// 追剧轨道的顺序（02 §2.2）：有更新的先聚成一组，组内按下一集播出时间升序，
/// 未知（0）排最后，再按追番时间降序。
///
/// 0 排最后而不是最前：它表示**不知道**什么时候播，不是「马上播」。
int _compareFollowing(Following a, Following b) {
  final aUpdate = _hasUpdate(a) ? 0 : 1;
  final bUpdate = _hasUpdate(b) ? 0 : 1;
  if (aUpdate != bUpdate) return aUpdate.compareTo(bUpdate);
  if (a.nextAirAtMs != b.nextAirAtMs) {
    if (a.nextAirAtMs == 0) return 1;
    if (b.nextAirAtMs == 0) return -1;
    return a.nextAirAtMs.compareTo(b.nextAirAtMs);
  }
  final byCreated = b.createdAtMs.compareTo(a.createdAtMs);
  // 最后按身份键兜底，理由同 [_resumeItems]：不稳定排序会让相邻两张偶尔换位。
  return byCreated != 0 ? byCreated : a.identityKey.compareTo(b.identityKey);
}

HomeItem _followingItem(Following row) {
  final episodeLine = _followingEpisodeLine(row);
  return HomeItem(
    kind: HomeItemKind.following,
    key: row.identityKey,
    title: row.vodName.trim(),
    poster: _imageOrNull(row.vodPic),
    // 02 §2.3 的后半句（「· {平台} {播出时间}」）要等 FollowingAirData 到位，
    // 那是页面层的异步补充；这里只给本地就一定知道的前半句。
    reason: episodeLine,
    episodeLabel: episodeLine,
    following: row,
  );
}

/// 「更新至 第12集」：优先站点给的最新集名，缺了退回集数，都没有就留空
/// （空理由行不显示，不编一句话）。
String _followingEpisodeLine(Following row) {
  final name = row.latestEpisodeName.trim();
  if (name.isNotEmpty) return '更新至 $name';
  final episode = row.latestReleasedEpisode;
  if (episode > 0) return '更新至 第$episode集';
  return '';
}

/// 推荐候选：**保持服务返回顺序**（02 §2.2）。
///
/// 再按评分或年份排一次等于替推荐服务重排，它的顺序本身就是它想说的东西。
List<HomeItem> _recommendationItems(List<RecommendationEntry> entries) {
  final items = <HomeItem>[];
  for (final entry in entries) {
    final item = _recommendationItem(entry);
    if (item != null) items.add(item);
  }
  return items;
}

HomeItem? _recommendationItem(RecommendationEntry entry) {
  final title = entry.item.title.trim();
  // 没有标题的推荐连卡片都画不出来；跳过比画一张空白卡诚实（I6：跳过，不抛）。
  if (title.isEmpty) return null;
  final meta = recommendationMeta(
    entry.item.subtitle,
    doubanRating: entry.doubanRating,
  );
  return HomeItem(
    kind: HomeItemKind.recommend,
    key: entry.key,
    title: title,
    poster: _imageOrNull(entry.item.posterUrl),
    backdrop: _imageOrNull(entry.item.backdropUrl),
    subtitle: meta,
    // 简介：TMDB 的推荐/相似列表里本来就带 `overview`，直接用——不额外请求。
    overview: (entry.item.overview ?? '').trim(),
    // 理由行三档（02 §2.3）：推荐语 → 年份 · 评分 → 空串（不显示）。
    reason: entry.reason.trim().isNotEmpty ? entry.reason.trim() : meta,
    entry: entry,
  );
}

typedef HomeAiredEpisode = ({int season, int episode});

/// 轮播的待检池：保留原首批顺序，再用轨道与热门中的后续作品补位。
/// 这里只投影候选，图片是否真实高清可用由展示层解码判定；不改轨道。
List<HomeItem> homeHeroCandidates(
  HomeFeed feed, {
  Iterable<HomeItem> hot = const [],
  Iterable<PlaybackHistory> history = const [],
  Iterable<Following> followings = const [],
  HomeAiredEpisode? Function(TmdbIdentity)? lastAiredEpisodeFor,
  SkipSegments Function(PlaybackHistory)? skipSegmentsFor,
}) {
  final latestEpisodes = <PlaybackHistory>[];
  final finishedMovies = <PlaybackHistory>[];
  for (final row in history) {
    if (_isLatestAiredEpisode(row, followings, lastAiredEpisodeFor)) {
      latestEpisodes.add(row);
    } else if ((row.mediaType == 'movie' ||
            (row.mediaType.isEmpty && _heroEpisodeNumber(row.episodeName) <= 0)) &&
        _isNearContentEnd(row, skipSegmentsFor)) {
      finishedMovies.add(row);
    }
  }

  bool isExcluded(HomeItem item) =>
      latestEpisodes.any((row) => _matchesHeroHistory(item, row)) ||
      finishedMovies.any((row) {
        final isMovie = row.mediaType == 'movie' ||
            item.entry?.item.mediaType == TmdbMediaType.movie;
        return item.following == null && isMovie && _matchesHeroHistory(item, row);
      });

  final claimer = HomeWorkClaimer();
  return [
    for (final item in [
      ...feed.hero,
      for (final rail in feed.rails) ...rail.items,
      ...hot,
    ])
      if (!isExcluded(item) && claimer.claim(item)) item,
  ].take(120).toList();
}

bool _isNearContentEnd(
  PlaybackHistory row,
  SkipSegments Function(PlaybackHistory)? skipSegmentsFor,
) {
  if (row.completed) return true;
  if (row.durationMs <= 0 || row.positionMs <= 0) return false;
  final end = skipSegmentsFor?.call(row)
      .normalizedFor(row.durationMs).outroStartMs ?? row.durationMs;
  final tolerance = end < 120000 ? end ~/ 2 : 60000;
  return row.positionMs >= end - tolerance;
}

final _numberedVideoFile = RegExp(
  r'^(\d{1,3})(?:\s+(?:4k|8k|2160p|1080p|720p))?\.(?:mkv|mp4|avi|ts|m2ts|mov|wmv|flv|webm|m4v)$',
  caseSensitive: false,
);

int _heroEpisodeNumber(String name) {
  final label = EpisodeFileSize.strip(name).trim();
  final fromLabel = sourceEpisodeNumber(label);
  if (fromLabel > 0) return fromLabel;
  final fileNumber = _numberedVideoFile.firstMatch(label)?.group(1);
  return fileNumber == null ? -1 : int.parse(fileNumber);
}

bool _isLatestAiredEpisode(
  PlaybackHistory row,
  Iterable<Following> followings,
  HomeAiredEpisode? Function(TmdbIdentity)? lastAiredEpisodeFor,
) {
  if (row.mediaType == 'movie') return false;
  final episode = _heroEpisodeNumber(row.episodeName);
  final episodeSeason = sourceSeasonNumber(row.episodeName);
  final season = episodeSeason > 0 ? episodeSeason : sourceSeasonNumber(row.vodName);
  final identity = TmdbIdentity.from(row.mediaType, row.tmdbId);
  final aired = identity == null ? null : lastAiredEpisodeFor?.call(identity);
  final sameAiredSeason = aired != null &&
      (season == aired.season || (season <= 0 && aired.season == 1));
  if (aired != null &&
      ((season > 0 && season < aired.season) ||
          (sameAiredSeason && episode > 0 && episode < aired.episode))) {
    return false;
  }

  var matchesFollowing = false;
  for (final following in followings) {
    if (following.siteKey != row.siteKey || following.vodId != row.vodId ||
        following.latestReleasedEpisode <= 0) {
      continue;
    }
    final latestSeason = following.latestReleasedSeason > 0
        ? following.latestReleasedSeason
        : sourceSeasonNumber(following.latestEpisodeName);
    if (latestSeason > 0 && season > 0 && season < latestSeason) return false;
    final exactEpisode = row.episodeId.isNotEmpty &&
        row.episodeId == following.latestEpisodeTarget;
    if (!exactEpisode &&
        ((latestSeason > 1 && season != latestSeason) ||
            (latestSeason <= 0 && season > 0))) {
      continue;
    }
    if (!exactEpisode && episode > 0 && episode < following.latestReleasedEpisode) {
      return false;
    }
    matchesFollowing |= exactEpisode || episode == following.latestReleasedEpisode;
  }
  return matchesFollowing || (sameAiredSeason && episode == aired.episode);
}

bool _matchesHeroHistory(HomeItem item, PlaybackHistory row) {
  if (item.following case final following?) {
    return following.siteKey == row.siteKey && following.vodId == row.vodId;
  }
  final current = item.history;
  final candidateType = item.entry?.item.mediaType ??
      TmdbMediaType.parse(current?.mediaType);
  final historyType = TmdbMediaType.parse(row.mediaType);
  if (candidateType != null && historyType != null &&
      candidateType != historyType) {
    return false;
  }
  final identity = _identityOf(item);
  if (identity != null && row.hasTmdbIdentity) {
    return identity == '${row.mediaType}:${row.tmdbId}';
  }
  if (current != null && homeHistoryKey(current) == homeHistoryKey(row)) {
    return true;
  }
  final title = homeWorkKey(item.title);
  final year = item.entry?.item.year ?? int.tryParse(current?.vodYear.trim() ?? '') ?? 0;
  final historyYear = int.tryParse(row.vodYear.trim()) ?? 0;
  if (year > 0 && historyYear > 0 && year != historyYear) return false;
  return title.isNotEmpty && title == homeWorkKey(row.vodName);
}

/// hero 取哪几张（02 §2.1）。
///
/// 三段都直接取自三条已去重的轨道：hero 与轨道对同一部剧说同一句话，
/// 不会出现「hero 说更新到第 12 集、卡片说第 10 集」。
List<HomeItem> _hero({
  required List<HomeItem> following,
  required List<HomeItem> resume,
  required List<HomeItem> tmdb,
  required List<HomeItem> douban,
}) {
  // 追剧位只收真有新集的：没有更新的追剧放进 hero，等于让用户点一张
  // 什么也不会发生的海报（02 §2.1-1）。组内按更新时刻降序＝最近更新的先上。
  final followingSlot =
      following.where((item) => _hasUpdate(item.following!)).toList()..sort(
        (a, b) => b.following!.updatedAtMs.compareTo(a.following!.updatedAtMs),
      );
  final followingPicked = followingSlot.take(_heroFollowingMax).toList();
  final resumePicked = resume.take(_heroResumeMax).toList();
  final recommendSource = _alternating(tmdb, douban);
  final recommendPicked = recommendSource.take(_heroRecommendMax).toList();

  // 三类的预算之和**正好等于** `_heroMax`（3 + 6 + 3 = 12），所以不需要
  // 「先排满再按优先级裁员」那一步，也不需要「推荐被挤掉时拿续播换回来」：
  // 推荐位结构上就有 3 个，永远不会整段消失（I2 从「要照顾」变成「不可能违反」）。
  //
  // `.take(_heroMax)` 是兜底：以后有人调大某一类的预算却忘了总数，这里会截住。
  return [
    ...followingPicked,
    ...resumePicked,
    ...recommendPicked,
  ].take(_heroMax).toList();
}

/// TMDB 与豆瓣**交替**（02 §2.1-3）：先 TMDB 再豆瓣，一路轮下去。
///
/// 某一行先空就自然退化成一行的顺序，不需要单独分支。
List<HomeItem> _alternating(List<HomeItem> tmdb, List<HomeItem> douban) {
  final picked = <HomeItem>[];
  for (var i = 0; i < tmdb.length || i < douban.length; i++) {
    if (i < tmdb.length) picked.add(tmdb[i]);
    if (i < douban.length) picked.add(douban[i]);
  }
  return picked;
}

/// 续播的理由行（02 §2.3）：继续观看 · {集名} · 剩 {M} 分钟，两段都能降级。
String _resumeReason(PlaybackHistory row) {
  const head = '继续观看';
  // durationMs 为 0 时连进度都没有：写「剩 X 分钟」就是编数据。
  // 这条分支在 buildHomeFeed 里不可达（I3 已先把它挡在门外），留着是因为
  // 理由行是独立契约：别处复用同一份文案时不该突然算错。
  if (row.durationMs <= 0) return head;
  final episode = row.episodeName.trim();
  final remaining = _remainingText(row);
  final parts = <String>[head];
  if (episode.isNotEmpty) parts.add(episode);
  if (remaining != null) parts.add(remaining);
  return parts.join(' · ');
}

/// M = ((1 - progress) * durationMs / 60000).ceil()（02 §2.3）。
///
/// 返回 null 表示「不写分钟」：M > 999 时数据明显不可信，宁可不写。
String? _remainingText(PlaybackHistory row) {
  final minutes = ((1 - _progressOf(row)) * row.durationMs / 60000).ceil();
  if (minutes > _minuteCap) return null;
  if (minutes < 1) return '剩 不到 1 分钟';
  return '剩 $minutes 分钟';
}

/// 0..1 的进度；durationMs <= 0 时为 0（与 PlaybackHistory.progress 同口径，
/// 但不直接用它：services 层改口径时首页不该悄悄跟着变）。
double _progressOf(PlaybackHistory row) {
  if (row.durationMs <= 0) return 0;
  return (row.positionMs / row.durationMs).clamp(0.0, 1.0);
}

/// 图片地址的空值归一：空串按「没有图」处理，让页面层的兜底链能生效。
String? _imageOrNull(String? url) {
  final trimmed = url?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
