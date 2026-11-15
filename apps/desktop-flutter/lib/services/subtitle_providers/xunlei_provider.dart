/// 迅雷字幕源（实现见 `docs/superpowers/plans/2026-11-15-subtitle-online-search.md` Task 3）。
///
/// 负责：按片名搜索、把 `data[]` 每条归一成 [SubtitleCandidate]（id / 名称 /
/// 格式 / 语言 / score 都走参考实现的逐字规则）、以及单跳 `resolve()` ——
/// 把候选 URL 交给 [SubtitleAssetStore] 落盘。
///
/// 不负责：多源聚合、排序与超时（`registry.dart` 做）、字幕文本校验（播放器侧）、
/// 以及计划 §0.1 D4 明确不做的「本地文件 sha1 加分」（只改同源内排序权重，
/// 不改可搜到的集合）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/subtitle_provider.dart';
import '../../core/subtitle_settings.dart';
import '../subtitle_asset_store.dart';
import 'provider.dart';

const String _endpoint = 'https://api-shoulei-ssl.xunlei.com/oracle/subtitle';

/// 接口只认浏览器来源：缺 Referer 会被直接拒。
const Map<String, String> _headers = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Referer': 'https://sl-m-ssl.xunlei.com/',
};

/// 能直接交给播放器的格式；其余一律按 `srt` 处理（参考实现同口径）。
const Set<String> _formats = {'ass', 'ssa', 'srt', 'vtt'};

/// 语言白名单子串（计划 §0「迅雷语言」逐字照抄）。
const List<String> _languageTokens = [
  '中文',
  '中字',
  '简',
  '繁',
  'chs',
  'cht',
  'zh',
  'english',
  'eng',
  'en',
  '日',
  'ja',
  'jp',
  '韩',
  '韓',
  'ko',
  'kr',
];

/// 未启用时返回 null：该源完全不参与搜索，也不产生任何请求。
SubtitleProvider? buildXunleiProvider({
  required SubtitleSettings settings,
  http.Client? client,
  String cacheDir = '',
}) {
  if (!settings.xunleiEnabled) return null;
  return XunleiSubtitleProvider(client: client, cacheDir: cacheDir);
}

