import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/ai_content/recommendation.dart';
import 'package:webhtv_pc/core/viewing_report.dart';
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
import 'package:webhtv_pc/ui/ai_content/ai_content_page.dart';

AiConfig readyConfig() => const AiConfig(
  enabled: true,
  apiKey: 'k',
  endpoint: 'https://example.com/v1',
  model: 'm',
);

/// 页面级 smoke 测试：真实服务 + 可注入的「模型」，验证入口到结果可用。
void main() {
  late Directory tempRoot;
  final now = DateTime(2026, 11, 10, 12);

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('ai_content_page_test');
  });

  tearDown(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  testWidgets('推荐分区：点击生成后展示真实卡片与「不感兴趣」', (tester) async {
    final paths = AiContentPaths(
      dataDir: '${tempRoot.path}/data',
      cacheDir: '${tempRoot.path}/cache',
    );
    var calls = 0;
    final completion = AiContentCompletion(
      complete: ({required AiConfig config, required String prompt, Duration timeout = Duration.zero}) async {
        calls++;
        return AiCompletionResult(
          ok: true,
          statusCode: 200,
          text:
              '{"items":[{"title":"页面片单","year":2024,'
              '"mediaType":"movie","reason":"测试推荐"}]}',
          message: '',
        );
      },
    );
    final services = AiContentServices(
      recommendation: RecommendationService(
        config: readyConfig,
        paths: paths,
        completion: completion,
        clock: () => now,
      ),
      title: TitleResolutionService(
        config: readyConfig,
        paths: paths,
        completion: completion,
        clock: () => now,
      ),
      group: GroupRuleService(
        config: readyConfig,
        paths: paths,
        completion: completion,
      ),
      ad: AdRuleService(
        config: readyConfig,
        paths: paths,
        completion: completion,
      ),
      logDiagnosis: LogDiagnosisService(
        config: readyConfig,
        completion: completion,
        logSource: () async => 'log line',
      ),
      profile: ViewingProfileService(
        config: readyConfig,
        paths: paths,
        completion: completion,
        clock: () => now,
      ),
      userData: AiContentUserDataStore(paths: paths, clock: () => now),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiContentPage(
            deps: AiContentPageDeps(
              services: services,
              loadSnapshot: () async => AiContentPageSnapshot(
                contexts: const [
                  WatchContextItem(
                    title: '上下文片',
                    mediaType: RecommendationMediaType.tv,
                    year: 2023,
                  ),
                ],
                siteNames: const ['腾讯视频', '腾讯体育'],
                report: generateViewingReport(
                  records: const [],
                  range: ViewingReportRange.all,
                  now: now,
                ),
                latestUpdatedAtMs: 0,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('推荐'), findsOneWidget);
    expect(find.text('画像'), findsOneWidget);

    await tester.tap(find.text('生成推荐'));
    // 页面内部有真实文件 IO：用 runAsync 推进真实异步，再逐帧 pump。
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
      if (find.text('页面片单').evaluate().isNotEmpty) break;
    }

    expect(tester.takeException(), isNull);
    expect(calls, 1);
    expect(find.text('页面片单'), findsOneWidget);
    expect(find.textContaining('已生成'), findsOneWidget);
  });
}
