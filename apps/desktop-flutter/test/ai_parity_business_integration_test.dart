import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/ai_content/recommendation.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/services/ai_content/ai_content_completion.dart';
import 'package:webhtv_pc/services/ai_content/ai_content_paths.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/services/proxy_server.dart';
import 'package:webhtv_pc/core/proxy_policy.dart';

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ad_rules.dart';
import 'package:webhtv_pc/core/ai_content/ad_rule_validation.dart';
import 'package:webhtv_pc/core/ai_content/group_rule_validation.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/site_group_rules.dart';
import 'package:webhtv_pc/services/ai_integration.dart';
import 'package:webhtv_pc/services/ai_content/ad_rule_service.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/sync_state.dart';
import 'package:webhtv_pc/services/sync_client.dart';

void main() {
  integratedServiceTests();
  consumerContractTests();
  test('AI分组替换只动AI规则，手工与内置开关保留', () {
    final original = SiteGroupSettings(
      rules: [
        builtinSiteGroupRules.first.copyWith(enabled: false),
        const SiteGroupRule(id: 'manual', name: '手工', pattern: r'^(手工)'),
        const SiteGroupRule(id: 'ai-content-0', name: '旧AI', pattern: r'^(旧)'),
      ],
    );
    final result = mergeAiGroupRules(original, const [
      GroupRuleProposal(name: '新AI', regex: r'^(新)', reason: '重复覆盖'),
    ]);
    expect(result.rules.map((r) => r.id), [
      'builtin_bracket_tag',
      'manual',
      'ai-content-0',
    ]);
    expect(result.rules.first.enabled, isFalse);
    expect(result.rules.last.pattern, r'^(新)');
  });

  test('AI广告保护先于黑名单，且只作用于确认的播放清单', () {
    final rules = mergeAiAdRules(const AdRuleSet.empty(), const [
      AdRuleProposal(
        confidence: .95,
        hostsBlacklist: ['ads.test'],
        regexPatterns: [r'/advert/'],
        excludePatterns: [r'/feature/'],
      ),
    ], Uri.parse('https://media.test/feature/index.m3u8'));
    const playlist =
        '#EXTM3U\n#EXTINF:10,\nhttps://ads.test/feature/001.ts\n#EXTINF:5,\nhttps://ads.test/advert/002.ts\n#EXT-X-ENDLIST';
    final result = cleanHlsPlaylist(
      text: playlist,
      playlistUri: Uri.parse('https://media.test/feature/index.m3u8'),
      rules: rules,
    );
    expect(result.removedSegments, 1);
    expect(result.text, contains('/feature/001.ts'));
    expect(result.text, isNot(contains('/advert/002.ts')));
    expect(
      cleanHlsPlaylist(
        text: playlist,
        playlistUri: Uri.parse('https://other.test/feature/index.m3u8'),
        rules: rules,
      ).changed,
      isFalse,
    );
    expect(rules.isAdHost('ads.test'), isFalse, reason: 'AI主机规则不能成为全局请求拒绝');
  });

  test('采集真实HLS仅计EXTINF媒体切片，不把master/key当证据', () {
    final evidence = collectAdPlaylistEvidence(
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:8,\none.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:5,\nhttps://ads.test/ad.ts\n',
      Uri.parse('https://media.test/main/index.m3u8'),
    );
    expect(evidence.segments, [
      'https://media.test/main/one.ts',
      'https://ads.test/ad.ts',
    ]);
    expect(evidence.durations, [8, 5]);
    expect(evidence.discontinuities, [1]);
    expect(
      collectAdPlaylistEvidence(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=123\nchild.m3u8',
        Uri.parse('https://media.test/index.m3u8'),
      ).isEmpty,
      isTrue,
    );
  });

  test('安卓AI开关消费与prompt(trim后)/key/未知字段重启保真', () async {
    final temp = await Directory.systemTemp.createTemp('parity-sync-');
    final paths = AppPaths.resolve(
      overrides: {
        'config': '${temp.path}/config',
        'data': '${temp.path}/data',
        'cache': '${temp.path}/cache',
        'state': '${temp.path}/log',
      },
    );
    final state = AppState(paths: paths, log: LogService());
    try {
      await state.bootstrap();
      final settings = SyncSettings.fromBackup({
        'prefers': {
          'ai_title_extraction': true,
          'ai_ad_detection': true,
          'ai_config': jsonEncode({
            'enabled': false,
            'apiKey': 'secret',
            'model': 'm',
            'titleExtractionPrompt': ' 原样提示词\n',
            'titleExtractionPromptCustom': true,
            'futureField': {'preserve': 1},
          }),
        },
      }, allowSensitive: true);
      expect(settings.unsupportedKeys, isNot(contains('ai_title_extraction')));
      await state.applySyncedSettings(settings);
      expect(state.aiTitleExtractionEnabled, isTrue);
      expect(state.aiAdDetectionEnabled, isTrue);
      // 安卓 AiConfig.java 与 PC ai_config.dart 的 sanitize 都对 prompt 做 trim：
      // 这里断言的是**契约一致**的 trim 结果，不是放宽保真。
      expect(state.aiConfig.titleExtractionPrompt, '原样提示词');
      expect(state.aiConfig.additionalFields['futureField'], {'preserve': 1});
      await state.saveAiConfig(state.aiConfig.copyWith(model: 'new'));
      final backup = await state.createBackup(
        outputPath: '${temp.path}/backup.zip',
      );
      expect(backup.ok, isTrue);
      await state.setAiTitleExtractionEnabled(false);
      expect(await state.restoreBackup(backup.path), isNull);
      expect(state.aiTitleExtractionEnabled, isTrue);
      expect(state.aiConfig.apiKey, 'secret');
      expect(state.aiConfig.model, 'new');
    } finally {
      state.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('映射应用保留源集顺序URL，skipped仍可播但不猜季集', () {
    final line = VodPlayLine(
      flag: '线路',
      episodes: [
        VodEpisode(name: '第一集', url: 'one'),
        VodEpisode(name: '花絮', url: 'extra'),
      ],
    );
    final enriched = applyAiEpisodeBindings(line, const {
      0: (season: 2, episode: 3),
    });
    expect(enriched.episodes.map((e) => e.url), ['one', 'extra']);
    expect(enriched.episodes.first.extra['tmdb_season_number'], 2);
    expect(enriched.episodes.first.extra['tmdb_episode_number'], 3);
    expect(enriched.episodes.last.extra['tmdb_episode_number'], isNull);
  });
}

void integratedServiceTests() {
  const ready = AiConfig(
    enabled: true,
    apiKey: 'fixture-key',
    model: 'fixture-model',
    endpoint: 'https://fixture.test/v1',
  );
  AppPaths testPaths(Directory temp) => AppPaths.resolve(
    overrides: {
      'config': '${temp.path}/config',
      'data': '${temp.path}/data',
      'cache': '${temp.path}/cache',
      'state': '${temp.path}/logs',
    },
  );

  test('真实推荐富集与当前源搜索零结果全局降级；负反馈重建服务后仍过滤缓存', () async {
    final temp = await Directory.systemTemp.createTemp('parity-rec-');
    final paths = testPaths(temp);
    final completion = AiContentCompletion(
      complete:
          ({
            required config,
            required prompt,
            timeout = const Duration(seconds: 1),
          }) async => AiCompletionResult(
            ok: true,
            statusCode: 200,
            message: '',
            text: jsonEncode({
              'items': [
                {
                  'title': '真实电影',
                  'mediaType': 'movie',
                  'year': 2024,
                  'reason': '同类',
                },
                {'title': '未命中', 'mediaType': 'tv', 'reason': '扩展'},
              ],
            }),
          ),
    );
    final client = MockClient((request) async {
      if (request.url.host == 'tmdb.test') {
        return http.Response(
          jsonEncode({
            'results': request.url.queryParameters['query'] == '真实电影'
                ? [
                    {
                      'id': 42,
                      'media_type': 'movie',
                      'title': '真实电影',
                      'release_date': '2024-01-01',
                      'vote_average': 8.2,
                      'poster_path': '/real.jpg',
                      'overview': '真实TMDB简介',
                    },
                  ]
                : [],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }
      final searching = request.url.queryParameters.containsKey('wd');
      return http.Response(
        jsonEncode({
          'class': [],
          'list': searching && request.url.path == '/b'
              ? [
                  {
                    'vod_id': 'actual-b',
                    'vod_name': '真实电影',
                    'vod_remarks': '完整',
                  },
                ]
              : [],
        }),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final tmdb = TmdbService(
      config: () => const TmdbConfig(
        enabled: true,
        apiKey: 'fixture-key',
        apiBase: 'https://tmdb.test/3',
      ),
      client: client,
    );
    final state = AppState(
      paths: paths,
      log: LogService(),
      httpClient: client,
      tmdbService: tmdb,
      aiContentCompletion: completion,
    );
    try {
      await state.bootstrap();
      await state.saveAiConfig(ready);
      await state.saveTmdbConfig(
        const TmdbConfig(
          enabled: true,
          apiKey: 'fixture-key',
          apiBase: 'https://tmdb.test/3',
        ),
      );
      await state.importConfig(
        jsonEncode({
          'name': '源',
          'sites': [
            {
              'key': 'a',
              'name': 'A',
              'type': 1,
              'api': 'https://source.test/a',
              'searchable': 1,
            },
            {
              'key': 'b',
              'name': 'B',
              'type': 1,
              'api': 'https://source.test/b',
              'searchable': 1,
            },
          ],
        }),
      );
      await state.selectSite(state.siteItems.first.site);
      // 先证明这条夹具的 TMDB 输入合同本身可命中，再断言推荐卡富集；
      // 若这里失败就是夹具，若这里通过而卡片降级才是生产富集接线。
      final direct = await tmdb.search('真实电影');
      expect(
        pickRecommendationTmdbItem(
          direct,
          '真实电影',
          TmdbMediaType.movie,
          2024,
        )?.tmdbId,
        42,
        reason: '真实 TMDB 服务 + 富集命中逻辑',
      );
      const request = RecommendationRequest(
        source: RecommendationSource.history,
        siteKey: 'a',
      );
      final result = await state.aiIntegration.recommendation.recommend(
        request: request,
      );
      expect(result.ok, isTrue);
      expect(result.value!.first.tmdbId, 42);
      expect(result.value!.first.rating, 8.2);
      expect(result.value!.first.posterUrl, contains('/real.jpg'));
      expect(result.value!.last.degraded, isTrue);
      final search = await state.searchRecommendation(
        result.value!.first.title,
      );
      expect(search!.siteKey, '');
      expect(search.totalItems, 1);
      expect(
        search.results
            .singleWhere((e) => e.siteKey == 'b')
            .result!
            .list
            .single
            .vodId,
        'actual-b',
      );
      final feedback = await state.aiIntegration.recommendation
          .markNotInterested(result.value!.first);
      expect(feedback.ok, isTrue);
      final rebuilt = AiIntegration(
        paths: paths,
        config: () => ready,
        titleEnabled: () => false,
        log: LogService(),
        completion: completion,
      );
      final after = await rebuilt.recommendation.recommend(request: request);
      expect(after.value!.map((card) => card.title), ['未命中']);
    } finally {
      state.dispose();
      client.close();
      await temp.delete(recursive: true);
    }
  });

  test('备份恢复四域未知字段与阅读器偏好精确值；模型缓存不入包', () async {
    final temp = await Directory.systemTemp.createTemp('parity-backup-');
    final paths = testPaths(temp);
    final state = AppState(paths: paths, log: LogService());
    try {
      await state.bootstrap();
      final content = AiContentPaths.of(paths);
      await Directory(content.dataDir).create(recursive: true);
      final payload = {
        'recommendation_feedback.json': {
          'entries': [
            {
              'title': '不感兴趣电影',
              'mediaType': 'movie',
              'createdAtMs': DateTime.now().millisecondsSinceEpoch,
              'future': 'keep-entry',
            },
          ],
          'futureRoot': {'a': 1},
        },
        'title_learning.json': {'examples': [], 'futureLearning': true},
        'group_rules.json': {
          'rules': [
            {'name': '分组', 'regex': r'^(盘)', 'reason': '手工确认'},
          ],
          'futureGroup': [1, 2],
        },
        'ad_rules.json': {
          'rules': [
            {
              'confidence': .95,
              'hostsBlacklist': ['ads.test'],
              'regexPatterns': [r'/advert/'],
              'excludePatterns': [r'/feature/'],
              'reasoning': '候选',
            },
          ],
          'futureAd': 'retained',
        },
      };
      for (final entry in payload.entries) {
        await File('${content.dataDir}/${entry.key}')
            .writeAsString(jsonEncode(entry.value));
      }
      await File('${paths.configDir}/reader_tts.json').writeAsString(
        '{"source":"system","timerMinutes":120,"futureReader":7}',
      );
      final cached = File('${content.cacheDir}/model.bin');
      await cached.parent.create(recursive: true);
      await cached.writeAsString('rebuild');
      final result = await state.createBackup(
        outputPath: '${temp.path}/all.zip',
      );
      expect(result.ok, isTrue);
      expect(
        result.manifest!.entries.map((e) => e.path),
        containsAll(['ai-user-data.json', 'reader.json']),
      );
      expect(
        result.manifest!.entries
            .map((e) => e.path)
            .any((p) => p.contains('model')),
        isFalse,
      );
      await File(content.feedbackPath).writeAsString('{"entries":[]}');
      await File('${paths.configDir}/reader_tts.json').writeAsString('{}');
      expect(await state.restoreBackup(result.path), isNull);
      for (final entry in payload.entries) {
        expect(
          jsonDecode(
            await File('${content.dataDir}/${entry.key}').readAsString(),
          ),
          entry.value,
        );
      }
      expect(
        jsonDecode(
          await File('${paths.configDir}/reader_tts.json').readAsString(),
        ),
        {'source': 'system', 'timerMinutes': 120, 'futureReader': 7},
      );
      expect(await state.aiIntegration.ad.loadCandidates(), hasLength(1));
      expect(
        state.aiPlaylistFor('any'),
        isNull,
        reason: '备份中的广告只是候选，不授予当前播放权限',
      );
      final pushed = await state.exportSyncedSettings(allowSensitive: false);
      expect(pushed.keys, isNot(contains('ai_config')));
      expect(pushed.keys, isNot(contains('ai_user_data')));
      expect(
        (await state.exportSyncedSettings(
          allowSensitive: true,
        ))['ai_user_data'],
        isNotEmpty,
      );
    } finally {
      state.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('坏用户域/路径/版本导入拒绝且旧用户文件保持精确内容', () async {
    final temp = await Directory.systemTemp.createTemp('parity-bad-import-');
    final paths = testPaths(temp);
    await importAiUserFiles(
      paths,
      jsonEncode({
        'schemaVersion': 1,
        'files': {
          'title_learning.json': {'examples': [], 'preserve': 42},
        },
      }),
    );
    final old = await File(AiContentPaths.of(paths).learningPath)
        .readAsString();
    for (final payload in [
      {'schemaVersion': 2, 'files': {}},
      {
        'schemaVersion': 1,
        'files': {
          '../settings.json': {'rules': []},
        },
      },
      {
        'schemaVersion': 1,
        'files': {
          'title_learning.json': {'examples': 'bad'},
        },
      },
    ]) {
      await expectLater(
        importAiUserFiles(paths, jsonEncode(payload)),
        throwsFormatException,
      );
    }
    expect(
      await File(AiContentPaths.of(paths).learningPath).readAsString(),
      old,
    );
    await temp.delete(recursive: true);
  });

  test('真实代理切片过滤只在确认会话执行，另一个会话保持原清单', () async {
    const playlist =
        '#EXTM3U\n#EXTINF:8,\n/feature/one.ts\n#EXTINF:5,\n/advert/ad.ts\n#EXT-X-ENDLIST';
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) {
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
      );
      request.response.write(playlist);
      request.response.close();
    });
    final proxy = LocalProxyServer(
      log: LogService(),
      policy: const ProxyTargetPolicy(allowLoopback: true),
    );
    final client = HttpClient();
    try {
      await proxy.start();
      final a = proxy.sessions.create(siteKey: 'a');
      final b = proxy.sessions.create(siteKey: 'a');
      final target = Uri.parse(
        'http://127.0.0.1:${upstream.port}/feature/index.m3u8',
      );
      Future<String> read(String url) async =>
          await (await client.getUrl(Uri.parse(url)))
              .close()
              .then((r) => utf8.decoder.bind(r).join());
      // 代理会把子清单/分片重写成 `/p/<token>/<base64 target>`；
      // 断言必须解码回真实目标，不能对明文子串下判断。
      List<String> mediaUris(String manifest) => [
        for (final line in const LineSplitter().convert(manifest))
          if (line.trim().isNotEmpty && !line.trim().startsWith('#'))
            LocalProxyServer.decodeTarget(
                  Uri.parse(line.trim()).pathSegments.last,
                )?.toString() ??
                line.trim(),
      ];
      expect(
        mediaUris(await read(proxy.urlFor(a, target))),
        containsAll([
          'http://127.0.0.1:${upstream.port}/feature/one.ts',
          'http://127.0.0.1:${upstream.port}/advert/ad.ts',
        ]),
      );
      final captured = proxy.mediaPlaylistFor(a.fingerprint)!;
      expect(captured.evidence.totalSegments, 2);
      proxy.aiSessionFingerprint = a.fingerprint;
      proxy.aiSessionRules = mergeAiAdRules(const AdRuleSet.empty(), const [
        AdRuleProposal(
          confidence: .95,
          regexPatterns: [r'/advert/'],
          excludePatterns: [r'/feature/'],
        ),
      ], target);
      final filtered = mediaUris(await read(proxy.urlFor(a, target)));
      expect(filtered, ['http://127.0.0.1:${upstream.port}/feature/one.ts']);
      expect(
        mediaUris(await read(proxy.urlFor(b, target))),
        contains('http://127.0.0.1:${upstream.port}/advert/ad.ts'),
      );
    } finally {
      client.close(force: true);
      await proxy.stop();
      await upstream.close(force: true);
    }
  });
}

class _CapturingSyncClient extends SyncClient {
  _CapturingSyncClient() : super(log: LogService());
  Map<String, Object?>? lastBackup;
  bool? lastSettingsOption;

  @override
  Future<SyncPushResult> pushBackup({
    required String deviceBase,
    required Map<String, Object?> backup,
    SyncOptions options = SyncOptions.pcDefault,
  }) async {
    lastBackup = backup;
    lastSettingsOption = options.settings;
    return const SyncPushResult(
      statusCode: 200,
      body: 'OK',
      type: 'backup',
      mode: '1',
      itemCount: 1,
    );
  }
}

void consumerContractTests() {
  AppPaths pathsOf(Directory temp) => AppPaths.resolve(
    overrides: {
      'config': '${temp.path}/config',
      'data': '${temp.path}/data',
      'cache': '${temp.path}/cache',
      'state': '${temp.path}/log',
    },
  );

  test('S03 旧坏用户轨不阻断任何域回滚，且逐域失败可见', () async {
    final temp = await Directory.systemTemp.createTemp('parity-recovery-');
    final paths = pathsOf(temp);
    final aiDir = Directory(AiContentPaths.of(paths).dataDir);
    final tracks = Directory('${paths.dataDir}/karaoke/tracks');
    await aiDir.create(recursive: true);
    await tracks.create(recursive: true);
    final settings = File(paths.settingsPath);
    final db = File(paths.databasePath);
    final reader = File('${paths.configDir}/reader_tts.json');
    await settings.parent.create(recursive: true);
    await settings.writeAsString('old-settings');
    await db.writeAsString('old-db');
    await reader.writeAsString('old-reader');
    await File('${aiDir.path}/group_rules.json').writeAsString('{"rules":[]}');
    // 用户旧轨已经损坏（不可评分）——回滚必须原样带回这些字节。
    await File('${tracks.path}/old.txt').writeAsBytes([98, 97, 100]);

    final recovery = await captureBackupRecovery(paths);
    expect(
      await recoveryDomains(recovery),
      containsAll(['settings', 'database', 'ai', 'karaoke', 'reader']),
    );

    // 破坏所有域，并让 reader 目标是目录（该域恢复必然失败）。
    await settings.writeAsString('new-settings');
    await db.writeAsString('new-db');
    await File('${aiDir.path}/group_rules.json').delete();
    await File('${tracks.path}/old.txt').delete();
    await File('${tracks.path}/new.txt').writeAsString('new-track');
    await reader.delete();
    await Directory(reader.path).create(recursive: true);

    final failures = await restoreBackupRecovery(paths, recovery);
    expect(failures.any((item) => item.startsWith('reader')), isTrue);
    expect(await settings.readAsString(), 'old-settings');
    expect(await db.readAsString(), 'old-db');
    expect(
      await File('${aiDir.path}/group_rules.json').readAsString(),
      '{"rules":[]}',
    );
    expect(await File('${tracks.path}/old.txt').readAsBytes(), [98, 97, 100]);
    expect(await File('${tracks.path}/new.txt').exists(), isFalse);
    await recovery.delete();
    await temp.delete(recursive: true);
  });

  test('S04 确认后在途取消/关开关均不得安装广告规则', () async {
    final temp = await Directory.systemTemp.createTemp('parity-ad-gate-');
    final paths = pathsOf(temp);
    final state = AppState(paths: paths, log: LogService());
    try {
      await state.bootstrap();
      await state.saveAiConfig(
        const AiConfig(
          enabled: true,
          apiKey: 'fixture',
          model: 'fixture',
          endpoint: 'https://ai.test/v1',
        ),
      );
      await state.setAiAdDetectionEnabled(true);
      final playlist = Uri.parse('https://media.test/feature/index.m3u8');
      final context = AdDetectionContext(
        siteKey: 's',
        urlHost: playlist.host,
        urlPath: playlist.path,
      );
      final evidence = const AdPlaylistEvidence(
        segments: ['https://media.test/feature/one.ts'],
        durations: [8],
      );
      final assessment = assessAdRuleProposal(
        const {
          'confidence': .95,
          'hostsBlacklist': ['ads.test'],
          'regexPatterns': [r'/advert/'],
          'excludePatterns': [r'/feature/'],
        },
        contentHost: playlist.host,
        contentPath: playlist.path,
        evidenceSegments: evidence.segments,
      );
      // 没有当前播放会话：即使票据有效也不能安装。
      final ticket = state.startAiAdApply();
      expect(
        await state.applyAiAdRule(
          assessment,
          context: context,
          evidence: evidence,
          playlist: playlist,
          ticket: ticket,
        ),
        isFalse,
      );
      // 关闭对话框（撤销在途提交）后，迟到结果必须作废。
      state.cancelAiAdApply();
      expect(
        await state.applyAiAdRule(
          assessment,
          context: context,
          evidence: evidence,
          playlist: playlist,
          ticket: ticket,
        ),
        isFalse,
      );
      expect(
        await state.applyAiAdRule(
          assessment,
          context: context,
          evidence: evidence,
          playlist: playlist,
          ticket: state.startAiAdApply(),
        ),
        isFalse,
      );
    } finally {
      state.dispose();
      await temp.delete(recursive: true);
    }
  });

  test('S05 真实 pushSettingsTo 回推本机当前TMDB/AI且不越权带凭据', () async {
    final temp = await Directory.systemTemp.createTemp('parity-push-');
    final paths = pathsOf(temp);
    final client = _CapturingSyncClient();
    final state = AppState(paths: paths, log: LogService(), syncClient: client);
    try {
      await state.bootstrap();
      // 先接收一份过期设置（enabled=false / key=A）。
      await state.applySyncedSettings(
        SyncSettings.fromBackup({
          'prefers': {
            'tmdb_enabled': false,
            'tmdb_config': jsonEncode({'enabled': false, 'apiKey': 'A'}),
            'ai_title_extraction': true,
            'unknown_future': {'keep': 1},
          },
        }, allowSensitive: true),
      );
      // 本机改成本机真实值 B / enabled=true。
      await state.saveTmdbConfig(
        const TmdbConfig(
          enabled: true,
          apiKey: 'B',
          apiBase: 'https://tmdb.test/3',
        ),
      );

      final peer = const SyncPeer(
        uuid: 'peer-1',
        name: '测试安卓',
        address: 'http://127.0.0.1:9',
      );
      // 生产有推送门禁（_pushEnabled 默认关闭）；夹具必须显式打开，
      // 否则 exporter 根本不会被调用，这不代表 exporter 缺失。
      await state.syncState.setPushEnabled(true);
      await state.syncState.pushSettingsTo(peer);
      var prefers = (client.lastBackup!['prefers'] as Map)
          .cast<String, Object?>();
      expect(prefers['tmdb_enabled'], isTrue);
      expect(prefers['ai_title_extraction'], isTrue);
      // 未开启「设置同步」时敏感项一律不出现。
      expect(prefers.containsKey('tmdb_config'), isFalse);
      expect(prefers.containsKey('ai_config'), isFalse);
      expect(client.lastSettingsOption, isFalse);

      await state.syncState.setSettingsSyncEnabled(true);
      await state.syncState.pushSettingsTo(peer);
      prefers = (client.lastBackup!['prefers'] as Map).cast<String, Object?>();
      expect(client.lastSettingsOption, isTrue);
      final pushedTmdb = decodeAndroidJsonSetting(prefers['tmdb_config'])!;
      expect(pushedTmdb['enabled'], isTrue);
      expect(pushedTmdb['apiKey'], 'B', reason: '回推的是本机当前配置而不是旧的接收值');
      expect(prefers['unknown_future'], {'keep': 1}, reason: '未知顶层键必须原样回推');
    } finally {
      state.dispose();
      await temp.delete(recursive: true);
    }
  });
}
