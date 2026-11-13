/// 站点列表治理（手动顺序 + 屏蔽）在 AppState 层的闭环。
///
/// 为什么单独一个文件：这里同时要真 HTTP（屏蔽站点连请求都不发）和真落盘
/// （按配置作用域写 `siteList`），而 `TestWidgetsFlutterBinding` 会把
/// `HttpClient` 固定返回 400——所以整份文件只用普通 `test()`，不出现
/// `testWidgets`（`source_swap_state_test.dart` 文件头记录过同一坑）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/test_fixture_server.dart';

void main() {
  late TestFixtureServer server;
  late Directory tempDir;
  late AppPaths paths;
  late AppState state;
  late bool stateDisposed;

  Map<String, Object?> readSettings() {
    final file = File(paths.settingsPath);
    if (!file.existsSync()) return const {};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }

  List<String> keysOf(List<SiteListItem> items) => [
    for (final item in items) item.site.key,
  ];

  /// 某个站点收到的 `/search` 请求（按 api 路径区分站点）。
  List<CapturedRequest> searchCallsOf(String apiMarker) => server.captured
      .where(
        (item) =>
            item.path.contains(apiMarker) && item.path.endsWith('/search'),
      )
      .toList();

  setUp(() async {
    server = await TestFixtureServer.start();
    tempDir = await Directory.systemTemp.createTemp('webhtv-site-list');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/webhtv-pc',
        'data': '${tempDir.path}/webhtv-pc',
        'cache': '${tempDir.path}/webhtv-pc/cache',
        'state': '${tempDir.path}/webhtv-pc/logs',
      },
    );
    state = AppState(paths: paths, log: LogService());
    stateDisposed = false;
    await state.bootstrap();
    final ok = await state.importConfig(
      jsonEncode({
        'name': '站点治理测试',
        'sites': [
          {
            'key': 'site-a',
            'name': '木偶[盘]',
            'type': 3,
            'api': '${server.baseUrl}/cathttp/ok/spider/demo',
            'searchable': 1,
          },
          {
            'key': 'site-b',
            'name': '金牌[采]',
            'type': 3,
            'api': '${server.baseUrl}/cathttp/ok/spider/other',
            'searchable': 1,
          },
          {
            'key': 'site-c',
            'name': '备用[盘]',
            'type': 3,
            'api': '${server.baseUrl}/cathttp/ok/spider/third',
            'searchable': 1,
          },
        ],
      }),
    );
    expect(ok, isTrue, reason: '配置导入应成功');
  });

  tearDown(() async {
    if (!stateDisposed) state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    await server.stop();
  });

  test('手动顺序立即生效于 siteItems，并按配置作用域落盘', () async {
    expect(keysOf(state.siteItems), ['site-a', 'site-b', 'site-c']);

    expect(
      await state.setSiteManualOrder(['site-c', 'site-a', 'site-b']),
      isTrue,
    );
    expect(keysOf(state.siteItems), ['site-c', 'site-a', 'site-b']);

    final scope = state.siteListScopeKey;
    expect(scope, startsWith('config:'), reason: '生产口径是按配置记录 id');
    final siteList = readSettings()['siteList'] as Map<String, Object?>;
    expect(
      ((siteList[scope] as Map<String, Object?>)['order'] as List)
          .cast<String>(),
      ['site-c', 'site-a', 'site-b'],
    );
  });

  test('恢复默认（空顺序）回到配置顺序，且不留下手动顺序段', () async {
    await state.setSiteManualOrder(['site-b', 'site-a', 'site-c']);
    expect(await state.setSiteManualOrder(const []), isTrue);
    expect(keysOf(state.siteItems), ['site-a', 'site-b', 'site-c']);

    final siteList = (readSettings()['siteList'] as Map?) ?? const {};
    expect(
      (siteList[state.siteListScopeKey] as Map?)?.containsKey('order') ?? false,
      isFalse,
    );
  });

  test('屏蔽站点离开搜索范围分组，但保留在 siteItems 里（当前站点不悬空）', () async {
    expect(state.searchScopeGroups, containsAll(['盘', '采']));

    expect(await state.setSiteBlocked('site-b', true), isTrue);
    expect(state.blockedSiteKeys, {'site-b'});
    expect(keysOf(state.siteItems), [
      'site-a',
      'site-b',
      'site-c',
    ], reason: '屏蔽只影响列表与搜索，不把站点从配置里摘掉');
    expect(state.searchScopeGroups, ['盘'], reason: '只由被屏蔽站点支撑的分组（采）不该留在搜索范围里');

    expect(await state.setSiteBlocked('site-b', false), isTrue);
    expect(state.blockedSiteKeys, isEmpty);
    expect(state.searchScopeGroups, containsAll(['盘', '采']));
  });

  test('被屏蔽站点不参与搜索：连请求都不发', () async {
    await state.setSiteBlocked('site-b', true);
    server.captured.clear();

    final outcome = await state.searchAll('site-list-kw');

    expect(outcome.results.map((entry) => entry.siteKey).toList(), [
      'site-a',
      'site-c',
    ], reason: '被屏蔽站点不得出现在结果里');
    expect(
      searchCallsOf('/spider/other'),
      isEmpty,
      reason: '被屏蔽站点连搜索请求都不该发（不是收不到结果）',
    );
  });

  test('屏蔽只影响当前配置：换配置不继承', () async {
    final firstScope = state.siteListScopeKey;
    await state.setSiteBlocked('site-b', true);
    expect(state.blockedSiteKeys, {'site-b'});

    // 第二份配置：与第一份不同 origin，才不会被 `saveConfig` 按来源去重成同一条记录。
    final db = state.database!;
    final secondId = db.saveConfig(
      name: '第二份配置',
      origin: 'https://second.example/config.json',
      json: {
        'name': '第二份配置',
        'sites': [
          {
            'key': 'site-b',
            'name': '金牌[采]',
            'type': 3,
            'api': '${server.baseUrl}/cathttp/ok/spider/other',
            'searchable': 1,
          },
        ],
      },
      siteCount: 1,
      makeActive: true,
    );
    expect(await state.activateConfigRecord(secondId), isTrue);

    expect(state.siteListScopeKey, isNot(firstScope), reason: '第二份配置必须是独立作用域');
    expect(
      state.siteListOverrides.order,
      isEmpty,
      reason: '顺序同样是按配置分桶的，不得跨配置继承',
    );
  });

  test('解除屏蔽后站点保持在手动顺序里的原位', () async {
    await state.setSiteManualOrder(['site-c', 'site-a', 'site-b']);
    await state.setSiteBlocked('site-a', true);

    expect(state.siteListOverrides.order, [
      'site-c',
      'site-a',
      'site-b',
    ], reason: '屏蔽只改屏蔽集合，不该把 key 从顺序里抹掉');
    expect(keysOf(state.siteItems), ['site-c', 'site-a', 'site-b']);

    await state.setSiteBlocked('site-a', false);
    expect(keysOf(state.siteItems), ['site-c', 'site-a', 'site-b']);
  });

  test('重启后手动顺序与屏蔽都从 settings.json 读回', () async {
    await state.setSiteManualOrder(['site-c', 'site-a', 'site-b']);
    await state.setSiteBlocked('site-b', true);
    final scope = state.siteListScopeKey;
    // 同一进程里不并存两个 AppState（同一个库/同一份 settings.json），先释放再重开。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    state.dispose();
    stateDisposed = true;

    final reopened = AppState(paths: paths, log: LogService());
    addTearDown(reopened.dispose);
    await reopened.bootstrap();
    if (reopened.effectiveConfig == null) {
      expect(
        await reopened.activateConfigRecord(reopened.activeRecord!.id),
        isTrue,
      );
    }

    expect(reopened.siteListScopeKey, scope, reason: '作用域仍是同一条配置记录');
    expect(keysOf(reopened.siteItems), ['site-c', 'site-a', 'site-b']);
    expect(reopened.blockedSiteKeys, {'site-b'});
  });

  test('重启不把被屏蔽站点恢复成当前站点', () async {
    final target = state.siteItems.firstWhere(
      (item) => item.site.key == 'site-b',
    );
    await state.selectSite(target.site);
    // selectSite 异步写 lastSiteKey（不 await 落盘），先让它写完再屏蔽。
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await state.setSiteBlocked('site-b', true);
    state.dispose();
    stateDisposed = true;

    final reopened = AppState(paths: paths, log: LogService());
    addTearDown(reopened.dispose);
    await reopened.bootstrap();
    if (reopened.effectiveConfig == null) {
      expect(
        await reopened.activateConfigRecord(reopened.activeRecord!.id),
        isTrue,
      );
    }

    expect(
      reopened.selectedSite?.key,
      isNot('site-b'),
      reason: '屏蔽的站点不再作为下次选择的起点',
    );
    expect(reopened.selectedSite, isNotNull, reason: '仍要有一个可用的起点站点');
  });
}
