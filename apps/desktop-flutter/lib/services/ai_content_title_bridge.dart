/// Task5 · Task4 typed 片名结果 → 季集身份回退的桥接。
///
/// 边界（调度合同）：
/// - 片名解析、缓存、学习全部归 Task4（`core/ai_content/title_resolution.dart`）；
///   本文件只做**适配**，不重造片名 AI，也不复制其缓存/学习逻辑。
/// - 身份回退**不猜 ID**：回退只把清洗后的片名交给 TMDB 搜索，TMDB 命中才给 ID。
/// - **弱信心不覆盖**：既有任何匹配（manual 或 auto）时一律不发起回退。
library;

import '../core/ai_content/title_resolution.dart';
import 'ai_season_mapping_service.dart';

/// 把 Task4 的 typed `TitleResolution` 适配成本层最小注入接口。
///
/// Task4 的 resolver 继续持有自己的规则/学习/AI/缓存顺序；这里只是把它的
/// 输出收敛成 [SeasonTitleResolution]，供季集身份回退使用。
class AiContentTitleResolverAdapter implements SeasonTitleResolver {
  // ignore_for_file: prefer_initializing_formals
  AiContentTitleResolverAdapter({
    required Future<TitleResolution?> Function(TitleQuery query) resolveTyped,
  }) : _resolveTyped = resolveTyped;

  final Future<TitleResolution?> Function(TitleQuery query) _resolveTyped;

  @override
  Future<SeasonTitleResolution?> resolve(SeasonTitleQuery query) async {
    final typed = await _resolveTyped(
      TitleQuery(rawTitle: query.rawTitle),
    );
    if (typed == null) return null;
    final title = typed.title.trim();
    if (title.isEmpty) return null;
    return SeasonTitleResolution(
      title: title,
      confidence: typed.confidence,
      year: typed.year,
      mediaType: typed.mediaType?.wireName,
    );
  }
}

/// 身份回退的检索词闸门。
///
/// 返回 `null` 表示**不要回退**：既有匹配存在（含 manual）、resolver 无结果、
/// 或信心不足。返回非空字符串则是交给 TMDB 搜索的清洗片名（不是 ID）。
String? identityFallbackRequest({
  required String rawTitle,
  required int existingTmdbId,
  required bool existingIsManual,
  required SeasonTitleResolution? resolution,
}) {
  if (existingTmdbId > 0) return null;
  if (existingIsManual) return null;
  if (resolution == null) return null;
  if (resolution.title.trim().isEmpty) return null;
  if (!shouldWriteIdentityFallback(
    existingTmdbId: existingTmdbId,
    existingIsManual: existingIsManual,
    confidence: resolution.confidence,
  )) {
    return null;
  }
  return resolution.title.trim();
}
