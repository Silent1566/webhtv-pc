import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/ui/player_controller.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';

import 'support/player_navigation_fixture.dart';

/// 可控的 seeking 属性观察端。
///
/// 复用既有导航夹具（`NavigationNativeIO` 已实现 NativePlayer 的属性读、
/// 命令与流），只补上 observe/unobserve 两条路径——真引擎上这两个调用由
/// media-kit 直接转发给 libmpv，单测里必须能反过来驱动它们。
class ObservingNativeIO extends NavigationNativeIO {
  final observers = <String, Future<void> Function(String)>{};
  int unobserves = 0;

  @override
  Future<void> observeProperty(
    String property,
    Future<void> Function(String) listener, {
    bool waitForInitialization = true,
  }) async {
    observers[property] = listener;
  }

  @override
  Future<void> unobserveProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    unobserves++;
    observers.remove(property);
  }

  /// 模拟 libmpv 的属性变化：media-kit 就是把新值以字符串交给监听者。
  Future<void> emit(String property, String value) async {
    final listener = observers[property];
    expect(listener, isNotNull, reason: '控制器必须已经订阅 $property');
    await listener!(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('缓冲提示判据：缓冲中或定位中都算卡住', () {
    test('四条真值表', () {
      expect(
        showBufferingIndicator(
          isBuffering: true,
          isSeeking: false,
          isLoading: false,
        ),
        isTrue,
        reason: '引擎真的在上报缓冲',
      );
      expect(
        showBufferingIndicator(
          isBuffering: false,
          isSeeking: true,
          isLoading: false,
        ),
        isTrue,
        reason: 'seek 期间 mpv 不上报 buffering，只有 seeking=yes，必须单独成立',
      );
      expect(
        showBufferingIndicator(
          isBuffering: true,
          isSeeking: true,
          isLoading: true,
        ),
        isFalse,
        reason: '加载阶段已有全屏 LoadingBlock，再叠一个就是两个圈',
      );
      expect(
        showBufferingIndicator(
          isBuffering: false,
          isSeeking: false,
          isLoading: false,
        ),
        isFalse,
        reason: '直播/回看不 seek 时 seeking 恒为 false，不得凭空多出提示',
      );
    });

    test('加载态压制两种情况各自独立', () {
      expect(
        showBufferingIndicator(
          isBuffering: true,
          isSeeking: false,
          isLoading: true,
        ),
        isFalse,
        reason: '缓冲中也要被加载态压掉',
      );
      expect(
        showBufferingIndicator(
          isBuffering: false,
          isSeeking: true,
          isLoading: true,
        ),
        isFalse,
        reason: '定位中也要被加载态压掉',
      );
    });
  });

  group('控制器暴露 mpv 的 seeking 属性', () {
    test('seeking 属性变化会更新 isSeeking 并通知监听者', () async {
      final io = ObservingNativeIO();
      final controller = PlayerController(
        player: Player(platformPlayer: io),
      );
      addTearDown(controller.dispose);

      await pumpEventQueue();
      expect(
        io.observers['seeking'],
        isNotNull,
        reason: '控制器必须订阅 seeking，否则长时间 seek 期间无任何信号',
      );
      expect(controller.isSeeking, isFalse);

      var notifications = 0;
      controller.addListener(() => notifications++);

      await io.emit('seeking', 'yes');
      expect(controller.isSeeking, isTrue);
      expect(notifications, 1);

      await io.emit('seeking', 'yes');
      expect(controller.isSeeking, isTrue);
      expect(notifications, 1, reason: '同值不重复通知，避免每帧重建');

      await io.emit('seeking', 'no');
      expect(controller.isSeeking, isFalse);
      expect(notifications, 2);
    });

    test('dispose 时撤销 seeking 观察', () async {
      final io = ObservingNativeIO();
      final controller = PlayerController(
        player: Player(platformPlayer: io),
      );
      await pumpEventQueue();
      expect(io.observers['seeking'], isNotNull);

      controller.dispose();
      await pumpEventQueue();

      expect(io.unobserves, greaterThan(0));
      expect(io.observers, isEmpty, reason: '销毁后不得留下未撤销的观察');
    });

    test('非 NativePlayer 平台安全退化为 false', () async {
      final media = NavigationMediaIO();
      final controller = PlayerController(
        player: Player(platformPlayer: media),
      );
      addTearDown(controller.dispose);

      await pumpEventQueue();
      expect(controller.isSeeking, isFalse);
    });
  });
}
