/// 「全部设置」页（\`SettingsOverviewPage\`）的可 push 回归。
///
/// 为什么需要它：设置首页是外壳里的一个标签页，\`Navigator.push\` 不到；而播放器
/// 右键菜单的「完整设置页…」需要一条从**播放画面**摸到所有设置的路。它以前指向
/// 「高级设置」中枢（只覆盖四个分类里的长尾），中枢删除后改成本页——本页复用
/// 设置首页的分类中枢本体，所以它必须：
///
/// 1. 能被真实 \`Navigator.push\` 打开（不是只在 \`home:\` 里能渲染）；
/// 2. 五个分类都能进，且同一时刻只挂当前分类的正文；
/// 3. AppBar 的返回按钮真的回得去（pop 回被盖住的那一页）；
/// 4. 不重复画页标题（标题在 AppBar，正文不再来一次「设置」）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/settings_overview_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/settings_row_navigation.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-settings-overview');
    final paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
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

  const categories = <String>[
    'preferences',
    'playback',
    'sites',
    'connections',
    'maintenance',
  ];

  /// 每类的代表控件（用来判断「当前分类独占正文」）。
  const marker = <String, String>{
    'preferences': 'settings-theme-mode',
    'playback': 'settings-osd-open',
    'sites': 'settings-site-health-open',
    'connections': 'settings-ai-open',
    'maintenance': 'settings-python-environment-open',
  };

  /// 从「视频页」push 出来：还原播放器右键菜单「完整设置页…」的真实入口形态。
  Future<void> pushOverview(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1072, 728);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const ValueKey('open-overview'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsOverviewPage(state: state),
                  ),
                ),
                child: const Text('完整设置页…'),
              ),
            ),
          ),
        ),
      ),
    );
    await pumpSettingsSettled(tester);
    await tester.tap(find.byKey(const ValueKey('open-overview')));
    await pumpSettingsSettled(tester);
    expect(
      find.byType(SettingsOverviewPage),
      findsOneWidget,
      reason: '「完整设置页…」必须能真的 push 出全部设置页',
    );
  }

  testWidgets('全部设置页可 push：五个分类都能进，返回按钮回得去', (tester) async {
    await pushOverview(tester);

    // 标题在 AppBar；正文不得重复画一次「设置」页标题。
    expect(find.widgetWithText(AppBar, '全部设置'), findsOneWidget);
    expect(
      find.text('设置'),
      findsNothing,
      reason: '独立路由已用 AppBar 标标题，正文再画一次就是同屏两个标题',
    );
    expect(
      find.text('调整日常偏好、播放体验与连接服务。'),
      findsNothing,
      reason: '页标题的说明句也不得在独立路由里重复',
    );

    // ① 五个分类 key 各恰好一处。
    for (final id in categories) {
      expect(
        find.byKey(ValueKey('settings-category-$id')),
        findsOneWidget,
        reason: '全部设置页缺少分类入口：$id',
      );
    }

    // 逐个进入：当前分类独占正文，其余分类的内容区不挂载。
    for (final id in categories) {
      await tester.tap(find.byKey(ValueKey('settings-category-$id')));
      await pumpSettingsSettled(tester);
      expect(
        find.byKey(ValueKey('settings-category-content-$id')),
        findsOneWidget,
        reason: '全部设置页里分类 $id 选中后必须挂自己的单列内容区',
      );
      expect(
        find.byKey(ValueKey(marker[id]!), skipOffstage: false),
        findsOneWidget,
        reason: '分类 $id 必须渲染自己的入口',
      );
      for (final other in categories.where((value) => value != id)) {
        expect(
          find.byKey(
            ValueKey('settings-category-content-$other'),
            skipOffstage: false,
          ),
          findsNothing,
          reason: '同一时刻只渲染当前分类的正文（$id 选中时 $other 还在）',
        );
      }
      expect(tester.takeException(), isNull);
    }

    // 原生返回：回到被盖住的那一页（push 来源），而不是留在本页。
    final back = find.byType(BackButton);
    expect(back, findsOneWidget, reason: '全部设置页必须有原生返回按钮');
    await tester.tap(back);
    await pumpSettingsSettled(tester);
    expect(find.byType(SettingsOverviewPage), findsNothing);
    expect(
      find.byKey(const ValueKey('open-overview')),
      findsOneWidget,
      reason: '返回必须回到 push 出来的上一页',
    );
  });

  testWidgets('全部设置页自己监听 AppState：拨开关后回显（独立路由管不到宿主重建）', (
    tester,
  ) async {
    await pushOverview(tester);

    // 演示用状态：外观选择是偏好类里第一个受控控件。
    expect(state.themeMode, 'dark', reason: '前置：默认暗色');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('settings-theme-mode')),
        matching: find.text('亮色'),
      ),
    );
    await settleSettingsIo(tester);

    expect(state.themeMode, 'light', reason: '点「亮色」必须真的改变主题状态');
    expect(
      tester
          .widget<SegmentedButton<ThemeMode>>(
            find.byKey(const ValueKey('settings-theme-mode')),
          )
          .selected,
      {ThemeMode.light},
      reason: '独立路由必须自己听 AppState，否则控件停在进页那一刻的旧快照',
    );
  });
}
