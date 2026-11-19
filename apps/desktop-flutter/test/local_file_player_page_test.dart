/// 本地文件播放（迭代 2 Wave 2）：**播放器页**上的 4 条行为用例。
///
/// 请求对象自身的语义由 local_file_playback_test.dart 锁定，这里只锁页面行为：
/// 1. 本地播放不写播放历史；
/// 2. 本地播放不问站点要解析结果（切集/切线路入口不渲染、playback 决策不调用）；
/// 3. 画质按钮 / 选集按钮 / 解析源条三件套在本地不渲染；
/// 4. 音频 AI 在本地只弹提示、不建面板。
///
/// **每条都带一组对照**（同样的流程换成远程请求）：只断言「没有出现」时，
/// 一个「什么都没渲染、什么都没调用」的实现也能通过；对照负责排除这种假绿。
///
/// 装配方式沿用 test/player_quality_ui_test.dart：
/// - media_kit_video / window_manager 平台通道 mock（见 support/player_page_harness.dart）；
/// - 用 addPersistentFrameCallback 把 Player.platform 换成假内核，由假内核报出
///   时长/位置——没有时长 _progressReady 恒为 false，第 1 条就会变成
///   「计时器根本没跑」的假绿。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/danmaku_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_integration_widgets.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/libmpv_guard.dart';
import 'support/player_page_harness.dart';

// ---------------------------------------------------------------------------
// 可观察面
// ---------------------------------------------------------------------------

/// 画质按钮（player_page.dart:5183）。
const Key _qualityButtonKey = ValueKey('player-quality-button');

/// 解析源条（player_parse_source_strip.dart:46）。
const Key _parseStripKey = ValueKey('player-parse-source-strip');

/// 第 2 个解析源 chip（同上，player-parse-source-INDEX）。
const Key _parseChip1Key = ValueKey('player-parse-source-1');

/// 音频 AI 入口（player_page.dart:4917）。
const Key _audioAiButtonKey = ValueKey('player-audio-ai');

/// 解析源名称（第 1 项是合成的「超级解析」）。
const List<String> _parseSources = ['超级解析', '解析B'];

const List<PlaybackQuality> _qualities = [
  PlaybackQuality(name: '高清', url: 'https://raw.test/hd'),
  PlaybackQuality(name: '超清', url: 'https://raw.test/full'),
];

// ---------------------------------------------------------------------------
// 假内核：只报时长/位置，不碰磁盘与网络
// ---------------------------------------------------------------------------

/// 替换 Player.platform。
///
/// Player.state 就是 platform!.state（media_kit-1.2.6/lib/src/player/player.dart:128），
/// 所以这里的 state 直接决定 PlayerController.duration——这是
/// _persistProgress（player_page.dart:3184）除 isLocal 之外唯一会提前 return 的可变量。
class _FakeMedia extends PlatformPlayer {
  _FakeMedia(this.original) : super(configuration: original.configuration) {
    stream = original.stream;
  }

  final PlatformPlayer original;
  final opened = <Media>[];

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
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(playable as Media);
    report(const Duration(seconds: 42), playing: play);
  }

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

/// 不起任何网络请求的弹幕加载器。
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

/// 记账版 AppState：把「写历史」与「问站点解析」变成可断言的调用流水。
///
/// 不调 super 实现：本文件的断言对象是**调用有没有发生**，
/// 落库细节由既有存储类套件负责。
class _RecordingState extends AppState {
  _RecordingState({required super.paths, required super.log});

  final progressWrites = <({String vodId, String target, int positionMs})>[];
  final resolveCalls = <({String target, String? flag, String? vodId})>[];
  final sourceResolveCalls =
      <({String sourceKey, String siteKey, String target})>[];

