/// 详情页竞态的真实窗口端到端验收（设计文档 §8.3、§17.2）。
///
/// 复现用户实测的操作序列：**详情 A → 返回列表 → 立刻点详情 B**。修复前详情请求
/// 没有运行号、详情页也不校验结果归属，于是：
/// - 第一次点进去「没有线路」（详情还没回来，页面已按空数据渲染）；
/// - 第二次一直转圈（旧的失败/空结果与在途请求交织）；
/// - 第三次才看到线路，而且**返回后点其他剧看到的还是上一部剧的信息**。
///
/// 前置条件：本机 fixture 服务已启动（`py -m tools.fixture_server.server`，端口
/// 18080），详见 `docs/phase3/README.md`。fixture 提供 `ids=slow-*` 的慢详情样本，
/// 用于在真实窗口里构造「先发后到」的竞态。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

/// 与既有集成测试同口径的可复查事实行（便于验收脚本统一采集）。
void evidence(String message) => debugPrint('PHASE3-EVIDENCE detail-race $message');

/// 在真实 async 区推进 I/O，直到 [until] 成立或超时。
///
/// `testWidgets` 的 fake-async 区推不动真实 socket I/O，因此必须借
/// `tester.runAsync`；而用固定延迟等待结果会随机器负载变脆（批量跑套件时
/// 曾因固定 2s 不够而间歇失败），所以改为轮询 + 超时。
Future<void> drainRealIo(
  WidgetTester tester, {
  required bool Function() until,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (until()) return;
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
  }
}

/// 最小导航宿主：两个按钮各自 `Navigator.push` 一个 [DetailPage]。
///
/// 必须走真实导航路径：连续两次 `pumpWidget(MaterialApp(home: DetailPage(...)))`
/// 时，同类型同位置的 widget 会被 Flutter **更新而不是重建**，`initState` 不再
/// 触发，第二个页面的详情请求根本不会发出（本用例初次编写时就撞上这点）。
/// 产品里详情页始终由 `Navigator.push` 打开，因此这里用同一语义。
class _NavHost extends StatelessWidget {
  const _NavHost({required this.state, required this.vods});

  final AppState state;
  final List<Vod> vods;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final vod in vods)
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => DetailPage(state: state, vod: vod),
                  ),
                ),
                child: Text('打开 ${vod.vodName}'),
              ),
          ],
        ),
      ),
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const base = 'http://127.0.0.1:18080';

  testWidgets('详情 A → 返回 → 立刻详情 B：B 的线路与简介不被 A 覆盖', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-detail-race-e2e');
    final paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
    final state = AppState(paths: paths, log: LogService());
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    await state.bootstrap();

    final imported = await state.importConfig(
      jsonEncode({
        'name': '详情竞态 e2e',
        'sites': [
          {
            'key': 'nodejs_race',
            'name': '竞态站点',
            'type': 1,
            'api': '$base/api/type1/',
            'searchable': 1,
          },
        ],
      }),
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);

    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // ---- 第一步：打开 A 剧（慢详情，1.2s 才回来），随即返回列表 ----
    final aVod = Vod(vodId: 'slow-A', vodName: 'A 剧（慢）');
    final bVod = Vod(vodId: 'demo-1', vodName: 'B 剧（快）');
    await tester.pumpWidget(
      MaterialApp(home: _NavHost(state: state, vods: [aVod, bVod])),
    );
    await tester.pump();

    await tester.tap(find.text('打开 ${aVod.vodName}'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPage), findsOneWidget);
    // 用户看到「没有线路」/转圈后点返回（此时 A 的请求仍在飞行）。
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(state.detailResult, isNull, reason: '离开详情页即清空，且 A 的在途请求被作废');
    evidence('leave-a cleared=true');

    // ---- 第二步：立刻打开 B 剧（普通详情，即时返回）----
    await tester.tap(find.text('打开 ${bVod.vodName}'));
    await tester.pump();
    // 等真实 I/O：先在真实 async 区轮询 B 的详情落定（不靠固定眠）。
    await drainRealIo(tester, until: () => state.detailResult != null);
    // B 落定后再多等一段，**蹇过 A 的慢响应窗口**（slow- 样本 1.2s），
    // 否则「A 不覆盖 B」这一断言可能只是碰巧在 A 返回前就跑了。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1800));
    });
    await tester.pumpAndSettle();

    // B 的详情必须落定，且不是 A 的内容。
    expect(
      state.detailResult?.list.first.vodId,
      'demo-1',
      reason: 'A 的迟到响应不得覆盖 B；这是用户实测的「点其他剧还是上一部剧」根因',
    );
    expect(
      find.textContaining('慢详情'),
      findsNothing,
      reason: 'A 剧内容不得出现在 B 剧页面上',
    );
    final lines = state.playLinesOf(state.detailResult!.list.first);
    expect(lines, isNotEmpty, reason: 'B 剧必须有可用线路（不再是「没有线路」）');
    expect(find.textContaining(lines.first.displayName), findsWidgets);
    evidence(
      'render-b vod=${state.detailResult!.list.first.vodId} '
      'lines=${lines.length} episodes=${lines.first.episodes.length} '
      'no-stale-a=true',
    );

    // ---- 第三步：返回后再次进入，不得残留上一部剧 ----
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(state.detailResult, isNull);
    expect(state.selectedVod, isNull);
    evidence('leave-b cleared=true');
  });
}
