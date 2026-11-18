/// Bangumi 兜底源客户端单测（CI 上由 `flutter test` 执行）。
///
/// 只打桩、不联网：
/// - 时间基准注入固定 [clock]，间隔等待注入计数用的 `delay`，测试不需要真睡；
/// - 每个用例都注入 `MockClient`，顺带断言请求形态（方法 / 路径 / UA / body）；
/// - 响应一律用 `http.Response.bytes(utf8.encode(..))`：`Response(String)` 在
///   `Content-Type` 不带 charset 时会按 latin1 编码，中文标题会直接抛错。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/external_meta.dart';
import 'package:webhtv_pc/core/meta_source.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/bangumi_service.dart';

/// 固定时钟：注入后限速只走 `delay`，不会真的等 1 秒。
DateTime fixedClock() => DateTime(2026, 11, 17, 12);

http.Response jsonResponse(Object? body, {int status = 200}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json'},
    );

http.Response rawResponse(String body, int status) =>
    http.Response.bytes(utf8.encode(body), status);

/// 一条三次元（`type = 6`）搜索结果，形状照 2026-11 实测。
Map<String, Object?> subjectItem({
  Object? id = 187187,
  String name = 'Stranger Things',
  String nameCn = '怪奇物语',
  String platform = '欧美剧',
  String date = '2016-07-15',
  Object? eps = 8,
  Object? totalEpisodes = 8,
  Object? score = 7.6,
  Map<String, Object?> images = const {
    'large': 'https://lain.bgm.tv/pic/cover/l/187187.jpg',
  },
  String summary = '小镇上的怪事。',
}) => {
  'id': id,
  'type': 6,
  'name': name,
  'name_cn': nameCn,
  'date': date,
  'platform': platform,
  'eps': eps,
  'total_episodes': totalEpisodes,
  'rating': {'score': score, 'rank': 695, 'total': 567},
  'images': images,
  'summary': summary,
  'infobox': [
    {'key': '导演', 'value': 'A / B'},
    {
      'key': '别名',
      'value': [
        {'v': 'Montauk'},
      ],
    },
  ],
};

