import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/player_button_config_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

/// 按钮配置页（Task 9 / `docs/phase8/design/03` §6）。
///
/// 断言策略：**正向断言精确期望值**，不用「不抛异常」这类空洞断言。
/// 每条用例的注释写明「什么错误实现会仍然通过」，并据此补上断言。
///
/// ## 为什么所有配置写入都必须包在 `tester.runAsync` 里
///
/// `setUp` 跑在**真实**事件循环 zone；`testWidgets` 的函数体跑在 `FakeAsync`。
/// `UiPreferencesStore._persistQueue`（`ui_preferences_store.dart:469`）是
/// `setUp` 那个 zone 里造出来的 `Future`，`Future.then` 会按**该 Future 自己的
/// zone** 去 `scheduleMicrotask`（`_Future._addListener` 用的是 `_zone`，
/// 不是调用方的 zone），于是续体落在真实事件循环上，`FakeAsync` 永远不推进它。
/// 在 `testWidgets` 里直接 `await state.setPlayerButtonOrder(...)` 会挂到
/// 10 分钟超时，并让后续用例连锁报 `Guarded function conflict`。
/// `runAsync` 在真实 zone 里执行回调，写入才能完成。
///
/// 注意：`pumpAndSettle` 用**有界超时**（5s），这样将来再出现挂起是几秒失败，
/// 而不是 10 分钟。
void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('webhtv-phase8-btnpage');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    state = AppState(paths: paths, log: LogService());
    await state.bootstrap();
  });

  tearDown(() {
    state.dispose();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 有界 `pumpAndSettle`：3 参形式，超时 5 秒。
  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );

  /// 在真实 zone 里完成一次配置写入（见文件头注释）。
  Future<void> configure(
    WidgetTester tester,
    Future<bool> Function() write,
  ) async {
    await tester.runAsync(() async {
      await write();
    });
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: PlayerButtonConfigPage(state: state),
      ),
    );
    await settle(tester);
  }

  Finder rowOf(String id) => find.byKey(ValueKey('button-row-$id'));
  Finder handleOf(String id) => find.byKey(ValueKey('button-handle-$id'));
  Finder switchOf(String id) => find.byKey(ValueKey('button-visible-$id'));
  Finder previewFinder() => find.byKey(const ValueKey('player-buttons-preview'));

  String previewText(WidgetTester tester) =>
      tester.widget<Text>(previewFinder()).data ?? '';

  /// 渲染出来的行序（按屏幕纵坐标升序）。
  List<String> renderedOrder(WidgetTester tester) {
    final tops = <String, double>{
      for (final spec in kPlayerButtons)
        spec.id: tester.getRect(rowOf(spec.id)).top,
    };
    final ids = tops.keys.toList()
      ..sort((a, b) => tops[a]!.compareTo(tops[b]!));
    return ids;
  }

  const defaultPreview =
      '上一集  ·  播放/暂停  ·  下一集  ·  静音  ·  音量  ·  倍速  ·  剧集  ·  全屏';

  testWidgets('列出全部 8 个按钮与中文名', (tester) async {
    await pumpPage(tester);
    for (final spec in kPlayerButtons) {
      expect(find.text(spec.label), findsWidgets, reason: '缺少「${spec.label}」');
    }
    // 8 行都真的建出来了，而不是只建了视口内那几行。
    for (final spec in kPlayerButtons) {
      expect(rowOf(spec.id), findsOneWidget, reason: '缺少 ${spec.id} 行');
    }
  });

  testWidgets('列表按当前顺序渲染，而不是定义顺序', (tester) async {
    // 反向顺序：任何「忽略 _order、直接按 kPlayerButtons 渲染」的实现都会失败。
    const reversed = [
      'fullscreen',
      'episodes',
      'speed',
      'volume',
      'mute',
      'next',
      'play',
      'prev',
    ];
    await configure(tester, () => state.setPlayerButtonOrder(reversed));
    await pumpPage(tester);

    final tops = [
      for (final id in state.playerButtonOrder) tester.getRect(rowOf(id)).top,
    ];
    expect(tops.length, 8);
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]), reason: '第 $i 行应排在上一行下方');
    }
    // 屏幕上的顺序本身就是反向的（不只是「单调递增」这种弱断言）。
    expect(renderedOrder(tester), reversed);
  });

  testWidgets('分组标签逐行显示（不是一页图例）', (tester) async {
    await pumpPage(tester);
    for (final spec in kPlayerButtons) {
      // 不能写成 `find.descendant(of: rowOf(id), matching: find.text(group.label))`
      // 期望 `findsOneWidget`：`volume` 行的**标题**就是「音量」，与
      // `PlayerButtonGroup.volume.label`（同样是「音量」）字面相同，那一行会
      // 命中 2 个 Text。直接断言 `ListTile.subtitle` 的精确文案，
      // 既避开这个同名碰撞，又比「行内存在某段文字」更强——
      // 「只在页首放一页图例、行内不放分组」的实现会在这里失败。
      final tile = tester.widget<ListTile>(rowOf(spec.id));
      final subtitle = tile.subtitle;
      expect(subtitle, isA<Text>(), reason: '${spec.id} 行应有分组副标题');
      expect(
        (subtitle! as Text).data,
        spec.group.label,
        reason: '${spec.id} 行的分组标签应为「${spec.group.label}」',
      );
    }
  });

  testWidgets('每行恰好一个拖动手柄，且在手侧左端', (tester) async {
    // **平台必须覆盖成 Windows**：`ReorderableListView` 的默认手柄只在
    // 桌面平台（linux/windows/macOS）插一个 `Icons.drag_handle`；
    // 在 iOS/android/fuchsia 上它插的是 `ReorderableDelayedDragStartListener`
    // （**不带图标**，见 `material/reorderable_list.dart:382-443`）。
    // `flutter_test` 默认平台是 **android**，所以不覆盖的话，
    // 下面那条「手柄数不得翻倍」的断言在 `buildDefaultDragHandles: true`
    // 的缺陷实现下**照样通过**——它根本抓不到自己声称要抓的东西（实测确认）。
    // 本应用是 Windows 桌面端，覆盖成 Windows 才是它真实运行的平台。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpPage(tester);
      final rows = tester.widgetList(find.byType(ListTile)).length;
      expect(rows, 8);
      // `ReorderableListView.buildDefaultDragHandles` 默认 true，会在**行尾**再插一个
      // 无 key 的手柄，正好压在 trailing 的开关上。那个手柄不会让任何 byKey 断言失败，
      // 所以必须用总数把它抓出来。
      expect(
        find.byIcon(Icons.drag_handle),
        findsNWidgets(rows),
        reason: '每行只能有一个手柄（默认拖动手柄会让这个数字翻倍）',
      );
      // 第二条独立信号：`ReorderableDragStartListener` 是**精确类型**匹配，
      // 桌面平台的默认手柄同样用它，所以默认手柄开着时这里也会翻倍。
      expect(
        find.byType(ReorderableDragStartListener),
        findsNWidgets(rows),
        reason: '每行只能有一个拖动监听器（默认手柄会再加一个）',
      );
      for (final spec in kPlayerButtons) {
        final handle = handleOf(spec.id);
        expect(handle, findsOneWidget);
        final rowRect = tester.getRect(rowOf(spec.id));
        final handleRect = tester.getRect(handle);
        expect(
          handleRect.center.dx,
          lessThan(rowRect.center.dx),
          reason: '手柄应在行首（设计稿把 ≡ 画在左边）',
        );
      }
    } finally {
      // 必须在**测试体内**复位：框架的 `debugAssertAllFoundationVarsUnset`
      // 在 tearDown 之前就会跑（`phase3_search_page_test.dart:309-311` 同款先例）。
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('开关反映已存的隐藏集', (tester) async {
    await configure(
      tester,
      () => state.setPlayerButtonHidden({'speed', 'fullscreen'}),
    );
    await pumpPage(tester);
    for (final spec in kPlayerButtons) {
      expect(
        tester.widget<Switch>(switchOf(spec.id)).value,
        !state.playerButtonHidden.contains(spec.id),
        reason: '${spec.id} 的开关状态应与隐藏集一致',
      );
    }
  });

  testWidgets('切换开关会持久化隐藏集（精确集合 + 往返）', (tester) async {
    await pumpPage(tester);
    final toggle = switchOf('speed');
    expect(toggle, findsOneWidget);
    await tester.ensureVisible(toggle);
    await settle(tester);

    await tester.tap(toggle);
    await settle(tester);
    expect(state.playerButtonHidden, {'speed'});
    expect(tester.widget<Switch>(switchOf('speed')).value, isFalse);

    // 往返：关掉再打开必须回到空集（「只会往里加」的实现会在这里失败）。
    await tester.tap(switchOf('speed'));
    await settle(tester);
    expect(state.playerButtonHidden, isEmpty);
    expect(tester.widget<Switch>(switchOf('speed')).value, isTrue);
  });

  testWidgets('切换开关后预览行立刻反映新隐藏集', (tester) async {
    // 对照组：只在 `build` 时读一次隐藏集、或切换后不重建预览行的实现，
    // 会继续显示「倍速」。
    await pumpPage(tester);
    expect(previewText(tester), defaultPreview);

    // 9 行在 600px 视口里放不下，`speed` 行的实际位置落在底部按钮栏下方，
    // 不滚动过去 `tap` 会打在「完成」按钮上（实测：hit test 命中 FilledButton）。
    final toggle = switchOf('speed');
    await tester.ensureVisible(toggle);
    await settle(tester);
    await tester.tap(toggle);
    await settle(tester);

    expect(state.playerButtonHidden, {'speed'});
    expect(
      previewText(tester),
      '上一集  ·  播放/暂停  ·  下一集  ·  静音  ·  音量  ·  剧集  ·  全屏',
    );
  });

  testWidgets('恢复默认需二次确认（design/03 §6.2）', (tester) async {
    await configure(tester, () => state.setPlayerButtonOrder(['next', 'play']));
    await configure(tester, () => state.setPlayerButtonHidden({'speed'}));
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('player-buttons-reset')));
    await settle(tester);
    // 第一次点击只弹确认框，不改状态。
    //
    // 注意：**不能**只断言 `find.text('恢复默认')`——触发按钮的文案本身就是
    // 「恢复默认」，那条断言在「对话框根本没弹出来」时同样成立。
    // 必须断言对话框独有的内容与按钮。
    expect(find.text('将按钮顺序与显示状态恢复为默认值。'), findsOneWidget);
    expect(find.text('确认恢复'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(state.playerButtonHidden, {'speed'}, reason: '弹框阶段不得改隐藏集');
    expect(state.playerButtonOrder.take(2).toList(), ['next', 'play']);

    await tester.tap(find.text('确认恢复'));
    await settle(tester);
    expect(state.playerButtonHidden, isEmpty);
    expect(state.playerButtonOrder, defaultButtonOrder());
  });

  testWidgets('确认恢复默认后页面自身也回到默认顺序', (tester) async {
    // 对照组：只重置 `AppState`、不刷新本地 `_order` 的实现会在这里失败
    // （页面仍停在旧顺序，预览行也还是旧文案）。
    await configure(tester, () => state.setPlayerButtonOrder(['next', 'play']));
    await configure(tester, () => state.setPlayerButtonHidden({'speed'}));
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('player-buttons-reset')));
    await settle(tester);
    await tester.tap(find.text('确认恢复'));
    await settle(tester);

    expect(renderedOrder(tester), defaultButtonOrder());
    expect(previewText(tester), defaultPreview);
  });

  testWidgets('取消恢复默认不改动任何状态', (tester) async {
    await configure(tester, () => state.setPlayerButtonOrder(['next', 'play']));
    await configure(tester, () => state.setPlayerButtonHidden({'speed'}));
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('player-buttons-reset')));
    await settle(tester);
    await tester.tap(find.text('取消'));
    await settle(tester);

    expect(state.playerButtonHidden, {'speed'});
    expect(state.playerButtonOrder.take(2).toList(), ['next', 'play']);
    // 页面也不许动。
    expect(renderedOrder(tester).take(2).toList(), ['next', 'play']);
  });

  testWidgets('预览行精确反映当前顺序', (tester) async {
    await configure(
      tester,
      () => state.setPlayerButtonOrder(['next', 'play', 'prev']),
    );
    await pumpPage(tester);
    expect(previewFinder(), findsOneWidget);
    // 字面量断言：顺序与分隔符都被锁住。
    expect(
      previewText(tester),
      '下一集  ·  播放/暂停  ·  上一集  ·  静音  ·  音量  ·  倍速  ·  剧集  ·  全屏',
    );
  });

  testWidgets('预览行排除已隐藏的按钮', (tester) async {
    await configure(tester, () => state.setPlayerButtonHidden({'mute'}));
    await pumpPage(tester);
    expect(
      previewText(tester),
      '上一集  ·  播放/暂停  ·  下一集  ·  音量  ·  倍速  ·  剧集  ·  全屏',
    );
  });

  testWidgets('全部隐藏时预览行仍是非空文本', (tester) async {
    await configure(
      tester,
      () => state.setPlayerButtonHidden(
        kPlayerButtons.map((spec) => spec.id).toSet(),
      ),
    );
    await pumpPage(tester);
    expect(previewFinder(), findsOneWidget);
    final data = tester.widget<Text>(previewFinder()).data;
    expect(data, isNotNull);
    // 精确值：只断言「非空」的话，随便一个占位符（例如 " "）都能通过。
    expect(data, '（已隐藏全部按钮）');
  });

  testWidgets('拖动重排会持久化顺序（向上拖：精确置换）', (tester) async {
    await pumpPage(tester);
    final handle = handleOf('play');
    expect(handle, findsOneWidget);
    // 把「播放/暂停」向上拖一格。
    await tester.drag(handle, const Offset(0, -60));
    await settle(tester);
    expect(state.playerButtonOrder, [
      'play',
      'prev',
      'next',
      'mute',
      'volume',
      'speed',
      'episodes',
      'fullscreen',
    ]);
    // 页面自身也要跟着重排。
    expect(renderedOrder(tester).first, 'play');
  });

  testWidgets('向下拖动重排（抓 -1 下标调整不能重复应用）', (tester) async {
    // 这条用例是**唯一**能区分 `onReorder` 与 `onReorderItem` 的用例。
    //
    // 框架在 `_handleReorderItem`（`reorderable_list.dart:1022-1025`）里已经替
    // `onReorderItem` 做过「移除一项后下标左移」的 -1 调整。若实现改用
    // `onReorderItem` 却保留了自己那句 `if (newIndex > oldIndex) newIndex -= 1;`，
    // 就会**减两次**。
    //
    // 向上拖时（oldIndex > newIndex）那句判断恒为假，减两次与减一次结果相同，
    // 所以「向上拖一格」的用例抓不到这个缺陷；只有**向下拖**才会暴露：
    // 正确结果 `['play','prev',...]`，减两次会退化成 `['prev','play',...]`（原地不动）。
    await pumpPage(tester);
    final handle = handleOf('prev');
    expect(handle, findsOneWidget);
    await tester.drag(handle, const Offset(0, 72));
    await settle(tester);

    expect(state.playerButtonOrder, [
      'play',
      'prev',
      'next',
      'mute',
      'volume',
      'speed',
      'episodes',
      'fullscreen',
    ]);
    expect(renderedOrder(tester).take(2).toList(), ['play', 'prev']);
  });

  testWidgets('拖动不足半行时不改变顺序', (tester) async {
    await pumpPage(tester);
    await tester.drag(handleOf('play'), const Offset(0, -20));
    await settle(tester);
    // 对照组：「只要拖了就重排」的实现会在这里失败。
    expect(state.playerButtonOrder, defaultButtonOrder());
  });

  testWidgets('拖动过程中不出现非 0 elevation', (tester) async {
    await pumpPage(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(handleOf('play')),
    );
    await gesture.moveBy(const Offset(0, -60));
    // 默认 proxyDecorator 的 elevation 动画是 250ms，跑满再看。
    //
    // **必须 pump 两次**：第一次 `pump` 只提交「代理层已插入 Overlay」这一帧，
    // 代理层内 `AnimatedBuilder` 的动画控制器要在**下一次** tick 才被推进
    // （`Ticker._startTime ??= timeStamp`，`scheduler/ticker.dart:277`——首帧
    // 的 elapsed 恒为 0，`lerpDouble(0, 6, 0) == 0`）。只 pump 一次的话，
    // 即便用的是默认装饰器，读到的 elevation 也还是 0，这条用例就变成了
    // 一条**永远通过**的假断言（实测：漏掉第二次 pump 时，
    // 删掉自定义 `proxyDecorator` 的缺陷实现照样全绿）。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // 先确认拖动代理层**真的存在**——否则「遍历所有 Material 都 elevation 0」
    // 在「拖动根本没起来」时也会通过。
    //
    // **不能断言 `find.byType(Overlay)`**：`MaterialApp`/`Navigator` 永远提供
    // 一个 `Overlay`，所以那条断言**恒真**（实测：把拖动手柄换成惰性实现，
    // 这条用例照样通过）。
    // 有区分力的信号是**拖动代理层本身**：它是 `proxyDecorator` 产出的
    // `Material`，底色 `surfaceContainerHigh`——静止时页面上**一个都没有**。
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Material &&
            w.color ==
                buildAppTheme(Brightness.dark).colorScheme.surfaceContainerHigh &&
            w.elevation == 0,
      ),
      findsOneWidget,
      reason: '拖动代理层必须存在（用它的底色识别，而不是恒真的 Overlay）',
    );

    for (final material in tester.widgetList<Material>(find.byType(Material))) {
      expect(
        material.elevation,
        0,
        reason: '拖动代理层不得有 elevation（The Zero-Elevation Rule）',
      );
    }

    await gesture.up();
    await settle(tester);
  });
}
