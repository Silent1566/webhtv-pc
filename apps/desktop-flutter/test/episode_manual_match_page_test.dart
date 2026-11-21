/// 集级手动匹配的端到端验收（`docs/superpowers/specs/2026-11-21-episode-manual-match-design.md`）：
/// 长按卡片 → 菜单 → 匹配弹窗 → 顺延落库 → 卡面生效 → 重进详情页仍生效 → 恢复自动。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/detail_test_seams.dart';

/// 一条线路 7 集（S02E01..S02E07），TMDB 第 2 季有 12 集。
class _Client extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    Object body;
    if (path.endsWith('/search/multi')) {
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
          {'season_number': 2, 'episode_count': 12},
        ],
      };
    } else if (path.endsWith('/season/2')) {
      body = {
        'id': 2,
        'season_number': 2,
        'episodes': [
          for (var i = 1; i <= 12; i++)
            {
              'episode_number': i,
              'season_number': 2,
              'name': '元数据$i',
              'air_date': '2025-01-01',
              'runtime': 42,
            },
        ],
      };
    } else if (path.contains('/episode/')) {
      body = {
        'id': 207,
        'season_number': 2,
        'episode_number': 3,
        'name': '远端第三集',
        'overview': '远端完整详情简介',
        'runtime': 42,
        'credits': {'cast': [], 'crew': []},
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

class _State extends AppState with ExternalMetaOff {
  _State({required super.paths, required this.client, required this.site})
    : super(log: MemoryOnlyLogService()) {
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
    String? preferredParseName,
    SiteService? serviceOverride,
  }) async => throw AppError(AppErrorKind.siteCancelled, '测试不播放');
}

Vod _vod() => Vod(
  vodId: 'owned',
  vodName: '本页剧',
  vodPlayFrom: '原线路',
  vodPlayUrl: [
    for (var i = 1; i <= 7; i++)
      'S02E0$i 原名保留\$http://example.invalid/e$i',
  ].join('#'),
);

void main() {
  late Directory temp;
  late _Client client;
  final states = <_State>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('episode-manual-match');
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

  Future<_State> stateFor(Vod vod, {_Client? override}) async {
    final state = _State(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
      client: override ?? client,
      site: Site(
        key: 'site',
        name: '本站',
        type: 1,
        api: 'http://example.invalid',
      ),
    );
    states.add(state);
    await state.bootstrap();
    await state.tmdb.loadForVod(vod, siteKey: 'site');
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
        await tester.pump(const Duration(milliseconds: 50));
        break;
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pump();
    }
    expect(target, findsOneWidget);
  }

  Finder card(int index) =>
      find.byKey(ValueKey('tmdb-episode-card-原线路-$index'));

  Future<void> openMenu(WidgetTester tester, int index) async {
    final target = card(index);
    await reveal(tester, target);
    await tester.longPress(target);
    await tester.pumpAndSettle();
  }

  testWidgets('长按→手动匹配第 1 张卡到 S2E3→从此集起顺延，后续卡逐集 +1', (
    tester,
  ) async {
    final vod = _vod();
    // 真实 IO（建库/读盘）必须走 runAsync：testWidgets 默认是 fake async。
    final state = (await tester.runAsync(() => stateFor(vod)))!;
    await pumpPage(tester, DetailPage(state: state, vod: vod));
    // 卡片在长页面的下方：先滚到可见位置，ListView 才会把它们建出来。
    await reveal(tester, card(0));

    // 匹配前：第 1 张卡是自动的 S2E1。
    expect(
      find.descendant(of: card(0), matching: find.text('S2E1')),
      findsOneWidget,
    );

    await openMenu(tester, 0);
    await tester.tap(find.text('手动匹配…'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('episode-match-dialog')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('episode-match-row-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从此集起顺延'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: card(0), matching: find.text('S2E3')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card(1), matching: find.text('S2E4')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card(6), matching: find.text('S2E9')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('tmdb-episode-match-summary')),
      findsOneWidget,
    );
  });

  testWidgets('匹配第 3 集并顺延：前两集仍保留刮削元数据（用户报的丢刮削）', (tester) async {
    final vod = _vod();
    final state = (await tester.runAsync(() => stateFor(vod)))!;
    await pumpPage(tester, DetailPage(state: state, vod: vod));
    await reveal(tester, card(0));
    expect(
      find.descendant(of: card(0), matching: find.text('E1 元数据1')),
      findsOneWidget,
      reason: '匹配前前两集本来就是自动刮削',
    );

    await openMenu(tester, 2);
    await tester.tap(find.text('手动匹配…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('episode-match-row-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从此集起顺延'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: card(0), matching: find.text('E1 元数据1')),
      findsOneWidget,
      reason: '未被锚点覆盖的第 1 集必须继续用自动刮削，不能退回源名',
    );
    expect(
      find.descendant(of: card(1), matching: find.text('E2 元数据2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card(2), matching: find.text('E3 元数据3')),
      findsOneWidget,
    );
  });

  testWidgets('恢复自动匹配：卡面回到自动集号，摘要行消失', (tester) async {
    final vod = _vod();
    final state = (await tester.runAsync(() => stateFor(vod)))!;
    await pumpPage(tester, DetailPage(state: state, vod: vod));

    await openMenu(tester, 0);
    await tester.tap(find.text('手动匹配…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('episode-match-row-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅此一集'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: card(0), matching: find.text('S2E5')),
      findsOneWidget,
    );
    // 仅此一集：后面仍是自动号。
    expect(
      find.descendant(of: card(1), matching: find.text('S2E2')),
      findsOneWidget,
    );

    await openMenu(tester, 0);
    await tester.tap(find.text('恢复自动匹配'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: card(0), matching: find.text('S2E1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('tmdb-episode-match-summary')),
      findsNothing,
    );
  });

  testWidgets('落库后重进详情页仍生效（新 AppState 从库里读回并铺开）', (tester) async {
    final vod = _vod();
    final first = (await tester.runAsync(() => stateFor(vod)))!;
    final line = first.playLinesOf(vod).first;
    await tester.runAsync(
      () => first.matchEpisodeManually(
        vod: vod,
        line: line,
        sourceIndex: 0,
        sourceName: line.episodes.first.name,
        seasonNumber: 2,
        episodeNumber: 3,
        siteKey: 'site',
      ),
    );
    first.dispose();
    states.remove(first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );

    final second = (await tester.runAsync(() => stateFor(vod)))!;
    await tester.runAsync(
      () => second.refreshManualEpisodeMatches(vod, siteKey: 'site'),
    );
    final reloaded = second.playLinesOf(vod).first;
    expect(second.manualEpisodeAnchorsFor(vod, reloaded).length, 1);
    final applied = second.applyEpisodeBindingsToLine(vod, reloaded);
    expect(applied.episodes[0].extra['tmdb_episode_number'], 3);
    expect(applied.episodes[1].extra['tmdb_episode_number'], 4);
  });
}
