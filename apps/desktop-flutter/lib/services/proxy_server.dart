/// 本地代理服务（设计文档 §9.6、§11.1、§11.2、§11.3、§11.3.1）。
///
/// 职责：为播放器提供带 Header 注入、Range 支持和 HLS 清单重写的本机通道，
/// 并使播放器的所有请求都必须经过 token 校验与目标校验。
///
/// 硬约束：
/// - 只监听 `127.0.0.1`，默认随机端口；非本机请求一律拒绝（§11.1、§11.3）；
/// - 每次播放独立 `sessionId` + 高熵 token，停止/超时/退出即失效（§11.3.1）；
/// - 每次 DNS 解析、连接和重定向后重新校验 scheme/host/port/IP（§11.3.1）；
/// - `Cookie`/`Authorization` 默认仅同源传播，跨 origin 重定向移除（§11.3.1）；
/// - HLS 主清单、子清单、分片保持同一会话（§11.4）；
/// - 日志只记录 token 指纹、目标主机、状态、字节数、耗时（§11.3.1）；
/// - HTML 错误页不得伪装成 200 媒体响应（§11.3 第 8 条）。
library;

import 'ai_integration.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import '../core/ad_rules.dart';
import '../core/dash_playlist.dart';
import '../core/proxy_policy.dart';
import '../core/playback_diagnostics.dart' show MediaFormat;
import '../core/png_wrapped_transport_stream.dart';
import 'log_service.dart';
import 'tolerant_http_reader.dart';

/// 代理请求结果，供调用方断言与诊断。
class ProxyRequestOutcome {
  const ProxyRequestOutcome({
    required this.statusCode,
    required this.bytes,
    this.error,
  });

  final int statusCode;
  final int bytes;
  final String? error;
}

