/// Phase 7 · 身份注册表的持久化（`design/01` §3.2.1）。
///
/// 为什么单独一个套件：`adopt` 的结论必须**跨重启**可用。安卓拿到
/// `canonicalInterfaceKey` 后会把自己的 `interfaceKey` 改成它；若 PC 丢了
/// 注册表，下次解析就会「按同一批地址键**新造**一个身份」，两端的键永久错开
/// ——而且**不报错**，只是历史再也对不上。
///
/// 用真实文件 I/O + 真实 HTTP（`test()` 而不是 `testWidgets`：本文件不做
/// UI 断言，fake-async 会把真实 I/O 挂死）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/android_bridge.dart';
import 'package:webhtv_pc/core/playback_identity.dart';
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_client.dart';
import 'package:webhtv_pc/services/sync_server.dart';
import 'package:webhtv_pc/state/app_state.dart';

/// 不做任何真实网络的桥接与客户端（本套件不测桥接/推送）。
class _OfflineBridge extends AndroidBridgeService {
  _OfflineBridge() : super(log: LogService());
}

class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      throw const SocketException('测试禁止出网');
}

Map<String, Object?> resolveBody({
  required String interfaceKey,
  required String strictKey,
}) => {
  'schema': playbackIdentitySchema,
  'operation': 'resolve',
  'configType': 'vod',
  'interfaceKey': interfaceKey,
  'strictAddressKeys': [strictKey],
  'endpointMatchKeys': <String>[],
  'hostMatchKeys': <String>[],
  'legacyConfigKeys': <String>[],
  'sourceDataState': 'empty',
  'client': 'android',
  'appVersion': '5.6.0',
};

Future<Map<String, Object?>> postResolve(
  String baseUrl,
  Map<String, Object?> body,
) async {
  final response = await http.post(
    Uri.parse('$baseUrl/api/playback/identity/resolve'),
    headers: const {'content-type': 'application/json'},
    body: jsonEncode(body),
  );
  expect(response.statusCode, 200, reason: '响应体：${response.body}');
  final decoded = jsonDecode(response.body);
  expect(decoded, isA<Map<String, Object?>>());
  return decoded as Map<String, Object?>;
}

