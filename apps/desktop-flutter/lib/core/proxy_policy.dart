/// 本地代理安全策略与 HLS 重写（设计文档 §11.1、§11.3、§11.3.1、§9.6）。
///
/// 本文件是纯逻辑层，不绑定端口、不做 IO，便于用单元测试逐条覆盖安全要求：
/// token 校验、目标 URL 白名单、内网/回环/云元数据拒绝、凭据同源传播、
/// HLS 清单重写与日志脱敏。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// 目标 URL 的判定结果。
class ProxyTargetDecision {
  const ProxyTargetDecision._(this.allowed, this.reason, this.code);

  const ProxyTargetDecision.allow() : this._(true, 'allowed', 200);

  const ProxyTargetDecision.deny(String reason, {int code = 403})
    : this._(false, reason, code);

  final bool allowed;
  final String reason;

  /// 拒绝时返回给客户端的 HTTP 状态码。
  final int code;

  @override
  String toString() => allowed ? 'allow' : 'deny($code $reason)';
}

/// 目标 URL 策略（§11.3「校验目标 URL 白名单」「不转发内网地址」）。
class ProxyTargetPolicy {
  const ProxyTargetPolicy({
    this.allowPrivate = false,
    this.allowLoopback = false,
    this.allowedHosts = const {},
    this.allowedSchemes = const ['http', 'https'],
    this.maxRedirects = 5,
  });

  /// 用户显式开启后允许私网目标（§11.3 第 4 条）。
  final bool allowPrivate;

  /// 用户显式授权的本地源（例如局域网内的自建媒体服务）。
  final bool allowLoopback;

  /// 站点授权的目标主机白名单；为空表示不做主机限制（仅做 IP 与 scheme 限制）。
  final Set<String> allowedHosts;

  final List<String> allowedSchemes;
  final int maxRedirects;

  /// 云元数据地址：即使在私网也不允许访问（§11.3.1）。
  static const Set<String> cloudMetadataHosts = {
    '169.254.169.254',
    'metadata.google.internal',
    'metadata.goog',
    '100.100.100.200',
  };

  /// 只做静态判定（scheme/host/字面 IP），不做 DNS 解析。
  ProxyTargetDecision evaluateStatic(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (!allowedSchemes.contains(scheme)) {
      return ProxyTargetDecision.deny('scheme 不受支持：$scheme');
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty) {
      return const ProxyTargetDecision.deny('缺少 host');
    }
    if (cloudMetadataHosts.contains(host)) {
      return const ProxyTargetDecision.deny('云元数据地址被拒绝');
    }
    if (allowedHosts.isNotEmpty && !_hostAllowed(host, uri.port)) {
      return ProxyTargetDecision.deny('主机不在授权列表：$host');
    }
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return evaluateAddress(literal, host);
    if (_isLocalName(host)) {
      if (allowLoopback || allowPrivate) {
        return const ProxyTargetDecision.allow();
      }
      return ProxyTargetDecision.deny('本机主机名被拒绝：$host');
    }
    return const ProxyTargetDecision.allow();
  }

  /// DNS 解析后逐个地址复检（§11.3.1「每次 DNS 解析、连接和重定向后都重新校验」）。
  ProxyTargetDecision evaluateAddress(InternetAddress address, String host) {
    if (cloudMetadataHosts.contains(host.toLowerCase())) {
      return const ProxyTargetDecision.deny('云元数据地址被拒绝');
    }
    if (_isUnspecified(address)) {
      return ProxyTargetDecision.deny('未指定地址被拒绝：$host');
    }
    if (_isLoopback(address) && !allowLoopback) {
      return ProxyTargetDecision.deny('回环地址被拒绝：$host');
    }
    if (_isLinkLocal(address) && !allowPrivate && !allowLoopback) {
      return ProxyTargetDecision.deny('链路本地地址被拒绝：$host');
    }
    if (_isPrivate(address) && !allowPrivate && !allowLoopback) {
      return ProxyTargetDecision.deny('私网地址被拒绝：$host');
    }
    return const ProxyTargetDecision.allow();
  }

