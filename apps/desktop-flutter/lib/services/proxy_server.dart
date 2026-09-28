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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import '../core/proxy_policy.dart';
import 'log_service.dart';

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
  final ProxySessionManager sessions;
  final HttpClient _upstream;
  final Duration requestTimeout;

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

  /// 启动服务。只允许回环地址。
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

  /// 目标 URL 编码：base64url 无填充，避免路径分隔符与 query 干扰路由解析。
  static String encodeTarget(Uri target) =>
      base64Url.encode(utf8.encode(target.toString())).replaceAll('=', '');

  static Uri? decodeTarget(String encoded) {
    try {
      final padding = (4 - encoded.length % 4) % 4;
      final text = utf8.decode(
        base64Url.decode('$encoded${'=' * padding}'),
      );
      final uri = Uri.tryParse(text);
      if (uri == null || !uri.hasScheme) return null;
      return uri;
    } catch (_) {
      return null;
    }
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

    final target = decodeTarget(segments.sublist(2).join('/'));
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
      await _forward(request, session, target);
    } finally {
      _activeRequests -= 1;
    }
  }

  Future<void> _forward(
    HttpRequest request,
    ProxySession session,
    Uri target,
  ) async {
    final stopwatch = Stopwatch()..start();
    final range = request.headers.value(HttpHeaders.rangeHeader);
    // 会话级白名单优先于全局策略（§11.3.1「token 只授权当前站点与当前播放请求」）。
    final effectivePolicy = ProxyTargetPolicy(
      allowPrivate: policy.allowPrivate,
      allowLoopback: policy.allowLoopback,
      allowedHosts: session.allowedHosts.isEmpty
          ? policy.allowedHosts
          : session.allowedHosts,
      allowedSchemes: policy.allowedSchemes,
      maxRedirects: policy.maxRedirects,
    );

    var current = target;
    var redirects = 0;
    HttpClientResponse? upstream;
    String? denyReason;
    int denyCode = 403;

    while (true) {
      final staticDecision = effectivePolicy.evaluateStatic(current);
      if (!staticDecision.allowed) {
        denyReason = staticDecision.reason;
        denyCode = staticDecision.code;
        break;
      }
      // 每次连接前重新解析并复核全部地址，防 DNS 重绑定（§11.3.1）。
      final List<InternetAddress> addresses;
      try {
        addresses = await InternetAddress.lookup(current.host);
      } catch (error) {
        denyReason = 'DNS 解析失败：${current.host}';
        denyCode = 502;
        break;
      }
      final addressDecision = effectivePolicy.evaluateAll(addresses, current.host);
      if (!addressDecision.allowed) {
        denyReason = addressDecision.reason;
        denyCode = addressDecision.code;
        break;
      }

      final HttpClientRequest outbound;
      try {
        outbound = await _upstream
            .openUrl(request.method == 'HEAD' ? 'HEAD' : 'GET', current)
            .timeout(requestTimeout);
      } catch (error) {
        denyReason = '连接上游失败：${error.runtimeType}';
        denyCode = 502;
        break;
      }

      for (final entry in _forwardHeaders(
        session: session,
        request: request,
        target: current,
        range: range,
      ).entries) {
        outbound.headers.set(entry.key, entry.value);
      }
      if (current == target && session.establishedOrigin == null) {
        session.establishedOrigin = '${current.host}:${current.port}';
      }

      final HttpClientResponse response;
      try {
        response = await outbound.close().timeout(requestTimeout);
      } catch (error) {
        denyReason = '请求上游失败：${error.runtimeType}';
        denyCode = 502;
        break;
      }

      // 重定向：手工跟随并逐跳复核（§11.3.1）。
      if (_isRedirect(response.statusCode)) {
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
        final next = current.resolve(location);
        log.debug(
          '代理跟随重定向 href=${redactProxyTarget(next)} redirects=$redirects',
          scope: 'proxy',
        );
        current = next;
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
        elapsed: stopwatch.elapsed,
        range: range,
        note: denyReason ?? 'denied',
      );
      await _fail(request, denyCode, denyReason ?? '目标被拒绝');
      return;
    }

    // 4) HTML 错误页不得伪装成 200 媒体（§11.3 第 8 条）。
    final contentType = upstream.headers.value(HttpHeaders.contentTypeHeader) ?? '';
    final looksHtml = contentType.toLowerCase().contains('text/html');
    if (looksHtml && upstream.statusCode >= 200 && upstream.statusCode < 300) {
      await upstream.drain<void>();
      _record(
        session,
        target,
        statusCode: 502,
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
      await upstream.drain<void>();
      _record(
        session,
        target,
        statusCode: 429,
        elapsed: stopwatch.elapsed,
        range: range,
        note: 'session-limit',
      );
      await _fail(request, 429, '会话累计流量或请求数超过上限');
      return;
    }

    final response = request.response;
    response.statusCode = upstream.statusCode;

    final isPlaylist = HlsPlaylistRewriter.looksLikePlaylist(
      contentType,
      target.toString(),
    );

    if (isPlaylist) {
      // 清单必须整体读取后重写，保证子清单/分片 URL 走同一会话（§11.4）。
      final body = await _readAll(upstream);
      final rewritten = HlsPlaylistRewriter.rewrite(
        utf8.decode(body, allowMalformed: true),
        target,
        (child) => _proxify(session, child),
      );
      final bytes = utf8.encode(rewritten);
      _copySafeHeaders(response, upstream, contentLength: bytes.length);
      response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      response.headers.set(HttpHeaders.contentLengthHeader, '${bytes.length}');
      response.add(bytes);
      await response.close();
      _record(
        session,
        target,
        statusCode: upstream.statusCode,
        bytes: bytes.length,
        elapsed: stopwatch.elapsed,
        range: range,
        note: 'hls-rewrite',
      );
      return;
    }

    _copySafeHeaders(response, upstream, contentLength: upstream.contentLength);
    var bytes = 0;
    try {
      await for (final chunk in upstream) {
        bytes += chunk.length;
        response.add(chunk);
      }
      await response.close();
    } catch (error) {
      // 异常流必须被关闭（§11.4）。
      log.warning('代理流转发中断：$error', scope: 'proxy');
      try {
        await response.close();
      } catch (_) {}
    }
    _record(
      session,
      target,
      statusCode: upstream.statusCode,
      bytes: bytes,
      elapsed: stopwatch.elapsed,
      range: range,
    );
  }

  /// 允许代理的子资源 URL。
  ///
  /// 只允许当前会话已确立来源的 host（HLS 常见做法是清单与分片同 host），
  /// 或站点显式授权的 host。返回 null 时清单中的该行保持原样。
  String? _proxify(ProxySession session, Uri child) {
    final host = child.host.toLowerCase();
    final established = session.establishedOrigin?.split(':').first;
    final allowed =
        session.allowedHosts.isEmpty ||
        session.allowedHosts.any(
          (entry) =>
              entry.toLowerCase() == host ||
              host.endsWith('.${entry.toLowerCase()}'),
        ) ||
        (established != null && established == host);
    if (!allowed) return null;
    return urlFor(session, child);
  }

  Map<String, String> _forwardHeaders({
    required ProxySession session,
    required HttpRequest request,
    required Uri target,
    required String? range,
  }) {
    final origin = session.establishedOrigin ??
        '${request.uri.host}:${request.uri.port}';
    final targetOrigin = '${target.host}:${target.port}';

    final headers = <String, String>{
      // 强制 identity：避免压缩后 Content-Range/Content-Length 与实际字节不符。
      HttpHeaders.acceptEncodingHeader: 'identity',
      'Range': ?range,
      'If-Range': ?request.headers.value(HttpHeaders.ifRangeHeader),
      'If-None-Match': ?request.headers.value(HttpHeaders.ifNoneMatchHeader),
      'If-Modified-Since': ?request.headers.value(
        HttpHeaders.ifModifiedSinceHeader,
      ),
    };

    // 会话内允许继承 User-Agent 与 Referer（§11.3.1）。
    final userAgent = session.userAgent ??
        request.headers.value(HttpHeaders.userAgentHeader);
    if (userAgent != null) headers[HttpHeaders.userAgentHeader] = userAgent;
    final referer = session.referer ??
        request.headers.value(HttpHeaders.refererHeader);
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

  void _copySafeHeaders(
    HttpResponse response,
    HttpClientResponse upstream, {
    required int contentLength,
  }) {
    const passthrough = [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.lastModifiedHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.cacheControlHeader,
    ];
    // Host：只复制已知安全的头，避免把上游 Set-Cookie 等透传给播放器。
    for (final name in passthrough) {
      final value = upstream.headers.value(name);
      if (value == null) continue;
      response.headers.set(name, value);
    }
    if (upstream.statusCode == 206 &&
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

  Future<List<int>> _readAll(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > 16 * 1024 * 1024) {
        throw StateError('HLS 清单超过 16 MiB');
      }
    }
    return builder.takeBytes();
  }

  Future<void> _fail(HttpRequest request, int statusCode, String message) async {
    final response = request.response;
    response.statusCode = statusCode;
    response.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    final body = utf8.encode(jsonEncode({'status': statusCode, 'msg': message}));
    response.headers.set(HttpHeaders.contentLengthHeader, '${body.length}');
    response.add(body);
    await response.close();
  }

  void _record(
    ProxySession session,
    Uri target, {
    required int statusCode,
    int bytes = 0,
    Duration elapsed = Duration.zero,
    String? range,
    String? note,
  }) {
    final record = ProxyLogRecord(
      tokenFingerprint: session.fingerprint,
      targetHost: '${target.host}:${target.port}',
      statusCode: statusCode,
      bytes: bytes,
      elapsed: elapsed,
      range: range,
      siteKey: session.siteKey,
      note: note,
    );
    log.debug('代理 ${record.line}', scope: 'proxy');
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
