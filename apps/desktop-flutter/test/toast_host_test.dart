/// 右下角浮动通知（`lib/ui/toast.dart`）的门禁。
///
/// 锁的是用户已经定下的四条行为，每一条单独都能被一种错误实现弄红：
///
/// - 自动关闭 vs 错误驻留更久：把 error 也当成 4 秒，第 2 条红；
/// - 悬停暂停：只做视觉上的 hover 效果而不 stop 控制器，第 3 条红；
/// - 动作按钮在卡片里且能用：把动作放回页面侧，第 4 条红；
/// - 透明区域不拦截点击：把宿主包成整屏不透明层，第 6 条红。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/toast.dart';
import 'package:webhtv_pc/ui/tokens.dart';

/// 页面侧被点中的次数：用来证明通知没有把整屏的点击吃掉。
int _pageTaps = 0;

ValueKey<String> _toastKey(int id) => ValueKey<String>('app-toast-$id');

ValueKey<String> _closeKey(int id) => ValueKey<String>('app-toast-close-$id');

/// 挂一棵「页面 + 通知宿主」的树，和 `app.dart` 里的挂法一致。
Future<void> _pumpHost(WidgetTester tester) async {
  _pageTaps = 0;
  await tester.pumpWidget(
    MaterialApp(
      home: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _pageTaps++,
            child: const ColoredBox(color: Color(0xFF101010)),
          ),
          const ToastHost(),
        ],
      ),
    ),
  );
}

/// 走完入场动画（`AppMotion.base`）。入场期间卡片有位移，取坐标前必须先走完。
Future<void> _settleEntrance(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(AppMotion.base);
}

/// 真实鼠标悬停：必须是 `PointerDeviceKind.mouse` 且**不按下**。
Future<TestGesture> _mouseAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await tester.pump();
  await mouse.moveTo(at);
  await tester.pump();
  return mouse;
}

