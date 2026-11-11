/// Phase 5 · 同步存储：合并路径、删除标记、schema 2→3 迁移
/// （`docs/phase5/design/02` §4.4 / §4.5）。
///
/// 对应门禁：`docs/phase5/README.md` §2.2「T6 存储：合并路径与删除标记
/// （`test/phase5_android_sync_test.dart` 合并矩阵 + `schemaVersion` 2→3 迁移）」。
///
/// 本套件验证**纯逻辑裁决落到真实 SQLite** 后的行为：
/// - 旧不覆盖新（不因同步倒退进度）；
/// - 幂等（重复推送不产生新行）；
/// - 删除后不复活（删除标记）；
/// - 同步写入使用**远端时间戳**（不是 `now()`）；
/// - 迁移幂等且旧库不丢数据。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/services/storage.dart';

/// 合并矩阵用例内部的固定时间戳（只用于相互比较，不参与与 `now()` 的裁决）。
const int kDefaultTime = 1791450000000;

/// 造一条远端（安卓）历史 JSON。
Map<String, Object?> remote({
  String siteKey = 'csp_Media',
  String vodId = 'demo-001',
  String vodName = '示例剧集',
  String vodPic = '',
  String flag = '线路一',
  String remarks = '第2集',
  String episodeUrl = 'http://h/ep-1.m3u8',
  int position = 754000,
  int duration = 2700000,
  int createTime = 1791450000000,
}) => {
  'key': '$siteKey@@@$vodId@@@1',
  'vodName': vodName,
  'vodPic': vodPic,
  'vodFlag': flag,
  'vodRemarks': remarks,
  'episodeUrl': episodeUrl,
  'position': position,
  'duration': duration,
  'createTime': createTime,
  'opening': -9223372036854775808,
  'ending': -9223372036854775808,
};

/// 走一次完整的「解析 → 裁决 → 落库」，返回统计。
SyncMergeStats sync(
  AppDatabase db,
  List<Map<String, Object?>> payload, {
  bool includeDeletions = true,
}) {
  final plan = buildHistoryMergePlan(
    parsed: SyncHistoryParseResult.parse(payload),
    localByMatchKey: db.historySyncIndex(),
    deletedAtByMatchKey: includeDeletions
        ? db.historyDeletionIndex()
        : const {},
  );
  return db.applyHistoryMerge(plan);
}

