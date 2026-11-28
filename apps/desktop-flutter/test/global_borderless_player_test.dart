import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/player_episode_panel.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/player_parse_source_strip.dart';
import 'package:webhtv_pc/ui/player_queue_panel.dart';
import 'package:webhtv_pc/ui/player_quality_panel.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'player_queue_test.dart' show QueueFixture;
import 'support/player_page_harness.dart';

Future<void> mount(
  WidgetTester tester,
  Widget child,
  Brightness brightness,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(brightness),
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

double contrast(Color a, Color b) {
  final l1 = a.computeLuminance();
  final l2 = b.computeLuminance();
  return l1 > l2 ? (l1 + .05) / (l2 + .05) : (l2 + .05) / (l1 + .05);
}

void expectBorderlessChips(WidgetTester tester) {
  final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).toList();
  expect(chips.length, greaterThanOrEqualTo(2));
  for (final chip in chips) {
    expect(
      chip.side?.style,
      BorderStyle.none,
      reason:
          'Ordinary and selected player chips use fill/text, not static sides',
    );
  }
  final selected = chips.firstWhere((chip) => chip.selected);
  final idle = chips.firstWhere((chip) => !chip.selected);
  expect(selected.selectedColor, isNot(idle.backgroundColor));
  expect(selected.labelStyle?.color, isNot(idle.labelStyle?.color));
}

