/// 解析条的行为锁。
///
/// 锁的是这一轮真正会翻车的地方：
/// - 解析条只在**有可切换解析源**时被构造（少于两项不给入口）；
/// - 选中态跟着当前解析源走，点 chip 回调拿到的是**那个名称**；
/// - 选集弹窗不再有任何解析控件（它已经搬去控制区）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/player_episode_panel.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_parse_source_strip.dart';
import 'package:webhtv_pc/ui/theme.dart';

const Key _stripKey = ValueKey('player-parse-source-strip');

Widget _host(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(body: Center(child: child)),
);

Widget _overlay({Widget? extraRow}) => PlayerControlOverlay(
  topBar: AppBar(title: const Text('标题')),
  progressRow: const SizedBox(height: 24),
  actionButtons: const [Icon(Icons.play_arrow)],
  actionGroups: const [PlayerButtonGroup.transport],
  extraRow: extraRow,
);

void main() {
  group('解析条', () {
    testWidgets('三项解析源：每个都渲染，选中态落在当前源上', (tester) async {
      await tester.pumpWidget(
        _host(
          PlayerParseSourceStrip(
            sources: const ['超级解析', '虾米', '云解'],
            selected: '虾米',
            onSelect: (_) {},
          ),
        ),
      );

      expect(find.byKey(_stripKey), findsOneWidget);
      expect(find.text('超级解析'), findsOneWidget);
      expect(find.text('虾米'), findsOneWidget);
      expect(find.text('云解'), findsOneWidget);

      ChoiceChip chipAt(int index) => tester.widget<ChoiceChip>(
        find.byKey(ValueKey('player-parse-source-$index')),
      );
      expect(chipAt(0).selected, isFalse);
      expect(chipAt(1).selected, isTrue);
      expect(chipAt(2).selected, isFalse);
    });

    testWidgets('点 chip：回调收到被点的那一项', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(
        _host(
          PlayerParseSourceStrip(
            sources: const ['超级解析', '虾米', '云解'],
            selected: '超级解析',
            onSelect: picked.add,
          ),
        ),
      );

      await tester.tap(find.text('云解'));
      await tester.pump();

      expect(picked, ['云解']);
    });

    testWidgets('控制浮层没有 extraRow 时整条不出现', (tester) async {
      await tester.pumpWidget(_host(_overlay()));
      expect(find.byKey(_stripKey), findsNothing);
    });

    testWidgets('控制浮层带 extraRow 时解析条随控制栏出现', (tester) async {
      await tester.pumpWidget(
        _host(
          _overlay(
            extraRow: PlayerParseSourceStrip(
              sources: const ['超级解析', '虾米'],
              selected: '超级解析',
              onSelect: (_) {},
            ),
          ),
        ),
      );
      expect(find.byKey(_stripKey), findsOneWidget);
    });
  });

  testWidgets('选集弹窗不再有解析控件', (tester) async {
    final lines = [
      VodPlayLine(
        flag: 'baidu',
        episodes: [VodEpisode(name: '第1集', url: 'https://e.test/1.m3u8')],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: PlayerEpisodePanel(
          title: '测试剧',
          lineLabel: 'baidu',
          playLines: lines,
          lineFlag: 'baidu',
          episodes: lines.first.episodes,
          episodeIndex: 0,
          onSelectEpisode: (_) {},
          onSelectLine: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('player-episode-parse-source-strip')),
      findsNothing,
    );
    expect(find.text('超级解析'), findsNothing);
  });
}