void main() {
  group('schema 迁移（2 → 当前版本；Phase 5 删除标记 + Phase 9 增强 + 播放源身份 + 历史作品身份 + 收藏海报 + AI 季集映射）', () {
    test('schemaVersion 不低于 9（Task5 起为 10），且 history_deletions/following 表存在', () {
      expect(AppDatabase.schemaVersion, greaterThanOrEqualTo(9));
      final db = AppDatabase.inMemory();
      expect(db.schemaVersionValue, '${AppDatabase.schemaVersion}');
      expect(db.count('history_deletions'), 0);
      expect(db.rowCounts().containsKey('history_deletions'), isTrue);
      expect(db.rowCounts().containsKey('following'), isTrue);
      db.dispose();
    });

    test('迁移幂等：重复打开同一文件不报错、不重复建表', () {
      final tempDir = Directory.systemTemp.createTempSync('phase5-migrate-');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final path = p.join(tempDir.path, 'sync.sqlite3');

      for (var round = 0; round < 3; round++) {
        final opened = AppDatabase.open(path);
        expect(opened.succeeded, isTrue, reason: opened.error);
        final db = opened.database!;
        expect(db.schemaVersionValue, '${AppDatabase.schemaVersion}');
        expect(db.count('history_deletions'), 0);
        db.dispose();
      }
    });

    test('Phase 4 时代的旧库（version 2）打开后获得删除标记表且历史完好', () {
      final tempDir = Directory.systemTemp.createTempSync('phase5-legacy-');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final path = p.join(tempDir.path, 'legacy-v2.sqlite3');

      // 构造「Phase 4 时代」的库：老表 + schema_version=2，无删除标记表。
      final legacy = sqlite3.open(path);
      legacy.execute('''
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
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
      legacy.execute("INSERT INTO meta(key, value) VALUES('schema_version', '2');");
      legacy.execute(
        'INSERT INTO history(site_key, vod_id, vod_name, flag, episode_id, '
        'position_ms, duration_ms, updated_at) VALUES(?,?,?,?,?,?,?,?);',
        ['csp_Old', 'v1', '旧剧名', '线路一', 'http://h/old.m3u8', 1000, 2000, 111],
      );
      // ignore: deprecated_member_use
      legacy.dispose();

      final opened = AppDatabase.open(path);
      expect(opened.succeeded, isTrue, reason: opened.error);
      final db = opened.database!;
      expect(db.count('history'), 1, reason: '旧数据必须完好');
      expect(db.count('history_deletions'), 0);
      expect(db.schemaVersionValue, '${AppDatabase.schemaVersion}');

      // 旧历史能正常参与合并（不是只建了表但索引不可用）。
      expect(db.historySyncIndex(), hasLength(1));
      db.dispose();
    });

    test('v8 旧库的收藏表打开后补上 vod_pic 列，旧行海报为空串', () {
      final tempDir = Directory.systemTemp.createTempSync('phase5-favorite-v8-');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final path = p.join(tempDir.path, 'legacy-v8.sqlite3');

      final legacy = sqlite3.open(path);
      legacy.execute('''
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      ''');
      legacy.execute('''
        CREATE TABLE favorites (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          kind TEXT NOT NULL,
          site_key TEXT NOT NULL,
          target_id TEXT NOT NULL,
          title TEXT NOT NULL,
          subtitle TEXT,
          updated_at INTEGER NOT NULL,
          UNIQUE(kind, site_key, target_id)
        );
      ''');
      legacy.execute(
        "INSERT INTO meta(key, value) VALUES('schema_version', '8');",
      );
      legacy.execute(
        'INSERT INTO favorites(kind, site_key, target_id, title, subtitle, '
        "updated_at) VALUES('vod','k','v1','旧收藏','全12集',111);",
      );
      // ignore: deprecated_member_use
      legacy.dispose();

      final opened = AppDatabase.open(path);
      expect(opened.succeeded, isTrue, reason: opened.error);
      final db = opened.database!;
      final favorites = db.listFavorites();
      expect(favorites, hasLength(1), reason: '旧收藏不能丢');
      expect(favorites.first.title, '旧收藏');
      expect(favorites.first.vodPic, '', reason: 'v8 收藏没有海报，升级后为空串');
      expect(db.schemaVersionValue, '${AppDatabase.schemaVersion}');
      db.dispose();
    });
  });

  group('同步写入的合并矩阵（design/02 §4.4）', () {
    test('本地无 → 插入；写入使用远端时间戳而不是 now()', () {
      final db = AppDatabase.inMemory();
      final stats = sync(db, [remote(createTime: kDefaultTime)]);
      expect(stats.applied, 1);
      expect(stats.total, 1);
      expect(stats.isConsistent, isTrue);

      final rows = db.recentHistory();
      expect(rows, hasLength(1));
      expect(rows.first.positionMs, 754000);
      expect(
        rows.first.updatedAt,
        1791450000000,
        reason: '必须落远端 createTime，否则下一轮"旧不覆盖新"会失真',
      );
      db.dispose();
    });

    test('远端更新 → 覆盖；重复推送 → 幂等全部 skipped', () {
      final db = AppDatabase.inMemory();
      sync(db, [remote(createTime: kDefaultTime, position: 1000)]);
      final applied = sync(db, [
        remote(createTime: 1791460000000, position: 900000),
      ]);
      expect(applied.applied, 1);
      expect(db.recentHistory().first.positionMs, 900000);

      // 同一条再推两次：必须全部 skipped，且仍只有 1 行。
      for (var round = 0; round < 2; round++) {
        final repeated = sync(db, [
          remote(createTime: 1791460000000, position: 900000),
        ]);
        expect(repeated.applied, 0);
        expect(repeated.skipped, 1);
        expect(repeated.isConsistent, isTrue);
      }
      expect(db.count('history'), 1);
      db.dispose();
    });

    test('远端更旧 → 跳过，本地进度不倒退', () {
      final db = AppDatabase.inMemory();
      sync(db, [remote(createTime: 1791460000000, position: 1200000)]);
      final older = sync(db, [
        remote(createTime: 1791400000000, position: 5000),
      ]);
      expect(older.skipped, 1);
      expect(older.applied, 0);
      expect(db.recentHistory().first.positionMs, 1200000);
      db.dispose();
    });

    test('解析失败条目计入 failed，且不变式 applied+skipped+failed==total', () {
      final db = AppDatabase.inMemory();
      final stats = sync(db, [
        {'key': 'broken'},
        remote(),
        remote(vodId: 'demo-002', episodeUrl: 'http://h/ep-2.m3u8'),
      ]);
      expect(stats.failed, 1);
      expect(stats.applied, 2);
      expect(stats.total, 3);
      expect(stats.isConsistent, isTrue);
      expect(db.count('history'), 2, reason: '单条失败不回滚整批');
      db.dispose();
    });

    test('completed 由 PC 规则重算（position >= duration - 5000）', () {
      final db = AppDatabase.inMemory();
      sync(db, [remote(position: 2700000, duration: 2700000)]);
      expect(db.recentHistory().first.completed, isTrue);

      sync(db, [
        remote(
          episodeUrl: 'http://h/ep-9.m3u8',
          position: 100000,
          duration: 2700000,
          createTime: 1791470000000,
        ),
      ]);
      final partial = db
          .recentHistory()
          .firstWhere((row) => row.episodeId == 'http://h/ep-9.m3u8');
      expect(partial.completed, isFalse);
      db.dispose();
    });

    test('siteKey/vodId/flag/episodeId 任一不同即视为不同记录', () {
      final db = AppDatabase.inMemory();
      sync(db, [
        remote(),
        remote(flag: '线路二', episodeUrl: 'http://h/ep-1b.m3u8'),
        remote(episodeUrl: 'http://h/ep-2.m3u8'),
        remote(siteKey: 'csp_Other', episodeUrl: 'http://h/ep-3.m3u8'),
      ]);
      expect(db.count('history'), 4);
      db.dispose();
    });
  });

  group('删除标记（design/02 §4.5）', () {
    test('删单条后远端旧记录不复活；远端新记录可恢复', () {
      // 时间戳必须**相对当前时刻**构造：删除标记写的是 `now()`，
      // 用写死的绝对时间戳会让用例在某些时刻（绝对时间戳比 now 更晚时）假失败。
      final now = DateTime.now().millisecondsSinceEpoch;
      const day = 24 * 60 * 60 * 1000;
      final db = AppDatabase.inMemory();
      sync(db, [remote(createTime: now - day)]);
      final row = db.recentHistory().first;
      db.deleteHistory(row.id);
      expect(db.count('history'), 0);
      expect(db.historyDeletionCount, 1, reason: '删除必须留下标记');
      expect(db.historyDeletionIndex(), hasLength(1));

      // 远端仍持有一条更旧的 → 不得复活。
      final resurrect = sync(db, [remote(createTime: now - 2 * day)]);
      expect(resurrect.applied, 0);
      expect(resurrect.skipped, 1);
      expect(db.count('history'), 0, reason: '被删除的记录不得复活');

      // 用户又在安卓上看了（时间戳更新）→ 应恢复。
      final revived = sync(db, [
        remote(createTime: now + 60 * 1000, position: 1500000),
      ]);
      expect(revived.applied, 1);
      expect(db.count('history'), 1);
      expect(db.recentHistory().first.positionMs, 1500000);
      // 写入后标记被清掉，避免表无界增长。
      expect(db.historyDeletionCount, 0);
      db.dispose();
    });

    test('清空历史同样留下标记，语义上等价于逐条删除', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      const day = 24 * 60 * 60 * 1000;
      final db = AppDatabase.inMemory();
      sync(db, [
        remote(createTime: now - day),
        remote(createTime: now - day, episodeUrl: 'http://h/ep-2.m3u8'),
      ]);
      expect(db.count('history'), 2);
      db.clearHistory();
      expect(db.count('history'), 0);
      expect(db.historyDeletionCount, 2, reason: '清空后旧记录同样不得被同步复活');

      final resurrect = sync(db, [
        remote(createTime: now - 2 * day),
        remote(createTime: now - 2 * day, episodeUrl: 'http://h/ep-2.m3u8'),
      ]);
      expect(resurrect.applied, 0);
      expect(resurrect.skipped, 2);
      expect(db.count('history'), 0);
      db.dispose();
    });

    test('本地仍有记录时删除标记不再拦截（用户后来又看了）', () {
      final db = AppDatabase.inMemory();
      sync(db, [remote(createTime: 1791460000000, position: 2000000)]);
      // 直接写入一个标记（模拟"删过、但后来本地又有了"的残留形态）。
      db.deleteHistory(db.recentHistory().first.id);
      db.upsertHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        vodName: '示例剧集',
        flag: '线路一',
        episodeName: '第3集',
        episodeId: 'http://h/ep-1.m3u8',
        positionMs: 1000,
        durationMs: 2700000,
        updatedAt: 1791450000000,
      );
      // upsert 已清掉标记，旧远端记录仍不得覆盖本地。
      expect(db.historyDeletionCount, 0);
      final older = sync(db, [remote(createTime: 1791400000000)]);
      expect(older.skipped, 1);
      expect(db.recentHistory().first.episodeName, '第3集');
      db.dispose();
    });

    test('同步路径不产生任何 DELETE（P3：禁止清表式合并）', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      const day = 24 * 60 * 60 * 1000;
      final db = AppDatabase.inMemory();
      sync(db, [
        remote(createTime: now + day, position: 2000000),
        remote(episodeUrl: 'http://h/ep-2.m3u8', createTime: now + day),
      ]);
      // 推一批更旧的、以及两条无法解析的：都不应删除任何东西。
      final stats = sync(db, [
        remote(createTime: now - day, position: 1),
        {'key': 'broken-1'},
        {'key': 'broken-2'},
      ]);
      expect(stats.skipped, 1);
      expect(stats.failed, 2);
      expect(stats.isConsistent, isTrue);
      expect(db.count('history'), 2, reason: '合并不得清表');
      // 旧记录的进度没有被改回去。
      expect(db.recentHistory().first.positionMs, 2000000);
      db.dispose();
    });
  });

  group('历史作品身份列：只加法迁移、只由真实值覆盖（design/05 §4）', () {
    test('三列存在，旧行升级后身份为空（不回填猜测的 TMDB）', () {
      final db = AppDatabase.inMemory();
      db.upsertHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        vodName: '示例剧集',
        flag: '线路一',
        episodeName: '第1集',
        episodeId: 'http://h/ep-1.m3u8',
        positionMs: 1000,
        durationMs: 2700000,
        updatedAt: kDefaultTime,
      );
      final row = db.recentHistory().single;
      expect(row.vodYear, '');
      expect(row.tmdbId, 0);
      expect(row.mediaType, '');
      expect(row.hasTmdbIdentity, isFalse);
      db.dispose();
    });

    test('后续写入不带身份时，已有的身份不被抹掉', () {
      final db = AppDatabase.inMemory();
      void write({String vodYear = '', int tmdbId = 0, String mediaType = ''}) {
        db.upsertHistory(
          siteKey: 'csp_Media',
          vodId: 'demo-001',
          vodName: '示例剧集',
          flag: '线路一',
          episodeName: '第1集',
          episodeId: 'http://h/ep-1.m3u8',
          positionMs: 1000,
          durationMs: 2700000,
          updatedAt: kDefaultTime,
          vodYear: vodYear,
          tmdbId: tmdbId,
          mediaType: mediaType,
        );
      }

      // 播放器写入真实身份（player_page 的 _persistProgress 传的就是这两个值）。
      write(vodYear: '2024', tmdbId: 1399, mediaType: 'tv');
      var row = db.recentHistory().single;
      expect(row.vodYear, '2024');
      expect(row.tmdbId, 1399);
      expect(row.mediaType, 'tv');

      // 安卓推来的记录不带身份：位置前进，身份必须保留。
      write();
      row = db.recentHistory().single;
      expect(row.vodYear, '2024', reason: '同步记录没有年份，不得抹掉本地已绑定的年份');
      expect(row.tmdbId, 1399, reason: 'TMDB 0 表示「不知道」，不是「清空」');
      expect(row.mediaType, 'tv');

      // 拿到新的真实身份时照常覆盖（用户换了匹配结果）。
      write(vodYear: '2025', tmdbId: 550, mediaType: 'movie');
      row = db.recentHistory().single;
      expect(row.tmdbId, 550);
      expect(row.mediaType, 'movie');
      expect(row.vodYear, '2025');
      db.dispose();
    });

    test('媒体类型只认 movie/tv：大小写归一，坏值落库为空串', () {
      final db = AppDatabase.inMemory();
      db.upsertHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        vodName: '示例剧集',
        flag: '线路一',
        episodeName: '第1集',
        episodeId: 'http://h/ep-1.m3u8',
        positionMs: 1000,
        durationMs: 2700000,
        updatedAt: kDefaultTime,
        tmdbId: 1399,
        mediaType: 'TV',
      );
      // 大小写不敏感（`normalizeMediaTypeValue` 先 toLowerCase），但落库统一小写。
      final row = db.recentHistory().single;
      expect(row.mediaType, 'tv');
      expect(row.hasTmdbIdentity, isTrue);

      // 不认识的类型收敛为空串：留个坏值会让聚合键分裂出第三种命名空间
      // （tmdb|TV|1399 与 tmdb|tv|1399 是两张卡）。
      db.upsertHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        vodName: '示例剧集',
        flag: '线路一',
        episodeName: '第1集',
        episodeId: 'http://h/ep-1.m3u8',
        positionMs: 1000,
        durationMs: 2700000,
        updatedAt: kDefaultTime + 1,
        tmdbId: 1399,
        mediaType: 'person',
      );
      final bad = db.recentHistory().single;
      expect(bad.mediaType, 'tv', reason: '坏值不覆盖已有的合法身份');
      expect(normalizeMediaTypeValue('person'), '');
      expect(normalizeMediaTypeValue(' Movie '), 'movie');
      db.dispose();
    });
  });

  group('同步索引与删除标记索引（design/02 §4.3）', () {
    test('historySyncIndex 以 (siteKey,vodId,flag,episodeId) 为键', () {
      final db = AppDatabase.inMemory();
      sync(db, [
        remote(),
        remote(flag: '线路二', episodeUrl: 'http://h/ep-1b.m3u8'),
      ]);
      final index = db.historySyncIndex();
      expect(index, hasLength(2));
      final item = SyncHistoryItem.fromLocal(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        vodName: '任意',
        flag: '线路一',
        episodeName: '',
        episodeId: 'http://h/ep-1.m3u8',
        positionMs: 0,
        durationMs: 0,
        updatedAt: 0,
      );
      expect(index.containsKey(item.matchKey), isTrue);
    });

    test('空库的索引与标记都是空集合', () {
      final db = AppDatabase.inMemory();
      expect(db.historySyncIndex(), isEmpty);
      expect(db.historyDeletionIndex(), isEmpty);
      expect(db.historyDeletionCount, 0);
      db.dispose();
    });
  });
}
