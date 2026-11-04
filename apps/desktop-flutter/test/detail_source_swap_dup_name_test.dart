/// 同名但不同 key 的两个站点，换源并入后的健康色必须各显各的（回归门禁）。
///
/// 修复前的 `_siteStatusByKey()` 先按 `magnitude.name` 建表、再用
/// `item.site.name` 反查：两个**同名不同 key** 的站点会落在同一个名称键上
/// 互相覆盖，一个站的行尾色点显示成另一个站的健康度。这条测试锁定"按 key
/// 建表"这一条：`dup-a` 实测全失败（失效色）、`dup-b` 全成功（可用色），
/// 两个色点的颜色必须**不相等**。
///
/// 站点是 `type=1` HTTP API + 注入的假客户端（`testWidgets` 的 fake-async
/// 推不动真实 socket；`test/detail_source_swap_test.dart` 同一模式）。
/// 浮层里的加载指示器是无限动画，`pumpAndSettle` 会 timeout，必须显式推帧。
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
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/source_field.dart';

/// 两个可搜站点**共用**同一个显示名：这正是缺陷的触发条件。
const String _dupName = '同名站[盘]';

/// `dup-main` 只承载详情页自己的线路（不可搜）；
/// `dup-a` / `dup-b` 同名、可搜、api 用不同路径以便假客户端分流。
const String _configJson = '''
{
  "name": "同名站点健康色测试",
  "sites": [
    {"key": "dup-main", "name": "主站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/main/", "searchable": 0},
    {"key": "dup-a", "name": "同名站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/a/", "searchable": 1},
    {"key": "dup-b", "name": "同名站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/b/", "searchable": 1}
  ]
}
''';

/// 并入后的页面内 flag：`站点名 · 原线路名`（见 `core/source_swap.dart`）。
const String _flagA = '$_dupName · sa';
const String _flagB = '$_dupName · sb';

