/// 启发式 m3u8 清洗：依据仓库 reference/win-box-borrowings.md §4.4，独立实现五级策略。
/// 未直接核对 TVBox / Win-box 源码，不声称是已验证的源码移植。
///
/// 定位：**用户规则一条都没命中时**的兜底。默认关闭——启发式清洗天生会误删，
/// 若默认打开，「用户没开广告过滤却少了一段正片」会变成默认体验（Win-box 刻意默认关）。
/// 调用口径：只有 `removedSegments > 0` 才允许使用返回的文本。
///
/// 本文件有意不 import `core/ad_rules.dart`：两者互不依赖，才能单独回滚这个开关。
///
/// # 五级链（顺序即优先级，逐级作用在上一级的结果上）
///
/// 1. `removeMinorityUrl`：按分片 URL 的「主机 + 目录前缀」统计主导者，删少数派。
///    误删场景：多 CDN 边缘节点会给同一部片的不同分片不同主机/目录，CDN 切换的清单会被
///    当成广告。因此额外要求主导者**过半**，否则整级不动。
/// 2. `clean`：两条内置的「DISCONTINUITY/EXTINF 特征」通用正则（不读任何外部规则文件）：
///    两道 `#EXT-X-DISCONTINUITY` 之间只剩一段的缝合点（正则整段匹配）、0 时长分片。
///    误删场景：正片里合法插入的一段花絮/角标；所以缝合点只在时长 ≤ 30s 时才算数。
/// 3. `cleanCommonAdMarkers`：SCTE-35 标记段、`#EXT-X-CUE-OUT`~`#EXT-X-CUE-IN`
///    广告块、带广告属性的 `#EXT-X-DATERANGE`、URL 里带广告词的段。
///    误删场景：URL 里出现 `ad`/`midroll` 等词的正常素材；SCTE-35 也可能标在正片点位上。
/// 4. `cleanDecimalPrecisionGroups` / `cleanFrameRateGroups`：短的非主导不连续组里，
///    时长精度/帧率特征和正片不一致的块——时长 3 位小数且完全一致（同一广告切片），
///    或时长在 ±1 帧（≈42ms）内摆动（逐帧重切）。误删场景：正片本身就按 3 位小数切片，
///    或 B 帧重编码让整条清单的时长抖动，所以只在「短 + 非主导」的组里生效。
/// 5. `cleanDiscontinuityGroups`：删非主导的短不连续组（≤4 段且 ≤60s）。最激进的一级，
///    误删场景：正片里合法的短章节/预告，因此它排在最后，且受下面三道保护约束。
///
/// # 三道回退保护（这个功能唯一的安全阀）
///
/// - 单级删除超过该级输入总段数 30% → 该级作废，保留上一级结果；
/// - 累计删除超过原清单总段数 50% → 整体回退，原样返回原文；
/// - 结果不满足「可播放媒体清单」（须有分片、不得连续两个 EXTINF、不得 EXTINF 紧跟
///   ENDLIST、不得有非 URL 的结构破坏）→ 整体回退。
///
/// 任何一级都没删到东西时，必须原样返回原文（不得返回「等价但不是同一份」的文本）。
///
/// # 硬边界
///
/// 只处理**点播**媒体清单：含 `#EXT-X-BYTERANGE`、缺 `#EXT-X-ENDLIST`、
/// 含 `#EXT-X-PART`/`#EXT-X-SKIP`/`#EXT-X-PRELOAD-HINT`、不以 `#EXTM3U` 开头的
/// 一律原样返回并给出 `abandonReason`（这些清单的分片位置由别的字段共同决定，
/// 删一段就得重算全部兄弟字段，收益远小于风险）。
///
/// # 幂等
///
/// 默认最多 [kPurifyMaxPasses] 轮完整五级链，之后必须确认所有级都不能再删：只跑一遍时，
/// 删掉一个短不连续组会让另一个组变成新的少数派，于是下一次调用还会继续删——
/// 代理每次请求都重洗一遍就会把清单越洗越短。达到轮数上限后仍须验证固定点，
/// 任何一级仍能通过 30% 阀删段就整体回退，不能把轮数上限当成收敛证明。
/// KEY 缺显式 IV、任何 MAP，以及被删段携带语义不明标签时也整体回退；
/// DEFINE / KEY 与不连续边界保留，GAP 不挪到正片段上。
///
/// 纯逻辑：无网络、无文件、无 Flutter 依赖，可用固定样本穷举。
library;

