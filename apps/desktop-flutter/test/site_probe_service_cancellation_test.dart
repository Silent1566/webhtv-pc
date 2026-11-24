import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/request_cancellation.dart';
import 'package:webhtv_pc/services/cancellable_probe_runtime.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/storage.dart';

class _ProbeRuntime extends UnsupportedRuntime
    implements CancellableProbeRuntime {
  _ProbeRuntime() : super(runtimeName: 'probe', reason: 'fixture');
  final started = Completer<void>();
  final response = Completer<SiteResult>();
  RequestCancellation? received;

  @override
  Future<SiteResult> homeCancellable(
    Site site, {
    required RequestCancellation cancellation,
  }) {
    received = cancellation;
    started.complete();
    return response.future;
  }

  @override
  Future<SiteResult> categoryCancellable(
    Site site, {
    required String typeId,
    required int page,
    Map<String, String> filters = const {},
    required RequestCancellation cancellation,
  }) => homeCancellable(site, cancellation: cancellation);
}

class _LegacyProbeRuntime extends UnsupportedRuntime {
  _LegacyProbeRuntime() : super(runtimeName: 'legacy', reason: 'fixture');
  final started = Completer<void>();
  final response = Completer<SiteResult>();

  @override
  Future<SiteResult> home(Site site) {
    started.complete();
    return response.future;
  }
}

class _ProbeRouter extends SpiderRouter {
  _ProbeRouter(this.runtime)
    : super(client: HttpApiClient(), globalHeaders: const []);
  final SiteRuntime runtime;
  var resolutions = 0;
  @override
  SiteRuntime runtimeFor(Site site) {
    resolutions++;
    return runtime;
  }
}

void main() {
  final site = Site(
    key: 's',
    name: 'Probe',
    type: 1,
    api: 'http://fixture.invalid',
  );
  test(
    'legacy runtime cancellation stops waiting and consumes a late error',
    () async {
      final runtime = _LegacyProbeRuntime();
      final router = _ProbeRouter(runtime);
      final database = AppDatabase.inMemory();
      addTearDown(router.dispose);
      addTearDown(database.dispose);
      final service = SiteService(
        appConfig: AppConfig(sites: [site]),
        router: router,
        database: database,
      );
      final cancellation = RequestCancellation();
      final operation = service.home(site, cancellation: cancellation);
      final stopped = expectLater(
        operation.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.siteCancelled,
          ),
        ),
      );
      await runtime.started.future;
      cancellation.cancel();
      await stopped;
      expect(runtime.response.isCompleted, isFalse);
      runtime.response.completeError(StateError('late legacy error'));
      await Future<void>.delayed(Duration.zero);
      expect(database.siteHealth(), isEmpty);
    },
  );

  for (final category in [false, true]) {
    test(
      '${category ? 'category' : 'home'} pre-cancel does not resolve a runtime',
      () async {
        final runtime = _ProbeRuntime();
        final router = _ProbeRouter(runtime);
        addTearDown(router.dispose);
        final service = SiteService(
          appConfig: AppConfig(sites: [site]),
          router: router,
        );
        final cancellation = RequestCancellation()..cancel();
        await expectLater(
          category
              ? service.category(site, typeId: '1', cancellation: cancellation)
              : service.home(site, cancellation: cancellation),
          throwsA(
            isA<AppError>().having(
              (e) => e.kind,
              'kind',
              AppErrorKind.siteCancelled,
            ),
          ),
        );
        expect(router.resolutions, 0);
        expect(runtime.started.isCompleted, isFalse);
      },
    );
    test(
      '${category ? 'category' : 'home'} cancellation suppresses late health writes',
      () async {
        final database = AppDatabase.inMemory();
        final runtime = _ProbeRuntime();
        final router = _ProbeRouter(runtime);
        addTearDown(database.dispose);
        addTearDown(router.dispose);
        final service = SiteService(
          appConfig: AppConfig(sites: [site]),
          router: router,
          database: database,
        );
        final cancellation = RequestCancellation();
        final operation = category
            ? service.category(site, typeId: '1', cancellation: cancellation)
            : service.home(site, cancellation: cancellation);
        final stopped = expectLater(
          operation.timeout(const Duration(seconds: 1)),
          throwsA(
            isA<AppError>().having(
              (e) => e.kind,
              'kind',
              AppErrorKind.siteCancelled,
            ),
          ),
        );
        await runtime.started.future;
        expect(runtime.received, same(cancellation));
        cancellation.cancel();
        await stopped;
        runtime.response.complete(
          SiteResult(
            list: [Vod(vodId: 'late', vodName: 'Late')],
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(database.siteHealth(), isEmpty);
      },
    );
  }
}
