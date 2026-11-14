/// 换源后自动续播的**定位算法**门禁（集号定位，不是下标定位）。
///
/// 邻接门禁 `detail_playback_resume_swap_test.dart` 只锁「续播这件事发生了」，
/// 它锁不住两条会静默播错的语义：
/// 1. 目标线路选错：旧实现里 `best` 的初值是**原线路**，只有外部线路集数
///    `>=` 它时才被顶替。于是「原线路第 5 集失败 → 换源 → 新源只有 2 集」会拿
///    那条已经证明播不通的原线路去续播，换源等于没换（而且续播那一趟抑制了
///    确认框，用户只看到一条 SnackBar）。
/// 2. 定位用错身份：旧实现把旧线路的**数组下标**直接套到新线路上。不同站点的
///    剧集数组不同构（预告/花絮、季集混排），下标相同不等于同一集，会静默播错。
///
/// 这里用「新线路短于原线路」和「新线路前面多一条预告（下标整体偏移）」两种
/// 形状把上面两条锁住：第一种只有落回外部线路才可能播到新线路第 1 集，第二种
/// 只有按集号定位才可能播到第 2 集。
///
/// 站点是 `type=1` HTTP API + 注入的假客户端（`testWidgets` 的 fake-async 区推
/// 不动真实 socket，注入 `httpClient` 是仓库既有的可测性口子）。详情页自己的
/// 线路刻意给不可播目标：`type=1` 不在 `mustCallPlay` 名单里，最终
/// `_resolvePlayEntryTarget` 如实抛 AppError，正好是确认框入口。
///
/// 浮层里的加载指示器是无限动画，`pumpAndSettle` 必然 timeout，一律显式推帧。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/player_page_harness.dart';

/// `主站[盘]` 承载详情页自己的线路（不可搜），`换源站[盘]` 可搜。
const String _configJson = '''
{
  "name": "详情续播定位测试",
  "sites": [
    {"key": "ui-main", "name": "主站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 0},
    {"key": "ui-swap", "name": "换源站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 1}
  ]
}
''';

