import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/osd_diagnostics.dart';
import 'package:webhtv_pc/ui/player_osd.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tokens.dart';

Widget wrap(Widget child) => MaterialApp(
  theme: buildAppTheme(Brightness.dark),
  home: Scaffold(body: Stack(children: [child])),
);

PlayerOsdLayer buildLayer({
  Map<String, bool>? flags,
  bool controlsVisible = false,
  bool isLive = false,
  Duration duration = const Duration(minutes: 10),
  Duration position = const Duration(minutes: 2, seconds: 56),
  String? resolution = '3840×2160',
  double? bytesPerSecond,
  List<OsdDiagnosticsRow> diagnostics = const [],
  List<OsdDiagnosticsRow> environment = const [],
}) => PlayerOsdLayer(
  flags: flags ?? defaultOsdFlags(),
  controlsVisible: controlsVisible,
  title: '示例剧集 · E3',
  resolution: resolution,
  position: position,
  duration: duration,
  isLive: isLive,
  now: DateTime(2026, 10, 18, 20, 30, 18),
  bytesPerSecond: bytesPerSecond,
  diagnostics: diagnostics,
  environment: environment,
);

/// 断言「整层没有渲染任何文本」——直接数 `Text`，不猜具体串。
void expectNoTextInsideLayer(WidgetTester tester) {
  expect(
    find.descendant(
      of: find.byType(PlayerOsdLayer),
      matching: find.byType(Text),
    ),
    findsNothing,
    reason: '屏显全关时层内不得残留任何文本',
  );
}

