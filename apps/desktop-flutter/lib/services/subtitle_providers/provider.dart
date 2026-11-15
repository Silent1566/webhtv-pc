/// 字幕源契约（`docs/superpowers/plans/2026-11-15-subtitle-online-search.md` Task 1）。
///
/// `search()` 只负责「找到候选」；`resolve()` 才把候选变成能播放的本地文件
/// ——二次跳转、ZIP 解包、落盘都由源自己处理，播放器只拿到一个路径。
library;

import '../../core/subtitle_provider.dart';
import '../../core/subtitle_settings.dart';

abstract class SubtitleProvider {
  /// 让子类保留 `const` 构造（`const LocalSubtitleProvider()` 在注册表里被复用）。
  const SubtitleProvider();

  String get id;

  String get name;

  /// 同分时的排序权重：local 50 > assrt 30 > xunlei 20 > shooter 10 > http 5。
  int get priority => 0;

  /// true 表示没有本地视频文件就没有输入（射手）。
  bool get needsLocalMediaPath => false;

  Future<List<SubtitleCandidate>> search(
    SubtitleQuery query,
    SubtitleSettings settings,
  );

  /// 默认 null：直链源不需要 resolve。
  Future<SubtitleResolvedAsset?> resolve(
    SubtitleCandidate candidate,
    SubtitleQuery query,
    SubtitleSettings settings,
  ) async => null;
}
