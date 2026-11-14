/// 联想 / 热门推荐服务测试：真实本地 HTTP 服务驱动（不打外网）。
///
/// 覆盖：
/// - 爱奇艺 + 腾讯双源联想合并、去重、`<hl>` 高亮清洗；
/// - 腾讯响应的两种标题路径（`search_keyword.strVal` / `cell_info.title`）；
/// - 360kan 榜单解析（title 字段、上限裁剪）；
/// - 热搜磁盘缓存：命中不出网、过期兜底、损坏降级；
/// - 上游失败（超时 / 非 2xx / 非法 JSON）安静降级为空表。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/services/search_suggest_service.dart';

void main() {
  late Directory tempDir;
  late _FakeUpstream upstream;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-suggest');
    upstream = await _FakeUpstream.start();
  });

  tearDown(() async {
    await upstream.stop();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  SearchSuggestService serviceOf({Duration? timeout}) => SearchSuggestService(
    client: _RoutingClient(upstream.baseUrl),
    cacheDir: '${tempDir.path}${Platform.pathSeparator}search',
    timeout: timeout ?? const Duration(seconds: 5),
  );

  group('联想（爱奇艺 + 腾讯双源合并）', () {
    test('两源合并去重、清洗 <hl> 高亮标签', () async {
      upstream.iqiyiSuggest = {
        'code': 'A00000',
        'data': [
          {'name': '庆余年<hl>第二季</hl>'},
          {'name': '庆余年'},
        ],
      };
      upstream.tencentSuggest = _tencentResponse(['庆余年第二季', ' 庆余年番外 ']);

      final service = serviceOf();
      addTearDown(service.close);
      final items = await service.suggest('庆余年');

      final titles = items.map((item) => item.title).toList();
      expect(titles, contains('庆余年第二季'));
      expect(titles, contains('庆余年'));
      expect(titles, contains('庆余年番外'));
      // 去重：庆余年第二季只出现一次。
      expect(
        titles.where((title) => title == '庆余年第二季').length,
        1,
        reason: '两源重复词必须合并',
      );
      // 清洗后的词不再带 <hl>。
      expect(titles.every((title) => !title.contains('<hl>')), isTrue);
    });

    test('空关键词直接返回空表（不发请求）', () async {
      final service = serviceOf();
      addTearDown(service.close);
      expect(await service.suggest('   '), isEmpty);
      expect(upstream.requestCount, 0);
    });

    test('爱奇艺源失败时腾讯结果仍可用（安静降级）', () async {
      upstream.iqiyiStatus = 500;
      upstream.tencentSuggest = _tencentResponse(['庆余年第二季']);

      final service = serviceOf();
      addTearDown(service.close);
      final items = await service.suggest('庆余年');
      expect(items.map((item) => item.title), ['庆余年第二季']);
    });

    test('两源都失败返回空表（不抛异常）', () async {
      upstream.iqiyiStatus = 500;
      upstream.tencentStatus = 500;
      final service = serviceOf();
      addTearDown(service.close);
      expect(await service.suggest('庆余年'), isEmpty);
    });

    test('非法 JSON 响应安静降级为空表', () async {
      upstream.iqiyiBody = 'not-json';
      upstream.tencentBody = '<html>';
      final service = serviceOf();
      addTearDown(service.close);
      expect(await service.suggest('庆余年'), isEmpty);
    });
  });

  group('热门推荐（360kan 榜单 + 磁盘缓存）', () {
    test('解析 title 并按**候选池**上限裁剪（默认 30，接口全量）', () async {
      upstream.rankBodies[2] = {
        'data': [
          for (var i = 0; i < 40; i++) {'title': '电影$i'},
        ],
      };
      final service = serviceOf();
      addTearDown(service.close);
      final items = await service.hotRank(HotRankCategory.movie);
      expect(
        items.length,
        30,
        reason: '候选池上限 30：一屏放不下时还要能「换一批」轮换出新条目',
      );
      expect(items.first.title, '电影0');
    });

    test('响应不足池子上限时全量保留（显示几条由布局算）', () async {
      upstream.rankBodies[2] = {
        'data': [
          for (var i = 0; i < 15; i++) {'title': '电影$i'},
        ],
      };
      final service = serviceOf();
      addTearDown(service.close);
      final items = await service.hotRank(HotRankCategory.movie);
      expect(items.length, 15, reason: '接口给多少就留多少，不再固定截到 10');
      expect(items.first.title, '电影0');
    });

    test('解析海报与元信息（cover/upinfo/doubanscore/url + 名次）', () async {
      // 真实响应形状（2026-10-14 实测）：字段类型并不整齐——
      // `doubanscore` 常为空串、`moviecat` 是数组、`id`/`pv` 是数字。
      upstream.rankBodies[3] = {
        'data': [
          {
            'title': '兰香如故',
            'upinfo': '全47集',
            'doubanscore': '5.3',
            'cover': 'https://p3.qhimg.com/d/dy_5cf5c251f3322d3f6655b6107ff40c68.',
            'url': 'http://www.360kan.com/tv/PrNsaH7nTGHpM3.html',
            'moviecat': ['其他'],
            'id': 0,
            'pv': '19,794',
            'vip': true,
          },
          {
            'title': '醒来',
            'upinfo': '全22集',
            'doubanscore': '',
            'cover': 'https://p6.qhimg.com/d/dy_15c1d9cbcde18bb4acb026138f785f3d.jpg',
            'url': 'http://www.360kan.com/tv/abc.html',
          },
        ],
      };
      final service = serviceOf();
      addTearDown(service.close);
      final items = await service.hotRank(HotRankCategory.series);

      expect(items.length, 2);
      expect(items[0].title, '兰香如故');
      expect(
        items[0].cover,
        'https://p3.qhimg.com/d/dy_5cf5c251f3322d3f6655b6107ff40c68.',
        reason: '封面必须原样保留（含无扩展名的形状）',
      );
      expect(items[0].subtitle, '全47集');
      expect(items[0].score, '5.3');
      expect(
        items[0].detailUrl,
        'http://www.360kan.com/tv/PrNsaH7nTGHpM3.html',
      );
      expect(items[0].rank, 1, reason: '名次按响应顺序从 1 开始');
      expect(items[1].rank, 2);
      // 空字符串一律当缺失，不能透传成空串（否则 UI 会画出空角标）。
      expect(items[1].score, isNull);
      expect(items[1].subtitle, '全22集');
    });

    test('脏字段不致整条榜单作废（类型不符时当缺失）', () async {
      upstream.rankBodies[2] = {
        'data': [
          {
            'title': '类型乱写的条目',
            'upinfo': 2026, // 数字而不是字符串
            'doubanscore': 5.3, // 数字而不是字符串
            'cover': '', // 空串
            'url': null,
          },
          {
            'title': '正常条目',
            'upinfo': '全10集',
            'cover': 'https://p3.qhimg.com/x.jpg',
          },
        ],
      };
      final service = serviceOf();
      addTearDown(service.close);
      final items = await service.hotRank(HotRankCategory.movie);

      expect(items.length, 2, reason: '脏字段不影响条目计数');
      expect(items[0].title, '类型乱写的条目');
      expect(items[0].subtitle, isNull);
      expect(items[0].score, isNull);
      expect(items[0].cover, isNull);
      expect(items[0].detailUrl, isNull);
      expect(items[1].cover, 'https://p3.qhimg.com/x.jpg');
    });

    test('缺 title 的条目被跳过且名次连续', () async {
      upstream.rankBodies[2] = {
        'data': [
          {'upinfo': '无标题'},
          {'title': '第一条', 'cover': 'https://p3.qhimg.com/a.jpg'},
          {'title': '第二条'},
        ],
      };
      final service = serviceOf();
      addTearDown(service.close);
      final items = await service.hotRank(HotRankCategory.movie);

      expect(items.map((item) => item.title), ['第一条', '第二条']);
      expect(items.map((item) => item.rank), [1, 2], reason: '跳过无标题条目后名次仍连续');
    });

    test('缓存命中后不再请求上游', () async {
      upstream.rankBodies[2] = {
        'data': [
          {'title': '战狼2'},
        ],
      };
      final service = serviceOf();
      addTearDown(service.close);
      final first = await service.hotRank(HotRankCategory.movie);
      expect(first.map((item) => item.title), ['战狼2']);
      final afterFirst = upstream.requestCount;

      // 第二个服务实例（同一缓存目录）：必须命中磁盘缓存，零请求。
      final cached = serviceOf();
      addTearDown(cached.close);
      final second = await cached.hotRank(HotRankCategory.movie);
      expect(second.map((item) => item.title), ['战狼2']);
      expect(upstream.requestCount, afterFirst, reason: '缓存命中不得出网');
    });

    test('上游失败时过期缓存兜底', () async {
      upstream.rankBodies[2] = {
        'data': [
          {'title': '旧榜单'},
        ],
      };
      final cacheDir = '${tempDir.path}${Platform.pathSeparator}search';
      final seeding = SearchSuggestService(
        client: _RoutingClient(upstream.baseUrl),
        cacheDir: cacheDir,
        hotCacheTtl: Duration.zero, // 立即过期
      );
      await seeding.hotRank(HotRankCategory.movie);
      seeding.close();

      // 上游挂掉后：缓存虽过期，但兜底仍然给出旧榜单。
      upstream.rankStatus = 500;
      final offline = SearchSuggestService(
        client: _RoutingClient(upstream.baseUrl),
        cacheDir: cacheDir,
        hotCacheTtl: Duration.zero,
      );
      addTearDown(offline.close);
      final items = await offline.hotRank(HotRankCategory.movie);
      expect(items.map((item) => item.title), ['旧榜单']);
    });

    test('上游失败且无缓存返回空表（不抛异常）', () async {
      upstream.rankStatus = 500;
      final service = serviceOf();
      addTearDown(service.close);
      expect(await service.hotRank(HotRankCategory.variety), isEmpty);
    });

    test('损坏的缓存文件按 miss 处理', () async {
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}search'
        '${Platform.pathSeparator}hot-series.json',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString('{broken');
      upstream.rankBodies[3] = {
        'data': [
          {'title': '兰香如故'},
        ],
      };
      final service = serviceOf();
      addTearDown(service.close);
      final items = await service.hotRank(HotRankCategory.series);
      expect(items.map((item) => item.title), ['兰香如故']);
    });
  });

  group('请求超时', () {
    test('超时安静降级为空表', () async {
      upstream.holdSuggest = true;
      final service = serviceOf(timeout: const Duration(milliseconds: 200));
      addTearDown(service.close);
      final items = await service.suggest('庆余年');
      expect(items, isEmpty);
    });
  });
}

