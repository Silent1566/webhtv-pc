/// 日志页的四项新增能力（用户 2026-11-06 反馈：只能选中一行、无法整段复制）。
///
/// 锁定的用户可见行为：
/// 1. 日志是**一整块**可选中文本：跨行拖拽即可选中任意多行（不再是逐行
///    `SelectableText`），但仍按级别着色；
/// 2. 关键字搜索即时过滤，命中处高亮，条数显示「命中 / 总数」；
/// 3. 工具栏有「下载」「清理」两个按钮；
/// 4. 「清理」先弹确认框，取消不删除任何东西。
///
/// 真实文件 I/O（下载写盘、清理删文件）不在 widget 测试里执行：`testWidgets`
/// 跑在假时钟下，`await` 真实 I/O 不会推进（见仓库既有的
/// `webhtv-pc-test-io-layering` 分层纪律），那两条路径由 `log_service_test.dart`
/// 直接验证。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';

class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw StateError('测试不应发起网络请求');
  }
}

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-logs-page');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
      ),
      log: LogService(),
      httpClient: _NoNetworkClient(),
    );
    await state.bootstrap();
    state.log.info('普通日志 alpha');
    state.log.warning('告警日志 beta');
    state.log.error('错误日志 gamma');
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpLogs(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LogsPage(state: state))),
    );
    await tester.pump();
  }

  Finder logText(String pattern) =>
      find.textContaining(pattern, findRichText: true);

  testWidgets('日志整块可选中：只有一个 SelectableText，且包含全部行', (tester) async {
    await pumpLogs(tester);
    expect(find.byType(SelectableText), findsOneWidget);
    final selectable = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    final plain = selectable.textSpan!.toPlainText();
    expect(plain, contains('普通日志 alpha'));
    expect(plain, contains('告警日志 beta'));
    expect(plain, contains('错误日志 gamma'));
    // 跨行选中的前提：多行拼在同一个文本里，行间有换行符。
    expect(plain.split('\n').length, greaterThanOrEqualTo(3));
  });

  testWidgets('关键字搜索即时过滤并显示命中条数', (tester) async {
    await pumpLogs(tester);
    final total = state.log.entries.length;
    expect(find.text('$total 条'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('logs-search')),
      'beta',
    );
    await tester.pump();

    expect(logText('告警日志 beta'), findsOneWidget);
    expect(logText('普通日志 alpha'), findsNothing);
    expect(logText('错误日志 gamma'), findsNothing);
    expect(find.text('1 / $total 条'), findsOneWidget);
  });

  testWidgets('搜索无命中显示「没有匹配的日志」', (tester) async {
    await pumpLogs(tester);
    await tester.enterText(
      find.byKey(const ValueKey('logs-search')),
      '不存在的关键字',
    );
    await tester.pump();
    expect(find.text('没有匹配的日志'), findsOneWidget);
  });

  testWidgets('工具栏有下载与清理按钮', (tester) async {
    await pumpLogs(tester);
    expect(find.byKey(const ValueKey('logs-download')), findsOneWidget);
    expect(find.byKey(const ValueKey('logs-clear')), findsOneWidget);
    // 原有的整段复制不能丢。
    expect(find.textContaining('复制全部'), findsOneWidget);
  });

  testWidgets('清理先弹确认框，取消后日志原样保留', (tester) async {
    await pumpLogs(tester);
    await tester.tap(find.byKey(const ValueKey('logs-clear')));
    await tester.pumpAndSettle();
    expect(find.text('清理日志？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('清理日志？'), findsNothing);
    expect(state.log.entries, isNotEmpty);
    expect(logText('普通日志 alpha'), findsOneWidget);
  });

  testWidgets('内存环形缓冲塞满（500 行）后整块布局仍然可接受', (tester) async {    for (var i = 0; i < 500; i++) {
      state.log.info('批量日志 index=$i site=csp_a status=200');
    }
    final watch = Stopwatch()..start();
    await pumpLogs(tester);
    watch.stop();
    expect(state.log.entries.length, 500);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(
      watch.elapsedMilliseconds,
      lessThan(2000),
      reason: '500 行整块布局耗时 ${watch.elapsedMilliseconds}ms',
    );
  });

  testWidgets('最小窗口 1024x640 下工具栏不溢出', (tester) async {
    await pumpLogs(tester, size: const Size(1024, 640));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('logs-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('logs-download')), findsOneWidget);
    expect(find.byKey(const ValueKey('logs-clear')), findsOneWidget);
  });
}
