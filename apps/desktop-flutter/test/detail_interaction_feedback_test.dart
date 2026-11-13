/// 详情页播放入口的**交互反馈**门禁（用户反馈：点播放没反应）。
///
/// 缺口（`lib/ui/browse_pages.dart:2024` `_play`）：`await state.resolvePlayback(...)`
/// 之后才 `Navigator.push`，中间**没有任何页面忙碌状态**，也没有防重入；hero
/// 播放按钮（`:2681`）与剧集卡（`_playEpisodeAt` → `_play`）都直连它。这段解析
/// 期间按钮既不置灰也不提示，用户看到的就是「点了没反应」，连点还会重复解析、
/// 重复 push 播放器。
///
/// 本文件用 pending Completer 把解析挂住，锁住**可观察的行为**：
/// 1. 慢解析时按下一帧就有可见反馈；
/// 2. hero 按钮与剧集卡共享本页防重入，只解析一次；
/// 3. 解析成功进入播放器，返回后反馈不残留且可再次播放；
/// 4. 解析失败收起反馈并给出错误，且可立即重试；
/// 5. 离页安全：等待中离开页面 → 反馈收掉，迟到成功不得 push；
/// 6. 减动态（disableAnimations / accessibleNavigation）：反馈仍可见。
///
/// 断言只用**本文件可达的公开落点**（反馈组件的 key）与真实控件，不绑定它的
/// 内部图标 / 补间细节——那些属于反馈组件自身的门禁。
///
/// **绝不用 `pumpAndSettle`**：详情页背景轮播与 `LoadingBlock` 都是无限动画。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/player_page_harness.dart';

/// 等待反馈的落点：只有一个转圈，没有上屏文案，因此按 key 找。
const ValueKey<String> _feedbackKey = ValueKey('async-action-feedback');

/// 详情页播放入口：hero 按钮与剧集卡（两者都必须有反馈且共享防重入）。
const ValueKey<String> _heroPlayKey = ValueKey('detail-hero-play');

/// 第二条线路集的卡片 key（`TmdbEpisodeStrip` 的 `keyPrefix-originalIndex`）。
const ValueKey<String> _episodeCardKey = ValueKey('tmdb-episode-card-原线路-1');

/// 换源用例的站点配置：主站承载详情页自己的线路（不可搜），换源站可搜。
const String _swapConfigJson = '''
{
  "name": "详情反馈换源测试",
  "sites": [
    {"key": "ui-main", "name": "主站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 0},
    {"key": "ui-swap", "name": "换源站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 1}
  ]
}
''';

/// 把解析挂住的 `AppState`：真实状态层 + 可控的 `resolvePlayback`。
///
/// 为什么覆写而不是注入假 HTTP：`resolvePlayback` 内部还要依次走
/// `SiteService` → `PlaybackResolver` → 本地代理 token（`revokeProxySession`
/// /`proxyDecision`），用假客户端只能挂住**某一环**。挂住这一个公开入口，
/// 测的正是「入口到播放器之间那段时间用户看到什么」。
class _PendingPlaybackState extends AppState {
  _PendingPlaybackState({
    required super.paths,
    required super.log,
    super.httpClient,
  });

  /// 每次调用的挂起器，按调用顺序排列（断言「只解析一次」用）。
  final List<Completer<PlaybackDecision?>> pending = [];

  /// 解析被调用了几次。
  int resolutions = 0;

  /// 第 1 次解析**如实失败**（用于触发换源确认框这条真实路径），
  /// 之后各次挂起。默认 false：所有调用都挂起。
  bool failFirstPlayback = false;

  /// 最近一次解析收到的参数（确认这次改动没有弄丢透传）。
  String? lastEpisodeTarget;
  String? lastFlag;
  String? lastVodId;

  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    bool Function()? isCurrent,
    int? qualityIndex,
    Site? siteOverride,
    SiteService? serviceOverride,
    String? preferredParseName,
  }) async {
    resolutions += 1;
    lastEpisodeTarget = episodeTarget;
    lastFlag = flag;
    lastVodId = vodId;
    if (failFirstPlayback && resolutions == 1) {
      throw AppError(AppErrorKind.playbackUrlMissing, '这一集没有可播放的地址');
    }
    final completer = Completer<PlaybackDecision?>();
    pending.add(completer);
    return completer.future;
  }
}

