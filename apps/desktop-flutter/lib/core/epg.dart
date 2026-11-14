/// EPG（电子节目单）核心（设计文档 §13.1「EPG」、§13.3「EPG 可加载、刷新、显示当前节目」）。
///
/// 本层是纯逻辑：解析 XMLTV 文本、按频道归组节目、判定当前/下一个节目。
/// 网络拉取与缓存刷新在 `lib/services/epg_service.dart`。
///
/// # 为什么按 XMLTV 实现
///
/// 直播清单（M3U 的 `url-tvg` / TXT 的 `#EXTM3U` 属性）指向的就是 **XMLTV** 文件，
/// 这是 WebHTV/TVBox 生态的通用 EPG 格式。Android 侧用 simpleframework 反序列化
/// `Tv`（`channel` + `programme`），PC 端用 `package:xml`（已在依赖中）解析，
/// 字段语义保持一致：
///
/// ```xml
/// <tv>
///   <channel id="cctv1">
///     <display-name>CCTV-1</display-name>
///     <icon src="http://.../cctv1.png"/>
///   </channel>
///   <programme start="20260929080000 +0800" stop="20260929090000 +0800" channel="cctv1">
///     <title>朝闻天下</title>
///   </programme>
/// </tv>
/// ```
///
/// # 频道匹配（对齐 Android `EpgParser.findTargetChannel`）
///
/// programme 的 `channel` 属性（XMLTV channel id）先按直播频道的
/// `tvg-id` → `tvg-name` → 频道名依次匹配；都匹配不上再用 XML 侧
/// `<channel id>` 的 `<display-name>` 反查直播频道名。匹配不上的 programme 丢弃
/// （计入诊断，不阻断其他频道）。
library;

import 'package:xml/xml.dart';

import 'app_error.dart';
import 'protocol.dart';

/// 一个节目（对齐 Android `EpgData`）。
class EpgProgram {
  const EpgProgram({
    required this.title,
    required this.startMs,
    required this.stopMs,
    this.description = '',
  });

  /// 节目名。
  final String title;

  /// 开始/结束时间（UTC epoch 毫秒）。
  final int startMs;
  final int stopMs;

  /// 简介（XMLTV `<desc>`；可选）。
  final String description;

  int get durationMs => stopMs - startMs;

  /// 该节目在 [nowMs] 时刻是否正在播出。
  ///
  /// 边界按「左闭右开」：`start <= now < stop`。这样相邻节目不会同时算作当前。
  bool isLiveAt(int nowMs) => nowMs >= startMs && nowMs < stopMs;

  bool isFinishedAt(int nowMs) => nowMs >= stopMs;

  Map<String, Object?> toJson() => {
    'title': title,
    'startMs': startMs,
    'stopMs': stopMs,
    if (description.isNotEmpty) 'desc': description,
  };

  @override
  bool operator ==(Object other) =>
      other is EpgProgram &&
      other.title == title &&
      other.startMs == startMs &&
      other.stopMs == stopMs;

  @override
  int get hashCode => Object.hash(title, startMs, stopMs);

  @override
  String toString() => 'EpgProgram($title $startMs..$stopMs)';
}

/// 一个频道的节目单（按开始时间排序）。
class EpgChannelGuide {
  const EpgChannelGuide({required this.channelId, required this.programs});

  /// XMLTV 的 channel id（或匹配到的直播频道标识）。
  final String channelId;

  /// 节目列表（按 [EpgProgram.startMs] 升序）。
  final List<EpgProgram> programs;

  bool get isEmpty => programs.isEmpty;
  bool get isNotEmpty => programs.isNotEmpty;

  /// 当前正在播出的节目；没有则返回 null。
  ///
  /// 多个节目同时命中（数据重叠）时取开始时间最晚的那个——这更接近用户预期
  /// 「现在在放什么」。
  EpgProgram? programAt(int nowMs) {
    EpgProgram? found;
    for (final program in programs) {
      if (!program.isLiveAt(nowMs)) continue;
      if (found == null || program.startMs > found.startMs) found = program;
    }
    return found;
  }