  /// 校验全部解析结果；任一地址被拒绝即整体拒绝（防 DNS 重绑定）。
  ProxyTargetDecision evaluateAll(
    List<InternetAddress> addresses,
    String host,
  ) {
    if (addresses.isEmpty) {
      return const ProxyTargetDecision.deny('DNS 未返回任何地址', code: 502);
    }
    for (final address in addresses) {
      final decision = evaluateAddress(address, host);
      if (!decision.allowed) return decision;
    }
    return const ProxyTargetDecision.allow();
  }

  bool _hostAllowed(String host, int port) {
    for (final entry in allowedHosts) {
      final normalized = entry.trim().toLowerCase();
      if (normalized.isEmpty) continue;
      final withPort = normalized.contains(':') && !normalized.startsWith('[');
      if (withPort) {
        final parts = normalized.split(':');
        final entryPort = int.tryParse(parts.last);
        final entryHost = parts.sublist(0, parts.length - 1).join(':');
        if (entryHost == host && (entryPort == null || entryPort == port)) {
          return true;
        }
        continue;
      }
      if (normalized == host || host.endsWith('.$normalized')) return true;
    }
    return false;
  }

  static bool _isLocalName(String host) =>
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host == 'localhost.localdomain';

  static bool _isUnspecified(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.every((byte) => byte == 0)) return true;
    // ::ffff:0.0.0.0 等价于 IPv4 any。
    if (bytes.length == 16 &&
        bytes.sublist(0, 10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff) {
      return bytes.sublist(12).every((byte) => byte == 0);
    }
    return false;
  }

  static bool _isLoopback(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) return bytes[0] == 127;
    if (bytes.length == 16) {
      if (bytes.sublist(0, 15).every((byte) => byte == 0) && bytes[15] == 1) {
        return true;
      }
      if (bytes.sublist(0, 10).every((byte) => byte == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff) {
        return bytes[12] == 127;
      }
    }
    return false;
  }

  static bool _isLinkLocal(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return bytes[0] == 169 && bytes[1] == 254;
    }
    // IPv6 fe80::/10
    return bytes.length == 16 && bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
  }

  static bool _isPrivate(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      final a = bytes[0];
      final b = bytes[1];
      if (a == 10) return true;
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      // 100.64.0.0/10 CGNAT：同样是运营商内网。
      if (a == 100 && b >= 64 && b <= 127) return true;
      return false;
    }
    if (bytes.length == 16) {
      // fc00::/7 唯一本地地址
      if ((bytes[0] & 0xfe) == 0xfc) return true;
      // IPv4-mapped ::ffff:a.b.c.d
      if (bytes.sublist(0, 10).every((byte) => byte == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff) {
        return _isPrivate(InternetAddress.fromRawAddress(bytes.sublist(12)));
      }
    }
    return false;
  }
}

/// 代理会话（§11.3.1「每次播放创建独立 sessionId 和高熵随机 token」）。
typedef ProxyTrafficSnapshot = ({String sessionId, int receivedBytes});

/// 可选会话级传输授权：把逻辑目标映射到已由适配器建立的回环转发端口。
///
/// 返回 null 表示本会话不授权该目标，调用方必须继续走普通 HTTP 策略；
/// 返回端口只授权 `127.0.0.1:<port>`，不得返回任意主机或 URL。
typedef ProxyTargetResolver = Future<int?> Function(Uri logicalTarget);

class ProxySession {
  ProxySession({
    required this.id,
    required this.token,
    required this.siteKey,
    required this.createdAt,
    required this.expiresAt,
    this.maxBytes = defaultMaxBytes,
    this.maxRequests = 4096,
    this.allowedHosts = const {},
    this.userAgent,
    this.referer,
    this.cookie,
    this.authorization,
    this.extraHeaders = const {},
    this.targetResolver,
    this.inspectPlaylistContent = false,
  });

  /// 单会话累计字节上限默认值。
  ///
  /// 网盘点播是 GB 级**整文件**流（实测百度网盘单集 1882 MB），而非 HLS 小分片，
  /// 因此 512 MiB 这类小上限会把正常播放判成超限并返回 429。会话本身已由
  /// 高熵 token、站点绑定与短 TTL（默认 30 分钟）限定范围，64 GiB 既覆盖 4K 原盘，
  /// 又仍是有界上限（§11.3「限制单请求大小和总并发」）。
  static const int defaultMaxBytes = 64 * 1024 * 1024 * 1024;

