/// 手动截图工具：把设置页渲染成 PNG，供改版 before / after 对照。
///
/// 用法（在 apps/desktop-flutter 下）：
///   ../../.tools/flutter/bin/flutter test tool/settings_capture_test.dart
///   CAPTURE_PHASE=after ../../.tools/flutter/bin/flutter test tool/settings_capture_test.dart
/// 输出：`<仓库根>/.local/settings-refactor-visual/<phase>/<名称>-<亮度>-<宽>x<高>.png`
///
/// before/ 里的 8 张是改版前基线，本工具只读：phase 为 before 时若输出目录已有
/// PNG 就直接失败，避免覆盖基线；改版后的新增截图一律走 CAPTURE_PHASE=after。
///
/// 为什么不用 integration_test：本机没有 clang/GTK 开发头，Linux 桌面构建不可用；
/// widget test 里注册真实中文字体与 Material 图标后，渲染结果足够做版式对照。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/advanced_settings_page.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

import '../test/support/settings_navigation.dart';

const _captureKey = ValueKey('settings-capture-root');
const _wide = Size(1440, 900);
const _narrow = Size(480, 640);
const _user = Size(1072, 728);
const _phaseEnv = 'CAPTURE_PHASE';
const _beforePhase = 'before';
const _afterPhase = 'after';
const _cjkFontEnv = 'CAPTURE_CJK_FONT';
const _defaultCjkFont =
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
const _materialFonts =
    '.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';

/// 截图总数上限：既有 8 张基线 + 最多 18 张新增。
const _maxPngs = 26;

enum _Page { settings, advanced }

/// 一张截图：挂载哪个页面、什么主题与视口、以及截图前怎么走到目标状态。
class _Scenario {
  const _Scenario(
    this.name,
    this.brightness,
    this.size, {
    this.page = _Page.settings,
    this.category,
    this.open,
    this.scrollTo,
    this.afterOnly = false,
  });

  final String name;
  final Brightness brightness;
  final Size size;
  final _Page page;

  /// 真实分类入口 id（`selectSettingsCategory` 的合法取值）。
  final String? category;

  /// 明细页入口 key：点开后再截图，拍到的是被 push 的整条路由。
  final String? open;

  /// 截图前需要滚到可见区域的目标 key，用于覆盖 hub 下端分区。
  final String? scrollTo;

  /// true = 只在 after 阶段采集，不参与 before 基线。
  final bool afterOnly;

  String get file =>
      '$name-${brightness.name}-${size.width.toInt()}x${size.height.toInt()}';
}

/// 高级设置里的六级明细页入口，key 同时用作截图名称。
const _detailRoutes = [
  'settings-player-options-open',
  'settings-danmaku-open',
  'settings-group-rules-open',
  'settings-outbound-proxy-open',
  'settings-doh-open',
  'settings-browser-open',
];

