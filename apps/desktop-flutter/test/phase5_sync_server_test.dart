/// Phase 5 · PC 同步服务端（`docs/phase5/design/02` §4）。
///
/// 对应门禁：`docs/phase5/design/03` §3.3「`/device` 契约 / 端口探测与释放 /
/// `type` 与 `mode` 校验 / 落库与统计 / 403 与 413 / 幂等」。
///
/// 本套件走**真实回环 HTTP**（不用进程内 fake）：服务端的价值就是"能被安卓
/// 按一致路径访问到"，只测处理函数会漏掉路由、状态码、请求体读取这些真正的
/// 风险点。绑定地址用 `127.0.0.1`，避免测试机上弹防火墙或占用局域网端口。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/sync_server.dart';

/// 测试用端口区间（刻意避开 9978，避免影响本机正在运行的其它实例）。
const int testPortStart = 18500;
const int testPortEnd = 18510;

/// 造一条远端（安卓）历史 JSON。
Map<String, Object?> remoteHistory({
  String siteKey = 'csp_Media',
  String vodId = 'demo-001',
  String flag = '线路一',
  String episodeUrl = 'http://h/ep-1.m3u8',
  int position = 754000,
  int duration = 2700000,
  int createTime = 1791450000000,
}) => {
  'key': '$siteKey@@@$vodId@@@1',
  'vodName': '示例剧集',
  'vodPic': '',
  'vodFlag': flag,
  'vodRemarks': '第2集',
  'episodeUrl': episodeUrl,
  'position': position,
  'duration': duration,
  'createTime': createTime,
  'opening': -9223372036854775808,
  'ending': -9223372036854775808,
};

/// 测试宿主：把服务端回调接到真实内存数据库，并记录设置合并结果。
class TestHost {
  TestHost({this.enabled = true, this.authorizeAll = true});

  final AppDatabase db = AppDatabase.inMemory();
  final LogService log = LogService();
  final List<String> authorized = [];
  final List<SyncSettings> settingsMerged = [];
  final List<String> pullRequests = [];

  bool enabled;
  bool authorizeAll;

  final Map<String, Object?> backupFixture = {
    'keep': [],
    'config': [],
    'history': [],
    'prefers': {'tmdb_enabled': true, 'tmdb_config': '{"apiKey":"secret"}'},
  };

  SyncServerHost get host => SyncServerHost(
    deviceUuid: 'pc-fixture-uuid-0001',
    deviceName: 'WebHTV PC（测试）',
    isEnabled: () => enabled,
    isPeerAuthorized: (identity) => authorizeAll || authorized.contains(identity),
    onHistory: (parsed) async {
      final plan = buildHistoryMergePlan(
        parsed: parsed,
        localByMatchKey: db.historySyncIndex(),
        deletedAtByMatchKey: db.historyDeletionIndex(),
      );
      return db.applyHistoryMerge(plan);
    },
    onKeep: (parsed) async {
      final plan = buildFavoriteMergePlan(
        parsed: parsed,
        localUpdatedAtByKey: db.favoriteSyncIndex(),
      );
      return db.applyFavoriteMerge(plan);
    },
    onBackup: (backup, allowSensitive) async {
      final settings = SyncSettings.fromBackup(
        backup ?? backupFixture,
        allowSensitive: allowSensitive,
      );
      settingsMerged.add(settings);
      return settings;
    },
    onPullRequest: (deviceJson) async {
      pullRequests.add(deviceJson);
    },
  );

  void dispose() {
    db.dispose();
  }
}

/// 起一个只监听回环的服务端，测试结束自动停止。
Future<SyncServer> startServer(
  TestHost testHost, {
  int startPort = testPortStart,
  int endPort = testPortEnd,
}) async {
  final server = SyncServer(
    log: testHost.log,
    host: testHost.host,
    bindAddress: '127.0.0.1',
    lanIpOverride: '127.0.0.1',
    startPort: startPort,
    endPort: endPort,
  );
  await server.start();
  addTearDown(() async {
    await server.stop();
    testHost.dispose();
  });
  return server;
}

