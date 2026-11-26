import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';

class _RequestJournal {
  int active = 0, maximum = 0;
  int? port;
  final events = <String>[];
  void Function() acquire(Uri uri) {
    if (uri.port != port) return () {};
    active++;
    if (active > maximum) maximum = active;
    events.add('open:${uri.path}:$active');
    var done = false;
    return () {
      if (done) return;
      done = true;
      active--;
      events.add('closed:${uri.path}:$active');
    };
  }
}

class _TrackedOverrides extends HttpOverrides {
  _TrackedOverrides(this.journal);
  final _RequestJournal journal;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _TrackedClient(super.createHttpClient(context), journal);
}

class _TrackedClient implements HttpClient {
  _TrackedClient(this.delegate, this.journal);
  final HttpClient delegate;
  final _RequestJournal journal;
  final releases = <void Function()>[];
  bool tracked = false;
  @override
  set idleTimeout(Duration value) => delegate.idleTimeout = value;
  @override
  set autoUncompress(bool value) => delegate.autoUncompress = value;
  @override
  set connectionTimeout(Duration? value) => delegate.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) => openUrl('GET', uri);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    final request = await delegate.openUrl(method, uri);
    final release = journal.acquire(uri);
    if (uri.port == journal.port) tracked = true;
    releases.add(release);
    return _TrackedRequest(request, release);
  }

  @override
  void close({bool force = false}) {
    delegate.close(force: force);
    if (force && tracked) journal.events.add('force-close');
    if (force) {
      for (final release in releases) {
        release();
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected tracked client call ${invocation.memberName}',
  );
}

class _TrackedRequest implements HttpClientRequest {
  _TrackedRequest(this.delegate, this.release);
  final HttpClientRequest delegate;
  final void Function() release;
  @override
  HttpHeaders get headers => delegate.headers;
  @override
  set followRedirects(bool value) => delegate.followRedirects = value;
  @override
  Future<HttpClientResponse> close() async {
    try {
      return _TrackedResponse(await delegate.close(), release);
    } catch (_) {
      release();
      rethrow;
    }
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    delegate.abort(exception, stackTrace);
    release();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected tracked request call ${invocation.memberName}',
  );
}

class _TrackedResponse extends Stream<List<int>> implements HttpClientResponse {
  _TrackedResponse(this.delegate, this.release);
  final HttpClientResponse delegate;
  final void Function() release;
  @override
  int get statusCode => delegate.statusCode;
  @override
  HttpHeaders get headers => delegate.headers;
  @override
  int get contentLength => delegate.contentLength;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _TrackedSubscription(
    delegate.listen(
      onData,
      onError: onError,
      onDone: () {
        release();
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    ),
    release,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected tracked response call ${invocation.memberName}',
  );
}

class _TrackedSubscription implements StreamSubscription<List<int>> {
  _TrackedSubscription(this.delegate, this.release);
  final StreamSubscription<List<int>> delegate;
  final void Function() release;
  @override
  Future<void> cancel() async {
    try {
      await delegate.cancel();
    } finally {
      release();
    }
  }

  @override
  bool get isPaused => delegate.isPaused;
  @override
  void pause([Future<void>? signal]) => delegate.pause(signal);
  @override
  void resume() => delegate.resume();
  @override
  void onData(void Function(List<int>)? fn) => delegate.onData(fn);
  @override
  void onError(Function? fn) => delegate.onError(fn);
  @override
  void onDone(void Function()? fn) => delegate.onDone(fn);
  @override
  Future<E> asFuture<E>([E? value]) => delegate.asFuture(value);
}

class _Upstream {
  _Upstream(this.server);
  final HttpServer server;
  final requests = <String>[];
  final arrivals = StreamController<String>.broadcast();
  final finished = StreamController<String>.broadcast();
  int active = 0, maxActive = 0;
  bool live = false;
  int segmentCount = 12;
  bool reject = false;
  int segmentBytes = 16;
  bool dynamicBodies = false;
  final segmentHeaders = <String, String>{};
  Completer<void>? gate;
  Future<void> serve(HttpRequest request) async {
    final path = request.uri.path;
    requests.add(path);
    arrivals.add(path);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (path.endsWith('.m3u8')) {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write(
          [
            '#EXTM3U',
            '#EXT-X-TARGETDURATION:10',
            for (var i = 0; i < segmentCount; i++) ...['#EXTINF:10,', 's$i.ts'],
            if (!live) '#EXT-X-ENDLIST',
            '',
          ].join(String.fromCharCode(10)),
        );
      } else if (reject) {
        request.response.statusCode = 429;
      } else {
        request.response.headers.contentType = ContentType('video', 'mp2t');
        segmentHeaders.forEach(
          (name, value) => request.response.headers.set(name, value),
        );
        request.response.contentLength = segmentBytes;
        final wait = gate;
        if (wait != null && path == '/s2.ts') {
          request.response.add([0]);
          await request.response.flush();
          await Future.any([wait.future, request.response.done]);
          request.response.add(List.filled(segmentBytes - 1, 7));
        } else {
          request.response.add(
            segmentBytes > 1024
                ? Uint8List(segmentBytes)
                : List.generate(
                    segmentBytes,
                    (i) => dynamicBodies
                        ? requests.where((seen) => seen == path).length
                        : i % 251,
                  ),
          );
        }
      }
      await request.response.close();
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    } finally {
      active--;
      finished.add(path);
    }
  }
}

Future<void> _event(bool Function() predicate, {String why = 'event'}) async {
  final deadline = Stopwatch()..start();
  while (!predicate() && deadline.elapsed < const Duration(seconds: 3)) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(predicate(), isTrue, reason: why);
}

Future<
  ({
    LocalProxyServer proxy,
    _Upstream upstream,
    ProxySession session,
    Uri playlist,
    HttpClient client,
    LogService log,
  })
>
_fixture({bool live = false}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final upstream = _Upstream(server)..live = live;
  server.listen((request) => unawaited(upstream.serve(request)));
  final log = LogService();
  final proxy = LocalProxyServer(
    log: log,
    policy: const ProxyTargetPolicy(allowLoopback: true),
  );
  await proxy.start();
  final session = proxy.sessions.create(siteKey: 'test');
  final playlist = Uri.parse(
    proxy.urlFor(
      session,
      Uri.parse('http://127.0.0.1:${server.port}/vod.m3u8'),
    ),
  );
  final client = HttpClient();
  addTearDown(() async {
    if (upstream.gate case final pending?) {
      if (!pending.isCompleted) pending.complete();
    }
    client.close(force: true);
    await proxy.stop();
    await server.close(force: true);
    await upstream.arrivals.close();
    await upstream.finished.close();
  });
  final response = await (await client.getUrl(playlist)).close();
  await response.drain<void>();
  return (
    proxy: proxy,
    upstream: upstream,
    session: session,
    playlist: playlist,
    client: client,
    log: log,
  );
}

void main() {
  for (final headers in [
    <String, String>{
      'expires': HttpDate.format(
        DateTime.now().add(const Duration(minutes: 2)),
      ),
    },
    {'cache-control': 'public, s-maxage=60', 'age': '2'},
    {'cache-control': 'max-age="60", must-revalidate'},
  ]) {
    test('HTTP fresh explicit lifetime $headers keeps reusable body', () async {
      final f = await _fixture();
      f.upstream.dynamicBodies = true;
      f.upstream.segmentHeaders.addAll(headers);
      final done = f.log.stream.firstWhere(
        (entry) => entry.message.startsWith('预取窗口完成'),
      );
      f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
      await done.timeout(const Duration(seconds: 3));
      f.proxy.cancelPrefetch(clearCache: false);
      final uri = Uri.parse(
        f.proxy.urlFor(
          f.session,
          Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
        ),
      );
      final response = await (await f.client.getUrl(uri)).close();
      expect(
        await response.fold<List<int>>([], (a, b) => a..addAll(b)),
        List.filled(16, 1),
      );
      expect(
        f.upstream.requests.where((path) => path == '/s2.ts'),
        hasLength(1),
      );
      expect(response.headers.value('cache-control'), 'no-store');
    });
  }

  test('HTTP request revalidation evicts known prior body instead of returning it to later normal request', () async {
    final f = await _fixture();
    f.upstream.dynamicBodies = true;
    f.upstream.segmentHeaders['cache-control'] = 'public, max-age=60';
    final done = f.log.stream.firstWhere(
      (entry) => entry.message.startsWith('预取窗口完成'),
    );
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    await done.timeout(const Duration(seconds: 3));
    f.proxy.cancelPrefetch(clearCache: false);
    final uri = Uri.parse(
      f.proxy.urlFor(
        f.session,
        Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
      ),
    );
    final revalidate = await f.client.getUrl(uri);
    revalidate.headers.set('cache-control', 'no-cache');
    await (await revalidate.close()).drain<void>();
    final response = await (await f.client.getUrl(uri)).close();
    expect(
      await response.fold<List<int>>([], (a, b) => a..addAll(b)),
      List.filled(16, 3),
    );
    expect(f.upstream.requests.where((path) => path == '/s2.ts'), hasLength(3));
  });

  final responseRestrictions = <String, Map<String, String>>{
    'no-cache': {'cache-control': 'public, no-cache'},
    'no-cache field': {'cache-control': 'no-cache="Set-Cookie"'},
    'zero max-age': {'cache-control': 'max-age=0'},
    'zero s-maxage': {'cache-control': 'max-age=600, s-maxage=0'},
    'expired': {'expires': 'Thu, 01 Jan 1970 00:00:00 GMT'},
    'aged max-age': {'cache-control': 'max-age=10', 'age': '10'},
    'aged expires': {
      'date': 'Thu, 01 Jan 2026 00:00:00 GMT',
      'expires': 'Thu, 01 Jan 2026 00:00:10 GMT',
      'age': '10',
    },
    'old Date': {
      'cache-control': 'max-age=600',
      'date': 'Thu, 01 Jan 1970 00:00:00 GMT',
    },
    'invalid age': {'cache-control': 'max-age=60', 'age': 'invalid'},
    'invalid max-age': {'cache-control': 'max-age=invalid'},
    'invalid expires': {'expires': 'invalid'},
    'pragma no-cache': {'pragma': 'no-cache'},
    'vary star': {'vary': '*'},
    'vary user-agent': {'vary': 'User-Agent'},
    'set-cookie': {'set-cookie': 'fixture=value; HttpOnly'},
    'private': {'cache-control': 'private, max-age=60'},
  };
  for (final restriction in responseRestrictions.entries) {
    test(
      'HTTP response bypass ${restriction.key} preserves new upstream body',
      () async {
        final f = await _fixture();
        f.upstream.dynamicBodies = true;
        f.upstream.segmentHeaders.addAll(restriction.value);
        final done = f.log.stream.firstWhere(
          (entry) => entry.message.startsWith('预取窗口完成'),
        );
        f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
        await done.timeout(const Duration(seconds: 3));
        f.proxy.cancelPrefetch(clearCache: false);
        final uri = Uri.parse(
          f.proxy.urlFor(
            f.session,
            Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
          ),
        );
        final response = await (await f.client.getUrl(uri)).close();
        final body = await response.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(
          f.upstream.requests.where((path) => path == '/s2.ts'),
          hasLength(2),
        );
        expect(body, List.filled(16, 2));
      },
    );
  }

  for (final directive in [
    <String, String>{'cache-control': 'no-cache'},
    {'cache-control': 'max-age=0'},
    {'pragma': 'no-cache'},
    {'cache-control': 'no-store'},
  ]) {
    test(
      'HTTP request revalidate $directive bypasses otherwise fresh segment',
      () async {
        final f = await _fixture();
        f.upstream.dynamicBodies = true;
        f.upstream.segmentHeaders['cache-control'] = 'public, max-age=60';
        final done = f.log.stream.firstWhere(
          (entry) => entry.message.startsWith('预取窗口完成'),
        );
        f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
        await done.timeout(const Duration(seconds: 3));
        f.proxy.cancelPrefetch(clearCache: false);
        final uri = Uri.parse(
          f.proxy.urlFor(
            f.session,
            Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
          ),
        );
        final request = await f.client.getUrl(uri);
        directive.forEach((name, value) => request.headers.set(name, value));
        final response = await request.close();
        expect(
          await response.fold<List<int>>([], (a, b) => a..addAll(b)),
          List.filled(16, 2),
        );
        expect(
          f.upstream.requests.where((path) => path == '/s2.ts'),
          hasLength(2),
        );
      },
    );
  }

  test('HTTP explicit positive freshness keeps range hit and prevents downstream cache reuse', () async {
    final f = await _fixture();
    f.upstream.segmentHeaders.addAll({
      'cache-control': 'public, max-age=60, must-revalidate',
      'age': '1',
      'expires': HttpDate.format(
        DateTime.now().add(const Duration(minutes: 1)),
      ),
    });
    final done = f.log.stream.firstWhere(
      (entry) => entry.message.startsWith('预取窗口完成'),
    );
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    await done.timeout(const Duration(seconds: 3));
    f.proxy.cancelPrefetch(clearCache: false);
    final uri = Uri.parse(
      f.proxy.urlFor(
        f.session,
        Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
      ),
    );
    final request = await f.client.getUrl(uri);
    request.headers.set('Range', 'bytes=2-5');
    final response = await request.close();
    expect(response.statusCode, 206);
    expect(response.headers.value('content-range'), 'bytes 2-5/16');
    expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
      2,
      3,
      4,
      5,
    ]);
    expect(f.upstream.requests.where((path) => path == '/s2.ts'), hasLength(1));
    // ignore: avoid_print
    print(
      'HTTP fresh range landing upstreamCount=${f.upstream.requests.where((path) => path == "/s2.ts").length} status=${response.statusCode} contentRange=${response.headers.value("content-range")} downstream=${response.headers.value("cache-control")}',
    );
    expect(response.headers.value('cache-control'), contains('no-store'));
  });

  test('uncacheable same target has a bounded retry budget despite repeated prime calls', () async {
    final f = await _fixture();
    f.upstream.segmentHeaders['cache-control'] = 'no-store';
    final target = f.playlist.replace(fragment: 't=25');
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        // Deliberately advance the retry cooldown, not a completion barrier.
        await Future<void>.delayed(const Duration(milliseconds: 1100));
      }
      final done = f.log.stream.firstWhere(
        (entry) => entry.message.startsWith('预取窗口完成'),
      );
      f.proxy.primePrefetch([target]);
      await done.timeout(const Duration(seconds: 3));
    }
    final count = f.upstream.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    f.proxy.cancelPrefetch(clearCache: false);
    for (var i = 0; i < 100; i++) {
      f.proxy.primePrefetch([target]);
    }
    // An actual foreground round trip lets any wrongly queued job run first.
    await (await (await f.client.getUrl(f.playlist)).close()).drain<void>();
    expect(f.upstream.requests.length, count + 1);
    expect(f.upstream.requests.where((path) => path == '/s2.ts'), hasLength(3));
  });

  test('repeated same-target notifications do not restart a fresh completed window', () async {
    final f = await _fixture();
    final target = f.playlist.replace(fragment: 't=25');
    final done = f.log.stream.firstWhere(
      (entry) => entry.message.startsWith('预取窗口完成'),
    );
    f.proxy.primePrefetch([target]);
    await done.timeout(const Duration(seconds: 3));
    final count = f.upstream.requests.length;
    for (var i = 0; i < 100; i++) {
      f.proxy.primePrefetch([target]);
    }
    await (await (await f.client.getUrl(f.playlist)).close()).drain<void>();
    expect(f.upstream.requests.length, count + 1);
    expect(f.upstream.requests.where((path) => path == '/s2.ts'), hasLength(1));
  });

  test('HTTP same target refreshes an expired window before landing without a foreground miss', () async {
    final f = await _fixture();
    f.upstream.dynamicBodies = true;
    f.upstream.segmentHeaders['cache-control'] = 'max-age=1';
    final firstDone = f.log.stream.firstWhere(
      (entry) => entry.message.startsWith('预取窗口完成'),
    );
    final target = f.playlist.replace(fragment: 't=25');
    f.proxy.primePrefetch([target]);
    await firstDone.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final secondDone = f.log.stream.firstWhere(
      (entry) => entry.message.startsWith('预取窗口完成'),
    );
    f.proxy.primePrefetch([target]);
    await secondDone.timeout(const Duration(seconds: 3));
    f.proxy.cancelPrefetch(clearCache: false);
    final uri = Uri.parse(
      f.proxy.urlFor(
        f.session,
        Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
      ),
    );
    final response = await (await f.client.getUrl(uri)).close();
    expect(
      await response.fold<List<int>>([], (a, b) => a..addAll(b)),
      List.filled(16, 2),
    );
    expect(f.upstream.requests.where((path) => path == '/s2.ts'), hasLength(2));
  });

  test('HTTP entry max-age expiry during completed-cache residency forwards fresh body', () async {
    final f = await _fixture();
    f.upstream.dynamicBodies = true;
    f.upstream.segmentHeaders['cache-control'] = 'max-age=1';
    final done = f.log.stream.firstWhere(
      (entry) => entry.message.startsWith('预取窗口完成'),
    );
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    await done.timeout(const Duration(seconds: 3));
    f.proxy.cancelPrefetch(clearCache: false);
    // This timer advances the HTTP freshness lifetime, not a request completion barrier.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final uri = Uri.parse(
      f.proxy.urlFor(
        f.session,
        Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
      ),
    );
    final response = await (await f.client.getUrl(uri)).close();
    expect(
      await response.fold<List<int>>([], (a, b) => a..addAll(b)),
      List.filled(16, 2),
    );
    expect(f.upstream.requests.where((path) => path == '/s2.ts'), hasLength(2));
  });

  test('HTTP no-store segment dynamic body must reach upstream again after prefetch', () async {
    final f = await _fixture();
    f.upstream.dynamicBodies = true;
    f.upstream.segmentHeaders['cache-control'] = 'no-store';
    final done = f.log.stream.firstWhere(
      (entry) => entry.message.startsWith('预取窗口完成'),
    );
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    await done.timeout(const Duration(seconds: 3));
    f.proxy.cancelPrefetch(clearCache: false);
    final uri = Uri.parse(
      f.proxy.urlFor(
        f.session,
        Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
      ),
    );
    final response = await (await f.client.getUrl(uri)).close();
    final body = await response.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    expect(f.upstream.requests.where((path) => path == '/s2.ts'), hasLength(2));
    expect(
      body,
      List.filled(16, 2),
      reason: 'no-store may not return prefetched first version',
    );
    // ignore: avoid_print
    print(
      'HTTP no-store landing upstreamCount=${f.upstream.requests.where((path) => path == "/s2.ts").length} bodyFirst=${body.first} bytes=${body.length}',
    );
    expect(response.headers.value('cache-control'), contains('no-store'));
  });

  test(
    'prefetched media time is capped at 30 seconds of complete segments',
    () async {
      final f = await _fixture();
      final done = f.log.stream.firstWhere(
        (entry) => entry.message.startsWith('预取窗口完成'),
      );
      f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
      await done.timeout(const Duration(seconds: 3));
      f.proxy.cancelPrefetch(clearCache: false);
      expect(f.upstream.requests, ['/vod.m3u8', '/s2.ts', '/s3.ts', '/s4.ts']);
    },
  );

  test('foreground does not wait for cancelled background resolver that has no active socket', () async {
    final f = await _fixture();
    final entered = Completer<void>();
    final pending = Completer<int?>();
    final managed = f.proxy.sessions.create(
      siteKey: 'managed',
      targetResolver: (uri) async {
        if (uri.path == '/s2.ts') {
          if (!entered.isCompleted) entered.complete();
          return pending.future;
        }
        return f.upstream.server.port;
      },
    );
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(f.upstream.server.port);
    });
    final list = Uri.parse(
      f.proxy.urlFor(managed, Uri.parse('http://127.0.0.1:9978/vod.m3u8')),
    );
    await (await (await f.client.getUrl(list)).close()).drain<void>();
    f.proxy.primePrefetch([list.replace(fragment: 't=25')]);
    await entered.future.timeout(const Duration(seconds: 2));
    final foreground = Uri.parse(
      f.proxy.urlFor(managed, Uri.parse('http://127.0.0.1:9978/s0.ts')),
    );
    final response = await (await f.client.getUrl(foreground))
        .close()
        .timeout(const Duration(seconds: 1));
    expect(await response.fold<int>(0, (a, b) => a + b.length), 16);
    expect(pending.isCompleted, isFalse);
    f.proxy.cancelPrefetch();
  });

  test('unindexed token and arbitrary media URL never borrow another playlist index', () async {
    final f = await _fixture();
    final uri = Uri.parse(
      f.proxy.urlFor(
        f.session,
        Uri.parse('http://127.0.0.1:${f.upstream.server.port}/unseen.m3u8'),
      ),
    );
    f.proxy.primePrefetch([uri.replace(fragment: 't=25')]);
    final barrier = await (await f.client.getUrl(f.playlist)).close();
    await barrier.drain<void>();
    expect(f.upstream.requests.every((path) => path.endsWith('.m3u8')), isTrue);
  });

  test('changing target while body pending cancels it and fetches new window in order', () async {
    final f = await _fixture();
    f.upstream.gate = Completer<void>();
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    await _event(() => f.upstream.requests.contains('/s2.ts'));
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=65')]);
    await _event(() => f.upstream.requests.contains('/s8.ts'));
    expect(f.upstream.requests.contains('/s3.ts'), isFalse);
    expect(
      f.upstream.requests.where(
        (x) =>
            x.startsWith('/s6') ||
            x.startsWith('/s7') ||
            x.startsWith('/s8') ||
            x.startsWith('/s9'),
      ),
      ['/s6.ts', '/s7.ts', '/s8.ts'],
    );
    f.proxy.cancelPrefetch(clearCache: false);
  });

  test('same-session seek cancel(false) keeps target bytes while cancel(true) clears', () async {
    final f = await _fixture();
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    await _event(() => f.upstream.requests.contains('/s4.ts'));
    await _event(() => f.upstream.active == 0);
    f.proxy.cancelPrefetch(clearCache: false);
    final url = Uri.parse(
      f.proxy.urlFor(
        f.session,
        Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
      ),
    );
    await (await (await f.client.getUrl(url)).close()).drain<void>();
    expect(f.upstream.requests.where((x) => x == '/s2.ts'), hasLength(1));
    f.proxy.cancelPrefetch();
    await (await (await f.client.getUrl(url)).close()).drain<void>();
    expect(f.upstream.requests.where((x) => x == '/s2.ts'), hasLength(2));
  });

  test('same-session new target can start after cancel(false) without losing cached bytes', () async {
    final f = await _fixture();
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    await _event(() => f.upstream.requests.contains('/s4.ts'));
    await _event(() => f.upstream.active == 0);
    f.proxy.cancelPrefetch(clearCache: false);
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=65')]);
    await _event(
      () => f.upstream.requests.contains('/s6.ts'),
      why: 'new target cannot be suppressed by prior fetched queue',
    );
    expect(
      f.upstream.requests.where((x) => x == '/s2.ts'),
      hasLength(1),
      reason: 'old cached window preserved',
    );
  });

  test('invalid public or malformed local targets never throw and cannot trigger upstream', () async {
    final f = await _fixture();
    for (final uri in [
      Uri.parse('https://outside.test/x#t=25'),
      f.playlist.replace(fragment: 't=NaN'),
      f.playlist.replace(fragment: 't=Infinity'),
      f.playlist.replace(fragment: 't=-1'),
      f.playlist.replace(fragment: 't=10000'),
      f.playlist.replace(fragment: 't=%'),
      f.playlist.replace(path: '/p/wrong/data', fragment: 't=25'),
    ]) {
      expect(() => f.proxy.primePrefetch([uri]), returnsNormally);
    }
    expect(f.upstream.requests, ['/vod.m3u8']);
  });

  test(
    'session cache LRU hard limit is 64MiB across multiple completed windows',
    () async {
      final f = await _fixture();
      f.upstream.segmentBytes = 16 * 1024 * 1024;
      for (final second in [0, 20, 40, 60, 80]) {
        f.proxy.primePrefetch([f.playlist.replace(fragment: 't=$second')]);
        final path = '/s${second ~/ 10 + 1}.ts';
        await _event(
          () => f.upstream.requests.contains(path),
          why: 'window byte budget finished',
        );
        await _event(() => f.upstream.active == 0);
      }
      f.proxy.cancelPrefetch(clearCache: false);
      final cached = Uri.parse(
        f.proxy.urlFor(
          f.session,
          Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s8.ts'),
        ),
      );
      await (await (await f.client.getUrl(cached)).close()).drain<void>();
      expect(f.upstream.requests.where((x) => x == '/s8.ts'), hasLength(1));
      final evicted = Uri.parse(
        f.proxy.urlFor(
          f.session,
          Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s0.ts'),
        ),
      );
      await (await (await f.client.getUrl(evicted)).close()).drain<void>();
      expect(f.upstream.requests.where((x) => x == '/s0.ts'), hasLength(2));
    },
  );

  test('foreground preempts pending background and abandoned partial body is never cached', () async {
    final journal = _RequestJournal();
    await HttpOverrides.runWithHttpOverrides(() async {
      final f = await _fixture();
      journal.port = f.upstream.server.port;
      final events = f.log.stream.listen((entry) {
        if (entry.message.startsWith('预取任务已释放')) journal.events.add('run-done');
      });
      addTearDown(events.cancel);
      final gate = Completer<void>();
      f.upstream.gate = gate;
      f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
      await _event(() => f.upstream.requests.contains('/s2.ts'));
      final url = Uri.parse(
        f.proxy.urlFor(
          f.session,
          Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s0.ts'),
        ),
      );
      final response = await (await f.client.getUrl(url))
          .close()
          .timeout(const Duration(seconds: 2));
      expect(
        await response.fold<int>(0, (sum, chunk) => sum + chunk.length),
        16,
      );
      expect(gate.isCompleted, isFalse);
      expect(
        journal.maximum,
        1,
        reason: 'scheduler owns at most one local upstream request during preemption',
      );
      final close = journal.events.indexOf('force-close');
      final done = journal.events.indexOf('run-done');
      final foreground = journal.events.indexWhere(
        (entry) => entry.startsWith('open:/s0.ts:'),
      );
      expect(close, greaterThanOrEqualTo(0));
      expect(done, greaterThan(close));
      expect(foreground, greaterThan(done));
      // ignore: avoid_print
      print(
        'prefetch local request ownership maximum=${journal.maximum} events=${journal.events}',
      );
      gate.complete();
      f.upstream.gate = null;
      await _event(() => f.upstream.active == 0);
      f.proxy.cancelPrefetch();
      final partial = Uri.parse(
        f.proxy.urlFor(
          f.session,
          Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
        ),
      );
      await (await (await f.client.getUrl(partial)).close()).drain<void>();
      expect(
        f.upstream.requests.where((path) => path == '/s2.ts'),
        hasLength(2),
      );
    }, _TrackedOverrides(journal));
  });

  test('fresh session cannot see prior session cache even for identical logical URI', () async {
    final f = await _fixture();
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    await _event(() => f.upstream.requests.contains('/s4.ts'));
    await _event(() => f.upstream.active == 0);
    final other = f.proxy.sessions.create(siteKey: 'test');
    final target = Uri.parse(
      f.proxy.urlFor(
        other,
        Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
      ),
    );
    await (await (await f.client.getUrl(target)).close()).drain<void>();
    expect(f.upstream.requests.where((path) => path == '/s2.ts'), hasLength(2));
  });

  test('VOD target prefetch is ordered single-flight and cache serves range without upstream', () async {
    final f = await _fixture();
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    await _event(
      () => f.upstream.requests.contains('/s4.ts'),
      why: 'target window fetched',
    );
    await _event(() => f.upstream.active == 0);
    expect(f.upstream.requests, ['/vod.m3u8', '/s2.ts', '/s3.ts', '/s4.ts']);
    expect(f.upstream.maxActive, 1);
    final target = Uri.parse(
      f.proxy.urlFor(
        f.session,
        Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
      ),
    );
    final request = await f.client.getUrl(target);
    request.headers.set('Range', 'bytes=2-5');
    final response = await request.close();
    expect(response.statusCode, 206);
    expect(response.headers.value('content-range'), 'bytes 2-5/16');
    expect(response.headers.contentType?.mimeType, 'video/mp2t');
    expect(
      await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
      [2, 3, 4, 5],
    );
    expect(f.upstream.requests.where((path) => path == '/s2.ts'), hasLength(1));
    // ignore: avoid_print
    print(
      'prefetch cache range bytes=${response.contentLength} upstream=${f.upstream.requests} maxHandler=${f.upstream.maxActive}',
    );
  });

  test('live and unknown playlist never prefetch', () async {
    final f = await _fixture(live: true);
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    final barrier = await (await f.client.getUrl(f.playlist)).close();
    await barrier.drain<void>();
    expect(f.upstream.requests, ['/vod.m3u8', '/vod.m3u8']);
  });

  for (final foreground in [false, true]) {
    test(
      '429 consumed by proxy disables entire session foreground=$foreground',
      () async {
        final f = await _fixture();
        final consumed = f.log.stream.firstWhere(
          (entry) => entry.message.startsWith('预取已禁用：上游429'),
        );
        f.upstream.reject = true;
        if (foreground) {
          final uri = Uri.parse(
            f.proxy.urlFor(
              f.session,
              Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s0.ts'),
            ),
          );
          final response = await (await f.client.getUrl(uri)).close();
          expect(response.statusCode, 429);
          await response.drain<void>();
        } else {
          f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
        }
        await consumed.timeout(const Duration(seconds: 3));
        final count = f.upstream.requests.length;
        f.proxy.cancelPrefetch(clearCache: false);
        final ignored = f.log.stream.firstWhere(
          (entry) => entry.message == '预取已忽略：会话停用',
        );
        f.proxy.primePrefetch([f.playlist.replace(fragment: 't=60')]);
        await ignored.timeout(const Duration(seconds: 3));
        final barrier = Uri.parse(
          f.proxy.urlFor(
            f.session,
            Uri.parse('http://127.0.0.1:${f.upstream.server.port}/vod.m3u8'),
          ),
        );
        await (await (await f.client.getUrl(barrier)).close()).drain<void>();
        expect(f.upstream.requests.length, count + 1);
        expect(f.upstream.requests.contains('/s6.ts'), isFalse);
        final next = f.proxy.sessions.create(siteKey: 'test');
        f.upstream.reject = false;
        final nextList = Uri.parse(
          f.proxy.urlFor(
            next,
            Uri.parse('http://127.0.0.1:${f.upstream.server.port}/vod.m3u8'),
          ),
        );
        await (await (await f.client.getUrl(nextList)).close()).drain<void>();
        f.proxy.primePrefetch([nextList.replace(fragment: 't=60')]);
        await _event(() => f.upstream.requests.contains('/s6.ts'));
      },
    );
  }

  test(
    'cancel clears pending cache and session revocation cannot reuse it',
    () async {
      final f = await _fixture();
      f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
      await _event(() => f.upstream.requests.contains('/s4.ts'));
      await _event(() => f.upstream.active == 0);
      f.proxy.cancelPrefetch();
      final url = Uri.parse(
        f.proxy.urlFor(
          f.session,
          Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s2.ts'),
        ),
      );
      await (await (await f.client.getUrl(url)).close()).drain<void>();
      expect(f.upstream.requests.where((x) => x == '/s2.ts'), hasLength(2));
      f.proxy.sessions.revoke(f.session.token);
      final denied = await (await f.client.getUrl(url)).close();
      expect(denied.statusCode, 401);
      await denied.drain<void>();
    },
  );

  test('24MiB window budget is hard and foreground cancels background before next request', () async {
    final f = await _fixture();
    f.upstream.segmentBytes = 13 * 1024 * 1024;
    f.proxy.primePrefetch([f.playlist.replace(fragment: 't=25')]);
    await _event(() => f.upstream.requests.contains('/s3.ts'));
    await _event(() => f.upstream.active == 0);
    expect(f.upstream.requests, ['/vod.m3u8', '/s2.ts', '/s3.ts']);
    // ignore: avoid_print
    print(
      'prefetch byte budget downloaded=${f.upstream.segmentBytes} nextEntryRejected=${f.upstream.segmentBytes} limit=${LocalProxyServer.prefetchWindowBytes}',
    );
    final target = Uri.parse(
      f.proxy.urlFor(
        f.session,
        Uri.parse('http://127.0.0.1:${f.upstream.server.port}/s3.ts'),
      ),
    );
    final response = await (await f.client.getUrl(target)).close();
    await response.drain<void>();
    expect(
      f.upstream.requests.where((x) => x == '/s3.ts'),
      hasLength(2),
      reason: 'oversized remaining entry not cached',
    );
  });
}
