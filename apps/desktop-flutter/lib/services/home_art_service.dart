/// 首页元数据解析：按**逐字段优先级**给首页条目补齐海报、背景、简介、类型与年份。
///
/// 两条入口共用同一份 [HomeMeta]：
/// - [HomeMetaService.resolve]：续播/推荐这类**已经带 TMDB 身份**的条目，走一次 `detail`；
/// - [HomeMetaService.resolveFollowings]：追剧记录没有身份，复用已落盘的匹配，再交给
///   `ExternalMetaService.resolveFields` → `SourceMetaResolver`，与详情页同一套字段规则。
///
/// 取不到 / 失败 / 超时的字段保持空值，调用方据此保留站点图；只有用户停用了该字段
/// 全部来源时才清掉站点兜底。TMDB 未配置、无图、网络异常
/// 都不能让首页整块无图，所以这里对外**不抛异常**。
///
/// 关键契约：
/// - 同一身份只请求一次：多个首页条目（不同站源、不同 vodId）可能指向同一部作品；
/// - 每个身份走 `TmdbService.detail`，它自带磁盘缓存，命中缓存时**零网络请求**；
/// - 站源详情只在它的优先级可能胜出、或更高来源确实缺字段时才读；
/// - 任一条失败只丢这一条，整体超时返回已经拿到的部分；
/// - 空输入直接返回 `const {}`，连并发池都不建。
library;

import 'dart:convert';

