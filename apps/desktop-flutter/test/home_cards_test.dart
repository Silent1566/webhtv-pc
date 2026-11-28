/// 首页轨道卡片与轨道的**视觉契约**门禁（`docs/phase11/design/01-home-hero.md` §4）。
///
/// 只钉住"写死就会退回原样"的那几项：海报 2:3 由宽度推、默认文字区为 40、
/// 续播才有进度条、空轨道不占位、推荐行的"查看全部"入口不存在。
///
/// 全部用假 [HomeItem] 直接构造：卡片只读模型字段，不需要 `AppState`，
/// 也就不该为了测一张卡片把网络与配置拖进来。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

HomeItem _item({
  required HomeItemKind kind,
  required String title,
  String subtitle = '',
  String reason = '',
  double progress = 0,
}) {
  return HomeItem(
    kind: kind,
    key: 'k-$title',
    title: title,
    subtitle: subtitle,
    reason: reason,
    progress: progress,
  );
}

Future<void> _pumpCard(
  WidgetTester tester,
  HomeItem item, {
  double width = 200,
  VoidCallback? onTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: HomePosterCard(
            item: item,
            onTap: onTap ?? () {},
            width: width,
          ),
        ),
      ),
    ),
  );
}

Future<void> _pumpRail(
  WidgetTester tester,
  HomeRail rail, {
  VoidCallback? onSeeAll,
  ValueChanged<HomeItem>? onTap,
  double textScale = 1,
  ThemeData? theme,
  GlobalKey? captureKey,
}) async {
  final app = MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      backgroundColor: theme?.colorScheme.surface,
      body: Align(
        alignment: Alignment.topLeft,
        child: HomeRailView(
          rail: rail,
          onTap: onTap ?? (_) {},
          onSeeAll: onSeeAll,
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    captureKey == null ? app : RepaintBoundary(key: captureKey, child: app),
  );
}

HomeFeed _captionFixture() => buildHomeFeed(
  history: const [
    PlaybackHistory(
      id: 1,
      siteKey: 'site-a',
      vodId: 'v1',
      vodName: '漫长的季节',
      flag: '线路一',
      episodeName: '第08集',
      episodeId: 'e1',
      positionMs: 1400000,
      durationMs: 2700000,
      updatedAt: 1,
    ),
  ],
  followings: const [],
  tmdbRecommendations: const [
    RecommendationEntry(
      item: TmdbItem(
        tmdbId: 2,
        mediaType: TmdbMediaType.tv,
        title: '隐秘的角落',
        subtitle: '2020 · 8.8',
      ),
      source: RecommendationSource.tmdb,
      reason: '因为你看过《漫长的季节》',
    ),
  ],
);

Future<void> _captureRail(
  WidgetTester tester,
  GlobalKey key,
  String path,
) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    File(path).writeAsBytesSync(
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  });
}

