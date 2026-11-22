/// 弹幕库搜索客户端（`docs/phase9/design/02` §2.3）。
///
/// 两套协议并存，因为用户真实在用的弹幕源是 huangxd-/danmu_api 一类中转，
/// 而本仓库早期按自建 HTTP 源实现：
/// 1. FongMi/TVBox 弹幕中转（与安卓 `DanmakuApi` 同款）：
///    `POST <apiUrl|apiUrl/danmaku>`，表单 `name=<片名>&episode=<集名>`，
///    响应是弹幕源数组 `[{name,url,...}]`（中文名形如「片名 - 集名」）；
///    地址里带 `{name}`/`{episode}` 占位符时改走 GET 直接替换。
/// 2. 旧通用契约兜底：`GET <apiUrl>?title=&episode=`，响应
///    `{"code":0,"data":[{"id","title","episode","url","count"}]}` 或裸数组。
///
/// 只有中转「不可用」时才回落；中转返回合法 JSON（含空数组 `[]`）即权威结果，
/// 不再补发第二个请求——否则一次空命中会变成两次网络等待。
///
/// 约束：非 2xx / 非法 JSON / 超时一律返回空列表；单次最多 30 条。
/// 超时分两档：中转（含占位符 GET）用 [DanmakuLibraryService.relayTimeout]（30s），
/// 旧通用契约回落用 [DanmakuLibraryService.timeout]（6s）。
///
/// 多源（S1）：[searchSources] 对每个启用的源复用同一个 [search]，
/// 并行执行、逐源记账。协议实现只有一份——多源不该变成两套解析逻辑。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/danmaku.dart';
import '../core/danmaku_catalog.dart';
import '../core/danmaku_match.dart';
import '../core/danmaku_settings.dart';
import '../core/protocol.dart' show DanmakuSource;

/// 一个源的单次查询结果（失败也带着可读原因，供 UI 逐源显示）。
class DanmakuLibrarySourceResult {
  const DanmakuLibrarySourceResult({
    required this.id,
    required this.name,
    required this.ok,
    required this.count,
    required this.elapsedMs,
    this.error,
  });

  /// 弹幕源 id（`DanmakuSourceConfig.id`）；结果条目的 `libraryId` 与它同源。
  final String id;

  final String name;

  /// 本次查询是否成功；失败时 [error] 说明原因。
  final bool ok;

  /// 该源返回的条目数（合并去重**前**）：用来回答「这个源到底有没有货」。
  final int count;

  /// 该源耗时（Stopwatch 计），供 UI 显示与排查慢源。
  final int elapsedMs;

  /// ok=false 时的可读原因（HTTP 状态、超时、异常文本）。
  final String? error;

  @override
  String toString() =>
      'DanmakuLibrarySourceResult($id, ok=$ok, count=$count, '
      '${elapsedMs}ms${error == null ? '' : ', error=$error'})';
}

/// 多源查询的合并结果。
class DanmakuLibraryQueryResult {
  const DanmakuLibraryQueryResult({
    required this.entries,
    required this.sources,
  });

  const DanmakuLibraryQueryResult.empty()
    : entries = const [],
      sources = const [];

  /// 已按来源顺序合并、按 url 去重的条目。
  final List<DanmakuLibraryEntry> entries;

  /// 逐源记账，顺序与查询时传入的源顺序一致（与完成顺序无关）。
  final List<DanmakuLibrarySourceResult> sources;

  @override
  String toString() =>
      'DanmakuLibraryQueryResult(${entries.length} 条 / '
      '${sources.length} 源)';
}

