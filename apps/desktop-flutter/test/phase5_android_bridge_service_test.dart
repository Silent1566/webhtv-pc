/// Phase 5 · 安卓设备探测与 T4 配置拉取服务（`docs/phase5/design/01` §4/§6）。
///
/// 对应门禁：`docs/phase5/design/03` §3.1 的服务层部分 —— 请求形态（**特别是
/// `Host` 头**）、6 类错误分类、脱敏。
///
/// L2 用**请求捕获**断言请求形态，不只断言最终解析结果（`design/03` §1）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/log_service.dart';

import 'fixture_support.dart';

/// 可捕获请求（含 Header）的假 HTTP 客户端。
class _FakeClient extends http.BaseClient {
  final List<Uri> requests = [];
  final List<Map<String, String>> headers = [];

  /// 路径 → 响应体。按插入顺序首个 `endsWith` 匹配生效。
  final List<(String, Object?, int)> routes = [];

  /// 非空时所有请求抛该异常。
  Object? failure;
  Duration delay = Duration.zero;

  void route(String pathSuffix, Object? body, {int status = 200}) {
    routes.add((pathSuffix, body, status));
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    headers.add(Map<String, String>.from(request.headers));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final local = failure;
    if (local != null) throw local;

    for (final (suffix, body, status) in routes) {
      if (request.url.path.endsWith(suffix)) {
        final text = body is String ? body : jsonEncode(body);
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(text)),
          status,
        );
      }
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"status":404}')),
      404,
    );
  }
}

/// 捕获日志，用于脱敏断言。
class _RecordingLog extends LogService {
  final List<String> lines = [];

  @override
  void info(String message, {String? scope}) {
    lines.add(message);
    super.info(message, scope: scope);
  }

  @override
  void warning(String message, {String? scope}) {
    lines.add(message);
    super.warning(message, scope: scope);
  }
}

String withHost(String json, String host) =>
    json.replaceAll('http://__HOST__', host);

const String reachable = 'http://192.168.1.5:9978';

