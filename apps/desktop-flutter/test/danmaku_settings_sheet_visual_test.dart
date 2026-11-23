/// 弹层视觉证据：四个页签各出一张 PNG，落在仓库根 .tools/。
///
/// 为什么走真实 showModalBottomSheet：截的是用户真正会看到的层级——遮罩、
/// 拖拽把手、圆角与安全区都在；只 pump 弹层控件会丢掉这些，证据图就不能
/// 回答「弹层在播放器上长什么样」。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku_style.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/danmaku_settings_sheet.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

/// 证据图里的弹幕样式：取一组非默认值，让四个页签的当前值都能读出差异。
const _evidenceStyle = DanmakuStyle(
  opacity: 0.8,
  textScale: 1.25,
  strokeWidth: 1.2,
  scrollDurationMs: 15000,
  fixedDurationMs: 4000,
  areaRatio: 0.6,
  maxTracks: 5,
  timeOffsetMs: 1500,
);

const _sourceAUrl = 'https://a.test/danmaku/star-river-ep01.xml';
const _sourceBUrl = 'wss://live.test/room/42';
const _evidenceSources = <DanmakuSource>[
  DanmakuSource(url: _sourceAUrl, name: '星河'),
  DanmakuSource(url: _sourceBUrl, name: '直播房'),
];
const _evidenceSourceView = DanmakuSourceView(
  sources: _evidenceSources,
  currentUrl: _sourceAUrl,
  itemCount: 12,
  libraryUrl: 'https://lib.test/api/danmaku',
);

Future<void> _pumpHost(
  WidgetTester tester, {
  required GlobalKey capture,
  required DanmakuSourceView sourceView,
}) async {
  final theme = buildAppTheme(Brightness.dark);
  await tester.pumpWidget(
    RepaintBoundary(
      key: capture,
      child: MaterialApp(
        theme: theme,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              // 证据图里只留弹层：宿主按钮只用来触发，透明后仍可点击，
              // 不会透过遮罩在深色背景上留下一个孤立标签。
              child: Opacity(
                opacity: 0,
                child: TextButton(
                  key: const ValueKey('open-danmaku-sheet'),
                  onPressed: () => showDanmakuSettingsSheet(
                    context,
                    style: _evidenceStyle,
                    onChanged: (_) {},
                    sourceView: sourceView,
                    onSelectSource: (source) async => DanmakuSourceLoadOutcome(
                      ok: true,
                      currentUrl: source.url,
                    ),
                  ),
                  child: const Text('打开弹幕设置'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-danmaku-sheet')));
  await tester.pumpAndSettle();
}

Future<void> _writeCapture(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String fileName,
) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../../.tools/$fileName');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
  final file = File('../../.tools/$fileName');
  expect(file.existsSync(), isTrue, reason: '视觉证据必须留在 $fileName，不能只在测试里渲染一次');
  expect(file.lengthSync(), greaterThan(10000), reason: 'PNG 太小通常意味着只截到空白背景');
}

/// 把 CJK 与拉丁字形同时注册到主题实际使用的两个字族。
///
/// 组件主题（ListTile / 按钮）各自带 _fontFallback，不是简单的 textTheme
/// 覆盖；只注册一个族名会出现「中文正常、数字变方块」。两套字形挂在同一
/// 族下，引擎按字形覆盖挑字体，与 player_parse_visual_test 一致。
Future<void> _loadEvidenceFonts() async {
  await loadFixtureFonts(cjkFamily: 'Microsoft YaHei UI');
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

  testWidgets('弹层四个页签写入 PNG 证据', (tester) async {
    tester.view.physicalSize = const Size(1024, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final capture = GlobalKey();
    await _pumpHost(tester, capture: capture, sourceView: _evidenceSourceView);

    // 显示页签同时作为总览图（after）；其余是逐页签对照。
    await _writeCapture(tester, capture, 'danmaku-sheet-display.png');
    await tester.runAsync(_copyOverview);

    await tester.tap(find.byKey(const ValueKey('player-danmaku-tab-timing')));
    await tester.pumpAndSettle();
    await _writeCapture(tester, capture, 'danmaku-sheet-timing.png');

    await tester.tap(find.byKey(const ValueKey('player-danmaku-tab-tracks')));
    await tester.pumpAndSettle();
    await _writeCapture(tester, capture, 'danmaku-sheet-tracks.png');

    await tester.tap(find.byKey(const ValueKey('player-danmaku-tab-sources')));
    await tester.pumpAndSettle();
    await _writeCapture(tester, capture, 'danmaku-sheet-sources.png');
  });

  testWidgets('弹幕源空状态写入 PNG 证据', (tester) async {
    tester.view.physicalSize = const Size(1024, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final capture = GlobalKey();
    await _pumpHost(
      tester,
      capture: capture,
      sourceView: const DanmakuSourceView(),
    );
    await tester.tap(find.byKey(const ValueKey('player-danmaku-tab-sources')));
    await tester.pumpAndSettle();
    await _writeCapture(tester, capture, 'danmaku-sheet-sources-empty.png');
  });
}

/// 总览图与显示页签同一帧：不重复渲染一次，避免两张图悄悄分叉。
Future<void> _copyOverview() async {
  final source = File('../../.tools/danmaku-sheet-display.png');
  await source.copy('../../.tools/danmaku-sheet-after.png');
}
