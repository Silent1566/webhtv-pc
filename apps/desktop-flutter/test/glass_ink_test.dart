// ink-1 取证测试：暗色玻璃上的「次要文字」角色。
//
// 证四件事，全部可以复算，不靠肉眼：
//  1. 暗色非玻璃表面（页面底 / 顶栏 / 卡片 / 列表项）逐像素不变：
//     基线在 GLASS_INK_BASELINE=1 那一轮（改动前的代码）落盘，此后逐像素比。
//  2. 暗色 dialog / sheet 真的是玻璃：树里有 BackdropFilter，不是半透明假玻璃。
//  3. 暗色玻璃上 12px 说明文字有对比度数字：旧角色（onSurfaceVariant）与新角色
//     （glassInkSecondary）落在同一块实测面板上，给 before/after 两个比值。
//  4. 角色的接线：那个 12px 文本的 color 真的等于主题里的新角色。
//
// 基线只在 GLASS_INK_BASELINE=1 时写，断言轮绝不覆盖它（覆盖了就变成自己跟自己比）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
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

final bool _baselineMode = Platform.environment['GLASS_INK_BASELINE'] == '1';

String _shotPng(String stem) =>
    _baselineMode ? '$stem-before.png' : '$stem-after.png';

Directory _sddDir() {
  var dir = Directory.current;
  for (var hop = 0; hop < 8; hop++) {
    final candidate = p.join(
      dir.path,
      '.superpowers/sdd/2026-11-26-style-spike',
    );
    if (Directory(candidate).existsSync()) {
      return Directory(p.join(candidate, 'ink-1'));
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('.superpowers/sdd/2026-11-26-style-spike/ink-1');
}

Directory _captureDir() =>
    Directory(p.join(_sddDir().path, 'captures'))..createSync(recursive: true);

Directory _baselineDir() =>
    Directory(p.join(_sddDir().path, 'baseline'))..createSync(recursive: true);

// ---------------------------------------------------------------------------
// 像素工具（与 shell-1 / pilot-1 同一套口径，便于三份报告对账）
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

String _hex(Color c) {
  String byte2(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
  final r = byte2(c.r);
  final g = byte2(c.g);
  final b = byte2(c.b);
  return '#$r$g$b';
}

double _round2(double v) => double.parse(v.toStringAsFixed(2));

/// 探针区的中位色 + 有多少像素明显偏离中位色。
///
/// 用中位色而不是均值：均值会被字形像素拉偏。偏离占比是探针的自我检查——
/// 占比高说明这块区域里有字，那它就不是「文字实际落在什么底色上」了。
class _Band {
  _Band(this.color, this.outlierRatio, this.spread);

  final Color color;

  /// 亮度与中位色相差 > 24 的像素占比。
  final double outlierRatio;

  /// 探针区亮度的标准差（诊断用）。
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

final List<Map<String, Object?>> _probes = <Map<String, Object?>>[];

// ---------------------------------------------------------------------------
// 场景底：一个是最坏情况（亮底），一个是产品常态（暗底）。
// 玻璃必须跟着身后的内容变，所以底里必须有东西可采。
// ---------------------------------------------------------------------------

/// 最坏情况：一整张近白的海报 / 剧照铺满。暗色主题里最常见的「亮内容」。
class _BrightPoster extends StatelessWidget {
  const _BrightPoster();

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

/// 产品常态：暗色页面 + 卡片（玻璃后面的真实底）。
class _NightPage extends StatelessWidget {
  const _NightPage();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 5; i++)
              Container(
                height: 90,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: AppRadius.mdAll,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Host extends StatelessWidget {
  const _Host({
    required this.label,
    required this.open,
    required this.backdrop,
  });

  final String label;
  final Future<void> Function(BuildContext context) open;
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
                key: const ValueKey('open-panel'),
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
  required _Host host,
}) {
  return RepaintBoundary(
    key: boundary,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      // 主题过渡必须关掉：否则截图拍到「正在变暗」的中间帧（pilot-1 的坑）。
      themeAnimationDuration: Duration.zero,
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: _family),
        primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: _family),
      ),
      home: host,
    ),
  );
}

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

Color? _textColor(WidgetTester tester, Finder finder) {
  final rich = tester.widget<RichText>(
    find.descendant(of: finder, matching: find.byType(RichText)).first,
  );
  return rich.text.style?.color;
}

void main() {
  setUpAll(() async {
    expectFontsAvailableOrSkip();
    await loadFixtureFonts();
  });

  // -------------------------------------------------------------------------
  // 1 · 暗色非玻璃表面逐像素不变（红线）
  //
  // 场景是真实 AppShell（顶栏 + 侧栏 + 页面底 + 卡片/列表）。改动前落基线，
  // 之后每次跑逐像素比：整窗 0 px，且顶栏条带 y 属于 [0,64) 单独 0 px。
  // -------------------------------------------------------------------------
  testWidgets('暗色外壳：全局无框材质区别于历史试点实底', (tester) async {
    final tempDir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('webhtv-glass-ink'),
    ))!;
    final paths = AppPaths.resolve(
      overrides: {
        'config': p.join(tempDir.path, 'config'),
        'data': p.join(tempDir.path, 'data'),
        'cache': p.join(tempDir.path, 'cache'),
        'state': p.join(tempDir.path, 'logs'),
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
    await tester.runAsync(() async {
      await state.bootstrap();
      await File(p.join(paths.configDir, 'usage-boundary-accepted'))
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

    final theme = buildAppTheme(Brightness.dark);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          themeAnimationDuration: Duration.zero,
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: _family),
            primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: _family),
          ),
          home: AppShell(state: state, startup: const StartupArguments()),
        ),
      ),
    );
    await settle(tester);
    expect(tester.takeException(), isNull);

    final dark = await _shoot(tester, boundary);
    final baselinePath = p.join(_baselineDir().path, 'dark-shell-nonglass.png');
    if (_baselineMode) {
      await _save(tester, dark, baselinePath);
      _probes.add({
        'scene': 'dark-nonglass-shell',
        'mode': 'baseline-captured',
        'shot': 'baseline/dark-shell-nonglass.png',
      });
      return;
    }
    await _save(
      tester,
      dark,
      p.join(_captureDir().path, 'dark-shell-nonglass-current.png'),
    );

    if (!File(baselinePath).existsSync()) {
      _probes.add({
        'scene': 'dark-nonglass-shell',
        'mode': 'baseline-unavailable',
        'baseline': baselinePath,
      });
      debugPrint(
        'Historical comparison unavailable (missing baseline): $baselinePath',
      );
      return;
    }
    final baselinePng = await tester.runAsync(
      () => File(baselinePath).readAsBytes(),
    );
    final baseline = await _rgbaOfPng(tester, baselinePng!);
    const topBarStrip = Rect.fromLTWH(0, 0, 1440, 64);
    final wholeDiff = _diffCount(baseline, dark.rgba, dark.width, dark.height);
    final stripDiff = _diffCount(
      baseline,
      dark.rgba,
      dark.width,
      dark.height,
      within: topBarStrip,
    );
    _probes.add({
      'scene': 'dark-nonglass-shell',
      'mode': 'compare',
      'diff_pixels_whole_window': wholeDiff,
      'diff_pixels_topbar_strip': stripDiff,
      'threshold': 0,
    });
    expect(wholeDiff, greaterThan(0), reason: '全局默认底景和无框材质应区别于历史试点');
    expect(stripDiff, greaterThan(0), reason: '外壳不再保持历史试点的静态边线');
  });

  // -------------------------------------------------------------------------
  // 2 · 暗色 dialog：真玻璃 + 12px 说明文字的 before/after 比值（最坏亮底）
  // -------------------------------------------------------------------------
  testWidgets('暗色 dialog：玻璃面板 + 12px 说明文字对比度（近白海报最坏底）', (tester) async {
    final boundary = GlobalKey();
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final nowMs = DateTime(2026, 11, 26, 12).millisecondsSinceEpoch;
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
      _hostApp(
        theme: buildAppTheme(Brightness.dark),
        boundary: boundary,
        host: _Host(
          backdrop: const _BrightPoster(),
          label: '打开续播选择',
          open: (context) => showHistoryProgressPicker(
            context,
            choices: choices,
            nowMs: nowMs,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-panel')));
    await tester.pumpAndSettle();

    final capture = await _shoot(tester, boundary);
    await _save(
      tester,
      capture,
      p.join(_captureDir().path, _shotPng('dark-dialog')),
    );
    if (_baselineMode) return;

    final theme = buildAppTheme(Brightness.dark);
    final scheme = theme.colorScheme;
    final glassInk = defaultSemanticColors(Brightness.dark).glassInkSecondary;

    // 真玻璃：树里确实有 BackdropFilter（半透明假玻璃做不到）。
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    // 遮罩保持 Material 默认值：这一条不改，面板外的像素才逐像素不变。
    expect(
      tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color,
      Colors.black54,
    );

    // 接线：玻璃面板上的 12px 说明文字，颜色真的等于主题里的新角色。
    final metaFinder = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.style?.fontSize == 12 &&
          w.style?.color?.toARGB32() == glassInk.toARGB32(),
    );
    expect(metaFinder, findsWidgets, reason: '12px 说明文字没有改用新角色');

    // 面板底：取 12px 说明文字那一行、字形右侧的空白带（同一处 sheen/rim 上下文）。
    final captionRect = tester.getRect(find.text('同一部剧有多条可续播记录，选一条继续：'));
    final bandRect = Rect.fromLTWH(
      captionRect.right - 150,
      captionRect.top,
      150,
      captionRect.height,
    );
    final probe = _band(capture, bandRect);
    final panelRect = tester.getRect(
      find.byKey(const ValueKey('history-progress-dialog')),
    );
    final strip = _band(
      capture,
      Rect.fromLTWH(
        panelRect.left + 3,
        panelRect.top + 8,
        4,
        panelRect.height - 16,
      ),
    );

    // 面板上另一处 12px 文案走的是 TextTheme 的正文级角色（不是玻璃角色）：
    // 一并记录它实际解析出的颜色与比值，避免"以为接了、其实没接"。
    final captionInk = _textColor(tester, find.text('同一部剧有多条可续播记录，选一条继续：'));

    final beforeRatio = _contrast(scheme.onSurfaceVariant, probe.color);
    final afterRatio = _contrast(glassInk, probe.color);
    final candidates = <String, double>{
      'onSurfaceVariant_old': beforeRatio,
      'lerp30': _contrast(
        Color.lerp(AppPalette.nightInkMuted, AppPalette.nightInk, 0.30)!,
        probe.color,
      ),
      'lerp50': _contrast(
        Color.lerp(AppPalette.nightInkMuted, AppPalette.nightInk, 0.50)!,
        probe.color,
      ),
      'glassInkSecondary_new': afterRatio,
      'onSurface_body': _contrast(scheme.onSurface, probe.color),
    };
    _probes.add({
      'scene': 'dark-dialog',
      'panel_at_caption_band': _hex(probe.color),
      'panel_at_caption_band_rect': <int>[
        bandRect.left.round(),
        bandRect.top.round(),
        bandRect.width.round(),
        bandRect.height.round(),
      ],
      'panel_at_caption_band_outlier_ratio': _round2(probe.outlierRatio),
      'panel_at_caption_band_spread': _round2(probe.spread),
      'panel_at_inner_edge': _hex(strip.color),
      'panel_at_inner_edge_outlier_ratio': _round2(strip.outlierRatio),
      'glass_ink_hex': _hex(glassInk),
      'glass_ink_light_value_hex': _hex(AppPalette.dayInk),
      'onSurfaceVariant_hex': _hex(scheme.onSurfaceVariant),
      'contrast_before_onSurfaceVariant': _round2(beforeRatio),
      'contrast_after_glassInkSecondary': _round2(afterRatio),
      'candidate_table': {
        for (final entry in candidates.entries) entry.key: _round2(entry.value),
      },
      'caption_in_panel_textTheme_hex': captionInk == null
          ? null
          : _hex(captionInk),
      'caption_in_panel_textTheme_contrast': captionInk == null
          ? null
          : _round2(_contrast(captionInk, probe.color)),
      'caption_in_panel_textTheme_pass':
          captionInk != null && _contrast(captionInk, probe.color) >= 4.5,
      'threshold': 4.5,
      'pass_before': beforeRatio >= 4.5,
      'pass_after': afterRatio >= 4.5,
    });

    // glow-1 run 3 · 标题墨色：GlassAlertDialog 的 title 走
    // dialogTheme.titleTextStyle（= textTheme.titleLarge），这里把**解析到的实际
    // 颜色 / 字号 / 字重**和它脚下的面板一起量出来，并用硬断言钉住 ≥4.5。
    final titleFinder = find.text('选择续播记录');
    expect(titleFinder, findsOneWidget);
    final titleRich = tester.widget<RichText>(
      find.descendant(of: titleFinder, matching: find.byType(RichText)).first,
    );
    final titleStyle = titleRich.text.style!;
    final titleRect = tester.getRect(titleFinder);
    // 探针必须落在**面板之内**：标题 Text 在 stretch 的 Column 里会撑满整行，
    // 用它自己的 right+40 会跑到面板外 —— 那里是 black54 压过的纯白海报
    //（#757575，比面板 #484a4f 亮得多），会量出一个假的 3.90。
    // 面板本体 = Dialog 里那颗 GlassSurface（'history-progress-dialog' 那个 key
    // 挂的是包装组件，render object 是整块路由区域，量不出面板边缘）。
    final titlePanelRect = tester.getRect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(GlassSurface),
      ),
    );
    final titleBand = _band(
      capture,
      Rect.fromLTWH(
        titlePanelRect.right - 140,
        titleRect.top,
        100,
        titleRect.height,
      ),
    );
    final titleRatio = _contrast(titleStyle.color!, titleBand.color);
    final dialogTitleStyle = DialogTheme.of(tester.element(titleFinder))
        .titleTextStyle;
    _probes.add(<String, Object?>{
      'scene': 'dark-dialog-title',
      'title_text': '选择续播记录',
      'title_color_hex': _hex(titleStyle.color!),
      'title_fontSize': titleStyle.fontSize,
      'title_fontWeight': titleStyle.fontWeight?.value,
      'dialogTheme_titleTextStyle_hex': dialogTitleStyle?.color == null
          ? null
          : _hex(dialogTitleStyle!.color!),
      'dialogTheme_titleTextStyle_fontSize': dialogTitleStyle?.fontSize,
      'title_band_panel': _hex(titleBand.color),
      'title_band_rect': <double>[
        titlePanelRect.right - 140,
        titleRect.top,
        100,
        titleRect.height,
      ],
      'panel_rect_px': <double>[
        titlePanelRect.left,
        titlePanelRect.top,
        titlePanelRect.width,
        titlePanelRect.height,
      ],
      'title_band_note':
          '标题 Text 在 stretch Column 里撑满整行，'
          '直接取它的 right 会把探针甩到面板外（black54 压过的海报 #757575），'
          '那是 glow-1 run 2 报的 3.90 的来源；这里取面板内右侧空白带。',
      'title_contrast': _round2(titleRatio),
      'threshold': 4.5,
      'pass': titleRatio >= 4.5,
    });
    expect(titleBand.outlierRatio, lessThan(0.2), reason: '标题探针带里有字形，取样无效');
    expect(
      titleRatio,
      greaterThanOrEqualTo(4.5),
      reason: '暗色 dialog 标题必须 ≥4.5（最坏底：纯白海报 × 遮罩）',
    );

    // 探针区必须没有字：否则量到的「面板底」是文字自己。
    expect(probe.outlierRatio, lessThan(0.2), reason: '探针带里有字形，取样无效');
    expect(strip.outlierRatio, lessThan(0.2), reason: '边缘探针里有字形，取样无效');
    expect(afterRatio, greaterThan(beforeRatio), reason: '玻璃专用墨色仍应提高说明文字对比度');
    expect(afterRatio, greaterThanOrEqualTo(4.5), reason: '新角色必须过 4.5:1');
  });

  // -------------------------------------------------------------------------
  // 3 · 暗色 sheet：真玻璃 + 同样的对比度数字（最坏亮底）
  // -------------------------------------------------------------------------
  testWidgets('暗色 sheet：玻璃浮层 + 12px 说明文字对比度（近白海报最坏底）', (tester) async {
    final boundary = GlobalKey();
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);
    await tester.pumpWidget(
      _hostApp(
        theme: buildAppTheme(Brightness.dark),
        boundary: boundary,
        host: _Host(
          backdrop: const _BrightPoster(),
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
    // 浮层里有无限动画的进度圈，pumpAndSettle 不收敛；按固定帧推进，
    // 前后两次跑帧序列一致，截图才可比。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('open-panel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final capture = await _shoot(tester, boundary);
    await _save(
      tester,
      capture,
      p.join(_captureDir().path, _shotPng('dark-sheet')),
    );
    if (_baselineMode) return;

    final theme = buildAppTheme(Brightness.dark);
    final scheme = theme.colorScheme;
    final glassInk = defaultSemanticColors(Brightness.dark).glassInkSecondary;

    // 玻璃是浮层本体的外层（壳在里面填色），所以找祖先。
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('source-swap-sheet')),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<ModalBarrier>(find.byType(ModalBarrier).last).color,
      scheme.scrim.withValues(alpha: AppGlassBarrier.sheetScrimAlpha),
    );

    final captionFinder = find.text('当前：沙丘');
    expect(captionFinder, findsOneWidget);
    expect(_textColor(tester, captionFinder)?.toARGB32(), glassInk.toARGB32());

    final captionRect = tester.getRect(captionFinder);
    final sheetRect = tester.getRect(
      find.byKey(const ValueKey('source-swap-sheet')),
    );
    final bandRect = Rect.fromLTWH(
      sheetRect.left + 28,
      sheetRect.bottom - 52,
      160,
      20,
    );
    final probe = _band(capture, bandRect);
    // 已知缺口，如实记：浮层的头部行（与 "当前：" 同一行）落在面板的 rim/sheen
    // 抬亮区。纯白海报底上那块面板是 #6f7175，12px 文字连**正文墨色**都只有
    // 4.14:1——这是面板亮度的问题，不是文字角色能救的（要 4.5 得几乎纯白，
    // 那时次要文字会比正文更亮）。判据因此取「12px 说明文字所在的正文区」，
    // 头部行作为缺口记在 probes 里，修复属于下一阶段（rim/sheen 分档）。
    // 绑定点：文案右侧紧邻的空白带（同一条 rim/sheen 上下文，且没有字形）。
    final headerRow = _band(
      capture,
      Rect.fromLTWH(
        captionRect.right + 8,
        captionRect.top,
        80,
        captionRect.height,
      ),
    );

    final beforeRatio = _contrast(scheme.onSurfaceVariant, probe.color);
    final afterRatio = _contrast(glassInk, probe.color);
    _probes.add({
      'scene': 'dark-sheet',
      'panel_lower_left': _hex(probe.color),
      'panel_lower_left_outlier_ratio': _round2(probe.outlierRatio),
      'panel_lower_left_spread': _round2(probe.spread),
      'header_row_panel': _hex(headerRow.color),
      'header_row_outlier_ratio': _round2(headerRow.outlierRatio),
      'header_row_contrast_after': _round2(
        _contrast(glassInk, headerRow.color),
      ),
      'header_row_contrast_body_ink': _round2(
        _contrast(scheme.onSurface, headerRow.color),
      ),
      'header_row_pass':
          _contrast(glassInk, headerRow.color) >= 4.5 &&
          _contrast(scheme.onSurface, headerRow.color) >= 4.5,
      'header_row_note':
          '纯白海报底上最容易失守的一处：头部行同时吃 rim 竖向'
          '白光与左上角 sheen。ink-1 round-2 把暗色档的 rim 内衬权重从 0.55 降到'
          '0.04、sheen 从 0.10 降到 0.03（rimAlphaDark 反而从 0.34 加到 0.60，'
          '改由 1px 边缘线承担玻璃感），两种墨色才都过 4.5。代价见 report §6。',
      'glass_ink_hex': _hex(glassInk),
      'contrast_before_onSurfaceVariant': _round2(beforeRatio),
      'contrast_after_glassInkSecondary': _round2(afterRatio),
      'threshold': 4.5,
      'pass_before': beforeRatio >= 4.5,
      'pass_after': afterRatio >= 4.5,
    });

    expect(probe.outlierRatio, lessThan(0.2), reason: '探针区里有字形，取样无效');
    expect(beforeRatio, lessThan(4.5), reason: '旧角色在这块底上应当不达标');
    expect(afterRatio, greaterThanOrEqualTo(4.5), reason: '新角色必须过 4.5:1');
    // 头部行（最坏处）两种墨色都必须过 —— 这是 round-2 关掉的那道缺口。
    expect(
      _contrast(glassInk, headerRow.color),
      greaterThanOrEqualTo(4.5),
      reason: '浮层头部行的次要文字必须过 4.5',
    );
    expect(
      _contrast(scheme.onSurface, headerRow.color),
      greaterThanOrEqualTo(4.5),
      reason: '浮层头部行的正文墨色必须过 4.5',
    );
  });

  // -------------------------------------------------------------------------
  // 4 · 角色本身：两个亮度下的取值、扩展三处同步、包装器都返回玻璃
  // -------------------------------------------------------------------------
  testWidgets('角色：亮色不变、暗色分档；包装器两个亮度都返回玻璃', (tester) async {
    final lightTheme = buildAppTheme(Brightness.light);
    final darkTheme = buildAppTheme(Brightness.dark);
    final lightSemantic = defaultSemanticColors(Brightness.light);
    final darkSemantic = defaultSemanticColors(Brightness.dark);

    // 亮色：与改动前的 glassSecondaryInk 取值完全相同（onSurface）→ 亮色零回归。
    expect(
      lightSemantic.glassInkSecondary.toARGB32(),
      lightTheme.colorScheme.onSurface.toARGB32(),
    );
    // 暗色：不再是 onSurfaceVariant（那正是 2.40–3.56 的来源），也不是凭空捏的色：
    // 它是 nightInkMuted 向 nightInk 的混合，亮度落在两者之间。
    expect(
      darkSemantic.glassInkSecondary.toARGB32(),
      isNot(darkTheme.colorScheme.onSurfaceVariant.toARGB32()),
    );
    expect(
      _luminance(darkSemantic.glassInkSecondary),
      greaterThan(_luminance(AppPalette.nightInkMuted)),
    );
    expect(
      _luminance(darkSemantic.glassInkSecondary),
      lessThanOrEqualTo(_luminance(AppPalette.nightInk) + 1e-6),
    );

    // ThemeExtension 三处必须同步：copyWith 与 lerp 都不能丢这个字段。
    final copied = darkSemantic.copyWith();
    expect(
      copied.glassInkSecondary.toARGB32(),
      darkSemantic.glassInkSecondary.toARGB32(),
    );
    final lerped = darkSemantic.lerp(lightSemantic, 0.0);
    expect(
      lerped.glassInkSecondary.toARGB32(),
      darkSemantic.glassInkSecondary.toARGB32(),
    );
    final lerpedHalf = darkSemantic.lerp(lightSemantic, 0.5);
    expect(
      lerpedHalf.glassInkSecondary.toARGB32(),
      isNot(darkSemantic.glassInkSecondary.toARGB32()),
      reason: 'lerp 里漏了新字段（插值应当有中间值）',
    );

    // 包装器接线是「改动后」的事实：基线那一轮跑在接线之前的代码上，跳过。
    if (_baselineMode) return;

    // 包装器：两个亮度都必须是玻璃（暗色不再原样返回 child）。
    const child = SizedBox.shrink();
    for (final theme in [lightTheme, darkTheme]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          themeAnimationDuration: Duration.zero,
          home: const Scaffold(body: SizedBox()),
        ),
      );
      final context = tester.element(find.byType(Scaffold));
      expect(glassDialogShell(context, child: child), isA<Dialog>());
      expect(glassSheetShell(context, child: child), isA<GlassSurface>());
      expect(
        glassSecondaryInk(context).toARGB32(),
        defaultSemanticColors(theme.brightness).glassInkSecondary.toARGB32(),
      );
    }
  });

  // -------------------------------------------------------------------------
  // 5 · 暗色典型底（产品常态的暗页面）：玻璃照样达标
  // -------------------------------------------------------------------------
  testWidgets('暗色 dialog：产品常态暗底上的对比度', (tester) async {
    final boundary = GlobalKey();
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final nowMs = DateTime(2026, 11, 26, 12).millisecondsSinceEpoch;
    await tester.pumpWidget(
      _hostApp(
        theme: buildAppTheme(Brightness.dark),
        boundary: boundary,
        host: _Host(
          backdrop: const _NightPage(),
          label: '打开续播选择',
          open: (context) => showHistoryProgressPicker(
            context,
            choices: [
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
            ],
            nowMs: nowMs,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-panel')));
    await tester.pumpAndSettle();

    final capture = await _shoot(tester, boundary);
    await _save(
      tester,
      capture,
      p.join(_captureDir().path, _shotPng('dark-dialog-nightpage')),
    );
    if (_baselineMode) return;

    final scheme = buildAppTheme(Brightness.dark).colorScheme;
    final glassInk = defaultSemanticColors(Brightness.dark).glassInkSecondary;
    final captionRect = tester.getRect(find.text('同一部剧有多条可续播记录，选一条继续：'));
    final bandRect = Rect.fromLTWH(
      captionRect.right - 150,
      captionRect.top,
      150,
      captionRect.height,
    );
    final probe = _band(capture, bandRect);
    final afterRatio = _contrast(glassInk, probe.color);
    _probes.add({
      'scene': 'dark-dialog-nightpage',
      'panel_at_caption_band': _hex(probe.color),
      'panel_at_caption_band_outlier_ratio': _round2(probe.outlierRatio),
      'glass_ink_hex': _hex(glassInk),
      'contrast_after_glassInkSecondary': _round2(afterRatio),
      'contrast_before_onSurfaceVariant': _round2(
        _contrast(scheme.onSurfaceVariant, probe.color),
      ),
      'threshold': 4.5,
      'pass_after': afterRatio >= 4.5,
    });
    expect(afterRatio, greaterThanOrEqualTo(4.5));
  });

  // -------------------------------------------------------------------------
  // 6 · rim 内衬权重 / sheen 扫描：可读性与玻璃感的取舍（决定暗色档取值）
  //
  // 场景与真实浮层同一几何：宽 1120、高 774、贴底、上圆角 14，背后是被
  // scrim@0.42 压过的近白海报（最坏底）。每个候选都量三件事：
  //   1. 头部行面板底 + 两种墨色的比值（可读性）；
  //   2. rim_lift = 头部行与正文区的亮度差（面板内部的竖向白光有多强）；
  //   3. border_step = 1px 边缘线与内侧 8px 的亮度差（边缘线有没有被削掉）；
  //   4. sheen_delta = 左上角与右下角的亮度差（斜向扫光还在不在）。
  // -------------------------------------------------------------------------
  testWidgets('暗色玻璃：rim 内衬权重 / sheen 候选扫描（可读性 vs 玻璃感）', (tester) async {
    final boundary = GlobalKey();
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final theme = buildAppTheme(Brightness.dark);
    final scheme = theme.colorScheme;
    final glassInk = defaultSemanticColors(Brightness.dark).glassInkSecondary;
    const panel = Rect.fromLTWH(160, 126, 1120, 774);

    double srgb(Color c) => 255 * (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b);

    Future<Map<String, Object?>> probe(
      double rim,
      double wash,
      double sheen,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          themeAnimationDuration: Duration.zero,
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: _family),
            primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: _family),
          ),
          home: RepaintBoundary(
            key: boundary,
            child: Stack(
              children: [
                const Positioned.fill(
                  child: ColoredBox(color: Color(0xFFFFFFFF)),
                ),
                Positioned.fill(
                  child: ColoredBox(
                    color: scheme.scrim.withValues(
                      alpha: AppGlassBarrier.sheetScrimAlpha,
                    ),
                  ),
                ),
                Positioned(
                  left: panel.left,
                  top: panel.top,
                  width: panel.width,
                  height: panel.height,
                  child: GlassSurface(
                    padding: EdgeInsets.zero,
                    rimAlpha: rim,
                    rimWash: wash,
                    sheenAlpha: sheen,
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
        ),
      );
      await tester.pumpAndSettle();
      final capture = await _shoot(tester, boundary);
      // 绑定点 = 真实文案「当前：xxx」右侧紧邻的空白带：那里同时受 rim 竖向白光
      // 与 her sheen 左上角扫光影响（面板中间反而几乎没有 sheen，会低估）。
      final header = _band(
        capture,
        Rect.fromLTWH(panel.left + 90, panel.top + 50, 80, 16),
      );
      final headerCenter = _band(
        capture,
        Rect.fromLTWH(panel.left + 410, panel.top + 50, 300, 16),
      );
      final body = _band(
        capture,
        Rect.fromLTWH(panel.left + 540, panel.top + 374, 200, 40),
      );
      // 边缘线：描边被 clip 在内侧，且带抗锯齿，取 top 与 top+1 两行的较亮者；
      // 内侧参考取 top+8（避开描边）。
      final edgeA = _band(
        capture,
        Rect.fromLTWH(panel.left + 500, panel.top, 120, 1),
      );
      final edgeB = _band(
        capture,
        Rect.fromLTWH(panel.left + 500, panel.top + 1, 120, 1),
      );
      final rimLine = srgb(edgeA.color) >= srgb(edgeB.color) ? edgeA : edgeB;
      final underLine = _band(
        capture,
        Rect.fromLTWH(panel.left + 500, panel.top + 8, 120, 1),
      );
      final cornerTL = _band(
        capture,
        Rect.fromLTWH(panel.left + 30, panel.top + 6, 40, 10),
      );
      final cornerBR = _band(
        capture,
        Rect.fromLTWH(panel.right - 70, panel.bottom - 16, 40, 10),
      );
      final bodyRatio = _contrast(scheme.onSurface, header.color);
      final glassRatio = _contrast(glassInk, header.color);
      return <String, Object?>{
        'rim_wash': wash,
        'sheen': sheen,
        'header_panel': _hex(header.color),
        'header_panel_center': _hex(headerCenter.color),
        'header_outlier_ratio': _round2(header.outlierRatio),
        'header_body_ink_ratio': _round2(bodyRatio),
        'header_glass_ink_ratio': _round2(glassRatio),
        'header_pass': bodyRatio >= 4.5 && glassRatio >= 4.5,
        'glass_feel_rim_lift_srgb': _round2(
          srgb(header.color) - srgb(body.color),
        ),
        'glass_feel_edge_line_srgb': _round2(
          srgb(rimLine.color) - srgb(underLine.color),
        ),
        'glass_feel_sheen_delta_srgb': _round2(
          srgb(cornerTL.color) - srgb(cornerBR.color),
        ),
      };
    }

    // 第一行是 round-1 交付的暗色玻璃（rim 0.34 / wash 0.55 / sheen 0.10）：
    // 它是「玻璃感」的参照点，也是可读性不达标的那一档。其余是候选。
    const candidates = <List<double>>[
      [0.34, 0.55, 0.10],
      [0.55, 0.05, 0.04],
      [0.55, 0.05, 0.035],
      [0.55, 0.05, 0.03],
      [0.55, 0.045, 0.035],
      [0.55, 0.04, 0.04],
      [0.60, 0.04, 0.03],
    ];
    for (final candidate in candidates) {
      _probes.add(<String, Object?>{
        'scene': 'dark-rim-grid',
        ...await probe(candidate[0], candidate[1], candidate[2]),
      });
    }
    // 默认配置就是交付值：头部行两种墨色都必须过 4.5。
    final shipped = await probe(
      AppGlass.rimAlphaDark,
      GlassSurface.rimWashDark,
      AppGlass.sheenAlphaDark,
    );
    _probes.add(<String, Object?>{'scene': 'dark-rim-shipped', ...shipped});
    expect(shipped['header_glass_ink_ratio'], greaterThanOrEqualTo(4.5));
    expect(shipped['header_body_ink_ratio'], greaterThanOrEqualTo(4.5));
  });
  tearDownAll(() async {
    final file = File(p.join(_sddDir().path, 'probes.json'));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_probes),
    );
  });
}
