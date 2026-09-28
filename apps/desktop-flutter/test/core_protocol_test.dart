/// 核心协议单元测试（设计文档 §7.5、§8.4、§19.3）。
///
/// 覆盖配置解析、字段语义、HTTP API 请求编码、Result/Vod 解析、多线路多剧集、
/// Header 合并、播放决策、日志脱敏与文本解码。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/config_loader.dart';
import 'package:webhtv_pc/core/config_parser.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/playback.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/text_codec.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/services/storage.dart';

import 'fixture_support.dart';

void main() {
  group('配置解析（§7.1–§7.4）', () {
    test('最小配置解析出站点与未知字段保留', () {
      final document = parseConfigDocument(readFixture('config/config-min.json'));
      final config = document.config!;
      expect(config.sites.length, greaterThanOrEqualTo(6));
      expect(config.parses.length, 2);
      expect(config.flags, ['youku', 'qq', 'iqiyi']);
      expect(config.headers.length, 1);
      expect(config.home, 'fixture-type1');
      // 未知顶层字段与站点字段必须保留，不能因解析而丢失。
      expect(config.extra['futureTopLevel'], {'must': 'be preserved'});
      final type1 = config.sites.firstWhere((site) => site.key == 'fixture-type1');
      expect(type1.extra['futureField'], isNull);
      expect(config.defaultSite()?.key, 'fixture-type1');
    });

    test('msg 键存在即拒绝加载（含空值），错误码为 configMsg', () {
      for (final name in ['config/config-msg-error.json', 'config/config-msg-empty.json']) {
        expect(
          () => parseConfigDocument(readFixture(name)),
          throwsA(
            isA<AppError>().having(
              (error) => error.kind,
              'kind',
              AppErrorKind.configMsg,
            ),
          ),
          reason: name,
        );
      }
      final error = _captureError(
        () => parseConfigDocument(readFixture('config/config-msg-error.json')),
      );
      expect(error.message, contains('停止维护'));
    });

    test('urls 仓库：无 sites 但有 urls 时识别为仓库', () {
      final document = parseConfigDocument(
        readFixture('config/config-repository.json'),
      );
      expect(document.isRepository, isTrue);
      expect(document.repositoryEntries.length, 2);
      expect(document.repositoryEntries.first.url, contains('repository-a'));
    });

    test('urls 纯字符串条目给出弃用诊断', () {
      final document = parseConfigDocument(
        jsonEncode({
          'urls': ['http://127.0.0.1:18080/api/repository-a.json'],
        }),
      );
      expect(document.isRepository, isTrue);
      expect(document.diagnostics.join(), contains('已弃用'));
    });

    test('无效 JSON 报 configInvalid 且带偏移信息', () {
      final error = _captureError(
        () => parseConfigDocument(readFixture('config/config-invalid.json')),
      );
      expect(error.kind, AppErrorKind.configInvalid);
      expect(error.detail, contains('offset'));
    });

    test('根节点不是对象时报 configInvalid', () {
      final error = _captureError(() => parseConfigDocument('[1,2,3]'));
      expect(error.kind, AppErrorKind.configInvalid);
    });

    test('没有 sites 也没有 urls 时报 configInvalid', () {
      final error = _captureError(() => parseConfigDocument('{"name":"空"}'));
      expect(error.kind, AppErrorKind.configInvalid);
    });

    test('全字段配置：所有 §7.1 顶层键都被保留', () {
      final document = parseConfigDocument(readFixture('config/config-full.json'));
      final config = document.config!;
      expect(config.spider, isNotNull);
      expect(config.lives, isNotEmpty);
      expect(config.doh, isNotEmpty);
      expect(config.proxy, isNotEmpty);
      expect(config.hosts, isNotEmpty);
      expect(config.rules, isNotEmpty);
      expect(config.hlsRules, isNotEmpty);
      expect(config.groupRules, isNotEmpty);
      expect(config.ads, isNotEmpty);
      expect(config.wallpaper, isNotNull);
      expect(config.logo, isNotNull);
      expect(config.parse, 'json解析');
      final roundTrip = config.toJson();
      expect(roundTrip['futureTopLevel'], {'must': 'be preserved'});
      expect((roundTrip['sites'] as List).length, config.sites.length);
    });

    test('配置导入来源识别：URL / 文件 / JSON 文本 / 非法协议', () {
      expect(ConfigSource.parse('https://example.invalid/a.json').kind,
          ConfigSourceKind.url);
      expect(ConfigSource.parse(r'C:\tmp\a.json').kind, ConfigSourceKind.file);
      expect(ConfigSource.parse('{"sites":[]}').kind, ConfigSourceKind.inlineJson);
      final error = _captureError(() => ConfigSource.parse('ftp://example.invalid/a.json'));
      expect(error.kind, AppErrorKind.configSchemeUnsupported);
    });
  });

  group('站点类型与分发（§8.1）', () {
    test('type=0/1/2/4 均可运行，type=3 按 api 形态判定', () {
      Site site(int type, {String api = 'http://127.0.0.1:18080/api/x/'}) =>
          Site(key: 'k', name: 'n', type: type, api: api);

      expect(SpiderRouter.classify(site(0)).available, isTrue);
      expect(SpiderRouter.classify(site(1)).available, isTrue);
      expect(SpiderRouter.classify(site(2)).available, isTrue);
      expect(SpiderRouter.classify(site(4)).available, isTrue);

      final js = SpiderRouter.classify(site(3, api: 'http://x/spider/a.js'));
      expect(js.available, isFalse);
      expect(js.runtimeName, contains('JS'));
      expect(js.stage, 'Phase 3');

      final py = SpiderRouter.classify(site(3, api: 'http://x/spider/a.py'));
      expect(py.available, isFalse);
      expect(py.stage, 'Phase 3');

      // §9.4:MVP-B 后 `/spider/` 形态由 CatSpider HTTP 承担,变为可用。
      final catHttp =
          SpiderRouter.classify(site(3, api: 'http://x/spider/cat/home'));
      expect(catHttp.available, isTrue);
      expect(catHttp.runtimeName, contains('CatSpider HTTP'));
      expect(catHttp.stage, 'MVP-B');

      final csp = SpiderRouter.classify(site(3, api: 'csp_Demo'));
      expect(csp.runtimeName, 'PC Java Spider');

      final jar = SpiderRouter.classify(
        Site(key: 'j', name: 'j', type: 3, api: 'demo', jar: 'http://x/a.jar'),
      );
      expect(jar.runtimeName, contains('JAR'));

      final nullRuntime = SpiderRouter.classify(site(3, api: 'demo'));
      expect(nullRuntime.runtimeName, 'SpiderNull');
      expect(nullRuntime.reason, contains('未匹配'));

      // 本地 sidecar 需要注册表,必须用实例方法判定(§9.7)。
      final localStatic = SpiderRouter.classify(
        site(3, api: 'spider-local:demo'),
      );
      expect(localStatic.available, isFalse);
      expect(localStatic.reason, contains('classifySite'));
    });

    test('不支持站点返回 SPIDER_UNSUPPORTED 而不返回空列表', () async {
      final router = SpiderRouter(
        client: HttpApiClient(),
        globalHeaders: const [],
      );
      final site = Site(key: 'k', name: 'n', type: 3, api: 'demo.js');
      final runtime = router.runtimeFor(site);
      expect(
        () => runtime.home(site),
        throwsA(
          isA<AppError>().having(
            (error) => error.kind,
            'kind',
            AppErrorKind.siteUnsupported,
          ),
        ),
      );
      router.dispose();
    });
  });

  group('HTTP API 请求编码（§7.4.7）', () {
    Site site(int type, {Object? ext, Map<String, Object?> extra = const {}}) =>
        Site(
          key: 'site-$type',
          name: 'site-$type',
          type: type,
          api: 'http://127.0.0.1:18080/api/type$type/',
          ext: ext,
          searchable: true,
          quickSearch: true,
          header: HeaderMap({'X-Site': 'yes'}),
          extra: extra,
        );

    test('type=0 分类使用 ac=videolist，type=1 使用 ac=detail', () {
      final xml = HttpApiRequestBuilder(site: site(0))
          .build(HttpApiAction.category, typeId: '1', page: 2);
      expect(xml.uri.queryParameters['ac'], 'videolist');
      expect(xml.uri.queryParameters['t'], '1');
      expect(xml.uri.queryParameters['pg'], '2');

      final json = HttpApiRequestBuilder(site: site(1))
          .build(HttpApiAction.category, typeId: '1', page: 2);
      expect(json.uri.queryParameters['ac'], 'detail');
    });

    test('type=1 筛选对象进 f，type=4 筛选对象进 Base64 URL-Safe ext', () {
      final filters = {'area': '大陆', 'year': '2026'};
      final type1 = HttpApiRequestBuilder(site: site(1))
          .build(HttpApiAction.category, typeId: '1', filters: filters);
      expect(type1.uri.queryParameters['f'], jsonEncode(filters));

      final type4 = HttpApiRequestBuilder(site: site(4))
          .build(HttpApiAction.category, typeId: '1', filters: filters);
      final ext = type4.uri.queryParameters['ext']!;
      expect(ext.contains('+'), isFalse);
      expect(ext.contains('/'), isFalse);
      expect(ext.contains('='), isFalse);
      // URL-Safe Base64 必须能还原原 JSON。
      final padded = ext.padRight((ext.length + 3) ~/ 4 * 4, '=');
      expect(utf8.decode(base64Url.decode(padded)), jsonEncode(filters));
    });

    test('站点 ext ≤1000 走 query，>1000 走表单 body', () {
      final shortExt = 'a' * 1000;
      final queryCall = HttpApiRequestBuilder(site: site(1, ext: shortExt))
          .build(HttpApiAction.home);
      expect(queryCall.uri.queryParameters['extend'], shortExt);
      expect(queryCall.formBody, isNull);
      expect(queryCall.method, 'GET');

      final longExt = 'b' * 1001;
      final formCall = HttpApiRequestBuilder(site: site(1, ext: longExt))
          .build(HttpApiAction.home);
      expect(formCall.uri.queryParameters.containsKey('extend'), isFalse);
      expect(formCall.formBody?['extend'], longExt);
      expect(formCall.method, 'POST');
      expect(formCall.headers['Content-Type'], contains('x-www-form-urlencoded'));
    });

    test('ext 对象按稳定 JSON 文本传递，不做 Base64（§7.4.5）', () {
      final builder = HttpApiRequestBuilder(
        site: site(1, ext: {'fixture': true, 'n': 1}),
      );
      expect(builder.normalizedExt, '{"fixture":true,"n":1}');
    });

    test('Header 注入顺序：全局规则匹配 host 后由站点 header 覆盖同名键', () {
      final rules = [
        HeaderRule(
          host: '127.0.0.1',
          header: HeaderMap({'X-Global': '1', 'X-Shared': 'global'}),
        ),
        HeaderRule(host: 'other.invalid', header: HeaderMap({'X-Global': '2'})),
      ];
      final builder = HttpApiRequestBuilder(
        site: Site(
          key: 'k',
          name: 'n',
          type: 1,
          api: 'http://127.0.0.1:18080/api/type1/',
          header: HeaderMap({'X-Shared': 'site'}),
        ),
        globalHeaders: rules,
      );
      final call = builder.build(HttpApiAction.home);
      expect(call.headers['X-Global'], '1');
      // 站点 header 覆盖全局同名键。
      expect(call.headers['X-Shared'], 'site');
      expect(call.headers['User-Agent'], HttpApiRequestBuilder.defaultUserAgent);
    });

    test('搜索请求带 wd/pg，quick 仅在站点声明 quickSearch 时生效', () {
      final call = HttpApiRequestBuilder(site: site(1))
          .build(HttpApiAction.search, keyword: '示例', page: 3, quick: true);
      expect(call.uri.queryParameters['wd'], '示例');
      expect(call.uri.queryParameters['pg'], '3');
      expect(call.uri.queryParameters['quick'], 'true');
    });

    test('api 为空或非 http(s) 时报可定位错误', () {
      final empty = _captureError(
        () => HttpApiRequestBuilder(
          site: Site(key: 'k', name: 'n', type: 1, api: ''),
        ).build(HttpApiAction.home),
      );
      expect(empty.kind, AppErrorKind.siteEmptyApi);

      final bad = _captureError(
        () => HttpApiRequestBuilder(
          site: Site(key: 'k', name: 'n', type: 1, api: 'file:///tmp/a.json'),
        ).build(HttpApiAction.home),
      );
      expect(bad.kind, AppErrorKind.siteEmptyApi);
    });

    test('playUrl 播放入口保留原 query 并追加 id', () {
      final builder = HttpApiRequestBuilder(
        site: Site(
          key: 'k',
          name: 'n',
          type: 1,
          api: 'http://127.0.0.1:18080/api/type1/',
          extra: {'playUrl': 'http://127.0.0.1:18080/api/play?src=1'},
        ),
      );
      final call = builder.buildPlayRequest('abc');
      expect(call.uri.queryParameters['src'], '1');
      expect(call.uri.queryParameters['id'], 'abc');
    });

    test('缺少 playUrl 的播放入口报需要解析器', () {
      final error = _captureError(
        () => HttpApiRequestBuilder(
          site: Site(key: 'k', name: 'n', type: 1, api: 'http://x/api/'),
        ).buildPlayRequest('abc'),
      );
      expect(error.kind, AppErrorKind.playbackParserRequired);
    });
  });

  group('Result / Vod 解析（§8.3、§8.4）', () {
    test('首页 JSON：class/list/filters 解析正确', () {
      final result = HttpApiResponseParser.parse(
        readFixture('http/home.json'),
        siteKey: 'k',
      );
      expect(result.classes, isNotEmpty);
      expect(result.list, isNotEmpty);
      expect(result.list.first.vodId, 'demo-1');
    });

    test('分类 JSON：分页字段与筛选项解析正确', () {
      final result = HttpApiResponseParser.parse(
        readFixture('http/filters.json'),
        siteKey: 'k',
      );
      expect(result.page, 1);
      expect(result.pageCount, 1);
      expect(result.total, 1);
      expect(result.filters['1'], isNotEmpty);
      expect(result.filters['1']!.first.key, 'area');
      expect(result.filters['1']!.first.options.length, 3);
      expect(result.filters['1']!.first.options[1].value, '大陆');
    });

    test('XML API（type=0）解析 class 与 list', () {
      const xml = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <class id="1">电影</class>
  <list id="demo-1">
    <name>XML 测试视频</name>
    <note>第 1 集</note>
    <dt>第 1 集\$http://127.0.0.1:18080/media/sample.m3u8</dt>
  </list>
</rss>''';
      final result = HttpApiResponseParser.parse(xml, siteKey: 'k');
      expect(result.classes.first.typeId, '1');
      expect(result.classes.first.typeName, '电影');
      expect(result.list.first.vodId, 'demo-1');
      expect(result.list.first.vodName, 'XML 测试视频');
      expect(result.list.first.vodRemarks, '第 1 集');
    });

    test('播放结果解析出 url/header/parse', () {
      final result = HttpApiResponseParser.parse(
        readFixture('http/play.json'),
        siteKey: 'k',
      );
      expect(result.playUrl, contains('sample.m3u8'));
      expect(result.header?['Referer'], 'http://127.0.0.1:18080/');
      expect(result.parse, 0);
    });

    test('播放入口返回纯文本 URL 也可解析', () {
      final result = HttpApiResponseParser.parse(
        'https://example.invalid/a.m3u8\n',
        siteKey: 'k',
      );
      expect(result.playUrl, 'https://example.invalid/a.m3u8');
    });

    test('code/data 信封解包，数组 data 包装为 list（§9.4）', () {
      final wrapped = HttpApiResponseParser.parse(
        jsonEncode({
          'code': 0,
          'data': {'list': [{'vod_id': '1', 'vod_name': 'A'}]},
        }),
        siteKey: 'k',
      );
      expect(wrapped.list.first.vodId, '1');

      final array = HttpApiResponseParser.parse(
        jsonEncode({
          'code': 0,
          'data': [
            {'vod_id': '2', 'vod_name': 'B'},
          ],
        }),
        siteKey: 'k',
      );
      expect(array.list.first.vodName, 'B');
    });

    test('非 0 code 映射为业务错误', () {
      final error = _captureError(
        () => HttpApiResponseParser.parse(
          jsonEncode({'code': 1, 'msg': '站点维护中'}),
          siteKey: 'k',
        ),
      );
      expect(error.kind, AppErrorKind.siteBusiness);
      expect(error.message, '站点维护中');
    });

    test('业务错误 msg 不转换为空列表（§7.4.3）', () {
      final error = _captureError(
        () => HttpApiResponseParser.parse(
          readFixture('http/result-msg.json'),
          siteKey: 'k',
        ),
      );
      expect(error.kind, AppErrorKind.siteBusiness);
      expect(error.message, contains('维护中'));
    });

    test('HTML 错误页识别为 siteParse，不当作 JSON 成功（§7.4.3、§8.4）', () {
      final error = _captureError(
        () => HttpApiResponseParser.parse(
          readFixture('http/error-html.html'),
          siteKey: 'k',
        ),
      );
      expect(error.kind, AppErrorKind.siteParse);
      expect(error.detail, contains('502 Bad Gateway'));
    });

    test('空响应与无法识别文本报 siteParse', () {
      expect(
        _captureError(() => HttpApiResponseParser.parse('   ', siteKey: 'k')).kind,
        AppErrorKind.siteParse,
      );
      expect(
        _captureError(
          () => HttpApiResponseParser.parse('not json at all', siteKey: 'k'),
        ).kind,
        AppErrorKind.siteParse,
      );
    });

    test('列表条目缺少 vod_id/vod_name 报 siteParse', () {
      final error = _captureError(
        () => HttpApiResponseParser.parse(
          jsonEncode({'list': [{'foo': 'bar'}]}),
          siteKey: 'k',
        ),
      );
      expect(error.kind, AppErrorKind.siteParse);
    });
  });

  group('多线路与多剧集（§8.4）', () {
    test('vod_play_from/vod_play_url 解析为多线路多剧集', () {
      final result = HttpApiResponseParser.parse(
        readFixture('http/result-multi-flag.json'),
        siteKey: 'k',
      );
      final vod = result.list.first;
      final lines = parsePlayLines(vod.vodPlayFrom, vod.vodPlayUrl);
      expect(lines.length, 3);
      expect(lines[0].flag, '主线');
      expect(lines[0].episodes.length, 2);
      expect(lines[1].flag, '备用线');
      expect(lines[2].flag, '线路三');
      expect(lines[0].episodes.first.name, '第1集');
      expect(lines[0].episodes.first.url, contains('sample.m3u8'));
    });

    test('多剧集单线路解析', () {
      final result = HttpApiResponseParser.parse(
        readFixture('http/result-multi-episode.json'),
        siteKey: 'k',
      );
      final lines = parsePlayLines(
        result.list.first.vodPlayFrom,
        result.list.first.vodPlayUrl,
      );
      expect(lines.length, 1);
      expect(lines.first.episodes.length, 3);
      expect(lines.first.episodes[2].name, '第3集');
    });

    test('线路名缺失时补默认名，空地址返回空列表', () {
      final lines = parsePlayLines(null, r'http://a/b.m3u8');
      expect(lines.length, 1);
      expect(lines.first.flag, '线路1');
      expect(lines.first.episodes.first.url, 'http://a/b.m3u8');
      expect(parsePlayLines(null, null), isEmpty);
      expect(parsePlayLines(null, ''), isEmpty);
    });

    test('地址中含 \$ 时按第一个 \$ 切分，不截断 URL', () {
      final lines = parsePlayLines(
        'line',
        r'第1集$http://a/b.m3u8?token=x$y',
      );
      expect(lines.first.episodes.first.name, '第1集');
      expect(lines.first.episodes.first.url, r'http://a/b.m3u8?token=x$y');
    });
  });

  group('播放决策（§7.4.8）', () {
    Site site({Map<String, Object?> extra = const {}, HeaderMap? header}) => Site(
      key: 'k',
      name: 'n',
      type: 1,
      api: 'http://127.0.0.1:18080/api/type1/',
      extra: extra,
      header: header,
    );

    test('parse=1 或 jx=1 明确报需要解析器', () {
      for (final input in [
        PlaybackResolutionInput(site: site(), episodeTarget: 'http://a/b.m3u8', parse: 1),
        PlaybackResolutionInput(site: site(), episodeTarget: 'http://a/b.m3u8', jx: 1),
      ]) {
        final error = _captureError(() => PlaybackResolver.decide(input));
        expect(error.kind, AppErrorKind.playbackParserRequired);
      }
    });

    test('绝对媒体地址直接播放', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: site(),
          episodeTarget: 'https://example.invalid/movie.mp4',
        ),
      );
      expect(decision.action, PlaybackAction.direct);
      expect(decision.url, 'https://example.invalid/movie.mp4');
    });

    test('相对路径相对站点 api origin 解析', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: site(),
          episodeTarget: '/media/a.m3u8',
        ),
      );
      expect(decision.url, 'http://127.0.0.1:18080/media/a.m3u8');
    });

    test('playUrl 前缀形态拼接（目标不是直链时）', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: site(extra: {'playUrl': 'http://127.0.0.1:18080/proxy?url='}),
          episodeTarget: 'v-episode-1',
        ),
      );
      expect(decision.url, 'http://127.0.0.1:18080/proxy?url=v-episode-1');
    });

    test('剧集已是直链时优先直连，不套 playUrl 前缀', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: site(extra: {'playUrl': 'http://127.0.0.1:18080/proxy?url='}),
          episodeTarget: 'http://a/b.m3u8',
        ),
      );
      expect(decision.url, 'http://a/b.m3u8');
    });

    test('playUrl 模板形态替换 {id}', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: site(extra: {'playUrl': 'http://127.0.0.1:18080/p/{id}'}),
          episodeTarget: 'abc',
        ),
      );
      expect(decision.url, 'http://127.0.0.1:18080/p/abc');
    });

    test('非直链且无前缀时报需要解析器', () {
      final error = _captureError(
        () => PlaybackResolver.decide(
          PlaybackResolutionInput(site: site(), episodeTarget: 'magnet:?xt=1'),
        ),
      );
      expect(error.kind, AppErrorKind.playbackParserRequired);
    });

    test('空目标报 playbackUrlMissing', () {
      final error = _captureError(
        () => PlaybackResolver.decide(
          PlaybackResolutionInput(site: site(), episodeTarget: '  '),
        ),
      );
      expect(error.kind, AppErrorKind.playbackUrlMissing);
    });

    test('媒体 Header 优先级：全局匹配 → 站点 → 播放结果', () {
      final decision = PlaybackResolver.decide(
        PlaybackResolutionInput(
          site: site(header: HeaderMap({'Referer': 'site', 'X-Site': '1'})),
          episodeTarget: 'http://127.0.0.1:18080/media/a.m3u8',
          resultHeader: HeaderMap({'Referer': 'result'}),
          globalHeaders: [
            HeaderRule(
              host: '127.0.0.1',
              header: HeaderMap({'Referer': 'global', 'X-Global': 'g'}),
            ),
          ],
        ),
      );
      expect(decision.headers?['Referer'], 'result');
      expect(decision.headers?['X-Site'], '1');
      expect(decision.headers?['X-Global'], 'g');
    });

    test('HeaderMap 键名大小写不敏感但保留原始键名', () {
      final map = HeaderMap({'User-Agent': 'a'});
      expect(map['user-agent'], 'a');
      map.put('user-AGENT', 'b');
      expect(map['User-Agent'], 'b');
      expect(map.keys.length, 1);
    });

    test('全局 header 规则支持通配与子域匹配', () {
      expect(HeaderRule(host: '*', header: HeaderMap()).matches('any.host'), isTrue);
      expect(
        HeaderRule(host: '*.example.com', header: HeaderMap())
            .matches('cdn.example.com'),
        isTrue,
      );
      expect(
        HeaderRule(host: 'example.com', header: HeaderMap())
            .matches('cdn.example.com'),
        isTrue,
      );
      expect(
        HeaderRule(host: 'example.com', header: HeaderMap())
            .matches('notexample.com'),
        isFalse,
      );
    });

    test('media URL scheme 判定', () {
      expect(looksLikeMediaUrl('rtmp://a/b'), isTrue);
      expect(looksLikeMediaUrl('rtsp://a/b'), isTrue);
      expect(looksLikeMediaUrl('//cdn.example.com/a.m3u8'), isTrue);
      expect(looksLikeMediaUrl('magnet:?xt=1'), isFalse);
      expect(looksLikeMediaUrl(''), isFalse);
    });
  });

  group('日志与 URL 脱敏（§9.3.1、§11.3.1、§18.2）', () {
    test('URL 脱敏隐藏 query 与用户信息', () {
      expect(
        redactUrl('https://user:pass@example.com/a/b.m3u8?token=secret&sign=1'),
        'https://example.com/a/b.m3u8?...',
      );
      expect(redactUrl('http://127.0.0.1:18080/api/type1/'), contains('127.0.0.1:18080'));
      expect(redactUrl(''), '');
      expect(redactUrl(null), '');
      // 非法 URI 必须显式标记，不能把原文当成 URL 输出。
      expect(redactUrl('http://[::'), '<invalid-url>');
      // 相对路径不包含主机与 query，原样保留路径便于定位。
      expect(redactUrl('some/relative/path'), 'some/relative/path');
    });

    test('Header 日志脱敏识别敏感键（大小写不敏感）', () {
      final text = redactHeadersForLog({
        'Cookie': 'sid=1',
        'Authorization': 'Bearer x',
        'X-Signature': 'abc',
        'X-Api-Key': 'k',
        'Referer': 'http://127.0.0.1:18080/',
        'User-Agent': 'WebHTV-PC/0.1',
      });
      expect(text, contains('Cookie=<redacted>'));
      expect(text, contains('Authorization=<redacted>'));
      expect(text, contains('X-Signature=<redacted>'));
      expect(text, contains('X-Api-Key=<redacted>'));
      expect(text, contains('Referer=http://127.0.0.1:18080/'));
      expect(text.contains('sid=1'), isFalse);
      expect(text.contains('Bearer x'), isFalse);
    });

    test('HeaderMap 只暴露键名，不泄露值', () {
      final map = HeaderMap({'Cookie': 'secret', 'X-A': '1'});
      expect(map.keyNames, ['Cookie', 'X-A']);
      expect(map.toString(), contains('keys='));
      expect(map.toString().contains('secret'), isFalse);
    });
  });

  group('文本解码（§7.4.1）', () {
    test('BOM 去除与 charset 识别', () {
      final bom = <int>[0xEF, 0xBB, 0xBF, 0x7B, 0x7D];
      final stripped = stripBom(bom);
      expect(stripped.charset, 'utf-8');
      expect(utf8.decode(stripped.bytes), '{}');

      expect(stripBom([0xFF, 0xFE, 0x41, 0x00]).charset, 'utf-16le');
      expect(stripBom([0xFE, 0xFF, 0x00, 0x41]).charset, 'utf-16be');
      expect(stripBom([0x41]).charset, isNull);
    });

    test('Content-Type charset 解析', () {
      expect(
        charsetFromContentType('application/json; charset=GB18030'),
        'gb18030',
      );
      expect(charsetFromContentType('application/json'), isNull);
      expect(charsetFromContentType(null), isNull);
    });

    test('UTF-8 与 GBK 解码', () {
      expect(decodeConfigText(utf8.encode('{"a":"中文"}')), '{"a":"中文"}');
      // GBK 字节序列（“中文”）在未声明 charset 时按 GBK 兜底解码。
      final gbkBytes = <int>[0xD6, 0xD0, 0xCE, 0xC4];
      expect(decodeConfigText(gbkBytes), '中文');
      expect(
        decodeConfigText(gbkBytes, declaredCharset: 'gb18030'),
        '中文',
      );
    });

    test('不支持的 charset 报 configDecode', () {
      final error = _captureError(
        () => decodeConfigText(utf8.encode('{}'), declaredCharset: 'koi8-r'),
      );
      expect(error.kind, AppErrorKind.configDecode);
    });

    test('空内容报 configInvalid', () {
      expect(
        _captureError(() => decodeConfigText(const [])).kind,
        AppErrorKind.configInvalid,
      );
    });

    test('gzip 传输解压', () {
      final original = utf8.encode('{"sites":[]}');
      final compressed = gzip.encode(original);
      final decoded = decodeTransportBody(compressed, contentEncoding: 'gzip');
      expect(decoded.encoding, 'gzip');
      expect(utf8.decode(decoded.bytes), '{"sites":[]}');
    });

    test('identity 与未知编码不被当作解压', () {
      final decoded = decodeTransportBody(utf8.encode('{}'));
      expect(decoded.encoding, 'identity');
      expect(utf8.decode(decoded.bytes), '{}');
      // 声称 gzip 但内容不是 gzip 时按原样返回，不抛错（HttpClient 可能已解压）。
      final assumed = decodeTransportBody(utf8.encode('{}'), contentEncoding: 'gzip');
      expect(assumed.encoding, startsWith('identity(assumed:'));
    });
  });

  group('存储（§15、§16.3）', () {
    late AppDatabase database;

    setUp(() => database = AppDatabase.inMemory());
    tearDown(() => database.dispose());

    test('历史写入、查询、进度百分比与完成标记', () {
      database.upsertHistory(
        siteKey: 'k',
        vodId: 'v1',
        vodName: '影片',
        flag: 'line',
        episodeName: '第1集',
        episodeId: 'http://a/1.m3u8',
        positionMs: 30000,
        durationMs: 120000,
      );
      final items = database.recentHistory();
      expect(items.length, 1);
      expect(items.first.progressPercent, 25);
      expect(items.first.completed, isFalse);

      // 同一剧集重复写入应更新而不是新增（不产生重复记录）。
      database.upsertHistory(
        siteKey: 'k',
        vodId: 'v1',
        vodName: '影片',
        flag: 'line',
        episodeName: '第1集',
        episodeId: 'http://a/1.m3u8',
        positionMs: 120000,
        durationMs: 120000,
      );
      final updated = database.recentHistory();
      expect(updated.length, 1);
      expect(updated.first.completed, isTrue);
      expect(updated.first.progressPercent, 100);
    });

    test('历史搜索与删除', () {
      database.upsertHistory(
        siteKey: 'k',
        vodId: 'v1',
        vodName: '流浪地球',
        flag: 'line',
        episodeName: '第1集',
        episodeId: 'a',
        positionMs: 1,
        durationMs: 100,
      );
      database.upsertHistory(
        siteKey: 'k',
        vodId: 'v2',
        vodName: '其他影片',
        flag: 'line',
        episodeName: '第2集',
        episodeId: 'b',
        positionMs: 1,
        durationMs: 100,
      );
      expect(database.searchHistory('流浪').length, 1);
      expect(database.searchHistory('第2集').length, 1);
      final first = database.recentHistory().first;
      database.deleteHistory(first.id);
      expect(database.recentHistory().length, 1);
    });

    test('清空历史不删除配置（§15.3）', () {
      database.saveConfig(
        name: 'cfg',
        origin: 'http://x/a.json',
        json: {
          'sites': [
            {'key': 'k', 'name': 'n', 'type': 1, 'api': 'http://x/api/'},
          ],
        },
        siteCount: 1,
      );
      database.upsertHistory(
        siteKey: 'k',
        vodId: 'v1',
        vodName: '影片',
        flag: 'l',
        episodeName: 'e',
        episodeId: 'a',
        positionMs: 1,
        durationMs: 10,
      );
      database.clearHistory();
      expect(database.count('history'), 0);
      expect(database.count('configs'), 1);
    });

    test('配置保存覆盖同一 origin 并保持单一 active', () {
      final first = database.saveConfig(
        name: 'cfg',
        origin: 'http://x/a.json',
        json: {
          'sites': [
            {'key': 'k', 'name': 'n', 'type': 1, 'api': 'http://x/api/'},
          ],
        },
        siteCount: 1,
      );
      final second = database.saveConfig(
        name: 'cfg2',
        origin: 'http://x/b.json',
        json: {
          'sites': [
            {'key': 'k2', 'name': 'n2', 'type': 1, 'api': 'http://x/api/'},
          ],
        },
        siteCount: 1,
      );
      expect(first, isNot(second));
      expect(database.listConfigs().length, 2);
      expect(database.listConfigs().where((r) => r.isActive).length, 1);
      expect(database.activeConfig()?.name, 'cfg2');

      // 相同 origin 再次导入：覆盖而不是新增版本。
      database.saveConfig(
        name: 'cfg2-updated',
        origin: 'http://x/b.json',
        json: {
          'sites': [
            {'key': 'k3', 'name': 'n3', 'type': 1, 'api': 'http://x/api/'},
          ],
        },
        siteCount: 1,
      );
      expect(database.listConfigs().length, 2);
      expect(database.activeConfig()?.name, 'cfg2-updated');
    });

    test('配置记录可恢复为 AppConfig（未知字段保留）', () {
      database.saveConfig(
        name: 'cfg',
        origin: 'http://x/a.json',
        json: {
          'name': 'cfg',
          'sites': [
            {
              'key': 'k',
              'name': 'n',
              'type': 1,
              'api': 'http://x/api/',
              'futureField': 'keep-me',
            },
          ],
          'futureTopLevel': {'a': 1},
          'headers': [
            {
              'host': 'x',
              'header': {'X-A': '1'},
            },
          ],
        },
        siteCount: 1,
      );
      final record = database.activeConfig()!;
      final config = record.config!;
      expect(config.sites.first.extra['futureField'], 'keep-me');
      expect(config.extra['futureTopLevel'], {'a': 1});
      expect(config.headers.first.header['X-A'], '1');
    });

    test('敏感 Header 不明文入库（§16.3）', () {
      final id = database.saveConfig(
        name: 'cfg',
        origin: 'http://x/a.json',
        json: const {'sites': <Object?>[]},
      );
      database.saveConfigSites(id, [
        Site(
          key: 'k',
          name: 'n',
          type: 1,
          api: 'http://x/api/',
          header: HeaderMap({'Cookie': 'secret-value', 'X-A': '1'}),
        ),
      ]);
      final row = database.configSites(id).first;
      final keyNames = row['header_key_names'] as String;
      expect(keyNames, contains('Cookie'));
      expect(keyNames.contains('secret-value'), isFalse);
    });

    test('站点健康统计与搜索缓存 TTL', () {
      database.recordHealth(
        siteKey: 'k',
        action: HealthAction.home,
        success: true,
        latencyMs: 12,
      );
      database.recordHealth(
        siteKey: 'k',
        action: HealthAction.home,
        success: false,
        latencyMs: 30,
        error: 'timeout',
      );
      final health = database.siteHealth().first;
      expect(health.homeTotal, 2);
      expect(health.homeOk, 1);
      expect(SiteHealth.rate(health.homeOk, health.homeTotal), 0.5);
      expect(SiteHealth.rate(0, 0), isNull);
      expect(health.lastError, 'timeout');

      database.cacheSearch(
        keyword: 'w',
        siteKey: 'k',
        payload: {'list': []},
      );
      expect(database.readSearchCache(keyword: 'w', siteKey: 'k'), isNotNull);
      expect(
        database.readSearchCache(
          keyword: 'w',
          siteKey: 'k',
          ttl: Duration.zero,
        ),
        isNull,
      );
    });

    test('收藏增删查', () {
      database.upsertFavorite(
        kind: 'vod',
        siteKey: 'k',
        targetId: 'v1',
        title: '影片',
      );
      expect(
        database.isFavorite(kind: 'vod', siteKey: 'k', targetId: 'v1'),
        isTrue,
      );
      database.upsertFavorite(
        kind: 'vod',
        siteKey: 'k',
        targetId: 'v1',
        title: '影片改名',
      );
      expect(database.listFavorites().length, 1);
      expect(database.listFavorites().first.title, '影片改名');
      database.removeFavorite(kind: 'vod', siteKey: 'k', targetId: 'v1');
      expect(database.listFavorites(), isEmpty);
    });

    test('数据库打开失败返回错误而不抛出（§16.3）', () {
      final result = AppDatabase.open('::invalid::path::/x.sqlite3');
      expect(result.succeeded, isFalse);
      expect(result.error, isNotNull);
    });
  });

  group('错误模型（§9.5 错误码、§10.4 播放错误）', () {
    test('错误分类文案可定位且可重试标记正确', () {
      final error = AppError(
        AppErrorKind.siteTimeout,
        '超时',
        detail: 'site=k',
        retryable: true,
      );
      expect(error.userMessage, contains('超时'));
      expect(error.userMessage, contains('site=k'));
      expect(error.retryable, isTrue);
      expect(error.logLine, contains('siteTimeout'));

      final cancel = AppError(AppErrorKind.siteCancelled, '取消');
      expect(cancel.isCancellation, isTrue);
      expect(describeErrorKind(AppErrorKind.siteUnsupported), contains('未支持'));
    });
  });
}

/// 捕获 [AppError]，非 [AppError] 直接失败。
AppError _captureError(void Function() action) {
  try {
    action();
  } on AppError catch (error) {
    return error;
  } catch (error) {
    fail('期望 AppError，实际抛出 ${error.runtimeType}: $error');
  }
  fail('期望抛出 AppError，但没有抛出');
}
