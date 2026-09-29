/// 弹幕：数据模型、解析与轨道判定（设计文档 §21 Phase 3「字幕/弹幕可开启和关闭」、
/// §8.3 Result 协议、§10.3 播放器能力）。
///
/// 本层是纯逻辑，不执行网络、不触碰 UI，便于用固定 fixture 做解析与布局测试。
///
/// ## 为什么这样设计
///
/// WebHTV/TVBox 生态里没有单一的弹幕格式，实际至少三种：
///
/// 1. **播放结果里的弹幕源列表**：`Result.danmaku`，元素形态极宽松——可能是
///    字符串（就是地址）、对象（`{name,url,source}`），也可能被包在
///    `data/list/result/items/danmaku` 信封里（Android 侧 `DanmakuAdapter` +
///    `Danmaku.arrayFrom` 就是为此写的兼容层）。
/// 2. **Bilibili XML 弹幕文件**：`<d p="时间,模式,字号,颜色,...">文本</d>`，
///    这是最普遍的弹幕文件格式（media3 `BiliParser`）。
/// 3. **纯文本弹幕**：每行 `[参数]文本`（media3 `TxtParser`）。
///
/// 因此这里的解析规则**逐条对齐 media3 `androidx.media3.ui.danmaku`**：
/// 类型常量（1 滚动 / 4 底部 / 5 顶部 / 6 反向）、Bili mode 映射、
/// 文本行正则 `\[([^\]]+)\](.*)`、参数位置（时间,模式,字号,颜色）、
/// 字号小/大档位（12/18）。
library;

import 'dart:convert';

import 'protocol.dart';

/// 弹幕类型（与 media3 `Danmaku.TYPE_*` 数值一致，便于对照上游）。
enum DanmakuType {
  /// 滚动弹幕（media3 `TYPE_SCROLL = 1`）。
  scroll(1),

  /// 底部固定弹幕（media3 `TYPE_BOTTOM = 4`）。
  bottom(4),

  /// 顶部固定弹幕（media3 `TYPE_TOP = 5`）。
  top(5),

  /// 反向滚动弹幕（media3 `TYPE_REVERSE = 6`）。
  reverse(6);

  const DanmakuType(this.code);

  /// media3 的类型数值。
  final int code;

  /// 是否横向移动（滚动/反向）。
  bool get movesHorizontally =>
      this == DanmakuType.scroll || this == DanmakuType.reverse;

  static DanmakuType? fromCode(int code) {
    for (final type in DanmakuType.values) {
      if (type.code == code) return type;
    }
    return null;
  }

  /// Bilibili `mode` → media3 类型（对齐 media3 `ParserUtil.mapBiliMode`）。
  ///
  /// | Bili mode | 含义 | media3 类型 |
  /// | --- | --- | --- |
  /// | 1/2/3 | 滚动 | 1 |
  /// | 4 | 底部 | 4 |
  /// | 5 | 顶部 | 5 |
  /// | 6 | 反向 | 6 |
  /// | 7 | 高级/定位 | 不支持（[DanmakuType] 无对应值） |
  static DanmakuType? fromBiliMode(int mode) {
    switch (mode) {
      case 1:
      case 2:
      case 3:
        return DanmakuType.scroll;
      case 4:
        return DanmakuType.bottom;
      case 5:
        return DanmakuType.top;
      case 6:
        return DanmakuType.reverse;
      default:
        // 7（定位弹幕）与未知值按 media3 语义返回 -1 → 丢弃。
        return null;
    }
  }
}

/// 一条弹幕。
class DanmakuItem {
  const DanmakuItem({
    required this.timeMs,
    required this.text,
    this.type = DanmakuType.scroll,
    this.color = defaultColor,
    this.textSizeSp = defaultTextSizeSp,
  });

  /// 出现时间（毫秒，相对播放起点）。
  final int timeMs;
  final String text;
  final DanmakuType type;

