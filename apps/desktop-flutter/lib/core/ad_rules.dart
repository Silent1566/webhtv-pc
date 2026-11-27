/// 广告过滤规则（`docs/phase9/README.md` P1-1）。
///
/// 两类规则都来自用户配置，PC 端不内置任何广告域名：
/// - `ads`：广告/统计**主机名**清单；命中即拒绝该请求或从清单中剔除对应分片；
/// - `hlsRules`：HLS 分片级规则（清单主机范围 + 分片主机/URL/时长/不连续/跨域信号）。
///
/// 本文件只做纯逻辑：解析规则、判定分片、清洗 m3u8 文本。
/// 不做网络请求，也不依赖代理实现，便于用固定 m3u8 样本穷举。
///
/// 安全与正确性约束（与安卓 `utils/HlsManifestCleaner.java` 对齐）：
/// 1. 规则为空时**原样返回**输入，绝不做任何“启发式猜测”；
/// 2. 规则不匹配清单主机时整条规则不生效（避免把别的站点的分片误删）；
/// 3. 只删除分片与其分片级标签；`#EXT-X-KEY`/`#EXT-X-MAP` 这类会影响后续分片的
///    标签保留，避免删广告把正片解密搞坏；
/// 4. 删完若没有任何变化，返回原文（调用方据此跳过重写）；
/// 5. 结构上无法安全重算的清单（BYTERANGE / 低延迟 HLS / 超体积）直接放弃，
///    放弃时**原文与计数同时归零**，绝不半途写出半份清单；
/// 6. 删除量超过 35% 或超过 90 秒即放弃：一条过宽的规则不该删掉整片正片。
library;

import 'protocol.dart';

/// 命中 `ads` 主机清单时记入统计的规则 id。
const String kAdHostRuleId = 'ads';

/// 清单体积上限（字符）：超过就别逐行分析了。
const int kMaxManifestChars = 2 * 1024 * 1024;

/// 清单行数上限：正常媒体清单远小于它，超出说明不是给我们洗的清单。
const int kMaxManifestLines = 20000;

/// 单次可删除的分片比例上限。
const double kMaxRemovalRatio = 0.35;

/// 单次可删除的媒体时长上限（秒）：超过就不是「插播广告」而是「换片」了。
const double kMaxRemovedDurationSec = 90;

/// 单条规则的清单主机正则上限。
const int kMaxRuleRegexCount = 32;

/// 单条正则的字符上限（与安卓 `MAX_REGEX_LENGTH` 同口径）。
const int kMaxRuleRegexLength = 512;

/// 一条 HLS 广告规则（对应安卓 `HlsAdRule` 的可用子集）。
class HlsAdRule {
  const HlsAdRule({
    required this.id,
    this.playlistHostSuffixes = const [],
    this.playlistHostRegex = const [],
    this.hostSuffixes = const [],
    this.segmentUrlRegex = const [],
    this.minDuration,
    this.maxDuration,
    this.requireDiscontinuity = false,
    this.requireCrossDomain = false,
    this.minimumSignals = 1,
    this.playlistPath,
    this.excludeUrlRegex = const [],
  });

  final String id;

  /// 只对这些清单主机生效（后缀匹配）。
  final List<String> playlistHostSuffixes;

  /// 只对这些清单主机生效（正则）。
  final List<String> playlistHostRegex;

  /// 分片主机后缀信号。
  final List<String> hostSuffixes;

  /// 分片 URL 正则信号。
  final List<String> segmentUrlRegex;

  /// 分片时长区间信号（秒）。
  final double? minDuration;
  final double? maxDuration;

  /// 分片前有 `#EXT-X-DISCONTINUITY` 信号。
  final bool requireDiscontinuity;

  /// 分片与清单跨域信号。
  final bool requireCrossDomain;

  /// 命中多少个信号才算广告（至少 1）。
  final int minimumSignals;
  final String? playlistPath;
  final List<String> excludeUrlRegex;

  bool get isEmpty =>
      hostSuffixes.isEmpty &&
      segmentUrlRegex.isEmpty &&
      minDuration == null &&
      !requireDiscontinuity &&
      !requireCrossDomain;

