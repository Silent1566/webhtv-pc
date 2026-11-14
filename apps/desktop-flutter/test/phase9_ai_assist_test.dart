import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_assist.dart';

void main() {
  group('P1-10 提示词（README §4.2）', () {
    test('四种任务都声明数据不可信，并带数据边界', () {
      for (final task in AiAssistTask.values) {
        final prompt = buildAiAssistPrompt(task: task, input: 'payload');
        expect(prompt, contains('不可信内容'));
        expect(prompt, contains('数据开始 >>>'));
        expect(prompt, contains('payload'));
        expect(prompt, contains('<<< 数据结束'));
        expect(prompt, contains(task.label));
      }
    });

    test('每种任务都要求 JSON 输出', () {
      expect(
        buildAiAssistPrompt(task: AiAssistTask.titleClean, input: 'x'),
        contains('{"title"'),
      );
      expect(
        buildAiAssistPrompt(task: AiAssistTask.logDiagnosis, input: 'x'),
        contains('"causes"'),
      );
      expect(
        buildAiAssistPrompt(task: AiAssistTask.groupSuggestion, input: 'x'),
        contains('"groups"'),
      );
      expect(
        buildAiAssistPrompt(task: AiAssistTask.adSegmentReview, input: 'x'),
        contains('"segments"'),
      );
    });

    test('超长输入被截断（保留尾部）', () {
      final long = '${'a' * 9000}TAIL';
      final clipped = clipAiAssistInput(long);
      expect(clipped.length, lessThan(9000));
      expect(clipped, endsWith('TAIL'));
    });

    test('分组建议带入已有分组', () {
      final prompt = buildAiAssistPrompt(
        task: AiAssistTask.groupSuggestion,
        input: 'x',
        extra: {'groups': '盘|采'},
      );
      expect(prompt, contains('盘|采'));
    });
  });

  group('P1-10 输出解析（README §4.2）', () {
    test('容忍代码围栏与前后说明', () {
      final result = parseAiAssistOutput(
        '说明文字\n```json\n{"title":"某剧","year":2024}\n```\n后记',
        task: AiAssistTask.titleClean,
      );
      expect(result.ok, isTrue);
      expect(result.cleanedTitle, '某剧');
      expect(result.cleanedYear, 2024);
    });

    test('尾随逗号可解析', () {
      final result = parseAiAssistOutput(
        '{"title":"某剧","year":2024,}',
        task: AiAssistTask.titleClean,
      );
      expect(result.ok, isTrue);
      expect(result.cleanedTitle, '某剧');
    });

    test('缺关键字段视为失败，不把部分结果当成功', () {
      expect(
        parseAiAssistOutput('{"year":2024}', task: AiAssistTask.titleClean).ok,
        isFalse,
      );
      expect(
        parseAiAssistOutput('{"nope":1}', task: AiAssistTask.logDiagnosis).ok,
        isFalse,
      );
      expect(
        parseAiAssistOutput('没有 JSON', task: AiAssistTask.titleClean).error,
        isNotNull,
      );
    });

    test('日志诊断最多 3 条且字段必须齐全', () {
      final result = parseAiAssistOutput(
        '{"causes":['
        '{"reason":"r1","action":"a1"},'
        '{"reason":"r2","action":"a2"},'
        '{"reason":"r3","action":"a3"},'
        '{"reason":"r4","action":"a4"},'
        '{"reason":"缺 action"}'
        ']}',
        task: AiAssistTask.logDiagnosis,
      );
      expect(result.causes, hasLength(3));
      expect(result.causes.first.reason, 'r1');
    });

    test('分组建议去重并限制 3 个', () {
      final result = parseAiAssistOutput(
        '{"groups":["盘","盘","采","官","影"]}',
        task: AiAssistTask.groupSuggestion,
      );
      expect(result.suggestedGroups, ['盘', '采', '官']);
    });

    test('广告分片行号必须 >=1', () {
      final result = parseAiAssistOutput(
        '{"segments":[{"line":0,"reason":"x"},{"line":3,"reason":"时长异常"}]}',
        task: AiAssistTask.adSegmentReview,
      );
      expect(result.adSegments, hasLength(1));
      expect(result.adSegments.single.line, 3);
    });

    test('年份越界被丢弃', () {
      final result = parseAiAssistOutput(
        '{"title":"某剧","year":12345}',
        task: AiAssistTask.titleClean,
      );
      expect(result.cleanedTitle, '某剧');
      expect(result.cleanedYear, isNull);
    });

    test('JSON 字符串内的花括号不影响截取', () {
      final result = parseAiAssistOutput(
        '{"title":"某剧 {特别版}","year":null}',
        task: AiAssistTask.titleClean,
      );
      expect(result.ok, isTrue);
      expect(result.cleanedTitle, '某剧 {特别版}');
    });
  });
}
