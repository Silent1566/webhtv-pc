import 'dart:async';
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
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/playback_source_context.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/player_page.dart';
import 'package:webhtv_pc/ui/theme.dart';

import 'support/player_page_harness.dart';
import 'support/test_fonts.dart';

const evidenceDir = String.fromEnvironment(
  'FOLDER_EVIDENCE_DIR',
  defaultValue: '../../.superpowers/multi-folder',
);
const rootId = '根目录 /?原样=1';
final root = Vod(vodId: rootId, vodName: '资料库', vodTag: 'folder');

Map<String, Object?> entry(
  String id,
  String name, {
  bool folder = false,
  Object? cate,
}) => {
  'vod_id': id,
  'vod_name': name,
  'vod_tag': folder ? 'folder' : 'file',
  'cate': ?cate,
};

class FolderFixture {
  late final AppState state;
  final calls = <Uri>[];
  final failures = <String>{};
  final delayed = <String, Completer<http.Response>>{};
  late final Directory dir;

  http.Response response(Object value) => http.Response(
    jsonEncode(value),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Future<void> initialize() async {
    dir = Directory('$evidenceDir/runtime').absolute;
    dir.createSync(recursive: true);
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${dir.path}/config',
          'data': '${dir.path}/data',
          'cache': '${dir.path}/cache',
          'state': '${dir.path}/state',
        },
      ),
      log: LogService(),
      httpClient: MockClient((request) async {
        calls.add(request.url);
        final query = request.url.queryParameters;
        final id = query['t'];
        if (id != null) {
          if (delayed[id] != null) return delayed[id]!.future;
          if (failures.contains(id)) {
            return response({'code': -1, 'msg': '目录暂时不可用'});
          }
          final page = int.parse(query['pg'] ?? '1');
          return response({
            'page': page,
            'pagecount': id == rootId ? 8 : 1,
            'list': page > 1
                ? <Object>[]
                : switch (id) {
                    rootId => [
                      entry('二层 &路径', '影集', folder: true),
                      entry('empty', '空目录', folder: true),
                      entry('error', '失败目录', folder: true),
                      for (var i = 0; i < 26; i++)
                        entry('file-$i', '影片 ${i + 1}'),
                    ],
                    '二层 &路径' => [
                      entry('三层?保留=值', '第三层', cate: false),
                      entry('file-inner', '内层影片'),
                    ],
                    '三层?保留=值' => [entry('file-last', '深层影片')],
                    _ => <Object>[],
                  },
          });
        }
        final file = query['ids'];
        if (file != null) {
          return response({
            'list': [
              {
                'vod_id': file,
                'vod_name': '影片详情',
                'vod_tag': 'file',
                'vod_play_from': '测试线路',
                'vod_play_url': r'第一集$http://127.0.0.1:9/video.mp4',
              },
            ],
          });
        }
        return response({
          'class': [
            {'type_id': 'home', 'type_name': '首页'},
          ],
          'list': <Object>[],
        });
      }),
    );
    await state.bootstrap();
    await state.importConfig(
      jsonEncode({
        'sites': [
          {
            'key': 'fixture',
            'name': '测试站点',
            'type': 1,
            'api': 'https://fixture.invalid/api',
          },
        ],
      }),
    );
    await state.loadCategory('home', filters: {'sort': '原样 /&值'});
    calls.clear();
  }
}

