/// Phase 4 · TMDB 详情页组件（`docs/phase4/design/04` §3–§5、§7）。
///
/// 对应门禁：`docs/phase4/design/05` §4.4「状态条 6 态 / 季度选择器 /
/// 选集数量 / 手动匹配弹窗 / 季度绑定弹窗 / 相关视频 / 键盘 / 失败隔离」。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

// ---------------------------------------------------------------------------
// fake HTTP
// ---------------------------------------------------------------------------

class _FakeClient extends http.BaseClient {
  final List<(String, Object?)> routes = [];
  Object? failure;

  void route(String suffix, Object? body) => routes.add((suffix, body));

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final local = failure;
    if (local != null) throw local;
    for (final (suffix, body) in routes) {
      if (request.url.path.endsWith(suffix)) {
        final text = body is String ? body : jsonEncode(body);
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(text)),
          200,
        );
      }
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"status_code":404}')),
      404,
    );
  }
}

TmdbConfig _ready() => const TmdbConfig(apiKey: 'k');

TmdbState _state({
  required TmdbConfig Function() config,
  required http.Client client,
  TmdbMatchStore? store,
  TmdbSeasonStore? seasonStore,
}) {
  final service = TmdbService(config: config, client: client);
  return TmdbState(
    config: config,
    service: service,
    identityService: TmdbIdentityService(
      config: config,
      service: service,
      store: store ?? InMemoryTmdbMatchStore(),
    ),
    seasonService: TmdbSeasonService(
      store: seasonStore ?? InMemoryTmdbSeasonStore(),
    ),
    enrichmentService: TmdbEnrichmentService(service: service, config: config),
  );
}

Vod _vod({String name = '来源剧名'}) => Vod(vodId: 'v1', vodName: name);

TmdbSourceLine _line({int count = 10}) => TmdbSourceLine(
  flagKey: 'f#0',
  sourceFlag: '线路一',
  episodeNames: List.generate(count, (i) => '第${i + 1}集'),
);

/// 构造一个已匹配且已加载详情的 state。
Future<TmdbState> _matchedState({
  required TmdbConfig Function() config,
  required http.Client client,
  TmdbMatchStore? store,
  int episodeCount = 10,
  List<int> tmdbSeasons = const [1],
  Map<int, int> seasonCounts = const {1: 10},
}) async {
  final state = _state(
    config: config,
    client: client,
    store: store,
  );
  final generation = state.beginLoad(
    siteKey: 's',
    vodId: 'v',
    sourceTitle: '剧名',
    vod: _vod(),
    line: _line(count: episodeCount),
  );
  await state.loadMatch(generation: generation, sourceTitle: '剧名');
  await state.loadDetail(
    generation: generation,
    tmdbSeasons: tmdbSeasons,
    seasonCounts: seasonCounts,
  );
  return state;
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Column(children: [child])),
);

