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
import 'package:webhtv_pc/services/cancellable_probe_runtime.dart';
import 'package:webhtv_pc/services/spider_router.dart';

import 'support/probe_cancel_harness.dart';

const _bound = Duration(seconds: 8);
const _filters = {'genre': '中文 + &'};

enum _Probe { home, category }

Future<SiteResult> _probe(
  SiteRuntime runtime,
  Site site,
  _Probe probe,
  RequestCancellation cancellation,
) {
  expect(runtime, isA<CancellableProbeRuntime>());
  final capable = runtime as CancellableProbeRuntime;
  return probe == _Probe.home
      ? capable.homeCancellable(site, cancellation: cancellation)
      : capable.categoryCancellable(
          site,
          typeId: 'movie:1',
          page: 3,
          filters: _filters,
          cancellation: cancellation,
        );
}

AppError _reason(bool timeout) => AppError(
  timeout ? AppErrorKind.siteTimeout : AppErrorKind.siteCancelled,
  timeout ? 'whole probe budget expired' : 'probe cancelled',
);

class _ObservedClient extends http.BaseClient {
  final _inner = http.Client();
  final firstChunk = Completer<void>();
  int sent = 0;
  int closed = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent++;
    final response = await _inner.send(request);
    return http.StreamedResponse(
      response.stream.map((chunk) {
        if (!firstChunk.isCompleted) firstChunk.complete();
        return chunk;
      }),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() {
    closed++;
    _inner.close();
  }
}

class _LateErrorClient extends http.BaseClient {
  final started = Completer<void>();
  final result = Completer<http.StreamedResponse>();
  int closed = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    started.complete();
    return result.future;
  }

  @override
  void close() => closed++;
}

SpiderRouter _router(bool cat, http.Client transport) => SpiderRouter(
  client: HttpApiClient(client: transport),
  catHttpClient: CatHttpClient(client: transport),
  globalHeaders: [
    HeaderRule(host: '*', header: HeaderMap({'X-Probe-Test': 'kept'})),
  ],
);

Site _site(bool cat, String api, String key) => Site(
  key: key,
  name: key,
  type: cat ? 3 : 1,
  api: cat ? '$api/spider' : api,
  searchable: true,
  ext: 'opaque-init-参数',
);

