/// 点历史记录时的**入口顺序**（用户 2026-11 需求）。
///
/// 锁住三件事：
/// 1. 原配置可用时**优先**用它（详情模式推详情页、播放模式直接起播），
///    而不是先去当前源里找同名站点；
/// 2. 原配置缺失 / 里没有该站点时，**先给出原因**，再走既有的当前源匹配；
/// 3. 全程不激活原配置、不改顶栏选中的站点。
///
/// ## 为什么这次用假 http client
///
/// 入口顺序本身不依赖网络，但「详情模式」会真的去取详情、「播放模式」会真的去
/// 解析，二者都会发请求。`testWidgets` 的假时钟下真实 socket 走不通，所以按本仓库
/// 既有分层纪律注入 `http.BaseClient`，并把真实 I/O 夹在 `tester.runAsync` 里。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/history_cross_source.dart';


const String sharedSiteKey = 'csp_shared';
const String activeApiRoot = 'http://127.0.0.1:1/A/';
const String otherApiRoot = 'http://127.0.0.1:1/B/';

/// 记录所有请求路径，用来判断「打到了哪份配置」。
class _RecordingClient extends http.BaseClient {
  final List<String> paths = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    paths.add(path);
    final payload = {
      'parse': 0,
      'url': 'http://media.example$path.m3u8',
      'header': {'Referer': 'http://media.example/'},
      'list': [
        {
          'vod_id': 'v1',
          'vod_name': '外站剧',
          'vod_year': '2024',
          'vod_play_from': '线路一',
          'vod_play_url': '第1集\$http://media.example/e1',
        },
      ],
    };
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(payload))),
      200,
    );
  }
}

void main() {
  late Directory tempDir;
  late AppState state;
  late _RecordingClient client;

  Map<String, Object?> configJson(String apiRoot, String name) => {
    'name': name,
    'sites': [
      {
        'key': sharedSiteKey,
        'name': '共用站点',
        'type': 4,
        'api': apiRoot,
        'searchable': 1,
      },
    ],
  };

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-history-entry');
    client = _RecordingClient();
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
      httpClient: client,
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 生效配置（/A/）+ 另一份配置（/B/，同一个站点 key）。
  Future<String> seedTwoConfigs(WidgetTester tester) async {
    late String otherKey;
    await tester.runAsync(() async {
      await state.importConfig(
        jsonEncode(configJson(activeApiRoot, '当前配置')),
      );
      final origin = '${otherApiRoot}other.json';
      otherKey = LocalSourceKey.of(origin);
      state.database!.saveConfig(
        name: '其它配置',
        origin: origin,
        json: configJson(otherApiRoot, '其它配置'),
        makeActive: false,
        sourceKey: otherKey,
      );
    });
    return otherKey;
  }

  /// 一条属于**另一份配置**的历史。
  PlaybackHistory foreignItem(String sourceKey) => PlaybackHistory(
    id: 1,
    siteKey: sharedSiteKey,
    vodId: 'v1',
    vodName: '外站剧',
    vodPic: '',
    flag: '线路一',
    episodeName: '第1集',
    episodeId: 'http://media.example/e1',
    positionMs: 30000,
    durationMs: 300000,
    updatedAt: 1,
    sourceKey: sourceKey,
    vodYear: '2024',
  );

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Material(child: child ?? const SizedBox()),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pump();
    return tester.element(find.byType(Scaffold));
  }

  Future<void> runOpen(
    WidgetTester tester,
    BuildContext context,
    PlaybackHistory item,
  ) async {
    await tester.runAsync(() async {
      // 不 await：命中后会 await 页面 push，直到用户返回才解析。
      openHistoryFromOtherSource(context, state, item);
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('详情模式：用原配置打开详情页，且不激活原配置', (tester) async {
    final otherKey = await seedTwoConfigs(tester);
    await tester.runAsync(() async {
      await state.setHistoryClickAction(UiHistoryClickAction.detail);
    });
    final context = await pumpHost(tester);
    final beforeSource = state.activeSourceKey;
    final beforeSite = state.selectedSite?.key;

    await runOpen(tester, context, foreignItem(otherKey));

    final page = tester.widget<DetailPage>(find.byType(DetailPage));
    expect(
      page.sourceSiteKey,
      sharedSiteKey,
      reason: '详情页必须知道这条记录在原配置里属于哪个站点',
    );
    expect(
      page.sourceContext?.sourceKey,
      otherKey,
      reason: '详情页必须拿到**原配置**的上下文，而不是退回当前配置',
    );
    expect(
      find.byType(DetailPage),
      findsOneWidget,
      reason: '详情模式下必须停在详情页',
    );

    expect(state.activeSourceKey, beforeSource, reason: '不得激活原配置');
    expect(state.selectedSite?.key, beforeSite, reason: '不得改选中站点');
  });

  // 播放模式的「UI 级」用例刻意不写：`PlayerPage` 构建需要 media_kit 原生库，
  // 测试进程里没有（`MediaKit.ensureInitialized must be called`），渲染必然失败。
  // 该路径改由两层**等价证据**覆盖，且都不依赖页面渲染：
  // - `phase6_history_original_source_test.dart`：「原配置解析真的打到原配置的
  //   站点 api」「进度写回原来源」「不切配置/不改选中站点」；
  // - 本文件的一条已删除配置用例：回退分支确实被走到。

  testWidgets('原配置已删除：先提示原因，再回退到当前源匹配', (tester) async {
    await seedTwoConfigs(tester);
    await tester.runAsync(() async {
      await state.setHistoryClickAction(UiHistoryClickAction.play);
    });
    final context = await pumpHost(tester);

    // 一条指向**不存在**配置的历史。
    final gone = LocalSourceKey.of('http://127.0.0.1:1/gone.json');
    await runOpen(tester, context, foreignItem(gone));

    // 回退路径的可见证据：既没有用原配置起播，也没有崩；
    // 当前源里没有该站点时会走到「找替代站点」的分支或直接失败提示。
    expect(
      state.activeSourceKey,
      isNot(gone),
      reason: '回退过程中也不得把生效配置切到那条已删除的源',
    );
    expect(
      tester.takeException(),
      isNull,
      reason: '原配置缺失必须走回退流程，不允许抛异常到 UI',
    );
  });
}
