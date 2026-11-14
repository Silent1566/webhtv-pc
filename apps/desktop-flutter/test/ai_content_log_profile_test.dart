import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ai_content/log_diagnosis.dart';
import 'package:webhtv_pc/core/ai_content/viewing_profile.dart';
import 'package:webhtv_pc/core/viewing_report.dart';
import 'package:webhtv_pc/services/storage.dart';

PlaybackHistory history({
  required String vodName,
  required int positionMs,
  required int durationMs,
  required DateTime watchedAt,
}) => PlaybackHistory(
  id: watchedAt.millisecondsSinceEpoch ~/ 1000,
  siteKey: 'fixture',
  vodId: vodName,
  vodName: vodName,
  flag: '线路一',
  episodeName: 'E1',
  episodeId: 'E1',
  positionMs: positionMs,
  durationMs: durationMs,
  updatedAt: watchedAt.millisecondsSinceEpoch,
);

const int minute = 60 * 1000;

void main() {
  group('日志脱敏（发送前）', () {
    test('Authorization 头被替换', () {
      final out = sanitizeAiLogText(
        'request headers: Authorization: Bearer sk-abc123\n',
      );
      expect(out, contains('<redacted>'));
      expect(out, isNot(contains('sk-abc123')));
    });

    test('api-key/token/cookie 字段被替换', () {
      final out = sanitizeAiLogText(
        '{"apiKey":"sk-live-1","x-api-key":"k2","cookie":"c=1",'
        '"access_token":"t3"}',
      );
      expect(out, isNot(contains('sk-live-1')));
      expect(out, isNot(contains('"k2"')));
      expect(out, isNot(contains('c=1')));
      expect(out, isNot(contains('t3')));
      expect(out, contains('<redacted>'));
    });

    test('URL query 里的 key/token/sign 被替换', () {
      final out = sanitizeAiLogText(
        'GET https://x.com/a?key=abc&token=def&sign=ghi&page=2',
      );
      expect(out, isNot(contains('key=abc')));
      expect(out, isNot(contains('token=def')));
      expect(out, isNot(contains('sign=ghi')));
      // 非敏感参数保留，便于诊断。
      expect(out, contains('page=2'));
    });

    test('裸 Bearer/Basic token 也被替换（M6）', () {
      final out = sanitizeAiLogText(
        'retry with Bearer sk-bare-token-1 failed\n'
        'proxy said: Basic dXNlcjpwYXNz',
      );
      expect(out, isNot(contains('sk-bare-token-1')));
      expect(out, isNot(contains('dXNlcjpwYXNz')));
      expect(out, contains('<redacted>'));
    });

    test('字段名带前缀时仍按单词边界匹配（M6）', () {
      // `myauthorization` 不是 authorization 字段，不能被当成凭据改写。
      final untouched = sanitizeAiLogText('myauthorization: keep-me');
      expect(untouched, contains('keep-me'));
      // 正常写法仍然被脱敏。
      final redacted = sanitizeAiLogText('authorization: sk-secret-2');
      expect(redacted, isNot(contains('sk-secret-2')));
    });
  });

  group('日志截尾（28Ki 字符）', () {
    test('不超限时只 trim', () {
      expect(sanitizeAiLogText('  hello  '), 'hello');
      expect(clipAiLogTail('x' * 10), 'x' * 10);
    });

    test('超限保留尾部并写明被截断的长度', () {
      final raw = '${'a' * 100}${'b' * (aiLogMaxChars + 50)}';
      final clipped = clipAiLogTail(raw);
      expect(clipped, startsWith('...<truncated '));
      expect(clipped, contains(' chars>'));
      expect(clipped.length, lessThan(raw.length));
      // 尾部内容（最近日志）必须保留。
      expect(clipped.endsWith('b'), isTrue);
    });

    test('诊断入口同时脱敏与截尾', () {
      final raw = 'Authorization: Bearer secret ${'z' * (aiLogMaxChars + 10)}';
      final safe = buildSanitizedLogPayload(raw);
      expect(safe, isNot(contains('secret')));
      expect(safe.length, lessThanOrEqualTo(aiLogMaxChars + 64));
      expect(aiLogMaxChars, 28 * 1024);
    });
  });

  group('日志诊断结构（中文四段）', () {
    const model =
        '结论：线路超时导致播放失败。\n'
        '证据：日志里有 HTTP 504 与 30s 超时。\n'
        '建议：切换到线路二并重试。\n'
        '还缺什么：需要该时段的完整请求头。';

    test('四段齐全时解析成功', () {
      final result = parseLogDiagnosis(model);
      expect(result.ok, isTrue);
      expect(result.conclusion, contains('超时'));
      expect(result.evidence, contains('504'));
      expect(result.suggestion, contains('线路二'));
      expect(result.missing, contains('请求头'));
    });

    test('缺少建议段时视为不完整，保留可用文本', () {
      final result = parseLogDiagnosis('结论：不知道\n证据：无');
      expect(result.ok, isFalse);
      expect(result.conclusion, contains('不知道'));
      expect(result.suggestion, isEmpty);
    });

    test('空输出解析为失败', () {
      expect(parseLogDiagnosis('   ').ok, isFalse);
    });

    test('提示词声明日志是不可信数据并要求中文四段', () {
      final prompt = buildLogDiagnosisPrompt('日志内容');
      expect(prompt, contains('不可信'));
      expect(prompt, contains('结论'));
      expect(prompt, contains('证据'));
      expect(prompt, contains('建议'));
      expect(prompt, contains('还缺什么'));
    });
  });

  group('结构画像统计', () {
    final now = DateTime(2026, 11, 10, 12);
    final records = <PlaybackHistory>[
      history(
        vodName: '庆余年',
        positionMs: 42 * minute,
        durationMs: 45 * minute,
        watchedAt: DateTime(2026, 11, 9, 23, 30),
      ),
      history(
        vodName: '庆余年',
        positionMs: 20 * minute,
        durationMs: 45 * minute,
        watchedAt: DateTime(2026, 11, 8, 21, 0),
      ),
      history(
        vodName: '流浪地球',
        positionMs: 100 * minute,
        durationMs: 100 * minute,
        watchedAt: DateTime(2026, 11, 7, 10, 0),
      ),
    ];

    ViewingReport reportFor(ViewingReportRange range) => generateViewingReport(
      records: records,
      range: range,
      now: now,
    );

    test('画像带范围 id、指纹与时段分布', () {
      final report = reportFor(ViewingReportRange.last30Days);
      final latest = records
          .map((r) => r.updatedAt)
          .reduce((a, b) => a > b ? a : b);
      final profile = buildViewingProfile(
        report: report,
        latestUpdatedAtMs: latest,
        now: now,
      );
      expect(profile.rangeId, ViewingReportRange.last30Days.name);
      expect(profile.recordCount, 3);
      expect(profile.fingerprint, ViewingProfileFingerprint.of(
        recordCount: 3,
        latestUpdatedAtMs: latest,
      ));
      expect(profile.slotShares[ViewingTimeSlot.lateNight], greaterThan(0));
      expect(profile.completionRate, closeTo(2 / 3, 0.001));
      expect(profile.topVodName, '流浪地球');
    });

    test('指纹只由记录数与最近更新时间决定', () {
      final a = ViewingProfileFingerprint.of(
        recordCount: 3,
        latestUpdatedAtMs: 1000,
      );
      final b = ViewingProfileFingerprint.of(
        recordCount: 3,
        latestUpdatedAtMs: 1000,
      );
      final c = ViewingProfileFingerprint.of(
        recordCount: 4,
        latestUpdatedAtMs: 1000,
      );
      expect(a, b);
      expect(a, isNot(c));
      expect(a.length, 12);
    });
  });

  group('画像缓存：24 小时 + 范围过期保护', () {
    final now = DateTime(2026, 11, 10, 12);

    test('24 小时内且指纹未变时可复用', () {
      expect(
        ViewingProfileCachePolicy.isReusable(
          cachedRangeId: 'last30Days',
          requestedRangeId: 'last30Days',
          cachedFingerprint: 'abc',
          currentFingerprint: 'abc',
          generatedAtMs: now
              .subtract(const Duration(hours: 23))
              .millisecondsSinceEpoch,
          now: now,
        ),
        isTrue,
      );
    });

    test('超过 24 小时或指纹变化即失效', () {
      expect(
        ViewingProfileCachePolicy.isReusable(
          cachedRangeId: 'last30Days',
          requestedRangeId: 'last30Days',
          cachedFingerprint: 'abc',
          currentFingerprint: 'abc',
          generatedAtMs: now
              .subtract(const Duration(hours: 25))
              .millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
      expect(
        ViewingProfileCachePolicy.isReusable(
          cachedRangeId: 'last30Days',
          requestedRangeId: 'last30Days',
          cachedFingerprint: 'abc',
          currentFingerprint: 'abcd',
          generatedAtMs: now.millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });

    test('跨范围缓存绝不复用（旧响应不得显示在新范围上）', () {
      expect(
        ViewingProfileCachePolicy.isReusable(
          cachedRangeId: 'thisMonth',
          requestedRangeId: 'all',
          cachedFingerprint: 'abc',
          currentFingerprint: 'abc',
          generatedAtMs: now.millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
      expect(ViewingProfileCachePolicy.ttl, const Duration(hours: 24));
    });
  });
}