/// 单级删除比例上限：超过该级输入总段数的 30% 就整级作废。
const double kPurifyLevelRemovalRatio = 0.30;

/// 累计删除比例上限：超过原清单总段数的 50% 就整体回退。
const double kPurifyTotalRemovalRatio = 0.50;

/// 清单体积上限（字符）：超过就别逐行分析了。
const int kPurifyMaxManifestChars = 2 * 1024 * 1024;

/// 保守地只运行一轮，若仍有可接受的删除则回退，不交付半收敛结果。
const int kPurifyMaxPasses = 1;

/// 短不连续组的段数上限。
const int kPurifyShortGroupMaxSegments = 4;

/// 短不连续组的时长上限（秒）。
const double kPurifyShortGroupMaxDurationSec = 60;

/// 两道 DISCONTINUITY 之间的单段被视为插播缝合点的时长上限（秒）。
const double kPurifyIsolatedMaxDurationSec = 30;

/// 一帧的时长上限（秒）：23.976fps 时约 41.7ms。
const double kPurifyFrameMaxSpreadSec = 0.042;

/// 正片 EXTINF 的常见小数精度上限：超过它说明这一段是别的源切出来的。
const int kPurifyDominantPrecisionMax = 1;

/// 各级在 `levelCounts` 里的键名（代理的日志直接用它）。
const String kPurifyLevelMinorityUrl = 'removeMinorityUrl';
const String kPurifyLevelClean = 'clean';
const String kPurifyLevelCommonAdMarkers = 'cleanCommonAdMarkers';
const String kPurifyLevelDecimalPrecisionGroups = 'cleanDecimalPrecisionGroups';
const String kPurifyLevelFrameRateGroups = 'cleanFrameRateGroups';
const String kPurifyLevelDiscontinuityGroups = 'cleanDiscontinuityGroups';

/// 各级命中数压成一行日志：按次数降序、同级按名字排序；没有命中返回空串。
///
/// 为什么要有它：`adBlockRemoved=N heuristic` 只说「删了几段」，说不出是哪一级删的——
/// 五级的误删风险差别很大，排查时必须能一眼看到。
String purifyLevelsSummary(Map<String, int> levelCounts) {
  final entries =
      <MapEntry<String, int>>[
        for (final entry in levelCounts.entries)
          if (entry.value > 0) entry,
      ]..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
  return entries.map((entry) => '${entry.key}=${entry.value}').join(',');
}

/// 启发式清洗结果。字段语义与 `HlsCleanResult` 对齐，但本文件不依赖它。
class PurifyOutcome {
  const PurifyOutcome({
    required this.text,
    this.removedSegments = 0,
    this.removedDurationSec = 0,
    this.levelCounts = const {},
    this.removed = const [],
    this.abandonReason,
  });

  final String text;

  /// 被删掉的分片数（各级之和）。
  final int removedSegments;

  /// 被删分片的 `#EXTINF` 时长合计（秒）。
  final double removedDurationSec;

  /// 每一级删了几段（键见 [kPurifyLevelMinorityUrl] 等常量）。
  final Map<String, int> levelCounts;

  /// 删除明细只存主机，不存完整 URL；时间与序号始终属于原始清单。
  final List<PurifyRemovedSegment> removed;

  /// 安全回退的原因；非空时 [text] 一定是原文。
  final String? abandonReason;

  bool get changed => removedSegments > 0;

  bool get abandoned => abandonReason != null;

  @override
  String toString() =>
      'PurifyOutcome(removed=$removedSegments, abandoned=$abandonReason)';
}

/// 单个被删分片的原始时间线信息；字段不可变，不含完整 URL。
class PurifyRemovedSegment {
  const PurifyRemovedSegment({
    required this.host,
    required this.ruleId,
    required this.startSeconds,
    required this.durationSec,
    required this.originalIndex,
  });

  final String host;
  final String ruleId;
  final double startSeconds;
  final double durationSec;
  final int originalIndex;
}

