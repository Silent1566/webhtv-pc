/// 站点服务：首页、分类、详情、搜索、播放编排（§6.1、§8、§10.2）。
///
/// 职责边界：
/// - 只通过 [SpiderRouter] 调用运行时，不关心运行时是 HTTP API 还是 sidecar；
/// - 单站点失败不得阻塞其他站点，错误以 [AppError] 向上传递；
/// - 播放决策交给 [PlaybackResolver]，本层只负责补全站点与播放结果上下文。
library;

import 'dart:async';

import '../core/app_error.dart';
import '../core/http_api.dart';
import '../core/parse_runtime.dart';
import '../core/playback.dart';
import '../core/protocol.dart';
import 'parse_service.dart';
import 'spider_router.dart';
import 'storage.dart';

/// 一次站点调用的结果，附带耗时用于健康统计。
class SiteCallResult<T> {
  const SiteCallResult({
    required this.value,
    required this.latency,
    this.fromCache = false,
  });

  final T value;
  final Duration latency;
  final bool fromCache;
}

/// 站点服务。
class SiteService {
  SiteService({
    required this.appConfig,
    required this.router,
    this.database,
    this.userAgent = HttpApiRequestBuilder.defaultUserAgent,
  });

  final AppConfig appConfig;
  final SpiderRouter router;

  /// 本地数据库（可为空：存储不可用时降级运行）。
  final AppDatabase? database;
  AppDatabase? get _database => database;
  final String userAgent;

  List<HeaderRule> get _globalHeaders => appConfig.headers;

  Site? siteByKey(String key) {
    for (final site in appConfig.sites) {
      if (site.key == key) return site;
    }
    return null;
  }

  /// 记录一次调用结果（§14.2），存储不可用时静默跳过。
  void _record(
    String siteKey,
    HealthAction action,
    bool success,
    Duration latency,
    String? error,
  ) {
    final database = _database;
    if (database == null) return;
    try {
      database.recordHealth(
        siteKey: siteKey,
        action: action,
        success: success,
        latencyMs: latency.inMilliseconds,
        error: error,
      );
    } catch (_) {
      // 健康统计失败不得影响主流程。
    }
  }