/// 轮询等 `sync.identity.vod` 出现在 settings.json 里（最多 5 秒）。
///
/// 为什么不直接读一次：`PlaybackIdentityStore.onChanged → _persist()` 是
/// fire-and-forget（不能阻塞 HTTP 响应），响应返回时文件可能还没写完。
Future<Map<String, Object?>> waitForVodRegistry(String settingsPath) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final file = File(settingsPath);
    if (await file.exists()) {
      try {
        final settings =
            jsonDecode(await file.readAsString()) as Map<String, Object?>;
        final vod =
            ((settings['sync'] as Map?)?['identity'] as Map?)?['vod'] as Map?;
        if (vod != null && vod['identities'] is Map && (vod['identities'] as Map).isNotEmpty) {
          return vod.map((key, value) => MapEntry('$key', value));
        }
      } on Object {
        // 写到一半的 JSON：下一轮再试。
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('等不到 settings.json 的 sync.identity.vod（注册表未落盘）');
}

void main() {
  late Directory tempDir;
  late AppPaths paths;

  AppState buildState() => AppState(
    paths: paths,
    log: LogService(),
    androidBridgeService: _OfflineBridge(),
    syncClient: SyncClient(log: LogService(), client: _NoNetworkClient()),
    // 固定回环 + 测试端口区间：不占 9978，也不碰局域网。
    syncServerFactory: (host) => SyncServer(
      log: LogService(),
      host: host,
      bindAddress: '127.0.0.1',
      lanIpOverride: '127.0.0.1',
      startPort: 18740,
      endPort: 18750,
    ),
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-sync-identity');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/webhtv-pc',
        'data': '${tempDir.path}/webhtv-pc',
        'cache': '${tempDir.path}/webhtv-pc/cache',
        'state': '${tempDir.path}/webhtv-pc/logs',
      },
    );
    // 预置一台「已授权」的安卓对端（回环地址）：未配置 token 时只允许
    // 白名单对端，这是 `design/01` §3.2.2 的默认局域网形态。
    final settingsFile = File(paths.settingsPath);
    await settingsFile.parent.create(recursive: true);
    await settingsFile.writeAsString(
      jsonEncode({
        'sync': {
          'peers': [
            {
              'uuid': 'android-uuid-0001',
              'name': '测试电视',
              'address': 'http://127.0.0.1:19978',
            },
          ],
        },
      }),
    );
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // Windows 上偶发占用，清理失败不影响断言。
    }
  });

  test('adopt 结论跨重启存活（注册表写进 settings.json 的 sync.identity）', () async {
    // —— 第一次运行：设备 A 首次提交 → create。
    final first = buildState();
    await first.bootstrap();
    expect(
      await first.syncState.setServerEnabled(true),
      isTrue,
      reason: '前置条件：服务端要能起来',
    );
    final firstBase = first.syncState.serverBaseUrl;
    expect(firstBase, isNotNull);
    final created = await postResolve(
      firstBase!,
      resolveBody(interfaceKey: 'device-a', strictKey: 's' * 64),
    );
    expect(created['action'], 'create');
    final firstEpoch = int.parse('${created['identityEpoch']}');
    expect(firstEpoch, greaterThan(0));

    // 落盘证据：settings.json 的 sync.identity 里能看到这条身份。
    //
    // `onChanged` 是 fire-and-forget（不能阻塞 HTTP 响应），所以这里轮询等
    // 写入完成，而不是假设「响应返回 = 已落盘」。
    final vod = await waitForVodRegistry(paths.settingsPath);
    expect(vod['epoch'], firstEpoch);

    await first.syncState.setServerEnabled(false);
    first.dispose();

    // —— 第二次运行（同一数据目录）：设备 B 命中同一 strict 键 → adopt。
    final second = buildState();
    await second.bootstrap();
    expect(await second.syncState.setServerEnabled(true), isTrue);
    final secondBase = second.syncState.serverBaseUrl;
    final adopted = await postResolve(
      secondBase!,
      resolveBody(interfaceKey: 'device-b', strictKey: 's' * 64),
    );
    expect(
      adopted['action'],
      'adopt',
      reason: '注册表没落盘的话这里会退化成 create，两端身份永久错开',
    );
    expect(adopted['canonicalInterfaceKey'], 'device-a');

    await second.syncState.setServerEnabled(false);
    second.dispose();
  });

  test('注册表为空文件/缺失时安全退化（不抛、不留脏别名）', () async {
    final settingsFile = File(paths.settingsPath);
    final current =
        jsonDecode(await settingsFile.readAsString()) as Map<String, Object?>;
    final sync = current['sync']! as Map<String, Object?>;
    sync['deviceUuid'] = 'pc-uuid';
    sync['identity'] = {
      'vod': {
        'epoch': 5,
        'identities': <String, Object?>{},
        'aliases': {
          'k': {'canonicalInterfaceKey': 'gone', 'kind': 'strict'},
        },
      },
    };
    await settingsFile.writeAsString(jsonEncode(current));

    final state = buildState();
    await state.bootstrap();
    expect(await state.syncState.setServerEnabled(true), isTrue);
    final base = state.syncState.serverBaseUrl!;

    // 脏别名被丢弃 → 提交同一把键仍然是 create（不会指向不存在的身份）。
    final response = await postResolve(
      base,
      resolveBody(interfaceKey: 'device-a', strictKey: 'k'),
    );
    expect(response['action'], 'create');
    expect(response['canonicalInterfaceKey'], 'device-a');

    await state.syncState.setServerEnabled(false);
    state.dispose();
  });

  test('安卓设备实体不会把身份键当 uuid 混用（边界澄清）', () async {
    // 这条只是把「身份键 ≠ 设备 uuid」写成断言，避免以后有人复用字段。
    const device = AndroidDevice(
      uuid: 'device-uuid',
      name: '电视',
      reachableBase: 'http://192.168.50.9:9978',
      reportedIp: '',
      type: 1,
    );
    expect(device.uuid, isNot('device-a'));
  });
}
