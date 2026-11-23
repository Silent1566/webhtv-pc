/// 播放器侧接线：本集的两条弹幕源必须原样出现在弹层的「弹幕源」页签。
///
/// 为什么不复用 support/player_page_harness.dart 的 pumpPlayerPage：那个
/// helper 把 PlaybackRequest 写死成无弹幕的 fixture，且 harness 不在本轮
/// Boundary 内；这里只复制它的启动顺序（临时配置目录、AppState bootstrap、
/// media_kit/window_manager mock），请求体换成带两条 danmaku 的版本。
library;

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
const _liveUrl = 'ws://127.0.0.1:9/live';
const _defaultSources = <DanmakuSource>[
  DanmakuSource(url: _urlA, name: '源一'),
  DanmakuSource(url: _urlB, name: '源二'),
];

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
    find.descendant(of: row, matching: find.text('当前在用'));

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
    await _pumpPlayerWithSources(
      tester,
      sources: const [
        DanmakuSource(url: _urlB, name: '点播源'),
        DanmakuSource(url: _liveUrl, name: '直播源'),
      ],
    );
    await _openSourcesTabFromMenu(tester);

    final pointRow = find.byKey(const ValueKey('player-danmaku-source-$_urlB'));
    final liveRow = find.byKey(
      const ValueKey('player-danmaku-source-$_liveUrl'),
    );
    expect(pointRow, findsOneWidget);
    expect(liveRow, findsOneWidget);

    await tester.ensureVisible(liveRow);
    await settlePlayerPage(tester, times: 2);
    await tester.tap(liveRow);
    // WebSocket 握手是真实 I/O，FakeAsync 的 pump 推不动；给 runAsync 一个
    // 真实事件循环窗口，让 127.0.0.1:9 的拒绝快速走完再断言弹层状态。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await settlePlayerPage(tester, times: 8);
    // 127.0.0.1:9 必然握手失败：不能把失败写成「当前在用」。
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
    await settlePlayerPage(tester, times: 2);
    await tester.tap(pointRow);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await settlePlayerPage(tester, times: 8);
    expect(_currentWithin(liveRow), findsNothing);
    expect(
      find.descendant(of: liveRow, matching: find.textContaining('连接失败：')),
      findsNothing,
    );
    expect(
      find.descendant(of: liveRow, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });
}
