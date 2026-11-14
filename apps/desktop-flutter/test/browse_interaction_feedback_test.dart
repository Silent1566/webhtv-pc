/// 浏览页（分类条 / 筛选 / 刷新）**实际等待状态**门禁。
///
/// 用户诉求：真实等待要看得见，但不得人为拖长等待、不得隐藏默认内容、
/// 不得整页阻塞。
///
/// 已核实的现状（`lib/ui/browse_pages.dart`）：
/// - 分类切换：`loadCategory` 同步清空列表并置 `LoadPhase.loading`
///   （`app_state.dart:3612-3620`），网格渲染 `LoadingBlock`（`:857-864`）
///   ——**已有可见等待态，本文件只锁住它不被这次改动破坏**；
/// - **首页刷新**：`loadHome` 保留旧列表（不闪空），只压一条
///   `LinearProgressIndicator`，而它被放在 `slivers` 的**最后一个 slot**
///   （`:887-893`，网格之后、页脚之前）——网格填满视口时它落在视口之外，
///   首页刷新期间用户**看不到任何变化**。这是本次唯一要补的明确缺口：
///   等待态必须出现在首屏视口内；
/// - 筛选：`setCategoryFilter` 立刻改筛选值并重载（走分类路径，有 loading），
///   且 `_FilterPanelBody` 刻意**不禁用** chip（`:579-589`）。这次不改它，
///   只锁住「等待中仍可交互」。
///
/// **绝不用 `pumpAndSettle`**：`LoadingBlock` / 进度条都是无限动画。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/common.dart';

/// 首页刷新等待态在首屏出现的标记 key。
const ValueKey<String> _refreshBusyKey = ValueKey('browse-refresh-busy');

const String _configJson = '''
{
  "name": "浏览反馈测试",
  "sites": [
    {"key": "fb-site", "name": "反馈站[盘]", "type": 1, "api": "http://127.0.0.1:19978/vod/api?key=fb-site", "searchable": 0, "filterable": 1}
  ]
}
''';

/// 可控假站点客户端：响应可被 `hold` 挂住，用来构造真实等待态。
class _HoldingClient extends http.BaseClient {
  /// 非 null 时挂住响应（构造「在途」）。
  Completer<void>? hold;

  /// 首页请求次数。
  int homeRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final gate = hold;
    if (gate != null) await gate.future;
    final query = request.url.queryParameters;
    final payload = query.containsKey('t')
        ? _categoryPayload(query['t']!)
        : _homePayload();
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
    );
  }

  Map<String, Object?> _homePayload() {
    homeRequests += 1;
    return {
      'class': [
        {'type_id': '1', 'type_name': '电影'},
        {'type_id': '2', 'type_name': '电视剧'},
      ],
      'list': [
        {
          'vod_id': 'home-1',
          'vod_name': '首页影片一',
          'vod_pic': '',
          'vod_remarks': '2024',
        },
        {
          'vod_id': 'home-2',
          'vod_name': '首页影片二',
          'vod_pic': '',
          'vod_remarks': '2025',
        },
      ],
      'filters': {
        '1': [
          {
            'key': 'class',
            'name': '剧情',
            'value': [
              {'n': '全部', 'v': ''},
              {'n': '喜剧', 'v': '喜剧'},
            ],
          },
        ],
      },
      'page': 1,
      'pagecount': 1,
      'total': 2,
    };
  }

  Map<String, Object?> _categoryPayload(String typeId) => {
    'class': [
      {'type_id': '1', 'type_name': '电影'},
    ],
    'list': [
      {'vod_id': 'cat-$typeId-1', 'vod_name': '分类$typeId影片一', 'vod_pic': ''},
    ],
    'filters': {
      typeId: [
        {
          'key': 'class',
          'name': '剧情',
          'value': [
            {'n': '全部', 'v': ''},
            {'n': '喜剧', 'v': '喜剧'},
          ],
        },
      ],
    },
    'page': 1,
    'pagecount': 1,
    'total': 1,
  };
}

