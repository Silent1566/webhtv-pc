/// 解析器运行时服务（设计文档 §12「解析器设计」、§7.4.8）。
///
/// 网络执行层：按 [ParseKind] 构造请求并归一化结果，对齐 Android ParseJob。
/// 网络层使用 package:http（与 http_api.dart 一致），避免 dart:io 二进制 API
/// 的签名分叉；type=0/4 依赖 lib/core/sniff/ 的浏览器嗅探内核。
///
/// | type | 请求形态（对齐 Android） | 响应解析 |
/// |---|---|---|
/// | 0 (webSniff) | 用本机浏览器打开「解析器url + 目标」，注入站点 click 与
///   config.rules，等第一个媒体请求 | 第一个 SniffCandidate |
/// | 1 (json) | GET 解析器url + 目标url，带解析器 Header | {url} 或
///   {data:{url}}（可能附带 UA/Referer/Cookie header，§8.4 Header 注入） |
/// | 2 (jsonExtend) | POST 表单，携带全部 type=1 解析器 extUrl() 为查找表 | 完整
///   Result（url/header/subs…，§8.3） |
/// | 3 (jsonMix) | POST 表单，携带 flag 与全部解析器 name->{type,ext,url} | 完整
///   Result |
/// | 4 (superParse) | type=1 解析器并发 + type=0 解析器按优先级串行，第一个
///   成功即胜出 | 胜出者的结果（parseKind 标明是哪一类赢的） |
///
/// 超时、大小上限、编码兜底、错误归一化在这里完成；**解析失败不影响直接换源**
/// （§12.3：由调用方捕获错误后回退）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:http/http.dart' as http;

import '../core/app_error.dart';
import '../core/danmaku.dart';
import '../core/http_api.dart';
import '../core/parse_failover.dart';
import '../core/parse_runtime.dart';
import '../core/protocol.dart';
import '../core/sniff/sniff_engine_factory.dart';
import '../core/sniff/sniff_types.dart';

/// 解析器执行结果。
class ParseRunResult {
  const ParseRunResult({
    required this.url,
    required this.headers,
    required this.parseKind,
    required this.source,
    required this.entryName,
    this.format,
    this.subs = const [],
    this.danmaku = const [],
    this.latency = Duration.zero,
  });

  final String url;
  final Map<String, String> headers;

  /// 实际执行的解析器类型。
  ///
  /// type=4（Super）时是**胜出那一条**的类型（webSniff 或 json）：安卓也是把
  /// 胜出解析器的名字当作 from 上报。
  final ParseKind parseKind;

  /// 来源标记（jx / parse），用于诊断与线路标识（对齐 Result.jxFrom）。
  final String source;

  final String entryName;
  final String? format;
  final List<SubtitleInfo> subs;
  final List<DanmakuSource> danmaku;
  final Duration latency;
}

/// 解析器错误分类（§12.3 解析失败不影响直接换源）。
const Set<AppErrorKind> parseErrorKinds = {
  AppErrorKind.parseNetwork,
  AppErrorKind.parseHttp,
  AppErrorKind.parseDecode,
  AppErrorKind.parseInvalid,
  AppErrorKind.parseEmpty,
  AppErrorKind.parseSniffUnavailable,
  AppErrorKind.parseSniffTimeout,
  AppErrorKind.parseSniffChallenge,
};

/// 判断一个错误是否为解析器错误。
bool isParseError(Object? error) =>
    error is AppError && parseErrorKinds.contains(error.kind);

/// 解析轨迹的输出端（由应用启动时接到 `LogService(scope: 'parse')`）。
typedef ParseTraceSink = void Function(String line);

ParseTraceSink? _traceSink;
ParseTraceSink? _verboseSink;

/// 安装解析轨迹输出端。
///
/// 两层：`trace` 是**永远记录**的骨架（哪个解析源、什么目标、结果/失败），
/// `verbose` 受「详细调试日志」开关控制（逐请求的 HTTP 细节、嗅探事件）。
/// 解析失败时用户唯一能自救的信息就是这两层——不记录等于把定位成本推给人。
void installParseTrace({ParseTraceSink? trace, ParseTraceSink? verbose}) {
  _traceSink = trace;
  _verboseSink = verbose;
}

void _trace(String line) => _traceSink?.call(line);
void _verbose(String line) => _verboseSink?.call(line);

/// 日志里的 Header 只留键名：Cookie/Token 的值绝不能进日志（§12.3）。
String _headerKeysForLog(Map<String, String> headers) =>
    headers.isEmpty ? '[]' : '[${headers.keys.join(", ")}]';

