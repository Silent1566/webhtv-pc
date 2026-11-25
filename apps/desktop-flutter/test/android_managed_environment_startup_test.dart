/// 冷启动恢复管理型（ADB）记录：绝不探测旧的本机转发端口，必须走已保存的环境描述。
///
/// 缺陷前提（R6 修正）：管理型记录的 origin 是上次连接时 adb 分配的本机转发
/// 端口，重启后必然失效。旧启动路径拿它去 probeAutoConnectTarget，于是
/// 「记录还在、端口已死」：站源地址停在旧端口、恢复静默失败。本文件用真实
/// AppShell + 真实 AppState 锁定新分支：先按已保存描述重连并重导入，
/// 再按坐标激活；描述缺失/设备不符时给横幅，绝不请求旧端口、不丢标记。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/services/android_adb_runtime.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/android_connection_store.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';

import 'android_adb_runtime_fixtures.dart';
import 'support/temp_dirs.dart';

const String _deviceUuid = 'uuid-startup-0001';
const String _interfaceKey = 'managed-startup';
const String _target = '10.0.2.2:5555';

/// 旧端口：重启后必然已经没人监听，任何请求打到它都算缺陷。
const String _oldOrigin = 'http://127.0.0.1:34567';
const String _oldAuthority = '127.0.0.1:34567';

/// 手写的管理型源标识。
const String _sourceKey = 'bridge|$_deviceUuid|$_interfaceKey';

http.Response _json(Object? body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// 受控 T4 网关（HTTP 边界），记录每个被请求的 authority。
class _GatewayHttp {
  String uuid = _deviceUuid;
  final List<Uri> requests = <Uri>[];
  final List<String> authorities = <String>[];

  late final http.Client client = MockClient((request) async {
    requests.add(request.url);
    authorities.add(request.url.authority);
    switch (request.url.path) {
      case '/device':
        return http.Response(
          deviceJson(uuid: uuid, name: '客厅电视'),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      case '/manage/configs':
        return _json({
          'items': [
            {
              'type': 0,
              'name': '管理型源',
              'url': 'https://sub.example.test/a.json',
              'interfaceKey': _interfaceKey,
              'active': true,
              'time': 1700000000000,
            },
          ],
        });
      case '/vod/api':
        final authority = request.url.authority;
        return _json({
          'class': [
            {'type_id': '1', 'type_name': '电影'},
          ],
          'list': [
            {'vod_id': 'v1', 'vod_name': '管理型影片', 'vod_pic': ''},
          ],
          'sites': [
            {
              'key': 'managed-site',
              'name': '受控站点',
              'type': '4',
              'api': 'http://$authority/vod/api?key=managed-site',
              'searchable': 1,
            },
          ],
          'lives': <Object>[],
        });
    }
    return http.Response('not found', 404);
  });
}

class _StartupEnv {
  _StartupEnv(this.tempDir) {
    // 受控自有 ADB 服务：被启动时按参数端口绑定协议夹具（绝不执行真实 adb）。
    processes.onStart = (executable, arguments, environment) async {
      final port = int.parse(arguments[1].substring(4));
      final bound = await FakeAdbServer.bind(port: port);
      adb = bound;
      return FakeProcess.detached(
        onKill: () async {
          await bound.close();
        },
      );
    };
  }

  final Directory tempDir;
  final _GatewayHttp gateway = _GatewayHttp();
  final FakeProcessHost processes = FakeProcessHost();
  FakeAdbServer? adb;

  late final AppPaths paths = AppPaths.resolve(
    overrides: {
      'config': '${tempDir.path}/webhtv-pc',
      'data': '${tempDir.path}/webhtv-pc',
      'cache': '${tempDir.path}/webhtv-pc/cache',
      'state': '${tempDir.path}/webhtv-pc/logs',
    },
  );

  late final AndroidBridgeService bridge = AndroidBridgeService(
    log: LogService(),
    timeout: const Duration(seconds: 3),
    client: gateway.client,
  );

  late final AndroidAdbRuntime runtime = AndroidAdbRuntime(
    bridge: bridge,
    log: LogService(),
    processes: processes,
    commandTimeout: const Duration(milliseconds: 500),
    connectTimeout: const Duration(seconds: 3),
  );

  late AppState state;

  /// 手工落一条「上一次会话留下的」管理型记录：origin 是旧端口，站点 api 也是。
  Future<void> seed({
    required bool withProfile,
    String profileUuid = _deviceUuid,
  }) async {
    final configDir = Directory('${tempDir.path}/webhtv-pc');
    configDir.createSync(recursive: true);
    if (withProfile) {
      File('${configDir.path}/$androidConnectionsFileName').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'records': [
            {
              'profile': {
                'version': 1,
                'mode': 'network',
                'target': _target,
                'adbPath': '',
                'emulatorPath': '',
                'avdHome': '',
                'serverPort': 5037,
                'gatewayPort': 9978,
              },
              'deviceUuid': profileUuid,
              'name': '客厅电视',
              'lastUsedMs': 1700000000000,
            },
          ],
        }),
      );
    }

    final seeder = AppState(
      paths: paths,
      log: LogService(),
      httpClient: gateway.client,
    );
    await seeder.bootstrap();
    seeder.syncDatabase!.saveConfig(
      name: '管理型源',
      origin: _oldOrigin,
      json: const {
        'sites': [
          {
            'key': 'managed-site',
            'name': '受控站点',
            'type': 4,
            'api': 'http://127.0.0.1:34567/vod/api?key=managed-site',
          },
        ],
      },
      contentType: 'android-t4-gateway',
      siteCount: 1,
      liveCount: 0,
      makeActive: true,
      sourceKey: _sourceKey,
      bridgeDevice: _deviceUuid,
      bridgeInterfaceKey: _interfaceKey,
      bridgeConfigUrl: 'https://sub.example.test/a.json',
      bridgeTransport: 'adb',
    );
    seeder.dispose();

    state = AppState(
      paths: paths,
      log: LogService(),
      androidBridgeService: bridge,
      androidAdbRuntime: runtime,
      httpClient: gateway.client,
    );
    await state.bootstrap();
  }
}

