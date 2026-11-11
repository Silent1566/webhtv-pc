import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/episode_range.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/tmdb_detail_page.dart';
import 'package:webhtv_pc/ui/toast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

const _card = TmdbEpisodeCard(
  number: 7,
  seasonNumber: 2,
  title: '第七集',
  overview: '长按应展示这一集的基础简介',
  date: '2025-02-07',
  runtime: 42,
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  _pageTests();
  for (final grid in [false, true]) {
    testWidgets('${grid ? '网格' : '横向'}区间倒序长按回调拿到原 cards 下标', (tester) async {
      final events = <(int, int, int)>[];
      var taps = 0;
      final cards = [
        for (var i = 7; i >= 1; i--)
          TmdbEpisodeCard(number: i, seasonNumber: 2, title: '卡片$i'),
      ];
      await tester.pumpWidget(
        _host(
          TmdbEpisodeStrip(
            cards: cards,
            gridMode: grid,
            ranges: const [
              EpisodeRange(label: '7-5', start: 0, end: 3, selected: false),
              EpisodeRange(label: '4-1', start: 3, end: 7, selected: true),
            ],
            rangeIndex: 1,
            onTap: (_, _) => taps++,
            onLongPress: (index, card) =>
                events.add((index, card.seasonNumber, card.number)),
          ),
        ),
      );
      final target = find.byKey(const ValueKey('tmdb-episode-card-3'));
      expect(tester.widget(target), isA<OutlinedButton>());
      await tester.longPress(target);
      await tester.pumpAndSettle();
      expect(events, [(3, 2, 4)]);
      expect(taps, 0);
    });

    testWidgets('${grid ? '网格' : '横向'}拖动及取消不触发短按或长按', (tester) async {
      var taps = 0;
      var holds = 0;
      await tester.pumpWidget(
        _host(
          TmdbEpisodeStrip(
            cards: const [_card, _card, _card, _card],
            gridMode: grid,
            onTap: (_, _) => taps++,
            onLongPress: (_, _) => holds++,
          ),
        ),
      );
      final target = find.byKey(const ValueKey('tmdb-episode-card-0'));
      final gesture = await tester.startGesture(tester.getCenter(target));
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 0);
      expect(holds, 0);
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      final cancel = await tester.startGesture(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 100));
      await cancel.cancel();
      await tester.pump(const Duration(seconds: 1));
      expect(taps, 0);
      expect(holds, 0);
    });
  }

  testWidgets('DetailView 经 Section 透传显式长按，不执行短按', (tester) async {
    tester.view.physicalSize = const Size(1400, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var taps = 0;
    final events = <(int, int, int)>[];
    await tester.pumpWidget(
      _host(
        TmdbDetailView(
          data: const TmdbDetailData(title: '本页'),
          episodeCards: const [_card],
          onEpisodeTap: (_, _) => taps++,
          onEpisodeLongPress: (index, card) =>
              events.add((index, card.seasonNumber, card.number)),
        ),
      ),
    );
    final target = find.byKey(const ValueKey('tmdb-episode-card-0'));
    await tester.ensureVisible(target);
    await tester.longPress(target);
    await tester.pumpAndSettle();
    expect(events, [(0, 2, 7)]);
    expect(taps, 0);
  });
  for (final grid in [false, true]) {
    testWidgets('${grid ? '网格' : '横向'}卡片短按一次、长按仅打开详情', (tester) async {
      var plays = 0;
      await tester.pumpWidget(
        _host(
          TmdbEpisodeStrip(
            cards: const [_card],
            gridMode: grid,
            onTap: (_, _) => plays++,
          ),
        ),
      );
      final target = find.byKey(const ValueKey('tmdb-episode-card-0'));
      expect(tester.widget(target), isA<OutlinedButton>());
      await tester.tap(target);
      expect(plays, 1);
      await tester.longPress(target);
      await tester.pumpAndSettle();
      expect(find.text('长按应展示这一集的基础简介'), findsOneWidget);
      expect(plays, 1, reason: '长按不能播放或触发原短按');
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-action')));
      await tester.pumpAndSettle();
      expect(plays, 2, reason: '只有显式动作按钮才复用原短按');
    });
  }

  testWidgets('只读卡片保留 null 短按仍可长按基础详情', (tester) async {
    await tester.pumpWidget(_host(const TmdbEpisodeStrip(cards: [_card])));
    final target = find.byKey(const ValueKey('tmdb-episode-card-0'));
    expect(tester.widget<OutlinedButton>(target).onPressed, isNull);
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(find.text('长按应展示这一集的基础简介'), findsNothing);
    await tester.longPress(target);
    await tester.pumpAndSettle();
    expect(find.text('长按应展示这一集的基础简介'), findsOneWidget);
  });
}

