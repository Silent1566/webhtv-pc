import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/ui/player_context_menu.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(body: Stack(children: [child])),
);

/// 每一列的表面（`Material`），按树序排列：第 1 列、第 2 列……
///
/// 用列里的 `Material` 而不是 `find.byType(PlayerContextMenu)`：后者返回的是
/// 整个飞出层的产物（全窗口大小的坐标底板），能证明「菜单层在哪儿」，但
/// 「这一列多大、落在哪儿」要落在真正的表面上。
Finder get columnSurfaces => find.descendant(
  of: find.byType(PlayerContextMenu),
  matching: find.byType(Material),
);

/// 第 1 列（主列）的表面。
Finder get menuSurface => columnSurfaces.first;

/// 第 [index] 列的矩形（0 = 主列）。
Rect columnRect(WidgetTester tester, int index) =>
    tester.getRect(columnSurfaces.at(index));

/// 把测试画布放大到和菜单声明的 `viewport` 一致。
///
/// 真是真事：飞出式菜单会把子列推到锚点右侧，而默认画布只有 800x600——
/// 超出画布的列会被父 `Stack` 裁掉且**点不到**（不在根底板的 bounds 内）。
/// 真实播放器页里 body 原点就是窗口原点、两者一致，所以这里也设成一致。
void setSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 深色主题下的角色值（菜单恒定跑在播放器页的暗色主题上，`design/01` §4.3）。
final ColorScheme darkScheme = buildAppTheme(Brightness.dark).colorScheme;

/// 造一个**鼠标**指针用于悬停。
///
/// 必须是 `PointerDeviceKind.mouse`：touch 设备在「抬起」状态发不出 move，
/// 悬停（`PointerHoverEvent`）只有 mouse 才产生；用 `tester.tap` 之类
/// 也造不出 hover——那正是「点击驱动」和「悬停驱动」两种实现能在这里被区分
/// 开的原因。
Future<TestGesture> mousePointer(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  // 先落在任何列之外的原点：进入菜单必须是一次真实的「移动」。
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  return gesture;
}

/// 悬停/离开需要的空白点：远在所有列（左上角锚点 100,100 起）之外，
/// 且在 1440x900 的画布内。
const Offset blankSpot = Offset(700, 820);

