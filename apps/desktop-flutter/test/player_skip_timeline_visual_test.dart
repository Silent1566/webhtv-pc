import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

const timelineFixture = <SkipSegment>[
  SkipSegment(
    kind: SkipKind.recap,
    provider: 'fixture',
    identity: 'recap',
    startMs: 0,
    endMs: 30000,
  ),
  SkipSegment(
    kind: SkipKind.intro,
    provider: 'fixture',
    identity: 'intro',
    startMs: 45000,
    endMs: 105000,
  ),
  SkipSegment(
    kind: SkipKind.advertisement,
    provider: 'fixture',
    identity: 'advertisement',
    startMs: 210000,
    endMs: 240000,
  ),
  SkipSegment(
    kind: SkipKind.intermission,
    provider: 'fixture',
    identity: 'intermission',
    startMs: 300000,
    endMs: 330000,
  ),
  SkipSegment(
    kind: SkipKind.outro,
    provider: 'fixture',
    identity: 'outro',
    startMs: 420000,
    endMs: 480000,
  ),
  SkipSegment(
    kind: SkipKind.preview,
    provider: 'fixture',
    identity: 'preview',
    startMs: 495000,
    endMs: 525000,
  ),
  SkipSegment(
    kind: SkipKind.postCredits,
    provider: 'fixture',
    identity: 'postCredits',
    startMs: 540000,
    endMs: 570000,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
    await loadFixtureFonts(cjkFamily: 'Roboto');
  });

  for (final brightness in Brightness.values) {
    testWidgets('timeline evidence ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(1000, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final phase = Platform.environment['CAPTURE_PHASE'] ?? 'after';
      final prefix = Platform.environment['CAPTURE_PREFIX'] ?? 'track-overlay';
      final dpr = double.tryParse(Platform.environment['CAPTURE_DPR'] ?? '');
      if (dpr != null) {
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize = Size(1000 * dpr, 320 * dpr);
      }
      final theme = buildAppTheme(brightness);
      const root = ValueKey('timeline-capture');
      // Capture the same seven segments before and after the track change.
      final slider = Function.apply(PlayerProgressSlider.new, const [], {
        #position: const Duration(seconds: 150),
        #duration: const Duration(seconds: 600),
        #buffered: const Duration(seconds: 390),
        #onSeek: (Duration _) {},
        #skipSegments: timelineFixture,
      }) as Widget;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: RepaintBoundary(
            key: root,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('可跳片段时间轴', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 12),
                    const Text('播放 02:30 / 10:00    缓冲至 06:30'),
                    const Spacer(),
                    Row(
                      children: [
                        const Text('02:30'),
                        const SizedBox(width: 12),
                        Expanded(child: SizedBox(height: 32, child: slider)),
                        const SizedBox(width: 12),
                        const Text('10:00'),
                      ],
                    ),
                    const Spacer(),
                    const Text(
                      '回顾 00:00–00:30 · 片头 00:45–01:45 · 广告 03:30–04:00 · 休息 05:00–05:30',
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '片尾 07:00–08:00 · 预告 08:15–08:45 · 彩蛋 09:00–09:30',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(root),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: dpr ?? 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory('../../docs/phase9/evidence/skip-segments');
        await directory.create(recursive: true);
        await File('${directory.path}/$prefix-${brightness.name}-$phase.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.getSize(find.byType(PlayerProgressSlider)).height, 32);
      expect(tester.takeException(), isNull);
    });
  }
}
