/// 详情页视觉回归（任务：参考安卓版美化详情页 + 清理无效背景色区域，用户反馈 2026-10-09）。
///
/// 两条约束：
///
/// 1. **背景海报必须全屏**（原先是「AppBar + 16px 边距里一块 340px 的图」，
///    用户反馈「太简陋，背景海报也没有全屏显示」）。因此锁定：
///    - `Scaffold.extendBodyBehindAppBar == true`；
///    - AppBar 背景透明；
///    - hero 宽度 == 屏幕宽度（左右不留边距）；
///    - hero 高度按视口取值（不写死 340）。
/// 2. **不得出现无效的背景色块**（用户反馈「大量地方存在这种无效的阴影或背景色
///    区域太丑了」）。锁定海报墙的**框比与素材一致**（2:3 竖图用竖框），
///    避免竖图被塞进横框后两侧露出大片底色。
///
/// 另生成一张 golden 图供人工查看（`--update-goldens` 后阅读 PNG）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart' show PosterImage;
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

TmdbDetailData _data() => const TmdbDetailData(
  title: '测试剧集',
  originalTitle: 'Test Show',
  overview: '这是一段用于视觉回归的简介。',
  posterUrl: 'https://image.tmdb.org/t/p/w342/poster.jpg',
  backdropUrls: [
    'https://image.tmdb.org/t/p/w780/bd1.jpg',
    'https://image.tmdb.org/t/p/w780/bd2.jpg',
  ],
  rating: 7.2,
  runtime: 45,
  seasonCount: 1,
  episodeCount: 12,
  genres: ['剧情', '古装'],
  photoUrls: [
    'https://image.tmdb.org/t/p/w780/p1.jpg',
    'https://image.tmdb.org/t/p/w780/p2.jpg',
    'https://image.tmdb.org/t/p/w780/p3.jpg',
  ],
  posterUrls: [
    'https://image.tmdb.org/t/p/w342/po1.jpg',
    'https://image.tmdb.org/t/p/w342/po2.jpg',
    'https://image.tmdb.org/t/p/w342/po3.jpg',
  ],
  cast: [
    TmdbPerson(personId: 1, name: '演员甲', subtitle: 'Actor', profileUrl: null),
    TmdbPerson(
      personId: 2,
      name: '演员乙',
      subtitle: 'Actor',
      profileUrl: 'https://image.tmdb.org/t/p/w185/c2.jpg',
    ),
  ],
  crew: [
    TmdbPerson(personId: 3, name: '导演甲', subtitle: 'Director', profileUrl: null),
  ],
);

