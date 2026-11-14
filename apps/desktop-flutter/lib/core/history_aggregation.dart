/// 历史记录的**聚合模式**（同名作品合并成一张卡）。
///
/// 三档语义（对应用户 2026-10-27 的需求「历史记录需要支持同名聚合，优先 tmdb，
/// 没有配置等情况再基于名称等信息」）：
///
/// - [off]：保持 v7 的「每集一条独立记录」形态，一张卡就是一条历史；
/// - [tmdb]：优先按 TMDB 身份 `(mediaType, tmdbId)` 合并；**没有 TMDB 身份**
///   的记录再按「规范化片名 + 年份」合并；
/// - [title]：只按「规范化片名 + 年份」合并，完全不看 TMDB。
///
/// 默认 [tmdb]：这是用户明确要求的「默认这种模式」，同时保留 [off] 让用户
/// 能手动切回原来的逐集形态。
///
/// 为什么不是纯 enum：与 [UiHistoryScope]、[UiThemeMode] 同一分层理由——
/// 本层是纯逻辑层，取值要与 `settings.json` 的字面值一一对应，UI 只依赖
/// `AppState` 暴露的原始字符串。
library;

abstract final class UiHistoryAggregation {
  /// 不聚合：每集一条独立历史（v7 既有形态）。
  static const String off = 'none';

  /// 优先 TMDB，缺失 TMDB 身份时回退按片名+年份（默认）。
  static const String tmdb = 'tmdb';

  /// 只按片名+年份合并。
  static const String title = 'title';

  static const List<String> values = [tmdb, off, title];

  /// 把任意输入归一化成合法值；不认识的值回落到默认 [tmdb]。
  ///
  /// 回落方向选「默认档」而不是「保守档」：聚合是本功能的默认体验，
  /// 手改坏设置文件时不该把用户静默降级回逐集形态。
  static String normalize(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    return values.contains(value) ? value : tmdb;
  }

  /// 是否启用聚合。
  static bool isAggregated(String? raw) => normalize(raw) != off;

  /// 聚合时是否使用 TMDB 身份。
  static bool usesTmdb(String? raw) {
    final mode = normalize(raw);
    return mode == tmdb;
  }
}
