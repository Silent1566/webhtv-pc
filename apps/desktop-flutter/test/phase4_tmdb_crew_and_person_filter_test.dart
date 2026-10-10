/// 制作团队与人物页筛选（用户反馈 2026-10-10，对齐默影视）。
///
/// 三条反馈：
/// 1. 「制作团队应该放在演员下方」——原顺序是
///    剧照→海报→演职人员→**相关推荐→相关视频**→制作团队，被两个大区块隔开。
///    默影视 `activity_tmdb_detail.xml` 的顺序是 castTitle → creatorTitle → relatedTitle。
/// 2. 「制作团队没有标明身份比如：导演，编剧等」——原实现把 TMDB 的 `job` 原文
///    （`Screenplay`）当副标题，甚至部分条目**完全没有副标题**。
///    默影视 `TmdbService#creatorJob` 把 job/department 归一成「导演/编剧/制片」
///    并按该顺序排序。
/// 3. 「人员介绍页也不支持按分类筛选：电视，电影，参演，导演等」——
///    默影视 `TmdbPersonWorkFilters` 提供两个正交维度（部门 / 类型），
///    选项带计数，取交集。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/person_work_filters.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

/// 造一条 `credits.crew` 原始条目。
Map<Object?, Object?> _crew(
  int id,
  String name, {
  String job = '',
  String department = '',
}) => {'id': id, 'name': name, 'job': job, 'department': department};

/// 造一条作品（`TmdbPersonWork`）。
TmdbPersonWork _work(
  int id,
  TmdbMediaType type, {
  String title = '作品',
  String character = '',
  String job = '',
  String department = '',
}) => TmdbPersonWork(
  item: TmdbItem(tmdbId: id, mediaType: type, title: title),
  character: character,
  job: job,
  department: department,
);

