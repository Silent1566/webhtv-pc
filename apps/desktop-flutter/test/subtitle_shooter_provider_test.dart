/// 射手字幕源的分界行为（`docs/superpowers/plans/2026-11-15-subtitle-online-search.md` Task 4）。
///
/// 覆盖「没有本地文件 → 零请求」、四段哈希、form 字段顺序与 resolve 落盘。
/// 不覆盖 registry 的并行聚合，也不覆盖 ZIP 解包（见 subtitle_asset_store_test）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/subtitle_provider.dart';
import 'package:webhtv_pc/core/subtitle_settings.dart';
import 'package:webhtv_pc/services/subtitle_asset_store.dart';
import 'package:webhtv_pc/services/subtitle_providers.dart';

/// 12KiB 阈值（shooter.py:32-37）。
const int kMinFileBytes = 12 * 1024;

/// 以下常量由 python3 独立算出（同一字节序列 + 同一 offsets 顺序），
/// 不是用 Dart 实现自证：
/// ```
/// data = bytes(((i * 37 + 11) % 256) for i in range(size))
/// offsets = (4096, size // 3 * 2, size // 3, size - 8192)
/// ";".join(md5(data[o:o+4096]).hexdigest() for o in offsets)
/// ```
const String kHash100k =
    'efc404fa609a799c7801273de6d65e84;8d22e6cf01ced431570c580e9b638782;'
    '57fb8dd4f52c053bbffb22ea230eb047;62e468ead1dad9582b59da9d231b87fe';

/// 同一文件按升序 offset 拼出的哈希：必须与上面不同，钉住「不得排序」。
const String kHash100kSorted =
    'efc404fa609a799c7801273de6d65e84;57fb8dd4f52c053bbffb22ea230eb047;'
    '8d22e6cf01ced431570c580e9b638782;62e468ead1dad9582b59da9d231b87fe';

/// size = 12KiB + 7，offsets 挤在一起（4096, 8196, 4098, 4103）。
const String kHashJustAboveMin =
    'efc404fa609a799c7801273de6d65e84;2723dc1a32b0ba7c9114dba9db0d2f0a;'
    '80a8b11f9026cec89eb491bf6918ab7d;e9f305f54c2bb4d12f441f704d0ffc3b';

List<int> patternBytes(int size) =>
    List<int>.generate(size, (i) => (i * 37 + 11) % 256);

SubtitleQuery queryWith(String? mediaPath) => SubtitleQuery(
  title: '测试剧',
  mediaPath: mediaPath,
  siteKey: 'site',
  vodId: 'vod',
  episodeName: '第1集',
);

