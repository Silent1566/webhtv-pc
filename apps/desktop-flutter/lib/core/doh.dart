/// DoH（DNS over HTTPS）纯逻辑层（Phase 9 · P2-8）。
///
/// 对齐安卓 `catvod/net/OkDns.java`：
/// - 配置顶层 `doh` 是服务商列表（`{name,url,ips}`），`ips` 是 DoH 服务自身的
///   bootstrap 地址（避免用系统 DNS 去解析 DoH 域名，形成鸡生蛋问题）；
/// - 配置顶层 `hosts` 是静态域名映射（`host=ip`），命中时直接返回，不查 DoH；
/// - 两者都不存在时行为与 Phase 0–8 完全一致（走系统 DNS）。
///
/// 本文件只做「编解码 / 解析 / 校验 / 缓存模型」，不发网络请求。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// DNS 记录类型（只支持 A/AAAA/CNAME）。
abstract final class DnsRecordType {
  static const int a = 1;
  static const int cname = 5;
  static const int aaaa = 28;
}

/// DoH 服务商条目（配置文件里的 `doh` 项）。
class DohEndpoint {
  const DohEndpoint({this.name = '', required this.url, this.ips = const []});

  final String name;
  final String url;

  /// DoH 服务自身的 IP（bootstrap）。空表示用系统 DNS 解析它。
  final List<String> ips;

  bool get isValid =>
      url.startsWith('https://') && Uri.tryParse(url)?.host.isNotEmpty == true;

  /// 宽松解析：接受对象与「只有字符串」两种写法；非法项返回 null。
  static DohEndpoint? tryParse(Object? raw) {
    if (raw is String) {
      return DohEndpoint(url: raw.trim()).isValid
          ? DohEndpoint(url: raw.trim())
          : null;
    }
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String || url.trim().isEmpty) return null;
    final name = raw['name'];
    final ips = raw['ips'];
    final endpoint = DohEndpoint(
      name: name is String ? name.trim() : '',
      url: url.trim(),
      ips: [
        if (ips is List)
          for (final item in ips)
            if (item is String && item.trim().isNotEmpty) item.trim(),
      ],
    );
    return endpoint.isValid ? endpoint : null;
  }

  static List<DohEndpoint> parseList(Object? raw) {
    if (raw is! List) return const [];
    final result = <DohEndpoint>[];
    for (final item in raw) {
      final endpoint = tryParse(item);
      if (endpoint == null) continue;
      // 同一 url 只保留第一条（对齐 catvod `Doh.equals` 按 url 去重）。
      if (result.any((e) => e.url == endpoint.url)) continue;
      result.add(endpoint);
    }
    return result;
  }

  Map<String, Object?> toJson() => {
    if (name.isNotEmpty) 'name': name,
    'url': url,
  };

  @override
  bool operator ==(Object other) => other is DohEndpoint && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// 静态域名映射（配置 `hosts`，形如 `example.com=1.2.3.4`）。
class DohHostMap {
  const DohHostMap(this.entries);

  static const DohHostMap empty = DohHostMap({});

  /// 规则原文 → IP 文本（保持配置顺序）。
  final Map<String, String> entries;

  bool get isEmpty => entries.isEmpty;

  bool get isNotEmpty => entries.isNotEmpty;

  /// 宽松解析：接受 `"host=ip"`、`"host:port=ip"`（端口忽略）与
  /// `{"host":..,"ip":..}` 两种形态；IPv6 的方括号会被去掉。
  static DohHostMap parse(Object? raw) {
    if (raw is! List) return empty;
    final entries = <String, String>{};
    for (final item in raw) {
      if (item is String) {
        final index = item.indexOf('=');
        if (index <= 0) continue;
        final host = _normalizeHost(item.substring(0, index));
        final ip = _normalizeIp(item.substring(index + 1));
        if (host.isEmpty || ip == null) continue;
        entries[host] = ip;
      } else if (item is Map) {
        final host = item['host'];
        final ip = item['ip'] ?? item['value'];
        if (host is! String || ip is! String) continue;
        final normalizedHost = _normalizeHost(host);
        final normalizedIp = _normalizeIp(ip);
        if (normalizedHost.isEmpty || normalizedIp == null) continue;
        entries[normalizedHost] = normalizedIp;
      }
    }
    return DohHostMap(entries);
  }

  /// 精确匹配优先；否则按「配置键是域名后缀」匹配（对齐 catvod 的宽松包含）。
  String? lookup(String host) {
    final target = host.trim().toLowerCase();
    final exact = entries[target];
    if (exact != null) return exact;
    for (final entry in entries.entries) {
      final key = entry.key;
      if (key.startsWith('*.')) {
        final suffix = key.substring(2);
        if (target.endsWith('.$suffix')) return entry.value;
        continue;
      }
      if (target.endsWith('.$key')) return entry.value;
    }
    return null;
  }

