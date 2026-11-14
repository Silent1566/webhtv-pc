/// 结构画像：从本地观影报告派生的结构化统计 + 24 小时指纹缓存策略。
///
/// 设计依据来自风险 3「画像旧响应跨范围显示」：缓存必须同时绑定
/// **输入指纹**（记录数 + 最近更新时间）与**范围 id**，任一不符即失效，
/// 绝不允许把「本月」的 AI 解读贴到「全部」范围上。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../viewing_report.dart';

/// 输入指纹（对齐安卓 `ViewingReportCache`：count + latest，取 hex 前 12）。
abstract final class ViewingProfileFingerprint {
  static String of({
    required int recordCount,
    required int latestUpdatedAtMs,
  }) {
    final raw = '$recordCount|$latestUpdatedAtMs';
    return md5.convert(utf8.encode(raw)).toString().substring(0, 12);
  }
}

/// 一份结构画像。
class ViewingProfile {
  const ViewingProfile({
    required this.rangeId,
    required this.fingerprint,
    required this.generatedAtMs,
    required this.recordCount,
    required this.slotShares,
    required this.completionRate,
    required this.lateNightShare,
    required this.weekendShare,
    required this.totalWatchMinutes,
    required this.topVodName,
  });

  /// 报告范围 id（`ViewingReportRange.name`）：缓存隔离的第一把钥匙。
  final String rangeId;
  final String fingerprint;
  final int generatedAtMs;
  final int recordCount;

  /// 每个时段占记录数的比例（无记录时全 0）。
  final Map<ViewingTimeSlot, double> slotShares;

  final double completionRate;
  final double lateNightShare;
  final double weekendShare;
  final int totalWatchMinutes;

  /// 观看时长最高的作品名；没有记录时为 null。
  final String? topVodName;

  Map<String, Object?> toJson() => {
    'rangeId': rangeId,
    'fingerprint': fingerprint,
    'generatedAtMs': generatedAtMs,
    'recordCount': recordCount,
    'slotShares': {
      for (final entry in slotShares.entries) entry.key.name: entry.value,
    },
    'completionRate': completionRate,
    'lateNightShare': lateNightShare,
    'weekendShare': weekendShare,
    'totalWatchMinutes': totalWatchMinutes,
    'topVodName': topVodName,
  };

  static ViewingProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final rangeId = raw['rangeId'];
    final fingerprint = raw['fingerprint'];
    if (rangeId is! String || fingerprint is! String) return null;
    final shares = <ViewingTimeSlot, double>{
      for (final slot in ViewingTimeSlot.values) slot: 0,
    };
    final rawShares = raw['slotShares'];
    if (rawShares is Map) {
      for (final slot in ViewingTimeSlot.values) {
        final value = rawShares[slot.name];
        if (value is num) shares[slot] = value.toDouble();
      }
    }
    double number(Object? value) => value is num ? value.toDouble() : 0;
    return ViewingProfile(
      rangeId: rangeId,
      fingerprint: fingerprint,
      generatedAtMs: raw['generatedAtMs'] is int
          ? raw['generatedAtMs']! as int
          : 0,
      recordCount: raw['recordCount'] is int ? raw['recordCount']! as int : 0,
      slotShares: shares,
      completionRate: number(raw['completionRate']),
      lateNightShare: number(raw['lateNightShare']),
      weekendShare: number(raw['weekendShare']),
      totalWatchMinutes: raw['totalWatchMinutes'] is int
          ? raw['totalWatchMinutes']! as int
          : 0,
      topVodName: raw['topVodName'] is String ? raw['topVodName']! as String : null,
    );
  }
}

/// 由本地报告生成结构画像（纯函数）。
ViewingProfile buildViewingProfile({
  required ViewingReport report,
  required int latestUpdatedAtMs,
  DateTime? now,
}) {
  final generatedAt = now ?? DateTime.now();
  final total = report.recordCount;
  final shares = <ViewingTimeSlot, double>{
    for (final slot in ViewingTimeSlot.values)
      slot: total == 0 ? 0.0 : (report.timeSlots[slot] ?? 0) / total,
  };
  return ViewingProfile(
    rangeId: report.range.name,
    fingerprint: ViewingProfileFingerprint.of(
      recordCount: report.recordCount,
      latestUpdatedAtMs: latestUpdatedAtMs,
    ),
    generatedAtMs: generatedAt.millisecondsSinceEpoch,
    recordCount: report.recordCount,
    slotShares: shares,
    completionRate: report.completionRate,
    lateNightShare: total == 0 ? 0 : report.lateNightCount / total,
    weekendShare: report.weekendRatio,
    totalWatchMinutes: report.totalWatchMinutes,
    topVodName: report.topVods.isEmpty ? null : report.topVods.first.name,
  );
}

/// 画像缓存策略。
abstract final class ViewingProfileCachePolicy {
  static const Duration ttl = Duration(hours: 24);

  /// 是否可复用缓存：范围一致 + 指纹一致 + 24 小时内。
  static bool isReusable({
    required String cachedRangeId,
    required String requestedRangeId,
    required String cachedFingerprint,
    required String currentFingerprint,
    required int generatedAtMs,
    required DateTime now,
  }) {
    if (cachedRangeId != requestedRangeId) return false;
    if (cachedFingerprint != currentFingerprint) return false;
    if (generatedAtMs <= 0) return false;
    final age = now.millisecondsSinceEpoch - generatedAtMs;
    return age >= 0 && age <= ttl.inMilliseconds;
  }
}
