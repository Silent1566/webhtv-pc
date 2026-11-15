import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/http_api.dart';
import 'package:webhtv_pc/core/playback_request.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/parse_service.dart';
import 'package:webhtv_pc/services/site_service.dart';
import 'package:webhtv_pc/services/spider_router.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/sniff_fakes.dart';

const _media = 'https://cdn.test/episode.m3u8';
const _parsers = [
  ParseEntry(name: '解析 A', type: 0, url: 'https://parser-a.test/?url='),
  ParseEntry(name: '解析 B', type: 0, url: 'https://parser-b.test/?url='),
];

Future<PlaybackDecision> _resolve({
  required String target,
  int parse = 0,
  String? preferred,
}) async {
  final site = Site(
    key: 'test',
    name: 'Test',
    type: 4,
    api: 'https://site.test/api',
  );
  final router = SpiderRouter(
    globalHeaders: const [],
    client: HttpApiClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'url': target, 'parse': parse}),
          200,
          // 默认 latin1 编码写不了中文（解析器名就是中文），显式声明 UTF-8。
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    ),
  );
  addTearDown(router.dispose);
  final parser = ParseService(sniffEngine: FakeSniffEngine.success(_media));
  addTearDown(parser.close);
  final service = SiteService(
    appConfig: AppConfig(sites: [site], parses: _parsers),
    router: router,
  );
  return (await service.resolvePlayback(
    site: site,
    episodeTarget: 'https://video.test/episode-1',
    flag: 'video',
    parseService: parser,
    preferredParseName: preferred,
  )).value;
}

PlaybackRequest _request(PlaybackDecision decision) => PlaybackRequest(
  url: decision.url!,
  title: 'Test',
  siteKey: 'test',
  vodId: 'vod',
  vodName: 'Test',
  episodeName: '1',
  flag: 'video',
  parseSources: decision.parseSources,
  parseSource: decision.parseSource,
);

void main() {
  test('configured parsers do not expose choices for a direct result', () async {
    final decision = await _resolve(target: _media);
    expect(decision.url, _media);
    expect(decision.parseSources, isEmpty);
    expect(decision.parseSource, isEmpty);
  });

  test('parsed playback exposes its own selectable configuration and automatic mode', () async {
    final decision = await _resolve(target: 'https://video.test/episode-1', parse: 1);
    expect(decision.url, _media);
    expect(decision.parseSources, ['超级解析', '解析 A', '解析 B']);
    expect(decision.parseSource, '超级解析');
  });

  test('explicit parser selection is reflected by the playable result', () async {
    final decision = await _resolve(
      target: 'https://video.test/episode-1',
      parse: 1,
      preferred: '解析 B',
    );
    expect(decision.url, _media);
    expect(decision.parseSource, '解析 B');
    expect(decision.parseSources, ['超级解析', '解析 A', '解析 B']);
  });

  test('fixed named parser does not offer an override that its prefix ignores', () async {
    final decision = await _resolve(
      target: 'parse:解析 A',
      parse: 1,
      preferred: '解析 B',
    );
    expect(decision.url, _media);
    expect(decision.parseSource, '解析 A');
    expect(decision.parseSources, isEmpty);
  });

  test('copying playback state preserves choices and fresh direct results clear them', () async {
    final parsed = await _resolve(target: 'https://video.test/episode-1', parse: 1);
    final request = _request(parsed.copyWith(headers: HeaderMap({'Referer': 'test'})));
    final resumed = request.copyWith(startPosition: const Duration(seconds: 40));
    expect(resumed.parseSources, ['超级解析', '解析 A', '解析 B']);
    expect(resumed.parseSource, '超级解析');

    final direct = await _resolve(target: _media);
    final changed = resumed.copyWith(
      url: direct.url,
      parseSources: direct.parseSources,
      parseSource: direct.parseSource,
    );
    expect(changed.parseSources, isEmpty);
    expect(changed.parseSource, isEmpty);
  });

  test('local proxy reconstruction does not lose parser options', () async {
    final temp = await Directory.systemTemp.createTemp('webhtv-parse-metadata-');
    final state = AppState(paths: AppPaths.resolve(overrides: {
      'config': '${temp.path}/config',
      'data': '${temp.path}/data',
      'cache': '${temp.path}/cache',
      'state': '${temp.path}/state',
    }));
    addTearDown(() async {
      await state.stopProxy();
      state.dispose();
      await temp.delete(recursive: true);
    });
    final proxied = await state.proxyDecision(
      PlaybackDecision(
        action: PlaybackAction.direct,
        url: 'https://cdn.example/episode.m3u8',
        headers: HeaderMap({'Referer': 'https://video.example/'}),
        parseSources: const ['超级解析', '解析 A', '解析 B'],
        parseSource: '解析 B',
      ),
      siteKey: 'test',
    );
    expect(Uri.parse(proxied.url!).host, '127.0.0.1');
    expect(proxied.parseSources, ['超级解析', '解析 A', '解析 B']);
    expect(proxied.parseSource, '解析 B');
  });
}
