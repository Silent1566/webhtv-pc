/// 去广告二级页的界面门禁：三条入口存在、开关落盘、并留一张 After 截图。
///
/// 为什么需要这一组：新页面是设置分类页里新增的一行 + 一个独立二级页，
/// 结构一旦被后来的改动挪走（比如把开关收回主列表、把入口塞进别的分组），
/// 业务测试全都还是绿的——只有界面级断言抓得到。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ad_block_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;
  late UiPreferencesStore preferences;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-ad-block-page');
    final paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    state = AppState(paths: paths, log: LogService());
    preferences = UiPreferencesStore(path: paths.settingsPath);
    await preferences.load();
    state.attachUiPreferences(preferences);
  });

  tearDown(() async {
    state.dispose();
    temp.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: AdBlockPage(state: state),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('三条入口都在：总开关、启发式、规则库与统计', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('ad-block-enabled')), findsOneWidget);
    expect(find.byKey(const ValueKey('ad-block-heuristic')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ad-block-rule-library-open')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('ad-block-stats-open')), findsOneWidget);
    // 启发式默认关闭：副标题必须把「默认关闭 + 会误删」写出来。
    expect(find.textContaining('默认关闭'), findsOneWidget);
  });

  testWidgets('启发式开关默认关，打开后写顶层 adBlock.heuristic', (tester) async {
    await pumpPage(tester);
    expect(state.adBlockHeuristicEnabled, isFalse);
    expect(preferences.adBlockHeuristicEnabled, isFalse);

    await tester.tap(find.byKey(const ValueKey('ad-block-heuristic')));
    await tester.pumpAndSettle();
    // 偏好写入走真实事件循环，与 phase9 偏好测试同一处理方式。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    expect(state.adBlockHeuristicEnabled, isTrue);
    final raw = File(preferences.path).readAsStringSync();
    expect(raw.contains('"heuristic"'), isTrue);
    expect(raw.contains('"heuristic": true'), isTrue);
  });

  testWidgets('这是独立路由：拨开关后控件必须自己回显（不能停在进页那一刻的旧快照）', (tester) async {
    await pumpPage(tester);
    SwitchListTile heuristic() => tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('ad-block-heuristic')),
    );
    expect(heuristic().value, isFalse, reason: '前置：默认关闭');

    await tester.tap(find.byKey(const ValueKey('ad-block-heuristic')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(state.adBlockHeuristicEnabled, isTrue, reason: '状态必须真的改了');
    expect(
      heuristic().value,
      isTrue,
      reason: '独立路由不监听 AppState 时，控件会停在旧快照上——用户看到的就是「点了没反应」',
    );

    // 再关回去：两个方向都要能回显。
    await tester.tap(find.byKey(const ValueKey('ad-block-heuristic')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(heuristic().value, isFalse);
  });

  testWidgets('截图：1280×800 暗色（After）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: AdBlockPage(state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (Platform.environment['AD_BLOCK_CAPTURE'] != '1') return;
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File(
        p.join('..', '..', '.impeccable', 'review', 'ad-block-page-after.png'),
      );
      output.parent.createSync(recursive: true);
      output.writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
