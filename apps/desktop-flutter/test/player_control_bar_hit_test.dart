/// 底栏空白不得落到画面手势上（`docs/phase8/design/01-overlay-layout.md` §7 A3 的补集）。
///
/// 画面层的单击语义是**播放/暂停**（`_onVideoTap`）。底栏里行间留白与上下
/// padding 没有任何控件，命中不到时这一笔会继续交给下层画面手势——用户看到
/// 的就是「点进度条差几像素 → 没跳进度，反而暂停了」。实测坐标：
/// 1024×640 下进度行 532..580、动作行 584..632，于是 524..531（上 padding）、
/// 581..583（行间 xs）、633..639（下 padding）三段都是"点了变暂停"。
///
/// 锁两件事：
/// 1. 底栏内的空白点下去什么都不发生（不 seek、不 pause、不 play）；
/// 2. 吸收空白不许把进度条一起吃掉——点滑杆仍然是一次 seek。
library;

// ignore_for_file: invalid_use_of_protected_member

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'live_playback_session_test.dart' show fixture;
import 'player_live_controls_test.dart' show MediaIO, flush, mount, unmount;

/// 记录 pause / play / seek 调用序列的引擎替身。
///
/// 与 `player_drag_pause_test.dart` 的同名替身同源：`MediaIO.pause()` 是空
/// 实现、`MediaIO.seek()` 还会把 playing 置回 true，用 state 反推只会得到假信号。
class _RecordingIO extends MediaIO {
  _RecordingIO(super.original, super.journal);

  final calls = <String>[];

  @override
  Future<void> pause() async {
    calls.add('pause');
    await super.pause();
  }

  @override
  Future<void> play() async {
    calls.add('play');
    await super.play();
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek');
    await super.seek(position);
  }

  /// 把引擎置成"播放中"：页面据此认定底栏的点击发生在播放中。
  void emitPlaying() {
    state = state.copyWith(playing: true);
    if (!disposed) original.playingController.add(true);
  }
}

void main() {
  testWidgets('底栏空白垫到画面上：点它不暂停、不跳转', (tester) async {
    final f = fixture();
    final media = await mount(
      tester,
      PlayerPage(state: f.state, request: f.session.request),
    );
    final player = tester.widget<Video>(find.byType(Video)).controller.player;
    final io = _RecordingIO(media.original, media.journal);
    player.platform = io;
    final pageState = tester.state<State<PlayerPage>>(find.byType(PlayerPage));
    debugRevealPlayerControls(pageState);
    await flush(tester);
    io.emitPlaying();
    await flush(tester);

    final slider = find.descendant(
      of: find.byType(PlayerProgressSlider),
      matching: find.byType(Slider),
    );
    final sliderRect = tester.getRect(slider);
    final progressRect = tester.getRect(find.byType(PlayerProgressSlider));
    final actionRect = tester.getRect(find.byType(PlayerOverlayActionRow));
    final x = sliderRect.center.dx;

    Future<void> tapAt(Offset point, String where) async {
      io.calls.clear();
      // 每次点击前都唤回控制栏：3 秒隐藏计时器与双击窗口都会让用例自己失真。
      debugRevealPlayerControls(
        tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.tapAt(point);
      await flush(tester);
      io.emitPlaying();
      expect(
        io.calls,
        isEmpty,
        reason:
            '$where 属于底栏的空白，点下去必须什么都不发生'
            '（落到画面手势就会变成播放/暂停）',
      );
    }

    // 一段 padding / 行间留白都不许漏；坐标从真实布局量出来，不写死像素。
    await tapAt(Offset(x, progressRect.top - 4), '进度行上方的 padding');
    await tapAt(
      Offset(x, (progressRect.bottom + actionRect.top) / 2),
      '进度行与动作行之间的留白',
    );
    await tapAt(Offset(x, actionRect.bottom + 4), '动作行下方的 padding');

    // 反证：吸收空白不许把进度条本身吃掉。
    io.calls.clear();
    debugRevealPlayerControls(
      tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.tapAt(Offset(x, sliderRect.center.dy));
    await flush(tester);
    expect(
      io.calls.where((call) => call == 'seek').length,
      1,
      reason: '点滑杆仍然是一次跳转：这条用例是"吸收空白"的护栏',
    );

    await unmount(tester);
    expect(tester.takeException(), isNull);
  });
}