/// 清洗一个点播 HLS 媒体清单：在没有任何用户规则命中的情况下，用启发式规则兜底删广告。
PurifyOutcome purifyM3u8Playlist({
  required String text,
  required Uri playlistUri,
}) {
  if (text.isEmpty) return _abandon(text, '清单为空');
  // 带 BOM 的清单同样可播：只在分析时去掉，回写时按原样补回。
  final bom = text.startsWith('\uFEFF') ? '\uFEFF' : '';
  final body = bom.isEmpty ? text : text.substring(1);
  if (!body.trimLeft().startsWith('#EXTM3U')) {
    return _abandon(text, '不是 M3U8 清单（缺少 #EXTM3U）');
  }
  if (body.length > kPurifyMaxManifestChars) {
    return _abandon(text, '清单超过 2MB 上限');
  }
  final lines = _splitLines(body);
  for (final line in lines) {
    final upper = line.trim().toUpperCase();
    if (upper.startsWith('#EXT-X-MAP')) {
      return _abandon(text, 'EXT-X-MAP 初始化绑定无法安全重算');
    }
    if (upper.startsWith('#EXT-X-KEY:')) {
      final attrs = _attributes(line);
      final method = attrs['METHOD']?.toUpperCase();
      if (method == null ||
          method.isEmpty ||
          (method != 'NONE' && !(attrs['IV']?.isNotEmpty ?? false))) {
        return _abandon(text, '加密 KEY 的隐式 IV 依赖原媒体序号');
      }
    }
    if (upper.startsWith('#EXT-X-BYTERANGE')) {
      return _abandon(text, '含 #EXT-X-BYTERANGE：分片偏移依赖前段，不做启发式删除');
    }
    if (upper.startsWith('#EXT-X-PART') ||
        upper.startsWith('#EXT-X-SKIP') ||
        upper.startsWith('#EXT-X-PRELOAD-HINT')) {
      return _abandon(text, '低延迟 HLS（PART/SKIP/PRELOAD-HINT），不做启发式删除');
    }
  }
  if (!lines.any((line) => line.trim().toUpperCase() == '#EXT-X-ENDLIST')) {
    return _abandon(text, '不是点播清单（缺少 #EXT-X-ENDLIST），只清洗已完结的媒体清单');
  }

  if (!_isPlayableMediaPlaylist(body, playlistUri: playlistUri)) {
    return _abandon(text, '原清单不是可播放媒体清单，时间线或 URI 损坏');
  }
  var current = _Manifest.parse(lines);
  if (current.segments.isEmpty) return _abandon(text, '清单里没有分片');

  final originalSegments = current.segments.length;
  var currentText = body;
  var totalRemoved = 0;
  var removedDurationSec = 0.0;
  final levelCounts = <String, int>{};
  final details = <PurifyRemovedSegment>[];

  for (var pass = 0; pass < kPurifyMaxPasses; pass++) {
    var passRemoved = 0;
    for (final stage in _purifyStages) {
      final inputSegments = current.segments.length;
      if (inputSegments == 0) break;
      final removed = stage.select(current, playlistUri);
      if (removed.isEmpty) continue;
      // 第一道保护：一级删得太狠，说明这一级的判据和这条清单不匹配。
      if (removed.length > inputSegments * kPurifyLevelRemovalRatio) continue;
      final ambiguous = current.ambiguousRemovalTag(removed);
      if (ambiguous != null) {
        return _abandon(text, '$ambiguous 标签语义不明确，不能移到正片或丢弃');
      }
      final candidate = current.render(removed);
      // 第二道保护：多级叠加后的总量仍然不能超过原清单的一半。
      if (totalRemoved + removed.length >
          originalSegments * kPurifyTotalRemovalRatio) {
        return _abandon(text, '累计删除超过原清单 50%');
      }
      // 第三道保护：洗完必须还是能播的媒体清单。
      if (!_isPlayableMediaPlaylist(candidate)) {
        return _abandon(text, '清洗后不是可播放的媒体清单');
      }
      for (final index in removed.toList()..sort()) {
        final segment = current.segments[index];
        details.add(
          PurifyRemovedSegment(
            host: playlistUri.resolve(segment.uri).host.toLowerCase(),
            ruleId: stage.name,
            startSeconds: segment.startSeconds,
            durationSec: segment.duration ?? 0,
            originalIndex: segment.originalIndex,
          ),
        );
      }
      removedDurationSec += current.durationOf(removed);
      totalRemoved += removed.length;
      passRemoved += removed.length;
      levelCounts[stage.name] = (levelCounts[stage.name] ?? 0) + removed.length;
      currentText = candidate;
      current = _Manifest.parse(
        _splitLines(candidate),
        originals: [
          for (var i = 0; i < current.segments.length; i++)
            if (!removed.contains(i)) current.segments[i],
        ],
      );
    }
    if (passRemoved == 0) break;
  }

  for (final stage in _purifyStages) {
    final remaining = stage.select(current, playlistUri);
    if (remaining.isNotEmpty &&
        remaining.length <=
            current.segments.length * kPurifyLevelRemovalRatio) {
      return _abandon(text, '达到清洗轮数上限但未建立固定点');
    }
  }
  if (totalRemoved == 0) return PurifyOutcome(text: text);
  details.sort((a, b) => a.originalIndex.compareTo(b.originalIndex));
  return PurifyOutcome(
    text: '$bom$currentText',
    removedSegments: totalRemoved,
    removedDurationSec: removedDurationSec,
    levelCounts: Map<String, int>.unmodifiable(levelCounts),
    removed: List<PurifyRemovedSegment>.unmodifiable(details),
  );
}

