/// TODB PlayBack（`playback.theotherdb.org/api/metadata`）：只认 TMDB 键。
///
/// 实测响应（2026-11）：一次返回多个播放版本（`items`），每个版本自带
/// `marker` 数组；同一集在不同平台上标定不同，**每个版本都产出**，去重交给
/// `SkipPlan.resolve`（它按起点/区间合并同类段）。
///
/// 单位陷阱：`time_start`/`time_end`/`version_runtime` 都是**秒**。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/skip_plan.dart';
import 'provider.dart';

/// TODB PlayBack 数据源。
class TodbProvider extends IntroSkipProvider {
  const TodbProvider();

  static const String _endpoint =
      'https://playback.theotherdb.org/api/metadata';

  /// 一次要几个版本：实测 3 个够覆盖常见平台，再多只是重复段。
  static const int _pageSize = 3;

  @override
  String get id => 'todb';

  @override
  String get name => 'TODB';

  @override
  int get sourceBit => SkipSourceBits.todb;

  /// 没有 TMDB 键时这家查不了，按「这集没数据」返回（理由同 `IntroDbProvider`）。
  @override
  Future<List<RawSkipSegment>?> fetch(
    SkipQuery query, {
    required http.Client client,
  }) async {
    if (!query.hasTmdb) return const <RawSkipSegment>[];
    final payload = <String, Object?>{
      'platform_type': query.isTv ? 'tmdb_id_tv' : 'tmdb_id_movie',
      'platform_value': query.tmdbId.toString(),
      'includes': const <String>['marker'],
      'page': 1,
      'page_size': _pageSize,
    };
    // 电影没有季集号；TV 缺季集号时不猜（猜错等于把别的集标定缓存成这集的）。
    if (query.season > 0 && query.episode > 0) {
      payload['season_number'] = query.season;
      payload['episode_number'] = query.episode;
    }
    final body = jsonEncode(payload);
    final http.Response response;
    try {
      response = await client.post(
        Uri.parse(_endpoint),
        headers: const <String, String>{'content-type': 'application/json'},
        body: body,
      );
    } catch (_) {
      return null;
    }
    if (response.statusCode == 404) return const <RawSkipSegment>[];
    if (!skipIsSuccessStatus(response.statusCode)) return null;
    final root = skipDecodeJsonObject(response);
    if (root == null) return null;
    final segments = <RawSkipSegment>[];
    for (final item in skipJsonObjects(root['items'])) {
      final versionId = _idOf(item['version_id']);
      final reference = skipJsonSecondsToMs(item['version_runtime']) ?? 0;
      for (final marker in skipJsonObjects(item['marker'])) {
        // `chapter` 是剧情章节标记，不是可跳过段：认进来会让播放器把正片当
        // 片尾跳掉，所以只认 `SkipKind.fromWire` 认识的那几个。
        final kind = SkipKind.fromWire(marker['marker_type']);
        if (kind == null) continue;
        final start = skipJsonSecondsToMs(marker['time_start']);
        final end = skipJsonSecondsToMs(marker['time_end']);
        if (start == null && end == null) continue;
        segments.add(
          RawSkipSegment(
            kind: kind,
            provider: id,
            identity: 'todb|$versionId|${_idOf(marker['marker_id'])}',
            startMs: start,
            endMs: end,
            referenceDurationMs: reference,
            confidence: skipJsonConfidence(marker['confidence']),
            submissionCount: skipJsonSubmissionCount(
              marker['submission_count'],
            ),
          ),
        );
      }
    }
    return segments;
  }

  /// id 字段可能是数字也可能是字符串，统一成稳定的文本形式。
  static String _idOf(Object? raw) {
    if (raw is num) return raw.round().toString();
    if (raw is String) return raw.trim();
    return '';
  }
}
