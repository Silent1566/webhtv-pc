import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/subtitle_provider.dart';
import 'package:webhtv_pc/core/subtitle_settings.dart';
import 'package:webhtv_pc/services/subtitle_match_service.dart';
import 'package:webhtv_pc/services/subtitle_providers.dart';

void main() {
  group('字幕源设置（design/02 §3）', () {
    test('默认全关，未配置 provider', () {
      final settings = SubtitleSettings();
      expect(settings.autoMatch, isFalse);
      expect(settings.hasAnyProvider, isFalse);
      expect(settings.isEnabled, isFalse);
      expect(settings.preferredLanguages, kDefaultSubtitleLanguages);
    });

    test('序列化往返与空白清理', () {
      final settings = SubtitleSettings(
        autoMatch: true,
        httpEndpoint: '  https://example.test/s  ',
        httpToken: ' t ',
        localDirectories: const ['  C:\\subs  ', ''],
      );
      final restored = SubtitleSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())),
      );
      expect(restored.autoMatch, isTrue);
      expect(restored.httpEndpoint, 'https://example.test/s');
      expect(restored.httpToken, 't');
      expect(restored.localDirectories, [r'C:\subs']);
      expect(restored.hasAnyProvider, isTrue);
    });

    test('preferredLanguages 为空时回落默认', () {
      final parsed = SubtitleSettings.fromJson({
        'autoMatch': true,
        'preferredLanguages': <String>[],
      });
      expect(parsed.preferredLanguages, kDefaultSubtitleLanguages);
    });
  });

  group('本地字幕源（design/02 §1.4）', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('webhtv-phase9-subs');
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('按片名匹配并识别语言，非字幕文件忽略', () async {
      File('${temp.path}${Platform.pathSeparator}某剧 第01集 简中.srt')
          .writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\n你好\n');
      File('${temp.path}${Platform.pathSeparator}other.mkv')
          .writeAsStringSync('x');
      File('${temp.path}${Platform.pathSeparator}无关.ass')
          .writeAsStringSync('[Script Info]\n');

      final provider = LocalSubtitleProvider();
      final results = await provider.search(
        const SubtitleQuery(
          title: '某剧',
          siteKey: 's',
          vodId: 'v',
          episodeName: '第1集',
        ),
        SubtitleSettings(localDirectories: [temp.path]),
      );
      expect(results, hasLength(1));
      expect(results.single.language, 'zh-Hans');
      expect(results.single.format, 'srt');
      expect(results.single.url, contains('某剧 第01集 简中.srt'));
    });

    test('目录不存在时安静返回空', () async {
      final provider = LocalSubtitleProvider();
      final results = await provider.search(
        const SubtitleQuery(
          title: '某剧',
          siteKey: 's',
          vodId: 'v',
          episodeName: '第1集',
        ),
        SubtitleSettings(localDirectories: ['${temp.path}${Platform.pathSeparator}nope']),
      );
      expect(results, isEmpty);
    });
  });

  group('HTTP 字幕源（design/02 §1.4）', () {
    test('解析 data 数组并透传 query', () async {
      late Uri captured;
      final client = MockClient((request) async {
        captured = request.url;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': [
              {
                'id': 'a1',
                'title': '某剧 第1集',
                'language': 'zh-Hans',
                'format': 'srt',
                'url': 'https://example.test/a1.srt',
                'season': 1,
                'episode': 1,
              },
              {'id': 'a2', 'title': '缺地址'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final provider = HttpSubtitleProvider(client: client);
      final results = await provider.search(
        const SubtitleQuery(
          title: '某剧',
          season: 1,
          episode: 1,
          siteKey: 's',
          vodId: 'v',
          episodeName: '第1集',
        ),
        SubtitleSettings(
          httpEndpoint: 'https://example.test/search',
          httpToken: 'secret',
        ),
      );
      expect(results, hasLength(1));
      expect(results.single.url, 'https://example.test/a1.srt');
      expect(results.single.season, 1);
      expect(captured.queryParameters['q'], '某剧');
      expect(captured.queryParameters['token'], 'secret');
      expect(captured.queryParameters['season'], '1');
    });

    test('非 2xx / 非法 JSON / 网络异常都返回空', () async {
      final failing = HttpSubtitleProvider(
        client: MockClient((_) async => http.Response('nope', 500)),
      );
      final settings = SubtitleSettings(
        httpEndpoint: 'https://example.test/search',
      );
      const query = SubtitleQuery(
        title: 'x',
        siteKey: 's',
        vodId: 'v',
        episodeName: 'e',
      );
      expect(await failing.search(query, settings), isEmpty);

      final badJson = HttpSubtitleProvider(
        client: MockClient((_) async => http.Response('not json', 200)),
      );
      expect(await badJson.search(query, settings), isEmpty);

      final throwing = HttpSubtitleProvider(
        client: MockClient((_) async => throw const SocketException('x')),
      );
      expect(await throwing.search(query, settings), isEmpty);
    });

    test('未配置地址时零请求', () async {
      var called = false;
      final provider = HttpSubtitleProvider(
        client: MockClient((_) async {
          called = true;
          return http.Response('[]', 200);
        }),
      );
      const query = SubtitleQuery(
        title: 'x',
        siteKey: 's',
        vodId: 'v',
        episodeName: 'e',
      );
      expect(await provider.search(query, SubtitleSettings()), isEmpty);
      expect(called, isFalse);
    });
  });

  group('字幕匹配编排（design/02 §1.3）', () {
    test('高于阈值才自动选中；低于阈值返回 null', () async {
      final high = _FakeProvider([
        const SubtitleCandidate(
          providerId: 'fake',
          assetId: 'a',
          title: '某剧',
          language: 'zh-Hans',
          format: 'srt',
          url: 'https://example.test/a.srt',
        ),
      ]);
      final service = SubtitleMatchService(providers: [high]);
      const query = SubtitleQuery(
        title: '某剧',
        siteKey: 's',
        vodId: 'v',
        episodeName: '第1集',
      );
      final picked = await service.autoMatch(
        query: query,
        settings: SubtitleSettings(autoMatch: true),
      );
      expect(picked, isNotNull);
      expect(picked!.score, greaterThanOrEqualTo(kSubtitleAutoPickThreshold));

      final low = _FakeProvider([
        const SubtitleCandidate(
          providerId: 'fake',
          assetId: 'b',
          title: '完全不同的片名',
          language: 'en',
          format: 'srt',
          url: 'https://example.test/b.srt',
        ),
      ]);
      final service2 = SubtitleMatchService(providers: [low]);
      expect(
        await service2.autoMatch(
          query: query,
          settings: SubtitleSettings(autoMatch: true),
        ),
        isNull,
      );
    });

    test('没有 provider 时返回空/null，不发任何请求', () async {
      final service = SubtitleMatchService(providers: const []);
      const query = SubtitleQuery(
        title: 'x',
        siteKey: 's',
        vodId: 'v',
        episodeName: 'e',
      );
      expect(
        await service.search(query: query, settings: SubtitleSettings()),
        isEmpty,
      );
      expect(
        await service.autoMatch(query: query, settings: SubtitleSettings()),
        isNull,
      );
    });
  });
}

class _FakeProvider implements SubtitleProvider {
  _FakeProvider(this.results);

  final List<SubtitleCandidate> results;

  @override
  String get id => 'fake';

  @override
  String get name => 'fake';

  @override
  Future<List<SubtitleCandidate>> search(
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async => results;
}