  /// ARGB 颜色。默认白色（`0xFFFFFFFF`）。
  final int color;

  /// 字号（sp）。默认 [defaultTextSizeSp]。
  final double textSizeSp;

  /// 默认白色，与 media3 `ParserUtil` 的默认色一致。
  static const int defaultColor = 0xFFFFFFFF;

  /// 默认字号，与 media3 `ParserUtil.DEFAULT_SP` 一致。
  static const double defaultTextSizeSp = 16;

  /// Bili 字号小档（media3 `ParserUtil.SMALL_SP = 12`）。
  static const double smallTextSizeSp = 12;

  /// Bili 字号大档（media3 `ParserUtil.LARGE_SP = 18`）。
  static const double largeTextSizeSp = 18;

  Duration get time => Duration(milliseconds: timeMs);

  Map<String, Object?> toJson() => {
    'timeMs': timeMs,
    'text': text,
    'type': type.code,
    'color': color,
    'textSizeSp': textSizeSp,
  };

  static DanmakuItem? fromJson(Object? value) {
    final map = asMap(value);
    final text = asNonEmptyString(map['text']);
    if (text == null) return null;
    final type = DanmakuType.fromCode(asInt(map['type']) ?? 1);
    return DanmakuItem(
      timeMs: asInt(map['timeMs']) ?? 0,
      text: text,
      type: type ?? DanmakuType.scroll,
      color: asInt(map['color']) ?? defaultColor,
      textSizeSp: _asDouble(map['textSizeSp']) ?? defaultTextSizeSp,
    );
  }

  /// Bili 字号档位映射（对齐 media3 `ParserUtil.mapBiliTextSize`）：
  /// `<= 18` → 12；`>= 36` → 18；其余（一般 25）→ 默认。
  static double textSizeForBiliSize(int size) {
    if (size <= 18) return smallTextSizeSp;
    if (size >= 36) return largeTextSizeSp;
    return defaultTextSizeSp;
  }

  @override
  bool operator ==(Object other) =>
      other is DanmakuItem &&
      other.timeMs == timeMs &&
      other.text == text &&
      other.type == type &&
      other.color == color &&
      other.textSizeSp == textSizeSp;

  @override
  int get hashCode => Object.hash(timeMs, text, type, color, textSizeSp);

  @override
  String toString() =>
      'DanmakuItem(${timeMs}ms ${type.name} #${color.toRadixString(16)} '
      '$textSizeSp: $text)';
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

// ------------------------------------------------------------------ 弹幕源解析

/// 解析一个弹幕源条目；不可用返回 null。
///
/// 兼容形态（与 Android `Danmaku.arrayFrom` 同语义）：
/// - 字符串 → 地址；以 `[`/`{` 开头时视为内嵌 JSON 文本（交给上层递归）；
/// - 对象 → `{name,url,source/from/site/...}`；
/// - 缺 `url` → 丢弃。
DanmakuSource? danmakuSourceFromJson(Object? value) {
  // 字符串形态：本身就是地址（含 Android `Danmaku.from(path)`）。
  final text = asString(value);
  if (text != null) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    // Android 的 `arrayFromPrimitive` 会把以 `[`/`{` 开头的字符串当 JSON 再解析。
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) return null;
    return DanmakuSource(url: trimmed, name: trimmed);
  }

  final map = asMap(value);
  final url = asNonEmptyString(map['url']);
  if (url == null) return null;
  return DanmakuSource(
    url: url,
    name: asNonEmptyString(map['name']) ?? '',
    source: _firstString(map, const [
      'source',
      'from',
      'site',
      'provider',
      'platform',
    ]),
    selected: map['selected'] == true,
  );
}

