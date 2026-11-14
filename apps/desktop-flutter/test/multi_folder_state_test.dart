import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/state/folder_browser_state.dart';

void main() {
  late FolderBrowserState browser;
  late SiteService service;
  final site = Site(
    key: 'fixture',
    name: '普通站点',
    type: 1,
    api: 'https://fixture.invalid/api',
  );
  final folder = Vod(vodId: '/原样?路径 &值', vodName: '目录', vodTag: 'folder');
  late Future<http.Response> Function(Uri) respond;
  final calls = <Uri>[];
  http.Response body(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  Map<String, Object?> page(List<String> ids, {int? count}) => {
    'list': [
      for (final id in ids) {'vod_id': id, 'vod_name': id, 'vod_tag': 'file'},
    ],
    'pagecount': ?count,
  };

  setUp(() {
    calls.clear();
    respond = (_) async => body(page(['file']));
    service = SiteService(
      appConfig: AppConfig(sites: [site]),
      router: SpiderRouter(
        globalHeaders: const [],
        client: HttpApiClient(
          client: MockClient((request) {
            calls.add(request.url);
            return respond(request.url);
          }),
        ),
      ),
    );
    browser = FolderBrowserState(
      service: service,
      site: site,
      folder: folder,
      filters: {'sort': '原样 /&值'},
    );
  });
  tearDown(() => browser.dispose());

  test(
    'all category pages retain original folder ID and filter snapshot',
    () async {
      respond = (uri) async => body(
        page(uri.queryParameters['pg'] == '1' ? ['a'] : ['b'], count: 2),
      );
      await browser.load();
      await browser.loadMore();
      expect(browser.items.map((v) => v.vodId), ['a', 'b']);
      expect(browser.page, 2);
      expect(browser.hasMore, isFalse);
      await browser.loadMore();
      expect(calls.length, 2);
      expect(calls.map((u) => u.queryParameters['t']), [
        '/原样?路径 &值',
        '/原样?路径 &值',
      ]);
      expect(calls.map((u) => u.queryParameters['pg']), ['1', '2']);
      for (final call in calls) {
        expect(jsonDecode(call.queryParameters['f']!), {'sort': '原样 /&值'});
        expect(call.queryParameters.containsKey('ids'), isFalse);
      }
    },
  );

  test('empty last page stops even with inaccurate pagecount', () async {
    respond = (uri) async =>
        body(page(uri.queryParameters['pg'] == '1' ? ['a'] : [], count: 100));
    await browser.load();
    await browser.loadMore();
    await browser.loadMore();
    expect(browser.items.single.vodId, 'a');
    expect(browser.hasMore, isFalse);
    expect(calls.length, 2);
  });

  test('repeated nonempty page stops without duplicate entries', () async {
    await browser.load();
    await browser.loadMore();
    await browser.loadMore();
    expect(browser.items.length, 1);
    expect(browser.hasMore, isFalse);
    expect(calls.length, 2);
  });

  test('failed pagination preserves list and retries same page', () async {
    await browser.load();
    respond = (_) async => body({'code': -1, 'msg': '暂时失败'});
    await browser.loadMore();
    expect(browser.error, isNotNull);
    expect(browser.page, 1);
    expect(browser.items.single.vodId, 'file');
    respond = (_) async => body(page(['retry'], count: 2));
    await browser.retry();
    expect(browser.error, isNull);
    expect(browser.items.map((v) => v.vodId), ['file', 'retry']);
    expect(calls.map((u) => u.queryParameters['pg']), ['1', '2', '2']);
  });

  test('empty first page is successful and cannot load more', () async {
    respond = (_) async => body(page([]));
    await browser.load();
    await browser.loadMore();
    expect(browser.error, isNull);
    expect(browser.loading, isFalse);
    expect(browser.items, isEmpty);
    expect(browser.hasMore, isFalse);
    expect(calls.length, 1);
  });

  test(
    'failed refresh retries page one while preserving loaded list',
    () async {
      await browser.load();
      respond = (_) async => body({'code': -1, 'msg': '刷新失败'});
      await browser.load();
      expect(browser.items.single.vodId, 'file');
      expect(browser.page, 1);
      respond = (_) async => body(page(['refreshed'], count: 1));
      await browser.retry();
      expect(browser.items.single.vodId, 'refreshed');
      expect(browser.page, 1);
      expect(browser.error, isNull);
      expect(calls.map((u) => u.queryParameters['pg']), ['1', '1', '1']);
    },
  );

  test(
    'failed refresh after terminal page remains retryable at page one',
    () async {
      respond = (uri) async => body(
        page(uri.queryParameters['pg'] == '1' ? ['a'] : ['b'], count: 2),
      );
      await browser.load();
      await browser.loadMore();
      expect(browser.hasMore, isFalse);
      respond = (_) async => body({'code': -1, 'msg': '刷新失败'});
      await browser.load();
      expect(browser.items.map((v) => v.vodId), ['a', 'b']);
      expect(browser.page, 2);
      respond = (_) async => body(page(['refreshed'], count: 1));
      await browser.retry();
      expect(browser.items.single.vodId, 'refreshed');
      expect(browser.page, 1);
      expect(browser.error, isNull);
      expect(calls.map((u) => u.queryParameters['pg']), ['1', '2', '1', '1']);
    },
  );

  test('failed first page can be reloaded', () async {
    respond = (_) async => body({'code': -1, 'msg': '暂时失败'});
    await browser.load();
    expect(browser.error, isNotNull);
    respond = (_) async => body(page(['retry']));
    await browser.load();
    expect(browser.error, isNull);
    expect(browser.items.single.vodId, 'retry');
  });

  test(
    'late response from superseded reload never replaces new content',
    () async {
      final old = Completer<http.Response>();
      respond = (_) => old.future;
      final pending = browser.load();
      respond = (_) async => body(page(['new']));
      await browser.load();
      old.complete(body(page(['old'])));
      await pending;
      expect(browser.items.single.vodId, 'new');
      expect(browser.error, isNull);
    },
  );

  test(
    'disposed directory ignores late response and sends no detail requests',
    () async {
      final old = Completer<http.Response>();
      respond = (_) => old.future;
      final pending = browser.load();
      final gone = browser;
      gone.dispose();
      browser = FolderBrowserState(
        service: service,
        site: site,
        folder: folder,
      );
      old.complete(body(page(['old'])));
      await pending;
      expect(gone.items, isEmpty);
      expect(calls.length, 1);
    },
  );
}
