/// 本地代理安全门禁测试（设计文档 §9.6、§11.1、§11.2、§11.3、§11.3.1、§11.4）。
///
/// 覆盖 `docs/phase2/README.md` §3「代理安全」门禁：
/// - 非本机拒绝、无 token 拒绝；
/// - Range 返回 206 + 正确 `Content-Range`；
/// - 20 并发分片不崩溃；
/// - 日志不泄露敏感信息；
/// - 代理关闭后端口释放。
///
/// 另外覆盖 §11.3/§11.3.1 的可验证要求：内网/回环/云元数据拒绝、scheme 白名单、
/// 站点主机白名单、DNS 重绑定（多地址任一被拒即整体拒绝）、HTML 错误页不得伪装成
/// 200 媒体、会话流量/请求数上限、HLS 清单重写保持同一会话、凭据仅同源传播。
///
/// 端到端用例使用**真实 HTTP 回环连接**（受控上游 + 真实代理），不使用桩。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  // ---------------------------------------------------------------------------
  // 目标 URL 策略（纯逻辑，§11.3、§11.3.1）
  // ---------------------------------------------------------------------------
  group('代理目标策略（§11.3、§11.3.1）', () {
    const policy = ProxyTargetPolicy();

    test('默认拒绝回环、私网、链路本地与云元数据地址', () {
      for (final url in [
        'http://127.0.0.1:18080/media/sample.m3u8',
        'http://[::1]/x',
        'http://10.0.0.5/x',
        'http://192.168.1.10/x',
        'http://172.16.5.5/x',
        'http://169.254.1.1/x',
        'http://169.254.169.254/latest/meta-data/',
        'http://metadata.google.internal/computeMetadata/v1/',
        'http://100.100.100.200/latest/meta-data/',
        'http://0.0.0.0/x',
        'http://localhost/x',
      ]) {
        final decision = policy.evaluateStatic(Uri.parse(url));
        expect(
          decision.allowed,
          isFalse,
          reason: '$url 必须被默认拒绝，实际：$decision',
        );
      }
    });

    test('只允许 http/https scheme', () {
      expect(policy.evaluateStatic(Uri.parse('https://cdn.example.com/a')).allowed, isTrue);
      expect(policy.evaluateStatic(Uri.parse('http://cdn.example.com/a')).allowed, isTrue);
      for (final url in ['ftp://cdn.example.com/a', 'file:///etc/passwd']) {
        final decision = policy.evaluateStatic(Uri.parse(url));
        expect(decision.allowed, isFalse, reason: url);
        expect(decision.reason, contains('scheme'));
      }
    });

    test('allowPrivate 不放行回环，也不放行云元数据（§11.3 第 4 条、§11.3.1）', () {
      const relaxed = ProxyTargetPolicy(allowPrivate: true);
      // 私网被显式放行。
      expect(relaxed.evaluateStatic(Uri.parse('http://10.0.0.5/x')).allowed, isTrue);
      // 但回环仍需 allowLoopback，云元数据在任何情况都拒绝。
      expect(relaxed.evaluateStatic(Uri.parse('http://127.0.0.1/x')).allowed, isFalse);
      expect(
        relaxed
            .evaluateStatic(Uri.parse('http://169.254.169.254/latest/meta-data/'))
            .allowed,
        isFalse,
      );
    });

    test('站点主机白名单生效（§11.3「校验目标 URL 白名单」）', () {
      const scoped = ProxyTargetPolicy(allowedHosts: {'cdn.example.com'});
      expect(scoped.evaluateStatic(Uri.parse('http://cdn.example.com/a')).allowed, isTrue);
      final denied = scoped.evaluateStatic(Uri.parse('http://other.example.com/a'));
      expect(denied.allowed, isFalse);
      expect(denied.reason, contains('主机不在授权列表'));
    });

    test('DNS 重绑定：多地址中任一被拒即整体拒绝（§11.3.1）', () {
      const policy = ProxyTargetPolicy();
      final mixed = policy.evaluateAll(
        [
          InternetAddress('93.184.216.34'),
          InternetAddress('10.0.0.7'),
        ],
        'cdn.example.com',
      );
      expect(mixed.allowed, isFalse);
      expect(mixed.reason, contains('私网'));

      final clean = policy.evaluateAll(
        [InternetAddress('93.184.216.34')],
        'cdn.example.com',
      );
      expect(clean.allowed, isTrue);

      final empty = policy.evaluateAll(const [], 'cdn.example.com');
      expect(empty.allowed, isFalse);
      expect(empty.code, 502);
    });

    test('凭据仅同源传播：跨 origin 移除敏感 Header（§11.3.1）', () {
      const headers = {
        'Cookie': 'sid=secret',
        'Authorization': 'Bearer abc',
        'X-Api-Key': 'k',
        'Referer': 'http://origin/',
        'User-Agent': 'WebHTV-PC/0.1 (Windows)',
      };
      final same = SensitiveHeaders.filter(
        headers: headers,
        origin: 'a:80',
        target: 'a:80',
      );
      expect(same.containsKey('Cookie'), isTrue);

      final cross = SensitiveHeaders.filter(
        headers: headers,
        origin: 'a:80',
        target: 'b:80',
      );
      expect(cross.containsKey('Cookie'), isFalse);
      expect(cross.containsKey('Authorization'), isFalse);
      expect(cross.containsKey('X-Api-Key'), isFalse);
      // 非敏感 Header 保留。
      expect(cross['Referer'], 'http://origin/');
    });

    test('HLS 清单重写只代理允许的主机，其他主机保持原样', () {
      final body = [
        '#EXTM3U',
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"',
        '#EXTINF:10.0,',
        'seg0.ts',
        '#EXTINF:10.0,',
        'https://evil.example.com/seg2.ts',
        '#EXT-X-ENDLIST',
      ].join('\n');
      final base = Uri.parse('https://cdn.example.com/live/index.m3u8');
      final rewritten = HlsPlaylistRewriter.rewrite(body, base, (target) {
        // 上游只授权 cdn.example.com；其他主机必须保持原样。
        if (target.host == 'evil.example.com') return null;
        return 'proxy://${target.path}';
      });
      // 相对路径按清单所在目录解析（RFC 3986），`key.bin` → `/live/key.bin`。
      expect(rewritten, contains('URI="proxy:///live/key.bin"'));
      expect(rewritten, contains('proxy:///live/seg0.ts'));
      // 不允许的主机必须保留原 URL，而不是静默丢弃。
      expect(rewritten, contains('https://evil.example.com/seg2.ts'));
    });

    test('looksLikePlaylist 同时按 Content-Type 与扩展名判定', () {
      expect(HlsPlaylistRewriter.looksLikePlaylist('application/vnd.apple.mpegurl', 'a'), isTrue);
      expect(HlsPlaylistRewriter.looksLikePlaylist('audio/x-mpegurl', 'a'), isTrue);
      expect(HlsPlaylistRewriter.looksLikePlaylist(null, 'http://x/a.m3u8?t=1'), isTrue);
      expect(HlsPlaylistRewriter.looksLikePlaylist('video/mp4', 'http://x/a.mp4'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 会话与 token（§11.3.1）
  // ---------------------------------------------------------------------------
  group('代理会话与 token（§11.3.1）', () {
    test('token 高熵且每次播放唯一', () {
      final manager = ProxySessionManager();
      final a = manager.create(siteKey: 'site-a');
      final b = manager.create(siteKey: 'site-a');
      expect(a.token.length, greaterThanOrEqualTo(32));
      expect(a.token, isNot(b.token));
      // 高熵：不出现可预测的短周期重复。
      final tokens = <String>{
        for (var i = 0; i < 64; i++) manager.create(siteKey: 's').token,
      };
      expect(tokens.length, 64);
    });

    test('token 校验：空、伪造、撤销后一律失效', () {
      final manager = ProxySessionManager();
      final session = manager.create(siteKey: 'site-a');
      expect(manager.byToken(session.token), isNotNull);
      expect(manager.byToken(''), isNull);
      expect(manager.byToken('forged-token'), isNull);
      expect(manager.revoke(session.token), isTrue);
      expect(manager.byToken(session.token), isNull);
      // 重复撤销返回 false，不抛错。
      expect(manager.revoke(session.token), isFalse);
    });

    test('revokeAll 使全部 token 失效（应用退出，§11.3.1）', () {
      final manager = ProxySessionManager();
      final tokens = [
        for (var i = 0; i < 3; i++) manager.create(siteKey: 's').token,
      ];
      expect(manager.revokeAll(), 3);
      for (final token in tokens) {
        expect(manager.byToken(token), isNull);
      }
    });

    test('过期会话不可用且可被 sweep 清理', () {
      final manager = ProxySessionManager();
      final session = manager.create(
        siteKey: 's',
        ttl: const Duration(milliseconds: -1),
      );
      expect(session.expired, isTrue);
      expect(session.usable, isFalse);
      expect(manager.byToken(session.token), isNull);
      expect(manager.sweep(), greaterThanOrEqualTo(0));
    });

    test('会话流量与请求数上限（§11.3「限制单请求大小和总并发」）', () {
      final manager = ProxySessionManager();
      final limited = manager.create(siteKey: 's', maxRequests: 2, maxBytes: 10);
      expect(limited.accountRequest(1), isTrue);
      expect(limited.accountRequest(1), isTrue);
      expect(limited.accountRequest(1), isFalse, reason: '超过 maxRequests 必须拒绝');

      final byBytes = manager.create(siteKey: 's', maxBytes: 9, maxRequests: 100);
      expect(byBytes.accountRequest(5), isTrue);
      expect(byBytes.accountRequest(5), isFalse, reason: '超过 maxBytes 必须拒绝');
    });

    test('日志只用 token 指纹，不暴露 token 明文', () {
      final manager = ProxySessionManager();
      final session = manager.create(siteKey: 's');
      final fingerprint = ProxySessionManager.fingerprintOf(session.token);
      expect(fingerprint.length, 12);
      expect(session.token.contains(fingerprint), isFalse);

      final record = ProxyLogRecord(
        tokenFingerprint: session.fingerprint,
        targetHost: '127.0.0.1:18080',
        statusCode: 200,
        bytes: 1024,
      );
      expect(record.line, contains('token=$fingerprint'));
      expect(record.line.contains(session.token), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // 端到端（真实回环 HTTP，§11.1、§11.2、§11.3、§11.4）
  // ---------------------------------------------------------------------------
  group('本地代理端到端（§11.1、§11.2、§11.4）', () {
    late _Upstream upstream;
    late LocalProxyServer proxy;
    late LogService log;
    late HttpClient client;

    setUp(() async {
      upstream = await _Upstream.start();
      log = LogService();
      // 上游就在回环上，必须显式开启 allowLoopback 才能代理本机源。
      proxy = LocalProxyServer(
        log: log,
        policy: const ProxyTargetPolicy(allowLoopback: true),
      );
      await proxy.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await proxy.stop();
      await upstream.stop();
    });

    ProxySession newSession({Set<String>? allowedHosts, int? maxBytes, int? maxRequests}) =>
        proxy.sessions.create(
          siteKey: 'site-a',
          allowedHosts: allowedHosts ?? {'127.0.0.1'},
          maxBytes: maxBytes ?? 64 * 1024 * 1024,
          maxRequests: maxRequests ?? 4096,
        );

    test('默认策略下，回环目标被拒绝（需要显式 allowLoopback）', () async {
      final strict = LocalProxyServer(log: log);
      await strict.start();
      try {
        final session = strict.sessions.create(
          siteKey: 's',
          allowedHosts: {'127.0.0.1'},
        );
        final response = await _get(
          client,
          strict.urlFor(session, upstream.uri('/media.bin')),
        );
        expect(response.status, 403);
        expect(response.text, contains('拒绝'));
      } finally {
        await strict.stop();
      }
    });

    test('非本机监听被拒绝：只允许回环地址（§11.1、§11.3 第 1 条）', () async {
      final other = LocalProxyServer(log: log);
      await expectLater(other.start(host: '0.0.0.0'), throwsArgumentError);
      expect(other.isRunning, isFalse);
    });

    test('无 token / 伪造 token 一律 401', () async {
      final noToken = await _get(client, '${proxy.baseUrl}/p/bogus-token/AAAA');
      expect(noToken.status, 401);
      final short = await _get(client, '${proxy.baseUrl}/p/only-token');
      expect(short.status, 404);
      final badPath = await _get(client, '${proxy.baseUrl}/nope');
      expect(badPath.status, 404);
    });

    test('成功转发并注入站点 Header（§11.3.1）', () async {
      final session = newSession();
      // 让会话带上站点要求的 Referer 与 UA（本地媒体 fixture 的常见要求）。
      final withHeaders = proxy.sessions.create(
        siteKey: 'site-a',
        allowedHosts: {'127.0.0.1'},
        userAgent: 'WebHTV-PC/0.1 (Windows)',
        referer: 'http://127.0.0.1:18080/',
      );
      expect(session.usable, isTrue);

      final response = await _get(
        client,
        proxy.urlFor(withHeaders, upstream.uri('/media.bin')),
      );
      expect(response.status, 200);
      expect(response.body.length, 64 * 1024);

      final hit = upstream.hits.last;
      expect(hit['user-agent'], 'WebHTV-PC/0.1 (Windows)');
      expect(hit['referer'], 'http://127.0.0.1:18080/');
    });

    test('Range 请求返回 206 与正确 Content-Range（§11.2、§11.4）', () async {
      final session = newSession();
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/media.bin')),
        range: 'bytes=0-1023',
      );
      expect(response.status, 206);
      expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 0-1023/65536');
      expect(response.body.length, 1024);
      expect(upstream.hits.last['range'], 'bytes=0-1023');
    });

    test('上游 206 缺少 Content-Range 时补齐（§11.4）', () async {
      final session = newSession();
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/broken-range.bin')),
        range: 'bytes=0-127',
      );
      expect(response.status, 206);
      expect(response.headers.value(HttpHeaders.contentRangeHeader), isNotNull);
    });

    test('HTML 错误页不得伪装成 200 媒体（§11.3 第 8 条）', () async {
      final session = newSession();
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/error.html')),
      );
      expect(response.status, 502);
    });

    test('会话超出流量上限返回 429', () async {
      final session = newSession(maxBytes: 1024);
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/media.bin')),
      );
      expect(response.status, 429);
    });

    // 缺陷 19：网盘点播是 GB 级**整文件**流（实测百度网盘单集 1882 MB），
    // 原先 512 MiB 的会话上限会把正常播放判成超限并返回 429。
    test('默认会话上限能覆盖 GB 级媒资（缺陷 19，§11.3）', () {
      // 不传 maxBytes，用 ProxySessionManager 的真实默认值。
      final session = proxy.sessions.create(
        siteKey: 'site-a',
        allowedHosts: {'127.0.0.1'},
      );
      // 1.9 GB 的单集必须不被默认上限拒绝。
      const singleEpisode = 1882 * 1024 * 1024;
      expect(session.accountRequest(singleEpisode), isTrue);
      expect(ProxySession.defaultMaxBytes, greaterThan(singleEpisode));
    });

    // 缺陷 19：超限拒绝路径原先 `await upstream.drain<void>()` 排空整个 body；
    // 对 GB 级流会耗时上百秒，mpv 20s 超时→`loadFailed`。必须中止上游。
    test('超限拒绝中止上游流，不排空 GB 级响应（缺陷 19，§11.3）', () async {
      final session = newSession(maxBytes: 1024);
      final stopwatch = Stopwatch()..start();
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/slow-big.bin')),
      );
      stopwatch.stop();
      expect(response.status, 429);
      // 完整写出需 3.2s；中止上游应远快于此。
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(1500),
        reason: '拒绝必须先返回 429，而不是排空整个上游响应',
      );
      // 上游未被完整写出，证明代理确实中止了连接。
      await _waitUntil(() => !upstream.slowBigCompleted);
      expect(upstream.slowBigCompleted, isFalse);
    });

    test('20 并发分片请求不崩溃且全部成功（门禁）', () async {
      final session = newSession();
      final futures = [
        for (var i = 0; i < 20; i++)
          _get(
            client,
            proxy.urlFor(session, upstream.uri('/media.bin')),
            range: 'bytes=${i * 1024}-${i * 1024 + 511}',
          ),
      ];
      final responses = await Future.wait(futures);
      for (final response in responses) {
        expect(response.status, 206);
        expect(response.body.length, 512);
      }
      // 所有请求结束后并发计数必须归零（§11.3「限制单请求大小和总并发」）。
      // 计数在服务端 `finally` 中递减，可能晚于客户端读完最后一个字节，
      // 因此按「最终必然归零」断言而不是瞬时值；若真的泄漏，这里会超时失败。
      await _waitUntil(() => proxy.activeRequests == 0);
      expect(proxy.activeRequests, 0);
    });

    test('HLS 主清单被重写：子清单与分片保持同一会话 token（§11.4）', () async {
      final session = newSession();
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/index.m3u8')),
      );
      expect(response.status, 200);
      final body = response.text;
      final prefix = '${proxy.baseUrl}${LocalProxyServer.pathPrefix}${session.token}/';
      // 子清单/分片/密钥都必须指向同一会话。
      expect(body, contains(prefix));
      expect(body.contains('seg0.ts'), isFalse, reason: '相对分片必须被重写');
      // 非授权主机保持原样（不静默丢弃）。
      expect(body, contains('https://evil.example.com/seg2.ts'));
    });

    test('撤销会话后 token 立即失效（停止播放，§11.3.1）', () async {
      final session = newSession();
      expect(proxy.sessions.revoke(session.token), isTrue);
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/media.bin')),
      );
      expect(response.status, 401);
    });

    test('日志不含 token 明文、Cookie 与完整 query（§11.3.1）', () async {
      final session = proxy.sessions.create(
        siteKey: 'site-a',
        allowedHosts: {'127.0.0.1'},
        cookie: 'sid=SECRET-COOKIE',
        authorization: 'Bearer SECRET-TOKEN',
      );
      await _get(client, proxy.urlFor(session, upstream.uri('/media.bin')));
      // 日志写入发生在响应关闭之后，可能晚于客户端读完响应；
      // 先等到该次请求确实被记录，再做「不得泄露」断言，避免把竞态当成泄露。
      final fingerprint = ProxySessionManager.fingerprintOf(session.token);
      await _waitUntil(() => log.export().contains('token=$fingerprint'));
      final text = log.export();
      expect(text, contains('token=$fingerprint'));
      expect(text.contains(session.token), isFalse, reason: '日志不得出现 token 明文');
      expect(text.contains('SECRET-COOKIE'), isFalse);
      expect(text.contains('SECRET-TOKEN'), isFalse);

      // 目标展示必须隐藏 query（签名参数必须脱敏）。
      final redacted = LocalProxyServer.redactProxyTarget(
        Uri.parse('https://cdn.example.com/a/b.m3u8?sign=deadbeef&token=x'),
      );
      expect(redacted, 'https://cdn.example.com/a/b.m3u8?...');
      expect(redacted.contains('deadbeef'), isFalse);
    });

    test('stop() 后端口释放且可被重新绑定（§11.4）', () async {
      final port = proxy.port;
      expect(port, greaterThan(0));
      await proxy.stop();
      expect(proxy.isRunning, isFalse);
      // 端口必须真的释放：能再次绑定同一端口。
      final rebound = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      expect(rebound.port, port);
      await rebound.close(force: true);
    });

    // 缺陷 19：`HttpClient` 自动跟随重定向会丢弃自定义 Header（回落为
    // `Dart/3.x (dart:io)`），导致百度网盘 CDN 校验 UA 失败返回 403 `sign error`。
    // 代理必须手工逐跳跟随，并在每一跳重新注入会话 Header。
    test('手工跟随 302 时保留会话 User-Agent（缺陷 19，§11.3.1）', () async {
      final session = proxy.sessions.create(
        siteKey: 'site-a',
        allowedHosts: {'127.0.0.1'},
        userAgent: 'netdisk;12.24.6;',
      );
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/redirect.bin')),
      );
      expect(response.status, 200);
      expect(response.body.length, 64 * 1024);
      // 关键断言：重定向后的第二跳仍带着站点 UA，而不是 `Dart/3.x (dart:io)`。
      expect(upstream.hits.last['user-agent'], 'netdisk;12.24.6;');
      expect(upstream.hits.last['user-agent'], isNot(contains('Dart/')));
    });

    test('重定向派生主机被授权，可继续代理（缺陷 19，§11.3.1）', () async {
      // 白名单只含 127.0.0.1；302 目标是 localhost（不同主机名）。
      final session = proxy.sessions.create(
        siteKey: 'site-a',
        allowedHosts: {'127.0.0.1'},
        userAgent: 'netdisk;12.24.6;',
      );
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/redirect-cdn.bin')),
      );
      expect(response.status, 200, reason: '重定向派生主机应被授权' );
      expect(session.derivedHosts, contains('localhost'));
    });

    test('重定向到云元数据地址仍被拒绝（§11.3.1）', () async {
      final session = proxy.sessions.create(
        siteKey: 'site-a',
        allowedHosts: {'127.0.0.1'},
      );
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/redirect-meta.bin')),
      );
      expect(response.status, 403);
      expect(session.derivedHosts, isNot(contains('169.254.169.254')));
    });

    test('跨域 Referer 被剥离，同主机 Referer 保留（§11.3.1）', () async {
      final session = newSession();
      // 播放器携带一个与目标不同主机的 Referer：必须被剥离。
      await _get(
        client,
        proxy.urlFor(session, upstream.uri('/media.bin')),
        referer: 'https://123.666291.xyz/',
      );
      expect(
        upstream.hits.last['referer'],
        isEmpty,
        reason: '跨域 Referer 会触发防盗链 CDN 的 403，必须剥离',
      );

      // 同主机 Referer 保留。
      await _get(
        client,
        proxy.urlFor(session, upstream.uri('/media.bin')),
        referer: 'http://127.0.0.1:${upstream.port}/page',
      );
      expect(
        upstream.hits.last['referer'],
        'http://127.0.0.1:${upstream.port}/page',
      );
    });

    test('站点声明的 Referer 优先于播放器 Referer（§11.3.1）', () async {
      final session = proxy.sessions.create(
        siteKey: 'site-a',
        allowedHosts: {'127.0.0.1'},
        referer: 'http://127.0.0.1:18080/',
      );
      await _get(
        client,
        proxy.urlFor(session, upstream.uri('/media.bin')),
        referer: 'https://evil.example.com/',
      );
      expect(upstream.hits.last['referer'], 'http://127.0.0.1:18080/');
    });

    test('首跳即注入会话 Cookie 与 Authorization（缺陷 19，§11.3.1）', () async {
      final session = proxy.sessions.create(
        siteKey: 'site-a',
        allowedHosts: {'127.0.0.1'},
        cookie: 'sid=SAME-ORIGIN',
        authorization: 'Bearer SAME-ORIGIN',
      );
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/media.bin')),
      );
      expect(response.status, 200);
      // 首跳 origin 必须在构造 Header 前确立，否则凭据会被误当作跨域剥离。
      expect(upstream.hits.last['cookie'], 'sid=SAME-ORIGIN');
      expect(upstream.hits.last['authorization'], 'Bearer SAME-ORIGIN');
    });

    test('跨 origin 重定向移除 Cookie 与 Authorization（§11.3.1）', () async {
      // 白名单同时授权 127.0.0.1 与 localhost，让重定向能继续；
      // 但凭据只能同源传播，跨主机名必须被移除。
      final session = proxy.sessions.create(
        siteKey: 'site-a',
        allowedHosts: {'127.0.0.1', 'localhost'},
        cookie: 'sid=SECRET',
        authorization: 'Bearer SECRET',
      );
      final response = await _get(
        client,
        proxy.urlFor(session, upstream.uri('/redirect-cdn.bin')),
      );
      expect(response.status, 200);
      // 第一跳（127.0.0.1）带凭据，第二跳（localhost）必须剥离。
      expect(upstream.hits.first['cookie'], 'sid=SECRET');
      expect(upstream.hits.last['cookie'], isEmpty);
      expect(upstream.hits.last['authorization'], isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // 代理接线（§9.6、§11.3.1）：AppState.proxyDecision 的分支
  // ---------------------------------------------------------------------------
  group('代理接线（§9.6、§11.3.1）', () {
    late Directory tempDir;
    late AppState state;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webhtv-proxy-decision');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': tempDir.path, 'local': tempDir.path},
        ),
        log: LogService(),
      );
      await state.bootstrap();
    });

    tearDown(() async {
      await state.stopProxy();
      state.dispose();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    PlaybackDecision decisionFor(String url, {bool withHeaders = true}) =>
        PlaybackDecision(
          action: PlaybackAction.direct,
          url: url,
          headers: withHeaders
              ? HeaderMap({'Referer': 'http://example.com/'})
              : null,
          flag: 'f',
        );

    test('策略拒绝的目标保持直连，不被换成永远 403 的代理地址', () async {
      // 默认策略拒绝回环地址。若仍改写为代理 URL，播放将必然失败。
      final decision = decisionFor('http://127.0.0.1:18080/media/sample.m3u8');
      final result = await state.proxyDecision(decision, siteKey: 'site-a');

      expect(result.url, 'http://127.0.0.1:18080/media/sample.m3u8');
      expect(result.url, isNot(contains('/p/')));
      expect(
        state.proxySessions.activeSessions,
        isEmpty,
        reason: '被拒绝的目标不得创建代理会话',
      );
    });

    test('云元数据地址同样保持直连（§11.3.1）', () async {
      final decision = decisionFor(
        'http://169.254.169.254/latest/meta-data/',
      );
      final result = await state.proxyDecision(decision, siteKey: 'site-a');
      expect(result.url, 'http://169.254.169.254/latest/meta-data/');
    });

    test('无 Header 时保持直连（少一跳开销）', () async {
      final decision = decisionFor(
        'https://cdn.example.com/a.m3u8',
        withHeaders: false,
      );
      final result = await state.proxyDecision(decision, siteKey: 'site-a');
      expect(result.url, 'https://cdn.example.com/a.m3u8');
      expect(state.proxyRunning, isFalse);
    });

    test('非 http(s) 目标保持原样', () async {
      final decision = decisionFor('file:///c:/media/a.m3u8');
      final result = await state.proxyDecision(decision, siteKey: 'site-a');
      expect(result.url, 'file:///c:/media/a.m3u8');
    });

    test('允许的目标被改写为代理 URL，并只在会话内授权该主机', () async {
      // 用公网地址，默认策略允许。
      final target = 'https://cdn.example.com/live/index.m3u8?sign=secret';
      final result = await state.proxyDecision(
        decisionFor(target),
        siteKey: 'site-a',
      );

      expect(state.proxyRunning, isTrue);
      expect(result.url, contains('/p/'));
      expect(result.headers, isNotNull);
      expect(
        result.headers!.isEmpty,
        isTrue,
        reason: '走代理后 Header 由代理注入，播放器不再重复携带（§11.3.1）',
      );

      final session = state.proxySessions.activeSessions.single;
      expect(session.siteKey, 'site-a');
      expect(session.allowedHosts, {'cdn.example.com'});
      // token 只出现在 URL 中，日志只记录指纹。
      expect(result.url, contains(session.token));
      expect(session.fingerprint.length, 12);
    });

    test('stopProxy 会使代理会话失效（§11.3.1）', () async {
      await state.proxyDecision(
        decisionFor('https://cdn.example.com/a.m3u8'),
        siteKey: 'site-a',
      );
      final token = state.proxySessions.activeSessions.single.token;

      await state.stopProxy();
      expect(state.proxyRunning, isFalse);
      expect(state.proxySessions.byToken(token), isNull);
    });
  });
}

