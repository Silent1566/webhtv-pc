// ignore_for_file: prefer_initializing_formals
/// 内容智能用户数据的落盘与导入导出（反馈 / 分组规则 / 去广规则 / 片名学习）。
///
/// 四类数据各一个专属 JSON 文件，原子写（`.tmp` + rename），可枚举、可备份；
/// 读取容错：单个文件损坏只影响该域，其他用户数据照常可用。
/// 读取/导入同样**重新校验**不可信正则（安全子集、长度、域名清洗），
/// 手工编辑或导入的 JSON 不能绕过 AI 路径的校验。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/ai_content/ad_rule_validation.dart';
import '../../core/ai_content/group_rule_validation.dart';
import '../../core/ai_content/recommendation_feedback.dart';
import '../../core/ai_content/title_learning.dart';
import '../../core/ai_content/user_data.dart';
import '../log_service.dart';
import 'ai_content_paths.dart';

/// 导入用户数据的结果：成功与否、实际写入的域、写入失败的域。
///
/// 调用方（UI/集成层）必须看 [ok] 与 [message]，不能只看有没有返回数据：
/// 校验失败与写盘失败都**不是**导入成功。
class AiContentImportResult {
  AiContentImportResult._({
    required this.ok,
    required this.message,
    required this.domains,
    this.unsavedDomains = const [],
    this.data,
  });

  factory AiContentImportResult.imported(
    AiContentUserData data,
    List<String> domains,
  ) => AiContentImportResult._(
    ok: true,
    message: '',
    data: data,
    domains: List.unmodifiable(domains),
  );

  factory AiContentImportResult.failed(
    String message, {
    List<String> domains = const [],
    List<String> unsavedDomains = const [],
    AiContentUserData? data,
  }) => AiContentImportResult._(
    ok: false,
    message: message,
    data: data,
    domains: List.unmodifiable(domains),
    unsavedDomains: List.unmodifiable(unsavedDomains),
  );

  final bool ok;
  final String message;

  /// 真正写进文件的域（`feedback` / `groupRules` / `adRules` / `learning`）。
  final List<String> domains;

  /// 写盘失败的域（解析/校验阶段失败时为空，因为没有尝试写入）。
  final List<String> unsavedDomains;

  /// 解析出来的数据（失败时可能为 null）。
  final AiContentUserData? data;
}

class AiContentUserDataStore {
  AiContentUserDataStore({
    required this.paths,
    LogService? log,
    DateTime Function()? clock,
  }) : _log = log,
       _clock = clock ?? DateTime.now;

  final AiContentPaths paths;
  final LogService? _log;
  final DateTime Function() _clock;

  /// 读取全部用户数据（缺文件/坏文件都返回可用空集）。
  Future<AiContentUserData> load() async => AiContentUserData(
    exportedAtMs: _clock().millisecondsSinceEpoch,
    feedback: await loadFeedback(),
    groupRules: await loadGroupRules(),
    adRules: await loadAdRules(),
    learning: await loadLearning(),
  );

  Future<RecommendationFeedbackCollection> loadFeedback() async {
    final raw = await _readJson(paths.feedbackPath);
    return RecommendationFeedbackCollection.fromJson(raw);
  }

  Future<bool> saveFeedback(RecommendationFeedbackCollection feedback) =>
      _writeJson(paths.feedbackPath, feedback.toJson());

  Future<TitleLearningCollection> loadLearning() async {
    final raw = await _readJson(paths.learningPath);
    return TitleLearningCollection.fromJson(raw);
  }

  Future<bool> saveLearning(TitleLearningCollection learning) =>
      _writeJson(paths.learningPath, learning.toJson());

  Future<List<GroupRuleProposal>> loadGroupRules() async {
    final raw = await _readJson(paths.groupRulesPath);
    final list = raw is Map ? raw['rules'] : raw;
    if (list is! List) return const [];
    final rules = <GroupRuleProposal>[];
    for (final item in list) {
      final rule = GroupRuleProposal.fromJson(item);
      if (rule == null) continue;
      rules.add(rule);
    }
    _logDropped('分组规则', list.length - rules.length);
    return rules;
  }

  Future<bool> saveGroupRules(List<GroupRuleProposal> rules) => _writeJson(
    paths.groupRulesPath,
    {'rules': [for (final rule in rules) rule.toJson()]},
  );

  Future<List<AdRuleProposal>> loadAdRules() async {
    final raw = await _readJson(paths.adRulesPath);
    final list = raw is Map ? raw['rules'] : raw;
    if (list is! List) return const [];
    final rules = <AdRuleProposal>[];
    for (final item in list) {
      final rule = AdRuleProposal.fromJson(item);
      if (rule == null) continue;
      rules.add(rule);
    }
    _logDropped('去广规则', list.length - rules.length);
    return rules;
  }

  Future<bool> saveAdRules(List<AdRuleProposal> rules) => _writeJson(
    paths.adRulesPath,
    {'rules': [for (final rule in rules) rule.toJson()]},
  );

  /// 导出：一份包含四类用户数据的 JSON 文本（同时落盘一份快照）。
  Future<String> exportJson() async {
    final data = await load();
    final text = const JsonEncoder.withIndent('  ').convert(data.toJson());
    await _writeRaw(paths.exportPath, text);
    return text;
  }

