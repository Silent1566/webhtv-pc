import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/glass_widgets.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_episode_panel.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_quality_panel.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/player_page_harness.dart';
import 'support/test_fonts.dart';

const _captureKey = ValueKey('glass-player-capture');
final _before = Platform.environment['CAPTURE_PHASE'] == 'before';
final _capture = Platform.environment['PLAYER_GLASS_CAPTURE'] == '1';
final _borderlessCapture =
    Platform.environment['PLAYER_BORDERLESS_CAPTURE'] == '1';

void _noVideoSampling(WidgetTester tester, {int minimumPanes = 1}) {
  if (_before) return;
  final panes = tester.widgetList<GlassPane>(find.byType(GlassPane));
  expect(panes.length, greaterThanOrEqualTo(minimumPanes));
  expect(panes.every((pane) => !pane.blurBackdrop), isTrue);
  expect(find.byType(BackdropFilter), findsNothing);
  expect(find.byType(ImageFiltered), findsNothing);
}

Future<void> _mount(
  WidgetTester tester,
  Widget child,
  Brightness brightness,
  Size size, {
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: _captureKey, child: child!),
      ),
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: _borderlessCapture
                  ? const CustomPaint(painter: _NoisyVideoFixture())
                  : const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFF344E68),
                            Color(0xFF172435),
                            Color(0xFF6B5B42),
                          ],
                        ),
                      ),
                    ),
            ),
            child,
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _save(WidgetTester tester, String name) async {
  if (!_capture) return;
  expectFontsAvailableOrSkip();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(
      _borderlessCapture
          ? '../../.local/global-borderless-captures/player'
          : '../../.local/glass-full-captures/glass-player',
    );
    await dir.create(recursive: true);
    await File('${dir.path}/$name-${_before ? 'before' : 'after'}.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget _transport(VoidCallback onPlay) => Positioned.fill(
  child: PlayerControlOverlay(
    topBar: AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      title: const Text('晚秋寄情 · 第1集'),
      actions: [
        IconButton(
          tooltip: '更多',
          onPressed: () {},
          icon: const Icon(Icons.more_vert),
        ),
      ],
    ),
    progressRow: Row(
      children: [
        const Text('00:12:31'),
        Expanded(child: Slider(value: .28, onChanged: (_) {})),
        const Text('00:45:00'),
      ],
    ),
    actionButtons: [
      IconButton(
        tooltip: '播放',
        onPressed: onPlay,
        icon: const Icon(Icons.play_arrow),
      ),
      IconButton(
        tooltip: '下一集',
        onPressed: () {},
        icon: const Icon(Icons.skip_next),
      ),
      const Icon(Icons.volume_up),
      const Text('100%'),
      const Text('1.0×'),
      TextButton(onPressed: () {}, child: const Text('选集（12集）')),
    ],
    actionGroups: const [
      PlayerButtonGroup.transport,
      PlayerButtonGroup.transport,
      PlayerButtonGroup.volume,
      PlayerButtonGroup.volume,
      PlayerButtonGroup.rate,
      PlayerButtonGroup.rate,
    ],
  ),
);

