import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/app_motion.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  test('重建动效作用域不会产生新的主题数据', () {
    final base = buildAppTheme(Brightness.dark);
    ThemeData apply() =>
        base.copyWith(pageTransitionsTheme: appPageTransitionsTheme());
    expect(apply(), equals(apply()), reason: '同样偏好必须得到相等的主题');
    for (final reduced in [false, true]) {
      expect(
        appPageTransitionsTheme(reducedMotion: reduced),
        equals(appPageTransitionsTheme(reducedMotion: reduced)),
      );
    }
  });

  testWidgets('播放诊断等状态通知不能重新构造当前播放器路由', (tester) async {
    final notifications = ValueNotifier(0);
    addTearDown(notifications.dispose);
    final navigator = GlobalKey<NavigatorState>();
    var routeBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: buildAppTheme(Brightness.dark),
        builder: (context, child) => ListenableBuilder(
          listenable: notifications,
          builder: (context, _) => AppMotionScope(child: child!),
        ),
        home: const Scaffold(body: Text('详情')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) {
          routeBuilds++;
          return const Scaffold(body: Text('当前播放器'));
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('当前播放器'), findsOneWidget);
    final initialBuilds = routeBuilds;
    for (var i = 0; i < 4; i++) {
      notifications.value++;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        routeBuilds,
        initialBuilds,
        reason: '无关状态通知不可重新构造 PlaybackRequest，触发播放器重新加载',
      );
    }
    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 200));
  });
}
