/// 搜索辅助服务：联想词、热门推荐、（历史在 `UiPreferencesStore` 持久化）。
///
/// 上游对应实现（安卓「默影视」）：
/// - `SearchSuggest.java`：爱奇艺 + 腾讯双源联想，合并去重取前 20；
/// - `SearchFragment.getHot()`：360kan 榜单（cat=2 电影 / 3 剧集 / 4 综艺），
///   结果落 `Setting.putHotTv/...` 做磁盘缓存，下次优先用缓存。
///
/// PC 端差异：
/// - 联想与热搜都是**锦上添花**的外网请求，失败必须安静降级（空列表），
///   绝不阻塞用户输入或搜索；
/// - 热搜缓存落 `<cacheDir>/search/hot-<category>.json`（磁盘 JSON，
///   与 EPG 缓存同域思路），不进 `settings.json`（那只是偏好，不是数据）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'log_service.dart';

/// 联想 / 热搜的条目。
///
/// 联想词只填 [title]；[cover] 等字段只在**热门榜单**（360kan `rank`）上有值，
/// 因为那个接口本身就返回海报与元信息（实测字段：`cover` 竖版海报、`upinfo` 集数、
/// `doubanscore` 评分、`url` 详情页）。
class SearchSuggestItem {
  const SearchSuggestItem({
    required this.title,
    this.cover,
    this.subtitle,
    this.score,
    this.detailUrl,
    this.rank,
  });

  final String title;

  /// 竖版海报地址（榜单返回的 `cover`）。多数为 20~170KB 的 JPEG，
  /// 偶有 1.6MB 的 770×1080 PNG——渲染时必须限解码尺寸（`cacheWidth`）。
  final String? cover;

  /// 副标题：榜单里是 `upinfo`（`全47集` / `2026-10-13期`）。
  final String? subtitle;

  /// 豆瓣评分文本（`5.3`）；多数条目为空。
  final String? score;

  /// 原始详情页地址（360kan）。PC 端不播放这个来源，
  /// 它只是「点击去各站点搜索」的语义出处。
  final String? detailUrl;

  /// 榜单名次（1 起）。仅榜单提供。
  final int? rank;
}

/// 360kan 榜单类目。
enum HotRankCategory {
  movie(2, '电影'),
  series(3, '剧集'),
  variety(4, '综艺');

  const HotRankCategory(this.remoteValue, this.label);

  /// 360kan `/v1/rank?cat=` 的取值。
  final int remoteValue;

  /// UI 展示名。
  final String label;
}

class SearchSuggestService {
  SearchSuggestService({
    http.Client? client,
    LogService? log,
    this.cacheDir,
    this.timeout = const Duration(seconds: 8),
    this.hotCacheTtl = const Duration(hours: 12),
    this.hotPoolLimit = 30,
  }) : _client = client ?? http.Client(),
       // 可选参数与可空字段同名但语义不同（参数是“注入或默认”，字段是“可空引用”），
       // 这里不用 initializing formal 是故意的。
       // ignore: prefer_initializing_formals
       _log = log;

  final http.Client _client;
  final LogService? _log;

  /// 热搜磁盘缓存目录（`<cacheDir>/search/`）；null = 不落盘。
  final String? cacheDir;

  final Duration timeout;

  /// 热搜缓存有效期；上游 360kan 榜单一天最多变一两次，12h 足够。
  final Duration hotCacheTtl;

  /// 榜单**候选池**上限（解析几条备用）。
  ///
  /// 上游 `HOT_LIMIT` 是 10（直接显示 10 条），但 PC 端要支持「按窗口宽高
  /// 恰好铺满」与「换一批」（用户 2026-10-14），屏幕一次能放几条由布局决定、
  /// 且需要比一屏更多的候选才能轮换出**新**条目。360kan 单类目实测返回 30 条，
  /// 这里就取全量 30；显示几条由 `HotRankLayout` 算。
  final int hotPoolLimit;

  /// 联想合并上限（上游 `SearchSuggest.LIMIT = 20`）。
  static const int suggestLimit = 20;

  int _suggestSeq = 0;

  bool _closed = false;

  // ---------------------------------------------------------------------------
  // 联想
  // ---------------------------------------------------------------------------

