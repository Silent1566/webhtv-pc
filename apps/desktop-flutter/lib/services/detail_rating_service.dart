/// 详情页「外部评分」查询：豆瓣 + OMDb + IMDb 直连合流（见 `core/detail_ratings.dart`）。
///
/// 边界：
/// - **不抛异常**：评分是详情页的增强信息，任何失败都退化成空值，详情页不能
///   因为评分请求失败而变成错误页。
/// - 两半**并行**：豆瓣与 OMDb 互不依赖，串行只是把等待叠加；每个分支自己兜住
///   异常，一半失败不影响另一半。
/// - 没有 OMDb Key 或没有 imdbId 时**一次都不请求** OMDb（没有 Key 是 PC 端常态，
///   空 key 打请求只会拿 401，见 `omdb_service.dart`）。
/// - 没有 Key（PC 端常态）时改用 IMDb 直连取分；有 Key 但 OMDb 没给出 IMDb 分时
///   同样调用一次直连服务（GraphQL + 可选 HTML 兜底），非法 `imdbId` 不发请求。
/// - IMDb 直连受 `imdbEnabled` 回调控制（默认开）：关掉时既不发直连请求，也不
///   返回 IMDb 分/人数（连 OMDb 给的那份也不返回），豆瓣、烂番茄、MC 不受影响。
/// - 内存缓存按「作品 + 是否带 OMDb Key + IMDb 开关」分键：同一详情页重建多次不
///   重复请求，用户刚填上 Key 或重新打开 IMDb 时又能立刻补上对应那一半。
library;

import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/detail_ratings.dart';
import 'douban_recommendation_service.dart';
import 'imdb_rating_service.dart';
import 'log_service.dart';
import 'omdb_service.dart';

/// 豆瓣评分查询的函数式接口（测试注入假实现，避免真实网络与磁盘）。
typedef DoubanRatings = Future<double> Function({
  required String title,
  required String mediaType,
  required int year,
});

/// 一次外部评分查询；IMDb 优先取 OMDb，无 Key 或缺分时走免 Key 直连。
class DetailRatingService {
  DetailRatingService({
    OmdbService? omdb,
    ImdbRatingService? imdb,
    DoubanRatings? douban,
    bool Function()? imdbEnabled,
    this.cacheTtl = const Duration(days: 7),
    LogService? log,
  }) : // 具名参数 `omdb` / `douban` / `log` 不能作为初始化形参绑定到私有字段。
       // ignore: prefer_initializing_formals
       _omdb = omdb,
       // ignore: prefer_initializing_formals
       _imdb = imdb,
       // ignore: prefer_initializing_formals
       _douban = douban,
       // 具名参数 `imdbEnabled` 不能作为初始化形参绑定到私有字段。
       // ignore: prefer_initializing_formals
       _imdbEnabled = imdbEnabled,
       _onClose = null,
       // 注入模式下的豆瓣实现由调用方拥有，本服务无权取消它的间隔。
       _doubanOwner = null,
       // ignore: prefer_initializing_formals
       _log = log;

  DetailRatingService._owned({
    required OmdbService omdb,
    required ImdbRatingService imdb,
    required bool closeImdb,
    required DoubanRecommendationService douban,
    bool Function()? imdbEnabled,
    LogService? log,
  }) : cacheTtl = const Duration(days: 7),
       // ignore: prefer_initializing_formals
       _omdb = omdb,
       // ignore: prefer_initializing_formals
       _imdb = imdb,
       // 复用豆瓣服务自己的队列/缓存/冷却，因此直接绑它的 lookupRating。
       _douban = douban.lookupRating,
       _doubanOwner = douban,
       // 具名参数 `imdbEnabled` 不能作为初始化形参绑定到私有字段。
       // ignore: prefer_initializing_formals
       _imdbEnabled = imdbEnabled,
       _onClose = _closeServices(omdb, douban, imdb, closeImdb: closeImdb),
       // ignore: prefer_initializing_formals
       _log = log;