  static String _normalizeHost(String raw) {
    var host = raw.trim().toLowerCase();
    final colon = host.lastIndexOf(':');
    if (colon > 0 && !host.contains(']')) host = host.substring(0, colon);
    return host;
  }

  static String? _normalizeIp(String raw) {
    var value = raw.trim();
    if (value.startsWith('[') && value.endsWith(']')) {
      value = value.substring(1, value.length - 1);
    }
    final colon = value.lastIndexOf(':');
    if (colon > 0 && !value.contains(':')) value = value.substring(0, colon);
    return InternetAddress.tryParse(value) == null ? null : value;
  }
}

/// 一条 DoH 查询的应答。
class DohAnswer {
  const DohAnswer({
    required this.host,
    required this.addresses,
    required this.ttlSeconds,
  });

  final String host;
  final List<String> addresses;
  final int ttlSeconds;
}

/// DoH 查询结果（成功 / 失败原因）。
class DohLookupResult {
  const DohLookupResult.success(this.answer) : error = '';

  const DohLookupResult.failure(this.error) : answer = null;

  final DohAnswer? answer;
  final String error;

  bool get ok => answer != null;
}

// ---------------------------------------------------------------------------
// DNS wire format（RFC 1035）编解码：RFC 8484 的 POST 请求体就是它
// ---------------------------------------------------------------------------

/// 构造一条 A/AAAA 查询报文。
Uint8List buildDnsQuery({
  required String host,
  int type = DnsRecordType.a,
  int id = 0,
  bool recursionDesired = true,
}) {
  final builder = BytesBuilder();
  builder.add([(id >> 8) & 0xff, id & 0xff]);
  // QR=0 OPCODE=0 AA=0 TC=0 RD=1 RA=0 Z=0 RCODE=0
  builder.add([0x00, recursionDesired ? 0x01 : 0x00]);
  builder.add([0x00, 0x01]); // QDCOUNT
  builder.add([0x00, 0x00]); // ANCOUNT
  builder.add([0x00, 0x00]); // NSCOUNT
  builder.add([0x00, 0x00]); // ARCOUNT
  for (final label in host.trim().split('.')) {
    if (label.isEmpty) continue;
    final bytes = utf8.encode(label);
    if (bytes.length > 63) {
      throw ArgumentError('DNS 标签过长：$label');
    }
    builder.addByte(bytes.length);
    builder.add(bytes);
  }
  builder.addByte(0);
  builder.add([(type >> 8) & 0xff, type & 0xff]);
  builder.add([0x00, 0x01]); // IN
  return builder.toBytes();
}

/// 解析一条 DNS 应答报文；只取 A/AAAA（CNAME 用于日志/诊断）。
DohLookupResult parseDnsResponse(Uint8List data, {required String host}) {
  if (data.length < 12) {
    return const DohLookupResult.failure('应答过短');
  }
  final flags = (data[2] << 8) | data[3];
  final rcode = flags & 0x0f;
  if (rcode != 0) {
    return DohLookupResult.failure('DNS rcode=$rcode');
  }
  final questionCount = (data[4] << 8) | data[5];
  final answerCount = (data[6] << 8) | data[7];
  var offset = 12;
  for (var i = 0; i < questionCount; i++) {
    final question = _readName(data, offset);
    if (question == null) return const DohLookupResult.failure('问题段损坏');
    offset = question.nextOffset + 4; // QTYPE + QCLASS
    if (offset > data.length) {
      return const DohLookupResult.failure('问题段越界');
    }
  }

  final addresses = <String>[];
  var minTtl = 0;
  for (var i = 0; i < answerCount; i++) {
    final name = _readName(data, offset);
    if (name == null) return const DohLookupResult.failure('应答段损坏');
    offset = name.nextOffset;
    if (offset + 10 > data.length) {
      return const DohLookupResult.failure('应答段越界');
    }
    final type = (data[offset] << 8) | data[offset + 1];
    final ttl = (data[offset + 4] << 24) |
        (data[offset + 5] << 16) |
        (data[offset + 6] << 8) |
        data[offset + 7];
    final length = (data[offset + 8] << 8) | data[offset + 9];
    final rdataStart = offset + 10;
    if (rdataStart + length > data.length) {
      return const DohLookupResult.failure('RDATA 越界');
    }
    if (type == DnsRecordType.a && length == 4) {
      addresses.add(
        '${data[rdataStart]}.${data[rdataStart + 1]}.'
        '${data[rdataStart + 2]}.${data[rdataStart + 3]}',
      );
      if (minTtl == 0 || ttl < minTtl) minTtl = ttl;
    } else if (type == DnsRecordType.aaaa && length == 16) {
      final bytes = data.sublist(rdataStart, rdataStart + 16);
      addresses.add(_formatIpv6(bytes));
      if (minTtl == 0 || ttl < minTtl) minTtl = ttl;
    }
    offset = rdataStart + length;
  }

  if (addresses.isEmpty) {
    return DohLookupResult.failure('没有 A/AAAA 记录');
  }
  return DohLookupResult.success(
    DohAnswer(
      host: host,
      addresses: addresses,
      ttlSeconds: clampDohTtl(minTtl == 0 ? 300 : minTtl),
    ),
  );
}

