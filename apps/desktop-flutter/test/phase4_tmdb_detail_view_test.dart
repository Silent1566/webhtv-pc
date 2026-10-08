/// Phase 4 · 详情页视图门禁（`docs/phase4/design/04` §3、§4.2、§6、§11）。
///
/// 对应三条用户反馈（2026-10-07）：
/// 1. **每集没有对应的海报卡片** → 剧集卡片必须带剧照图与副标题；
/// 2. **没有海报、导演等其他信息** → 头部必须渲染海报、导演、评分、时长等；
/// 3. **剧照 / 演职人员 / 相关推荐点击无效** → 点击必须真的打开查看器 / 人物页 /
///    进入该作品详情（用回调与真实 widget 断言，而不是只看有没有回调字段）；
/// 4. **用剧集海报/剧照当动态背景** → 背景必须真的在轮播（假时钟推进后换图）。
///
/// 纯逻辑部分见 `phase4_tmdb_detail_model_test.dart`；本文件只锁 UI 行为。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

const String _imageBase = 'https://images.tmdb.org/t/p/w342';
const String _backdropBase = 'https://images.tmdb.org/t/p/w780';

TmdbDetailData _data() => TmdbDetailData.fromDetail(
  {
    'id': 1399,
    'name': '示例剧集',
    'overview': '这是简介' * 40,
    'first_air_date': '2024-03-01',
    'vote_average': 8.2,
    'number_of_seasons': 2,
    'number_of_episodes': 22,
    'episode_run_time': [45],
    'poster_path': '/tv-poster.jpg',
    'genres': [
      {'id': 18, 'name': '剧情'},
      {'id': 10765, 'name': '科幻'},
    ],
    'production_countries': [
      {'iso_3166_1': 'CN', 'name': '中国'},
    ],
    'status': 'Returning Series',
    'images': {
      'posters': [
        {'file_path': '/p1.jpg', 'width': 680, 'height': 1020},
      ],
      'backdrops': [
        {'file_path': '/b1.jpg', 'width': 1920, 'height': 1080},
        {'file_path': '/b2.jpg', 'width': 1280, 'height': 720},
      ],
      'stills': [
        {'file_path': '/still1.jpg', 'width': 1920, 'height': 1080},
        {'file_path': '/still2.jpg', 'width': 1280, 'height': 720},
      ],
    },
    'seasons': [
      {
        'season_number': 1,
        'name': '第 1 季',
        'episode_count': 12,
        'air_date': '2024-03-01',
        'poster_path': '/s1.jpg',
      },
      {
        'season_number': 2,
        'name': '第 2 季',
        'episode_count': 10,
        'air_date': '2025-04-05',
        'poster_path': '/s2.jpg',
      },
    ],
    'aggregate_credits': {
      'cast': [
        {
          'id': 287,
          'name': '示例演员',
          'roles': [
            {'character': '主角', 'episode_count': 12},
          ],
          'profile_path': '/person.jpg',
        },
      ],
    },
    'credits': {
      'crew': [
        {
          'id': 500,
          'name': '示例导演',
          'job': 'Director',
          'department': 'Directing',
          'profile_path': '/crew.jpg',
        },
      ],
    },
  },
  imageBase: _imageBase,
  backdropBase: _backdropBase,
);

const List<TmdbEpisodeCard> _cards = [
  TmdbEpisodeCard(
    number: 1,
    title: 'E1 开端',
    date: '2024-03-01',
    overview: '第一集简介',
    stillUrl: '$_imageBase/s1e1.jpg',
    runtime: 45,
    rating: 7.3,
    seasonNumber: 1,
  ),
  TmdbEpisodeCard(
    number: 2,
    title: 'E2 发展',
    date: '2024-03-08',
    stillUrl: '$_imageBase/s1e2.jpg',
    seasonNumber: 1,
  ),
];

