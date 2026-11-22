/// 从播放页返回详情页时，历史必须立刻反映刚才的播放（用户 2026-11-29 实报）。
///
/// 复现形状与真实时序一致：
/// 1. 播放器在自己的 `dispose()` 里写最后一条进度——那是 **pop 之后**（pop 动画结束、
///    路由被移除）才发生的；
/// 2. `AppState.recordProgress` 写完**不通知**监听者；
/// 3. 详情页只在 build 里查库，没有任何「数据变了」的钩子。
///
/// 于是返回详情页时：要么页面没重建，要么重建发生在写库之前——角标和首屏文案
/// 都停在进播放器之前。本用例把「写库 → 详情页刷新」这条契约钉住。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

import 'support/detail_test_seams.dart';

/// 假的播放页：只在 `dispose()` 里写进度，与 `PlayerPage` 的真实时序一致。
class _FakePlayerPage extends StatefulWidget {
  const _FakePlayerPage({
    required this.state,
    required this.vod,
    required this.sourceKey,
  });

  final AppState state;
  final Vod vod;
  final String sourceKey;

  @override
  State<_FakePlayerPage> createState() => _FakePlayerPageState();
}

class _FakePlayerPageState extends State<_FakePlayerPage> {
  @override
  void dispose() {
    widget.state.recordProgress(
      vod: widget.vod,
      flag: '线路一',
      episodeName: '第2集',
      episodeId: 'http://x/e2',
      position: const Duration(seconds: 40),
      duration: const Duration(seconds: 100),
      siteKey: 'site-a',
      sourceKey: widget.sourceKey,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('播放器')));
}

void main() {
  late Directory tempDir;
  late AppState state;
  late String sourceKey;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-detail-refresh');
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: MemoryOnlyLogService(),
      httpClient: MockClient((request) async =>
          http.Response(jsonEncode(<String, Object?>{'list': []}), 200)),
    );
    await bootstrapWithoutExternalMeta(state);
    final ok = await state.importConfig(
      jsonEncode(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{
            'key': 'site-a',
            'name': '甲站',
            'type': 3,
            'api': 'c1',
            'searchable': 1,
            'quickSearch': 1,
            'filter': 0,
          },
        ],
      }),
      displayName: '测试源',
    );
    expect(ok, isTrue, reason: '前置：配置导入必须成功');
    await state.selectSite(state.siteByKey('site-a')!);
    sourceKey = state.activeSourceKey;
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  final vod = Vod(
    vodId: 'a-1',
    vodName: '剧集甲',
    vodPlayFrom: '线路一',
    vodPlayUrl: '第1集\$http://x/e1#第2集\$http://x/e2',
  );

  Future<void> pumpDetail(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    state.seedDetailForTest(vod: vod);
    await tester.pumpWidget(MaterialApp(home: DetailPage(state: state, vod: vod)));
    await tester.pump();
    for (var attempt = 0; attempt < 20; attempt++) {
      if (find.byKey(const ValueKey('tmdb-episode-card-线路一-0')).evaluate().isNotEmpty) {
        break;
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await tester.pump();
    }
  }

  testWidgets('从播放页返回后，详情页的历史标记与首屏文案立刻更新', (tester) async {
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: vod.vodId,
      vodName: vod.vodName,
      flag: '线路一',
      episodeName: '第1集',
      episodeId: 'http://x/e1',
      positionMs: 30000,
      durationMs: 100000,
      updatedAt: 100,
      sourceKey: sourceKey,
    );
    await pumpDetail(tester);
    expect(find.text('继续播放 · 第1集'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-0')),
      findsOneWidget,
    );

    // 进播放页再返回：播放页在 dispose 里写第 2 集的进度（pop 之后才发生）。
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => _FakePlayerPage(
          state: state,
          vod: vod,
          sourceKey: sourceKey,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('播放器'), findsOneWidget);

    navigator.pop();
    await tester.pumpAndSettle();

    expect(
      find.text('继续播放 · 第2集'),
      findsOneWidget,
      reason: '播放页退出时写的那条进度必须反映到首屏文案上',
    );
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-1')),
      findsOneWidget,
      reason: '角标要挪到第 2 集',
    );
  });

  testWidgets('详情页可见时写进度，角标与文案立刻更新（不依赖离开页面）', (tester) async {
    // 与「从播放页返回」分开：这条锁的是「写库 → 刷新」本身，而不是某条路由时序。
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: vod.vodId,
      vodName: vod.vodName,
      flag: '线路一',
      episodeName: '第1集',
      episodeId: 'http://x/e1',
      positionMs: 30000,
      durationMs: 100000,
      updatedAt: 100,
      sourceKey: sourceKey,
    );
    await pumpDetail(tester);
    expect(find.text('继续播放 · 第1集'), findsOneWidget);

    state.recordProgress(
      vod: vod,
      flag: '线路一',
      episodeName: '第2集',
      episodeId: 'http://x/e2',
      position: const Duration(seconds: 40),
      duration: const Duration(seconds: 100),
      siteKey: 'site-a',
      sourceKey: sourceKey,
    );
    await tester.pumpAndSettle();

    expect(find.text('继续播放 · 第2集'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-recent-1')),
      findsOneWidget,
    );
  });
}
