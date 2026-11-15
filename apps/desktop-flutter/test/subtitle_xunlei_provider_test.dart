/// 迅雷源适配器契约测试（计划 `docs/superpowers/plans/2026-11-15-subtitle-online-search.md` Task 3）。
///
/// 只覆盖这一层的两条职责：`search()` 的请求门禁与逐字段归一、`resolve()` 的
/// 单跳落盘；聚合/排序/超时属于 `registry.dart`，不在这里断言。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/subtitle_provider.dart';
import 'package:webhtv_pc/core/subtitle_settings.dart';
import 'package:webhtv_pc/services/subtitle_asset_store.dart';
import 'package:webhtv_pc/services/subtitle_providers/xunlei_provider.dart';

SubtitleQuery queryOf(String title) => SubtitleQuery(
  title: title,
  siteKey: 'site',
  vodId: 'vod-1',
  episodeName: '第1集',
);

SubtitleSettings enabled() => SubtitleSettings(xunleiEnabled: true);

http.Response jsonResponse(Object? body, {int status = 200}) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// 一条最小的合法条目；各用例按需覆盖单个字段。
Map<String, Object?> itemOf({String url = 'https://cdn.test/a.srt'}) => {
  'url': url,
  'name': '某剧.S01E01.srt',
  'ext': 'srt',
  'languages': ['简体中文'],
};

