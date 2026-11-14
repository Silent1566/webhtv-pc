/// AI 设置页（`docs/phase6/design/04` §7.6）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/ai_settings_page.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

import 'support/settings_navigation.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-ai-settings');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsPage(state: state)),
      ),
    );
    await tester.pump();
    await selectSettingsCategory(tester, 'connections');
  }

  Future<void> pumpAiPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(state: state)));
    await tester.pump();
  }

  testWidgets('设置页有「AI 助手」区块与入口', (tester) async {
    await pumpSettings(tester);
    expect(find.text('AI 助手'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-ai-open')), findsOneWidget);
  });

  testWidgets('入口与 TMDB 解耦：未配置 TMDB 也可见', (tester) async {
    // state 刚 bootstrap，TMDB 未配置。
    expect(state.tmdbConfig.isReady, isFalse);
    await pumpSettings(tester);
    expect(find.byKey(const ValueKey('settings-ai-open')), findsOneWidget);
  });

  testWidgets('AI 设置页渲染全部字段', (tester) async {
    await pumpAiPage(tester);
    expect(find.byKey(const ValueKey('ai-settings-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-enabled')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-protocol')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-endpoint')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-api-key')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-model')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-user-agent')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-test')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-fetch-models')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-save')), findsOneWidget);
  });

  testWidgets('保存后写入 ai 段', (tester) async {
    await pumpAiPage(tester);

    await tester.enterText(
      find.byKey(const ValueKey('ai-endpoint')),
      'https://api.deepseek.com/v1',
    );
    await tester.enterText(find.byKey(const ValueKey('ai-api-key')), 'sk-test');
    await tester.enterText(
      find.byKey(const ValueKey('ai-model')),
      'deepseek-chat',
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('ai-save')));
    await tester.pumpAndSettle();

    expect(state.aiConfig.endpoint, 'https://api.deepseek.com/v1');
    expect(state.aiConfig.apiKey, 'sk-test');
    expect(state.aiConfig.model, 'deepseek-chat');
  });

  Future<void> pumpAiPageWithModels(
    WidgetTester tester,
    List<String> models,
  ) async {
    // 设置页很长（还有五个提示词编辑框），视口必须足够高，否则下拉候选项
    // 会因为位于 ListView 视野外而根本没有被构建。
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AiSettingsPage(
          state: state,
          fetchModelList: (config, {cancellationToken}) async => models,
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('ai-fetch-models')));
    await tester.tap(find.byKey(const ValueKey('ai-fetch-models')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('ai-model')));
  }

  testWidgets('拉取模型后模型框变为可筛选下拉，点选回填并保存', (tester) async {
    await pumpAiPageWithModels(tester, const [
      'deepseek-v4.1-flash',
      '1/MiniMax-M2.5',
      '1/MiniMax-M3',
    ]);
    expect(find.byKey(const ValueKey('ai-model-options')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ai-model-option-1/MiniMax-M3')),
      findsOneWidget,
    );

    // 本地筛选：包含匹配、不区分大小写，非匹配项立即隐藏。
    await tester.enterText(find.byKey(const ValueKey('ai-model')), 'minimax');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('ai-model-option-1/MiniMax-M2.5')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ai-model-option-1/MiniMax-M3')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ai-model-option-deepseek-v4.1-flash')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('ai-model-option-1/MiniMax-M3')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('ai-model-options')),
      findsNothing,
      reason: '选中后下拉收起',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-model')))
          .controller
          ?.text,
      '1/MiniMax-M3',
    );

    await tester.tap(find.byKey(const ValueKey('ai-save')));
    await tester.pumpAndSettle();
    expect(state.aiConfig.model, '1/MiniMax-M3');
  });

  testWidgets('筛选无匹配时给出提示，仍可保存自定义模型名', (tester) async {
    await pumpAiPageWithModels(tester, const ['1/MiniMax-M3']);
    await tester.enterText(
      find.byKey(const ValueKey('ai-model')),
      'my-local-model',
    );
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的模型名'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-save')));
    await tester.pumpAndSettle();
    expect(state.aiConfig.model, 'my-local-model');
  });

  testWidgets('未拉取模型时没有下拉面板，模型框仍可手动输入', (tester) async {
    await pumpAiPage(tester);
    expect(find.byKey(const ValueKey('ai-model-options')), findsNothing);
    expect(find.byKey(const ValueKey('ai-model-toggle')), findsNothing);
  });
  testWidgets('切换协议时自动填该协议的默认端点', (tester) async {
    await pumpAiPage(tester);
    await tester.tap(find.byKey(const ValueKey('ai-protocol')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anthropic Messages').last);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('ai-endpoint')),
    );
    expect(field.controller?.text, 'https://api.anthropic.com/v1/messages');
  });

  testWidgets('API Key 默认遮蔽', (tester) async {
    await pumpAiPage(tester);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('ai-api-key')),
    );
    expect(field.obscureText, isTrue, reason: '凭据默认遮蔽');
  });

  group('季度弹窗 AI 项与返回值契约（design/04 §7.1.1）', () {
    testWidgets('弹窗有 AI 项，未配置时提示去设置', (tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbSeasonDialog(
              tmdbSeasons: const [1, 2],
              seasonCounts: const {1: 3, 2: 2},
              sourceEpisodeCount: 5,
              aiReady: false,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('tmdb-season-ai')), findsOneWidget);
      expect(find.textContaining('未配置 AI 服务'), findsOneWidget);
    });

    testWidgets('已配置时不显示「未配置」提示', (tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbSeasonDialog(
              tmdbSeasons: const [1, 2],
              seasonCounts: const {1: 3, 2: 2},
              sourceEpisodeCount: 5,
              aiReady: true,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('tmdb-season-ai')), findsOneWidget);
      expect(find.textContaining('未配置 AI 服务'), findsNothing);
    });

    testWidgets('选项顺序：自动 / 按集数 / 保持原始 / AI / 各季', (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbSeasonDialog(
              tmdbSeasons: const [1, 2],
              seasonCounts: const {1: 3, 2: 2},
              sourceEpisodeCount: 5,
              aiReady: true,
            ),
          ),
        ),
      );
      await tester.pump();

      final auto = tester
          .getTopLeft(find.byKey(const ValueKey('tmdb-season-auto')))
          .dy;
      final slice = tester
          .getTopLeft(find.byKey(const ValueKey('tmdb-season-auto-slice')))
          .dy;
      final keep = tester
          .getTopLeft(find.byKey(const ValueKey('tmdb-season-keep-original')))
          .dy;
      final ai = tester
          .getTopLeft(find.byKey(const ValueKey('tmdb-season-ai')))
          .dy;
      final season = tester
          .getTopLeft(find.byKey(const ValueKey('tmdb-season-option-1')))
          .dy;

      expect(auto, lessThan(slice));
      expect(slice, lessThan(keep));
      expect(keep, lessThan(ai), reason: 'AI 项在「保持原始」之后');
      expect(ai, lessThan(season), reason: 'AI 项在「各季」之前');
    });

    test('TmdbSeasonAiSettings 的 bindingModeOf 返回 null（= 清除绑定）', () {
      // 这是**危险**的：调用方必须先分流，绝不能直接喂给 bindTmdbSeason。
      expect(bindingModeOf(const TmdbSeasonAiSettings()), isNull);
    });

    test('TmdbSeasonAi 的 bindingModeOf 也返回 null（它不是绑定选择）', () {
      expect(bindingModeOf(const TmdbSeasonAi()), isNull);
    });
  });
}