void main() {
  group('位置 clamp（design/04 §5.2）', () {
    test('左上角锚点不偏移', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(10, 10),
        viewport: const Size(1440, 900),
        menuSize: const Size(240, 420),
      );
      expect(origin, const Offset(10, 10));
    });

    test('右下角锚点被拉回窗口内', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(1430, 890),
        viewport: const Size(1440, 900),
        menuSize: const Size(240, 420),
      );
      expect(origin.dx + 240, lessThanOrEqualTo(1440));
      expect(origin.dy + 420, lessThanOrEqualTo(900));
      // 正向断言精确值，而不是只关心「没超出」：只把 x 拉回、y 不管的实现
      // 也能过上面两条之外的那一条（`origin.dy = 890` 时 890 + 420 = 1310 会
      // 超出，但把 menuSize 当 0 的实现同样过），所以这里钉住两个分量。
      expect(origin, const Offset(1192, 472));
    });

    test('菜单比窗口还大时贴左上角', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(500, 500),
        viewport: const Size(200, 200),
        menuSize: const Size(240, 420),
      );
      expect(origin.dx, 8);
      expect(origin.dy, 8);
    });

    test('负坐标锚点（多屏/任务栏外的全局坐标）也贴留白', () {
      final origin = clampMenuOrigin(
        anchor: const Offset(-40, -12),
        viewport: const Size(1440, 900),
        menuSize: const Size(240, 420),
      );
      expect(origin, const Offset(8, 8));
    });
  });

  group('菜单渲染（design/04 §4.1、§5.6）', () {
    testWidgets('菜单是 Scaffold 的后代（页内 Stack 层，不是 Navigator 的 Overlay）', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 这是本任务的核心设计决定（`design/04` §3）：截图 harness 取树中第一个
      // `RepaintBoundary`（`Scaffold` 那层），菜单必须是 **`Scaffold` 的后代**
      // 才拍得到。`showMenu` / `MenuAnchor` 把菜单挂到 `Navigator` 的 `Overlay`
      // 上，而 `Overlay` 是 `Scaffold` 的**祖先**，于是这条断言会红。
      // （`design/05` §4 反向验证 #7 的 L2 版本；L3 版本是 Task 13 的截图对比。）
      expect(
        find.descendant(
          of: find.byType(Scaffold),
          matching: find.byType(PlayerContextMenu),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byType(PlayerContextMenu),
          matching: find.byType(Scaffold),
        ),
        findsOneWidget,
      );
    });

    testWidgets('分组渲染成可飞出的父项行，而不是静态标题', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [
                  PlayerMenuItem(id: 'play', label: '播放 / 暂停'),
                  PlayerMenuItem(id: 'prev', label: '上一集'),
                ],
              ),
              PlayerMenuSection(
                title: '速度',
                items: [PlayerMenuItem(id: 'rate_1', label: '1.0×', selected: true)],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 分组标题变成了第 1 列里的一行（bodyMedium + onSurface），不再是 11px 的
      // labelSmall 静态标签：用户报的「速度的 6 个档位平铺在主列里」正是
      // 「标题 + 摊平的项」这个结构的产物。
      expect(find.text('播放'), findsOneWidget);
      expect(find.text('速度'), findsOneWidget);
      for (final title in ['播放', '速度']) {
        final text = tester.widget<Text>(find.text(title));
        expect(text.style?.color, darkScheme.onSurface, reason: '「$title」是行不是标题');
        expect(text.style?.fontSize, isNot(11), reason: '「$title」不该还是标题字号');
      }
      // 组内的项不再摊在主列里，只在自己组的飞出列里。
      expect(find.text('播放 / 暂停'), findsNothing);
      expect(find.text('上一集'), findsNothing);
      expect(find.text('1.0×'), findsNothing);
      // 每个分组行都带「飞出」方向指示；主列只有这两行。
      expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
      expect(columnSurfaces, findsOneWidget);

      // 点开「速度」：档位在**第二列**里，当前值仍带勾。
      await tester.tap(find.text('速度'));
      await tester.pumpAndSettle();
      expect(find.text('1.0×'), findsOneWidget);
      expect(columnSurfaces, findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-rate_1')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
    });

    testWidgets('禁用项不可点（design/04 §5.6）', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: [
              PlayerMenuSection(
                title: '信息',
                items: [
                  PlayerMenuItem(
                    id: 'diag',
                    label: '播放诊断',
                    enabled: false,
                    onSelect: () => tapped = true,
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 「信息」组的项在飞出列里，先点开分组。
      await tester.tap(find.text('信息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放诊断'));
      await tester.pump();
      expect(tapped, isFalse);
      // 正向断言「为什么不可点」：回调根本没挂上，而不是靠某个手势竞技场
      // 恰好没抢到。
      final row = tester.widget<InkWell>(
        find
            .ancestor(of: find.text('播放诊断'), matching: find.byType(InkWell))
            .first,
      );
      expect(row.onTap, isNull);
      // 禁用态 = onSurfaceVariant @ 0.5（design/04 §5.6）。
      expect(
        tester.widget<Text>(find.text('播放诊断')).style?.color,
        darkScheme.onSurfaceVariant.withValues(alpha: 0.5),
      );
    });

    testWidgets('选中项用星等琥珀（design/04 §5.6）', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '速度',
                items: [
                  PlayerMenuItem(id: 'rate_1', label: '1.0×', selected: true),
                  PlayerMenuItem(id: 'rate_2', label: '1.5×'),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      await tester.tap(find.text('速度'));
      await tester.pumpAndSettle();
      final selected = tester.widget<Text>(find.text('1.0×'));
      final unselected = tester.widget<Text>(find.text('1.5×'));
      expect(selected.style?.color, isNot(unselected.style?.color));
      // 精确值：星等琥珀（`AppPalette.magnitude`，暗色主题下就是它）。
      expect(selected.style?.color, AppPalette.magnitude);
      expect(unselected.style?.color, darkScheme.onSurface);
      // 「必须显示已生效」（design/04 §5.6）：除了前景色，还有对勾标记。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-rate_1')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-rate_2')),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );
      // 恰好一个对勾：把每个项都打勾的实现也要红。
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('点击项执行回调（不自动关闭，由调用方决定）', (tester) async {
      var tapped = '';
      var dismissed = 0;
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: [
              PlayerMenuSection(
                title: '播放',
                items: [
                  PlayerMenuItem(
                    id: 'play',
                    label: '播放 / 暂停',
                    onSelect: () => tapped = 'play',
                  ),
                ],
              ),
            ],
            onDismiss: () => dismissed++,
          ),
        ),
      );
      // 分组现在是一行：「播放 / 暂停」在「播放」组的飞出列里，先点开分组。
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放 / 暂停'));
      await tester.pump();
      expect(tapped, 'play');
      // 关闭是调用方的事（`player_page.dart` 在 onSelect 里自己关）：
      // 菜单自己再关一次会把「打开子菜单/对话框不关闭」这条规则搞坏。
      expect(dismissed, 0);
    });

    testWidgets('菜单被约束在窗口内（design/04 §5.2）', (tester) async {
      await tester.pumpWidget(
        wrap(
          SizedBox(
            width: 1440,
            height: 900,
            child: Stack(
              children: [
                PlayerContextMenu(
                  anchor: const Offset(1430, 890),
                  viewport: const Size(1440, 900),
                  sections: const [
                    PlayerMenuSection(
                      title: '播放',
                      items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
                    ),
                  ],
                  onDismiss: () {},
                ),
              ],
            ),
          ),
        ),
      );
      // 断言落在**表面**上而不是 `PlayerContextMenu` 的整体矩形上：后者是
      // 飞出层的全窗口坐标底板（`Positioned.fill`），永远等于窗口大小，会让
      // 这条用例变成恒真。
      final rect = tester.getRect(menuSurface);
      expect(rect.right, lessThanOrEqualTo(1440));
      expect(rect.bottom, lessThanOrEqualTo(900));
    });

    testWidgets('无阴影、elevation 0（DESIGN.md The Zero-Elevation Rule）', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      for (final m in tester.widgetList<Material>(find.byType(Material))) {
        expect(m.elevation, 0);
      }
    });

    testWidgets('几何：左上角等于 clamp 后的锚点，宽度 240、项高 36（§5.2、§5.6）', (
      tester,
    ) async {
      // 画布要与菜单声明的 viewport 一致：行现在在分组飞出列里，要真的点到
      // 「播放」组就得让它在画布内（理由见 setSurface 的注释）。
      setSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(1430, 890),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [
                  PlayerMenuItem(id: 'play', label: '播放 / 暂停'),
                  PlayerMenuItem(id: 'next', label: '下一集'),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 左上角 = clampMenuOrigin 的结果（不是窗口左上角，也不是锚点原值）。
      // 这一条同时排除「铺一层 Positioned.fill 全屏遮罩」和「进 Overlay」两种
      // 实现：前者左上角是 (0,0)，后者根本不在这个坐标空间。
      expect(tester.getTopLeft(menuSurface), const Offset(1192, 472));
      expect(tester.getSize(menuSurface).width, 240);
      // 项高 36 只在行上量得到，而行现在都在分组飞出列里。
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      // 项高 36（design/04 §5.6）。
      expect(
        tester.getSize(find.byKey(const ValueKey('player-menu-item-play'))),
        const Size(240, 36),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('player-menu-item-next'))),
        const Size(240, 36),
      );
    });

    testWidgets('表面与发丝边：nightSurface3 @ 0.96 + 1px outlineVariant @ 0.72', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      final material = tester.widget<Material>(menuSurface);
      expect(material.elevation, 0);
      // 底色 design/04 §5.6：nightSurface3 @ 0.96。
      expect(material.color, AppPalette.nightSurface3.withValues(alpha: 0.96));
      final shape = material.shape! as RoundedRectangleBorder;
      // 圆角 = AppRadius.mdAll（10px）。
      expect(shape.borderRadius, AppRadius.mdAll);
      // 发丝边 1px 且是 outlineVariant @ 0.72（暗色下就是 nightLine）。
      // 断言的是 `shape` 而不是另包的 DecoratedBox：`Material` 用
      // `ShapeBorderClipper` 裁内容，边由同一套实现画出，1px 不会被裁掉半像素。
      expect(shape.side.width, 1.0);
      expect(shape.side.color, AppPalette.nightLine.withValues(alpha: 0.72));
      expect(material.shape, isNot(isA<StadiumBorder>()));
    });

    testWidgets('图标按 item.icon 渲染', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [
                  PlayerMenuItem(
                    id: 'play',
                    label: '播放 / 暂停',
                    icon: Icons.play_arrow,
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-play')),
          matching: find.byIcon(Icons.play_arrow),
        ),
        findsOneWidget,
      );
    });

    testWidgets('父项点击飞出子列、再点收起，且父项不发动作（design/04 §5.5）', (
      tester,
    ) async {
      var parentSelected = 0;
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: [
              PlayerMenuSection(
                title: '显示',
                items: [
                  PlayerMenuItem(
                    id: 'osd',
                    label: '屏显',
                    icon: Icons.tune,
                    onSelect: () => parentSelected++,
                    children: const [
                      PlayerMenuItem(id: 'osd_title', label: '标题', selected: true),
                      PlayerMenuItem(id: 'osd_clock', label: '时钟'),
                    ],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 「显示」组本身现在是第 1 列里的一行：先把它点开，才能看到组内项。
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();

      // 收起态：主列 + 「显示」组的一列，屏显的子项尚未渲染，方向指示朝右。
      expect(find.text('标题'), findsNothing);
      expect(find.text('时钟'), findsNothing);
      expect(columnSurfaces, findsNWidgets(2));
      // 主列 1 个（显示组）+ 组列里 1 个（屏显；「全屏」是叶子，没有箭头）。
      expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));

      await tester.tap(find.text('屏显'));
      await tester.pumpAndSettle();
      // 飞出态：子项在**新的一列**（独立的一列），不是缩进塞进主列。
      // 现在的列序：0 = 主列，1 = 「显示」组的列，2 = 屏显的子列。
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('时钟'), findsOneWidget);
      expect(columnSurfaces, findsNWidgets(3));
      final parent = columnRect(tester, 1);
      final flyout = columnRect(tester, 2);
      // 子列贴着父列右缘、顶边对齐父项所在行（行顶边 = 父列内的绝对坐标）。
      expect(flyout.left, greaterThanOrEqualTo(parent.right));
      expect(flyout.width, parent.width);
      expect(
        flyout.top,
        tester.getTopLeft(find.byKey(const ValueKey('player-menu-item-osd'))).dy,
      );
      // 子列整列落在父列之外：证明它是飞出的一列，而不是缩进塞进父列滚动区
      // （就地展开的实现里子项一定在父列矩形之内）。
      expect(
        parent.contains(flyout.topLeft),
        isFalse,
        reason: '子列必须飞出父列之外（parent=$parent flyout=$flyout）',
      );
      // 带子列的项本身不发动作，否则一次点击会同时「飞出」和「执行」。
      expect(parentSelected, 0);
      // 子项自己的选中态仍然可见（屏显开关状态要能读）。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-osd_title')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );

      // 再点一次收起：子列连同它的内容一起消失（「显示」组那一列还在，
      // 它只能靠点自己收起）。
      await tester.tap(find.text('屏显'));
      await tester.pumpAndSettle();
      expect(find.text('标题'), findsNothing);
      expect(columnSurfaces, findsNWidgets(2));
      expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
    });

    testWidgets('内容比可用空间高时：菜单压到可用高度并在内部滚动，不溢出窗口', (
      tester,
    ) async {
      // 20 个分组行 ≈ 728px，远超「锚点以下」的 492px——这是主列**可能**变得
      // 过高的形状（真实内容现在是 10 行，但分组数由调用方决定，本引擎不许
      // 依赖「恰好 10 个」）。用 420 的估值 clamp 之后如果不把高度压到左上角
      // 以下，菜单会伸到窗口外沿外且滚不到。
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(800, 600),
            sections: [
              for (var i = 0; i < 20; i++)
                PlayerMenuSection(
                  title: '分组 $i',
                  items: [PlayerMenuItem(id: 'info_$i', label: '项 $i')],
                ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      final rect = tester.getRect(menuSurface);
      expect(rect.top, 100);
      // 上限 = 视口高 - 左上角 - 留白 = 600 - 100 - 8。
      expect(rect.height, 492);
      expect(rect.bottom, lessThanOrEqualTo(600 - 8));
      // 超出部分真的可滚：内容高于视口。
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
    });

    testWidgets('窗口比 240 还窄时收窄菜单，右边缘仍留在留白内', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(150, 150),
            viewport: const Size(200, 200),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      final rect = tester.getRect(menuSurface);
      expect(rect.left, 8);
      expect(rect.width, 200 - 2 * 8);
      expect(rect.right, lessThanOrEqualTo(200 - 8));
      expect(rect.bottom, lessThanOrEqualTo(200 - 8));
    });
  });

  group('契约守卫（design/04 §4.1）', () {
    // 关键用例：**三级菜单可渲染**（飞出式多列的验收口径）。
    //
    // 为什么必须有这一条：就地展开的旧实现只渲染顶层项的孩子，第二层再带
    // children 就只画一个「点了没反应」的箭头——静默失效，最难发现的一类缺陷。
    // 飞出式实现里三层必须同时挂 key，任何一层断链本用例都会红。
    testWidgets('三级菜单可渲染：三层 player-menu-item-* key 同时存在', (tester) async {
      setSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '显示',
                items: [
                  PlayerMenuItem(
                    id: 'aspect',
                    label: '画面比例',
                    children: [
                      PlayerMenuItem(
                        id: 'aspect-16-9',
                        label: '16:9',
                        children: [
                          PlayerMenuItem(id: 'aspect-16-9-pillarbox', label: '信箱'),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 主列 → 分组列（显示）→ 画面比例列 → 16:9 列。
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('画面比例'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('16:9'));
      await tester.pumpAndSettle();

      expect(columnSurfaces, findsNWidgets(4));
      for (final id in [
        'aspect',
        'aspect-16-9',
        'aspect-16-9-pillarbox',
      ]) {
        expect(
          find.byKey(ValueKey('player-menu-item-$id')),
          findsOneWidget,
          reason: '第 $id 层必须真的渲染出可点的行，而不是一个点不动的箭头',
        );
      }
      // 四列互不重叠（第 3 列起会因右缘放不下而翻到左侧，所以不该断言
      // 「每列都在前一列右边」——那是两列时代的写法）。
      final columns = [for (var i = 0; i < 4; i++) columnRect(tester, i)];
      for (var i = 1; i < columns.length; i++) {
        expect(
          columns[i].overlaps(columns[i - 1]),
          isFalse,
          reason: '第 $i 列与上一列重叠了：${columns.map((c) => c.toString()).join(' / ')}',
        );
      }

      // 点更浅层的父项：它弹出的整条后代链一起关掉，不允许「多列同时开着
      // 但彼此不相关」。
      await tester.tap(find.text('画面比例'));
      await tester.pumpAndSettle();
      expect(columnSurfaces, findsNWidgets(2));
      expect(find.text('16:9'), findsNothing);
    });

    testWidgets('子列超出窗口右缘时翻到左侧，且不伸出窗口', (tester) async {
      setSurface(tester, const Size(1440, 900));
      // 近右沿的 anchor：主列被 clamp 到 1440-240-8 = 1192，右缘正好贴留白。
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(1430, 200),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '显示',
                items: [
                  PlayerMenuItem(
                    id: 'aspect',
                    label: '画面比例',
                    children: [PlayerMenuItem(id: 'aspect-16-9', label: '16:9')],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('画面比例'));
      await tester.pumpAndSettle();

      final main = columnRect(tester, 0);
      expect(main.right, lessThanOrEqualTo(1440 - 8));
      final flyout = columnRect(tester, 1);
      // 右侧放不下 → 翻到主列左侧；无论如何整列留在窗口留白内。
      expect(flyout.right, lessThanOrEqualTo(1440 - 8));
      expect(flyout.left, greaterThanOrEqualTo(8));
      expect(flyout.right, lessThanOrEqualTo(main.left));
    });

    testWidgets('子列竖直方向不伸出窗口下沿', (tester) async {
      // 主列贴窗口下沿（anchor 在最底部），父项在列表末尾：直接按「行顶边」
      // 放下方的子列一定会伸出下沿，必须上移。
      setSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 700),
            viewport: const Size(1440, 900),
            sections: [
              PlayerMenuSection(
                title: '显示',
                items: [
                  for (var i = 0; i < 3; i++)
                    PlayerMenuItem(id: 'filler_$i', label: '填充 $i'),
                  PlayerMenuItem(
                    id: 'aspect',
                    label: '画面比例',
                    children: [
                      for (var i = 0; i < 4; i++)
                        PlayerMenuItem(id: 'aspect_$i', label: '比例 $i'),
                    ],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('画面比例'));
      await tester.pumpAndSettle();

      final flyout = columnRect(tester, 1);
      expect(
        flyout.bottom,
        lessThanOrEqualTo(900 - 8),
        reason: '子列不得伸出窗口下沿（flyout=$flyout）',
      );
      // 不是靠把子列压成一条缝过关的：列里至少还剩 3 项的高度。
      expect(flyout.height, greaterThanOrEqualTo(36.0 * 3));
    });

    // 关键用例：**禁用不能抹掉选中态**（`DESIGN.md:373`）。
    //
    // 为什么必须有这一条：`DESIGN.md:373` 明确写着「禁用只降低强调，
    // **不能抹掉状态**」，并记录了一次真实用户反馈（把 `onTap == null`
    // 一律当静态标签，导致整排控件「长得一模一样且点不动」）。
    // 原实现把「选中 + 禁用」压成中性灰，琥珀完全消失。
    // 变异测试实测确认：改回中性灰，本用例会失败。
    testWidgets('选中且禁用时仍保留琥珀（只是压暗）', (tester) async {
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '倍速',
                items: [
                  PlayerMenuItem(
                    id: 'rate-1',
                    label: '1.0×',
                    selected: true,
                    enabled: false,
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      await tester.tap(find.text('倍速'));
      await tester.pumpAndSettle();
      final color = tester.widget<Text>(find.text('1.0×')).style?.color;
      expect(
        color,
        AppPalette.magnitude.withValues(alpha: 0.5),
        reason: '禁用时压暗琥珀，而不是换成中性灰（DESIGN.md:373）',
      );
      // 反向：不得等于中性灰——那正是被修掉的行为。
      expect(color, isNot(darkScheme.onSurfaceVariant.withValues(alpha: 0.5)));
    });
  });

  // 悬停驱动（PotPlayer 行为）：这组用例逐条钉住「只剩点击」与「立即收起」
  // 两种回退实现——见每条用例自己的说明。
  group('悬停展开（PotPlayer 行为）', () {
    testWidgets('悬停到带子列的项上即展开，不需要点击', (tester) async {
      setSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '显示',
                items: [
                  PlayerMenuItem(
                    id: 'osd',
                    label: '屏显',
                    children: [PlayerMenuItem(id: 'osd_title', label: '标题')],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      expect(columnSurfaces, findsOneWidget);

      // 「显示」组自己就带 `▸`：一次纯 hover 就把它飞出来（分组行复用同一套
      // 悬停机制，没有另写）。这一步顺带就是「分组行能悬停展开」的证据。
      final mouse = await mousePointer(tester);
      expect(columnSurfaces, findsOneWidget);
      await mouse.moveTo(tester.getCenter(find.text('显示')));
      await tester.pumpAndSettle();
      expect(
        columnSurfaces,
        findsNWidgets(2),
        reason: '悬停分组行必须飞出该组的项，不点击也要飞出',
      );

      // 组内带子列的行同样只靠 hover 展开。
      await mouse.moveTo(tester.getCenter(find.text('屏显')));
      await tester.pumpAndSettle();

      // 抓的错误实现：只保留点击路径（hover 不展开）→ 这里仍是 2 列。
      expect(
        columnSurfaces,
        findsNWidgets(3),
        reason: '悬停必须展开子列，不点击也要飞出',
      );
      expect(find.text('标题'), findsOneWidget);
      // 悬停不触发父项的动作（和点击路径同一条规则）。
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-menu-item-osd')),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );
    });

    testWidgets('悬停到叶子项上不展开任何列', (tester) async {
      setSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '播放',
                items: [PlayerMenuItem(id: 'play', label: '播放 / 暂停')],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 「播放 / 暂停」是「播放」组里的叶子：先点开分组才看得到它。
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(columnSurfaces, findsNWidgets(2));

      final mouse = await mousePointer(tester);
      await mouse.moveTo(tester.getCenter(find.text('播放 / 暂停')));
      await tester.pumpAndSettle();
      // 抓的错误实现：给叶子行也挂展开逻辑（例如对 children 为空的行照样
      // 往 _openIds 里塞 id），会在 _visibleLevels 里断链或凭空多一列。
      expect(columnSurfaces, findsNWidgets(2));
    });

    testWidgets('悬停到同列另一个父项：旧的子列消失，只留下一条展开链', (tester) async {
      setSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '显示',
                items: [
                  PlayerMenuItem(
                    id: 'osd',
                    label: '屏显',
                    children: [PlayerMenuItem(id: 'osd_title', label: '标题')],
                  ),
                  PlayerMenuItem(
                    id: 'aspect',
                    label: '画面比例',
                    children: [PlayerMenuItem(id: 'aspect_16_9', label: '16:9')],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // 先点开「显示」组（悬停组也会展开，但那正是下面一条用例的对象）。
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      final mouse = await mousePointer(tester);
      await mouse.moveTo(tester.getCenter(find.text('屏显')));
      await tester.pumpAndSettle();
      expect(find.text('标题'), findsOneWidget);

      await mouse.moveTo(tester.getCenter(find.text('画面比例')));
      await tester.pumpAndSettle();

      // 抓的错误实现：同层换支时不砍旧分支 → 这里会是 4 列、两列子菜单同时在。
      expect(columnSurfaces, findsNWidgets(3));
      expect(find.text('标题'), findsNothing);
      expect(find.text('16:9'), findsOneWidget);
    });

    testWidgets('斜向容错：离开父项到空白区、延迟内进入子列，子列仍然在', (tester) async {
      setSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '显示',
                items: [
                  PlayerMenuItem(
                    id: 'osd',
                    label: '屏显',
                    children: [PlayerMenuItem(id: 'osd_title', label: '标题')],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      final mouse = await mousePointer(tester);
      await mouse.moveTo(tester.getCenter(find.text('屏显')));
      await tester.pumpAndSettle();
      expect(columnSurfaces, findsNWidgets(3));

      // 离开父项，落到「不属于任何列」的空白区（主列右缘之外、子列顶边之上）。
      final main = columnRect(tester, 1);
      final flyout = columnRect(tester, 2);
      final gap = Offset(flyout.left + 4, main.top - 20);
      // 自检：「空白区」真的不在任何列里，否则这条用例测的就不是斜穿间隙。
      expect(main.contains(gap), isFalse);
      expect(flyout.contains(gap), isFalse);
      await mouse.moveTo(gap);
      // 只推进一半的延迟：**逐帧**推进而不是一次 pump 到底——一次性 pump
      // 到 delay 之后，立即收起的实现也会「碰巧通过」。
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        columnSurfaces,
        findsNWidgets(3),
        reason: '离开父项只应排一次延迟收起，不能立刻收',
      );

      // 延迟未到，指针已经进入子列。
      // 抓的错误实现：**立即收起**（没有延迟）→ 上一行就已经红了；
      // 只加延迟但不在进入列时取消计时器 → 这一行之后仍然会红。
      await mouse.moveTo(tester.getCenter(find.text('标题')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        columnSurfaces,
        findsNWidgets(3),
        reason: '指针已经进到子列里，父层不得把它收掉',
      );
      expect(find.text('标题'), findsOneWidget);
    });

    testWidgets('延迟过后才收起：移到空白区并等过延迟，子列消失', (tester) async {
      setSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: const [
              PlayerMenuSection(
                title: '显示',
                items: [
                  PlayerMenuItem(
                    id: 'osd',
                    label: '屏显',
                    children: [PlayerMenuItem(id: 'osd_title', label: '标题')],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      final mouse = await mousePointer(tester);
      await mouse.moveTo(tester.getCenter(find.text('屏显')));
      await tester.pumpAndSettle();
      expect(columnSurfaces, findsNWidgets(3));

      await mouse.moveTo(blankSpot);
      // 抓的错误实现：排了计时器却永不触发（或延迟长到没有意义）。
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      // 屏显那一列（第 3 列）被收掉；「显示」组那一列是点开的，点击是唯一的
      // 收起手段，所以它仍在。
      expect(columnSurfaces, findsNWidgets(2));
      expect(find.text('标题'), findsNothing);
    });

    testWidgets('点击路径不被悬停抢走：不 hover，直接点父项展开 / 再点收起', (tester) async {
      setSurface(tester, const Size(1440, 900));
      var parentSelected = 0;
      await tester.pumpWidget(
        wrap(
          PlayerContextMenu(
            anchor: const Offset(100, 100),
            viewport: const Size(1440, 900),
            sections: [
              PlayerMenuSection(
                title: '显示',
                items: [
                  PlayerMenuItem(
                    id: 'osd',
                    label: '屏显',
                    onSelect: () => parentSelected++,
                    children: const [
                      PlayerMenuItem(id: 'osd_title', label: '标题'),
                    ],
                  ),
                ],
              ),
            ],
            onDismiss: () {},
          ),
        ),
      );
      // `tester.tap` 不产生 hover：它是一次 touch 式的按下/抬起。
      await tester.tap(find.text('显示'));
      await tester.pumpAndSettle();
      expect(columnSurfaces, findsNWidgets(2));

      await tester.tap(find.text('屏显'));
      await tester.pumpAndSettle();
      expect(columnSurfaces, findsNWidgets(3));
      expect(parentSelected, 0);

      await tester.tap(find.text('屏显'));
      await tester.pumpAndSettle();
      expect(columnSurfaces, findsNWidgets(2));
    });
  });
}
