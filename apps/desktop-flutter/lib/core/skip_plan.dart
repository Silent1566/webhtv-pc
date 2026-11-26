/// 片头/片尾的**远端标定解析与播放决策**（对齐安卓 `IntroSkipService` /
/// `IntroSkipPlayback`，见 `docs/phase9/design/01` §3）。
///
/// 与 [SkipSegments] 的分工：
/// - [SkipSegments] 是**用户手动标记**，按影片存进 SQLite，只有 `introEndMs` /
///   `outroStartMs` 两个点；
/// - 本文件处理**远端标定**：一条记录里可能有回顾/片头/片尾/预告四类段，且时间
///   轴对的是数据源标定用的那个片源，与本地片源存在整体漂移。
///
/// 纯逻辑：不碰 Flutter、不碰 IO、不碰播放器，便于穷举测试。
library;

import 'skip_segments.dart';

/// 片段类型的位（对齐安卓 `Setting.INTRO_SKIP_KIND_*`）。
///
/// 用独立常量而不是枚举字段：Dart 的 `const` 表达式不允许读取枚举实例的字段，
/// 而这里需要在 `PlayerOptions` 的默认值里写成常量。
abstract final class SkipKindBits {
  static const int recap = 1;
  static const int intro = 1 << 1;
  static const int outro = 1 << 2;
  static const int preview = 1 << 3;

  /// 片尾之后的彩蛋/附加内容（IntroDB 的 `post_credits`）。
  ///
  /// 与「下集预告」分成两类而不是并成一类：观众常常正相反——预告跳过、彩蛋留着。
  /// 并成一类等于强迫他二选一，而这个选择在播放页上根本看不见。
  static const int postCredits = 1 << 4;

  /// 片内广告位（TODB 的 `advertisement`）。
  static const int advertisement = 1 << 5;

  /// 中场休息/幕间（TODB 的 `intermission`）。
  static const int intermission = 1 << 6;

  /// 出厂默认：回顾 + 片头 + 片尾（安卓 `INTRO_SKIP_KIND_DEFAULT`）。
  ///
  /// 预告、彩蛋、广告、休息都默认**关**：它们要么排在最末尾（误跳等于切走一集），
  /// 要么依赖社区标注的准确度。开关都在设置页，用户自己开。
  static const int defaults = recap | intro | outro;
  static const int all =
      recap |
      intro |
      outro |
      preview |
      postCredits |
      advertisement |
      intermission;
  static const int none = 0;
}

/// 片段类型。
enum SkipKind {
  /// 前情回顾（正片之前）。
  recap,

  /// 片头/OP。
  intro,

  /// 片尾/ED。
  outro,

  /// 下集预告（常在片尾之后，也可能连着文件结尾）。
  preview,

  /// 片尾之后的彩蛋/附加内容（IntroDB `post_credits`）。
  postCredits,

  /// 片内广告位（TODB `advertisement`）。片中/任意位置，走绝对时间轴。
  advertisement,

  /// 中场休息/幕间（TODB `intermission`）。走绝对时间轴。
  intermission;

  int get bit => switch (this) {
    SkipKind.recap => SkipKindBits.recap,
    SkipKind.intro => SkipKindBits.intro,
    SkipKind.outro => SkipKindBits.outro,
    SkipKind.preview => SkipKindBits.preview,
    SkipKind.postCredits => SkipKindBits.postCredits,
    SkipKind.advertisement => SkipKindBits.advertisement,
    SkipKind.intermission => SkipKindBits.intermission,
  };

  String get label => switch (this) {
    SkipKind.recap => '回顾',
    SkipKind.intro => '片头',
    SkipKind.outro => '片尾',
    SkipKind.preview => '预告',
    SkipKind.postCredits => '彩蛋',
    SkipKind.advertisement => '广告',
    SkipKind.intermission => '休息',
  };

  /// 正片之前（跳的目标是「段末」）。
  bool get isOpening => this == SkipKind.recap || this == SkipKind.intro;

