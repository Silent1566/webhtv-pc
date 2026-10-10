/// UI 偏好持久化（`<configDir>/settings.json` 的 `ui` 段）。
///
/// 为什么单独一段：`settings.json` 已有 `tmdb`（凭据）与 `sync`（同步白名单/设备）
/// 两段，各自有独立的 store。UI 偏好与它们语义无关，混进去会让任何一方保存时
/// 覆盖另一方的键。这里沿用同样的「读改写、只替换自己那一段」模式。
///
/// 当前只存一项：
/// - `lastSiteKey`：**最近一次使用的站点**。重启后默认加载它；只有从未选过
///   （首次使用）才退回配置里的第一个站点（用户需求 2026-10-10）。
library;

import 'dart:convert';
import 'dart:io';

import 'log_service.dart';

class UiPreferencesStore {
  UiPreferencesStore({required this.path, LogService? log}) : _log = log;

  /// `settings.json` 的绝对路径（`AppPaths.settingsPath`）。
  final String path;

  // ignore_for_file: prefer_initializing_formals
  final LogService? _log;

  String _lastSiteKey = '';
  bool _loaded = false;

  /// 最近一次使用的站点 key；从未选过时为空串。
  String get lastSiteKey => _lastSiteKey;

  /// 是否已成功读取过磁盘内容。
  bool get loaded => _loaded;

  /// 从磁盘读取。文件不存在或解析失败时保持默认值并记日志（不阻塞启动）。
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
        final ui = decoded['ui'];
        if (ui is Map) {
          final value = ui['lastSiteKey'];
          if (value is String) _lastSiteKey = value.trim();
        }
      }
      _loaded = true;
    } catch (error) {
      _log?.warning('读取 UI 偏好失败，使用默认值：$error', scope: 'ui');
      _lastSiteKey = '';
      _loaded = true;
    }
  }

  /// 记住最近使用的站点。key 为空时视为「清除记录」。
  ///
  /// 写入失败**不影响**当前会话（内存里已生效），只记日志。
  Future<bool> rememberSite(String key) async {
    final normalized = key.trim();
    if (normalized == _lastSiteKey) return true;
    _lastSiteKey = normalized;
    return _persist();
  }

  Future<bool> _persist() async {
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
      existing['ui'] = {'lastSiteKey': _lastSiteKey};

      final temporary = File('$path.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(existing),
        flush: true,
      );
      if (await file.exists()) await file.delete();
      await temporary.rename(path);
      return true;
    } catch (error) {
      _log?.error('保存 UI 偏好失败：$error', scope: 'ui');
      return false;
    }
  }
}
