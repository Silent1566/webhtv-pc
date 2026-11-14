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

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(state: state, startup: const StartupArguments()),
      ),
    );
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
    expect(find.byType(WebHomePage), findsOneWidget);
    expect(state.selectedSite, same(before));
    expect(state.selectedKeys, isEmpty);
    expect(state.homeKeys, isEmpty);
    expect(state.homeResult, isNull);
    expect(calls.map((call) => call.method), contains('initialize'));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(TextButton, Icons.dns_outlined));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SitePickerDialog),
        matching: find.text('普通源'),
      ),
    );
    await tester.pumpAndSettle();
    expect(state.selectedKeys, ['base']);
    expect(state.homeKeys, ['base']);
    expect(state.selectedSite?.key, 'base');
    expect(find.byType(WebHomePage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
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
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(SitePickerDialog),
        matching: find.text('普通源'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
