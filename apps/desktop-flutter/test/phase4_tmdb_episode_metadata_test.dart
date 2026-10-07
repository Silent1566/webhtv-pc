/// Phase 4 · TMDB 元数据应用（`docs/phase4/design/04` §3.2、`02` §9）。
///
/// 对应门禁：`docs/phase4/design/05` §3.11「未知季度不应用（反向验证）/ 已知季度 /
/// 集号对齐 / 迟到响应丢弃 / 季集数变化 / 多线路隔离 / 分段应用 / 保留原始名」
/// 与 §4.4 用例组 2（头部补位 8 字段）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/core/tmdb_season.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

TmdbEnrichmentService _service() => TmdbEnrichmentService(
  service: TmdbService(config: () => const TmdbConfig(apiKey: 'k')),
  config: () => const TmdbConfig(apiKey: 'k'),
);

Vod _vod({
  String name = '来源剧名',
  String? pic,
  String? content,
  String? area,
  String? year,
  String? director,
  String? actor,
  Map<String, Object?> extra = const {},
}) => Vod(
  vodId: 'v1',
  vodName: name,
  vodPic: pic,
  vodContent: content,
  vodArea: area,
  vodYear: year,
  vodDirector: director,
  vodActor: actor,
  extra: extra,
);

VodPlayLine _line(List<String> names) => VodPlayLine(
  flag: '线路一',
  episodes: [
    for (var i = 0; i < names.length; i++)
      VodEpisode(name: names[i], url: 'https://cdn/e${i + 1}.m3u8'),
  ],
);

const _tvItem = TmdbItem(
  tmdbId: 1399,
  mediaType: TmdbMediaType.tv,
  title: '示例剧集',
  posterUrl: 'https://img/p.jpg',
);

