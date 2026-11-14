import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

import '../test/support/settings_navigation.dart';

const _wide = Size(1440, 900);
const _narrow = Size(480, 640);
const _userViewport = Size(1072, 728);
const _captureKey = ValueKey('settings-categories-capture');
const _categoryContent = <String, String>{
  'preferences': 'settings-theme-mode',
  'playback': 'settings-osd',
  'connections': 'settings-ai-open',
  'maintenance': 'settings-site-health-open',
};

class _Capture {
  const _Capture(this.category, this.brightness, this.size);

  final String category;
  final Brightness brightness;
  final Size size;

  String get viewport => size == _wide
      ? 'wide'
      : size == _userViewport
      ? 'user'
      : 'narrow';

  bool get useShell => size == _userViewport;

  String get name => '$category-${brightness.name}-$viewport';
}

final _matrix = <_Capture>[
  for (final category in _categoryContent.keys)
    for (final brightness in Brightness.values)
      _Capture(category, brightness, _wide),
  const _Capture('preferences', Brightness.dark, _narrow),
  const _Capture('connections', Brightness.light, _narrow),
  const _Capture('preferences', Brightness.dark, _userViewport),
  const _Capture('connections', Brightness.light, _userViewport),
];

class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _OfflineHttpClient();
}

class _OfflineHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter || invocation.memberName == #close) return null;
    throw StateError('分类截图禁止网络访问：${invocation.memberName}');
  }
}

