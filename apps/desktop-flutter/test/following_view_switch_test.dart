/// 追剧页的两个视角：列表 / 日历的切换、懒创建与状态保持。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/following_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-following-view');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}${Platform.pathSeparator}config',
        'data': '${temp.path}${Platform.pathSeparator}data',
        'cache': '${temp.path}${Platform.pathSeparator}cache',
        'state': '${temp.path}${Platform.pathSeparator}logs',
      },
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void addItem() {
    final item = state.followFromDetail(
      site: Site(key: 's', name: '甲站', type: 4, api: 'http://127.0.0.1:1/vod'),
      vod: Vod(vodId: 'v1', vodName: '测试剧'),
      flag: '线路一',
      sourceFlag: '线路一',
      releasedEpisode: 10,
    );
    expect(item, isNotNull);
  }

  const captureKey = ValueKey('following-test-capture');

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fontPath = Platform.environment['FOLLOWING_KEYS_FONT'];
    if (fontPath != null) {
      await tester.runAsync(() async {
        final bytes = await File(fontPath).readAsBytes();
        final font = FontLoader('FollowingFixture');
        font.addFont(Future.value(ByteData.sublistView(bytes)));
        await font.load();
      });
    }
    final theme = buildAppTheme(Brightness.dark);
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: fontPath == null
              ? theme
              : theme.copyWith(
                  textTheme: theme.textTheme.apply(
                    fontFamily: 'FollowingFixture',
                  ),
                ),
          home: Scaffold(body: FollowingPage(state: state)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 当前视角（宿主用 IndexedStack 装两个视角，0 = 列表，1 = 日历）。
  int viewIndex(WidgetTester tester) => tester
      .widget<IndexedStack>(
        find.descendant(
          of: find.byType(FollowingPage),
          matching: find.byType(IndexedStack),
        ),
      )
      .index!;

  for (final (group, inactive, selected, inactiveLabel, selectedLabel) in [
    ('following', 'calendar', 'list', '日历', '列表'),
    ('calendar', 'week', 'month', '整周', '整月'),
  ]) {
    final target = find.byKey(ValueKey('$group-view-$inactive'));
    final current = find.byKey(ValueKey('$group-view-$selected'));
    final calendar = find.byKey(const ValueKey('following-view-calendar'));

    Future<void> mountSwitch(WidgetTester tester) async {
      addItem();
      await mount(tester);
      if (group == 'calendar') {
        await tester.tap(calendar);
        await tester.pumpAndSettle();
      }
      expect(target, findsOneWidget);
      expect(current, findsOneWidget);
    }

    testWidgets('$group switch paints hover, press and Tab focus', (
      tester,
    ) async {
      await mountSwitch(tester);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final rect = tester
          .getRect(target)
          .expandToInclude(tester.getRect(current));
      final crop = Rect.fromLTRB(
        rect.left.floorToDouble() - 2,
        rect.top.floorToDouble() - 2,
        rect.right.ceilToDouble() + 2,
        rect.bottom.ceilToDouble() + 2,
      );
      final frames = <ui.Image>[];
      addTearDown(() {
        for (final frame in frames) {
          frame.dispose();
        }
      });
      Future<void> capture() async {
        final layer = boundary.debugLayer! as OffsetLayer;
        frames.add((await tester.runAsync(() => layer.toImage(crop)))!);
      }

      await capture();
      final center = tester.getCenter(target);
      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: center);
      await tester.pumpAndSettle();
      await capture();
      await mouse.down(center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await capture();
      await mouse.cancel();
      await mouse.removePointer();
      await tester.pumpAndSettle();

      final label = find.descendant(
        of: target,
        matching: find.text(inactiveLabel),
      );
      final focus = Focus.of(tester.element(label));
      for (var tab = 0; !focus.hasPrimaryFocus && tab < 14; tab++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(
        focus.hasPrimaryFocus,
        isTrue,
        reason: 'Tab must reach $inactiveLabel',
      );
      await capture();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      if (group == 'following') {
        expect(viewIndex(tester), 1);
        expect(find.byKey(const ValueKey('calendar-region')), findsOneWidget);
      } else {
        expect(
          find.byKey(const ValueKey('calendar-week-title')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('calendar-title')), findsNothing);
      }

      final counts = (await tester.runAsync(
        () => _measureCapture(group, frames),
      ))!;
      // A visible state layer affects an area, not just antialiasing at an edge.
      expect(
        counts,
        everyElement(greaterThan(20)),
        reason: 'hover, press, focus pixel changes',
      );
    });

    testWidgets('$group switch exposes both choices and current selection', (
      tester,
    ) async {
      await mountSwitch(tester);

      void expectSelection(Finder option, String label, bool selected) {
        final node = tester.getSemantics(option).getSemanticsData();
        expect(node.label, label);
        expect(node.flagsCollection.isButton, isTrue, reason: label);
        expect(
          node.flagsCollection.isEnabled,
          ui.Tristate.isTrue,
          reason: label,
        );
        expect(
          node.flagsCollection.isSelected,
          selected ? ui.Tristate.isTrue : ui.Tristate.isFalse,
          reason: label,
        );
        expect(node.hasAction(ui.SemanticsAction.tap), isTrue, reason: label);
      }

      expectSelection(current, selectedLabel, true);
      expectSelection(target, inactiveLabel, false);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expectSelection(current, selectedLabel, false);
      expectSelection(target, inactiveLabel, true);
    });
  }

  testWidgets('默认列表视角，日历首次切入才创建', (tester) async {
    addItem();
    await mount(tester);
    expect(viewIndex(tester), 0);
    expect(find.byKey(const ValueKey('following-list')), findsOneWidget);
    // 懒创建：没切过日历就不存在（只用列表的用户不触发日历的 TMDB 取数）。
    expect(find.byKey(const ValueKey('calendar-region')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('following-view-calendar')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(viewIndex(tester), 1);
    expect(find.byKey(const ValueKey('calendar-region')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('离开页面再回来保留上次视角（壳层会重建本页）', (tester) async {
    addItem();
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('following-view-calendar')));
    await tester.pump();
    expect(viewIndex(tester), 1);

    // 壳层切到别的侧栏项会丢掉本页 State（AppShell 每次重建内容区）。
    await tester.pumpWidget(const SizedBox());
    await mount(tester);
    expect(viewIndex(tester), 1, reason: '会话内应恢复上次视角');
  });

  testWidgets('切换视角保留日历的月份（IndexedStack 保状态）', (tester) async {
    addItem();
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('following-view-calendar')));
    await tester.pump();

    final now = DateTime.now();
    final next = DateTime(now.year, now.month + 1);
    await tester.tap(find.byKey(const ValueKey('calendar-next-month')));
    await tester.pump();
    expect(find.text('${next.year}年${next.month}月'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('following-view-list')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('following-view-calendar')));
    await tester.pump();
    expect(viewIndex(tester), 1);
    expect(
      find.text('${next.year}年${next.month}月'),
      findsOneWidget,
      reason: '切走再切回不该回到当月',
    );
  });
}

Future<List<int>> _measureCapture(String group, List<ui.Image> frames) async {
  final pixels = <Uint8List>[
    for (final frame in frames)
      (await frame.toByteData())!.buffer.asUint8List(),
  ];
  int changed(int from, int to) {
    var count = 0;
    for (var i = 0; i < pixels[from].length; i += 4) {
      if ([
        0,
        1,
        2,
      ].any((c) => (pixels[from][i + c] - pixels[to][i + c]).abs() >= 6)) {
        count++;
      }
    }
    return count;
  }

  final counts = [changed(0, 1), changed(1, 2), changed(0, 3)];
  final prefix = Platform.environment['FOLLOWING_KEYS_CAPTURE'];
  if (prefix != null) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final width = frames.first.width;
    final height = frames.first.height;
    var column = 0;
    for (final index in [0, 3, 1, 2]) {
      canvas.drawImage(
        frames[index],
        Offset(column++ * (width + 4.0), 0),
        Paint(),
      );
    }
    final picture = recorder.endRecording();
    final strip = await picture.toImage(
      frames.length * (width + 4) - 4,
      height,
    );
    try {
      final png = (await strip.toByteData(format: ui.ImageByteFormat.png))!;
      await File('$prefix-$group.png').writeAsBytes(png.buffer.asUint8List());
      // ignore: avoid_print
      print('$group painted pixels (hover, press, focus): $counts');
    } finally {
      strip.dispose();
      picture.dispose();
    }
  }
  return counts;
}
