// ignore_for_file: prefer_initializing_formals
/// 推荐服务：三种输入 → AI → TMDB 富集/降级卡 → 负反馈过滤 → 缓存。
///
/// 业务链完整（不是预览页）：调用方拿到的是 [RecommendationCard] 列表，
/// 可以直接渲染、可以点「不感兴趣」（写入用户数据）、可以打开 TMDB。
///
/// 富集由调用方注入（现有 TMDB 身份解析），本层不 import TMDB 服务，
/// 避免内容智能域与元数据域互相依赖。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ai_config.dart';
import '../../core/ai_content/ai_content_contracts.dart';
import '../../core/ai_content/recommendation.dart';
import '../../core/ai_content/recommendation_feedback.dart';
import '../../core/ai_content/title_resolution.dart' show TitleQuery;
import '../log_service.dart';
import 'ai_content_completion.dart';
import 'ai_content_paths.dart';
import 'user_data_store.dart';

/// TMDB 富集注入点：按顺序返回与 items 等长的结果，未命中的位置为 null。
typedef RecommendationEnricher =
    Future<List<RecommendationEnrichment?>> Function(List<RecommendationItem> items);

class RecommendationService {
  RecommendationService({
    required AiConfig Function() config,
    required AiContentPaths paths,
    AiContentUserDataStore? userData,
    AiContentCompletion? completion,
    RecommendationEnricher? enricher,
    LogService? log,
    DateTime Function()? clock,
  }) : _config = config,
       _completion = completion ?? AiContentCompletion(log: log),
       _enricher = enricher,
       _log = log,
       _clock = clock ?? DateTime.now,
       _userData =
           userData ?? AiContentUserDataStore(paths: paths, log: log);

  final AiConfig Function() _config;
  final AiContentCompletion _completion;
  final RecommendationEnricher? _enricher;
  final LogService? _log;
  final DateTime Function() _clock;
  final AiContentUserDataStore _userData;

  AiContentPaths get _paths => _userData.paths;

  /// 服务商配置指纹：协议/端点/模型/UA/推荐提示词，任一改变都会换缓存分片。
  String _providerSignature() {
    final config = _config().sanitized();
    return [
      config.protocol,
      config.endpoint,
      config.model,
      config.customUserAgent,
      config.recommendPrompt,
    ].join('|');
  }

  /// 给请求补上输入指纹（已有时不覆盖），供缓存键与"是否需要刷新"判定使用。
  RecommendationRequest sealRequest(RecommendationRequest request) =>
      request.inputFingerprint.isNotEmpty
      ? request
      : request.copyWith(
          inputFingerprint: RecommendationCachePolicy.inputFingerprintOf(
            providerSignature: _providerSignature(),
            request: request,
          ),
        );

  /// 缓存优先读取：**只读磁盘、不联网、不消耗 token**。
  ///
  /// 对齐安卓 `AiRecommendationService.loadCached` 的降级链：先看本请求指纹
  /// 对应的缓存（exact），未命中则退到最近写入的一份缓存（可能 stale，
  /// 仅用于先把内容展示出来）。
  Future<RecommendationCacheLookup> loadCached({
    required RecommendationRequest request,
  }) async {
    final sealed = sealRequest(request);
    final key = RecommendationCachePolicy.keyFor(sealed);
    final own = await _readCacheFile(key);
    if (own != null && own.cards.isNotEmpty) {
      return RecommendationCacheLookup(
        cards: own.cards,
        exact: true,
        fresh: own.fresh,
      );
    }
    final newest = await _readNewestCacheFile();
    if (newest != null && newest.cards.isNotEmpty) {
      return RecommendationCacheLookup(
        cards: newest.cards,
        exact: false,
        fresh: newest.fresh,
      );
    }
    return RecommendationCacheLookup.empty;
  }

