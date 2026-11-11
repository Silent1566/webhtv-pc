// ignore_for_file: prefer_initializing_formals
/// 片名解析服务：学习命中 → 规则 → AI 回退，带 30 天缓存与学习落盘。
///
/// 交付给集成层的调用面很小（[resolve] / [confirm]），Task 5 的季集映射与
/// TMDB 身份解析都只需要这两步：拿到带置信度的 typed 片名，用户确认后记录
/// 一次学习，下次同类标题不再花 AI 请求。
///
/// 决议顺序与纯函数 [decideTitleResolution] 一致（学习 > 规则 > AI）：
/// 规则可信只用于「不需要再调 AI」，**不**用于跳过学习命中。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ai_config.dart';
import '../../core/ai_content/ai_content_contracts.dart';
import '../../core/ai_content/title_learning.dart';
import '../../core/ai_content/title_resolution.dart';
import '../log_service.dart';
import 'ai_content_completion.dart';
import 'ai_content_paths.dart';
import 'user_data_store.dart';

class TitleResolutionService {
  TitleResolutionService({
    required AiConfig Function() config,
    required AiContentPaths paths,
    AiContentUserDataStore? userData,
    AiContentCompletion? completion,
    LogService? log,
    DateTime Function()? clock,
    bool Function()? aiEnabled,
  }) : _config = config,
       _completion = completion ?? AiContentCompletion(log: log),
       _log = log,
       _clock = clock ?? DateTime.now,
       _aiEnabled = aiEnabled,
       _userData = userData ?? AiContentUserDataStore(paths: paths, log: log);

  final AiConfig Function() _config;
  final AiContentCompletion _completion;
  final LogService? _log;
  final DateTime Function() _clock;
  final bool Function()? _aiEnabled;
  final AiContentUserDataStore _userData;

  AiContentPaths get _paths => _userData.paths;

  /// 是否允许调用 AI（默认跟随配置是否就绪；用户可整体关闭）。
  bool get _canUseAi {
    final gate = _aiEnabled;
    if (gate != null) return gate();
    return _config().sanitized().isReady;
  }

  /// 解析片名（不写任何状态；缓存写入是内部行为）。
  Future<AiContentOutcome<TitleResolution>> resolve(
    TitleQuery query, {
    AiContentCancellation? cancellation,
    bool useCache = true,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return const AiContentOutcome<TitleResolution>.cancelled();
    }
    final ruleFields = parseTitleByRules(query.rawTitle);
    // 学习命中优先于规则：用户确认过的映射必须能覆盖规则抽取结果，否则
    // `confirm` 写进学习库的修正永远不会被再次采用（学习库空转）。
    final learning = await _userData.loadLearning();
    final learningHit = learning.find(query, limit: 1).firstOrNull;
    if (learningHit != null && learningHit.score >= 0.9) {
      return AiContentOutcome<TitleResolution>.value(
        decideTitleResolution(
          rawTitle: query.rawTitle,
          ruleFields: ruleFields,
          learningHit: learningHit,
        ),
      );
    }
    // 规则可信：结论已经够用，不再花一次付费调用。
    if (ruleFields.ruleConfidence >= TitleResolution.ruleTrust) {
      return AiContentOutcome<TitleResolution>.value(
        decideTitleResolution(rawTitle: query.rawTitle, ruleFields: ruleFields),
      );
    }

    final version = AiPromptCatalog.versionFor(_config(), AiContentKind.title);
    final cacheKey = TitleResolutionCachePolicy.keyFor(
      query.rawTitle,
      promptVersion: version,
    );
    if (useCache) {
      final cached = await _readCache(cacheKey, version);
      if (cached != null) {
        return AiContentOutcome<TitleResolution>.value(cached.asCached());
      }
    }

    if (!_canUseAi) {
      _log?.info('片名解析：AI 未启用，返回规则结果', scope: 'ai');
      return AiContentOutcome<TitleResolution>.value(
        decideTitleResolution(
          rawTitle: query.rawTitle,
          ruleFields: ruleFields,
          learningHit: learningHit,
        ),
      );
    }

    final prompt = buildTitleExtractionPrompt(
      config: _config(),
      query: query,
      learningContexts: [
        for (final hit in learning.find(query))
          TitleLearningExampleRef(
            rawTitle: hit.example.rawTitle,
            resolvedTitle: hit.example.resolvedTitle,
            year: hit.example.year,
            mediaType: hit.example.mediaType,
          ),
      ],
    );
    final result = await _completion.run(
      config: _config(),
      prompt: prompt,
      cancellation: cancellation,
      logTag: 'ai-title',
    );
    if (result.cancelled) {
      return const AiContentOutcome<TitleResolution>.cancelled();
    }
    final aiCandidate = result.ok
        ? parseTitleAiOutput(result.value!)
        : null;
    if (!result.ok) {
      _log?.warning(
        '片名 AI 回退失败，使用规则结果：${result.message}',
        scope: 'ai',
      );
    }
    final resolution = decideTitleResolution(
      rawTitle: query.rawTitle,
      ruleFields: ruleFields,
      learningHit: learningHit,
      aiResolution: aiCandidate,
    );
    if (aiCandidate != null && !resolution.lowConfidence) {
      await _writeCache(cacheKey, resolution, version);
    }
    return AiContentOutcome<TitleResolution>.value(resolution);
  }