void main() {
  testWidgets('默认开关：显示标题/分辨率/时钟/进度（design/02 §5.1）', (tester) async {
    await tester.pumpWidget(wrap(buildLayer()));
    // 标题与分辨率是同一个 Text 的两行（§3.1「换行」）——断言整串，不是子串。
    expect(find.text('示例剧集 · E3\n3840×2160'), findsOneWidget);
    expect(find.text('20:30:18'), findsOneWidget);
    // 断言精确串：任一格式化分支写错（例如恒输出 mm:ss）都会失败。
    expect(find.text('02:56 / 10:00'), findsOneWidget);
  });

  testWidgets('时长跨小时时段格式为 H:MM:SS（不是 123:04）', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(
          duration: const Duration(hours: 2, minutes: 3, seconds: 4),
        ),
      ),
    );
    expect(find.text('02:56 / 2:03:04'), findsOneWidget);
  });

  testWidgets('分辨率未知时只显示标题一行（design/02 §3.1）', (tester) async {
    await tester.pumpWidget(wrap(buildLayer(resolution: null)));
    expect(find.text('示例剧集 · E3'), findsOneWidget);
    expect(find.textContaining('3840×2160'), findsNothing);
  });

  testWidgets('默认关闭的项不渲染', (tester) async {
    // 行数据照给：否则「诊断面板没渲染」与「没数据」不可区分，断言必然成立。
    await tester.pumpWidget(
      wrap(
        buildLayer(
          diagnostics: const [OsdDiagnosticsRow('视频', 'hevc 3840×2160')],
          environment: const [OsdDiagnosticsRow('运行环境', 'Windows 11')],
        ),
      ),
    );
    expect(find.byType(PlayerOsdMiniProgress), findsNothing);
    expect(find.text('视频'), findsNothing, reason: '诊断面板默认关');
    expect(find.textContaining('hevc'), findsNothing, reason: '诊断面板默认关');
    expect(find.text('运行环境'), findsNothing, reason: '附加列同属诊断面板');
  });

  testWidgets('控制栏可见时：只强制时钟，进度被强制隐藏（design/02 §4.2）', (tester) async {
    await tester.pumpWidget(wrap(buildLayer(controlsVisible: true)));
    expect(find.text('20:30:18'), findsOneWidget, reason: '时钟强制显示');
    expect(find.textContaining('02:56'), findsNothing, reason: '进度强制隐藏');
    // PC 端的有意差异：控制栏可见时**不**强制显示标题（顶栏已有）。
    expect(find.textContaining('示例剧集'), findsNothing, reason: '标题不强制显示');
  });

  testWidgets('控制栏可见时诊断面板与迷你条强制隐藏', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(
          controlsVisible: true,
          flags: {
            ...defaultOsdFlags(),
            OsdFlag.diagnostics: true,
            OsdFlag.mini: true,
          },
          diagnostics: const [OsdDiagnosticsRow('视频', 'hevc 3840×2160')],
          environment: const [OsdDiagnosticsRow('运行环境', 'Windows 11')],
        ),
      ),
    );
    expect(find.text('视频'), findsNothing);
    expect(find.text('运行环境'), findsNothing);
    expect(find.byType(PlayerOsdMiniProgress), findsNothing);
  });

  testWidgets('全关时整层不渲染任何文本', (tester) async {
    final all = {for (final id in OsdFlag.values) id: false};
    await tester.pumpWidget(wrap(buildLayer(flags: all)));
    expect(find.byType(PlayerOsdLayer), findsOneWidget);
    expectNoTextInsideLayer(tester);
    expect(find.text('20:30:18'), findsNothing);
  });

  testWidgets('全关但控制栏可见时仍显示时钟（design/02 §4.3）', (tester) async {
    final all = {for (final id in OsdFlag.values) id: false};
    await tester.pumpWidget(
      wrap(buildLayer(flags: all, controlsVisible: true)),
    );
    expect(find.text('20:30:18'), findsOneWidget);
    // 除时钟外仍然什么都不画。
    expect(find.textContaining('示例剧集'), findsNothing);
    expect(find.byType(PlayerOsdMiniProgress), findsNothing);
  });

  testWidgets('直播时隐藏进度与迷你条（时长已知也不显示，design/02 §3.1/§3.3）', (tester) async {
    // 关键：duration 是**已知的 10 分钟**。若实现漏了 `!isLive` 只判 `duration > 0`，
    // 这条会失败——用 duration: 0 测直播区分不了这两个分支。
    await tester.pumpWidget(
      wrap(
        buildLayer(
          isLive: true,
          flags: {...defaultOsdFlags(), OsdFlag.mini: true},
        ),
      ),
    );
    expect(find.textContaining('02:56'), findsNothing, reason: '直播无进度');
    expect(find.byType(PlayerOsdMiniProgress), findsNothing, reason: '直播无迷你条');
  });

  testWidgets('duration 为 0 时隐藏进度（不显示 00:00 / 00:00）', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(
          duration: Duration.zero,
          flags: {...defaultOsdFlags(), OsdFlag.mini: true},
        ),
      ),
    );
    expect(find.textContaining('/ 00:00'), findsNothing);
    expect(find.textContaining('02:56'), findsNothing);
    expect(find.byType(PlayerOsdMiniProgress), findsNothing, reason: '时长未知也不画迷你条');
  });

  testWidgets('诊断面板开启时渲染主列与附加列', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(
          flags: {...defaultOsdFlags(), OsdFlag.diagnostics: true},
          diagnostics: const [
            OsdDiagnosticsRow('视频', 'hevc 3840×2160'),
            OsdDiagnosticsRow('音频', 'eac3 6ch'),
          ],
          environment: const [OsdDiagnosticsRow('运行环境', 'Windows 11')],
        ),
      ),
    );
    // 标签与取值各自是独立 Text：标签精确串可断言，取值用精确串再钉一次。
    expect(find.text('视频'), findsOneWidget);
    expect(find.text('hevc 3840×2160'), findsOneWidget);
    expect(find.text('音频'), findsOneWidget);
    expect(find.text('eac3 6ch'), findsOneWidget);
    expect(find.text('运行环境'), findsOneWidget);
    expect(find.text('Windows 11'), findsOneWidget);
  });

  testWidgets('诊断面板不与上左标题/时钟叠印（design/02 §3.2）', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(
          flags: {...defaultOsdFlags(), OsdFlag.diagnostics: true},
          diagnostics: const [
            OsdDiagnosticsRow('视频', 'hevc 3840×2160'),
            OsdDiagnosticsRow('音频', 'eac3 6ch'),
          ],
        ),
      ),
    );
    // 标题/时钟与面板都贴顶：实现若把它们各画在 `top: 0`，两段文字会叠印在
    // 一起（标题 14px 两行压在「视频」行上）。这里量的是真实几何，不是结构。
    final titleRect = tester.getRect(find.text('示例剧集 · E3\n3840×2160'));
    final clockRect = tester.getRect(find.text('20:30:18'));
    final panelTop = tester.getRect(find.text('视频')).top;
    expect(panelTop, greaterThanOrEqualTo(titleRect.bottom), reason: '面板须排在标题之下');
    expect(panelTop, greaterThanOrEqualTo(clockRect.bottom), reason: '面板须排在时钟之下');
  });

  testWidgets('诊断开关开但没有主列数据时不渲染空面板', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(
          flags: {
            for (final id in OsdFlag.values) id: false,
            OsdFlag.diagnostics: true,
          },
          // 只有附加列、没有主列：出面板等于屏幕上只有「运行环境」两行孤字。
          environment: const [OsdDiagnosticsRow('运行环境', 'Windows 11')],
        ),
      ),
    );
    expect(find.text('运行环境'), findsNothing);
    expectNoTextInsideLayer(tester);
  });

  group('下右网速（design/02 §3.6）', () {
    testWidgets('开关开时按字节/秒渲染，并落在右下角', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildLayer(
            flags: {...defaultOsdFlags(), OsdFlag.traffic: true},
            bytesPerSecond: 12800000,
          ),
        ),
      );
      // 精确串：断言的是**真的读了这个数**（12.8 MB/s），不是写死的占位。
      expect(find.text('12.8 MB/s'), findsOneWidget);

      final traffic = tester.getRect(find.text('12.8 MB/s'));
      final progress = tester.getRect(find.text('02:56 / 10:00'));
      // 贴右缘：内边距是 AppSpace.lg（§3.4 统一内边距）。
      expect(
        traffic.right,
        800 - AppSpace.lg,
        reason: '网速贴右下角，与进度同一行',
      );
      expect(
        traffic.bottom,
        progress.bottom,
        reason: '两段同底（Row 的 crossAxisAlignment.end）',
      );
      expect(
        traffic.left,
        greaterThan(progress.right),
        reason: '网速不得压到进度文字上',
      );
    });

    testWidgets('取不到值时显示长破折号，不显示 0', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildLayer(
            flags: {...defaultOsdFlags(), OsdFlag.traffic: true},
            bytesPerSecond: null,
          ),
        ),
      );
      expect(find.text('—'), findsOneWidget);
      expect(find.textContaining('0 B/s'), findsNothing, reason: '0 会被误读成卡了');
    });

    testWidgets('另有反向锁：0 字节/秒显示 0 B/s（真实的零不是没数据）', (tester) async {
      await tester.pumpWidget(
        wrap(
          buildLayer(
            flags: {...defaultOsdFlags(), OsdFlag.traffic: true},
            bytesPerSecond: 0,
          ),
        ),
      );
      expect(find.text('0 B/s'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('只开网速（进度关）时仍贴右缘，不跑到左边', (tester) async {
      // 回归锁：这个组合是 `Row` 里唯一没有 `Expanded` 子项的情形，
      // 少了 `Spacer` 网速就会贴左——一个只有"关掉别的开关"才会出现的缺陷。
      await tester.pumpWidget(
        wrap(
          buildLayer(
            flags: {
              ...defaultOsdFlags(),
              OsdFlag.traffic: true,
              OsdFlag.progress: false,
            },
            bytesPerSecond: 860000,
          ),
        ),
      );
      final traffic = tester.getRect(find.text('860 KB/s'));
      expect(traffic.right, 800 - AppSpace.lg, reason: '仍须贴右缘');
      expect(traffic.left, greaterThan(400), reason: '不得掉到左半边');
    });

    testWidgets('开关关时不渲染；控制栏可见时也强制隐藏', (tester) async {
      await tester.pumpWidget(
        wrap(buildLayer(bytesPerSecond: 12800000)),
      );
      expect(find.text('12.8 MB/s'), findsNothing, reason: '开关默认关闭');

      await tester.pumpWidget(
        wrap(
          buildLayer(
            flags: {...defaultOsdFlags(), OsdFlag.traffic: true},
            bytesPerSecond: 12800000,
            controlsVisible: true,
          ),
        ),
      );
      expect(find.text('12.8 MB/s'), findsNothing, reason: '控制栏可见时屏显退让');
    });
  });

  testWidgets('整层 IgnorePointer：点击穿透（design/01 §3.1）', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: Stack(
            children: [
              // 画面上的接收者放在屏显层**下面**（兄弟节点）。
              //
              // 不能用「GestureDetector 包住屏显层」的写法：`GestureDetector`
              // 默认 `deferToChild`，子节点被 `IgnorePointer` 挡掉时它自己也
              // 收不到事件——那种写法无论有没有 `IgnorePointer` 都得到 false，
              // 是一条测不出东西的用例（实测确认）。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => tapped = true,
                child: const SizedBox.expand(),
              ),
              buildLayer(),
            ],
          ),
        ),
      ),
    );
    // 点在**文字上**：文本本身是命中测试目标，没有 IgnorePointer 时会被它吃掉。
    await tester.tap(find.text('20:30:18'), warnIfMissed: false);
    expect(tapped, isTrue, reason: '屏显层不得吃掉指针');

    // 结构断言：包住整层的那个 IgnorePointer 必须真的在拦截。
    final guards = find.descendant(
      of: find.byType(PlayerOsdLayer),
      matching: find.byType(IgnorePointer),
    );
    expect(guards, findsOneWidget);
    expect(tester.widget<IgnorePointer>(guards).ignoring, isTrue);
  });

  testWidgets('屏显文本字号为 14 且带表格字形（design/02 §3.5）', (tester) async {
    await tester.pumpWidget(wrap(buildLayer()));
    final clock = tester.widget<Text>(find.text('20:30:18'));
    expect(clock.style?.fontSize, 14);
    expect(clock.style?.fontFeatures, kTabularFigures);
    expect(clock.style?.color, Colors.white);
    // 描边（不是底色块）：亮画面上纯白字不可读。
    expect(clock.style?.shadows, isNotEmpty, reason: '亮画面上必须描边');
    expect(clock.style?.shadows?.first.color, Colors.black);
  });

  testWidgets('迷你进度条颜色为星等琥珀（The One Accent Rule）', (tester) async {
    await tester.pumpWidget(
      wrap(buildLayer(flags: {...defaultOsdFlags(), OsdFlag.mini: true})),
    );
    final progress = tester.widget<PlayerOsdMiniProgress>(
      find.byType(PlayerOsdMiniProgress),
    );
    // 2:56 / 10:00 —— 断言的是「按播放位置算出的比例」。
    expect(progress.progress, closeTo(176 / 600, 0.001));

    final bar = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(PlayerOsdMiniProgress),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      bar.color,
      AppPalette.magnitude,
      reason: 'DESIGN.md 的 The One Accent Rule 把「进度条」列为琥珀的合法用途',
    );
  });

  testWidgets('播放位置超出时长时比例钳到 1', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(
          // 位置 12:00 > 时长 10:00：拖到末尾之外时不能把条子撑出画面。
          position: const Duration(minutes: 12),
          flags: {...defaultOsdFlags(), OsdFlag.mini: true},
        ),
      ),
    );
    final progress = tester.widget<PlayerOsdMiniProgress>(
      find.byType(PlayerOsdMiniProgress),
    );
    expect(progress.progress, 1.0);
  });

  testWidgets('迷你进度条贴底且通栏（design/02 §3.3/§3.4 的例外）', (tester) async {
    await tester.pumpWidget(
      wrap(buildLayer(flags: {...defaultOsdFlags(), OsdFlag.mini: true})),
    );
    final rect = tester.getRect(find.byType(PlayerOsdMiniProgress));
    // 800×600 是 flutter_test 的默认视口。
    expect(rect.left, 0, reason: '无内边距');
    expect(rect.right, 800, reason: '通栏');
    expect(rect.bottom, 600, reason: '贴画面最底部');
    expect(rect.height, 2, reason: '上游 2dp');
  });

  // 关键用例：不得渲染 `data == ''` 的 Text。
  //
  // 为什么必须有这一条：`size` 开而 `title` 关、且 `resolution == null` 时，
  // 上左两段都为空 → `join('\n')` 得到空串 → 会渲染一个 `data == ''` 的 `Text`。
  // 全站约束要求「`.data` 非空」（`Text.rich` 会在遍历 `allWidgets` 取 `.data`
  // 的测试里静默消失；空串虽非 null 但同样是无内容占位）。
  // 变异测试实测确认：把 `_cornerTopLeftVisible` 改回只看开关（不看内容），
  // 这条用例会失败。
  testWidgets('分辨率缺失且标题关闭时不渲染空 Text', (tester) async {
    await tester.pumpWidget(
      wrap(
        buildLayer(
          // 只有 size 开，且拿不到分辨率。
          flags: {
            ...defaultOsdFlags(),
            OsdFlag.title: false,
            OsdFlag.size: true,
            OsdFlag.time: false,
            OsdFlag.progress: false,
          },
          resolution: null,
        ),
      ),
    );
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      expect(text.data, isNot(''), reason: '不得渲染空串 Text（无内容占位）');
    }
    expect(find.text(''), findsNothing);
  });
}
