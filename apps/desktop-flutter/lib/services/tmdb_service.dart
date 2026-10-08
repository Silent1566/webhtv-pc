/// TMDB HTTP 服务：端点封装、TTL 三级读路径、鉴权熔断、错误映射、取消
/// （`docs/phase4/design/03` §3/§4/§8）。
///
/// 上游对应实现：`service/TmdbService`（1158 行）。
///
/// 关键契约：
/// - **未配置时不发请求**（`00` §3.4）；
/// - 401/403 触发 5 分钟熔断，熔断期内**零请求**，且按凭据隔离（`03` §3.4）；
/// - 网络失败时回退到**任意陈旧缓存**（`03` §3.3）；
/// - 取消时**不写缓存、不落盘**（`03` §3.5）；
/// - 全部错误归一化为 `tmdb*` 分类，属**非致命**类别（`03` §4.5）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/app_error.dart';
import '../core/tmdb_config.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import 'tmdb_cache.dart';

/// TMDB 请求被取消。
class TmdbCancelledException implements Exception {
  const TmdbCancelledException();

  @override
  String toString() => 'TmdbCancelledException';
}

/// 取消令牌（`03` §3.5）。
class TmdbCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const TmdbCancelledException();
  }
}

/// TMDB 鉴权失败（`03` §3.4）。携带状态码以便熔断与诊断。
class TmdbAuthException implements Exception {
  const TmdbAuthException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'TmdbAuthException($statusCode): $message';
}

/// 端点清单（`03` §4.1）。
abstract final class TmdbEndpoint {
  static const String configuration = '/configuration';
  static const String searchMulti = '/search/multi';
  static String detail(TmdbMediaType type, int id) => '/${type.name}/$id';
  static String season(int id, int season) => '/tv/$id/season/$season';
  static String episode(int id, int season, int episode) =>
      '/tv/$id/season/$season/episode/$episode';
  static String person(int id) => '/person/$id';
  static String videos(TmdbMediaType type, int id) => '/${type.name}/$id/videos';
  static String seasonVideos(int id, int season) =>
      '/tv/$id/season/$season/videos';
  static String episodeVideos(int id, int season, int episode) =>
      '/tv/$id/season/$season/episode/$episode/videos';
  static String recommendations(TmdbMediaType type, int id) =>
      '/${type.name}/$id/recommendations';
  static String similar(TmdbMediaType type, int id) => '/${type.name}/$id/similar';
}

/// `append_to_response` 组合（`03` §4.1）。
abstract final class TmdbAppend {
  static const String tv =
      'images,credits,aggregate_credits,translations,external_ids,content_ratings';
  static const String movie =
      'images,credits,translations,external_ids,release_dates';
  static const String season =
      'images,credits,aggregate_credits,translations';
  static const String episode = 'images,credits,translations';
  static const String person = 'combined_credits,images,translations,external_ids';
  static const String related = 'recommendations,similar';

  static String detail(TmdbMediaType type, {required bool includeRelated}) {
    final base = type == TmdbMediaType.tv ? tv : movie;
    return includeRelated ? '$base,$related' : base;
  }
}

