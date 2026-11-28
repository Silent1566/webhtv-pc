import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/player_page.dart';

import 'support/detail_test_seams.dart';
import 'support/player_page_harness.dart';

class _FolderState extends AppState {
  _FolderState({required super.paths, required super.log, super.httpClient});
  bool instantPlayback = false;

  @override
  Future<PlaybackDecision?> resolvePlayback({
    required String episodeTarget,
    String? flag,
    String? vodId,
    int? qualityIndex,
    bool Function()? isCurrent,
    Site? siteOverride,
    String? preferredParseName,
    SiteService? serviceOverride,
  }) {
    if (instantPlayback) {
      return Future.value(
        const PlaybackDecision(
          action: PlaybackAction.direct,
          url: 'http://127.0.0.1:1/fixture.mp4',
        ),
      );
    }
    return super.resolvePlayback(
      episodeTarget: episodeTarget,
      flag: flag,
      vodId: vodId,
      qualityIndex: qualityIndex,
      isCurrent: isCurrent,
      siteOverride: siteOverride,
      preferredParseName: preferredParseName,
      serviceOverride: serviceOverride,
    );
  }
}

void main() {
  late Directory temp;
  late _FolderState state;
  final calls = <Uri>[];
  final failures = <String>{};
  Completer<http.Response>? delayed;
  Completer<http.Response>? heldPlay;
  var delayedResource = 'baidu';
  var sharedEntryUrl = false;
  var sameEpisodeNames = false;
  const sharedTarget = 'http://127.0.0.1:1/shared';
  final parent = Vod(
    vodId: 'atvp_detail:series',
    vodName: '原始作品名',
    vodTag: 'folder',
  );

  Map<String, Object?> detail(String resource) => {
    'list': [
      {
        'vod_id': 'atvp_resume:$resource',
        'vod_name': '分享资源标题',
        'vod_tag': 'file',
        // 真实网关里多个资源都可能返回同一个 flag，显示时要区分，播放时要原样发送。
        'vod_play_from': '丫仙女',
        'vod_play_url':
            '${sameEpisodeNames ? '第1集' : '${resource}01'}\$${sharedEntryUrl ? sharedTarget : '$resource@1'}#${resource}02\$$resource@2',
      },
    ],
  };
  http.Response response(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  setUp(() async {
    calls.clear();
    failures.clear();
    delayed = null;
    heldPlay = null;
    delayedResource = 'baidu';
    sharedEntryUrl = false;
    sameEpisodeNames = false;
    temp = Directory.systemTemp.createTempSync('webhtv-folder-lines');
    final client = MockClient((request) async {
      calls.add(request.url);
      final q = request.url.queryParameters;
      if (q.containsKey('play')) {
        if (q['play'] == 'held-first' && heldPlay != null) return heldPlay!.future;
        return response({'code': -1, 'msg': '已捕获播放目标'});
      }
      if (q.containsKey('ids')) {
        final resource = Uri.parse(q['ids']!).pathSegments.last;
        if (resource == delayedResource && delayed != null) {
          return delayed!.future;
        }
        if (failures.contains(resource)) {
          return response({'code': -1, 'msg': '资源暂时不可用'});
        }
        return response(detail(resource));
      }
      if (q.containsKey('t')) {
        return response({
          'list': [
            for (final resource in ['baidu', 'quark', 'uc'])
              {
                'vod_id': 'https://share.example/$resource',
                'vod_name': resource,
                'vod_tag': 'file',
              },
          ],
        });
      }
      return response({'list': []});
    });
    state = _FolderState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
      log: MemoryOnlyLogService(),
      httpClient: client,
    );
    await bootstrapWithoutExternalMeta(state);
    await state.importConfig(
      jsonEncode({
        'sites': [
          {
            'key': 'bridge',
            'name': '桥接站点',
            'type': 4,
            'api': 'http://127.0.0.1:19978/vod/api?key=bridge',
          },
        ],
      }),
    );
    calls.clear();
  });

  tearDown(() async {
    state.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> openDetail(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(state: state, vod: parent),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await tester.pumpAndSettle();
  }

  testWidgets('桥接详情自动展示标准线路与分集，切线路无需点分享资源', (tester) async {
    await openDetail(tester);
    expect(find.textContaining('选择资源'), findsNothing);
    expect(find.textContaining('baidu（2 集）'), findsOneWidget);
    expect(find.textContaining('quark（2 集）'), findsOneWidget);
    expect(find.textContaining('uc（2 集）'), findsOneWidget);
    expect(find.textContaining('baidu01'), findsWidgets);
    expect(calls.where((u) => u.queryParameters.containsKey('ids')).length, 3);
    expect(calls.where((u) => u.queryParameters.containsKey('play')), isEmpty);
    expect(state.detailResult!.list.single.vodId, parent.vodId);
    expect(state.selectedVod?.vodName, parent.vodName);

    await tester.tap(find.textContaining('uc（2 集）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('uc02'), findsWidgets);
    expect(find.textContaining('baidu01'), findsNothing);
    expect(calls.where((u) => u.queryParameters.containsKey('ids')).length, 3);
    await tester.tap(find.textContaining('uc02').first);
    await tester.pumpAndSettle();
    final play = calls.singleWhere(
      (u) => u.queryParameters.containsKey('play'),
    );
    expect(play.queryParameters['play'], 'uc@2');
    expect(play.queryParameters['flag'], '丫仙女');
  });

  testWidgets('桥接详情不等慢线路就可以看到已加载剧集', (tester) async {
    final gate = delayed = Completer<http.Response>();
    delayedResource = 'quark';
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(response(detail('quark')));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(state: state, vod: parent),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      calls
          .where((url) => url.queryParameters.containsKey('ids'))
          .map(
            (url) => Uri.parse(url.queryParameters['ids']!).pathSegments.last,
          ),
      ['baidu', 'quark'],
      reason: '第一条已完成，第二条仍在途；保持串行，不提前发第三条',
    );
    expect(gate.isCompleted, isFalse);
    expect(find.byKey(const ValueKey('detail-hero-play')), findsOneWidget);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await tester.pump();
    expect(find.textContaining('baidu01'), findsWidgets);
    expect(find.textContaining('quark（2 集）'), findsNothing);
    expect(find.byKey(const ValueKey('detail-lines-loading')), findsOneWidget);
    expect(state.detailLinesLoading, isTrue);
    final snapshot = state.detailResult!;
    final resolving = state
        .resolvePlayback(
          episodeTarget: 'baidu@2',
          flag: '丫仙女',
          vodId: parent.vodId,
        )
        .then<Object?>((value) => value, onError: (Object error) => error);
    await tester.pump();
    expect(
      calls.where((u) => u.queryParameters.containsKey('play')),
      isEmpty,
      reason: '已加载线路的播放不能和在途分享链详情并发',
    );

    gate.complete(response(detail('quark')));
    expect(await resolving, isA<AppError>());
    await tester.pumpAndSettle();
    expect(find.textContaining('quark（2 集）'), findsOneWidget);
    expect(find.textContaining('uc（2 集）'), findsOneWidget);
    expect(find.textContaining('baidu01'), findsWidgets);
    expect(find.byKey(const ValueKey('detail-lines-loading')), findsNothing);
    expect(state.detailLinesLoading, isFalse);
    expect(
      state.playLinesOf(snapshot.list.first),
      hasLength(1),
      reason: '已发布的快照不会被后续资源原地修改',
    );
    final relevant = calls
        .where(
          (url) =>
              url.queryParameters.containsKey('ids') ||
              url.queryParameters.containsKey('play'),
        )
        .toList();
    expect(
      relevant.map(
        (url) =>
            url.queryParameters['play'] ??
            Uri.parse(url.queryParameters['ids']!).pathSegments.last,
      ),
      ['baidu', 'quark', 'baidu@2', 'uc'],
    );
    expect(relevant[2].queryParameters['flag'], '丫仙女');
  });

  testWidgets('目录加载结束后不再串行阻塞同站的普通播放', (tester) async {
    await state.loadDetail(parent);
    final gate = heldPlay = Completer<http.Response>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(response({'code': -1, 'msg': '已结束'}));
    });
    final first = state.resolvePlayback(
      episodeTarget: 'held-first', flag: '丫仙女', vodId: parent.vodId,
    ).then<Object?>((value) => value, onError: (Object error) => error);
    await tester.pump();
    expect(calls.where((url) => url.queryParameters['play'] == 'held-first'), hasLength(1));
    final second = state.resolvePlayback(
      episodeTarget: 'ordinary-second', flag: '丫仙女', vodId: parent.vodId,
    ).then<Object?>((value) => value, onError: (Object error) => error);
    await tester.pump();
    expect(calls.where((url) => url.queryParameters['play'] == 'ordinary-second'), hasLength(1),
        reason: '目录已结束，新的普通播放不能等已过期的旧解析返回');
    gate.complete(response({'code': -1, 'msg': '已结束'}));
    await Future.wait([first, second]);
  });

  testWidgets('同页刷新使排队早播的旧详情快照失效', (tester) async {
    final gate = delayed = Completer<http.Response>();
    delayedResource = 'quark';
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(response(detail('quark')));
    });
    await tester.pumpWidget(MaterialApp(home: DetailPage(state: state, vod: parent)));
    await tester.pump();
    final previousRun = state.detailLoadTrace!.runId;
    expect(state.detailLinesLoading, isTrue);
    await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
    await tester.pump();
    expect(calls.where((url) => url.queryParameters.containsKey('play')), isEmpty);
    await tester.tap(find.byTooltip('刷新详情'));
    await tester.pump();
    expect(state.detailLoadTrace!.runId, greaterThan(previousRun));
    gate.complete(response(detail('quark')));
    await tester.pumpAndSettle();
    expect(calls.where((url) => url.queryParameters.containsKey('play')), isEmpty,
        reason: '刷新后不派发旧快照的早播请求');
    expect(find.byType(PlayerPage), findsNothing);
  });

  testWidgets('早播不从不完整线路推断跨源种子，也不透传播放器', (tester) async {
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester);
    state.instantPlayback = true;
    sharedEntryUrl = true;
    final gate = delayed = Completer<http.Response>();
    delayedResource = 'quark';
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(response(detail('quark')));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(
          state: state,
          vod: parent,
          resumeSeed: const ResumeSeed(
            flag: 'foreign',
            episodeId: sharedTarget,
            episodeName: '旧集',
            positionMs: 30000,
            durationMs: 100000,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(state.detailLinesLoading, isTrue);
    await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
    await tester.pump();
    await settlePlayerPage(tester);
    final request = tester.widget<PlayerPage>(find.byType(PlayerPage)).request;
    expect(request.episodeTarget, sharedTarget);
    expect(
      request.startPosition,
      isNull,
      reason: '同一 URL 可能在迟到线路里重复，不得在半份数据上迁移进度',
    );
    expect(request.resumeSeed, isNull, reason: '播放器也不能拿半份线路重新推断同一个跨源种子');
    gate.complete(response(detail('quark')));
    Navigator.of(tester.element(find.byType(PlayerPage))).pop();
    await settlePlayerPage(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('早播不按同名剧集借用迟到线路的本地历史', (tester) async {
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester);
    state.instantPlayback = true;
    sameEpisodeNames = true;
    state.recordProgress(
      vod: parent,
      flag: '丫仙女',
      episodeName: '第1集',
      episodeId: 'quark@1',
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 100),
    );
    final gate = delayed = Completer<http.Response>();
    delayedResource = 'quark';
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(response(detail('quark')));
    });
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(state: state, vod: parent),
      ),
    );
    await tester.pump();
    expect(state.detailLinesLoading, isTrue);
    await tester.tap(find.byKey(const ValueKey('detail-hero-play')));
    await tester.pump();
    await settlePlayerPage(tester);
    final request = tester.widget<PlayerPage>(find.byType(PlayerPage)).request;
    expect(request.episodeTarget, 'baidu@1');
    expect(
      request.startPosition,
      isNull,
      reason: 'baidu 第1集不应继承 quark 同名集的30秒进度',
    );
    gate.complete(response(detail('quark')));
    Navigator.of(tester.element(find.byType(PlayerPage))).pop();
    await settlePlayerPage(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('退出后取消尚未发出的排队播放，不占用新请求', (tester) async {
    final gate = delayed = Completer<http.Response>();
    delayedResource = 'quark';
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(response(detail('quark')));
    });
    final loading = state.loadDetail(parent);
    await tester.pump();
    var active = true;
    final play = state
        .resolvePlayback(
          episodeTarget: 'baidu@2',
          flag: '丫仙女',
          vodId: parent.vodId,
          isCurrent: () => active,
        )
        .then<Object?>((value) => value, onError: (Object error) => error);
    await tester.pump();
    expect(
      calls.where((url) => url.queryParameters.containsKey('play')),
      isEmpty,
    );
    active = false;
    state.clearDetail();
    gate.complete(response(detail('quark')));
    await loading;
    expect(await play, isNull);
    expect(
      state
          .siteHealth()
          .singleWhere((row) => row.siteKey == 'bridge')
          .playTotal,
      0,
      reason: '尚未派发的取消不应降低站点播放成功率',
    );
    expect(
      calls.where((url) => url.queryParameters.containsKey('play')),
      isEmpty,
      reason: '排队期间失去页面归属，不能再给网关发送播放',
    );
  });

  testWidgets('渐进进度观察者失败不妨碍其他线路加载', (tester) async {
    final result = await state.siteService!.folderDetail(
      state.selectedSite!,
      parent,
      onProgress: (_) => throw StateError('observer failure'),
    );
    expect(state.playLinesOf(result.value.list.single), hasLength(3));
    expect(
      calls.where((url) => url.queryParameters.containsKey('ids')),
      hasLength(3),
    );
  });

  testWidgets('渐进加载期间退出不会追加线路或继续第三条请求', (tester) async {
    final gate = delayed = Completer<http.Response>();
    delayedResource = 'quark';
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(response(detail('quark')));
    });
    final pending = state.loadDetail(parent);
    await tester.pump();
    expect(state.detailLinesLoading, isTrue);
    expect(state.playLinesOf(state.detailResult!.list.single), hasLength(1));
    state.clearDetail();
    gate.complete(response(detail('quark')));
    await pending;
    expect(state.detailResult, isNull);
    expect(state.selectedVod, isNull);
    expect(
      calls.where((u) => u.queryParameters.containsKey('ids')),
      hasLength(2),
    );
  });

  for (final manual in [false, true]) {
    testWidgets('渐进线路不提前抢占历史，手动选择优先=$manual', (tester) async {
      final gate = delayed = Completer<http.Response>();
      delayedResource = 'quark';
      addTearDown(() {
        if (!gate.isCompleted) gate.complete(response(detail('quark')));
      });
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            state: state,
            vod: parent,
            historyFlag: '丫仙女',
            historyEpisodeId: 'quark@2',
          ),
        ),
      );
      await tester.pump();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
      await tester.pump();
      expect(find.textContaining('baidu01'), findsWidgets);
      expect(find.textContaining('quark02'), findsNothing);
      if (manual) {
        await tester.tap(find.textContaining('baidu（2 集）'));
        await tester.pump();
      }
      gate.complete(response(detail('quark')));
      await tester.pumpAndSettle();
      expect(find.textContaining(manual ? 'baidu01' : 'quark02'), findsWidgets);
      expect(find.textContaining(manual ? 'quark02' : 'baidu01'), findsNothing);
    });
  }

  testWidgets('一个资源失败仍展示其余线路，刷新详情可重试', (tester) async {
    failures.add('baidu');
    await openDetail(tester);
    expect(state.detailPhase, LoadPhase.ready);
    expect(state.playLinesOf(state.selectedVod!).length, 2);
    expect(find.textContaining('quark（2 集）'), findsOneWidget);
    expect(find.textContaining('uc（2 集）'), findsOneWidget);
    expect(state.detailError?.userMessage, contains('baidu'));
    expect(state.log.export(), contains('baidu'));
    failures.clear();
    await tester.tap(find.byTooltip('刷新详情'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(state.detailError, isNull);
    expect(find.textContaining('baidu（2 集）'), findsOneWidget);
  });

  testWidgets('全部资源失败显示详情错误，不伪装成成功的空目录', (tester) async {
    failures.addAll(['baidu', 'quark', 'uc']);
    await openDetail(tester);
    expect(state.detailPhase, LoadPhase.failed);
    expect(state.detailError, isNotNull);
    expect(state.detailResult, isNull);
    expect(find.textContaining('选择资源'), findsNothing);
    expect(calls.where((u) => u.queryParameters.containsKey('play')), isEmpty);
  });

  testWidgets('离开详情后停止后续资源展开，晚到响应不写回', (tester) async {
    delayed = Completer<http.Response>();
    final pending = state.loadDetail(parent);
    await tester.pump();
    expect(calls.where((u) => u.queryParameters.containsKey('ids')).length, 1);
    state.clearDetail();
    delayed!.complete(response(detail('baidu')));
    await pending;
    expect(state.detailResult, isNull);
    expect(state.selectedVod, isNull);
    expect(calls.where((u) => u.queryParameters.containsKey('ids')).length, 1);
  });
}
