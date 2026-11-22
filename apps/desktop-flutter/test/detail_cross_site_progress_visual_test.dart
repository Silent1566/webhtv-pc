/// 跨爬虫源进度标记的**视觉证据**（`design/02` §9）。
///
/// 为什么要有它：角标是叠在剧照上的第三色小标签，最容易出的问题不是逻辑错，
/// 而是**看不清/压住别的角标/在窄卡上溢出**——这些只有渲染出来才看得见。
/// 用例把详情页（本站 + 别的源两种角标）与「选择续播记录」弹框各截一张图，
/// 落到 `.local/detail-cross-site-progress/`，供人工验收与回归对比。
///
/// 断言只做「确实渲染出来了」（不存在异常、角标与弹框都在），像素级比对不是
/// 本用例的职责：主题/字体在 CI 与开发机之间不同，硬比会变成噪声。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

import 'support/detail_test_seams.dart';
import 'support/test_fonts.dart';

void main() {
  setUpAll(() async {
    await loadFixtureFonts();
  });

  late Directory tempDir;
  late AppState state;
  late String sourceKey;
  final captureKey = GlobalKey();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-cross-site-visual');
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
          <String, Object?>{
            'key': 'site-b',
            'name': '乙站',
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
    expect(ok, isTrue);
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
    vodPlayUrl: '第1集\$http://x/e1#第2集\$http://x/e2#第3集\$http://x/e3',
  );

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.local/detail-cross-site-progress/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('截图：两种角标的详情页 + 选择续播记录弹框', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    // 本站：第 1 集看过一半；别的源：第 3 集看得更多也更新。
    state.database!.upsertHistory(
      siteKey: 'site-a',
      vodId: vod.vodId,
      vodName: vod.vodName,
      flag: '线路一',
      episodeName: '第1集',
      episodeId: 'http://x/e1',
      positionMs: 900000,
      durationMs: 2400000,
      updatedAt: DateTime.now().millisecondsSinceEpoch - 24 * 3600 * 1000,
      sourceKey: sourceKey,
    );
    state.database!.upsertHistory(
      siteKey: 'site-b',
      vodId: 'b-1',
      vodName: vod.vodName,
      flag: '乙站线路',
      episodeName: '第3集',
      episodeId: 'http://b/e3',
      positionMs: 1500000,
      durationMs: 2400000,
      updatedAt: DateTime.now().millisecondsSinceEpoch - 3 * 3600 * 1000,
      sourceKey: sourceKey,
    );
    state.seedDetailForTest(vod: vod);
    await tester.pumpWidget(
      MaterialApp(
        // 测试字体加载成 FixtureCJK 家族：不指定 family 时中文会渲染成方块，
        // 截图就没有验收价值（字宽/换行也不是真实结果）。
        theme: ThemeData(fontFamily: 'FixtureCJK'),
        // 边界包在 Navigator 外面：弹框走 Overlay，只包 home 会截不到它。
        builder: (context, child) =>
            RepaintBoundary(key: captureKey, child: child!),
        home: DetailPage(state: state, vod: vod),
      ),
    );
    await tester.pump();
    // 把选集区滚进视口再截图：hero 占满首屏，不滚只会截到它。
    for (var attempt = 0; attempt < 30; attempt++) {
      final strip = find.byKey(const ValueKey('tmdb-episode-card-线路一-0'));
      if (strip.evaluate().isNotEmpty) {
        final box = tester.getRect(strip);
        if (box.top > 40 && box.bottom < 960) break;
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -240));
      await tester.pump();
    }
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-线路一-foreign-2')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await capture(tester, 'after-detail');

    await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-progress-dialog')), findsOneWidget);
    await capture(tester, 'after-picker');
  });
}