  /// 下一个即将播出的节目（开始时间 > [nowMs] 中最早的）。
  EpgProgram? nextAfter(int nowMs) {
    for (final program in programs) {
      if (program.startMs > nowMs) return program;
    }
    return null;
  }

  /// 相对 [nowMs] 的播出进度（0..1）；无当前节目时为 0。
  double progressAt(int nowMs) {
    final current = programAt(nowMs);
    if (current == null || current.durationMs <= 0) return 0;
    return ((nowMs - current.startMs) / current.durationMs).clamp(0.0, 1.0);
  }
}

/// XMLTV 解析结果：全部频道的节目单 + 诊断计数。
class EpgGuide {
  const EpgGuide({
    required this.channels,
    required this.totalPrograms,
    required this.skippedPrograms,
    required this.sourceName,
  });

  /// 频道 id → 节目单。
  final Map<String, EpgChannelGuide> channels;

  final int totalPrograms;

  /// 因频道匹配不上而丢弃的节目数（诊断用，不静默）。
  final int skippedPrograms;

  final String sourceName;

  bool get isEmpty => channels.isEmpty;

  EpgChannelGuide? guideFor(String channelId) => channels[channelId];

  static const EpgGuide empty = EpgGuide(
    channels: {},
    totalPrograms: 0,
    skippedPrograms: 0,
    sourceName: '',
  );

  String get logLine =>
      'source=$sourceName channels=${channels.length} '
      'programs=$totalPrograms skipped=$skippedPrograms';
}

/// 在 [guide] 中查找 [channel] 的节目单（UI 用）。
///
/// 键规则必须与解析期 `_resolveChannelKey` 一致：匹配到直播频道时存的是
/// `epgId`（非空时），否则是频道名。因此这里依次用 `epgId`、频道名查找。
EpgChannelGuide? epgGuideForChannel(EpgGuide? guide, LiveChannel channel) {
  if (guide == null) return null;
  final epgId = channel.epgId?.trim();
  if (epgId != null && epgId.isNotEmpty) {
    final found = guide.guideFor(epgId);
    if (found != null) return found;
  }
  final name = channel.name.trim();
  if (name.isEmpty) return null;
  return guide.guideFor(name);
}

/// 频道当前/下一节目的一句话摘要（UI 列表用）；无节目时返回 null。
String? epgNowLabel(EpgGuide? guide, LiveChannel channel, int nowMs) {
  final channelGuide = epgGuideForChannel(guide, channel);
  if (channelGuide == null) return null;
  final current = channelGuide.programAt(nowMs);
  if (current != null) {
    return '${formatEpgTime(current.startMs)}'
        '-${formatEpgTime(current.stopMs)} ${current.title}';
  }
  final next = channelGuide.nextAfter(nowMs);
  if (next != null) {
    return '${formatEpgTime(next.startMs)} ${next.title}（即将播出）';
  }
  return null;
}

/// EPG 解析错误分类（§13.3 允许 EPG 失败但不阻断直播）。
const Set<AppErrorKind> epgErrorKinds = {
  AppErrorKind.epgNetwork,
  AppErrorKind.epgHttp,
  AppErrorKind.epgDecode,
  AppErrorKind.epgInvalid,
  AppErrorKind.epgEmpty,
  AppErrorKind.epgUnsupported,
};

/// 判断一个错误是否为 EPG 错误。
bool isEpgError(Object? error) =>
    error is AppError && epgErrorKinds.contains(error.kind);

/// EPG 失败的用户提示文案（必须说明不影响直播播放）。
String describeEpgFailure(Object? error) {
  if (error is AppError) return 'EPG 加载失败：${describeErrorKind(error.kind)}';
  return 'EPG 加载失败：${error ?? "未知错误"}（不影响直播播放）';
}

