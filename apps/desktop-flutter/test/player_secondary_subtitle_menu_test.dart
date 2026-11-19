/// 次字幕菜单（迭代 3-D）：入口开关、候选剔除、选中态与落盘。
///
/// 锁四件事：
/// 1. 「次字幕」分组只在引擎报了 **≥2 条真实字幕轨**时出现——0 条、1 条都整组
///    不出现（单轨时主字幕占掉唯一那条，候选为空，做出来就是个死入口）；
/// 2. 候选剔除主字幕那条（`buildSecondarySubtitleOptions(excludeId:)`），
///    选中态读落盘值 `_options.secondarySubtitleId`；
/// 3. 点选后落盘（`AppState.playerOptions` 就是写盘的那一份）并尝试写内核；
///    假内核写不了也只提示不抛（不是 NativePlayer → 控制器返回 false）；
/// 4. 主字幕切到次字幕那条轨时，core 把组合回落到「关闭」，重开菜单的选中态
///    随之刷新——不写回落盘的话界面会一直显示「次字幕开着」。
///
/// 为什么必须 pump 真实的 `PlayerPage`：`_showSubtitleMenu` 是 `part` 里的页面
/// 扩展，观察面是底部弹层的**菜单树**与播放器页的落盘值；纯逻辑用例只能证明
/// core 的函数返回值，证明不了菜单把它们接在了哪一项上。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/danmaku_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/libmpv_guard.dart';
import 'support/player_page_harness.dart';

// ---------------------------------------------------------------------------
// 假内核：报时长/位置/轨道，不碰磁盘与网络
// ---------------------------------------------------------------------------

/// 替换 `Player.platform`（手法沿用 test/player_offset_menu_test.dart）。
///
/// 两个关键点：
/// - `stream` 必须复用原平台的：`Player.stream` 直接返回
///   `platform.stream`，换一个空的流之后控制器一个事件都收不到；
/// - `state` 由本对象自己维护：`Player.state` 也直接返回 `platform.state`，
///   主字幕的同轨回落读的就是这里。
class _FakeMedia extends PlatformPlayer {
  _FakeMedia(this.original) : super(configuration: original.configuration) {
    stream = original.stream;
  }

  final PlatformPlayer original;

  @override
  Future<int> get handle => original.handle;

  void _report(Duration position, {bool playing = true}) {
    state = state.copyWith(
      position: position,
      duration: const Duration(seconds: 1000),
      playing: playing,
      completed: false,
    );
    original.durationController.add(state.duration);
    original.positionController.add(position);
    original.playingController.add(playing);
    original.completedController.add(false);
  }

  /// 引擎上报字幕轨表（`stream.tracks`）：控制器据此算菜单候选。
  void reportSubtitleTracks(List<SubtitleTrack> subtitle) {
    final tracks = Tracks(subtitle: subtitle);
    state = state.copyWith(tracks: tracks);
    original.tracksController.add(tracks);
  }

  /// 引擎上报「此刻的轨道」（`stream.track`）：控制器据此更新主字幕选中态，
  /// `selectSecondarySubtitle` 的同轨回落也拿它比对。
  void reportCurrentTrack(Track track) {
    state = state.copyWith(track: track);
    original.trackController.add(track);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async =>
      _report(const Duration(seconds: 42), playing: play);

  @override
  Future<void> seek(Duration position) async =>
      _report(position, playing: state.playing);

  @override
  Future<void> play() async => _report(state.position);

  @override
  Future<void> pause() async => _report(state.position, playing: false);

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    // 主字幕切换在这个假内核上「成功并回报」：菜单选中态与同轨回落都靠回报。
    reportCurrentTrack(state.track.copyWith(subtitle: track));
  }

  @override
  Future<void> dispose() async {
    unawaited(original.dispose());
    await super.dispose();
  }
}

/// 不起任何网络请求的弹幕加载器（本用例的请求不带弹幕源）。
class _NoDanmaku implements DanmakuLoader {
  @override
  Future<DanmakuDocument> load(
    DanmakuSource source, {
    Map<String, String> headers = const {},
    bool useCache = true,
  }) async => DanmakuDocument(
    items: const [],
    format: 'xml',
    encoding: 'utf-8',
    sourceUrl: source.url,
    byteLength: 0,
    skipped: 0,
  );

  @override
  void invalidate([String? url]) {}
}

// ---------------------------------------------------------------------------
// 装配
// ---------------------------------------------------------------------------

class _Fixture {
  _Fixture(this.state, this.pageKey);
  final AppState state;
  final Key pageKey;
}

/// 挂载序号：每次挂载给 PlayerPage 新的 key（同 test/player_offset_menu_test.dart）。
int _pageSeq = 0;

/// 当前由哪个挂载实例接管帧回调（persistent 回调注册后不可撤销）。
int _frameOwner = 0;

