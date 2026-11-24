/// 加固壳解包三处交互（导入确认 / 多选 / 进度）与 state 钩子的回归测试。
///
/// 只测**用户可见结论**：弹框出没出、默认勾了谁、取消有没有触发动作、
/// 失败态会不会被静默关掉。真实解包（下载 40.7 MB 运行时、跑 unidbg）不在
/// 单测范围内——那部分由 shell_unpack_test.dart 覆盖。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/shell_unpack.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/shell_unpack_dialogs.dart';

/// 阶段名与 CLI 同源（`ShellUnpack.stages`），不在这里另抄一份。
final String _readStage = ShellUnpack.stages[0];
final String _startStage = ShellUnpack.stages[2];
final String _invokeStage = ShellUnpack.stages[4];

/// 点一下按钮就在当前 context 上开框：测的是对话框本身，不是页面。
Widget _host(Future<void> Function(BuildContext context) open) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

const ValueKey<String> _promptKey = ValueKey('shell-unpack-prompt');
const ValueKey<String> _promptLaterKey = ValueKey('shell-unpack-prompt-later');
const ValueKey<String> _promptConfirmKey = ValueKey(
  'shell-unpack-prompt-confirm',
);
const ValueKey<String> _progressKey = ValueKey('shell-unpack-progress');
const ValueKey<String> _progressCloseKey = ValueKey(
  'shell-unpack-progress-close',
);