void main() {
  const capturePath = String.fromEnvironment('HOME_CAPTION_CAPTURE');
  const captureFont = 'Noto Sans CJK SC';
  if (capturePath.isNotEmpty) {
    setUpAll(() async {
      expectFontsAvailableOrSkip();
      await loadFixtureFonts(cjkFamily: captureFont);
    });
  }

  for (final scale in [1.0, 1.5, 2.0]) {
    for (final kind in [HomeRailKind.resume, HomeRailKind.recommendTmdb]) {
      testWidgets('rail caption fits at $scale× (${kind.name})', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1024, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final resume = kind == HomeRailKind.resume;
        final rail = _captionFixture().rails.singleWhere(
          (rail) => rail.kind == kind,
        );
        final theme = buildAppTheme(
          resume ? Brightness.dark : Brightness.light,
        );
        final captureKey = capturePath.isNotEmpty && resume && scale == 2
            ? GlobalKey()
            : null;
        HomeItem? tapped;
        await _pumpRail(
          tester,
          rail,
          onTap: (item) => tapped = item,
          textScale: scale,
          theme: capturePath.isEmpty
              ? theme
              : theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: captureFont),
                ),
          captureKey: captureKey,
        );
        if (captureKey != null) {
          await _captureRail(tester, captureKey, capturePath);
        }

        expect(tester.takeException(), isNull);
        final poster = tester.getRect(
          find.byKey(HomePosterCard.posterFrameKey),
        );
        final viewport = tester.getRect(find.byType(ListView));
        final card = tester.getRect(find.byType(HomePosterCard));
        expect(poster.width, closeTo(185.25, 0.001));
        expect(poster.height, closeTo(poster.width * 1.5, 0.001));
        if (scale == 1) expect(card.bottom - poster.bottom, closeTo(40, 0.001));
        final title = find.text(resume ? '漫长的季节' : '隐秘的角落');
        final metadata = find.text(
          resume ? '继续观看 · 第08集 · 剩 22 分钟' : '因为你看过《漫长的季节》',
        );
        expect(tester.getRect(title).top, greaterThan(poster.bottom));
        expect(
          tester.getRect(metadata).top,
          greaterThan(tester.getRect(title).bottom),
        );
        for (final line in [title, metadata]) {
          final text = tester.widget<Text>(line);
          expect(text.maxLines, 1);
          expect(text.overflow, TextOverflow.ellipsis);
          final bounds = tester.getRect(line);
          expect(
            bounds.bottom,
            lessThanOrEqualTo(card.bottom),
            reason: '${text.data}: $bounds vs card $card',
          );
          expect(
            bounds.bottom,
            lessThanOrEqualTo(viewport.bottom),
            reason: '${text.data}: $bounds vs rail $viewport',
          );
        }
        final progress = find.byKey(HomePosterCard.progressKey);
        if (resume) {
          expect(
            tester.getSize(progress).width,
            closeTo(poster.width * 1400000 / 2700000, 0.001),
          );
        } else {
          expect(progress, findsNothing);
          expect(find.text('2020 · 8.8'), findsNothing);
        }
        await tester.tap(metadata);
        expect(tapped, same(rail.items.single));
      });
    }
  }

  testWidgets('海报保持 2:3：高 = 宽 × 1.5', (tester) async {
    await _pumpCard(
      tester,
      _item(kind: HomeItemKind.recommend, title: '漫长的季节'),
      width: 200,
    );

    final size = tester.getSize(find.byKey(HomePosterCard.posterFrameKey));
    expect(size.width, 200);
    expect(size.height, 300);
  });

  testWidgets('续播卡有琥珀进度条，推荐卡没有', (tester) async {
    await _pumpCard(
      tester,
      _item(kind: HomeItemKind.resume, title: '漫长的季节', progress: 0.4),
      width: 200,
    );

    final bar = find.byKey(HomePosterCard.progressKey);
    expect(bar, findsOneWidget);
    final size = tester.getSize(bar);
    expect(size.width, moreOrLessEquals(200 * 0.4));
    expect(size.height, 3);

    await _pumpCard(
      tester,
      _item(kind: HomeItemKind.recommend, title: '漫长的季节', progress: 0.4),
    );
    expect(find.byKey(HomePosterCard.progressKey), findsNothing);
  });

  testWidgets('items 为空时收缩为 SizedBox.shrink', (tester) async {
    await _pumpRail(
      tester,
      const HomeRail(kind: HomeRailKind.resume, title: '继续观看'),
      onSeeAll: () {},
    );

    expect(find.byType(HomePosterCard), findsNothing);
    expect(find.byType(ListView), findsNothing);
    expect(tester.getSize(find.byType(HomeRailView)), Size.zero);
  });

  testWidgets('rail.seeAll 为 null 时不渲染「查看全部」', (tester) async {
    await _pumpRail(
      tester,
      HomeRail(
        kind: HomeRailKind.recommendTmdb,
        title: '个性推荐 · TMDB',
        items: [_item(kind: HomeItemKind.recommend, title: '漫长的季节')],
      ),
      onSeeAll: () {},
    );

    expect(find.text('个性推荐 · TMDB'), findsOneWidget);
    expect(find.text('查看全部'), findsNothing);
  });

  testWidgets('seeAll 与 onSeeAll 都有时渲染「查看全部」并可点', (tester) async {
    var tapped = 0;
    await _pumpRail(
      tester,
      HomeRail(
        kind: HomeRailKind.resume,
        title: '继续观看',
        items: [_item(kind: HomeItemKind.resume, title: '漫长的季节')],
        seeAll: HomeSeeAll.history,
      ),
      onSeeAll: () => tapped++,
    );

    expect(find.text('继续观看'), findsOneWidget);
    final button = find.widgetWithText(TextButton, '查看全部');
    expect(button, findsOneWidget);

    await tester.tap(button);
    expect(tapped, 1);
  });

  testWidgets('有 seeAll 但没有 onSeeAll 时不渲染死按钮', (tester) async {
    await _pumpRail(
      tester,
      HomeRail(
        kind: HomeRailKind.resume,
        title: '继续观看',
        items: [_item(kind: HomeItemKind.resume, title: '漫长的季节')],
        seeAll: HomeSeeAll.history,
      ),
    );

    expect(find.text('查看全部'), findsNothing);
  });

  testWidgets('推荐卡第二行显示 reason（压过 subtitle）', (tester) async {
    await _pumpRail(
      tester,
      HomeRail(
        kind: HomeRailKind.recommendDouban,
        title: '个性推荐 · 豆瓣',
        items: [
          _item(
            kind: HomeItemKind.recommend,
            title: '漫长的季节',
            subtitle: '2023 · 8.9',
            reason: '因为你看过《隐秘的角落》',
          ),
        ],
      ),
    );

    expect(find.text('因为你看过《隐秘的角落》'), findsOneWidget);
    expect(find.text('2023 · 8.9'), findsNothing);
  });

  testWidgets('没有 reason 时副信息行退回 subtitle', (tester) async {
    await _pumpRail(
      tester,
      HomeRail(
        kind: HomeRailKind.following,
        title: '追剧更新',
        items: [
          _item(
            kind: HomeItemKind.following,
            title: '漫长的季节',
            subtitle: '2023 · 8.9',
          ),
        ],
      ),
    );

    expect(find.text('2023 · 8.9'), findsOneWidget);
  });

  testWidgets('点击卡片把该条 HomeItem 交回页面', (tester) async {
    final item = _item(kind: HomeItemKind.resume, title: '漫长的季节');
    HomeItem? tapped;
    await _pumpRail(
      tester,
      HomeRail(kind: HomeRailKind.resume, title: '继续观看', items: [item]),
      onTap: (value) => tapped = value,
    );

    await tester.tap(find.text('漫长的季节'));
    expect(tapped, same(item));
  });

  testWidgets('所有轨道卡片同宽（含推荐卡）', (tester) async {
    await _pumpRail(
      tester,
      HomeRail(
        kind: HomeRailKind.resume,
        title: '继续观看',
        items: [_item(kind: HomeItemKind.resume, title: '漫长的季节')],
      ),
    );
    final resumeWidth = tester
        .getSize(find.byKey(HomePosterCard.posterFrameKey))
        .width;

    await _pumpRail(
      tester,
      HomeRail(
        kind: HomeRailKind.recommendTmdb,
        title: '个性推荐 · TMDB',
        items: [_item(kind: HomeItemKind.recommend, title: '漫长的季节')],
      ),
    );
    final recommendWidth = tester
        .getSize(find.byKey(HomePosterCard.posterFrameKey))
        .width;

    // 用户 2026-11-19：「各推荐栏目的卡片大小不一需要统一」——首页一屏只有横向
    // 条，不同宽度的行读起来像没对齐。详情页的 0.86 不搬到首页来。
    expect(recommendWidth, moreOrLessEquals(resumeWidth));
  });
}