final _scenarios = <_Scenario>[
  // 改版前基线：名称与视口不得改动，否则无法与 before/ 里的 8 张逐帧对照。
  const _Scenario('home', Brightness.dark, _wide),
  const _Scenario('home', Brightness.light, _wide),
  const _Scenario('home', Brightness.dark, _user),
  const _Scenario('home', Brightness.dark, _narrow),
  const _Scenario('hub', Brightness.dark, _wide, page: _Page.advanced),
  const _Scenario('hub', Brightness.light, _wide, page: _Page.advanced),
  const _Scenario('hub', Brightness.dark, _user, page: _Page.advanced),
  const _Scenario('hub', Brightness.dark, _narrow, page: _Page.advanced),
  // 改版后新增：设置页三个分类，走真实分类入口而不是拼装正文。
  const _Scenario(
    'settings-playback',
    Brightness.dark,
    _user,
    category: 'playback',
    afterOnly: true,
  ),
  const _Scenario(
    'settings-connections',
    Brightness.light,
    _narrow,
    category: 'connections',
    afterOnly: true,
  ),
  const _Scenario(
    'settings-maintenance',
    Brightness.dark,
    _user,
    category: 'maintenance',
    afterOnly: true,
  ),
  // 改版后新增：六级明细页，两种代表视口各一张。
  for (final route in _detailRoutes) ...[
    _Scenario(
      route,
      Brightness.dark,
      _user,
      page: _Page.advanced,
      open: route,
      afterOnly: true,
    ),
    _Scenario(
      route,
      Brightness.light,
      _narrow,
      page: _Page.advanced,
      open: route,
      afterOnly: true,
    ),
  ],
  // 改版后新增：hub 滚到底部，覆盖「网络 / 工具 / 隐私与诊断」三个分区。
  _Scenario(
    'hub-bottom',
    Brightness.dark,
    _user,
    page: _Page.advanced,
    scrollTo: 'settings-spider-debug-log',
    afterOnly: true,
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

/// 主题的首选族名是 Microsoft YaHei UI，本机没有真实字面；测试环境又会退回
/// Ahem（全是方框）。因此把一款同时含中文与拉丁字形的真实字重注册到主题用到的
/// 每个族名下，字形覆盖才与真实安装字体一致（默认 NotoSansCJK-Regular.ttc）。
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

Widget _page(_Page page, AppState state) => switch (page) {
  _Page.settings => Scaffold(body: SettingsPage(state: state)),
  _Page.advanced => AdvancedSettingsPage(state: state),
};

/// 捕获边界必须在 MaterialApp 之上：包在 home 里只拍得到当前页，
/// push 出来的明细路由画在 Navigator 的 Overlay 上，会被漏掉。
Widget _captureRoot(_Scenario scenario, AppState state) => RepaintBoundary(
  key: _captureKey,
  child: MaterialApp(
    // 截图根现在包在 MaterialApp 外，DEBUG 角标会一起入镜；它不属于界面。
    debugShowCheckedModeBanner: false,
    theme: _captureTheme(scenario.brightness),
    home: _page(scenario.page, state),
  ),
);

/// 把目标控件滚到可见区域：懒加载列表里目标可能还没建出来，先按需滚动。
/// 只依赖公开的 Scrollable 与控件 key，不读页面私有状态。
Future<void> _reveal(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

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

void main() {
  final phase = Platform.environment[_phaseEnv] ?? _beforePhase;
  final output = Directory(
    '${_repoRoot().path}/.local/settings-refactor-visual/$phase',
  );
  final scenarios = [
    for (final scenario in _scenarios)
      if (!scenario.afterOnly || phase == _afterPhase) scenario,
  ];
  final previousHttpOverrides = HttpOverrides.current;

  setUpAll(() async {
    expect(
      const [_beforePhase, _afterPhase],
      contains(phase),
      reason: '$_phaseEnv 只接受 $_beforePhase / $_afterPhase',
    );
    expect(scenarios.length, lessThanOrEqualTo(_maxPngs));
    expect(
      scenarios.map((scenario) => scenario.file).toSet().length,
      scenarios.length,
      reason: '截图文件名必须唯一',
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
    expect(_pngs(output).length, lessThanOrEqualTo(_maxPngs));
  });

  for (final scenario in scenarios) {
    testWidgets('capture ${scenario.file}', (tester) async {
      final temp = Directory.systemTemp.createTempSync('webhtv-capture-');
      final previousLogDirectory = LogService.logDirectoryOverride;
      addTearDown(() {
        LogService.logDirectoryOverride = previousLogDirectory;
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      );
      // bootstrap 之前就把日志目录钉在临时目录：初始化早退或报错都写临时文件，
      // 不碰真实用户的日志。
      LogService.logDirectoryOverride = paths.logDir;
      final state = AppState(
        paths: paths,
        log: LogService(),
        externalPlayerDetector: () => const [],
      );
      addTearDown(state.dispose);
      await tester.runAsync(state.bootstrap);
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_captureRoot(scenario, state));
      await tester.pumpAndSettle();
      if (scenario.category != null) {
        await selectSettingsCategory(tester, scenario.category!);
      }
      if (scenario.scrollTo != null) {
        await _reveal(tester, scenario.scrollTo!);
      }
      if (scenario.open != null) {
        await _reveal(tester, scenario.open!);
        await tester.tap(find.byKey(ValueKey(scenario.open!)));
        await tester.pumpAndSettle();
      }
      expect(find.byType(ErrorWidget), findsNothing);
      expect(tester.takeException(), isNull, reason: '渲染异常（含布局溢出）时不出图');
      await _writePng(tester, File('${output.path}/${scenario.file}.png'));
    });
  }
}
