// P1 取证测试：3 个 theme 表面键能不能承载「玻璃」。
//
// 这份测试要证的不是「我调了参」，而是三个可以用像素复核的事实：
//  1. appBarTheme.backgroundColor / cardTheme.color / dialogTheme.backgroundColor
//     是绘制数据（Color），挂不上 BackdropFilter —— 用 widget 树断言，不用嘴说。
//  2. 把那个 Color 改成半透明，得到的不是玻璃：条纹背景照原样透出来（边缘能量量化）。
//  3. 真玻璃（GlassSurface）挂进去之后，同样的场景里背景只剩色块、没有结构。
//
// 只用 Material / dart:ui 与合成底图，不引用 lib/ui/style_spike/ 的一次性资产。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/glass_surface.dart';
import 'package:webhtv_pc/ui/history_progress_picker.dart';
import 'package:webhtv_pc/ui/source_swap_sheet.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

import 'support/test_fonts.dart';

const String _family = 'FixtureCJK';
const Size _viewport = Size(1440, 900);

// ---------------------------------------------------------------------------
// 取证落盘
// ---------------------------------------------------------------------------

Directory _captureDir() {
  var dir = Directory.current;
  for (var hop = 0; hop < 8; hop++) {
    final candidate = "${dir.path}/.superpowers/sdd/2026-11-26-style-spike";
    if (Directory(candidate).existsSync()) {
      return Directory("$candidate/pilot-1/captures")
        ..createSync(recursive: true);
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('.superpowers/sdd/2026-11-26-style-spike/pilot-1/captures')
    ..createSync(recursive: true);
}

// ---------------------------------------------------------------------------
// 合成底图：不是产品素材，只用来给玻璃提供「可采样的背景」
// ---------------------------------------------------------------------------

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7FA8D8), Color(0xFF2E3E63)],
        ).createShader(rect),
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.62, size.height * 0.10, 380, 300),
      Paint()..color = const Color(0xFFF0B429),
    );
    canvas.drawCircle(
      Offset(size.width * 0.18, size.height * 0.72),
      220,
      Paint()..color = const Color(0xFF2AE7FF),
    );
    canvas.drawCircle(
      Offset(size.width * 0.78, size.height * 0.80),
      180,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    // 6px 高频条纹（只铺左半）：玻璃压得住它，半透明色压不住。
    for (var x = 0.0; x < size.width / 2; x += 12) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 6, size.height),
        Paint()..color = const Color(0xCC000000),
      );
      canvas.drawRect(
        Rect.fromLTWH(x + 6, 0, 6, size.height),
        Paint()..color = const Color(0xCCFFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => false;
}

Widget _backdrop({bool veil = false}) => Stack(
  fit: StackFit.expand,
  children: [
    const CustomPaint(painter: _BackdropPainter()),
    // 配置壁纸那一套真实垫底：壁纸之上永远有一层由底色染出的纱（亮色 0.90）。
    if (veil) ColoredBox(color: AppPalette.dayGround.withValues(alpha: 0.90)),
  ],
);

// ---------------------------------------------------------------------------
// 场景：同一份内容、同一几何，「现状」与「玻璃」是唯一变量
// ---------------------------------------------------------------------------

const Key _probeKey = Key('probe');
const Key _dialogProbeKey = Key('probe-dialog');

Widget _panelContent(
  ThemeData theme,
  String title,
  String body, {
  Key probeKey = _probeKey,
}) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: [
    Text(title, style: theme.textTheme.titleMedium),
    const SizedBox(height: 8),
    Text(body, style: theme.textTheme.bodyMedium),
    const SizedBox(height: 8),
    Text(
      '12px 说明文字 · 采样窗口',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
    const SizedBox(height: 6),
    SizedBox(key: probeKey, width: 240, height: 24),
  ],
);

Widget _scene(
  ThemeData theme,
  Widget panel, {
  Widget? appBar,
  bool extendBodyBehindAppBar = false,
  bool veilBackdrop = false,
}) => Scaffold(
  extendBodyBehindAppBar: extendBodyBehindAppBar,
  appBar: appBar as PreferredSizeWidget?,
  body: Stack(
    children: [
      Positioned.fill(child: _backdrop(veil: veilBackdrop)),
      Positioned.fill(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: panel,
          ),
        ),
      ),
    ],
  ),
);

Widget _app(ThemeData theme, GlobalKey boundary, Widget home) => MaterialApp(
  debugShowCheckedModeBanner: false,
  // 关掉 200ms 主题过渡：否则会拍到「暗色正在变亮」的中间帧。
  themeAnimationDuration: Duration.zero,
  theme: theme,
  builder: (context, child) => RepaintBoundary(key: boundary, child: child!),
  home: home,
);

