/// Wikidata 人物简介（CC0 / CC BY-SA 之外的官方 API）。
///
/// 为什么接它：豆瓣 celebrity 载荷没有简介、Bangumi 的真人库很窄，
/// 「演员没有简介」是当前最大的空洞；Wikidata 的中文描述与维基百科摘要
/// 正好补这一块，且是官方接口、无需凭据。
///
/// 只读两个端点，都走 MediaWiki 官方 API：
/// - `wbsearchentities`：按姓名找 Q 号（语言优先 zh，回退 en）；
/// - `wbgetentities`：取 `descriptions`（一句话）与 `sitelinks.zhwiki/enwiki`，
///   再用 `rest_v1/page/summary` 取正文摘要。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/meta_source.dart';

class WikidataException implements Exception {
  const WikidataException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'WikidataException($message)';
}

const String wikidataUserAgent =
    'webhtv-pc/0.1 (https://github.com/Silent1566/webhtv-pc)';

class WikidataService {
  WikidataService({
    http.Client? client,
    this.baseUri = const String.fromEnvironment('WIKIDATA_BASE', defaultValue: 'https://zh.wikipedia.org'),
    this.delay = _defaultDelay,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  static Future<void> _defaultDelay(Duration d) => Future<void>.delayed(d);

  final http.Client _client;
  final bool _ownsClient;
  final String baseUri;
  final Future<void> Function(Duration) delay;
  DateTime? _last;
  bool _closed = false;
  final Map<String, Map<String, Object?>> _cache = {};

  /// 按人名找 Wikidata 人物实体；找不到返回 `null`。
  Future<MetaPersonRef?> searchPerson(String name, {int year = 0}) async {
    final query = name.trim();
    if (_closed || query.isEmpty) return null;
    try {
      final hits = await _json(
        '/w/api.php',
        {
          'action': 'wbsearchentities',
          'search': query,
          'language': 'zh',
          'uselang': 'zh',
          'type': 'item',
          'limit': '5',
          'format': 'json',
        },
      );
      final list = hits?['search'];
      if (list is! List) return null;
      for (final item in list) {
        final map = item is Map ? item.cast<String, Object?>() : const <String, Object?>{};
        final id = '${map['id'] ?? ''}';
        final number = int.tryParse(id.replaceFirst(RegExp('^Q'), ''));
        if (number == null || number <= 0) continue;
        // 只用「人」实体：描述里带 human/人物/演员/歌手 之类才算。
        final description = '${map['description'] ?? map['match'] ?? ''}'.toLowerCase();
        if (!_looksLikeHuman(description)) continue;
        return MetaPersonRef.of(
          MetaSourceKind.wikidata,
          number,
          name: '${map['label'] ?? query}',
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 取该实体的简介文本：先中文维基摘要，再英文，再 Wikidata 描述。
  Future<String> biography(int qNumber) async {
    if (_closed || qNumber <= 0) return '';
    final id = 'Q$qNumber';
    final cached = _cache[id];
    if (cached != null) return '${cached['bio'] ?? ''}';
    try {
      final entity = await _json(
        '/w/api.php',
        {
          'action': 'wbgetentities',
          'ids': id,
          'props': 'descriptions|sitelinks',
          'languages': 'zh|en',
          'sitefilter': 'zhwiki|enwiki',
          'format': 'json',
        },
      );
      final entities = entity?['entities'];
      final first = entities is Map ? entities.values.firstOrNull : null;
      final map = first is Map ? first.cast<String, Object?>() : const <String, Object?>{};
      final description = _localized(map['descriptions'], 'zh') .isNotEmpty
          ? _localized(map['descriptions'], 'zh')
          : _localized(map['descriptions'], 'en');
      final title = _siteTitle(map['sitelinks'], 'zhwiki') .isNotEmpty
          ? _siteTitle(map['sitelinks'], 'zhwiki')
          : _siteTitle(map['sitelinks'], 'enwiki');
      var summary = '';
      if (title.isNotEmpty) summary = await _summary(title);
      final bio = summary.isNotEmpty ? summary : description;
      _cache[id] = {'bio': bio};
      return bio;
    } catch (_) {
      return '';
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    if (_ownsClient) _client.close();
  }

  // -------------------------------------------------------------------------

  bool _looksLikeHuman(String description) {
    if (description.isEmpty) return true;
    const hints = ['human', 'person', 'actor', 'actress', 'singer', 'director',
      'writer', 'producer', '人物', '演员', '歌手', '导演', '编剧', '男演员', '女演员'];
    return hints.any(description.contains);
  }

  String _localized(Object? descriptions, String lang) {
    if (descriptions is! Map) return '';
    final entry = descriptions[lang];
    if (entry is! Map) return '';
    return '${entry['value'] ?? ''}'.trim();
  }

  String _siteTitle(Object? sitelinks, String site) {
    if (sitelinks is! Map) return '';
    final entry = sitelinks[site];
    if (entry is! Map) return '';
    return '${entry['title'] ?? ''}'.trim();
  }

  Future<String> _summary(String title) async {
    final body = await _json(
      '/api/rest_v1/page/summary/${Uri.encodeComponent(title.replaceAll(' ', '_'))}',
      const {},
    );
    return '${body?['extract'] ?? ''}'.trim();
  }

  Future<Map<String, Object?>?> _json(String path, Map<String, String> query) async {
    await _space();
    final uri = Uri.parse(baseUri + path).replace(queryParameters: query.isEmpty ? null : query);
    final response = await _client.get(uri, headers: {
      'User-Agent': wikidataUserAgent,
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw WikidataException('HTTP ${response.statusCode}', statusCode: response.statusCode);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  }

  Future<void> _space() async {
    final last = _last;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      const gap = Duration(milliseconds: 200);
      if (elapsed < gap) await delay(gap - elapsed);
    }
    _last = DateTime.now();
  }
}