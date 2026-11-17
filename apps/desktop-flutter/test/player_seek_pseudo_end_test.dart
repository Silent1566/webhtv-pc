/// seek 伪结束的判据与闸门接线。
///
/// **为什么以纯函数断言 + 源码契约为主**：连播闸门住在 `_PlayerPageState` 里，
/// 它的 `PlayerController` 构造会触发 `MediaKit.ensureInitialized()`，在
/// `flutter test`（无 libmpv）里必然抛异常。所以判据抽到
/// `lib/core/playback.dart` 直接测，接线用源码断言锁（与
/// `phase7_player_advance_test.dart` 同一套做法）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback.dart';

String _readSourceCode(String relative) => File(relative)
    .readAsLinesSync()
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  final pageSource = _readSourceCode('lib/ui/player_page.dart');
  final controllerSource = _readSourceCode('lib/ui/player_controller.dart');

  group('伪结束判据：位置跳变', () {
    test('自然播放的相邻采样不算跳变', () {
      expect(isPositionJump(previousMs: 1000, currentMs: 1250), isFalse);
      // 8x 快放一次通知最多前进 2s，仍低于 10s 门槛。
      expect(isPositionJump(previousMs: 1000, currentMs: 3000), isFalse);
    });

    test('点击/拖动进度条到片尾算跳变（伪结束）', () {
      expect(isPositionJump(previousMs: 600000, currentMs: 3290325), isTrue);
      expect(isPositionJump(previousMs: 1000, currentMs: 3290325), isTrue);
    });

    test('快退同样算跳变', () {
      expect(isPositionJump(previousMs: 600000, currentMs: 1000), isTrue);
    });

    test('没有基线（刚换媒体）时不判跳变', () {
      expect(isPositionJump(previousMs: -1, currentMs: 5000), isFalse);
    });
  });

  group('起播定位判据', () {
    test('同一点（含毫秒误差）不再补 seek', () {
      expect(
        isSameStartPosition(
          const Duration(milliseconds: 1200000),
          const Duration(milliseconds: 1200000),
        ),
        isTrue,
      );
      expect(
        isSameStartPosition(
          const Duration(milliseconds: 1200000),
          const Duration(milliseconds: 1200400),
        ),
        isTrue,
      );
    });

    test('差得远就是两个点', () {
      expect(
        isSameStartPosition(
          const Duration(milliseconds: 1200000),
          const Duration(milliseconds: 1205000),
        ),
        isFalse,
      );
      expect(isSameStartPosition(null, const Duration(seconds: 5)), isFalse);
      expect(isSameStartPosition(null, null), isTrue);
    });
  });

  group('跨缓冲跳转必须重开定位（源码契约）', () {
    test('进度条走缓冲分流，不再直连 seek', () {
      expect(pageSource.contains('onSeek: _seekFromUser,'), isTrue);
      expect(pageSource.contains('onSeek: _controller.seek,'), isFalse);
      expect(pageSource.contains('_controller.buffered'), isTrue);
    });

    test('重开时把定位随 open 下发', () {
      expect(
        pageSource.contains('startAt: _startPositionForOpen(intent.startPosition)'),
        isTrue,
      );
      expect(
        controllerSource.contains('Media(url, httpHeaders: headers, start: startAt)'),
        isTrue,
        reason: '定位必须写在 Media 上，打开后 seek 会开第二条连接被 429',
      );
    });

    test('起播定位走 mpv 的 start 选项（FFI），不是 setProperty', () {
      expect(
        controllerSource.contains('_startOption.apply(nativeHandle, startAt)'),
        isTrue,
        reason: '定位必须在 loadfile 之前写进 option，property 实测无效',
      );
      expect(
        controllerSource.contains('Media(url, httpHeaders: headers, start: startAt)'),
        isTrue,
        reason: '定位意图也要挂在 Media 上，供假件模拟内核',
      );
    });

    test('恢复进度不再无条件 seek', () {
      expect(pageSource.contains('alreadyPositioned'), isTrue);
      expect(pageSource.contains('isSameStartPosition('), isTrue);
    });
  });

  group('seek 溯源（源码契约）', () {
    test('控制器为每次 seek 记账', () {
      expect(
        controllerSource.contains('DateTime? _lastSeekAt;'),
        isTrue,
        reason: '闸门要靠 seek 时刻判断伪结束',
      );
      final seekStart = controllerSource.indexOf('Future<void> seek(Duration target) {');
      expect(seekStart, greaterThan(0));
      expect(
        controllerSource.substring(seekStart, seekStart + 160).contains(
          '_lastSeekAt = DateTime.now();',
        ),
        isTrue,
        reason: 'seek 必须先记账再下发，否则闸门看到的是陈旧时刻',
      );
    });
  });

  group('连播闸门接线（源码契约）', () {
    test('第四道闸门排在真播完判定之后', () {
      final genuine = pageSource.indexOf('if (!_isGenuineEnd()) return;');
      final spurious = pageSource.indexOf('if (_spuriousCompletion) return;');
      expect(genuine, greaterThan(0));
      expect(spurious, greaterThan(genuine));
    });

    test('闸门复用 core 的判据，不就地硬编码窗口', () {
      expect(pageSource.contains('isPositionJump('), isTrue);
      expect(pageSource.contains('_seekPending'), isTrue);
      expect(pageSource.contains('_controller.seekCount'), isTrue);
    });

    test('伪结束期间不落库（否则历史被写成已看完）', () {
      final start = pageSource.indexOf('void _persistProgress() {');
      expect(start, greaterThan(0));
      expect(
        pageSource.substring(start, start + 400).contains(
          'if (_spuriousCompletion) return;',
        ),
        isTrue,
      );
    });

    test('换媒体必须丢弃上一集的 seek 溯源', () {
      expect(pageSource.contains('_controller.clearLastSeek();'), isTrue);
    });

    test('跳过片尾的 seek 不算用户 seek', () {
      expect(pageSource.contains('_skipSeekAt = DateTime.now();'), isTrue);
      expect(pageSource.contains('_isSkipSeekJustNow()'), isTrue);
    });

    test('completed 复位时作废伪结束判定', () {
      expect(pageSource.contains('_trackPositionSample();'), isTrue);
      expect(
        pageSource.contains('_spuriousCompletion = false;'),
        isTrue,
      );
    });
  });
}