PurifyOutcome _abandon(String text, String reason) =>
    PurifyOutcome(text: text, abandonReason: reason);

List<String> _splitLines(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

Map<String, String> _attributes(String line) => {
  for (final match in RegExp(
    r'([A-Za-z0-9-]+)=("[^"]*"|[^,]*)',
  ).allMatches(line))
    match[1]!.toUpperCase(): match[2]!.replaceAll('"', '').trim(),
};

bool _isAdMarkerTag(String upper) =>
    upper.startsWith('#EXT-X-CUE-') ||
    upper.startsWith('#EXT-X-SCTE35:') ||
    upper.startsWith('#EXT-OATCLS-SCTE35:') ||
    (upper.startsWith('#EXT-X-DATERANGE:') && _hasAdDaterange([upper]));

bool _isSegmentTag(String line) {
  final upper = line.trim().toUpperCase();
  return upper == '#EXT-X-DISCONTINUITY' ||
      upper == '#EXT-X-GAP' ||
      upper.startsWith('#EXT-X-DATERANGE:') ||
      _isAdMarkerTag(upper);
}

/// 一道清洗级：给定当前清单，返回要删掉的分片下标。
class _Stage {
  const _Stage(this.name, this.select);

  final String name;
  final Set<int> Function(_Manifest manifest, Uri playlistUri) select;
}

const List<_Stage> _purifyStages = <_Stage>[
  _Stage(kPurifyLevelMinorityUrl, _removeMinorityUrl),
  _Stage(kPurifyLevelClean, _cleanGeneric),
  _Stage(kPurifyLevelCommonAdMarkers, _cleanCommonAdMarkers),
  _Stage(kPurifyLevelDecimalPrecisionGroups, _cleanDecimalPrecisionGroups),
  _Stage(kPurifyLevelFrameRateGroups, _cleanFrameRateGroups),
  _Stage(kPurifyLevelDiscontinuityGroups, _cleanDiscontinuityGroups),
];

/// 一个分片：它自己的 URI 行，加上紧挨在它前面的标签行。
class _Seg {
  _Seg({
    required this.tags,
    required this.uri,
    required this.originalIndex,
    required this.startSeconds,
  });

  final List<String> tags;
  final String uri;
  final int originalIndex;
  final double startSeconds;

  List<String> get upperTags => <String>[
    for (final tag in tags) tag.trim().toUpperCase(),
  ];

  bool get discontinuity => upperTags.contains('#EXT-X-DISCONTINUITY');

  double? get duration {
    for (var i = tags.length - 1; i >= 0; i--) {
      final line = tags[i].trim();
      if (line.toUpperCase().startsWith('#EXTINF:')) {
        final value = line.substring('#EXTINF:'.length).split(',').first.trim();
        return double.tryParse(value);
      }
    }
    return null;
  }
}

/// 解析后的清单：头部标签、分片块、尾部标签（例如 `#EXT-X-ENDLIST`）。
class _Manifest {
  _Manifest({
    required this.header,
    required this.segments,
    required this.trailing,
  });

  final List<String> header;
  final List<_Seg> segments;
  final List<String> trailing;

  /// 头部 = 第一个 `#EXTINF` 之前的行。这样删掉首段时不会把 `#EXTM3U` 一起删掉。
  static _Manifest parse(List<String> lines, {List<_Seg>? originals}) {
    var firstUri = lines.length;
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      firstUri = i;
      break;
    }
    var headerEnd = firstUri;
    for (var i = 0; i < firstUri; i++) {
      if (lines[i].trim().toUpperCase().startsWith('#EXTINF:') ||
          _isSegmentTag(lines[i])) {
        headerEnd = i;
        break;
      }
    }
    final segments = <_Seg>[];
    final pending = <String>[];
    var startSeconds = 0.0;
    for (var i = headerEnd; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        pending.add(line);
        continue;
      }
      final index = segments.length;
      final original = originals == null ? null : originals[index];
      final segment = _Seg(
        tags: List<String>.of(pending),
        uri: trimmed,
        originalIndex: original?.originalIndex ?? index,
        startSeconds: original?.startSeconds ?? startSeconds,
      );
      segments.add(segment);
      startSeconds += segment.duration ?? 0;
      pending.clear();
    }
    return _Manifest(
      header: lines.sublist(0, headerEnd),
      segments: segments,
      trailing: pending,
    );
  }

  String render(Set<int> removed) {
    final out = <String>[...header];
    final carry = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (removed.contains(i)) {
        for (final line in segment.tags) {
          final upper = line.trim().toUpperCase();
          // 持续生效标签与边界必须跨过被删分片；未知标签已在选择后整体回退。
          if (upper.startsWith('#EXT-X-KEY:') ||
              upper.startsWith('#EXT-X-DEFINE:') ||
              upper == '#EXT-X-DISCONTINUITY') {
            carry.add(line);
          }
        }
        continue;
      }
      out.addAll(carry);
      carry.clear();
      out.addAll(segment.tags);
      out.add(segment.uri);
    }
    out.addAll(carry);
    out.addAll(trailing);
    if (removed.isEmpty) return out.join('\n');
    // 删掉被两道 DISCONTINUITY 夹住的段之后会留下相邻的重复标记，收成一个。
    return _collapseDiscontinuities(out).join('\n');
  }

  String? ambiguousRemovalTag(Set<int> removed) {
    for (final index in removed) {
      for (final line in segments[index].tags) {
        final tag = line.trim().toUpperCase();
        if (tag.isEmpty) continue;
        if (tag.startsWith('#EXTINF:') ||
            tag.startsWith('#EXT-X-KEY:') ||
            tag.startsWith('#EXT-X-DEFINE:') ||
            tag == '#EXT-X-DISCONTINUITY' ||
            _isAdMarkerTag(tag)) {
          continue;
        }
        return tag.split(':').first;
      }
    }
    return null;
  }

  double durationOf(Set<int> indices) {
    var total = 0.0;
    for (final index in indices) {
      total += segments[index].duration ?? 0;
    }
    return total;
  }
}

