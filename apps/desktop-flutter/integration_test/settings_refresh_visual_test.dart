import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/advanced_settings_page.dart';
import 'package:webhtv_pc/ui/ai_assist_page.dart';
import 'package:webhtv_pc/ui/ai_settings_page.dart';
import 'package:webhtv_pc/ui/backup_page.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/injected_sites_page.dart';
import 'package:webhtv_pc/ui/pan_check_page.dart';
import 'package:webhtv_pc/ui/player_button_config_page.dart';
import 'package:webhtv_pc/ui/subtitle_settings_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import '../test/support/settings_navigation.dart';

// 首轮固定 17 个文件；第二轮只覆盖相同路径，不扩张矩阵。
const _wide = Size(1440, 900);
const _narrow = Size(1024, 640);
const _captureKey = ValueKey('settings-refresh-capture');

class _Capture {
  const _Capture(this.page, this.brightness, this.size);

  final String page;
  final Brightness brightness;
  final Size size;

  String get name =>
      '$page-${brightness.name}-${size == _wide ? 'wide' : 'narrow'}';
}

const _pages = [
  'settings',
  'tmdb',
  'android',
  'ai',
  'advanced',
  'subtitle',
  'buttons',
  'backup',
  'injected',
  'pan',
  'ai-assist',
  'health',
];
final _matrix = <_Capture>[
  for (final page in _pages) _Capture(page, Brightness.dark, _wide),
  const _Capture('settings', Brightness.light, _wide),
  const _Capture('settings', Brightness.dark, _narrow),
  const _Capture('settings', Brightness.light, _narrow),
  const _Capture('tmdb', Brightness.light, _narrow),
  const _Capture('ai', Brightness.light, _narrow),
];

class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _OfflineHttpClient();
}

class _OfflineHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter || invocation.memberName == #close) return null;
    throw StateError('截图测试禁止网络访问：${invocation.memberName}');
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
  throw StateError('无法定位截图输出仓库根目录');
}

