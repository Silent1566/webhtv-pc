/// 改造后的视觉证据采集：真实主题 + 真实外壳 → PNG（`.impeccable/review/`）。
///
/// ## 为什么必须新建这个文件，而不是复用现有的
///
/// 现有集成测试（含 `tmdb_detail_visual_flow_test.dart`）一律用**裸 `MaterialApp`**
/// pump 页面，**不传 `theme:`**。也就是说它们拍的是 Flutter 默认亮色主题，
/// 不是线上观感——这正是 `docs/phase4/evidence/tmdb-detail-header.png` 是白底、
/// 而应用其实强制暗色的原因。用那种截图复核本次改造等于没复核。
///
/// 本文件显式套 `buildAppTheme`，并且**写到 `.impeccable/review/`**，
/// 不覆盖 `docs/phase4/evidence/` 里已提交的证据记录。
///
/// ## 为什么不需要 fixture 服务和网络
///
/// 源场的星等来自 `site_health` 表的实测计数。这里用
/// `AppDatabase.recordHealth` **种入确定性的计数**，于是四种状态
/// （可用 / 降级 / 失效 / 未知）在一次渲染里全部出现，
/// 而且不依赖任何外部服务、不读写用户的真实配置目录
/// （`AppPaths.resolve(overrides:)` 指向临时目录）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/app.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/common.dart';
import 'package:webhtv_pc/ui/config_pages.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/live_page.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/spider_page.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';
import 'package:webhtv_pc/ui/tokens.dart';

import '../test/support/settings_navigation.dart';
import 'fixture_http.dart';

void evidence(String message) => debugPrint('UI-REDESIGN-EVIDENCE $message');

/// 从当前目录向上找仓库根（以 `docs/` 存在为判据）。
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

/// 把当前整窗渲染结果写成 PNG。
///
/// 用真实光栅化结果（`RepaintBoundary → toImage → PNG`）而不是"widget 树的重描述"，
/// 因为要证明的是**用户看到的样子**。
Future<void> capture(
  WidgetTester tester, {
  required String relativePath,
}) async {
  final boundary = find.byType(RepaintBoundary);
  if (boundary.evaluate().isEmpty) {
    evidence('screenshot-skip reason=no-repaint-boundary path=$relativePath');
    return;
  }
  final object = boundary.evaluate().first.renderObject;
  if (object is! RenderRepaintBoundary) {
    evidence('screenshot-skip reason=not-repaint-boundary path=$relativePath');
    return;
  }
  final image = await object.toImage(pixelRatio: 1.0);
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

/// 构造一份带真实感站源清单的配置。
///
/// 站点类型刻意混合：`type=1` 走 HTTP 运行时（可用），`type=3` 且 `api` 是
/// `csp_*` 形态的走 JVM 运行时——在测试环境里 JVM 宿主不可用，
/// 于是这些站点会如实显示成「失效（运行时不支持）」，这正是我们要验证的一态。
const List<Map<String, Object>> _sites = [
  {'key': 'muou', 'name': '木偶', 'type': 1, 'api': 'http://127.0.0.1:9/muou'},
  {
    'key': 'jinpai',
    'name': '金牌',
    'type': 1,
    'api': 'http://127.0.0.1:9/jinpai',
  },
  {'key': 'huban', 'name': '湖班', 'type': 1, 'api': 'http://127.0.0.1:9/huban'},
  {'key': 'p115', 'name': '115', 'type': 1, 'api': 'http://127.0.0.1:9/p115'},
  {'key': 'kuake', 'name': '夸克', 'type': 1, 'api': 'http://127.0.0.1:9/kuake'},
  {'key': 'tiankong', 'name': '天空', 'type': 1, 'api': 'http://127.0.0.1:9/tk'},
  {'key': 'kuaikan', 'name': '快看', 'type': 1, 'api': 'http://127.0.0.1:9/kk'},
  {'key': 'fengche', 'name': '风车', 'type': 1, 'api': 'http://127.0.0.1:9/fc'},
  {'key': 'csp_demo', 'name': '存量 JAR 站源', 'type': 3, 'api': 'csp_Demo'},
  {'key': 'fresh', 'name': '新导入站点', 'type': 1, 'api': 'http://127.0.0.1:9/new'},
];

/// 种入确定性的健康计数，让四种状态一次全部出现。
///
/// 判级规则（`ui/source_field.dart`）：成功率 ≥0.8 可用；<0.8 且样本 ≥3
/// 才可能失效；**一次失败不算失效**。
void seedHealth(AppDatabase database) {
  void hit(String key, int ok, int fail, {int latencyMs = 120}) {
    for (var i = 0; i < ok; i++) {
      database.recordHealth(
        siteKey: key,
        action: HealthAction.home,
        success: true,
        latencyMs: latencyMs,
      );
    }
    for (var i = 0; i < fail; i++) {
      database.recordHealth(
        siteKey: key,
        action: HealthAction.home,
        success: false,
        latencyMs: latencyMs,
        error: '连接超时',
      );
    }
  }

  // 可用：成功率 1.0 / 0.9。
  hit('muou', 10, 0, latencyMs: 86);
  hit('jinpai', 9, 1, latencyMs: 142);
  hit('p115', 8, 1, latencyMs: 233);
  // 降级：成功率 0.5 与 0.6。
  hit('kuake', 5, 5, latencyMs: 640);
  hit('tiankong', 6, 4, latencyMs: 510);
  // 失效：样本足够且一次都没成功。
  hit('huban', 0, 6, latencyMs: 3000);
  hit('kuaikan', 0, 4, latencyMs: 2800);
  // 只有一次失败 → 仍算「降级」，用来验证"一次失败不足以判死一个源"。
  hit('fengche', 0, 1, latencyMs: 2500);
  // `fresh` 不种任何数据 → 未知。
}

Future<AppState> _bootState(Directory temp) async {
  final paths = AppPaths.resolve(
    overrides: {'roaming': temp.path, 'local': temp.path},
  );
  final state = AppState(paths: paths, log: LogService());
  await state.bootstrap();
  // 预先写下边界确认标记：否则首次启动的边界提示会盖住窗口底部，
  // 让截图里的内容区不完整。
  File('${paths.configDir}${Platform.pathSeparator}usage-boundary-accepted')
      .writeAsStringSync(DateTime.now().toIso8601String());
  final imported = await state.importConfig(
    jsonEncode({'name': '视觉证据 fixture', 'sites': _sites}),
  );
  if (!imported) {
    throw StateError('fixture 配置导入失败：${state.lastError?.logLine}');
  }
  seedHealth(state.database!);
  return state;
}

/// 把窗口设成给定逻辑尺寸。
void useViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
}

