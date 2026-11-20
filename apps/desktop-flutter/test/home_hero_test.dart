/// 首页 hero 的行为门禁：轮播节奏、悬停停表、减少动效、指示点、进度线。
///
/// 为什么这些必须有用例：hero 是本页唯一自带 Timer 的组件，且它是「用户没说停
/// 就别停」的反面案例——悬停时换图会把人读一半的内容抽走；而漏掉 dispose 的
/// Timer 会让 flutter_test 直接报 pending timer（仓库在豆瓣节流上踩过一次）。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/ui/backdrop_scrim.dart';
import 'package:webhtv_pc/ui/common.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/poster_image.dart';
import 'package:webhtv_pc/ui/theme.dart';

HomeItem heroItem(
  HomeItemKind kind,
  String title, {
  double progress = 0,
  String reason = '',
  String overview = '',
  List<String> tags = const [],
  String? poster,
  String? backdrop,
}) => HomeItem(
  kind: kind,
  key: title,
  title: title,
  subtitle: '2024 · 8.1',
  overview: overview,
  tags: tags,
  reason: reason,
  progress: progress,
  poster: poster,
  backdrop: backdrop,
);

Future<void> pumpHero(
  WidgetTester tester,
  List<HomeItem> items, {
  bool disableAnimations = false,
  bool paintImage = true,
  ValueChanged<HomeItem>? onPrimary,
  ValueChanged<HomeItem>? onSecondary,
  ValueChanged<int>? onIndexChanged,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(disableAnimations: disableAnimations),
          child: Scaffold(
            body: HomeHero(
              items: items,
              height: 500,
              onPrimary: onPrimary ?? (_) {},
              onSecondary: onSecondary ?? (_) {},
              onIndexChanged: onIndexChanged,
              paintImage: paintImage,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('标题、理由行与主按钮文案按类别渲染', (tester) async {
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, '漫长的季节', reason: '继续观看 · 第08集 · 剩 12 分钟'),
    ]);
    expect(find.text('漫长的季节'), findsOneWidget);
    expect(find.text('继续观看 · 第08集 · 剩 12 分钟'), findsOneWidget);
    expect(find.text('继续播放'), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    expect(find.text('2024 · 8.1'), findsOneWidget);
  });

  testWidgets('有简介时渲染简介（随取图那次 detail 一起回来，不额外请求）', (tester) async {
    await pumpHero(tester, [
      heroItem(
        HomeItemKind.resume,
        '漫长的季节',
        overview: '桦林一座小城的出租车司机王响，在追查儿子死因的十八年里越过越窄。',
      ),
    ]);
    expect(find.text('桦林一座小城的出租车司机王响，在追查儿子死因的十八年里越过越窄。'), findsOneWidget);
  });

  testWidgets('有类型标签时渲染标签行（与详情页同一套静态 TagChip）', (tester) async {
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, '轧戏', tags: const ['剧情', '悬疑']),
    ]);
    expect(find.byType(TagChip), findsNWidgets(2));
    expect(find.text('剧情'), findsOneWidget);
  });

  testWidgets('没有标签时不画标签行', (tester) async {
    await pumpHero(tester, [heroItem(HomeItemKind.resume, '轧戏')]);
    expect(find.byType(TagChip), findsNothing);
  });

  testWidgets('没有简介时不画那一行（不留空行）', (tester) async {
    await pumpHero(tester, [heroItem(HomeItemKind.resume, '漫长的季节')]);
    expect(find.textContaining('因为'), findsNothing);
  });

  testWidgets('追剧的主按钮是「从最新一集开始」', (tester) async {
    await pumpHero(tester, [heroItem(HomeItemKind.following, '繁花')]);
    expect(find.text('从最新一集开始'), findsOneWidget);
  });

  testWidgets('续播画琥珀进度线，追剧不画', (tester) async {
    await pumpHero(tester, [heroItem(HomeItemKind.resume, 'A', progress: 0.4)]);
    expect(find.byKey(const ValueKey('home-hero-progress')), findsOneWidget);

    await pumpHero(tester, [heroItem(HomeItemKind.following, 'B')]);
    expect(find.byKey(const ValueKey('home-hero-progress')), findsNothing);
  });

  testWidgets('多张有指示点，单张没有', (tester) async {
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, 'A'),
      heroItem(HomeItemKind.resume, 'B'),
    ]);
    expect(find.byKey(const ValueKey('home-hero-dots')), findsOneWidget);

    await pumpHero(tester, [heroItem(HomeItemKind.resume, 'A')]);
    expect(find.byKey(const ValueKey('home-hero-dots')), findsNothing);
  });

  testWidgets('自动轮播：一个间隔后换到下一张', (tester) async {
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, 'A'),
      heroItem(HomeItemKind.resume, 'B'),
    ]);
    expect(find.byKey(const ValueKey('home-hero-backdrop-0')), findsOneWidget);
    await tester.pump(homeHeroInterval);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-hero-backdrop-1')), findsOneWidget);
  });

  testWidgets('悬停停表、移开恢复（桌面端鼠标只是路过不该换图）', (tester) async {
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, 'A'),
      heroItem(HomeItemKind.resume, 'B'),
    ]);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    // 悬停点取主按钮：停表只挂在内容块上，不是整块 hero。
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('home-hero-primary'))),
    );
    await tester.pump();

    await tester.pump(homeHeroInterval * 2);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('home-hero-backdrop-0')),
      findsOneWidget,
      reason: '指针停在 hero 上时不该自动换图',
    );

    // 移出内容块（右上角仍是画面上，但不是内容块），MouseRegion 才会收到 exit。
    await mouse.moveTo(const Offset(1200, 60));
    await tester.pump();
    await tester.pump(homeHeroInterval);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-hero-backdrop-1')), findsOneWidget);
  });

  testWidgets('指针停在画面（非内容块）上照常轮播', (tester) async {
    // 用户 2026-11-19 反馈「不会自动切换」：桌面用户的指针大半时间就在窗口里，
    // 若整块 hero 都算悬停，幻灯片等于永远不轮播。停表只该管会挡住阅读的内容块。
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, 'A'),
      heroItem(HomeItemKind.resume, 'B'),
    ]);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(900, 120));
    await tester.pump();
    await tester.pump(homeHeroInterval);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-hero-backdrop-1')), findsOneWidget);
  });

  testWidgets('减少动效时仍轮播，但不做淡入', (tester) async {
    // 治的是「持续运动」，不是「内容会换」：硬切既满足无障碍，也不把这个功能
    // 对这类用户直接关死。
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, 'A'),
      heroItem(HomeItemKind.resume, 'B'),
    ], disableAnimations: true);
    await tester.pump(homeHeroInterval);
    await tester.pump();
    expect(find.byKey(const ValueKey('home-hero-backdrop-1')), findsOneWidget);
  });

  testWidgets('卸载后不留下 pending timer', (tester) async {
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, 'A'),
      heroItem(HomeItemKind.resume, 'B'),
    ]);
    await tester.pump(homeHeroInterval);
    await tester.pumpWidget(const SizedBox());
    // flutter_test 会在用例结束时把未取消的 Timer 报成 pending timer 失败。
  });

  testWidgets('点指示点跳到该张', (tester) async {
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, 'A'),
      heroItem(HomeItemKind.resume, 'B'),
      heroItem(HomeItemKind.resume, 'C'),
    ]);
    final dots = find.byKey(const ValueKey('home-hero-dots'));
    final third = find
        .descendant(of: dots, matching: find.byType(GestureDetector))
        .at(2);
    await tester.tap(third);
    await tester.pumpAndSettle();
    expect(find.text('C'), findsOneWidget);
  });

  testWidgets('主按钮把被点的条目交回页面', (tester) async {
    HomeItem? tapped;
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, 'A'),
    ], onPrimary: (item) => tapped = item);
    await tester.tap(find.byKey(const ValueKey('home-hero-primary')));
    expect(tapped?.title, 'A');
  });

  testWidgets('有 16:9 背景图：hero 不自绘图，图交给页面的固定背景', (tester) async {
    // 两处都画＝两张同图不同框比：滚动时 hero 的图往上走、固定背景不动，
    // 交界处会错位（详情页 `paintImage: false` 是同一条理由）。所以有背景图时
    // hero 只留内容，不碰背景。
    await pumpHero(tester, [
      heroItem(
        HomeItemKind.resume,
        'A',
        backdrop: 'http://127.0.0.1:1/a.jpg',
        poster: 'http://127.0.0.1:1/a2.jpg',
      ),
    ], paintImage: false);
    expect(find.byKey(const ValueKey('home-hero-backdrop-0')), findsNothing);
    expect(find.byType(BackdropScrim), findsNothing);
    expect(find.byType(PosterImage), findsNothing);
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('没有 16:9 背景图：hero 自己画夜空底（不然首屏只剩一块空）', (tester) async {
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, 'A', poster: 'http://127.0.0.1:1/a2.jpg'),
    ]);
    expect(find.byKey(const ValueKey('home-hero-backdrop-0')), findsOneWidget);
    expect(find.byType(BackdropScrim), findsOneWidget);
    // 竖版海报是**内容**（左侧那张大而锐利的海报），不是背景。
    expect(find.byType(PosterImage), findsOneWidget);
  });

  testWidgets('换张时把当前下标回传给页面（固定背景要跟着换）', (tester) async {
    final seen = <int>[];
    await pumpHero(tester, [
      heroItem(HomeItemKind.resume, 'A', backdrop: 'http://127.0.0.1:1/a.jpg'),
      heroItem(HomeItemKind.resume, 'B', backdrop: 'http://127.0.0.1:1/b.jpg'),
      heroItem(HomeItemKind.resume, 'C', backdrop: 'http://127.0.0.1:1/c.jpg'),
    ], onIndexChanged: seen.add);

    await tester.tap(
      find
          .descendant(
            of: find.byKey(const ValueKey('home-hero-dots')),
            matching: find.byType(GestureDetector),
          )
          .at(2),
    );
    await tester.pumpAndSettle();
    expect(seen.last, 2);

    await tester.pump(homeHeroInterval);
    await tester.pumpAndSettle();
    expect(seen.last, 0, reason: '3 张里停在第 3 张，一个间隔后回到第 1 张');
  });
}
