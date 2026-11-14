import '../services/external_player.dart';

/// 用户记录以最初路径锚定；历史路径同时抑制扫描与旧预选的复活。
class ExternalPlayerCatalog {
  const ExternalPlayerCatalog() : _entries = const [];

  ExternalPlayerCatalog._(List<_Entry> entries)
    : _entries = List.unmodifiable(entries);

  final List<_Entry> _entries;

  bool get isEmpty => _entries.isEmpty;

  factory ExternalPlayerCatalog.fromJson(Object? raw) {
    if (raw is! List) return const ExternalPlayerCatalog();
    final entries = <_Entry>[];
    final occupied = <String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final name = item['name'];
      final executable = item['executable'];
      final original = item['originalExecutable'];
      if (name is! String ||
          name.trim().isEmpty ||
          executable is! String ||
          !ExternalPlayers.isExecutablePath(executable) ||
          original is! String ||
          original.trim().isEmpty) {
        continue;
      }
      final history = item['previousExecutables'];
      final entry = _Entry(
        player: ExternalPlayer(
          name: name.trim(),
          executable: executable.trim(),
        ),
        originalExecutable: original.trim(),
        previousExecutables: [
          if (history is List)
            for (final value in history)
              if (value is String && ExternalPlayers.isExecutablePath(value))
                value.trim(),
        ],
      );
      if (!occupied.add(_key(entry.player.executable))) continue;
      entries.add(entry);
    }
    return ExternalPlayerCatalog._(entries);
  }

  List<Map<String, Object?>> toJson() => [
    for (final entry in _entries)
      {
        'name': entry.player.name,
        'executable': entry.player.executable,
        'originalExecutable': entry.originalExecutable,
        if (entry.previousExecutables.isNotEmpty)
          'previousExecutables': entry.previousExecutables,
      },
  ];

  List<ExternalPlayer> list(
    List<ExternalPlayer> scanned, {
    String? legacyExecutable,
  }) {
    final result = <ExternalPlayer>[];
    final seen = <String>{};
    void add(ExternalPlayer player) {
      if (seen.add(_key(player.executable))) result.add(player);
    }

    for (final player in scanned) {
      final override = _find(player.executable);
      add(override?.player ?? player);
    }
    for (final entry in _entries) {
      add(entry.player);
    }
    final legacy = legacyExecutable?.trim() ?? '';
    if (legacy.isNotEmpty && _find(legacy) == null) {
      add(
        ExternalPlayer(
          name: legacy.split(RegExp(r'[/\\]')).last,
          executable: legacy,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  /// 返回 null 表示拒绝保存；调用者只在成功落盘后提交新的目录。
  ExternalPlayerCatalog? save({
    String? originalExecutable,
    required String name,
    required String executable,
    required List<ExternalPlayer> scanned,
    String? legacyExecutable,
  }) {
    final label = name.trim();
    final target = executable.trim();
    if (label.isEmpty || !ExternalPlayers.isExecutablePath(target)) return null;
    final original = originalExecutable?.trim();
    final existing = original == null ? null : _findCurrent(original);
    if (original != null &&
        existing == null &&
        !list(
          scanned,
          legacyExecutable: legacyExecutable,
        ).any((player) => _key(player.executable) == _key(original))) {
      return null;
    }

    final targetKey = _key(target);
    if (list(scanned, legacyExecutable: legacyExecutable).any(
      (player) =>
          _key(player.executable) == targetKey &&
          (original == null || _key(player.executable) != _key(original)),
    )) {
      return null;
    }
    final history = <String, String>{};
    if (existing != null) {
      for (final path in existing.previousExecutables) {
        history[_key(path)] = path;
      }
    }
    if (original != null) history[_key(original)] = original;
    history.remove(targetKey);
    final entry = _Entry(
      player: ExternalPlayer(name: label, executable: target),
      originalExecutable: existing?.originalExecutable ?? original ?? target,
      previousExecutables: history.values.toList(),
    );
    final entries = [..._entries];
    if (existing == null) {
      entries.add(entry);
    } else {
      entries[entries.indexOf(existing)] = entry;
    }
    return ExternalPlayerCatalog._(entries);
  }

  String? resolveExecutable(String? executable) {
    if (executable == null) return null;
    return _find(executable)?.player.executable ?? executable;
  }

  _Entry? _find(String executable) {
    final current = _findCurrent(executable);
    if (current != null) return current;
    final key = _key(executable);
    for (final entry in _entries.reversed) {
      if (entry.historicalKeys.contains(key)) return entry;
    }
    return null;
  }

  _Entry? _findCurrent(String executable) {
    final key = _key(executable);
    for (final entry in _entries) {
      if (_key(entry.player.executable) == key) return entry;
    }
    return null;
  }
}

String _key(String executable) =>
    ExternalPlayers.normalizeExecutablePath(executable);

class _Entry {
  _Entry({
    required this.player,
    required this.originalExecutable,
    required List<String> previousExecutables,
  }) : previousExecutables = List.unmodifiable(previousExecutables);

  final ExternalPlayer player;
  final String originalExecutable;
  final List<String> previousExecutables;

  Set<String> get historicalKeys => {
    _key(originalExecutable),
    ...previousExecutables.map(_key),
  };
}
