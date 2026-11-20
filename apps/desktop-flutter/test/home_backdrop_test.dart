/// 页面级固定海报：滚下去也看得见（用户 2026-11-20：「首页参考详情页海报滚动往下也能看到」）。
///
/// 为什么单独钉这一层：hero 的图**必须**由这个层负责，hero 自己再画一次就会变成
/// 两张同图、不同框比（滚动时在交界处错位，见 `backdrop_scrim.dart` 与
/// `tmdb_detail_view.dart` 的 `paintImage` 注释）。所以这里钉的是三件事：
/// 铺满整块可用区域、压上**页面级**遮罩、下标换了图跟着换。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/ui/backdrop_scrim.dart';
import 'package:webhtv_pc/ui/home_backdrop.dart';
import 'package:webhtv_pc/ui/poster_image.dart';
import 'package:webhtv_pc/ui/theme.dart';

HomeItem item(String title, {String? backdrop, String? poster}) => HomeItem(
  kind: HomeItemKind.resume,
  key: title,
  title: title,
  poster: poster,
  backdrop: backdrop,
);

Future<void> pumpBackdrop(
  WidgetTester tester,
  List<HomeItem> items, {
  int index = 0,
  bool disableAnimations = false,
  bool settle = true,
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
            body: HomeBackdrop(items: items, index: index),
          ),
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

String posterUrl(WidgetTester tester) =>
    tester.widget<PosterImage>(find.byType(PosterImage)).url ?? '';

void main() {
  testWidgets('有 16:9 背景图：铺满可用区域 + cover/顶部对齐 + 页面级遮罩', (tester) async {
    await pumpBackdrop(tester, [
      item(
        'A',
        backdrop: 'http://127.0.0.1:1/a.jpg',
        poster: 'http://127.0.0.1:1/a2.jpg',
      ),
    ]);

    expect(posterUrl(tester), 'http://127.0.0.1:1/a.jpg');
    final image = tester.widget<PosterImage>(find.byType(PosterImage));
    expect(image.fit, BoxFit.cover);
    expect(image.alignment, Alignment.topCenter);
    // 整块可用区域：滚动时它不动，所以高度必须与内容区一致，不能按 hero 高裁。
    expect(
      tester.getSize(find.byKey(const ValueKey('home-backdrop'))),
      const Size(1280, 800),
    );
    final scrims = tester.widgetList<BackdropScrim>(find.byType(BackdropScrim));
    expect(scrims.single.kind, BackdropScrimKind.page);
  });

  testWidgets('只有竖版海报：不把它拉成宽幅，只留页面底色', (tester) async {
    await pumpBackdrop(tester, [
      item('A', poster: 'http://127.0.0.1:1/a2.jpg'),
    ]);

    expect(find.byType(PosterImage), findsNothing);
    expect(find.byType(BackdropScrim), findsNothing);
    expect(find.byKey(const ValueKey('home-backdrop-plain')), findsOneWidget);
  });

  testWidgets('下标换了背景跟着换（页面把 hero 的当前下标传进来）', (tester) async {
    final items = [
      item('A', backdrop: 'http://127.0.0.1:1/a.jpg'),
      item('B', backdrop: 'http://127.0.0.1:1/b.jpg'),
    ];
    await pumpBackdrop(tester, items);
    expect(posterUrl(tester), 'http://127.0.0.1:1/a.jpg');

    await pumpBackdrop(tester, items, index: 1);
    await tester.pumpAndSettle();
    expect(posterUrl(tester), 'http://127.0.0.1:1/b.jpg');
  });

  testWidgets('下标越界取模（条目数变少时不会空成一块底色）', (tester) async {
    await pumpBackdrop(tester, [
      item('A', backdrop: 'http://127.0.0.1:1/a.jpg'),
      item('B', backdrop: 'http://127.0.0.1:1/b.jpg'),
    ], index: 3);
    expect(posterUrl(tester), 'http://127.0.0.1:1/b.jpg');
  });

  testWidgets('没有条目（空态首屏）只画页面底色', (tester) async {
    await pumpBackdrop(tester, const []);
    expect(find.byKey(const ValueKey('home-backdrop-plain')), findsOneWidget);
    expect(find.byType(PosterImage), findsNothing);
  });

  testWidgets('有图切无图时，旧图淡出期间仍有页面遮罩', (tester) async {
    final items = [item('A', backdrop: 'http://127.0.0.1:1/a.jpg'), item('B')];
    await pumpBackdrop(tester, items);
    await pumpBackdrop(tester, items, index: 1, settle: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PosterImage), findsOneWidget);
    expect(
      find.byType(BackdropScrim),
      findsOneWidget,
      reason: '旧图还在淡出，遮罩不能提前移除而闪出未压暗的画面',
    );
    await tester.pumpAndSettle();
    expect(find.byType(PosterImage), findsNothing);
    expect(find.byType(BackdropScrim), findsNothing);
  });

  testWidgets('减少动效时硬切：切换不做淡入', (tester) async {
    await pumpBackdrop(tester, [
      item('A', backdrop: 'http://127.0.0.1:1/a.jpg'),
    ], disableAnimations: true);
    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    expect(switcher.duration, Duration.zero);
  });
}