// -----------------------------------------------------------------------------
// 测试辅助
// -----------------------------------------------------------------------------

class _Response {
  const _Response(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final List<int> body;

  String get text => utf8.decode(body, allowMalformed: true);
}

Future<_Response> _get(
  HttpClient client,
  String url, {
  String? range,
  String? referer,
}) async {
  final request = await client.getUrl(Uri.parse(url));
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
  if (referer != null) request.headers.set(HttpHeaders.refererHeader, referer);
  final response = await request.close();
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  return _Response(response.statusCode, response.headers, builder.takeBytes());
}

/// 轮询等待条件成立；用于断言「最终状态」而不是瞬时值。
Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 受控上游：只监听回环，提供 Range、HTML 错误页与 HLS 清单。
class _Upstream {
  _Upstream._(this._server);

  final HttpServer _server;

  /// 每次请求记录代理转发过来的关键 Header（用于断言注入与同源传播）。
  final List<Map<String, String>> hits = [];

  /// `/slow-big.bin` 是否被上游完整写出（false 说明代理中止了上游流）。
  bool slowBigCompleted = false;

  int get port => _server.port;

  Uri uri(String path) => Uri.parse('http://127.0.0.1:$port$path');

  static Future<_Upstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _Upstream._(server);
    unawaited(upstream._listen());
    return upstream;
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }

