/// 跨源续播的第二阶段探测（docs/phase5/design/05 §7.3、§10）。
///
/// 锁一条用户可见行为：历史记录不在当前播放源时，PC 只在**当前配置**里找
/// 可替代站点（用户决定 3：不切源），并且**必须加载详情确认那一集存在**
/// 才自动播放。少了这一步，「同名片但只有 1 集」的候选会被当成能续播，
/// 用户点「继续观看」后进度迁移被 resumeEpisodeMatches 拒掉，落得从头播
/// ——这正是本轮要修的缺口。
///
/// ## 为什么用假 http 客户端
///
/// testWidgets 跑在 TestWidgetsFlutterBinding 下，dart:io 的 HttpClient 被框架
/// 固定返回 400，真实 socket 走不通；这里的被测流程又需要真实 AppState
/// （写库 + 站点服务）。注入 http.BaseClient 既绕开平台限制，又能让两个站点
/// 返回**不同**的详情（一个有第 2 集、一个没有），于是「谁被自动选中」本身
/// 就证明了探测确实发生了。
///
/// ## 为什么整段流程包在 runAsync 里
///
/// testWidgets 的函数体跑在 fake-async 区：真实 I/O 的完成回调不会投递，
/// 而这段流程要做写库 + 两次 HTTP。所以流程本身放在 tester.runAsync 里跑
/// （真实时钟），跑完再 pump 让推上去的页面真正构建。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/history_cross_source.dart';
import 'package:webhtv_pc/ui/search_page.dart';

/// 两个站点用不同路径，假客户端据此返回不同详情。
const String siteA = 'csp_a';
const String siteB = 'csp_b';

/// 历史记录来自一个**当前配置里不存在**的源（模拟「换了播放源 / 原站已删」）。
const String goneSource = 'bridge|dev-uuid-0001|gone';

/// 假站点客户端：搜索恒定返回同一条目；详情按站点的路径前缀返回不同集数。
class _FakeSiteClient extends http.BaseClient {
  /// 详情请求次数，用来断言「确实做了第二阶段探测」。
  int detailRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final query = request.url.queryParameters;
    final Object payload;
    if (query.containsKey('wd')) {
      payload = {
        'page': 1,
        'pagecount': 1,
        'limit': 20,
        'total': 1,
        'list': [
          {
            'vod_id': 'demo-1',
            'vod_name': '测试视频',
            'vod_pic': '',
            'vod_year': '2024',
            'vod_remarks': '更新至 2 集',
          },
        ],
      };
    } else if (query.containsKey('ids')) {
      detailRequests++;
      payload = {
        'list': [
          {
            'vod_id': 'demo-1',
            'vod_name': '测试视频',
            'vod_pic': '',
            'vod_year': '2024',
            'vod_play_from': '默认',
            // /b/ 那条有第 2 集，/a/ 那条只有第 1 集。
            'vod_play_url': path.contains('/b/')
                ? '第1集\$http://b/e1#第2集\$http://b/e2'
                : '第1集\$http://a/e1',
          },
        ],
      };
    } else {
      payload = {'class': [], 'list': []};
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
    );
  }
}

void main() {
  late Directory tempDir;
  late AppState state;
  late _FakeSiteClient client;

  String configJson(String baseUrl) => jsonEncode({
    'name': '跨源续播测试',
    'sites': [
      // a 在前：若 hasTargetEpisode 被硬编码成 true，被选中的会是 a。
      {
        'key': siteA,
        'name': '站A',
        'type': 1,
        'api': '$baseUrl/a/',
        'searchable': 1,
      },
      {
        'key': siteB,
        'name': '站B',
        'type': 1,
        'api': '$baseUrl/b/',
        'searchable': 1,
      },
    ],
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-cross-source');
    client = _FakeSiteClient();
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
      httpClient: client,
    );
    // bootstrap 必须在真实异步区里跑（打开数据库、读设置）；放进 testWidgets
    // 的假时钟区会让写库永不返回。
    await state.bootstrap();
    final imported = await state.importConfig(
      configJson('http://127.0.0.1:1/api/type1'),
    );
    expect(imported, isTrue, reason: '配置导入应成功');
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  PlaybackHistory itemAt(String episodeName, String episodeId, int id) =>
      PlaybackHistory(
        id: id,
        siteKey: 'csp_gone',
        vodId: 'gone-1',
        vodName: '测试视频',
        vodPic: '',
        flag: '线路一',
        episodeName: episodeName,
        episodeId: episodeId,
        positionMs: 180000,
        durationMs: 2400000,
        updatedAt: 1,
        sourceKey: goneSource,
        vodYear: '2024',
      );

  /// 起一个带 Material 祖先的空壳页面，返回可用作 BuildContext 的元素。
  ///
  /// Material 由 MaterialApp.builder 提供：SearchPage 自己不带 Scaffold，
  /// 而它被 push 成一条新路由时若上层没有 Material，TextField 会直接报
  /// 「No Material widget found」。
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Material(child: child ?? const SizedBox()),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pump();
    return tester.element(find.byType(Scaffold));
  }

  /// 在真实时钟里跑完一次「点历史卡片」的完整流程，再把结果 pump 出来。
  ///
  /// 不 await 那个入口：命中候选后它会 await 详情页的 push，直到用户返回
  /// 才解析，await 会直接挂住。
  Future<void> runOpen(
    WidgetTester tester,
    BuildContext context,
    PlaybackHistory item,
  ) async {
    await tester.runAsync(() async {
      openHistoryFromOtherSource(context, state, item);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('第二阶段探测：只有「有第 2 集」的那个站点会被自动选中（回归）', (tester) async {
    final context = await pumpHost(tester);

    await runOpen(tester, context, itemAt('第2集', 'http://gone/e2', 1));

    expect(
      client.detailRequests,
      greaterThan(0),
      reason: '必须加载详情才知道候选有没有那一集',
    );
    expect(
      state.selectedSite?.key,
      siteB,
      reason: '站A 只有第 1 集、站B 有第 2 集；按输入顺序站A 在前，'
          '若 hasTargetEpisode 被硬编码成 true 就会选错站',
    );
  });

  testWidgets('两个站点都没有那一集 → 不自动播放，改为提示用户自己选', (tester) async {
    final context = await pumpHost(tester);

    // 原记录在第 5 集：两个站点都只有 1~2 集，必然对不上。
    await runOpen(tester, context, itemAt('第5集', 'http://gone/e5', 2));

    expect(
      find.byKey(const ValueKey('history-cross-source-dialog')),
      findsOneWidget,
      reason: '没有能接上这一集的站点时必须让用户自己选，不能猜',
    );
    expect(state.selectedSite?.key, isNot(siteB), reason: '不得自动切站播放');
  });

  testWidgets('全局搜索兜底把续播上下文带进搜索页（否则选完片又从头播）', (tester) async {
    final context = await pumpHost(tester);
    await runOpen(tester, context, itemAt('第5集', 'http://gone/e5', 3));

    final button = find.byKey(
      const ValueKey('history-cross-source-open-search'),
    );
    expect(button, findsOneWidget, reason: '兜底对话框必须先出现');
    await tester.tap(button);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final page = tester.widget<SearchPage>(find.byType(SearchPage));
    expect(page.initialKeyword, '测试视频');
    expect(
      page.resumeSeed,
      isNotNull,
      reason: '搜索页拿不到续播种子，用户选完片后进度就丢了',
    );
    expect(page.resumeSeed!.episodeName, '第5集');
  });
}