  /// 片中段（广告/休息）：位置任意，同样走**绝对**时间轴。
  ///
  /// 它既不是「正片之前」也不是「尾部」，单列出来是因为去重分组必须把它和
  /// 开头段分开：一条 0–30s 的广告与一条 0–90s 的片头本来就可能是两回事，
  /// 合并掉会让用户开的那个开关形同虚设。
  bool get isMidRoll =>
      this == SkipKind.advertisement || this == SkipKind.intermission;

  /// 正片之后（段的时间轴按「距文件结尾的距离」理解）。
  bool get isEnding =>
      this == SkipKind.outro ||
      this == SkipKind.preview ||
      this == SkipKind.postCredits;

  /// 是否走绝对时间轴。只有尾部段例外（它们按「距结尾的距离」折算）。
  bool get usesAbsoluteTimeline => !isEnding;

  /// 去重分组：同组内才可能被判为「同一段」，跨组永不合并。
  ///
  /// 开头（回顾/片头）/ 片中（广告/休息）/ 尾部（片尾/预告/彩蛋）三组物理位置不同，
  /// 混在一起比重叠会把紧随其后的段整段吞掉。
  int get dedupeGroup {
    if (isEnding) return 2;
    if (isMidRoll) return 1;
    return 0;
  }

  /// 把外部 `marker_type` / 字段名映射成本类型；不认识的一律返回 null。
  ///
  /// 只认**明确表示可跳过内容**的名字：TODB 的 `chapter` 是剧情章节标记，
  /// 不是可跳过段，认进来会让播放器把正片当片尾跳掉。
  static SkipKind? fromWire(Object? raw) {
    final value = raw is String ? raw.trim().toLowerCase() : '';
    return switch (value) {
      'recap' || 'previously' || 'previously_on' => SkipKind.recap,
      'intro' || 'opening' || 'op' => SkipKind.intro,
      'outro' || 'credits' || 'ending' || 'ed' => SkipKind.outro,
      'preview' || 'next_episode' || 'next' || 'trailer' => SkipKind.preview,
      'post_credits' ||
      'post_credit' ||
      'postcredits' ||
      'extras' => SkipKind.postCredits,
      'advertisement' || 'ad' || 'ads' => SkipKind.advertisement,
      'intermission' || 'interval' => SkipKind.intermission,
      _ => null,
    };
  }
}

/// 跳过模式（对齐安卓 `Setting.INTRO_SKIP_MODE_*`）。
enum SkipMode {
  /// 完全关闭：不查询、不跳过。
  off,

  /// 命中即静默 seek。
  auto,

  /// 命中先弹确认框，用户点确定才 seek。
  confirm;

  static SkipMode fromName(Object? raw) => switch (raw) {
    'auto' => SkipMode.auto,
    'confirm' => SkipMode.confirm,
    _ => SkipMode.off,
  };
}

/// 参考时长与本集时长的差值超过该值才做时间轴折算（几百毫秒的抖动不算换版本）。
const int skipTimeBaseToleranceMs = 2000;

/// 段末落在参考结尾的这个范围内，视为「一直放到文件结束」。
const int skipOpenEndToleranceMs = 5000;

/// 参考时长与本集时长的最大容许差：超过即认为不是同一版本，放弃折算。
const int skipMaxTimeBaseDriftMs = 5 * 60 * 1000;

/// 起点差在此范围内视为两家在说同一段。
const int skipSameStartToleranceMs = 3000;

/// 外部时间轴超过一周即视为异常输入。
const int skipMaxMediaTimeMs = 7 * 24 * 60 * 60 * 1000;

/// 提交次数上限：超出范围的外部值夹住而不是截断绕回。
const int skipMaxSubmissionCount = 1000000;

/// 跳转落点与当前位置的最小距离，小于它就不值得 seek。
const int skipMinDeltaMs = 1500;

