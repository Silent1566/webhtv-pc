import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/following_progress_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/following_calendar_page.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/history_entry_detail.dart';
import 'package:webhtv_pc/ui/library_pages.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/detail_test_seams.dart';

const _title = '保留的电影';
const _poster = 'https://fixture.invalid/poster.jpg';
const _deletedId = 'deleted-vod';

class _State extends AppState with ExternalMetaOff {
  _State(Directory dir, http.Client client, this.metadata)
    : super(
        paths: AppPaths.resolve(
          overrides: {
            'config': dir.path,
            'data': dir.path,
            'cache': '${dir.path}/cache',
            'state': '${dir.path}/logs',
          },
        ),
        log: MemoryOnlyLogService(),
        httpClient: client,
      );

  final TmdbState metadata;
  int itemSyncs = 0;

  @override
  TmdbState get tmdb => metadata;

  @override
  FollowingProgressSyncResult syncFollowingProgress({List<Following>? items}) {
    if (items != null) itemSyncs++;
    return super.syncFollowingProgress(items: items);
  }
}

void main() {
  late Directory dir;
  late _State state;
  late TmdbState metadata;
  late List<Uri> requests;

  setUp(() async {
    dismissAllToasts();
    dir = await Directory.systemTemp.createTemp('missing-site-detail-');
    requests = [];
    final client = MockClient((request) async {
      requests.add(request.url);
      final path = request.url.path;
      Object body = {'results': []};
      if (path.endsWith('/movie/550')) {
        body = {'id': 550, 'title': _title, 'overview': '保留身份的元数据'};
      } else if (path == '/station') {
        body = {
          'class': [],
          'list': request.url.queryParameters.containsKey('ids')
              ? [
                  {
                    'vod_id': request.url.queryParameters['ids'],
                    'vod_name': '站点详情',
                    'vod_play_from': '线路一',
                    'vod_play_url': '第1集\$https://fixture.invalid/ep1',
                  },
                ]
              : [],
        };
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    TmdbConfig config() => const TmdbConfig(apiKey: 'fixture');
    final service = TmdbService(config: config, client: client);
    metadata = TmdbState(
      config: config,
      service: service,
      identityService: TmdbIdentityService(
        config: config,
        service: service,
        store: InMemoryTmdbMatchStore(),
      ),
      seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
      enrichmentService: TmdbEnrichmentService(
        service: service,
        config: config,
      ),
    );
    state = _State(dir, client, metadata);
    await state.bootstrap();
  });

  tearDown(() async {
    dismissAllToasts();
    state.dispose();
    metadata.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> seedSites() async {
    expect(
      await state.importConfig(
        jsonEncode({
          'sites': [
            for (final key in ['current', 'original'])
              {
                'key': key,
                'name': key,
                'type': 4,
                'api': 'https://fixture.invalid/station',
                'searchable': 1,
              },
          ],
        }),
      ),
      isTrue,
    );
  }

  PlaybackHistory seedHistory({
    String site = 'deleted',
    int tmdbId = 550,
    String mediaType = 'movie',
  }) {
    state.database!.upsertHistory(
      siteKey: site,
      vodId: _deletedId,
      vodName: _title,
      vodPic: _poster,
      flag: '线路一',
      episodeName: '第1集',
      episodeId: 'https://fixture.invalid/ep1',
      positionMs: 30000,
      durationMs: 100000,
      sourceKey: state.activeSourceKey,
      tmdbId: tmdbId,
      mediaType: mediaType,
    );
    return state.recentHistory().first;
  }

  Following seedFollowing({
    String site = 'deleted',
    String latestEpisodeTarget = '',
  }) {
    final item = Following(
      seriesKey: followingSeriesKey(site, _deletedId),
      season: 0,
      siteKey: site,
      vodId: _deletedId,
      vodName: _title,
      vodPic: _poster,
      flag: '线路一',
      latestReleasedEpisode: 3,
      seasonReleasedEpisodes: 3,
      latestEpisodeName: '第3集',
      latestEpisodeTarget: latestEpisodeTarget,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    state.database!.upsertFollowing(item);
    return item;
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: page)));
    await tester.pump();
    requests.clear();
    state.itemSyncs = 0;
  }

  Future<DetailPage> expectDetail(
    WidgetTester tester, {
    bool missing = true,
  }) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DetailPage), findsOneWidget);
    final page = tester.widget<DetailPage>(find.byType(DetailPage));
    expect(page.vod.vodId, missing ? isEmpty : _deletedId);
    expect(page.vod.vodName, _title);
    expect(page.vod.vodPic, _poster);
    expect(find.textContaining('已不在当前配置中'), findsNothing);
    expect(
      requests.where((uri) => uri.queryParameters.containsKey('play')),
      isEmpty,
    );
    if (missing) {
      expect(
        requests.where((uri) => uri.queryParameters.containsKey('ids')),
        isEmpty,
      );
    }
    return page;
  }

  testWidgets(
    'history row opens fallback with persisted metadata identity and source swap',
    (tester) async {
      await seedSites();
      final item = seedHistory();
      state.seedDetailForTest(
        vod: Vod(
          vodId: 'stale-id',
          vodName: '旧站点影片',
          vodPlayFrom: '旧线路',
          vodPlayUrl: '第9集\$https://fixture.invalid/stale',
        ),
      );
      await pumpPage(tester, HistoryPage(state: state));
      await tester.tap(find.byKey(ValueKey('history-row-${item.id}')));
      final page = await expectDetail(tester);
      expect(page.vod.extra, {'tmdb_id': 550, 'media_type': 'movie'});
      expect(
        metadata.identity?.tmdbId,
        550,
        reason:
            'phase=${metadata.phase} error=${metadata.error} detail=${state.detailPhase} requests=$requests',
      );
      expect(metadata.detail?['overview'], '保留身份的元数据');
      expect(state.selectedSite?.key, 'current');
      expect(state.detailResult, isNull);
      expect(find.text('旧站点影片'), findsNothing);
      expect(find.text('旧线路'), findsNothing);
      expect(state.detailPhase, LoadPhase.ready);
      await tester.pumpAndSettle();
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(600);
      await tester.pump();
      final swap = find.byKey(const ValueKey('nav-source-swap-empty'));
      await tester.ensureVisible(swap);
      await tester.tap(swap);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('source-swap-sheet')), findsOneWidget);
      expect(
        requests.any((uri) => uri.queryParameters['wd'] == _title),
        isTrue,
      );
      expect(
        requests.where((uri) => uri.queryParameters.containsKey('play')),
        isEmpty,
      );
    },
  );

  testWidgets('shared home history action rejects invalid metadata identity', (
    tester,
  ) async {
    await seedSites();
    final item = seedHistory(tmdbId: 550, mediaType: 'invalid');
    await pumpPage(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => unawaited(openHistoryDetail(context, state, item)),
          child: const Text('查看详情'),
        ),
      ),
    );
    await tester.tap(find.text('查看详情'));
    final page = await expectDetail(tester);
    expect(page.vod.extra, isEmpty);
  });

  for (final available in [false, true]) {
    testWidgets(
      'following list marks read and syncs after returning: original site available=$available',
      (tester) async {
        await seedSites();
        final item = seedFollowing(site: available ? 'original' : 'deleted');
        await pumpPage(tester, FollowingPage(state: state));
        await tester.tap(
          find.byKey(ValueKey('following-menu-${item.identityKey}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开详情'));
        final page = await expectDetail(tester, missing: !available);
        expect(page.historyFlag, item.flag);
        expect(state.selectedSite?.key, available ? 'original' : 'current');
        if (available) {
          expect(
            requests.any((uri) => uri.queryParameters['ids'] == _deletedId),
            isTrue,
          );
        }
        expect(
          state.database!.following(item.seriesKey, 0)!.readWatermarkEpisode,
          3,
        );
        expect(state.itemSyncs, 0);
        state.database!.upsertHistory(
          siteKey: item.siteKey,
          vodId: item.vodId,
          vodName: item.vodName,
          flag: item.flag,
          episodeName: '第3集',
          episodeId: 'https://fixture.invalid/ep3',
          positionMs: 100000,
          durationMs: 100000,
          completed: true,
        );
        expect(state.database!.following(item.seriesKey, 0)!.watchedEpisode, 0);
        Navigator.of(tester.element(find.byType(DetailPage))).pop();
        await tester.pumpAndSettle();
        expect(state.itemSyncs, 1);
        expect(state.database!.following(item.seriesKey, 0)!.watchedEpisode, 3);
      },
    );
  }

  for (final configured in [true, false]) {
    testWidgets(
      'following card with retained latest target opens fallback: configured=$configured',
      (tester) async {
        if (configured) await seedSites();
        final item = seedFollowing(
          latestEpisodeTarget: 'https://fixture.invalid/ep3',
        );
        await pumpPage(tester, FollowingPage(state: state));
        await tester.tap(
          find.byKey(ValueKey('following-card-${item.identityKey}')),
        );
        await expectDetail(tester);
        expect(state.selectedSite?.key, configured ? 'current' : null);
        expect(
          state.database!.following(item.seriesKey, 0)!.readWatermarkEpisode,
          3,
        );
        expect(state.database!.following(item.seriesKey, 0)!.watchedEpisode, 0);
        expect(state.itemSyncs, 0);
        Navigator.of(tester.element(find.byType(DetailPage))).pop();
        await tester.pumpAndSettle();
        expect(state.itemSyncs, 1);
        expect(state.database!.following(item.seriesKey, 0)!.watchedEpisode, 0);
      },
    );

    testWidgets(
      'latest calendar tile with retained target opens fallback: configured=$configured',
      (tester) async {
        if (configured) await seedSites();
        final item = seedFollowing(
          latestEpisodeTarget: 'https://fixture.invalid/ep3',
        );
        await pumpPage(tester, FollowingCalendarView(state: state));
        final tile = find.byKey(
          ValueKey('calendar-entry-${item.identityKey}-S01E03'),
        );
        expect(tile, findsOneWidget);
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await expectDetail(tester);
        expect(state.selectedSite?.key, configured ? 'current' : null);
        expect(
          state.database!.following(item.seriesKey, 0)!.readWatermarkEpisode,
          0,
        );
        expect(state.database!.following(item.seriesKey, 0)!.watchedEpisode, 0);
        Navigator.of(tester.element(find.byType(DetailPage))).pop();
        await tester.pumpAndSettle();
        expect(state.itemSyncs, 0);
        expect(state.database!.following(item.seriesKey, 0)!.watchedEpisode, 0);
      },
    );
  }

  testWidgets('calendar entry fallback does not mark read or sync progress', (
    tester,
  ) async {
    await seedSites();
    final item = seedFollowing();
    await pumpPage(tester, FollowingCalendarView(state: state));
    final entry = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('calendar-entry-'),
    );
    expect(entry, findsWidgets);
    await tester.ensureVisible(entry.first);
    await tester.tap(entry.first);
    await expectDetail(tester);
    expect(
      state.database!.following(item.seriesKey, 0)!.readWatermarkEpisode,
      0,
    );
    Navigator.of(tester.element(find.byType(DetailPage))).pop();
    await tester.pumpAndSettle();
    expect(state.itemSyncs, 0);
  });

  for (final available in [false, true]) {
    testWidgets(
      'vod favorite opens detail: original site available=$available',
      (tester) async {
        await seedSites();
        final site = available ? 'original' : 'deleted';
        state.database!.upsertFavorite(
          kind: 'vod',
          siteKey: site,
          targetId: _deletedId,
          title: _title,
          vodPic: _poster,
        );
        await pumpPage(tester, FavoritesPage(state: state));
        await tester.tap(
          find.byKey(ValueKey('favorite-card-vod-$site-$_deletedId')),
        );
        await expectDetail(tester, missing: !available);
        expect(state.selectedSite?.key, available ? 'original' : 'current');
        if (available) {
          expect(
            requests.any((uri) => uri.queryParameters['ids'] == _deletedId),
            isTrue,
          );
        }
      },
    );
  }

  testWidgets('non-vod favorite keeps its existing notification path', (
    tester,
  ) async {
    await seedSites();
    state.database!.upsertFavorite(
      kind: 'site',
      siteKey: 'deleted',
      targetId: 'site-favorite',
      title: '站点收藏',
    );
    await pumpPage(tester, FavoritesPage(state: state));
    await tester.tap(
      find.byKey(const ValueKey('favorite-card-site-deleted-site-favorite')),
    );
    await tester.pump();
    expect(find.byType(DetailPage), findsNothing);
    expect(state.selectedSite?.key, 'current');
    expect(
      toastCenter.toasts.any((entry) => entry.message.contains('站点级收藏没有影片详情')),
      isTrue,
    );
    expect(requests, isEmpty);
  });

  testWidgets(
    'removing last config does not reuse earlier synthetic metadata',
    (tester) async {
      await seedSites();
      await state.loadDetail(
        Vod(
          vodId: '',
          vodName: '上一部电影',
          extra: {'tmdb_id': 550, 'media_type': 'movie'},
        ),
      );
      expect(metadata.hasMatch, isTrue);
      await state.deleteConfigRecord(state.activeRecord!.id);
      final item = seedHistory(tmdbId: 0, mediaType: '');
      await pumpPage(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(openHistoryDetail(context, state, item)),
            child: const Text('查看详情'),
          ),
        ),
      );
      await tester.tap(find.text('查看详情'));
      await expectDetail(tester);
      expect(
        metadata.hasMatch,
        isFalse,
        reason: 'The earlier empty-ID title must not own this missing-site fallback',
      );
    },
  );

  testWidgets('no configured site still opens fallback without stale detail', (
    tester,
  ) async {
    final item = seedHistory();
    state.seedDetailForTest(
      vod: Vod(
        vodId: 'stale-id',
        vodName: '站点详情',
        vodPlayFrom: '旧线路',
        vodPlayUrl: '第9集\$https://fixture.invalid/stale',
      ),
    );
    await pumpPage(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => unawaited(openHistoryDetail(context, state, item)),
          child: const Text('查看详情'),
        ),
      ),
    );
    await tester.tap(find.text('查看详情'));
    await expectDetail(tester);
    expect(find.text('站点详情'), findsNothing);
    expect(find.text('旧线路'), findsNothing);
    expect(state.detailResult, isNull);
    expect(state.selectedVod?.vodName, _title);
    expect(state.selectedSite, isNull);
    expect(metadata.identity?.tmdbId, 550);
    expect(metadata.detail?['overview'], '保留身份的元数据');
    expect(requests.any((uri) => uri.path.endsWith('/movie/550')), isTrue);
    expect(state.detailPhase, LoadPhase.ready);
  });

  testWidgets(
    'metadata reload without selected site refreshes synthetic detail',
    (tester) async {
      final vod = Vod(
        vodId: '',
        vodName: _title,
        extra: {'tmdb_id': 550, 'media_type': 'movie'},
      );
      state.seedDetailForTest(vod: vod);
      expect(state.selectedSite, isNull);
      requests.clear();

      await state.reloadTmdb();

      expect(requests.any((uri) => uri.path.endsWith('/movie/550')), isTrue);
      expect(metadata.identity?.tmdbId, 550);
      expect(metadata.detail?['overview'], '保留身份的元数据');
      expect(
        requests.where((uri) => uri.queryParameters.containsKey('ids')),
        isEmpty,
      );
      expect(
        requests.where((uri) => uri.queryParameters.containsKey('play')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'persisted history from the last deleted config opens synthetic detail',
    (tester) async {
      await seedSites();
      final item = seedHistory();
      expect(item.sourceKey, isNotEmpty);
      await state.deleteConfigRecord(state.activeRecord!.id);
      expect(state.effectiveConfig?.sites ?? const [], isEmpty);
      expect(state.isHistoryFromOtherSource(item), isTrue);

      await pumpPage(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(openHistoryDetail(context, state, item)),
            child: const Text('查看详情'),
          ),
        ),
      );
      await tester.tap(find.text('查看详情'));
      await expectDetail(tester);
      expect(
        toastCenter.toasts.any((entry) => entry.message.contains('无法续播')),
        isFalse,
      );
    },
  );

  testWidgets(
    'first frame of another missing-site item does not claim retained metadata',
    (tester) async {
      await seedSites();
      await state.loadDetail(
        Vod(
          vodId: '',
          vodName: '上一部电影',
          extra: {'tmdb_id': 550, 'media_type': 'movie'},
        ),
      );
      expect(metadata.hasMatch, isTrue);
      await state.deleteConfigRecord(state.activeRecord!.id);
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: state,
            vod: Vod(vodId: '', vodName: _title, vodPic: _poster),
          ),
        ),
      );
      expect(find.byType(TmdbStatusBar), findsNothing);
      expect(find.text('保留身份的元数据'), findsNothing);
    },
  );

  testWidgets('manual metadata matching works without a selected site', (
    tester,
  ) async {
    await tester.runAsync(
      () => state.saveTmdbConfig(const TmdbConfig(apiKey: 'fixture')),
    );
    state.seedDetailForTest(
      vod: Vod(vodId: '', vodName: _title),
    );
    final outcome = await tester.runAsync(
      () => state.matchTmdbManual(
        item: const TmdbItem(
          tmdbId: 550,
          mediaType: TmdbMediaType.movie,
          title: _title,
        ),
      ),
    );
    expect(outcome, isNotNull);
    expect(outcome?.item?.tmdbId, 550);
    expect(
      requests.where((uri) => uri.queryParameters.containsKey('ids')),
      isEmpty,
    );
  });
}
