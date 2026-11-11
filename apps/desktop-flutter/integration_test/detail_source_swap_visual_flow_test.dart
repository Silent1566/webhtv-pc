/// 详情页「换源」新交互的视觉证据采集（真实主题 → 真实光栅化 PNG）。
///
/// 六张图分别证明：错误条上的换源 CTA、换源浮层的候选列表（含站点健康色点与
/// 候选行海报）、勾选解析后的集数与并入入口、并入后详情页线路选择器里的外部
/// 线路与清空入口、「播放外部线路不改变全局当前站源」，以及
/// 「播放失败 → 确认换源」对话框（由一次真实的 `_play` 失败触发）。
///
/// ## 为什么不依赖网络
/// 三个站点都是 type=1 HTTP API，网络层用注入的假 http.BaseClient 按
/// request.url.path 分流（AppState(httpClient:) 是仓库既有的可测性口子）。
/// 站点健康度用 AppDatabase.recordHealth 种入确定计数，于是浮层与线路行尾的
/// 6px 色点颜色有信息量（A 站红、B 站绿），而不是清一色「未知」。
///
/// ## 为什么不用 pumpAndSettle
/// 换源浮层打开期间有无限旋转的加载指示器、播放器还有每秒推进的屏显时钟，
/// 都不可能 settle。这里统一用固定次数的 pump(Duration) 推帧。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/toast.dart';

void evidence(String message) => debugPrint('UI-REDESIGN-EVIDENCE $message');