  /// 声明的信号总数（用于校验 `minimumSignals`）。
  int get signalCount {
    var count = 0;
    if (hostSuffixes.isNotEmpty) count += 1;
    if (segmentUrlRegex.isNotEmpty) count += 1;
    if (minDuration != null && maxDuration != null) count += 1;
    if (requireDiscontinuity) count += 1;
    if (requireCrossDomain) count += 1;
    return count;
  }

  bool get isValid {
    if (isEmpty || minimumSignals < 1 || minimumSignals > signalCount) {
      return false;
    }
    final min = minDuration;
    final max = maxDuration;
    if (min != null || max != null) {
      if (min == null ||
          max == null ||
          !min.isFinite ||
          !max.isFinite ||
          min < 0 ||
          max < min) {
        return false;
      }
    }
    for (final patterns in [
      playlistHostRegex,
      segmentUrlRegex,
      excludeUrlRegex,
    ]) {
      if (patterns.length > kMaxRuleRegexCount ||
          patterns.any((pattern) => safeRuleRegex(pattern) == null)) {
        return false;
      }
    }
    return true;
  }

  /// 规则是否适用于该清单主机。
  bool appliesToPlaylist(String host) {
    final lowered = host.toLowerCase();
    for (final suffix in playlistHostSuffixes) {
      final value = suffix.trim().toLowerCase();
      if (value.isEmpty) continue;
      if (lowered == value || lowered.endsWith('.$value')) return true;
    }
    for (final pattern in playlistHostRegex) {
      final regex = safeRuleRegex(pattern, caseSensitive: false);
      if (regex != null && regex.hasMatch(lowered)) return true;
    }
    return false;
  }

  /// 从 JSON 宽松解析；非法/缺 id 的条目丢弃。
  static List<HlsAdRule> listFrom(Object? raw) {
    if (raw is! List) return const [];
    final rules = <HlsAdRule>[];
    for (final item in raw) {
      final map = asMap(item);
      final id = asNonEmptyString(map['id']) ?? '';
      final min = asDouble(map['minDuration']);
      final max = asDouble(map['maxDuration']);
      if ((map['minDuration'] != null || map['maxDuration'] != null) &&
          (min == null || max == null)) {
        continue;
      }
      final threshold = map['minimumSignals'];
      final minimumSignals = threshold == null ? 1 : _int(threshold);
      if (minimumSignals == null) continue;
      final playlistHostRegex = _strings(map['playlistHostRegex']);
      final segmentUrlRegex = _strings(map['segmentUrlRegex']);
      final excludeUrlRegex = _strings(map['excludeUrlRegex']);
      // 正则不可安全编译的规则整条丢弃：配置作者的错不该让清洗半路抛异常，
      // 也不该让一条病态正则把播放线程挂在回溯上。
      if (playlistHostRegex.any((pattern) => safeRuleRegex(pattern) == null)) {
        continue;
      }
      if (segmentUrlRegex.any((pattern) => safeRuleRegex(pattern) == null)) {
        continue;
      }
      if (excludeUrlRegex.any((pattern) => safeRuleRegex(pattern) == null)) {
        continue;
      }
      final rule = HlsAdRule(
        id: id.isEmpty ? 'hls-${rules.length}' : id,
        playlistHostSuffixes: _strings(map['playlistHostSuffixes']),
        playlistHostRegex: playlistHostRegex,
        hostSuffixes: _strings(map['hostSuffixes']),
        segmentUrlRegex: segmentUrlRegex,
        minDuration: min,
        maxDuration: max,
        requireDiscontinuity: map['requireDiscontinuity'] == true,
        requireCrossDomain: map['requireCrossDomain'] == true,
        minimumSignals: minimumSignals,
        playlistPath: asNonEmptyString(map['playlistPath']),
        excludeUrlRegex: excludeUrlRegex,
      );
      if (!rule.isValid) continue;
      rules.add(rule);
    }
    return rules;
  }

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
  }

  static int? _int(Object? raw) {
    if (raw is! num || !raw.isFinite || raw != raw.truncateToDouble()) {
      return null;
    }
    return raw.toInt();
  }

  static double? asDouble(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw.trim());
    return null;
  }
}

/// 规则正则的编译缓存：媒体清单可能上万行，逐行重编译正则会拖到秒级。
final Map<String, RegExp?> _ruleRegexCache = <String, RegExp?>{};

