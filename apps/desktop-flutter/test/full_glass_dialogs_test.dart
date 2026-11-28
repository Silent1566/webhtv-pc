import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku_match.dart';
import 'package:webhtv_pc/core/episode_aggregation.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/subtitle_provider.dart';
import 'package:webhtv_pc/services/danmaku_library_service.dart';
import 'package:webhtv_pc/services/subtitle_match_service.dart';
import 'package:webhtv_pc/ui/async_action_feedback.dart';
import 'package:webhtv_pc/ui/episode_version_dialog.dart';
import 'package:webhtv_pc/ui/danmaku_search_dialog.dart';
import 'package:webhtv_pc/ui/external_player_picker_dialog.dart';
import 'package:webhtv_pc/ui/recommendation_info_dialog.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/glass_surface.dart';
import 'package:webhtv_pc/ui/subtitle_search_dialog.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';

import 'support/test_fonts.dart';

const _keyword = ValueKey<String>('subtitle-search-keyword');
const _season = ValueKey<String>('subtitle-search-season');
const _query = SubtitleQuery(
  title: '星空旅行',
  season: 2,
  episode: 3,
  siteKey: 'demo',
  vodId: 'demo-1',
  episodeName: '第三集',
);
const _candidate = SubtitleCandidate(
  providerId: 'demo',
  assetId: '1',
  title: '星空旅行 · 第三集',
  language: 'zh-Hans',
  format: 'srt',
  score: 0.8,
  url: 'https://example.test/subtitle',
);

