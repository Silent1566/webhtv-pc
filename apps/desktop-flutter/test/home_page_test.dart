/// 首页装配层：空态、高度、固定背景与 hero 当前条目的同步。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';

import 'support/home_hd_art_fixture.dart';

import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/home_backdrop.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/detail_test_seams.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-home-page');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: MemoryOnlyLogService(),
    );
    await bootstrapWithoutExternalMeta(state);
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    required VoidCallback onOpenBrowse,
    required VoidCallback onImportConfig,
    ValueChanged<String>? onSearch,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 来源宽图同时被轨道和hero使用；渲染轨道之前先将其真实合成像素放入缓存，
    // 避免testWidgets默认400网络请求与I/O替身竞争同一个key。
    for (final row in state.recentHistory(sourceKey: '')) {
      final url = row.vodPic;
      if (url != null && url.contains('backdrop')) {
        await loadHdHeroFixture(NetworkImage(url), ImageConfiguration.empty);
      }
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: HomePage(
            state: state,
            heroImageLoader: loadHdHeroFixture,
            onOpenBrowse: onOpenBrowse,
            onOpenHistory: () {},
            onOpenFollowing: () {},
            onImportConfig: onImportConfig,
            onSearch: onSearch ?? (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有配置：首屏是占满 hero 高度的空态，不是白屏', (tester) async {
    var browsed = false;
    var imported = false;
    await pumpHome(
      tester,
      onOpenBrowse: () => browsed = true,
      onImportConfig: () => imported = true,
    );

    final hero = find.byKey(const ValueKey('home-hero-startup-placeholder'));
    expect(hero, findsOneWidget);
    expect(find.text('还没有导入配置'), findsOneWidget);
    // 首屏只有一档高度：占满内容区（800），不因为没有背景图缩到 62%。
    expect(tester.getSize(hero).height, closeTo(800, 0.5));
    expect(find.byKey(const ValueKey('home-scroll')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('home-empty-action')));
    expect(imported, isTrue);
    expect(browsed, isFalse);
  });

  testWidgets('无合格宽图时保留同高占位，低窗口仍遵循hero高度下限', (tester) async {
    await pumpHome(tester, onOpenBrowse: () {}, onImportConfig: () {});

    tester.view.physicalSize = const Size(1024, 560);
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('home-hero-startup-placeholder')))
          .height,
      closeTo(560, 0.5),
      reason: '高度不再随素材缩：560 高的窗口里 hero 就是 560',
    );

    // 只有低于下限才夹：300 高的窗口里 hero 仍是 360（否则标题与按钮挤不下）。
    tester.view.physicalSize = const Size(1024, 300);
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('home-hero-startup-placeholder')))
          .height,
      closeTo(360, 0.5),
    );
  });

  testWidgets('有配置但没看过任何东西：空态给出「去点播逛逛」这一条出路', (tester) async {
    await tester.runAsync(() async {
      await state.importConfig(
        '{"sites":[{"key":"demo","name":"示例","type":3,"api":"c1","searchable":1,'
        '"quickSearch":1,"filter":0}]}',
        displayName: 'demo',
      );
    });
    var browsed = false;
    await pumpHome(
      tester,
      onOpenBrowse: () => browsed = true,
      onImportConfig: () {},
    );

    expect(find.text('还没有可续播的内容'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-empty-action')));
    expect(browsed, isTrue);
  });

  testWidgets('站点名命中「直播」关键词的历史行不进首页（内置关键词）', (tester) async {
    // 用户 2026-11-25 图一：直播卡进了 hero。真实数据里那行来自 `site_key=Douyu`
    // 的**站点**（配置里叫「🌇｜斗鱼｜直播」，type 3，和点播站同一种），所以按站点名
    // 与键匹配可配置的关键词（默认「直播」「Live」）。
    await tester.runAsync(() async {
      await state.importConfig(
        '{"sites":[{"key":"demo","name":"示例影视","type":3,"api":"c1","searchable":1,'
        '"quickSearch":1,"filter":0},{"key":"Douyu","name":"🌇｜斗鱼｜直播","type":3,'
        '"api":"c2","searchable":1,"quickSearch":1,"filter":0}]}',
        displayName: 'demo',
      );
    });
    final now = DateTime.now().millisecondsSinceEpoch;
    state.database!.upsertHistory(
      siteKey: 'demo',
      vodId: 'v1',
      vodName: '点播剧',
      flag: '线路一',
      episodeName: '第1集',
      episodeId: 'e1',
      positionMs: 600000,
      durationMs: 2400000,
      updatedAt: now,
    );
    state.database!.upsertHistory(
      siteKey: 'Douyu',
      vodId: '10040721',
      vodName: '冬天到了 该上分了！ 10040721',
      flag: 'DouyuLive',
      episodeName: '原画1080P30',
      episodeId: '10040721_0',
      positionMs: 5000,
      durationMs: 12887,
      updatedAt: now + 1,
    );
    await pumpHome(tester, onOpenBrowse: () {}, onImportConfig: () {});

    expect(
      tester
          .getSize(find.byKey(const ValueKey('home-hero-startup-placeholder')))
          .height,
      800,
    );
    await tester.scrollUntilVisible(
      find.text('点播剧'),
      400,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('home-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('点播剧'), findsOneWidget);
    expect(
      find.textContaining('该上分了'),
      findsNothing,
      reason: '直播行的站点名命中关键词，不进首页',
    );
  });

  testWidgets('背景层在滚动视图之外：滚下去它不动，轨道从它上面滑过', (tester) async {
    // 用户 2026-11-20：「首页参考详情页海报滚动往下也能看到」。
    // 详情页的做法是「页面级固定背景 + 内容滚动」（browse_pages.dart 的
    // Positioned.fill(TmdbDetailBackdrop)）。首页照做：背景必须是滚动视图的
    // **兄弟**节点；进了滚动视图就会跟着滚走——那正是要改掉的行为。
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: 'v1',
      vodName: '漫长的季节',
      vodPic: 'https://fixture.invalid/source-backdrop1.jpg',
      flag: '线路一',
      episodeName: '第08集',
      episodeId: 'http://x/e1',
      positionMs: 1400000,
      durationMs: 2700000,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await pumpHome(tester, onOpenBrowse: () {}, onImportConfig: () {});

    final backdrop = find.byKey(const ValueKey('home-backdrop'));
    expect(backdrop, findsOneWidget);
    expect(
      find.ancestor(of: backdrop, matching: find.byType(CustomScrollView)),
      findsNothing,
      reason: '背景进了滚动视图就会跟着滚走',
    );
    final before = tester.getRect(backdrop);
    expect(
      before.size,
      tester.view.physicalSize / tester.view.devicePixelRatio,
    );
    final heroBefore = tester.getRect(find.byKey(const ValueKey('home-hero')));

    // 从 hero 上方往下拖（横向轨道会吃掉落在自己身上的拖动）。
    await tester.dragFrom(const Offset(640, 200), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byKey(const ValueKey('home-hero'))).top,
      lessThan(heroBefore.top),
      reason: '页面必须真的滚动了，否则这条用例什么都证明不了',
    );
    expect(tester.getRect(backdrop), before, reason: '背景固定：滚动不改变它的位置');
  });

  testWidgets('手动、自动切换与条目数更新后，固定背景始终对应 hero 当前作品', (tester) async {
    void addHistory(int id) {
      state.database!.upsertHistory(
        siteKey: 'site-a',
        vodId: 'v$id',
        vodName: '作品$id',
        vodPic: 'https://fixture.invalid/source-backdrop$id.jpg',
        flag: '线路一',
        episodeName: '第01集',
        episodeId: 'http://x/e$id',
        positionMs: 100000,
        durationMs: 1000000,
        updatedAt: 1000 + id,
      );
    }

    String backgroundTitle() {
      final background = tester.widget<HomeBackdrop>(find.byType(HomeBackdrop));
      return background.items[background.index].title;
    }

    addHistory(1);
    addHistory(2);
    await pumpHome(tester, onOpenBrowse: () {}, onImportConfig: () {});
    expect(backgroundTitle(), '作品2');
    final dots = find.descendant(
      of: find.byKey(const ValueKey('home-hero-dots')),
      matching: find.byType(GestureDetector),
    );
    await tester.tap(dots.at(1));
    await tester.pumpAndSettle();
    expect(backgroundTitle(), '作品1');
    expect(
      find.descendant(of: find.byType(HomeHero), matching: find.text('作品1')),
      findsOneWidget,
    );

    await tester.pump(homeHeroInterval);
    await tester.pumpAndSettle();
    expect(backgroundTitle(), '作品2');

    await tester.tap(dots.at(1));
    await tester.pumpAndSettle();
    addHistory(3);
    await pumpHome(tester, onOpenBrowse: () {}, onImportConfig: () {});
    expect(backgroundTitle(), '作品1', reason: '后台新候选不能打断用户当前阅读的作品');
    expect(
      find.descendant(of: find.byType(HomeHero), matching: find.text('作品1')),
      findsOneWidget,
    );
    final updatedItems = tester.widget<HomeHero>(find.byType(HomeHero)).items;
    expect(
      updatedItems.map((item) => item.title),
      contains('作品3'),
      reason: '保持当前选择不能靠丢弃新候选实现',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