void main() {
  group('头部补位 8 字段：仅补位不覆盖（§3.2）', () {
    test('来源全空 → 全部补位', () {
      final result = _service().enrichVod(
        vod: _vod(name: ''),
        item: _tvItem,
        detail: {
          'overview': 'TMDB 简介',
          'first_air_date': '2024-03-01',
          'production_countries': [
            {'name': '中国'},
          ],
          'genres': [
            {'name': '剧情'},
            {'name': '科幻'},
          ],
          'credits': {
            'cast': [
              {'id': 1, 'name': '演员A', 'character': '主角'},
              {'id': 2, 'name': '演员B', 'character': '配角'},
            ],
          },
          'created_by': [
            {'id': 3, 'name': '导演A'},
          ],
        },
      );
      final vod = result.vod;
      expect(vod.vodName, '示例剧集');
      expect(vod.vodContent, 'TMDB 简介');
      expect(vod.vodPic, 'https://img/p.jpg');
      expect(vod.vodYear, '2024');
      expect(vod.vodArea, '中国');
      expect(vod.extra['type_name'], '剧情 / 科幻');
      expect(vod.vodActor, '演员A / 演员B');
      expect(vod.vodDirector, '导演A');
      expect(result.applied, containsAll([
        'vodName',
        'vodContent',
        'vodPic',
        'vodYear',
        'vodArea',
        'typeName',
        'vodActor',
        'vodDirector',
      ]));
    });

    test('来源非空 → 除 vodName 外全部不变（vodName 是文档化例外）', () {
      final result = _service().enrichVod(
        vod: _vod(
          name: '来源剧名',
          pic: 'https://src/p.jpg',
          content: '来源简介来源简介来源简介来源简介来源简介来源简介来源简介来源简介',
          area: '来源地区',
          year: '2020',
          director: '来源导演',
          actor: '来源演员',
          extra: const {'type_name': '来源类型'},
        ),
        item: _tvItem,
        detail: {
          'overview': '短',
          'first_air_date': '2024-03-01',
          'production_countries': [
            {'name': '中国'},
          ],
          'genres': [
            {'name': '剧情'},
          ],
          'credits': {
            'cast': [
              {'id': 1, 'name': '演员A'},
            ],
          },
          'created_by': [
            {'id': 3, 'name': '导演A'},
          ],
        },
      );
      final vod = result.vod;
      // `vodName` 是 §3.2 表中唯一的例外：来源标题不含季度时使用 TMDB 标题。
      expect(vod.vodName, '示例剧集');
      expect(vod.vodPic, 'https://src/p.jpg');
      expect(vod.vodContent, startsWith('来源简介'));
      expect(vod.vodArea, '来源地区');
      expect(vod.vodYear, '2020');
      expect(vod.vodDirector, '来源导演');
      expect(vod.vodActor, '来源演员');
      expect(vod.extra['type_name'], '来源类型');
      // 除 vodName 外，全部因来源非空而跳过
      expect(
        result.skipped,
        containsAll(['vodPic', 'vodContent', 'vodArea', 'vodYear', 'typeName', 'vodActor', 'vodDirector']),
      );
      expect(result.applied, ['vodName']);
    });

    test('简介仅在 TMDB 更长时替换', () {
      // TMDB 更长 → 替换
      final longer = _service().enrichVod(
        vod: _vod(content: '短简介'),
        item: _tvItem,
        detail: {'overview': '这是一个很长很长的 TMDB 简介文本内容'},
      );
      expect(longer.vod.vodContent, '这是一个很长很长的 TMDB 简介文本内容');
      // TMDB 更短 → 保留来源
      final shorter = _service().enrichVod(
        vod: _vod(content: '这是一个很长很长的来源简介文本内容'),
        item: _tvItem,
        detail: {'overview': '短'},
      );
      expect(shorter.vod.vodContent, '这是一个很长很长的来源简介文本内容');
    });

    test('detail 为空时只补标题与海报', () {
      final result = _service().enrichVod(
        vod: _vod(name: ''),
        item: _tvItem,
      );
      expect(result.vod.vodName, '示例剧集');
      expect(result.vod.vodPic, 'https://img/p.jpg');
      expect(result.vod.vodContent, isNull);
      expect(result.vod.vodYear, isNull);
      expect(result.vod.vodArea, isNull);
      expect(result.vod.vodActor, isNull);
      expect(result.vod.vodDirector, isNull);
      expect(result.applied, containsAll(['vodName', 'vodPic']));
    });

    test('来源标题已含明确季度 → 保留来源标题（§3.1）', () {
      final result = _service().enrichVod(
        vod: _vod(name: '来源剧名 第2季'),
        item: _tvItem,
      );
      expect(result.vod.vodName, '来源剧名 第2季');
    });

    test('电影不使用 sourceAwareTitle 的季度保留', () {
      final result = _service().enrichVod(
        vod: _vod(name: '来源剧名 第2季'),
        item: const TmdbItem(
          tmdbId: 550,
          mediaType: TmdbMediaType.movie,
          title: '示例电影',
        ),
      );
      expect(result.vod.vodName, '示例电影');
    });

    test('演员与主创最多 5 位', () {
      final result = _service().enrichVod(
        vod: _vod(name: ''),
        item: _tvItem,
        detail: {
          'credits': {
            'cast': [
              for (var i = 1; i <= 8; i++) {'id': i, 'name': '演员$i'},
            ],
          },
          'created_by': [
            for (var i = 1; i <= 8; i++) {'id': i, 'name': '主创$i'},
          ],
        },
      );
      expect(result.vod.vodActor!.split(' / ').length, 5);
      expect(result.vod.vodDirector!.split(' / ').length, 5);
    });

    test('原 Vod 对象不被修改（不可变语义）', () {
      final original = _vod(name: '');
      _service().enrichVod(vod: original, item: _tvItem);
      expect(original.vodName, '', reason: '输入 Vod 必须保持不变');
    });

    test('返回的 Vod 保留 vodId / 线路字段 / 未知字段', () {
      final source = Vod(
        vodId: 'keep-me',
        vodName: '',
        vodRemarks: '备注',
        vodPlayFrom: '线路一',
        vodPlayUrl: 'e1\$u1',
        extra: const {'custom': 'value'},
      );
      final result = _service().enrichVod(vod: source, item: _tvItem);
      expect(result.vod.vodId, 'keep-me');
      expect(result.vod.vodRemarks, '备注');
      expect(result.vod.vodPlayFrom, '线路一');
      expect(result.vod.vodPlayUrl, 'e1\$u1');
      expect(result.vod.extra['custom'], 'value');
    });
  });

  group('评分文案（§3.2）', () {
    test('四种分支', () {
      expect(
        TmdbEnrichmentService.ratingText(tmdbRating: 8.2, doubanRating: 9.1),
        'TMDB 8.2 · 豆瓣 9.1',
      );
      expect(
        TmdbEnrichmentService.ratingText(tmdbRating: 8.2),
        'TMDB 8.2',
      );
      expect(
        TmdbEnrichmentService.ratingText(tmdbRating: 0, doubanRating: 9.1),
        '豆瓣 9.1',
      );
      expect(
        TmdbEnrichmentService.ratingText(tmdbRating: 0),
        'TMDB — · 豆瓣 —',
      );
    });

    test('未匹配时返回空串', () {
      expect(
        TmdbEnrichmentService.ratingText(tmdbRating: 0, matched: false),
        '',
      );
    });
  });

  group('剧集元数据应用：未知季度不应用（§9.1，反向验证）', () {
    test('seasonNumber = -1 → 不应用且返回 unknown_season', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集', '第2集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: -1,
          tmdbEpisodes: [
            TmdbEpisode(number: 1, title: '真相'),
            TmdbEpisode(number: 2, title: '答案'),
          ],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(result.changed, isFalse);
      expect(result.appliedCount, 0);
      expect(result.rejectedReason, 'unknown_season');
      // 原始剧集名必须保留
      expect(result.line.episodes.map((e) => e.name), ['第1集', '第2集']);
      expect(result.line.episodes.every((e) => e.extra.isEmpty), isTrue);
    });

    test('反向验证：若把未知季度改成兜底 [1,0]，本用例会失败', () {
      // 该断言锁定「未知季度绝不产生任何元数据」这一契约。
      // 任何引入 [1, 0] 兜底的实现都会让下面的 extra 非空。
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集', '第2集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: -1,
          tmdbEpisodes: [
            TmdbEpisode(number: 1, title: 'S1 元数据'),
            TmdbEpisode(number: 2, title: 'S1 元数据2'),
          ],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(
        result.line.episodes.any((e) => e.extra.containsKey('display_name')),
        isFalse,
        reason: '未知季度不得应用任何 TMDB 剧集元数据',
      );
    });

    test('seasonNumber = 0（特别篇）是已确证季度，允许应用', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 0,
          tmdbEpisodes: [TmdbEpisode(number: 1, title: '特别篇1')],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(result.changed, isTrue);
      expect(result.line.episodes.first.extra['tmdb_season_number'], 0);
    });
  });

  group('剧集元数据应用：代数与快照校验（§9.2）', () {
    test('迟到响应被丢弃（generation 不匹配）', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [TmdbEpisode(number: 1, title: '真相')],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 2,
        currentMetadataGeneration: 1,
      );
      expect(result.changed, isFalse);
      expect(result.rejectedReason, 'stale_generation');
    });

    test('metadataGeneration 不匹配同样丢弃', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [TmdbEpisode(number: 1, title: '真相')],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 3,
      );
      expect(result.rejectedReason, 'stale_generation');
    });

    test('季集数快照变化 → 放弃应用', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [TmdbEpisode(number: 1, title: '真相')],
          generation: 1,
          metadataGeneration: 1,
          seasonEpisodeCount: 12, // 快照说 12 集，实际只给了 1 集
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(result.changed, isFalse);
      expect(result.rejectedReason, 'season_count_changed');
    });

    test('元数据为空 → no_metadata', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(result.rejectedReason, 'no_metadata');
    });

    test('线路为空 → no_metadata', () {
      final result = _service().applyEpisodeMetadata(
        line: _line([]),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [TmdbEpisode(number: 1, title: '真相')],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(result.rejectedReason, 'no_metadata');
    });
  });

  group('集号对齐（§9.3）', () {
    test('集号可解析且唯一无越界 → 按号对齐', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集', '第2集', '第3集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [
            TmdbEpisode(number: 1, title: 'A'),
            TmdbEpisode(number: 2, title: 'B'),
            TmdbEpisode(number: 3, title: 'C'),
          ],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(
        result.line.episodes.map((e) => e.extra['tmdb_episode_number']),
        [1, 2, 3],
      );
      expect(
        result.line.episodes.map((e) => e.extra['display_name']),
        ['E1 A', 'E2 B', 'E3 C'],
      );
    });

    test('集号缺失 → 按位对齐', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第一集', '第二集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [
            TmdbEpisode(number: 1, title: 'A'),
            TmdbEpisode(number: 2, title: 'B'),
          ],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(
        result.line.episodes.map((e) => e.extra['tmdb_episode_number']),
        [1, 2],
      );
    });

    test('集号重复 → 按位对齐', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集', '第1集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [
            TmdbEpisode(number: 1, title: 'A'),
            TmdbEpisode(number: 2, title: 'B'),
          ],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(
        result.line.episodes.map((e) => e.extra['tmdb_episode_number']),
        [1, 2],
      );
    });

    test('集号越界 → 按位对齐', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集', '第99集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [
            TmdbEpisode(number: 1, title: 'A'),
            TmdbEpisode(number: 2, title: 'B'),
          ],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(
        result.line.episodes.map((e) => e.extra['tmdb_episode_number']),
        [1, 2],
      );
    });

    test('无法匹配的集保留原始名（不丢集、不伪造）', () {
      final result = _service().applyEpisodeMetadata(
        line: _line(['第1集', '第2集', '第3集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [
            TmdbEpisode(number: 1, title: 'A'),
            // 没有 E2、E3
          ],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(result.line.episodes.length, 3, reason: '不得丢集');
      expect(result.line.episodes[1].name, '第2集');
      expect(result.line.episodes[1].extra, isEmpty);
      expect(result.line.episodes[2].extra, isEmpty);
      expect(result.appliedCount, 1);
    });

    test('shouldUseEpisodePosition 直接断言', () {
      const episodes = [
        TmdbEpisode(number: 1, title: 'A'),
        TmdbEpisode(number: 2, title: 'B'),
      ];
      expect(shouldUseEpisodePosition(['第1集', '第2集'], episodes), isFalse);
      expect(shouldUseEpisodePosition(['第1集', '第1集'], episodes), isTrue);
      expect(shouldUseEpisodePosition(['第1集', '第99集'], episodes), isTrue);
      // 中文数字集名同样可解析（第一集 → 1），因此按号对齐
      expect(shouldUseEpisodePosition(['第一集', '第二集'], episodes), isFalse);
      expect(shouldUseEpisodePosition([], episodes), isTrue);
      // 完全无法解析的集名 → 按位
      expect(shouldUseEpisodePosition(['上', '下'], episodes), isTrue);
    });

    test('episodeNumberFromName 解析各种形态', () {
      expect(episodeNumberFromName('第1集'), 1);
      expect(episodeNumberFromName('第 12 集'), 12);
      expect(episodeNumberFromName('第三话'), 3);
      expect(episodeNumberFromName('第十二回'), 12);
      expect(episodeNumberFromName('S01E05'), 5);
      expect(episodeNumberFromName('EP07'), 7);
      expect(episodeNumberFromName('Episode 100'), 100);
      expect(episodeNumberFromName('05'), 5);
      // 中文数字集名可解析（`01` §3.5 的中文数字归一）
      expect(episodeNumberFromName('第一集'), 1);
      expect(episodeNumberFromName('第十二集'), 12);
      // 无法解析的返回 -1
      expect(episodeNumberFromName('上'), -1);
      expect(episodeNumberFromName(''), -1);
    });

    test('resolveEpisodeNumber 按位 / 按号', () {
      expect(
        resolveEpisodeNumber(episodeName: '第5集', position: 0, usePosition: true),
        1,
      );
      expect(
        resolveEpisodeNumber(episodeName: '第5集', position: 0, usePosition: false),
        5,
      );
    });
  });

  group('多线路隔离与分段应用（§9.4）', () {
    test('applyEpisodeMetadata 只作用于传入线路（返回新线路）', () {
      final lineA = _line(['第1集', '第2集']);
      final lineB = _line(['第1集', '第2集']);
      final result = _service().applyEpisodeMetadata(
        line: lineA,
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [
            TmdbEpisode(number: 1, title: 'A'),
            TmdbEpisode(number: 2, title: 'B'),
          ],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(result.changed, isTrue);
      // lineB 不受影响
      expect(lineB.episodes.every((e) => e.extra.isEmpty), isTrue);
      // lineA 原对象也不被修改（不可变语义）
      expect(lineA.episodes.every((e) => e.extra.isEmpty), isTrue);
      // 返回的新线路已应用
      expect(result.line.episodes.first.extra['display_name'], 'E1 A');
    });

    test('分段应用：每段只应用本段集数', () {
      const scope = MultiSeason([
        SeasonSegment(
          seasonNumber: 1,
          sourceEpisodeStartIndex: 0,
          sourceEpisodeEndIndex: 2,
          tmdbEpisodeStartNumber: 1,
        ),
        SeasonSegment(
          seasonNumber: 2,
          sourceEpisodeStartIndex: 3,
          sourceEpisodeEndIndex: 4,
          tmdbEpisodeStartNumber: 1,
        ),
      ]);
      final result = _service().applySegmentedEpisodeMetadata(
        line: _line(['a1', 'a2', 'a3', 'b1', 'b2']),
        scope: scope,
        episodesBySeason: const {
          1: [
            TmdbEpisode(number: 1, title: 'S1E1'),
            TmdbEpisode(number: 2, title: 'S1E2'),
            TmdbEpisode(number: 3, title: 'S1E3'),
          ],
          2: [
            TmdbEpisode(number: 1, title: 'S2E1'),
            TmdbEpisode(number: 2, title: 'S2E2'),
          ],
        },
        generation: 1,
        metadataGeneration: 1,
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(result.changed, isTrue);
      expect(result.appliedCount, 5);
      // 前 3 集属于 S1
      for (var i = 0; i < 3; i++) {
        expect(result.line.episodes[i].extra['tmdb_season_number'], 1);
        expect(result.line.episodes[i].extra['tmdb_episode_number'], i + 1);
      }
      // 后 2 集属于 S2
      for (var i = 3; i < 5; i++) {
        expect(result.line.episodes[i].extra['tmdb_season_number'], 2);
        expect(result.line.episodes[i].extra['tmdb_episode_number'], i - 2);
      }
    });

    test('分段应用：代数不匹配 → 拒绝', () {
      final result = _service().applySegmentedEpisodeMetadata(
        line: _line(['a1']),
        scope: const MultiSeason([
          SeasonSegment(
            seasonNumber: 1,
            sourceEpisodeStartIndex: 0,
            sourceEpisodeEndIndex: 0,
            tmdbEpisodeStartNumber: 1,
          ),
          SeasonSegment(
            seasonNumber: 2,
            sourceEpisodeStartIndex: 1,
            sourceEpisodeEndIndex: 1,
            tmdbEpisodeStartNumber: 1,
          ),
        ]),
        episodesBySeason: const {},
        generation: 1,
        metadataGeneration: 1,
        currentGeneration: 9,
        currentMetadataGeneration: 1,
      );
      expect(result.rejectedReason, 'stale_generation');
      expect(result.changed, isFalse);
    });

    test('分段应用：段越界时跳过该段', () {
      final result = _service().applySegmentedEpisodeMetadata(
        line: _line(['a1']),
        scope: const MultiSeason([
          SeasonSegment(
            seasonNumber: 1,
            sourceEpisodeStartIndex: 0,
            sourceEpisodeEndIndex: 0,
            tmdbEpisodeStartNumber: 1,
          ),
          SeasonSegment(
            seasonNumber: 2,
            sourceEpisodeStartIndex: 5,
            sourceEpisodeEndIndex: 9, // 越界
            tmdbEpisodeStartNumber: 1,
          ),
        ]),
        episodesBySeason: const {
          1: [TmdbEpisode(number: 1, title: 'S1E1')],
          2: [TmdbEpisode(number: 1, title: 'S2E1')],
        },
        generation: 1,
        metadataGeneration: 1,
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(result.appliedCount, 1);
      expect(result.line.episodes.first.extra['tmdb_season_number'], 1);
    });
  });

  group('clearEpisodeMetadata（§9.4）', () {
    test('清除 TMDB 元数据但保留原始名与地址', () {
      final applied = _service()
          .applyEpisodeMetadata(
            line: _line(['第1集']),
            request: const TmdbEpisodeEnrichment(
              seasonNumber: 1,
              tmdbEpisodes: [TmdbEpisode(number: 1, title: 'A')],
              generation: 1,
              metadataGeneration: 1,
            ),
            currentGeneration: 1,
            currentMetadataGeneration: 1,
          )
          .line;
      expect(applied.episodes.first.extra, isNotEmpty);
      final cleared = TmdbEnrichmentService.clearEpisodeMetadata(applied);
      expect(cleared.episodes.first.extra, isEmpty);
      expect(cleared.episodes.first.name, '第1集');
      expect(cleared.episodes.first.url, 'https://cdn/e1.m3u8');
      expect(cleared.flag, applied.flag);
    });
  });

  group('幂等与变更检测（§9.2）', () {
    test('重复应用同一元数据 → 第二次 changed 为 false', () {
      final service = _service();
      const request = TmdbEpisodeEnrichment(
        seasonNumber: 1,
        tmdbEpisodes: [TmdbEpisode(number: 1, title: 'A')],
        generation: 1,
        metadataGeneration: 1,
      );
      final first = service.applyEpisodeMetadata(
        line: _line(['第1集']),
        request: request,
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(first.changed, isTrue);
      final second = service.applyEpisodeMetadata(
        line: first.line,
        request: request,
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(second.changed, isFalse, reason: '内容相同时不应报告变更');
      expect(second.appliedCount, 0);
    });

    test('元数据变化 → changed 为 true', () {
      final service = _service();
      final first = service.applyEpisodeMetadata(
        line: _line(['第1集']),
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [TmdbEpisode(number: 1, title: 'A')],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      final second = service.applyEpisodeMetadata(
        line: first.line,
        request: const TmdbEpisodeEnrichment(
          seasonNumber: 1,
          tmdbEpisodes: [TmdbEpisode(number: 1, title: 'B')],
          generation: 1,
          metadataGeneration: 1,
        ),
        currentGeneration: 1,
        currentMetadataGeneration: 1,
      );
      expect(second.changed, isTrue);
      expect(second.line.episodes.first.extra['display_name'], 'E1 B');
    });
  });

  group('sourceAwareTitle（§3.1）', () {
    test('剧集且来源含季度 → 保留来源标题', () {
      expect(
        sourceAwareTitle('来源 第2季', _tvItem, 'TMDB 标题'),
        '来源 第2季',
      );
    });

    test('剧集但来源无季度 → 用 TMDB 标题', () {
      expect(sourceAwareTitle('来源', _tvItem, 'TMDB 标题'), 'TMDB 标题');
    });

    test('电影 → 用 TMDB 标题', () {
      expect(
        sourceAwareTitle(
          '来源 第2季',
          const TmdbItem(tmdbId: 550, mediaType: TmdbMediaType.movie, title: 'M'),
          'TMDB 标题',
        ),
        'TMDB 标题',
      );
    });
  });
}
