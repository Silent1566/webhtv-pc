/// ASSRT 字幕源（实现见 `docs/superpowers/plans/2026-11-15-subtitle-online-search.md`）。
///
/// 这层负责：`/v1/sub/search` 的候选映射（格式 / 语言 / 季集），以及
/// `resolve()` 的第一跳 `/v1/sub/detail` 取真实下载地址。
///
/// **不负责**：下载落盘、ZIP 解包、体积与路径穿越守卫——拿到地址就交给
/// `services/subtitle_asset_store.dart`；语言也**不做归一**，`lang.desc`
/// 原样透传给打分层（计划 §0）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/subtitle_provider.dart';
import '../../core/subtitle_settings.dart';
import '../../core/tmdb_title.dart';
import '../subtitle_asset_store.dart';
import 'provider.dart';

const String _apiHost = 'api.assrt.net';

const Duration _timeout = Duration(seconds: 15);

/// ASSRT 缺 Referer 直接拒绝，UA 必须像浏览器（计划 §0 对照表）。
const Map<String, String> _headers = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Referer': 'https://assrt.net/',
};

/// 依次探测的格式：**不含 srt**，三个都不中才回退 `srt`（计划 §0）。
const List<String> _formatProbes = ['ass', 'ssa', 'vtt'];

/// 未启用时返回 null：该源完全不参与搜索，也不产生任何请求。
SubtitleProvider? buildAssrtProvider({
  required SubtitleSettings settings,
  http.Client? client,
  String cacheDir = '',
}) {
  if (!settings.hasAssrt) return null;
  return _AssrtProvider(client: client, cacheDir: cacheDir);
}

class _AssrtProvider implements SubtitleProvider {
  _AssrtProvider({http.Client? client, this.cacheDir = ''})
    : _client = client ?? http.Client();

  final http.Client _client;
  final String cacheDir;

  @override
  String get id => 'assrt';

  @override
  String get name => 'ASSRT';

  @override
  int get priority => 30;

  @override
  bool get needsLocalMediaPath => false;

  @override
  Future<List<SubtitleCandidate>> search(
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async {
    final token = settings.assrtToken.trim();
    final keyword = query.title.trim();
    // builder 在无 token 时已经返回 null；这里再守一道，保证零请求。
    if (token.isEmpty || keyword.isEmpty) return const [];
    final http.Response response;
    try {
      response = await _client
          .get(
            _uri('/v1/sub/search', {
              'token': token,
              'q': keyword,
              'is_file': '1',
              'cnt': '15',
            }),
            headers: _headers,
          )
          .timeout(_timeout);
    } catch (_) {
      // 网络/超时不在 search 里外抛：失败原因由 registry 统一记录。
      return const [];
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const [];
    }
    final body = _decodeMap(response);
    if (_asInt(body?['status']) != 0) return const [];
    final sub = body?['sub'];
    final subs = sub is Map ? sub['subs'] : null;
    if (subs is! List) return const [];
    final candidates = <SubtitleCandidate>[];
    for (final item in subs) {
      if (item is! Map) continue;
      final candidate = _toCandidate(item);
      if (candidate != null) candidates.add(candidate);
    }
    return candidates;
  }

  @override
  Future<SubtitleResolvedAsset?> resolve(
    SubtitleCandidate candidate,
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async {
    if (cacheDir.trim().isEmpty) {
      throw const SubtitleResolveException('no_cache_dir');
    }
    final payloadId = _text(candidate.payload['id']);
    final assetId = payloadId.isNotEmpty ? payloadId : candidate.assetId;
    final uri = _uri('/v1/sub/detail', {
      'token': settings.assrtToken.trim(),
      'id': assetId,
    });

    final http.Response response;
    try {
      response = await _client.get(uri, headers: _headers).timeout(_timeout);
    } on TimeoutException {
      throw const SubtitleResolveException('timeout');
    } catch (_) {
      // 原始异常文本会带上含 token 的 URL，绝不外泄。
      throw const SubtitleResolveException('network');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const SubtitleResolveException('detail_api_failed');
    }
    final body = _decodeMap(response);
    if (_asInt(body?['status']) != 0) {
      throw const SubtitleResolveException('detail_api_failed');
    }
    final url = _downloadUrlOf(body);
    if (url.isEmpty) {
      throw const SubtitleResolveException('download_url_missing');
    }
    // 下载与 ZIP 解包的下标、体积、路径守卫全部在 store 里，format 以最终
    // 扩展名为准（计划 §0.1 D1）。
    return SubtitleAssetStore(cacheDir: cacheDir, client: _client).download(
      url: url,
      headers: _headers,
      nameHint: candidate.title,
      fallbackFormat: candidate.format,
    );
  }

  SubtitleCandidate? _toCandidate(Map<Object?, Object?> item) {
    final assetId = _firstText(item, const ['id', 'fileid']);
    if (assetId.isEmpty) return null;
    final title = _firstText(item, const [
      'name',
      'sub_name',
      'm_version',
      'm_title',
    ]);
    final videoName = _firstText(item, const [
      'videoname',
      'm_videoname',
      'video_chinese_name',
      'm_video_chinese_name',
    ]);
    final subtype = _firstText(item, const ['subtype', 'm_subtype']);
    final lang = item['lang'];
    final fromDesc = lang is Map ? _text(lang['desc']) : '';
    final language = fromDesc.isNotEmpty ? fromDesc : _text(item['m_lang']);
    final format = _detectFormat(subtype, title);
    final haystack = '$title $videoName';
    final season = sourceSeasonNumber(haystack);
    final episode = sourceEpisodeNumber(haystack);
    // 不解析年份：SubtitleCandidate 没有 year 字段，payload 又被契约钉成
    // {id, format}，算了也没有落点。
    return SubtitleCandidate(
      providerId: id,
      assetId: assetId,
      title: title,
      language: language,
      format: format,
      url: '',
      season: season > 0 ? season : null,
      episode: episode > 0 ? episode : null,
      requiresResolve: true,
      payload: {'id': assetId, 'format': format},
    );
  }

  /// `(subtype + ' ' + title)` 里出现 `.<fmt>` 或 ` <fmt>` 即命中。
  ///
  /// 注意 subtype 落在首位时**不**命中（上游用 `" "+fmt` 比较），照抄参考实现。
  static String _detectFormat(String subtype, String title) {
    final value = '$subtype $title'.toLowerCase();
    for (final format in _formatProbes) {
      if (value.contains('.$format') || value.contains(' $format')) {
        return format;
      }
    }
    return 'srt';
  }

  static String _downloadUrlOf(Map<Object?, Object?>? body) {
    final sub = body?['sub'];
    final subs = sub is Map ? sub['subs'] : null;
    if (subs is! List || subs.isEmpty) return '';
    final first = subs.first;
    return first is Map ? _text(first['url']) : '';
  }

  static Uri _uri(String path, Map<String, String> queryParameters) =>
      Uri.https(_apiHost, path, queryParameters);

  static Map<Object?, Object?>? _decodeMap(http.Response response) {
    try {
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      return decoded is Map ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String _text(Object? value) {
    if (value is String) return value.trim();
    if (value is num) return value.toString();
    return '';
  }

  static String _firstText(Map<Object?, Object?> item, List<String> keys) {
    for (final key in keys) {
      final text = _text(item[key]);
      if (text.isNotEmpty) return text;
    }
    return '';
  }
}
