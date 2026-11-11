import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/ai_content/ad_rule_validation.dart';
import 'package:webhtv_pc/core/ai_content/group_rule_validation.dart';
import 'package:webhtv_pc/core/ai_content/log_diagnosis.dart';
import 'package:webhtv_pc/services/ai_content/ad_rule_service.dart';
import 'package:webhtv_pc/services/ai_content/ai_content_paths.dart';
import 'package:webhtv_pc/services/ai_content/user_data_store.dart';

void main() {
  late Directory temp;
  late AiContentPaths paths;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('ai_content_safety_');
    paths = AiContentPaths(dataDir: '${temp.path}/data', cacheDir: '${temp.path}/cache');
  });
  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  AdRuleService service() => AdRuleService(
    config: () => const AiConfig(
      enabled: true,
      apiKey: 'fixture',
      endpoint: 'https://example.com/v1',
      model: 'fixture',
    ),
    paths: paths,
  );

  test('裸短Bearer和Basic凭据不进入诊断payload（M6）', () {
    expect(
      buildSanitizedLogPayload('Bearer a\nBearer abc123 failed\nBasic YTpi'),
      'Bearer <redacted>\nBearer <redacted> failed\nBasic <redacted>',
    );
  });

  test('量化组在安全子集与AI/fromJson入口均被拒绝（I3-b）', () {
    for (final pattern in [r'^(a+)+$', r'^(a*){2,}$', r'^(a|aa)+$']) {
      expect(isJavaCompatibleSafeRegex(pattern), isFalse, reason: pattern);
      expect(
        GroupRuleProposal.fromJson({'name': 'x', 'regex': pattern}),
        isNull,
      );
      expect(
        validateGroupRuleProposals([{'name': 'x', 'regex': pattern}]).accepted,
        isEmpty,
      );
      expect(
        AdRuleProposal.fromJson({
          'confidence': 0.9,
          'regexPatterns': [pattern],
        }),
        isNull,
      );
    }
    for (final pattern in [r'^(腾讯).*$', r'^/ad/.*\.ts$', r'^\([ab]\)$']) {
      expect(isJavaCompatibleSafeRegex(pattern), isTrue, reason: pattern);
    }
  });

  test('相同广告和排除模式及低置信JSON不授予应用权限（I3-a）', () {
    expect(
      AdRuleProposal.fromJson({
        'confidence': 0.9,
        'regexPatterns': ['movie'],
        'excludePatterns': ['movie'],
      }),
      isNull,
    );
    expect(
      AdRuleProposal.fromJson({
        'confidence': 0.1,
        'regexPatterns': ['/ad/'],
      }),
      isNull,
    );
  });

  test('不可信规则通过文件与导入仍被拒绝（I3）', () async {
    final store = AiContentUserDataStore(paths: paths);
    await Directory(paths.dataDir).create(recursive: true);
    final rules = [
      {'confidence': 0.9, 'regexPatterns': ['movie'], 'excludePatterns': ['movie']},
      {'confidence': 0.9, 'regexPatterns': [r'^(a+)+$']},
      {'confidence': 0.1, 'regexPatterns': ['/ad/']},
    ];
    await File(paths.adRulesPath).writeAsString(jsonEncode({'rules': rules}));
    expect(await service().loadCandidates(), isEmpty);
    final imported = await store.importJson(jsonEncode({
      'schemaVersion': 1,
      'adRules': rules,
      'groupRules': [{'name': 'x', 'regex': r'^(a+)+$'}],
    }));
    expect(imported.ok, isTrue);
    expect(await store.loadAdRules(), isEmpty);
    expect(await store.loadGroupRules(), isEmpty);
  });

  test('没有当前播放证据的人为applicable仍不可批准（I3-a）', () async {
    final result = await service().approve(const AdRuleAssessment(
      verdict: AdRuleVerdict.applicable,
      proposal: AdRuleProposal(confidence: 0.9, regexPatterns: ['/ad/']),
    ));
    expect(result.ok, isFalse);
    expect(await File(paths.adRulesPath).exists(), isFalse);
  });

  test('当前正片host黑名单被拒绝（I3-a）', () {
    final assessment = assessAdRuleProposal(
      {'confidence': 0.9, 'hostsBlacklist': ['example.com']},
      contentHost: 'video.example.com',
      contentPath: '/movie/index.m3u8',
      evidenceSegments: ['https://video.example.com/movie/seg.ts'],
    );
    expect(assessment.verdict, AdRuleVerdict.rejected);
  });

  test('再次批准不同exclude不丢旧保护并能导入往返（N1）', () async {
    final ad = service();
    const first = AdRuleProposal(
      confidence: 0.9,
      hostsBlacklist: ['cdn.example.com'],
      regexPatterns: ['/ad/'],
      excludePatterns: ['/movie/'],
    );
    const second = AdRuleProposal(
      confidence: 0.9,
      hostsBlacklist: ['cdn.example.com'],
      regexPatterns: ['/ad/'],
    );
    for (final proposal in [first, second, second]) {
      final result = await ad.approve(AdRuleAssessment(
        verdict: AdRuleVerdict.applicable,
        proposal: proposal,
      ),
        context: const AdDetectionContext(siteKey: 's1', urlHost: 'main.example.com', urlPath: '/v/play/index.m3u8'),
        evidence: const AdPlaylistEvidence(segments: ['https://cdn.example.com/ad/x.ts']),
      );
      expect(result.ok, isTrue);
    }
    final store = AiContentUserDataStore(paths: paths);
    final saved = await store.loadAdRules();
    expect(saved, hasLength(2));
    expect(saved.expand((rule) => rule.excludePatterns), contains('/movie/'));
    final exported = await store.exportJson();
    final restored = AiContentUserDataStore(
      paths: AiContentPaths(dataDir: '${temp.path}/restored/data', cacheDir: '${temp.path}/restored/cache'),
    );
    expect((await restored.importJson(exported)).ok, isTrue);
    expect(
      (await restored.loadAdRules()).expand((rule) => rule.excludePatterns),
      contains('/movie/'),
    );
  });
}




