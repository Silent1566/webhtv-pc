import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'player_history_lines_test.dart' as fixture;
import 'support/test_fonts.dart';

Future<void> _capture(
  WidgetTester tester,
  GlobalKey capture,
  String name,
) async {
  final boundary =
      capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('../../.local/captures/player-history-lines');
    await dir.create(recursive: true);
    await File('${dir.path}/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    await loadFixtureFonts();
    await loadFixtureFonts(cjkFamily: 'Roboto');
    await loadFixtureFonts(cjkFamily: 'Microsoft YaHei UI');
  });

  testWidgets('history resume line hydration capture', (tester) async {
    expectFontsAvailableOrSkip();
    const phase = String.fromEnvironment(
      'HISTORY_LINES_CAPTURE',
      defaultValue: 'after',
    );
    expect(['before', 'after'], contains(phase));
    // 屏显时钟必须冻结，否则两张证据还会混入真实墙钟变化。
    debugOsdClockOverride = DateTime(2026, 11, 14, 12, 34, 56);
    addTearDown(() => debugOsdClockOverride = null);
    final capture = GlobalKey();
    // 场景取自真机记录：网盘聚合目录条目（`atvp_detail:131957`）直接进播放器，
    // 历史里只有父目录 id，线路要等目录展开才补出来。
    final mounted = await fixture.mountHistory(
      tester,
      hydrationEnabled: phase == 'after',
      capture: capture,
      lines: fixture.folderLines,
      routes: fixture.folderRoutes,
      request: fixture.historyRequest(
        vodId: fixture.folderVodId,
        flag: '丫仙女',
        target: '1@20465',
        episodeName: '01(696.02 MB)',
        sourceKey: '',
      ),
    );
    mounted.media.progress(120);
    await fixture.settleHistory(tester);
    expect(find.text('02:00'), findsOneWidget);
    expect(mounted.media.state.playing, isTrue);
    expect(find.byKey(const ValueKey('player-episode-panel')), findsNothing);
    if (phase == 'before') {
      expect(find.textContaining('选集（'), findsNothing);
    } else {
      expect(find.text('选集（2）'), findsOneWidget);
    }
    // 两张对比都是控制栏；面板是同一 after 场景的另一张证据，不能替代 after。
    await _capture(tester, capture, phase);
    if (phase == 'after') {
      final panel = await fixture.openHistoryEpisodes(tester);
      expect(panel.lineFlag, '丫仙女');
      expect(panel.episodeIndex, 0);
      expect(panel.episodes, hasLength(2));
      // 面板列出的是目录展开后的全部线路（两个提供方，其中一条自带两条线路）。
      expect(panel.playLines.map((line) => line.flag), [
        '丫仙女',
        'quark · 夸克',
        'quark · 夸克原画',
      ]);
      await _capture(tester, capture, 'after-panel');
    }
    await fixture.closeHistory(tester);
  });
}
