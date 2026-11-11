import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/epg.dart';
import 'package:webhtv_pc/core/live_catchup.dart';
import 'package:webhtv_pc/core/playback_diagnostics.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/epg_service.dart';
import 'package:webhtv_pc/services/live_service.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/live_page.dart';
import 'package:webhtv_pc/ui/player_live_line_panel.dart';
import 'package:webhtv_pc/ui/player_live_panel.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_osd.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:window_manager/window_manager.dart';

import '../test/fixture_support.dart';

final _captureEnabled = Platform.environment['TASK_C_CAPTURE'] != '0';
final _targetSize = Platform.environment['TASK_C_ONLY_SIZE'];
const _rootKey = ValueKey('task-c-material-app-capture');
const _firstSource = '验收源甲 · 超长中文直播源名称用于窄窗口可读性核实';
const _secondSource = '验收源乙 · 跨源Header和返回列表同步';
const _firstChannel = '综合频道甲 · 超长中文频道名称与多线路直播验收';
const _secondChannel = '综合频道乙 · 源乙专用Header与节目单';
const _crossGroupChannel = '跨组频道乙 · 返回后应自动定位到此频道';
const _pastTitle = '已结束节目 · 可回看本机真实媒体';
const _currentTitle = '当前节目 · 不允许回看';
const _futureTitle = '未来节目 · 不允许回看';

void _evidence(String message) => debugPrint('TASK-C-EVIDENCE $message');

class _MemoryLiveService extends LiveService {
  _MemoryLiveService(this.playlists);
  final Map<String, LivePlaylist> playlists;

  @override
  Future<LiveLoadResult> load(LiveSource source, {bool useCache = true}) async {
    final playlist = playlists[source.name];
    if (playlist == null) throw StateError('未定义的本机验收源 ${source.name}');
    return LiveLoadResult(
      playlist: playlist,
      source: source,
      latency: Duration.zero,
    );
  }
}

class _MemoryEpgService extends EpgService {
  _MemoryEpgService({required super.cacheDir, required this.guide});
  final EpgGuide guide;

  @override
  Future<EpgLoadResult> load({
    required String url,
    List<LiveChannel> liveChannels = const [],
    String sourceName = '',
    bool forceRefresh = false,
  }) async => EpgLoadResult(
    guide: guide,
    url: url,
    fromCache: false,
    latency: Duration.zero,
  );
}

