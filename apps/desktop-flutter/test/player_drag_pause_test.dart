/// 拖动进度条时暂停、松手按拖动前状态续播（`docs/reference/potplayer-borrowings.md` §3.2）。
///
/// 锁五件事：
/// 1. [PlayerDragPauseGate] 的四种情形：播放中拖动 → pause 后 resume；拖动前
///    本就暂停 → 松手不 resume；拖动中重复 begin 不覆盖；未 begin 直接 end
///    返回 false；
/// 2. [PlayerProgressSlider] 真拖动才发 [PlayerProgressSlider.onSeekStart] /
///    [PlayerProgressSlider.onSeekEnd]，且 `onSeek` 仍是连续的；
/// 3. 直播（`duration <= 0`）时三个回调一个都不触发（判据仍是既有的 `live`，
///    没有为本次改动新加分支）；
/// 4. [PlayerOptions.dragPause] 的持久化：json 往返、旧配置缺键回落 `true`、
///    `copyWith` / `normalized` 保留值；
/// 5. 真实 [PlayerPage] 接线：VOD 播放中拖动 → 暂停再续播；拖前本就暂停 →
///    松手不续播；直播（含引擎报出**非零**时长那种）→ 一个都不调；回看与点播
///    同语义；关掉开关/拖动中途换集都不会让 gate 残留状态；
/// 6. seek **只在松手时发一次**：拖动期间页面只记目标、不落引擎（这条 HLS
///    代理单次 seek 1–3 秒，逐格排队会把画面按在 `seeking=yes` 上）。
///
/// 另外锁两条"看起来像 bug、其实是既定语义"的行为：单击轨道 = 一次导航
/// （start → seek → end，暂停随即恢复），以及程序化 seek 从不经过这条链路。
///
/// 为什么单独一个套件：暂停/续播的判据全在"拖动前是什么状态"，它一旦写错，
/// 症状是"替用户点了播放"——静默、且只在流媒体上明显（本地文件感觉不到）。
library;

// debugRevealPlayerControls 是 @visibleForTesting 的观测缝。
// ignore_for_file: invalid_use_of_protected_member

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/epg.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'live_playback_session_test.dart' show fixture;
import 'player_live_controls_test.dart' show MediaIO, flush, mount, unmount;

/// 拖动一次滑杆：`Slider` 的 onChangeStart → 若干次 onChanged → onChangeEnd。
Future<void> dragSlider(WidgetTester tester) async {
  await tester.drag(find.byType(Slider), const Offset(120, 0));
  await tester.pump();
}

/// 记录 pause / play 调用序列的引擎替身。
///
/// 为什么必须自己记：`MediaIO.pause()` 是空实现（不改 state、也不发 playing
/// 流），暂停在既有脚手架上**没有任何可观测表象**；而 `MediaIO.seek()` 又会
/// 把 playing 置回 true，用 state 反推只会得到假信号。
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

  /// 把引擎置成"播放中"：页面据此认定拖动前在播。
  void emitPlaying() {
    state = state.copyWith(playing: true);
    if (!disposed) original.playingController.add(true);
  }

  /// 把引擎置成"播放中被用户暂停"：拖动前本就暂停的那条路径。
  void emitPaused() {
    state = state.copyWith(playing: false);
    if (!disposed) original.playingController.add(false);
  }
}

/// 挂载真实 [PlayerPage]，并把引擎换成可观测的 [_RecordingIO]。
///
/// 返回播放器本体一起交出去：播放状态读的是 **[Player]** 的 state（它由
/// 引擎推上来的 playing 流维护），不是替身自己那份——替身是挂上去之后才
/// 接手的，它的 `state` 从默认值起算，读它会得到"没在播"的假象。
Future<({_RecordingIO io, Player player})> mountRecorder(
  WidgetTester tester,
  PlayerPage page,
) async {
  final media = await mount(tester, page);
  final player = tester.widget<Video>(find.byType(Video)).controller.player;
  final recorder = _RecordingIO(media.original, media.journal);
  player.platform = recorder;
  debugRevealPlayerControls(
    tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
  );
  await tester.pump();
  return (io: recorder, player: player);
}