void main() {
  late Directory tempDir;
  late AppState state;
  late _DupNameSiteClient siteClient;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-dup-name');
    siteClient = _DupNameSiteClient();
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

  /// 显式推帧：浮层里的 `CircularProgressIndicator` 是无限动画。
  Future<void> pumpFrames(WidgetTester tester, {int times = 12}) async {
    for (var i = 0; i < times; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 导入配置 + 把两个同名站点的健康度**真的种进 DB**。
  ///
  /// 判级规则（`lib/ui/source_field.dart` 的 `buildMagnitudes`）：
  /// rate >= 0.8 → ok；rate == 0 且 samples >= 3 → failed。
  /// 所以 `dup-a` 连记 3 次失败 → failed，`dup-b` 连记 3 次成功 → ok。
  Future<void> prepare(WidgetTester tester) async {
    await tester.runAsync(() async {
      final ok = await state.importConfig(_configJson);
      expect(ok, isTrue, reason: '配置导入应成功');
      final database = state.database!;
      for (var i = 0; i < 3; i += 1) {
        database.recordHealth(
          siteKey: 'dup-a',
          action: HealthAction.detail,
          success: false,
          error: '连接超时',
        );
        database.recordHealth(
          siteKey: 'dup-b',
          action: HealthAction.detail,
          success: true,
        );
      }
    });
  }

  /// 站源健康态（与 `_siteStatusByKey()` 同一个换算入口）。
  Map<String, SourceStatus> statusByKey() => {
    for (final magnitude in buildMagnitudes(
      items: state.siteItems,
      health: {
        for (final row in state.siteHealth()) row.siteKey: row,
      },
    ))
      magnitude.siteKey: magnitude.status,
  };

  Vod detailVod() => Vod(
    vodId: 'main-1',
    vodName: '同名健康色目标影片',
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

  /// 外部线路行的 6px 色点颜色（`tmdb_detail_view.dart` 的 `BoxDecoration`）。
  Color dotColorOf(WidgetTester tester, String flag) {
    final dot = tester.widget<Container>(
      find.byKey(ValueKey('tmdb-line-external-$flag')),
    );
    return (dot.decoration! as BoxDecoration).color!;
  }

  testWidgets('同名不同 key 的两个站点并入后健康色必须不同', (tester) async {
    await prepare(tester);

    // 前置条件（与 UI 无关）：两站名称相同、key 不同，健康态必须已经分成两态。
    expect(state.siteItems.where((item) => item.site.name == _dupName), hasLength(2));
    final seeded = statusByKey();
    expect(
      seeded['dup-a'],
      SourceStatus.failed,
      reason: 'dup-a 连错 3 次 → 失效',
    );
    expect(seeded['dup-b'], SourceStatus.ok, reason: 'dup-b 连成 3 次 → 可用');

    await pumpDetail(tester);
    expect(state.detailError, isNotNull, reason: '主站详情失败 → 应该出现错误条');

    // 打开浮层 → 勾选两行 → 解析所选 → 并入。
    await tester.tap(find.byKey(const ValueKey('detail-swap-source')));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('source-swap-sheet')), findsOneWidget);
    for (final suffix in ['dup-a-a-1', 'dup-b-b-1']) {
      final checkbox = find.byKey(ValueKey('source-swap-check-$suffix'));
      expect(checkbox, findsOneWidget, reason: '浮层应搜到 $suffix 这个候选');
      await tester.tap(checkbox);
      await pumpFrames(tester, times: 4);
    }
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpFrames(tester);
    await scrollPastHero(tester);

    // 两个色点都在：同名不同 key → 两条独立的外部线路行。
    final dotA = find.byKey(const ValueKey('tmdb-line-external-$_flagA'));
    final dotB = find.byKey(const ValueKey('tmdb-line-external-$_flagB'));
    expect(dotA, findsOneWidget, reason: 'dup-a 的线路行必须有色点');
    expect(dotB, findsOneWidget, reason: 'dup-b 的线路行必须有色点');

    // 期望色由主题现算，不硬编码颜色常量。
    final context = tester.element(dotA);
    expect(
      dotColorOf(tester, _flagA),
      sourceStatusColor(context, SourceStatus.failed),
      reason: 'dup-a 的健康色应是「失效」',
    );
    expect(
      dotColorOf(tester, _flagB),
      sourceStatusColor(context, SourceStatus.ok),
      reason: 'dup-b 的健康色应是「可用」',
    );
    expect(
      dotColorOf(tester, _flagA) == dotColorOf(tester, _flagB),
      isFalse,
      reason: '同名不同 key 的两个站点绝不能共用一个健康色（按名称中转会互相覆盖）',
    );
  });
}

/// 假站点客户端：`type=1` 的搜索与详情都走这里，不碰真实 socket。
///
/// 三个站点共用 host，只能按 `url.path` 分流（api 路径不同）。
class _DupNameSiteClient extends http.BaseClient {
  /// 每次请求的 `path?query`，便于失败时定位是谁发的。
  final List<String> calls = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls.add('${request.url.path}?${request.url.query}');
    final path = request.url.path;
    final query = request.url.queryParameters;
    final keyword = query['wd'];
    Map<String, Object?> payload;
    if (keyword != null) {
      if (path.startsWith('/api/a/')) {
        payload = _hits('a-1', '同名站候选 A');
      } else if (path.startsWith('/api/b/')) {
        payload = _hits('b-1', '同名站候选 B');
      } else {
        payload = {'list': <Object?>[]};
      }
    } else if (query['ac'] == 'detail') {
      final id = query['ids'] ?? '';
      if (path.startsWith('/api/a/') && id == 'a-1') {
        payload = _detail(
          vodId: 'a-1',
          vodName: '同名站候选 A',
          playFrom: 'sa',
          episodeName: 'A 第1集',
          media: 'a1.mp4',
        );
      } else if (path.startsWith('/api/b/') && id == 'b-1') {
        payload = _detail(
          vodId: 'b-1',
          vodName: '同名站候选 B',
          playFrom: 'sb',
          episodeName: 'B 第1集',
          media: 'b1.mp4',
        );
      } else {
        // 主站详情失败：错误条是换源 CTA 的入口，这里必须真的失败。
        payload = {'code': 1, 'msg': '站点业务错误:需要登录'};
      }
    } else {
      payload = {'list': <Object?>[]};
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
    );
  }

  static Map<String, Object?> _hits(String vodId, String vodName) => {
    'page': 1,
    'pagecount': 1,
    'limit': 20,
    'total': 1,
    'list': [
      {'vod_id': vodId, 'vod_name': vodName, 'vod_pic': '', 'vod_remarks': ''},
    ],
  };

  static Map<String, Object?> _detail({
    required String vodId,
    required String vodName,
    required String playFrom,
    required String episodeName,
    required String media,
  }) => {
    'list': [
      {
        'vod_id': vodId,
        'vod_name': vodName,
        'vod_play_from': playFrom,
        'vod_play_url': '$episodeName\$http://127.0.0.1:1/media/$media',
      },
    ],
  };
}
