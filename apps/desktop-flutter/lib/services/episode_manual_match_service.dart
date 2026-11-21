/// 集级手动匹配的持久化原语。
///
/// 契约见 `docs/superpowers/specs/2026-11-21-episode-manual-match-design.md` §4：
/// 锚点按「配置/站点/影片/标题/线路」五元键存取，`anchors` 列是
/// `EpisodeMatchAnchor` 的 JSON 数组；不存全局快照，失效由调用方按
/// `EpisodeManualMatch.relocate` 逐条判定。
///
/// 读路径永不抛：无行、空串、坏 JSON、非数组一律返回 `const []`。
library;

import 'dart:convert';

import '../core/episode_manual_match.dart';
import 'storage.dart';

class EpisodeManualMatchService {
  EpisodeManualMatchService({required AppDatabase database})
    : _database = database; // ignore: prefer_initializing_formals

  final AppDatabase _database;

  /// 读取一条线路保存的锚点；无行或数据不可解析时返回空列表。
  List<EpisodeMatchAnchor> load({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
  }) {
    final row = _database.findEpisodeManualBindings(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
    );
    if (row == null) return const [];
    return _decodeAnchors(row['anchors'] as String?);
  }

  /// 该行记录的作品身份（供调用方在身份变化时清除过期锚点）。
  ///
  /// 无行返回 `null`；有行返回表里原样存储的 `tmdb_id`/`media_type`。
  ({int tmdbId, String mediaType})? loadScope({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
  }) {
    final row = _database.findEpisodeManualBindings(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
    );
    if (row == null) return null;
    final tmdbId = row['tmdb_id'];
    final mediaType = row['media_type'];
    return (
      tmdbId: tmdbId is int ? tmdbId : 0,
      mediaType: mediaType is String ? mediaType : '',
    );
  }

  /// 覆盖写入一条线路的锚点（同键 update，不新增行）。
  void save({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
    required int tmdbId,
    required String mediaType,
    required List<EpisodeMatchAnchor> anchors,
  }) {
    _database.upsertEpisodeManualBindings(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
      tmdbId: tmdbId,
      mediaType: mediaType,
      anchors: [for (final anchor in anchors) anchor.toJson()],
    );
  }

  /// 删除一条线路的锚点（整行删除，`load` 之后返回空列表）。
  void clear({
    required int configId,
    required String siteKey,
    required String vodId,
    required String sourceTitle,
    required String flagKey,
  }) {
    _database.removeEpisodeManualBindings(
      configId: configId,
      siteKey: siteKey,
      vodId: vodId,
      sourceTitle: sourceTitle,
      flagKey: flagKey,
    );
  }

  static List<EpisodeMatchAnchor> _decodeAnchors(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      return EpisodeMatchAnchor.listFromJson(jsonDecode(raw));
    } on FormatException {
      return const [];
    }
  }
}
