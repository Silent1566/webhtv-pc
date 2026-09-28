/// 直播清单解析（设计文档 §13.3，与 WebHTV Android `api/parser/LiveParser.java`
/// 及 `docs/integration/live.md` 对齐）。
///
/// 纯文本层：把 M3U / TXT / JSON 直播文本解析为 [LivePlaylist] 分组树，不依赖
/// Flutter、不发网络请求，便于用固定 fixture 做组合测试。
///
/// 格式识别与合并语义（对齐 WebHTV）：
/// - 申明为 [LiveLineType.json] 或内容以 `[` 开头 → JSON；
/// - 含 `#EXTM3U` 且不含 `#genre#` → M3U，否则按 TXT；
/// - 频道在分组内按「名称」去重合并，同名频道追加线路（M3U/TXT）；
/// - 不含 `://` 的地址视为不可播放并丢弃；
/// - 名称以「更新时间/更新日期/update time/update date/last update」开头的
///   元频道行跳过；
/// - 申明为 JSON 但内容非法时抛 [AppError]（§8.4「不许把错误页当成功」），
///   不静默返回空列表。
library;

import 'dart:convert';

import 'app_error.dart';
import 'protocol.dart';

// ---------------------------------------------------------------------------
// 通用小工具
// ---------------------------------------------------------------------------

/// 解析 `key="value"` 形式的行内属性（键统一小写）。
Map<String, String> _attributeMap(String line) {
  final attributes = <String, String>{};
  final regex = RegExp(r'''([\w\-]+)\s*=\s*"([^"]*)"''');
  for (final match in regex.allMatches(line)) {
    attributes[match.group(1)!.toLowerCase()] = match.group(2)!.trim();
  }
  return attributes;
}

/// 频道名：取最后一个 `,` 之后的文本（WebHTV 模式 `.*,(.+?)$`）。
String _nameAfterComma(String line) {
  final index = line.lastIndexOf(',');
  return index < 0 ? '' : line.substring(index + 1).trim();
}

/// 元频道判定（WebHTV `isMetaChannel`）。
bool _isMetaChannel(String? name) {
  final text = (name ?? '').trim().toLowerCase();
  return text.startsWith('更新时间') ||
      text.startsWith('更新日期') ||
      text.startsWith('update time') ||
      text.startsWith('update date') ||
      text.startsWith('last update');
}

/// 可播放地址判定（WebHTV `isPlayableUrl`：必须含 `://`）。
bool _isPlayableUrl(String? url) {
  final text = (url ?? '').trim();
  return text.contains('://');
}

/// `Key=Value&Key2=Value2` 形式的 header 参数（值去引号）。
Map<String, String> _headerParams(String query) {
  final headers = <String, String>{};
  for (final part in query.trim().split('&')) {
    final index = part.indexOf('=');
    if (index <= 0) continue;
    final key = part.substring(0, index).trim();
    final value = part.substring(index + 1).trim().replaceAll('"', '');
    if (key.isEmpty) continue;
    headers[key] = value;
  }
  return headers;
}

/// 取 `key` 之后的文本（去引号），键大小写不敏感。
String _valueAfter(String line, String key) {
  final index = line.toLowerCase().indexOf(key.toLowerCase());
  if (index < 0) return '';
  return line
      .substring(index + key.length)
      .trim()
      .replaceAll('"', '');
}

// ---------------------------------------------------------------------------
// 可写构建草稿（最终对象不可变，构建期用草稿累加）
// ---------------------------------------------------------------------------

class _DraftChannel {
  _DraftChannel({
    required this.name,
    this.number,
    this.logo,
    this.epgId,
    required this.group,
  });

  final String name;
  int? number;
  String? logo;
  String? epgId;
  final String group;
  final List<String> urls = [];
  final Map<String, String> header = {};
  final Map<String, String> extras = {};

  LiveChannel toChannel() => LiveChannel(
    name: name,
    number: number,
    logo: logo,
    epgId: epgId,
    urls: List.unmodifiable(urls),
    group: group,
    header: HeaderMap(Map<String, Object?>.from(header)),
    extra: Map.unmodifiable(extras),
  );
}

class _DraftGroup {
  _DraftGroup(this.name);

  final String name;
  final List<_DraftChannel> channels = [];

  _DraftChannel findOrAdd(String name, String group) {
    for (final channel in channels) {
      if (channel.name == name) return channel;
    }
    final channel = _DraftChannel(name: name, group: group);
    channels.add(channel);
    return channel;
  }

  LiveGroup toGroup() => LiveGroup(
    name: name,
    channels: channels.map((channel) => channel.toChannel()).toList(),
  );
}

LivePlaylist _build(
  String sourceName,
  List<_DraftGroup> groups,
  int rawLines, {
  String? epg,
}) {
  // 分组内按频道号（无号视为最大）稳定排序；同号保持声明顺序。
  for (final group in groups) {
    final indexed = group.channels.indexed.toList();
    indexed.sort((a, b) {
      final na = a.$2.number ?? 0x7fffffff;
      final nb = b.$2.number ?? 0x7fffffff;
      if (na != nb) return na.compareTo(nb);
      return a.$1.compareTo(b.$1);
    });
    group.channels
      ..clear()
      ..addAll(indexed.map((entry) => entry.$2));
  }
  return LivePlaylist(
    sourceName: sourceName,
    groups: groups.map((group) => group.toGroup()).toList(),
    rawLines: rawLines,
    epg: epg,
  );
}