/// 解析播放结果里的 `danmaku` 字段。
///
/// 兼容（与 Android `Danmaku.arrayFrom` 同语义）：
/// - 数组 → 逐个解析；
/// - 信封对象（[danmakuEnvelopeKeys]）→ 递归下钻；
/// - 单个对象 → 当成一个源；
/// - 字符串 → 地址，或以 `[`/`{` 开头的内嵌 JSON 文本。
/// 结果按 `url` 去重并保序（对齐 Android `Danmaku.equals` 只比 url）。
List<DanmakuSource> danmakuSourcesFromJson(Object? value) {
  final seen = <String>{};
  final unique = <DanmakuSource>[];
  for (final source in _collectSources(value, depth: 0)) {
    if (seen.add(source.url)) unique.add(source);
  }
  return unique;
}

/// 弹幕源常见信封键（对齐 Android `Danmaku.arrayFrom` 的下钻顺序）。
const List<String> danmakuEnvelopeKeys = [
  'data',
  'list',
  'result',
  'results',
  'items',
  'danmakus',
  'danmaku',
];

List<DanmakuSource> _collectSources(Object? value, {required int depth}) {
  // 防御自引用/过深嵌套：信封最多下钻 3 层（畸形配置不得把导入挂死）。
  if (depth > 3 || value == null) return const [];

  if (value is List) {
    final result = <DanmakuSource>[];
    for (final item in value) {
      result.addAll(_collectSources(item, depth: depth + 1));
    }
    return result;
  }

  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      final decoded = decodeDanmakuJson(trimmed);
      if (decoded == null) return const [];
      return _collectSources(decoded, depth: depth + 1);
    }
    final single = danmakuSourceFromJson(trimmed);
    return single == null ? const [] : [single];
  }

  if (value is Map) {
    final map = asMap(value);
    for (final key in danmakuEnvelopeKeys) {
      if (!map.containsKey(key)) continue;
      final nested = _collectSources(map[key], depth: depth + 1);
      if (nested.isNotEmpty) return nested;
    }
    final single = danmakuSourceFromJson(value);
    return single == null ? const [] : [single];
  }

  return const [];
}

String _firstString(Map<String, Object?> map, List<String> keys) {
  for (final key in keys) {
    final value = asNonEmptyString(map[key]);
    if (value != null) return value;
  }
  return '';
}

/// 尝试把内嵌 JSON 文本解码为可用结构；失败返回 null（不抛异常）。
Object? decodeDanmakuJson(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

/// 解析产物：一次弹幕文件的解析结果。
class DanmakuParseResult {
  const DanmakuParseResult({
    required this.items,
    required this.format,
    this.skipped = 0,
  });

  final List<DanmakuItem> items;

  /// 识别出的格式：`xml`（Bilibili XML）或 `text`（行式文本）。
  final String format;

  /// 被丢弃的条目数（非法行/不支持的弹幕类型），用于诊断。
  final int skipped;

  String get logLine =>
      'format=$format items=${items.length} skipped=$skipped';
}

/// 弹幕文件格式。
enum DanmakuFormat {
  /// Bilibili XML：`<d p="时间,模式,字号,颜色,...">文本</d>`。
  xml,

  /// 行式文本：`[时间,模式,字号,颜色]文本`。
  text,
}

/// 判定弹幕文件格式（对齐 media3 各 `Parser.sniff` 的取舍）。
///
/// - 跳过空行与 XML 声明后，以 `<` 开头 → XML；
/// - 命中文本行正则 → text；
/// - 都识别不出 → null（调用方报 `danmakuInvalid`，不静默返回空列表）。
DanmakuFormat? sniffDanmakuFormat(String content) {
  final lines = content.split('\n');
  for (var index = 0; index < lines.length && index < 200; index++) {
    final trimmed = lines[index].trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('<?xml')) continue;
    if (trimmed.startsWith('<')) return DanmakuFormat.xml;
    if (danmakuTextLinePattern.hasMatch(trimmed)) return DanmakuFormat.text;
    return null;
  }
  return null;
}

