/// 播放器「选集」面板（`lib/ui/player_episode_panel.dart`）的行为锁。
///
/// 锁的是这一轮真正会翻车的几处：
/// - 面板能打开、卡片数 = 当前区间的集数（分组用的是 `EpisodeRangePolicy`，
///   所以这里同时校验分组结果真的落到了网格上）；
/// - 切区间后卡片数跟着变（区间与网格的下标换算最易错位）；
/// - 点卡片 = 切集 + 关面板，且回调拿到的是**绝对下标**；
/// - 只有一条线路时不渲染线路行（否则一排单元素 chip 纯属噪音）；
/// - 没有 TMDB 卡片时退化为集名文字卡，不崩、不补集。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/ui/player_episode_panel.dart';
import 'package:webhtv_pc/ui/theme.dart';

const Key _panelKey = ValueKey('player-episode-panel');
const Key _gridKey = ValueKey('player-episode-grid');

List<VodEpisode> _episodes(int count, {String prefix = '第'}) => [
  for (var i = 1; i <= count; i++)
    VodEpisode(name: '$prefix$i集', url: 'https://example.test/$i.m3u8'),
];

List<VodPlayLine> _lines(List<int> counts) => [
  for (var i = 0; i < counts.length; i++)
    VodPlayLine(flag: '线路${i + 1}', episodes: _episodes(counts[i])),
];

PlayerEpisodePanel _panel({
  List<VodPlayLine>? lines,
  List<TmdbEpisodeCard> cards = const [],
  int episodeIndex = 0,
  ValueChanged<int>? onSelectEpisode,
  ValueChanged<String>? onSelectLine,
  String title = '测试剧',
  String lineLabel = '线路1',
  String lineFlag = '线路1',
}) {
  final playLines = lines ?? _lines([6]);
  return PlayerEpisodePanel(
    title: title,
    lineLabel: lineLabel,
    playLines: playLines,
    lineFlag: lineFlag,
    episodes: playLines.firstWhere((line) => line.flag == lineFlag).episodes,
    episodeCards: cards,
    episodeIndex: episodeIndex,
    onSelectEpisode: onSelectEpisode ?? (_) {},
    onSelectLine: onSelectLine ?? (_) {},
  );
}

/// 把面板放进真实的弹窗里打开（关闭行为必须和真实路径一致）。
Future<void> _open(WidgetTester tester, PlayerEpisodePanel panel) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  showDialog<void>(context: context, builder: (_) => panel),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

/// 网格声明了多少个格子（懒加载只构建可见项，所以数 widget 不可靠）。
int _gridItemCount(WidgetTester tester) {
  final grid = tester.widget<GridView>(find.byKey(_gridKey));
  return grid.childrenDelegate.estimatedChildCount ?? -1;
}

