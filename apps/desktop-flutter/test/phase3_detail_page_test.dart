/// 详情页渲染归属的 widget 门禁（设计文档 §8.3、§17.2 详情页）。
///
/// 与 `phase3_detail_race_test.dart` 的分工：那个文件用**真实 HTTP** 锁定
/// 「运行号丢弃迟到响应」「状态清理」「错误隔离」，运行在普通 async 区；本文件
/// 用注入的站点运行时锁定**渲染归属**，运行在 `testWidgets` 的 fake-async 区。
///
/// 为什么必须分开：`TestWidgetsFlutterBinding` 会把所有 `HttpClient` 请求
/// 固定返回 400（Flutter 测试框架的既有行为）。因此同一文件里只要出现
/// `testWidgets`，同文件的普通 `test()` 也拿不到真实网络。
///
/// 锁定的不变量：详情页是全局 `detailResult` 的**唯一消费者**，用户「返回列表
/// → 点另一部剧」时前一个请求可能还在飞行，页面必须按 `vod_id` 判归属，
/// 不属于本页就退回列表页传入的条目，绝不套用别的剧的线路与简介。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

void main() {
  late Directory tempDir;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-detail-ui');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Vod vodOf(String id, String name) => Vod(vodId: id, vodName: name);

  Future<void> pumpDetail(WidgetTester tester, Vod vod) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(state: state, vod: vod)),
    );
    await tester.pump();
  }

  testWidgets('结果不属于本页影片时退回列表条目，不套用别的剧', (tester) async {
    // 模拟「上一个详情页残留」：全局详情结果属于另一部剧，且当前站点不可用，
    // 因此本页自己的请求必然失败——页面更不能拿残留结果冒充成功。
    final seeded = Vod(
      vodId: 'other-1',
      vodName: '上一部剧',
      vodPlayFrom: '残留线路',
      vodPlayUrl: '第1集\$http://127.0.0.1:1/media/a.mp4',
    );
    state.seedDetailForTest(vod: seeded);

    final target = Vod(
      vodId: 'demo-1',
      vodName: '本页影片',
      vodPlayFrom: '本页线路',
      vodPlayUrl: '第1集\$http://127.0.0.1:1/media/b.mp4',
    );
    await pumpDetail(tester, target);

    expect(find.text('本页影片'), findsWidgets, reason: '必须显示本页传入的条目');
    expect(
      find.text('上一部剧'),
      findsNothing,
      reason: '残留的上一部剧详情不得渲染到本页',
    );
    expect(
      find.textContaining('本页线路'),
      findsWidgets,
      reason: '线路必须来自本页条目，而不是残留结果',
    );
  });

  testWidgets('详情结果属于本页影片时优先使用详情（含简介与线路）', (tester) async {
    final detailed = Vod(
      vodId: 'demo-1',
      vodName: '测试视频',
      vodContent: '来自详情的简介',
      vodPlayFrom: '详情线路',
      vodPlayUrl: '第1集\$http://127.0.0.1:1/media/a.mp4#第2集\$http://127.0.0.1:1/media/b.mp4',
    );
    state.seedDetailForTest(vod: detailed);

    // 列表条目只有基础字段：详情加载成功后应展示简介与两条剧集。
    await pumpDetail(tester, vodOf('demo-1', '列表条目'));
    await tester.pump();

    expect(find.textContaining('来自详情的简介'), findsWidgets);
    expect(find.textContaining('详情线路'), findsWidgets);
    expect(find.textContaining('2 集'), findsWidgets);
  });

  testWidgets('加载中且没有线路时显示进度指示，不显示「没有剧集」', (tester) async {
    // 详情请求尚未返回（本页条目没有任何线路）：必须是进度指示而非空态文案。
    state.seedDetailForTest(phase: LoadPhase.loading);
    await pumpDetail(tester, vodOf('demo-1', '待加载'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(find.textContaining('没有可播放的剧集'), findsNothing);
  });

  testWidgets('页面监听状态变更：详情完成后自动重建（不再停在转圈）', (tester) async {
    // 「第一次进去说没有线路、第二次一直转圈」的直接成因：详情页从未监听
    // AppState，请求在页面挂载后才完成，页面却不会重建。
    state.seedDetailForTest(phase: LoadPhase.loading);
    await pumpDetail(tester, vodOf('demo-1', '测试视频'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    // 详情到达（模拟请求完成）→ 页面必须自动重建并展示线路。
    state.seedDetailForTest(
      vod: Vod(
        vodId: 'demo-1',
        vodName: '测试视频',
        vodContent: '到达的简介',
        vodPlayFrom: '到达线路',
        vodPlayUrl: '第1集\$http://127.0.0.1:1/media/a.mp4',
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('到达的简介'), findsWidgets);
    expect(find.textContaining('到达线路'), findsWidgets);
  });

  testWidgets('返回按钮清空详情状态', (tester) async {
    final detailed = Vod(
      vodId: 'demo-1',
      vodName: '测试视频',
      vodPlayFrom: '详情线路',
      vodPlayUrl: '第1集\$http://127.0.0.1:1/media/a.mp4',
    );
    state.seedDetailForTest(vod: detailed);
    await pumpDetail(tester, vodOf('demo-1', '测试视频'));
    await tester.pump();
    expect(state.detailResult, isNotNull);

    await tester.tap(find.byTooltip('返回'));
    await tester.pump();

    expect(state.detailResult, isNull, reason: '离开详情页必须清空全局详情结果');
    expect(state.selectedVod, isNull);
    expect(state.detailPhase, LoadPhase.idle);
  });
}
