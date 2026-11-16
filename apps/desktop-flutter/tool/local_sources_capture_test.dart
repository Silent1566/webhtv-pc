/// 本地源管理页截图工具：改前 / 改后版式对照。
///
/// 用法（在 apps/desktop-flutter 下）：
///   ../../.tools/flutter/bin/flutter test tool/local_sources_capture_test.dart
///   CAPTURE_PHASE=after ../../.tools/flutter/bin/flutter test tool/local_sources_capture_test.dart
/// 输出：`<仓库根>/.local/local-sources-visual/<phase>/<名称>.png`
///
/// 为什么不用 integration_test：本机没有 GTK 开发头，Linux 桌面构建不可用；
/// widget test 里注册真实中文字体与 Material 图标后，渲染结果足够做版式对照。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/web_home_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/local_sources_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

const _captureKey = ValueKey('local-sources-capture-root');
const _phaseEnv = 'CAPTURE_PHASE';
const _beforePhase = 'before';
const _afterPhase = 'after';
const _cjkFontEnv = 'CAPTURE_CJK_FONT';
const _defaultCjkFont =
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
const _materialFonts =
    '.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';

/// 一张截图：主题、视口、以及截图前怎么走到目标状态。
class _Scenario {
  const _Scenario(
    this.name,
    this.brightness,
    this.size, {
    this.afterOnly = false,
    this.enterBatch = false,
    this.scanFolder = false,
  });

  final String name;
  final Brightness brightness;
  final Size size;

  /// 只有改版后的界面才有这种形态。
  final bool afterOnly;

  /// 截图前点「批量管理」进入多选态。
  final bool enterBatch;
  final bool scanFolder;

  String get file => '$name-${brightness.name}.png';
}

const _scenarios = <_Scenario>[
  _Scenario('list', Brightness.dark, Size(1000, 1100)),
  _Scenario('list', Brightness.light, Size(1000, 1100)),
  _Scenario('rescan', Brightness.dark, Size(1000, 1100), scanFolder: true),
  _Scenario('rescan', Brightness.light, Size(1000, 1100), scanFolder: true),
  _Scenario('rescan-narrow', Brightness.dark, Size(480, 900), scanFolder: true),
  _Scenario(
    'batch-mode',
    Brightness.dark,
    Size(1000, 1100),
    afterOnly: true,
    enterBatch: true,
  ),
];

Directory _repoRoot() {
  var directory = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    if (File('${directory.path}/apps/desktop-flutter/pubspec.yaml')
        .existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('无法定位仓库根目录');
}

List<File> _pngs(Directory dir) => dir.existsSync()
    ? dir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.png'))
          .toList()
    : <File>[];

/// 把一款同时含中文与拉丁字形的真实字重注册到主题用到的每个族名下：测试环境
/// 否则会退回 Ahem（全是方框），版式对照就失去意义。
Future<void> _loadFonts() async {
  final cjk = File(Platform.environment[_cjkFontEnv] ?? _defaultCjkFont);
  if (!cjk.existsSync()) {
    throw StateError('缺少中文字体 ${cjk.path}；可用 $_cjkFontEnv 指定 TTC/OTF 路径');
  }
  final bytes = cjk.readAsBytesSync();
  if (bytes.isEmpty) throw StateError('中文字体为空：${cjk.path}');
  for (final family in const [
    'CaptureSans',
    'Roboto',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'Segoe UI',
  ]) {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
  final icons = File('${_repoRoot().path}/$_materialFonts');
  if (!icons.existsSync()) throw StateError('缺少 Material 图标字体：${icons.path}');
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.view(icons.readAsBytesSync().buffer)));
  await iconLoader.load();
}

ThemeData _captureTheme(Brightness brightness) {
  final base = buildAppTheme(brightness);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'CaptureSans'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'CaptureSans'),
  );
}

Widget _captureRoot(_Scenario scenario, AppState state) => RepaintBoundary(
  key: _captureKey,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _captureTheme(scenario.brightness),
    home: LocalSourcesPage(state: state),
  ),
);

Future<void> _writePng(WidgetTester tester, File target) async {
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      target.writeAsBytesSync(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
  // 纯色或空图连 PNG 头都攒不满这么多字节。
  expect(target.lengthSync(), greaterThan(1024), reason: '截图疑似空白：$target');
}

class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _OfflineHttpClient();
}

class _OfflineHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter || invocation.memberName == #close) return null;
    throw StateError('截图禁止网络访问：${invocation.memberName}');
  }
}

/// 写一个已导入的本地源：`spiders/local/<key>/`。
void _writeLocalSpider(String spiderRoot, String key, String runtime) {
  final dir = Directory(p.join(spiderRoot, 'local', key))
    ..createSync(recursive: true);
  final entry = runtime.startsWith('node') ? 'spider.js' : 'spider.py';
  File(p.join(dir.path, entry)).writeAsStringSync('// $key\n');
  File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'key': key,
      'name': '示例源 $key',
      'runtime': runtime,
      'entry': entry,
      'capabilities': const ['home', 'category', 'detail', 'search', 'play'],
    }),
  );
}

