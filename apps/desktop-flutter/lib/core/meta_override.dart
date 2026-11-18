/// 用户手动指定的元数据身份（超过自动匹配）。
///
/// 为什么需要它：自动匹配再准也有认错的时候（同名续作、翻拍、季号缺失），
/// 而 TMDB 的手动匹配只覆盖 TMDB 一家。这里把「这一部影片用哪个来源的哪一条」
/// 收敛成一张表，三个来源都只是它的写入者，匹配/展示只读它。
///
/// 与 TMDB 的关系：**不替换** `TmdbMatchRecord`（那是 TMDB 自己的匹配结论与
/// 冲突标记），只作为「外部来源」的独立覆盖层，两者互不覆盖。
library;

import 'external_meta.dart';
import 'meta_source.dart';

/// `vodId → MetaIdentity` 的持久化覆盖表。
class MetaOverrideStore {
  MetaOverrideStore([Map<String, MetaIdentity>? initial])
      : _entries = {...?initial};

  final Map<String, MetaIdentity> _entries;

  /// 全部条目（只读快照，供设置页/诊断展示）。
  Map<String, MetaIdentity> get entries => Map.unmodifiable(_entries);

  MetaIdentity? of(String vodId) => _entries[vodId.trim()];

  /// 钉住一条身份；vodId 为空或身份非法时不写入并返回 false。
  bool pin(String vodId, MetaIdentity identity) {
    final key = vodId.trim();
    if (key.isEmpty || identity.id <= 0) return false;
    _entries[key] = identity;
    return true;
  }

  /// 取消钉住；返回是否真的删掉了。
  bool unpin(String vodId) => _entries.remove(vodId.trim()) != null;

  bool get isEmpty => _entries.isEmpty;

  Map<String, Object?> toJson() => {
    for (final entry in _entries.entries) entry.key: entry.value.key,
  };

  /// 解析持久化表：未知/非法键值一律忽略，绝不因此丢掉整张表。
  static MetaOverrideStore fromJson(Object? value) {
    final entries = <String, MetaIdentity>{};
    if (value is Map) {
      for (final entry in value.entries) {
        final vodId = '${entry.key}'.trim();
        final identity = MetaIdentity.parse('${entry.value}');
        if (vodId.isEmpty || identity == null) continue;
        if (identity.kind == MetaSourceKind.tmdb) {
          // TMDB 的手动结论归 `TmdbMatchRecord` 管，这里只收外部来源。
          continue;
        }
        entries[vodId] = identity;
      }
    }
    return MetaOverrideStore(entries);
  }
}