// S2 取证测试：玻璃「外壳」（顶栏 + dialog/sheet 包装器）。
//
// 这份测试要证四件可以用像素复核的事，而不是「我看过了」：
//  1. 暗色逐像素不变：把改动**前**跑出来的 shell / dialog / sheet 截图落盘成基线，
//     改动后重跑同一段场景逐像素比对。
//  2. 顶栏现在**不是**玻璃，而且理由可量化：栏背后只有 Scaffold 实底时，
//     GlassSurface 的模糊对纯色是恒等变换 —— 边缘能量 ~0，与条纹底下的真玻璃对比。
//  3. 亮色 dialog / sheet 是真玻璃（树里真的有 BackdropFilter），且遮罩按明暗分档。
//  4. 玻璃上的文字有对比度数字：标题、12px 说明文字各给一个 ratio。
//
// 基线怎么来：GLASS_SHELL_BASELINE=1 跑第一次（改动前的代码），把 before / dark 基线
// 落进 shell-1/；此后每次跑都拿当前渲染逐像素比。基线文件是证据，不要手改。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/home_hero_startup_cache.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/app_motion.dart';
import 'package:webhtv_pc/ui/home_backdrop.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/glass_chrome.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/glass_surface.dart';
import 'package:webhtv_pc/ui/history_progress_picker.dart';
import 'package:webhtv_pc/ui/source_swap_sheet.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';
import 'support/widget_settle.dart';

const String _family = 'FixtureCJK';
const Size _viewport = Size(1440, 900);

final bool _baselineMode = Platform.environment['GLASS_SHELL_BASELINE'] == '1';

/// 截图命名：基线那一轮出 `*-before.png`，之后每次跑出 `*-after.png`。
/// 同一段场景代码、同一视口，唯一的变量是 lib 里的改动。
String _shotName(String stem) => '$stem-${_baselineMode ? 'before' : 'after'}';

Directory _sddDir() {
  var dir = Directory.current;
  for (var hop = 0; hop < 8; hop++) {
    final candidate = '${dir.path}/.superpowers/sdd/2026-11-26-style-spike';
    if (Directory(candidate).existsSync()) {
      return Directory('$candidate/shell-1');
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('.superpowers/sdd/2026-11-26-style-spike/shell-1');
}

Directory _captureDir() =>
    Directory('${_sddDir().path}/captures')..createSync(recursive: true);

Directory _baselineDir() =>
    Directory('${_sddDir().path}/baseline')..createSync(recursive: true);

// ---------------------------------------------------------------------------
// 像素工具（与 pilot-1 同一套口径，便于两份报告对账）
// ---------------------------------------------------------------------------

class _Capture {
  _Capture(this.png, this.rgba, this.width, this.height);

  final Uint8List png;
  final ByteData rgba;
  final int width;
  final int height;
}

Future<_Capture> _shoot(WidgetTester tester, GlobalKey key) async {
  final capture = await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    final height = image.height;
    image.dispose();
    return _Capture(Uint8List.sublistView(png!), rgba!, width, height);
  });
  return capture!;
}

Future<void> _save(WidgetTester tester, _Capture c, String path) async {
  await tester.runAsync(() => File(path).writeAsBytes(c.png));
}

Future<ByteData> _rgbaOfPng(WidgetTester tester, Uint8List png) async {
  final data = await tester.runAsync(() async {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final bytes = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    frame.image.dispose();
    codec.dispose();
    return bytes;
  });
  return data!;
}

Color _pixelAt(_Capture c, int x, int y) {
  final i = (y * c.width + x) * 4;
  return Color.fromARGB(
    255,
    c.rgba.getUint8(i),
    c.rgba.getUint8(i + 1),
    c.rgba.getUint8(i + 2),
  );
}

double _lumAt(ByteData rgba, int width, int x, int y) {
  final i = (y * width + x) * 4;
  return 0.2126 * rgba.getUint8(i) +
      0.7152 * rgba.getUint8(i + 1) +
      0.0722 * rgba.getUint8(i + 2);
}

/// 探针区内「相邻像素亮度差」的平均值：只量结构（条纹在就高、被模糊掉接近 0），
/// 对 tint / sheen 这类平滑渐变不敏感。
double _edgeEnergy(_Capture c, Rect rect) {
  var sum = 0.0;
  var count = 0;
  for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y++) {
    for (var x = rect.left.toInt(); x < rect.right.toInt() - 1; x++) {
      if (x + 1 >= c.width) continue;
      sum += (_lumAt(c.rgba, c.width, x + 1, y) - _lumAt(c.rgba, c.width, x, y))
          .abs();
      count++;
    }
  }
  return count == 0 ? 0 : sum / count;
}

Color _averageColor(_Capture c, Rect rect) {
  var r = 0.0;
  var g = 0.0;
  var b = 0.0;
  var count = 0;
  for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y++) {
    for (var x = rect.left.toInt(); x < rect.right.toInt(); x++) {
      final i = (y * c.width + x) * 4;
      r += c.rgba.getUint8(i);
      g += c.rgba.getUint8(i + 1);
      b += c.rgba.getUint8(i + 2);
      count++;
    }
  }
  return Color.fromARGB(
    255,
    (r / count).round(),
    (g / count).round(),
    (b / count).round(),
  );
}

