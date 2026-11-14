/// Phase 7 · PC 拉取端点（`docs/phase7/design/01` §3.2.2、`design/04` S17–S20）。
///
/// 用**真实 HTTP**（起真 `SyncServer`，用真 `HttpClient` 当安卓），
/// 因此本文件**不得出现 `testWidgets`**（否则真实请求会被 mock 拦截）。
///
/// 覆盖：
/// - S17/S18 响应形态与别名（`nextSince`/`items`/`deleted`）；
/// - S19/S20 鉴权（token 不匹配 → 403；未配置 token 时只允许白名单）；
/// - 游标语义（非法 → 400；空游标 → 最近 N 条；`nextSince` 不回退）；
/// - `hasMore` 与 `limit` 夹取。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/realtime_sync.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_server.dart';

/// 构造一条本地历史（用于喂给拉取端点）。
SyncHistoryItem localHistory({
  String siteKey = 'CupFox',
  String vodId = '/video/104339.html',
  String episodeId = 'aaa',
  int positionMs = 1000,
  int durationMs = 10000,
  int updatedAt = 100,
}) => SyncHistoryItem(
  siteKey: siteKey,
  vodId: vodId,
  vodName: '扫毒风暴',
  flag: '线路1',
  episodeName: '第01集',
  episodeId: episodeId,
  positionMs: positionMs,
  durationMs: durationMs,
  updatedAt: updatedAt,
);

/// 起一个真实 SyncServer，返回 (server, 端口)。
Future<SyncServer> startServer({
  required List<SyncHistoryItem> history,
  List<({String historyKey, int deletedAt})> deletions = const [],
  bool enabled = true,
  bool peerAuthorized = true,
  String? pullToken,
}) async {
  final server = SyncServer(
    log: LogService(),
    host: SyncServerHost(
      deviceUuid: 'pc-uuid-test',
      deviceName: 'WebHTV PC',
      isEnabled: () => enabled,
      isPeerAuthorized: (_) => peerAuthorized,
      onHistory: (_, {String sourceKey = ''}) async =>
          const SyncMergeStats.empty(),
      onKeep: (_) async => const SyncMergeStats.empty(),
      onBackup: (_, _) async => const SyncSettings.empty(),
      realtimePull: ({required int since, required int limit}) =>
          buildSyncPullBatch(
            history: history,
            deletions: deletions,
            since: since,
            limit: limit,
          ),
      pullToken: pullToken,
    ),
    startPort: 0,
    endPort: 0,
    bindAddress: '127.0.0.1',
  );
  await server.start();
  return server;
}

/// 发一个 GET，返回 (状态码, 响应体, content-type)。
Future<({int status, String body, String? contentType})> get(
  int port,
  String path, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return (
      status: response.statusCode,
      body: body,
      contentType: response.headers.contentType?.mimeType,
    );
  } finally {
    client.close();
  }
}