class XunleiSubtitleProvider extends SubtitleProvider {
  XunleiSubtitleProvider({
    http.Client? client,
    this.cacheDir = '',
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// resolve() 的落盘目录；空则 [SubtitleAssetStore] 直接报 `no_cache_dir`。
  final String cacheDir;

  final Duration timeout;

  @override
  String get id => 'xunlei';

  @override
  String get name => '迅雷字幕';

  @override
  int get priority => 20;

  @override
  Future<List<SubtitleCandidate>> search(
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async {
    final keyword = query.title.trim();
    if (keyword.isEmpty) return const [];
    // 空格必须编成 %20（urllib quote 语义）：Dart 的 encodeQueryComponent 与
    // queryParameters 走 form 编码，会变成 '+'，这个接口不认。
    final uri = Uri.parse(
      _endpoint,
    ).replace(query: 'name=${Uri.encodeComponent(keyword)}');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const [];
      }
      return _parse(response.bodyBytes);
    } catch (_) {
      // 网络 / 超时 / 非法 JSON 一律按「没有结果」处理：本层不抛，
      // 失败原因由 registry 统一记录。
      return const [];
    }
  }

  @override
  Future<SubtitleResolvedAsset?> resolve(
    SubtitleCandidate candidate,
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async {
    final url = (candidate.payload['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw const SubtitleResolveException('download_url_missing');
    }
    final declared = (candidate.payload['format'] ?? '').toString().trim();
    final fallbackFormat = declared.isNotEmpty
        ? declared
        : (candidate.format.trim().isEmpty ? 'srt' : candidate.format.trim());
    final name = (candidate.payload['name'] ?? '').toString().trim();
    return SubtitleAssetStore(cacheDir: cacheDir, client: _client).download(
      url: url,
      headers: _headers,
      nameHint: name.isEmpty ? candidate.title : name,
      fallbackFormat: fallbackFormat,
    );
  }

  List<SubtitleCandidate> _parse(List<int> body) {
    final Object? decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
    if (decoded is! Map) return const [];
    // code 缺失按 1 处理：等价于「不是成功响应」。
    if (_intOf(decoded['code']) != 0) return const [];
    final result = (decoded['result'] ?? '').toString().trim();
    if (result.isNotEmpty && result.toLowerCase() != 'ok') return const [];
    final data = decoded['data'];
    if (data is! List) return const [];
    final candidates = <SubtitleCandidate>[];
    for (final raw in data) {
      final candidate = _candidateOf(raw);
      if (candidate != null) candidates.add(candidate);
    }
    return candidates;
  }

  SubtitleCandidate? _candidateOf(Object? raw) {
    if (raw is! Map) return null;
    final url = (raw['url'] ?? '').toString().trim();
    if (url.isEmpty) return null;
    final assetId = _firstNonEmpty([raw['cid'], raw['gcid']]) ?? url;
    final name = (raw['name'] ?? '').toString().trim();
    final title = name.isEmpty ? assetId : name;
    final format = _formatOf(
      ext: (raw['ext'] ?? '').toString(),
      name: name,
      url: url,
    );
    return SubtitleCandidate(
      providerId: id,
      assetId: assetId,
      title: title,
      language: _languageOf(raw['languages']),
      format: format,
      url: url,
      score: _scoreOf(raw),
      requiresResolve: true,
      payload: {'url': url, 'name': title, 'format': format},
    );
  }

  /// 格式：`ext` → 名称扩展名 → URL 扩展名，取第一个非空来源；
  /// 归一后不在白名单就回落到 `srt`（参考实现同口径）。
  static String _formatOf({
    required String ext,
    required String name,
    required String url,
  }) {
    var source = ext.trim();
    if (source.isEmpty) source = name;
    if (source.isEmpty) source = url;
    final extension = _extensionOf(source);
    return _formats.contains(extension) ? extension : 'srt';
  }

  /// 扩展名：先切掉 query/fragment 与目录，再取最后一个点之后，小写去点。
  static String _extensionOf(String value) {
    var text = value.trim().toLowerCase();
    final cut = text.indexOf(RegExp(r'[?#]'));
    if (cut >= 0) text = text.substring(0, cut);
    final slash = text.lastIndexOf('/');
    if (slash >= 0) text = text.substring(slash + 1);
    final dot = text.lastIndexOf('.');
    if (dot >= 0) text = text.substring(dot + 1);
    return text.replaceAll('.', '');
  }

  /// 语言归一：命中白名单子串就**原样返回**，否则 `zh`。
  ///
  /// `en` 是纯子串匹配，`Bengali` 会命中并原样返回——参考实现行为，照抄。
  static String _languageOf(Object? raw) {
    var value = '';
    if (raw is List) {
      for (final item in raw) {
        if (item is String && item.trim().isNotEmpty) {
          value = item.trim();
          break;
        }
      }
    }
    if (value.isEmpty) return 'zh';
    final lower = value.toLowerCase();
    if (lower == 'default' || value == '默认') return 'zh';
    for (final token in _languageTokens) {
      if (lower.contains(token)) return value;
    }
    return 'zh';
  }

  /// 参考实现按 `fingerprintf_score` 取指纹分（拼写如此），另兼容常见的
  /// `fingerprint_score`。
  static double _scoreOf(Map raw) {
    final plain = _doubleOf(raw['score']);
    final fingerprint = _doubleOf(
      raw['fingerprintf_score'] ?? raw['fingerprint_score'],
    );
    return plain >= fingerprint ? plain : fingerprint;
  }

  static String? _firstNonEmpty(List<Object?> values) {
    for (final value in values) {
      final text = (value ?? '').toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static int? _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static double _doubleOf(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? 0;
    return 0;
  }
}
