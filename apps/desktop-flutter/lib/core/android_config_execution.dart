/// PC 原始配置到 Android 执行的纯数据层：绑定、可转发快照与内存叠加。
///
/// 不碰配置数据库、不碰 sourceKey、不发网络请求。
library;

import 'dart:convert';

import 'protocol.dart';

/// Android 快照的 UTF-8 JSON 上限（2 MiB）。
const int androidExecutionSnapshotMaxBytes = 2 * 1024 * 1024;

/// 单个绑定：原配置源 + Android 连接描述。
///
/// interfaceKey 允许为空，表示已预留、尚未导入完成的 pending 绑定；
/// pending 绑定可以持久化，但不能被选为启用。
class AndroidConfigExecutionBinding {
  AndroidConfigExecutionBinding({
    required this.sourceKey,
    required this.profileConnectionKey,
    required this.deviceUuid,
    required this.configHash,
    required this.snapshotToken,
    required this.guestPort,
    this.interfaceKey = '',
  });

  final String sourceKey;
  final String profileConnectionKey;
  final String deviceUuid;
  final String configHash;
  final String snapshotToken;
  final int guestPort;
  final String interfaceKey;

  bool get isReady =>
      sourceKey.trim().isNotEmpty &&
      profileConnectionKey.trim().isNotEmpty &&
      deviceUuid.trim().isNotEmpty &&
      isValidAndroidConfigHash(configHash) &&
      isValidAndroidSnapshotToken(snapshotToken) &&
      guestPort >= 1 &&
      guestPort <= 65535 &&
      interfaceKey.trim().isNotEmpty;

  /// 稳定去重键：执行字段变化不改身份，且不受分隔符碰撞影响。
  String get bindingKey =>
      jsonEncode(<String>[sourceKey, profileConnectionKey]);

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'sourceKey': sourceKey,
    'profileConnectionKey': profileConnectionKey,
    'deviceUuid': deviceUuid,
    'configHash': configHash,
    'snapshotToken': snapshotToken,
    'guestPort': guestPort,
    'interfaceKey': interfaceKey,
  };

  /// 读取版本 1 绑定；无法识别（含未来版本、越界字段）返回 null。
  static AndroidConfigExecutionBinding? fromJson(Object? value) {
    if (value is! Map) return null;
    if (value['version'] != 1) return null;
    final sourceKey = value['sourceKey'];
    final profileConnectionKey = value['profileConnectionKey'];
    final deviceUuid = value['deviceUuid'];
    final configHash = value['configHash'];
    final snapshotToken = value['snapshotToken'];
    final guestPort = value['guestPort'];
    final interfaceKey = value['interfaceKey'];
    if (sourceKey is! String || sourceKey.trim().isEmpty) return null;
    if (profileConnectionKey is! String ||
        profileConnectionKey.trim().isEmpty) {
      return null;
    }
    if (deviceUuid is! String || deviceUuid.trim().isEmpty) return null;
    if (configHash is! String || !isValidAndroidConfigHash(configHash)) {
      return null;
    }
    if (snapshotToken is! String ||
        !isValidAndroidSnapshotToken(snapshotToken)) {
      return null;
    }
    if (guestPort is! int || guestPort < 1 || guestPort > 65535) return null;
    if (interfaceKey is! String) return null;
    return AndroidConfigExecutionBinding(
      sourceKey: sourceKey,
      profileConnectionKey: profileConnectionKey,
      deviceUuid: deviceUuid,
      configHash: configHash,
      snapshotToken: snapshotToken,
      guestPort: guestPort,
      interfaceKey: interfaceKey,
    );
  }

  AndroidConfigExecutionBinding copyWith({
    String? deviceUuid,
    String? configHash,
    String? snapshotToken,
    int? guestPort,
    String? interfaceKey,
  }) => AndroidConfigExecutionBinding(
    sourceKey: sourceKey,
    profileConnectionKey: profileConnectionKey,
    deviceUuid: deviceUuid ?? this.deviceUuid,
    configHash: configHash ?? this.configHash,
    snapshotToken: snapshotToken ?? this.snapshotToken,
    guestPort: guestPort ?? this.guestPort,
    interfaceKey: interfaceKey ?? this.interfaceKey,
  );

  /// 只含短指纹，绝不含 token 或设备 uuid。
  @override
  String toString() =>
      'AndroidConfigExecutionBinding(source=$sourceKey, profile=$profileConnectionKey, device=****, token=#${_shortFingerprint(snapshotToken)}, port=$guestPort, ready=$isReady)';
}

/// 128 bit（16 字节）以上的 base64url 文本。
bool isValidAndroidSnapshotToken(String token) {
  if (token.length < 22 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(token)) {
    return false;
  }
  try {
    final bytes = base64Url.decode(base64Url.normalize(token));
    return bytes.length >= 16;
  } on FormatException {
    return false;
  }
}

/// 64 位十六进制配置摘要。
bool isValidAndroidConfigHash(String hash) =>
    RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash);

