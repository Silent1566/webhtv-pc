import 'package:flutter_test/flutter_test.dart';

/// 推进假时钟直到没有帧在排队，每一轮先放行一次真实事件循环。
///
/// 为什么不能直接 `pumpAndSettle`：`AppShell` 在 `usage-boundary-accepted` 的
/// `File.exists()`（真实 `dart:io`）返回前渲染 `LoadingBlock`——一个无限
/// `CircularProgressIndicator`，每帧都会再排一帧。假时钟推不动真实 IO
/// （`binding.pump` 只 flush 假微任务，不回到真实事件循环），于是
/// `pumpAndSettle` 唯一的出口「`hasScheduledFrame == false`」在慢机器上永远
/// 到不了：CI run 44441281049 就是这样在 6000 次 pump 后抛
/// `pumpAndSettle timed out`。
///
/// 收敛判据与 `pumpAndSettle` 完全相同（没有帧在排队），只是每轮多给真实事件
/// 循环一次机会让 IO 落地；真出现无限动画照样失败，窗口还从 10 分钟假时钟收紧
/// 到 30 秒真实时间，失败信息直接指向「真实 IO 没落地 / 有无限动画」。
///
/// 用法：`mount` 里 `pumpWidget` 之后调用它，替代
/// `runAsync(Future.delayed(Duration.zero)) + pumpAndSettle()` 这两步。
Future<void> settle(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (!tester.binding.hasScheduledFrame) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('30s 真实时间内仍在排帧：真实 IO 未落地或存在无限动画');
    }
  }
}