class _Client extends http.BaseClient {
  final episodePaths = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    Object body;
    if (path.contains('/episode/')) {
      episodePaths.add(path);
      body = {
        'id': 207,
        'season_number': 2,
        'episode_number': 7,
        'name': '远端第七集',
        'overview': '远端完整详情简介',
        'runtime': 42,
        'credits': {'cast': [], 'crew': []},
      };
    } else if (path.endsWith('/search/multi')) {
      body = {
        'results': [
          {
            'id': 1399,
            'media_type': 'tv',
            'name': '本页剧',
            'first_air_date': '2025-01-01',
          },
        ],
      };
    } else if (path.endsWith('/tv/1399')) {
      body = {
        'id': 1399,
        'name': '本页剧',
        'poster_path': '/owned-poster.jpg',
        'seasons': [
          {'season_number': 2, 'episode_count': 7},
        ],
      };
    } else if (path.endsWith('/season/2')) {
      body = {
        'id': 2,
        'season_number': 2,
        'episodes': [
          for (var i = 1; i <= 7; i++)
            {
              'episode_number': i,
              'season_number': 2,
              'name': '元数据$i',
              'overview': '基础$i',
              'air_date': '2025-01-0$i',
              'vote_average': 9.1,
              'runtime': 42,
              'still_path': '/wrong-$i.jpg',
            },
        ],
      };
    } else {
      body = {'results': []};
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      200,
    );
  }
}

TmdbConfig _config() => const TmdbConfig(apiKey: 'test-key');

class _State extends AppState {
  _State({required super.paths, required this.client, required this.site})
    : super(log: LogService()) {
    service = TmdbService(config: _config, client: client);
    metadata = TmdbState(
      config: _config,
      service: service,
      identityService: TmdbIdentityService(
        config: _config,
        service: service,
        store: InMemoryTmdbMatchStore(),
      ),
      seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
      enrichmentService: TmdbEnrichmentService(
        service: service,
        config: _config,
      ),
    );
  }

  final _Client client;
  final Site site;
  late final TmdbService service;
  late final TmdbState metadata;
  final played = <String>[];

  @override
  TmdbState get tmdb => metadata;
  @override
  TmdbService get tmdbService => service;
  @override
  Site get selectedSite => site;
  @override
  Future<void> loadDetail(
    Vod vod, {
    SiteService? serviceOverride,
    Site? siteOverride,
  }) async {}
  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    int? qualityIndex,
    bool Function()? isCurrent,
    Site? siteOverride,
    SiteService? serviceOverride,
  }) async {
    played.add(episodeTarget);
    throw AppError(AppErrorKind.siteCancelled, '测试取消播放');
  }
}

Vod _vod({bool noLines = false, String id = 'owned'}) => Vod(
  vodId: id,
  vodName: '本页剧',
  vodPlayFrom: noLines ? null : '原线路',
  vodPlayUrl: noLines
      ? null
      : [
          for (var i = 1; i <= 7; i++)
            'S02E0$i 原名保留\$http://example.invalid/e$i',
        ].join('#'),
);

