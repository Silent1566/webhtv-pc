/// 播放器「选集」面板（`lib/ui/player_episode_panel.dart`）的行为锁。
///
/// 锁的是这一轮真正会翻车的几处：
/// - 面板能打开、卡片数 = 当前区间的集数（分组用的是 `EpisodeRangePolicy`，
///   所以这里同时校验分组结果真的落到了网格上）；
/// - 切区间后卡片数跟着变（区间与网格的下标换算最易错位）；
/// - 点卡片 = 切集 + 关面板，且回调拿到的是**线路 + 绝对下标**；
/// - 点线路 chip 只换预览：不关面板、不起播，集数/卡片/标题区跟着预览线路换；
/// - 预览别的线路时不谎报播放状态（没有「正在播放」高亮）；
/// - 每条线路用**自己那份**卡片，数量对不上就退回集名文字卡（不串图）；
/// - 剧照缺席时回退本剧海报（与详情页同一条回退）；
/// - 只有一条线路时不渲染线路行（否则一排单元素 chip 纯属噪音）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/ui/player_episode_panel.dart';
import 'package:webhtv_pc/ui/poster_image.dart';
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
  Map<String, List<TmdbEpisodeCard>> cardsByFlag = const {},
  int episodeIndex = 0,
  bool reversed = false,
  PlayerEpisodeTap? onSelectEpisode,
  String? posterUrl,
  String title = '测试剧',
  String lineFlag = '线路1',
}) {
  return PlayerEpisodePanel(
    title: title,
    playLines: lines ?? _lines([6]),
    lineFlag: lineFlag,
    episodeIndex: episodeIndex,
    episodeCardsByFlag: cardsByFlag,
    posterUrl: posterUrl,
    reversed: reversed,
    onSelectEpisode: onSelectEpisode ?? (_, _) {},
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
    expect(find.textContaining('线路1 · 共 6 集'), findsOneWidget);
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

  testWidgets('点卡片：触发切集回调（线路 + 绝对下标）并关闭面板', (tester) async {
    final tapped = <String>[];
    await _open(
      tester,
      _panel(
        lines: _lines([45]),
        episodeIndex: 0,
        onSelectEpisode: (flag, index) => tapped.add('$flag:$index'),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('player-episode-range-1')));
    await tester.pumpAndSettle();
    // 第 2 区间的第 1 张卡是第 21 集 → 绝对下标 20（不是区间内的 0）。
    await tester.tap(find.byKey(const ValueKey('player-episode-card-20')));
    await tester.pumpAndSettle();

    expect(tapped, ['线路1:20']);
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

  testWidgets('点另一条线路：只换预览，不关面板、不起播', (tester) async {
    final played = <String>[];
    await _open(
      tester,
      _panel(
        lines: _lines([6, 4]),
        onSelectEpisode: (flag, index) => played.add('$flag:$index'),
      ),
    );

    await tester.tap(find.text('线路2'));
    await tester.pumpAndSettle();

    // 面板还在、没有任何播放回调：点线路不是播放动作。
    expect(find.byKey(_panelKey), findsOneWidget);
    expect(played, isEmpty);
    // 集数、标题区与网格都跟着预览线路走。
    expect(_gridItemCount(tester), 4);
    expect(find.textContaining('线路2 · 共 4 集'), findsOneWidget);
    expect(
      find.textContaining('点集数卡片起播'),
      findsOneWidget,
      reason: '画面不会变，必须说明起播发生在点集数卡片那一下',
    );
  });

  testWidgets('预览线路后点卡片：回调带回预览线路的 flag（不是正在播放的那条）', (tester) async {
    final played = <String>[];
    await _open(
      tester,
      _panel(
        lines: _lines([6, 4]),
        onSelectEpisode: (flag, index) => played.add('$flag:$index'),
      ),
    );

    await tester.tap(find.text('线路2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-episode-card-2')));
    await tester.pumpAndSettle();

    expect(played, ['线路2:2']);
    expect(find.byKey(_panelKey), findsNothing);
  });

  testWidgets('预览别的线路时落在对应集上，但不画「正在播放」', (tester) async {
    await _open(tester, _panel(lines: _lines([45, 45]), episodeIndex: 25));

    await tester.tap(find.text('线路2'));
    await tester.pumpAndSettle();

    // 区间跟着「同一集」走（第 26 集 → 21-40），不是回到第一段。
    expect(
      find.byKey(const ValueKey('player-episode-range-1')),
      findsOneWidget,
    );
    expect(_gridItemCount(tester), 20);
    // 那一集并没有在播：不能留「正在播放」高亮，否则等于谎报播放状态。
    expect(find.text('正在播放'), findsNothing);
    final tile = tester.widget<Container>(
      find.byKey(const ValueKey('player-episode-card-25')),
    );
    final border = (tile.decoration! as BoxDecoration).border! as Border;
    expect(border.top.width, 1);
  });

  testWidgets('没有 TMDB 卡片时退化为集名文字卡，不崩', (tester) async {
    await _open(tester, _panel(lines: _lines([3])));

    expect(_gridItemCount(tester), 3);
    expect(find.text('第1集'), findsOneWidget);
    expect(find.text('第2集'), findsOneWidget);
  });

  testWidgets('卡片数与**该线路**集数不等时，那条线路整体退回集名文字卡', (tester) async {
    await _open(
      tester,
      _panel(
        lines: _lines([3, 3]),
        cardsByFlag: {
          // 线路1 对得上（3 集 3 张卡）。
          '线路1': const [
            TmdbEpisodeCard(number: 1, title: '线路一首集'),
            TmdbEpisodeCard(number: 2, title: '线路一第二集'),
            TmdbEpisodeCard(number: 3, title: '线路一第三集'),
          ],
          // 线路2 只有 2 张卡：按下标贴会把第 2 张的图贴到第 3 集上。
          '线路2': const [
            TmdbEpisodeCard(number: 1, title: '线路二首集'),
            TmdbEpisodeCard(number: 2, title: '线路二第二集'),
          ],
        },
      ),
    );

    expect(find.text('线路一首集'), findsOneWidget);

    await tester.tap(find.text('线路2'));
    await tester.pumpAndSettle();

    expect(_gridItemCount(tester), 3);
    expect(find.text('线路二首集'), findsNothing);
    expect(find.text('第3集'), findsOneWidget);
  });

  testWidgets('卡片按预览线路取：线路2 用自己的卡片，切回来还是线路1 的', (tester) async {
    await _open(
      tester,
      _panel(
        lines: _lines([2, 2]),
        cardsByFlag: {
          '线路1': const [
            TmdbEpisodeCard(number: 1, title: '线路一首集'),
            TmdbEpisodeCard(number: 2, title: '线路一第二集'),
          ],
          '线路2': const [
            TmdbEpisodeCard(number: 1, title: '线路二首集'),
            TmdbEpisodeCard(number: 2, title: '线路二第二集'),
          ],
        },
      ),
    );

    expect(find.text('线路一首集'), findsOneWidget);
    expect(find.text('线路二首集'), findsNothing);

    await tester.tap(find.text('线路2'));
    await tester.pumpAndSettle();
    expect(find.text('线路二首集'), findsOneWidget);
    expect(find.text('线路一首集'), findsNothing);

    await tester.tap(find.text('线路1'));
    await tester.pumpAndSettle();
    expect(find.text('线路一首集'), findsOneWidget);
    expect(find.text('线路二首集'), findsNothing);
  });

  testWidgets('有卡片时：剧照缺失用占位块，标题与副信息来自卡片', (tester) async {
    await _open(
      tester,
      _panel(
        lines: _lines([2]),
        cardsByFlag: {
          '线路1': const [
            TmdbEpisodeCard(
              number: 1,
              title: '试播集',
              date: '2024-03-01',
              runtime: 42,
            ),
            TmdbEpisodeCard(number: 2, title: '第二集'),
          ],
        },
      ),
    );

    expect(find.text('试播集'), findsOneWidget);
    expect(find.text('42m · 2024-03-01'), findsOneWidget);
    // 无剧照、也没有本剧海报：占位块中央显示集号，不放假图。
    expect(find.byType(Image), findsNothing);
    expect(find.text('E1'), findsOneWidget);
  });

  testWidgets('剧照缺失时回退本剧海报（与详情页同一条回退）', (tester) async {
    await _open(
      tester,
      _panel(
        lines: _lines([2]),
        posterUrl: 'https://img.test/poster.jpg',
        cardsByFlag: {
          '线路1': const [
            TmdbEpisodeCard(number: 1, title: '试播集'),
            TmdbEpisodeCard(number: 2, title: '第二集'),
          ],
        },
      ),
    );

    final still = tester.widget<PosterImage>(find.byType(PosterImage).first);
    expect(still.url, isNull, reason: '这两集没有剧照');
    expect(
      still.fallbackUrl,
      'https://img.test/poster.jpg',
      reason: '剧照缺席要显示整部剧的海报，而不是一块灰底',
    );
  });

  testWidgets('倒序：第一张卡是最后一集，区间标签方向跟着倒', (tester) async {
    // 45 集、当前集是原始下标 44（第 45 集）→ 倒序后它就是展示顺序的第 1 张。
    await _open(
      tester,
      _panel(lines: _lines([45]), reversed: true, episodeIndex: 44),
    );

    // 分组算法本身复用 `EpisodeRangePolicy`（倒序时余数段在最前），
    // 这里锁的是面板**真的**把 reversed 传下去了：标签方向与正序相反。
    expect(find.text('45-41'), findsOneWidget);
    expect(find.text('40-21'), findsOneWidget);
    expect(find.text('20-1'), findsOneWidget);
    expect(find.text('1-20'), findsNothing);

    // 当前集所在的区间被选中，网格里只有该区间的 5 张卡。
    expect(_gridItemCount(tester), 5);
    // 第一张卡的 key 是**原始下标** 44，文案是第 45 集（不是第 1 集）。
    expect(
      find.byKey(const ValueKey('player-episode-card-44')),
      findsOneWidget,
    );
    expect(find.text('第45集'), findsOneWidget);

    final tile = tester.widget<Container>(
      find.byKey(const ValueKey('player-episode-card-44')),
    );
    final border = (tile.decoration! as BoxDecoration).border! as Border;
    expect(border.top.width, 2, reason: '当前集在倒序下也必须强高亮');
  });

  testWidgets('倒序：点第一张卡，回调拿到的是原始下标（length-1）而不是 0', (tester) async {
    final tapped = <int>[];
    await _open(
      tester,
      _panel(
        lines: _lines([45]),
        reversed: true,
        episodeIndex: 44,
        onSelectEpisode: (_, index) => tapped.add(index),
      ),
    );

    // 展示顺序第 1 张 = 原始列表最后一张：映射漏了就会播成第 1 集。
    await tester.tap(find.byKey(const ValueKey('player-episode-card-44')));
    await tester.pumpAndSettle();

    expect(tapped, [44]);
    expect(tapped.first, isNot(0));
    expect(find.byKey(_panelKey), findsNothing);
  });

  testWidgets('倒序：卡片按展示顺序取（第 1 张用 cards[0]）', (tester) async {
    await _open(
      tester,
      _panel(
        lines: _lines([3]),
        reversed: true,
        episodeIndex: 0,
        // 详情页下发的是**展示顺序**的卡片：cards[0] 属于倒序后的第 1 张。
        cardsByFlag: {
          '线路1': const [
            TmdbEpisodeCard(number: 3, title: '最终话'),
            TmdbEpisodeCard(number: 2, title: '第二集'),
            TmdbEpisodeCard(number: 1, title: '首播集'),
          ],
        },
      ),
    );

    expect(_gridItemCount(tester), 3);
    // 原始下标 2 的卡排在最前，它的标题必须来自 cards[0]。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-episode-card-2')),
        matching: find.text('最终话'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-episode-card-0')),
        matching: find.text('首播集'),
      ),
      findsOneWidget,
    );
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
