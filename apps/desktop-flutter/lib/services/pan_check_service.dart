/// 网盘链接检测服务（`docs/phase9/README.md` P1-8）。
///
/// 做法：对分享链接发一次有界 GET（跟随重定向），按状态码 + 页面特征判定；
/// 命中缓存直接返回。并发上限 4，请求去重（同链接并发只发一次）。
///
/// 明确的能力边界：不做各网盘私有 API 适配，页面改版时结果会退化为
/// `uncertain`（而不是误报失效）。不记录链接内容到日志（只记脱敏主机与状态）。
library;

import 'dart:async';
import 'dart:io';

import '../core/pan_check.dart';
import 'log_service.dart';

class PanCheckService {
  PanCheckService({
    this.log,
    HttpClient? client,
    PanCheckCache? cache,
    this.timeout = const Duration(seconds: 12),
    this.maxConcurrency = 4,
    this.maxBodyBytes = 512 * 1024,
  }) : cache = cache ?? PanCheckCache(),
       _client = client ?? HttpClient() {
    _client
      ..connectionTimeout = timeout
      ..userAgent =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';
  }

  final LogService? log;
  final PanCheckCache cache;
  final Duration timeout;
  final int maxConcurrency;
  final int maxBodyBytes;
  final HttpClient _client;

  final Map<String, Future<PanCheckResult>> _inflight = {};
  int _active = 0;

  /// 批量检测（保序）；同一个链接在结果里只出现一次。
  Future<List<PanCheckResult>> checkAll(
    List<String> links, {
    bool forceRefresh = false,
  }) async {
    final pending = <Future<PanCheckResult>>[];
    for (final link in links) {
      final parsed = parsePanShareLink(link);
      if (parsed.url.isEmpty) continue;
      pending.add(_checkOne(parsed, forceRefresh: forceRefresh));
    }
    if (pending.isEmpty) return const [];
    return Future.wait(pending);
  }

  Future<PanCheckResult> _checkOne(
    PanShareLink link, {
    required bool forceRefresh,
  }) async {
    final key = link.normalizedUrl;
    if (!forceRefresh) {
      final cached = cache.get(key);
      if (cached != null) return cached;
    }
    final running = _inflight[key];
    if (running != null) return running;

    final future = _runLimited(link, key);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<PanCheckResult> _runLimited(PanShareLink link, String key) async {
    while (_active >= maxConcurrency) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _active += 1;
    try {
      final result = await _probe(link);
      cache.put(key, result);
      log?.info(
        '网盘检测 ${result.diskType.id} ${result.state.id} '
        'host=${Uri.tryParse(link.url)?.host ?? "-"}',
        scope: 'pan',
      );
      return result;
    } finally {
      _active -= 1;
    }
  }

  Future<PanCheckResult> _probe(PanShareLink link) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (link.diskType == PanDiskType.unknown) {
      return PanCheckResult(
        url: link.url,
        normalizedUrl: link.normalizedUrl,
        diskType: PanDiskType.unknown,
        state: PanCheckState.unsupported,
        summary: '无法识别网盘类型（只支持常见分享链接）',
        checkedAt: now,
      );
    }

    final uri = Uri.tryParse(link.normalizedUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return PanCheckResult(
        url: link.url,
        normalizedUrl: link.normalizedUrl,
        diskType: link.diskType,
        state: PanCheckState.uncertain,
        summary: '链接不是有效的 http(s) 地址',
        checkedAt: now,
      );
    }

    try {
      final request = await _client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      final response = await request.close().timeout(timeout);
      final body = await _readBounded(response);
      final state = classifyPanCheck(
        diskType: link.diskType,
        statusCode: response.statusCode,
        body: body,
      );
      return PanCheckResult(
        url: link.url,
        normalizedUrl: link.normalizedUrl,
        diskType: link.diskType,
        state: state,
        summary: _summaryOf(state),
        checkedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (error) {
      // 网络不可达 ≠ 链接失效：如实给「无法判定」，不误报失效。
      log?.warning(
        '网盘检测请求失败 ${link.diskType.id} ${error.runtimeType}',
        scope: 'pan',
      );
      return PanCheckResult(
        url: link.url,
        normalizedUrl: link.normalizedUrl,
        diskType: link.diskType,
        state: PanCheckState.uncertain,
        summary: '请求失败：${error.runtimeType}',
        checkedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  static String _summaryOf(PanCheckState state) => switch (state) {
    PanCheckState.ok => '链接有效',
    PanCheckState.bad => '链接失效',
    PanCheckState.locked => '需要提取码或登录',
    PanCheckState.unsupported => '网盘类型不支持',
    PanCheckState.uncertain => '无法判定（页面特征不足）',
  };

  Future<String> _readBounded(HttpClientResponse response) async {
    final buffer = StringBuffer();
    var total = 0;
    try {
      await for (final chunk in response) {
        total += chunk.length;
        buffer.write(String.fromCharCodes(chunk));
        if (total >= maxBodyBytes) break;
      }
    } catch (_) {
      // 读取中断按已读内容判定。
    }
    return buffer.toString();
  }

  void close() => _client.close(force: true);
}
