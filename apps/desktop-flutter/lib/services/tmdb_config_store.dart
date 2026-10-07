/// TMDB 配置持久化（`docs/phase4/design/03` §5.3、§5.5）。
///
/// 位置：`<configDir>/settings.json` 的 `tmdb` 段。
///
/// 为什么**不进配置 JSON**（`03` §5.3）：
/// 1. TMDB 是应用级能力，与站源配置无关；放进 `AppConfig` 会随配置记录写回，
///    在设备间同步时携带凭据；
/// 2. 切换配置不应改变 TMDB 设置。
///
/// 写入策略：**单写入点 + 原子写**（临时文件 + rename，`04` §R4）。
/// 读取失败（文件不存在 / 非法 JSON）一律退回默认配置，**不阻塞启动**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/tmdb_config.dart';
import 'log_service.dart';

class TmdbConfigStore {
  TmdbConfigStore({required this.path, LogService? log}) : _log = log;

  /// `settings.json` 的绝对路径（`AppPaths.settingsPath`）。
  final String path;
  final LogService? _log;

  // ignore_for_file: prefer_initializing_formals

  TmdbConfig _config = const TmdbConfig();
  bool _loaded = false;

  /// 当前配置。未调用 [load] 时为默认配置。
  TmdbConfig get config => _config;

  /// 是否已成功读取过磁盘内容。
  bool get loaded => _loaded;

  /// 从磁盘读取。文件不存在或解析失败时保持默认配置并记日志。
  Future<void> load() async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        _loaded = true;
        return;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        _loaded = true;
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _config = TmdbConfig.fromJson(decoded['tmdb']);
      }
      _loaded = true;
    } catch (error) {
      // 设置文件损坏不得阻塞启动（`03` §5.5）。
      _log?.warning('读取 TMDB 设置失败，使用默认配置：$error', scope: 'tmdb');
      _config = const TmdbConfig();
      _loaded = true;
    }
  }

  /// 原子写入。返回是否成功。
  ///
  /// 保留 `settings.json` 中其它顶层键（未来设置项），只替换 `tmdb` 段。
  Future<bool> save(TmdbConfig config) async {
    _config = config;
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final existing = <String, Object?>{};
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            existing.addAll(decoded.cast<String, Object?>());
          }
        } catch (_) {
          // 旧文件损坏 → 直接覆盖，不把损坏内容带进新文件。
        }
      }
      existing['tmdb'] = config.toJson();

      final temporary = File('$path.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(existing),
        flush: true,
      );
      // rename 在同一卷上是原子操作（Windows 上会先删除目标）。
      if (await file.exists()) await file.delete();
      await temporary.rename(path);
      _log?.info('TMDB 设置已保存（凭据已脱敏）', scope: 'tmdb');
      return true;
    } catch (error) {
      _log?.error('保存 TMDB 设置失败：$error', scope: 'tmdb');
      return false;
    }
  }

  /// 便于诊断：设置文件所在目录。
  String get directory => p.dirname(path);
}