/// 文本弹幕行正则，与 media3 `TxtParser.LINE_PATTERN` 完全一致：
/// `\[([^\]]+)\](.*)`——参数放方括号里，其余部分为文本。
final RegExp danmakuTextLinePattern = RegExp(r'\[([^\]]+)\](.*)');

/// Bilibili XML 的 `<d p="...">文本</d>` 规则。
///
/// 属性顺序固定为 `p` 在前、文本在标签内；与 `xml` 包解析保持一致的宽松度
/// （单引号属性、属性间多空格、自闭合空标签都要能处理）。
final RegExp danmakuXmlEntryPattern = RegExp(
  r'''<d\s+p=(?:"([^"]*)"|'([^']*)')\s*>(.*?)</d>''',
  dotAll: true,
);

/// 解析弹幕文件内容。
///
/// [content] 必须已经是 UTF-8 文本（编码兜底由服务层负责）。
/// 无法识别格式时抛 [DanmakuFormatException]。
DanmakuParseResult parseDanmakuContent(
  String content, {
  DanmakuFormat? override,
}) {
  final format = override ?? sniffDanmakuFormat(content);
  if (format == null) {
    throw const DanmakuFormatException('无法识别弹幕格式（既不是 Bilibili XML 也不是行式文本）');
  }
  return format == DanmakuFormat.xml
      ? _parseXml(content)
      : _parseText(content);
}

/// 弹幕内容无法解析。
class DanmakuFormatException implements Exception {
  const DanmakuFormatException(this.message);

  final String message;

  @override
  String toString() => 'DanmakuFormatException: $message';
}

DanmakuParseResult _parseText(String content) {
  final items = <DanmakuItem>[];
  var skipped = 0;
  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final item = parseDanmakuTextLine(line);
    if (item == null) {
      skipped++;
      continue;
    }
    items.add(item);
  }
  items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return DanmakuParseResult(items: items, format: 'text', skipped: skipped);
}

/// 解析一行文本弹幕：`[时间,模式,字号,颜色]文本`。
///
/// 参数位置与 media3 `ParserUtil.parsePAttr` 一致：
/// `[0]` 时间（秒，浮点）、`[1]` 模式、`[2]` 字号、`[3]` 颜色（十进制 ARGB）。
/// 参数不足 4 个、数字非法、模式不支持时返回 null（丢弃该行）。
DanmakuItem? parseDanmakuTextLine(String line) {
  final match = danmakuTextLinePattern.firstMatch(line);
  if (match == null) return null;
  final param = match.group(1);
  final text = _decodeEntities(match.group(2) ?? '');
  if (param == null || text.isEmpty) return null;

  final parts = param.split(',');
  if (parts.length < 4) return null;

  try {
    final seconds = double.parse(parts[0].trim());
    final mode = int.parse(parts[1].trim());
    final size = int.parse(parts[2].trim());
    // 颜色是十进制（Android 用 Long.parseLong），也可能是 `0xRRGGBB` 写法。
    final color = _parseColor(parts[3].trim());
    final type = DanmakuType.fromBiliMode(mode);
    if (type == null) return null;
    return DanmakuItem(
      timeMs: (seconds * 1000).round(),
      text: text,
      type: type,
      color: color,
      textSizeSp: DanmakuItem.textSizeForBiliSize(size),
    );
  } on FormatException {
    return null;
  }
}

DanmakuParseResult _parseXml(String content) {
  final items = <DanmakuItem>[];
  var skipped = 0;
  for (final match in danmakuXmlEntryPattern.allMatches(content)) {
    final param = match.group(1) ?? match.group(2) ?? '';
    final text = _decodeEntities(match.group(3) ?? '');
    final item = _parseXmlEntry(param, text);
    if (item == null) {
      skipped++;
      continue;
    }
    items.add(item);
  }
  items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  return DanmakuParseResult(items: items, format: 'xml', skipped: skipped);
}

