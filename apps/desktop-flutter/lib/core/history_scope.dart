/// 历史记录的可见范围（按源隔离 / 全局）。
///
/// 默认 [UiHistoryScope.source]：历史只显示**当前播放源**的记录。语义与安卓的
/// `global_history_mode` 对齐，但不是同一个开关——安卓只是运行容器，PC 的历史
/// 显示范围属于 PC 本地偏好，**不写回安卓**。
///
/// 存字符串而不是 enum：本层是纯逻辑层，且要与 `settings.json` 的字面值一一
/// 对应（与 `UiHistoryClickAction`、`UiThemeMode` 同样的分层理由）。
library;

abstract final class UiHistoryScope {
  /// 只看当前源（默认）。
  static const String source = 'source';

  /// 看所有源。
  static const String global = 'global';

  static const List<String> values = [source, global];

  /// 把任意输入归一化成合法值；不认识的值回落到默认 [source]。
  ///
  /// 回落方向选"更保守"的那一侧：误判成全局会把别的源的历史混进来，用户会
  /// 以为数据串了；误判成当前源最多是少看见几条。
  static String normalize(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    return values.contains(value) ? value : source;
  }

  /// 是否为全局模式。
  static bool isGlobal(String? raw) => normalize(raw) == global;
}
