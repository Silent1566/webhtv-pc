/// 本地爬虫源播出来的历史，必须在「最近观看 / 续播 / 追剧 / 收藏」里解析到站点。
///
/// 用户反馈的现象（截图）：点最近观看的卡片弹「该记录所属站点已不在当前配置中：
/// 豆播ai」。真实数据里 history 行的 site_key 是本地爬虫源 manifest 的 key，
/// 而本地源（`spiders/local/<key>/`）只并入 AppState.effectiveConfig，**从不写进
/// 配置记录**。于是凡是拿「配置记录原文」（state.config.sites）去找站点的地方，
/// 本地源的历史一律落空。
///
/// 本文件锁住修复后的三条契约：
/// 1. 生效源解析：siteInActiveSource / configForSourceKey(active) /
///    playbackContextFor(active) 都能看到本地源；
/// 2. 只读契约：本地源**不得**被写回配置记录（state.config.sites 与库里记录的
///    JSON 都不变），这也是「下次打开变成用户自己写的站点」的防线；
/// 3. 跨源与同 key 冲突：其它配置的上下文里同样能解析本地源，但不覆盖那份配置
///    自己的同 key 站点（只追加不覆盖）；停用后旧上下文必须失效。
///
/// 纪律：
/// - 每个用例都在 Directory.systemTemp 下建真实目录与真实 manifest，经
///   AppPaths.resolve 的四个 override 完全隔离，绝不碰 ~/.config 或
///   ~/.local/share；
/// - 站点请求一律走注入的假 http.BaseClient：testWidgets 的假时钟区里做真实
///   socket I/O 会挂死（本仓库既有的分层纪律），也让「没发请求」可断言；
/// - widget 用例只替换「首页/详情取数」这一层（loadHome / loadDetail），
///   站点解析、切站点与跳转全部走真实实现——否则断言的就只是替身。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/source_key.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/browse_pages.dart';
import 'package:webhtv_pc/ui/home_page.dart';
import 'package:webhtv_pc/ui/library_pages.dart';
import 'package:webhtv_pc/ui/toast.dart';

import 'support/detail_test_seams.dart';

/// 本地爬虫源的 manifest key，也就是历史行里的 site_key（用户截图里的那个名字）。
const String localKey = '豆播ai';

/// 生效配置里普通站点的 api 前缀。
const String activeApi = 'http://127.0.0.1:1/A/';

/// 另一份配置里普通站点的 api 前缀。
const String otherApi = 'http://127.0.0.1:1/B/';

/// 另一份配置里与本地源**同 key** 的站点 api 前缀。
const String ownApi = 'http://127.0.0.1:1/C/';

/// 首页续播用例里「另一份配置」的站点 api：单独一段路径，便于断言请求打到哪一侧。
const String crossApi = 'http://127.0.0.1:1/other/';

/// 本地条目在站点集合里的 api 形态（见 local_site_sources.dart）。
String localApi(String key) => 'spider-local:$key';

/// 记录请求的假客户端：一律拒绝，用例内不联网。
///
/// 抛异常而不是返回 200：任何「意外真的去请求站点」都会变成可观察的失败，
/// 而不是安静地拿到一份假数据。
class _RecordingClient extends http.BaseClient {
  final List<Uri> urls = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    urls.add(request.url);
    throw StateError('用例不联网：${request.url}');
  }
}

/// 只替换取数那一层：站点解析、切站点、跳转仍是真实实现。
///
/// 本地源站点的首页/详情会真起 python sidecar，而 testWidgets 的假时钟推不动
/// 真实子进程 I/O；本文件钉的是「本地源的历史能不能解析到站点」，不是 sidecar。
class _NoSidecarState extends AppState {
  _NoSidecarState({
    required super.paths,
    required super.log,
    super.httpClient,
  });

  @override
  Future<void> loadHome(Site site) async {}

  @override
  Future<void> loadDetail(
    Vod vod, {
    SiteService? serviceOverride,
    Site? siteOverride,
  }) async {}
}

Map<String, Object?> _siteJson({
  required String key,
  required String name,
  required String api,
  int type = 1,
}) => <String, Object?>{
  'key': key,
  'name': name,
  'type': type,
  'api': api,
  'searchable': 1,
};

Map<String, Object?> _configJson(
  List<Map<String, Object?>> sites, {
  String name = '当前配置',
}) => <String, Object?>{'name': name, 'sites': sites};