/// 交替推进真实事件循环与假时钟，直到 done 成立（有界）。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  int rounds = 300,
  String Function()? describe,
}) async {
  for (var round = 0; round < rounds; round++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (done()) return;
  }
  fail('启动恢复未在预算内收敛：${describe?.call() ?? '（无诊断）'}');
}

Future<void> _mountShell(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: AppShell(state: state, startup: const StartupArguments()),
    ),
  );
  await tester.pump();
}

void main() {
  late Directory tempDir;
  late _StartupEnv env;

  setUp(() async {
    // setUp 不在 fake-async 区里：这里的真实文件/DB/日志 I/O 可以正常完成。
    tempDir = await Directory.systemTemp.createTemp('webhtv-adb-startup');
    env = _StartupEnv(tempDir);
  });

  tearDown(() async {
    await deleteTempDirBestEffort(tempDir);
  });

  void testStartup(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          env.state.dispose();
        });
      }
    });
  }

  testStartup('已有描述：启动按它重连刷新，不请求旧端口，标记与源标识保持不变', (tester) async {
    await tester.runAsync(() => env.seed(withProfile: true));
    final before = env.state.activeRecord!;
    expect(before.origin, _oldOrigin);
    expect(before.bridgeTransport, 'adb');

    await _mountShell(tester, env.state);
    String diag() {
      final record = env.state.savedConfigs.single;
      final sync = env.state.syncState;
      final log = env.state.log.export();
      return 'origin=${record.origin} transport=${record.bridgeTransport} '
          'error=${env.state.lastError?.logLine} '
          'paths=${env.gateway.requests.map((uri) => uri.path).join(',')} '
          'busy=${sync.busy} syncError=${sync.lastError?.logLine} '
          'devices=${sync.devices.length} '
          'connections=${env.state.androidConnections.length} '
          'LOG[${log.length > 900 ? log.substring(log.length - 900) : log}]';
    }

    await _pumpUntil(
      tester,
      () => env.state.configs.single.origin != _oldOrigin,
      describe: diag,
    );
    await tester.pump();

    final after = env.state.configs.single;
    expect(after.id, before.id, reason: '刷新是原地更新，不许新插一条');
    expect(after.sourceKey, _sourceKey);
    expect(after.bridgeTransport, 'adb', reason: '重导入不得丢掉内部标记');
    expect(after.origin, startsWith('http://127.0.0.1:'));
    expect(after.origin, isNot(_oldOrigin));
    expect(env.state.activeRecord?.id, before.id);

    // 站源 api 必须指向新网关（旧端口不再被用）。
    final api = Uri.parse(env.state.siteService!.appConfig.sites.single.api);
    expect(api.authority, Uri.parse(after.origin).authority);
    expect(
      env.gateway.authorities,
      isNot(contains(_oldAuthority)),
      reason: '启动恢复绝不能拿记录里的旧回环端口去探测',
    );
    expect(
      find.byKey(const ValueKey('bridge-restore-banner')),
      findsNothing,
      reason: '成功恢复不该留横幅',
    );
  });

  testStartup('描述缺失：给可操作横幅，记录与标记原样保留，不请求旧端口', (tester) async {
    await tester.runAsync(() => env.seed(withProfile: false));

    await _mountShell(tester, env.state);
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('bridge-restore-banner'))
          .evaluate()
          .isNotEmpty,
    );

    expect(find.byKey(const ValueKey('bridge-restore-banner')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bridge-restore-retry')),
      findsOneWidget,
      reason: '横幅必须给出下一步动作（重试），而不是只解释',
    );
    final text = tester
        .widget<Text>(find.byKey(const ValueKey('bridge-restore-banner-text')))
        .data!;
    expect(text, contains('重新连接已保存的安卓环境'));

    final record = env.state.savedConfigs.single;
    expect(record.origin, _oldOrigin, reason: '没连上就不许改记录地址');
    expect(record.sourceKey, _sourceKey);
    expect(record.bridgeTransport, 'adb');
    expect(
      env.gateway.authorities,
      isNot(contains(_oldAuthority)),
      reason: '没有描述时绝不能拿旧端口去探测',
    );
  });

  testStartup('设备不符：expectedUuid 拦下，横幅说明不一致，标记不丢', (tester) async {
    await tester.runAsync(() => env.seed(withProfile: true));
    // 已保存的描述属于 uuid-startup-0001，但网关后面换了另一台设备。
    env.gateway.uuid = 'uuid-live-other';

    await _mountShell(tester, env.state);
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('bridge-restore-banner'))
          .evaluate()
          .isNotEmpty,
    );

    expect(find.byKey(const ValueKey('bridge-restore-banner')), findsOneWidget);
    final text = tester
        .widget<Text>(find.byKey(const ValueKey('bridge-restore-banner-text')))
        .data!;
    expect(text, contains('不一致'));

    final record = env.state.savedConfigs.single;
    expect(record.origin, _oldOrigin);
    expect(record.bridgeTransport, 'adb');
    expect(record.sourceKey, _sourceKey);
    expect(record.bridgeDevice, _deviceUuid, reason: '设备不符时不许改已保存的绑定');
    expect(env.gateway.authorities, isNot(contains(_oldAuthority)));
  });
}