void main() {
  final phase = Platform.environment[_phaseEnv] ?? _beforePhase;
  final output = Directory(
    '${_repoRoot().path}/.local/'
    '${Platform.environment['CAPTURE_OUTPUT_DIR'] ?? 'local-sources-visual'}/$phase',
  );
  final scenarios = _scenarios
      .where((scenario) => !scenario.afterOnly || phase == _afterPhase)
      .toList();
  final previousHttpOverrides = HttpOverrides.current;

  setUpAll(() async {
    expect(
      const [_beforePhase, _afterPhase],
      contains(phase),
      reason: '$_phaseEnv 只接受 $_beforePhase / $_afterPhase',
    );
    if (phase == _beforePhase) {
      expect(
        _pngs(output),
        isEmpty,
        reason: 'before 基线必须保持原样；采集改版后截图请用 CAPTURE_PHASE=after',
      );
    }
    HttpOverrides.global = _OfflineHttpOverrides();
    output.createSync(recursive: true);
    await _loadFonts();
  });

  tearDownAll(() {
    HttpOverrides.global = previousHttpOverrides;
  });

  for (final scenario in scenarios) {
    testWidgets('capture ${scenario.file}', (tester) async {
      final temp = Directory.systemTemp.createTempSync('webhtv-local-capture-');
      final previousLogDirectory = LogService.logDirectoryOverride;
      final state = _buildState(temp);
      addTearDown(() async {
        LogService.logDirectoryOverride = previousLogDirectory;
        state.dispose();
        await state.pythonEnvironmentIdle;
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      await tester.runAsync(state.bootstrap);
      await tester.runAsync(() async {
        await state.reloadLocalSources();
        _addWebHomeSources(state);
      });

      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_captureRoot(scenario, state));
      await tester.pumpAndSettle();
      if (scenario.scanFolder) {
        final source = Directory(p.join(temp.path, 'sources'))
          ..createSync(recursive: true);
        for (final name in ['py-demo.py', 'js-demo.js', 'new-demo.py']) {
          final file = File(p.join(source.path, name));
          file.writeAsStringSync('// fixture only\n');
          file.setLastModifiedSync(DateTime(2025, 11, 15, 18));
        }
        final html = File(p.join(source.path, 'html-demo', 'index.html'));
        html.parent.createSync(recursive: true);
        html.writeAsStringSync('<html><body>fixture</body></html>');
        html.setLastModifiedSync(DateTime(2025, 11, 15, 18));
        await tester.enterText(
          find.byKey(const ValueKey('local-sources-folder')),
          source.path,
        );
        await tester.tap(find.byKey(const ValueKey('local-sources-scan')));
        await tester.pump();
        for (var i = 0; i < 200; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump();
          if (tester
                  .widget<FilledButton>(
                    find.byKey(const ValueKey('local-sources-scan')),
                  )
                  .onPressed !=
              null) {
            break;
          }
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('candidate-js-demo')), findsOneWidget);
      }
      if (scenario.enterBatch) {
        await tester.tap(find.byKey(const ValueKey('local-sources-batch')));
        await tester.pumpAndSettle();
      }
      expect(find.byType(ErrorWidget), findsNothing);
      expect(tester.takeException(), isNull, reason: '渲染异常（含布局溢出）时不出图');
      await _writePng(tester, File('${output.path}/${scenario.file}'));
    });
  }
}

AppState _buildState(Directory temp) {
  final paths = AppPaths.resolve(
    overrides: {
      'config': p.join(temp.path, 'config'),
      'data': p.join(temp.path, 'data'),
      'cache': p.join(temp.path, 'cache'),
      'state': p.join(temp.path, 'logs'),
    },
  );
  paths.ensureDirectories();
  // bootstrap 之前就把日志目录钉在临时目录：不碰真实用户的日志。
  LogService.logDirectoryOverride = paths.logDir;
  final state = AppState(
    paths: paths,
    log: LogService(),
    externalPlayerDetector: () => const [],
  );
  _writeLocalSpider(state.spiderRoot, 'py-demo', 'python');
  _writeLocalSpider(state.spiderRoot, 'js-demo', 'node-22');
  return state;
}

void _addWebHomeSources(AppState state) {
  final store = WebHomeStore(root: p.join(state.paths.configDir, 'webhome'));
  Directory(p.join(store.root, 'html-demo')).createSync(recursive: true);
  File(p.join(store.root, 'html-demo', 'index.html'))
      .writeAsStringSync('<!doctype html><html><body>demo</body></html>');
  store.upsert(
    const WebHomeSource(
      key: 'html-demo',
      name: '示例源 html-demo',
      entry: 'index.html',
      importedAt: '2025-11-16T09:30:00.000',
      entrySha256: '0',
      modifiedAt: '2025-11-15T18:00:00.000',
    ),
  );
  store.addRemote('https://example.com/page', name: '示例源 在线 HTML');
}