Future<int> _httpStatus(String path, {bool mediaHeaders = false}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.getUrl(Uri.parse('$fixtureBaseUrl$path'));
    if (mediaHeaders) fixtureMediaHeaders.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>().timeout(const Duration(seconds: 5));
    _evidence(
      'fixture path=$path headers=$mediaHeaders status=${response.statusCode}',
    );
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  FutureOr<bool> Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final watch = Stopwatch()..start();
  for (var step = 0; step < 200 && watch.elapsed < timeout; step++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (await condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  fail('$reason；有界等待超时 ${watch.elapsed.inMilliseconds}ms');
}

Future<void> _paint(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(tester.takeException(), isNull, reason: '绘制不得出现布局溢出或异步异常');
}

Future<Uint8List?> _capture(
  WidgetTester tester,
  String name,
  Size size, {
  bool save = true,
}) async {
  await _paint(tester);
  final root = find.byKey(_rootKey);
  expect(root, findsOneWidget);
  expect(
    find.descendant(of: root, matching: find.byType(Navigator)),
    findsWidgets,
    reason: '截图根必须位于MaterialApp/Navigator之外',
  );
  expect(
    find.descendant(of: root, matching: find.byType(Overlay)),
    findsWidgets,
  );
  final boundary = tester.renderObject<RenderRepaintBoundary>(root);
  expect(boundary.size, size, reason: '根截图必须是完整指定窗口尺寸');
  if (!_captureEnabled) {
    _evidence('capture-disabled screenshot-evidence=false state=$name');
    return null;
  }
  final image = await boundary.toImage(pixelRatio: 1);
  try {
    expect(image.width, size.width.toInt());
    expect(image.height, size.height.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(bytes, isNotNull, reason: '原生Flutter截图不得空缺');
    final png = bytes!.buffer.asUint8List(
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    if (save) {
      final relative =
          '.local/live-interaction/player-right-screenshots/task-C-$name.png';
      final output = File('${repositoryRoot.path}/$relative');
      await tester.runAsync(() async {
        await output.parent.create(recursive: true);
        await output.writeAsBytes(png, flush: true);
      });
      _evidence(
        'screenshot=$relative bytes=${png.length} size=$size navigatorOverlay=true',
      );
    }
    return png;
  } finally {
    image.dispose();
  }
}

Player _player(WidgetTester tester) =>
    tester.widget<Video>(find.byType(Video).first).controller.player;

String? _actualMediaUri(Player player) {
  final playlist = player.state.playlist;
  if (playlist.medias.isEmpty) return null;
  return playlist.medias[playlist.index].uri;
}

class _NativePlayers {
  final _closed = <Player, Completer<void>>{};
  final _subscriptions = <StreamSubscription<Duration>>[];

  void observe(Player player) {
    if (_closed.containsKey(player)) return;
    final closed = Completer<void>();
    _closed[player] = closed;
    _subscriptions.add(
      player.stream.position.listen(
        (_) {},
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      ),
    );
  }

  Future<void> waitForDisposal() async {
    await Future.wait(_closed.values.map((closed) => closed.future))
        .timeout(const Duration(seconds: 10));
    _evidence('all-native-players-disposed count=${_closed.length}');
  }

  Future<void> cancel() async {
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
  }
}

State<PlayerPage> _playerState(WidgetTester tester) =>
    tester.state<State<PlayerPage>>(find.byType(PlayerPage));

Future<void> _probeBoundary(WidgetTester tester, String tag) async {
  final button = find.byTooltip('全屏（F11）');
  final panelState = _playerState(tester);
  final focus = FocusManager.instance.primaryFocus;
  _evidence(
    'probe-$tag fullscreen=${await windowManager.isFullScreen()} '
    'controlsVisible=${debugPlayerControlsVisible(panelState)} '
    'buttonNodes=${button.evaluate().length} '
    'buttonHit=${button.hitTestable().evaluate().length} '
    'buttonRect=${button.evaluate().isEmpty ? 'absent' : tester.getRect(button)} '
    'focus=${focus?.debugLabel ?? 'none'} '
    'livePanels=${find.byType(PlayerLivePanel).evaluate().length}'
    '${find.byType(PlayerLiveLinePanel).evaluate().length}',
  );
}

Future<Player> _expectRealPlayback(
  WidgetTester tester,
  AppState state, {
  required String url,
  required String source,
  required String channel,
  required String headerTag,
  required PlaybackDiagnostics? previous,
  required _NativePlayers players,
  String flag = '直播线路',
}) async {
  try {
    await _waitFor(tester, () {
      if (find.byType(Video).evaluate().length != 1) return false;
      final player = _player(tester);
      players.observe(player);
      final diagnostic = state.lastDiagnostics;
      return _actualMediaUri(player) == url &&
          player.state.position > Duration.zero &&
          diagnostic != null &&
          !identical(diagnostic, previous) &&
          diagnostic.succeeded == true &&
          diagnostic.siteKey == source &&
          diagnostic.flag == flag;
    }, reason: '真实媒体必须起播且生成本次请求的成功诊断：$source / $channel / $url');
  } on TestFailure {
    final videos = find.byType(Video).evaluate().length;
    final diagnostic = state.lastDiagnostics;
    final session = tester
        .widget<PlayerPage>(find.byType(PlayerPage))
        .liveSession;
    _evidence(
      'probe-playback-timeout videos=$videos '
      'uri=${videos == 1 ? _actualMediaUri(_player(tester)) : 'absent'} '
      'expected=$url '
      'position=${videos == 1 ? _player(tester).state.position.inMilliseconds : -1} '
      'playing=${videos == 1 ? _player(tester).state.playing : null} '
      'sessionChannel=${session?.channel.name} '
      'sessionRevision=${session?.playbackRevision} '
      'sameDiagnostic=${diagnostic == null ? 'null' : identical(diagnostic, previous)} '
      'diagnosticSucceeded=${diagnostic?.succeeded} '
      'diagnosticFlag=${diagnostic?.flag} '
      'diagnosticSiteKey=${diagnostic?.siteKey} '
      'failureText=${find.textContaining('播放失败').evaluate().length}',
    );
    rethrow;
  }
  final player = _player(tester);
  final diagnostic = state.lastDiagnostics!;
  expect(player.state.position, greaterThan(Duration.zero));
  expect(_actualMediaUri(player), url);
  expect(diagnostic.engine, PlaybackEngine.mediaKit);
  expect(diagnostic.succeeded, isTrue);
  expect(diagnostic.target.host, '127.0.0.1');
  expect(diagnostic.siteKey, source);
  expect(diagnostic.flag, flag);
  expect(
    diagnostic.requestedHeaders['Referer'],
    fixtureMediaHeaders['Referer'],
  );
  expect(
    diagnostic.requestedHeaders['User-Agent'],
    fixtureMediaHeaders['User-Agent'],
  );
  expect(diagnostic.requestedHeaders['X-Task-C-Channel'], headerTag);
  expect(find.textContaining('播放失败'), findsNothing);
  final session = tester
      .widget<PlayerPage>(find.byType(PlayerPage))
      .liveSession!;
  expect(session.source.name, source);
  expect(session.channel.name, channel);
  expect(session.request.url, url);
  final osdTitle = tester
      .widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer))
      .title;
  final expectedTitle = flag == '直播线路' ? channel : '$channel · $_pastTitle';
  expect(osdTitle, expectedTitle, reason: '真实OSD必须显示当前频道/节目且不重复频道名');
  _evidence('osd-title=$osdTitle expected=$expectedTitle');
  if (flag == '直播线路') {
    await tester.runAsync(() => player.setPlaylistMode(PlaylistMode.single));
  }
  _evidence(
    'real-playback durationMs=${player.state.duration.inMilliseconds} '
    'playing=${player.state.playing} completed=${player.state.completed} '
    'source=$source channel=$channel flag=$flag '
    'uri=${_actualMediaUri(player)} positionMs=${player.state.position.inMilliseconds} '
    'succeeded=${diagnostic.succeeded} headerTag=$headerTag',
  );
  return player;
}

/// 用**鼠标悬停**唤醒控制栏：这正是生产代码的唤醒路径
/// （`player_page.dart` 第 1 层的 `MouseRegion.onHover`）。
///
/// 为什么不能用「反复 tapAt」唤醒：画面那层 GestureDetector 同时挂了
/// `onTap` 和 `onDoubleTap`（`player_page.dart:2869-2872`），而单次 tap 的
/// `onTap` 要等双击判定窗（约 300ms）结束才落地。轮询里若因为「目标还没变」
/// 就再点一次，两次点击会被识别为**双击** → `resolvePlayerGesture(doubleTap:true,
/// fullscreen:false)` = `enterFullscreen` → 播放器真的进了全屏，随后测试点
/// 「全屏」按钮就把全屏**退出**了，20 秒等待必然超时。
Future<void> _hoverVideo(WidgetTester tester, Offset point) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(1, 1));
  try {
    for (var step = 1; step <= 3; step++) {
      await mouse.moveTo(point + Offset(step.toDouble(), 0));
      await tester.pump();
    }
  } finally {
    await mouse.removePointer();
  }
}