/// 数据源给出的**原始**段，尚未折算到本地片源的时间轴（对应安卓 `RawSegment`）。
///
/// 缓存里存的就是它：同一集换了线路（时长不同）能复用同一份缓存，折算推迟到
/// 读取时按当次时长做。
class RawSkipSegment {
  const RawSkipSegment({
    required this.kind,
    required this.provider,
    this.identity = '',
    this.versionId = '',
    this.startMs,
    this.endMs,
    this.referenceDurationMs = 0,
    this.confidence = 0.5,
    this.submissionCount = 0,
  });

  final SkipKind kind;

  /// 数据源 id（`introdb` / `theintrodb` / `todb`），也参与去重时的排序权重。
  final String provider;

  /// 数据源内部稳定身份；空则由 [SkipSegment] 按字段拼一个。
  final String identity;

  /// 同一来源中的播放版本；同版的片头、片中段和片尾必须一起选择。
  /// 空字符串表示来源未提供版本信息，不可仅凭参考时长拆成不同版本。
  final String versionId;

  final int? startMs;
  final int? endMs;

  /// 数据源标定所用版本的总时长；0 表示无从折算。
  final int referenceDurationMs;

  final double confidence;
  final int submissionCount;

  @override
  String toString() =>
      'RawSkipSegment(${kind.name}@$provider start=${startMs ?? 'null'} '
      'end=${endMs ?? 'null'} ref=$referenceDurationMs)';
}

/// 已折算到本地片源时间轴的段。
class SkipSegment {
  const SkipSegment({
    required this.kind,
    required this.provider,
    required this.identity,
    required this.startMs,
    required this.endMs,
    this.openEnded = false,
    this.confidence = 0.5,
    this.submissionCount = 0,
  });

  /// 用户手动标记的来源标识；与远端段同类型时手动的胜出。
  static const String manualProvider = 'manual';

  final SkipKind kind;
  final String provider;

  /// 稳定身份，用于「这段处理过了」的去重集合；不随本地时长折算变化。
  final String identity;

  final int startMs;
  final int endMs;

  /// 是否有界：为真表示这段一直延伸到文件结尾，没有可 seek 的落点。
  final bool openEnded;

  final double confidence;
  final int submissionCount;

  bool get isManual => provider == manualProvider;

  bool get isOpening => kind.isOpening;

  bool get isEnding => kind.isEnding;

  /// 同类段之间的优先级：有界段（能 seek 到确切位置）优先于无界段，其次比分数。
  double get score =>
      confidence * 100 + submissionCount * 2 + (provider == 'introdb' ? 1 : 0);

  bool betterThan(SkipSegment other) {
    if (openEnded != other.openEnded) return !openEnded;
    return score > other.score;
  }

  @override
  String toString() =>
      'SkipSegment(${kind.name}@$provider $startMs..$endMs'
      '${openEnded ? ' open' : ''})';
}

/// 一次判定得到的跳转动作。
class SkipPlanDecision {
  const SkipPlanDecision.none()
    : segment = null,
      targetMs = 0,
      openEnd = false,
      needsConfirm = false;

  const SkipPlanDecision._(
    this.segment,
    this.targetMs,
    this.openEnd,
    this.needsConfirm,
  );

  final SkipSegment? segment;
  final int targetMs;

  /// 为真表示这段一直放到文件结束：seek 到结尾等于「本集看完」，调用方要走
  /// 连播判定而不是当作普通 seek。
  final bool openEnd;

  /// 为真表示当前是 [SkipMode.confirm]，调用方要先问用户。
  final bool needsConfirm;

  bool get shouldSeek => segment != null;

  @override
  String toString() =>
      'SkipPlanDecision(${segment?.kind.name ?? 'none'} target=$targetMs '
      'openEnd=$openEnd confirm=$needsConfirm)';
}

/// 某一集的完整跳过计划（已按本地时长折算、去重、排序）。
class SkipPlan {
  const SkipPlan._(this.segments);

  /// 空计划。
  static const SkipPlan empty = SkipPlan._(<SkipSegment>[]);

  /// 按起点升序。
  final List<SkipSegment> segments;

  bool get isEmpty => segments.isEmpty;

  bool get isNotEmpty => segments.isNotEmpty;

