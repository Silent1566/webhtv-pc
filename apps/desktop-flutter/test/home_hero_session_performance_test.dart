import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/home_hero_art.dart';
import 'package:webhtv_pc/core/detail_recommendation.dart';
import 'package:webhtv_pc/services/search_suggest_service.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/home_hero_startup_cache.dart';
import 'package:webhtv_pc/services/recommendation_feedback_store.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/detail_recommendation_state.dart';
import 'package:webhtv_pc/state/home_hero_session.dart';

import 'support/detail_test_seams.dart';

class _State extends AppState {
  _State(Directory dir, this.metadata)
    : super(
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
  bool maximal = false;
  bool richRecommendations = false;
  late final dependencies = DetailRecommendationDependencies(
    loaders: {
      RecommendationRow.tmdb: (_) async => RecommendationPage(
        items: [
          if (maximal)
            for (var n = 20; n < 40; n++)
              RecommendationEntry(
                item: TmdbItem(
                  tmdbId: richRecommendations ? n + 1 : 0,
                  mediaType: TmdbMediaType.movie,
                  title: 'work$n',
                  backdropUrl: 'https://fixture.invalid/backdrop$n.png',
                ),
                source: RecommendationSource.tmdb,
              ),
        ],
      ),
    },
    feedback: RecommendationFeedbackStore(),
  );
  @override
  Future<List<SearchSuggestItem>> searchHotRank(
    HotRankCategory category,
  ) async => [
    if (maximal && !richRecommendations)
      for (var i = 0; i < 30; i++)
        SearchSuggestItem(
          title: 'hot${category.index}-$i',
          cover:
              'https://fixture.invalid/backdrop${40 + category.index * 30 + i}.png',
        ),
  ];
  String source = 'a';
  List<PlaybackHistory> rows = [row(0), row(1)];
  @override
  String get activeSourceKey => source;
  @override
  TmdbService get tmdbService => metadata;
  @override
  DetailRecommendationDependencies get recommendationDependencies =>
      dependencies;
  @override
  bool get externalMetaEnabled => false;
  @override
  List<PlaybackHistory> recentHistory({int limit = 100, String? sourceKey}) =>
      rows;
  @override
  Future<TmdbItem?> historyTmdbItem(
    PlaybackHistory row, {
    bool Function()? isCurrent,
  }) async => null;
  @override
  Future<Vod?> historyVod(PlaybackHistory row) async => null;
}

PlaybackHistory row(int n, {String? picture}) => PlaybackHistory(
  id: n + 1,
  sourceKey: 'a',
  siteKey: 'site',
  vodId: 'v$n',
  vodName: 'work$n',
  vodPic: picture ?? 'https://fixture.invalid/backdrop$n.png',
  flag: 'line',
  episodeName: 'one',
  episodeId: 'one',
  positionMs: 60000,
  durationMs: 600000,
  updatedAt: 1000 - n,
);

class _ReadFile implements File {
  _ReadFile(this.file, this.opened);
  final File file;
  final void Function() opened;
  @override
  String get path => file.path;
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    opened();
    return file.openSync(mode: mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _State state;
  late TmdbService metadata;
  late HomeHeroSession session;
  final checks = <String>[];
  final pending = <String, Completer<HomeHeroArtEvidence?>>{};
  const hd = HomeHeroArtEvidence(width: 1920, height: 1080);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('hero-performance-');
    metadata = TmdbService(
      config: () => TmdbConfig(
        enabled: state.richRecommendations,
        apiKey: 'fixture',
        imageBase: 'https://fixture.invalid',
        backdropBase: 'https://fixture.invalid',
      ),
      client: MockClient((request) async {
        final id = int.tryParse(request.url.pathSegments.last) ?? 0;
        return http.Response(
          jsonEncode({
            'id': id,
            'title': 'scraped${id - 1}',
            'backdrop_path': '/backdrop${id - 1}.png',
            'overview': 'resolved overview',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    state = _State(dir, metadata);
    session = HomeHeroSession(state);
    checks.clear();
    pending.clear();
    session.attachImageLoader((provider, _) {
      final url = (provider as NetworkImage).url;
      checks.add(url);
      return pending[url]?.future ?? Future.value(null);
    });
    session.attach();
  });
  tearDown(() async {
    session.dispose();
    state.dispose();
    metadata.close();
    await dir.delete(recursive: true);
  });

  int events(String name) => state.log.entries
      .where((entry) => entry.message.contains('event=$name '))
      .length;
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: session,
        builder: (_, _) {
          final projection = session.project(headerRules: const []);
          return Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              projection.heroItems.map((item) => item.title).join('|'),
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> readBarrier(WidgetTester tester) async {
    await tester.runAsync(() async {
      await HomeHeroStartupCache(directory: dir).readAsync('barrier');
      await HomeHeroStartupCache.session(directory: dir).readAsync('barrier');
    });
    await tester.pump();
  }

  String scope() => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            state.activeSourceKey,
            state.metaPipeline.toJson(),
            state.externalMetaEnabled,
            state.metaOverrides.toJson(),
            state.liveSiteKeywords,
            state.tmdbConfig.enabled,
            state.tmdbConfig.imageBase,
            state.tmdbConfig.backdropBase,
            state.tmdbConfig.enabledSites,
            state.tmdbConfig.disabledSites,
            state.tmdbConfig.allowedSites,
          ]),
        ),
      )
      .toString();
  Future<void> seed(WidgetTester tester) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xff123456), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(1280, 720);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final entry = HomeHeroStartupCandidate(
        key: sha256
            .convert(utf8.encode(jsonEncode(['a|site|v0', 0, ''])))
            .toString(),
        sourceUrl: 'https://fixture.invalid/backdrop0.png',
        title: 'offline',
        bytes: Uint8List.sublistView(bytes!),
      );
      await HomeHeroStartupCache(directory: dir).save(scope(), [entry]);
      await HomeHeroStartupCache.session(directory: dir).save(scope(), [entry]);
      image.dispose();
      picture.dispose();
    });
  }

  testWidgets(
    'project never opens cache on caller; same scope restores once offline',
    (tester) async {
      await seed(tester);
      final files = {
        for (final file in dir.listSync(recursive: true).whereType<File>())
          file.path: file,
      };
      var opens = 0;
      final first = await tester.runAsync(
        () async => IOOverrides.runZoned(() {
          final value = session.project(headerRules: const []);
          session.project(headerRules: const []);
          return value;
        }, createFile: (path) => _ReadFile(files[path]!, () => opens++)),
      );
      expect(
        opens,
        0,
        reason: 'cache index/image read and SHA must leave project/build',
      );
      expect(
        first!.heroItems,
        isEmpty,
        reason: 'first frame now reserves a same-height placeholder',
      );
      await readBarrier(tester);
      expect(
        session.project(headerRules: const []).heroItems.single.title,
        'offline',
      );
      session.project(headerRules: const []);
      await readBarrier(tester);
      expect(events('cache_restore'), 1);
      debugPrint(
        'PERF callerCacheOpens=$opens restoreCompletions=1 offlineHeroes=1',
      );
      session.detach();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'late scope A cannot publish into B; disposed restore cannot notify',
    (tester) async {
      await seed(tester);
      var notices = 0;
      session.addListener(() => notices++);
      await tester.runAsync(() async {
        session.project(headerRules: const []);
        state.source = 'b';
        session.project(headerRules: const []);
      });
      await readBarrier(tester);
      expect(
        events('cache_restore'),
        1,
        reason: 'late scope A completion is rejected',
      );
      expect(session.project(headerRules: const []).heroItems, isEmpty);
      session.dispose();
      final before = notices;
      await readBarrier(tester);
      expect(notices, before);
      debugPrint('PERF lateScopeAccepted=0 finalScopeHeroes=0');
    },
  );

  testWidgets(
    'held pair plus append preserves one scan and at most two image checks',
    (tester) async {
      for (var n = 0; n < 3; n++) {
        pending['https://fixture.invalid/backdrop$n.png'] = Completer();
      }
      await mount(tester);
      expect(checks, hasLength(2));
      state.rows.add(row(2));
      session.project(headerRules: const []);
      await tester.pump();
      expect(
        events('scan_start'),
        1,
        reason: 'unchanged pending pair must not be rescheduled',
      );
      expect(checks, hasLength(2));
      pending.values.elementAt(1).complete(hd);
      await tester.pump();
      expect(
        session.project(headerRules: const []).heroItems,
        isEmpty,
        reason: 'pair publishes in candidate order',
      );
      pending.values.first.complete(hd);
      await tester.pumpAndSettle();
      expect(checks, hasLength(3));
      expect(
        session
            .project(headerRules: const [])
            .heroItems
            .map((item) => item.title),
        ['work0', 'work1'],
      );
      pending.values.last.complete(hd);
      await tester.pumpAndSettle();
      expect(
        session
            .project(headerRules: const [])
            .heroItems
            .map((item) => item.title),
        ['work0', 'work1', 'work2'],
      );
      expect(checks.toSet(), hasLength(3));
      debugPrint(
        'PERF heldAppendChecks=${checks.length} scanStarts=${events('scan_start')}',
      );
      session.detach();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'all 120 rejected candidates finish without per-pair visible notifications',
    (tester) async {
      state.maximal = true;
      state.rows = [for (var n = 0; n < 20; n++) row(n)];
      for (var n = 0; n < 130; n++) {
        pending['https://fixture.invalid/backdrop$n.png'] = Completer();
      }
      await mount(tester);
      var notices = 0;
      session.addListener(() => notices++);
      for (final held in pending.values) {
        held.complete(null);
      }
      await tester.pumpAndSettle();
      debugPrint(
        'PERF rejectedChecks=${checks.length} pureScanNotices=$notices',
      );
      expect(checks, hasLength(120));
      expect(session.scanRunning, isFalse);
      expect(
        notices,
        lessThanOrEqualTo(2),
        reason: 'failed pairs only update internal progress',
      );
      expect(session.project(headerRules: const []).heroItems, isEmpty);
      session.detach();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'rejected image batch still publishes newly resolved rail metadata',
    (tester) async {
      state.maximal = true;
      state.richRecommendations = true;
      state.rows = [row(0)];
      for (final n in [0, 24, 25]) {
        pending['https://fixture.invalid/backdrop$n.png'] = Completer();
      }
      var titlesAtNotification = <String>[];
      session.addListener(() {
        titlesAtNotification = [
          for (final rail in session.project(headerRules: const []).rails)
            for (final item in rail.items) item.title,
        ];
      });
      await mount(tester);
      expect(titlesAtNotification, isNot(contains('scraped23')));
      pending.values.elementAt(0).complete(null);
      await tester.pumpAndSettle();
      expect(session.scanRunning, isTrue, reason: 'later pair remains held');
      expect(
        titlesAtNotification,
        contains('scraped23'),
        reason: 'new rail metadata must notify even though its image failed',
      );
      session.detach();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pending restore detach retries without notification; dispose ignores completion',
    (tester) async {
      await seed(tester);
      state.rows = [];
      var notices = 0;
      session.addListener(() => notices++);
      await tester.runAsync(() async {
        session.project(headerRules: const []);
        session.detach();
      });
      await readBarrier(tester);
      expect(events('cache_restore'), 0);
      expect(notices, 0);
      state.rows = [row(0), row(1)];
      session.attach();
      await tester.runAsync(() async => session.project(headerRules: const []));
      await readBarrier(tester);
      expect(
        session.project(headerRules: const []).heroItems.single.title,
        'offline',
      );
      expect(events('cache_restore'), 1);
      await tester.runAsync(() async {
        state.source = 'b';
        session.project(headerRules: const []);
        session.dispose();
      });
      final before = notices;
      await readBarrier(tester);
      expect(notices, before);
      expect(events('cache_restore'), 1);
    },
  );

  testWidgets('prepend while pair is pending keeps current candidate order', (
    tester,
  ) async {
    for (var n = 0; n < 3; n++) {
      pending['https://fixture.invalid/backdrop$n.png'] = Completer();
    }
    await mount(tester);
    state.rows = [row(2), row(0), row(1)];
    // Newest row becomes the first candidate.
    final first = row(2);
    state.rows[0] = PlaybackHistory(
      id: first.id,
      sourceKey: first.sourceKey,
      siteKey: first.siteKey,
      vodId: first.vodId,
      vodName: first.vodName,
      vodPic: first.vodPic,
      flag: first.flag,
      episodeName: first.episodeName,
      episodeId: first.episodeId,
      positionMs: first.positionMs,
      durationMs: first.durationMs,
      updatedAt: 2000,
    );
    session.project(headerRules: const []);
    tester.binding.scheduleFrame();
    await tester.pump();
    pending.values.elementAt(0).complete(hd);
    pending.values.elementAt(1).complete(hd);
    await tester.pumpAndSettle();
    expect(
      session.project(headerRules: const []).heroItems,
      isEmpty,
      reason:
          'a newly earlier candidate must settle before accepting the old pair',
    );
    pending.values.elementAt(2).complete(hd);
    await tester.pumpAndSettle();
    expect(
      session
          .project(headerRules: const [])
          .heroItems
          .map((item) => item.title),
      ['work2', 'work0', 'work1'],
    );
    session.detach();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changed first candidate keeps unchanged second behind replacement', (
    tester,
  ) async {
    final oldFirst = Completer<HomeHeroArtEvidence?>();
    final second = Completer<HomeHeroArtEvidence?>();
    final replacement = Completer<HomeHeroArtEvidence?>();
    pending['https://fixture.invalid/backdrop0.png'] = oldFirst;
    pending['https://fixture.invalid/backdrop1.png'] = second;
    pending['https://fixture.invalid/replaced.png'] = replacement;
    await mount(tester);
    expect(checks, hasLength(2));
    state.rows = [
      row(0, picture: 'https://fixture.invalid/replaced.png'),
      row(1),
    ];
    session.project(headerRules: const []);
    tester.binding.scheduleFrame();
    await tester.pump();
    second.complete(hd);
    oldFirst.complete(hd);
    await tester.pumpAndSettle();
    final interim = session.project(headerRules: const []).heroItems;
    debugPrint(
      'PERF changedFirstInterim=${interim.map((item) => item.title).toList()} checks=${checks.length} scanStarts=${events('scan_start')}',
    );
    expect(
      interim,
      isEmpty,
      reason:
          'unchanged second must not publish ahead of changed first candidate',
    );
    expect(checks.where((url) => url.endsWith('replaced.png')), hasLength(1));
    expect(
      checks.where((url) => url.endsWith('backdrop1.png')),
      hasLength(1),
      reason: 'reconsidering the pair reuses unchanged second probe evidence',
    );
    expect(events('scan_start'), 1);
    replacement.complete(hd);
    await tester.pumpAndSettle();
    final titles = session
        .project(headerRules: const [])
        .heroItems
        .map((item) => item.title)
        .toList();
    expect(titles, ['work0', 'work1']);
    expect(checks, hasLength(3));
    debugPrint(
      'PERF changedFirstFinal=$titles checks=${checks.length} scanStarts=${events('scan_start')}',
    );
    session.detach();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changed or removed pending candidate cannot accept stale art', (
    tester,
  ) async {
    final old = Completer<HomeHeroArtEvidence?>();
    pending['https://fixture.invalid/backdrop0.png'] = old;
    final second = Completer<HomeHeroArtEvidence?>();
    pending['https://fixture.invalid/backdrop1.png'] = second;
    await mount(tester);
    state.rows = [row(0, picture: 'https://fixture.invalid/replaced.png')];
    session.project(headerRules: const []);
    tester.binding.scheduleFrame();
    await tester.pump();
    second.complete(hd);
    old.complete(hd);
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(session.project(headerRules: const []).heroItems, isEmpty);
    expect(checks.where((url) => url.endsWith('replaced.png')), hasLength(1));
    session.detach();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