void main() {
  for (final probe in _Probe.values) {
    test(
      'legacy HTTP ${probe.name} still rejects an invalid API synchronously',
      () async {
        final transport = _ObservedClient();
        addTearDown(transport.close);
        final router = _router(false, transport);
        final site = _site(false, 'not-http', 'invalid');
        final runtime = router.runtimeFor(
          _site(false, 'http://127.0.0.1/api', 'valid'),
        );
        var synchronousError = false;
        try {
          final pending = probe == _Probe.home
              ? runtime.home(site)
              : runtime.category(site, typeId: 'movie', page: 1);
          await expectLater(pending, throwsA(isA<AppError>()));
        } on AppError catch (error) {
          synchronousError = true;
          expect(error.kind, AppErrorKind.siteEmptyApi);
        }
        expect(synchronousError, isTrue);
        expect(transport.sent, 0);
      },
    );
  }
  for (final cat in [false, true]) {
    final kind = cat ? 'Cat HTTP' : 'HTTP API';
    for (final probe in _Probe.values) {
      final label = '$kind ${probe.name}';
      test('$label pre-cancel never sends a request', () async {
        final server = await ProbeWireServer.start();
        final transport = _ObservedClient();
        addTearDown(() async {
          transport.close();
          await server.close();
        });
        final router = _router(cat, transport);
        final site = _site(cat, server.api('never'), 'never');
        final reason = _reason(false);
        await expectLater(
          _probe(
            router.runtimeFor(site),
            site,
            probe,
            RequestCancellation()..cancel(reason),
          ),
          throwsA(same(reason)),
        );
        expect(transport.sent, 0);
        expect(server.requests, isEmpty);
        expect(transport.closed, 0);
      });

      for (final timeout in [false, true]) {
        for (final bodyInFlight in [false, true]) {
          final mode = timeout ? 'timeout' : 'cancel';
          final phase = bodyInFlight ? 'body' : 'headers';
          test('$label $mode aborts $phase only', () async {
            final server = await ProbeWireServer.start();
            if (bodyInFlight) server.partialBodies.add('target');
            final transport = _ObservedClient();
            addTearDown(() async {
              transport.close();
              await server.close();
            });
            final router = _router(cat, transport);
            final targetSite = _site(cat, server.api('target'), 'target-site');
            final peerSite = _site(cat, server.api('peer'), 'peer-site');
            final scope = RequestCancellation();
            final reason = _reason(timeout);
            final target = _probe(
              router.runtimeFor(targetSite),
              targetSite,
              probe,
              scope,
            );
            final stopped = expectLater(
              target.timeout(_bound),
              throwsA(same(reason)),
            );
            final peer = router.runtimeFor(peerSite).home(peerSite);
            final wire = await server.received('target').timeout(_bound);
            await server.received('peer').timeout(_bound);
            expect(wire.headers['x-probe-test'], 'kept');
            if (cat) {
              expect(wire.method, 'POST');
              expect(wire.uri.path, '/target/spider/${probe.name}');
              expect(
                jsonDecode(wire.body),
                probe == _Probe.home
                    ? {}
                    : {'id': 'movie:1', 'page': 3, 'filters': _filters},
              );
            } else {
              expect(wire.uri.queryParameters['extend'], 'opaque-init-参数');
              if (probe == _Probe.category) {
                expect(wire.uri.queryParameters['t'], 'movie:1');
                expect(wire.uri.queryParameters['pg'], '3');
              }
            }
            if (bodyInFlight) await transport.firstChunk.future.timeout(_bound);
            if (timeout) {
              final timer = Timer(Duration.zero, () => scope.cancel(reason));
              addTearDown(timer.cancel);
            } else {
              scope.cancel(reason);
            }
            await stopped;
            await server.disconnected('target').timeout(_bound);
            expect(transport.closed, 0);
            server.complete('peer');
            final survivor = await peer.timeout(_bound);
            expect(survivor.list.single.vodName, 'peer alive');
            expect(survivor.list.single.vodId, 'wire-id');
            final nextSite = _site(cat, server.api('next'), 'next-site');
            final next = _probe(
              router.runtimeFor(nextSite),
              nextSite,
              probe,
              RequestCancellation(),
            );
            await server.received('next').timeout(_bound);
            server.complete('next');
            expect((await next.timeout(_bound)).list.single.vodId, 'wire-id');
            expect(transport.closed, 0);
            // ignore: avoid_print
            print(
              '$label: target TCP disconnected; in-flight peer and next request survived; client closes=0',
            );
          });
        }
      }

      test('$label consumes late transport errors', () async {
        final transport = _LateErrorClient();
        final router = _router(cat, transport);
        final site = _site(cat, 'http://127.0.0.1/not-sent', 'late');
        final scope = RequestCancellation();
        final reason = _reason(false);
        final pending = _probe(router.runtimeFor(site), site, probe, scope);
        final stopped = expectLater(pending, throwsA(same(reason)));
        await transport.started.future;
        scope.cancel(reason);
        await stopped;
        transport.result.completeError(StateError('late network failure'));
        await Future<void>.delayed(Duration.zero);
        expect(transport.closed, 0);
      });
    }
  }

  group('request-local sidecar probes', () {
    late ProbeCancelHarness fixture;
    setUp(() async {
      fixture = ProbeCancelHarness();
      await fixture.start();
    });
    tearDown(() => fixture.close());

    for (final probe in _Probe.values) {
      final label = probe.name;
      test('$label pre-cancel cannot start a host', () async {
        final reason = _reason(false);
        await expectLater(
          _probe(
            fixture.runtime(),
            fixture.site,
            probe,
            RequestCancellation()..cancel(reason),
          ),
          throwsA(same(reason)),
        );
        expect(fixture.supervisor.statuses(), isEmpty);
        expect(fixture.frames, isEmpty);
      });

      test('$label cancelled startup leaves shared initialize alive', () async {
        final runtime = fixture.runtime(gateInit: true);
        final scope = RequestCancellation();
        final reason = _reason(false);
        final pending = _probe(runtime, fixture.site, probe, scope);
        final stopped = expectLater(
          pending.timeout(_bound),
          throwsA(same(reason)),
        );
        await fixture.until(() => fixture.gates.containsKey('initialize'));
        final peer = fixture
            .runtime(gateInit: true)
            .search(fixture.site, keyword: 'peer');
        scope.cancel(reason);
        await stopped;
        await fixture.reply('initialize');
        final frame = await fixture.searchFrame('peer');
        await fixture.reply(frame['id'] as String);
        expect((await peer.timeout(_bound)).list, isNotEmpty);
        expect(fixture.frames.where((f) => f['method'] == probe.name), isEmpty);
        expect(
          fixture.frames.where((f) => f['method'] == r'$/cancelRequest'),
          isEmpty,
        );
        expect(fixture.frames.first['params']['extend'], fixture.site.ext);
        expect(
          fixture.supervisor.hostFor(fixture.site.key)!.process.killTreeCount,
          0,
        );
      });

      for (final timeout in [false, true]) {
        final mode = timeout ? 'timeout' : 'cancel';
        test('$label $mode targets one RPC and consumes a late error', () async {
          final first = fixture.runtime();
          final second = fixture.runtime();
          final scope = RequestCancellation();
          final reason = _reason(timeout);
          final pending = _probe(first, fixture.site, probe, scope);
          final stopped = expectLater(
            pending.timeout(_bound),
            throwsA(same(reason)),
          );
          final peer = second.search(fixture.site, keyword: 'peer');
          final targetFrame = await fixture.probeFrame(probe.name);
          final peerFrame = await fixture.searchFrame('peer');
          expect(targetFrame['id'], isNot(peerFrame['id']));
          expect(
            targetFrame['params'],
            probe == _Probe.home
                ? {}
                : {'id': 'movie:1', 'page': 3, 'filters': _filters},
          );
          scope.cancel(reason);
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
          await fixture.replyError(targetFrame['id'] as String);
          await fixture.until(() => fixture.sent.contains(targetFrame['id']));
          await fixture.reply(
            peerFrame['id'] as String,
            title: 'unrelated search alive',
          );
          final survivor = await peer.timeout(_bound);
          expect(survivor.list.single.vodName, 'unrelated search alive');
          expect(survivor.list.single.vodId, peerFrame['id']);
          final host = fixture.supervisor.hostFor(fixture.site.key)!;
          expect(host.process.isRunning, isTrue);
          expect(host.process.killTreeCount, 0);
          // ignore: avoid_print
          print(
            '$label: cancel RPC id=${targetFrame['id']}; peer id=${peerFrame['id']}; late error consumed; host kills=0',
          );
        });
      }

      test('$label actual Python host observes only target context cancelled', () async {
        final host = await fixture.host(actualHost: true);
        final runtime = fixture.runtime();
        final scope = RequestCancellation();
        final reason = _reason(true);
        final pending = _probe(runtime, fixture.site, probe, scope);
        final stopped = expectLater(
          pending.timeout(_bound),
          throwsA(same(reason)),
        );
        final peer = runtime.search(fixture.site, keyword: 'peer');
        final targetFrame = await fixture.probeFrame(probe.name);
        final peerFrame = await fixture.searchFrame('peer');
        scope.cancel(reason);
        await stopped;
        await Future<void>.delayed(const Duration(milliseconds: 2200));
        await fixture.reply(targetFrame['id'] as String);
        await fixture.reply(peerFrame['id'] as String);
        expect((await peer.timeout(_bound)).list, isNotEmpty);
        await fixture.until(() => fixture.observations.length == 2);
        expect(
          fixture.observations,
          unorderedEquals([
            {'id': targetFrame['id'], 'cancelled': true},
            {'id': peerFrame['id'], 'cancelled': false},
          ]),
        );
        expect(host.process.killTreeCount, 0);
        expect(host.process.isRunning, isTrue);
        // ignore: avoid_print
        print(
          '$label: actual host target context cancelled=true, peer=false; survived >2s; host kills=0',
        );
      });
    }
  }, skip: Platform.isWindows ? 'POSIX Python fixture' : false);
}
