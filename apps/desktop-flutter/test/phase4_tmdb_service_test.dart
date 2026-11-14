/// Phase 4 · TMDB HTTP 服务与缓存（`docs/phase4/design/03` §3/§4）。
///
/// 对应门禁：`docs/phase4/design/05` §4.1「鉴权形态 / 语言参数 / TTL 新鲜命中 /
/// 陈旧兜底 / refresh / 动态详情 TTL / 视频缓存分档 / 熔断（零请求）/ 熔断恢复 /
/// 按凭据隔离 / 取消不落盘 / 7 类错误映射 / 未配置零请求 / 详情回退键 /
/// 缓存不可写降级 / 单文件上限」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/services/tmdb_cache.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';

// ---------------------------------------------------------------------------
// 进程内 fake HTTP 客户端（可注入响应、计数、失败、延迟）
// ---------------------------------------------------------------------------

class _FakeResponse {
  _FakeResponse(this.statusCode, this.body);

  final int statusCode;
  final Object? body;
}

class _FakeClient extends http.BaseClient {
  _FakeClient();

  final List<Uri> requests = [];
  final List<Map<String, String>> headers = [];

  /// 路由：路径前缀 → 响应。按插入顺序首个匹配生效。
  final List<(String, _FakeResponse)> routes = [];

  /// 非空时所有请求都抛该异常（模拟网络失败）。
  Object? failure;

  /// 请求延迟（模拟超时/慢响应）。
  Duration delay = Duration.zero;

  int get count => requests.length;

  void route(String pathPrefix, Object? body, {int status = 200}) {
    routes.add((pathPrefix, _FakeResponse(status, body)));
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    headers.add(Map<String, String>.from(request.headers));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final failureLocal = failure;
    if (failureLocal != null) throw failureLocal;

    for (final (prefix, response) in routes) {
      // 用 endsWith 而不是 contains：`/episode/1/videos` 也 contains `/season/1/videos`
      // 的子串 `1/videos`，会误命中。
      if (request.url.path.endsWith(prefix)) {
        final body = response.body;
        final text = body is String ? body : jsonEncode(body);
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(text)),
          response.statusCode,
        );
      }
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{"status_code":404}')),
      404,
    );
  }
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

TmdbConfig _ready({String apiKey = 'k', String accessToken = ''}) =>
    TmdbConfig(apiKey: apiKey, accessToken: accessToken);

