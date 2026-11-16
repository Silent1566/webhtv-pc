/// 广告过滤规则（`docs/phase9/README.md` P1-1）。
///
/// 两类规则都来自用户配置，PC 端不内置任何广告域名：
/// - `ads`：广告/统计**主机名**清单；命中即拒绝该请求或从清单中剔除对应分片；
/// - `hlsRules`：HLS 分片级规则（清单主机范围 + 分片主机/URL/时长/不连续/跨域信号）。
///
/// 本文件只做纯逻辑：解析规则、判定分片、清洗 m3u8 文本。
/// 不做网络请求，也不依赖代理实现，便于用固定 m3u8 样本穷举。
///
/// 安全与正确性约束：
/// 1. 规则为空时**原样返回**输入，绝不做任何“启发式猜测”；
/// 2. 规则不匹配清单主机时整条规则不生效（避免把别的站点的分片误删）；
/// 3. 只删除分片与其分片级标签；`#EXT-X-KEY`/`#EXT-X-MAP` 这类会影响后续分片的
///    标签保留，避免删广告把正片解密搞坏；
/// 4. 删完若没有任何变化，返回原文（调用方据此跳过重写）。
library;

import 'protocol.dart';

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

  /// 规则是否适用于该清单主机。
  bool appliesToPlaylist(String host) {
    final lowered = host.toLowerCase();
    for (final suffix in playlistHostSuffixes) {
      final value = suffix.trim().toLowerCase();
      if (value.isEmpty) continue;
      if (lowered == value || lowered.endsWith('.$value')) return true;
    }
    for (final pattern in playlistHostRegex) {
      final value = pattern.trim();
      if (value.isEmpty) continue;
      try {
        if (RegExp(value, caseSensitive: false).hasMatch(lowered)) return true;
      } catch (_) {
        // 非法正则忽略该条（配置作者的错不该让整个清洗失败）。
      }
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
      final rule = HlsAdRule(
        id: id.isEmpty ? 'hls-${rules.length}' : id,
        playlistHostSuffixes: _strings(map['playlistHostSuffixes']),
        playlistHostRegex: _strings(map['playlistHostRegex']),
        hostSuffixes: _strings(map['hostSuffixes']),
        segmentUrlRegex: _strings(map['segmentUrlRegex']),
        minDuration: min,
        maxDuration: max,
        requireDiscontinuity: map['requireDiscontinuity'] == true,
        requireCrossDomain: map['requireCrossDomain'] == true,
        minimumSignals: _int(map['minimumSignals']) ?? 1,
      );
      if (rule.isEmpty) continue;
      if (rule.minimumSignals < 1 || rule.minimumSignals > rule.signalCount) {
        continue;
      }
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

  static int? _int(Object? raw) => raw is num ? raw.toInt() : null;

  static double? asDouble(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw.trim());
    return null;
  }
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

/// 清洗结果。
class HlsCleanResult {
  const HlsCleanResult({
    required this.text,
    this.removedSegments = 0,
    this.abandonReason,
  });

  final String text;
  final int removedSegments;

  /// 安全回退保留原文和零移除计数，供代理诊断说明规则为何未应用。
  final String? abandonReason;
  bool get abandoned => abandonReason != null;

  bool get changed => removedSegments > 0;

  @override
  String toString() => 'HlsCleanResult(removed=$removedSegments)';
}

/// 清洗一个 HLS 清单：删除命中的广告分片。
///
/// [playlistUri] 是清单自身的地址，用于解析相对分片与判断跨域。
HlsCleanResult cleanHlsPlaylist({
  required String text,
  required Uri playlistUri,
  required AdRuleSet rules,
}) {
  if (text.isEmpty || rules.isEmpty) {
    return HlsCleanResult(text: text);
  }
  // 带 BOM 的清单同样可播：只在分析时去掉，回写时按原样补回。
  final bom = text.startsWith('\uFEFF') ? '\uFEFF' : '';
  final body = bom.isEmpty ? text : text.substring(1);
  final lines = body.replaceAll('\r\n', '\n').replaceAll('\r', '').split('\n');
  // 规则清洗只处理完整点播媒体清单，不能删直播窗口或主清单的 variant URI。
  if (!lines.any((line) => line.trim().toUpperCase() == '#EXT-X-ENDLIST')) {
    return HlsCleanResult(text: text);
  }
  if (!_isPlayableMediaPlaylist(body)) {
    return HlsCleanResult(text: text, abandonReason: '上游不是完整可播放的媒体清单');
  }
  // RFC 8216 §5.2：未显式给 IV 的 AES-128 依赖原媒体序号。删除分片会改变
  // 后续解密；BYTERANGE 的隐式偏移同样依赖前段，不能只凭结构有效就认定可播。
  final attributes = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
  for (final raw in lines) {
    final upper = raw.trim().toUpperCase();
    if (upper.startsWith('#EXT-X-BYTERANGE:')) {
      return HlsCleanResult(text: text, abandonReason: 'BYTERANGE 清单保留原分片偏移');
    }
    if (!upper.startsWith('#EXT-X-KEY:')) continue;
    final values = {
      for (final match in attributes.allMatches(upper))
        match[1]!: match[2]!.replaceAll('"', '').trim(),
    };
    // METHOD 不止 AES-128：SAMPLE-AES / SAMPLE-AES-CTR 同样用媒体序号派生 IV。
    final method = values['METHOD'] ?? '';
    if (method.isNotEmpty && method != 'NONE' && !values.containsKey('IV')) {
      return HlsCleanResult(text: text, abandonReason: '$method 隐式 IV 依赖原媒体序号');
    }
  }

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
      if (trimmed.toUpperCase().startsWith('#EXT-X-DISCONTINUITY')) {
        pendingDiscontinuity = true;
      }
      continue;
    }
    // 分片 URI 行。
    final tags = List<String>.of(pending);
    blocks.add(
      _SegmentBlock(
        tags: tags,
        uri: trimmed,
        discontinuity: pendingDiscontinuity,
      ),
    );
    pending.clear();
    pendingDiscontinuity = false;
  }

  var removed = 0;
  final output = <String>[];
  for (final block in blocks) {
    if (_isAdBlock(block, playlistUri, rules)) {
      // MAP 声明的初始化段归属于后随分片。删掉广告却留下它的 MAP，会让下一个
      // 正片分片用广告的 init 段解码；删掉 MAP 又让正片用回更早的 init 段。
      // 两种猜测都可能坏，直接放弃这次清洗。
      if (block.tags.any(_isInitSectionTag)) {
        return HlsCleanResult(text: text, abandonReason: '广告分片自带初始化段，取舍不可判定');
      }
      removed += 1;
      // 只丢**属于这一分片本身**的标签。其它标签（KEY / DISCONTINUITY / DEFINE /
      // I-FRAMES-ONLY / GAP 等）对后随分片持续生效，删掉会破坏仍保留的分片。
      for (final tag in block.tags) {
        if (!_isSegmentLocalTag(tag)) output.add(tag);
      }
      continue;
    }
    output.addAll(block.tags);
    output.add(block.uri);
  }
  // 末尾剩余标签（如 #EXT-X-ENDLIST）保留。
  output.addAll(pending);

  if (removed == 0) return HlsCleanResult(text: text);
  // 当前只有规则级清洗；30% 是多级启发式的单级限额，不套在用户规则上。
  // 累计超过一半则整次回退，避免一条宽规则删除整片 CDN 的正片。
  if (removed > blocks.length * 0.5) {
    return HlsCleanResult(text: text, abandonReason: '移除分片超过50%上限');
  }
  final cleaned = output.join('\n');
  if (!_isPlayableMediaPlaylist(cleaned)) {
    return HlsCleanResult(text: text, abandonReason: '清洗后媒体清单不可播放');
  }
  return HlsCleanResult(text: '$bom$cleaned', removedSegments: removed);
}

