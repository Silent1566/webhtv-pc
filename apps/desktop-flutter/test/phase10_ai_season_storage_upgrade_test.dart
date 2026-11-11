// ignore_for_file: deprecated_member_use
/// Task5 · AI 季集映射表的 schema 前向升级（`9 → 10`）。
///
/// 合同：加法式新增；旧数据库（schema_version=9，含既有绑定/进度）打开后
/// 自动获得新表，旧行不丢、可读。
library;

import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/ai_season_mapping_service.dart';
import 'package:webhtv_pc/services/storage.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('webhtv_task5_db_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  test('schemaVersion 升到 10 且新表存在', () {
    expect(AppDatabase.schemaVersion, 10);
    final db = AppDatabase.inMemory();
    expect(db.count('ai_season_episode_mappings'), 0);
    expect(db.rowCounts().containsKey('ai_season_episode_mappings'), isTrue);
    expect(db.schemaVersionValue, '10');
    db.dispose();
  });

  test('旧库（v9 结构与数据）打开后升级保数据并新增表', () {
    final path = p.join(tempDir.path, 'legacy.db');
    // 构造一个 v9 数据库：既有表 + 旧绑定行 + 旧进度行 + 旧版本号
    final legacy = sqlite3.open(path);
    legacy.execute('''
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    ''');
    legacy.execute('''
      CREATE TABLE tmdb_season_bindings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        config_id INTEGER NOT NULL DEFAULT 0,
        site_key TEXT NOT NULL,
        vod_id TEXT NOT NULL,
        source_title TEXT NOT NULL DEFAULT '',
        flag_key TEXT NOT NULL DEFAULT '',
        tmdb_id INTEGER NOT NULL,
        media_type TEXT NOT NULL DEFAULT 'tv',
        mode TEXT NOT NULL,
        season_number INTEGER,
        source_fingerprint TEXT NOT NULL DEFAULT '',
        source_episode_count INTEGER NOT NULL DEFAULT 0,
        tmdb_season_episode_count INTEGER NOT NULL DEFAULT 0,
        segments TEXT,
        version INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL,
        UNIQUE(config_id, site_key, vod_id, source_title, flag_key)
      );
    ''');
    legacy.execute('''
      CREATE TABLE tmdb_season_progress (
        config_id INTEGER NOT NULL DEFAULT 0,
        media_type TEXT NOT NULL DEFAULT 'tv',
        tmdb_id INTEGER NOT NULL,
        season_number INTEGER NOT NULL,
        episode_number INTEGER NOT NULL DEFAULT 0,
        position_ms INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        source_flag TEXT NOT NULL DEFAULT '',
        source_episode_name TEXT NOT NULL DEFAULT '',
        source_episode_url TEXT NOT NULL DEFAULT '',
        source_history_key TEXT NOT NULL DEFAULT '',
        source_binding_key TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (config_id, media_type, tmdb_id, season_number)
      );
    ''');
    legacy.execute(
      "INSERT INTO meta(key, value) VALUES('schema_version', '9');",
    );
    legacy.execute(
      'INSERT INTO tmdb_season_bindings(config_id, site_key, vod_id, '
      "source_title, flag_key, tmdb_id, media_type, mode, season_number, "
      'updated_at) VALUES(0,?,?,?,?,?,?,?,?,?);',
      ['s1', 'v1', 'T', 'f1', 42, 'tv', 'manualSeason', 1, 1],
    );
    legacy.execute(
      'INSERT INTO tmdb_season_progress(config_id, media_type, tmdb_id, '
      'season_number, episode_number, position_ms, duration_ms, updated_at) '
      'VALUES(0,?,?,?,?,?,?,?);',
      ['tv', 42, 1, 3, 1000, 2000, 1],
    );
    final oldBinding = Map<String, Object?>.from(
      legacy.select('SELECT * FROM tmdb_season_bindings').single,
    );
    final oldProgress = Map<String, Object?>.from(
      legacy.select('SELECT * FROM tmdb_season_progress').single,
    );
    legacy.dispose();

    void expectLegacyValues(AppDatabase database) {
      final binding = database.findTmdbSeasonBinding(
        configId: 0, siteKey: 's1', vodId: 'v1', sourceTitle: 'T', flagKey: 'f1',
      )!;
      expect(binding, equals(oldBinding));
      expect(binding['tmdb_id'], 42);
      expect(binding['media_type'], 'tv');
      expect(binding['mode'], 'manualSeason');
      expect(binding['season_number'], 1);
      final progress = database.findTmdbSeasonProgress(
        configId: 0, mediaType: 'tv', tmdbId: 42, seasonNumber: 1,
      )!;
      expect(progress, equals(oldProgress));
      expect(progress['tmdb_id'], 42);
      expect(progress['media_type'], 'tv');
      expect(progress['season_number'], 1);
      expect(progress['episode_number'], 3);
      expect(progress['position_ms'], 1000);
      expect(progress['duration_ms'], 2000);
      expect(progress['updated_at'], 1);
    }

    final db = AppDatabase.open(path).database!;
    expectLegacyValues(db);
    // 旧数据仍在
    expect(db.count('tmdb_season_bindings'), 1);
    expect(db.count('tmdb_season_progress'), 1);
    expect(db.schemaVersionValue, '10');
    // 新表可用
    expect(db.count('ai_season_episode_mappings'), 0);
    db.upsertAiSeasonMappings(
      configId: 0,
      siteKey: 's1',
      vodId: 'v1',
      sourceTitle: 'T',
      flagKey: 'f1',
      tmdbId: 42,
      mediaType: 'tv',
      mode: 'flatByCounts',
      seasonNumber: -1,
      confidence: 0.9,
      mappings: [
        {'sourceIndex': 0, 'seasonNumber': 1, 'episodeNumber': 1},
      ],
      snapshot: 'snap',
    );
    expect(db.count('ai_season_episode_mappings'), 1);
    db.dispose();

    // 再次打开仍幂等
    final again = AppDatabase.open(path).database!;
    expect(again.schemaVersionValue, '10');
    expect(again.count('ai_season_episode_mappings'), 1);
    expectLegacyValues(again);
    final mapping = again.findAiSeasonMappings(
      configId: 0, siteKey: 's1', vodId: 'v1', sourceTitle: 'T', flagKey: 'f1',
    )!;
    expect(mapping['tmdb_id'], 42);
    expect(mapping['media_type'], 'tv');
    expect(mapping['mode'], 'flatByCounts');
    expect(mapping['season_number'], -1);
    expect(mapping['confidence'], 0.9);
    expect(mapping['snapshot'], 'snap');
    expect(mapping['status'], 'applied');
    expect(jsonDecode(mapping['skipped_source_indexes'] as String), isEmpty);
    expect(jsonDecode(mapping['mappings'] as String), [
      {'sourceIndex': 0, 'seasonNumber': 1, 'episodeNumber': 1},
    ]);
    again.dispose();
  });

  test('R5 v10早期表缺列：关闭重开幂等补列并保留旧行精确业务值', () async {
    final path = p.join(tempDir.path, 'early_v10.db');
    final episodes = [VodEpisode(name: '第1集', url: 'http://x/e1')];
    const counts = {1: 2};
    const snapshot = '25acecabf09288d50f62e9e2a85dae62c3a8166ca293d5c1a0c4fa4bedf9323b';
    const expected = [
      {'sourceIndex': 0, 'seasonNumber': 1, 'episodeNumber': 1},
    ];
    expect(seasonBindingsSnapshot(episodes, counts), snapshot);
    final legacy = sqlite3.open(path);
    legacy.execute(
      'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);',
    );
    legacy.execute('''
      CREATE TABLE ai_season_episode_mappings (
        config_id INTEGER NOT NULL DEFAULT 0,
        site_key TEXT NOT NULL,
        vod_id TEXT NOT NULL,
        source_title TEXT NOT NULL DEFAULT '',
        flag_key TEXT NOT NULL DEFAULT '',
        tmdb_id INTEGER NOT NULL DEFAULT 0,
        media_type TEXT NOT NULL DEFAULT '',
        mode TEXT NOT NULL,
        season_number INTEGER NOT NULL DEFAULT -1,
        confidence REAL NOT NULL DEFAULT 0,
        mappings TEXT NOT NULL DEFAULT '[]',
        snapshot TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        UNIQUE(config_id, site_key, vod_id, source_title, flag_key)
      );
    ''');
    legacy.execute(
      "INSERT INTO meta(key, value) VALUES('schema_version', '10');",
    );
    legacy.execute(
      'INSERT INTO ai_season_episode_mappings(config_id, site_key, vod_id, '
      'source_title, flag_key, tmdb_id, media_type, mode, season_number, '
      'confidence, mappings, snapshot, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);',
      [3, 's', 'v', 'T', 'f', 51, 'tv', 'flatByCounts', -1, 0.9,
        jsonEncode(expected), snapshot, 123],
    );
    legacy.dispose();

    for (var openNumber = 0; openNumber < 2; openNumber++) {
      final opened = AppDatabase.open(path);
      expect(opened.error, isNull);
      final db = opened.database!;
      try {
        final row = db.findAiSeasonMappings(
          configId: 3, siteKey: 's', vodId: 'v', sourceTitle: 'T', flagKey: 'f',
        );
        expect(row, isNotNull, reason: '旧行不能丢，第二次open不能重复补列');
        expect(row!['config_id'], 3);
        expect(row['site_key'], 's');
        expect(row['vod_id'], 'v');
        expect(row['source_title'], 'T');
        expect(row['flag_key'], 'f');
        expect(row['tmdb_id'], 51);
        expect(row['media_type'], 'tv');
        expect(row['mode'], 'flatByCounts');
        expect(row['season_number'], -1);
        expect(row['confidence'], 0.9);
        expect(row['updated_at'], 123);
        expect(row['status'], 'applied');
        expect(jsonDecode(row['skipped_source_indexes'] as String), isEmpty);
        expect(row['snapshot'], snapshot);
        expect(jsonDecode(row['mappings'] as String), expected);
        final loaded = await AiSeasonMappingService(database: db).bindingsFor(
          configId: 3, siteKey: 's', vodId: 'v', sourceTitle: 'T', flagKey: 'f',
          episodes: episodes, seasonCounts: counts,
        );
        expect(loaded.status, AiSeasonApplyStatus.applied);
        expect(loaded.skippedSourceIndexes, isEmpty);
        expect(loaded.mappedCount, 1);
        expect(loaded.bindings.map((b) => b.toJson()), expected);
        expect(db.schemaVersionValue, '10');
      } finally {
        db.dispose();
      }
    }
  });

  test('映射行 upsert/查询/删除往返', () {
    final db = AppDatabase.inMemory();
    db.upsertAiSeasonMappings(
      configId: 0,
      siteKey: 's',
      vodId: 'v',
      sourceTitle: 'T',
      flagKey: 'f',
      tmdbId: 7,
      mediaType: 'tv',
      mode: 'explicitMapping',
      seasonNumber: -1,
      confidence: 0.95,
      mappings: [
        {'sourceIndex': 0, 'seasonNumber': 1, 'episodeNumber': 1},
        {'sourceIndex': 1, 'seasonNumber': 2, 'episodeNumber': 1},
      ],
      snapshot: 'abc',
    );
    final row = db.findAiSeasonMappings(
      configId: 0,
      siteKey: 's',
      vodId: 'v',
      sourceTitle: 'T',
      flagKey: 'f',
    );
    expect(row, isNotNull);
    expect(row!['mode'], 'explicitMapping');
    expect(row['snapshot'], 'abc');
    expect(row['mappings'], contains('"sourceIndex":1'));
    expect(
      db.removeAiSeasonMappings(
        configId: 0,
        siteKey: 's',
        vodId: 'v',
        sourceTitle: 'T',
        flagKey: 'f',
      ),
      1,
    );
    expect(
      db.findAiSeasonMappings(
        configId: 0,
        siteKey: 's',
        vodId: 'v',
        sourceTitle: 'T',
        flagKey: 'f',
      ),
      isNull,
    );
    db.dispose();
  });

  test('快照不一致的持久化行不参与结果（stale 判定在服务层）', () async {
    final db = AppDatabase.inMemory();
    final service = AiSeasonMappingService(database: db);
    db.upsertAiSeasonMappings(
      configId: 0,
      siteKey: 's',
      vodId: 'v',
      sourceTitle: 'T',
      flagKey: 'f',
      tmdbId: 7,
      mediaType: 'tv',
      mode: 'flatByCounts',
      seasonNumber: -1,
      confidence: 0.9,
      mappings: [
        {'sourceIndex': 0, 'seasonNumber': 1, 'episodeNumber': 1},
      ],
      snapshot: 'other-snapshot',
    );
    final stale = service.bindingsFor(
      siteKey: 's',
      vodId: 'v',
      sourceTitle: 'T',
      flagKey: 'f',
      episodes: const [],
      seasonCounts: const {},
    );
    expect(
      (await stale).status,
      AiSeasonApplyStatus.staleSnapshot,
    );
    db.dispose();
  });
}
