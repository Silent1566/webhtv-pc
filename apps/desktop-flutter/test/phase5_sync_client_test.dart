/// Phase 5 · 同步客户端（`docs/phase5/design/02` §3.2 / §6）。
///
/// 对应门禁：`docs/phase5/design/03` §3.4「推送路径与 `mode` / 表单字段 /
/// `cid=0` / 默认不发 `settings` / 403、连接被拒、超时、5xx 的分类 / `Host` 头」。
///
/// L2 用**请求捕获**断言请求形态，不只断言最终结果（`design/03` §1）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_client.dart';

/// 捕获请求形态的假 HTTP 客户端。
class FakeClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  final List<String> bodies = [];

  /// 非空时所有请求抛该异常（模拟连接被拒/超时）。
  Object? failure;

  int status = 200;
  String body = 'OK applied=1 skipped=0 failed=0 total=1';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    bodies.add(
      request is http.Request ? request.body : await _drain(request),
    );
    final error = failure;
    if (error != null) throw error;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      status,
    );
  }

  Future<String> _drain(http.BaseRequest request) async {
    final builder = StringBuffer();
    await for (final chunk in request.finalize()) {
      builder.write(utf8.decode(chunk, allowMalformed: true));
    }
    return builder.toString();
  }
}

Uri lastUri(FakeClient client) => client.requests.last.url;

Map<String, String> lastForm(FakeClient client) =>
    Uri.splitQueryString(client.bodies.last);

SyncHistoryItem localItem({
  String siteKey = 'csp_Media',
  String vodId = 'demo-001',
  String flag = '线路一',
  String episodeId = 'http://h/ep-1.m3u8',
  int positionMs = 754000,
  int durationMs = 2700000,
  int updatedAt = 1791450000000,
}) => SyncHistoryItem.fromLocal(
  siteKey: siteKey,
  vodId: vodId,
  vodName: '示例剧集',
  flag: flag,
  episodeName: '第2集',
  episodeId: episodeId,
  positionMs: positionMs,
  durationMs: durationMs,
  updatedAt: updatedAt,
);

const String configJson =
    '{"id":1,"type":0,"name":"示例配置","url":"http://h/sub/demo"}';

const String deviceBase = 'http://192.168.50.9:9978';

/// 捕获同步调用抛出的 [AppError]。
Future<AppError> throwsAppError(Future<void> Function() body, AppErrorKind kind) async {
  try {
    await body();
  } on AppError catch (error) {
    expect(
      error.kind,
      kind,
      reason: '期望 $kind，实际 ${error.kind}（${error.message}）',
    );
    return error;
  }
  fail('期望抛出 AppError($kind)，但没有抛出任何错误');
}