void main() {
  group('导入后的确认框', () {
    testWidgets('未装运行时说明体积，点「稍后」不回调', (tester) async {
      var confirmations = 0;
      bool? result;
      await tester.pumpWidget(
        _host((context) async {
          result = await showShellUnpackPrompt(
            context,
            siteCount: 3,
            runtimeInstalled: false,
            onConfirm: () async => confirmations++,
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byKey(_promptKey), findsOneWidget);
      expect(find.textContaining('3 个加固壳站源'), findsOneWidget);
      expect(find.textContaining('40.7 MB'), findsOneWidget);

      await tester.tap(find.byKey(_promptLaterKey));
      await tester.pumpAndSettle();

      expect(confirmations, 0, reason: '取消路径不许触发任何下载');
      expect(result, isFalse);
      expect(find.byKey(_promptKey), findsNothing);
    });

    testWidgets('已装运行时不提体积，点确认才回调一次', (tester) async {
      var confirmations = 0;
      bool? result;
      await tester.pumpWidget(
        _host((context) async {
          result = await showShellUnpackPrompt(
            context,
            siteCount: 2,
            runtimeInstalled: true,
            onConfirm: () async => confirmations++,
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('40.7 MB'), findsNothing);
      await tester.tap(find.byKey(_promptConfirmKey));
      await tester.pumpAndSettle();

      expect(confirmations, 1);
      expect(result, isTrue);
    });
  });

  group('多选解包', () {
    const items = [
      ShellTargetItem(
        jarUrl: 'http://a/spring.jar',
        label: 'spring.jar',
        siteCount: 90,
        stateLabel: '需解包',
      ),
      ShellTargetItem(
        jarUrl: 'http://a/aegis.jar',
        label: 'aegis.jar',
        siteCount: 2,
        stateLabel: '需下载运行时',
      ),
      ShellTargetItem(
        jarUrl: 'http://a/done.jar',
        label: 'done.jar',
        siteCount: 1,
        stateLabel: '已解包',
        selected: false,
        disabled: true,
      ),
    ];

    testWidgets('默认全选、已解包置灰、返回选中集合', (tester) async {
      Set<String>? selected;
      await tester.pumpWidget(
        _host((context) async {
          selected = await showShellUnpackSelection(
            context,
            items: items,
            runtimeStateLabel: '解包运行时已安装。',
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('shell-unpack-selection')),
        findsOneWidget,
      );
      expect(find.text('解包运行时已安装。'), findsOneWidget);
      // 默认全选 = 所有可勾选项（已解包那项不算）。
      expect(find.text('开始解包（选中 2 项）'), findsOneWidget);

      final spring = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('shell-target-http://a/spring.jar')),
      );
      expect(spring.value, isTrue);
      expect(spring.onChanged, isNotNull);

      final done = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('shell-target-http://a/done.jar')),
      );
      expect(done.value, isFalse, reason: '已解包默认不勾选');
      expect(done.onChanged, isNull, reason: '已解包置灰，避免无意义重解');

      await tester.tap(
        find.byKey(const ValueKey('shell-unpack-selection-start')),
      );
      await tester.pumpAndSettle();

      expect(selected, {'http://a/spring.jar', 'http://a/aegis.jar'});
    });

    testWidgets('取消勾选后计数与返回值同步', (tester) async {
      Set<String>? selected;
      await tester.pumpWidget(
        _host((context) async {
          selected = await showShellUnpackSelection(
            context,
            items: items,
            runtimeStateLabel: null,
          );
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('shell-target-http://a/aegis.jar')),
      );
      await tester.pumpAndSettle();
      expect(find.text('开始解包（选中 1 项）'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('shell-unpack-selection-start')),
      );
      await tester.pumpAndSettle();
      expect(selected, {'http://a/spring.jar'});
    });

    testWidgets('取消返回 null', (tester) async {
      Set<String>? selected;
      var closed = false;
      await tester.pumpWidget(
        _host((context) async {
          selected = await showShellUnpackSelection(
            context,
            items: items,
            runtimeStateLabel: null,
          );
          closed = true;
        }),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('shell-unpack-selection-cancel')),
      );
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(selected, isNull);
      expect(
        find.byKey(const ValueKey('shell-unpack-selection')),
        findsNothing,
      );
    });
  });

  group('进度对话框', () {
    testWidgets('渲染 第 i/N · 阶段 · 百分比 · ETA（含 eta 为 null）', (tester) async {
      final ticks = StreamController<ShellUnpackTick>();
      addTearDown(() {
        if (!ticks.isClosed) ticks.close();
      });
      await tester.pumpWidget(
        _host(
          (context) => showShellUnpackProgress(
            context,
            jarCount: 2,
            ticks: ticks.stream,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();

      // 还没有 tick：总数已知，剩余时间算不出来。
      expect(find.text('第 1/2 个壳'), findsOneWidget);
      expect(find.text('阶段：准备中'), findsOneWidget);
      expect(find.text('预计剩余：计算中…'), findsOneWidget);

      ticks.add(
        ShellUnpackTick(
          jarIndex: 0,
          jarCount: 2,
          jarUrl: 'http://a/spring.jar',
          fraction: 0,
          stage: _readStage,
        ),
      );
      await tester.pump();
      expect(find.text('第 1/2 个壳'), findsOneWidget);
      expect(find.text('阶段：$_readStage'), findsOneWidget);
      expect(find.text('0%'), findsOneWidget);
      expect(find.text('预计剩余：计算中…'), findsOneWidget);

      ticks.add(
        ShellUnpackTick(
          jarIndex: 1,
          jarCount: 2,
          jarUrl: 'http://a/aegis.jar',
          fraction: 0.45,
          stage: _startStage,
          eta: Duration(seconds: 83),
        ),
      );
      await tester.pump();
      expect(find.text('第 2/2 个壳'), findsOneWidget);
      expect(find.text('阶段：$_startStage'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);
      expect(find.text('预计剩余：01:23'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('shell-unpack-progress-bar')),
      );
      expect(bar.value, closeTo(0.45, 1e-9));

      // 流没结束 = 还在跑：这时不提供关闭入口。
      expect(find.byKey(_progressCloseKey), findsNothing);
      await ticks.close();
      await tester.pump();
      expect(find.text('完成'), findsOneWidget);

      await tester.tap(find.byKey(_progressCloseKey));
      await tester.pumpAndSettle();
      expect(find.byKey(_progressKey), findsNothing);
    });

    for (final previousEta in <Duration?>[null, const Duration(seconds: 83)]) {
      testWidgets('探测成功结束清零剩余时间（${previousEta == null ? "未知估计" : "旧估计"}）', (
        tester,
      ) async {
        final ticks = StreamController<ShellUnpackTick>();
        addTearDown(() {
          if (!ticks.isClosed) ticks.close();
        });
        await tester.pumpWidget(
          _host(
            (context) => showShellUnpackProgress(
              context,
              jarCount: 95,
              ticks: ticks.stream,
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        ticks.add(
          ShellUnpackTick(
            jarIndex: 94,
            jarCount: 95,
            jarUrl: 'https://example.test/source.jar',
            fraction: 1,
            stage: '探测-完成',
            eta: previousEta,
          ),
        );
        await tester.pump();
        await ticks.close();
        await tester.pump();
        expect(find.text('100%'), findsOneWidget);
        expect(find.byKey(_progressCloseKey), findsOneWidget);
        expect(find.text('预计剩余：00:00'), findsOneWidget);
        expect(find.text('预计剩余：计算中…'), findsNothing);
        await tester.tap(find.byKey(_progressCloseKey));
        await tester.pumpAndSettle();
      });
    }

    testWidgets('失败停在失败态，显示阶段与原因且不会被静默关掉', (tester) async {
      final ticks = StreamController<ShellUnpackTick>();
      addTearDown(() {
        if (!ticks.isClosed) ticks.close();
      });
      await tester.pumpWidget(
        _host(
          (context) => showShellUnpackProgress(
            context,
            jarCount: 1,
            ticks: ticks.stream,
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();

      ticks.add(
        ShellUnpackTick(
          jarIndex: 0,
          jarCount: 1,
          jarUrl: 'http://a/spring.jar',
          fraction: 0.8,
          stage: _invokeStage,
        ),
      );
      await tester.pump();
      ticks.addError(StateError('unidbg 启动超时'));
      await tester.pump();

      expect(find.text('加固壳解包失败'), findsOneWidget);
      expect(find.textContaining('失败于阶段「$_invokeStage」'), findsOneWidget);
      expect(find.textContaining('unidbg 启动超时'), findsOneWidget);
      expect(find.byKey(_progressKey), findsOneWidget, reason: '失败不许静默关掉');
      expect(find.byKey(_progressCloseKey), findsOneWidget);

      await tester.tap(find.byKey(_progressCloseKey));
      await tester.pumpAndSettle();
      expect(find.byKey(_progressKey), findsNothing);
    });
  });

  group('待弹框信号', () {
    test('同一站点重复登记只留一个', () {
      final pending = PendingShellUnpack();
      expect(pending.stageSite('csp_AT'), isTrue);
      expect(pending.stageSite('csp_AT'), isFalse, reason: '幂等：不叠加第二个弹框');
      expect(pending.siteKey, 'csp_AT');
      expect(pending.takeSite(), 'csp_AT');
      expect(pending.siteKey, isNull);
      expect(pending.takeSite(), isNull, reason: '取走一次就没了');
      expect(pending.stageSite('csp_AT'), isTrue, reason: '取走后可再次登记');
    });

    test('同一批导入目标重复登记只留一个', () {
      final pending = PendingShellUnpack();
      const items = [
        ShellTargetItem(
          jarUrl: 'http://a/spring.jar',
          label: 'spring.jar',
          siteCount: 2,
          stateLabel: '需解包',
        ),
      ];
      expect(pending.stagePrompt(items), isTrue);
      expect(pending.stagePrompt(items), isFalse);
      expect(pending.prompt, hasLength(1));
      expect(pending.takePrompt(), hasLength(1));
      expect(pending.prompt, isNull);
      expect(pending.stagePrompt(const []), isFalse, reason: '空结果不登记');
    });

    test('AppState 钩子只看需要解包的站点，并默认勾选它所属 jar', () {
      final dir = Directory.systemTemp.createTempSync('webhtv-shell-pending');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': '${dir.path}/webhtv-pc',
            'data': '${dir.path}/webhtv-pc',
            'cache': '${dir.path}/webhtv-pc/cache',
            'state': '${dir.path}/webhtv-pc/logs',
          },
        ),
        log: LogService(),
      );
      addTearDown(state.dispose);
      state.debugSetShellTargets(const [
        ShellJarTarget(
          jarUrl: 'http://a/spring.jar',
          state: ShellTargetState.needsUnpack,
          siteKeys: ['csp_AT'],
        ),
        ShellJarTarget(
          jarUrl: 'http://a/done.jar',
          state: ShellTargetState.unpacked,
          siteKeys: ['csp_OLD'],
        ),
      ]);

      expect(state.pendingShellUnpackForSite, isNull);
      state.debugStageShellUnpackForSite('csp_AT');
      state.debugStageShellUnpackForSite('csp_AT');
      expect(state.pendingShellUnpackForSite, 'csp_AT', reason: '连点不叠加');

      final items = state.shellUnpackItems(preferSiteKey: 'csp_AT');
      expect(items.map((item) => item.jarUrl), [
        'http://a/spring.jar',
        'http://a/done.jar',
      ]);
      expect(items.first.siteCount, 1);
      expect(items.first.stateLabel, '需解包');
      expect(items.first.selected, isTrue, reason: '默认勾选用户点的那个站点所属 jar');
      expect(items.last.stateLabel, '已解包');
      expect(items.last.selected, isFalse);
      expect(items.last.disabled, isTrue);

      // 已解包的站点不再被问。
      state.debugStageShellUnpackForSite('csp_OLD');
      expect(state.pendingShellUnpackForSite, 'csp_AT');

      expect(state.takePendingShellUnpackForSite(), 'csp_AT');
      expect(state.pendingShellUnpackForSite, isNull);
    });
  });
}