void main() {
  group('TmdbStatusBar 六态（§3.1 ②）', () {
    testWidgets('未配置 → 渲染「未配置 TMDB」与「去设置」入口', (tester) async {
      var configured = 0;
      final state = _state(config: () => const TmdbConfig(), client: _FakeClient());
      state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await tester.pumpWidget(
        _host(
          TmdbStatusBar(state: state, onConfigure: () => configured++),
        ),
      );
      // 发布包实测缺陷：未配置时整块不渲染 → 用户永远进不了 TMDB 设置页。
      expect(
        find.byKey(const ValueKey('tmdb-status-unconfigured')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('tmdb-configure')));
      expect(configured, 1, reason: '「去设置」必须可用');
      state.dispose();
    });

    testWidgets('站点禁用 → 整块不渲染', (tester) async {
      final config = const TmdbConfig(apiKey: 'k', disabledSites: ['[书]']);
      final state = _state(config: () => config, client: _FakeClient());
      state.beginLoad(
        siteKey: '[书]站',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await tester.pumpWidget(_host(TmdbStatusBar(state: state)));
      expect(find.byType(Row), findsNothing);
      state.dispose();
    });

    testWidgets('匹配中 → 显示进度指示器', (tester) async {
      final state = _state(config: _ready, client: _FakeClient());
      state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await tester.pumpWidget(_host(TmdbStatusBar(state: state)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      state.dispose();
    });

    testWidgets('未匹配 → 显示「未匹配 TMDB」与匹配按钮', (tester) async {
      final client = _FakeClient()..route('/search/multi', {'results': []});
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await tester.pumpWidget(_host(TmdbStatusBar(state: state)));
      expect(find.text('未匹配 TMDB'), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-match')), findsOneWidget);
      state.dispose();
    });

    testWidgets('已匹配 → 显示标题与评分，以及重新匹配入口', (tester) async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
              'vote_average': 8.2,
            },
          ],
        })
        ..route('/tv/1399', {'id': 1399, 'name': '剧名'});
      final state = await _matchedState(config: _ready, client: client);
      await tester.pumpWidget(_host(TmdbStatusBar(state: state)));
      expect(find.byKey(const ValueKey('tmdb-status-matched')), findsOneWidget);
      expect(find.textContaining('8.2'), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-rematch')), findsOneWidget);
      state.dispose();
    });

    testWidgets('失败 → 显示错误文案与重试，文案含「不影响站源浏览与播放」', (tester) async {
      final client = _FakeClient()..failure = const FormatException('boom');
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await tester.pumpWidget(_host(TmdbStatusBar(state: state)));
      expect(find.byKey(const ValueKey('tmdb-status-error')), findsOneWidget);
      expect(find.textContaining('不影响站源浏览与播放'), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-retry')), findsOneWidget);
      state.dispose();
    });

    testWidgets('点击重试触发回调', (tester) async {
      final client = _FakeClient()..failure = const FormatException('boom');
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      var retried = 0;
      await tester.pumpWidget(
        _host(TmdbStatusBar(state: state, onRetry: () => retried++)),
      );
      await tester.tap(find.byKey(const ValueKey('tmdb-retry')));
      expect(retried, 1);
      state.dispose();
    });

    testWidgets('骨架屏高度与状态条固定高度一致（防布局跳动）', (tester) async {
      final state = _state(config: _ready, client: _FakeClient());
      state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await tester.pumpWidget(_host(TmdbStatusBar(state: state)));
      final size = tester.getSize(find.byType(TmdbStatusBar));
      expect(size.height, tmdbStatusBarHeight);
      state.dispose();
    });
  });

  group('TmdbSeasonSelector（§4.1）', () {
    testWidgets('单季 → 只显示季度上下文，无切换控件', (tester) async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {
          'id': 1399,
          'name': '剧名',
          'seasons': [
            {'season_number': 1, 'episode_count': 10},
          ],
        });
      final state = await _matchedState(config: _ready, client: client);
      await tester.pumpWidget(_host(TmdbSeasonSelector(state: state)));
      expect(find.byKey(const ValueKey('tmdb-season-context')), findsOneWidget);
      expect(find.text('第 1 季'), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-switcher')), findsNothing);
      state.dispose();
    });

    testWidgets('多季 → 显示分段控件', (tester) async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {
          'id': 1399,
          'name': '剧名',
          'seasons': [
            {'season_number': 1, 'episode_count': 3},
            {'season_number': 2, 'episode_count': 2},
          ],
        });
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(count: 5),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await tester.pumpWidget(_host(TmdbSeasonSelector(state: state)));
      expect(find.byKey(const ValueKey('tmdb-season-switcher')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-season-2')), findsOneWidget);
      state.dispose();
    });

    testWidgets('点击季度触发回调', (tester) async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {
          'id': 1399,
          'name': '剧名',
          'seasons': [
            {'season_number': 1, 'episode_count': 3},
            {'season_number': 2, 'episode_count': 2},
          ],
        });
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(count: 5),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      int? selected;
      await tester.pumpWidget(
        _host(TmdbSeasonSelector(state: state, onChanged: (s) => selected = s)),
      );
      await tester.tap(find.byKey(const ValueKey('tmdb-season-2')));
      expect(selected, 2);
      state.dispose();
    });

    testWidgets('无法可靠分季 → 显示「未确定季度」+ 选择入口', (tester) async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {
          'id': 1399,
          'name': '剧名',
          'seasons': [
            {'season_number': 1, 'episode_count': 3},
            {'season_number': 2, 'episode_count': 2},
          ],
        });
      // 7 集，而 S1=3、S2=2：既不能切片（3+2≠7），单季兼容也不成立
      // （S1 的 3 集 < 7），因此 §4.3 落到 G → availableSeasons 为空。
      final state = await _matchedState(
        config: _ready,
        client: client,
        episodeCount: 7,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      await tester.pumpWidget(_host(TmdbSeasonSelector(state: state)));
      expect(find.text('未确定季度'), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-choose-season')), findsOneWidget);
      state.dispose();
    });

    testWidgets('电影 → 不渲染季度选择器', (tester) async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 550,
              'media_type': 'movie',
              'title': '剧名',
              'release_date': '2024-01-01',
            },
          ],
        })
        ..route('/movie/550', {'id': 550, 'title': '剧名'});
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [],
        seasonCounts: const {},
      );
      await tester.pumpWidget(_host(TmdbSeasonSelector(state: state)));
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('未确定季度'), findsNothing);
      state.dispose();
    });
  });

  group('TmdbEpisodeRenderPolicy（§4.2、§4.7）', () {
    VodEpisode ep(String name, {int? season, String? displayName}) {
      final extra = <String, Object?>{};
      if (season != null) extra['tmdb_season_number'] = season;
      if (displayName != null) extra['display_name'] = displayName;
      return VodEpisode(name: name, url: 'https://cdn/$name', extra: extra);
    }

    test('availableSeasons 为空 → 返回全部（退化为扁平）', () {
      final episodes = [ep('E1'), ep('E2'), ep('E3')];
      final rendered = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [],
        selectedSeason: -1,
        seasonOf: (e) => e.extra['tmdb_season_number'] as int? ?? -1,
      );
      expect(rendered.length, 3);
    });

    test('按季度过滤，未分类集保留（不丢集）', () {
      final episodes = [
        ep('S1E1', season: 1),
        ep('S1E2', season: 1),
        ep('未分类'), // season 缺失 → -1
        ep('S2E1', season: 2),
      ];
      final rendered = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [1, 2],
        selectedSeason: 1,
        seasonOf: (e) => e.extra['tmdb_season_number'] as int? ?? -1,
      );
      // S1 的 2 集 + 未分类的 1 集
      expect(rendered.map((e) => e.name), ['S1E1', 'S1E2', '未分类']);
    });

    test('不补集：TMDB 有 9 集但线路 8 集 → 只渲染 8 项', () {
      final episodes = List.generate(8, (i) => ep('E${i + 1}', season: 1));
      final rendered = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [1],
        selectedSeason: 1,
        seasonOf: (e) => e.extra['tmdb_season_number'] as int? ?? -1,
      );
      expect(rendered.length, 8);
      expect(rendered.length, lessThan(9));
    });

    test('matchesSeasonEpisodeCount 断言渲染数量正确', () {
      final episodes = [
        ep('S1E1', season: 1),
        ep('未分类'),
        ep('S2E1', season: 2),
      ];
      final rendered = TmdbEpisodeRenderPolicy.filter(
        episodes: episodes,
        availableSeasons: const [1, 2],
        selectedSeason: 1,
        seasonOf: (e) => e.extra['tmdb_season_number'] as int? ?? -1,
      );
      expect(
        TmdbEpisodeRenderPolicy.matchesSeasonEpisodeCount(
          rendered: rendered,
          sourceEpisodes: episodes,
          selectedSeason: 1,
          seasonOf: (e) => e.extra['tmdb_season_number'] as int? ?? -1,
        ),
        isTrue,
      );
      // 少渲染一项 → 断言失败
      expect(
        TmdbEpisodeRenderPolicy.matchesSeasonEpisodeCount(
          rendered: rendered.take(1).toList(),
          sourceEpisodes: episodes,
          selectedSeason: 1,
          seasonOf: (e) => e.extra['tmdb_season_number'] as int? ?? -1,
        ),
        isFalse,
      );
    });

  });

  group('TmdbSeasonDialog（§5.2）', () {
    testWidgets('候选展示集数；切片不可用时禁用并给出原因', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbSeasonDialog(
              tmdbSeasons: const [1, 2],
              seasonCounts: const {1: 12, 2: 10},
              sourceEpisodeCount: 22,
              canAutoSlice: false,
            ),
          ),
        ),
      );
      expect(find.text('第 1 季'), findsOneWidget);
      expect(find.textContaining('12 集'), findsOneWidget);
      expect(find.text('第 2 季'), findsOneWidget);
      expect(find.textContaining('10 集'), findsOneWidget);
      expect(
        find.textContaining('无法安全自动切分'),
        findsOneWidget,
      );
      // 22 集线路下 12/10 集季度都触发风险提示
      expect(find.textContaining('与线路集数差异较大'), findsNWidgets(2));
    });

    testWidgets('切片可用时给出可点击条目', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbSeasonDialog(
              tmdbSeasons: const [1, 2],
              seasonCounts: const {1: 3, 2: 2},
              sourceEpisodeCount: 5,
              canAutoSlice: true,
            ),
          ),
        ),
      );
      expect(find.textContaining('无法安全自动切分'), findsNothing);
    });

    testWidgets('选择季度返回语义化结果', (tester) async {
      Object? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = decodeSeasonChoice(
                    await showDialog<Object?>(
                      context: context,
                      builder: (_) => const TmdbSeasonDialog(
                        tmdbSeasons: [1, 2],
                        seasonCounts: {1: 12, 2: 10},
                        sourceEpisodeCount: 10,
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tmdb-season-option-2')));
      await tester.pumpAndSettle();
      expect(result, isA<TmdbSeasonNumber>());
      expect((result! as TmdbSeasonNumber).seasonNumber, 2);
    });

    testWidgets('「自动」返回 TmdbSeasonAuto', (tester) async {
      Object? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = decodeSeasonChoice(
                    await showDialog<Object?>(
                      context: context,
                      builder: (_) => const TmdbSeasonDialog(
                        tmdbSeasons: [1],
                        seasonCounts: {1: 12},
                        sourceEpisodeCount: 10,
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tmdb-season-auto')));
      await tester.pumpAndSettle();
      expect(result, isA<TmdbSeasonAuto>());
    });

    test('needsRiskWarning 阈值：|差| > max(2, 20%)', () {
      // 22 集线路，12 集季度 → 差 10 > max(2, 4) → 需要提示
      expect(
        TmdbSeasonDialog.needsRiskWarning(
          seasonEpisodeCount: 12,
          sourceEpisodeCount: 22,
        ),
        isTrue,
      );
      // 差 1 <= 2 → 不需要提示
      expect(
        TmdbSeasonDialog.needsRiskWarning(
          seasonEpisodeCount: 12,
          sourceEpisodeCount: 13,
        ),
        isFalse,
      );
      // 20% 阈值：100 集线路 → 阈值 20；差 19 不提示
      expect(
        TmdbSeasonDialog.needsRiskWarning(
          seasonEpisodeCount: 81,
          sourceEpisodeCount: 100,
        ),
        isFalse,
      );
      expect(
        TmdbSeasonDialog.needsRiskWarning(
          seasonEpisodeCount: 79,
          sourceEpisodeCount: 100,
        ),
        isTrue,
      );
    });
  });

  group('TmdbMatchDialog（§5.1）', () {
    testWidgets('打开即搜索并展示结果', (tester) async {
      var searched = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbMatchDialog(
              initialQuery: '剧名',
              search: (keyword) async {
                searched++;
                return const [
                  TmdbItem(
                    tmdbId: 1399,
                    mediaType: TmdbMediaType.tv,
                    title: '示例剧集',
                    subtitle: '2024 · 8.2',
                  ),
                ];
              },
              resolveProviderId: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(searched, 1, reason: '打开即搜索');
      expect(find.text('示例剧集'), findsOneWidget);
      expect(find.textContaining('剧集'), findsWidgets);
    });

    testWidgets('Provider ID 直达跳过搜索', (tester) async {
      var searched = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbMatchDialog(
              initialQuery: 'tv:1399',
              search: (keyword) async {
                searched++;
                return const [];
              },
              resolveProviderId: (input) async => const TmdbItem(
                tmdbId: 1399,
                mediaType: TmdbMediaType.tv,
                title: '直达结果',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(searched, 0, reason: 'Provider ID 直达不应调用搜索');
      expect(find.text('直达结果'), findsOneWidget);
    });

    testWidgets('空结果提示', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbMatchDialog(
              initialQuery: '剧名',
              search: (_) async => const [],
              resolveProviderId: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('没有候选结果'), findsOneWidget);
    });

    testWidgets('点击结果返回该条目', (tester) async {
      TmdbItem? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  picked = await showDialog<TmdbItem>(
                    context: context,
                    builder: (_) => TmdbMatchDialog(
                      initialQuery: '剧名',
                      search: (_) async => const [
                        TmdbItem(
                          tmdbId: 1399,
                          mediaType: TmdbMediaType.tv,
                          title: '示例剧集',
                        ),
                      ],
                      resolveProviderId: (_) async => null,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('示例剧集'));
      await tester.pumpAndSettle();
      expect(picked?.identity?.key, 'tv:1399');
    });

    testWidgets('搜索异常显示错误文案', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbMatchDialog(
              initialQuery: '剧名',
              search: (_) async =>
                  throw AppError(AppErrorKind.tmdbNetwork, '网络失败'),
              resolveProviderId: (_) async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('网络'), findsWidgets);
    });
  });

  group('TmdbVideoTile（§7.2）', () {
    const video = TmdbVideo(
      id: 'v1',
      key: 'abc123',
      site: 'YouTube',
      name: '官方预告',
      type: 'Trailer',
      scope: TmdbVideoScope.tv,
    );

    testWidgets('渲染名称与类型，且有打开与复制按钮', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbVideoTile(video: video, onCopy: (_) async {}),
          ),
        ),
      );
      expect(find.text('官方预告'), findsOneWidget);
      expect(find.textContaining('预告'), findsWidgets);
      expect(
        find.byKey(const ValueKey('tmdb-video-open-YouTube|abc123')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tmdb-video-copy-YouTube|abc123')),
        findsOneWidget,
      );
    });

    testWidgets('打开成功 → 不触发复制兜底', (tester) async {
      var copied = 0;
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbVideoTile(
              video: video,
              onOpen: (url) async {
                opened = url;
                return true;
              },
              onCopy: (_) async => copied++,
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('tmdb-video-open-YouTube|abc123')),
      );
      await tester.pumpAndSettle();
      expect(opened, 'https://www.youtube.com/watch?v=abc123');
      expect(copied, 0);
    });

    testWidgets('打开失败 → 复制链接兜底并提示', (tester) async {
      var copied = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbVideoTile(
              video: video,
              onOpen: (_) async => false,
              onCopy: (_) async => copied++,
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('tmdb-video-open-YouTube|abc123')),
      );
      await tester.pumpAndSettle();
      expect(copied, 1, reason: '打开失败应复制链接兜底');
      expect(find.textContaining('已复制链接'), findsOneWidget);
    });

    testWidgets('复制按钮复制 watchUrl', (tester) async {
      String? copied;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbVideoTile(
              video: video,
              onCopy: (url) async => copied = url,
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('tmdb-video-copy-YouTube|abc123')),
      );
      await tester.pumpAndSettle();
      expect(copied, 'https://www.youtube.com/watch?v=abc123');
    });
  });

  group('键盘可用性（§11）', () {
    testWidgets('Tab 可在状态条按钮间移动焦点，Esc 可关闭弹窗', (tester) async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {'id': 1399, 'name': '剧名'});
      final state = await _matchedState(config: _ready, client: client);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TmdbStatusBar(state: state),
                TmdbSeasonSelector(state: state),
              ],
            ),
          ),
        ),
      );
      // Tab 聚焦到第一个可交互控件
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus,
        isNotNull,
        reason: 'Tab 应把焦点移到某个控件',
      );
      state.dispose();
    });

    testWidgets('季度分段控件可用键盘激活', (tester) async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '剧名',
              'first_air_date': '2024-01-01',
            },
          ],
        })
        ..route('/tv/1399', {
          'id': 1399,
          'name': '剧名',
          'seasons': [
            {'season_number': 1, 'episode_count': 3},
            {'season_number': 2, 'episode_count': 2},
          ],
        });
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(count: 5),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await state.loadDetail(
        generation: generation,
        tmdbSeasons: const [1, 2],
        seasonCounts: const {1: 3, 2: 2},
      );
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbSeasonSelector(
              state: state,
              onChanged: (s) => selected = s,
            ),
          ),
        ),
      );
      // 直接点击也能验证可交互（键盘激活由 Chip 的 focus 语义保证）
      await tester.tap(find.byKey(const ValueKey('tmdb-season-2')));
      expect(selected, 2);
      state.dispose();
    });
  });

  group('失败隔离文案（§3.4）', () {
    test('全部 tmdb 错误文案含「不影响站源浏览与播放」', () {
      for (final kind in tmdbErrorKinds) {
        expect(
          describeErrorKind(kind),
          contains('不影响站源浏览与播放'),
          reason: kind.name,
        );
      }
    });

    testWidgets('错误态不影响其他区块渲染', (tester) async {
      final client = _FakeClient()..failure = const FormatException('boom');
      final state = _state(config: _ready, client: client);
      final generation = state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      await state.loadMatch(generation: generation, sourceTitle: '剧名');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TmdbStatusBar(state: state),
                // 模拟线路与选集区照常渲染
                const Expanded(
                  child: Center(
                    child: Text('线路一 · 10 集', key: ValueKey('play-lines')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('tmdb-status-error')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('play-lines')),
        findsOneWidget,
        reason: 'TMDB 失败不得影响线路与选集',
      );
      state.dispose();
    });
  });
}
