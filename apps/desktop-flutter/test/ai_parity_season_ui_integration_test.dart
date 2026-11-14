import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_playback.dart';
import 'package:webhtv_pc/services/ai_integration.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/ai_episode_season_service.dart';
import 'package:webhtv_pc/services/ai_season_mapping_service.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

class _SeasonCompletion extends AiCompletionClient {
  _SeasonCompletion(this.response)
    : super(client: MockClient((_) async => http.Response('{}', 200)));
  final Map<String, Object?> response;
  @override
  Future<AiCompletionResult> complete({
    required AiConfig config,
    required String prompt,
    Duration? timeout,
    String task = 'ai',
    AiCancellationToken? cancellationToken,
  }) async => AiCompletionResult(
    ok: true,
    statusCode: 200,
    text: jsonEncode(response),
    message: '',
  );
}

void main() {
  for (final mode in [
    'SINGLE_SEASON',
    'FLAT_BY_COUNTS',
    'EXPLICIT_MAPPING',
    'KEEP_ORIGINAL',
  ]) {
    testWidgets('真实详情季度AI入口 $mode 预览确认落库并文件关闭重开读取', (tester) async {
      tester.view.physicalSize = const Size(1400, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp = Directory.systemTemp.createTempSync('parity-season-ui-');
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/log',
        },
      );
      final vod = Vod(
        vodId: 'v',
        vodName: '迁移剧',
        vodYear: '2024',
        vodPlayFrom: '线路',
        vodPlayUrl: mode == 'FLAT_BY_COUNTS'
            ? r'第1集$https://source.test/e1#花絮$https://source.test/extra#第9集$https://source.test/e9'
            : r'第1集$https://source.test/e1#第2集$https://source.test/e2',
      );
      final response = <String, Object?>{
        'mode': mode,
        'seasonNumber': 1,
        'confidence': .95,
        'summary': '经过类型校验的迁移建议',
        if (mode == 'EXPLICIT_MAPPING')
          'mappings': [
            {'sourceIndex': 0, 'seasonNumber': 1, 'episodeNumber': 1},
            {'sourceIndex': 1, 'seasonNumber': 2, 'episodeNumber': 1},
          ],
      };
      AppState createState() {
        final client = MockClient((request) async {
          final path = request.url.path;
          Object body;
          if (request.url.host == 'source.test') {
            body = {
              'class': [],
              'list': [vod.toJson()],
            };
          } else if (path.endsWith('/search/multi')) {
            body = {
              'results': [
                {
                  'id': 88,
                  'media_type': 'tv',
                  'name': '迁移剧',
                  'first_air_date': '2024-01-01',
                },
              ],
            };
          } else if (path.endsWith('/season/1') || path.endsWith('/season/2')) {
            final season = int.parse(path.split('/').last);
            body = {
              'id': 88,
              'episodes': [
                for (var i = 1; i <= 2; i++)
                  {
                    'id': season * 10 + i,
                    'episode_number': i,
                    'season_number': season,
                    'name': '真实S${season}E$i',
                  },
              ],
            };
          } else if (path.endsWith('/videos')) {
            body = {'results': []};
          } else {
            body = {
              'id': 88,
              'name': '迁移剧',
              'media_type': 'tv',
              'first_air_date': '2024-01-01',
              'number_of_seasons': 2,
              'number_of_episodes': 4,
              'seasons': [
                {'season_number': 1, 'episode_count': 2},
                {'season_number': 2, 'episode_count': 2},
              ],
              'credits': {'cast': [], 'crew': []},
              'aggregate_credits': {'cast': [], 'crew': []},
              'genres': [],
              'images': {'backdrops': [], 'posters': [], 'stills': []},
              'recommendations': {'results': []},
              'similar': {'results': []},
              'videos': {'results': []},
            };
          }
          return http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        return AppState(
          paths: paths,
          log: LogService(),
          httpClient: client,
          aiSeasonClient: _SeasonCompletion(response),
          tmdbService: TmdbService(
            config: () => const TmdbConfig(
              enabled: true,
              apiKey: 'fixture',
              apiBase: 'https://tmdb.test/3',
            ),
            client: client,
          ),
        );
      }

      var state = createState();
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      try {
        await tester.runAsync(() async {
          await state.bootstrap();
          await state.saveTmdbConfig(
            const TmdbConfig(
              enabled: true,
              apiKey: 'fixture',
              apiBase: 'https://tmdb.test/3',
            ),
          );
          await state.saveAiConfig(
            const AiConfig(
              enabled: true,
              apiKey: 'fixture',
              model: 'fixture',
              endpoint: 'https://ai.test/v1',
            ),
          );
          await state.importConfig(
            jsonEncode({
              'name': '迁移源',
              'sites': [
                {
                  'key': 's',
                  'name': '站点',
                  'type': 1,
                  'api': 'https://source.test/api',
                  'searchable': 1,
                },
              ],
            }),
          );
          await state.selectSite(state.siteItems.first.site);
          await state.loadDetail(vod);
          await state.reloadTmdb();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(Brightness.dark),
            home: DetailPage(state: state, vod: vod),
          ),
        );
        await settle();
        expect(state.tmdb.hasMatch, isTrue);
        final flag = state.tmdb.sourceLine!.flagKey;
        final counts = state.tmdb.seasonEpisodeCounts;
        final episodes = [
          for (var i = 0; i < state.tmdb.sourceLine!.episodeNames.length; i++)
            VodEpisode(
              name: state.tmdb.sourceLine!.episodeNames[i],
              url: i < state.tmdb.sourceLine!.episodeUrls.length
                  ? state.tmdb.sourceLine!.episodeUrls[i]
                  : '',
            ),
        ];
        // 真实可见性（已核源码）：站点详情页的季度区是 TmdbDetailView
        // - `tmdb-season-button` 属 TmdbSeasonSelector（站点页/播放器侧），详情页永不渲染；
        // - `tmdb-choose-season` 只在 selectedSeason<0 且季度区可见时出现；
        //   而季度区要求 `seasons.isNotEmpty`，本夹具在未解析出可播放季度时该区直接不渲染，
        //   已绑定季度时又不显示手动入口（单季 chip 条为 SizedBox.shrink）。
        // 两态都属于**产品可见性缺口**：详情页没有常驻的季度/AI 入口。
        // 这里如实断言该事实，不新增无条件入口，也不放宽为“找不到就跳过”。
        expect(find.byKey(const ValueKey('tmdb-season-button')), findsNothing);
        expect(find.byKey(const ValueKey('tmdb-choose-season')), findsNothing);

        // 用同一批生产消费者驱动四 mode：parser → buildSeasonBindings →
        // confirmAiSeasonMapping → bindingsFor / applyAiMappingsToLine / 逐集身份。
        final analysis = parseAiSeasonResponse(
          text: jsonEncode(response),
          episodes: episodes,
          seasonCounts: counts,
        );
        expect(analysis.success, isTrue);
        final proposed = buildSeasonBindings(
          analysis: analysis,
          episodes: episodes,
          seasonCounts: counts,
        );
        final canApply =
            proposed.status == AiSeasonApplyStatus.applied ||
            proposed.status == AiSeasonApplyStatus.partial;
        expect(canApply, isTrue, reason: '四 mode 都必须可确认应用');
        final applied = await state.confirmAiSeasonMapping(
          analysis: analysis,
          vod: vod,
          flagKey: flag,
          episodes: episodes,
          seasonCounts: counts,
          snapshot: seasonBindingsSnapshot(episodes, counts),
        );
        final mappingService = AiSeasonMappingService(
          database: state.database!,
        );
        final readBack = await mappingService.bindingsFor(
          configId: state.tmdbConfigId,
          siteKey: 's',
          vodId: 'v',
          sourceTitle: '迁移剧',
          flagKey: flag,
          episodes: episodes,
          seasonCounts: counts,
        );
        if (mode == 'KEEP_ORIGINAL') {
          // KEEP 的返回状态按服务合同是 applied（“清理完成”），真正的验收点是
          // 该配置/线路/作品的 AI 行被删除、bindingsFor 读回 missing。
          expect(applied!.status, AiSeasonApplyStatus.applied);
          expect(
            state.database!.findAiSeasonMappings(
              configId: state.tmdbConfigId,
              siteKey: 's',
              vodId: 'v',
              sourceTitle: '迁移剧',
              flagKey: flag,
            ),
            isNull,
            reason: 'KEEP_ORIGINAL 必须清除 AI 映射行',
          );
          expect(readBack.status, AiSeasonApplyStatus.missing);
        } else {
          expect(
            applied!.status,
            mode == 'FLAT_BY_COUNTS'
                ? AiSeasonApplyStatus.partial
                : AiSeasonApplyStatus.applied,
          );
          expect(readBack.status, applied.status);
        }
        final rawLine = state.playLinesOf(vod).single;
        if (mode == 'KEEP_ORIGINAL') {
          expect(state.hasAiMappings(vod, rawLine), isFalse);
        } else {
          final row = state.database!.findAiSeasonMappings(
            configId: state.tmdbConfigId,
            siteKey: 's',
            vodId: 'v',
            sourceTitle: '迁移剧',
            flagKey: flag,
          )!;
          expect(
            row['status'],
            mode == 'FLAT_BY_COUNTS' ? 'partial' : 'applied',
          );
          expect(
            jsonDecode(row['skipped_source_indexes'] as String),
            mode == 'FLAT_BY_COUNTS' ? [1, 2] : [],
          );
          final mapped = state.applyAiMappingsToLine(vod, rawLine);
          expect(mapped.episodes.first.url, 'https://source.test/e1');
          expect(mapped.episodes.first.extra['tmdb_episode_number'], 1);
          if (mode == 'EXPLICIT_MAPPING') {
            expect(mapped.episodes.last.extra['tmdb_season_number'], 2);
          }
          // Q04：实际播放身份必须按**每集**映射取季/集，不沿用上一集。
          final baseIdentity = TmdbPlaybackIdentity.of(
            identity: TmdbIdentity.of(TmdbMediaType.tv, 88),
            episode: mapped.episodes.first,
            flagKey: '线路',
            seasonNumber: 1,
            episodeNumber: 1,
          );
          final firstIdentity = aiPlaybackIdentityForEpisode(
            baseIdentity,
            mapped.episodes.first,
            '线路',
          );
          expect(firstIdentity!.episodeNumber, 1);
          if (mode == 'EXPLICIT_MAPPING') {
            final second = aiPlaybackIdentityForEpisode(
              firstIdentity,
              mapped.episodes.last,
              '线路',
            );
            expect(second!.seasonNumber, 2);
            expect(second.episodeNumber, 1);
          }
          if (mode == 'FLAT_BY_COUNTS') {
            // 未映射的集保持 -1：不猜季集，但仍可播。
            final skipped = aiPlaybackIdentityForEpisode(
              firstIdentity,
              mapped.episodes[1],
              '线路',
            );
            expect(skipped!.episodeNumber, -1);
          }
        }
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await tester.pump();
        state.dispose();
        state = createState();
        await tester.runAsync(() async {
          await state.bootstrap();
          await state.loadDetail(vod);
          await state.reloadTmdb();
        });
        final reopened = state.aiMappingsFor(
          vod,
          state.playLinesOf(vod).single,
        );
        expect(
          reopened?.status,
          mode == 'KEEP_ORIGINAL'
              ? AiSeasonApplyStatus.missing
              : mode == 'FLAT_BY_COUNTS'
              ? AiSeasonApplyStatus.partial
              : AiSeasonApplyStatus.applied,
        );
        if (mode == 'FLAT_BY_COUNTS') {
          expect(reopened!.skippedSourceIndexes, [1, 2]);
        }
        if (mode == 'EXPLICIT_MAPPING') {
          expect(reopened!.bindings.last.seasonNumber, 2);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        state.dispose();
        temp.deleteSync(recursive: true);
      }
    });
  }
}