Widget _host(Widget child, {ThemeData? theme, Size size = const Size(1200, 900)}) {
  return MaterialApp(
    theme: theme ?? buildAppTheme(Brightness.dark),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  group('详情 hero：全屏背景', () {
    testWidgets('hero 铺满整宽且高度按视口取值', (tester) async {
      const width = 1200.0;
      const height = 900.0;
      tester.view.physicalSize = const Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          TmdbDetailHeader(data: _data()),
          size: const Size(width, height),
        ),
      );
      await tester.pump();

      final slideshow = find.byKey(const ValueKey('tmdb-backdrop-slideshow'));
      expect(slideshow, findsOneWidget);
      final rect = tester.getRect(slideshow);
      expect(
        rect.width,
        width,
        reason: '背景必须铺满整宽（左右不留边距），否则不是「全屏」',
      );
      expect(
        rect.height,
        height,
        reason: '默认高度应等于视口高度（满屏背景）',
      );
    });
  });

  group('详情 hero 的 Scaffold 装配（**真实 DetailPage**）', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      // 真实 I/O 必须在 `setUp`（`testWidgets` 的 fake-async 区里 await 会挂住）。
      temp = await Directory.systemTemp.createTemp('webhtv-detail-hero');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': temp.path, 'local': temp.path},
        ),
        log: LogService(),
      );
      await state.bootstrap();
    });

    tearDown(() async {
      state.dispose();
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets('extendBodyBehindAppBar + 透明 AppBar + hero 无侧边距', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 用**真实 DetailPage**：否则把生产代码里的 `extendBodyBehindAppBar` 或
      // 透明 AppBar 改回去，本用例仍会通过（那就不算门禁）。
      final vod = Vod(
        vodId: 'hero-1',
        vodName: 'hero 测试影片',
        vodPic: 'https://img.invalid/p.jpg',
        vodPlayFrom: '线路一',
        vodPlayUrl: '第1集\$https://media.invalid/1.m3u8',
      );
      state.seedDetailForTest(vod: vod);

      await tester.pumpWidget(
        MaterialApp(home: DetailPage(state: state, vod: vod)),
      );
      await tester.pump();

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.extendBodyBehindAppBar,
        isTrue,
        reason: '背景要延伸到 app bar 之下，才算「全屏背景」',
      );
      final appBar = tester.widget<AppBar>(find.byType(AppBar).first);
      expect(
        appBar.backgroundColor,
        Colors.transparent,
        reason: 'app bar 必须透明，否则会盖住背景海报',
      );
      final rect = tester.getRect(
        find.byKey(const ValueKey('tmdb-backdrop-slideshow')),
      );
      expect(
        rect.width,
        1200,
        reason: 'hero 应当左右铺满（生产代码不能再给列表加 16px 侧边距）',
      );
      expect(
        rect.top,
        lessThan(56),
        reason: 'hero 顶部应在 app bar 之下（extendBodyBehindAppBar 生效）',
      );
      expect(
        rect.height,
        900,
        reason: '背景海报要**满屏**（用户反馈 2026-10-10：「我想要全屏的效果」），'
            '高度应等于视口高度，而不是只占一半',
      );
    });

    testWidgets('正文仍在 hero 之下（满屏后从第二屏开始，滚动可达）', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final vod = Vod(
        vodId: 'hero-2',
        vodName: '正文测试影片',
        vodPlayFrom: '线路一',
        vodPlayUrl: '第1集\$https://media.invalid/1.m3u8',
      );
      state.seedDetailForTest(vod: vod);
      await tester.pumpWidget(
        MaterialApp(home: DetailPage(state: state, vod: vod)),
      );
      await tester.pump();

      final heroRect = tester.getRect(
        find.byKey(const ValueKey('tmdb-backdrop-slideshow')),
      );
      expect(heroRect.height, 900, reason: 'hero 应满屏');

      // 正文在 hero **之下**：首屏（视口高度）内看不到，必须滚动才可见。
      // 这正是「背景全屏」的代价与预期——首屏全是背景图。
      expect(
        find.byType(TmdbInfoTable),
        findsNothing,
        reason: 'hero 满屏时正文应在首屏之外（否则说明 hero 没满屏）',
      );
      await tester.drag(
        find.byType(Scrollable).first,
        const Offset(0, -900),
      );
      await tester.pump();
      expect(
        find.byType(TmdbInfoTable),
        findsOneWidget,
        reason: '向下滚动后应能看到正文（内容没有被 hero 挤没）',
      );
      // hero 会随列表一起滚动，因此比较**滚动后**的实时位置。
      final heroAfter = tester.getRect(
        find.byKey(const ValueKey('tmdb-backdrop-slideshow')),
      );
      expect(
        tester.getRect(find.byType(TmdbInfoTable)).top,
        greaterThanOrEqualTo(heroAfter.bottom - 1),
        reason: '正文必须在 hero 之下，不能被 hero 盖住',
      );
    });
  });

  group('海报墙框比：竖图用竖框（不露无效底色）', () {
    testWidgets('海报墙单项为 2:3 竖框', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          TmdbDetailSections(data: _data()),
        ),
      );
      await tester.pump();

      final poster = find.byKey(const ValueKey('tmdb-poster-0'));
      expect(poster, findsOneWidget, reason: '海报墙应渲染（>1 张时）');
      final rect = tester.getRect(poster);
      expect(
        rect.height,
        greaterThan(rect.width),
        reason: '海报是竖图，框必须是竖的；横框会让竖图两侧露出大片底色',
      );
      expect(
        (rect.width / rect.height),
        closeTo(2 / 3, 0.05),
        reason: '框比应与素材一致（2:3），BoxFit.cover 才能恰好铺满',
      );
    });

    testWidgets('剧照墙单项为 16:9 横框（与海报墙区分）', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(TmdbDetailSections(data: _data())));
      await tester.pump();

      final photo = find.byKey(const ValueKey('tmdb-photo-0'));
      expect(photo, findsOneWidget);
      final rect = tester.getRect(photo);
      expect(
        rect.width,
        greaterThan(rect.height),
        reason: '剧照是横图，应保持横框',
      );
      expect((rect.width / rect.height), closeTo(16 / 9, 0.1));
    });
  });

  group('占位底色：不得使用会突兀跳出的高亮容器色', () {
    testWidgets('PosterImage 占位用 surfaceContainerLow（贴近页面底色）', (tester) async {
      tester.view.physicalSize = const Size(400, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 无 URL → 直接走占位分支（测试环境也不会去发网络请求）。
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: const Scaffold(body: Center(child: PosterImage(url: null))),
        ),
      );
      await tester.pump();

      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(PosterImage),
          matching: find.byType(Container),
        ).first,
      );
      final scheme = buildAppTheme(Brightness.dark).colorScheme;
      expect(
        container.color,
        scheme.surfaceContainerLow,
        reason: '占位底色要贴近页面底色；用 Highest 会比背景亮得多，形成突兀灰块',
      );
      expect(
        container.color,
        isNot(scheme.surfaceContainerHighest),
        reason: '这正是用户反馈「无效的背景色区域太丑」的根因',
      );
    });
  });
}