  List<SkipSegment> get openings =>
      segments.where((s) => s.isOpening).toList(growable: false);

  List<SkipSegment> get endings =>
      segments.where((s) => s.isEnding).toList(growable: false);

  /// 把远端原始段折算到本地时间轴（安卓 `IntroSkipPlan.from`）。
  ///
  /// [durationMs] `<= 0` 表示时长未知：开头段仍可用（绝对时间戳），尾部段只能
  /// 沿用原始时间戳，因为无从做「距结尾」折算。
  static SkipPlan resolve(List<RawSkipSegment> raw, {required int durationMs}) {
    if (raw.isEmpty) return empty;
    final openings = <SkipSegment>[];
    final endings = <SkipSegment>[];
    for (final item in _preferClosestVersion(raw, durationMs)) {
      final segment = _resolveOne(item, durationMs);
      if (segment == null) continue;
      _addDeduped(segment.isEnding ? endings : openings, segment);
    }
    openings.sort((a, b) => a.startMs.compareTo(b.startMs));
    endings.sort((a, b) => a.startMs.compareTo(b.startMs));
    final all = <SkipSegment>[...openings, ...endings]
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    if (all.isEmpty) return empty;
    return SkipPlan._(List<SkipSegment>.unmodifiable(all));
  }

  /// 多版本按来源及显式版本一起选，不能按每段参考时长拆散片头、广告和片尾。
  /// 没有版本信息的标记仍按原规则处理；时长未知或两版同样接近时不猜选。
  static List<RawSkipSegment> _preferClosestVersion(
    List<RawSkipSegment> raw,
    int durationMs,
  ) {
    final kept = <RawSkipSegment>[];
    final byProvider = <String, Map<String, List<RawSkipSegment>>>{};
    for (final item in raw) {
      final version = item.versionId.trim();
      if (version.isEmpty) {
        kept.add(item);
        continue;
      }
      byProvider
          .putIfAbsent(item.provider, () => {})
          .putIfAbsent(version, () => [])
          .add(item);
    }
    for (final versions in byProvider.values) {
      final viable = [
        for (final group in versions.values)
          if (group.any((item) => _resolveOne(item, durationMs) != null)) group,
      ];
      if (viable.length == 1) {
        kept.addAll(viable.single);
        continue;
      }
      if (durationMs <= 0) continue;
      List<RawSkipSegment>? selected;
      int? closest;
      var ambiguous = false;
      for (final group in viable) {
        final references = {for (final item in group) item.referenceDurationMs};
        if (references.length != 1 || references.single <= 0) {
          // 还有一个可用版本无法比较时，不能声称其余版本是唯一最接近。
          selected = null;
          ambiguous = true;
          break;
        }
        final distance = (references.single - durationMs).abs();
        if (closest == null || distance < closest) {
          selected = group;
          closest = distance;
          ambiguous = false;
        } else if (distance == closest) {
          ambiguous = true;
        }
      }
      if (selected != null && !ambiguous) kept.addAll(selected);
    }
    return kept;
  }

  /// 叠上用户的手动标记（手动优先）。
  ///
  /// 只覆盖**同类型**：手动标了片头不代表用户否定了远端的回顾段，反之亦然。
  /// 片尾端点从 [SkipSegments.outroStartMs] 一直延伸到文件结尾，所以是 openEnded。
  SkipPlan withManualOverride({
    required SkipSegments manual,
    required int durationMs,
  }) {
    final introEnd = manual.introEndMs;
    final outroStart = manual.outroStartMs;
    if (introEnd == null && outroStart == null) return this;
    final result = <SkipSegment>[];
    for (final segment in segments) {
      if (introEnd != null && segment.kind == SkipKind.intro) continue;
      if (outroStart != null && segment.kind == SkipKind.outro) continue;
      result.add(segment);
    }
    if (introEnd != null && introEnd > 0) {
      result.add(
        SkipSegment(
          kind: SkipKind.intro,
          provider: SkipSegment.manualProvider,
          identity: 'manual|intro',
          startMs: 0,
          endMs: introEnd,
          confidence: 1,
        ),
      );
    }
    if (outroStart != null && outroStart > 0) {
      final bounded = durationMs > outroStart;
      result.add(
        SkipSegment(
          kind: SkipKind.outro,
          provider: SkipSegment.manualProvider,
          identity: 'manual|outro',
          startMs: outroStart,
          endMs: bounded ? durationMs : outroStart,
          openEnded: !bounded,
          confidence: 1,
        ),
      );
    }
    result.sort((a, b) => a.startMs.compareTo(b.startMs));
    return SkipPlan._(List<SkipSegment>.unmodifiable(result));
  }

