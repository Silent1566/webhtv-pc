/// Phase 5 · 安卓接入与同步的设置页（`docs/phase5/design/02` §5）。
///
/// 对应门禁：`docs/phase5/README.md` §2.2 T8「设备卡片、扫描、导入、同步开关、
/// 错误分类展示」，以及 `design/03` §6.1 G10 要求的入口符号。
///
/// 两条测试环境约束（否则套件会莫名其妙地挂住）：
/// 1. 用注入的假桥接服务与回环测试端口 —— widget 测试**不得**做真实局域网 I/O；
/// 2. 真实文件/网络 I/O 必须放进 `tester.runAsync`：`testWidgets` 用的是假时钟，
///    真实 I/O 的完成回调不会被 `pumpAndSettle` 推进。
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
import 'package:webhtv_pc/services/android_bridge_service.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/sync_client.dart';
import 'package:webhtv_pc/services/sync_server.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';

/// 假桥接服务：不碰网络，行为由测试逐项设定。
class FakeBridge extends AndroidBridgeService {
  FakeBridge() : super(log: LogService());

  final AndroidDevice device = const AndroidDevice(
    uuid: 'fake-android-uuid',
    name: '测试安卓设备',
    reachableBase: 'http://192.168.50.9:9978',
    reportedIp: 'http://172.16.1.4:9978',
    type: 1,
  );

  AppError? probeFailure;
  AppError? fetchFailure;
  int siteCount = 3;
  List<BridgeHostRewrite> rewrites = const [];
  List<String> diagnostics = const [];
  int probeCalls = 0;
  int fetchCalls = 0;

  @override
  Future<AndroidDevice> probeDevice(String base) async {
    probeCalls++;
    final failure = probeFailure;
    if (failure != null) throw failure;
    return device;
  }

  @override
  Future<BridgeConversion> fetchGatewayConfig(
    String base, {
    String? selfBase,
    void Function(BridgeStage stage)? onStage,
  }) async {
    fetchCalls++;
    final failure = fetchFailure;
    if (failure != null) throw failure;
    onStage?.call(BridgeStage.converting);
    return BridgeConversion(
      config: AppConfig(
        name: '安卓桥接（fixture）',
        sites: [
          for (var index = 0; index < siteCount; index++)
            Site(
              key: 'csp_$index',
              name: '站点$index',
              type: SiteType.jsonApiBase64Ext,
              api: 'http://192.168.50.9:9978/$index',
            ),
        ],
      ),
      diagnostics: diagnostics,
      hostRewrites: rewrites,
    );
  }

  @override
  Future<List<AndroidDevice>> scan({
    void Function(AndroidDevice device)? onFound,
    void Function(int done, int total)? onProgress,
    Future<bool> Function()? shouldStop,
  }) async {
    onFound?.call(device);
    onProgress?.call(1, 1);
    return [device];
  }
}

/// 记录推送请求的假 HTTP 客户端。
class FakeHttpClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  String body = 'OK applied=2 skipped=1 failed=0 total=3';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
    );
  }
}