  @override
  void recordProgress({
    required Vod vod,
    required String flag,
    required String episodeName,
    required String episodeId,
    required Duration position,
    required Duration duration,
    String? siteKey,
    String? sourceKey,
    int tmdbId = 0,
    String mediaType = '',
  }) {
    progressWrites.add((
      vodId: vod.vodId,
      target: episodeId,
      positionMs: position.inMilliseconds,
    ));
  }

  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    int? qualityIndex,
    bool Function()? isCurrent,
    Site? siteOverride,
    String? preferredParseName,
    SiteService? serviceOverride,
  }) async {
    resolveCalls.add((target: episodeTarget, flag: flag, vodId: vodId));
    return _decision(episodeTarget, qualityIndex);
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
    String? preferredParseName,
  }) async {
    sourceResolveCalls.add((
      sourceKey: sourceKey,
      siteKey: siteKey,
      target: episodeTarget,
    ));
    return _decision(episodeTarget, qualityIndex);
  }

  PlaybackDecision _decision(String target, int? qualityIndex) =>
      PlaybackDecision(
        action: PlaybackAction.direct,
        url: 'https://final.test/$target.m3u8',
        qualities: _qualities,
        qualityIndex: qualityIndex ?? 0,
        parseSources: _parseSources,
        parseSource: _parseSources.first,
      );
}

// ---------------------------------------------------------------------------
// 请求样本
// ---------------------------------------------------------------------------

/// 本地请求，但**三件套需要的字段全都给足**。
///
/// 只给 localFile(path:) 是不够的：那样 qualities / playLines / parseSources
/// 本来就为空，三件套「不渲染」便可能只是因为字段为空，而不是因为「本地」。
/// 这里让字段与远程对照组逐项对齐，剩下的差异只有「是不是本地」。
PlaybackRequest _localRequest(String path) =>
    PlaybackRequest.localFile(path: path).copyWith(
      qualities: _qualities,
      playLines: [_localLine(path)],
      parseSources: _parseSources,
      parseSource: _parseSources.first,
    );

VodPlayLine _localLine(String path) => VodPlayLine(
  flag: PlaybackRequest.localSourceFlag,
  episodes: [
    VodEpisode(name: '本地片.mkv', url: path),
    VodEpisode(name: '第二部.mkv', url: path),
  ],
);

/// 本地请求的远程孪生：字段与 _localRequest 逐项一致，只有播放种类不同。
PlaybackRequest _remoteRequest({String target = 'entry-1'}) => PlaybackRequest(
  url: 'https://final.test/$target.m3u8',
  episodeTarget: target,
  title: '测试剧',
  siteKey: 'fixture',
  vodId: 'vod-1',
  vodName: '测试剧',
  episodeName: '第1集',
  flag: '线路一',
  qualities: _qualities,
  parseSources: _parseSources,
  parseSource: _parseSources.first,
  playLines: [
    VodPlayLine(
      flag: '线路一',
      episodes: [
        VodEpisode(name: '第1集', url: 'entry-1'),
        VodEpisode(name: '第2集', url: 'entry-2'),
      ],
    ),
  ],
);

// ---------------------------------------------------------------------------
// 装配
// ---------------------------------------------------------------------------

class _Fixture {
  _Fixture(this.state, this.media, this.pageKey);
  final _RecordingState state;
  final List<_FakeMedia> media;

  /// 本次挂载的页面 key，见 [_pageSeq]。
  final Key pageKey;
}

/// 挂载序号：每次挂载给 PlayerPage 一个新的 key。
///
/// 没有它，第二次 pumpWidget 会**复用**上一次的 PlayerPage element/State
/// （widget 类型与位置相同），于是新页面沿用旧页面的 PlayerController
/// 与 Player——对照组看到的是本地那一轮的解码器，断言对象就串了。
int _pageSeq = 0;

/// 当前由哪个挂载实例接管帧回调。
///
/// persistent frame callback 注册后**不会被撤销**：不判归属，先注册的回调
/// 会抢先把新页面的解码器换掉并记进自己那份 fixture。
int _frameOwner = 0;

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
/// 且 PlayerController.open 挂了 180 秒加载超时，见脚手架文件头注释）。
Future<void> _settle(WidgetTester tester) async {
  // 两轮：一轮给假时钟推进浮层/计时器，一轮把真实 zone 里的解码器初始化跑完。
  for (var round = 0; round < 2; round++) {
    await settlePlayerPage(tester, times: 4);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
}

/// 收尾：销毁页面并把残留的一次性定时器跑完。
///
/// 不显式销毁时，起播链路（加载超时、进度计时器）会留着仍在排队的
/// 零延时 Timer，用例结束时被判成「A Timer is still pending」。
Future<void> _closePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump(const Duration(milliseconds: 100));
}