/// 解析 `<d p="...">` 的 `p` 属性。
///
/// Bili 的 `p` 字段顺序：`时间,模式,字号,颜色,时间戳,池,用户,行号`。
/// 只有前 4 个是必需的（与 media3 一致）。
DanmakuItem? _parseXmlEntry(String param, String text) {
  if (param.isEmpty || text.isEmpty) return null;
  final parts = param.split(',');
  if (parts.length < 4) return null;
  try {
    final seconds = double.parse(parts[0].trim());
    final mode = int.parse(parts[1].trim());
    final size = int.parse(parts[2].trim());
    final color = _parseColor(parts[3].trim());
    final type = DanmakuType.fromBiliMode(mode);
    if (type == null) return null;
    return DanmakuItem(
      timeMs: (seconds * 1000).round(),
      text: text,
      type: type,
      color: color,
      textSizeSp: DanmakuItem.textSizeForBiliSize(size),
    );
  } on FormatException {
    return null;
  }
}

/// 解析颜色：支持十进制（Android 形态）与 `0x`/`#` 十六进制写法。
int _parseColor(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return DanmakuItem.defaultColor;
  if (trimmed.startsWith('#')) {
    final hex = trimmed.substring(1);
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return DanmakuItem.defaultColor;
    // `#RRGGBB` 补上不透明 alpha；`#AARRGGBB` 原样使用。
    return hex.length <= 6 ? (0xFF000000 | parsed) : parsed;
  }
  final parsed = int.tryParse(trimmed);
  if (parsed != null) {
    // 对齐 Android `DanmakuData.param`：
    // `(0x00000000FF000000L | value) & 0xFFFFFFFF`——弹幕颜色按 RGB 给出，
    // 必须补上不透明 alpha，否则会画成全透明而“看不见弹幕”。
    // 已自带 alpha 的 32 位值原样保留。
    return parsed <= 0xFFFFFF ? (0xFF000000 | parsed) : (parsed & 0xFFFFFFFF);
  }
  final hex = int.tryParse(trimmed, radix: 16);
  if (hex != null) return hex <= 0xFFFFFF ? (0xFF000000 | hex) : hex;
  return DanmakuItem.defaultColor;
}

/// 解码弹幕文本里的 XML 实体（对齐 Android `DanmakuData.getText`）。
String _decodeEntities(String text) => text
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&gt;', '>')
    .replaceAll('&lt;', '<')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .trim();

// ------------------------------------------------------------------ 轨道布局

/// 弹幕轨道分配结果（§10.3 弹幕渲染）。
///
/// 纯函数：给定屏幕参数与已排定弹幕，决定下一条弹幕放到哪一条轨道。
/// 抽出来是为了能对「防重叠」做确定性单测，不必依赖渲染帧。
class DanmakuTrackAllocator {
  DanmakuTrackAllocator({
    required this.width,
    required this.height,
    this.trackHeight = 28,
    this.gap = 12,
    this.maxTracksRatio = 0.6,
  });

  /// 画面宽度（逻辑像素）。
  final double width;

  /// 画面高度（逻辑像素）。
  final double height;

  /// 单条弹幕占用的轨道高度。
  final double trackHeight;

  /// 同轨道相邻弹幕之间的最小水平间距。
  final double gap;

  /// 滚动弹幕最多占用画面的比例（避免遮挡整屏）。
  final double maxTracksRatio;

  int get scrollTrackCount {
    final usable = height * maxTracksRatio;
    final count = (usable / trackHeight).floor();
    return count < 1 ? 1 : count;
  }

  int get fixedTrackCount {
    final count = (height * 0.5 / trackHeight).floor();
    return count < 1 ? 1 : count;
  }

