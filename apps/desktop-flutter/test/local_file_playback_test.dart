/// 本地文件播放（Wave 1）：请求语义、命令行形态与应用入口。
///
/// ## 锁定的行为
/// 1. `PlaybackRequest.localFile` 的本地源语义：`url == localPath`、无 Header、
///    不参与站点解析与跨源续播；
/// 2. `copyWith` 不会把本地请求悄悄降级成 remote；
/// 3. 命令行：`--media=<绝对路径>` 与裸绝对路径（拖文件到 exe）都识别为本地媒体；
/// 4. 顶栏「打开本地文件」把本地请求交给**既有**播放器入口（不改 player_page）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/player_page.dart';
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

  group('应用入口（顶栏「打开本地文件」）', () {
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

    // 这条会真正构造 PlayerPage（初始化原生解码器）：没有 libmpv 时跳过而不是报错。
    testWidgets('选中的文件被包成本地请求并交给既有播放器入口', skip: libmpvUnavailableReason != null, (tester) async {
      final path = '${tempDir.path}${Platform.pathSeparator}本地片.mkv';
      File(path).createSync();
      final picked = <String?>[];
      installMediaKitMocks(tester);
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
            pickLocalMediaFile: () async {
              picked.add(path);
              return path;
            },
          ),
        ),
      );
      await settle(tester);
      final accept = find.text('我已了解并继续');
      if (accept.evaluate().isNotEmpty) {
        await tester.tap(accept);
        await tester.pumpAndSettle();
      }

      final entry = find.byKey(const ValueKey('topbar-open-local-file'));
      expect(entry, findsOneWidget, reason: '本地视频入口不能埋在站点/配置里');
      await tester.tap(entry);
      await settlePlayerPage(tester, times: 6);

      expect(picked, [path], reason: '点击入口必须真的走文件选择器');
      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(page.request.isLocal, isTrue);
      expect(page.request.localPath, path);
      expect(page.request.url, path);
      expect(page.request.headers, isEmpty);
    });

    testWidgets('取消选择不打开播放器', skip: libmpvUnavailableReason != null, (tester) async {
      installMediaKitMocks(tester);
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
            pickLocalMediaFile: () async => null,
          ),
        ),
      );
      await settle(tester);
      final accept = find.text('我已了解并继续');
      if (accept.evaluate().isNotEmpty) {
        await tester.tap(accept);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.byKey(const ValueKey('topbar-open-local-file')));
      await settlePlayerPage(tester, times: 2);
      expect(find.byType(PlayerPage), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