/// 把 PC 原配置 JSON 变成 Android 可读取的快照。
///
/// 深拷贝全部未知字段，只改写 origin 能证明安全的 HTTP 相对引用。
/// PC 本地 JAR、扩展、本地协议与 bundle 引用一律拒绝，诊断不含原始 URL。
Map<String, Object?> androidExecutionSnapshot(
  Map<String, Object?> original, {
  required String origin,
  String contentType = '',
}) {
  final normalizedType = contentType.trim().toLowerCase();
  // contentType 是传输元数据；服务器误标 HTML 不应拒绝已解析的配置站点。
  if (normalizedType.contains('html') && original['sites'] is! List) {
    throw const FormatException('配置来源不是 JSON 内容，无法生成执行快照');
  }

  final copied = _deepCopyJson(original);
  if (copied is! Map<String, Object?>) {
    throw const FormatException('执行快照根节点必须是 JSON 对象');
  }
  final copiedMap = copied.cast<String, Object?>();
  _ensureSnapshotSize(copiedMap);

  final base = _parseHttpOrigin(origin);
  _rewriteSnapshotReferences(copiedMap, base);
  _ensureSnapshotSize(copiedMap);
  return copiedMap;
}

/// 把原配置站点替换为 Android 网关的 T4 站点，返回新对象。
///
/// 原配置的站点顺序、key、展示名、header 与全部顶层字段保持原样；
/// 只取同 key 网关站点的 type/api/ext，并移除 jar。
/// 原配置站点在网关缺失或不是 T4 时整次失败，不做半套叠加、不回退 PC API。
AppConfig overlayAndroidExecution(AppConfig original, AppConfig gateway) {
  final byKey = <String, Site>{};
  for (final site in gateway.sites) {
    byKey.putIfAbsent(site.key, () => site);
  }

  for (final site in original.sites) {
    final replacement = byKey[site.key];
    if (replacement == null) {
      throw FormatException('Android 网关配置缺少原站点：${site.key}');
    }
    if (replacement.type != 4) {
      throw FormatException('Android 网关站点不是 T4 接口：${site.key}');
    }
  }

  final sites = <Site>[
    for (final site in original.sites) _overlaySite(site, byKey[site.key]!),
  ];

  return AppConfig(
    name: original.name,
    spider: original.spider,
    sites: sites,
    parses: original.parses,
    flags: original.flags,
    lives: original.lives,
    doh: original.doh,
    proxy: original.proxy,
    hosts: original.hosts,
    headers: original.headers,
    rules: original.rules,
    hlsRules: original.hlsRules,
    groupRules: original.groupRules,
    ads: original.ads,
    wallpaper: original.wallpaper,
    logo: original.logo,
    notice: original.notice,
    home: original.home,
    parse: original.parse,
    danmaku: original.danmaku,
    urls: original.urls,
    msg: original.msg,
    hasMsgKey: original.hasMsgKey,
    extra: original.extra,
  );
}

Site _overlaySite(Site original, Site gateway) {
  final extra = Map<String, Object?>.of(original.extra)..remove('jar');
  return Site(
    key: original.key,
    name: original.name,
    type: gateway.type,
    api: gateway.api,
    jar: null,
    ext: gateway.ext,
    header: original.header,
    timeoutSeconds: original.timeoutSeconds,
    searchable: original.searchable,
    changeable: original.changeable,
    quickSearch: original.quickSearch,
    filterable: original.filterable,
    categories: original.categories,
    style: original.style,
    hide: original.hide,
    indexs: original.indexs,
    extra: extra,
  );
}

void _ensureSnapshotSize(Map<String, Object?> snapshot) {
  final bytes = utf8.encode(jsonEncode(snapshot));
  if (bytes.length > androidExecutionSnapshotMaxBytes) {
    throw const FormatException('执行快照超过 2 MiB 上限');
  }
}

Uri _parseHttpOrigin(String raw) {
  final origin = raw.trim();
  if (origin.isEmpty || _looksLikeLocalReference(origin)) {
    throw const FormatException('配置来源不是可转发的 HTTP 地址');
  }
  final uri = Uri.tryParse(origin);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      _isLoopbackHost(uri.host)) {
    throw const FormatException('配置来源不是可转发的 HTTP 地址');
  }
  return uri;
}

void _rewriteSnapshotReferences(Map<String, Object?> snapshot, Uri origin) {
  final spider = snapshot['spider'];
  if (spider is String && spider.trim().isNotEmpty) {
    snapshot['spider'] = _resolveReference(
      spider,
      origin,
      field: 'spider',
      forceReference: true,
    );
  }

  final sites = snapshot['sites'];
  if (sites is! List) return;
  for (final item in sites) {
    if (item is! Map) continue;
    final site = item.cast<String, Object?>();
    final api = site['api'];
    if (api is String && api.trim().isNotEmpty) {
      site['api'] = _resolveReference(
        api,
        origin,
        field: 'api',
        forceReference: false,
      );
    }
    final jar = site['jar'];
    if (jar is String && jar.trim().isNotEmpty) {
      site['jar'] = _resolveReference(
        jar,
        origin,
        field: 'jar',
        forceReference: true,
      );
    }
    final ext = site['ext'];
    if (ext is String && ext.trim().isNotEmpty) {
      site['ext'] = _resolveReference(
        ext,
        origin,
        field: 'ext',
        forceReference: false,
      );
    }
  }
}

