/// PC 推送接收端点（`GET /` 推送页 + `POST /action?do=push`）。
///
/// 对应验收门：`docs/superpowers/plans/2026-11-20-push-receive-and-title.md`。
/// 与 `phase5_sync_server_test` 同一口径：走**真实回环 HTTP**，绑定 127.0.0.1，
/// 因为要证明的就是"安卓按同一路径能打到"。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/push_parser.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_server.dart';

const int testPortStart = 18620;
const int testPortEnd = 18630;

/// 推送端点专用测试宿主（不接数据库：本套件只验证路由、门禁与解析）。
class PushTestHost {
  PushTestHost({
    this.serviceEnabled = true,
    this.pushEnabled = false,
    this.accept = true,
  });

  bool serviceEnabled;
  bool pushEnabled;
  bool accept;

  final LogService log = LogService();
  final List<PushParsed> accepted = [];

  SyncServerHost get host => SyncServerHost(
    deviceUuid: 'pc-fixture-uuid-0001',
    deviceName: 'WebHTV PC（测试）',
    isEnabled: () => serviceEnabled,
    isPeerAuthorized: (_) => true,
    onHistory: (parsed, {String sourceKey = ''}) async =>
        const SyncMergeStats.empty(),
    onKeep: (parsed) async => const SyncMergeStats.empty(),
    onBackup: (backup, allowSensitive) async =>
        SyncSettings.fromBackup(backup, allowSensitive: false),
    isPushEnabled: () => pushEnabled,
    onPush: (parsed) async {
      accepted.add(parsed);
      return accept;
    },
  );
}

Future<SyncServer> startServer(PushTestHost testHost) async {
  final server = SyncServer(
    log: testHost.log,
    host: testHost.host,
    bindAddress: '127.0.0.1',
    startPort: testPortStart,
    endPort: testPortEnd,
    lanIpOverride: '127.0.0.1',
  );
  await server.start();
  addTearDown(server.stop);
  return server;
}

