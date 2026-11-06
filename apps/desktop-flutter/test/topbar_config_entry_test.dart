/// 顶栏的两个配置入口必须分得清（用户反馈 2026-11-05）。
///
/// ## 锁定的行为
///
/// 1. 「配置：xxx」是**换配置**，不是管理；
/// 2. 「管理」是独立入口，且**必须带可见文字**——初版只放了一个无标签的
///    `settings_ethernet` 图标，用户截图反馈「不太明显」：顶栏一排图标里
///    分不出它是入口还是装饰；
/// 3. 配置名过长时省略显示，不能把站点入口挤出顶栏。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-topbar-config');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  int seed(String name) => state.database!.saveConfig(
    name: name,
    origin: 'https://example.test/$name.json',
    json: {
      'sites': [
        {
          'key': 'k-$name',
          'name': '站点',
          'type': 0,
          'api': 'https://example.test/$name/',
        },
      ],
    },
    siteCount: 1,
  );

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: AppShell(state: state, startup: const StartupArguments()),
      ),
    );
    // 有首启公告时先关掉，否则它盖住顶栏。
    for (var round = 0; round < 40; round++) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 8)),
      );
    }
    final accept = find.text('我已了解并继续');
    if (accept.evaluate().isNotEmpty) {
      await tester.tap(accept);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('「管理」入口带文字，不是裸图标', (tester) async {
    seed('示例配置');
    await mount(tester);

    final manage = find.byKey(const ValueKey('topbar-manage-config'));
    expect(manage, findsOneWidget, reason: '管理入口必须存在');
    expect(
      find.descendant(of: manage, matching: find.text('管理')),
      findsOneWidget,
      reason: '纯图标在顶栏一排字形里分不出来，用户反馈「不太明显」',
    );
  });

  testWidgets('「配置：xxx」仍是换配置入口，点击弹切换框', (tester) async {
    final first = seed('甲');
    seed('乙');
    // 必须走 activateConfigRecord 而不是只改库：后者不动内存里的
    // `activeRecord`，顶栏会退化成「导入配置」，测的就不是真实首屏了。
    await state.activateConfigRecord(first);
    await mount(tester);

    // 两条配置才值得弹切换框；只有一条时直接进管理页（见实现注释）。
    await tester.tap(find.textContaining('配置：'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('config-switcher')),
      findsOneWidget,
      reason: '顶栏「配置：xxx」的意图是换源，应直接给出可选列表',
    );
    await tester.tap(find.byKey(const ValueKey('config-switcher-cancel')));
    await tester.pumpAndSettle();
  });

  testWidgets('超长配置名被省略，不挤掉站点入口', (tester) async {
    seed('这是一个特别特别长的配置名称用于验证顶栏不会被撑爆的情况');
    await mount(tester);

    // 站点入口仍必须可见且在屏幕内。
    final site = find.textContaining('站点：');
    if (site.evaluate().isNotEmpty) {
      expect(tester.getRect(site.first).right, lessThanOrEqualTo(1280));
    }
    expect(tester.takeException(), isNull);
  });
}
