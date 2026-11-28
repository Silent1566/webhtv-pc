// STYLE-SPIKE / THROWAWAY —— 液态玻璃可行性 spike 的取证测试，不是生产测试。
//
// 真渲染：RepaintBoundary → toImage → PNG，不是对 widget 树的重描述。
// 同一内容、同一视口（1440x900）分别以「现状」与「玻璃」出图，成对落盘；
// 再对面板内的空区做像素取样，算出玻璃上正文/标题的真实对比度。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/style_spike/style_spike_gallery.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

const String _family = 'FixtureCJK';
const Size _viewport = Size(spikeWidth, spikeHeight);

String _spikeRoot() {
  var dir = Directory.current;
  for (var hop = 0; hop < 8; hop++) {
    final candidate = '${dir.path}/.superpowers/sdd/2026-11-26-style-spike';
    if (Directory(candidate).existsSync()) {
      return '$candidate/task-1';
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return '.superpowers/sdd/2026-11-26-style-spike/task-1';
}

/// 取证专用主题：把已注册的 CJK 字体设成主字族。
///
/// 只注册字体不够：`flutter test` 默认字族把拉丁字母与数字画成方块，
/// 而按钮/芯片的文字样式是 `buildAppTheme` 构建时捕获的副本，不会跟着
/// `textTheme.apply` 走（与既有视觉捕获测试同口径）。
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
      secondaryLabelStyle: base.chipTheme.secondaryLabelStyle
          ?.copyWith(fontFamily: _family),
    ),
  );
}

/// 对抗性底图：高亮白 + 高频纹理 + 明暗对半分。
///
/// 为什么不用一张好看的剧照：本次要判断的是「文字在任何背景下读不读得清」，
/// 而一张构图平缓的照片会把玻璃的可读性问题藏起来。这里把三个失败源全放进去。
Future<ui.Image> _adversarialBackdrop() async {
  const width = 1920.0;
  const height = 1080.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final split = width * 0.55;
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFF080A10),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, split, height),
    Paint()..color = const Color(0xFFF7F3EC),
  );
  // 高频纹理：左 8px 白条、右 6px 青条，没有平滑余地。
  for (var x = 0.0; x < split; x += 16) {
    canvas.drawRect(
      Rect.fromLTWH(x, 0, 8, height),
      Paint()..color = const Color(0xFFFFFFFF),
    );
  }
  for (var x = split; x < width; x += 12) {
    canvas.drawRect(
      Rect.fromLTWH(x, 0, 6, height),
      Paint()..color = const Color(0xFF2AE7FF),
    );
  }
  // 最亮白的光斑（片头 logo / 雪景的极端），专治白字。
  canvas.drawCircle(
    const Offset(320, 250),
    250,
    Paint()..color = const Color(0xFFFFFFFF),
  );
  canvas.drawCircle(
    const Offset(760, 780),
    210,
    Paint()..color = const Color(0xFFFFF1C4),
  );
  // 暗区里的高饱和亮块：测试「暗字落在亮块上」。
  canvas.drawRect(
    const Rect.fromLTWH(1180, 140, 330, 280),
    Paint()..color = const Color(0xFFF0B429),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(1920, 1080);
  picture.dispose();
  return image;
}

/// 许可与来源见 task-1/report.md：Unsplash License 的实景照片，只作固定图像输入。
Future<ui.Image> _photoBackdrop() async {
  final file = File(
    '${_spikeRoot()}/../../../../apps/desktop-flutter/lib/ui/style_spike/fixtures/background-photo.jpg',
  );
  expect(file.existsSync(), isTrue, reason: '缺少 fixtures/background-photo.jpg');
  final codec = await ui.instantiateImageCodec(await file.readAsBytes());
  final frame = await codec.getNextFrame();
  return frame.image;
}

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

