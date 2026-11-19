import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart'
    show
        imageCacheBudgetBytes,
        imageCacheBudgetCount,
        installImageCacheBudget;
import 'package:webhtv_pc/ui/poster_image.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/layout_scale.dart';

const _posterUrl = 'https://fixture.test/grid-poster.jpg';
const _cardKey = ValueKey('vod-card-budget-1');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('启动期图片缓存预算', () {
    test('同一安装入口显式设置字节与张数上限', () {
      final cache = PaintingBinding.instance.imageCache;
      final originalBytes = cache.maximumSizeBytes;
      final originalCount = cache.maximumSize;
      addTearDown(() {
        cache.maximumSizeBytes = originalBytes;
        cache.maximumSize = originalCount;
      });
      cache
        ..maximumSizeBytes = 100 << 20
        ..maximumSize = 1000;

      installImageCacheBudget();

      expect(cache.maximumSizeBytes, 64 * 1024 * 1024);
      expect(cache.maximumSizeBytes, imageCacheBudgetBytes);
      expect(cache.maximumSize, 256);
      expect(cache.maximumSize, imageCacheBudgetCount);
    });

    test('预算覆盖三屏默认网格、两张 1080p 背景和列表缩略图', () {
      const gridBytes = 6 * 2 * 3 * 397 * 596 * 4;
      const backdropBytes = 2 * 1920 * 1080 * 4;
      const thumbnailBytes = 40 * 200 * 300 * 4;
      expect(
        imageCacheBudgetBytes,
        greaterThanOrEqualTo(gridBytes + backdropBytes + thumbnailBytes),
      );
      // 大于缓存字节上限的单图不会被保留；4K 背景至少要能单独放进去。
      expect(imageCacheBudgetBytes, greaterThan(3840 * 2160 * 4));
      expect(imageCacheBudgetCount, greaterThanOrEqualTo(9 * 3 * 3 + 60 + 80));
    });
  });

  group('主网格海报解码宽度', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('webhtv-image-budget');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/config',
            'data': '${temp.path}/data',
            'cache': '${temp.path}/cache',
            'state': '${temp.path}/state',
          },
        ),
        log: LogService(),
      );
      await state.bootstrap();
      final imported = await state.importConfig(
        jsonEncode({
          'name': '图片预算测试',
          'sites': [
            {
              'key': 'budget_site',
              'name': '测试站点',
              'type': 4,
              'api': 'http://127.0.0.1:19978/vod/api?key=budget_site',
            },
          ],
        }),
      );
      expect(imported, isTrue, reason: state.lastError?.logLine);
      state.seedListingForTest([
        Vod(vodId: 'budget-1', vodName: '预算影片', vodPic: _posterUrl),
      ]);
    });

    tearDown(() async {
      state.dispose();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    Future<void> pumpGrid(
      WidgetTester tester, {
      required Size logicalSize,
      double dpr = 1,
    }) async {
      tester.view
        ..devicePixelRatio = dpr
        ..physicalSize = logicalSize * dpr;
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: BrowsePage(state: state))),
      );
      await tester.pump();
    }

    Finder posterFinder() => find.descendant(
      of: find.byKey(_cardKey),
      matching: find.byType(PosterImage),
    );

    ResizeImage providerOf(WidgetTester tester) {
      final image = tester.widget<Image>(
        find.descendant(of: posterFinder(), matching: find.byType(Image)),
      );
      expect(image.image, isA<ResizeImage>(), reason: '裸 NetworkImage 会按源尺寸解码');
      return image.image as ResizeImage;
    }

    testWidgets('实际 provider 是带列宽的 ResizeImage，保留图片地址和 2:3 比例', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await pumpGrid(tester, logicalSize: const Size(1280, 800));
      final provider = providerOf(tester);
      final posterSize = tester.getSize(posterFinder());
      final context = tester.element(posterFinder());
      final target = LayoutScale.cardWidth(context);
      final spacing = LayoutScale.gutter(context);
      const double usable = 1280 - 16 * 2;
      final columns = LayoutScale.columnsFor(usable, target, spacing);
      final expectedWidth = (usable - (columns - 1) * spacing) / columns;

      expect(posterSize.width, closeTo(expectedWidth, 0.001));
      expect(posterSize.height, closeTo(posterSize.width * 1.5, 0.001));
      expect(provider.width, expectedWidth.round());
      expect(provider.height, isNull);
      expect(provider.imageProvider, isA<NetworkImage>());
      expect((provider.imageProvider as NetworkImage).url, _posterUrl);
      expect(tester.widget<PosterImage>(posterFinder()).cacheWidth, provider.width);
    });

    testWidgets('同一逻辑视口中 DPR 1 → 1.5 → 2，解码宽度变而布局不变', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await pumpGrid(tester, logicalSize: const Size(1280, 800));
      final originalSize = tester.getSize(posterFinder());
      var previousWidth = providerOf(tester).width!;
      for (final dpr in [1.5, 2.0]) {
        await pumpGrid(tester, logicalSize: const Size(1280, 800), dpr: dpr);
        final provider = providerOf(tester);
        expect(tester.getSize(posterFinder()), originalSize);
        // 先乘后取整，不能把已取整的 1x 宽度直接翻倍（198.5 → 199/397）。
        expect(provider.width, (originalSize.width * dpr).round());
        expect(provider.width, greaterThan(previousWidth));
        previousWidth = provider.width!;
      }
    });

    testWidgets('窗口短边从 800 升到 1440，卡片密度升档后解码宽度增大', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      await pumpGrid(tester, logicalSize: const Size(1280, 800));
      final smallWidth = providerOf(tester).width!;
      final smallTarget = LayoutScale.cardWidth(tester.element(posterFinder()));
      await pumpGrid(tester, logicalSize: const Size(1920, 1440));
      final largeWidth = providerOf(tester).width!;
      final largeTarget = LayoutScale.cardWidth(tester.element(posterFinder()));

      expect(largeTarget, greaterThan(smallTarget));
      expect(largeWidth, greaterThan(smallWidth));
      expect(largeWidth, tester.getSize(posterFinder()).width.round());
    });
  });
}
