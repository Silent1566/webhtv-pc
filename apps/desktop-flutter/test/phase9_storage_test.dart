import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku_match.dart';
import 'package:webhtv_pc/core/skip_segments.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/site_injection.dart';
import 'package:webhtv_pc/core/subtitle_provider.dart';
import 'package:webhtv_pc/services/storage.dart';

void main() {
  group('Phase 9 schema v6', () {
    test('schemaVersion 为 10 且五张新表存在', () {
      final db = AppDatabase.inMemory();
      // v10 是 AI 季集映射表（`ai_season_episode_mappings`）的加法迁移。
      expect(AppDatabase.schemaVersion, 10);
      expect(db.schemaVersionValue, '10');
      for (final table in [
        'skip_segments',
        'subtitle_match',
        'danmaku_match',
        'injected_sites',
        'following',
      ]) {
        expect(db.count(table), 0);
      }
    });
  });

  group('片头片尾标记', () {
    test('写入后可读回，按影片而不是按集', () {
      final db = AppDatabase.inMemory();
      db.upsertSkipSegments(
        siteKey: 's1',
        vodId: 'v1',
        introEndMs: 90000,
        outroStartMs: 1600000,
      );
      final read = db.skipSegmentsFor(siteKey: 's1', vodId: 'v1');
      expect(read.introEndMs, 90000);
      expect(read.outroStartMs, 1600000);
      // 不同影片互不影响。
      expect(
        db.skipSegmentsFor(siteKey: 's1', vodId: 'v2'),
        const SkipSegments.none(),
      );
    });

    test('非法值（<=0）不落库；两侧都空时删除记录', () {
      final db = AppDatabase.inMemory();
      db.upsertSkipSegments(
        siteKey: 's1',
        vodId: 'v1',
        introEndMs: 0,
        outroStartMs: -5,
      );
      expect(db.count('skip_segments'), 0);

      db.upsertSkipSegments(siteKey: 's1', vodId: 'v1', introEndMs: 1000);
      expect(db.count('skip_segments'), 1);
      db.upsertSkipSegments(siteKey: 's1', vodId: 'v1');
      expect(db.count('skip_segments'), 0);
    });

    test('覆盖写入保留另一侧', () {
      final db = AppDatabase.inMemory();
      db.upsertSkipSegments(
        siteKey: 's1',
        vodId: 'v1',
        introEndMs: 90000,
        outroStartMs: 1600000,
      );
      // 只改片头：outroStartMs 传 null 表示清除，符合“全量覆盖”语义。
      db.upsertSkipSegments(siteKey: 's1', vodId: 'v1', introEndMs: 80000);
      final read = db.skipSegmentsFor(siteKey: 's1', vodId: 'v1');
      expect(read.introEndMs, 80000);
      expect(read.outroStartMs, isNull);
    });
  });

  group('字幕匹配记忆', () {
    test('写入/命中/删除', () {
      final db = AppDatabase.inMemory();
      const record = SubtitleMatchRecord(
        siteKey: 's1',
        vodId: 'v1',
        episodeName: '第 1 集',
        providerId: 'assrt',
        assetId: 'a1',
        title: '示例剧',
        language: 'zh-Hans',
        url: 'https://example.test/a1.srt',
        updatedAt: 1,
      );
      db.upsertSubtitleMatch(record);
      final hit = db.subtitleMatchFor(
        siteKey: 's1',
        vodId: 'v1',
        episodeName: '第 1 集',
      );
      expect(hit, isNotNull);
      expect(hit!.assetId, 'a1');
      expect(hit.language, 'zh-Hans');

      // 同名不同集不串味。
      expect(
        db.subtitleMatchFor(siteKey: 's1', vodId: 'v1', episodeName: '第 2 集'),
        isNull,
      );

      db.deleteSubtitleMatch(
        siteKey: 's1',
        vodId: 'v1',
        episodeName: '第 1 集',
      );
      expect(
        db.subtitleMatchFor(siteKey: 's1', vodId: 'v1', episodeName: '第 1 集'),
        isNull,
      );
    });

    test('重复写入是覆盖而不是新增', () {
      final db = AppDatabase.inMemory();
      for (final asset in ['a1', 'a2']) {
        db.upsertSubtitleMatch(
          SubtitleMatchRecord(
            siteKey: 's1',
            vodId: 'v1',
            episodeName: 'E1',
            providerId: 'assrt',
            assetId: asset,
            title: 't',
            language: 'zh-Hans',
            url: 'https://example.test/$asset.srt',
            updatedAt: 1,
          ),
        );
      }
      expect(db.count('subtitle_match'), 1);
      expect(
        db.subtitleMatchFor(siteKey: 's1', vodId: 'v1', episodeName: 'E1')!
            .assetId,
        'a2',
      );
    });
  });

  group('弹幕匹配记忆', () {
    test('写入/命中/删除', () {
      final db = AppDatabase.inMemory();
      const record = DanmakuMatchRecord(
        siteKey: 's1',
        vodId: 'v1',
        episodeName: '第 3 集',
        providerId: 'default',
        entryId: 'd1',
        title: '示例剧',
        episode: '03',
        url: 'https://example.test/d1.xml',
        updatedAt: 1,
      );
      db.upsertDanmakuMatch(record);
      final hit = db.danmakuMatchFor(
        siteKey: 's1',
        vodId: 'v1',
        episodeName: '第 3 集',
      );
      expect(hit, isNotNull);
      expect(hit!.entryId, 'd1');
      expect(hit.toEntry().episode, '03');

      db.deleteDanmakuMatch(
        siteKey: 's1',
        vodId: 'v1',
        episodeName: '第 3 集',
      );
      expect(
        db.danmakuMatchFor(siteKey: 's1', vodId: 'v1', episodeName: '第 3 集'),
        isNull,
      );
    });
  });

  group('站点注入存储（P1-2）', () {
    InjectedSiteEntry entry(String key, {bool enabled = true}) =>
        InjectedSiteEntry(
          site: Site(key: key, name: '站点 $key', type: 1, api: 'https://$key'),
          enabled: enabled,
          updatedAt: 1,
        );

    test('写入/读取/切换/删除', () {
      final db = AppDatabase.inMemory();
      db.upsertInjectedSite(entry('a'));
      db.upsertInjectedSite(entry('b', enabled: false));
      final rows = db.injectedSites();
      expect(rows.map((e) => e.key).toSet(), {'a', 'b'});
      expect(
        rows.firstWhere((e) => e.key == 'b').enabled,
        isFalse,
      );

      db.upsertInjectedSite(
        entry('b').copyWith(enabled: true, updatedAt: 2),
      );
      expect(
        db.injectedSites().firstWhere((e) => e.key == 'b').enabled,
        isTrue,
      );

      db.deleteInjectedSite('a');
      expect(db.injectedSites().map((e) => e.key), ['b']);
    });

    test('同 key 写入是覆盖而不是新增', () {
      final db = AppDatabase.inMemory();
      db.upsertInjectedSite(entry('a'));
      db.upsertInjectedSite(entry('a').copyWith(updatedAt: 9));
      expect(db.count('injected_sites'), 1);
    });
  });
}
