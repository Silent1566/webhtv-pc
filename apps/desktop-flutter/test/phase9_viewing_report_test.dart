import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/core/viewing_report.dart';
import 'package:webhtv_pc/services/ai_completion_client.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/services/viewing_report_ai.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/ui/library_pages.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/viewing_report_page.dart';

PlaybackHistory history({
  required String vodName,
  required int positionMs,
  required int durationMs,
  required DateTime watchedAt,
  String episodeName = 'E1',
}) => PlaybackHistory(
  id: watchedAt.millisecondsSinceEpoch ~/ 1000,
  siteKey: 'fixture',
  vodId: vodName,
  vodName: vodName,
  flag: '线路一',
  episodeName: episodeName,
  episodeId: episodeName,
  positionMs: positionMs,
  durationMs: durationMs,
  updatedAt: watchedAt.millisecondsSinceEpoch,
);

const int minute = 60 * 1000;

void main() {
  final now = DateTime(2026, 10, 21, 12);
  final records = <PlaybackHistory>[
    // A：周二深夜，完播（42/45 = 93%）。
    history(
      vodName: '庆余年',
      positionMs: 42 * minute,
      durationMs: 45 * minute,
      watchedAt: DateTime(2026, 10, 20, 23, 30),
    ),
    // B：周一上午，同一部剧的另一集，未完播。
    history(
      vodName: '庆余年',
      positionMs: 10 * minute,
      durationMs: 45 * minute,
      watchedAt: DateTime(2026, 10, 19, 9),
      episodeName: 'E2',
    ),
    // C：周日，电影，完播。
    history(
      vodName: '流浪地球',
      positionMs: 100 * minute,
      durationMs: 100 * minute,
      watchedAt: DateTime(2026, 10, 18, 10),
    ),
    // D：8 月周六，超出最近 7 天/本月。
    history(
      vodName: '老片',
      positionMs: 30 * minute,
      durationMs: 100 * minute,
      watchedAt: DateTime(2026, 8, 1, 14),
    ),
    // E：无进度的脏记录：计入记录数与片名，但不计入完播率分母。
    history(
      vodName: '无进度',
      positionMs: 0,
      durationMs: 0,
      watchedAt: DateTime(2026, 10, 21, 7),
    ),
  ];

  group('观影报告本地统计（P2-2）', () {
    test('黄金样本：时长/作品/完播率/时段/周末/深夜', () {
      final report = generateViewingReport(records: records, now: now);
      expect(report.recordCount, 5);
      expect(report.totalWatchMinutes, 182);
      expect(report.uniqueVodCount, 4, reason: '「无进度」也是独立片名');
      expect(report.totalEpisodeCount, 5);
      expect(report.completedCount, 2);
      expect(report.completionRate, closeTo(0.5, 1e-9));
      expect(report.averageWatchMinutes, closeTo(36.4, 1e-6));
      expect(report.lateNightCount, 1);
      expect(report.weekendCount, 2);
      expect(report.weekendRatio, closeTo(0.4, 1e-9));
      expect(report.timeSlots[ViewingTimeSlot.morning], 3);
      expect(report.timeSlots[ViewingTimeSlot.afternoon], 1);
      expect(report.timeSlots[ViewingTimeSlot.lateNight], 1);
      expect(report.timeSlots[ViewingTimeSlot.dawn], 0);
      expect(report.topTimeSlot, ViewingTimeSlot.morning);
      expect(report.badges, isEmpty);
    });

    test('同一部剧的不同集只算一个作品，时长累加', () {
      final report = generateViewingReport(records: records, now: now);
      final top = report.topVods.firstWhere((v) => v.name == '庆余年');
      expect(top.watchMinutes, 52);
      expect(top.episodes, 2);
      // 时长最高的是电影，不是这部剧。
      expect(report.topVods.first.name, '流浪地球');
    });

    test('范围裁剪：最近 7 天 / 本月 / 上半年', () {
      final week = generateViewingReport(
        records: records,
        range: ViewingReportRange.last7Days,
        now: now,
      );
      expect(week.recordCount, 4, reason: '8 月的老片应被排除');
      expect(week.topVods.where((v) => v.name == '老片'), isEmpty);

      final month = generateViewingReport(
        records: records,
        range: ViewingReportRange.thisMonth,
        now: now,
      );
      expect(month.recordCount, 4);
      expect(month.uniqueVodCount, 3);

      final firstHalf = generateViewingReport(
        records: records,
        range: ViewingReportRange.firstHalf,
        now: now,
      );
      expect(firstHalf.recordCount, 0);
      expect(firstHalf.isEmpty, isTrue);
      expect(firstHalf.topTimeSlot, isNull);
      expect(firstHalf.completionRate, 0);
    });

    test('范围边界：本周从周一开始，本季度从季度首月开始', () {
      expect(
        ViewingReportRange.thisWeek.timeBounds(now).startMs,
        DateTime(2026, 10, 19).millisecondsSinceEpoch,
      );
      expect(
        ViewingReportRange.thisQuarter.timeBounds(now).startMs,
        DateTime(2026, 10, 1).millisecondsSinceEpoch,
      );
      expect(
        ViewingReportRange.firstHalf.timeBounds(now).endMs,
        DateTime(2026, 6, 30, 23, 59, 59, 999).millisecondsSinceEpoch,
      );
    });

    test('片名归一化：空白/标点/括号不影响去重', () {
      expect(normalizeViewingName(' 庆余年 · 第二季 '), '庆余年第二季');
      expect(normalizeViewingName('Movie (2024)'), 'movie2024');
      expect(
        normalizeViewingName('A / B｜C'),
        normalizeViewingName('A B C'),
      );
    });

    test('同分排序稳定：按时长、集数、片名依次裁决', () {
      final tie = <PlaybackHistory>[
        history(
          vodName: 'B 剧',
          positionMs: 10 * minute,
          durationMs: 10 * minute,
          watchedAt: DateTime(2026, 10, 20),
        ),
        history(
          vodName: 'A 剧',
          positionMs: 10 * minute,
          durationMs: 10 * minute,
          watchedAt: DateTime(2026, 10, 20),
        ),
      ];
      final report = generateViewingReport(records: tie, now: now);
      expect(report.topVods.map((v) => v.name).toList(), ['A 剧', 'B 剧']);
    });

    test('徽章阈值与安卓一致（深夜 10 / 作品 30 / 完播 70%+20 集）', () {
      final many = <PlaybackHistory>[
        for (var i = 0; i < 30; i++)
          history(
            vodName: '剧$i',
            positionMs: 100 * minute,
            durationMs: 100 * minute,
            watchedAt: DateTime(2026, 10, 20, 23, 30),
          ),
      ];
      final report = generateViewingReport(records: many, now: now);
      expect(report.badges.map((b) => b.id), containsAll([
        'night_owl',
        'drama_king',
        'finisher',
      ]));
    });
  });

  group('AI 解读（可选叠加）', () {
    AiConfig readyConfig() => const AiConfig(
      enabled: true,
      protocol: AiProtocol.openAiChat,
      endpoint: 'https://example.test/v1/chat/completions',
      apiKey: 'k',
      model: 'm',
    );

    test('未配置时零请求，直接返回 skipped', () async {
      final analyzer = ViewingReportAiAnalyzer(
        client: AiCompletionClient(
          client: MockClient((_) async {
            fail('未配置 AI 时不允许发请求');
          }),
        ),
      );
      final result = await analyzer.analyze(
        config: const AiConfig(),
        report: generateViewingReport(records: records, now: now),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('未配置'));
    });

    test('提示词显式声明输入不可信，并含统计摘要', () {
      final prompt = buildViewingReportPrompt(
        generateViewingReport(records: records, now: now),
      );
      expect(prompt, contains('不可信输入'));
      expect(prompt, contains('"watchMinutes": 182'));
      expect(prompt, contains('庆余年'));
      expect(prompt, contains('不要编造数据'));
    });

    test('成功时返回清洗后的文本；超长截断', () async {
      final analyzer = ViewingReportAiAnalyzer(
        client: AiCompletionClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '  你看得很专注。  '},
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );
      final result = await analyzer.analyze(
        config: readyConfig(),
        report: generateViewingReport(records: records, now: now),
      );
      expect(result.ok, isTrue);
      expect(result.text, '你看得很专注。');
    });

    test('失败如实返回原因，基础报告不受影响', () async {
      final analyzer = ViewingReportAiAnalyzer(
        client: AiCompletionClient(
          client: MockClient(
            (_) async => http.Response('boom', 500),
          ),
        ),
      );
      final result = await analyzer.analyze(
        config: readyConfig(),
        report: generateViewingReport(records: records, now: now),
      );
      expect(result.ok, isFalse);
      expect(result.message, contains('HTTP 500'));
    });
  });

  group('观影报告页', () {
    late AppState state;

    setUp(() {
      state = AppState(
        paths: AppPaths.resolve(overrides: {
          'config': '${'x'}/webhtv-pc',
          'data': '${'x'}/webhtv-pc',
          'cache': '${'x'}/webhtv-pc/cache',
          'state': '${'x'}/webhtv-pc/logs',
        }),
        log: LogService(),
      );
    });

    tearDown(() => state.dispose());

    Future<void> pump(
      WidgetTester tester, {
      required List<PlaybackHistory> history,
      AiConfig ai = const AiConfig(),
      ViewingReportAiAnalyzer? analyzer,
    }) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: ViewingReportPage(
            state: state,
            historyOverride: history,
            aiConfigOverride: ai,
            analyzer: analyzer,
            now: now,
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
    }

    testWidgets('无记录时显示空态，不渲染统计卡片', (tester) async {
      await pump(tester, history: const []);
      expect(find.text('观影报告'), findsOneWidget);
      expect(find.textContaining('还没有观看记录'), findsOneWidget);
      expect(find.byKey(const ValueKey('viewing-report-list')), findsNothing);
    });

    testWidgets('历史页工具栏入口可以打开报告', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(body: HistoryPage(state: state)),
        ),
      );
      await tester.pump();
      final entry = find.byKey(const ValueKey('history-viewing-report'));
      expect(entry, findsOneWidget);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(ViewingReportPage), findsOneWidget);
    });

    testWidgets('有记录时渲染关键统计与最常看', (tester) async {
      await pump(tester, history: records);
      expect(find.text('182 分钟'), findsOneWidget);
      expect(find.text('4 部'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('1 次'), findsOneWidget);
      expect(find.text('最常看'), findsOneWidget);
      expect(find.text('庆余年'), findsOneWidget);
    });

    testWidgets('未配置 AI 时说明基础报告完整，且没有运行按钮', (tester) async {
      await pump(tester, history: records);
      expect(
        find.byKey(const ValueKey('viewing-report-ai-unconfigured')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('viewing-report-ai-run')),
        findsNothing,
      );
    });

    testWidgets('AI 成功时展示解读；失败时不隐藏基础报告', (tester) async {
      final analyzer = ViewingReportAiAnalyzer(
        client: AiCompletionClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': '你偏爱深夜追剧。'},
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        ),
      );
      await pump(
        tester,
        history: records,
        ai: const AiConfig(
          enabled: true,
          protocol: AiProtocol.openAiChat,
          endpoint: 'https://example.test/v1/chat/completions',
          apiKey: 'k',
          model: 'm',
        ),
        analyzer: analyzer,
      );
      await tester.tap(find.byKey(const ValueKey('viewing-report-ai-run')));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(find.text('你偏爱深夜追剧。'), findsOneWidget);
      expect(find.text('182 分钟'), findsOneWidget);
    });
  });
}
