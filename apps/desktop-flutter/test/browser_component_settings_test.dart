import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/sniff/sniff_transport.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/browser_component_store.dart';
import 'package:webhtv_pc/services/sniff_runtime.dart';
import 'package:webhtv_pc/ui/browser_component_settings.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/advanced_settings_page.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/services/log_service.dart';

class FakeTransport extends SniffTransport {
  FakeTransport(this.commands, {this.issues = const {}});
  final List<BrowserCommand> commands;
  final Map<String, String> issues;
  int locateCalls = 0;
  int probeCalls = 0;
  @override
  Future<List<BrowserCommand>> locateAll({String? override}) async {
    locateCalls++;
    return commands;
  }

  @override
  Future<BrowserCommand?> locate({String? override}) async =>
      commands.isEmpty ? null : commands.first;
  @override
  Future<String?> probe(BrowserCommand command) async {
    probeCalls++;
    return issues[command.label];
  }

  @override
  Future<BrowserSession> launch(
    BrowserCommand command, {
    bool headless = true,
    Duration readyTimeout = const Duration(seconds: 20),
    int? width,
    int? height,
  }) => throw UnimplementedError();
  @override
  Future<CdpConnection> connect(
    Uri webSocketUrl, {
    Duration timeout = const Duration(seconds: 10),
  }) => throw UnimplementedError();
}

class TrackingStore extends BrowserComponentStore {
  TrackingStore({required super.rootDirectory});
  final List<String> uninstalled = [];
  final List<String> validated = [];
  String? validationIssue;
  @override
  Future<void> uninstall(BrowserComponent component) async {
    uninstalled.add(component.id);
    // Widget 测试只验证确认与刷新，同步假删除避免真实 IO 跨 FakeAsync zone。
    Directory(component.directory).deleteSync(recursive: true);
  }

  @override
  Future<String?> validate(BrowserComponent component) async {
    validated.add(component.id);
    return validationIssue;
  }
}