/// 本地代理服务。
class LocalProxyServer {
  LocalProxyServer({
    required this.log,
    this.policy = const ProxyTargetPolicy(),
    ProxySessionManager? sessions,
    HttpClient? upstreamClient,
    this.requestTimeout = const Duration(seconds: 30),
  }) : sessions = sessions ?? ProxySessionManager(),
       _upstream = upstreamClient ?? HttpClient() {
    _upstream
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30)
      // 重定向必须手工跟随：每一跳都要重新校验（§11.3.1）。
      ..autoUncompress = false;
  }

  final LogService log;
  final ProxyTargetPolicy policy;

  /// 生效中的广告规则；由 `AppState` 在配置切换时注入。
  ///
  /// 默认空集：没有配置规则时行为与 Phase 3–8 完全一致。
  AdRuleSet adRules = const AdRuleSet.empty();
  final Map<String, AiPlaylistSnapshot> _mediaPlaylists = {};
  String? aiSessionFingerprint;
  AdRuleSet aiSessionRules = const AdRuleSet.empty();
  AiPlaylistSnapshot? mediaPlaylistFor(String fingerprint) =>
      _mediaPlaylists[fingerprint];

  /// 配置切换后更新规则（代理运行中也可安全替换）。
  void setAdRules(AdRuleSet rules) {
    adRules = rules;
  }

  final ProxySessionManager sessions;
  final HttpClient _upstream;
  final Duration requestTimeout;

  /// 严格容错读取器：只在**已授权映射端点**上重试一次（见 [_forwardTolerantly]）。
  /// 连接/空闲超时复用 [requestTimeout]，不引入第二套时间常量。
  late final TolerantHttpReader _tolerant = TolerantHttpReader(
    connectTimeout: requestTimeout,
    idleTimeout: requestTimeout,
  );

  HttpServer? _server;
  int _activeRequests = 0;

  /// 并发请求上限，避免被当作压测目标（§11.3「限制单请求大小和总并发」）。
  static const int maxConcurrentRequests = 32;

  int get activeRequests => _activeRequests;

  bool get isRunning => _server != null;

  int get port => _server?.port ?? 0;

  String get baseUrl => 'http://127.0.0.1:$port';

  /// 监听路径前缀。使用 `/p/<token>/<encoded>` 形态，token 在路径中而非 query，
  /// 避免被中间日志把完整 query 记下来（§11.3.1）。
  static const String pathPrefix = '/p/';

  /// 接收带标准媒体片段 t=秒 的本地播放URL；只保留一个跳段窗口。
  void primePrefetch(Iterable<Uri> targets) {
    final target = targets.firstOrNull;
    if (target == _prefetchTarget) {
      _queuePrefetch();
      return;
    }
    _prefetchRetryQueued = false;
    final previous = _background;
    cancelPrefetch(clearCache: false);
    if (target == null ||
        target.scheme != 'http' ||
        target.host != '127.0.0.1' ||
        target.port != port) {
      return;
    }
    _prefetchTarget = target;
    _queuePrefetch();
    if (previous != null && _background == previous) {
      _prefetchRetryQueued = true;
      previous.cancel();
    }
  }

  void cancelPrefetch({bool clearCache = true}) {
    _prefetchTarget = null;
    _prefetchRetryQueued = false;
    _prefetchQueue.clear();
    if (clearCache) {
      for (final state in _prefetchSessions.values) {
        state.cache.clear();
        state.bytes = 0;
        state.attempts.clear();
      }
    }
    _background?.cancel();
  }

  static const int prefetchWindowBytes = 24 * 1024 * 1024;
  static const int prefetchCacheBytes = 64 * 1024 * 1024;
  final _prefetchSessions = <String, _PrefetchSession>{};
  final _prefetchQueue = Queue<_PrefetchJob>();
  Uri? _prefetchTarget;
  _PrefetchRun? _background;
  bool _prefetchRetryQueued = false;

  void _indexPrefetch(ProxySession session, Uri playlist, String text) {
    final existing = _prefetchSessions[session.fingerprint];
    final state = existing != null && identical(existing.session, session)
        ? existing
        : (_prefetchSessions[session.fingerprint] = _PrefetchSession(session));
    if (text.contains('#EXT-X-STREAM-INF')) state.masterPlaylists.add(playlist);
    final index = _HlsPrefetchIndex.parse(playlist, text);
    if (index == null) {
      if (!text.contains('#EXT-X-STREAM-INF')) {
        state.disabled = true;
        state.cache.clear();
        state.bytes = 0;
        if (_background?.job.state == state) _background?.cancel();
      }
      return;
    }
    state.indexes[playlist] = index;
    _queuePrefetch();
  }

  void _queuePrefetch() {
    final target = _prefetchTarget;
    if (target == null || _prefetchQueue.isNotEmpty || _background != null) {
      return;
    }
    final parts = target.pathSegments;
    if (parts.length != 3 || parts.first != 'p') return;
    final session = sessions.byToken(parts[1]);
    if (session == null) return;
    final state = _prefetchSessions[session.fingerprint];
    if (state == null || !identical(state.session, session)) return;
    if (state.disabled) {
      log.debug('预取已忽略：会话停用', scope: 'proxy');
      return;
    }
    final seconds = target.fragment.startsWith('t=')
        ? double.tryParse(target.fragment.substring(2))
        : null;
    if (seconds == null || !seconds.isFinite || seconds < 0) return;
    final source = decodeTarget(parts[2]);
    final index =
        state.indexes[source] ??
        (state.masterPlaylists.contains(source) && state.indexes.length == 1
            ? state.indexes.values.single
            : null);
    if (index == null || seconds >= index.duration) return;
    for (final uri in state.cache.keys.toList()) {
      final entry = state.cache[uri]!;
      if (!entry.freshness.isFresh) {
        state.cache.remove(uri);
        state.bytes -= entry.bytes.length;
      }
    }
    final attempt = state.attempts[target];
    if (attempt != null &&
        (attempt.count >= 3 ||
            attempt.sinceStart.elapsed < const Duration(seconds: 1))) {
      return;
    }
    if (attempt == null && state.attempts.length >= 64) return;
    final window = _PrefetchWindow();
    final queued = <Uri>{};
    var mediaSeconds = 0.0;
    for (final segment in index.segments) {
      if (segment.start + segment.duration <= seconds) continue;
      if (mediaSeconds + segment.duration > 30) break;
      mediaSeconds += segment.duration;
      for (final uri in [
        segment.key,
        segment.initialization,
        segment.uri,
      ].whereType<Uri>()) {
        if (queued.add(uri) && !state.cache.containsKey(uri)) {
          _prefetchQueue.add(_PrefetchJob(state, uri, window));
        }
      }
    }
    if (_prefetchQueue.isNotEmpty) {
      final record = state.attempts.putIfAbsent(target, _PrefetchAttempt.new);
      record.count += 1;
      record.sinceStart
        ..reset()
        ..start();
    }
    _pumpPrefetch();
  }

  bool _prefetchValid(_PrefetchRun run) =>
      isRunning &&
      !run.cancelled &&
      _activeRequests == 0 &&
      !run.job.state.disabled &&
      run.job.state.session.usable &&
      identical(
        sessions.byToken(run.job.state.session.token),
        run.job.state.session,
      );

  void _pumpPrefetch() {
    for (final key in _prefetchSessions.keys.toList()) {
      final state = _prefetchSessions[key]!;
      if (!state.session.usable ||
          !identical(sessions.byToken(state.session.token), state.session)) {
        _prefetchSessions.remove(key);
        if (_background?.job.state == state) _background!.cancel();
      }
    }
    if (!isRunning || _activeRequests != 0 || _background != null) return;
    while (_prefetchQueue.isNotEmpty) {
      final job = _prefetchQueue.removeFirst();
      if (job.state.disabled ||
          !job.state.session.usable ||
          job.window.bytes >= prefetchWindowBytes ||
          job.state.cache.containsKey(job.uri)) {
        continue;
      }
      final run = _PrefetchRun(job);
      _background = run;
      unawaited(
        _fetchPrefetch(run).whenComplete(() {
          run.client.close(force: true);
          if (identical(_background, run)) _background = null;
          log.debug(
            '预取任务已释放 fingerprint=${run.job.state.session.fingerprint}',
            scope: 'proxy',
          );
          if (!run.done.isCompleted) run.done.complete();
          if (!run.cancelled && _prefetchQueue.isEmpty) {
            log.debug('预取窗口完成 bytes=${run.job.window.bytes}', scope: 'proxy');
          }
          if (_prefetchRetryQueued) {
            _prefetchRetryQueued = false;
            _queuePrefetch();
          }
          _pumpPrefetch();
        }),
      );
      return;
    }
  }

  Future<void> _preemptPrefetch() async {
    final run = _background;
    if (run == null) return;
    run.cancel();
    await run.done.future;
  }

  Future<void> _fetchPrefetch(_PrefetchRun run) async {
    final job = run.job;
    final session = job.state.session;
    var logical = job.uri;
    try {
      for (var redirect = 0; redirect <= policy.maxRedirects; redirect++) {
        if (!_prefetchValid(run)) return;
        final resolver = session.targetResolver;
        int? mapped;
        if (resolver != null) {
          if (!_managedLogicalDecision(logical).allowed) return;
          mapped = await run.wait(resolver(logical).timeout(requestTimeout));
          if (mapped != null &&
              (mapped < 1 || mapped > 65535 || mapped == port)) {
            return;
          }
        }
        final wire = mapped == null
            ? logical
            : logical.replace(host: '127.0.0.1', port: mapped, userInfo: '');
        final base = session.allowedHosts.isEmpty
            ? policy.allowedHosts
            : session.allowedHosts;
        final hop = ProxyTargetPolicy(
          allowPrivate: mapped == null && policy.allowPrivate,
          allowLoopback: mapped != null || policy.allowLoopback,
          allowedHosts: mapped != null
              ? {'127.0.0.1:$mapped'}
              : (base.isEmpty ? const {} : {...base, ...session.derivedHosts}),
          allowedSchemes: policy.allowedSchemes,
          maxRedirects: policy.maxRedirects,
        );
        if (!hop.evaluateStatic(wire).allowed ||
            adRules.isAdHost(logical.host)) {
          return;
        }
        final addresses = await run.wait(
          InternetAddress.lookup(wire.host).timeout(requestTimeout),
        );
        if (!_prefetchValid(run) ||
            !hop.evaluateAll(addresses, wire.host).allowed) {
          return;
        }
        final request = await run.client.getUrl(wire).timeout(requestTimeout);
        if (!_prefetchValid(run)) {
          request.abort();
          return;
        }
        request.followRedirects = false;
        final headers = _forwardHeaders(
          session: session,
          request: null,
          target: logical,
          range: null,
          managed: mapped != null,
        );
        headers.forEach((key, value) => request.headers.set(key, value));
        final responseStarted = Stopwatch()..start();
        final response = await request.close().timeout(requestTimeout);
        if (response.statusCode == 429) {
          _disablePrefetchSession(session);
          await _abort(response);
          return;
        }
        if (!_prefetchValid(run)) {
          await _abort(response);
          return;
        }
        if (!session.accountRequest(response.contentLength)) {
          await _abort(response);
          job.state.disabled = true;
          return;
        }
        if (_isRedirect(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await _abort(response);
          if (location == null || redirect == policy.maxRedirects) return;
          logical = logical.resolve(location);
          final check = ProxyTargetPolicy(
            allowPrivate: policy.allowPrivate,
            allowLoopback: policy.allowLoopback,
            allowedSchemes: policy.allowedSchemes,
          );
          if (!check.evaluateStatic(logical).allowed) return;
          session.derivedHosts.add(logical.host.toLowerCase());
          continue;
        }
        final type =
            response.headers.value(HttpHeaders.contentTypeHeader) ??
            'application/octet-stream';
        final freshness = _PrefetchFreshness.read(
          response.headers,
          responseStarted.elapsed,
        );
        final remaining = prefetchWindowBytes - job.window.bytes;
        if (response.statusCode != 200 ||
            freshness == null ||
            type.toLowerCase().contains('text/html') ||
            response.headers.value(HttpHeaders.contentEncodingHeader) != null ||
            response.contentLength > remaining) {
          if (response.contentLength > remaining) {
            job.window.bytes = prefetchWindowBytes;
          }
          await _abort(response);
          return;
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(requestTimeout)) {
          if (!_prefetchValid(run) ||
              chunk.length > prefetchWindowBytes - job.window.bytes) {
            job.window.bytes = prefetchWindowBytes;
            run.cancel();
            return;
          }
          if (response.contentLength < 0) {
            if (chunk.length > session.maxBytes - session.bytes) {
              job.state.disabled = true;
              run.cancel();
              return;
            }
            session.bytes += chunk.length;
          }
          job.window.bytes += chunk.length;
          session.recordReceivedBytes(chunk.length);
          builder.add(chunk);
        }
        if (!_prefetchValid(run) ||
            (response.contentLength >= 0 &&
                builder.length != response.contentLength)) {
          return;
        }
        final bytes = builder.takeBytes();
        if (bytes.length >= 8 &&
            bytes[0] == 137 &&
            bytes[1] == 80 &&
            bytes[2] == 78 &&
            bytes[3] == 71) {
          return;
        }
        _cachePrefetch(job.state, job.uri, bytes, type, freshness);
        return;
      }
    } catch (_) {
      // 取消和后台失败不改变前台播放，也不自动重试。
    }
  }

  void _disablePrefetchSession(ProxySession session) {
    final state = _prefetchSessions.putIfAbsent(
      session.fingerprint,
      () => _PrefetchSession(session),
    );
    final alreadyDisabled = state.disabled;
    state.disabled = true;
    state.cache.clear();
    state.bytes = 0;
    _prefetchQueue.removeWhere((job) => identical(job.state.session, session));
    if (_background?.job.state.session == session) _background!.cancel();
    if (!alreadyDisabled) {
      log.info('预取已禁用：上游429 session=${session.fingerprint}', scope: 'proxy');
    }
  }

  void _cachePrefetch(
    _PrefetchSession state,
    Uri uri,
    Uint8List bytes,
    String type,
    _PrefetchFreshness freshness,
  ) {
    if (!freshness.isFresh) return;
    if (bytes.length > prefetchWindowBytes || !state.session.usable) return;
    final old = state.cache.remove(uri);
    state.bytes -= old?.bytes.length ?? 0;
    while (state.bytes + bytes.length > prefetchCacheBytes &&
        state.cache.isNotEmpty) {
      final removed = state.cache.remove(state.cache.keys.first)!;
      state.bytes -= removed.bytes.length;
    }
    state.cache[uri] = _CachedPrefetch(bytes, type, freshness);
    state.bytes += bytes.length;
    log.debug(
      '预取缓存 bytes=${bytes.length} total=${state.bytes} '
      'fingerprint=${state.session.fingerprint}',
      scope: 'proxy',
    );
  }

  Future<bool> _servePrefetch(
    HttpRequest request,
    ProxySession session,
    Uri target,
  ) async {
    final state = _prefetchSessions[session.fingerprint];
    if (request.method != 'GET' && request.method != 'HEAD') return false;
    final entry = state?.cache.remove(target);
    if (entry == null) return false;
    // A revalidation request invalidates our old copy and uses normal forwarding.
    if (request.headers[HttpHeaders.cacheControlHeader] != null ||
        request.headers[HttpHeaders.pragmaHeader] != null ||
        request.headers.value(HttpHeaders.ifRangeHeader) != null ||
        request.headers.value(HttpHeaders.ifNoneMatchHeader) != null ||
        request.headers.value(HttpHeaders.ifModifiedSinceHeader) != null ||
        !entry.freshness.isFresh) {
      state!.bytes -= entry.bytes.length;
      return false;
    }
    state!.cache[target] = entry;
    final length = entry.bytes.length;
    var start = 0;
    var end = length - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
      if (match == null) return false;
      if (match[1]!.isEmpty) {
        final suffix = int.tryParse(match[2]!);
        if (suffix == null || suffix <= 0) return false;
        start = length > suffix ? length - suffix : 0;
      } else {
        start = int.tryParse(match[1]!) ?? length;
        end = match[2]!.isEmpty ? length - 1 : int.tryParse(match[2]!) ?? -1;
        if (end >= length) end = length - 1;
      }
    }
    final response = request.response;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.contentTypeHeader, entry.contentType);
    // Local reuse never grants downstream caches a fresh lifetime of their own.
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (start >= length || start > end) {
      response.statusCode = 416;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      await response.close();
      return true;
    }
    response.statusCode = range == null ? 200 : 206;
    if (range != null) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    }
    response.contentLength = end - start + 1;
    if (request.method != 'HEAD') {
      response.add(entry.bytes.sublist(start, end + 1));
    }
    await response.close();
    return true;
  }

  Future<void> start({int port = 0, String host = '127.0.0.1'}) async {
    if (_server != null) return;
    if (host != '127.0.0.1' && host != 'localhost' && host != '::1') {
      throw ArgumentError('本地代理只允许监听回环地址，收到：$host');
    }
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
      shared: false,
    );
    _server = server;
    log.info('本地代理已启动 base=$baseUrl', scope: 'proxy');
    unawaited(_serve(server));
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handleSafely(request));
    }
  }

  /// 停止服务并释放端口（§11.4「代理关闭后端口释放」）。
  Future<void> stop() async {
    final server = _server;
    _server = null;
    cancelPrefetch();
    await _preemptPrefetch();
    _prefetchSessions.clear();
    sessions.revokeAll();
    _upstream.close(force: true);
    if (server != null) {
      await server.close(force: true);
    }
    log.info('本地代理已停止', scope: 'proxy');
  }

  /// 构造某个会话下目标 URL 的代理地址。
  String urlFor(ProxySession session, Uri target) =>
      '$baseUrl$pathPrefix${session.token}/${encodeTarget(target)}';

  ProxyTrafficSnapshot? trafficFor(String playbackUrl) {
    final uri = Uri.tryParse(playbackUrl);
    if (!isRunning ||
        uri == null ||
        uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.port != port) {
      return null;
    }
    final parts = uri.pathSegments;
    if (parts.length < 3 || parts.first != 'p') return null;
    final session = sessions.byToken(parts[1]);
    if (session == null) return null;
    return (sessionId: session.id, receivedBytes: session.receivedBytes);
  }

  /// Signature evidence for exactly this live proxy/session/path, never URL guesses.
  MediaFormat? observedFormatFor(String playbackUrl) {
    if (trafficFor(playbackUrl) == null) return null;
    final uri = Uri.parse(playbackUrl);
    final session = sessions.byToken(uri.pathSegments[1]);
    return session?.hasObservedHlsPath(uri.path) == true
        ? MediaFormat.hls
        : null;
  }

  /// 构造会话内子资源（分片、子清单、密钥）的代理地址。
  ///
  /// 先用会话短码 `…/p/<token>/i/<n>`：清单里每一条子资源都要写一个地址，长表
  /// 单条 500+ 字符，一份实测 24 KB 的清单（739 段）重写后变成 240 KB。短码表满
  /// 时退回 [urlFor] 的长表单条 URL，正确性不受上限影响。
  String urlForChild(ProxySession session, Uri target) {
    final index = session.indexOfChild(target);
    if (index == null) return urlFor(session, target);
    return '$baseUrl$pathPrefix${session.token}/i/$index';
  }

  /// 构造会话内基址代理地址；文件或目录 BaseURL 都按原 URI 保留，
  /// 播放器可把相对模板/分片追加到末尾，取回时按 URI 解析规则还原。
  String urlForDirectory(ProxySession session, Uri logicalBase) {
    return '$baseUrl$pathPrefix${session.token}/d/${encodeTarget(logicalBase)}/';
  }

  /// 目标 URL 编码：base64url 无填充，避免路径分隔符与 query 干扰路由解析。
  static String encodeTarget(Uri target) =>
      base64Url.encode(utf8.encode(target.toString())).replaceAll('=', '');

  static Uri? decodeTarget(String encoded) {
    try {
      final padding = (4 - encoded.length % 4) % 4;
      final text = utf8.decode(base64Url.decode('$encoded${'=' * padding}'));
      final uri = Uri.tryParse(text);
      if (uri == null || !uri.hasScheme) return null;
      return uri;
    } catch (_) {
      return null;
    }
  }

  /// 兼容旧版本把本地代理地址写进历史记录的情况（Phase 2 修复的续播缺陷）。
  ///
  /// 历史 `episode_id` 里存过 `http://127.0.0.1:<port>/p/<token>/<base64>`：
  /// token 已失效，但路径最后一段仍包含原始站点目标，可以无损恢复。
  /// 放在服务层是因为它依赖 [LocalProxyServer] 的路径/解码约定；
  /// `ui/library_pages.dart` 通过 `export` 继续对外提供同名函数。
  static String restoreHistoryPlaybackTarget(String episodeId) {
    final uri = Uri.tryParse(episodeId);
    if (uri != null && uri.path.startsWith(pathPrefix)) {
      final encoded = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
      final decoded = decodeTarget(encoded);
      if (decoded != null) return decoded.toString();
    }
    return episodeId;
  }

  Future<void> _handleSafely(HttpRequest request) async {
    try {
      await _handle(request);
    } catch (error, stackTrace) {
      log.error('代理请求异常：$error\n$stackTrace', scope: 'proxy');
      try {
        await _fail(request, 500, '代理内部错误');
      } catch (_) {
        // 连接可能已关闭。
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    // 1) 只接受本机请求（§11.3 第 1 条）。
    final remote = request.connectionInfo?.remoteAddress;
    if (remote == null || !_isLoopback(remote)) {
      log.warning(
        '拒绝非本机代理请求 from=${remote?.address ?? "unknown"}',
        scope: 'proxy',
      );
      await _fail(request, 403, '代理只接受本机请求');
      return;
    }

    // 2) 路由与 token 校验（§11.3 第 2 条）。
    final segments = request.uri.pathSegments;
    if (segments.length < 3 || segments[0] != 'p') {
      await _fail(request, 404, '代理路径非法');
      return;
    }
    final token = segments[1];
    final session = sessions.byToken(token);
    if (session == null) {
      log.warning(
        '代理请求 token 无效 fingerprint=${ProxySessionManager.fingerprintOf(token)}',
        scope: 'proxy',
      );
      await _fail(request, 401, 'token 无效或会话已失效');
      return;
    }

    // 3) 目标解析：`i/<n>` 是**本会话**的短码命名空间，其余按 base64 目标解码。
    //    两套编码互不回落——短码越界就当作无法解析，绝不去当 base64 再解一次。
    final payload = segments.sublist(2);
    final Uri? target;
    if (payload.length == 2 && payload[0] == 'i') {
      final alias = RegExp(r'^(0|[1-9]\d*)\.ts$').firstMatch(payload[1]);
      target = alias == null
          ? session.childTargetAt(int.tryParse(payload[1]) ?? -1)
          : session.pngTsMediaAliasTargetAt(
              int.tryParse(alias.group(1)!) ?? -1,
            );
    } else if (payload.length >= 2 && payload[0] == 'd') {
      target = _directoryTarget(
        decodeTarget(payload[1]),
        payload.sublist(2),
        request.uri.query,
      );
    } else {
      target = decodeTarget(payload.join('/'));
    }
    if (target == null) {
      await _fail(request, 400, '目标 URL 无法解析');
      return;
    }

    if (_activeRequests >= maxConcurrentRequests) {
      await _fail(request, 429, '代理并发超过上限');
      return;
    }
    _activeRequests += 1;
    try {
      await _preemptPrefetch();
      await _forward(request, session, target);
    } finally {
      _activeRequests -= 1;
      _pumpPrefetch();
    }
  }

  static Uri? _directoryTarget(Uri? base, List<String> suffix, String query) {
    if (base == null ||
        !(base.isScheme('http') || base.isScheme('https')) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty) {
      return null;
    }
    for (final segment in suffix) {
      if (segment.isEmpty ||
          segment == '.' ||
          segment == '..' ||
          segment.contains('\\') ||
          segment.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
        return null;
      }
    }
    if (suffix.isEmpty) {
      return base.replace(query: query.isEmpty ? base.query : query);
    }
    final relative = Uri(
      pathSegments: suffix,
      query: query.isEmpty ? null : query,
    );
    // RFC 3986 resolution: a file BaseURL drops its last segment for a
    // relative child, while a directory BaseURL appends normally.
    return base.resolveUri(relative);
  }

  Future<void> _forward(
    HttpRequest request,
    ProxySession session,
    Uri target, {
    bool fullManifest = false,
    bool fullTransportStream = false,
    Uri? transportStreamSource,
    Uri? verifiedWireTarget,
  }) async {
    final stopwatch = Stopwatch()..start();
    final mediaSource = transportStreamSource ?? target;
    final fullRepresentation = fullManifest || fullTransportStream;
    final range = fullRepresentation
        ? null
        : request.headers.value(HttpHeaders.rangeHeader);
    if (!identical(sessions.byToken(session.token), session) ||
        !session.usable) {
      await _fail(request, 401, 'token 无效或会话已失效');
      return;
    }
    if (!adRules.isAdHost(target.host) &&
        await _servePrefetch(request, session, target)) {
      return;
    }
    // 会话级白名单优先于全局策略（§11.3.1「token 只授权当前站点与当前播放请求」）。
    // 主机白名单：站点授权主机 + 本次播放已派生的重定向主机（§11.3.1）。
    // 媒资分发常见 302 到 CDN（百度 `d.pcs.baidu.com` → `appall01.baidupcs.com`），
    // 派生主机只在通过 scheme/IP 安全校验后才被授权。
    final baseHosts = session.allowedHosts.isEmpty
        ? policy.allowedHosts
        : session.allowedHosts;
    ProxyTargetPolicy hopPolicy() => ProxyTargetPolicy(
      allowPrivate: policy.allowPrivate,
      allowLoopback: policy.allowLoopback,
      // 空名单代表不额外限主机；派生重定向不能反向收紧原有公网范围。
      allowedHosts: baseHosts.isEmpty
          ? const <String>{}
          : {...baseHosts, ...session.derivedHosts},
      allowedSchemes: policy.allowedSchemes,
      maxRedirects: policy.maxRedirects,
    );

    var logicalCurrent = target;
    var redirects = 0;
    Uri? currentWireTarget;
    ProxyTargetPolicy? currentWirePolicy;
    HttpClientResponse? upstream;
    int? lastUpstreamStatus;
    String? denyReason;
    int denyCode = 403;

    ProxyTargetPolicy mappedPolicy(int mappedPort) => ProxyTargetPolicy(
      allowLoopback: true,
      allowPrivate: false,
      allowedHosts: {'127.0.0.1:$mappedPort'},
      allowedSchemes: policy.allowedSchemes,
      maxRedirects: policy.maxRedirects,
    );

    while (true) {
      int? mappedPort;
      final resolver = session.targetResolver;
      if (resolver != null) {
        final logicalDecision = _managedLogicalDecision(logicalCurrent);
        if (!logicalDecision.allowed) {
          denyReason = logicalDecision.reason;
          denyCode = logicalDecision.code;
          break;
        }
        if (adRules.isAdHost(logicalCurrent.host)) {
          denyReason = '命中广告规则：${logicalCurrent.host}';
          denyCode = 403;
          break;
        }
        try {
          mappedPort = await resolver(logicalCurrent).timeout(requestTimeout);
        } on TimeoutException {
          denyReason = 'Android 传输授权超时';
          denyCode = 502;
          break;
        } catch (_) {
          denyReason = 'Android 传输授权失败';
          denyCode = 502;
          break;
        }
        // 解析可能耗时：撤销/过期后不得继续使用旧 token 打开上游。
        if (!identical(sessions.byToken(session.token), session) ||
            !session.usable) {
          denyReason = 'token 无效或会话已失效';
          denyCode = 401;
          break;
        }
        if (mappedPort != null &&
            (mappedPort < 1 || mappedPort > 65535 || mappedPort == port)) {
          denyReason = 'Android 转发端口无效';
          denyCode = 502;
          break;
        }
      }
      final mapped = mappedPort != null;
      final wireTarget = mapped
          ? logicalCurrent.replace(
              host: '127.0.0.1',
              port: mappedPort,
              userInfo: '',
            )
          : logicalCurrent;
      if (fullRepresentation && wireTarget != verifiedWireTarget) {
        denyReason = '清单重试目标发生变化';
        denyCode = 502;
        break;
      }
      currentWireTarget = wireTarget;
      final effectivePolicy = mapped ? mappedPolicy(mappedPort) : hopPolicy();
      currentWirePolicy = effectivePolicy;
      final staticDecision = effectivePolicy.evaluateStatic(wireTarget);
      if (!staticDecision.allowed) {
        denyReason = staticDecision.reason;
        denyCode = staticDecision.code;
        break;
      }
      // 广告主机：在 DNS 解析前拒绝（避免无谓解析，也避免把广告请求发出去）。
      if (adRules.isAdHost(logicalCurrent.host)) {
        denyReason = '命中广告规则：${logicalCurrent.host}';
        denyCode = 403;
        break;
      }
      // 每次连接前重新解析并复核全部地址，防 DNS 重绑定（§11.3.1）。
      final List<InternetAddress> addresses;
      try {
        addresses = await InternetAddress.lookup(wireTarget.host);
      } catch (error) {
        denyReason = 'DNS 解析失败：${wireTarget.host}';
        denyCode = 502;
        break;
      }
      if (!identical(sessions.byToken(session.token), session) ||
          !session.usable) {
        denyReason = 'token 无效或会话已失效';
        denyCode = 401;
        break;
      }
      final addressDecision = effectivePolicy.evaluateAll(
        addresses,
        wireTarget.host,
      );
      if (!addressDecision.allowed) {
        denyReason = addressDecision.reason;
        denyCode = addressDecision.code;
        break;
      }

      final HttpClientRequest outbound;
      try {
        outbound = await _upstream
            .openUrl(request.method == 'HEAD' ? 'HEAD' : 'GET', wireTarget)
            .timeout(requestTimeout);
      } catch (error) {
        denyReason = '连接上游失败：${error.runtimeType}';
        denyCode = 502;
        break;
      }
      // 必须关闭自动重定向：`HttpClient` 自动跟随会**丢弃自定义请求头**
      // （回落为 `Dart/3.x (dart:io)` 的 UA 与 `gzip` 的 Accept-Encoding），
      // 导致网盘 CDN（如百度 `appall01.baidupcs.com`）校验 UA 失败而返回
      // 403 `sign error`。手工逐跳跟随才能在每一跳重新注入会话 Header
      // （§11.3.1）。
      if (!identical(sessions.byToken(session.token), session) ||
          !session.usable) {
        outbound.abort();
        denyReason = 'token 无效或会话已失效';
        denyCode = 401;
        break;
      }
      outbound.followRedirects = false;

      // 必须在构造转发 Header **之前**确立来源：否则首跳的 origin 会退化为
      // 代理自身地址（与目标永远不同源），导致站点 Cookie/Authorization
      // 在首跳就被当作跨域凭据剥离（§11.3.1）。
      if (logicalCurrent == target && session.establishedOrigin == null) {
        session.establishedOrigin = mapped
            ? '${logicalCurrent.scheme}://${logicalCurrent.host}:${logicalCurrent.port}'
            : '${logicalCurrent.host}:${logicalCurrent.port}';
      }
      final forwardHeaders = _forwardHeaders(
        session: session,
        request: request,
        target: logicalCurrent,
        range: range,
        managed: mapped,
      );
      if (fullRepresentation) {
        forwardHeaders.removeWhere(
          (name, _) => {
            HttpHeaders.rangeHeader,
            HttpHeaders.ifRangeHeader,
            HttpHeaders.ifNoneMatchHeader,
            HttpHeaders.ifModifiedSinceHeader,
            HttpHeaders.ifMatchHeader,
            HttpHeaders.ifUnmodifiedSinceHeader,
          }.contains(name.toLowerCase()),
        );
      }
      for (final entry in forwardHeaders.entries) {
        outbound.headers.set(entry.key, entry.value);
      }

      final guard =
          (session.targetResolver != null || session.inspectPlaylistContent)
          ? Timer.periodic(const Duration(milliseconds: 25), (_) {
              if (!session.usable ||
                  !identical(sessions.byToken(session.token), session)) {
                outbound.abort();
              }
            })
          : null;
      unawaited(
        request.response.done.then(
          (_) => outbound.abort(),
          onError: (Object _) => outbound.abort(),
        ),
      );
      final HttpClientResponse response;
      try {
        response = await outbound.close().timeout(requestTimeout);
      } catch (error) {
        if (!identical(sessions.byToken(session.token), session) ||
            !session.usable) {
          denyReason = 'token 无效或会话已失效';
          denyCode = 401;
          break;
        }
        // Dart 的 HttpClient 在解析阶段就拒绝「重复/冲突分帧头」，
        // 过去只会得到不透明的「请求上游失败：HttpException」。这里把它识别成
        // 可定位的一类失败；受管会话再对**同一个已核验转发端点**严格重试一次。
        if (UpstreamFramingFailure.isDuplicateFraming(error)) {
          _logFramingReject(session, logicalCurrent);
          if (!fullTransportStream &&
              mapped &&
              session.targetResolver != null) {
            await _forwardTolerantly(
              request: request,
              session: session,
              logicalTarget: logicalCurrent,
              wireTarget: wireTarget,
              headers: forwardHeaders,
              range: range,
              stopwatch: stopwatch,
            );
            return;
          }
          denyReason = UpstreamFramingFailure.message;
          denyCode = 502;
          break;
        }
        denyReason = '请求上游失败：${error.runtimeType}';
        denyCode = 502;
        break;
      } finally {
        guard?.cancel();
      }
      if (!identical(sessions.byToken(session.token), session) ||
          !session.usable) {
        await _abort(response);
        denyReason = 'token 无效或会话已失效';
        denyCode = 401;
        break;
      }

      lastUpstreamStatus = response.statusCode;
      if (lastUpstreamStatus == 429) _disablePrefetchSession(session);

      // 重定向：手工跟随并逐跳复核（§11.3.1）。
      if (_isRedirect(response.statusCode)) {
        if (fullTransportStream) {
          final withinQuota = session.accountRequest(
            response.contentLength >= 0 ? response.contentLength : 0,
          );
          await _abort(response);
          denyReason = '受管媒体重试目标发生变化';
          denyCode = withinQuota ? 502 : 429;
          break;
        }
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) {
          denyReason = '重定向缺少 Location';
          denyCode = 502;
          break;
        }
        redirects += 1;
        if (redirects > effectivePolicy.maxRedirects) {
          denyReason = '重定向次数超过限制';
          denyCode = 502;
          break;
        }
        // Location 必须按**逻辑**当前地址解析；物理 127.0.0.1:port 只属于
        // 传输层，不能成为清单/凭据/重定向的来源。
        final next = logicalCurrent.resolve(location);
        if (!policy.allowedSchemes.contains(next.scheme.toLowerCase()) ||
            next.host.isEmpty ||
            next.userInfo.isNotEmpty ||
            ProxyTargetPolicy.cloudMetadataHosts.contains(
              next.host.toLowerCase(),
            )) {
          denyReason = '重定向目标不被允许';
          denyCode = 403;
          break;
        }
        // 普通目标沿用既有全局静态校验与派生主机授权；已授权私网目标
        // 不在这里放行，交给下一轮 resolver 或普通策略明确拒绝。
        final probePolicy = ProxyTargetPolicy(
          allowPrivate: policy.allowPrivate,
          allowLoopback: policy.allowLoopback,
          allowedSchemes: policy.allowedSchemes,
          maxRedirects: policy.maxRedirects,
        );
        final probe = probePolicy.evaluateStatic(next);
        if (probe.allowed) {
          session.derivedHosts.add(next.host.toLowerCase());
        }
        log.debug(
          '代理跟随重定向 href=${redactProxyTarget(next)} redirects=$redirects',
          scope: 'proxy',
        );
        logicalCurrent = next;
        continue;
      }

      upstream = response;
      break;
    }

    if (upstream == null) {
      _record(
        session,
        target,
        statusCode: denyCode,
        upstreamStatus: lastUpstreamStatus,
        elapsed: stopwatch.elapsed,
        range: range,
        note: denyReason ?? 'denied',
      );
      await _fail(request, denyCode, denyReason ?? '目标被拒绝');
      return;
    }

    // 4) HTML 错误页不得伪装成 200 媒体（§11.3 第 8 条）。
    final contentType =
        upstream.headers.value(HttpHeaders.contentTypeHeader) ?? '';
    final looksHtml = contentType.toLowerCase().contains('text/html');
    if (looksHtml && upstream.statusCode >= 200 && upstream.statusCode < 300) {
      await _abort(upstream);
      _record(
        session,
        target,
        statusCode: 502,
        upstreamStatus: upstream.statusCode,
        elapsed: stopwatch.elapsed,
        range: range,
        note: 'upstream-html',
      );
      await _fail(request, 502, '上游返回 HTML 页面而不是媒体数据');
      return;
    }

    if (!session.accountRequest(
      upstream.contentLength >= 0 ? upstream.contentLength : 0,
    )) {
      // 不能 drain：上游可能是 GB 级整文件流，排空会耗时上百秒，
      // 使客户端（mpv 20s 超时）在拿到 429 之前就报 `loadFailed`。
      await _abort(upstream);
      _record(
        session,
        target,
        statusCode: 429,
        upstreamStatus: upstream.statusCode,
        elapsed: stopwatch.elapsed,
        range: range,
        note: 'session-limit',
      );
      await _fail(request, 429, '会话累计流量或请求数超过上限');
      return;
    }

    final response = request.response;
    response.statusCode = upstream.statusCode;

    final isDash =
        !(fullTransportStream && upstream.statusCode >= 400) &&
        DashPlaylistRewriter.looksLikeManifest(
          contentType,
          logicalCurrent.toString(),
        );
    if ((fullManifest || fullTransportStream) && isDash) {
      await _abort(upstream);
      await _fail(request, 502, '清单重试类型发生变化');
      return;
    }
    if (isDash && upstream.statusCode >= 200 && upstream.statusCode < 300) {
      final body = await _readAll(upstream, manifestType: 'DASH');
      session.recordReceivedBytes(body.length);
      final String rewritten;
      try {
        rewritten = DashPlaylistRewriter.rewrite(
          utf8.decode(body, allowMalformed: true),
          baseUri: logicalCurrent,
          childUrl: (child) => _proxifyForManifest(session, child),
          directoryUrl: (directory) =>
              _directoryForManifest(session, directory),
        );
      } catch (_) {
        _record(
          session,
          target,
          statusCode: 502,
          elapsed: stopwatch.elapsed,
          range: range,
          note: 'dash-invalid',
        );
        await _fail(request, 502, 'DASH 清单无法解析');
        return;
      }
      final bytes = utf8.encode(rewritten);
      response.statusCode = HttpStatus.ok;
      _copySafeHeaders(
        response,
        upstream,
        contentLength: bytes.length,
        synthesizedBody: true,
        dropCacheMetadata: true,
      );
      response.headers.contentType = ContentType(
        'application',
        'dash+xml',
        charset: 'utf-8',
      );
      response.headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}');
      response.add(bytes);
      await response.close();
      _record(
        session,
        target,
        statusCode: 200,
        bytes: bytes.length,
        elapsed: stopwatch.elapsed,
        range: range,
        note: 'dash-rewrite',
      );
      return;
    }

    final managedInspection =
        session.targetResolver != null || session.inspectPlaylistContent;
    final encoding = upstream.headers.value(HttpHeaders.contentEncodingHeader);
    final uncompressed =
        encoding == null || encoding.toLowerCase() == 'identity';
    var isPlaylist =
        managedInspection &&
        request.method == 'GET' &&
        uncompressed &&
        !(fullTransportStream && upstream.statusCode >= 400) &&
        HlsPlaylistRewriter.looksLikePlaylist(
          contentType,
          logicalCurrent.toString(),
        );
    var bodyStream = upstream as Stream<List<int>>;
    List<int>? sniffedManifest;
    Future<void> Function()? hlsCancel;
    // 仅受管 GET 成功响应按内容补判；普通流遇到非清单前缀立即原样透传。
    if (managedInspection &&
        uncompressed &&
        request.method == 'GET' &&
        (upstream.statusCode == 200 || upstream.statusCode == 206) &&
        !isPlaylist) {
      final _SniffedHls sniffed;
      try {
        sniffed = await _sniffHls(bodyStream, session, request);
      } on _PngFailure catch (error) {
        await _fail(request, error.status, '受管媒体会话失效');
        return;
      } catch (_) {
        await _fail(request, 502, '受管媒体读取失败');
        return;
      }
      hlsCancel = sniffed.cancel;
      bodyStream = sniffed.stream;
      if (sniffed.oversized) {
        await _fail(request, 502, 'HLS 清单超过 1 MiB');
        return;
      }
      sniffedManifest = sniffed.manifest;
      isPlaylist = sniffedManifest != null;
    }

    if (!managedInspection &&
        request.method == 'GET' &&
        _canInspectPlaylist(upstream)) {
      final probe = await _inspectPlaylist(bodyStream);
      isPlaylist = probe.isPlaylist;
      bodyStream = probe.body;
    }
    if (!isPlaylist &&
        request.method == 'GET' &&
        _canInspectPlaylist(upstream)) {
      session.clearHlsPath(request.uri.path);
    }

    if (fullTransportStream && isPlaylist) {
      if (sniffedManifest != null) {
        session.recordReceivedBytes(sniffedManifest.length);
      }
      await _abortBody(bodyStream);
      await _fail(request, 502, '受管媒体重试类型发生变化');
      return;
    }

    if (fullManifest && !isPlaylist) {
      await _abortBody(bodyStream);
      await _fail(request, 502, '清单完整响应无法确认');
      return;
    }

    if (isPlaylist) {
      // 清单必须整体读取后重写，保证子清单/分片 URL 走同一会话（§11.4）。
      final body = sniffedManifest ?? await _readAll(bodyStream);
      session.recordReceivedBytes(body.length);
      if (managedInspection) {
        if (!identical(sessions.byToken(session.token), session) ||
            !session.usable) {
          await _fail(request, 401, 'token 无效或会话已失效');
          return;
        }
        // 206 必须覆盖完整实体才能合成 200；真正的片段只重试一次，
        // 去掉 Range/If-Range 与条件缓存头，重新执行授权、DNS 和配额检查。
        if (!_completeManifest(
          upstream.statusCode,
          upstream.headers.value(HttpHeaders.contentRangeHeader),
          body.length,
        )) {
          if (fullManifest) {
            await _fail(request, 502, '清单重试仍不是完整响应');
          } else {
            await _forward(
              request,
              session,
              logicalCurrent,
              fullManifest: true,
              verifiedWireTarget: currentWireTarget,
            );
          }
          return;
        }
      }
      final decoded = utf8.decode(body, allowMalformed: true);
      final originalText = decoded.replaceFirst(RegExp(r'^[\s\uFEFF]*'), '');
      final evidence = collectAdPlaylistEvidence(originalText, logicalCurrent);
      if (!evidence.isEmpty) {
        _mediaPlaylists[session.fingerprint] = AiPlaylistSnapshot(
          playlist: logicalCurrent,
          evidence: evidence,
          siteKey: session.siteKey,
          sessionFingerprint: session.fingerprint,
        );
        while (_mediaPlaylists.length > 32) {
          _mediaPlaylists.remove(_mediaPlaylists.keys.first);
        }
      }
      final effectiveRules = session.fingerprint == aiSessionFingerprint
          ? AdRuleSet(
              adHosts: adRules.adHosts,
              hlsRules: [...adRules.hlsRules, ...aiSessionRules.hlsRules],
            )
          : adRules;
      final cleaned = cleanHlsPlaylist(
        text: originalText,
        playlistUri: logicalCurrent,
        rules: effectiveRules,
      );
      _indexPrefetch(session, logicalCurrent, cleaned.text);
      final rewritten = _aliasPngTsMedia(
        session,
        HlsPlaylistRewriter.rewrite(
          cleaned.text,
          logicalCurrent,
          (child) => _proxifyForManifest(session, child),
        ),
      );
      final bytes = utf8.encode(rewritten);
      _logPlaylistShape(
        session,
        upstreamText: originalText,
        cleaned: cleaned,
        upstreamBytes: body.length,
        bytes: bytes.length,
      );
      // 重写后的清单是**新的实体**，必须按 200 完整返回。
      //
      // 绝不能转发上游的 `Content-Range`：上游用 `Range: bytes=0-` 回 206，
      // 声明的是**它那份**清单的长度（实测 `bytes 0-24522/24523`），而重写后
      // 的正文是 240311 字节（每条分片 URI 换成了代理地址）。播放器按声明长度
      // 截断后，末尾的 `#EXT-X-ENDLIST` 永远读不到——HLS 会被当成直播，引擎上报
      // 的时长变成「已播 + 缓冲」的爬升值，进度条从此失真、拖动也没了（§11.4）。
      response.statusCode = HttpStatus.ok;
      _copySafeHeaders(
        response,
        upstream,
        contentLength: bytes.length,
        synthesizedBody: true,
      );
      response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      response.headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}');
      final signature = HlsPlaylistRewriter.sniffPlaylistPrefix(
        body.take(256).toList(),
      );
      if (signature == true) {
        session.recordHlsPath(request.uri.path);
      } else {
        session.clearHlsPath(request.uri.path);
      }
      response.add(bytes);
      await response.close();
      _record(
        session,
        target,
        statusCode: upstream.statusCode,
        upstreamStatus: upstream.statusCode,
        downstreamStatus: response.statusCode,
        bytes: bytes.length,
        elapsed: stopwatch.elapsed,
        range: range,
        note: cleaned.changed
            ? 'hls-rewrite ad-block(-${cleaned.removedSegments})'
            : 'hls-rewrite',
      );
      return;
    }

    _PngBody? png;
    final inspectMedia =
        (session.targetResolver != null || session.inspectPlaylistContent) &&
        request.method == 'GET' &&
        session.allowsPngTsNormalization(mediaSource) &&
        (upstream.statusCode == 200 || upstream.statusCode == 206);
    if (inspectMedia) {
      try {
        final contentRange = upstream.headers.value(
          HttpHeaders.contentRangeHeader,
        );
        final startsAtZero =
            upstream.statusCode == 200 ||
            (contentRange != null &&
                RegExp(r'^bytes 0-').hasMatch(contentRange));
        png = await _sniffPng(
          bodyStream,
          session,
          request,
          knownLength: upstream.contentLength >= 0,
          inspect: startsAtZero,
          cancelSource: hlsCancel,
        );
        bodyStream = png.stream;
        var proven = png.offset != null;
        if (!proven &&
            !startsAtZero &&
            contentType.toLowerCase().split(';').first.trim() == 'image/png' &&
            !fullTransportStream) {
          proven = await _probePngPrefix(
            request,
            session,
            logicalCurrent,
            currentWireTarget!,
            currentWirePolicy!,
          );
        }
        _checkPngSession(session);
        if (!session.allowsPngTsNormalization(mediaSource)) {
          throw const _PngFailure(502);
        }
        final complete =
            upstream.statusCode == 200 ||
            (upstream.contentLength >= 0 &&
                _completeManifest(
                  upstream.statusCode,
                  contentRange,
                  upstream.contentLength,
                ));
        if (proven && (!complete || png.offset == null)) {
          await png.cancel();
          if (fullTransportStream) throw const _PngFailure(502);
          await _forward(
            request,
            session,
            logicalCurrent,
            fullTransportStream: true,
            transportStreamSource: mediaSource,
            verifiedWireTarget: currentWireTarget,
          );
          return;
        }
        if (fullTransportStream && !proven) throw const _PngFailure(502);
        if (proven) {
          response.statusCode = 200;
          _copySafeHeaders(
            response,
            upstream,
            contentLength: -1,
            synthesizedBody: true,
            dropCacheMetadata: true,
          );
          response.headers.contentType = ContentType('video', 'mp2t');
          if (upstream.contentLength >= 0) {
            response.contentLength = upstream.contentLength - png.offset!;
          }
          await _copyPngBody(response, png.stream, session);
          _record(
            session,
            target,
            statusCode: 200,
            elapsed: stopwatch.elapsed,
            range: range,
            note: 'png-ts-normalized',
          );
          return;
        }
      } on _PngFailure catch (error) {
        await png?.cancel();
        await _fail(request, error.status, '受管媒体完整响应无法确认');
        return;
      } catch (_) {
        await png?.cancel();
        await _fail(request, 502, '受管媒体读取失败');
        return;
      }
    } else if (fullTransportStream && upstream.statusCode < 400) {
      await _abortBody(bodyStream);
      await _fail(
        request,
        upstream.statusCode >= 400 ? upstream.statusCode : 502,
        '受管媒体完整响应无法确认',
      );
      return;
    }

    _copySafeHeaders(response, upstream, contentLength: upstream.contentLength);
    response.bufferOutput = false;
    var bytes = 0;
    try {
      if (png == null) {
        await response.addStream(
          bodyStream.map((chunk) {
            bytes += chunk.length;
            session.recordReceivedBytes(chunk.length);
            return chunk;
          }),
        );
      } else {
        await for (final chunk in bodyStream) {
          bytes += chunk.length;
          response.add(chunk);
          await response.flush().timeout(requestTimeout);
        }
      }
      await response.close();
    } catch (error) {
      // 异常流必须被关闭（§11.4）。
      log.warning('代理流转发中断：${error.runtimeType}', scope: 'proxy');
      try {
        await response.close();
      } catch (_) {}
    }
    await png?.cancel();
    await hlsCancel?.call();
    _record(
      session,
      target,
      statusCode: upstream.statusCode,
      upstreamStatus: upstream.statusCode,
      downstreamStatus: response.statusCode,
      bytes: bytes,
      elapsed: stopwatch.elapsed,
      range: range,
    );
  }

  /// 只在「严格 HttpClient 因重复/冲突分帧头失败」后调用一次。
  ///
  /// 约束：目标必须是本轮已通过策略与 DNS 复核的 `127.0.0.1:<映射端口>`；
  /// 方法（GET/HEAD）、Range 与会话注入头与严格请求完全一致；不跟随重定向；
  /// 正文流式转发，不整段缓冲。会话字节/请求配额由 [_serveTolerant] 照常记账。
  Future<void> _forwardTolerantly({
    required HttpRequest request,
    required ProxySession session,
    required Uri logicalTarget,
    required Uri wireTarget,
    required Map<String, String> headers,
    required String? range,
    required Stopwatch stopwatch,
  }) async {
    final String method = request.method == 'HEAD' ? 'HEAD' : 'GET';
    final TolerantHttpResponse upstream;
    try {
      upstream = await _tolerant.send(
        wireTarget: wireTarget,
        method: method,
        headers: headers,
        timeout: requestTimeout,
      );
    } on TolerantHttpException catch (error) {
      _record(
        session,
        logicalTarget,
        statusCode: 502,
        elapsed: stopwatch.elapsed,
        range: range,
        note: 'tolerant-${error.kind.name}',
      );
      await _fail(request, 502, _tolerantFailureMessage(error));
      return;
    } catch (error) {
      _record(
        session,
        logicalTarget,
        statusCode: 502,
        elapsed: stopwatch.elapsed,
        range: range,
        note: 'tolerant-error',
      );
      await _fail(request, 502, '请求上游失败：${error.runtimeType}');
      return;
    }

    try {
      await _serveTolerant(
        request: request,
        session: session,
        logicalTarget: logicalTarget,
        upstream: upstream,
        range: range,
        stopwatch: stopwatch,
      );
    } finally {
      await upstream.close();
    }
  }

  Future<void> _serveTolerant({
    required HttpRequest request,
    required ProxySession session,
    required Uri logicalTarget,
    required TolerantHttpResponse upstream,
    required String? range,
    required Stopwatch stopwatch,
  }) async {
    final contentType = upstream.headers[HttpHeaders.contentTypeHeader] ?? '';
    if (contentType.toLowerCase().contains('text/html') &&
        upstream.statusCode >= 200 &&
        upstream.statusCode < 300) {
      _record(
        session,
        logicalTarget,
        statusCode: 502,
        elapsed: stopwatch.elapsed,
        range: range,
        note: 'upstream-html',
      );
      await _fail(request, 502, '上游返回 HTML 页面而不是媒体数据');
      return;
    }
    // 清单在本路径不做二次重写：原样转发会把 guest 回环地址泄漏给播放器，
    // 静默降级比明确失败更危险，所以失败关闭。
    if (HlsPlaylistRewriter.looksLikePlaylist(
          contentType,
          logicalTarget.toString(),
        ) ||
        DashPlaylistRewriter.looksLikeManifest(
          contentType,
          logicalTarget.toString(),
        )) {
      _record(
        session,
        logicalTarget,
        statusCode: 502,
        elapsed: stopwatch.elapsed,
        range: range,
        note: 'tolerant-manifest',
      );
      await _fail(request, 502, '容错读取路径不接受清单响应：拒绝二次重写');
      return;
    }
    if (!session.accountRequest(
      upstream.contentLength >= 0 ? upstream.contentLength : 0,
    )) {
      _record(
        session,
        logicalTarget,
        statusCode: 429,
        elapsed: stopwatch.elapsed,
        range: range,
        note: 'session-limit',
      );
      await _fail(request, 429, '会话累计流量或请求数超过上限');
      return;
    }

    var bodyStream = upstream.body;
    if (request.method == 'GET' &&
        (upstream.statusCode == 200 || upstream.statusCode == 206)) {
      final sniffed = await _sniffHls(bodyStream, session, request);
      bodyStream = sniffed.stream;
      if (sniffed.oversized || sniffed.manifest != null) {
        if (sniffed.manifest != null) {
          session.recordReceivedBytes(sniffed.manifest!.length);
        }
        await _fail(request, 502, '容错读取路径不接受清单响应：拒绝二次重写');
        return;
      }
    }

    final response = request.response;
    response.statusCode = upstream.statusCode;
    _copyTolerantHeaders(
      response,
      upstream,
      headRequest: request.method == 'HEAD',
    );
    var bytes = 0;
    try {
      await for (final chunk in bodyStream) {
        bytes += chunk.length;
        session.recordReceivedBytes(chunk.length);
        response.add(chunk);
      }
      await response.close();
    } catch (error) {
      final failure = error is TolerantHttpException
          ? error.kind.name
          : error.runtimeType;
      log.warning('容错读取正文中断：$failure', scope: 'proxy');
      try {
        await response.close();
      } catch (_) {}
    }
    _record(
      session,
      logicalTarget,
      statusCode: upstream.statusCode,
      bytes: bytes,
      elapsed: stopwatch.elapsed,
      range: range,
      note: 'tolerant-read',
    );
  }

  /// 只转发与严格路径同一套白名单头（不含 `Set-Cookie` 等）。
  void _copyTolerantHeaders(
    HttpResponse response,
    TolerantHttpResponse upstream, {
    required bool headRequest,
  }) {
    const forwarded = [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.cacheControlHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
    ];
    for (final name in forwarded) {
      final value = upstream.headers[name.toLowerCase()];
      if (value != null) response.headers.set(name, value);
    }
    if (upstream.contentLength >= 0) {
      if (headRequest) {
        // HEAD 无正文：显式写头，避免 dart:io 按正文长度校验。
        response.headers.set(
          HttpHeaders.contentLengthHeader,
          '${upstream.contentLength}',
        );
      } else {
        response.contentLength = upstream.contentLength;
      }
    }
    if (upstream.statusCode == 206 &&
        upstream.contentLength >= 0 &&
        upstream.headers[HttpHeaders.contentRangeHeader.toLowerCase()] ==
            null) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${upstream.contentLength}',
      );
    }
  }

  static String _tolerantFailureMessage(TolerantHttpException error) {
    switch (error.kind) {
      case TolerantHttpFailureKind.framing:
        return UpstreamFramingFailure.message;
      case TolerantHttpFailureKind.redirect:
      case TolerantHttpFailureKind.protocol:
      case TolerantHttpFailureKind.connection:
      case TolerantHttpFailureKind.timeout:
        return error.message;
    }
  }

  /// 一条脱敏诊断：只写主机、端口与 token 指纹，不写 path/query/头取值。
  void _logFramingReject(ProxySession session, Uri logicalTarget) {
    log.warning(
      '上游响应头不合规（重复或冲突的 Content-Length）：严格解析拒绝 '
      'host=${_hostPort(logicalTarget)} token=${session.fingerprint}',
      scope: 'proxy',
    );
  }

  static String _hostPort(Uri target) =>
      target.hasPort ? '${target.host}:${target.port}' : target.host;

  /// 会话级传输授权只接受逻辑 HTTP(S) 目标；物理地址由代理构造。
  ProxyTargetDecision _managedLogicalDecision(Uri target) {
    if (!policy.allowedSchemes.contains(target.scheme.toLowerCase())) {
      return ProxyTargetDecision.deny('scheme 不受支持：${target.scheme}');
    }
    if (target.host.isEmpty) {
      return const ProxyTargetDecision.deny('缺少 host');
    }
    if (target.userInfo.isNotEmpty) {
      return const ProxyTargetDecision.deny('目标不得包含 userinfo');
    }
    if (ProxyTargetPolicy.cloudMetadataHosts.contains(
      target.host.toLowerCase(),
    )) {
      return const ProxyTargetDecision.deny('云元数据地址被拒绝');
    }
    return const ProxyTargetDecision.allow();
  }

  /// 会话级授权下，清单中的 HTTP(S) 子资源都必须先回到本会话 token，
  /// 绝不让 scoped guest 地址直接落到 PC 播放器；实际授权在取回时复核。
  int? _registeredManifestChild(ProxySession session, String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority || uri.origin != baseUrl) return null;
    final parts = uri.pathSegments;
    if (parts.length != 4 ||
        parts[0] != 'p' ||
        parts[1] != session.token ||
        parts[2] != 'i') {
      return null;
    }
    final index = int.tryParse(parts[3]);
    return index != null && session.childTargetAt(index) != null ? index : null;
  }

  String _aliasPngTsMedia(ProxySession session, String playlist) {
    if (!(session.targetResolver != null || session.inspectPlaylistContent)) {
      return playlist;
    }
    session.recordPngTsManifest();
    final lines = const LineSplitter().convert(playlist);
    final unsupported =
        lines.any(
          (line) => RegExp(
            r'^#EXT-X-(MAP:|BYTERANGE:|STREAM-INF:|SESSION-KEY:)',
            caseSensitive: false,
          ).hasMatch(line.trim()),
        ) ||
        lines.any(
          (line) =>
              line.trim().toUpperCase().startsWith('#EXT-X-KEY:') &&
              !RegExp(
                r'(?:[:,])\s*METHOD\s*=\s*NONE(?:,|$)',
                caseSensitive: false,
              ).hasMatch(line.trim()),
        );
    var media = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.toUpperCase().startsWith('#EXTINF:')) {
        media = true;
        continue;
      }
      if (line.startsWith('#')) {
        for (final match in RegExp(
          r'URI\s*=\s*"([^"]*)"',
          caseSensitive: false,
        ).allMatches(line)) {
          final index = _registeredManifestChild(session, match.group(1)!);
          if (index != null) session.excludePngTsChild(index);
        }
        continue;
      }
      if (line.isEmpty) continue;
      final index = _registeredManifestChild(session, line);
      if (index != null) {
        if (!unsupported && media && session.registerPngTsMediaAlias(index)) {
          lines[i] = '$line.ts';
        } else {
          session.excludePngTsChild(index);
        }
      }
      media = false;
    }
    return "${lines.join('\n')}\n";
  }

  String? _proxifyForManifest(ProxySession session, Uri child) {
    if (session.targetResolver != null &&
        (child.isScheme('http') || child.isScheme('https')) &&
        child.host.isNotEmpty &&
        child.userInfo.isEmpty) {
      return urlForChild(session, child);
    }
    return _proxify(session, child);
  }

  String? _directoryForManifest(ProxySession session, Uri directory) {
    if (session.targetResolver != null &&
        (directory.isScheme('http') || directory.isScheme('https')) &&
        directory.host.isNotEmpty &&
        directory.userInfo.isEmpty) {
      return urlForDirectory(session, directory);
    }
    if (!_manifestHostAllowed(session, directory)) return null;
    return urlForDirectory(session, directory);
  }

  /// 允许代理的子资源 URL。
  ///
  /// 只允许当前会话已确立来源的 host（HLS 常见做法是清单与分片同 host），
  /// 或站点显式授权的 host。返回 null 时清单中的该行保持原样。
  String? _proxify(ProxySession session, Uri child) {
    if (!_manifestHostAllowed(session, child)) return null;
    return urlForChild(session, child);
  }

  bool _manifestHostAllowed(ProxySession session, Uri child) {
    final host = child.host.toLowerCase();
    final established = session.establishedOrigin?.split(':').first;
    final allowed =
        session.allowedHosts.isEmpty ||
        session.allowedHosts.any(
          (entry) =>
              entry.toLowerCase() == host ||
              host.endsWith('.${entry.toLowerCase()}'),
        ) ||
        session.derivedHosts.any(
          (entry) => entry == host || host.endsWith('.$entry'),
        ) ||
        (established != null && established == host);
    return allowed;
  }

  Map<String, String> _forwardHeaders({
    required ProxySession session,
    required HttpRequest? request,
    required Uri target,
    required String? range,
    bool managed = false,
  }) {
    String credentialOrigin(Uri uri) => managed
        ? '${uri.scheme}://${uri.host}:${uri.port}'
        : '${uri.host}:${uri.port}';
    final origin =
        session.establishedOrigin ?? credentialOrigin(request?.uri ?? target);
    final targetOrigin = credentialOrigin(target);

    final headers = <String, String>{
      // 强制 identity：避免压缩后 Content-Range/Content-Length 与实际字节不符。
      HttpHeaders.acceptEncodingHeader: 'identity',
      HttpHeaders.cacheControlHeader: ?request?.headers.value(
        HttpHeaders.cacheControlHeader,
      ),
      HttpHeaders.pragmaHeader: ?request?.headers.value(
        HttpHeaders.pragmaHeader,
      ),
      'Range': ?range,
      'If-Range': ?request?.headers.value(HttpHeaders.ifRangeHeader),
      'If-None-Match': ?request?.headers.value(HttpHeaders.ifNoneMatchHeader),
      'If-Modified-Since': ?request?.headers.value(
        HttpHeaders.ifModifiedSinceHeader,
      ),
    };

    // User-Agent 可在会话内继承（§11.3.1）。
    final userAgent =
        session.userAgent ??
        request?.headers.value(HttpHeaders.userAgentHeader);
    if (userAgent != null) headers[HttpHeaders.userAgentHeader] = userAgent;
    // Referer 只在站点显式声明（会话注入）或与目标同主机时传播。
    // 播放器的 Referer 指向本地代理，跨域转发会触发防盗链 CDN 的 403
    // （§11.3.1「Referer 按显式域名授权传播」）。
    final referer =
        session.referer ??
        (request == null ? null : _sameHostReferer(request, target));
    if (referer != null) headers[HttpHeaders.refererHeader] = referer;

    // 凭据只同源传播；跨 origin 重定向已由 origin/targetOrigin 差异覆盖。
    final credentials = <String, String>{
      if (session.cookie != null) HttpHeaders.cookieHeader: session.cookie!,
      if (session.authorization != null)
        HttpHeaders.authorizationHeader: session.authorization!,
      ...session.extraHeaders,
    };
    headers.addAll(
      SensitiveHeaders.filter(
        headers: credentials,
        origin: origin,
        target: targetOrigin,
      ),
    );
    return headers;
  }

  /// 播放器携带的 Referer 只有与目标同主机时才可继承。
  static String? _sameHostReferer(HttpRequest request, Uri target) {
    final inherited = request.headers.value(HttpHeaders.refererHeader);
    if (inherited == null) return null;
    final parsed = Uri.tryParse(inherited);
    if (parsed == null || parsed.host.isEmpty) return null;
    return parsed.host.toLowerCase() == target.host.toLowerCase()
        ? inherited
        : null;
  }

  /// 复制可透传给播放器的上游 Header（白名单，§11.3.1）。
  ///
  /// [synthesizedBody] 为 true 表示正文是本地生成的（清单重写）：
  /// `Content-Range`/`Accept-Ranges`/`ETag`/`Last-Modified` 描述的都是**上游
  /// 那份**字节，与合成后的正文无关，一律不转发——否则播放器按上游长度截断，
  /// 合成正文的尾部（例如 `#EXT-X-ENDLIST`）永远读不到。
  void _checkPngSession(ProxySession session) {
    if (!identical(sessions.byToken(session.token), session) ||
        !session.usable) {
      throw const _PngFailure(401);
    }
  }

  Future<bool> _probePngPrefix(
    HttpRequest request,
    ProxySession session,
    Uri logical,
    Uri wire,
    ProxyTargetPolicy wirePolicy,
  ) async {
    HttpClientResponse? response;
    _PngBody? prefix;
    try {
      response = await _openPngPrefixProbe(
        request,
        session,
        logical,
        wire,
        wirePolicy,
      );
      if ((response.statusCode != 200 && response.statusCode != 206) ||
          (response.headers.value(HttpHeaders.contentTypeHeader) ?? '')
              .toLowerCase()
              .contains('text/html')) {
        return false;
      }
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      if (response.statusCode != 200 &&
          (range == null || !RegExp(r'^bytes 0-').hasMatch(range))) {
        return false;
      }
      prefix = await _sniffPng(
        response,
        session,
        request,
        knownLength: response.contentLength >= 0,
      );
      return prefix.offset != null;
    } on TimeoutException {
      _checkPngSession(session);
      return false;
    } on SocketException {
      _checkPngSession(session);
      return false;
    } on HttpException {
      _checkPngSession(session);
      return false;
    } finally {
      if (prefix != null) {
        await prefix.cancel();
      } else if (response != null) {
        await _abort(response);
      }
    }
  }

  Future<HttpClientResponse> _openPngPrefixProbe(
    HttpRequest request,
    ProxySession session,
    Uri logical,
    Uri wire,
    ProxyTargetPolicy wirePolicy,
  ) async {
    _checkPngSession(session);
    final resolver = session.targetResolver;
    if (resolver != null) {
      if (!_managedLogicalDecision(logical).allowed) {
        throw const _PngFailure(403);
      }
      final int? mappedPort;
      try {
        mappedPort = await resolver(logical).timeout(requestTimeout);
      } catch (_) {
        _checkPngSession(session);
        throw const _PngFailure(502);
      }
      _checkPngSession(session);
      final resolved = mappedPort == null
          ? logical
          : logical.replace(host: '127.0.0.1', port: mappedPort, userInfo: '');
      if (resolved != wire) throw const _PngFailure(502);
    }
    if (adRules.isAdHost(logical.host) ||
        !wirePolicy.evaluateStatic(wire).allowed) {
      throw const _PngFailure(403);
    }
    final addresses = await InternetAddress.lookup(wire.host)
        .timeout(requestTimeout);
    _checkPngSession(session);
    if (!wirePolicy.evaluateAll(addresses, wire.host).allowed) {
      throw const _PngFailure(403);
    }
    if (!session.accountRequest(0)) throw const _PngFailure(429);
    final outbound = await _upstream
        .openUrl('GET', wire)
        .timeout(requestTimeout);
    try {
      _checkPngSession(session);
      outbound.followRedirects = false;
      final headers = _forwardHeaders(
        session: session,
        request: request,
        target: logical,
        range: 'bytes=0-16383',
        managed: wire != logical,
      );
      headers.removeWhere(
        (name, _) => {
          HttpHeaders.ifRangeHeader,
          HttpHeaders.ifNoneMatchHeader,
          HttpHeaders.ifModifiedSinceHeader,
          HttpHeaders.ifMatchHeader,
          HttpHeaders.ifUnmodifiedSinceHeader,
        }.contains(name.toLowerCase()),
      );
      for (final entry in headers.entries) {
        outbound.headers.set(entry.key, entry.value);
      }
      final timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
        if (!session.usable ||
            !identical(sessions.byToken(session.token), session)) {
          outbound.abort();
        }
      });
      unawaited(
        request.response.done.then(
          (_) => outbound.abort(),
          onError: (Object _) => outbound.abort(),
        ),
      );
      final HttpClientResponse result;
      try {
        result = await outbound.close().timeout(requestTimeout);
        if (result.statusCode == 429) _disablePrefetchSession(session);
      } finally {
        timer.cancel();
      }
      try {
        _checkPngSession(session);
        if (result.contentLength > 0) session.bytes += result.contentLength;
        if (session.bytes > session.maxBytes) throw const _PngFailure(429);
        if (_isRedirect(result.statusCode)) throw const _PngFailure(502);
        return result;
      } catch (_) {
        await _abort(result);
        rethrow;
      }
    } catch (_) {
      outbound.abort();
      _checkPngSession(session);
      rethrow;
    }
  }

  Future<_PngBody> _sniffPng(
    Stream<List<int>> source,
    ProxySession session,
    HttpRequest request, {
    required bool knownLength,
    bool inspect = true,
    Future<void> Function()? cancelSource,
  }) async {
    final iterator = StreamIterator(
      cancelSource == null ? source.timeout(requestTimeout) : source,
    );
    _PngFailure? interrupted;
    var cancelled = false;
    late Timer timer;
    Future<void> cancel() async {
      if (cancelled) return;
      cancelled = true;
      timer.cancel();
      try {
        await cancelSource?.call();
      } catch (_) {}
      try {
        await iterator.cancel();
      } catch (_) {}
    }

    timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
      if (!session.usable ||
          !identical(sessions.byToken(session.token), session)) {
        interrupted = const _PngFailure(401);
        unawaited(cancel());
      }
    });
    unawaited(
      request.response.done.then(
        (_) => cancel(),
        onError: (Object _) => cancel(),
      ),
    );
    Future<bool> next() async {
      final available = await iterator.moveNext();
      _checkPngSession(session);
      if (interrupted != null) throw interrupted!;
      if (!available) return false;
      final count = iterator.current.length;
      session.recordReceivedBytes(count);
      if (!knownLength) {
        session.bytes += count;
        if (session.bytes > session.maxBytes) throw const _PngFailure(429);
      }
      return true;
    }

    final buffer = BytesBuilder(copy: false);
    List<int> pending = const [];
    final proof = PngWrappedTransportStreamProbe();
    try {
      if (inspect) {
        while (!proof.done && await next()) {
          final chunk = iterator.current;
          var consumed = 0;
          while (consumed < chunk.length && !proof.done) {
            proof.add(chunk[consumed++]);
          }
          buffer.add(chunk.sublist(0, consumed));
          if (consumed < chunk.length) pending = chunk.sublist(consumed);
        }
      }
      final prefix = buffer.takeBytes();
      Stream<List<int>> replay() async* {
        try {
          _checkPngSession(session);
          final start = proof.offset ?? 0;
          if (prefix.length > start) yield prefix.sublist(start);
          if (pending.isNotEmpty) yield pending;
          while (await next()) {
            yield iterator.current;
          }
        } finally {
          await cancel();
        }
      }

      return _PngBody(replay(), cancel, proof.offset);
    } catch (_) {
      await cancel();
      rethrow;
    }
  }

  Future<void> _copyPngBody(
    HttpResponse response,
    Stream<List<int>> source,
    ProxySession session,
  ) async {
    try {
      await for (final chunk in source) {
        _checkPngSession(session);
        response.add(chunk);
        await response.flush().timeout(requestTimeout);
      }
      await response.close();
    } catch (error) {
      log.warning('受管媒体流中断：${error.runtimeType}', scope: 'proxy');
      try {
        await response.close();
      } catch (_) {}
    }
  }

  void _copySafeHeaders(
    HttpResponse response,
    HttpClientResponse upstream, {
    required int contentLength,
    bool synthesizedBody = false,
    bool dropCacheMetadata = false,
  }) {
    final alwaysPass = [
      HttpHeaders.contentTypeHeader,
      if (!dropCacheMetadata) HttpHeaders.cacheControlHeader,
    ];
    const upstreamOnly = [
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.contentEncodingHeader,
    ];
    // 只复制已知安全的头，避免把上游 Set-Cookie 等透传给播放器。
    for (final name in [...alwaysPass, if (!synthesizedBody) ...upstreamOnly]) {
      final value = upstream.headers.value(name);
      if (value == null) continue;
      response.headers.set(name, value);
    }
    if (!synthesizedBody && contentLength >= 0) {
      response.contentLength = contentLength;
    }
    if (!synthesizedBody &&
        upstream.statusCode == 206 &&
        upstream.headers.value(HttpHeaders.contentRangeHeader) == null) {
      // 206 必须带 Content-Range，否则播放器无法定位（§11.4）。
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$contentLength',
      );
    }
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  /// 主动中止上游响应（不读完 body）。
  ///
  /// `drain()` 会读完整个 body；对 GB 级媒资流而言，这意味着连接会持续
  /// 占用几十秒到上百秒，调用方（mpv）早已超时。取消订阅会关闭底层连接。
  static Future<void> _abort(HttpClientResponse response) async {
    try {
      await response.listen(null).cancel();
    } catch (_) {
      // 连接可能已关闭。
    }
  }

  static bool _canInspectPlaylist(HttpClientResponse response) {
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding.toLowerCase() != 'identity') return false;
    if (response.statusCode == HttpStatus.ok) return true;
    if (response.statusCode != HttpStatus.partialContent) return false;
    final range = response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    final match = RegExp(r'^bytes 0-(\d+)/(\d+)$').firstMatch(range);
    return match != null &&
        int.parse(match.group(1)!) + 1 == int.parse(match.group(2)!);
  }

  Future<({bool isPlaylist, Stream<List<int>> body})> _inspectPlaylist(
    Stream<List<int>> body,
  ) async {
    final iterator = StreamIterator(body);
    final chunks = <List<int>>[];
    final prefix = <int>[];
    bool? isPlaylist;
    try {
      while (isPlaylist == null &&
          prefix.length < 256 &&
          await iterator.moveNext().timeout(requestTimeout)) {
        final chunk = iterator.current;
        chunks.add(chunk);
        for (final byte in chunk) {
          prefix.add(byte);
          isPlaylist = HlsPlaylistRewriter.sniffPlaylistPrefix(prefix);
          if (isPlaylist != null || prefix.length == 256) break;
        }
      }
    } catch (_) {
      await iterator.cancel();
      rethrow;
    }
    return (
      isPlaylist: isPlaylist == true,
      body: _replayInspectedBody(chunks, iterator),
    );
  }

  Stream<List<int>> _replayInspectedBody(
    List<List<int>> chunks,
    StreamIterator<List<int>> iterator,
  ) {
    Stream<List<int>> replay() async* {
      try {
        for (final chunk in chunks) {
          yield chunk;
        }
        while (await iterator.moveNext()) {
          yield iterator.current;
        }
      } finally {
        await iterator.cancel();
      }
    }

    late StreamSubscription<List<int>> subscription;
    late StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        subscription = replay().listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onPause: () => subscription.pause(),
      onResume: () => subscription.resume(),
      onCancel: () async {
        // Cancel moveNext before async* cancellation waits for that same read.
        try {
          await iterator.cancel();
          await subscription.cancel();
        } catch (error, stackTrace) {
          if (error is HttpException || error is SocketException) {
            log.warning('代理流取消中断：${error.runtimeType}', scope: 'proxy');
          } else {
            log.error('代理流取消异常：$error\n$stackTrace', scope: 'proxy');
          }
        }
      },
    );
    return controller.stream;
  }

  static bool _completeManifest(int status, String? range, int length) {
    if (status == 200) return true;
    if (status != 206 || range == null) return false;
    final match = RegExp(r'^bytes 0-(\d+)/(\d+)$').firstMatch(range);
    if (match == null) return false;
    final end = int.tryParse(match.group(1)!);
    final total = int.tryParse(match.group(2)!);
    return total == length && end == length - 1;
  }

  /// 未知类型清单最多暂存 1 MiB；未证明前超限则回放原始流，
  /// 已证明的超大清单失败关闭，绝不把 guest 子 URI 原样泄漏给播放器。
  Future<_SniffedHls> _sniffHls(
    Stream<List<int>> source,
    ProxySession session,
    HttpRequest request,
  ) async {
    const cap = 1024 * 1024;
    final iterator = StreamIterator(source.timeout(requestTimeout));
    Timer? timer;
    Future<void>? cancelling;
    Future<void> cancel() => cancelling ??= () async {
      timer?.cancel();
      try {
        await iterator.cancel();
      } catch (_) {}
    }();
    timer = Timer.periodic(const Duration(milliseconds: 25), (_) {
      if (!session.usable ||
          !identical(sessions.byToken(session.token), session)) {
        unawaited(cancel());
      }
    });
    unawaited(
      request.response.done.then(
        (_) => cancel(),
        onError: (Object _) => cancel(),
      ),
    );
    final buffer = BytesBuilder(copy: false);
    final probe = _HlsPrefixProbe();
    var replay = false;
    try {
      while (await iterator.moveNext()) {
        _checkPngSession(session);
        final chunk = iterator.current;
        final remaining = cap - buffer.length;
        for (final byte in chunk.take(remaining)) {
          probe.add(byte);
          if (probe.playlist != null) break;
        }
        if (probe.playlist == false || chunk.length > remaining) {
          if (probe.playlist == true) {
            session.recordReceivedBytes(buffer.length + chunk.length);
            return const _SniffedHls(oversized: true);
          }
          replay = true;
          return _SniffedHls(
            stream: _replayBody(iterator, buffer.takeBytes(), chunk, cancel),
            cancel: cancel,
          );
        }
        buffer.add(chunk);
      }
      _checkPngSession(session);
      final body = buffer.takeBytes();
      if (probe.playlist == true) return _SniffedHls(manifest: body);
      return _SniffedHls(stream: Stream.value(body));
    } finally {
      if (!replay) await cancel();
    }
  }

  static Stream<List<int>> _replayBody(
    StreamIterator<List<int>> iterator,
    List<int> prefix,
    List<int> pending,
    Future<void> Function() cancel,
  ) async* {
    try {
      if (prefix.isNotEmpty) yield prefix;
      yield pending;
      while (await iterator.moveNext()) {
        yield iterator.current;
      }
    } finally {
      await cancel();
    }
  }

  static Future<void> _abortBody(Stream<List<int>> body) async {
    await body.listen(null).cancel();
  }

  Future<List<int>> _readAll(
    Stream<List<int>> response, {
    String manifestType = 'HLS',
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > 16 * 1024 * 1024) {
        throw StateError('$manifestType 清单超过 16 MiB');
      }
    }
    return builder.takeBytes();
  }

  Future<void> _fail(
    HttpRequest request,
    int statusCode,
    String message,
  ) async {
    final response = request.response;
    response.statusCode = statusCode;
    log.debug('代理拒绝 downstreamStatus=$statusCode', scope: 'proxy');
    response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    final body = utf8.encode(
      jsonEncode({'status': statusCode, 'msg': message}),
    );
    response.headers.set(HttpHeaders.contentLengthHeader, '${body.length}');
    response.add(body);
    await response.close();
  }

  void _record(
    ProxySession session,
    Uri target, {
    required int statusCode,
    int? upstreamStatus,
    int? downstreamStatus,
    int bytes = 0,
    Duration elapsed = Duration.zero,
    String? range,
    String? note,
  }) {
    final record = ProxyLogRecord(
      tokenFingerprint: session.fingerprint,
      targetHost: '${target.host}:${target.port}',
      statusCode: statusCode,
      upstreamStatus: upstreamStatus,
      downstreamStatus: downstreamStatus ?? statusCode,
      bytes: bytes,
      elapsed: elapsed,
      range: range,
      siteKey: session.siteKey,
      note: note,
    );
    log.debug('代理 ${record.line}', scope: 'proxy');
  }

  /// 记录清单形状（诊断用：只写标签事实，不写任何 URL，§11.3.1）。
  ///
  /// 为什么必须记：进度条总长只能取自播放引擎，而 HLS 线路的引擎时长会骗人
  /// ——实测同一部两小时的片子，载入时引擎只报 1.78s / 4.14s，界面把这句话
  /// 当成总长之后拇指被钳在末端不再跟随。清单侧的事实（段数、Σ `#EXTINF`、
  /// 有无 `#EXT-X-ENDLIST`）是唯一能区分「引擎算错」与「清单本来就只有两分钟」
  /// 的证据，两种情况的修法相反，所以每次重写都留一行。
  void _logPlaylistShape(
    ProxySession session, {
    required String upstreamText,
    required HlsCleanResult cleaned,
    required int upstreamBytes,
    required int bytes,
  }) {
    // 引擎真正读的是清洗后的清单，所以形状以它为准：广告被删掉之后，引擎
    // 本该上报的总长是「删完之后」的 Σ `#EXTINF`，不是上游那一份。
    final played = HlsPlaylistShape.parse(cleaned.text);
    log.debug(
      '清单形状 token=${session.fingerprint} ${played.summary} '
      'upstreamBytes=$upstreamBytes bytes=$bytes '
      'adBlockRemoved=${cleaned.removedSegments}'
      '${cleaned.abandoned ? ' adBlockRollback=${cleaned.abandonReason}' : ''}',
      scope: 'proxy',
    );
    if (!cleaned.changed) return;
    // 删过分片时再记一条上游形状：否则「少了多少秒」只能靠猜。
    final upstream = HlsPlaylistShape.parse(upstreamText);
    log.debug(
      '清单形状（上游） token=${session.fingerprint} ${upstream.summary}',
      scope: 'proxy',
    );
  }

  static bool _isLoopback(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) return bytes[0] == 127;
    if (bytes.length == 16) {
      return bytes.sublist(0, 15).every((byte) => byte == 0) && bytes[15] == 1;
    }
    return false;
  }

  /// 日志用目标展示：不含 query（签名参数必须脱敏，§11.3.1）。
  static String redactProxyTarget(Uri target) {
    final buffer = StringBuffer('${target.scheme}://${target.host}');
    if (target.hasPort) buffer.write(':${target.port}');
    buffer.write(target.path.isEmpty ? '/' : target.path);
    if (target.hasQuery) buffer.write('?...');
    return buffer.toString();
  }
}