  /// 供 app_state 用的便捷构造：自建 OMDb、IMDb 与豆瓣查询（`close()` 一并释放）。
  ///
  /// 注入的 [client] 只被借用：子服务均不拥有它，`close()` 不会关掉调用方
  /// 的客户端。
  factory DetailRatingService.fromServices({
    http.Client? client,
    Directory? cacheDirectory,
    LogService? log,
    ImdbRatingService? imdb,
    bool Function()? imdbEnabled,
  }) {
    return DetailRatingService._owned(
      omdb: OmdbService(client: client, log: log),
      imdb: imdb ?? ImdbRatingService(client: client, log: log),
      closeImdb: imdb == null,
      imdbEnabled: imdbEnabled,
      douban: DoubanRecommendationService(
        client: client,
        cacheDirectory: cacheDirectory == null
            ? null
            : Directory(
                '${cacheDirectory.path}${Platform.pathSeparator}'
                'douban_ratings',
              ),
      ),
      log: log,
    );
  }

  /// 内存缓存条目的存活时间（同一部作品在 TTL 内只查一次）。
  final Duration cacheTtl;

  /// 缓存条数上限：详情页走过的作品数远小于这个量级。
  static const int maxCacheEntries = 64;

  final OmdbService? _omdb;

  /// IMDb 直连：没有 OMDb Key（或 OMDb 没给出 IMDb 分）时唯一的 IMDb 分来源。
  /// 可能是自建实例，也可能是 [fromServices] 借用的共享实例。
  final ImdbRatingService? _imdb;

  /// 直连开关（未注入时按 true 处理）；每次 [fetch] 都重新读取。
  final bool Function()? _imdbEnabled;

  /// 实际使用的 IMDb 直连实例（借用或自建），供接线与测试观察。
  ImdbRatingService? get imdb => _imdb;

  bool get _imdbOn => _imdbEnabled?.call() ?? true;
  final DoubanRatings? _douban;
  final LogService? _log;

  /// 只在 [DetailRatingService.fromServices] 里有值：`close()` 释放自建的子服务。
  final void Function()? _onClose;

  /// 同样只在自建模式下有值：页面关闭时用来取消**正在等待的**限速间隔。
  final DoubanRecommendationService? _doubanOwner;

  final _cache = <String, _CacheEntry>{};
  bool _closed = false;

  /// 查询外部评分。**必须不抛异常**：任何失败都返回已有的/空的
  /// [DetailRatingValues]。
  Future<DetailRatingValues> fetch(
    DetailRatingRequest request, {
    required String omdbApiKey,
  }) async {
    if (request.isEmpty) return DetailRatingValues.empty;
    final apiKey = omdbApiKey.trim();
    final imdbId = request.imdbId.trim();
    final imdbOn = _imdbOn;
    final imdb = imdbOn ? _imdb : null;
    // 直连能力（含启停状态）进缓存键：关掉再打开不能读到旧的 IMDb 分。
    final direct = imdb != null && imdbId.isNotEmpty;
    final key =
        '${request.cacheKey}|${apiKey.isEmpty ? 'douban' : 'omdb'}'
        '|imdb-${imdbOn ? 'on' : 'off'}|direct-$direct';
    final cached = _read(key);
    if (cached != null) return cached;

    final useOmdb = apiKey.isNotEmpty && imdbId.isNotEmpty && _omdb != null;
    // 「豆瓣」与「OMDb 或 IMDb 直连」互不依赖，一起发；每个分支自己兜住异常。
    final halves = <Future<DetailRatingValues>>[
      _doubanHalf(request),
      if (useOmdb)
        _omdbHalf(imdbId, apiKey)
      else if (direct)
        _imdbHalf(imdbId, imdb),
    ];
    var values = DetailRatingValues.empty;
    for (final half in await Future.wait(halves)) {
      values = values.merge(half);
    }
    // OMDb 200 却没给 IMDb 分（`N/A`、`Response=false`、请求失败）时再补一枪直连：
    // 填了 Key 不该比没填时少一个分。
    if (useOmdb && direct && _imdbOn && values.imdb.isEmpty) {
      values = values.merge(await _imdbHalf(imdbId, imdb));
    }
    // 关掉 IMDb 时，OMDb 给出的 IMDb 分与人数也一并滤掉：开关要能真正收回
    // 这类数据，而不只是少发一次请求。
    final imdbStillOn = _imdbOn;
    if (!imdbOn || !imdbStillOn) values = _withoutImdb(values);
    // 开关在请求期间变化时不把过滤后的结果写进原先的启用缓存。
    if (_closed || imdbStillOn != imdbOn) return values;
    // 空的也进缓存等于把一次网络抽风钉死 [cacheTtl]（对齐豆瓣服务「不缓存 0」）。
    if (!values.isEmpty) _write(key, values);
    return values;
  }

