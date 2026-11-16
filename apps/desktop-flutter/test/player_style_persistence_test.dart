import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webhtv_pc/core/osd_style.dart';
import 'package:webhtv_pc/core/subtitle_style.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/player_osd.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/player_page_harness.dart';

/// 字幕 / 屏显样式的落盘链路（docs/reference/potplayer-checklist.md P1-4）。
///
/// 分两层，因为它们失败的原因不同：
/// - **存储层**：settings.json 里到底有没有这两个键、恢复默认后键是否消失；
/// - **播放器页**：从右键菜单改档之后，同一份 settings.json 重开页面拿到什么。
///
/// 只断言字段值（style.textScale == 1.25）测不出「落盘」——内存里改一下就能过。
/// 所以每条用例都落到**文件**或**下一轮读取**上。
void main() {
  late Directory temp;
  late String settingsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-style-prefs');
    settingsPath = '${temp.path}${Platform.pathSeparator}settings.json';
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, Object?> readRaw() {
    final file = File(settingsPath);
    if (!file.existsSync()) return const {};
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map<String, Object?> ? decoded : const {};
  }

  /// settings.json 的 ui 段（不存在时给空表，避免空指针掩盖真正的失败）。
  Map<String, Object?> uiSection() {
    final ui = readRaw()['ui'];
    return ui is Map<String, Object?> ? ui : const {};
  }

  // ---------------------------------------------------------------- 存储往返
  group('偏好存储：ui.subtitleStyle / ui.osdStyle', () {
    test('从未设置过：两个键都不写盘，getter 返回默认值', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.subtitleStyle, SubtitleStyle.defaults);
      expect(store.hasExplicitSubtitleStyle, isFalse);
      expect(store.osdStyle, OsdStyle.defaults);
      expect(store.hasExplicitOsdStyle, isFalse);

      // 造一次真实写盘：默认值不得被顺手固化进文件（缺席 = 用默认）。
      await store.rememberSite('fixture');
      expect(File(settingsPath).existsSync(), isTrue, reason: '写盘本身要发生，否则本用例是空转');
      expect(uiSection().containsKey('subtitleStyle'), isFalse);
      expect(uiSection().containsKey('osdStyle'), isFalse);
    });

    test('remember 之后重新构造 store（同一文件）读回一致', () async {
      const subtitle = SubtitleStyle(
        textColorValue: 0xFFFFEB3B,
        backgroundOpacity: 0.5,
        outlineWidth: 3,
        textScale: 1.25,
        bottomPadding: 48,
      );
      const osd = OsdStyle(textScale: 1.25, opacity: 0.7);

      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(await store.rememberSubtitleStyle(subtitle), isTrue);
      expect(await store.rememberOsdStyle(osd), isTrue);

      // 落盘内容逐字段核对：只断言「重新 load 后相等」会漏掉 toJson 少写一个键。
      final ui = uiSection();
      final subtitleJson = ui['subtitleStyle'] as Map<String, Object?>;
      expect(subtitleJson['textColorValue'], 0xFFFFEB3B);
      expect(subtitleJson['backgroundOpacity'], 0.5);
      expect(subtitleJson['outlineWidth'], 3.0);
      expect(subtitleJson['textScale'], 1.25);
      expect(subtitleJson['bottomPadding'], 48.0);
      final osdJson = ui['osdStyle'] as Map<String, Object?>;
      expect(osdJson['textScale'], 1.25);
      expect(osdJson['opacity'], 0.7);

      final reopened = UiPreferencesStore(path: settingsPath);
      await reopened.load();
      expect(reopened.subtitleStyle, subtitle);
      expect(reopened.hasExplicitSubtitleStyle, isTrue);
      expect(reopened.osdStyle, osd);
      expect(reopened.hasExplicitOsdStyle, isTrue);
    });

    test('把字幕样式改回默认后 settings.json 的 ui.subtitleStyle 键消失', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberSubtitleStyle(
        SubtitleStyle.defaults.copyWith(textScale: 1.5),
      );
      expect(
        uiSection().containsKey('subtitleStyle'),
        isTrue,
        reason: '非默认值必须先落盘，否则「键消失」证明不了任何事',
      );

      await store.rememberSubtitleStyle(SubtitleStyle.defaults);
      // 同一会话里 store 仍持有「显式值」（字段非空），删键发生在写盘那一步；
      // 所以这里断的是值的语义，文件与下一轮 load 才是键缺席的证明。
      expect(store.subtitleStyle.isDefault, isTrue);
      expect(
        uiSection().containsKey('subtitleStyle'),
        isFalse,
        reason: '恢复默认后必须删键：留下 {"textScale":1.0} 等于把默认值固化进设置文件',
      );

      // 再读一遍：下一轮启动不能又「看起来设置过」。
      final reopened = UiPreferencesStore(path: settingsPath);
      await reopened.load();
      expect(reopened.subtitleStyle, SubtitleStyle.defaults);
      expect(reopened.hasExplicitSubtitleStyle, isFalse);
    });

    test('把屏显样式改回默认后 settings.json 的 ui.osdStyle 键消失', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdStyle(const OsdStyle(textScale: 1.25));
      expect(uiSection().containsKey('osdStyle'), isTrue);

      await store.rememberOsdStyle(OsdStyle.defaults);
      expect(store.osdStyle.isDefault, isTrue, reason: '同上：同一会话里 hasExplicit 仍为 true');
      expect(
        uiSection().containsKey('osdStyle'),
        isFalse,
        reason: '恢复默认后必须删键（与 subtitleStyle 同一口径）',
      );

      final reopened = UiPreferencesStore(path: settingsPath);
      await reopened.load();
      expect(reopened.osdStyle, OsdStyle.defaults);
      expect(reopened.hasExplicitOsdStyle, isFalse);
    });

    test('越界值先夹取再落盘：菜单拖不到的值不得进设置文件', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberSubtitleStyle(
        const SubtitleStyle(textScale: 9, outlineWidth: -2, bottomPadding: 999),
      );
      await store.rememberOsdStyle(const OsdStyle(textScale: 0.1, opacity: 3));

      final ui = uiSection();
      expect((ui['subtitleStyle'] as Map)['textScale'], 1.8);
      expect((ui['subtitleStyle'] as Map)['outlineWidth'], 0.0);
      expect((ui['subtitleStyle'] as Map)['bottomPadding'], 120.0);
      expect((ui['osdStyle'] as Map)['textScale'], 0.8);
      expect((ui['osdStyle'] as Map)['opacity'], 1.0);

      final reopened = UiPreferencesStore(path: settingsPath);
      await reopened.load();
      expect(
        reopened.subtitleStyle,
        SubtitleStyle.defaults.copyWith(textScale: 1.8, outlineWidth: 0, bottomPadding: 120),
      );
      expect(reopened.osdStyle, const OsdStyle(textScale: 0.8));
    });

    test('旧版本设置文件没有这两个键时保持默认（升级不改变外观）', () async {
      File(settingsPath).writeAsStringSync(
        jsonEncode({
          'ui': {'lastSiteKey': 'fixture'},
          'player': {'autoNext': true},
        }),
      );
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.subtitleStyle, SubtitleStyle.defaults);
      expect(store.osdStyle, OsdStyle.defaults);
      // 同一段里的老键仍然读得到（新增字段不得挤掉别人）。
      expect(uiSection()['lastSiteKey'], 'fixture');
    });
  });

  // ---------------------------------------------------------------- 播放器页
  //
  // 页面用**固定的 AppPaths**：harness 的 pumpPlayerPage 每次自己造临时目录，
  // 造不出「同一份 settings.json 重开页面」这个前提。
  group('播放器页：右键菜单改档 → 落盘 → 重开页面', () {
    AppPaths pathsFor(Directory temp) => AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/webhtv-pc',
        'data': '${temp.path}/webhtv-pc',
        'cache': '${temp.path}/webhtv-pc/cache',
        'state': '${temp.path}/webhtv-pc/logs',
      },
    );

    /// 第几次 pump：给页面一个唯一 key，强制**重建 State**。
    ///
    /// 不带 key 时 pumpWidget 会复用同一个 PlayerPage element（同类型同位置），
    /// initState 不再跑、上一次打开的菜单还挂在树上——那就不是「重开播放器页」。
    var pageSerial = 0;

    /// pump 一个播放器页；返回值是这一页的 AppState（同一份文件只换 state）。
    Future<AppState> pumpPage(WidgetTester tester, AppPaths paths) async {
      final serial = ++pageSerial;
      final state = AppState(paths: paths, log: LogService());
      addTearDown(state.dispose);
      // 与 harness 同一条 Trap A：bootstrap 的落盘 Future 建在真实 zone 里，
      // 在 FakeAsync zone 直接 await 会永久挂起。
      await tester.runAsync(() async {
        await state.bootstrap();
      });
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      installMediaKitMocks(tester);
      installWindowManagerMocks(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: PlayerPage(
              key: ValueKey('player-page-$serial'),
              state: state,
              request: const PlaybackRequest(
                url: 'http://127.0.0.1:9/never.m3u8',
                title: '示例剧集',
                siteKey: 'fixture',
                vodId: 'demo-1',
                vodName: '示例剧集',
                episodeName: 'E3',
                flag: '线路一',
              ),
            ),
          ),
        ),
      );
      await settlePlayerPage(tester);
      return state;
    }

    /// 打开右键菜单（与 phase8_context_menu_content_test.dart 同一手法）。
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tapAt(const Offset(300, 260), buttons: kSecondaryButton);
      await settlePlayerPage(tester);
      expect(find.byType(PlayerContextMenu), findsOneWidget, reason: '右键没能打开菜单');
    }

    List<InkWell> rowsAt(WidgetTester tester, int level) {
      final surfaces = find.descendant(
        of: find.byType(PlayerContextMenu),
        matching: find.byType(Material),
      );
      if (level >= surfaces.evaluate().length) return const [];
      return tester
          .widgetList<InkWell>(
            find.descendant(of: surfaces.at(level), matching: find.byType(InkWell)),
          )
          .toList();
    }

    String labelOf(WidgetTester tester, InkWell row) => tester
        .widgetList<Text>(
          find.descendant(of: find.byWidget(row), matching: find.byType(Text)),
        )
        .map((t) => t.data ?? '')
        .join();

    bool isChecked(WidgetTester tester, InkWell row) => tester
        .widgetList(
          find.descendant(of: find.byWidget(row), matching: find.byIcon(Icons.check)),
        )
        .isNotEmpty;

    /// 第 level 列的选中项（无勾 = 空表），用来读「当前生效档位」。
    List<String> checkedAt(WidgetTester tester, int level) => [
      for (final row in rowsAt(tester, level))
        if (isChecked(tester, row)) labelOf(tester, row),
    ];

    /// 点开一级：与内容结构套件同一手法（先 ensureVisible，列可能被压高滚动）。
    Future<void> drill(WidgetTester tester, String label) async {
      final target = find.descendant(
        of: find.byType(PlayerContextMenu),
        matching: find.text(label),
      );
      expect(target, findsWidgets, reason: '菜单里找不到「$label」');
      await tester.ensureVisible(target.first);
      await settlePlayerPage(tester, times: 2);
      await tester.tap(target.first);
      await settlePlayerPage(tester, times: 3);
    }

    /// 按 id 点一个叶子（key 是 player-menu-item-<id>）。
    Future<void> tapItem(WidgetTester tester, String id) async {
      final target = find.byKey(ValueKey('player-menu-item-$id'));
      expect(target, findsOneWidget, reason: '菜单里找不到菜单项「$id」');
      await tester.ensureVisible(target);
      await settlePlayerPage(tester, times: 2);
      await tester.tap(target);
      await settlePlayerPage(tester, times: 3);
    }

    /// 等页面把样式写进 settings.json。
    ///
    /// 页面的落盘是 unawaited(...)：写盘本体同步（writeSettingsSectionSync），
    /// 但它排在该 store 的 _persistQueue 之后，而那条队列的底部 Future 建在
    /// bootstrap 的 runAsync 真实 zone 里。所以「只 pump」清不掉这件事：
    /// pump 清 FakeAsync 的微任务，runAsync 才放行真实 I/O 的完成回调。
    /// 两者交替转，直到磁盘出现预期值（上限 50 轮，不做无意义等待）。
    Future<void> waitForDisk(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 50 && !done(); i++) {
        await tester.pump(const Duration(milliseconds: 10));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
    }

    /// 把 ui 段里的一个键读出来（不存在给 null）。
    Map<String, Object?>? uiKeyOf(String path, String key) {
      final file = File(path);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      final ui = decoded['ui'];
      if (ui is! Map) return null;
      final value = ui[key];
      return value is Map<String, Object?> ? value : null;
    }

    testWidgets('改字号落盘：重开播放器页拿到 125%，渲染投影同步', (tester) async {
      final paths = pathsFor(temp);
      final settingsPath = paths.settingsPath;

      final first = await pumpPage(tester, paths);
      expect(first.subtitleStyle, SubtitleStyle.defaults);

      await openMenu(tester);
      await drill(tester, '字幕');
      await drill(tester, '字幕样式');
      await drill(tester, '字号');
      expect(checkedAt(tester, 3), ['100%'], reason: '默认档位必须是 100%');

      await tapItem(tester, 'sub_size_125');
      // 字号叶子**不关菜单**（连着调档是这条菜单存在的理由）。
      expect(find.byType(PlayerContextMenu), findsOneWidget, reason: '改字号把菜单关了');
      expect(checkedAt(tester, 3), ['125%'], reason: '勾选必须当场挪到 125%');

      // 渲染投影：media-kit 的 SubtitleViewConfiguration 基准 32dp × 1.25。
      final video = tester.widget<Video>(find.byType(Video));
      expect(
        video.subtitleViewConfiguration.style.fontSize,
        40,
        reason: '页面的字幕样式没传到 Video（32dp × 1.25 = 40）',
      );

      // 落盘：页面是不 await 的，必须等文件里真的出现这个值。
      await waitForDisk(
        tester,
        () => uiKeyOf(settingsPath, 'subtitleStyle')?['textScale'] == 1.25,
      );
      expect(
        uiKeyOf(settingsPath, 'subtitleStyle')?['textScale'],
        1.25,
        reason: '右键菜单改档后必须写进同一份 settings.json',
      );

      // 同一份 settings.json、新的 AppState：模拟「关掉播放器再打开」。
      final second = await pumpPage(tester, paths);
      expect(second.subtitleStyle.textScale, 1.25);
      expect(uiKeyOf(settingsPath, 'subtitleStyle'), isNotNull, reason: '落盘值必须还在文件里');

      await openMenu(tester);
      await drill(tester, '字幕');
      await drill(tester, '字幕样式');
      await drill(tester, '字号');
      expect(
        checkedAt(tester, 3),
        ['125%'],
        reason: '重开播放器页后菜单仍是 100% —— 落盘链路没接上',
      );
      expect(
        tester.widget<Video>(find.byType(Video)).subtitleViewConfiguration.style.fontSize,
        40,
      );
    });

    testWidgets('「恢复默认样式」回到 defaults，settings.json 的键随之消失', (tester) async {
      final paths = pathsFor(temp);
      final settingsPath = paths.settingsPath;

      // 先造一份非默认的落盘状态：页面必须从这一档起跑。
      await tester.runAsync(() async {
        final seed = UiPreferencesStore(path: settingsPath);
        await seed.load();
        await seed.rememberSubtitleStyle(
          const SubtitleStyle(textScale: 1.5, outlineWidth: 3),
        );
      });
      expect(uiKeyOf(settingsPath, 'subtitleStyle')?['textScale'], 1.5);

      final state = await pumpPage(tester, paths);
      expect(state.subtitleStyle.textScale, 1.5, reason: '页面必须从落盘值起跑');

      await openMenu(tester);
      await drill(tester, '字幕');
      await drill(tester, '字幕样式');
      await drill(tester, '字号');
      expect(checkedAt(tester, 3), ['150%'], reason: '落盘的 150% 应显示为当前档');

      await tapItem(tester, 'sub_style_reset');
      // 恢复默认是「收尾动作」，点了就关菜单（与其它 act() 叶子一致）。
      expect(find.byType(PlayerContextMenu), findsNothing, reason: '恢复默认后菜单应关闭');
      expect(state.subtitleStyle, SubtitleStyle.defaults);

      await waitForDisk(
        tester,
        () => uiKeyOf(settingsPath, 'subtitleStyle') == null,
      );
      expect(
        uiKeyOf(settingsPath, 'subtitleStyle'),
        isNull,
        reason: '恢复默认后 ui.subtitleStyle 必须从 settings.json 消失',
      );

      // 重开页面确认「默认」不是内存里的假象。
      final reopened = await pumpPage(tester, paths);
      expect(reopened.subtitleStyle, SubtitleStyle.defaults);
      expect(uiKeyOf(settingsPath, 'subtitleStyle'), isNull, reason: '重开页面读到默认，文件里也没有残留键');
      await openMenu(tester);
      await drill(tester, '字幕');
      await drill(tester, '字幕样式');
      await drill(tester, '字号');
      expect(checkedAt(tester, 3), ['100%']);
    });

    testWidgets('屏显样式：字号与不透明度落到 OSD 层并写盘', (tester) async {
      final paths = pathsFor(temp);
      final settingsPath = paths.settingsPath;

      await pumpPage(tester, paths);
      expect(
        tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer)).style,
        OsdStyle.defaults,
      );

      await openMenu(tester);
      await drill(tester, '显示');
      await drill(tester, '屏显样式');
      await drill(tester, '字号');
      expect(checkedAt(tester, 3), ['100%']);

      await tapItem(tester, 'osd_size_125');
      expect(
        tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer)).style.textScale,
        1.25,
        reason: '菜单改的字号必须传给屏显层（否则只是改了个变量）',
      );

      await drill(tester, '不透明度');
      await tapItem(tester, 'osd_opacity_50');
      expect(
        tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer)).style.opacity,
        0.5,
      );

      await waitForDisk(
        tester,
        () => uiKeyOf(settingsPath, 'osdStyle')?['opacity'] == 0.5,
      );
      final osdJson = uiKeyOf(settingsPath, 'osdStyle');
      expect(osdJson?['textScale'], 1.25);
      expect(osdJson?['opacity'], 0.5);

      // 重开页面：两个字段都从设置文件回来。
      final reopened = await pumpPage(tester, paths);
      expect(reopened.osdStyle, const OsdStyle(textScale: 1.25, opacity: 0.5));
      expect(
        tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer)).style,
        const OsdStyle(textScale: 1.25, opacity: 0.5),
      );

      // 恢复默认：层回到 defaults，键也从文件消失。
      await openMenu(tester);
      await drill(tester, '显示');
      await drill(tester, '屏显样式');
      await tapItem(tester, 'osd_style_reset');
      expect(
        tester.widget<PlayerOsdLayer>(find.byType(PlayerOsdLayer)).style,
        OsdStyle.defaults,
      );
      await waitForDisk(tester, () => uiKeyOf(settingsPath, 'osdStyle') == null);
      expect(
        uiKeyOf(settingsPath, 'osdStyle'),
        isNull,
        reason: '恢复默认后 ui.osdStyle 必须从 settings.json 消失',
      );
    });
  });
}
