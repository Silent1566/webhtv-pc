import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/web_home_page.dart';

import 'local_source_sites_test.dart' show tempPaths, writeCandidates, join;

class _RecordingState extends AppState {
  _RecordingState(Directory temp)
    : super(paths: tempPaths(temp), log: LogService());
  final selectedKeys = <String>[];
  final homeKeys = <String>[];

  @override
  Future<void> selectSite(Site site) async {
    selectedKeys.add(site.key);
    await super.selectSite(site);
  }

  @override
  Future<void> loadHome(Site site) async {
    homeKeys.add(site.key);
  }
}

void main() {
  late Directory temp;
  late _RecordingState state;
  const plugin = MethodChannel('io.jns.webview.win');
  const controller = MethodChannel('io.jns.webview.win/71');
  const events = MethodChannel('io.jns.webview.win/71/events');
  final calls = <MethodCall>[];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv_local_shell_');
    LogService.logDirectoryOverride = join(temp, 'logs');
    state = _RecordingState(temp);
    File(
      join(
        Directory(state.paths.configDir)..createSync(recursive: true),
        'usage-boundary-accepted',
      ),
    ).writeAsStringSync('ok');
    calls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return {'textureId': 71};
      return null;
    });
    messenger.setMockMethodCallHandler(controller, (call) async {
      if (call.method != 'setSize') calls.add(call);
      if (call.method == 'addScriptToExecuteOnDocumentCreated') return 'bridge';
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });

  tearDown(() async {
    // 导入 Python 源会触发后台专用环境准备；等它完成后目录才不再被占用。
    await state.pythonEnvironmentIdle;
    state.dispose();
    for (final channel in [plugin, controller, events]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// 推进假时钟直到没有帧在排队，每一轮先放行一次真实事件循环。
  ///
  /// 为什么不能直接 `pumpAndSettle`：`AppShell` 在 `usage-boundary-accepted` 的
  /// `File.exists()`（真实 dart:io）返回前渲染 `LoadingBlock`——一个无限
  /// `CircularProgressIndicator`，每帧都会再排一帧。假时钟推不动真实 IO
  /// （`binding.pump` 只 flush 假微任务，不回到事件循环），于是
  /// `pumpAndSettle` 唯一的出口「`hasScheduledFrame == false`」在慢机器上永远
  /// 到不了：CI run 44441281049 就是这样在 6000 次 pump 后抛
  /// `pumpAndSettle timed out`。
  ///
  /// 收敛判据与 `pumpAndSettle` 完全相同（没有帧在排队），只是每轮多给真实
  /// 事件循环一次机会；真出现无限动画照样失败，窗口还从 10 分钟假时钟收紧到
  /// 30 秒真实时间，且失败信息说明是「真实 IO 没落地 / 有无限动画」。
  Future<void> settle(WidgetTester tester) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (!tester.binding.hasScheduledFrame) return;
      if (DateTime.now().isAfter(deadline)) {
        fail('30s 真实时间内仍在排帧：真实 IO 未落地或存在无限动画');
      }
    }
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(state: state, startup: const StartupArguments()),
      ),
    );
    await settle(tester);
  }

  testWidgets('真实AppShell picker打开HTML宿主，不选站点也不loadHome，普通站点仍selectSite', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await state.importConfig(
        '{"sites":[{"key":"base","name":"普通源","type":1,"api":"http://example.com/api"}]}',
      );
      final report = await state.scanLocalSources(writeCandidates(temp).path);
      await state.importLocalSources(report.candidates);
    });
    await mount(tester);
    final before = state.selectedSite;
    state.selectedKeys.clear();
    state.homeKeys.clear();
    await tester.tap(find.widgetWithIcon(TextButton, Icons.dns_outlined));
    await settle(tester);
    expect(find.byType(SitePickerDialog), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(SitePickerDialog),
        matching: find.text('c'),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    tester.binding.channelBuffers.push(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'loadingStateChanged',
        'value': 2,
      }),
      (_) {},
    );
    await settle(tester);
    expect(find.byType(WebHomePage), findsOneWidget);
    expect(state.selectedSite, same(before));
    expect(state.selectedKeys, isEmpty);
    expect(state.homeKeys, isEmpty);
    expect(state.homeResult, isNull);
    expect(calls.map((call) => call.method), contains('initialize'));
    await tester.tap(find.byType(BackButton));
    await settle(tester);
    await tester.tap(find.widgetWithIcon(TextButton, Icons.dns_outlined));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(SitePickerDialog),
        matching: find.text('普通源'),
      ),
    );
    await settle(tester);
    expect(state.selectedKeys, ['base']);
    expect(state.homeKeys, ['base']);
    expect(state.selectedSite?.key, 'base');
    expect(find.byType(WebHomePage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('坏HTML登记表主外壳不红屏，展示失败原因且普通站点仍可选', (tester) async {
    await tester.runAsync(() async {
      await state.importConfig(
        '{"sites":[{"key":"base","name":"普通源","type":1,"api":"http://example.com/api"}]}',
      );
      final registry = File(
        join(
          Directory(join(Directory(state.paths.configDir), 'webhome'))
            ..createSync(recursive: true),
          'registry.json',
        ),
      );
      registry.writeAsStringSync('{broken');
      await state.reloadLocalSources();
    });
    await mount(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('webhome-load-error')), findsOneWidget);
    expect(find.textContaining('载入HTML源失败'), findsWidgets);
    expect(
      tester
          .widget<Tooltip>(find.byKey(const ValueKey('webhome-load-error')))
          .message,
      contains('FormatException'),
    );
    await tester.tap(find.widgetWithIcon(TextButton, Icons.dns_outlined));
    await settle(tester);
    expect(
      find.descendant(
        of: find.byType(SitePickerDialog),
        matching: find.text('普通源'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });
}