  /// 页面关掉了：取消还在等限速间隔的那次请求。
  ///
  /// 只影响「等待中」的那一枪——缓存、冷却与已完成的请求都不动，服务继续可用。
  void cancelPending() => _doubanOwner?.cancelPendingSpacing();

  void close() {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    _onClose?.call();
  }

  Future<DetailRatingValues> _doubanHalf(DetailRatingRequest request) async {
    final douban = _douban;
    final title = request.title.trim();
    if (douban == null || title.isEmpty) return DetailRatingValues.empty;
    try {
      final rating = await douban(
        title: title,
        mediaType: request.mediaType.name,
        year: request.year,
      );
      if (!rating.isFinite || rating <= 0) return DetailRatingValues.empty;
      return DetailRatingValues(doubanRating: rating);
    } catch (error) {
      _warn('豆瓣评分查询失败：$error');
      return DetailRatingValues.empty;
    }
  }

  Future<DetailRatingValues> _omdbHalf(String imdbId, String apiKey) async {
    final omdb = _omdb;
    if (omdb == null) return DetailRatingValues.empty;
    try {
      final json = await omdb.fetch(imdbId: imdbId, apiKey: apiKey);
      if (_closed || json.isEmpty) return DetailRatingValues.empty;
      // 归一与投票数压缩都在 core 层（[parseOmdbRatings]），这一层不再重复实现。
      return parseOmdbRatings(json);
    } catch (error) {
      _warn('OMDb 评分解析失败：$error');
      return DetailRatingValues.empty;
    }
  }

  Future<DetailRatingValues> _imdbHalf(
    String imdbId,
    ImdbRatingService imdb,
  ) async {
    try {
      final rating = await imdb.byImdbId(imdbId);
      if (_closed || rating.isEmpty) return DetailRatingValues.empty;
      return DetailRatingValues(imdb: rating.value, imdbVotes: rating.votes);
    } catch (error) {
      _warn('IMDb 评分请求失败：$error');
      return DetailRatingValues.empty;
    }
  }

  DetailRatingValues _withoutImdb(DetailRatingValues values) =>
      DetailRatingValues(
        doubanRating: values.doubanRating,
        rottenTomatoes: values.rottenTomatoes,
        metacritic: values.metacritic,
      );

  void _warn(String message) => _log?.warning(message, scope: 'tmdb');

  DetailRatingValues? _read(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    final age = DateTime.now().difference(entry.at);
    if (age.isNegative || age >= cacheTtl) {
      _cache.remove(key);
      return null;
    }
    return entry.values;
  }

  void _write(String key, DetailRatingValues values) {
    if (_closed) return;
    _cache[key] = _CacheEntry(DateTime.now(), values);
    if (_cache.length > maxCacheEntries) _cache.remove(_cache.keys.first);
  }
}

void Function() _closeServices(
  OmdbService omdb,
  DoubanRecommendationService douban,
  ImdbRatingService imdb, {
  required bool closeImdb,
}) => () {
  omdb.close();
  // 借用的共享实例归调用方所有，详情页关掉时不替别人释放。
  if (closeImdb) imdb.close();
  douban.close();
};

class _CacheEntry {
  const _CacheEntry(this.at, this.values);
  final DateTime at;
  final DetailRatingValues values;
}