void main() {
  testWidgets('subtitle swatches use selection icon without inert rings', (
    tester,
  ) async {
    await pumpPlayerPage(tester, size: const Size(1280, 800));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    });
    await tester.tap(find.byTooltip('更多'));
    await settlePlayerPage(tester, times: 2);
    await tester.tap(find.text('字幕样式'));
    await settlePlayerPage(tester, times: 2);
    final swatches = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration! as BoxDecoration).shape == BoxShape.circle &&
          widget.constraints?.maxWidth == 30,
    );
    expect(swatches, findsNWidgets(6));
    for (final widget in tester.widgetList<Container>(swatches)) {
      expect((widget.decoration! as BoxDecoration).border, isNull);
    }
    expect(
      find.descendant(of: swatches, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    await tester.tap(swatches.at(1));
    await tester.pump();
    expect(
      find.descendant(of: swatches.at(1), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('borderless source keeps incumbent one-pixel chip inset', (
    tester,
  ) async {
    final theme = buildAppTheme(Brightness.dark);
    await mount(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 600,
            child: PlayerParseSourceStrip(
              sources: const ['超级解析', '备用解析'],
              selected: '超级解析',
              onSelect: (_) {},
            ),
          ),
          ChoiceChip(
            key: const ValueKey('incumbent-chip'),
            label: const Text('备用解析'),
            selected: false,
            onSelected: (_) {},
            showCheckmark: false,
            side: BorderSide(color: theme.colorScheme.outlineVariant),
            labelStyle: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      Brightness.dark,
    );
    final actual = tester.getSize(
      find.byKey(const ValueKey('player-parse-source-1')),
    );
    final incumbent = tester.getSize(
      find.byKey(const ValueKey('incumbent-chip')),
    );
    expect(
      actual.width,
      closeTo(incumbent.width, 0.5),
      reason: 'Removing paint must preserve the chip width to within a half-pixel across list constraints',
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'quality choice keeps selected check and distinct unselected marker ${brightness.name}',
      (tester) async {
        await mount(
          tester,
          const PlayerQualityPanel(
            qualities: [
              PlaybackQuality(
                name: '蓝光 1080P',
                url: 'https://example.test/1080',
              ),
              PlaybackQuality(name: '超清 4K', url: 'https://example.test/4k'),
            ],
            selectedIndex: 0,
          ),
          brightness,
        );
        final current = tester.widget<ListTile>(
          find.byKey(playerQualityOptionKey(0)),
        );
        final idle = tester.widget<ListTile>(
          find.byKey(playerQualityOptionKey(1)),
        );
        expect(current.selected, isTrue);
        expect(idle.selected, isFalse);
        expect((current.trailing! as Icon).icon, Icons.check);
        expect(idle.trailing, isNull);
      },
    );

    testWidgets(
      'episode cards and chips are borderless with playing feedback ${brightness.name}',
      (tester) async {
        final episodes = List.generate(
          3,
          (i) => VodEpisode(name: '第${i + 1}集', url: 'https://example.test/$i'),
        );
        await mount(
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
            onSelectEpisode: (_, _) {},
          ),
          brightness,
        );
        expectBorderlessChips(tester);
        for (var i = 0; i < 3; i++) {
          final tile = tester.widget<Container>(
            find.byKey(ValueKey('player-episode-card-$i')),
          );
          expect((tile.decoration! as BoxDecoration).border, isNull);
        }
        final currentTitle = tester.widget<Text>(find.text('第1集'));
        final idleTitle = tester.widget<Text>(find.text('第2集'));
        expect(currentTitle.style?.color, isNot(idleTitle.style?.color));
        expect(currentTitle.style?.fontWeight, FontWeight.w700);
        final currentTile = tester.widget<Container>(
          find.byKey(const ValueKey('player-episode-card-0')),
        );
        final idleTile = tester.widget<Container>(
          find.byKey(const ValueKey('player-episode-card-1')),
        );
        expect(
          (currentTile.decoration! as BoxDecoration).color,
          isNot((idleTile.decoration! as BoxDecoration).color),
        );
        expect(
          contrast(
            currentTitle.style!.color!,
            (currentTile.decoration! as BoxDecoration).color!,
          ),
          greaterThanOrEqualTo(4.5),
        );
        await tester.tap(find.text('备用线路'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.text('第1集')).style?.fontWeight,
          FontWeight.w500,
        );
        expectBorderlessChips(tester);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(
          field.decoration?.border,
          isNull,
          reason: 'Local base border must defer to theme normal-none/focused/error semantics',
        );
        var input = tester.widget<InputDecorator>(find.byType(InputDecorator));
        expect(
          input.decoration.enabledBorder?.borderSide.style,
          BorderStyle.none,
        );
        await tester.tap(find.byType(TextField));
        await tester.pumpAndSettle();
        input = tester.widget<InputDecorator>(find.byType(InputDecorator));
        expect(input.isFocused, isTrue);
        expect(
          input.decoration.focusedBorder?.borderSide.style,
          BorderStyle.solid,
        );
        expect(
          input.decoration.errorBorder?.borderSide.style,
          BorderStyle.solid,
        );
      },
    );

    testWidgets(
      'parse source sides absent and current source distinguishable ${brightness.name}',
      (tester) async {
        String? chosen;
        await mount(
          tester,
          SizedBox(
            width: 600,
            child: PlayerParseSourceStrip(
              sources: const ['超级解析', '备用解析'],
              selected: '超级解析',
              onSelect: (value) => chosen = value,
            ),
          ),
          brightness,
        );
        expectBorderlessChips(tester);
        await tester.tap(find.text('备用解析'));
        expect(chosen, '备用解析');
      },
    );

    testWidgets(
      'queue ordinary frames absent and current title distinct ${brightness.name}',
      (tester) async {
        final queue = QueueFixture();
        addTearDown(queue.dispose);
        await mount(
          tester,
          PlayerQueuePanel(
            title: '播放队列',
            queue: queue,
            currentKey: 'opaque-file-A',
            onSelect: (_) {},
            playLines: const [],
            lineFlag: '',
            onSelectLine: (_) {},
          ),
          brightness,
        );
        final colors = <Color?>[];
        for (final key in ['opaque-file-A', 'opaque-file-B']) {
          final material = tester.widget<Material>(
            find
                .descendant(
                  of: find.byKey(ValueKey('player-queue-item-$key')),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(
            (material.shape! as RoundedRectangleBorder).side,
            BorderSide.none,
          );
          colors.add(material.color);
        }
        expect(colors[0], isNot(colors[1]));
        final currentTitle = tester.widget<Text>(find.text('第01集 星空初遇.mkv'));
        expect(
          contrast(currentTitle.style!.color!, colors[0]!),
          greaterThanOrEqualTo(4.5),
        );
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.decoration?.border, isNull);
      },
    );

    testWidgets(
      'overlay separator paints nothing while its slot stays ${brightness.name}',
      (tester) async {
        await mount(tester, const PlayerOverlayDivider(), brightness);
        expect(
          tester.getSize(find.byType(PlayerOverlayDivider)),
          const Size(9, 20),
        );
        expect(
          find.descendant(
            of: find.byType(PlayerOverlayDivider),
            matching: find.byType(DecoratedBox),
          ),
          findsNothing,
        );
      },
    );
  }
}
