/// 字幕源设置页的每源开关/令牌
/// （`docs/superpowers/plans/2026-11-15-subtitle-online-search.md`）。
///
/// 只测页面这一层的契约：三段的默认值、即时写进 `SubtitleSettings` 的字段、
/// 状态行的源计数、token 输入的显隐，以及 1280×720 下不溢出。
/// 不测网络与「某个源是否真有结果」——那是 provider 和 core 的测试。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/subtitle_settings.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/subtitle_settings_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subtitle-settings-page');
    final paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    // 先确认路径确实落在自己的临时目录里，再让 bootstrap 碰存储。
    for (final dir in [
      paths.configDir,
      paths.dataDir,
      paths.cacheDir,
      paths.logDir,
    ]) {
      expect(p.isWithin(temp.path, dir), isTrue, reason: '测试目录必须自持');
    }
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(560, 720),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: SubtitleSettingsPage(state: state),
      ),
    );
    await tester.pump();
  }

  /// scrollUntilVisible 只往一个方向滚；目标在当前视口上方时永远找不到，
  /// 所以每次先跳回顶部，再往下找，断言顺序就与滚动方向无关了。
  Future<void> reveal(WidgetTester tester, Finder target) async {
    final scrollable = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(target, 180, scrollable: scrollable);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  /// 保存走真实写盘，假时钟的 pump 等不到它；按状态条件轮询，不用固定 sleep。
  Future<void> waitUntil(WidgetTester tester, bool Function() done) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
  }

  Finder assrtField() => find.byKey(const ValueKey('subtitle-assrt-token'));

  testWidgets('默认三个源全关，状态行显示未配置', (tester) async {
    await pumpPage(tester);

    await reveal(tester, assrtField());
    expect(tester.widget<TextField>(assrtField()).controller!.text, '');
    expect(tester.widget<TextField>(assrtField()).obscureText, isTrue);

    final xunlei = find.byKey(const ValueKey('subtitle-xunlei-enabled'));
    await reveal(tester, xunlei);
    expect(tester.widget<SwitchListTile>(xunlei).value, isFalse);

    final shooter = find.byKey(const ValueKey('subtitle-shooter-enabled'));
    await reveal(tester, shooter);
    expect(tester.widget<SwitchListTile>(shooter).value, isFalse);

    await reveal(tester, find.byKey(const ValueKey('subtitle-status')));
    expect(find.textContaining('未配置任何字幕源').hitTestable(), findsOneWidget);
    expect(find.textContaining('已启用'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('填入 ASSRT token 并打开迅雷即时生效，字段正确且统计为 2 个源', (tester) async {
    await pumpPage(tester);
    const token = 'assrt-token-7f3';

    await reveal(tester, assrtField());
    await tester.enterText(assrtField(), '  $token  ');

    final xunlei = find.byKey(const ValueKey('subtitle-xunlei-enabled'));
    await reveal(tester, xunlei);
    await tester.tap(xunlei);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(xunlei).value, isTrue);

    await waitUntil(tester, () => state.subtitleSettings.assrtToken.isNotEmpty);
    await tester.pumpAndSettle();

    expect(state.subtitleSettings.assrtToken, token, reason: '保存要 trim');
    expect(state.subtitleSettings.xunleiEnabled, isTrue);
    expect(state.subtitleSettings.shooterEnabled, isFalse);

    final message = find.byKey(const ValueKey('subtitle-save-message'));
    await reveal(tester, message);
    final text = tester.widget<Text>(message).data!;
    expect(text, '已保存');
    expect(text, isNot(contains(token)), reason: 'token 不得出现在提示文案里');

    await reveal(tester, find.byKey(const ValueKey('subtitle-status')));
    expect(find.textContaining('已启用 2 个源').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空 ASSRT token 并关掉迅雷后，回到未配置任何字幕源', (tester) async {
    await tester.runAsync(
      () => state.setSubtitleSettings(
        SubtitleSettings(assrtToken: 'tok-seeded', xunleiEnabled: true),
      ),
    );
    await pumpPage(tester);

    await reveal(tester, find.byKey(const ValueKey('subtitle-status')));
    expect(find.textContaining('已启用 2 个源').hitTestable(), findsOneWidget);

    await reveal(tester, assrtField());
    expect(
      tester.widget<TextField>(assrtField()).controller!.text,
      'tok-seeded',
    );
    await tester.enterText(assrtField(), '');

    final xunlei = find.byKey(const ValueKey('subtitle-xunlei-enabled'));
    await reveal(tester, xunlei);
    await tester.tap(xunlei);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(xunlei).value, isFalse);

    await waitUntil(
      tester,
      () =>
          state.subtitleSettings.assrtToken.isEmpty &&
          !state.subtitleSettings.xunleiEnabled,
    );
    await tester.pumpAndSettle();

    expect(state.subtitleSettings.hasAnyProvider, isFalse);
    await reveal(tester, find.byKey(const ValueKey('subtitle-status')));
    expect(find.textContaining('未配置任何字幕源').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('token 默认隐藏，点显示按钮后可见且不丢内容', (tester) async {
    await pumpPage(tester);
    await reveal(tester, assrtField());
    await tester.enterText(assrtField(), 'secret-token');
    // enterText 会让输入框把光标滚进视口，动画没停就点按钮会点空。
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(assrtField()).obscureText, isTrue);
    // 老用例按 tooltip「显示令牌」点 HTTP 源的按钮，ASSRT 这个必须另有名字，
    // 否则一次 find.byTooltip 会命中两个按钮。
    expect(find.byTooltip('显示 ASSRT token'), findsOneWidget);
    expect(find.byTooltip('显示令牌'), findsOneWidget);

    final revealButton = find.byKey(
      const ValueKey('subtitle-assrt-token-reveal'),
    );
    await tester.ensureVisible(revealButton);
    await tester.pumpAndSettle();
    await tester.tap(revealButton);
    await tester.pump();
    expect(tester.widget<TextField>(assrtField()).obscureText, isFalse);
    expect(
      tester.widget<TextField>(assrtField()).controller!.text,
      'secret-token',
    );
    expect(find.byTooltip('隐藏 ASSRT token'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('1280×720 下五个分区都可滚到且无溢出', (tester) async {
    await pumpPage(tester, size: const Size(1280, 720));
    for (final title in const [
      '自动匹配',
      'ASSRT',
      '迅雷字幕',
      '射手字幕',
      '本地目录',
      'HTTP 字幕源',
    ]) {
      await reveal(tester, find.text(title));
      expect(find.text(title).hitTestable(), findsOneWidget, reason: title);
      expect(tester.takeException(), isNull, reason: title);
    }
    for (final key in const [
      'subtitle-assrt-token',
      'subtitle-xunlei-enabled',
      'subtitle-shooter-enabled',
      'subtitle-status',
    ]) {
      await reveal(tester, find.byKey(ValueKey(key)));
      expect(
        find.byKey(ValueKey(key)).hitTestable(),
        findsOneWidget,
        reason: key,
      );
      expect(tester.takeException(), isNull, reason: key);
    }
  });
}