void main() {
  group('推送页 /', () {
    test('接收推送未开启 → 404 且说明原因', () async {
      final testHost = PushTestHost();
      final server = await startServer(testHost);
      final response = await http.get(Uri.parse('${server.baseUrl}/'));
      expect(response.statusCode, 404);
      expect(response.body, contains('接收推送未开启'));
    });

    test('只开推送不开服务 → 也 404（不能绕过局域网服务开关）', () async {
      final testHost = PushTestHost(pushEnabled: true, serviceEnabled: false);
      final server = await startServer(testHost);
      final response = await http.get(Uri.parse('${server.baseUrl}/'));
      expect(response.statusCode, 404);
      expect(response.body, contains('局域网服务未开启'));
    });

    test('开启后返回 HTML 两栏页面', () async {
      final testHost = PushTestHost(pushEnabled: true);
      final server = await startServer(testHost);
      for (final path in ['/', '/index.html']) {
        final response = await http.get(Uri.parse('${server.baseUrl}$path'));
        expect(response.statusCode, 200, reason: path);
        expect(
          response.headers['content-type'],
          contains('text/html'),
          reason: path,
        );
        expect(response.body, contains('name="url"'), reason: path);
        expect(response.body, contains('name="title"'), reason: path);
        expect(response.body, contains('do=push'), reason: path);
        expect(response.body, contains('WebHTV PC（测试）'), reason: path);
        expect(response.body, isNot(contains('%DEVICE%')), reason: path);
      }
    });
  });

  group('POST /action?do=push', () {
    test('两栏字段被解析并交给状态层', () async {
      final testHost = PushTestHost(pushEnabled: true);
      final server = await startServer(testHost);
      final response = await http.post(
        Uri.parse('${server.baseUrl}/action?do=push'),
        body: {'url': 'https://cdn.example/a.m3u8', 'title': '庆余年'},
      );
      expect(response.statusCode, 200);
      expect(response.body, contains('OK push'));
      expect(testHost.accepted, hasLength(1));
      expect(testHost.accepted.single.url, 'https://cdn.example/a.m3u8');
      expect(testHost.accepted.single.title, '庆余年');
    });

    test('安卓同款 地址|剧名 单栏写法也认', () async {
      final testHost = PushTestHost(pushEnabled: true);
      final server = await startServer(testHost);
      final response = await http.post(
        Uri.parse('${server.baseUrl}/action?do=push'),
        body: {'url': 'https://cdn.example/a.m3u8|庆余年'},
      );
      expect(response.statusCode, 200);
      expect(testHost.accepted.single.url, 'https://cdn.example/a.m3u8');
      expect(testHost.accepted.single.title, '庆余年');
    });

    test('GET 查询串同样可用（curl 与老发送端）', () async {
      final testHost = PushTestHost(pushEnabled: true);
      final server = await startServer(testHost);
      final uri = Uri.parse(
        '${server.baseUrl}/action?do=push&url=https%3A%2F%2Fcdn.example%2Fa.m3u8&title=%E5%BA%86%E4%BD%99%E5%B9%B4',
      );
      final response = await http.get(uri);
      expect(response.statusCode, 200);
      expect(testHost.accepted.single.title, '庆余年');
    });

    test('缺 url → 400', () async {
      final testHost = PushTestHost(pushEnabled: true);
      final server = await startServer(testHost);
      final response = await http.post(
        Uri.parse('${server.baseUrl}/action?do=push'),
        body: {'title': '只有剧名'},
      );
      expect(response.statusCode, 400);
      expect(response.body, contains('缺少 url'));
      expect(testHost.accepted, isEmpty);
    });

    test('接收推送未开启 → 403 且不交给状态层', () async {
      final testHost = PushTestHost();
      final server = await startServer(testHost);
      final response = await http.post(
        Uri.parse('${server.baseUrl}/action?do=push'),
        body: {'url': 'https://cdn.example/a.m3u8'},
      );
      expect(response.statusCode, 403);
      expect(response.body, contains('接收推送未开启'));
      expect(testHost.accepted, isEmpty);
    });

    test('状态层没接住 → 503（不让手机看到假的成功）', () async {
      final testHost = PushTestHost(pushEnabled: true, accept: false);
      final server = await startServer(testHost);
      final response = await http.post(
        Uri.parse('${server.baseUrl}/action?do=push'),
        body: {'url': 'https://cdn.example/a.m3u8'},
      );
      expect(response.statusCode, 503);
    });

    test('do=cast 仍然明确拒绝（PC 不实现安卓本机操作）', () async {
      final testHost = PushTestHost(pushEnabled: true);
      final server = await startServer(testHost);
      final response = await http.post(
        Uri.parse('${server.baseUrl}/action?do=cast'),
        body: {'url': 'https://cdn.example/a.m3u8'},
      );
      expect(response.statusCode, 400);
      expect(response.body, contains('do=push'));
      expect(response.body, contains('do=sync'));
      expect(testHost.accepted, isEmpty);
    });

    test('do=sync 仍走既有校验（缺 mode/type 不回落到推送）', () async {
      final testHost = PushTestHost(pushEnabled: true);
      final server = await startServer(testHost);
      final response = await http.post(
        Uri.parse('${server.baseUrl}/action?do=sync'),
      );
      expect(response.statusCode, 400);
      expect(testHost.accepted, isEmpty);
    });
  });

  group('来源网段与日志脱敏', () {
    test('回环与私有网段放行，公网拒绝', () {
      for (final address in [
        '127.0.0.1',
        '192.168.50.9',
        '10.1.2.3',
        '172.16.0.9',
        '172.31.255.1',
        '169.254.1.1',
        '::1',
        'fe80::1',
        'fc00::1',
      ]) {
        expect(
          isLanOrLoopback(InternetAddress(address)),
          isTrue,
          reason: address,
        );
      }
      for (final address in ['8.8.8.8', '172.32.0.1', '203.0.113.9', '2001:db8::1']) {
        expect(
          isLanOrLoopback(InternetAddress(address)),
          isFalse,
          reason: address,
        );
      }
    });

    test('日志里只留 scheme + host', () {
      expect(
        redactPushUrl('https://cdn.example/a.m3u8?token=secret'),
        'https://cdn.example',
      );
      expect(redactPushUrl('/mnt/videos/a.mkv'), '/mnt/videos/a.mkv');
      expect(redactPushUrl(''), '');
    });
  });
}
