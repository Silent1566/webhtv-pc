/// 推送详情页：先看清是什么，再决定播不播（用户 2026-11-21 决策）。
///
/// 锁定的行为：
/// 1. 远程地址：剧名 + 地址 + 「播放 / 匹配元数据 / 用剧名搜索站点」；
/// 2. 网盘分享链给出明确提示（PC 不能把分享页当视频播），普通地址不提示；
/// 3. 有匹配结论时展示标题/副标题，按钮变「修改匹配」；
/// 4. 「用剧名搜索站点」进入搜索页；
/// 5. 「播放」才构造播放页（无 libmpv 时 skip）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/push_parser.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/meta_match_dialog.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/poster_image.dart';
import 'package:webhtv_pc/ui/push_detail_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

import 'support/detail_test_seams.dart';
import 'support/libmpv_guard.dart';
import 'support/player_page_harness.dart';
import 'support/widget_settle.dart';


/// 外部元数据补全在测试里会留下定时器：用既有接缝整片关掉。
class _PushSiteAppState extends AppState with ExternalMetaOff {
  _PushSiteAppState({super.paths, super.log});

  /// 配置里那条「推送」源（安卓 SiteApi.PUSH 的 PC 对应物）。
  static final Site pushSite = Site(
    key: pushSiteKey,
    name: '推送',
    type: 1,
    api: 'http://127.0.0.1:1/vod',
  );

  Site? _selectedOverride;

  @override
  Site? get selectedSite => _selectedOverride ?? super.selectedSite;

  @override
  Site? siteInActiveSource(String siteKey) =>
      siteKey == pushSiteKey ? pushSite : super.siteInActiveSource(siteKey);

  /// 测试里不真的切站点：selectSite 会去拉站点首页（真实网络/流程），
  /// 而本用例只钉「推送落点是不是普通详情页」。
  @override
  Future<void> selectSite(Site site) async {
    _selectedOverride = site;
  }
}