  /// 用户确认后记录一次学习（用户数据，立即落盘）。
  Future<AiContentOutcome<TitleLearningCollection>> confirm(
    TitleQuery query,
    TitleResolution resolution, {
    AiContentCancellation? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return const AiContentOutcome<TitleLearningCollection>.cancelled();
    }
    if (resolution.title.trim().isEmpty) {
      return const AiContentOutcome<TitleLearningCollection>.failed(
        message: '片名为空，不能记录学习',
      );
    }
    final now = _clock();
    final current = await _userData.loadLearning();
    final next = current.record(
      query,
      TitleLearningExample(
        rawTitle: query.rawTitle,
        resolvedTitle: resolution.title,
        year: resolution.year,
        mediaType: resolution.mediaType,
        siteKey: query.siteKey,
        vodId: query.vodId,
        hitCount: 1,
        updatedAtMs: now.millisecondsSinceEpoch,
      ),
      now: now,
    );
    final saved = await _userData.saveLearning(next);
    if (!saved) {
      return const AiContentOutcome<TitleLearningCollection>.failed(
        message: '学习记录保存失败（磁盘不可写）',
      );
    }
    _log?.info('片名学习已记录：${query.rawTitle} → ${resolution.title}', scope: 'ai');
    return AiContentOutcome<TitleLearningCollection>.value(next);
  }

  Future<TitleLearningCollection> loadLearning() => _userData.loadLearning();

  /// 学习库命中（给 UI 展示「为什么是这个片名」）。
  Future<List<TitleLearningHit>> explain(TitleQuery query) async {
    final learning = await _userData.loadLearning();
    return learning.find(query);
  }

  Future<TitleResolution?> _readCache(String key, int version) async {
    final target = File(p.join(_paths.cacheDir, 'title_$key.json'));
    try {
      if (!await target.exists()) return null;
      final decoded = jsonDecode(await target.readAsString());
      if (decoded is! Map) return null;
      final generatedAtMs = decoded['generatedAtMs'];
      if (generatedAtMs is! int) return null;
      if (!TitleResolutionCachePolicy.isFresh(
        generatedAtMs: generatedAtMs,
        promptVersion: version,
        currentVersion: version,
        now: _clock(),
      )) {
        return null;
      }
      final cached = TitleResolution.fromJson(decoded['resolution']);
      if (cached == null) return null;
      return cached;
    } catch (error) {
      _log?.warning('片名缓存读取失败：$error', scope: 'ai');
      return null;
    }
  }

  Future<void> _writeCache(
    String key,
    TitleResolution resolution,
    int version,
  ) async {
    final target = File(p.join(_paths.cacheDir, 'title_$key.json'));
    final payload = <String, Object?>{
      'generatedAtMs': _clock().millisecondsSinceEpoch,
      'promptVersion': version,
      'resolution': resolution.toJson(),
    };
    try {
      await Directory(p.dirname(target.path)).create(recursive: true);
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(jsonEncode(payload), flush: true);
      await temporary.rename(target.path);
    } catch (error) {
      _log?.warning('片名缓存写入失败：$error', scope: 'ai');
    }
  }
}