/// 取证专用主题：把已注册的 CJK 字体设成主字族。
///
/// 只注册字体不够：`flutter test` 的默认字族会把中文画成方块，而顶栏/对话框/按钮
/// 的文字样式是 `buildAppTheme` 构建时捕获的副本，不跟着 `textTheme.apply` 走。
/// 这里只补字族，不改任何取值。
ThemeData _captureTheme(Brightness brightness) {
  final base = buildAppTheme(brightness);
  final text = base.textTheme.apply(
    fontFamily: _family,
    fontFamilyFallback: const [_family],
  );
  final label = base.textTheme.labelLarge?.copyWith(fontFamily: _family);
  return base.copyWith(
    textTheme: text,
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _family),
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
        fontFamily: _family,
      ),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: base.dialogTheme.titleTextStyle?.copyWith(
        fontFamily: _family,
      ),
      contentTextStyle: base.dialogTheme.contentTextStyle?.copyWith(
        fontFamily: _family,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base.outlinedButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(label),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: base.chipTheme.labelStyle?.copyWith(fontFamily: _family),
      secondaryLabelStyle: base.chipTheme.secondaryLabelStyle?.copyWith(
        fontFamily: _family,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// 取证工具
// ---------------------------------------------------------------------------

class _Capture {
  _Capture(this.png, this.rgba, this.width, this.height);

  final Uint8List png;
  final ByteData rgba;
  final int width;
  final int height;
}

Future<_Capture> _shoot(WidgetTester tester, GlobalKey key, String name) async {
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
  final file = File("${_captureDir().path}/$name.png");
  await tester.runAsync(() => file.writeAsBytes(capture!.png));
  return capture!;
}

double _lumAt(ByteData rgba, int width, int x, int y) {
  final i = (y * width + x) * 4;
  return 0.2126 * rgba.getUint8(i) +
      0.7152 * rgba.getUint8(i + 1) +
      0.0722 * rgba.getUint8(i + 2);
}

/// 探针区与它右侧一像素的平均亮度差。对平滑渐变（tint / sheen）不敏感，
/// 只量「结构」：条纹在就高，被模糊掉就接近 0。
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

/// 面板平均色的亮度差：用来证明玻璃确实换了表面，而不是「什么都没变」。
double _delta(Color a, Color b) =>
    ((a.r - b.r) * 255).abs() +
    ((a.g - b.g) * 255).abs() +
    ((a.b - b.b) * 255).abs();

final List<Map<String, Object?>> _probes = <Map<String, Object?>>[];

void _record(
  String scene,
  String shot,
  Rect rect,
  Color bg,
  Color fg,
  double edge,
) {
  _probes.add(<String, Object?>{
    'scene': scene,
    'shot': shot,
    'probe': <int>[
      rect.left.round(),
      rect.top.round(),
      rect.width.round(),
      rect.height.round(),
    ],
    'bg': _hex(bg),
    'fg': _hex(fg),
    'caption_contrast': _round2(_contrast(fg, bg)),
    'caption_threshold': 4.5,
    'caption_pass': _contrast(fg, bg) >= 4.5,
    'edge_energy': _round2(edge),
  });
}

// ---------------------------------------------------------------------------
// glow-1 取证：落盘、像素工具与「真实浮层」场景
//
// 与 ink-1 同一套口径（1440×900 / pixelRatio 1 / median 色 / 对比度公式），
// 只是这一轮的变量是**渐变的垂直跨度**，不是 alpha。
// ---------------------------------------------------------------------------

Directory _glowDir() {
  var dir = Directory.current;
  for (var hop = 0; hop < 8; hop++) {
    final candidate = "${dir.path}/.superpowers/sdd/2026-11-26-style-spike";
    if (Directory(candidate).existsSync()) {
      final glow = Directory("$candidate/glow-1");
      Directory("${glow.path}/captures").createSync(recursive: true);
      return glow;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  final fallback = Directory('.superpowers/sdd/2026-11-26-style-spike/glow-1');
  Directory("${fallback.path}/captures").createSync(recursive: true);
  return fallback;
}

/// 基线轮（GLOW1_BASELINE=1）只落 `-before.png`，不跑断言：
/// 断言轮绝不覆盖 before，否则就是自己跟自己比。
final bool _glowBaselineMode = Platform.environment['GLOW1_BASELINE'] == '1';

final List<Map<String, Object?>> _glowProbes = <Map<String, Object?>>[];

String _glowCapturePath(String stem) =>
    '${_glowDir().path}/captures/$stem-${_glowBaselineMode ? 'before' : 'after'}.png';

Future<_Capture> _glowShoot(WidgetTester tester, GlobalKey key) async {
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

Future<void> _glowSave(
  WidgetTester tester,
  _Capture capture,
  String path,
) async {
  await tester.runAsync(() => File(path).writeAsBytes(capture.png));
}

Future<_Capture> _glowRead(WidgetTester tester, String path) async {
  final capture = await tester.runAsync(() async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final rgba = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    final width = frame.image.width;
    final height = frame.image.height;
    frame.image.dispose();
    codec.dispose();
    return _Capture(bytes, rgba!, width, height);
  });
  return capture!;
}

int _glowDiffCount(_Capture a, _Capture b) {
  var diff = 0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final i = (y * a.width + x) * 4;
      if (a.rgba.getUint8(i) != b.rgba.getUint8(i) ||
          a.rgba.getUint8(i + 1) != b.rgba.getUint8(i + 1) ||
          a.rgba.getUint8(i + 2) != b.rgba.getUint8(i + 2)) {
        diff++;
      }
    }
  }
  return diff;
}

String _glowSha(_Capture c) => sha256.convert(c.png).toString();

double _srgb(Color c) => 255 * (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b);

/// 探针区的中位色 + 有多少像素明显偏离中位色（偏离高说明区里有字形）。
class _Band {
  _Band(this.color, this.outlierRatio, this.spread);

  final Color color;
  final double outlierRatio;
  final double spread;
}

_Band _band(_Capture c, Rect rect) {
  final rs = <int>[];
  final gs = <int>[];
  final bs = <int>[];
  final lums = <double>[];
  for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y++) {
    for (var x = rect.left.toInt(); x < rect.right.toInt(); x++) {
      final i = (y * c.width + x) * 4;
      final r = c.rgba.getUint8(i);
      final g = c.rgba.getUint8(i + 1);
      final b = c.rgba.getUint8(i + 2);
      rs.add(r);
      gs.add(g);
      bs.add(b);
      lums.add(0.2126 * r + 0.7152 * g + 0.0722 * b);
    }
  }
  int median(List<int> v) {
    final sorted = List<int>.of(v)..sort();
    return sorted[sorted.length ~/ 2];
  }

  final color = Color.fromARGB(255, median(rs), median(gs), median(bs));
  final base = 0.2126 * median(rs) + 0.7152 * median(gs) + 0.0722 * median(bs);
  final mean = lums.reduce((a, b) => a + b) / lums.length;
  var variance = 0.0;
  var outliers = 0;
  for (final l in lums) {
    variance += (l - mean) * (l - mean);
    if ((l - base).abs() > 24) outliers++;
  }
  return _Band(
    color,
    outliers / lums.length,
    math.sqrt(variance / lums.length),
  );
}

/// 逐行（1px 一条）取最坏的一行：辉光带里的文字，吃亏的是最亮的那一行，
/// 用一条 16px 的中位色带取中位数会把这个最坏值抹平。
double _worstRowContrast(_Capture c, Rect rect, Color ink) {
  var worst = double.infinity;
  for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y++) {
    final row = _band(c, Rect.fromLTWH(rect.left, y.toDouble(), rect.width, 1));
    final ratio = _contrast(ink, row.color);
    if (ratio < worst) worst = ratio;
  }
  return worst;
}

/// 解析后的文本样式：`Text.style` 往往只覆盖一部分，字号/字重来自主题继承，
/// 取 RichText 上真正用于绘制的那份，才能说清「这是不是 WCAG 大字」。
TextStyle _glowResolvedStyle(WidgetTester tester, Finder finder) {
  final rich = tester.widget<RichText>(
    find.descendant(of: finder, matching: find.byType(RichText)).first,
  );
  return rich.text.style ?? const TextStyle();
}

/// 真实暗色浮层的几何：1440×900 视口里 sheet 宽 min(1440-64, 1120) = 1120、
/// 高 min(900×0.86, 820) = 774、贴底、上圆角 14 —— 即 left 160 / top 126。
const Rect _glowSheetRect = Rect.fromLTWH(160, 126, 1120, 774);

