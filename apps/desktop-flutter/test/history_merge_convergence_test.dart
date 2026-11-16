/// 同 `updatedAt` 冲突的**规范化收敛**（PC 侧合并语义）。
///
/// 背景：`decideHistoryMerge` 原先对"时间戳相同"一律 skip，胜负取决于
/// **谁先落地**——A←B 与 B←A 会各自保留自己那一份；同一批内的重复
/// `matchKey` 也会退化成"后写者胜"。本套件锁的是修正后的性质：
///
/// 1. **交换性**：A←B 与 B←A 得到同一条有效记录；
/// 2. **批内顺序无关**：同一批里同 `matchKey` 的多条，反序批得到同一赢家；
/// 3. **幂等**：同一批连推两次，第二次全部 `skipped`，行数不变；
/// 4. **统计不变式**：`applied + skipped + failed == total`（批内合并后仍成立）；
/// 5. **无震荡**：`cid` 别名、`vodPic` 空串归一、`opening/ending` 哨兵值
///    都不产生重复写入；
/// 6. **不回归**：新/旧时间戳裁决、墓碑（删除标记）与 `sourceKey` 隔离。
///
/// **声明范围**：这里锁的是 **PC 侧合并行为**；对端安卓未被修改，它的
/// 落地顺序仍由它自己决定。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/services/storage.dart';

/// 所有用例共用的时间戳（只用于相互比较）。
const int t0 = 1791450000000;

/// 造一条对端（安卓 `History`）JSON。
Map<String, Object?> peerJson({
  String key = 'csp_Media@@@demo-001@@@1',
  String vodName = '示例剧集',
  String vodPic = '',
  String vodFlag = '线路一',
  String vodRemarks = '第2集',
  String episodeUrl = 'http://h/ep-1.m3u8',
  int position = 900000,
  int duration = 2700000,
  int createTime = t0,
  Object? opening,
  Object? ending,
}) => {
  'key': key,
  'vodName': vodName,
  'vodPic': vodPic,
  'vodFlag': vodFlag,
  'vodRemarks': vodRemarks,
  'episodeUrl': episodeUrl,
  'position': position,
  'duration': duration,
  'createTime': createTime,
  'opening': ?opening,
  'ending': ?ending,
};

/// 从 JSON 解析一条记录，解析失败即测试失败。
SyncHistoryItem item(Map<String, Object?> json) {
  final parsed = SyncHistoryItem.tryFromJson(json);
  expect(parsed, isNotNull, reason: '期望可解析：$json');
  return parsed!;
}

AppDatabase freshDb() {
  final db = AppDatabase.inMemory();
  addTearDown(db.dispose);
  return db;
}

/// 走一次完整的「解析 → 裁决 → 落库」，并要求统计闭合。
SyncMergeStats sync(
  AppDatabase db,
  List<Object?> payload, {
  String sourceKey = '',
}) {
  final plan = buildHistoryMergePlan(
    parsed: SyncHistoryParseResult.parse(payload),
    localByMatchKey: db.historySyncIndex(sourceKey: sourceKey),
    deletedAtByMatchKey: db.historyDeletionIndex(sourceKey: sourceKey),
  );
  final stats = db.applyHistoryMerge(plan, sourceKey: sourceKey);
  expect(stats.isConsistent, isTrue, reason: stats.describe());
  return stats;
}

/// 一条落库记录的「有效内容」，用于比较两个库是否收敛到同一条。
String effective(AppDatabase db, {String episodeId = 'http://h/ep-1.m3u8'}) {
  final rows = db.recentHistory().where((row) => row.episodeId == episodeId);
  expect(rows, hasLength(1), reason: '同一 matchKey 只允许一行');
  final row = rows.single;
  return [
    row.siteKey,
    row.vodId,
    row.flag,
    row.episodeId,
    '${row.positionMs}',
    '${row.durationMs}',
    '${row.updatedAt}',
    '${row.completed}',
    row.vodName,
    row.episodeName,
    row.vodPic ?? '(null)',
  ].join('|');
}