/// 挂一个播放器页，并让假内核接管解码器。
Future<_Fixture> _mount(WidgetTester tester, PlaybackRequest request) async {
  dismissAllToasts();
  final temp = Directory.systemTemp.createTempSync('webhtv-local-page');
  final state = _RecordingState(
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
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);

  final owner = ++_frameOwner;
  final fixture = _Fixture(
    state,
    <_FakeMedia>[],
    ValueKey('player-page-${++_pageSeq}'),
  );
  var active = true;
  addTearDown(() => active = false);
  tester.binding.addPersistentFrameCallback((_) {
    if (!active || owner != _frameOwner) return;
    final video = find.byType(Video);
    if (video.evaluate().isEmpty) return;
    final player = tester.widget<Video>(video).controller.player;
    if (player.platform is _FakeMedia) return;
    final media = _FakeMedia(player.platform!);
    fixture.media.add(media);
    player.platform = media;
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
    reason: '假内核没有接管解码器：时长恒为 0，写历史/解析相关的断言会全部失效',
  );
  return fixture;
}

/// 把控制浮层唤回可见态后点一个浮层里的按钮。
///
/// 浮层隐藏时按钮**仍在树里**、只是被 IgnorePointer 吃掉点击
/// （player_page.dart:6330 的注释记过这个坑），所以必须先走产品的唤醒路径。
Future<void> _tapControl(WidgetTester tester, Finder target) async {
  final page = tester.state<State<PlayerPage>>(find.byType(PlayerPage));
  debugRevealPlayerControls(page);
  await tester.pump();
  // 显隐是 AnimatedOpacity（AppMotion.fast），走完再点，否则命中的是动画层。
  await tester.pump(const Duration(milliseconds: 300));
  expect(target, findsOneWidget, reason: '控制浮层里找不到目标按钮');
  await tester.tap(target);
  await tester.pump();
}

/// 造一个真实存在的临时媒体路径（假内核不读盘，但路径语义要成立）。
String _tempMediaPath(String name) {
  final dir = Directory.systemTemp.createTempSync('webhtv-local-media');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  file.createSync();
  return file.path;
}

void main() {
  group('本地文件播放 · 播放器页行为', () {
    testWidgets(
      '本地播放不写历史：换片、走过进度计时器、销毁页面都不落 recordProgress',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        final first = await _mount(
          tester,
          PlaybackRequest.localFile(path: _tempMediaPath('本地片.mkv')),
        );
        // 播放：假内核已报出时长，进度计时器是「能真的写历史」的前提。
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(seconds: 5));
        // 换片：didUpdateWidget → _beginMediaTransition（player_page.dart:3132）
        // 会在替换请求前用旧标识落一次进度——本地这条必须是死路。
        await _pumpPage(
          tester,
          pageKey: first.pageKey,
          state: first.state,
          request: PlaybackRequest.localFile(path: _tempMediaPath('第二部.mkv')),
        );
        await _settle(tester);
        await tester.pump(const Duration(seconds: 5));

        // 对照：完全相同的挂载/换片/销毁流程换成远程请求。
        final remote = await _mount(tester, _remoteRequest());
        await tester.pump(const Duration(seconds: 5));
        await _pumpPage(
          tester,
          pageKey: remote.pageKey,
          state: remote.state,
          request: _remoteRequest(target: 'entry-2'),
        );
        await _settle(tester);
        await tester.pump(const Duration(seconds: 5));

        // 销毁：dispose（player_page.dart:3259）最后一次落进度。
        await _closePage(tester);

        expect(
          first.state.progressWrites,
          isEmpty,
          reason: '本地文件的集 id 是磁盘路径，落库只会得到一条续播不回去的历史',
        );
        expect(
          remote.state.progressWrites,
          isNotEmpty,
          reason: '对照：同一流程的远程请求必须写出历史，否则上面那条只是「计时器没跑」',
        );
      },
    );

    testWidgets(
      '本地播放不问站点：解析决策零调用、切集/切线路入口不渲染（对照：远程点了就走解析）',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        final local = await _mount(
          tester,
          _localRequest(_tempMediaPath('本地片.mkv')),
        );
        // 让起播后的补齐与计时器都有机会跑完再断言。
        await tester.pump(const Duration(seconds: 5));
        await _settle(tester);

        expect(local.state.resolveCalls, isEmpty, reason: '本地没有站点可解析');
        expect(local.state.sourceResolveCalls, isEmpty);
        expect(find.byKey(_parseStripKey), findsNothing);
        expect(find.textContaining('选集'), findsNothing);
        expect(
          find.textContaining('线路'),
          findsNothing,
          reason: '切线路入口只从选集面板进，本地不该有',
        );

        // 对照：同样字段的远程请求，起播直接用它自带地址（所以此刻也是 0 次），
        // 但点一下解析源条就会走站点解析——证明计数器本身是通的。
        final remote = await _mount(tester, _remoteRequest());
        expect(
          remote.state.resolveCalls,
          isEmpty,
          reason: '起播不解析：_load 直接用 request.url',
        );
        await _tapControl(tester, find.byKey(_parseChip1Key));
        await _settle(tester);
        expect(
          remote.state.resolveCalls,
          isNotEmpty,
          reason: '对照：远程点解析源条必须走站点解析，否则上面的空断言没有意义',
        );
        expect(remote.state.resolveCalls.first.target, 'entry-1');

        await _closePage(tester);
      },
    );

    testWidgets(
      '本地隐藏三件套：画质按钮 / 选集按钮 / 解析源条；同字段远程请求仍渲染',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        await _mount(tester, _localRequest(_tempMediaPath('本地片.mkv')));

        // 前提：这份本地请求**带着**能触发三件套的全部字段。
        final request = tester
            .widget<PlayerPage>(find.byType(PlayerPage))
            .request;
        expect(request.isLocal, isTrue);
        expect(request.qualities.length, greaterThan(1), reason: '画质入口的装配条件已满足');
        expect(
          request.parseSources.length,
          greaterThanOrEqualTo(2),
          reason: '解析源条的装配条件已满足',
        );
        expect(
          request.playLines.single.episodes.length,
          2,
          reason: '选集入口的装配条件已满足',
        );

        expect(find.byKey(_qualityButtonKey), findsNothing);
        expect(find.textContaining('选集'), findsNothing);
        expect(find.byKey(_parseStripKey), findsNothing);

        // 对照：只有「本地」这一点不同的远程请求，三件套必须都在。
        await _mount(tester, _remoteRequest());
        expect(find.byKey(_qualityButtonKey), findsOneWidget, reason: '画质：高清 / 超清 两档');
        expect(find.text('选集（2）'), findsOneWidget);
        expect(
          find.byKey(_parseStripKey),
          findsOneWidget,
          reason: '超级解析 / 解析B 两个可切源',
        );

        await _closePage(tester);
      },
    );

    testWidgets(
      '本地音频 AI 只提示不建面板',
      skip: libmpvUnavailableReason != null,
      (tester) async {
        await _mount(
          tester,
          PlaybackRequest.localFile(path: _tempMediaPath('本地片.mkv')),
        );

        await _tapControl(tester, find.byKey(_audioAiButtonKey));
        await tester.pump();

        expect(
          find.textContaining('不支持'),
          findsOneWidget,
          reason: '本地必须给出可见提示，而不是静默吞掉',
        );
        expect(
          find.byType(PlayerAudioAiPanel),
          findsNothing,
          reason: '面板要拿 mediaUri 拉音频流，本地路径只可能失败',
        );

        // 再点一次：仍然只有提示，不会因为「第二次」翻出面板来。
        await _tapControl(tester, find.byKey(_audioAiButtonKey));
        await tester.pump();
        expect(find.byType(PlayerAudioAiPanel), findsNothing);
        expect(
          toastCenter.toasts.where((toast) => toast.message.contains('不支持')),
          isNotEmpty,
        );

        await _closePage(tester);
      },
    );
  });
}
