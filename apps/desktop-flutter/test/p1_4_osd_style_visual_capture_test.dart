/// P1-4 视觉证据：屏显样式的「设置前后」对照。
///
/// ## 这一对为什么不是「改动前后」
///
/// 屏显层的默认观感在改动前后**逐像素相同**（默认 `OsdStyle` = 字号 100%、
/// 不透明 100%，与写死的 14dp 一致）——拿改动前当对照，两张图应当一模一样，
/// 反而证明不了这个功能存在。这里拍的是**同一个渲染层在默认样式与调过样式下的
/// 对照**：同一构造、同一视口、同一主题、同一组开关。
///
/// 背景是纯色（不是真实视频帧）：本用例的断言对象是 OSD 自己的字号与浓淡，
/// 真实视频帧会让「淡了没有」无法判读。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/osd_diagnostics.dart';
import 'package:webhtv_pc/core/osd_style.dart';
import 'package:webhtv_pc/ui/player_osd.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'support/test_fonts.dart';

void evidence(String message) => debugPrint('P1-4-VISUAL-EVIDENCE $message');

/// 只有显式要求时才写图：默认 `flutter test` 会跑 test/ 下所有用例，
/// 让它每跑一次就改一遍 `docs/` 下的证据文件是污染。
/// 与 `test/config_source_status_capture_test.dart:16` 的 `CONFIG_SOURCE_CAPTURE_PHASE`
/// 同一口径：`P1_4_CAPTURE=1 flutter test test/p1_4_*_capture_test.dart`。
final bool _captureEnabled = Platform.environment['P1_4_CAPTURE'] == '1';

Directory repoRootOf(Directory start) {
  var current = start;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${current.path}/docs').existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return start;
}

/// 见 `test/p1_4_menu_visual_capture_test.dart` 里同名函数的注释：
/// `toImage` 必须在 `runAsync` 里完成。
Future<void> capture(
  WidgetTester tester, {
  required String relativePath,
}) async {
  if (!_captureEnabled) {
    evidence('screenshot-skip reason=capture-disabled path=$relativePath');
    return;
  }
  final bytes = await tester.runAsync(() async {
    final boundary = find.byType(RepaintBoundary);
    if (boundary.evaluate().isEmpty) return null;
    final object = boundary.evaluate().first.renderObject;
    if (object is! RenderRepaintBoundary) return null;
    final image = await object.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data == null ? null : Uint8List.sublistView(data);
  });
  if (bytes == null) {
    evidence('screenshot-skip reason=no-bytes path=$relativePath');
    return;
  }
  final output = File('${repoRootOf(Directory.current).path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes);
  evidence('screenshot path=$relativePath bytes=${bytes.length}');
}

/// 与播放器页同构的挂载：深色主题 + 纯色底 + 只开需要的屏显项。
Widget wrap(OsdStyle style) {
  // 把正文字族绑到已注册的 CJK 字体上：flutter_test 的默认测试字体把每个字形
  // 画成实心方块，数字会变成一排方框（时钟、进度、网速全废）——
  // 沿用 `test/config_source_status_capture_test.dart:34-42` 的同一手法。
  final theme = buildAppTheme(Brightness.dark);
  final cjk = theme.textTheme.apply(fontFamily: 'Noto Sans CJK SC');
  return MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: theme.copyWith(
    textTheme: cjk,
    primaryTextTheme: theme.primaryTextTheme.apply(
      fontFamily: 'Noto Sans CJK SC',
    ),
  ),
  home: Scaffold(
    body: Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: Color(0xFF10242E))),
        Positioned.fill(
          child: PlayerOsdLayer(
            flags: {
              OsdFlag.title: true,
              OsdFlag.size: true,
              OsdFlag.time: true,
              OsdFlag.progress: true,
              OsdFlag.traffic: true,
            },
            style: style,
            controlsVisible: false,
            title: '示例剧集 · E3',
            resolution: '3840×2160',
            position: const Duration(minutes: 12, seconds: 34),
            duration: const Duration(minutes: 45),
            isLive: false,
            now: DateTime(2026, 11, 15, 20, 30, 18),
            bytesPerSecond: 5242880,
            diagnostics: const <OsdDiagnosticsRow>[],
            environment: const <OsdDiagnosticsRow>[],
          ),
        ),
      ],
    ),
  ),
  );
}

Future<void> shoot(
  WidgetTester tester, {
  required OsdStyle style,
  required String relativePath,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(wrap(style));
  await tester.pump(const Duration(milliseconds: 100));
  await capture(tester, relativePath: relativePath);
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  // 字体：没加载时中文全是豆腐块，截图就成了「看不出标签」的假证据。
  // 主题的 fontFamilyFallback（ui/theme.dart:27-35）里含 'Noto Sans CJK SC'，
  // 把 CJK 字体注册成这个名字即可让 harness 自建的 MaterialApp 也吃到。
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
  });

  testWidgets('屏显样式：默认 100% / 100%', (tester) async {
    await shoot(
      tester,
      style: OsdStyle.defaults,
      relativePath: 'docs/reference/evidence/p1-4/osd-style-default.png',
    );
  });

  testWidgets('屏显样式：字号 150% / 不透明 60%', (tester) async {
    await shoot(
      tester,
      style: const OsdStyle(textScale: 1.5, opacity: 0.6),
      relativePath: 'docs/reference/evidence/p1-4/osd-style-scaled.png',
    );
  });
}