/// 顶层别名：历史页/播放恢复都从服务层取这个函数（`library_pages.dart`
/// 通过 `export` 继续对外暴露同名符号，老测试不用改 import）。
String restoreHistoryPlaybackTarget(String episodeId) =>
    LocalProxyServer.restoreHistoryPlaybackTarget(episodeId);

class _SniffedHls {
  const _SniffedHls({
    this.manifest,
    this.stream = const Stream.empty(),
    this.oversized = false,
    this.cancel,
  });

  final List<int>? manifest;
  final Stream<List<int>> stream;
  final bool oversized;
  final Future<void> Function()? cancel;
}

class _HlsPrefixProbe {
  static const marker = [35, 69, 88, 84, 77, 51, 85]; // #EXTM3U
  static const bom = [239, 187, 191];
  int _markerIndex = 0;
  int _bomIndex = 0;
  bool? playlist;

  void add(int byte) {
    if (playlist != null) return;
    if (_markerIndex == 0) {
      if (_bomIndex > 0 || byte == bom[0]) {
        if (byte != bom[_bomIndex]) {
          playlist = false;
        } else {
          _bomIndex = (_bomIndex + 1) % bom.length;
        }
        return;
      }
      if (byte == 32 || (byte >= 9 && byte <= 13)) return;
    }
    if (byte != marker[_markerIndex]) {
      playlist = false;
    } else if (++_markerIndex == marker.length) {
      playlist = true;
    }
  }
}