void main() {
  final requests = <http.Request>[];

  setUp(requests.clear);

  XunleiSubtitleProvider providerWith(
    http.Response Function(http.Request request) respond, {
    String cacheDir = '',
  }) => XunleiSubtitleProvider(
    client: MockClient((request) async {
      requests.add(request);
      return respond(request);
    }),
    cacheDir: cacheDir,
  );

  test('未启用返回 null；启用后 id/name/priority 符合契约', () {
    expect(buildXunleiProvider(settings: SubtitleSettings()), isNull);
    final provider = buildXunleiProvider(settings: enabled());
    expect(provider, isNotNull);
    expect(provider!.id, 'xunlei');
    expect(provider.name, '迅雷字幕');
    expect(provider.priority, 20);
    // 迅雷按片名搜索，不依赖本地文件（只有射手依赖）。
    expect(provider.needsLocalMediaPath, isFalse);
  });

  test('正常响应：两条候选逐字段映射，缺 url 的条目丢弃', () async {
    final provider = providerWith(
      (_) => jsonResponse({
        'code': 0,
        'result': 'ok',
        'data': [
          {
            'url': 'https://cdn.test/a.ass',
            'cid': 'cid-1',
            'gcid': 'gcid-1',
            'name': '某剧 S01E01.ass',
            'ext': 'ASS',
            'languages': ['简体中文'],
            'score': 0.2,
            'fingerprintf_score': 0.9,
          },
          {
            'url': 'https://cdn.test/b.srt',
            'gcid': 'gcid-2',
            'name': '',
            'languages': ['English'],
            'score': 1,
          },
          {'name': '没有下载地址的条目', 'ext': 'srt'},
        ],
      }),
    );

    final results = await provider.search(queryOf('某剧 第二季'), enabled());

    expect(results, hasLength(2));
    final first = results[0];
    expect(first.providerId, 'xunlei');
    expect(first.assetId, 'cid-1');
    expect(first.title, '某剧 S01E01.ass');
    expect(first.language, '简体中文');
    expect(first.format, 'ass');
    expect(first.url, 'https://cdn.test/a.ass');
    expect(first.score, 0.9);
    expect(first.season, isNull);
    expect(first.episode, isNull);
    expect(first.requiresResolve, isTrue);
    expect(first.payload, {
      'url': 'https://cdn.test/a.ass',
      'name': '某剧 S01E01.ass',
      'format': 'ass',
    });

    // 第二条：cid 缺失回退 gcid；name 空则用 id；ext 缺失回退 URL 扩展名。
    final second = results[1];
    expect(second.assetId, 'gcid-2');
    expect(second.title, 'gcid-2');
    expect(second.language, 'English');
    expect(second.format, 'srt');
    expect(second.score, 1.0);
    expect(second.payload['format'], 'srt');

    expect(requests, hasLength(1));
    expect(requests.single.url.host, 'api-shoulei-ssl.xunlei.com');
    expect(requests.single.url.path, '/oracle/subtitle');
    expect(requests.single.headers['Referer'], 'https://sl-m-ssl.xunlei.com/');
    expect(requests.single.headers['User-Agent'], contains('Chrome/124'));
  });

  test('code 不为 0（含字段缺失）→ 空结果', () async {
    for (final body in <Object?>[
      {'code': 1, 'result': 'ok', 'data': [itemOf()]},
      {'result': 'ok', 'data': [itemOf()]},
    ]) {
      final provider = providerWith((_) => jsonResponse(body));
      expect(await provider.search(queryOf('某剧'), enabled()), isEmpty);
    }
  });

  test('result 存在且不是 ok → 空结果；缺失则照常解析', () async {
    final rejected = providerWith(
      (_) => jsonResponse({'code': 0, 'result': 'failed', 'data': [itemOf()]}),
    );
    expect(await rejected.search(queryOf('某剧'), enabled()), isEmpty);

    final accepted = providerWith(
      (_) => jsonResponse({'code': 0, 'data': [itemOf()]}),
    );
    expect(await accepted.search(queryOf('某剧'), enabled()), hasLength(1));
  });

  test('非 2xx → 空结果且不外抛', () async {
    for (final status in [301, 404, 500]) {
      final provider = providerWith(
        (_) => jsonResponse({
          'code': 0,
          'result': 'ok',
          'data': [itemOf()],
        }, status: status),
      );
      expect(await provider.search(queryOf('某剧'), enabled()), isEmpty);
    }
  });

  test('响应不是 JSON 或请求失败 → 空结果且不外抛', () async {
    final broken = providerWith(
      (_) => http.Response.bytes(utf8.encode('<html>502</html>'), 200),
    );
    expect(await broken.search(queryOf('某剧'), enabled()), isEmpty);

    final failing = XunleiSubtitleProvider(
      client: MockClient((request) async {
        requests.add(request);
        throw http.ClientException('boom', request.url);
      }),
    );
    expect(await failing.search(queryOf('某剧'), enabled()), isEmpty);
  });

  test('空关键词：零请求、空结果', () async {
    final provider = providerWith(
      (_) => jsonResponse({'code': 0, 'data': [itemOf()]}),
    );
    expect(await provider.search(queryOf('   '), enabled()), isEmpty);
    expect(requests, isEmpty);
  });

  test('关键词按 urllib quote 编码：空格是 %20，不是 +', () async {
    final provider = providerWith((_) => jsonResponse({'code': 0, 'data': const []}));
    await provider.search(queryOf('某剧 第二季'), enabled());

    final query = requests.single.url.query;
    expect(
      query,
      'name=%E6%9F%90%E5%89%A7%20%E7%AC%AC%E4%BA%8C%E5%AD%A3',
    );
    expect(query, isNot(contains('+')));
    expect(requests.single.url.queryParameters['name'], '某剧 第二季');
  });

  test('语言归一（表驱动，逐字照抄参考实现）', () async {
    final cases = <List<Object?>>[
      [null, 'zh'],
      [<String>[], 'zh'],
      [[''], 'zh'],
      [['默认'], 'zh'],
      [['Default'], 'zh'],
      [['简体中文'], '简体中文'],
      [['English'], 'English'],
      // 'en' 是纯子串匹配，Bengali 命中后原样返回——参考实现行为，照抄。
      [['Bengali'], 'Bengali'],
      [['', 'English'], 'English'],
      // languages 不是数组时等价于空。
      ['简体中文', 'zh'],
    ];
    for (final testCase in cases) {
      final languages = testCase[0];
      final expected = testCase[1] as String;
      final provider = providerWith(
        (_) => jsonResponse({
          'code': 0,
          'data': [
            {'url': 'https://cdn.test/x.srt', 'name': 'x.srt', 'languages': languages},
          ],
        }),
      );
      final results = await provider.search(queryOf('某剧'), enabled());
      expect(
        results.single.language,
        expected,
        reason: 'languages=$languages',
      );
    }
  });

  group('resolve', () {
    late Directory temp;
    const subtitleText = '1\n00:00:01,000 --> 00:00:02,000\n你好\n';

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('xunlei_sub_');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('单跳落盘：format 来自 ext，下载请求同样带 UA/Referer', () async {
      final provider = providerWith(
        (request) {
          if (request.url.path == '/oracle/subtitle') {
            return jsonResponse({
              'code': 0,
              'data': [
                {
                  // URL 上没有可识别后缀，落盘格式只能来自 ext。
                  'url': 'https://cdn.test/download/9527',
                  'cid': 'cid-9',
                  'name': '某剧 第1集',
                  'ext': 'ass',
                  'languages': ['简体中文'],
                },
              ],
            });
          }
          return http.Response.bytes(utf8.encode(subtitleText), 200);
        },
        cacheDir: '${temp.path}/subtitles',
      );

      final candidate = (await provider.search(queryOf('某剧'), enabled())).single;
      expect(candidate.format, 'ass');

      final asset = await provider.resolve(candidate, queryOf('某剧'), enabled());

      expect(asset, isNotNull);
      expect(asset!.format, 'ass');
      expect(asset.path, endsWith('.ass'));
      expect(asset.fileName, endsWith('.ass'));
      expect(await File(asset.path).readAsString(), subtitleText);

      expect(requests, hasLength(2));
      expect(requests.last.url.toString(), 'https://cdn.test/download/9527');
      expect(requests.last.headers['Referer'], 'https://sl-m-ssl.xunlei.com/');
      expect(requests.last.headers['User-Agent'], contains('Chrome/124'));
    });

    test('payload 缺 url → SubtitleResolveException(download_url_missing)', () async {
      final provider = providerWith(
        (_) => jsonResponse({'code': 0, 'data': const []}),
        cacheDir: '${temp.path}/subtitles',
      );
      const candidate = SubtitleCandidate(
        providerId: 'xunlei',
        assetId: 'cid-x',
        title: '某剧',
        language: 'zh',
        format: 'srt',
        url: '',
        requiresResolve: true,
        payload: {'format': 'srt'},
      );

      await expectLater(
        provider.resolve(candidate, queryOf('某剧'), enabled()),
        throwsA(
          isA<SubtitleResolveException>().having(
            (error) => error.code,
            'code',
            'download_url_missing',
          ),
        ),
      );
      expect(requests, isEmpty);
    });
  });
}
