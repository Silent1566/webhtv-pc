/// 播放器侧接线：本集的两条弹幕源必须原样出现在弹层的「弹幕源」页签。
///
/// 为什么不复用 support/player_page_harness.dart 的 pumpPlayerPage：那个
/// helper 把 PlaybackRequest 写死成无弹幕的 fixture，且 harness 不在本轮
/// Boundary 内；这里只复制它的启动顺序（临时配置目录、AppState bootstrap、
/// media_kit/window_manager mock），请求体换成带两条 danmaku 的版本。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/player_page_harness.dart';

const _urlA = 'https://a.test/danmaku/one.xml';
const _urlB = 'https://b.test/danmaku/two.xml';
const _defaultSources = <DanmakuSource>[
  DanmakuSource(url: _urlA, name: '源一'),
  DanmakuSource(url: _urlB, name: '源二'),
];

class _LoopbackHttpOverrides extends HttpOverrides {
  final _clients = <HttpClient>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context)
      ..findProxy = (uri) {
        if (uri.host != InternetAddress.loopbackIPv4.address) {
          throw SocketException('Non-loopback request blocked: $uri');
        }
        return 'DIRECT';
      };
    _clients.add(client);
    return client;
  }

  void close() {
    for (final client in _clients) {
      client.close(force: true);
    }
  }
}

class _HandshakeRejectServer {
  _HandshakeRejectServer(this._server) {
    _subscription = _server.listen(_reject);
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  final requested = Completer<Uri>();
  final responseSent = Completer<void>();
  final _release = Completer<void>();

  String get url => 'ws://127.0.0.1:${_server.port}/live?token=raw-address';

  static Future<_HandshakeRejectServer> start() async => _HandshakeRejectServer(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  Future<void> _reject(HttpRequest request) async {
    if (!requested.isCompleted) requested.complete(request.uri);
    await _release.future;
    request.response
      ..statusCode = HttpStatus.forbidden
      ..write('fixture handshake rejected');
    await request.response.close();
    if (!responseSent.isCompleted) responseSent.complete();
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  Future<void> close() async {
    release();
    await _server.close(force: true);
    await _subscription.cancel();
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() completed, {
  required String reason,
}) async {
  final elapsed = Stopwatch()..start();
  // 网络事件与页面回调分别需要真实事件循环和 FakeAsync 微任务/定时器。
  while (!completed() && elapsed.elapsed < const Duration(seconds: 3)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(completed(), isTrue, reason: reason);
}

Finder _loadingWithin(Finder row) => find.descendant(
  of: row,
  matching: find.byKey(const ValueKey('player-danmaku-source-loading')),
);

Future<void> _waitForSourceSelection(WidgetTester tester, Finder row) async {
  await _pumpUntil(
    tester,
    () => _loadingWithin(row).evaluate().isEmpty,
    reason: '选择源回调未完成',
  );
  // 回调会排入零延迟日志刷盘；再推进一毫秒清理已到期事件。
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> _pumpPlayerWithSources(
  WidgetTester tester, {
  List<DanmakuSource> sources = _defaultSources,
}) async {
  final temp = Directory.systemTemp.createTempSync('danmaku-source-tab-player');
  addTearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });
  final paths = AppPaths.resolve(
    overrides: {
      'config': '${temp.path}/webhtv-pc',
      'data': '${temp.path}/webhtv-pc',
      'cache': '${temp.path}/webhtv-pc/cache',
      'state': '${temp.path}/webhtv-pc/logs',
    },
  );
  final state = AppState(paths: paths, log: LogService());
  addTearDown(state.dispose);
  await tester.runAsync(state.bootstrap);

  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  installMediaKitMocks(tester);
  installWindowManagerMocks(tester);

  await tester.pumpWidget(
    RepaintBoundary(
      key: playerPageCaptureRootKey,
      child: MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: 'http://127.0.0.1:9/never.m3u8',
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E3',
              flag: '线路一',
              danmaku: sources,
            ),
          ),
        ),
      ),
    ),
  );
  await settlePlayerPage(tester);
}

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

Future<void> _openSourcesTabFromMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
  await settlePlayerPage(tester);
  expect(find.byType(PlayerContextMenu), findsOneWidget);
  await _drill(tester, '弹幕');

  final settingsItem = find.byKey(
    const ValueKey('player-menu-item-danmaku_settings'),
  );
  await tester.ensureVisible(settingsItem);
  await settlePlayerPage(tester, times: 2);
  await tester.tap(settingsItem);
  await settlePlayerPage(tester, times: 6);
  expect(find.byKey(const ValueKey('player-danmaku-sheet')), findsOneWidget);

  await tester.tap(find.byKey(const ValueKey('player-danmaku-tab-sources')));
  await settlePlayerPage(tester, times: 2);
}

