/// Phase 4 · TMDB 季度进度：写入 / 读取 / 历史投影 / 换源 / 删除
/// （`docs/phase4/design/02` §6、§7）。
///
/// 对应门禁：`docs/phase4/design/05` §3.8。
///
/// 关键契约：
/// - `UnknownSeason` **不写**季度进度，只保留来源 `history`；
/// - 同节目不同季度**互不覆盖**；
/// - 读取顺序：季度进度 → 来源历史 → 同季度候选 → **不跨季**；
/// - 删除季度卡片**不得**删除同节目其他季度。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_playback.dart';
import 'package:webhtv_pc/core/tmdb_season.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';

final _identity = TmdbIdentity.of(TmdbMediaType.tv, 1399)!;
final _movie = TmdbIdentity.of(TmdbMediaType.movie, 550)!;

TmdbSeasonService _service([InMemoryTmdbSeasonStore? store]) =>
    TmdbSeasonService(store: store ?? InMemoryTmdbSeasonStore());

/// 写入一条进度（默认 S1E2 / 60s / 1800s）。
bool _write(
  TmdbSeasonService service, {
  required SeasonScope scope,
  int episodeNumber = 2,
  int positionMs = 60000,
  int durationMs = 1800000,
  String sourceFlag = '线路一',
  String episodeName = '第 2 集',
  String episodeUrl = 'https://cdn/a/2.m3u8',
  int configId = 0,
  int segmentSeason = -1,
}) => service.recordProgress(
  configId: configId,
  identity: _identity,
  scope: scope,
  episodeNumber: episodeNumber,
  positionMs: positionMs,
  durationMs: durationMs,
  sourceFlag: sourceFlag,
  sourceEpisodeName: episodeName,
  sourceEpisodeUrl: episodeUrl,
  sourceHistoryKey: TmdbHistoryKey.of(
    siteKey: 'csp_A',
    vodId: 'v1',
    flag: sourceFlag,
    episodeUrl: episodeUrl,
  ),
  sourceBindingKey: 'f#0',
  segmentSeason: segmentSeason < 0 ? null : segmentSeason,
);