/// 详情页用的合成展示模型。
///
/// 只喂 `TmdbDetailView`（它是吃纯数据的 `StatelessWidget`），因此**不需要
/// TMDB fixture 服务、不发网络请求**。海报/剧照地址指向不可达主机，
/// 于是图位渲染成占位块——这正好诚实反映"图还没到"的状态；
/// 而层级、间距、区块标题、元数据、标签这些本次要复核的东西都是真实的。
TmdbDetailData _detailData() => TmdbDetailData(
  title: '示例剧集',
  originalTitle: 'Fallout',
  overview: '一段用于视觉复核的简介文本，用来检查正文行高与最大宽度是否合适。',
  posterUrl: '$fixtureBaseUrl/tmdb-img/w342/p1.jpg',
  backdropUrls: [
    // `wide` 前缀 → fixture 返回 **16:9 且上下带红/蓝标记带**的图。
    //
    // 为什么必须换成真图（2026-10-13）：背景改双层铺法后要验证的是
    // 「原图完整、一处不裁」。原来指向 `127.0.0.1:9`（丢弃端口，图必然加载失败），
    // 截图里只有占位块——**根本看不出裁没裁**。有了标记带，顶带或底带缺了就是被裁了。
    '$fixtureBaseUrl/tmdb-img/w1280/wide-bd1.jpg',
    '$fixtureBaseUrl/tmdb-img/w1280/wide-bd2.jpg',
  ],
  rating: 8.2,
  runtime: 45,
  seasonCount: 1,
  episodeCount: 12,
  genres: ['剧情', '科幻'],
  photoUrls: [
    '$fixtureBaseUrl/tmdb-img/w780/wide-p1.jpg',
    '$fixtureBaseUrl/tmdb-img/w780/wide-p2.jpg',
  ],
  posterUrls: ['$fixtureBaseUrl/tmdb-img/w342/p1.jpg'],
  cast: [
    TmdbPerson(personId: 1, name: '演员甲', subtitle: 'Actor', profileUrl: null),
    TmdbPerson(personId: 2, name: '演员乙', subtitle: 'Actor', profileUrl: null),
  ],
  crew: [
    TmdbPerson(
      personId: 3,
      name: '导演甲',
      subtitle: 'Director',
      profileUrl: null,
    ),
  ],
);