Finder _currentWithin(Finder row) =>
    find.descendant(of: row, matching: find.textContaining('当前在用'));

void main() {
  testWidgets('本集两条弹幕源进入弹层的弹幕源页签', (tester) async {
    await _pumpPlayerWithSources(tester);
    await _openSourcesTabFromMenu(tester);
    expect(
      find.byKey(const ValueKey('player-danmaku-source-$_urlA')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-danmaku-source-$_urlB')),
      findsOneWidget,
    );
    expect(find.text('源一'), findsOneWidget);
    expect(find.text('源二'), findsOneWidget);
  });

  testWidgets('直播与点播互切后当前项跟随，直播不残留', (tester) async {
    final server = (await tester.runAsync(_HandshakeRejectServer.start))!;
    final liveUrl = server.url;
    final previousHttpOverrides = HttpOverrides.current;
    final loopbackHttpOverrides = _LoopbackHttpOverrides();
    try {
      await _pumpPlayerWithSources(
        tester,
        sources: [
          const DanmakuSource(url: _urlB, name: '点播源'),
          DanmakuSource(url: liveUrl, name: '直播源'),
        ],
      );
      await _openSourcesTabFromMenu(tester);

      final pointRow = find.byKey(
        const ValueKey('player-danmaku-source-$_urlB'),
      );
      final liveRow = find.byKey(ValueKey('player-danmaku-source-$liveUrl'));
      expect(pointRow, findsOneWidget);
      expect(liveRow, findsOneWidget);

      await tester.ensureVisible(liveRow);
      await settlePlayerPage(tester, times: 2);
      HttpOverrides.global = loopbackHttpOverrides;
      await tester.tap(liveRow);
      await tester.pump();
      await _pumpUntil(
        tester,
        () => server.requested.isCompleted,
        reason: '页面没有向本地服务发送 WebSocket 握手',
      );
      final requestedUri = await tester.runAsync(() => server.requested.future);
      expect(requestedUri.toString(), '/live?token=raw-address');
      expect(
        find.descendant(of: liveRow, matching: find.byTooltip(liveUrl)),
        findsOneWidget,
      );
      // 握手刻意晚于旧测试的 300ms 窗口；尚未响应时不能提前宣告当前源。
      await tester.pump(const Duration(milliseconds: 300));
      expect(_loadingWithin(liveRow), findsOneWidget);
      expect(server.responseSent.isCompleted, isFalse);
      expect(
        find.descendant(of: liveRow, matching: find.byIcon(Icons.check)),
        findsNothing,
      );
      server.release();
      await tester.runAsync(
        () => server.responseSent.future.timeout(const Duration(seconds: 3)),
      );
      await _waitForSourceSelection(tester, liveRow);
      // 真正的握手拒绝经页面回调交给弹层，不能把失败写成「当前在用」。
      expect(
        find.descendant(of: liveRow, matching: find.textContaining('连接失败：')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: liveRow, matching: find.byIcon(Icons.check)),
        findsNothing,
      );
      expect(_currentWithin(liveRow), findsNothing);
      expect(_currentWithin(pointRow), findsNothing);
      // 选中语义仍指向用户刚点的直播地址，便于重新打开时看到真实来源。
      expect(find.textContaining('当前弹幕：直播源'), findsOneWidget);

      await tester.ensureVisible(pointRow);
      await tester.pump();
      HttpOverrides.global = previousHttpOverrides;
      await tester.tap(pointRow);
      await tester.pump();
      await _waitForSourceSelection(tester, pointRow);
      expect(
        find.descendant(of: pointRow, matching: find.textContaining('加载失败：')),
        findsOneWidget,
      );
      expect(find.text('当前弹幕：未加载'), findsOneWidget);
      expect(
        find.descendant(
          of: liveRow,
          matching: find.textContaining(RegExp('连接中|已连接|重连中|已断开')),
        ),
        findsNothing,
      );
      expect(_currentWithin(liveRow), findsNothing);
      expect(
        find.descendant(of: liveRow, matching: find.textContaining('连接失败：')),
        findsNothing,
      );
      expect(
        find.descendant(of: liveRow, matching: find.byIcon(Icons.check)),
        findsNothing,
      );
    } finally {
      server.release();
      try {
        await _waitForSourceSelection(
          tester,
          find.byKey(ValueKey('player-danmaku-source-$liveUrl')),
        );
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 1));
        } finally {
          try {
            await tester.runAsync(server.close);
          } finally {
            loopbackHttpOverrides.close();
            HttpOverrides.global = previousHttpOverrides;
          }
        }
      }
    }
  });
}
