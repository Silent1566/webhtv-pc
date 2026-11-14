/// Task5 · AI 季集完整映射应用、持久化与确认快照（安卓合同对照）。
///
/// 对照源：`AiEpisodeSeasonService`、`EpisodeSeasonPolicy`、`EpisodeSeasonSnapshot`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/ai_episode_season_service.dart';
import 'package:webhtv_pc/services/ai_season_mapping_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';

/// 测试替身：记录请求、支持取消、可选择挂起（模拟在途请求）。
class CancelAwareCompletionClient extends AiCompletionClient {
  CancelAwareCompletionClient({this.gate})
    : super(client: MockClient((request) async => http.Response('{}', 200)));

  final Future<void>? gate;
  final List<String> sentBodies = [];
  bool receivedCancellation = false;

  @override
  Future<AiCompletionResult> complete({
    required AiConfig config,
    required String prompt,
    Duration? timeout,
    String task = 'ai',
    AiCancellationToken? cancellationToken,
  }) async {
    sentBodies.add(prompt);
    if (cancellationToken != null) {
      receivedCancellation = true;
      if (cancellationToken.isCancelled) return _cancelledResult;
      if (gate != null) {
        await Future.any([gate!, cancellationToken.whenCancelled]);
      }
      if (cancellationToken.isCancelled) return _cancelledResult;
    } else if (gate != null) {
      await gate;
    }
    return const AiCompletionResult(
      ok: false,
      statusCode: 0,
      text: '',
      message: '网络错误，请检查网络与端点',
    );
  }

  static const AiCompletionResult _cancelledResult = AiCompletionResult(
    ok: false,
    statusCode: 0,
    text: '',
    message: '请求已取消',
  );
}