void main() {
  late Directory tempDir;
  late AppState state;
  late _HoldingClient client;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-browse-feedback');
    client = _HoldingClient();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
      ),
      log: LogService(),
      httpClient: client,
    );
  });

  tearDown(() async {
    // 挂起的请求若未放行，会让 tearDown 的目录删除撞上在途 I/O。
    client.hold?.complete();
    client.hold = null;
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 导入配置（真实 I/O 必须在 `runAsync` 里推进；导入会自动加载首页）。
  Future<void> prepare(WidgetTester tester) async {
    await tester.runAsync(() async {
      final ok = await state.importConfig(_configJson);
      expect(ok, isTrue, reason: '配置导入应成功');
    });
  }

  Future<void> pumpPage(WidgetTester tester, {bool reduce = false}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        // 用 copyWith，避免裸 `MediaQueryData` 把 size 变成 0×0。
        builder: reduce
            ? (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  disableAnimations: true,
                  accessibleNavigation: true,
                ),
                child: child!,
              )
            : null,
        // 真实壳里 `BrowsePage` 由订阅 `AppState` 的父级重建（`app.dart`）。
        // 直接 pump 它不会重建，`loadHome`/`loadCategory` 的 notifyListeners
        // 就无从反映到帧上——那是夹具缺陷，不是产品缺陷。
        home: Scaffold(
          body: ListenableBuilder(
            listenable: state,
            builder: (_, _) => BrowsePage(state: state),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// 显式推帧（页面里有无限动画，不能用 `pumpAndSettle`）。
  Future<void> pumpFrames(WidgetTester tester, {int times = 6}) async {
    for (var i = 0; i < times; i += 1) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 放行挂住的请求并等页面稳定。
  Future<void> release(WidgetTester tester) async {
    client.hold?.complete();
    client.hold = null;
    await pumpFrames(tester);
  }

  testWidgets('首页刷新：等待态必须在首屏视口内可见，且旧内容不被隐藏', (tester) async {
    await prepare(tester);
    await pumpPage(tester);
    expect(find.text('首页影片一'), findsOneWidget, reason: '前置条件：首页有内容');

    // 挂住下一次请求 → 点刷新 → 真实在途。
    client.hold = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('browse-refresh')));
    await tester.pump();
    await pumpFrames(tester, times: 2);

    expect(
      find.byKey(_refreshBusyKey),
      findsOneWidget,
      reason: '首页刷新必须有**首屏可见**的等待态：原来那条进度条被放在 slivers 末尾'
          '（网格之后），网格填满视口时落在视口外，用户看不到任何反应',
    );
    // 首屏可见性：控件矩形必须与视口相交。
    final rect = tester.getRect(find.byKey(_refreshBusyKey));
    expect(
      rect.top < 900 && rect.bottom > 0,
      isTrue,
      reason: '等待态必须在视口内（rect=$rect），不能落在滚动内容尾部',
    );
    expect(
      find.text('首页影片一'),
      findsOneWidget,
      reason: '刷新期间旧内容不得被隐藏/清空（不能整页闪空）',
    );

    await release(tester);
    expect(
      find.byKey(_refreshBusyKey),
      findsNothing,
      reason: '刷新完成后等待态必须消失',
    );
    expect(find.text('首页影片一'), findsOneWidget, reason: '刷新完成后内容仍在');
  });

  testWidgets('刷新入口在等待中禁用（既有行为，防回归）', (tester) async {
    await prepare(tester);
    await pumpPage(tester);

    client.hold = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('browse-refresh')));
    await tester.pump();
    await pumpFrames(tester, times: 2);

    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('browse-refresh')))
          .onPressed,
      isNull,
      reason: '等待中刷新按钮必须禁用（防重复请求）',
    );

    await release(tester);
  });

  testWidgets('筛选：等待期间 chip 仍可交互（既有约定，防回归）', (tester) async {
    await prepare(tester);
    await pumpPage(tester);

    // 进分类上下文（筛选维度来自分类/首页 filters）。
    client.hold = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('browse-tab-1')));
    await tester.pump();
    await pumpFrames(tester, times: 2);
    expect(
      find.byType(LoadingBlock),
      findsWidgets,
      reason: '分类加载清空列表 → 必须显示加载块（既有正确行为）',
    );
    await release(tester);
    await pumpFrames(tester);

    expect(
      find.byKey(const ValueKey('category-filter-menu')),
      findsOneWidget,
      reason: '前置条件：分类上下文有筛选维度',
    );

    // 展开筛选面板。
    await tester.tap(find.byKey(const ValueKey('category-filter-menu')));
    await pumpFrames(tester, times: 3);
    final chip = find.byKey(const ValueKey('category-filter-class-喜剧'));
    expect(chip, findsOneWidget, reason: '前置条件：筛选 chip 已渲染');

    // 挂住新的筛选请求 → 点 chip。
    client.hold = Completer<void>();
    await tester.tap(chip);
    await tester.pump();
    await pumpFrames(tester, times: 2);

    // 等待中 chip 不得被禁用（`:579-589` 的既有约定：即时生效的控件
    // 不该在生效过程中把自己关掉）。
    final tagChip = tester.widget<TagChip>(
      find.descendant(of: chip, matching: find.byType(TagChip)),
    );
    expect(
      tagChip.onTap,
      isNotNull,
      reason: '筛选控件在等待中不得被禁用',
    );
    // 等待态本身仍可见（分类路径清空列表 → 加载块）。
    expect(
      find.byType(LoadingBlock),
      findsWidgets,
      reason: '筛选等待时必须有可见等待态',
    );

    await release(tester);
    await pumpFrames(tester);
    expect(find.text('分类1影片一'), findsOneWidget, reason: '放行后应展示该分类内容');
  });

  testWidgets('减动态：首页刷新等待态仍然可见', (tester) async {
    await prepare(tester);
    await pumpPage(tester, reduce: true);

    client.hold = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('browse-refresh')));
    await tester.pump();
    await pumpFrames(tester, times: 2);

    expect(
      find.byKey(_refreshBusyKey),
      findsOneWidget,
      reason: '减动态下等待态仍必须可见（反馈是动作确认，不是装饰）',
    );

    await release(tester);
  });
}