Color _averageColor(ByteData rgba, int width, Rect rect) {
  var r = 0.0;
  var g = 0.0;
  var b = 0.0;
  var count = 0;
  for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y++) {
    for (var x = rect.left.toInt(); x < rect.right.toInt(); x++) {
      final i = (y * width + x) * 4;
      r += rgba.getUint8(i);
      g += rgba.getUint8(i + 1);
      b += rgba.getUint8(i + 2);
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

/// 探针区的亮度标准差：用来证明这 20x20 采样区里没有字形，否则算出的
/// 「对比度」是拿文字跟它自己比。
double _spread(ByteData rgba, int width, Rect rect) {
  var sum = 0.0;
  var sumSq = 0.0;
  var count = 0;
  for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y++) {
    for (var x = rect.left.toInt(); x < rect.right.toInt(); x++) {
      final i = (y * width + x) * 4;
      final lum = 0.2126 * rgba.getUint8(i) +
          0.7152 * rgba.getUint8(i + 1) +
          0.0722 * rgba.getUint8(i + 2);
      sum += lum;
      sumSq += lum * lum;
      count++;
    }
  }
  final mean = sum / count;
  final variance = sumSq / count - mean * mean;
  return double.parse(math.sqrt(math.max(variance, 0)).toStringAsFixed(1));
}

double _luminance(Color c) {
  double channel(double v) => v <= 0.03928
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrast(Color fg, Color bg) {
  final a = _luminance(fg);
  final b = _luminance(bg);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

String _byte(int value) => value.toRadixString(16).padLeft(2, '0');

String _hex(Color c) =>
    '#${_byte((c.r * 255).round())}${_byte((c.g * 255).round())}${_byte((c.b * 255).round())}';

String _sceneName(
  Brightness brightness,
  SpikeBackdrop backdrop,
  SpikeSurface surface,
) {
  final b = brightness == Brightness.dark ? 'dark' : 'light';
  final back = switch (backdrop) {
    SpikeBackdrop.hero => 'hero',
    SpikeBackdrop.page => 'page',
    SpikeBackdrop.solid => 'solid',
  };
  final material = switch (surface) {
    SpikeSurface.current => 'current',
    SpikeSurface.glass => 'glass',
    SpikeSurface.glassDense => 'glass-dense',
  };
  return '$b-$back-$material';
}

Map<String, Object?> _probe(
  _Capture capture,
  Rect rect,
  Color fg,
  double threshold,
) {
  final bg = _averageColor(capture.rgba, capture.width, rect);
  final ratio = _contrast(fg, bg);
  final spread = _spread(capture.rgba, capture.width, rect);
  return <String, Object?>{
    'probe': '${rect.left.toInt()},${rect.top.toInt()} ${rect.width.toInt()}x${rect.height.toInt()}',
    'fg': _hex(fg),
    'bg': _hex(bg),
    'ratio': double.parse(ratio.toStringAsFixed(2)),
    'bg_spread': spread,
    'threshold': threshold,
    'pass': ratio >= threshold,
  };
}

Widget _app(ThemeData theme, GlobalKey key, Widget gallery) => MaterialApp(
  debugShowCheckedModeBanner: false,
  // 关掉主题过渡：默认 200ms 的 AnimatedTheme 会让 32ms 后的捕获停在半途，
  // 拍出「暗色还没变成亮色」的中间帧。
  themeAnimationDuration: Duration.zero,
  theme: theme,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(key: key, child: gallery),
    ),
  ),
);

void main() {
  setUpAll(() async {
    expectFontsAvailableOrSkip();
    await loadFixtureFonts();
  });

  testWidgets('玻璃与现状在三种真实底上成对出图（1440x900）', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final adversarial = (await tester.runAsync(_adversarialBackdrop))!;
    final photo = (await tester.runAsync(_photoBackdrop))!;
    addTearDown(adversarial.dispose);
    addTearDown(photo.dispose);

    final dir = Directory('${_spikeRoot()}/captures')
      ..createSync(recursive: true);
    final scenes = <Map<String, Object?>>[];

    for (final brightness in Brightness.values) {
      final theme = _captureTheme(brightness);
      final scheme = theme.colorScheme;
      final headingColor = theme.textTheme.titleLarge!.color!;
      final bodyColor = theme.textTheme.bodyMedium!.color!;
      final metaColor = scheme.onSurfaceVariant;
      for (final backdrop in SpikeBackdrop.values) {
        final ui.Image? backdropImage =
            backdrop == SpikeBackdrop.solid ? null : adversarial;
        _Capture? currentCapture;
        for (final surface in SpikeSurface.values) {
          final key = GlobalKey();
          await tester.pumpWidget(
            _app(
              theme,
              key,
              StyleSpikeGallery(
                backdrop: backdrop,
                surface: surface,
                image: backdropImage,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 32));
          final capture = await _shoot(tester, key);
          expect(capture.width, spikeWidth.toInt());
          expect(capture.height, spikeHeight.toInt());
          final name = _sceneName(brightness, backdrop, surface);
          File('${dir.path}/$name.png').writeAsBytesSync(capture.png);

          if (surface == SpikeSurface.current) {
            currentCapture = capture;
          } else {
            // 成对断言：同一内容、同一视口，玻璃必须真的改变了面板底像素。
            expect(currentCapture, isNotNull);
            final before = _averageColor(
              currentCapture!.rgba,
              currentCapture.width,
              spikeHeadingProbe,
            );
            final after = _averageColor(
              capture.rgba,
              capture.width,
              spikeHeadingProbe,
            );
            expect(
              before,
              isNot(after),
              reason: '$name: 玻璃没有改变底像素，说明 BackdropFilter 未生效',
            );
          }

          scenes.add(<String, Object?>{
            'scene': name,
            'brightness': brightness == Brightness.dark ? 'dark' : 'light',
            'backdrop': backdrop.name,
            'surface': surface.name,
            'input': backdrop == SpikeBackdrop.solid ? 'none' : 'adversarial',
            'png': 'task-1/captures/$name.png',
            'probes': <String, Object?>{
              'heading': _probe(capture, spikeHeadingProbe, headingColor, 3.0),
              'body': _probe(capture, spikeBodyProbe, bodyColor, 4.5),
              'meta': _probe(capture, spikeMetaProbe, metaColor, 4.5),
              'body_dark': _probe(capture, spikeDarkProbe, bodyColor, 4.5),
            },
          });
        }
      }
    }

    // 照片底：hero 一档，暗/亮各一对，证明这套材料不是只对合成图成立。
    for (final brightness in Brightness.values) {
      final theme = _captureTheme(brightness);
      for (final surface in SpikeSurface.values) {
        final key = GlobalKey();
        await tester.pumpWidget(
          _app(
            theme,
            key,
            StyleSpikeGallery(
              backdrop: SpikeBackdrop.hero,
              surface: surface,
              image: photo,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 32));
        final capture = await _shoot(tester, key);
        final tag = brightness == Brightness.dark ? 'dark' : 'light';
        final material = switch (surface) {
          SpikeSurface.current => 'current',
          SpikeSurface.glass => 'glass',
          SpikeSurface.glassDense => 'glass-dense',
        };
        final name = 'photo-$tag-hero-$material';
        File('${dir.path}/$name.png').writeAsBytesSync(capture.png);
        scenes.add(<String, Object?>{
          'scene': name,
          'brightness': tag,
          'backdrop': 'hero',
          'surface': surface.name,
          'input': 'fixture-photo',
          'png': 'task-1/captures/$name.png',
        });
      }
    }

    final manifest = <String, Object?>{
      'what': 'STYLE-SPIKE task-1 captures',
      'viewport': '1440x900, pixelRatio 1',
      'inputs': <String, Object?>{
        'adversarial':
            'generated in test: bright white + high-frequency stripes + hard light/dark split',
        'photo': 'lib/ui/style_spike/fixtures/background-photo.jpg (Unsplash License)',
      },
      'scenes': scenes,
    };
    File('${_spikeRoot()}/contrast.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );

    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(files.length, greaterThanOrEqualTo(6));
    for (final file in files) {
      expect(file.lengthSync(), greaterThan(20000), reason: file.path);
    }
    debugPrint('STYLE-SPIKE captures=${files.length} dir=${dir.path}');
    for (final file in files) {
      debugPrint('STYLE-SPIKE png ${file.path}');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('玻璃在场才有 BackdropFilter，现状面不含玻璃滤镜', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = _captureTheme(Brightness.dark);
    for (final surface in SpikeSurface.values) {
      await tester.pumpWidget(
        MaterialApp(
          themeAnimationDuration: Duration.zero,
          theme: theme,
          home: Scaffold(
            body: StyleSpikeGallery(
              backdrop: SpikeBackdrop.solid,
              surface: surface,
            ),
          ),
        ),
      );
      final filters = find.byType(BackdropFilter);
      if (surface != SpikeSurface.current) {
        expect(filters, findsWidgets);
      } else {
        expect(filters, findsNothing);
      }
    }
  });
}