  /// 生成推荐（命中缓存时不再消耗一次付费调用）。
  Future<AiContentOutcome<List<RecommendationCard>>> recommend({
    required RecommendationRequest request,
    AiContentCancellation? cancellation,
    bool useCache = true,
  }) async {
    final sealed = sealRequest(request);
    final key = RecommendationCachePolicy.keyFor(sealed);
    final feedback = await _userData.loadFeedback();
    final now = _clock();
    if (useCache) {
      final cached = await _readCache(key);
      if (cached != null) {
        _log?.info('推荐命中缓存 key=$key', scope: 'ai');
        // 缓存可能是「写负反馈之前」的快照：命中缓存也必须重新过一遍当前
        // 负反馈，否则用户否掉的作品会在重进页面后照旧出现。
        final filtered = filterRecommendationsByFeedback(
          cached,
          feedback,
          now: now,
        );
        if (filtered.length != cached.length) {
          _log?.info(
            '缓存命中后过滤负反馈 ${cached.length - filtered.length} 条',
            scope: 'ai',
          );
          await _writeCache(key, filtered);
        }
        return AiContentOutcome<List<RecommendationCard>>.value(filtered);
      }
    }

    final prompt = buildRecommendationPrompt(
      config: _config(),
      request: request,
    );
    final result = await _completion.run(
      config: _config(),
      prompt: prompt,
      cancellation: cancellation,
      logTag: 'ai-rec ${request.source.id}',
    );
    if (result.cancelled) {
      return const AiContentOutcome<List<RecommendationCard>>.cancelled();
    }
    if (!result.ok) {
      return AiContentOutcome<List<RecommendationCard>>.failed(
        message: result.message,
        statusCode: result.statusCode,
      );
    }

    final items = parseRecommendationItems(result.value!);
    if (items.isEmpty) {
      return const AiContentOutcome<List<RecommendationCard>>.failed(
        message: 'AI 没有给出可用的推荐（输出结构不合规）',
      );
    }

    final cards = await _withEnrichment(items);
    final filtered = filterRecommendationsByFeedback(
      cards,
      feedback,
      now: now,
    );
    if (filtered.length != cards.length) {
      _log?.info(
        '推荐过滤负反馈 ${cards.length - filtered.length} 条',
        scope: 'ai',
      );
    }
    await _writeCache(key, filtered);
    return AiContentOutcome<List<RecommendationCard>>.value(filtered);
  }

  /// 标记「不感兴趣」：立即落盘为用户数据，并返回新的反馈集合。
  Future<AiContentOutcome<RecommendationFeedbackCollection>> markNotInterested(
    RecommendationCard card, {
    AiContentCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return const AiContentOutcome<RecommendationFeedbackCollection>.cancelled();
    }
    final now = _clock();
    final current = await _userData.loadFeedback();
    final next = current.add(
      RecommendationFeedbackEntry(
        title: card.title,
        year: card.year,
        mediaType: card.mediaType,
        createdAtMs: now.millisecondsSinceEpoch,
      ),
      now: now,
    );
    final saved = await _userData.saveFeedback(next);
    if (!saved) {
      return const AiContentOutcome<RecommendationFeedbackCollection>.failed(
        message: '负反馈保存失败（磁盘不可写）',
      );
    }
    _log?.info('负反馈已记录：${card.title} 共 ${next.length} 条', scope: 'ai');
    return AiContentOutcome<RecommendationFeedbackCollection>.value(next);
  }

  Future<RecommendationFeedbackCollection> loadFeedback({DateTime? now}) async {
    final feedback = await _userData.loadFeedback();
    return feedback.trimmed(now: now ?? _clock());
  }

  Future<List<RecommendationCard>> _withEnrichment(
    List<RecommendationItem> items,
  ) async {
    final enricher = _enricher;
    if (enricher == null) {
      return [for (final item in items) RecommendationCard.fromItem(item)];
    }
    List<RecommendationEnrichment?> enrichments;
    try {
      enrichments = await enricher(items);
    } catch (error) {
      _log?.warning('推荐富集失败，降级为片名卡：$error', scope: 'ai');
      enrichments = const [];
    }
    return [
      for (var i = 0; i < items.length; i++)
        RecommendationCard.fromItem(
          items[i],
          enrichment: i < enrichments.length ? enrichments[i] : null,
        ),
    ];
  }

  Future<List<RecommendationCard>?> _readCache(String key) async {
    final cached = await _readCacheFile(key);
    if (cached == null || !cached.fresh) return null;
    return cached.cards;
  }