/// XMLTV 文本 → [EpgGuide]。
///
/// [liveChannels] 用于把 XMLTV 的 channel id 匹配到直播频道；为空时**不做匹配**，
/// 直接用 XMLTV 的 channel id 作为键（便于独立测试解析器）。
/// [nowMs] 仅用于诊断日志，不影响解析。
EpgGuide parseXmlTv(
  String xml, {
  List<LiveChannel> liveChannels = const [],
  String sourceName = '',
}) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xml);
  } on XmlException catch (error) {
    throw AppError(
      AppErrorKind.epgInvalid,
      'EPG 内容非法：不是有效的 XMLTV',
      detail: '$error',
      cause: error,
    );
  }

  final root = document.rootElement;
  if (root.name.local.toLowerCase() != 'tv') {
    throw AppError(
      AppErrorKind.epgInvalid,
      'EPG 内容非法：根元素不是 <tv>',
      detail: 'root=<${root.name.local}>',
    );
  }

  // 1) XMLTV 侧 channel：id → display-name（用于反查直播频道）。
  final xmlChannelNames = <String, List<String>>{};
  for (final element in root.findElements('channel')) {
    final id = element.getAttribute('id');
    if (id == null || id.trim().isEmpty) continue;
    final names = <String>[];
    for (final display in element.findElements('display-name')) {
      final text = display.innerText.trim();
      if (text.isNotEmpty) names.add(text);
    }
    xmlChannelNames[id] = names;
  }

  // 2) 直播频道索引：tvg-id / tvg-name / 频道名 → 频道。
  final liveIndex = <String, LiveChannel>{};
  for (final channel in liveChannels) {
    final epgId = channel.epgId?.trim();
    if (epgId != null && epgId.isNotEmpty) {
      liveIndex.putIfAbsent(epgId, () => channel);
    }
    final tvgName = _extraString(channel, 'tvgName') ??
        _extraString(channel, 'tvg-name');
    if (tvgName != null && tvgName.isNotEmpty) {
      liveIndex.putIfAbsent(tvgName, () => channel);
    }
    final name = channel.name.trim();
    if (name.isNotEmpty) liveIndex.putIfAbsent(name, () => channel);
  }

  // 3) 逐个 programme 归组。
  final byChannel = <String, List<EpgProgram>>{};
  var total = 0;
  var skipped = 0;
  for (final element in root.findElements('programme')) {
    final xmlChannelId = element.getAttribute('channel')?.trim() ?? '';
    final start = element.getAttribute('start');
    final stop = element.getAttribute('stop');
    if (xmlChannelId.isEmpty || start == null) {
      skipped++;
      continue;
    }
    final startMs = parseXmlTvTime(start);
    // stop 可缺失（缺省按 +1 小时兜底，保证 duration 有效而不是 0）；
    // 缺失或解析失败均按 [startMs, startMs+1h] 处理。
    final stopMs = stop == null ? null : parseXmlTvTime(stop);
    if (startMs == null) {
      skipped++;
      continue;
    }
    final effectiveStop = stopMs == null || stopMs <= startMs
        ? startMs + const Duration(hours: 1).inMilliseconds
        : stopMs;

    final title = element
        .findElements('title')
        .map((node) => node.innerText.trim())
        .firstWhere((text) => text.isNotEmpty, orElse: () => '');
    if (title.isEmpty) {
      skipped++;
      continue;
    }
    final description = element
        .findElements('desc')
        .map((node) => node.innerText.trim())
        .firstWhere((text) => text.isNotEmpty, orElse: () => '');

    // 频道匹配：直播频道的 epgId/tvgName/name，其次 XML 侧 display-name 反查。
    final key = _resolveChannelKey(
      xmlChannelId: xmlChannelId,
      liveIndex: liveIndex,
      xmlChannelNames: xmlChannelNames,
      hasLiveChannels: liveChannels.isNotEmpty,
    );
    if (key == null) {
      skipped++;
      continue;
    }

    byChannel
        .putIfAbsent(key, () => <EpgProgram>[])
        .add(
          EpgProgram(
            title: title,
            startMs: startMs,
            stopMs: effectiveStop,
            description: description,
          ),
        );
    total++;
  }

  // 4) 排序 + 去重（同一节目可能重复出现）。
  final channels = <String, EpgChannelGuide>{};
  for (final entry in byChannel.entries) {
    final programs = entry.value
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final deduped = <EpgProgram>[];
    for (final program in programs) {
      if (deduped.isEmpty || deduped.last != program) deduped.add(program);
    }
    channels[entry.key] = EpgChannelGuide(
      channelId: entry.key,
      programs: List.unmodifiable(deduped),
    );
  }

  return EpgGuide(
    channels: Map.unmodifiable(channels),
    totalPrograms: total,
    skippedPrograms: skipped,
    sourceName: sourceName,
  );
}