// ---------------------------------------------------------------------------
// 顶层入口
// ---------------------------------------------------------------------------

/// 把直播文本解析为 [LivePlaylist]。
///
/// [sourceName] 仅用于诊断（配置 `lives[].name` 或文件名）。
/// [declaredType] 申明 [LiveLineType.json] 时强制按 JSON 解析。
LivePlaylist parseLivePlaylist(
  String sourceName,
  String text, {
  int? declaredType,
}) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '');
  final rawLines = normalized.isEmpty ? 0 : normalized.split('\n').length;
  final trimmed = normalized.trimLeft();

  // JSON 可以是数组（`[`）或对象（`{`，含 `{"groups":[...]}` / `{code:0,data:...}` 信封）。
  // 只按 `[` 判断会漏掉整个对象形态，导致 JSON 被误当 M3U/TXT 解析。
  if (declaredType == LiveLineType.json ||
      trimmed.startsWith('[') ||
      trimmed.startsWith('{')) {
    return _parseJson(sourceName, normalized, rawLines);
  }
  if (trimmed.contains('#EXTM3U') && !trimmed.contains('#genre#')) {
    return _parseM3u(sourceName, normalized, rawLines);
  }
  return _parseTxt(sourceName, normalized, rawLines);
}

// ---------------------------------------------------------------------------
// M3U
// ---------------------------------------------------------------------------

LivePlaylist _parseM3u(String sourceName, String text, int rawLines) {
  final groups = <_DraftGroup>[];
  var epg = '';
  _DraftChannel? current;
  final pendingHeaders = <String, String>{};

  _DraftGroup group(String name) {
    final groupName = name.isEmpty ? '未分组' : name;
    for (final item in groups) {
      if (item.name == groupName) return item;
    }
    final created = _DraftGroup(groupName);
    groups.add(created);
    return created;
  }

  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    if (trimmed.startsWith('#EXTM3U')) {
      final attributes = _attributeMap(trimmed);
      if (epg.isEmpty) {
        epg = attributes['tvg-url'] ?? attributes['url-tvg'] ?? '';
      }
      continue;
    }

    if (trimmed.startsWith('#EXTINF:')) {
      final attributes = _attributeMap(trimmed);
      final name = _nameAfterComma(trimmed);
      if (_isMetaChannel(name)) {
        current = null;
        continue;
      }
      final groupName = attributes['group-title'] ?? '';
      final draft = group(groupName);
      final channel = draft.findOrAdd(name, draft.name);
      if (attributes['tvg-chno'] != null) {
        channel.number = int.tryParse(attributes['tvg-chno']!);
      }
      channel.logo ??= attributes['tvg-logo'];
      channel.epgId ??= attributes['tvg-id'];
      if (attributes['tvg-name'] != null) {
        channel.extras['tvgName'] = attributes['tvg-name']!;
      }
      if (attributes['http-user-agent'] != null) {
        channel.extras['ua'] = attributes['http-user-agent']!;
      }
      current = channel;
      continue;
    }

    // 行级流设置：作用于随后的频道 URL。
    if (trimmed.startsWith('#EXTVLCOPT:')) {
      final lowered = trimmed.toLowerCase();
      if (lowered.contains('http-user-agent=')) {
        pendingHeaders['User-Agent'] = _valueAfter(trimmed, 'http-user-agent=');
      } else if (lowered.contains('http-referrer=')) {
        pendingHeaders['Referer'] = _valueAfter(trimmed, 'http-referrer=');
      } else if (lowered.contains('http-origin=')) {
        pendingHeaders['Origin'] = _valueAfter(trimmed, 'http-origin=');
      } else if (lowered.contains('http-cookie=')) {
        pendingHeaders['Cookie'] = _valueAfter(trimmed, 'http-cookie=');
      }
      continue;
    }

    if (trimmed.startsWith('#EXTHTTP:')) {
      final index = trimmed.indexOf(':');
      try {
        final decoded = jsonDecode(trimmed.substring(index + 1).trim());
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            pendingHeaders[entry.key.toString()] = entry.value.toString();
          }
        }
      } on FormatException {
        // 非 JSON header 行忽略（WebHTV 同样 try/catch 吞掉）。
      }
      continue;
    }

    if (trimmed.startsWith('#KODIPROP:')) {
      final index = trimmed.indexOf('=');
      if (index > 0) {
        pendingHeaders.addAll(_headerParams(trimmed.substring(index + 1)));
      }
      continue;
    }

    if (trimmed.startsWith('#')) continue;

    // 频道 URL 行：`url|header参数`。
    final bar = trimmed.indexOf('|');
    final url = (bar < 0 ? trimmed : trimmed.substring(0, bar)).trim();
    if (!_isPlayableUrl(url)) continue;
    final channel = current;
    if (channel == null) continue;
    channel.urls.add(url);
    if (bar >= 0) {
      pendingHeaders.addAll(_headerParams(trimmed.substring(bar + 1)));
    }
    if (pendingHeaders.isNotEmpty) {
      channel.header.addAll(pendingHeaders);
      pendingHeaders.clear();
    }
  }

  return _build(sourceName, groups, rawLines, epg: epg.isEmpty ? null : epg);
}

