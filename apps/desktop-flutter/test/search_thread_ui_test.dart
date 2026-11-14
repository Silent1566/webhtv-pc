/// 设置页「搜索」区块与共享数值滑块对话框的 widget 门禁。
///
/// 为什么与 `search_thread_test.dart` **分文件**：同一个测试文件里只要有
/// `testWidgets`，`TestWidgetsFlutterBinding` 就会给整个 isolate 装上 mock HTTP
/// 拦截（所有请求 400、不发真实网络），于是同文件的真实 HTTP 用例全废
/// （实测：并发探针观测到 0 个在途请求）。真实 I/O 的状态测试与 widget 测试
/// 必须分文件——这也是本仓库既有测试的既有分工。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/common.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-search-thread-ui');
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
    // bootstrap 装配 UiPreferencesStore（`setSearchThread` 依赖它）。
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('设置页：搜索区块', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      // 放大窗口，让整个设置表单一次性渲染（默认 800x600 会截断）。
      tester.view.physicalSize = const Size(1400, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SettingsPage(state: state))),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('展示当前并发线程（默认 20，对齐上游）', (tester) async {
      await pumpSettings(tester);

      expect(
        find.byKey(const ValueKey('settings-search-thread-summary')),
        findsOneWidget,
      );
      expect(find.textContaining('并发线程：20'), findsOneWidget);
    });

    testWidgets('滑块对话框可调整线程并写回', (tester) async {
      await pumpSettings(tester);

      final entry = find.byKey(const ValueKey('settings-search-thread'));
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('search-thread-slider')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('search-thread-value')))
            .data,
        '20',
        reason: '对话框应从当前值开始',
      );

      // 往右拖：值必须升高。
      await tester.drag(
        find.byKey(const ValueKey('search-thread-slider')),
        const Offset(400, 0),
      );
      await tester.pumpAndSettle();
      final chosen = int.parse(
        tester
            .widget<Text>(find.byKey(const ValueKey('search-thread-value')))
            .data!,
      );
      expect(chosen, greaterThan(20));

      await tester.tap(find.byKey(const ValueKey('search-thread-confirm')));
      await tester.pumpAndSettle();

      expect(state.searchThread, chosen, reason: '确定后必须写回状态');
    });

    testWidgets('取消不改动线程数', (tester) async {
      await pumpSettings(tester);

      final entry = find.byKey(const ValueKey('settings-search-thread'));
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('search-thread-slider')),
        const Offset(400, 0),
      );
      await tester.pumpAndSettle();
      // 页面上的「取消」是取消搜索按钮，必须定位对话框里的那个。
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('取消'),
        ),
      );
      await tester.pumpAndSettle();

      expect(state.searchThread, 20, reason: '取消必须不改值');
    });
  });

  group('共享数值滑块对话框（上游 SliderNumberDialog 语义）', () {
    /// 打开对话框并把结果写进 [captured]。
    Future<void> openDialog(
      WidgetTester tester, {
      required int current,
      required int min,
      required int max,
      required List<int?> captured,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    captured.add(
                      await showNumberSliderDialog(
                        context,
                        title: '测试',
                        current: current,
                        minValue: min,
                        maxValue: max,
                        suffix: '%',
                        hint: '说明',
                        keyPrefix: 'probe',
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('max < min 时不弹对话框且返回 null（下游保护）', (tester) async {
      final captured = <int?>[];
      await openDialog(tester, current: 5, min: 10, max: 1, captured: captured);

      expect(find.byType(AlertDialog), findsNothing);
      expect(captured, [null]);
    });

    testWidgets('当前值超出区间时被夹到边界后再显示', (tester) async {
      final captured = <int?>[];
      await openDialog(
        tester,
        current: 500,
        min: 1,
        max: 100,
        captured: captured,
      );

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('probe-value'))).data,
        '100%',
        reason: '越界的当前值必须夹到 max，而不是显示 500%',
      );
      await tester.tap(find.byKey(const ValueKey('probe-confirm')));
      await tester.pumpAndSettle();
      expect(captured, [100]);
    });

    testWidgets('取消返回 null（调用方据此不写入）', (tester) async {
      final captured = <int?>[];
      await openDialog(tester, current: 42, min: 0, max: 100, captured: captured);

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('取消'),
        ),
      );
      await tester.pumpAndSettle();
      expect(captured, [null]);
    });
  });
}
