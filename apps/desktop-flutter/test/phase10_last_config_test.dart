/// Phase 10 · 启动恢复「最后一次使用的配置」。
///
/// ## 锁定的用户可见行为
///
/// 1. 没有 `last-config.json` 且 `is_active` 是本地源 → 与升级前完全一致
///    （加载首页、**零**探测）；
/// 2. 没有 `last-config.json` 但 `is_active` 是桥接源（旧版本升级上来的真实
///    场景）→ 按该记录的 deviceUuid 兜底探**一次**，成功则导入并精确激活，
///    不可达则与「有记忆」时同一条横幅；兜底推断**不写**记忆；
/// 3. 记忆是本地源 → 按记忆恢复（而不是按 `is_active`），**零**探测；
/// 4. 记忆是桥接源且可达 → 只重拉**该源**并精确激活上次那条记录（同一设备
///    两个源时，按 origin 挑会命中最后导入的那条，那是本次要修的缺陷）；
/// 5. 记忆是桥接源且不可达 → 非阻塞横幅，文案含设备名/地址/失败分类；
///    「重试」再探一次、「切换播放源」唤起源选择器、关闭后不再出现；
/// 6. 记忆指向已删除的记录 → 静默回落 + 一条日志，无弹窗、无横幅。
///
/// ## 装配纪律（与 `phase2_startup_home_test.dart` 同一套）
///
/// - 一切真实 I/O（`createTemp`/DB/写盘）放在 `setUp` 或 `tester.runAsync`
///   里：`testWidgets` 是假时钟，直接 await 真实 I/O 会永久挂起；
/// - 收敛循环**不能**用 `pumpAndSettle`（加载态里有无限动画），改用有界轮次；
/// - 桥接全部走 `FakeSourcesBridge`，用例里不触网。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/android_bridge.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/last_config_store.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';

import 'support/fake_sources_bridge.dart';

const String _deviceUuid = 'dev-uuid-0001';
const String _deviceBase = 'http://192.168.50.9:9978';

Map<String, Object?> _homePayload() => {
  'class': [
    {'type_id': '1', 'type_name': '电影'},
  ],
  'list': [
    {'vod_id': 'v1', 'vod_name': '启动影片', 'vod_pic': ''},
  ],
};

/// 可注入探测失败的假桥接。
///
/// `test/support/fake_sources_bridge.dart` 没有失败注入口径，而它是共享文件
/// （另一条并行任务也在用），所以失败注入留在本文件里，靠子类完成。
class _FlakyBridge extends FakeSourcesBridge {
  /// 非空时 `probeDevice` 直接抛这个错误。
  AppError? probeFailure;

  /// 探测次数（失败也算：用来断言「只探一次，不轮询」）。
  int attempts = 0;

  @override
  Future<AndroidDevice> probeDevice(String base) async {
    attempts++;
    final failure = probeFailure;
    if (failure != null) throw failure;
    return super.probeDevice(base);
  }
}

/// 首页请求的替身（widget 测试不能做真实 socket I/O）。
class _CapturingClient extends http.BaseClient {
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(_homePayload()))),
      200,
    );
  }
}

const String _localConfigJson = '''
{
  "name": "本地配置",
  "sites": [
    {
      "key": "local_site",
      "name": "本地站点",
      "type": 4,
      "api": "http://127.0.0.1:19978/vod/api?key=local_site",
      "searchable": 1
    }
  ]
}
''';

String _bridgeSourceKey(String interfaceKey) =>
    BridgeSourceKey.of(deviceUuid: _deviceUuid, interfaceKey: interfaceKey);