Directory _repoRoot() {
  var directory = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    if (File('${directory.path}/apps/desktop-flutter/pubspec.yaml')
        .existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('无法定位分类截图输出仓库根目录');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final output = Directory(
    '${_repoRoot().path}/.local/settings-categories-visual',
  );
  final previousHttpOverrides = HttpOverrides.current;
  final previousLogDirectory = LogService.logDirectoryOverride;

  setUpAll(() {
    expect(Platform.isWindows, isTrue, reason: '仅协调者在 Windows 原生时段采集');
    expect(_matrix.length, 12);
    expect(_matrix.map((capture) => capture.name).toSet().length, 12);
    HttpOverrides.global = _OfflineHttpOverrides();
    output.createSync(recursive: true);
  });
  tearDownAll(() {
    HttpOverrides.global = previousHttpOverrides;
    LogService.logDirectoryOverride = previousLogDirectory;
  });

  for (final capture in _matrix) {
    testWidgets('分类主页面采集 ${capture.name}', (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'webhtv-categories-visual-',
      );
      var httpRequests = 0;
      final client = MockClient((request) async {
        httpRequests++;
        throw StateError('分类截图禁止 HTTP 请求：${request.url}');
      });
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      );
      final state = AppState(
        paths: paths,
        log: LogService(),
        httpClient: client,
        externalPlayerDetector: () => const [],
      );
      final semantics = tester.ensureSemantics();
      try {
        await tester.runAsync(state.bootstrap);
        expect(state.hasConfig, isFalse);
        expect(state.syncState.serverRunning, isFalse);
        if (capture.useShell) {
          await tester.runAsync(
            () => File('${paths.configDir}/usage-boundary-accepted')
                .writeAsString('settings-categories isolated accepted fixture'),
          );
        }
        tester.view.physicalSize = capture.size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: _captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildAppTheme(capture.brightness),
              home: capture.useShell
                  ? AppShell(state: state, startup: const StartupArguments())
                  : Scaffold(body: SettingsPage(state: state)),
            ),
          ),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 50),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
        if (capture.useShell) {
          // 与既有 TMDB 壳层回归相同：有界等待真实边界文件读取完成。
          for (var frame = 0; frame < 60; frame++) {
            if (find.byType(NavigationRail).evaluate().isNotEmpty) break;
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump();
          }
          expect(find.byType(AppShell), findsOneWidget);
          expect(find.byType(NavigationRail), findsOneWidget);
          expect(find.text('使用边界提示'), findsNothing);
          final settingsDestination = find.descendant(
            of: find.byType(NavigationRail),
            matching: find.text('设置'),
          );
          expect(settingsDestination, findsOneWidget);
          await tester.ensureVisible(settingsDestination);
          await tester.tap(settingsDestination);
          await tester.pumpAndSettle(
            const Duration(milliseconds: 50),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
        }
        expect(find.byType(SettingsPage), findsOneWidget);
        expect(
          find.byType(NavigationRail),
          capture.useShell ? findsOneWidget : findsNothing,
          reason: '仅真实主壳层提供一个 NavigationRail，分类不得再造第二个',
        );
        await selectSettingsCategory(tester, capture.category);
        for (final entry in _categoryContent.entries) {
          final control = find.byKey(
            ValueKey('settings-category-${entry.key}'),
          );
          expect(control, findsOneWidget);
          // Flutter 3.47 起 `hasFlag` 弃用，改读同一节点的 Tristate 语义集合。
          expect(
            tester.getSemantics(control).flagsCollection.isSelected ==
                ui.Tristate.isTrue,
            entry.key == capture.category,
            reason: '截图必须来自真实分类选中态：${capture.name}/${entry.key}',
          );
          expect(
            find.byKey(ValueKey('settings-category-content-${entry.key}')),
            entry.key == capture.category ? findsOneWidget : findsNothing,
            reason: '只能挂载当前分类单列内容区：${capture.name}/${entry.key}',
          );
          expect(
            find.byKey(ValueKey(entry.value)),
            entry.key == capture.category ? findsOneWidget : findsNothing,
            reason: '右侧正文只能显示当前分类：${capture.name}/${entry.key}',
          );
        }
        final selected = tester.getRect(
          find.byKey(ValueKey('settings-category-${capture.category}')),
        );
        final contentList = find.byKey(
          ValueKey('settings-category-content-${capture.category}'),
        );
        expect(
          tester.widget<ListView>(contentList).scrollDirection,
          Axis.vertical,
        );
        final content = tester.getRect(contentList);
        if (capture.useShell) {
          final rail = tester.getRect(find.byType(NavigationRail));
          final settingsPage = tester.getRect(find.byType(SettingsPage));
          expect(settingsPage.left, greaterThanOrEqualTo(rail.right));
          expect(settingsPage.top, greaterThan(0), reason: '保留真实顶栏占用高度');
          expect(settingsPage.width, lessThan(capture.size.width));
          expect(selected.left, greaterThanOrEqualTo(settingsPage.left));
          expect(content.width, greaterThan(selected.width));
          final field = tester.getRect(
            find.byKey(ValueKey(_categoryContent[capture.category]!)),
          );
          expect(field.left, greaterThanOrEqualTo(content.left));
          expect(field.right, lessThanOrEqualTo(content.right));
        }
        expect(selected.left, greaterThanOrEqualTo(0));
        expect(selected.right, lessThanOrEqualTo(capture.size.width));
        expect(selected.top, greaterThanOrEqualTo(0));
        expect(selected.bottom, lessThanOrEqualTo(capture.size.height));
        expect(content.left, greaterThanOrEqualTo(0));
        expect(content.right, lessThanOrEqualTo(capture.size.width));
        if (capture.size != _narrow) {
          expect(selected.right, lessThan(content.left));
        } else {
          expect(selected.bottom, lessThan(content.top));
        }
        expect(tester.takeException(), isNull, reason: capture.name);
        expect(httpRequests, 0);
        expect(state.syncState.serverRunning, isFalse);

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_captureKey),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          expect(image.width, capture.size.width.toInt());
          expect(image.height, capture.size.height.toInt());
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          expect(bytes, isNotNull);
          final file = File('${output.path}/${capture.name}.png');
          file.writeAsBytesSync(bytes!.buffer.asUint8List());
          File('${output.path}/${capture.name}.json').writeAsStringSync(
            jsonEncode({
              'category': capture.category,
              'selectedSemantics': true,
              'visibleContentKey': _categoryContent[capture.category],
              'theme': capture.brightness.name,
              'width': image.width,
              'height': image.height,
              'platform': Platform.operatingSystem,
              'scope': capture.useShell
                  ? 'AppShell'
                  : 'standalone SettingsPage',
              'settingsContentWidth': content.width,
              'navigationRailCount': find
                  .byType(NavigationRail)
                  .evaluate()
                  .length,
              'fixture': capture.useShell
                  ? 'fresh isolated AppPaths; accepted boundary marker; no config or network'
                  : 'fresh isolated AppPaths; no config or network',
              'httpRequests': httpRequests,
              'capture': 'native Flutter MaterialApp raster, real category tap',
              'source': 'integration_test/settings_categories_visual_test.dart',
            }),
          );
          debugPrint(
            'SETTINGS-CATEGORIES-EVIDENCE ${file.path} '
            '${image.width}x${image.height} selected=${capture.category} '
            'httpRequests=$httpRequests bytes=${bytes.lengthInBytes}',
          );
        } finally {
          image.dispose();
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        state.dispose();
        client.close();
        tester.view.reset();
        await tester.runAsync(() async => temp.delete(recursive: true));
      }
    });
  }
}
