import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/meta_pipeline.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/meta_sources_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

/// 用显式 pump 而不是 pumpAndSettle：页面里有 ReorderableListView 与
/// SegmentedButton，测试环境下 pumpAndSettle 会一直等不到静止（实测卡死），
/// 逐帧推进才可靠。
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('勾掉 Wikidata 后管线立即生效并落盘', (tester) async {
    final dir = Directory.systemTemp.createTempSync('meta-sources');
    addTearDown(() => dir.deleteSync(recursive: true));
    final state = AppState(
      paths: AppPaths.resolve(overrides: {
        'config': dir.path,
        'data': dir.path,
        'cache': '${dir.path}/cache',
        'state': '${dir.path}/state',
      }),
      log: LogService(),
    );
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    expect(
      state.metaPipeline.orderOf(MetaField.personBiography),
      contains(MetaSourceKind.wikidata),
    );

    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: MetaSourcesPage(state: state),
      ),
    );
    await settle(tester);

    final row = find.byKey(
      const ValueKey('meta-source-personBiography-wikidata'),
    );
    await tester.scrollUntilVisible(row, 2000, scrollable: find.byType(Scrollable).first);
    expect(row, findsOneWidget);
    expect(find.byKey(const ValueKey('meta-source-personBiography-source')), findsNothing);
    await tester.ensureVisible(row);
    await settle(tester);
    await tester.tap(
      find.descendant(of: row, matching: find.byType(Checkbox)),
      warnIfMissed: false,
    );
    await settle(tester);

    expect(
      state.metaPipeline.orderOf(MetaField.personBiography),
      isNot(contains(MetaSourceKind.wikidata)),
    );
    final store = UiPreferencesStore(
      path: '${state.paths.configDir}/settings.json',
    );
    await tester.runAsync(store.load);
    expect(
      store.metaPipeline.orderOf(MetaField.personBiography),
      isNot(contains(MetaSourceKind.wikidata)),
    );
    final checkbox = tester.widget<Checkbox>(find.descendant(of: row, matching: find.byType(Checkbox)));
    expect(checkbox.value, isFalse, reason: 'the rebuilt row must reflect the updated pipeline');
    expect(tester.takeException(), isNull);
  });

  testWidgets('crawler toggle and drag update visible rows immediately', (tester) async {
    final dir = Directory.systemTemp.createTempSync('crawler-settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final state = AppState(paths: AppPaths.resolve(overrides: {'config': dir.path, 'data': dir.path, 'cache': '${dir.path}/cache', 'state': '${dir.path}/state'}), log: LogService());
    addTearDown(state.dispose);
    await tester.runAsync(state.bootstrap);
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: buildAppTheme(Brightness.dark), home: MetaSourcesPage(state: state)));
    await settle(tester);
    final row = find.byKey(const ValueKey('meta-source-title-source'));
    final checkbox = find.descendant(of: row, matching: find.byType(Checkbox));
    await tester.tap(checkbox); await settle(tester);
    expect(tester.widget<Checkbox>(checkbox).value, isFalse);
    await tester.tap(checkbox); await settle(tester);
    expect(tester.widget<Checkbox>(checkbox).value, isTrue);
    final handle = find.descendant(of: row, matching: find.byType(ReorderableDragStartListener));
    final target = find.byKey(const ValueKey('meta-source-title-tmdb'));
    final destination = Offset(tester.getCenter(handle).dx, tester.getCenter(target).dy - 72);
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(destination);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    await settle(tester);
    expect(state.metaPipeline.orderOf(MetaField.title).first, MetaSourceKind.source);
    expect(tester.getTopLeft(row).dy, lessThan(tester.getTopLeft(target).dy));
    final store = UiPreferencesStore(path: '${state.paths.configDir}/settings.json');
    await tester.runAsync(store.load);
    expect(store.metaPipeline.orderOf(MetaField.title).first, MetaSourceKind.source);
    expect(tester.takeException(), isNull);
  });
}
