/// 应用更新偏好（settings.json 的 update 段，ADR-0015）。
///
/// 与 UiPreferencesStore / TmdbConfigStore 同一模式：读改写只替换自己那一段，
/// 临时文件名由 SettingsWriter.update 独占。为什么单独一段而不是塞进 ui：
/// 更新偏好属于「应用本体」，日后同步到安卓也是独立键。
library;

// 具名参数 log 与私有字段 _log 不同名，不能写成初始化形参。
// ignore_for_file: prefer_initializing_formals

import '../core/app_update.dart';
import 'log_service.dart';
import 'settings_file.dart';

class UpdatePreferencesStore {
  UpdatePreferencesStore({required this.path, LogService? log}) : _log = log;

  /// settings.json 的绝对路径（AppPaths.settingsPath）。
  final String path;

  final LogService? _log;

  AppUpdatePreferences _preferences = AppUpdatePreferences.defaults;

  /// 本次进程读到/写入的最新值。
  AppUpdatePreferences get preferences => _preferences;

  bool _loaded = false;

  /// load() 是否跑过（测试与「从没检查过」的展示要区分这两种空值）。
  bool get loaded => _loaded;

  /// 读取 update 段。文件缺失/损坏/键非法都回落默认值，绝不抛错。
  Future<void> load() async {
    try {
      final root = readSettingsRootSync(path);
      _preferences = AppUpdatePreferences.fromJson(root['update']);
    } on Object catch (error) {
      _log?.warning('读取更新偏好失败，回落默认值：$error', scope: 'update');
      _preferences = AppUpdatePreferences.defaults;
    }
    _loaded = true;
  }

  /// 保存新偏好；值没变时不写盘。
  Future<bool> persist(AppUpdatePreferences next) async {
    if (next == _preferences) return true;
    final result = writeSettingsSectionSync(
      path: path,
      writer: SettingsWriter.update,
      mutate: (root) {
        root['update'] = next.toJson();
        return true;
      },
    );
    if (!result.ok) {
      final reason = result.error;
      _log?.warning('保存更新偏好失败：$reason', scope: 'update');
      return false;
    }
    _preferences = next;
    return true;
  }
}
