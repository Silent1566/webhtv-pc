/// 首页图片解析：按**元数据优先级**给首页条目取图
/// （TMDB 已知身份优先，站点海报兜底）。
///
/// 只对**已知 TMDB 身份**的条目取图：取不到 / 失败 / 超时的键不出现返回结果里，
/// 调用方据此保留站点海报。TMDB 未配置、无图、网络异常都不能让首页整块无图，
/// 所以这里对外**不抛异常**。
///
/// 关键契约：
/// - 同一身份只请求一次：多个首页条目（不同站源、不同 vodId）可能指向同一部作品；
/// - 每个身份走 `TmdbService.detail`，它自带磁盘缓存，命中缓存时**零网络请求**；
/// - 任一条失败只丢这一条，整体超时返回已经拿到的部分；
/// - 空输入直接返回 `const {}`，连并发池都不建。
library;

import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import 'tmdb_service.dart';

/// 一个条目能从**同一次** `detail()` 里拿到的展示元数据。
///
/// 为什么一次拿全：详情响应里本来就带着 `overview` / `genres` / `vote_average` /
/// `release_date`，只取图片等于白扔这份数据；而**再为标签发一次请求**是不可接受的
/// 代价（首页一屏十几条）。这与详情页「一次 detail 画满一屏」是同一套口径。
///
/// 字段全部可空/可空串：拿不到就不显示，不做占位。
class HomeMeta {
  const HomeMeta({
    this.poster,
    this.backdrop,
    this.overview,
    this.genres = const [],
    this.year = '',
    this.rating = 0,
  });

  final String? poster;
  final String? backdrop;
  final String? overview;

  /// 类型标签（`genres[].name`，最多 3 个）——详情页同一份数据。
  final List<String> genres;

  /// 年份（`release_date` / `first_air_date` 的前 4 位）。
  final String year;

  /// TMDB 评分（`vote_average`）；0 表示没有。
  final double rating;
}

/// 详情加载器：注入后测试不必联网，也不必构造真实 TMDB 配置。
typedef HomeArtLoader = Future<Map<String, Object?>> Function(
  TmdbIdentity identity,
);

/// 首页取图服务。
class HomeMetaService {
  HomeMetaService({required TmdbService tmdb, HomeArtLoader? loader})
    : _tmdb = tmdb,
      _load =
          loader ??
          // 首页只要图，相关推荐那一坨不追加：同一个缓存键下少掉一大段响应体。
          ((identity) => tmdb.detail(_itemOf(identity), includeRelated: false));

  final TmdbService _tmdb;
  final HomeArtLoader _load;

  /// 只对**已知 TMDB 身份**的条目取图；返回 key → [HomeMeta]。
  ///
  /// 取不到 / 失败 / 超时的键**不出现**在结果里（调用方据此保留站点海报）。
  Future<Map<String, HomeMeta>> resolve(
    Map<String, TmdbIdentity> byKey, {
    int concurrency = 2,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (byKey.isEmpty) return const <String, HomeMeta>{};

    // 先按身份折叠：同一身份被多个 key 引用时只留一条待办。
    final keysByIdentity = <TmdbIdentity, List<String>>{};
    for (final entry in byKey.entries) {
      keysByIdentity.putIfAbsent(entry.value, () => <String>[]).add(entry.key);
    }

    final identities = keysByIdentity.keys.toList();
    final artByIdentity = <TmdbIdentity, HomeMeta>{};

    // 固定数量的 worker 依次取待办：在途请求数天然不超过 concurrency，
    // 不需要额外的信号量。
    final slots = concurrency < 1 ? 1 : concurrency;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final index = next;
        if (index >= identities.length) return;
        next = index + 1;
        final identity = identities[index];
        try {
          final art = _artOf(await _load(identity));
          if (art != null) artByIdentity[identity] = art;
        } catch (_) {
          // 单条失败（未配置、401、解析异常）只丢这一条：其余条目照常贴图。
        }
      }
    }

    final workers = List<Future<void>>.generate(
      slots < identities.length ? slots : identities.length,
      (_) => worker(),
    );
    // 超时不抛异常：慢的条目按「取不到」处理，已经拿到的图仍然有效。
    await Future.wait(workers)
        .timeout(timeout, onTimeout: () => const <void>[]);

    // 同步快照：超时后仍在飞的 worker 不能再往返回值里塞图。
    final result = <String, HomeMeta>{};
    for (final entry in keysByIdentity.entries) {
      final art = artByIdentity[entry.key];
      if (art == null) continue;
      for (final key in entry.value) {
        result[key] = art;
      }
    }
    return result;
  }

  /// 拼地址口径与 `TmdbDetailData.fromDetail` 一致：背景走 `backdropBase`、
  /// 海报走 `imageBase`，各自取排序后的第一张。
  ///
  /// 不做「无背景时拿海报顶」的回退：竖版海报拉成背景会糊，而且这里返回
  /// `null` 正好让调用方保留站点自己的背景图。
  HomeMeta? _artOf(Map<String, Object?> detail) {
    final config = _tmdb.config;
    final overview = (detail['overview'] is String)
        ? (detail['overview']! as String).trim()
        : '';
    final backdrops = TmdbImageSelector.backdrops(
      detail,
      config.backdropBase,
      limit: 1,
    );
    final posters = TmdbImageSelector.posters(
      detail,
      config.imageBase,
      limit: 1,
    );
    final genres = _genresOf(detail);
    final year = _yearOf(detail);
    final rating = _ratingOf(detail);
    // 一样都拿不到才返回 null（调用方据此保留站点海报与站点文案）。
    if (backdrops.isEmpty &&
        posters.isEmpty &&
        overview.isEmpty &&
        genres.isEmpty &&
        year.isEmpty &&
        rating <= 0) {
      return null;
    }
    return HomeMeta(
      poster: posters.isEmpty ? null : posters.first,
      backdrop: backdrops.isEmpty ? null : backdrops.first,
      overview: overview.isEmpty ? null : overview,
      genres: genres,
      year: year,
      rating: rating,
    );
  }
}

/// 类型标签：`genres` 是 `[{id, name}]`，只取名字，最多 3 个。
List<String> _genresOf(Map<String, Object?> detail) {
  final raw = detail['genres'];
  if (raw is! List) return const [];
  final names = <String>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final name = entry['name'];
    if (name is! String) continue;
    final trimmed = name.trim();
    if (trimmed.isEmpty) continue;
    names.add(trimmed);
    if (names.length >= 3) break;
  }
  return names;
}

/// 年份：电影 `release_date`、剧集 `first_air_date`，都取前 4 位。
String _yearOf(Map<String, Object?> detail) {
  for (final key in const ['release_date', 'first_air_date']) {
    final value = detail[key];
    if (value is! String || value.length < 4) continue;
    final year = value.substring(0, 4);
    if (int.tryParse(year) != null) return year;
  }
  return '';
}

double _ratingOf(Map<String, Object?> detail) {
  final value = detail['vote_average'];
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

/// `TmdbService.detail` 只读 `item.identity`，标题与副标题不参与请求。
TmdbItem _itemOf(TmdbIdentity identity) =>
    TmdbItem(tmdbId: identity.tmdbId, mediaType: identity.mediaType, title: '');