void main() {
  group('制作团队身份归一（对齐默影视 creatorJob）', () {
    test('director / directing → 导演', () {
      expect(tmdbCreatorJobLabel('Director', 'Directing'), '导演');
      expect(tmdbCreatorJobLabel('Assistant Director', ''), '导演');
      expect(tmdbCreatorJobLabel('', 'Directing'), '导演');
    });

    test('writer / screenplay / story / teleplay / writing → 编剧', () {
      expect(tmdbCreatorJobLabel('Screenplay', ''), '编剧');
      expect(tmdbCreatorJobLabel('Writer', ''), '编剧');
      expect(tmdbCreatorJobLabel('Story', ''), '编剧');
      expect(tmdbCreatorJobLabel('Teleplay', ''), '编剧');
      expect(tmdbCreatorJobLabel('', 'Writing'), '编剧');
    });

    test('producer / production → 制片', () {
      expect(tmdbCreatorJobLabel('Producer', ''), '制片');
      expect(tmdbCreatorJobLabel('Executive Producer', ''), '制片');
      expect(tmdbCreatorJobLabel('', 'Production'), '制片');
    });

    test('不可读的身份返回 null（不把 Lighting 这类英文原样上屏）', () {
      expect(tmdbCreatorJobLabel('Lighting', 'Lighting'), isNull);
      expect(tmdbCreatorJobLabel('Camera', ''), isNull);
      expect(tmdbCreatorJobLabel('', ''), isNull);
    });

    test('导演优先于编剧（job 同时命中两个词表时）', () {
      // `Director` 命中 directing 组，同时也是 writing？——不应发生；
      // 这里锁定优先级顺序：先判导演。
      expect(tmdbCreatorJobLabel('Director', 'Writing'), '导演');
    });
  });

  group('制作团队列表：合并身份 + 排序 + 过滤', () {
    test('同一人多个身份合并为「导演 / 编剧」', () {
      final team = tmdbCreatorTeam([
        _crew(1, '张三', job: 'Director', department: 'Directing'),
        _crew(1, '张三', job: 'Writer', department: 'Writing'),
      ]);
      expect(team, hasLength(1));
      expect(team.first.name, '张三');
      expect(team.first.subtitle, '导演 / 编剧');
    });

    test('导演排在编剧/制片之前', () {
      final team = tmdbCreatorTeam([
        _crew(3, '制片人', job: 'Producer', department: 'Production'),
        _crew(2, '编剧甲', job: 'Screenplay', department: 'Writing'),
        _crew(1, '导演甲', job: 'Director', department: 'Directing'),
      ]);
      expect(
        team.map((p) => p.subtitle).toList(),
        ['导演', '编剧', '制片'],
        reason: '对齐默影视 creatorJobOrder：导演 0 / 编剧 1 / 制片 2',
      );
    });

    test('没有可读身份的人被丢掉（不上屏无意义的英文职务）', () {
      final team = tmdbCreatorTeam([
        _crew(1, '导演甲', job: 'Director', department: 'Directing'),
        _crew(2, '灯光师', job: 'Lighting', department: 'Lighting'),
      ]);
      expect(team.map((p) => p.name), ['导演甲']);
    });

    test('上限 12 条（对齐默影视）', () {
      final team = tmdbCreatorTeam([
        for (var i = 1; i <= 20; i++)
          _crew(i, '导演$i', job: 'Director', department: 'Directing'),
      ]);
      expect(team, hasLength(12));
    });

    test('同权重保持原始顺序（稳定排序）', () {
      final team = tmdbCreatorTeam([
        _crew(1, '导演甲', job: 'Director', department: 'Directing'),
        _crew(2, '导演乙', job: 'Director', department: 'Directing'),
        _crew(3, '导演丙', job: 'Director', department: 'Directing'),
      ]);
      expect(team.map((p) => p.name), ['导演甲', '导演乙', '导演丙']);
    });
  });

  group('详情页区块顺序：制作团队紧跟演职人员（用户反馈）', () {
    testWidgets('制作团队排在演职人员之后、相关推荐之前', (tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 造出四个区块都有数据的详情，才能比较它们的先后。
      final data = TmdbDetailData.fromDetail({
        'id': 1399,
        'name': '示例剧集',
        'credits': {
          'cast': [
            {'id': 1, 'name': '演员甲', 'character': '主角'},
          ],
          'crew': [
            {'id': 9, 'name': '导演甲', 'job': 'Director', 'department': 'Directing'},
          ],
        },
      }, imageBase: 'https://img/t/p/w342', backdropBase: 'https://img/t/p/w780');

      expect(data.creatorTeam, isNotEmpty, reason: '前置条件：应解析出制作团队');

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TmdbDetailSections(
                data: data,
                recommendations: [
                  TmdbItem(
                    tmdbId: 2,
                    mediaType: TmdbMediaType.movie,
                    title: '相关推荐甲',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      double topOf(String key) => tester
          .getTopLeft(find.byKey(ValueKey(key)))
          .dy;

      final people = topOf('tmdb-section-people');
      final crew = topOf('tmdb-section-crew');
      final related = topOf('tmdb-section-recommendations');

      expect(
        crew,
        greaterThan(people),
        reason: '制作团队应在演职人员**下方**（用户反馈：「制作团队应该放在演员下方」）',
      );
      expect(
        crew,
        lessThan(related),
        reason: '制作团队不应被「相关推荐」隔开（对齐默影视 cast→creator→related）',
      );
    });

    testWidgets('制作团队标注身份（导演/编剧），不是空白副标题', (tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final data = TmdbDetailData.fromDetail({
        'id': 1399,
        'name': '示例剧集',
        'credits': {
          'cast': const [],
          'crew': [
            {'id': 9, 'name': '导演甲', 'job': 'Director', 'department': 'Directing'},
            {'id': 10, 'name': '编剧乙', 'job': 'Screenplay', 'department': 'Writing'},
          ],
        },
      }, imageBase: 'https://img/t/p/w342', backdropBase: 'https://img/t/p/w780');

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(child: TmdbDetailSections(data: data)),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('tmdb-section-crew')),
        findsOneWidget,
        reason: '制作团队区块应渲染',
      );
      expect(
        find.text('导演'),
        findsWidgets,
        reason: '制作团队必须标明身份「导演」（用户反馈：没有标明身份）',
      );
      expect(find.text('编剧'), findsWidgets, reason: '编剧同样要标明');
    });
  });

  group('人物作品筛选（对齐默影视 TmdbPersonWorkFilters）', () {
    PersonWorkFilters build() => PersonWorkFilters.from(
      // cast：出演
      [
        _work(1, TmdbMediaType.movie, title: '电影甲', character: '主角'),
        _work(2, TmdbMediaType.tv, title: '剧集甲', character: '配角'),
      ],
      // crew：导演 / 编剧
      [
        _work(
          1,
          TmdbMediaType.movie,
          title: '电影甲',
          job: 'Director',
          department: 'Directing',
        ),
        _work(
          3,
          TmdbMediaType.tv,
          title: '剧集乙',
          job: 'Screenplay',
          department: 'Writing',
        ),
      ],
    );

    test('部门选项含「全部部门」，计数为去重后的作品数', () {
      final options = build().departmentOptions();
      expect(options.first.key, PersonWorkDepartment.all);
      expect(options.first.label, '全部部门');
      expect(options.first.count, 3, reason: '电影甲/剧集甲/剧集乙 共 3 部（电影甲去重）');
      expect(
        options.map((o) => o.label),
        containsAll(<String>['出演', '导演', '编剧']),
      );
    });

    test('类型选项含「全部类型 / 电影 / 剧集」及计数', () {
      final options = build().mediaOptions();
      expect(options.map((o) => o.label), ['全部类型', '电影', '剧集']);
      expect(options[1].count, 1, reason: '电影只有「电影甲」');
      expect(options[2].count, 2, reason: '剧集有「剧集甲」「剧集乙」');
    });

    test('两个维度都是「全部」时返回全部（去重）', () {
      final result = build().filter();
      expect(result.map((w) => w.item.title), ['电影甲', '剧集甲', '剧集乙']);
    });

    test('只看部门：出演 → 该人出演的作品', () {
      final result = build().filter(department: PersonWorkDepartment.cast);
      expect(result.map((w) => w.item.title), ['电影甲', '剧集甲']);
    });

    test('只看类型：剧集 → 该人参与的全部剧集', () {
      final result = build().filter(media: PersonWorkMedia.tv);
      expect(result.map((w) => w.item.title), ['剧集甲', '剧集乙']);
    });

    test('两个维度取交集：导演 + 电影 → 只有电影甲', () {
      final result = build().filter(
        department: PersonWorkDepartment.of('导演'),
        media: PersonWorkMedia.movie,
      );
      expect(result.map((w) => w.item.title), ['电影甲']);
    });

    test('交集为空时返回空列表（UI 需显示空态，不能崩）', () {
      final result = build().filter(
        department: PersonWorkDepartment.of('编剧'),
        media: PersonWorkMedia.movie,
      );
      expect(result, isEmpty, reason: '编剧只参与剧集乙，没有电影作品');
    });

    test('同一作品既在 cast 又在 crew 时只出现一次', () {
      final filters = build();
      expect(
        filters.all.where((w) => w.item.tmdbId == 1),
        hasLength(1),
        reason: '电影甲同时在 cast 与 crew，必须按 (mediaType, tmdbId) 去重',
      );
    });

    test('认不出身份且不是出演的 crew 归入「其他」', () {
      final filters = PersonWorkFilters.from(
        const [],
        [_work(9, TmdbMediaType.movie, title: '某片', job: 'Lighting')],
      );
      expect(
        filters.departmentOptions().map((o) => o.label),
        contains('其他'),
      );
    });
  });

  group('人物页 UI：筛选 chip 真的渲染并可切换（测**真实组件**）', () {
    testWidgets('渲染部门与类型两组 chip，点击回调带正确键', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final filters = PersonWorkFilters.from(
        [
          _work(1, TmdbMediaType.movie, title: '电影甲', character: '主角'),
          _work(2, TmdbMediaType.tv, title: '剧集甲', character: '配角'),
        ],
        [
          _work(
            3,
            TmdbMediaType.tv,
            title: '剧集乙',
            job: 'Director',
            department: 'Directing',
          ),
        ],
      );

      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                // 用**生产组件本身**（不是复刻一份），否则改坏生产代码门禁也不会响。
                PersonWorkFilterRow(
                  keyValue: 'test-department',
                  options: filters.departmentOptions(),
                  selected: PersonWorkDepartment.all,
                  onSelected: (key) => picked = key,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // 选项文案带计数（本用例 crew 是 Director，故部门为 出演/导演）。
      expect(find.text('全部部门 3'), findsOneWidget);
      expect(find.text('出演 2'), findsOneWidget);
      expect(find.text('导演 1'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('test-department-department:导演')),
      );
      await tester.pump();
      expect(picked, PersonWorkDepartment.of('导演'));
    });

    testWidgets('编剧（Screenplay）也出现在部门选项里', (tester) async {
      tester.view.physicalSize = const Size(1200, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final filters = PersonWorkFilters.from(
        const [],
        [
          _work(
            3,
            TmdbMediaType.tv,
            title: '剧集乙',
            job: 'Screenplay',
            department: 'Writing',
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: PersonWorkFilterRow(
              keyValue: 'test-writing',
              options: filters.departmentOptions(),
              selected: PersonWorkDepartment.all,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('编剧 1'), findsOneWidget);
    });

    testWidgets('选中态用主色（可辨识当前筛选）', (tester) async {
      tester.view.physicalSize = const Size(1200, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final filters = PersonWorkFilters.from(
        [_work(1, TmdbMediaType.movie, title: '电影甲', character: '主角')],
        const [],
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: PersonWorkFilterRow(
              keyValue: 'test-media',
              options: filters.mediaOptions(),
              selected: PersonWorkMedia.movie,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();

      final selectedText = tester.widget<Text>(find.text('电影 1'));
      final unselectedText = tester.widget<Text>(find.text('全部类型 1'));
      expect(
        selectedText.style?.color,
        isNot(unselectedText.style?.color),
        reason: '选中项应与未选中项视觉可辨（主色 vs onSurfaceVariant）',
      );
    });
  });
}