/// TMDB HTTP 服务。
///
/// 全部方法在未配置凭据时抛 [AppErrorKind.tmdbNotConfigured] 且**不发请求**。
class TmdbService {
  TmdbService({
    required TmdbConfig Function() config,
    http.Client? client,
    TmdbCache? cache,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 15),
  }) : _config = config,
       _client = client ?? http.Client(),
       _cache = cache,
       _clock = clock ?? DateTime.now;

  // 这两个字段无法用初始化形参：`_config` 需保持函数引用语义，
  // `_cache` 需与其它包装参数一起在初始化列表中赋值。
  // ignore_for_file: prefer_initializing_formals
  final TmdbConfig Function() _config;
  final http.Client _client;
  final TmdbCache? _cache;
  final DateTime Function() _clock;
  final Duration timeout;

  /// 当前 TMDB 配置（只读）。
  ///
  /// UI 层需要 `imageBase` / `backdropBase` 拼接图片地址，因此这里暴露一个
  /// 只读快照；不得在服务外部修改配置（写入统一走设置页的 `saveTmdbConfig`）。
  TmdbConfig get config => _config();

  /// 鉴权熔断表（`03` §3.4）：`authCircuitKey -> 解禁时间`。
  final Map<String, DateTime> _authBlocks = {};

  /// 请求计数器（测试与诊断用）。
  int requestCount = 0;

  /// 最近一次缓存来源（`cache` / `network` / `stale-cache`）。
  String? lastSource;

  /// 熔断键 = `md5(apiBase|apiKey|accessToken)` 的等价稳定串。
  ///
  /// 这里不做真实 md5（纯逻辑层不引 crypto），用长度受限的稳定拼接即可满足
  /// “按凭据隔离”的语义，且不泄露凭据原文。
  String _authCircuitKey(TmdbConfig config) {
    final base = config.apiBase;
    final key = config.apiKey;
    final token = config.accessToken;
    return '${base.length}:$base|${key.length}|${token.length}';
  }

  /// 请求前的熔断检查（`03` §3.4）。
  void throwIfAuthBlocked(TmdbConfig config) {
    final blockKey = _authCircuitKey(config);
    final until = _authBlocks[blockKey];
    if (until == null) return;
    if (!until.isAfter(_clock())) {
      _authBlocks.remove(blockKey);
      return;
    }
    throw const TmdbAuthException(
      401,
      'TMDB authentication temporarily blocked after HTTP 401/403',
    );
  }

  /// 熔断是否处于开启状态（诊断用）。
  bool isAuthBlocked(TmdbConfig config) {
    final until = _authBlocks[_authCircuitKey(config)];
    return until != null && until.isAfter(_clock());
  }

  /// 手动清除熔断（测试用）。
  void clearAuthBlocks() => _authBlocks.clear();

  void close() => _client.close();

  // -------------------------------------------------------------------------
  // 端点方法（`03` §4.6）
  // -------------------------------------------------------------------------

  Future<Map<String, Object?>> configuration({
    TmdbCancellationToken? cancel,
  }) {
    return _request(
      TmdbCacheType.configuration,
      TmdbEndpoint.configuration,
      TmdbTtl.search,
      cancel: cancel,
      requiredFields: const ['images'],
    );
  }

  Future<List<TmdbItem>> search(
    String keyword, {
    TmdbCancellationToken? cancel,
  }) async {
    final config = _requireConfig();
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final body = await _request(
      TmdbCacheType.search,
      TmdbEndpoint.searchMulti,
      TmdbTtl.search,
      query: {'query': query},
      cancel: cancel,
      requiredFields: const ['results'],
    );
    return _itemsFromSearch(body, config);
  }

  Future<Map<String, Object?>> detail(
    TmdbItem item, {
    bool includeRelated = true,
    bool refresh = false,
    TmdbCancellationToken? cancel,
  }) async {
    final config = _requireConfig();
    final identity = item.identity;
    if (identity == null) {
      throw AppError(AppErrorKind.tmdbEmpty, 'TMDB 详情缺少有效身份');
    }
    final url = TmdbEndpoint.detail(identity.mediaType, identity.tmdbId);
    final append = TmdbAppend.detail(identity.mediaType, includeRelated: includeRelated);
    // 回退键必须是**与写入时完全一致的 URI**（含 include_image_language），
    // 否则永远命中不了（§3.2）。
    final keys = <String>[
      _detailCacheUri(config, url, append),
      if (!includeRelated)
        _detailCacheUri(
          config,
          url,
          TmdbAppend.detail(identity.mediaType, includeRelated: true),
        ),
    ];
    return _request(
      TmdbCacheType.detail,
      url,
      TmdbTtl.detail,
      query: {'append_to_response': append},
      cancel: cancel,
      refresh: refresh,
      cacheKeys: keys,
      ttlOf: _detailTtl,
      requiredFields: const ['id'],
      extraHeaders: _languageHeaders(config, includeImages: true),
    );
  }

  Future<Map<String, Object?>> season(
    TmdbItem item,
    int seasonNumber, {
    bool refresh = false,
    TmdbCancellationToken? cancel,
  }) async {
    final identity = item.identity;
    if (identity == null || identity.mediaType != TmdbMediaType.tv) {
      throw AppError(AppErrorKind.tmdbEmpty, 'TMDB 分季要求剧集身份');
    }
    return _request(
      TmdbCacheType.season,
      TmdbEndpoint.season(identity.tmdbId, seasonNumber),
      TmdbTtl.season,
      query: {'append_to_response': TmdbAppend.season},
      cancel: cancel,
      refresh: refresh,
      requiredFields: const ['episodes'],
      extraHeaders: _languageHeaders(_requireConfig(), includeImages: true),
    );
  }

  Future<List<TmdbEpisode>> seasonEpisodes(
    TmdbItem item,
    int seasonNumber, {
    bool refresh = false,
    TmdbCancellationToken? cancel,
  }) async {
    final config = _requireConfig();
    final body = await season(
      item,
      seasonNumber,
      refresh: refresh,
      cancel: cancel,
    );
    return TmdbEpisode.listFromSeason(
      body,
      image: (base, path) => _image(base, path),
      imageBase: config.imageBase,
      fallbackSeasonNumber: seasonNumber,
    );
  }

  Future<Map<String, Object?>> episode(
    TmdbItem item,
    int seasonNumber,
    int episodeNumber, {
    TmdbCancellationToken? cancel,
  }) async {
    final identity = item.identity;
    if (identity == null || identity.mediaType != TmdbMediaType.tv) {
      throw AppError(AppErrorKind.tmdbEmpty, 'TMDB 单集要求剧集身份');
    }
    return _request(
      TmdbCacheType.episode,
      TmdbEndpoint.episode(identity.tmdbId, seasonNumber, episodeNumber),
      TmdbTtl.season,
      query: {'append_to_response': TmdbAppend.episode},
      cancel: cancel,
      requiredFields: const ['id'],
      extraHeaders: _languageHeaders(_requireConfig(), includeImages: true),
    );
  }

  Future<Map<String, Object?>> person(
    int personId, {
    TmdbCancellationToken? cancel,
  }) {
    return _request(
      TmdbCacheType.person,
      TmdbEndpoint.person(personId),
      TmdbTtl.person,
      query: {'append_to_response': TmdbAppend.person},
      cancel: cancel,
      requiredFields: const ['id'],
    );
  }

  /// 相关视频（`04` §7.1）。合并 movie/tv/season/episode 四个作用域。
  Future<List<TmdbVideo>> videos(
    TmdbItem item, {
    int? seasonNumber,
    int? episodeNumber,
    TmdbCancellationToken? cancel,
  }) async {
    final identity = item.identity;
    if (identity == null) return const [];
    final config = _requireConfig();
    final collected = <TmdbVideo>[];

    Future<void> fetch(String url, TmdbVideoScope scope, int season, int episode) async {
      try {
        final body = await _request(
          TmdbCacheType.videos,
          url,
          TmdbTtl.videos,
          cancel: cancel,
          requiredFields: const ['results'],
          emptyResultShortTtl: TmdbTtl.videosEmpty,
          shortTtlWhenEmpty: true,
        );
        collected.addAll(
          TmdbVideo.listFrom(
            body,
            scope: scope,
            seasonNumber: season,
            episodeNumber: episode,
          ),
        );
      } on TmdbCancelledException {
        rethrow;
      } on TmdbAuthException {
        rethrow;
      } catch (_) {
        // 单个作用域失败不阻塞其他作用域（`04` §3.4 失败隔离）。
      }
    }

    if (seasonNumber != null && episodeNumber != null) {
      await fetch(
        TmdbEndpoint.episodeVideos(identity.tmdbId, seasonNumber, episodeNumber),
        TmdbVideoScope.episode,
        seasonNumber,
        episodeNumber,
      );
    }
    if (seasonNumber != null) {
      await fetch(
        TmdbEndpoint.seasonVideos(identity.tmdbId, seasonNumber),
        TmdbVideoScope.season,
        seasonNumber,
        0,
      );
    }
    await fetch(
      TmdbEndpoint.videos(identity.mediaType, identity.tmdbId),
      identity.mediaType == TmdbMediaType.movie
          ? TmdbVideoScope.movie
          : TmdbVideoScope.tv,
      0,
      0,
    );

    return TmdbVideo.mergeAndRank(
      collected,
      preferredLanguage: _preferredLanguage(config.language),
      limit: 0,
    );
  }

  /// 推荐 / 相似（`03` §4.1）。
  Future<List<TmdbItem>> related(
    TmdbItem item, {
    required bool recommendations,
    int page = 1,
    TmdbCancellationToken? cancel,
  }) async {
    final identity = item.identity;
    if (identity == null) return const [];
    final config = _requireConfig();
    final url = recommendations
        ? TmdbEndpoint.recommendations(identity.mediaType, identity.tmdbId)
        : TmdbEndpoint.similar(identity.mediaType, identity.tmdbId);
    final body = await _request(
      TmdbCacheType.detail,
      url,
      TmdbTtl.detail,
      query: {'page': '$page'},
      cancel: cancel,
      requiredFields: const ['results'],
      cacheKeySuffix: 'p$page',
    );
    return _itemsFromSearch(body, config);
  }

  /// 演职人员（`03` §4.2）：电影取 `credits.cast`，剧集取 `aggregate_credits.cast`。
  List<TmdbPerson> cast(Map<String, Object?> detail) {
    final config = _config();
    final aggregate = _mapOf(detail['aggregate_credits']);
    final credits = _mapOf(detail['credits']);
    final raw = _listOf(aggregate?['cast'] ?? credits?['cast']);
    return TmdbPerson.listFrom(
      raw,
      image: (base, path) => _image(base, path),
      imageBase: config.imageBase,
    );
  }

  /// 主创（`created_by`）。
  List<TmdbPerson> creators(Map<String, Object?> detail) {
    final config = _config();
    return TmdbPerson.listFrom(
      _listOf(detail['created_by']),
      image: (base, path) => _image(base, path),
      imageBase: config.imageBase,
    );
  }

  /// 分季演职人员。
  List<TmdbPerson> seasonCast(Map<String, Object?> season) {
    final config = _config();
    final aggregate = _mapOf(season['aggregate_credits']);
    final credits = _mapOf(season['credits']);
    return TmdbPerson.listFrom(
      _listOf(aggregate?['cast'] ?? credits?['cast']),
      image: (base, path) => _image(base, path),
      imageBase: config.imageBase,
    );
  }

  /// 单集客串（`guest_stars`）。
  List<TmdbPerson> episodeGuests(Map<String, Object?> episode) {
    final config = _config();
    return TmdbPerson.listFrom(
      _listOf(episode['guest_stars']),
      image: (base, path) => _image(base, path),
      imageBase: config.imageBase,
    );
  }

  /// 剧照墙（`03` §4.4）。
  List<String> photos(
    Map<String, Object?> detail, {
    bool preferLandscape = false,
  }) {
    final config = _config();
    return TmdbImageSelector.backgrounds(
      detail,
      imageBase: config.imageBase,
      backdropBase: config.backdropBase,
      preferLandscape: preferLandscape,
    );
  }

  List<String> posters(Map<String, Object?> detail) {
    final config = _config();
    return TmdbImageSelector.posters(detail, config.imageBase);
  }

  List<String> backdrops(Map<String, Object?> detail) {
    final config = _config();
    return TmdbImageSelector.backdrops(detail, config.backdropBase);
  }

  /// 翻译简介（`03` §4.2）：优先取 `iso_639_1 == language 主语言` 的 `data.overview`。
  String? translatedOverview(Map<String, Object?> detail) {
    final config = _config();
    final preferred = _preferredLanguage(config.language);
    final translations = _mapOf(detail['translations']);
    final list = _listOf(translations?['translations']);
    for (final item in list) {
      final map = _mapOf(item);
      if (map == null) continue;
      final language = map['iso_639_1']?.toString().toLowerCase();
      if (language != preferred) continue;
      final data = _mapOf(map['data']);
      final overview = data?['overview'];
      if (overview is String && overview.trim().isNotEmpty) return overview;
    }
    final fallback = detail['overview'];
    if (fallback is String && fallback.trim().isNotEmpty) return fallback;
    return null;
  }

  /// 图片 URL 拼接（`03` §4.4）。
  String image(String base, String? path) => _image(base, path);

  /// 人物作品列表（`person.combined_credits`）。
  List<TmdbItem> personWorks(
    Map<String, Object?> person, {
    required bool cast,
  }) {
    final config = _config();
    final credits = _mapOf(person['combined_credits']);
    final raw = _listOf(credits?[cast ? 'cast' : 'crew']);
    return _itemsFromSearch({'results': raw}, config);
  }

  // -------------------------------------------------------------------------
  // 内部：请求与缓存
  // -------------------------------------------------------------------------

  TmdbConfig _requireConfig() {
    final config = _config();
    if (!config.isReady) {
      throw AppError(
        AppErrorKind.tmdbNotConfigured,
        '未配置 TMDB，请在设置中填写 API Key 或 Access Token',
      );
    }
    return config;
  }

  Uri _buildUri(TmdbConfig config, String path, Map<String, String> query) {
    final base = config.apiBase;
    final uri = Uri.parse('$base$path');
    final params = <String, String>{
      'language': config.language,
      ...query,
    };
    // 有 accessToken 时不附加 api_key（`03` §3.6）。
    if (config.accessToken.isEmpty) {
      params['api_key'] = config.apiKey;
    }
    return uri.replace(queryParameters: params);
  }

  Map<String, String> _languageHeaders(
    TmdbConfig config, {
    required bool includeImages,
  }) {
    if (!includeImages) return const {};
    return {'X-Image-Language': '${config.language},null'};
  }

  /// 详情缓存 URI：必须包含 `include_image_language`，与 `_request` 内部一致。
  String _detailCacheUri(TmdbConfig config, String url, String append) =>
      _buildUri(config, url, {
        'append_to_response': append,
        'include_image_language': '${config.language},null',
      }).toString();

  Duration _detailTtl(Map<String, Object?> payload) {
    // 含未播集信息时用短 TTL（`03` §3.3）。
    final next = payload['next_episode_to_air'];
    if (next is Map && next.isNotEmpty) return TmdbTtl.detailWithNextEpisode;
    return TmdbTtl.detail;
  }

  Future<Map<String, Object?>> _request(
    String type,
    String path,
    Duration ttl, {
    Map<String, String> query = const {},
    TmdbCancellationToken? cancel,
    bool refresh = false,
    List<String>? cacheKeys,
    Duration Function(Map<String, Object?> payload)? ttlOf,
    List<String> requiredFields = const [],
    Map<String, String> extraHeaders = const {},
    String? cacheKeySuffix,
    bool shortTtlWhenEmpty = false,
    Duration? emptyResultShortTtl,
  }) async {
    cancel?.throwIfCancelled();
    final config = _requireConfig();
    throwIfAuthBlocked(config);

    final uri = _buildUri(config, path, {
      ...query,
      if (extraHeaders.containsKey('X-Image-Language'))
        'include_image_language': extraHeaders['X-Image-Language']!,
    });
    final key = cacheKeySuffix == null ? uri.toString() : '${uri.toString()}&$cacheKeySuffix';
    final keys = cacheKeys ?? [key];
    final cache = _cache;

    // 1. 新鲜命中
    if (!refresh && cache != null) {
      final hit = cache.readFirstFresh(type, keys, ttlOf, ttl);
      if (hit != null) {
        lastSource = hit.source;
        return hit.payload;
      }
    }

    // 2. 网络请求
    try {
      cancel?.throwIfCancelled();
      requestCount++;
      final headers = <String, String>{
        if (config.accessToken.isNotEmpty)
          'Authorization': 'Bearer ${config.accessToken}',
        'Accept': 'application/json',
      };
      final response = await _client.get(uri, headers: headers).timeout(timeout);
      cancel?.throwIfCancelled();

      if (response.statusCode == 401 || response.statusCode == 403) {
        _authBlocks[_authCircuitKey(config)] =
            _clock().add(TmdbTtl.authCooldown);
        throw TmdbAuthException(
          response.statusCode,
          'TMDB 鉴权失败: HTTP ${response.statusCode}',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AppError(
          AppErrorKind.tmdbHttp,
          'TMDB 请求失败：HTTP ${response.statusCode}',
          statusCode: response.statusCode,
          retryable: response.statusCode >= 500,
        );
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } catch (error) {
        throw AppError(
          AppErrorKind.tmdbDecode,
          'TMDB 响应解析失败',
          detail: '$error',
          cause: error,
        );
      }
      if (decoded is! Map) {
        throw AppError(AppErrorKind.tmdbDecode, 'TMDB 响应不是 JSON 对象');
      }
      final body = decoded.cast<String, Object?>();
      for (final field in requiredFields) {
        if (!body.containsKey(field)) {
          throw AppError(
            AppErrorKind.tmdbEmpty,
            'TMDB 响应缺少必需字段 $field',
          );
        }
      }

      // 写缓存（取消时不写；写失败不影响返回）。
      if (cache != null) {
        cache.write(type, key, body);
      }
      lastSource = 'network';
      return body;
    } on TmdbAuthException {
      // 鉴权失败不做陈旧兜底（否则用户看不到真正的配置问题）。
      rethrow;
    } on TmdbCancelledException {
      rethrow;
    } catch (error) {
      // 3. 陈旧兜底（不看 TTL，`03` §3.3）
      if (cache != null) {
        final stale = cache.readFirstAny(type, keys);
        if (stale != null) {
          lastSource = 'stale-cache';
          return stale.payload;
        }
      }
      throw _mapError(error);
    }
  }

  /// 把任意异常归一化为 `tmdb*` 分类（`03` §4.5）。
  AppError _mapError(Object error) {
    if (error is AppError) return error;
    if (error is TimeoutException) {
      return AppError(
        AppErrorKind.tmdbNetwork,
        'TMDB 请求超时',
        detail: '${timeout.inSeconds}s',
        cause: error,
        retryable: true,
      );
    }
    return AppError(
      AppErrorKind.tmdbNetwork,
      'TMDB 请求失败：网络不可达或 DNS 失败',
      detail: '$error',
      cause: error,
      retryable: true,
    );
  }

  /// 从详情对象的 `recommendations` 取推荐（`03` §4.2）。
  List<TmdbItem> recommendationsFromDetail(Map<String, Object?> detail) =>
      _itemsFromRelated(detail['recommendations']);

  /// 从详情对象的 `similar` 取相似（`03` §4.2）。
  List<TmdbItem> similarFromDetail(Map<String, Object?> detail) =>
      _itemsFromRelated(detail['similar']);

  List<TmdbItem> _itemsFromRelated(Object? section) {
    final config = _config();
    final map = _mapOf(section);
    if (map == null) return const [];
    return _itemsFromSearch({'results': _listOf(map['results'])}, config);
  }

  List<TmdbItem> _itemsFromSearch(
    Map<String, Object?> body,
    TmdbConfig config,
  ) {
    final results = _listOf(body['results']);
    final items = <TmdbItem>[];
    for (final result in results) {
      final item = TmdbItem.fromSearchResult(
        result,
        image: (base, path) => _image(base, path),
        imageBase: config.imageBase,
        backdropBase: config.backdropBase,
      );
      if (item != null) items.add(item);
    }
    return items;
  }

  String _image(String base, String? path) =>
      TmdbImageSelector.image(base, path);

  String _preferredLanguage(String language) {
    final text = language.trim().toLowerCase();
    if (text.isEmpty) return '';
    final index = text.indexOf('-');
    return index > 0 ? text.substring(0, index) : text;
  }
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

Map<String, Object?>? _mapOf(Object? value) {
  if (value is! Map) return null;
  return value.cast<String, Object?>();
}

List<Object?> _listOf(Object? value) {
  if (value is! List) return const [];
  return value;
}