void main() {
  late Directory temp;
  var requests = 0;
  late List<http.Request> captured;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subtitle_shooter_test_');
    requests = 0;
    captured = [];
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> mediaFile(String name, int size) async {
    final file = File('${temp.path}/$name');
    await file.writeAsBytes(patternBytes(size));
    return file;
  }

  SubtitleProvider provider(http.Client client, {String cacheDir = ''}) =>
      buildShooterProvider(
        settings: SubtitleSettings(shooterEnabled: true),
        client: client,
        cacheDir: cacheDir,
      )!;

  /// 抓请求并回一份 JSON 响应的假客户端。
  MockClient jsonClient(Object? body) => MockClient((request) async {
    requests++;
    captured.add(request);
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
  });

  group('输入门禁：没有本地文件就零请求', () {
    test('未启用返回 null', () {
      expect(buildShooterProvider(settings: SubtitleSettings()), isNull);
      expect(requests, 0);
    });

    test('mediaPath 为 null 或空白：零请求空结果', () async {
      final source = provider(jsonClient(<Object>[]));
      expect(await source.search(queryWith(null), SubtitleSettings()), isEmpty);
      expect(
        await source.search(queryWith('   '), SubtitleSettings()),
        isEmpty,
      );
      expect(requests, 0);
    });

    test('文件不存在：零请求空结果', () async {
      final source = provider(jsonClient(<Object>[]));
      expect(
        await source.search(
          queryWith('${temp.path}/missing.mkv'),
          SubtitleSettings(),
        ),
        isEmpty,
      );
      expect(requests, 0);
    });

    test('文件小于 12KiB：零请求空结果', () async {
      final tiny = await mediaFile('tiny.mkv', kMinFileBytes - 1);
      final source = provider(jsonClient(<Object>[]));
      expect(
        await source.search(queryWith(tiny.path), SubtitleSettings()),
        isEmpty,
      );
      expect(requests, 0);
    });
  });

  group('四段哈希', () {
    test('与 python3 参考实现逐字一致；升序顺序会得到别的值', () async {
      final file = await mediaFile('movie.mkv', 100000);
      expect(shooterFileHash(file), kHash100k);
      expect(shooterFileHash(file), isNot(kHash100kSorted));
    });

    test('刚好 12KiB 可算，size=12KiB+7 的紧凑 offsets 也对', () async {
      final edge = await mediaFile('edge.mkv', kMinFileBytes);
      expect(shooterFileHash(edge), isNotNull);
      final close = await mediaFile('close.mkv', kMinFileBytes + 7);
      expect(shooterFileHash(close), kHashJustAboveMin);
    });

    test('太小或不存在返回 null', () async {
      final tiny = await mediaFile('tiny2.mkv', kMinFileBytes - 1);
      expect(shooterFileHash(tiny), isNull);
      expect(shooterFileHash(File('${temp.path}/nope.mkv')), isNull);
    });
  });

  group('search 请求与解析', () {
    test('POST form 字段顺序逐字，只发 UA 不发 Referer', () async {
      final file = await mediaFile('movie-e1.mkv', 100000);
      final source = provider(jsonClient(<Object>[]));
      expect(
        await source.search(queryWith(file.path), SubtitleSettings()),
        isEmpty,
      );

      expect(requests, 1);
      final request = captured.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://www.shooter.cn/api/subapi.php');
      expect(request.headers.keys.map((key) => key.toLowerCase()).toSet(), {
        'user-agent',
        'content-type',
      });
      expect(
        request.headers['content-type'],
        contains('application/x-www-form-urlencoded'),
      );
      expect(
        request.headers['user-agent'],
        startsWith('Mozilla/5.0 (Windows NT 10.0; Win64; x64)'),
      );
      expect(
        request.body,
        'filehash=$kHash100k&pathinfo=${Uri.encodeComponent(file.path)}'
        '&format=json&lang=chn',
      );
    });

    test('路径含空格与 &：pathinfo 百分号编码，不注入额外字段', () async {
      final dir = Directory('${temp.path}/My Videos & More');
      await dir.create(recursive: true);
      final file = File('${dir.path}/movie a&b.mkv');
      await file.writeAsBytes(patternBytes(100000));

      final source = provider(jsonClient(<Object>[]));
      await source.search(queryWith(file.path), SubtitleSettings());

      final body = captured.single.body;
      expect(
        body,
        'filehash=$kHash100k&pathinfo=${Uri.encodeComponent(file.path)}'
        '&format=json&lang=chn',
      );
      // 编码后 body 里没有裸空格，'&' 只剩 3 个字段分隔符（无注入）。
      expect(body, isNot(contains(' ')));
      expect('&'.allMatches(body).length, 3);
      expect(body, contains('My%20Videos%20%26%20More'));
      expect(body, contains('movie%20a%26b.mkv'));
    });

    test('语言归一：en* → eng，其余 → zh', () {
      expect(shooterLanguageOf('en'), 'eng');
      expect(shooterLanguageOf('English'), 'eng');
      expect(shooterLanguageOf('zh-Hans'), 'zh');
      expect(shooterLanguageOf('简体中文'), 'zh');
      expect(shooterLanguageOf(null), 'zh');
    });

    test('响应体不是 JSON：空结果不抛', () async {
      final file = await mediaFile('movie-e2.mkv', 100000);
      final source = provider(
        MockClient((request) async {
          requests++;
          return http.Response('<html>blocked</html>', 200);
        }),
      );
      expect(
        await source.search(queryWith(file.path), SubtitleSettings()),
        isEmpty,
      );
      expect(requests, 1);
    });

    test('顶层不是数组：空结果', () async {
      final file = await mediaFile('movie-e3.mkv', 100000);
      final source = provider(jsonClient({'Files': <Object>[]}));
      expect(
        await source.search(queryWith(file.path), SubtitleSettings()),
        isEmpty,
      );
    });

    test('Files 缺失或不是数组：空结果', () async {
      final file = await mediaFile('movie-e4.mkv', 100000);
      final source = provider(
        jsonClient([
          {'Something': 1},
          {'Files': 'nope'},
        ]),
      );
      expect(
        await source.search(queryWith(file.path), SubtitleSettings()),
        isEmpty,
      );
    });

    test('Files[] 映射：Ext 优先、URL 扩展名回退、空 Link 跳过', () async {
      final file = await mediaFile('movie-e5.mkv', 100000);
      final source = provider(
        jsonClient([
          {
            'Files': [
              {'Ext': 'ass', 'Link': 'https://shooter.test/1.zip'},
              {'Ext': '', 'Link': 'https://shooter.test/2.srt?token=1'},
              {'Link': 'https://shooter.test/3.rar'},
              {'Ext': 'ass', 'Link': ''},
            ],
          },
        ]),
      );
      final candidates = await source.search(
        queryWith(file.path),
        SubtitleSettings(),
      );
      expect(candidates, hasLength(3));

      final first = candidates[0];
      expect(first.providerId, 'shooter');
      expect(first.assetId, 'https://shooter.test/1.zip');
      expect(first.url, 'https://shooter.test/1.zip');
      expect(first.format, 'ass');
      expect(first.title, 'movie-e5.mkv | 射手 | ass');
      expect(first.language, 'zh');
      expect(first.score, 120);
      expect(first.requiresResolve, isTrue);
      expect(first.payload, {
        'url': 'https://shooter.test/1.zip',
        'format': 'ass',
      });

      expect(candidates[1].format, 'srt');
      expect(candidates[1].title, 'movie-e5.mkv | 射手 | srt');
      expect(candidates[2].format, 'srt');
    });

    test('format 白名单：Ext 也要过筛，zip/unknown 回落 srt', () async {
      final file = await mediaFile('movie-e7.mkv', 100000);
      final source = provider(
        jsonClient([
          {
            'Files': [
              // Ext 非空就只看 Ext：即便 URL 是 .ass，也按 Ext 判为 srt。
              {'Ext': 'zip', 'Link': 'https://shooter.test/a.ass'},
              {'Ext': 'unknown', 'Link': 'https://shooter.test/b'},
              {'Ext': 'ass', 'Link': 'https://shooter.test/c.zip'},
              // 参考实现先拼再 replace('.', '')，带点写法同样命中。
              {'Ext': '.ssa', 'Link': 'https://shooter.test/d'},
            ],
          },
        ]),
      );
      final candidates = await source.search(
        queryWith(file.path),
        SubtitleSettings(),
      );
      expect(
        [for (final candidate in candidates) candidate.format],
        ['srt', 'srt', 'ass', 'ssa'],
      );
    });
  });

  group('resolve', () {
    const candidate = SubtitleCandidate(
      providerId: 'shooter',
      assetId: 'https://shooter.test/1.zip',
      title: 'movie-e6.mkv | 射手 | ass',
      language: 'zh',
      format: 'ass',
      url: 'https://shooter.test/1.zip',
      score: 120,
      payload: {'url': 'https://shooter.test/1.zip', 'format': 'srt'},
      requiresResolve: true,
    );

    test('单跳下载落盘，格式按最终扩展名，带 UA', () async {
      final client = MockClient((request) async {
        requests++;
        captured.add(request);
        return http.Response.bytes(
          utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n你好\n'),
          200,
        );
      });
      final source = provider(client, cacheDir: '${temp.path}/subtitles');
      final asset = await source.resolve(
        candidate,
        queryWith(null),
        SubtitleSettings(),
      );
      expect(asset, isNotNull);
      expect(asset!.format, 'srt');
      expect(asset.path, endsWith('.srt'));
      expect(await File(asset.path).readAsString(), contains('你好'));
      expect(requests, 1);
      expect(
        captured.single.headers['user-agent'],
        startsWith('Mozilla/5.0 (Windows NT 10.0; Win64; x64)'),
      );
    });

    test('payload 缺 url：download_url_missing 且零请求', () async {
      final source = provider(
        MockClient((request) async {
          requests++;
          return http.Response('', 200);
        }),
        cacheDir: '${temp.path}/subtitles',
      );
      const broken = SubtitleCandidate(
        providerId: 'shooter',
        assetId: 'x',
        title: 'x',
        language: 'zh',
        format: 'srt',
        url: '',
        requiresResolve: true,
      );
      expect(
        () => source.resolve(broken, queryWith(null), SubtitleSettings()),
        throwsA(
          isA<SubtitleResolveException>().having(
            (error) => error.code,
            'code',
            'download_url_missing',
          ),
        ),
      );
      expect(requests, 0);
    });
  });
}
