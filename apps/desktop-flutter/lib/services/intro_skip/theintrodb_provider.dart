/// TheIntroDB（`api.theintrodb.org/v4/media`）：只认 TMDB 键。
///
/// 实测响应（2026-11）：各类型都是**数组**，且很多时间点是 null——
/// `start_ms: null` 表示从 0 开始，`end_ms: null` 表示一直延伸到结尾。
/// null 原样传进 [RawSkipSegment]，填 0 会把「延伸到结尾」变成「到 0 结束」，
/// 折算由 `SkipPlan.resolve` 负责。
library;

import 'package:http/http.dart' as http;

import '../../core/skip_plan.dart';
import 'provider.dart';

/// TheIntroDB 数据源。
class TheIntroDbProvider extends IntroSkipProvider {
  const TheIntroDbProvider();

  static const String _endpoint = 'https://api.theintrodb.org/v4/media';

  /// 顶层字段名 → 段类型；同一类型可以出现在多个字段里。
  static const Map<String, SkipKind> _fields = <String, SkipKind>{
    'recap': SkipKind.recap,
    'intro': SkipKind.intro,
    'credits': SkipKind.outro,
    'preview': SkipKind.preview,
    'next_episode': SkipKind.preview,
    'trailer': SkipKind.preview,
    // 该家文档只列 intros/recaps/credits/previews，目前没观察到这个键；
    // 认它只是为了将来它出现时不被静默丢掉。
    'post_credits': SkipKind.postCredits,
  };

  @override
  String get id => 'theintrodb';

  @override
  String get name => 'TheIntroDB';

  @override
  int get sourceBit => SkipSourceBits.theintrodb;

  /// 没有 TMDB 键时查不了，按「这集没数据」返回（理由同 `IntroDbProvider`）。
  @override
  Future<List<RawSkipSegment>?> fetch(
    SkipQuery query, {
    required http.Client client,
  }) async {
    if (!query.hasTmdb) return const <RawSkipSegment>[];
    final parameters = <String, String>{'tmdb_id': query.tmdbId.toString()};
    // 电影没有季集号；TV 的季集号不全时按单集查反而会拿错数据，索性不带。
    if (query.season > 0 && query.episode > 0) {
      parameters['season'] = query.season.toString();
      parameters['episode'] = query.episode.toString();
    }
    // 时长只影响这家自己的匹配精度，不是必需的查询条件。
    if (query.durationMs > 0) {
      parameters['duration_ms'] = query.durationMs.toString();
    }
    final uri = Uri.parse(_endpoint).replace(queryParameters: parameters);
    final http.Response response;
    try {
      response = await client.get(uri);
    } catch (_) {
      return null;
    }
    if (response.statusCode == 404) return const <RawSkipSegment>[];
    if (!skipIsSuccessStatus(response.statusCode)) return null;
    final root = skipDecodeJsonObject(response);
    if (root == null) return null;
    final segments = <RawSkipSegment>[];
    for (final entry in _fields.entries) {
      for (final body in skipJsonObjects(root[entry.key])) {
        final start = _timeOf(body, 'start');
        final end = _timeOf(body, 'end');
        if (start == null && end == null) continue;
        segments.add(
          RawSkipSegment(
            kind: entry.value,
            provider: id,
            startMs: start,
            endMs: end,
            // 该接口不下发参考时长：0 = 无从折算，尾部段按原始时间戳理解。
            referenceDurationMs: 0,
          ),
        );
      }
    }
    return segments;
  }

  /// 优先毫秒字段，缺了退回秒字段乘 1000；null 保持 null。
  static int? _timeOf(Map<String, Object?> body, String prefix) =>
      skipJsonMs(body['${prefix}_ms']) ??
      skipJsonSecondsToMs(body['${prefix}_sec']);
}