void main() {
  late Directory tempDir;
  late AppState state;
  late FakeBridge bridge;
  late FakeHttpClient httpClient;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-android-ui');
    bridge = FakeBridge();
    httpClient = FakeHttpClient();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
      ),
      log: LogService(),
      androidBridgeService: bridge,
      syncClient: SyncClient(log: LogService(), client: httpClient),
      // 固定到回环 + 测试端口区间：不占 9978，也不碰局域网。
      syncServerFactory: (host) => SyncServer(
        log: LogService(),
        host: host,
        bindAddress: '127.0.0.1',
        lanIpOverride: '127.0.0.1',
        startPort: 18700,
        endPort: 18710,
      ),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> openPage(WidgetTester tester) async {
    // 放大视口：页面是长 `ListView`，默认 800×600 下靠后的控件不会被构建，
    // `find.text` 会找不到"推送到设备"这类内容。
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: AndroidSettingsPage(state: state)),
    );
    await tester.pumpAndSettle();
  }

  /// 交替「推进一帧 → 给真实 I/O 一点时间」，直到 UI 收敛。
  ///
  /// 为什么不能只 `tap + pumpAndSettle`：`testWidgets` 的时钟是假的，
  /// 真实文件/网络 I/O 的完成回调不会被 `pumpAndSettle` 推进；而有些 I/O 又是在
  /// 弹窗关闭、下一帧之后才**开始**的（例如"开启服务端"要先关确认框）。
  /// 只给一次 `runAsync` 窗口会在这种情形下漏掉后续 I/O，测试就挂住。
  Future<void> settleIo(WidgetTester tester, {int rounds = 25}) async {
    for (var round = 0; round < rounds; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
    }
    await tester.pumpAndSettle();
  }

  /// 点一个会触发**真实 I/O** 的控件并等它落地。
  Future<void> tapIo(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await settleIo(tester);
  }

  /// 执行会触发真实 I/O 的状态操作（授权、开关、导入、推送）。
  Future<T> runIo<T>(WidgetTester tester, Future<T> Function() action) async {
    final result = await tester.runAsync(action);
    await settleIo(tester, rounds: 2);
    return result as T;
  }

  Future<void> addDevice(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('android-device-input')),
      '192.168.50.9:9978',
    );
    await tapIo(tester, find.text('接入设备'));
  }

  group('页面与默认值（design/02 §5）', () {
    testWidgets('页面标题与入口 key 存在（G10 符号）', (tester) async {
      await openPage(tester);
      expect(find.text('安卓设备接入'), findsOneWidget);
      expect(find.byKey(const ValueKey('android-bridge')), findsOneWidget);
      expect(find.text('扫描局域网'), findsOneWidget);
      expect(find.text('手动输入地址'), findsOneWidget);
      expect(find.text('同步设置'), findsOneWidget);
      expect(find.text('已授权对端'), findsOneWidget);
      expect(find.text('推送到设备'), findsNothing, reason: '无对端时不显示推送按钮');
    });

    testWidgets('三项开关默认全部关闭（P3）', (tester) async {
      await openPage(tester);
      final sync = state.syncState;
      expect(sync.serverEnabled, isFalse);
      expect(sync.pushEnabled, isFalse);
      expect(sync.settingsSyncEnabled, isFalse);
      expect(sync.serverRunning, isFalse);

      for (final key in const [
        'android-sync-server',
        'android-sync-push',
        'android-sync-settings',
      ]) {
        final tile = tester.widget<SwitchListTile>(find.byKey(ValueKey(key)));
        expect(tile.value, isFalse, reason: '$key 必须默认关闭');
      }
    });

    testWidgets('未开启推送时点"推送到设备"给出 syncDisabled 而不是假装成功', (tester) async {
      await openPage(tester);
      await runIo(tester, () => state.syncState.authorizePeer(bridge.device));

      await tapIo(tester, find.text('推送到设备'));

      expect(state.syncState.lastError?.kind, AppErrorKind.syncDisabled);
      expect(pageText(tester), contains('推送未开启'));
      expect(httpClient.requests, isEmpty, reason: '开关关闭时不得发请求');
    });
  });

  group('设备接入（design/01 §4 / §5）', () {
    testWidgets('手动输入地址 → 设备卡片出现且展示可达地址与脱敏标识', (tester) async {
      await openPage(tester);
      await addDevice(tester);

      expect(bridge.probeCalls, 1);
      expect(find.textContaining('测试安卓设备'), findsWidgets);
      expect(
        find.byKey(const ValueKey('android-device-fake-android-uuid')),
        findsOneWidget,
      );
      // 可达地址与设备自报地址必须分开显示（不是同一个值）。
      expect(pageText(tester), contains('http://192.168.50.9:9978'));
      expect(pageText(tester), contains('http://172.16.1.4:9978'));
      // 指纹脱敏：只出现前 4 位 + 掩码。
      expect(pageText(tester), contains('fake****'));
      expect(pageText(tester), isNot(contains('fake-android-uuid')));
    });

    testWidgets('扫描局域网 → 发现设备并写入列表', (tester) async {
      await openPage(tester);
      await tapIo(tester, find.byKey(const ValueKey('android-scan')));
      expect(state.syncState.devices, hasLength(1));
      expect(pageText(tester), contains('测试安卓设备'));
    });

    testWidgets('导入站点 → 新建配置记录且不切换当前配置（Q10）', (tester) async {
      await openPage(tester);
      await addDevice(tester);

      final before = state.database!.activeConfig();
      await tapIo(tester, find.byKey(const ValueKey('android-import')));

      expect(bridge.fetchCalls, 1);
      final records = state.database!.listConfigs();
      expect(records, hasLength(1), reason: '导入应产生一条新配置记录');
      expect(records.first.origin, 'http://192.168.50.9:9978');
      expect(records.first.siteCount, 3);
      expect(
        state.database!.activeConfig()?.id,
        before?.id,
        reason: '导入不得切换当前配置（Q10）',
      );
      // 接入过的设备自动进入白名单。
      expect(state.syncState.peers, hasLength(1));
      expect(state.syncState.lastOperation, contains('bridge-import'));
    });

    testWidgets('主机修正必须用户可见（P2 + G10 的 bridge-host- 符号）', (tester) async {
      bridge.rewrites = const [
        BridgeHostRewrite(
          siteKey: 'csp_0',
          from: '127.0.0.1:9978',
          to: '192.168.50.9:9978',
        ),
      ];
      bridge.diagnostics = const ['已修正 1 个站点地址的主机'];
      await openPage(tester);
      await addDevice(tester);
      await tapIo(tester, find.byKey(const ValueKey('android-import')));

      expect(find.text('站点地址已修正'), findsOneWidget);
      expect(find.byKey(const ValueKey('bridge-host-csp_0')), findsOneWidget);
      expect(pageText(tester), contains('127.0.0.1:9978 → 192.168.50.9:9978'));
    });
  });

  group('错误分类展示（P5）', () {
    testWidgets('bridgeEmptySites 明确报错，不显示"0 个站点导入成功"', (tester) async {
      bridge.fetchFailure = AppError(
        AppErrorKind.bridgeEmptySites,
        '安卓设备上尚未加载任何点播配置，没有可导入的站点',
      );
      await openPage(tester);
      await addDevice(tester);
      await tapIo(tester, find.byKey(const ValueKey('android-import')));

      expect(state.syncState.lastError?.kind, AppErrorKind.bridgeEmptySites);
      expect(find.byKey(const ValueKey('android-error')), findsOneWidget);
      expect(pageText(tester), contains('bridgeEmptySites'));
      expect(state.database!.listConfigs(), isEmpty, reason: '失败不得留下半成品记录');
    });

    testWidgets('bridgeHostMismatch 拒绝导入并给出类别', (tester) async {
      bridge.fetchFailure = AppError(
        AppErrorKind.bridgeHostMismatch,
        '安卓返回的站点地址不属于该设备，已拒绝导入',
      );
      await openPage(tester);
      await addDevice(tester);
      await tapIo(tester, find.byKey(const ValueKey('android-import')));

      expect(state.syncState.lastError?.kind, AppErrorKind.bridgeHostMismatch);
      expect(pageText(tester), contains('bridgeHostMismatch'));
      expect(pageText(tester), contains('不属于该设备'));
    });

    testWidgets('bridgeNotAndroid 探测失败时给出类别', (tester) async {
      bridge.probeFailure = AppError(
        AppErrorKind.bridgeNotAndroid,
        '该地址不是 WebHTV 安卓服务',
      );
      await openPage(tester);
      await addDevice(tester);

      expect(state.syncState.lastError?.kind, AppErrorKind.bridgeNotAndroid);
      expect(pageText(tester), contains('bridgeNotAndroid'));
      expect(pageText(tester), contains('不是 WebHTV 安卓服务'));
    });
  });

  group('同步开关与推送（design/02 §5 / §3.2）', () {
    testWidgets('开启服务端需二次确认，提示必须说明监听范围与可关闭', (tester) async {
      await openPage(tester);
      await tester.tap(find.byKey(const ValueKey('android-sync-server')));
      await tester.pumpAndSettle();

      expect(find.text('开启局域网同步服务'), findsOneWidget);
      final hint = pageText(tester);
      expect(hint, contains('同局域网设备可访问'));
      expect(hint, contains('仅接受'));

      await tapIo(tester, find.text('开启'));
      expect(state.syncState.serverEnabled, isTrue);
      expect(state.syncState.serverRunning, isTrue);
      expect(state.syncState.serverPort, 18700);

      // 关闭后端口立即释放。
      await tapIo(tester, find.byKey(const ValueKey('android-sync-server')));
      expect(state.syncState.serverEnabled, isFalse);
      expect(state.syncState.serverRunning, isFalse);
    });

    testWidgets('授权对端后展示 sync-peer- key 与"已授权对端"标题', (tester) async {
      await openPage(tester);
      expect(find.text('已授权对端'), findsOneWidget);
      await runIo(tester, () => state.syncState.authorizePeer(bridge.device));

      expect(
        find.byKey(const ValueKey('sync-peer-fake-android-uuid')),
        findsOneWidget,
      );
      // 对端 IP 也进入白名单：安卓推送历史不带 uuid（见 SyncState.isPeerAuthorized）。
      expect(state.syncState.isPeerAuthorized('192.168.50.9'), isTrue);
      expect(state.syncState.isPeerAuthorized('10.0.0.1'), isFalse);
      expect(state.syncState.isPeerAuthorized('fake-android-uuid'), isTrue);
    });

    testWidgets('推送前必须能给出与安卓一致的 config，否则拒绝发送', (tester) async {
      await openPage(tester);
      await runIo(tester, () => state.syncState.authorizePeer(bridge.device));
      await runIo(tester, () => state.syncState.setPushEnabled(true));
      state.database!.upsertHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        vodName: '示例剧集',
        flag: '线路一',
        episodeName: '第2集',
        episodeId: 'http://h/ep-1.m3u8',
        positionMs: 754000,
        durationMs: 2700000,
        updatedAt: 1791450000000,
      );

      // 生效配置的 origin 与对端不一致 → 拒绝发送（防"静默无操作仍返回成功"）。
      await tapIo(tester, find.text('推送到设备'));
      expect(state.syncState.lastError?.kind, AppErrorKind.syncPayloadInvalid);
      expect(httpClient.requests, isEmpty);
      expect(pageText(tester), contains('config.url'));

      // origin 就是该对端地址后，推送发出且带上明细。
      // 必须走 `activateConfigRecord`：`syncConfigJson()` 读的是 AppState 里的
      // 生效记录，直接写库不会刷新它（这正是"推送前要选对配置"的用户动作）。
      final recordId = state.database!.saveConfig(
        name: '安卓桥接',
        origin: 'http://192.168.50.9:9978',
        json: const {'sites': <Object?>[]},
        makeActive: false,
      );
      await runIo(tester, () => state.activateConfigRecord(recordId));
      await tapIo(tester, find.text('推送到设备'));

      expect(httpClient.requests, hasLength(1));
      final request = httpClient.requests.single;
      expect(request.url.queryParameters['mode'], '1');
      expect(request.url.queryParameters['type'], 'history');
      expect(request.url.queryParameters['do'], 'sync');
      expect(state.syncState.lastStats?.applied, 2);
      expect(pageText(tester), contains('applied=2'));
    });
  });

  group('设置页入口可达性（发布包反馈回归）', () {
    // 背景（真实用户反馈）：安卓接入入口原先挂在 `TmdbSettingsPage` 底部，
    // 用户要先点「打开 TMDB 设置」再滚到底才能看到，于是以为"正式版没编进去"。
    //
    // 为什么既有门禁发现不了：`verify_release_symbols.py` 只断言符号存在于
    // app.so（确实存在，类被保留了），断言不了"运行时能不能点到"；
    // 而 widget 用例此前只测了 `AndroidSettingsPage` 自身，没测它怎么被进入。
    //
    // 本用例断言：设置页**一层**即可见安卓入口，且点击真正进入接入页。
    testWidgets('设置页无条件可见「打开安卓接入」，点击进入接入页', (tester) async {
      tester.view.physicalSize = const Size(1400, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SettingsPage(state: state))),
      );
      await tester.pumpAndSettle();

      final entry = find.byKey(const ValueKey('settings-android-open'));
      expect(
        entry,
        findsOneWidget,
        reason: '设置页必须有安卓接入入口（不得再嵌套进 TMDB 设置页）',
      );
      expect(find.text('安卓接入'), findsWidgets);
      expect(
        find.byKey(const ValueKey('settings-android-summary')),
        findsOneWidget,
        reason: '入口旁应有状态摘要（未接入/已接入 N 台）',
      );

      await tester.tap(entry);
      await tester.pumpAndSettle();

      // 真正进入接入页：断言页内特征控件，而非仅断言路由类型。
      expect(find.text('安卓设备接入'), findsOneWidget);
      expect(find.byKey(const ValueKey('android-bridge')), findsOneWidget);
      expect(find.byKey(const ValueKey('android-scan')), findsOneWidget);
      expect(find.byKey(const ValueKey('android-sync-server')), findsOneWidget);
    });

    testWidgets('入口与 TMDB 解耦：未配置 TMDB 也可见', (tester) async {
      expect(state.tmdbConfig.isReady, isFalse, reason: '前置条件：未配置 TMDB');
      tester.view.physicalSize = const Size(1400, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SettingsPage(state: state))),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings-android-open')), findsOneWidget);
      expect(
        pageText(tester),
        contains('未接入'),
        reason: '未接入设备时摘要应说明可扫描或手动输入',
      );
    });
  });

  group('设置持久化（design/02 §8 Q5）', () {
    testWidgets('uuid 持久化：重启后仍是同一台设备', (tester) async {
      await openPage(tester);
      final first = state.syncState.deviceUuid;
      expect(first, hasLength(32));
      await runIo(tester, () => state.syncState.setPushEnabled(true));

      final section =
          (jsonDecode(File(state.paths.settingsPath).readAsStringSync())
                  as Map<String, Object?>)
              .let((root) => (root['sync'] as Map).cast<String, Object?>());
      expect(section['deviceUuid'], first);
      expect(section['pushEnabled'], isTrue);
      expect(section['serverEnabled'], isFalse);
      expect((section['peers'] as List?)?.length, 0);

      // 重新打开一份 state，读回同一 uuid 与开关。
      late AppState reopened;
      await tester.runAsync(() async {
        reopened = AppState(
          paths: AppPaths.resolve(
            overrides: {'roaming': tempDir.path, 'local': tempDir.path},
          ),
          log: LogService(),
          androidBridgeService: bridge,
        );
        await reopened.bootstrap();
      });
      expect(reopened.syncState.deviceUuid, first);
      expect(reopened.syncState.pushEnabled, isTrue);
      expect(reopened.syncState.serverEnabled, isFalse);
      reopened.dispose();
    });
  });
}

/// 页面可见文本（用于不依赖具体 widget 类型的断言）。
String pageText(WidgetTester tester) {
  final buffer = StringBuffer();
  for (final element in tester.allWidgets) {
    if (element is Text && element.data != null) buffer.writeln(element.data);
    if (element is SelectableText && element.data != null) {
      buffer.writeln(element.data);
    }
  }
  return buffer.toString();
}

extension<T> on T {
  R let<R>(R Function(T value) body) => body(this);
}