  /// 判定此刻该不该跳、跳到哪（安卓 `IntroSkipPlayback` 的逐段判定）。
  ///
  /// [handled] 是「已经处理过的段身份」集合：调用方在处理完一段后把
  /// [SkipSegment.identity] 加进去，保证每段每集只自动处理一次——用户手动拖
  /// 回片头不会被再次跳走。
  ///
  /// [resumeMs] 是续播起点：起点已在某开头段结束之后的，视为用户已经越过它。
  SkipPlanDecision decide({
    required int positionMs,
    required int durationMs,
    required int kinds,
    required SkipMode mode,
    Set<String> handled = const <String>{},
    int resumeMs = 0,
  }) {
    if (mode == SkipMode.off) return const SkipPlanDecision.none();
    if (durationMs <= 0) return const SkipPlanDecision.none();
    if (segments.isEmpty) return const SkipPlanDecision.none();
    final position = positionMs < 0 ? 0 : positionMs;
    if (position >= durationMs) return const SkipPlanDecision.none();
    final needsConfirm = mode == SkipMode.confirm;

    for (final segment in segments) {
      if ((kinds & segment.kind.bit) == 0) continue;
      if (handled.contains(segment.identity)) continue;

      final int target;
      if (segment.kind.usesAbsoluteTimeline) {
        // 开头段与片中段：位置必须落在段内，跳向段末。
        if (resumeMs >= segment.endMs) continue;
        if (position < segment.startMs || position >= segment.endMs) continue;
        target = segment.endMs;
      } else {
        if (position < segment.startMs) continue;
        target = segment.openEnded ? durationMs : segment.endMs;
      }
      if (target <= position || target - position < skipMinDeltaMs) continue;
      return SkipPlanDecision._(
        segment,
        target,
        segment.isEnding && target >= durationMs,
        needsConfirm,
      );
    }
    return const SkipPlanDecision.none();
  }

  @override
  String toString() =>
      'SkipPlan(${segments.length} segments: ${segments.join(', ')})';

  // --- 逐段折算 -------------------------------------------------------------

  static SkipSegment? _resolveOne(RawSkipSegment raw, int durationMs) {
    final trailing = raw.kind.isEnding;
    var start = raw.startMs ?? (trailing ? -1 : 0);
    var end = raw.endMs ?? -1;
    if (start < 0) return null;
    if (trailing) return _resolveTrailing(raw, start, end, durationMs);
    if (durationMs > 0) {
      if (start >= durationMs) return null;
      if (end > durationMs) end = durationMs;
    }
    if (end <= start) return null;
    return SkipSegment(
      kind: raw.kind,
      provider: raw.provider,
      identity: _identityOf(raw),
      startMs: start,
      endMs: end,
      confidence: raw.confidence < 0 ? 0 : raw.confidence,
      submissionCount: raw.submissionCount < 0 ? 0 : raw.submissionCount,
    );
  }