/// 只接受可安全编译的规则正则：长度、条数与病态回溯三条线（对齐安卓）。
RegExp? safeRuleRegex(String pattern, {bool caseSensitive = true}) {
  final value = pattern.trim();
  if (value.isEmpty ||
      value.length > kMaxRuleRegexLength ||
      _looksDangerous(value)) {
    return null;
  }
  final key = '$caseSensitive:$value';
  if (_ruleRegexCache.containsKey(key)) return _ruleRegexCache[key];
  RegExp? compiled;
  try {
    compiled = RegExp(value, caseSensitive: caseSensitive);
  } catch (_) {
    compiled = null;
  }
  // 切换配置不能让历史正则缓存无界增长。
  if (_ruleRegexCache.length >= 512) {
    _ruleRegexCache.remove(_ruleRegexCache.keys.first);
  }
  _ruleRegexCache[key] = compiled;
  return compiled;
}

/// `.*.*` / `.+.+` / 嵌套量词是典型的回溯爆炸写法：宁可不用这条规则。
bool _looksDangerous(String value) {
  if (value.contains('.*.*') || value.contains('.+.+')) return true;
  return RegExp(r'\([^)]*[+*][^)]*\)[+*]').hasMatch(value);
}

/// 一套生效中的广告规则。
class AdRuleSet {
  const AdRuleSet({this.adHosts = const [], this.hlsRules = const []});

  const AdRuleSet.empty() : this();

  /// 广告主机清单（小写、去端口）。命中即阻止/剔除。
  final List<String> adHosts;

  final List<HlsAdRule> hlsRules;

  bool get isEmpty => adHosts.isEmpty && hlsRules.isEmpty;

  /// 从配置构造。`ads` 既接受纯域名，也接受 `http(s)://host/...`（取 host）。
  factory AdRuleSet.fromConfig(AppConfig config) {
    final hosts = <String>[];
    for (final raw in config.ads) {
      // 只接受字符串：数字/对象不是域名，静默忽略（配置作者的脏数据）。
      if (raw is! String) continue;
      final text = raw.trim();
      if (text.isEmpty) continue;
      final uri = Uri.tryParse(text);
      final host = uri != null && uri.host.isNotEmpty
          ? uri.host
          : text.split('/').first;
      final normalized = _normalizeHost(host);
      if (normalized.isEmpty) continue;
      if (!hosts.contains(normalized)) hosts.add(normalized);
    }
    return AdRuleSet(
      adHosts: hosts,
      hlsRules: HlsAdRule.listFrom(config.hlsRules),
    );
  }

  /// 主机是否在广告清单中（相等或子域）。
  bool isAdHost(String rawHost) {
    final host = _normalizeHost(rawHost);
    if (host.isEmpty) return false;
    for (final entry in adHosts) {
      if (host == entry || host.endsWith('.$entry')) return true;
    }
    return false;
  }
}

String _normalizeHost(String raw) {
  var text = raw.trim().toLowerCase();
  if (text.isEmpty) return '';
  if (text.contains(':')) text = text.split(':').first;
  while (text.startsWith('.')) {
    text = text.substring(1);
  }
  return text;
}

/// 被删掉的一个分片：统计页与日志页要按「哪个域名 / 哪条规则 / 第几秒」记账。
class AdRemovedSegment {
  const AdRemovedSegment({
    required this.host,
    required this.ruleId,
    required this.startSeconds,
    required this.durationSec,
  });

  final String host;
  final String ruleId;
  final double startSeconds;
  final double durationSec;

  Map<String, Object?> toJson() => <String, Object?>{
    'host': host,
    'ruleId': ruleId,
    'startSeconds': startSeconds,
    'durationSec': durationSec,
  };

  static AdRemovedSegment? fromJson(Object? raw) {
    final map = asMap(raw);
    final ruleId = asNonEmptyString(map['ruleId']) ?? '';
    if (ruleId.isEmpty) return null;
    return AdRemovedSegment(
      host: asNonEmptyString(map['host']) ?? '',
      ruleId: ruleId,
      startSeconds: HlsAdRule.asDouble(map['startSeconds']) ?? 0,
      durationSec: HlsAdRule.asDouble(map['durationSec']) ?? 0,
    );
  }
}

/// 清洗结果。
class HlsCleanResult {
  const HlsCleanResult({
    required this.text,
    this.removedSegments = 0,
    this.removedDurationSec = 0,
    this.ruleCounts = const {},
    this.removed = const [],
    this.abandonReason,
  });

