import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webhtv_pc/services/config_source_status.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/ui/config_source_status_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'config_source_status_fixture.dart';

void main() {
  ConfigRecord record(int id, String origin) => ConfigRecord(
    id: id, name: '同名配置', origin: origin, updatedAt: configSourceFixtureNow,
    siteCount: 1, liveCount: 0,
  );
  ConfigSourceStatus status(int id, ConfigSourceAvailability availability) => ConfigSourceStatus(
    recordId: id, name: '同名配置', availability: availability,
  );
  Future<void> mountRow(WidgetTester tester, ConfigRecord record,
      Future<ConfigSourceStatus> Function(ConfigRecord) inspect) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildAppTheme(Brightness.light), home: Scaffold(
      body: ListTile(subtitle: ConfigSourceStatusView(record: record, metadata: '站点 1', inspect: inspect)))));
    await tester.pump();
  }

  testWidgets('unreadable source is distinct from missing and narrow long paths do not overflow', (tester) async {
    await mountRow(tester, record(1, '/sources/${'long-directory/' * 25}config.json'),
      (_) async => status(1, ConfigSourceAvailability.unreadable));
    expect(find.text('来源文件无法读取 · 使用缓存'), findsOneWidget);
    expect(find.textContaining('已丢失'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('row caches inspection across rebuild and rebinds on origin change', (tester) async {
    final pending = Completer<ConfigSourceStatus>();
    var calls = 0;
    Future<ConfigSourceStatus> inspect(ConfigRecord r) {
      calls++;
      return r.origin == '/old.json' ? pending.future : Future.value(status(r.id, ConfigSourceAvailability.available));
    }
    await mountRow(tester, record(1, '/old.json'), inspect);
    await mountRow(tester, record(1, '/old.json'), inspect);
    expect(calls, 1);
    await mountRow(tester, record(1, '/new.json'), inspect);
    expect(calls, 2);
    pending.complete(status(1, ConfigSourceAvailability.missing));
    await tester.pump();
    expect(find.textContaining('已丢失'), findsNothing);
    expect(find.text('来源 /new.json'), findsOneWidget);
  });

  testWidgets('completed old status is hidden while rebound row awaits new id', (tester) async {
    final pending = Completer<ConfigSourceStatus>();
    Future<ConfigSourceStatus> inspect(ConfigRecord r) => r.id == 1
      ? Future.value(status(1, ConfigSourceAvailability.missing)) : pending.future;
    await mountRow(tester, record(1, '/one.json'), inspect);
    expect(find.textContaining('已丢失'), findsOneWidget);
    await mountRow(tester, record(2, '/two.json'), inspect);
    expect(find.textContaining('已丢失'), findsNothing);
    pending.complete(status(2, ConfigSourceAvailability.available));
    await tester.pump();
    expect(find.textContaining('已丢失'), findsNothing);
  });

  testWidgets('normal HTTP and inline rows do not receive local-source warnings', (tester) async {
    for (final origin in ['https://fixture.test/config.json?token=secret', 'inline://json']) {
      await mountRow(tester, record(1, origin), inspectConfigSource);
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(find.byKey(const ValueKey('config-source-warning-1')), findsNothing);
      expect(find.textContaining('token=secret'), findsNothing);
    }
  });

  testWidgets('restored banner actions stay reachable on narrow light layout', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildAppTheme(Brightness.light), home: Scaffold(body:
      RestoredConfigSourceBanner(status: ConfigSourceStatus(recordId: 1,
        name: '一个非常长的配置名称用于验证紧凑提示可以换行', availability: ConfigSourceAvailability.unreadable,
        path: '/sources/${'long-directory/' * 25}'), onManage: () {}, onDismiss: () {}))));
    await tester.pump();
    expect(find.text('管理配置'), findsOneWidget);
    expect(find.text('关闭提示'), findsOneWidget);
    expect(tester.getRect(find.byKey(const ValueKey('config-source-dismiss'))).right, lessThanOrEqualTo(360));
    expect(tester.takeException(), isNull);
  });

  Future<ConfigSourceFixtureState> mount(WidgetTester tester, {bool shell = false}) async {
    final state = (await tester.runAsync(() => createConfigSourceFixture(shell ? 'startup-ui' : 'list-ui')))!;
    addTearDown(state.dispose);
    tester.view.physicalSize = const Size(1280, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildAppTheme(Brightness.dark),
      home: shell ? AppShell(state: state, startup: const StartupArguments()) : ConfigPage(state: state)));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('missing local source row explains cache without disabling switching or actions', (tester) async {
    final state = await mount(tester);
    final missing = state.savedConfigs.singleWhere((r) => r.origin.contains('电视播放配置'));
    final row = find.byKey(ValueKey('config-row-${missing.id}'));
    expect(find.descendant(of: row, matching: find.text('来源文件已丢失 · 使用缓存')), findsOneWidget);
    expect(find.byKey(ValueKey('config-edit-${missing.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('config-refresh-${missing.id}')), findsOneWidget);
    expect(find.textContaining('来源文件已丢失'), findsOneWidget);
    expect(find.textContaining('token=secret'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switch dialog distinguishes same names by source and keeps missing cache selectable', (tester) async {
    final state = await mount(tester);
    final missing = state.savedConfigs.singleWhere((r) => r.origin.contains('电视播放配置'));
    await tester.pumpWidget(MaterialApp(theme: buildAppTheme(Brightness.dark), home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => showDialog<int>(context: context, builder: (_) => ConfigSwitcherDialog(records: state.savedConfigs, activeId: null)), child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('config-switch-option-${missing.id}'));
    expect(find.descendant(of: row, matching: find.text('来源文件已丢失 · 使用缓存')), findsOneWidget);
    expect(find.textContaining('fixture.test/config.json'), findsOneWidget);
    expect(tester.widget<ListTile>(row).onTap, isNotNull);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(ConfigSwitcherDialog), findsNothing);
  });

  testWidgets('startup warning is nonblocking and management uses existing route', (tester) async {
    final state = await mount(tester, shell: true);
    expect(state.config, isNotNull);
    expect(find.byKey(const ValueKey('config-source-restored-warning')), findsOneWidget);
    expect(find.textContaining('刷新不可用'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('config-source-manage')));
    await tester.pumpAndSettle();
    expect(find.byType(ConfigPage), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    final count = state.savedConfigs.length;
    await tester.tap(find.byKey(const ValueKey('config-source-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('config-source-restored-warning')), findsNothing);
    expect(state.savedConfigs.length, count);
    expect(state.config, isNotNull);
  });
}