/// 交替「推进一帧 → 给真实 I/O 一点时间」，有界收敛（不用 `pumpAndSettle`）。
Future<void> _settle(WidgetTester tester, {int rounds = 40}) async {
  for (var round = 0; round < rounds; round++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
  }
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  late Directory temp;
  late AppPaths paths;
  late _FlakyBridge bridge;
  late LogService log;
  late _CapturingClient client;
  late AppState state;

  Future<AppState> openState() async {
    final next = AppState(
      paths: paths,
      log: log,
      androidBridgeService: bridge,
      httpClient: client,
    );
    await next.bootstrap();
    return next;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-last-config');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    );
    bridge = _FlakyBridge();
    log = LogService();
    client = _CapturingClient();
    state = await openState();
    // 使用边界提示的标记写掉（配置目录由 bootstrap 创建，必须等它之后写）：
    // 底部弹层会占掉一屏，横幅断言就跟着不稳。
    await File(
      '${paths.configDir}${Platform.pathSeparator}usage-boundary-accepted',
    ).writeAsString('ok');
  });

  tearDown(() async {
    state.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  /// 冷启动：换一个新的 AppState 指向同一数据目录。
  Future<AppState> reopen(WidgetTester tester) async {
    state.dispose();
    final next = await tester.runAsync(openState);
    state = next!;
    return state;
  }

  Future<void> mountShell(WidgetTester tester, AppState target) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(state: target, startup: const StartupArguments()),
      ),
    );
    await _settle(tester);
  }

  /// 存一条桥接源记录（走真实的 `saveBridgeConfig`，与桥接导入同一条路径）。
  Future<int> saveBridgeSource(String interfaceKey, String name) async {
    final id = await state.saveBridgeConfig(
      name: name,
      origin: _deviceBase,
      config: AppConfig(
        sites: [
          Site(
            key: 'csp_$interfaceKey',
            name: '站点$interfaceKey',
            type: SiteType.jsonApiBase64Ext,
            api: '$_deviceBase/$interfaceKey',
          ),
        ],
      ),
      diagnostics: const [],
      deviceUuid: _deviceUuid,
      interfaceKey: interfaceKey,
      configUrl: 'https://sub.example/$interfaceKey.json',
    );
    expect(id, isNotNull, reason: '保存桥接记录失败：数据库不可用？');
    return id!;
  }

  /// 记下设备接入历史（自动接入按 uuid 从这里找地址）。
  Future<void> seedDeviceHistory() async {
    final device = await state.syncState.probe(_deviceBase);
    expect(device, isNotNull, reason: '假桥接必须能探测成功，否则用例前提不成立');
    expect(state.syncState.deviceHistory, hasLength(1));
  }

  testWidgets('验收 1a：没有 last-config.json 且 is_active 是本地源 → 零探测，照旧加载首页', (tester) async {
    await tester.runAsync(() async {
      expect(
        await state.importConfig(_localConfigJson, displayName: '本地'),
        isTrue,
        reason: state.lastError?.logLine,
      );
      // 本地源：兜底分支必须认出「这不是桥接源」，一个字都不多探。
      expect(state.activeRecord?.bridgeInterfaceKey ?? '', isEmpty);
      // 模拟「从没有这份记忆的旧版本升级上来」：配置在库里，但文件不存在。
      final memory = File(
        '${paths.dataDir}${Platform.pathSeparator}last-config.json',
      );
      expect(memory.existsSync(), isTrue, reason: '导入应写入记忆');
      memory.deleteSync();
    });

    final cold = await reopen(tester);
    expect(cold.lastConfigRecord, isNull, reason: '没有记忆时不得凭空造一条');
    expect(
      cold.activeRecord?.bridgeInterfaceKey ?? '',
      isEmpty,
      reason: 'is_active 必须仍指向本地源，否则这条用例没有测到兜底分支的空转',
    );
    final probesBefore = bridge.probeCalls;

    await mountShell(tester, cold);

    expect(bridge.probeCalls, probesBefore, reason: '本地源不得发起任何桥接探测');
    expect(cold.selectedSite?.key, 'local_site', reason: '选中配置里的默认站点');
    expect(cold.homeResult, isNotNull, reason: '首页必须照旧自动加载');
    expect(client.requests, isNotEmpty);
    expect(
      find.byKey(const ValueKey('bridge-restore-banner')),
      findsNothing,
      reason: '本地源不该出现桥接横幅',
    );
  });

  testWidgets('验收 1b：没有 last-config.json 但 is_active 是桥接源 → 仍按 deviceUuid 探一次；不可达出横幅', (tester) async {
    await tester.runAsync(() async {
      final a = await saveBridgeSource('a', '源 A');
      expect(await state.activateConfigRecord(a), isTrue);
      await seedDeviceHistory();
      // 旧版本升级：库里的 is_active 是桥接源，但记忆文件从没存在过。
      final memory = File(
        '${paths.dataDir}${Platform.pathSeparator}last-config.json',
      );
      expect(memory.existsSync(), isTrue, reason: '显式激活应写入记忆');
      memory.deleteSync();
    });
    bridge.probeFailure = AppError(
      AppErrorKind.bridgeUnreachable,
      '安卓设备不可达：连接被拒绝或超时',
    );

    final cold = await reopen(tester);
    expect(cold.lastConfigRecord, isNull, reason: '确实没有记忆，走的是兜底推断');
    expect(cold.activeRecord?.bridgeInterfaceKey, 'a');
    // 用 attempts 而不是 probeCalls：本文件注入的失败探测不递减 probeCalls，
    // 而 attempts「失败也算」，才量得出「只探一次」。
    final probesBefore = bridge.attempts;

    await mountShell(tester, cold);

    expect(
      bridge.attempts,
      probesBefore + 1,
      reason: '兜底恢复同样只探测一次（不扫描、不轮询）',
    );
    expect(
      find.byKey(const ValueKey('bridge-restore-banner')),
      findsOneWidget,
      reason: '兜底恢复也必须走同一条横幅路径，否则这类用户升级后毫无提示',
    );
    final text = tester
        .widget<Text>(find.byKey(const ValueKey('bridge-restore-banner-text')))
        .data!;
    expect(text, contains('测试电视'), reason: '设备名要按 uuid 从接入历史里查');
    expect(text, contains(_deviceBase), reason: '探测地址要按 uuid 从接入历史里查');
    expect(
      text,
      contains('bridgeUnreachable'),
      reason: '失败分类必须原样呈现',
    );
    expect(
      cold.homeResult,
      isNotNull,
      reason: '横幅是非阻塞的：首页照常加载，用户仍可继续用当前配置',
    );
    expect(
      File('${paths.dataDir}${Platform.pathSeparator}last-config.json').existsSync(),
      isFalse,
      reason: '兜底推断不得写记忆：记忆只来自用户显式选择',
    );
  });

  testWidgets('验收 2：记忆是本地源时按记忆恢复，零探测', (tester) async {
    final restoredId = await tester.runAsync(() async {
      expect(
        await state.importConfig(_localConfigJson, displayName: '本地'),
        isTrue,
      );
      final wanted = state.activeRecord!.id;
      // 干扰项：库里还有另一条本地配置，`is_active` 停在它身上。
      final decoy = state.database!.saveConfig(
        name: '别的本地配置',
        origin: 'https://other.example/sub.json',
        json: const {
          'sites': [
            {'key': 'other_site', 'name': '别的站点', 'type': 4, 'api': 'http://x'},
          ],
        },
        makeActive: false,
      );
      // 用户最后用的是 `wanted`：显式切换成功必须写记忆。
      expect(await state.activateConfigRecord(wanted), isTrue);
      final memory = LastConfigStore(dataDir: paths.dataDir).read();
      expect(memory?.recordId, wanted, reason: '显式切换必须写记忆');
      expect(memory?.isLocal, isTrue);
      expect(memory?.sourceKey, startsWith('local|'));
      // `is_active` 故意指向干扰项，让「按记忆」与「按 is_active」可区分。
      state.database!.activateConfig(decoy);
      return wanted;
    }) as int;

    final cold = await reopen(tester);
    final probesBefore = bridge.probeCalls;
    await mountShell(tester, cold);

    expect(bridge.probeCalls, probesBefore, reason: '本地源不得发起桥接探测');
    expect(
      cold.activeRecord?.id,
      restoredId,
      reason: '必须按记忆恢复，而不是按库里的 is_active',
    );
    expect(cold.selectedSite?.key, 'local_site');
    expect(
      find.byKey(const ValueKey('bridge-restore-banner')),
      findsNothing,
      reason: '本地源恢复不该出现桥接横幅',
    );
  });

  testWidgets('验收 3：桥接源可达时精确激活上次那条（不按 origin 挑最后一条）', (tester) async {
    await tester.runAsync(() async {
      final a = await saveBridgeSource('a', '源 A');
      final b = await saveBridgeSource('b', '源 B');
      // B 比 A 新（updated_at 更晚）：按 origin 挑「最后更新」会挑到 B。
      expect(b, isNot(a));
      expect(await state.activateConfigRecord(a), isTrue);
      expect(state.activeSourceKey, _bridgeSourceKey('a'));
      await seedDeviceHistory();
    });

    final cold = await reopen(tester);
    final probesBefore = bridge.probeCalls;
    await mountShell(tester, cold);

    expect(
      bridge.probeCalls,
      probesBefore + 1,
      reason: '桥接源必须只探测一次（不扫描、不轮询、不延时重试）',
    );
    expect(
      bridge.fetchedInterfaceKeys,
      ['a'],
      reason: '只重拉上次用的那个源，不重拉设备上的全部源',
    );
    expect(
      cold.activeSourceKey,
      _bridgeSourceKey('a'),
      reason: '同一设备两个源 origin 相同，只有 sourceKey 能区分上次用的是哪条',
    );
    expect(
      cold.database!.configBySourceKey(_bridgeSourceKey('b'))!.isActive,
      isFalse,
      reason: '不得把最后导入的那条（源 B）当成上次使用的配置',
    );
    expect(
      find.byKey(const ValueKey('bridge-restore-banner')),
      findsNothing,
      reason: '恢复成功时不该有横幅',
    );
  });

  testWidgets('验收 2b：导入即切换也更新记忆，重启不会换回旧的源', (tester) async {
    final expected = await tester.runAsync(() async {
      // 先有一条本地源并被记住。
      expect(
        await state.importConfig(_localConfigJson, displayName: '旧本地'),
        isTrue,
      );
      // 再导入一条（`makeActive: true` = 用户显式切到它），记忆必须跟着改。
      const second = '''
{
  "name": "新配置",
  "sites": [
    {
      "key": "new_site",
      "name": "新站点",
      "type": 4,
      "api": "http://127.0.0.1:19979/vod/api?key=new_site",
      "searchable": 1
    }
  ]
}
''';
      expect(await state.importConfig(second, displayName: '新本地'), isTrue);
      final active = state.activeRecord!;
      expect(active.name, '新本地');
      final memory = LastConfigStore(dataDir: paths.dataDir).read();
      expect(
        memory?.recordId,
        active.id,
        reason: '导入成功也是一次显式切换，不记的话重启会被旧记忆换回去',
      );
      return active.id;
    }) as int;

    final cold = await reopen(tester);
    await mountShell(tester, cold);

    expect(
      cold.activeRecord?.id,
      expected,
      reason: '重启后必须停在用户最后导入并使用的那条配置上',
    );
    expect(cold.selectedSite?.key, 'new_site');
  });

  testWidgets('验收 4a：桥接源不可达时横幅给出设备名/地址/失败分类', (tester) async {
    await tester.runAsync(() async {
      final a = await saveBridgeSource('a', '源 A');
      expect(await state.activateConfigRecord(a), isTrue);
      await seedDeviceHistory();
    });
    bridge.probeFailure = AppError(
      AppErrorKind.bridgeUnreachable,
      '安卓设备不可达：连接被拒绝或超时',
    );

    final cold = await reopen(tester);
    await mountShell(tester, cold);

    expect(
      find.byKey(const ValueKey('bridge-restore-banner')),
      findsOneWidget,
      reason: '探测失败必须给出非阻塞横幅，而不是静默回落',
    );
    final text = tester
        .widget<Text>(find.byKey(const ValueKey('bridge-restore-banner-text')))
        .data!;
    expect(text, contains('测试电视'), reason: '文案要给出设备名');
    expect(text, contains(_deviceBase), reason: '文案要给出地址');
    expect(
      text,
      contains('bridgeUnreachable'),
      reason: '失败分类必须原样呈现，不能折叠成一句「连不上」',
    );
    expect(
      cold.homeResult,
      isNotNull,
      reason: '横幅是非阻塞的：首页照常加载，用户仍可继续用当前配置',
    );
  });

  testWidgets('验收 4b：点「重试」才会再探测一次（不自动轮询）', (tester) async {
    await tester.runAsync(() async {
      final a = await saveBridgeSource('a', '源 A');
      expect(await state.activateConfigRecord(a), isTrue);
      await seedDeviceHistory();
    });
    bridge.probeFailure = AppError(AppErrorKind.bridgeUnreachable, '设备不在线');

    final cold = await reopen(tester);
    await mountShell(tester, cold);
    expect(find.byKey(const ValueKey('bridge-restore-banner')), findsOneWidget);
    final afterStartup = bridge.probeCalls;

    // 不做任何操作也不该再探测：只探一次。
    await _settle(tester, rounds: 10);
    expect(bridge.probeCalls, afterStartup, reason: '不得自动轮询/延时重试');

    // 用户点「重试」，这次设备回来了。
    bridge.probeFailure = null;
    await tester.tap(find.byKey(const ValueKey('bridge-restore-retry')));
    await _settle(tester);

    expect(
      bridge.probeCalls,
      greaterThan(afterStartup),
      reason: '「重试」必须真的再探一次',
    );
    expect(
      find.byKey(const ValueKey('bridge-restore-banner')),
      findsNothing,
      reason: '重试成功应撤掉横幅',
    );
    expect(cold.activeSourceKey, _bridgeSourceKey('a'));
  });

  testWidgets('验收 4c：点「切换播放源」唤起现有源选择器', (tester) async {
    await tester.runAsync(() async {
      final a = await saveBridgeSource('a', '源 A');
      expect(await state.activateConfigRecord(a), isTrue);
      await seedDeviceHistory();
    });
    bridge.probeFailure = AppError(AppErrorKind.bridgeUnreachable, '设备不在线');

    final cold = await reopen(tester);
    await mountShell(tester, cold);

    await tester.tap(
      find.byKey(const ValueKey('bridge-restore-switch-source')),
    );
    await _settle(tester, rounds: 6);

    expect(
      find.byType(SitePickerDialog),
      findsOneWidget,
      reason: '必须复用现有源选择器，而不是新造一个',
    );
  });

  testWidgets('验收 4d：关闭横幅后不再出现', (tester) async {
    await tester.runAsync(() async {
      final a = await saveBridgeSource('a', '源 A');
      expect(await state.activateConfigRecord(a), isTrue);
      await seedDeviceHistory();
    });
    bridge.probeFailure = AppError(AppErrorKind.bridgeUnreachable, '设备不在线');

    final cold = await reopen(tester);
    await mountShell(tester, cold);
    expect(find.byKey(const ValueKey('bridge-restore-banner')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bridge-restore-dismiss')));
    await _settle(tester, rounds: 4);
    expect(find.byKey(const ValueKey('bridge-restore-banner')), findsNothing);

    // 后续重建（状态通知）不能再把它弹回来。
    cold.notifyListeners();
    await _settle(tester, rounds: 4);
    expect(find.byKey(const ValueKey('bridge-restore-banner')), findsNothing);
  });

  testWidgets('验收 5：记忆指向已删除的记录时静默回落并留日志', (tester) async {
    await tester.runAsync(() async {
      expect(
        await state.importConfig(_localConfigJson, displayName: '本地'),
        isTrue,
      );
      final local = state.activeRecord!.id;
      final gone = await saveBridgeSource('gone', '已删源');
      expect(await state.activateConfigRecord(gone), isTrue);
      // 用户随后删掉了这条桥接配置；库里还留着本地配置作为当前配置。
      state.database!.deleteConfig(gone);
      state.database!.activateConfig(local);
      await seedDeviceHistory();
    });

    final cold = await reopen(tester);
    expect(
      cold.lastConfigRecord?.sourceKey,
      _bridgeSourceKey('gone'),
      reason: '用例前提：记忆仍指向那条已被删掉的记录',
    );
    expect(cold.lastConfigRecordAlive, isFalse);

    final before = log.entries.length;
    await mountShell(tester, cold);

    expect(
      find.byKey(const ValueKey('bridge-restore-banner')),
      findsNothing,
      reason: '记录被用户删掉不是故障，不该出现横幅',
    );
    expect(find.byType(SitePickerDialog), findsNothing, reason: '也不该弹任何对话框');
    final added = log.entries.skip(before).map((entry) => entry.line).join('\n');
    expect(
      added,
      contains('已不存在'),
      reason: '必须留一条日志说明为什么没恢复',
    );
    expect(cold.activeRecord?.name, '本地', reason: '静默回落当前配置，不改动它');
    expect(cold.homeResult, isNotNull, reason: '照旧加载首页');
  });
}
