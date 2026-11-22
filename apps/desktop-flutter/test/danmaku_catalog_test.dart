import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku_catalog.dart';
import 'package:webhtv_pc/core/danmaku_match.dart';

/// 一条库结果；url 按 id 生成，方便断言排序结果。
DanmakuLibraryEntry entry({
  required String id,
  String title = '',
  String episode = '',
  double score = 0,
}) => DanmakuLibraryEntry(
  providerId: 'tvbox',
  id: id,
  title: title,
  episode: episode,
  url: 'https://cdn.test/$id.xml',
  score: score,
);

/// 一次查询（播放器侧 `DanmakuQuery` 的最小形态）。
DanmakuQuery danmakuQuery({
  String title = '灵笼',
  String? episode = '第1集',
  int? year,
}) => DanmakuQuery(
  title: title,
  episode: episode,
  year: year,
  siteKey: 'demo',
  vodId: 'vod-1',
  episodeName: episode ?? '',
);

void main() {
  group('渠道解析（对齐安卓 DanmakuTitle / 中转 name 形态）', () {
    test('优先 from X', () {
      expect(
        danmakuChannelOf(
          '灵笼 第二季(2025)【动漫】from bilibili - 【bilibili1】 第1话 末世桃源',
        ),
        'bilibili',
      );
      expect(
        danmakuChannelOf('灵笼 第二季(2025)【动漫】from DANDAN - 【dandan】 第1话'),
        'dandan',
        reason: '归一化统一小写',
      );
    });

    test('没有 from 时取第一个【】/[] 标记', () {
      expect(danmakuChannelOf('【qq】 灵笼 第1话'), 'qq');
      expect(danmakuChannelOf('[tencent] 灵笼 第1话'), 'tencent');
    });

    test('尾部署号归一：bilibili1 → bilibili', () {
      expect(danmakuChannelOf('灵笼 - 【bilibili1】 第1话'), 'bilibili');
      expect(danmakuChannelOf('灵笼 from bilibili2 - 第1话'), 'bilibili');
    });

    test('都没有时用 fallback，且可为 null', () {
      expect(danmakuChannelOf('灵笼 - 第1话', fallback: 'tvbox'), 'tvbox');
      expect(danmakuChannelOf('灵笼 - 第1话', fallback: 'TVBox'), 'tvbox');
      expect(danmakuChannelOf('灵笼 - 第1话'), isNull);
      expect(danmakuChannelOf('', fallback: '  '), isNull);
    });
  });

  group('剧名分组键（对齐安卓 DanmakuTitle.cleanTitle，但保留年份）', () {
    test('真实中转名称 → 剧名（年份括注保留）', () {
      expect(
        danmakuTitleKeyOf(
          '灵笼 第二季(2025)【动漫】from bilibili - 【bilibili1】 第1话 末世桃源',
        ),
        '灵笼 第二季(2025)',
        reason: '年份是「同名不同剧」唯一的区分依据，洗掉就会把两部剧合成一组',
      );
      expect(
        danmakuTitleKeyOf(
          '灵笼:INCARNATION 终章(2021)【3D网络放送】from dandan - 【dandan】 第1话 上',
        ),
        '灵笼:INCARNATION 终章(2021)',
      );
    });

    test('年份分组：同名不同年份的两部剧不混组', () {
      expect(
        danmakuTitleKeyOf('一马当先(2026)【电视剧】from tencent - 【qq】 一马当先 第1集'),
        '一马当先(2026)',
      );
      expect(
        danmakuTitleKeyOf('一马当先(2023)【短剧】from hongguo - 【hongguo】 第1集'),
        '一马当先(2023)',
      );
      expect(
        danmakuTitleKeyOf(
          '灵笼 第二季(2025)【动漫】from bilibili - 【bilibili1】 第1话 末世桃源',
        ),
        '灵笼 第二季(2025)',
      );

      final groups = groupDanmakuEntries(
        entries: [
          entry(
            id: 't1',
            title: '一马当先(2026)【电视剧】from tencent - 【qq】 一马当先 第1集',
            episode: '第1集',
          ),
          entry(
            id: 'h1',
            title: '一马当先(2023)【短剧】from hongguo - 【hongguo】 第1集',
            episode: '第1集',
          ),
          entry(
            id: 't2',
            title: '一马当先(2026)【电视剧】from bilibili - 【qq】 一马当先 第2集',
            episode: '第2集',
          ),
        ],
      );
      expect(groups.map((group) => group.title), [
        '一马当先(2023)',
        '一马当先(2026)',
      ], reason: '同分时按剧名升序，但两个年份各自成组');
      expect(
        groups[1].entries.map((item) => item.id),
        ['t1', 't2'],
        reason: '同一年同一部剧的多来源仍然合并',
      );
      expect(groups[0].entries.map((item) => item.id), ['h1']);
    });

    test('没有 from 时按分隔符截断，再清标记（年份保留）', () {
      expect(
        danmakuTitleKeyOf('灵笼 第二季(2025)【动漫】 - 【bilibili1】 第1话'),
        '灵笼 第二季(2025)',
      );
      expect(danmakuTitleKeyOf('灵笼(2024)'), '灵笼(2024)');
      expect(danmakuTitleKeyOf('灵笼'), '灵笼', reason: '没有年份时保持原样');
    });

    test('解析不出剧名 → null（调用方归入未分类）', () {
      expect(danmakuTitleKeyOf(''), isNull);
      expect(danmakuTitleKeyOf('   '), isNull);
      expect(danmakuTitleKeyOf('【qq】'), isNull);
      expect(danmakuTitleKeyOf('from bilibili - 第1话'), isNull);
      expect(danmakuTitleKeyOf('https://example.test/a.xml'), isNull);
    });
  });

  group('集号解析', () {
    test('复用 extractEpisodeNumber 的语义', () {
      expect(danmakuEpisodeOf('【bilibili1】 第1话 末世桃源'), 1);
      expect(danmakuEpisodeOf('【dandan】 第12集'), 12);
      expect(danmakuEpisodeOf('第12-13集'), 12);
      expect(danmakuEpisodeOf('EP03'), 3);
      expect(danmakuEpisodeOf('S02E07'), 7);
      expect(danmakuEpisodeOf('第１０集'), 10, reason: '全角数字要归一后再解析');
      expect(danmakuEpisodeOf('灵笼'), isNull);
      expect(danmakuEpisodeOf(''), isNull);
    });
  });

  group('分组与排序', () {
    test('上游按字符串顺序到达时，仍按集号数值升序（不是字符串序）', () {
      // 中转可能按名字字符串返回 第1集/第10集/第11集/第12集/第2集…：
      // 只要集号解析正确，组内必须恢复成 1,2,3,…,10 的数值顺序。
      const relayOrder = ['第1集', '第10集', '第11集', '第12集', '第2集', '第3集'];
      final groups = groupDanmakuEntries(
        entries: [
          for (var index = 0; index < relayOrder.length; index++)
            entry(
              id: 'e$index',
              title: '一马当先(2026)【电视剧】from tencent',
              episode: '【qq】 一马当先 ${relayOrder[index]}',
            ),
        ],
      );
      expect(groups.single.entries.map((item) => danmakuEpisodeOf(item.episode)), [
        1,
        2,
        3,
        10,
        11,
        12,
      ]);
    });

    test('集号字段优先：展示串解析不出也能按数值排', () {
      DanmakuLibraryEntry numbered(String id, String episode, int number) =>
          DanmakuLibraryEntry(
            providerId: 'qq',
            id: id,
            title: '一马当先(2026)【电视剧】from tencent',
            episode: episode,
            url: 'https://cdn.test/$id.xml',
            episodeNumber: number,
          );
      final groups = groupDanmakuEntries(
        entries: [
          // 展示串故意写成解析不出的形态：排序必须只认 episodeNumber。
          numbered('n10', '第某话 集名', 10),
          numbered('n2', '第某话 集名', 2),
          numbered('n1', '第某话 集名', 1),
        ],
      );
      expect(groups.single.entries.map((item) => item.id), ['n1', 'n2', 'n10']);
    });

    test('组间按最高分降序、同分按剧名升序，未分类永远最后', () {
      final groups = groupDanmakuEntries(
        entries: [
          entry(
            id: 'a1',
            title: '灵笼 第二季(2025)【动漫】from bilibili',
            episode: '【bilibili1】 第1话',
            score: 0.4,
          ),
          entry(
            id: 'a2',
            title: '灵笼 第二季(2025)【动漫】from dandan',
            episode: '【dandan】 第2话',
            score: 0.8,
          ),
          entry(
            id: 'b1',
            title: '斗罗大陆(2021)【动漫】from tencent',
            episode: '【tencent】 第1话',
            score: 0.5,
          ),
          // 未分类的分数最高，也必须排在最后。
          entry(id: 'c1', title: '', episode: '第1话', score: 0.99),
        ],
      );

      expect(groups.map((group) => group.title), [
        '灵笼 第二季(2025)',
        '斗罗大陆(2021)',
        kDanmakuUnclassifiedTitle,
      ]);
      expect(groups.first.bestScore, 0.8);
      expect(groups.first.hasRating, isTrue);
      expect(groups.first.entries.map((item) => item.id), ['a1', 'a2']);
      expect(groups.last.entries.map((item) => item.id), ['c1']);
    });

    test('同分按剧名升序', () {
      final groups = groupDanmakuEntries(
        entries: [
          entry(id: 'x', title: 'B站独播 from qq', episode: '第1话'),
          entry(id: 'y', title: 'A站独播 from qq', episode: '第1话'),
        ],
      );
      expect(groups.map((group) => group.title), ['A站独播', 'B站独播']);
      expect(groups.every((group) => group.hasRating), isFalse);
      expect(groups.first.bestScore, 0);
    });

    test('组内集号升序/降序，解析不出集号的排末尾', () {
      final entries = [
        entry(id: 'e3', title: '灵笼 from bilibili', episode: '第3话'),
        entry(id: 'e1', title: '灵笼 from bilibili', episode: '第1话'),
        entry(id: 'ex', title: '灵笼 from bilibili'),
        entry(id: 'e2', title: '灵笼 from bilibili', episode: '第2话'),
      ];

      expect(
        groupDanmakuEntries(entries: entries).single.entries.map((e) => e.id),
        ['e1', 'e2', 'e3', 'ex'],
      );
      expect(
        groupDanmakuEntries(
          entries: entries,
          reverse: true,
        ).single.entries.map((e) => e.id),
        ['e3', 'e2', 'e1', 'ex'],
        reason: '倒序时解析不出集号的仍在末尾',
      );
    });

    test('集号按数值排序：第10集排在第2集之后', () {
      final entries = [
        entry(id: 'e10', title: '灵笼 from bilibili', episode: '第10集'),
        entry(id: 'e2', title: '灵笼 from bilibili', episode: '第2集'),
        entry(id: 'e1', title: '灵笼 from bilibili', episode: '第1集'),
      ];

      expect(
        groupDanmakuEntries(entries: entries).single.entries.map((e) => e.id),
        ['e1', 'e2', 'e10'],
        reason: '按字符串比会得到 1 < 10 < 2，第2集就跑到第10集后面了',
      );
      expect(
        groupDanmakuEntries(
          entries: entries,
          reverse: true,
        ).single.entries.map((e) => e.id),
        ['e10', 'e2', 'e1'],
      );
    });

    test('同集号保持原输入顺序（同一集的多条弹幕源）', () {
      final entries = [
        entry(id: 'tencent-1', title: '一马当先(2026)', episode: '第1集'),
        entry(id: 'hongguo-1', title: '一马当先(2026)', episode: '第1集'),
        entry(id: 'tencent-2', title: '一马当先(2026)', episode: '第2集'),
        entry(id: 'hongguo-2', title: '一马当先(2026)', episode: '第2集'),
      ];

      expect(
        groupDanmakuEntries(entries: entries).single.entries.map((e) => e.id),
        ['tencent-1', 'hongguo-1', 'tencent-2', 'hongguo-2'],
        reason: '同集号不参与比较，按输入顺序摆，排序不会让它们抖动',
      );
    });

    test('空输入 → 空分组', () {
      expect(groupDanmakuEntries(entries: const []), isEmpty);
    });
  });

  group('标题信息解析（名称/年份/季/类型）', () {
    test('年份与类型：一马当先(2026)【电视剧】', () {
      final info = parseDanmakuTitleInfo('一马当先(2026)【电视剧】');
      expect(info.base, '一马当先', reason: '年份/类型标记都要从名称里去掉');
      expect(info.year, 2026);
      expect(info.type, '电视剧');
      expect(info.season, isNull);
    });

    test('季：灵笼 第二季(2025)【动漫】', () {
      final info = parseDanmakuTitleInfo('灵笼 第二季(2025)【动漫】');
      expect(info.base, '灵笼');
      expect(info.season, 2);
      expect(info.year, 2025);
      expect(info.type, '动漫');
    });

    test('S02E07 里的 S02 不算季', () {
      final info = parseDanmakuTitleInfo('灵笼 S02E07');
      expect(
        info.season,
        isNull,
        reason: 'S02E07 读作「第2季第7集」，但那个 S02 首先是集号的一部分',
      );
      expect(info.base, '灵笼 S02E07', reason: '认不出的标记原样留在名称里');
    });

    test('Season 2 / 第三季 也认', () {
      expect(parseDanmakuTitleInfo('灵笼 Season 2').season, 2);
      expect(parseDanmakuTitleInfo('灵笼 第三季').season, 3);
      expect(parseDanmakuTitleInfo('灵笼 S2').season, 2);
    });

    test('没有年份/季/类型时对应字段为 null', () {
      final info = parseDanmakuTitleInfo('灵笼');
      expect(info.base, '灵笼');
      expect(info.year, isNull);
      expect(info.season, isNull);
      expect(info.type, isNull);
    });

    test('来源标记不当成类型，【2026】当成年份', () {
      expect(
        parseDanmakuTitleInfo('灵笼 第二季(2025)【bilibili1】').type,
        isNull,
        reason: '【bilibili1】是渠道；当类型会让同片不同源互相压低',
      );
      expect(parseDanmakuTitleInfo('一马当先【2026】').year, 2026);
    });
  });

  group('多维相似度（design/02 §2.3）', () {
    DanmakuLibraryEntry item(
      String id,
      String title, {
      String episode = '第1集',
      int? episodeNumber,
    }) => DanmakuLibraryEntry(
      providerId: 'relay',
      id: id,
      title: title,
      episode: episode,
      url: 'https://cdn.test/$id.xml',
      episodeNumber: episodeNumber,
    );

    test('同年同名 > 异年同名', () {
      final query = danmakuQuery(title: '一马当先', year: 2026);
      final same = danmakuEntrySimilarity(
        entry: item('same', '一马当先(2026)【电视剧】'),
        query: query,
      );
      final other = danmakuEntrySimilarity(
        entry: item('other', '一马当先(2023)【电视剧】'),
        query: query,
      );
      expect(
        same,
        greaterThan(other),
        reason: '名称、类型一致，只有年份不同：年份维度必须拉开差距',
      );
    });

    test('同季 > 异季', () {
      final query = danmakuQuery(title: '灵笼 第二季');
      final second = danmakuEntrySimilarity(
        entry: item('s2', '灵笼 第二季(2025)【动漫】from bilibili'),
        query: query,
      );
      final first = danmakuEntrySimilarity(
        entry: item('s1', '灵笼 第一季(2019)【动漫】from dandan'),
        query: query,
      );
      expect(
        second,
        greaterThan(first),
        reason: '两季的名称去掉季标记后完全同形，只靠季维度才分得开',
      );
    });

    test('类型不一致 < 类型一致', () {
      final query = danmakuQuery(title: '一马当先【电视剧】');
      final drama = danmakuEntrySimilarity(
        entry: item('drama', '一马当先【电视剧】from tencent'),
        query: query,
      );
      final short = danmakuEntrySimilarity(
        entry: item('short', '一马当先【短剧】from hongguo'),
        query: query,
      );
      expect(drama, greaterThan(short));
    });

    test('集号字段优先：展示串解析不出时仍按数值判一致', () {
      final query = danmakuQuery(episode: '第3集');
      final byField = danmakuEntrySimilarity(
        entry: item('field', '灵笼', episode: '第某话 集名', episodeNumber: 3),
        query: query,
      );
      final byText = danmakuEntrySimilarity(
        entry: item('text', '灵笼', episode: '第2话'),
        query: query,
      );
      expect(byField, greaterThan(byText));
    });

    test('scoreDanmakuEntry 与 danmakuEntrySimilarity 同值（同一个算法）', () {
      final query = danmakuQuery(title: '灵笼 第二季', year: 2025);
      final entry = item('x', '灵笼 第二季(2025)【动漫】from bilibili');
      expect(
        scoreDanmakuEntry(entry: entry, query: query),
        danmakuEntrySimilarity(entry: entry, query: query),
      );
    });
  });

  group('分组按相似度排序（design/02 §2.3）', () {
    test('年份：query 带 2026 时 2026 组排在 2023 组之前', () {
      final groups = groupDanmakuEntries(
        entries: [
          entry(
            id: 'y2023',
            title: '一马当先(2023)【电视剧】from hongguo',
            episode: '第1集',
          ),
          entry(
            id: 'y2026',
            title: '一马当先(2026)【电视剧】from tencent',
            episode: '第1集',
          ),
        ],
        query: danmakuQuery(title: '一马当先', year: 2026),
      );
      expect(groups.map((group) => group.title), [
        '一马当先(2026)',
        '一马当先(2023)',
      ], reason: '旧规则按剧名升序会把 2023 排前面，那时用户看到的就是错的那部');
    });

    test('季：query 带「第二季」时第二季组在前', () {
      final groups = groupDanmakuEntries(
        entries: [
          entry(
            id: 's1',
            title: '灵笼 第一季(2019)【动漫】from dandan',
            episode: '第1话',
          ),
          entry(
            id: 's2',
            title: '灵笼 第二季(2025)【动漫】from bilibili',
            episode: '第1话',
          ),
        ],
        query: danmakuQuery(title: '灵笼 第二季', episode: '第1话'),
      );
      expect(groups.map((group) => group.title), [
        '灵笼 第二季(2025)',
        '灵笼 第一季(2019)',
      ]);
    });

    test('集号存在性加分：仅靠「含本集」的 0.05 反超标题分更高的组', () {
      // 数值是算好的：A 的标题复合分 0.73、含本集，B 的 0.96、无集号信息。
      // 0.7*0.73+0.3 = 0.811 < 0.7*0.96+0.15 = 0.822（没有加分时 B 在前），
      // 加上 0.05 后 0.861 > 0.822：这个用例只有加分存在才会通过。
      final groups = groupDanmakuEntries(
        entries: [
          entry(
            id: 'covers',
            title: '灵笼:INCARNATION(2023) 第二季',
            episode: '第2集',
          ),
          entry(id: 'nofinfo', title: '灵笼(2026)'),
        ],
        query: danmakuQuery(episode: '第2集', year: 2026),
      );
      expect(groups.map((group) => group.title), [
        '灵笼:INCARNATION(2023) 第二季',
        '灵笼(2026)',
      ]);
    });

    test('覆盖度打平：同相似度时条目多的组在前', () {
      final entries = [
        entry(
          id: 'a1',
          title: '灵笼:INCARNATION(2026) from bilibili',
          episode: '第1集',
        ),
        entry(
          id: 'a2',
          title: '灵笼:INCARNATION(2026) from dandan',
          episode: '第2集',
        ),
        entry(id: 'b1', title: '灵笼 前传(2026) from qq', episode: '第1集'),
      ];
      final query = danmakuQuery(year: 2026);
      final groups = groupDanmakuEntries(entries: entries, query: query);
      expect(groups.map((group) => group.title), [
        '灵笼:INCARNATION(2026)',
        '灵笼 前传(2026)',
      ], reason: '两组的最像条目同分，条目多的那组更像正主');
      // 不传 query 的旧调用方仍按剧名升序：这里恰好把顺序反过来。
      expect(
        groupDanmakuEntries(entries: entries).map((group) => group.title),
        ['灵笼 前传(2026)', '灵笼:INCARNATION(2026)'],
        reason: '旧调用方（没有查询上下文）的行为不得变化',
      );
    });

    test('传了 query 时「未分类」仍排最后', () {
      final groups = groupDanmakuEntries(
        entries: [
          // 没有剧名（`from` 开头即截断）→ 未分类；它的相似度并不低。
          entry(
            id: 'u',
            title: 'from bilibili - 一马当先(2026)',
            episode: '第1集',
          ),
          entry(
            id: 'k',
            title: '一马当先(2026)【电视剧】from tencent',
            episode: '第1集',
          ),
        ],
        query: danmakuQuery(title: '一马当先', year: 2026),
      );
      expect(groups.last.title, kDanmakuUnclassifiedTitle);
    });
  });
}
