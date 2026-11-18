/// 追剧页的两个视角：列表 / 日历的切换、懒创建与状态保持。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-following-view');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}${Platform.pathSeparator}config',
        'data': '${temp.path}${Platform.pathSeparator}data',
        'cache': '${temp.path}${Platform.pathSeparator}cache',
        'state': '${temp.path}${Platform.pathSeparator}logs',
      },
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void addItem() {
    final item = state.followFromDetail(
      site: Site(key: 's', name: '甲站', type: 4, api: 'http://127.0.0.1:1/vod'),
      vod: Vod(vodId: 'v1', vodName: '测试剧'),
      flag: '线路一',
      sourceFlag: '线路一',
      releasedEpisode: 10,
    );
    expect(item, isNotNull);
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: FollowingPage(state: state)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 当前视角（宿主用 IndexedStack 装两个视角，0 = 列表，1 = 日历）。
  int viewIndex(WidgetTester tester) => tester
      .widget<IndexedStack>(
        find.descendant(
          of: find.byType(FollowingPage),
          matching: find.byType(IndexedStack),
        ),
      )
      .index!;

  testWidgets('默认列表视角，日历首次切入才创建', (tester) async {
    addItem();
    await mount(tester);
    expect(viewIndex(tester), 0);
    expect(find.byKey(const ValueKey('following-list')), findsOneWidget);
    // 懒创建：没切过日历就不存在（只用列表的用户不触发日历的 TMDB 取数）。
    expect(find.byKey(const ValueKey('calendar-region')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('following-view-calendar')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(viewIndex(tester), 1);
    expect(find.byKey(const ValueKey('calendar-region')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('离开页面再回来保留上次视角（壳层会重建本页）', (tester) async {
    addItem();
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('following-view-calendar')));
    await tester.pump();
    expect(viewIndex(tester), 1);

    // 壳层切到别的侧栏项会丢掉本页 State（AppShell 每次重建内容区）。
    await tester.pumpWidget(const SizedBox());
    await mount(tester);
    expect(viewIndex(tester), 1, reason: '会话内应恢复上次视角');
  });

  testWidgets('切换视角保留日历的月份（IndexedStack 保状态）', (tester) async {
    addItem();
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('following-view-calendar')));
    await tester.pump();

    final now = DateTime.now();
    final next = DateTime(now.year, now.month + 1);
    await tester.tap(find.byKey(const ValueKey('calendar-next-month')));
    await tester.pump();
    expect(find.text('${next.year}年${next.month}月'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('following-view-list')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('following-view-calendar')));
    await tester.pump();
    expect(viewIndex(tester), 1);
    expect(
      find.text('${next.year}年${next.month}月'),
      findsOneWidget,
      reason: '切走再切回不该回到当月',
    );
  });
}