/// 与真实浮层同一几何的玻璃面板：背后是纯白海报 × scrim 0.42（最坏底）。
/// 面板里不放任何文字 —— 量的是「文字会落在什么底上」，不是字形自己。
Widget _glowScanApp({
  required ThemeData theme,
  required GlobalKey boundary,
  required double span,
  required double wash,
}) {
  final scheme = theme.colorScheme;
  final dark = scheme.brightness == Brightness.dark;
  return RepaintBoundary(
    key: boundary,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      themeAnimationDuration: Duration.zero,
      theme: theme,
      home: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Color(0xFFFFFFFF))),
          Positioned.fill(
            child: ColoredBox(
              color: scheme.scrim.withValues(
                alpha: AppGlassBarrier.sheetScrimAlpha,
              ),
            ),
          ),
          Positioned(
            left: _glowSheetRect.left,
            top: _glowSheetRect.top,
            width: _glowSheetRect.width,
            height: _glowSheetRect.height,
            child: GlassSurface(
              padding: EdgeInsets.zero,
              rimAlpha: dark ? AppGlass.rimAlphaDark : AppGlass.rimAlphaLight,
              rimWash: wash,
              rimWashSpan: span,
              sheenAlpha: dark
                  ? AppGlass.sheenAlphaDark
                  : AppGlass.sheenAlphaLight,
              radius: 0,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.lg),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    ),
  );
}

class _GlowBrightPoster extends StatelessWidget {
  const _GlowBrightPoster();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFFFFFFFF),
    child: Center(
      child: Text(
        'POSTER',
        style: TextStyle(
          fontSize: 96,
          fontWeight: FontWeight.w700,
          color: Color(0xFFCFD5E0),
        ),
      ),
    ),
  );
}

class _GlowHost extends StatelessWidget {
  const _GlowHost({
    required this.label,
    required this.open,
    required this.backdrop,
  });