class _PngFailure implements Exception {
  const _PngFailure(this.status);
  final int status;
}

class _PngBody {
  const _PngBody(this.stream, this.cancel, this.offset);
  final Stream<List<int>> stream;
  final Future<void> Function() cancel;
  final int? offset;
}

class _PrefetchFreshness {
  _PrefetchFreshness(this.remaining) : clock = Stopwatch()..start();
  final Duration remaining;
  final Stopwatch clock;
  bool get isFresh => clock.elapsed < remaining;

  static _PrefetchFreshness? read(HttpHeaders headers, Duration responseDelay) {
    if (headers[HttpHeaders.varyHeader] != null ||
        headers[HttpHeaders.setCookieHeader] != null ||
        headers[HttpHeaders.pragmaHeader] != null) {
      return null;
    }
    String? value(String name) => headers[name]?.join(',');
    final directives = <String, String?>{};
    final control = value(HttpHeaders.cacheControlHeader);
    if (control != null) {
      for (final item in control.split(',')) {
        final separator = item.indexOf('=');
        final name = (separator < 0 ? item : item.substring(0, separator))
            .trim()
            .toLowerCase();
        if (!const {
              'public',
              'immutable',
              'must-revalidate',
              'proxy-revalidate',
              'no-transform',
              'max-age',
              's-maxage',
            }.contains(name) ||
            directives.containsKey(name)) {
          return null;
        }
        directives[name] = separator < 0
            ? null
            : item.substring(separator + 1).trim();
      }
    }
    final now = DateTime.now().toUtc();
    DateTime? date(String name) {
      final text = value(name);
      return text == null ? null : HttpDate.parse(text);
    }

    try {
      final sourceDate = date(HttpHeaders.dateHeader);
      final expires = date(HttpHeaders.expiresHeader);
      final ageText = value(HttpHeaders.ageHeader);
      var currentAge = Duration.zero;
      if (ageText != null) {
        if (!RegExp(r'^\d+$').hasMatch(ageText)) return null;
        final seconds = int.tryParse(ageText);
        if (seconds == null || seconds > 2147483647) return null;
        currentAge = Duration(seconds: seconds);
      }
      if (sourceDate != null && now.difference(sourceDate) > currentAge) {
        currentAge = now.difference(sourceDate);
      }
      currentAge += responseDelay;
      Duration? lifetime;
      for (final key in ['max-age', 's-maxage']) {
        if (!directives.containsKey(key)) continue;
        var text = directives[key];
        if (text != null &&
            text.length > 1 &&
            text.startsWith('"') &&
            text.endsWith('"')) {
          text = text.substring(1, text.length - 1);
        }
        if (text == null || !RegExp(r'^\d+$').hasMatch(text)) return null;
        final seconds = int.tryParse(text);
        if (seconds == null || seconds > 2147483647) return null;
        final candidate = Duration(seconds: seconds);
        if (lifetime == null || candidate < lifetime) lifetime = candidate;
      }
      if (expires != null) {
        final candidate = expires.difference(sourceDate ?? now);
        if (lifetime == null || candidate < lifetime) lifetime = candidate;
      }
      var remaining = (lifetime ?? const Duration(seconds: 30)) - currentAge;
      if (remaining <= Duration.zero) return null;
      if (remaining > const Duration(seconds: 30)) {
        remaining = const Duration(seconds: 30);
      }
      return _PrefetchFreshness(remaining);
    } on FormatException {
      return null;
    }
  }
}