/// 让目标**真正进入视口**。
///
/// 两个坑都踩过：
/// 1. `tester.scrollUntilVisible` 要求页面里只有一个 `Scrollable`，而详情页
///    同时有纵向页面列表与剧集/剧照/人员的横向列表 → `Bad state: Too many
///    elements`；
/// 2. 只判断 `finder.evaluate().isNotEmpty` 不够：横向 `ListView` 会把项
///    **构建**在视口外（缓存区），此时 widget 存在但 `tap` 打不中
///    （实测 y=743 超出 600 高视口）。
///
/// 因此先用 `ensureVisible`（它走 `Scrollable.ensureVisible`，能正确处理嵌套
/// 滚动），再断言目标矩形确实落在视口内，否则继续拖外层列表兜底。
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    if (target.evaluate().isNotEmpty) {
      await tester.ensureVisible(target);
      await tester.pump();
      final rect = tester.getRect(target);
      final view = tester.view.physicalSize / tester.view.devicePixelRatio;
      if (rect.bottom > 0 && rect.top < view.height) return;
    }
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await tester.pump();
  }
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(child: child),
  ),
);

/// 取某个 key 对应的 [PosterImage] 的 URL（证明「真的渲染了图片」）。
String? _posterUrlOf(WidgetTester tester, Key key) {
  final finder = find.descendant(
    of: find.byKey(key),
    matching: find.byType(Image),
    matchRoot: true,
  );
  if (finder.evaluate().isEmpty) return null;
  final image = tester.widget<Image>(finder.first);
  final provider = image.image;
  return provider is NetworkImage ? provider.url : null;
}