  /// 取联想词：爱奇艺 + 腾讯并发，合并去重、保序，取前 20。
  ///
  /// [keyword] 为空时直接返回空表（上游 `getWord` 的分支语义）。
  /// 请求失败（断网 / 超时 / 解析失败）一律安静降级为空表并记日志。
  Future<List<SearchSuggestItem>> suggest(String keyword) async {
    final text = keyword.trim();
    if (text.isEmpty || _closed) return const [];
    // 递增序号：输入框每次变化都会触发请求，只保留最新一次的结果语义
    // （与上游 `mSuggestSeq` 一致；这里是方法级返回，迟到的旧结果自然被丢弃）。
    final seq = ++_suggestSeq;
    final results = await Future.wait([
      _fetchIqiyiSuggest(text),
      _fetchTencentSuggest(text),
    ]);
    if (_closed || seq != _suggestSeq) return const [];
    final merged = <String>{};
    for (final list in results) {
      for (final title in list) {
        final clean = _cleanTitle(title);
        if (clean.isNotEmpty) merged.add(clean);
      }
    }
    return [
      for (final title in merged.take(suggestLimit))
        SearchSuggestItem(title: title),
    ];
  }

  Future<List<String>> _fetchIqiyiSuggest(String keyword) async {
    final uri = Uri.https('suggest.video.iqiyi.com', '/', {
      'if': 'mobile',
      'key': keyword,
    });
    final body = await _getJson(uri);
    if (body == null) return const [];
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      final data = decoded['data'];
      if (data is! List) return const [];
      return [
        for (final item in data)
          if (item is Map)
            if (item['name'] is String) item['name'] as String,
      ];
    } catch (error) {
      _log?.debug('爱奇艺联想解析失败：$error', scope: 'search');
      return const [];
    }
  }

  Future<List<String>> _fetchTencentSuggest(String keyword) async {
    final uri = Uri.https(
      'tv.aiseet.atianqi.com',
      '/i-tvbin/qtv_video/search/get_search_smart_box',
      {
        'format': 'json',
        'page_num': '0',
        'page_size': '10',
        'key': keyword,
      },
    );
    final body = await _getJson(uri);
    if (body == null) return const [];
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      final data = decoded['data'];
      if (data is! Map) return const [];
      final search = data['search_data'];
      if (search is! Map) return const [];
      final groups = search['vecGroupData'];
      if (groups is! List) return const [];
      final titles = <String>[];
      for (final groupElement in groups) {
        final groupData =
            groupElement is Map ? groupElement['group_data'] : null;
        if (groupData is! List) continue;
        for (final itemElement in groupData) {
          final title = _tencentTitle(itemElement);
          if (title != null) titles.add(title);
        }
      }
      return titles;
    } catch (error) {
      _log?.debug('腾讯联想解析失败：$error', scope: 'search');
      return const [];
    }
  }

  /// 腾讯响应的标题：优先 `action.actionArgs.search_keyword.strVal`，
  /// 回落 `cell_info.title`（上游 `SearchSuggest.getTencentTitle`）。
  String? _tencentTitle(Object? item) {
    if (item is! Map) return null;
    dynamic read(String path) {
      dynamic current = item;
      for (final segment in path.split('.')) {
        if (current is! Map) return null;
        current = current[segment];
      }
      return current;
    }

    final keyword = read('action.actionArgs.search_keyword.strVal');
    if (keyword is String && keyword.trim().isNotEmpty) return keyword;
    final cellTitle = read('cell_info.title');
    if (cellTitle is String && cellTitle.trim().isNotEmpty) return cellTitle;
    return null;
  }

  // ---------------------------------------------------------------------------
  // 热门推荐
  // ---------------------------------------------------------------------------

  /// 取热门榜单：磁盘缓存（未过期）优先，miss 时请求 360kan 并写缓存。
  ///
  /// 失败链路：请求失败 → 尝试**过期缓存**兜底（上游 Setting 缓存正是这个语义，
  /// 断网时上次榜单仍可用）→ 仍无则空表。
  Future<List<SearchSuggestItem>> hotRank(HotRankCategory category) async {
    if (_closed) return const [];
    final cacheFile = _hotCacheFile(category);
    final cached = await _readHotCache(cacheFile, allowExpired: false);
    if (cached != null) return cached;
    final uri = Uri.https('api.web.360kan.com', '/v1/rank', {
      'cat': '${category.remoteValue}',
    });
    final body = await _getJson(uri, headers: {
      'Referer': 'https://www.360kan.com/rank/general',
    });
    if (body != null) {
      final items = _parseHotRank(body);
      if (items.isNotEmpty) {
        await _writeHotCache(cacheFile, body);
        return items;
      }
    }
    // 断网兜底：过期缓存总比空榜好（上游一样：缓存只在拿到新结果时覆盖）。
    return await _readHotCache(cacheFile, allowExpired: true) ?? const [];
  }

  List<SearchSuggestItem> _parseHotRank(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      final data = decoded['data'];
      if (data is! List) return const [];
      final items = <SearchSuggestItem>[];
      for (final item in data) {
        if (item is! Map) continue;
        final title = _stringOf(item['title']);
        if (title == null) continue;
        items.add(
          SearchSuggestItem(
            title: title,
            cover: _stringOf(item['cover']),
            subtitle: _stringOf(item['upinfo']),
            score: _stringOf(item['doubanscore']),
            detailUrl: _stringOf(item['url']),
            rank: items.length + 1,
          ),
        );
        if (items.length >= hotPoolLimit) break;
      }
      return items;
    } catch (error) {
      _log?.debug('热门榜单解析失败：$error', scope: 'search');
      return const [];
    }
  }

  /// 取一个非空字符串；非字符串或空白一律视为缺失。
  ///
  /// 为什么不能直接 `as String?`：榜单里这些字段的类型并不稳定
  /// （`doubanscore` 常为空串、`moviecat` 是数组、`id`/`pv` 是数字），
  /// 逐个强转会因一个脏字段废掉整条榜单。
  static String? _stringOf(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  // ---------------------------------------------------------------------------
  // 磁盘缓存
  // ---------------------------------------------------------------------------

  String? _hotCacheFile(HotRankCategory category) => cacheDir == null
      ? null
      : '$cacheDir${Platform.pathSeparator}hot-${category.name}.json';

  Future<List<SearchSuggestItem>?> _readHotCache(
    String? file, {
    required bool allowExpired,
  }) async {
    if (file == null) return null;
    try {
      final entity = File(file);
      if (!await entity.exists()) return null;
      final decoded = jsonDecode(await entity.readAsString());
      if (decoded is! Map) return null;
      final fetchedAt = decoded['fetchedAt'];
      final body = decoded['body'];
      if (fetchedAt is! String || body is! String) return null;
      final fetchedTime = DateTime.tryParse(fetchedAt);
      if (fetchedTime == null) return null;
      final age = DateTime.now().difference(fetchedTime);
      if (!allowExpired && (age.isNegative || age > hotCacheTtl)) return null;
      final items = _parseHotRank(body);
      return items.isEmpty ? null : items;
    } catch (_) {
      // 缓存损坏按 miss 处理。
      return null;
    }
  }

  Future<void> _writeHotCache(String? file, String body) async {
    if (file == null) return;
    try {
      final entity = File(file);
      await entity.parent.create(recursive: true);
      await entity.writeAsString(
        jsonEncode({
          'fetchedAt': DateTime.now().toIso8601String(),
          'body': body,
        }),
        flush: true,
      );
    } catch (error) {
      // 缓存写失败不影响结果。
      _log?.debug('热门榜单缓存写入失败：$error', scope: 'search');
    }
  }

  // ---------------------------------------------------------------------------
  // 基础设施
  // ---------------------------------------------------------------------------

  Future<String?> _getJson(Uri uri, {Map<String, String>? headers}) async {
    try {
      final response = await _client
          .get(uri, headers: headers)
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log?.debug(
          '联想/热搜上游 HTTP ${response.statusCode} ${uri.host}',
          scope: 'search',
        );
        return null;
      }
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (error) {
      _log?.debug('联想/热搜请求失败 ${uri.host}：$error', scope: 'search');
      return null;
    }
  }

  /// 去掉联想标题里的 `<hl>` 高亮标签与多余空白（上游 `SearchSuggest.clean`）。
  String _cleanTitle(String title) =>
      title
          .replaceAll(RegExp('</?hl>', caseSensitive: false), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

  void close() {
    _closed = true;
    _client.close();
  }
}
