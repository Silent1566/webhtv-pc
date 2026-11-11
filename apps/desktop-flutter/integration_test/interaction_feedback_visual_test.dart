/// 详情页「播放准备中」反馈的视觉证据（真实主题 + 真实窗口尺寸 → PNG）。
///
/// 截图必须是**整窗**：等待反馈挂在 Navigator 的 Overlay 上，而 Overlay 不在
/// Scaffold 子树里，所以根 `RepaintBoundary` 由 `MaterialApp.builder` 包裹整棵树，
/// 并按它的 key 截图；按 `RepaintBoundary` 类型取第一个会拍到 Scaffold 层而漏掉反馈。
///
/// 输出：`.impeccable/review/detail-play-pending-{window-1200x800,wide-1920x1080}.png`
///
/// 不需要网络：`resolvePlayback` 由本地子类挂住，等待态稳定可复现。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';

void evidence(String message) =>
    debugPrint('INTERACTION-FEEDBACK-EVIDENCE $message');

/// 把解析挂住的 `AppState`：等待态因此不会因为解析提前返回而拍空。
class _PendingPlaybackState extends AppState {
  _PendingPlaybackState({required super.paths, required super.log});

  final Completer<PlaybackDecision?> playback = Completer<PlaybackDecision?>();

  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    Site? siteOverride,
    SiteService? serviceOverride,
    bool Function()? isCurrent,
    int? qualityIndex,
  }) => playback.future;
}

Directory repoRootOf(Directory start) {
  var current = start;
  for (var hop = 0; hop < 6; hop += 1) {
    if (Directory('${current.path}/docs').existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return start;
}

/// 按根 boundary 截整窗；取不到 boundary / 编码失败一律失败，不静默跳过。
Future<void> capture(
  WidgetTester tester,
  GlobalKey boundaryKey, {
  required String relativePath,
}) async {
  final boundary = find.byKey(boundaryKey);
  expect(boundary, findsOneWidget, reason: '根 RepaintBoundary 必须在树上');
  final object = boundary.evaluate().single.renderObject;
  expect(
    object,
    isA<RenderRepaintBoundary>(),
    reason: '根 boundary 必须是 RenderRepaintBoundary 才能 toImage',
  );
  final image = await (object as RenderRepaintBoundary).toImage(
    pixelRatio: 1.0,
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  expect(bytes, isNotNull, reason: 'PNG 编码不得失败');
  final output = File('${repoRootOf(Directory.current).path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes!.buffer.asUint8List());
  evidence(
    'screenshot path=$relativePath bytes=${bytes.lengthInBytes} '
    'size=${image.width}x${image.height}',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('详情页播放准备中反馈：桌面窗口与宽屏各一张整窗 PNG', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-feedback-visual');
    final state = _PendingPlaybackState(
      paths: AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      ),
      log: LogService(),
    );
    final vod = Vod(
      vodId: 'visual-1',
      vodName: '反馈视觉证据影片',
      vodContent: '用于拍摄「播放准备中」这一帧的两集测试影片。',
      vodPlayFrom: '原线路',
      vodPlayUrl: '第1集\$http://127.0.0.1:1/media/a.mp4#第2集\$http://127.0.0.1:1/media/b.mp4',
    );
    addTearDown(() {
      if (!state.playback.isCompleted) {
        state.playback.completeError(
          AppError(AppErrorKind.siteCancelled, '视觉证据收尾'),
        );
      }
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await tester.runAsync(state.bootstrap);
    // 详情作用域必须真的属于本页影片，否则 hero 不渲染播放入口。
    state.seedDetailForTest(vod: vod);

    Future<void> shoot(String suffix, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          debugShowCheckedModeBanner: false,
          // 包住 Navigator/Overlay 整棵树：反馈正是挂在 Overlay 上的。
          builder: (context, child) =>
              RepaintBoundary(key: boundaryKey, child: child!),
          home: DetailPage(state: state, vod: vod),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final play = find.byKey(const ValueKey('detail-hero-play'));
      expect(play, findsOneWidget, reason: '详情页必须渲染 hero 播放入口');
      await tester.tap(play);
      // 反馈在下一帧出现；再推一帧让 `AppMotion.fast`(120ms) 落定。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final panel = find.byKey(const ValueKey('async-action-feedback'));
      expect(panel, findsOneWidget, reason: '点击后必须出现加载转圈');
      final rect = tester.getRect(panel);
      expect(
        rect.width > 0 && rect.height > 0,
        isTrue,
        reason: '加载转圈必须真的被布局出来（rect=$rect）',
      );
      expect(
        (tester.getCenter(panel) - size.center(Offset.zero)).distance,
        lessThan(1),
        reason: '加载转圈必须位于窗口中央',
      );
      expect(
        find.descendant(of: panel, matching: find.byType(Text)),
        findsNothing,
        reason: '只留转圈，不上屏文字',
      );
      evidence(
        'state suffix=$suffix feedbackRect=$rect '
        'viewport=${size.width.toInt()}x${size.height.toInt()}',
      );
      await capture(
        tester,
        boundaryKey,
        relativePath:
            '.impeccable/review/detail-play-pending-$suffix-'
            '${size.width.toInt()}x${size.height.toInt()}.png',
      );

      // 卸载让下一轮从干净状态开始（反馈随页面收掉）。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    await shoot('window', const Size(1200, 800));
    await shoot('wide', const Size(1920, 1080));

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
