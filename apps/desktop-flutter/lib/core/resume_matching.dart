/// 跨源续播的**候选匹配与置信分级**（纯逻辑，可无窗口单测）。
///
/// 对齐上游安卓 `VodSourceResolver` 的候选等级表
/// （`docs/global-history-resume-design.md` §10.4），但按 PC 现状**只保留
/// 能可靠判定的三级**——PC 侧没有 `SiteHealthStore` 的健康评分参与自动决策，
/// 也不在列表阶段发任何网络请求，因此安卓表里的 `UNIQUE_TITLE_CONFIRMED`
/// 在这里降级为歧义（宁可让用户手动选，不可自作主张播错片）。
///
/// ## 等级
///
/// | 等级 | 条件 | 自动播放 |
/// | --- | --- | --- |
/// | `tmdb` | 双方 `(mediaType, tmdbId)` 一致 | 是 |
/// | `titleYear` | 规范化片名完全一致 + 年份一致 | 是 |
/// | `ambiguous` | 其余（含仅包含匹配、年份缺失、多候选同分） | 否 |
/// | `rejected` | TMDB 冲突 / 年份明确冲突 | 否 |
///
/// 年份缺失**不算一致**（安卓 §10.4 同）：两条都没年份只能说「无法排除」，
/// 不能升格成高置信。
library;

import 'tmdb_identity.dart';

/// 匹配置信等级。
abstract final class MatchConfidence {
  /// TMDB 身份一致。
  static const String tmdb = 'tmdb';

  /// 规范化片名 + 年份一致。
  static const String titleYear = 'titleYear';

  /// 无法可靠判定。
  static const String ambiguous = 'ambiguous';

  /// 明确冲突（TMDB 不同 / 年份冲突）。
  static const String rejected = 'rejected';

  /// 是否允许**自动**采用该候选。
  static bool canAutoPlay(String confidence) =>
      confidence == tmdb || confidence == titleYear;
}

/// 一条候选（搜索结果 / 同源站点的另一部作品）。
class ResumeCandidate {
  const ResumeCandidate({
    required this.siteKey,
    required this.siteName,
    required this.vodId,
    required this.vodName,
    this.vodYear = '',
    this.tmdbId = 0,
    this.mediaType = '',
    this.episodeCount = 0,
    this.hasTargetEpisode = false,
  });

  final String siteKey;
  final String siteName;
  final String vodId;
  final String vodName;
  final String vodYear;
  final int tmdbId;
  final String mediaType;

  /// 该候选详情里的集数（0 = 未知）。
  final int episodeCount;

  /// 该候选详情的线路里**是否找到了目标集**（由调用方在加载详情后判定）。
  final bool hasTargetEpisode;

  String get normalizedMediaType {
    final value = mediaType.trim().toLowerCase();
    return value == 'movie' || value == 'tv' ? value : '';
  }

  bool get hasTmdbIdentity => tmdbId > 0 && normalizedMediaType.isNotEmpty;
}

/// 续播请求（原记录的身份信息，标量投影）。
class ResumeRequest {
  const ResumeRequest({
    required this.vodName,
    this.vodYear = '',
    this.tmdbId = 0,
    this.mediaType = '',
  });

  final String vodName;
  final String vodYear;
  final int tmdbId;
  final String mediaType;

  String get normalizedMediaType {
    final value = mediaType.trim().toLowerCase();
    return value == 'movie' || value == 'tv' ? value : '';
  }

  bool get hasTmdbIdentity => tmdbId > 0 && normalizedMediaType.isNotEmpty;

  /// 归一化片名（用于标题级比较）。
  String get normalizedTitle => TmdbCacheKey.normalizeSourceTitle(vodName);
}

/// 为一个候选评级（纯函数，不发起请求）。
String rateCandidate(ResumeRequest request, ResumeCandidate candidate) {
  // 1. 双方都有 TMDB 身份：只认完全一致，明确不同即拒绝。
  if (request.hasTmdbIdentity && candidate.hasTmdbIdentity) {
    if (request.tmdbId == candidate.tmdbId &&
        request.normalizedMediaType == candidate.normalizedMediaType) {
      return MatchConfidence.tmdb;
    }
    return MatchConfidence.rejected;
  }
  // 2. 一方有 TMDB、另一方没有：TMDB 不能参与，退回标题级。
  final requestTitle = request.normalizedTitle;
  final candidateTitle = TmdbCacheKey.normalizeSourceTitle(candidate.vodName);
  if (requestTitle.isEmpty || candidateTitle.isEmpty) {
    return MatchConfidence.ambiguous;
  }
  if (requestTitle != candidateTitle) {
    // 仅「包含」关系不足以判定同名（另一部作品常见）。
    return MatchConfidence.ambiguous;
  }
  final requestYear = request.vodYear.trim();
  final candidateYear = candidate.vodYear.trim();
  if (requestYear.isEmpty || candidateYear.isEmpty) {
    // 片名一致但年份缺失：无法排除同名不同年，不升格。
    return MatchConfidence.ambiguous;
  }
  if (requestYear != candidateYear) {
    return MatchConfidence.rejected;
  }
  return MatchConfidence.titleYear;
}

/// 候选排序权重（同等级内的稳定顺序）。
int _rankOf(String confidence) => switch (confidence) {
  MatchConfidence.tmdb => 0,
  MatchConfidence.titleYear => 1,
  MatchConfidence.ambiguous => 2,
  _ => 3,
};

/// 给候选列表评级并排序，返回 `(候选, 等级)` 列表。
///
/// 排序规则（稳定，便于测试断言）：
/// 1. 等级（tmdb > titleYear > ambiguous > rejected）；
/// 2. 找到了目标集的优先；
/// 3. 保持输入顺序（调用方已按站点顺序 / 搜索结果顺序排好）。
List<({ResumeCandidate candidate, String confidence})> rankCandidates(
  ResumeRequest request,
  List<ResumeCandidate> candidates,
) {
  final rated = <({ResumeCandidate candidate, String confidence, int index})>[
    for (var i = 0; i < candidates.length; i++)
      (
        candidate: candidates[i],
        confidence: rateCandidate(request, candidates[i]),
        index: i,
      ),
  ];
  rated.sort((a, b) {
    final byConfidence =
        _rankOf(a.confidence).compareTo(_rankOf(b.confidence));
    if (byConfidence != 0) return byConfidence;
    final byEpisode = (b.candidate.hasTargetEpisode ? 1 : 0)
        .compareTo(a.candidate.hasTargetEpisode ? 1 : 0);
    if (byEpisode != 0) return byEpisode;
    return a.index.compareTo(b.index);
  });
  return [
    for (final item in rated)
      (candidate: item.candidate, confidence: item.confidence),
  ];
}

/// 从已排序的候选里选出**可自动播放**的那一个。
///
/// 只有同时满足「等级够高」「找到了目标集」才返回；否则 `null`——
/// 由调用方降级为「打开全局搜索」让用户手动选（安卓 §7.3 同）。
///
/// 多个高置信候选时取**第一个**（排序已保证站点顺序稳定），不引入额外的
/// 评分体系（安卓 §12 线路选择同样「保持源站顺序，不引入新的质量评分」）。
ResumeCandidate? pickAutoPlayable(
  List<({ResumeCandidate candidate, String confidence})> ranked,
) {
  for (final item in ranked) {
    if (!MatchConfidence.canAutoPlay(item.confidence)) continue;
    if (!item.candidate.hasTargetEpisode) continue;
    return item.candidate;
  }
  return null;
}
