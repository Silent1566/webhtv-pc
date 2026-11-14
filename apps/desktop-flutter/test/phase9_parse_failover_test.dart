import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/parse_failover.dart';
import 'package:webhtv_pc/core/parse_runtime.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/parse_service.dart';

void main() {
  const primaryEntry = ParseEntry(
    name: 'A',
    type: 1,
    url: 'https://a.test/parse',
  );
  final primary = ParseSelection(entry: primaryEntry, kind: ParseKind.json);

  group('P1-4 失败切换候选（design/00 §5）', () {
    final entries = [
      primaryEntry,
      const ParseEntry(name: 'B', type: 1, url: 'https://b.test/parse'),
      const ParseEntry(name: 'C', type: 0, url: 'https://c.test/parse'),
      const ParseEntry(name: 'D', type: 3, url: ''),
      const ParseEntry(name: 'E', type: 2, url: 'https://e.test/parse'),
      const ParseEntry(name: 'B', type: 1, url: 'https://b.test/parse'),
    ];

    test('关闭或只允许一次时不产生候选', () {
      expect(
        parseFailoverSelections(
          primary: primary,
          entries: entries,
          settings: const ParseFailoverSettings(),
        ),
        isEmpty,
      );
      expect(
        parseFailoverSelections(
          primary: primary,
          entries: entries,
          settings: const ParseFailoverSettings(
            enabled: true,
            maxAttempts: 1,
          ),
        ),
        isEmpty,
      );
    });

    test('只收支持的 JSON 类、排除首选、去重、保序、受上限约束', () {
      final selections = parseFailoverSelections(
        primary: primary,
        entries: entries,
        settings: const ParseFailoverSettings(
          enabled: true,
          maxAttempts: 3,
        ),
      );
      expect(selections.map((s) => s.entry.name), ['B', 'E']);
      expect(selections.every((s) => parseKindSupported(s.kind)), isTrue);

      final limited = parseFailoverSelections(
        primary: primary,
        entries: entries,
        settings: const ParseFailoverSettings(
          enabled: true,
          maxAttempts: 2,
        ),
      );
      expect(limited.map((s) => s.entry.name), ['B']);
    });
  });

  group('P1-4 失败切换执行（design/00 §5）', () {
    test('首选解析错误 → 次选成功，返回次选结果', () async {
      final service = _FakeParseService({
        'A': AppError(AppErrorKind.parseNetwork, 'timeout'),
        'B': 'https://media.test/x.m3u8',
      });
      final result = await service.runWithFallback(
        selection: primary,
        entries: [
          primaryEntry,
          const ParseEntry(name: 'B', type: 1, url: 'https://b.test/parse'),
        ],
        webUrl: 'https://media.test/x',
        failover: const ParseFailoverSettings(enabled: true),
      );
      expect(result.entryName, 'B');
      expect(result.url, 'https://media.test/x.m3u8');
      expect(service.calls, ['A', 'B']);
    });

    test('关闭时直接抛出首选错误，不尝试次选', () async {
      final service = _FakeParseService({
        'A': AppError(AppErrorKind.parseEmpty, 'empty'),
        'B': 'https://media.test/x.m3u8',
      });
      await expectLater(
        service.runWithFallback(
          selection: primary,
          entries: [
            primaryEntry,
            const ParseEntry(name: 'B', type: 1, url: 'https://b.test/parse'),
          ],
          webUrl: 'https://media.test/x',
        ),
        throwsA(isA<AppError>()),
      );
      expect(service.calls, ['A']);
    });

    test('非解析错误不重试（不做无意义尝试）', () async {
      final service = _FakeParseService({
        'A': StateError('bug'),
        'B': 'https://media.test/x.m3u8',
      });
      await expectLater(
        service.runWithFallback(
          selection: primary,
          entries: [
            primaryEntry,
            const ParseEntry(name: 'B', type: 1, url: 'https://b.test/parse'),
          ],
          webUrl: 'https://media.test/x',
          failover: const ParseFailoverSettings(enabled: true),
        ),
        throwsA(isA<StateError>()),
      );
      expect(service.calls, ['A']);
    });

    test('全部失败时抛出最后一个解析错误', () async {
      final service = _FakeParseService({
        'A': AppError(AppErrorKind.parseNetwork, 'a failed'),
        'B': AppError(AppErrorKind.parseInvalid, 'b failed'),
      });
      try {
        await service.runWithFallback(
          selection: primary,
          entries: [
            primaryEntry,
            const ParseEntry(name: 'B', type: 1, url: 'https://b.test/parse'),
          ],
          webUrl: 'https://media.test/x',
          failover: const ParseFailoverSettings(enabled: true),
        );
        fail('应当抛出');
      } on AppError catch (error) {
        expect(error.message, 'b failed');
      }
      expect(service.calls, ['A', 'B']);
    });
  });
}

class _FakeParseService extends ParseService {
  _FakeParseService(this.behavior);

  final Map<String, Object> behavior;
  final List<String> calls = [];

  @override
  Future<ParseRunResult> run({
    required ParseSelection selection,
    required List<ParseEntry> entries,
    required String webUrl,
    String? flag,
    String? source,
  }) async {
    calls.add(selection.entry.name);
    final value = behavior[selection.entry.name];
    if (value is Exception) throw value;
    if (value is Error) throw value;
    if (value is String) {
      return ParseRunResult(
        url: value,
        headers: const {},
        parseKind: selection.kind,
        source: source ?? 'parse',
        entryName: selection.entry.name,
      );
    }
    throw AppError(AppErrorKind.parseEmpty, 'no behavior');
  }
}
