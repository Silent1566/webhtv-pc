/// Phase 7 · 续播匹配：同步来的历史必须能续播（缺陷回归）。
///
/// ## 缺陷（用户实报：手动拉取的历史，点击播放从头开始）
///
/// `history.episode_id` 有**两种互不兼容的语义**，取决于写入方：
///
/// | 写入方 | `episode_id` 存的值 | 代码 |
/// | --- | --- | --- |
/// | 本地播放 | **站点入口 URL**（`episodeTarget`） | `player_page.dart` 的 `_persistProgress` |
/// | 同步落库 | 安卓 `episodeId` = **episodeUrl 的 SHA-256**（64 位 hex） | `storage.dart` 的 `_writeSyncHistory` |
///
/// 而续播查询（详情页/历史页点播放）传的是**站点入口 URL**：
///
/// ```dart
/// state.resumePositionFor(
///   siteKey: ..., vodId: ..., flag: line.playbackFlag,
///   episodeId: episode.url,        // ← 站点入口 URL
/// );
/// ```
///
/// 于是 `WHERE episode_id = ?` **永远命不中**同步记录 →
/// `resumePositionFor` 返回 `null` → `startPosition: null` → **从头播放**。
///
/// 这不是「数据没同步过来」——记录、进度、时长都在库里；坏的只是**查询键**。
///
/// ## 修复的边界（不能为了"能续播"而错续播）
///
/// `design/01` §4.1 的警告同样适用：**宁可不续播，也不要把第 3 集续成第 1 集**。
/// 因此兜底必须按保守顺序：
///
/// 1. `episode_id` 精确命中（现状，语义不变）；
/// 2. `episode_name` 精确命中（仅当给了 `episodeName` 且第 1 步落空）；
/// 3. **唯一性兜底**：同 `siteKey + vodId` 下**只有一条未完成记录**时用它；
///    多条时**不猜**（回 null）。
///
/// 用真实 SQLite（`test()` 而非 `testWidgets`）：fake-async 时钟不会推进真实
/// 文件回调，本仓库已踩过多次。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/storage.dart';

/// 安卓给的 `episodeId`：`episodeUrl` 的 SHA-256（64 位小写 hex）。
final String androidEpisodeHash = 'a' * 64;

/// 站点入口 URL（PC 本地播放写进 `episode_id` 的那种值）。
const String siteEpisodeUrl = 'http://site.example/1-1-1.html';