/// TTL 夹取：太短会导致每个请求都查 DoH，太长会让 DNS 变更久久不生效。
int clampDohTtl(int seconds) {
  if (seconds < 60) return 60;
  if (seconds > 86400) return 86400;
  return seconds;
}

/// 把 DoH 应答里的 IPv6 字节转成文本（不做零压缩，保证可逆解析）。
String _formatIpv6(Uint8List bytes) {
  final parts = <String>[];
  for (var i = 0; i < 16; i += 2) {
    parts.add(((bytes[i] << 8) | bytes[i + 1]).toRadixString(16));
  }
  return parts.join(':');
}

class _DnsName {
  const _DnsName(this.name, this.nextOffset);

  final String name;
  final int nextOffset;
}

/// 读取域名（含压缩指针）。返回 null 表示损坏/越界。
_DnsName? _readName(Uint8List data, int start) {
  final labels = <String>[];
  var offset = start;
  var nextOffset = -1;
  var hops = 0;
  while (true) {
    if (offset >= data.length) return null;
    final length = data[offset];
    if (length == 0) {
      offset += 1;
      if (nextOffset < 0) nextOffset = offset;
      break;
    }
    if ((length & 0xc0) == 0xc0) {
      if (offset + 1 >= data.length) return null;
      final pointer = ((length & 0x3f) << 8) | data[offset + 1];
      if (nextOffset < 0) nextOffset = offset + 2;
      if (pointer >= data.length || ++hops > 16) return null;
      offset = pointer;
      continue;
    }
    if ((length & 0xc0) != 0 || offset + 1 + length > data.length) return null;
    labels.add(utf8.decode(data.sublist(offset + 1, offset + 1 + length)));
    offset += 1 + length;
  }
  return _DnsName(labels.join('.'), nextOffset < 0 ? offset : nextOffset);
}

// ---------------------------------------------------------------------------
// 缓存模型
// ---------------------------------------------------------------------------

/// 一条缓存记录（磁盘格式的一部分）。
class DohCacheEntry {
  const DohCacheEntry({required this.addresses, required this.expiresAtMs});

  final List<String> addresses;
  final int expiresAtMs;

  bool expiredAt(int nowMs) => nowMs >= expiresAtMs;

  Map<String, Object?> toJson() => {
    'ips': addresses,
    'expiresAt': expiresAtMs,
  };

  static DohCacheEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final ips = raw['ips'];
    final expiresAt = raw['expiresAt'];
    if (ips is! List || expiresAt is! num) return null;
    final addresses = <String>[
      for (final item in ips)
        if (item is String && InternetAddress.tryParse(item) != null) item,
    ];
    if (addresses.isEmpty) return null;
    return DohCacheEntry(
      addresses: addresses,
      expiresAtMs: expiresAt.toInt(),
    );
  }
}

/// 磁盘缓存文件内容（`<cache>/doh_cache.json`）。
class DohCacheFile {
  const DohCacheFile({this.entries = const {}});

  static const int formatVersion = 1;

  /// 上限：避免长期运行后无界增长（每条一个域名）。
  static const int maxEntries = 512;

  final Map<String, DohCacheEntry> entries;

  /// 读取时丢弃过期项并裁剪到上限（按到期时间保留最久的）。
  DohCacheFile pruned(int nowMs, {int maxEntries = DohCacheFile.maxEntries}) {
    final alive = <String, DohCacheEntry>{
      for (final entry in entries.entries)
        if (!entry.value.expiredAt(nowMs)) entry.key: entry.value,
    };
    if (alive.length <= maxEntries) return DohCacheFile(entries: alive);
    final sorted = alive.entries.toList()
      ..sort((a, b) => b.value.expiresAtMs.compareTo(a.value.expiresAtMs));
    return DohCacheFile(
      entries: {for (final entry in sorted.take(maxEntries)) entry.key: entry.value},
    );
  }

  String encode() => jsonEncode({
    'version': formatVersion,
    'entries': {
      for (final entry in entries.entries) entry.key: entry.value.toJson(),
    },
  });

  static DohCacheFile decode(String text) {
    try {
      final raw = jsonDecode(text);
      if (raw is! Map) return const DohCacheFile();
      final version = raw['version'];
      if (version is! num || version.toInt() != formatVersion) {
        return const DohCacheFile();
      }
      final entries = raw['entries'];
      if (entries is! Map) return const DohCacheFile();
      final parsed = <String, DohCacheEntry>{};
      for (final entry in entries.entries) {
        final key = entry.key;
        if (key is! String) continue;
        final value = DohCacheEntry.tryParse(entry.value);
        if (value == null) continue;
        parsed[key] = value;
      }
      return DohCacheFile(entries: parsed);
    } catch (_) {
      return const DohCacheFile();
    }
  }
}