void main() {
  group('同一时间戳冲突的规范化裁决（与到达顺序无关）', () {
    test('A←B 与 B←A 收敛到同一条记录', () {
      // 同 ts、内容不同：先进 vs 更靠后的进度。
      final early = peerJson(position: 300000);
      final late = peerJson(position: 1500000);

      final dbA = freshDb();
      sync(dbA, [early]);
      sync(dbA, [late]);
      final aWins = effective(dbA);

      final dbB = freshDb();
      sync(dbB, [late]);
      sync(dbB, [early]);
      final bWins = effective(dbB);

      expect(aWins, bWins, reason: '到达顺序不得决定胜者');
      expect(aWins, contains('1500000'), reason: '更靠后的进度按规范化排序胜出');
    });

    test('同一方向重复应用是幂等的（胜者固定点）', () {
      final early = peerJson(position: 300000);
      final late = peerJson(position: 1500000);
      final db = freshDb();
      sync(db, [early]);
      sync(db, [late]);
      final settled = effective(db);

      for (var round = 0; round < 3; round++) {
        final repeated = sync(db, [late]);
        expect(repeated.applied, 0, reason: '收敛后再推同一份内容必须 skip');
        expect(repeated.skipped, 1);
      }
      expect(effective(db), settled);
      expect(db.count('history'), 1);
    });

    test('内容完全等价 → skip（幂等），不因规范化排序误判为分歧', () {
      final local = peerJson(position: 900000);
      final db = freshDb();
      sync(db, [local]);
      final again = sync(db, [peerJson(position: 900000)]);
      expect(again.applied, 0);
      expect(again.skipped, 1);
      expect(again.isConsistent, isTrue);
    });

    for (final (field, low, high) in [
      ('duration', 2700000, 3000000),
      ('vodName', 'A', 'Z'),
      ('vodRemarks', '第1集', '第2集'),
      ('vodPic', 'http://h/a.jpg', 'http://h/z.jpg'),
    ]) {
      test('同时间戳仅 $field 分歧时取固定序最大，两个方向收敛', () {
        final a = <String, Object?>{...peerJson(), field: low};
        final b = <String, Object?>{...peerJson(), field: high};
        final dbA = freshDb();
        sync(dbA, [a]);
        final update = sync(dbA, [b]);
        expect(update.applied, 1);

        final dbB = freshDb();
        sync(dbB, [b]);
        final retain = sync(dbB, [a]);
        expect(retain.applied, 0);
        expect(retain.skipped, 1);
        expect(effective(dbA), effective(dbB));
        expect(
          dbA.historySyncIndex().values.single.toAndroidJson()[field],
          high,
        );
      });
    }

    test('裁决本身是反对称的：decideHistoryMerge 两个方向结论互斥', () {
      final a = item(peerJson(position: 300000));
      final b = item(peerJson(position: 1500000));
      final ab = decideHistoryMerge(incoming: b, local: a);
      final ba = decideHistoryMerge(incoming: a, local: b);
      expect(ab.action, SyncMergeAction.upsert);
      expect(ba.action, SyncMergeAction.skip);
      expect(ba.reason, contains('本地'));
    });
  });

  group('批内同 matchKey 重复条目的顺序无关性', () {
    test('反序批得到同一赢家，且统计闭合', () {
      final low = peerJson(position: 200000);
      final high = peerJson(position: 1600000);

      final db1 = freshDb();
      final forward = sync(db1, [low, high]);
      final forwardWinner = effective(db1);

      final db2 = freshDb();
      final backward = sync(db2, [high, low]);
      final backwardWinner = effective(db2);

      expect(forwardWinner, backwardWinner, reason: '批内顺序不得决定赢家');
      expect(forwardWinner, contains('1600000'));
      expect(forward.applied, 1, reason: '同 matchKey 只写一条');
      expect(forward.skipped, 1, reason: '被淘汰的那条计入 skipped');
      expect(backward.applied, 1);
      expect(backward.skipped, 1);
      expect(forward.isConsistent, isTrue);
      expect(backward.isConsistent, isTrue);
      expect(db1.count('history'), 1);
      expect(db2.count('history'), 1);

      final repeated = sync(db1, [low, high]);
      expect(repeated.applied, 0);
      expect(repeated.skipped, 2);
      expect(effective(db1), forwardWinner);
    });

    test('批内重复 + 本地已有 → 一律覆盖为规范化赢家（不是后写者赢）', () {
      final db = freshDb();
      sync(db, [peerJson(position: 100000)]);

      // 顺序 A：低进度在前，高进度在后。
      final planA = buildHistoryMergePlan(
        parsed: SyncHistoryParseResult.parse([
          peerJson(position: 400000),
          peerJson(position: 1800000),
        ]),
        localByMatchKey: db.historySyncIndex(),
      );
      expect(planA.applied, hasLength(1));
      expect(planA.applied.single.positionMs, 1800000);
      expect(planA.skipped, 1);
      expect(planA.stats.isConsistent, isTrue);

      // 顺序 B：反序，赢家必须相同。
      final planB = buildHistoryMergePlan(
        parsed: SyncHistoryParseResult.parse([
          peerJson(position: 1800000),
          peerJson(position: 400000),
        ]),
        localByMatchKey: db.historySyncIndex(),
      );
      expect(planB.applied, hasLength(1));
      expect(planB.applied.single.positionMs, 1800000);
      expect(planB.skipped, 1);
    });

    test('批内新旧时间戳混合：更新优先于进度大小，反序仍相同', () {
      final older = peerJson(position: 2000000, createTime: t0);
      final newer = peerJson(position: 100000, createTime: t0 + 1);
      for (final payload in [
        [older, newer],
        [newer, older],
      ]) {
        final db = freshDb();
        final stats = sync(db, payload);
        expect(stats.applied, 1);
        expect(stats.skipped, 1);
        expect(db.recentHistory().single.positionMs, 100000);
        expect(db.recentHistory().single.updatedAt, t0 + 1);
      }
    });

    test('批内三份同 matchKey + 一条解析失败：统计仍闭合', () {
      final db = freshDb();
      final stats = sync(db, [
        peerJson(position: 500000),
        {'key': 'broken'},
        peerJson(position: 1900000),
        peerJson(position: 700000),
      ]);
      expect(stats.applied, 1);
      expect(stats.skipped, 2);
      expect(stats.failed, 1);
      expect(stats.total, 4);
      expect(stats.isConsistent, isTrue);
      expect(db.count('history'), 1);
      expect(db.recentHistory().single.positionMs, 1900000);
    });

    test('批内不同 matchKey 的条目不受合并影响（各自独立写入）', () {
      final db = freshDb();
      final stats = sync(db, [
        peerJson(episodeUrl: 'http://h/ep-1.m3u8', position: 100000),
        peerJson(episodeUrl: 'http://h/ep-2.m3u8', position: 200000),
        peerJson(episodeUrl: 'http://h/ep-1.m3u8', position: 1100000),
      ]);
      expect(stats.applied, 2);
      expect(stats.skipped, 1);
      expect(stats.isConsistent, isTrue);
      expect(db.count('history'), 2);
    });
  });

  group('Key 别名与归一化字段不产生震荡', () {
    test('cid 1 / cid 9 是同一条：往返后仍 skip', () {
      final db = freshDb();
      sync(db, [peerJson(key: 'csp_Media@@@demo-001@@@1')]);
      final alias = sync(db, [peerJson(key: 'csp_Media@@@demo-001@@@9')]);
      expect(alias.applied, 0, reason: 'cid 是安卓侧别名，不得当身份');
      expect(alias.skipped, 1);
      expect(db.count('history'), 1);
    });

    test('vodPic 空串 ↔ null 归一后不产生重复写入', () {
      final db = freshDb();
      sync(db, [peerJson(vodPic: '')]);
      final settled = effective(db);

      final again = sync(db, [peerJson(vodPic: '')]);
      expect(again.applied, 0);
      expect(effective(db), settled);
      expect(db.count('history'), 1);
    });

    test('opening/ending 哨兵值不参与裁决（同步写入本就不落库）', () {
      final db = freshDb();
      sync(db, [peerJson(position: 900000)]);
      final stats = sync(db, [
        peerJson(
          position: 900000,
          opening: -9223372036854775808,
          ending: -9223372036854775808,
        ),
      ]);
      expect(stats.applied, 0, reason: '哨兵值差异不得触发覆盖');
      expect(stats.skipped, 1);

      // 有真实值也同理：这些字段不落库，纳入裁决会造成每轮反复写入。
      final withRealValues = sync(db, [
        peerJson(position: 900000, opening: 30000, ending: 100000),
      ]);
      expect(withRealValues.applied, 0);
      expect(withRealValues.skipped, 1);
      expect(db.count('history'), 1);
    });

    test('SQLite → Android JSON → SQLite 三轮仍稳定（归一化与别名）', () {
      final db = freshDb();
      final original = <String, Object?>{
        ...peerJson(position: 1200000, opening: 30000, ending: 40000),
        'key': ' csp_Media @@@ demo-001 @@@9',
        'position': '1200000.0',
        'duration': '2700000',
        'createTime': '$t0',
        'vodPic': '  ',
        'speed': 1.5,
        'player': 2,
        'tmdbId': 1399,
      };
      sync(db, [original]);
      final settled = effective(db);

      for (var round = 0; round < 3; round++) {
        final exported = db.historySyncIndex().values.single.toAndroidJson();
        expect(exported['key'], 'csp_Media@@@demo-001@@@0');
        expect(exported['position'], 1200000);
        expect(exported['vodPic'], '');
        final stats = sync(db, [jsonDecode(jsonEncode(exported))]);
        expect(stats.applied, 0);
        expect(stats.skipped, 1);
        final alias = sync(db, [original]);
        expect(alias.applied, 0);
        expect(alias.skipped, 1);
      }
      expect(effective(db), settled);
      expect(db.count('history'), 1);
    });
  });

  group('新/旧时间戳与墓碑不回归', () {
    test('远端更新 → 覆盖（规范化排序不干扰时间戳优先）', () {
      final db = freshDb();
      sync(db, [peerJson(position: 1600000, createTime: t0)]);
      // 进度更小但时间更新 → 仍必须胜出。
      final applied = sync(db, [
        peerJson(position: 400000, createTime: t0 + 1),
      ]);
      expect(applied.applied, 1);
      expect(db.recentHistory().single.positionMs, 400000);
    });

    test('远端更旧 → skip，本地进度不倒退', () {
      final db = freshDb();
      sync(db, [peerJson(position: 1600000, createTime: t0 + 1)]);
      final older = sync(db, [peerJson(position: 5000, createTime: t0)]);
      expect(older.applied, 0);
      expect(older.skipped, 1);
      expect(db.recentHistory().single.positionMs, 1600000);
    });

    test('删除标记：远端更旧不复活；远端更新可恢复', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      const day = 24 * 60 * 60 * 1000;
      final db = freshDb();
      sync(db, [peerJson(createTime: now - day)]);
      db.deleteHistory(db.recentHistory().single.id);
      expect(db.count('history'), 0);

      final resurrect = sync(db, [peerJson(createTime: now - 2 * day)]);
      expect(resurrect.applied, 0);
      expect(resurrect.skipped, 1);
      expect(db.count('history'), 0, reason: '更旧的记录不得复活已删除条目');

      final restore = sync(db, [peerJson(createTime: now + day)]);
      expect(restore.applied, 1);
      expect(db.count('history'), 1);
    });

    test('删除标记按 matchKey 生效：同批另一集不受影响', () {
      final db = freshDb();
      final now = DateTime.now().millisecondsSinceEpoch;
      sync(db, [
        peerJson(episodeUrl: 'http://h/ep-1.m3u8', createTime: now - 1000),
        peerJson(episodeUrl: 'http://h/ep-2.m3u8', createTime: now - 1000),
      ]);
      final target = db.recentHistory().firstWhere(
        (row) => row.episodeId == 'http://h/ep-1.m3u8',
      );
      db.deleteHistory(target.id);

      final stats = sync(db, [
        peerJson(episodeUrl: 'http://h/ep-1.m3u8', createTime: now - 5000),
        // 另一集：新时间戳，必须正常落地。
        peerJson(episodeUrl: 'http://h/ep-2.m3u8', createTime: now + 5000),
      ]);
      expect(stats.applied, 1);
      expect(stats.skipped, 1);
      expect(stats.isConsistent, isTrue);
      expect(db.count('history'), 1);
    });

    test('sourceKey 隔离：一源墓碑不拦截另一源同 matchKey', () {
      final db = freshDb();
      final now = DateTime.now().millisecondsSinceEpoch;
      final old = peerJson(position: 100000, createTime: now - 10000);
      sync(db, [old], sourceKey: 'dev-a');
      db.deleteHistory(db.recentHistory(sourceKey: 'dev-a').single.id);
      expect(db.historyDeletionIndex(sourceKey: 'dev-a'), hasLength(1));
      expect(db.historyDeletionIndex(sourceKey: 'dev-b'), isEmpty);

      final blocked = sync(db, [old, old], sourceKey: 'dev-a');
      expect(blocked.applied, 0);
      expect(blocked.skipped, 2);
      final allowed = sync(db, [old], sourceKey: 'dev-b');
      expect(allowed.applied, 1);
      expect(db.recentHistory().single.sourceKey, 'dev-b');
    });

    test('sourceKey 隔离：另一源的记录不参与匹配，也不被覆盖', () {
      final db = freshDb();
      sync(db, [peerJson(position: 1600000)], sourceKey: 'dev-a');
      final other = sync(db, [peerJson(position: 200000)], sourceKey: 'dev-b');
      expect(other.applied, 1, reason: '另一源应插入自己的行');
      expect(db.count('history'), 2);

      final back = sync(db, [peerJson(position: 1600000)], sourceKey: 'dev-a');
      expect(back.applied, 0);
      expect(back.skipped, 1);
      final rows = db.recentHistory();
      expect(rows.map((row) => row.sourceKey).toSet(), {
        'dev-a',
        'dev-b',
      }, reason: '两源各自保留一行，互不覆盖');
    });
  });
}
