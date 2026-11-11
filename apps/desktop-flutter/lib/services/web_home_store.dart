/// HTML 首页注入（webHome）的持久化登记表。
///
/// 本地页面资源与在线 URL 都登记在独立的 `registry.json` 中；
/// 不放进 `spiders/`，避免被 sidecar 爬虫注册表误识别。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 一个已导入的 webHome 源。
class WebHomeSource {
  const WebHomeSource({
    required this.key,
    required this.name,
    required this.entry,
    required this.importedAt,
    required this.entrySha256,
    this.enabled = true,
    this.remoteUrl = '',
    this.modifiedAt = '',
  });

  final String key;
  final String name;

  /// 本地入口文件名（相对源目录）。
  final String entry;
  final String importedAt;
  final String entrySha256;
  final bool enabled;

  /// 在线加载原 URL；为空时使用本地资源。
  final String remoteUrl;

  /// 原入口文件扫描时的修改时间（ISO-8601）；未知时为空。
  final String modifiedAt;

  bool get isRemote => remoteUrl.isNotEmpty;

  WebHomeSource copyWith({
    String? name,
    bool? enabled,
    String? remoteUrl,
    String? modifiedAt,
  }) => WebHomeSource(
    key: key,
    name: name ?? this.name,
    entry: entry,
    importedAt: importedAt,
    entrySha256: entrySha256,
    enabled: enabled ?? this.enabled,
    remoteUrl: remoteUrl ?? this.remoteUrl,
    modifiedAt: modifiedAt ?? this.modifiedAt,
  );

  factory WebHomeSource.fromJson(Map<Object?, Object?> map) => WebHomeSource(
    key: '${map['key'] ?? ''}',
    name: '${map['name'] ?? ''}',
    entry: '${map['entry'] ?? 'index.html'}',
    importedAt: '${map['importedAt'] ?? ''}',
    entrySha256: '${map['entrySha256'] ?? ''}',
    enabled: map['enabled'] != false,
    remoteUrl: '${map['remoteUrl'] ?? ''}',
    modifiedAt: '${map['modifiedAt'] ?? ''}',
  );

  Map<String, Object?> toJson() => {
    'key': key,
    'name': name,
    'entry': entry,
    'importedAt': importedAt,
    'entrySha256': entrySha256,
    'enabled': enabled,
    'remoteUrl': remoteUrl,
    'modifiedAt': modifiedAt,
  };
}

/// webHome 注册表（读改写整个 `registry.json`，条目数很小）。
class WebHomeStore {
  WebHomeStore({required this.root});

  final String root;

  String get registryPath => p.join(root, 'registry.json');

