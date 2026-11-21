/// 集级手动匹配的**匹配选择弹窗**（纯 UI，不碰 AppState / 菜单接线）。
///
/// 锁定的行为：
/// 1. 打开即拉初始季并定位到初始集（该行标「当前」且首帧已滚入视野）；
/// 2. 底部三个动作分别返回 spread:true / spread:false / null，没有选中项时确认禁用；
/// 3. 季列表拉不到时报不可用并可重试（不猜集号、不阻塞别的季）；
/// 4. 切季按季缓存，不重复请求同一季；迟到响应既不跨季污染、也不在关闭后 setState；
/// 5. 集号文案只来自 EpisodeManualMatch.unitLabel（综艺是「第 N 期」）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/ui/episode_match_dialog.dart';
import 'package:webhtv_pc/ui/theme.dart';

/// 一季的假集列表：没有剧照（stillUrl 空串），避免 widget 测试真发网络请求。
List<TmdbEpisode> seasonEpisodes(int season, {int count = 12}) => [
  for (var number = 1; number <= count; number++)
    TmdbEpisode(
      number: number,
      title: '第 $number 集标题',
      date: '2023-01-01',
      seasonNumber: season,
    ),
];

/// 弹窗返回值：completed 区分「还没关」与「关掉了且返回 null」。
class _Opened {
  bool completed = false;
  EpisodeMatchChoice? choice;
}

bool _buttonEnabled(WidgetTester tester, String key) {
  final widget = tester.widget(find.byKey(ValueKey(key)));
  if (widget is ButtonStyleButton) return widget.onPressed != null;
  throw StateError('$key 不是按钮');
}