const _tvItem = TmdbItem(tmdbId: 1399, mediaType: TmdbMediaType.tv, title: '剧名');

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('webhtv_tmdb_svc_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TmdbCache cache() => TmdbCache(cacheDir: tempDir.path);

  group('鉴权形态（§3.6）', () {
    test('有 accessToken → Authorization: Bearer，且不带 api_key', () async {
      final client = _FakeClient()..route('/configuration', {'images': {}});
      final service = TmdbService(
        config: () => _ready(apiKey: 'k', accessToken: 'a.b.c'),
        client: client,
      );
      await service.configuration();
      expect(client.count, 1);
      expect(client.headers.first['Authorization'], 'Bearer a.b.c');
      expect(client.requests.first.queryParameters.containsKey('api_key'), isFalse);
    });

    test('无 accessToken → api_key query，且无 Authorization', () async {
      final client = _FakeClient()..route('/configuration', {'images': {}});
      final service = TmdbService(
        config: () => _ready(apiKey: 'my-key'),
        client: client,
      );
      await service.configuration();
      expect(client.count, 1);
      expect(client.headers.first.containsKey('Authorization'), isFalse);
      expect(client.requests.first.queryParameters['api_key'], 'my-key');
    });

    test('语言参数与 include_image_language 正确拼接', () async {
      final client = _FakeClient()..route('/tv/1399', {'id': 1399});
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'k', language: 'zh-CN'),
        client: client,
      );
      await service.detail(_tvItem);
      final query = client.requests.first.queryParameters;
      expect(query['language'], 'zh-CN');
      expect(query['include_image_language'], 'zh-CN,null');
    });

    test('append_to_response 按媒体类型组合', () async {
      final client = _FakeClient()..route('/tv/1399', {'id': 1399});
      final service = TmdbService(config: () => _ready(), client: client);
      await service.detail(_tvItem);
      final append = client.requests.first.queryParameters['append_to_response']!;
      expect(append, contains('aggregate_credits'));
      expect(append, contains('content_ratings'));
      expect(append, contains('recommendations'));
      expect(append, contains('similar'));
    });

    test('includeRelated=false 时不请求 recommendations/similar', () async {
      final client = _FakeClient()..route('/tv/1399', {'id': 1399});
      final service = TmdbService(config: () => _ready(), client: client);
      await service.detail(_tvItem, includeRelated: false);
      final append = client.requests.first.queryParameters['append_to_response']!;
      expect(append, isNot(contains('recommendations')));
      expect(append, isNot(contains('similar')));
    });
  });

  group('TTL 三级读路径（§3.3）', () {
    test('新鲜命中不发请求', () async {
      final client = _FakeClient()..route('/configuration', {'images': {}});
      final service = TmdbService(
        config: () => _ready(),
        client: client,
        cache: cache(),
      );
      await service.configuration();
      expect(client.count, 1);
      final again = TmdbService(
        config: () => _ready(),
        client: client,
        cache: cache(),
      );
      await again.configuration();
      expect(client.count, 1, reason: '第二次应命中缓存，不发请求');
      expect(again.lastSource, 'cache');
    });

    test('TTL 过期后重新请求', () async {
      final client = _FakeClient()..route('/configuration', {'images': {}});
      final cacheDir = tempDir.path;
      // 写入一个「很久以前」的缓存文件
      final oldCache = TmdbCache(cacheDir: cacheDir);
      oldCache.write(
        TmdbCacheType.configuration,
        _configurationKey(),
        {'images': {}},
      );
      final path = oldCache.filePath(
        TmdbCacheType.configuration,
        _configurationKey(),
      )!;
      final file = File(path);
      final payload =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      payload[tmdbCacheSavedAtField] = 0;
      file.writeAsStringSync(jsonEncode(payload));

      final service = TmdbService(
        config: () => _ready(),
        client: client,
        cache: TmdbCache(cacheDir: cacheDir),
      );
      await service.configuration();
      expect(client.count, 1, reason: '过期缓存不应命中新鲜路径');
      expect(service.lastSource, 'network');
    });

    test('网络失败时回退到陈旧缓存', () async {
      final cacheDir = tempDir.path;
      // 先写一份缓存
      final warm = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..route('/configuration', {'images': {}}),
        cache: TmdbCache(cacheDir: cacheDir),
      );
      await warm.configuration();

      // 让缓存看起来过期
      final cache = TmdbCache(cacheDir: cacheDir);
      final path =
          cache.filePath(TmdbCacheType.configuration, _configurationKey())!;
      final file = File(path);
      final payload =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      payload[tmdbCacheSavedAtField] = 0;
      file.writeAsStringSync(jsonEncode(payload));

      // 网络失败
      final failing = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..failure = const SocketException('no network'),
        cache: TmdbCache(cacheDir: cacheDir),
      );
      final body = await failing.configuration();
      expect(body.containsKey('images'), isTrue);
      expect(failing.lastSource, 'stale-cache');
    });

    test('网络失败且无缓存时抛原始错误', () async {
      final service = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..failure = const SocketException('no network'),
        cache: cache(),
      );
      await expectLater(
        service.configuration(),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.tmdbNetwork),
        ),
      );
    });

    test('refresh=true 跳过新鲜命中并走网络', () async {
      final cacheDir = tempDir.path;
      final warmClient = _FakeClient()
        ..route('/tv/1399', {'id': 1399, 'name': 'X'});
      final warm = TmdbService(
        config: () => _ready(),
        client: warmClient,
        cache: TmdbCache(cacheDir: cacheDir),
      );
      await warm.detail(_tvItem);
      expect(warmClient.count, 1);

      // 不 refresh：命中缓存，零请求
      final cachedClient = _FakeClient();
      final cached = TmdbService(
        config: () => _ready(),
        client: cachedClient,
        cache: TmdbCache(cacheDir: cacheDir),
      );
      await cached.detail(_tvItem);
      expect(cachedClient.count, 0);
      expect(cached.lastSource, 'cache');

      // refresh=true 强制走网络（即使缓存新鲜）
      final refreshClient = _FakeClient()
        ..route('/tv/1399', {'id': 1399, 'name': 'X2'});
      final refreshing = TmdbService(
        config: () => _ready(),
        client: refreshClient,
        cache: TmdbCache(cacheDir: cacheDir),
      );
      final body = await refreshing.detail(_tvItem, refresh: true);
      expect(refreshClient.count, 1, reason: 'refresh=true 必须走网络');
      expect(refreshing.lastSource, 'network');
      expect(body['name'], 'X2');
    });

    test('详情回退键：includeRelated=false 可命中 true 的缓存', () async {
      final cacheDir = tempDir.path;
      final fullClient = _FakeClient()
        ..route('/tv/1399', {'id': 1399, 'name': 'X'});
      // 确保 fake client 对详情路由有响应（避免 404）
      final full = TmdbService(
        config: () => _ready(),
        client: fullClient,
        cache: TmdbCache(cacheDir: cacheDir),
      );
      await full.detail(_tvItem, includeRelated: true);
      expect(fullClient.count, 1);

      final partialClient = _FakeClient();
      final partial = TmdbService(
        config: () => _ready(),
        client: partialClient,
        cache: TmdbCache(cacheDir: cacheDir),
      );
      final body = await partial.detail(_tvItem, includeRelated: false);
      expect(
        partialClient.count,
        0,
        reason: '应命中 includeRelated=true 的缓存，不发请求',
      );
      expect(partial.lastSource, 'cache');
      expect(body['name'], 'X');
      // 缓存目录里应只有一个详情文件（回退键没有产生新写入）
      expect(TmdbCache(cacheDir: cacheDir).fileCount(), 1);
    });

    test('动态详情 TTL：含 next_episode_to_air 时用短 TTL', () async {
      final cacheDir = tempDir.path;
      final client = _FakeClient()
        ..route('/tv/1399', {
          'id': 1399,
          'next_episode_to_air': {'season_number': 2, 'episode_number': 1},
        });
      final service = TmdbService(
        config: () => _ready(),
        client: client,
        cache: TmdbCache(cacheDir: cacheDir),
      );
      await service.detail(_tvItem);
      // 把写入时间设为 2 天前：短 TTL（1 天）已过期 → 必须重新请求
      final cache = TmdbCache(cacheDir: cacheDir);
      // 找出服务实际写入的那个缓存文件（键为真实 URI）
      final dir = Directory(cache.directory!) ;
      final detailFiles = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('detail_'))
          .toList();
      expect(detailFiles.length, 1, reason: '应恰好写入一个详情缓存文件');
      final file = detailFiles.first;
      final payload =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      payload[tmdbCacheSavedAtField] = DateTime.now()
          .subtract(const Duration(days: 2))
          .millisecondsSinceEpoch;
      file.writeAsStringSync(jsonEncode(payload));

      final againClient = _FakeClient()
        ..route('/tv/1399', {
          'id': 1399,
          'next_episode_to_air': {'season_number': 2, 'episode_number': 1},
        });
      final again = TmdbService(
        config: () => _ready(),
        client: againClient,
        cache: TmdbCache(cacheDir: cacheDir),
      );
      await again.detail(_tvItem);
      expect(againClient.count, 1, reason: '短 TTL 已过期，必须重新请求');
    });
  });

  group('鉴权熔断（§3.4）', () {
    test('401 触发熔断；熔断期内零请求', () async {
      var now = DateTime(2026, 1, 1, 12);
      final client = _FakeClient()
        ..route('/configuration', {'status_code': 7}, status: 401);
      final service = TmdbService(
        config: () => _ready(),
        client: client,
        clock: () => now,
      );

      await expectLater(service.configuration(), throwsA(isA<TmdbAuthException>()));
      expect(client.count, 1);
      expect(service.isAuthBlocked(_ready()), isTrue);

      // 熔断期内再次请求 → 零网络
      await expectLater(service.configuration(), throwsA(isA<TmdbAuthException>()));
      expect(client.count, 1, reason: '熔断期内不得发请求');

      // 冷却到期后恢复
      now = now.add(const Duration(minutes: 6));
      expect(service.isAuthBlocked(_ready()), isFalse);
      await expectLater(service.configuration(), throwsA(isA<TmdbAuthException>()));
      expect(client.count, 2, reason: '冷却到期后应恢复请求');
    });

    test('403 同样触发熔断', () async {
      final client = _FakeClient()
        ..route('/configuration', {'status_code': 7}, status: 403);
      final service = TmdbService(config: () => _ready(), client: client);
      await expectLater(service.configuration(), throwsA(isA<TmdbAuthException>()));
      expect(service.isAuthBlocked(_ready()), isTrue);
    });

    test('熔断按凭据隔离：换 Key 后立即可用', () async {
      final client = _FakeClient()
        ..route('/configuration', {'status_code': 7}, status: 401);
      var config = _ready(apiKey: 'bad');
      final service = TmdbService(config: () => config, client: client);
      await expectLater(service.configuration(), throwsA(isA<TmdbAuthException>()));
      expect(service.isAuthBlocked(config), isTrue);

      // 换 Key
      config = _ready(apiKey: 'good');
      expect(service.isAuthBlocked(config), isFalse);
    });

    test('鉴权失败不做陈旧兜底（否则掩盖配置问题）', () async {
      final cacheDir = tempDir.path;
      final cache = TmdbCache(cacheDir: cacheDir);
      final warm = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..route('/configuration', {'images': {}}),
        cache: cache,
      );
      await warm.configuration();

      // 把缓存改旧，确保失败客户端会真的走网络（否则会命中新鲜缓存）
      final path = cache.filePath(
        TmdbCacheType.configuration,
        _configurationKey(),
      )!;
      final file = File(path);
      final payload =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      payload[tmdbCacheSavedAtField] = 0;
      file.writeAsStringSync(jsonEncode(payload));

      final failing = TmdbService(
        config: () => _ready(),
        client: _FakeClient()
          ..route('/configuration', {'status_code': 7}, status: 401),
        cache: TmdbCache(cacheDir: cacheDir),
      );
      await expectLater(
        failing.configuration(),
        throwsA(isA<TmdbAuthException>()),
        reason: '鉴权失败必须抛出，不能被陈旧兜底掩盖',
      );
    });
  });

  group('取消语义（§3.5）', () {
    test('取消时抛 TmdbCancelledException 且不写缓存', () async {
      final client = _FakeClient()
        ..route('/configuration', {'images': {}})
        ..delay = const Duration(milliseconds: 50);
      final cacheDir = tempDir.path;
      final service = TmdbService(
        config: () => _ready(),
        client: client,
        cache: TmdbCache(cacheDir: cacheDir),
      );
      final token = TmdbCancellationToken();
      final future = service.configuration(cancel: token);
      token.cancel();
      await expectLater(future, throwsA(isA<TmdbCancelledException>()));
      // 不写缓存
      expect(TmdbCache(cacheDir: cacheDir).fileCount(), 0);
    });

    test('已取消的令牌在请求前直接抛出（零请求）', () async {
      final client = _FakeClient()..route('/configuration', {'images': {}});
      final service = TmdbService(config: () => _ready(), client: client);
      final token = TmdbCancellationToken()..cancel();
      await expectLater(
        service.configuration(cancel: token),
        throwsA(isA<TmdbCancelledException>()),
      );
      expect(client.count, 0);
    });
  });

  group('错误映射（§4.5）', () {
    test('未配置 → tmdbNotConfigured 且零请求', () async {
      final client = _FakeClient()..route('/configuration', {'images': {}});
      final service = TmdbService(
        config: () => const TmdbConfig(),
        client: client,
      );
      await expectLater(
        service.configuration(),
        throwsA(
          isA<AppError>().having(
            (e) => e.kind,
            'kind',
            AppErrorKind.tmdbNotConfigured,
          ),
        ),
      );
      expect(client.count, 0, reason: '未配置时禁止发请求');
    });

    test('enabled=false 等同未配置', () async {
      final client = _FakeClient()..route('/configuration', {'images': {}});
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'k', enabled: false),
        client: client,
      );
      await expectLater(
        service.configuration(),
        throwsA(isA<AppError>()),
      );
      expect(client.count, 0);
    });

    test('500 → tmdbHttp 且 retryable', () async {
      final service = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..route('/configuration', {'x': 1}, status: 500),
      );
      await expectLater(
        service.configuration(),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.tmdbHttp)
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('404 → tmdbHttp 且不可重试', () async {
      final service = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..route('/configuration', {'x': 1}, status: 404),
      );
      await expectLater(
        service.configuration(),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.tmdbHttp)
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('非法 JSON → tmdbDecode', () async {
      final service = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..route('/configuration', 'not json'),
      );
      await expectLater(
        service.configuration(),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.tmdbDecode),
        ),
      );
    });

    test('JSON 非对象 → tmdbDecode', () async {
      final service = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..route('/configuration', [1, 2, 3]),
      );
      await expectLater(
        service.configuration(),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.tmdbDecode),
        ),
      );
    });

    test('缺必需字段 → tmdbEmpty', () async {
      final service = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..route('/configuration', {'other': 1}),
      );
      await expectLater(
        service.configuration(),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.tmdbEmpty),
        ),
      );
    });

    test('网络异常 → tmdbNetwork 且 retryable', () async {
      final service = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..failure = const SocketException('boom'),
      );
      await expectLater(
        service.configuration(),
        throwsA(
          isA<AppError>()
              .having((e) => e.kind, 'kind', AppErrorKind.tmdbNetwork)
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('超时 → tmdbNetwork 且 retryable', () async {
      final service = TmdbService(
        config: () => _ready(),
        client: _FakeClient()..delay = const Duration(milliseconds: 200),
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        service.configuration(),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.tmdbNetwork),
        ),
      );
    });

    test('详情缺身份 → tmdbEmpty', () async {
      final service = TmdbService(
        config: () => _ready(),
        client: _FakeClient(),
      );
      await expectLater(
        service.detail(const TmdbItem(tmdbId: 0, mediaType: TmdbMediaType.tv, title: 'X')),
        throwsA(
          isA<AppError>().having((e) => e.kind, 'kind', AppErrorKind.tmdbEmpty),
        ),
      );
    });

    test('全部 tmdb* 错误文案含「不影响站源浏览与播放」', () {
      for (final kind in tmdbErrorKinds) {
        expect(
          describeErrorKind(kind),
          contains('不影响站源浏览与播放'),
          reason: kind.name,
        );
      }
    });

    test('isTmdbError 只认 tmdb* 前缀', () {
      expect(
        isTmdbError(AppError(AppErrorKind.tmdbNetwork, 'x')),
        isTrue,
      );
      for (final kind in tmdbErrorKinds) {
        expect(isTmdbError(AppError(kind, 'x')), isTrue, reason: kind.name);
      }
      expect(isTmdbError(AppError(AppErrorKind.siteNetwork, 'x')), isFalse);
      expect(isTmdbError(AppError(AppErrorKind.subtitleHttp, 'x')), isFalse);
      expect(isTmdbError('string error'), isFalse);
      expect(isTmdbError(null), isFalse);
    });
  });

  group('缓存降级与上限（§6.4）', () {
    test('cacheDir 为空 → 降级为不缓存，主流程不受影响', () async {
      final client = _FakeClient()..route('/configuration', {'images': {}});
      final service = TmdbService(
        config: () => _ready(),
        client: client,
        cache: TmdbCache(cacheDir: null),
      );
      final body = await service.configuration();
      expect(body.containsKey('images'), isTrue);
      expect(client.count, 1);
    });

    test('目录不可写 → 降级，写返回 false 且不抛异常', () {
      final cache = TmdbCache(cacheDir: '\u0000invalid\u0000path');
      expect(cache.write(TmdbCacheType.search, 'k', {'a': 1}), isFalse);
      expect(cache.lastError, isNotNull);
    });

    test('单文件超过上限 → 拒绝写入', () {
      final cache = TmdbCache(cacheDir: tempDir.path, maxFileBytes: 32);
      expect(
        cache.write(TmdbCacheType.search, 'k', {'big': 'x' * 200}),
        isFalse,
      );
      expect(cache.lastError, contains('上限'));
    });

    test('clear 删除缓存目录', () {
      final cache = TmdbCache(cacheDir: tempDir.path);
      cache.write(TmdbCacheType.search, 'k', {'a': 1});
      expect(cache.fileCount(), 1);
      expect(cache.clear(), isTrue);
      expect(cache.fileCount(), 0);
    });
  });

  group('搜索与归一化（§4.2）', () {
    test('search 过滤 person，构造 TmdbItem', () async {
      final client = _FakeClient()
        ..route('/search/multi', {
          'results': [
            {
              'id': 1399,
              'media_type': 'tv',
              'name': '示例剧集',
              'first_air_date': '2024-03-01',
              'vote_average': 8.2,
              'poster_path': '/p.jpg',
              'original_language': 'zh',
              'origin_country': ['CN'],
              'genre_ids': [18],
            },
            {'id': 287, 'media_type': 'person', 'name': '演员'},
            {
              'id': 550,
              'media_type': 'movie',
              'title': '示例电影',
              'release_date': '2023-06-15',
            },
          ],
        });
      final service = TmdbService(config: () => _ready(), client: client);
      final items = await service.search('示例');
      expect(items.length, 2);
      expect(items[0].identity?.key, 'tv:1399');
      expect(items[0].subtitle, '2024 · 8.2');
      expect(items[0].posterUrl, contains('/p.jpg'));
      expect(items[1].identity?.key, 'movie:550');
    });

    test('search 空关键词不发请求', () async {
      final client = _FakeClient();
      final service = TmdbService(config: () => _ready(), client: client);
      expect(await service.search('   '), isEmpty);
      expect(client.count, 0);
    });

    test('related 分页使用 cacheKeySuffix', () async {
      final client = _FakeClient()
        ..route('/recommendations', {'results': [], 'page': 1})
        ..route('/similar', {'results': [], 'page': 1});
      final service = TmdbService(
        config: () => _ready(),
        client: client,
        cache: cache(),
      );
      await service.related(_tvItem, recommendations: true, page: 1);
      await service.related(_tvItem, recommendations: true, page: 2);
      expect(client.count, 2, reason: '不同页应有不同缓存键');
      expect(client.requests[0].queryParameters['page'], '1');
      expect(client.requests[1].queryParameters['page'], '2');
    });
  });

  group('解析辅助（§4.2）', () {
    test('cast：电影取 credits.cast，剧集取 aggregate_credits.cast', () {
      final service = TmdbService(config: () => _ready(), client: _FakeClient());
      final tv = service.cast({
        'aggregate_credits': {
          'cast': [
            {
              'id': 287,
              'name': '演员',
              'roles': [
                {'character': '主角'},
              ],
            },
          ],
        },
      });
      expect(tv.length, 1);
      expect(tv.first.subtitle, '主角');
      final movie = service.cast({
        'credits': {
          'cast': [
            {'id': 288, 'name': '演员2', 'character': '配角'},
          ],
        },
      });
      expect(movie.length, 1);
      expect(movie.first.subtitle, '配角');
    });

    test('creators 取 created_by', () {
      final service = TmdbService(config: () => _ready(), client: _FakeClient());
      final creators = service.creators({
        'created_by': [
          {'id': 500, 'name': '导演'},
        ],
      });
      expect(creators.length, 1);
      expect(creators.first.name, '导演');
    });

    test('episodeGuests 取 guest_stars', () {
      final service = TmdbService(config: () => _ready(), client: _FakeClient());
      final guests = service.episodeGuests({
        'guest_stars': [
          {'id': 288, 'name': '客串', 'character': '客串角色'},
        ],
      });
      expect(guests.length, 1);
      expect(guests.first.subtitle, '客串角色');
    });

    test('translatedOverview 优先取偏好语言翻译', () {
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'k', language: 'zh-CN'),
        client: _FakeClient(),
      );
      expect(
        service.translatedOverview({
          'overview': '原始简介',
          'translations': {
            'translations': [
              {
                'iso_639_1': 'en',
                'data': {'overview': 'English'},
              },
              {
                'iso_639_1': 'zh',
                'data': {'overview': '中文简介'},
              },
            ],
          },
        }),
        '中文简介',
      );
    });

    test('translatedOverview 无匹配翻译时回退 overview', () {
      final service = TmdbService(
        config: () => const TmdbConfig(apiKey: 'k', language: 'zh-CN'),
        client: _FakeClient(),
      );
      expect(
        service.translatedOverview({'overview': '原始简介'}),
        '原始简介',
      );
      expect(service.translatedOverview({}), isNull);
    });

    test('photos 方向回退', () {
      final service = TmdbService(config: () => _ready(), client: _FakeClient());
      final photos = service.photos(
        {
          'images': {
            'backdrops': [
              {'file_path': '/b.jpg', 'width': 1920, 'height': 1080},
            ],
          },
        },
        preferLandscape: true,
      );
      expect(photos.length, 1);
      expect(photos.first, contains('/b.jpg'));
    });
  });

  group('视频聚合（§7.1）', () {
    test('聚合 movie/tv/season/episode 并去重排序', () async {
      final client = _FakeClient()
        ..route('/episode/2/videos', {
          'results': [
            {'key': 'epi', 'site': 'YouTube', 'name': '单集预告', 'type': 'Trailer'},
          ],
        })
        ..route('/season/1/videos', {
          'results': [
            {'key': 'sea', 'site': 'YouTube', 'name': '季预告', 'type': 'Trailer'},
          ],
        })
        ..route('/tv/1399/videos', {
          'results': [
            {'key': 'tv', 'site': 'YouTube', 'name': '剧预告', 'type': 'Trailer'},
            {'key': 'epi', 'site': 'YouTube', 'name': '重复', 'type': 'Clip'},
          ],
        });
      final service = TmdbService(
        config: () => _ready(),
        client: client,
        cache: cache(),
      );
      final videos = await service.videos(_tvItem, seasonNumber: 1, episodeNumber: 2);
      // episode(rank 0) + season(rank 1) + tv(rank 2)；tv 里的重复 epi 被去重
      expect(videos.length, 3);
      expect(videos.map((v) => v.key), ['epi', 'sea', 'tv']);
      expect(videos.first.scope, TmdbVideoScope.episode);
      expect(videos[1].scope, TmdbVideoScope.season);
      expect(videos.last.scope, TmdbVideoScope.tv);
    });

    test('单作用域失败不阻塞其他作用域', () async {
      final client = _FakeClient()
        // episode 与 season 路由缺失 → 404
        ..route('/tv/1399/videos', {
          'results': [
            {'key': 'tv', 'site': 'YouTube', 'name': '剧预告', 'type': 'Trailer'},
          ],
        });
      final service = TmdbService(
        config: () => _ready(),
        client: client,
        cache: cache(),
      );
      final videos = await service.videos(_tvItem, seasonNumber: 1, episodeNumber: 2);
      expect(videos.length, 1);
      expect(videos.first.key, 'tv');
    });

    test('取消在视频聚合中向上传播', () async {
      final client = _FakeClient()..route('/videos', {'results': []});
      final service = TmdbService(config: () => _ready(), client: client);
      final token = TmdbCancellationToken()..cancel();
      await expectLater(
        service.videos(_tvItem, cancel: token),
        throwsA(isA<TmdbCancelledException>()),
      );
    });
  });

  group('TmdbCache 单元（§3.2/§6.4）', () {
    test('filePath 使用 md5 且带类型前缀', () {
      final cache = TmdbCache(cacheDir: tempDir.path);
      final path = cache.filePath(TmdbCacheType.search, 'some-key')!;
      expect(p.basename(path), startsWith('search_'));
      expect(p.basename(path), endsWith('.json'));
      // 同一 key 稳定
      expect(cache.filePath(TmdbCacheType.search, 'some-key'), path);
      // 不同 key 不同
      expect(cache.filePath(TmdbCacheType.search, 'other'), isNot(path));
    });

    test('readFresh / readAny 语义差异', () {
      final cache = TmdbCache(cacheDir: tempDir.path);
      cache.write(TmdbCacheType.search, 'k', {'a': 1});
      expect(cache.readFresh(TmdbCacheType.search, 'k', const Duration(days: 1)), isNotNull);
      expect(
        cache.readFresh(TmdbCacheType.search, 'k', Duration.zero),
        anyOf(isNull, isA<TmdbCacheHit>()),
      );
      expect(cache.readAny(TmdbCacheType.search, 'k'), isNotNull);
      expect(cache.readAny(TmdbCacheType.search, 'missing'), isNull);
    });

    test('readFirstFresh 按顺序取首个新鲜命中', () {
      final cache = TmdbCache(cacheDir: tempDir.path);
      cache.write(TmdbCacheType.detail, 'second', {'v': 2});
      final hit = cache.readFirstFresh(
        TmdbCacheType.detail,
        ['first', 'second'],
        null,
        const Duration(days: 7),
      );
      expect(hit?.payload['v'], 2);
    });

    test('readFirstAny 在全部未命中时返回 null', () {
      final cache = TmdbCache(cacheDir: tempDir.path);
      expect(
        cache.readFirstAny(TmdbCacheType.detail, ['a', 'b']),
        isNull,
      );
    });

    test('缓存 payload 不泄漏内部 __mtime 字段', () {
      final cache = TmdbCache(cacheDir: tempDir.path);
      cache.write(TmdbCacheType.search, 'k', {'a': 1});
      final hit = cache.readAny(TmdbCacheType.search, 'k')!;
      expect(hit.payload.containsKey('__mtime'), isFalse);
      expect(hit.payload['a'], 1);
    });
  });
}

// ---------------------------------------------------------------------------
// 缓存键复现（与 service 内部生成方式一致）
// ---------------------------------------------------------------------------

String _configurationKey() =>
    Uri.parse('https://api.tmdb.org/3/configuration')
        .replace(queryParameters: {'language': 'zh-CN', 'api_key': 'k'})
        .toString();

