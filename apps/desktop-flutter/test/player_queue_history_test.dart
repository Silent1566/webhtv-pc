import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'player_queue_test.dart' as fixture;

void main() {
  testWidgets(
    'file preparation saves paired old history before full identity replacement',
    (tester) async {
      final queue = fixture.QueueFixture();
      final mounted = await fixture.mountQueue(tester, queue: queue);
      mounted.media.progress(960);
      await tester.pump();
      final gate = Completer<PlaybackRequest>();
      queue.gates['opaque-file-B'] = gate;
      await fixture.selectQueueItem(tester, 'opaque-file-B');
      expect(mounted.state.writes.single, (
        vodId: 'real-vod-A',
        target: 'real-target-A',
        source: 'original-config',
        position: 960000,
      ));
      mounted.media.progress(980);
      await tester.pump(const Duration(seconds: 6));
      expect(mounted.state.writes.length, 1);
      gate.complete(fixture.fileRequest(1));
      await fixture.settleQueue(tester);
      mounted.media.progress(30);
      await tester.pump(const Duration(seconds: 6));
      expect(mounted.state.writes.last, (
        vodId: 'real-vod-B',
        target: 'real-target-B',
        source: 'original-config',
        position: 30000,
      ));
      expect(
        mounted.state.recentHistory().map((item) => item.vodId),
        containsAll(['real-vod-A', 'real-vod-B']),
      );
      await fixture.closeQueue(tester);
    },
  );
  testWidgets(
    'media failure retry resolves real current file entry and preserves paused position source',
    (tester) async {
      final mounted = await fixture.mountQueue(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await fixture.settleQueue(tester);
      mounted.media.progress(120, playing: false);
      await tester.pump();
      mounted.media.failOpen = true;
      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            state: mounted.state,
            request: fixture
                .fileRequest(1)
                .copyWith(startPosition: const Duration(seconds: 120)),
            queue: page.queue,
            queueItemKey: 'opaque-file-B',
          ),
        ),
      );
      await fixture.settleQueue(tester);
      mounted.media.failOpen = false;
      await tester.tap(find.byKey(const ValueKey('player-error-retry')));
      await fixture.settleQueue(tester);
      expect(mounted.state.targets.last, (
        target: 'real-target-B',
        flag: 'backend-B',
        vodId: 'real-vod-B',
        source: 'original-config',
        quality: 0,
      ));
      expect(
        mounted.media.opened.last.uri,
        'https://proxy.test/real-target-B/q0.m3u8',
      );
      expect(mounted.media.state.position, const Duration(seconds: 120));
      expect(mounted.media.state.playing, isFalse);
      await fixture.closeQueue(tester);
    },
  );
  testWidgets(
    'resume after preparation failure recovers current file not failed pending key',
    (tester) async {
      final queue = fixture.QueueFixture()..failKey = 'opaque-file-B';
      final mounted = await fixture.mountQueue(tester, queue: queue);
      mounted.media.progress(150, playing: false);
      await tester.pump(const Duration(seconds: 6));
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await fixture.settleQueue(tester);
      await tester.tap(find.byKey(const ValueKey('player-error-resume')));
      await fixture.settleQueue(tester);
      expect(mounted.state.targets.last, (
        target: 'real-target-A',
        flag: 'backend-A',
        vodId: 'real-vod-A',
        source: 'original-config',
        quality: 0,
      ));
      expect(
        mounted.media.opened.last.uri,
        'https://proxy.test/real-target-A/q0.m3u8',
      );
      expect(mounted.media.state.position, const Duration(seconds: 150));
      expect(mounted.media.state.playing, isFalse);
      await fixture.closeQueue(tester);
    },
  );
}
