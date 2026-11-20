import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/following.dart';
import 'package:webhtv_pc/core/playback_lines.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/source_swap.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/playback_resume.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/libmpv_guard.dart';
import 'support/player_page_harness.dart';

class _PendingState extends AppState {
  final home = Completer<void>();
  final playback = Completer<PlaybackDecision?>();
  int selections = 0;
  int resolutions = 0;
  final fixture = Site(key: 'site', name: '站点', type: 1, api: 'http://fixture');

  late final AppConfig _config = AppConfig(sites: [fixture]);

  @override
  AppConfig get config => _config;

  /// 历史/收藏/追剧解析站点走的是 [siteInActiveSource]，它读 [effectiveConfig]
  /// 而不是这个 `config` 覆盖（本地导入源只并进 effectiveConfig）。假 state 必须
  /// 跟着补同一个接缝，否则用例会落进「站点已不在当前配置中」的分支。
  @override
  AppConfig? get effectiveConfig => config;

  @override
  Future<void> selectSite(Site site) {
    selections++;
    return home.future;
  }

  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    Site? siteOverride,
    SiteService? serviceOverride,
    bool Function()? isCurrent,
    int? qualityIndex,
    String? preferredParseName,
  }) {
    resolutions++;
    expect(episodeTarget, 'http://fixture/episode');
    expect(flag, '原线路');
    expect(vodId, 'vod');
    return playback.future;
  }
}

class _PendingFollowingState extends _PendingState {
  final read = Completer<void>();
  int reads = 0;
  final item = Following(
    seriesKey: followingSeriesKey('site', 'vod'),
    season: 0,
    siteKey: 'site',
    vodId: 'vod',
    vodName: '原剧名',
    flag: '原线路',
    latestEpisodeName: '第2集',
    latestEpisodeTarget: 'http://fixture/episode',
  );

  @override
  List<Following> get followings => [item];

  @override
  Future<void> markFollowingRead(Following item) {
    reads++;
    return read.future;
  }
}

const _history = PlaybackHistory(
  id: 7,
  siteKey: 'site',
  vodId: 'vod',
  vodName: '原剧名',
  vodPic: 'poster',
  flag: '原线路',
  episodeName: '第2集',
  episodeId: 'http://fixture/episode',
  positionMs: 90000,
  durationMs: 600000,
  updatedAt: 1,
);

class _PushObserver extends NavigatorObserver {
  Route<dynamic>? last;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    last = route;
  }
}

Future<BuildContext> _pumpEntry(
  WidgetTester tester,
  _PendingState state,
  GlobalKey<NavigatorState> navigator, {
  _PushObserver? observer,
  PlaybackHistory history = _history,
  Duration linesTimeout = folderLinesPrefetchTimeout,
}) async {
  late BuildContext entryContext;
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [?observer],
      home: Scaffold(
        body: Builder(
          builder: (context) {
            entryContext = context;
            return FilledButton(
              onPressed: () => resumeHistoryEntry(
                context,
                state,
                history,
                linesTimeout: linesTimeout,
              ),
              child: const Text('续播'),
            );
          },
        ),
      ),
    ),
  );
  return entryContext;
}

/// 等待反馈的落点：只有一个转圈，没有上屏文案，因此按 key 找。
const ValueKey<String> _feedbackKey = ValueKey('async-action-feedback');

/// 网盘聚合目录条目（`atvp_detail:` 前缀）的历史记录。
///
/// 形态取自真机记录：`vod_id="atvp_detail:131957"`、`flag="丫仙女"`、
/// `episode_id="1@20465"`。
const _folderHistory = PlaybackHistory(
  id: 9,
  siteKey: 'site',
  vodId: 'atvp_detail:131957',
  vodName: '目录剧',
  vodPic: 'poster',
  flag: '丫仙女',
  episodeName: '01(696.02 MB)',
  episodeId: '1@20465',
  positionMs: 0,
  durationMs: 0,
  updatedAt: 2,
);

final _folderLines = [
  VodPlayLine(
    flag: '丫仙女',
    sourceFlag: '丫仙女',
    episodes: [
      VodEpisode(name: '01(696.02 MB)', url: '1@20465'),
      VodEpisode(name: '02(1.2 GB)', url: '1@20466'),
    ],
  ),
  VodPlayLine(
    flag: 'quark · 夸克',
    sourceFlag: '夸克',
    episodes: [VodEpisode(name: '01(696.02 MB)', url: '9@30001')],
  ),
];

const _folderRoutes = {
  '丫仙女': SwapLineRoute(
    siteKey: 'bridge-site',
    siteName: '桥接站',
    vodId: 'hxq-1',
  ),
  'quark · 夸克': SwapLineRoute(
    siteKey: 'bridge-site',
    siteName: '桥接站',
    vodId: 'hxq-2',
  ),
};

const _decision = PlaybackDecision(
  action: PlaybackAction.direct,
  url: 'http://fixture/media',
);

