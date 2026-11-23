import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/doh_settings.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

class _Request {
  _Request(this.request);
  final http.Request request;
  final response = Completer<http.Response>();

  void succeed() {
    if (response.isCompleted) return;
    final keyword = request.url.queryParameters['wd'];
    final page = request.url.queryParameters['pg'] ?? '1';
    response.complete(
      http.Response(
        jsonEncode({
          'page': int.parse(page),
          'pagecount': 4,
          'list': [
            {'vod_id': '$keyword-$page', 'vod_name': '$keyword page $page'},
          ],
        }),
        200,
      ),
    );
  }
}

void main() {
  late Directory root;
  late AppState state;
  late List<_Request> requests;
  late StreamController<void> arrivals;
  var disposed = false;

  Future<_Request> requestAt(int index) async {
    while (requests.length <= index) {
      await arrivals.stream.first.timeout(const Duration(seconds: 2));
    }
    return requests[index];
  }

  Future<void> importSites([int count = 1]) async {
    expect(
      await state.importConfig(
        jsonEncode({
          'sites': [
            for (var i = 0; i < count; i++)
              {
                'key': 's$i',
                'name': 'Site $i',
                'type': 1,
                'api': 'http://fixture.invalid/api/$i',
                'searchable': 1,
              },
          ],
        }),
      ),
      isTrue,
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('search-inflight-');
    requests = [];
    arrivals = StreamController<void>.broadcast();
    disposed = false;
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': root.path,
          'data': root.path,
          'cache': '${root.path}/cache',
          'state': '${root.path}/state',
        },
      ),
      log: LogService(),
      httpClient: MockClient((request) {
        if (!request.url.queryParameters.containsKey('wd')) {
          return Future.value(http.Response('{"class":[],"list":[]}', 200));
        }
        final pending = _Request(request);
        requests.add(pending);
        arrivals.add(null);
        return pending.response.future;
      }),
    );
    await importSites();
  });

  tearDown(() async {
    for (final request in requests) {
      request.succeed();
    }
    await Future<void>.delayed(Duration.zero);
    if (!disposed) state.dispose();
    await arrivals.close();
    await root.delete(recursive: true);
  });

  test(
    'cancel promptly settles a hung search without publishing late results',
    () async {
      final searching = state.searchAll('old');
      final request = await requestAt(0);
      state.cancelSearch();
      final outcome = await searching.timeout(
        const Duration(milliseconds: 200),
      );
      expect(outcome.cancelled, isTrue);
      expect(outcome.finished, isTrue);
      expect(outcome.results, isEmpty);
      request.succeed();
      await Future<void>.delayed(Duration.zero);
      expect(state.activeSearch, same(outcome));
      expect(outcome.results, isEmpty);
    },
  );

  test('cancel preserves a published initial result and does not start queued sites', () async {
    await importSites(3);
    final published = Completer<void>();
    void onResult() {
      if (state.activeSearch?.results.isNotEmpty == true &&
          !published.isCompleted) {
        published.complete();
      }
    }

    state.addListener(onResult);
    final searching = state.searchAll('query', maxConcurrency: 1);
    (await requestAt(0)).succeed();
    await published.future;
    await requestAt(1);
    state.cancelSearch();
    final outcome = await searching.timeout(const Duration(milliseconds: 200));
    expect(outcome.results.single.siteKey, 's0');
    expect(outcome.results.single.itemCount, 1);
    expect(requests.length, 2);
    state.removeListener(onResult);
  });

  for (final action in ['supersede', 'clear', 'config', 'dispose']) {
    test('$action promptly invalidates a hung initial search', () async {
      final searching = state.searchAll('old');
      await requestAt(0);
      switch (action) {
        case 'supersede':
          final replacement = state.searchAll('new');
          (await requestAt(1)).succeed();
          expect((await replacement).keyword, 'new');
        case 'clear':
          state.clearSearch();
        case 'config':
          await importSites(2);
        case 'dispose':
          state.dispose();
          disposed = true;
      }
      final old = await searching.timeout(const Duration(milliseconds: 200));
      expect(old.results, isEmpty);
      if (action == 'clear') expect(state.activeSearch, isNull);
      if (action == 'supersede') {
        expect(state.activeSearch!.keyword, 'new');
        expect(
          old.cancelled,
          isFalse,
          reason: 'superseded is not user-cancelled',
        );
      }
    });
  }

  test('a site timeout frees its worker for the next queued site', () async {
    await importSites(2);
    final searching = state.searchAll(
      'query',
      maxConcurrency: 1,
      timeout: const Duration(milliseconds: 80),
    );
    await requestAt(0);
    (await requestAt(1)).succeed();
    final outcome = await searching;
    expect(outcome.results[0].error!.kind, AppErrorKind.siteTimeout);
    expect(outcome.results[1].succeeded, isTrue);
    expect(outcome.results[1].itemCount, 1);
  });

  test(
    'cancel works for a pending page after the initial batch finished',
    () async {
      final searching = state.searchAll('query');
      (await requestAt(0)).succeed();
      final outcome = await searching;
      expect(outcome.finished, isTrue);
      final paging = state.loadMoreSearch('s0');
      final page = await requestAt(1);
      state.cancelSearch();
      expect(await paging.timeout(const Duration(milliseconds: 200)), isFalse);
      expect(outcome.cancelled, isTrue);
      expect(outcome.entryOf('s0')!.loadingMore, isFalse);
      expect(outcome.entryOf('s0')!.itemCount, 1);
      page.succeed();
      await Future<void>.delayed(Duration.zero);
      expect(outcome.entryOf('s0')!.itemCount, 1);
    },
  );

  for (final action in ['clear', 'config', 'dispose']) {
    test(
      '$action cancels a pending page and preserves published items',
      () async {
        final searching = state.searchAll('query');
        (await requestAt(0)).succeed();
        final snapshot = await searching;
        final paging = state.loadMoreSearch('s0');
        final page = await requestAt(1);
        switch (action) {
          case 'clear':
            state.clearSearch();
          case 'config':
            await importSites(2);
          case 'dispose':
            state.dispose();
            disposed = true;
        }
        expect(
          await paging.timeout(const Duration(milliseconds: 200)),
          isFalse,
        );
        expect(snapshot.entryOf('s0')!.itemCount, 1);
        expect(snapshot.entryOf('s0')!.loadingMore, isFalse);
        page.succeed();
        await Future<void>.delayed(Duration.zero);
        expect(snapshot.entryOf('s0')!.itemCount, 1);
      },
    );
  }

  test('service replacement cancels work even when the configuration stays the same', () async {
    await state.bootstrap();
    final searching = state.searchAll('old');
    await requestAt(0);
    final originalService = state.siteService;
    await state.setDohSettings(DohSettings.defaults);
    expect(state.siteService, isNot(same(originalService)));
    expect(
      (await searching.timeout(const Duration(milliseconds: 200))).results,
      isEmpty,
    );
  });

  test(
    'synchronous listener cancellation cannot launch a page request afterwards',
    () async {
      final searching = state.searchAll('query');
      (await requestAt(0)).succeed();
      await searching;
      void cancelOnLoading() {
        if (state.activeSearch!.entryOf('s0')!.loadingMore) {
          state.cancelSearch();
        }
      }

      state.addListener(cancelOnLoading);
      final paging = state.loadMoreSearch(
        's0',
        timeout: const Duration(milliseconds: 80),
      );
      expect(await paging.timeout(const Duration(milliseconds: 200)), isFalse);
      state.removeListener(cancelOnLoading);
      expect(requests.length, 1);
      expect(state.activeSearch!.cancelled, isTrue);
      expect(state.activeSearch!.entryOf('s0')!.loadingMore, isFalse);
    },
  );

  test(
    'old page completion cannot clear a new batch paging registration',
    () async {
      final oldSearch = state.searchAll('old');
      (await requestAt(0)).succeed();
      await oldSearch;
      final oldPage = state.loadMoreSearch('s0');
      final oldRequest = await requestAt(1);
      final newSearch = state.searchAll('new');
      (await requestAt(2)).succeed();
      await newSearch;
      final newPage = state.loadMoreSearch('s0');
      final newRequest = await requestAt(3);
      oldRequest.succeed();
      expect(await oldPage, isFalse);
      expect(
        await state
            .loadMoreSearch('s0')
            .timeout(const Duration(milliseconds: 200)),
        isFalse,
      );
      expect(requests.length, 4);
      newRequest.succeed();
      expect(await newPage, isTrue);
      expect(state.searchPageOf('s0'), 2);
      expect(state.activeSearch!.entryOf('s0')!.itemCount, 2);
    },
  );
}
