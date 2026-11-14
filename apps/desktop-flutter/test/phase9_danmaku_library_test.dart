import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/danmaku_match.dart';
import 'package:webhtv_pc/core/danmaku_settings.dart';
import 'package:webhtv_pc/services/danmaku_library_service.dart';

void main() {
  group('弹幕库设置（design/02 §2.4）', () {
    test('默认全关', () {
      const settings = DanmakuSettings.defaults();
      expect(settings.autoSearch, isFalse);
      expect(settings.hasLibrary, isFalse);
      expect(settings.isEnabled, isFalse);
    });

    test('序列化往返与空白清理', () {
      const settings = DanmakuSettings(
        autoSearch: true,
        apiUrl: '  https://example.test/d  ',
      );
      final restored = DanmakuSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())),
      );
      expect(restored.autoSearch, isTrue);
      expect(restored.apiUrl, 'https://example.test/d');
      expect(restored.isEnabled, isTrue);
    });
  });

  group('弹幕库客户端（design/02 §2.3）', () {
    const query = DanmakuQuery(
      title: '某剧',
      episode: '第1集',
      siteKey: 's',
      vodId: 'v',
      episodeName: '第1集',
    );

    test('解析 data 数组并透传标题/集', () async {
      late Uri captured;
      final client = MockClient((request) async {
        captured = request.url;
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': [
              {
                'id': 'd1',
                'title': '某剧',
                'episode': '01',
                'url': 'https://example.test/d1.xml',
                'count': 120,
              },
              {'id': 'd2', 'title': '缺地址'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final service = DanmakuLibraryService(client: client);
      final entries = await service.search(
        apiUrl: 'https://example.test/search',
        title: '某剧',
        episode: '第1集',
      );
      expect(entries, hasLength(1));
      expect(entries.single.count, 120);
      expect(captured.queryParameters['title'], '某剧');
      expect(captured.queryParameters['episode'], '第1集');
    });

    test('未配置地址时零请求', () async {
      var called = false;
      final service = DanmakuLibraryService(
        client: MockClient((_) async {
          called = true;
          return http.Response('[]', 200);
        }),
      );
      expect(
        await service.search(apiUrl: '', title: 'x'),
        isEmpty,
      );
      expect(called, isFalse);
    });

    test('非 2xx / 非法 JSON / 网络异常返回空', () async {
      final cases = <DanmakuLibraryService>[
        DanmakuLibraryService(
          client: MockClient((_) async => http.Response('x', 500)),
        ),
        DanmakuLibraryService(
          client: MockClient((_) async => http.Response('not json', 200)),
        ),
        DanmakuLibraryService(
          client: MockClient((_) async => throw const SocketException('x')),
        ),
      ];
      for (final service in cases) {
        expect(
          await service.search(apiUrl: 'https://example.test/s', title: 'x'),
          isEmpty,
        );
      }
    });

    test('评分选出集号与标题都匹配的条目', () async {
      final entries = [
        const DanmakuLibraryEntry(
          providerId: 'p',
          id: 'wrong-ep',
          title: '某剧',
          episode: '02',
          url: 'https://example.test/2.xml',
        ),
        const DanmakuLibraryEntry(
          providerId: 'p',
          id: 'right',
          title: '某剧',
          episode: '01',
          url: 'https://example.test/1.xml',
        ),
      ];
      final picked = pickDanmakuEntry(entries: entries, query: query);
      expect(picked, isNotNull);
      expect(picked!.id, 'right');
    });
  });
}
