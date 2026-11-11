/// 收藏页门禁：形态对齐最近观看（海报格），交互对齐安卓 `KeepActivity`
/// （点击进详情、删除态点谁删谁、长按切换）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/library_pages.dart';
import 'package:webhtv_pc/ui/toast.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    // `toastCenter` 是进程级单例：上一条用例留下的通知会漏进这一条。
    dismissAllToasts();
    tempDir = await Directory.systemTemp.createTemp('webhtv-favorites-page');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    dismissAllToasts();
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: FavoritesPage(state: state))),
    );
    await tester.pump();
  }

  void seedFavorites() {
    final database = state.database!;
    database.upsertFavorite(
      kind: 'vod',
      siteKey: 'k',
      targetId: 'v1',
      title: '卡片影片一',
      subtitle: '全12集',
      vodPic: 'http://img.example/a.jpg',
    );
    database.upsertFavorite(
      kind: 'vod',
      siteKey: 'k',
      targetId: 'v2',
      title: '卡片影片二',
    );
    database.upsertFavorite(
      kind: 'site',
      siteKey: 's1',
      targetId: 's1',
      title: '站点收藏',
    );
  }

  testWidgets('空态：没有收藏时给空态，不渲染空网格', (tester) async {
    await pumpPage(tester);
    expect(find.text('暂无收藏'), findsOneWidget);
    expect(find.byKey(const ValueKey('favorites-grid')), findsNothing);
  });

  testWidgets('有收藏时渲染海报网格卡片，而不是列表行', (tester) async {
    seedFavorites();
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('favorites-grid')), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('收藏（3）'), findsOneWidget);
    expect(find.text('卡片影片一'), findsOneWidget);
    expect(find.text('全12集'), findsOneWidget);
  });

  testWidgets('删除按钮进入删除态，删除态下点卡片即删除', (tester) async {
    seedFavorites();
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('favorites-delete-switch')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('favorite-delete-overlay-vod-k-v1')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('favorite-card-vod-k-v1')));
    await tester.pump();
    expect(state.favorites(), hasLength(2));
    expect(find.text('卡片影片一'), findsNothing);
  });

  testWidgets('长按卡片同样能切换删除态', (tester) async {
    seedFavorites();
    await pumpPage(tester);
    await tester.longPress(
      find.byKey(const ValueKey('favorite-card-vod-k-v2')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('favorite-delete-overlay-vod-k-v2')),
      findsOneWidget,
    );
  });
}
