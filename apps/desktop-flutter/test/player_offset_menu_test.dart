/// 迭代 3-B 的菜单用例：偏移菜单的四条行为，外加本地播放的「播放」组收尾。
///
/// 偏移那部分断言四件事：
/// 1. 字幕菜单里同时有「字幕延迟」「音轨延迟」两组，初值都是 0.0 秒；
/// 2. 点 +0.1s 后界面显示 +0.1 秒，且**落盘**（AppState.playerOptions）
///    已经是 100 ms —— 读的就是写进磁盘的那一份；
/// 3. 点「重置」回到 0；
/// 4. 顶到 ±60 s 边界后再点只给提示，值不变、不写盘。
///
/// 第三个用例锁的是同一个文件里的另一处改动：本地播放的「播放」组不再列
/// 上一集/下一集（player_menu_sections.dart）。放这里而不是另开文件，是因为
/// 两者要的是同一套播放器页装配；本轮的可改范围只有这一份测试文件。
///
/// 装配沿用 test/local_file_player_page_test.dart，它记录的两个坑一并照抄：
/// - **每次挂载换一个新的 ValueKey**：否则第二次 pumpWidget 会复用上一次的
///   PlayerPage element/State，新页面沿用旧页面的 PlayerController；
/// - **persistent frame callback 注册后不可撤销**：不判归属，先注册的回调会
///   抢先把新页面的解码器换掉并记进自己那份 fixture。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/player_tracks.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/danmaku_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/libmpv_guard.dart';
import 'support/player_page_harness.dart';

// ---------------------------------------------------------------------------
// 假内核：只报时长/位置，不碰磁盘与网络
// ---------------------------------------------------------------------------

/// 替换 Player.platform。
///
/// 不换的话 Player() 会用真内核去开 http://127.0.0.1:9/...，用例要么等连接
/// 超时、要么在没有 libmpv 的机器上直接抛异常。换掉之后 open 只回一份假进度，
/// 页面照常认为自己「在播」（时长非零是进度计时器与偏移写入的前置）。
class _FakeMedia extends PlatformPlayer {
  _FakeMedia(this.original) : super(configuration: original.configuration) {
    stream = original.stream;
  }

  final PlatformPlayer original;

  @override
  Future<int> get handle => original.handle;

  void report(Duration position, {bool playing = true}) {
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

  @override
  Future<void> open(Playable playable, {bool play = true}) async =>
      report(const Duration(seconds: 42), playing: play);

  @override
  Future<void> seek(Duration position) async =>
      report(position, playing: state.playing);

  @override
  Future<void> play() async => report(state.position);

  @override
  Future<void> pause() async => report(state.position, playing: false);

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> dispose() async {
    unawaited(original.dispose());
    await super.dispose();
  }
}

/// 不起任何网络请求的弹幕加载器（本用例的请求不带任何弹幕源）。
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

/// 挂载序号：每次挂载给 PlayerPage 一个新的 key（见文件头第一个坑）。
int _pageSeq = 0;

/// 当前由哪个挂载实例接管帧回调（见文件头第二个坑）。
int _frameOwner = 0;

/// 播放请求：偏移与「本地/站点」无关，这里只求页面能上。
///
/// url 指向不可达地址也无所谓——假内核不真的打开它。
const PlaybackRequest _request = PlaybackRequest(
  url: 'http://127.0.0.1:9/never.m3u8',
  title: '示例剧集',
  siteKey: 'fixture',
  vodId: 'demo-1',
  vodName: '示例剧集',
  episodeName: 'E3',
  flag: '线路一',
);

Future<void> _pumpPage(
  WidgetTester tester, {
  required Key pageKey,
  required AppState state,
  required PlaybackRequest request,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      // ToastHost 必须挂在 Navigator 之上：_showPlayerMessage 走全局 toast。
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [child ?? const SizedBox.shrink(), const ToastHost()],
      ),
      home: PlayerPage(
        key: pageKey,
        state: state,
        request: request,
        danmakuLoader: _NoDanmaku(),
      ),
    ),
  );
}

/// 推进假时间：**不用 pumpAndSettle**（加载态有常驻进度指示，
/// 且 PlayerController.open 挂着 180 秒加载超时）。
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 2; round++) {
    await settlePlayerPage(tester, times: 4);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

/// 收尾：销毁页面，把残留的一次性定时器与全局 toast 一起清掉。
Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(const Duration(milliseconds: 100));
  // toastCenter 是全局单例：error 提示驻留 30 秒，会浮在右下角盖住弹层按钮，
  // 把后面的用例全部点不中（实测跨用例串扰）。
  dismissAllToasts();
}

