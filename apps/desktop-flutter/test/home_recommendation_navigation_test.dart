import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/search_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_page.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';

final _capture = Platform.environment['HOME_CARD_CAPTURE'] == '1';
final _captureAfter = Platform.environment['HOME_DETAIL_CAPTURE'] == '1';

/// 回退页 After 截图：只有显式打开环境变量时才写盘，CI 默认跑全绿。
final _withFonts = _capture || _captureAfter;
final _captureRoot = GlobalKey();

const _item = TmdbItem(
  tmdbId: 1399,
  mediaType: TmdbMediaType.tv,
  title: '双轨',
  overview: '推荐作品的剧情简介',
);

/// 当前选中的普通站点（indexs 不为 1）：推荐点击「先按片名搜一次」的目标。
Site _site() => Site(
  key: 'current',
  name: '当前站',
  type: 1,
  api: 'https://fixture.invalid/api.php/provide/vod',
);

Vod _siteVod(String vodId, String vodName) =>
    Vod(vodId: vodId, vodName: vodName);

/// 导航源回退页的剧集卡片前缀（与站源卡片的命名空间隔离）。
const _navCardPrefix = 'tmdb-episode-card-nav-';

Finder _navCards() => find.byWidgetPredicate(
  (widget) =>
      widget is OutlinedButton &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith(_navCardPrefix),
);

class _HomeRecommendationState extends AppState with ExternalMetaOff {
  _HomeRecommendationState(
    Directory dir,
    this.metadata,
    this.recommendations,
    this.fakeTmdb,
  ) : super(
        paths: AppPaths.resolve(
          overrides: {
            'config': dir.path,
            'data': dir.path,
            'cache': dir.path,
            'state': dir.path,
          },
        ),
        log: MemoryOnlyLogService(),
      );

  final TmdbService metadata;
  final DetailRecommendationDependencies recommendations;
  final TmdbState fakeTmdb;
  Map<HotRankCategory, List<SearchSuggestItem>> hot = const {};

  /// 注入的「当前选中站点」。null = 首页没有选中站点（退回按片名搜索）。
  Site? site;

  /// 该站点按片名搜到的条目。
  List<Vod> siteResults = const [];

  /// 该站点搜索抛错（搜索失败也要按未命中处理）。
  bool siteSearchFails = false;

  /// 页面真的发过哪几次站点搜索（关键词，按顺序）。
  final List<String> siteSearches = [];

  @override
  Future<List<SearchSuggestItem>> searchHotRank(
    HotRankCategory category,
  ) async => hot[category] ?? const [];

  @override
  TmdbService get tmdbService => metadata;

  @override
  TmdbState get tmdb => fakeTmdb;

  @override
  Site? get selectedSite => site;

  @override
  Future<SiteResult?> search(
    Site site, {
    required String keyword,
    int page = 1,
    bool quick = false,
  }) async {
    siteSearches.add(keyword);
    if (siteSearchFails) throw StateError('fixture site offline');
    return SiteResult(list: siteResults);
  }

  @override
  DetailRecommendationDependencies get recommendationDependencies =>
      recommendations;
}

