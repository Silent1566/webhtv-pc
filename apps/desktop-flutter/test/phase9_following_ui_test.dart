/// 追番卡片展示信息（已看/未看/可播集数/通知状态/下一季入口）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

Following _item({
  int released = 0,
  int watched = 0,
  int read = 0,
  bool itemNotifyEnabled = true,
  int trackedSeason = 0,
  int latestReleasedSeason = 0,
}) => Following(
  seriesKey: followingSeriesKey('s', 'v'),
  season: 0,
  siteKey: 's',
  vodId: 'v',
  vodName: '测试剧',
  flag: '线路一',
  sourceFlag: '线路一',
  trackedSeason: trackedSeason,
  latestReleasedSeason: latestReleasedSeason,
  latestReleasedEpisode: released,
  seasonReleasedEpisodes: released,
  watchedEpisode: watched,
  readWatermarkEpisode: read,
  status: FollowingStatus.returning,
  notifyEnabled: itemNotifyEnabled,
  createdAtMs: 1,
  updatedAtMs: 1,
);

Future<void> _pump(
  WidgetTester tester,
  Following item, {
  bool globalNotifyEnabled = true,
  ValueChanged<bool>? onSetNotify,
}) async {
  tester.view.physicalSize = const Size(1200, 400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: FollowingCard(
          item: item,
          checking: false,
          globalNotifyEnabled: globalNotifyEnabled,
          onPlay: (_) {},
          onOpenDetail: (_) {},
          onCheck: (_) {},
          onMarkRead: (_) {},
          onSetNotify: onSetNotify ?? (_) {},
          onRemove: (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 可交互版本：把 [FollowingCard] 的回调接到一个会真正改数据的本地状态上，
/// 用来验证「菜单点完 → 卡片文案跟着变」。
Future<void> _pumpInteractive(
  WidgetTester tester,
  Following initial, {
  bool globalNotifyEnabled = true,
  required ValueChanged<bool> onSetNotify,
  ValueChanged<Following>? onMarkRead,
}) async {
  tester.view.physicalSize = const Size(1200, 400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  var item = initial;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setLocal) => FollowingCard(
            item: item,
            checking: false,
            globalNotifyEnabled: globalNotifyEnabled,
            onPlay: (_) {},
            onOpenDetail: (_) {},
            onCheck: (_) {},
            onMarkRead: (value) => onMarkRead?.call(value),
            onSetNotify: (enabled) {
              onSetNotify(enabled);
              setLocal(() => item = item.copyWith(notifyEnabled: enabled));
            },
            onRemove: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 点开 kebab 菜单（菜单渲染在 overlay 里，需要 settle）。
Future<void> _openMenu(WidgetTester tester, Following item) async {
  await tester.tap(find.byKey(ValueKey('following-menu-${item.identityKey}')));
  await tester.pumpAndSettle();
}

void main() {
  group('追番卡片展示（P2-1 补全）', () {
    testWidgets('有未看 → 徽标与未看集数按 unwatchedCount 出现', (tester) async {
      final item = _item(released: 12, watched: 9);
      await _pump(tester, item);

      expect(
        find.byKey(ValueKey('following-badge-${item.identityKey}')),
        findsOneWidget,
      );
      expect(find.text('3 集未看'), findsOneWidget);
      expect(
        find.byKey(ValueKey('following-unwatched-${item.identityKey}')),
        findsOneWidget,
      );
      expect(find.text('未看 3 集'), findsOneWidget);
    });

    testWidgets('已读水位不算已看：read=12/watched=3 仍有 9 集未看', (tester) async {
      final item = _item(released: 12, watched: 3, read: 12);
      await _pump(tester, item);

      expect(item.unwatchedCount, 9);
      expect(find.text('9 集未看'), findsOneWidget);
      expect(find.text('已看 3 集'), findsOneWidget);
    });

    testWidgets('全部看完 → 徽标与未看文案都不出现', (tester) async {
      final item = _item(released: 12, watched: 12);
      await _pump(tester, item);

      expect(
        find.byKey(ValueKey('following-badge-${item.identityKey}')),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey('following-unwatched-${item.identityKey}')),
        findsNothing,
      );
      expect(find.textContaining('集未看'), findsNothing);
      expect(find.text('已看 12 集'), findsOneWidget);
    });

    testWidgets('watchedEpisode==0 显示「未开始看」而不是「已看 0 集」', (tester) async {
      await _pump(tester, _item(released: 5));

      expect(find.text('未开始看'), findsOneWidget);
      expect(find.text('已看 0 集'), findsNothing);
    });

    testWidgets('可播集数：有集数按线路报数，无集数显示「集数未知」', (tester) async {
      await _pump(tester, _item(released: 12, watched: 1));
      expect(find.text('本线路可播 12 集'), findsOneWidget);

      await _pump(tester, _item());
      expect(find.text('集数未知'), findsOneWidget);
    });

    testWidgets('通知状态：条目关 / 条目开但全局关 / 两者都开', (tester) async {
      await _pump(tester, _item(released: 1, itemNotifyEnabled: false));
      expect(find.text('新集通知：关（条目关闭）'), findsOneWidget);

      await _pump(tester, _item(released: 1), globalNotifyEnabled: false);
      expect(find.text('新集通知：关（全局开关关闭）'), findsOneWidget);

      await _pump(tester, _item(released: 1));
      expect(find.text('新集通知：开'), findsOneWidget);
    });

    testWidgets('下一季入口：latestReleasedSeason<=trackedSeason 不显示', (
      tester,
    ) async {
      final same = _item(
        released: 12,
        trackedSeason: 1,
        latestReleasedSeason: 1,
      );
      await _pump(tester, same);
      expect(
        find.byKey(ValueKey('following-next-season-${same.identityKey}')),
        findsNothing,
      );
      expect(find.textContaining('季已开播'), findsNothing);
    });

    testWidgets('下一季入口：更晚的发布季出现且只是文字提示', (tester) async {
      final newer = _item(
        released: 12,
        trackedSeason: 0,
        latestReleasedSeason: 1,
      );
      await _pump(tester, newer);

      final key = ValueKey('following-next-season-${newer.identityKey}');
      expect(find.byKey(key), findsOneWidget);
      expect(find.text('第 2 季已开播'), findsOneWidget);
      // 没有「追下一季」能力：只是一行文字，不是按钮。
      expect(
        find.ancestor(of: find.byKey(key), matching: find.byType(TextButton)),
        findsNothing,
      );
      expect(
        find.ancestor(of: find.byKey(key), matching: find.byType(IconButton)),
        findsNothing,
      );
    });
  });

  group('追番卡片 kebab 菜单（单部剧新集通知开关）', () {
    testWidgets('点「新集通知」→ 回调收到取反值，卡片文案随之翻转', (tester) async {
      final item = _item(released: 3, itemNotifyEnabled: true);
      final seen = <bool>[];
      await _pumpInteractive(tester, item, onSetNotify: seen.add);

      expect(find.text('新集通知：开'), findsOneWidget);

      await _openMenu(tester, item);
      // 菜单项自身显示当前状态。
      expect(find.text('新集通知：已开启'), findsOneWidget);
      await tester.tap(find.text('新集通知：已开启'));
      await tester.pumpAndSettle();

      // 开→关：传出去的必须是取反后的 false。
      expect(seen, [false]);
      expect(find.text('新集通知：关（条目关闭）'), findsOneWidget);
      expect(find.text('新集通知：开'), findsNothing);
    });

    testWidgets('条目关闭而全局开启 → 卡片「关（条目关闭）」', (tester) async {
      final item = _item(released: 3, itemNotifyEnabled: false);
      await _pump(tester, item);

      expect(find.text('新集通知：关（条目关闭）'), findsOneWidget);
      expect(find.text('新集通知：关（全局开关关闭）'), findsNothing);

      await _openMenu(tester, item);
      expect(find.text('新集通知：已关闭'), findsOneWidget);
      expect(find.text('仅对这部剧生效'), findsOneWidget);
    });

    testWidgets('条目开启但全局关闭 → 卡片与菜单项都说明不会推送', (tester) async {
      final item = _item(released: 3, itemNotifyEnabled: true);
      final seen = <bool>[];
      await _pumpInteractive(
        tester,
        item,
        globalNotifyEnabled: false,
        onSetNotify: seen.add,
      );

      expect(find.text('新集通知：关（全局开关关闭）'), findsOneWidget);

      await _openMenu(tester, item);
      // 条目状态仍如实显示「已开启」，同时点明全局关闭。
      expect(find.text('新集通知：已开启'), findsOneWidget);
      expect(
        find.text('全局「新集提示」已关闭，开启后也不会推送'),
        findsOneWidget,
      );

      // 全局关时条目照样可切（只是不会推送）。
      await tester.tap(find.text('新集通知：已开启'));
      await tester.pumpAndSettle();
      expect(seen, [false]);
      expect(find.text('新集通知：关（条目关闭）'), findsOneWidget);
    });

    testWidgets('「标为已读（仅清除提示）」文案清楚，且行为仍是 markFollowingRead', (
      tester,
    ) async {
      final item = _item(released: 3, watched: 1, read: 0);
      final markedRead = <Following>[];
      await _pumpInteractive(
        tester,
        item,
        onSetNotify: (_) {},
        onMarkRead: markedRead.add,
      );

      await _openMenu(tester, item);
      expect(find.textContaining('仅清除提示'), findsOneWidget);
      expect(find.text('标记已读'), findsNothing);

      await tester.tap(find.text('标为已读（仅清除提示）'));
      await tester.pumpAndSettle();
      expect(markedRead, [item]);
    });
  });
}
