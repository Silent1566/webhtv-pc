import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/request_cancellation.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/storage.dart';

class _Router extends SpiderRouter {
  _Router() : super(client: HttpApiClient(), globalHeaders: const []);
  final started = Completer<void>();
  final response = Completer<SiteResult>();
  RequestCancellation? received;
  var calls = 0;

  @override
  Future<SiteResult> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
    HttpApiClient? client,
    RequestCancellation? cancellation,
  }) {
    calls++;
    received = cancellation;
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}

void main() {
  final site = Site(
    key: 's',
    name: 'Site',
    type: 1,
    api: 'http://fixture.invalid/api',
    searchable: true,
  );
  final result = SiteResult(
    list: [Vod(vodId: 'fresh', vodName: 'Fresh')],
  );
  late AppDatabase database;
  late _Router router;
  late SiteService service;

  setUp(() {
    database = AppDatabase.inMemory();
    router = _Router();
    service = SiteService(
      appConfig: AppConfig(sites: [site]),
      router: router,
      database: database,
    );
  });
  tearDown(() {
    router.dispose();
    database.dispose();
  });

  Future<SiteCallResult<SiteResult>> search(RequestCancellation cancellation) =>
      service.search(site, keyword: 'query', cancellation: cancellation);

  test(
    'explicit runtime cancellation never records a health failure',
    () async {
      final searching = service.search(site, keyword: 'query');
      final checked = expectLater(
        searching,
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.siteCancelled,
          ),
        ),
      );
      router.response.completeError(
        AppError(AppErrorKind.siteCancelled, 'cancelled'),
      );
      await checked;
      expect(database.siteHealth(), isEmpty);
      expect(database.readSearchCache(keyword: 'query', siteKey: 's'), isNull);
    },
  );

  test('pre-cancelled search cannot read an existing cache hit', () async {
    database.cacheSearch(
      keyword: 'query',
      siteKey: 's',
      payload: result.toCacheJson(),
    );
    final cancellation = RequestCancellation()..cancel();
    await expectLater(
      search(cancellation),
      throwsA(
        isA<AppError>().having(
          (error) => error.kind,
          'kind',
          AppErrorKind.siteCancelled,
        ),
      ),
    );
    expect(router.calls, 0);
    expect(database.siteHealth(), isEmpty);
  });

  test(
    'cancel stops local wait and late success cannot cache or record health',
    () async {
      final cancellation = RequestCancellation();
      final searching = search(cancellation);
      final checked = expectLater(
        searching.timeout(const Duration(milliseconds: 200)),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.siteCancelled,
          ),
        ),
      );
      await router.started.future;
      expect(router.received, same(cancellation));
      cancellation.cancel();
      await checked;
      expect(database.siteHealth(), isEmpty);
      router.response.complete(result);
      await Future<void>.delayed(Duration.zero);
      expect(database.readSearchCache(keyword: 'query', siteKey: 's'), isNull);
      expect(database.siteHealth(), isEmpty);
    },
  );

  test('late success cannot overwrite a newer cached result', () async {
    final cancellation = RequestCancellation();
    final searching = search(cancellation);
    final checked = expectLater(searching, throwsA(isA<AppError>()));
    await router.started.future;
    cancellation.cancel();
    await checked;
    final newer = SiteResult(
      list: [Vod(vodId: 'newer', vodName: 'Newer')],
    );
    database.cacheSearch(
      keyword: 'query',
      siteKey: 's',
      payload: newer.toCacheJson(),
    );
    router.response.complete(result);
    await Future<void>.delayed(Duration.zero);
    final cached = await service.search(site, keyword: 'query');
    expect(cached.value.list.single.vodId, 'newer');
    expect(database.siteHealth(), isEmpty);
  });

  test(
    'late errors after cancellation are observed without health failure',
    () async {
      final cancellation = RequestCancellation();
      final searching = search(cancellation);
      final checked = expectLater(searching, throwsA(isA<AppError>()));
      await router.started.future;
      cancellation.cancel();
      await checked;
      router.response.completeError(StateError('late failure'));
      await Future<void>.delayed(Duration.zero);
      expect(database.siteHealth(), isEmpty);
      expect(database.readSearchCache(keyword: 'query', siteKey: 's'), isNull);
    },
  );

  test('cancellation wins a completed router result before cache and health publication', () async {
    final cancellation = RequestCancellation();
    final searching = search(cancellation);
    final checked = expectLater(searching, throwsA(isA<AppError>()));
    await router.started.future;
    router.response.complete(result);
    cancellation.cancel();
    await checked;
    expect(database.readSearchCache(keyword: 'query', siteKey: 's'), isNull);
    expect(database.siteHealth(), isEmpty);
  });

  test(
    'true timeout promptly counts one failure and no late success',
    () async {
      final cancellation = RequestCancellation();
      final searching = search(cancellation);
      final checked = expectLater(
        searching.timeout(const Duration(milliseconds: 200)),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.siteTimeout,
          ),
        ),
      );
      await router.started.future;
      cancellation.cancel(
        AppError(AppErrorKind.siteTimeout, 'search budget exceeded'),
      );
      await checked;
      expect(database.siteHealth().single.homeTotal, 1);
      expect(database.siteHealth().single.homeOk, 0);
      expect(database.siteHealth().single.lastError, contains('siteTimeout'));
      router.response.complete(result);
      await Future<void>.delayed(Duration.zero);
      expect(database.siteHealth().single.homeTotal, 1);
      expect(database.readSearchCache(keyword: 'query', siteKey: 's'), isNull);
    },
  );

  test(
    'ordinary success still caches and records exactly one success',
    () async {
      final cancellation = RequestCancellation();
      final searching = search(cancellation);
      router.response.complete(result);
      expect((await searching).value.list.single.vodId, 'fresh');
      expect(database.siteHealth().single.homeOk, 1);
      expect(database.siteHealth().single.homeTotal, 1);
      expect(
        database.readSearchCache(keyword: 'query', siteKey: 's'),
        isNotNull,
      );
      final cached = await service.search(site, keyword: 'query');
      expect(cached.fromCache, isTrue);
      expect(router.calls, 1);
      expect(database.siteHealth().single.homeTotal, 1);
    },
  );
}
