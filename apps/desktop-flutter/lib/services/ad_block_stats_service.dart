/// 去广告统计的入口（安卓 `AdBlockStats` 记账侧的 PC 化）。
///
/// 只做一件事：把一次 HLS 清洗结果翻译成拦截日志，交给 store 记账 + 落盘。
/// 翻译规则固定，因而可以单测：
/// - 明细来自 `HlsCleanResult.removed`，一段广告一条日志；
/// - `adDomain` 取 `AdRemovedSegment.host`，`ruleId` 取 `AdRemovedSegment.ruleId`，
///   时间取记账那一刻的毫秒时间戳；
/// - **`abandoned` 或 `!changed` 时一条都不记**：安全回退意味着什么都没删，
///   记账就成了假数据。
library;

import '../core/ad_block_stats.dart';
import '../core/ad_rules.dart';
import 'ad_block_stats_store.dart';

class AdBlockStatsService {
  AdBlockStatsService({required this.store, this.ruleName});

  final AdBlockStatsStore store;

  /// 规则 id → 展示名（页面用它把 `r1` 显示成人能读的名字）。
  final String Function(String ruleId)? ruleName;

  AdBlockStats get stats => store.stats;

  /// 展示名；回调缺席或返回空串时退回规则 id 本身。
  String ruleLabel(String ruleId) {
    final label = ruleName?.call(ruleId).trim() ?? '';
    return label.isEmpty ? ruleId : label;
  }

  /// 记一次清洗。
  void recordClean({
    required HlsCleanResult result,
    required AdBlockContext context,
  }) {
    // 回退即没删：放弃时原文与计数都已归零，这里既不能记日志也不能累加。
    if (result.abandoned || !result.changed) return;
    final blockedAt = DateTime.now().millisecondsSinceEpoch;
    final logs = <AdBlockLog>[
      for (final segment in result.removed)
        AdBlockLog(
          blockedAt: blockedAt,
          siteKey: context.siteKey,
          siteName: context.siteName,
          siteDomain: context.siteDomain,
          pipeline: context.pipeline,
          adDomain: segment.host,
          ruleId: segment.ruleId,
          vodName: context.vodName,
          lineName: context.lineName,
          episodeName: context.episodeName,
          segmentStartSeconds: segment.startSeconds,
          segmentDurationSeconds: segment.durationSec,
        ),
    ];
    if (logs.isEmpty) return;
    store.record(logs);
  }

  /// 清空统计（`Future` 是因为调用方是按钮；store 侧仍是一次同步写）。
  Future<bool> reset() async => store.reset();
}
