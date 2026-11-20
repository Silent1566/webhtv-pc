import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

import 'support/test_fonts.dart';
import 'support/detail_test_seams.dart';

import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/episode_aggregation.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/ai_season_mapping_service.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/toast.dart';

void main() {
  _pageTests();
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
    await loadFixtureFonts(cjkFamily: 'Roboto');
  });
  for (final grid in [false, true]) {
    testWidgets('badge and sizes stay visible at scale1.5 layout $grid', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1024, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(1024, 700),
              textScaler: TextScaler.linear(1.5),
            ),
            child: Scaffold(
              body: TmdbEpisodeStrip(
                cards: const [
                  TmdbEpisodeCard(
                    number: 1,
                    title: '第1集',
                    variantCount: 2,
                    groupLabel: 'S1E1',
                    fileSizeLabel: '大小不全',
                  ),
                  TmdbEpisodeCard(
                    number: 2,
                    title: '第2集',
                    fileSizeLabel: '2 GB',
                  ),
                  TmdbEpisodeCard(number: 3, title: '未知大小'),
                ],
                cardWidth: 200,
                gridMode: grid,
                onTap: (_, _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 版本'), findsOneWidget);
      expect(find.text('大小不全'), findsOneWidget);
      expect(find.text('2 GB'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  for (final brightness in Brightness.values) {
    testWidgets('duplicate episode visual ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(1024, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      final sourceCards = [
        for (var i = 1; i <= 3; i++)
          for (final quality in ['1080p', '2160p'])
            TmdbEpisodeCard(
              number: i,
              seasonNumber: 1,
              title: 'E$i 海岸线上的漫长旅程与重逢',
              sourceName:
                  '海岸线.S01E0$i.$quality.WEB-DL.H265[${quality == '1080p' ? '1' : '3'}GB].mkv',
              runtime: 42,
            ),
      ];
      final groups = EpisodeAggregation.build([
        for (var i = 0; i < sourceCards.length; i++)
          VodEpisode(name: sourceCards[i].sourceName, url: 'raw-$i'),
      ]);
      final cards = [
        for (final group in groups)
          TmdbEpisodeCard(
            number: group.episodeNumber,
            seasonNumber: group.seasonNumber,
            title: sourceCards[group.versions.first.sourceIndex].title,
            sourceName: group.label,
            groupLabel: group.label,
            variantCount: group.versions.length,
            fileSizeLabel: group.sizeSummary,
            runtime: 42,
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('海岸线', style: TextStyle(fontSize: 28)),
                    const SizedBox(height: 24),
                    TmdbEpisodeHeader(
                      episodeCount: cards.length,
                      reversed: false,
                      gridMode: true,
                      lineName: 'quark · 完整剧集与多版本文件',
                      onToggleNameMode: () {},
                      onToggleAggregation: () {},
                    ),
                    TmdbEpisodeStrip(
                      cards: cards,
                      cardWidth: 180,
                      gridMode: true,
                      onTap: (_, _) {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final phase = Platform.environment['EPISODE_AGGREGATION_CAPTURE'];
      if (phase == null) return;
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '../../.local/episode-aggregation/detail/$phase-${brightness.name}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    });
  }
}

class _DetailState extends AppState with ExternalMetaOff {
  _DetailState(Directory dir)
    : super(
        paths: AppPaths.resolve(
          overrides: {
            for (final key in ['config', 'data', 'cache', 'state'])
              key: dir.path,
          },
        ),
        log: MemoryOnlyLogService(),
      );
  final played = <String>[];
  bool aggregate = true;
  bool navigationOnly = false;
  AiSeasonBindingsResult? mappings;
  TmdbState? metadata;
  final historyRows = <PlaybackHistory>[];
  bool failPlayback = false;
  @override
  PlaybackHistory? findHistory({
    required String siteKey,
    required String vodId,
    String? flag,
    String? episodeId,
    String? episodeName,
    String? sourceKey,
  }) {
    final matches =
        historyRows
            .where(
              (row) =>
                  row.vodId == vodId &&
                  (flag == null || row.flag == flag) &&
                  (episodeId == null || row.episodeId == episodeId),
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return matches.firstOrNull;
  }

  @override
  TmdbState get tmdb => metadata ?? super.tmdb;
  @override
  AiSeasonBindingsResult? aiMappingsFor(Vod vod, VodPlayLine line) => mappings;
  @override
  Site get selectedSite => Site(
    key: 'fixture',
    name: 'Fixture',
    type: 1,
    api: 'https://fixture.invalid',
    indexs: navigationOnly ? 1 : null,
  );
  @override
  bool get episodeAggregateVersions => aggregate;
  @override
  Future<void> setEpisodeAggregateVersions(bool enabled) async {
    aggregate = enabled;
    notifyListeners();
  }

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
    bool Function()? isCurrent,
    int? qualityIndex,
    Site? siteOverride,
    String? preferredParseName,
    SiteService? serviceOverride,
  }) async {
    played.add(episodeTarget);
    if (failPlayback) throw AppError(AppErrorKind.playbackUrlMissing, '测试失败');
    throw AppError(AppErrorKind.siteCancelled, '测试结束');
  }
}

class _KnownMetadata extends TmdbState {
  _KnownMetadata(TmdbService service)
    : super(
        config: () => const TmdbConfig(),
        service: service,
        identityService: TmdbIdentityService(
          config: () => const TmdbConfig(),
          service: service,
          store: InMemoryTmdbMatchStore(),
        ),
        seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
        enrichmentService: TmdbEnrichmentService(
          service: service,
          config: () => const TmdbConfig(),
        ),
      );
  @override
  bool belongsTo(String vodId, {String? siteKey, String? sourceTitle}) => true;
  @override
  int get selectedSeason => 1;
  @override
  List<int> get availableSeasons => [1];
  @override
  Map<int, TmdbEpisode> get episodeMetadataByNumber => {
    for (var i = 1; i <= 4; i++)
      i: TmdbEpisode(number: i, seasonNumber: 1, title: '元数据$i'),
  };
  @override
  TmdbEpisodeEnrichmentResult applyEpisodesToLine(VodPlayLine line) =>
      TmdbEpisodeEnrichmentResult(line: line, changed: false, appliedCount: 0);
}

void _pageTests() {
  late _DetailState state;
  setUp(() async {
    final base = Directory(
      '../../.local/episode-aggregation/detail/test-state',
    );
    await base.create(recursive: true);
    final dir = await base.createTemp('ui-');
    state = _DetailState(dir.absolute);
    await state.bootstrap();
  });
  tearDown(() {
    dismissAllToasts();
    state.dispose();
  });
  Vod vod({bool duplicates = true}) => Vod(
    vodId: 'aggregation',
    vodName: '海岸线',
    vodPlayFrom: 'quark',
    vodPlayUrl: [
      'S01E01.1080p[1GB].mkv\$raw-a',
      if (duplicates) 'S01E01.2160p[3GB].mkv\$raw-b',
      'S01E02.1080p[2GB].mkv\$raw-c',
      '未知内容甲\$unknown-a',
      '未知内容甲\$unknown-b',
    ].join('#'),
  );
  Future<void> pump(
    WidgetTester tester,
    Vod item, {
    String historyUrl = '',
  }) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: item,
          historyFlag: historyUrl.isEmpty ? '' : 'quark',
          historyEpisodeId: historyUrl,
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('tmdb-episode-header')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  int cards(WidgetTester tester) => tester
      .widgetList<OutlinedButton>(find.byType(OutlinedButton))
      .where(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith(
              'tmdb-episode-card-quark-',
            ),
      )
      .length;
  testWidgets(
    'full current line duplicates switch survives off and re-enable, unknown stays independent',
    (tester) async {
      await pump(tester, vod());
      final toggle = find.byKey(const ValueKey('tmdb-episode-aggregation'));
      expect(toggle, findsOneWidget);
      expect(cards(tester), 4);
      expect(find.text('2 版本'), findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      expect(state.aggregate, isFalse);
      expect(toggle, findsOneWidget);
      expect(cards(tester), 5);
      await tester.tap(toggle);
      await tester.pump();
      expect(state.aggregate, isTrue);
      expect(cards(tester), 4);
    },
  );
  testWidgets(
    'confirmed AI groups filter by season while full-line switch stays visible',
    (tester) async {
      state.mappings = const AiSeasonBindingsResult(
        status: AiSeasonApplyStatus.applied,
        bindings: [
          AiEpisodeBinding(sourceIndex: 0, seasonNumber: 1, episodeNumber: 1),
          AiEpisodeBinding(sourceIndex: 1, seasonNumber: 1, episodeNumber: 1),
          AiEpisodeBinding(sourceIndex: 2, seasonNumber: 2, episodeNumber: 1),
        ],
      );
      final item = Vod(
        vodId: 'ai',
        vodName: 'AI',
        vodPlayFrom: 'quark',
        vodPlayUrl: [
          r'文件甲[1GB]$ai-a',
          r'文件乙[3GB]$ai-b',
          r'文件丙[2GB]$ai-c',
        ].join('#'),
      );
      await pump(tester, item);
      expect(cards(tester), 2);
      await tester.tap(find.text('第2季'));
      await tester.pump();
      expect(cards(tester), 1);
      expect(
        find.byKey(const ValueKey('tmdb-episode-aggregation')),
        findsOneWidget,
      );
      final strip = tester.widget<TmdbEpisodeStrip>(
        find.byKey(const ValueKey('tmdb-episode-strip-quark')),
      );
      expect(strip.cards.single.number, 1);
      expect(strip.cards.single.seasonNumber, 2);
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-card-quark-0')));
      await tester.pump();
      expect(state.played, ['ai-c']);
    },
  );
  testWidgets('group ranges and focus follow historical non-first variant', (
    tester,
  ) async {
    final item = Vod(
      vodId: 'many',
      vodName: 'Many',
      vodPlayFrom: 'quark',
      vodPlayUrl: [
        for (var i = 1; i <= 25; i++)
          for (final profile in ['1080p', '2160p'])
            'S01E${i.toString().padLeft(2, '0')}.$profile\$raw-$i-$profile',
      ].join('#'),
    );
    await pump(tester, item, historyUrl: 'raw-25-2160p');
    final strip = tester.widget<TmdbEpisodeStrip>(
      find.byKey(const ValueKey('tmdb-episode-strip-quark')),
    );
    expect(strip.cards.length, 25);
    expect(strip.recentIndex, 24);
    expect(strip.rangeIndex, 1);
    expect(strip.ranges.map((range) => range.label), ['1-20', '21-25']);
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-quark-recent-24')),
      findsOneWidget,
    );
  });
  testWidgets('stale preference callback invalidates pending version choice', (
    tester,
  ) async {
    await pump(tester, vod());
    final header = tester.widget<TmdbEpisodeHeader>(
      find.byType(TmdbEpisodeHeader),
    );
    await tester.tap(find.byKey(const ValueKey('tmdb-episode-card-quark-0')));
    await tester.pump(const Duration(milliseconds: 300));
    header.onToggleAggregation!();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('episode-version-confirm')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.played, isEmpty);
  });
  testWidgets(
    'covered route invalidates confirmed selection before resolver starts',
    (tester) async {
      await pump(tester, vod());
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-card-quark-0')));
      await tester.pump(const Duration(milliseconds: 300));
      final confirm = tester.widget<FilledButton>(
        find.byKey(const ValueKey('episode-version-confirm')),
      );
      final navigator = Navigator.of(
        tester.element(find.byKey(const ValueKey('episode-version-confirm'))),
      );
      confirm.onPressed!();
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('covered')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.played, isEmpty);
    },
  );
  testWidgets('pure navigation page does not offer aggregation control', (
    tester,
  ) async {
    state.navigationOnly = true;
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(state: state, vod: vod()),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.byKey(const ValueKey('tmdb-episode-aggregation')),
      findsNothing,
    );
    expect(cards(tester), 0);
  });
  testWidgets(
    'group remembers its exact historical version after another episode played',
    (tester) async {
      for (final row in [
        ('raw-b', 'S01E01.2160p[3GB].mkv', 10),
        ('raw-c', 'S01E02.1080p[2GB].mkv', 20),
      ]) {
        state.historyRows.add(
          PlaybackHistory(
            id: row.$3,
            siteKey: 'fixture',
            vodId: 'aggregation',
            vodName: '海岸线',
            flag: 'quark',
            episodeName: row.$2,
            episodeId: row.$1,
            positionMs: 0,
            durationMs: 0,
            updatedAt: row.$3,
          ),
        );
      }
      await pump(tester, vod());
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-card-quark-0')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('episode-version-confirm')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.played, ['raw-b']);
    },
  );
  for (final aggregate in [true, false]) {
    testWidgets(
      'shared URL different raw names preserve clicked identity aggregation $aggregate',
      (tester) async {
        state.aggregate = aggregate;
        state.failPlayback = true;
        final item = Vod(
          vodId: 'same-name',
          vodName: 'Same URL',
          vodPlayFrom: 'quark',
          vodPlayUrl: [r'第1集$same-url', r'第2集$same-url'].join('#'),
        );
        await pump(tester, item);
        await tester.tap(
          find.byKey(const ValueKey('tmdb-episode-card-quark-1')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        final dialog = find.byKey(const ValueKey('detail-playback-failed'));
        expect(
          find.descendant(of: dialog, matching: find.text('第2集')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('detail-playback-failed-dismiss')),
        );
        await tester.pump(const Duration(milliseconds: 300));
      },
    );
  }
  testWidgets('shared URL historical name focuses actual second raw group', (
    tester,
  ) async {
    state.historyRows.add(
      const PlaybackHistory(
        id: 1,
        siteKey: 'fixture',
        vodId: 'same-name',
        vodName: 'Same URL',
        flag: 'quark',
        episodeName: '第2集',
        episodeId: 'same-url',
        positionMs: 0,
        durationMs: 0,
        updatedAt: 1,
      ),
    );
    final item = Vod(
      vodId: 'same-name',
      vodName: 'Same URL',
      vodPlayFrom: 'quark',
      vodPlayUrl: [r'第1集$same-url', r'第2集$same-url'].join('#'),
    );
    await pump(tester, item);
    final strip = tester.widget<TmdbEpisodeStrip>(
      find.byKey(const ValueKey('tmdb-episode-strip-quark')),
    );
    expect(strip.recentIndex, 1);
  });
  testWidgets('repeated raw URLs retain distinct source positions', (
    tester,
  ) async {
    final item = Vod(
      vodId: 'same-url',
      vodName: 'Same URL',
      vodPlayFrom: 'quark',
      vodPlayUrl: [r'未知甲$same-url', r'未知乙$same-url'].join('#'),
    );
    await pump(tester, item);
    final strip = tester.widget<TmdbEpisodeStrip>(
      find.byKey(const ValueKey('tmdb-episode-strip-quark')),
    );
    expect(strip.cards.map((card) => card.number), [1, 2]);
  });
  testWidgets(
    'numeric filename groups use recognized identity not representative raw position',
    (tester) async {
      final item = Vod(
        vodId: 'numeric',
        vodName: 'Numeric',
        vodPlayFrom: 'quark',
        vodPlayUrl: [
          r'[1GB] 01.mkv$one-low',
          r'[3GB] 01.mkv$one-high',
          r'[2GB] 02.mkv$two-low',
          r'[4GB] 02.mkv$two-high',
        ].join('#'),
      );
      await pump(tester, item);
      final strip = tester.widget<TmdbEpisodeStrip>(
        find.byKey(const ValueKey('tmdb-episode-strip-quark')),
      );
      expect(strip.cards.map((card) => card.number), [1, 2]);
      expect(strip.ranges.single.label, '1-2');
      expect(find.text('E3'), findsNothing);
    },
  );
  testWidgets(
    'numeric grouped identity chooses correct metadata rather than raw position',
    (tester) async {
      final metadata = _KnownMetadata(state.tmdbService);
      state.metadata = metadata;
      addTearDown(metadata.dispose);
      final item = Vod(
        vodId: 'numeric-meta',
        vodName: 'Numeric',
        vodPlayFrom: 'quark',
        vodPlayUrl: [
          r'[1GB] 01.mkv$one-low',
          r'[3GB] 01.mkv$one-high',
          r'[2GB] 02.mkv$two-low',
          r'[4GB] 02.mkv$two-high',
        ].join('#'),
      );
      await pump(tester, item);
      final strip = tester.widget<TmdbEpisodeStrip>(
        find.byKey(const ValueKey('tmdb-episode-strip-quark')),
      );
      expect(strip.cards.map((card) => card.number), [1, 2]);
      expect(strip.cards[1].title, contains('元数据2'));
      expect(strip.cards[1].title, isNot(contains('元数据3')));
      expect(strip.ranges.single.label, '1-2');
    },
  );
  testWidgets(
    'non-first historical version marks group and card confirms exact URL',
    (tester) async {
      await pump(tester, vod(), historyUrl: 'raw-b');
      expect(
        find.byKey(const ValueKey('tmdb-episode-card-quark-recent-0')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-card-quark-0')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.played, isEmpty);
      await tester.tap(find.byKey(const ValueKey('episode-version-confirm')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.played, ['raw-b']);
    },
  );
  testWidgets('reverse changes groups, not source order of variants', (
    tester,
  ) async {
    await pump(tester, vod());
    await tester.tap(find.byKey(const ValueKey('tmdb-episode-reverse')));
    await tester.pump();
    final strip = tester.widget<TmdbEpisodeStrip>(
      find.byKey(const ValueKey('tmdb-episode-strip-quark')),
    );
    expect(strip.cards.last.groupLabel, 'S1E1');
    await tester.tap(find.byKey(const ValueKey('tmdb-episode-card-quark-3')));
    await tester.pump(const Duration(milliseconds: 300));
    final first = tester.getTopLeft(
      find.byKey(const ValueKey('episode-version-option-0')),
    );
    final second = tester.getTopLeft(
      find.byKey(const ValueKey('episode-version-option-1')),
    );
    expect(first.dy, lessThan(second.dy));
    await tester.tap(find.byKey(const ValueKey('episode-version-cancel')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.played, isEmpty);
  });
  testWidgets(
    'aggregate original name uses logical label with separate nonduplicated size',
    (tester) async {
      await pump(tester, vod());
      await tester.tap(find.byKey(const ValueKey('tmdb-episode-name-mode')));
      await tester.pump();
      final strip = tester.widget<TmdbEpisodeStrip>(
        find.byKey(const ValueKey('tmdb-episode-strip-quark')),
      );
      expect(strip.cards.first.sourceName, isNot(contains('GB')));
      expect(strip.cards.first.fileSizeLabel, '1–3 GB');
      expect(find.text('S1E1'), findsWidgets);
      expect(find.text('S01E01.1080p.mkv'), findsNothing);
      expect(find.text('1–3 GB'), findsOneWidget);
    },
  );
  testWidgets(
    'exact history hero resumes concrete version without a selector',
    (tester) async {
      await pump(tester, vod(), historyUrl: 'raw-b');
      final hero = find.byKey(const ValueKey('detail-hero-play'));
      await tester.ensureVisible(hero);
      await tester.tap(hero);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.played, ['raw-b']);
      expect(
        find.byKey(const ValueKey('episode-version-dialog')),
        findsNothing,
      );
    },
  );
  testWidgets('hero without exact history requires explicit version choice', (
    tester,
  ) async {
    await pump(tester, vod());
    final hero = find.byKey(const ValueKey('detail-hero-play'));
    await tester.ensureVisible(hero);
    await tester.tap(hero);
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.played, isEmpty);
    expect(
      find.byKey(const ValueKey('episode-version-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('episode-version-cancel')));
    await tester.pump(const Duration(milliseconds: 300));
  });
  testWidgets(
    'ordinary raw line has no aggregation switch and single plays directly',
    (tester) async {
      await pump(tester, vod(duplicates: false));
      expect(
        find.byKey(const ValueKey('tmdb-episode-aggregation')),
        findsNothing,
      );
      expect(cards(tester), 4);
      final card = find.byKey(const ValueKey('tmdb-episode-card-quark-0'));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pump();
      expect(state.played, ['raw-a']);
    },
  );
  testWidgets(
    'multi cancel has zero resolver calls and explicit selection preserves raw URL',
    (tester) async {
      await pump(tester, vod());
      final card = find.byKey(const ValueKey('tmdb-episode-card-quark-0'));
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.played, isEmpty);
      await tester.tap(find.byKey(const ValueKey('episode-version-cancel')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.played, isEmpty);
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('episode-version-option-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('episode-version-confirm')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.played, ['raw-b']);
    },
  );
}