void main() {
  group('search', () {
    test('解析 platform→mediaType / name_cn 回退 / rating / poster', () async {
      var requests = 0;
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          return jsonResponse({
            'data': [
              subjectItem(),
              subjectItem(
                id: 383130,
                name: 'Stranger Things Season 5',
                nameCn: '怪奇物语 第五季',
              ),
              // 剧场版含「剧」字：必须判 movie，不能按「含剧即 tv」。
              subjectItem(
                id: 200000,
                name: 'Some Movie',
                nameCn: '',
                platform: '剧场版',
                eps: 1,
                totalEpisodes: 1,
              ),
              // 没有 platform：用集数兜底。
              subjectItem(
                id: 200001,
                name: 'No Platform Show',
                nameCn: '',
                platform: '',
                eps: 12,
                totalEpisodes: 12,
              ),
              // id <= 0：没有可用身份，丢弃。
              subjectItem(id: 0),
            ],
            'total': 5,
            'limit': 10,
            'offset': 0,
          });
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      final found = await service.search(const MetaQuery(title: '怪奇物语'));

      expect(requests, 1);
      expect(found, hasLength(4));

      final first = found.first;
      expect(first.identity.key, 'bangumi:tv:187187');
      expect(first.identity.kind, MetaSourceKind.bangumi);
      expect(first.identity.mediaType, TmdbMediaType.tv);
      expect(first.title, '怪奇物语');
      expect(first.originalTitle, 'Stranger Things');
      expect(first.year, 2016);
      expect(first.episodeCount, 8);
      expect(first.rating, 7.6);
      expect(first.posterUrl, 'https://lain.bgm.tv/pic/cover/l/187187.jpg');
      expect(first.overview, '小镇上的怪事。');
      expect(first.seasonLabel, '');

      expect(found[1].seasonLabel, '第五季');
      expect(found[2].identity.mediaType, TmdbMediaType.movie);
      expect(found[2].title, 'Some Movie');
      expect(found[3].identity.mediaType, TmdbMediaType.tv);
      expect(found[3].originalTitle, '');
      // 不做二次排序：保留外部源给出的顺序。
      expect(found.map((candidate) => candidate.identity.id).toList(), [
        187187,
        383130,
        200000,
        200001,
      ]);

      // 同一 URL 命中内存缓存，不再打网络。
      await service.search(const MetaQuery(title: '怪奇物语'));
      expect(requests, 1);
    });

    test('请求形态：POST + UA + 动画与三次元', () async {
      http.Request? last;
      final service = BangumiService(
        client: MockClient((request) async {
          last = request;
          return jsonResponse({'data': <Object?>[], 'total': 0});
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      await service.search(const MetaQuery(title: '怪奇物语'));

      expect(last!.method, 'POST');
      expect(last!.url.path, '/v0/search/subjects');
      expect(last!.url.queryParameters['limit'], '10');
      expect(last!.headers['User-Agent'], bangumiUserAgent);
      expect(last!.headers['Content-Type'], startsWith('application/json'));
      expect(last!.body, '{"keyword":"怪奇物语","filter":{"type":[2,6]}}');
    });

    test('失败（5xx）返回空列表且不抛，尝试 3 次并写日志', () async {
      var requests = 0;
      final logs = <String>[];
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          return jsonResponse({'error': 'boom'}, status: 500);
        }),
        clock: fixedClock,
        delay: (duration) async {},
        log: logs.add,
      );
      addTearDown(service.close);

      final found = await service.search(const MetaQuery(title: '怪奇物语'));

      expect(found, isEmpty);
      // 首次 + maxRetries(2) 次重试。
      expect(requests, 1 + maxRetries);
      expect(logs, isNotEmpty);
    });

    test('解析失败也返回空列表，且不重试', () async {
      var requests = 0;
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          return rawResponse('<html>not json</html>', 200);
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      expect(await service.search(const MetaQuery(title: 'x')), isEmpty);
      expect(requests, 1);
    });

    test('空查询一次都不请求', () async {
      var requests = 0;
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          return jsonResponse({'data': <Object?>[]});
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      expect(await service.search(const MetaQuery(title: '   ')), isEmpty);
      expect(requests, 0);
    });
  });

  group('详情与人物', () {
    test('subject 原样返回 JSON 对象', () async {
      final service = BangumiService(
        client: MockClient((request) async {
          expect(request.url.path, '/v0/subjects/187187');
          return jsonResponse(subjectItem());
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      final subject = await service.subject(187187);

      expect(subject['id'], 187187);
      expect(aliasOf(subject), 'Montauk');
      final rating = subject['rating'];
      expect(rating, isA<Map>());
      expect((rating as Map)['score'], 7.6);
    });

    test('persons 解析裸数组（不是 {data:..} 包装）', () async {
      final service = BangumiService(
        client: MockClient((request) async {
          expect(request.url.path, '/v0/subjects/187187/persons');
          return jsonResponse([
            {
              'id': 46517,
              'name': 'Millie Bobby Brown',
              'relation': '主演',
              'career': ['producer', 'actor'],
              'images': {'grid': 'https://lain.bgm.tv/pic/crt/g/1.jpg'},
              'eps': 8,
              'type': 1,
            },
          ]);
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      final persons = await service.persons(187187);

      expect(persons, hasLength(1));
      expect(persons.first['id'], 46517);
      expect(persons.first['relation'], '主演');
    });

    test('person 原样返回 JSON 对象', () async {
      final service = BangumiService(
        client: MockClient((request) async {
          expect(request.url.path, '/v0/persons/46517');
          return jsonResponse({
            'id': 46517,
            'name': 'Millie Bobby Brown',
            'birth_year': 2004,
            'summary': '英国演员。',
            'images': {'large': 'https://lain.bgm.tv/pic/crt/l/1.jpg'},
          });
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      final person = await service.person(46517);

      expect(person['birth_year'], 2004);
      expect(person['summary'], '英国演员。');
    });

    test('personSubjects 解析裸数组', () async {
      final service = BangumiService(
        client: MockClient((request) async {
          expect(request.url.path, '/v0/persons/46517/subjects');
          return jsonResponse([
            {
              'id': 383130,
              'name': 'Stranger Things Season 5',
              'name_cn': '怪奇物语 第五季',
              'image': 'https://lain.bgm.tv/pic/cover/l/383130.jpg',
              'staff': '主演',
              'eps': 8,
              'type': 6,
            },
          ]);
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      final works = await service.personSubjects(46517);

      expect(works, hasLength(1));
      expect(works.first['staff'], '主演');
      expect(works.first['type'], 6);
    });

    test('响应形态不对抛 BangumiException', () async {
      final service = BangumiService(
        client: MockClient((request) async {
          // persons 要数组却给了对象；subject 要对象却给了数组。
          if (request.url.path.endsWith('/persons')) {
            return jsonResponse({'data': <Object?>[]});
          }
          return jsonResponse([subjectItem()]);
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      await expectLater(service.persons(1), throwsA(isA<BangumiException>()));
      await expectLater(service.subject(1), throwsA(isA<BangumiException>()));
    });

    test('4xx 不重试，抛带状态码的 BangumiException', () async {
      var requests = 0;
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          return jsonResponse({'error': 'nf'}, status: 404);
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      await expectLater(
        service.subject(999999),
        throwsA(
          isA<BangumiException>().having(
            (error) => error.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
      expect(requests, 1);
    });
  });

  group('请求边界回归', () {
    test('搜索保留动画候选', () async {
      final service = BangumiService(
        client: MockClient(
          (request) async => jsonResponse({
            'data': [
              {...subjectItem(id: 2, nameCn: '动画 第二季'), 'type': 2},
            ],
          }),
        ),
        minInterval: Duration.zero,
      );
      addTearDown(service.close);
      final found = await service.search(const MetaQuery(title: '动画'));
      expect(found.single.identity.key, 'bangumi:tv:2');
      expect(found.single.seasonLabel, '第二季');
    });

    test('5xx 的每次重试均等待 minInterval', () async {
      var now = fixedClock();
      final starts = <DateTime>[];
      final waits = <Duration>[];
      final service = BangumiService(
        client: MockClient((request) async {
          starts.add(now);
          return jsonResponse(
            subjectItem(),
            status: starts.length < 3 ? 502 : 200,
          );
        }),
        clock: () => now,
        delay: (duration) async {
          waits.add(duration);
          now = now.add(duration);
        },
      );
      addTearDown(service.close);
      expect((await service.subject(1))['id'], 187187);
      expect(starts, [
        fixedClock(),
        fixedClock().add(const Duration(seconds: 1)),
        fixedClock().add(const Duration(seconds: 2)),
      ]);
      expect(waits, [const Duration(seconds: 1), const Duration(seconds: 1)]);
    });

    test('网络异常重试同样限速且最多两次', () async {
      var now = fixedClock();
      var requests = 0;
      final waits = <Duration>[];
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          throw const SocketException('network unavailable');
        }),
        clock: () => now,
        delay: (duration) async {
          waits.add(duration);
          now = now.add(duration);
        },
      );
      addTearDown(service.close);
      await expectLater(service.subject(1), throwsA(isA<BangumiException>()));
      expect(requests, 3);
      expect(waits, [const Duration(seconds: 1), const Duration(seconds: 1)]);
    });

    test('所有非法 id 在缓存读取与网络之前拒绝', () async {
      final directory = _CacheProbeDirectory();
      var requests = 0;
      final service = BangumiService(
        cacheDirectory: directory,
        client: MockClient((request) async {
          requests++;
          return jsonResponse(subjectItem());
        }),
        minInterval: Duration.zero,
      );
      addTearDown(service.close);
      for (final id in [0, -1]) {
        for (final operation in <Future<Object?> Function()>[
          () => service.subject(id),
          () => service.persons(id),
          () => service.person(id),
          () => service.personSubjects(id),
        ]) {
          await expectLater(operation(), throwsA(isA<BangumiException>()));
        }
      }
      expect(requests, 0);
      expect(directory.pathReads, 0);
    });

    test('关闭后所有方法不再读取磁盘缓存', () async {
      final directory = _CacheProbeDirectory();
      final service = BangumiService(cacheDirectory: directory);
      service.close();
      for (final operation in <Future<Object?> Function()>[
        () => service.subject(1),
        () => service.persons(1),
        () => service.person(1),
        () => service.personSubjects(1),
      ]) {
        await expectLater(operation(), throwsA(isA<BangumiException>()));
      }
      expect(await service.search(const MetaQuery(title: 'x')), isEmpty);
      expect(directory.pathReads, 0);
    });

    test('间隔等待期间关闭不会继续发请求', () async {
      var requests = 0;
      late BangumiService service;
      service = BangumiService(
        client: MockClient((request) async {
          requests++;
          return jsonResponse(subjectItem());
        }),
        clock: fixedClock,
        delay: (duration) async => service.close(),
      );
      await service.subject(1);
      await expectLater(service.subject(2), throwsA(isA<BangumiException>()));
      expect(requests, 1);
    });

    test('飞行请求关闭后不回填缓存', () async {
      final directory = _CacheProbeDirectory(allowRead: true);
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final service = BangumiService(
        cacheDirectory: directory,
        client: MockClient((request) async {
          started.complete();
          return response.future;
        }),
      );
      final result = service.subject(1);
      await started.future;
      service.close();
      response.complete(jsonResponse(subjectItem()));
      await expectLater(result, throwsA(isA<BangumiException>()));
      expect(directory.creates, 0);
    });

    testWidgets('响应 body 未结束也受单次十五秒超时约束', (tester) async {
      final streams = <StreamController<List<int>>>[];
      Object? failure;
      var finished = false;
      final service = BangumiService(
        client: MockClient.streaming((request, body) async {
          final stream = StreamController<List<int>>();
          streams.add(stream);
          return http.StreamedResponse(stream.stream, 200);
        }),
        minInterval: Duration.zero,
      );
      service
          .subject(1)
          .then<void>(
            (_) {
              finished = true;
            },
            onError: (Object error) {
              failure = error;
              finished = true;
            },
          );
      await tester.pump();
      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.pump(const Duration(seconds: 15));
      }
      service.close();
      for (final stream in streams) {
        unawaited(stream.close());
      }
      await tester.pump();
      expect(finished, isTrue);
      expect(failure, isA<BangumiException>());
      expect(streams, hasLength(3));
    });

    test('日志回调抛异常也不破坏搜索兜底', () async {
      final service = BangumiService(
        client: MockClient((request) async => rawResponse('bad json', 200)),
        log: (message) => throw StateError('logger failed'),
      );
      addTearDown(service.close);
      expect(await service.search(const MetaQuery(title: 'x')), isEmpty);
    });

    test('非 200 的成功状态仍抛异常且不重试', () async {
      var requests = 0;
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          return jsonResponse(subjectItem(), status: 201);
        }),
      );
      addTearDown(service.close);
      await expectLater(service.subject(1), throwsA(isA<BangumiException>()));
      expect(requests, 1);
    });
  });

  group('限速、重试与缓存', () {
    test('请求串行，且每次之间注入 minInterval 的等待', () async {
      var active = 0;
      var maxActive = 0;
      var delayCalls = 0;
      final waits = <Duration>[];
      final service = BangumiService(
        client: MockClient((request) async {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          active--;
          return jsonResponse(subjectItem());
        }),
        clock: fixedClock,
        delay: (duration) async {
          delayCalls++;
          waits.add(duration);
        },
      );
      addTearDown(service.close);

      await Future.wait([
        service.subject(1),
        service.subject(2),
        service.subject(3),
      ]);

      // 串行：任何时刻只有一个请求在飞。
      expect(maxActive, 1);
      // 3 个请求之间需要 2 次间隔等待。
      expect(delayCalls, greaterThanOrEqualTo(2));
      expect(waits.every((wait) => wait == const Duration(seconds: 1)), isTrue);
    });

    test('5xx 重试后成功（共 3 次请求）', () async {
      var requests = 0;
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          if (requests < 3) {
            return jsonResponse({'error': 'flaky'}, status: 502);
          }
          return jsonResponse(subjectItem());
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      final subject = await service.subject(187187);

      expect(subject['id'], 187187);
      expect(requests, 3);
    });

    test('5xx 用尽重试后抛 BangumiException', () async {
      var requests = 0;
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          return jsonResponse({'error': 'flaky'}, status: 503);
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      await expectLater(
        service.subject(187187),
        throwsA(
          isA<BangumiException>().having(
            (error) => error.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
      expect(requests, 1 + maxRetries);
    });

    test('同一 URL 命中内存缓存，只请求一次', () async {
      var requests = 0;
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          return jsonResponse(subjectItem());
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );
      addTearDown(service.close);

      await service.subject(187187);
      await service.subject(187187);

      expect(requests, 1);
    });

    test('close 之后不再发请求', () async {
      var requests = 0;
      final service = BangumiService(
        client: MockClient((request) async {
          requests++;
          return jsonResponse(subjectItem());
        }),
        clock: fixedClock,
        delay: (duration) async {},
      );

      service.close();

      await expectLater(service.subject(1), throwsA(isA<BangumiException>()));
      expect(await service.search(const MetaQuery(title: 'x')), isEmpty);
      expect(requests, 0);
    });
  });
}

/// 只观察缓存访问边界，不创建真实缓存文件。
class _CacheProbeDirectory implements Directory {
  _CacheProbeDirectory({this.allowRead = false});
  final bool allowRead;
  int pathReads = 0;
  int creates = 0;

  @override
  String get path {
    pathReads++;
    if (!allowRead) throw StateError('缓存不应被读取');
    return '/nonexistent-bangumi-boundary-cache';
  }

  @override
  Future<Directory> create({bool recursive = false}) async {
    creates++;
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 取 `infobox` 中「别名」的第一项（`value` 是 List 的形态）。
String aliasOf(Map<String, Object?> subject) {
  final infobox = subject['infobox'];
  if (infobox is! List) return '';
  for (final item in infobox) {
    if (item is! Map || item['key'] != '别名') continue;
    final value = item['value'];
    if (value is! List || value.isEmpty) return '';
    final first = value.first;
    if (first is! Map) return '';
    final alias = first['v'];
    return alias is String ? alias : '';
  }
  return '';
}