PlaybackRequest pushRequestFixture() => pushPlaybackRequest(
  parsed: parsePushFields(
    url: 'https://cdn.example/a.m3u8',
    title: '庆余年',
  ),
);

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-push-detail');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  PlaybackRequest remoteRequest(String url, {String title = '庆余年'}) =>
      pushPlaybackRequest(
        parsed: parsePushFields(url: url, title: title),
      );

  Future<void> pumpPage(
    WidgetTester tester,
    PlaybackRequest request, {
    bool withToastHost = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final page = PushDetailPage(state: state, request: request);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        // 提示走全局 ToastCenter：不挂宿主就什么都看不到。
        home: withToastHost
            ? Stack(children: [page, const ToastHost()])
            : page,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('远程地址：剧名/地址/三个动作都在，且不自动起播', (tester) async {
    await pumpPage(tester, remoteRequest('https://cdn.example/a.m3u8'));

    expect(find.text('推送详情'), findsOneWidget);
    expect(find.text('庆余年'), findsOneWidget);
    expect(find.text('https://cdn.example/a.m3u8'), findsOneWidget);
    expect(find.byKey(const ValueKey('push-detail-play')), findsOneWidget);
    expect(find.byKey(const ValueKey('push-detail-match')), findsOneWidget);
    expect(find.byKey(const ValueKey('push-detail-search')), findsOneWidget);
    expect(find.byType(PlayerPage), findsNothing, reason: '先详情后播放');
    expect(find.byKey(const ValueKey('push-detail-pan-hint')), findsNothing);
  });

  testWidgets('网盘分享链给出明确提示', (tester) async {
    await pumpPage(
      tester,
      remoteRequest('https://pan.baidu.com/s/16oztu4ZXEg6ZbN586Ji_Yw?pwd=wnsu'),
    );
    expect(find.byKey(const ValueKey('push-detail-pan-hint')), findsOneWidget);
    expect(find.textContaining('网盘分享链接'), findsOneWidget);
  });

  testWidgets('有匹配结论时展示副标题，按钮变「修改匹配」', (tester) async {
    await state.saveTmdbConfig(
      const TmdbConfig(enabled: true, apiKey: 'fixture-key', disabledSites: []),
    );
    await state.manualMatchPush(
      vodId: 'https://cdn.example/a.m3u8',
      title: '庆余年',
      item: const TmdbItem(
        tmdbId: 95396,
        mediaType: TmdbMediaType.tv,
        title: '庆余年',
        subtitle: '2019 · 8.1',
        posterUrl: 'https://img.example/qingyu.jpg',
      ),
    );
    await pumpPage(tester, remoteRequest('https://cdn.example/a.m3u8'));

    expect(find.text('2019 · 8.1'), findsOneWidget);
    expect(find.text('修改匹配'), findsOneWidget);
    final poster = tester.widget<PosterImage>(find.byType(PosterImage));
    expect(poster.url, 'https://img.example/qingyu.jpg');
  });

  testWidgets('「用剧名搜索站点」进入搜索页', (tester) async {
    await pumpPage(tester, remoteRequest('https://cdn.example/a.m3u8'));
    await tester.tap(find.byKey(const ValueKey('push-detail-search')));
    await tester.pumpAndSettle();

    expect(find.text('搜索：庆余年'), findsOneWidget);
  });

  testWidgets('TMDB 未配置时点匹配给出明确提示', (tester) async {
    expect(state.tmdbConfig.isReady, isFalse, reason: '本用例走"未配置"分支');
    await pumpPage(
      tester,
      remoteRequest('https://cdn.example/a.m3u8'),
      withToastHost: true,
    );
    await tester.tap(find.byKey(const ValueKey('push-detail-match')));
    // 不能用 pumpAndSettle：通知自带 30 秒倒计时动画，它会一直排帧，settle 会把
    // 倒计时走完、通知自动退场——于是"有没有提示"永远断言不到。
    await tester.pump();
    expect(find.byType(MetaMatchDialog), findsNothing, reason: '未配置不该弹匹配框');
    // 提示走全局 ToastCenter：直接读它，比依赖 ToastHost 的布局更稳。
    expect(
      toastCenter.toasts.map((toast) => toast.message).join(),
      contains('TMDB 未配置'),
    );
    for (final toast in toastCenter.toasts.toList()) {
      dismissToast(toast.id);
    }
    await tester.pumpAndSettle();
  });

  testWidgets('本地文件：显示路径且无网盘提示', (tester) async {
    final path = '${tempDir.path}${Platform.pathSeparator}本地片.mkv';
    File(path).createSync();
    await pumpPage(
      tester,
      pushPlaybackRequest(
        parsed: parsePushFields(url: path, title: '阿凡达'),
        localPath: path,
      ),
    );
    expect(find.text('本地文件'), findsOneWidget);
    expect(find.text(path), findsOneWidget);
    expect(find.byKey(const ValueKey('push-detail-pan-hint')), findsNothing);
  });

  testWidgets('点「播放」才构造播放页', skip: libmpvUnavailableReason != null, (tester) async {
    installMediaKitMocks(tester);
    await pumpPage(tester, remoteRequest('https://cdn.example/a.m3u8'));
    await tester.tap(find.byKey(const ValueKey('push-detail-play')));
    await settlePlayerPage(tester, times: 6);
    expect(find.byType(PlayerPage), findsOneWidget);
    final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(page.request.siteKey, pushSiteKey);
  });

  group('推送落点（先详情后播放）', () {
    PlaybackRequest request() => pushPlaybackRequest(
      parsed: parsePushFields(
        url: 'https://cdn.example/a.m3u8',
        title: '庆余年',
      ),
    );

    Future<void> pumpLauncher(WidgetTester tester, PlaybackRequest req) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const ValueKey('launch-push'),
                  onPressed: () => openPushLanding(context, state, req),
                  child: const Text('push'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('launch-push')));
      await settle(tester);
    }

    testWidgets('没有匹配结论 → 极简推送页兜底', (tester) async {
      await pumpLauncher(tester, request());
      expect(find.byType(PushDetailPage), findsOneWidget);
      expect(find.byKey(const ValueKey('push-detail-play')), findsOneWidget);
    });

  });

  group('配置里有推送源（安卓 push_agent 契约）', () {
    late Directory siteTemp;
    late _PushSiteAppState siteState;

    // bootstrap/删目录都是真实 I/O：只能在 testWidgets 之外的 zone 里做，
    // 否则 fake-async 等不到完成（此前这里把用例挂成了 10 分钟超时）。
    setUp(() async {
      siteTemp = await Directory.systemTemp.createTemp('webhtv-push-site');
      siteState = _PushSiteAppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${siteTemp.path}/webhtv-pc',
            'data': '${siteTemp.path}/webhtv-pc',
            'cache': '${siteTemp.path}/webhtv-pc/cache',
            'state': '${siteTemp.path}/webhtv-pc/logs',
          },
        ),
        log: MemoryOnlyLogService(),
      );
      await bootstrapWithoutExternalMeta(siteState);
    });

    tearDown(() async {
      siteState.dispose();
      try {
        await siteTemp.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets('推送 → 选中该源并进普通详情页，而不是兜底页', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const ValueKey('launch-push-site'),
                  onPressed: () =>
                      openPushLanding(context, siteState, pushRequestFixture()),
                  child: const Text('push'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('launch-push-site')));
      // 详情页会自己去拉源（本用例没有真实站点）：只推进有限帧，不断言加载结果。
      for (var round = 0; round < 20; round++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }

      expect(
        siteState.selectedSite?.key,
        pushSiteKey,
        reason: '与安卓一致：推送就是把 push_agent 站点选中',
      );
      expect(find.byType(DetailPage), findsOneWidget);
      expect(find.byType(PushDetailPage), findsNothing, reason: '有源就不该用兜底页');
    });
  });
}