  final String id;

  /// 高熵随机 token。只在 URL 中出现，不写入日志。
  final String token;

  final String siteKey;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// 单会话累计字节上限，避免被当作无界下载器（§11.3「限制单请求大小和总并发」）。
  final int maxBytes;
  final int maxRequests;
  final Set<String> allowedHosts;

  int bytes = 0;
  int requests = 0;

  int _receivedBytes = 0;

  /// 会话内**实际收到的上游字节**（按到达的块累加）。
  ///
  /// 与 [bytes] 不同：[bytes] 是配额记账，按声明的长度预先累加；这里只记真的
  /// 到了的数据，所以能回答「此刻在下多少」。
  int get receivedBytes => _receivedBytes;

  void recordReceivedBytes(int count) {
    if (count > 0 && !revoked) _receivedBytes += count;
  }

  final Set<String> _observedHlsPaths = {};

  /// Positive signature evidence only, bounded and owned by this session.
  void recordHlsPath(String path) {
    if (usable && _observedHlsPaths.length < maxChildTargets) {
      _observedHlsPaths.add(path);
    }
  }

  void clearHlsPath(String path) => _observedHlsPaths.remove(path);

  bool hasObservedHlsPath(String path) =>
      usable && _observedHlsPaths.contains(path);

  bool revoked = false;

  /// 会话内允许继承的 `User-Agent`；不得用于覆盖宿主的安全/诊断 Header（§11.3.1）。
  final String? userAgent;

  /// 站点要求注入的 `Referer`。
  final String? referer;

  /// 凭据只在同源传播（§11.3.1）。
  final String? cookie;
  final String? authorization;

  /// 站点声明的额外 Header（例如自定义签名头），同样仅同源传播。
  final Map<String, String> extraHeaders;

  /// 仅本会话生效的 Android/ADB 传输授权；null 保持普通代理行为。
  final ProxyTargetResolver? targetResolver;

  /// 来源已在 Android 执行：未知类型的成功媒体 GET 可按内容补判清单。
  /// 仅影响有界清单检查，绝不授权地址或改变目标策略/传输映射。
  final bool inspectPlaylistContent;

  /// 该会话已确立的来源（首次请求的目标 host:port），用于同源凭据传播。
  String? establishedOrigin;

  /// 重定向派生出的主机（同一播放请求的重定向目标，§11.3.1）。
  /// 302 到 CDN 是媒资分发常态（如百度 `d.pcs.baidu.com` → `appall01.baidupcs.com`），
  /// 这些主机需要被授权以继续代理 HLS 子清单/分片。
  final Set<String> derivedHosts = {};

  /// 重写清单时引用过的子资源（分片、子清单、密钥）与其短码。
  ///
  /// 为什么要有：清单里每条子资源都要写成本地代理地址，长表单条 500+ 字符。
  /// 一份实测 24 KB 的真实清单（739 段 × 10s）重写后变成 240 KB，播放器每次
  /// 重载都要多读一个数量级。短码把每条压到几十字符，取回时只在本会话内还原，
  /// 授权范围不变（每个目标被记下时都已通过同一套主机白名单）。
  static const int maxChildTargets = 4096;

  final List<Uri> _childTargets = <Uri>[];
  final Set<int> _pngTsMediaAliases = {};
  final Set<int> _pngTsExcludedChildren = {};
  bool _pngTsManifestObserved = false;
  final Map<String, int> _childIndexes = <String, int>{};

  /// 子资源的短码（同一目标复用同一个编号）；表满返回 null。
  ///
  /// 表满时调用方必须退回长表单条 URL：清单变大可以接受，把地址丢掉不行。
  int? indexOfChild(Uri target) {
    final key = target.toString();
    final existing = _childIndexes[key];
    if (existing != null) return existing;
    if (_childTargets.length >= maxChildTargets) return null;
    final index = _childTargets.length;
    _childTargets.add(target);
    _childIndexes[key] = index;
    return index;
  }

