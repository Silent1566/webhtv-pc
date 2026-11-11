// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/source_swap.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/danmaku_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/player_quality_panel.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/player_page_harness.dart';

const _qualities = [
  PlaybackQuality(name: '高清', url: 'https://raw.test/hd'),
  PlaybackQuality(name: '超清', url: 'https://raw.test/full'),
  PlaybackQuality(name: '蓝光', url: 'https://raw.test/blue'),
];

class _MediaIO extends PlatformPlayer {
  _MediaIO(this.original) : super(configuration: original.configuration) {
    stream = original.stream;
  }

  final PlatformPlayer original;
  final opened = <Media>[];
  final seeks = <Duration>[];
  Completer<void>? nextOpen;

  /// 让恢复进度这一步失败（`_load` 的 seek），验证错误可见性。
  bool throwOnSeek = false;
  Completer<void>? nextSeek;

  @override
  Future<int> get handle => original.handle;

  void progress(Duration position, {bool playing = true}) {
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
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(playable as Media);
    final pending = nextOpen;
    nextOpen = null;
    if (pending != null) await pending.future;
    progress(const Duration(seconds: 1), playing: play);
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    final gate = nextSeek;
    nextSeek = null;
    if (gate != null) await gate.future;
    if (throwOnSeek) throw StateError('seek failed');
    progress(position, playing: state.playing);
  }

  @override
  Future<void> play() async => progress(state.position);

  @override
  Future<void> pause() async => progress(state.position, playing: false);

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  @override
  Future<void> dispose() async {
    unawaited(original.dispose());
    await super.dispose();
  }
}

typedef _ResolveCall = ({
  String target,
  int? index,
  String? vodId,
  String? site,
  String? source,
});

class _ResolveState extends AppState {
  _ResolveState({required super.paths, required super.log});
  final calls = <_ResolveCall>[];
  final gates = <int, Completer<PlaybackDecision?>>{};

  /// 每次解析拿到的有效性守卫，按调用顺序保存。
  final guards = <bool Function()>[];

  /// 调用当刻守卫的返回值（此时本应仍有效＝true）。
  final guardAtCall = <bool>[];

  void _recordGuard(bool Function()? isCurrent) {
    if (isCurrent == null) return;
    guards.add(isCurrent);
    guardAtCall.add(isCurrent());
  }

  PlaybackDecision result(String target, int? index) {
    final quality = index ?? 0;
    return PlaybackDecision(
      action: PlaybackAction.direct,
      url: 'https://final.test/$target/$quality.m3u8',
      qualities: target == 'entry-2' ? _qualities.take(1).toList() : _qualities,
      qualityIndex: quality,
      headers: HeaderMap({'Referer': 'https://media.test/$target/$quality'}),
      upstreamHeaders: HeaderMap({
        'Referer': 'https://asset.test/$target/$quality',
      }),
      subs: [
        SubtitleInfo(
          url: 'https://asset.test/sub-$quality.srt',
          name: '字幕$quality',
          flag: 4,
        ),
      ],
      danmaku: [DanmakuSource(url: 'https://asset.test/danmaku-$quality.xml')],
    );
  }

  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    Site? siteOverride,
    SiteService? serviceOverride,
    int? qualityIndex,
    bool Function()? isCurrent,
  }) async {
    calls.add((
      target: episodeTarget,
      index: qualityIndex,
      vodId: vodId,
      site: siteOverride?.key,
      source: null,
    ));
    _recordGuard(isCurrent);
    return gates.remove(qualityIndex)?.future ??
        result(episodeTarget, qualityIndex);
  }

  @override
  Future<PlaybackDecision?> resolvePlaybackForSource({
    required String sourceKey,
    required String siteKey,
    required String episodeTarget,
    String? flag,
    String? vodId,
    int? qualityIndex,
    bool Function()? isCurrent,
  }) async {
    calls.add((
      target: episodeTarget,
      index: qualityIndex,
      vodId: vodId,
      site: siteKey,
      source: sourceKey,
    ));
    _recordGuard(isCurrent);
    return result(episodeTarget, qualityIndex);
  }
}

/// 记录播放器真正交给加载器的弹幕源与资源头（不发网络请求）。
class _FakeDanmaku implements DanmakuLoader {
  final requests = <({String url, Map<String, String> headers})>[];