Future<void> _showControls(WidgetTester tester) async {
  expect(find.byType(PlayerLivePanel), findsNothing, reason: '唤醒控制栏前频道抽屉必须已关闭');
  expect(find.byType(PlayerLiveLinePanel), findsNothing);
  final opacity = find
      .ancestor(
        of: find.byType(PlayerControlOverlay),
        matching: find.byType(AnimatedOpacity),
      )
      .first;
  _evidence(
    'controls-before target=${tester.widget<AnimatedOpacity>(opacity).opacity} '
    'rendered=${tester.renderObject<RenderAnimatedOpacity>(opacity).opacity.value}',
  );
  var wakeAttempts = 0;
  var tapped = false;
  await _waitFor(
    tester,
    () async {
      if (!debugPlayerControlsVisible(_playerState(tester))) {
        const point = Offset(100, 150);
        expect(tester.getRect(find.byType(Video)).contains(point), isTrue);
        wakeAttempts++;
        // 悬停唤醒没有手势语义，永远不会被识别成双击；只在悬停无效时
        // 才补**一次**真实点击，且绝不重复点（重复点就是双击）。
        if (wakeAttempts < 12) {
          await _hoverVideo(tester, point);
        } else if (!tapped) {
          tapped = true;
          await tester.tapAt(point);
        }
        await tester.pump();
        _evidence(
          'controls-wake attempt=$wakeAttempts hover=${!tapped} '
          'singleTap=$tapped '
          'visibleAfter=${debugPlayerControlsVisible(_playerState(tester))} '
          'target=${tester.widget<AnimatedOpacity>(opacity).opacity} '
          'fullscreen=${await windowManager.isFullScreen()}',
        );
        return false;
      }
      return tester.widget<AnimatedOpacity>(opacity).opacity == 1 &&
          tester.renderObject<RenderAnimatedOpacity>(opacity).opacity.value ==
              1 &&
          find.byTooltip('全屏（F11）').hitTestable().evaluate().length == 1 &&
          find.byType(BackButton).hitTestable().evaluate().length == 1;
    },
    reason: '真实控制层必须目标可见、绘制不透明且全屏/返回可命中',
    timeout: const Duration(seconds: 5),
  );
  expect(tester.renderObject<RenderAnimatedOpacity>(opacity).opacity.value, 1);
  expect(find.byTooltip('全屏（F11）').hitTestable(), findsOneWidget);
  expect(find.byType(BackButton).hitTestable(), findsOneWidget);
  expect(
    await windowManager.isFullScreen(),
    isFalse,
    reason:
        '唤醒控制栏不得改变窗口的全屏状态：画面层单击是延迟落地的，'
        '轮询里重复点击会被识别成双击（=进入全屏）',
  );
  expect(tester.takeException(), isNull);
  _evidence(
    'controls-ready target=1 rendered=1 fullscreenHit=true backHit=true wakeAttempts=$wakeAttempts',
  );
  await _probeBoundary(tester, 'controls-ready');
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('player-live-panel-toggle')));
  await _paint(tester);
  expect(find.byType(PlayerLivePanel), findsOneWidget);
}

