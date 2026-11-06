/// 原来源（其它配置）历史播放的**状态层**契约。
///
/// 锁住三件用户可见的事（用户 2026-11 需求）：
///
/// 1. 其它配置的历史用**它自己那份配置**解析：同名站点 key 也不会串到当前配置的
///    站点 api / 请求头上；
/// 2. 全程**不切配置、不改选中站点**（生效配置与顶栏都不许动）；
/// 3. 进度写回**原来的 `source_key`**，否则一次续播就会在当前源里裂出第二条。
///
/// 另外锁住来源名的可读性：只能用配置名，**不许**回落到 URL（用户原话：
/// 「应该显示其他线路的名称，现在好像是显示的 URL」）。
///
/// ## 为什么用假 http client
///
/// `testWidgets` 的函数体跑在假时钟区，真实 socket 走不通；而这里的被测流程需要
/// 真实 `AppState`（写库 + 站点服务）。注入 `http.BaseClient` 既绕开平台限制，
/// 又能按**请求路径**区分「请求打到了哪份配置的站点」——这正是本文件的核心断言。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

/// 两份配置共用同一个站点 key（真实场景：桥接设备的每个源都是 `csp_*`）。
const String sharedSiteKey = 'csp_shared';

/// 生效配置的站点 api 前缀。
const String activeApiRoot = 'http://127.0.0.1:1/A/';

/// 另一份配置的站点 api 前缀。
const String otherApiRoot = 'http://127.0.0.1:1/B/';

/// 记录请求打到了哪一侧：这是「有没有串配置」的硬证据。
class _RoutingClient extends http.BaseClient {
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
          'vod_name': '测试视频',
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
  late _RoutingClient client;

  Map<String, Object?> configJson(
    String apiRoot,
    String name, {
    int siteType = 1,
  }) => {
    'name': name,
    'sites': [
      {
        'key': sharedSiteKey,
        'name': '共用站点',
        'type': siteType,
        'api': apiRoot,
        'searchable': 1,
      },
    ],
  };

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-original-source');
    client = _RoutingClient();
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {'roaming': tempDir.path, 'local': tempDir.path},
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

  /// 造一份**非生效**配置记录，返回它的 `source_key`。
  String seedOtherConfig({
    required String name,
    required String apiRoot,
    int siteType = 1,
  }) {
    final origin = '$apiRoot-other.json';
    final key = LocalSourceKey.of(origin);
    state.database!.saveConfig(
      name: name,
      origin: origin,
      json: configJson(apiRoot, name, siteType: siteType),
      makeActive: false,
      sourceKey: key,
    );
    return key;
  }

  testWidgets('原配置解析真的打到原配置的站点 api（type=4 强制进播放入口）', (tester) async {
    await tester.runAsync(() async {
      // type=4 会**无条件**向站点播放入口取地址，请求一定真打出去，
      // 于是「请求路径前缀」就成了「打到哪份配置」的硬证据。
      await state.importConfig(
        jsonEncode(configJson(activeApiRoot, '当前配置', siteType: 4)),
      );
      final otherKey = seedOtherConfig(
        name: '其它配置',
        apiRoot: otherApiRoot,
        siteType: 4,
      );

      // 导入配置会顺带发一次首页请求（/A/），那是装配噪声，不是本次解析。
      // 必须在解析**之前**清空，否则断言证明不了「解析打到哪份配置」。
      client.paths.clear();

      final decision = await state.resolvePlaybackForSource(
        sourceKey: otherKey,
        siteKey: sharedSiteKey,
        episodeTarget: 'http://media.example/entry-1',
        flag: '线路一',
        vodId: 'v1',
      );

      expect(decision, isNotNull);
      expect(client.paths, isNotEmpty, reason: '播放入口必须被真的请求过');
      expect(
        client.paths.every((path) => path.startsWith('/B/')),
        isTrue,
        reason: '请求必须全部落在原配置的站点（/B/）；实际：${client.paths}',
      );
      expect(
        client.paths.any((path) => path.startsWith('/A/')),
        isFalse,
        reason: '串到当前配置就会表现为「点这部片播的是另一部」',
      );
    });
  });

  testWidgets('其它配置的历史用它自己的配置解析：同名站点 key 不串配置', (tester) async {
    await tester.runAsync(() async {
      // 生效配置：sharedSiteKey 指向 /A/。
      await state.importConfig(jsonEncode(configJson(activeApiRoot, '当前配置')));
      // 另一份配置：**同一个** sharedSiteKey，指向 /B/。
      final otherKey = seedOtherConfig(name: '其它配置', apiRoot: otherApiRoot);

      final beforeSource = state.activeSourceKey;
      final beforeSite = state.selectedSite?.key;
      final beforeRecord = state.activeRecord?.id;

      final decision = await state.resolvePlaybackForSource(
        sourceKey: otherKey,
        siteKey: sharedSiteKey,
        episodeTarget: 'http://media.example/orig.m3u8',
        flag: '线路一',
        vodId: 'v1',
      );

      expect(decision, isNotNull, reason: '原配置里站点在、目标可直连，必须能解析出来');
      expect(decision!.url, 'http://media.example/orig.m3u8');

      // 串配置的唯一结构性证据：解析用的站点服务必须是**另一套**，
      // 且它的配置指向 /B/。共用同一份服务就等于共用请求头与运行时缓存。
      final context = state.playbackContextFor(otherKey)!;
      expect(
        context.service.appConfig.sites.single.api,
        otherApiRoot,
        reason: '原配置的站点 api 必须是 /B/',
      );
      expect(
        identical(context.service, state.siteService),
        isFalse,
        reason: '不得复用生效配置的站点服务（那会把请求头与运行时一起借过去）',
      );
      expect(
        identical(context.service.router, state.siteService!.router),
        isFalse,
        reason: '原配置必须有独立路由：同名站点 key 的运行时与请求头不得互通',
      );

      expect(state.activeSourceKey, beforeSource, reason: '不得切换生效配置');
      expect(state.selectedSite?.key, beforeSite, reason: '不得改选中站点');
      expect(state.activeRecord?.id, beforeRecord, reason: '不得激活原配置');
    });
  });

