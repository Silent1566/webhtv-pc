/// WebHTV PC 核心协议模型：配置、站点、Result/Vod、解析器、播放结果。
///
/// 本文件只描述数据，不依赖 Flutter，也不发网络请求，便于单元测试直接覆盖
/// 设计文档 §7、§8 的字段语义。
library;

import 'dart:convert';

// ---------------------------------------------------------------------------
// JSON 取值工具：配置文件与站点数据大量使用字符串/数字混用字段（TVBox 生态
// 常见），因此统一做宽松归一化，避免因类型差异导致整份配置导入失败。
// ---------------------------------------------------------------------------

/// 宽松读取字符串：数字、布尔、null 均按协议惯例转换。
String? asString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return null;
}

/// 读取字符串，缺失或空串返回 null。
String? asNonEmptyString(Object? value) {
  final text = asString(value);
  if (text == null) return null;
  final trimmed = text.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is bool) return value ? 1 : 0;
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed) ?? double.tryParse(trimmed)?.toInt();
  }
  return null;
}

/// TVBox 的 `0/1` 与 `true/false` 混用开关字段。
bool asFlag(Object? value, {bool fallback = false}) {
  final number = asInt(value);
  if (number != null) return number != 0;
  if (value is String) {
    final lowered = value.trim().toLowerCase();
    if (lowered == 'true') return true;
    if (lowered == 'false') return false;
  }
  return fallback;
}

List<Object?> asList(Object? value) {
  if (value is List) return value;
  if (value == null) return const [];
  return [value];
}

Map<String, Object?> asMap(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return const {};
}

/// 头部字段名大小写不敏感，输出时保留首次出现的原始键名（设计要求 §7.4.6）。
class HeaderMap {
  HeaderMap([Map<String, Object?> source = const {}]) {
    for (final entry in source.entries) {
      final value = asString(entry.value);
      if (value == null || entry.key.trim().isEmpty) continue;
      put(entry.key, value);
    }
  }

  final Map<String, String> _byLowerCase = {};
  final Map<String, String> _originalKeys = {};

  /// 头部注入顺序固定为：全局 headers → 站点 header → 播放结果 header。
  /// 后者覆盖前者的同名键（大小写不敏感）。
  static HeaderMap merge(Iterable<HeaderMap?> layers) {
    final merged = HeaderMap();
    for (final layer in layers) {
      if (layer == null) continue;
      for (final entry in layer.entries) {
        merged.put(entry.key, entry.value);
      }
    }
    return merged;
  }

  void put(String key, String value) {
    final normalized = key.trim().toLowerCase();
    if (normalized.isEmpty) return;
    _byLowerCase[normalized] = value;
    _originalKeys.putIfAbsent(normalized, () => key.trim());
  }

  String? operator [](String key) => _byLowerCase[key.trim().toLowerCase()];

  bool containsKey(String key) => _byLowerCase.containsKey(key.trim().toLowerCase());

  bool get isEmpty => _byLowerCase.isEmpty;

  bool get isNotEmpty => _byLowerCase.isNotEmpty;

  int get length => _byLowerCase.length;

  Iterable<String> get keys => _originalKeys.values;

  /// 遍历键值对，键为原始键名。用于合并与日志。
  Iterable<MapEntry<String, String>> get entries => _byLowerCase.entries.map(
    (entry) => MapEntry(_originalKeys[entry.key] ?? entry.key, entry.value),
  );

  /// 用于 HTTP 请求的键值对，保留原始键名。
  Map<String, String> get asRequestHeaders {
    final result = <String, String>{};
    for (final entry in _byLowerCase.entries) {
      result[_originalKeys[entry.key] ?? entry.key] = entry.value;
    }
    return result;
  }

  /// 只列出 header 名称，不含值，用于日志与诊断脱敏（§9.3.1、§11.3）。
  List<String> get keyNames => _originalKeys.values.toList()..sort();

  Map<String, String> toJson() => asRequestHeaders;

  @override
  String toString() => 'HeaderMap(keys=${keyNames.join(",")})';
}

// ---------------------------------------------------------------------------
// 配置模型（§7.1、§7.2）
// ---------------------------------------------------------------------------

/// 顶层 `headers` 规则：按目标 host 匹配后注入请求 Header（§7.4.6）。
class HeaderRule {
  const HeaderRule({required this.host, required this.header});

  final String host;
  final HeaderMap header;

  /// host 匹配支持 `*` 通配与包含规则；无通配时按“完全相同或作为子域后缀”匹配。
  bool matches(String host) {
    final pattern = this.host.trim().toLowerCase();
    final target = host.trim().toLowerCase();
    if (pattern.isEmpty) return false;
    if (pattern == '*') return true;
    if (pattern.contains('*')) {
      final regex = RegExp(
        '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
      );
      return regex.hasMatch(target);
    }
    return target == pattern || target.endsWith('.$pattern');
  }

  static HeaderRule? fromJson(Object? value) {
    final map = asMap(value);
    final host = asNonEmptyString(map['host']);
    if (host == null) return null;
    return HeaderRule(host: host, header: HeaderMap(asMap(map['header'])));
  }
}

/// 解析器条目（§7.4.8、§12.1）。
class ParseEntry {
  const ParseEntry({
    required this.name,
    required this.type,
    this.url,
    this.ext,
    this.flag,
  });

  final String name;

  /// 0=JSON、1=Web 嗅探、2=JSON 扩展、3=Spider。
  final int type;

  final String? url;

  /// `ext` 可以是 JSON 字符串或对象，按原始结构保留。
  final Object? ext;