  final String text;
  final int removedSegments;

  /// 被删除分片的 `#EXTINF` 时长合计（秒）。
  final double removedDurationSec;

  /// 每条规则删掉了几段（键为规则 id 或 [kAdHostRuleId]）。
  final Map<String, int> ruleCounts;

  /// 删除明细，供统计与日志。
  final List<AdRemovedSegment> removed;

  /// 安全回退保留原文和零移除计数，供代理诊断说明规则为何未应用。
  final String? abandonReason;
  bool get abandoned => abandonReason != null;

  bool get changed => removedSegments > 0;

  @override
  String toString() => 'HlsCleanResult(removed=$removedSegments)';
}

HlsCleanResult _abandon(String text, String reason) =>
    HlsCleanResult(text: text, abandonReason: reason);

HlsCleanResult _unchanged(String text) => HlsCleanResult(text: text);

/// 清洗一个 HLS 清单：删除命中的广告分片。
///
/// [playlistUri] 是清单自身的地址，用于解析相对分片与判断跨域。
///
/// 点播清单与直播窗口走同一条判定，区别只在收尾：直播没有
/// `#EXT-X-ENDLIST`，删掉窗口头部的分片必须同步递增
/// `#EXT-X-MEDIA-SEQUENCE`（与 `#EXT-X-DISCONTINUITY-SEQUENCE`），
/// 否则播放器会把剩下的分片当成比实际更早的媒体序号。
HlsCleanResult cleanHlsPlaylist({
  required String text,
  required Uri playlistUri,
  required AdRuleSet rules,
}) {
  if (text.isEmpty || rules.isEmpty) {
    return _unchanged(text);
  }
  final effectiveRules = AdRuleSet(
    adHosts: rules.adHosts,
    hlsRules: rules.hlsRules.where((rule) => rule.isValid).toList(),
  );
  if (effectiveRules.isEmpty) return _unchanged(text);
  // 带 BOM 的清单同样可播：只在分析时去掉，回写时按原样补回。
  final bom = text.startsWith('\uFEFF') ? '\uFEFF' : '';
  final body = bom.isEmpty ? text : text.substring(1);
  if (!body.trimLeft().startsWith('#EXTM3U')) return _unchanged(text);
  if (body.length > kMaxManifestChars) {
    return _abandon(text, '清单超过 2MB 上限');
  }
  final lines = body
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  if (lines.length > kMaxManifestLines) {
    return _abandon(text, '清单超过 2 万行上限');
  }
  // 这几类清单的分片位置由别的字段共同决定，删一段就得重算全部兄弟字段：
  // 收益远小于风险，直接放弃本次清洗。
  for (final line in lines) {
    final upper = line.trim().toUpperCase();
    if (upper.startsWith('#EXT-X-BYTERANGE')) {
      return _abandon(text, 'BYTERANGE 清单保留原分片偏移');
    }
    if (upper.startsWith('#EXT-X-SKIP:') ||
        upper.startsWith('#EXT-X-PART:') ||
        upper.startsWith('#EXT-X-PRELOAD-HINT:')) {
      return _abandon(text, '低延迟 HLS 清单不做分片删除');
    }
  }
  final hasEndlist = lines.any(
    (line) => line.trim().toUpperCase() == '#EXT-X-ENDLIST',
  );
  final blocks = _parseBlocks(lines);
  if (hasEndlist) {
    if (!_isPlayableMediaPlaylist(body)) {
      return _abandon(text, '上游不是完整可播放的媒体清单');
    }
  } else if (!_isLiveMediaPlaylist(lines, blocks)) {
    return _abandon(text, '上游不是可识别的直播媒体清单');
  }
  // RFC 8216 §5.2：未显式给 IV 的 AES-128 依赖原媒体序号。删除分片会改变
  // 后续解密；BYTERANGE 的隐式偏移同样依赖前段，不能只凭结构有效就认定可播。
  for (final line in lines) {
    final upper = line.trim().toUpperCase();
    if (!upper.startsWith('#EXT-X-KEY:')) continue;
    final values = _attributeMap(upper);
    // METHOD 不止 AES-128：SAMPLE-AES / SAMPLE-AES-CTR 同样用媒体序号派生 IV。
    final method = values['METHOD'] ?? '';
    if (method.isNotEmpty && method != 'NONE' && !values.containsKey('IV')) {
      return _abandon(text, '$method 隐式 IV 依赖原媒体序号');
    }
  }

  var mediaOffsetSec = 0.0;
  var removedCount = 0;
  var removedDurationSec = 0.0;
  final ruleCounts = <String, int>{};
  final removed = <AdRemovedSegment>[];
  for (final block in blocks) {
    final ruleId = _matchRuleId(block, playlistUri, effectiveRules);
    if (ruleId != null) {
      if (block.tags.any(
        (tag) => tag.trim().toUpperCase().startsWith('#EXT-X-MAP:'),
      )) {
        return _abandon(text, '广告分片自带初始化段，取舍不可判定');
      }
      block.removed = true;
      removedCount += 1;
      removedDurationSec += block.duration ?? 0;
      ruleCounts[ruleId] = (ruleCounts[ruleId] ?? 0) + 1;
      removed.add(
        AdRemovedSegment(
          host: block.hostOf(playlistUri),
          ruleId: ruleId,
          startSeconds: mediaOffsetSec,
          durationSec: block.duration ?? 0,
        ),
      );
    }
    mediaOffsetSec += block.duration ?? 0;
  }

  if (removedCount == 0) return _unchanged(text);
  if (removedCount == blocks.length) {
    return _abandon(text, '所有分片都被判定为广告');
  }
  if (removedCount / blocks.length > kMaxRemovalRatio) {
    return _abandon(text, '移除分片超过 35% 上限');
  }
  if (removedDurationSec > kMaxRemovedDurationSec) {
    return _abandon(text, '移除时长超过 90 秒上限');
  }

  // 直播窗口：删掉的必须是窗口头部连续的一段，否则窗口语义无从重算。
  var mediaSequenceIncrement = 0;
  var discontinuitySequenceIncrement = 0;
  if (!hasEndlist) {
    var retainedSeen = false;
    for (final block in blocks) {
      if (!block.removed) {
        retainedSeen = true;
        continue;
      }
      if (retainedSeen) {
        return _abandon(text, '直播窗口只删除窗口头部的广告');
      }
      mediaSequenceIncrement += 1;
      if (block.discontinuity) discontinuitySequenceIncrement += 1;
    }
    if (mediaSequenceIncrement > 0 &&
        !lines.any(
          (line) =>
              line.trim().toUpperCase().startsWith('#EXT-X-MEDIA-SEQUENCE:'),
        )) {
      return _abandon(text, '直播清单缺少 MEDIA-SEQUENCE，无法保持序号');
    }
    if (discontinuitySequenceIncrement > 0 &&
        !lines.any(
          (line) => line.trim().toUpperCase().startsWith(
            '#EXT-X-DISCONTINUITY-SEQUENCE:',
          ),
        )) {
      return _abandon(text, '直播清单缺少 DISCONTINUITY-SEQUENCE，无法保持序号');
    }
  }

  final String cleaned;
  try {
    cleaned = _render(
      blocks,
      trailing: _trailingTags(lines),
      bom: bom,
      mediaSequenceIncrement: mediaSequenceIncrement,
      discontinuitySequenceIncrement: discontinuitySequenceIncrement,
      dropSegmentPrefixTags: !hasEndlist,
    );
  } on FormatException {
    return _abandon(text, '清单序号不是合法整数，放弃重写');
  }

  final cleanedBody = bom.isEmpty ? cleaned : cleaned.substring(1);
  if (hasEndlist && !_isPlayableMediaPlaylist(cleanedBody)) {
    return _abandon(text, '清洗后媒体清单不可播放');
  }
  return HlsCleanResult(
    text: cleaned,
    removedSegments: removedCount,
    removedDurationSec: removedDurationSec,
    ruleCounts: Map<String, int>.unmodifiable(ruleCounts),
    removed: List<AdRemovedSegment>.unmodifiable(removed),
  );
}