void main() {
  group('推送历史（design/02 §3.2）', () {
    test('1 · 打到 /action?do=sync&mode=1&type=history', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      final result = await sync.pushHistory(
        deviceBase: deviceBase,
        configJson: configJson,
        items: [localItem()],
      );

      final request = client.requests.last;
      expect(request.method, 'POST');
      final uri = lastUri(client);
      expect(uri.path, '/action');
      expect(uri.queryParameters['do'], 'sync');
      expect(
        uri.queryParameters['mode'],
        '1',
        reason: 'mode 从被请求方视角：PC 推送 = 1（你接收我发的）',
      );
      expect(uri.queryParameters['type'], 'history');
      expect(result.statusCode, 200);
      expect(result.itemCount, 1);
      expect(result.type, 'history');
      // 服务端明细被解析出来。
      expect(result.stats?.applied, 1);
      expect(result.stats?.total, 1);
      expect(result.isInconsistent, isFalse);
    });

    test('2 · 表单含 config 与 targets，且都是合法 JSON', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      await sync.pushHistory(
        deviceBase: deviceBase,
        configJson: configJson,
        items: [localItem(), localItem(vodId: 'demo-002', episodeId: 'http://h/ep-2.m3u8')],
      );

      final form = lastForm(client);
      expect(form.containsKey('config'), isTrue);
      expect(form.containsKey('targets'), isTrue);
      final config = jsonDecode(form['config']!);
      expect(config, isA<Map<String, Object?>>());
      final targets = jsonDecode(form['targets']!) as List<Object?>;
      expect(targets, hasLength(2));
      for (final item in targets) {
        expect(item, isA<Map<String, Object?>>());
      }
      // 请求头必须是表单类型（安卓用 `FormBody`，两边保持同一形态）。
      expect(
        client.requests.last.headers['Content-Type'],
        contains('application/x-www-form-urlencoded'),
      );
    });

    test('3 · 每条记录的 key 以 @@@0 结尾（cid 交给安卓）', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      await sync.pushHistory(
        deviceBase: deviceBase,
        configJson: configJson,
        items: [
          localItem(),
          localItem(vodId: 'demo-002', episodeId: 'http://h/ep-2.m3u8'),
        ],
      );
      final targets =
          jsonDecode(lastForm(client)['targets']!) as List<Object?>;
      for (final item in targets) {
        final key = (item as Map<String, Object?>)['key'] as String;
        expect(key.endsWith('@@@0'), isTrue, reason: key);
      }
      // 毫秒直传 + 省略 opening/ending（`design/02` §3.5）。
      final first = targets.first as Map<String, Object?>;
      expect(first['position'], 754000);
      expect(first.keys, isNot(contains('opening')));
      expect(first.keys, isNot(contains('ending')));
    });

    test('4 · 默认请求不含 settings=true（含凭据项不发）', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      await sync.pushHistory(
        deviceBase: deviceBase,
        configJson: configJson,
        items: [localItem()],
      );
      final options =
          jsonDecode(lastForm(client)['options']!) as Map<String, Object?>;
      expect(options['settings'], isFalse);
      expect(options['history'], isTrue);
      expect(options['keep'], isTrue);
      expect(options['config'], isFalse);
      expect(client.bodies.last.contains('settings=true'), isFalse);
    });

    test('9 · Host 头与可达地址一致（缺端口补 9978）', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      await sync.pushHistory(
        deviceBase: '192.168.50.9',
        configJson: configJson,
        items: [localItem()],
      );
      final request = client.requests.last;
      expect(request.url.port, 9978);
      expect(request.headers['Host'], '192.168.50.9:9978');
    });

    test('config 缺 url 时本地就拒绝（防安卓静默无操作）', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      final error = await throwsAppError(
        () => sync.pushHistory(
          deviceBase: deviceBase,
          configJson: '{"name":"没有 url"}',
          items: [localItem()],
        ),
        AppErrorKind.syncPayloadInvalid,
      );
      expect(error.message, contains('静默忽略'));
      expect(
        client.requests,
        isEmpty,
        reason: '校验失败不得发出请求：否则用户看到"成功"但安卓什么都没写',
      );
    });
  });

  group('错误分类（design/02 §6）', () {
    test('5 · 403 → syncLocalWriteRejected 且文案含安卓侧开关指引', () async {
      final client = FakeClient()
        ..status = 403
        ..body = '本机 API 修改未开启';
      final sync = SyncClient(log: LogService(), client: client);
      final error = await throwsAppError(
        () => sync.pushHistory(
          deviceBase: deviceBase,
          configJson: configJson,
          items: [localItem()],
        ),
        AppErrorKind.syncLocalWriteRejected,
      );
      expect(error.message, contains('观影记录同步'));
      expect(error.message, contains('本机 API 修改'));
      expect(error.statusCode, 403);
    });

    test('6 · 连接被拒 → syncPeerUnreachable（可重试）', () async {
      final client = FakeClient()
        ..failure = const SocketException('Connection refused');
      final sync = SyncClient(log: LogService(), client: client);
      final error = await throwsAppError(
        () => sync.pushHistory(
          deviceBase: deviceBase,
          configJson: configJson,
          items: [localItem()],
        ),
        AppErrorKind.syncPeerUnreachable,
      );
      expect(error.retryable, isTrue);
      expect(error.detail, '192.168.50.9:9978');
    });

    test('7 · 超时 → syncPeerUnreachable', () async {
      final client = FakeClient()..failure = TimeoutException('slow');
      final sync = SyncClient(
        log: LogService(),
        client: client,
        timeout: const Duration(milliseconds: 50),
      );
      final error = await throwsAppError(
        () => sync.pushHistory(
          deviceBase: deviceBase,
          configJson: configJson,
          items: [localItem()],
        ),
        AppErrorKind.syncPeerUnreachable,
      );
      expect(error.message, contains('超时'));
      expect(error.retryable, isTrue);
    });

    test('8 · 5xx 不静默：抛出并带状态码与正文', () async {
      final client = FakeClient()
        ..status = 500
        ..body = 'targets 必须是 JSON 数组';
      final sync = SyncClient(log: LogService(), client: client);
      final error = await throwsAppError(
        () => sync.pushHistory(
          deviceBase: deviceBase,
          configJson: configJson,
          items: [localItem()],
        ),
        AppErrorKind.syncPeerError,
      );
      expect(error.statusCode, 500);
      expect(error.message, contains('500'));
      expect(error.message, contains('targets 必须是 JSON 数组'));
      expect(error.retryable, isTrue);
    });

    test('4xx（非 403）同样归入 syncPeerError，不折叠为"连不上"', () async {
      final client = FakeClient()
        ..status = 400
        ..body = 'config 不能为空';
      final sync = SyncClient(log: LogService(), client: client);
      final error = await throwsAppError(
        () => sync.pushHistory(
          deviceBase: deviceBase,
          configJson: configJson,
          items: [localItem()],
        ),
        AppErrorKind.syncPeerError,
      );
      expect(error.statusCode, 400);
      expect(error.retryable, isFalse);
      expect(error.message, contains('config 不能为空'));
    });

    test('对端返回 200 但明细不闭合时被标记（不折叠成成功）', () async {
      final client = FakeClient()..body = 'OK applied=1 skipped=0 failed=0 total=9 INCONSISTENT';
      final sync = SyncClient(log: LogService(), client: client);
      final result = await sync.pushHistory(
        deviceBase: deviceBase,
        configJson: configJson,
        items: [localItem()],
      );
      expect(result.isInconsistent, isTrue);
      expect(result.stats?.isConsistent, isFalse);
    });

    test('对端没有明细时 stats 为 null（不伪造 0）', () async {
      final client = FakeClient()..body = 'OK';
      final sync = SyncClient(log: LogService(), client: client);
      final result = await sync.pushHistory(
        deviceBase: deviceBase,
        configJson: configJson,
        items: [localItem()],
      );
      expect(result.stats, isNull);
    });
  });

  group('收藏 / 设置 / 拉取（design/02 §3.2 / §3.6）', () {
    test('pushKeep 用 type=keep 且 key 以 @@@0 结尾', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      await sync.pushKeep(
        deviceBase: deviceBase,
        items: const [
          SyncFavoriteItem(
            kind: 'vod',
            siteKey: 'csp_Media',
            targetId: 'demo-001',
            title: '示例剧集',
            subtitle: '我的追剧',
            updatedAt: 1791450000000,
          ),
        ],
      );
      expect(lastUri(client).queryParameters['type'], 'keep');
      expect(lastUri(client).queryParameters['mode'], '1');
      final targets = jsonDecode(lastForm(client)['targets']!) as List<Object?>;
      final key = (targets.first as Map<String, Object?>)['key'] as String;
      expect(key, 'csp_Media@@@demo-001@@@0');
      expect(lastForm(client).containsKey('configs'), isTrue);
    });

    test('pushBackup 默认不带 allowSensitive（凭据不同步）', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      await sync.pushBackup(
        deviceBase: deviceBase,
        backup: const {
          'prefers': {'tmdb_enabled': true},
        },
      );
      expect(lastUri(client).queryParameters['type'], 'backup');
      expect(lastForm(client).containsKey('allowSensitive'), isFalse);
      final options =
          jsonDecode(lastForm(client)['options']!) as Map<String, Object?>;
      expect(options['settings'], isFalse);
    });

    test('pushBackup 在显式开启 settings 时才带 allowSensitive', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      await sync.pushBackup(
        deviceBase: deviceBase,
        backup: const {
          'prefers': {'tmdb_config': '{"apiKey":"k"}'},
        },
        options: SyncOptions.pcDefault.copyWith(settings: true),
      );
      expect(lastForm(client)['allowSensitive'], 'true');
    });

    test('requestPull 用 mode=2 + device（mode 语义锁定）', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      await sync.requestPull(
        deviceBase: deviceBase,
        type: 'history',
        pcDeviceJson: '{"uuid":"pc-uuid","ip":"http://192.168.50.20:9978"}',
      );
      final query = lastUri(client).queryParameters;
      expect(query['mode'], '2', reason: '拉取 = 2（对方只发送）');
      expect(query['type'], 'history');
      final form = lastForm(client);
      expect(form['device'], contains('pc-uuid'));
      // mode=2 时对方不会应用载荷，因此不该伪造空 targets 让对端误解。
      expect(form.keys, isNot(contains('targets')));
    });

    test('非法 mode/type 在构造路径时就抛（不发畸形请求）', () async {
      final client = FakeClient();
      final sync = SyncClient(log: LogService(), client: client);
      expect(
        () => buildSyncActionPath(mode: '9', type: 'history'),
        throwsArgumentError,
      );
      expect(
        () => buildSyncActionPath(mode: '1', type: 'unknown'),
        throwsArgumentError,
      );
      expect(client.requests, isEmpty);
      expect(sync.timeout, const Duration(seconds: 30));
    });
  });
}
