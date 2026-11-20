import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';

import 'support/test_fonts.dart';

void main() {
  setUpAll(() async {
    await loadFixtureFonts(cjkFamily: 'Noto Sans CJK SC');
    await loadFixtureFonts(cjkFamily: 'Roboto');
  });

  for (final (source, scraped, want) in [
    ('S01E01.Long.Source.Name.mkv', 'E1 开端', 'S01E01.Long.Source.Name.mkv'),
    ('', 'E1 开端', 'E1 开端'),
    ('第1集', '第1集', '第1集'),
  ]) {
    testWidgets('原名模式显示 $want 且悬浮提示一致', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              child: TmdbEpisodeStrip(
                cards: [
                  TmdbEpisodeCard(
                    number: 1,
                    title: scraped,
                    sourceName: source,
                  ),
                ],
                showScrapedName: false,
                onTap: (_, _) {},
              ),
            ),
          ),
        ),
      );
      expect(find.text(want), findsOneWidget);
      expect(find.byTooltip('播放 · $want'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('长线路标题不会挤出名称开关 ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: TmdbEpisodeHeader(
                episodeCount: 100,
                onToggleAggregation: () {},
                reversed: false,
                gridMode: true,
                lineName: '这是一条需要安全省略而不能挤走操作按钮的很长的线路名称' * 3,
                onToggleNameMode: () {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final toggle = find.byKey(const ValueKey('tmdb-episode-name-mode'));
      expect(tester.getRect(toggle).right, lessThanOrEqualTo(1024));
      expect(find.byTooltip('切换为原始名称'), findsOneWidget);
      final aggregate = find.byKey(const ValueKey('tmdb-episode-aggregation'));
      expect(tester.getRect(aggregate).right, lessThanOrEqualTo(1024));
      expect(
        tester.getRect(aggregate).left,
        greaterThan(tester.getRect(toggle).left),
      );
    });

    testWidgets('名称模式可视化 ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(1024, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundary = GlobalKey();
      var showScraped = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: StatefulBuilder(
                  builder: (context, setState) => Column(
                    children: [
                      TmdbEpisodeHeader(
                        episodeCount: 7,
                        reversed: false,
                        gridMode: true,
                        lineName: 'quark',
                        showScrapedName: showScraped,
                        onToggleNameMode: () => setState(() {
                          showScraped = !showScraped;
                        }),
                      ),
                      TmdbEpisodeStrip(
                        cards: [
                          for (var i = 1; i <= 7; i++)
                            TmdbEpisodeCard(
                              number: i,
                              title: 'E$i 第$i集的刮削标题',
                              sourceName: '剧名.S01E0$i.1080p.WEB-DL.mkv',
                              date: '2026-11-20',
                              runtime: 42,
                            ),
                        ],
                        cardWidth: 160,
                        gridMode: true,
                        showScrapedName: showScraped,
                        onTap: (_, _) {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      for (final mode in ['scraped', 'original']) {
        if (mode == 'original') {
          await tester.tap(
            find.byKey(const ValueKey('tmdb-episode-name-mode')),
          );
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.text(
            mode == 'original' ? '剧名.S01E01.1080p.WEB-DL.mkv' : 'E1 第1集的刮削标题',
          ),
          findsOneWidget,
        );
        if (Platform.environment['EPISODE_NAME_CAPTURE'] != '1') continue;
        await tester.runAsync(() async {
          final render = boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            '../../.local/episode-name/after-${brightness.name}-$mode.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
}