  /// 短码还原；越界或负数返回 null（调用方必须以 4xx 拒绝）。
  Uri? childTargetAt(int index) =>
      index >= 0 && index < _childTargets.length ? _childTargets[index] : null;

  /// Format hints share the registered child table's bound and token lifetime.
  bool registerPngTsMediaAlias(int index) {
    final source = childTargetAt(index);
    if (!(targetResolver != null || inspectPlaylistContent) ||
        !usable ||
        _pngTsExcludedChildren.contains(index) ||
        source == null ||
        !source.path.toLowerCase().endsWith('.png')) {
      return false;
    }
    _pngTsMediaAliases.add(index);
    return true;
  }

  Uri? pngTsMediaAliasTargetAt(int index) =>
      usable &&
          _pngTsMediaAliases.contains(index) &&
          !_pngTsExcludedChildren.contains(index)
      ? childTargetAt(index)
      : null;

  void recordPngTsManifest() {
    _pngTsManifestObserved = true;
  }

  void excludePngTsChild(int index) {
    if (childTargetAt(index) != null) _pngTsExcludedChildren.add(index);
  }

  bool allowsPngTsNormalization(Uri target) {
    final index = _childIndexes[target.toString()];
    if (!usable || (index != null && _pngTsExcludedChildren.contains(index))) {
      return false;
    }
    // Direct approved media can be inspected before a playlist assigns roles.
    // Thereafter only a positively registered media alias is eligible.
    return !_pngTsManifestObserved ||
        (index != null && _pngTsMediaAliases.contains(index));
  }

  bool get expired => DateTime.now().isAfter(expiresAt);

  bool get usable => !revoked && !expired;

  /// 日志用指纹：只暴露 hash 前缀（§11.3.1）。
  String get fingerprint => ProxySessionManager.fingerprintOf(token);

  /// 记录一次请求；超限返回 false（调用方必须以 429 拒绝）。
  bool accountRequest(int contentLength) {
    requests += 1;
    if (requests > maxRequests) return false;
    bytes += contentLength <= 0 ? 0 : contentLength;
    return bytes <= maxBytes;
  }
}

/// 会话管理：创建、校验、撤销、过期清理。
class ProxySessionManager {
  ProxySessionManager({
    this.sessionTtl = const Duration(minutes: 30),
    Random? random,
  }) : _random = random ?? Random.secure();

  final Duration sessionTtl;
  final Random _random;
  final Map<String, ProxySession> _byToken = {};
  int _sequence = 0;

  List<ProxySession> get activeSessions =>
      _byToken.values.where((session) => session.usable).toList();

  int get sessionCount => _byToken.length;

  /// 创建会话。token 为 32 字节随机数据的高熵编码。
  ProxySession create({
    required String siteKey,
    Set<String> allowedHosts = const {},
    Duration? ttl,
    int maxBytes = ProxySession.defaultMaxBytes,
    int maxRequests = 4096,
    String? userAgent,
    String? referer,
    String? cookie,
    String? authorization,
    Map<String, String> extraHeaders = const {},
    ProxyTargetResolver? targetResolver,
    bool inspectPlaylistContent = false,
  }) {
    _sequence += 1;
    final token = _newToken();
    final now = DateTime.now();
    final session = ProxySession(
      id: 'proxy-${now.microsecondsSinceEpoch}-$_sequence',
      token: token,
      siteKey: siteKey,
      createdAt: now,
      expiresAt: now.add(ttl ?? sessionTtl),
      allowedHosts: allowedHosts,
      maxBytes: maxBytes,
      maxRequests: maxRequests,
      userAgent: userAgent,
      referer: referer,
      cookie: cookie,
      authorization: authorization,
      extraHeaders: extraHeaders,
      targetResolver: targetResolver,
      inspectPlaylistContent: inspectPlaylistContent,
    );
    _byToken[token] = session;
    return session;
  }

  ProxySession? byToken(String token) {
    if (token.isEmpty) return null;
    final session = _byToken[token];
    if (session == null) return null;
    if (!session.usable) {
      _byToken.remove(token);
      return null;
    }
    return session;
  }

