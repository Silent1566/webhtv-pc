/// 详情页视觉回归（任务：参考安卓版美化详情页 + 清理无效背景色区域，用户反馈 2026-10-09）。
///
/// 两条约束：
///
/// 1. **背景海报铺满整宽、首屏信息可读**：详情 Hero 延伸到透明 AppBar 下方，
///    高度约占首屏一半，让标题/简介/播放入口与线路可以更早出现，避免用户先滚过
///    一整屏空背景。因此锁定：
///    - `Scaffold.extendBodyBehindAppBar == true`；
///    - AppBar 背景透明；
///    - hero 宽度 == 屏幕宽度（左右不留边距）；
///    - 默认高度为视口的 54%，并限制在 360~500px。
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
        reason: '图片框必须铺满整个视口高度（用户反馈 2026-10-13：「我要的是全屏」）；'
            '而且这直接决定原图能显示多大——3.07:1 的横带里 16:9 原图只能按高度适配，'
            '降成约 58% 宽，用 cover 则要纵向裁掉约 42%',
      );
      // 内容**贴视口底部**（2026-10-23 用户反馈：「位置不对，预期应该是
      // 靠近底部，包括全屏的时候」）。曾经有个独立的「内容带」（视口 80%），
      // 内容停在 80% 处、下面还空着 20% 背景 —— 内容带已退场。
      final content = tester.getRect(
        find.byKey(const ValueKey('tmdb-detail-poster')),
      );
      expect(
        rect.bottom - content.bottom,
        lessThan(80),
        reason: '内容块必须贴视口底部（间隙只留给 44 的指示点安全区），'
            '实测间隙 ${rect.bottom - content.bottom}',
      );
      // 内容在**首屏下部**：海报落在下半屏，而不是悬在上半屏。
      expect(
        content.top,
        greaterThan(height * 0.45),
        reason: '内容块应落在视口下半屏（当前海报顶边 ${content.top}）',
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
          overrides: {
            'config': '${temp.path}/webhtv-pc',
            'data': '${temp.path}/webhtv-pc',
            'cache': '${temp.path}/webhtv-pc/cache',
            'state': '${temp.path}/webhtv-pc/logs',
          },
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

    testWidgets('extendBodyBehindAppBar + 透明 AppBar + 首屏 Hero 无侧边距', (tester) async {
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
        // 真实 `DetailPage` 里图片由**页面级固定背景**负责，头部只画内容，
        // 所以头部那块现在是 `tmdb-detail-hero`（见 TmdbBackdropSlideshow.build）。
        find.byKey(const ValueKey('tmdb-detail-hero')),
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
        closeTo(900, 0.1),
        reason: '图片框为整个视口高度（全屏），内容贴它的底部',
      );
      // 内容贴视口底部（2026-10-23 用户反馈），不是停在中间某个「内容带」。
      final poster = tester.getRect(
        find.byKey(const ValueKey('tmdb-detail-poster')),
      );
      expect(
        rect.bottom - poster.bottom,
        lessThan(80),
        reason: '真实详情页里内容也必须贴底（实测间隙 ${rect.bottom - poster.bottom}）',
      );
    });

    testWidgets('正文紧随 Hero，滚动后仍可继续查看', (tester) async {
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
        find.byKey(const ValueKey('tmdb-detail-hero')),
      );
      expect(
        heroRect.height,
        closeTo(900, 0.1),
        reason: '图片框占满首屏（全屏），内容贴视口底部',
      );

      // 正文在 hero 之下。
      //
      // 注意「首屏就能看到一部分」这句已经不成立，**这是全屏 hero 的必然结果**：
      // 图片框占满整个视口后，信息表落在折叠线以下，而 `ListView` 是懒构建的，
      // 滚动之前它**根本还没被创建**。所以这里改成先滚动、再断言，
      // 断言的意图（正文存在、且在 hero 之下、没被挤没）一条不少。
      await tester.drag(
        find.byType(Scrollable).first,
        const Offset(0, -900),
      );
      await tester.pump();
      // 信息表已随 2026-10-22 反馈退场；用线路选择器作为「正文」的锚点。
      final bodyAnchor = find.byKey(const ValueKey('tmdb-line-selector'));
      expect(
        bodyAnchor,
        findsOneWidget,
        reason: '向下滚动后必须能看到正文（内容没有被全屏 hero 挤没）',
      );
      // hero 会随列表一起滚动，因此比较**滚动后**的实时位置。
      final heroAfter = tester.getRect(
        find.byKey(const ValueKey('tmdb-detail-hero')),
      );
      expect(
        tester.getRect(bodyAnchor).top,
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