void main() {
  group('S17 · 响应形态（design/01 §3.2.2）', () {
    late SyncServer server;

    tearDown(() async => server.stop());

    test('S17 · 响应含 nextSince/items/deleted 三者', () async {
      server = await startServer(
        history: [localHistory(updatedAt: 500)],
        deletions: [(historyKey: 'CupFox@@@/v/9@@@0', deletedAt: 600)],
      );
      final response = await get(server.port, '/api/playback/sync?since=0');

      expect(response.status, 200);
      expect(response.contentType, 'application/json');
      final decoded = jsonDecode(response.body) as Map<String, Object?>;
      expect(decoded.containsKey('nextSince'), isTrue);
      expect(decoded['items'], isA<List<Object?>>());
      expect(decoded['deleted'], isA<List<Object?>>());
      expect(decoded['hasMore'], isA<bool>());
    });

    test('S17 · nextSince = 本批最大游标', () async {
      server = await startServer(
        history: [
          localHistory(vodId: '/a', updatedAt: 100),
          localHistory(vodId: '/b', updatedAt: 900),
          localHistory(vodId: '/c', updatedAt: 500),
        ],
      );
      final decoded =
          jsonDecode((await get(server.port, '/api/playback/sync?since=0')).body)
              as Map<String, Object?>;
      expect(decoded['nextSince'], 900);
    });

    test('S17 · 单条记录含安卓 PlaybackProgressInput 必需字段', () async {
      server = await startServer(history: [localHistory(updatedAt: 500)]);
      final decoded =
          jsonDecode((await get(server.port, '/api/playback/sync?since=0')).body)
              as Map<String, Object?>;
      final item = (decoded['items']! as List).first as Map<String, Object?>;

      // 安卓的 PlaybackProgressWriter 用 updatedAt 做 setCreateTime 与冲突裁决。
      expect(item['updatedAt'], 500);
      expect(item['historyKey'], 'CupFox@@@/video/104339.html@@@0');
      expect(item['siteKey'], 'CupFox');
      expect(item['vodId'], '/video/104339.html');
      expect(item['positionMs'], 1000);
      expect(item['durationMs'], 10000);
      expect(item['episodeId'], 'aaa');
      // PC 一律按自己公式重算 completed（`design/03` §4.2）。
      expect(item['completed'], isFalse);
    });

    test('S17 · 删除条目形态为 {historyKey, deletedAt}', () async {
      server = await startServer(
        history: const [],
        deletions: [(historyKey: 'CupFox@@@/v/9@@@0', deletedAt: 777)],
      );
      final decoded =
          jsonDecode((await get(server.port, '/api/playback/sync?since=0')).body)
              as Map<String, Object?>;
      final deletion = (decoded['deleted']! as List).first as Map<String, Object?>;
      expect(deletion['historyKey'], 'CupFox@@@/v/9@@@0');
      expect(deletion['deletedAt'], 777);
    });

    test('S18 · 别名路径 /playback/sync 同样可用', () async {
      server = await startServer(history: [localHistory()]);
      expect((await get(server.port, '/playback/sync?since=0')).status, 200);
    });

    test('非 GET → 405', () async {
      server = await startServer(history: const []);
      final client = HttpClient();
      try {
        final request = await client.postUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/playback/sync'),
        );
        final response = await request.close();
        expect(response.statusCode, 405);
        await response.drain<void>();
      } finally {
        client.close();
      }
    });
  });

  group('S19/S20 · 鉴权（design/01 §3.2.2）', () {
    late SyncServer server;

    tearDown(() async => server.stop());

    test('S19 · 配置了 token 时，不匹配 → 403', () async {
      server = await startServer(history: [localHistory()], pullToken: 'secret');
      final response = await get(
        server.port,
        '/api/playback/sync?since=0',
        headers: {'X-WebHTV-Token': 'wrong'},
      );
      expect(response.status, 403);
      expect(response.body, contains('token'));
    });

    test('S19 · token 匹配 → 200', () async {
      server = await startServer(history: [localHistory()], pullToken: 'secret');
      final response = await get(
        server.port,
        '/api/playback/sync?since=0',
        headers: {'X-WebHTV-Token': 'secret'},
      );
      expect(response.status, 200);
    });

    test('S20 · 未配置 token 时只允许白名单对端', () async {
      server = await startServer(
        history: [localHistory()],
        peerAuthorized: false,
      );
      final response = await get(server.port, '/api/playback/sync?since=0');
      expect(response.status, 403);
      expect(response.body, contains('未授权'));
    });

    test('S20 · 未配置 token 且对端已授权 → 200', () async {
      server = await startServer(history: [localHistory()], peerAuthorized: true);
      expect((await get(server.port, '/api/playback/sync?since=0')).status, 200);
    });

    test('实时推送未开启 → 403（P1：端点只在显式开启后返回数据）', () async {
      server = await startServer(history: [localHistory()], enabled: false);
      final response = await get(server.port, '/api/playback/sync?since=0');
      expect(response.status, 403);
      expect(response.body, contains('未开启'));
    });

    test('token 优先于白名单：token 对了就不再看白名单', () async {
      server = await startServer(
        history: [localHistory()],
        pullToken: 'secret',
        peerAuthorized: false,
      );
      final response = await get(
        server.port,
        '/api/playback/sync?since=0',
        headers: {'X-WebHTV-Token': 'secret'},
      );
      expect(response.status, 200);
    });
  });

  group('游标语义（design/01 §3.2.2）', () {
    late SyncServer server;

    tearDown(() async => server.stop());

    test('非法游标 → 400（不得回落 0）', () async {
      server = await startServer(history: [localHistory()]);
      for (final bad in ['abc', '-1', '1.5', 'NaN']) {
        final response = await get(server.port, '/api/playback/sync?since=$bad');
        expect(response.status, 400, reason: 'since=$bad 应被拒绝');
        expect(response.body, contains('Invalid'));
      }
    });

    test('空游标 → 200（首次同步）', () async {
      server = await startServer(history: [localHistory()]);
      expect((await get(server.port, '/api/playback/sync')).status, 200);
      expect((await get(server.port, '/api/playback/sync?since=')).status, 200);
    });

    test('since 有值时只返回更新的记录', () async {
      server = await startServer(
        history: [
          localHistory(vodId: '/old', updatedAt: 100),
          localHistory(vodId: '/new', updatedAt: 900),
        ],
      );
      final decoded =
          jsonDecode((await get(server.port, '/api/playback/sync?since=500')).body)
              as Map<String, Object?>;
      final items = decoded['items']! as List;
      expect(items, hasLength(1));
      expect((items.first as Map)['vodId'], '/new');
    });

    test('nextSince 在空批时保持 since（不回退）', () async {
      server = await startServer(history: [localHistory(updatedAt: 100)]);
      final decoded =
          jsonDecode((await get(server.port, '/api/playback/sync?since=5000')).body)
              as Map<String, Object?>;
      expect(decoded['items'], isEmpty);
      expect(decoded['nextSince'], 5000, reason: '回退会让安卓重复拉取');
    });

    test('header 形态的游标与 limit 也被接受', () async {
      server = await startServer(
        history: [
          localHistory(vodId: '/a', updatedAt: 100),
          localHistory(vodId: '/b', updatedAt: 200),
        ],
      );
      final decoded = jsonDecode(
        (await get(
          server.port,
          '/api/playback/sync',
          headers: {'X-WebHTV-Since': '150', 'X-WebHTV-Limit': '10'},
        )).body,
      ) as Map<String, Object?>;
      expect((decoded['items']! as List), hasLength(1));
    });

    test('header 优先于 query（安卓客户端实际发的是 header）', () async {
      server = await startServer(
        history: [
          localHistory(vodId: '/a', updatedAt: 100),
          localHistory(vodId: '/b', updatedAt: 200),
        ],
      );
      final decoded = jsonDecode(
        (await get(
          server.port,
          '/api/playback/sync?since=50',
          headers: {'X-WebHTV-Since': '250'},
        )).body,
      ) as Map<String, Object?>;
      // header 的 250 生效 → 两条都被过滤掉。
      // 为什么 header 优先：安卓 `PlaybackRemoteSyncer` 发的是 header，
      // query 只是给手动调试/第三方服务端的便利形式；
      // 两者都给时以客户端真实协议为准。
      expect(decoded['items'], isEmpty);
    });

    test('query 在无 header 时生效（调试/第三方服务端路径）', () async {
      server = await startServer(
        history: [
          localHistory(vodId: '/a', updatedAt: 100),
          localHistory(vodId: '/b', updatedAt: 200),
        ],
      );
      final decoded =
          jsonDecode((await get(server.port, '/api/playback/sync?since=150')).body)
              as Map<String, Object?>;
      expect((decoded['items']! as List), hasLength(1));
    });
  });

  group('limit 与 hasMore（design/01 §3.2.2）', () {
    late SyncServer server;

    tearDown(() async => server.stop());

    test('limit 限制返回条数并置 hasMore', () async {
      server = await startServer(
        history: [
          for (var i = 0; i < 10; i++)
            localHistory(vodId: '/v$i', updatedAt: 100 + i),
        ],
      );
      final decoded =
          jsonDecode((await get(server.port, '/api/playback/sync?since=0&limit=3')).body)
              as Map<String, Object?>;
      expect((decoded['items']! as List), hasLength(3));
      expect(decoded['hasMore'], isTrue);
    });

    test('条数不足时不置 hasMore', () async {
      server = await startServer(history: [localHistory()]);
      final decoded =
          jsonDecode((await get(server.port, '/api/playback/sync?since=0&limit=50')).body)
              as Map<String, Object?>;
      expect(decoded['hasMore'], isFalse);
    });

    test('limit 超过上限被夹到 500', () {
      expect(parseSyncLimit('999999'), realtimeSyncMaxLimit);
      expect(parseSyncLimit('500'), 500);
    });

    test('limit 非法值回落默认 100', () {
      expect(parseSyncLimit('abc'), realtimeSyncDefaultLimit);
      expect(parseSyncLimit('0'), realtimeSyncDefaultLimit);
      expect(parseSyncLimit('-5'), realtimeSyncDefaultLimit);
      expect(parseSyncLimit(null), realtimeSyncDefaultLimit);
    });

    test('limit 与删除共享配额', () async {
      server = await startServer(
        history: [
          for (var i = 0; i < 5; i++)
            localHistory(vodId: '/v$i', updatedAt: 100 + i),
        ],
        deletions: [
          for (var i = 0; i < 5; i++)
            (historyKey: 'CupFox@@@/d$i@@@0', deletedAt: 200 + i),
        ],
      );
      final decoded =
          jsonDecode((await get(server.port, '/api/playback/sync?since=0&limit=4')).body)
              as Map<String, Object?>;
      // `deleted` 在空时被省略（不塞空数组噪音），因此用 `?? const []`。
      final total = (decoded['items']! as List).length +
          ((decoded['deleted'] as List?) ?? const []).length;
      expect(total, 4, reason: 'upsert 与删除共享 limit 配额');
      expect(decoded['hasMore'], isTrue);
    });

    test('删除优先于 upsert 抢占配额（墓碑更紧急）', () async {
      // 当前实现先填 upsert 再填删除（与 Go 参考实现一致）。
      // 这个用例锁定顺序，避免以后默默改成“删除优先”而无人知晓。
      server = await startServer(
        history: [
          for (var i = 0; i < 3; i++)
            localHistory(vodId: '/v$i', updatedAt: 100 + i),
        ],
        deletions: [(historyKey: 'k', deletedAt: 300)],
      );
      final decoded =
          jsonDecode((await get(server.port, '/api/playback/sync?since=0&limit=2')).body)
              as Map<String, Object?>;
      expect((decoded['items']! as List), hasLength(2));
      expect(decoded.containsKey('deleted'), isFalse);
    });
  });

  group('游标解析（纯逻辑）', () {
    test('空/缺省 → 0', () {
      expect(parseSyncCursor(null), 0);
      expect(parseSyncCursor(''), 0);
      expect(parseSyncCursor('   '), 0);
    });

    test('合法整数 → 原值', () {
      expect(parseSyncCursor('0'), 0);
      expect(parseSyncCursor('12345'), 12345);
      expect(parseSyncCursor(' 42 '), 42);
    });

    test('非法值 → null（调用方必须回 400）', () {
      expect(parseSyncCursor('abc'), isNull);
      expect(parseSyncCursor('-1'), isNull);
      expect(parseSyncCursor('1.5'), isNull);
      expect(parseSyncCursor('999999999999999999999'), isNull);
    });
  });

  group('批次构造（纯逻辑）', () {
    test('空游标也只给最近 N 条（P2：不做全量）', () {
      final batch = buildSyncPullBatch(
        history: [
          for (var i = 0; i < 10; i++)
            localHistory(vodId: '/v$i', updatedAt: 100 + i),
        ],
        deletions: const [],
        since: 0,
        limit: 3,
      );
      expect(batch.items, hasLength(3));
      expect(batch.hasMore, isTrue);
    });

    test('按 updatedAt 升序返回（便于安卓顺序应用）', () {
      final batch = buildSyncPullBatch(
        history: [
          localHistory(vodId: '/c', updatedAt: 300),
          localHistory(vodId: '/a', updatedAt: 100),
          localHistory(vodId: '/b', updatedAt: 200),
        ],
        deletions: const [],
        since: 0,
        limit: 10,
      );
      expect(
        batch.items.map((i) => i['vodId']).toList(),
        ['/a', '/b', '/c'],
      );
    });

    test('删除也按 deletedAt 升序', () {
      final batch = buildSyncPullBatch(
        history: const [],
        deletions: [
          (historyKey: 'k2', deletedAt: 300),
          (historyKey: 'k1', deletedAt: 100),
        ],
        since: 0,
        limit: 10,
      );
      expect(batch.deletions.map((d) => d['historyKey']).toList(), ['k1', 'k2']);
    });

    test('toJson 省略空的 deleted（不塞空数组噪音）', () {
      final batch = buildSyncPullBatch(
        history: [localHistory()],
        deletions: const [],
        since: 0,
        limit: 10,
      );
      expect(batch.toJson().containsKey('deleted'), isFalse);
    });

    test('nextSince 取 items 与 deletions 的最大值', () {
      final batch = buildSyncPullBatch(
        history: [localHistory(updatedAt: 500)],
        deletions: [(historyKey: 'k', deletedAt: 900)],
        since: 0,
        limit: 10,
      );
      expect(batch.nextSince, 900);
    });

    test('全空批次时 nextSince 保持 since', () {
      final batch = buildSyncPullBatch(
        history: const [],
        deletions: const [],
        since: 123,
        limit: 10,
      );
      expect(batch.nextSince, 123);
      expect(batch.total, 0);
      expect(batch.hasMore, isFalse);
    });

    test('describe 含关键字段（证据落盘用）', () {
      final batch = buildSyncPullBatch(
        history: [localHistory(updatedAt: 500)],
        deletions: [(historyKey: 'k', deletedAt: 600)],
        since: 0,
        limit: 10,
      );
      final text = batch.describe();
      expect(text, contains('items=1'));
      expect(text, contains('deleted=1'));
      expect(text, contains('nextSince=600'));
    });
  });

  group('鉴权校验（纯逻辑）', () {
    test('未开启推送 → 拒绝', () {
      final check = validateSyncPullAuth(
        pushEnabled: false,
        configuredToken: null,
        providedToken: null,
        peerAuthorized: true,
      );
      expect(check.allowed, isFalse);
      expect(check.status, 403);
    });

    test('配置 token 时不匹配 → 拒绝', () {
      final check = validateSyncPullAuth(
        pushEnabled: true,
        configuredToken: 'secret',
        providedToken: 'other',
        peerAuthorized: true,
      );
      expect(check.allowed, isFalse);
      expect(check.message, contains('token'));
    });

    test('配置 token 时匹配 → 允许（不看白名单）', () {
      final check = validateSyncPullAuth(
        pushEnabled: true,
        configuredToken: 'secret',
        providedToken: 'secret',
        peerAuthorized: false,
      );
      expect(check.allowed, isTrue);
    });

    test('未配置 token 时看白名单', () {
      expect(
        validateSyncPullAuth(
          pushEnabled: true,
          configuredToken: null,
          providedToken: null,
          peerAuthorized: true,
        ).allowed,
        isTrue,
      );
      expect(
        validateSyncPullAuth(
          pushEnabled: true,
          configuredToken: '',
          providedToken: null,
          peerAuthorized: false,
        ).allowed,
        isFalse,
      );
    });

    test('空字符串 token 视为未配置', () {
      final check = validateSyncPullAuth(
        pushEnabled: true,
        configuredToken: '   ',
        providedToken: null,
        peerAuthorized: true,
      );
      expect(check.allowed, isTrue, reason: '空白 token 不应被当成已配置');
    });
  });

  group('historyKey 形态（路径 B 的身份字段）', () {
    test('historyKey 用 @@@ 分隔且 cid 写 0', () {
      final item = localHistory(siteKey: 'CupFox', vodId: '/video/104339.html');
      expect(item.historyKey, 'CupFox@@@/video/104339.html@@@0');
    });

    test('historyKey 与 matchKey 语义不同（前者带 cid，后者带 flag/episodeId）', () {
      final item = localHistory();
      expect(item.historyKey, contains('@@@'));
      expect(item.matchKey, isNot(contains('@@@')));
      expect(item.matchKey, contains('线路1'));
    });

    test('toAndroidJson 的 key 与 historyKey 一致（单一来源）', () {
      final item = localHistory();
      expect(item.toAndroidJson()['key'], item.historyKey);
    });
  });
}