  /// 撤销单个会话（停止播放、超时）。
  bool revoke(String token) {
    final session = _byToken.remove(token);
    if (session == null) return false;
    session.revoked = true;
    return true;
  }

  /// 撤销全部会话（应用退出）。重启后不得恢复旧 token（§11.3.1）。
  int revokeAll() {
    final count = _byToken.length;
    for (final session in _byToken.values) {
      session.revoked = true;
    }
    _byToken.clear();
    return count;
  }

  /// 清理过期会话；返回清理数量。
  int sweep() {
    final expired = _byToken.entries
        .where((entry) => !entry.value.usable)
        .map((entry) => entry.key)
        .toList();
    for (final token in expired) {
      _byToken.remove(token);
    }
    return expired.length;
  }

  String _newToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// token 指纹：SHA-256 前 12 个十六进制字符。
  static String fingerprintOf(String token) {
    if (token.isEmpty) return '-';
    final digest = sha256.convert(utf8.encode(token)).toString();
    return digest.substring(0, 12);
  }
}

/// HLS 清单重写（§11.2「HLS 清单重写」「HLS 分片代理」）。
abstract final class HlsPlaylistRewriter {
  /// 需要重写的行前缀（分片、清单、加密密钥）。
  static const List<String> _tagPrefixes = [
    '#EXT-X-KEY:',
    '#EXT-X-MAP:',
    '#EXT-X-MEDIA:',
    '#EXT-X-PART:',
    '#EXT-X-PRELOAD-HINT:',
    '#EXT-X-SESSION-KEY:',
    '#EXT-X-STREAM-INF:',
    '#EXT-X-I-FRAME-STREAM-INF:',
  ];

  /// 重写清单中所有子资源 URL。
  ///
  /// [proxify] 把绝对 URL 转成代理 URL；返回 null 表示该目标不允许代理，
  /// 此时保留原 URL 而不是静默丢弃，调用方可从日志看到未重写项。
  static String rewrite(
    String body,
    Uri baseUri,
    String? Function(Uri target) proxify,
  ) {
    final buffer = StringBuffer();
    for (final rawLine in const LineSplitter().convert(body)) {
      buffer.writeln(_rewriteLine(rawLine, baseUri, proxify));
    }
    return buffer.toString();
  }

  static String _rewriteLine(
    String line,
    Uri baseUri,
    String? Function(Uri target) proxify,
  ) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return line;
    if (!trimmed.startsWith('#')) {
      // 裸 URI 行：分片或子清单。
      return _rewriteUri(trimmed, baseUri, proxify) ?? line;
    }
    final tag = _tagPrefixes.firstWhere(
      (prefix) => trimmed.toUpperCase().startsWith(prefix),
      orElse: () => '',
    );
    if (tag.isEmpty) return line;

    // 重写 URI="..." 属性。
    var rewritten = line;
    final pattern = RegExp(r'URI\s*=\s*"([^"]*)"', caseSensitive: false);
    rewritten = rewritten.replaceAllMapped(pattern, (match) {
      final target = _resolve(match.group(1)!, baseUri);
      final proxied = target == null ? null : proxify(target);
      return proxied == null ? match.group(0)! : 'URI="$proxied"';
    });

