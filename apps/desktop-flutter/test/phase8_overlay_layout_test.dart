import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/ui/player_overlay.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

/// 测试视口固定 800×600（`flutter_test` 默认），下文的所有几何断言都按它算。
const Size viewport = Size(800, 600);

Widget wrap(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(body: child),
);

/// 三段都给可分辨的固定高度，便于断言位置。
PlayerControlOverlay buildOverlay({
  Widget? topBar,
  Widget progressRow = const SizedBox(height: 32, key: ValueKey('progress')),
  List<Widget> actionButtons = const [
    SizedBox(width: 48, height: 40, key: ValueKey('action')),
  ],
  List<PlayerButtonGroup> actionGroups = const [PlayerButtonGroup.transport],
}) => PlayerControlOverlay(
  topBar: topBar ?? const SizedBox(height: 56, key: ValueKey('top')),
  progressRow: progressRow,
  actionButtons: actionButtons,
  actionGroups: actionGroups,
);

/// 取一条纱的渐变，用于断言颜色与朝向。
LinearGradient gradientOf(WidgetTester tester, Finder scrim) {
  final decoration =
      tester
              .widget<DecoratedBox>(
                find
                    .descendant(of: scrim, matching: find.byType(DecoratedBox))
                    .first,
              )
              .decoration
          as BoxDecoration;
  return decoration.gradient! as LinearGradient;
}