/// 走**真实右键菜单**开关 `dragPause`（F10 → 菜单项 onSelect）。
///
/// 为什么不用 `state.setPlayerOptions`：页面只在 initState/换媒时读一次
/// `state.playerOptions`，直接改 store 不会改变页面当前这份 `_options`，
/// 那样测到的就不是用户在菜单里关掉的那条路径。
Future<void> toggleDragPause(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.f10);
  await tester.pump();
  final menu = tester.widget<PlayerContextMenu>(find.byType(PlayerContextMenu));
  menu.sections
      .expand((section) => section.items)
      .firstWhere((item) => item.id == 'drag_pause')
      .onSelect!();
  await flush(tester);
  // 就地开关**不关菜单**（见右菜单用例集），而开着的菜单会挡住滑杆的指针：
  // 不关掉它，后面的拖动就打不到滑杆上，用例会以"没暂停"的方式假绿。
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump();
  debugRevealPlayerControls(
    tester.state<State<PlayerPage>>(find.byType(PlayerPage)),
  );
  await tester.pump();
}

/// 按下滑杆并拖到松手前一刻，让用例能在"拖动中"断言。
Future<TestGesture> halfDrag(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(PlayerProgressSlider)),
  );
  await tester.pump();
  await gesture.moveBy(const Offset(40, 0));
  await tester.pump();
  await gesture.moveBy(const Offset(60, 0));
  await tester.pump();
  return gesture;
}

/// 进度行里那两个"分:秒"文本（左：当前位置，右：总时长）。
///
/// 拖动期间引擎不上报新位置（这一次拖动**还没** seek），所以这两个文本只要
/// 变了，来源就只能是页面的拖动目标——用它把"时间跟着拇指走"钉住。
///
/// 只认两段式（分:秒）：三段式 时:分:秒 那个是界面上的墙钟，每跑一秒自己
/// 就会变，混进来会让"标签变了"变成永真断言。
List<String> timeLabels(WidgetTester tester) {
  final pattern = RegExp(r'^\d{1,2}:\d{2}$');
  return tester
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data)
      .whereType<String>()
      .where(pattern.hasMatch)
      .toList();
}