String? _resolveChannelKey({
  required String xmlChannelId,
  required Map<String, LiveChannel> liveIndex,
  required Map<String, List<String>> xmlChannelNames,
  required bool hasLiveChannels,
}) {
  // 无直播频道上下文（独立解析/测试）：直接用 XMLTV 的 channel id。
  if (!hasLiveChannels) return xmlChannelId;

  // 1) 直接命中直播频道的 epgId/tvgName/name。
  if (liveIndex.containsKey(xmlChannelId)) {
    final channel = liveIndex[xmlChannelId]!;
    return channel.epgId?.isNotEmpty == true ? channel.epgId : channel.name;
  }

  // 2) 用 XMLTV <channel> 的 display-name 反查直播频道名（对齐 Android）。
  final names = xmlChannelNames[xmlChannelId];
  if (names != null) {
    for (final name in names) {
      final channel = liveIndex[name];
      if (channel != null) {
        return channel.epgId?.isNotEmpty == true ? channel.epgId : channel.name;
      }
    }
  }
  return null;
}

String? _extraString(LiveChannel channel, String key) {
  final value = channel.extra[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

/// 解析 XMLTV 时间戳。
///
/// 支持的格式（对齐 Android `EpgParser.parseFull` 的取舍）：
/// - `20260929080000`（无时区，按本地时区解释）；
/// - `20260929080000 +0800`（带偏移）；
/// - `20260929080000 +08:00`（偏移带冒号）；
/// - `2026-09-29T08:00:00+08:00`（ISO 8601）。
///
/// 无法解析返回 null（调用方按丢弃处理，不抛异常）。
int? parseXmlTvTime(String source, {Duration? localOffset}) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) return null;
  final offset = localOffset ?? DateTime.now().timeZoneOffset;

  // ISO 8601 形态交给 DateTime.parse。
  if (trimmed.contains('T') || trimmed.contains('-')) {
    final parsed = DateTime.tryParse(trimmed);
    if (parsed != null) return parsed.toUtc().millisecondsSinceEpoch;
  }

  // `YYYYMMDDhhmmss` + 可选 ` +HHMM` / ` +HH:MM`。
  final match = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})?\s*([+-]\d{2}:?\d{2})?$',
  ).firstMatch(trimmed);
  if (match == null) return null;

  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = match.group(6) == null ? 0 : int.parse(match.group(6)!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;

  final zone = match.group(7);
  Duration tz = offset;
  if (zone != null) {
    final cleaned = zone.replaceAll(':', '');
    final sign = cleaned.startsWith('-') ? -1 : 1;
    final digits = cleaned.substring(1);
    final tzHours = int.parse(digits.substring(0, 2));
    final tzMinutes = int.parse(digits.substring(2, 4));
    tz = Duration(hours: sign * tzHours, minutes: sign * tzMinutes);
  }

  // 按「本地时间 - 时区偏移」换算到 UTC（不依赖 DateTime 的本地时区）。
  final utc = DateTime.utc(year, month, day, hour, minute, second)
      .subtract(tz);
  return utc.millisecondsSinceEpoch;
}

/// 格式化节目时间为 `HH:mm`（UI 用）。
String formatEpgTime(int epochMs, {Duration? localOffset}) {
  final offset = localOffset ?? DateTime.now().timeZoneOffset;
  final local = DateTime.fromMillisecondsSinceEpoch(
    epochMs,
    isUtc: true,
  ).add(offset);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}