class DanmakuLibraryService {
  DanmakuLibraryService({
    http.Client? client,
    this.timeout = const Duration(seconds: 6),
    this.relayTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// 旧通用契约回落请求的超时。
  final Duration timeout;

  /// FongMi 中转（含 `{name}`/`{episode}` 占位符 GET）的超时。
  ///
  /// danmu_api 冷搜索要现场去各平台源聚合再落缓存，实测 6.6–21s；沿用 6s 会把
  /// 慢但有效的响应判成超时，随后回落只拿到网页（text/html）→ 空结果 →
  /// 用户看到的却是「没有弹幕」。所以中转单独给足时间，回落仍用短超时。
  final Duration relayTimeout;

  /// 单次搜索的结果上限（与设计 §2.3 一致）。
  static const int maxEntries = 30;

  /// 搜索弹幕库；[apiUrl] 为空时零请求。
  Future<List<DanmakuLibraryEntry>> search({
    required String apiUrl,
    required String title,
    String? episode,
  }) async {
    final attempt = await _searchSource(
      apiUrl: apiUrl,
      title: title,
      episode: episode,
    );
    // 单源语义维持「失败即空」：调用方（播放器自动搜索）只关心有没有结果。
    return attempt.entries;
  }

  /// 并行搜索多个源，逐源记账后合并。
  ///
  /// 为什么逐源记账而不是「一个 Future.wait 拿总结果」：用户要看到哪个源没回、
  /// 为什么没回（超时/HTTP 500/地址写错）。单源失败被吞成空列表后，
  /// 「这个源配错了」和「这个源确实没有这部剧」就再也分不开了。
  ///
  /// [onSourceResult] 让慢源不再拖住快源：每个源一完成就回调一次（**完成顺序**，
  /// 与 [sources] 的配置顺序无关），UI 可以立刻渲染先回来的那批。返回值仍是旧契约
  /// ——「按源顺序合并 + 按 url 去重」——所以回调只改变渲染时机，不改变最终顺序。
  Future<DanmakuLibraryQueryResult> searchSources({
    required List<DanmakuSourceConfig> sources,
    required String title,
    String? episode,
    int maxConcurrency = 4,
    void Function(
      DanmakuLibrarySourceResult result,
      List<DanmakuLibraryEntry> entries,
    )? onSourceResult,
  }) async {
    final targets = [
      for (final source in sources)
        if (source.enabled) source,
    ];
    if (targets.isEmpty) return const DanmakuLibraryQueryResult.empty();

    final entriesBySource = List<List<DanmakuLibraryEntry>>.generate(
      targets.length,
      (_) => const [],
    );
    final resultsBySource = List<DanmakuLibrarySourceResult?>.filled(
      targets.length,
      null,
    );

    // 固定数量的 worker 抢队列：比「每批 Future.wait」简单，且不会在源数量
    // 不是并发上限整数倍时留下半批的等待。
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= targets.length) return;
        final source = targets[index];
        final watch = Stopwatch()..start();
        var entries = const <DanmakuLibraryEntry>[];
        String? error;
        try {
          if (!isValidDanmakuApiUrl(source.url)) {
            error = '地址无效：${source.url.trim()}';
          } else {
            final attempt = await _searchSource(
              apiUrl: source.url,
              title: title,
              episode: episode,
            );
            entries = attempt.entries;
            error = attempt.error;
          }
        } catch (exception) {
          // 兜底：任何一个源的意外异常都不该让整次多源搜索失败。
          error = exception.toString();
        }
        watch.stop();
        entriesBySource[index] = entries;
        final result = DanmakuLibrarySourceResult(
          id: source.id,
          name: source.name,
          ok: error == null,
          count: entries.length,
          elapsedMs: watch.elapsedMilliseconds,
          error: error,
        );
        resultsBySource[index] = result;
        if (onSourceResult != null) {
          // 就地发出＝完成顺序：快源不必等排在它前面的慢源。
          // 回调自己的异常必须吞掉——UI 少渲染一行，不该升级成「整次搜索失败」。
          try {
            onSourceResult(result, [
              for (final entry in entries) _decorate(source, entry),
            ]);
          } catch (_) {}
        }
      }
    }

