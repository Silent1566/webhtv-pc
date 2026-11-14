import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/async_action_feedback.dart';
import 'package:webhtv_pc/ui/common.dart';
import 'package:webhtv_pc/ui/theme.dart';

const ValueKey<String> _feedbackKey = ValueKey('async-action-feedback');

void main() {
  for (final size in [
    const Size(800, 600),
    const Size(1200, 800),
    const Size(1920, 1080),
  ]) {
    testWidgets('播放等待反馈居中且加载指示清晰可见：$size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      AsyncActionFeedback? action;
      addTearDown(() => action?.close());
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () =>
                    action = AsyncActionFeedback.begin(context, '正在准备播放：第1集'),
                child: const Text('播放'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('播放'));
      await tester.pump();
      final panel = find.byKey(_feedbackKey);
      expect(panel, findsOneWidget);
      expect(
        (tester.getCenter(panel) - size.center(Offset.zero)).distance,
        lessThanOrEqualTo(4),
        reason: '下一帧反馈就应在视口中央，而不是角落通知',
      );
      await tester.pump(const Duration(milliseconds: 160));
      expect(
        (tester.getCenter(panel) - size.center(Offset.zero)).distance,
        lessThan(1),
      );
      expect(
        find.descendant(
          of: panel,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      action!.close();
      await tester.pump();
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('等待反馈只有一个转圈，没有文字与底色：$brightness', (tester) async {
      AsyncActionFeedback? action;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () =>
                    action = AsyncActionFeedback.begin(context, '正在准备播放'),
                child: const Text('播放'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('播放'));
      await tester.pump();
      final panel = find.byKey(_feedbackKey);
      expect(panel, findsOneWidget);
      expect(
        find.descendant(of: panel, matching: find.byType(Text)),
        findsNothing,
        reason: '只留加载转圈，不上屏文案',
      );
      expect(
        find.descendant(of: panel, matching: find.byType(Material)),
        findsNothing,
        reason: '不要背景底色卡片',
      );
      final spinner = tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: panel,
          matching: find.byType(CircularProgressIndicator),
        ),
      );
      expect(spinner.color, isNull, reason: '颜色随主题 primary，不写死');
      expect(
        tester.getSize(panel),
        const Size(36, 36),
        reason: '转圈盒子就是转圈本身，不撑满整屏',
      );
      final semantics = tester.ensureSemantics();
      expect(tester.getSemantics(panel).label, '正在准备播放', reason: '不上屏也要能被屏读出来');
      semantics.dispose();
      action!.close();
      await tester.pump();
    });
  }

  for (final media in [
    const MediaQueryData(disableAnimations: true),
    const MediaQueryData(accessibleNavigation: true),
  ]) {
    testWidgets('减动态只留静态图标，首帧即可见：$media', (tester) async {
      AsyncActionFeedback? action;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(data: media, child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () =>
                    action = AsyncActionFeedback.begin(context, '正在准备播放'),
                child: const Text('播放'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('播放'));
      await tester.pump();
      expect(find.byType(LoadingBlock), findsNothing);
      expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(_feedbackKey),
          matching: find.byType(Text),
        ),
        findsNothing,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
      action!.close();
      await tester.pump();
      expect(find.byKey(_feedbackKey), findsNothing);
    });
  }

  testWidgets('反馈不占点击且同owner防重入，成功导航首帧不残留', (tester) async {
    final pending = Completer<void>();
    final navigator = GlobalKey<NavigatorState>();
    var runs = 0;
    var otherClicks = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                FilledButton(
                  onPressed: () async {
                    final feedback = AsyncActionFeedback.begin(
                      context,
                      '正在准备播放',
                    );
                    if (feedback == null) return;
                    runs++;
                    try {
                      await pending.future;
                      if (!feedback.isCurrent) return;
                      feedback.dismiss();
                      await navigator.currentState!.push(
                        MaterialPageRoute<void>(
                          builder: (_) => const Scaffold(body: Text('播放器')),
                        ),
                      );
                    } finally {
                      feedback.close();
                    }
                  },
                  child: const Text('播放'),
                ),
                TextButton(
                  onPressed: () => otherClicks++,
                  child: const Text('其他操作'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('播放'));
    await tester.pump();
    expect(find.byType(LoadingBlock), findsOneWidget);
    await tester.tap(find.text('播放'));
    await tester.tap(find.text('其他操作'));
    expect(runs, 1);
    expect(otherClicks, 1);
    pending.complete();
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsNothing);
    await tester.pump();
    expect(find.text('播放器'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('进入其他路由即取消，返回原页也不接受旧结果，新页独立owner可反馈', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    AsyncActionFeedback? oldAction;
    AsyncActionFeedback? newAction;
    late BuildContext original;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              original = context;
              return FilledButton(
                onPressed: () =>
                    oldAction = AsyncActionFeedback.begin(context, '原页等待'),
                child: const Text('开始'),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pump();
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () =>
                  newAction = AsyncActionFeedback.begin(context, '新页等待'),
              child: const Text('新动作'),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(original.mounted, isTrue);
    expect(find.byKey(_feedbackKey), findsNothing);
    expect(oldAction!.isCurrent, isFalse);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('新动作'));
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsOneWidget);
    expect(newAction!.isCurrent, isTrue);
    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_feedbackKey), findsNothing);
    expect(newAction!.isCurrent, isFalse);
    expect(oldAction!.isCurrent, isFalse);
  });

  testWidgets('相同路由内发起组件卸载仍收掉反馈与owner', (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    AsyncActionFeedback? action;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, show, _) => show
                ? Builder(
                    builder: (context) => FilledButton(
                      onPressed: () =>
                          action = AsyncActionFeedback.begin(context, '正在准备播放'),
                      child: const Text('开始'),
                    ),
                  )
                : const Text('其他区块'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pump();
    visible.value = false;
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsNothing);
    expect(action!.isCurrent, isFalse);
  });
}