Future<void> _openDialog(
  WidgetTester tester, {
  required Future<List<TmdbEpisode>?> Function(int season) loadSeason,
  Map<int, int> seasonEpisodeCounts = const {1: 12},
  int initialSeason = 1,
  int initialEpisode = 1,
  bool variety = false,
  String title = '漫长的季节',
  _Opened? opened,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const ValueKey('open-dialog'),
              onPressed: () => showEpisodeMatchDialog(
                context,
                title: title,
                seasonEpisodeCounts: seasonEpisodeCounts,
                initialSeason: initialSeason,
                initialEpisode: initialEpisode,
                variety: variety,
                loadSeason: loadSeason,
              ).then((choice) {
                final target = opened;
                if (target == null) return;
                target.choice = choice;
                target.completed = true;
              }),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-dialog')));
  // 第一帧推入路由并跑 initState（发起首个请求），第二帧让响应落地。
  await tester.pump();
  await tester.pump();
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  testWidgets('打开即加载初始季并定位到初始集', (tester) async {
    final calls = <int>[];
    await _openDialog(
      tester,
      initialEpisode: 8,
      loadSeason: (season) async {
        calls.add(season);
        return seasonEpisodes(season);
      },
    );

    expect(calls, [1]);
    expect(find.text('漫长的季节'), findsOneWidget);
    // 只有一季：不渲染季切换器。
    expect(find.byKey(const ValueKey('episode-match-season-1')), findsNothing);

    final row = find.byKey(const ValueKey('episode-match-row-8'));
    expect(row, findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('当前')),
      findsOneWidget,
    );
    // 集号文案来自 unitLabel，不是 UI 自己拼的。
    expect(
      find.descendant(of: row, matching: find.text('S1E8')),
      findsOneWidget,
    );
    // 首帧已滚到初始集：偏移量不再是 0。
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.controller!.offset, greaterThan(0));
  });

  testWidgets('「从此集起顺延」返回 spread:true', (tester) async {
    final opened = _Opened();
    await _openDialog(
      tester,
      initialEpisode: 3,
      opened: opened,
      loadSeason: (season) async => seasonEpisodes(season),
    );

    await tester.tap(find.byKey(const ValueKey('episode-match-spread')));
    await tester.pumpAndSettle();

    expect(opened.completed, isTrue);
    expect(opened.choice!.seasonNumber, 1);
    expect(opened.choice!.episodeNumber, 3);
    expect(opened.choice!.spread, isTrue);
  });

  testWidgets('整行可点选中，「仅此一集」返回 spread:false', (tester) async {
    final opened = _Opened();
    await _openDialog(
      tester,
      initialEpisode: 2,
      opened: opened,
      loadSeason: (season) async => seasonEpisodes(season),
    );

    final row = find.byKey(const ValueKey('episode-match-row-5'));
    await tester.tap(row);
    await tester.pump();
    expect(
      find.descendant(of: row, matching: find.text('当前')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('episode-match-single')));
    await tester.pumpAndSettle();

    expect(opened.completed, isTrue);
    expect(opened.choice!.seasonNumber, 1);
    expect(opened.choice!.episodeNumber, 5);
    expect(opened.choice!.spread, isFalse);
  });

  testWidgets('取消返回 null', (tester) async {
    final opened = _Opened();
    await _openDialog(
      tester,
      opened: opened,
      loadSeason: (season) async => seasonEpisodes(season),
    );

    await tester.tap(find.byKey(const ValueKey('episode-match-cancel')));
    await tester.pumpAndSettle();

    expect(opened.completed, isTrue);
    expect(opened.choice, isNull);
  });

  testWidgets('季列表不可用时报占位并禁用确认，重试后恢复', (tester) async {
    final calls = <int>[];
    var broken = true;
    await _openDialog(
      tester,
      loadSeason: (season) async {
        calls.add(season);
        return broken ? null : seasonEpisodes(season);
      },
    );

    expect(
      find.byKey(const ValueKey('episode-match-unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('episode-match-row-1')), findsNothing);
    expect(_buttonEnabled(tester, 'episode-match-spread'), isFalse);
    expect(_buttonEnabled(tester, 'episode-match-single'), isFalse);

    broken = false;
    await tester.tap(find.byKey(const ValueKey('episode-match-retry')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('episode-match-unavailable')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('episode-match-row-1')), findsOneWidget);
    expect(_buttonEnabled(tester, 'episode-match-spread'), isTrue);
    expect(_buttonEnabled(tester, 'episode-match-single'), isTrue);
    // 重试确实重打了这一季（首帧一次 + 重试一次）。
    expect(calls, [1, 1]);
  });

  testWidgets('加载中有进度态', (tester) async {
    final completer = Completer<List<TmdbEpisode>?>();
    await _openDialog(
      tester,
      settle: false,
      loadSeason: (season) => completer.future,
    );

    expect(find.byKey(const ValueKey('episode-match-loading')), findsOneWidget);
    expect(_buttonEnabled(tester, 'episode-match-spread'), isFalse);

    completer.complete(seasonEpisodes(1));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('episode-match-loading')), findsNothing);
    expect(find.byKey(const ValueKey('episode-match-row-1')), findsOneWidget);
  });

  testWidgets('关闭后才到达的响应不再 setState', (tester) async {
    final completer = Completer<List<TmdbEpisode>?>();
    final opened = _Opened();
    await _openDialog(
      tester,
      settle: false,
      opened: opened,
      loadSeason: (season) => completer.future,
    );

    await tester.tap(find.byKey(const ValueKey('episode-match-cancel')));
    await tester.pumpAndSettle();
    expect(opened.completed, isTrue);
    expect(opened.choice, isNull);

    completer.complete(seasonEpisodes(1));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('两季切季只回调对应季，切回不重复请求', (tester) async {
    final calls = <int>[];
    await _openDialog(
      tester,
      seasonEpisodeCounts: const {2: 8, 1: 10},
      initialSeason: 1,
      initialEpisode: 2,
      loadSeason: (season) async {
        calls.add(season);
        return seasonEpisodes(season, count: season == 1 ? 10 : 8);
      },
    );

    expect(calls, [1]);
    expect(
      find.byKey(const ValueKey('episode-match-season-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('episode-match-season-2')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('episode-match-season-2')));
    await tester.pumpAndSettle();

    expect(calls, [1, 2]);
    // 切季重置到该季第 1 集。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('episode-match-row-1')),
        matching: find.text('当前'),
      ),
      findsOneWidget,
    );
    expect(find.text('S2E1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('episode-match-season-1')));
    await tester.pumpAndSettle();

    // 已缓存：切回不再请求。
    expect(calls, [1, 2]);
    // 切回初始季还原初始集。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('episode-match-row-2')),
        matching: find.text('当前'),
      ),
      findsOneWidget,
    );
    expect(find.text('S1E2'), findsOneWidget);
  });

  testWidgets('综艺集号文案用「期」', (tester) async {
    await _openDialog(
      tester,
      seasonEpisodeCounts: const {1: 8, 2: 6},
      initialSeason: 1,
      initialEpisode: 3,
      variety: true,
      loadSeason: (season) async =>
          seasonEpisodes(season, count: season == 1 ? 8 : 6),
    );

    expect(find.textContaining('期'), findsWidgets);
    expect(find.text('第 3 期'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('episode-match-season-2')));
    await tester.pumpAndSettle();

    // 多季综艺带季号（unitLabel 的文案，不由 UI 拼）。
    expect(find.text('第 2 季 第 1 期'), findsOneWidget);
    expect(find.textContaining('S2E1'), findsNothing);
  });

  testWidgets('初始集不在该季里时退到最近的一集', (tester) async {
    await _openDialog(
      tester,
      seasonEpisodeCounts: const {1: 5},
      initialEpisode: 9,
      loadSeason: (season) async => seasonEpisodes(season, count: 5),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('episode-match-row-5')),
        matching: find.text('当前'),
      ),
      findsOneWidget,
    );
    expect(_buttonEnabled(tester, 'episode-match-spread'), isTrue);
  });
}