  testWidgets('原配置的站点服务绑定它自己的 AppConfig', (tester) async {
    await tester.runAsync(() async {
      await state.importConfig(jsonEncode(configJson(activeApiRoot, '当前配置')));
      final otherKey = seedOtherConfig(name: '其它配置', apiRoot: otherApiRoot);

      final context = state.playbackContextFor(otherKey);
      expect(context, isNotNull);
      expect(
        context!.config.sites.single.api,
        otherApiRoot,
        reason: '上下文里的配置必须是原配置',
      );
      expect(
        context.service.appConfig.sites.single.api,
        otherApiRoot,
        reason: '站点服务必须绑定原配置，否则请求头/解析规则会串',
      );
      expect(
        state.siteService!.appConfig.sites.single.api,
        activeApiRoot,
        reason: '生效配置的服务不得被替换',
      );
    });
  });

  testWidgets('配置被删除时上下文返回 null（交给调用方回退）', (tester) async {
    await tester.runAsync(() async {
      expect(
        state.playbackContextFor(LocalSourceKey.of('http://127.0.0.1:1/gone.json')),
        isNull,
        reason: '原配置不存在时必须返回 null，让历史页回退到当前源匹配',
      );
      expect(state.playbackContextFor(''), isNull);
    });
  });

  testWidgets('进度写回原来源的 source_key（不裂出第二条历史）', (tester) async {
    await tester.runAsync(() async {
      await state.importConfig(jsonEncode(configJson(activeApiRoot, '当前配置')));
      final otherKey = seedOtherConfig(name: '其它配置', apiRoot: otherApiRoot);

      state.recordProgress(
        vod: Vod(vodId: 'v-orig', vodName: '原来源片子'),
        flag: '线路一',
        episodeName: '第2集',
        episodeId: 'http://share.example/entry-2',
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 100),
        siteKey: sharedSiteKey,
        sourceKey: otherKey,
      );

      final rows = state.database!.recentHistory(limit: 50, sourceKey: '');
      final written = rows.where((row) => row.vodId == 'v-orig');
      expect(written, hasLength(1), reason: '只写一条，不许在当前源里再裂一条');
      expect(written.single.sourceKey, otherKey);
    });
  });

  testWidgets('不传 sourceKey 时保持既有行为（写当前生效源）', (tester) async {
    await tester.runAsync(() async {
      await state.importConfig(jsonEncode(configJson(activeApiRoot, '当前配置')));

      state.recordProgress(
        vod: Vod(vodId: 'v-now', vodName: '当前源片子'),
        flag: '线路一',
        episodeName: '第1集',
        episodeId: 'http://share.example/entry-1',
        position: const Duration(seconds: 20),
        duration: const Duration(seconds: 100),
        siteKey: sharedSiteKey,
      );

      final rows = state.database!.recentHistory(limit: 50, sourceKey: '');
      expect(
        rows.firstWhere((row) => row.vodId == 'v-now').sourceKey,
        state.activeSourceKey,
        reason: '默认行为必须与改造前一致',
      );
    });
  });

  testWidgets('来源名只用配置名，绝不显示 URL', (tester) async {
    await tester.runAsync(() async {
      await state.importConfig(jsonEncode(configJson(activeApiRoot, '当前配置')));
      final named = seedOtherConfig(name: '其它配置', apiRoot: otherApiRoot);

      expect(
        state.historySourceLabel(named),
        '其它配置',
        reason: '有可读名称就显示名称',
      );
      expect(
        state.historySourceLabel(state.activeSourceKey),
        isNull,
        reason: '当前源不标注（既有契约）',
      );
      expect(state.historySourceLabel(''), isNull);

      // 老记录把 URL 当名字存下来的情况：不许把 URL 当成名称显示。
      final urlNamed = seedOtherConfig(
        name: 'http://192.168.1.5:8080/sub.json',
        apiRoot: 'http://127.0.0.1:1/C/',
      );
      expect(
        state.historySourceLabel(urlNamed),
        '其他来源',
        reason: '名字本身是地址时按「其他来源」显示，不展示 URL',
      );
      expect(
        state.historySourceLabel(urlNamed)!.contains('://'),
        isFalse,
      );

      // 配置已删除：同样只能给「其他来源」，不能回落成 manifest 的短标签。
      expect(
        state.historySourceLabel(LocalSourceKey.of('http://127.0.0.1:1/del.json')),
        '其他来源',
      );
    });
  });
}
