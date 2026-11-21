/// 本地文件播放（Wave 1）：请求语义、命令行形态与应用入口。
///
/// ## 锁定的行为
/// 1. `PlaybackRequest.localFile` 的本地源语义：`url == localPath`、无 Header、
///    不参与站点解析与跨源续播；
/// 2. `copyWith` 不会把本地请求悄悄降级成 remote；
/// 3. 命令行：`--media=<绝对路径>` 与裸绝对路径（拖文件到 exe）都识别为本地媒体；
/// 4. 顶栏只有「推送」：本地文件从推送对话框里选，仍交给**既有**播放器入口
///    （不改 player_page）。「打开本地文件」入口已删除（用户 2026-11-20 决策）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/push_detail_page.dart';
import 'package:webhtv_pc/ui/startup_arguments.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/libmpv_guard.dart';
import 'support/player_page_harness.dart';
import 'support/widget_settle.dart';

void main() {
  group('本地播放请求', () {
    test('url 与 localPath 一致，且不带任何站点上下文', () {
      const path = r'D:\电影\阿凡达 2009.mkv';
      final request = PlaybackRequest.localFile(path: path);
      expect(request.isLocal, isTrue);
      expect(request.sourceKind, PlaybackSourceKind.local);
      expect(request.localPath, path);
      expect(
        request.url,
        path,
        reason: '播放器页直接 open(request.url)，两者分叉本地文件就打不开',
      );
      expect(request.headers, isEmpty);
      expect(request.subtitleHeaders, isEmpty, reason: '本地文件不注入 Header');
      expect(request.parseSources, isEmpty);
      expect(request.parseSource, '');
      expect(request.playLines, isEmpty);
      expect(request.lineRoutes, isEmpty);
      expect(request.episodeCardsByFlag, isEmpty);
      expect(request.resumeSeed, isNull, reason: '本地文件不参与跨源续播');
      expect(
        request.directUrl,
        isFalse,
        reason: 'directUrl 在播放器页等价于「直播」，借用它会让进度条消失',
      );
      expect(request.episodeTarget, path);
      expect(request.siteKey, PlaybackRequest.localSiteKey);
      expect(request.flag, PlaybackRequest.localSourceFlag);
    });

    test('标题取文件名去掉扩展名，集名保留完整文件名', () {
      final request = PlaybackRequest.localFile(path: '/mnt/videos/阿凡达.2009.mkv');
      expect(request.title, '阿凡达.2009');
      expect(request.vodName, '阿凡达.2009');
      expect(request.episodeName, '阿凡达.2009.mkv');
    });

    test('显式标题优先', () {
      final request = PlaybackRequest.localFile(
        path: '/mnt/videos/a.mkv',
        title: '  我的片子  ',
      );
      expect(request.title, '我的片子');
      expect(request.vodName, '我的片子');
    });

    test('空路径当场拒绝，不产出半成品请求', () {
      expect(() => PlaybackRequest.localFile(path: '   '), throwsArgumentError);
    });

    test('copyWith 不会把本地请求降级成 remote', () {
      final request = PlaybackRequest.localFile(
        path: '/mnt/videos/a.mkv',
      ).copyWith(
        url: '/mnt/videos/a.mkv',
        startPosition: const Duration(seconds: 30),
      );
      expect(request.isLocal, isTrue);
      expect(request.sourceKind, PlaybackSourceKind.local);
      expect(request.localPath, '/mnt/videos/a.mkv');
      expect(request.startPosition, const Duration(seconds: 30));
    });

    test('远程请求默认不是本地', () {
      const remote = PlaybackRequest(
        url: 'https://cdn.example/a.m3u8',
        title: '示例',
        siteKey: 's',
        vodId: 'v',
        vodName: '示例',
        episodeName: 'E1',
        flag: '线路一',
      );
      expect(remote.isLocal, isFalse);
      expect(remote.sourceKind, PlaybackSourceKind.remote);
      expect(remote.localPath, '');
    });
  });

  group('命令行参数', () {
    test('裸绝对路径当媒体，且标为本地（拖文件到 exe）', () {
      final args = StartupArguments.parse([r'D:\电影\a.mkv']);
      expect(args.media, r'D:\电影\a.mkv');
      expect(args.mediaIsLocal, isTrue);
    });

    test('--media=<本地路径> 同样标为本地', () {
      final args = StartupArguments.parse([r'--media=/mnt/videos/a.mkv']);
      expect(args.media, '/mnt/videos/a.mkv');
      expect(args.mediaIsLocal, isTrue);
    });

    test('--media=<远程地址> 不是本地', () {
      final args = StartupArguments.parse([
        '--media=https://cdn.example/a.m3u8',
      ]);
      expect(args.mediaIsLocal, isFalse);
    });

    test('相对路径参数不被误当成待播文件', () {
      final args = StartupArguments.parse([
        'test/foo_test.dart',
        '--fullscreen=true',
      ]);
      expect(args.media, isNull);
      expect(args.fullscreen, isTrue);
    });
  });
  group('应用入口（顶栏「推送」→ 选择本地文件）', () {
    late Directory tempDir;
    late AppState state;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('webhtv-local-file');
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

    /// 挂起壳层并越过首次启动的边界确认弹窗。
    Future<void> mountShell(
      WidgetTester tester,
      Future<String?> Function() pickLocalFile,
    ) async {
      // 本机没有 libmpv 时 installMediaKitMocks 会直接抛：只有真正打开播放页的
      // 用例才需要它（那条自己也带了 skip）。
      if (libmpvUnavailableReason == null) installMediaKitMocks(tester);
      installWindowManagerMocks(tester);
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: AppShell(
            state: state,
            startup: const StartupArguments(),
            pickLocalMediaFile: pickLocalFile,
          ),
        ),
      );
      await settle(tester);
      final accept = find.text('我已了解并继续');
      if (accept.evaluate().isNotEmpty) {
        await tester.tap(accept);
        await tester.pumpAndSettle();
      }
    }

    testWidgets('选中的文件被包成本地请求并进入推送详情页', (tester) async {
      final path = '${tempDir.path}${Platform.pathSeparator}本地片.mkv';
      File(path).createSync();
      final picked = <String?>[];
      await mountShell(tester, () async {
        picked.add(path);
        return path;
      });

      final entry = find.byKey(const ValueKey('topbar-push'));
      expect(entry, findsOneWidget, reason: '本地视频能力仍在顶栏（经推送对话框）');
      expect(
        find.byKey(const ValueKey('topbar-open-local-file')),
        findsNothing,
        reason: '旧入口已并入推送对话框',
      );
      await tester.tap(entry);
      await settle(tester);
      final pick = find.byKey(const ValueKey('push-dialog-pick-file'));
      expect(pick, findsOneWidget, reason: '推送对话框必须自带本地文件入口');
      await tester.tap(pick);
      await settle(tester);

      expect(picked, [path], reason: '点击入口必须真的走文件选择器');
      expect(find.byType(PushDetailPage), findsOneWidget, reason: '先详情后播放');
      final detail = tester.widget<PushDetailPage>(find.byType(PushDetailPage));
      expect(detail.request.isLocal, isTrue);
      expect(detail.request.localPath, path);
      expect(detail.request.url, path);
      expect(detail.request.headers, isEmpty);
      expect(state.pendingPush, isNull);
    });

    // 这条真正构造 PlayerPage（初始化原生解码器）：没有 libmpv 时跳过而不是报错。
    testWidgets('详情页点「播放」才交给既有播放器入口', skip: libmpvUnavailableReason != null, (tester) async {
      final path = '${tempDir.path}${Platform.pathSeparator}本地片.mkv';
      File(path).createSync();
      await mountShell(tester, () async => path);

      await tester.tap(find.byKey(const ValueKey('topbar-push')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('push-dialog-pick-file')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('push-detail-play')));
      await settlePlayerPage(tester, times: 6);

      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(page.request.isLocal, isTrue);
      expect(page.request.localPath, path);
      expect(page.request.url, path);
      expect(page.request.headers, isEmpty);
    });

    testWidgets('取消选择不打开详情页', (tester) async {
      await mountShell(tester, () async => null);

      await tester.tap(find.byKey(const ValueKey('topbar-push')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('push-dialog-pick-file')));
      await settle(tester);
      expect(find.byType(PushDetailPage), findsNothing);
      expect(find.byType(PlayerPage), findsNothing);
      expect(
        find.byKey(const ValueKey('push-dialog')),
        findsOneWidget,
        reason: '取消选择只是不落地，对话框不该跟着关掉',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