  /// 尾部段按「距文件结尾的偏移」理解，而不是照抄绝对时间戳。
  ///
  /// 片源普遍存在掐头、贴片、删减，与数据源标定的参考版本时长对不上；此时绝对
  /// 时间戳整体漂移，但「距结尾还有多久」基本稳定，按该距离折算才能对上本地时间轴。
  static SkipSegment? _resolveTrailing(
    RawSkipSegment raw,
    int start,
    int end,
    int durationMs,
  ) {
    final reference = _plausibleReference(raw.referenceDurationMs, durationMs);
    if (reference > 0 &&
        end > reference &&
        end - reference > skipOpenEndToleranceMs) {
      return null;
    }
    final missingEnd = end < 0;
    final openEnded =
        reference > 0 &&
        (missingEnd ||
            (reference >= end && reference - end <= skipOpenEndToleranceMs));
    if (reference > 0 &&
        durationMs > 0 &&
        !_withinDistance(reference, durationMs, skipTimeBaseToleranceMs)) {
      final shift = durationMs - reference;
      final shiftedStart = _safeAdd(start, shift);
      if (shiftedStart == null) return null;
      start = shiftedStart;
      if (end >= 0) {
        final shiftedEnd = _safeAdd(end, shift);
        if (shiftedEnd == null) return null;
        end = shiftedEnd;
      }
    }
    if (durationMs > 0) {
      if (missingEnd || openEnded || end > durationMs) end = durationMs;
      if (start >= durationMs) return null;
    }
    // 尾部段不可能从 0 开始，整集当片尾必是错配。
    if (start <= 0) return null;
    if (end >= 0 && end <= start) return null;
    return SkipSegment(
      kind: raw.kind,
      provider: raw.provider,
      identity: _identityOf(raw),
      startMs: start,
      endMs: end < 0 ? start : end,
      openEnded: openEnded,
      confidence: raw.confidence < 0 ? 0 : raw.confidence,
      submissionCount: raw.submissionCount < 0 ? 0 : raw.submissionCount,
    );
  }

  /// 参考时长与本集时长必须足够接近，否则视为对不上同一版本，放弃折算。
  ///
  /// 折算是整段平移：差到分钟数十倍（合并版、跨版本错配）时平移量本身就比片尾
  /// 还长，算出来的落点落在正片里，跳过去等于把正片当片尾扔掉。
  static int _plausibleReference(int reference, int durationMs) {
    if (reference <= 0) return 0;
    if (durationMs <= 0) return reference;
    return _withinDistance(reference, durationMs, skipMaxTimeBaseDriftMs)
        ? reference
        : 0;
  }

  static bool _withinDistance(int left, int right, int tolerance) {
    if (tolerance < 0) return false;
    final distance = left >= right ? left - right : right - left;
    return distance >= 0 && distance <= tolerance;
  }

  /// 回绕检测：Dart 的 int 在 VM 上是 64 位，溢出会静默回绕，必须自己拦。
  static int? _safeAdd(int value, int delta) {
    final result = value + delta;
    if (delta > 0 && result < value) return null;
    if (delta < 0 && result > value) return null;
    return result;
  }

  static String _identityOf(RawSkipSegment raw) {
    final given = raw.identity.trim();
    if (given.isNotEmpty) return given;
    return '${raw.kind.name}|${raw.provider}|'
        '${raw.startMs ?? 'null'}|${raw.endMs ?? 'null'}';
  }

  static void _addDeduped(List<SkipSegment> segments, SkipSegment segment) {
    for (var i = 0; i < segments.length; i++) {
      final existing = segments[i];
      if (!_overlaps(existing, segment)) continue;
      if (existing.openEnded &&
          segment.openEnded &&
          existing.kind == segment.kind &&
          existing.startMs != segment.startMs) {
        if (segment.startMs > existing.startMs) segments[i] = segment;
      } else if (segment.betterThan(existing)) {
        segments[i] = segment;
      }
      return;
    }
    segments.add(segment);
  }