void main() {
  group('动态背景（用户反馈 4：用海报/剧照当动态背景）', () {
    testWidgets('渲染背景图，且按 5 秒节奏轮播（假时钟推进后换图）', (tester) async {
      final data = _data();
      expect(data.backdropUrls.length, greaterThan(1), reason: '前置：多张背景图');

      await tester.pumpWidget(_host(TmdbBackdropSlideshow(urls: data.backdropUrls)));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tmdb-backdrop-0')),
        findsOneWidget,
        reason: '首帧必须是第一张背景图',
      );
      expect(
        _posterUrlOf(tester, const ValueKey('tmdb-backdrop-0')),
        data.backdropUrls.first,
      );
      expect(
        find.byKey(const ValueKey('tmdb-backdrop-dots')),
        findsOneWidget,
        reason: '多张图时必须显示进度点',
      );

      // 推进 5 秒：必须切到第二张。
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(const ValueKey('tmdb-backdrop-1')),
        findsOneWidget,
        reason: '5 秒后必须轮播到第二张背景图',
      );

      // 再推进 5 秒：环形回到第一张。
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(const ValueKey('tmdb-backdrop-0')),
        findsOneWidget,
        reason: '轮播必须环形回到第一张',
      );
    });

    testWidgets('只有一张图时不启动轮播（不显示进度点、不换图）', (tester) async {
      await tester.pumpWidget(
        _host(const TmdbBackdropSlideshow(urls: ['https://img/only.jpg'])),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('tmdb-backdrop-dots')), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(find.byKey(const ValueKey('tmdb-backdrop-0')), findsOneWidget);
    });

    testWidgets('无背景图时回退海报（不留白）', (tester) async {
      await tester.pumpWidget(
        _host(
          const TmdbBackdropSlideshow(
            urls: [],
            fallbackUrl: 'https://img/poster.jpg',
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('tmdb-backdrop-empty')), findsNothing);
      expect(
        _posterUrlOf(tester, const ValueKey('tmdb-backdrop-0')),
        'https://img/poster.jpg',
      );
    });
  });

  group('头部信息（用户反馈 2：海报 / 导演 / 其他信息）', () {
    testWidgets('渲染海报、标题、导演、评分、时长、季集数、类型', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 1200,
            height: 400,
            child: TmdbDetailHeader(data: _data()),
          ),
        ),
      );
      await tester.pump();

      expect(
        _posterUrlOf(tester, const ValueKey('tmdb-detail-poster')),
        '$_imageBase/p1.jpg',
        reason: '头部必须有海报',
      );
      expect(find.byKey(const ValueKey('tmdb-detail-title')), findsOneWidget);
      expect(find.text('导演：示例导演'), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-detail-rating')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-detail-year')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-detail-runtime')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-detail-seasons')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-detail-genres')), findsOneWidget);
    });
  });

  group('剧集海报卡片（用户反馈 1：每集没有对应的海报卡片）', () {
    testWidgets('每张卡片都有剧照、集号徽标与标题；数量等于卡片数', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 1200,
            child: TmdbEpisodeStrip(
              cards: _cards,
              keyPrefix: 'tmdb-episode-card-线路一',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        _posterUrlOf(
          tester,
          const ValueKey('tmdb-episode-card-线路一-still-1'),
        ),
        '$_imageBase/s1e1.jpg',
        reason: '每集必须有对应的剧照图片',
      );
      expect(
        _posterUrlOf(
          tester,
          const ValueKey('tmdb-episode-card-线路一-still-2'),
        ),
        '$_imageBase/s1e2.jpg',
      );
      expect(find.text('S1E1'), findsOneWidget);
      expect(find.text('E1 开端'), findsOneWidget);
      expect(find.textContaining('2024-03-01'), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-episode-card-线路一-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-episode-card-线路一-1')), findsOneWidget);
    });

    testWidgets('点击卡片回调携带渲染下标（保证点哪集播哪集）', (tester) async {
      var tapped = -1;
      TmdbEpisodeCard? tappedCard;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 1200,
            child: TmdbEpisodeStrip(
              cards: _cards,
              onTap: (index, card) {
                tapped = index;
                tappedCard = card;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-card-1')));
      expect(tapped, 1);
      expect(tappedCard?.number, 2);
    });

    testWidgets('无剧照时仍渲染卡片（占位，不丢集）', (tester) async {
      await tester.pumpWidget(
        _host(
          const SizedBox(
            width: 600,
            child: TmdbEpisodeStrip(
              cards: [
                TmdbEpisodeCard(number: 1, title: '第1集'),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('tmdb-episode-card-0')), findsOneWidget);
      expect(find.text('第1集'), findsOneWidget);
    });

    testWidgets('单集详情弹窗展示剧照、标题、简介与动作', (tester) async {
      var acted = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showTmdbEpisodeSheet(
                  context,
                  card: _cards.first,
                  actionLabel: '播放',
                  onAction: () => acted = true,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('tmdb-episode-sheet')), findsOneWidget);
      expect(
        _posterUrlOf(tester, const ValueKey('tmdb-episode-sheet-still')),
        '$_imageBase/s1e1.jpg',
      );
      expect(find.text('E1 开端'), findsOneWidget);
      expect(find.text('第一集简介'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tmdb-episode-sheet-action')));
      await tester.pumpAndSettle();
      expect(acted, isTrue, reason: '弹窗动作必须真的触发播放');
    });
  });

  group('剧照墙（用户反馈 3：剧照点击无效）', () {
    testWidgets('点击第 N 张打开查看器并定位到第 N 张，可翻页', (tester) async {
      final data = _data();
      await tester.pumpWidget(
        _host(
          SizedBox(width: 1200, child: TmdbDetailSections(data: data)),
        ),
      );
      await tester.pump();

      await _scrollTo(
        tester,
        find.byKey(const ValueKey('tmdb-section-photos')),
      );
      expect(find.byKey(const ValueKey('tmdb-section-photos')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tmdb-photo-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('tmdb-photo-viewer')), findsOneWidget);
      expect(
        _posterUrlOf(tester, const ValueKey('tmdb-photo-viewer-image')),
        data.photoUrls[1],
        reason: '查看器必须定位到被点击的那一张',
      );
      expect(find.textContaining('2/2'), findsOneWidget);

      // 单张以外的翻页按钮存在；点「下一张」环绕回第一张。
      await tester.tap(find.byKey(const ValueKey('tmdb-photo-viewer-next')));
      await tester.pumpAndSettle();
      expect(
        _posterUrlOf(tester, const ValueKey('tmdb-photo-viewer-image')),
        data.photoUrls[0],
      );
      expect(find.textContaining('1/2'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tmdb-photo-viewer-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tmdb-photo-viewer')), findsNothing);
    });
  });

  group('演职人员（用户反馈 3：演职人员点击无效）', () {
    testWidgets('点击头像回调携带该人物（用于打开人物页）', (tester) async {
      TmdbPerson? tapped;
      final data = _data();
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 1200,
            child: TmdbDetailSections(
              data: data,
              onPersonTap: (person) => tapped = person,
            ),
          ),
        ),
      );
      await tester.pump();

      await _scrollTo(
        tester,
        find.byKey(const ValueKey('tmdb-section-people')),
      );
      expect(find.byKey(const ValueKey('tmdb-section-people')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tmdb-person-287')));
      expect(tapped?.personId, 287);
      expect(tapped?.name, '示例演员');
    });
  });

  group('相关推荐（用户反馈 3：相关推荐点击无效）', () {
    testWidgets('点击推荐项回调携带该作品（用于进入其详情）', (tester) async {
      TmdbItem? tapped;
      const item = TmdbItem(
        tmdbId: 550,
        mediaType: TmdbMediaType.movie,
        title: '推荐电影',
        posterUrl: 'https://img/r.jpg',
      );
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 1200,
            child: TmdbDetailSections(
              data: _data(),
              recommendations: const [item],
              onRecommendationTap: (value) => tapped = value,
            ),
          ),
        ),
      );
      await tester.pump();

      final section = find.byKey(
        const ValueKey('tmdb-section-recommendations'),
      );
      await _scrollTo(tester, section);
      expect(section, findsOneWidget);
      final entry = find.byKey(
        const ValueKey('tmdb-recommendation-movie:550'),
      );
      await _scrollTo(tester, entry);
      await tester.tap(entry);
      expect(tapped?.tmdbId, 550);
      expect(tapped?.title, '推荐电影');
    });
  });

  group('纯 TMDB 详情页约束（`04` §6.2：剧集卡片不得可播）', () {
    testWidgets('剧集卡片动作文案为「搜索站源」，且没有播放按钮', (tester) async {
      var searched = false;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 1200,
            child: TmdbEpisodeStrip(
              cards: _cards,
              actionLabel: '搜索站源',
              onTap: (_, _) => searched = true,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('播放'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-card-0')));
      expect(searched, isTrue);
    });
  });

  group('键盘与布局（`04` §11）', () {
    testWidgets('查看器支持左右方向键翻页与 Esc 关闭', (tester) async {
      final data = _data();
      await tester.pumpWidget(
        _host(
          SizedBox(width: 1200, child: TmdbDetailSections(data: data)),
        ),
      );
      await tester.pump();
      await _scrollTo(
        tester,
        find.byKey(const ValueKey('tmdb-section-photos')),
      );
      await tester.tap(find.byKey(const ValueKey('tmdb-photo-0')));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        _posterUrlOf(tester, const ValueKey('tmdb-photo-viewer-image')),
        data.photoUrls[1],
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        _posterUrlOf(tester, const ValueKey('tmdb-photo-viewer-image')),
        data.photoUrls[0],
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tmdb-photo-viewer')), findsNothing);
    });

    testWidgets('窄窗口（900px）不溢出，头部仍渲染海报与导演', (tester) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              child: TmdbDetailHeader(data: _data()),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '900px 宽不得溢出');
      expect(find.byKey(const ValueKey('tmdb-detail-director')), findsOneWidget);
      expect(
        _posterUrlOf(tester, const ValueKey('tmdb-detail-poster')),
        isNotNull,
      );
    });
  });

  group('详情页整页渲染（`04` §11：窗口缩放不重叠）', () {
    testWidgets('1600x2600 整页渲染：无溢出，且关键区块全部出现', (tester) async {
      tester.view.physicalSize = const Size(1600, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      const item = TmdbItem(
        tmdbId: 550,
        mediaType: TmdbMediaType.movie,
        title: '推荐电影',
        posterUrl: 'https://img/r.jpg',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TmdbDetailView(
                data: _data(),
                seasons: _data().seasons,
                selectedSeason: 1,
                selectableSeasons: const [1, 2],
                episodeCards: _cards,
                recommendations: const [item],
                episodeKeyPrefix: 'tmdb-only-episode',
                infoRows: const [('类型', '剧情 / 科幻'), ('时长', '45 分钟')],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '整页渲染不得溢出');
      // 首屏区块（动态背景 / 头部 / 信息表 / 季度 / 剧集区块）。
      for (final key in const [
        'tmdb-backdrop-slideshow',
        'tmdb-detail-poster',
        'tmdb-detail-director',
        'tmdb-info-table',
        'tmdb-section-seasons',
        'tmdb-section-episodes',
        'tmdb-episode-header',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '缺少区块 $key');
      }
      expect(
        find.byKey(const ValueKey('tmdb-only-episode-0')),
        findsOneWidget,
        reason: '剧集卡片必须渲染',
      );
      // 后续区块（剧照/海报/演职人员/推荐）在可滚动页面下方，逐段滚到可见。
      // 页面变长后一次性断言会因懒加载而找不到，因此滚动收集。
      for (final key in const [
        'tmdb-section-photos',
        'tmdb-section-posters',
        'tmdb-section-people',
        'tmdb-section-recommendations',
      ]) {
        await _scrollTo(tester, find.byKey(ValueKey(key)));
        expect(
          find.byKey(ValueKey(key)),
          findsOneWidget,
          reason: '滚动后仍缺少区块 $key',
        );
      }
    });
  });

  group('线路选择（`04` §3.1 ④：点击切换线路显示对应的集数卡片）', () {
    const lines = [
      VodPlayLine(flag: '线路一', episodes: []),
      VodPlayLine(flag: '线路二', episodes: []),
    ];

    testWidgets('渲染每条线路与各自集数，当前线路被选中', (tester) async {
      VodPlayLine? tapped;
      await tester.pumpWidget(
        _host(
          TmdbLineSelector(
            lines: lines,
            selectedFlag: '线路二',
            episodeCounts: const {'线路一': 22, '线路二': 8},
            onChanged: (line) => tapped = line,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('tmdb-line-selector')), findsOneWidget);
      expect(find.text('线路一（22 集）'), findsOneWidget);
      expect(find.text('线路二（8 集）'), findsOneWidget);
      // 当前线路必须处于选中态（用户据此确认在看哪条线路）。
      final chip = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路二')),
      );
      expect(chip.selected, isTrue);
      final other = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('tmdb-line-线路一')),
      );
      expect(other.selected, isFalse);

      await tester.tap(find.byKey(const ValueKey('tmdb-line-线路一')));
      expect(tapped?.flag, '线路一');
    });

    testWidgets('单线路也渲染（不隐藏，避免用户不知道有几条线路）', (tester) async {
      await tester.pumpWidget(
        _host(
          const TmdbLineSelector(
            lines: [VodPlayLine(flag: '唯一线路', episodes: [])],
            selectedFlag: '唯一线路',
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('tmdb-line-唯一线路')), findsOneWidget);
    });
  });

  group('剧集区块头（`04` §3.1 ⑤：正序倒序 / 列表网格）', () {
    testWidgets('显示集数与线路名，切换按钮回调生效', (tester) async {
      var reversedToggles = 0;
      var gridToggles = 0;
      await tester.pumpWidget(
        _host(
          TmdbEpisodeHeader(
            episodeCount: 12,
            reversed: false,
            gridMode: false,
            lineName: '线路一',
            onToggleReversed: () => reversedToggles++,
            onToggleGridMode: () => gridToggles++,
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('选集'), findsOneWidget);
      expect(find.textContaining('线路一'), findsOneWidget);
      expect(find.textContaining('12 集'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tmdb-episode-reverse')));
      expect(reversedToggles, 1);
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-view-mode')));
      expect(gridToggles, 1);
    });

    testWidgets('网格模式下剧集卡片换行铺满（不再是横向条）', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 1200,
            child: TmdbEpisodeSection(
              cards: _cards,
              keyPrefix: 'tmdb-episode-card-线路一',
              gridMode: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-grid')),
        findsOneWidget,
        reason: '网格模式必须用 GridView',
      );
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-strip')),
        findsNothing,
        reason: '网格模式下不得再渲染横向条',
      );
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-线路一-0')),
        findsOneWidget,
      );
    });
  });

  group('信息表（`04` §3.1 ①：类型/地区/年份/时长/季集/导演…）', () {
    testWidgets('两列排布，空值行自动跳过', (tester) async {
      await tester.pumpWidget(
        _host(
          const TmdbInfoTable(
            rows: [
              ('类型', '剧情 / 科幻'),
              ('地区', '中国'),
              ('年份', '2024'),
              ('时长', ''),
              ('导演', null),
              ('评分', 'TMDB 8.2'),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('tmdb-info-table')), findsOneWidget);
      expect(find.text('类型'), findsOneWidget);
      expect(find.text('剧情 / 科幻'), findsOneWidget);
      expect(find.text('评分'), findsOneWidget);
      // 空值与 null 行必须整行跳过，不留空标签。
      expect(find.text('时长'), findsNothing);
      expect(find.text('导演'), findsNothing);
    });

    testWidgets('全部为空时不渲染整块', (tester) async {
      await tester.pumpWidget(
        _host(const TmdbInfoTable(rows: [('类型', ''), ('导演', null)])),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('tmdb-info-table')), findsNothing);
    });
  });

  group('制作团队卡片（用户反馈：没有导演卡片）', () {
    testWidgets('导演/主创以头像卡片渲染且可点击（对齐上游 tmdbCrew）', (tester) async {
      TmdbPerson? tapped;
      final data = _data();
      expect(data.crew, isNotEmpty, reason: '前置：fixture 必须有 crew');
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 1200,
            child: TmdbDetailSections(
              data: data,
              onPersonTap: (person) => tapped = person,
            ),
          ),
        ),
      );
      await tester.pump();
      await _scrollTo(
        tester,
        find.byKey(const ValueKey('tmdb-section-crew')),
      );

      expect(
        find.byKey(const ValueKey('tmdb-section-crew')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tmdb-crew-wall')),
        findsOneWidget,
        reason: '制作团队必须是卡片墙，不是纯文字列表',
      );
      // 头像卡片：必须真的渲染了头像图片（用户反馈的就是「没有卡片」）。
      final crewId = data.crew.first.personId;
      expect(
        _posterUrlOf(tester, ValueKey('tmdb-crew-$crewId')),
        isNotNull,
        reason: '团队卡片必须有头像图片',
      );
      await tester.tap(find.byKey(ValueKey('tmdb-crew-$crewId')));
      expect(tapped?.personId, crewId, reason: '团队卡片必须可点击进人物页');
    });
  });

  group('失败隔离（`04` §3.4：空区块整块隐藏）', () {
    testWidgets('无剧照/无演职人员/无推荐/无视频时整块不渲染', (tester) async {
      const bare = TmdbDetailData(
        tmdbId: 1,
        title: '空数据',
        mediaType: TmdbMediaType.movie,
      );
      await tester.pumpWidget(
        _host(const SizedBox(width: 1200, child: TmdbDetailSections(data: bare))),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('tmdb-section-photos')), findsNothing);
      expect(find.byKey(const ValueKey('tmdb-section-people')), findsNothing);
      expect(
        find.byKey(const ValueKey('tmdb-section-recommendations')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('tmdb-section-videos')), findsNothing);
    });
  });
}
