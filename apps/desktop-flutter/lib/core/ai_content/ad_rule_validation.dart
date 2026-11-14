/// AI 去广规则的类型合同与方向/安全校验。
///
/// 对齐安卓 `AiAdDetectionService` 与 `bean/AdDetectionResult`：
/// `confidence / hostsBlacklist / regexPatterns / excludePatterns / reasoning`，
/// 以及 `bean/M3u8Evidence.toSummary()` 的「首尾各 3 段 + 摘要」证据格式。
///
/// 两条硬约束（方向绝不能反）：
/// 1. `regexPatterns` 描述**广告**：命中主内容路径的任何一条都被判为危险并拒绝；
/// 2. `excludePatterns` 保护**正片**：它与广告正则对同一地址都命中时就是方向
///    冲突，同样拒绝——宁可不出规则，也不能把正片当广告切掉。
///
/// 置信度低于阈值时只产出警告（`warningOnly`），不提供可应用规则。
library;

import '../ai_assist.dart' show decodeJsonObject, extractJsonObject;
import 'group_rule_validation.dart' show isJavaCompatibleSafeRegex;

/// m3u8 切片证据（与安卓同字段）。
class AdPlaylistEvidence {
  const AdPlaylistEvidence({
    this.segments = const [],
    this.discontinuities = const [],
    this.durations = const [],
    this.domainSwitches = const [],
  });

  const AdPlaylistEvidence.empty() : this();

  final List<String> segments;
  final List<int> discontinuities;
  final List<double> durations;
  final List<bool> domainSwitches;

  bool get isEmpty => segments.isEmpty;

  int get totalSegments => segments.length;

  /// 供提示词使用的摘要：总数/不连续点/总时长/域切换数 + 首尾各 3 段。
  String summary() {
    if (isEmpty) return 'No segments found';
    final buffer = StringBuffer()
      ..writeln('Total segments: ${segments.length}')
      ..writeln(
        'Discontinuities at: '
        '${discontinuities.isEmpty ? 'None' : discontinuities}',
      );
    var total = 0.0;
    for (final duration in durations) {
      total += duration;
    }
    buffer.writeln('Total duration: ${total.toStringAsFixed(1)}s');
    var switches = 0;
    for (final switched in domainSwitches) {
      if (switched) switches++;
    }
    buffer.writeln('Domain switches: $switches');
    buffer.writeln();
    buffer.writeln('First 3 segments:');
    for (var i = 0; i < 3 && i < segments.length; i++) {
      buffer.write(_segmentLine(i));
    }
    if (segments.length > 6) {
      buffer.writeln('  ... (${segments.length - 6} segments)');
    }
    if (segments.length > 3) {
      buffer.writeln('Last 3 segments:');
      for (var i = segments.length - 3 < 3 ? 3 : segments.length - 3;
          i < segments.length;
          i++) {
        buffer.write(_segmentLine(i));
      }
    }
    return buffer.toString();
  }

  String _segmentLine(int index) {
    final buffer = StringBuffer()
      ..write('  [$index] ')
      ..write(_truncateUrl(segments[index]));
    if (index < domainSwitches.length && domainSwitches[index]) {
      buffer.write(' [DOMAIN_SWITCH]');
    }
    if (discontinuities.contains(index)) buffer.write(' [DISCONTINUITY]');
    final duration = index < durations.length ? durations[index] : 0.0;
    buffer.writeln(' (${duration.toStringAsFixed(1)}s)');
    return buffer.toString();
  }

  static String _truncateUrl(String url) {
    if (url.length <= 80) return url;
    return '${url.substring(0, 40)}...${url.substring(url.length - 37)}';
  }
}

/// 语法清洗后的去广候选；必须用当前播放证据重验后才能确认应用。
class AdRuleProposal {
  const AdRuleProposal({
    required this.confidence,
    this.hostsBlacklist = const [],
    this.regexPatterns = const [],
    this.excludePatterns = const [],
    this.reasoning = '',
  });

  final double confidence;
  final List<String> hostsBlacklist;
  final List<String> regexPatterns;
  final List<String> excludePatterns;
  final String reasoning;

  bool get isEmpty =>
      hostsBlacklist.isEmpty &&
      regexPatterns.isEmpty &&
      excludePatterns.isEmpty;

  Map<String, Object?> toJson() => {
    'confidence': confidence,
    'hostsBlacklist': hostsBlacklist,
    'regexPatterns': regexPatterns,
    'excludePatterns': excludePatterns,
    'reasoning': reasoning,
  };