// ---------------------------------------------------------------------------
// TXT
// ---------------------------------------------------------------------------

LivePlaylist _parseTxt(String sourceName, String text, int rawLines) {
  final groups = <_DraftGroup>[];
  _DraftGroup? lastGroup;

  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    final comma = trimmed.indexOf(',');
    final name = (comma < 0 ? trimmed : trimmed.substring(0, comma)).trim();
    final rest = comma < 0 ? '' : trimmed.substring(comma + 1).trim();

    if (trimmed.contains('#genre#')) {
      final groupName = name.isEmpty ? '未分组' : name;
      if (groups.isEmpty || groups.last.name != groupName) {
        groups.add(_DraftGroup(groupName));
      }
      lastGroup = groups.last;
      continue;
    }
    if (rest.isEmpty || _isMetaChannel(name)) continue;

    if (lastGroup == null) {
      groups.add(_DraftGroup('未分组'));
      lastGroup = groups.last;
    }
    // 先收集本行有效线路；一条都没有（例如地址不含 `://`）时不创建空壳频道。
    final collected = <String>[];
    final collectedHeaders = <String, String>{};
    for (final rawUrl in rest.split('#')) {
      final urlText = rawUrl.trim();
      if (urlText.isEmpty) continue;
      final bar = urlText.indexOf('|');
      final url = (bar < 0 ? urlText : urlText.substring(0, bar)).trim();
      if (!_isPlayableUrl(url)) continue;
      collected.add(url);
      if (bar >= 0) {
        collectedHeaders.addAll(_headerParams(urlText.substring(bar + 1)));
      }
    }
    if (collected.isEmpty) continue;
    final channel = lastGroup.findOrAdd(name, lastGroup.name);
    channel.urls.addAll(collected);
    channel.header.addAll(collectedHeaders);
  }

  return _build(sourceName, groups, rawLines);
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

LivePlaylist _parseJson(String sourceName, String text, int rawLines) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw AppError(
      AppErrorKind.liveInvalid,
      '$sourceName 直播内容不是有效 JSON',
      detail: '申明为 JSON 直播源但内容非法',
    );
  }

  final List<Object?>? rawGroups = switch (decoded) {
    List list => list,
    Map map when map['groups'] is List => map['groups'] as List,
    // TVBox/WebHTV 信封形态：`{code:0,data:[...]}` 或 `{data:{groups:[...]}}`。
    Map map when map['data'] is List => map['data'] as List,
    Map map when map['data'] is Map && (map['data'] as Map)['groups'] is List =>
      (map['data'] as Map)['groups'] as List,
    _ => null,
  };
  if (rawGroups == null) {
    throw AppError(
      AppErrorKind.liveInvalid,
      '$sourceName 直播内容没有可解析的 JSON 分组',
      detail: '期望 JSON 数组、{"groups":[...]} 或 {code,data} 信封',
    );
  }

  final groups = <_DraftGroup>[];
  for (final rawGroup in rawGroups) {
    final map = asMap(rawGroup);
    final groupName = asNonEmptyString(map['name']) ?? '未分组';
    final draft = _DraftGroup(groupName);
    for (final rawChannel in asList(map['channel'])) {
      final channelMap = asMap(rawChannel);
      final channel = _DraftChannel(
        name: asNonEmptyString(channelMap['name']) ?? '未知频道',
        number: asInt(channelMap['number']),
        logo: asNonEmptyString(channelMap['logo']),
        epgId:
            asNonEmptyString(channelMap['tvgId']) ??
            asNonEmptyString(channelMap['tvg_id']) ??
            asNonEmptyString(channelMap['epgId']),
        group: groupName,
      );
      for (final rawUrl in asList(channelMap['urls'])) {
        final url = (asString(rawUrl) ?? '').trim();
        if (_isPlayableUrl(url)) channel.urls.add(url);
      }
      for (final key in const [
        'epg',
        'ua',
        'origin',
        'referer',
        'tvgName',
        'format',
        'click',
      ]) {
        final value = asNonEmptyString(channelMap[key]);
        if (value != null) channel.extras[key] = value;
      }
      draft.channels.add(channel);
    }
    groups.add(draft);
  }

  // 空频道号按顺序生成编号（WebHTV `apply`）。
  var number = 0;
  for (final group in groups) {
    for (final channel in group.channels) {
      if (channel.number == null) {
        channel.number = ++number;
      } else if (channel.number! > number) {
        number = channel.number!;
      }
    }
  }

  return _build(sourceName, groups, rawLines);
}