/// 最后一次装上假内核的那个实例：用例靠它上报轨道。
_FakeMedia? _kernel;

const PlaybackRequest _request = PlaybackRequest(
  url: 'http://127.0.0.1:9/never.m3u8',
  title: '示例剧集',
  siteKey: 'fixture',
  vodId: 'demo-1',
  vodName: '示例剧集',
  episodeName: 'E3',
  flag: '线路一',
);

Future<void> _settle(WidgetTester tester) async {
  // 不用 pumpAndSettle：加载态有常驻进度指示，且有 180 秒加载超时定时器。
  for (var round = 0; round < 2; round++) {
    await settlePlayerPage(tester, times: 4);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(const Duration(milliseconds: 100));
  // toastCenter 是全局单例：error 提示驻留 30 秒，会盖住弹层右侧按钮。
  dismissAllToasts();
}

Future<_Fixture> _mountFixture(
  WidgetTester tester, {
  PlayerOptions? seedOptions,
}) async {
  dismissAllToasts();
  final temp = Directory.systemTemp.createTempSync('webhtv-secondary-menu');
  final state = AppState(
    paths: AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    ),
    log: LogService(),
  );
  addTearDown(() {
    state.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });
  await tester.runAsync(state.bootstrap);
  if (seedOptions != null) {
    await tester.runAsync(() => state.setPlayerOptions(seedOptions));
  }
  // 比播放器页的常规用例高：底部弹层的上限是屏高的 9/16，菜单里多了「次字幕」
  // 一组之后 720 高会被压到内部滚动，列表下方（偏移那两行、甚至次字幕的后半）
  // 根本不会被 build —— 断言会写成「找不到」，而不是「没有」。
  tester.view.physicalSize = const Size(1280, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);

  final owner = ++_frameOwner;
  final fixture = _Fixture(state, ValueKey('player-page-${++_pageSeq}'));
  var active = true;
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || owner != _frameOwner) return;
    final video = find.byType(Video);
    if (video.evaluate().isEmpty) return;
    final player = tester.widget<Video>(video).controller.player;
    if (player.platform is _FakeMedia) return;
    final fake = _FakeMedia(player.platform!);
    player.platform = fake;
    _kernel = fake;
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      // ToastHost 必须挂在 Navigator 之上：_showPlayerMessage 走全局 toast。
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [child ?? const SizedBox.shrink(), const ToastHost()],
      ),
      home: PlayerPage(
        key: fixture.pageKey,
        state: state,
        request: _request,
        danmakuLoader: _NoDanmaku(),
      ),
    ),
  );
  await _settle(tester);
  expect(tester.takeException(), isNull);
  expect(
    tester.widget<Video>(find.byType(Video)).controller.player.platform,
    isA<_FakeMedia>(),
    reason: '假内核没有接管解码器：时长恒为 0，起播链路会一直停在加载态',
  );
  return fixture;
}

