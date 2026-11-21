/// 推送对话框与应用入口：「推送」对话框 → 推送详情页 → 播放。
///
/// ## 锁定的行为（2026-11-21 改为"先详情后播放"）
/// 1. 顶栏「推送」打开对话框：地址、剧名、本地文件三条路径都在同一处；
/// 2. 提交成功后进入**推送详情页**（不是直接起播），且「点了没反应」不再出现：
///    壳层延到下一帧才压栈，对话框能正常关掉；
/// 3. `submitPush` 失败**不关窗**，原因显示在按钮下方；
/// 4. 局域网推送到达 → 壳层自动打开推送详情页；
/// 5. 详情页点「播放」才构造 `PlayerPage`（无 libmpv 时该条 skip）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/push_parser.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/push_detail_page.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/libmpv_guard.dart';
import 'support/player_page_harness.dart';
import 'support/widget_settle.dart';

void main() {
  group('推送对话框', () {
    late Directory tempDir;
    late AppState state;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webhtv-push-dialog');
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
      state.dispose();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    Future<void> mountShell(
      WidgetTester tester, {
      Future<String?> Function()? pickLocalFile,
    }) async {
      if (libmpvUnavailableReason == null) installMediaKitMocks(tester);
      installWindowManagerMocks(tester);
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: AppShell(
            state: state,
            startup: const StartupArguments(),
            pickLocalMediaFile: pickLocalFile,
          ),
        ),
      );
      await settle(tester);
      final accept = find.text('我已了解并继续');
      if (accept.evaluate().isNotEmpty) {
        await tester.tap(accept);
        await tester.pumpAndSettle();
      }
    }

    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('topbar-push')));
      await settle(tester);
    }

    testWidgets('顶栏「推送」打开对话框：地址/剧名/本地文件三处齐备', (tester) async {
      await mountShell(tester);
      await openDialog(tester);

      expect(find.byKey(const ValueKey('push-dialog')), findsOneWidget);
      expect(find.text('推送播放'), findsOneWidget);
      expect(find.byKey(const ValueKey('push-dialog-url')), findsOneWidget);
      expect(find.byKey(const ValueKey('push-dialog-title')), findsOneWidget);
      expect(find.byKey(const ValueKey('push-dialog-pick-file')), findsOneWidget);
      expect(find.text('打开详情'), findsOneWidget, reason: '按钮文案随"先详情后播放"改名');
      // 测试环境没起局域网服务：这里必须是「未开启」提示，而不是一个假的可复制地址。
      expect(find.byKey(const ValueKey('push-dialog-receive-off')), findsOneWidget);
      expect(find.byKey(const ValueKey('push-dialog-copy-url')), findsNothing);
    });

    testWidgets('地址 + 剧名 → 推送详情页（不再直接起播）', (tester) async {
      await mountShell(tester);
      await openDialog(tester);

      const url = 'https://cdn.example/庆余年.E01.m3u8';
      await tester.enterText(find.byKey(const ValueKey('push-dialog-url')), url);
      await tester.enterText(
        find.byKey(const ValueKey('push-dialog-title')),
        '庆余年',
      );
      await tester.tap(find.byKey(const ValueKey('push-dialog-play')));
      await settle(tester);

      // 「点了没反应」的回归护栏：对话框必须真的关掉，详情页必须真的出现。
      expect(find.byKey(const ValueKey('push-dialog')), findsNothing);
      expect(find.byType(PushDetailPage), findsOneWidget);
      final page = tester.widget<PushDetailPage>(find.byType(PushDetailPage));
      expect(page.request.siteKey, pushSiteKey);
      expect(page.request.url, url);
      expect(page.request.vodName, '庆余年');
      expect(find.text('庆余年'), findsWidgets);
      expect(find.byKey(const ValueKey('push-detail-play')), findsOneWidget);
      // 起播前状态层已把待播请求交出去，同一条推送不会在下次状态变化时重开。
      expect(state.pendingPush, isNull);
      expect(find.byType(PlayerPage), findsNothing, reason: '这一页还不该有播放器');
    });

    testWidgets('不填地址点提交：不关窗并显示原因', (tester) async {
      await mountShell(tester);
      await openDialog(tester);

      await tester.tap(find.byKey(const ValueKey('push-dialog-play')));
      await settle(tester);

      expect(find.byKey(const ValueKey('push-dialog')), findsOneWidget);
      expect(find.byKey(const ValueKey('push-dialog-error')), findsOneWidget);
      expect(find.textContaining('推送需要一个播放地址'), findsOneWidget);
      expect(find.byType(PushDetailPage), findsNothing);
    });

    testWidgets('选择本地文件后取消：不打开详情页', (tester) async {
      await mountShell(tester, pickLocalFile: () async => null);
      await openDialog(tester);

      await tester.tap(find.byKey(const ValueKey('push-dialog-pick-file')));
      await settle(tester);

      expect(find.byType(PushDetailPage), findsNothing);
      expect(find.byKey(const ValueKey('push-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // 局域网推送到达时没有 UI 输入：壳层必须自己消费 pendingPush。
    testWidgets('局域网推送到达 → 壳层自动打开推送详情页', (tester) async {
      await mountShell(tester);

      await tester.runAsync(
        () => state.submitPush(
          url: 'https://cdn.example/lan-push.m3u8',
          title: '局域网剧名',
        ),
      );
      await settle(tester);

      expect(find.byType(PushDetailPage), findsOneWidget);
      final page = tester.widget<PushDetailPage>(find.byType(PushDetailPage));
      expect(page.request.siteKey, pushSiteKey);
      expect(page.request.vodName, '局域网剧名');
      expect(state.pendingPush, isNull);
    });

    // 真正会构造 PlayerPage（初始化原生解码器）：没有 libmpv 时跳过。
    testWidgets('详情页点「播放」才构造播放页', skip: libmpvUnavailableReason != null, (tester) async {
      await mountShell(tester);
      await openDialog(tester);
      await tester.enterText(
        find.byKey(const ValueKey('push-dialog-url')),
        'https://cdn.example/a.m3u8',
      );
      await tester.enterText(
        find.byKey(const ValueKey('push-dialog-title')),
        '庆余年',
      );
      await tester.tap(find.byKey(const ValueKey('push-dialog-play')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('push-detail-play')));
      await settlePlayerPage(tester, times: 6);

      expect(find.byType(PlayerPage), findsOneWidget);
      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(page.request.siteKey, pushSiteKey);
      expect(page.request.vodName, '庆余年');
    });
  });
}