  /// 可选标识，用于 `flag` 匹配。
  final String? flag;

  static ParseEntry? fromJson(Object? value) {
    final map = asMap(value);
    final name = asNonEmptyString(map['name']);
    if (name == null) return null;
    return ParseEntry(
      name: name,
      type: asInt(map['type']) ?? 0,
      url: asNonEmptyString(map['url']),
      ext: map.containsKey('ext') ? map['ext'] : null,
      flag: asNonEmptyString(map['flag']),
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'type': type,
    if (url != null) 'url': url,
    if (ext != null) 'ext': ext,
    if (flag != null) 'flag': flag,
  };
}

/// 直播源（§13.2 `LiveSource`）。
///
/// 对应配置顶层 `lives` 数组条目：声明一个直播资源（通常是 M3U/TXT/JSON 清单或
/// 单个频道），由 [LiveLineType] 区分；`url` 可被 HTTP 拉取也可为本地文件。
class LiveSource {
  LiveSource({
    required this.name,
    required this.type,
    this.url,
    this.epg,
    this.proxy,
    this.referer,
    this.userAgent,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra);

  final String name;

  /// 直播清单/频道格式（见 [LiveLineType]）。
  final int type;

  final String? url;
  final String? epg;
  final String? proxy;
  final String? referer;
  final String? userAgent;

  /// 未识别字段在导入后原样保留。
  final Map<String, Object?> extra;

  static LiveSource? fromJson(Object? value) {
    final map = asMap(value);
    final name = asNonEmptyString(map['name']);
    if (name == null) return null;
    return LiveSource(
      name: name,
      type: asInt(map['type']) ?? LiveLineType.m3u,
      url: asNonEmptyString(map['url']),
      epg: asNonEmptyString(map['epg']),
      proxy: asNonEmptyString(map['proxy']),
      referer: asNonEmptyString(map['referer']),
      userAgent: asNonEmptyString(map['userAgent']),
      extra: {
        for (final entry in map.entries)
          if (!{'name', 'type', 'url', 'epg', 'proxy', 'referer', 'userAgent'}
              .contains(entry.key))
            entry.key: entry.value,
      },
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'name': name,
    'type': type,
    if (url != null) 'url': url,
    if (epg != null) 'epg': epg,
    if (proxy != null) 'proxy': proxy,
    if (referer != null) 'referer': referer,
    if (userAgent != null) 'userAgent': userAgent,
  };
}

/// 直播清单/频道格式标识（§13.3「直播格式」）。
///
/// 与 TVBox `lives[].type` 和设计文档 `LiveLineType` 对齐：
/// `1`=M3U、`2`=TXT、`3`=JSON。
abstract final class LiveLineType {
  static const int m3u = 1;
  static const int txt = 2;
  static const int json = 3;
}

/// 直播频道（§13.2 `LiveChannel`）。
///
/// 一个频道可有多个线路 [urls]；播放失败时由上层按顺序尝试（§13.3
/// 「播放失败可切线路」、§10.3 换源）。
class LiveChannel {
  LiveChannel({
    required this.name,
    this.number,
    this.logo,
    this.epgId,
    List<String> urls = const [],
    this.group = '未分组',
    HeaderMap? header,
    Map<String, Object?> extra = const {},
  }) : urls = List.unmodifiable(urls),
       header = header ?? HeaderMap(),
       extra = Map.unmodifiable(extra);

  final String name;
  final int? number;
  final String? logo;
  final String? epgId;

  /// 频道线路（按声明顺序，第一个为默认）。
  final List<String> urls;

  /// 所属分组名（TXT/M3U 的 `group-title`）。
  final String group;

  /// 频道级请求头（来自 `#EXTVLCOPT`/`url|header`/JSON `header`）。
  final HeaderMap header;

  final Map<String, Object?> extra;

  static LiveChannel fromJson(Object? value) {
    final map = asMap(value);
    return LiveChannel(
      name: asNonEmptyString(map['name']) ?? '未知频道',
      number: asInt(map['number']),
      logo: asNonEmptyString(map['logo']),
      epgId: asNonEmptyString(map['epgId']),
      urls: asList(map['urls']).map((item) => asString(item) ?? '').toList(),
      group: asNonEmptyString(map['group']) ?? '未分组',
      header: HeaderMap(asMap(map['header'])),
      extra: {
        for (final entry in map.entries)
          if (!{'name', 'number', 'logo', 'epgId', 'urls', 'group', 'header'}
              .contains(entry.key))
            entry.key: entry.value,
      },
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'name': name,
    if (number != null) 'number': number,
    if (logo != null) 'logo': logo,
    if (epgId != null) 'epgId': epgId,
    if (urls.isNotEmpty) 'urls': urls,
    'group': group,
    if (header.isNotEmpty) 'header': header.toJson(),
  };
}

/// 直播分组（§13.2 `LiveGroup`）。
///
/// 频道按 `group-title`（M3U）/ 分组行（TXT）分组；未指定分组的频道进入
/// `未分组`。[groupName] 之外的频道由各 [LiveChannel.group] 携带，解析时聚拢。
class LiveGroup {
  LiveGroup({required this.name, List<LiveChannel> channels = const []})
    : channels = List.unmodifiable(channels);

  final String name;
  final List<LiveChannel> channels;

  Map<String, Object?> toJson() => {
    'name': name,
    'channels': channels.map((channel) => channel.toJson()).toList(),
  };
}

/// 直播清单解析结果：分组树 + 原始源引用。
///
/// 由直播解析器（§13.3）产出，供直播页分组展示与频道播放。
class LivePlaylist {
  LivePlaylist({
    required this.sourceName,
    List<LiveGroup> groups = const [],
    this.rawLines = 0,
    this.epg,
  }) : groups = List.unmodifiable(groups);

  /// 清单来源（配置 `lives[].name` 或文件名）。
  final String sourceName;

  /// 有序分组；未分组频道聚集在 `未分组` 组。
  final List<LiveGroup> groups;

  /// 原始清单行数（诊断用）。
  final int rawLines;

  /// 清单内申明的 EPG 地址（`#EXTM3U url-tvg`，§13.1 EPG）。
  final String? epg;

  int get channelCount => groups.fold(0, (sum, group) => sum + group.channels.length);

  /// 全部频道（展平），按分组顺序。
  List<LiveChannel> get allChannels => groups
      .expand((group) => group.channels)
      .toList();

  /// 按频道名分区查找（忽略大小写）。
  LiveChannel? channelById(String id) {
    final lowered = id.trim().toLowerCase();
    for (final channel in allChannels) {
      if (channel.name.toLowerCase() == lowered) return channel;
    }
    return null;
  }
}

/// 站点模型（§8.2）。未知字段通过 [extra] 原样保留，避免导入即丢字段。
class Site {
  Site({
    required this.key,
    required this.name,
    required this.type,
    required this.api,
    this.jar,
    this.ext,
    HeaderMap? header,
    this.timeoutSeconds,
    this.searchable = false,
    this.changeable = false,
    this.quickSearch = false,
    this.filterable = false,
    this.categories = const [],
    this.style,
    this.hide = false,
    this.indexs,
    Map<String, Object?> extra = const {},
  }) : header = header ?? HeaderMap(),
       extra = Map.unmodifiable(extra);

  final String key;
  final String name;

  /// 0=XML API、1=JSON API、2=JSON API 兼容、3=Spider、4=HTTP API + Base64 ext。
  final int type;

  final String api;
  final String? jar;
  final Object? ext;
  final HeaderMap header;
  final int? timeoutSeconds;
  final bool searchable;
  final bool changeable;
  final bool quickSearch;
  final bool filterable;
  final List<String> categories;
  final Object? style;
  final bool hide;
  final int? indexs;
  final Map<String, Object?> extra;

  static Site? fromJson(Object? value) {
    final map = asMap(value);
    final key = asNonEmptyString(map['key']) ?? asNonEmptyString(map['name']);
    final name = asNonEmptyString(map['name']) ?? key;
    if (key == null || name == null) return null;
    final known = <String>{
      'key',
      'name',
      'type',
      'api',
      'jar',
      'ext',
      'header',
      'timeout',
      'searchable',
      'changeable',
      'quickSearch',
      'filterable',
      'categories',
      'style',
      'hide',
      'indexs',
    };
    final extra = <String, Object?>{};
    for (final entry in map.entries) {
      if (!known.contains(entry.key)) extra[entry.key] = entry.value;
    }
    return Site(
      key: key,
      name: name,
      type: asInt(map['type']) ?? 0,
      api: asString(map['api']) ?? '',
      jar: asNonEmptyString(map['jar']),
      ext: map.containsKey('ext') ? map['ext'] : null,
      header: HeaderMap(asMap(map['header'])),
      timeoutSeconds: asInt(map['timeout']),
      searchable: asFlag(map['searchable']),
      changeable: asFlag(map['changeable']),
      quickSearch: asFlag(map['quickSearch']),
      filterable: asFlag(map['filterable']),
      categories: asList(map['categories'])
          .map(asNonEmptyString)
          .whereType<String>()
          .toList(),
      style: map['style'],
      hide: asFlag(map['hide']),
      indexs: asInt(map['indexs']),
      extra: extra,
    );
  }

  /// 解析优先级（§7.4.4）：站点 `jar` 优先，其次顶层 `spider`。
  String? effectiveJar(String? globalSpider) {
    final own = asNonEmptyString(jar);
    if (own != null) return own;
    return asNonEmptyString(globalSpider);
  }

  Map<String, Object?> toJson() => {
    'key': key,
    'name': name,
    'type': type,
    'api': api,
    if (jar != null) 'jar': jar,
    if (ext != null) 'ext': ext,
    if (header.isNotEmpty) 'header': header.toJson(),
    if (timeoutSeconds != null) 'timeout': timeoutSeconds,
    'searchable': searchable ? 1 : 0,
    'changeable': changeable ? 1 : 0,
    'quickSearch': quickSearch ? 1 : 0,
    if (filterable) 'filterable': 1,
    if (categories.isNotEmpty) 'categories': categories,
    if (style != null) 'style': style,
    if (hide) 'hide': 1,
    if (indexs != null) 'indexs': indexs,
    ...extra,
  };
}

/// 配置仓库条目（§7.4.2）。
class ConfigRepositoryEntry {
  const ConfigRepositoryEntry({this.name, required this.url});

  final String? name;
  final String url;

  static ConfigRepositoryEntry? fromJson(Object? value) {
    final direct = asNonEmptyString(value);
    if (direct != null) return ConfigRepositoryEntry(url: direct);
    final map = asMap(value);
    final url = asNonEmptyString(map['url']) ?? asNonEmptyString(map['api']);
    if (url == null) return null;
    return ConfigRepositoryEntry(name: asNonEmptyString(map['name']), url: url);
  }

  Map<String, Object?> toJson() => {'name': name ?? url, 'url': url};
}

/// 顶层配置（§7.1）。未识别字段保存在 [extra] 中，导入后原样回写。
class AppConfig {
  AppConfig({
    this.name,
    this.spider,
    this.sites = const [],
    this.parses = const [],
    this.flags = const [],
    this.lives = const [],
    this.doh = const [],
    this.proxy = const [],
    this.hosts = const [],
    this.headers = const [],
    this.rules = const [],
    this.hlsRules = const [],
    this.groupRules = const [],
    this.ads = const [],
    this.wallpaper,
    this.logo,
    this.notice,
    this.home,
    this.parse,
    this.urls = const [],
    this.msg,
    this.hasMsgKey = false,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra);

  final String? name;
  final String? spider;
  final List<Site> sites;
  final List<ParseEntry> parses;
  final List<String> flags;
  final List<LiveSource> lives;
  final List<Object?> doh;
  final List<Object?> proxy;
  final List<Object?> hosts;
  final List<HeaderRule> headers;
  final List<Object?> rules;
  final List<Object?> hlsRules;
  final List<Object?> groupRules;
  final List<Object?> ads;
  final String? wallpaper;
  final String? logo;
  final String? notice;
  final String? home;
  final String? parse;
  final List<ConfigRepositoryEntry> urls;

  /// 配置对象自身声明的错误信息（§7.4.3）。
  final String? msg;

  /// 是否存在 `msg` 键。
  ///
  /// Android 当前实现在配置对象存在 `msg` 键时直接抛错，即使值是空串也一样；
  /// 因此这里必须区分“键不存在”和“键存在但值为空”，不能只看 [msg] 是否为 null。
  final bool hasMsgKey;

  final Map<String, Object?> extra;

  /// 配置仓库：没有 `sites` 但有 `urls`（§7.4.2）。
  bool get isRepository => urls.isNotEmpty && sites.isEmpty;

  Map<String, Object?> toJson() => {
    ...extra,
    if (name != null) 'name': name,
    if (spider != null) 'spider': spider,
    'sites': sites.map((site) => site.toJson()).toList(),
    'parses': parses.map((entry) => entry.toJson()).toList(),
    if (flags.isNotEmpty) 'flags': flags,
    if (lives.isNotEmpty)
      'lives': lives.map((source) => source.toJson()).toList(),
    if (doh.isNotEmpty) 'doh': doh,
    if (proxy.isNotEmpty) 'proxy': proxy,
    if (hosts.isNotEmpty) 'hosts': hosts,
    if (headers.isNotEmpty)
      'headers': headers
          .map((rule) => {'host': rule.host, 'header': rule.header.toJson()})
          .toList(),
    if (rules.isNotEmpty) 'rules': rules,
    if (hlsRules.isNotEmpty) 'hlsRules': hlsRules,
    if (groupRules.isNotEmpty) 'groupRules': groupRules,
    if (ads.isNotEmpty) 'ads': ads,
    if (wallpaper != null) 'wallpaper': wallpaper,
    if (logo != null) 'logo': logo,
    if (notice != null) 'notice': notice,
    if (home != null) 'home': home,
    if (parse != null) 'parse': parse,
    if (urls.isNotEmpty) 'urls': urls.map((entry) => entry.toJson()).toList(),
    if (msg != null) 'msg': msg,
  };

  /// 默认站点 key（§7.2 `home`）。
  Site? defaultSite() {
    final target = asNonEmptyString(home);
    if (target != null) {
      for (final site in sites) {
        if (site.key == target || site.name == target) return site;
      }
    }
    for (final site in sites) {
      if (!site.hide) return site;
    }
    return sites.isEmpty ? null : sites.first;
  }

  AppConfig copyWith({
    String? name,
    String? spider,
    List<Site>? sites,
    List<ParseEntry>? parses,
    String? notice,
    String? home,
    String? parse,
    List<ConfigRepositoryEntry>? urls,
    String? msg,
    bool? hasMsgKey,
  }) {
    return AppConfig(
      name: name ?? this.name,
      spider: spider ?? this.spider,
      sites: sites ?? this.sites,
      parses: parses ?? this.parses,
      flags: flags,
      lives: lives,
      doh: doh,
      proxy: proxy,
      hosts: hosts,
      headers: headers,
      rules: rules,
      hlsRules: hlsRules,
      groupRules: groupRules,
      ads: ads,
      wallpaper: wallpaper,
      logo: logo,
      notice: notice ?? this.notice,
      home: home ?? this.home,
      parse: parse ?? this.parse,
      urls: urls ?? this.urls,
      msg: msg ?? this.msg,
      hasMsgKey: hasMsgKey ?? this.hasMsgKey,
      extra: extra,
    );
  }
}

// ---------------------------------------------------------------------------
// Result / Vod 模型（§8.3）
// ---------------------------------------------------------------------------

/// 分类条目。
class VodClass {
  const VodClass({required this.typeId, required this.typeName});

  final String typeId;
  final String typeName;

  static VodClass? fromJson(Object? value) {
    final map = asMap(value);
    final id = asNonEmptyString(map['type_id']) ?? asNonEmptyString(map['typeId']);
    final name =
        asNonEmptyString(map['type_name']) ?? asNonEmptyString(map['typeName']);
    if (id == null || name == null) return null;
    return VodClass(typeId: id, typeName: name);
  }
}

/// 分类筛选项（`type=1/2/4` 的 `filters`）。
class VodFilterOption {
  const VodFilterOption({required this.name, required this.value});

  final String name;
  final String value;

  static VodFilterOption? fromJson(Object? value) {
    final map = asMap(value);
    final name = asNonEmptyString(map['n']) ?? asNonEmptyString(map['name']);
    if (name == null) return null;
    return VodFilterOption(name: name, value: asString(map['v']) ?? '');
  }
}

class VodFilterGroup {
  const VodFilterGroup({
    required this.key,
    required this.name,
    required this.options,
  });

  final String key;
  final String name;
  final List<VodFilterOption> options;

  static VodFilterGroup? fromJson(Object? value) {
    final map = asMap(value);
    final key = asNonEmptyString(map['key']);
    if (key == null) return null;
    return VodFilterGroup(
      key: key,
      name: asNonEmptyString(map['name']) ?? key,
      options: asList(map['value'])
          .map(VodFilterOption.fromJson)
          .whereType<VodFilterOption>()
          .toList(),
    );
  }
}

/// 影视条目。
class Vod {
  Vod({
    required this.vodId,
    required this.vodName,
    this.vodPic,
    this.vodRemarks,
    this.vodContent,
    this.vodArea,
    this.vodYear,
    this.vodDirector,
    this.vodActor,
    this.vodPlayFrom,
    this.vodPlayUrl,
    this.vodTag,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra);

  final String vodId;
  final String vodName;
  final String? vodPic;
  final String? vodRemarks;
  final String? vodContent;
  final String? vodArea;
  final String? vodYear;
  final String? vodDirector;
  final String? vodActor;

  /// 线路标记，`$$$` 分隔。
  final String? vodPlayFrom;

  /// 剧集地址，`$$$` 分隔线路，`#` 分隔剧集，`剧集名$地址` 组成一部剧集。
  final String? vodPlayUrl;

  /// 条目类型（TVBox 约定）：`folder` = 目录（需用 `t=<vod_id>` 展开）、
  /// `file` = 终态条目（可直接播）。
  ///
  /// **为什么必须单独建模**：网盘聚合类站源（实测 170 站点里 93 个共用
  /// `spring.jar`）的分类只返回 `folder` 壳，真正的分享链接在展开后的
  /// `file` 条目里。把 `folder` 当普通条目调 `ids=` 详情接口只会得到空壳
  /// （实测 `vod_name` 为空、`vod_play_url` 为空）。
  final String? vodTag;

  /// 是否为目录条目（需展开而不是直接取详情）。
  bool get isFolder => vodTag == 'folder';

  final Map<String, Object?> extra;

  static Vod? fromJson(Object? value) {
    final map = asMap(value);
    final id = asNonEmptyString(map['vod_id']) ?? asNonEmptyString(map['vodId']);
    final name =
        asNonEmptyString(map['vod_name']) ?? asNonEmptyString(map['vodName']);
    if (id == null || name == null) return null;
    final known = <String>{
      'vod_id',
      'vodId',
      'vod_name',
      'vodName',
      'vod_pic',
      'vod_remarks',
      'vod_content',
      'vod_area',
      'vod_year',
      'vod_director',
      'vod_actor',
      'vod_play_from',
      'vod_play_url',
      'vod_tag',
      'vodTag',
    };
    final extra = <String, Object?>{};
    for (final entry in map.entries) {
      if (!known.contains(entry.key)) extra[entry.key] = entry.value;
    }
    return Vod(
      vodId: id,
      vodName: name,
      vodPic: asNonEmptyString(map['vod_pic']),
      vodRemarks: asNonEmptyString(map['vod_remarks']),
      vodContent: asNonEmptyString(map['vod_content']),
      vodArea: asNonEmptyString(map['vod_area']),
      vodYear: asNonEmptyString(map['vod_year']),
      vodDirector: asNonEmptyString(map['vod_director']),
      vodActor: asNonEmptyString(map['vod_actor']),
      vodPlayFrom: asNonEmptyString(map['vod_play_from']),
      vodPlayUrl: asNonEmptyString(map['vod_play_url']),
      vodTag: asNonEmptyString(map['vod_tag']) ?? asNonEmptyString(map['vodTag']),
      extra: extra,
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'vod_id': vodId,
    'vod_name': vodName,
    if (vodPic != null) 'vod_pic': vodPic,
    if (vodRemarks != null) 'vod_remarks': vodRemarks,
    if (vodContent != null) 'vod_content': vodContent,
    if (vodArea != null) 'vod_area': vodArea,
    if (vodYear != null) 'vod_year': vodYear,
    if (vodDirector != null) 'vod_director': vodDirector,
    if (vodActor != null) 'vod_actor': vodActor,
    if (vodPlayFrom != null) 'vod_play_from': vodPlayFrom,
    if (vodPlayUrl != null) 'vod_play_url': vodPlayUrl,
  };
}

/// 一条线路及其剧集。
class VodPlayLine {
  const VodPlayLine({required this.flag, required this.episodes});

  final String flag;
  final List<VodEpisode> episodes;

  String get displayName => flag.isEmpty ? '线路' : flag;

  Map<String, Object?> toJson() => {
    'flag': flag,
    'episodes': episodes.map((episode) => episode.toJson()).toList(),
  };
}

class VodEpisode {
  VodEpisode({
    required this.name,
    required this.url,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra);

  final String name;
  final String url;

  /// 未知字段与 TMDB 富集结果的承载（§27）。
  ///
  /// TMDB 富集写入 `display_name` / `tmdb_season_number` / `tmdb_episode_number`；
  /// 原始终源字段不受影响。
  final Map<String, Object?> extra;

  VodEpisode copyWith({String? name, String? url, Map<String, Object?>? extra}) =>
      VodEpisode(
        name: name ?? this.name,
        url: url ?? this.url,
        extra: extra ?? this.extra,
      );

  Map<String, Object?> toJson() => {
    ...extra,
    'name': name,
    'url': url,
  };
}

/// 外挂字幕（§10.3「外挂字幕」「字幕轨选择」）。
///
/// 字段与 WebHTV/TVBox 播放结果里的 `subs` 数组逐一对齐（Android 侧为
/// `com.fongmi.android.tv.bean.Sub`）：`url`、`name`、`lang`、`format`、`flag`。
/// `flag` 沿用 media3 的 `C.SELECTION_FLAG_*` 位语义，`0` 视为默认字幕。
class SubtitleInfo {
  const SubtitleInfo({
    required this.url,
    this.name = '',
    this.lang = '',
    this.format = '',
    this.flag = 0,
  });

  final String url;
  final String name;
  final String lang;
  final String format;

  /// 选择标志位（media3 语义）：`flag == 0` 视为 [selectionFlagDefault]。
  final int flag;

  /// media3 `C.SELECTION_FLAG_DEFAULT`。
  static const int selectionFlagDefault = 1;

  /// media3 `C.SELECTION_FLAG_FORCED`。
  static const int selectionFlagForced = 2;

  /// media3 `C.SELECTION_FLAG_AUTOSELECT`。
  static const int selectionFlagAutoSelect = 4;

  /// `flag == 0` 时按媒体生态惯例视为“默认字幕”。
  int get effectiveFlag => flag == 0 ? selectionFlagDefault : flag;

  bool get isDefault => (effectiveFlag & selectionFlagDefault) != 0;
  bool get isForced => (flag & selectionFlagForced) != 0;
  bool get isAutoSelect => (effectiveFlag & selectionFlagAutoSelect) != 0;

  /// 播放器菜单里的展示名：名称 → 语言 → 地址末段。
  String get displayName {
    if (name.isNotEmpty) return name;
    if (lang.isNotEmpty) return lang;
    return url.isEmpty ? '外挂字幕' : url.split('/').last;
  }

  static SubtitleInfo? fromJson(Object? value) {
    final map = asMap(value);
    final url = asNonEmptyString(map['url']);
    if (url == null) return null;
    return SubtitleInfo(
      url: url,
      name: asNonEmptyString(map['name']) ?? '',
      lang: asNonEmptyString(map['lang']) ?? '',
      format: asNonEmptyString(map['format']) ?? '',
      flag: asInt(map['flag']) ?? 0,
    );
  }

  Map<String, Object?> toJson() => {
    'url': url,
    'name': name,
    'lang': lang,
    'format': format,
    'flag': flag,
  };

  /// 解析 `subs` 数组：缺 `url` 的条目丢弃（与 `Vod` 缺 id 同语义，§8.4）。
  static List<SubtitleInfo> listFromJson(Object? value) => asList(value)
      .map(SubtitleInfo.fromJson)
      .whereType<SubtitleInfo>()
      .toList();

  @override
  bool operator ==(Object other) =>
      other is SubtitleInfo &&
      other.url == url &&
      other.name == name &&
      other.lang == lang &&
      other.format == format &&
      other.flag == flag;

  @override
  int get hashCode => Object.hash(url, name, lang, format, flag);

  @override
  String toString() =>
      'SubtitleInfo(name=$name lang=$lang format=$format flag=$flag url=${redactUrl(url)})';
}

/// 弹幕源类型（与 Android `DanmakuUrlPolicy.classify` 语义对齐）。
enum DanmakuSourceKind {
  /// 静态弹幕文件（`http(s)` 弹幕文件、本地文件）。
  staticFile,

  /// 直播弹幕（`ws`/`wss`）：需要 WebSocket 会话，本阶段不支持。
  live,

  /// 协议不受支持。
  unsupported,
}

/// 一个弹幕源（播放结果里的 `danmaku` 条目）。
///
/// 字段与 WebHTV Android 的 `com.fongmi.android.tv.bean.Danmaku` 对齐：
/// `name`、`url`，外加 `source`/`from`/`site` 等来源标记。
/// 解析细节见 `lib/core/danmaku.dart`。
class DanmakuSource {
  const DanmakuSource({
    required this.url,
    this.name = '',
    this.source = '',
    this.selected = false,
  });

  final String url;
  final String name;

  /// 来源标记（`source`/`from`/`site`/`provider`/`platform` 任一）。
  final String source;

  final bool selected;

  /// 展示名：名称 → 来源 → 地址末段（对齐 Android `Danmaku.getName`）。
  String get displayName {
    if (name.isNotEmpty) return name;
    if (source.isNotEmpty) return source;
    return url.isEmpty ? '弹幕' : url.split('/').last;
  }

  /// 地址是否是直播弹幕（`ws`/`wss`）。
  bool get isLive => classify() == DanmakuSourceKind.live;

  Map<String, Object?> toJson() => {
    'name': name,
    'url': url,
    'source': source,
    'selected': selected,
  };

  /// 判定源类型（与 Android `DanmakuUrlPolicy.classify` 取舍一致）：
  /// `http/https/file` → 静态；`ws/wss` → 直播；其余 → 不支持。
  DanmakuSourceKind classify() {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return DanmakuSourceKind.unsupported;
    // Windows 盘符路径（`C:\...`）先于 URI 解析判定，否则会被当成 scheme。
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(trimmed)) {
      return DanmakuSourceKind.staticFile;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return DanmakuSourceKind.unsupported;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      return uri.host.isEmpty
          ? DanmakuSourceKind.unsupported
          : DanmakuSourceKind.staticFile;
    }
    if (scheme == 'file') return DanmakuSourceKind.staticFile;
    if (scheme == 'ws' || scheme == 'wss') {
      return uri.host.isEmpty
          ? DanmakuSourceKind.unsupported
          : DanmakuSourceKind.live;
    }
    if (scheme.isEmpty) return DanmakuSourceKind.staticFile;
    return DanmakuSourceKind.unsupported;
  }

  @override
  bool operator ==(Object other) =>
      other is DanmakuSource &&
      other.url == url &&
      other.name == name &&
      other.source == source;

  @override
  int get hashCode => Object.hash(url, name, source);

  @override
  String toString() =>
      'DanmakuSource(name=$displayName source=$source url=${redactUrl(url)})';
}

/// 统一的 Result 结构（首页/分类/详情/搜索/播放）。
class SiteResult {
  const SiteResult({
    this.classes = const [],
    this.filters = const {},
    this.list = const [],
    this.page,
    this.pageCount,
    this.total,
    this.playUrl,
    this.header,
    this.format,
    this.parse,
    this.jx,
    this.msg,
    this.subs = const [],
    this.danmaku = const [],
    this.extra = const {},
  });

  final List<VodClass> classes;
  final Map<String, List<VodFilterGroup>> filters;
  final List<Vod> list;
  final int? page;
  final int? pageCount;
  final int? total;

  /// 播放结果 `url`。
  final String? playUrl;
  final HeaderMap? header;
  final String? format;
  final int? parse;
  final int? jx;
  final String? msg;

  /// 播放结果携带的外挂字幕（§10.3）。非播放结果通常为空。
  final List<SubtitleInfo> subs;

  /// 播放结果携带的弹幕源（§21 Phase 3「弹幕可开启和关闭」）。
  final List<DanmakuSource> danmaku;
  final Map<String, Object?> extra;

  bool get isEmpty => classes.isEmpty && list.isEmpty && playUrl == null;

  SiteResult copyWith({
    List<VodClass>? classes,
    Map<String, List<VodFilterGroup>>? filters,
    List<Vod>? list,
    int? page,
    int? pageCount,
    int? total,
    String? playUrl,
    HeaderMap? header,
    String? format,
    int? parse,
    int? jx,
    String? msg,
    List<SubtitleInfo>? subs,
    List<DanmakuSource>? danmaku,
  }) {
    return SiteResult(
      classes: classes ?? this.classes,
      filters: filters ?? this.filters,
      list: list ?? this.list,
      page: page ?? this.page,
      pageCount: pageCount ?? this.pageCount,
      total: total ?? this.total,
      playUrl: playUrl ?? this.playUrl,
      header: header ?? this.header,
      format: format ?? this.format,
      parse: parse ?? this.parse,
      jx: jx ?? this.jx,
      msg: msg ?? this.msg,
      subs: subs ?? this.subs,
      danmaku: danmaku ?? this.danmaku,
      extra: extra,
    );
  }
}

/// 播放决策：把 Result 里的 `url/parse/jx/playUrl/flag` 归一化为可执行动作（§7.4.8）。
enum PlaybackAction {
  /// 直接播放 [PlaybackDecision.url]。
  direct,

  /// 需要解析器：交由 `ParseService` 执行（§12）。
  ///
  /// [PlaybackDecision.url] 为待解析的目标地址，[PlaybackDecision.parse] /
  /// [PlaybackDecision.jx] 标明触发原因。
  needParser,

  /// 需要 Spider 运行时（Phase 2+）。
  needSpiderRuntime,
}

class PlaybackDecision {
  const PlaybackDecision({
    required this.action,
    this.url,
    this.headers,
    this.format,
    this.reason,
    this.flag,
    this.subs = const [],
    this.danmaku = const [],
    this.upstreamHeaders,
    this.parse,
    this.jx,
  });

  final PlaybackAction action;
  final String? url;
  final HeaderMap? headers;
  final String? format;
  final String? reason;
  final String? flag;

  /// 播放结果的 `parse` / `jx` 标记（§7.4.8）。
  ///
  /// 仅当 [action] 为 [PlaybackAction.needParser] 时有意义：`site_service` 据此
  /// 决定是否调用解析器，以及按 `flag` 匹配哪个解析器（§12.2）。
  final int? parse;
  final int? jx;

  /// 播放结果携带的外挂字幕（§10.3）：随决策一起传到播放器。
  final List<SubtitleInfo> subs;

  /// 播放结果携带的弹幕源（§21 Phase 3）：随决策一起传到播放器。
  final List<DanmakuSource> danmaku;

  /// 代理**之前**合并出的媒体 Header（§7.4.6）。
  ///
  /// 走本地代理时 [headers] 会被清空（Header 由代理注入，避免泄漏到直连请求），
  /// 但外挂字幕/弹幕由宿主自己发请求，必须用代理前的原始 Header，否则丢 Referer/UA。
  final HeaderMap? upstreamHeaders;

  /// 宿主自行发起的附加资源请求（外挂字幕、弹幕）应使用的 Header。
  HeaderMap? get assetHeaders =>
      (upstreamHeaders?.isNotEmpty ?? false) ? upstreamHeaders : headers;

  String get logLine =>
      'action=${action.name} url=${redactUrl(url)} flag=${flag ?? ""} '
      'subs=${subs.length} danmaku=${danmaku.length} reason=${reason ?? ""}';
}

/// 从 URL 的 userinfo（`scheme://user:pass@host`）生成 `Authorization: Basic` 头值。
///
/// **为什么需要它**：dart:io 的 `HttpClient` 会把 `Uri.userInfo` **原样**塞进 Basic 凭据，
/// **不做百分号解码**。而台面上的猫源/TVBox 订阅大量使用 `user:eXi6S%3Axxx@host` 这种
/// 「密码里含 `:`，按 URL 规则编码成 `%3A`」的写法：curl 会先解码再发送（实测
/// `root:eXi6S:jgdv22!N6` → 200），Dart 发送字面 `%3A` → 服务端 401。
/// 因此凡走 [HttpClient] 的出站请求都要用本函数解码 userinfo 并显式设置 Basic 头，
/// 同时把请求 URI 换成不带 userinfo 的 [uriWithoutUserInfo]。
///
/// 返回 `null` 表示该 URI 没有 userinfo，调用方无需设置任何头。
String? basicAuthHeader(Uri uri) {
  if (uri.userInfo.isEmpty) return null;
  final decoded = Uri.decodeComponent(uri.userInfo);
  return 'Basic ${base64Encode(utf8.encode(decoded))}';
}

/// 去掉 userinfo 的同一 URI。
///
/// 与 [basicAuthHeader] 配对使用：凭据改由 Authorization 头携带后，URI 里再留一份
/// userinfo 只会让 `HttpClient` 再发一次（错误编码的）凭据，并可能把密码写进日志/诊断。
Uri uriWithoutUserInfo(Uri uri) {
  if (uri.userInfo.isEmpty) return uri;
  return uri.replace(userInfo: '');
}

/// URL 脱敏：只保留 scheme + host + path，隐藏 query 与片段（§11.3.1）。
String redactUrl(String? url) {
  if (url == null || url.isEmpty) return '';
  final uri = Uri.tryParse(url);
  if (uri == null) return '<invalid-url>';
  if (!uri.hasScheme) return uri.path.isEmpty ? '<relative>' : uri.path;
  final buffer = StringBuffer('${uri.scheme}://');
  if (uri.host.isNotEmpty) {
    buffer.write(uri.host);
    if (uri.hasPort) buffer.write(':${uri.port}');
  }
  buffer.write(uri.path.isEmpty ? '/' : uri.path);
  if (uri.hasQuery) buffer.write('?...');
  return buffer.toString();
}

/// 日志脱敏（§9.3.1、§11.3.1、§18.2）。
final RegExp _sensitiveKeyPattern = RegExp(
  r'(cookie|authorization|token|sign|signature|auth|password|passwd|'
  r'secret|session|api[-_]?key|access[-_]?key)',
  caseSensitive: false,
);

/// 判断一个 Header 名称是否为敏感键（Cookie/Authorization/Token 等，§9.3.1）。
///
/// 提取为公共函数，供日志与播放诊断（§23）复用同一套判定，避免两处规则分叉。
bool isSensitiveHeaderKey(String key) =>
    _sensitiveKeyPattern.hasMatch(key.trim());

String redactHeadersForLog(Map<String, String> headers) {
  final parts = <String>[];
  for (final entry in headers.entries) {
    parts.add('${entry.key}=${isSensitiveHeaderKey(entry.key) ? "<redacted>" : entry.value}');
  }
  parts.sort();
  return parts.join(', ');
}

/// 脱敏一行日志文本（§9.3.1「stderr 日志执行大小限制、轮转和脱敏」、
/// §11.3.1「日志仅记录 token 指纹，不记录完整 token、签名 query、Cookie 或
/// Authorization」）。
///
/// 与 [redactHeadersForLog] 的区别：这里处理的是 sidecar 自己打印的自由文本，
/// 因此需要同时覆盖 `Key: value` 形式与 URL query 形式。
String redactLogText(String line) {
  var output = line;

  // 1) `Cookie: xxx` / `Authorization: Bearer xxx` 这类头样式。
  // 值要吃到行尾或 `;`，否则 `Authorization: Bearer abc` 只会隐掉 `Bearer`。
  output = output.replaceAllMapped(
    RegExp(
      r'\b((?:cookie|set-cookie|authorization|proxy-authorization)'
      r'\s*[:=]\s*)([^;\r\n]+)',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>',
  );

  // 2) API key 类 Header（值不带空格）。
  output = output.replaceAllMapped(
    RegExp(
      r'\b((?:x-api-key|x-auth-token|api[-_]?key)\s*[:=]\s*)([^\s,;]+)',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>',
  );

  // 3) URL query 中的敏感键值（含签名参数）。
  output = output.replaceAllMapped(
    RegExp(
      r'([?&](?:' + _sensitiveQueryNames + r')=)([^&#\s]*)',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>',
  );

  // 4) `token=xxx` / `sign=xxx` 这类非 URL 形式的键值。
  output = output.replaceAllMapped(
    RegExp(
      r'\b((?:token|sign|signature|secret|password|passwd|session|'
      r'access[-_]?key)\s*=\s*)([^\s,;&]+)',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>',
  );

  return output;
}

const String _sensitiveQueryNames =
    r'cookie|authorization|token|sign|signature|auth|password|passwd|secret|'
    r'session|api[-_]?key|access[-_]?key';

/// 按 host 规则注入全局 header（§7.4.6 步骤 2）。
HeaderMap globalHeadersFor(List<HeaderRule> rules, String host) {
  final merged = HeaderMap();
  for (final rule in rules) {
    if (rule.matches(host)) {
      for (final entry in rule.header.entries) {
        merged.put(entry.key, entry.value);
      }
    }
  }
  return merged;
}
