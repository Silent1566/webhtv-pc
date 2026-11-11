import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/app_motion.dart';
import 'package:webhtv_pc/ui/theme.dart';

double _paintOpacity(WidgetTester tester, Finder target) {
  return tester
      .widgetList<FadeTransition>(
        find.ancestor(of: target, matching: find.byType(FadeTransition)),
      )
      .fold(1.0, (value, fade) => value * fade.opacity.value);
}

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    testWidgets(
      '$platform route paints intermediate push/pop without resizing',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        final homeFocus = FocusNode();
        final pageFocus = FocusNode();
        addTearDown(homeFocus.dispose);
        addTearDown(pageFocus.dispose);
        var actions = 0;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: buildAppTheme(Brightness.dark).copyWith(platform: platform),
            home: Scaffold(
              body: TextField(
                key: const ValueKey('home-input'),
                focusNode: homeFocus,
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('home-input')));
        await tester.pump();
        expect(homeFocus.hasFocus, isTrue);
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: Column(
                children: [
                  const SizedBox(
                    key: ValueKey('video-sized-surface'),
                    width: 640,
                    height: 360,
                    child: ColoredBox(color: Colors.black),
                  ),
                  TextField(
                    key: const ValueKey('route-input'),
                    focusNode: pageFocus,
                    autofocus: true,
                  ),
                  TextButton(
                    key: const ValueKey('route-action'),
                    onPressed: () => actions++,
                    child: const Text('操作'),
                  ),
                ],
              ),
            ),
          ),
        );
        // Navigator 先布局 offstage 路由；下一帧才绘制，不推进动画时间。
        await tester.pump();
        await tester.pump();
        final surface = find.byKey(const ValueKey('video-sized-surface'));
        expect(surface, findsOneWidget);
        final first = _paintOpacity(tester, surface);
        expect(first, greaterThan(0), reason: '首帧内容已经可见，不能等待动画才出现');
        expect(first, lessThan(1), reason: '主题必须真正绘制过渡，而非只声明时长');
        final rect = tester.getRect(surface);
        expect(rect.size, const Size(640, 360));
        await tester.tap(find.byKey(const ValueKey('route-action')));
        expect(actions, 1, reason: '动画不锁控件');
        await tester.pump(const Duration(milliseconds: 48));
        final middle = _paintOpacity(tester, surface);
        expect(middle, greaterThan(first));
        expect(middle, lessThan(1));
        expect(tester.getRect(surface), rect, reason: '视频表面的绘制尺寸和位置都不缩放');
        await tester.pump(const Duration(milliseconds: 350));
        expect(_paintOpacity(tester, surface), 1);
        expect(pageFocus.hasFocus, isTrue);
        await tester.enterText(
          find.byKey(const ValueKey('route-input')),
          '可输入',
        );
        expect(find.text('可输入'), findsOneWidget);
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 32));
        final leaving = _paintOpacity(tester, surface);
        expect(leaving, greaterThan(0));
        expect(leaving, lessThan(1), reason: 'pop 也必须有真实中间帧');
        expect(tester.getRect(surface), rect);
        await tester.pump(const Duration(milliseconds: 140));
        await tester.pump();
        expect(surface, findsNothing);
        expect(homeFocus.hasFocus, isTrue);
      },
    );
  }

  for (final preference in ['disableAnimations', 'accessibleNavigation']) {
    testWidgets('$preference removes route motion and route delay', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: buildAppTheme(Brightness.dark)
              .copyWith(platform: TargetPlatform.windows),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: preference == 'disableAnimations',
              accessibleNavigation: preference == 'accessibleNavigation',
            ),
            child: AppMotionScope(child: child!),
          ),
          home: const Scaffold(body: Text('首页')),
        ),
      );
      final route = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          body: SizedBox(
            key: ValueKey('reduced-surface'),
            width: 640,
            height: 360,
          ),
        ),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      final surface = find.byKey(const ValueKey('reduced-surface'));
      expect(_paintOpacity(tester, surface), 1);
      expect(
        route.animation!.status,
        AnimationStatus.completed,
        reason: '不能只不绘制而仍等待时长',
      );
      final rect = tester.getRect(surface);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getRect(surface), rect);
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reduced-surface'), skipOffstage: false),
        findsNothing,
      );
      expect(find.text('首页'), findsOneWidget);
    });
  }

  testWidgets(
    'changing reduced motion does not remount route content or lose focus',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final reduced = ValueNotifier(false);
      final focus = FocusNode();
      addTearDown(reduced.dispose);
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: buildAppTheme(Brightness.light)
              .copyWith(platform: TargetPlatform.windows),
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: reduced,
            builder: (context, value, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: value),
              child: AppMotionScope(child: child!),
            ),
          ),
          home: const Scaffold(body: Text('首页')),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: TextField(
              key: const ValueKey('stable-input'),
              focusNode: focus,
              autofocus: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final input = find.byKey(const ValueKey('stable-input'));
      final element = tester.element(input);
      await tester.enterText(input, '偏好不丢输入');
      reduced.value = true;
      await tester.pump();
      expect(tester.element(input), same(element));
      expect(find.text('偏好不丢输入'), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      reduced.value = false;
      await tester.pump();
      expect(tester.element(input), same(element));
      expect(focus.hasFocus, isTrue);
    },
  );

  testWidgets('rapid push/pop does not bring a popped route back', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: buildAppTheme(Brightness.light)
            .copyWith(platform: TargetPlatform.windows),
        home: const Scaffold(body: Text('首页')),
      ),
    );
    void push(String label) {
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(body: Text(label, key: ValueKey(label))),
        ),
      );
    }

    push('甲');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 24));
    navigator.currentState!.pop();
    push('乙');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 24));
    navigator.currentState!.pop();
    push('丙');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const ValueKey('甲'), skipOffstage: false), findsNothing);
    expect(find.byKey(const ValueKey('乙'), skipOffstage: false), findsNothing);
    expect(find.byKey(const ValueKey('丙')), findsOneWidget);
    expect(_paintOpacity(tester, find.byKey(const ValueKey('丙'))), 1);
    expect(tester.takeException(), isNull);
  });
}
