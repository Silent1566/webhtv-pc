/// IntroDB（`api.introdb.app`）：只认 IMDb 键 + 季集号。
///
/// 实测响应（2026-11）：四个顶层字段是**对象**而不是数组，
/// `recap` / `intro` / `outro` / `post_credits` 各自最多一段，
/// 没有的那类是 `null`。
library;

import 'package:http/http.dart' as http;

import '../../core/skip_plan.dart';
import 'provider.dart';

/// IntroDB 数据源。
class IntroDbProvider extends IntroSkipProvider {
  const IntroDbProvider();

  static const String _endpoint = 'https://api.introdb.app/segments';

  /// 顶层字段名 → 段类型。
  ///
  /// 这家只有这四个字段（实测响应键集恒为 recap/intro/outro/post_credits），
  /// **没有「下集预告」字段**；`post_credits` 是片尾之后的彩蛋/附加内容，与预告
  /// 是两种东西，所以单独映射成 [SkipKind.postCredits] 而不是并进预告。
  static const Map<String, SkipKind> _fields = <String, SkipKind>{
    'recap': SkipKind.recap,
    'intro': SkipKind.intro,
    'outro': SkipKind.outro,
    'post_credits': SkipKind.postCredits,
  };

  @override
  String get id => 'introdb';

  @override
  String get name => 'IntroDB';

  @override
  int get sourceBit => SkipSourceBits.introdb;

  /// 没有 IMDb 键（或季集号）时这家**查不了**：算「这集没数据」而不是「没答
  /// 上来」，否则只有 TMDB 键的查询会因为这一家永远不可缓存，每集都重打一轮。
  @override
  Future<List<RawSkipSegment>?> fetch(
    SkipQuery query, {
    required http.Client client,
  }) async {
    if (!query.hasImdbEpisode) return const <RawSkipSegment>[];
    final uri = Uri.parse(_endpoint).replace(
      queryParameters: <String, String>{
        'imdb_id': query.imdbId.trim(),
        'season': query.season.toString(),
        'episode': query.episode.toString(),
      },
    );
    final http.Response response;
    try {
      response = await client.get(uri);
    } catch (_) {
      return null;
    }
    // 404 是「这集没标过」，是结论；其它非 2xx 是这家出问题了，不是结论。
    if (response.statusCode == 404) return const <RawSkipSegment>[];
    if (!skipIsSuccessStatus(response.statusCode)) return null;
    final root = skipDecodeJsonObject(response);
    if (root == null) return null;
    final reference = _referenceDurationOf(root);
    final segments = <RawSkipSegment>[];
    for (final entry in _fields.entries) {
      final body = skipJsonObject(root[entry.key]);
      if (body == null) continue;
      final start = _timeOf(body, 'start');
      final end = _timeOf(body, 'end');
      // 整段一个时间点都读不出来：这条记录对播放器毫无用处，丢掉。
      if (start == null && end == null) continue;
      segments.add(
        RawSkipSegment(
          kind: entry.value,
          provider: id,
          startMs: start,
          endMs: end,
          referenceDurationMs: reference,
          confidence: skipJsonConfidence(body['confidence']),
          submissionCount: skipJsonSubmissionCount(body['submission_count']),
        ),
      );
    }
    return segments;
  }

  /// 优先毫秒字段，缺了退回秒字段乘 1000。
  static int? _timeOf(Map<String, Object?> body, String prefix) =>
      skipJsonMs(body['${prefix}_ms']) ??
      skipJsonSecondsToMs(body['${prefix}_sec']);

  /// 标定所用版本的时长；四个别名都认，都没有则 0（= 无从折算）。
  static int _referenceDurationOf(Map<String, Object?> root) {
    final ms =
        skipJsonMs(root['duration_ms']) ?? skipJsonMs(root['runtime_ms']);
    if (ms != null && ms > 0) return ms;
    final seconds =
        skipJsonSecondsToMs(root['duration_sec']) ??
        skipJsonSecondsToMs(root['runtime_sec']);
    return seconds ?? 0;
  }
}
