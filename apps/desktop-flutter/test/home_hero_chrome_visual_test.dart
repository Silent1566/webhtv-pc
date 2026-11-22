/// hero 手动切张控件（左右箭头 + 指示点）的视觉取证。
///
/// 为什么单开一个 harness：`home_scroll_visual_capture_test` 那条走的是真实
/// HomePage + 单条 hero 条目——单张时按设计不画指示点也不画箭头，拍不到这块。
/// 这里直接喂 12 张（`DESIGN.md` 里登记的「超过 6 张时点会细到不好点」的那个
/// 上限），两个形态各一张：有 16:9 背景图（满幅）与只有竖版海报（夜空 + 大片）。
///
/// 用法：`HOME_HERO_CAPTURE_STAGE=before flutter test test/home_hero_chrome_visual_test.dart`
/// 输出到 `.local/home-scroll/hero-chrome-<stage>-<scenario>.png`，同视口同主题。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

const _font = 'HeroChromeCaptureCJK';
const _backdropUrl = 'https://fixture.invalid/hero-chrome-backdrop.png';
const _posterUrl = 'https://fixture.invalid/hero-chrome-poster.png';
final _rootKey = GlobalKey();

/// 与 `home_scroll_visual_capture_test` 同一套字体主题：不换字族的话合成图里
/// 中文会渲染成豆腐块，取证看不出标题与按钮。
ThemeData _captureTheme() {
  final base = buildAppTheme(Brightness.dark);
  final label = base.textTheme.labelLarge?.copyWith(fontFamily: _font);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _font),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _font),
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
      labelStyle: base.chipTheme.labelStyle?.copyWith(fontFamily: _font),
      secondaryLabelStyle: base.chipTheme.secondaryLabelStyle?.copyWith(
        fontFamily: _font,
      ),
    ),
  );
}

Directory _evidenceDir() {
  var root = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${root.path}/apps/desktop-flutter').existsSync()) {
      return Directory('${root.path}/.local/home-scroll');
    }
    root = root.parent;
  }
  throw StateError('Repository root not found');
}

/// 合成素材：亮暗交替的色带 + 一条琥珀高亮条。
///
/// 刻意不做成"海报"：取证要看的是半透明深色圆底在**亮部与暗部**上是否都读得出
/// 边界，真实的影视剧照反而会把这一点藏起来。
Future<Uint8List> _fixtureBytes(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final rect = ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  canvas.drawRect(
    rect,
    ui.Paint()
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomRight,
        const [Color(0xFF14203A), Color(0xFF2E6F8E), Color(0xFF0B0E1A)],
        const [0.0, 0.5, 1.0],
      ),
  );
  final bright = ui.Paint()..color = const Color(0xE6F2C14E);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, height * 0.18, width.toDouble(), height * 0.10),
    bright,
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(width * 0.62, 0, width * 0.14, height.toDouble()),
    ui.Paint()..color = const Color(0xCCFFFFFF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return Uint8List.sublistView(bytes!);
}

Future<void> _prime(ImageProvider provider, ui.Image image) async {
  final key = await provider.obtainKey(ImageConfiguration.empty);
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(
      Future.value(ImageInfo(image: image.clone())),
    ),
  );
}

HomeItem _item(int index, {required bool withBackdrop}) => HomeItem(
  kind: HomeItemKind.resume,
  key: 'hero-chrome-$index',
  title: '合成海报 第${index + 1} 张',
  poster: _posterUrl,
  backdrop: withBackdrop ? _backdropUrl : null,
  subtitle: '2026 · 8.3',
  overview: '这是一张确定性合成的 16:9 测试背景，用来核对 hero 的左右箭头与指示点在亮暗两侧是否都读得清。',
  tags: const ['合成素材', '取证'],
  reason: '继续观看 · 第04集 · 剩 12 分钟',
  progress: 0.35,
);

Future<void> _pumpAndCapture(
  WidgetTester tester, {
  required String stage,
  required String scenario,
  required double height,
  required bool withBackdrop,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  // 解码与预载必须走 runAsync：testWidgets 的假时钟不会推进真实 I/O 的 future，
  // 直接在用例体里 await 解码会永久挂住（不是失败，是挂）。
  await tester.runAsync(() async {
    final backdropBytes = await _fixtureBytes(1920, 1080);
    final posterBytes = await _fixtureBytes(400, 600);
    final backdropCodec = await ui.instantiateImageCodec(backdropBytes);
    final posterCodec = await ui.instantiateImageCodec(posterBytes);
    final backdropImage = (await backdropCodec.getNextFrame()).image;
    final posterImage = (await posterCodec.getNextFrame()).image;
    await _prime(const NetworkImage(_backdropUrl), backdropImage);
    await _prime(const NetworkImage(_posterUrl), posterImage);
    // hero 左侧那张竖版海报按显示尺寸解码（`cacheWidth`），缓存键因此是
    // ResizeImage 而不是裸 NetworkImage——只预载裸图会渲染成占位图。
    final tileHeight = (height * 0.52).clamp(160.0, 320.0);
    await _prime(
      ResizeImage.resizeIfNeeded(
        (tileHeight * 2 / 3).round(),
        null,
        const NetworkImage(_posterUrl),
      ),
      posterImage,
    );
    backdropImage.dispose();
    posterImage.dispose();
    backdropCodec.dispose();
    posterCodec.dispose();
  });

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _captureTheme(),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(1280, 800),
          devicePixelRatio: 1,
          disableAnimations: true,
        ),
        child: RepaintBoundary(
          key: _rootKey,
          child: Scaffold(
            body: HomeHero(
              items: [
                for (var i = 0; i < 12; i++)
                  _item(i, withBackdrop: withBackdrop),
              ],
              height: height,
              onPrimary: (_) {},
              onSecondary: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.runAsync(() async {
    final boundary =
        _rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    _evidenceDir().createSync(recursive: true);
    File('${_evidenceDir().path}/hero-chrome-$stage-$scenario.png')
        .writeAsBytesSync(Uint8List.sublistView(bytes!));
  });
}

void main() {
  setUpAll(() async {
    expectFontsAvailableOrSkip();
    await loadFixtureFonts(cjkFamily: _font);
  });

  testWidgets('hero chrome capture: 满幅背景', (tester) async {
    final stage = Platform.environment['HOME_HERO_CAPTURE_STAGE'] ?? 'latest';
    await _pumpAndCapture(
      tester,
      stage: stage,
      scenario: 'backdrop',
      height: 800,
      withBackdrop: true,
    );
  });

  testWidgets('hero chrome capture: 只有竖版海报', (tester) async {
    final stage = Platform.environment['HOME_HERO_CAPTURE_STAGE'] ?? 'latest';
    await _pumpAndCapture(
      tester,
      stage: stage,
      scenario: 'poster',
      height: 456,
      withBackdrop: false,
    );
  });
}
