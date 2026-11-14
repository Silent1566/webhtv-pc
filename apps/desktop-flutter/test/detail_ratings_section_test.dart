/// 详情页评分与外链的两段展示门禁（用户需求 2026-11-11）。
///
/// 锁四件事：
/// 1. 评分只作**静态信息**：与 TMDB 标签同样式、同强调底色，不可点击、无外链图标；
/// 2. **有的才显示**：没有分值、或分值不合法时该来源整条不出现，不画占位；
/// 3. 外链沉到页尾，只用站名 + 外链图标的描边按钮，不再重复分值；
/// 4. 两段**共用一次查询**：页面只发一轮请求，换作品才重查。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/detail_ratings.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/detail_rating_service.dart';
import 'package:webhtv_pc/state/detail_ratings_state.dart';
import 'package:webhtv_pc/ui/detail_ratings_section.dart';
import 'package:webhtv_pc/ui/theme.dart';

const _request = DetailRatingRequest(
  tmdbId: 1399,
  title: '示例剧集',
  year: 2024,
  mediaType: TmdbMediaType.tv,
  imdbId: 'tt0944947',
  originalTitle: 'Game of Thrones',
  englishTitle: 'Game of Thrones',
);

const _fullValues = DetailRatingValues(
  doubanRating: 9.4,
  imdb: '9.2',
  imdbVotes: '2.4M',
  rottenTomatoes: '89%',
  metacritic: '82/100',
);

class _FakeRatingService implements DetailRatingService {
  _FakeRatingService();

  final DetailRatingValues values = _fullValues;
  int calls = 0;