  static AdRuleProposal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final confidence = raw['confidence'];
    final warnings = <String>[];
    // 落盘/导入的正则同样是不可信数据：重新过一遍安全子集、长度与域名清洗，
    // 否则手工编辑或导入的 JSON 会绕过 AI 路径的校验直接进入应用。
    final proposal = AdRuleProposal(
      confidence: confidence is num ? _clamp01(confidence.toDouble()) : 0,
      hostsBlacklist: _sanitizeHosts(raw['hostsBlacklist'], warnings),
      regexPatterns: _sanitizeRegexes(
        raw['regexPatterns'],
        maxRegexLength: AdRuleLimits.maxRegexLength,
        maxRegexRules: AdRuleLimits.maxRegexRules,
        label: '广告正则',
        warnings: warnings,
      ),
      excludePatterns: _sanitizeRegexes(
        raw['excludePatterns'],
        maxRegexLength: AdRuleLimits.maxRegexLength,
        maxRegexRules: AdRuleLimits.maxRegexRules,
        label: '排除正则',
        warnings: warnings,
      ),
      reasoning: raw['reasoning'] is String ? raw['reasoning']! as String : '',
    );
    if (proposal.confidence < AdRuleLimits.minConfidence || proposal.isEmpty) {
      return null;
    }
    if (proposal.regexPatterns.any(proposal.excludePatterns.contains)) {
      return null;
    }
    return proposal;
  }
}

/// 结论级别。
enum AdRuleVerdict {
  /// 可进入「用户确认后应用」的流程。
  applicable,

  /// 置信度不足：只展示警告，不给应用入口。
  warningOnly,

  /// 输出不可用或方向危险：整份丢弃。
  rejected,
}

/// 评估结果。
class AdRuleAssessment {
  const AdRuleAssessment({
    required this.verdict,
    this.proposal,
    this.warnings = const [],
    this.reasons = const [],
  });

  final AdRuleVerdict verdict;
  final AdRuleProposal? proposal;
  final List<String> warnings;
  final List<String> reasons;

  bool get applicable =>
      verdict == AdRuleVerdict.applicable && proposal != null;
}

/// 上限（与分组规则同口径：单条正则不超过 256 字符）。
abstract final class AdRuleLimits {
  static const int maxRegexLength = 256;
  static const int maxRegexRules = 8;
  static const int maxHosts = 12;
  static const double minConfidence = 0.5;
}

/// 校验 AI 去广建议。
///
/// [evidenceSegments] 是本次分析的真实 m3u8 切片地址：方向冲突用真实地址判定；
/// 没有证据时才退回内置样本（仅用于「两条正则互相咬住」的兜底判定）。
AdRuleAssessment assessAdRuleProposal(
  Object? raw, {
  required String contentHost,
  required String contentPath,
  List<String> evidenceSegments = const [],
  double minConfidence = AdRuleLimits.minConfidence,
  int maxRegexLength = AdRuleLimits.maxRegexLength,
  int maxRegexRules = AdRuleLimits.maxRegexRules,
}) {
  final Map<String, Object?>? decoded;
  if (raw is Map) {
    decoded = raw.cast<String, Object?>();
  } else if (raw is String) {
    final jsonText = extractJsonObject(raw);
    if (jsonText == null) {
      return const AdRuleAssessment(
        verdict: AdRuleVerdict.rejected,
        reasons: ['AI 输出不是可解析的 JSON 对象'],
      );
    }
    decoded = decodeJsonObject(jsonText);
  } else {
    decoded = null;
  }
  if (decoded == null) {
    return const AdRuleAssessment(
      verdict: AdRuleVerdict.rejected,
      reasons: ['AI 输出的 JSON 无法解析'],
    );
  }

  final warnings = <String>[];
  final hosts = _sanitizeHosts(decoded['hostsBlacklist'], warnings);
  final adRegexes = _sanitizeRegexes(
    decoded['regexPatterns'],
    maxRegexLength: maxRegexLength,
    maxRegexRules: maxRegexRules,
    label: '广告正则',
    warnings: warnings,
  );
  final excludeRegexes = _sanitizeRegexes(
    decoded['excludePatterns'],
    maxRegexLength: maxRegexLength,
    maxRegexRules: maxRegexRules,
    label: '排除正则',
    warnings: warnings,
  );

  if (adRegexes.any(excludeRegexes.contains)) {
    return const AdRuleAssessment(
      verdict: AdRuleVerdict.rejected,
      reasons: ['广告正则与排除正则完全相同，方向冲突'],
    );
  }
  final currentHost = contentHost.trim().toLowerCase();
  for (final host in hosts) {
    if (currentHost == host || currentHost.endsWith('.$host')) {
      return const AdRuleAssessment(
        verdict: AdRuleVerdict.rejected,
        reasons: ['黑名单域名承载当前正片，不能应用'],
      );
    }
  }
  // 方向校验 1：广告正则绝不能命中主内容。
  for (final pattern in adRegexes) {
    final regex = RegExp(pattern);
    if (regex.hasMatch(contentPath) ||
        (contentHost.isNotEmpty && regex.hasMatch(contentHost))) {
      return AdRuleAssessment(
        verdict: AdRuleVerdict.rejected,
        reasons: ['广告正则会命中正片路径（正片保护优先）：$pattern'],
      );
    }
  }

  // 方向校验 2：排除正则与广告正则对同一地址都命中 = 方向冲突。
  // 用真实证据地址判定；没有证据时才用内置样本兜底。
  final conflictSamples = evidenceSegments.isEmpty
      ? _adSamples
      : [
          ...evidenceSegments,
          if (contentPath.isNotEmpty) contentPath,
        ];
  for (final ad in adRegexes) {
    final adRegex = RegExp(ad);
    for (final exclude in excludeRegexes) {
      final excludeRegex = RegExp(exclude);
      for (final sample in conflictSamples) {
        if (adRegex.hasMatch(sample) && excludeRegex.hasMatch(sample)) {
          return AdRuleAssessment(
            verdict: AdRuleVerdict.rejected,
            reasons: [
              '广告正则与排除正则方向冲突（同一地址 $sample 同时命中）：'
                  '$ad / $exclude',
            ],
          );
        }
      }
    }
  }

  final rawConfidence = decoded['confidence'];
  final confidence = rawConfidence is num
      ? _clamp01(rawConfidence.toDouble())
      : (rawConfidence is String
            ? _clamp01(double.tryParse(rawConfidence.trim()) ?? 0)
            : 0.0);
  final reasoning = decoded['reasoning'] is String
      ? (decoded['reasoning']! as String).trim()
      : '';

  if (confidence < minConfidence) {
    return AdRuleAssessment(
      verdict: AdRuleVerdict.warningOnly,
      warnings: [
        '置信度 ${(confidence * 100).round()}% 低于 '
            '${(minConfidence * 100).round()}%，仅供参考，不提供可应用规则',
        ...warnings,
        if (reasoning.isNotEmpty) reasoning,
      ],
    );
  }

  final proposal = AdRuleProposal(
    confidence: confidence,
    hostsBlacklist: hosts,
    regexPatterns: adRegexes,
    excludePatterns: excludeRegexes,
    reasoning: reasoning,
  );
  if (proposal.isEmpty) {
    return AdRuleAssessment(
      verdict: AdRuleVerdict.warningOnly,
      warnings: ['没有可用的域名或正则建议', ...warnings],
    );
  }
  return AdRuleAssessment(
    verdict: AdRuleVerdict.applicable,
    proposal: proposal,
    warnings: warnings,
  );
}