void main() {
  late Directory temp;
  late AppPaths paths;
  late TrackingStore store;

  setUp(() {
    resetSniffBrowserStatus();
    temp = Directory.systemTemp.createTempSync('webhtv-browser-settings-');
    paths = AppPaths.resolve(
      overrides: {
        'config': temp.path,
        'data': temp.path,
        'cache': temp.path,
        'state': temp.path,
      },
    );
    store = TrackingStore(rootDirectory: '${temp.path}/components/browser');
  });
  tearDown(() {
    resetSniffBrowserStatus();
    temp.deleteSync(recursive: true);
  });

  void manifest() {
    final directory = Directory('${store.rootDirectory}/chrome-154')
      ..createSync(recursive: true);
    File('${directory.path}/chrome')
        .writeAsStringSync('#!/bin/sh\necho Chrome 154.0\n');
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['+x', '${directory.path}/chrome']);
    }
    File('${directory.path}/component.json').writeAsStringSync(
      jsonEncode({
        'id': 'chrome-154',
        'label': 'Google Chrome',
        'version': '154.0.8037.0',
        'executable': 'chrome',
        'source': '/portable/chrome',
      }),
    );
  }

  Future<void> mount(WidgetTester tester, FakeTransport transport) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: BrowserComponentSettingsSection(
                  paths: paths,
                  store: store,
                  transport: transport,
                  versionReader: (_) async => 'Google Chrome 154.0.8037.0',
                ),
              ),
            ),
          ),
        ),
      );
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('browser-component-refresh')));
    await tester.pumpAndSettle();
  }

  testWidgets('尚未检测的首帧只读取快照，不定位或探测浏览器', (tester) async {
    final transport = FakeTransport([]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserComponentSettingsSection(
            paths: paths,
            store: store,
            transport: transport,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('尚未检测系统浏览器'), findsOneWidget);
    expect(find.text('检测'), findsOneWidget);
    expect(transport.locateCalls, 0);
    expect(transport.probeCalls, 0);
    await tester.tap(find.byKey(const ValueKey('browser-component-refresh')));
    await tester.pumpAndSettle();
    expect(transport.locateCalls, 1);
    expect(
      find.byKey(const ValueKey('browser-component-system-unavailable')),
      findsOneWidget,
    );
  });

  testWidgets('空组件且没有系统浏览器时说明如何安装与无需重启', (tester) async {
    await mount(tester, FakeTransport([]));
    expect(
      find.textContaining('需要 Chromium 内核浏览器：安装后可直接点播放，无需重启'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('browser-component-system-unavailable')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('browser-component-install-directory')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('browser-component-install-zip')),
      findsOneWidget,
    );
  });

  testWidgets('有可用系统浏览器显示成功态、名称与版本', (tester) async {
    await mount(
      tester,
      FakeTransport(const [
        BrowserCommand(executablePath: '/fake/chrome', label: 'Google Chrome'),
      ]),
    );
    expect(
      find.byKey(const ValueKey('browser-component-system-available')),
      findsOneWidget,
    );
    expect(find.textContaining('Google Chrome 154.0.8037.0'), findsOneWidget);
    expect(find.byKey(const ValueKey('browser-component-empty')), findsNothing);
  });

  testWidgets('全部系统候选不可用时保留每一个探测原因', (tester) async {
    await mount(
      tester,
      FakeTransport(
        const [
          BrowserCommand(executablePath: '/fake/chrome', label: 'Chrome'),
          BrowserCommand(executablePath: '/fake/edge', label: 'Edge'),
        ],
        issues: {'Chrome': 'snap-confine 权限不足', 'Edge': '架构不匹配'},
      ),
    );
    expect(find.text('/fake/chrome：snap-confine 权限不足'), findsOneWidget);
    expect(find.text('/fake/edge：架构不匹配'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('browser-component-system-unavailable')),
      findsOneWidget,
    );
  });

  testWidgets('manifest 组件显示名称、原始来源与重新校验结果', (tester) async {
    manifest();
    await mount(tester, FakeTransport([]));
    expect(find.text('Google Chrome 154.0.8037.0'), findsOneWidget);
    expect(find.text('来源：/portable/chrome'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('browser-component-revalidate-chrome-154')),
    );
    await tester.pumpAndSettle();
    expect(store.validated, ['chrome-154']);
    expect(find.text('可用'), findsOneWidget);
    store.validationIssue = '可执行文件权限不足';
    await tester.tap(
      find.byKey(const ValueKey('browser-component-revalidate-chrome-154')),
    );
    await tester.pumpAndSettle();
    expect(find.text('可执行文件权限不足'), findsOneWidget);
  });

  testWidgets('卸载必须二次确认，取消不删除，确认后调用 store 并刷新', (tester) async {
    manifest();
    await mount(tester, FakeTransport([]));
    final uninstall = find.byKey(
      const ValueKey('browser-component-uninstall-chrome-154'),
    );
    await tester.tap(uninstall);
    await tester.pumpAndSettle();
    expect(store.uninstalled, isEmpty);
    expect(
      find.byKey(const ValueKey('browser-component-uninstall-confirm')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('browser-component-uninstall-cancel')),
    );
    await tester.pumpAndSettle();
    expect(store.uninstalled, isEmpty);
    await tester.tap(uninstall);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey('browser-component-uninstall-confirm-ok')),
      );
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(store.uninstalled, ['chrome-154']);
    expect(
      find.byKey(const ValueKey('browser-component-row-chrome-154')),
      findsNothing,
    );
    expect(
      Directory('${store.rootDirectory}/chrome-154').existsSync(),
      isFalse,
    );
  });

  testWidgets('高级设置页末视觉快照', (tester) async {
    final target = Platform.environment['BROWSER_COMPONENT_CAPTURE'];
    if (target == null) return;
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(paths: paths, log: LogService());
    addTearDown(state.dispose);
    final boundary = GlobalKey();
    await tester.runAsync(() async {
      final font = ByteData.sublistView(
        await File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')
            .readAsBytes(),
      );
      // 测试引擎默认 Ahem 无中文字形；注册到既有字体族，不改变应用主题。
      for (final family in [
        'Roboto',
        'Microsoft YaHei UI',
        'Noto Sans CJK SC',
      ]) {
        final loader = FontLoader(family)..addFont(Future.value(font));
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        );
      await icons.load();
      await state.bootstrap();
      final theme = buildAppTheme(Brightness.dark);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: RepaintBoundary(
            key: boundary,
            child: AdvancedSettingsPage(state: state),
          ),
        ),
      );
    });
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(target).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }, skip: Platform.environment['BROWSER_COMPONENT_CAPTURE'] == null);
}