Finder _sourceRow(String name) =>
    find.byKey(ValueKey('live-panel-source-$name'));

Future<void> _browseSource(WidgetTester tester, String name) async {
  await tester.tap(_sourceRow(name));
  await _waitFor(tester, () {
    final session = tester
        .widget<PlayerLivePanel>(find.byType(PlayerLivePanel))
        .session;
    return !session.browseLoading && session.browseSource.name == name;
  }, reason: '浏览源加载应完成');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUpAll(() async {
    expect(Platform.isWindows, isTrue, reason: 'Task C必须在真实Windows桌面执行');
    expect(
      Uri.parse(fixtureBaseUrl).host,
      '127.0.0.1',
      reason: '仅允许协调者本机fixture',
    );
    await windowManager.ensureInitialized();
  });

  if (_targetSize == null) {
    testWidgets('本机fixture Header门禁：无Header拒绝，有Header可读', (tester) async {
      for (final path in ['/health', '/live/live.m3u', '/live/epg.xml']) {
        expect(
          await tester.runAsync(() => _httpStatus(path)),
          200,
          reason: '前置端点不可用时必须失败，不允许skip',
        );
      }
      for (final path in ['/media/sample.m3u8', '/media/sample.mp4']) {
        expect(await tester.runAsync(() => _httpStatus(path)), 403);
        expect(
          await tester.runAsync(() => _httpStatus(path, mediaHeaders: true)),
          200,
        );
      }
    });
  }

  for (final size in [
    const Size(1024, 640),
    const Size(1440, 900),
    const Size(1600, 800),
  ]) {
    final tag = '${size.width.toInt()}x${size.height.toInt()}';
    if (_targetSize != null && _targetSize != tag) continue;
    final detailed = size.width != 1600;
    final modeLabel = _captureEnabled
        ? ''
        : _targetSize == null
        ? '行为探测（截图未验收） '
        : '正式功能补验（不采图） ';
    testWidgets('$modeLabel$tag 列表到真实播放器：源频道线路、跨组、回看、返回同步', (tester) async {
      expect(await tester.runAsync(() => _httpStatus('/health')), 200);
      final temp = Directory.systemTemp.createTempSync('webhtv-task-c-$tag-');
      final paths = AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      );
      final now = DateTime.now();
      final past = EpgProgram(
        title: _pastTitle,
        startMs: now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
        stopMs: now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      final current = EpgProgram(
        title: _currentTitle,
        startMs: now
            .subtract(const Duration(minutes: 30))
            .millisecondsSinceEpoch,
        stopMs: now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      final future = EpgProgram(
        title: _futureTitle,
        startMs: now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        stopMs: now.add(const Duration(hours: 2)).millisecondsSinceEpoch,
      );
      final catchupUrl = '$fixtureBaseUrl/media/sample.mp4?task-c=catchup-$tag';
      final catchup = CatchupSpec(type: 'default', source: catchupUrl);
      final longSuffix =
          'task-c=$tag&description=${List.filled(8, 'long-readable-fixture-url').join('-')}';
      final aUrl = '$fixtureBaseUrl/media/sample.m3u8?$longSuffix&channel=a';
      final bUrl = '$fixtureBaseUrl/media/sample.m3u8?$longSuffix&channel=b';
      final bLine2 =
          '$fixtureBaseUrl/media/sample.mp4?$longSuffix&channel=b-line2';
      final crossUrl =
          '$fixtureBaseUrl/media/sample.mp4?$longSuffix&channel=cross-group';
      LiveChannel makeChannel(
        String name,
        String group,
        String id,
        List<String> urls,
      ) => LiveChannel(
        name: name,
        group: group,
        epgId: id,
        urls: urls,
        catchup: catchup,
        header: HeaderMap({...fixtureMediaHeaders, 'X-Task-C-Channel': id}),
      );
      final a = makeChannel(_firstChannel, '综合组甲', 'task-c-a', [aUrl, bLine2]);
      final b = makeChannel(_secondChannel, '综合组乙', 'task-c-b', [bUrl, bLine2]);
      final cross = makeChannel(_crossGroupChannel, '跨组定位乙', 'task-c-cross', [
        crossUrl,
      ]);
      final fillers = [
        for (var i = 0; i < 16; i++)
          makeChannel('填充频道 $i · 保证最终频道原本在视口外', '综合组乙', 'filler-$i', [bUrl]),
      ];
      final sourceA = LiveSource(
        name: _firstSource,
        type: 1,
        url: '$fixtureBaseUrl/live/live.m3u?source=a',
        epg: '$fixtureBaseUrl/live/epg.xml',
      );
      final sourceB = LiveSource(
        name: _secondSource,
        type: 1,
        url: '$fixtureBaseUrl/live/live.m3u?source=b',
        epg: '$fixtureBaseUrl/live/epg.xml',
      );
      final playlists = {
        _firstSource: LivePlaylist(
          sourceName: _firstSource,
          epg: sourceA.epg,
          groups: [
            LiveGroup(name: a.group, channels: [a]),
          ],
        ),
        _secondSource: LivePlaylist(
          sourceName: _secondSource,
          epg: sourceB.epg,
          groups: [
            LiveGroup(name: b.group, channels: [b, ...fillers]),
            LiveGroup(name: cross.group, channels: [cross]),
          ],
        ),
      };
      final guide = EpgGuide(
        channels: {
          for (final channel in [a, b, cross])
            channel.epgId!: EpgChannelGuide(
              channelId: channel.epgId!,
              programs: [past, current, future],
            ),
        },
        totalPrograms: 9,
        skippedPrograms: 0,
        sourceName: 'Task C本机节目单',
      );
      final state = AppState(
        paths: paths,
        log: LogService(),
        liveService: _MemoryLiveService(playlists),
        epgService: _MemoryEpgService(cacheDir: paths.cacheDir, guide: guide),
      );
      final originalSize = await windowManager.getSize();
      final originallyFullscreen = await windowManager.isFullScreen();
      final originallyMaximized = await windowManager.isMaximized();
      final players = _NativePlayers();
      var mounted = false;
      try {
        await tester.runAsync(state.bootstrap);
        final imported = await tester.runAsync(
          () => state.importConfig(
            jsonEncode({
              'name': 'Task C本机验收配置',
              'sites': [
                {
                  'key': 'task-c-fixture',
                  'name': 'Task C本机fixture',
                  'type': 1,
                  'api': '$fixtureBaseUrl/api/type1/',
                },
              ],
              'lives': [sourceA.toJson(), sourceB.toJson()],
            }),
            displayName: 'Task C本机验收配置',
          ),
        );
        expect(imported, isTrue, reason: '必须通过公开配置导入API设置直播源');
        expect(state.liveSources.map((source) => source.name), [
          _firstSource,
          _secondSource,
        ]);
        await windowManager.setFullScreen(false);
        await windowManager.unmaximize();
        await windowManager.setSize(size);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: _rootKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildAppTheme(Brightness.dark),
              home: Scaffold(body: LivePage(state: state)),
            ),
          ),
        );
        mounted = true;
        await _waitFor(
          tester,
          () => find.byTooltip('详情与节目单 $_firstChannel').evaluate().isNotEmpty,
          reason: '直播列表必须加载',
        );
        await tester.tap(find.byTooltip('详情与节目单 $_firstChannel'));
        await _waitFor(
          tester,
          () => find.text(_pastTitle).evaluate().isNotEmpty,
          reason: '详情应显示已加载节目单',
        );
        await _paint(tester);
        expect(find.byType(PlayerPage), findsNothing, reason: '详情入口不能开播');
        expect(find.text(_pastTitle), findsOneWidget);
        expect(find.textContaining(_currentTitle), findsWidgets);
        await _capture(tester, '$tag-list-detail', size);
        final list = find.byKey(const ValueKey('live-channel-list'));
        await tester.tap(
          find.descendant(of: list, matching: find.text(_firstChannel)),
        );
        await _waitFor(
          tester,
          () => find.byType(PlayerPage).evaluate().isNotEmpty,
          reason: '频道单击必须真实导航到播放器',
        );
        final session = tester
            .widget<PlayerPage>(find.byType(PlayerPage))
            .liveSession;
        expect(session, isNotNull);
        final live = session!;
        await _waitFor(
          tester,
          () => find.byType(Video).evaluate().length == 1,
          reason: '播放器应建立真实原生媒体引擎',
        );
        final player = _player(tester);
        players.observe(player);
        await _expectRealPlayback(
          tester,
          state,
          players: players,
          url: aUrl,
          source: _firstSource,
          channel: _firstChannel,
          headerTag: 'task-c-a',
          previous: null,
        );
        await _showControls(tester);
        expect(find.text('线路（2）'), findsOneWidget);
        expect(find.textContaining('选集（'), findsNothing);
        final videoRect = tester.getRect(find.byType(Video));
        final closed = await _capture(
          tester,
          '$tag-player-closed',
          size,
          save: detailed,
        );
        await _openDrawer(tester);
        expect(
          tester.getRect(find.byType(Video)),
          videoRect,
          reason: '抽屉不能缩放或移动视频',
        );
        expect(
          find.descendant(
            of: find.byKey(_rootKey),
            matching: find.byType(PlayerLivePanel),
          ),
          findsOneWidget,
        );
        final opened = await _capture(tester, '$tag-player-drawer', size);
        if (_captureEnabled) {
          expect(
            listEquals(closed, opened),
            isFalse,
            reason: '抽屉开关截图必须有真实像素差异',
          );
        }
        final sourceRow = _sourceRow(_secondSource);
        expect(sourceRow, findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) => widget is DropdownButton<LiveSource>,
          ),
          findsNothing,
          reason: '播放器源选择与频道线路同屏，不再使用独立下拉面板',
        );
        await tester.tap(sourceRow);
        await _paint(tester);
        await _capture(tester, '$tag-source-list-linked', size, save: detailed);
        await _waitFor(
          tester,
          () => !live.browseLoading && live.browseSource.name == _secondSource,
          reason: '另一个源的候选应可浏览',
        );
        final beforeBrowseDiagnostic = state.lastDiagnostics;
        final beforeBrowsePosition = player.state.position;
        _evidence(
          'browse-before positionMs=${beforeBrowsePosition.inMilliseconds} '
          'durationMs=${player.state.duration.inMilliseconds} playing=${player.state.playing} '
          'completed=${player.state.completed}',
        );
        expect(live.source.name, _firstSource);
        expect(live.channel.name, _firstChannel);
        expect(live.request.url, aUrl);
        expect(find.text('正在播放 · $_firstSource'), findsOneWidget);
        expect(
          tester.widget<ListTile>(_sourceRow(_secondSource)).selected,
          isTrue,
        );
        await _waitFor(
          tester,
          () =>
              player.state.playing &&
              player.state.position != beforeBrowsePosition,
          reason: '只浏览另一源不能暂停或替换正在播放的媒体',
        );
        expect(_actualMediaUri(player), aUrl);
        expect(
          identical(state.lastDiagnostics, beforeBrowseDiagnostic),
          isTrue,
        );
        _evidence(
          'browse-only playing=$_firstSource candidate=$_secondSource uninterrupted=true',
        );
        var previous = state.lastDiagnostics;
        await tester.tap(find.byKey(const ValueKey('live-panel-channel-0')));
        await _expectRealPlayback(
          tester,
          state,
          players: players,
          url: bUrl,
          source: _secondSource,
          channel: _secondChannel,
          headerTag: 'task-c-b',
          previous: previous,
        );
        expect(find.text('正在播放 · $_secondSource'), findsOneWidget);
        expect(find.text('$_secondSource · 播放中'), findsOneWidget);
        expect(
          find.text(_secondChannel),
          findsWidgets,
          reason: '播放器和抽屉标题同步新频道',
        );
        expect(
          (tester.widget<AppBar>(find.byType(AppBar)).title as Text).data,
          contains(_secondChannel),
          reason: '播放器顶栏必须使用新频道，不得沿用旧频道请求',
        );
        final selectedTile = find.descendant(
          of: find.byKey(const ValueKey('live-panel-channel-0')),
          matching: find.byType(ListTile),
        );
        expect(tester.widget<ListTile>(selectedTile).selected, isTrue);
        expect(tester.getRect(find.byType(Video)), videoRect);
        await tester.tap(
          find.byKey(const ValueKey('live-panel-channel-lines-0')),
        );
        await _paint(tester);
        expect(find.byType(PlayerLiveLinePanel), findsOneWidget);
        previous = state.lastDiagnostics;
        await tester.tap(find.byKey(const ValueKey('live-line-1')));
        await _expectRealPlayback(
          tester,
          state,
          players: players,
          url: bLine2,
          source: _secondSource,
          channel: _secondChannel,
          headerTag: 'task-c-b',
          previous: previous,
        );
        expect(live.lineIndex, 1);
        expect(
          tester
              .widget<ListTile>(find.byKey(const ValueKey('live-line-1')))
              .selected,
          isTrue,
        );
        expect(
          find.byTooltip(bLine2),
          findsOneWidget,
          reason: '长URL必须可通过tooltip查看',
        );
        expect(tester.getRect(find.byType(Video)), videoRect);
        await _capture(tester, '$tag-live-lines', size, save: detailed);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _paint(tester);
        expect(find.byType(PlayerLiveLinePanel), findsNothing);
        expect(
          find.byType(PlayerLivePanel),
          findsNothing,
          reason: '线路与频道在同一面板，Esc一次关闭整个联动面板',
        );
        previous = state.lastDiagnostics;
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await _expectRealPlayback(
          tester,
          state,
          players: players,
          url: crossUrl,
          source: _secondSource,
          channel: _crossGroupChannel,
          headerTag: 'task-c-cross',
          previous: previous,
        );
        expect(live.channel.group, '跨组定位乙', reason: 'PgUp必须跨组循环到最后频道');
        previous = state.lastDiagnostics;
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await _expectRealPlayback(
          tester,
          state,
          players: players,
          url: bUrl,
          source: _secondSource,
          channel: _secondChannel,
          headerTag: 'task-c-b',
          previous: previous,
        );
        expect(live.channel.group, '综合组乙', reason: 'PgDn必须跨组循环回首频道');
        await _showControls(tester);
        expect(
          find.byTooltip('全屏（F11）').hitTestable(),
          findsOneWidget,
          reason: '全屏按钮必须真实可点击，不能隔着抽屉点击',
        );
        await _probeBoundary(tester, 'f11-before');
        // 该按钮是**切换**语义：若此刻已是全屏（例如前面某次画面点击被识别成
        // 双击），这一次点击就会把全屏退出，等待必然超时。把前提写成断言，
        // 让误入全屏在**这一行**报出来，而不是 20 秒后只报「超时」。
        expect(
          await windowManager.isFullScreen(),
          isFalse,
          reason: '点击全屏按钮前必须处于窗口态，否则这次点击会变成退出全屏',
        );
        await tester.tap(find.byTooltip('全屏（F11）'));
        await tester.pump();
        await _probeBoundary(tester, 'f11-after-tap');
        final fullscreenWatch = Stopwatch()..start();
        var fullscreen = await windowManager.isFullScreen();
        var fullscreenSteps = 0;
        while (!fullscreen &&
            fullscreenWatch.elapsed < const Duration(seconds: 20)) {
          await tester.pump(const Duration(milliseconds: 100));
          fullscreen = await windowManager.isFullScreen();
          if (fullscreen || fullscreenSteps < 4) {
            fullscreenSteps++;
            _evidence(
              'probe-f11-wait step=$fullscreenSteps fullscreen=$fullscreen '
              'elapsedMs=${fullscreenWatch.elapsedMilliseconds} '
              'controlsVisible=${debugPlayerControlsVisible(_playerState(tester))} '
              'buttonHit=${find.byTooltip('全屏（F11）').hitTestable().evaluate().length}',
            );
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
        }
        expect(fullscreen, isTrue, reason: '播放器全屏操作必须真正进入原生全屏');
        expect(await windowManager.isFullScreen(), isTrue);
        await _openDrawer(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _paint(tester);
        expect(find.byType(PlayerLivePanel), findsNothing, reason: 'Esc仅关闭抽屉');
        expect(
          await windowManager.isFullScreen(),
          isTrue,
          reason: '抽屉Esc不得退出全屏',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _waitFor(
          tester,
          () async => !await windowManager.isFullScreen(),
          reason: '无抽屉的第二次Esc应退出原生全屏',
        );
        await _paint(tester);
        expect(await windowManager.isFullScreen(), isFalse);
        await windowManager.setSize(size);
        expect(tester.getRect(find.byType(Video)), videoRect);
        await _openDrawer(tester);
        await tester.tap(find.text('节目单'));
        await _waitFor(
          tester,
          () => find.byTooltip('回看$_pastTitle').evaluate().isNotEmpty,
          reason: '当前频道节目单应加载完成',
        );
        expect(find.byTooltip('回看$_currentTitle'), findsNothing);
        expect(find.byTooltip('回看$_futureTitle'), findsNothing);
        final revision = live.playbackRevision;
        await tester.tap(find.text(_currentTitle));
        await _paint(tester);
        expect(live.playbackRevision, revision, reason: '当前节目不能触发回看');
        previous = state.lastDiagnostics;
        await tester.tap(find.byTooltip('回看$_pastTitle'));
        await _expectRealPlayback(
          tester,
          state,
          players: players,
          url: catchupUrl,
          source: _secondSource,
          channel: _secondChannel,
          headerTag: 'task-c-b',
          previous: previous,
          flag: '回看',
        );
        expect(live.program, past);
        final catchupTitle =
            (tester.widget<AppBar>(find.byType(AppBar)).title as Text).data;
        expect(catchupTitle, contains(_secondChannel));
        expect(catchupTitle, contains(_pastTitle), reason: '播放器顶栏必须同步回看节目');
        expect(find.text('回看 · $_pastTitle'), findsOneWidget);
        await _capture(tester, '$tag-catchup', size);
        previous = state.lastDiagnostics;
        await tester.tap(
          find.descendant(
            of: find.byType(PlayerLivePanel),
            matching: find.text('回到直播'),
          ),
        );
        await _expectRealPlayback(
          tester,
          state,
          players: players,
          url: bUrl,
          source: _secondSource,
          channel: _secondChannel,
          headerTag: 'task-c-b',
          previous: previous,
        );
        expect(live.program, isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _paint(tester);
        previous = state.lastDiagnostics;
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await _expectRealPlayback(
          tester,
          state,
          players: players,
          url: crossUrl,
          source: _secondSource,
          channel: _crossGroupChannel,
          headerTag: 'task-c-cross',
          previous: previous,
        );
        await _openDrawer(tester);
        await _browseSource(tester, _firstSource);
        expect(live.source.name, _secondSource);
        expect(live.channel.name, _crossGroupChannel);
        expect(live.browseSource.name, _firstSource);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _paint(tester);
        await _showControls(tester);
        await tester.tap(find.byType(BackButton));
        await _waitFor(
          tester,
          () =>
              find.byType(PlayerPage).evaluate().isEmpty &&
              find
                  .byTooltip('详情与节目单 $_crossGroupChannel')
                  .hitTestable()
                  .evaluate()
                  .isNotEmpty,
          reason: '返回必须同步实际播放频道并滚动到可见，不能同步浏览源',
        );
        final sourceTile = find.ancestor(
          of: find.text(_secondSource),
          matching: find.byType(ListTile),
        );
        expect(tester.widget<ListTile>(sourceTile).selected, isTrue);
        // 分组已改为抽屉层级：入口按钮上必须显示返回后定位到的那个分组，
        // 而不是一个没有选中态的下拉框。
        final groupToggle = find.byKey(const ValueKey('live-group-toggle'));
        expect(groupToggle, findsOneWidget);
        expect(
          find.descendant(
            of: groupToggle,
            matching: find.textContaining('跨组定位乙'),
          ),
          findsOneWidget,
          reason: '返回同步必须把分组入口定位到实际播放频道所在分组',
        );
        await tester.tap(find.text('线路'));
        await _paint(tester);
        final lineTile = find.byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.title is Text &&
              (widget.title as Text).data == '线路 1',
        );
        expect(
          tester.widget<ListTile>(lineTile).selected,
          isTrue,
          reason: '返回详情必须同步最后线路',
        );
        await _capture(
          tester,
          '$tag-return-synchronized',
          size,
          save: detailed,
        );
        _evidence(
          'flow-complete size=$tag returnedSource=$_secondSource '
          'returnedChannel=$_crossGroupChannel line=0 candidateNotSynced=true',
        );
      } finally {
        if (mounted) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
        try {
          await tester.runAsync(players.waitForDisposal);
          _evidence('native-player-disposed size=$tag streamClosed=true');
        } finally {
          await players.cancel();
          state.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await windowManager.setFullScreen(false);
          await windowManager.setSize(originalSize);
          if (originallyMaximized) await windowManager.maximize();
          if (originallyFullscreen) await windowManager.setFullScreen(true);
          expect(temp.path.contains('webhtv-task-c-$tag-'), isTrue);
          await tester.runAsync(() => temp.delete(recursive: true));
          _evidence('cleanup size=$tag appStateDisposed=true tempRemoved=true');
        }
      }
    }, timeout: const Timeout(Duration(minutes: 6)));
  }
}