  final String label;
  final Future<Object?> Function(BuildContext context) open;
  final Widget backdrop;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) => Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            backdrop,
            Center(
              child: TextButton(
                key: const ValueKey('glow-open-panel'),
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

Widget _glowHostApp({
  required ThemeData theme,
  required GlobalKey boundary,
  required _GlowHost host,
}) {
  return RepaintBoundary(
    key: boundary,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      themeAnimationDuration: Duration.zero,
      theme: theme,
      home: host,
    ),
  );
}

/// 真实浮层：`source_swap_sheet`（壳就是 GlassSurface 本身，padding 0）。
Future<_Capture> _glowShootSheet(
  WidgetTester tester,
  ThemeData theme,
  GlobalKey boundary,
) async {
  final notifier = ValueNotifier<int>(0);
  try {
    await tester.pumpWidget(
      _glowHostApp(
        theme: theme,
        boundary: boundary,
        host: _GlowHost(
          backdrop: const _GlowBrightPoster(),
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
    // 浮层里有无限动画的进度圈：pumpAndSettle 不收敛，按固定帧推进，
    // 前后两轮跑帧序列一致，截图才可比。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('glow-open-panel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    return await _glowShoot(tester, boundary);
  } finally {
    notifier.dispose();
  }
}

/// 真实 dialog：`history_progress_picker`（左上是标题，下面是 12px 说明文字）。
Future<_Capture> _glowShootDialog(
  WidgetTester tester,
  ThemeData theme,
  GlobalKey boundary,
) async {
  final choices = [
    for (var i = 0; i < 2; i++)
      HistoryProgressChoice(
        sourceLabel: i == 0 ? '本站' : '备用站',
        isOwnSite: i == 0,
        lineFlag: 'line-$i',
        episodeIndex: i,
        episodeName: i == 0 ? '第 1 集' : '第 2 集',
        positionMs: 600000 + i * 1000,
        durationMs: 1440000,
        updatedAt: DateTime(2026, 11, 20, 20, i).millisecondsSinceEpoch,
      ),
  ];
  await tester.pumpWidget(
    _glowHostApp(
      theme: theme,
      boundary: boundary,
      host: _GlowHost(
        backdrop: const _GlowBrightPoster(),
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
  await tester.tap(find.byKey(const ValueKey('glow-open-panel')));
  await tester.pumpAndSettle();
  return await _glowShoot(tester, boundary);
}

void main() {
  setUpAll(() async {
    expectFontsAvailableOrSkip();
    await loadFixtureFonts();
  });

  // -------------------------------------------------------------------------
  // glow-1 · 跨度安全边界矩阵（run 2/3）
  //
  // `rimWashSpanDark = 0.05` 是按「面板高度的比例」定义的，那么它到底在哪些
  // 真实组合里成立？这里不推公式，直接把真实浮层放进出货的三个视口里跑：
  //   视口 1024×640 / 1440×900 / 1440×1200（第三个会撞到 820px 高度封顶）
  //   字号 1.0 / 1.5 / 2.0
  // 每个组合记录：面板实际高度、标题与说明文字顶坐标、跨度归零点、正文/次要
  // 文字最坏行对比度、是否溢出。断言只卡两条：12px 次要 ≥4.5、16px 粗体标题
  // ≥4.5（16px w600 按 WCAG 不算大字：大字是 18.66px 粗体 / 24px 常规）。
  // -------------------------------------------------------------------------
  testWidgets('glow-1 · 跨度矩阵：3 视口 × 3 字号的真实浮层安全边界', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    const viewports = <List<double>>[
      [1024, 640],
      [1440, 900],
      [1440, 1200],
    ];
    const scales = <double>[1.0, 1.5, 2.0];
    final rows = <Map<String, Object?>>[];
    final theme = _captureTheme(Brightness.dark);
    final scheme = theme.colorScheme;
    final glassInk = defaultSemanticColors(Brightness.dark).glassInkSecondary;

    for (final vp in viewports) {
      for (final scale in scales) {
        tester.view.physicalSize = Size(vp[0], vp[1]);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        // 每个组合换一把新 key：上一棵树的 ModalRoute（无限动画）不会被复用。
        final capture = await _glowShootSheet(tester, theme, GlobalKey());
        final errors = <String>[];
        while (true) {
          final error = tester.takeException();
          if (error == null) break;
          errors.add(error.toString().split('\n').first);
        }

        final sheetRect = tester.getRect(
          find.byKey(const ValueKey('source-swap-sheet')),
        );
        final captionRect = tester.getRect(find.text('当前：沙丘'));
        final titleRect = tester.getRect(find.text('换源'));
        final captionStyle = _glowResolvedStyle(tester, find.text('当前：沙丘'));
        final titleStyle = _glowResolvedStyle(tester, find.text('换源'));

        final stopPx = GlassSurface.rimWashSpanDark * sheetRect.height;
        final headerBand = Rect.fromLTWH(
          captionRect.right + 8,
          captionRect.top,
          80,
          captionRect.height,
        );
        final titleBand = Rect.fromLTWH(
          sheetRect.left + 300,
          titleRect.top,
          120,
          titleRect.height,
        );
        final headerMinor = _worstRowContrast(capture, headerBand, glassInk);
        final headerBody = _worstRowContrast(
          capture,
          headerBand,
          scheme.onSurface,
        );
        final titleBody = _worstRowContrast(
          capture,
          titleBand,
          scheme.onSurface,
        );
        final margin = captionRect.top - sheetRect.top - stopPx;

        rows.add(<String, Object?>{
          'viewport': '${vp[0].toInt()}x${vp[1].toInt()}',
          'text_scale': scale,
          'panel_rect_px': <double>[
            sheetRect.left,
            sheetRect.top,
            sheetRect.width,
            sheetRect.height,
          ],
          'panel_height_px': _round2(sheetRect.height),
          'title_top_offset_px': _round2(titleRect.top - sheetRect.top),
          'title_box_height_px': _round2(titleRect.height),
          'title_font': <String, Object?>{
            'fontSize': titleStyle.fontSize,
            'fontWeight': titleStyle.fontWeight?.value,
            'large_text_wcag':
                (titleStyle.fontSize ?? 0) >= 24 ||
                ((titleStyle.fontSize ?? 0) >= 18.66 &&
                    (titleStyle.fontWeight?.value ?? 400) >= 700),
          },
          'title_worst_body_ratio': _round2(titleBody),
          'header_top_offset_px': _round2(captionRect.top - sheetRect.top),
          'header_box_height_px': _round2(captionRect.height),
          'caption_font': <String, Object?>{
            'fontSize': captionStyle.fontSize,
            'fontWeight': captionStyle.fontWeight?.value,
          },
          'span_end_offset_px': _round2(stopPx),
          'margin_above_span_px': _round2(margin),
          'header_in_glow': margin < 0,
          'header_worst_minor_ratio': _round2(headerMinor),
          'header_worst_body_ratio': _round2(headerBody),
          'overflow_errors': errors,
        });
      }
    }

    File('${_glowDir().path}/span-matrix.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'viewport_label': 'physicalSize, devicePixelRatio 1',
        'rimWashSpanDark': GlassSurface.rimWashSpanDark,
        'rimWashDark': GlassSurface.rimWashDark,
        'rows': rows,
      }),
    );

    for (final row in rows) {
      final where = '${row['viewport']} @${row['text_scale']}';
      expect(
        row['header_worst_minor_ratio']! as double,
        greaterThanOrEqualTo(4.5),
        reason: '12px 次要文字在所有出货组合里都必须 ≥4.5（$where）',
      );
      expect(
        row['title_worst_body_ratio']! as double,
        greaterThanOrEqualTo(4.5),
        reason: '16px w700 标题按非大字处理，必须 ≥4.5（$where）',
      );
      expect(
        row['margin_above_span_px']! as double,
        greaterThan(0),
        reason: '头部行必须在跨度归零点之下（$where）',
      );
    }
  });

  tearDownAll(() {
    if (_probes.isEmpty) return;
    File("${_captureDir().path}/../probes.json").writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'viewport': '1440x900, pixelRatio 1',
        'probe_note': 'edge_energy = 探针区相邻像素平均亮度差；条纹还在=有结构，被模糊掉=接近 0',
        'probes': _probes,
      }),
    );
  });

  // ① token：取值必须等于 T1 的参数表，不许另定一套。
  test('AppGlass 取值 = T1 参数表', () {
    expect(AppGlass.blurSigmaLight, 20);
    expect(AppGlass.tintAlphaLight, 0.58);
    expect(AppGlass.saturationLight, 1.15);
    expect(AppGlass.radius, AppRadius.lg);
    expect(AppGlass.rimWidth, 1);
    // 暗色档：blur / tint / saturation 仍是 T1 那一份测量的另一半，继续锁死。
    expect(AppGlass.blurSigmaDark, 26);
    expect(AppGlass.tintAlphaDark, 0.42);
    expect(AppGlass.saturationDark, 1.35);
    // rim / sheen 在 ink-1 里按「12px 文字可读性」重新标定：
    // rim 0.34 → 0.60（加成 1px 边缘线）、sheen 0.10 → 0.03（扫光压到不压文字）。
    // glow-1 只改几何：暗色内衬的垂直跨度 50% → 5%，权重因此可以回到 0.34
    //（权重 × 跨度才是头部行吃到的白）。数字见 glow-1/report.md。
    expect(GlassSurface.rimWashLight, 0.55);
    expect(GlassSurface.rimWashDark, 0.34);
    // 亮色跨度是既有几何（冻结）；暗色是这一轮唯一的几何改动。
    expect(GlassSurface.rimWashSpanLight, 0.50);
    expect(GlassSurface.rimWashSpanDark, 0.05);
  });

  // ② 红线：暗色（以及亮色）的三个表面键仍是不透明原值 —— 本任务没动它们。
  test('三个表面键的亮/暗取值仍是改动前的原值', () {
    final dark = buildAppTheme(Brightness.dark);
    final light = buildAppTheme(Brightness.light);

    expect(dark.appBarTheme.backgroundColor, AppPalette.nightGround);
    expect(dark.cardTheme.color, AppPalette.nightSurface1);
    expect(dark.dialogTheme.backgroundColor, AppPalette.nightSurface3);

    expect(light.appBarTheme.backgroundColor, AppPalette.dayGround);
    expect(light.cardTheme.color, AppPalette.daySurface1);
    expect(light.dialogTheme.backgroundColor, AppPalette.daySurface3);

    for (final color in <Color?>[
      dark.appBarTheme.backgroundColor,
      dark.cardTheme.color,
      dark.dialogTheme.backgroundColor,
      light.appBarTheme.backgroundColor,
      light.cardTheme.color,
      light.dialogTheme.backgroundColor,
    ]) {
      expect(color, isNotNull);
      expect(color!.a, 1.0, reason: '任何一个键变成半透明，表面就不再是填色而是透底');
    }
  });

  // ③ 键本身挂不上玻璃：用 widget 树而不是嘴说。
  testWidgets('三个 theme 键都不产生 BackdropFilter', (tester) async {
    final theme = _captureTheme(Brightness.light);
    final boundary = GlobalKey();

    await tester.pumpWidget(
      _app(
        theme,
        boundary,
        _scene(
          theme,
          Card(child: _panelContent(theme, '卡片', 'cardTheme.color 只能填色')),
          appBar: AppBar(title: const Text('顶栏')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    showDialog<void>(
      context: tester.element(find.byType(Scaffold)),
      builder: (context) => const AlertDialog(title: Text('对话框')),
    );
    await tester.pumpAndSettle();

    // 顶栏 + 卡片 + 对话框都在树上，但一个模糊层都没有。
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(Card), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);

    // 把 GlassSurface 挂进去，模糊层才出现（这是唯一的实现方式）。
    await tester.pumpWidget(
      _app(
        theme,
        boundary,
        _scene(
          theme,
          Card(
            color: Colors.transparent,
            elevation: 0,
            child: GlassSurface(child: _panelContent(theme, '卡片', '玻璃在这里')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNWidgets(1));
  });

  // ④ 半透明色 ≠ 玻璃。
  testWidgets('半透明填色 vs 真玻璃：条纹穿透量化', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = _captureTheme(Brightness.light);
    final boundary = GlobalKey();

    Future<double> measure(Widget panel, String name) async {
      await tester.pumpWidget(_app(theme, boundary, _scene(theme, panel)));
      await tester.pumpAndSettle();
      final capture = await _shoot(tester, boundary, name);
      return _edgeEnergy(capture, tester.getRect(find.byKey(_probeKey)));
    }

    // 「把 cardTheme.color 改成半透明」的字面后果。
    final translucent = await measure(
      Card(
        color: theme.colorScheme.surface.withValues(
          alpha: AppGlass.tintAlphaLight,
        ),
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _panelContent(theme, '半透明卡片', 'cardTheme.color 改 alpha'),
        ),
      ),
      'probe-card-translucent',
    );

    final glass = await measure(
      Card(
        color: Colors.transparent,
        elevation: 0,
        child: GlassSurface(
          padding: const EdgeInsets.all(16),
          child: _panelContent(theme, '玻璃卡片', 'GlassSurface'),
        ),
      ),
      'probe-card-glass',
    );

    // ignore: avoid_print
    print("edge_energy: translucent=$translucent glass=$glass");
    expect(
      translucent,
      greaterThan(3.0),
      reason: '半透明填色会把 6px 条纹原样透出来，这就是假玻璃的量化形态',
    );
    expect(
      glass,
      lessThan(translucent * 0.2),
      reason: '真玻璃要把条纹压掉一个量级，否则 blur 没生效',
    );
  });

  // ⑤ 亮色顶栏成对出图。
  testWidgets('亮色：顶栏 before/after 成对截图', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = _captureTheme(Brightness.light);
    final boundary = GlobalKey();
    final means = <Color>[];

    Future<void> shoot(String name, {required bool glass}) async {
      await tester.pumpWidget(
        _app(
          theme,
          boundary,
          _scene(
            theme,
            // 卡片保持「现状」（主题驱动），让顶栏成为唯一变量。
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _panelContent(theme, '卡片 · 现状', '顶栏采样在 AppBar 内'),
              ),
            ),
            extendBodyBehindAppBar: true,
            appBar: AppBar(
              title: const Text('顶栏 · 玻璃试水'),
              backgroundColor: glass ? Colors.transparent : null,
              elevation: 0,
              flexibleSpace: glass
                  ? GlassSurface(
                      radius: 0,
                      padding: EdgeInsets.zero,
                      child: const SizedBox.expand(),
                    )
                  : null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final capture = await _shoot(tester, boundary, name);
      final bar = tester.getRect(find.byType(AppBar));
      final window = Rect.fromLTWH(
        bar.left + 320,
        bar.top + 8,
        bar.width - 720,
        bar.height - 16,
      );
      final bg = _averageColor(capture, window);
      means.add(bg);
      _record(
        'light-appbar',
        name,
        window,
        bg,
        theme.colorScheme.onSurface,
        _edgeEnergy(capture, window),
      );
    }

    await shoot('light-appbar-current', glass: false);
    await shoot('light-appbar-glass', glass: true);

    expect(
      _delta(means[0], means[1]),
      greaterThan(6.0),
      reason: '玻璃顶栏的采样色必须离开 surface，否则它还是那块不透明底',
    );
  });

  // ⑥ 亮色卡片成对出图。
  testWidgets('亮色：卡片 before/after 成对截图', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = _captureTheme(Brightness.light);
    final boundary = GlobalKey();
    final means = <Color>[];

    Future<void> shoot(
      String name, {
      required bool glass,
      bool veil = false,
    }) async {
      await tester.pumpWidget(
        _app(
          theme,
          boundary,
          _scene(
            theme,
            veilBackdrop: veil,
            glass
                ? Card(
                    color: Colors.transparent,
                    elevation: 0,
                    child: GlassSurface(
                      padding: const EdgeInsets.all(16),
                      child: _panelContent(theme, '卡片 · 玻璃', '背景色块透进面板'),
                    ),
                  )
                : Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: _panelContent(
                        theme,
                        '卡片 · 现状',
                        '不透明 surfaceContainerLow',
                      ),
                    ),
                  ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final capture = await _shoot(tester, boundary, name);
      final rect = tester.getRect(find.byKey(_probeKey));
      final bg = _averageColor(capture, rect);
      means.add(bg);
      _record(
        'light-card',
        name,
        rect,
        bg,
        theme.colorScheme.onSurfaceVariant,
        _edgeEnergy(capture, rect),
      );
    }

    await shoot('light-card-current', glass: false);
    await shoot('light-card-glass', glass: true);
    // 生产里有「配置壁纸 + 亮色 0.90 的纱」这一档：玻璃坐在它上面才是常态。
    await shoot('light-card-glass-veiled', glass: true, veil: true);

    expect(_delta(means[0], means[1]), greaterThan(6.0));
    // 玻璃上的 12px 说明文字（onSurfaceVariant）：有纱的那一档必须过 4.5:1。
    final veiled = _probes.last;
    expect(
      veiled['caption_pass'],
      isTrue,
      reason: '有纱时 ${veiled['bg']} 上的说明文字只有 ${veiled['caption_contrast']}:1',
    );
  });

  // ⑦ 亮色对话框成对出图 + barrier 对照。
  testWidgets('亮色：对话框 before/after 成对截图（含 barrier 对照）', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = _captureTheme(Brightness.light);
    final boundary = GlobalKey();
    final means = <Color>[];

    Future<void> shoot(
      String name, {
      required bool glass,
      Color? barrierColor,
      bool recordPage = false,
    }) async {
      await tester.pumpWidget(
        _app(
          theme,
          boundary,
          _scene(
            theme,
            Card(
              color: Colors.transparent,
              elevation: 0,
              child: _panelContent(theme, '卡片', '对话框采样在下面'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      showDialog<void>(
        context: tester.element(find.byType(Scaffold)),
        barrierColor: barrierColor,
        builder: (context) => glass
            ? Dialog(
                backgroundColor: Colors.transparent,
                elevation: 0,
                child: GlassSurface(
                  padding: const EdgeInsets.all(24),
                  child: _panelContent(
                    theme,
                    '对话框 · 玻璃',
                    'dialogTheme 只能给色，玻璃靠挂载',
                    probeKey: _dialogProbeKey,
                  ),
                ),
              )
            : AlertDialog(
                title: const Text('对话框 · 现状'),
                content: _panelContent(
                  theme,
                  '现状',
                  '不透明 surfaceContainerHigh',
                  probeKey: _dialogProbeKey,
                ),
              ),
      );
      await tester.pumpAndSettle();

      final capture = await _shoot(tester, boundary, name);
      final rect = tester.getRect(find.byKey(_dialogProbeKey));
      final bg = _averageColor(capture, rect);
      means.add(bg);
      _record(
        'light-dialog',
        name,
        rect,
        bg,
        theme.colorScheme.onSurfaceVariant,
        _edgeEnergy(capture, rect),
      );
      if (recordPage) {
        // 对话框脚下的页面（barrier 覆盖区）：barrier 若把它压暗，
        // 玻璃采到的就已经不是页面本色了。
        final page = Rect.fromLTWH(40, 720, 260, 140);
        _record(
          'light-dialog-barrier',
          name,
          page,
          _averageColor(capture, page),
          theme.colorScheme.onSurfaceVariant,
          _edgeEnergy(capture, page),
        );
      }
      Navigator.of(tester.element(find.byType(Navigator).last)).pop();
      await tester.pumpAndSettle();
    }

    await shoot('light-dialog-current', glass: false);
    await shoot('light-dialog-glass', glass: true, recordPage: true);
    await shoot(
      'light-dialog-glass-nobarrier',
      glass: true,
      barrierColor: Colors.transparent,
      recordPage: true,
    );

    expect(_delta(means[0], means[1]), greaterThan(6.0));
  });

  // ⑧ 暗色对照：主题没动，所以暗色只需证明「它还是它」。
  testWidgets('暗色：现状截图', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = _captureTheme(Brightness.dark);
    final boundary = GlobalKey();

    await tester.pumpWidget(
      _app(
        theme,
        boundary,
        _scene(
          theme,
          Card(child: _panelContent(theme, '卡片 · 暗色现状', '暗色不接玻璃')),
          appBar: AppBar(title: const Text('暗色顶栏 · 现状')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    showDialog<void>(
      context: tester.element(find.byType(Scaffold)),
      builder: (context) => AlertDialog(
        title: const Text('暗色对话框 · 现状'),
        content: _panelContent(
          theme,
          '现状',
          '与改动前一致',
          probeKey: _dialogProbeKey,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final capture = await _shoot(tester, boundary, 'dark-current');
    final rect = tester.getRect(find.byKey(_dialogProbeKey));
    _record(
      'dark-dialog',
      'dark-current',
      rect,
      _averageColor(capture, rect),
      theme.colorScheme.onSurfaceVariant,
      _edgeEnergy(capture, rect),
    );
  });

  // =========================================================================
  // glow-1 · 回收暗色玻璃「被上方照亮」的观感（渐变几何实验）
  //
  // ink-1 为了 12px 文字可读性把暗色内衬权重压到 0.04，代价是「表面那层光没了」
  // （rim 内衬 26.9 → 5.0、斜向扫光 34.9 → 5.0）。这一轮不动任何一个可读性数值，
  // 只改**几何**：把那层白光的垂直跨度从「面板高度的 50%」收到面板顶部一小条，
  // 于是权重可以往回加，而浮层头部行（面板顶部 50px）落在辉光之外。
  //
  // 「收窄到 5% 就够」不是结论而是假设：先量出头部行距面板顶部多少 px、面板多高，
  // 再把每一档 span 的逐行亮度剖面打出来，看辉光到底在哪一行结束。
  // =========================================================================
  testWidgets('glow-1 · 暗色内衬 span×wash 候选扫描（可读性 vs 上方辉光）', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = _captureTheme(Brightness.dark);
    final scheme = theme.colorScheme;
    final glassInk = defaultSemanticColors(Brightness.dark).glassInkSecondary;
    final boundary = GlobalKey();
    const panel = _glowSheetRect;

    Future<Map<String, Object?>> probe(double span, double wash) async {
      await tester.pumpWidget(
        _glowScanApp(theme: theme, boundary: boundary, span: span, wash: wash),
      );
      await tester.pumpAndSettle();
      final capture = await _glowShoot(tester, boundary);
      if (!_glowBaselineMode) {
        await _glowSave(
          tester,
          capture,
          '${_glowDir().path}/captures/scan-span$span-wash$wash.png',
        );
      }

      _Band rowAt(double yOff) => _band(
        capture,
        Rect.fromLTWH(panel.left + 500, panel.top + yOff, 120, 1),
      );

      final body = _band(
        capture,
        Rect.fromLTWH(panel.left + 540, panel.top + 374, 200, 40),
      );
      final header = _band(
        capture,
        Rect.fromLTWH(panel.left + 90, panel.top + 50, 80, 16),
      );
      final edgeA = rowAt(0);
      final edgeB = rowAt(1);
      final underLine = rowAt(8);
      final rimLine = _srgb(edgeA.color) >= _srgb(edgeB.color) ? edgeA : edgeB;
      final cornerTL = _band(
        capture,
        Rect.fromLTWH(panel.left + 30, panel.top + 6, 40, 10),
      );
      final cornerBR = _band(
        capture,
        Rect.fromLTWH(panel.right - 70, panel.bottom - 16, 40, 10),
      );
      // 浮层自带的「换源」标题落在 y∈[13,37]（1px 发丝线 + md=12 内边距 + 标题行）：
      // 辉光往回加时，第一个撞上的不是 50px 那条头部行，而是这块标题。
      var titleWorst = rowAt(13);
      for (var y = 14.0; y <= 37; y += 1) {
        final row = rowAt(y);
        if (_srgb(row.color) > _srgb(titleWorst.color)) titleWorst = row;
      }
      final rows = <double>[
        for (var y = 0; y <= 110; y++) _srgb(rowAt(y.toDouble()).color),
      ];
      var glowPeak = 0.0;
      for (var y = 4; y <= 28; y++) {
        if (rows[y] > glowPeak) glowPeak = rows[y];
      }
      // 斜向 sheen 单独量一次（取辉光带之下的一行），免得「上沿辉光」把
      // 「斜向扫光」这个指标灌高 —— 两个指标要能分开看。
      final cornerTLBelowGlow = _band(
        capture,
        Rect.fromLTWH(panel.left + 30, panel.top + 52, 40, 10),
      );
      final profile = <String, double>{
        for (final y in <int>[2, 6, 10, 14, 18, 24, 30, 38, 44, 50, 66, 100])
          'y+$y': _round2(rows[y]),
      };
      final bodyRatio = _contrast(scheme.onSurface, header.color);
      final minorRatio = _contrast(glassInk, header.color);
      return <String, Object?>{
        'span': span,
        'wash': wash,
        'header_panel': _hex(header.color),
        'header_outlier_ratio': _round2(header.outlierRatio),
        'header_body_ratio': _round2(bodyRatio),
        'header_minor_ratio': _round2(minorRatio),
        'header_pass': bodyRatio >= 4.5 && minorRatio >= 4.5,
        'title_panel': _hex(titleWorst.color),
        'title_onSurface_ratio': _round2(
          _contrast(scheme.onSurface, titleWorst.color),
        ),
        'glow_top_lift': _round2(_srgb(rowAt(2).color) - _srgb(body.color)),
        'glow_peak_lift': _round2(glowPeak - _srgb(body.color)),
        'sheen_delta_below_glow': _round2(
          _srgb(cornerTLBelowGlow.color) - _srgb(cornerBR.color),
        ),
        'rows': rows,
        'rim_lift_at_header_legacy': _round2(
          _srgb(header.color) - _srgb(body.color),
        ),
        'edge_line_step': _round2(
          _srgb(rimLine.color) - _srgb(underLine.color),
        ),
        'sheen_delta': _round2(_srgb(cornerTL.color) - _srgb(cornerBR.color)),
        'profile_srgb': profile,
      };
    }

    // 第一行是改动前的对照（白光铺到面板 50%，权重只能压到 0.04）；
    // 其余是 span × wash 网格 —— span 是这一轮唯一被授权的几何变量。
    const grid = <List<double>>[
      [0.50, 0.04],
      [0.05, 0.12],
      [0.05, 0.22],
      [0.05, 0.34],
      [0.08, 0.22],
      [0.10, 0.22],
    ];
    for (final candidate in grid) {
      final row = await probe(candidate[0], candidate[1]);
      row.remove('rows');
      _glowProbes.add(<String, Object?>{'scene': 'dark-glow-grid', ...row});
    }
    // 对照组：wash = 0（只剩 sheen + 染底 + 1px 边缘线）。用它证明 stop 之后
    // 那层白光是真的 0，不是「细水长流」的残留。
    final control = await probe(0.05, 0);
    final controlRows = control['rows']! as List<double>;
    control.remove('rows');
    _glowProbes.add(<String, Object?>{
      'scene': 'dark-glow-control',
      ...control,
    });
    // 交付值本身也量一遍，并卡住两条红线：头部行两种墨色 ≥4.5。
    final shipped = await probe(
      GlassSurface.rimWashSpanDark,
      GlassSurface.rimWashDark,
    );
    final shippedRows = shipped['rows']! as List<double>;
    final stopPx = (GlassSurface.rimWashSpanDark * _glowSheetRect.height)
        .ceil();
    var tailMax = 0.0;
    for (var y = stopPx + 2; y <= 110; y++) {
      final delta = (shippedRows[y] - controlRows[y]).abs();
      if (delta > tailMax) tailMax = delta;
    }
    shipped.remove('rows');
    _glowProbes.add(<String, Object?>{
      'scene': 'dark-glow-shipped',
      ...shipped,
    });
    _glowProbes.add(<String, Object?>{
      'scene': 'dark-glow-tail',
      'wash_span_pct': _round2(100 * GlassSurface.rimWashSpanDark),
      'panel_height_px': _glowSheetRect.height,
      'stop_px': stopPx,
      'rows_compared': 'y∈[${stopPx + 2},110]',
      'tail_max_delta_vs_nowash_srgb': _round2(tailMax),
      'note': 'stop 之后如果还有残留白光，这里的差值就不为 0',
    });
    expect(shipped['header_minor_ratio'], greaterThanOrEqualTo(4.5));
    expect(shipped['header_body_ratio'], greaterThanOrEqualTo(4.5));
    expect(
      tailMax,
      lessThanOrEqualTo(0.01),
      reason: '内衬渐变在 stop 之后必须完全透明，不许有长尾',
    );
  });

  // -------------------------------------------------------------------------
  // 真实浮层：头部行（「当前：沙丘」那一行，面板顶部 50px）的两个比值不许掉，
  // 并且用 before/after 两份落盘图直接比 —— 不靠 ink-1 的旧数字背书。
  // -------------------------------------------------------------------------
  testWidgets('glow-1 · 暗色 sheet：真实浮层头部行两个 ratio 不掉 + 前后截图', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = _captureTheme(Brightness.dark);
    final scheme = theme.colorScheme;
    final glassInk = defaultSemanticColors(Brightness.dark).glassInkSecondary;
    final boundary = GlobalKey();
    final capture = await _glowShootSheet(tester, theme, boundary);
    await _glowSave(tester, capture, _glowCapturePath('dark-sheet'));

    final sheetRect = tester.getRect(
      find.byKey(const ValueKey('source-swap-sheet')),
    );
    final captionRect = tester.getRect(find.text('当前：沙丘'));
    final titleRect = tester.getRect(find.text('换源'));

    Map<String, double> ratiosOf(_Capture shot) {
      final header = _band(
        shot,
        Rect.fromLTWH(
          captionRect.right + 8,
          captionRect.top,
          80,
          captionRect.height,
        ),
      );
      // 标题（16px）整行都落在新的辉光带里：取它逐行的最坏值。
      final titleBand = Rect.fromLTWH(
        titleRect.right + 40,
        titleRect.top,
        200,
        titleRect.height,
      );
      return <String, double>{
        'header_minor': _contrast(glassInk, header.color),
        'header_body': _contrast(scheme.onSurface, header.color),
        'title_onSurface': _worstRowContrast(shot, titleBand, scheme.onSurface),
      };
    }

    final after = ratiosOf(capture);
    final geometry = <String, Object?>{
      'sheet_rect_px': <double>[
        sheetRect.left,
        sheetRect.top,
        sheetRect.width,
        sheetRect.height,
      ],
      // 「收窄到 X% 够不够」的算式：头部行距面板顶部多少 px、占面板高度多少。
      'header_row_top_offset_px': _round2(captionRect.top - sheetRect.top),
      'header_row_top_offset_pct': _round2(
        100 * (captionRect.top - sheetRect.top) / sheetRect.height,
      ),
      'title_row_offset_px': _round2(titleRect.top - sheetRect.top),
      'wash_span_pct': _round2(100 * GlassSurface.rimWashSpanDark),
      'wash_end_offset_px': _round2(
        GlassSurface.rimWashSpanDark * sheetRect.height,
      ),
    };
    if (_glowBaselineMode) {
      _glowProbes.add(<String, Object?>{
        'scene': 'dark-sheet-glow',
        'phase': 'before',
        ...geometry,
        'header_minor': _round2(after['header_minor']!),
        'header_body': _round2(after['header_body']!),
        'title_onSurface': _round2(after['title_onSurface']!),
      });
      return;
    }
    final beforeCapture = await _glowRead(
      tester,
      '${_glowDir().path}/captures/dark-sheet-before.png',
    );
    final before = ratiosOf(beforeCapture);
    final diff = _glowDiffCount(beforeCapture, capture);
    _glowProbes.add(<String, Object?>{
      'scene': 'dark-sheet-glow',
      'phase': 'after',
      ...geometry,
      'header_minor_before': _round2(before['header_minor']!),
      'header_body_before': _round2(before['header_body']!),
      'header_minor_after': _round2(after['header_minor']!),
      'header_body_after': _round2(after['header_body']!),
      'title_onSurface_before': _round2(before['title_onSurface']!),
      'title_onSurface_after': _round2(after['title_onSurface']!),
      'diff_pixels_before_after': diff,
      'sha256_before': _glowSha(beforeCapture),
      'sha256_after': _glowSha(capture),
    });
    expect(after['header_minor']!, greaterThanOrEqualTo(4.58));
    expect(after['header_body']!, greaterThanOrEqualTo(5.23));
    expect(
      after['title_onSurface']!,
      greaterThanOrEqualTo(4.5),
      reason: '辉光加回去不许压掉浮层标题（换源）的可读性',
    );
    expect(
      after['header_minor']!,
      greaterThanOrEqualTo(before['header_minor']! - 0.005),
      reason: '头部行次要文字比值不许掉',
    );
    expect(
      after['header_body']!,
      greaterThanOrEqualTo(before['header_body']! - 0.005),
      reason: '头部行正文比值不许掉',
    );
    expect(diff, greaterThan(0), reason: '辉光几何改动必须在真实浮层上留下像素差');
  });

  testWidgets('glow-1 · 暗色 dialog：真实浮层 12px 说明文字不降 + 前后截图', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = _captureTheme(Brightness.dark);
    final scheme = theme.colorScheme;
    final glassInk = defaultSemanticColors(Brightness.dark).glassInkSecondary;
    final boundary = GlobalKey();
    final capture = await _glowShootDialog(tester, theme, boundary);
    await _glowSave(tester, capture, _glowCapturePath('dark-dialog'));

    // 玻璃面板本体的 rect：ValueKey('history-progress-dialog') 挂在包装组件上，
    // 它的 render object 是整块路由区域（1440×900），量不出面板边缘 ——
    // 面板 = Dialog 里那颗 GlassSurface。
    final panelRect = tester.getRect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(GlassSurface),
      ),
    );
    final captionRect = tester.getRect(find.text('同一部剧有多条可续播记录，选一条继续：'));
    final titleRect = tester.getRect(find.text('选择续播记录'));
    final titleStyle = _glowResolvedStyle(tester, find.text('选择续播记录'));
    final bandRect = Rect.fromLTWH(
      captionRect.right - 150,
      captionRect.top,
      150,
      captionRect.height,
    );

    Map<String, double> ratiosOf(_Capture shot) {
      final probe = _band(shot, bandRect);
      final titleBand = Rect.fromLTWH(
        titleRect.right + 40,
        titleRect.top,
        120,
        titleRect.height,
      );
      final topRow = _band(
        shot,
        Rect.fromLTWH(panelRect.right - 60, panelRect.top + 4, 40, 1),
      );
      return <String, double>{
        'caption_minor': _contrast(glassInk, probe.color),
        'title_onSurface': _worstRowContrast(shot, titleBand, scheme.onSurface),
        'top_row_srgb': _srgb(topRow.color),
      };
    }

    final after = ratiosOf(capture);
    final geometry = <String, Object?>{
      'panel_rect_px': <double>[
        panelRect.left,
        panelRect.top,
        panelRect.width,
        panelRect.height,
      ],
      'title_row_offset_px': _round2(titleRect.top - panelRect.top),
      // 大字判定：WCAG 大字线 = 24px 常规，或 18.66px 且字重 ≥700。
      'title_font': <String, Object?>{
        'fontSize': titleStyle.fontSize,
        'fontWeight': titleStyle.fontWeight?.value,
        'large_text_wcag':
            (titleStyle.fontSize ?? 0) >= 24 ||
            ((titleStyle.fontSize ?? 0) >= 18.66 &&
                (titleStyle.fontWeight?.value ?? 400) >= 700),
      },
      'caption_row_offset_px': _round2(captionRect.top - panelRect.top),
      'wash_end_offset_px': _round2(
        GlassSurface.rimWashSpanDark * panelRect.height,
      ),
    };
    if (_glowBaselineMode) {
      _glowProbes.add(<String, Object?>{
        'scene': 'dark-dialog-glow',
        'phase': 'before',
        ...geometry,
        'caption_minor': _round2(after['caption_minor']!),
        'title_onSurface': _round2(after['title_onSurface']!),
        'top_row_srgb': _round2(after['top_row_srgb']!),
      });
      return;
    }
    final beforeCapture = await _glowRead(
      tester,
      '${_glowDir().path}/captures/dark-dialog-before.png',
    );
    final before = ratiosOf(beforeCapture);
    final diff = _glowDiffCount(beforeCapture, capture);
    _glowProbes.add(<String, Object?>{
      'scene': 'dark-dialog-glow',
      'phase': 'after',
      ...geometry,
      'caption_minor_before': _round2(before['caption_minor']!),
      'caption_minor_after': _round2(after['caption_minor']!),
      'title_onSurface_before': _round2(before['title_onSurface']!),
      'title_onSurface_after': _round2(after['title_onSurface']!),
      'top_row_srgb_before': _round2(before['top_row_srgb']!),
      'top_row_srgb_after': _round2(after['top_row_srgb']!),
      'diff_pixels_before_after': diff,
      'sha256_before': _glowSha(beforeCapture),
      'sha256_after': _glowSha(capture),
    });
    expect(
      after['caption_minor']!,
      greaterThanOrEqualTo(before['caption_minor']! - 0.005),
      reason: '暗色 dialog 的 12px 说明文字比值不许掉',
    );
    expect(after['caption_minor']!, greaterThanOrEqualTo(6.4));
    expect(diff, greaterThan(0));
  });

  // -------------------------------------------------------------------------
  // 亮色红线：这一轮只改暗色档的几何，亮色必须逐像素不变。
  // 同一场景 before/after 两份落盘图直接比，并给出 sha256。
  // -------------------------------------------------------------------------
  testWidgets('glow-1 · 亮色：sheet / dialog / 面板逐字节不变（sha256）', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = _captureTheme(Brightness.light);
    final results = <String, Object?>{};

    // 每个场景换一把新的 GlobalKey：同一个 key 会让上一棵树的 ModalRoute
    //（浮层里有无限动画）被「复用」下来，pumpAndSettle 永远不收敛。
    Future<void> check(
      String stem,
      Future<_Capture> Function(GlobalKey key) shoot,
    ) async {
      final capture = await shoot(GlobalKey());
      await _glowSave(tester, capture, _glowCapturePath(stem));
      if (_glowBaselineMode) return;
      final before = await _glowRead(
        tester,
        '${_glowDir().path}/captures/$stem-before.png',
      );
      final diff = _glowDiffCount(before, capture);
      results['${stem}_diff_pixels'] = diff;
      results['${stem}_sha256_before'] = _glowSha(before);
      results['${stem}_sha256_after'] = _glowSha(capture);
      expect(diff, 0, reason: '亮色必须逐像素不变：改了暗色几何也不许漏到亮色');
    }

    await check('light-sheet', (key) => _glowShootSheet(tester, theme, key));
    await check('light-dialog', (key) => _glowShootDialog(tester, theme, key));
    await check('light-panel', (key) async {
      await tester.pumpWidget(
        _glowScanApp(
          theme: theme,
          boundary: key,
          span: GlassSurface.rimWashSpanLight,
          wash: GlassSurface.rimWashLight,
        ),
      );
      await tester.pumpAndSettle();
      return _glowShoot(tester, key);
    });
    _glowProbes.add(<String, Object?>{
      'scene': 'light-glow-identity',
      ...results,
    });
  });

  tearDownAll(() {
    if (_glowProbes.isEmpty) return;
    final name = _glowBaselineMode ? 'probes-before.json' : 'probes.json';
    File('${_glowDir().path}/$name').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'viewport': '1440x900, pixelRatio 1',
        'phase': _glowBaselineMode ? 'before' : 'after',
        'probes': _glowProbes,
      }),
    );
  });
}
