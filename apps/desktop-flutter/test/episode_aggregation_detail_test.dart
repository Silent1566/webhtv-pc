import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/episode_aggregation.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/episode_version_dialog.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/test_fonts.dart';

EpisodeGroup group() => EpisodeGroup(
  key: 's1e1',
  seasonNumber: 1,
  episodeNumber: 1,
  versions: [
    EpisodeVersion(
      episode: VodEpisode(
        name: '海岸线.S01E01.1080p.WEB-DL.H265[1GB].mkv',
        url: 'raw-a',
      ),
      sourceIndex: 4,
      fileSize: EpisodeFileSize(label: '1 GB', bytes: 1e9),
    ),
    EpisodeVersion(
      episode: VodEpisode(
        name: '海岸线.S01E01.2160p.WEB-DL.H265[3GB].mkv',
        url: 'raw-b',
      ),
      sourceIndex: 8,
      fileSize: EpisodeFileSize(label: '3 GB', bytes: 3e9),
    ),
  ],
);

void main() {
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
    await loadFixtureFonts(cjkFamily: 'Roboto');
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'explicit confirmation returns exact historical URL ${brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(1024, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        EpisodeVersion? selected;
        var returned = false;
        final boundary = GlobalKey();
        final versions = group();
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness),
            builder: (context, child) => RepaintBoundary(
              key: boundary,
              child: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    selected = await showEpisodeVersionDialog(
                      context,
                      group: versions,
                      lineName: 'quark · 很长的线路名称',
                      preferredUrl: 'raw-b',
                    );
                    returned = true;
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(returned, isFalse);
        expect(find.text(versions.versions.last.episode.name), findsOneWidget);
        expect(find.text('3 GB'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (Platform.environment['EPISODE_AGGREGATION_CAPTURE'] != null) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '../../.local/episode-aggregation/detail/modal-after-${brightness.name}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.byKey(const ValueKey('episode-version-confirm')));
        await tester.pumpAndSettle();
        expect(identical(selected, versions.versions.last), isTrue);
        expect(selected!.episode.url, 'raw-b');
        expect(selected!.sourceIndex, 8);
      },
    );
  }
  testWidgets(
    'keyboard and historical selection remain visible with many versions',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final many = EpisodeGroup(
        key: 'many',
        seasonNumber: 1,
        episodeNumber: 1,
        versions: [
          for (var i = 0; i < 18; i++)
            EpisodeVersion(
              episode: VodEpisode(
                name: 'S01E01.long.file.name.version $i.mkv',
                url: 'url-$i',
              ),
              sourceIndex: i,
            ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showEpisodeVersionDialog(
                  context,
                  group: many,
                  preferredUrl: 'url-16',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final option = find.byKey(const ValueKey('episode-version-option-16'));
      expect(option.hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('episode-version-option-17')).hitTestable(),
        findsOneWidget,
      );
      for (var i = 0; i < 17; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
      }
      expect(
        find.byKey(const ValueKey('episode-version-option-0')).hitTestable(),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Enter on focused cancel cancels rather than confirming', (
    tester,
  ) async {
    EpisodeVersion? selected;
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showEpisodeVersionDialog(
                  context,
                  group: group(),
                );
                returned = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('取消'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(selected, isNull);
  });
  testWidgets('version changes require confirm and escape cancels', (
    tester,
  ) async {
    EpisodeVersion? selected;
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showEpisodeVersionDialog(
                  context,
                  group: group(),
                );
                returned = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('episode-version-option-8')));
    await tester.pump();
    expect(returned, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(selected, isNull);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('episode-version-option-8')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected!.episode.url, 'raw-b');
  });
}
