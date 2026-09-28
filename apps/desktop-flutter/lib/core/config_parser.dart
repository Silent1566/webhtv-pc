/// 配置解析：把 WebHTV/TVBox 顶层 JSON 转成 [AppConfig]。
///
/// 只做解析与归一化，不做网络与存储，覆盖设计文档 §7.1–§7.4：
/// - `msg` 键语义（§7.4.3）；
/// - `urls` 配置仓库识别（§7.4.2）；
/// - 站点 `jar` / 顶层 `spider` 优先级（§7.4.4）；
/// - 全局 `headers` 规则（§7.4.6）；
/// - 未知字段原样保留，导入不丢字段。
library;

import 'dart:convert';

import 'app_error.dart';
import 'protocol.dart';

/// 一份 JSON 文本的解析结果。
///
/// 要么是单配置（[config] 非空），要么是配置仓库（[repositoryEntries] 非空）。
class ConfigDocument {
  const ConfigDocument({
    this.config,
    this.repositoryEntries = const [],
    this.diagnostics = const [],
    this.raw = const {},
  });

  final AppConfig? config;
  final List<ConfigRepositoryEntry> repositoryEntries;

  /// 解析过程中产生的、不影响导入成功的说明（例如跳过非法站点、旧式 URL 条目）。
  final List<String> diagnostics;

  /// 原始 JSON 对象，用于原样保存未知字段。
  final Map<String, Object?> raw;

  bool get isRepository => config == null && repositoryEntries.isNotEmpty;
}

/// 解析配置 JSON 文本。
///
/// 抛出 [AppError]，其中 `msg` 非空配置使用 [AppErrorKind.configMsg]，
/// 以便 UI 展示配置自带的原始错误文本（§7.4.3）。
ConfigDocument parseConfigDocument(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    throw AppError(
      AppErrorKind.configInvalid,
      'JSON 解析失败',
      detail: '${error.message}（offset=${error.offset}）',
      cause: error,
    );
  }

  if (decoded is! Map) {
    throw AppError(
      AppErrorKind.configInvalid,
      '配置根节点必须是 JSON 对象',
      detail: '实际类型：${decoded.runtimeType}',
    );
  }

  final map = asMap(decoded);
  // §7.4.3：存在 `msg` 键即按兼容语义拒绝加载，即使值为空串。
  if (map.containsKey('msg')) {
    final message = asNonEmptyString(map['msg']);
    throw AppError(
      AppErrorKind.configMsg,
      message ?? '配置未提供错误详情（msg 为空）',
      detail: 'msg',
    );
  }

  final diagnostics = <String>[];

  final repositoryEntries = _parseRepositoryEntries(map['urls'], diagnostics);
  final sites = _parseSites(map['sites'], diagnostics);

  if (sites.isEmpty && repositoryEntries.isNotEmpty) {
    // 仓库配置：不合并为一个配置，交给加载器按条目展开（§7.4.2）。
    return ConfigDocument(
      repositoryEntries: repositoryEntries,
      diagnostics: diagnostics,
      raw: map,
    );
  }

  if (sites.isEmpty) {
    throw AppError(
      AppErrorKind.configInvalid,
      '配置中没有可用站点',
      detail: 'sites 为空且未提供 urls 仓库',
    );
  }

  return ConfigDocument(
    config: _buildConfig(map, sites, repositoryEntries, diagnostics),
    repositoryEntries: repositoryEntries,
    diagnostics: diagnostics,
    raw: map,
  );
}

List<Site> _parseSites(Object? value, List<String> diagnostics) {
  final sites = <Site>[];
  final seenKeys = <String>{};
  for (final item in asList(value)) {
    final site = Site.fromJson(item);
    if (site == null) {
      diagnostics.add('跳过缺少 key/name/type/api 的站点条目');
      continue;
    }
    if (!seenKeys.add(site.key)) {
      diagnostics.add('跳过重复站点 key=${site.key}');
      continue;
    }
    sites.add(site);
  }
  return sites;
}

List<ConfigRepositoryEntry> _parseRepositoryEntries(
  Object? value,
  List<String> diagnostics,
) {
  final entries = <ConfigRepositoryEntry>[];
  for (final item in asList(value)) {
    if (item is String) {
      final url = asNonEmptyString(item);
      if (url == null) continue;
      diagnostics.add('urls 使用纯字符串条目已弃用，请改为 {name, url}：$url');
      entries.add(ConfigRepositoryEntry(url: url));
      continue;
    }
    final entry = ConfigRepositoryEntry.fromJson(item);
    if (entry == null) {
      diagnostics.add('跳过缺少 url 的仓库条目');
      continue;
    }
    entries.add(entry);
  }
  return entries;
}

AppConfig _buildConfig(
  Map<String, Object?> map,
  List<Site> sites,
  List<ConfigRepositoryEntry> repositoryEntries,
  List<String> diagnostics,
) {
  final headers = <HeaderRule>[];
  for (final item in asList(map['headers'])) {
    final rule = HeaderRule.fromJson(item);
    if (rule == null) {
      diagnostics.add('跳过缺少 host 的全局 headers 规则');
      continue;
    }
    headers.add(rule);
  }

  final parses = <ParseEntry>[];
  for (final item in asList(map['parses'])) {
    final entry = ParseEntry.fromJson(item);
    if (entry == null) {
      diagnostics.add('跳过缺少 name 的解析器条目');
      continue;
    }
    parses.add(entry);
  }

  final flags = asList(
    map['flags'],
  ).map(asNonEmptyString).whereType<String>().toList();

  final known = <String>{
    'name',
    'spider',
    'sites',
    'parses',
    'flags',
    'lives',
    'doh',
    'proxy',
    'hosts',
    'headers',
    'rules',
    'hlsRules',
    'groupRules',
    'ads',
    'wallpaper',
    'logo',
    'notice',
    'home',
    'parse',
    'urls',
    'msg',
  };
  final extra = <String, Object?>{};
  for (final entry in map.entries) {
    if (!known.contains(entry.key)) extra[entry.key] = entry.value;
  }

  return AppConfig(
    name: asNonEmptyString(map['name']),
    spider: asNonEmptyString(map['spider']),
    sites: sites,
    parses: parses,
    flags: flags,
    lives: asList(map['lives']),
    doh: asList(map['doh']),
    proxy: asList(map['proxy']),
    hosts: asList(map['hosts']),
    headers: headers,
    rules: asList(map['rules']),
    hlsRules: asList(map['hlsRules']),
    groupRules: asList(map['groupRules']),
    ads: asList(map['ads']),
    wallpaper: asNonEmptyString(map['wallpaper']),
    logo: asNonEmptyString(map['logo']),
    notice: asNonEmptyString(map['notice']),
    home: asNonEmptyString(map['home']),
    parse: asNonEmptyString(map['parse']),
    urls: repositoryEntries,
    msg: asNonEmptyString(map['msg']),
    hasMsgKey: map.containsKey('msg'),
    extra: extra,
  );
}
