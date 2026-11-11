/// 历史页与设置页的交互门禁（`docs/phase6/design/01` §4.3、§7）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/library_pages.dart';
import 'package:webhtv_pc/ui/toast.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    // `toastCenter` 是进程级单例：上一条用例留下的通知会漏进这一条。
    dismissAllToasts();
    tempDir = await Directory.systemTemp.createTemp('webhtv-history-page');
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
      // **必须注入假 client**：`play` 分流会走 `_resume` → `resolvePlayback`，
      // 那是真实 HTTP + 本地代理链。在 `testWidgets` 的 fake-async 区里做真实
      // socket I/O 会**挂死**（`did not complete`，无任何 Exception 日志）——
      // 这是本仓库既有的分层纪律（`webhtv-pc-test-io-layering`）。
      httpClient: _RecordingSiteClient(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    // 先收通知再销毁状态（通知的 `onDismiss` 会回调状态层）。
    dismissAllToasts();
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsPage(state: state))),
    );
    await tester.pump();
  }

  testWidgets('设置页有「历史记录」区块与两个选项', (tester) async {
    await pumpSettings(tester);
    expect(find.text('历史记录'), findsOneWidget);
    final selector = find.byKey(
      const ValueKey('settings-history-click-action'),
    );
    expect(selector, findsOneWidget);
    expect(find.text('进入详情页'), findsOneWidget);
    expect(find.text('直接播放'), findsOneWidget);
  });

  testWidgets('默认选中「进入详情页」', (tester) async {
    await pumpSettings(tester);
    final button = tester.widget<SegmentedButton<String>>(
      find.byKey(const ValueKey('settings-history-click-action')),
    );
    expect(button.selected, {UiHistoryClickAction.detail});
  });

  testWidgets('已保存的偏好决定初始选中项（不是永远显示第一项）', (tester) async {
    // 变异自检发现的覆盖缺口：把 `selected` 写死成 `{detail}` 时前三个用例
    // 照样全绿。这里先把偏好改成 `play` 再建页面——选中态必须来自
    // `AppState.historyClickAction`，而不是常量。
    //
    // 真实 I/O 必须放进 `runAsync`：`testWidgets` 是假时钟，写盘回调不会被
    // `pump` 推进（见 `phase5_sync_ui_test.dart` 顶部注释）。
    await tester.runAsync(
      () => state.setHistoryClickAction(UiHistoryClickAction.play),
    );
    expect(state.historyClickAction, UiHistoryClickAction.play);

    await pumpSettings(tester);
    final button = tester.widget<SegmentedButton<String>>(
      find.byKey(const ValueKey('settings-history-click-action')),
    );
    expect(button.selected, {UiHistoryClickAction.play});
  });

  testWidgets('点「直接播放」写入偏好', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('直接播放'));
    await tester.pumpAndSettle();
    expect(state.historyClickAction, UiHistoryClickAction.play);
  });

  /// 直接往库里塞一条历史，绕过播放器。
  ///
  /// **`vodId` / `episodeId` 必须随 `id` 变化**：`history` 表的唯一键是
  /// `(site_key, vod_id, flag, episode_id)`，全部用同一个默认值时三次
  /// `upsertHistory` 会走 `ON CONFLICT ... DO UPDATE` **塌成同一行**，
  /// 「3 条历史」的用例就只剩最后一条。
  void seedHistory({
    required int id,
    required String vodName,
    String episodeName = '第1集',
    String siteKey = 'site-a',
    String? vodId,
    String flag = '线路一',
    String? episodeId,
    int positionMs = 30000,
    int durationMs = 100000,
    int? updatedAt,
  }) {
    state.database!.upsertHistory(
      siteKey: siteKey,
      vodId: vodId ?? 'v$id',
      vodName: vodName,
      flag: flag,
      episodeName: episodeName,
      episodeId: episodeId ?? 'http://x/e$id',
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAt: updatedAt,
      // 归属到**当前生效源**：这些用例锁的是点击分流，不是来源范围。
      // 不写源就会落成空 source_key，而按源隔离的视图里空来源记录不可见
      // （用户 2026-10-28 要求严格过滤「来源未知」），卡片会直接找不到。
      sourceKey: state.activeSourceKey,
    );
  }

  Future<void> pumpHistory(
    WidgetTester tester, {
    Size size = const Size(1400, 1000),
    bool inShell = false,
    double textScaleFactor = 1.0,
  }) async {
    if (textScaleFactor != 1.0) {
      tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    // `inShell: true` 复刻真实壳层：左栏 76 + `VerticalDivider(width: 1)`，
    // 于是**内容区宽 ≠ 整窗宽**。这正是判据：
    // 列数必须来自 `LayoutBuilder` 的 `constraints.maxWidth`（内容区），
    // 而不是 `MediaQuery.sizeOf(context).width`（整窗）。
    final page = HistoryPage(state: state);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 通知宿主挂在 `home:` 里（Navigator 的 Overlay 内），不是
          // `MaterialApp.builder`：后者在 Overlay 之外，且会吃掉下方内容的命中
          // 测试。挂法与层级由 `test/toast_host_test.dart` 单独锁定。
          body: Stack(
            fit: StackFit.expand,
            children: [
              inShell
                  ? Row(
                      children: [
                        const SizedBox(width: 76),
                        const VerticalDivider(width: 1),
                        Expanded(child: page),
                      ],
                    )
                  : page,
              const ToastHost(),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('历史页卡片网格（design/01 §2）', () {
    testWidgets('渲染为网格，卡片数 == 历史条数', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲', updatedAt: 3000);
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 2000);
      seedHistory(id: 3, vodName: '剧集丙', updatedAt: 1000);
      // 前置条件自检：三条种子必须真的是三行（否则「只出现一次」是假绿）。
      expect(state.recentHistory().length, 3);
      await pumpHistory(tester);

      expect(find.byKey(const ValueKey('history-grid')), findsOneWidget);
      expect(find.byType(SliverGrid), findsWidgets);
      for (final name in const ['剧集甲', '剧集乙', '剧集丙']) {
        expect(find.text(name), findsOneWidget, reason: '$name 必须出现且只出现一次');
      }
      // 用例标题里的「卡片数 == 历史条数」必须真的被断言：只查片名挡不住
      // 「多渲染了空卡片」这类变异（如 `itemCount` 写大一点）。
      for (final id in const [1, 2, 3]) {
        expect(
          find.byKey(ValueKey('history-row-$id')),
          findsOneWidget,
          reason: '第 $id 条历史必须有且只有一张卡片',
        );
      }
    });

    testWidgets('每张卡片只渲染一次片名 Text', (tester) async {
      seedHistory(id: 1, vodName: '唯一片名');
      await pumpHistory(tester);
      expect(find.text('唯一片名'), findsOneWidget);
    });

    testWidgets('海报保持 2:3', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);
      final box = tester.getSize(
        find
            .descendant(
              of: find.byKey(const ValueKey('history-row-1')),
              matching: find.byType(AspectRatio),
            )
            .first,
      );
      expect(box.width / box.height, closeTo(2 / 3, 0.05));
    });

    testWidgets('空历史显示空态，不渲染网格', (tester) async {
      await pumpHistory(tester);
      expect(find.text('暂无播放记录'), findsOneWidget);
      expect(find.byKey(const ValueKey('history-grid')), findsNothing);
    });

    // 变异自检发现的覆盖缺口：把 `columns` 写死成常量（例如 `3`）时，上面四条
    // 用例**全部照绿**——它们只看「有没有网格 / 片名出现几次 / 海报比例」，
    // 而写死列数在 1400 宽下同样能给出 2:3 的海报。列数自适应是
    // `design/01` §2.2 明确要求的（「列数按窗口宽自适应」），必须单独钉住。
    testWidgets('列数随窗口宽自适应（不是写死的常量）', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      // 期望值来自 DESIGN.md 的「内容网格」实测取值：目标列宽 150、列间距 14、
      // 网格内边距 16 → usable = 宽 - 32，columns = round(usable / 164)。
      // 宽 1400：usable 1368，1368/164 = 8.34 → 8 列。
      // 宽 700： usable  668， 668/164 = 4.07 → 4 列。
      await pumpHistory(tester, size: const Size(1400, 1000));
      expect(
        _historyColumns(tester),
        8,
        reason: '1400 宽必须铺 8 列（DESIGN.md 的目标列宽 150 + 列间距 14）',
      );

      await pumpHistory(tester, size: const Size(700, 1000));
      expect(
        _historyColumns(tester),
        4,
        reason: '700 宽必须收到 4 列——写死列数会让窄窗口下的海报比例失真',
      );
    });

    // 列数的**基准宽度**必须是内容区，而不是整窗（`design/01` §2.2 要求与首页
    // 海报墙共用同一套算法，而首页用的是 `LayoutBuilder(constraints.maxWidth)`）。
    // 壳层左侧有 `NavigationRail`(76) + `VerticalDivider`(1)，两者相差 77px。
    // 窗宽 1100 时两种口径必然分叉：
    //   整窗（错）：usable 1100-32 = 1068，1068/164 = 6.51 → 7 列
    //   内容（对）：usable 1100-77-32 = 991，991/164 = 6.04 → 6 列
    testWidgets('列数按内容区宽度算，不是整窗宽（壳层下列数不偏多）', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester, size: const Size(1100, 1000), inShell: true);
      expect(
        _historyColumns(tester),
        6,
        reason:
            '壳层里内容区只有 1023px：列数必须用 LayoutBuilder 的 constraints.maxWidth。'
            '用 MediaQuery.sizeOf 会算成 7 列（比首页海报墙多一列）。',
      );
    });

    // 无障碍放大字号时，卡片**不得溢出格子**。`_historyCaptionHeight` 是固定值
    // （DESIGN.md 的「文字区高 40px」，与首页共用），所以文字区必须夹住放大倍数
    // ——首页 `_VodCard` 就是这么做的（`browse_pages.dart` 的
    // `MediaQuery.withClampedTextScaling(maxScaleFactor: 1.25)`）。
    //
    // 取 1.5 而不是 1.25：1.25 是**clamp 的上界本身**，在 1.25 下「夹住」与
    // 「没夹住」观察结果相同，测不出 clamp 是否真的存在。
    for (final scale in const [1.5, 2.0]) {
      testWidgets('文字放大 $scale 倍时卡片不溢出', (tester) async {
        seedHistory(id: 1, vodName: '剧集甲');
        await pumpHistory(
          tester,
          size: const Size(1400, 1000),
          textScaleFactor: scale,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'textScaleFactor=$scale 时卡片溢出了固定高度的文字区',
        );
        // 片名仍然只渲染一次（放大不能靠复制一份「缩小版」文字来兜底）。
        expect(find.text('剧集甲'), findsOneWidget);
      });
    }
  });

  group('删除态（design/01 §3）', () {
    testWidgets('长按卡片进入删除态：出现遮罩与「完成」', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();

      expect(find.byKey(const ValueKey('history-delete-done')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('history-delete-overlay-1')),
        findsOneWidget,
      );
    });

    testWidgets('删除态下点卡片即删该条，仍在删除态', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.text('剧集甲'), findsNothing, reason: '该条被删除');
      expect(find.text('剧集乙'), findsOneWidget, reason: '另一条不受影响');
      expect(
        find.byKey(const ValueKey('history-delete-done')),
        findsOneWidget,
        reason: '还有条目时仍在删除态',
      );
      expect(state.recentHistory().length, 1, reason: '必须真的落盘');
    });

    testWidgets('删除态删掉最后一条后自动退出', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('暂无播放记录'), findsOneWidget);
    });

    testWidgets('点「完成」退出删除态且不删任何东西', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-delete-done')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('剧集甲'), findsOneWidget);
      expect(state.recentHistory().length, 1);
    });

    testWidgets('再次长按退出删除态', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      // 先断言**真的进去了**：否则「退出」断言在「从未进入」时也绿（假绿）。
      expect(find.byKey(const ValueKey('history-delete-done')), findsOneWidget);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('剧集甲'), findsOneWidget);
    });

    testWidgets('空历史时不渲染删除入口', (tester) async {
      await pumpHistory(tester);
      expect(find.byKey(const ValueKey('history-bulk-delete')), findsNothing);
    });

    // **`design/01` §3.2 这一段自相矛盾**（同一场景两个相反结论）：
    //   句2「搜索出 1 条、删掉它之后，可见列表为空 → 退出删除态」
    //   句3「搜索后可见 1 条，删掉这 1 条**不应**退出（还有 9 条被搜索词挡着）」
    //   句5「判定必须用 `_items`（过滤后）而不是 `state.recentHistory()`（全量）」
    // 句3 与句5 **不可兼得**：用 `_items` 判定 ⇒ 删掉可见最后一条后必然为空
    // ⇒ 必然退出（= 句2），永远达不到句3。
    //
    // **裁定：退出**。依据 3 条 vs 1 条：
    //   ① `design/05` A11d（**验收判据**）只写了退出条款：
    //      「删除态删掉"过滤后最后一条"才退出」；
    //   ② §3.2 句5 是实现指令，用 `_items` 必然导出退出；
    //   ③ §3.2 句2 是**加粗的主规则**（「判定基准是过滤后的可见列表」）；
    //   ④ 上游 `HistoryActivity` 无搜索，`getItemCount() == 0 → setDelete(false)`
    //      （其 `getItemCount()` 等价于全量，但全量==可见时与句2 一致）。
    // UX 判据（决定性）：若「不退出」，可见列表已空、删除态横幅仍在，屏幕会同时
    // 出现「暂无播放记录」与「点击卡片即删除该条记录」——自相矛盾的界面，
    // 正是 design 自己批判的反模式（「点了什么也没有的按钮比没有按钮更糟」）。
    //
    // 这条用例同时是**判定基准**的钉子：若实现改用 `state.recentHistory()`（全量）
    // 判空，则全量还有 1 条 → 不退出 → 本用例失败。
    testWidgets('删掉过滤后最后一条即退出（裁定：§3.2 句3 与句5 冲突，取句5）', (
      tester,
    ) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.enterText(find.byType(TextField), '剧集乙');
      await tester.pump();
      expect(find.text('剧集甲'), findsNothing, reason: '前置：搜索已把它挡住');

      await tester.longPress(find.byKey(const ValueKey('history-row-2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-2')));
      await tester.pumpAndSettle();

      expect(
        state.recentHistory().length,
        1,
        reason: '全量里还有「剧集甲」（被搜索词挡着）',
      );
      expect(
        find.byKey(const ValueKey('history-delete-done')),
        findsNothing,
        reason:
            '判定必须用 `_items`（过滤后）：可见列表已空 → 退出。'
            '用 `state.recentHistory()`（全量）判空会留在这个已无卡片可点的模式里。',
      );
    });

    // Esc 退出（`design/01` §3.1 的「退出方式」列）。
    testWidgets('Esc 退出删除态', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      expect(find.byKey(const ValueKey('history-delete-done')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-delete-done')), findsNothing);
      expect(find.text('剧集甲'), findsOneWidget, reason: 'Esc 不删任何东西');
    });

    // 删除态下**必须**逐条走 `state.deleteHistory`（而不是直接改本地列表）：
    // 它同时写 `history_deletions` 标记，否则安卓下次推来旧记录会复活
    // （`docs/phase5/design/02` §4.5）。
    testWidgets('删除会写删除标记（否则远端旧记录会复活）', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(
        state.database!.historyDeletionCount,
        1,
        reason: '删除必须留下 history_deletions 标记（phase5 design/02 §4.5）',
      );
    });
  });

  group('多选批量删除（design/01 §3.1、§3.3）', () {
    testWidgets('点「批量删除」进入多选态', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      expect(find.byKey(const ValueKey('history-bulk-delete')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();

      expect(find.byKey(const ValueKey('history-checkbox-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-select-all')), findsOneWidget);
    });

    testWidgets('多选态点卡片只勾选，不删除', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.text('剧集甲'), findsOneWidget, reason: '不得删除');
      expect(find.text('已选 1 条'), findsOneWidget);
      expect(state.recentHistory().length, 2, reason: '库中仍是 2 条');
    });

    testWidgets('全选后删除选中：确认框写明条数，确认后删除', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-select-all')));
      await tester.pump();
      expect(find.text('已选 2 条'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
      await tester.pumpAndSettle();
      expect(find.textContaining('将删除选中的 2 条'), findsOneWidget);
      expect(find.textContaining('不可撤销'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('history-bulk-confirm')));
      await tester.pumpAndSettle();

      expect(state.recentHistory(), isEmpty);
      expect(find.text('暂无播放记录'), findsOneWidget);
      // `design/01` A10：「确认后 N 条被删除，**退出多选态**」。
      // 不退出的话，列表已空而多选工具栏仍在（「全选 / 删除选中(0) / 取消」
      // 对着一个空列表），正是文档自己批判的反模式。
      expect(
        find.byKey(const ValueKey('history-select-all')),
        findsNothing,
        reason: '确认删除后必须退出多选态（A10）',
      );
      expect(
        find.byKey(const ValueKey('history-bulk-delete')),
        findsNothing,
        reason: '列表已空 → 两个删除入口都不渲染（A12）',
      );
    });

    testWidgets('取消确认框不删除', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-select-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
      await tester.pumpAndSettle();
      // **必须限定到对话框内**：多选工具栏自己也有一个「取消」按钮，
      // 裸 `find.text('取消')` 会命中 2 个 widget 而报「ambiguously found」。
      // （brief 原文就是裸 finder，属事实性错误。）
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('history-bulk-confirm-dialog')),
          matching: find.text('取消'),
        ),
      );
      await tester.pumpAndSettle();

      expect(state.recentHistory().length, 1);
    });

    testWidgets('「取消」退出多选态并清空勾选', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-cancel-select')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-checkbox-1')), findsNothing);
      expect(find.byKey(const ValueKey('history-bulk-delete')), findsOneWidget);
    });

    testWidgets('搜索词变化清空已选', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      expect(find.text('已选 1 条'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '剧集乙');
      await tester.pumpAndSettle();

      expect(find.text('已选 1 条'), findsNothing, reason: '搜索词变化必须清空已选');
      expect(find.byKey(const ValueKey('history-checkbox-2')), findsOneWidget);
    });

    testWidgets('搜索词未变化时不清空已选', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '剧集');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      // 再输入同一个词（onChanged 会被调用，但值未变）。
      await tester.enterText(find.byType(TextField), '剧集');
      await tester.pumpAndSettle();

      expect(find.text('已选 1 条'), findsOneWidget, reason: '值未变不得清空');
    });

    // ---- 以下 5 条是 brief 没有的钉子（变异自检发现）----

    // 「全选」必须只勾**可见**的（`design/01` §3.2：「勾选当前可见全部」）。
    // 搜索后全选若把被搜索词挡住的条目也勾上，用户点「删除选中」会删掉
    // 自己看不见的记录。
    testWidgets('全选只勾当前可见的（搜索后被挡住的不得被勾）', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '剧集乙');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-select-all')));
      await tester.pump();

      expect(find.text('已选 1 条'), findsOneWidget, reason: '只有「剧集乙」可见');
    });

    // 只删**选中**的，不得把未选中的一起删（`design/01` A10）。
    testWidgets('只删选中的那一条，未选中的保留', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-bulk-confirm')));
      await tester.pumpAndSettle();

      expect(find.text('剧集甲'), findsNothing, reason: '选中的被删');
      expect(find.text('剧集乙'), findsOneWidget, reason: '未选中的必须保留');
      expect(state.recentHistory().length, 1);
    });

    // 批量删除也必须逐条走 `deleteHistory`（写删除标记），
    // 否则安卓下次推来旧记录会复活（`phase5 design/02` §4.5）。
    testWidgets('批量删除也写删除标记', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-select-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-delete-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('history-bulk-confirm')));
      await tester.pumpAndSettle();

      expect(
        state.database!.historyDeletionCount,
        2,
        reason: '两条删除都必须留下 history_deletions 标记',
      );
    });

    // 未勾选任何条目时「删除选中(0)」必须**禁用**（`DESIGN.md`：
    // 「一个点了什么也没有的按钮比没有按钮更糟」）。
    testWidgets('未勾选时「删除选中(0)」禁用', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();

      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('history-delete-selected')),
      );
      expect(button.onPressed, isNull, reason: '没有选中时不得可点');

      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      final enabled = tester.widget<TextButton>(
        find.byKey(const ValueKey('history-delete-selected')),
      );
      expect(enabled.onPressed, isNotNull, reason: '勾选后必须可点');
    });

    // 多选态下长按**不得**切进删除态（§3.1 状态图里没有
    // `multiSelect → singleDelete` 这条边）：否则用户误长按会丢掉已勾选的集合，
    // 而且卡片会突然变成「点谁删谁」——一个删除动作被误触。
    testWidgets('多选态下长按不切进删除态，已勾选不丢', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      expect(find.text('已选 1 条'), findsOneWidget);

      await tester.longPress(find.byKey(const ValueKey('history-row-2')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('history-delete-done')),
        findsNothing,
        reason: '多选态长按不得切进删除态',
      );
      expect(find.text('已选 1 条'), findsOneWidget, reason: '已勾选不得被清掉');
      expect(state.recentHistory().length, 2, reason: '长按不得删任何东西');
    });

    // 多选态下 Esc 退出（`design/01` §3.1 的「退出方式」列）。
    testWidgets('多选态下 Esc 退出并清空勾选', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history-checkbox-1')), findsNothing);
      expect(find.byKey(const ValueKey('history-bulk-delete')), findsOneWidget);
      expect(state.recentHistory().length, 1, reason: 'Esc 不删任何东西');
    });

    // `none` 态不得渲染多选态的工具栏（模式互斥）。
    testWidgets('默认态不渲染多选工具栏', (tester) async {
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      expect(find.byKey(const ValueKey('history-select-all')), findsNothing);
      expect(find.byKey(const ValueKey('history-cancel-select')), findsNothing);
      expect(find.byKey(const ValueKey('history-delete-selected')), findsNothing);
      expect(find.byKey(const ValueKey('history-checkbox-1')), findsNothing);
    });
  });

  group('点击分流（design/01 §4、§5）', () {
    // `setUp` 的 `state` 没有配置（`bootstrap()` 不导入任何配置），
    // 而 `_openDetail` / `_resume` 都要求「站点在配置里」。
    // 因此本组用例必须先导入一份**内联 JSON** 配置。
    //
    // 用内联 JSON 而不是 `configFor(url)`：后者是 URL 源，
    // `importConfig` 会走真实 HTTP 拉取，而 `testWidgets` 的 fake-async 区里
    // 所有 `HttpClient` 都被固定返回 400（Flutter 测试框架既有行为）。
    // 内联 JSON 不联网，实测 `ok=true`。
    Future<void> seedSite({String key = 'site-a'}) async {
      final ok = await state.importConfig(
        '{"name":"点击分流测试","sites":[{"key":"$key","name":"甲站",'
        '"type":4,"api":"http://127.0.0.1:1/vod/api?key=$key"}]}',
      );
      expect(ok, isTrue, reason: '前置：配置导入必须成功');
      expect(state.config, isNotNull, reason: '前置：config 必须可用');
    }

    testWidgets('默认 detail：点卡片进详情页，不播放', (tester) async {
      await seedSite();
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.byType(DetailPage), findsOneWidget);
    });

    testWidgets('play：点卡片直接续播，不进详情页', (tester) async {
      await seedSite();
      // **必须放进 `runAsync`**：`setHistoryClickAction` 会真实写盘，
      // 而 `testWidgets` 是假时钟，写盘回调不会被 `pump` 推进 → 整个用例
      // `did not complete`（无 Exception 日志）。同文件上方
      // 「已保存的偏好决定初始选中项」用例已踩过同一个坑。
      await tester.runAsync(
        () => state.setHistoryClickAction(UiHistoryClickAction.play),
      );
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);
      // 清掉 `pumpHistory` 期间 `_repairMissingPosters` 留下的请求记录，
      // 只观察**点击之后**发起了什么。
      _requests.clear();

      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      // 真实 I/O 链必须用 `runAsync` 推：fake-async 区里只 `pump()` 推不动
      // 挂在真实 socket 上的续体（本仓库既有的分层纪律）。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      // **必须把 `LogService` 的刷盘定时器泵完**：`loadHome` 失败会写一条
      // error 日志，`_enqueue` 安排了一个 0 延迟 `Timer`；不泵完则用例结束时
      // 报 `A Timer is still pending even after the widget tree was disposed`。
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(DetailPage), findsNothing);
      // **强断言**：必须真的发起了「播放入口」请求（`play=` 参数）。
      // 只断言「没进详情页」是弱断言——「什么都没发生」也能让它绿。
      expect(
        _requests.any((url) => url.queryParameters.containsKey('play')),
        isTrue,
        reason: 'play 分流必须走 _resume → resolvePlayback（带 play= 的播放入口请求），'
            '实际请求：$_requests',
      );
    });

    testWidgets('站点不在配置中时给出可见提示，不静默失败', (tester) async {
      await seedSite();
      seedHistory(id: 1, vodName: '剧集甲', siteKey: '已删除的站点');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      // 不能用 `pumpAndSettle`：错误通知带 15 秒倒计时动画，settle 会一路把它
      // 推到自动关闭，断言就没东西可看了（这正是本文件当初按「错误永不关闭」
      // 规避的那个陷阱，错误改成 15 秒后该规避失效）。显式推两帧即可。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('已不在当前配置中'), findsOneWidget);
      expect(find.byType(DetailPage), findsNothing);
    });

    // ---- 以下 5 条是 brief 没有的钉子（预检/变异自检发现）----

    // **进详情页前必须先切站点**（`search_page.dart#_openResult` 同因）：
    // `DetailPage` 的详情请求依赖「当前站点」，不切会串到别的站点去取详情。
    // 用两个站点：历史属于第二个，断言点卡片后 `selectedSite` 变成了它。
    testWidgets('进详情页前先切到该记录所属站点（不串站）', (tester) async {
      final ok = await state.importConfig(
        '{"name":"双站","sites":['
        '{"key":"site-a","name":"甲站","type":4,'
        '"api":"http://127.0.0.1:1/vod/api?key=site-a"},'
        '{"key":"site-b","name":"乙站","type":4,'
        '"api":"http://127.0.0.1:1/vod/api?key=site-b"}]}',
      );
      expect(ok, isTrue, reason: '前置：配置导入必须成功');
      // 导入后默认选中第一个站点；先把当前站点明确设为 site-a。
      await state.selectSite(state.config!.sites.first);
      expect(state.selectedSite?.key, 'site-a', reason: '前置：当前是甲站');

      seedHistory(id: 1, vodName: '剧集甲', siteKey: 'site-b');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(
        state.selectedSite?.key,
        'site-b',
        reason: '必须先切到历史所属站点，否则详情会串到甲站去取',
      );
      expect(find.byType(DetailPage), findsOneWidget);
    });

    // 详情页必须拿到**用户点的那一条**的线路与集入口（`design/02` §7.1）：
    // 同一部剧有多条历史时，点旧记录却续新记录是错的。
    testWidgets('详情页收到该条历史的线路与集入口', (tester) async {
      await seedSite();
      seedHistory(
        id: 1,
        vodName: '剧集甲',
        flag: '线路二',
        episodeId: 'http://x/e7',
      );
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      final page = tester.widget<DetailPage>(find.byType(DetailPage));
      expect(page.historyFlag, '线路二');
      expect(page.historyEpisodeId, 'http://x/e7');
      expect(page.vod.vodId, 'v1', reason: '必须传该条历史的 vodId');
      expect(page.vod.vodName, '剧集甲');
    });

    // 删除态 / 多选态下点卡片**不得**走分流（否则会边删边跳详情页）。
    testWidgets('删除态下点卡片不跳详情页', (tester) async {
      await seedSite();
      seedHistory(id: 1, vodName: '剧集甲');
      seedHistory(id: 2, vodName: '剧集乙', updatedAt: 1000);
      await pumpHistory(tester);

      await tester.longPress(find.byKey(const ValueKey('history-row-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-2')));
      await tester.pumpAndSettle();

      expect(find.byType(DetailPage), findsNothing, reason: '删除态不跳详情');
      expect(state.recentHistory().length, 1, reason: '而是删掉那一条');
    });

    testWidgets('多选态下点卡片不跳详情页', (tester) async {
      await seedSite();
      seedHistory(id: 1, vodName: '剧集甲');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-bulk-delete')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.pumpAndSettle();

      expect(find.byType(DetailPage), findsNothing, reason: '多选态只勾选');
      expect(find.text('已选 1 条'), findsOneWidget);
    });

    // `play` 模式下站点不在配置中时也必须给可见提示（不得静默失败）。
    testWidgets('play 模式下站点不在配置中同样给提示', (tester) async {
      await seedSite();
      await tester.runAsync(
        () => state.setHistoryClickAction(UiHistoryClickAction.play),
      );
      seedHistory(id: 1, vodName: '剧集甲', siteKey: '已删除的站点');
      await pumpHistory(tester);

      await tester.tap(find.byKey(const ValueKey('history-row-1')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('已不在当前配置中'), findsOneWidget);
    });
  });
}

/// 读出历史网格当前的实际列数。
int _historyColumns(WidgetTester tester) {
  final grid = tester.widget<GridView>(
    find.byKey(const ValueKey('history-grid')),
  );
  return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
      .crossAxisCount;
}

/// 记录所有站点请求，并一律拒绝。
///
/// 两个作用：
/// 1. **避免真实 socket I/O**：`testWidgets` 的 fake-async 区里做真实网络会挂死
///    （`did not complete`，无 Exception 日志）——本仓库既有的分层纪律。
/// 2. **让分流可断言**：记录 URL 就能区分「发了播放入口请求（`play=`）」
///    与「没发任何请求」，比只断言「没进详情页」强得多。
class _RecordingSiteClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _requests.add(request.url);
    throw StateError('测试不发真实站点请求：${request.url}');
  }
}

/// 本文件内所有站点请求的 URL（跨用例共享，用例内自行清空）。
final List<Uri> _requests = <Uri>[];
