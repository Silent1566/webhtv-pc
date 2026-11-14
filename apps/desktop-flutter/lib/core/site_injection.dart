/// 站点注入（`docs/phase9/README.md` P1-2）。
///
/// 三件事：
/// 1. **宽松识别**：粘贴的一段文本可以是单个站点 JSON、数组、或首尾相接的多个 JSON；
/// 2. **合并**：把启用的注入站点并入当前配置的站点列表（同 key 覆盖、其余追加），
///    但**不改写**用户导入的配置源文件/配置记录；
/// 3. **校验**：没有 `key`/`name`/`api` 的条目不收，避免注入出一个点不开的站点。
library;

import 'dart:convert';

import 'protocol.dart';

/// 一条注入站点（持久化单位）。
class InjectedSiteEntry {
  const InjectedSiteEntry({
    required this.site,
    this.enabled = true,
    required this.updatedAt,
  });

  final Site site;
  final bool enabled;
  final int updatedAt;

  String get key => site.key;

  InjectedSiteEntry copyWith({Site? site, bool? enabled, int? updatedAt}) =>
      InjectedSiteEntry(
        site: site ?? this.site,
        enabled: enabled ?? this.enabled,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'site': site.toJson(),
    'enabled': enabled,
    'updatedAt': updatedAt,
  };

  factory InjectedSiteEntry.fromJson(Object? raw) {
    final map = asMap(raw);
    final site = Site.fromJson(map['site']);
    if (site == null) {
      throw const FormatException('注入站点缺少 site 对象');
    }
    return InjectedSiteEntry(
      site: site,
      enabled: map['enabled'] is bool ? map['enabled'] as bool : true,
      updatedAt:
          asInt(map['updatedAt']) ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  factory InjectedSiteEntry.fromRow(Map<String, Object?> row) {
    final raw = row['json'];
    final decoded = raw is String ? jsonDecode(raw) : raw;
    final site = Site.fromJson(decoded);
    if (site == null) {
      throw const FormatException('注入站点记录损坏');
    }
    return InjectedSiteEntry(
      site: site,
      enabled: (asInt(row['enabled']) ?? 1) != 0,
      updatedAt: asInt(row['updated_at']) ?? 0,
    );
  }
}

/// 宽松识别：从自由文本里抽出所有可解析的站点对象。
///
/// 顺序：整体 JSON → 逐行 → 括号配对。任何片段解析失败都跳过并继续，
/// 不因一个坏片段丢掉整段文本。
List<Map<String, Object?>> parseSiteJsonFragments(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];

  final direct = _tryDecode(trimmed);
  if (direct != null) {
    final flattened = _flatten(direct);
    if (flattened.isNotEmpty) return flattened;
  }

  final objects = <Map<String, Object?>>[];
  final seen = <String>{};

  void addDecoded(Object? decoded) {
    for (final map in _flatten(decoded)) {
      final encoded = jsonEncode(map);
      if (!seen.add(encoded)) continue;
      objects.add(map);
    }
  }

  // 1) 逐行：覆盖「每行一个 JSON」「尾随逗号」这类最常见粘贴形态。
  for (final line in trimmed.split(RegExp(r'\r?\n'))) {
    final candidate = line.trim();
    if (candidate.length < 2 || !candidate.startsWith('{')) continue;
    final decoded = _tryDecode(candidate);
    if (decoded != null) addDecoded(decoded);
  }

  // 2) 括号配对：覆盖跨行 JSON。坏片段不闭合时不会产出候选，因此不会吞掉后面的好片段。
  var depth = 0;
  var start = -1;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < trimmed.length; i++) {
    final char = trimmed[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }
    if (char == '"') {
      inString = true;
      continue;
    }
    if (char == '{') {
      if (depth == 0) start = i;
      depth += 1;
    } else if (char == '}') {
      if (depth > 0) {
        depth -= 1;
        if (depth == 0 && start >= 0) {
          final decoded = _tryDecode(trimmed.substring(start, i + 1));
          if (decoded != null) addDecoded(decoded);
          start = -1;
        }
      }
    }
  }
  return objects;
}

/// 识别并校验为可注入的站点。
///
/// 校验规则：
/// - 必须有 `key`（或 `name`）与 `name`（协议允许 key 缺省时取 name）；
/// - `api` 不能为空（没有执行入口的站点注入后只会显示“不可用”）；
/// - 同一批里 key 重复时后者覆盖前者。
List<Site> parseInjectedSites(String text) {
  final sites = <String, Site>{};
  for (final map in parseSiteJsonFragments(text)) {
    final site = Site.fromJson(map);
    if (site == null) continue;
    if (site.key.trim().isEmpty || site.name.trim().isEmpty) continue;
    if (site.api.trim().isEmpty) continue;
    sites[site.key] = site;
  }
  return sites.values.toList();
}

Object? _tryDecode(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    // 容忍尾随逗号（从网页复制时常见）；再失败就放弃这一段。
    final cleaned = text.replaceAllMapped(
      RegExp(r',\s*([}\]])'),
      (match) => match.group(1) ?? '',
    );
    try {
      return jsonDecode(cleaned);
    } catch (_) {
      return null;
    }
  }
}

List<Map<String, Object?>> _flatten(Object? decoded) {
  final result = <Map<String, Object?>>[];
  void visit(Object? value) {
    if (value is List) {
      for (final item in value) {
        visit(item);
      }
      return;
    }
    if (value is Map) {
      final sites = value['sites'];
      if (sites is List) {
        visit(sites);
        return;
      }
      final data = value['data'];
      if (data is Map && data['sites'] is List) {
        visit(data['sites']);
        return;
      }
      result.add(Map<String, Object?>.from(value));
    }
  }

  visit(decoded);
  return result;
}

/// 把启用的注入站点并入配置（同 key 覆盖，其余追加）。
///
/// 返回**新对象**：调用方不得把结果写回配置记录，否则会把注入站点固化进
/// 用户导入的配置。
AppConfig mergeInjectedSites(
  AppConfig config,
  Iterable<InjectedSiteEntry> injected,
) {
  final enabled = [
    for (final entry in injected)
      if (entry.enabled) entry.site,
  ];
  if (enabled.isEmpty) return config;
  final sites = List<Site>.of(config.sites);
  for (final site in enabled) {
    final index = sites.indexWhere((item) => item.key == site.key);
    if (index >= 0) {
      sites[index] = site;
    } else {
      sites.add(site);
    }
  }
  return AppConfig(
    name: config.name,
    spider: config.spider,
    sites: sites,
    parses: config.parses,
    flags: config.flags,
    lives: config.lives,
    doh: config.doh,
    proxy: config.proxy,
    hosts: config.hosts,
    headers: config.headers,
    rules: config.rules,
    hlsRules: config.hlsRules,
    groupRules: config.groupRules,
    ads: config.ads,
    wallpaper: config.wallpaper,
    logo: config.logo,
    notice: config.notice,
    home: config.home,
    parse: config.parse,
    urls: config.urls,
    msg: config.msg,
    hasMsgKey: config.hasMsgKey,
    extra: config.extra,
  );
}
