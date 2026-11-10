import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/advanced_settings_page.dart';
import 'package:webhtv_pc/ui/ai_settings_page.dart';
import 'package:webhtv_pc/ui/subtitle_settings_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('settings-forms-refresh');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(560, 720),
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: buildAppTheme(brightness), home: page),
    );
    await tester.pump();
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  /// 保存走真实写盘 + `notifyListeners`，假时钟的 pump 等不到它；
  /// 按状态条件轮询，不用固定 sleep。
  Future<void> waitUntil(WidgetTester tester, bool Function() done) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
  }

  for (final brightness in Brightness.values) {
    for (final size in [const Size(560, 720), const Size(1440, 900)]) {
      testWidgets('高级设置五类分组可扫描且无溢出 $brightness $size', (tester) async {
        await pumpPage(
          tester,
          AdvancedSettingsPage(state: state),
          size: size,
          brightness: brightness,
        );
        for (final title in ['播放与观看', '站点与搜索', '辅助工具', '网络连接', '隐私', '诊断']) {
          await reveal(tester, find.text(title));
          expect(find.text(title).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await reveal(
          tester,
          find.byKey(const ValueKey('settings-spider-debug-log')),
        );
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('settings-spider-debug-log')),
              )
              .value,
          isFalse,
        );
      });

      testWidgets('AI 服务凭据操作分区可达且无溢出 $brightness $size', (tester) async {
        await pumpPage(
          tester,
          AiSettingsPage(state: state),
          size: size,
          brightness: brightness,
        );
        for (final title in ['服务连接', '访问凭据', '操作与状态']) {
          await reveal(tester, find.text(title));
          expect(find.text(title).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        for (final key in ['ai-test', 'ai-fetch-models', 'ai-save']) {
          await reveal(tester, find.byKey(ValueKey(key)));
          expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      });

      testWidgets('字幕三类源与保存可达且无溢出 $brightness $size', (tester) async {
        await pumpPage(
          tester,
          SubtitleSettingsPage(state: state),
          size: size,
          brightness: brightness,
        );
        for (final title in ['自动匹配', '本地目录', 'HTTP 字幕源']) {
          await reveal(tester, find.text(title));
          expect(find.text(title).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await reveal(tester, find.byKey(const ValueKey('subtitle-save')));
        expect(
          find.byKey(const ValueKey('subtitle-save')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('AI 编辑不提前保存，显隐凭据保留草稿，保存显示结果', (tester) async {
    await pumpPage(
      tester,
      AiSettingsPage(state: state),
      size: const Size(1200, 1800),
    );
    final before = state.aiConfig.endpoint;
    final endpoint = find.byKey(const ValueKey('ai-endpoint'));
    await reveal(tester, endpoint);
    await tester.enterText(endpoint, ' https://example.test/v1 ');
    expect(state.aiConfig.endpoint, before);
    final key = find.byKey(const ValueKey('ai-api-key'));
    await reveal(tester, key);
    await tester.enterText(key, 'sk-test');
    expect(tester.widget<TextField>(key).obscureText, isTrue);
    await tester.tap(find.byTooltip('显示'));
    await tester.pump();
    expect(tester.widget<TextField>(key).obscureText, isFalse);
    expect(tester.widget<TextField>(key).controller!.text, 'sk-test');
    final save = find.byKey(const ValueKey('ai-save'));
    await reveal(tester, save);
    await tester.tap(save);
    await tester.pump();
    expect(find.text('正在保存…'), findsOneWidget, reason: '保存开始应有即时反馈');
    await tester.pumpAndSettle();
    await waitUntil(tester, () => state.aiConfig.apiKey == 'sk-test');
    await tester.pump();
    await tester.pump();
    expect(state.aiConfig.endpoint, 'https://example.test/v1');
    expect(state.aiConfig.apiKey, 'sk-test');
    expect(tester.takeException(), isNull);
  });

  testWidgets('字幕编辑不提前保存，默认目录与令牌保存后刷新当前状态', (tester) async {
    await pumpPage(tester, SubtitleSettingsPage(state: state));
    expect(state.subtitleSettings.hasAnyProvider, isFalse);
    final directories = find.byKey(
      const ValueKey('subtitle-local-directories'),
    );
    await reveal(tester, directories);
    await tester.enterText(directories, ' C:\\字幕一 \n\n D:\\字幕二 ');
    final add = find.byKey(const ValueKey('subtitle-add-default-dir'));
    await reveal(tester, add);
    await tester.tap(add);
    await tester.pump();
    expect(
      tester.widget<TextField>(directories).controller!.text,
      contains('subtitles'),
    );
    expect(state.subtitleSettings.hasAnyProvider, isFalse);
    final token = find.byKey(const ValueKey('subtitle-http-token'));
    await reveal(tester, token);
    await tester.enterText(token, ' token-test ');
    expect(tester.widget<TextField>(token).obscureText, isTrue);
    await tester.tap(find.byTooltip('显示令牌'));
    await tester.pump();
    expect(tester.widget<TextField>(token).obscureText, isFalse);
    final save = find.byKey(const ValueKey('subtitle-save'));
    await reveal(tester, save);
    await tester.tap(save);
    await tester.pump();
    await waitUntil(
      tester,
      () => state.subtitleSettings.httpToken == 'token-test',
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('subtitle-save-message')));
    expect(find.text('已保存'), findsOneWidget);
    expect(state.subtitleSettings.localDirectories.take(2), [
      'C:\\字幕一',
      'D:\\字幕二',
    ]);
    expect(state.subtitleSettings.httpToken, 'token-test');
    await reveal(tester, find.textContaining('当前状态：已配置字幕源'));
    expect(find.textContaining('当前状态：已配置字幕源').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