/// 目录记录专用：线路补齐由用例用 Completer 控制，解析不走 `_PendingState` 的断言。
class _FolderState extends _PendingState {
  final lines = Completer<PlaybackLines?>();
  final lineCalls = <({String siteKey, String vodId, String sourceKey})>[];

  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    Site? siteOverride,
    SiteService? serviceOverride,
    bool Function()? isCurrent,
    int? qualityIndex,
    String? preferredParseName,
  }) {
    resolutions++;
    return playback.future;
  }

  @override
  Future<PlaybackLines?> playLinesForRecord({
    required String siteKey,
    required String vodId,
    String vodName = '',
    String sourceKey = '',
    bool Function()? isCurrent,
  }) {
    lineCalls.add((siteKey: siteKey, vodId: vodId, sourceKey: sourceKey));
    return lines.future;
  }
}

void main() {
  tearDown(dismissAllToasts);

  testWidgets('追番卡片真实接线：已读准备阶段首帧反馈并防重入，失败恢复', (tester) async {
    final state = _PendingFollowingState();
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FollowingPage(state: state)),
      ),
    );
    final card = find.byKey(
      ValueKey('following-card-${state.item.identityKey}'),
    );
    await tester.tap(card);
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsOneWidget);
    await tester.tap(card);
    expect(state.reads, 1);
    expect(state.selections, 0);
    state.read.completeError(
      AppError(AppErrorKind.unknown, '已读写入失败', diagnostic: '内部请求上下文不可显示'),
    );
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsNothing);
    expect(toastCenter.toasts, hasLength(1));
    expect(toastCenter.toasts.single.message, '未知错误：已读写入失败');
    expect(toastCenter.toasts.single.message, isNot(contains('内部请求上下文不可显示')));
    await tester.tap(card);
    await tester.pump();
    expect(state.reads, 2);
  });

  testWidgets('追番卡片已读准备期间离页，迟到结果不切站、不出错误', (tester) async {
    final state = _PendingFollowingState();
    addTearDown(state.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(body: FollowingPage(state: state)),
      ),
    );
    await tester.tap(
      find.byKey(ValueKey('following-card-${state.item.identityKey}')),
    );
    await tester.pump();
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('另一页')),
      ),
    );
    await tester.pump();
    state.read.complete();
    await tester.pump(const Duration(milliseconds: 400));
    expect(state.selections, 0);
    expect(find.byKey(_feedbackKey), findsNothing);
    expect(find.text('另一页'), findsOneWidget);
    expect(toastCenter.toasts, isEmpty);
  });

  testWidgets('真实历史入口在选站等待首帧反馈并忽略重复点击，失败后能重试', (tester) async {
    final state = _PendingState();
    addTearDown(state.dispose);
    await _pumpEntry(tester, state, GlobalKey<NavigatorState>());
    await tester.tap(find.text('续播'));
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsOneWidget);
    await tester.tap(find.text('续播'));
    expect(state.selections, 1);
    state.home.complete();
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsOneWidget);
    state.playback.completeError(
      AppError(AppErrorKind.playbackUrlMissing, '历史记录没有可用播放地址'),
    );
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsNothing);
    expect(toastCenter.toasts, hasLength(1));
    await tester.tap(find.text('续播'));
    await tester.pump();
    expect(state.selections, 2);
    expect(state.resolutions, 2);
  });

  for (final fails in [false, true]) {
    testWidgets('历史等待时另一页已打开，迟到${fails ? '错误' : '成功'}不能导航或通知', (tester) async {
      final state = _PendingState();
      addTearDown(state.dispose);
      final navigator = GlobalKey<NavigatorState>();
      final context = await _pumpEntry(tester, state, navigator);
      await tester.tap(find.text('续播'));
      state.home.complete();
      await tester.pump();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('另一页')),
        ),
      );
      await tester.pump();
      expect(context.mounted, isTrue);
      expect(find.byKey(_feedbackKey), findsNothing);
      if (fails) {
        state.playback.completeError(
          AppError(AppErrorKind.playbackUrlMissing, '迟到错误'),
        );
      } else {
        state.playback.complete(
          const PlaybackDecision(
            action: PlaybackAction.direct,
            url: 'http://fixture/media',
          ),
        );
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('另一页'), findsOneWidget);
      expect(find.byType(PlayerPage), findsNothing);
      expect(toastCenter.toasts, isEmpty);
    });
  }

  testWidgets('历史页卸载立即收反馈，迟到选站不继续解析', (tester) async {
    final state = _PendingState();
    addTearDown(state.dispose);
    await _pumpEntry(tester, state, GlobalKey<NavigatorState>());
    await tester.tap(find.text('续播'));
    await tester.pump();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('离开历史'))),
    );
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsNothing);
    state.home.complete();
    await tester.pump();
    expect(state.resolutions, 0);
    expect(toastCenter.toasts, isEmpty);
  });

  testWidgets('历史导航前移除反馈且保留标题线路入口及续播进度', (tester) async {
    final state = _PendingState();
    addTearDown(state.dispose);
    final navigator = GlobalKey<NavigatorState>();
    final observer = _PushObserver();
    final context = await _pumpEntry(
      tester,
      state,
      navigator,
      observer: observer,
    );
    await tester.tap(find.text('续播'));
    state.home.complete();
    await tester.pump();
    // 只检查生产路由交接，不装载原生解码器或媒体。
    await tester.runAsync(() async {
      state.playback.complete(
        const PlaybackDecision(
          action: PlaybackAction.direct,
          url: 'http://fixture/media',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final route = observer.last! as MaterialPageRoute<void>;
      final player = route.builder(context) as PlayerPage;
      expect(player.request.title, '原剧名');
      expect(player.request.flag, '原线路');
      expect(player.request.episodeTarget, 'http://fixture/episode');
      expect(player.request.startPosition, const Duration(seconds: 90));
      expect(player.request.vodPic, 'poster');
      navigator.currentState!.pop();
    });
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsNothing);
    expect(toastCenter.toasts, isEmpty);
  });

  testWidgets('目录记录：进播放器前就取好线路，request 直接带线路与路由', (tester) async {
    final state = _FolderState();
    addTearDown(state.dispose);
    final navigator = GlobalKey<NavigatorState>();
    final observer = _PushObserver();
    final context = await _pumpEntry(
      tester,
      state,
      navigator,
      observer: observer,
      history: _folderHistory,
    );
    // 观察者也会收到启动时首页那次 push，用身份比较而不是判空。
    final homeRoute = observer.last;
    await tester.tap(find.text('续播'));
    await tester.pump();
    state.home.complete();
    await tester.pump();
    // 还没 push：线路预取已经发出去了。
    expect(state.lineCalls, hasLength(1));
    expect(state.lineCalls.single.vodId, 'atvp_detail:131957');
    expect(identical(observer.last, homeRoute), isTrue);
    state.lines.complete(
      PlaybackLines(lines: _folderLines, routes: _folderRoutes),
    );
    state.playback.complete(_decision);
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      final route = observer.last! as MaterialPageRoute<void>;
      final player = route.builder(context) as PlayerPage;
      // 断言的是**push 出去的那个 request**：线路、路由、命中线路与集下标成对。
      expect(player.request.playLines, _folderLines);
      expect(player.request.lineRoutes, _folderRoutes);
      expect(player.request.flag, '丫仙女');
      expect(player.request.playbackFlag, '丫仙女');
      expect(player.request.episodeIndex, 0);
      expect(player.request.episodeTarget, '1@20465');
      navigator.currentState!.pop();
    });
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsNothing);
    expect(toastCenter.toasts, isEmpty);
  });

  testWidgets('目录记录预取超时：仍在超时后起播，不带线路、无 toast、留 debug', (tester) async {
    // 超时后播放器会真的被 push 上来，先把 media_kit / window_manager 的
    // 平台通道 mock 掉，否则构建 PlayerPage 会抛 MissingPluginException。
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester);
    final state = _FolderState();
    addTearDown(state.dispose);
    final navigator = GlobalKey<NavigatorState>();
    final observer = _PushObserver();
    final context = await _pumpEntry(
      tester,
      state,
      navigator,
      observer: observer,
      history: _folderHistory,
      linesTimeout: const Duration(milliseconds: 20),
    );
    final homeRoute = observer.last;
    await tester.tap(find.text('续播'));
    await tester.pump();
    state.home.complete();
    await tester.pump();
    expect(state.lineCalls, hasLength(1));
    // 线路永远不完成：只靠超时收口。
    state.playback.complete(_decision);
    await tester.pump(const Duration(milliseconds: 5));
    expect(
      identical(observer.last, homeRoute),
      isTrue,
      reason: '超时之前不得提前起播',
    );
    await tester.pump(const Duration(milliseconds: 100));
    final route = observer.last! as MaterialPageRoute<void>;
    final player = route.builder(context) as PlayerPage;
    // 超时只是没线路，其余字段照旧（未命中就不硬塞）。
    expect(player.request.playLines, isEmpty);
    expect(player.request.lineRoutes, isEmpty);
    expect(player.request.flag, '丫仙女');
    expect(player.request.episodeIndex, 0);
    navigator.currentState!.pop();
    await tester.pump();
    expect(toastCenter.toasts, isEmpty);
    final debug = state.log.entries.where(
      (entry) =>
          entry.scope == 'player' &&
          entry.level == LogLevel.debug &&
          entry.message.contains('预取线路超时'),
    );
    expect(debug, hasLength(1));
    expect(debug.single.message, contains('atvp_detail:131957'));
    // 本条会构造 PlayerPage（初始化原生解码器）：没有 libmpv 时跳过而不是报错。
  }, skip: libmpvUnavailableReason != null);
}