    final limit = maxConcurrency < 1
        ? 1
        : (maxConcurrency > targets.length ? targets.length : maxConcurrency);
    await Future.wait([for (var index = 0; index < limit; index++) worker()]);

    // 合并顺序按「用户配置的源顺序」而不是完成顺序：同一部剧的两个源谁先回
    // 取决于网络，按完成顺序合并会让列表顺序每次刷新都变。
    final seenUrls = <String>{};
    final merged = <DanmakuLibraryEntry>[];
    for (var index = 0; index < targets.length; index++) {
      final source = targets[index];
      for (final entry in entriesBySource[index]) {
        if (!seenUrls.add(entry.url)) continue;
        merged.add(_decorate(source, entry));
      }
    }

    return DanmakuLibraryQueryResult(
      entries: merged,
      sources: [for (final result in resultsBySource) result!],
    );
  }

  /// 给条目补上归属信息（源 id / 源名 / 渠道）。
  ///
  /// 回调与最终合并共用它：增量渲染的那批条目必须带同样的来源与渠道，否则
  /// 先到的行是「未知来源」、后到的行才有来源——同一份结果两副面孔。
  static DanmakuLibraryEntry _decorate(
    DanmakuSourceConfig source,
    DanmakuLibraryEntry entry,
  ) => entry.copyWith(
    libraryId: source.id,
    libraryName: source.name,
    channel: _channelOf(entry),
  );

  /// 条目的渠道：先从中转名里解析，再从 providerId 兜底，最后才是「未知」。
  ///
  /// 'tvbox'/'default' 是适配层在「上游没给来源」时写的占位值，不是渠道：
  /// 把它们当渠道会让「渠道」筛选里出现一个既不可读也不指向真实平台的假分组。
  static String _channelOf(DanmakuLibraryEntry entry) {
    final provider = entry.providerId.trim();
    final placeholder =
        provider.isEmpty || provider == 'tvbox' || provider == 'default';
    return danmakuChannelOf(
          '${entry.title} ${entry.episode}',
          fallback: placeholder ? null : provider,
        ) ??
        kUnknownDanmakuChannel;
  }

  void close() => _client.close();

  /// 中转地址（对齐安卓 `DanmakuApi.getSearchUrl`）。
  ///
  /// 末段已是 `danmaku`、或地址本身就是多段路径时原样使用；否则补一段 `danmaku`：
  /// danmu_api 的部署地址常是 `http://host:9321/TOKEN`，而搜索接口在
  /// `/TOKEN/danmaku` 上，把表单 POST 到 `/TOKEN` 只会拿到它的网页。
  static Uri _relaySearchUri(Uri uri) {
    final segments = [...uri.pathSegments];
    // 末尾空段来自结尾的 `/`，不参与「段数」判断。
    if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
    if (segments.isNotEmpty && segments.last.toLowerCase() == 'danmaku') {
      return uri;
    }
    if (segments.length > 1) return uri;
    return uri.replace(pathSegments: [...segments, 'danmaku']);
  }

  /// 单源查询：返回条目与可读失败原因（error 为 null 表示成功）。
  Future<({List<DanmakuLibraryEntry> entries, String? error})> _searchSource({
    required String apiUrl,
    required String title,
    String? episode,
  }) async {
    final endpoint = apiUrl.trim();
    if (endpoint.isEmpty) {
      return (entries: const <DanmakuLibraryEntry>[], error: null);
    }
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasScheme) {
      return (entries: const <DanmakuLibraryEntry>[], error: '地址格式非法');
    }
    final episodeText = episode?.trim() ?? '';

    // 占位符模板由服务端自己拼参数，走 GET（对齐安卓 `DanmakuApi.newCall`）。
    if (endpoint.contains('{name}') || endpoint.contains('{episode}')) {
      return _getTemplate(endpoint, title: title, episode: episodeText);
    }

    final relay = await _postRelay(
      _relaySearchUri(uri),
      title: title,
      episode: episodeText,
    );
    if (relay.entries != null) {
      return (entries: relay.entries!, error: null);
    }
    final legacy = await _getLegacy(uri, title: title, episode: episodeText);
    if (legacy.entries.isNotEmpty) return legacy;
    // 两条链都空时：旧契约拿到合法空结果也算成功（ok=true, count=0），
    // 只有它也报错才把原因带回；否则报中转的原因（用户配的多半是中转）。
    return (entries: legacy.entries, error: legacy.error ?? relay.error);
  }

  Future<({List<DanmakuLibraryEntry> entries, String? error})> _getTemplate(
    String pattern, {
    required String title,
    required String episode,
  }) async {
    final target = Uri.tryParse(
      pattern
          .replaceAll('{name}', Uri.encodeComponent(title))
          .replaceAll('{episode}', Uri.encodeComponent(episode)),
    );
    if (target == null) {
      return (entries: const <DanmakuLibraryEntry>[], error: '地址模板无法解析');
    }
    try {
      final response = await _client
          .get(target, headers: const {'Accept': 'application/json'})
          .timeout(relayTimeout);
      if (!_isOk(response)) {
        return (
          entries: const <DanmakuLibraryEntry>[],
          error: 'HTTP ${response.statusCode}',
        );
      }
      final entries = _entriesOf(response.bodyBytes, title);
      if (entries == null) {
        return (entries: const <DanmakuLibraryEntry>[], error: '响应不是 JSON');
      }
      return (entries: entries, error: null);
    } on TimeoutException {
      return (entries: const <DanmakuLibraryEntry>[], error: _timeoutLabel());
    } catch (error) {
      return (entries: const <DanmakuLibraryEntry>[], error: error.toString());
    }
  }

  /// 中转搜索；返回 null 条目表示中转不可用（调用方据此回落旧契约）。
  Future<({List<DanmakuLibraryEntry>? entries, String? error})> _postRelay(
    Uri target, {
    required String title,
    required String episode,
  }) async {
    try {
      final response = await _client
          .post(
            target,
            headers: const {
              'Accept': 'application/json',
              'Content-Type':
                  'application/x-www-form-urlencoded; charset=utf-8',
            },
            body: _formBody({'name': title, 'episode': episode}),
          )
          .timeout(relayTimeout);
      if (!_isOk(response)) {
        return (entries: null, error: 'HTTP ${response.statusCode}');
      }
      final entries = _entriesOf(response.bodyBytes, title);
      if (entries == null) return (entries: null, error: '响应不是 JSON');
      return (entries: entries, error: null);
    } on TimeoutException {
      return (entries: null, error: _timeoutLabel());
    } catch (error) {
      return (entries: null, error: error.toString());
    }
  }

  Future<({List<DanmakuLibraryEntry> entries, String? error})> _getLegacy(
    Uri uri, {
    required String title,
    required String episode,
  }) async {
    final target = uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        'title': title,
        if (episode.isNotEmpty) 'episode': episode,
      },
    );
    try {
      final response = await _client
          .get(target, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      if (!_isOk(response)) {
        return (
          entries: const <DanmakuLibraryEntry>[],
          error: 'HTTP ${response.statusCode}',
        );
      }
      final decoded = _decode(response.bodyBytes);
      if (identical(decoded, _notJson)) {
        return (entries: const <DanmakuLibraryEntry>[], error: '响应不是 JSON');
      }
      return (entries: _entriesFromLegacy(decoded, title), error: null);
    } on TimeoutException {
      return (
        entries: const <DanmakuLibraryEntry>[],
        error: '请求超时（${timeout.inMilliseconds}ms）',
      );
    } catch (error) {
      return (entries: const <DanmakuLibraryEntry>[], error: error.toString());
    }
  }

  String _timeoutLabel() => '请求超时（${relayTimeout.inMilliseconds}ms）';

  /// 解析中转响应；响应不是 JSON 返回 null。
  List<DanmakuLibraryEntry>? _entriesOf(List<int> bytes, String fallbackTitle) {
    final decoded = _decode(bytes);
    if (identical(decoded, _notJson)) return null;
    final relayed = _entriesFromSources(danmakuSourcesFromJson(decoded));
    // 旧通用契约的条目只有 title/episode、没有中转的 name：信封里的 url 让中转
    // 解析「成功」但标题全空。此时改用旧映射，不必再发第二个请求。
    if (relayed.any((entry) => entry.title.isNotEmpty)) return relayed;
    final legacy = _entriesFromLegacy(decoded, fallbackTitle);
    return legacy.isEmpty ? relayed : legacy;
  }

  /// 中转条目：`name` 是「片名 - 集名」，`source` 是来源标记。
  List<DanmakuLibraryEntry> _entriesFromSources(List<DanmakuSource> sources) {
    // [danmakuSourcesFromJson] 已按 url 去重保序，这里只需映射与限长。
    final entries = <DanmakuLibraryEntry>[];
    for (final source in sources) {
      final url = source.url.trim();
      if (url.isEmpty) continue;
      final name = source.name.trim();
      // 片名自己可能含 ' - '，所以按最后一个分隔符拆。
      final divider = name.lastIndexOf(' - ');
      final sourceId = source.source.trim();
      entries.add(
        DanmakuLibraryEntry(
          providerId: sourceId.isEmpty ? 'tvbox' : sourceId,
          id: url,
          title: divider < 0 ? name : name.substring(0, divider).trim(),
          episode: divider < 0 ? '' : name.substring(divider + 3).trim(),
          url: url,
          count: 0,
          // 数值集号在入口算一次：排序/「仅本集」都读它，不再反复解析展示串。
          episodeNumber: danmakuEpisodeOf(
            divider < 0 ? name : name.substring(divider + 3),
          ),
        ),
      );
      if (entries.length >= maxEntries) break;
    }
    return entries;
  }

  /// 旧通用契约的数据形状：`{code,data:[...]}` 或裸数组。
  List<DanmakuLibraryEntry> _entriesFromLegacy(
    Object? decoded,
    String fallbackTitle,
  ) {
    final list = switch (decoded) {
      List value => value,
      Map value when value['data'] is List => value['data'] as List,
      _ => const [],
    };
    final entries = <DanmakuLibraryEntry>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final url = (raw['url'] ?? '').toString().trim();
      if (url.isEmpty) continue;
      entries.add(
        DanmakuLibraryEntry(
          providerId: (raw['provider'] ?? 'default').toString(),
          id: (raw['id'] ?? url).toString(),
          title: (raw['title'] ?? fallbackTitle).toString(),
          episode: (raw['episode'] ?? '').toString(),
          url: url,
          count: _intOf(raw['count']) ?? 0,
          episodeNumber: danmakuEpisodeOf(
            (raw['episode'] ?? '').toString().trim().isEmpty
                ? (raw['title'] ?? fallbackTitle).toString()
                : (raw['episode'] ?? '').toString(),
          ),
        ),
      );
      if (entries.length >= maxEntries) break;
    }
    return entries;
  }

  /// 解码响应体；非法 JSON 返回 [_notJson]（与合法的 null JSON 区分开）。
  static Object? _decode(List<int> bytes) {
    try {
      return jsonDecode(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return _notJson;
    }
  }

  static bool _isOk(http.Response response) =>
      response.statusCode >= 200 && response.statusCode < 300;

  static String _formBody(Map<String, String> fields) {
    final parts = <String>[];
    for (final field in fields.entries) {
      parts.add(
        '${Uri.encodeQueryComponent(field.key)}='
        '${Uri.encodeQueryComponent(field.value)}',
      );
    }
    return parts.join('&');
  }

  static int? _intOf(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }
}

/// jsonDecode 失败的哨兵。
const Object _notJson = _NotJson();

class _NotJson {
  const _NotJson();
}
