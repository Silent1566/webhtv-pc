/// 详情页「播放失败 → 换源 → 自动续播」接线门禁。
///
/// 覆盖三条真实可达的路径（见 `browse_pages.dart` 的 `_play` catch 与
/// `_resumeAfterSourceSwap`）：
/// 1. 点集数卡片失败 → 弹确认框（不是一闪而过的 SnackBar），「知道了」什么都不做；
/// 2. 确认「换源」→ 并入后按原来的集号自动续播，且走新并入的外部线路；
/// 3. 关掉浮层（返回 null）→ 续播意图必须清掉，之后再一次并入不得自动播放。
///
/// 站点是 `type=1` HTTP API + 注入的假客户端：`testWidgets` 的 fake-async
/// 区推不动真实 socket，注入 `httpClient` 是仓库既有的可测性口子
/// （`detail_source_swap_test.dart` 同一模式）。
///
/// 详情页自己的线路刻意给**不可播目标**（`no-such-target`）：`type=1` 不在
/// `SiteService` 的 `mustCallPlay` 名单里，`PlaybackResolver` 初判抛出的异常被
/// 吞掉后落到播放入口，最终 `_resolvePlayEntryTarget` 如实抛出 AppError——
/// 这正是确认框的入口，且不依赖任何真实网络。
///
/// 自动续播要能被观测：并入后 `_play` 会 push `PlayerPage`，所以按
/// `support/player_page_harness.dart` 的做法把 `media_kit_video` 的 MethodChannel
/// mock 掉，直接读 `PlayerPage.request`——它同时带上 `episodeName`（续播到哪一集）、
/// `episodeTarget`（哪一集的地址）与 `siteKey`（哪条外部线路），三个维度一起把
/// 「续播了原来那一集」和「定向解析没串回老站点」都锁住。
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
  "name": "详情续播换源测试",
  "sites": [
    {"key": "ui-main", "name": "主站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 0},
    {"key": "ui-swap", "name": "换源站[盘]", "type": 1, "api": "http://127.0.0.1:1/api/type1/", "searchable": 1}
  ]
}
''';

void main() {
  late Directory tempDir;
  late AppState state;
  late _ResumeSiteClient siteClient;

  setUp(() async {
    // `toastCenter` 是进程级单例：上一条用例留下的通知会漏进这一条。
    dismissAllToasts();
    tempDir = await Directory.systemTemp.createTemp('webhtv-detail-resume');
    siteClient = _ResumeSiteClient();
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
    // 先收通知再销毁状态（通知的 `onDismiss` 会回调 `clearDetailError()`）。
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

  /// 详情页自己的条目：两集，目标都不可播（`type=1` 会如实报错）。
  Vod detailVod() => Vod(
    vodId: 'main-1',
    vodName: '换源目标影片',
    vodPlayFrom: 'orig',
    vodPlayUrl: '原第1集\$no-such-target-1#原第2集\$no-such-target-2',
  );

  Future<void> pumpDetail(WidgetTester tester) async {
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
        // 通知宿主挂在 `home:` 的 `Stack` 里，而不是生产的 `MaterialApp.builder`。
        // 原因（实测）：`builder` 把宿主放在 Navigator **之上**，浮层底部那颗
        // 「并入」按钮的点击会落到通知层（tap 报 "derived an Offset that would not
        // hit test"，命中链里是通知卡片）。本文件只验证「消息以通知形式到达用户」，
        // 不验证层级；生产挂法与层级由 `test/toast_host_test.dart` 锁定。
        home: Stack(
          fit: StackFit.expand,
          children: [
            DetailPage(state: state, vod: detailVod()),
            const ToastHost(),
          ],
        ),
      ),
    );
    await pumpFrames(tester);
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
    await tester.tap(card);
    await pumpFrames(tester);
  }

  /// 浮层里勾选换源站候选 → 解析 → 并入（走完整真实接线）。
  Future<void> commitSwap(WidgetTester tester) async {
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
    // 错误通知驻留右下角 15 秒，正好压在浮层底部的「并入」按钮上：测试里不能等
    // 它自己过去，先按用户会做的动作（点 ×）收走，否则这次点击落在通知卡片上。
    dismissAllToasts();
    await pumpFrames(tester, times: 2);
    await tester.tap(find.byKey(const ValueKey('source-swap-commit')));
    await pumpFrames(tester);
  }

  testWidgets('集数卡片播放失败弹确认框，「知道了」不换源也不播放', (tester) async {
    await prepare(tester);
    await pumpDetail(tester);
    await tapEpisodeCard(tester, 1);

    expect(
      find.byKey(const ValueKey('detail-playback-failed-boundary')),
      findsOneWidget,
      reason: '证据截图要按 key 指到这一层 RepaintBoundary',
    );
    expect(
      find.byKey(const ValueKey('detail-playback-failed')),
      findsOneWidget,
    );
    expect(find.text('这一集没有可播放的地址'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('detail-playback-failed')),
        matching: find.text('原第2集'),
      ),
      findsOneWidget,
      reason: '正文要指认失败的是哪一集',
    );
    expect(
      find.byKey(const ValueKey('detail-playback-failed-swap')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('detail-playback-failed-dismiss')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('detail-playback-failed-dismiss')),
    );
    await pumpFrames(tester);

    expect(
      find.byKey(const ValueKey('detail-playback-failed')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsNothing,
      reason: '「知道了」不得升起换源浮层',
    );
    expect(find.byType(PlayerPage), findsNothing);

    // 反向锁：`_resumingAfterSwap` 若在失败路径上没有复位，第二次失败就不再弹框
    // （只闪 SnackBar），那时这里会 findsNothing。
    await tapEpisodeCard(tester, 1);
    expect(
      find.byKey(const ValueKey('detail-playback-failed')),
      findsOneWidget,
      reason: '第二次失败仍须弹确认框',
    );
    await tester.tap(
      find.byKey(const ValueKey('detail-playback-failed-dismiss')),
    );
    await pumpFrames(tester);
  });

  testWidgets('确认换源并入后自动续播同一集号，且走新并入的外部线路', (tester) async {
    await prepare(tester);
    await pumpDetail(tester);
    await tapEpisodeCard(tester, 1);

    await tester.tap(
      find.byKey(const ValueKey('detail-playback-failed-swap')),
    );
    await pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsOneWidget,
      reason: '只有确认「换源」才打开浮层',
    );

    await commitSwap(tester);

    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsNothing,
      reason: '并入后浮层应关闭',
    );
    final page = find.byType(PlayerPage);
    expect(page, findsOneWidget, reason: '并入后必须自动续播（确认框的承诺）');
    final request = tester.widget<PlayerPage>(page).request;
    expect(
      request.episodeName,
      '换源第2集',
      reason: '续播必须回到原来那一集（第 2 集），不是新线路第 1 集',
    );
    expect(request.episodeTarget, 'http://127.0.0.1:1/media/e2.mp4');
    expect(
      request.siteKey,
      'ui-swap',
      reason: '续播必须走新并入的外部线路（定向解析不得串回老站点）',
    );
  });

  testWidgets('关掉浮层清掉续播意图，之后的并入不得自动播放', (tester) async {
    await prepare(tester);
    await pumpDetail(tester);
    await tapEpisodeCard(tester, 1);

    await tester.tap(
      find.byKey(const ValueKey('detail-playback-failed-swap')),
    );
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('source-swap-sheet')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('source-swap-close')));
    await pumpFrames(tester);
    expect(find.byKey(const ValueKey('source-swap-sheet')), findsNothing);
    expect(
      find.byType(PlayerPage),
      findsNothing,
      reason: '关掉浮层不得播放',
    );

    // 再走一次换源：这次入口是线路行上常驻的「换源」次入口，没有失败确认，
    // 也就没有续播意图。若浮层关闭时没清掉 `_pendingResumeEpisode`，这里会被
    // 残留的意图自动播放。
    //
    // 不能用错误条 CTA（`detail-swap-source`）：`showSourceSwapSheet()` 打开浮层
    // 前会 `dismissAllToasts()`，那条通知连同 `detailError` 一起被清掉。
    //
    // 线路行在 hero 之后（hero 占满整屏），而正文是**惰性** ListView：停在第 0 屏
    // 时它根本没挂载，所以先回到顶部，再往下滚到它出现为止。`ensureVisible` 会把它
    // 贴到 AppBar 底下（命中测试被 AppBar 吃掉），滚出来的位置在视口内，可直接点。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await pumpFrames(tester, times: 6);
    final lineSwap = find.byKey(const ValueKey('tmdb-line-swap'));
    await tester.scrollUntilVisible(
      lineSwap,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await pumpFrames(tester, times: 6);
    expect(lineSwap, findsOneWidget, reason: '线路行上的常驻换源入口应在页面顶部区域内');
    await tester.tap(lineSwap);
    await pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('source-swap-sheet')),
      findsOneWidget,
      reason: '常驻换源入口必须升起换源浮层（这一轮不带续播意图）',
    );
    await pumpFrames(tester);
    await commitSwap(tester);

    expect(
      find.byType(PlayerPage),
      findsNothing,
      reason: '没有续播意图时，并入不得自动播放',
    );
    await scrollPastHero(tester);
    expect(
      find.textContaining('换源第1集'),
      findsWidgets,
      reason: '前置条件：这一次并入确实成功了（外部线路已选中）',
    );
  });

  // 回归：正文只报**具体原因**，不得把错误类别再拼一遍。
  //
  // 详情页自己的线路 `ui-main` 没声明 playUrl，播放入口兜底抛出的正是
  // kind=playbackParserRequired、message=「站点 ui-main 未声明 playUrl…」、
  // detail=「需要解析器或 Spider 运行时（MVP-A 未实现）」；而 kind 的描述就是
  // 那句话本身，于是 `userMessage` 拼成「类别：message（类别）」——括号嵌套的
  // 重复噪音（用户实测截图）。这里锁住正文＝message 原文，且那段重复文字一次
  // 都不出现；旧实现用 `failure.userMessage` 必然污染正文。
  testWidgets('确认框正文只给具体原因，不重复错误类别', (tester) async {
    await prepare(tester);
    await pumpDetail(tester);
    await tapEpisodeCard(tester, 1);

    final dialog = find.byKey(const ValueKey('detail-playback-failed'));
    expect(dialog, findsOneWidget, reason: '前置条件：确认框应已弹出');
    expect(find.text('这一集没有可播放的地址'), findsOneWidget);

    const reason = '站点 ui-main 未声明 playUrl，且剧集目标不是直链';
    expect(
      find.descendant(of: dialog, matching: find.text(reason)),
      findsOneWidget,
      reason: '正文要显示具体原因（AppError.message 原文），整行不得再拼类别',
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('MVP-A 未实现')),
      findsNothing,
      reason: 'detail 与错误类别重复，正文不得再出现这段技术术语',
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('该剧集需要解析器或 Spider 运行时'),
      ),
      findsNothing,
      reason: '错误类别描述不得出现在正文（标题已经说清了没有地址）',
    );

    await tester.tap(
      find.byKey(const ValueKey('detail-playback-failed-dismiss')),
    );
    await pumpFrames(tester);
  });
}

/// 假站点客户端：搜索与详情都走这里，不碰真实 socket。
class _ResumeSiteClient extends http.BaseClient {
  /// 详情请求的 `ids` 参数。
  final List<String> detailIds = [];

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