void main() {
  setUpAll(() async {
    await loadFixtureFonts();
    await loadFixtureFonts(cjkFamily: 'Microsoft YaHei UI');
    await loadFixtureFonts(cjkFamily: 'Roboto');
  });

  for (final brightness in Brightness.values) {
    for (final size in [const Size(1280, 800), const Size(1024, 640)]) {
      final scenario =
          '${brightness.name}-${size.width.toInt()}x${size.height.toInt()}';
      testWidgets('transport glass preserves center passthrough $scenario', (
        tester,
      ) async {
        var plays = 0;
        await _mount(tester, _transport(() => plays++), brightness, size);
        _noVideoSampling(tester, minimumPanes: 2);
        await tester.tap(find.byTooltip('播放'));
        expect(plays, 1);
        expect(tester.takeException(), isNull);
        await _save(tester, 'transport-$scenario');
      });
      testWidgets('context flyouts keep actions and viewport clamp $scenario', (
        tester,
      ) async {
        var selected = false;
        await _mount(
          tester,
          PlayerContextMenu(
            anchor: Offset(size.width - 10, size.height - 10),
            viewport: size,
            onDismiss: () {},
            sections: [
              PlayerMenuSection(
                title: '画面',
                items: [
                  PlayerMenuItem(
                    id: 'lut',
                    label: 'LUT 滤镜',
                    children: [
                      PlayerMenuItem(
                        id: 'warm',
                        label: '暖秋',
                        selected: true,
                        onSelect: () => selected = true,
                      ),
                      const PlayerMenuItem(id: 'off', label: '关闭 LUT'),
                    ],
                  ),
                  const PlayerMenuItem(id: 'fit', label: '画面比例与缩放'),
                ],
              ),
              const PlayerMenuSection(
                title: '信息',
                items: [
                  PlayerMenuItem(id: 'info', label: '媒体信息'),
                  PlayerMenuItem(id: 'help', label: '快捷键'),
                ],
              ),
            ],
          ),
          brightness,
          size,
        );
        await tester.tap(find.text('画面'));
        await tester.pump();
        await tester.tap(find.text('LUT 滤镜'));
        await tester.pump();
        _noVideoSampling(tester, minimumPanes: 3);
        for (final rect
            in tester
                .widgetList<GlassPane>(find.byType(GlassPane))
                .map((pane) => tester.getRect(find.byWidget(pane)))) {
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
        }
        await _save(tester, 'menu-$scenario');
        await tester.tap(find.text('暖秋'));
        expect(selected, isTrue);
        expect(tester.takeException(), isNull);
      });
      testWidgets(
        'episode panel glass preserves preview and selection $scenario',
        (tester) async {
          final episodes = List.generate(
            12,
            (i) => VodEpisode(
              name: '第${i + 1}集 · 秋夜重逢',
              url: 'https://example.test/$i',
            ),
          );
          String? selected;
          await _mount(
            tester,
            PlayerEpisodePanel(
              title: '晚秋寄情',
              playLines: [
                VodPlayLine(flag: '蓝光线路', episodes: episodes),
                VodPlayLine(flag: '备用线路', episodes: episodes),
              ],
              lineFlag: '蓝光线路',
              episodeIndex: 0,
              episodeCardsByFlag: const {},
              onSelectEpisode: (flag, i) => selected = '$flag:$i',
            ),
            brightness,
            size,
          );
          _noVideoSampling(tester);
          await _save(tester, 'panel-$scenario');
          await tester.tap(find.text('备用线路'));
          await tester.pump();
          expect(selected, isNull);
          await tester.tap(find.byKey(const ValueKey('player-episode-card-1')));
          expect(selected, '备用线路:1');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('quality panel uses low-cost glass at enlarged text', (
    tester,
  ) async {
    await _mount(
      tester,
      const PlayerQualityPanel(
        qualities: [
          PlaybackQuality(name: '蓝光 1080P', url: 'https://example.test/1080'),
          PlaybackQuality(name: '超清 4K', url: 'https://example.test/4k'),
        ],
        selectedIndex: 0,
      ),
      Brightness.dark,
      const Size(1024, 640),
      scale: 1.3,
    );
    _noVideoSampling(tester);
    expect(find.text('蓝光 1080P'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'player overflow, subtitle and aspect routes use no-filter glass',
    (tester) async {
      await pumpPlayerPage(
        tester,
        size: const Size(1024, 640),
        theme: buildAppTheme(Brightness.light),
      );
      await tester.tap(find.byTooltip('更多'));
      await settlePlayerPage(tester, times: 2);
      _noVideoSampling(tester, minimumPanes: 4);
      expect(find.text('画面比例与缩放'), findsOneWidget);
      await tester.tap(find.text('画面比例与缩放'));
      await settlePlayerPage(tester, times: 2);
      expect(find.byType(BottomSheet), findsOneWidget);
      _noVideoSampling(tester, minimumPanes: 4);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settlePlayerPage(tester, times: 2);
      expect(find.byType(BottomSheet), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(100, 100));
      await mouse.moveTo(const Offset(200, 100));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byTooltip('字幕轨'));
      await settlePlayerPage(tester, times: 2);
      expect(find.text('搜索字幕…'), findsOneWidget);
      _noVideoSampling(tester, minimumPanes: 4);
      await tester.tapAt(const Offset(15, 70));
      await settlePlayerPage(tester, times: 2);
      expect(find.byType(BottomSheet), findsNothing);
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    },
  );

  testWidgets('selector popup keeps keyboard dismiss and selected callback', (
    tester,
  ) async {
    var selected = 1;
    await _mount(
      tester,
      Center(
        child: StatefulBuilder(
          builder: (context, update) => PlayerGlassDropdown<int>(
            value: selected,
            items: const [
              DropdownMenuItem(value: 1, child: Text('原速')),
              DropdownMenuItem(value: 2, child: Text('二倍速')),
            ],
            onChanged: (value) => update(() => selected = value!),
          ),
        ),
      ),
      Brightness.dark,
      const Size(1024, 640),
    );
    await tester.tap(find.text('原速'));
    await tester.pumpAndSettle();
    _noVideoSampling(tester);
    await tester.tap(find.text('二倍速'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    await tester.tap(find.text('二倍速'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(find.byType(GlassPane), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long selector reveals and focuses active choice on open', (
    tester,
  ) async {
    var selectedValue = 32;
    await _mount(
      tester,
      Center(
        child: PlayerGlassDropdown<int>(
          value: 32,
          items: [
            for (var i = 1; i <= 32; i++)
              DropdownMenuItem(value: i, child: Text('分块 $i')),
          ],
          onChanged: (value) => selectedValue = value!,
        ),
      ),
      Brightness.dark,
      const Size(1024, 640),
    );
    await tester.tap(find.text('分块 32'));
    await tester.pumpAndSettle();
    final active = find.descendant(
      of: find.byType(GlassPane),
      matching: find.text('分块 32'),
    );
    expect(tester.getRect(active).bottom, lessThanOrEqualTo(640));
    expect(tester.getRect(active).top, greaterThanOrEqualTo(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      selectedValue,
      31,
      reason: 'keyboard traversal must begin at the active choice',
    );
    expect(find.byType(GlassPane), findsNothing);
    await tester.tap(find.text('分块 32'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  test('player owned selector routes all use one no-filter popup shell', () {
    for (final name in [
      'player_page',
      'danmaku_settings_sheet',
      'audio_ai/audio_ai_controls',
    ]) {
      final source = File('lib/ui/$name.dart').readAsStringSync();
      expect(source, contains('PlayerGlassDropdown<'), reason: name);
      expect(
        RegExp(r'\bDropdownButton(?:FormField)?<').allMatches(source),
        isEmpty,
        reason: name,
      );
    }
  });

  test('audio AI owned popup family explicitly disables video sampling', () {
    final source = File('lib/ui/audio_ai/audio_ai_controls.dart')
        .readAsStringSync();
    expect(
      RegExp(r'GlassAlertDialog\(\s*blurBackdrop: false')
          .allMatches(source)
          .length,
      2,
    );
    expect(source, isNot(contains('=> AlertDialog(')));
  });

  test(
    'owned major player surfaces all explicitly disable backdrop sampling',
    () {
      if (_before) return;
      for (final name in ['danmaku_settings_sheet', 'player_subtitle_menu']) {
        expect(
          File('lib/ui/$name.dart').readAsStringSync(),
          contains('showPlayerGlassSheet<'),
          reason: name,
        );
      }
      for (final name in [
        'player_overlay',
        'player_context_menu',
        'player_episode_panel',
        'player_queue_panel',
        'player_quality_panel',
        'player_live_panel',
        'player_subtitle_menu',

        'player_page',
        'player_osd',
      ]) {
        final source = File('lib/ui/$name.dart').readAsStringSync();
        expect(source, contains('blurBackdrop: false'), reason: name);
        expect(source, isNot(contains('BackdropFilter(')), reason: name);
      }
    },
  );
}

class _NoisyVideoFixture extends CustomPainter {
  const _NoisyVideoFixture();

  @override
  void paint(Canvas canvas, Size size) {
    const colors = [
      Color(0xFFF5E8A8),
      Color(0xFF0B1828),
      Color(0xFF809DAB),
      Color(0xFFFAFAF0),
      Color(0xFF6D2948),
      Color(0xFF1B493F),
    ];
    final paint = Paint();
    for (var y = 0; y < size.height; y += 32) {
      for (var x = 0; x < size.width; x += 48) {
        paint.color = colors[((x ~/ 48) * 7 + (y ~/ 32) * 11) % colors.length];
        canvas.drawRect(
          Rect.fromLTWH(x.toDouble(), y.toDouble(), 48, 32),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_NoisyVideoFixture oldDelegate) => false;
}
