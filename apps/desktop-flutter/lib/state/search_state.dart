/// 多站点并发搜索、结果分页与搜索范围的状态模型（§14.1、§14.3）。
///
/// 单独成文件的理由：搜索批次是 UI 与状态层共享的只读快照，把它和
/// [AppState] 的其它职责混在一起会让「结果是否已被取代」「取消后是否还投递」
/// 「这一页是不是重复内容」这类约束难以被测试直接观察。
library;

import 'dart:math' as math;

import '../core/app_error.dart';
import '../core/protocol.dart';

/// 单个站点的搜索结果条目。
///
/// 失败站点保留 [error] 而不是从列表中消失，UI 才能按 §14.3 显示「失败站点状态」
/// 而不阻塞其他站点。
class SiteSearchEntry {
  const SiteSearchEntry({
    required this.siteKey,
    required this.siteName,
    this.groups = const [],
    this.result,
    this.error,
    this.latency = Duration.zero,
    this.fromCache = false,
    this.page = 1,
    this.pageCount = 0,
    this.hasMore = false,
    this.loadingMore = false,
  });

  final String siteKey;
  final String siteName;

  /// 站点分组（从站点名抽取，`siteGroupsOf`；无标记时为空表）。
  ///
  /// 为什么存在：结果页的「按分组筛选」需要每个站点携带自己的分组，
  /// 否则筛选 chip 列表无法从结果里动态生成（对齐上游 CollectFragment
  /// 的 `Site.getGroups(mSites)`）。
  final List<String> groups;

  final SiteResult? result;
  final AppError? error;
  final Duration latency;
  final bool fromCache;

  /// 该站点已加载到第几页（初始搜索 = 1；加载更多会递增）。
  final int page;

  /// 上游声明的总页数；0 = 未知（说明可以一直往后翻，直到出现重复内容）。
  final int pageCount;

  /// 是否还能看图翻下一页（由 [SearchPagingState.canLoadMore] 计算后写入）。
  final bool hasMore;

  /// 该站点是否正在加载下一页（防重入 + UI 显示加载态）。
  final bool loadingMore;

  /// 该站点是否搜索成功。
  bool get succeeded => error == null;

  /// 该站点当前**已加载**的条目数（含所有已翻页）。
  int get itemCount => result?.list.length ?? 0;