  @override
  Future<DanmakuDocument> load(
    DanmakuSource source, {
    Map<String, String> headers = const {},
    bool useCache = true,
  }) async {
    requests.add((url: source.url, headers: Map<String, String>.of(headers)));
    return DanmakuDocument(
      items: const [],
      format: 'xml',
      encoding: 'utf-8',
      sourceUrl: source.url,
      byteLength: 0,
      skipped: 0,
    );
  }

  @override
  void invalidate([String? url]) {}
}

class _Fixture {
  _Fixture(this.state);
  final _ResolveState state;
  final media = <_MediaIO>[];
  _MediaIO get current => media.last;
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  int count = 3,
  Size size = const Size(1280, 720),
  String sourceKey = '',
  Map<String, SwapLineRoute> routes = const {},
  Duration startPosition = const Duration(seconds: 10),
  DanmakuLoader? danmakuLoader,
}) async {
  dismissAllToasts();
  final temp = Directory.systemTemp.createTempSync('webhtv-quality-ui');
  final state = _ResolveState(
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
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);
  final fixture = _Fixture(state);
  var active = true;
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active) return;
    final video = find.byType(Video);
    if (video.evaluate().isEmpty) return;
    final player = tester.widget<Video>(video).controller.player;
    if (player.platform is _MediaIO) return;
    final media = _MediaIO(player.platform!);
    fixture.media.add(media);
    player.platform = media;
  });
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(1, 1));
  addTearDown(() {
    if (identical(_mouse, mouse)) _mouse = null;
    mouse.removePointer();
  });
  _mouse = mouse;
  _hoverTick = 0;
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [child ?? const SizedBox.shrink(), const ToastHost()],
      ),
      home: PlayerPage(
        state: state,
        danmakuLoader: danmakuLoader ?? _FakeDanmaku(),
        request: PlaybackRequest(
          url: 'https://final.test/entry-1/0.m3u8',
          episodeTarget: 'entry-1',
          title: '测试剧',
          siteKey: 'fixture',
          vodId: 'vod-1',
          vodName: '测试剧',
          episodeName: '第1集',
          flag: '线路一',
          qualities: _qualities.take(count).toList(),
          danmaku: const [
            DanmakuSource(url: 'https://asset.test/danmaku-0.xml'),
          ],
          subtitleHeaders: const {'Referer': 'https://asset.test/entry-1/0'},
          startPosition: startPosition,
          sourceKey: sourceKey,
          lineRoutes: routes,
          playLines: [
            VodPlayLine(
              flag: '线路一',
              episodes: [
                VodEpisode(name: '第1集', url: 'entry-1'),
                VodEpisode(name: '第2集', url: 'entry-2'),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  await _settle(tester);
  expect(tester.takeException(), isNull);
  return fixture;
}

Future<void> _settle(WidgetTester tester) async {
  await settlePlayerPage(tester, times: 2);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

/// 每个用例只挂一个页面，因此鼠标指针在文件级复用。
///
/// 反复 `addPointer` 会踩框架 `MouseTracker` 的
/// `(event is PointerAddedEvent) == (lastEvent is PointerRemovedEvent)` 断言；
/// 同一位置也不会产生新的 hover 事件，所以每次交替两个落点。
TestGesture? _mouse;
int _hoverTick = 0;

Future<void> _hover(WidgetTester tester) async {
  final mouse = _mouse;
  if (mouse == null) return;
  _hoverTick++;
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  // 落点必须落在**画面**上：底部控制栏隐藏时仍会挡住该区域的悬停。
  final center = Offset(size.width / 2, size.height / 2);
  await mouse.moveTo(const Offset(1, 1));
  await mouse.moveTo(
    _hoverTick.isEven ? center : center + const Offset(24, 24),
  );
  await tester.pump();
  // 显隐是 AnimatedOpacity 过渡，等它走完再操作，否则命中的是动画层。
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _openQualityMenu(WidgetTester tester) async {
  // 控制栏 3 秒自动隐藏、显隐又是动画：用「结果验证 + 重试」代替一次 tap。
  final panel = find.byKey(playerQualityPanelKey);
  final button = find.byKey(const ValueKey('player-quality-button'));
  for (var attempt = 0; attempt < 6; attempt++) {
    if (panel.evaluate().isNotEmpty) return;
    // 先让上一轮显隐动画落定，再唤回控制栏。
    await tester.pump(const Duration(milliseconds: 400));
    await _hover(tester);
    if (button.evaluate().isEmpty) continue;
    await tester.tapAt(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _select(WidgetTester tester, int index) async {
  await _openQualityMenu(tester);
  final option = find.byKey(playerQualityOptionKey(index));
  expect(option, findsOneWidget, reason: '画质面板必须已经打开');
  await tester.tap(option);
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _openEpisodes(WidgetTester tester) async {
  final card = find.byKey(const ValueKey('player-episode-card-1'));
  final button = find.text('选集（2）');
  for (var attempt = 0; attempt < 6; attempt++) {
    if (card.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 400));
    await _hover(tester);
    if (button.evaluate().isEmpty) continue;
    await tester.tapAt(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 300));
  }
  expect(card, findsWidgets, reason: '选集面板必须已经打开');
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  // `toastCenter` 是全局单例：error 提示驻留 15 秒，会浮在右下角盖住控制栏
  // 按钮，把后面的用例全部点不中（实测跨用例串扰）。
  dismissAllToasts();
}

void main() {
  testWidgets('真实播放器多地址入口可读且当前项高亮、重复点击不重载', (tester) async {
    final f = await _mount(tester);
    expect(find.text('画质：高清'), findsOneWidget);

    await _openQualityMenu(tester);
    expect(find.byKey(playerQualityPanelKey), findsOneWidget);
    final current = tester.widget<ListTile>(
      find.byKey(playerQualityOptionKey(0)),
    );
    expect(current.selected, isTrue, reason: '当前项必须标为选定');
    expect(find.text('超清'), findsOneWidget);

    await tester.tap(find.byKey(playerQualityOptionKey(0)));
    await _settle(tester);
    expect(f.state.calls, isEmpty, reason: '重复点当前项不得重新解析');
    expect(f.current.opened.length, 1, reason: '重复点当前项不得重载媒体');
    await _close(tester);
  });

  for (final count in [0, 1]) {
    testWidgets('$count个地址隐藏画质入口', (tester) async {
      await _mount(tester, count: count);
      await _hover(tester);
      expect(find.byKey(const ValueKey('player-quality-button')), findsNothing);
      expect(find.textContaining('画质：'), findsNothing);
      await _close(tester);
    });
  }

  for (final playing in [false, true]) {
    testWidgets('切画质按索引解析、保留进度与playing=$playing，不回到旧历史', (tester) async {
      final f = await _mount(tester);
      f.current.progress(
        const Duration(milliseconds: 123456),
        playing: playing,
      );
      await tester.pump();

      await _select(tester, 1);
      await _settle(tester);

      expect(f.state.calls.single.target, 'entry-1', reason: '必须用入口目标重新解析');
      expect(f.state.calls.single.index, 1);
      expect(f.current.opened.last.uri, 'https://final.test/entry-1/1.m3u8');
      expect(f.current.opened.last.httpHeaders, {
        'Referer': 'https://media.test/entry-1/1',
      });
      expect(
        f.current.seeks,
        contains(const Duration(milliseconds: 123456)),
        reason: '切画质要停在当前进度，而不是请求里的旧续播位置',
      );
      expect(f.current.state.playing, playing);
      expect(find.text('画质：超清'), findsOneWidget);

      await _hover(tester);
      await tester.tap(find.byTooltip('字幕轨'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('字幕1'), findsWidgets, reason: '字幕要交接所选决策');
      await _close(tester);
    });
  }

  testWidgets('换集重新取候选并清空旧画质与旧进度', (tester) async {
    final f = await _mount(tester);
    await _select(tester, 1);
    await _settle(tester);

    await _openEpisodes(tester);
    await tester.tap(find.byKey(const ValueKey('player-episode-card-1')));
    await _settle(tester);

    expect(f.state.calls.last.target, 'entry-2');
    expect(f.state.calls.last.index, isNull, reason: '换集不得套用上一集的画质索引');
    expect(f.current.opened.last.uri, 'https://final.test/entry-2/0.m3u8');
    expect(find.byKey(const ValueKey('player-quality-button')), findsNothing);
    expect(f.current.state.position, const Duration(seconds: 1));
    await _close(tester);
  });

  testWidgets('快速切换画质时旧解析结果不能覆盖新选择', (tester) async {
    final f = await _mount(tester);
    final old = Completer<PlaybackDecision?>();
    f.state.gates[1] = old;
    await _select(tester, 1);
    await _select(tester, 2);
    await _settle(tester);
    old.complete(f.state.result('entry-1', 1));
    await _settle(tester);

    expect(f.current.opened.map((m) => m.uri), [
      'https://final.test/entry-1/0.m3u8',
      'https://final.test/entry-1/2.m3u8',
    ]);
    expect(find.text('画质：蓝光'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('画质解析未完成就换集：旧结果不得开媒体', (tester) async {
    final f = await _mount(tester);
    final old = Completer<PlaybackDecision?>();
    f.state.gates[1] = old;
    await _select(tester, 1);
    await _openEpisodes(tester);
    await tester.tap(find.byKey(const ValueKey('player-episode-card-1')));
    await _settle(tester);
    old.complete(f.state.result('entry-1', 1));
    await _settle(tester);

    expect(f.current.opened.last.uri, 'https://final.test/entry-2/0.m3u8');
    expect(f.current.opened.length, 2);
    await _close(tester);
  });

  testWidgets('原来源画质仍走自己的 sourceKey、站点与 vodId', (tester) async {
    final f = await _mount(tester, sourceKey: 'original-source');
    await _select(tester, 1);
    await _settle(tester);

    expect(f.state.calls.single.source, 'original-source');
    expect(f.state.calls.single.site, 'fixture');
    expect(f.state.calls.single.vodId, 'vod-1');
    expect(f.state.calls.single.index, 1);
    expect(f.state.guards, hasLength(1), reason: '原来源路线同样要透传状态守卫');
    expect(f.state.guardAtCall, [true]);
    await _close(tester);
  });

  testWidgets('外部并入线路切画质仍定向自己的vodId且不借用原来源', (tester) async {
    final f = await _mount(
      tester,
      routes: {
        '线路一': const SwapLineRoute(
          siteKey: 'route-site',
          siteName: '路由站点',
          vodId: 'route-vod',
        ),
      },
    );
    await _select(tester, 1);
    await _settle(tester);

    expect(
      f.state.calls.single.vodId,
      'route-vod',
      reason: '外部线路必须用它自己的 vodId',
    );
    expect(f.state.calls.single.source, isNull, reason: '外部线路属于当前配置，不走原来源');
    expect(f.state.calls.single.index, 1);
    await _close(tester);
  });

  testWidgets('画质解析把有效性守卫交给状态层：调用时有效，新选择/换集后立刻失效', (tester) async {
    final f = await _mount(tester);
    final first = Completer<PlaybackDecision?>();
    final second = Completer<PlaybackDecision?>();
    f.state.gates[1] = first;
    f.state.gates[2] = second;
    await _select(tester, 1);
    expect(f.state.guards.length, 1, reason: '状态层必须拿到 UI 的有效性守卫');
    expect(f.state.guardAtCall, [true], reason: '发起解析时这一代仍有效');

    final firstGuard = f.state.guards.first;
    expect(firstGuard(), isTrue, reason: '同一代内守卫保持有效');

    await _select(tester, 2);
    expect(
      firstGuard(),
      isFalse,
      reason: '新选择一开始，旧一次解析的守卫必须立刻为 false，状态层才不会先撤新 token',
    );
    expect(f.state.guardAtCall, [true, true]);

    final secondGuard = f.state.guards.last;
    await _openEpisodes(tester);
    await tester.tap(find.byKey(const ValueKey('player-episode-card-1')));
    await _settle(tester);
    expect(secondGuard(), isFalse, reason: '换集后上一集的画质解析守卫必须失效');
    first.complete(f.state.result('entry-1', 1));
    second.complete(f.state.result('entry-1', 2));
    await _settle(tester);
    await _close(tester);
  });

  testWidgets('新画质恢复进度失败要可见：提示与日志都留下，且不重开媒体', (tester) async {
    final f = await _mount(tester);
    f.current.progress(const Duration(milliseconds: 123456), playing: true);
    await tester.pump();
    f.current.throwOnSeek = true;

    final opensBefore = f.current.opened.length;
    await _select(tester, 1);
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      f.current.opened.length,
      opensBefore + 1,
      reason: '恢复失败发生在换地址之后，不该再重开一次媒体',
    );
    expect(
      f.state.log.entries.any((entry) => entry.line.contains('画质切换失败')),
      isTrue,
      reason: '当前新画质的恢复失败必须留下日志',
    );
    expect(
      find.textContaining('画质切换失败'),
      findsOneWidget,
      reason: '当前新画质的恢复失败必须提示用户，不能被静默吞掉',
    );
    await _close(tester);
  });

  testWidgets('过期的画质失败不报给新集', (tester) async {
    final f = await _mount(tester);
    final gate = Completer<PlaybackDecision?>();
    f.state.gates[1] = gate;

    await _select(tester, 1);
    // 解析还挂着时切到另一集：这一次画质选择已经过期。
    await _openEpisodes(tester);
    await tester.tap(find.byKey(const ValueKey('player-episode-card-1')));
    await _settle(tester);
    gate.completeError(AppError(AppErrorKind.siteNetwork, '解析已过期'));
    await _settle(tester);

    expect(
      f.state.log.entries.any((entry) => entry.line.contains('画质切换失败')),
      isFalse,
      reason: '过期失败属于上一集/上一次选择，不能记到新集上',
    );
    expect(find.textContaining('画质切换失败'), findsNothing);
    expect(f.current.opened.last.uri, 'https://final.test/entry-2/0.m3u8');
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('切画质把所选决策的弹幕源与资源头交给加载器（不发网络请求）', (tester) async {
    final loader = _FakeDanmaku();
    final f = await _mount(tester, danmakuLoader: loader);
    expect(
      loader.requests.map((r) => r.url),
      contains('https://asset.test/danmaku-0.xml'),
      reason: '首播用的是这一集决策里的弹幕源',
    );

    await _select(tester, 1);
    await _settle(tester);

    expect(
      loader.requests.last.url,
      'https://asset.test/danmaku-1.xml',
      reason: '所选画质决策里的弹幕源必须取代上一份弹幕源',
    );
    expect(
      loader.requests.last.headers['Referer'],
      'https://asset.test/entry-1/1',
      reason: '弹幕请求头必须来自所选决策的 assetHeaders，而不是旧决策',
    );
    expect(f.state.log.entries, isNotEmpty);
    await _close(tester);
  });

  testWidgets('窄窗口控制行与进入/退出全屏后画质选择都可达', (tester) async {
    await _mount(tester, size: const Size(600, 420));
    // 通用 mock 的 isFullScreen 恒为 false，无法证明真的切进/切出；
    // 这里模拟平台记录的实际状态，供 PlayerPage 回读并更新它自己的状态。
    var platformFullscreen = false;
    windowManagerCalls.clear();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowManagerChannel,
      (call) async {
        windowManagerCalls.add(call);
        switch (call.method) {
          case 'setFullScreen':
            platformFullscreen =
                (call.arguments as Map)['isFullScreen'] as bool;
            return null;
          case 'isFullScreen':
            return platformFullscreen;
          case 'isFocused':
            return true;
          case 'isPreventClose':
            return false;
          default:
            return null;
        }
      },
    );

    Future<void> expectPageFullscreen(bool fullscreen) async {
      // 菜单的全屏项由 PlayerPage 自己的 _fullscreen 决定，不能只检查 mock。
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.pump(const Duration(milliseconds: 250));
      final menu = tester.widget<PlayerContextMenu>(
        find.byType(PlayerContextMenu),
      );
      final item = menu.sections
          .expand((section) => section.items)
          .singleWhere((item) => item.id == 'fullscreen');
      expect(item.label, fullscreen ? '退出全屏' : '全屏');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 250));
    }

    await _select(tester, 1);
    await _settle(tester);
    expect(find.text('画质：超清'), findsOneWidget);
    await expectPageFullscreen(false);

    // 窄控制行是横向滚动的，F11 是既有且不依赖按钮屏内坐标的入口。
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await _settle(tester);
    expect(platformFullscreen, isTrue, reason: 'F11 必须确实发起进入全屏');
    expect(
      windowManagerCalls
          .where((call) => call.method == 'setFullScreen')
          .map((call) => (call.arguments as Map)['isFullScreen']),
      [true],
    );
    await expectPageFullscreen(true);
    await _select(tester, 2);
    await _settle(tester);
    expect(find.text('画质：蓝光'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await _settle(tester);
    expect(platformFullscreen, isFalse, reason: '第二次 F11 必须确实退出全屏');
    expect(
      windowManagerCalls
          .where((call) => call.method == 'setFullScreen')
          .map((call) => (call.arguments as Map)['isFullScreen']),
      [true, false],
    );
    await expectPageFullscreen(false);
    await _select(tester, 1);
    await _settle(tester);
    expect(find.text('画质：超清'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });
}