Future<void> openFolder(
  WidgetTester tester,
  FolderFixture fixture, {
  GlobalKey? capture,
  PlaybackSourceContext? source,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final theme = buildAppTheme(Brightness.dark);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
        appBarTheme: theme.appBarTheme.copyWith(
          titleTextStyle: theme.textTheme.titleMedium?.copyWith(
            fontFamily: 'FixtureCJK',
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            textStyle: const TextStyle(fontFamily: 'FixtureCJK'),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            textStyle: const TextStyle(fontFamily: 'FixtureCJK'),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            textStyle: const TextStyle(fontFamily: 'FixtureCJK'),
          ),
        ),
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: SegmentedButton.styleFrom(
            textStyle: const TextStyle(fontFamily: 'FixtureCJK'),
          ),
        ),
        listTileTheme: theme.listTileTheme.copyWith(
          titleTextStyle: theme.textTheme.bodyLarge?.copyWith(
            fontFamily: 'FixtureCJK',
          ),
          subtitleTextStyle: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: 'FixtureCJK',
          ),
        ),
        chipTheme: theme.chipTheme.copyWith(
          labelStyle: theme.textTheme.labelLarge?.copyWith(
            fontFamily: 'FixtureCJK',
          ),
        ),
      ),
      builder: (context, child) => RepaintBoundary(key: capture, child: child!),
      home: DetailPage(
        state: fixture.state,
        vod: root,
        sourceContext: source,
        sourceSiteKey: 'fixture',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadFixtureFonts);
  late FolderFixture fixture;
  setUp(() async {
    fixture = FolderFixture();
    await fixture.initialize();
  });
  tearDown(() {
    fixture.state.dispose();
  });

  Future<void> captureTo(
    WidgetTester tester,
    GlobalKey capture,
    String name,
  ) async {
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$evidenceDir/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets('fixed folder scenario capture', (tester) async {
    final capture = GlobalKey();
    await openFolder(tester, fixture, capture: capture);
    const phase = String.fromEnvironment('FOLDER_CAPTURE_PHASE');
    if (phase.isNotEmpty) await captureTo(tester, capture, phase);
    if (phase == 'after') {
      await tester.tap(find.text('剧集模式'));
      await tester.pumpAndSettle();
      await captureTo(tester, capture, 'after-episodes');
    }
    if (phase != 'before') {
      expect(find.text('影集'), findsOneWidget);
      expect(find.text('影片 1'), findsOneWidget);
      expect(
        fixture.calls.where((u) => u.queryParameters.containsKey('ids')),
        isEmpty,
        reason: '目录不得预取子目录或文件详情',
      );
    }
  });

  testWidgets('file opens direct player and returns to exact parent scroll', (
    tester,
  ) async {
    await openFolder(tester, fixture);
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('folder-list')),
    );
    list.controller!.jumpTo(480);
    await tester.pumpAndSettle();
    final offset = list.controller!.offset;
    final visible = find.byWidgetPredicate(
      (widget) =>
          widget is ListTile &&
          widget.key == const ValueKey('folder-entry-file-7'),
    );
    installMediaKitMocks(tester);
    installWindowManagerMocks(tester);
    await tester.tap(visible);
    await settlePlayerPage(tester);
    expect(
      fixture.calls
          .where((u) => u.queryParameters.containsKey('ids'))
          .single
          .queryParameters['ids'],
      'file-7',
      reason: '只按需解析被选文件',
    );
    final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
    expect(player.request.vodId, 'file-7');
    expect(player.request.siteKey, 'fixture');
    expect(player.request.episodeTarget, 'http://127.0.0.1:9/video.mp4');
    expect(player.request.title, '资料库');
    expect(player.request.episodeName, '影片 8');
    expect(player.queueItemKey, 'file-7');
    expect(player.queue!.snapshot.items.first.title, '影片 1');
    expect(player.queue!.snapshot.items.length, 26);
    expect(find.byTooltip('刷新详情'), findsNothing, reason: '文件点击不再进单集详情页');
    await tester.pageBack();
    await tester.pumpAndSettle();
    final returned = tester.widget<ListView>(
      find.byKey(const ValueKey('folder-list')),
    );
    expect(returned.controller!.offset, offset);
    expect(find.byType(ListTile), findsWidgets);
    expect(
      fixture.calls.where((u) => u.queryParameters.containsKey('t')).length,
      1,
    );
  });

  for (final selection in [
    (id: 'file-0', name: '影片 1', seconds: 45),
    (id: 'file-1', name: '影片 2', seconds: 65),
  ]) {
    testWidgets(
      'directory reopen restores saved position for ${selection.id}',
      (tester) async {
        fixture.state.recordProgress(
          vod: Vod(vodId: 'file-0', vodName: '影片详情'),
          flag: '测试线路',
          episodeName: '影片 1',
          episodeId: 'http://127.0.0.1:9/video.mp4',
          position: const Duration(seconds: 35),
          duration: const Duration(minutes: 5),
          siteKey: 'fixture',
          sourceKey: fixture.state.activeSourceKey,
        );
        await openFolder(tester, fixture);
        installMediaKitMocks(tester);
        installWindowManagerMocks(tester);
        await tester.tap(find.text('影片 1'));
        await settlePlayerPage(tester);
        final first = tester.widget<PlayerPage>(find.byType(PlayerPage));
        expect(first.request.startPosition, const Duration(seconds: 35));
        final queue = first.queue!;
        await tester.pageBack();
        await tester.pumpAndSettle();
        fixture.state.recordProgress(
          vod: Vod(vodId: selection.id, vodName: '影片详情'),
          flag: '测试线路',
          episodeName: selection.name,
          episodeId: 'http://127.0.0.1:9/video.mp4',
          position: Duration(seconds: selection.seconds),
          duration: const Duration(minutes: 5),
          siteKey: 'fixture',
          sourceKey: fixture.state.activeSourceKey,
        );
        await tester.tap(find.text(selection.name));
        await settlePlayerPage(tester);
        final reopened = tester.widget<PlayerPage>(find.byType(PlayerPage));
        expect(reopened.queue, same(queue));
        expect(reopened.request.vodId, selection.id);
        expect(
          reopened.request.startPosition,
          Duration(seconds: selection.seconds),
        );
        expect(
          (await queue.resolve(selection.id)).startPosition,
          isNull,
          reason: 'Repeated in-player resolution must not resume again',
        );
        expect(
          (await queue.resolve('file-0')).startPosition,
          isNull,
          reason: 'In-player previous must not restore unrelated progress',
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('empty folder and failed folder offer friendly recovery', (
    tester,
  ) async {
    await openFolder(tester, fixture);
    await tester.tap(find.text('空目录'));
    await tester.pumpAndSettle();
    expect(find.text('此目录暂无内容'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    fixture.failures.add('error');
    await tester.tap(find.text('失败目录'));
    await tester.pumpAndSettle();
    expect(find.text('目录加载失败'), findsOneWidget);
    fixture.failures.clear();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('此目录暂无内容'), findsOneWidget);
    expect(
      fixture.calls.where((u) => u.queryParameters['t'] == 'error').length,
      2,
    );
  });

  testWidgets('empty pagination end stops and retains parent offset', (
    tester,
  ) async {
    await openFolder(tester, fixture);
    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('folder-list')),
    );
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('没有更多了'), findsOneWidget);
    expect(
      fixture.calls
          .where((u) => u.queryParameters['t'] == rootId)
          .map((u) => u.queryParameters['pg']),
      ['1', '2'],
    );
    final offset = list.controller!.offset;
    list.controller!.jumpTo(offset - 10);
    await tester.pumpAndSettle();
    list.controller!.jumpTo(offset);
    await tester.pumpAndSettle();
    expect(
      fixture.calls.where((u) => u.queryParameters['t'] == rootId).length,
      2,
    );
  });

  testWidgets(
    'terminal folder refresh failure retries page one without clearing list',
    (tester) async {
      await openFolder(tester, fixture);
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('folder-list')),
      );
      list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('没有更多了'), findsOneWidget);
      fixture.failures.add(rootId);
      await tester.tap(find.byTooltip('刷新目录'));
      await tester.pumpAndSettle();
      expect(find.text('刷新目录失败'), findsOneWidget);
      expect(find.text('影片 26'), findsOneWidget);
      fixture.failures.clear();
      await tester.tap(find.text('重试刷新'));
      await tester.pumpAndSettle();
      expect(find.text('刷新目录失败'), findsNothing);
      expect(
        fixture.calls
            .where((u) => u.queryParameters['t'] == rootId)
            .map((u) => u.queryParameters['pg']),
        ['1', '2', '1', '1'],
      );
    },
  );

  testWidgets(
    'late child response after back cannot contaminate another directory',
    (tester) async {
      await openFolder(tester, fixture);
      final delayed = Completer<http.Response>();
      fixture.delayed['二层 &路径'] = delayed;
      await tester.tap(find.text('影集'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('空目录'));
      await tester.pumpAndSettle();
      delayed.complete(
        fixture.response({
          'list': [entry('stale', '旧请求串入')],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('此目录暂无内容'), findsOneWidget);
      expect(find.text('旧请求串入'), findsNothing);
      expect(fixture.state.detailResult, isNull);
    },
  );

  testWidgets(
    'history source context remains frozen through nested folders and file',
    (tester) async {
      final source = fixture.state.playbackContextFor(
        fixture.state.activeSourceKey,
      )!;
      final otherConfig = File('${fixture.dir.path}/other-config.json');
      otherConfig.writeAsStringSync(
        jsonEncode({
          'sites': [
            {
              'key': 'other',
              'name': '当前站点',
              'type': 1,
              'api': 'https://other.invalid/api',
            },
          ],
        }),
      );
      await tester.runAsync(() => fixture.state.importConfig(otherConfig.path));
      final active = fixture.state.activeSourceKey;
      final selected = fixture.state.selectedSite;
      fixture.calls.clear();
      await openFolder(tester, fixture, source: source);
      await tester.tap(find.text('影集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第三层'));
      await tester.pumpAndSettle();
      installMediaKitMocks(tester);
      installWindowManagerMocks(tester);
      await tester.tap(find.text('深层影片'));
      await settlePlayerPage(tester);
      expect(
        fixture.calls
            .where(
              (u) =>
                  u.queryParameters.containsKey('t') ||
                  u.queryParameters.containsKey('ids'),
            )
            .every((u) => u.host == 'fixture.invalid'),
        isTrue,
      );
      expect(
        fixture.calls
            .where((u) => u.queryParameters.containsKey('ids'))
            .single
            .queryParameters['ids'],
        'file-last',
      );
      final player = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(player.request.siteKey, 'fixture');
      expect(player.request.vodId, 'file-last');
      expect(player.request.sourceKey, source.sourceKey);
      expect(player.request.episodeTarget, 'http://127.0.0.1:9/video.mp4');
      expect(fixture.state.activeSourceKey, active);
      expect(fixture.state.selectedSite, same(selected));
      expect(source.sourceKey, isNot(active));
      fixture.calls.clear();
      final resolved = await player.queue!.resolve('file-last');
      final refresh = fixture.calls.singleWhere(
        (u) => u.queryParameters.containsKey('ids'),
      );
      expect(refresh.host, 'fixture.invalid');
      expect(refresh.queryParameters['ids'], 'file-last');
      expect(resolved.sourceKey, source.sourceKey);
      expect(resolved.vodId, 'file-last');
      expect(fixture.state.activeSourceKey, active);
      expect(fixture.state.selectedSite, same(selected));
      expect(fixture.state.detailResult, isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('深层影片'), findsOneWidget);
    },
  );

  testWidgets(
    'generic directory cannot mutate global detail through loadDetail',
    (tester) async {
      final selected = fixture.state.selectedVod;
      final detail = fixture.state.detailResult;
      await fixture.state.loadDetail(root);
      expect(fixture.calls, isEmpty, reason: '普通目录不允许桥接分享链预取');
      expect(fixture.state.selectedVod, same(selected));
      expect(fixture.state.detailResult, same(detail));
    },
  );

  testWidgets(
    'three layers keep original IDs filters and global browse state',
    (tester) async {
      final home = fixture.state.homeResult;
      final category = fixture.state.categoryResult;
      final filters = Map.of(fixture.state.categoryFilters);
      final selected = fixture.state.selectedSite;
      await openFolder(tester, fixture);
      final rootList = tester.widget<ListView>(
        find.byKey(const ValueKey('folder-list')),
      );
      rootList.controller!.jumpTo(32);
      await tester.pumpAndSettle();
      await tester.tap(find.text('影集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第三层'));
      await tester.pumpAndSettle();
      expect(find.text('深层影片'), findsOneWidget);
      final requests = fixture.calls
          .where((u) => u.queryParameters.containsKey('t'))
          .toList();
      expect(requests.map((u) => u.queryParameters['t']), [
        rootId,
        '二层 &路径',
        '三层?保留=值',
      ]);
      for (final request in requests) {
        expect(request.queryParameters['pg'], '1');
        expect(jsonDecode(request.queryParameters['f']!), {'sort': '原样 /&值'});
      }
      expect(fixture.state.homeResult, same(home));
      expect(fixture.state.categoryResult, same(category));
      expect(fixture.state.categoryFilters, filters);
      expect(fixture.state.selectedSite, same(selected));
      expect(fixture.state.detailResult, isNull);
      expect(
        fixture.calls.where((u) => u.queryParameters.containsKey('ids')),
        isEmpty,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('内层影片'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('影片 1'), findsOneWidget);
      final restored = tester.widget<ListView>(
        find.byKey(const ValueKey('folder-list')),
      );
      expect(restored.controller!.offset, 32);
    },
  );
}