List<String> _collapseDiscontinuities(List<String> lines) {
  final out = <String>[];
  for (final line in lines) {
    final upper = line.trim().toUpperCase();
    if (upper == '#EXT-X-DISCONTINUITY' &&
        out.isNotEmpty &&
        out.last.trim().toUpperCase() == '#EXT-X-DISCONTINUITY') {
      continue;
    }
    out.add(line);
  }
  return out;
}

/// 不连续组：段与段之间出现 `#EXT-X-DISCONTINUITY` 就切开。
class _Group {
  const _Group(this.start, this.length);

  final int start;
  final int length;

  Iterable<int> get indices => Iterable<int>.generate(length, (i) => start + i);
}

List<_Group> _groups(List<_Seg> segments) {
  final groups = <_Group>[];
  var start = 0;
  var length = 0;
  for (var i = 0; i < segments.length; i++) {
    if (i > 0 && segments[i].discontinuity) {
      groups.add(_Group(start, length));
      start = i;
      length = 0;
    }
    length++;
  }
  if (length > 0) groups.add(_Group(start, length));
  return groups;
}

double _groupDuration(_Manifest manifest, _Group group) {
  var total = 0.0;
  for (final index in group.indices) {
    total += manifest.segments[index].duration ?? 0;
  }
  return total;
}

/// 主导组：段数最多；段数相同比总时长，再相同取靠前者（保证纯函数可复现）。
_Group _dominantGroup(_Manifest manifest, List<_Group> groups) {
  var best = groups.first;
  var bestDuration = _groupDuration(manifest, best);
  for (final group in groups.skip(1)) {
    final duration = _groupDuration(manifest, group);
    if (group.length > best.length ||
        (group.length == best.length && duration > bestDuration)) {
      best = group;
      bestDuration = duration;
    }
  }
  return best;
}