Map<String, String> _attributeMap(String upper) {
  final attributes = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
  return {
    for (final match in attributes.allMatches(upper))
      match[1]!: match[2]!.replaceAll('"', '').trim(),
  };
}

/// 尾部没有归属分片的标签（例如 `#EXT-X-ENDLIST`）。
List<String> _trailingTags(List<String> lines) {
  final trailing = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      trailing.add(line);
      continue;
    }
    trailing.clear();
  }
  if (trailing.isNotEmpty && trailing.last.isEmpty) trailing.removeLast();
  return trailing;
}

List<_SegmentBlock> _parseBlocks(List<String> lines) {
  final blocks = <_SegmentBlock>[];
  final pending = <String>[];
  var pendingDiscontinuity = false;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      pending.add(line);
      continue;
    }
    if (trimmed.startsWith('#')) {
      pending.add(line);
      if (trimmed.toUpperCase() == '#EXT-X-DISCONTINUITY') {
        pendingDiscontinuity = true;
      }
      continue;
    }
    // 分片 URI 行。
    blocks.add(
      _SegmentBlock(
        tags: List<String>.of(pending),
        uri: trimmed,
        discontinuity: pendingDiscontinuity,
      ),
    );
    pending.clear();
    pendingDiscontinuity = false;
  }
  return blocks;
}

