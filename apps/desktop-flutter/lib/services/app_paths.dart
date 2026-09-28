/// 平台标准目录（§16.1）。
///
/// Windows 使用 `%APPDATA%` / `%LOCALAPPDATA%`；Linux/macOS 使用 XDG 约定。
/// 设计文档要求“删除缓存目录后应用可重建”“不依赖开发机 PATH/HOME”，
/// 因此这里所有目录都可创建、可删除，且在创建失败时退化到进程工作目录而不是崩溃。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

class AppPaths {
  AppPaths._({
    required this.configDir,
    required this.dataDir,
    required this.cacheDir,
    required this.logDir,
  });

  final String configDir;
  final String dataDir;
  final String cacheDir;
  final String logDir;

  String get databasePath =>
      p.join(dataDir, 'webhtv-pc.sqlite3');

  String get configRecordsPath =>
      p.join(configDir, 'configs.json');

  String get settingsPath => p.join(configDir, 'settings.json');

  String get evidenceDir => p.join(dataDir, 'evidence');

  static String _env(String name) => Platform.environment[name] ?? '';

  /// 解析平台目录。可注入 [overrides] 供测试使用独立目录。
  static AppPaths resolve({
    Map<String, String> overrides = const {},
    String appName = 'webhtv-pc',
  }) {
    String config;
    String data;
    String cache;
    String state;

    if (Platform.isWindows) {
      final roaming = overrides['roaming'] ??
          _env('APPDATA').ifEmpty(() => p.join(_home(), 'AppData', 'Roaming'));
      final local = overrides['local'] ??
          _env('LOCALAPPDATA').ifEmpty(() => p.join(_home(), 'AppData', 'Local'));
      config = p.join(roaming, appName);
      data = p.join(local, appName);
      cache = p.join(local, appName, 'cache');
      state = p.join(local, appName, 'logs');
    } else {
      final home = _home();
      final xdgConfig = overrides['xdgConfig'] ??
          _env('XDG_CONFIG_HOME').ifEmpty(() => p.join(home, '.config'));
      final xdgData = overrides['xdgData'] ??
          _env('XDG_DATA_HOME').ifEmpty(() => p.join(home, '.local', 'share'));
      final xdgCache = overrides['xdgCache'] ??
          _env('XDG_CACHE_HOME').ifEmpty(() => p.join(home, '.cache'));
      final xdgState = overrides['xdgState'] ??
          _env('XDG_STATE_HOME').ifEmpty(() => p.join(home, '.local', 'state'));
      config = p.join(xdgConfig, appName);
      data = p.join(xdgData, appName);
      cache = p.join(xdgCache, appName);
      state = p.join(xdgState, appName, 'logs');
    }

    if (Platform.isMacOS) {
      final home = _home();
      config = p.join(home, 'Library', 'Application Support', appName);
      data = config;
      cache = p.join(home, 'Library', 'Caches', appName);
      state = p.join(home, 'Library', 'Logs', appName);
    }

    return AppPaths._(
      configDir: overrides['config'] ?? config,
      dataDir: overrides['data'] ?? data,
      cacheDir: overrides['cache'] ?? cache,
      logDir: overrides['state'] ?? state,
    );
  }

  static String _home() {
    final profile = _env('USERPROFILE');
    if (profile.isNotEmpty) return profile;
    final home = _env('HOME');
    if (home.isNotEmpty) return home;
    return Directory.current.path;
  }

  /// 创建所有目录。任何一步失败都返回失败结果而不是抛出，让 UI 明确提示。
  Future<List<String>> ensureDirectories() async {
    final failures = <String>[];
    for (final dir in [configDir, dataDir, cacheDir, logDir]) {
      try {
        if (!await Directory(dir).exists()) {
          await Directory(dir).create(recursive: true);
        }
      } catch (error) {
        failures.add('$dir: $error');
      }
    }
    return failures;
  }
}

extension _IfEmpty on String {
  String ifEmpty(String Function() fallback) =>
      isEmpty ? fallback() : this;
}