void main() {
  final captureStage = Platform.environment['GLASS_DIALOG_CAPTURE_STAGE'];
  if (captureStage != null) {
    setUpAll(() async {
      expectFontsAvailableOrSkip();
      expect(firstExisting(iconFontCandidates()), isNotNull);
      for (final family in [
        'Roboto',
        'Noto Sans CJK SC',
        'Microsoft YaHei UI',
      ]) {
        await loadFixtureFonts(cjkFamily: family);
      }
    });
    for (final brightness in Brightness.values) {
      testWidgets('capture subtitle and notifications in $brightness', (
        tester,
      ) async {
        final boundary = GlobalKey();
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        addTearDown(toastCenter.dismissAll);
        await _showSubtitle(tester, brightness: brightness, boundary: boundary);
        await tester.tap(find.byKey(const ValueKey('subtitle-search-submit')));
        await tester.pumpAndSettle();
        toastCenter.show('字幕搜索已完成', detail: '找到 1 条可用结果。');
        toastCenter.show('本地文件无法读取', kind: ToastKind.error);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        await _capture(tester, boundary, '$captureStage-${brightness.name}');
      });
    }
  }

  testWidgets(
    'subtitle dialog has one bounded filter and keeps keyboard flow',
    (tester) async {
      final hits = <SubtitleQuery>[];
      final results = <SubtitleCandidate?>[];
      await _showSubtitle(tester, hits: hits, results: results);
      final filter = find.byType(BackdropFilter);
      expect(filter, findsOneWidget);
      expect(tester.getSize(filter).width, 720);
      expect(
        tester.getSize(filter).height,
        lessThan(tester.view.physicalSize.height),
      );
      final editable = find.descendant(
        of: find.byKey(_keyword),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
      await tester.enterText(find.byKey(_keyword), '搜索关键词');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(hits.single.title, '搜索关键词');
      expect(find.text(_candidate.title), findsOneWidget);
      await tester.tap(find.byKey(_keyword));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final season = find.descendant(
        of: find.byKey(_season),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(season).focusNode.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(_keyword), findsNothing);
      expect(results, [null]);
    },
  );

  testWidgets(
    'alert keeps a local dialog barrier and lays out lazy content with wrapped actions',
    (tester) async {
      tester.view.physicalSize = const Size(310, 470);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const localBarrier = Color(0x44006600);
      var confirmed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DialogTheme(
              data: const DialogThemeData(barrierColor: localBarrier),
              child: Builder(
                builder: (context) => FilledButton(
                  onPressed: () => showGlassDialog<void>(
                    context: context,
                    builder: (context) => GlassAlertDialog(
                      title: const Text('选择条目'),
                      content: ListView.builder(
                        itemCount: 50,
                        itemBuilder: (_, i) => Text('结果 $i'),
                      ),
                      actions: [
                        FilledButton(
                          onPressed: () => confirmed = true,
                          child: const Text('Confirm selected item'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel changes'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('打开列表'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开列表'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<AnimatedModalBarrier>(find.byType(AnimatedModalBarrier))
            .color
            .value,
        localBarrier,
      );
      expect(
        tester.widget<Dialog>(find.byType(Dialog)).semanticsRole,
        ui.SemanticsRole.alertDialog,
      );
      expect(
        tester.getRect(find.text('Cancel changes')).top,
        greaterThan(tester.getRect(find.text('Confirm selected item')).bottom),
      );
      expect(find.text('结果 49'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -205));
      await tester.pumpAndSettle();
      expect(find.text('结果 0').hitTestable(), findsNothing);
      await tester.tap(find.text('Confirm selected item'));
      expect(confirmed, isTrue);
    },
  );

  testWidgets(
    'video episode picker retains glass without sampling the backdrop',
    (tester) async {
      final version = EpisodeVersion(
        episode: VodEpisode(name: '第1集', url: 'https://example.test/1'),
        sourceIndex: 0,
      );
      final results = <EpisodeVersion?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => results.add(
                  await showEpisodeVersionDialog(
                    context,
                    group: EpisodeGroup(
                      key: 'episode-1',
                      seasonNumber: 1,
                      episodeNumber: 1,
                      versions: [version],
                    ),
                    blurBackdrop: false,
                  ),
                ),
                child: const Text('打开版本'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开版本'));
      await tester.pumpAndSettle();
      expect(find.byType(GlassSurface), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(results, [version]);
    },
  );

  testWidgets(
    'scrollable alert keeps actions reachable at enlarged text scale',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var dismissed = false;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  await showGlassDialog<void>(
                    context: context,
                    builder: (context) => GlassAlertDialog(
                      scrollable: true,
                      constraints: const BoxConstraints(maxWidth: 600),
                      title: const Text('导入配置说明'),
                      content: const SizedBox(
                        height: 1000,
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: Text('最后一行'),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('取消'),
                        ),
                      ],
                    ),
                  );
                  dismissed = true;
                },
                child: const Text('打开说明'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开说明'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(BackdropFilter)).width, 600);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -1000),
      );
      await tester.pumpAndSettle();
      expect(find.text('最后一行').hitTestable(), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(dismissed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in ['subtitle', 'danmaku', 'external']) {
    testWidgets('$kind player popup disables backdrop sampling', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  if (kind == 'subtitle') {
                    showSubtitleSearchDialog(
                      context: context,
                      initialQuery: _query,
                      search: (_) async => const SubtitleSearchReport(),
                      blurBackdrop: false,
                    );
                  } else if (kind == 'danmaku') {
                    showDanmakuSearchDialog(
                      context: context,
                      sources: const [],
                      query: const DanmakuQuery(
                        title: '星空',
                        siteKey: 'demo',
                        vodId: '1',
                        episodeName: '第1集',
                      ),
                      runner: ({
                        required sources,
                        required title,
                        episode,
                        onSourceResult,
                      }) async => const DanmakuLibraryQueryResult.empty(),
                      blurBackdrop: false,
                    );
                  } else {
                    showGlassDialog<void>(
                      context: context,
                      builder: (_) => ExternalPlayerPickerDialog(
                        loadPlayers: () async => [],
                        savePlayer: ({
                          originalExecutable,
                          required name,
                          required executable,
                        }) async => true,
                        blurBackdrop: false,
                      ),
                    );
                  }
                },
                child: const Text('打开播放器弹窗'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开播放器弹窗'));
      await tester.pumpAndSettle();
      expect(find.byType(GlassSurface), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(GlassSurface), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(1024, 640), const Size(1280, 800)]) {
    testWidgets(
      'recommendation bounded glass retains the source search action at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var searched = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showRecommendationInfo(
                    context,
                    info: RecommendationInfo(
                      title: '星空旅行',
                      sourceLabel: 'TMDB',
                      overview: List.filled(24, '沿着星光继续旅行。').join(),
                    ),
                    onSearchSource: () => searched = true,
                    onOpen: () {},
                  ),
                  child: const Text('推荐详情'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('推荐详情'));
        await tester.pumpAndSettle();
        expect(find.byType(BackdropFilter), findsOneWidget);
        expect(
          tester.getSize(find.byType(BackdropFilter)).width,
          lessThanOrEqualTo(720),
        );
        await tester.tap(
          find.byKey(const ValueKey('recommendation-info-search')),
        );
        await tester.pumpAndSettle();
        expect(searched, isTrue);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('transient feedback and toasts are bounded glass surfaces', (
    tester,
  ) async {
    AsyncActionFeedback? feedback;
    addTearDown(() => feedback?.close());
    addTearDown(toastCenter.dismissAll);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => Stack(
          fit: StackFit.expand,
          children: [
            child!,
            const Material(type: MaterialType.transparency, child: ToastHost()),
          ],
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () =>
                  feedback = AsyncActionFeedback.begin(context, '准备播放'),
              child: const Text('播放'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('播放'));
    final info = toastCenter.show('播放提示');
    final error = toastCenter.show('播放失败', kind: ToastKind.error);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));
    for (final key in [
      'async-action-feedback',
      'app-toast-$info',
      'app-toast-$error',
    ]) {
      final panel = find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(GlassSurface),
      );
      expect(panel, findsOneWidget);
      expect(tester.getSize(panel).width, lessThan(420));
    }
    expect(find.byType(BackdropFilter), findsNothing);
  });
}

Future<void> _showSubtitle(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
  GlobalKey? boundary,
  List<SubtitleQuery>? hits,
  List<SubtitleCandidate?>? results,
}) async {
  var theme = buildAppTheme(brightness);
  if (boundary != null) {
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: 'Noto Sans CJK SC'),
    );
    theme = theme.copyWith(
      dialogTheme: theme.dialogTheme.copyWith(
        titleTextStyle: theme.textTheme.titleLarge,
        contentTextStyle: theme.textTheme.bodyMedium,
      ),
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => RepaintBoundary(
        key: boundary,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (boundary != null) const DefaultGlassBackdrop(),
            child!,
            if (boundary != null)
              const Material(
                type: MaterialType.transparency,
                child: ToastHost(),
              ),
          ],
        ),
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                final selection = await showSubtitleSearchDialog(
                  context: context,
                  initialQuery: _query,
                  search: (query) async {
                    hits?.add(query);
                    return const SubtitleSearchReport(candidates: [_candidate]);
                  },
                  pickLocalFile: () async => null,
                );
                results?.add(selection);
              },
              child: const Text('打开字幕搜索'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开字幕搜索'));
  await tester.pumpAndSettle();
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  final target = Directory('../../.local/glass-full-captures/glass-dialogs');
  await tester.runAsync(() async {
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: 1);
    try {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await target.create(recursive: true);
      await File('${target.path}/$name.png')
          .writeAsBytes(png.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
