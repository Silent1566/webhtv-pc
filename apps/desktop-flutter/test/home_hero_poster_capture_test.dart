/// 首屏 hero「只有竖版海报」那一档的视觉证据与版式门禁。
///
/// 场景固定、真光栅化：1280×800 视口、深色主题、CJK 字体、合成 PNG 素材
/// （1600×900 的 16:9 背景 + 400×600 的 2:3 海报）。
/// `HOME_UNIFY_STAGE=before|after` 写到 `docs/superpowers/evidence/home-feed-unify/<stage>/`，
/// 两张图是同一次运行里的「有背景图」与「只有海报」两档，便于并排看「风格是否统一」。
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

const String _cjk = 'Noto Sans CJK SC';
final String _stage = Platform.environment['HOME_UNIFY_STAGE'] ?? 'after';
final GlobalKey _rootKey = GlobalKey();

Directory _evidenceDir() {
  var dir = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${dir.path}/apps/desktop-flutter').existsSync()) {
      return Directory('${dir.path}/docs/superpowers/evidence/home-feed-unify/$_stage')
        ..createSync(recursive: true);
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory('.local/home-feed-unify/$_stage')
    ..createSync(recursive: true);
}

Future<Uint8List> _syntheticPng({
  required int width,
  required int height,
  required bool portrait,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()
      ..shader =
          ui.Gradient.linear(
            Offset.zero,
            Offset(width.toDouble(), height.toDouble()),
            const [Color(0xFF1D3A5F), Color(0xFF8C2F39), Color(0xFF22182B)],
            const [0.0, 0.55, 1.0],
          ),
  );
  final paragraph = (ui.ParagraphBuilder(
    ui.ParagraphStyle(fontFamily: _cjk, fontSize: 28),
  )..pushStyle(ui.TextStyle(color: const Color(0xFFFFFFFF))))
    ..addText(portrait ? 'SYNTHETIC POSTER 2:3' : 'SYNTHETIC BACKDROP 16:9');
  final built = paragraph.build()
    ..layout(ui.ParagraphConstraints(width: width - 64.0));
  canvas.drawParagraph(built, const Offset(32, 30));
  built.dispose();
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return Uint8List.sublistView(bytes!);
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
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

Future<void> _capture(WidgetTester tester, String scenario) async {
  final bytes = await tester.runAsync(() async {
    final boundary =
        _rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return Uint8List.sublistView(data!);
  });
  final file = File('${_evidenceDir().path}/$_stage-$scenario.png');
  file.writeAsBytesSync(bytes!);
  debugPrint('HOME-UNIFY-CAPTURE path=${file.path} bytes=${bytes.length}');
}

HomeItem _item({String? backdrop}) => HomeItem(
  kind: HomeItemKind.resume,
  key: 'k-${backdrop ?? 'none'}',
  title: '那一夜，我怀了社长的孩子',
  poster: 'https://capture.invalid/poster.png',
  backdrop: backdrop == null ? null : 'https://capture.invalid/backdrop.png',
  subtitle: '2026 · 9.5',
  overview: '在服装销售公司工作的花井菜里，在遭遇男友背叛的失意之夜，与一位温柔陌生人发生了一夜情并意外怀孕。随后她发现，公司新上任的霸道社长濑古真人，竟就是那晚的男人。',
  tags: const ['剧情', '喜剧'],
  reason: '继续观看 · 第4集 · 剩 16 分钟',
  progress: 0.35,
);

Future<void> _pump(WidgetTester tester, HomeItem item) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: RepaintBoundary(
          key: _rootKey,
          child: HomeHero(
            items: [item],
            height: homeHeroHeight(800),
            onPrimary: (_) {},
            onSecondary: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: _cjk);
  });

  testWidgets('有 16:9 背景图与只有竖版海报：同一高度、同一构图', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final backdropImage = await tester.runAsync(
      () async => _decode(
        await _syntheticPng(width: 1600, height: 900, portrait: false),
      ),
    );
    final posterImage = await tester.runAsync(
      () async => _decode(
        await _syntheticPng(width: 400, height: 600, portrait: true),
      ),
    );
    addTearDown(() {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });
    await tester.runAsync(() async {
      await _prime(
        const NetworkImage('https://capture.invalid/backdrop.png'),
        backdropImage!,
      );
      await _prime(
        const NetworkImage('https://capture.invalid/poster.png'),
        posterImage!,
      );
    });

    await _pump(tester, _item(backdrop: 'https://capture.invalid/backdrop.png'));
    expect(tester.getSize(find.byKey(const ValueKey('home-hero'))).height, 800);
    expect(
      find.byKey(const ValueKey('home-hero-poster-tile')),
      findsNothing,
      reason: '有背景图时海报只是重复，不该再画一块',
    );
    await _capture(tester, 'with-backdrop');

    await _pump(tester, _item());
    expect(tester.getSize(find.byKey(const ValueKey('home-hero'))).height, 800);
    // 先落盘再断言：断言失败时也要留下证据图（Before 档就是用来跑挂的）。
    await _capture(tester, 'poster-only');
    final tile = find.byKey(const ValueKey('home-hero-poster-tile'));
    expect(tile, findsOneWidget);
    expect(
      tester.getSize(tile).height,
      closeTo((800 * 0.62).clamp(240.0, 560.0), 0.5),
      reason: '只有海报时它必须是「大」的那一块，不是 160 高的缩略图',
    );
    expect(tester.takeException(), isNull);
  });
}