String _render(
  List<_SegmentBlock> blocks, {
  required List<String> trailing,
  required String bom,
  required int mediaSequenceIncrement,
  required int discontinuitySequenceIncrement,
  required bool dropSegmentPrefixTags,
}) {
  final output = <String>[];
  for (final block in blocks) {
    if (!block.removed) {
      for (final tag in block.tags) {
        output.add(
          _rewriteSequence(
            tag,
            mediaSequenceIncrement,
            discontinuitySequenceIncrement,
          ),
        );
      }
      output.add(block.uri);
      continue;
    }
    for (final tag in block.tags) {
      if (!_survivesSegmentRemoval(
        tag,
        dropPrefixTags: dropSegmentPrefixTags,
      )) {
        continue;
      }
      output.add(
        _rewriteSequence(
          tag,
          mediaSequenceIncrement,
          discontinuitySequenceIncrement,
        ),
      );
    }
  }
  for (final tag in trailing) {
    output.add(
      _rewriteSequence(
        tag,
        mediaSequenceIncrement,
        discontinuitySequenceIncrement,
      ),
    );
  }
  final joined = output.join('\n');
  return bom.isEmpty ? joined : bom + joined;
}

/// 删掉该分片时这条标签要不要留。
///
/// 判据是「删掉它会不会改变仍保留的分片的解释」：KEY / MAP / DEFINE / GAP /
/// I-FRAMES-ONLY 持续生效，必须保留；EXTINF / BYTERANGE / 时间戳 / 码率只描述
/// 被删的那一段。`#EXT-X-DISCONTINUITY` 是边界标记而不是状态：直播窗口把它连同
/// 分片一起移出窗口（DISCONTINUITY-SEQUENCE 已递增），点播则保留它——点播里它
/// 描述的正是「这一段与上一段不同」，删广告后仍然成立。
bool _survivesSegmentRemoval(String tag, {required bool dropPrefixTags}) {
  final upper = tag.trim().toUpperCase();
  if (upper.startsWith('#EXTINF') ||
      upper.startsWith('#EXT-X-BYTERANGE') ||
      upper.startsWith('#EXT-X-PROGRAM-DATE-TIME') ||
      upper.startsWith('#EXT-X-BITRATE')) {
    return false;
  }
  if (upper == '#EXT-X-DISCONTINUITY') return !dropPrefixTags;
  return true;
}

String _rewriteSequence(
  String line,
  int mediaIncrement,
  int discontinuityIncrement,
) {
  final upper = line.trim().toUpperCase();
  if (mediaIncrement > 0 && upper.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
    return _incrementTag(line, '#EXT-X-MEDIA-SEQUENCE:', mediaIncrement);
  }
  if (discontinuityIncrement > 0 &&
      upper.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE:')) {
    return _incrementTag(
      line,
      '#EXT-X-DISCONTINUITY-SEQUENCE:',
      discontinuityIncrement,
    );
  }
  return line;
}

String _incrementTag(String line, String tag, int increment) {
  final raw = line.trim().substring(tag.length).trim();
  final value = BigInt.tryParse(raw);
  if (value == null || value.isNegative || value.bitLength > 64) {
    throw const FormatException('清单序号不是合法无符号 64 位整数');
  }
  final updated = value + BigInt.from(increment);
  if (updated.bitLength > 64) throw const FormatException('清单序号溢出');
  return '$tag$updated';
}

