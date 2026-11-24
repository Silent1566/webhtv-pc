@Tags(['external'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/cat_http.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/request_cancellation.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';

import 'support/search_cancel_harness.dart';

class _TaggedClient extends http.BaseClient {
  _TaggedClient(this.tag);
  final String tag;
  final _transport = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['X-Client-Owner'] = tag;
    return _transport.send(request);
  }

  @override
  void close() => _transport.close();
}

class _LegacyRuntime extends UnsupportedRuntime {
  _LegacyRuntime() : super(runtimeName: 'legacy-blocking', reason: 'fixture');
  final started = Completer<void>();
  final result = Completer<SiteResult>();
  @override
  Future<SiteResult> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
  }) {
    started.complete();
    return result.future;
  }
}

class _LegacyRouter extends SpiderRouter {
  _LegacyRouter(this.runtime, LogService log)
    : super(client: HttpApiClient(), globalHeaders: const [], log: log);
  final _LegacyRuntime runtime;
  @override
  SiteRuntime runtimeFor(Site site) => runtime;
}

Matcher get _cancelled =>
    isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.siteCancelled);

void main() {
  test(
    'legacy runtime stops waiting and reports termination unsupported',
    () async {
      final runtime = _LegacyRuntime();
      final log = LogService();
      final router = _LegacyRouter(runtime, log);
      addTearDown(router.client.close);
      final scope = RequestCancellation();
      final result = router.search(
        Site(key: 'legacy', name: 'legacy', type: 3, api: 'custom'),
        keyword: 'old',
        cancellation: scope,
      );
      final stopped = expectLater(result, throwsA(_cancelled));
      await runtime.started.future;
      scope.cancel();
      await stopped.timeout(const Duration(seconds: 2));
      expect(runtime.result.isCompleted, isFalse);
      expect(log.export(), contains('不支持终止'));
      runtime.result.completeError(StateError('late failure is consumed'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'injected HTTP client wins without replacing cached runtime client',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = StreamIterator<HttpRequest>(server);
      final shared = HttpApiClient(client: _TaggedClient('shared'));
      final injected = HttpApiClient(client: _TaggedClient('injected'));
      final router = SpiderRouter(client: shared, globalHeaders: const []);
      addTearDown(() async {
        shared.close();
        injected.close();
        await received.cancel();
        await server.close(force: true);
      });
      final site = Site(
        key: 'http',
        name: 'http',
        type: 1,
        api: 'http://127.0.0.1:${server.port}/api',
        searchable: true,
      );
      final cached = router.runtimeFor(site) as HttpApiRuntime;
      final scope = RequestCancellation();
      final result = router.search(
        site,
        keyword: 'old',
        client: injected,
        cancellation: scope,
      );
      final stopped = expectLater(result, throwsA(_cancelled));
      expect(await received.moveNext(), isTrue);
      final first = received.current;
      expect(first.uri.queryParameters['wd'], 'old');
      expect(first.headers.value('X-Client-Owner'), 'injected');
      scope.cancel();
      await stopped;
      injected.close();
      expect(identical(cached.client, shared), isTrue);
      final home = cached.home(site);
      expect(await received.moveNext(), isTrue);
      expect(received.current.headers.value('X-Client-Owner'), 'shared');
      received.current.response.write(
        jsonEncode({
          'list': [
            {'vod_id': '1', 'vod_name': 'shared alive'},
          ],
        }),
      );
      await received.current.response.close();
      expect((await home).list.single.vodName, 'shared alive');
    },
  );

  test(
    'router passes cancellation to Cat HTTP without closing shared transport',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = StreamIterator<HttpRequest>(server);
      final cat = CatHttpClient();
      final router = SpiderRouter(
        client: HttpApiClient(),
        catHttpClient: cat,
        globalHeaders: const [],
      );
      addTearDown(() async {
        cat.close();
        router.client.close();
        await received.cancel();
        await server.close(force: true);
      });
      final site = Site(
        key: 'cat',
        name: 'cat',
        type: 3,
        api: 'http://127.0.0.1:${server.port}/spider/',
        searchable: true,
      );
      final scope = RequestCancellation();
      final reason = AppError(
        AppErrorKind.siteTimeout,
        'search budget expired',
      );
      final result = router.search(site, keyword: 'slow', cancellation: scope);
      final stopped = expectLater(result, throwsA(same(reason)));
      expect(await received.moveNext(), isTrue);
      expect(received.current.uri.path, '/spider/search');
      scope.cancel(reason);
      await stopped;
      final home = router.runtimeFor(site).home(site);
      expect(await received.moveNext(), isTrue);
      received.current.response.write(jsonEncode({'list': []}));
      await received.current.response.close();
      expect((await home).list, isEmpty);
    },
  );

  group('real child sidecar cancellation', () {
    late SearchCancelHarness fixture;
    setUp(() async {
      fixture = SearchCancelHarness();
      await fixture.start();
    });
    tearDown(() => fixture.close());

    test(
      'pre-cancelled scope cannot initialize a host or send search',
      () async {
        final scope = RequestCancellation()..cancel();
        await expectLater(
          fixture.runtime().searchCancellable(
            fixture.site,
            keyword: 'never',
            cancellation: scope,
          ),
          throwsA(_cancelled),
        );
        expect(fixture.supervisor.statuses(), isEmpty);
        expect(fixture.frames, isEmpty);
      },
    );

    test(
      'cancelled startup waiter never sends old search or kills shared init',
      () async {
        final old = fixture.runtime(gateInit: true);
        final peer = fixture.runtime(gateInit: true);
        final scope = RequestCancellation();
        final result = old.searchCancellable(
          fixture.site,
          keyword: 'obsolete',
          cancellation: scope,
        );
        final stopped = expectLater(result, throwsA(_cancelled));
        await fixture.until(() => fixture.gates.containsKey('initialize'));
        final survivor = peer.search(fixture.site, keyword: 'current');
        scope.cancel();
        await stopped.timeout(const Duration(seconds: 2));
        await fixture.reply('initialize');
        final frame = await fixture.searchFrame('current');
        await fixture.reply(frame['id'] as String);
        expect((await survivor).list, isNotEmpty);
        expect(fixture.frames.where((f) => f['method'] == 'search').length, 1);
        expect(
          fixture.frames.where((f) => f['method'] == r'$/cancelRequest'),
          isEmpty,
        );
        expect(
          fixture.supervisor.hostFor(fixture.site.key)!.process.killTreeCount,
          0,
        );
      },
    );

    test('runtime instances use distinct request ids and target only cancelled search', () async {
      final first = fixture.runtime();
      final second = fixture.runtime();
      final scope = RequestCancellation();
      final target = first.searchCancellable(
        fixture.site,
        keyword: 'target',
        cancellation: scope,
      );
      final stopped = expectLater(target, throwsA(_cancelled));
      final survivor = second.search(fixture.site, keyword: 'survivor');
      final targetFrame = await fixture.searchFrame('target');
      final peerFrame = await fixture.searchFrame('survivor');
      expect(targetFrame['id'], isNot(peerFrame['id']));
      scope.cancel();
      await stopped;
      await fixture.until(
        () => fixture.frames.any((f) => f['method'] == r'$/cancelRequest'),
      );
      expect(
        fixture.frames
            .where((f) => f['method'] == r'$/cancelRequest')
            .single['params'],
        {'id': targetFrame['id']},
      );
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      await fixture.reply(targetFrame['id'] as String);
      await fixture.reply(peerFrame['id'] as String);
      expect((await survivor).list, isNotEmpty);
      expect(
        fixture.supervisor.hostFor(fixture.site.key)!.process.killTreeCount,
        0,
      );
      // ignore: avoid_print
      print(
        'runtime ids target=${targetFrame['id']} survivor=${peerFrame['id']}; peer survived >2s',
      );
    });
  }, skip: Platform.isWindows ? 'POSIX Python fixture' : false);
}