void main() {
  setUp(dismissAllToasts);

  testWidgets('info 通知到时自动关闭（约 4 秒）', (tester) async {
    await _pumpHost(tester);
    final id = showToast('已保存配置');
    await _settleEntrance(tester);
    expect(find.byKey(_toastKey(id)), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(
      find.byKey(_toastKey(id)),
      findsOneWidget,
      reason: '默认驻留 4 秒，3 秒时不该消失',
    );

    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();
    expect(find.byKey(_toastKey(id)), findsNothing);
  });

  testWidgets('error 通知驻留 15 秒后自动关闭（远长于 info 的 4 秒）', (tester) async {
    await _pumpHost(tester);
    final id = showToast('源站不可用', kind: ToastKind.error);
    await _settleEntrance(tester);

    // 14 秒时还在：错误要比 info 的 4 秒长得多，不能提前收走用户还没读完的原因。
    await tester.pump(const Duration(seconds: 14));
    expect(
      find.byKey(_toastKey(id)),
      findsOneWidget,
      reason: '错误驻留 15 秒，14 秒时不该消失',
    );

    // 越过 15 秒即自动关闭，把右下角的集数卡片与「并入」按钮让出来。
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();
    expect(
      find.byKey(_toastKey(id)),
      findsNothing,
      reason: '15 秒到时自己让开右下角，不必等用户手动收',
    );
  });

  testWidgets('悬停暂停倒计时，移开后继续', (tester) async {
    await _pumpHost(tester);
    final id = showToast('已复制到剪贴板');
    await _settleEntrance(tester);

    final mouse = await _mouseAt(
      tester,
      tester.getCenter(find.byKey(_toastKey(id))),
    );
    await tester.pump(const Duration(seconds: 8));
    expect(
      find.byKey(_toastKey(id)),
      findsOneWidget,
      reason: '悬停期间倒计时暂停，超过 4 秒也不该关闭',
    );

    await mouse.moveTo(const Offset(AppSpace.md, AppSpace.md));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(
      find.byKey(_toastKey(id)),
      findsNothing,
      reason: '移开后从暂停处继续，剩余时间走完即关闭',
    );
  });

  testWidgets('动作按钮渲染在通知内，点击即执行', (tester) async {
    await _pumpHost(tester);
    var fired = 0;
    var dismissed = 0;
    final id = showToast(
      '当前源已失效',
      kind: ToastKind.error,
      detail: '错误码：network',
      action: AppToastAction(label: '换源', onPressed: () => fired++),
      onDismiss: () => dismissed++,
    );
    await _settleEntrance(tester);

    expect(find.text('换源'), findsOneWidget);
    expect(find.text('错误码：network'), findsOneWidget);

    await tester.tap(find.text('换源'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(fired, 1);
    expect(find.byKey(_toastKey(id)), findsNothing);
    expect(dismissed, 0, reason: '动作按钮不是"关掉它"，不触发 onDismiss');
  });

  testWidgets('关闭按钮调用 onDismiss', (tester) async {
    await _pumpHost(tester);
    var dismissed = 0;
    final id = showToast('已刷新', onDismiss: () => dismissed++);
    await _settleEntrance(tester);

    await tester.tap(find.byKey(_closeKey(id)));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(dismissed, 1);
    expect(find.byKey(_toastKey(id)), findsNothing);
  });

  testWidgets('卡片之外的透明区域不拦截点击', (tester) async {
    await _pumpHost(tester);
    final id = showToast('浮在右下角');
    await _settleEntrance(tester);

    final card = tester.getRect(find.byKey(_toastKey(id)));
    // 卡片左边、同一行高的空白：仍然属于宿主的盒子，但那里什么都没有画。
    await tester.tapAt(Offset(80, card.center.dy));
    await tester.pump();
    expect(_pageTaps, 1, reason: '透明区域必须让点击穿过去');

    await tester.tapAt(card.center);
    await tester.pump();
    expect(_pageTaps, 1, reason: '卡片本体吸收点击，不漏到页面');
  });

  testWidgets('可见栈上限 4，更早的被挤掉并回调 onDismiss', (tester) async {
    await _pumpHost(tester);
    var droppedDismissed = 0;
    final ids = <int>[];
    for (var i = 0; i < 5; i++) {
      ids.add(
        showToast(
          '通知 $i',
          onDismiss: i == 0 ? () => droppedDismissed++ : null,
        ),
      );
    }
    await _settleEntrance(tester);

    expect(find.byKey(_toastKey(ids[0])), findsNothing);
    for (final id in ids.skip(1)) {
      expect(find.byKey(_toastKey(id)), findsOneWidget);
    }
    expect(droppedDismissed, 1);

    // 新的在最下方。
    final newest = tester.getRect(find.byKey(_toastKey(ids.last)));
    final older = tester.getRect(find.byKey(_toastKey(ids[ids.length - 2])));
    expect(newest.bottom, greaterThan(older.bottom));
  });

  // 唯一能抓住"宿主挂错位置"的用例：`_pumpHost` 把 ToastHost 放进 `home:`，
  // 而 `home:` 在 Navigator/Overlay **之内**，于是任何"控件依赖 Overlay"的写法
  // 在那里都能过——生产挂法恰恰相反。历史上关闭按钮的 `tooltip:` 就是这么漏的
  // （`RawTooltip.build` 无条件 `assert(debugCheckHasOverlay)`，一渲染就抛
  // `No Overlay widget found`，release 剥掉断言才看不见）。
  testWidgets('按生产结构挂在 MaterialApp.builder（Navigator/Overlay 之外）不抛异常', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Stack(
          fit: StackFit.expand,
          children: [child ?? const SizedBox.shrink(), const ToastHost()],
        ),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );

    final id = showToast('浮在所有路由与对话框之上');
    await _settleEntrance(tester);

    expect(
      tester.takeException(),
      isNull,
      reason: '宿主在 Overlay 之外，任何依赖 Overlay 的控件都会在这里露馅',
    );
    expect(find.byKey(_toastKey(id)), findsOneWidget);
    expect(find.byKey(_closeKey(id)), findsOneWidget);
  });
}