void main() {
  group('PlayerDragPauseGate', () {
    test('播放中拖动：先 pause，松手 resume', () {
      final gate = PlayerDragPauseGate();
      expect(
        gate.begin(playing: true),
        isTrue,
        reason: '拖动前在播 → 该暂停（这就是"拖动时先停住"）',
      );
      expect(gate.end(), isTrue, reason: '拖动前在播 → 松手回到播放状态');
    });

    test('拖动前本就暂停：松手不许 resume', () {
      final gate = PlayerDragPauseGate();
      expect(gate.begin(playing: false), isFalse, reason: '本来就没在播，不必暂停');
      expect(
        gate.end(),
        isFalse,
        reason: '松手一律 play() 等于替一个暂停着的用户点了播放',
      );
    });

    test('拖动中重复 begin 不覆盖已记录的播放状态', () {
      final gate = PlayerDragPauseGate();
      expect(gate.begin(playing: true), isTrue);
      expect(
        gate.begin(playing: false),
        isFalse,
        reason: '重复 begin 既不该再发一次 pause，也不该改写状态',
      );
      expect(
        gate.end(),
        isTrue,
        reason: '状态仍是第一次 begin 记下的 true：重复 begin 没有覆盖它',
      );
    });

    test('reset() 丢掉进行中的状态：既不静默失效，也不强行续播', () {
      final gate = PlayerDragPauseGate();
      expect(gate.begin(playing: true), isTrue);
      gate.reset();
      expect(gate.end(), isFalse, reason: '换集/换台后松手不该再按旧状态 play()');
      expect(
        gate.begin(playing: true),
        isTrue,
        reason: '残留状态会让下一次 begin 返回 false（功能静默失效），这里必须仍然暂停',
      );
      expect(gate.end(), isTrue);
    });

    test('未 begin 直接 end 返回 false，并发起后状态已清空', () {
      final gate = PlayerDragPauseGate();
      expect(gate.end(), isFalse, reason: '没有进行中的拖动就没有"续播"可言');
      expect(gate.begin(playing: true), isTrue);
      expect(gate.end(), isTrue);
      expect(gate.end(), isFalse, reason: 'end 无条件清状态，第二次 end 无事可做');
    });
  });

  group('PlayerProgressSlider', () {
    testWidgets('拖动发 onSeekStart / onSeekEnd，onSeek 仍连续触发', (tester) async {
      final events = <String>[];
      var seeks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerProgressSlider(
              position: const Duration(seconds: 10),
              duration: const Duration(seconds: 100),
              buffered: const Duration(seconds: 40),
              onSeek: (_) => seeks++,
              onSeekStart: () => events.add('start'),
              onSeekEnd: () => events.add('end'),
            ),
          ),
        ),
      );

      await dragSlider(tester);

      expect(events, ['start', 'end'], reason: '一次拖动恰好一对 start/end');
      expect(seeks, greaterThan(1), reason: 'onSeek 仍是连续回调，不是只在松手时发');
    });

    testWidgets('直播时三个回调都不触发', (tester) async {
      final events = <String>[];
      var seeks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerProgressSlider(
              position: Duration.zero,
              duration: Duration.zero,
              buffered: Duration.zero,
              onSeek: (_) => seeks++,
              onSeekStart: () => events.add('start'),
              onSeekEnd: () => events.add('end'),
            ),
          ),
        ),
      );

      await dragSlider(tester);

      expect(events, isEmpty, reason: '直播没有可拖的值域，不许暂停/续播');
      expect(seeks, 0, reason: '直播路径的 seek 语义零变化');
    });

    testWidgets('单击轨道也算一次导航：start → end 各一次', (tester) async {
      final events = <String>[];
      var seeks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerProgressSlider(
              position: const Duration(seconds: 10),
              duration: const Duration(seconds: 100),
              buffered: const Duration(seconds: 40),
              onSeek: (_) => seeks++,
              onSeekStart: () => events.add('start'),
              onSeekEnd: () => events.add('end'),
            ),
          ),
        ),
      );

      // 无位移的按下/抬起：Flutter 的 Slider 会先安置拇指再结束交互。
      await tester.tapAt(
        tester.getCenter(find.byType(Slider)) - const Offset(60, 0),
      );
      await tester.pump();

      expect(
        events,
        ['start', 'end'],
        reason: '点一下进度条 = 一次导航，暂停随即恢复（既定语义，不是漏判）',
      );
      expect(seeks, greaterThan(0), reason: '点击确实 seek 了一次');
    });
  });

  group('PlayerOptions.dragPause', () {
    test('默认开启（关掉等于回到改造前的手感）', () {
      expect(const PlayerOptions().dragPause, isTrue);
      expect(const PlayerOptions.defaults().dragPause, isTrue);
      expect(const PlayerOptions(dragPause: false).dragPause, isFalse);
    });

    test('json 往返保留值', () {
      for (final value in const [true, false]) {
        final options = PlayerOptions(dragPause: value);
        final restored = PlayerOptions.fromJson(options.toJson());
        expect(restored.dragPause, value, reason: 'dragPause=$value 往返后必须不变');
      }
    });

    test('旧 settings.json 缺该键 → true', () {
      final old = <String, Object?>{
        'hardwareDecoding': true,
        'showThumbnailPreview': false,
      };
      expect(PlayerOptions.fromJson(old).dragPause, isTrue);
      expect(PlayerOptions.fromJson(null).dragPause, isTrue);
    });

    test('copyWith 与 normalized 都保留该值', () {
      const off = PlayerOptions(dragPause: false);
      expect(off.copyWith(cache: false).dragPause, isFalse, reason: '未传即沿用原值');
      expect(off.copyWith(dragPause: true).dragPause, isTrue);
      expect(const PlayerOptions(dragPause: false).normalized().dragPause, isFalse);
      expect(
        const PlayerOptions(dragPause: false) == const PlayerOptions(dragPause: true),
        isFalse,
        reason: '该字段必须参与相等判定，否则设置页与浮层看不到变化',
      );
    });
  });

  group('PlayerPage 接线', () {
    testWidgets('VOD 播放中拖动：拖动期间暂停，松手续播', (tester) async {
      final f = fixture();
      final mounted = await mountRecorder(
        tester,
        PlayerPage(state: f.state, request: f.session.request),
      );
      final io = mounted.io;
      // 引擎的播放状态要显式置一次：装载完成后的 playing 事件是异步落地的，
      // 直接在挂载返回时读会读到"还没开始播"。这里的 emitPlaying 就是引擎
      // 上报 playing=true 的那条流。
      io.emitPlaying();
      await flush(tester);
      expect(mounted.player.state.playing, isTrue, reason: '前置：VOD 在播');

      final gesture = await halfDrag(tester);
      expect(
        io.calls,
        ['pause'],
        reason: '拖动一开始就暂停；而且一格都没 seek——逐格 seek 会把画面按在 seeking=yes 上',
      );
      await gesture.up();
      await flush(tester);
      expect(
        io.calls,
        ['pause', 'seek', 'play'],
        reason: '松手只发一次 seek，再按拖动前的状态续播（顺序 seek → play）',
      );

      await unmount(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('拖动期间一格都不 seek，松手只落一次（seek → play）', (tester) async {
      final f = fixture();
      final io = (await mountRecorder(
        tester,
        PlayerPage(state: f.state, request: f.session.request),
      )).io;
      io.emitPlaying();
      await flush(tester);

      final beforeDrag = timeLabels(tester);

      // 多走几格：真实用例里用户会拖几十格，这正是"每格一次 seek"变成
      // 几十次串行排队的场景（单次 1–3 秒，画面长时间静止）。
      final gesture = await halfDrag(tester);
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(
        io.calls.where((call) => call == 'seek'),
        isEmpty,
        reason: '拖动期间一次引擎 seek 都不许发（根因就是这些 seek 排队）',
      );
      expect(
        io.calls,
        ['pause'],
        reason: '拖动期间页面只记目标：即时动作只有暂停',
      );

      final duringDrag = timeLabels(tester);
      expect(
        duringDrag,
        isNot(beforeDrag),
        reason: '拖动期间时间标签要跟着拇指走（读数来自拖动目标），不能冻在按下那一刻',
      );

      await gesture.up();
      await flush(tester);
      expect(
        io.calls.where((call) => call == 'seek').length,
        1,
        reason: '松手恰好一次 seek，不多不少',
      );
      expect(
        io.calls,
        ['pause', 'seek', 'play'],
        reason: '先 seek 再 play：先播再跳会闪回旧位置',
      );
      expect(
        timeLabels(tester),
        duringDrag,
        reason: '松手后读数回到引擎位置，而引擎正好被 seek 到拖动目标上',
      );

      await unmount(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('单击进度条：仍然恰好一次 seek（延后不许把导航吞掉）', (tester) async {
      final f = fixture();
      final io = (await mountRecorder(
        tester,
        PlayerPage(state: f.state, request: f.session.request),
      )).io;
      io.emitPlaying();
      await flush(tester);

      // 单击只走 start →（onChanged）→ end，没有一堆 moveTo：目标值必须
      // 在 onChanged 里就记下来，否则这次延后会变成"点了没反应"。
      // 页面上不止一根滑杆（音量也是 `Slider`），必须只打进度那根。
      final track = find.descendant(
        of: find.byType(PlayerProgressSlider),
        matching: find.byType(Slider),
      );
      await tester.tapAt(tester.getCenter(track) - const Offset(60, 0));
      await flush(tester);
      expect(
        io.calls.where((call) => call == 'seek').length,
        1,
        reason: '点一下进度条 = 一次导航，既不能丢也不能变成两次',
      );

      await unmount(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('VOD 拖动前已暂停：松手不续播', (tester) async {
      final f = fixture();
      final io = (await mountRecorder(
        tester,
        PlayerPage(state: f.state, request: f.session.request),
      )).io;
      io.emitPaused();
      await flush(tester);

      final gesture = await halfDrag(tester);
      expect(
        io.calls,
        isEmpty,
        reason: '本来就没在播，拖动不必再暂停，也还不该 seek',
      );
      await gesture.up();
      await flush(tester);
      expect(
        io.calls,
        ['seek'],
        reason: '松手 seek 一次；play() 等于替一个暂停着的用户点了播放',
      );

      await unmount(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('直播拖动：一个回调都不调（引擎报了非零时长也不调）', (tester) async {
      final f = fixture();
      final io = (await mountRecorder(
        tester,
        PlayerPage(
          state: f.state,
          request: f.session.request,
          liveSession: f.session,
        ),
      )).io;
      final slider = tester.widget<PlayerProgressSlider>(
        find.byType(PlayerProgressSlider),
      );
      // 引擎对直播流照样上报了时长，所以滑杆内部那份 `duration <= 0` 判据
      // 拦不住——只能靠页面的 `_isLive` 判据兜底。这条断言就是把那个
      // 场景钉死：不满足它就等于这条用例没测到任何东西。
      expect(
        slider.duration,
        greaterThan(Duration.zero),
        reason: '直播流报出了非零时长，滑杆侧判据失效',
      );
      // 回调**恒挂载**（见 player_page 里的注释）：判据在回调内部按
      // `_options.dragPause && !_isLive` 现算，所以直播时非 null 是设计，
      // 行为上必须一次都不调——下面这条断言才是判据本身。
      expect(slider.onSeekStart, isNotNull);
      expect(slider.onSeekEnd, isNotNull);

      final gesture = await halfDrag(tester);
      await gesture.up();
      await flush(tester);
      expect(io.calls, isEmpty, reason: '直播路径零行为变化：既不 pause 也不 play');

      await unmount(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('回看也同样享受拖动暂停（判据只排直播）', (tester) async {
      final f = fixture(
        initialProgram: const EpgProgram(
          title: '回看节目',
          startMs: 1700000000000,
          stopMs: 1700003600000,
        ),
      );
      final mounted = await mountRecorder(
        tester,
        PlayerPage(
          state: f.state,
          request: f.session.request,
          liveSession: f.session,
        ),
      );
      final io = mounted.io;
      io.emitPlaying();
      await flush(tester);
      expect(
        tester
            .widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider))
            .duration,
        greaterThan(Duration.zero),
        reason: '回看有时长、可自由 seek，与点播同语义',
      );

      final gesture = await halfDrag(tester);
      expect(io.calls, ['pause'], reason: '回看拖动也要先暂停，拖动期间同样不 seek');
      await gesture.up();
      await flush(tester);
      expect(
        io.calls,
        ['pause', 'seek', 'play'],
        reason: '松手一次 seek，再回到拖动前的状态',
      );

      await unmount(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('程序化 seek（快捷键）既不暂停也不续播', (tester) async {
      final f = fixture();
      final mounted = await mountRecorder(
        tester,
        PlayerPage(state: f.state, request: f.session.request),
      );
      final io = mounted.io;
      io.emitPlaying();
      await flush(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await flush(tester);
      expect(
        io.calls,
        ['seek'],
        reason: '只有用户拖滑杆才暂停；seekBy 走 _controller.seek（一次落地），不经过 gate',
      );

      await unmount(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('关掉开关：回调仍挂载，拖动不暂停也不续播', (tester) async {
      final f = fixture();
      final mounted = await mountRecorder(
        tester,
        PlayerPage(state: f.state, request: f.session.request),
      );
      final io = mounted.io;
      io.emitPlaying();
      await flush(tester);

      await toggleDragPause(tester);
      expect(f.state.playerOptions.dragPause, isFalse, reason: '前置：开关已关');

      final slider = tester.widget<PlayerProgressSlider>(
        find.byType(PlayerProgressSlider),
      );
      expect(slider.onSeekStart, isNotNull, reason: '恒挂载：判据在回调内部求值');
      expect(slider.onSeekEnd, isNotNull, reason: '恒挂载：任何一次拖动都有 end 走到');

      final gesture = await halfDrag(tester);
      expect(
        io.calls,
        isEmpty,
        reason: '关掉开关只关掉"暂停"，拖动中照样不 seek、不暂停',
      );
      await gesture.up();
      await flush(tester);
      expect(
        io.calls,
        ['seek'],
        reason: '松手恰好一次 seek——seek 频率与这个开关无关；且不 play',
      );

      await unmount(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('拖动中途关掉开关：这次不强行续播，下一次拖动照常暂停+续播', (tester) async {
      final f = fixture();
      final mounted = await mountRecorder(
        tester,
        PlayerPage(state: f.state, request: f.session.request),
      );
      final io = mounted.io;
      io.emitPlaying();
      await flush(tester);

      final gesture = await halfDrag(tester);
      expect(io.calls, ['pause'], reason: '拖动一开始暂停，拖动期间不 seek');
      // 还没松手就在菜单里把开关关掉：end 必须仍然走得到（回调恒挂载），
      // 并且不许拿"拖动前在播"的旧状态强行 play()。
      await toggleDragPause(tester);
      await gesture.up();
      await flush(tester);
      expect(
        io.calls,
        ['pause', 'seek'],
        reason: '这次拖动已经不算数（不许强行 play()），但用户选的位置仍要 seek 一次',
      );

      // 再开回来：如果上一次的 `_wasPlaying` 残留下来，这一次 begin() 会被
      // 判成重复 → 不再暂停（功能静默失效），松手却还会 play()。
      io.calls.clear();
      await toggleDragPause(tester);
      expect(f.state.playerOptions.dragPause, isTrue, reason: '前置：开关已重新打开');
      io.emitPlaying();
      await flush(tester);
      final second = await halfDrag(tester);
      expect(io.calls, ['pause'], reason: '下一次拖动必须仍然暂停（gate 没被残留状态废掉）');
      await second.up();
      await flush(tester);
      expect(
        io.calls,
        ['pause', 'seek', 'play'],
        reason: '并且松手 seek 一次后恢复播放——不是"不暂停却强行 play"',
      );

      await unmount(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