Widget _page(String id, AppState state) => switch (id) {
  'settings' => Scaffold(body: SettingsPage(state: state)),
  'tmdb' => TmdbSettingsPage(state: state),
  'android' => AndroidSettingsPage(state: state),
  'ai' => AiSettingsPage(state: state),
  'advanced' => AdvancedSettingsPage(state: state),
  'subtitle' => SubtitleSettingsPage(state: state, paths: state.paths),
  'buttons' => PlayerButtonConfigPage(state: state),
  'backup' => BackupPage(state: state),
  'injected' => InjectedSitesPage(state: state),
  'pan' => PanCheckPage(state: state),
  'ai-assist' => AiAssistPage(state: state),
  'health' => SiteHealthPage(state: state),
  _ => throw ArgumentError.value(id),
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final output = Directory('${_repoRoot().path}/.local/settings-A-visual');
  final previousHttpOverrides = HttpOverrides.current;
  final previousLogDirectory = LogService.logDirectoryOverride;
  setUpAll(() {
    expect(_matrix.length, 17);
    expect(_matrix.map((capture) => capture.name).toSet().length, 17);
    HttpOverrides.global = _OfflineHttpOverrides();
    output.createSync(recursive: true);
  });
  tearDownAll(() {
    HttpOverrides.global = previousHttpOverrides;
    LogService.logDirectoryOverride = previousLogDirectory;
  });

  testWidgets('AI 保存完成反馈与实际落盘一致（无截图）', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-ai-save-native-');
    var httpRequests = 0;
    final client = MockClient((request) async {
      httpRequests++;
      throw StateError('保存取证禁止 HTTP 请求：${request.url}');
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
    const expected = AiConfig(
      enabled: true,
      protocol: AiProtocol.defaultProtocol,
      endpoint: 'http://127.0.0.1:1/v1/responses',
      apiKey: 'fixture-local-key',
      model: 'fixture-save-model',
      customUserAgent: 'settings-native-fixture',
    );
    final saved = Completer<void>();
    void onSaved() {
      // saveAiConfig 只在 store 写盘 Future 完成后 notifyListeners。
      if (!saved.isCompleted &&
          mapEquals(state.aiConfig.toJson(), expected.toJson())) {
        saved.complete();
      }
    }

    try {
      await tester.runAsync(state.bootstrap);
      expect(state.hasConfig, isFalse);
      expect(state.syncState.serverRunning, isFalse);
      expect(state.aiConfig.enabled, isFalse);
      tester.view.physicalSize = _wide;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(body: SettingsPage(state: state)),
        ),
      );
      await tester.pump();
      await selectSettingsCategory(tester, 'connections');
      await tester.tap(find.byKey(const ValueKey('settings-ai-open')));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(find.byKey(const ValueKey('ai-settings-page')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-enabled')));
      for (final entry in {
        'ai-endpoint': ' ${expected.endpoint} ',
        'ai-model': ' ${expected.model} ',
        'ai-api-key': ' ${expected.apiKey} ',
        'ai-user-agent': ' ${expected.customUserAgent} ',
      }.entries) {
        final field = find.byKey(ValueKey(entry.key));
        await tester.ensureVisible(field);
        await tester.pump();
        await tester.enterText(field, entry.value);
      }
      expect(state.aiConfig.enabled, isFalse, reason: '填写草稿不能提前保存');
      expect(state.aiConfig.model, isNot(expected.model));
      final saveButton = find.byKey(const ValueKey('ai-save'));
      await tester.ensureVisible(saveButton);
      await tester.pump();
      state.addListener(onSaved);
      await tester.tap(saveButton);
      // 等待真实业务完成通知，不按帧/固定延迟轮询；超时直接报错。
      await tester.runAsync(
        () => saved.future.timeout(const Duration(seconds: 5)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('ai-settings-status')))
            .data,
        '已保存',
      );
      expect(state.aiConfig.toJson(), expected.toJson());
      final persisted = await tester.runAsync(() async {
        final root =
            jsonDecode(await File(paths.settingsPath).readAsString()) as Map;
        return root['ai'];
      });
      expect(persisted, expected.toJson(), reason: '成功提示必须对应实际磁盘值');
      expect(httpRequests, 0);
      expect(state.syncState.serverRunning, isFalse);
      debugPrint(
        'SETTINGS-REFRESH-EVIDENCE ai-save status=已保存 '
        'memory=matched disk=matched httpRequests=$httpRequests png=0',
      );
    } finally {
      state.removeListener(onSaved);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      client.close();
      tester.view.reset();
      await tester.runAsync(() async => temp.delete(recursive: true));
    }
  });

  for (final capture in _matrix) {
    testWidgets('采集 ${capture.name}', (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'webhtv-settings-visual-',
      );
      final client = MockClient((request) async {
        throw StateError('截图测试禁止 HTTP 请求：${request.url}');
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
      try {
        await tester.runAsync(state.bootstrap);
        // 不导入配置、不启服务器、不点击“扫描/测试/保存”等业务动作。
        expect(state.hasConfig, isFalse);
        expect(state.syncState.serverRunning, isFalse);
        tester.view.physicalSize = capture.size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: _captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildAppTheme(capture.brightness),
              initialRoute: '/capture',
              routes: {
                '/': (_) => const Scaffold(),
                '/capture': (_) => ListenableBuilder(
                  listenable: state,
                  builder: (_, _) => _page(capture.page, state),
                ),
              },
            ),
          ),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 50),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
        expect(tester.takeException(), isNull, reason: capture.name);
        if (capture.page != 'settings') {
          expect(find.byType(AppBar), findsOneWidget);
          expect(find.byType(BackButton), findsOneWidget);
        }
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_captureKey),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          expect(bytes, isNotNull);
          final file = File('${output.path}/${capture.name}.png');
          file.writeAsBytesSync(bytes!.buffer.asUint8List());
          File('${output.path}/${capture.name}.json').writeAsStringSync(
            jsonEncode({
              'page': capture.page,
              'theme': capture.brightness.name,
              'width': image.width,
              'height': image.height,
              'platform': Platform.operatingSystem,
              'fixture': 'fresh isolated state; no config or network',
              'capture': 'entire MaterialApp including Navigator overlays',
              'source': 'integration_test/settings_refresh_visual_test.dart',
            }),
          );
          debugPrint(
            'SETTINGS-REFRESH-EVIDENCE ${file.path} '
            '${image.width}x${image.height} bytes=${bytes.lengthInBytes}',
          );
        } finally {
          image.dispose();
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
        client.close();
        tester.view.reset();
        await tester.runAsync(() async {
          await temp.delete(recursive: true);
        });
      }
    });
  }
}