bool _isMinorShortGroup(_Manifest manifest, _Group group, _Group dominant) {
  if (group.length > kPurifyShortGroupMaxSegments) return false;
  if (_groupDuration(manifest, group) > kPurifyShortGroupMaxDurationSec) {
    return false;
  }
  return group.length * 2 <= dominant.length;
}

String _segmentText(_Seg segment) =>
    <String>[...segment.tags, segment.uri].join('\n');

String _groupText(_Manifest manifest, _Group group) => group.indices
    .map((index) => _segmentText(manifest.segments[index]))
    .join('\n');

int _decimalPrecision(double value) {
  final text = value.toString();
  final dot = text.indexOf('.');
  if (dot < 0) return 0;
  return text.length - dot - 1;
}

int _typicalPrecision(List<double?> values) {
  final counts = <int, int>{};
  for (final value in values) {
    if (value == null) continue;
    final precision = _decimalPrecision(value);
    counts[precision] = (counts[precision] ?? 0) + 1;
  }
  if (counts.isEmpty) return 99;
  var best = 0;
  var bestCount = 0;
  for (final entry in counts.entries) {
    if (entry.value > bestCount ||
        (entry.value == bestCount && entry.key > best)) {
      best = entry.key;
      bestCount = entry.value;
    }
  }
  return best;
}

List<double?> _durationsOf(_Manifest manifest, Iterable<int> indices) =>
    <double?>[for (final index in indices) manifest.segments[index].duration];

/// 第 1 级：按「主机 + 目录前缀」找主导者，删少数派。
///
/// 只有 URL 可解析、主导者过半、且确实存在少数派时才动手——多 CDN 清单在两份地址间
/// 五五开时不动，宁可漏删也不误删。
Set<int> _removeMinorityUrl(_Manifest manifest, Uri playlistUri) {
  final segments = manifest.segments;
  if (segments.length < 3) return const <int>{};
  final buckets = <String, List<int>>{};
  for (var i = 0; i < segments.length; i++) {
    final key = _urlKey(segments[i].uri, playlistUri);
    if (key == null) continue;
    (buckets[key] ??= <int>[]).add(i);
  }
  if (buckets.length < 2) return const <int>{};
  var dominantKey = '';
  var dominantCount = 0;
  for (final entry in buckets.entries) {
    if (entry.value.length > dominantCount ||
        (entry.value.length == dominantCount &&
            dominantKey.isNotEmpty &&
            entry.key.compareTo(dominantKey) < 0)) {
      dominantKey = entry.key;
      dominantCount = entry.value.length;
    }
  }
  // 没有真正的主导者：这更像多线路混排，而不是「正片 + 插播」。
  if (dominantCount * 2 <= segments.length) return const <int>{};
  final removed = <int>{};
  for (final entry in buckets.entries) {
    if (entry.key != dominantKey) removed.addAll(entry.value);
  }
  if (removed.isEmpty || removed.length >= segments.length) {
    return const <int>{};
  }
  return removed;
}

String? _urlKey(String uri, Uri playlistUri) {
  final Uri resolved;
  try {
    resolved = playlistUri.resolve(uri);
  } catch (_) {
    return null;
  }
  final host = resolved.host.toLowerCase();
  final path = resolved.path;
  final cut = path.lastIndexOf('/');
  final dir = cut < 0 ? '' : path.substring(0, cut + 1);
  if (host.isEmpty && dir.isEmpty) return null;
  return '$host$dir';
}

/// 第 2 级：带 DISCONTINUITY/EXTINF 特征的通用正则，整段删。
///
/// 只认两种形态：被两道 DISCONTINUITY 夹住的单段（插播缝合点），以及 0 时长分片。
/// 不做任何按关键词猜分片的事——那属于第 3 级。
Set<int> _cleanGeneric(_Manifest manifest, Uri playlistUri) {
  final removed = <int>{};
  for (final group in _groups(manifest.segments)) {
    final match = _splicedInsertPattern.firstMatch(_groupText(manifest, group));
    if (match != null) {
      final duration = double.tryParse(match.group(1) ?? '');
      if (duration != null && duration <= kPurifyIsolatedMaxDurationSec) {
        removed.addAll(group.indices);
        continue;
      }
    }
    for (final index in group.indices) {
      if (_zeroDurationPattern.hasMatch(
        _segmentText(manifest.segments[index]),
      )) {
        removed.add(index);
      }
    }
  }
  return removed;
}

