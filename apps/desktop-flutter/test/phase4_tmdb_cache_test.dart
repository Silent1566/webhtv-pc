/// Phase 4 · TMDB 身份与匹配缓存三层键（`docs/phase4/design/01` §2）。
///
/// 对应门禁：`docs/phase4/design/05` §3.4「三层键读取顺序 / 同 vodId 多作品 /
/// 手动不被覆盖 / 标题域冲突 / 富集后读回 / 空标题兼容 / 归一化键」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';

TmdbItem _tv(int id, String title) => TmdbItem(
  tmdbId: id,
  mediaType: TmdbMediaType.tv,
  title: title,
);

TmdbItem _movie(int id, String title) => TmdbItem(
  tmdbId: id,
  mediaType: TmdbMediaType.movie,
  title: title,
);

void main() {
  group('TmdbIdentity（§2.1）', () {
    test('tmdbId <= 0 不得构造身份', () {
      expect(TmdbIdentity.of(TmdbMediaType.tv, 0), isNull);
      expect(TmdbIdentity.of(TmdbMediaType.tv, -1), isNull);
      expect(TmdbIdentity.of(TmdbMediaType.tv, null), isNull);
      expect(TmdbIdentity.of(null, 1399), isNull);
      expect(TmdbIdentity.of(TmdbMediaType.tv, 1399), isNotNull);
    });

    test('稳定键与相等语义', () {
      final a = TmdbIdentity.of(TmdbMediaType.tv, 1399)!;
      final b = TmdbIdentity.of(TmdbMediaType.tv, 1399)!;
      final c = TmdbIdentity.of(TmdbMediaType.movie, 1399)!;
      expect(a.key, 'tv:1399');
      expect(c.key, 'movie:1399');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
      expect(a.isTv, isTrue);
      expect(c.isMovie, isTrue);
    });

    test('from 解析 TMDB 响应的 media_type + id', () {
      expect(TmdbIdentity.from('tv', 1399)?.key, 'tv:1399');
      expect(TmdbIdentity.from('MOVIE', 550)?.key, 'movie:550');
      expect(TmdbIdentity.from('person', 287), isNull);
      expect(TmdbIdentity.from('tv', 0), isNull);
    });

    test('parse 从键反解', () {
      expect(TmdbIdentity.parse('tv:1399')?.tmdbId, 1399);
      expect(TmdbIdentity.parse('movie:550')?.mediaType, TmdbMediaType.movie);
      expect(TmdbIdentity.parse('tv:0'), isNull);
      expect(TmdbIdentity.parse('tv'), isNull);
      expect(TmdbIdentity.parse(null), isNull);
    });
  });

  group('TmdbItem 搜索归一化（§5.1）', () {
    test('只接受 movie / tv，过滤 person', () {
      expect(
        TmdbItem.fromSearchResult({'media_type': 'person', 'id': 287, 'name': 'X'}),
        isNull,
      );
      expect(
        TmdbItem.fromSearchResult({'media_type': 'tv', 'id': 1399, 'name': 'X'}),
        isNotNull,
      );
    });

    test('movie 取 title 回退 name；tv 取 name 回退 title', () {
      expect(
        TmdbItem.fromSearchResult({
          'media_type': 'movie',
          'id': 550,
          'title': '电影名',
          'name': '别名',
        })?.title,
        '电影名',
      );
      expect(
        TmdbItem.fromSearchResult({
          'media_type': 'movie',
          'id': 550,
          'name': '别名',
        })?.title,
        '别名',
      );
      expect(
        TmdbItem.fromSearchResult({
          'media_type': 'tv',
          'id': 1399,
          'name': '剧集名',
          'title': '别名',
        })?.title,
        '剧集名',
      );
    });

    test('date 字段按类型选择', () {
      final movie = TmdbItem.fromSearchResult({
        'media_type': 'movie',
        'id': 550,
        'title': 'M',
        'release_date': '2023-06-15',
      })!;
      expect(movie.subtitle, '2023');
      final tv = TmdbItem.fromSearchResult({
        'media_type': 'tv',
        'id': 1399,
        'name': 'T',
        'first_air_date': '2024-03-01',
        'vote_average': 8.2,
      })!;
      expect(tv.subtitle, '2024 · 8.2');
    });

    test('buildSubtitle 边界', () {
      expect(TmdbItem.buildSubtitle('2024-03-01', 8.2), '2024 · 8.2');
      expect(TmdbItem.buildSubtitle('2024-03-01', 0), '2024');
      expect(TmdbItem.buildSubtitle(null, 8.2), '8.2');
      expect(TmdbItem.buildSubtitle(null, 0), '');
    });

    test('origin_country 取首项；genre_ids 解析', () {
      final item = TmdbItem.fromSearchResult({
        'media_type': 'tv',
        'id': 1399,
        'name': 'T',
        'origin_country': ['CN', 'HK'],
        'genre_ids': [18, '10765'],
      })!;
      expect(item.originCountry, 'CN');
      expect(item.genreIds, [18, 10765]);
    });

    test('image 回调拼接海报与背景图', () {
      final item = TmdbItem.fromSearchResult(
        {
          'media_type': 'tv',
          'id': 1399,
          'name': 'T',
          'poster_path': '/p.jpg',
          'backdrop_path': '/b.jpg',
        },
        image: (base, path) => path == null ? '' : '$base$path',
        imageBase: 'https://img/t/p/w342',
        backdropBase: 'https://img/t/p/w780',
      )!;
      expect(item.posterUrl, 'https://img/t/p/w342/p.jpg');
      expect(item.backdropUrl, 'https://img/t/p/w780/b.jpg');
    });

    test('缺 id 或 title 返回 null', () {
      expect(
        TmdbItem.fromSearchResult({'media_type': 'tv', 'name': 'T'}),
        isNull,
      );
      expect(
        TmdbItem.fromSearchResult({'media_type': 'tv', 'id': 1399}),
        isNull,
      );
    });

    test('非 Map 输入返回 null', () {
      expect(TmdbItem.fromSearchResult('x'), isNull);
      expect(TmdbItem.fromSearchResult(null), isNull);
    });
  });

  group('TmdbCacheKey 三层键（§2.4）', () {
    test('键形态与分隔符', () {
      expect(TmdbCacheKey.separator, '@@@');
      expect(TmdbCacheKey.titleScope, '__title__');
      expect(TmdbCacheKey.entry('csp_A', '123'), 'csp_A@@@123');
      expect(TmdbCacheKey.scoped('csp_A', '123', '剧名'), 'csp_A@@@123@@@剧名');
      expect(TmdbCacheKey.title('剧名'), '__title__@@@剧名');
    });

    test('normalizedTitle 为空时退化为条目级键', () {
      expect(TmdbCacheKey.scoped('a', 'b', ''), TmdbCacheKey.entry('a', 'b'));
      expect(TmdbCacheKey.title(''), '');
    });

    test('normalizeSourceTitle = normalize(cleanTitle(...)) 且替换分隔符', () {
      expect(TmdbCacheKey.normalizeSourceTitle('剧名 第1季'), '剧名');
      expect(TmdbCacheKey.normalizeSourceTitle('剧 名'), '剧名');
      expect(TmdbCacheKey.normalizeSourceTitle(''), '');
      expect(TmdbCacheKey.normalizeSourceTitle(null), '');
    });
  });

  group('TmdbMatchCache 读取顺序（§2.4）', () {
    late TmdbMatchCache cache;

    setUp(() => cache = TmdbMatchCache());

    test('1. 手动条目级锚点优先（标题指向同一作品时）', () {
      cache.putManual('s', 'v', ['剧名'], _tv(1399, '剧名'), matchedAt: 1);
      // 富集后 vodName 被改写成 TMDB 标题，仍应读回。
      final hit = cache.findScoped('s', 'v', '剧名');
      expect(hit?.identity.tmdbId, 1399);
      expect(hit?.isManual, isTrue);
    });

    test('2. 条目+标题键命中', () {
      cache.put('s', 'v', _tv(1399, '剧名'), sourceTitle: '剧名', matchedAt: 1);
      expect(cache.findScoped('s', 'v', '剧名')?.identity.tmdbId, 1399);
    });

    test('3. 条目级键（需标题兼容）', () {
      cache.put('s', 'v', _tv(1399, '剧名'), matchedAt: 1);
      // 条目级记录的 title 是「剧名」，源标题「剧名」兼容 → 命中。
      expect(cache.findScoped('s', 'v', '剧名')?.identity.tmdbId, 1399);
      // 源标题不兼容 → 不命中条目级。
      expect(cache.findScoped('s', 'v', '别的剧'), isNull);
    });

    test('4. 全局标题域键（需标题兼容）', () {
      cache.put('s1', 'v1', _tv(1399, '剧名'), sourceTitle: '剧名', matchedAt: 1);
      // 另一个站点的同名作品可沿用。
      expect(cache.findScoped('s2', 'v2', '剧名')?.identity.tmdbId, 1399);
    });

    test('空标题直接读条目级键（不做兼容校验）', () {
      cache.put('s', 'v', _tv(1399, '剧名'), matchedAt: 1);
      expect(cache.findScoped('s', 'v', '')?.identity.tmdbId, 1399);
      expect(cache.findScoped('s', 'v', null)?.identity.tmdbId, 1399);
    });

    test('空 siteKey / vodId 返回 null', () {
      cache.put('s', 'v', _tv(1399, '剧名'), matchedAt: 1);
      expect(cache.findScoped('', 'v', '剧名'), isNull);
      expect(cache.findScoped('s', '', '剧名'), isNull);
      expect(cache.find('s', ''), isNull);
    });

    test('归一化键：标点/空格/季集后缀映射到同一键', () {
      cache.put('s', 'v', _tv(1399, '剧名'), sourceTitle: '剧名', matchedAt: 1);
      expect(cache.findScoped('s', 'v', '剧 名')?.identity.tmdbId, 1399);
      expect(cache.findScoped('s', 'v', '剧名 第1季')?.identity.tmdbId, 1399);
      expect(cache.findScoped('s', 'v', '【剧名】')?.identity.tmdbId, 1399);
      // 额外副标题是真实内容，不应被归一掉。
      expect(cache.findScoped('s', 'v', '剧名·副标'), isNull);
    });
  });

  group('TmdbMatchCache 手动排他性（§2.5）', () {
    late TmdbMatchCache cache;

    setUp(() => cache = TmdbMatchCache());

    test('自动匹配不得覆盖手动结论（同条目）', () {
      cache.putManual('s', 'v', ['剧名'], _tv(1399, '剧名'), matchedAt: 1);
      final written = cache.put(
        's',
        'v',
        _tv(9999, '别的作品'),
        sourceTitle: '剧名',
        matchedAt: 2,
      );
      expect(written, isFalse, reason: '自动匹配必须直接返回，不得写入');
      expect(cache.findScoped('s', 'v', '剧名')?.identity.tmdbId, 1399);
    });

    test('自动匹配不得覆盖手动结论（条目级）', () {
      cache.putManual('s', 'v', ['剧名'], _tv(1399, '剧名'), matchedAt: 1);
      expect(cache.put('s', 'v', _tv(9999, '别的作品'), matchedAt: 2), isFalse);
      expect(cache.find('s', 'v')?.identity.tmdbId, 1399);
    });

    test('putManual 写入全部别名，含 TMDB 标题别名', () {
      cache.putManual(
        's',
        'v',
        ['来源名', 'Intent 名', '当前 Vod 名'],
        _tv(1399, 'TMDB 标题'),
        matchedAt: 1,
      );
      for (final alias in ['来源名', 'Intent 名', '当前 Vod 名', 'TMDB 标题']) {
        expect(
          cache.findScoped('s', 'v', alias)?.identity.tmdbId,
          1399,
          reason: '别名 $alias 应能读回',
        );
      }
    });

    test('富集后读回：vodName 被改写成 TMDB 标题仍命中', () {
      cache.putManual('s', 'v', ['来源名'], _tv(1399, 'TMDB 标题'), matchedAt: 1);
      // 富集改写后下次进场用 TMDB 标题当键。
      expect(cache.findScoped('s', 'v', 'TMDB 标题')?.identity.tmdbId, 1399);
      expect(cache.isManual('s', 'v', 'TMDB 标题'), isTrue);
    });

    test('isManual 对手动记录为 true，对自动记录为 false', () {
      cache.put('s', 'v', _tv(1399, '剧名'), sourceTitle: '剧名', matchedAt: 1);
      expect(cache.isManual('s', 'v', '剧名'), isFalse);
      cache.putManual('s2', 'v2', ['剧名'], _tv(1399, '剧名'), matchedAt: 1);
      expect(cache.isManual('s2', 'v2', '剧名'), isTrue);
    });

    test('全部标题都被清洗为空时不放行锚点（防止变成通配符）', () {
      // 只由年份构成的标题清洗后为空 → manualTitles 为空 → 锚点不生效。
      cache.putManual('s', 'v', ['2024'], _tv(1399, '剧名'), matchedAt: 1);
      // 别名集合里只剩 TMDB 标题「剧名」，所以「别的剧」读不到。
      expect(cache.findScoped('s', 'v', '别的剧'), isNull);
      // 但 TMDB 标题本身仍可读回。
      expect(cache.findScoped('s', 'v', '剧名')?.identity.tmdbId, 1399);
    });
  });

  group('TmdbMatchCache 同 vodId 多作品（§2.5 上游关键用例）', () {
    test('条目级锚点只在标题确实指向同一作品时生效', () {
      final cache = TmdbMatchCache();
      // 同一 vodId 下先手动绑定「作品 A」。
      cache.putManual('s', 'v', ['作品A'], _tv(1399, '作品A'), matchedAt: 1);
      // 另一部作品（同名 vodId）手动绑定「作品 B」，覆盖条目级锚点。
      cache.putManual('s', 'v', ['作品B'], _tv(2000, '作品B'), matchedAt: 2);

      // 读「作品A」：锚点是 B，标题不匹配 → 但条目+标题键仍是 A。
      expect(cache.findScoped('s', 'v', '作品A')?.identity.tmdbId, 1399);
      // 读「作品B」：锚点匹配 → B。
      expect(cache.findScoped('s', 'v', '作品B')?.identity.tmdbId, 2000);
      // 读一个从未绑定过的标题：锚点（B）标题不匹配 → 不命中。
      expect(cache.findScoped('s', 'v', '作品C'), isNull);
    });

    test('两部作品都手动且标题不同时，各自条目+标题键互不干扰', () {
      final cache = TmdbMatchCache();
      cache.putManual('s', 'v', ['作品A'], _tv(1399, '作品A'), matchedAt: 1);
      cache.putManual('s', 'v', ['作品B'], _tv(2000, '作品B'), matchedAt: 2);
      expect(cache.findScoped('s', 'v', '作品A')?.title, '作品A');
      expect(cache.findScoped('s', 'v', '作品B')?.title, '作品B');
    });
  });

  group('TmdbMatchCache 全局标题域冲突（§2.4）', () {
    test('手动 vs 手动且身份不同 → 记冲突，读取方按未匹配处理', () {
      final cache = TmdbMatchCache();
      cache.putManual('s1', 'v1', ['剧名'], _tv(1399, '剧名'), matchedAt: 1);
      cache.putManual('s2', 'v2', ['剧名'], _tv(2000, '剧名'), matchedAt: 2);
      expect(cache.conflicts, contains('剧名'));
      // 第三个站点读该标题 → 冲突 → 未匹配。
      expect(cache.findScoped('s3', 'v3', '剧名'), isNull);
    });

    test('手动 vs 自动 → 手动保留，不记冲突', () {
      final cache = TmdbMatchCache();
      cache.put('s1', 'v1', _tv(2000, '剧名'), sourceTitle: '剧名', matchedAt: 1);
      cache.putManual('s2', 'v2', ['剧名'], _tv(1399, '剧名'), matchedAt: 2);
      expect(cache.conflicts, isEmpty);
      // 手动结论生效，自动结论被冲掉。
      expect(cache.findScoped('s3', 'v3', '剧名')?.identity.tmdbId, 1399);
    });

    test('自动不得覆盖已有的手动标题域结论', () {
      final cache = TmdbMatchCache();
      cache.putManual('s1', 'v1', ['剧名'], _tv(1399, '剧名'), matchedAt: 1);
      cache.put('s2', 'v2', _tv(2000, '剧名'), sourceTitle: '剧名', matchedAt: 2);
      expect(cache.conflicts, isEmpty);
      expect(cache.findScoped('s3', 'v3', '剧名')?.identity.tmdbId, 1399);
    });

    test('同身份写入 → 覆盖，不记冲突', () {
      final cache = TmdbMatchCache();
      cache.put('s1', 'v1', _tv(1399, '剧名'), sourceTitle: '剧名', matchedAt: 1);
      cache.put('s2', 'v2', _tv(1399, '剧名'), sourceTitle: '剧名', matchedAt: 2);
      expect(cache.conflicts, isEmpty);
      expect(cache.findScoped('s3', 'v3', '剧名')?.identity.tmdbId, 1399);
    });
  });

  group('TmdbMatchCache 移除与清空', () {
    test('remove 清掉条目级与全部条目+标题键', () {
      final cache = TmdbMatchCache();
      cache.putManual('s', 'v', ['A', 'B'], _tv(1399, '剧名'), matchedAt: 1);
      expect(cache.findScoped('s', 'v', 'A'), isNotNull);
      expect(cache.remove('s', 'v'), isTrue);
      expect(cache.findScoped('s', 'v', 'A'), isNull);
      expect(cache.find('s', 'v'), isNull);
      expect(cache.remove('s', 'v'), isFalse);
    });

    test('remove 不影响其他条目', () {
      final cache = TmdbMatchCache();
      cache.putManual('s', 'v1', ['A'], _tv(1399, 'A'), matchedAt: 1);
      cache.putManual('s', 'v2', ['B'], _tv(2000, 'B'), matchedAt: 2);
      cache.remove('s', 'v1');
      expect(cache.findScoped('s', 'v2', 'B')?.identity.tmdbId, 2000);
    });

    test('clear 重置全部状态', () {
      final cache = TmdbMatchCache();
      cache.putManual('s1', 'v1', ['剧名'], _tv(1399, '剧名'), matchedAt: 1);
      cache.putManual('s2', 'v2', ['剧名'], _tv(2000, '剧名'), matchedAt: 2);
      expect(cache.conflicts, isNotEmpty);
      cache.clear();
      expect(cache.length, 0);
      expect(cache.conflicts, isEmpty);
    });
  });

  group('TmdbMatchRecord（§2.3）', () {
    test('fromItem 保留快照字段以支持离线渲染', () {
      final item = TmdbItem(
        tmdbId: 1399,
        mediaType: TmdbMediaType.tv,
        title: '剧名',
        subtitle: '2024 · 8.2',
        overview: '简介',
        posterUrl: 'https://img/p.jpg',
        backdropUrl: 'https://img/b.jpg',
        credit: '演员',
        rating: 8.2,
        tmdbRating: 8.2,
        originalLanguage: 'zh',
        originCountry: 'CN',
      );
      final record = TmdbMatchRecord.fromItem(item, manual: false, matchedAt: 7);
      expect(record.identity.key, 'tv:1399');
      expect(record.title, '剧名');
      expect(record.subtitle, '2024 · 8.2');
      expect(record.overview, '简介');
      expect(record.posterUrl, 'https://img/p.jpg');
      expect(record.backdropUrl, 'https://img/b.jpg');
      expect(record.credit, '演员');
      expect(record.tmdbRating, 8.2);
      expect(record.originalLanguage, 'zh');
      expect(record.originCountry, 'CN');
      expect(record.matchedAt, 7);
      expect(record.source, TmdbMatchSource.auto);
      expect(record.isManual, isFalse);
    });

    test('fromItem 拒绝无身份的 item', () {
      expect(
        () => TmdbMatchRecord.fromItem(
          const TmdbItem(tmdbId: 0, mediaType: TmdbMediaType.tv, title: 'X'),
          manual: false,
          matchedAt: 1,
        ),
        throwsArgumentError,
      );
    });

    test('toItem 往返一致', () {
      final item = _tv(1399, '剧名');
      final record = TmdbMatchRecord.fromItem(item, manual: true, matchedAt: 1);
      final round = record.toItem();
      expect(round.tmdbId, item.tmdbId);
      expect(round.mediaType, item.mediaType);
      expect(round.title, item.title);
    });

    test('isManual 要求 manual 且身份有效', () {
      final record = TmdbMatchRecord.fromItem(
        _tv(1399, '剧名'),
        manual: true,
        matchedAt: 1,
      );
      expect(record.isManual, isTrue);
      expect(record.source, TmdbMatchSource.manual);
    });

    test('matchesManualTitle：空别名列表不放行', () {
      final record = TmdbMatchRecord.fromItem(
        _tv(1399, '剧名'),
        manual: true,
        matchedAt: 1,
      );
      expect(record.matchesManualTitle('剧名'), isFalse);
      expect(record.matchesManualTitle(''), isFalse);
    });
  });

  group('TmdbMatchResult 显式类型（§7.4）', () {
    test('不引入 tmdbId = -1 语义', () {
      final conflict = TmdbMatchConflict('剧名');
      expect(conflict, const TmdbMatchConflict('剧名'));
      expect(conflict.sourceTitle, '剧名');
    });

    test('六种 miss 原因可表达', () {
      for (final reason in TmdbMissReason.values) {
        final miss = TmdbMatchMiss(reason);
        expect(miss.reason, reason);
      }
      expect(TmdbMissReason.values.length, 6);
    });

    test('disabled 区分未配置与站点禁用', () {
      const a = TmdbMatchDisabled(TmdbMissReason.notConfigured);
      const b = TmdbMatchDisabled(TmdbMissReason.siteDisabled);
      expect(a.isNotConfigured, isTrue);
      expect(a.isSiteDisabled, isFalse);
      expect(b.isSiteDisabled, isTrue);
      expect(a == b, isFalse);
    });

    test('hit 相等性按身份', () {
      final a = TmdbMatchHit(
        TmdbMatchRecord.fromItem(_tv(1399, 'A'), manual: false, matchedAt: 1),
      );
      final b = TmdbMatchHit(
        TmdbMatchRecord.fromItem(_tv(1399, 'B'), manual: false, matchedAt: 2),
      );
      expect(a, b);
      expect(a.item.title, 'A');
    });

    test('sealed 类型可穷尽匹配', () {
      String describe(TmdbMatchResult result) => switch (result) {
        TmdbMatchHit() => 'hit',
        TmdbMatchMiss() => 'miss',
        TmdbMatchConflict() => 'conflict',
        TmdbMatchDisabled() => 'disabled',
      };
      expect(describe(TmdbMatchHit(
        TmdbMatchRecord.fromItem(_movie(550, 'M'), manual: false, matchedAt: 1),
      )), 'hit');
      expect(describe(const TmdbMatchMiss(TmdbMissReason.noCandidates)), 'miss');
      expect(describe(const TmdbMatchConflict('x')), 'conflict');
      expect(
        describe(const TmdbMatchDisabled(TmdbMissReason.siteDisabled)),
        'disabled',
      );
    });
  });
}