  /// 导入：解析/结构/版本校验通过后**只写回文件里真实存在的域**。
  ///
  /// 三条硬规则：
  /// 1. 版本不认识、或一个域的键都没有 → 拒绝整份导入，现有用户数据保持原样
  ///    （缺域绝不能被当成「空集」覆盖掉用户已有的负反馈/规则/学习）；
  /// 2. 逐域检查 `save*` 的返回值，任一失败就返回失败并写明失败域，
  ///    不允许调用方以为「导入成功」；
  /// 3. 写入前不删旧数据（每域都是 `.tmp` + rename 原子替换）。
  Future<AiContentImportResult> importJson(String raw) async {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (error) {
      _log?.warning('导入 AI 内容数据失败：$error', scope: 'ai');
      return AiContentImportResult.failed('导入内容不是合法 JSON，未改动任何用户数据');
    }
    if (decoded is! Map) {
      return AiContentImportResult.failed(
        '导入内容不是 JSON 对象，未改动任何用户数据',
      );
    }
    final version = decoded['schemaVersion'];
    if (version is! int || version != aiContentUserDataSchemaVersion) {
      _log?.warning('拒绝导入：schemaVersion=$version 不受支持', scope: 'ai');
      return AiContentImportResult.failed(
        '导入文件版本不支持（schemaVersion='
        '${version ?? '缺失'}，当前只支持 $aiContentUserDataSchemaVersion），'
        '未改动任何用户数据',
      );
    }
    final invalid = <String>[];
    final present = <String>[];
    for (final key in AiContentUserData.exportedKeys) {
      if (!decoded.containsKey(key)) continue;
      if (_domainPayloadValid(key, decoded[key])) {
        present.add(key);
      } else {
        invalid.add(key);
      }
    }
    if (invalid.isNotEmpty) {
      return AiContentImportResult.failed(
        '导入内容里 ${invalid.join('、')} 域结构不正确，已拒绝导入（未改动任何用户数据）',
      );
    }
    if (present.isEmpty) {
      return AiContentImportResult.failed(
        '导入内容不包含任何内容智能用户数据域'
        '（${AiContentUserData.exportedKeys.join('/')}），已拒绝导入'
        '（未改动任何用户数据）',
      );
    }

    final data = AiContentUserData.fromJson(decoded);
    _logDropped(
      '分组规则',
      _listLength(decoded['groupRules']) - data.groupRules.length,
    );
    _logDropped(
      '去广规则',
      _listLength(decoded['adRules']) - data.adRules.length,
    );
    final saved = <String>[];
    final unsaved = <String>[];
    for (final key in present) {
      final bool ok;
      if (key == 'feedback') {
        ok = await saveFeedback(data.feedback);
      } else if (key == 'groupRules') {
        ok = await saveGroupRules(data.groupRules);
      } else if (key == 'adRules') {
        ok = await saveAdRules(data.adRules);
      } else {
        ok = await saveLearning(data.learning);
      }
      (ok ? saved : unsaved).add(key);
    }
    if (unsaved.isNotEmpty) {
      _log?.error(
        '导入 AI 内容数据失败：${unsaved.join('、')} 写入失败'
        '（已写入：${saved.isEmpty ? '无' : saved.join('、')}）',
        scope: 'ai',
      );
      return AiContentImportResult.failed(
        '导入失败：${unsaved.join('、')} 写入失败'
        '（已写入：${saved.isEmpty ? '无' : saved.join('、')}）',
        domains: saved,
        unsavedDomains: unsaved,
        data: data,
      );
    }
    _log?.info(
      '导入 AI 内容数据：${saved.join('、')}'
      '（反馈 ${data.feedback.length} / 分组 ${data.groupRules.length} / '
      '去广 ${data.adRules.length} / 学习 ${data.learning.length}）',
      scope: 'ai',
    );
    return AiContentImportResult.imported(data, saved);
  }

  /// 用户数据文件清单（备份枚举用）。
  Future<List<String>> userDataFiles() => paths.existingUserDataFiles();

  /// 某个域键的载荷结构是否可安全解释（类型不符就不导入，避免「空集覆盖」）。
  static bool _domainPayloadValid(String key, Object? value) {
    if (key == 'groupRules' || key == 'adRules') {
      if (value is List) return true;
      return value is Map && value['rules'] is List;
    }
    if (key == 'feedback') {
      if (value is List) return true;
      return value is Map && value['entries'] is List;
    }
    if (key == 'learning') {
      if (value is List) return true;
      return value is Map && value['examples'] is List;
    }
    return false;
  }

  /// 规则列表的原始条数（用于统计被校验挡掉的条目）。
  static int _listLength(Object? raw) {
    if (raw is List) return raw.length;
    if (raw is Map && raw['rules'] is List) {
      return (raw['rules']! as List).length;
    }
    return 0;
  }

  void _logDropped(String label, int dropped) {
    if (dropped <= 0) return;
    _log?.warning('$label：$dropped 条未通过校验已丢弃（不安全正则/超长/空规则）', scope: 'ai');
  }

  Future<Object?> _readJson(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      if (text.trim().isEmpty) return null;
      return jsonDecode(text);
    } catch (error) {
      _log?.warning('读取 ${p.basename(path)} 失败：$error', scope: 'ai');
      return null;
    }
  }

  Future<bool> _writeJson(String path, Object? json) =>
      _writeRaw(path, const JsonEncoder.withIndent('  ').convert(json));

  Future<bool> _writeRaw(String path, String text) async {
    final target = File(path);
    final temporary = File('$path.tmp');
    try {
      await Directory(p.dirname(path)).create(recursive: true);
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(target.path);
      return true;
    } catch (error) {
      _log?.error('写入 ${p.basename(path)} 失败：$error', scope: 'ai');
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {
        // 清理失败不影响结论：真正的失败已经记在日志里。
      }
      return false;
    }
  }
}
