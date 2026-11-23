import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Source URLs, not route types, own their validators and response bodies.
class AppUpdateCacheEntry {
  const AppUpdateCacheEntry({
    required this.body,
    required this.savedAt,
    this.etag,
    this.lastModified,
  });

  final String body;
  final DateTime savedAt;
  final String? etag;
  final String? lastModified;

  Map<String, Object?> toJson() => {
    'body': body,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'etag': ?etag,
    'lastModified': ?lastModified,
  };

  static AppUpdateCacheEntry? fromJson(Object? raw) {
    if (raw is! Map || raw['body'] is! String || raw['savedAt'] is! String) {
      return null;
    }
    final savedAt = DateTime.tryParse(raw['savedAt'] as String);
    final body = raw['body'] as String;
    if (savedAt == null || utf8.encode(body).length > 2 * 1024 * 1024) {
      return null;
    }
    return AppUpdateCacheEntry(
      body: body,
      savedAt: savedAt.toUtc(),
      etag: raw['etag'] is String ? raw['etag'] as String : null,
      lastModified: raw['lastModified'] is String
          ? raw['lastModified'] as String
          : null,
    );
  }
}

/// Best-effort metadata only: cache failures must never change network verdicts.
class AppUpdateMetadataCache {
  AppUpdateMetadataCache(this.directory);

  final Directory? directory;
  final entries = <String, AppUpdateCacheEntry>{};
  final cooldowns = <String, DateTime>{};
  Future<void>? _loading;
  Future<void> _writes = Future.value();
  static int _serial = 0;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final root = directory;
    if (root == null) return;
    try {
      final file = File(p.join(root.path, 'releases-cache.json'));
      if (await file.length() > 8 * 1024 * 1024) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['version'] != 1) return;
      final bodies = raw['entries'];
      if (bodies is Map) {
        for (final item in bodies.entries.take(8)) {
          if (item.key is! String) continue;
          final entry = AppUpdateCacheEntry.fromJson(item.value);
          if (entry != null) entries[item.key as String] = entry;
        }
      }
      final retries = raw['cooldowns'];
      if (retries is Map) {
        for (final item in retries.entries.take(8)) {
          if (item.key is! String || item.value is! String) continue;
          final retryAt = DateTime.tryParse(item.value as String);
          if (retryAt != null) cooldowns[item.key as String] = retryAt.toUtc();
        }
      }
    } on Object {
      // Missing, corrupt or unwritable cache behaves like an empty cache.
    }
  }

  Future<void> save() {
    final root = directory;
    if (root == null) return Future.value();
    final content = jsonEncode({
      'version': 1,
      'entries': {
        for (final item in entries.entries) item.key: item.value.toJson(),
      },
      'cooldowns': {
        for (final item in cooldowns.entries)
          item.key: item.value.toUtc().toIso8601String(),
      },
    });
    return _writes = _writes.then((_) async {
      File? temporary;
      try {
        await root.create(recursive: true);
        final target = p.join(root.path, 'releases-cache.json');
        temporary = File('$target.$pid.${_serial++}.tmp');
        await temporary.writeAsString(content, flush: true);
        await temporary.rename(target);
      } on Object {
        // Atomic rename leaves the previous complete cache available on failure.
      } finally {
        try {
          if (temporary != null && await temporary.exists()) {
            await temporary.delete();
          }
        } on Object {
          // Cache cleanup is best effort too.
        }
      }
    });
  }
}
