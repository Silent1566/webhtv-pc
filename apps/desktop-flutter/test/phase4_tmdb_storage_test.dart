/// Phase 4 · TMDB 存储与迁移（`docs/phase4/design/03` §6）。
///
/// 对应门禁：`docs/phase4/design/05` §4.2「建表 / 迁移幂等 / 匹配往返 / 绑定往返 /
/// 线路绑定上限 513→512 / 进度主键覆盖 / 清理边界 / 写失败隔离」。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:webhtv_pc/services/storage.dart';

void main() {
  group('建表与版本（§6.1/§6.2）', () {
    test('schemaVersion 不低于 2（Phase 4 引入的迁移基线）', () {
      // 具体版本号由引入该版本的那个阶段的套件断言：当前是 Phase 5
      // （`2 → 3`，见 `test/phase5_sync_storage_test.dart`）。
      expect(AppDatabase.schemaVersion, greaterThanOrEqualTo(2));
    });

    test('四张 TMDB 表全部存在', () {
      final db = AppDatabase.inMemory();
      for (final table in [
        'tmdb_matches',
        'tmdb_season_bindings',
        'tmdb_route_bindings',
        'tmdb_season_progress',
      ]) {
        expect(db.count(table), 0, reason: '$table 应可查询');
      }
      db.dispose();
    });

    test('rowCounts 包含 TMDB 四表', () {
      final db = AppDatabase.inMemory();
      final counts = db.rowCounts();
      for (final table in [
        'tmdb_matches',
        'tmdb_season_bindings',
        'tmdb_route_bindings',
        'tmdb_season_progress',
      ]) {
        expect(counts.containsKey(table), isTrue, reason: table);
        expect(counts[table], 0);
      }
      db.dispose();
    });

    test('meta 表记录与 AppDatabase.schemaVersion 一致', () {
      final db = AppDatabase.inMemory();
      expect(db.schemaVersionValue, '${AppDatabase.schemaVersion}');
      db.dispose();
    });
  });

  group('迁移幂等（§6.2）', () {
    late Directory tempDir;

    setUp(() => tempDir = Directory.systemTemp.createTempSync('webhtv_tmdb_db_'));
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('旧库（version 1）打开后获得新表且旧数据完好', () {
      final path = p.join(tempDir.path, 'legacy.sqlite3');

      // 构造一个「Phase 3 时代」的数据库：只有旧表 + schema_version=1
      final legacy = sqlite3.open(path);
      legacy.execute('''
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      ''');
      legacy.execute('''
        CREATE TABLE configs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          origin TEXT NOT NULL,
          content_type TEXT,
          repository_index INTEGER,
          repository_entries TEXT,
          json TEXT NOT NULL,
          site_count INTEGER NOT NULL DEFAULT 0,
          live_count INTEGER NOT NULL DEFAULT 0,
          is_active INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL
        );
      ''');
      legacy.execute('''
        CREATE TABLE history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          site_key TEXT NOT NULL,
          vod_id TEXT NOT NULL,
          vod_name TEXT NOT NULL,
          vod_pic TEXT,
          flag TEXT NOT NULL DEFAULT '',
          episode_name TEXT NOT NULL DEFAULT '',
          episode_id TEXT NOT NULL DEFAULT '',
          position_ms INTEGER NOT NULL DEFAULT 0,
          duration_ms INTEGER NOT NULL DEFAULT 0,
          completed INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL,
          UNIQUE(site_key, vod_id, flag, episode_id)
        );
      ''');
      legacy.execute(
        "INSERT INTO meta(key, value) VALUES('schema_version', '1');",
      );
      legacy.execute(
        'INSERT INTO configs(name, origin, json, updated_at) VALUES(?,?,?,?);',
        ['旧配置', 'http://example.com/old.json', '{"sites":[]}', 1],
      );
      legacy.execute(
        'INSERT INTO history(site_key, vod_id, vod_name, updated_at) '
        'VALUES(?,?,?,?);',
        ['csp_A', 'v1', '旧剧名', 1],
      );
      // `sqlite3` 的 Database.dispose() 已弃用但仍是当前 API 的一部分。
      // ignore: deprecated_member_use
      legacy.dispose();

      // 打开旧库：应自动建 TMDB 表且旧数据不变
      final opened = AppDatabase.open(path);
      expect(opened.succeeded, isTrue, reason: opened.error);
      final db = opened.database!;
      expect(db.count('configs'), 1);
      expect(db.count('history'), 1);
      for (final table in [
        'tmdb_matches',
        'tmdb_season_bindings',
        'tmdb_route_bindings',
        'tmdb_season_progress',
      ]) {
        expect(db.count(table), 0, reason: '$table 应已建立');
      }
      expect(db.schemaVersionValue, '${AppDatabase.schemaVersion}');
      db.dispose();

      // 再打开一次：仍然幂等
      final reopened = AppDatabase.open(path);
      expect(reopened.succeeded, isTrue);
      final again = reopened.database!;
      expect(again.count('configs'), 1);
      expect(again.count('history'), 1);
      again.dispose();
    });

    test('同路径重复打开不报错（幂等）', () {
      final path = p.join(tempDir.path, 'repeat.sqlite3');
      for (var i = 0; i < 3; i++) {
        final result = AppDatabase.open(path);
        expect(result.succeeded, isTrue, reason: '第 $i 次打开失败：${result.error}');
        result.database!.dispose();
      }
    });
  });

  group('匹配往返（§6.1）', () {
    test('upsert 后读回字段全等', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbMatch(
        configId: 1,
        siteKey: 'csp_A',
        vodId: 'v1',
        sourceTitle: '剧名',
        scope: 'scoped',
        tmdbId: 1399,
        mediaType: 'tv',
        title: '示例剧集',
        subtitle: '2024 · 8.2',
        overview: '简介',
        posterUrl: 'https://img/p.jpg',
        backdropUrl: 'https://img/b.jpg',
        credit: '演员',
        rating: 8.2,
        originalLanguage: 'zh',
        originCountry: 'CN',
        manual: true,
        manualTitles: ['剧名', '示例剧集'],
        matchedAt: 12345,
      );
      final row = db.findTmdbMatch(
        configId: 1,
        siteKey: 'csp_A',
        vodId: 'v1',
        sourceTitle: '剧名',
        scope: 'scoped',
      )!;
      expect(row['tmdb_id'], 1399);
      expect(row['media_type'], 'tv');
      expect(row['title'], '示例剧集');
      expect(row['subtitle'], '2024 · 8.2');
      expect(row['overview'], '简介');
      expect(row['poster_url'], 'https://img/p.jpg');
      expect(row['backdrop_url'], 'https://img/b.jpg');
      expect(row['credit'], '演员');
      expect(row['rating'], 8.2);
      expect(row['original_language'], 'zh');
      expect(row['origin_country'], 'CN');
      expect(row['manual'], 1);
      expect(row['manual_titles'], '剧名\u0001示例剧集');
      expect(row['matched_at'], 12345);
      db.dispose();
    });

    test('同键 upsert 覆盖而非新增', () {
      final db = AppDatabase.inMemory();
      for (var i = 0; i < 3; i++) {
        db.upsertTmdbMatch(
          configId: 1,
          siteKey: 's',
          vodId: 'v',
          sourceTitle: 't',
          scope: 'scoped',
          tmdbId: 100 + i,
          mediaType: 'tv',
          title: 'T$i',
        );
      }
      expect(db.count('tmdb_matches'), 1);
      expect(
        db.findTmdbMatch(
          configId: 1,
          siteKey: 's',
          vodId: 'v',
          sourceTitle: 't',
          scope: 'scoped',
        )!['tmdb_id'],
        102,
      );
      db.dispose();
    });

    test('条目级键（source_title 为空）与标题键互不干扰', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbMatch(
        configId: 1,
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '',
        scope: 'entry',
        tmdbId: 1,
        mediaType: 'tv',
        title: 'A',
      );
      db.upsertTmdbMatch(
        configId: 1,
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        scope: 'scoped',
        tmdbId: 2,
        mediaType: 'tv',
        title: 'B',
      );
      expect(db.count('tmdb_matches'), 2);
      expect(
        db.findTmdbMatch(
          configId: 1, siteKey: 's', vodId: 'v', sourceTitle: '', scope: 'entry',
        )!['tmdb_id'],
        1,
      );
      expect(
        db.findTmdbMatch(
          configId: 1, siteKey: 's', vodId: 'v', sourceTitle: '剧名', scope: 'scoped',
        )!['tmdb_id'],
        2,
      );
      db.dispose();
    });

    test('config_id 隔离', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbMatch(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', scope: 'scoped',
        tmdbId: 1, mediaType: 'tv', title: 'A',
      );
      expect(
        db.findTmdbMatch(
          configId: 2, siteKey: 's', vodId: 'v', sourceTitle: 't', scope: 'scoped',
        ),
        isNull,
      );
      db.dispose();
    });

    test('removeTmdbMatches 删除全部标题键', () {
      final db = AppDatabase.inMemory();
      for (final title in ['', 'A', 'B']) {
        db.upsertTmdbMatch(
          configId: 1, siteKey: 's', vodId: 'v', sourceTitle: title,
          scope: title.isEmpty ? 'entry' : 'scoped',
          tmdbId: 1, mediaType: 'tv', title: 'T',
        );
      }
      expect(db.count('tmdb_matches'), 3);
      expect(db.removeTmdbMatches(configId: 1, siteKey: 's', vodId: 'v'), 3);
      expect(db.count('tmdb_matches'), 0);
      db.dispose();
    });

    test('未命中返回 null', () {
      final db = AppDatabase.inMemory();
      expect(
        db.findTmdbMatch(
          configId: 1, siteKey: 'x', vodId: 'y', sourceTitle: 'z', scope: 'scoped',
        ),
        isNull,
      );
      db.dispose();
    });
  });

  group('季度绑定往返（§6.1）', () {
    test('manualSeason 往返', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbSeasonBinding(
        configId: 1,
        siteKey: 's',
        vodId: 'v',
        sourceTitle: 't',
        flagKey: 'f#0',
        tmdbId: 1399,
        mediaType: 'tv',
        mode: 'manualSeason',
        seasonNumber: 2,
        sourceFingerprint: 'fp',
        sourceEpisodeCount: 10,
        tmdbSeasonEpisodeCount: 10,
        version: 1,
        updatedAt: 999,
      );
      final row = db.findTmdbSeasonBinding(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
      )!;
      expect(row['mode'], 'manualSeason');
      expect(row['season_number'], 2);
      expect(row['tmdb_id'], 1399);
      expect(row['source_fingerprint'], 'fp');
      expect(row['source_episode_count'], 10);
      expect(row['tmdb_season_episode_count'], 10);
      expect(row['version'], 1);
      expect(row['updated_at'], 999);
      db.dispose();
    });

    test('manualFlat 的 season_number 为 NULL', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbSeasonBinding(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
        tmdbId: 1399, mediaType: 'tv', mode: 'manualFlat',
      );
      final row = db.findTmdbSeasonBinding(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
      )!;
      expect(row['season_number'], isNull);
      db.dispose();
    });

    test('manualMultiSlice 的 segments JSON 往返', () {
      final db = AppDatabase.inMemory();
      const segmentsJson =
          '[{"seasonNumber":1,"sourceEpisodeStartIndex":0,'
          '"sourceEpisodeEndIndex":2,"tmdbEpisodeStartNumber":1},'
          '{"seasonNumber":2,"sourceEpisodeStartIndex":3,'
          '"sourceEpisodeEndIndex":4,"tmdbEpisodeStartNumber":1}]';
      db.upsertTmdbSeasonBinding(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
        tmdbId: 1399, mediaType: 'tv', mode: 'manualMultiSlice',
        segments: segmentsJson,
      );
      final row = db.findTmdbSeasonBinding(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
      )!;
      expect(row['segments'], segmentsJson);
      db.dispose();
    });

    test('不同 flagKey 独立存储（线路级绑定）', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbSeasonBinding(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
        tmdbId: 1399, mediaType: 'tv', mode: 'manualSeason', seasonNumber: 1,
      );
      db.upsertTmdbSeasonBinding(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#1',
        tmdbId: 1399, mediaType: 'tv', mode: 'manualSeason', seasonNumber: 2,
      );
      expect(db.count('tmdb_season_bindings'), 2);
      expect(
        db.findTmdbSeasonBinding(
          configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
        )!['season_number'],
        1,
      );
      expect(
        db.findTmdbSeasonBinding(
          configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#1',
        )!['season_number'],
        2,
      );
      db.dispose();
    });

    test('removeTmdbSeasonBindings：按线路或按条目', () {
      final db = AppDatabase.inMemory();
      for (final flag in ['f#0', 'f#1']) {
        db.upsertTmdbSeasonBinding(
          configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: flag,
          tmdbId: 1399, mediaType: 'tv', mode: 'manualSeason', seasonNumber: 1,
        );
      }
      // 按线路删除
      expect(
        db.removeTmdbSeasonBindings(
          configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f#0',
        ),
        1,
      );
      expect(db.count('tmdb_season_bindings'), 1);
      // 按条目删除剩余
      expect(
        db.removeTmdbSeasonBindings(configId: 1, siteKey: 's', vodId: 'v'),
        1,
      );
      expect(db.count('tmdb_season_bindings'), 0);
      db.dispose();
    });
  });

  group('线路绑定索引（§5.5）', () {
    test('往返与查询', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbRouteBinding(
        configId: 1,
        siteKey: 's',
        vodId: 'v',
        flagKey: 'f#0',
        sourceFlag: '线路一',
        sourceFingerprint: 'fp',
        tmdbId: 1399,
        mediaType: 'tv',
        scopeKind: 'known',
        seasonNumbers: '[1]',
        updatedAt: 100,
      );
      final row = db.findTmdbRouteBinding(
        configId: 1, siteKey: 's', vodId: 'v', flagKey: 'f#0',
      )!;
      expect(row['source_flag'], '线路一');
      expect(row['scope_kind'], 'known');
      expect(row['season_numbers'], '[1]');
      expect(row['updated_at'], 100);
      db.dispose();
    });

    test('tmdbRouteBindingsFor 按 updated_at 降序', () {
      final db = AppDatabase.inMemory();
      for (var i = 0; i < 3; i++) {
        db.upsertTmdbRouteBinding(
          configId: 1, siteKey: 's', vodId: 'v$i', flagKey: 'f',
          sourceFlag: '线路$i', sourceFingerprint: 'fp',
          tmdbId: 1399, mediaType: 'tv', scopeKind: 'known',
          seasonNumbers: '[1]', updatedAt: 100 + i,
        );
      }
      final rows = db.tmdbRouteBindingsFor(
        configId: 1, tmdbId: 1399, mediaType: 'tv', seasonNumber: 1,
      );
      expect(rows.length, 3);
      expect(rows.first['updated_at'], 102);
      db.dispose();
    });

    test('容量上限：513 条淘汰到 512', () {
      final db = AppDatabase.inMemory();
      for (var i = 0; i < 513; i++) {
        db.upsertTmdbRouteBinding(
          configId: 1, siteKey: 's', vodId: 'v$i', flagKey: 'f',
          sourceFlag: '线路', sourceFingerprint: 'fp',
          tmdbId: 1399, mediaType: 'tv', scopeKind: 'known',
          seasonNumbers: '[1]', updatedAt: 1000 + i,
        );
      }
      expect(db.count('tmdb_route_bindings'), 513);
      final removed = db.trimTmdbRouteBindings();
      expect(removed, 1);
      expect(db.count('tmdb_route_bindings'), 512);
      // 最旧的（updatedAt=1000）被淘汰
      expect(
        db.findTmdbRouteBinding(
          configId: 1, siteKey: 's', vodId: 'v0', flagKey: 'f',
        ),
        isNull,
      );
      // 最新的仍在
      expect(
        db.findTmdbRouteBinding(
          configId: 1, siteKey: 's', vodId: 'v512', flagKey: 'f',
        ),
        isNotNull,
      );
      db.dispose();
    });

    test('未超上限时 trim 不删除', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbRouteBinding(
        configId: 1, siteKey: 's', vodId: 'v', flagKey: 'f',
        sourceFlag: '线路', sourceFingerprint: 'fp',
        tmdbId: 1399, mediaType: 'tv', scopeKind: 'known', seasonNumbers: '[1]',
      );
      expect(db.trimTmdbRouteBindings(), 0);
      expect(db.count('tmdb_route_bindings'), 1);
      db.dispose();
    });

    test('removeTmdbRouteBinding', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbRouteBinding(
        configId: 1, siteKey: 's', vodId: 'v', flagKey: 'f',
        sourceFlag: '线路', sourceFingerprint: 'fp',
        tmdbId: 1399, mediaType: 'tv', scopeKind: 'known', seasonNumbers: '[1]',
      );
      expect(
        db.removeTmdbRouteBinding(
          configId: 1, siteKey: 's', vodId: 'v', flagKey: 'f',
        ),
        1,
      );
      expect(db.count('tmdb_route_bindings'), 0);
      db.dispose();
    });
  });

  group('季度进度（§6.1/§6.2）', () {
    test('主键覆盖而非新增', () {
      final db = AppDatabase.inMemory();
      for (var i = 0; i < 3; i++) {
        db.upsertTmdbSeasonProgress(
          configId: 1,
          mediaType: 'tv',
          tmdbId: 1399,
          seasonNumber: 1,
          episodeNumber: i + 1,
          positionMs: 1000 * (i + 1),
        );
      }
      expect(db.count('tmdb_season_progress'), 1);
      final row = db.findTmdbSeasonProgress(
        configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: 1,
      )!;
      expect(row['episode_number'], 3);
      expect(row['position_ms'], 3000);
      db.dispose();
    });

    test('不同季度独立存储（播放另一季不覆盖）', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbSeasonProgress(
        configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: 1,
        episodeNumber: 5, positionMs: 111,
      );
      db.upsertTmdbSeasonProgress(
        configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: 2,
        episodeNumber: 3, positionMs: 222,
      );
      expect(db.count('tmdb_season_progress'), 2);
      expect(
        db.findTmdbSeasonProgress(
          configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: 1,
        )!['position_ms'],
        111,
        reason: 'S2 写入不得覆盖 S1',
      );
      db.dispose();
    });

    test('全部字段往返', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbSeasonProgress(
        configId: 1,
        mediaType: 'tv',
        tmdbId: 1399,
        seasonNumber: 1,
        episodeNumber: 2,
        positionMs: 12345,
        durationMs: 2700000,
        sourceFlag: '线路一',
        sourceEpisodeName: '第 2 集',
        sourceEpisodeUrl: 'https://cdn/e2.m3u8',
        sourceHistoryKey: 'csp_A@@@v1@@@线路一@@@e2',
        sourceBindingKey: 'csp_A@@@v1@@@f#0',
        updatedAt: 777,
      );
      final row = db.findTmdbSeasonProgress(
        configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: 1,
      )!;
      expect(row['episode_number'], 2);
      expect(row['position_ms'], 12345);
      expect(row['duration_ms'], 2700000);
      expect(row['source_flag'], '线路一');
      expect(row['source_episode_name'], '第 2 集');
      expect(row['source_episode_url'], 'https://cdn/e2.m3u8');
      expect(row['source_history_key'], 'csp_A@@@v1@@@线路一@@@e2');
      expect(row['source_binding_key'], 'csp_A@@@v1@@@f#0');
      expect(row['updated_at'], 777);
      db.dispose();
    });

    test('tmdbSeasonProgressFor 按季度升序', () {
      final db = AppDatabase.inMemory();
      for (final season in [3, 1, 2]) {
        db.upsertTmdbSeasonProgress(
          configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: season,
        );
      }
      final rows = db.tmdbSeasonProgressFor(
        configId: 1, mediaType: 'tv', tmdbId: 1399,
      );
      expect(rows.map((r) => r['season_number']), [1, 2, 3]);
      db.dispose();
    });

    test('tmdbSeasonProgressByHistory 按关联历史键查找', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbSeasonProgress(
        configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: 1,
        sourceHistoryKey: 'key-a',
      );
      db.upsertTmdbSeasonProgress(
        configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: 2,
        sourceHistoryKey: 'key-a',
      );
      final rows = db.tmdbSeasonProgressByHistory(
        configId: 1, sourceHistoryKey: 'key-a',
      );
      expect(rows.length, 2);
      expect(
        db.tmdbSeasonProgressByHistory(configId: 1, sourceHistoryKey: 'missing'),
        isEmpty,
      );
      db.dispose();
    });

    test('删除单季不影响其他季（§7.4）', () {
      final db = AppDatabase.inMemory();
      for (final season in [1, 2]) {
        db.upsertTmdbSeasonProgress(
          configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: season,
        );
      }
      expect(
        db.removeTmdbSeasonProgress(
          configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: 1,
        ),
        1,
      );
      expect(db.count('tmdb_season_progress'), 1);
      expect(
        db.findTmdbSeasonProgress(
          configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: 2,
        ),
        isNotNull,
        reason: 'S2 快照必须保留',
      );
      db.dispose();
    });

    test('删除整部节目清空全部季度（二级操作）', () {
      final db = AppDatabase.inMemory();
      for (final season in [1, 2, 3]) {
        db.upsertTmdbSeasonProgress(
          configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: season,
        );
      }
      expect(
        db.removeTmdbSeasonProgressForMedia(
          configId: 1, mediaType: 'tv', tmdbId: 1399,
        ),
        3,
      );
      expect(db.count('tmdb_season_progress'), 0);
      db.dispose();
    });

    test('clearTmdbSeasonProgress 清空但不动匹配与绑定（§6.5）', () {
      final db = AppDatabase.inMemory();
      db.upsertTmdbMatch(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', scope: 'scoped',
        tmdbId: 1399, mediaType: 'tv', title: 'T',
      );
      db.upsertTmdbSeasonBinding(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', flagKey: 'f',
        tmdbId: 1399, mediaType: 'tv', mode: 'manualSeason', seasonNumber: 1,
      );
      db.upsertTmdbSeasonProgress(
        configId: 1, mediaType: 'tv', tmdbId: 1399, seasonNumber: 1,
      );

      expect(db.clearTmdbSeasonProgress(), 1);
      expect(db.count('tmdb_season_progress'), 0);
      expect(
        db.count('tmdb_matches'),
        1,
        reason: '清空历史不得删除匹配结论',
      );
      expect(
        db.count('tmdb_season_bindings'),
        1,
        reason: '清空历史不得删除季度绑定',
      );
      db.dispose();
    });
  });

  group('写失败隔离（§6.6）', () {
    test('已关闭的数据库写入抛异常但不影响其他实例', () {
      final db = AppDatabase.inMemory();
      db.dispose();
      expect(
        () => db.upsertTmdbMatch(
          configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', scope: 'scoped',
          tmdbId: 1, mediaType: 'tv', title: 'T',
        ),
        throwsA(anything),
      );
      // 新实例正常工作
      final fresh = AppDatabase.inMemory();
      fresh.upsertTmdbMatch(
        configId: 1, siteKey: 's', vodId: 'v', sourceTitle: 't', scope: 'scoped',
        tmdbId: 1, mediaType: 'tv', title: 'T',
      );
      expect(fresh.count('tmdb_matches'), 1);
      fresh.dispose();
    });

    test('isHealthy 在正常库上为 true', () {
      final db = AppDatabase.inMemory();
      expect(db.isHealthy, isTrue);
      db.dispose();
    });
  });
}