String _resolveReference(
  String raw,
  Uri origin, {
  required String field,
  required bool forceReference,
}) {
  final reference = raw.trim();
  if (_looksLikeLocalReference(reference)) {
    throw FormatException('Android 执行不支持 PC 本地的 $field 引用（V1 不上传本地 JAR/扩展）');
  }
  if ((field == 'spider' || field == 'jar') && reference.contains('\u005C')) {
    throw FormatException('Android 执行不支持 PC 本地的 $field 引用（V1 不上传本地 JAR/扩展）');
  }

  final absolute = _tryHttpUri(reference);
  if (absolute != null) {
    _rejectLoopbackUri(absolute, field);
    return raw;
  }

  final refSplit = _splitMd5Suffix(reference);
  if (!forceReference &&
      !_looksLikeExplicitUriReference(reference, refSplit.path)) {
    return raw;
  }

  final split = _splitMd5Suffix(origin.toString());
  final base = Uri.parse(split.path);
  final resolved = base.resolve(refSplit.path);
  _rejectLoopbackUri(resolved, field);
  return resolved.toString() + refSplit.suffix;
}

({String path, String suffix}) _splitMd5Suffix(String value) {
  final index = value.indexOf(';md5;');
  if (index < 0) return (path: value, suffix: '');
  return (path: value.substring(0, index), suffix: value.substring(index));
}

Uri? _tryHttpUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

bool _looksLikeExplicitUriReference(String raw, String path) {
  final value = path.trim();
  if (value.isEmpty || _looksLikeOpaqueText(value)) return false;
  if (value.startsWith('./') ||
      value.startsWith('../') ||
      value.startsWith('//') ||
      value.startsWith('/')) {
    return true;
  }
  final resourceLike = value.contains('/') || _looksLikeResourceFile(value);
  if (raw.contains(';md5;')) return resourceLike;
  return _looksLikeResourceFile(value);
}

bool _looksLikeOpaqueText(String value) =>
    value.startsWith('{') || value.startsWith('[') || value.startsWith('"');

bool _looksLikeResourceFile(String value) => RegExp(
  r'^[^?#\s\\]+\.(json|jar|js|txt|zip|dex|php|xml|m3u8|css|html|htm)([?#].*)?$',
  caseSensitive: false,
).hasMatch(value);

bool _looksLikeLocalReference(String value) {
  if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) return true;
  if (value.startsWith(r'\\') || value.startsWith('~/')) {
    return true;
  }
  final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):')
      .firstMatch(value)
      ?.group(1)
      ?.toLowerCase();
  if (scheme != null &&
      const {
        'file',
        'content',
        'asset',
        'assets',
        'bundle',
        'web-home',
        'spider-local',
        'jar',
        'data',
        'blob',
        'about',
        'chrome-extension',
        'resource',
        'pc-local',
        'local',
      }.contains(scheme)) {
    return true;
  }
  for (final prefix in const [
    '/home/',
    '/Users/',
    '/tmp/',
    '/var/',
    '/opt/',
    '/mnt/',
    '/media/',
    '/private/',
    '/System/',
    '/etc/',
  ]) {
    if (value.startsWith(prefix)) return true;
  }
  return false;
}

void _rejectLoopbackUri(Uri uri, String field) {
  if (_isLoopbackHost(uri.host)) {
    throw FormatException('Android 执行不支持 PC 本机回环地址的 $field 引用（V1 不转发本机资源）');
  }
}

bool _isLoopbackHost(String host) {
  var value = host.trim().toLowerCase();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  if (value.endsWith('.')) {
    value = value.substring(0, value.length - 1);
  }
  if (value.startsWith('::ffff:')) {
    value = value.substring('::ffff:'.length);
  }
  if (value == 'localhost' || value == '::1' || value == '0:0:0:0:0:0:0:1') {
    return true;
  }
  if (!RegExp(r'^127(\.\d{1,3}){1,3}$').hasMatch(value)) return false;
  return value.split('.').every((part) => (int.tryParse(part) ?? 256) <= 255);
}

Object? _deepCopyJson(Object? value, {int depth = 0}) {
  if (depth > 64) {
    throw const FormatException('执行快照嵌套过深');
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map) {
    final copy = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const FormatException('执行快照包含非字符串键');
      }
      copy[key] = _deepCopyJson(entry.value, depth: depth + 1);
    }
    return copy;
  }
  if (value is List) {
    return <Object?>[
      for (final item in value) _deepCopyJson(item, depth: depth + 1),
    ];
  }
  throw const FormatException('执行快照包含非 JSON 值');
}

String _shortFingerprint(String value) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