void _pageTests() {
  group('详情页长按接线', () {
    late Directory temp;
    late _Client client;
    final states = <_State>[];

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('episode-long-press');
      client = _Client();
    });
    tearDown(() async {
      dismissAllToasts();
      for (final state in states) {
        state.dispose();
      }
      states.clear();
      await temp.delete(recursive: true);
    });

    Future<_State> stateFor(
      Vod vod, {
      bool nav = false,
      bool stale = false,
    }) async {
      final state = _State(
        paths: AppPaths.resolve(
          overrides: {'roaming': temp.path, 'local': temp.path},
        ),
        client: client,
        site: Site(
          key: 'site',
          name: '本站',
          type: 1,
          api: 'http://example.invalid',
          indexs: nav ? 1 : null,
        ),
      );
      states.add(state);
      await state.bootstrap();
      await state.tmdb.loadForVod(
        stale ? _vod(id: 'previous') : vod,
        siteKey: 'site',
        navSource: nav,
      );
      return state;
    }

    Future<void> pumpPage(WidgetTester tester, Widget page) async {
      tester.view.physicalSize = const Size(1400, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: page));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> reveal(WidgetTester tester, Finder target) async {
      for (var attempt = 0; attempt < 20; attempt++) {
        if (target.evaluate().isNotEmpty) {
          await tester.ensureVisible(target);
          await tester.pump();
          return;
        }
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await tester.pump();
      }
      expect(target, findsOneWidget);
    }

    Future<void> longPressCard(WidgetTester tester, Finder target) async {
      await reveal(tester, target);
      await tester.longPress(target);
      await tester.pumpAndSettle();
    }

    for (final (name, index) in [('前篇', 0), ('后篇', 1)]) {
      testWidgets('无号站源长按$name不猜集号、不请求、不展示猜号元数据', (tester) async {
        final vod = Vod(
          vodId: 'owned',
          vodName: '本页剧',
          vodPlayFrom: '原线路',
          vodPlayUrl: [
            '前篇\$http://example.invalid/e1',
            '后篇\$http://example.invalid/e2',
            for (var i = 3; i <= 7; i++) 'S02E0$i\$http://example.invalid/e$i',
          ].join('#'),
        );
        final state = (await tester.runAsync(() => stateFor(vod)))!;
        await pumpPage(tester, DetailPage(state: state, vod: vod));
        final target = find.byKey(ValueKey('tmdb-episode-card-原线路-$index'));
        await reveal(tester, target);
        final tile = tester.widget<TmdbEpisodeCardTile>(
          find.ancestor(of: target, matching: find.byType(TmdbEpisodeCardTile)),
        );
        expect(tile.card.number, index + 1, reason: '旧卡片仍按位置推号，不能改变旧管线');
        expect(tile.card.overview, '基础${index + 1}', reason: '前置证明已有猜号元数据');
        await longPressCard(tester, target);
        final modal = find.byKey(const ValueKey('tmdb-episode-details'));
        expect(client.episodePaths, isEmpty, reason: '源名无明确集号时不得虚构当集请求');
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('tmdb-episode-title')))
              .data,
          name,
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('tmdb-episode-overview')))
              .data,
          '暂无简介',
        );
        expect(
          find.descendant(
            of: modal,
            matching: find.textContaining('2025-01-0'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(of: modal, matching: find.textContaining('9.1')),
          findsNothing,
        );
        expect(
          find.descendant(of: modal, matching: find.textContaining('42 分钟')),
          findsNothing,
        );
        var provider = tester
            .widget<Image>(
              find
                  .descendant(
                    of: find.byKey(const ValueKey('tmdb-episode-cover')),
                    matching: find.byType(Image),
                  )
                  .first,
            )
            .image;
        while (provider is ResizeImage) {
          provider = provider.imageProvider;
        }
        expect(provider, isA<NetworkImage>());
        expect(
          (provider as NetworkImage).url,
          endsWith('/owned-poster.jpg'),
          reason: '只保留本片海报，不带猜号元数据剧照',
        );
        expect(state.played, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }
    testWidgets('普通站源倒序长按保留真实 S2E7 与原名且不播放', (tester) async {
      final vod = _vod();
      final state = (await tester.runAsync(() => stateFor(vod)))!;
      await pumpPage(tester, DetailPage(state: state, vod: vod));
      final reverse = find.byKey(const ValueKey('tmdb-episode-reverse'));
      await reveal(tester, reverse);
      await tester.tap(reverse);
      await tester.pump();
      await longPressCard(
        tester,
        find.byKey(const ValueKey('tmdb-episode-card-原线路-0')),
      );
      expect(find.text('远端完整详情简介'), findsOneWidget);
      expect(find.textContaining('S02E07 原名保留'), findsOneWidget);
      expect(client.episodePaths, ['/3/tv/1399/season/2/episode/7']);
      expect(state.played, isEmpty);
    });

    for (final nav in [true, false]) {
      testWidgets('${nav ? '导航源' : '无线详情'}长按保留多季卡片身份且不触发换源', (tester) async {
        final vod = _vod(noLines: !nav);
        final state = (await tester.runAsync(() => stateFor(vod, nav: nav)))!;
        await pumpPage(tester, DetailPage(state: state, vod: vod));
        final prefix = nav ? 'nav' : 'noline';
        await longPressCard(
          tester,
          find.byKey(ValueKey('tmdb-episode-card-$prefix-owned-6')),
        );
        expect(find.text('远端完整详情简介'), findsOneWidget);
        expect(client.episodePaths, ['/3/tv/1399/season/2/episode/7']);
        expect(state.played, isEmpty);
        expect(
          find.byKey(const ValueKey('nav-source-swap-dialog')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('no-line-swap-dialog')), findsNothing);
      });
    }

    testWidgets('上一部 TMDB 残留不能用于本页长按请求', (tester) async {
      final vod = _vod();
      final state = (await tester.runAsync(() => stateFor(vod, stale: true)))!;
      await pumpPage(tester, DetailPage(state: state, vod: vod));
      await longPressCard(
        tester,
        find.byKey(const ValueKey('tmdb-episode-card-原线路-6')),
      );
      expect(find.textContaining('S02E07 原名保留'), findsWidgets);
      expect(find.text('远端完整详情简介'), findsNothing);
      expect(client.episodePaths, isEmpty);
      expect(state.played, isEmpty);
    });

    testWidgets('纯 TMDB 页长按使用页面服务及 identity，短按仍搜索站源', (tester) async {
      var searches = 0;
      final service = TmdbService(config: _config, client: client);
      await pumpPage(
        tester,
        TmdbDetailPage(
          service: service,
          identity: TmdbIdentity.of(TmdbMediaType.tv, 1399)!,
          initialItem: const TmdbItem(
            tmdbId: 1399,
            mediaType: TmdbMediaType.tv,
            title: '本页剧',
          ),
          onSearchSource: (_, _) => searches++,
        ),
      );
      final target = find.byKey(const ValueKey('tmdb-only-episode-6'));
      await reveal(tester, target);
      await tester.tap(target);
      expect(searches, 1);
      await longPressCard(tester, target);
      expect(find.text('远端完整详情简介'), findsOneWidget);
      expect(client.episodePaths, ['/3/tv/1399/season/2/episode/7']);
      expect(searches, 1);
    });
  });
}
