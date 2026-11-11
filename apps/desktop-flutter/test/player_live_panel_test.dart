import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/epg.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/player_live_panel.dart';
import 'package:webhtv_pc/ui/player_live_line_panel.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'live_playback_session_test.dart' show fixture;

void main() {
  testWidgets('分组以抽屉层级展开：选中分组后收起并显示该组频道', (tester) async {
    final f = fixture();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 560,
            child: PlayerLivePanel(
              session: f.session,
              onDismiss: () {},
              onLines: (_) {},
            ),
          ),
        ),
      ),
    );
    const groupList = ValueKey('player-live-group-list');
    expect(find.byKey(groupList), findsNothing);
    expect(
      find.byKey(const ValueKey('player-live-channel-list')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('player-live-group-toggle')));
    await tester.pump();
    expect(find.byKey(groupList), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-live-channel-list')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('player-live-group-2')));
    await tester.pump();
    expect(find.byKey(groupList), findsNothing);
    expect(f.session.browseGroup, '二组');
    expect(find.text('频道二'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('联动面板子控件获得焦点后Esc仍关闭面板', (tester) async {
    final f = fixture();
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerLivePanel(
            session: f.session,
            onDismiss: () => dismissed = true,
            onLines: (_) {},
          ),
        ),
      ),
    );
    Focus.of(tester.element(find.text('线路'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(dismissed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final size in [
    const Size(800, 600),
    const Size(1024, 640),
    const Size(1440, 900),
  ]) {
    testWidgets('覆盖抽屉在${size.width}展示实际播放态且候选不打断播放', (tester) async {
      final f = fixture();
      final second = LiveSource(name: '另一个很长名称的源' * 12, type: 1);
      final candidate = LiveChannel(
        name: '长名称频道' * 30,
        urls: [
          'https://fixture.test/${'long-url/' * 100}',
          'https://fixture.test/second',
        ],
      );
      f.state.sources = [...f.state.sources, second];
      f.service.loads[second.name] = () async => LivePlaylist(
        sourceName: second.name,
        groups: [
          LiveGroup(name: '长分组' * 20, channels: [candidate]),
        ],
      );
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      LiveChannel? openedLines;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: size.width,
                child: PlayerLivePanel(
                  session: f.session,
                  onDismiss: () {},
                  onLines: (channel) => openedLines = channel,
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is DropdownButton<LiveSource>,
        ),
        findsNothing,
      );
      final sourceList = find.byKey(const ValueKey('player-live-source-list'));
      final channelList = find.byKey(
        const ValueKey('player-live-channel-list'),
      );
      final detail = find.byKey(const ValueKey('player-live-channel-detail'));
      expect(sourceList, findsOneWidget);
      expect(channelList, findsOneWidget);
      expect(detail, findsOneWidget);
      expect(
        tester.getRect(sourceList).right,
        lessThanOrEqualTo(tester.getRect(channelList).left),
      );
      expect(
        tester.getRect(channelList).right,
        lessThanOrEqualTo(tester.getRect(detail).left),
      );
      await tester.tap(
        find.byKey(ValueKey('live-panel-source-${second.name}')),
      );
      await tester.pump();
      expect(find.text('正在播放 · 源一'), findsOneWidget);
      expect(f.session.request.title, 'CCTV-5');
      await tester.tap(
        find.byKey(const ValueKey('live-panel-channel-lines-0')),
      );
      expect(openedLines, candidate);
      await tester.pump();
      expect(sourceList, findsOneWidget);
      expect(channelList, findsOneWidget);
      expect(find.text('线路 2'), findsOneWidget);
      expect(find.byTooltip(candidate.urls[1]), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('live-panel-channel-0')));
      expect(f.session.request.title, candidate.name);
      expect(f.session.source.name, '源一');
      f.session.confirmPlayback(f.session.playbackRevision);
      await tester.pump();
      expect(find.text('正在播放 · ${second.name}'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('频道加载失败有重试，空清单不是无反馈', (tester) async {
    final f = fixture();
    final failed = LiveSource(name: '失败源', type: 1);
    f.service.loads[failed.name] = () async => throw StateError('网络错误');
    await f.session.browse(failed);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerLivePanel(
            session: f.session,
            onDismiss: () {},
            onLines: (_) {},
          ),
        ),
      ),
    );
    expect(find.textContaining('源加载失败'), findsOneWidget);
    f.service.loads[failed.name] = () async =>
        LivePlaylist(sourceName: failed.name);
    await tester.tap(find.text('重试加载源'));
    await tester.pump();
    expect(find.text('此源没有频道'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('线路面板选中线路清晰且完整URL通过tooltip可达', (tester) async {
    final f = fixture();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: PlayerLiveLinePanel(
              session: f.session,
              channel: f.session.channel,
              onDismiss: () {},
              onSelect: f.session.selectLine,
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('https://fixture.test/b'), findsOneWidget);
    final selected = tester.widget<ListTile>(
      find.byKey(const ValueKey('live-line-1')),
    );
    expect(selected.selected, isTrue);
    await tester.tap(find.byKey(const ValueKey('live-line-0')));
    expect(f.session.request.url, 'https://fixture.test/a');
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('节目单区分当前与已结束，只有已结束回看可选', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final current = EpgProgram(
      title: '当前节目',
      startMs: now - 1000,
      stopMs: now + 100000,
    );
    final past = EpgProgram(
      title: '过去节目',
      startMs: now - 100000,
      stopMs: now - 1000,
    );
    // 使用已有解析指南的公开入口，不修改会话内部状态。
    final guide = EpgGuide(
      channels: {
        'CCTV-5': EpgChannelGuide(
          channelId: 'CCTV-5',
          programs: [past, current],
        ),
      },
      totalPrograms: 2,
      skippedPrograms: 0,
      sourceName: '源一',
    );
    final withGuide = fixture(guide: guide).session;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerLivePanel(
            session: withGuide,
            onDismiss: () {},
            onLines: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('节目单'));
    await tester.pump();
    expect(find.textContaining('当前播出'), findsOneWidget);
    expect(find.textContaining('已结束'), findsOneWidget);
    expect(find.byTooltip('回看过去节目'), findsOneWidget);
    expect(find.byTooltip('回看当前节目'), findsNothing);
    await tester.tap(find.byTooltip('回看过去节目'));
    expect(withGuide.requestProgram, past);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
