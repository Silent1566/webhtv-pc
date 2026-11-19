/// 首页轨道卡片与轨道的**视觉契约**门禁（`docs/phase11/design/01-home-hero.md` §4）。
///
/// 只钉住"写死就会退回原样"的那几项：海报 2:3 由宽度推、文字区固定 40、
/// 续播才有进度条、空轨道不占位、推荐行的"查看全部"入口不存在。
///
/// 全部用假 [HomeItem] 直接构造：卡片只读模型字段，不需要 `AppState`，
/// 也就不该为了测一张卡片把网络与配置拖进来。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/ui/home_cards.dart';

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
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: HomeRailView(
            rail: rail,
            onTap: onTap ?? (_) {},
            onSeeAll: onSeeAll,
          ),
        ),
      ),
    ),
  );
}

void main() {
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
