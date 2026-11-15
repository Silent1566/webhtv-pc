/// 解析选择位置修正的视觉证据（Before / After 同一场景、同一视口、同一主题）。
///
/// 拍的是真实光栅化结果（`RepaintBoundary.toImage`），不是 widget 树的重新描述。
/// 视口固定 1280×800、播放器暗色主题，与真实播放器浮层一致。
///
/// Before 图由 `CAPTURE_PHASE=before` 采集（弹窗里还带解析行）；After 图是本轮
/// 实现后的真实渲染。两者同一 fixture、同一视口、同一主题，可直接叠看。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/player_episode_panel.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_parse_source_strip.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

const Key _captureKey = ValueKey('parse-evidence-root');
const _evidenceDir = '../../.superpowers/parse-controls/evidence';

List<VodEpisode> _episodes(int count) => [
  for (var i = 1; i <= count; i++)
    VodEpisode(name: '第$i集', url: 'https://example.test/$i.m3u8'),
];

List<VodPlayLine> _lines() => [
  VodPlayLine(flag: 'baidu', episodes: _episodes(12)),
  VodPlayLine(flag: 'quark', episodes: _episodes(12)),
];

/// 与真实播放器一致的三项解析源（含合成「超级解析」）。
const List<String> _parsers = ['超级解析', '虾米', '云解'];

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(_evidenceDir);
    await dir.create(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void _viewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 选集弹窗：After 状态下它**不该**再有任何解析控件。
Future<void> _capturePanel(WidgetTester tester, {required String name}) async {
  _viewport(tester);
  final lines = _lines();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      builder: (context, child) =>
          RepaintBoundary(key: _captureKey, child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PlayerEpisodePanel(
                  title: '晚秋寄情',
                  lineLabel: 'baidu',
                  playLines: lines,
                  lineFlag: 'baidu',
                  episodes: lines.first.episodes,
                  episodeIndex: 0,
                  onSelectEpisode: (_) {},
                  onSelectLine: (_) {},
                ),
              ),
              child: const Text('打开选集'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开选集'));
  await tester.pumpAndSettle();
  await _capture(tester, name);
}

/// 控制浮层底栏：解析条在解析播放时出现，直链播放时不出现。
Future<void> _captureControlBar(
  WidgetTester tester, {
  required String name,
  required bool parsed,
}) async {
  _viewport(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      builder: (context, child) =>
          RepaintBoundary(key: _captureKey, child: child!),
      home: Scaffold(
        backgroundColor: const Color(0xFF10131F),
        body: Stack(
          children: [
            Positioned.fill(
              child: PlayerControlOverlay(
                topBar: AppBar(title: const Text('晚秋寄情 · 第1集')),
                progressRow: Row(
                  children: [
                    const Text('00:12:31'),
                    const Expanded(child: SizedBox(height: 4)),
                    const Text('00:45:00'),
                  ],
                ),
                actionButtons: const [
                  Icon(Icons.skip_previous),
                  Icon(Icons.play_arrow),
                  Icon(Icons.skip_next),
                  Icon(Icons.volume_up),
                  Icon(Icons.speed),
                  Icon(Icons.video_library),
                  Icon(Icons.fullscreen),
                ],
                actionGroups: const [
                  PlayerButtonGroup.transport,
                  PlayerButtonGroup.transport,
                  PlayerButtonGroup.transport,
                  PlayerButtonGroup.volume,
                  PlayerButtonGroup.rate,
                  PlayerButtonGroup.rate,
                  PlayerButtonGroup.display,
                ],
                extraRow: parsed
                    ? PlayerParseSourceStrip(
                        sources: _parsers,
                        selected: _parsers.first,
                        onSelect: (_) {},
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _capture(tester, name);
}

/// 把 CJK 与拉丁两套字形注册进主题实际使用的第一个回退字族。
///
/// 只注册 CJK 时，测试环境里数字与拉丁会落到豆腐块（真机不会），证据图就
/// 没法读了；两套都挂在同一字族下，引擎按字形覆盖挑字体。
Future<void> _loadEvidenceFonts() async {
  await loadFixtureFonts();
  for (final family in ['Roboto', 'Microsoft YaHei UI']) {
    final loader = FontLoader(family);
    for (final path in [
      firstExisting(cjkFontCandidates())?.path,
      firstExisting(['/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'])?.path,
    ]) {
      if (path == null) continue;
      final bytes = await File(path).readAsBytes();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadEvidenceFonts);

  testWidgets('after: 选集弹窗不再有解析行（同一场景）', (tester) async {
    expectFontsAvailableOrSkip();
    await _capturePanel(tester, name: 'after-panel-parsed');
    expect(
      find.byKey(const ValueKey('player-episode-parse-source-strip')),
      findsNothing,
    );
  });

  testWidgets('after: 解析播放时控制区出现解析条', (tester) async {
    expectFontsAvailableOrSkip();
    await _captureControlBar(tester, name: 'after-controlbar-parsed', parsed: true);
    expect(
      find.byKey(const ValueKey('player-parse-source-strip')),
      findsOneWidget,
    );
  });

  testWidgets('after: 直链播放时控制区没有解析条', (tester) async {
    expectFontsAvailableOrSkip();
    await _captureControlBar(tester, name: 'after-controlbar-direct', parsed: false);
    expect(
      find.byKey(const ValueKey('player-parse-source-strip')),
      findsNothing,
    );
  });
}