  /// key 必须是单个安全目录名；Windows 保留名也不能作为资源目录。
  static bool isValidKey(String key) =>
      key.isNotEmpty &&
      key != '.' &&
      key != '..' &&
      key.trim() == key &&
      !key.endsWith('.') &&
      !RegExp(r'[\\/:*?"<>|\x00-\x1f\x7f]').hasMatch(key) &&
      !RegExp(
        r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(key);

  /// 某个源的资源目录，禁止目录穿越。
  String directoryFor(String key) {
    if (!isValidKey(key)) throw ArgumentError.value(key, 'key', '非法源 key');
    return p.join(root, key);
  }

  List<WebHomeSource> list() {
    final file = File(registryPath);
    final type = FileSystemEntity.typeSync(registryPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return const [];
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('登记路径不是普通文件', registryPath);
    }
    final decoded = jsonDecode(file.readAsStringSync());
    final items = decoded is Map ? decoded['items'] : decoded;
    if (items is! List || items.any((item) => item is! Map)) {
      throw FormatException('登记表 items 必须是记录列表', registryPath);
    }
    final sources = items
        .map((item) => WebHomeSource.fromJson(item as Map))
        .toList(growable: false);
    if (sources.any((item) => item.key.isEmpty)) {
      throw FormatException('登记表记录缺少 key', registryPath);
    }
    return sources;
  }

  void save(List<WebHomeSource> items) {
    list();
    final dir = Directory(root);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File(registryPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'items': items.map((item) => item.toJson()).toList(),
      }),
      flush: true,
    );
  }

  /// 只登记网址，不请求页面或下载副本；URL 和 key 冲突都明确拒绝。
  WebHomeSource addRemote(String url, {String? name}) {
    final original = url.trim();
    final uri = Uri.tryParse(original);
    final authority =
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]*)')
            .firstMatch(original)
            ?.group(1) ??
        '';
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        authority.contains('@') ||
        authority.contains('%') ||
        authority.endsWith(':') ||
        RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(original) ||
        RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(original) ||
        uri.host.contains('%') ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw ArgumentError.value(url, 'url', '需要无用户凭据的合法 http(s) 地址');
    }
    if (!uri.host.contains(':')) {
      if (RegExp(r'^[0-9.]+$').hasMatch(uri.host)) {
        final parts = uri.host.split('.');
        if (parts.length != 4 ||
            parts.any((part) {
              final number = int.tryParse(part);
              return number == null || number < 0 || number > 255;
            })) {
          throw ArgumentError.value(url, 'url', '非法 IPv4 host');
        }
      }
      final host = uri.host.endsWith('.')
          ? uri.host.substring(0, uri.host.length - 1)
          : uri.host;
      if (host
          .split('.')
          .any(
            (label) =>
                !RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$')
                    .hasMatch(label),
          )) {
        throw ArgumentError.value(url, 'url', '非法 host');
      }
    }
    final items = list().toList();
    if (items.any(
      (item) => item.isRemote && Uri.tryParse(item.remoteUrl) == uri,
    )) {
      throw StateError('该 URL 已登记');
    }
    final key = 'remote-${sha256.convert(utf8.encode(original))}';
    if (items.any((item) => item.key.toLowerCase() == key) ||
        FileSystemEntity.typeSync(directoryFor(key), followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw StateError('源 key 已存在（key=$key），不会覆盖既有源');
    }
    final source = WebHomeSource(
      key: key,
      name: name?.trim().isNotEmpty == true ? name!.trim() : uri.host,
      entry: '',
      importedAt: DateTime.now().toIso8601String(),
      entrySha256: '',
      remoteUrl: original,
    );
    items.add(source);
    items.sort((a, b) => a.key.compareTo(b.key));
    save(items);
    return source;
  }

  bool contains(String key) => list().any((item) => item.key == key);

  WebHomeSource? byKey(String key) {
    for (final item in list()) {
      if (item.key == key) return item;
    }
    return null;
  }

  void upsert(WebHomeSource source) {
    final items = list().where((item) => item.key != source.key).toList()
      ..add(source);
    items.sort((a, b) => a.key.compareTo(b.key));
    save(items);
  }

  bool setEnabled(String key, bool enabled) {
    final items = list();
    final index = items.indexWhere((item) => item.key == key);
    if (index < 0) return false;
    items[index] = items[index].copyWith(enabled: enabled);
    save(items);
    return true;
  }

  /// 远端只移除登记；本地只删除已登记、安全 key 的资源目录。
  bool remove(String key) {
    if (!isValidKey(key)) return false;
    final items = list();
    final matches = items.where((item) => item.key == key).toList();
    if (matches.isEmpty) return false;
    if (matches.every((item) => !item.isRemote)) {
      final dir = Directory(directoryFor(key));
      if (FileSystemEntity.typeSync(dir.path, followLinks: false) ==
          FileSystemEntityType.link) {
        return false;
      }
      if (dir.existsSync()) {
        final resolvedRoot = Directory(root).resolveSymbolicLinksSync();
        final resolvedDir = dir.resolveSymbolicLinksSync();
        if (!p.isWithin(resolvedRoot, resolvedDir)) return false;
        dir.deleteSync(recursive: true);
      }
    }
    save(items.where((item) => item.key != key).toList());
    return true;
  }
}
