import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/core/skip_segment_colors.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/intro_skip_options_page.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/theme.dart';

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory temp;
  late AppState state;
  late LogService log;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-skip-colors');
    log = LogService();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      ),
      log: log,
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    // Windows 上未释放的文件句柄会让目录删除直接抛错；先等日志落盘收尾。
    await log.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: IntroSkipOptionsPage(state: state),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    expect(finder, findsOneWidget);
    await tester.scrollUntilVisible(
      finder,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Future<void> openColor(WidgetTester tester, SkipKind kind) async {
    final row = find.byKey(ValueKey('settings-player-skip-color-${kind.name}'));
    await reveal(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  testWidgets('七类颜色在窄窗口可达并有名称、十六进制和色点', (tester) async {
    await pumpPage(tester);
    const expected = {
      SkipKind.recap: '#22B8CF',
      SkipKind.intro: '#38D9A9',
      SkipKind.outro: '#A78BFA',
      SkipKind.preview: '#4DABF7',
      SkipKind.postCredits: '#F783AC',
      SkipKind.advertisement: '#FF6B6B',
      SkipKind.intermission: '#FFD43B',
    };
    for (final entry in expected.entries) {
      final row = find.byKey(
        ValueKey('settings-player-skip-color-${entry.key.name}'),
      );
      await reveal(tester, row);
      expect(
        find.descendant(of: row, matching: find.text(entry.key.label)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text(entry.value)),
        findsOneWidget,
      );
      final swatch = tester.widget<Container>(
        find.byKey(
          ValueKey('settings-player-skip-color-swatch-${entry.key.name}'),
        ),
      );
      expect(
        (swatch.decoration as BoxDecoration).color,
        Color(int.parse('FF${entry.value.substring(1)}', radix: 16)),
      );
    }
    expect(tester.takeException(), isNull);
  });

  const customColors = {
    '#1aB2c3': 0xFF1AB2C3,
    '#ABCDEF': 0xFFABCDEF,
    '#FFFFFF': 0xFFFFFFFF,
    '#000000': 0xFF000000,
  };
  for (final entry in customColors.entries) {
    final input = entry.key;
    testWidgets('自定义颜色 $input 即时回显、落盘并重载保留，不改跳过设置', (tester) async {
      await tester.runAsync(
        () => state.setPlayerOptions(
          state.playerOptions.copyWith(
            skipMode: SkipMode.confirm,
            skipKinds: SkipKindBits.intro | SkipKindBits.preview,
            skipRemoteEnabled: false,
            skipSources: SkipSourceBits.todb,
          ),
        ),
      );
      final before = state.playerOptions;
      await pumpPage(tester);
      await openColor(tester, SkipKind.intro);
      await tester.enterText(
        find.byKey(const ValueKey('skip-color-input')),
        input,
      );
      await tester.tap(find.byKey(const ValueKey('skip-color-save')));
      await _flush(tester);
      final wanted = entry.value;
      expect(
        state.playerOptions.skipSegmentColors.colorFor(SkipKind.intro),
        wanted,
      );
      expect(
        state.playerOptions.skipSegmentColors.colorFor(SkipKind.outro),
        before.skipSegmentColors.colorFor(SkipKind.outro),
      );
      expect(
        state.playerOptions,
        before.copyWith(
          skipSegmentColors: before.skipSegmentColors.withColor(
            SkipKind.intro,
            wanted,
          ),
        ),
      );
      expect(find.text(input.toUpperCase()), findsOneWidget);
      final raw = jsonDecode(
        File(state.paths.settingsPath).readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(raw['player']['skipSegmentColors']['intro'], wanted);
      final reloadLog = LogService();
      final reloaded = AppState(paths: state.paths, log: reloadLog);
      await tester.runAsync(() => reloaded.bootstrap());
      expect(reloaded.playerOptions, state.playerOptions);
      reloaded.dispose();
      await tester.runAsync(reloadLog.dispose);
    });
  }

  testWidgets('非法颜色显示行内错误且不保存，取消编辑不修改设置或磁盘', (tester) async {
    await tester.runAsync(
      () => state.setPlayerOptions(
        state.playerOptions.copyWith(skipMode: SkipMode.confirm),
      ),
    );
    final before = state.playerOptions;
    final written = File(state.paths.settingsPath).readAsStringSync();
    await pumpPage(tester);
    await openColor(tester, SkipKind.advertisement);
    for (final input in ['#12345', '#GG0000', '#AA123456', '123456', '']) {
      await tester.enterText(
        find.byKey(const ValueKey('skip-color-input')),
        input,
      );
      await tester.tap(find.byKey(const ValueKey('skip-color-save')));
      await tester.pumpAndSettle();
      expect(find.text('请输入 #RRGGBB 格式的颜色，例如 #38D9A9'), findsOneWidget);
      expect(find.byType(GlassAlertDialog), findsOneWidget);
      expect(state.playerOptions, before);
      expect(File(state.paths.settingsPath).readAsStringSync(), written);
    }
    await tester.enterText(
      find.byKey(const ValueKey('skip-color-input')),
      '#123456',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassAlertDialog), findsNothing);
    expect(state.playerOptions, before);
    expect(File(state.paths.settingsPath).readAsStringSync(), written);
  });

  for (final brightness in Brightness.values) {
    testWidgets('白色和黑色色点在 ${brightness.name} 主题保留轮廓与可访问名称', (tester) async {
      await tester.runAsync(
        () => state.setPlayerOptions(
          state.playerOptions.copyWith(
            skipSegmentColors: const SkipSegmentColors(
              intro: 0xFFFFFFFF,
              outro: 0xFF000000,
            ),
          ),
        ),
      );
      await pumpPage(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness),
          home: IntroSkipOptionsPage(state: state),
        ),
      );
      final semantics = tester.ensureSemantics();

      for (final kind in [SkipKind.intro, SkipKind.outro]) {
        final row = find.byKey(
          ValueKey('settings-player-skip-color-${kind.name}'),
        );
        await reveal(tester, row);
        expect(tester.getSemantics(row).label, contains(kind.label));
        final swatch = tester.widget<Container>(
          find.byKey(
            ValueKey('settings-player-skip-color-swatch-${kind.name}'),
          ),
        );
        final decoration = swatch.decoration as BoxDecoration;
        final border = decoration.border! as Border;
        expect(border.top.width, greaterThan(0));
        expect(border.top.color, isNot(decoration.color));
      }
      semantics.dispose();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('预设填入草稿，保存后只改当前类型，整体恢复默认也落盘', (tester) async {
    await pumpPage(tester);
    await openColor(tester, SkipKind.intermission);
    await tester.tap(find.byKey(const ValueKey('skip-color-preset-FFFFEB3B')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('skip-color-preset-FFFFEB3B')),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('skip-color-preset-FFFFEB3B')),
          )
          .showCheckmark,
      isTrue,
    );
    expect(
      state.playerOptions.skipSegmentColors.colorFor(SkipKind.intermission),
      0xFFFFD43B,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('skip-color-input')))
          .controller!
          .text,
      '#FFEB3B',
    );
    await tester.tap(find.byKey(const ValueKey('skip-color-save')));
    await _flush(tester);
    expect(
      state.playerOptions.skipSegmentColors.colorFor(SkipKind.intermission),
      0xFFFFEB3B,
    );
    final reset = find.byKey(
      const ValueKey('settings-player-skip-colors-reset'),
    );
    await reveal(tester, reset);
    await tester.tap(reset);
    await _flush(tester);
    expect(state.playerOptions.skipSegmentColors, const SkipSegmentColors());
    final raw = jsonDecode(
      File(state.paths.settingsPath).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(raw['player']['skipSegmentColors']['intermission'], 0xFFFFD43B);
    expect(state.playerOptions.skipMode, SkipMode.off);
    expect(state.playerOptions.skipKinds, SkipKindBits.defaults);
  });
}