    // STREAM-INF 的 URL 在下一行，无需在此处理。
    return rewritten;
  }

  static String? _rewriteUri(
    String value,
    Uri baseUri,
    String? Function(Uri target) proxify,
  ) {
    final target = _resolve(value, baseUri);
    if (target == null) return null;
    return proxify(target);
  }

  static Uri? _resolve(String value, Uri baseUri) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('data:')) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (uri.hasScheme) {
      return uri.isScheme('http') || uri.isScheme('https') ? uri : null;
    }
    return baseUri.resolveUri(uri);
  }

  /// true/false 表示签名已确定，null 表示仍需少量前缀字节。
  static bool? sniffPlaylistPrefix(List<int> bytes) {
    var offset = 0;
    if (bytes.isNotEmpty && bytes.first == 0xef) {
      const bom = [0xef, 0xbb, 0xbf];
      for (var i = 0; i < bom.length; i++) {
        if (i >= bytes.length) return null;
        if (bytes[i] != bom[i]) return false;
      }
      offset = bom.length;
    }
    while (offset < bytes.length &&
        const [0x20, 0x09, 0x0a, 0x0d].contains(bytes[offset])) {
      offset++;
    }
    const signature = [0x23, 0x45, 0x58, 0x54, 0x4d, 0x33, 0x55]; // #EXTM3U
    for (var i = 0; i < signature.length; i++) {
      if (offset + i >= bytes.length) return null;
      if (bytes[offset + i] != signature[i]) return false;
    }
    offset += signature.length;
    if (offset >= bytes.length) return null;
    return bytes[offset] == 0x0a || bytes[offset] == 0x0d;
  }

  /// 判断响应是否是需要重写的 HLS 清单。
  static bool looksLikePlaylist(String? contentType, String url) {
    final type = (contentType ?? '').toLowerCase();
    if (type.contains('mpegurl') || type.contains('vnd.apple')) return true;
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }
}

/// HLS 清单形状：**只统计标签**，不含任何 URL（§11.3.1 的日志约束）。
///
/// 为什么要有它：进度条的总长完全照搬播放引擎，而 HLS 线路的引擎时长可能是
/// 假的——实测同一部两小时的片子，载入时引擎只报 1.78s / 4.14s，界面把这句话
/// 当真之后拇指到 2:19 就被钳住。只看引擎那一个点，分不清是「引擎算错了」
/// 还是「清单本身就只有两分钟内容」，而这两种情况的修法相反。把清单侧的事实
/// （段数、Σ `#EXTINF`、有无 `#EXT-X-ENDLIST`、是否主清单）与引擎时长的变化放在
/// 同一份日志里，才有可能定论。
class HlsPlaylistShape {
  const HlsPlaylistShape({
    required this.segments,
    required this.totalSeconds,
    required this.hasEndList,
    required this.playlistType,
    required this.isMaster,
    required this.hasByteRange,
    required this.hasParts,
    required this.hasMap,
    required this.hasKey,
    required this.discontinuities,
  });

  /// 分片数：数 `#EXTINF` 的条数（与 demuxer 求和的口径一致，不看 URI 行）。
  final int segments;

  /// Σ `#EXTINF`（秒）：点播清单里它就是引擎本该上报的总时长。
  final double totalSeconds;

  /// 有 `#EXT-X-ENDLIST` 才是「点播完结」；缺失时 ffmpeg 侧时长是 N/A。
  final bool hasEndList;

  /// `#EXT-X-PLAYLIST-TYPE` 的值（VOD/EVENT），没有该标签时为 null。
  final String? playlistType;

  /// 主清单（含 `#EXT-X-STREAM-INF`）：本身没有分片，时长得问子清单。
  final bool isMaster;

  /// 分片按 `#EXT-X-BYTERANGE` 切：同一个文件被反复请求。
  final bool hasByteRange;

  /// 含 `#EXT-X-PART`：低延迟切片，通常是滚动窗口而不是完整点播。
  final bool hasParts;

  /// 含 `#EXT-X-MAP`：fMP4 初始化段，广告贴片常在这里换轨。
  final bool hasMap;

  /// 含 `#EXT-X-KEY`：分片加密。
  final bool hasKey;

  /// `#EXT-X-DISCONTINUITY` 数量：贴片广告与正片的分界通常就在这几处。
  final int discontinuities;