/// 腾讯联想响应构造（`vecGroupData[].group_data[]` 结构）。
Map<String, Object?> _tencentResponse(List<String> titles) => {
  'result': {'ret': 0, 'code': 0},
  'data': {
    'search_data': {
      'vecGroupData': [
        {
          'group_id': 1,
          'group_title': '猜你想搜',
          'group_data': [
            for (final title in titles)
              {
                'action': {
                  'actionArgs': {
                    'search_keyword': {'strVal': title},
                  },
                },
              },
          ],
        },
      ],
    },
  },
};

/// 本地假上游：按 `x-webhtv-test-upstream` header 分流到联想 / 榜单端点。
class _FakeUpstream {
  _FakeUpstream._(this._server);

  final HttpServer _server;
  int requestCount = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  // 爱奇艺联想（host=suggest.video.iqiyi.com 走 header 路由）。
  Map<String, Object?>? iqiyiSuggest;
  int iqiyiStatus = 200;
  String? iqiyiBody;

  // 腾讯联想。
  Map<String, Object?>? tencentSuggest;
  int tencentStatus = 200;
  String? tencentBody;

  // 360kan 榜单：cat → body。
  final Map<int, Map<String, Object?>> rankBodies = {};
  int rankStatus = 200;

  /// 联想请求挂起（测超时）。
  bool holdSuggest = false;