class _CachedPrefetch {
  _CachedPrefetch(this.bytes, this.contentType, this.freshness);
  final Uint8List bytes;
  final String contentType;
  final _PrefetchFreshness freshness;
}

class _PrefetchSession {
  _PrefetchSession(this.session);
  final ProxySession session;
  bool disabled = false;
  int bytes = 0;
  final indexes = <Uri, _HlsPrefetchIndex>{};
  final masterPlaylists = <Uri>{};
  final cache = <Uri, _CachedPrefetch>{};
  final attempts = <Uri, _PrefetchAttempt>{};
}

class _PrefetchAttempt {
  int count = 0;
  final sinceStart = Stopwatch();
}

class _PrefetchWindow {
  int bytes = 0;
}

class _PrefetchJob {
  _PrefetchJob(this.state, this.uri, this.window);
  final _PrefetchSession state;
  final Uri uri;
  final _PrefetchWindow window;
}

class _PrefetchRun {
  _PrefetchRun(this.job);
  final _PrefetchJob job;
  final client = HttpClient()..autoUncompress = false;
  final done = Completer<void>();
  final _cancelled = Completer<void>();
  bool cancelled = false;
  Future<T> wait<T>(Future<T> pending) => Future.any([
    pending,
    _cancelled.future.then<T>((_) => throw const _PrefetchCancelled()),
  ]);
  void cancel() {
    cancelled = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    client.close(force: true);
  }
}