/// 无证据时的兜底样本：只用于判断两条正则是否互相咬住。
/// 有真实切片证据时一律用证据地址（见 [assessAdRuleProposal]）。
const List<String> _adSamples = [
  '/ad/clip.ts',
  '/ads/roll.mp4',
  '/preroll/index.m3u8',
];

List<String> _sanitizeHosts(Object? raw, List<String> warnings) {
  if (raw is! List) return const [];
  final result = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    var value = item.trim().toLowerCase();
    if (value.isEmpty) continue;
    // 去协议、路径、端口、查询。
    final scheme = value.indexOf('://');
    if (scheme >= 0) value = value.substring(scheme + 3);
    final slash = value.indexOf('/');
    if (slash >= 0) value = value.substring(0, slash);
    final query = value.indexOf('?');
    if (query >= 0) value = value.substring(0, query);
    final colon = value.indexOf(':');
    if (colon >= 0) value = value.substring(0, colon);
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    if (value.isEmpty) continue;
    if (!RegExp(r'^[a-z0-9.\-]+$').hasMatch(value)) {
      warnings.add('丢弃非法域名片段：$item');
      continue;
    }
    if (value.contains('..') || !value.contains('.')) {
      warnings.add('丢弃非法域名片段：$item');
      continue;
    }
    if (result.contains(value)) continue;
    result.add(value);
    if (result.length >= AdRuleLimits.maxHosts) break;
  }
  return List.unmodifiable(result);
}

List<String> _sanitizeRegexes(
  Object? raw, {
  required int maxRegexLength,
  required int maxRegexRules,
  required String label,
  required List<String> warnings,
}) {
  if (raw is! List) return const [];
  final result = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    final pattern = item.trim();
    if (pattern.isEmpty) continue;
    if (pattern.length > maxRegexLength) {
      warnings.add('$label超过 $maxRegexLength 字符，已丢弃');
      continue;
    }
    if (!isJavaCompatibleSafeRegex(pattern)) {
      warnings.add('$label不在安全子集内，已丢弃：$pattern');
      continue;
    }
    if (result.contains(pattern)) continue;
    result.add(pattern);
    if (result.length >= maxRegexRules) break;
  }
  return List.unmodifiable(result);
}

double _clamp01(double value) {
  if (value.isNaN) return 0;
  if (value < 0) return 0;
  if (value > 1) return 1;
  return value;
}