/// 从当前目录向上找仓库根（以 docs/ 存在为判据）。
Directory repoRootOf(Directory start) {
  var current = start;
  for (var hop = 0; hop < 6; hop++) {
    if (Directory('${current.path}/docs').existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return start;
}

/// 截图锚点：测试侧给整棵被测树自己套的一层 RepaintBoundary。
///
/// Navigator / Overlay 都是它的后代，所以浮层、遮罩、对话框会被一起绘制进
/// 同一张图。反之，拿浮层自己那条路由的 boundary 当锚点，两侧透明区域会被
/// 渲染成白色、底下详情页与遮罩全部丢失（用户没见过的画面，是假证据）。
const ValueKey<String> _visualRoot = ValueKey<String>('visual-root-boundary');

/// 整窗逻辑尺寸，与 [useViewport] 的窗口尺寸一致。
const Size _viewportSize = Size(1440, 900);

/// 把当前渲染结果写成 PNG。
///
/// 默认锚点就是 [_visualRoot]（整窗）；浮层与对话框也用它截图，才能同时拍到
/// 详情页背景与模态遮罩。
Future<void> capture(
  WidgetTester tester, {
  required String relativePath,
  Finder? boundaryFinder,
  double pixelRatio = 1.0,
}) async {
  final anchor = boundaryFinder ?? find.byKey(_visualRoot);
  expect(
    anchor,
    findsOneWidget,
    reason: '截图锚点（测试侧根边界）必须唯一存在，path=$relativePath',
  );
  final object = anchor.evaluate().first.renderObject;
  if (object is! RenderRepaintBoundary) {
    evidence('screenshot-skip reason=not-repaint-boundary path=$relativePath');
    return;
  }
  final image = await object.toImage(pixelRatio: pixelRatio);
  // 截图后：锚点必须就是整窗。拍成 1440x612 这类只有浮层高度的画面，说明锚点
  // 又退回浮层自己的路由了。
  expect(
    tester.getSize(anchor),
    _viewportSize,
    reason: '截图锚点尺寸必须等于视口 1440x900，path=$relativePath',
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) {
    evidence('screenshot-skip reason=encode-failed path=$relativePath');
    return;
  }
  final repoRoot = repoRootOf(Directory.current);
  final output = File('${repoRoot.path}/$relativePath');
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(bytes.buffer.asUint8List());
  evidence(
    'screenshot path=$relativePath bytes=${bytes.lengthInBytes} '
    'size=${image.width}x${image.height}',
  );
}

void useViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
}

Future<void> pumpFrames(WidgetTester tester, {int times = 12}) async {
  for (var i = 0; i < times; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 有界等待：每帧 100ms，最多 times 帧。达到上限不抛错，交给后面的 expect
/// 报出「到底缺了什么」。
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  int times = 40,
}) async {
  for (var i = 0; i < times; i += 1) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 详情页自己的条目：一条原始线路一集。
Vod detailVod() => Vod(
  vodId: 'main-1',
  vodName: '换源目标影片',
  vodPlayFrom: 'orig',
  vodPlayUrl: '原第1集\$http://127.0.0.1:1/media/o1.mp4',
);

/// 播放失败证据用的条目：唯一一集的地址**不是任何可播形态**。
///
/// 选这条路径的原因（为什么它必然失败，见 `main` 里第六张图的注释）：
/// `bt-abc123-def` 不是媒体直链、也不以 `/` 开头，而主站 ui-main 是 type=1
/// 且配置里没有 playUrl 前缀 → `PlaybackResolver.decide` 兜底抛
/// `playbackParserRequired`，随后播放入口在建请求前再抛同一个分类。
Vod playbackFailedVod() => Vod(
  vodId: 'main-2',
  vodName: '播放失败目标影片',
  vodPlayFrom: 'orig',
  vodPlayUrl: '故障第1集\$bt-abc123-def',
);

/// 三个 type=1 站点：主站只承载详情（不可搜），两个换源站可搜。
const String _configJson = '''
{
  "name": "详情换源证据",
  "sites": [
    {"key": "ui-main", "name": "主站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/main/", "searchable": 0},
    {"key": "ui-swap-a", "name": "换源站A[盘]", "type": 1, "api": "http://127.0.0.1:1/api/a/", "searchable": 1},
    {"key": "ui-swap-b", "name": "换源站B[采]", "type": 1, "api": "http://127.0.0.1:1/api/b/", "searchable": 1}
  ]
}
''';

/// 种入确定性的健康计数，让两个换源站的色点颜色不同。
///
/// 判级规则（lib/ui/source_field.dart）：成功率 >=0.8 可用；<0.8 且样本 >=3
/// 才可能失效。于是 ui-swap-a（0 成功 / 3 失败）判「失效」→ 红，
/// ui-swap-b（3 成功 / 0 失败）判「可用」→ 绿。
void seedHealth(AppDatabase database) {
  void hit(String key, int ok, int fail) {
    for (var i = 0; i < ok; i++) {
      database.recordHealth(
        siteKey: key,
        action: HealthAction.home,
        success: true,
        latencyMs: 120,
      );
    }
    for (var i = 0; i < fail; i++) {
      database.recordHealth(
        siteKey: key,
        action: HealthAction.home,
        success: false,
        latencyMs: 2500,
        error: '连接超时',
      );
    }
  }

  hit('ui-main', 3, 0);
  hit('ui-swap-a', 0, 3);
  hit('ui-swap-b', 3, 0);
}

/// 假站点客户端：按 request.url.path 分流三个站点，按参数分流搜索/详情。
class SwapSiteClient extends http.BaseClient {
  /// 详情请求的 ids 参数（供断言「播放定向到哪个站点」时复用）。
  final List<String> detailIds = [];

  /// 搜索请求的 wd 参数。
  final List<String> searchKeywords = [];

  static Map<String, Object?> _searchPayload(String vodId) => {
    'page': 1,
    'pagecount': 1,
    'limit': 20,
    'total': 1,
    'list': [
      {
        'vod_id': vodId,
        'vod_name': '换源目标影片',
        'vod_pic': '',
        'vod_remarks': '',
      },
    ],
  };

  static Map<String, Object?> _detailPayload({
    required String vodId,
    required String flag,
    required String playUrl,
  }) => {
    'list': [
      {
        'vod_id': vodId,
        'vod_name': '换源目标影片',
        'vod_play_from': flag,
        'vod_play_url': playUrl,
      },
    ],
  };

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    final query = request.url.queryParameters;
    final keyword = query['wd'];
    Map<String, Object?> payload;
    if (keyword != null) {
      searchKeywords.add(keyword);
      if (path.contains('/a/')) {
        payload = _searchPayload('a-1');
      } else if (path.contains('/b/')) {
        payload = _searchPayload('b-1');
      } else {
        // 主站 searchable: 0，本不该被搜到，返回空表而不是报错。
        payload = {'list': []};
      }
    } else if (query['ac'] == 'detail') {
      final id = query['ids'] ?? '';
      detailIds.add(id);
      if (id == 'a-1') {
        payload = _detailPayload(
          vodId: 'a-1',
          flag: 'sa',
          playUrl:
              '换源A第1集\$http://127.0.0.1:1/media/a1.mp4#换源A第2集\$http://127.0.0.1:1/media/a2.mp4',
        );
      } else if (id == 'b-1') {
        payload = _detailPayload(
          vodId: 'b-1',
          flag: 'sb',
          playUrl:
              '换源B第1集\$http://127.0.0.1:1/media/b1.mp4#换源B第2集\$http://127.0.0.1:1/media/b2.mp4#换源B第3集\$http://127.0.0.1:1/media/b3.mp4',
        );
      } else {
        // 主站详情失败：错误条是换源 CTA 的入口，这里必须真的失败。
        payload = {'code': 1, 'msg': '站点业务错误:需要登录'};
      }
    } else {
      payload = {'list': []};
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
    );
  }
}

/// 装一个临时目录里的 AppState（不碰用户真实配置目录）。
Future<AppState> bootAppState(
  Directory temp,
  SwapSiteClient client, {
  required bool acceptUsageBoundary,
}) async {
  final paths = AppPaths.resolve(
    overrides: {
      'config': '${temp.path}/webhtv-pc',
      'data': '${temp.path}/webhtv-pc',
      'cache': '${temp.path}/webhtv-pc/cache',
      'state': '${temp.path}/webhtv-pc/logs',
    },
  );
  final state = AppState(paths: paths, log: LogService(), httpClient: client);
  await state.bootstrap();
  if (acceptUsageBoundary) {
    // 不预写这个标记，首屏的使用边界提示会盖住窗口底部，截图内容不完整。
    File(
      '${paths.configDir}${Platform.pathSeparator}usage-boundary-accepted',
    ).writeAsStringSync(DateTime.now().toIso8601String());
  }
  final imported = await state.importConfig(_configJson);
  if (!imported) {
    throw StateError('fixture 配置导入失败：${state.lastError?.logLine}');
  }
  seedHealth(state.database!);
  return state;
}

/// 护栏：浮层/对话框必须是 [_visualRoot] 的后代（它同时是 Navigator 的祖先）。
///
/// 这条断言防的是「又拍成一张没有浮层的旧页面」：只要浮层不在根边界之下，
/// 截图里就不可能有它，后面的整窗尺寸断言也就变成了自欺。
void expectInsideVisualRoot(String overlayKey) {
  expect(
    find.descendant(
      of: find.byKey(_visualRoot),
      matching: find.byKey(ValueKey(overlayKey)),
    ),
    findsOneWidget,
    reason: '$overlayKey 必须是整窗根边界 visual-root-boundary 的后代',
  );
}

/// 先收通知、再销毁 `AppState`（顺序不能反）。
///
/// 错误通知的 `onDismiss` 会调 `AppState.clearDetailError()`：状态层先销毁、
/// 通知后收（例如被下一条用例的 `setUp` 收走），那条回调就会抛
/// 「A AppState was used after being disposed」。在这里先收通知，回调走的是
/// 「页面还挂着」的正常路径；页面已经销毁时回调自己 `mounted` 短路，也安全。
void teardownToastsThenState(AppState state) {
  addTearDown(() {
    dismissAllToasts();
    state.dispose();
  });
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // 通知中心是进程级单例：上一条用例留下的通知（错误通知会驻留 15 秒，足够跨过去）
  // 会活到下一条用例里，把「用户被告知失败」变成假绿。每条用例前清空。
  setUp(dismissAllToasts);

  testWidgets('详情页换源：错误条 → 浮层 → 解析 → 并入外部线路', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-swap-evidence');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final client = SwapSiteClient();
    final state = await bootAppState(temp, client, acceptUsageBoundary: false);
    teardownToastsThenState(state);

    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 测试侧包裹：整窗统一截图锚点（不改变任何业务语义）。
    await tester.pumpWidget(
      RepaintBoundary(
        key: _visualRoot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.dark),
          // 通知宿主挂在 `home:` 里（= Navigator/Overlay **之内**），与仓库既有
          // `test/toast_host_test.dart`、`test/detail_source_swap_test.dart` 同一挂法。
          //
          // 不用 `MaterialApp.builder`：它的 child 就是 Navigator，宿主因此在
          // Overlay 之外，任何依赖 Overlay 的控件（`RawTooltip` 无条件断言
          // `debugCheckHasOverlay`）会抛 `No Overlay widget found`。
          //
          // 代价（如实记录）：这只能证明「错误以通知形式到达用户」，**不能**证明
          // 「浮在所有路由与对话框之上」那层——在 `home:` 里后压的路由会盖住它。
          home: Stack(
            fit: StackFit.expand,
            children: [
              DetailPage(state: state, vod: detailVod()),
              const ToastHost(),
            ],
          ),
        ),
      ),
    );
    await pumpFrames(tester, times: 16);

    // ---- frame 1：详情页错误条 + 琥珀色「换源」CTA（整窗）
    expect(
      find.byKey(const ValueKey('detail-swap-source')),
      findsOneWidget,
      reason: '主站详情失败后错误条上必须有换源 CTA',
    );
    await capture(
      tester,
      relativePath: '.impeccable/review/detail-swap-1-error-cta.png',
    );

    // ---- frame 2：换源浮层已打开，显示搜索结果候选行
    await tester.tap(find.byKey(const ValueKey('detail-swap-source')));
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('source-swap-row-ui-swap-b-b-1'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('source-swap-row-ui-swap-a-a-1')),
      findsOneWidget,
      reason: '浮层应搜到换源站A的候选',
    );
    expect(
      find.byKey(const ValueKey('source-swap-row-ui-swap-b-b-1')),
      findsOneWidget,
      reason: '浮层应搜到换源站B的候选',
    );
    await pumpFrames(tester, times: 8);
    // 护栏：浮层宽度取 min(窗口宽 - 2*32, 1120)，1440 窗口下 = 1120。旧实现被
    // Material bottomSheet 的默认 constraints 封顶 640 —— 这条断言就是新旧分界。
    expect(
      tester.getSize(find.byKey(const ValueKey('source-swap-sheet'))).width,
      greaterThan(900),
      reason: '浮层宽度必须超过旧实现的 640 封顶（1440 窗口下应为 1120）',
    );
    // 护栏：候选行的标准海报卡必须在场（与搜索页结果区同一张 140×190 卡）。
    expect(
      find.byKey(const ValueKey('source-swap-poster-ui-swap-a-a-1')),
      findsOneWidget,
      reason: '候选行必须渲染海报 widget',
    );
    final posterSize = tester.getSize(
      find.byKey(const ValueKey('source-swap-poster-ui-swap-a-a-1')),
    );
    expect(posterSize.width, 140);
    expect(posterSize.height, 190);
    expectInsideVisualRoot('source-swap-sheet');
    await capture(
      tester,
      relativePath: '.impeccable/review/detail-swap-2-sheet-search.png',
      // pixelRatio 是真实光栅化参数：截图以 2x 光栅化，图内文字更清楚；
      // 宽度护栏已由上面 getSize 断言守住（不靠 PNG 尺寸兼职）。
      pixelRatio: 2.0,
    );

    // ---- frame 3：勾选两个候选并解析完成（行尾「N 集」+「并入 N 条线路」）
    await tester.tap(
      find.byKey(const ValueKey('source-swap-check-ui-swap-a-a-1')),
    );
    await pumpFrames(tester, times: 4);
    await tester.tap(
      find.byKey(const ValueKey('source-swap-check-ui-swap-b-b-1')),
    );
    await pumpFrames(tester, times: 4);
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpUntil(
      tester,
      () => find.text('并入 2 条线路').evaluate().isNotEmpty,
    );
    expect(find.textContaining('2 集'), findsWidgets, reason: 'A 站解析出 2 集');
    expect(find.textContaining('3 集'), findsWidgets, reason: 'B 站解析出 3 集');
    // 同一组护栏：第二张浮层图也必须是宽浮层、也必须有候选行海报。
    expect(
      tester.getSize(find.byKey(const ValueKey('source-swap-sheet'))).width,
      greaterThan(900),
      reason: '解析完成后的浮层宽度同样必须超过旧实现的 640 封顶',
    );
    expect(
      find.byKey(const ValueKey('source-swap-poster-ui-swap-b-b-1')),
      findsOneWidget,
      reason: '解析完成后的候选行仍必须渲染海报 widget',
    );
    expectInsideVisualRoot('source-swap-sheet');
    await capture(
      tester,
      relativePath: '.impeccable/review/detail-swap-3-probed.png',
      pixelRatio: 2.0,
    );

    // 第二次点同一个按钮 = 并入，浮层关闭。
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpFrames(tester, times: 16);
    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsNothing,
      reason: '并入后浮层应关闭',
    );

    // ---- frame 4：并入后的详情页线路选择器（整窗）
    for (var i = 0; i < 2; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
      await pumpFrames(tester, times: 6);
    }
    expect(
      find.byKey(const ValueKey('tmdb-line-external-换源站A[盘] · sa')),
      findsOneWidget,
      reason: '外部线路A必须进入线路选择器（行首带 6px 健康色点）',
    );
    expect(
      find.byKey(const ValueKey('tmdb-line-external-换源站B[采] · sb')),
      findsOneWidget,
      reason: '外部线路B必须进入线路选择器（行首带 6px 健康色点）',
    );
    expect(
      find.byKey(const ValueKey('detail-clear-external')),
      findsOneWidget,
      reason: '有外部线路时必须给出「清空外部线路」入口',
    );
    await capture(
      tester,
      relativePath: '.impeccable/review/detail-swap-4-merged-lines.png',
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('frame 5：播放外部线路后全局当前站源不变（AppShell 顶栏）', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-swap-shell');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final client = SwapSiteClient();
    final state = await bootAppState(temp, client, acceptUsageBoundary: true);
    teardownToastsThenState(state);

    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 测试侧包裹：整窗统一截图锚点（不改变任何业务语义）。
    await tester.pumpWidget(
      RepaintBoundary(
        key: _visualRoot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.dark),
          // 【这一处**必须**用 builder，与其余两处不同】实测依据：
          // 本用例在 `home: AppShell` 之后 `navigator.push(DetailPage)`，随后点
          // `detail-swap-source`——那是详情错误通知上的动作按钮。宿主若挂在
          // `home:`（= 下层路由的 Overlay 内），上层不透明路由会把它盖住，
          // 点击当场失败："Found 0 widgets with key [<'detail-swap-source'>]"。
          // 只有位于 Navigator **之上**的 builder 位置，跨路由才对用户可见/可点。
          //
          // 这里不会踩 `No Overlay widget found`：`lib/ui/toast.dart` 的关闭按钮
          // 已把 `tooltip:` 换成 `Icon.semanticLabel`，不再依赖祖先 Overlay。
          // 本文件 frame 1/5/6 三例均实测通过。
          builder: (context, child) => Stack(
            fit: StackFit.expand,
            children: [
              child ?? const SizedBox.shrink(),
              const ToastHost(),
            ],
          ),
          home: AppShell(state: state, startup: const StartupArguments()),
        ),
      ),
    );
    await pumpFrames(tester, times: 20);

    // A 分支判据：lib/ui/app.dart:1084-1088 的 _TopBar 用
    // Text(site == null ? '选择站点' : '站点：${site.name}') 渲染当前站源。
    // 这条断言成立就说明顶栏确实带站点名，A 分支可用（不需要改 app.dart）。
    expect(
      find.text('站点：主站[盘]'),
      findsOneWidget,
      reason: '顶栏必须渲染当前站点名，这是 A 分支成立的前提',
    );

    // 在同一棵树上 push 详情页（与用户从列表点进来的路径一致）。
    final navigator = Navigator.of(tester.element(find.byType(AppShell)));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(state: state, vod: detailVod()),
      ),
    );
    await pumpFrames(tester, times: 16);

    // 换源：只并 B 站（3 集，集数最多 → 并入后被自动选中）。
    await tester.tap(find.byKey(const ValueKey('detail-swap-source')));
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('source-swap-row-ui-swap-b-b-1'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const ValueKey('source-swap-check-ui-swap-b-b-1')),
    );
    await pumpFrames(tester, times: 4);
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpUntil(
      tester,
      () => find.text('并入 1 条线路').evaluate().isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpFrames(tester, times: 16);

    // 播放外部线路的第一集。
    for (var i = 0; i < 2; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
      await pumpFrames(tester, times: 6);
    }
    final episodeCard = find.byKey(
      const ValueKey('tmdb-episode-card-换源站B[采] · sb-0'),
    );
    expect(episodeCard, findsOneWidget, reason: '外部线路的第一集卡片应在页面上');
    await tester.tap(episodeCard);
    await pumpFrames(tester, times: 16);
    expect(
      find.byType(PlayerPage),
      findsOneWidget,
      reason: '点外部线路的集应真的进入播放器',
    );
    expect(
      state.selectedSite?.key,
      'ui-main',
      reason: '播放外部线路不得切换全局站源',
    );
    expect(
      client.detailIds.contains('b-1'),
      isTrue,
      reason: '播放解析必须定向到外部站点自己的 vodId',
    );
    // 媒体地址是不可达的 127.0.0.1:1，让 openWithRetry 在真实时间里落定为失败。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 3)),
    );
    await pumpFrames(tester, times: 8);

    // 回到 AppShell，整窗截图：顶栏仍应显示「站点：主站[盘]」。
    navigator.pop(); // PlayerPage
    await pumpFrames(tester, times: 12);
    navigator.pop(); // DetailPage
    await pumpFrames(tester, times: 20);
    expect(find.byType(AppShell), findsOneWidget, reason: '应回到外壳');
    expect(
      find.text('站点：主站[盘]'),
      findsOneWidget,
      reason: '播放外部线路后全局当前站源仍是主站',
    );
    await capture(
      tester,
      relativePath: '.impeccable/review/detail-swap-5-shell-site-unchanged.png',
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('frame 6：点集数卡片播放失败 → 确认换源对话框（由真实 _play 失败触发）', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-swap-failed');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final client = SwapSiteClient();
    final state = await bootAppState(temp, client, acceptUsageBoundary: false);
    teardownToastsThenState(state);

    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    // 测试侧包裹：整窗统一截图锚点（不改变任何业务语义）。
    await tester.pumpWidget(
      RepaintBoundary(
        key: _visualRoot,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.dark),
          // 同上：播放失败也会推一条错误通知，宿主挂在 `home:` 里。
          home: Stack(
            fit: StackFit.expand,
            children: [
              DetailPage(state: state, vod: playbackFailedVod()),
              const ToastHost(),
            ],
          ),
        ),
      ),
    );
    await pumpFrames(tester, times: 16);

    // 这张图的失败必须是**真实播放链路**给的，不是摆拍：
    //   1. 集数卡片的 onTap → DetailPage._playEpisodeAt → _play（browse_pages.dart:1880）
    //   2. _play 调 state.resolvePlayback(episodeTarget: 'bt-abc123-def')
    //      → SiteService.resolvePlayback → PlaybackResolver.decide
    //   3. 'bt-abc123-def' 既不是媒体直链（无 http/https/... scheme，也不以 '//'
    //      开头）也不以 '/' 开头相对化，而 ui-main 的 extra 里没有 playUrl 前缀
    //      → playback.dart:226-230 兜底抛 AppErrorKind.playbackParserRequired
    //   4. 该初判异常被 site_service.dart:359-372 的 try 吞掉后改走播放入口
    //      HttpApiRuntime.play → http_api.dart:284-290 在**发请求之前**再抛同一个
    //      分类（站点未声明 playUrl 且剧集目标不是直链）
    //   5. SiteService 记一次 play 失败并把 AppError rethrow
    //      → AppState.resolvePlayback rethrow → _play 的 catch
    //   6. catch 里 kind != siteCancelled 且非自动续播 → _confirmSwapAfterPlayFailure
    //      → showDialog 弹出 AlertDialog(key 'detail-playback-failed')
    // 与生产环境「站点 play 接口报错」等价之处：两者都是 resolvePlayback 抛出
    // AppError 后进入同一个确认框；差异只在错误分类与文案（见交付报告）。
    final episodeCard = find.byKey(const ValueKey('tmdb-episode-card-orig-0'));
    // hero 占整屏，选集区在下方：与其余用例一致，用有界推帧 + 两次大幅滚动带进视口。
    for (var i = 0; i < 2; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
      await pumpFrames(tester, times: 6);
    }
    expect(
      episodeCard,
      findsOneWidget,
      reason: '原线路第 1 集卡片必须渲染（线路来自 vod.playUrl，不依赖详情请求成功）',
    );

    await tester.tap(episodeCard);
    // 播放决策要走一次真实解析 + 健康度落库，给足够的有界帧数等对话框浮出。
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('detail-playback-failed'))
          .evaluate()
          .isNotEmpty,
      times: 60,
    );
    // pumpUntil 在「节点刚建出来」那一帧就返回：此时对话框路由的淡入与模态遮罩
    // 还在 t=0（opacity 0）。再推若干帧让它们真正落到画面上，否则截图里只剩
    // 详情页、看不到对话框与遮罩。
    await pumpFrames(tester, times: 8);

    expect(
      find.byKey(const ValueKey('detail-playback-failed')),
      findsOneWidget,
      reason: '播放失败后必须弹出「这一集没有可播放的地址」确认框',
    );
    expect(
      find.text('这一集没有可播放的地址'),
      findsOneWidget,
      reason: '对话框标题必须是换源语义（不是一条只读 SnackBar）',
    );
    expect(
      find.byKey(const ValueKey('detail-playback-failed-swap')),
      findsOneWidget,
      reason: '对话框必须给出「换源」主操作',
    );
    expect(
      find.byKey(const ValueKey('detail-playback-failed-dismiss')),
      findsOneWidget,
      reason: '对话框必须给出「知道了」次操作',
    );

    // AlertDialog 内部是 Align + Material：AlertDialog 那个 key 的 render box 会撑满
    // 整窗（实测 getSize == 1440x900，等于没有门槛）。真正可视的对话框面板是它外层的
    // Material，因此尺寸门槛必须压在这个面板上，并且要额外断言它没有铺满整窗。
    final dialogPanel = tester.getSize(
      find
          .descendant(
            of: find.byKey(const ValueKey('detail-playback-failed')),
            matching: find.byType(Material),
          )
          .first,
    );
    evidence(
      'playback-failed dialog panel='
      '${dialogPanel.width.toStringAsFixed(0)}x'
      '${dialogPanel.height.toStringAsFixed(0)}',
    );
    expect(
      dialogPanel.width,
      greaterThanOrEqualTo(280),
      reason: '对话框面板宽度不低于 Material 最小宽度 280',
    );
    expect(
      dialogPanel.height,
      greaterThanOrEqualTo(120),
      reason: '对话框面板高度必须容得下标题+说明+两个按钮',
    );
    expect(
      dialogPanel.width,
      lessThan(1440),
      reason: '面板必须是对话框而非铺满整窗（证明是弹窗态而不是整页）',
    );
    expect(
      find.byKey(const ValueKey('detail-playback-failed-boundary')),
      findsOneWidget,
      reason: '截图锚点 RepaintBoundary 必须存在',
    );

    // 对话框也走整窗锚点：这样图里才有详情页背景与模态遮罩。
    expectInsideVisualRoot('detail-playback-failed');
    await capture(
      tester,
      relativePath: '.impeccable/review/detail-swap-6-playback-failed.png',
      pixelRatio: 2.0,
    );

    // 关掉对话框后：仍停在这部影片的原线路上，没有被静默切走或并入外部线路。
    await tester.tap(find.byKey(const ValueKey('detail-playback-failed-dismiss')));
    await pumpFrames(tester, times: 12);
    expect(
      find.byKey(const ValueKey('detail-playback-failed')),
      findsNothing,
      reason: '点「知道了」后对话框必须消失',
    );
    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsNothing,
      reason: '不换源就不该替他打开换源浮层',
    );
    expect(
      find.byKey(const ValueKey('tmdb-episode-card-orig-0')),
      findsOneWidget,
      reason: '仍应停在这部影片的原线路选集区',
    );
    expect(
      find.byKey(const ValueKey('detail-clear-external')),
      findsNothing,
      reason: '没有并入任何外部线路，不该出现「清空外部线路」',
    );
    expect(
      find.byKey(const ValueKey('tmdb-line-external-换源站B[采] · sb')),
      findsNothing,
      reason: '失败后不得把线路偷偷换成外部站点',
    );
    expect(
      state.selectedSite?.key,
      'ui-main',
      reason: '播放失败不得改动全局站源',
    );

    expect(tester.takeException(), isNull);
  });
}