void main() {
  late Directory tempDir;
  late _PendingPlaybackState state;

  setUp(() async {
    dismissAllToasts();
    tempDir = await Directory.systemTemp.createTemp('webhtv-detail-feedback');
    state = _PendingPlaybackState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
      ),
      log: LogService(),
      // 换源用例要走真实的搜索/探测/并入，用假客户端承接，不碰 socket。
      httpClient: _SwapClient(),
    );
    // 详情页 `initState` 会碰 `state.tmdb`（TMDB 身份服务由 bootstrap 装配）。
    await state.bootstrap();
  });

  tearDown(() async {
    // 挂起的解析若未放行，会让 tearDown 的目录删除撞上在途 I/O。
    for (final completer in state.pending) {
      if (!completer.isCompleted) {
        completer.completeError(AppError(AppErrorKind.siteCancelled, '测试收尾'));
      }
    }
    dismissAllToasts();
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Vod detailVod() => Vod(
    vodId: 'feedback-1',
    vodName: '反馈测试影片',
    vodContent: '两集，用于验证播放入口的等待反馈。',
    vodPlayFrom: '原线路',
    vodPlayUrl: '第1集\$http://127.0.0.1:1/media/a.mp4#第2集\$http://127.0.0.1:1/media/b.mp4',
  );

  /// 显式推帧（详情页有无限动画，`pumpAndSettle` 必然超时）。
  Future<void> pumpFrames(WidgetTester tester, {int times = 6}) async {
    for (var i = 0; i < times; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 用「用户主动中断」收尾：这条失败只推通知、不弹换源确认框，
  /// 因此不会留下挡住后续点击的模态层。
  Future<void> settlePending(WidgetTester tester) async {
    for (final completer in state.pending) {
      if (!completer.isCompleted) {
        completer.completeError(AppError(AppErrorKind.siteCancelled, '测试收尾'));
      }
    }
    await pumpFrames(tester);
    dismissAllToasts();
    await pumpFrames(tester, times: 2);
  }

  Future<void> pumpDetail(
    WidgetTester tester, {
    bool disableAnimations = false,
    bool accessibleNavigation = false,
  }) async {
    // 解析成功后要 push `PlayerPage`，媒体通道必须先 mock。
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester);
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final reduce = disableAnimations || accessibleNavigation;
    await tester.pumpWidget(
      MaterialApp(
        // **必须 copyWith**：直接塞一个裸 `MediaQueryData` 会把 size 变成
        // 0×0，hero 根本不会被布局（实测：hero 按钮随后找不到）。
        builder: reduce
            ? (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  disableAnimations: disableAnimations,
                  accessibleNavigation: accessibleNavigation,
                ),
                child: child!,
              )
            : null,
        home: Stack(
          fit: StackFit.expand,
          children: [
            DetailPage(state: state, vod: detailVod()),
            const ToastHost(),
          ],
        ),
      ),
    );
    await pumpFrames(tester);
  }

  /// 滚过满屏 hero，让剧集卡进入视口。
  Future<void> scrollPastHero(WidgetTester tester) async {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await pumpFrames(tester, times: 4);
  }

  testWidgets('慢解析：按下 hero 播放后下一帧就有等待反馈', (tester) async {
    await pumpDetail(tester);
    expect(find.byKey(_heroPlayKey), findsOneWidget, reason: '前置条件：hero 有播放入口');

    await tester.tap(find.byKey(_heroPlayKey));
    // 只推一帧：反馈必须在**下一帧**就可见，不能等解析回来。
    await tester.pump();

    expect(state.resolutions, 1, reason: '解析已经开始');
    expect(
      find.byKey(_feedbackKey),
      findsOneWidget,
      reason: '解析在途时必须有可见反馈（用户反馈「点了没反应」的成因）',
    );
    expect(find.byType(PlayerPage), findsNothing, reason: '解析未回来时不得提前进入播放器');

    await settlePending(tester);
  });

  testWidgets('hero 按钮与剧集卡共享本页防重入：连点只解析一次', (tester) async {
    await pumpDetail(tester);

    await tester.tap(find.byKey(_heroPlayKey));
    await tester.pump();
    expect(state.resolutions, 1);

    // 同一入口连点。
    await tester.tap(find.byKey(_heroPlayKey));
    await tester.pump();
    expect(state.resolutions, 1, reason: '等待中重复点 hero 不得再次解析');
    expect(
      find.byKey(_feedbackKey),
      findsOneWidget,
      reason: '等待中反馈必须一直在（不能因为第二次点击就消失）',
    );

    // 换到另一个入口（剧集卡）再点：仍在等待，必须被同一个防重入挡住。
    await scrollPastHero(tester);
    final card = find.byKey(_episodeCardKey);
    expect(card, findsOneWidget, reason: '前置条件：剧集卡可达');
    await tester.ensureVisible(card);
    await pumpFrames(tester, times: 3);
    await tester.tap(card);
    await pumpFrames(tester, times: 3);

    expect(state.resolutions, 1, reason: '本页所有播放入口共享防重入：等待中第二次点击不得再发起解析');

    await settlePending(tester);
  });

  testWidgets('解析成功进入播放器；返回后反馈不残留且可再次播放', (tester) async {
    await pumpDetail(tester);
    await tester.tap(find.byKey(_heroPlayKey));
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsOneWidget);

    state.pending.last.complete(
      const PlaybackDecision(
        action: PlaybackAction.direct,
        url: 'http://127.0.0.1:1/media/a.mp4',
      ),
    );
    await pumpFrames(tester);

    expect(find.byType(PlayerPage), findsOneWidget, reason: '解析成功应进入播放器');
    expect(
      find.byKey(_feedbackKey),
      findsNothing,
      reason: '导航前必须收掉反馈，否则会盖在播放器首帧上',
    );

    // 返回详情页：反馈与防重入状态都必须复位。
    Navigator.of(tester.element(find.byType(PlayerPage))).pop();
    await pumpFrames(tester);
    expect(find.byType(PlayerPage), findsNothing);
    expect(find.byKey(_feedbackKey), findsNothing, reason: '返回后不得残留反馈');

    expect(find.byKey(_heroPlayKey), findsOneWidget);
    await tester.tap(find.byKey(_heroPlayKey));
    await tester.pump();
    expect(state.resolutions, 2, reason: '返回后再次点击应重新解析');
    expect(find.byKey(_feedbackKey), findsOneWidget);

    await settlePending(tester);
  });

  testWidgets('解析失败收起反馈并给错误，且可立即重试', (tester) async {
    await pumpDetail(tester);
    await tester.tap(find.byKey(_heroPlayKey));
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsOneWidget);

    // 用「用户在站点里主动中断」：这条失败只推通知，不弹换源确认框。
    state.pending.last.completeError(
      AppError(AppErrorKind.siteCancelled, '用户在站点里中断了播放'),
    );
    await pumpFrames(tester);

    expect(
      find.byKey(_feedbackKey),
      findsNothing,
      reason: '失败后必须收起等待反馈，否则用户以为还在等',
    );
    expect(find.byType(PlayerPage), findsNothing, reason: '失败不得进入播放器');

    // 失败后入口仍可点：重试一次必须真的重新解析。
    await tester.tap(find.byKey(_heroPlayKey));
    await tester.pump();
    expect(state.resolutions, 2, reason: '失败后必须能重试');
    expect(find.byKey(_feedbackKey), findsOneWidget);

    await settlePending(tester);
  });

  testWidgets('等待中离开详情页：反馈立即收掉，迟到成功不得 push 播放器', (tester) async {
    await pumpDetail(tester);
    await tester.tap(find.byKey(_heroPlayKey));
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsOneWidget);

    // 用户离开详情页（整棵子树被替换）。
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('别处'))),
    );
    await tester.pump();
    expect(find.byKey(_feedbackKey), findsNothing, reason: '详情页卸载后反馈必须立即收掉');

    // 迟到的解析成功不得把播放器推到别处。
    state.pending.last.complete(
      const PlaybackDecision(
        action: PlaybackAction.direct,
        url: 'http://127.0.0.1:1/media/a.mp4',
      ),
    );
    await pumpFrames(tester);

    expect(find.byType(PlayerPage), findsNothing, reason: '离页后不得 push 播放器');
    expect(find.text('别处'), findsOneWidget, reason: '用户应仍停留在离开后的页面');
  });

  for (final reduce in [
    const {'disableAnimations': true},
    const {'accessibleNavigation': true},
  ]) {
    testWidgets('减动态（$reduce）：反馈仍必须可见', (tester) async {
      await pumpDetail(
        tester,
        disableAnimations: reduce['disableAnimations'] ?? false,
        accessibleNavigation: reduce['accessibleNavigation'] ?? false,
      );
      await tester.tap(find.byKey(_heroPlayKey));
      await tester.pump();

      expect(
        find.byKey(_feedbackKey),
        findsOneWidget,
        reason: '减动态不等于没有反馈——反馈是动作确认，必须保留',
      );

      await settlePending(tester);
    });
  }

  // ---------------------------------------------------------------------------
  // 真实换源 → 自动续播：反馈的 owner 交接与取消
  // ---------------------------------------------------------------------------

  Future<void> prepareSwapConfig(WidgetTester tester) async {
    await tester.runAsync(() async {
      final ok = await state.importConfig(_swapConfigJson);
      expect(ok, isTrue, reason: '配置导入应成功');
      // 第 1 次解析如实失败 → 弹出换源确认框；第 2 次（续播）挂起。
      state.failFirstPlayback = true;
    });
  }

  Vod swapVod() => Vod(
    vodId: 'main-1',
    vodName: '换源目标影片',
    vodPlayFrom: 'orig',
    vodPlayUrl: '原第1集\$http://127.0.0.1:1/media/a1.mp4#原第2集\$http://127.0.0.1:1/media/a2.mp4',
  );

  Future<void> pumpSwapDetail(WidgetTester tester) async {
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester);
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            DetailPage(state: state, vod: swapVod()),
            const ToastHost(),
          ],
        ),
      ),
    );
    await pumpFrames(tester);
  }

  /// 点第 2 集 → 失败 → 确认换源 → 走真实浮层并入（续播随即开始）。
  Future<void> swapAndMerge(WidgetTester tester) async {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await pumpFrames(tester, times: 4);
    final card = find.byKey(const ValueKey('tmdb-episode-card-orig-1'));
    expect(card, findsOneWidget, reason: '前置条件：第 2 集卡片可达');
    await tester.ensureVisible(card);
    await pumpFrames(tester, times: 3);
    await tester.tap(card);
    await pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('detail-playback-failed')),
      findsOneWidget,
      reason: '前置条件：解析失败弹出换源确认框',
    );
    await tester.tap(find.byKey(const ValueKey('detail-playback-failed-swap')));
    await pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsOneWidget,
      reason: '前置条件：换源浮层已打开',
    );

    await tester.tap(
      find.byKey(const ValueKey('source-swap-check-ui-swap-swap-1')),
    );
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpFrames(tester);
    expect(find.textContaining('2 集'), findsWidgets, reason: '候选应解析出 2 集');
    // 错误通知驻留右下角，正好压在浮层底部按钮上：按用户会做的动作先收走。
    dismissAllToasts();
    await pumpFrames(tester, times: 2);
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpFrames(tester);
  }

  testWidgets('换源自动续播：等待期间必须有可见反馈，且同页防重入仍有效', (tester) async {
    await prepareSwapConfig(tester);
    await pumpSwapDetail(tester);
    await swapAndMerge(tester);

    expect(state.resolutions, 2, reason: '第 1 次解析失败、第 2 次是换源后的自动续播');
    expect(
      find.byKey(_feedbackKey),
      findsOneWidget,
      reason: '自动续播同样是网络解析，等待期必须可见反馈（不能靠豁免守卫绕过）',
    );
    expect(find.byType(PlayerPage), findsNothing, reason: '解析未回来不得进播放器');

    final otherCard = find.byKey(const ValueKey('tmdb-episode-card-orig-0'));
    if (otherCard.evaluate().isNotEmpty) {
      await tester.tap(otherCard);
      await pumpFrames(tester, times: 3);
      expect(state.resolutions, 2, reason: '等待中重复入口不得再次解析');
    }

    await settlePending(tester);
  });

  testWidgets('换源自动续播在途中被别的路由覆盖：迟到成功不 push', (tester) async {
    await prepareSwapConfig(tester);
    await pumpSwapDetail(tester);
    await swapAndMerge(tester);
    expect(find.byKey(_feedbackKey), findsOneWidget);
    dismissAllToasts();

    final navigator = Navigator.of(tester.element(find.byType(DetailPage)));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('另一页')),
      ),
    );
    await pumpFrames(tester);
    expect(find.text('另一页'), findsOneWidget);
    expect(find.byKey(_feedbackKey), findsNothing, reason: '被覆盖后反馈必须立即收掉');

    state.pending.last.complete(
      const PlaybackDecision(
        action: PlaybackAction.direct,
        url: 'http://127.0.0.1:1/media/e2.mp4',
      ),
    );
    await pumpFrames(tester);
    expect(find.byType(PlayerPage), findsNothing, reason: '被覆盖后不得迟到 push');
    expect(find.text('另一页'), findsOneWidget);
  });

  testWidgets('换源自动续播在途中被覆盖后抛错：不推通知也不弹确认框', (tester) async {
    await prepareSwapConfig(tester);
    await pumpSwapDetail(tester);
    await swapAndMerge(tester);
    dismissAllToasts();

    final navigator = Navigator.of(tester.element(find.byType(DetailPage)));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('另一页')),
      ),
    );
    await pumpFrames(tester);

    state.pending.last.completeError(
      AppError(AppErrorKind.playbackUrlMissing, '迟到的播放地址缺失'),
    );
    await pumpFrames(tester);

    expect(toastCenter.toasts, isEmpty, reason: '旧页被覆盖后不得把错误推成通知');
    expect(
      find.byKey(const ValueKey('detail-playback-failed')),
      findsNothing,
      reason: '旧页被覆盖后不得弹换源确认框',
    );
    expect(find.text('另一页'), findsOneWidget);
  });
}

/// 换源流程的假站点客户端：搜索与探测都走这里，不碰真实 socket。
class _SwapClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final query = request.url.queryParameters;
    Map<String, Object?> payload;
    if (query['wd'] != null) {
      payload = {
        'page': 1,
        'pagecount': 1,
        'limit': 20,
        'total': 1,
        'list': [
          {
            'vod_id': 'swap-1',
            'vod_name': '换源目标影片',
            'vod_pic': '',
            'vod_remarks': '',
          },
        ],
      };
    } else if (query['ac'] == 'detail') {
      payload = query['ids'] == 'swap-1'
          ? {
              'list': [
                {
                  'vod_id': 'swap-1',
                  'vod_name': '换源目标影片',
                  'vod_play_from': 'ext',
                  'vod_play_url': '换源第1集\$http://127.0.0.1:1/media/e1.mp4#换源第2集\$http://127.0.0.1:1/media/e2.mp4',
                },
              ],
            }
          : {'list': []};
    } else {
      payload = {'list': []};
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
    );
  }
}