  SiteSearchEntry copyWith({
    SiteResult? result,
    bool clearResult = false,
    int? page,
    int? pageCount,
    bool? hasMore,
    bool? loadingMore,
  }) => SiteSearchEntry(
    siteKey: siteKey,
    siteName: siteName,
    groups: groups,
    result: clearResult ? null : (result ?? this.result),
    error: error,
    latency: latency,
    fromCache: fromCache,
    page: page ?? this.page,
    pageCount: pageCount ?? this.pageCount,
    hasMore: hasMore ?? this.hasMore,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

/// 一次并发搜索批次。
///
/// [runId] 单调递增：调用方据此判断自己持有的结果是否已被更新的查询取代。
/// [cancelled] 只表示用户取消；被新查询取代时旧批次不会把结果写回状态。
class MultiSiteSearchOutcome {
  MultiSiteSearchOutcome({
    required this.runId,
    required this.keyword,
    required List<SiteSearchEntry> results,
    this.siteKey = '',
    this.group = '',
    this.skippedUnsupported = 0,
    this.skippedNotSearchable = 0,
  }) : _results = List.of(results);

  final int runId;
  final String keyword;

  /// 搜索范围：限定站点 key（空 = 不限定）。
  ///
  /// 对齐上游 `SearchFragment` 的 scope 菜单：全部 / 当前站点 / 某分组。
  final String siteKey;

  /// 搜索范围：限定分组（空 = 不限定）。
  final String group;

  /// 因运行时不可用而跳过的站点数（§8.1，只统计**范围内**的站点）。
  final int skippedUnsupported;

  /// 因未声明 `searchable` 而跳过的站点数（只统计范围内的站点）。
  final int skippedNotSearchable;

  List<SiteSearchEntry> _results;

  /// 全部站点是否都已结束（成功或失败）。
  bool finished = false;

  /// 用户是否已取消本批次。
  bool cancelled = false;

  /// 从发起到全部结束的总耗时。
  Duration totalElapsed = Duration.zero;

  List<SiteSearchEntry> get results => List.unmodifiable(_results);

  /// 本批次是否是「限定范围」的搜索。
  bool get scoped => siteKey.isNotEmpty || group.isNotEmpty;

  int get succeededCount => _results.where((entry) => entry.succeeded).length;

  int get failedCount => _results.where((entry) => !entry.succeeded).length;

  int get totalItems =>
      _results.fold(0, (sum, entry) => sum + entry.itemCount);

  /// 是否存在「成功但零结果」的站点，用于给出准确提示（§14.3）。
  bool get hasEmptyResult =>
      _results.any((entry) => entry.succeeded && entry.itemCount == 0);

  /// 按站点 key 取条目；不存在时为 null。
  SiteSearchEntry? entryOf(String siteKey) {
    for (final entry in _results) {
      if (entry.siteKey == siteKey) return entry;
    }
    return null;
  }

  /// 用最新快照替换结果集合（每个站点完成都会调用一次）。
  void update(List<SiteSearchEntry> next) {
    _results = List.of(next);
  }

  /// 就地替换单个站点的条目（加载更多追加一页后调用）。
  ///
  /// 只替换同 key 的条目，保持原有顺序——结果顺序必须按配置中的站点顺序稳定，
  /// 不能因为「谁先翻页完成」而重排。
  void replaceEntry(SiteSearchEntry entry) {
    final index = _results.indexWhere((item) => item.siteKey == entry.siteKey);
    if (index < 0) return;
    _results[index] = entry;
  }
}

/// 分页状态（移植上游安卓「默影视」`SearchPageState.java`）。
///
/// 职责：记住每个站点已加载到第几页、上游声明的总页数、**已见过的页内容指纹**。
/// 指纹是这套逻辑的关键：上游站点经常出现「第 2 页返回的还是第 1 页内容」
/// 或「越界页码返回末页」的情况，只看 `page < pageCount` 会无限翻下去，
/// 只有内容重复才判定该站点已耗尽。
class SearchPagingState {
  final Map<String, int> _pages = {};
  final Map<String, int> _pageCounts = {};
  final Map<String, Set<String>> _pageTokens = {};
  final Set<String> _exhausted = {};

  _PagingRequest? _pending;

  /// 清空全部状态（新搜索批次开始时调用）。
  void clear() {
    _pages.clear();
    _pageCounts.clear();
    _pageTokens.clear();
    _exhausted.clear();
    _pending = null;
  }

  /// 取消在途请求的登记（请求失败 / 批次被取代时调用）。
  void cancelPending() => _pending = null;

  bool get hasPending => _pending != null;

  bool isPending(String siteKey) => _pending?.siteKey == siteKey;

  /// 记录初始搜索（第 1 页）的页数与内容指纹。
  void recordInitial(String siteKey, int pageCount, [String pageToken = '']) {
    if (!_isSite(siteKey)) return;
    _pages.putIfAbsent(siteKey, () => 1);
    _recordPageCount(siteKey, pageCount);
    _recordPageToken(siteKey, pageToken);
  }

  int pageOf(String siteKey) => math.max(1, _pages[siteKey] ?? 1);

  int pageCountOf(String siteKey) => math.max(0, _pageCounts[siteKey] ?? 0);

  /// 是否还能继续翻页。
  ///
  /// `pageCount == 0`（上游未声明总页数）时视为可以继续，靠内容重复检测兜底。
  bool canLoadMore(String siteKey) {
    if (!_isSite(siteKey) || _exhausted.contains(siteKey)) return false;
    final pageCount = pageCountOf(siteKey);
    return pageCount == 0 || pageOf(siteKey) < pageCount;
  }

  bool isExhausted(String siteKey) => _exhausted.contains(siteKey);

  /// 登记一次「请求第 [requestedPage] 页」。
  ///
  /// 拒绝的情形（与上游一致）：站点不合法、已有在途请求、不可续翻、
  /// 请求页码不是「当前页 + 1」。
  bool begin(String siteKey, int requestedPage) {
    if (!_isSite(siteKey) || hasPending || !canLoadMore(siteKey)) return false;
    if (requestedPage != pageOf(siteKey) + 1) return false;
    _pending = _PagingRequest(siteKey, requestedPage);
    return true;
  }

  /// 登记一次「第 [_requestedPage] 页请求已完成」。
  ///
  /// 语义：
  /// - 本次请求无内容 → 不接受，但**不**标耗尽（上游可能只是这一页为空）；
  /// - 内容指纹与已见过的重复 → 标该站点耗尽；
  /// - 已被接受 → 页码推进到本次请求的页。
  PagingCompletion complete({
    required bool hasItems,
    required int pageCount,
    String pageToken = '',
  }) {
    final request = _pending;
    if (request == null) return PagingCompletion.none;
    _pending = null;
    if (pageCount > 0) _recordPageCount(request.siteKey, pageCount);
    final repeated = hasItems && !_recordPageToken(request.siteKey, pageToken);
    if (repeated) _exhausted.add(request.siteKey);
    final accepted = hasItems && !repeated;
    if (accepted) _pages[request.siteKey] = request.page;
    return PagingCompletion(
      handled: true,
      accepted: accepted,
      siteKey: request.siteKey,
      page: request.page,
      repeated: repeated,
    );
  }

  /// 是否应当在「原始页有条目、但按相似度过滤后一条都看不见」时自动续翻下一页。
  ///
  /// 上游 `shouldContinue` 同语义。没有它时，开启相似度过滤的站点会显示成
  /// 空列表，而实际上后面几页有命中项。
  bool shouldContinue(
    String siteKey, {
    required bool precise,
    required bool rawPageHasItems,
    required bool visiblePageHasItems,
  }) =>
      precise &&
      rawPageHasItems &&
      !visiblePageHasItems &&
      !hasPending &&
      canLoadMore(siteKey);

  void _recordPageCount(String siteKey, int pageCount) {
    if (pageCount <= 0) return;
    final current = _pageCounts[siteKey] ?? 0;
    if (pageCount > current) _pageCounts[siteKey] = pageCount;
  }

  /// 记录内容指纹；返回 false 表示「这一页和之前某页内容完全相同」。
  bool _recordPageToken(String siteKey, String pageToken) {
    if (pageToken.isEmpty) return true;
    return _pageTokens
        .putIfAbsent(siteKey, () => <String>{})
        .add(pageToken);
  }

  static bool _isSite(String siteKey) =>
      siteKey.isNotEmpty && siteKey != 'all';

  /// 页内容指纹：对条目按 (id, 名称) 排序后做长度前缀拼接，与顺序无关
  /// （上游 `SearchPageState.pageToken` 同算法；PC 端的条目已按站点分桶，
  /// 因此不再把站点 key 混进指纹）。
  static String pageTokenOf(List<Vod> items) {
    if (items.isEmpty) return '';
    final entries = [
      for (final item in items)
        '${item.vodId.length}:${item.vodId}'
            '${item.vodName.length}:${item.vodName}',
    ]..sort();
    return entries.join();
  }
}

/// 一次分页请求的登记。
final class _PagingRequest {
  const _PagingRequest(this.siteKey, this.page);

  final String siteKey;
  final int page;
}

/// [SearchPagingState.complete] 的结果。
class PagingCompletion {
  const PagingCompletion({
    required this.handled,
    required this.accepted,
    required this.siteKey,
    required this.page,
    this.repeated = false,
  });

  static const PagingCompletion none = PagingCompletion(
    handled: false,
    accepted: false,
    siteKey: '',
    page: 0,
  );

  /// 是否有在途请求被这次完成登记消费掉。
  final bool handled;

  /// 这一页是否被接受（有条目且内容不重复）。
  final bool accepted;

  final String siteKey;
  final int page;

  /// 内容与已见过的某页完全重复（该站点已判定耗尽）。
  final bool repeated;
}
