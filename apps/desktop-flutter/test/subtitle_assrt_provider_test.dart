/// ASSRT 字幕源的行为契约（`docs/superpowers/plans/2026-11-15-subtitle-online-search.md` Task 2）。
///
/// 每一条断言都对应协议里的一句话：门禁、`sub.subs` 嵌套、字段回退顺序、
/// 格式探测、无 token 零请求、resolve 两跳 + ZIP。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/subtitle_provider.dart';
import 'package:webhtv_pc/core/subtitle_settings.dart';
import 'package:webhtv_pc/services/subtitle_asset_store.dart';
import 'package:webhtv_pc/services/subtitle_providers/assrt_provider.dart';
import 'package:webhtv_pc/services/subtitle_providers/provider.dart';

const String _token = 'T0KEN-abc';

const SubtitleQuery _query = SubtitleQuery(
  title: '庆余年',
  siteKey: 'site',
  vodId: '1',
  episodeName: '第5集',
);

final SubtitleSettings _settings = SubtitleSettings(assrtToken: _token);

http.Response _json(Object body, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

List<int> _zipOf(Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

const Map<String, Object?> _searchBody = {
  'status': 0,
  'sub': {
    'subs': [
      {
        'id': 12345,
        'name': '庆余年 第二季 S02E05 简体 ASS',
        'videoname': '庆余年.2019.S02E05.1080p.WEB-DL.mkv',
        'lang': {'desc': '简体中文'},
        'subtype': 'ass',
      },
      {
        'fileid': '67890',
        'sub_name': '庆余年 第二季 繁中',
        'm_videoname': '庆余年.2019.S02E06.1080p.mkv',
        'm_lang': '繁體中文',
        'm_subtype': 'srt',
      },
    ],
  },
};

SubtitleProvider _provider(MockClient client, {String cacheDir = ''}) =>
    buildAssrtProvider(
      settings: _settings,
      client: client,
      cacheDir: cacheDir,
    )!;

Matcher matcherFor(String code) => throwsA(
  isA<SubtitleResolveException>().having((e) => e.code, 'code', code),
);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('assrt_provider_test_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('元信息：id / name / priority', () {
    final provider = _provider(MockClient((_) async => _json(const {})));
    expect(provider.id, 'assrt');
    expect(provider.name, 'ASSRT');
    expect(provider.priority, 30);
    expect(provider.needsLocalMediaPath, isFalse);
  });

  group('search', () {
    test('正常返回 2 条：字段回退顺序、季集、格式、语言原样透传', () async {
      final requests = <http.Request>[];
      final provider = _provider(
        MockClient((request) async {
          requests.add(request);
          return _json(_searchBody);
        }),
      );

      final candidates = await provider.search(_query, _settings);
      expect(candidates, hasLength(2));

      final first = candidates.first;
      expect(first.providerId, 'assrt');
      expect(first.assetId, '12345');
      expect(first.title, '庆余年 第二季 S02E05 简体 ASS');
      expect(first.language, '简体中文', reason: 'lang.desc 原样透传，不归一');
      expect(first.format, 'ass');
      expect(first.url, '', reason: '这一跳还不知道下载地址');
      expect(first.requiresResolve, isTrue);
      expect(first.payload, {'id': '12345', 'format': 'ass'});
      expect(first.season, 2);
      expect(first.episode, 5);

      final second = candidates[1];
      expect(second.assetId, '67890', reason: 'id 缺失回退 fileid');
      expect(second.title, '庆余年 第二季 繁中');
      expect(second.language, '繁體中文', reason: 'lang 缺失回退 m_lang');
      expect(second.format, 'srt');
      expect(second.season, 2);
      expect(second.episode, 6);

      final request = requests.single;
      expect(request.method, 'GET');
      expect(request.url.host, 'api.assrt.net');
      expect(request.url.path, '/v1/sub/search');
      expect(request.url.queryParameters['token'], _token);
      expect(request.url.queryParameters['q'], '庆余年');
      expect(request.url.queryParameters['is_file'], '1');
      expect(request.url.queryParameters['cnt'], '15');
      expect(request.headers['Referer'], 'https://assrt.net/');
      expect(request.headers['User-Agent'], contains('Chrome/124.0.0.0'));
    });

    test('id 与 fileid 都缺 → 跳过该条，其余照常', () async {
      final provider = _provider(
        MockClient(
          (_) async => _json(const {
            'status': 0,
            'sub': {
              'subs': [
                {'name': '没有 id 的字幕'},
                {'id': 7, 'name': '有 id 的字幕'},
              ],
            },
          }),
        ),
      );
      final candidates = await provider.search(_query, _settings);
      expect(candidates.map((c) => c.assetId), ['7']);
    });

    test('格式探测：.ass/.ssa/.vtt 命中，其余回退 srt', () async {
      final provider = _provider(
        MockClient(
          (_) async => _json(const {
            'status': 0,
            'sub': {
              'subs': [
                {'id': 1, 'name': 'Show.S01E01.ass'},
                {'id': 2, 'name': 'Show.S01E01.ssa'},
                {'id': 3, 'name': 'Show.S01E01.vtt'},
                {'id': 4, 'name': 'Show 简体 ASS'},
                {'id': 5, 'name': 'Show.srt'},
                // subtype 落在首位时不命中（上游用 " "+fmt 比较），照抄。
                {'id': 6, 'subtype': 'ass'},
              ],
            },
          }),
        ),
      );
      final candidates = await provider.search(_query, _settings);
      expect(candidates.map((c) => c.format), [
        'ass',
        'ssa',
        'vtt',
        'ass',
        'srt',
        'srt',
      ]);
    });

    test('status != 0 或缺失 → 空结果，不抛', () async {
      for (final body in const [
        {
          'status': 1,
          'sub': {'subs': []},
        },
        {
          'sub': {'subs': []},
        },
        <String, Object?>{},
      ]) {
        final provider = _provider(MockClient((_) async => _json(body)));
        expect(await provider.search(_query, _settings), isEmpty);
      }
    });

    test('非 2xx → 空结果，不抛', () async {
      final provider = _provider(
        MockClient((_) async => http.Response('boom', 500)),
      );
      expect(await provider.search(_query, _settings), isEmpty);
    });

    test('网络异常 → 空结果，不抛', () async {
      final provider = _provider(
        MockClient((_) async => throw http.ClientException('connect refused')),
      );
      expect(await provider.search(_query, _settings), isEmpty);
    });

    test('sub.subs 不是数组 → 空结果', () async {
      final provider = _provider(
        MockClient(
          (_) async => _json(const {
            'status': 0,
            'sub': {'subs': 'nope'},
          }),
        ),
      );
      expect(await provider.search(_query, _settings), isEmpty);
    });

    test('无 token / 空关键词 → 零请求', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return _json(_searchBody);
      });

      expect(
        buildAssrtProvider(
          settings: SubtitleSettings(assrtToken: '  '),
          client: client,
          cacheDir: temp.path,
        ),
        isNull,
        reason: '没有 token 就没有该源',
      );
      expect(calls, 0);

      // builder 已过滤，provider 内部还要再守一道（调用侧可能传来另一份设置）。
      final provider = _provider(client);
      expect(
        await provider.search(_query, SubtitleSettings(assrtToken: '')),
        isEmpty,
      );
      expect(calls, 0);

      expect(
        await provider.search(
          const SubtitleQuery(
            title: '   ',
            siteKey: 'site',
            vodId: '1',
            episodeName: '',
          ),
          _settings,
        ),
        isEmpty,
      );
      expect(calls, 0);
    });
  });

  group('resolve', () {
    test('detail 取地址 → ZIP 解出 .ass，format 由最终扩展名决定', () async {
      final detailRequests = <http.Request>[];
      final downloadRequests = <http.Request>[];
      final client = MockClient((request) async {
        final url = request.url;
        if (url.host == 'api.assrt.net' && url.path == '/v1/sub/detail') {
          detailRequests.add(request);
          return _json(const {
            'status': 0,
            'sub': {
              'subs': [
                {'url': 'https://dl.assrt.test/f/12345.zip'},
              ],
            },
          });
        }
        if (url.host == 'api.assrt.net') {
          return _json(_searchBody);
        }
        downloadRequests.add(request);
        return http.Response.bytes(
          _zipOf({'a.srt': 'srt text', 'b.ass': '[Script Info]\n'}),
          200,
        );
      });

      final provider = _provider(client, cacheDir: '${temp.path}/subtitles');
      final candidate = (await provider.search(_query, _settings)).first;
      final asset = await provider.resolve(candidate, _query, _settings);

      expect(asset, isNotNull);
      expect(asset!.format, 'ass');
      expect(asset.path, endsWith('.ass'));
      expect(await File(asset.path).readAsString(), contains('[Script Info]'));

      final detail = detailRequests.single;
      expect(detail.url.path, '/v1/sub/detail');
      expect(detail.url.queryParameters['token'], _token);
      expect(detail.url.queryParameters['id'], '12345');
      expect(detail.headers['Referer'], 'https://assrt.net/');
      expect(
        downloadRequests.single.headers['Referer'],
        'https://assrt.net/',
        reason: '下载也要带同一套 header',
      );
    });

    test('detail 缺 url → download_url_missing，异常文本不含 token', () async {
      final provider = _provider(
        MockClient(
          (_) async => _json(const {
            'status': 0,
            'sub': {
              'subs': [
                {'id': 12345},
              ],
            },
          }),
        ),
        cacheDir: '${temp.path}/subtitles',
      );
      Object? caught;
      try {
        await provider.resolve(
          const SubtitleCandidate(
            providerId: 'assrt',
            assetId: '12345',
            title: 'x',
            language: '',
            format: 'srt',
            url: '',
            requiresResolve: true,
            payload: {'id': '12345', 'format': 'srt'},
          ),
          _query,
          _settings,
        );
      } catch (error) {
        caught = error;
      }
      expect(
        caught,
        isA<SubtitleResolveException>().having(
          (e) => e.code,
          'code',
          'download_url_missing',
        ),
      );
      expect(caught.toString(), isNot(contains(_token)));
    });

    test('detail status != 0 / 非 2xx → detail_api_failed', () async {
      for (final client in [
        MockClient((_) async => _json(const {'status': 1})),
        MockClient((_) async => http.Response('boom', 503)),
      ]) {
        final provider = _provider(client, cacheDir: '${temp.path}/subtitles');
        await expectLater(
          provider.resolve(
            const SubtitleCandidate(
              providerId: 'assrt',
              assetId: '1',
              title: 'x',
              language: '',
              format: 'srt',
              url: '',
              requiresResolve: true,
              payload: {'id': '1', 'format': 'srt'},
            ),
            _query,
            _settings,
          ),
          matcherFor('detail_api_failed'),
        );
      }
    });

    test('cacheDir 为空 → no_cache_dir，且不发请求', () async {
      var calls = 0;
      final provider = _provider(
        MockClient((_) async {
          calls++;
          return _json(const {'status': 0});
        }),
      );
      await expectLater(
        provider.resolve(
          const SubtitleCandidate(
            providerId: 'assrt',
            assetId: '1',
            title: 'x',
            language: '',
            format: 'srt',
            url: '',
            requiresResolve: true,
            payload: {'id': '1', 'format': 'srt'},
          ),
          _query,
          _settings,
        ),
        matcherFor('no_cache_dir'),
      );
      expect(calls, 0);
    });
  });
}
