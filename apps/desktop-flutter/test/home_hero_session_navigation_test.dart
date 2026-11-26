import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/home_hero_art.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/home_backdrop.dart';
import 'package:webhtv_pc/ui/home_hero.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/home_hd_art_fixture.dart';

class _NavigationState extends AppState {
  _NavigationState(Directory directory, this.metadata)
    : super(
        paths: AppPaths.resolve(
          overrides: {
            // 契约（tests/test_linux_path_isolation.py）：四个平台目录必须逐字列出，
            // 不允许用计算出来的映射——漏一个键会悄悄把缓存写到默认目录。
            'config': directory.path,
            'data': directory.path,
            'cache': directory.path,
            'state': directory.path,
          },
        ),
      );

  final TmdbService metadata;
  final rows = [
    for (var index = 0; index < 13; index++)
      PlaybackHistory(
        id: index + 1,
        siteKey: 'site',
        vodId: 'v$index',
        vodName: '作品$index',
        vodPic: 'https://fixture.example/poster$index.jpg',
        flag: 'line',
        episodeName: '第1集',
        episodeId: 'entry$index',
        positionMs: 60000,
        durationMs: 600000,
        updatedAt: 1000 - index,
        tmdbId: index + 1,
        mediaType: 'tv',
      ),
  ];

  @override
  TmdbService get tmdbService => metadata;

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

void main() {
  late Directory directory;
  late TmdbService metadata;
  late _NavigationState state;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('home-hero-navigation-');
    metadata = TmdbService(
      config: () => const TmdbConfig(apiKey: 'fixture'),
      client: MockClient((request) async {
        final id = int.tryParse(request.url.pathSegments.last) ?? 0;
        return http.Response(
          jsonEncode({
            'id': id,
            'name': '作品${id - 1}',
            'poster_path': '/poster$id.jpg',
            'backdrop_path': '/backdrop$id.jpg',
            'overview': '剧情$id',
            'first_air_date': '2026-01-01',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    state = _NavigationState(directory, metadata);
  });

  tearDown(() {
    state.dispose();
    metadata.close();
    directory.deleteSync(recursive: true);
  });

  testWidgets('同次运行切走再返回立即恢复12张和第8张，下一张从第9张继续', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final inspected = <String>[];
    Completer<void>? returnImageGate;

    Future<HomeHeroArtEvidence?> imageLoader(
      ImageProvider<Object> provider,
      ImageConfiguration configuration,
    ) async {
      final url = (provider as NetworkImage).url;
      inspected.add(url);
      if (returnImageGate != null) await returnImageGate.future;
      if (url.endsWith('/backdrop1.jpg')) {
        return const HomeHeroArtEvidence(width: 1279, height: 720);
      }
      return loadHdHeroFixture(provider, configuration);
    }

    Widget home() => MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: HomePage(
          state: state,
          onOpenBrowse: () {},
          onOpenHistory: () {},
          onOpenFollowing: () {},
          onImportConfig: () {},
          onSearch: (_) {},
          heroImageLoader: imageLoader,
        ),
      ),
    );

    const away = MaterialApp(home: Scaffold(body: Text('另一个页面')));
    final heroFinder = find.byType(HomeHero);
    final backdropFinder = find.byType(HomeBackdrop);

    try {
      await tester.pumpWidget(home());
      await tester.pumpAndSettle();
      expect(tester.widget<HomeHero>(heroFinder).items, hasLength(12));
      expect(
        tester.widget<HomeHero>(heroFinder).items.map((item) => item.title),
        [for (var index = 1; index <= 12; index++) '作品$index'],
        reason: '13个候选中仅12张高清宽图合格，第13个候选必须补满',
      );
      expect(inspected, contains(endsWith('/backdrop13.jpg')));

      await tester.tap(find.byKey(const ValueKey('home-hero-dot-7')));
      await tester.pump();
      expect(tester.widget<HomeBackdrop>(backdropFinder).index, 7);
      await tester.pumpAndSettle();
      final checksBeforeLeaving = inspected.length;
      final titlesBeforeLeaving = tester
          .widget<HomeHero>(heroFinder)
          .items
          .map((item) => item.title)
          .toList();

      await tester.pumpWidget(away);
      expect(find.byType(HomePage), findsNothing);
      expect(find.text('另一个页面'), findsOneWidget);
      returnImageGate = Completer<void>();

      await tester.pumpWidget(home());
      expect(returnImageGate.isCompleted, isFalse);
      expect(heroFinder, findsOneWidget, reason: '返回首帧不能等待图片复查');
      expect(tester.widget<HomeHero>(heroFinder).items, hasLength(12));
      expect(
        tester.widget<HomeHero>(heroFinder).items.map((item) => item.title),
        titlesBeforeLeaving,
      );
      expect(tester.widget<HomeBackdrop>(backdropFinder).index, 7);
      expect(inspected.length, checksBeforeLeaving);

      await tester.tap(find.byKey(const ValueKey('home-hero-next')));
      await tester.pump();
      expect(tester.widget<HomeBackdrop>(backdropFinder).index, 8);
      await tester.pumpAndSettle();
      expect(inspected.length, checksBeforeLeaving, reason: '恢复后继续切张也不复查资格');
    } finally {
      await tester.pumpWidget(away);
      if (returnImageGate != null && !returnImageGate.isCompleted) {
        returnImageGate.complete();
      }
      await tester.pumpAndSettle();
    }
  });
}
