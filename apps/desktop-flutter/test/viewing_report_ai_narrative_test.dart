import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/viewing_report_ai_narrative.dart';
import 'package:webhtv_pc/ui/viewing_report_ai_view.dart';

const _json = '{"summary":"你的观影集中在下午与工作日。","tags":["下午常看","剧集为主"],'
    '"badges":[],"genreInsights":"以剧情、爱情为主。",'
    '"highlights":["播完率 27.3%,偏试看","前 5 部占 52.6% 时长"],'
    '"recommendationHint":"优先选已完结剧,固定时段集中看。"}';

void main() {
  group('AI 解读解析', () {
    test('把 JSON 拆成五段，空数组/空串占位被丢弃', () {
      final narrative = ViewingReportAiNarrative.parse(_json)!;
      expect(narrative.summary, contains('下午与工作日'));
      expect(narrative.tags, ['下午常看', '剧集为主']);
      expect(narrative.badges, isEmpty, reason: '截图里的 "badges":[],[] 这类空占位要丢掉');
      expect(narrative.genreInsights, contains('剧情'));
      expect(narrative.highlights, hasLength(2));
      expect(narrative.recommendationHint, contains('已完结剧'));
    });

    test('纯文本不是 JSON 时返回 null（调用方回退原文）', () {
      expect(ViewingReportAiNarrative.parse('你偏爱深夜追剧。'), isNull);
      expect(ViewingReportAiNarrative.parse(''), isNull);
    });

    test('JSON 里没有可用字段时返回 null，不显示空面板', () {
      expect(ViewingReportAiNarrative.parse('{"other":1}'), isNull);
      expect(ViewingReportAiNarrative.parse('{"summary":"   "}'), isNull);
    });

    test('超长字段与过多条目被截断', () {
      final long = 'x' * 5000;
      final many = [for (var i = 0; i < 30; i++) 'tag$i'];
      final narrative = ViewingReportAiNarrative.parse(
        jsonEncode({'summary': long, 'tags': many}),
      )!;
      expect(narrative.summary.length,
          lessThanOrEqualTo(ViewingReportAiNarrative.maxFieldLength + 1));
      expect(narrative.tags.length, ViewingReportAiNarrative.maxTags);
    });
  });

  group('AI 解读展示', () {
    Future<void> pump(WidgetTester tester, String text) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ViewingReportAiNarrativeView(text: text),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('结构化展示：摘要/标签/洞察/亮点/建议分区，不再出现裸 JSON', (tester) async {
      await pump(tester, _json);
      expect(
        find.byKey(const ValueKey('viewing-report-ai-narrative')),
        findsOneWidget,
      );
      expect(find.text('类型偏好'), findsOneWidget);
      expect(find.text('值得注意'), findsOneWidget);
      expect(find.text('下一步建议'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('viewing-report-ai-tags')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('viewing-report-ai-badges')),
        findsNothing,
        reason: '空 badges 不该渲染空面板',
      );
      // 关键回归：不能再把原始 JSON 贴出来。
      expect(find.textContaining('"summary"'), findsNothing);
      expect(find.textContaining('recommendationHint'), findsNothing);
    });

    testWidgets('非 JSON 输出回退为原文，内容不丢', (tester) async {
      await pump(tester, '你偏爱深夜追剧。');
      expect(find.byKey(const ValueKey('viewing-report-ai-text')), findsOneWidget);
      expect(find.text('你偏爱深夜追剧。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('viewing-report-ai-narrative')),
        findsNothing,
      );
    });

    testWidgets('只有摘要时只渲染摘要，不出现空标题', (tester) async {
      await pump(tester, '{"summary":"只有一段摘要。"}');
      expect(find.text('只有一段摘要。'), findsOneWidget);
      expect(find.text('类型偏好'), findsNothing);
      expect(find.text('值得注意'), findsNothing);
      expect(find.text('下一步建议'), findsNothing);
    });
  });
}
