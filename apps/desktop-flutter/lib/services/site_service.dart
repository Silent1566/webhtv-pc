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

    // 站点播放入口回调必须真实参与解析的站点：
    // - `type=3` Spider 站点（含猫源 / JS / PC Java）的剧集目标常是**站点播放入口的
    //   输入**（详情 `vod_play_url` 里该集 `$` 之后的值），而不是可直连的媒体地址。
    //   以网盘线路为例：
    //     episodeTarget = `https://pan.baidu.com/s/...|...|<base64>`
    //   裸 scheme 是 https，若按普通 HTTP API 站点的「直链初判」会把它当成直链直接给
    //   播放器，于是网盘分享页被当 html 流 → `Failed to recognize file format`（实测）。
    //   参考实现（Silent1566/webhtv）对 `type=3` 在 `playerContent` 里**无条件**先调
    //   `/play`（`site.recent().spider().playerContent(flag, id, ...)`），从不做这种短路。
    // - `type=4`（HTTP API + Base64 ext）同理：参考实现在 `playerContent` 里对
    //   `site.getType() == 4` **无条件**用 `play=<剧集目标>&flag=<线路>` 调站点 `api`，
    //   从不先做直链初判。实测 T4 站点（`http://192.168.50.50:3000/video/木偶`）的
    //   剧集目标本身就是**带时效签名的 CDN 直链**，但它只有在播放入口返回的
    //   `header`（如 115 CDN 必需的 `user-agent: Mozilla/5.0 115Browser/…`）下才可取流；
    //   平台型 T4 站点（`movie360`/`iqiyi`/`mgtv`/`youku`）更依赖播放入口的 `parse=1`
    //   才能拿到解析器地址。此前 PC 端把 `type=4` 当普通 HTTP API 站点处理，只对
    //   **站点自身声明的 `playUrl`** 才调播放入口，而 T4 站点的播放入口就是 `api`，
    //   于是**所有** T4 站点都落到「目标不是直链且未声明 playUrl」→
    //   `playbackParserRequired`（用户实测日志：`site=木偶 playbackParserRequired`）。
    //   因此这里对 `type=3`/`type=4` 跳过直链初判，一律先向播放入口取真实地址；普通
    //   HTTP API 站点（`type=0/1/2`）保留原有初判，避免多余网络请求。
    // 注意：SpiderNull / Unsupported 站点的 runtime 会在播放入口如实报错，
    // 不会伪装成直链成功。
    final mustCallPlay =
        site.type == SiteType.spider ||
        site.type == SiteType.jsonApiBase64Ext;

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
      // `type=3` 的剧集目标是**播放入口的输入**（网盘分享页等），不是媒体地址。
      // 播放入口没给出地址时**不得回退到 episodeTarget**——那会把分享页 HTML
      // 交给播放器（`Failed to recognize file format`）。实测上游对部分网盘线路
      // （如夸克）就是返回 `{urls:[], header:{}}`，属**上游没有地址**，应如实报错
      // 以便 UI 引导换源，而不是伪装成可播放。
      // 普通 HTTP API 站点（`type=0/1/2/4`）的 `playUrl` 前缀回退语义不受影响。
      final playTarget = playResult.playUrl;
      if (playTarget == null && mustCallPlay) {
        throw AppError(
          AppErrorKind.playbackUrlMissing,
          '播放入口未返回播放地址',
          detail: '站点=${site.key} 线路=${flag ?? ""} 目标=${redactUrl(episodeTarget)}',
        );
      }
      // 播放入口给了地址但该地址仍不可播（如 `tvb_yunbao` 的「剧情简介」线路回
      // `parse=0` + `url:"vwnet-07cd…"` 这类站点内占位串）。此时 [PlaybackResolver]
      // 会抛「剧集目标不是直链，且站点未声明 playUrl 前缀」——对 `type=4` 这句话是
      // **错的**：T4 根本没有 `playUrl` 概念，播放入口就是 `api` 且已经调过了。
      // 实测该文案把排查方向引向「站点缺 playUrl」（用户报告的同一类困惑）。
      // 因此这里把兜底错误换成**如实描述实际发生了什么**并带上播放入口返回值。
      final resolved = _resolvePlayEntryTarget(
        site: site,
        playResult: playResult,
        playTarget: playTarget,
        episodeTarget: episodeTarget,
        flag: flag,
        globalHeaders: _globalHeaders,
      );
      final failure = resolved.failure;
      if (failure != null) throw failure;
      var decision = resolved.decision;
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

  /// 把播放入口返回值变成播放决策；不可播时给出**如实**的错误。
  ///
  /// 为什么需要它：对 `type=3`/`type=4` 这类「剧集目标必须先送播放入口」的站点，
  /// [PlaybackResolver] 的兜底文案（「站点未声明 playUrl 前缀」）在语义上是错的——
  /// 播放入口**已经调过**，问题由在播放入口返回的东西不可播。用户报告的缺陷正是
  /// 被这类错位文案误导（`site=木偶 playbackParserRequired: 站点 木偶 未声明 playUrl`）。
  _PlayEntryResolution _resolvePlayEntryTarget({
    required Site site,
    required SiteResult playResult,
    required String? playTarget,
    required String episodeTarget,
    String? flag,
    required List<HeaderRule> globalHeaders,
  }) {
    final target = playTarget ?? episodeTarget;
    try {
      return _PlayEntryResolution(
        decision: PlaybackResolver.decide(
          PlaybackResolutionInput(
            site: site,
            episodeTarget: target,
            flag: flag,
            parse: playResult.parse,
            jx: playResult.jx,
            resultHeader: playResult.header,
            globalHeaders: globalHeaders,
            subs: playResult.subs,
            danmaku: playResult.danmaku,
          ),
        ),
      );
    } on AppError catch (error) {
      // 只重写「目标不可播」这一类；解析器/其它分类原样上抛（它们已可定位）。
      if (error.kind != AppErrorKind.playbackParserRequired &&
          error.kind != AppErrorKind.playbackUrlMissing) {
        rethrow;
      }
      final entryField = playTarget != null
          ? '播放入口返回 ${redactUrl(playTarget)}'
          : '播放入口未给出地址，剧集目标 ${redactUrl(episodeTarget)}';
      return _PlayEntryResolution(
        // `decision` 在 failure 非空时不会被使用；这里保留原错误对应的动作以
        // 避免引入无意义的占位值。
        decision: PlaybackDecision(
          action: error.kind == AppErrorKind.playbackUrlMissing
              ? PlaybackAction.direct
              : PlaybackAction.needParser,
        ),
        failure: AppError(
          AppErrorKind.playbackParserRequired,
          '播放入口返回的目标不是可播放地址',
          detail: '站点=${site.key} 线路=${flag ?? ""} $entryField',
        ),
      );
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

/// 播放入口返回值的解析结果：要么是可用决策，要么是**如实**的失败。
class _PlayEntryResolution {
  const _PlayEntryResolution({required this.decision, this.failure});

  final PlaybackDecision decision;

  /// 非空表示播放入口返回的目标不可播；调用方必须上抛，不得继续使用 [decision]。
  final AppError? failure;
}
