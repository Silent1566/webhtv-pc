import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/glass_surface.dart';
import 'package:webhtv_pc/ui/glass_widgets.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';

import 'support/test_fonts.dart';

bool _visibleSide(BorderSide side) =>
    side.style != BorderStyle.none && side.color.a > 0 && side.width > 0;
bool _visibleBorder(BoxBorder? border) =>
    border is Border &&
    [border.top, border.right, border.bottom, border.left].any(_visibleSide);

void main() {
  setUpAll(() async {
    await loadFixtureFonts();
    for (final family in ['Roboto', 'Noto Sans CJK SC', 'Microsoft YaHei UI']) {
      await loadFixtureFonts(
        cjkFamily: family,
        iconFamily: 'UnusedFixtureIcons',
      );
    }
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'default material has no decorative rim or sheen in ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness),
            home: RepaintBoundary(
              key: boundary,
              child: WallpaperBackdrop(
                url: null,
                builder: (_, _) => Center(
                  child: SizedBox(
                    width: 680,
                    height: 400,
                    child: GlassPane(
                      child: Material(
                        type: MaterialType.transparency,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('搜索与设置'),
                              const SizedBox(height: 20),
                              const TextField(
                                decoration: InputDecoration(labelText: '关键词'),
                              ),
                              const SizedBox(height: 20),
                              OutlinedButton(
                                onPressed: () {},
                                child: const Text('取消'),
                              ),
                              const Chip(label: Text('全部站点')),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final dir = Platform.environment['BORDERLESS_CAPTURE'];
        final phase = Platform.environment['BORDERLESS_PHASE'];
        if (dir != null && phase != null) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            try {
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              await Directory(dir).create(recursive: true);
              await File('$dir/material-${brightness.name}-$phase.png')
                  .writeAsBytes(bytes.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        final pane = find.byType(GlassSurface);
        final boxes = tester
            .widgetList<DecoratedBox>(
              find.descendant(of: pane, matching: find.byType(DecoratedBox)),
            )
            .map((w) => w.decoration)
            .whereType<BoxDecoration>();
        expect(
          boxes.any((box) => _visibleBorder(box.border)),
          isFalse,
          reason: 'ordinary panels must not paint a permanent outline',
        );
        expect(
          boxes
              .where((box) => box.gradient != null)
              .expand((box) => box.gradient!.colors)
              .every((color) => color.a == 0),
          isTrue,
          reason: 'edge washes and diagonal sheen are decorative frames too',
        );
        expect(find.byType(BackdropFilter), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'plain controls stay borderless but focus and errors remain visible in ${brightness.name}',
      (tester) async {
        final theme = buildAppTheme(brightness);
        final form = GlobalKey<FormState>();
        final node = FocusNode();
        final submitFocus = FocusNode();
        addTearDown(node.dispose);
        addTearDown(submitFocus.dispose);
        var submissions = 0;
        final submitStates = WidgetStatesController();
        addTearDown(submitStates.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: form,
                  child: Column(
                    children: [
                      TextFormField(
                        focusNode: node,
                        validator: (value) =>
                            (value ?? '').isEmpty ? '请输入内容' : null,
                        decoration: const InputDecoration(labelText: '必填字段'),
                      ),
                      OutlinedButton(
                        focusNode: submitFocus,
                        statesController: submitStates,
                        onPressed: () { submissions++; form.currentState!.validate(); },
                        child: const Text('提交'),
                      ),
                      const TextField(enabled: false, decoration: InputDecoration(labelText: '不可编辑')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        var decoration = tester
            .widget<InputDecorator>(find.byType(InputDecorator).first)
            .decoration;
        expect(_visibleSide(decoration.enabledBorder!.borderSide), isFalse);
        expect(
          _visibleSide(theme.outlinedButtonTheme.style!.side!.resolve({})!),
          isFalse,
        );
        expect(_visibleSide(theme.chipTheme.side!), isFalse);
        expect(
          _visibleSide(theme.segmentedButtonTheme.style!.side!.resolve({})!),
          isFalse,
        );
        node.requestFocus();
        await tester.pumpAndSettle();
        expect(node.hasFocus, isTrue);
        decoration = tester
            .widget<InputDecorator>(find.byType(InputDecorator).first)
            .decoration;
        expect(_visibleSide(decoration.focusedBorder!.borderSide), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(submitFocus.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(submissions, 1);
        expect(find.text('请输入内容'), findsOneWidget);
        node.requestFocus();
        await tester.pumpAndSettle();
        decoration = tester
            .widget<InputDecorator>(find.byType(InputDecorator).first)
            .decoration;
        expect(_visibleSide(decoration.focusedErrorBorder!.borderSide), isTrue);
        expect(
          decoration.focusedErrorBorder!.borderSide.color,
          theme.colorScheme.error,
        );
        final disabled = tester.widget<InputDecorator>(find.byType(InputDecorator).last).decoration;
        expect(_visibleSide(disabled.disabledBorder!.borderSide), isFalse);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1, 1));
        await mouse.moveTo(tester.getCenter(find.text('提交')));
        await tester.pumpAndSettle();
        expect(submitStates.value, contains(WidgetState.hovered));
        expect(theme.outlinedButtonTheme.style!.overlayColor!.resolve(submitStates.value)!.a, greaterThan(0));
        await mouse.removePointer();
        expect(theme.hoverColor.a, greaterThan(0));
        expect(theme.focusColor.a, greaterThan(0));
        expect(
          theme.navigationRailTheme.indicatorColor,
          isNot(theme.navigationRailTheme.backgroundColor),
        );
      },
    );
  }

  testWidgets(
    'low-cost media panel remains unfiltered and lighter than an opaque card',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: const GlassPane(
            blurBackdrop: false,
            child: Text('Media controls'),
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      final surfaces = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(GlassSurface),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((w) => w.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.color != null);
      expect(surfaces.first.color!.a, lessThan(.9));
    },
  );
}