void main() {
  late _FakeClient client;
  late _RecordingLog log;
  late AndroidBridgeService service;

  setUp(() {
    client = _FakeClient();
    log = _RecordingLog();
    service = AndroidBridgeService(
      log: log,
      client: client,
      timeout: const Duration(seconds: 2),
      scanTimeout: const Duration(milliseconds: 200),
    );
  });

  tearDown(() => service.close());

  group('设备探测（design/01 §4.3）', () {
    test('GET /device 并解析设备', () async {
      client.route('/device', readFixture('android/device.json'));
      final device = await service.probeDevice('192.168.1.5');
      expect(client.requests.single.path, '/device');
      expect(device.reachableBase, reachable);
      expect(device.name, isNotEmpty);
    });

    test('请求显式带 Host 头（网关据此派生站点地址）', () async {
      client.route('/device', readFixture('android/device.json'));
      await service.probeDevice('192.168.1.5');
      // 实测：真实网关用请求的 Host 现算站点 api。显式设置可避免中间层
      // （隧道 / 反向代理 / adb forward）改写后得到不可用地址。
      expect(client.headers.single['Host'], '192.168.1.5:9978');
    });

    test('缺 scheme / 缺端口时规范化后再请求', () async {
      client.route('/device', readFixture('android/device.json'));
      final device = await service.probeDevice('192.168.1.5');
      expect(client.requests.single.port, 9978);
      expect(device.reachableBase, reachable);
    });

    test('非设备 JSON → bridgeNotAndroid', () async {
      client.route('/device', {'hello': 'world'});
      await expectLater(
        service.probeDevice(reachable),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.bridgeNotAndroid,
          ),
        ),
      );
    });

    test('非 JSON 响应 → bridgeNotAndroid（不是 siteParse）', () async {
      client.route('/device', '<html>404</html>');
      await expectLater(
        service.probeDevice(reachable),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.bridgeNotAndroid,
          ),
        ),
      );
    });

    test('连接被拒 → bridgeUnreachable 且可重试', () async {
      client.failure = const SocketException('connection refused');
      try {
        await service.probeDevice(reachable);
        fail('应当抛出');
      } on AppError catch (error) {
        expect(error.kind, AppErrorKind.bridgeUnreachable);
        expect(error.retryable, isTrue);
      }
    });

    test('超时 → bridgeUnreachable 且可重试', () async {
      client.route('/device', readFixture('android/device.json'));
      client.delay = const Duration(seconds: 3);
      try {
        await service.probeDevice(reachable);
        fail('应当抛出');
      } on AppError catch (error) {
        expect(error.kind, AppErrorKind.bridgeUnreachable);
        expect(error.retryable, isTrue);
      }
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('probeOne 把失败归一化为 BridgeDiscovery.error（不抛）', () async {
      client.failure = const SocketException('nope');
      final discovery = await service.probeOne(reachable);
      expect(discovery.isDevice, isFalse);
      expect(discovery.error?.kind, AppErrorKind.bridgeUnreachable);
    });
  });

  group('配置拉取（design/01 §5/§6）', () {
    test('GET /vod/api?ac=config 并转换 170 个站点', () async {
      client.route(
        '/vod/api',
        withHost(readFixture('android/gateway-config.json'), reachable),
      );
      final conversion = await service.fetchGatewayConfig(reachable);
      expect(client.requests.single.queryParameters['ac'], 'config');
      expect(conversion.siteCount, 170);
      expect(conversion.config.sites.first.api, startsWith(reachable));
    });

    test('ac=config 的 404 → bridgeNoGateway（版本过旧，不是「0 个站点」）', () async {
      // 未注册 /vod/api 路由 → 假客户端返回 404。
      await expectLater(
        service.fetchGatewayConfig(reachable),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.bridgeNoGateway,
          ),
        ),
      );
    });

    test('空 sites → bridgeEmptySites（不折叠成「导入成功 0 站点」）', () async {
      client.route('/vod/api', readFixture('android/gateway-config-empty.json'));
      await expectLater(
        service.fetchGatewayConfig(reachable),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.bridgeEmptySites,
          ),
        ),
      );
    });

    test('第三方主机 → bridgeHostMismatch（P2 拒绝导入）', () async {
      client.route(
        '/vod/api',
        readFixture('android/gateway-config-mismatch.json'),
      );
      await expectLater(
        service.fetchGatewayConfig(reachable),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.bridgeHostMismatch,
          ),
        ),
      );
    });

    test('回环响应 → 重写为可达地址并给可见诊断（P2 不静默）', () async {
      client.route('/vod/api', readFixture('android/gateway-config-loopback.json'));
      final conversion = await service.fetchGatewayConfig(reachable);
      expect(conversion.hostRewrites, hasLength(1));
      expect(conversion.diagnostics, isNotEmpty);
      expect(conversion.config.sites.single.api, startsWith(reachable));
    });

    test('自引用（目标即本机）→ bridgeSelfReference', () async {
      client.route('/vod/api', readFixture('android/gateway-config-loopback.json'));
      await expectLater(
        service.fetchGatewayConfig(reachable, selfBase: reachable),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.bridgeSelfReference,
          ),
        ),
      );
    });

    test('阶段回调按序发出', () async {
      client.route(
        '/vod/api',
        withHost(readFixture('android/gateway-config.json'), reachable),
      );
      final stages = <BridgeStage>[];
      await service.fetchGatewayConfig(reachable, onStage: stages.add);
      expect(stages, [
        BridgeStage.fetchingConfig,
        BridgeStage.converting,
        BridgeStage.done,
      ]);
    });
  });

  group('脱敏（design/01 §7）', () {
    test('日志不含设备指纹原文（uuid 只留前 4 位）', () async {
      final deviceJson = readFixture('android/device.json');
      final device = jsonDecode(deviceJson) as Map<String, dynamic>;
      client.route('/vod/api', readFixture('android/gateway-config-empty.json'));
      // 直接驱动扫描路径会全网段扫描，这里改为断言探测日志口径。
      client.route('/device', deviceJson);
      final found = await service.probeOne(reachable);
      expect(found.device, isNotNull);
      log.lines.add('probe ${found.device!.maskedUuid}');
      for (final line in log.lines) {
        expect(line, isNot(contains(device['uuid'])));
        expect(line, isNot(contains(device['serial'])));
        expect(line, isNot(contains(device['wlan'])));
      }
    });

    test('拉取日志含站点数但不含站点名列表', () async {
      client.route(
        '/vod/api',
        withHost(readFixture('android/gateway-config.json'), reachable),
      );
      await service.fetchGatewayConfig(reachable);
      final joined = log.lines.join('\n');
      expect(joined, contains('sites=170'));
      expect(joined, contains(reachable));
      // 站点名属于内容而非诊断信息，不进日志。
      expect(joined, isNot(contains('片单导航')));
    });
  });
}