/// 上报字幕轨表与当前主字幕，并让控制器跑完两条流。
Future<void> _reportTracks(
  WidgetTester tester, {
  required List<SubtitleTrack> subtitle,
  SubtitleTrack? current,
}) async {
  final kernel = _kernel;
  expect(kernel, isNotNull, reason: '假内核没有装上');
  kernel!.reportSubtitleTracks(subtitle);
  if (current != null) kernel.reportCurrentTrack(Track(subtitle: current));
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

// ---------------------------------------------------------------------------
// 弹层的可观察面
// ---------------------------------------------------------------------------

/// 字幕菜单是底部弹层，入口是顶栏的「字幕轨」按钮（同偏移菜单用例）。
Future<void> _openSubtitleMenu(WidgetTester tester) async {
  final page = tester.state<State<PlayerPage>>(find.byType(PlayerPage));
  debugRevealPlayerControls(page);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byTooltip('字幕轨'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  // 以第一行当锚点：字幕菜单永远有「关闭字幕」这条（subtitleMenu 固定追加），
  // 而偏移那两行在列表底部，屏高不够时压根不会被 build。
  expect(find.text('关闭字幕'), findsOneWidget, reason: '字幕菜单没有打开');
}

/// 弹层里某一行是否打勾。
bool _checked(WidgetTester tester, String label) {
  final tile = find.ancestor(
    of: find.text(label),
    matching: find.byType(ListTile),
  );
  expect(tile, findsOneWidget, reason: '弹层里找不到「$label」这一行');
  return tester
      .widgetList(find.descendant(of: tile, matching: find.byIcon(Icons.check)))
      .isNotEmpty;
}

/// 点弹层里的一行（先滚到可见处：弹层比窗口高时会内部滚动）。
Future<void> _tapRow(WidgetTester tester, String label) async {
  final target = find.text(label);
  expect(target, findsOneWidget, reason: '弹层里找不到「$label」');
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

// 两条轨的固定装配：title + language 让「主字幕列表」与「次字幕候选」的
// label 天然不同（前者 `简体（zh）`，后者 `简体 · zh`），不会互相干扰断言。
const SubtitleTrack _trackZh = SubtitleTrack('1', '简体', 'zh');
const SubtitleTrack _trackEn = SubtitleTrack('2', 'English', 'en');

void main() {
  group('次字幕菜单', () {
    testWidgets(
      '无字幕轨：菜单照开，但不给次字幕分组',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        await _mountFixture(tester);
        await _openSubtitleMenu(tester);

        expect(
          find.text('关闭字幕'),
          findsOneWidget,
          reason: '前提：这一集确实一条内嵌字幕轨都没有（只剩「关闭字幕」一行）',
        );
        expect(
          find.text('次字幕'),
          findsNothing,
          reason: '0 条字幕轨时次字幕没有可选项，整组不该出现',
        );

        await _closePage(tester);
      },
    );

    testWidgets(
      '只有一条字幕轨：不给次字幕分组（不做点了没东西的死入口）',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        await _mountFixture(tester);
        await _reportTracks(tester, subtitle: [_trackZh], current: _trackZh);
        await _openSubtitleMenu(tester);

        expect(
          find.text('简体（zh）'),
          findsOneWidget,
          reason: '前提：主字幕列表读到了引擎上报的那一条',
        );
        expect(
          find.text('次字幕'),
          findsNothing,
          reason: '单轨时主字幕占掉唯一那条，次字幕候选为空——入口不能做出来',
        );

        await _closePage(tester);
      },
    );

    testWidgets(
      '两条字幕轨：出现次字幕分组，剔除主字幕那条，点选后落盘且不抛',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        final fixture = await _mountFixture(tester);
        await _reportTracks(
          tester,
          subtitle: [_trackZh, _trackEn],
          current: _trackZh,
        );
        expect(fixture.state.playerOptions.secondarySubtitleId, 'no');

        await _openSubtitleMenu(tester);
        expect(find.text('次字幕'), findsOneWidget, reason: '≥2 条真实轨才给入口');
        expect(
          find.text('简体 · zh'),
          findsNothing,
          reason: '主字幕（简体）那条必须从次字幕候选里剔除：同一条轨当主+次只会叠两遍',
        );
        expect(find.text('English · en'), findsOneWidget);
        expect(_checked(tester, '关闭'), isTrue, reason: '默认关闭');
        expect(_checked(tester, 'English · en'), isFalse);

        await _tapRow(tester, 'English · en');

        expect(
          fixture.state.playerOptions.secondarySubtitleId,
          '2',
          reason: '落盘值必须是引擎轨道号（写 mpv secondary-sid 的就是它），不是菜单 id',
        );
        expect(
          find.textContaining('次字幕未生效'),
          findsOneWidget,
          reason: '假内核不是 NativePlayer：写不进去只能提示，不能抛',
        );
        expect(tester.takeException(), isNull);

        // 重开菜单：选中态读的是落盘值，不靠上一次弹层的残影。
        dismissAllToasts();
        await tester.pump();
        await _openSubtitleMenu(tester);
        expect(_checked(tester, 'English · en'), isTrue);
        expect(_checked(tester, '关闭'), isFalse);

        await _closePage(tester);
      },
    );

    testWidgets(
      '主字幕切到次字幕那条轨：次字幕回落关闭，重开菜单选中态同步',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        final fixture = await _mountFixture(
          tester,
          // 起点直接写成落盘值：主='1'、次='2'，正是双字幕的常规组合。
          seedOptions: const PlayerOptions().copyWith(
            secondarySubtitleId: '2',
          ),
        );
        await _reportTracks(
          tester,
          subtitle: [_trackZh, _trackEn],
          current: _trackZh,
        );

        await _openSubtitleMenu(tester);
        expect(_checked(tester, 'English · en'), isTrue, reason: '次字幕=2 已在落盘里');

        // 把**主**字幕换成同一条轨：主+次同轨只会在画面上把同一行字叠两遍。
        await _tapRow(tester, 'English（en）');

        expect(
          fixture.state.playerOptions.secondarySubtitleId,
          'no',
          reason: 'core 的同轨回落必须落到落盘值上，否则界面一直显示次字幕开着',
        );

        await _openSubtitleMenu(tester);
        expect(_checked(tester, '关闭'), isTrue, reason: '菜单选中态要跟着回落刷新');
        expect(
          find.text('English · en'),
          findsNothing,
          reason: '主字幕已经是这条了，它不该再出现在次字幕候选里',
        );
        expect(find.text('简体 · zh'), findsOneWidget);

        await _closePage(tester);
      },
    );
  });
}