/// `#EXT-X-DISCONTINUITY` + 标签 + 一段 `#EXTINF` + URI，且到此是块尾——
/// 也就是「这一组里只有一段」。两段以上的组不会命中（第二段 URI 之后不是块尾）。
final RegExp _splicedInsertPattern = RegExp(
  r'^#EXT-X-DISCONTINUITY[^\n]*\n'
  r'(?:#[^\n]*\n)*'
  r'#EXTINF:([0-9.]+),[^\n]*\n'
  r'[^#\s][^\n]*\s*$',
);

/// 0 时长分片：既播不出来，也不是正片。
final RegExp _zeroDurationPattern = RegExp(r'#EXTINF:0(?:\.0+)?,');

/// 第 3 级：广告标记块。
///
/// CUE-OUT~CUE-IN 是标准的广告插入区间，命中即整块删；SCTE-35 标记段与带广告属性的
/// DATERANGE 只删它自己所属的那段（标记也可能被别的工具贴在正片点位上）。
Set<int> _cleanCommonAdMarkers(_Manifest manifest, Uri playlistUri) {
  final removed = <int>{};
  var inCueRun = false;
  for (var i = 0; i < manifest.segments.length; i++) {
    final segment = manifest.segments[i];
    final tags = segment.upperTags;
    final cueOut = tags.any(
      (tag) => tag.startsWith('#EXT-X-CUE-OUT:') || tag == '#EXT-X-CUE-OUT',
    );
    final cueOutCont = tags.any((tag) => tag.startsWith('#EXT-X-CUE-OUT-CONT'));
    final cueIn = tags.any((tag) => tag.startsWith('#EXT-X-CUE-IN'));
    final scte = tags.any(
      (tag) =>
          tag.startsWith('#EXT-X-SCTE35:') ||
          tag.startsWith('#EXT-OATCLS-SCTE35:'),
    );
    if (inCueRun) {
      removed.add(i);
      if (cueIn) inCueRun = false;
      continue;
    }
    if (cueOut) {
      removed.add(i);
      inCueRun = !cueIn;
      continue;
    }
    if (cueOutCont || scte) {
      removed.add(i);
      continue;
    }
    if (_hasAdDaterange(tags) || _hasAdUrlToken(segment.uri)) removed.add(i);
  }
  return removed;
}

bool _hasAdDaterange(List<String> upperTags) {
  for (final tag in upperTags) {
    if (!tag.startsWith('#EXT-X-DATERANGE:')) continue;
    if (_adDaterangeToken.hasMatch(tag)) return true;
  }
  return false;
}

/// 只在词边界上认广告词：`LOAD` 里的 `AD` 不算，`CLASS=...INTERSTITIAL` 算。
final RegExp _adDaterangeToken = RegExp(
  r'(?:^|[^A-Z0-9])(?:ADS?|ADVERT|SPLICE|INTERSTITIAL|CUE)(?:$|[^A-Z0-9])',
);

/// URL 里的广告词同样只在分隔符边界上认，避免把 `sadou`/`radar` 判成广告。
final RegExp _adUrlToken = RegExp(
  r'(?:^|[/_.\-?&=])(?:AD|ADS|ADV|ADVERT|ADVERTISEMENT|PREROLL|MIDROLL'
  r'|POSTROLL|BUMPER|SPLICE|SCTE35|CUE)(?:[/_.\-?&=]|$)',
);

bool _hasAdUrlToken(String uri) => _adUrlToken.hasMatch(uri.toUpperCase());

/// 第 4 级（精度）：短的非主导组里，时长全是 3 位小数且**完全一致**——同一段广告被切片。
Set<int> _cleanDecimalPrecisionGroups(_Manifest manifest, Uri playlistUri) {
  final groups = _groups(manifest.segments);
  if (groups.length < 2) return const <int>{};
  final dominant = _dominantGroup(manifest, groups);
  final dominantPrecision = _typicalPrecision(
    _durationsOf(manifest, dominant.indices),
  );
  if (dominantPrecision > kPurifyDominantPrecisionMax) return const <int>{};
  final removed = <int>{};
  for (final group in groups) {
    if (identical(group, dominant)) continue;
    if (!_isMinorShortGroup(manifest, group, dominant)) continue;
    final durations = _durationsOf(manifest, group.indices);
    if (durations.contains(null)) continue;
    final values = durations.cast<double>();
    final precisions = values.map(_decimalPrecision).toSet();
    if (precisions.length != 1 || precisions.single < 3) continue;
    if (values.toSet().length != 1) continue;
    removed.addAll(group.indices);
  }
  return removed;
}