void main() {
  testWidgets('面板能打开，卡片数 = 当前区间的集数', (tester) async {
    await _open(tester, _panel());

    expect(find.byKey(_panelKey), findsOneWidget);
    expect(find.text('测试剧'), findsOneWidget);
    // 6 集 ≤ 20：只有一个区间，区间行不渲染。
    expect(find.byKey(const ValueKey('player-episode-range-0')), findsNothing);
    expect(_gridItemCount(tester), 6);
  });

  testWidgets('切区间后卡片数变化正确（45 集 → 20 / 20 / 5）', (tester) async {
    await _open(tester, _panel(lines: _lines([45])));

    expect(_gridItemCount(tester), 20);
    expect(find.text('1-20'), findsOneWidget);
    expect(find.text('21-40'), findsOneWidget);
    expect(find.text('41-45'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-episode-range-1')));
    await tester.pumpAndSettle();
    expect(_gridItemCount(tester), 20);

    await tester.tap(find.byKey(const ValueKey('player-episode-range-2')));
    await tester.pumpAndSettle();
    expect(_gridItemCount(tester), 5);
    // 第 3 区间的第一张卡是**第 41 集**（绝对下标 40，不是区间内的 0）。
    expect(
      find.byKey(const ValueKey('player-episode-card-40')),
      findsOneWidget,
    );
  });

  testWidgets('点卡片：触发切集回调（绝对下标）并关闭面板', (tester) async {
    final tapped = <int>[];
    await _open(
      tester,
      _panel(lines: _lines([45]), episodeIndex: 0, onSelectEpisode: tapped.add),
    );

    await tester.tap(find.byKey(const ValueKey('player-episode-range-1')));
    await tester.pumpAndSettle();
    // 第 2 区间的第 1 张卡是第 21 集 → 绝对下标 20（不是区间内的 0）。
    await tester.tap(find.byKey(const ValueKey('player-episode-card-20')));
    await tester.pumpAndSettle();

    expect(tapped, [20]);
    expect(
      find.byKey(_panelKey),
      findsNothing,
      reason: '点卡片必须关上面板，否则切集后面板还显示着上一集的高亮',
    );
  });

  testWidgets('打开时自动滚到当前集，并把当前集高亮', (tester) async {
    await _open(tester, _panel(lines: _lines([45]), episodeIndex: 25));

    // 当前集在第 2 个区间（21-40），区间随之选中，网格只有该区间的 20 张卡。
    expect(_gridItemCount(tester), 20);

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(_gridKey),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      scrollable.position.pixels,
      greaterThan(0),
      reason: '当前集在第 3 行，打开后必须已经滚过去，不能停在第一行',
    );

    final tile = tester.widget<Container>(
      find.byKey(const ValueKey('player-episode-card-25')),
    );
    final border = (tile.decoration! as BoxDecoration).border! as Border;
    expect(border.top.width, 2, reason: '当前集用强调色描边强高亮');
  });

  testWidgets('线路只有 1 条时不渲染线路行，多线路时渲染', (tester) async {
    await _open(tester, _panel(lines: _lines([6])));
    expect(
      find.byKey(const ValueKey('player-episode-line-strip')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await _open(tester, _panel(lines: _lines([6, 6])));
    expect(
      find.byKey(const ValueKey('player-episode-line-strip')),
      findsOneWidget,
    );
    expect(find.text('线路2'), findsOneWidget);
  });

  testWidgets('点另一条线路：回调收到线路 flag 并关闭面板', (tester) async {
    final switched = <String>[];
    await _open(
      tester,
      _panel(lines: _lines([6, 6]), onSelectLine: switched.add),
    );

    await tester.tap(find.text('线路2'));
    await tester.pumpAndSettle();

    expect(switched, ['线路2']);
    expect(find.byKey(_panelKey), findsNothing);
  });

  testWidgets('没有 TMDB 卡片时退化为集名文字卡，不崩', (tester) async {
    await _open(tester, _panel(lines: _lines([3])));

    expect(_gridItemCount(tester), 3);
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第2集'), findsOneWidget);
  });

  testWidgets('卡片数与集数不等（切到另一条线路）时全部退回集名文字卡', (tester) async {
    await _open(
      tester,
      _panel(
        lines: _lines([3]),
        // 详情页给的是**原线路**的卡片：数量对不上就不能按下标贴图。
        cards: [
          const TmdbEpisodeCard(number: 1, title: '试播集'),
          const TmdbEpisodeCard(number: 2, title: '第二集'),
        ],
      ),
    );

    expect(_gridItemCount(tester), 3);
    expect(find.text('试播集'), findsNothing);
    expect(find.text('第3集'), findsOneWidget);
  });

  testWidgets('有卡片时：剧照缺失用占位块，标题与副信息来自卡片', (tester) async {
    await _open(
      tester,
      _panel(
        lines: _lines([2]),
        cards: [
          const TmdbEpisodeCard(
            number: 1,
            title: '试播集',
            date: '2024-03-01',
            runtime: 42,
          ),
          const TmdbEpisodeCard(number: 2, title: '第二集'),
        ],
      ),
    );

    expect(find.text('试播集'), findsOneWidget);
    expect(find.text('42m · 2024-03-01'), findsOneWidget);
    // 无剧照：占位块中央显示集号，不放假图。
    expect(find.byType(Image), findsNothing);
    expect(find.text('E1'), findsOneWidget);
  });

  group('切线路续同集的定位顺序', () {
    test('集名完全相同优先', () {
      final target = [
        VodEpisode(name: '第01集', url: 'u1'),
        VodEpisode(name: '第02集 高清', url: 'u2'),
      ];
      expect(locateEpisodeInLine(episodes: target, currentName: '第02集 高清'), 1);
    });

    test('集名不同但集号相同', () {
      final target = [
        VodEpisode(name: 'EP01', url: 'u1'),
        VodEpisode(name: 'EP02', url: 'u2'),
        VodEpisode(name: 'EP03', url: 'u3'),
      ];
      expect(locateEpisodeInLine(episodes: target, currentName: '第03集'), 2);
    });

    test('集号也匹配不上 → 回第 1 集（不按位置猜）', () {
      final target = [
        VodEpisode(name: 'EP01', url: 'u1'),
        VodEpisode(name: 'EP02', url: 'u2'),
      ];
      expect(locateEpisodeInLine(episodes: target, currentName: '花絮'), 0);
      expect(locateEpisodeInLine(episodes: target, currentName: ''), 0);
    });

    test('集号取自最后一个数字段（S01E03 → 3）', () {
      expect(episodeNumberFromName('S01E03'), 3);
      expect(episodeNumberFromName('第 12 集'), 12);
      expect(episodeNumberFromName('正片'), isNull);
    });
  });
}