  /// 为一条滚动弹幕分配轨道下标；找不到可用轨道时返回 null（丢弃）。
  ///
  /// 轨道在弹幕进入后的一整个 [DanmakuTrackAllocator#scrollDurationMs] 窗口内
  /// 都被视为占用，只有等到该窗口结束（[trackFreeAtMs] <= 开始时刻）才能复用。
  ///
  /// **为什么不做“尾随空隙复用”**：同一轨道的弹幕共享同一 y 坐标，两条在同刻
  /// 出现在屏幕上必然水平重叠；而精确判定“上一条已完全移入画面左侧”需要按时间
  /// 推算每条的位置与宽度，代价高、容易错。真实弹幕渲染器（含 media3）采用的就是
  /// “轨道在活动窗口内独占”模型：宁可多占一条轨道，也不两条叠字。
  int? allocateScrollTrack({
    required double textWidth,
    required int nowMs,
    required List<int?> trackFreeAtMs,
    List<double> trackTailX = const [],
  }) {
    final count = scrollTrackCount;
    for (var index = 0; index < count; index++) {
      final freeAt = index < trackFreeAtMs.length ? trackFreeAtMs[index] : null;
      if (freeAt == null || freeAt <= nowMs) return index;
    }
    return null;
  }

  /// 为顶部/底部弹幕分配轨道（按顺序占用，满了返回 null）。
  int? allocateFixedTrack({
    required List<int?> trackFreeAtMs,
    required int nowMs,
  }) {
    final count = fixedTrackCount;
    for (var index = 0; index < count; index++) {
      final freeAt = index < trackFreeAtMs.length ? trackFreeAtMs[index] : null;
      if (freeAt == null || freeAt <= nowMs) return index;
    }
    return null;
  }

  /// 判断某条弹幕在当前时间是否应显示，以及它的进度（0..1）。
  ///
  /// 滚动弹幕：进入屏幕到完全离开（[scrollDurationMs]）。
  /// 固定弹幕：显示 [fixedDurationMs] 后消失。
  static ({bool visible, double progress}) visibilityAt({
    required DanmakuItem item,
    required int positionMs,
    int scrollDurationMs = 8000,
    int fixedDurationMs = 4000,
  }) {
    if (item.type.movesHorizontally) {
      final elapsed = positionMs - item.timeMs;
      if (elapsed < 0 || elapsed > scrollDurationMs) {
        return (visible: false, progress: 0);
      }
      return (visible: true, progress: elapsed / scrollDurationMs);
    }
    final elapsed = positionMs - item.timeMs;
    if (elapsed < 0 || elapsed > fixedDurationMs) {
      return (visible: false, progress: 0);
    }
    return (visible: true, progress: elapsed / fixedDurationMs);
  }

