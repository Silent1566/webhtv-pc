/// 「弹幕设置」独立页（P1/S2）：显示参数 + 多弹幕源列表。
///
/// ## 这一组用例锁什么
///
/// 1. 页标题与两个分区都在——少一个分区，等于显示参数又回到播放器弹层里；
/// 2. 开关/滑块真的写进 `AppState`，且写进 settings.json 的 `danmakuDisplay`
///    （显示段）与 `danmaku`（库段）：界面回显但没落盘是这类「即时保存」页
///    最可能的退化；
/// 3. 弹幕源列表的新增 / 编辑 / 删除 / 上下移 / 启停都既改 `AppState` 也落盘，
///    且非法地址**只报错不写盘**（写进去等于让自动搜索拿一个坏地址发请求）；
/// 4. 分类页副标题（[DanmakuSettingsPage.summary]）与页面内容同一口径：
///    有源要报「N 个源（手填）」，无源要报「未配置」。
///
/// ## 为什么写盘断言都包在真实 I/O 轮询里
///
/// `UiPreferencesStore._persistQueue` 在 setUp 的**真实** zone 里创建，续体落在
/// 真实事件循环上，FakeAsync 推不动它（同 settings_immediate_forms_test）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku_settings.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/danmaku_settings_page.dart';
import 'package:webhtv_pc/ui/glass_dialog.dart';
import 'package:webhtv_pc/ui/theme.dart';

Future<AppState> isolatedState(WidgetTester tester) async {
  final temp = Directory.systemTemp.createTempSync('danmaku-settings-page-');
  final paths = AppPaths.resolve(
    overrides: {
      'config': '${temp.path}/config',
      'data': '${temp.path}/data',
      'cache': '${temp.path}/cache',
      'state': '${temp.path}/logs',
    },
  );
  final previous = LogService.logDirectoryOverride;
  LogService.logDirectoryOverride = paths.logDir;
  final state = AppState(
    paths: paths,
    log: LogService(),
    externalPlayerDetector: () => const [],
  );
  addTearDown(() {
    state.dispose();
    LogService.logDirectoryOverride = previous;
    temp.deleteSync(recursive: true);
  });
  await tester.runAsync(state.bootstrap);
  return state;
}

Future<void> settleWrites(WidgetTester tester) async {
  for (var round = 0; round < 30; round++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 16)),
    );
  }
  await tester.pumpAndSettle();
}

