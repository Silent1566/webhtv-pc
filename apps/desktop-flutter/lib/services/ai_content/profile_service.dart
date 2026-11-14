// ignore_for_file: prefer_initializing_formals
/// 观影结构画像服务：本地统计 → 结构画像 → 24 小时指纹缓存 → 可选 AI 解读。
///
/// 缓存键同时绑定「范围 id」与「输入指纹」：换范围、历史变化、超过 24 小时
/// 都会导致缓存失效并重算。这修掉了风险 3「画像旧响应跨范围显示」。
library;

import 'dart:convert';
import 'dart:io';

import '../../core/ai_config.dart';
import '../../core/ai_content/ai_content_contracts.dart';
import '../../core/ai_content/viewing_profile.dart';
import '../../core/viewing_report.dart';
import '../log_service.dart';
import 'ai_content_completion.dart';
import 'ai_content_paths.dart';

class ViewingProfileService {
  ViewingProfileService({
    required AiConfig Function() config,
    required AiContentPaths paths,
    AiContentCompletion? completion,
    LogService? log,
    DateTime Function()? clock,
  }) : _config = config,
       _completion = completion ?? AiContentCompletion(log: log),
       _log = log,
       _clock = clock ?? DateTime.now,
       _paths = paths;

  final AiConfig Function() _config;
  final AiContentCompletion _completion;
  final LogService? _log;
  final DateTime Function() _clock;
  final AiContentPaths _paths;

  /// 生成结构画像（命中缓存时直接返回；范围不符一律重算）。
  Future<AiContentOutcome<ViewingProfile>> profile({
    required ViewingReport report,
    required int latestUpdatedAtMs,
    bool useCache = true,
  }) async {
    final now = _clock();
    final current = buildViewingProfile(
      report: report,
      latestUpdatedAtMs: latestUpdatedAtMs,
      now: now,
    );
    if (useCache) {
      final cached = await _readCache(report.range);
      if (cached != null &&
          ViewingProfileCachePolicy.isReusable(
            cachedRangeId: cached.rangeId,
            requestedRangeId: current.rangeId,
            cachedFingerprint: cached.fingerprint,
            currentFingerprint: current.fingerprint,
            generatedAtMs: cached.generatedAtMs,
            now: now,
          )) {
        return AiContentOutcome<ViewingProfile>.value(cached);
      }
    }
    await _writeCache(current);
    return AiContentOutcome<ViewingProfile>.value(current);
  }

  /// AI 解读文本（可选能力：未配置时返回失败原因，基础画像不受影响）。
  Future<AiContentOutcome<String>> narrative({
    required ViewingReport report,
    AiContentCancellation? cancellation,
  }) async {
    final prompt = _buildPrompt(report);
    final result = await _completion.run(
      config: _config(),
      prompt: prompt,
      cancellation: cancellation,
      logTag: 'ai-report ${report.range.name}',
    );
    if (result.cancelled) {
      return const AiContentOutcome<String>.cancelled();
    }
    if (!result.ok) {
      return AiContentOutcome<String>.failed(
        message: result.message,
        statusCode: result.statusCode,
      );
    }
    final text = result.value!.trim();
    if (text.isEmpty) {
      return const AiContentOutcome<String>.failed(message: 'AI 返回了空内容');
    }
    return AiContentOutcome<String>.value(
      text.length > 2000 ? '${text.substring(0, 2000)}…' : text,
    );
  }

  /// 提示词原文取自 `AiConfig.viewingReportPrompt`（内置兜底），
  /// 数据块复用既有 [`buildViewingReportPrompt`] 的安全声明与 JSON 结构。
  String _buildPrompt(ViewingReport report) {
    final base = AiPromptCatalog.promptFor(
      _config(),
      AiContentKind.viewingReport,
    );
    final data = buildViewingReportPrompt(report);
    final marker = data.indexOf('数据：');
    final payload = marker >= 0 ? data.substring(marker) : data;
    return '$base\n\n$payload';
  }

  Future<ViewingProfile?> _readCache(ViewingReportRange range) async {
    final file = File(_paths.profileCachePath(range.name));
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return ViewingProfile.fromJson(decoded['profile']);
    } catch (error) {
      _log?.warning('画像缓存读取失败：$error', scope: 'ai');
      return null;
    }
  }

  Future<void> _writeCache(ViewingProfile profile) async {
    final file = File(_paths.profileCachePath(profile.rangeId));
    try {
      await Directory(file.parent.path).create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({'profile': profile.toJson()}),
        flush: true,
      );
      await temporary.rename(file.path);
    } catch (error) {
      _log?.warning('画像缓存写入失败：$error', scope: 'ai');
    }
  }
}