void main() {
  late Directory dir;
  late TmdbService metadata;
  late TmdbState tmdbState;
  late _HomeRecommendationState state;
  var browseCalls = 0;
  final hotSearches = <String>[];
  var lookupResults = <Map<String, Object?>>[];
  final lookupQueries = <String>[];
  Completer<http.Response>? pendingLookup;
  var tmdbEnabled = true;
  var lookupFails = false;

  setUpAll(() async {
    if (_withFonts) await loadFixtureFonts();
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('home-recommendation-navigation');
    metadata = TmdbService(
      config: () => TmdbConfig(apiKey: tmdbEnabled ? 'fixture' : ''),
      client: MockClient((request) async {
        final path = request.url.path;
        http.Response json(Object body) => http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
        if (path.endsWith('/search/multi')) {
          lookupQueries.add(request.url.queryParameters['query'] ?? '');
          if (pendingLookup != null) return pendingLookup!.future;
          if (lookupFails) throw const SocketException('fixture offline');
          return json({'results': lookupResults});
        }
        // 回退页的剧集卡片来自 TMDB 全季聚合：一季两集，卡片才铺得出来。
        if (path.endsWith('/season/1')) {
          return json({
            'season_number': 1,
            'episodes': [
              {'episode_number': 1, 'name': '第一集', 'season_number': 1},
              {'episode_number': 2, 'name': '第二集', 'season_number': 1},
            ],
          });
        }
        if (path.endsWith('/tv/1399')) {
          return json({
            'id': 1399,
            'name': '双轨',
            'overview': '推荐作品的剧情简介',
            'seasons': [
              {'season_number': 1, 'episode_count': 2},
            ],
          });
        }
        final detailMatch = RegExp(r'/(movie|tv)/([0-9]+)$').firstMatch(path);
        if (detailMatch != null) {
          final id = int.parse(detailMatch.group(2)!);
          final result = lookupResults
              .where((item) => item['id'] == id)
              .firstOrNull;
          return json({
            'id': id,
            'name': result?['name'] ?? result?['title'] ?? '热门样片',
            'title': result?['title'] ?? result?['name'] ?? '热门样片',
            'overview': '热门作品的完整资料',
            'seasons': <Object>[],
          });
        }
        // 其余路径（videos / credits …）按 404 处理：TMDB 区块失败不影响本页。
        return http.Response(
          jsonEncode({'status_code': 404}),
          404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    browseCalls = 0;
    hotSearches.clear();
    lookupResults = [];
    lookupQueries.clear();
    pendingLookup = null;
    tmdbEnabled = true;
    lookupFails = false;
  });

  tearDown(() {
    state.dispose();
    state.recommendations.close();
    tmdbState.dispose();
    metadata.close();
    dir.deleteSync(recursive: true);
  });

  /// 详情页读取的 TMDB 状态（与既有详情页用例同一套注入方式）。
  TmdbState buildTmdbState() {
    TmdbConfig config() => TmdbConfig(apiKey: tmdbEnabled ? 'fixture' : '');
    return TmdbState(
      config: config,
      service: metadata,
      identityService: TmdbIdentityService(
        config: config,
        service: metadata,
        store: InMemoryTmdbMatchStore(),
      ),
      seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
      enrichmentService: TmdbEnrichmentService(
        service: metadata,
        config: config,
      ),
    );
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    bool titleOnly = false,
    bool hotOnly = false,
    int extraRecommendations = 0,
    Brightness brightness = Brightness.dark,
    Map<HotRankCategory, List<SearchSuggestItem>> hot = const {},
    Site? site,
    List<Vod> siteResults = const [],
    bool siteSearchFails = false,
  }) async {
    final entry = RecommendationEntry(
      item: titleOnly
          ? const TmdbItem(
              tmdbId: 0,
              mediaType: TmdbMediaType.movie,
              title: '豆瓣独立作品',
              overview: '只有豆瓣资料的简介',
            )
          : _item,
      source: titleOnly
          ? RecommendationSource.douban
          : RecommendationSource.tmdb,
      reason: '因为你看过《旧作品》',
      doubanId: titleOnly ? 'douban-only' : null,
    );
    final row = titleOnly ? RecommendationRow.douban : RecommendationRow.tmdb;
    final dependencies = DetailRecommendationDependencies(
      feedback: RecommendationFeedbackStore(
        file: File('${dir.path}/feedback.json'),
      ),
      loaders: {
        for (final kind in RecommendationRow.values)
          kind: (_) async => RecommendationPage(
            items: kind == row && !hotOnly
                ? [
                    entry,
                    for (var i = 0; i < extraRecommendations; i++)
                      RecommendationEntry(
                        item: TmdbItem(
                          tmdbId: 2000 + i,
                          mediaType: TmdbMediaType.movie,
                          title: '推荐样片$i',
                        ),
                        source: RecommendationSource.tmdb,
                      ),
                  ]
                : const [],
          ),
      },
    );
    tmdbState = buildTmdbState();
    state = _HomeRecommendationState(dir, metadata, dependencies, tmdbState)
      ..hot = hot
      ..site = site
      ..siteResults = siteResults
      ..siteSearchFails = siteSearchFails;
    await tester.runAsync(() => bootstrapWithoutExternalMeta(state));
    // 已看完的记录只作为个性推荐种子，不占首屏轮播位。
    state.database!.upsertHistory(
      siteKey: 'old-site',
      vodId: 'seed',
      vodName: '旧作品',
      flag: '线路一',
      episodeName: '第01集',
      episodeId: 'seed-episode',
      positionMs: 100000,
      durationMs: 100000,
      updatedAt: 1,
    );
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final base = buildAppTheme(brightness);
    final label = base.textTheme.labelLarge?.copyWith(fontFamily: 'FixtureCJK');
    final theme = !_withFonts
        ? base
        : base.copyWith(
            textTheme: base.textTheme.apply(fontFamily: 'FixtureCJK'),
            primaryTextTheme: base.primaryTextTheme.apply(
              fontFamily: 'FixtureCJK',
            ),
            filledButtonTheme: FilledButtonThemeData(
              style: base.filledButtonTheme.style?.copyWith(
                textStyle: WidgetStatePropertyAll(label),
              ),
            ),
            textButtonTheme: TextButtonThemeData(
              style: base.textButtonTheme.style?.copyWith(
                textStyle: WidgetStatePropertyAll(label),
              ),
            ),
            chipTheme: base.chipTheme.copyWith(
              labelStyle: label,
              secondaryLabelStyle: label,
            ),
          );
    await tester.pumpWidget(
      RepaintBoundary(
        key: _captureRoot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            body: HomePage(
              state: state,
              onOpenBrowse: () => browseCalls++,
              onOpenHistory: () {},
              onOpenFollowing: () {},
              onImportConfig: () {},
              onSearch: hotSearches.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (!hotOnly) {
      expect(find.text('查看详情'), findsOneWidget);
      expect(find.text('去找片源'), findsOneWidget);
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  DetailPage pushedDetail(WidgetTester tester) =>
      tester.widget<DetailPage>(find.byType(DetailPage));

  /// 详情页是满屏 hero + 懒构建的下半页：目标控件在视口外时还没被 build，
  /// 按既有视觉用例的做法先往下滚到它出现（找不到就交给后面的 expect 报错）。
  Future<void> scrollDetailTo(WidgetTester tester, Finder target) async {
    for (var attempt = 0;
        attempt < 30 && target.evaluate().isEmpty;
        attempt++) {
      await tester.drag(
        find.byType(Scrollable).first,
        const Offset(0, -160),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('首页推荐查看详情先按片名搜当前站点，命中进站点真实详情', (tester) async {
    await pumpHome(
      tester,
      site: _site(),
      siteResults: [_siteVod('site-1399', '双轨')],
    );
    await tester.tap(find.byKey(const ValueKey('home-hero-primary')));
    await tester.pumpAndSettle();
    expect(browseCalls, 0);
    expect(state.siteSearches, ['双轨'], reason: '点一次只按片名搜一次');
    final detail = pushedDetail(tester);
    expect(
      detail.vod.vodId,
      'site-1399',
      reason: '命中站点条目：vodId 非空，页面可直接播放',
    );
    expect(detail.vod.vodName, '双轨');
    expect(detail.state, same(state));
    expect(find.byType(TmdbDetailPage), findsNothing);
    expect(find.byType(SearchPage), findsNothing);
    expect(state.recentSearchKeywords, isEmpty);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('首页推荐去找片源带入片名和 TMDB 身份，并执行站源搜索', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('home-hero-secondary')));
    await tester.pumpAndSettle();
    expect(browseCalls, 0);
    final search = tester.widget<SearchPage>(find.byType(SearchPage));
    expect(search.initialKeyword, '双轨');
    expect(search.identityHint, _item.identity);
    expect(state.recentSearchKeywords, contains('双轨'));
    expect(find.byType(TmdbDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('推荐轨道卡片进入详情，而不是误走去找片源', (tester) async {
    await pumpHome(
      tester,
      site: _site(),
      siteResults: [_siteVod('site-1399', '双轨')],
    );
    final card = find.descendant(
      of: find.byType(HomeRailView),
      matching: find.text('双轨'),
    );
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(browseCalls, 0);
    expect(state.siteSearches, ['双轨']);
    expect(pushedDetail(tester).vod.vodId, 'site-1399');
    expect(find.byType(SearchPage), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('推荐在当前站点没命中时进回退详情页，带重新匹配与剧集卡片', (tester) async {
    await pumpHome(tester, site: _site());
    await tester.tap(find.byKey(const ValueKey('home-hero-primary')));
    await tester.pumpAndSettle();
    expect(browseCalls, 0);
    expect(state.siteSearches, ['双轨']);
    final detail = pushedDetail(tester);
    expect(
      detail.vod.vodId,
      isEmpty,
      reason: '没有站源身份：合成条目不伪造可播放 id',
    );
    expect(detail.vod.vodName, '双轨');
    final rematch = find.byKey(const ValueKey('tmdb-rematch'));
    await scrollDetailTo(tester, rematch);
    expect(rematch, findsOneWidget, reason: '回退页必须提供重新匹配');
    expect(find.byKey(const ValueKey('tmdb-status-matched')), findsOneWidget);
    await scrollDetailTo(tester, _navCards());
    expect(_navCards(), findsWidgets, reason: '剧集卡片由 TMDB 全季聚合铺出');
    expect(find.byType(TmdbDetailPage), findsNothing);
    expect(find.byType(SearchPage), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('推荐站点搜索失败按未命中处理，退回回退详情页而不是报错', (tester) async {
    await pumpHome(tester, site: _site(), siteSearchFails: true);
    await tester.tap(find.byKey(const ValueKey('home-hero-primary')));
    await tester.pumpAndSettle();
    expect(state.siteSearches, ['双轨']);
    expect(pushedDetail(tester).vod.vodId, isEmpty);
    final rematch = find.byKey(const ValueKey('tmdb-rematch'));
    await scrollDetailTo(tester, rematch);
    expect(rematch, findsOneWidget);
    expect(find.byType(SearchPage), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('没有选中站点时查看详情退回按片名搜索站源', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const ValueKey('home-hero-primary')));
    await tester.pumpAndSettle();
    expect(state.siteSearches, isEmpty, reason: '没有站点就不该发站点搜索');
    final search = tester.widget<SearchPage>(find.byType(SearchPage));
    expect(search.initialKeyword, '双轨');
    expect(search.identityHint, isNull);
    expect(find.byType(DetailPage), findsNothing);
    expect(find.byType(TmdbDetailPage), findsNothing);
    expect(browseCalls, 0);
    await unmount(tester);
  });

  testWidgets('回退详情页的重新匹配沿用同一片名与 TMDB 身份', (tester) async {
    await pumpHome(tester, site: _site());
    await tester.tap(find.byKey(const ValueKey('home-hero-primary')));
    await tester.pumpAndSettle();
    final detail = pushedDetail(tester);
    expect(detail.vod.vodName, '双轨');
    expect(detail.vod.extra['tmdb_id'], 1399);
    expect(detail.vod.extra['media_type'], 'tv');
    final rematch = find.byKey(const ValueKey('tmdb-rematch'));
    await scrollDetailTo(tester, rematch);
    expect(rematch, findsOneWidget);
    await tester.tap(rematch);
    await tester.pumpAndSettle();
    final query = tester.widget<TextField>(
      find.byKey(const ValueKey('meta-match-query')),
    );
    expect(query.controller!.text, '双轨');
    expect(browseCalls, 0);
    await unmount(tester);
  });

  testWidgets('无 TMDB 身份查看详情展示已有资料，不跳无关点播页', (tester) async {
    await pumpHome(tester, titleOnly: true);
    await tester.tap(find.byKey(const ValueKey('home-hero-primary')));
    await tester.pumpAndSettle();
    expect(browseCalls, 0);
    expect(
      find.byKey(const ValueKey('recommendation-info-dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recommendation-info-overview')),
      findsOneWidget,
    );
    expect(find.text('只有豆瓣资料的简介').hitTestable(), findsOneWidget);
    expect(find.byType(SearchPage), findsNothing);
    expect(find.byType(TmdbDetailPage), findsNothing);
    await unmount(tester);
  });

  testWidgets('无 TMDB 身份去找片源只带标题，不伪造身份', (tester) async {
    await pumpHome(tester, titleOnly: true);
    await tester.tap(find.byKey(const ValueKey('home-hero-secondary')));
    await tester.pumpAndSettle();
    expect(browseCalls, 0);
    final search = tester.widget<SearchPage>(find.byType(SearchPage));
    expect(search.initialKeyword, '豆瓣独立作品');
    expect(search.identityHint, isNull);
    expect(state.recentSearchKeywords, contains('豆瓣独立作品'));
    await unmount(tester);
  });

  Future<Finder> revealCard(WidgetTester tester, String title) async {
    final card = find.widgetWithText(HomePosterCard, title);
    if (card.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        card,
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('home-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
    }
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    return card;
  }

  Future<void> secondaryTap(WidgetTester tester, Finder card) async {
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.down(tester.getCenter(card));
    await mouse.up();
    await mouse.removePointer();
    await tester.pumpAndSettle();
  }

  for (final rightClick in [false, true]) {
    testWidgets('推荐卡片${rightClick ? "右键" : "长按"}展示资料且不会触发单击', (tester) async {
      await pumpHome(
        tester,
        site: _site(),
        siteResults: [_siteVod('site-1399', '双轨')],
      );
      final card = await revealCard(tester, '双轨');
      if (rightClick) {
        await secondaryTap(tester, card);
      } else {
        await tester.longPress(card);
        await tester.pumpAndSettle();
      }
      expect(
        find.byKey(const ValueKey('recommendation-info-dialog')),
        findsOneWidget,
      );
      expect(find.text('推荐作品的剧情简介').hitTestable(), findsOneWidget);
      expect(find.text('因为你看过《旧作品》').hitTestable(), findsOneWidget);
      expect(find.text('不感兴趣'), findsOneWidget);
      expect(find.byType(TmdbDetailPage), findsNothing);
      expect(find.byType(DetailPage), findsNothing);
      expect(hotSearches, isEmpty);
      expect(state.siteSearches, isEmpty, reason: '弹窗本身不触发站点搜索');
      expect(browseCalls, 0);
      await tester.tap(find.byKey(const ValueKey('recommendation-info-open')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recommendation-info-dialog')),
        findsNothing,
      );
      expect(state.siteSearches, ['双轨']);
      expect(
        pushedDetail(tester).vod.vodId,
        'site-1399',
        reason: '弹窗的详情与单击走同一条去向',
      );
      await unmount(tester);
    });
  }

  testWidgets('仅标题推荐长按后明确提供找片源，不循环打开同一资料弹窗', (tester) async {
    await pumpHome(tester, titleOnly: true);
    await tester.longPress(await revealCard(tester, '豆瓣独立作品'));
    await tester.pumpAndSettle();
    final dialog = find.byKey(const ValueKey('recommendation-info-dialog'));
    expect(
      find.descendant(of: dialog, matching: find.text('去找片源')),
      findsOneWidget,
    );
    expect(find.text('不感兴趣'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recommendation-info-open')));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    final search = tester.widget<SearchPage>(find.byType(SearchPage));
    expect(search.initialKeyword, '豆瓣独立作品');
    expect(search.identityHint, isNull);
    expect(browseCalls, 0);
    await unmount(tester);
  });

  testWidgets('不感兴趣立即从首页推荐与轮播移除，并复用持久化反馈', (tester) async {
    await pumpHome(tester);
    await tester.longPress(await revealCard(tester, '双轨'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recommendation-info-hide')));
    await tester.pumpAndSettle();
    expect(find.text('双轨'), findsNothing);
    expect(
      find.byKey(const ValueKey('recommendation-info-dialog')),
      findsNothing,
    );
    final reloaded = RecommendationFeedbackStore(
      file: File('${dir.path}/feedback.json'),
    );
    expect(reloaded.blockedTitles, contains(recommendationTitleKey('双轨')));
    reloaded.dispose();
    await unmount(tester);
  });

  testWidgets('其他页面写入相同反馈后首页同步隐藏，不影响热门轨道', (tester) async {
    await pumpHome(
      tester,
      hot: {
        HotRankCategory.movie: [
          const SearchSuggestItem(title: '热门样片', rank: 7),
        ],
      },
    );
    state.recommendations.feedback.block('双轨');
    await tester.pumpAndSettle();
    expect(find.text('双轨'), findsNothing);
    expect(find.text('热门样片'), findsWidgets);
    await unmount(tester);
  });

  for (final rightClick in [false, true]) {
    testWidgets('热门卡片${rightClick ? "右键" : "长按"}展示榜单事实，保留详情与找片源入口', (
      tester,
    ) async {
      await pumpHome(
        tester,
        hot: {
          HotRankCategory.movie: [
            const SearchSuggestItem(
              title: '热门样片',
              rank: 7,
              subtitle: '全24集',
              score: '8.8',
            ),
          ],
        },
      );
      final card = await revealCard(tester, '热门样片');
      if (rightClick) {
        await secondaryTap(tester, card);
      } else {
        await tester.longPress(card);
        await tester.pumpAndSettle();
      }
      final dialog = find.byKey(const ValueKey('recommendation-info-dialog'));
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.text('360kan · 电影榜')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('第 7 名')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('豆瓣 8.8')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('全24集')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('榜单信息')),
        findsOneWidget,
      );
      expect(find.text('不感兴趣'), findsNothing);
      expect(find.text('推荐理由'), findsNothing);
      expect(hotSearches, isEmpty);
      expect(
        find.descendant(of: dialog, matching: find.text('去找片源')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.text('查看详情')),
        findsOneWidget,
      );
      expect(lookupQueries, isEmpty, reason: '只预览榜单不查询作品详情');
      await tester.tap(
        find.byKey(const ValueKey('recommendation-info-search')),
      );
      await tester.pumpAndSettle();
      expect(hotSearches, ['热门样片']);
      expect(
        find.byKey(const ValueKey('recommendation-info-dialog')),
        findsNothing,
      );
      expect(state.recommendations.feedback.blockedTitles, isEmpty);
      await unmount(tester);
    });
  }

  testWidgets('热门缺少名次与评分时不编造数据，关闭不触发搜索', (tester) async {
    await pumpHome(
      tester,
      hot: {
        HotRankCategory.series: [const SearchSuggestItem(title: '缺资料热剧')],
      },
    );
    await tester.longPress(await revealCard(tester, '缺资料热剧'));
    await tester.pumpAndSettle();
    final dialog = find.byKey(const ValueKey('recommendation-info-dialog'));
    expect(
      find.descendant(of: dialog, matching: find.text('360kan · 剧集榜')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('第 ')),
      findsNothing,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('豆瓣')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('recommendation-info-close')));
    await tester.pumpAndSettle();
    expect(hotSearches, isEmpty);
    expect(browseCalls, 0);
    await unmount(tester);
  });

  testWidgets('横向鼠标拖拽不误开资料弹窗或详情', (tester) async {
    await pumpHome(tester, extraRecommendations: 10);
    final card = await revealCard(tester, '双轨');
    final horizontal = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(HomeRailView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final before = horizontal.position.pixels;
    final mouse = await tester.startGesture(
      tester.getCenter(card),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(-30, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(-300, 0));
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();
    expect(
      horizontal.position.pixels,
      greaterThan(before),
      reason: '横向拖拽必须真的滚动，不能只是没有弹窗',
    );
    expect(
      find.byKey(const ValueKey('recommendation-info-dialog')),
      findsNothing,
    );
    expect(find.byType(TmdbDetailPage), findsNothing);
    expect(find.byType(DetailPage), findsNothing);
    expect(browseCalls, 0);
    expect(hotSearches, isEmpty);
    await unmount(tester);
  });

  Map<String, Object?> hotResult(
    int id,
    String type, {
    String title = '热门样片',
    String year = '2025',
  }) => {
    'id': id,
    'media_type': type,
    if (type == 'movie') 'title': title else 'name': title,
    if (type == 'movie')
      'release_date': '$year-01-01'
    else
      'first_air_date': '$year-01-01',
  };

  testWidgets('热门卡片单击按榜单类别匹配并进入完整详情，不再只搜索片源', (tester) async {
    lookupResults = [hotResult(3000, 'tv'), hotResult(3001, 'movie')];
    await pumpHome(
      tester,
      site: _site(),
      siteResults: [_siteVod('site-hot', '热门样片')],
      hot: {
        HotRankCategory.movie: [
          const SearchSuggestItem(title: '热门样片', rank: 7),
        ],
      },
    );
    expect(lookupQueries, isEmpty);
    await tester.tap(await revealCard(tester, '热门样片'));
    await tester.pumpAndSettle();
    expect(lookupQueries, ['热门样片']);
    expect(
      find.byKey(const ValueKey('home-hot-details-picker')),
      findsNothing,
      reason: '榜单类别筛出唯一候选，不该再让人选',
    );
    final detail = pushedDetail(tester);
    expect(detail.vod.vodId, 'site-hot');
    expect(detail.vod.vodName, '热门样片');
    expect(state.siteSearches, ['热门样片']);
    expect(find.byType(TmdbDetailPage), findsNothing);
    expect(hotSearches, isEmpty);
    expect(browseCalls, 0);
    // 回退页/详情页的返回是 hero 上的透明 AppBar 图标（tooltip 返回），
    // 不是 BackButton，所以按 tooltip 点而不是 tester.pageBack()。
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('热门长按弹窗查看详情与去找片源各走各的动作', (tester) async {
    lookupResults = [hotResult(3001, 'movie')];
    await pumpHome(
      tester,
      site: _site(),
      siteResults: [_siteVod('site-hot', '热门样片')],
      hot: {
        HotRankCategory.movie: [
          const SearchSuggestItem(title: '热门样片', rank: 7),
        ],
      },
    );
    await tester.longPress(await revealCard(tester, '热门样片'));
    await tester.pumpAndSettle();
    expect(lookupQueries, isEmpty);
    await tester.tap(find.byKey(const ValueKey('recommendation-info-open')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recommendation-info-dialog')),
      findsNothing,
    );
    expect(pushedDetail(tester).vod.vodId, 'site-hot');
    expect(state.siteSearches, ['热门样片']);
    expect(hotSearches, isEmpty);
    await unmount(tester);
  });

  for (final category in [HotRankCategory.series, HotRankCategory.variety]) {
    testWidgets('首次使用的热门轮播 ${category.label}：主按钮查看详情，次按钮找片源', (tester) async {
      lookupResults = [hotResult(3000, 'movie'), hotResult(3002, 'tv')];
      await pumpHome(
        tester,
        hotOnly: true,
        site: _site(),
        siteResults: [_siteVod('site-hot', '热门样片')],
        hot: {
          category: [const SearchSuggestItem(title: '热门样片', rank: 3)],
        },
      );
      expect(find.text('查看详情'), findsOneWidget);
      expect(find.text('去找片源'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-hero-secondary')));
      await tester.pumpAndSettle();
      expect(hotSearches, ['热门样片']);
      expect(lookupQueries, isEmpty);
      expect(find.byType(DetailPage), findsNothing);
      hotSearches.clear();
      await tester.tap(find.byKey(const ValueKey('home-hero-primary')));
      await tester.pumpAndSettle();
      expect(pushedDetail(tester).vod.vodId, 'site-hot');
      expect(state.siteSearches, ['热门样片']);
      expect(hotSearches, isEmpty);
      await unmount(tester);
    });
  }

  testWidgets('同名热门候选不盲选第一个，选择年份后打开选中的作品', (tester) async {
    lookupResults = [
      hotResult(3001, 'movie', year: '1999'),
      hotResult(3003, 'movie', year: '2025'),
    ];
    await pumpHome(
      tester,
      site: _site(),
      siteResults: [_siteVod('site-hot', '热门样片')],
      hot: {
        HotRankCategory.movie: [
          const SearchSuggestItem(title: '热门样片', rank: 7),
        ],
      },
    );
    await tester.tap(await revealCard(tester, '热门样片'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsNothing);
    expect(
      find.byKey(const ValueKey('home-hot-details-picker')),
      findsOneWidget,
    );
    expect(find.textContaining('1999'), findsWidgets);
    expect(find.textContaining('2025'), findsWidgets);
    await tester.tap(
      find.byKey(const ValueKey('home-hot-candidate-movie:3003')),
    );
    await tester.pumpAndSettle();
    expect(pushedDetail(tester).vod.vodId, 'site-hot');
    expect(state.siteSearches, ['热门样片']);
    expect(hotSearches, isEmpty);
    await unmount(tester);
  });

  testWidgets('只有近似片名不自动误认，取消候选保持在首页', (tester) async {
    lookupResults = [hotResult(3004, 'movie', title: '热门样片续集')];
    await pumpHome(
      tester,
      hot: {
        HotRankCategory.movie: [const SearchSuggestItem(title: '热门样片')],
      },
    );
    await tester.tap(await revealCard(tester, '热门样片'));
    await tester.pumpAndSettle();
    expect(find.byType(TmdbDetailPage), findsNothing);
    expect(
      find.byKey(const ValueKey('home-hot-details-picker')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('home-hot-details-cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(hotSearches, isEmpty);
    await unmount(tester);
  });

  for (final titles in [('无耻之徒（美版）', '无耻之徒（英版）'), ('奔跑吧 第九季', '奔跑吧 第一季')]) {
    testWidgets('热门标题中的版本或季度不能被抹去后自动认成同一作品：${titles.$1}', (tester) async {
      lookupResults = [hotResult(3002, 'tv', title: titles.$2)];
      await pumpHome(
        tester,
        hot: {
          HotRankCategory.series: [SearchSuggestItem(title: titles.$1)],
        },
      );
      await tester.tap(await revealCard(tester, titles.$1));
      await tester.pumpAndSettle();
      expect(
        find.byType(TmdbDetailPage),
        findsNothing,
        reason: '不同版本或季度的候选只能展示供选择，不能自动打开',
      );
      expect(
        find.byKey(const ValueKey('home-hot-details-picker')),
        findsOneWidget,
      );
      expect(find.text(titles.$2), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home-hot-details-cancel')));
      await tester.pumpAndSettle();
      expect(hotSearches, isEmpty);
      await unmount(tester);
    });
  }

  for (final failure in [
    'not-found',
    'wrong-type',
    'offline',
    'unconfigured',
  ]) {
    testWidgets('热门详情 $failure：给出可恢复说明，不伪造身份或跳点播', (tester) async {
      if (failure == 'wrong-type') lookupResults = [hotResult(3002, 'tv')];
      lookupFails = failure == 'offline';
      tmdbEnabled = failure != 'unconfigured';
      await pumpHome(
        tester,
        hot: {
          HotRankCategory.movie: [const SearchSuggestItem(title: '热门样片')],
        },
      );
      await tester.tap(await revealCard(tester, '热门样片'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-hot-details-unavailable')),
        findsOneWidget,
      );
      expect(find.byType(TmdbDetailPage), findsNothing);
      expect(find.byType(DetailPage), findsNothing);
      expect(hotSearches, isEmpty);
      expect(browseCalls, 0);
      await tester.tap(find.byKey(const ValueKey('home-hot-details-search')));
      await tester.pumpAndSettle();
      expect(hotSearches, ['热门样片']);
      expect(
        find.byKey(const ValueKey('home-hot-details-unavailable')),
        findsNothing,
      );
      await unmount(tester);
    });
  }

  testWidgets('热门详情查找期间连点只查一次，离开首页后迟到结果不跳页', (tester) async {
    pendingLookup = Completer<http.Response>();
    await pumpHome(
      tester,
      hot: {
        HotRankCategory.movie: [const SearchSuggestItem(title: '热门样片')],
      },
    );
    final card = await revealCard(tester, '热门样片');
    await tester.tap(card);
    await tester.pump();
    await tester.tap(card);
    await tester.pump();
    expect(lookupQueries, ['热门样片']);
    await unmount(tester);
    pendingLookup!.complete(
      http.Response(
        jsonEncode({
          'results': [hotResult(3001, 'movie')],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TmdbDetailPage), findsNothing);
    expect(find.byKey(const ValueKey('home-hot-details-picker')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  if (_capture) {
    for (final brightness in Brightness.values) {
      for (final hot in [false, true]) {
        testWidgets('长按弹窗视觉 ${brightness.name} ${hot ? "热门" : "推荐"}', (
          tester,
        ) async {
          await pumpHome(
            tester,
            brightness: brightness,
            hot: hot
                ? {
                    HotRankCategory.movie: [
                      const SearchSuggestItem(
                        title: '热门样片',
                        rank: 7,
                        score: '8.8',
                        subtitle: '全24集',
                      ),
                    ],
                  }
                : const {},
          );
          await tester.longPress(await revealCard(tester, hot ? '热门样片' : '双轨'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final boundary =
                _captureRoot.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            var root = Directory.current;
            while (!Directory('${root.path}/apps/desktop-flutter')
                .existsSync()) {
              if (root.parent.path == root.path) {
                throw StateError('Repository root not found');
              }
              root = root.parent;
            }
            final output = Directory('${root.path}/.local/home-card-info')
              ..createSync(recursive: true);
            File(
              '${output.path}/${hot ? "hot" : "recommendation"}-${brightness.name}.png',
            ).writeAsBytesSync(
              bytes!.buffer.asUint8List(
                bytes.offsetInBytes,
                bytes.lengthInBytes,
              ),
            );
          });
          await unmount(tester);
        });
      }
    }
  }

  if (_captureAfter) {
    testWidgets('推荐未命中回退页 After 截图', (tester) async {
      await pumpHome(tester, site: _site());
      await tester.tap(find.byKey(const ValueKey('home-hero-primary')));
      await tester.pumpAndSettle();
      final rematch = find.byKey(const ValueKey('tmdb-rematch'));
      await scrollDetailTo(tester, rematch);
      expect(rematch, findsOneWidget);
      await tester.ensureVisible(rematch);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            _captureRoot.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        var root = Directory.current;
        while (!Directory('${root.path}/apps/desktop-flutter').existsSync()) {
          if (root.parent.path == root.path) {
            throw StateError('Repository root not found');
          }
          root = root.parent;
        }
        final output =
            Directory('${root.path}/docs/superpowers/evidence/home-detail-route')
              ..createSync(recursive: true);
        File('${output.path}/after-home-fallback.png').writeAsBytesSync(
          bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      });
      await unmount(tester);
    });
  }
}