bool _isPlayableMediaPlaylist(String text, {bool requireEndlist = true}) {
  var needsUri = false;
  var segments = 0;
  var ended = false;
  final lines = text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  if (lines.isEmpty || lines.first.toUpperCase() != '#EXTM3U') return false;
  for (final line in lines) {
    final upper = line.toUpperCase();
    if (upper.startsWith('#EXT-X-STREAM-INF:')) return false;
    if (upper.startsWith('#EXTINF:')) {
      if (needsUri || ended) return false;
      final duration = double.tryParse(
        line.substring('#EXTINF:'.length).split(',').first.trim(),
      );
      if (duration == null || !duration.isFinite || duration < 0) return false;
      needsUri = true;
    } else if (upper == '#EXT-X-ENDLIST') {
      if (needsUri) return false;
      ended = true;
    } else if (!line.startsWith('#')) {
      if (!needsUri || ended) return false;
      needsUri = false;
      segments++;
    }
  }
  return (!requireEndlist || ended) && !needsUri && segments > 0;
}

/// 直播清单没有 ENDLIST，判据换成「至少有分片、不是主清单、没有悬空 EXTINF」。
bool _isLiveMediaPlaylist(List<String> lines, List<_SegmentBlock> blocks) =>
    blocks.isNotEmpty &&
    _isPlayableMediaPlaylist(lines.join('\n'), requireEndlist: false);

String? _matchRuleId(_SegmentBlock block, Uri playlistUri, AdRuleSet rules) {
  final Uri segment;
  try {
    segment = playlistUri.resolve(block.uri);
  } catch (_) {
    return null;
  }
  final host = segment.host.toLowerCase();
  if (rules.isAdHost(host)) return kAdHostRuleId;

  for (final rule in rules.hlsRules) {
    if (!rule.appliesToPlaylist(playlistUri.host)) continue;
    if (rule.playlistPath != null && rule.playlistPath != playlistUri.path) {
      continue;
    }
    if (rule.excludeUrlRegex.any((pattern) {
      final regex = safeRuleRegex(pattern);
      return regex != null && regex.hasMatch(segment.toString());
    })) {
      continue;
    }
    if (_matchesRule(block, segment, playlistUri, rule)) return rule.id;
  }
  return null;
}

bool _matchesRule(
  _SegmentBlock block,
  Uri segment,
  Uri playlistUri,
  HlsAdRule rule,
) {
  final host = segment.host.toLowerCase();
  final playlistHost = playlistUri.host.toLowerCase();
  var signals = 0;
  var matched = 0;

  if (rule.hostSuffixes.isNotEmpty) {
    signals += 1;
    for (final suffix in rule.hostSuffixes) {
      final value = suffix.trim().toLowerCase();
      if (value.isEmpty) continue;
      if (host == value || host.endsWith('.$value')) {
        matched += 1;
        break;
      }
    }
  }
  if (rule.segmentUrlRegex.isNotEmpty) {
    signals += 1;
    for (final pattern in rule.segmentUrlRegex) {
      final regex = safeRuleRegex(pattern);
      if (regex != null && regex.hasMatch(segment.toString())) {
        matched += 1;
        break;
      }
    }
  }
  final min = rule.minDuration;
  final max = rule.maxDuration;
  if (min != null && max != null) {
    signals += 1;
    final duration = block.duration;
    if (duration != null && duration >= min && duration <= max) {
      matched += 1;
    }
  }
  if (rule.requireDiscontinuity) {
    signals += 1;
    if (block.discontinuity) matched += 1;
  }
  if (rule.requireCrossDomain) {
    signals += 1;
    if (host.isNotEmpty && playlistHost.isNotEmpty && host != playlistHost) {
      matched += 1;
    }
  }

  if (signals == 0) return false;
  return matched >= rule.minimumSignals && matched > 0;
}

class _SegmentBlock {
  _SegmentBlock({
    required this.tags,
    required this.uri,
    required this.discontinuity,
  });

  final List<String> tags;
  final String uri;
  final bool discontinuity;
  bool removed = false;

  /// 分片的实际主机（解析后的 URI；解析失败退回空串）。
  String hostOf(Uri playlistUri) {
    try {
      return playlistUri.resolve(uri).host.toLowerCase();
    } catch (_) {
      return '';
    }
  }

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
