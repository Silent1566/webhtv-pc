import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_content/ad_rule_validation.dart';
import 'package:webhtv_pc/core/ai_content/group_rule_validation.dart';
import 'package:webhtv_pc/core/ai_content/log_diagnosis.dart';
import 'package:webhtv_pc/core/ai_content/recommendation.dart';
import 'package:webhtv_pc/core/ai_content/recommendation_feedback.dart';
import 'package:webhtv_pc/core/ai_content/title_learning.dart';
import 'package:webhtv_pc/core/ai_content/user_data.dart';
import 'package:webhtv_pc/ui/ai_content/ai_content_widgets.dart';

void main() {
  group('用户数据导出/导入（反馈/规则/学习是用户数据）', () {
    AiContentUserData sample() => AiContentUserData(
      exportedAtMs: DateTime(2026, 11, 10).millisecondsSinceEpoch,
      feedback: RecommendationFeedbackCollection.empty().add(
        RecommendationFeedbackEntry(
          title: '不想看',
          year: 2024,
          createdAtMs: DateTime(2026, 11, 9).millisecondsSinceEpoch,
        ),
        now: DateTime(2026, 11, 10),
      ),
      groupRules: const [
        GroupRuleProposal(name: '腾讯系', regex: '^腾讯.*\$', reason: '同源'),
      ],
      adRules: const [
        AdRuleProposal(
          confidence: 0.9,
          hostsBlacklist: ['ad.example.com'],
          regexPatterns: ['^/ad/.*'],
          excludePatterns: ['^/v/.*'],
          reasoning: '前贴片',
        ),
      ],
      learning: TitleLearningCollection.empty().record(
        const TitleQuery(rawTitle: '原始', siteKey: 's', vodId: 'v'),
        const TitleLearningExample(
          rawTitle: '原始',
          resolvedTitle: '结果',
          siteKey: 's',
          vodId: 'v',
          hitCount: 1,
          updatedAtMs: 1,
        ),
        now: DateTime(2026, 11, 10),
      ),
    );

    test('JSON 往返保真，含 schemaVersion 与分类目录', () {
      final data = sample();
      final json = data.toJson();
      expect(json['schemaVersion'], aiContentUserDataSchemaVersion);
      final restored = AiContentUserData.fromJson(
        jsonDecode(jsonEncode(json)),
      );
      expect(restored.feedback.entries.single.title, '不想看');
      expect(restored.groupRules.single.regex, '^腾讯.*\$');
      expect(restored.adRules.single.hostsBlacklist, ['ad.example.com']);
      expect(restored.learning.examples.single.resolvedTitle, '结果');
    });

    test('导出不含缓存字段（缓存与模型可重建）', () {
      final json = sample().toJson();
      expect(json.containsKey('cache'), isFalse);
      expect(json.containsKey('recommendationCache'), isFalse);
      expect(AiContentUserData.exportedKeys, [
        'feedback',
        'groupRules',
        'adRules',
        'learning',
      ]);
    });

    test('未知字段与缺字段容错', () {
      final restored = AiContentUserData.fromJson({
        'schemaVersion': 1,
        'feedback': 'broken',
        'groupRules': null,
        'extra': {'x': 1},
      });
      expect(restored.feedback.entries, isEmpty);
      expect(restored.groupRules, isEmpty);
      expect(restored.adRules, isEmpty);
      expect(restored.learning.examples, isEmpty);
    });
  });

  group('可嵌入组件（PC 现有风格）', () {
    Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

    testWidgets('推荐卡显示片名/理由/年份；降级卡标注未富集', (tester) async {
      var notInterested = 0;
      await tester.pumpWidget(
        host(
          Column(
            children: [
              AiRecommendationCardTile(
                card: const RecommendationCard(
                  title: '富集片',
                  year: 2021,
                  mediaType: RecommendationMediaType.tv,
                  reason: '节奏紧凑',
                  enriched: true,
                ),
                onNotInterested: () => notInterested++,
              ),
              AiRecommendationCardTile(
                card: const RecommendationCard(
                  title: '降级片',
                  mediaType: RecommendationMediaType.movie,
                  reason: '口碑好',
                ),
                onNotInterested: () => notInterested++,
              ),
            ],
          ),
        ),
      );
      expect(find.text('富集片'), findsOneWidget);
      expect(find.textContaining('2021'), findsWidgets);
      expect(find.textContaining('节奏紧凑'), findsWidgets);
      expect(find.text('降级片'), findsOneWidget);
      expect(find.textContaining('未富集'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('ai-recommendation-not-interested-富集片')));
      await tester.pump();
      expect(notInterested, 1);
    });

    testWidgets('置信度徽章区分高/低置信', (tester) async {
      await tester.pumpWidget(
        host(
          const Column(
            children: [
              AiConfidenceBadge(confidence: 0.92),
              AiConfidenceBadge(confidence: 0.3),
            ],
          ),
        ),
      );
      expect(find.textContaining('92%'), findsOneWidget);
      expect(find.textContaining('低置信'), findsOneWidget);
    });

    testWidgets('分组规则预览必须人工确认后才可应用', (tester) async {
      var confirmed = false;
      await tester.pumpWidget(
        host(
          AiGroupRulePreview(
            rules: const [
              GroupRuleProposal(name: '腾讯系', regex: '^腾讯.*\$', reason: '同源'),
            ],
            onConfirm: () => confirmed = true,
            onCancel: () {},
          ),
        ),
      );
      expect(find.textContaining('腾讯系'), findsWidgets);
      expect(find.text('应用规则'), findsOneWidget);
      expect(confirmed, isFalse);
      await tester.tap(find.text('应用规则'));
      await tester.pump();
      expect(confirmed, isTrue);
    });

    testWidgets('低置信广告结论只显示警告，不提供应用按钮', (tester) async {
      await tester.pumpWidget(
        host(
          const AiAdRulePreview(
            assessment: AdRuleAssessment(
              verdict: AdRuleVerdict.warningOnly,
              warnings: ['置信度不足，仅供参考'],
            ),
            onConfirm: null,
            onCancel: null,
          ),
        ),
      );
      expect(find.textContaining('仅供参考'), findsWidgets);
      expect(find.text('应用规则'), findsNothing);
    });

    testWidgets('日志诊断四段渲染，缺段显示占位', (tester) async {
      await tester.pumpWidget(
        host(
          AiLogDiagnosisView(
            result: parseLogDiagnosis('结论：线路超时\n证据：504\n建议：换线路'),
          ),
        ),
      );
      expect(find.textContaining('线路超时'), findsWidgets);
      expect(find.textContaining('504'), findsWidgets);
      expect(find.textContaining('还缺什么'), findsWidgets);
    });
  });
}
