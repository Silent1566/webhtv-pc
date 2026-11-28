import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ai_content/recommendation_feedback.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/watched_recommendation.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/recommendation_feedback_manager.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/settings_navigation.dart';
import 'support/settings_row_navigation.dart';

const _entry = ValueKey('settings-recommendation-feedback-open');
const _capture = ValueKey('recommendation-feedback-capture');

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('recommendation-feedback-ui-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'state'),
      },
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    for (final dir in [
      paths.configDir,
      paths.dataDir,
      paths.cacheDir,
      paths.logDir,
    ]) {
      expect(p.isWithin(temp.path, dir), isTrue);
    }
    state = AppState(paths: paths, log: LogService());
    addTearDown(state.dispose);
    await state.bootstrap();
    expect(state.aiConfig.isReady, isFalse);
  });

  tearDown(dismissAllToasts);

  Future<void> pumpPreferences(
    WidgetTester tester, {
    ThemeData? theme,
    Size size = const Size(1072, 728),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme ?? buildAppTheme(Brightness.dark),
          home: Scaffold(body: SettingsPage(state: state)),
        ),
      ),
    );
    await pumpSettingsSettled(tester);
  }

  Future<void> openFeedback(WidgetTester tester) async {
    final entry = find.byKey(_entry);
    expect(entry.hitTestable(), findsOneWidget, reason: '偏好首屏必须直接可点');
    await tester.tap(entry);
    await pumpSettingsSettled(tester);
  }

  void seedWatched() {
    for (final (title, year) in [
      ('花样年华', 2000),
      ('千与千寻', 2001),
      ('海街日记', 2015),
      ('宇宙探索编辑部', 2023),
    ]) {
      expect(
        state.recommendationDependencies.watched.setWatched(
          RecommendationWork(
            title: title,
            mediaType: TmdbMediaType.movie,
            year: year,
          ),
          true,
        ),
        isTrue,
      );
    }
  }

  Future<void> seedDislikes() async {
    state.recommendationDependencies.feedback.block('漫长的季节');
    final now = DateTime.now();
    final feedback = RecommendationFeedbackCollection.empty().add(
      RecommendationFeedbackEntry(
        title: '星际穿越',
        createdAtMs: now.millisecondsSinceEpoch,
      ),
      now: now,
    );
    expect(await state.aiIntegration.userData.saveFeedback(feedback), isTrue);
  }

  testWidgets(
    'opens recommendation feedback directly from Preferences with AI disabled',
    (tester) async {
      seedWatched();
      await pumpPreferences(tester);
      await openFeedback(tester);
      expect(find.text('推荐反馈'), findsOneWidget);
      expect(find.text('已看'), findsOneWidget);
      expect(find.text('不感兴趣'), findsOneWidget);
      expect(find.text('花样年华'), findsOneWidget);
      expect(find.text('2000 · 电影'), findsOneWidget);
      await backFromSettingsDetail(tester);
      expect(find.byKey(_entry).hitTestable(), findsOneWidget);
      await openAboutDataSettings(tester);
      expect(find.byKey(_entry), findsNothing);
    },
  );

  testWidgets('feedback entry is visible on narrow settings windows', (tester) async {
    await pumpPreferences(tester, size: const Size(480, 640));
    await openFeedback(tester);
    expect(find.text('暂无「已看」记录'), findsOneWidget);
  });

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsOneWidget);
  }

  Future<void> showDislikes(WidgetTester tester) async {
    await tester.runAsync(() => tester.tap(find.text('不感兴趣')));
    await tester.pump();
    await waitFor(tester, find.text('漫长的季节'));
  }

  Future<void> select(WidgetTester tester, String title) async {
    final row = find.widgetWithText(CheckboxListTile, title);
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pump();
  }

  Future<void> confirm(WidgetTester tester, String label) async {
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, label));
      await tester.pump();
    });
  }

  testWidgets(
    'isolates selection by scope and persists single and batch deletes',
    (tester) async {
      seedWatched();
      await tester.runAsync(seedDislikes);
      await pumpPreferences(tester);
      await openFeedback(tester);
      await select(tester, '花样年华');
      expect(find.text('共 4 条 · 已选 1 条'), findsOneWidget);
      await showDislikes(tester);
      expect(find.text('共 2 条 · 已选 0 条'), findsOneWidget);
      expect(find.text('首页／详情推荐'), findsOneWidget);
      expect(find.text('AI 推荐'), findsOneWidget);
      expect(find.text('花样年华'), findsNothing);
      await select(tester, '星际穿越');
      await tester.tap(find.text('已看'));
      await pumpSettingsSettled(tester);
      expect(find.text('共 4 条 · 已选 0 条'), findsOneWidget);

      await select(tester, '花样年华');
      await tester.tap(find.text('删除选中'));
      await pumpSettingsSettled(tester);
      expect(find.textContaining('选中的 1 条'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await pumpSettingsSettled(tester);
      expect(find.text('共 4 条 · 已选 1 条'), findsOneWidget);
      expect(state.recommendationDependencies.watched.works, hasLength(4));
      await tester.tap(find.text('删除选中'));
      await pumpSettingsSettled(tester);
      await confirm(tester, '删除');
      await waitFor(tester, find.text('共 3 条 · 已选 0 条'));
      await pumpSettingsSettled(tester);
      expect(find.text('花样年华'), findsNothing);
      expect(toastCenter.toasts.single.kind, ToastKind.success);
      dismissAllToasts();

      await select(tester, '海街日记');
      await select(tester, '千与千寻');
      await tester.tap(find.text('删除选中'));
      await pumpSettingsSettled(tester);
      expect(find.textContaining('选中的 2 条'), findsOneWidget);
      await confirm(tester, '删除');
      await waitFor(tester, find.text('共 1 条 · 已选 0 条'));
      final saved = state.recommendationDependencies.watched;
      expect(saved.works.single.title, '宇宙探索编辑部');
      expect(saved.file!.readAsStringSync(), isNot(contains('千与千寻')));
      expect(
        state.recommendationDependencies.feedback.entries.single.title,
        '漫长的季节',
      );
      expect(
        (await tester.runAsync(state.aiIntegration.userData.loadFeedback))!
            .entries
            .single
            .title,
        '星际穿越',
      );
    },
  );

  testWidgets(
    'cancels clear, then clears only the active scope without playback changes',
    (tester) async {
      seedWatched();
      await tester.runAsync(seedDislikes);
      state.database!.upsertHistory(
        siteKey: 'fixture',
        vodId: 'a',
        vodName: '花样年华',
        flag: 'line',
        episodeName: '正片',
        episodeId: 'movie',
        positionMs: 20000,
        durationMs: 120000,
      );
      await pumpPreferences(tester);
      await openFeedback(tester);
      await tester.tap(find.text('全选本类'));
      await tester.pump();
      expect(find.text('共 4 条 · 已选 4 条'), findsOneWidget);
      await tester.tap(find.text('取消全选'));
      await tester.pump();
      expect(find.text('共 4 条 · 已选 0 条'), findsOneWidget);
      await tester.tap(find.text('清空已看记录'));
      await pumpSettingsSettled(tester);
      expect(find.text('清空「已看」'), findsOneWidget);
      expect(find.textContaining('全部 4 条'), findsOneWidget);
      expect(find.textContaining('不会影响播放历史'), findsWidgets);
      await tester.tap(find.text('取消'));
      await pumpSettingsSettled(tester);
      expect(state.recommendationDependencies.watched.works, hasLength(4));
      expect(toastCenter.toasts, isEmpty);

      await tester.tap(find.text('清空已看记录'));
      await pumpSettingsSettled(tester);
      await confirm(tester, '清空');
      await waitFor(tester, find.text('暂无「已看」记录'));
      await pumpSettingsSettled(tester);
      expect(state.recommendationDependencies.watched.works, isEmpty);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '删除选中'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '清空已看记录'))
            .onPressed,
        isNull,
      );
      final playback = state.recentHistory(sourceKey: '').single;
      expect(playback.vodName, '花样年华');
      expect(playback.positionMs, 20000);
      await showDislikes(tester);
      expect(find.text('星际穿越'), findsOneWidget);
      expect(find.text('共 2 条 · 已选 0 条'), findsOneWidget);
    },
  );

  testWidgets('reconciles partial dislike writes without a success notice', (
    tester,
  ) async {
    seedWatched();
    await tester.runAsync(seedDislikes);
    await pumpPreferences(tester);
    await openFeedback(tester);
    await showDislikes(tester);
    final store = state.recommendationDependencies.feedback;
    final failedWrite = Directory('${store.file!.path}.tmp')..createSync();
    await tester.tap(find.text('全选本类'));
    await tester.pump();
    await tester.tap(find.text('删除选中'));
    await pumpSettingsSettled(tester);
    expect(find.textContaining('「不感兴趣」中选中的 2 条'), findsOneWidget);
    await confirm(tester, '删除');
    await waitFor(tester, find.text('共 1 条 · 已选 1 条'));
    await pumpSettingsSettled(tester);
    expect(find.text('漫长的季节'), findsOneWidget);
    expect(find.text('星际穿越'), findsNothing);
    expect(store.entries.single.title, '漫长的季节');
    expect(toastCenter.toasts.map((toast) => toast.kind), [ToastKind.error]);
    expect(
      (await tester.runAsync(state.aiIntegration.userData.loadFeedback))!
          .isEmpty,
      isTrue,
    );
    expect(state.recommendationDependencies.watched.works, hasLength(4));

    failedWrite.deleteSync();
    await tester.tap(find.text('清空不感兴趣记录'));
    await pumpSettingsSettled(tester);
    expect(find.text('清空「不感兴趣」'), findsOneWidget);
    expect(find.textContaining('全部 1 条'), findsOneWidget);
    await confirm(tester, '清空');
    await waitFor(tester, find.text('暂无「不感兴趣」记录'));
    expect(store.entries, isEmpty);
    expect(state.recommendationDependencies.watched.works, hasLength(4));
  });

  testWidgets(
    'ignores a superseded load and blocks edits while a write is pending',
    (tester) async {
      seedWatched();
      await tester.runAsync(seedDislikes);
      await pumpPreferences(tester);
      await openFeedback(tester);
      final feedbackPath = state.aiIntegration.userData.paths.feedbackPath;

      final load = await _holdFeedbackRead(
        tester,
        feedbackPath,
        () => tester.tap(find.text('不感兴趣')),
      );
      await tester.pump();
      expect(find.text('正在读取推荐反馈…'), findsOneWidget);
      expect(find.text('花样年华'), findsNothing);
      await tester.tap(find.text('已看'));
      await pumpSettingsSettled(tester);
      await _releaseFeedbackRead(tester, load);
      expect(find.text('漫长的季节'), findsNothing);
      expect(find.text('花样年华'), findsOneWidget);
      expect(find.text('共 4 条 · 已选 0 条'), findsOneWidget);

      await showDislikes(tester);
      await select(tester, '星际穿越');
      final write = await _holdFeedbackRead(tester, feedbackPath, () async {
        await tester.tap(find.text('删除选中'));
        await pumpSettingsSettled(tester);
        await tester.tap(find.widgetWithText(FilledButton, '删除'));
        await tester.pump();
      });
      await pumpSettingsSettled(tester);
      expect(find.text('正在保存…'), findsOneWidget);
      final scopeControl = find.byType(
        SegmentedButton<RecommendationFeedbackKind>,
      );
      expect(
        tester
            .widget<SegmentedButton<RecommendationFeedbackKind>>(scopeControl)
            .onSelectionChanged,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '删除选中'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '清空不感兴趣记录'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, '星际穿越'),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.text('已看'));
      await tester.tap(find.text('删除选中'));
      expect(find.byType(AlertDialog), findsNothing);
      expect(toastCenter.toasts, isEmpty);
      await _releaseFeedbackRead(tester, write);
      await waitFor(tester, find.text('共 1 条 · 已选 0 条'));
      expect(find.text('花样年华'), findsNothing);
      expect(find.text('漫长的季节'), findsOneWidget);
      expect(find.text('星际穿越'), findsNothing);
      expect(toastCenter.toasts.map((toast) => toast.kind), [
        ToastKind.success,
      ]);
    },
  );

  final capturePhase = Platform.environment['RECOMMENDATION_FEEDBACK_CAPTURE'];
  if (capturePhase != null) {
    testWidgets('captures recommendation feedback settings evidence', (
      tester,
    ) async {
      expect(capturePhase, anyOf('before', 'after'));
      final theme = await tester.runAsync(_captureTheme);
      seedWatched();
      await tester.runAsync(seedDislikes);
      await pumpPreferences(tester, theme: theme);
      await _writePng(tester, 'settings-preferences-$capturePhase');
      if (capturePhase == 'after') {
        await openFeedback(tester);
        await showDislikes(tester);
        await select(tester, '星际穿越');
        await pumpSettingsSettled(tester);
        await _writePng(tester, 'recommendation-feedback-after');
      }
    });
  }
}