void main() {
  late Directory tempDir;
  late AppDatabase db;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('webhtv-resume-match');
    final opened = AppDatabase.open(p.join(tempDir.path, 'test.db'));
    expect(opened.succeeded, isTrue, reason: opened.error);
    db = opened.database!;
  });

  tearDown(() {
    db.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 模拟「同步落库」：`episode_id` 是安卓哈希。
  void insertSynced({
    String siteKey = 'csp_Media',
    String vodId = 'demo-001',
    String flag = '线路一',
    String episodeName = '第02集',
    String? episodeId,
    int positionMs = 754000,
    int durationMs = 2700000,
    int? updatedAt,
  }) {
    db.upsertHistory(
      siteKey: siteKey,
      vodId: vodId,
      vodName: '示例剧集',
      flag: flag,
      episodeName: episodeName,
      episodeId: episodeId ?? androidEpisodeHash,
      positionMs: positionMs,
      durationMs: durationMs,
      completed: false,
      updatedAt: updatedAt ?? 1791450000000,
    );
  }

  group('同步记录必须能续播（缺陷回归）', () {
    test('用站点入口 URL + 集名查询同步来的记录 → 必须命中（修复前为 null）', () {
      insertSynced(episodeName: '第02集');

      // 这组参数就是生产调用点现在传的形态（`browse_pages.dart` 的
      // `_openEpisode` 与 `player_page.dart` 的 `_resumeFromLatestProgress`）：
      // `episodeId` 是站点入口 URL，`episodeName` 是站点解析出的集名。
      final found = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路一',
        episodeId: siteEpisodeUrl,
        episodeName: '第02集',
      );

      expect(
        found,
        isNotNull,
        reason: '同步记录的 episode_id 是安卓哈希，只靠站点 URL 永远命不中 → '
            'resumePositionFor 返回 null → 从头播放（用户实报的症状）',
      );
      expect(found!.positionMs, 754000);
    });

    test('站点 url（带集名）与安卓哈希都能命中同一条记录（不重复）', () {
      insertSynced(episodeName: '第02集');

      final byUrl = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路一',
        episodeId: siteEpisodeUrl,
        episodeName: '第02集',
      );
      final byHash = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路一',
        episodeId: androidEpisodeHash,
      );

      expect(byUrl, isNotNull);
      expect(byHash, isNotNull);
      expect(
        byUrl!.id,
        byHash!.id,
        reason: '两种键指向的是同一集，必须命中同一条记录',
      );
    });

    test('给了 episodeName 时按集名兜底命中', () {
      insertSynced(episodeName: '第02集');

      final found = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路一',
        episodeId: siteEpisodeUrl,
        episodeName: '第02集',
      );

      expect(found, isNotNull);
      expect(found!.episodeName, '第02集');
    });
  });

  group('不得串集（宁可不续播，不可错续播）', () {
    test('同剧多集时，按集名只能命中对应那一集', () {
      // 第 1 集（安卓哈希 1）
      insertSynced(
        episodeName: '第01集',
        episodeId: 'b' * 64,
        positionMs: 100000,
        updatedAt: 1791450000000,
      );
      // 第 2 集（安卓哈希 2），更新更晚
      insertSynced(
        episodeName: '第02集',
        episodeId: androidEpisodeHash,
        positionMs: 900000,
        updatedAt: 1791450600000,
      );

      final first = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路一',
        episodeId: 'http://site.example/1-1-1.html',
        episodeName: '第01集',
      );
      final second = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路一',
        episodeId: 'http://site.example/1-2-1.html',
        episodeName: '第02集',
      );

      expect(first?.positionMs, 100000, reason: '第 1 集不得续到第 2 集的进度');
      expect(second?.positionMs, 900000, reason: '第 2 集不得续到第 1 集的进度');
    });

    test('同剧多集且没给集名 → 返回 null（不猜）', () {
      insertSynced(episodeName: '第01集', episodeId: 'b' * 64);
      insertSynced(episodeName: '第02集', episodeId: androidEpisodeHash);

      final found = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路一',
        episodeId: siteEpisodeUrl,
        // 没有集名可依据
      );

      expect(
        found,
        isNull,
        reason: '多条候选时不许猜——错续播比不续播更糟',
      );
    });

    test('同剧只有一条记录、但集名对不上 → 仍返回 null（不拿别的集凑数）', () {
      insertSynced(episodeName: '第03集');

      // 用户点开的是**另一集**（episodeName 对不上），库内只有第 3 集。
      final found = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路一',
        episodeId: siteEpisodeUrl,
        episodeName: '第05集',
      );

      expect(
        found,
        isNull,
        reason: '集名对不上时不能拿别的集凑数——那会把用户送到第 3 集的进度上'
            '（`design/01` §4.1：宁可不续播，不可错续播）',
      );
    });

    test('查不存在的集且没给集名 → null（既有契约，不得回退）', () {
      insertSynced(episodeName: '第01集', episodeId: 'b' * 64);

      final found = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路一',
        episodeId: 'http://site.example/not-exist.html',
      );

      expect(found, isNull);
    });

    test('连 flag 也对不上时不命中（不同线路是不同记录）', () {
      insertSynced(flag: '线路一');

      final found = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路二',
        episodeId: siteEpisodeUrl,
      );

      expect(
        found,
        isNull,
        reason: '线路不同 = 不同播放上下文，不该跨线路续播',
      );
    });

    test('不同剧集互不影响', () {
      insertSynced(vodId: 'demo-001');

      final found = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-999',
        flag: '线路一',
        episodeId: siteEpisodeUrl,
      );

      expect(found, isNull);
    });
  });

  group('精确匹配优先于兜底', () {
    test('本地记录（episode_id=站点 URL）优先于同步记录（哈希）', () {
      // 本地播放产生的记录：episode_id 就是站点 URL。
      db.upsertHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        vodName: '示例剧集',
        flag: '线路一',
        episodeName: '第02集',
        episodeId: siteEpisodeUrl,
        positionMs: 111000,
        durationMs: 2700000,
        completed: false,
        // 更旧
        updatedAt: 1791450000000,
      );
      // 同步来的同一集（安卓哈希），更新更晚。
      insertSynced(
        episodeName: '第02集',
        episodeId: androidEpisodeHash,
        positionMs: 999000,
        updatedAt: 1791450600000,
      );

      final found = db.findHistory(
        siteKey: 'csp_Media',
        vodId: 'demo-001',
        flag: '线路一',
        episodeId: siteEpisodeUrl,
        episodeName: '第02集',
      );

      expect(
        found,
        isNotNull,
        reason: '精确命中必须有效（不能被兜底逻辑抢走）',
      );
      expect(
        found!.episodeId,
        siteEpisodeUrl,
        reason: '第 1 步（episode_id 精确命中）优先于任何兜底',
      );
    });
  });
}
