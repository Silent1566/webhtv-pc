/// 手动截图工具：把设置页渲染成 PNG，供改版 before / after 对照。
///
/// 用法（在 apps/desktop-flutter 下）：
///   ../../.tools/flutter/bin/flutter test tool/settings_capture_test.dart
///   CAPTURE_PHASE=after ../../.tools/flutter/bin/flutter test tool/settings_capture_test.dart
/// 输出：`<仓库根>/.local/settings-refactor-visual/<phase>/<名称>-<亮度>-<宽>x<高>.png`
///
/// before/ 与 before-cats/ 里的 12 张是改版前基线，本工具只读：phase 为 before 时
/// 若输出目录已有 PNG 就直接失败。改版后「高级设置」中枢整页删除，旧形态与本工具
/// 不再同源，因此 before 阶段不跑任何场景——基线只能由改版前的代码重新采集。
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
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/settings_overview_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import '../test/support/settings_navigation.dart';
import '../test/support/settings_row_navigation.dart';

const _captureKey = ValueKey('settings-capture-root');
const _wide = Size(1440, 900);
const _short = Size(1024, 300);
const _narrow = Size(480, 640);
const _tinyHeight = Size(480, 320);
const _user = Size(1072, 728);
const _phaseEnv = 'CAPTURE_PHASE';
const _beforePhase = 'before';
const _afterPhase = 'after';
const _cjkFontEnv = 'CAPTURE_CJK_FONT';
const _defaultCjkFont =
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc';
const _materialFonts =
    '.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';

/// 截图总数上限：与 [_scenarios] 等长，多出一张就说明有历史 PNG 混进了输出目录。
const _maxPngs = 22;

/// 挂哪一页做首页：外壳里的设置标签页，还是播放器右键菜单 push 的「全部设置」。
enum _Page { settings, overview }

/// 一张截图：挂载哪个页面、什么主题与视口、以及截图前怎么走到目标状态。
class _Scenario {
  const _Scenario(
    this.name,
    this.brightness,
    this.size, {
    this.page = _Page.settings,
    this.category,
    this.open,
  }) : assert(open == null || category != null, '点行必须先指定所在分类');

  final String name;
  final Brightness brightness;
  final Size size;
  final _Page page;

  /// 真实分类入口 id（selectSettingsCategory 的合法取值）；null = 默认「偏好」。
  final String? category;

  /// 明细页入口行 key：点开后再截图，拍到的是被 push 的整条路由。
  final String? open;

  String get file =>
      '$name-${brightness.name}-${size.width.toInt()}x${size.height.toInt()}';
}

/// 22 张改版后截图。
///
/// 命名与视口沿用基线，才能和 before/（home 4 张）、before-cats/（cat 4 张）逐张配对；
/// 中枢删除后它的 4 张由「同类落点」接替（cat-sites / cat-connections / cat-maintenance），
/// 其余 12 张是新增明细页、「全部设置」页与矮窗证据。
const _scenarios = <_Scenario>[
  // 改版前基线配对：默认进入「偏好」分类（宽窗是左栏，窄窗走顶部分类条）。
  _Scenario('home', Brightness.dark, _wide),
  _Scenario('home', Brightness.light, _wide),
  _Scenario('home', Brightness.dark, _user),
  _Scenario('home', Brightness.dark, _narrow),
  // 与 before-cats/ 配对：分类页，名字逐字沿用基线。
  _Scenario('cat-playback', Brightness.dark, _user, category: 'playback'),
  _Scenario('cat-playback', Brightness.light, _narrow, category: 'playback'),
  _Scenario('cat-maintenance', Brightness.dark, _user, category: 'maintenance'),
  _Scenario(
    'cat-connections',
    Brightness.light,
    _narrow,
    category: 'connections',
  ),
  // 中枢消失后的落点：原来 hub 的 4 个视口由这三个分类接住。
  _Scenario('cat-sites', Brightness.dark, _wide, category: 'sites'),
  _Scenario('cat-sites', Brightness.light, _wide, category: 'sites'),
  _Scenario('cat-connections', Brightness.dark, _user, category: 'connections'),
  _Scenario(
    'cat-maintenance',
    Brightness.dark,
    _narrow,
    category: 'maintenance',
  ),
  // 新增明细页：真实切分类 + 真实点行（不用 Navigator.push 抄近路）。
  _Scenario(
    'osd',
    Brightness.dark,
    _user,
    category: 'playback',
    open: 'settings-osd-open',
  ),
  _Scenario(
    'osd',
    Brightness.light,
    _narrow,
    category: 'playback',
    open: 'settings-osd-open',
  ),
  _Scenario(
    'live',
    Brightness.dark,
    _user,
    category: 'playback',
    open: 'settings-live-open',
  ),
  _Scenario(
    'live',
    Brightness.light,
    _narrow,
    category: 'playback',
    open: 'settings-live-open',
  ),
  _Scenario(
    'about-data',
    Brightness.dark,
    _user,
    category: 'maintenance',
    open: 'settings-about-data-open',
  ),
  _Scenario(
    'about-data',
    Brightness.light,
    _narrow,
    category: 'maintenance',
    open: 'settings-about-data-open',
  ),
  // 「全部设置」是可 push 的独立路由：直接挂该页，不点行。
  _Scenario('overview', Brightness.dark, _user, page: _Page.overview),
  _Scenario('overview', Brightness.light, _narrow, page: _Page.overview),
  // 矮窗：5 个分类 pill 在 480 下换行；1024x300 走左栏，分类栏自身可滚。
  _Scenario('home', Brightness.dark, _tinyHeight),
  _Scenario('home', Brightness.dark, _short),
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
  _Page.overview => SettingsOverviewPage(state: state),
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

void main() {
  final phase = Platform.environment[_phaseEnv] ?? _beforePhase;
  final output = Directory(
    '${_repoRoot().path}/.local/settings-refactor-visual/$phase',
  );
  final scenarios = phase == _afterPhase ? _scenarios : const <_Scenario>[];
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
      await pumpSettingsSettled(tester);
      if (scenario.category != null) {
        await selectSettingsCategory(tester, scenario.category!);
      }
      if (scenario.open != null) {
        await tapCategoryRow(
          tester,
          category: scenario.category!,
          rowKey: scenario.open!,
        );
      }
      expect(find.byType(ErrorWidget), findsNothing);
      expect(tester.takeException(), isNull, reason: '渲染异常（含布局溢出）时不出图');
      await _writePng(tester, File('${output.path}/${scenario.file}.png'));
    });
  }
}