// Gate only the real AI feedback file's read, leaving all persistence in the real stores.
class _GatedFeedbackFile implements File {
  _GatedFeedbackFile(this.delegate);

  final File delegate;
  final started = Completer<void>();
  final resume = Completer<void>();
  final readDone = Completer<void>();

  @override
  String get path => delegate.path;

  @override
  Future<bool> exists() => delegate.exists();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    started.complete();
    await resume.future;
    try {
      return await delegate.readAsString(encoding: encoding);
    } finally {
      readDone.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_GatedFeedbackFile> _holdFeedbackRead(
  WidgetTester tester,
  String path,
  Future<void> Function() action,
) async {
  return (await tester.runAsync(() async {
    final gate = _GatedFeedbackFile(File(path));
    final outer = Zone.current;
    await IOOverrides.runZoned(
      action,
      createFile: (filePath) {
        if (filePath == path && !gate.started.isCompleted) return gate;
        return outer.run(() => File(filePath));
      },
    );
    await gate.started.future.timeout(const Duration(seconds: 3));
    return gate;
  }))!;
}

Future<void> _releaseFeedbackRead(
  WidgetTester tester,
  _GatedFeedbackFile file,
) async {
  await tester.runAsync(() async {
    file.resume.complete();
    await file.readDone.future.timeout(const Duration(seconds: 3));
    await Future<void>(() {});
  });
  await tester.pump();
}

Future<ThemeData> _captureTheme() async {
  final font = File(Platform.environment['CAPTURE_CJK_FONT']!);
  final icons = File(Platform.environment['CAPTURE_MATERIAL_FONT']!);
  for (final (family, file) in [
    for (final name in [
      'FeedbackCaptureSans',
      'Roboto',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'Source Han Sans SC',
      'Segoe UI',
    ])
      (name, font),
    ('MaterialIcons', icons),
  ]) {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
  }
  final base = buildAppTheme(Brightness.dark);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'FeedbackCaptureSans'),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: 'FeedbackCaptureSans',
    ),
  );
}

Future<void> _writePng(WidgetTester tester, String name) async {
  final dir = Directory(
    Platform.environment['RECOMMENDATION_FEEDBACK_CAPTURE_DIR']!,
  );
  final file = File(p.join(dir.path, '$name-dark-1072x728.png'));
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  await tester.runAsync(() async {
    await dir.create(recursive: true);
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
  expect(file.lengthSync(), greaterThan(1024));
}