  /// 给定播放位置，取出当前应显示的弹幕（含生效的轨道下标）。
  ///
  /// 实现：先在**弹幕开始时刻**把全部弹幕排入轨道（顺序确定性），
  /// 再过滤出「此刻应该显示」的那些。因为轨道是在开始时刻独占的，
  /// 无论从哪个播放位置查询，轨道分配结果都一致且互相不重叠。
  /// [enabled] 为 false（弹幕关闭）时返回空列表——这就是
  /// 「弹幕可开启和关闭」的判定入口。
  static List<VisibleDanmaku> visibleAt({
    required List<DanmakuItem> items,
    required int positionMs,
    required bool enabled,
    int scrollDurationMs = 8000,
    int fixedDurationMs = 4000,
    double width = 1280,
    double height = 720,
    double trackHeight = 28,
    double gap = 12,
  }) {
    if (!enabled || items.isEmpty) return const [];
    final allocator = DanmakuTrackAllocator(
      width: width,
      height: height,
      trackHeight: trackHeight,
      gap: gap,
    );

    // 按开始时刻排定轨道（先排序，保证确定性）。
    final sorted = List<DanmakuItem>.of(items)
      ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    // 轨道 → 最新一条的释放时间（滚动：进入+整个滚动窗口；固定：进入+显示时长）。
    final scrollFreeAt = List<int?>.filled(allocator.scrollTrackCount, null);
    final topFreeAt = List<int?>.filled(allocator.fixedTrackCount, null);
    final bottomFreeAt = List<int?>.filled(allocator.fixedTrackCount, null);
    // 每条弹幕的轨道分配（固定类型取保存的时刻）。
    final trackOf = <DanmakuItem, int>{};

    for (final item in sorted) {
      switch (item.type) {
        case DanmakuType.scroll:
        case DanmakuType.reverse:
          final track = allocator.allocateScrollTrack(
            textWidth: estimateDanmakuTextWidth(item),
            nowMs: item.timeMs,
            trackFreeAtMs: scrollFreeAt,
          );
          if (track == null) continue; // 轨道满：该条丢弃（不阻塞后续）。
          scrollFreeAt[track] = item.timeMs + scrollDurationMs;
          trackOf[item] = track;
        case DanmakuType.top:
          final track = allocator.allocateFixedTrack(
            trackFreeAtMs: topFreeAt,
            nowMs: item.timeMs,
          );
          if (track == null) continue;
          topFreeAt[track] = item.timeMs + fixedDurationMs;
          trackOf[item] = track;
        case DanmakuType.bottom:
          final track = allocator.allocateFixedTrack(
            trackFreeAtMs: bottomFreeAt,
            nowMs: item.timeMs,
          );
          if (track == null) continue;
          bottomFreeAt[track] = item.timeMs + fixedDurationMs;
          trackOf[item] = track;
      }
    }

    final visible = <VisibleDanmaku>[];
    for (final item in sorted) {
      final track = trackOf[item];
      if (track == null) continue;
      final state = visibilityAt(
        item: item,
        positionMs: positionMs,
        scrollDurationMs: scrollDurationMs,
        fixedDurationMs: fixedDurationMs,
      );
      if (!state.visible) continue;
      visible.add(
        VisibleDanmaku(
          item: item,
          track: track,
          progress: state.progress,
          textWidth: estimateDanmakuTextWidth(item),
        ),
      );
    }
    return visible;
  }
}

/// 一条当前可见的弹幕（含轨道与进度），供渲染层直接使用。
class VisibleDanmaku {
  const VisibleDanmaku({
    required this.item,
    required this.track,
    required this.progress,
    required this.textWidth,
  });

  final DanmakuItem item;
  final int track;

  /// 0..1 的生命周期进度。
  final double progress;

  /// 估算的文本宽度（逻辑像素）。
  final double textWidth;

  /// 中文/日文按一个全角宽、其余按半角宽估算。
  ///
  /// 渲染层用真实 `TextPainter` 测量；这里给纯逻辑层一个与字号成正比、
  /// 对中英混排都合理稳定的值，保证防重叠判定可测试。
  static double estimateWidth(String text, double textSizeSp) {
    var units = 0.0;
    for (final rune in text.runes) {
      // ASCII 半角 ≈ 0.5 全角；使 `4 个汉字` 与 `8 个字母` 视觉等宽。
      units += _isWideRune(rune) ? 1.0 : 0.5;
    }
    return units * textSizeSp;
  }

  static bool _isWideRune(int rune) {
    return (rune >= 0x1100 && rune <= 0x115F) ||
        (rune >= 0x2E80 && rune <= 0xA4CF) ||
        (rune >= 0xAC00 && rune <= 0xD7A3) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0xFE30 && rune <= 0xFE6F) ||
        (rune >= 0xFF00 && rune <= 0xFF60) ||
        (rune >= 0xFFE0 && rune <= 0xFFE6);
  }
}

/// 估算弹幕文本宽度（供纯逻辑层使用）。
double estimateDanmakuTextWidth(DanmakuItem item) =>
    VisibleDanmaku.estimateWidth(item.text, item.textSizeSp);

/// 单份弹幕文件大小上限（8 MiB）。
///
/// 弹幕是纯文本，正常文件远小于此；设上限是为了不让「地址其实指向视频/压缩包」
/// 这类情况把内存占满（与配置导入、直播清单同一原则，§7.4.1）。
const int maxDanmakuBytes = 8 * 1024 * 1024;
