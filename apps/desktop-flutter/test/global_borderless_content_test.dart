import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/home_feed.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_content/ai_content_widgets.dart';
import 'package:webhtv_pc/ui/home_cards.dart';
import 'package:webhtv_pc/ui/search_page.dart';
import 'package:webhtv_pc/ui/search_result_view.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

import 'support/detail_test_seams.dart';

Iterable<BoxDecoration> decorations(WidgetTester tester, Finder subtree) =>
    tester
        .widgetList<DecoratedBox>(
          find.descendant(of: subtree, matching: find.byType(DecoratedBox)),
        )
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>();

void main() {
  final theme = buildAppTheme(Brightness.light);

  testWidgets(
    'popup retains its rounded silhouette but paints no edge or sheen',
    (tester) async {
      final shape = ContentMenuBorder(theme);
      const rect = Rect.fromLTWH(0, 0, 80, 64);
      expect(shape.getOuterPath(rect).contains(const Offset(1, 1)), isFalse);
      expect(shape.getOuterPath(rect).contains(rect.center), isTrue);
      final painted = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        shape.paint(canvas, rect);
        final picture = recorder.endRecording();
        try {
          final image = await picture.toImage(80, 64);
          try {
            final pixels = (await image.toByteData())!.buffer.asUint8List();
            return pixels.where((channel) => channel != 0).length;
          } finally {
            image.dispose();
          }
        } finally {
          picture.dispose();
        }
      });
      expect(
        painted,
        0,
        reason: 'The popup shape must not tint even the interior',
      );
    },
  );

  testWidgets('recent poster has no frame but retains its progress rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: HomePosterCard(
            item: const HomeItem(
              kind: HomeItemKind.resume,
              key: 'resume',
              title: '剧集',
              progress: .4,
            ),
            onTap: () {},
            width: 120,
          ),
        ),
      ),
    );
    final frame = find.byKey(HomePosterCard.posterFrameKey);
    expect(tester.getSize(frame), const Size(120, 180));
    expect(
      tester.getSize(find.byKey(HomePosterCard.progressKey)),
      const Size(48, 3),
    );
    expect(decorations(tester, frame).where((d) => d.border != null), isEmpty);
  });

  testWidgets(
    'AI confidence badge conveys caution through fill and text, not a frame',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(body: AiConfidenceBadge(confidence: .31)),
        ),
      );
      expect(find.text('低置信 31%'), findsOneWidget);
      final fill = decorations(
        tester,
        find.byType(AiConfidenceBadge),
      ).singleWhere((d) => d.color != null);
      expect(fill.color, isNot(Colors.transparent));
      expect(fill.border, isNull);
    },
  );

  testWidgets('selected search poster uses a tint rather than a frame', (
    tester,
  ) async {
    final poster = find.byKey(const ValueKey('selected-poster'));
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: PosterCard(
            posterKey: const ValueKey('selected-poster'),
            title: '片名',
            highlighted: true,
            onTap: () {},
          ),
        ),
      ),
    );
    final boxes = decorations(tester, poster).toList();
    expect(boxes.where((d) => d.border != null), isEmpty);
    expect(
      boxes.any(
        (d) => d.color == theme.colorScheme.primary.withValues(alpha: .16),
      ),
      isTrue,
    );
  });

  testWidgets(
    'recent and active cross-source episodes use different fills, not frames',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 180,
                  child: TmdbEpisodeCardTile(
                    buttonKey: const ValueKey('recent'),
                    card: const TmdbEpisodeCard(number: 1, title: '第一集'),
                    width: 180,
                    isRecent: true,
                    onTap: () => opened++,
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: TmdbEpisodeCardTile(
                    buttonKey: const ValueKey('foreign'),
                    card: const TmdbEpisodeCard(number: 2, title: '第二集'),
                    width: 180,
                    foreignMark: const EpisodeForeignProgressMark(
                      count: 1,
                      percent: 40,
                      detail: '其他站点',
                      active: true,
                    ),
                    onTap: () => opened++,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      for (final (key, fill) in [
        ('recent', theme.colorScheme.primaryContainer),
        ('foreign', theme.colorScheme.tertiaryContainer),
      ]) {
        final button = find.byKey(ValueKey(key));
        final style = tester.widget<OutlinedButton>(button).style!;
        expect(style.side?.resolve({}), anyOf(isNull, BorderSide.none));
        expect(style.backgroundColor?.resolve({}), fill);
        await tester.tap(button);
        await tester.pump();
      }
      expect(opened, 2);
      expect(find.text('上次看到这里'), findsOneWidget);
      expect(find.text('其他源 40%'), findsOneWidget);
    },
  );

  group('search scope', () {
    late Directory temp;
    late AppState state;
    setUp(() async {
      temp = Directory.systemTemp.createTempSync('borderless-search-');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/config',
            'data': '${temp.path}/data',
            'cache': '${temp.path}/cache',
            'state': '${temp.path}/state',
          },
        ),
        log: MemoryOnlyLogService(),
        httpClient: MockClient((_) async => http.Response('{"list":[]}', 200)),
      );
      await bootstrapWithoutExternalMeta(state);
      await state.importConfig('''
        {"name":"样片","sites":[{"key":"s","name":"样片站","type":1,"searchable":1,"api":"http://127.0.0.1:19978/vod/api"}]}
      ''');
    });
    tearDown(() {
      state.dispose();
      temp.deleteSync(recursive: true);
    });

    testWidgets(
      'scope remains unframed, keyboard dismisses the menu and selected scope is visible',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(body: SearchPage(state: state)),
          ),
        );
        await tester.pump();
        final input = find.byKey(const ValueKey('search-input'));
        final scope = find.byKey(const ValueKey('search-scope'));
        final selectedSite = find.byKey(const ValueKey('search-scope-site'));
        final editable = find.descendant(
          of: input,
          matching: find.byType(EditableText),
        );
        final decorator = find.descendant(
          of: input,
          matching: find.byType(InputDecorator),
        );
        expect(
          tester.widget<EditableText>(editable).focusNode.hasFocus,
          isTrue,
        );
        expect(tester.widget<InputDecorator>(decorator).isFocused, isTrue);
        expect(
          tester
              .widget<InputDecorator>(decorator)
              .decoration
              .focusedBorder
              ?.borderSide
              .color,
          theme.colorScheme.primary,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          tester.widget<EditableText>(editable).focusNode.hasFocus,
          isFalse,
        );
        expect(
          tester
              .widget<InputDecorator>(decorator)
              .decoration
              .enabledBorder
              ?.borderSide,
          BorderSide.none,
        );

        final scopeFace = find.descendant(
          of: scope,
          matching: find.byType(Ink),
        );
        expect(tester.widget<Ink>(scopeFace).decoration, isNull);
        await tester.tap(scope);
        await tester.pumpAndSettle();
        expect(selectedSite, findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(selectedSite, findsNothing);
        await tester.tap(scope);
        await tester.pumpAndSettle();
        await tester.tap(selectedSite);
        await tester.pumpAndSettle();
        expect(find.text('当前站点：样片站'), findsOneWidget);
        final scopedIcon = find.descendant(
          of: scope,
          matching: find.byIcon(Icons.filter_alt_outlined),
        );
        expect(
          tester.widget<Icon>(scopedIcon).color,
          theme.colorScheme.primary,
        );
        final scopedFace =
            tester.widget<Ink>(scopeFace).decoration! as BoxDecoration;
        expect(scopedFace.border, isNull);
        expect(scopedFace.color, theme.colorScheme.primaryContainer);
        await tester.enterText(input, '片名');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(state.activeSearch?.keyword, '片名');
        expect(state.activeSearch?.siteKey, 's');
      },
    );
  });
}