void main() {
  group('浮层不参与布局', () {
    testWidgets('视频区占满 body，浮层自身也恰好是 body 尺寸', (tester) async {
      await tester.pumpWidget(
        wrap(
          Stack(
            children: [
              Positioned.fill(
                child: Container(key: const ValueKey('video'), color: Colors.red),
              ),
              Positioned.fill(child: buildOverlay()),
            ],
          ),
        ),
      );
      final video = tester.getRect(find.byKey(const ValueKey('video')));
      expect(video, Rect.fromLTWH(0, 0, viewport.width, viewport.height), reason: '视频区必须占满整个 body');

      // 正向断言：浮层不是"按内容高度自适应"的盒子，它就是 body 那么大。
      final overlay = tester.getRect(find.byType(PlayerControlOverlay));
      expect(overlay, Rect.fromLTWH(0, 0, viewport.width, viewport.height), reason: '浮层应吃掉 body 的全部约束');
    });

    testWidgets('内容再高也不改变视频区：视频矩形与浮层内容无关', (tester) async {
      // 顶栏 400 + 动作行 400 远超 body 高度。
      //
      // 注意本用例的**真实检出力**：视频是 `Positioned.fill`，
      // 所以**任何**浮层实现下它都是 800×600——单看视频矩形这条断言没有区分力。
      // 真正有区分力的是下面两条：
      // (1) `takeException()` 为 null：浮层若被塞进 `Column`/`Row`，
      //     400+400 的贴边子项会在 800×600 里触发 `RenderFlex` 溢出；
      // (2) **浮层自身**矩形仍是 800×600：内容自适应实现在这里会缩成内容高度。
      await tester.pumpWidget(
        wrap(
          Stack(
            children: [
              Positioned.fill(
                child: Container(key: const ValueKey('video'), color: Colors.red),
              ),
              Positioned.fill(
                child: buildOverlay(
                  topBar: const SizedBox(height: 400, key: ValueKey('top')),
                  actionButtons: const [
                    SizedBox(height: 400, key: ValueKey('action')),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: '贴边子项重叠不得溢出报错');
      expect(
        tester.getRect(find.byKey(const ValueKey('video'))),
        Rect.fromLTWH(0, 0, viewport.width, viewport.height),
        reason: '浮层内容高度不得影响视频区',
      );
      // (2) 浮层自身也必须撑满——这一条才真正区分「撑满」与「按内容自适应」。
      expect(
        tester.getRect(find.byType(PlayerControlOverlay)),
        Rect.fromLTWH(0, 0, viewport.width, viewport.height),
        reason: '浮层自身必须撑满 body，不得按内容自适应',
      );
    });

    testWidgets('松散约束下仍撑满：不按内容高度自适应（Center 包一层）', (tester) async {
      // Center 给的是松散约束。Stack 只含 Positioned 子项 → 取 constraints.biggest，
      // 于是浮层仍是 800×600、顶栏贴 0、动作行贴底。
      // 按内容高度自适应（Column mainAxisSize.min 一类）的实现在这里会被 Center
      // 垂直居中 → 顶栏 top 变成 (600-内容高)/2 ≈ 230，本条即失败。
      await tester.pumpWidget(wrap(Center(child: buildOverlay())));

      expect(
        tester.getRect(find.byType(PlayerControlOverlay)),
        Rect.fromLTWH(0, 0, viewport.width, viewport.height),
        reason: '浮层必须撑满可用空间，而不是围着自己的内容',
      );
      expect(tester.getRect(find.byKey(const ValueKey('top'))).top, 0);
      expect(tester.getRect(find.byKey(const ValueKey('action'))).bottom, 592);
    });
  });

  group('三段几何', () {
    testWidgets('顶栏贴顶、进度行与动作行贴底，逐段精确', (tester) async {
      await tester.pumpWidget(wrap(buildOverlay()));

      // 顶栏：贴顶、通栏。
      expect(
        tester.getRect(find.byKey(const ValueKey('top'))),
        const Rect.fromLTWH(0, 0, 800, 56),
        reason: '顶栏贴顶且通栏',
      );

      // 底栏内边距：horizontal AppSpace.md=12，vertical AppSpace.sm=8。
      // 于是进度行 (12,516,776,32)、动作行 (12,552,776,40)、动作行下沿 592。
      expect(
        tester.getRect(find.byKey(const ValueKey('progress'))),
        const Rect.fromLTWH(AppSpace.md, 516, 800 - AppSpace.md * 2, 32),
        reason: '进度行在动作行之上，左右留 AppSpace.md，且被拉满宽度',
      );
      // 动作行**盒子**仍是通栏的：它自己占满 (12..788)。
      // 靠底部 `Column` 的默认 center 做不到这一点——那样盒子会缩成内容宽，
      // 溢出时连滚动视口都不存在。所以盒子通栏、**内容**居中，两件事分开。
      expect(
        tester.getRect(find.byType(PlayerOverlayActionRow)),
        const Rect.fromLTWH(AppSpace.md, 552, 800 - AppSpace.md * 2, 40),
        reason: '动作行盒子通栏且单行（内容居中不改变盒子宽度）',
      );
      // 内容居中：单个 48 宽按钮在 776 宽里居中 → 12 + (776 - 48) / 2 = 376。
      expect(
        tester.getRect(find.byKey(const ValueKey('action'))),
        const Rect.fromLTWH(376, 552, 48, 40),
        reason: '动作行内容居中：12 + (776-48)/2 = 376',
      );
      expect(
        600 - tester.getRect(find.byType(PlayerOverlayActionRow)).bottom,
        AppSpace.sm,
        reason: '动作行距底边恰为 AppSpace.sm（不是贴死 0，也不是别的散值）',
      );

      // 进度行与动作行之间是 AppSpace.xs 的缝。
      expect(
        tester.getRect(find.byKey(const ValueKey('action'))).top -
            tester.getRect(find.byKey(const ValueKey('progress'))).bottom,
        AppSpace.xs,
        reason: '进度行与动作行之间留 AppSpace.xs',
      );
    });

    testWidgets('顶栏保留 AppBar 类型，「更多」仍在 AppBar 内', (tester) async {
      // integration_test/ui_redesign_visual_flow_test.dart:677-681 用
      // find.descendant(of: find.byType(AppBar), matching: find.byTooltip('更多'))
      // 断言顶栏按钮位置。浮层必须原样承载调用方给的 AppBar，不得替换成自绘 Row。
      await tester.pumpWidget(
        wrap(
          buildOverlay(
            topBar: AppBar(
              title: const Text('片名 · 第 1 集'),
              actions: [
                IconButton(tooltip: '字幕轨', onPressed: () {}, icon: const Icon(Icons.subtitles)),
                IconButton(tooltip: '弹幕（开启）', onPressed: () {}, icon: const Icon(Icons.forum)),
                IconButton(tooltip: '全屏（F11）', onPressed: () {}, icon: const Icon(Icons.fullscreen)),
                IconButton(tooltip: '更多', onPressed: () {}, icon: const Icon(Icons.more_vert)),
              ],
            ),
          ),
        ),
      );

      expect(find.byType(AppBar), findsOneWidget);
      for (final tooltip in ['字幕轨', '弹幕（开启）', '全屏（F11）', '更多']) {
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byTooltip(tooltip),
          ),
          findsOneWidget,
          reason: '「$tooltip」必须仍在 AppBar 内',
        );
      }
      expect(
        tester.getRect(find.byType(AppBar)),
        const Rect.fromLTWH(0, 0, 800, 56),
        reason: 'AppBar 贴顶、通栏、高 56',
      );
    });
  });

  group('渐变纱（design/01 §4.3）', () {
    testWidgets('两条纱：位置、朝向、不透明度、颜色都精确', (tester) async {
      await tester.pumpWidget(wrap(buildOverlay()));
      final scrims = find.byType(PlayerOverlayScrim);
      expect(scrims, findsNWidgets(2), reason: '顶栏一条 + 底栏一条');

      // 顶栏纱：贴顶、高 120、从上往下渐隐、最浓处 0.72。
      expect(tester.getRect(scrims.at(0)), const Rect.fromLTWH(0, 0, 800, 120));
      final top = tester.widget<PlayerOverlayScrim>(scrims.at(0));
      expect(top.opacity, 0.72);
      expect(top.alignment, Alignment.topCenter);
      final topGradient = gradientOf(tester, scrims.at(0));
      expect(topGradient.begin, Alignment.topCenter);
      expect(topGradient.end, Alignment.bottomCenter, reason: '顶栏纱向下渐隐');
      expect(topGradient.colors, [
        AppPalette.nightGround.withValues(alpha: 0.72),
        AppPalette.nightGround.withValues(alpha: 0),
      ]);

      // 底栏纱：贴底、高 160、从下往上渐隐、最浓处 0.86（更高对比度）。
      expect(tester.getRect(scrims.at(1)), const Rect.fromLTWH(0, 440, 800, 160));
      final bottom = tester.widget<PlayerOverlayScrim>(scrims.at(1));
      expect(bottom.opacity, 0.86);
      expect(bottom.alignment, Alignment.bottomCenter);
      final bottomGradient = gradientOf(tester, scrims.at(1));
      expect(bottomGradient.begin, Alignment.bottomCenter);
      expect(bottomGradient.end, Alignment.topCenter, reason: '底栏纱向上渐隐');
      expect(bottomGradient.colors, [
        AppPalette.nightGround.withValues(alpha: 0.86),
        AppPalette.nightGround.withValues(alpha: 0),
      ]);
    });
  });

  group('命中测试', () {
    testWidgets('画面中部与纱覆盖区都能点到画面；浮层内的按钮仍可点', (tester) async {
      var videoTaps = 0;
      var buttonTaps = 0;
      await tester.pumpWidget(
        wrap(
          Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => videoTaps++,
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned.fill(
                child: buildOverlay(
                  actionButtons: [
                    SizedBox(
                      width: 48,
                      height: 40,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => buttonTaps++,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

      // 画面正中被浮层"覆盖"，但浮层中间必须是空的、纱也不吃指针。
      await tester.tapAt(const Offset(400, 300));
      expect(videoTaps, 1, reason: '浮层中部不得吃掉画面的点击');

      // 顶栏纱（0..120）之下、顶栏（0..56）之外的区域同样要穿透。
      await tester.tapAt(const Offset(400, 100));
      expect(videoTaps, 2, reason: '纱不得吃掉画面的点击');

      // 反过来：浮层自己的按钮必须能点到（浮层没有被整体 IgnorePointer）。
      // 单个 48 宽按钮现在居中：左端 376，中心 376 + 24。
      await tester.tapAt(const Offset(376 + 24, 552 + 20));
      expect(buttonTaps, 1, reason: '动作行按钮必须可点');
      expect(videoTaps, 2, reason: '按钮吃掉点击，画布不应再收到');
    });
  });

  group('分组分隔线（design/03 §5.1）', () {
    testWidgets('分组边界插入分隔线：数量、位置、尺寸与颜色精确', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildOverlay(
            actionButtons: const [
              SizedBox(width: 48, height: 40),
              SizedBox(width: 48, height: 40),
              SizedBox(width: 48, height: 40),
            ],
            actionGroups: const [
              PlayerButtonGroup.transport,
              PlayerButtonGroup.transport,
              PlayerButtonGroup.volume,
            ],
          ),
        ),
      );

      expect(find.byType(PlayerOverlayDivider), findsOneWidget);
      // 位置：插在第 2 与第 3 个按钮之间（不是开头、不是结尾）。
      // 内容居中：48*3 + 9 = 153 宽，左端 = 12 + (776 - 153) / 2 = 323.5，
      // 于是分隔线槽 323.5 + 96 = 419.5..428.5（4 + 1 + 4）。
      // 竖向：按钮 40 高、线 20 高，`Row` 的 crossAxisAlignment 是 center
      // → 线居中在 562..582。
      final divider = find.byType(PlayerOverlayDivider);
      expect(tester.getRect(divider), const Rect.fromLTWH(419.5, 562, 9, 20));

      // 尺寸与颜色：1px 宽、20px 高、由主题的 outline 角色染出。
      final line = find.descendant(of: divider, matching: find.byType(Container));
      expect(
        tester.getRect(line),
        const Rect.fromLTWH(423.5, 562, 1, 20),
        reason: '发丝线必须是 1×20 的实心线（尺寸为 0 等于没画）',
      );
      expect(
        tester.widget<Container>(line).color,
        buildAppTheme(Brightness.dark).colorScheme.outline,
        reason: '线的颜色取主题 outline 角色（不是 dividerColor，见实现注释的对比度）',
      );
    });

    testWidgets('单分组时不插分隔线', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildOverlay(
            actionButtons: const [
              SizedBox(width: 48, height: 40, key: ValueKey('b0')),
              SizedBox(width: 48, height: 40, key: ValueKey('b1')),
            ],
            actionGroups: const [
              PlayerButtonGroup.transport,
              PlayerButtonGroup.transport,
            ],
          ),
        ),
      );
      expect(find.byType(PlayerOverlayDivider), findsNothing);
      // 相邻两个按钮之间没有槽位：第二个按钮紧贴第一个。
      // 总宽 96，居中 → 左端 = 12 + (776 - 96) / 2 = 352。
      expect(tester.getRect(find.byKey(const ValueKey('b0'))).left, 352);
      expect(
        tester.getRect(find.byKey(const ValueKey('b1'))).left,
        352 + 48,
        reason: '无分隔线时按钮直接相邻（间距恰为一个按钮宽）',
      );
    });

    testWidgets('分隔线数 = 分组数 - 1（4 组 7 键 → 3 条）', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildOverlay(
            actionButtons: const [
              SizedBox(width: 48, height: 40),
              SizedBox(width: 48, height: 40),
              SizedBox(width: 48, height: 40),
              SizedBox(width: 48, height: 40),
              SizedBox(width: 48, height: 40),
              SizedBox(width: 48, height: 40),
              SizedBox(width: 48, height: 40),
            ],
            actionGroups: const [
              PlayerButtonGroup.transport,
              PlayerButtonGroup.transport,
              PlayerButtonGroup.volume,
              PlayerButtonGroup.rate,
              PlayerButtonGroup.rate,
              PlayerButtonGroup.rate,
              PlayerButtonGroup.display,
            ],
          ),
        ),
      );
      expect(find.byType(PlayerOverlayDivider), findsNWidgets(3));
      // 逐条钉住槽位。内容宽 = 48*7 + 9*3 = 363，居中左端 = 12 + (776-363)/2 = 218.5；
      // 于是 218.5 + 48*2 = 314.5；再 9 + 48 = 371.5；再 9 + 48*3 = 524.5。
      // 注意：`const PlayerOverlayDivider()` 被规范化成同一个实例，所以按 element 取
      // renderObject 的坐标，不能按 widget 反查。
      final xs = [
        for (final element in find.byType(PlayerOverlayDivider).evaluate())
          (element.renderObject! as RenderBox)
              .localToGlobal(Offset.zero)
              .dx,
      ];
      expect(xs, [314.5, 371.5, 524.5], reason: '分隔线必须落在每个分组边界上（随居中整体平移）');
    });
  });

  group('动作行单行溢出滚动（design/03 §5.4）', () {
    testWidgets('20 个宽按钮仍单行、不溢出，且是横向 SingleChildScrollView', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildOverlay(
            actionButtons: [
              for (var i = 0; i < 20; i++)
                const SizedBox(width: 120, height: 40),
            ],
            actionGroups: [
              for (var i = 0; i < 20; i++) PlayerButtonGroup.transport,
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull, reason: '不得溢出');
      expect(
        tester.getRect(find.byType(PlayerOverlayActionRow)).height,
        40,
        reason: '必须单行：高度恰为按钮高度，不因换行变高',
      );

      final scroll = tester.widget<SingleChildScrollView>(
        find
            .descendant(
              of: find.byType(PlayerOverlayActionRow),
              matching: find.byType(SingleChildScrollView),
            )
            .first,
      );
      expect(scroll.scrollDirection, Axis.horizontal, reason: '溢出后靠横向滚动，不换行');
      expect(
        find.descendant(
          of: find.byType(PlayerOverlayActionRow),
          matching: find.byType(Row),
        ),
        findsOneWidget,
        reason: '单行 + Row；Wrap 会变高',
      );
    });

    testWidgets('溢出部分能滚进视口（不是被裁掉就完事）', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildOverlay(
            actionButtons: [
              for (var i = 0; i < 19; i++)
                const SizedBox(width: 120, height: 40),
              const SizedBox(width: 120, height: 40, key: ValueKey('last')),
            ],
            actionGroups: [
              for (var i = 0; i < 20; i++) PlayerButtonGroup.transport,
            ],
          ),
        ),
      );
      const lastKey = ValueKey('last');

      // 未滚动时最后一个是屏幕外的——「不可达」是缺陷，要被下面这一步区分出来。
      expect(tester.getRect(find.byKey(lastKey)).left, greaterThan(800));

      await tester.drag(find.byType(PlayerOverlayActionRow), const Offset(-2000, 0));
      await tester.pumpAndSettle();

      final last = tester.getRect(find.byKey(lastKey));
      expect(
        last.right,
        closeTo(800 - AppSpace.md, 0.5),
        reason: '滚到底时最后一个按钮的右缘应贴住内容右界',
      );
      expect(last.left, lessThan(800), reason: '最后一项必须能进入视口');
    });

    testWidgets('内容溢出时退回左对齐（居中只在装得下时成立）', (tester) async {
      // 居中是由 `ConstrainedBox(minWidth: 通栏宽)` + `Row(center)` 共同得到的：
      // 装不下时内容盒比通栏宽更宽，`Row` 分到的剩余空间为 0（`RenderFlex`
      // 用 `math.max(0, freeSpace)` 钳过），内容自然从左侧排起。
      //
      // 这条用例是那个分支的唯一证据：把实现换成「无条件 Center 包一层」时，
      // 溢出的内容会被推到负坐标，第一个按钮的 left 就不再是 12。
      await tester.pumpWidget(
        wrap(
          buildOverlay(
            actionButtons: [
              for (var i = 0; i < 20; i++)
                SizedBox(
                  width: 120,
                  height: 40,
                  key: ValueKey('ov$i'),
                ),
            ],
            actionGroups: [
              for (var i = 0; i < 20; i++) PlayerButtonGroup.transport,
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: '不得溢出报错');
      expect(
        tester.getRect(find.byKey(const ValueKey('ov0'))).left,
        AppSpace.md,
        reason: '装不下时从左侧排起：第一个按钮贴内容左缘',
      );

      // 而且真的能拖动（可滚动范围 = 内容宽 − 视口宽 = 2400 − 776）。
      await tester.drag(
        find.byType(PlayerOverlayActionRow),
        const Offset(-2000, 0),
      );
      await tester.pumpAndSettle();
      final lastRect = tester.getRect(find.byKey(const ValueKey('ov19')));
      expect(
        lastRect.right,
        closeTo(800 - AppSpace.md, 0.5),
        reason: '拖动后最后一项贴住内容右界',
      );
    });
  });

  group('平坦场（DESIGN.md The Flat-Field Rule / design/05 §4 G9）', () {
    testWidgets('无阴影、无 elevation：任何 Material / 装饰盒都不例外', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildOverlay(
            actionButtons: const [
              SizedBox(width: 48, height: 40),
              SizedBox(width: 48, height: 40),
            ],
            actionGroups: const [
              PlayerButtonGroup.transport,
              PlayerButtonGroup.volume,
            ],
          ),
        ),
      );

      for (final material in tester.widgetList<Material>(find.byType(Material))) {
        expect(material.elevation, 0, reason: 'elevation 必须为 0');
      }
      expect(find.byType(Card), findsNothing);
      // `Material` 内部就是 `PhysicalModel`，所以不能要求它不存在——要求 elevation 为 0。
      for (final model in tester.widgetList<PhysicalModel>(
        find.byType(PhysicalModel),
      )) {
        expect(model.elevation, 0, reason: 'PhysicalModel 的 elevation 必须为 0');
      }

      // 阴影可以藏在任何 BoxDecoration 里（Container 的 decoration 也会落到
      // DecoratedBox），所以扫装饰盒而不是只扫 Material。
      final decorations = <BoxDecoration>[];
      for (final element in find.byType(DecoratedBox).evaluate()) {
        final decoration = (element.widget as DecoratedBox).decoration;
        if (decoration is BoxDecoration) decorations.add(decoration);
      }
      // 至少扫到了两条纱，断言才不是空转。
      expect(
        decorations.where((d) => d.gradient != null).length,
        2,
        reason: '两条纱的渐变必须在扫描范围内',
      );
      for (final decoration in decorations) {
        expect(decoration.boxShadow, isNull, reason: 'BoxDecoration 不得带 boxShadow');
      }
      // 文字描边（DESIGN.md 明确允许的那一类）不是盒子阴影；
      // 上面扫 `boxShadow` 已经覆盖全部「浮层自己画的投影」。
    });
  });

  group('契约守卫', () {
    testWidgets('actionButtons 与 actionGroups 数量不等时在 build 期断言失败', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildOverlay(
            actionButtons: const [
              SizedBox(width: 48, height: 40),
              SizedBox(width: 48, height: 40),
            ],
            actionGroups: const [PlayerButtonGroup.transport],
          ),
        ),
      );
      expect(
        tester.takeException(),
        isA<AssertionError>(),
        reason: '长度不一致是编程错误：必须显式失败，而不是静默少画一条分隔线',
      );
    });
  });
}
