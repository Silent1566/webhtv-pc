library;

import 'dart:convert';
import 'dart:io';

import '../core/ai_config.dart';
import 'log_service.dart';
import 'settings_file.dart';

class AiConfigStore {
  AiConfigStore({required this.path, LogService? log}) : _log = log;

  /// `settings.json` 的绝对路径（`AppPaths.settingsPath`）。
  final String path;

  // ignore_for_file: prefer_initializing_formals
  final LogService? _log;

  AiConfig _config = const AiConfig();
  bool _loaded = false;

  /// 当前配置（始终是归一化后的）。
  AiConfig get config => _config;

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
        _config = AiConfig.fromJson(decoded['ai']);
      }
      _loaded = true;
    } catch (error) {
      _log?.warning('读取 AI 配置失败，使用默认值：$error', scope: 'ai');
      _config = const AiConfig();
      _loaded = true;
    }
  }

  /// 保存配置。写盘失败**不影响**当前会话（内存里已生效），只记日志。
  Future<bool> save(AiConfig next) {
    _config = next.sanitized();
    return _persist();
  }

  Future<bool> _persist() async {
    final result = writeSettingsSectionSync(
      path: path,
      writer: SettingsWriter.aiConfig,
      mutate: (root) {
        root['ai'] = _config.toJson();
        return true;
      },
    );
    if (!result.ok) _log?.error('保存 AI 配置失败：${result.error}', scope: 'ai');
    return result.ok;
  }
}