void main() {
  late Directory temp;
  late AppPaths paths;
  late _RecordingClient client;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv_history_local_');
    // 日志也必须落在 temp 内：LogService 未显式 open 时不得摸默认目录。
    LogService.logDirectoryOverride = p.join(temp.path, 'logs');
    paths = AppPaths.resolve(
      overrides: {
        'config': p.join(temp.path, 'config'),
        'data': p.join(temp.path, 'data'),
        'cache': p.join(temp.path, 'cache'),
        'state': p.join(temp.path, 'logs'),
      },
    );
    paths.ensureDirectories();
    client = _RecordingClient();
  });

  tearDown(() async {
    LogService.logDirectoryOverride = null;
    dismissAllToasts();
    await _deleteTemp(temp);
  });

  /// 每个用例一份全新状态，释放排在临时目录删除之前。
  AppState newState() {
    final created = AppState(
      paths: paths,
      log: MemoryOnlyLogService(),
      httpClient: client,
    );
    addTearDown(created.dispose);
    return created;
  }

  /// 真实写一个本地爬虫源到 spiders/local/<key>/（manifest + 入口文件）。
  void writeLocalSpider({String key = localKey, String name = '豆播ai'}) {
    final dir = Directory(p.join(paths.configDir, 'spiders', 'local', key))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'spider.py')).writeAsStringSync('# $key\n');
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'abi': 'webhtv-ipc-v1',
        'abiMinor': 0,
        'key': key,
        'name': name,
        'runtime': 'python-3',
        'entry': 'spider.py',
        'capabilities': const ['home', 'category', 'detail', 'search', 'play'],
      }),
    );
  }

  /// 导入一份内联 JSON 配置（不联网），并校验前置成立。
  Future<void> importActive(
    AppState state, {
    List<Map<String, Object?>> sites = const [
      {'key': 'base', 'name': '甲站', 'type': 1, 'api': activeApi, 'searchable': 1},
    ],
  }) async {
    final ok = await state.importConfig(jsonEncode(_configJson(sites)));
    expect(ok, isTrue, reason: '前置：内联配置导入必须成功');
    expect(state.config, isNotNull, reason: '前置：生效配置必须可用');
  }

  /// 造一份**非生效**配置记录，返回它的 source_key。
  String seedOtherConfig(
    AppState state, {
    required String name,
    required List<Map<String, Object?>> sites,
    required String originTag,
  }) {
    final origin = 'http://127.0.0.1:1/$originTag.json';
    final key = LocalSourceKey.of(origin);
    state.database!.saveConfig(
      name: name,
      origin: origin,
      json: _configJson(sites, name: name),
      makeActive: false,
      sourceKey: key,
    );
    return key;
  }

  group('生效源解析（修复点 configForSourceKey / siteInActiveSource）', () {
    test('本地源进入 effectiveConfig：三处解析入口都能拿到这个站点', () async {
      final state = newState();
      await state.bootstrap();
      await importActive(state);
      // 前提自检：只凭配置记录原文，这个 key 是不存在的（缺陷的成因）。
      expect(
        state.config!.sites.map((site) => site.key),
        isNot(contains(localKey)),
        reason: '前置：配置记录里没有本地源',
      );

      writeLocalSpider();
      await state.rescanSpiders();
      expect(
        state.localSpiders.map((spider) => spider.key),
        contains(localKey),
        reason: '前置：manifest 必须真的被注册（否则后面的断言证明不了合并逻辑）',
      );

      final site = state.siteInActiveSource(localKey);
      expect(site, isNotNull, reason: 'UI 找站点必须查合并后的配置，否则弹「已不在当前配置中」');
      expect(site!.api, localApi(localKey));
      expect(site.name, '豆播ai');

      final config = state.configForSourceKey(state.activeSourceKey);
      expect(config, isNotNull);
      expect(config!.sites.map((item) => item.key), contains(localKey));
      // 生效源拿到的就是 effectiveConfig：与站点选择器、首页同一份。
      expect(
        config.sites.map((item) => item.key),
        state.effectiveConfig!.sites.map((item) => item.key),
        reason: '生效源必须与 effectiveConfig 一致，否则历史与首页看到两套站点',
      );

      final context = state.playbackContextFor(state.activeSourceKey);
      expect(context, isNotNull);
      expect(
        context!.siteByKey(localKey),
        isNotNull,
        reason: '续播要用上下文里的站点解析',
      );
      expect(context.siteByKey(localKey)!.api, localApi(localKey));
    });

    test('只读契约：本地源不得写回配置记录（state.config 与库里的 JSON 都不变）', () async {
      final state = newState();
      await state.bootstrap();
      await importActive(state);
      writeLocalSpider();
      await state.rescanSpiders();

      final record = state.database!.configBySourceKey(state.activeSourceKey)!;
      final jsonBefore = Map<String, Object?>.of(record.json);
      final sitesBefore = state.config!.sites.map((site) => site.key).toList();

      // 把每条会「拿配置去换站点」的读取路径都走一遍。
      expect(state.siteInActiveSource(localKey), isNotNull);
      expect(
        state.configForSourceKey(state.activeSourceKey)!.sites.map((s) => s.key),
        contains(localKey),
      );
      expect(
        state.playbackContextFor(state.activeSourceKey)!.siteByKey(localKey),
        isNotNull,
      );
      // 迁移前的老记录（空 source_key）按生效源解析，同样要看到本地源。
      expect(
        state.configForSourceKey('')!.sites.map((site) => site.key),
        contains(localKey),
      );

      expect(
        state.config!.sites.map((site) => site.key).toList(),
        sitesBefore,
        reason: '用户配置（配置记录原文）里不得出现本地源',
      );
      expect(
        state.config!.sites.map((site) => site.key),
        isNot(contains(localKey)),
        reason: '本地源一旦固化进配置记录，下次打开就变成「用户自己写的站点」',
      );
      expect(
        state.database!.configBySourceKey(state.activeSourceKey)!.json,
        equals(jsonBefore),
        reason: '读取路径只读：库里的配置 JSON 必须逐字段不变',
      );
    });
  });

  group('跨源与同 key 冲突（只追加不覆盖）', () {
    test('另一份配置的历史也引用这个本地源：能解析且不串源', () async {
      final state = newState();
      await state.bootstrap();
      await importActive(state);
      final otherKey = seedOtherConfig(
        state,
        name: '其它配置',
        originTag: 'other',
        sites: [
          _siteJson(key: 'other', name: '乙站', api: otherApi),
        ],
      );
      writeLocalSpider();
      await state.rescanSpiders();

      final beforeActive = state.activeSourceKey;
      final context = state.playbackContextFor(otherKey);
      expect(context, isNotNull, reason: '记录所属配置必须可解析');
      expect(
        context!.siteByKey(localKey),
        isNotNull,
        reason: '那份配置的记录同样可能是本地爬虫源播出来的',
      );
      expect(context.siteByKey(localKey)!.api, localApi(localKey));
      expect(
        context.siteByKey('other')!.api,
        otherApi,
        reason: '该配置自己的站点必须仍是它自己的 api（追加本地源不得改动它）',
      );
      expect(
        context.siteByKey('base'),
        isNull,
        reason: '不得把生效配置的站点带进其它配置的上下文（那是串源）',
      );
      expect(state.activeSourceKey, beforeActive, reason: '解析别的源不得切配置');
    });

    test('同 key 冲突：该配置自己的站点胜出，本地条目被拒绝', () async {
      final state = newState();
      await state.bootstrap();
      await importActive(state);
      final otherKey = seedOtherConfig(
        state,
        name: '其它配置',
        originTag: 'conflict',
        sites: [
          _siteJson(key: localKey, name: '用户自己的豆播', api: ownApi),
        ],
      );
      writeLocalSpider();
      await state.rescanSpiders();

      final context = state.playbackContextFor(otherKey)!;
      final site = context.siteByKey(localKey);
      expect(site, isNotNull);
      expect(
        site!.api,
        ownApi,
        reason: '同 key 时既有站点优先：追加本地源不能覆盖它',
      );
      expect(
        site.api.startsWith('spider-local:'),
        isFalse,
        reason: '上下文里这个 key 换成本地 api 就等于把别人的站点换掉了（串源）',
      );

      // 冲突只发生在**那一份**配置上：生效源里本地条目照旧可用。
      expect(
        state.playbackContextFor(state.activeSourceKey)!.siteByKey(localKey)!.api,
        localApi(localKey),
        reason: '同 key 让位是逐配置的，不该波及生效源',
      );
    });
  });

  // 修复点：上下文新鲜度 = 配置记录签名 + **合并源签名**
  // （`AppState._mergedSourcesSignature`）。不能改成「装配时清空整张表」——
  // 那张表同时是 `SiteService → 所属 sourceKey` 的身份索引
  // （`loadDetail` 的 captureSource 用它），清空会让原来源的在途详情记不出源。
  group('停用即消失（修复点：合并源签名参与上下文新鲜度判定）', () {
    test('停用后即时消失，重新启用又能解析（旧上下文不得残留）', () async {
      final state = newState();
      await state.bootstrap();
      await importActive(state);
      writeLocalSpider();
      await state.rescanSpiders();
      final activeKey = state.activeSourceKey;

      expect(state.localSourceEnabled(localKey), isTrue);
      expect(state.siteInActiveSource(localKey), isNotNull);
      // 先预热上下文缓存：这一份上下文里带着本地站点。停用本地源**不改配置
      // 记录**，只有合并源签名能判它过期——这也是本组用例唯一要锁的东西。
      expect(
        state.playbackContextFor(activeKey)!.siteByKey(localKey),
        isNotNull,
        reason: '前置：上下文已缓存',
      );

      final disabled = await state.setLocalSourceEnabled(localKey, false);
      expect(disabled, isTrue, reason: '前置：停用必须真的写盘成功');
      expect(state.localSourceEnabled(localKey), isFalse);
      expect(
        state.siteInActiveSource(localKey),
        isNull,
        reason: '停用即从站点集合消失，界面不该再解析得到它',
      );
      expect(
        state.playbackContextFor(activeKey)!.siteByKey(localKey),
        isNull,
        reason: '旧上下文必须失效：留着就等于拿一份含停用源的配置继续解析历史',
      );

      final enabled = await state.setLocalSourceEnabled(localKey, true);
      expect(enabled, isTrue, reason: '前置：重新启用必须真的写盘成功');
      expect(
        state.siteInActiveSource(localKey),
        isNotNull,
        reason: '重新启用后必须立刻又能解析',
      );
      expect(
        state.playbackContextFor(activeKey)!.siteByKey(localKey),
        isNotNull,
        reason: '启用回来的上下文同样要重建',
      );
    });
  });

  group('用户可见行为', () {
    testWidgets('本地源播出来的历史：点卡片进详情页，不再停在「已不在当前配置中」', (tester) async {
      dismissAllToasts();
      final state = _NoSidecarState(
        paths: paths,
        log: MemoryOnlyLogService(),
        httpClient: client,
      );
      addTearDown(state.dispose);
      await tester.runAsync(() async {
        await state.bootstrap();
        await state.setExternalMetaEnabled(false);
        await importActive(state);
        writeLocalSpider();
        await state.rescanSpiders();
      });
      expect(
        state.siteInActiveSource(localKey),
        isNotNull,
        reason: '前置：本地源必须已生效（否则本用例只是重演缺陷）',
      );

      // 真实数据形态：site_key 是本地源 manifest key，source_key 是生效配置。
      state.database!.upsertHistory(
        siteKey: localKey,
        vodId: 'v-local',
        vodName: '本地源剧集',
        // 有海报就不走历史页的补图管线（与本次缺陷无关的一层）。
        vodPic: 'http://127.0.0.1:1/poster.jpg',
        flag: '线路一',
        episodeName: '第1集',
        episodeId: 'http://127.0.0.1:1/e1',
        positionMs: 30000,
        durationMs: 100000,
        sourceKey: state.activeSourceKey,
      );
      final rows = state.recentHistory();
      expect(rows, hasLength(1), reason: '前置：这条历史必须可见（按源过滤后）');
      final item = rows.single;

      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [HistoryPage(state: state), const ToastHost()],
            ),
          ),
        ),
      );
      await tester.pump();

      final card = find.byKey(ValueKey('history-row-${item.id}'));
      expect(card, findsOneWidget, reason: '前置：卡片必须渲染出来');

      await tester.tap(card);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('已不在当前配置中'),
        findsNothing,
        reason: '修复前这里会停在提示上：站点查的是配置记录原文，本地源不在其中',
      );
      expect(
        find.byType(DetailPage),
        findsOneWidget,
        reason: '必须真的进入详情页，而不是「点了没反应」',
      );
      expect(
        state.selectedSite?.key,
        localKey,
        reason: '进详情前必须切到该记录所属的本地源站点，否则详情会串到别的站点',
      );
    });
  });

  group('首页续播入口（跨源）', () {
    // 首页 feed 取的是**全源**历史（recentHistory(sourceKey: '')），所以主按钮
    // 不能直接 resumeHistoryEntry：那会拿生效配置去解析别的源的记录，轻则误报
    // 「站点已不在配置中」，重则同名 key 在错源上起播（串源）。修复后先过
    // isHistoryFromOtherSource 闸门，走 openHistoryFromOtherSource。
    testWidgets('主按钮点另一份配置的历史：走跨源流程，不弹「已不在当前配置中」', (tester) async {
      dismissAllToasts();
      final state = _NoSidecarState(
        paths: paths,
        log: MemoryOnlyLogService(),
        httpClient: client,
      );
      addTearDown(state.dispose);
      late String otherKey;
      await tester.runAsync(() async {
        await state.bootstrap();
        await state.setExternalMetaEnabled(false);
        await importActive(state);
        // 另一份配置：site-b 用 type=4，解析时**无条件**向站点播放入口取地址，
        // 于是「请求打到 /other/ 还是 /A/」就是「用哪份配置解析」的硬证据。
        otherKey = seedOtherConfig(
          state,
          name: '其它配置',
          originTag: 'home-other',
          sites: [
            _siteJson(key: 'site-b', name: '乙站', api: crossApi, type: 4),
          ],
        );
      });

      // 真实数据形态：这条历史属于**另一份**配置。
      state.database!.upsertHistory(
        siteKey: 'site-b',
        vodId: 'v-other',
        vodName: '跨源剧集',
        vodPic: 'http://127.0.0.1:1/poster.jpg',
        flag: '线路一',
        episodeName: '第1集',
        episodeId: 'http://127.0.0.1:1/other/e1',
        positionMs: 30000,
        durationMs: 100000,
        sourceKey: otherKey,
      );
      final record = state.recentHistory(sourceKey: '').single;
      expect(
        state.isHistoryFromOtherSource(record),
        isTrue,
        reason: '前置：这条记录必须被判为「来自别的配置」，否则闸门分支根本没被走到',
      );
      final beforeActive = state.activeSourceKey;

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                HomePage(
                  state: state,
                  onOpenBrowse: () {},
                  onOpenHistory: () {},
                  onOpenFollowing: () {},
                  onImportConfig: () {},
                  onSearch: (_) {},
                ),
                const ToastHost(),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final primary = find.byKey(const ValueKey('home-hero-primary'));
      expect(primary, findsOneWidget, reason: '前置：hero 主按钮必须渲染出来');
      expect(find.text('继续播放'), findsOneWidget, reason: '前置：主按钮就是「继续播放」');
      // 只看点击之后发起的请求。
      client.urls.clear();

      await tester.tap(primary);
      // 真实 I/O 链（HTTP 站点解析）必须借 runAsync 推，fake-async 区里推不动。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('已不在当前配置中'),
        findsNothing,
        reason: '修复前主按钮直接 resumeHistoryEntry：用生效配置找 site-b 必然落空，'
            '于是弹的就是这句',
      );
      expect(
        client.urls,
        isNotEmpty,
        reason: '跨源流程必须真的拿原配置去解析（没有请求说明根本没试原来源）',
      );
      expect(
        client.urls.first.path,
        startsWith('/other'),
        reason: '第一个请求必须打给**原配置**的站点（/other）；打到 /A/ 就是拿生效配置解析别人的记录',
      );
      expect(
        find.textContaining('改为在当前播放源中匹配'),
        findsOneWidget,
        reason: '这句只出现在跨源流程的「原来源不可用 → 回退当前源」分支，是走到跨源流程的正面证据',
      );
      expect(
        find.byKey(const ValueKey('history-cross-source-dialog')),
        findsOneWidget,
        reason: '没有高置信候选时必须让用户自己选（打开全局搜索 / 取消），而不是静默失败',
      );
      expect(
        state.activeSourceKey,
        beforeActive,
        reason: '跨源续播不得把整个 App 切到另一份配置上',
      );
    });
  });
}

/// 有界重试删除临时目录。
///
/// Windows 上刚写完的文件可能被日志刷盘/实时扫描短暂持有（OS Error 32）。
/// 清理失败不得掩盖断言结果，因此重试用尽后放弃。
Future<void> _deleteTemp(Directory temp) async {
  for (var attempt = 1; attempt <= 20; attempt++) {
    if (!temp.existsSync()) return;
    try {
      temp.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 20) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