  /// 读一份缓存，**不过滤 TTL**：调用方自行判断 fresh（缓存优先展示需要旧内容）。
  Future<_CachedCards?> _readCacheFile(String key) async {
    final file = File(_paths.recommendationCachePath(key));
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final generatedAtMs = decoded['generatedAtMs'];
      if (generatedAtMs is! int) return null;
      final items = decoded['items'];
      if (items is! List) return null;
      final cards = <RecommendationCard>[];
      for (final item in items) {
        final card = RecommendationCard.fromJson(item);
        if (card != null) cards.add(card);
      }
      if (cards.isEmpty) return null;
      return _CachedCards(
        cards: cards,
        fresh: RecommendationCachePolicy.isFresh(
          generatedAtMs: generatedAtMs,
          now: _clock(),
        ),
      );
    } catch (error) {
      _log?.warning('推荐缓存读取失败：$error', scope: 'ai');
      return null;
    }
  }

  /// 最近写入的推荐缓存（跨分片兜底，仅用于先展示再刷新）。
  Future<_CachedCards?> _readNewestCacheFile() async {
    final files = await _paths.existingRecommendationCacheFiles();
    if (files.isEmpty) return null;
    final stats = <(File, DateTime)>[];
    for (final path in files) {
      final file = File(path);
      try {
        stats.add((file, await file.lastModified()));
      } catch (_) {
        continue;
      }
    }
    stats.sort((a, b) => b.$2.compareTo(a.$2));
    for (final (file, _) in stats) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) continue;
        final generatedAtMs = decoded['generatedAtMs'];
        final items = decoded['items'];
        if (generatedAtMs is! int || items is! List) continue;
        final cards = <RecommendationCard>[];
        for (final item in items) {
          final card = RecommendationCard.fromJson(item);
          if (card != null) cards.add(card);
        }
        if (cards.isEmpty) continue;
        return _CachedCards(
          cards: cards,
          fresh: RecommendationCachePolicy.isFresh(
            generatedAtMs: generatedAtMs,
            now: _clock(),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<void> _writeCache(String key, List<RecommendationCard> cards) async {
    final trimmed = cards.length > RecommendationCachePolicy.maxItems
        ? cards.sublist(0, RecommendationCachePolicy.maxItems)
        : cards;
    final payload = <String, Object?>{
      'generatedAtMs': _clock().millisecondsSinceEpoch,
      'items': [for (final card in trimmed) card.toJson()],
    };
    final file = File(_paths.recommendationCachePath(key));
    try {
      await Directory(p.dirname(file.path)).create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(payload), flush: true);
      await temporary.rename(file.path);
      await _trimCacheFiles();
    } catch (error) {
      _log?.warning('推荐缓存写入失败：$error', scope: 'ai');
    }
  }

  /// 推荐缓存文件上限 32：超出时按修改时间删最旧的（缓存可重建）。
  /// 只裁 `rec_*`：`title_*` / `profile_*` 是别的域的缓存，不能被推荐连带删掉。
  Future<void> _trimCacheFiles() async {
    final files = await _paths.existingRecommendationCacheFiles();
    if (files.length <= RecommendationCachePolicy.maxFiles) return;
    final stats = <(String, DateTime)>[];
    for (final path in files) {
      try {
        stats.add((path, (await File(path).stat()).modified));
      } catch (_) {
        // 读不到时间戳就跳过：不能因为清理失败而中断推荐。
      }
    }
    stats.sort((a, b) => a.$2.compareTo(b.$2));
    final overflow = stats.length - RecommendationCachePolicy.maxFiles;
    for (var i = 0; i < overflow; i++) {
      try {
        await File(stats[i].$1).delete();
      } catch (_) {
        // 同上。
      }
    }
  }

  /// 供调用方构造片名查询（搜索输入复用同一套片名解析）。
  TitleQuery titleQueryOf(RecommendationRequest request) => TitleQuery(
    rawTitle: request.seed?.title ?? request.keyword,
    siteKey: request.siteKey,
  );
}

/// 一份缓存内容（保留 TTL 判定结果，供"缓存优先 + 异步刷新"使用）。
class _CachedCards {
  const _CachedCards({required this.cards, required this.fresh});
  final List<RecommendationCard> cards;
  final bool fresh;
}

/// 对外暴露的缓存查询结果。
class RecommendationCacheLookup {
  const RecommendationCacheLookup({
    required this.cards,
    required this.exact,
    required this.fresh,
  });

  static const RecommendationCacheLookup empty = RecommendationCacheLookup(
    cards: [],
    exact: false,
    fresh: false,
  );

  final List<RecommendationCard> cards;

  /// 缓存是否来自「当前输入指纹」的分片：false 表示只是最近一份兜底缓存。
  final bool exact;

  /// 缓存是否仍在 TTL 内。
  final bool fresh;

  bool get hasItems => cards.isNotEmpty;

  /// 是否需要重新请求：指纹不一致或已过期都要刷新；两者都满足则直接复用，
  /// 避免每次进详情页都花一次付费调用。
  bool get needsRefresh => !exact || !fresh;
}