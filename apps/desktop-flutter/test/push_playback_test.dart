/// 推送落地（`AppState`）：待播请求、本地路径、剧名自动匹配与守卫。
///
/// 对应验收门（`docs/superpowers/plans/2026-11-20-push-receive-and-title.md`）：
/// 3. 历史/标题用剧名；4. 守卫放行且 TMDB 已配置时恰好一次匹配，未配置/守卫
/// 不放行时**零请求**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/push_parser.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/tmdb_stores.dart';
import 'package:webhtv_pc/state/app_state.dart';

/// TMDB 搜索固定返回一部剧；其它路径 404（证明"没有多余请求"）。
class FakeTmdbClient extends http.BaseClient {
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final path = request.url.path;
    if (path.endsWith('/search/multi')) {
      final body = jsonEncode({
        'page': 1,
        'results': [
          {
            'id': 95396,
            'media_type': 'tv',
            'name': '庆余年',
            'original_name': '庆余年',
            'first_air_date': '2019-11-26',
            'vote_average': 8.1,
            'poster_path': '/qingyu.jpg',
            'genre_ids': [18],
          },
        ],
        'total_results': 1,
      });
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (path.endsWith('/tv/95396')) {
      // 身份服务命中后会用详情富化匹配记录（海报/简介/季集）：这里也回一份，
      // 让"命中 → 海报进缓存"这条链完整成立。
      final body = jsonEncode({
        'id': 95396,
        'name': '庆余年',
        'original_name': '庆余年',
        'first_air_date': '2019-11-26',
        'vote_average': 8.1,
        'overview': '范闲的成长故事。',
        'poster_path': '/qingyu.jpg',
        'backdrop_path': '/qingyu-bd.jpg',
        'genres': [
          {'id': 18, 'name': '剧情'},
        ],
        'number_of_seasons': 2,
        'number_of_episodes': 46,
        'origin_country': ['CN'],
        'original_language': 'zh',
        'external_ids': {'imdb_id': 'tt1234567'},
      });
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"status_code":404}')),
      404,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory tempDir;
  late AppState state;
  late FakeTmdbClient tmdbClient;
  late TmdbService tmdbService;

  const tmdbConfig = TmdbConfig(
    enabled: true,
    apiKey: 'fixture-key',
    disabledSites: [],
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-push');
    tmdbClient = FakeTmdbClient();
    // 身份服务用的 config 取自状态层（saveTmdbConfig 之后才 ready），这里的
    // 注入只接管 HTTP 客户端与请求计数。
    late TmdbService service;
    service = TmdbService(config: () => tmdbConfig, client: tmdbClient);
    tmdbService = service;
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': '${tempDir.path}/webhtv-pc',
          'data': '${tempDir.path}/webhtv-pc',
          'cache': '${tempDir.path}/webhtv-pc/cache',
          'state': '${tempDir.path}/webhtv-pc/logs',
        },
      ),
      log: LogService(),
      tmdbService: tmdbService,
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('待播请求', () {
    test('远程地址 + 剧名 → 推送合成站点，壳层消费后清空', () async {
      final accepted = await state.submitPush(
        url: 'https://cdn.example/a.m3u8',
        title: '庆余年',
      );
      expect(accepted, isTrue);
      final request = state.pendingPush;
      expect(request, isNotNull);
      expect(request!.siteKey, pushSiteKey);
      expect(request.url, 'https://cdn.example/a.m3u8');
      expect(request.vodName, '庆余年');
      expect(request.title, '庆余年');
      expect(request.headers, isEmpty);
      expect(request.isLocal, isFalse);

      state.clearPendingPush();
      expect(state.pendingPush, isNull);
    });

    test('没剧名时用地址里的文件名（不是整条 URL）', () async {
      await state.submitPush(url: 'https://cdn.example/阿凡达.2009.mkv');
      expect(state.pendingPush!.vodName, '阿凡达.2009');
    });

    test('安卓同款 地址|剧名 语法同样落地', () async {
      await state.submitPush(url: 'https://cdn.example/a.m3u8|庆余年');
      expect(state.pendingPush!.vodName, '庆余年');
    });

    test('地址为空 → 不起播并给出可定位错误', () async {
      final accepted = await state.submitPush(url: '   ');
      expect(accepted, isFalse);
      expect(state.pendingPush, isNull);
      expect(state.lastError, isNotNull);
    });

    test('本地文件存在 → 沿用本地播放语义', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}本地片.mkv';
      File(path).createSync();
      final accepted = await state.submitPush(url: path, title: '阿凡达');
      expect(accepted, isTrue);
      final request = state.pendingPush!;
      expect(request.isLocal, isTrue);
      expect(request.localPath, path);
      expect(request.title, '阿凡达');
    });