/// 视口取高一些：两个分区都要一次性建出来，滑块与开关才能直接点/拖。
Future<void> openPage(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(560, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: DanmakuSettingsPage(state: state),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, Object?> readSettings(AppState state) {
  final file = File(state.paths.settingsPath);
  if (!file.existsSync()) return const {};
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

/// 落盘的 `danmaku.sources`；没有该键时返回空列表。
List<Object?> readSources(AppState state) {
  final danmaku = readSettings(state)['danmaku'];
  if (danmaku is! Map) return const [];
  final sources = danmaku['sources'];
  return sources is List ? sources : const [];
}

/// 走真实交互添加一条源：点「添加」→ 填两个字段 → 点「保存」。
Future<void> addSource(
  WidgetTester tester, {
  String name = '',
  String url = 'https://example.test/danmaku',
}) async {
  await tester.tap(find.byKey(const ValueKey('settings-danmaku-source-add')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('settings-danmaku-source-name')),
    name,
  );
  await tester.enterText(
    find.byKey(const ValueKey('settings-danmaku-source-url')),
    url,
  );
  await tester.tap(find.byKey(const ValueKey('settings-danmaku-source-save')));
  await settleWrites(tester);
}

void main() {
  testWidgets('页标题、两个分区与弹幕库控件都在，空列表报未配置', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);

    expect(find.widgetWithText(AppBar, '弹幕设置'), findsOneWidget);
    // 分区标题：显示参数与弹幕库必须在同一页，拆开就等于回到改造前。
    expect(find.text('弹幕库'), findsOneWidget);
    expect(find.text('显示'), findsOneWidget);

    const keys = <String>[
      'settings-danmaku-auto-search',
      'settings-danmaku-source-add',
      'settings-danmaku-enabled',
      'settings-danmaku-opacity',
      'settings-danmaku-scale',
      'settings-danmaku-stroke',
      'settings-danmaku-area',
      'settings-danmaku-duration',
      'settings-danmaku-tracks',
      'settings-danmaku-offset',
      'settings-danmaku-show-scroll',
      'settings-danmaku-show-top',
      'settings-danmaku-show-bottom',
    ];
    for (final key in keys) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: '缺少控件：$key');
    }
    // 旧的单地址行已被列表接管：它还留在页面上，就会又出现一个「地址」入口。
    expect(find.byKey(const ValueKey('settings-danmaku-api')), findsNothing);

    // 空列表：计数为 0、给出去哪添加的指引，自动搜索副标题说明「不会发请求」。
    expect(find.text('弹幕源（0 个启用）'), findsOneWidget);
    expect(find.textContaining('还没有弹幕源'), findsOneWidget);
    expect(find.textContaining('未配置地址：自动搜索不会发请求'), findsOneWidget);
    // 没有手填源、也没有站点配置/猫源时，不该出现「当前生效」的外部来源提示。
    expect(
      find.byKey(const ValueKey('settings-danmaku-external-source')),
      findsNothing,
    );

    expect(DanmakuSettingsPage.summary(state), '自动搜索已关 · 未配置');
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加弹幕源：写入 state 并落盘 danmaku.sources', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);

    await addSource(tester, name: '备用源', url: 'https://example.test/danmaku');

    expect(state.danmakuSettings.sources, hasLength(1));
    final source = state.danmakuSettings.sources.single;
    expect(source.name, '备用源');
    expect(source.url, 'https://example.test/danmaku');
    expect(source.enabled, isTrue, reason: '新源默认启用，否则「添加」像没生效');

    final stored = readSources(state);
    expect(stored, hasLength(1), reason: 'danmaku.sources 必须落盘');
    expect((stored.single! as Map)['url'], 'https://example.test/danmaku');
    expect((stored.single! as Map)['name'], '备用源');

    // 页面同时回显：计数 + 自动搜索副标题都跟着源数走。
    expect(find.text('弹幕源（1 个启用）'), findsOneWidget);
    expect(find.textContaining('已配置 1 个源'), findsOneWidget);
    expect(find.text('备用源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非法地址：就地报错，不写盘也不关对话框', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);
    final before = readSettings(state);

    await tester.tap(find.byKey(const ValueKey('settings-danmaku-source-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings-danmaku-source-name')),
      '坏地址',
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-danmaku-source-url')),
      'https://',
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-danmaku-source-save')),
    );
    await settleWrites(tester);

    expect(state.danmakuSettings.sources, isEmpty);
    expect(readSettings(state), before, reason: '非法地址不得落盘');
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('settings-danmaku-source-url')),
          )
          .decoration!
          .errorText,
      isNotNull,
    );
    expect(find.byType(GlassAlertDialog), findsOneWidget, reason: '错了别关，让人改');

    await tester.tap(
      find.byKey(const ValueKey('settings-danmaku-source-cancel')),
    );
    await settleWrites(tester);
    expect(find.byType(GlassAlertDialog), findsNothing);
    expect(state.danmakuSettings.sources, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('启用开关：写回该源的 enabled 并落盘', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);
    await addSource(tester, name: 'A');
    final id = state.danmakuSettings.sources.single.id;

    await tester.tap(
      find.byKey(ValueKey('settings-danmaku-source-enabled-$id')),
    );
    await settleWrites(tester);

    expect(state.danmakuSettings.sources.single.enabled, isFalse);
    expect(
      (readSources(state).single! as Map)['enabled'],
      isFalse,
      reason: '启停必须落盘，否则重启后又悄悄开始搜索',
    );
    expect(find.text('弹幕源（0 个启用）'), findsOneWidget);

    // 往返：再拨一次必须回到启用（「永远写 false」的实现会在这里露馅）。
    await tester.tap(
      find.byKey(ValueKey('settings-danmaku-source-enabled-$id')),
    );
    await settleWrites(tester);
    expect(state.danmakuSettings.sources.single.enabled, isTrue);
    expect((readSources(state).single! as Map)['enabled'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('上移/下移改变顺序并落盘，首末项按钮置灰', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);
    await addSource(tester, name: 'A', url: 'https://a.test/danmaku');
    await addSource(tester, name: 'B', url: 'https://b.test/danmaku');
    final ids = state.danmakuSettings.sources.map((s) => s.id).toList();
    expect(ids, hasLength(2));

    // 首项上移、末项下移都没有意义：按钮置灰而不是藏起来（位置稳定）。
    expect(
      tester
          .widget<IconButton>(
            find.byKey(ValueKey('settings-danmaku-source-up-${ids[0]}')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(ValueKey('settings-danmaku-source-down-${ids[1]}')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(
      find.byKey(ValueKey('settings-danmaku-source-up-${ids[1]}')),
    );
    await settleWrites(tester);
    expect(state.danmakuSettings.sources.map((s) => s.name).toList(), [
      'B',
      'A',
    ], reason: '顺序即搜索顺序，上移必须真的换位');
    expect(readSources(state).map((s) => (s! as Map)['name']).toList(), [
      'B',
      'A',
    ]);

    // 换位后 first 变成 B（原第二条），再把它下移必须是「移动这一条」而不是
    // 「按下标移动」：改回去的就是 A 的顺序。
    await tester.tap(
      find.byKey(ValueKey('settings-danmaku-source-down-${ids[1]}')),
    );
    await settleWrites(tester);
    expect(state.danmakuSettings.sources.map((s) => s.name).toList(), [
      'A',
      'B',
    ]);
    expect(readSources(state).map((s) => (s! as Map)['name']).toList(), [
      'A',
      'B',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除一条源：从列表与磁盘上一起消失', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);
    await addSource(tester, name: 'A', url: 'https://a.test/danmaku');
    await addSource(tester, name: 'B', url: 'https://b.test/danmaku');
    final first = state.danmakuSettings.sources.first.id;

    await tester.tap(
      find.byKey(ValueKey('settings-danmaku-source-remove-$first')),
    );
    await settleWrites(tester);

    expect(state.danmakuSettings.sources, hasLength(1));
    expect(state.danmakuSettings.sources.single.name, 'B');
    expect(readSources(state), hasLength(1), reason: '删除必须落盘');
    expect(find.text('A'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑一条源：改名改址，id 不变', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);
    await addSource(tester, name: 'A', url: 'https://a.test/danmaku');
    final id = state.danmakuSettings.sources.single.id;

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    // 对话框必须回填旧值：空着打开会让人以为在重填一条新源。
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('settings-danmaku-source-name')),
          )
          .controller!
          .text,
      'A',
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-danmaku-source-name')),
      '改名',
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-danmaku-source-url')),
      'https://c.test/danmaku',
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-danmaku-source-save')),
    );
    await settleWrites(tester);

    expect(state.danmakuSettings.sources, hasLength(1), reason: '编辑不得新增一条');
    final source = state.danmakuSettings.sources.single;
    expect(source.id, id, reason: 'id 是结果归属标识，改名不能换 id');
    expect(source.name, '改名');
    expect(source.url, 'https://c.test/danmaku');
    expect(
      (readSources(state).single! as Map)['url'],
      'https://c.test/danmaku',
    );
    expect(find.text('改名'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('名称留空时回退成 host，而不是留一个空标题', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);

    await addSource(tester, url: 'https://nas.local:9321/TOKEN');
    expect(state.danmakuSettings.sources.single.name, 'nas.local');
    expect(find.text('nas.local'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('summary 口径：无源报未配置，有源报个数与来源', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);
    expect(DanmakuSettingsPage.summary(state), '自动搜索已关 · 未配置');

    await addSource(tester, name: 'A', url: 'https://a.test/danmaku');
    expect(DanmakuSettingsPage.summary(state), '自动搜索已关 · 1 个源（手填）');

    await addSource(tester, name: 'B', url: 'https://b.test/danmaku');
    expect(DanmakuSettingsPage.summary(state), '自动搜索已关 · 2 个源（手填）');

    await tester.runAsync(
      () => state.setDanmakuSettings(
        state.danmakuSettings.copyWith(autoSearch: true),
      ),
    );
    expect(DanmakuSettingsPage.summary(state), '自动搜索已开 · 2 个源（手填）');

    // 关掉全部源 = 回到未配置：站点配置/猫源都不会被算成「手填」。
    await tester.runAsync(
      () => state.setDanmakuSettings(
        state.danmakuSettings.copyWith(
          sources: [
            for (final source in state.danmakuSettings.sources)
              source.copyWith(enabled: false),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(DanmakuSettingsPage.summary(state), '自动搜索已开 · 未配置');
    expect(tester.takeException(), isNull);
  });

  testWidgets('外部来源：手填列表为空但猫源可用时，说明「当前生效」', (tester) async {
    final state = await isolatedState(tester);
    // 没有手填源、也没有站点配置/猫源时不得出现提示：空列表 + 空提示只会误导。
    await openPage(tester, state);
    expect(
      find.byKey(const ValueKey('settings-danmaku-external-source')),
      findsNothing,
    );

    // 猫源带上弹幕服务地址 = 解析链第三档，它仍然会真的发请求，所以必须说出来。
    state.setBundleDanmakuApiUrl('http://127.0.0.1:9321/danmaku');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-danmaku-external-source')),
      findsOneWidget,
    );
    expect(find.textContaining('来自本地猫源'), findsOneWidget);
    expect(DanmakuSettingsPage.summary(state), '自动搜索已关 · 1 个源（本地猫源）');

    // 添加一条手填源后手填档胜出，外部来源提示必须消失（否则用户会以为两档都在搜）。
    await addSource(tester, name: '手填', url: 'https://mine.test/danmaku');
    expect(
      find.byKey(const ValueKey('settings-danmaku-external-source')),
      findsNothing,
    );
    expect(DanmakuSettingsPage.summary(state), '自动搜索已关 · 1 个源（手填）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('弹幕总开关：回显 + 写进 settings.json 的 danmakuDisplay', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);
    final toggle = find.byKey(const ValueKey('settings-danmaku-enabled'));
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.tap(toggle);
    await settleWrites(tester);

    expect(state.danmakuStyle.enabled, isFalse);
    expect(
      tester.widget<SwitchListTile>(toggle).value,
      isFalse,
      reason: '拨动后必须回显为关，不能弹回',
    );
    final display = readSettings(state)['danmakuDisplay'];
    expect(display, isA<Map>(), reason: '显示段必须落盘');
    expect((display! as Map)['enabled'], isFalse);

    // 往返：再拨一次必须回到开（「永远写 false」的实现会在这里露馅）。
    await tester.tap(toggle);
    await settleWrites(tester);
    expect(state.danmakuStyle.enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('透明度滑块：拖动后 danmakuStyle.opacity 立刻变化', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);
    final slider = find.byKey(const ValueKey('settings-danmaku-opacity'));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    expect(state.danmakuStyle.opacity, 0.8);

    await tester.drag(slider, const Offset(-120, 0));
    await settleWrites(tester);

    expect(state.danmakuStyle.opacity, lessThan(0.9), reason: '向左拖必须把透明度调低');
    expect(state.danmakuStyle.opacity, greaterThanOrEqualTo(0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动搜索开关：回显 + 写进 settings.json 的 danmaku 段', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);
    final toggle = find.byKey(const ValueKey('settings-danmaku-auto-search'));
    expect(
      tester.widget<SwitchListTile>(toggle).value,
      isFalse,
      reason: '默认关闭：未配置地址时不发任何请求',
    );

    await tester.tap(toggle);
    await settleWrites(tester);

    expect(state.danmakuSettings.autoSearch, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    final library = readSettings(state)['danmaku'];
    expect(library, isA<Map>());
    expect((library! as Map)['autoSearch'], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('速度档位：默认 20s，下拉含 30s/60s 与「自定义…」', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);

    final dropdown = find.byKey(const ValueKey('settings-danmaku-duration'));
    await tester.ensureVisible(dropdown);
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<int>>(dropdown).value, 20000);
    expect(find.text('20s'), findsOneWidget);
    expect(find.textContaining('越大越慢'), findsOneWidget);

    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    // 长档位要能一次选到：慢速观看时 20s 仍然「飞得太快」。
    expect(find.text('30s'), findsOneWidget);
    expect(find.text('45s'), findsOneWidget);
    expect(find.text('60s'), findsOneWidget);
    expect(find.text('自定义…'), findsOneWidget);

    await tester.tap(find.text('30s').last);
    await settleWrites(tester);
    expect(state.danmakuStyle.scrollDurationMs, 30000);
    final display = readSettings(state)['danmakuDisplay'] as Map?;
    expect(display?['scrollDurationMs'], 30000, reason: '档位改动必须落盘');
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义时长：25 秒写进 danmakuStyle 并落盘', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);

    final dropdown = find.byKey(const ValueKey('settings-danmaku-duration'));
    await tester.ensureVisible(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义…').last);
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('settings-danmaku-duration-input'));
    expect(input, findsOneWidget);
    await tester.enterText(input, '25');
    await tester.tap(
      find.byKey(const ValueKey('settings-danmaku-duration-confirm')),
    );
    await settleWrites(tester);

    expect(find.byType(GlassAlertDialog), findsNothing);
    expect(state.danmakuStyle.scrollDurationMs, 25000);
    final display = readSettings(state)['danmakuDisplay'] as Map?;
    expect(display?['scrollDurationMs'], 25000, reason: '自定义值必须落盘');
    // 25s 不在预设里：当前值必须当候选显示，否则下拉会直接断言白屏。
    expect(find.text('25s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自定义时长：99 与 1 秒只报错，不写盘也不关对话框', (tester) async {
    final state = await isolatedState(tester);
    await openPage(tester, state);
    final before = readSettings(state);

    final dropdown = find.byKey(const ValueKey('settings-danmaku-duration'));
    await tester.ensureVisible(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义…').last);
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('settings-danmaku-duration-input'));
    final confirm = find.byKey(
      const ValueKey('settings-danmaku-duration-confirm'),
    );
    for (final text in ['99', '1']) {
      await tester.enterText(input, text);
      await tester.tap(confirm);
      await settleWrites(tester);
      expect(
        tester.widget<TextField>(input).decoration!.errorText,
        isNotNull,
        reason: '$text 秒越界必须就地报错',
      );
      expect(find.byType(GlassAlertDialog), findsOneWidget, reason: '错了别关，让人改');
      expect(state.danmakuStyle.scrollDurationMs, 20000);
      expect(readSettings(state), before, reason: '非法输入不得写盘');
    }

    await tester.tap(
      find.byKey(const ValueKey('settings-danmaku-duration-cancel')),
    );
    await settleWrites(tester);
    expect(find.byType(GlassAlertDialog), findsNothing);
    expect(readSettings(state), before);
    expect(tester.takeException(), isNull);
  });

  test('DanmakuSettings 的多源解析仍按「用户源优先」——summary 依赖它', () {
    final resolved = resolveDanmakuSources(
      settings: const DanmakuSettings(
        sources: [
          DanmakuSourceConfig(id: 'a', name: 'A', url: 'https://a.test/x'),
          DanmakuSourceConfig(id: 'b', name: 'B', url: 'https://b.test/x'),
        ],
      ),
      configDanmaku: 'https://config.test/danmaku',
      bundleDanmaku: 'http://127.0.0.1:9321',
    );
    expect(resolved.origin, DanmakuApiSource.user);
    expect(resolved.sources, hasLength(2));
  });
}
