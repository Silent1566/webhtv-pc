/// 多站点并发搜索的状态模型（§14.1、§14.3）。
///
/// 单独成文件的理由：搜索批次是 UI 与状态层共享的只读快照，把它和
/// [AppState] 的其它职责混在一起会让「结果是否已被取代」「取消后是否还投递」
/// 这类约束难以被测试直接观察。
library;

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
    this.result,
    this.error,
    this.latency = Duration.zero,
    this.fromCache = false,
  });

  final String siteKey;
  final String siteName;
  final SiteResult? result;
  final AppError? error;
  final Duration latency;
  final bool fromCache;

  /// 该站点是否搜索成功。
  bool get succeeded => error == null;

  /// 该站点返回的条目数。
  int get itemCount => result?.list.length ?? 0;
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
    this.skippedUnsupported = 0,
    this.skippedNotSearchable = 0,
  }) : _results = List.of(results);

  final int runId;
  final String keyword;

  /// 因运行时不可用而跳过的站点数（§8.1）。
  final int skippedUnsupported;

  /// 因未声明 `searchable` 而跳过的站点数。
  final int skippedNotSearchable;

  List<SiteSearchEntry> _results;

  /// 全部站点是否都已结束（成功或失败）。
  bool finished = false;

  /// 用户是否已取消本批次。
  bool cancelled = false;

  /// 从发起到全部结束的总耗时。
  Duration totalElapsed = Duration.zero;

  List<SiteSearchEntry> get results => List.unmodifiable(_results);

  int get succeededCount => _results.where((entry) => entry.succeeded).length;

  int get failedCount => _results.where((entry) => !entry.succeeded).length;

  int get totalItems =>
      _results.fold(0, (sum, entry) => sum + entry.itemCount);

  /// 是否存在「成功但零结果」的站点，用于给出准确提示（§14.3）。
  bool get hasEmptyResult =>
      _results.any((entry) => entry.succeeded && entry.itemCount == 0);

  /// 用最新快照替换结果集合（每个站点完成都会调用一次）。
  void update(List<SiteSearchEntry> next) {
    _results = List.of(next);
  }
}
