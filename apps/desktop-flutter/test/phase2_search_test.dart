/// 多站点并发搜索与取消门禁测试（设计文档 §14.1、§14.3、§14.2）。
///
/// 覆盖 `docs/phase2/README.md` §3「搜索并发与取消」门禁：
/// - fixture 多站点并发搜索；
/// - 单站点失败**不阻塞**其他站点（失败站点保留错误状态而不是消失）；
/// - 取消后**不再投递**任何在途结果；
/// - 被更新的查询取代的旧批次同样不投递结果；
/// - 结果按配置顺序稳定排序；未声明 `searchable` 与运行时不可用的站点被跳过并计数。
///
/// 用真实 `AppState` + 真实 HTTP（`TestFixtureServer`）驱动，只有这样才能证明
/// 「迟到结果不投递」这类时序约束真的成立。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/concurrency_probe.dart';
import 'support/test_fixture_server.dart';

void main() {
  late TestFixtureServer server;
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    server = await TestFixtureServer.start();
    tempDir = await Directory.systemTemp.createTemp('webhtv-search');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
    );
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
    await server.stop();
  });

  Map<String, Object?> siteOf(
    String key,
    String api, {
    bool searchable = true,
    int type = 1,
  }) => {
    'key': key,
    'name': '站点 $key',
    'type': type,
    'api': api,
    if (searchable) 'searchable': 1,
    if (searchable) 'quickSearch': 1,
  };

  Future<void> importSites(List<Map<String, Object?>> sites) async {
    final ok = await state.importConfig(
      jsonEncode({'name': '并发搜索测试', 'sites': sites}),
    );
    expect(ok, isTrue, reason: '配置导入应成功');
  }

  /// 成功站点：fixture 的 `/api/type1/` 在带 `wd` 时返回 1 条结果。
  String okApi() => '${server.baseUrl}/api/type1/';

  /// 慢站点：`/api/slow` 按 `delay` 秒延迟后再返回。
  String slowApi(double seconds) =>
      '${server.baseUrl}/api/slow?delay=$seconds';

  /// 取一个确定已关闭的本机端口，用来制造真实的连接失败。
  Future<int> deadPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  // ---------------------------------------------------------------------------
  // 并发与失败隔离（§14.1、§14.3）
  // ---------------------------------------------------------------------------
  group('多站点并发搜索（§14.1、§14.3）', () {
    test('结果按配置顺序稳定排序，全部 searchable 站点都有条目', () async {
      final dead = await deadPort();
      await importSites([
        siteOf('s-a', okApi()),
        siteOf('s-b', okApi()),
        siteOf('s-c', 'http://127.0.0.1:$dead/api/type1/'),
      ]);

      final outcome = await state.searchAll('样本', maxConcurrency: 2);

      expect(
        outcome.results.map((entry) => entry.siteKey).toList(),
        ['s-a', 's-b', 's-c'],
        reason: '并发完成顺序不得改变结果的配置顺序',
      );
      expect(outcome.finished, isTrue);
      expect(outcome.keyword, '样本');
      expect(outcome.succeededCount, 2);
      expect(outcome.failedCount, 1);
    });

    test('单站点失败不阻塞其他站点，失败站点保留错误状态', () async {
      final dead = await deadPort();
      await importSites([
        siteOf('s-a', okApi()),
        siteOf('s-fail', 'http://127.0.0.1:$dead/api/type1/'),
        siteOf('s-b', okApi()),
      ]);

      final outcome = await state.searchAll('样本', maxConcurrency: 3);

      final byKey = {
        for (final entry in outcome.results) entry.siteKey: entry,
      };
      expect(byKey.keys, containsAll(['s-a', 's-fail', 's-b']));
      // 成功站点有结果。
      expect(byKey['s-a']!.succeeded, isTrue);
      expect(byKey['s-b']!.succeeded, isTrue);
      expect(byKey['s-a']!.result!.list, isNotEmpty);
      // 失败站点保留错误，不消失、不影响其他站点（§14.3）。
      expect(byKey['s-fail']!.succeeded, isFalse);
      expect(byKey['s-fail']!.error, isNotNull);
      expect(byKey['s-fail']!.result, isNull);
      // 整批必须正常结束，而不是被单站点失败中断。
      expect(outcome.finished, isTrue);
    });

    test('两个慢站点在 maxConcurrency=2 下并发执行（非串行）', () async {
      // `TestFixtureServer` 用 `await for` + `await _handle` 串行处理请求，
      // 无法用来观测客户端并发；这里用自带并发上游记录同时在途的峰值。
      final probe = await ConcurrencyProbe.start(holdMs: 400);
      try {
        await importSites([siteOf('s-1', probe.api), siteOf('s-2', probe.api)]);

        final outcome = await state.searchAll('样本', maxConcurrency: 2);

        expect(outcome.succeededCount, 2);
        expect(
          probe.maxInFlight,
          2,
          reason: '两个站点必须同时在途；峰值=1 说明被串行化',
        );
      } finally {
        await probe.stop();
      }
    });

    test('未声明 searchable 与运行时不可用的站点被跳过并计数（§8.1）', () async {
      await importSites([
        siteOf('s-ok', okApi()),
        siteOf('s-nosearch', okApi(), searchable: false),
        siteOf('s-js', 'http://h:1/spider/a.js', type: 3),
      ]);

      final outcome = await state.searchAll('样本');

      expect(outcome.skippedNotSearchable, 1);
      expect(outcome.skippedUnsupported, 1);
      expect(
        outcome.results.map((entry) => entry.siteKey).toList(),
        ['s-ok'],
        reason: '只有可搜索且运行时可用的站点才参与',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 取消与取代（§14.1「可取消搜索」、§9.5）
  // ---------------------------------------------------------------------------
  group('取消与批次取代（§14.1）', () {
    test('取消后不再投递任何在途结果', () async {
      await importSites([siteOf('s-slow', slowApi(1.0))]);

      final future = state.searchAll(
        '样本',
        maxConcurrency: 1,
        timeout: const Duration(seconds: 10),
      );
      // 确认请求已在途，再取消。
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(state.activeSearch, isNotNull);
      state.cancelSearch();

      final outcome = await future;

      expect(outcome.cancelled, isTrue);
      expect(outcome.finished, isTrue);
      expect(
        outcome.results,
        isEmpty,
        reason: '取消后即便请求刚好返回也不得投递结果（§14.1）',
      );
    });

    test('新查询取代旧批次：旧批次结果不再投递', () async {
      await importSites([
        siteOf('s-slow', slowApi(1.0)),
        siteOf('s-fast', okApi()),
      ]);

      // maxConcurrency=1 保证先处理慢站点，制造“在途 + 被取代”的窗口。
      final stale = state.searchAll('旧关键词', maxConcurrency: 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final fresh = state.searchAll('新关键词', maxConcurrency: 1);

      final staleOutcome = await stale;
      final freshOutcome = await fresh;

      expect(staleOutcome.results, isEmpty, reason: '被取代的批次不得投递结果');
      expect(freshOutcome.finished, isTrue);
      expect(freshOutcome.keyword, '新关键词');
      expect(
        freshOutcome.results.map((entry) => entry.siteKey),
        contains('s-slow'),
      );
    });

    test('取消只影响当前批次，之后可以正常发起新搜索', () async {
      await importSites([siteOf('s-slow', slowApi(1.0)), siteOf('s-fast', okApi())]);

      final first = state.searchAll('第一次', maxConcurrency: 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      state.cancelSearch();
      final cancelledOutcome = await first;
      expect(cancelledOutcome.cancelled, isTrue);

      final second = await state.searchAll('第二次', maxConcurrency: 2);
      expect(second.cancelled, isFalse);
      expect(second.finished, isTrue);
      expect(second.failedCount, 0);
    });

    test('搜索历史去重且最新在前（§14.1）', () async {
      await importSites([siteOf('s-fast', okApi())]);

      await state.searchAll('甲');
      await state.searchAll('乙');
      await state.searchAll('甲');

      expect(state.recentSearchKeywords.first, '甲');
      expect(state.recentSearchKeywords.where((k) => k == '甲').length, 1);
      expect(state.recentSearchKeywords, containsAll(['甲', '乙']));
    });
  });

  // ---------------------------------------------------------------------------
  // 搜索范围限定（对齐上游 SearchFragment 的 scope 菜单）
  // ---------------------------------------------------------------------------
  group('搜索范围限定（上游对齐）', () {
    test('限定单站点：只有该站点参与，其余既不算跳过也不算失败', () async {
      await importSites([
        siteOf('s-a', okApi()),
        siteOf('s-b', okApi()),
        siteOf('s-c', okApi()),
      ]);

      final outcome = await state.searchAll('样本', siteKey: 's-b');

      expect(outcome.results.map((e) => e.siteKey), ['s-b']);
      expect(outcome.siteKey, 's-b');
      expect(outcome.scoped, isTrue);
      expect(outcome.skippedUnsupported, 0, reason: '范围外站点不计入跳过统计');
      expect(outcome.skippedNotSearchable, 0);
    });

    test('限定分组：只搜命中该分组的站点', () async {
      await importSites([
        siteOf('s-a', okApi())..['name'] = '甲站[盘]',
        siteOf('s-b', okApi())..['name'] = '乙站[采]',
        siteOf('s-c', okApi())..['name'] = '丙站[盘]',
        siteOf('s-d', okApi()),
      ]);

      final outcome = await state.searchAll('样本', group: '盘');

      expect(outcome.results.map((e) => e.siteKey), ['s-a', 's-c']);
      expect(outcome.group, '盘');
      expect(outcome.scoped, isTrue);
    });

    test('范围内的不可用站点仍计入 skippedUnsupported', () async {
      await importSites([
        siteOf('s-a', okApi())..['name'] = '甲站[盘]',
        // 运行时不可用（JS 站点无 sidecar）但属于同一分组。
        siteOf('s-js', 'http://h:1/spider/a.js', type: 3)..['name'] = '乙站[盘]',
        siteOf('s-b', okApi())..['name'] = '丙站[采]',
      ]);

      final outcome = await state.searchAll('样本', group: '盘');

      expect(outcome.results.map((e) => e.siteKey), ['s-a']);
      expect(outcome.skippedUnsupported, 1, reason: '同分组内不可用站点要如实计数');
    });

    test('范围不限定时 siteKey/group 为空且不计入范围', () async {
      await importSites([siteOf('s-a', okApi())]);
      final outcome = await state.searchAll('样本');
      expect(outcome.siteKey, isEmpty);
      expect(outcome.group, isEmpty);
      expect(outcome.scoped, isFalse);
    });

    test('范围内没有站点时批次正常结束且零结果', () async {
      await importSites([siteOf('s-a', okApi())]);
      final outcome = await state.searchAll('样本', group: '不存在的分组');
      expect(outcome.finished, isTrue);
      expect(outcome.results, isEmpty);
      expect(outcome.succeededCount, 0);
    });

    test('范围过滤后不可搜索的站点计入 skippedNotSearchable', () async {
      await importSites([
        siteOf('s-a', okApi())..['name'] = '甲站[盘]',
        siteOf('s-nosearch', okApi(), searchable: false)..['name'] = '乙站[盘]',
      ]);
      final outcome = await state.searchAll('样本', group: '盘');
      expect(outcome.results.map((e) => e.siteKey), ['s-a']);
      expect(outcome.skippedNotSearchable, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // 结果分页加载（对齐上游 CollectFragment.onLoadMore + SearchPageState）
  // ---------------------------------------------------------------------------
  group('结果分页加载（上游对齐）', () {
    /// 分页站点：`pg` 参数决定返回内容，`pagecount` 可显式指定。
    String pagedApi({int pageCount = 3, bool repeatAfterFirst = false}) =>
        '${server.baseUrl}/api/paged?pageCount=$pageCount'
        '&repeatAfterFirst=$repeatAfterFirst';

    test('翻页追加条目、推进页码、保留原顺序', () async {
      await importSites([
        siteOf('s-a', pagedApi()),
        siteOf('s-b', pagedApi()),
      ]);
      final outcome = await state.searchAll('样本', maxConcurrency: 2);
      expect(outcome.entryOf('s-a')!.itemCount, greaterThan(0));
      expect(outcome.entryOf('s-a')!.page, 1);
      expect(outcome.entryOf('s-a')!.hasMore, isTrue);
      final before = outcome.entryOf('s-a')!.itemCount;

      final accepted = await state.loadMoreSearch('s-a');

      expect(accepted, isTrue, reason: '第 2 页应被接受');
      final entry = outcome.entryOf('s-a')!;
      expect(entry.page, 2);
      expect(entry.itemCount, greaterThan(before), reason: '条目应追加');
      expect(entry.loadingMore, isFalse);
      expect(
        outcome.results.map((e) => e.siteKey),
        ['s-a', 's-b'],
        reason: '翻页不得改变站点顺序',
      );
    });

    test('页内容与已见过的重复时判该站点耗尽且不追加', () async {
      await importSites([siteOf('s-a', pagedApi(repeatAfterFirst: true))]);
      final outcome = await state.searchAll('样本');
      final before = outcome.entryOf('s-a')!.itemCount;

      final accepted = await state.loadMoreSearch('s-a');

      expect(accepted, isFalse, reason: '重复内容不接受');
      final entry = outcome.entryOf('s-a')!;
      expect(entry.itemCount, before, reason: '不追加');
      expect(entry.page, 1, reason: '页码不推进');
      expect(entry.hasMore, isFalse, reason: '已耗尽');
      // 再翻也应当被直接拒绝（不发出请求）。
      expect(await state.loadMoreSearch('s-a'), isFalse);
    });

    test('已到达上游声明的末页时 hasMore 为 false', () async {
      await importSites([siteOf('s-a', pagedApi(pageCount: 1))]);
      final outcome = await state.searchAll('样本');
      final entry = outcome.entryOf('s-a')!;
      expect(entry.pageCount, 1);
      expect(entry.hasMore, isFalse);
      expect(await state.loadMoreSearch('s-a'), isFalse);
    });

    test('页数未知（pagecount=0）时允许一直翻', () async {
      await importSites([siteOf('s-a', pagedApi(pageCount: 0))]);
      final outcome = await state.searchAll('样本');
      expect(outcome.entryOf('s-a')!.pageCount, 0);
      expect(outcome.entryOf('s-a')!.hasMore, isTrue);
      expect(await state.loadMoreSearch('s-a'), isTrue);
      expect(outcome.entryOf('s-a')!.page, 2);
    });

    test('失败站点 / 零结果站点不允许翻页', () async {
      final dead = await deadPort();
      await importSites([
        siteOf('s-fail', 'http://127.0.0.1:$dead/api/type1/'),
        siteOf('s-empty', '${server.baseUrl}/api/empty'),
      ]);
      final outcome = await state.searchAll('样本');

      expect(outcome.entryOf('s-fail')!.succeeded, isFalse);
      expect(await state.loadMoreSearch('s-fail'), isFalse);
      expect(outcome.entryOf('s-empty')!.itemCount, 0);
      expect(await state.loadMoreSearch('s-empty'), isFalse);
    });

    test('新搜索会清空分页状态（不会沿用上一批次的页码）', () async {
      await importSites([siteOf('s-a', pagedApi())]);
      final first = await state.searchAll('第一次');
      await state.loadMoreSearch('s-a');
      expect(first.entryOf('s-a')!.page, 2);

      final second = await state.searchAll('第二次');
      expect(second.entryOf('s-a')!.page, 1, reason: '新批次从第 1 页开始');
      expect(state.searchPageOf('s-a'), 1);
    });

    test('翻页请求失败时结束加载态且不卡死（可重试）', () async {
      await importSites([siteOf('s-a', pagedApi())]);
      final outcome = await state.searchAll('样本');
      expect(outcome.entryOf('s-a')!.hasMore, isTrue);

      // 让上游在翻页时失败：临时把站点 api 指向已关闭端口不可行（站点已保存），
      // 改用超时=0 强制在途请求立即失败。
      final accepted = await state.loadMoreSearch(
        's-a',
        timeout: Duration.zero,
      );

      expect(accepted, isFalse);
      final entry = outcome.entryOf('s-a')!;
      expect(entry.loadingMore, isFalse, reason: '必须复位加载态');
      expect(entry.hasMore, isTrue, reason: '失败不应判耗尽');
      // 在途登记已清理 → 重新翻页仍可发起。
      expect(await state.loadMoreSearch('s-a'), isTrue);
    });

    test('取消搜索后翻页不投递', () async {
      await importSites([siteOf('s-slow', slowApi(1.0))]);
      final future = state.searchAll(
        '样本',
        maxConcurrency: 1,
        timeout: const Duration(seconds: 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      state.cancelSearch();
      await future;
      expect(await state.loadMoreSearch('s-slow'), isFalse);
    });

    // 这组用例必须**启用真实数据库缓存**（bootstrap 后 `_database != null`）：
    // 搜索响应缓存的键只有 `(关键词, 站点)`，语义上只代表第 1 页。UI 复核时
    // 实测两个真缺陷都只有在有缓存时才会暴露（而普通 `test()`/widget 测试
    // 不 bootstrap、没有 DB，因此漏掉了一整个类别）：
    // ① 翻页请求命中第 1 页缓存 → 内容指纹重复 → 被误判「该站点已耗尽」；
    // ② 第 N 页结果被写进第 1 页的缓存键。
    test('有搜索缓存时翻页仍然追加下一页（回归）', () async {
      final cached = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${tempDir.path}/webhtv-pc',
            'data': '${tempDir.path}/webhtv-pc',
            'cache': '${tempDir.path}/webhtv-pc/cache',
            'state': '${tempDir.path}/webhtv-pc/logs',
          },
        ),
        log: LogService(),
        httpClient: http.Client(),
      );
      addTearDown(cached.dispose);
      await cached.bootstrap();
      expect(
        await cached.importConfig(jsonEncode({
          'name': '分页缓存测试',
          'sites': [
            siteOf('s-a', pagedApi()),
          ],
        })),
        isTrue,
      );

      final outcome = await cached.searchAll('分页');
      final first = outcome.entryOf('s-a')!;
      expect(first.itemCount, 1, reason: '第 1 页 1 条');
      expect(first.hasMore, isTrue);

      final accepted = await cached.loadMoreSearch('s-a');

      expect(accepted, isTrue, reason: '第 2 页必须被接受（不得被缓存伪装的重复页骗成耗尽）');
      final after = cached.activeSearch!.entryOf('s-a')!;
      expect(after.page, 2);
      expect(
        after.result!.list.map((v) => v.vodId),
        containsAll(['paged-1', 'paged-2']),
        reason: '第 2 页条目应追加',
      );

      // ② 第 2 页不得污染第 1 页的缓存键：重新搜同一关键词时，命中缓存
      // 应当仍然只有第 1 页的条目。
      final again = await cached.searchAll('分页');
      final replayed = again.entryOf('s-a')!;
      expect(replayed.fromCache, isTrue, reason: '应命中缓存');
      expect(
        replayed.result!.list.map((v) => v.vodId),
        ['paged-1'],
        reason: '缓存里必须是第 1 页内容，不能被分页写入污染',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // 搜索历史持久化与相似度（对齐上游安卓默影视）
  // ---------------------------------------------------------------------------
  group('搜索历史持久化与相似度（上游对齐）', () {
    test('历史经 UiPreferencesStore 落盘并在重建后恢复', () async {
      await importSites([siteOf('s-fast', okApi())]);

      final store = UiPreferencesStore(
        path: p.join(tempDir.path, 'settings.json'),
      );
      await store.load();
      state.attachUiPreferences(store);

      await state.searchAll('庆余年');
      await state.searchAll('斗罗大陆');
      await state.searchAll('庆余年');
      await state.removeSearchKeyword('斗罗大陆');

      expect(state.recentSearchKeywords, ['庆余年']);

      // 重建 store（模拟重启）：历史必须从磁盘恢复。
      final restored = UiPreferencesStore(
        path: p.join(tempDir.path, 'settings.json'),
      );
      await restored.load();
      expect(restored.searchKeywords, ['庆余年']);
    });

    test('历史上限 10 条：超出时最旧的被裁剪', () async {
      final store = UiPreferencesStore(
        path: p.join(tempDir.path, 'settings.json'),
      );
      await store.load();
      for (var i = 0; i < 12; i++) {
        await store.rememberSearchKeyword('词$i');
      }
      expect(store.searchKeywords.length, 10);
      expect(store.searchKeywords.first, '词11', reason: '最新在前');
      expect(store.searchKeywords, isNot(contains('词0')));
      expect(store.searchKeywords, isNot(contains('词1')));
    });

    test('相似度阈值持久化并在 AppState 生效', () async {
      final store = UiPreferencesStore(
        path: p.join(tempDir.path, 'settings.json'),
      );
      await store.load();
      state.attachUiPreferences(store);

      // 未设置时用默认 30（上游安卓同默认）。
      expect(state.searchSimilarity, 30);

      await state.setSearchSimilarity(60);
      expect(state.searchSimilarity, 60);

      final restored = UiPreferencesStore(
        path: p.join(tempDir.path, 'settings.json'),
      );
      await restored.load();
      expect(restored.searchSimilarity, 60);
    });

    test('结果条目携带站点分组（站点名方括号标记）', () async {
      await importSites([
        siteOf('s-a', okApi())..['name'] = '木偶[盘]',
        siteOf('s-b', okApi())..['name'] = '金牌影视[采]',
        siteOf('s-c', okApi()),
      ]);

      final outcome = await state.searchAll('样本', maxConcurrency: 3);

      final byKey = {
        for (final entry in outcome.results) entry.siteKey: entry,
      };
      expect(byKey['s-a']!.groups, ['盘']);
      expect(byKey['s-b']!.groups, ['采']);
      expect(byKey['s-c']!.groups, isEmpty);
    });
  });
}
