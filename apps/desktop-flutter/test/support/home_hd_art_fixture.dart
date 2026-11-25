import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/home_hero_art.dart';

ui.Image? _landscape;

/// 只替换明确的合成宽图I/O，空图、竖图和坏来源地址不伪装高清。
Future<HomeHeroArtEvidence?> loadHdHeroFixture(
  ImageProvider<Object> provider,
  ImageConfiguration configuration,
) async {
  if (provider is! NetworkImage || !provider.url.contains('backdrop')) return null;
  final cache = PaintingBinding.instance.imageCache;
  if (_landscape == null) {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final bounds = const ui.Rect.fromLTWH(0, 0, 1920, 1080);
    canvas.drawRect(bounds, ui.Paint()..shader = ui.Gradient.linear(
      ui.Offset.zero, const ui.Offset(1920, 1080),
      const [ui.Color(0xFF143C52), ui.Color(0xFF9E6850), ui.Color(0xFF222C48)],
      const [0, 0.5, 1],
    ));
    canvas.drawCircle(const ui.Offset(1450, 260), 135,
      ui.Paint()..color = const ui.Color(0xFFE6CC98));
    canvas.drawRect(const ui.Rect.fromLTWH(1150, 530, 300, 550),
      ui.Paint()..color = const ui.Color(0xFF16333B));
    canvas.drawRect(const ui.Rect.fromLTWH(1480, 650, 440, 430),
      ui.Paint()..color = const ui.Color(0xFF202A3A));
    final picture = recorder.endRecording();
    _landscape = picture.toImageSync(1920, 1080);
    picture.dispose();
    final oldMaximumSize = cache.maximumSize;
    final oldMaximumBytes = cache.maximumSizeBytes;
    cache.maximumSize = 640;
    cache.maximumSizeBytes = 160 * 1920 * 1080 * 4;
    addTearDown(() {
      cache.clear();
      cache.clearLiveImages();
      cache.maximumSize = oldMaximumSize;
      cache.maximumSizeBytes = oldMaximumBytes;
      _landscape?.dispose();
      _landscape = null;
    });
  }
  final image = _landscape!;
  // 轨道先于异步hero出现，且ResizeImage失败会逐出底层NetworkImage key。
  // 因而夹具把默认185px卡图变体一同prime，二者都消费同一真实1920×1080像素。
  for (final variant in <ImageProvider<Object>>[
    provider,
    ResizeImage.resizeIfNeeded(185, null, provider),
  ]) {
    final key = await variant.obtainKey(configuration);
    cache.putIfAbsent(key, () => OneFrameImageStreamCompleter(
      Future.value(ImageInfo(image: image.clone())),
    ));
  }
  return HomeHeroArtEvidence(width: image.width, height: image.height);
}