  Future<SiteCallResult<SiteResult>> _call(
    String siteKey,
    HealthAction action,
    Future<SiteResult> Function() body,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final value = await body();
      _record(siteKey, action, true, stopwatch.elapsed, null);
      return SiteCallResult(value: value, latency: stopwatch.elapsed);
    } catch (error) {
      final failure = error is AppError ? error : AppError(
        AppErrorKind.unknown,
        '$error',
        cause: error,
      );
      _record(siteKey, action, false, stopwatch.elapsed, failure.logLine);
      throw failure;
    }
  }

  /// 首页：`class` + `list`（§8.3）。
  Future<SiteCallResult<SiteResult>> home(Site site) async {
    final runtime = router.runtimeFor(site);
    return _call(site.key, HealthAction.home, () => runtime.home(site));
  }

  /// 分类：支持分页与筛选（§7.4.7）。
  Future<SiteCallResult<SiteResult>> category(
    Site site, {
    required String typeId,
    int page = 1,
    Map<String, String> filters = const {},
  }) async {
    final runtime = router.runtimeFor(site);
    return _call(
      site.key,
      HealthAction.category,
      () => runtime.category(
        site,
        typeId: typeId,
        page: page,
        filters: filters,
      ),
    );
  }

  /// 详情（§8.3）。
  Future<SiteCallResult<SiteResult>> detail(Site site, String vodId) async {
    final runtime = router.runtimeFor(site);
    return _call(site.key, HealthAction.detail, () => runtime.detail(site, vodId));
  }

  /// 搜索（§14.1）。
  Future<SiteCallResult<SiteResult>> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
    bool useCache = true,
  }) async {
    final database = _database;
    if (useCache && database != null) {
      try {
        final cached = database.readSearchCache(
          keyword: keyword,
          siteKey: site.key,
        );
        if (cached is Map) {
          final result = HttpApiResponseParser.parse(
            _toJsonText(cached),
            siteKey: site.key,
          );
          return SiteCallResult(
            value: result,
            latency: Duration.zero,
            fromCache: true,
          );
        }
      } catch (_) {
        // 缓存损坏时按未命中处理。
      }
    }

    final runtime = router.runtimeFor(site);
    final outcome = await _call(
      site.key,
      HealthAction.home,
      () => runtime.search(site, keyword: keyword, page: page, quick: quick),
    );
    if (database != null) {
      try {
        database.cacheSearch(
          keyword: keyword,
          siteKey: site.key,
          payload: outcome.value.toCacheJson(),
        );
      } catch (_) {
        // 缓存写入失败不影响搜索结果。
      }
    }
    return outcome;
  }

  /// 解析一次剧集播放（§7.4.8、§10.2、§12）。
  ///
  /// 返回的 [PlaybackDecision] 只可能是 [PlaybackAction.direct] 或
  /// [PlaybackAction.needParser]（后者已由解析器解析完成，仍是直接可播放的 url）；
  /// 真正无法解析时抛出 [AppErrorKind.playbackParserRequired]。
  Future<SiteCallResult<PlaybackDecision>> resolvePlayback({
    required Site site,
    required String episodeTarget,
    String? flag,
    String? vodId,
    ParseService? parseService,
  }) async {
    final runtime = router.runtimeFor(site);
    final stopwatch = Stopwatch()..start();

    // 站点播放入口回调（如猫源 `/play`）必须真实参与解析的站点：
    // `type=3` Spider 站点（含猫源 / JS）的剧集目标常是**站点播放入口的输入**（详情
    // `vod_play_url` 里该集 `$` 之后的值），而不是可直连的媒体地址。以网盘线路为例：
    //   episodeTarget；=`https://pan.baidu.com/s/...|...|<base64>`
    // 裸 scheme 是 https，若按普通 HTTP API 站点的「直链初判」会把它当成直链直接给
    // 播放器，于是网盘分享页被当 html 流 → `Failed to recognize file format`（实测）。
    // 参考实现（Silent1566/webhtv）对 `type=3` 在 `playerContent` 里**无条件**先调
    // `/play`（`site.recent().spider().playerContent(flag, id, ...)`），从不做这种短路。
    // 因此这里对 `type=3` 跳过直链初判，一律先向播放入口取真实地址；普通 HTTP API
    // 站点（`type=0/1/2/4`）保留原有初判，避免多余网络请求。
    // 注意：SpiderNull / Unsupported 站点的 runtime 会在 `/play` 时如实报错，
    // 不会伪装成直链成功。
    final mustCallPlay = site.type == SiteType.spider;

    PlaybackDecision? preliminary;
    if (!mustCallPlay) {
      try {
        preliminary = PlaybackResolver.decide(
          PlaybackResolutionInput(
            site: site,
            episodeTarget: episodeTarget,
            flag: flag,
            globalHeaders: _globalHeaders,
          ),
        );
      } on AppError {
        preliminary = null;
      }
    }

    if (!mustCallPlay && preliminary != null) {
      // §12：parse=1/jx=1 的目标 → 执行解析器；否则直接播放。
      if (preliminary.action == PlaybackAction.needParser) {
        final resolved = await _runParser(
          site: site,
          target: preliminary.url ?? episodeTarget,
          flag: flag,
          parse: preliminary.parse,
          jx: preliminary.jx,
          parseService: parseService,
          stopwatch: stopwatch,
        );
        return SiteCallResult(value: resolved, latency: stopwatch.elapsed);
      }
      _record(site.key, HealthAction.play, true, stopwatch.elapsed, null);
      return SiteCallResult(value: preliminary, latency: stopwatch.elapsed);
    }

    // 需要向播放入口取回真实地址（站点 playUrl）。
    try {
      final playResult = await runtime.play(
        site,
        episodeTarget: episodeTarget,
        flag: flag,
        vodId: vodId,
      );
      var decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: site,
          episodeTarget: playResult.playUrl ?? episodeTarget,
          flag: flag,
          parse: playResult.parse,
          jx: playResult.jx,
          resultHeader: playResult.header,
          globalHeaders: _globalHeaders,
          subs: playResult.subs,
          danmaku: playResult.danmaku,
        ),
      );
      if (decision.action == PlaybackAction.needParser) {
        decision = await _runParser(
          site: site,
          target: decision.url ?? episodeTarget,
          flag: flag,
          parse: decision.parse,
          jx: decision.jx,
          parseService: parseService,
          stopwatch: stopwatch,
        );
      }
      _record(site.key, HealthAction.play, true, stopwatch.elapsed, null);
      return SiteCallResult(value: decision, latency: stopwatch.elapsed);
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      _record(site.key, HealthAction.play, false, stopwatch.elapsed, failure.logLine);
      throw failure;
    }
  }

  /// 执行一次解析（§12.2→§12.3）。
  ///
  /// 解析失败抛 [AppErrorKind.parse*]，由调用方决定是否回退直接换源（不静默）。
  /// 成功则返回 [PlaybackAction.direct] 的解析结果（携带解析出的 Header/字幕/弹幕）。
  Future<PlaybackDecision> _runParser({
    required Site site,
    required String target,
    String? flag,
    int? parse,
    int? jx,
    ParseService? parseService,
    required Stopwatch stopwatch,
  }) async {
    final service = parseService ?? (parseService = ParseService());
    final selection = ParseRuntime.select(
      appConfig.parses,
      flag: flag,
    );
    final outcome = await service.run(
      selection: selection,
      entries: appConfig.parses,
      webUrl: target,
      flag: flag,
      source: (jx ?? 0) == 1 ? 'jx' : 'parse',
    );
    // 解析结果应当是真实媒体地址（m3u8/mp4/dash…，§12.3「解析结果必须校验媒体
    // 类型」）。若解析器返回的是另一个待解析目标（对齐 Android
    // `Result.needParse()` 反向语义），判为循环（超限），不得无限嗅探（§12.3）。
    if (!looksLikeMediaUrl(outcome.url)) {
      throw AppError(
        AppErrorKind.parseInvalid,
        '解析结果不是媒体地址，疑似循环解析（最多 1 层）',
        detail: 'url=${redactUrl(outcome.url)}',
      );
    }
    return PlaybackDecision(
      action: PlaybackAction.direct,
      url: outcome.url,
      headers: outcome.headers.isEmpty ? null : HeaderMap(outcome.headers),
      format: outcome.format,
      flag: flag,
      reason: 'parsed-by:${outcome.entryName}',
      subs: outcome.subs,
      danmaku: outcome.danmaku,
    );
  }

  /// 解析详情里的多线路/多剧集（§8.3、§8.4）。
  static List<VodPlayLine> playLinesOf(Vod vod) =>
      parsePlayLines(vod.vodPlayFrom, vod.vodPlayUrl);

  static String _toJsonText(Map<Object?, Object?> value) {
    final buffer = StringBuffer('{');
    var first = true;
    for (final entry in value.entries) {
      if (!first) buffer.write(',');
      first = false;
      buffer
        ..write('"${entry.key}"')
        ..write(':')
        ..write(_encodeValue(entry.value));
    }
    buffer.write('}');
    return buffer.toString();
  }

  static String _encodeValue(Object? value) {
    if (value == null) return 'null';
    if (value is num || value is bool) return '$value';
    if (value is List) {
      return '[${value.map(_encodeValue).join(',')}]';
    }
    if (value is Map) return _toJsonText(value.cast<Object?, Object?>());
    // 站点文本统一按 JSON 字符串编码，避免手工拼接破坏转义。
    return _jsonString('$value');
  }

  static String _jsonString(String value) {
    final buffer = StringBuffer('"');
    for (final rune in value.runes) {
      switch (rune) {
        case 0x22:
          buffer.write(r'\"');
        case 0x5C:
          buffer.write(r'\\');
        case 0x0A:
          buffer.write(r'\n');
        case 0x0D:
          buffer.write(r'\r');
        case 0x09:
          buffer.write(r'\t');
        default:
          if (rune < 0x20) {
            buffer.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
          } else {
            buffer.writeCharCode(rune);
          }
      }
    }
    buffer.write('"');
    return buffer.toString();
  }
}