void main() {
  late Directory tempDir;
  late AppState state;
  late _LocatorSiteClient siteClient;

  setUp(() async {
    // `toastCenter` 是进程级单例：上一条用例留下的通知会漏进这一条。
    dismissAllToasts();
    tempDir = await Directory.systemTemp.createTemp('webhtv-detail-locator');
    siteClient = _LocatorSiteClient();
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
      httpClient: siteClient,
    );
    // 详情页 `initState` 会碰 `state.tmdb`（TMDB 身份服务由 bootstrap 装配）。
    await state.bootstrap();
  });

  tearDown(() async {
    // 先收通知再销毁状态（通知的 `onDismiss` 会回调状态层）。
    dismissAllToasts();
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

  Future<void> prepare(WidgetTester tester) async {
    await tester.runAsync(() async {
      final ok = await state.importConfig(_configJson);
      expect(ok, isTrue, reason: '配置导入应成功');
    });
  }

  /// 详情页自己的条目：[count] 集，目标都不可播（`type=1` 会如实报错）。
  Vod detailVod({required int count}) {
    final pairs = [
      for (var i = 1; i <= count; i += 1) '原第$i集\$no-such-target-$i',
    ];
    return Vod(
      vodId: 'main-1',
      vodName: '换源目标影片',
      vodPlayFrom: 'orig',
      vodPlayUrl: pairs.join('#'),
    );
  }

  Future<void> pumpDetail(WidgetTester tester, {required int episodeCount}) async {
    // PlayerPage 会在自动续播时被 push，媒体通道必须先 mock（见文件头注释）。
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester);
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        // 通知宿主挂在 `home:` 的 `Stack` 里（在 Navigator 的 Overlay 内），
        // 而不是 `MaterialApp.builder`：后者在 Overlay 之外，且会吃掉下方内容的
        // 命中测试。挂法与层级由 `test/toast_host_test.dart` 单独锁定。
        home: Stack(
          fit: StackFit.expand,
          children: [
            DetailPage(state: state, vod: detailVod(count: episodeCount)),
            const ToastHost(),
          ],
        ),
      ),
    );
    await pumpFrames(tester);
  }

  /// 收走当前所有通知，等同用户点「×」。
  ///
  /// 错误通知驻留右下角 15 秒，而详情页的错误通知正好压住右下角的集数卡片与
  /// 浮层底部的「并入」按钮：测试里不能等那 15 秒自己过去，先收走，
  /// 否则 `tap` 会落在通知卡片上（`derived an Offset that would not hit test`）。
  Future<void> clearToasts(WidgetTester tester) async {
    dismissAllToasts();
    await pumpFrames(tester, times: 2);
  }

  Future<void> scrollPastHero(WidgetTester tester) async {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await pumpFrames(tester, times: 4);
  }

  /// 点第 `index` 张集数卡片（0 基，对应详情页自己那条线路）。
  Future<void> tapEpisodeCard(WidgetTester tester, int index) async {
    await scrollPastHero(tester);
    final card = find.byKey(ValueKey('tmdb-episode-card-orig-$index'));
    expect(card, findsOneWidget, reason: '详情页自己的线路应有第 ${index + 1} 张集数卡片');
    await tester.ensureVisible(card);
    await pumpFrames(tester, times: 4);
    await clearToasts(tester);
    await tester.tap(card);
    await pumpFrames(tester);
  }

  /// 点失败确认框里的「换源」，浮层应当升起。
  Future<void> openSwapSheet(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey('detail-playback-failed-swap')),
    );
    await pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsOneWidget,
      reason: '只有确认「换源」才打开浮层',
    );
  }

  /// 浮层里勾选换源站候选 → 解析 → 并入（走完整真实接线）。
  ///
  /// 两次 commit：第一次解析候选（解析完才显示 [expectedCountLabel]），
  /// 第二次真正并入。`source-swap-commit` 每推一帧都在，不能靠它判断阶段。
  Future<void> commitSwap(
    WidgetTester tester, {
    required String expectedCountLabel,
  }) async {
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
      find.textContaining(expectedCountLabel),
      findsWidgets,
      reason: '解析后该候选显示集数',
    );
    // 第二次「并入」前必须收走常驻的错误通知（它压在浮层底部那颗按钮上）。
    await clearToasts(tester);
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpFrames(tester);
  }

  PlayerPage playedPage(WidgetTester tester) {
    final page = find.byType(PlayerPage);
    expect(page, findsOneWidget, reason: '并入后必须自动续播');
    return tester.widget<PlayerPage>(page);
  }

  /// 在当前树里找「通知渲染出的文案」，**包含 offstage 子树**。
  ///
  /// 为什么需要 `skipOffstage: false`：续播会 push `PlayerPage`（不透明路由），
  /// 路由盖住之后它下面的 `home:` 路由（本 harness 的宿住在那里）就被 Overlay
  /// 标成 offstage，默认 finder 会整片跳过——但那条通知确实被 `ToastHost`
  /// 画出来了（生产把宿主挂在 `MaterialApp.builder`，本就在所有路由之上，
  /// 用 `builder` 会吃掉下方内容的命中测试，见 `test/toast_host_test.dart`）。
  Finder toastText(String text) =>
      find.textContaining(text, skipOffstage: false);

  testWidgets('换源目标比原线路短时，续播落在外部线路第 1 集并提示回退', (tester) async {
    // 外部线路只有 2 集，比原线路的 5 集短。旧实现里 `best` 会留在这条已经
    // 证明播不通的原线路上（原线路 5 集 >= 外部 2 集），续播等于白换。
    siteClient.vodPlayUrl =
        '换源第01集\$http://127.0.0.1:1/media/s1.mp4#换源第02集\$http://127.0.0.1:1/media/s2.mp4';

    await prepare(tester);
    await pumpDetail(tester, episodeCount: 5);

    // 点第 5 集：1-based 集号 = 5，外部线路既没有集号 5 的集名，下标 4 也越界。
    await tapEpisodeCard(tester, 4);
    await openSwapSheet(tester);
    await commitSwap(tester, expectedCountLabel: '2 集');

    final request = playedPage(tester).request;
    expect(
      request.siteKey,
      'ui-swap',
      reason: '续播必须落在新并入的外部线路上，不能回刚失败的原线路',
    );
    expect(
      request.episodeName,
      '换源第01集',
      reason: '外部线路没有同一集号，按约定回退到它的第 1 集',
    );
    expect(request.episodeTarget, 'http://127.0.0.1:1/media/s1.mp4');
    expect(
      toastText('已从第 1 集开始播放'),
      findsWidgets,
      reason: '回退必须告诉用户为什么没接着看第 5 集',
    );
    expect(
      toastText('只有 2 集'),
      findsWidgets,
      reason: '提示要带上目标线路的实际集数',
    );
  });

  testWidgets('外部线路前面多一条预告时，按集号而不是下标定位到第 2 集', (tester) async {
    // 下标整体偏移：预告占了 index 0，于是「原第 2 集」的旧下标 1 指向的其实是
    // 换源第01集。只有按集号定位才会播到换源第02集。
    siteClient.vodPlayUrl =
        '预告\$http://127.0.0.1:1/media/trailer.mp4'
        '#换源第01集\$http://127.0.0.1:1/media/e01.mp4'
        '#换源第02集\$http://127.0.0.1:1/media/e02.mp4'
        '#换源第03集\$http://127.0.0.1:1/media/e03.mp4'
        '#换源第04集\$http://127.0.0.1:1/media/e04.mp4';

    await prepare(tester);
    await pumpDetail(tester, episodeCount: 3);

    // 点第 2 集：1-based 集号 = 2。
    await tapEpisodeCard(tester, 1);
    await openSwapSheet(tester);
    await commitSwap(tester, expectedCountLabel: '5 集');

    final request = playedPage(tester).request;
    expect(request.siteKey, 'ui-swap');
    expect(
      request.episodeName,
      '换源第02集',
      reason: '定位按集号：旧下标 1 在新线路上是换源第01集（错），预告还把它整体挪了一位',
    );
    expect(request.episodeTarget, 'http://127.0.0.1:1/media/e02.mp4');
    expect(
      toastText('已从第 1 集开始播放'),
      findsNothing,
      reason: '命中了同一集就不该提示回退',
    );
  });
}

/// 假站点客户端：搜索与详情都走这里，不碰真实 socket。
class _LocatorSiteClient extends http.BaseClient {
  /// 换源站 `swap-1` 的 `vod_play_url`（由各用例设定形状）。
  String vodPlayUrl = '';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final query = request.url.queryParameters;
    Map<String, Object?> payload;
    if (query['wd'] != null) {
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
      payload = id == 'swap-1'
          ? {
              'list': [
                {
                  'vod_id': 'swap-1',
                  'vod_name': '换源目标影片',
                  'vod_play_from': 'ext',
                  'vod_play_url': vodPlayUrl,
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
