import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/ai_content/ad_rule_validation.dart';
import 'package:webhtv_pc/core/ai_content/ai_content_contracts.dart';
import 'package:webhtv_pc/core/ai_content/group_rule_validation.dart';
import 'package:webhtv_pc/core/ai_content/recommendation.dart';
import 'package:webhtv_pc/core/ai_content/recommendation_feedback.dart';
import 'package:webhtv_pc/core/ai_content/title_resolution.dart';
import 'package:webhtv_pc/core/ai_content/user_data.dart';
import 'package:webhtv_pc/core/viewing_report.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/ai_content/ad_rule_service.dart';
import 'package:webhtv_pc/services/ai_content/ai_content_completion.dart';
import 'package:webhtv_pc/services/ai_content/ai_content_paths.dart';
import 'package:webhtv_pc/services/ai_content/group_rule_service.dart';
import 'package:webhtv_pc/services/ai_content/log_diagnosis_service.dart';
import 'package:webhtv_pc/services/ai_content/profile_service.dart';
import 'package:webhtv_pc/services/ai_content/recommendation_service.dart';
import 'package:webhtv_pc/services/ai_content/title_resolution_service.dart';
import 'package:webhtv_pc/services/ai_content/user_data_store.dart';

AiConfig readyConfig() => const AiConfig(
  enabled: true,
  apiKey: 'k',
  endpoint: 'https://example.com/v1',
  model: 'm',
);

/// 可控的「模型」：记录调用次数，按队列返回文本。
class FakeModel {
  FakeModel(this.replies);

  final List<String> replies;
  int calls = 0;
  final List<String> prompts = [];

  AiContentCompletion completer() => AiContentCompletion(
    complete: ({required AiConfig config, required String prompt, Duration timeout = Duration.zero}) async {
      calls++;
      prompts.add(prompt);
      final text = replies.isEmpty ? '' : replies.removeAt(0);
      return AiCompletionResult(
        ok: true,
        statusCode: 200,
        text: text,
        message: '',
      );
    },
  );
}

String recommendationPayload(List<String> titles) =>
    '{"items":[${[
      for (final title in titles)
        '{"title":"$title","year":2024,"mediaType":"movie","reason":"理由"}',
    ].join(',')}]}';

PlaybackHistory historyRecord({
  required String vodName,
  required DateTime watchedAt,
  int positionMs = 20 * 60 * 1000,
  int durationMs = 45 * 60 * 1000,
}) => PlaybackHistory(
  id: watchedAt.millisecondsSinceEpoch ~/ 1000,
  siteKey: 'site',
  vodId: vodName,
  vodName: vodName,
  flag: '线路',
  episodeName: 'E1',
  episodeId: 'E1',
  positionMs: positionMs,
  durationMs: durationMs,
  updatedAt: watchedAt.millisecondsSinceEpoch,
);