void main() {
  group('写入规则（§6.2）', () {
    test('KnownSeason → 写入对应季度', () {
      final service = _service();
      expect(_write(service, scope: const KnownSeason(2)), isTrue);
      final record = service.progressFor(
        identity: _identity,
        seasonNumber: 2,
      );
      expect(record, isNotNull);
      expect(record!.seasonNumber, 2);
      expect(record.episodeNumber, 2);
      expect(record.positionMs, 60000);
      expect(record.sourceEpisodeUrl, 'https://cdn/a/2.m3u8');
    });

    test('MultiSeason → 写入 segmentSeason 对应的季', () {
      final store = InMemoryTmdbSeasonStore();
      final service = _service(store);
      const scope = MultiSeason([
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 11,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 12,
          sourceEpisodeEndIndex: 21,
          tmdbEpisodeStartNumber: 1,
        ),
      ]);
      expect(
        _write(service, scope: scope, segmentSeason: 2, episodeNumber: 3),
        isTrue,
      );
      expect(
        service.progressFor(identity: _identity, seasonNumber: 2)!.episodeNumber,
        3,
      );
      expect(service.progressFor(identity: _identity, seasonNumber: 1), isNull);
    });

    test('MultiSeason 未给 segmentSeason → 不写（不猜测季度）', () {
      final service = _service();
      const scope = MultiSeason([
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 11,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 12,
          sourceEpisodeEndIndex: 21,
          tmdbEpisodeStartNumber: 1,
        ),
      ]);
      expect(_write(service, scope: scope), isFalse);
      expect(service.progressList(identity: _identity), isEmpty);
    });

    test('UnknownSeason → 不写（硬约束）', () {
      final service = _service();
      expect(_write(service, scope: const UnknownSeason()), isFalse);
      expect(service.progressList(identity: _identity), isEmpty);
    });

    test('电影不写季度进度', () {
      final service = _service();
      final wrote = service.recordProgress(
        identity: _movie,
        scope: const KnownSeason(1),
        episodeNumber: 1,
        positionMs: 1000,
        durationMs: 2000,
        sourceFlag: 'f',
        sourceEpisodeName: 'n',
        sourceEpisodeUrl: 'u',
        sourceHistoryKey: 'k',
        sourceBindingKey: 'b',
      );
      expect(wrote, isFalse);
      expect(
        service.progressList(identity: _movie),
        isEmpty,
      );
    });

    test('特别篇 seasonNumber = 0 可写入（已确证的特别篇）', () {
      final service = _service();
      expect(_write(service, scope: const KnownSeason(0)), isTrue);
      expect(
        service.progressFor(identity: _identity, seasonNumber: 0)!.seasonNumber,
        0,
      );
    });
  });

  group('不覆盖（§6.2）', () {
    test('播放 S2 后 S1 快照不变', () {
      final service = _service();
      _write(
        service,
        scope: const KnownSeason(1),
        episodeNumber: 5,
        positionMs: 300000,
      );
      _write(
        service,
        scope: const KnownSeason(2),
        episodeNumber: 1,
        positionMs: 1000,
      );
      final s1 = service.progressFor(identity: _identity, seasonNumber: 1)!;
      expect(s1.episodeNumber, 5);
      expect(s1.positionMs, 300000);
      expect(
        service.progressFor(identity: _identity, seasonNumber: 2)!.episodeNumber,
        1,
      );
      expect(service.progressList(identity: _identity).length, 2);
    });

    test('同季度重复写入 → 主键覆盖而非新增', () {
      final service = _service();
      _write(service, scope: const KnownSeason(1), episodeNumber: 1);
      _write(service, scope: const KnownSeason(1), episodeNumber: 9);
      expect(service.progressList(identity: _identity).length, 1);
      expect(
        service.progressFor(identity: _identity, seasonNumber: 1)!.episodeNumber,
        9,
      );
    });
  });

  group('读取顺序（§6.3）', () {
    test('季度进度存在 → 直接返回该季度', () {
      final service = _service();
      _write(
        service,
        scope: const KnownSeason(1),
        episodeNumber: 4,
        positionMs: 120000,
      );
      final record = service.progressFor(
        identity: _identity,
        seasonNumber: 1,
      )!;
      expect(record.episodeNumber, 4);
      expect(record.positionMs, 120000);
    });

    test('季度进度不存在 → 返回 null（调用方回退来源历史，不跨季猜测）', () {
      final service = _service();
      _write(service, scope: const KnownSeason(1));
      expect(service.progressFor(identity: _identity, seasonNumber: 3), isNull);
    });

    test('UnknownSeason 读取 → 返回 null（不猜季度）', () {
      final service = _service();
      _write(service, scope: const KnownSeason(1));
      expect(service.progressFor(identity: _identity, seasonNumber: -1), isNull);
    });

    test('电影读取 → 返回 null', () {
      final service = _service();
      expect(
        service.progressFor(
          identity: _movie,
          seasonNumber: 1,
        ),
        isNull,
      );
    });
  });

  group('历史投影键（§7.1）', () {
    test('同节目多季生成多张卡片', () {
      final service = _service();
      _write(service, scope: const KnownSeason(1));
      _write(service, scope: const KnownSeason(3));
      final list = service.progressList(identity: _identity);
      expect(list.length, 2);
      expect(list.map((r) => r.seasonNumber).toList(), [1, 3]);
    });

    test('同一季度的多个来源投影为同一张季度卡片', () {
      final service = _service();
      _write(service, scope: const KnownSeason(1), sourceFlag: '线路一');
      _write(
        service,
        scope: const KnownSeason(1),
        sourceFlag: '线路二',
        episodeUrl: 'https://cdn/b/2.m3u8',
        positionMs: 99000,
      );
      final list = service.progressList(identity: _identity);
      expect(list.length, 1);
      // 后写入者覆盖（同季主键）
      expect(list.first.sourceFlag, '线路二');
    });

    test('UnknownSeason 不生成季度卡片', () {
      final service = _service();
      _write(service, scope: const UnknownSeason());
      expect(service.progressList(identity: _identity), isEmpty);
    });

    test('identityKey 形态为 mediaType:tmdbId:season:N', () {
      final service = _service();
      _write(service, scope: const KnownSeason(2));
      expect(
        service.progressFor(identity: _identity, seasonNumber: 2)!.identityKey,
        'tv:1399:season:2',
      );
    });

    test('configId 隔离：不同配置互不可见', () {
      final service = _service();
      _write(service, scope: const KnownSeason(1), configId: 1);
      expect(
        service.progressFor(
          identity: _identity,
          seasonNumber: 1,
          configId: 1,
        ),
        isNotNull,
      );
      expect(
        service.progressFor(
          identity: _identity,
          seasonNumber: 1,
          configId: 2,
        ),
        isNull,
      );
    });
  });

  group('换源兼容 5 条（§7.3）', () {
    final service = _service();

    test('Known(N) accepts Known(N)', () {
      expect(
        service.acceptsSource(
          target: const KnownSeason(2),
          source: const KnownSeason(2),
        ),
        isTrue,
      );
    });

    test('Known(N) accepts MultiSeason containing N', () {
      expect(
        service.acceptsSource(
          target: const KnownSeason(2),
          source: const MultiSeason([
            SeasonSegment(
              seasonNumber: 1,
              sourceEpisodeStartIndex: 0,
              sourceEpisodeEndIndex: 11,
              tmdbEpisodeStartNumber: 1,
            ),
            SeasonSegment(
              seasonNumber: 2,
              sourceEpisodeStartIndex: 12,
              sourceEpisodeEndIndex: 21,
              tmdbEpisodeStartNumber: 1,
            ),
          ]),
        ),
        isTrue,
      );
    });

    test('Known(N) rejects Known(M), M != N', () {
      expect(
        service.acceptsSource(
          target: const KnownSeason(2),
          source: const KnownSeason(3),
        ),
        isFalse,
      );
    });

    test('Known(N) rejects UnknownSeason（不自动换到未知季度线路）', () {
      expect(
        service.acceptsSource(
          target: const KnownSeason(2),
          source: const UnknownSeason(),
        ),
        isFalse,
      );
    });

    test('UnknownSeason 只自动恢复原来源（对任何 source 均不接受）', () {
      expect(
        service.acceptsSource(
          target: const UnknownSeason(),
          source: const KnownSeason(1),
        ),
        isFalse,
      );
      expect(
        service.acceptsSource(
          target: const UnknownSeason(),
          source: const UnknownSeason(),
        ),
        isFalse,
      );
    });
  });

  group('同季度换源候选（§5.5）', () {
    test('candidatesForSeason 只返回覆盖该季度的线路', () {
      final store = InMemoryTmdbSeasonStore();
      final service = _service(store);
      store.routes['a'] = const RouteBinding(
        siteKey: 'csp_A',
        vodId: 'v1',
        flagKey: '线路一',
        sourceFlag: '线路一',
        sourceFingerprint: 'fp1',
        tmdbId: 1399,
        mediaType: TmdbMediaType.tv,
        scope: KnownSeason(1),
        updatedAt: 100,
      );
      store.routes['b'] = const RouteBinding(
        siteKey: 'csp_A',
        vodId: 'v1',
        flagKey: '线路二',
        sourceFlag: '线路二',
        sourceFingerprint: 'fp2',
        tmdbId: 1399,
        mediaType: TmdbMediaType.tv,
        scope: KnownSeason(2),
        updatedAt: 200,
      );
      final candidates = service.candidatesForSeason(
        identity: _identity,
        seasonNumber: 1,
      );
      expect(candidates.length, 1);
      expect(candidates.first.flagKey, '线路一');
    });

    test('电影没有换源候选', () {
      final service = _service();
      expect(
        service.candidatesForSeason(
          identity: _movie,
          seasonNumber: 1,
        ),
        isEmpty,
      );
    });
  });

  group('删除语义 4 条（§7.4）', () {
    test('删除某一季度历史 → 只删该季', () {
      final service = _service();
      _write(service, scope: const KnownSeason(1));
      _write(service, scope: const KnownSeason(2));
      expect(
        service.deleteSeasonHistory(identity: _identity, seasonNumber: 1),
        1,
      );
      expect(service.progressFor(identity: _identity, seasonNumber: 1), isNull);
      expect(
        service.progressFor(identity: _identity, seasonNumber: 2),
        isNotNull,
      );
    });

    test('删除整部节目历史 → 全部季度消失', () {
      final service = _service();
      _write(service, scope: const KnownSeason(1));
      _write(service, scope: const KnownSeason(2));
      _write(service, scope: const KnownSeason(3));
      expect(service.deleteMediaHistory(identity: _identity), 3);
      expect(service.progressList(identity: _identity), isEmpty);
    });

    test('删除未知季度历史 → 不删任何季度进度', () {
      final service = _service();
      _write(service, scope: const KnownSeason(1));
      expect(
        service.deleteSeasonHistory(identity: _identity, seasonNumber: -1),
        0,
      );
      expect(
        service.progressFor(identity: _identity, seasonNumber: 1),
        isNotNull,
      );
    });

    test('多季度线路删 S1 不动 S2（同节目跨季不级联）', () {
      final service = _service();
      _write(service, scope: const KnownSeason(1), sourceFlag: '多季线路');
      _write(service, scope: const KnownSeason(2), sourceFlag: '多季线路');
      service.deleteSeasonHistory(identity: _identity, seasonNumber: 1);
      final s2 = service.progressFor(identity: _identity, seasonNumber: 2);
      expect(s2, isNotNull);
      expect(s2!.sourceFlag, '多季线路');
    });

    test('电影删除 → 返回 0（不误删）', () {
      final service = _service();
      expect(
        service.deleteMediaHistory(identity: _movie),
        0,
      );
      expect(
        service.deleteSeasonHistory(
          identity: _movie,
          seasonNumber: 1,
        ),
        0,
      );
    });
  });

  group('来源历史键（§6.1）', () {
    test('键含站点/条目/线路/剧集地址，不含 TMDB 身份', () {
      final key = TmdbHistoryKey.of(
        siteKey: 'csp_A',
        vodId: 'v1',
        flag: '线路一',
        episodeUrl: 'https://cdn/a/2.m3u8',
      );
      expect(key, 'csp_A@@@v1@@@线路一@@@https://cdn/a/2.m3u8');
      expect(key.contains('1399'), isFalse);
    });

    test('不同剧集地址生成不同键（多版本消歧）', () {
      final a = TmdbHistoryKey.of(
        siteKey: 's',
        vodId: 'v',
        flag: 'f',
        episodeUrl: 'u1',
      );
      final b = TmdbHistoryKey.of(
        siteKey: 's',
        vodId: 'v',
        flag: 'f',
        episodeUrl: 'u2',
      );
      expect(a, isNot(b));
    });
  });
}