  /// 两家对同一段的标注常不一致（一家算回顾、另一家算片头），不合并会对同一段
  /// 连跳两次。开头与尾部之间不并——它们物理上相隔整集。
  static bool _overlaps(SkipSegment a, SkipSegment b) {
    if (a.kind.dedupeGroup != b.kind.dedupeGroup) return false;
    if (a.isEnding && a.kind != b.kind) return false;
    // 无界段的 end 已被拉到文件结尾，拿它算重叠会把紧随其后的段整个吞掉
    //（片尾吞预告）。这种情况只按起点判断。
    if (a.openEnded && b.openEnded && a.kind == b.kind) {
      // 两家各自给「一直放到文件末尾」的同一类结尾（片尾对片尾），起点不同也
      // 描述同一个结尾：并存会画出两条同色带。只取更晚的起点——少跳更安全。
      // 不同类型（片尾 vs 彩蛋）语义不同，仍按原规则判定。
      return true;
    }
    if (a.openEnded || b.openEnded) {
      return _withinDistance(a.startMs, b.startMs, skipSameStartToleranceMs);
    }
    if (_withinDistance(a.startMs, b.startMs, skipSameStartToleranceMs) &&
        _withinDistance(a.endMs, b.endMs, 5000)) {
      return true;
    }
    final overlap =
        (a.endMs < b.endMs ? a.endMs : b.endMs) -
        (a.startMs > b.startMs ? a.startMs : b.startMs);
    if (overlap <= 0) return false;
    final aSpan = a.endMs - a.startMs;
    final bSpan = b.endMs - b.startMs;
    final shorter = aSpan < bSpan ? aSpan : bSpan;
    return shorter > 0 && overlap * 10 >= shorter * 6;
  }
}

/// 数据源位（对齐安卓 `IntroSkipService` 的两家 + TODB PlayBack）。
abstract final class SkipSourceBits {
  static const int introdb = 1;
  static const int theintrodb = 1 << 1;
  static const int todb = 1 << 2;

  /// 出厂默认启用的源；当前恰好等于「全部已知源」。
  static const int defaults = introdb | theintrodb | todb;

  /// 全部已知源位——**夹取上界应当用这个，不是 [defaults]**。
  ///
  /// 两者今天等值，但语义不同：新增第 4 个源时只更新 [allBits] 与 [ids]，
  /// 不要把 [defaults] 跟着放大（那等于未经用户同意就默认启用新源）。
  static const int allBits = introdb | theintrodb | todb;

  static const int none = 0;

  /// 全部已知源的 id（顺序即设置页展示顺序）。
  static const List<String> ids = <String>['introdb', 'theintrodb', 'todb'];

  /// 兼容别名：语义同 [ids]。
  static const List<String> all = ids;

  static int bitOf(String id) => switch (id) {
    'introdb' => introdb,
    'theintrodb' => theintrodb,
    'todb' => todb,
    _ => 0,
  };

  static bool enabled(int sources, String id) => (sources & bitOf(id)) != 0;
}

/// 一次远端查询的身份条件（安卓 `IntroSkipService.Query` 的 Dart 版）。
///
/// **缓存键只含剧集身份、不含时长**：时长不是查询条件（IntroDB 压根不收，
/// TheIntroDB 可选），进了键就意味着同一集在时长未知与已知时各发一轮请求，
/// HLS 时长抖动也会穿透缓存。
class SkipQuery {
  const SkipQuery({
    this.tmdbId = 0,
    this.imdbId = '',
    this.mediaType = '',
    this.season = 0,
    this.episode = 0,
    this.durationMs = 0,
  });

  final int tmdbId;
  final String imdbId;
  final String mediaType;
  final int season;
  final int episode;
  final int durationMs;

  bool get isTv => mediaType == 'tv' || season > 0 || episode > 0;

  /// IntroDB 只收 IMDb 键，且必须带季集号。
  bool get hasImdbEpisode =>
      imdbId.trim().isNotEmpty && season > 0 && episode > 0;

  bool get hasTmdb => tmdbId > 0;

  /// 没有任何可用查询条件：不是失败，是确定的「查不了」。
  bool get canLookup => hasTmdb || hasImdbEpisode;

  String get cacheKey => '$tmdbId|${imdbId.trim()}|$mediaType|$season|$episode';

  @override
  String toString() =>
      'SkipQuery(tmdb=$tmdbId imdb=$imdbId $mediaType '
      'S${season}E$episode duration=$durationMs)';
}
