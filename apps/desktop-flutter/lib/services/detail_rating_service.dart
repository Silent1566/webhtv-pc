/// 详情页「外部评分」查询：豆瓣 + OMDb 两半合流（见 `core/detail_ratings.dart`）。
///
/// 边界：
/// - **不抛异常**：评分是详情页的增强信息，任何失败都退化成空值，详情页不能
///   因为评分请求失败而变成错误页。
/// - 两半**并行**：豆瓣与 OMDb 互不依赖，串行只是把等待叠加；每个分支自己兜住
///   异常，一半失败不影响另一半。
/// - 没有 OMDb Key 或没有 imdbId 时**一次都不请求** OMDb（没有 Key 是 PC 端常态，
///   空 key 打请求只会拿 401，见 `omdb_service.dart`）。
/// - 内存缓存按「作品 + 是否带 OMDb Key」分键：同一详情页重建多次不重复请求，
///   用户刚填上 Key 时又能立刻补上 OMDb 那一半。
library;

import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/detail_ratings.dart';
import 'douban_recommendation_service.dart';
import 'log_service.dart';
import 'omdb_service.dart';

/// 豆瓣评分查询的函数式接口（测试注入假实现，避免真实网络与磁盘）。
typedef DoubanRatings = Future<double> Function({
  required String title,
  required String mediaType,
  required int year,
});

/// 一次外部评分查询。无 OMDb Key 时只查豆瓣；两者都没有时不发任何请求。
class DetailRatingService {
  DetailRatingService({
    OmdbService? omdb,
    DoubanRatings? douban,
    this.cacheTtl = const Duration(days: 7),
    LogService? log,
  }) : // 具名参数 `omdb` / `douban` / `log` 不能作为初始化形参绑定到私有字段。
       // ignore: prefer_initializing_formals
       _omdb = omdb,
       // ignore: prefer_initializing_formals
       _douban = douban,
       _onClose = null,
       // 注入模式下的豆瓣实现由调用方拥有，本服务无权取消它的间隔。
       _doubanOwner = null,
       // ignore: prefer_initializing_formals
       _log = log;

  DetailRatingService._owned({
    required OmdbService omdb,
    required DoubanRecommendationService douban,
    LogService? log,
  }) : cacheTtl = const Duration(days: 7),
       // ignore: prefer_initializing_formals
       _omdb = omdb,
       // 复用豆瓣服务自己的队列/缓存/冷却，因此直接绑它的 lookupRating。
       _douban = douban.lookupRating,
       _doubanOwner = douban,
       _onClose = _closeBoth(omdb, douban),
       // ignore: prefer_initializing_formals
       _log = log;

  /// 供 app_state 用的便捷构造：自建 OMDb 与豆瓣查询（`close()` 一并释放）。
  ///
  /// 注入的 [client] 只被借用：两个子服务都不持有它，`close()` 不会关掉调用方
  /// 的客户端。
  factory DetailRatingService.fromServices({
    http.Client? client,
    Directory? cacheDirectory,
    LogService? log,
  }) {
    return DetailRatingService._owned(
      omdb: OmdbService(client: client, log: log),
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
    // 「有没有 Key」进缓存键：用户填上 Key 后必须重查，而不是拿旧的豆瓣结果。
    final key = '${request.cacheKey}|${apiKey.isEmpty ? 'douban' : 'omdb'}';
    final cached = _read(key);
    if (cached != null) return cached;

    final halves = <Future<DetailRatingValues>>[
      _doubanHalf(request),
      if (apiKey.isNotEmpty && imdbId.isNotEmpty) _omdbHalf(imdbId, apiKey),
    ];
    var values = DetailRatingValues.empty;
    for (final half in await Future.wait(halves)) {
      values = values.merge(half);
    }
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

void Function() _closeBoth(
  OmdbService omdb,
  DoubanRecommendationService douban,
) => () {
  omdb.close();
  douban.close();
};

class _CacheEntry {
  const _CacheEntry(this.at, this.values);
  final DateTime at;
  final DetailRatingValues values;
}