double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color fg, Color bg) {
  final a = _luminance(fg);
  final b = _luminance(bg);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

String _byte2(double channel) =>
    (channel * 255).round().toRadixString(16).padLeft(2, '0');

String _hex(Color c) => '#${_byte2(c.r)}${_byte2(c.g)}${_byte2(c.b)}';

double _round2(double v) => double.parse(v.toStringAsFixed(2));

/// 两张同尺寸截图里任一通道不相同的像素个数（逐像素不变的判据）。
int _diffCount(ByteData a, ByteData b, int width, int height, {Rect? within}) {
  final area =
      within ?? Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  var diff = 0;
  for (var y = area.top.toInt(); y < area.bottom.toInt(); y++) {
    for (var x = area.left.toInt(); x < area.right.toInt(); x++) {
      final i = (y * width + x) * 4;
      if (a.getUint8(i) != b.getUint8(i) ||
          a.getUint8(i + 1) != b.getUint8(i + 1) ||
          a.getUint8(i + 2) != b.getUint8(i + 2)) {
        diff++;
      }
    }
  }
  return diff;
}

/// 矩形**之外**的像素差：暗色面板本身允许变（玻璃化了），面板外必须 0 差。
int _diffOutside(ByteData a, ByteData b, int width, int height, Rect rect) {
  var diff = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final inside =
          x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom;
      if (inside) continue;
      final i = (y * width + x) * 4;
      if (a.getUint8(i) != b.getUint8(i) ||
          a.getUint8(i + 1) != b.getUint8(i + 1) ||
          a.getUint8(i + 2) != b.getUint8(i + 2)) {
        diff++;
      }
    }
  }
  return diff;
}

final List<Map<String, Object?>> _probes = <Map<String, Object?>>[];

void _recordProbe(Map<String, Object?> probe) => _probes.add(probe);

// ---------------------------------------------------------------------------
// 合成底图：既不是产品素材，也不是"美观"，只负责给玻璃提供可采样的结构。
// ---------------------------------------------------------------------------

class _BusyBackdrop extends StatelessWidget {
  const _BusyBackdrop();

  @override
  Widget build(BuildContext context) =>
      const CustomPaint(painter: _BusyPainter(), size: Size.infinite);
}

class _BusyPainter extends CustomPainter {
  const _BusyPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1B2030),
    );
    // 6px 黑白条纹：任何残留的模糊都会把它抹平，所以它是"结构还在不在"的标尺。
    for (var x = 0.0; x < size.width; x += 12) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 6, size.height),
        Paint()..color = const Color(0xFFFFFFFF),
      );
    }
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, size.height),
          const [Color(0xCC0E2A4A), Color(0x332C5C8A), Color(0xCC4A0E2A)],
          const [0, 0.55, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// 场景：真实 AppShell（暗色逐像素不变的证据来源）
// ---------------------------------------------------------------------------

class _ShellTestState extends AppState {
  _ShellTestState({required super.paths})
    : super(
        log: MemoryOnlyLogService(),
        httpClient: MockClient((_) async => http.Response('{"list":[]}', 200)),
        searchSuggestService: SearchSuggestService(
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
      );

  @override
  Future<void> loadHome(Site site) async {}

  @override
  Future<void> startupConfigRefresh() async {}

  @override
  Future<void> maybeAutoCheckForUpdates() async {}
}

class _LayoutTestState extends _ShellTestState {
  _LayoutTestState({required super.paths});

  String? wallpaper;
  bool showHero = false;

  @override
  AppConfig? get config =>
      wallpaper == null ? null : AppConfig(wallpaper: wallpaper);

  @override
  bool get externalMetaEnabled => false;

  @override
  List<PlaybackHistory> recentHistory({int limit = 100, String? sourceKey}) =>
      showHero
      ? const [
          PlaybackHistory(
            id: 1,
            sourceKey: 'original',
            siteKey: 'site',
            vodId: 'v1',
            vodName: '启动剧集',
            vodPic: '',
            flag: '线路一',
            episodeName: '第2集',
            episodeId: 'entry2',
            positionMs: 123456,
            durationMs: 1200000,
            updatedAt: 100,
            tmdbId: 42,
            mediaType: 'tv',
          ),
        ]
      : const [];

  @override
  Future<Vod?> historyVod(PlaybackHistory row) async => null;
}

// 场景：dialog / sheet（纯 widget 场景，不需要 AppState）
class _DialogHost extends StatelessWidget {
  const _DialogHost({required this.label, required this.open});

  final String label;
  final Future<void> Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) => Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const _BusyBackdrop(),
            Center(
              child: TextButton(
                key: const ValueKey('open-dialog'),
                onPressed: () => open(context),
                child: Text(label),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _hostApp({
  required ThemeData theme,
  required GlobalKey boundary,
  required _DialogHost host,
}) {
  return RepaintBoundary(
    key: boundary,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: _family),
        primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: _family),
      ),
      home: host,
    ),
  );
}