/// 表单 POST（对齐安卓 `FormBody` 的形态）。
Future<HttpClientResponse> postAction(
  SyncServer server, {
  required Map<String, String> query,
  Map<String, String> form = const {},
  List<int>? rawBody,
  String? contentType,
}) async {
  final client = HttpClient();
  try {
    final uri = Uri.parse(
      'http://127.0.0.1:${server.port}/action'
      '?${query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}',
    );
    final request = await client.postUrl(uri);
    request.headers.contentType =
        ContentType.parse(contentType ?? 'application/x-www-form-urlencoded');
    final body =
        rawBody ??
        utf8.encode(
          form.entries
              .map(
                (e) =>
                    '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
              )
              .join('&'),
        );
    request.add(body);
    return await request.close();
  } finally {
    // 响应读完后再关；这里只负责把 client 关联到请求生命周期。
    client.close();
  }
}

Future<String> readBody(HttpClientResponse response) async =>
    utf8.decode(await response.toList().then((chunks) => chunks.expand((c) => c).toList()));

Map<String, String> historyQuery({String mode = '1'}) => {
  'do': 'sync',
  'mode': mode,
  'type': 'history',
};

void main() {
  group('设备契约（design/02 §4.2）', () {
    test('1 · GET /device 返回完整 Device JSON 且 type=1', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final client = HttpClient();
      addTearDown(client.close);

      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/device'),
      );
      final response = await request.close();
      expect(response.statusCode, 200);
      final payload = jsonDecode(await readBody(response)) as Map<String, dynamic>;

      // 8 个字段齐全（design/03 §4.1 用例 6）。
      for (final key in const [
        'uuid',
        'name',
        'ip',
        'type',
        'serial',
        'eth',
        'wlan',
        'time',
      ]) {
        expect(payload.containsKey(key), isTrue, reason: '缺少字段 $key');
      }
      expect(payload['uuid'], 'pc-fixture-uuid-0001');
      expect(
        payload['type'],
        1,
        reason: 'type 必须是 1（Mobile/应用对端），写 2 会让安卓当投屏设备',
      );
      expect(payload['ip'], 'http://127.0.0.1:${server.port}');
    });

    test('未知路径返回 404 且不伪装成 200', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/vod/api'),
      );
      final response = await request.close();
      expect(response.statusCode, 404);
    });
  });

  group('端口探测与释放（design/02 §4.1）', () {
    test('2 · 起始端口被占用时落到下一个可用端口', () async {
      // 先占住 testPortStart。
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        testPortStart,
      );
      addTearDown(blocker.close);

      final testHost = TestHost();
      final server = await startServer(testHost);
      expect(server.port, testPortStart + 1);
      expect(server.isRunning, isTrue);
    });

    test('区间内端口全被占用时抛 syncPortUnavailable（不静默换随机端口）', () async {
      final blockers = <ServerSocket>[];
      addTearDown(() {
        for (final socket in blockers) {
          socket.close();
        }
      });
      for (var port = 18520; port <= 18521; port++) {
        blockers.add(
          await ServerSocket.bind(InternetAddress.loopbackIPv4, port),
        );
      }
      final testHost = TestHost();
      final server = SyncServer(
        log: testHost.log,
        host: testHost.host,
        bindAddress: '127.0.0.1',
        lanIpOverride: '127.0.0.1',
        startPort: 18520,
        endPort: 18521,
      );
      addTearDown(testHost.dispose);
      await expectLater(
        server.start(),
        throwsA(
          predicate(
            (Object error) =>
                error.toString().contains('syncPortUnavailable') ||
                error.toString().contains('端口全被占用'),
            '端口全占用时必须报 syncPortUnavailable',
          ),
        ),
      );
      expect(server.isRunning, isFalse);
    });

    test('3 · stop() 后端口立即可再次绑定', () async {
      final testHost = TestHost();
      final server = await startServer(testHost, startPort: 18522, endPort: 18522);
      expect(server.port, 18522);
      await server.stop();
      expect(server.isRunning, isFalse);

      // 端口必须真的释放（否则用户关掉同步后无法重新开启）。
      final probe = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        18522,
      );
      await probe.close();
    });
  });

  group('/action 校验（design/02 §3.3）', () {
    test('4 · 缺 type → 400', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: const {'do': 'sync', 'mode': '1'},
        form: const {'config': '{}', 'targets': '[]'},
      );
      expect(response.statusCode, 400);
      expect(await readBody(response), contains('type'));
    });

    test('5 · 未知 type → 400', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: const {'do': 'sync', 'mode': '1', 'type': 'nothing'},
      );
      expect(response.statusCode, 400);
      expect(await readBody(response), contains('history/keep/backup'));
    });

    test('非 sync 的 do → 400（不伪装成 OK）', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: const {'do': 'cast', 'mode': '1', 'type': 'history'},
      );
      expect(response.statusCode, 400);
      expect(await readBody(response), contains('do=sync'));
    });

    test('GET /action → 405', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse(
          'http://127.0.0.1:${server.port}/action?do=sync&mode=1&type=history',
        ),
      );
      final response = await request.close();
      expect(response.statusCode, 405);
    });

    test('mode 非法 → 400', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: const {'do': 'sync', 'mode': '9', 'type': 'history'},
        form: const {'config': '{}', 'targets': '[]'},
      );
      expect(response.statusCode, 400);
      expect(await readBody(response), contains('mode'));
    });

    test('6 · type=history 缺 config → 400 config 不能为空', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: historyQuery(),
        form: const {'targets': '[]'},
      );
      expect(response.statusCode, 400);
      expect(await readBody(response), 'config 不能为空');
    });

    test('7 · type=history config 非法 JSON → 400', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: historyQuery(),
        form: const {'config': '{oops', 'targets': '[]'},
      );
      expect(response.statusCode, 400);
      expect(await readBody(response), contains('JSON 对象'));
    });

    test('8 · type=history 缺 targets / 非数组 → 400', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final missing = await postAction(
        server,
        query: historyQuery(),
        form: const {'config': '{}'},
      );
      expect(missing.statusCode, 400);
      expect(await readBody(missing), 'targets 必须是 JSON 数组');

      final notArray = await postAction(
        server,
        query: historyQuery(),
        form: const {'config': '{}', 'targets': '{}'},
      );
      expect(notArray.statusCode, 400);
      expect(await readBody(notArray), 'targets 必须是 JSON 数组');
    });

    test('mode=2 缺 device → 400（对齐上游 Manage.syncStart）', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: historyQuery(mode: '2'),
        form: const {'config': '{}', 'targets': '[]'},
      );
      expect(response.statusCode, 400);
      expect(await readBody(response), contains('device'));
    });
  });

  group('落库与统计（design/02 §4.3）', () {
    test('9 · 空数组 → 200 OK 且 total=0', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: historyQuery(),
        form: const {'config': '{}', 'targets': '[]'},
      );
      expect(response.statusCode, 200);
      final body = await readBody(response);
      expect(body, startsWith('OK'));
      expect(body, contains('total=0'));
      expect(testHost.db.count('history'), 0);
    });

    test('10 · 正常推送 → 200 + 记录落库 + 统计正确', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final payload = [
        remoteHistory(),
        remoteHistory(vodId: 'demo-002', episodeUrl: 'http://h/ep-2.m3u8'),
      ];
      final response = await postAction(
        server,
        query: historyQuery(),
        form: {
          'config': '{"url":"http://127.0.0.1/android/config"}',
          'targets': jsonEncode(payload),
        },
      );
      expect(response.statusCode, 200);
      final body = await readBody(response);
      expect(body, contains('applied=2'));
      expect(body, contains('skipped=0'));
      expect(body, contains('failed=0'));
      expect(body, contains('total=2'));
      expect(body, isNot(contains('INCONSISTENT')));

      expect(testHost.db.count('history'), 2);
      final row = testHost.db.recentHistory().first;
      expect(row.positionMs, 754000);
      expect(
        row.updatedAt,
        1791450000000,
        reason: '必须落远端 createTime（毫秒直传）',
      );
    });

    test('mode=0 也落库（安卓 Action.post 投递用的就是 mode=0）', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: historyQuery(mode: '0'),
        form: {
          'config': '{"url":"http://127.0.0.1/c"}',
          'targets': jsonEncode([remoteHistory()]),
        },
      );
      expect(response.statusCode, 200);
      expect(await readBody(response), contains('applied=1'));
      expect(testHost.db.count('history'), 1);
      // 无 device 时不应触发回推。
      expect(testHost.pullRequests, isEmpty);
    });

    test('mode=2 + device → 触发回推，且不应用请求体载荷', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: historyQuery(mode: '2'),
        form: {
          'device': '{"uuid":"peer-uuid","ip":"http://127.0.0.1:9978"}',
          'config': '{"url":"http://127.0.0.1/c"}',
          'targets': jsonEncode([remoteHistory()]),
        },
      );
      expect(response.statusCode, 200);
      expect(testHost.pullRequests, hasLength(1));
      expect(await readBody(response), contains('mode=2'));
      expect(
        testHost.db.count('history'),
        0,
        reason: 'mode=2 只发送，不得写入请求体载荷',
      );
    });

    test('mode=0 + device → 既落库又回推（双向）', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: historyQuery(mode: '0'),
        form: {
          'device': '{"uuid":"peer-uuid","ip":"http://127.0.0.1:9978"}',
          'config': '{"url":"http://127.0.0.1/c"}',
          'targets': jsonEncode([remoteHistory()]),
        },
      );
      expect(response.statusCode, 200);
      expect(testHost.pullRequests, hasLength(1));
      expect(testHost.db.count('history'), 1);
    });

    test('14 · type=keep → 收藏落库', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: const {'do': 'sync', 'mode': '1', 'type': 'keep'},
        form: {
          'targets': jsonEncode([
            {
              'key': 'csp_Media@@@demo-001@@@1',
              'siteName': '我的追剧',
              'vodName': '示例剧集',
              'vodPic': '',
              'createTime': 1791450000000,
              'type': 0,
              'cid': 1,
            },
          ]),
          'configs': '[]',
        },
      );
      expect(response.statusCode, 200);
      expect(await readBody(response), contains('applied=1'));
      final favorites = testHost.db.listFavorites();
      expect(favorites, hasLength(1));
      expect(favorites.first.kind, 'vod');
      expect(favorites.first.targetId, 'demo-001');
      expect(favorites.first.title, '示例剧集');
      expect(favorites.first.subtitle, '我的追剧');
      expect(favorites.first.updatedAt, 1791450000000);
    });

    test('15 · type=backup → 设置按白名单合并，凭据默认排除', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: const {'do': 'sync', 'mode': '1', 'type': 'backup'},
        form: {
          'options': const SyncOptions().jsonText,
          'backup': jsonEncode(testHost.backupFixture),
        },
      );
      expect(response.statusCode, 200);
      expect(testHost.settingsMerged, hasLength(1));
      final merged = testHost.settingsMerged.first;
      expect(merged.values['tmdb_enabled'], isTrue);
      expect(
        merged.values.containsKey('tmdb_config'),
        isFalse,
        reason: 'settings=false 时含凭据项必须排除（P3）',
      );
      expect(merged.sensitiveIncluded, isFalse);
    });

    test('16 · 部分失败 → 明细可见且不回滚已应用记录', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: historyQuery(),
        form: {
          'config': '{"url":"http://127.0.0.1/c"}',
          'targets': jsonEncode([
            {'key': 'broken'},
            remoteHistory(),
          ]),
        },
      );
      expect(response.statusCode, 200);
      final body = await readBody(response);
      expect(body, contains('applied=1'));
      expect(body, contains('failed=1'));
      expect(body, contains('total=2'));
      expect(testHost.db.count('history'), 1);
    });

    test('17 · 同一批重复推送 → 第二次全部 skipped（幂等）', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      final targets = jsonEncode([
        remoteHistory(),
        remoteHistory(vodId: 'demo-002', episodeUrl: 'http://h/ep-2.m3u8'),
      ]);
      final first = await postAction(
        server,
        query: historyQuery(),
        form: {'config': '{"url":"http://127.0.0.1/c"}', 'targets': targets},
      );
      expect(await readBody(first), contains('applied=2'));

      final second = await postAction(
        server,
        query: historyQuery(),
        form: {'config': '{"url":"http://127.0.0.1/c"}', 'targets': targets},
      );
      final body = await readBody(second);
      expect(body, contains('applied=0'));
      expect(body, contains('skipped=2'));
      expect(testHost.db.count('history'), 2, reason: '幂等：不得新增行');
    });

    test('更旧的记录被拒（旧不覆盖新在服务端同样生效）', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      await postAction(
        server,
        query: historyQuery(),
        form: {
          'config': '{"url":"http://127.0.0.1/c"}',
          'targets': jsonEncode([
            remoteHistory(position: 2000000, createTime: 1791460000000),
          ]),
        },
      );
      final older = await postAction(
        server,
        query: historyQuery(),
        form: {
          'config': '{"url":"http://127.0.0.1/c"}',
          'targets': jsonEncode([
            remoteHistory(position: 1000, createTime: 1791400000000),
          ]),
        },
      );
      expect(await readBody(older), contains('skipped=1'));
      expect(testHost.db.recentHistory().first.positionMs, 2000000);
    });
  });

  group('授权与限额（design/02 §5 / §4.3）', () {
    test('11 · 同步未开启 → 403 同步未开启', () async {
      final testHost = TestHost()..enabled = false;
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: historyQuery(),
        form: const {'config': '{}', 'targets': '[]'},
      );
      expect(response.statusCode, 403);
      expect(await readBody(response), contains('同步未开启'));
    });

    test('12 · 对端未授权 → 403 对端未授权', () async {
      final testHost = TestHost()..authorizeAll = false;
      final server = await startServer(testHost);
      final response = await postAction(
        server,
        query: historyQuery(),
        form: const {'config': '{}', 'targets': '[]'},
      );
      expect(response.statusCode, 403);
      expect(await readBody(response), contains('未授权'));
      // 未授权时连库都不该碰。
      expect(testHost.db.count('history'), 0);
    });

    test('未授权时按对端 uuid 判定（device JSON 里的 uuid）', () async {
      final testHost = TestHost()
        ..authorizeAll = false
        ..authorized.add('known-uuid');
      final server = await startServer(testHost);

      final denied = await postAction(
        server,
        query: historyQuery(),
        form: {
          'device': '{"uuid":"stranger-uuid"}',
          'config': '{}',
          'targets': '[]',
        },
      );
      expect(denied.statusCode, 403);

      final allowed = await postAction(
        server,
        query: historyQuery(),
        form: {
          'device': '{"uuid":"known-uuid"}',
          'config': '{}',
          'targets': '[]',
        },
      );
      expect(allowed.statusCode, 200);
    });

    test('13 · 请求体超 8 MiB → 413', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      // 造一个超过 8 MiB 的 targets（真实场景：全量历史）。
      final huge = 'x' * (syncMaxPayloadBytes + 1024);
      final response = await postAction(
        server,
        query: historyQuery(),
        form: {'config': '{}', 'targets': huge},
      );
      expect(response.statusCode, 413);
      expect(await readBody(response), contains('8 MiB'));
      expect(testHost.db.count('history'), 0);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('multipart 带文件 → 415（明确披露不支持归档，不静默丢文件）', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      const boundary = 'X-BOUNDARY';
      final body = utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="backup"\r\n\r\n'
        '{}\r\n'
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="archive"; filename="a.zip"\r\n'
        'Content-Type: application/zip\r\n\r\n'
        'PK\u0003\u0004data\r\n'
        '--$boundary--\r\n',
      );
      final response = await postAction(
        server,
        query: const {'do': 'sync', 'mode': '1', 'type': 'backup'},
        rawBody: body,
        contentType: 'multipart/form-data; boundary=$boundary',
      );
      expect(response.statusCode, 415);
    });
  });

  group('脱敏（design/02 §7）', () {
    test('日志不含片名与 uuid 原文', () async {
      final testHost = TestHost();
      final server = await startServer(testHost);
      await postAction(
        server,
        query: historyQuery(),
        form: {
          'device': '{"uuid":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}',
          'config': '{"url":"http://127.0.0.1/secret-config"}',
          'targets': jsonEncode([remoteHistory()]),
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final text = testHost.log.export();
      expect(text, isNot(contains('示例剧集')));
      expect(text, isNot(contains('aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee')));
      expect(text, contains('aaaa****'));
      expect(text, isNot(contains('secret-config')));
      // 条数与统计可以出现（非敏感，便于排障）。
      expect(text, contains('applied=1'));
    });
  });
}
