/// 详情页「换源」接线门禁（错误条 CTA → 浮层 → 并入 → 清空）。
///
/// 站点是 `type=1` HTTP API + 注入的假客户端：`testWidgets` 的 fake-async 区
/// 推不动真实 socket，注入 `httpClient` 是仓库既有的可测性口子
/// （`phase3_search_page_test.dart` 同一模式）。
///
/// 浮层打开时是无限旋转的加载指示器，`pumpAndSettle` 会 timeout，必须显式推帧。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

/// 站点配置：`主站[盘]` 承载详情页自己的线路（不可搜），`换源站[盘]` 可搜。
const String _configJson = '''
{
  "name": "详情换源测试",
  "sites": [
    {"key": "ui-main", "name": "主站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 0},
    {"key": "ui-swap", "name": "换源站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 1}
  ]
}
''';

void main() {
  late Directory tempDir;
  late AppState state;
  late _SwapSiteClient siteClient;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-detail-swap');
    siteClient = _SwapSiteClient();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
      ),
      log: LogService(),
      httpClient: siteClient,
    );
    // 详情页 `initState` 会碰 `state.tmdb`（TMDB 身份服务由 bootstrap 装配）。
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 显式推帧：浮层里的 `CircularProgressIndicator` 是无限动画，
  /// `pumpAndSettle` 必然 timeout。
  Future<void> pumpFrames(WidgetTester tester, {int times = 12}) async {
    for (var i = 0; i < times; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> prepare(WidgetTester tester) async {
    await tester.runAsync(() async {
      final ok = await state.importConfig(_configJson);
      expect(ok, isTrue, reason: '配置导入应成功');
    });
  }

  /// 详情页自己的条目：一条线路一集（外部线路两集，并入后应胜出）。
  Vod detailVod() => Vod(
    vodId: 'main-1',
    vodName: '换源目标影片',
    vodPlayFrom: 'orig',
    vodPlayUrl: '原第1集\$http://127.0.0.1:1/media/o1.mp4',
  );

  Future<void> pumpDetail(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: DetailPage(state: state, vod: detailVod())),
    );
    await pumpFrames(tester);
  }

  Future<void> scrollPastHero(WidgetTester tester) async {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await pumpFrames(tester, times: 4);
  }

  /// 打开浮层 → 勾选 → 解析 → 并入，走完整的真实接线。
  Future<void> swapInThroughSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('detail-swap-source')));
    await pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsOneWidget,
      reason: '错误条 CTA 必须升起换源浮层',
    );
    expect(
      find.byKey(const ValueKey('source-swap-row-ui-swap-swap-1')),
      findsOneWidget,
      reason: '浮层应搜到换源站的候选',
    );
    await tester.tap(
      find.byKey(const ValueKey('source-swap-check-ui-swap-swap-1')),
    );
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpFrames(tester);
    expect(
      find.textContaining('2 集'),
      findsWidgets,
      reason: '解析后该候选显示集数',
    );
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpFrames(tester);
  }

  testWidgets('错误条上有换源主 CTA，点开升起换源浮层', (tester) async {
    await prepare(tester);
    await pumpDetail(tester);

    expect(state.detailError, isNotNull, reason: '主站详情失败 → 应该出现错误条');
    expect(find.byType(ErrorBanner), findsOneWidget);
    expect(
      find.byKey(const ValueKey('detail-swap-source')),
      findsOneWidget,
      reason: '错误条必须给出「换源」这个动作',
    );

    await tester.tap(find.byKey(const ValueKey('detail-swap-source')));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('source-swap-sheet')), findsOneWidget);
  });

  testWidgets('勾选并解析后并入：外部线路带站点色点且被选中', (tester) async {
    await prepare(tester);
    await pumpDetail(tester);
    await swapInThroughSheet(tester);
    await scrollPastHero(tester);

    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsNothing,
      reason: '并入后浮层应关闭',
    );
    expect(
      find.byKey(const ValueKey('tmdb-line-external-换源站[盘] · ext')),
      findsOneWidget,
      reason: '外部线路行首必须有站点健康色点',
    );
    expect(
      find.textContaining('换源站[盘] · ext'),
      findsWidgets,
      reason: '外部线路以「站点名 · 原线路名」并入',
    );
    expect(
      find.textContaining('换源第1集'),
      findsWidgets,
      reason: '集数最多的外部线路应被选中（2 集 > 1 集）',
    );
    expect(
      find.byKey(const ValueKey('detail-clear-external')),
      findsOneWidget,
    );
  });

  testWidgets('清空外部线路：外部线路消失并回到默认线路', (tester) async {
    await prepare(tester);
    await pumpDetail(tester);
    await swapInThroughSheet(tester);
    await scrollPastHero(tester);

    await tester.tap(find.byKey(const ValueKey('detail-clear-external')));
    await pumpFrames(tester);
    await scrollPastHero(tester);

    expect(
      find.byKey(const ValueKey('tmdb-line-external-换源站[盘] · ext')),
      findsNothing,
      reason: '清空后外部线路必须从线路列表消失',
    );
    expect(
      find.byKey(const ValueKey('detail-clear-external')),
      findsNothing,
      reason: '没有外部线路时不应留下清空入口',
    );
    expect(
      find.textContaining('原第1集'),
      findsWidgets,
      reason: '清空后应回到默认（原）线路的集序',
    );
  });
}

/// 假站点客户端：`type=1` 的搜索与详情都走这里，不碰真实 socket。
class _SwapSiteClient extends http.BaseClient {
  /// 详情请求的 `ids` 参数（供断言「播放定向到哪个站点」时复用）。
  final List<String> detailIds = [];

  /// 搜索请求的 `wd` 参数。
  final List<String> searchKeywords = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final query = request.url.queryParameters;
    final keyword = query['wd'];
    Map<String, Object?> payload;
    if (keyword != null) {
      searchKeywords.add(keyword);
      payload = {
        'page': 1,
        'pagecount': 1,
        'limit': 20,
        'total': 1,
        'list': [
          {
            'vod_id': 'swap-1',
            'vod_name': '换源目标影片',
            'vod_pic': '',
            'vod_remarks': '',
          },
        ],
      };
    } else if (query['ac'] == 'detail') {
      final id = query['ids'] ?? '';
      detailIds.add(id);
      payload = id == 'swap-1'
          ? {
              'list': [
                {
                  'vod_id': 'swap-1',
                  'vod_name': '换源目标影片',
                  'vod_play_from': 'ext',
                  'vod_play_url':
                      '换源第1集\$http://127.0.0.1:1/media/e1.mp4#换源第2集\$http://127.0.0.1:1/media/e2.mp4',
                },
              ],
            }
          // 主站详情失败：错误条是换源 CTA 的入口，这里必须真的失败。
          : {'code': 1, 'msg': '站点业务错误:需要登录'};
    } else {
      payload = {'list': []};
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
    );
  }
}