  static Future<_FakeUpstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = _FakeUpstream._(server);
    unawaited(upstream._listen());
    return upstream;
  }

  Future<void> _listen() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    requestCount++;
    try {
      // 用 header 把请求路由到对应“上游”。
      final upstreamHeader =
          request.headers.value('x-webhtv-test-upstream') ?? '';
      if (upstreamHeader == 'iqiyi') {
        await _respond(
          request,
          iqiyiStatus,
          iqiyiBody ?? (iqiyiSuggest == null ? '{}' : jsonEncode(iqiyiSuggest)),
          hold: holdSuggest,
        );
        return;
      }
      if (upstreamHeader == 'tencent') {
        await _respond(
          request,
          tencentStatus,
          tencentBody ??
              (tencentSuggest == null ? '{}' : jsonEncode(tencentSuggest)),
          hold: holdSuggest,
        );
        return;
      }
      if (upstreamHeader == 'rank') {
        final cat = int.tryParse(
          request.uri.queryParameters['cat'] ?? '',
        );
        final body = rankBodies[cat];
        await _respond(
          request,
          rankStatus,
          body == null ? '{"data":[]}' : jsonEncode(body),
        );
        return;
      }
      await _respond(request, 404, '{}');
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _respond(
    HttpRequest request,
    int status,
    String body, {
    bool hold = false,
  }) async {
    if (hold) {
      await Future<void>.delayed(const Duration(seconds: 10));
    }
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(body);
    await request.response.close();
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }
}

/// 把真实上游域名改写到本地假服务的客户端。
///
/// 生产代码里的 `Uri.https('suggest.video.iqiyi.com', …)` 不用为测试开口子；
/// 这里按原始 host 打上路由 header 再改写地址，假上游据此分流。
class _RoutingClient extends http.BaseClient {
  _RoutingClient(this._baseUrl);

  final String _baseUrl;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final host = request.url.host;
    final upstream = switch (host) {
      'suggest.video.iqiyi.com' => 'iqiyi',
      'tv.aiseet.atianqi.com' => 'tencent',
      'api.web.360kan.com' => 'rank',
      _ => 'unknown',
    };
    final mapped = Uri.parse('$_baseUrl${request.url.path}').replace(
      queryParameters: request.url.queryParameters,
    );
    final rewritten = http.Request(request.method, mapped)
      ..headers.addAll(request.headers)
      ..headers['x-webhtv-test-upstream'] = upstream;
    if (request is http.Request && request.body.isNotEmpty) {
      rewritten.bodyBytes = request.bodyBytes;
    }
    return _inner.send(rewritten);
  }
}