/// 挂一个播放器页，并让假内核接管解码器。
///
/// [seedOptions] 只在「边界」用例里用：把偏移直接写成落盘值，免得在界面上
/// 点 600 次才走到 ±60 s。
Future<_Fixture> _mountFixture(
  WidgetTester tester, {
  PlayerOptions? seedOptions,
  PlaybackRequest request = _request,
}) async {
  dismissAllToasts();
  final temp = Directory.systemTemp.createTempSync('webhtv-offset-menu');
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
  tester.view.physicalSize = const Size(1280, 720);
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
    player.platform = _FakeMedia(player.platform!);
  });

  await _pumpPage(
    tester,
    pageKey: fixture.pageKey,
    state: state,
    request: request,
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

// ---------------------------------------------------------------------------
// 偏移菜单的可观察面
// ---------------------------------------------------------------------------

/// 字幕菜单是一张底部弹层，入口是顶栏的「字幕轨」按钮。
Future<void> _openSubtitleMenu(WidgetTester tester) async {
  final page = tester.state<State<PlayerPage>>(find.byType(PlayerPage));
  debugRevealPlayerControls(page);
  await tester.pump();
  // 显隐是 AnimatedOpacity（AppMotion.fast），走完再点，否则命中的是动画层。
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byTooltip('字幕轨'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  expect(find.text('字幕延迟'), findsOneWidget, reason: '字幕菜单没有打开');
}

/// 偏移行（图标 + 「XX延迟」标题 + 当前值 + − / 重置 / +）。
///
/// find.ancestor 由近及远：标题 Text 的最近一个 Row 祖先就是这一行本身。
Finder _offsetRow(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Row)).first;

/// 这一行显示出来的当前值（+0.5 秒 / -0.3 秒 / 0.0 秒）。
String _offsetValue(WidgetTester tester, String label) {
  final values = tester
      .widgetList<Text>(
        find.descendant(of: _offsetRow(label), matching: find.byType(Text)),
      )
      .map((text) => text.data ?? '')
      .where((data) => data.endsWith('秒'))
      .toList();
  expect(values, hasLength(1), reason: '「$label」这一行应该有且只有一个「秒」值');
  return values.single;
}

/// 清掉浮在前面的提示。
///
/// 不是洁癖：假内核不是 NativePlayer，写内核那一步必然失败并弹一条 30 秒的
/// 错误提示，它悬在**右下角**，正好盖住弹层右侧的 + 按钮与「重置」——不清掉
/// 就点不到（实测：字幕那行能点，音轨那行点了没反应）。
Future<void> _clearToasts(WidgetTester tester) async {
  dismissAllToasts();
  await tester.pump();
}

/// 点这一行上的某个动作按钮（按钮的 tooltip 是唯一稳定锚点）。
Future<void> _tapOffsetButton(WidgetTester tester, String tooltip) async {
  await _clearToasts(tester);
  final target = find.byTooltip(tooltip);
  expect(target, findsOneWidget, reason: '弹层里找不到「$tooltip」');
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
  // _livePatchOptions 的落盘在真实 zone 里排队，给它一拍跑完。
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<void> _tapReset(WidgetTester tester, String label) async {
  await _clearToasts(tester);
  final target = find.descendant(
    of: _offsetRow(label),
    matching: find.text('重置'),
  );
  expect(target, findsOneWidget, reason: '「$label」这一行没有「重置」');
  await tester.tap(target);
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

// ---------------------------------------------------------------------------
// 本地播放的「播放」组（同一 library 里的另一处改动）
// ---------------------------------------------------------------------------

/// 右键打开上下文菜单：手法与 test/phase8_context_menu_content_test.dart 一致。
Future<void> _openContextMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
  await settlePlayerPage(tester);
  expect(find.byType(PlayerContextMenu), findsOneWidget, reason: '右键没能打开菜单');
}

/// 点分组行让它飞出第 2 列（同前一份文件：先 ensureVisible 再点）。
Future<void> _drill(WidgetTester tester, String label) async {
  final target = find.descendant(
    of: find.byType(PlayerContextMenu),
    matching: find.text(label),
  );
  expect(target, findsWidgets, reason: '菜单里找不到「$label」');
  await tester.ensureVisible(target.first);
  await settlePlayerPage(tester, times: 2);
  await tester.tap(target.first);
  await settlePlayerPage(tester, times: 3);
}

void main() {
  group('偏移菜单', () {
    testWidgets(
      '两组偏移：±0.1 步进即时可见且落盘，重置回到 0',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        final fixture = await _mountFixture(tester);

        // 「±0.0 秒」在界面上是「0.0 秒」：零按设计不带符号
        // （formatTrackOffsetSeconds，player_tracks.dart:545-551：
        // 「写 +0.0 秒 会让人以为偏了一点点」）。
        expect(formatTrackOffsetSeconds(0), '0.0 秒');
        expect(fixture.state.playerOptions.subtitleOffsetMs, 0);
        expect(fixture.state.playerOptions.audioOffsetMs, 0);

        await _openSubtitleMenu(tester);

        expect(find.text('音轨延迟'), findsOneWidget);
        expect(_offsetValue(tester, '字幕延迟'), '0.0 秒');
        expect(_offsetValue(tester, '音轨延迟'), '0.0 秒');

        await _tapOffsetButton(tester, '字幕延迟 +0.1 秒');
        expect(_offsetValue(tester, '字幕延迟'), '+0.1 秒');
        expect(
          fixture.state.playerOptions.subtitleOffsetMs,
          100,
          reason: '一步 = 100 ms，必须落在 state（落盘的那一份）上，不能只是界面数字',
        );
        expect(
          fixture.state.playerOptions.audioOffsetMs,
          0,
          reason: '两类偏移互不干扰',
        );

        await _tapOffsetButton(tester, '音轨延迟 +0.1 秒');
        expect(_offsetValue(tester, '音轨延迟'), '+0.1 秒');
        expect(fixture.state.playerOptions.audioOffsetMs, 100);
        expect(fixture.state.playerOptions.subtitleOffsetMs, 100);

        await _tapReset(tester, '字幕延迟');
        expect(_offsetValue(tester, '字幕延迟'), '0.0 秒');
        expect(fixture.state.playerOptions.subtitleOffsetMs, 0);
        expect(
          fixture.state.playerOptions.audioOffsetMs,
          100,
          reason: '重置只作用于被点的那一类',
        );

        await _tapReset(tester, '音轨延迟');
        expect(_offsetValue(tester, '音轨延迟'), '0.0 秒');
        expect(fixture.state.playerOptions.audioOffsetMs, 0);

        await _closePage(tester);
      },
    );

    testWidgets(
      '±60 秒边界：再点一步只给提示，值不变也不写盘',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        // 起点直接写成落盘值：界面上点 600 次才到边界，没有必要。
        final fixture = await _mountFixture(
          tester,
          seedOptions: const PlayerOptions.defaults().copyWith(
            subtitleOffsetMs: TrackOffset.maxMilliseconds,
            audioOffsetMs: -TrackOffset.maxMilliseconds,
          ),
        );

        await _openSubtitleMenu(tester);
        expect(_offsetValue(tester, '字幕延迟'), '+60.0 秒');
        expect(_offsetValue(tester, '音轨延迟'), '-60.0 秒');

        await _tapOffsetButton(tester, '字幕延迟 +0.1 秒');
        expect(
          _offsetValue(tester, '字幕延迟'),
          '+60.0 秒',
          reason: '顶到上限后不得越界（界面上看到的就是夹取后的值）',
        );
        expect(
          fixture.state.playerOptions.subtitleOffsetMs,
          TrackOffset.maxMilliseconds,
          reason: '越界的那一步不得写盘',
        );
        expect(
          toastCenter.toasts.map((toast) => toast.message),
          contains('字幕延迟已到 +60.0 秒，无法再调整'),
          reason: '只给提示：点了没反应会让人以为是按钮坏了',
        );

        await _tapOffsetButton(tester, '音轨延迟 -0.1 秒');
        expect(_offsetValue(tester, '音轨延迟'), '-60.0 秒');
        expect(
          fixture.state.playerOptions.audioOffsetMs,
          -TrackOffset.maxMilliseconds,
        );
        // 到哪一端就报哪一端：曾经两侧都印「+60.0 秒 上限」
        // （下界提示上界值），已修成按当前值符号取边界。
        expect(
          toastCenter.toasts.map((toast) => toast.message),
          contains('音轨延迟已到 -60.0 秒，无法再调整'),
        );

        // 反向仍可离开边界：提示不是「锁死」，±60 s 之外才是禁区。
        await _tapOffsetButton(tester, '字幕延迟 -0.1 秒');
        expect(_offsetValue(tester, '字幕延迟'), '+59.9 秒');
        expect(fixture.state.playerOptions.subtitleOffsetMs, 59900);

        await _closePage(tester);
      },
    );

    testWidgets(
      '本地播放的「播放」组不列上一集/下一集（对照：站点请求仍在）',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        // 生产里的本地请求是 PlaybackRequest.localFile：没有 playLines，
        // 于是 _playPrevious/_playNext 的选集分支恒为空——两个按钮点了没反应。
        final dir = Directory.systemTemp.createTempSync('webhtv-local-media');
        addTearDown(() {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        });
        final media = File('${dir.path}/本地片.mkv')..createSync();
        await _mountFixture(
          tester,
          request: PlaybackRequest.localFile(path: media.path),
        );

        await _openContextMenu(tester);
        await _drill(tester, '播放');
        // 前提：这一组真的飞出来了。没有这一条，「找不到上一集」也可能只是
        // 分组没展开——那是假绿。
        expect(find.text('后退 10 秒'), findsOneWidget, reason: '「播放」组没有飞出第 2 列');
        expect(
          find.text('上一集'),
          findsNothing,
          reason: '本地没有集可换，留着就是死按钮',
        );
        expect(find.text('下一集'), findsNothing);

        // 控制栏同口径：本地不渲染这两个图标。
        // 若只摘按钮不摘分组，PlayerOverlayActionRow 的「按钮与分组一一对应」
        // 断言会当场炸（接线时踩过）。
        expect(find.byIcon(Icons.skip_previous), findsNothing);
        expect(find.byIcon(Icons.skip_next), findsNothing);

        await _closePage(tester);

        // 对照：只有「是不是本地」这一点不同的站点请求，两项都在。
        await _mountFixture(tester);
        await _openContextMenu(tester);
        await _drill(tester, '播放');
        expect(find.text('上一集'), findsOneWidget);
        expect(find.text('下一集'), findsOneWidget);

        await _closePage(tester);
      },
    );
  });
}
