import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_content/ad_rule_validation.dart';
import 'package:webhtv_pc/core/ai_content/group_rule_validation.dart';

void main() {
  group('分组规则 · Java 兼容安全子集', () {
    test('普通锚定正则通过', () {
      expect(isJavaCompatibleSafeRegex('^腾讯.*视频\$'), isTrue);
      expect(isJavaCompatibleSafeRegex('^(爱奇艺|优酷|bilibili)\$'), isTrue);
      expect(isJavaCompatibleSafeRegex('[\\u4e00-\\u9fa5]{2,6}'), isTrue);
    });

    test('后行断言/原子组/占有量词/命名组被拒绝', () {
      expect(isJavaCompatibleSafeRegex('(?<=abc)x'), isFalse);
      expect(isJavaCompatibleSafeRegex('(?<!abc)x'), isFalse);
      expect(isJavaCompatibleSafeRegex('(?>abc)'), isFalse);
      expect(isJavaCompatibleSafeRegex('a*+'), isFalse);
      expect(isJavaCompatibleSafeRegex('(?<name>abc)'), isFalse);
      expect(isJavaCompatibleSafeRegex(r'\p{Han}+'), isFalse);
      expect(isJavaCompatibleSafeRegex(r'\Q.a.b\E'), isFalse);
    });

    test('无法编译或空模式被拒绝', () {
      expect(isJavaCompatibleSafeRegex(''), isFalse);
      expect(isJavaCompatibleSafeRegex('(abc'), isFalse);
      expect(isJavaCompatibleSafeRegex('   '), isFalse);
    });
  });

  group('分组规则 · 数量与长度上限', () {
    String proposals(int count) {
      final items = [
        for (var i = 0; i < count; i++)
          '{"name":"组$i","regex":"^站点$i.*\$","reason":"理由$i"}',
      ];
      return '{"rules":[${items.join(',')}]}';
    }

    test('最多 6 条，第 7 条起被拒绝并给出原因', () {
      final result = validateGroupRuleProposals(proposals(8));
      expect(result.accepted.length, 6);
      expect(result.rejected.length, 2);
      expect(result.rejected.first.reason, contains('6'));
    });

    test('正则超过 256 字符被拒绝', () {
      final long = 'a' * 257;
      final text = '{"rules":[{"name":"长","regex":"$long","reason":"r"}]}';
      final result = validateGroupRuleProposals(text);
      expect(result.accepted, isEmpty);
      expect(result.rejected.single.reason, contains('256'));
    });

    test('规则名超过 40 字符被截断，空名被拒绝', () {
      final longName = '名' * 60;
      final text =
          '{"rules":['
          '{"name":"$longName","regex":"^a\$","reason":"r"},'
          '{"name":"   ","regex":"^b\$","reason":"r"}'
          ']}';
      final result = validateGroupRuleProposals(text);
      expect(result.accepted.single.name.length, 40);
      expect(result.rejected.single.reason, contains('名称'));
    });

    test('非对象或不安全正则整体拒绝，不抛异常', () {
      expect(validateGroupRuleProposals('不是 JSON').accepted, isEmpty);
      expect(validateGroupRuleProposals(null).accepted, isEmpty);
      final unsafe = validateGroupRuleProposals(
        '{"rules":[{"name":"后行","regex":"(?<=x)y","reason":"r"}]}',
      );
      expect(unsafe.accepted, isEmpty);
      expect(unsafe.rejected.single.reason, contains('安全'));
    });

    test('重复覆盖不足 50% 时整组被拒', () {
      expect(hasEnoughRepeatedCoverage(matchedSources: 10, repeatedSources: 5),
          isTrue);
      expect(hasEnoughRepeatedCoverage(matchedSources: 10, repeatedSources: 4),
          isFalse);
      expect(hasEnoughRepeatedCoverage(matchedSources: 0, repeatedSources: 0),
          isFalse);
      // 单站点命中无法形成「重复」，必须拒绝。
      expect(hasEnoughRepeatedCoverage(matchedSources: 1, repeatedSources: 1),
          isFalse);
    });

    test('真实重复覆盖按捕获值统计（不是「命中 ≥2 站点」）', () {
      const names = [
        '优酷', '爱奇艺', '腾讯视频', '腾讯体育', '搜狐',
        '乐视', '芒果', 'PPTV', '哔哩', '咪咕',
      ];
      final noisy = computeGroupRuleCoverage(
        pattern: r'^(腾讯|优酷|爱奇艺|搜狐|乐视|芒果|PPTV|哔哩|咪咕)',
        sourceNames: names,
      );
      expect(noisy.matchedSources, 10);
      expect(noisy.repeatedSources, 2);
      expect(noisy.sufficient, isFalse);

      final grouped = computeGroupRuleCoverage(
        pattern: r'^(腾讯|优酷|爱奇艺)',
        sourceNames: names,
      );
      // 命中 4 个站点，其中 2 个共用「腾讯」→ 50% 达标。
      expect(grouped.matchedSources, 4);
      expect(grouped.repeatedSources, 2);
      expect(grouped.sufficient, isTrue);
    });

    test('捕获整串站点名不算分组（全名捕获）', () {
      final coverage = computeGroupRuleCoverage(
        pattern: r'^腾讯.*$',
        sourceNames: const ['腾讯视频', '腾讯体育'],
      );
      expect(coverage.matchedSources, 2);
      expect(coverage.repeatedSources, 0);
      expect(coverage.fullNameCaptures, 2);
      expect(coverage.sufficient, isFalse);
    });
  });

  group('广告规则 · HLS 首尾 3 段证据', () {
    AdPlaylistEvidence evidence(int segments) => AdPlaylistEvidence(
      segments: [
        for (var i = 0; i < segments; i++) 'https://cdn$i.example.com/seg$i.ts',
      ],
      discontinuities: const [0, 8],
      durations: [for (var i = 0; i < segments; i++) 4.0],
      domainSwitches: [for (var i = 0; i < segments; i++) i == 1],
    );

    test('摘要含总数/不连续点/总时长/域切换数/首尾各 3 段', () {
      final summary = evidence(10).summary();
      expect(summary, contains('Total segments: 10'));
      expect(summary, contains('Discontinuities at: [0, 8]'));
      expect(summary, contains('Total duration: 40.0s'));
      expect(summary, contains('Domain switches: 1'));
      expect(summary, contains('[0]'));
      expect(summary, contains('[9]'));
      expect(summary, isNot(contains('[4]')));
      expect(summary, contains('... (4 segments)'));
      expect(summary, contains('[DOMAIN_SWITCH]'));
      expect(summary, contains('[DISCONTINUITY]'));
    });

    test('不足 4 段时只列首 3 段，不重复列尾', () {
      final summary = evidence(3).summary();
      expect(summary, contains('First 3 segments:'));
      expect(summary, isNot(contains('Last 3 segments:')));
    });

    test('空证据给出明确说明', () {
      expect(const AdPlaylistEvidence.empty().summary(), 'No segments found');
    });
  });

  group('广告规则 · 置信度与方向保护', () {
    AdRuleAssessment assess({
      Object? raw,
      double minConfidence = 0.5,
      String contentHost = 'main.example.com',
      String contentPath = '/v/play/index.m3u8',
    }) => assessAdRuleProposal(
      raw,
      contentHost: contentHost,
      contentPath: contentPath,
      minConfidence: minConfidence,
    );

    test('置信度达标时给出可应用规则', () {
      final result = assess(
        raw:
            '{"confidence":0.86,"hostsBlacklist":["ad.example.com"],'
            '"regexPatterns":["^/ad/.*\\\\.ts\$"],'
            '"excludePatterns":["^/v/.*"],"reasoning":"前贴片跨域"}',
      );
      expect(result.verdict, AdRuleVerdict.applicable);
      expect(result.proposal, isNotNull);
      expect(result.proposal!.hostsBlacklist, ['ad.example.com']);
      expect(result.proposal!.regexPatterns.length, 1);
      expect(result.proposal!.confidence, closeTo(0.86, 1e-9));
    });

    test('置信度低于阈值只警告，不产生可应用规则', () {
      final result = assess(
        raw:
            '{"confidence":0.2,"hostsBlacklist":["ad.example.com"],'
            '"regexPatterns":["^/ad/.*"],"reasoning":"证据不足"}',
      );
      expect(result.verdict, AdRuleVerdict.warningOnly);
      expect(result.proposal, isNull);
      expect(result.warnings, isNotEmpty);
    });

    test('命中主内容路径的「广告正则」被拒绝（正片保护）', () {
      final result = assess(
        raw:
            '{"confidence":0.9,"hostsBlacklist":[],'
            '"regexPatterns":["^/v/play/.*\\\\.m3u8\$"],"reasoning":"x"}',
      );
      expect(result.verdict, AdRuleVerdict.rejected);
      expect(result.reasons.join(), contains('正片'));
    });

    test('排除正则与广告正则方向冲突时拒绝，不反向应用', () {
      final result = assess(
        raw:
            '{"confidence":0.9,"hostsBlacklist":[],'
            '"regexPatterns":["^/ad/.*"],"excludePatterns":["^/ad/.*"],'
            '"reasoning":"x"}',
      );
      expect(result.verdict, AdRuleVerdict.rejected);
      expect(result.reasons.join(), contains('冲突'));
    });

    test('非法域名片段被清洗，超长正则被丢弃', () {
      final result = assess(
        raw:
            '{"confidence":0.8,"hostsBlacklist":'
            '["https://ad.example.com/path","bad host","ad.example.com",'
            '".ad2.example.com","ad.example.com"],'
            '"regexPatterns":["${'a' * 300}"],"reasoning":"x"}',
      );
      expect(result.verdict, AdRuleVerdict.applicable);
      expect(result.proposal!.hostsBlacklist, ['ad.example.com', 'ad2.example.com']);
      expect(result.proposal!.regexPatterns, isEmpty);
    });

    test('不安全正则被丢弃，不给应用路径', () {
      final result = assess(
        raw:
            '{"confidence":0.8,"hostsBlacklist":["ad.example.com"],'
            '"regexPatterns":["(?<=x)y"],"reasoning":"x"}',
      );
      expect(result.proposal!.regexPatterns, isEmpty);
      expect(result.proposal!.hostsBlacklist, ['ad.example.com']);
    });

    test('非 JSON 输出直接拒绝', () {
      final result = assess(raw: '模型拒绝回答');
      expect(result.verdict, AdRuleVerdict.rejected);
      expect(result.reasons, isNotEmpty);
      expect(result.proposal, isNull);
    });

    test('方向冲突用真实证据切片地址判定（M1）', () {
      const body =
          '{"confidence":0.9,"hostsBlacklist":[],"regexPatterns":["/ad/"],'
          '"excludePatterns":["cdn2\\\\.example\\\\.com"],"reasoning":"x"}';
      const contentHost = 'main.example.com';
      const contentPath = '/v/play/index.m3u8';

      // 没有证据时，两条正则在内置样本上不重叠 → 不判冲突。
      final withoutEvidence = assessAdRuleProposal(
        body,
        contentHost: contentHost,
        contentPath: contentPath,
      );
      expect(withoutEvidence.verdict, AdRuleVerdict.applicable);

      // 真实证据地址同时命中两条正则 → 方向冲突，整份拒绝。
      final withEvidence = assessAdRuleProposal(
        body,
        contentHost: contentHost,
        contentPath: contentPath,
        evidenceSegments: const ['https://cdn2.example.com/ad/x.ts'],
      );
      expect(withEvidence.verdict, AdRuleVerdict.rejected);
      expect(withEvidence.reasons.join(), contains('冲突'));
    });

    test('落盘 JSON 里的不安全正则与脏域名被重新校验（I3）', () {
      final proposal = AdRuleProposal.fromJson({
        'confidence': 0.9,
        'hostsBlacklist': ['https://ad.example.com/x', 'bad host'],
        'regexPatterns': ['(?<=x)y', 'a' * 300, r'^/ad/.*$'],
        'excludePatterns': <String>[],
        'reasoning': 'r',
      });
      expect(proposal, isNotNull);
      expect(proposal!.regexPatterns, [r'^/ad/.*$']);
      expect(proposal.hostsBlacklist, ['ad.example.com']);

      // 全都是非法内容 → 这条「规则」没有任何可应用内容，直接丢弃。
      expect(
        AdRuleProposal.fromJson({
          'confidence': 0.9,
          'hostsBlacklist': ['bad host'],
          'regexPatterns': ['(?<=x)y'],
        }),
        isNull,
      );
    });

    test('分组规则落盘 JSON 复用安全子集与长度校验（I3）', () {
      expect(
        GroupRuleProposal.fromJson({'name': '不安全', 'regex': '(?>a)'}),
        isNull,
      );
      expect(
        GroupRuleProposal.fromJson({'name': '超长', 'regex': 'a' * 300}),
        isNull,
      );
      final ok = GroupRuleProposal.fromJson({
        'name': '腾讯系',
        'regex': r'^(腾讯).*$',
        'reason': '同源',
      });
      expect(ok, isNotNull);
      expect(ok!.name, '腾讯系');
    });
  });
}