/// 本机 fixture 服务是否可达。
///
/// 为什么必须探测而不是直接假设：浏览页与播放器两条用例需要
/// `tools/fixture_server/server.py` 在跑。硬依赖会让"服务没起"表现成
/// **用例失败**——那看起来像代码回归，实际只是环境没准备好，
/// 是最容易误导后续判断的一种假信号。不可达就跳过并说明原因。
Future<bool> _fixtureReachable() async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    final request = await client.getUrl(Uri.parse('$fixtureBaseUrl/health'));
    final response = await request.close();
    await response.drain<void>();
    client.close();
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// 等首页加载落定（离开 `loading`）或到上限。
///
/// 首页请求走真实 HTTP，失败需要真实时间；只 pump 固定次数会让截图落在加载序列的
/// 不同位置，同一份代码不同运行得到不同画面。截图 harness 的价值全在于可比，
/// 因此必须等一个**状态条件**，而不是等一个时长。
Future<void> _settleHome(WidgetTester tester, AppState state) async {
  for (var i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    if (state.contentPhase != LoadPhase.loading) break;
  }
  // 再走一小段，让错误横幅/通知条的入场动画结束。
  await tester.pump(const Duration(milliseconds: 400));
}

/// chip 状态表用的空回调（表里只关心渲染，不关心行为）。
void _noop() {}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 播放器用例需要它：`main.dart` 在应用启动时调用，但这里直接 pump
  // `PlayerPage`，不初始化就会抛
  // 「MediaKit.ensureInitialized must be called before using any API」。
  MediaKit.ensureInitialized();

  for (final brightness in [Brightness.dark, Brightness.light]) {
    final label = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('外壳与源场（$label，1440x900）', (tester) async {
      final temp = Directory.systemTemp.createTempSync('webhtv-ui-$label');
      final state = await _bootState(temp);
      addTearDown(() {
        state.dispose();
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });

      useViewport(tester, const Size(1440, 900));
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.light),
          darkTheme: buildAppTheme(Brightness.dark),
          themeMode: brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light,
          home: AppShell(state: state, startup: const StartupArguments()),
        ),
      );

      // 等首页加载**落定**再截图。
      //
      // 为什么不能只 pump 固定次数：首页请求是真实 HTTP（站点地址刻意不可达），
      // 失败需要真实时间。固定 pump 会让截图落在加载序列的不同位置——实测同一份
      // 代码两次运行，一次拍到加载中的转圈、一次拍到错误态 + 空态。
      // **会变的证据不是证据**，所以这里等到状态真正离开 loading。
      await _settleHome(tester, state);

      await capture(
        tester,
        relativePath: '.impeccable/review/shell-$label.png',
      );

      // 外壳的骨架必须在：左导轨 + 顶栏品牌。源场已搬到独立页
      // （见下面的「站点健康页」用例），首页不再渲染它。
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('WebHTV'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('详情页首屏（dark，1440x900）', (tester) async {
    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        // 必须套滚动视图：`TmdbDetailView` 自身是不可滚动的 `Column`，
        // 真实 app 里由 `DetailPage` 提供滚动容器。第一版漏了它，
        // 于是 harness 自己报了一个 106px 的 RenderFlex 溢出——
        // 那是 harness 的缺陷，不是产品缺陷。
        home: Scaffold(
          body: SingleChildScrollView(
            child: TmdbDetailView(
              data: _detailData(),
              // 带真实时长的剧集卡：复核方向契约里「长度编码时长」那条纪律
              // （条宽按真实时长成比例，不是均分）。刻意混入 runtime=0 的两集，
              // 验证"时长未知"是如实呈现而不是被平均掉。
              episodeCards: const [
                TmdbEpisodeCard(number: 1, title: '开端', runtime: 45),
                TmdbEpisodeCard(number: 2, title: '第二集', runtime: 62),
                TmdbEpisodeCard(number: 3, title: '第三集', runtime: 38),
                TmdbEpisodeCard(number: 4, title: '第四集', runtime: 51),
                TmdbEpisodeCard(number: 5, title: '第五集', runtime: 29),
                TmdbEpisodeCard(number: 6, title: '第六集', runtime: 0),
                TmdbEpisodeCard(number: 7, title: '第七集', runtime: 58),
                TmdbEpisodeCard(number: 8, title: '第八集', runtime: 0),
              ],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    await capture(tester, relativePath: '.impeccable/review/detail-dark.png');

    // 滚动后：正文必须**仍然浮在图片上**（用户反馈 2026-10-13
    // 「后续内容也应该显示在图片上」）。
    //
    // 背景改到页面级 `Positioned.fill` 之后，它脱离滚动、固定不动，
    // 正文在它上面滚过去。这一张就是那条要求的证据——没有它，
    // 我只能证明"首屏有图"，证明不了"后续内容也在图上"。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    await capture(
      tester,
      relativePath: '.impeccable/review/detail-scrolled-dark.png',
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('源详情页：页面级固定背景，滚动后正文仍在图上（2.35:1）', (tester) async {
    // 为什么单独一条（2026-10-13 的教训）：
    // 上面那条拍的是 `TmdbDetailView`（吃纯数据的 StatelessWidget），
    // 而页面级背景改在 `browse_pages.dart` 的**源详情页** `DetailPage` 里。
    // 结果：改完代码再拍，图**逐字节不变**——那条"验证"根本没经过改动。
    // 所以必须用真实 `DetailPage`，否则任何截图都不作数。
    if (!await _fixtureReachable()) {
      markTestSkipped(
        'fixture 服务不可达（$fixtureBaseUrl）：'
        '先运行 `python tools/fixture_server/server.py`',
      );
      return;
    }
    // 用户窗口比例 2661x1132 ≈ 2.35:1。

    final temp = Directory.systemTemp.createTempSync('webhtv-ui-srcdetail');
    final state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': temp.path, 'local': temp.path},
      ),
      log: LogService(),
    );
    await tester.runAsync(() => state.bootstrap());

    // 源详情页的背景走 `display.vodPic` 回退（没有 TMDB 配置时），
    // 所以把 fixture 的 **16:9** 图当来源海报喂进去，就能拍到真实的两层铺法。
    final vod = Vod(
      vodId: 'src-1',
      vodName: '源详情页样例',
      vodPic: '$fixtureBaseUrl/tmdb-img/w1280/wide-bd1.jpg',
      vodPlayFrom: '线路一',
      vodPlayUrl: '第1集\$https://media.invalid/1.m3u8',
      vodContent: '一段用于视觉复核的简介文本。',
    );
    state.seedDetailForTest(vod: vod);

    // **三档宽高比各出两张**（首屏 + 滚动态）。
    //
    // 上次的教训：只在 1440x900（1.6:1）出图就交付，而用户窗口是 2.35:1，
    // 问题在那一档才暴露。铺满/背景类改动**必须跨比例验证**。
    const ratios = <String, Size>{
      'r16x10': Size(1600, 1000), // 1.60:1
      'r2x1': Size(2000, 1000), // 2.00:1
      'r235x1': Size(2000, 850), // 2.35:1 ← 用户窗口
    };

    for (final entry in ratios.entries) {
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: DetailPage(state: state, vod: vod),
        ),
      );
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 120));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
      }

      // 复位到顶部再拍**首屏**。
      //
      // 上一档位结尾的 `drag(-700)` 会被下一档位的新 `ListView` 继承：
      // `Scrollable` 把偏移量写进 `PageStorage`，换 widget 树也读回来。
      // 实测后果是 r2x1 / r235x1 两张"首屏"其实各自被上移了 356px，
      // 内容看上去贴顶（差点被误判成"内容带跨比例漂移"的产品缺陷）。
      final scrollable = find.byType(Scrollable);
      if (scrollable.evaluate().isNotEmpty) {
        final position = tester
            .state<ScrollableState>(scrollable.first)
            .position;
        if (position.pixels != 0) {
          position.jumpTo(0);
          await tester.pumpAndSettle();
        }
      }

      await capture(
        tester,
        relativePath: '.impeccable/review/source-detail-${entry.key}.png',
      );

      // 滚下去：正文必须**仍然浮在图上**（用户反馈「后续内容也应该显示在图片上」）。
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
      await tester.pumpAndSettle();
      await capture(
        tester,
        relativePath:
            '.impeccable/review/source-detail-${entry.key}-scrolled.png',
      );
    }

    expect(tester.takeException(), isNull);
    state.dispose();
  });

  testWidgets('浏览页：源场 + 分类条 + 海报网格（dark，1440x900）', (tester) async {
    if (!await _fixtureReachable()) {
      markTestSkipped(
        'fixture 服务不可达（$fixtureBaseUrl）：'
        '先运行 `python tools/fixture_server/server.py`',
      );
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-ui-browse');
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
    File('${paths.configDir}${Platform.pathSeparator}usage-boundary-accepted')
        .writeAsStringSync(DateTime.now().toIso8601String());

    // 这一个站点指向**本机 fixture 服务**（`tools/fixture_server/server.py`），
    // 因此首页是真实加载出来的，不是空态。
    final imported = await state.importConfig(
      jsonEncode({
        'name': '浏览页 fixture',
        'sites': [
          {
            'key': 'fixture',
            'name': 'Fixture 站',
            'type': 1,
            'api': 'http://127.0.0.1:18080/api.php/provide/vod/',
            'searchable': 1,
          },
        ],
      }),
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);
    for (var i = 0; i < 8; i++) {
      state.database!.recordHealth(
        siteKey: 'fixture',
        action: HealthAction.home,
        success: i < 7,
        latencyMs: 95,
      );
    }

    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: AppShell(state: state, startup: const StartupArguments()),
      ),
    );

    // 真实 HTTP 要走真实 async 区，所以交替 pump 与 runAsync 直到首页就绪。
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      if (state.contentPhase == LoadPhase.ready) break;
    }
    await tester.pump(const Duration(milliseconds: 300));

    await capture(tester, relativePath: '.impeccable/review/browse-dark.png');

    expect(state.contentPhase, LoadPhase.ready, reason: '首页未就绪');

    // 需求①：**没有筛选维度就不该有筛选按钮**。
    // 停在「默认推荐」时没有选中任何分类，`filtersFor` 返回空 → 按钮不渲染。
    expect(
      find.byKey(const ValueKey('category-filter-menu')),
      findsNothing,
      reason: '默认推荐页没有分类筛选维度，不该出现筛选按钮',
    );

    // 进入一个分类后才有筛选维度（fixture 的 home.json 给 type_id=1 带了三组）。
    await tester.tap(find.byKey(const ValueKey('browse-tab-1')));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      if (state.contentPhase == LoadPhase.ready) break;
    }
    await tester.pump(const Duration(milliseconds: 300));

    // 需求②：筛选区域**不再默认展示**，改为按钮点击后悬浮显示。
    final filterButton = find.byKey(const ValueKey('category-filter-menu'));
    expect(filterButton, findsOneWidget, reason: '分类有筛选维度时必须给出「筛选」入口');
    // 面板默认是关的：按钮在、面板内容不在。
    expect(find.text('重置筛选'), findsNothing, reason: '还没筛过，不该有重置入口');

    // 这张图拍的是**面板关闭**时的分类条：它证明的是**需求①②**——筛选按钮出现
    // 在刷新旁边、且筛选区域不再常驻。所以必须在 `tap` 面板按钮**之前**拍，
    // 否则它和下一张「展开的面板」是同一帧（曾经两张图字节完全相同，白存一张）。
    await capture(
      tester,
      relativePath: '.impeccable/review/browse-filter-button.png',
    );

    // 点开后必须真的出现维度（而不是空面板）。
    await tester.tap(filterButton);
    await tester.pumpAndSettle();
    expect(find.text('剧情'), findsWidgets, reason: '面板里应有「剧情」维度');
    expect(find.text('地区'), findsWidgets, reason: '面板里应有「地区」维度');
    // 专门的展开面板证据图：全宽、维度按可用宽排成多列。
    //
    // 面板是**页面内联区**（不再是 `MenuAnchor` 挂在 `Navigator` 的 `Overlay`
    // 里的浮层），所以树中第一个 `RepaintBoundary`（`Scaffold` 那层）就能把它
    // 一起拍进来——原先"拍不到面板"的限制随这次改造一起消失了。
    await capture(
      tester,
      relativePath: '.impeccable/review/browse-filter-panel-dark.png',
    );

    // 让一个筛选维度真的生效，才拍得到底部那条「已生效 N 项 + 重置筛选」。
    //
    // 直接驱动状态而不是点 chip：chip 的 key 依赖站点给的选项值，而行数/列数
    // 本来就是这条证据要看的东西，不必再赌一次坐标。`setCategoryFilter` 会立刻
    // 重载当前分类（真实 HTTP），所以要用 `runAsync` 让真实 async 区跑完。
    await tester.runAsync(() => state.setCategoryFilter('class', '喜剧'));
    // `pumpAndSettle` 在这里不可用：重载期间页面有持续动画的进度指示器，永远不会
    // settle。改为有界 pump 循环，直到重置入口出现为止（最多 20 次，每次 50ms）。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find
          .byKey(const ValueKey('category-filter-clear'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    // 重置条一挂上，外层 AnimatedSize 才刚开始逐帧撑高面板：命中首帧拍到的是
    // 被裁掉下半截的面板，且此刻点「重置筛选」会落在裁剪区外（hit test 打空，
    // 于是重置没生效、重置入口留在原地）。所以再泵固定一段时长让尺寸动画走完。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byKey(const ValueKey('category-filter-clear')),
      findsOneWidget,
      reason: '筛选生效后底部必须给出「重置筛选」',
    );
    await capture(
      tester,
      relativePath: '.impeccable/review/browse-filter-panel-active-dark.png',
    );

    // 重置也走真实 HTTP 重载：先让真实 async 区把请求跑完再 settle，否则加载期的
    // 进度指示器是无限动画，`pumpAndSettle` 会直接超时。
    await tester.tap(find.byKey(const ValueKey('category-filter-clear')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      if (state.contentPhase == LoadPhase.ready) break;
    }
    await tester.pumpAndSettle();
    expect(find.text('重置筛选'), findsNothing, reason: '重置后不该再留着重置入口');

    // 收起 → 再展开 → 再收起：确认这个来回不会把面板状态弄坏（异常由末尾统一取）。
    await tester.tap(filterButton);
    await tester.pumpAndSettle();
    await tester.tap(filterButton);
    await tester.pumpAndSettle();
    await tester.tap(filterButton);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('播放器控制条（dark，1440x900）', (tester) async {
    if (!await _fixtureReachable()) {
      markTestSkipped(
        'fixture 服务不可达（$fixtureBaseUrl）：'
        '先运行 `python tools/fixture_server/server.py`',
      );
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-ui-player');
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

    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: '$fixtureBaseUrl/media/sample.m3u8',
              title: '示例剧集',
              siteKey: 'fixture',
              vodId: 'demo-1',
              vodName: '示例剧集',
              episodeName: 'E3',
              flag: '线路一',
              // fixture 媒体要求带 Referer 与 UA（`tools/fixture_server/README.md`）。
              headers: const {
                'Referer': 'http://127.0.0.1:18080/',
                'User-Agent': 'WebHTV-PC-Phase0',
              },
            ),
          ),
        ),
      ),
    );

    // 等真实出画：媒体解码要走真实 async 区。
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
    }

    // 控制条会随不活动自动隐藏——截图前点一下画面让它出现，
    // 否则拍到的是一块纯视频、验证不到本次改动的控制条。
    await tester.tap(find.byType(PlayerPage), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 500));

    await capture(tester, relativePath: '.impeccable/review/player-dark.png');

    // 顶栏重组的**硬约束**：这两个 tooltip 被集成测试按精确串查找并直接 `tap`
    // （`subtitle_flow_test.dart:144`、`danmaku_flow_test.dart:156`，
    // `find.byTooltip` 对 String 是精确匹配，见 flutter_test `finders.dart:407`）。
    // 它们一旦被收进溢出菜单，那些测试就会点空。
    expect(find.byTooltip('字幕轨'), findsOneWidget);
    expect(find.byTooltip('弹幕（开启）'), findsOneWidget);
    // 收进去的那几个改为经溢出菜单进入。
    //
    // 断言必须**限定在 AppBar 内**：底部控制条本来就有同名按钮
    // （`字幕样式` / `画面比例与缩放` / `媒体信息`），全局查找会命中它们。
    Finder inAppBar(String tooltip) => find.descendant(
      of: find.byType(AppBar),
      matching: find.byTooltip(tooltip),
    );
    expect(inAppBar('更多'), findsOneWidget);
    expect(inAppBar('媒体信息'), findsNothing);
    expect(inAppBar('快捷键说明'), findsNothing);
    expect(inAppBar('画面比例与缩放'), findsNothing);

    // 去重锁：这些动作现在**只有一处**。
    // 顶栏不再有全屏（归底部控制条）；底部控制条不再有轨道/显示类按钮（归顶栏）。
    expect(inAppBar('全屏'), findsNothing);
    expect(inAppBar('退出全屏'), findsNothing);
    expect(find.byTooltip('全屏（F11）'), findsOneWidget);
    expect(find.byTooltip('字幕样式'), findsNothing);
    expect(find.byTooltip('弹幕设置'), findsNothing);
    expect(find.byTooltip('画面比例与缩放（contain）'), findsNothing);

    // 溢出菜单真的能打开，且里面的项都在。
    //
    // 本轮把右键菜单扩成 PotPlayer 式 10 组多层之后，「更多」收敛为**只留
    // 右键之外再没有别的入口**的五项（字幕样式 / 弹幕设置 / 画面比例与缩放 /
    // 媒体信息 / 快捷键说明）。原来这里断言的 播放诊断、音轨、视频轨、
    // 循环与定时、LUT 滤镜 已各有更近的入口（右键菜单分组 / 设置页日志页），
    // 因此**下面同时加了它们不该出现在溢出菜单里的反向锁**：收敛如果不彻底
    // （新旧项并存），那些反向锁会红。
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    for (final label in ['字幕样式', '弹幕设置', '画面比例与缩放', '媒体信息', '快捷键说明']) {
      expect(find.text(label), findsWidgets, reason: '溢出菜单缺少「$label」');
    }
    for (final label in ['播放诊断', '音轨', '视频轨', '循环与定时', 'LUT 滤镜']) {
      expect(
        find.text(label),
        findsNothing,
        reason: '「$label」已归右键菜单，不得在收敛后的溢出菜单里重复出现',
      );
    }
    // 这里**不截图**：`PopupMenu` 渲染在 `Navigator` 的 `Overlay` 里，
    // 而本 harness 的 `capture` 取的是树中第一个 `RepaintBoundary`
    // （`Scaffold` 那一层），**拍不到浮层**。截出来的图与上一张逐字节相同，
    // 是假证据。菜单内容改由上面的断言保证——**不拿重复的图冒充新证据**。
    await tester.tapAt(const Offset(20, 700)); // 关掉菜单，避免影响后续用例
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('配置的品牌字段：wallpaper + logo 真的生效（dark，1440x900）', (tester) async {
    if (!await _fixtureReachable()) {
      markTestSkipped(
        'fixture 服务不可达（$fixtureBaseUrl）：'
        '先运行 `python tools/fixture_server/server.py`',
      );
      return;
    }
    final temp = Directory.systemTemp.createTempSync('webhtv-ui-brand');
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
    File('${paths.configDir}${Platform.pathSeparator}usage-boundary-accepted')
        .writeAsStringSync(DateTime.now().toIso8601String());

    // `wallpaper` 与 `logo` 是**配置协议自带的品牌字段**，此前被解析并持久化
    // 但 `lib/ui/` 从未呈现（用户确认必须让它们真正生效）。
    // 这里用 fixture 的真实 PNG 当作这两个字段的值。
    final imported = await state.importConfig(
      jsonEncode({
        'name': '品牌字段 fixture',
        'wallpaper': '$fixtureBaseUrl/tmdb-img/w780/b1.jpg',
        'logo': '$fixtureBaseUrl/tmdb-img/w342/p1.jpg',
        'sites': _sites,
      }),
    );
    expect(imported, isTrue, reason: state.lastError?.logLine);
    seedHealth(state.database!);

    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: AppShell(state: state, startup: const StartupArguments()),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 120));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
    }

    await capture(
      tester,
      relativePath: '.impeccable/review/shell-branded-dark.png',
    );

    // 品牌字段必须真的进入渲染：至少有两个网络图（壁纸 + logo）。
    final networkImages = find.byType(Image).evaluate().where((element) {
      return (element.widget as Image).image is NetworkImage;
    }).length;
    expect(
      networkImages,
      greaterThanOrEqualTo(2),
      reason: '壁纸与 logo 都应当是从配置 URL 加载的网络图',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('站点健康页：源场点阵 + 未知说明（dark，1440x900）', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-ui-health');
    final state = await _bootState(temp);
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: SiteHealthPage(state: state),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await capture(
      tester,
      relativePath: '.impeccable/review/site-health-dark.png',
    );

    // 源场四态都在，并且"未知"被解释过（不是被读成"源全挂了"）。
    for (final legend in ['可用', '降级', '失效', '未知']) {
      expect(find.text(legend), findsWidgets, reason: '源场图例缺少「$legend」');
    }
    expect(find.textContaining('尚无实测记录'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chip 状态表：选中 / 未选中 / 禁用 / 静态（dark，1440x900）', (tester) async {
    // 这张表是给**视觉复核**用的：2026-10-11 的缺陷（筛选 chip「全是选中状态、
    // 点了没反应」）本质是渲染问题，只有看图才能确认修好。
    // 单测锁住了颜色语义，这里锁住"眼睛看到的样子"。
    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Widget row(String title, List<Widget> chips) => Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: AppSpace.sm),
          Wrap(children: chips),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                row('可选 · 启用（选中 = 琥珀淡底，未选中 = 透明）', const [
                  TagChip(
                    keyValue: 'a1',
                    label: '全部',
                    onTap: _noop,
                    selectable: true,
                  ),
                  TagChip(
                    keyValue: 'a2',
                    label: '喜剧',
                    selected: true,
                    onTap: _noop,
                    selectable: true,
                  ),
                  TagChip(
                    keyValue: 'a3',
                    label: '爱情',
                    onTap: _noop,
                    selectable: true,
                  ),
                  TagChip(
                    keyValue: 'a4',
                    label: '恐怖',
                    onTap: _noop,
                    selectable: true,
                  ),
                ]),
                row('可选 · 禁用（整体降透明，**选中态保留**）', const [
                  TagChip(keyValue: 'b1', label: '全部', selectable: true),
                  TagChip(
                    keyValue: 'b2',
                    label: '喜剧',
                    selected: true,
                    selectable: true,
                  ),
                  TagChip(keyValue: 'b3', label: '爱情', selectable: true),
                  TagChip(keyValue: 'b4', label: '恐怖', selectable: true),
                ]),
                row('静态标签（填充底，不可点）', const [
                  TagChip(keyValue: 'c1', label: '2024'),
                  TagChip(keyValue: 'c2', label: '45 分钟'),
                  TagChip(keyValue: 'c3', label: 'TMDB 8.2', emphasized: true),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await capture(
      tester,
      relativePath: '.impeccable/review/chip-states-dark.png',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('其余五个面：配置 / TMDB 设置 / 站点选择 / 直播 / Spider（dark，1440x900）', (
    tester,
  ) async {
    // 这五个面此前**从未被眼睛看过**——只有 widget 测试背书。
    // widget 测试能证明结构对，证明不了"看起来对"（层级、密度、对比度、
    // 有没有框架默认值漏进来），而后者恰恰是这次改造的主题。
    final temp = Directory.systemTemp.createTempSync('webhtv-ui-surfaces');
    final state = await _bootState(temp);
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Future<void> shoot(String name, Widget page) async {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.dark),
          home: page,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await capture(tester, relativePath: '.impeccable/review/$name.png');
      expect(tester.takeException(), isNull, reason: '$name 渲染时抛异常');
    }

    // `ConfigPage` / `TmdbSettingsPage` 自带 `Scaffold`（它们是独立路由页）；
    // `LivePage` / `SpiderPage` 是外壳的 body 内容，需要外面套 `Scaffold`。
    await shoot('config-dark', ConfigPage(state: state));
    await shoot('tmdb-settings-dark', TmdbSettingsPage(state: state));
    await shoot('spider-dark', Scaffold(body: SpiderPage(state: state)));
    await shoot('live-dark', Scaffold(body: LivePage(state: state)));
    // 站点选择是对话框：直接把它当页面内容渲染，拍到的就是对话框本身。
    await shoot(
      'site-picker-dark',
      Scaffold(
        body: Center(
          child: SitePickerDialog(
            items: state.siteItems,
            log: state.log,
            selectedKey: state.selectedSite?.key,
          ),
        ),
      ),
    );
  });

  testWidgets('设置页：主题开关（dark，1440x900）', (tester) async {
    final temp = Directory.systemTemp.createTempSync('webhtv-ui-settings');
    final state = await _bootState(temp);
    addTearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    useViewport(tester, const Size(1440, 900));
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(Brightness.dark),
        home: Scaffold(body: SettingsPage(state: state)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await selectSettingsCategory(tester, 'preferences');

    await capture(tester, relativePath: '.impeccable/review/settings-dark.png');

    expect(
      find.byKey(const ValueKey('settings-theme-mode')),
      findsOneWidget,
      reason: '设置页必须有主题开关',
    );

    // 站点健康入口必须存在：源场从首页搬到独立页之后，这里就是**唯一**的入口。
    // 入口断掉的话，功能等于被删掉了——这正是本项目历史上踩过的坑
    // （`TmdbSettingsPage` 曾因为入口没被渲染而成为死代码）。
    //
    // 健康入口属于维护分类，不再要求和偏好同时出现在首屏。
    await selectSettingsCategory(tester, 'maintenance');

    final healthEntry = find.byKey(const ValueKey('settings-site-health-open'));
    expect(healthEntry, findsOneWidget, reason: '设置页必须有站点健康入口（源场唯一入口）');
    await capture(
      tester,
      relativePath: '.impeccable/review/settings-health-entry-dark.png',
    );

    expect(tester.takeException(), isNull);
  });
}