  static HlsPlaylistShape parse(String text) {
    var segments = 0;
    var totalSeconds = 0.0;
    var hasEndList = false;
    var isMaster = false;
    var hasByteRange = false;
    var hasParts = false;
    var hasMap = false;
    var hasKey = false;
    var discontinuities = 0;
    String? playlistType;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.length < 4 || !line.startsWith('#')) continue;
      final upper = line.toUpperCase();
      if (upper.startsWith('#EXTINF:')) {
        segments += 1;
        final value = line.substring('#EXTINF:'.length).split(',').first.trim();
        totalSeconds += double.tryParse(value) ?? 0;
      } else if (upper.startsWith('#EXT-X-ENDLIST')) {
        hasEndList = true;
      } else if (upper.startsWith('#EXT-X-PLAYLIST-TYPE:')) {
        playlistType = line.substring('#EXT-X-PLAYLIST-TYPE:'.length).trim();
      } else if (upper.startsWith('#EXT-X-STREAM-INF')) {
        isMaster = true;
      } else if (upper.startsWith('#EXT-X-BYTERANGE')) {
        hasByteRange = true;
      } else if (upper.startsWith('#EXT-X-PART')) {
        hasParts = true;
      } else if (upper.startsWith('#EXT-X-MAP')) {
        hasMap = true;
      } else if (upper.startsWith('#EXT-X-KEY')) {
        hasKey = true;
      } else if (upper.startsWith('#EXT-X-DISCONTINUITY') &&
          !upper.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) {
        // 序号标签不是断点，跟着算进去会把「广告分界」的数量放大。
        discontinuities += 1;
      }
    }
    return HlsPlaylistShape(
      segments: segments,
      totalSeconds: totalSeconds,
      hasEndList: hasEndList,
      playlistType: playlistType,
      isMaster: isMaster,
      hasByteRange: hasByteRange,
      hasParts: hasParts,
      hasMap: hasMap,
      hasKey: hasKey,
      discontinuities: discontinuities,
    );
  }

  /// 一行日志用的紧凑描述（只含标签事实，没有 URL）。
  String get summary =>
      'segments=$segments '
      'extinfSum=${totalSeconds.toStringAsFixed(1)}s '
      'endlist=${hasEndList ? "yes" : "no"} '
      'type=${playlistType ?? "-"} '
      'master=${isMaster ? "yes" : "no"} '
      'byrange=${hasByteRange ? "yes" : "no"} '
      'parts=${hasParts ? "yes" : "no"} '
      'map=${hasMap ? "yes" : "no"} '
      'key=${hasKey ? "yes" : "no"} '
      'disc=$discontinuities';
}

/// 需要跨 origin 移除的敏感 Header（§11.3.1）。
abstract final class SensitiveHeaders {
  static const Set<String> names = {
    'cookie',
    'authorization',
    'proxy-authorization',
    'x-api-key',
    'x-auth-token',
    'x-csrf-token',
  };

  static bool isSensitive(String name) =>
      names.contains(name.trim().toLowerCase());

  /// 按同源规则过滤：只有目标与来源同 origin 时才保留敏感 Header。
  static Map<String, String> filter({
    required Map<String, String> headers,
    required String origin,
    required String target,
  }) {
    if (origin == target) return Map.of(headers);
    return {
      for (final entry in headers.entries)
        if (!isSensitive(entry.key)) entry.key: entry.value,
    };
  }
}

/// 代理请求日志（§11.3.1「日志仅记录 token 指纹、目标主机、状态、字节数和耗时」）。
class ProxyLogRecord {
  const ProxyLogRecord({
    required this.tokenFingerprint,
    required this.targetHost,
    this.statusCode,
    this.upstreamStatus,
    this.downstreamStatus,
    this.bytes = 0,
    this.elapsed = Duration.zero,
    this.range,
    this.siteKey,
    this.note,
  });

  final String tokenFingerprint;
  final String targetHost;

  /// Legacy status: upstream for forwarded bodies, local rejection otherwise.
  final int? statusCode;
  final int? upstreamStatus;
  final int? downstreamStatus;
  final int bytes;
  final Duration elapsed;
  final String? range;
  final String? siteKey;
  final String? note;

  String get line {
    final parts = <String>[
      'token=$tokenFingerprint',
      'host=$targetHost',
      if (statusCode != null) 'status=$statusCode',
      if (upstreamStatus != null) 'upstreamStatus=$upstreamStatus',
      if (downstreamStatus != null) 'downstreamStatus=$downstreamStatus',
      'bytes=$bytes',
      'elapsed=${elapsed.inMilliseconds}ms',
      if (range != null) 'range=$range',
      if (siteKey != null) 'site=$siteKey',
      if (note != null) 'note=$note',
    ];
    return parts.join(' ');
  }
}