    test('本地文件不存在 → 不起播并说明路径', () async {
      final path = '${tempDir.path}${Platform.pathSeparator}没有这个文件.mkv';
      final accepted = await state.submitPush(url: path);
      expect(accepted, isFalse);
      expect(state.pendingPush, isNull);
      expect(state.lastError?.userMessage, contains('本地文件不存在'));
    });
  });

  group('剧名自动匹配', () {
    test('TMDB 已配置 + 守卫放行 → 恰好一次匹配，并留下海报缓存', () async {
      expect(await state.saveTmdbConfig(tmdbConfig), isTrue);
      expect(state.tmdbConfig.isReady, isTrue);

      // 推送落地前会先给匹配一个短窗口（命中就进 TMDB 详情页），所以这里
      // `submitPush` 返回时匹配结论已经在库里了。
      await state.submitPush(
        url: 'https://cdn.example/a.m3u8',
        title: '庆余年',
      );

      final searches = tmdbClient.requests
          .where((uri) => uri.path.endsWith('/search/multi'))
          .toList();
      expect(searches, hasLength(1), reason: '一次搜索就够，不能反复搜');
      expect(searches.single.queryParameters['query'], '庆余年');
      // 匹配不挡落地：等它落库再做断言。
      await waitFor(
        () =>
            state.pushMatchedItem(
              vodId: 'https://cdn.example/a.m3u8',
              title: '庆余年',
            ) !=
            null,
      );
      expect(
        state.pushMatchedItem(
          vodId: 'https://cdn.example/a.m3u8',
          title: '庆余年',
        )?.title,
        '庆余年',
        reason: '历史/海报要用这份结论',
      );
      expect(
        state.cachedTmdbPosterUrl(
          siteKey: pushSiteKey,
          vodId: 'https://cdn.example/a.m3u8',
        ),
        contains('qingyu.jpg'),
        reason: '历史卡片补图读的就是这份缓存',
      );
    });

    test('没填剧名 → 零请求（拿地址搜 TMDB 是白烧）', () async {
      await state.saveTmdbConfig(tmdbConfig);
      await state.submitPush(url: 'https://cdn.example/a.m3u8');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(tmdbClient.requests, isEmpty);
    });

    test('通用标题（推送/在线视频）→ 守卫不放行，零请求', () async {
      await state.saveTmdbConfig(tmdbConfig);
      for (final title in ['推送', '在线视频', 'video']) {
        await state.submitPush(url: 'https://cdn.example/a.m3u8', title: title);
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(tmdbClient.requests, isEmpty);
    });

    test('TMDB 未配置 → 零请求且不抛错', () async {
      await state.submitPush(url: 'https://cdn.example/a.m3u8', title: '庆余年');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(tmdbClient.requests, isEmpty);
      expect(state.lastError, isNull);
      expect(state.pendingPush, isNotNull);
    });
  });

  group('推送匹配结论查找（兼容旧 id / 带后缀片名）', () {
    test('id 少 scheme、片名带后缀时也能命中', () {
      DatabaseTmdbMatchStore(
        database: state.database!,
        configId: state.tmdbConfigId,
      ).putAuto(
        siteKey: pushSiteKey,
        vodId: 'https://pan.baidu.com/s/abc',
        sourceTitle: '罪蓝之路',
        matchedAt: 1,
        item: const TmdbItem(
          tmdbId: 300523,
          mediaType: TmdbMediaType.tv,
          title: '罪蓝之路',
          posterUrl: 'https://img.example/zlzl.jpg',
        ),
      );

      final byBareId = state.pushMatchedItem(
        vodId: 'pan.baidu.com/s/abc',
        title: '罪蓝之路',
      );
      expect(byBareId?.posterUrl, 'https://img.example/zlzl.jpg');

      final bySuffixedTitle = state.pushMatchedItem(
        vodId: 'pan.baidu.com/s/abc',
        title: '罪蓝之路 4K内嵌中字',
      );
      expect(bySuffixedTitle?.title, '罪蓝之路');
    });
  });
}