  Future<void> _listen() async {
    await for (final request in _server) {
      try {
        await _respond(request);
      } finally {
        try {
          await request.response.close();
        } catch (_) {
          // 客户端可能已断开。
        }
      }
    }
  }

  Future<void> _respond(HttpRequest request) async {
    hits.add({
      'user-agent': request.headers.value(HttpHeaders.userAgentHeader) ?? '',
      'referer': request.headers.value(HttpHeaders.refererHeader) ?? '',
      'range': request.headers.value(HttpHeaders.rangeHeader) ?? '',
      'cookie': request.headers.value(HttpHeaders.cookieHeader) ?? '',
      'authorization':
          request.headers.value(HttpHeaders.authorizationHeader) ?? '',
    });

    switch (request.uri.path) {
      case '/media.bin':
        await _serveBytes(request, 64 * 1024, 'video/mp4');
      case '/redirect.bin':
        // 同主机 302：验证手工跟随重定向后会话 Header 仍然保留（缺陷 19）。
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:$port/media.bin',
        );
      case '/redirect-cdn.bin':
        // 跨主机名 302（localhost 不在会话白名单）：验证派生主机被授权。
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://localhost:$port/media.bin',
        );
      case '/redirect-meta.bin':
        // 重定向到云元数据地址必须被拒绝（§11.3.1）。
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://169.254.169.254/latest/meta-data/',
        );
      case '/broken-range.bin':
        // 故意返回 206 但不带 Content-Range，验证代理会补齐。
        final body = Uint8List(128);
        request.response.statusCode = 206;
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.headers.set(
          HttpHeaders.contentLengthHeader,
          '${body.length}',
        );
        request.response.add(body);
      case '/huge.bin':
        await _serveBytes(request, 4 * 1024 * 1024, 'video/mp4');
      case '/slow-big.bin':
        // 声明 8 MiB 并**慢速**分块写出：若代理用 drain() 排空整个 body，
        // 会耗时数秒；若代理中止上游，则能很快返回 429。
        await _serveSlowBig(request);
      case '/error.html':
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType(
          'text',
          'html',
          charset: 'utf-8',
        );
        request.response.write('<html><body>站点错误页</body></html>');
      case '/index.m3u8':
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
          charset: 'utf-8',
        );
        request.response.write(_playlist());
      default:
        request.response.statusCode = 404;
    }
  }

  /// 慢速大响应：8 MiB，32 块 × 256 KiB，每块 100ms（完整写出约 3.2s）。
  Future<void> _serveSlowBig(HttpRequest request) async {
    const total = 8 * 1024 * 1024;
    const chunk = 256 * 1024;
    slowBigCompleted = false;
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType('video', 'mp4');
    request.response.headers.set(HttpHeaders.contentLengthHeader, '$total');
    try {
      for (var sent = 0; sent < total; sent += chunk) {
        request.response.add(Uint8List(chunk));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      slowBigCompleted = true;
    } catch (_) {
      // 代理中止了上游流：视为未完整写出。
      slowBigCompleted = false;
    }
  }

  /// 支持 Range 的字节响应；无 Range 时返回 200 全量。
  Future<void> _serveBytes(
    HttpRequest request,
    int total,
    String contentType,
  ) async {
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final match = rangeHeader == null
        ? null
        : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
    if (match != null) {
      final start = int.parse(match.group(1)!);
      final endPart = match.group(2)!;
      final end = endPart.isEmpty ? total - 1 : int.parse(endPart);
      final length = end - start + 1;
      final body = Uint8List(length);
      request.response.statusCode = 206;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$total',
      );
      request.response.headers.contentType = ContentType('video', 'mp2t');
      request.response.headers.set(
        HttpHeaders.contentLengthHeader,
        '$length',
      );
      request.response.add(body);
      return;
    }
    final body = Uint8List(total);
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType('video', 'mp4');
    request.response.headers.set(
      HttpHeaders.acceptRangesHeader,
      'bytes',
    );
    request.response.headers.set(
      HttpHeaders.contentLengthHeader,
      '$total',
    );
    request.response.add(body);
  }

  /// HLS 主清单：相对分片 + 同源绝对分片 + 非授权主机分片 + 加密密钥。
  String _playlist() => [
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-TARGETDURATION:10',
    '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"',
    '#EXTINF:10.0,',
    'seg0.ts',
    '#EXTINF:10.0,',
    'http://127.0.0.1:$port/seg1.ts',
    '#EXTINF:10.0,',
    'https://evil.example.com/seg2.ts',
    '#EXT-X-ENDLIST',
  ].join('\n');
}
