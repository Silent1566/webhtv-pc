/// 图片必须**真正铺满**它的盒子（用户反馈 2026-10-10：「打包正式版测试还是都没铺满」）。
///
/// 这条反馈推翻了我上一轮的判断：我当时把「灰色块」归因为占位底色太亮
/// （`surfaceContainerHigh` → `surfaceContainerLow`），那只改了颜色，**没改尺寸**。
/// 用户重新打包后看到的仍然是「图片按原始尺寸居中、两侧露底色」。
///
/// **真实根因**：`PosterImage` 用 `Container(alignment: Alignment.center)` 包图。
/// `Container` 一旦带 `alignment`，就会在子节点外包一层 `Align`，而 `Align` 传给
/// 子节点的是**松约束**（loose）；`Image` 在松约束且自身未给 width/height 时会
/// 退回**图片固有尺寸**——于是 `BoxFit.cover` 根本没有“盒子”可铺。
/// 实测：780×439 的图放进 1280×468 的盒子，`RawImage` 尺寸是 `0×0`（松约束下未
/// 定型），改成不给 `alignment` 后是 `1280×468`。
///
/// 同一根因解释了用户三张截图里的全部现象：
/// - 浏览页海报只有左侧两张铺满、其余「没铺满」（同一个 `PosterImage`）；
/// - 演职人员头像两侧露底色；
/// - 详情页背景图只占中间一条、左右大片空白。
///
/// 本文件锁定：给 `PosterImage` 一个**紧约束**盒子时，内部 `RawImage` 必须与盒子
/// 同尺寸（即 `BoxFit.cover` 真正生效）。
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/app.dart' show PosterImage;

/// 与 `MemoryImage` 匹配的解码回调（供图片缓存预热用）。
Future<ui.Codec> _decode(
  ui.ImmutableBuffer buffer, {
  ui.TargetImageSizeCallback? getTargetSize,
}) => ui.instantiateImageCodecWithSize(buffer, getTargetSize: getTargetSize);

/// 780×439 的 16:9 纯色 PNG（宽高比与盒子不同，能暴露「不铺满」）。
const String _landscapePng = (
  'iVBORw0KGgoAAAANSUhEUgAAAwwAAAG3CAIAAACWj0WzAAAHbUlEQVR4nO3WMRHAMBDAsKB7EAFW'
  'vN0b7+mgOwHw6PXsAQDgY10vAAD4IZMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAAST'
  'BAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIA'
  'QDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADB'
  'JAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJME'
  'ABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBA'
  'MEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEk'
  'AQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQA'
  'EEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAw'
  'SQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQB'
  'AASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQ'
  'TBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJ'
  'AADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEA'
  'BJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBM'
  'EgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkA'
  'AMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAE'
  'kwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwS'
  'AEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAA'
  'wSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAAST'
  'BAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIA'
  'QDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADB'
  'JAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJME'
  'ABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBA'
  'MEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEk'
  'AQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQA'
  'EEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAw'
  'SQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQB'
  'AASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQ'
  'TBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJ'
  'AADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEA'
  'BJMEABBMEgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBM'
  'EgBAMEkAAMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkA'
  'AMEkAQAEkwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAE'
  'kwQAEEwSAEAwSQAAwSQBAASTBAAQTBIAQDBJAADBJAEABJMEABBMEgBAMEkAAMEkAQAEkwQAMKcX'
  'hgUYJfNrt8kAAAAASUVORK5CYII='
);

void main() {
  /// 把一张 PNG 预置进图片缓存，使 `Image.network(url)` 命中它（测试环境无网络）。
  Future<void> warmCache(WidgetTester tester, String url, String base64Png) async {
    final bytes = base64Decode(base64Png);
    await tester.runAsync(() async {
      final netKey = await NetworkImage(
        url,
      ).obtainKey(ImageConfiguration.empty);
      final memKey = await MemoryImage(
        bytes,
      ).obtainKey(ImageConfiguration.empty);
      final completer = MemoryImage(bytes).loadImage(memKey, _decode);
      PaintingBinding.instance.imageCache.putIfAbsent(netKey, () => completer);
    });
  }

  /// 让图片解码完成（真实异步 + 推进帧）。
  Future<void> settleImages(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('PosterImage 在紧约束盒子里必须铺满（BoxFit.cover 生效）', (tester) async {
    const url = 'https://img.test/landscape.png';
    await warmCache(tester, url, _landscapePng);

    tester.view.physicalSize = const Size(1280, 468);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 与详情页 hero 的用法一致：`SizedBox.expand` 给出**紧**约束。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(child: PosterImage(url: url)),
        ),
      ),
    );
    await settleImages(tester);

    final raw = find.byType(RawImage);
    expect(raw, findsOneWidget, reason: '图片应已解码并渲染');
    final size = tester.getSize(raw);
    expect(
      size.width,
      1280,
      reason: '宽度必须铺满盒子；两侧留空正是用户反馈的「没铺满」'
          '（根因：Container(alignment:) 让子节点拿到松约束）',
    );
    expect(size.height, 468, reason: '高度必须铺满盒子');
  });

  testWidgets('PosterImage 在指定 width/height 时同样铺满', (tester) async {
    const url = 'https://img.test/landscape2.png';
    await warmCache(tester, url, _landscapePng);

    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: PosterImage(url: url, width: 320, height: 180),
          ),
        ),
      ),
    );
    await settleImages(tester);

    final size = tester.getSize(find.byType(RawImage));
    expect(size.width, 320);
    expect(size.height, 180);
  });

  testWidgets('无图时占位图标仍居中（去掉 alignment 后不能退化）', (tester) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox.expand(child: PosterImage(url: null)),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    final iconCenter = tester.getCenter(
      find.byIcon(Icons.image_not_supported_outlined),
    );
    expect(
      iconCenter.dx,
      closeTo(200, 1),
      reason: '占位图标应居中（改用 Center 包住后仍要居中）',
    );
    expect(iconCenter.dy, closeTo(150, 1));
  });
}