class _PrefetchCancelled implements Exception {
  const _PrefetchCancelled();
}

class _HlsPrefetchIndex {
  _HlsPrefetchIndex(this.segments, this.duration);
  final List<
    ({Uri uri, double start, double duration, Uri? key, Uri? initialization})
  >
  segments;
  final double duration;
  static _HlsPrefetchIndex? parse(Uri playlist, String text) {
    if (!text.startsWith('#EXTM3U') ||
        !text.contains('#EXT-X-ENDLIST') ||
        text.contains('#EXT-X-BYTERANGE') ||
        text.contains('#EXT-X-STREAM-INF')) {
      return null;
    }
    final segments =
        <
          ({
            Uri uri,
            double start,
            double duration,
            Uri? key,
            Uri? initialization,
          })
        >[];
    double start = 0;
    double? duration;
    Uri? key;
    Uri? initialization;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.startsWith('#EXTINF:')) {
        duration = double.tryParse(line.substring(8).split(',').first);
      } else if (line.startsWith('#EXT-X-MAP:') ||
          line.startsWith('#EXT-X-KEY:')) {
        final value = RegExp('URI="([^"]+)"').firstMatch(line)?.group(1);
        if (line.startsWith('#EXT-X-MAP:')) {
          if (value == null || line.contains('BYTERANGE=')) return null;
          initialization = playlist.resolve(value);
        } else {
          if (line.contains('METHOD=NONE')) {
            key = null;
          } else {
            if (value == null) return null;
            key = playlist.resolve(value);
          }
        }
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        if (duration == null || !duration.isFinite || duration <= 0) {
          return null;
        }
        segments.add((
          uri: playlist.resolve(line),
          start: start,
          duration: duration,
          key: key,
          initialization: initialization,
        ));
        start += duration;
        duration = null;
      }
    }
    return segments.isEmpty ? null : _HlsPrefetchIndex(segments, start);
  }
}