  @override
  Future<DetailRatingValues> fetch(
    DetailRatingRequest request, {
    required String omdbApiKey,
  }) async {
    calls++;
    return values;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

DetailRatings _built([DetailRatingValues values = _fullValues]) =>
    DetailRatingRules.build(request: _request, values: values);

class _CountingCancelService implements DetailRatingService {
  _CountingCancelService(this._inner, this._onCancel);

  final _FakeRatingService _inner;
  final void Function() _onCancel;

  @override
  Future<DetailRatingValues> fetch(
    DetailRatingRequest request, {
    required String omdbApiKey,
  }) => _inner.fetch(request, omdbApiKey: omdbApiKey);

  @override
  void cancelPending() => _onCancel();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Widget _host(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SizedBox(width: 900, child: child),
    ),
  ),
);

void main() {
  group('评分标签（简介上方）', () {
    testWidgets('与 TMDB 同款标签，顺序固定且只显示有分值的来源', (tester) async {
      await tester.pumpWidget(
        _host(DetailRatingTags(ratings: _built(), tmdbRating: 8.4)),
      );

      const keys = [
        'tmdb-detail-rating',
        'detail-rating-tag-douban',
        'detail-rating-tag-imdb',
        'detail-rating-tag-rotten',
        'detail-rating-tag-metacritic',
      ];
      for (final key in keys) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(find.text('TMDB 8.4'), findsOneWidget);
      expect(find.text('豆瓣 9.4'), findsOneWidget);
      expect(find.text('烂番茄 89%'), findsOneWidget);

      // 顺序按「先换行、再左右」比较：窄窗口下标签会折行，只比 x 会把第二行
      // 的第一个标签判成乱序。
      final positions = [
        for (final key in keys) tester.getTopLeft(find.byKey(ValueKey(key))),
      ];
      for (var i = 1; i < positions.length; i++) {
        final previous = positions[i - 1];
        final current = positions[i];
        expect(
          current.dy > previous.dy ||
              (current.dy == previous.dy && current.dx > previous.dx),
          isTrue,
          reason: '${keys[i - 1]} 必须排在 ${keys[i]} 之前',
        );
      }
    });

    testWidgets('评分标签不可点击，也不带外链图标', (tester) async {
      await tester.pumpWidget(
        _host(DetailRatingTags(ratings: _built(), tmdbRating: 8.4)),
      );

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('detail-rating-tags')),
          matching: find.byType(InkWell),
        ),
        findsNothing,
        reason: '评分是信息，不是入口',
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('detail-rating-tags')),
          matching: find.byIcon(Icons.open_in_new),
        ),
        findsNothing,
      );
    });

    testWidgets('没有分值时不占位；分值不合法也不显示', (tester) async {
      await tester.pumpWidget(
        _host(
          DetailRatingTags(
            ratings: _built(const DetailRatingValues(imdb: 'N/A')),
            // TMDB 分缺失（未匹配）时连 TMDB 标签也不该出现。
          ),
        ),
      );
      expect(find.byKey(const ValueKey('detail-rating-tags')), findsNothing);

      await tester.pumpWidget(
        _host(
          DetailRatingTags(
            ratings: _built(
              const DetailRatingValues(doubanRating: 9.4, imdb: '11.2'),
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('detail-rating-tag-douban')),
        findsOneWidget,
      );
      // 11.2 超过十分制上界：宁可留空，也不显示一个不可能是真的分数。
      expect(
        find.byKey(const ValueKey('detail-rating-tag-imdb')),
        findsNothing,
      );
    });

    testWidgets('悬停提示带 IMDb 投票数（chip 本身只放分数）', (tester) async {
      await tester.pumpWidget(
        _host(DetailRatingTags(ratings: _built(), tmdbRating: 8.4)),
      );
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(
          of: find.byKey(const ValueKey('detail-rating-tag-imdb')),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tooltip.message, contains('2.4M'));
    });
  });

  group('页尾外部链接', () {
    testWidgets('五个站点都是描边按钮，只显示站名', (tester) async {
      await tester.pumpWidget(
        _host(DetailRatingsSection(request: _request, ratings: _built())),
      );

      expect(
        find.byKey(const ValueKey('detail-ratings-section')),
        findsOneWidget,
      );
      const keys = [
        'detail-ratings-tmdb',
        'detail-ratings-douban',
        'detail-ratings-imdb',
        'detail-ratings-rotten',
        'detail-ratings-metacritic',
      ];
      for (final key in keys) {
        final button = find.byKey(ValueKey(key));
        expect(button, findsOneWidget, reason: key);
        expect(
          find.descendant(of: button, matching: find.byType(OutlinedButton)),
          findsNothing,
          reason: 'key 已落在按钮自身上',
        );
      }
      // 页面里不应再有分值与星标：分值只属于上面的评分标签。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('detail-ratings-section')),
          matching: find.byIcon(Icons.star),
        ),
        findsNothing,
      );
      expect(find.text('豆瓣 9.4'), findsNothing);
    });

    testWidgets('点哪个按钮就打开哪个站点', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        _host(
          DetailRatingsSection(
            request: _request,
            ratings: _built(),
            onOpen: (url) async {
              opened.add(url);
              return true;
            },
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('detail-ratings-rotten')));
      await tester.pump();
      expect(opened.single, contains('rottentomatoes.com'));

      await tester.tap(find.byKey(const ValueKey('detail-ratings-imdb')));
      await tester.pump();
      expect(opened.last, 'https://www.imdb.com/title/tt0944947');
    });

    testWidgets('打不开时复制链接兜底', (tester) async {
      final copied = <String>[];
      await tester.pumpWidget(
        _host(
          DetailRatingsSection(
            request: _request,
            ratings: _built(),
            onOpen: (url) async => false,
            onCopy: (url) async => copied.add(url),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('detail-ratings-douban')));
      await tester.pumpAndSettle();
      expect(copied.single, contains('search.douban.com'));
    });

    testWidgets('没有任何可打开地址时整块不渲染', (tester) async {
      await tester.pumpWidget(
        _host(
          DetailRatingsSection(
            request: const DetailRatingRequest(title: '只有标题'),
            ratings: DetailRatingRules.build(
              request: const DetailRatingRequest(title: '只有标题'),
              values: _fullValues,
            ),
          ),
        ),
      );
      // 只有豆瓣能按标题搜出地址；TMDB/IMDb/烂番茄/Metacritic 都不可点。
      expect(
        find.byKey(const ValueKey('detail-ratings-douban')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('detail-ratings-tmdb')), findsNothing);
      expect(find.byKey(const ValueKey('detail-ratings-imdb')), findsNothing);
    });
  });

  group('共用一次查询（页面持有控制器）', () {
    testWidgets('标签与页尾各自渲染，但只发一次请求', (tester) async {
      final service = _FakeRatingService();
      final controller = DetailRatingsController(
        service: service,
        omdbApiKey: () => '',
      );
      controller.begin(_request);
      await controller.load();
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              DetailRatingTags(ratings: controller.ratings, tmdbRating: 8.4),
              DetailRatingsSection(
                request: _request,
                ratings: controller.ratings,
              ),
            ],
          ),
        ),
      );

      expect(service.calls, 1, reason: '同一部作品只查一次');
      expect(find.text('豆瓣 9.4'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('detail-ratings-douban')),
        findsOneWidget,
      );
      controller.dispose();
    });

    testWidgets('换作品（幂等键变化）才重查，同一作品重建不重查', (tester) async {
      final service = _FakeRatingService();
      final controller = DetailRatingsController(
        service: service,
        omdbApiKey: () => '',
      );

      controller.begin(_request);
      expect(controller.requestKey, _request.cacheKey);
      await controller.load();
      expect(service.calls, 1);

      // 同一作品再次 begin（页面重建）不得重发请求，调用方按 requestKey 判断。
      expect(controller.requestKey, _request.cacheKey);

      controller.begin(
        const DetailRatingRequest(
          tmdbId: 1399,
          title: '另一部作品',
          mediaType: TmdbMediaType.tv,
        ),
      );
      await controller.load();
      expect(service.calls, 2);
      controller.dispose();
    });

    testWidgets('页面关闭会取消等待中的请求（不留悬挂 Timer）', (tester) async {
      final service = _FakeRatingService();
      var cancelled = 0;
      final controller = DetailRatingsController(
        service: _CountingCancelService(service, () => cancelled++),
        omdbApiKey: () => '',
      );
      controller.begin(_request);
      controller.dispose();
      expect(cancelled, 1, reason: 'dispose 必须把在途请求收掉');
    });
  });

  group('评分规则（纯逻辑）', () {
    test('TMDB 分带 /10，豆瓣一位小数，烂番茄百分比', () {
      expect(formatRating(RatingSource.tmdb, 8.4), '8.4/10');
      expect(formatRating(RatingSource.douban, 9.42), '9.4');
      expect(formatRating(RatingSource.rottenTomatoes, 8.9), '89%');
      expect(formatRating(RatingSource.metacritic, 8.2), '82/100');
      expect(formatRating(RatingSource.douban, 0), '');
    });

    test('烂番茄检索词优先英文译名，缺年份时补上', () {
      expect(
        westernSearchQuery(
          title: '权力的游戏',
          originalTitle: 'Game of Thrones',
          englishTitle: 'Game of Thrones',
          year: 2011,
        ),
        'Game of Thrones 2011',
      );
      expect(
        westernSearchQuery(title: 'Space Odyssey 1968', year: 1968),
        'Space Odyssey 1968',
      );
      expect(westernSearchQuery(title: '无间道', year: 2002), '无间道 2002');
    });

    test('OMDb 的 N/A 与 Response=false 都算没拿到', () {
      expect(parseOmdbRatings({}).isEmpty, isTrue);
      expect(
        parseOmdbRatings({'Response': 'False', 'Error': 'not found'}).isEmpty,
        isTrue,
      );
      expect(
        parseOmdbRatings({
          'Response': 'true',
          'imdbRating': 'N/A',
          'imdbVotes': 'N/A',
          'Ratings': [
            {'Source': 'Rotten Tomatoes', 'Value': 'N/A'},
          ],
          'Metascore': 'N/A',
        }).isEmpty,
        isTrue,
      );
    });

    test('OMDb 分值归一：Metascore 补 /100，投票数压缩', () {
      final parsed = parseOmdbRatings({
        'Response': 'true',
        'imdbRating': '8.4',
        'imdbVotes': '1,234,567',
        'Ratings': [
          {'Source': 'Rotten Tomatoes', 'Value': '87%'},
        ],
        'Metascore': '78',
      });
      expect(parsed.imdb, '8.4');
      expect(parsed.imdbVotes, '1.2M');
      expect(parsed.rottenTomatoes, '87%');
      expect(parsed.metacritic, '78/100');
    });

    test('外链：没有 id 的站点不构造地址（PC 端不猜 subject id）', () {
      final links = DetailRatingRules.links(
        tmdbId: 0,
        mediaType: TmdbMediaType.movie,
        imdbId: '',
        doubanTitle: '',
        westernQuery: '',
      );
      expect(links, hasLength(5));
      expect(links.every((entry) => !entry.canOpen), isTrue);
      expect(DetailRatings(entries: links).isEmpty, isTrue);
    });
  });
}
