/// Phase 8 · 视觉证据采集（`docs/phase8/design/05` §8.1）。
///
/// ## 为什么必须新建
///
/// 既有 `ui_redesign_visual_flow_test.dart` 的 `capture` 取树中**第一个
/// `RepaintBoundary`**（`Scaffold` 那层）。本轮把右键菜单做成**页内 Stack 层**
/// 而不是 `Overlay` 浮层，**正是为了让它出现在这张图里**
/// （`docs/phase8/design/04` §3）。
///
/// ## 纪律
///
/// - 沿用 `DESIGN.md:411` 的多宽高比纪律：1.6:1 / 2.0:1 / 2.35:1 各出一张；
/// - **菜单截图必须与关闭态字节不同**（否则就是假证据，
///   `ui_redesign_visual_flow_test.dart:708-711` 已经记录过这个坑）。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import '../test/fixture_support.dart';

void evidence(String message) => debugPrint('PHASE8-VISUAL-EVIDENCE $message');

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

Future<Uint8List?> captureBytes(WidgetTester tester) async {
  final boundary = find.byType(RepaintBoundary);
  if (boundary.evaluate().isEmpty) return null;
  final object = boundary.evaluate().first.renderObject;
  if (object is! RenderRepaintBoundary) return null;
  final image = await object.toImage(pixelRatio: 1.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes?.buffer.asUint8List();
}

Future<Uint8List?> capture(
  WidgetTester tester, {
  required String relativePath,
}) async {
  final data = await captureBytes(tester);
  if (data == null) {
    evidence('screenshot-skip reason=no-bytes path=$relativePath');
    return null;
  }
  final repoRoot = repoRootOf(Directory.current);
  final output = File('${repoRoot.path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(data);
  evidence('screenshot path=$relativePath bytes=${data.length}');
  return data;
}

Future<bool> fixtureReachable() async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    final request = await client.getUrl(Uri.parse('$fixtureBaseUrl/health'));
    final response = await request.close();
    await response.drain<void>();
    client.close();
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// 一个宽高比档位。
class Ratio {
  const Ratio(this.name, this.size);
  final String name;
  final Size size;
}

const ratios = [
  Ratio('r16x10', Size(1440, 900)), // 1.6:1
  Ratio('r2x1', Size(1600, 800)), // 2.0:1
  Ratio('r235x1', Size(1880, 800)), // 2.35:1
];

/// 截图上屏显时钟显示的时刻，固定值（见 `setUp` 的说明）。
final DateTime _frozenClock = DateTime(2026, 10, 20, 3, 53, 48);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // 冻结屏显时钟：截图要入库，实时时钟会让同一份代码每次跑出不同字节的
  // PNG（实测差异只有右上角约 34×10 像素），证据就无法复核。
  setUp(() => debugOsdClockOverride = _frozenClock);
  tearDown(() => debugOsdClockOverride = null);

  for (final ratio in ratios) {
    testWidgets('控制栏可见 / 隐藏 / 菜单打开（${ratio.name}）', (tester) async {
      if (!await fixtureReachable()) {
        markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
        return;
      }
      final temp = Directory.systemTemp.createTempSync(
        'webhtv-phase8-visual-${ratio.name}',
      );
      final paths = AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      );
      final state = AppState(paths: paths, log: LogService());
      addTearDown(() {
        state.dispose();
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      await state.bootstrap();
      // 诊断面板打开，让截图上能看到它。
      await state.setOsdFlag(OsdFlag.diagnostics, true);

      tester.view.physicalSize = ratio.size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: PlayerPage(
              state: state,
              request: PlaybackRequest(
                url: '$fixtureBaseUrl/media/sample.m3u8',
                title: '示例剧集',
                siteKey: 'fixture',
                vodId: 'demo-1',
                vodName: '示例剧集',
                episodeName: 'E3',
                flag: '线路一',
                headers: fixtureMediaHeaders,
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
      }

      // 1) 控制栏可见。
      //
      // **必须 pump 多次**：`PlayerControlOverlay` 外面包着
      // `AnimatedOpacity`（`design/01` §3.2），隐式动画的 ticker 需要
      // **一帧注册**（那一帧 `elapsed == 0`，`ticker.dart:277` 是
      // `_startTime ??= timeStamp;`）、**再一帧才推进**。
      // 实测：`pump()` + `pump(400ms)` 两次之后
      // `RenderAnimatedOpacity.opacity.value` 仍是 `0.0`，截图上只有屏显时钟、
      // 没有控制栏。这里改成有界的多帧推进。
      await tester.tap(find.byType(PlayerPage), warnIfMissed: false);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final opacityFinder = find.ancestor(
        of: find.byType(PlayerControlOverlay),
        matching: find.byType(AnimatedOpacity),
      );
      expect(
        opacityFinder,
        findsOneWidget,
        reason: '控制浮层必须存在（`design/01` §3）',
      );
      expect(
        tester.renderObject<RenderAnimatedOpacity>(opacityFinder.first).opacity.value,
        1.0,
        reason: '截图前控制浮层必须已完全不透明，否则拍到的是一张「控制栏没出现」的假证据',
      );
      await capture(
        tester,
        relativePath: 'docs/phase8/evidence/screenshots/'
            'player-controls-${ratio.name}.png',
      );

      // 2) 右键菜单打开。
      //
      // **锚点必须在顶栏之下**：顶栏现在是浮层里的 `AppBar`（`design/01` §4.1），
      // 它的 `Material` 会吸收命中测试，所以 `y < kToolbarHeight` 的右键
      // 落在顶栏上、根本到不了第 1 层的 `GestureDetector`——菜单不会打开。
      // （实测：锚点取 `0.05 * height` 时菜单没开，两张截图逐字节相同。）
      // 同时要避开底部的进度行/动作行，所以取 0.12 高度处。
      //
      // 锚点越靠上，菜单可见部分越多（`maxHeight` 从左上角往下量，
      // `design/04` §5.2）。但菜单真实高度远超 420 估算值，**任何**窗口下
      // 都会被裁——内部滚动是设计行为，所以下面再补一张滚到底的图。
      await tester.tapAt(
        Offset(ratio.size.width * 0.5, ratio.size.height * 0.12),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      // **主断言（确定性）**：菜单必须落在 harness 拍到的那个
      // `RepaintBoundary` 之内。这才是「截图是真证据」的直接判据；
      // 下面的字节比较只是辅助信号。
      final captured = find.byType(RepaintBoundary).first;
      expect(
        find.descendant(
          of: captured,
          matching: find.byType(PlayerContextMenu),
        ),
        findsOneWidget,
        reason:
            '右键菜单不在 harness 拍到的 `RepaintBoundary` 之内 → 截图拍不到它。'
            '检查它是否被实现成了 `Overlay` 浮层（`design/04` §3）。',
      );

      await capture(
        tester,
        relativePath: 'docs/phase8/evidence/screenshots/'
            'player-menu-${ratio.name}.png',
      );

      // 2b) 菜单内部滚到底，补一张——否则「6 个分组」在一张图里看不到。
      // 这不是为了迁就断言，而是因为菜单**确实**高于窗口：
      // 内部滚动是 `design/04` §5.2 明确设计的行为。
      final menuScrollable = find.descendant(
        of: find.byType(PlayerContextMenu),
        matching: find.byType(Scrollable),
      );
      expect(
        menuScrollable,
        findsOneWidget,
        reason: '菜单必须可内部滚动，否则超出窗口的部分永远看不到',
      );
      final position = tester
          .state<ScrollableState>(menuScrollable.first)
          .position;
      evidence(
        'menu-scroll extent=${position.maxScrollExtent.toStringAsFixed(1)} '
        'viewport=${position.viewportDimension.toStringAsFixed(1)}',
      );
      if (position.maxScrollExtent > 0) {
        position.jumpTo(position.maxScrollExtent);
        // **必须等滚动条淡出**，否则截图不可复现。
        //
        // `jumpTo` 会让滚动条显示，并挂一个 `fadeDuration`（300ms）的
        // **Timer** 才开始淡出。`pumpAndSettle` 只等「有没有排队的帧」，
        // 而那个 Timer 还没到点，于是它立刻返回、截图就把**半透明滚动条**
        // 拍进去了。实测：连续两次跑，差异正好落在菜单右缘一条 9px 宽的
        // 竖条上（r16x10 的差异包围盒 `(949, 232, 958, 892)`，4664~5924 像素），
        // 其余像素逐字节相同。
        //
        // 这里显式推进到淡出完成之后再拍。
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 800));
        await tester.pumpAndSettle();
        await capture(
          tester,
          relativePath: 'docs/phase8/evidence/screenshots/'
              'player-menu-bottom-${ratio.name}.png',
        );
      }

      // 3) 关闭菜单，等自动隐藏。
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await capture(
        tester,
        relativePath: 'docs/phase8/evidence/screenshots/'
            'player-osd-${ratio.name}.png',
      );

      // **关于「菜单截图必须与关闭态字节不同」**（brief 原话）：
      // 实测这条断言**恒真，没有判别力**，已删除。
      //
      // 原因：两个状态之间至少有两处像素必然变化——
      //   1. 屏显时钟每秒跳动（`Timer.periodic(1s)`，Task 11）；
      //   2. 视频在播放，帧内容每帧都在变。
      // 实测 r2x1 档位：菜单没打开（锚点落在顶栏上被吸收），
      // 两张截图仍差 5 字节（`menuBytes=363046 closedBytes=363041`），
      // 断言照样通过。**这就是一条假绿。**
      //
      // 真正的判据是上面那条 `find.descendant`：菜单必须在 harness 拍到的
      // 那个 `RepaintBoundary` 之内。它是确定性的、不依赖像素，
      // 且恰好能区分「页内 Stack 层」与「`Overlay` 浮层」两种实现——
      // 也就是 `design/04` §3 这个决策本身。
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('窄窗口 1024×640：控制栏单行不换行（design/03 §5.4）', (tester) async {
    if (!await fixtureReachable()) {
      markTestSkipped('fixture 服务不可达（$fixtureBaseUrl）');
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-phase8-narrow');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    tester.view.physicalSize = const Size(1024, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: '$fixtureBaseUrl/media/sample.m3u8',
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E3',
              flag: '线路一',
              headers: fixtureMediaHeaders,
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }
    await tester.tap(find.byType(PlayerPage), warnIfMissed: false);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final narrowOpacity = find.ancestor(
      of: find.byType(PlayerControlOverlay),
      matching: find.byType(AnimatedOpacity),
    );
    expect(
      tester.renderObject<RenderAnimatedOpacity>(narrowOpacity.first).opacity.value,
      1.0,
      reason: '窄窗口截图前控制浮层必须已完全不透明',
    );
    await capture(
      tester,
      relativePath: 'docs/phase8/evidence/screenshots/player-narrow-1024x640.png',
    );
    expect(tester.takeException(), isNull, reason: '窄窗口不得溢出');
  });
}