void main() {
  VodEpisode episodeOf(int number, {String? name}) =>
      VodEpisode(name: name ?? '第$number集', url: 'http://x/e$number');

  List<VodEpisode> episodesOf(List<int> numbers) =>
      [for (final n in numbers) episodeOf(n)];

  const seasonCounts = {1: 2, 2: 3, 0: 1};

  group('真实 FLAT 响应到逐集应用（run 2 回归）', () {
    const config = AiConfig(
      enabled: true,
      endpoint: 'http://fixture.test/v1',
      apiKey: 'fixture',
      model: 'fixture',
    );

    Future<AiSeasonAnalysis> analyzeFlat(
      List<VodEpisode> episodes,
      Map<int, int> counts,
    ) async {
      final client = AiCompletionClient(
        client: MockClient((request) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'mode': 'FLAT_BY_COUNTS',
                    'confidence': 0.9,
                    'mappings': <Object?>[],
                  }),
                },
              },
            ],
          }),
          200,
        )),
      );
      final service = AiEpisodeSeasonService(config: config, client: client);
      try {
        return await service.analyze(
          title: '剧', flagName: '线路', episodes: episodes, seasonCounts: counts,
        );
      } finally {
        service.dispose();
        client.close();
      }
    }

    test('analyze→parse→persist 缺号/重复/越界允许 partial，season0 不参与累计', () async {
      final episodes = [
        episodeOf(1),
        VodEpisode(name: '无编号', url: 'http://x/unparsed'),
        episodeOf(3),
        episodeOf(3),
        episodeOf(99),
      ];
      const counts = {0: 8, 1: 2, 2: 3};
      final analysis = await analyzeFlat(episodes, counts);
      expect(analysis.success, isTrue);
      expect(analysis.reason, AiSeasonFailure.none);
      final db = AppDatabase.inMemory();
      try {
        final result = await AiSeasonMappingService(database: db).confirmAndPersist(
          siteKey: 's', vodId: 'v', sourceTitle: '剧', flagKey: 'f',
          analysis: analysis, episodes: episodes, seasonCounts: counts,
          recognitionSnapshot: seasonBindingsSnapshot(episodes, counts),
        );
        expect(result.status, AiSeasonApplyStatus.partial);
        expect(result.skippedSourceIndexes, [1, 4]);
        expect(result.bindings.map((b) => '${b.sourceIndex}:${b.seasonNumber}:${b.episodeNumber}'),
          ['0:1:1', '2:2:1', '3:2:1']);
        expect(db.count('ai_season_episode_mappings'), 1);
      } finally {
        db.dispose();
      }
    });

    for (final unknownCount in [0, -1]) {
      test('R1 count=$unknownCount：真实 parser→apply 拒绝源[3]并保留旧行', () async {
        final episodes = episodesOf([3]);
        final counts = {1: 2, 2: unknownCount, 3: 2};
        final db = AppDatabase.inMemory();
        try {
          final service = AiSeasonMappingService(database: db);
          final snapshot = seasonBindingsSnapshot(episodes, counts);
          final previous = await service.confirmAndPersist(
            siteKey: 's', vodId: 'v', sourceTitle: '剧', flagKey: 'f',
            tmdbId: 42, mediaType: 'tv',
            analysis: AiSeasonAnalysis(
              success: true, reason: AiSeasonFailure.none,
              mode: AiSeasonMode.explicitMapping, confidence: 0.95,
              mappings: const [
                AiEpisodeMapping(sourceIndex: 0, seasonNumber: 3, episodeNumber: 2),
              ],
            ),
            episodes: episodes, seasonCounts: counts,
            recognitionSnapshot: snapshot,
          );
          expect(previous.status, AiSeasonApplyStatus.applied);
          final oldRow = Map<String, Object?>.from(db.findAiSeasonMappings(
            configId: 0, siteKey: 's', vodId: 'v', sourceTitle: '剧', flagKey: 'f',
          )!);
          final analysis = await analyzeFlat(episodes, counts);
          final rejected = await service.confirmAndPersist(
            siteKey: 's', vodId: 'v', sourceTitle: '剧', flagKey: 'f',
            analysis: analysis, episodes: episodes, seasonCounts: counts,
            recognitionSnapshot: snapshot,
          );
          expect(analysis.success, isFalse);
          expect(analysis.reason, AiSeasonFailure.unsafeFlatMapping);
          expect(rejected.status, AiSeasonApplyStatus.rejected);
          expect(rejected.bindings, isEmpty);
          expect(rejected.skippedSourceIndexes, isEmpty);
          expect(rejected.mappedCount, 0);
          expect(db.findAiSeasonMappings(
            configId: 0, siteKey: 's', vodId: 'v', sourceTitle: '剧', flagKey: 'f',
          ), equals(oldRow), reason: '拒绝不能覆盖旧映射、身份、快照或时间戳');
          final retained = await service.bindingsFor(
            siteKey: 's', vodId: 'v', sourceTitle: '剧', flagKey: 'f',
            episodes: episodes, seasonCounts: counts,
          );
          expect(retained.status, AiSeasonApplyStatus.applied);
          expect(retained.skippedSourceIndexes, isEmpty);
          expect(retained.bindings.map((b) => b.toJson()), [
            {'sourceIndex': 0, 'seasonNumber': 3, 'episodeNumber': 2},
          ]);
        } finally {
          db.dispose();
        }
      });

      test('R1 count=$unknownCount：真实 parser→apply 源[1,3]只映S1E1并skip源3', () async {
        final episodes = episodesOf([1, 3]);
        final counts = {1: 2, 2: unknownCount, 3: 2};
        final analysis = await analyzeFlat(episodes, counts);
        expect(analysis.success, isTrue);
        expect(analysis.reason, AiSeasonFailure.none);
        final db = AppDatabase.inMemory();
        try {
          final service = AiSeasonMappingService(database: db);
          final snapshot = seasonBindingsSnapshot(episodes, counts);
          final result = await service.confirmAndPersist(
            siteKey: 's', vodId: 'v', sourceTitle: '剧', flagKey: 'f',
            tmdbId: 42, mediaType: 'tv',
            analysis: analysis, episodes: episodes, seasonCounts: counts,
            recognitionSnapshot: snapshot,
          );
          expect(result.status, AiSeasonApplyStatus.partial);
          expect(result.skippedSourceIndexes, [1]);
          expect(result.mappedCount, 1);
          expect(result.bindings.map((b) => b.toJson()), [
            {'sourceIndex': 0, 'seasonNumber': 1, 'episodeNumber': 1},
          ]);
          final row = db.findAiSeasonMappings(
            configId: 0, siteKey: 's', vodId: 'v', sourceTitle: '剧', flagKey: 'f',
          )!;
          expect(row['snapshot'], snapshot);
          expect(row['status'], 'partial');
          expect(jsonDecode(row['skipped_source_indexes'] as String), [1]);
          expect(jsonDecode(row['mappings'] as String), [
            {'sourceIndex': 0, 'seasonNumber': 1, 'episodeNumber': 1},
          ]);
          final loaded = await service.bindingsFor(
            siteKey: 's', vodId: 'v', sourceTitle: '剧', flagKey: 'f',
            episodes: episodes, seasonCounts: counts,
          );
          expect(loaded.status, AiSeasonApplyStatus.partial);
          expect(loaded.skippedSourceIndexes, [1]);
          expect(loaded.bindings.map((b) => b.toJson()), [
            {'sourceIndex': 0, 'seasonNumber': 1, 'episodeNumber': 1},
          ]);
        } finally {
          db.dispose();
        }
      });
    }
    test('analyze→parse 只有 season0 时拒绝 FLAT，不把特别篇当普通季', () async {
      final analysis = await analyzeFlat(episodesOf([1]), const {0: 5});
      expect(analysis.success, isFalse);
      expect(analysis.reason, AiSeasonFailure.unsafeFlatMapping);
    });

    test('analyze→parse 全部未知或越界时仍拒绝 FLAT', () async {
      final analysis = await analyzeFlat([
        VodEpisode(name: '无编号', url: 'http://x/unparsed'), episodeOf(99),
      ], const {0: 100, 1: 2});
      expect(analysis.success, isFalse);
      expect(analysis.reason, AiSeasonFailure.unsafeFlatMapping);
    });
  });

  group('buildSeasonBindings（四模式应用，Task5.1）', () {
    test('FLAT_BY_COUNTS 按 parsedNumber 主键映射，缺号不偏移', () {
      final analysis = AiSeasonAnalysis(
        success: true,
        reason: AiSeasonFailure.none,
        mode: AiSeasonMode.flatByCounts,
        confidence: 0.9,
      );
      final result = buildSeasonBindings(
        analysis: analysis,
        episodes: episodesOf([1, 2, 3]),
        seasonCounts: seasonCounts,
      );
      // parsedNumber 1→S1E1, 2→S1E2, 3→S2E1（按集数累计，非数组下标）
      expect(result.status, AiSeasonApplyStatus.applied);
      expect(result.mappedCount, 3);
      expect(result.skippedSourceIndexes, isEmpty);
      final byNumber = {
        for (final b in result.bindings) b.seasonNumber * 100 + b.episodeNumber: b,
      };
      expect(byNumber[101]!.sourceIndex, 0);
      expect(byNumber[102]!.sourceIndex, 1);
      expect(byNumber[201]!.sourceIndex, 2);
    });

    test('FLAT_BY_COUNTS 越界/未知/重复号跳过且不偏移后续集', () {
      final analysis = AiSeasonAnalysis(
        success: true,
        reason: AiSeasonFailure.none,
        mode: AiSeasonMode.flatByCounts,
        confidence: 0.9,
      );
      final result = buildSeasonBindings(
        analysis: analysis,
        // 0=未知, 99=越界, 2 出现两次 → 重复号映射同一目标
        episodes: episodesOf([0, 99, 2, 2]),
        seasonCounts: seasonCounts,
      );
      expect(result.status, AiSeasonApplyStatus.partial);
      expect(result.mappedCount, 2);
      expect(result.skippedSourceIndexes, [0, 1]);
      // 重复号 2 都映射到同一目标 1:2，且后续集不偏移
      final targets = result.bindings
          .map((b) => '${b.seasonNumber}:${b.episodeNumber}')
          .toList();
      expect(targets, ['1:2', '1:2']);
    });

    test('SINGLE_SEASON 用解析集号，缺号 fallback index+1', () {
      final analysis = AiSeasonAnalysis(
        success: true,
        reason: AiSeasonFailure.none,
        mode: AiSeasonMode.singleSeason,
        seasonNumber: 1,
        confidence: 0.8,
      );
      final result = buildSeasonBindings(
        analysis: analysis,
        // 集名给出 7/8/9，缺号（第3集名无数字）
        episodes: [
          episodeOf(7),
          episodeOf(8),
          VodEpisode(name: '特别篇', url: 'http://x/e3'),
        ],
        seasonCounts: const {1: 12},
      );
      expect(result.status, AiSeasonApplyStatus.applied);
      expect(result.bindings.length, 3);
      expect(result.bindings[0].episodeNumber, 7);
      expect(result.bindings[1].episodeNumber, 8);
      expect(result.bindings[2].episodeNumber, 3); // fallback index+1
      expect(result.bindings.every((b) => b.seasonNumber == 1), isTrue);
    });

    test('SINGLE_SEASON 集数超出季容量 → rejected', () {
      final analysis = AiSeasonAnalysis(
        success: true,
        reason: AiSeasonFailure.none,
        mode: AiSeasonMode.singleSeason,
        seasonNumber: 1,
        confidence: 0.8,
      );
      final result = buildSeasonBindings(
        analysis: analysis,
        episodes: episodesOf([1, 2, 3]),
        seasonCounts: seasonCounts,
      );
      expect(result.status, AiSeasonApplyStatus.rejected);
      expect(result.bindings, isEmpty);
    });

    test('KEEP_ORIGINAL 空绑定 applied（清理语义由 clear 处理）', () {
      final analysis = AiSeasonAnalysis(
        success: true,
        reason: AiSeasonFailure.none,
        mode: AiSeasonMode.keepOriginal,
        confidence: 1.0,
      );
      final result = buildSeasonBindings(
        analysis: analysis,
        episodes: episodesOf([1, 2]),
        seasonCounts: seasonCounts,
      );
      expect(result.status, AiSeasonApplyStatus.applied);
      expect(result.bindings, isEmpty);
    });

    test('EXPLICIT_MAPPING 完整唯一映射全量应用', () {
      final analysis = AiSeasonAnalysis(
        success: true,
        reason: AiSeasonFailure.none,
        mode: AiSeasonMode.explicitMapping,
        confidence: 0.95,
        mappings: const [
          AiEpisodeMapping(sourceIndex: 0, seasonNumber: 1, episodeNumber: 1),
          AiEpisodeMapping(sourceIndex: 1, seasonNumber: 1, episodeNumber: 2),
          AiEpisodeMapping(sourceIndex: 2, seasonNumber: 2, episodeNumber: 1),
        ],
      );
      final result = buildSeasonBindings(
        analysis: analysis,
        episodes: episodesOf([1, 2, 3]),
        seasonCounts: seasonCounts,
      );
      expect(result.status, AiSeasonApplyStatus.applied);
      expect(result.mappedCount, 3);
      expect(result.bindings.map((b) => b.sourceIndex), [0, 1, 2]);
    });

    test('EXPLICIT_MAPPING 缺失 sourceIndex → rejected（不落半套绑定）', () {
      final analysis = AiSeasonAnalysis(
        success: true,
        reason: AiSeasonFailure.none,
        mode: AiSeasonMode.explicitMapping,
        confidence: 0.95,
        mappings: const [
          AiEpisodeMapping(sourceIndex: 0, seasonNumber: 1, episodeNumber: 1),
        ],
      );
      final result = buildSeasonBindings(
        analysis: analysis,
        episodes: episodesOf([1, 2, 3]),
        seasonCounts: seasonCounts,
      );
      expect(result.status, AiSeasonApplyStatus.rejected);
      expect(result.bindings, isEmpty);
    });

    test('EXPLICIT_MAPPING 乱序 sourceIndex 绕过严格递增 → rejected', () {
      // 若按给定顺序校验，(source1→S1E1)、(source0→S1E2) 看起来递增；
      // 按**源序**则是 E2→E1，必须拒绝。
      final result = buildSeasonBindings(
        analysis: AiSeasonAnalysis(
          success: true,
          reason: AiSeasonFailure.none,
          mode: AiSeasonMode.explicitMapping,
          confidence: 0.95,
          mappings: const [
            AiEpisodeMapping(sourceIndex: 1, seasonNumber: 1, episodeNumber: 1),
            AiEpisodeMapping(sourceIndex: 0, seasonNumber: 1, episodeNumber: 2),
          ],
        ),
        episodes: episodesOf([1, 2]),
        seasonCounts: const {1: 5},
      );
      expect(result.status, AiSeasonApplyStatus.rejected);
      expect(result.bindings, isEmpty);
    });

    test('EXPLICIT_MAPPING 乱序但按源序递增 → 接受并按源序返回', () {
      final result = buildSeasonBindings(
        analysis: AiSeasonAnalysis(
          success: true,
          reason: AiSeasonFailure.none,
          mode: AiSeasonMode.explicitMapping,
          confidence: 0.95,
          mappings: const [
            AiEpisodeMapping(sourceIndex: 1, seasonNumber: 1, episodeNumber: 2),
            AiEpisodeMapping(sourceIndex: 0, seasonNumber: 1, episodeNumber: 1),
          ],
        ),
        episodes: episodesOf([1, 2]),
        seasonCounts: const {1: 5},
      );
      expect(result.status, AiSeasonApplyStatus.applied);
      expect(result.bindings.map((b) => b.sourceIndex), [0, 1]);
      expect(result.bindings.map((b) => b.episodeNumber), [1, 2]);
    });

    test('失败的分析 → rejected，不产出绑定', () {
      final result = buildSeasonBindings(
        analysis: AiSeasonAnalysis.failure(AiSeasonFailure.invalidJson),
        episodes: episodesOf([1, 2]),
        seasonCounts: seasonCounts,
      );
      expect(result.status, AiSeasonApplyStatus.rejected);
      expect(result.bindings, isEmpty);
    });
  });

  group('确认快照与持久化（Task5.2）', () {
    test('识别快照不一致 → staleSnapshot 拒写', () async {
      final db = AppDatabase.inMemory();
      final service = AiSeasonMappingService(database: db);
      final episodes = episodesOf([1, 2, 3]);
      final result = await service.confirmAndPersist(
        siteKey: 's1',
        vodId: 'v2',
        sourceTitle: 'T',
        flagKey: 'f1',
        analysis: AiSeasonAnalysis(
          success: true,
          reason: AiSeasonFailure.none,
          mode: AiSeasonMode.flatByCounts,
          confidence: 0.9,
        ),
        episodes: episodes,
        seasonCounts: seasonCounts,
        recognitionSnapshot: 'deadbeef',
      );
      expect(result.status, AiSeasonApplyStatus.staleSnapshot);
      final stored = await service.bindingsFor(
        siteKey: 's1',
        vodId: 'v2',
        sourceTitle: 'T',
        flagKey: 'f1',
        episodes: episodes,
        seasonCounts: seasonCounts,
      );
      expect(stored.status, AiSeasonApplyStatus.missing);
      db.dispose();
    });

    test('识别快照一致即落库；列表变化 → staleSnapshot 读回为空', () async {
      final db = AppDatabase.inMemory();
      final service = AiSeasonMappingService(database: db);
      final episodes = episodesOf([1, 2, 3]);
      final recognition = seasonBindingsSnapshot(episodes, seasonCounts);
      final saved = await service.confirmAndPersist(
        siteKey: 's1',
        vodId: 'v1',
        sourceTitle: 'T',
        flagKey: 'f1',
        analysis: AiSeasonAnalysis(
          success: true,
          reason: AiSeasonFailure.none,
          mode: AiSeasonMode.flatByCounts,
          confidence: 0.9,
        ),
        episodes: episodes,
        seasonCounts: seasonCounts,
        recognitionSnapshot: recognition,
      );
      expect(saved.status, AiSeasonApplyStatus.applied);
      expect(saved.mappedCount, 3);
      // 换源后列表变化
      final changed = episodesOf([1, 2, 3, 4]);
      final stale = await service.bindingsFor(
        siteKey: 's1',
        vodId: 'v1',
        sourceTitle: 'T',
        flagKey: 'f1',
        episodes: changed,
        seasonCounts: seasonCounts,
      );
      expect(stale.status, AiSeasonApplyStatus.staleSnapshot);
      expect(stale.bindings, isEmpty);
      // 原始列表仍命中
      final fresh = await service.bindingsFor(
        siteKey: 's1',
        vodId: 'v1',
        sourceTitle: 'T',
        flagKey: 'f1',
        episodes: episodes,
        seasonCounts: seasonCounts,
      );
      expect(fresh.status, AiSeasonApplyStatus.applied);
      expect(fresh.mappedCount, 3);
      db.dispose();
    });

    test('R5 完整映射：真实文件DB关闭重开后source/target/快照/status精确保留', () async {
      final directory = Directory.systemTemp.createTempSync('webhtv_task5_complete_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = p.join(directory.path, 'complete.db');
      final episodes = episodesOf([1, 2, 3]);
      const snapshot = '9c961664b24e5edae38120dde85373194fc590749f7b12c18688be155b0941e3';
      const expected = [
        {'sourceIndex': 0, 'seasonNumber': 2, 'episodeNumber': 1},
        {'sourceIndex': 1, 'seasonNumber': 2, 'episodeNumber': 2},
        {'sourceIndex': 2, 'seasonNumber': 2, 'episodeNumber': 3},
      ];
      expect(seasonBindingsSnapshot(episodes, seasonCounts), snapshot);
      final opened = AppDatabase.open(path);
      expect(opened.error, isNull);
      final db = opened.database!;
      try {
        final saved = await AiSeasonMappingService(database: db).confirmAndPersist(
          configId: 7, siteKey: 's1', vodId: 'v3', sourceTitle: 'T', flagKey: 'f1',
          tmdbId: 42, mediaType: 'tv',
          analysis: AiSeasonAnalysis(
            success: true, reason: AiSeasonFailure.none,
            mode: AiSeasonMode.singleSeason, seasonNumber: 2, confidence: 0.9,
          ),
          episodes: episodes, seasonCounts: seasonCounts,
          recognitionSnapshot: snapshot,
        );
        expect(saved.status, AiSeasonApplyStatus.applied);
        expect(saved.skippedSourceIndexes, isEmpty);
        expect(saved.bindings.map((b) => b.toJson()), expected);
      } finally {
        db.dispose();
      }
      expect(File(path).existsSync(), isTrue);
      final reopened = AppDatabase.open(path);
      expect(reopened.error, isNull);
      final db2 = reopened.database!;
      try {
        final row = db2.findAiSeasonMappings(
          configId: 7, siteKey: 's1', vodId: 'v3', sourceTitle: 'T', flagKey: 'f1',
        )!;
        expect(row['config_id'], 7);
        expect(row['site_key'], 's1');
        expect(row['vod_id'], 'v3');
        expect(row['source_title'], 'T');
        expect(row['flag_key'], 'f1');
        expect(row['tmdb_id'], 42);
        expect(row['media_type'], 'tv');
        expect(row['mode'], 'singleSeason');
        expect(row['season_number'], 2);
        expect(row['confidence'], 0.9);
        expect(row['snapshot'], snapshot);
        expect(row['status'], 'applied');
        expect(jsonDecode(row['skipped_source_indexes'] as String), isEmpty);
        expect(jsonDecode(row['mappings'] as String), expected);
        final service2 = AiSeasonMappingService(database: db2);
        final loaded = await service2.bindingsFor(
          configId: 7, siteKey: 's1', vodId: 'v3', sourceTitle: 'T', flagKey: 'f1',
          episodes: episodes, seasonCounts: seasonCounts,
        );
        expect(loaded.status, AiSeasonApplyStatus.applied);
        expect(loaded.skippedSourceIndexes, isEmpty);
        expect(loaded.mappedCount, 3);
        expect(loaded.bindings.map((b) => b.toJson()), expected);
        final stale = await service2.bindingsFor(
          configId: 7, siteKey: 's1', vodId: 'v3', sourceTitle: 'T', flagKey: 'f1',
          episodes: episodes.reversed.toList(), seasonCounts: seasonCounts,
        );
        expect(stale.status, AiSeasonApplyStatus.staleSnapshot);
        expect(stale.bindings, isEmpty);
      } finally {
        db2.dispose();
      }
    });

    test('KEEP_ORIGINAL 确认时清除既有 AI 映射（清理语义）', () async {
      final db = AppDatabase.inMemory();
      final service = AiSeasonMappingService(database: db);
      final episodes = episodesOf([1, 2, 3]);
      final recognition = seasonBindingsSnapshot(episodes, seasonCounts);
      // 先落 FLAT 映射
      await service.confirmAndPersist(
        siteKey: 's1',
        vodId: 'v5',
        sourceTitle: 'T',
        flagKey: 'f1',
        analysis: AiSeasonAnalysis(
          success: true,
          reason: AiSeasonFailure.none,
          mode: AiSeasonMode.flatByCounts,
          confidence: 0.9,
        ),
        episodes: episodes,
        seasonCounts: seasonCounts,
        recognitionSnapshot: recognition,
      );
      // 再确认 KEEP_ORIGINAL → 应清除此前 AI 覆写
      final keep = await service.confirmAndPersist(
        siteKey: 's1',
        vodId: 'v5',
        sourceTitle: 'T',
        flagKey: 'f1',
        analysis: AiSeasonAnalysis(
          success: true,
          reason: AiSeasonFailure.none,
          mode: AiSeasonMode.keepOriginal,
          confidence: 1.0,
        ),
        episodes: episodes,
        seasonCounts: seasonCounts,
        recognitionSnapshot: recognition,
      );
      expect(keep.status, AiSeasonApplyStatus.applied);
      final loaded = await service.bindingsFor(
        siteKey: 's1',
        vodId: 'v5',
        sourceTitle: 'T',
        flagKey: 'f1',
        episodes: episodes,
        seasonCounts: seasonCounts,
      );
      expect(loaded.status, AiSeasonApplyStatus.missing);
      db.dispose();
    });

    test('clearMappings 删除后 bindingsFor 返回 missing', () async {
      final db = AppDatabase.inMemory();
      final service = AiSeasonMappingService(database: db);
      final episodes = episodesOf([1, 2]);
      await service.confirmAndPersist(
        siteKey: 's1',
        vodId: 'v4',
        sourceTitle: 'T',
        flagKey: 'f1',
        analysis: AiSeasonAnalysis(
          success: true,
          reason: AiSeasonFailure.none,
          mode: AiSeasonMode.flatByCounts,
          confidence: 0.9,
        ),
        episodes: episodes,
        seasonCounts: seasonCounts,
        recognitionSnapshot: seasonBindingsSnapshot(episodes, seasonCounts),
      );
      service.clearMappings(
        siteKey: 's1',
        vodId: 'v4',
        sourceTitle: 'T',
        flagKey: 'f1',
      );
      final loaded = await service.bindingsFor(
        siteKey: 's1',
        vodId: 'v4',
        sourceTitle: 'T',
        flagKey: 'f1',
        episodes: episodes,
        seasonCounts: seasonCounts,
      );
      expect(loaded.status, AiSeasonApplyStatus.missing);
      db.dispose();
    });

    test('重排（[E1,E2]→[E2,E1]）→ staleSnapshot，不按旧 sourceIndex 误绑', () async {
      final db = AppDatabase.inMemory();
      final service = AiSeasonMappingService(database: db);
      final episodes = episodesOf([1, 2]);
      await service.confirmAndPersist(
        siteKey: 's1',
        vodId: 'v6',
        sourceTitle: 'T',
        flagKey: 'f1',
        analysis: AiSeasonAnalysis(
          success: true,
          reason: AiSeasonFailure.none,
          mode: AiSeasonMode.explicitMapping,
          confidence: 0.95,
          mappings: const [
            AiEpisodeMapping(sourceIndex: 0, seasonNumber: 1, episodeNumber: 1),
            AiEpisodeMapping(sourceIndex: 1, seasonNumber: 1, episodeNumber: 2),
          ],
        ),
        episodes: episodes,
        seasonCounts: const {1: 5},
        recognitionSnapshot: seasonBindingsSnapshot(episodes, const {1: 5}),
      );
      final reordered = episodesOf([2, 1]);
      final stale = await service.bindingsFor(
        siteKey: 's1',
        vodId: 'v6',
        sourceTitle: 'T',
        flagKey: 'f1',
        episodes: reordered,
        seasonCounts: const {1: 5},
      );
      expect(stale.status, AiSeasonApplyStatus.staleSnapshot);
      expect(stale.bindings, isEmpty);
      db.dispose();
    });

    test('确认时重排（识别快照 vs 现场）→ 拒写', () async {
      final db = AppDatabase.inMemory();
      final service = AiSeasonMappingService(database: db);
      final recognized = episodesOf([1, 2]);
      final result = await service.confirmAndPersist(
        siteKey: 's1',
        vodId: 'v7',
        sourceTitle: 'T',
        flagKey: 'f1',
        analysis: AiSeasonAnalysis(
          success: true,
          reason: AiSeasonFailure.none,
          mode: AiSeasonMode.flatByCounts,
          confidence: 0.9,
        ),
        episodes: episodesOf([2, 1]),
        seasonCounts: seasonCounts,
        recognitionSnapshot: seasonBindingsSnapshot(recognized, seasonCounts),
      );
      expect(result.status, AiSeasonApplyStatus.staleSnapshot);
      expect(
        db.findAiSeasonMappings(
          configId: 0,
          siteKey: 's1',
          vodId: 'v7',
          sourceTitle: 'T',
          flagKey: 'f1',
        ),
        isNull,
      );
      db.dispose();
    });

    test('R5 partial映射：真实文件DB关闭重开后source/target/快照/status/skipped精确保留', () async {
      final directory = Directory.systemTemp.createTempSync('webhtv_task5_partial_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final path = p.join(directory.path, 'partial.db');
      final episodes = [episodeOf(1), episodeOf(99)];
      const counts = {1: 2};
      const snapshot = '997ecb6060e88735828ee5cb26df5796d137b04f47f1cb4d9f49adc52cda33e0';
      const expected = [
        {'sourceIndex': 0, 'seasonNumber': 1, 'episodeNumber': 1},
      ];
      expect(seasonBindingsSnapshot(episodes, counts), snapshot);
      final opened = AppDatabase.open(path);
      expect(opened.error, isNull);
      final db = opened.database!;
      try {
        final saved = await AiSeasonMappingService(database: db).confirmAndPersist(
          configId: 8, siteKey: 's1', vodId: 'v8', sourceTitle: 'T', flagKey: 'f1',
          tmdbId: 43, mediaType: 'tv',
          analysis: AiSeasonAnalysis(
            success: true, reason: AiSeasonFailure.none,
            mode: AiSeasonMode.flatByCounts, confidence: 0.9,
          ),
          episodes: episodes, seasonCounts: counts, recognitionSnapshot: snapshot,
        );
        expect(saved.status, AiSeasonApplyStatus.partial);
        expect(saved.skippedSourceIndexes, [1]);
        expect(saved.bindings.map((b) => b.toJson()), expected);
      } finally {
        db.dispose();
      }
      expect(File(path).existsSync(), isTrue);
      final reopened = AppDatabase.open(path);
      expect(reopened.error, isNull);
      final db2 = reopened.database!;
      try {
        final row = db2.findAiSeasonMappings(
          configId: 8, siteKey: 's1', vodId: 'v8', sourceTitle: 'T', flagKey: 'f1',
        )!;
        expect(row['config_id'], 8);
        expect(row['site_key'], 's1');
        expect(row['vod_id'], 'v8');
        expect(row['source_title'], 'T');
        expect(row['flag_key'], 'f1');
        expect(row['tmdb_id'], 43);
        expect(row['media_type'], 'tv');
        expect(row['mode'], 'flatByCounts');
        expect(row['season_number'], -1);
        expect(row['confidence'], 0.9);
        expect(row['snapshot'], snapshot);
        expect(row['status'], 'partial');
        expect(jsonDecode(row['skipped_source_indexes'] as String), [1]);
        expect(jsonDecode(row['mappings'] as String), expected);
        final service2 = AiSeasonMappingService(database: db2);
        final loaded = await service2.bindingsFor(
          configId: 8, siteKey: 's1', vodId: 'v8', sourceTitle: 'T', flagKey: 'f1',
          episodes: episodes, seasonCounts: counts,
        );
        expect(loaded.status, AiSeasonApplyStatus.partial);
        expect(loaded.skippedSourceIndexes, [1]);
        expect(loaded.mappedCount, 1);
        expect(loaded.bindings.map((b) => b.toJson()), expected);
        final stale = await service2.bindingsFor(
          configId: 8, siteKey: 's1', vodId: 'v8', sourceTitle: 'T', flagKey: 'f1',
          episodes: episodes.reversed.toList(), seasonCounts: counts,
        );
        expect(stale.status, AiSeasonApplyStatus.staleSnapshot);
        expect(stale.bindings, isEmpty);
      } finally {
        db2.dispose();
      }
    });
  });

  group('AI 取消（analyze 真实 HTTP 取消合同，Task5.2）', () {
    test('取消后 analyze 短路不发请求、不写库', () async {
      final client = CancelAwareCompletionClient();
      final service = AiEpisodeSeasonService(
        config: const AiConfig(
          enabled: true,
          apiKey: 'k',
          endpoint: 'http://x/v1',
          model: 'm',
          protocol: AiProtocol.openAiChat,
        ),
        client: client,
      );
      service.cancel();
      final result = await service.analyze(
        title: 'T',
        flagName: 'F',
        episodes: [episodeOf(1)],
        seasonCounts: seasonCounts,
      );
      expect(result.success, isFalse);
      expect(result.reason, AiSeasonFailure.canceled);
      expect(client.sentBodies, isEmpty);
      service.dispose();
    });

    test('在途取消：token 传到底层请求并返回取消，不产出分析', () async {
      final gate = Completer<void>();
      final client = CancelAwareCompletionClient(gate: gate.future);
      final token = AiCancellationToken();
      final service = AiEpisodeSeasonService(
        config: const AiConfig(
          enabled: true,
          apiKey: 'k',
          endpoint: 'http://x/v1',
          model: 'm',
          protocol: AiProtocol.openAiChat,
        ),
        client: client,
        cancellationToken: token,
      );
      final pending = service.analyze(
        title: 'T',
        flagName: 'F',
        episodes: [episodeOf(1), episodeOf(2)],
        seasonCounts: seasonCounts,
      );
      // 让请求真正发出
      await Future<void>.delayed(Duration.zero);
      expect(client.sentBodies.length, 1);
      expect(client.receivedCancellation, isTrue);
      service.cancel();
      final result = await pending;
      expect(result.success, isFalse);
      expect(result.reason, AiSeasonFailure.canceled);
      expect(result.mappings, isEmpty);
      // 外部 token 同样生效
      expect(token.isCancelled, isTrue);
      service.dispose();
    });
  });

  group('TMDB 身份低置信回退（Task5.3）', () {
    test('弱信心不覆盖已有强匹配', () {
      final result = shouldWriteIdentityFallback(
        existingTmdbId: 123,
        existingIsManual: true,
        confidence: 0.4,
      );
      expect(result, isFalse);
    });

    test('无既有绑定且强信心可回退', () {
      expect(
        shouldWriteIdentityFallback(
          existingTmdbId: 0,
          existingIsManual: false,
          confidence: 0.9,
        ),
        isTrue,
      );
    });

    test('既有强匹配且新结果更强信心仍不覆盖（不猜ID）', () {
      expect(
        shouldWriteIdentityFallback(
          existingTmdbId: 123,
          existingIsManual: false,
          confidence: 0.95,
        ),
        isFalse,
      );
    });

    test('无既有绑定但弱信心不回退', () {
      expect(
        shouldWriteIdentityFallback(
          existingTmdbId: 0,
          existingIsManual: false,
          confidence: 0.5,
        ),
        isFalse,
      );
    });
  });

  group('识别快照指纹（对照安卓 EpisodeSeasonSnapshot.stableStructureFingerprint）', () {
    test('同列表同季数 → 指纹一致', () {
      final episodes = episodesOf([1, 2, 3]);
      expect(
        seasonMappingSnapshot(episodes, seasonCounts),
        seasonMappingSnapshot(episodesOf([1, 2, 3]), seasonCounts),
      );
    });

    test('新增/删除/改名集 → 指纹变化', () {
      final base = seasonMappingSnapshot(episodesOf([1, 2, 3]), seasonCounts);
      expect(
        base != seasonMappingSnapshot(episodesOf([1, 2, 3, 4]), seasonCounts),
        isTrue,
      );
      expect(
        base !=
            seasonMappingSnapshot(
              [
                episodeOf(1),
                episodeOf(2),
                VodEpisode(name: '第3集改名', url: 'http://x/e3'),
              ],
              seasonCounts,
            ),
        isTrue,
      );
    });

    test('TMDB 季数变化 → 指纹变化', () {
      final episodes = episodesOf([1, 2, 3]);
      final base = seasonMappingSnapshot(episodes, seasonCounts);
      expect(
        base != seasonMappingSnapshot(episodes, const {1: 2, 2: 4, 0: 1}),
        isTrue,
      );
    });

    test('集排序不影响指纹（对照安卓 order-insensitive 语义）', () {
      final a = seasonMappingSnapshot(
        [episodeOf(1), episodeOf(2), episodeOf(3)],
        seasonCounts,
      );
      final b = seasonMappingSnapshot(
        [episodeOf(3), episodeOf(1), episodeOf(2)],
        seasonCounts,
      );
      expect(a, b);
    });
  });

  group('identity service 既有行为回归（确认未破坏）', () {
    test('InMemoryTmdbMatchStore put/find 往返', () {
      final store = InMemoryTmdbMatchStore();
      final item = TmdbItem(
        tmdbId: 42,
        mediaType: TmdbMediaType.tv,
        title: 'Show',
      );
      store.putManual(
        siteKey: 's',
        vodId: 'v',
        sourceTitles: ['Show'],
        item: item,
        matchedAt: 1,
      );
      final found = store.find(siteKey: 's', vodId: 'v', sourceTitle: 'Show');
      expect(found?.identity.tmdbId, 42);
    });
  });
}