import '../core/external_meta.dart';
import '../core/following.dart';
import '../core/meta_pipeline.dart';
import '../core/meta_source.dart';
import '../core/protocol.dart';
import '../core/source_meta_resolver.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../core/tmdb_title.dart';
import 'external_meta_service.dart';
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
    this.title = '',
    this.poster,
    this.backdrop,
    this.overview,
    this.genres = const [],
    this.year = '',
    this.rating = 0,
  });

  /// 刮削后的作品名（TMDB `name` / `title`）：详情页头部用的就是它，
  /// 首页 hero 与卡片跟着用它，两边才不会出现「首页叫原始名、详情页叫刮削名」。
  /// 空串表示没有，页面保留站点原名。
  final String title;

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

  /// 追剧没有内嵌 TMDB 身份：复用持久化匹配，再按详情页的逐字段规则补全。
  Future<Map<String, HomeMeta>> resolveFollowings(
    Iterable<Following> items, {
    required Future<TmdbItem?> Function(Following) match,
    Future<Vod?> Function(Following)? source,
    String? Function(Following)? siteName,
    required MetaPipeline pipeline,
    ExternalMetaService? external,
    MetaIdentity? Function(Following)? pinned,
    bool Function()? isCurrent,
    int concurrency = 2,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final rows = {for (final item in items) item.identityKey: item}.values
        .toList();
    if (rows.isEmpty) return const {};
    const fields = {
      // 标题也参与：首页 hero 与卡片要显示**刮削名**，与详情页头部同一条规则；
      // 把它排除在外会让管线里的「标题」来源被清空，追剧条目只能退回站点原名。
      MetaField.title,
      MetaField.poster,
      MetaField.backdrop,
      MetaField.overview,
      MetaField.genres,
      MetaField.releaseDate,
    };
    var rules = pipeline;
    for (final field in MetaField.values.where(
      (field) => !fields.contains(field),
    )) {
      rules = rules.withRule(rules.ruleOf(field).copyWith(order: const []));
    }
    // 多季共用同一部作品标题：同一查询只解析一次外部快照。
    final queries = <String, Future<MetaFieldSnapshots?>>{};
    final usesExternal =
        external != null &&
        fields.any((field) => rules.orderOf(field).isNotEmpty);
    final usesTmdb = fields.any(
      (field) => rules.orderOf(field).contains(MetaSourceKind.tmdb),
    );
    final usesSource =
        source != null &&
        fields.any(
          (field) => rules.orderOf(field).contains(MetaSourceKind.source),
        );
    // 站源可能在链的中间胜出；不能先拿低优先级外部数据填满，再误判无需读站源。
    final sourceBeforeExternal =
        usesSource &&
        fields.any((field) {
          final order = rules.orderOf(field);
          final index = order.indexOf(MetaSourceKind.source);
          if (index < 0) return false;
          return index == 0 ||
              order
                  .skip(index + 1)
                  .any(
                    (kind) =>
                        kind == MetaSourceKind.douban ||
                        kind == MetaSourceKind.bangumi,
                  );
        });
    final details = <TmdbIdentity, Future<Map<String, Object?>>>{};
    final matches = <String, Future<TmdbItem?>>{};
    final sources = <String, Future<Vod?>>{};
    final result = <String, HomeMeta>{};
    var next = 0;
    var expired = false;
    bool stopped() => expired || !(isCurrent?.call() ?? true);

    Future<void> worker() async {
      while (!stopped() && next < rows.length) {
        final row = rows[next++];
        var vod = Vod(
          vodId: row.vodId,
          vodName: row.vodName,
          vodPic: row.vodPic,
        );
        var sourceFetched = false;
        Future<Vod> readSource() async {
          try {
            return await sources.putIfAbsent(
                  row.seriesKey,
                  () => source!(row),
                ) ??
                vod;
          } catch (_) {
            // 站点被删除或离线时仍可按追剧标题匹配外部元数据。
            return vod;
          }
        }

        if (sourceBeforeExternal) {
          vod = await readSource();
          sourceFetched = true;
        }
        if (stopped()) return;
        TmdbDetailData? tmdb;
        TmdbIdentity? identity;
        // 持久化匹配命中会先于匹配器的站点闸门返回；禁用站点只能在这里拦。
        final tmdbAllowed =
            usesTmdb &&
            _tmdb.config.isReady &&
            _tmdb.config.isSiteEnabled(row.siteKey, siteName?.call(row) ?? '');
        if (tmdbAllowed) {
          try {
            final item = await matches.putIfAbsent(
              row.seriesKey,
              () => match(row),
            );
            if (stopped()) return;
            identity = item?.identity;
            if (identity != null) {
              final detail = await details.putIfAbsent(
                identity,
                () => _load(identity!),
              );
              tmdb = TmdbDetailData.fromDetail(
                detail,
                imageBase: _tmdb.config.imageBase,
                backdropBase: _tmdb.config.backdropBase,
                item: item,
              );
            }
          } catch (_) {
            // TMDB 失败不截断豆瓣、Bangumi 与站源的逐字段兜底。
          }
        }
        if (stopped()) return;
        MetaFieldSnapshots? snapshots;
        if (usesExternal) {
          final query = MetaQuery(
            title: vod.vodName,
            year: firstYear(vod.vodYear ?? ''),
            isTv: true,
          );
          final pin = pinned?.call(row);
          final queryKey = jsonEncode([
            row.seriesKey,
            query.key,
            pin?.key,
            identity?.key,
          ]);
          try {
            snapshots = await queries.putIfAbsent(
              queryKey,
              () => external.resolveFields(
                query,
                source: vod,
                pipeline: rules,
                tmdb: tmdb,
                tmdbIdentity: identity == null
                    ? null
                    : MetaIdentity.of(
                        MetaSourceKind.tmdb,
                        identity.mediaType,
                        identity.tmdbId,
                      ),
                pinned: pin,
              ),
            );
          } catch (_) {
            // 外部源失败仍显示本轮已取得的 TMDB / 站源数据。
          }
        }
        if (stopped()) return;
        final activePipeline = snapshots?.effectivePipeline(rules) ?? rules;
        var data = SourceMetaResolver.resolve(
          pipeline: activePipeline,
          source: vod,
          tmdb: tmdb,
          providers: snapshots?.providers ?? const {},
          primary: snapshots?.primary?.data,
        );
        // 默认管线里站源在最后：TMDB / 外部源已经填满展示字段时不必再读一次站点。
        // 站源自己的背景就是海报，单独缺背景不构成读站点的理由。
        bool missing(MetaField field, bool has) =>
            !has &&
            activePipeline.orderOf(field).contains(MetaSourceKind.source);
        final aggregateSource =
            activePipeline.modeOf(MetaField.genres) ==
                MetaFieldMode.aggregate &&
            activePipeline
                .orderOf(MetaField.genres)
                .contains(MetaSourceKind.source);
        final needsSource =
            usesSource &&
            !sourceFetched &&
            (aggregateSource ||
                missing(MetaField.poster, _nonEmpty(data.posterUrl) != null) ||
                missing(MetaField.overview, _nonEmpty(data.overview) != null) ||
                missing(MetaField.genres, data.genres.isNotEmpty) ||
                missing(
                  MetaField.releaseDate,
                  _yearOf({'release_date': data.releaseDate}).isNotEmpty,
                ));
        if (needsSource) {
          vod = await readSource();
          if (stopped()) return;
          data = SourceMetaResolver.resolve(
            pipeline: activePipeline,
            source: vod,
            tmdb: tmdb,
            providers: snapshots?.providers ?? const {},
            primary: snapshots?.primary?.data,
          );
        }
        final backdrop = data.backdropUrls
            .where(
              (url) =>
                  url.trim().isNotEmpty &&
                  url != data.posterUrl &&
                  url != vod.vodPic,
            )
            .firstOrNull;
        result[row.identityKey] = HomeMeta(
          title: _nonEmpty(data.title) ?? '',
          poster: _nonEmpty(data.posterUrl),
          backdrop: backdrop,
          overview: _nonEmpty(data.overview),
          genres: data.genres.take(3).toList(),
          year: _yearOf({'release_date': data.releaseDate}),
          rating: data.rating,
        );
      }
    }

    final slots = concurrency < 1 ? 1 : concurrency;
    await Future.wait(
      List.generate(slots < rows.length ? slots : rows.length, (_) => worker()),
    ).timeout(
      timeout,
      onTimeout: () {
        expired = true;
        return const <void>[];
      },
    );
    return Map.of(result);
  }

  /// 拼地址口径与 `TmdbDetailData.fromDetail` 一致：背景走 `backdropBase`、
  /// 海报走 `imageBase`，各自取排序后的第一张。
  ///
  /// 不做「无背景时拿海报顶」的回退：竖版海报拉成背景会糊，而且这里返回
  /// `null` 正好让调用方保留站点自己的背景图。
  HomeMeta? _artOf(Map<String, Object?> detail) {
    final config = _tmdb.config;
    final title = _titleOf(detail);
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
    if (title.isEmpty &&
        backdrops.isEmpty &&
        posters.isEmpty &&
        overview.isEmpty &&
        genres.isEmpty &&
        year.isEmpty &&
        rating <= 0) {
      return null;
    }
    return HomeMeta(
      title: title,
      poster: posters.isEmpty ? null : posters.first,
      backdrop: backdrops.isEmpty ? null : backdrops.first,
      overview: overview.isEmpty ? null : overview,
      genres: genres,
      year: year,
      rating: rating,
    );
  }
}

String? _nonEmpty(String? text) =>
    (text ?? '').trim().isEmpty ? null : text!.trim();

/// 作品名：电影用 `title`、剧集用 `name`（TMDB 两套字段）。
String _titleOf(Map<String, Object?> detail) {
  for (final key in const ['name', 'title']) {
    final value = detail[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return '';
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
