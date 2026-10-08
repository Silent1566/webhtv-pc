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
  group('schema 2 → 3 迁移（design/02 §4.5）', () {
    test('schemaVersion 为 3，且 history_deletions 表存在', () {
      expect(AppDatabase.schemaVersion, 3);
      final db = AppDatabase.inMemory();
      expect(db.schemaVersionValue, '3');
      expect(db.count('history_deletions'), 0);
      expect(db.rowCounts().containsKey('history_deletions'), isTrue);
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
        expect(db.schemaVersionValue, '3');
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
      expect(db.schemaVersionValue, '3');

      // 旧历史能正常参与合并（不是只建了表但索引不可用）。
      expect(db.historySyncIndex(), hasLength(1));
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
