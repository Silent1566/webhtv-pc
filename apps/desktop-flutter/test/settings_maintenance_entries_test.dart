/// 「维护」类承载原侧栏的两个低频入口（2026-11-22 用户决策：侧栏不再单独占位）：
/// Spider 运行时与日志都必须从设置**一级可达**，且 push 出来自带标题与返回。
///
/// 这条用例钉住的是「入口搬家后没有变成死链」：SpiderPage / LogsPage 原先都是
/// 外壳标签页的裸 body（无 `Scaffold`/`AppBar`），改成独立路由后必须自带宿主。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/spider_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-maintenance-entries');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': p.join(temp.path, 'config'),
          'data': p.join(temp.path, 'data'),
          'cache': p.join(temp.path, 'cache'),
          'state': p.join(temp.path, 'state'),
        },
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });
  tearDown(() async {
    state.dispose();
    await temp.delete(recursive: true);
  });

  /// 有界 settle（5 秒），理由同其余设置页用例：真实 IO 的前置会让无限等待超时。
  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );

  /// 路由切换只推进固定帧：日志页里有常驻滚动条与可选中文本，无限 settle 会超时。
  Future<void> pumpRoute(WidgetTester tester) async {
    await tester.pump();
    // 进/出一共三段：起帧、走完 300ms 转场、移除已退出的路由。
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> openMaintenance(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: SettingsPage(state: state)),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('settings-category-maintenance')));
    await settle(tester);
  }

  testWidgets('维护类里有 Spider 与日志两行入口', (tester) async {
    await openMaintenance(tester);
    expect(find.byKey(const ValueKey('settings-spider-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-logs-open')), findsOneWidget);
    expect(find.text('Spider 运行时'), findsOneWidget);
    expect(find.text('日志与诊断'), findsOneWidget);
  });

  testWidgets('两个入口 push 之后是带标题的独立路由', (tester) async {
    await openMaintenance(tester);

    await tester.tap(find.byKey(const ValueKey('settings-logs-open')));
    await pumpRoute(tester);
    expect(find.byType(LogsPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, '日志与诊断'), findsOneWidget);
    await tester.pageBack();
    await pumpRoute(tester);
    expect(find.byType(LogsPage, skipOffstage: false), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-spider-open')));
    await pumpRoute(tester);
    expect(find.byType(SpiderPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Spider'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