/// 第 4 级（帧率）：短的非主导组里，所有时长在 ±1 帧内摆动——逐帧重切出来的插播。
Set<int> _cleanFrameRateGroups(_Manifest manifest, Uri playlistUri) {
  final groups = _groups(manifest.segments);
  if (groups.length < 2) return const <int>{};
  final dominant = _dominantGroup(manifest, groups);
  final removed = <int>{};
  for (final group in groups) {
    if (identical(group, dominant)) continue;
    if (!_isMinorShortGroup(manifest, group, dominant)) continue;
    final durations = _durationsOf(manifest, group.indices);
    if (durations.contains(null)) continue;
    final values = durations.cast<double>();
    if (values.length < 2) continue;
    var min = values.first;
    var max = values.first;
    for (final value in values) {
      if (value < min) min = value;
      if (value > max) max = value;
    }
    final spread = max - min;
    if (spread <= 0 || spread > kPurifyFrameMaxSpreadSec) continue;
    if (values.every((value) => _decimalPrecision(value) < 2)) continue;
    removed.addAll(group.indices);
  }
  return removed;
}

/// 第 5 级：删非主导的短不连续组——最激进的一级，兜住前四级都看不出来的插播。
Set<int> _cleanDiscontinuityGroups(_Manifest manifest, Uri playlistUri) {
  final groups = _groups(manifest.segments);
  if (groups.length < 2) return const <int>{};
  final dominant = _dominantGroup(manifest, groups);
  final removed = <int>{};
  for (final group in groups) {
    if (identical(group, dominant)) continue;
    if (!_isMinorShortGroup(manifest, group, dominant)) continue;
    removed.addAll(group.indices);
  }
  return removed;
}

/// 「可播放媒体清单」：有分片、不是主清单、没有悬空 EXTINF、URI 行没被结构破坏。
bool _isPlayableMediaPlaylist(String text, {Uri? playlistUri}) {
  final lines = <String>[
    for (final line in text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.isEmpty || lines.first.toUpperCase() != '#EXTM3U') return false;
  var needsUri = false;
  var segments = 0;
  var ended = false;
  var durationSum = 0.0;
  for (final line in lines) {
    final upper = line.toUpperCase();
    if (upper.startsWith('#EXT-X-STREAM-INF:')) return false;
    if (upper.startsWith('#EXTINF:')) {
      if (needsUri || ended) return false;
      final csv = line.substring('#EXTINF:'.length);
      final comma = csv.indexOf(',');
      if (comma < 0) return false;
      final duration = double.tryParse(csv.substring(0, comma).trim());
      if (duration == null || !duration.isFinite || duration < 0) return false;
      durationSum += duration;
      if (!durationSum.isFinite) return false;
      needsUri = true;
    } else if (upper == '#EXT-X-ENDLIST') {
      if (needsUri) return false;
      ended = true;
    } else if (!line.startsWith('#')) {
      if (!needsUri || ended) return false;
      if (_isBrokenUri(line)) return false;
      try {
        final uri = Uri.parse(line);
        final resolved = playlistUri == null
            ? uri
            : playlistUri.resolveUri(uri);
        if (resolved.hasScheme &&
            resolved.scheme != 'http' &&
            resolved.scheme != 'https') {
          return false;
        }
        if ((resolved.scheme == 'http' || resolved.scheme == 'https') &&
            resolved.host.isEmpty) {
          return false;
        }
      } on FormatException {
        return false;
      }
      needsUri = false;
      segments++;
    }
  }
  return ended && !needsUri && segments > 0;
}

bool _isBrokenUri(String line) {
  if (line.isEmpty) return true;
  if (line.contains(' ')) return true;
  if (line.contains('\t')) return true;
  if (line.contains('"')) return true;
  if (line.endsWith(',')) return true;
  return false;
}