/// `#EXT-X-MAP` 指向后随分片共用的初始化段，删分片时无法安全重绑定。
bool _isInitSectionTag(String tag) =>
    tag.trim().toUpperCase().startsWith('#EXT-X-MAP');

/// 只描述**紧跟的那个分片**的标签，删掉该分片时一并删。
///
/// 判据是「删掉它会不会改变仍保留的分片的解释」：KEY / DISCONTINUITY / DEFINE /
/// GAP / I-FRAMES-ONLY 等持续生效，必须保留；EXTINF / BYTERANGE / 时间戳 / 广告
/// 标记只描述被删的那一段。
bool _isSegmentLocalTag(String tag) {
  final upper = tag.trim().toUpperCase();
  return upper.startsWith('#EXTINF') ||
      upper.startsWith('#EXT-X-BYTERANGE') ||
      upper.startsWith('#EXT-X-PROGRAM-DATE-TIME') ||
      upper.startsWith('#EXT-X-BITRATE');
}

bool _isPlayableMediaPlaylist(String text) {
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
  return ended && !needsUri && segments > 0;
}

bool _isAdBlock(_SegmentBlock block, Uri playlistUri, AdRuleSet rules) {
  final Uri segment;
  try {
    segment = playlistUri.resolve(block.uri);
  } catch (_) {
    return false;
  }
  final host = segment.host.toLowerCase();
  if (rules.isAdHost(host)) return true;

  for (final rule in rules.hlsRules) {
    if (!rule.appliesToPlaylist(playlistUri.host)) continue;
    if (rule.playlistPath != null && rule.playlistPath != playlistUri.path) {
      continue;
    }
    if (rule.excludeUrlRegex.any(
      (pattern) => RegExp(pattern).hasMatch(segment.toString()),
    )) {
      continue;
    }
    if (_matchesRule(block, segment, playlistUri, rule)) return true;
  }
  return false;
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
      try {
        if (RegExp(pattern).hasMatch(segment.toString())) {
          matched += 1;
          break;
        }
      } catch (_) {
        // 非法正则忽略。
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
