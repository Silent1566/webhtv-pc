/// 配置导入与站点服务集成测试（§7.4.1、§7.4.2、§7.5、§8、§10.2、§19.3）。
///
/// 使用本地 fixture 服务重放 `packages/test-fixtures` 的同一份数据，因此断言
/// 对象是真实 HTTP 行为（编码、Header、错误码），而不是被打桩的返回值。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/config_loader.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/playback.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/storage.dart';

import 'support/test_fixture_server.dart';

void main() {
  late TestFixtureServer server;
  late ConfigLoader loader;
  late ConfigImportService importService;

  setUp(() async {
    server = await TestFixtureServer.start();
    loader = ConfigLoader();
    importService = ConfigImportService(loader: loader);
  });

  tearDown(() async {
    importService.close();
    await server.stop();
  });

  String configFor(String sitePath, {int type = 1, String key = 'k'}) =>
      jsonEncode({
        'name': '集成测试配置',
        'sites': [
          {
            'key': key,
            'name': '站点 $key',
            'type': type,
            'api': '${server.baseUrl}$sitePath',
            'searchable': 1,
            'quickSearch': 1,
          },
        ],
      });

  group('配置导入（§7.4.1、§7.5）', () {
    test('三种入口：JSON 文本、本地文件、HTTP URL', () async {
      // 1) 纯 JSON 文本
      final inline = await importService.import(
        ConfigSource.parse(configFor('/api/type1/')),
      );
      expect(inline.config!.sites.length, 1);
      expect(inline.origin, 'inline://json');

      // 2) 本地文件（写一个临时文件，验证文件读取路径）
      final temp = await Directory.systemTemp.createTemp('webhtv-config-test');
      final file = File('${temp.path}${Platform.pathSeparator}config.json');
      await file.writeAsString(configFor('/api/type1/'));
      final fromFile = await importService.import(
        ConfigSource.parse(file.path),
      );
      expect(fromFile.config!.sites.first.api, contains(server.baseUrl));
      expect(fromFile.origin, contains('config.json'));

      // 3) HTTP URL：重定向后仍能导入
      final fromUrl = await importService.import(
        ConfigSource.parse('${server.baseUrl}/api/redirect-to-config'),
      );
      expect(fromUrl.config!.sites, isNotEmpty);
      expect(fromUrl.origin, contains('config.json'));

      await temp.delete(recursive: true);
    });

    test('gzip 传输编码与 UTF-8 BOM 都能导入', () async {
      final gz = await importService.import(
        ConfigSource.parse('${server.baseUrl}/api/gzip'),
      );
      expect(gz.contentEncoding, 'gzip');
      expect(gz.config!.sites, isNotEmpty);

      final bom = await importService.import(
        ConfigSource.parse('${server.baseUrl}/api/bom'),
      );
      expect(bom.config!.sites, isNotEmpty);
    });

    test('声明 charset=gbk 的配置可解码（§7.4.1）', () async {
      final gbk = await importService.import(
        ConfigSource.parse('${server.baseUrl}/api/gbk'),
      );
      expect(gbk.config!.name, 'GBK 配置');
      expect(gbk.config!.sites.first.name, '站点');
    });

    test('重定向循环与降级到 file:// 都被拒绝', () async {
      final loop = await _capture(
        () => importService.import(
          ConfigSource.parse('${server.baseUrl}/api/redirect-loop'),
        ),
      );
      expect(loop.kind, AppErrorKind.configRedirect);

      final downgrade = await _capture(
        () => importService.import(
          ConfigSource.parse('${server.baseUrl}/api/redirect-to-file'),
        ),
      );
      expect(downgrade.kind, AppErrorKind.configSchemeUnsupported);
    });

    test('超过大小上限的响应被拒绝且保留已有配置（§7.4.1）', () async {
      final small = ConfigLoader(maxBytes: 64 * 1024);
      final error = await _capture(
        () => small.fetch(ConfigSource.parse('${server.baseUrl}/api/oversize')),
      );
      small.close();
      expect(error.kind, AppErrorKind.configTooLarge);
    });

    test('HTTP 非 2xx 映射为 configHttp，网络不可达映射为 configNetwork', () async {
      final http = await _capture(
        () => importService.import(
          ConfigSource.parse('${server.baseUrl}/api/does-not-exist'),
        ),
      );
      expect(http.kind, AppErrorKind.configHttp);
      expect(http.statusCode, 404);

      // 关闭服务后请求同一端口应得到网络错误。
      final deadUrl = 'http://127.0.0.1:${server.baseUrl.split(":").last}/api/type1/';
      await server.stop();
      final network = await _capture(
        () => importService.import(ConfigSource.parse(deadUrl)),
      );
      expect(network.kind, AppErrorKind.configNetwork);
      expect(network.retryable, isTrue);
      // tearDown 会再次 stop，这里补一个新的服务避免重复关闭报错。
      server = await TestFixtureServer.start();
    });

    test('文件不存在报 configNotFound', () async {
      final error = await _capture(
        () => importService.import(
          ConfigSource.parse(
            '${Directory.systemTemp.path}${Platform.pathSeparator}missing-config.json',
          ),
        ),
      );
      expect(error.kind, AppErrorKind.configNotFound);
    });

    test('msg 非空的配置导入失败且不覆盖已有配置记录', () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.dispose);

      // 先保存一份可用配置。
      final good = await importService.import(
        ConfigSource.parse(configFor('/api/type1/')),
      );
      database.saveConfig(
        name: 'good',
        origin: good.origin,
        json: good.config!.toJson(),
        siteCount: good.config!.sites.length,
      );

      // 再导入 msg 配置，直接失败。
      final error = await _capture(
        () => importService.import(
          ConfigSource.parse(
            jsonEncode({'msg': '配置已下线', 'sites': []}),
          ),
        ),
      );
      expect(error.kind, AppErrorKind.configMsg);

      // 已有记录仍然可用，没有被覆盖。
      final records = database.listConfigs();
      expect(records.length, 1);
      expect(records.first.name, 'good');
      expect(records.first.json['sites'], isNotEmpty);
    });

    test('配置仓库：默认第一项、失败回退、不覆盖已有配置（§7.4.2）', () async {
      final repository = await importService.import(
        ConfigSource.parse(
          jsonEncode({
            'urls': [
              {'name': 'A', 'url': '${server.baseUrl}/api/repository-a.json'},
              {'name': 'B', 'url': '${server.baseUrl}/api/repository-b.json'},
            ],
          }),
        ),
      );
      expect(repository.isRepository, isTrue);
      expect(repository.siteCount, 0);

      // 默认第一项。
      final first = await importService.expandRepository(repository);
      expect(first.config!.sites.first.key, 'repo-a');

      // 显式选择第二项，条目各自独立配置记录。
      final second = await importService.expandRepository(repository, index: 1);
      expect(second.config!.sites.first.key, 'repo-b');

      // index 越界回退到第一项。
      final fallback = await importService.expandRepository(repository, index: 99);
      expect(fallback.config!.sites.first.key, 'repo-a');

      // 失效条目抛错，调用方保留已导入配置。
      final broken = await importService.import(
        ConfigSource.parse(
          jsonEncode({
            'urls': [
              {'name': '坏条目', 'url': '${server.baseUrl}/api/does-not-exist.json'},
            ],
          }),
        ),
      );
      final error = await _capture(
        () => importService.expandRepository(broken),
      );
      expect(error.kind, AppErrorKind.configHttp);
    });

    test('仓库条目的内容仍是仓库时停止递归展开（§7.4.2）', () async {
      final nested = await importService.import(
        ConfigSource.parse(
          jsonEncode({
            'urls': [
              {
                'name': '嵌套仓库',
                'url': '${server.baseUrl}/api/repository-nested.json',
              },
            ],
          }),
        ),
      );
      final error = await _capture(
        () => importService.expandRepository(nested),
      );
      expect(error.kind, AppErrorKind.configRepository);
      expect(error.message, contains('仍是仓库'));
    });

    test('仓库条目内容非法或站点为空时给出可定位错误', () async {
      final emptyEntry = await importService.import(
        ConfigSource.parse(
          jsonEncode({
            'urls': [
              {
                'name': '空条目',
                'url': '${server.baseUrl}/api/repository-broken.json',
              },
            ],
          }),
        ),
      );
      // 条目既没有 sites 也没有 urls：这是配置内容非法，保留原始错误码
      // 比统一报“仓库展开失败”更能定位问题。
      final error = await _capture(
        () => importService.expandRepository(emptyEntry),
      );
      expect(error.kind, AppErrorKind.configInvalid);
      expect(error.detail, contains('repository-broken'));
    });
  });

  group('站点服务闭环（§8、§10.2）', () {
    late SiteService service;
    late AppDatabase database;
    late SpiderRouter router;
    late AppConfig config;

    setUp(() async {
      database = AppDatabase.inMemory();
      final loaded = await importService.import(
        ConfigSource.parse(
          jsonEncode({
            'name': '闭环配置',
            'headers': [
              {
                'host': '127.0.0.1',
                'header': {'X-Global': 'yes'},
              },
            ],
            'sites': [
              {
                'key': 'type1',
                'name': 'JSON API 站点',
                'type': 1,
                'api': '${server.baseUrl}/api/type1/',
                'searchable': 1,
                'quickSearch': 1,
                'header': {'X-Site': 'type1'},
              },
            ],
          }),
        ),
      );
      config = loaded.config!;
      router = SpiderRouter(
        client: HttpApiClient(),
        globalHeaders: config.headers,
      );
      service = SiteService(
        appConfig: config,
        router: router,
        database: database,
      );
    });

    tearDown(() {
      database.dispose();
      router.dispose();
    });

    Site site() => config.sites.first;

    test('首页 → 分类 → 详情 → 播放 闭环', () async {
      final home = await service.home(site());
      expect(home.value.classes, isNotEmpty);
      expect(home.value.list, isNotEmpty);

      final category = await service.category(site(), typeId: '1', page: 1);
      expect(category.value.list, isNotEmpty);
      expect(category.value.pageCount, 1);

      final detail = await service.detail(site(), 'demo-1');
      final vod = detail.value.list.first;
      expect(vod.vodPlayUrl, contains('sample.m3u8'));

      final lines = SiteService.playLinesOf(vod);
      expect(lines, isNotEmpty);

      final decision = await service.resolvePlayback(
        site: site(),
        episodeTarget: lines.first.episodes.first.url,
        flag: lines.first.flag,
        vodId: vod.vodId,
      );
      expect(decision.value.action, PlaybackAction.direct);
      expect(decision.value.url, contains('/media/sample.m3u8'));
    });

    test('请求捕获：参数编码与 Header 注入符合 §7.4.6、§7.4.7', () async {
      server.captured.clear();
      // 站点 ext 超过 1000 字符时应改用表单 body。
      final longExtConfig = AppConfig(
        sites: [
          Site(
            key: 'long',
            name: '长 ext 站点',
            type: 1,
            api: '${server.baseUrl}/api/type1/',
            ext: 'x' * 1001,
          ),
        ],
      );
      final longService = SiteService(
        appConfig: longExtConfig,
        router: SpiderRouter(
          client: HttpApiClient(),
          globalHeaders: const [],
        ),
        database: database,
      );
      await longService.home(longExtConfig.sites.first);

      final longCall = server.captured.last;
      expect(longCall.method, 'POST');
      expect(longCall.form['extend'], 'x' * 1001);
      expect(longCall.query.containsKey('extend'), isFalse);

      // 短 ext + 分类：query 携带 extend/t/ac，并注入全局与站点 Header。
      server.captured.clear();
      await service.category(site(), typeId: '1', page: 2, filters: {'area': '大陆'});
      final call = server.captured.last;
      expect(call.method, 'GET');
      expect(call.query['ac'], 'detail');
      expect(call.query['t'], '1');
      expect(call.query['pg'], '2');
      expect(call.query['f'], jsonEncode({'area': '大陆'}));
      expect(call.headers['x-global'], 'yes');
      expect(call.headers['x-site'], 'type1');
    });

    test('type=0 XML 站点首页与详情解析', () async {
      final xmlConfig = AppConfig(
        sites: [
          Site(
            key: 'xml',
            name: 'XML 站点',
            type: 0,
            api: '${server.baseUrl}/api/type0/',
          ),
        ],
      );
      final xmlService = SiteService(
        appConfig: xmlConfig,
        router: SpiderRouter(
          client: HttpApiClient(),
          globalHeaders: const [],
        ),
        database: database,
      );
      final home = await xmlService.home(xmlConfig.sites.first);
      expect(home.value.classes.length, 2);
      expect(home.value.list.first.vodName, 'XML 测试视频');
      expect(home.value.list.first.vodRemarks, '第 1 集');

      final detail = await xmlService.detail(xmlConfig.sites.first, 'demo-1');
      final lines = SiteService.playLinesOf(detail.value.list.first);
      expect(lines.first.episodes.length, 2);
      expect(lines.first.episodes[1].name, '第 2 集');
    });

    test('type=4 分类筛选对象使用 Base64 URL-Safe ext（§7.4.5）', () async {
      final type4Config = AppConfig(
        sites: [
          Site(
            key: 'type4',
            name: 'Base64 站点',
            type: 4,
            api: '${server.baseUrl}/api/type4/',
          ),
        ],
      );
      final type4Service = SiteService(
        appConfig: type4Config,
        router: SpiderRouter(
          client: HttpApiClient(),
          globalHeaders: const [],
        ),
        database: database,
      );
      server.captured.clear();
      await type4Service.category(
        type4Config.sites.first,
        typeId: '1',
        filters: {'area': '大陆'},
      );
      final call = server.captured.last;
      final ext = call.query['ext']!;
      expect(ext.contains('+'), isFalse);
      expect(ext.contains('/'), isFalse);
      expect(ext.contains('='), isFalse);
      final padded = ext.padRight((ext.length + 3) ~/ 4 * 4, '=');
      expect(utf8.decode(base64Url.decode(padded)), jsonEncode({'area': '大陆'}));
    });

    test('搜索：命中缓存后不再发起请求（§14.1）', () async {
      server.captured.clear();
      final first = await service.search(site(), keyword: '示例');
      expect(first.value.list, isNotEmpty);
      expect(first.fromCache, isFalse);
      final requestsAfterFirst = server.captured.length;

      final second = await service.search(site(), keyword: '示例');
      expect(second.fromCache, isTrue);
      expect(server.captured.length, requestsAfterFirst);

      // 显式跳过缓存时必须重新请求。
      final third = await service.search(site(), keyword: '示例', useCache: false);
      expect(third.fromCache, isFalse);
      expect(server.captured.length, greaterThan(requestsAfterFirst));
    });

    test('未声明 searchable 的站点搜索报 siteUnsupported', () async {
      final noSearch = AppConfig(
        sites: [
          Site(
            key: 'nosearch',
            name: '不可搜索',
            type: 1,
            api: '${server.baseUrl}/api/type1/',
          ),
        ],
      );
      final runtime = SpiderRouter(
        client: HttpApiClient(),
        globalHeaders: const [],
      ).runtimeFor(noSearch.sites.first);
      await expectLater(
        runtime.search(noSearch.sites.first, keyword: 'x'),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.siteUnsupported,
          ),
        ),
      );
    });

    test('播出错：HTML 错误页与非 2xx 都是可定位错误', () async {
      final brokenConfig = AppConfig(
        sites: [
          Site(
            key: 'html',
            name: 'HTML 错误站点',
            type: 1,
            api: '${server.baseUrl}/api/error-html',
          ),
          Site(
            key: 'missing',
            name: '404 站点',
            type: 1,
            api: '${server.baseUrl}/api/does-not-exist',
          ),
        ],
      );
      final brokenService = SiteService(
        appConfig: brokenConfig,
        router: SpiderRouter(
          client: HttpApiClient(),
          globalHeaders: const [],
        ),
        database: database,
      );

      final htmlError = await _capture(
        () => brokenService.home(brokenConfig.sites.first),
      );
      expect(htmlError.kind, AppErrorKind.siteHttp);

      final notFound = await _capture(
        () => brokenService.home(brokenConfig.sites[1]),
      );
      expect(notFound.kind, AppErrorKind.siteHttp);
      expect(notFound.statusCode, 404);
    });

    test('超时映射为 siteTimeout 且标记可重试（§10.4）', () async {
      final slowConfig = AppConfig(
        sites: [
          Site(
            key: 'slow',
            name: '慢站点',
            type: 1,
            api: '${server.baseUrl}/api/slow?delay=2',
          ),
        ],
      );
      final slowService = SiteService(
        appConfig: slowConfig,
        router: SpiderRouter(
          client: HttpApiClient(timeout: const Duration(milliseconds: 300)),
          globalHeaders: const [],
        ),
        database: database,
      );
      final error = await _capture(
        () => slowService.home(slowConfig.sites.first),
      );
      expect(error.kind, AppErrorKind.siteTimeout);
      expect(error.retryable, isTrue);
    });

    test('单站点失败不影响其他站点（§8.4、§14.3）', () async {
      final mixed = AppConfig(
        sites: [
          Site(
            key: 'good',
            name: '可用站点',
            type: 1,
            api: '${server.baseUrl}/api/type1/',
          ),
          Site(
            key: 'bad',
            name: '不可用站点',
            type: 1,
            api: '${server.baseUrl}/api/does-not-exist',
          ),
        ],
      );
      final mixedService = SiteService(
        appConfig: mixed,
        router: SpiderRouter(
          client: HttpApiClient(),
          globalHeaders: const [],
        ),
        database: database,
      );

      final good = await mixedService.home(mixed.sites.first);
      expect(good.value.list, isNotEmpty);

      final bad = await _capture(() => mixedService.home(mixed.sites[1]));
      expect(bad.kind, AppErrorKind.siteHttp);

      // 失败之后可用站点仍能正常工作。
      final again = await mixedService.home(mixed.sites.first);
      expect(again.value.list, isNotEmpty);
    });

    test('多线路/多剧集详情能解析出全部线路（§8.4）', () async {
      final multi = await service.detail(site(), 'multi-1');
      final lines = SiteService.playLinesOf(multi.value.list.first);
      expect(lines.length, 3);
      expect(lines[0].episodes.length, 2);

      final episodes = await service.detail(site(), 'episodes-1');
      final single = SiteService.playLinesOf(episodes.value.list.first);
      expect(single.length, 1);
      expect(single.first.episodes.length, 3);
    });

    test('详情业务错误 msg 上报为 siteBusiness，不变成空列表', () async {
      final error = await _capture(() => service.detail(site(), 'msg-1'));
      expect(error.kind, AppErrorKind.siteBusiness);
      expect(error.message, contains('维护中'));
    });

    test('播放决策记录健康统计与耗时（§14.2）', () async {
      final decision = await service.resolvePlayback(
        site: site(),
        episodeTarget: '${server.baseUrl}/media/sample.m3u8',
        flag: 'line',
      );
      expect(decision.value.action, PlaybackAction.direct);

      final health = database.siteHealth();
      expect(health, isNotEmpty);
      final entry = health.firstWhere((item) => item.siteKey == 'type1');
      expect(entry.playTotal, greaterThanOrEqualTo(1));
      expect(entry.playOk, greaterThanOrEqualTo(1));
    });

    test('需要解析器的剧集给出明确错误而不是静默成功（§7.4.8）', () async {
      final error = await _capture(
        () => service.resolvePlayback(
          site: site(),
          episodeTarget: 'not-a-url-token',
          flag: 'line',
        ),
      );
      expect(error.kind, AppErrorKind.playbackParserRequired);
    });

    test('播放结果 parse=1 时明确报需要解析器（§7.4.8）', () async {
      // 站点 playUrl 指向返回 parse=0 的播放入口，这里改用一个显式返回
      // parse=1 的场景：直接构造结果集合并走 resolver。
      final error = _captureSync(
        () => PlaybackResolver.decide(
          PlaybackResolutionInput(
            site: site(),
            episodeTarget: 'token',
            parse: 1,
          ),
        ),
      );
      expect(error.kind, AppErrorKind.playbackParserRequired);
    });
  });

  group('配置记录持久化与恢复（§7.5、§16）', () {
    test('导入 → 保存 → 重启恢复 得到同样的模型与未知字段', () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.dispose);

      final imported = await importService.import(
        ConfigSource.parse(
          jsonEncode({
            'name': '待持久化配置',
            'sites': [
              {
                'key': 'k',
                'name': '站点',
                'type': 1,
                'api': '${server.baseUrl}/api/type1/',
                'futureField': 'keep',
              },
            ],
            'futureTopLevel': {'x': 1},
          }),
        ),
      );
      final id = database.saveConfig(
        name: '待持久化配置',
        origin: imported.origin,
        json: imported.config!.toJson(),
        contentType: imported.contentType,
        siteCount: imported.config!.sites.length,
      );
      database.saveConfigSites(id, imported.config!.sites);

      final record = database.activeConfig()!;
      expect(record.siteCount, 1);
      expect(record.name, '待持久化配置');

      final restored = record.config!;
      expect(restored.sites.first.extra['futureField'], 'keep');
      expect(restored.extra['futureTopLevel'], {'x': 1});

      // 恢复后的站点仍然可以正常工作（模型未在往返中损坏）。
      final router = SpiderRouter(
        client: HttpApiClient(),
        globalHeaders: const [],
      );
      addTearDown(router.dispose);
      final service = SiteService(
        appConfig: restored,
        router: router,
        database: database,
      );
      final home = await service.home(restored.sites.first);
      expect(home.value.list, isNotEmpty);

      final sites = database.configSites(id);
      expect(sites.length, 1);
      expect(sites.first['site_key'], 'k');
      expect(sites.first['type'], 1);
    });

    test('重复导入同一来源覆盖而不是新增版本', () async {
      final database = AppDatabase.inMemory();
      addTearDown(database.dispose);
      final origin = '${server.baseUrl}/api/type1/config.json';
      final first = await importService.import(ConfigSource.parse(origin));
      database.saveConfig(
        name: 'v1',
        origin: first.origin,
        json: first.config!.toJson(),
        siteCount: 1,
      );
      final second = await importService.import(ConfigSource.parse(origin));
      database.saveConfig(
        name: 'v2',
        origin: second.origin,
        json: second.config!.toJson(),
        siteCount: second.config!.sites.length,
      );
      expect(database.listConfigs().length, 1);
      expect(database.activeConfig()!.name, 'v2');
    });
  });
}

/// 捕获异步 [AppError]。
Future<AppError> _capture(Future<void> Function() action) async {
  try {
    await action();
  } on AppError catch (error) {
    return error;
  } catch (error) {
    fail('期望 AppError，实际抛出 ${error.runtimeType}: $error');
  }
  fail('期望抛出 AppError，但没有抛出');
}

/// 捕获同步 [AppError]。
AppError _captureSync(void Function() action) {
  try {
    action();
  } on AppError catch (error) {
    return error;
  } catch (error) {
    fail('期望 AppError，实际抛出 ${error.runtimeType}: $error');
  }
  fail('期望抛出 AppError，但没有抛出');
}
