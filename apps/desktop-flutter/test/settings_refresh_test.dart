import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/player_button_config_page.dart';
import 'package:webhtv_pc/ui/settings_layout.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/settings_navigation.dart';

const _categoryEntries = <String, List<String>>{
  'playback': ['settings-player-buttons', 'settings-advanced-open'],
  'connections': [
    'settings-ai-open',
    'settings-tmdb-open',
    'settings-android-open',
  ],
  'maintenance': ['settings-site-health-open'],
};

const _categoryContent = <String, String>{
  'preferences': 'settings-theme-mode',
  'playback': 'settings-osd',
  'connections': 'settings-ai-open',
  'maintenance': 'settings-site-health-open',
};

void _expectOnlyCategory(String category) {
  for (final entry in _categoryContent.entries) {
    expect(
      find.byKey(ValueKey('settings-category-content-${entry.key}')),
      entry.key == category ? findsOneWidget : findsNothing,
      reason: '只能挂载当前分类 $category 的单列内容区',
    );
    expect(
      find.byKey(ValueKey(entry.value)),
      entry.key == category ? findsOneWidget : findsNothing,
      reason: '只能显示当前分类 $category 的内容：${entry.key}',
    );
  }
}

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-settings-refresh-');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/config',
          'data': '${temp.path}/data',
          'cache': '${temp.path}/cache',
          'state': '${temp.path}/logs',
        },
      ),
      log: LogService(),
      externalPlayerDetector: () => const [],
    );
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    temp.deleteSync(recursive: true);
  });

  testWidgets('主设置默认偏好，选类后工具入口单列可达', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: SettingsPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    for (final title in ['偏好', '播放', '连接与增强', '维护与说明']) {
      expect(find.text(title), findsWidgets);
    }
    for (final category in _categoryContent.keys) {
      expect(
        find.byKey(ValueKey('settings-category-$category')),
        findsOneWidget,
      );
    }
    _expectOnlyCategory('preferences');
    for (final entry in _categoryEntries.entries) {
      await selectSettingsCategory(tester, entry.key);
      _expectOnlyCategory(entry.key);
      Rect? previous;
      for (final key in entry.value) {
        final target = find.byKey(ValueKey(key));
        expect(target, findsOneWidget);
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        final rect = tester.getRect(target);
        expect(rect.bottom, lessThanOrEqualTo(900));
        expect(rect.top, greaterThanOrEqualTo(0));
        if (previous != null) {
          expect(rect.left, closeTo(previous.left, 1));
          expect(rect.top, greaterThanOrEqualTo(previous.bottom));
        }
        previous = rect;
      }
    }
  });

  testWidgets('共享组件沿用主题层级，窄操作区换行并保留禁用状态', (tester) async {
    final theme = buildAppTheme(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 280,
              child: Column(
                children: [
                  const SettingsPageHeader(title: '页面标题', description: '页面说明'),
                  SettingsSection(
                    title: '分组标题',
                    description: '分组说明',
                    children: [
                      SettingsActions(
                        children: [
                          OutlinedButton(
                            key: const ValueKey('action-first'),
                            onPressed: () {},
                            child: const Text('第一项较长的操作'),
                          ),
                          const OutlinedButton(
                            key: ValueKey('action-second'),
                            onPressed: null,
                            child: Text('第二项较长的操作'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text('页面标题')).style,
      Theme.of(tester.element(find.text('页面标题'))).textTheme.headlineSmall,
    );
    expect(
      tester.widget<Text>(find.text('分组标题')).style,
      Theme.of(tester.element(find.text('分组标题'))).textTheme.titleMedium,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('action-second'))).top,
      greaterThan(
        tester.getRect(find.byKey(const ValueKey('action-first'))).top,
      ),
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('action-second')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('设置在 ${brightness.name} 480/720/1024 窄窗可滚动且 key 类型不变', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final width in [480.0, 720.0, 1024.0]) {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.physicalSize = Size(width, 640);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness),
            home: Scaffold(body: SettingsPage(state: state)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$width');
        expect(
          tester.widget(find.byKey(const ValueKey('settings-theme-mode'))),
          isA<SegmentedButton<ThemeMode>>(),
        );
        expect(
          tester.widget(
            find.byKey(const ValueKey('settings-history-click-action')),
          ),
          isA<SegmentedButton<String>>(),
        );
        _expectOnlyCategory('preferences');
        if (width == 1024) {
          final content = tester.getRect(
            find.byKey(const ValueKey('settings-theme-mode')),
          );
          Rect? previousCategory;
          for (final category in _categoryContent.keys) {
            final navigation = tester.getRect(
              find.byKey(ValueKey('settings-category-$category')),
            );
            expect(navigation.right, lessThan(content.left));
            if (previousCategory != null) {
              expect(
                navigation.top,
                greaterThanOrEqualTo(previousCategory.bottom),
              );
            }
            previousCategory = navigation;
          }
        }
        for (final entry in _categoryEntries.entries) {
          await selectSettingsCategory(tester, entry.key);
          _expectOnlyCategory(entry.key);
          if (entry.key == 'playback') {
            expect(
              tester.widget(find.byKey(const ValueKey('settings-osd'))),
              isA<Column>(),
            );
          }
          for (final key in entry.value) {
            final target = find.byKey(ValueKey(key));
            expect(tester.widget(target), isA<FilledButton>());
            await tester.ensureVisible(target);
            await tester.pumpAndSettle();
            final rect = tester.getRect(target);
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(width));
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(640));
          }
        }
        expect(tester.takeException(), isNull, reason: '$width');
      }
    });

    testWidgets('按钮页限宽、窄窗底部操作可见且站点健康空态保留 ${brightness.name}', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final width in [480.0, 1440.0]) {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.physicalSize = Size(width, 640);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness),
            home: PlayerButtonConfigPage(state: state),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const ValueKey('button-row-play'))).width,
          lessThanOrEqualTo(900),
        );
        expect(
          tester
              .getRect(find.byKey(const ValueKey('player-buttons-reset')))
              .bottom,
          lessThanOrEqualTo(640),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(brightness),
            home: SiteHealthPage(state: state),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('还没有调用记录。浏览、搜索或播放后会累计成功率与耗时。'), findsOneWidget);
        expect(find.text('逐站明细'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
