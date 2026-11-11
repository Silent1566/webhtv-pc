import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';

void main() {
  late Directory temp;
  late AppState state;
  final calls = <Uri>[];
  final failures = <String>{};
  Completer<http.Response>? delayed;
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
        'vod_play_url': '${resource}01\$$resource@1#${resource}02\$$resource@2',
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
    temp = Directory.systemTemp.createTempSync('webhtv-folder-lines');
    final client = MockClient((request) async {
      calls.add(request.url);
      final q = request.url.queryParameters;
      if (q.containsKey('play')) {
        return response({'code': -1, 'msg': '已捕获播放目标'});
      }
      if (q.containsKey('ids')) {
        final resource = Uri.parse(q['ids']!).pathSegments.last;
        if (resource == 'baidu' && delayed != null) return delayed!.future;
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
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${temp.path}/webhtv-pc',
          'data': '${temp.path}/webhtv-pc',
          'cache': '${temp.path}/webhtv-pc/cache',
          'state': '${temp.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
      httpClient: client,
    );
    await state.bootstrap();
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