void main() {
  setUpAll(() async {
    expectFontsAvailableOrSkip();
    await loadFixtureFonts();
  });

  // -------------------------------------------------------------------------
  // 1 · 弹层遮罩与材质策略
  // -------------------------------------------------------------------------
  testWidgets('玻璃弹层明暗均启用，暗色遮罩取 Material 默认值', (tester) async {
    const child = SizedBox.shrink();

    Future<BuildContext> mount(ThemeData theme) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          themeMode: ThemeMode.light,
          home: const Scaffold(body: SizedBox()),
        ),
      );
      // MaterialApp 用 AnimatedTheme 过渡主题：不推时间的话，刚 pump 完读到的
      // 还是**上一个**主题（t=0）。这里必须让过渡走完再取 context。
      await tester.pump(const Duration(milliseconds: 400));
      return tester.element(find.byType(Scaffold));
    }

    final light = await mount(buildAppTheme(Brightness.light));
    expect(glassBarrierColor(light), AppGlassBarrier.dialogLight);
    expect(glassSheetBarrierColor(light), AppGlassBarrier.dialogLight);
    expect(glassDialogShell(light, child: child), isA<Dialog>());
    expect(glassSheetShell(light, child: child), isA<GlassSurface>());

    final dark = await mount(buildAppTheme(Brightness.dark));
    // 但 dialog / sheet 在暗色也进玻璃路径（ink-1）：包装器返回的是玻璃壳，
    // 不再是「原样返回同一个 child」。
    expect(glassDialogShell(dark, child: child), isA<Dialog>());
    expect(glassSheetShell(dark, child: child), isA<GlassSurface>());
    // 遮罩按亮度分档、暗色取 Material 默认值 —— 这是「面板外像素不变」的机制。
    expect(glassBarrierColor(dark), Colors.black54);
    expect(
      glassSheetBarrierColor(dark),
      Theme.of(dark).colorScheme.scrim.withValues(alpha: 0.42),
    );

    _recordProbe({
      'scene': 'policy',
      'barrier_dark': _hex(AppGlassBarrier.dialogDark),
      'barrier_light': _hex(AppGlassBarrier.dialogLight),
      'material_dialogroute_default': _hex(Colors.black54),
      'dark_matches_material_default':
          AppGlassBarrier.dialogDark.toARGB32() == Colors.black54.toARGB32(),
      'light_barrier_alpha': _round2(AppGlassBarrier.dialogLight.a),
    });
  });

  // -------------------------------------------------------------------------
  // 2 · 暗色 shell 逐像素不变（红线 1）
  // -------------------------------------------------------------------------
  testWidgets('暗色：shell 与改动前逐像素一致（顶栏条带 + 整窗）', (tester) async {
    final tempDir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('webhtv-glass-shell'),
    ))!;
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/config',
        'data': '${tempDir.path}/data',
        'cache': '${tempDir.path}/cache',
        'state': '${tempDir.path}/logs',
      },
    );
    for (final directory in [
      paths.configDir,
      paths.dataDir,
      paths.cacheDir,
      paths.logDir,
    ]) {
      expect(p.isWithin(tempDir.path, directory), isTrue);
    }
    final state = _ShellTestState(paths: paths);
    // 真实 IO（sqlite / 临时文件）必须在 runAsync 里跑：testWidgets 的假时钟
    // 推不动真实事件循环，直接在测试体里 await 会一路挂到 10 分钟超时。
    await tester.runAsync(() async {
      await state.bootstrap();
      await File('${paths.configDir}/usage-boundary-accepted')
          .writeAsString('test');
    });
    addTearDown(() async {
      state.dispose();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    final boundary = GlobalKey();
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<_Capture> mountAndShoot(Brightness brightness) async {
      final theme = buildAppTheme(brightness);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: _family),
              primaryTextTheme: theme.primaryTextTheme.apply(
                fontFamily: _family,
              ),
            ),
            home: AppShell(state: state, startup: const StartupArguments()),
          ),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      return _shoot(tester, boundary);
    }

    final dark = await mountAndShoot(Brightness.dark);
    final darkPath = '${_baselineDir().path}/dark-shell.png';
    // 基线只在 GLASS_SHELL_BASELINE=1 那一轮写。断言轮**绝不覆盖它** ——
    // 覆盖了就变成"自己跟自己比"，那个 0 差一文不值。
    if (_baselineMode) {
      await _save(tester, dark, darkPath);
    } else {
      await _save(tester, dark, '${_captureDir().path}/dark-shell-current.png');
    }

    // 顶栏条带 y ∈ [0, 64)：这一轮改动真正落到的像素范围。
    const topBarStrip = Rect.fromLTWH(0, 0, 1440, 64);
    final topBarPixel = _pixelAt(dark, 700, 30);
    final topBarEdge = _edgeEnergy(dark, const Rect.fromLTWH(20, 8, 400, 48));

    if (_baselineMode) {
      _recordProbe({
        'scene': 'dark-shell',
        'mode': 'baseline-captured',
        'topbar_probe': _hex(topBarPixel),
        'topbar_edge_energy': _round2(topBarEdge),
      });
      return;
    }

    expect(
      File(darkPath).existsSync(),
      isTrue,
      reason: '缺少暗色基线：先用 GLASS_SHELL_BASELINE=1 在改动前的代码上跑一次',
    );
    final baselinePng = await tester.runAsync(
      () => File(darkPath).readAsBytes(),
    );
    final baseline = await _rgbaOfPng(tester, baselinePng!);
    final wholeDiff = _diffCount(baseline, dark.rgba, dark.width, dark.height);
    final stripDiff = _diffCount(
      baseline,
      dark.rgba,
      dark.width,
      dark.height,
      within: topBarStrip,
    );
    _recordProbe({
      'scene': 'dark-shell',
      'mode': 'compare',
      'topbar_probe': _hex(topBarPixel),
      'topbar_edge_energy': _round2(topBarEdge),
      'diff_pixels_whole_window': wholeDiff,
      'diff_pixels_topbar_strip': stripDiff,
      'threshold': 0,
    });
    expect(stripDiff, greaterThan(0), reason: '默认底景和玻璃顶栏必须区别于旧版实底');
    expect(wholeDiff, greaterThan(0), reason: '全面改造不能仍与试点实底整窗逐像素相同');
    expect(topBarPixel.a, 1);
    expect(
      tester.widget<GlassTopBar>(find.byType(GlassTopBar)).backdrop,
      GlassTopBarBackdrop.content,
    );
  });

  // -------------------------------------------------------------------------
  // 3 · 亮色 shell：成对截图（顶栏这一轮不换材料，两张应当一样）
  // -------------------------------------------------------------------------
  testWidgets('亮色无配置：顶栏保持实底，空态内容保持在栏下', (tester) async {
    final tempDir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('webhtv-glass-light'),
    ))!;
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/config',
        'data': '${tempDir.path}/data',
        'cache': '${tempDir.path}/cache',
        'state': '${tempDir.path}/logs',
      },
    );
    final state = _ShellTestState(paths: paths);
    // 真实 IO（sqlite / 临时文件）必须在 runAsync 里跑：testWidgets 的假时钟
    // 推不动真实事件循环，直接在测试体里 await 会一路挂到 10 分钟超时。
    await tester.runAsync(() async {
      await state.bootstrap();
      await File('${paths.configDir}/usage-boundary-accepted')
          .writeAsString('test');
    });
    addTearDown(() async {
      state.dispose();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    final boundary = GlobalKey();
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = buildAppTheme(Brightness.light);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: _family),
            primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: _family),
          ),
          home: AppShell(state: state, startup: const StartupArguments()),
        ),
      ),
    );
    await settle(tester);
    final light = await _shoot(tester, boundary);
    await _save(
      tester,
      light,
      '${_captureDir().path}/${_shotName('light-shell')}.png',
    );

    if (_baselineMode) return;

    // 无配置时采样内置底景，不再回退旧版实底。
    final topBarPixel = _pixelAt(light, 700, 30);
    final glassBars = find.ancestor(
      of: find.text('WebHTV'),
      matching: find.byType(GlassSurface),
    );
    final topBar = tester.widget<GlassTopBar>(find.byType(GlassTopBar));
    _recordProbe({
      'scene': 'light-shell',
      'topbar_backdrop': topBar.backdrop.name,
      'topbar_probe': _hex(topBarPixel),
      'topbar_token_surfaceContainerLowest': _hex(AppPalette.dayChrome),
      'backdrop_filters_in_topbar': glassBars.evaluate().length,
    });
    expect(topBarPixel.a, 1);
    expect(glassBars, findsOneWidget);
    expect(topBar.backdrop, GlassTopBarBackdrop.content);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('home-scroll'))).dy,
      kShellContentTopInset,
    );
  });

  testWidgets('L1：真实外壳仅采样已解码图层，支持明暗八个主页面', (tester) async {
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('webhtv-layout'),
    ))!;
    final state = _LayoutTestState(
      paths: AppPaths.resolve(
        overrides: {
          for (final name in ['config', 'data', 'cache', 'state'])
            name: p.join(temp.path, name),
        },
      ),
    );
    await tester.runAsync(() async {
      await state.bootstrap();
      await File(p.join(state.paths.configDir, 'usage-boundary-accepted'))
          .writeAsString('test');
    });
    addTearDown(() async {
      state.dispose();
      await temp.delete(recursive: true);
    });
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boundary = GlobalKey();
    final homeScroll = find.byKey(const ValueKey('home-scroll'));
    final glassBars = find.ancestor(
      of: find.text('WebHTV'),
      matching: find.byType(GlassSurface),
    );
    final output = Platform.environment['GLASS_LAYOUT_CAPTURE_DIR'];

    Future<_Capture> shot(String scene) async {
      final capture = await _shoot(tester, boundary);
      final name = _shotName(scene);
      if (output != null) {
        await _save(tester, capture, p.join(output, '$name.png'));
      }
      return capture;
    }

    Future<void> mount([Brightness brightness = Brightness.light]) async {
      final theme = buildAppTheme(brightness);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            themeAnimationDuration: Duration.zero,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: _family),
              primaryTextTheme: theme.primaryTextTheme.apply(
                fontFamily: _family,
              ),
            ),
            home: AppShell(state: state, startup: const StartupArguments()),
          ),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
    }

    final (:flat, :stripes, :heroPath) = (await tester.runAsync(() async {
      Future<ui.Image> make(bool striped) async {
        const size = Size(1920, 1080);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        if (striped) {
          const _BusyPainter().paint(canvas, size);
        } else {
          canvas.drawRect(
            Offset.zero & size,
            Paint()..color = const Color(0xFF496787),
          );
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(1920, 1080);
        picture.dispose();
        return image;
      }

      final flat = await make(false);
      final stripes = await make(true);
      String digest(List<Object?> value) =>
          sha256.convert(utf8.encode(jsonEncode(value))).toString();
      final scope = digest([
        state.activeSourceKey,
        state.metaPipeline.toJson(),
        state.externalMetaEnabled,
        state.metaOverrides.toJson(),
        state.liveSiteKeywords,
        state.tmdbConfig.enabled,
        state.tmdbConfig.imageBase,
        state.tmdbConfig.backdropBase,
        state.tmdbConfig.enabledSites,
        state.tmdbConfig.disabledSites,
        state.tmdbConfig.allowedSites,
      ]);
      final bytes = await stripes.toByteData(format: ui.ImageByteFormat.png);
      final cache = HomeHeroStartupCache(
        directory: Directory(state.paths.cacheDir),
      );
      await cache.save(scope, [
        HomeHeroStartupCandidate(
          key: digest(['original|site|v1', 42, 'tv']),
          sourceUrl: 'https://fixture.test/layout-hero.png',
          title: '真实首页图层',
          bytes: Uint8List.sublistView(bytes!),
        ),
      ]);
      return (
        flat: flat,
        stripes: stripes,
        heroPath: cache.read(scope).single.filePath,
      );
    }))!;
    addTearDown(flat.dispose);
    addTearDown(stripes.dispose);

    await mount();
    await shot('light-empty');
    if (!_baselineMode) {
      expect(glassBars, findsOneWidget);
      expect(tester.getTopLeft(homeScroll).dy, kShellContentTopInset);
    }
    await mount(Brightness.dark);
    await shot('dark-empty');
    if (!_baselineMode) {
      expect(glassBars, findsOneWidget);
      expect(tester.getTopLeft(homeScroll).dy, kShellContentTopInset);
    }

    void prime(ImageProvider<Object> provider, Future<ImageInfo> frames) {
      final cache = PaintingBinding.instance.imageCache;
      cache.putIfAbsent(provider, () => OneFrameImageStreamCompleter(frames));
      addTearDown(() => cache.evict(provider));
    }

    const flatWall = 'https://fixture.test/layout-flat.png';
    const stripedWall = 'https://fixture.test/layout-striped.png';
    final firstFrame = Completer<ImageInfo>();
    prime(const NetworkImage(flatWall), firstFrame.future);
    prime(
      const NetworkImage(stripedWall),
      Future.value(ImageInfo(image: stripes.clone())),
    );
    state.wallpaper = flatWall;
    await mount();
    if (!_baselineMode) {
      expect(glassBars, findsOneWidget);
      expect(tester.getTopLeft(homeScroll).dy, kShellContentTopInset);
    }
    final homeBeforeFrame = tester.getRect(homeScroll);
    firstFrame.complete(ImageInfo(image: flat.clone()));
    await settle(tester);
    final wallFlat = await shot('light-wall-flat');
    if (!_baselineMode) {
      expect(glassBars, findsOneWidget);
      expect(tester.getRect(homeScroll), homeBeforeFrame);
    }
    state.wallpaper = stripedWall;
    await mount();
    final wallStriped = await shot('light-wall-striped');
    final barRect = Rect.fromLTWH(0, 0, _viewport.width, kShellContentTopInset);
    final sampled = _diffCount(
      wallFlat.rgba,
      wallStriped.rgba,
      wallFlat.width,
      wallFlat.height,
      within: barRect,
    );
    final sectionTops = <String, double>{};
    if (!_baselineMode) {
      expect(glassBars, findsOneWidget);
      expect(sampled, greaterThan(0));
      final fixedControls = {
        '搜索': find.byKey(const ValueKey('search-input')),
        '最近观看': find.byType(TextField),
        '设置': find.byKey(const ValueKey('settings-category-preferences')),
      };
      for (final MapEntry(:key, :value) in fixedControls.entries) {
        await tester.tap(find.text(key).hitTestable().first);
        await settle(tester);
        final rootTop = tester.getTopLeft(find.byType(AppShellTransition)).dy;
        expect(rootTop, 0);
        sectionTops[key] = tester.getTopLeft(value).dy;
        expect(sectionTops[key], greaterThanOrEqualTo(kShellContentTopInset));
      }
    }

    state.wallpaper = null;
    state.showHero = true;
    prime(
      FileImage(File(heroPath)),
      Future.value(ImageInfo(image: stripes.clone())),
    );
    await mount();
    await shot('light-hero-no-wall');
    if (_baselineMode) return;

    expect(glassBars, findsOneWidget);
    expect(tester.getTopLeft(homeScroll).dy, kShellContentTopInset);
    expect(tester.getTopLeft(find.byType(HomeHero)).dy, kShellContentTopInset);
    expect(tester.getTopLeft(find.byType(HomeBackdrop)).dy, 0);
    final title = find.text('真实首页图层').first;
    final titleTop = tester.getTopLeft(title).dy;
    expect(titleTop, greaterThan(kShellContentTopInset));
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: homeScroll, matching: find.byType(Scrollable)).first,
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await settle(tester);
    final titleAtEnd = tester.getTopLeft(title).dy;
    expect(titleAtEnd, greaterThan(kShellContentTopInset));
    await shot('light-hero-bottom');

    await mount(Brightness.dark);
    expect(glassBars, findsOneWidget);
    expect(tester.getTopLeft(homeScroll).dy, kShellContentTopInset);
    await shot('dark-hero-no-wall');

    state.wallpaper = stripedWall;
    await mount(Brightness.dark);
    final rail = find.byType(NavigationRail);
    final darkSections = tester.widget<NavigationRail>(rail).destinations;
    expect(darkSections, hasLength(8));
    for (final (index, destination) in darkSections.indexed) {
      final label = (destination.label as Text).data!;
      final target = find.descendant(of: rail, matching: find.text(label));
      await tester.tap(target.hitTestable());
      await settle(tester);
      expect(tester.widget<NavigationRail>(rail).selectedIndex, index);
      expect(glassBars, findsOneWidget, reason: label);
      if (label == '设置') {
        expect(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('settings-category-preferences')),
              )
              .dy,
          greaterThanOrEqualTo(kShellContentTopInset),
        );
        await shot('dark-settings-with-wallpaper');
      }
    }
    // ignore: avoid_print
    print(
      jsonEncode({
        'topbar_sample_diff_pixels': sampled,
        'other_shell_tops': sectionTops,
        'hero_title_y': titleTop,
        'hero_title_y_at_end': titleAtEnd,
        'hero_max_scroll_extent': scrollable.position.maxScrollExtent,
      }),
    );
  });

  // -------------------------------------------------------------------------
  // 4 · 顶栏为什么不是玻璃：栏对身后的内容"完全无感"
  //
  // 判据不是"看起来像不像玻璃"，而是一个可证伪的因果：
  // 真玻璃必须**跟着身后的内容变**。真实 shell 是 Column[顶栏, 内容]，
  // 内容从 y=64 才开始，所以栏背后只有 Scaffold 实底 —— 无论下面放什么，
  // 栏的像素都一模一样。换成"内容滚到栏下"的 Stack 布局，同一套玻璃就会变。
  // -------------------------------------------------------------------------
  testWidgets('顶栏玻璃的量化：Column 布局下栏对内容无感（假玻璃），内容滚到栏下才真采样', (tester) async {
    final boundary = GlobalKey();
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = buildAppTheme(Brightness.light);

    Widget app(Widget body) => RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        theme: theme,
        home: Scaffold(body: body),
      ),
    );

    // 真实 shell 的布局：顶栏在 Column 里，内容在它下面。
    Widget columnShell(Widget topBar, Widget behind) => app(
      Column(
        children: [
          SizedBox(height: kGlassTopBarHeight, child: topBar),
          Expanded(child: behind),
        ],
      ),
    );

    // "内容滚到栏下"的样子：底铺满整块 body，顶栏叠在它上面。
    Widget stackShell(Widget topBar, Widget behind) => app(
      Stack(
        children: [
          Positioned.fill(child: behind),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SizedBox(height: kGlassTopBarHeight, child: topBar),
          ),
        ],
      ),
    );

    const barRect = Rect.fromLTWH(0, 0, 1440, 64);
    const flat = ColoredBox(color: Color(0xFFF4F6FB));
    const glassBar = GlassTopBar(
      backdrop: GlassTopBarBackdrop.content,
      child: SizedBox.expand(),
    );
    const opaqueBar = GlassTopBar(child: SizedBox.expand());

    Future<_Capture> shoot(Widget scene) async {
      await tester.pumpWidget(scene);
      await tester.pumpAndSettle();
      return _shoot(tester, boundary);
    }

    final columnFlat = await shoot(columnShell(glassBar, flat));
    final columnBusy = await shoot(
      columnShell(glassBar, const _BusyBackdrop()),
    );
    final stackFlat = await shoot(stackShell(glassBar, flat));
    final stackBusy = await shoot(stackShell(glassBar, const _BusyBackdrop()));
    final opaqueFlat = await shoot(columnShell(opaqueBar, flat));
    final opaqueBusy = await shoot(
      columnShell(opaqueBar, const _BusyBackdrop()),
    );

    final columnDiff = _diffCount(
      columnFlat.rgba,
      columnBusy.rgba,
      columnFlat.width,
      columnFlat.height,
      within: barRect,
    );
    final stackDiff = _diffCount(
      stackFlat.rgba,
      stackBusy.rgba,
      stackFlat.width,
      stackFlat.height,
      within: barRect,
    );
    final opaqueDiff = _diffCount(
      opaqueFlat.rgba,
      opaqueBusy.rgba,
      opaqueFlat.width,
      opaqueFlat.height,
      within: barRect,
    );

    final columnColor = _averageColor(columnFlat, barRect);
    final stackDark = _averageColor(stackBusy, barRect);
    final stackLight = _averageColor(stackFlat, barRect);

    _recordProbe({
      'scene': 'topbar-glass-proof',
      'probe_rect': <int>[0, 0, 1440, 64],
      'column_layout_glass_diff_px_flat_vs_busy_content': columnDiff,
      'stack_layout_glass_diff_px_flat_vs_busy_content': stackDiff,
      'opaque_bar_diff_px_flat_vs_busy_content': opaqueDiff,
      'column_glass_average': _hex(columnColor),
      'stack_glass_over_flat_average': _hex(stackLight),
      'stack_glass_over_busy_average': _hex(stackDark),
      'column_glass_edge_energy': _round2(_edgeEnergy(columnBusy, barRect)),
      'verdict':
          'Column 布局下栏对内容无感（$columnDiff px 差）→ 玻璃只会退化成'
          '半透明染色，契约禁止；内容滚到栏下时同一套玻璃会跟着内容变'
          '（$stackDiff px 差）。',
    });

    if (_baselineMode) return;

    // 1) 真实 shell 的布局：栏对身后的内容完全无感 —— 这里的"玻璃"没有采样。
    expect(columnDiff, 0);
    // 2) 不透明顶栏同样无感（这是它现在该有的行为）。
    expect(opaqueDiff, 0);
    // 3) 内容真在栏下时，同一套玻璃会跟着内容变：这才是玻璃。
    expect(stackDiff, greaterThan(1000));
  });

  // -------------------------------------------------------------------------
  // 5 · 亮色 dialog：玻璃 + 轻 barrier，成对截图与对比度数字
  // -------------------------------------------------------------------------
  testWidgets('亮色：续播选择 dialog 的玻璃 before/after + 遮罩分档 + 文字对比度', (tester) async {
    final boundary = GlobalKey();
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final choices = [
      for (var i = 0; i < 3; i++)
        HistoryProgressChoice(
          sourceLabel: i == 0 ? '本站' : '备用站 $i',
          isOwnSite: i == 0,
          lineFlag: 'line-$i',
          episodeIndex: i,
          episodeName: '第 ${i + 1} 集',
          positionMs: 600000 + i * 1000,
          durationMs: 1440000,
          updatedAt: DateTime(2026, 11, 20, 20, i).millisecondsSinceEpoch,
        ),
    ];

    final theme = buildAppTheme(Brightness.light);
    await tester.pumpWidget(
      _hostApp(
        theme: theme,
        boundary: boundary,
        host: _DialogHost(
          label: '打开续播选择',
          open: (context) => showHistoryProgressPicker(
            context,
            choices: choices,
            nowMs: DateTime(2026, 11, 26, 12).millisecondsSinceEpoch,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-dialog')));
    await tester.pumpAndSettle();

    final capture = await _shoot(tester, boundary);
    await _save(
      tester,
      capture,
      '${_captureDir().path}/${_shotName('light-history-dialog')}.png',
    );

    if (_baselineMode) return;

    final scheme = theme.colorScheme;
    expect(tester.takeException(), isNull);
    // 真玻璃：树里确实有 BackdropFilter（半透明假玻璃做不到这一点）。
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color,
      AppGlassBarrier.dialogLight,
    );

    // 面板底取样：标题右侧的空白区（避开文字与小色块）。
    final panelRect = Rect.fromLTWH(430, 300, 200, 40);
    final panel = _averageColor(capture, panelRect);
    final captionAsIs = _contrast(scheme.onSurfaceVariant, panel);
    final captionRemedy = _contrast(scheme.onSurface, panel);
    final title = _contrast(scheme.onSurface, panel);
    _recordProbe({
      'scene': 'light-history-dialog',
      'panel': _hex(panel),
      'barrier': _hex(AppGlassBarrier.dialogLight),
      'title_onSurface_contrast': _round2(title),
      'caption_onSurfaceVariant_contrast': _round2(captionAsIs),
      'caption_onSurface_contrast': _round2(captionRemedy),
      'threshold': 4.5,
      'caption_asIs_pass': captionAsIs >= 4.5,
      'caption_remedy_pass': captionRemedy >= 4.5,
      'edge_energy': _round2(_edgeEnergy(capture, panelRect)),
    });
    expect(title, greaterThanOrEqualTo(4.5));
    // 补救后的数字必须过线（玻璃上的说明文字改用 onSurface）。
    expect(captionRemedy, greaterThanOrEqualTo(4.5));
  });

  // -------------------------------------------------------------------------
  // 6 · 暗色 dialog：是玻璃、遮罩与改动前一致、面板外逐像素等于基线
  // -------------------------------------------------------------------------
  testWidgets('暗色：续播选择 dialog 是玻璃、面板外与改动前逐像素一致', (tester) async {
    final boundary = GlobalKey();
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final choices = [
      HistoryProgressChoice(
        sourceLabel: '本站',
        isOwnSite: true,
        lineFlag: 'line-0',
        episodeIndex: 0,
        episodeName: '第 1 集',
        positionMs: 600000,
        durationMs: 1440000,
        updatedAt: DateTime(2026, 11, 20, 20).millisecondsSinceEpoch,
      ),
    ];
    final theme = buildAppTheme(Brightness.dark);
    await tester.pumpWidget(
      _hostApp(
        theme: theme,
        boundary: boundary,
        host: _DialogHost(
          label: '打开续播选择',
          open: (context) => showHistoryProgressPicker(
            context,
            choices: choices,
            nowMs: DateTime(2026, 11, 26, 12).millisecondsSinceEpoch,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-dialog')));
    await tester.pumpAndSettle();

    final capture = await _shoot(tester, boundary);
    final path = '${_baselineDir().path}/dark-history-dialog.png';
    if (_baselineMode) {
      await _save(tester, capture, path);
    } else {
      await _save(
        tester,
        capture,
        '${_captureDir().path}/dark-history-dialog-current.png',
      );
    }

    if (_baselineMode) return;

    // 暗色现在也是玻璃（ink-1）：面板里必须有 BackdropFilter。
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    // 遮罩仍是 Material 默认值 —— 这是「面板外逐像素不变」的机制。
    expect(
      tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color,
      Colors.black54,
    );
    // 面板换成了玻璃壳：材质由 GlassSurface 承担，不再是 dialogTheme 的实底。
    expect(find.byType(GlassAlertDialog), findsOneWidget);
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(
      find.byKey(const ValueKey('history-progress-dialog')),
      findsOneWidget,
    );

    final baselinePng = await tester.runAsync(() => File(path).readAsBytes());
    final baseline = await _rgbaOfPng(tester, baselinePng!);
    // 面板本身允许变（它从实底变成了玻璃）；面板外必须与改动前逐像素一致。
    final panelRect = tester.getRect(
      find.byKey(const ValueKey('history-progress-dialog')),
    );
    final outside = _diffOutside(
      baseline,
      capture.rgba,
      capture.width,
      capture.height,
      panelRect.inflate(1),
    );
    final inside = _diffCount(
      baseline,
      capture.rgba,
      capture.width,
      capture.height,
      within: panelRect,
    );
    _recordProbe({
      'scene': 'dark-history-dialog',
      'panel_rect': <int>[
        panelRect.left.round(),
        panelRect.top.round(),
        panelRect.width.round(),
        panelRect.height.round(),
      ],
      'diff_pixels_outside_panel': outside,
      'diff_pixels_inside_panel': inside,
      'threshold_outside': 0,
    });
    expect(outside, 0, reason: '暗色 dialog 面板外必须逐像素不变，实际差 $outside px');
    expect(inside, greaterThan(0), reason: '面板本身应当已经变成玻璃（允许变）');
  });

  // -------------------------------------------------------------------------
  // 7 · 浮层（sheet）：亮色玻璃、暗色也是玻璃；浮层外逐像素等于基线
  // -------------------------------------------------------------------------
  testWidgets('浮层：亮色玻璃 + 遮罩分档；暗色玻璃、浮层外逐像素等于基线', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);
    final lightKey = GlobalKey();
    final darkKey = GlobalKey();

    Future<_Capture> openSheet(
      Brightness brightness,
      GlobalKey boundary,
    ) async {
      final theme = buildAppTheme(brightness);
      await tester.pumpWidget(
        _hostApp(
          theme: theme,
          boundary: boundary,
          host: _DialogHost(
            label: '打开换源',
            open: (context) => showSourceSwapSheet(
              context,
              keyword: '沙丘',
              searchListenable: notifier,
              outcomeOf: () => null,
              onSearch: (_) async {},
              onProbe: (_) async => throw UnimplementedError(),
            ),
          ),
        ),
      );
      // 浮层在"等结果"态里挂着无限动画的进度圈，pumpAndSettle 永远不收敛；
      // 这里按固定帧推进，前后两次跑的帧序列一致，截图才可比。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('open-dialog')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      return _shoot(tester, boundary);
    }

    final light = await openSheet(Brightness.light, lightKey);
    await _save(
      tester,
      light,
      '${_captureDir().path}/${_shotName('light-source-swap-sheet')}.png',
    );
    if (!_baselineMode) {
      // 玻璃是浮层本体的**外层**（壳在里面填色），所以找祖先而不是子孙。
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('source-swap-sheet')),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
      final scheme = buildAppTheme(Brightness.light).colorScheme;
      final panel = _averageColor(
        light,
        const Rect.fromLTWH(300, 500, 400, 200),
      );
      _recordProbe({
        'scene': 'light-source-swap-sheet',
        'panel': _hex(panel),
        'caption_onSurfaceVariant_contrast': _round2(
          _contrast(scheme.onSurfaceVariant, panel),
        ),
        'caption_onSurface_contrast': _round2(
          _contrast(scheme.onSurface, panel),
        ),
        'threshold': 4.5,
      });
      expect(
        tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color,
        AppGlassBarrier.dialogLight,
      );
    }

    final dark = await openSheet(Brightness.dark, darkKey);
    final darkPath = '${_baselineDir().path}/dark-source-swap-sheet.png';
    if (_baselineMode) {
      await _save(tester, dark, darkPath);
    } else {
      await _save(
        tester,
        dark,
        '${_captureDir().path}/dark-source-swap-sheet-current.png',
      );
    }

    if (_baselineMode) return;

    // 暗色浮层本体是玻璃（ink-1）：BackdropFilter 是它的祖先。
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('source-swap-sheet')),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    // 遮罩仍是既有的 scrim@0.42 —— 这是「面板外逐像素不变」的机制。
    final darkScheme = buildAppTheme(Brightness.dark).colorScheme;
    expect(
      tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color,
      darkScheme.scrim.withValues(alpha: 0.42),
    );

    final baselinePng = await tester.runAsync(
      () => File(darkPath).readAsBytes(),
    );
    final baseline = await _rgbaOfPng(tester, baselinePng!);
    // 浮层本体允许变；浮层之外必须与改动前逐像素一致。
    final sheetRect = tester.getRect(
      find.byKey(const ValueKey('source-swap-sheet')),
    );
    final outside = _diffOutside(
      baseline,
      dark.rgba,
      dark.width,
      dark.height,
      sheetRect.inflate(1),
    );
    final inside = _diffCount(
      baseline,
      dark.rgba,
      dark.width,
      dark.height,
      within: sheetRect,
    );
    _recordProbe({
      'scene': 'dark-source-swap-sheet',
      'sheet_rect': <int>[
        sheetRect.left.round(),
        sheetRect.top.round(),
        sheetRect.width.round(),
        sheetRect.height.round(),
      ],
      'diff_pixels_outside_sheet': outside,
      'diff_pixels_inside_sheet': inside,
      'threshold_outside': 0,
    });
    expect(outside, 0, reason: '暗色浮层之外必须逐像素不变，实际差 $outside px');
    expect(inside, greaterThan(0), reason: '浮层本体应当已经变成玻璃（允许变）');
  });

  tearDownAll(() async {
    if (_probes.isEmpty) return;
    final file = File('${_sddDir().path}/probes.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_probes),
    );
  });
}
