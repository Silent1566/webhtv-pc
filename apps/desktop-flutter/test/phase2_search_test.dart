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

import 'dart:async';
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
  late AppState state;

  setUp(() async {
    server = await TestFixtureServer.start();
    tempDir = await Directory.systemTemp.createTemp('webhtv-search');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
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
      final probe = await _ConcurrencyProbe.start(holdMs: 400);
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
}

/// 并发探针：真正**并发**处理请求，并记录同时在途的峰值请求数。
///
/// 用它而不是 `TestFixtureServer` 的原因：后者串行处理请求，会把客户端的并发
/// 掩盖成串行，从而测不出 `searchAll` 的真实并发行为。
class _ConcurrencyProbe {
  _ConcurrencyProbe._(this._server, this._hold);

  final HttpServer _server;
  final Duration _hold;
  int _inFlight = 0;
  int _maxInFlight = 0;

  /// 同时在处理的最大请求数。
  int get maxInFlight => _maxInFlight;

  /// 站点 `api`（`type=1` 的基地址）。
  String get api => 'http://127.0.0.1:${_server.port}/api/type1/';

  static Future<_ConcurrencyProbe> start({int holdMs = 400}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final probe = _ConcurrencyProbe._(
      server,
      Duration(milliseconds: holdMs),
    );
    unawaited(probe._listen());
    return probe;
  }

  Future<void> _listen() async {
    await for (final request in _server) {
      // 必须 unawaited，否则又变回串行，无法观测并发。
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    _inFlight += 1;
    if (_inFlight > _maxInFlight) _maxInFlight = _inFlight;
    try {
      // hold 期间保持请求在途，给并发重叠留出窗口。
      await Future<void>.delayed(_hold);
      request.response.headers.contentType = ContentType(
        'application',
        'json',
        charset: 'utf-8',
      );
      request.response.write(
        jsonEncode({
          'list': [
            {'vod_id': 'probe-1', 'vod_name': '并发探针'},
          ],
        }),
      );
    } finally {
      _inFlight -= 1;
      try {
        await request.response.close();
      } catch (_) {
        // 客户端可能已断开。
      }
    }
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }
}