/// 解析器运行时。
class ParseService {
  ParseService({
    http.Client? client,
    this.sniffEngine,
    this.maxBytes = 8 * 1024 * 1024,
    this.timeout = siteRequestTimeout,
    this.jsonParseTimeout = SniffTimeouts.parseDefault,
    this.userAgent = 'WebHTV-PC/0.1 (Windows)',
    this.webSniffTimeout = SniffTimeouts.parseWeb,
    this.superParseTimeout = SniffTimeouts.parseSuper,
    this.superWebAttemptTimeout = SniffTimeouts.superWebAttempt,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// 注入的嗅探引擎；为 null 时用进程共享引擎（sharedSniffEngine）。
  final SniffEngine? sniffEngine;

  final int maxBytes;

  /// 站点接口请求预算（沿用 `siteRequestTimeout` = 180s）。
  ///
  /// **解析器请求不使用它**：`type=1/2/3` 的上限是 [jsonParseTimeout]。保留这个
  /// 字段只为不改变既有构造契约（站点侧的超时由 `HttpApiClient` 持有）。
  final Duration timeout;

  /// `type=1/2/3` 解析器请求上限（默认 [SniffTimeouts.parseDefault] = 15s）。
  ///
  /// 对齐安卓 `Constant.TIMEOUT_PARSE_DEF`：解析器服务是「返回一个地址」的轻量
  /// 接口，15s 已经足够；用站点预算（180s）等它会把播放卡到用户以为死机。
  /// **只作用于解析器请求**，不改变 [timeout] / `siteRequestTimeout`。
  final Duration jsonParseTimeout;
  final String userAgent;

  /// type=0 单次嗅探上限（默认 SniffTimeouts.parseWeb = 30s）。
  final Duration webSniffTimeout;

  /// type=4 整体上限（默认 SniffTimeouts.parseSuper = 90s）。
  final Duration superParseTimeout;

  /// Super 内单次 Web 嗅探上限（默认 SniffTimeouts.superWebAttempt = 25s）。
  final Duration superWebAttemptTimeout;

  void close() => _client.close();

  /// 执行一次解析。
  ///
  /// [selection] 为 [ParseRuntime.select] 的产物；[webUrl] 为播放结果的
  /// playUrl（尚未解析时是剧集目标）；[flag] 为线路标识（type=3 携带）。
  /// [entries] 为配置的**全部**解析器：type=2/3 需要做查找表（对齐 Android
  /// jsonExt/jsonExtMix 传 VodConfig.get().getParses()），type=4 需要从中挑出
  /// 全部 type=0/1 解析器。
  Future<ParseRunResult> run({
    required ParseSelection selection,
    required List<ParseEntry> entries,
    required String webUrl,
    String? flag,
    String? source,
  }) => _execute(
    selection: selection,
    entries: entries,
    webUrl: webUrl,
    flag: flag,
    source: source,
    sniff: const _SniffContext(),
  );

  /// 执行一次解析；[selection] 失败且启用失败切换时，按配置顺序尝试其他接口。
  ///
  /// - 只对「解析类错误」重试（网络/HTTP/解码/非法/空结果/嗅探不可用与超时）；
  /// - 非解析错误（例如调用方 bug）立即上抛，不做无意义重试；
  /// - 全部失败时抛出**最后一个**错误，保留可诊断原因。
  ///
  /// [sniffClick] / [sniffRules] / [revealWindow] 是 type=0/4 的站点上下文
  /// （对齐安卓 ParseJob.setParse：parse.setClick(getClick(result)) 与
  /// config.rules）。JSON 类解析器不需要它们。
  Future<ParseRunResult> runWithFallback({
    required ParseSelection selection,
    required List<ParseEntry> entries,
    required String webUrl,
    String? flag,
    String? source,
    ParseFailoverSettings failover = const ParseFailoverSettings.defaults(),
    String? sniffClick,
    List<Object?> sniffRules = const [],
    bool revealWindow = true,
  }) async {
    final sniff = _SniffContext(
      click: sniffClick,
      rules: SniffRule.fromConfig(sniffRules),
      revealWindow: revealWindow,
    );
    final attempts = [
      selection,
      ...parseFailoverSelections(
        primary: selection,
        entries: entries,
        settings: failover,
      ),
    ];
    if (attempts.length > 1) {
      _trace(
        '解析回退候选=${attempts.map((attempt) => attempt.entry.name).join(" → ")}',
      );
    }
    Object? lastError;
    for (var index = 0; index < attempts.length; index++) {
      final attempt = attempts[index];
      try {
        return await _attempt(
          selection: attempt,
          entries: entries,
          webUrl: webUrl,
          flag: flag,
          source: source,
          sniff: sniff,
        );
      } catch (error) {
        lastError = error;
        final retryable = isParseError(error);
        if (!retryable || index == attempts.length - 1) rethrow;
      }
    }
    // 理论上不可达；保留以免静态分析认为缺返回值。
    throw lastError is AppError
        ? lastError
        : AppError(AppErrorKind.parseInvalid, '解析失败：$lastError');
  }

  /// 单次尝试。
  ///
  /// 没有站点嗅探上下文时走 [run]：run 是既有的可替换点（测试替身靠它观察
  /// 调用序列与行为），不得绕过。带上下文（click/rules）时由本层直接执行，
  /// 因为 [run] 的签名要保持向后兼容，装不下这两项。
  Future<ParseRunResult> _attempt({
    required ParseSelection selection,
    required List<ParseEntry> entries,
    required String webUrl,
    String? flag,
    String? source,
    required _SniffContext sniff,
  }) {
    if (sniff.isDefault) {
      return run(
        selection: selection,
        entries: entries,
        webUrl: webUrl,
        flag: flag,
        source: source,
      );
    }
    return _execute(
      selection: selection,
      entries: entries,
      webUrl: webUrl,
      flag: flag,
      source: source,
      sniff: sniff,
    );
  }

  Future<ParseRunResult> _execute({
    required ParseSelection selection,
    required List<ParseEntry> entries,
    required String webUrl,
    String? flag,
    String? source,
    required _SniffContext sniff,
  }) async {
    final stopwatch = Stopwatch()..start();
    final url = selection.entry.url?.trim() ?? '';
    _trace(
      '解析源=${selection.entry.name} type=${selection.entry.type} '
      '连接=${redactUrl(url)} 目标=${redactUrl(webUrl)} '
      'flag=${flag ?? "-"} 来源=${source ?? "-"}',
    );
    if (url.isEmpty && _requiresUrl(selection.kind)) {
      throw AppError(
        AppErrorKind.parseInvalid,
        '解析器 ${selection.entry.name} 未配置 url',
      );
    }

    try {
      final result = await _dispatch(selection, url, webUrl, flag, entries, stopwatch, sniff);
      _trace(
        '解析成功 源=${selection.entry.name} 地址=${redactUrl(result.url)} '
        '格式=${result.format ?? "?"} 耗时=${result.latency.inMilliseconds}ms',
      );
      return result;
    } on AppError catch (error) {
      _trace(
        '解析失败 源=${selection.entry.name} kind=${error.kind.name} '
        'message=${error.message} detail=${error.detail ?? "-"} '
        '耗时=${stopwatch.elapsedMilliseconds}ms',
      );
      rethrow;
    }
  }

  Future<ParseRunResult> _dispatch(
    ParseSelection selection,
    String url,
    String webUrl,
    String? flag,
    List<ParseEntry> entries,
    Stopwatch stopwatch,
    _SniffContext sniff,
  ) async {
    switch (selection.kind) {
      case ParseKind.json:
        return _jsonParse(url, webUrl, selection, stopwatch);
      case ParseKind.jsonExtend:
        return _jsonExtend(url, webUrl, entries, selection, stopwatch);
      case ParseKind.jsonMix:
        return _jsonMix(url, webUrl, flag, entries, selection, stopwatch);
      case ParseKind.webSniff:
        return _webSniff(url, webUrl, selection, stopwatch, sniff: sniff);
      case ParseKind.superParse:
        return _superParse(entries, webUrl, selection, stopwatch, sniff: sniff);
      case ParseKind.unknown:
        throw AppError(
          AppErrorKind.parseUnsupportedType,
          '解析器 ${selection.entry.name} 的类型未知'
          '（type=${selection.entry.type}），无法执行；已知类型：$knownParseKinds',
        );
    }
  }

  /// 哪些类型必须有 url。
  ///
  /// type=0 允许空 url（安卓 Parse.get(0, playUrl) 就是「直接嗅探目标页」）；
  /// type=4 不需要 url（安卓 Parse.god() 就是 type=4 + 空 url，由 Super 自己按
  /// 解析器分发）。
  static bool _requiresUrl(ParseKind kind) => switch (kind) {
    ParseKind.json || ParseKind.jsonExtend || ParseKind.jsonMix => true,
    ParseKind.webSniff || ParseKind.superParse || ParseKind.unknown => false,
  };

  /// 取嗅探引擎；本机不可用时如实报错，不静默降级（§12.3）。
  SniffEngine _engineFor(ParseEntry entry) {
    final engine = sniffEngine ?? sharedSniffEngine();
    if (engine != null) return engine;
    throw AppError(
      AppErrorKind.parseSniffUnavailable,
      '解析器 ${entry.name} 需要 Web 嗅探，但本机没有可用的浏览器内核',
      detail:
          'type=0/4 依赖 Chromium 内核浏览器（Microsoft Edge / Google Chrome / '
          'Chromium）；安装任一浏览器，或用 WEBHTV_SNIFF_BROWSER 指定浏览器路径',
    );
  }

  /// type=0：用一个浏览器会话打开解析页，等第一个媒体请求（对齐 startWeb）。
  Future<ParseRunResult> _webSniff(
    String parseUrl,
    String webUrl,
    ParseSelection selection,
    Stopwatch stopwatch, {
    required _SniffContext sniff,
    Duration? attemptTimeout,
    _SuperRace? race,
  }) async {
    final engine = _engineFor(selection.entry);
    final pageUrl = '${parseUrl.trim()}$webUrl'.trim();
    if (pageUrl.isEmpty) {
      throw AppError(
        AppErrorKind.parseInvalid,
        '解析器 ${selection.entry.name} 没有可嗅探的页面地址',
      );
    }
    final budget = attemptTimeout ?? webSniffTimeout;
    final request = SniffRequest(
      pageUrl: pageUrl,
      timeout: budget,
      // 安卓 Parse.setHeader：解析器 ext.header（UA/Referer/Cookie）落到页面请求上。
      headers: _parseEntryHeaders(selection.entry),
      clickScript: sniff.click,
      rules: sniff.rules,
      revealWindow: sniff.revealWindow,
      source: 'parse:${selection.entry.name}',
    );
    final attempt = _SniffAttempt(race);
    _verbose(
      '嗅探 源=${selection.entry.name} 页面=${redactLogText(pageUrl)} '
      '超时=${budget.inSeconds}s 无头=${!request.revealWindow ? "是" : "否"}',
    );
    try {
      final result = await _sniffOnce(engine, request, attempt, budget);
      _verbose(
        '嗅探命中 源=${selection.entry.name} via=${result.via} '
        '地址=${redactUrl(result.url)}',
      );
      return ParseRunResult(
        url: result.url,
        headers: sniffHeadersOf(result.headers),
        parseKind: ParseKind.webSniff,
        source: 'parse:${selection.entry.name}',
        entryName: selection.entry.name,
        latency: stopwatch.elapsed,
      );
    } finally {
      // §12.3：任何路径（成功/超时/失败/被竞速取消）都必须停止会话，
      // 不得泄漏浏览器进程。
      await attempt.stop();
    }
  }

  Future<SniffResult> _sniffOnce(
    SniffEngine engine,
    SniffRequest request,
    _SniffAttempt attempt,
    Duration budget,
  ) async {
    final SniffSession session;
    try {
      session = await engine.start(request);
    } on SniffUnavailableException catch (error) {
      throw AppError(
        AppErrorKind.parseSniffUnavailable,
        error.message,
        detail: error.detail,
        cause: error,
      );
    } on SniffException catch (error) {
      throw AppError(
        AppErrorKind.parseInvalid,
        '解析页启动失败：${error.message}',
        detail: error.detail,
        cause: error,
      );
    } catch (error) {
      throw AppError(AppErrorKind.parseInvalid, '解析页启动失败：$error', cause: error);
    }
    attempt.bind(session);
    if (attempt.cancelled) throw const _SniffAborted();
    return _awaitCandidate(
      session,
      attempt,
      budget,
      revealWindow: request.revealWindow,
    );
  }

  /// 等第一个 [SniffCandidate]。
  ///
  /// 超时由本层拥有（不依赖引擎守时）：SniffRequest.timeout 只是给引擎的提示，
  /// 引擎卡死时必须仍能结束解析。
  Future<SniffResult> _awaitCandidate(
    SniffSession session,
    _SniffAttempt attempt,
    Duration budget, {
    required bool revealWindow,
  }) {
    final completer = Completer<SniffResult>();
    Timer? timer;
    late final StreamSubscription<SniffEvent> subscription;

    void succeed(SniffResult result) {
      if (completer.isCompleted) return;
      timer?.cancel();
      completer.complete(result);
    }

    void fail(Object error) {
      if (completer.isCompleted) return;
      timer?.cancel();
      completer.completeError(error);
    }

    timer = Timer(
      budget,
      () => fail(
        AppError(
          AppErrorKind.parseSniffTimeout,
          '解析页嗅探超时（${budget.inSeconds}s）',
          detail: 'type=0/4 的解析页必须在限定时间内产出媒体请求',
        ),
      ),
    );
    subscription = session.events.listen(
      (event) {
        switch (event) {
          case SniffCandidate(:final url, :final headers, :final via):
            succeed(SniffResult(url: url, headers: headers, via: via));
          case SniffFailed(:final message, :final detail):
            fail(
              AppError(
                AppErrorKind.parseInvalid,
                '解析页执行失败：$message',
                detail: detail,
              ),
            );
          case SniffChallenge(:final reason):
            // 无头会话拿不出窗口：硬等到 180s 超时只会把「能力缺失」伪装成
            // 「网站太慢」，这里立刻如实失败，让用户去开可见模式或换源。
            if (!revealWindow || !session.canReveal) {
              fail(
                AppError(
                  AppErrorKind.parseSniffChallenge,
                  session.canReveal
                      ? '解析页需要人机校验，但当前不允许弹出窗口'
                      : '解析页需要人机校验，而当前是无头嗅探（未开启可见窗口）',
                  detail: 'reason=${reason ?? "未提供"}；'
                      '处理=设置 WEBHTV_SNIFF_HEADED=1 后重试，或换一条线路',
                ),
              );
            } else {
              // 拉到前台让用户完成校验，然后继续等候选（不结束本次嗅探）。
              unawaited(_revealQuietly(session));
            }
          case SniffPageLoaded():
            break;
        }
      },
      onError: (Object error) {
        fail(
          AppError(AppErrorKind.parseInvalid, '解析页嗅探失败：$error', cause: error),
        );
      },
      onDone: () {
        fail(
          attempt.cancelled
              ? const _SniffAborted()
              : AppError(
                  AppErrorKind.parseInvalid,
                  '解析页没有产出媒体地址（页面可能不是播放页，或解析器已失效）',
                ),
        );
      },
      cancelOnError: false,
    );
    return completer.future.whenComplete(() {
      timer?.cancel();
      unawaited(subscription.cancel());
    });
  }

  static Future<void> _revealQuietly(SniffSession session) async {
    try {
      await session.reveal();
    } catch (_) {
      // 弹窗失败不结束本次嗅探：仍可能靠页面自身脚本产出地址。
    }
  }

  /// type=4：type=1 并发 + type=0 按优先级串行，第一个成功即胜出
  /// （对齐 ParseJob.superParse）。
  Future<ParseRunResult> _superParse(
    List<ParseEntry> entries,
    String webUrl,
    ParseSelection selection,
    Stopwatch stopwatch, {
    required _SniffContext sniff,
  }) async {
    final webs = orderedSuperParseWebs(entries);
    final jsons = entries
        .where((entry) => parseKindOf(entry.type) == ParseKind.json)
        .where((entry) => (entry.url?.trim() ?? '').isNotEmpty)
        .toList();
    if (webs.isEmpty && jsons.isEmpty) {
      throw AppError(
        AppErrorKind.parseEmpty,
        '超级解析（type=4，${selection.entry.name}）没有可用的解析器：'
        '配置里既没有可用的 type=1 也没有 type=0',
      );
    }
    final target = unwrapSuperParseUrl(webUrl, webs);
    _trace(
      '超级解析 腿 JSON=[${jsons.map((entry) => entry.name).join(", ")}] '
      'Web=[${webs.map((entry) => entry.name).join(", ")}] '
      '目标=${redactUrl(target)} '
      '连接=[${[...jsons, ...webs].map((entry) => redactUrl(entry.url)).join(", ")}]',
    );
    final race = _SuperRace();
    final completer = Completer<ParseRunResult>();
    Object? lastError;
    var pending = webs.length + jsons.length;

    void settleError(Object error) {
      lastError = error;
      pending--;
      if (pending <= 0 && !completer.isCompleted) {
        completer.completeError(lastError!);
      }
    }

    void settleResult(ParseRunResult result) {
      if (completer.isCompleted) return;
      _trace(
        '超级解析胜出 源=${result.entryName} 地址=${redactUrl(result.url)} '
        '耗时=${result.latency.inMilliseconds}ms',
      );
      completer.complete(result);
    }

    // type=1：并发。安卓 jsonParse(item, targetUrl, false) 的 fatal=false 语义
    // 在这里体现为「单条失败只记错误，不判整体失败」。
    for (final entry in jsons) {
      final legSelection = ParseSelection(entry: entry, kind: ParseKind.json);
      unawaited(() async {
        try {
          settleResult(
            await _jsonParse(
              entry.url!.trim(),
              target,
              legSelection,
              stopwatch,
            ),
          );
        } catch (error) {
          settleError(error);
        }
      }());
    }

    // type=0：按优先级串行，每条有独立的尝试上限（superWebAttempt）。
    unawaited(() async {
      for (final entry in webs) {
        if (completer.isCompleted) return;
        final legSelection = ParseSelection(
          entry: entry,
          kind: ParseKind.webSniff,
        );
        try {
          settleResult(
            await _webSniff(
              entry.url?.trim() ?? '',
              target,
              legSelection,
              stopwatch,
              sniff: sniff,
              attemptTimeout: superWebAttemptTimeout,
              race: race,
            ),
          );
          return;
        } catch (error) {
          settleError(error);
        }
      }
    }());

    final timer = Timer(superParseTimeout, () {
      if (completer.isCompleted) return;
      completer.completeError(
        AppError(
          AppErrorKind.parseSniffTimeout,
          '超级解析超时（${superParseTimeout.inSeconds}s）',
          detail: '解析器=${selection.entry.name} 目标=${redactUrl(webUrl)}',
        ),
      );
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      // 胜出即取消其它尝试：落后的浏览器会话必须立刻停止。
      await race.abort();
    }
  }

  /// type=1：`GET 解析器url + 目标url`（对齐 `jsonParse`）。
  Future<ParseRunResult> _jsonParse(
    String parseUrl,
    String webUrl,
    ParseSelection selection,
    Stopwatch stopwatch,
  ) async {
    final target = (parseUrl + webUrl).trim();
    final payload = await _getText(target, selection.entry);
    final decoded = jsonDecodeLoose(payload);
    if (decoded is! Map) {
      throw AppError(
        AppErrorKind.parseInvalid,
        '解析器 ${selection.entry.name} 响应不是 JSON 对象',
        detail: _hint(payload),
      );
    }
    final map = decoded;

    // `url` 或 `data.url`。
    final url = asNonEmptyString(map['url']) ?? _nestedUrl(map['data']);
    if (url == null) {
      throw AppError(
        AppErrorKind.parseEmpty,
        '解析器 ${selection.entry.name} 没有返回可用地址',
        detail: _hint(payload),
      );
    }

    // 响应顶层可能带 UA/Referer/Cookie（对齐 `getHeader`）。
    final headers = _headersFromMap(map, selection.entry);
    return ParseRunResult(
      url: url,
      headers: headers,
      parseKind: ParseKind.json,
      source: 'parse:${selection.entry.name}',
      entryName: selection.entry.name,
      format: asNonEmptyString(map['format']),
      subs: SubtitleInfo.listFromJson(map['subs']),
      danmaku: danmakuSourcesFromJson(map['danmaku']),
      latency: stopwatch.elapsed,
    );
  }

  /// type=2：POST 表单，携带全部 type=1 解析器 `extUrl()`（对齐 `jsonExt`）。
  Future<ParseRunResult> _jsonExtend(
    String parseUrl,
    String webUrl,
    List<ParseEntry> entries,
    ParseSelection selection,
    Stopwatch stopwatch,
  ) async {
    final jxs = <String, String>{};
    for (final entry in entries) {
      if (parseKindOf(entry.type) == ParseKind.json && entry.url != null) {
        jxs[entry.name] = _extUrl(entry);
      }
    }
    final payload = await _postText(parseUrl, selection.entry, jxs, webUrl);
    return _toResult(
      payload,
      selection,
      'jx:${selection.entry.name}',
      stopwatch,
    );
  }

  /// type=3：POST 表单，携带 flag 与全部解析器 `name->{type,ext,url}`（对齐
  /// `jsonExtMix`）。
  Future<ParseRunResult> _jsonMix(
    String parseUrl,
    String webUrl,
    String? flag,
    List<ParseEntry> entries,
    ParseSelection selection,
    Stopwatch stopwatch,
  ) async {
    final jxs = <String, Map<String, Object?>>{};
    for (final entry in entries) {
      jxs[entry.name] = {
        'type': '${entry.type}',
        'ext': entry.ext ?? const {},
        'url': entry.url ?? '',
      };
    }
    final payload = await _postText(parseUrl, selection.entry, {
      'jx': flag ?? '',
      'name': selection.entry.name,
      'ext': jsonEncode(jxs),
    }, webUrl);
    return _toResult(
      payload,
      selection,
      'jx:${selection.entry.name}',
      stopwatch,
    );
  }

  /// type=2/3 响应是完整 `Result`（§8.3），复用 [HttpApiResponseParser] 归一化。
  ParseRunResult _toResult(
    String payload,
    ParseSelection selection,
    String source,
    Stopwatch stopwatch,
  ) {
    final result = HttpApiResponseParser.parse(
      payload,
      siteKey: 'parse:${selection.entry.name}',
    );
    final url = result.playUrl;
    if (url == null || url.isEmpty) {
      throw AppError(
        AppErrorKind.parseEmpty,
        '解析器 ${selection.entry.name} 没有返回可用地址',
        detail: _hint(payload),
      );
    }
    return ParseRunResult(
      url: url,
      headers: result.header?.asRequestHeaders ?? const {},
      parseKind: selection.kind,
      source: source,
      entryName: selection.entry.name,
      format: result.format,
      subs: result.subs,
      danmaku: result.danmaku,
      latency: stopwatch.elapsed,
    );
  }

  /// Android `Parse.extUrl()`：url 带 query 时注入 `cat_ext=<base64>`。
  String _extUrl(ParseEntry entry) {
    final url = entry.url?.trim() ?? '';
    final ext = entry.ext;
    if (ext == null) return url;
    final index = url.indexOf('?');
    if (index == -1) return url;
    final encoded = base64UrlEncode(jsonEncode(ext));
    return '${url.substring(0, index + 1)}cat_ext=$encoded&'
        '${url.substring(index + 1)}';
  }

  /// 响应顶层带响应的 UA/Referer/Cookie（对齐 `getHeader`），否则用解析器自身。
  Map<String, String> _headersFromMap(Map map, ParseEntry fallback) {
    final result = HeaderMap(asMap(map['header'])).asRequestHeaders;
    for (final key in <String>['User-Agent', 'Referer', 'Cookie', 'ua']) {
      final value = asNonEmptyString(map[key]);
      if (value != null) result[key] = value;
    }
    if (result.isNotEmpty) return result;
    return _parseEntryHeaders(fallback);
  }

  Map<String, String> _parseEntryHeaders(ParseEntry entry) {
    final ext = entry.ext;
    if (ext is Map) {
      final header = ext['header'];
      if (header is Map) {
        final result = <String, String>{};
        for (final entry in header.entries) {
          if (entry.value is String) {
            result['${entry.key}'] = entry.value as String;
          }
        }
        return result;
      }
    }
    return const {};
  }

  static String? _nestedUrl(Object? data) {
    if (data is! Map) return null;
    return asNonEmptyString(data['url']);
  }

  String _hint(String payload) {
    final trimmed = payload.trim();
    return trimmed.length > 120 ? '${trimmed.substring(0, 120)}…' : trimmed;
  }

  Future<String> _getText(String url, ParseEntry entry) =>
      _exchange(url, entry, method: 'GET').then((body) => body.text);

  Future<String> _postText(
    String url,
    ParseEntry entry,
    Map<String, Object?> form,
    String webUrl,
  ) => _exchange(
    url,
    entry,
    method: 'POST',
    form: form,
    webUrl: webUrl,
  ).then((body) => body.text);

  Future<_Body> _exchange(
    String url,
    ParseEntry entry, {
    required String method,
    Map<String, Object?>? form,
    String? webUrl,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw AppError(AppErrorKind.parseInvalid, '解析器地址非法：$url');
    }
    final headers = _requestHeaders(entry);
    final requestWatch = Stopwatch()..start();
    _verbose(
      'HTTP $method 源=${entry.name} 连接=${redactLogText(uri.toString())} '
      'Header=${_headerKeysForLog(headers)}',
    );
    final http.Response response;
    try {
      if (method == 'POST') {
        final body = _formBody(entry, form, webUrl);
        // §12.2：解析器表单必须是 form-urlencoded（对齐 Android
        // `OkHttp.toBody`）；`package:http` 默认 text/plain，会错过解析器解析。
        final formHeaders = {
          ...headers,
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
        };
        response = await _client
            .post(uri, headers: formHeaders, body: body)
            .timeout(jsonParseTimeout);
      } else {
        response = await _client
            .get(uri, headers: headers)
            .timeout(jsonParseTimeout);
      }
    } on TimeoutException catch (error) {
      throw AppError(
        AppErrorKind.parseNetwork,
        '解析器请求超时（${jsonParseTimeout.inSeconds}s）',
        detail: redactUrl(uri.toString()),
        retryable: true,
        cause: error,
      );
    } catch (error) {
      throw AppError(
        AppErrorKind.parseNetwork,
        '解析器请求失败：DNS 或连接失败',
        detail: redactUrl(uri.toString()),
        retryable: true,
        cause: error,
      );
    }

    _verbose(
      'HTTP ${response.statusCode} 源=${entry.name} '
      '字节=${response.bodyBytes.length} 耗时=${requestWatch.elapsedMilliseconds}ms',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppError(
        AppErrorKind.parseHttp,
        '解析器请求返回 HTTP ${response.statusCode}',
        detail: redactUrl(uri.toString()),
        statusCode: response.statusCode,
        retryable: response.statusCode >= 500,
      );
    }
    if (response.bodyBytes.length > maxBytes) {
      throw AppError(
        AppErrorKind.parseInvalid,
        '解析响应超过大小上限（${maxBytes ~/ (1024 * 1024)} MiB）',
        detail: redactUrl(uri.toString()),
      );
    }
    return _Body(text: _decodeResponse(response));
  }

  /// 解析器 Header：`ext.header` + 缺 UA 时补默认（对齐 Android
  /// `Parse.Ext.header`）。
  Map<String, String> _requestHeaders(ParseEntry entry) {
    final result = <String, String>{};
    for (final headerEntry in _parseEntryHeaders(entry).entries) {
      result[headerEntry.key] = headerEntry.value;
    }
    if (!result.keys.any((key) => key.toLowerCase() == 'user-agent')) {
      result['User-Agent'] = userAgent;
    }
    return result;
  }

  /// POST 表单体（§7.4.7 同语义：URL 编码键值；webUrl 追加 `url=`）。
  String _formBody(
    ParseEntry entry,
    Map<String, Object?>? form,
    String? webUrl,
  ) {
    final pairs = <String>[];
    for (final item in (form ?? const {}).entries) {
      pairs.add(
        '${Uri.encodeQueryComponent(item.key)}='
        '${Uri.encodeQueryComponent(_formValue(item.value))}',
      );
    }
    if (webUrl != null) {
      pairs.add('url=${Uri.encodeQueryComponent(webUrl)}');
    }
    return pairs.join('&');
  }

  /// 响应解码：声明 charset → UTF-8 → GBK 兜底（与 http_api 同规则）。
  String _decodeResponse(http.Response response) {
    final contentType = response.headers['content-type'];
    final declared = RegExp(
      r'''charset\s*=\s*"?([\w\-]+)"?''',
      caseSensitive: false,
    ).firstMatch(contentType ?? '')?.group(1);
    final bytes = response.bodyBytes;
    if (declared != null) {
      final charset = declared.toLowerCase();
      if (charset.startsWith('gb')) {
        try {
          return gbk.decode(bytes, allowMalformed: false);
        } on FormatException {
          // 落到下方 UTF-8 判定。
        }
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      try {
        return gbk.decode(bytes, allowMalformed: true);
      } on FormatException {
        throw AppError(
          AppErrorKind.parseDecode,
          '解析响应无法按 UTF-8 或 GBK 解码',
          detail: 'charset=${declared ?? "未声明"}',
        );
      }
    }
  }

  static String _formValue(Object? value) {
    if (value is String) return value;
    if (value is num) return '$value';
    if (value is bool) return '$value';
    return jsonEncode(value);
  }
}

class _Body {
  const _Body({required this.text});
  final String text;
}

/// 宽松 JSON 解码（顶层数组也接受，返回原结构）。
Object? jsonDecodeLoose(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

/// URL-safe base64（对齐 Android `Util.base64(..., URL_SAFE)`）。
String base64UrlEncode(String input) {
  final encoded = base64.encode(utf8.encode(input));
  return encoded.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

/// Super 里 type=0 解析器的尝试顺序（对齐安卓 ParseJob.superParsePriority）。
///
/// 虾米播放器（xmflv.com）会直接发出 HLS 请求，命中率最高；m3u8.tv 只是外层
/// iframe，注入不到子框架，放到最后。其余解析器保持配置顺序（稳定排序）。
List<ParseEntry> orderedSuperParseWebs(List<ParseEntry> entries) {
  final webs = entries
      .where((entry) => parseKindOf(entry.type) == ParseKind.webSniff)
      .toList(growable: false);
  final indexed = [
    for (var index = 0; index < webs.length; index++)
      (index: index, entry: webs[index]),
  ];
  indexed.sort((a, b) {
    final byPriority = _superWebPriority(a.entry)
        .compareTo(_superWebPriority(b.entry));
    return byPriority != 0 ? byPriority : a.index.compareTo(b.index);
  });
  return [for (final item in indexed) item.entry];
}

int _superWebPriority(ParseEntry entry) {
  final url = (entry.url ?? '').toLowerCase();
  if (url.contains('xmflv.com')) return 0;
  if (url.contains('hls.one')) return 1;
  if (url.contains('m3u8.tv')) return 2;
  return 10;
}

/// 解嵌「解析器套解析器」的目标地址（对齐安卓 ParseJob.unwrapSuperParseUrl）。
///
/// 部分站点把「智能线路」返回成另一个解析接口（例如 bd.jx.cn/?url=腾讯页）。
/// 此时再给 Super 的所有解析器拼前缀，页面脚本会沿错误的目标地址执行。这里
/// 逐层解出真正的播放页：最多 4 层 url=/jx= 参数，且只在整个地址确实像个解析
/// 入口（host 属于已知 type=0 解析器，或路径含 jiexi/parse/jx、以 /api 结尾）
/// 时才解，避免误伤普通站点地址。
String unwrapSuperParseUrl(String webUrl, List<ParseEntry> webs) {
  var current = webUrl.trim();
  final parserHosts = <String>{};
  for (final entry in webs) {
    final host = Uri.tryParse(entry.url?.trim() ?? '')?.host ?? '';
    if (host.isNotEmpty) parserHosts.add(host.toLowerCase());
  }
  for (var depth = 0; depth < 4; depth++) {
    final uri = Uri.tryParse(current);
    if (uri == null) break;
    final host = uri.host.toLowerCase();
    final raw = uri.queryParameters['url'] ?? uri.queryParameters['jx'];
    final inner = (raw ?? '').trim();
    if (inner.isEmpty) break;
    if (!inner.toLowerCase().startsWith('http')) break;
    final knownParserHost = host.isNotEmpty && parserHosts.contains(host);
    if (!knownParserHost && !_isLikelyParserUri(uri)) break;
    if (inner == current) break;
    current = inner;
  }
  return current;
}

bool _isLikelyParserUri(Uri uri) {
  final path = uri.path.toLowerCase();
  return path.contains('jiexi') ||
      path.contains('parse') ||
      path.contains('/jx') ||
      path.endsWith('/api');
}

/// 一次嗅探需要的站点上下文（对齐安卓 ParseJob.setParse 的
/// parse.setClick(getClick(result)) 与 config.rules）。只有 type=0/4 用到。
class _SniffContext {
  const _SniffContext({
    this.click,
    this.rules = const [],
    this.revealWindow = true,
  });

  final String? click;
  final List<SniffRule> rules;
  final bool revealWindow;

  /// 没有站点上下文：这类调用走既有 run() 路径（保持测试替身的可替换点）。
  bool get isDefault => click == null && rules.isEmpty && revealWindow;
}

/// 一次嗅探尝试的句柄：stop() 幂等，任何路径都只停一次会话。
class _SniffAttempt {
  _SniffAttempt(this._race) {
    _race?.track(this);
  }

  final _SuperRace? _race;
  SniffSession? _session;
  bool _stopped = false;

  bool get cancelled => _stopped;

  void bind(SniffSession session) {
    _session = session;
    if (_stopped) unawaited(_stopSession(session));
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _race?.forget(this);
    final session = _session;
    if (session != null) await _stopSession(session);
  }

  static Future<void> _stopSession(SniffSession session) async {
    try {
      await session.stop();
    } catch (_) {
      // 清理失败不得掩盖本次解析的真实结果。
    }
  }
}

/// Super 竞速时登记在跑的所有嗅探尝试，胜出后一次性取消落后的。
class _SuperRace {
  final List<_SniffAttempt> _active = [];
  bool _aborted = false;

  void track(_SniffAttempt attempt) {
    if (_aborted) {
      unawaited(attempt.stop());
      return;
    }
    _active.add(attempt);
  }

  void forget(_SniffAttempt attempt) => _active.remove(attempt);

  Future<void> abort() async {
    _aborted = true;
    for (final attempt in [..._active]) {
      await attempt.stop();
    }
    _active.clear();
  }
}

/// 竞速已结束导致本次尝试被取消：不是解析失败，不上报给调用方。
class _SniffAborted implements Exception {
  const _SniffAborted();

  @override
  String toString() => '嗅探已被取消';
}