void main() {
  late Directory tempRoot;
  late AiContentPaths paths;
  final now = DateTime(2026, 11, 10, 12);

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('ai_content_test');
    paths = AiContentPaths(
      dataDir: '${tempRoot.path}/data',
      cacheDir: '${tempRoot.path}/cache',
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  group('推荐服务：真实链路（生成 → 富集/降级 → 过滤 → 缓存）', () {
    test('首次调用模型，第二次命中缓存；富集失败降级为片名卡', () async {
      final model = FakeModel([recommendationPayload(['甲', '乙'])]);
      final service = RecommendationService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
        enricher: (items) async =>
            [null, const RecommendationEnrichment(tmdbId: 9, mediaType: RecommendationMediaType.movie)],
        clock: () => now,
      );
      final request = const RecommendationRequest(
        source: RecommendationSource.history,
        siteKey: 's1',
      );

      final first = await service.recommend(request: request);
      expect(first.ok, isTrue);
      expect(first.value!.length, 2);
      expect(first.value!.first.degraded, isTrue);
      expect(first.value!.last.tmdbKey, 'movie:9');
      expect(model.calls, 1);

      final second = await service.recommend(request: request);
      expect(second.ok, isTrue);
      expect(second.value!.length, 2);
      // 缓存命中：没有第二次付费调用。
      expect(model.calls, 1);
    });

    test('负反馈过滤生效，且「不感兴趣」写入用户数据文件', () async {
      final model = FakeModel([
        recommendationPayload(['不想看', '想看']),
        recommendationPayload(['不想看', '想看']),
      ]);
      final service = RecommendationService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
        clock: () => now,
      );
      const request = RecommendationRequest(
        source: RecommendationSource.current,
        siteKey: 's1',
      );
      final first = await service.recommend(request: request);
      final disliked = first.value!.first;
      expect(disliked.title, '不想看');

      final marked = await service.markNotInterested(disliked);
      expect(marked.ok, isTrue);
      expect(marked.value!.entries.single.title, '不想看');
      expect(await File(paths.feedbackPath).exists(), isTrue);

      // 换一个 key 绕开缓存，验证过滤真实生效。
      final second = await service.recommend(
        request: const RecommendationRequest(
          source: RecommendationSource.search,
          keyword: '科幻',
        ),
      );
      expect(second.value!.map((card) => card.title), ['想看']);
    });

    test('取消：ok=false、statusCode=0，且不写缓存', () async {
      final model = FakeModel([recommendationPayload(['甲'])]);
      final service = RecommendationService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
        clock: () => now,
      );
      final cancellation = AiContentCancellation()..cancel();
      final result = await service.recommend(
        request: const RecommendationRequest(
          source: RecommendationSource.history,
        ),
        cancellation: cancellation,
      );
      expect(result.ok, isFalse);
      expect(result.cancelled, isTrue);
      expect(result.statusCode, 0);
      expect(model.calls, 0);
    });

    test('未配置 AI 时失败原因明确，不抛异常', () async {
      final model = FakeModel(const []);
      final service = RecommendationService(
        config: () => const AiConfig(),
        paths: paths,
        completion: model.completer(),
        clock: () => now,
      );
      final result = await service.recommend(
        request: const RecommendationRequest(
          source: RecommendationSource.history,
        ),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('未配置'));
    });

    test('写入负反馈后，同一请求命中缓存也必须过滤（I1）', () async {
      final model = FakeModel([recommendationPayload(['不想看', '想看'])]);
      final service = RecommendationService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
        clock: () => now,
      );
      const request = RecommendationRequest(
        source: RecommendationSource.history,
        siteKey: 's1',
      );
      final first = await service.recommend(request: request);
      expect(first.value!.length, 2);

      final marked = await service.markNotInterested(first.value!.first);
      expect(marked.ok, isTrue);

      // 同一个 request → 同一个缓存键：命中缓存也必须重新过一遍负反馈，
      // 且不能因为过滤而重新付一次 AI 调用。
      final second = await service.recommend(request: request);
      expect(model.calls, 1);
      expect(second.value!.map((card) => card.title), ['想看']);
    });

    test('缓存裁剪只删 rec_*，不连带删片名缓存（M4）', () async {
      await Directory(paths.cacheDir).create(recursive: true);
      final titleCache = File('${paths.cacheDir}/title_keepme.json');
      await titleCache.writeAsString('{"generatedAtMs":1}');
      for (var i = 0; i < 33; i++) {
        final file = File('${paths.cacheDir}/rec_old$i.json');
        await file.writeAsString('{"generatedAtMs":1,"items":[]}');
        await file.setLastModified(now.subtract(Duration(minutes: i + 1)));
      }

      final model = FakeModel([recommendationPayload(['甲'])]);
      final service = RecommendationService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
        clock: () => now,
      );
      final result = await service.recommend(
        request: const RecommendationRequest(
          source: RecommendationSource.history,
          siteKey: 'trim',
        ),
      );
      expect(result.ok, isTrue);
      expect(
        (await paths.existingRecommendationCacheFiles()).length,
        lessThanOrEqualTo(RecommendationCachePolicy.maxFiles),
      );
      // 片名缓存是别的域的缓存，不能被推荐的容量裁剪删掉。
      expect(await titleCache.exists(), isTrue);
    });
  });

  group('片名服务：规则 → 学习 → AI', () {
    test('规则可信时不调模型', () async {
      final model = FakeModel(const []);
      final service = TitleResolutionService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
        clock: () => now,
      );
      final result = await service.resolve(
        const TitleQuery(rawTitle: '流浪地球 2019'),
      );
      expect(result.ok, isTrue);
      expect(result.value!.source, TitleResolutionSource.rule);
      expect(result.value!.title, '流浪地球');
      expect(model.calls, 0);
    });

    test('规则低置信 → AI；确认后第二次走学习命中', () async {
      final model = FakeModel([
        '{"title":"真正的片名","year":2022,"mediaType":"movie","confidence":0.9}',
      ]);
      final service = TitleResolutionService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
        clock: () => now,
      );
      const query = TitleQuery(rawTitle: 'xx 未命名', siteKey: 's1', vodId: 'v1');
      final first = await service.resolve(query);
      expect(first.value!.source, TitleResolutionSource.ai);
      expect(first.value!.title, '真正的片名');
      expect(model.calls, 1);

      final confirmed = await service.confirm(query, first.value!);
      expect(confirmed.ok, isTrue);
      expect(await File(paths.learningPath).exists(), isTrue);

      // 清掉缓存目录，确保结论只能来自学习库。
      await Directory(paths.cacheDir).delete(recursive: true);
      final second = await service.resolve(query);
      expect(second.value!.source, TitleResolutionSource.learning);
      expect(second.value!.title, '真正的片名');
      expect(model.calls, 1);
    });

    test('规则可信但有学习命中时采用学习结果（I5）', () async {
      final model = FakeModel(const []);
      final service = TitleResolutionService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
        clock: () => now,
      );
      const query = TitleQuery(
        rawTitle: '流浪地球 2019',
        siteKey: 's1',
        vodId: 'v1',
      );
      final ruled = await service.resolve(query);
      expect(ruled.value!.source, TitleResolutionSource.rule);
      expect(ruled.value!.title, '流浪地球');

      // 用户把片名改成自己的版本并确认 → 学习库记一条（同站同 id 1.0 分）。
      final confirmed = await service.confirm(
        query,
        const TitleResolution(
          rawTitle: '流浪地球 2019',
          title: '流浪地球 导演剪辑版',
          year: 2019,
          confidence: 0.95,
          source: TitleResolutionSource.rule,
        ),
      );
      expect(confirmed.ok, isTrue);

      // 真实标题的规则置信度 0.9 ≥ ruleTrust，但学习命中必须优先，
      // 否则用户确认过的修正永远不会被再次采用。
      final learned = await service.resolve(query);
      expect(learned.value!.source, TitleResolutionSource.learning);
      expect(learned.value!.title, '流浪地球 导演剪辑版');
      expect(model.calls, 0);
    });
  });

  group('分组服务：真实站点名做重复覆盖校验', () {
    test('单站点命中的规则被拒绝，多站点共用的分组名保留', () async {
      final model = FakeModel([
        '{"rules":['
        '{"name":"腾讯系","regex":"^(腾讯).*\$","reason":"同源"},'
        '{"name":"单站","regex":"^爱奇艺\$","reason":"一个站"}'
        ']}',
      ]);
      final service = GroupRuleService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
      );
      final result = await service.analyze(
        sourceNames: ['腾讯视频', '腾讯体育', '爱奇艺'],
      );
      expect(result.ok, isTrue);
      expect(result.value!.accepted.single.name, '腾讯系');
      expect(result.value!.rejected.single.reason, contains('重复覆盖'));
    });

    test('命中 10 个站点但只有 2 个共用一个分组名 → 拒绝（I4）', () async {
      final model = FakeModel([
        r'{"rules":[{"name":"噪音","regex":"^(腾讯|优酷|爱奇艺|搜狐|乐视|芒果|PPTV|哔哩|咪咕)","reason":"r"}]}',
      ]);
      final service = GroupRuleService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
      );
      final result = await service.analyze(
        sourceNames: const [
          '优酷', '爱奇艺', '腾讯视频', '腾讯体育', '搜狐',
          '乐视', '芒果', 'PPTV', '哔哩', '咪咕',
        ],
      );
      // 全拒也是分析成功：必须带回被拒明细（M3）。
      expect(result.ok, isTrue);
      expect(result.value!.accepted, isEmpty);
      expect(result.value!.rejected.single.reason, contains('重复覆盖'));
      expect(result.value!.rejected.single.reason, contains('命中 10 个站点'));
    });

    test('规则「截取整串站点名」不算分组（全名捕获）', () async {
      final model = FakeModel([
        r'{"rules":[{"name":"改名","regex":"^腾讯.*$","reason":"r"}]}',
      ]);
      final service = GroupRuleService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
      );
      final result = await service.analyze(
        sourceNames: ['腾讯视频', '腾讯体育'],
      );
      expect(result.ok, isTrue);
      expect(result.value!.accepted, isEmpty);
      expect(result.value!.rejected.single.reason, contains('全名捕获'));
    });

    test('站点不足两个时直接失败', () async {
      final service = GroupRuleService(
        config: readyConfig,
        paths: paths,
        completion: FakeModel(const []).completer(),
      );
      final result = await service.analyze(sourceNames: ['只有一个']);
      expect(result.ok, isFalse);
      expect(result.message, contains('两个'));
    });
  });

  group('去广服务：结论分级与落盘', () {
    test('低置信不写入用户数据，可应用建议写入', () async {
      final model = FakeModel([
        '{"confidence":0.2,"hostsBlacklist":["ad.example.com"],'
            '"regexPatterns":["^/ad/.*"],"reasoning":"证据不足"}',
        '{"confidence":0.9,"hostsBlacklist":["ad.example.com"],'
            '"regexPatterns":["^/ad/.*\\\\.ts\$"],"reasoning":"跨域切片"}',
      ]);
      final service = AdRuleService(
        config: readyConfig,
        paths: paths,
        completion: model.completer(),
      );
      const context = AdDetectionContext(
        siteKey: 's1',
        urlHost: 'main.example.com',
        urlPath: '/v/play/index.m3u8',
      );

      final weak = await service.analyze(context: context);
      expect(weak.value!.verdict, AdRuleVerdict.warningOnly);
      final rejected = await service.approve(weak.value!, context: context, evidence: const AdPlaylistEvidence(segments: ['https://ad.example.com/ad/x.ts']));
      expect(rejected.ok, isFalse);
      expect(await File(paths.adRulesPath).exists(), isFalse);

      final strong = await service.analyze(
        context: context,
        evidence: AdPlaylistEvidence(
          segments: [for (var i = 0; i < 8; i++) 'https://cdn/seg$i.ts'],
          durations: [for (var i = 0; i < 8; i++) 4.0],
          domainSwitches: [for (var i = 0; i < 8; i++) i == 5],
        ),
      );
      expect(strong.value!.applicable, isTrue);
      final applied = await service.approve(strong.value!, context: context, evidence: const AdPlaylistEvidence(segments: ['https://ad.example.com/ad/x.ts']));
      expect(applied.ok, isTrue);
      expect(await File(paths.adRulesPath).exists(), isTrue);
    });

    test('已确认的去广建议不被条数上限截断（M2）', () async {
      final service = AdRuleService(
        config: readyConfig,
        paths: paths,
        completion: FakeModel(const []).completer(),
      );
      for (var i = 0; i < 21; i++) {
        final applied = await service.approve(
          AdRuleAssessment(
            verdict: AdRuleVerdict.applicable,
            proposal: AdRuleProposal(
              confidence: 0.9,
              hostsBlacklist: ['ad$i.example.com'],
              regexPatterns: ['^/ad$i/.*'],
              reasoning: 'r$i',
            ),
          ),
          context: const AdDetectionContext(siteKey: 's1', urlHost: 'main.example.com', urlPath: '/v/play/index.m3u8'),
          evidence: AdPlaylistEvidence(segments: ['https://ad$i.example.com/ad$i/clip.ts']),
        );
        expect(applied.ok, isTrue);
      }
      // 去广规则是用户数据：确认过多少条就保留多少条（安卓端同样不截断）。
      expect((await service.loadCandidates()).length, 21);
    });
  });

  group('日志诊断：真实日志来源 + 发送前脱敏', () {
    test('取到真实日志、脱敏后发送、解析四段', () async {
      final model = FakeModel([
        '结论：线路超时\n证据：HTTP 504\n建议：换线路\n还缺什么：完整请求头',
      ]);
      final service = LogDiagnosisService(
        config: readyConfig,
        completion: model.completer(),
        logSource: () async =>
            'Authorization: Bearer sk-secret-1\nGET /a?key=abc HTTP/1.1',
      );
      final result = await service.diagnose();
      expect(result.ok, isTrue);
      expect(result.value!.conclusion, contains('线路超时'));
      expect(model.calls, 1);
      // 提示词里绝不能出现凭据原文。
      final prompt = model.prompts.single;
      expect(prompt, isNot(contains('sk-secret-1')));
      expect(prompt, isNot(contains('key=abc')));
      expect(prompt, contains('<redacted>'));
    });

    test('没有日志时给出可操作提示，不调用模型', () async {
      final model = FakeModel(const []);
      final service = LogDiagnosisService(
        config: readyConfig,
        completion: model.completer(),
        logSource: () async => '   ',
      );
      final result = await service.diagnose();
      expect(result.ok, isFalse);
      expect(result.message, contains('暂无'));
      expect(model.calls, 0);
    });
  });

  group('画像服务：24 小时缓存与范围隔离', () {
    final records = [
      historyRecord(vodName: '庆余年', watchedAt: DateTime(2026, 11, 9, 23, 0)),
      historyRecord(vodName: '流浪地球', watchedAt: DateTime(2026, 11, 8, 10, 0)),
    ];
    final latest = records
        .map((r) => r.updatedAt)
        .reduce((a, b) => a > b ? a : b);

    test('同一范围命中缓存；换范围必须重算', () async {
      final service = ViewingProfileService(
        config: readyConfig,
        paths: paths,
        clock: () => now,
      );
      final monthReport = generateViewingReport(
        records: records,
        range: ViewingReportRange.last30Days,
        now: now,
      );
      final first = await service.profile(
        report: monthReport,
        latestUpdatedAtMs: latest,
      );
      expect(first.value!.rangeId, ViewingReportRange.last30Days.name);

      final cached = await service.profile(
        report: monthReport,
        latestUpdatedAtMs: latest,
      );
      expect(cached.value!.generatedAtMs, first.value!.generatedAtMs);

      final allReport = generateViewingReport(
        records: records,
        range: ViewingReportRange.all,
        now: now,
      );
      final switched = await service.profile(
        report: allReport,
        latestUpdatedAtMs: latest,
      );
      expect(switched.value!.rangeId, ViewingReportRange.all.name);
      expect(switched.value!.rangeId, isNot(first.value!.rangeId));
    });

    test('AI 解读未配置时失败但基础画像仍可用', () async {
      final service = ViewingProfileService(
        config: () => const AiConfig(),
        paths: paths,
        completion: FakeModel(const []).completer(),
        clock: () => now,
      );
      final report = generateViewingReport(
        records: records,
        range: ViewingReportRange.all,
        now: now,
      );
      final profile = await service.profile(
        report: report,
        latestUpdatedAtMs: latest,
      );
      expect(profile.ok, isTrue);
      final narrative = await service.narrative(report: report);
      expect(narrative.ok, isFalse);
      expect(narrative.message, contains('未配置'));
    });
  });

  group('用户数据：可枚举、可导出、可导入', () {
    test('导出后在全新目录导入，四类数据保真', () async {
      final store = AiContentUserDataStore(paths: paths, clock: () => now);
      await store.saveGroupRules(const [
        GroupRuleProposal(name: '腾讯系', regex: '^腾讯.*\$', reason: '同源'),
      ]);
      await store.saveAdRules(const [
        AdRuleProposal(
          confidence: 0.9,
          hostsBlacklist: ['ad.example.com'],
          regexPatterns: ['^/ad/.*'],
          reasoning: '跨域',
        ),
      ]);
      final exported = await store.exportJson();
      expect(exported, contains('schemaVersion'));

      final files = await store.userDataFiles();
      expect(files, isNotEmpty);
      expect(files.every((path) => path.contains('ai_content')), isTrue);

      final otherPaths = AiContentPaths(
        dataDir: '${tempRoot.path}/other',
        cacheDir: '${tempRoot.path}/other_cache',
      );
      final otherStore = AiContentUserDataStore(paths: otherPaths);
      final imported = await otherStore.importJson(exported);
      expect(imported.ok, isTrue);
      expect(imported.domains.length, 4);
      expect((await otherStore.loadGroupRules()).single.name, '腾讯系');
      expect((await otherStore.loadAdRules()).single.confidence, 0.9);
    });

    test('坏文件只影响该域，不拖垮其他用户数据', () async {
      await Directory(paths.dataDir).create(recursive: true);
      await File(paths.groupRulesPath).writeAsString('不是 JSON');
      final store = AiContentUserDataStore(paths: paths);
      expect(await store.loadGroupRules(), isEmpty);
      expect(await store.loadFeedback(), isNotNull);
      // 坏文件之后仍能正常写入。
      expect(
        await store.saveGroupRules(const [
          GroupRuleProposal(name: 'a', regex: '^a\$', reason: 'r'),
        ]),
        isTrue,
      );
    });

    test('导入非法 JSON 报失败且不覆盖现有数据', () async {
      final store = AiContentUserDataStore(paths: paths);
      await store.saveGroupRules(const [
        GroupRuleProposal(name: '保留', regex: '^x\$', reason: 'r'),
      ]);
      final result = await store.importJson('{坏 JSON');
      expect(result.ok, isFalse);
      expect((await store.loadGroupRules()).single.name, '保留');
    });

    test('导入缺域或版本不认识 → 拒绝，且不清空已有用户数据（I2）', () async {
      final store = AiContentUserDataStore(paths: paths, clock: () => now);
      await store.saveGroupRules(const [
        GroupRuleProposal(name: '保留', regex: '^x\$', reason: 'r'),
      ]);
      await store.saveFeedback(
        RecommendationFeedbackCollection.empty().add(
          RecommendationFeedbackEntry(
            title: '不想看',
            createdAtMs: now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
          ),
          now: now,
        ),
      );

      // 合法 JSON，但一个内容智能域都没有（典型：别的应用的导出文件）。
      final empty = await store.importJson(jsonEncode({
        'schemaVersion': aiContentUserDataSchemaVersion,
      }));
      expect(empty.ok, isFalse);
      expect(empty.message, contains('不包含'));
      final missingVersion = await store.importJson('{}');
      expect(missingVersion.ok, isFalse);
      expect(missingVersion.message, contains('版本'));

      // 版本不认识 → 拒绝，而不是按「未知即兼容」去覆盖。
      final unknown = await store.importJson(
        jsonEncode({'schemaVersion': 99, 'groupRules': {'rules': []}}),
      );
      expect(unknown.ok, isFalse);
      expect(unknown.message, contains('版本'));

      // 结构不对（该是数组却是字符串）→ 拒绝。
      final broken = await store.importJson(
        jsonEncode({'schemaVersion': aiContentUserDataSchemaVersion, 'feedback': 'nope'}),
      );
      expect(broken.ok, isFalse);

      // 三次失败都没有动过用户数据。
      expect((await store.loadGroupRules()).single.name, '保留');
      expect((await store.loadFeedback()).length, 1);
    });

    test('写盘失败必须报失败，不能返回成功（I2）', () async {
      // 把 dataDir 做成一个普通文件：目录创建必然失败 → 该域写不进去。
      await File(paths.dataDir).writeAsString('not a directory');
      final store = AiContentUserDataStore(paths: paths);
      final payload = jsonEncode({
        'schemaVersion': aiContentUserDataSchemaVersion,
        'feedback': {
          'entries': [
            {'title': '甲', 'createdAtMs': now.millisecondsSinceEpoch},
          ],
        },
      });
      final result = await store.importJson(payload);
      expect(result.ok, isFalse);
      expect(result.unsavedDomains, ['feedback']);
      expect(result.message, contains('写入失败'));
    });

    test('落盘/导入里的不安全正则被重新校验并过滤（I3）', () async {
      await Directory(paths.dataDir).create(recursive: true);
      await File(paths.groupRulesPath).writeAsString(
        jsonEncode({
          'rules': [
            {'name': '不安全', 'regex': '(?<=a)b', 'reason': 'r'},
            {'name': '超长', 'regex': 'a' * 300, 'reason': 'r'},
            {'name': '合法', 'regex': r'^(腾讯).*$', 'reason': 'r'},
          ],
        }),
      );
      final store = AiContentUserDataStore(paths: paths);
      final rules = await store.loadGroupRules();
      expect(rules.map((rule) => rule.name), ['合法']);

      await File(paths.adRulesPath).writeAsString(
        jsonEncode({
          'rules': [
            {
              'confidence': 0.9,
              'hostsBlacklist': ['https://ad.example.com/x', 'bad host'],
              'regexPatterns': ['(?<=x)y', 'a' * 300],
              'excludePatterns': <String>[],
              'reasoning': 'r',
            },
          ],
        }),
      );
      final adRules = await store.loadAdRules();
      expect(adRules.single.regexPatterns, isEmpty);
      expect(adRules.single.hostsBlacklist, ['ad.example.com']);

      // 导入路径同样不能绕过校验。
      final imported = await store.importJson(
        jsonEncode({
          'schemaVersion': aiContentUserDataSchemaVersion,
          'groupRules': {
            'rules': [
              {'name': '导入不安全', 'regex': '(?>a)', 'reason': 'r'},
            ],
          },
        }),
      );
      expect(imported.ok, isTrue);
      expect(await store.loadGroupRules(), isEmpty);
    });

    test('导出快照不计入用户数据文件清单（M5）', () async {
      final store = AiContentUserDataStore(paths: paths);
      await store.saveGroupRules(const [
        GroupRuleProposal(name: 'a', regex: r'^a$', reason: 'r'),
      ]);
      await store.exportJson();
      final files = await store.userDataFiles();
      expect(File(paths.exportPath).existsSync(), isTrue);
      expect(files.contains(paths.exportPath), isFalse);
      expect(files.length, 1);
    });

    test('导出内容是合法 JSON 且不含缓存键', () async {
      final store = AiContentUserDataStore(paths: paths);
      final decoded = jsonDecode(await store.exportJson());
      expect(decoded, isA<Map>());
      expect(decoded.containsKey('cache'), isFalse);
    });
  });
}





