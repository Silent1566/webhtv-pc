/// 内容智能页：推荐 / 画像 / 规则 / 诊断 / 数据 五个分区。
///
/// 边界：本页不读 `AppState`、不改共享 shell、不做导航注册——宿主页面
/// （统一集成任务）通过 [AiContentPageDeps] 注入数据来源即可嵌入；
/// 需要的数据用 [AiContentPageSnapshot] 一次给全，避免页面自己拼业务。
library;

import 'package:flutter/material.dart';

import '../../core/ai_content/ad_rule_validation.dart';
import '../../core/ai_content/ai_content_contracts.dart';
import '../../core/ai_content/group_rule_validation.dart';
import '../../core/ai_content/log_diagnosis.dart';
import '../../core/ai_content/recommendation.dart';
import '../../core/ai_content/viewing_profile.dart';
import '../../core/viewing_report.dart';
import '../../services/ai_content/ad_rule_service.dart';
import '../../services/ai_content/group_rule_service.dart';
import '../../services/ai_content/log_diagnosis_service.dart';
import '../../services/ai_content/profile_service.dart';
import '../../services/ai_content/recommendation_service.dart';
import '../../services/ai_content/title_resolution_service.dart';
import '../../services/ai_content/user_data_store.dart';
import '../tokens.dart';
import 'ai_content_widgets.dart';

/// 页面用到的服务集合（一次注入，避免页面自己 new）。
class AiContentServices {
  const AiContentServices({
    required this.recommendation,
    required this.title,
    required this.group,
    required this.ad,
    required this.logDiagnosis,
    required this.profile,
    required this.userData,
  });

  final RecommendationService recommendation;
  final TitleResolutionService title;
  final GroupRuleService group;
  final AdRuleService ad;
  final LogDiagnosisService logDiagnosis;
  final ViewingProfileService profile;
  final AiContentUserDataStore userData;
}

/// 宿主提供的一屏数据（历史上下文 + 当前报告 + 站点名）。
class AiContentPageSnapshot {
  const AiContentPageSnapshot({
    this.contexts = const [],
    this.siteNames = const [],
    required this.report,
    required this.latestUpdatedAtMs,
  });

  final List<WatchContextItem> contexts;
  final List<String> siteNames;
  final ViewingReport report;
  final int latestUpdatedAtMs;
}

class AiContentPageDeps {
  const AiContentPageDeps({
    required this.services,
    required this.loadSnapshot,
  });

  final AiContentServices services;
  final Future<AiContentPageSnapshot> Function() loadSnapshot;
}

class AiContentPage extends StatefulWidget {
  const AiContentPage({super.key, required this.deps});

  final AiContentPageDeps deps;

  @override
  State<AiContentPage> createState() => _AiContentPageState();
}

class _AiContentPageState extends State<AiContentPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);

  AiContentCancellation? _cancellation;
  bool _busy = false;
  String _status = '';

  List<RecommendationCard> _cards = const [];
  RecommendationSource _source = RecommendationSource.history;
  String _keyword = '';

  ViewingProfile? _profile;
  String _narrative = '';

  GroupRuleValidation? _groupValidation;
  List<AdRuleProposal> _adRules = const [];
  List<GroupRuleProposal> _approvedGroupRules = const [];

  LogDiagnosisResult? _diagnosis;
  int _userDataFileCount = 0;

  @override
  void dispose() {
    _cancellation?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  void _begin() {
    _cancellation?.cancel();
    _cancellation = AiContentCancellation();
    _busy = true;
    _status = '';
    if (mounted) setState(() {});
  }

  void _end(String status) {
    _busy = false;
    _status = status;
    if (mounted) setState(() {});
  }

  Future<void> _generateRecommendations() async {
    _begin();
    final cancellation = _cancellation!;
    final snapshot = await widget.deps.loadSnapshot();
    final request = RecommendationRequest(
      source: _source,
      contexts: snapshot.contexts,
      keyword: _keyword,
      seed: snapshot.contexts.isEmpty ? null : snapshot.contexts.first,
    );
    final result = await widget.deps.services.recommendation.recommend(
      request: request,
      cancellation: cancellation,
    );
    if (!mounted) return;
    if (result.cancelled) return _end('已取消');
    if (!result.ok) return _end('失败：${result.message}');
    setState(() => _cards = result.value!);
    _end('已生成 ${_cards.length} 条推荐');
  }

  Future<void> _markNotInterested(RecommendationCard card) async {
    final result = await widget.deps.services.recommendation.markNotInterested(
      card,
    );
    if (!mounted) return;
    if (!result.ok) return _end('取消失败：${result.message}');
    setState(() => _cards = [for (final item in _cards) if (item.title != card.title) item]);
    _end('已记录「不感兴趣」');
  }

  Future<void> _loadProfile() async {
    _begin();
    final cancellation = _cancellation!;
    final snapshot = await widget.deps.loadSnapshot();
    final result = await widget.deps.services.profile.profile(
      report: snapshot.report,
      latestUpdatedAtMs: snapshot.latestUpdatedAtMs,
    );
    if (!mounted) return;
    if (!result.ok) return _end('失败：${result.message}');
    setState(() => _profile = result.value);
    final narrative = await widget.deps.services.profile.narrative(
      report: snapshot.report,
      cancellation: cancellation,
    );
    if (!mounted) return;
    if (narrative.cancelled) return _end('已取消');
    setState(() => _narrative = narrative.ok ? narrative.value! : '');
    _end(narrative.ok ? '画像已更新' : '画像已更新（AI 解读不可用：${narrative.message}）');
  }

  Future<void> _analyzeGroupRules() async {
    _begin();
    final cancellation = _cancellation!;
    final snapshot = await widget.deps.loadSnapshot();
    final result = await widget.deps.services.group.analyze(
      sourceNames: snapshot.siteNames,
      cancellation: cancellation,
    );
    if (!mounted) return;
    if (result.cancelled) return _end('已取消');
    if (!result.ok) return _end('失败：${result.message}');
    setState(() => _groupValidation = result.value);
    _end(
      result.value!.accepted.isEmpty
          ? 'AI 给出的 ${result.value!.rejected.length} 条规则都未通过校验（原因已列出）'
          : 'AI 给出 ${result.value!.accepted.length} 条规则，等待确认',
    );
  }

  Future<void> _approveGroupRules() async {
    final validation = _groupValidation;
    if (validation == null) return;
    final result = await widget.deps.services.group.approve(validation.accepted);
    if (!mounted) return;
    if (!result.ok) return _end('应用失败：${result.message}');
    setState(() => _approvedGroupRules = result.value!);
    _end('已应用 ${result.value!.length} 条分组规则');
  }

  Future<void> _loadApprovedRules() async {
    final group = await widget.deps.services.group.loadApproved();
    final ad = await widget.deps.services.ad.loadCandidates();
    if (!mounted) return;
    setState(() {
      _approvedGroupRules = group;
      _adRules = ad;
    });
  }

  Future<void> _diagnose() async {
    _begin();
    final result = await widget.deps.services.logDiagnosis.diagnose(
      cancellation: _cancellation,
    );
    if (!mounted) return;
    if (result.cancelled) return _end('已取消');
    if (!result.ok) return _end('失败：${result.message}');
    setState(() => _diagnosis = result.value);
    _end(result.value!.ok ? '诊断完成' : '诊断不完整（缺段已标注）');
  }

  Future<void> _exportUserData() async {
    final text = await widget.deps.services.userData.exportJson();
    final files = await widget.deps.services.userData.userDataFiles();
    if (!mounted) return;
    setState(() => _userDataFileCount = files.length);
    _end('已导出 ${text.length} 字符，共 ${files.length} 个用户数据文件');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tabs,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: const [
                    Tab(text: '推荐'),
                    Tab(text: '画像'),
                    Tab(text: '规则'),
                    Tab(text: '诊断'),
                    Tab(text: '数据'),
                  ],
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(right: AppSpace.sm),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (_busy)
                TextButton(
                  onPressed: () => _cancellation?.cancel(),
                  child: const Text('取消'),
                ),
            ],
          ),
        ),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
            child: Text(_status, style: theme.textTheme.bodySmall),
          ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _recommendationTab(theme),
              _profileTab(theme),
              _rulesTab(theme),
              _diagnosisTab(theme),
              _dataTab(theme),
            ],
          ),
        ),
      ],
    );
  }

  Widget _recommendationTab(ThemeData theme) => ListView(
    padding: const EdgeInsets.all(AppSpace.lg),
    children: [
      Wrap(
        spacing: AppSpace.sm,
        runSpacing: AppSpace.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final source in RecommendationSource.values)
            ChoiceChip(
              label: Text(source.label),
              selected: _source == source,
              onSelected: (_) => setState(() => _source = source),
            ),
          if (_source == RecommendationSource.search)
            SizedBox(
              width: 200,
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '搜索关键词',
                ),
                onChanged: (value) => _keyword = value,
              ),
            ),
          FilledButton(
            onPressed: _busy ? null : _generateRecommendations,
            child: const Text('生成推荐'),
          ),
        ],
      ),
      const SizedBox(height: AppSpace.md),
      if (_cards.isEmpty)
        Text('还没有推荐结果', style: theme.textTheme.bodySmall),
      for (final card in _cards)
        AiRecommendationCardTile(
          card: card,
          onNotInterested: () => _markNotInterested(card),
        ),
    ],
  );

  Widget _profileTab(ThemeData theme) {
    final profile = _profile;
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Row(
          children: [
            FilledButton(
              onPressed: _busy ? null : _loadProfile,
              child: const Text('刷新画像'),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.md),
        if (profile == null)
          Text('尚未生成结构画像', style: theme.textTheme.bodySmall)
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '范围：${profile.rangeId} · 记录 ${profile.recordCount} 条 · '
                '完播率 ${(profile.completionRate * 100).round()}%',
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                '深夜占比 ${(profile.lateNightShare * 100).round()}% · '
                '周末占比 ${(profile.weekendShare * 100).round()}% · '
                '共 ${profile.totalWatchMinutes} 分钟',
                style: theme.textTheme.bodySmall,
              ),
              if (profile.topVodName != null)
                Text(
                  '看得最多：${profile.topVodName}',
                  style: theme.textTheme.bodySmall,
                ),
              if (_narrative.isNotEmpty) ...[
                const SizedBox(height: AppSpace.md),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.md),
                    child: Text(_narrative, style: theme.textTheme.bodyMedium),
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }

  Widget _rulesTab(ThemeData theme) => ListView(
    padding: const EdgeInsets.all(AppSpace.lg),
    children: [
      Wrap(
        spacing: AppSpace.sm,
        children: [
          FilledButton(
            onPressed: _busy ? null : _analyzeGroupRules,
            child: const Text('分析分组规则'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _loadApprovedRules,
            child: const Text('刷新已应用规则'),
          ),
        ],
      ),
      const SizedBox(height: AppSpace.md),
      if (_groupValidation != null)
        AiGroupRulePreview(
          rules: _groupValidation!.accepted,
          rejected: _groupValidation!.rejected,
          onConfirm: _approveGroupRules,
          onCancel: () => setState(() => _groupValidation = null),
        ),
      if (_approvedGroupRules.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Text(
              '已应用 ${_approvedGroupRules.length} 条分组规则：'
              '${_approvedGroupRules.map((rule) => rule.name).join('、')}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
      if (_adRules.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.md),
            child: Text(
              '已保存 ${_adRules.length} 条去广候选（需当前证据重验后确认）'
              '（域名 ${_adRules.expand((rule) => rule.hostsBlacklist).toSet().length} 个）',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
    ],
  );

  Widget _diagnosisTab(ThemeData theme) => ListView(
    padding: const EdgeInsets.all(AppSpace.lg),
    children: [
      Row(
        children: [
          FilledButton(
            onPressed: _busy ? null : _diagnose,
            child: const Text('诊断最近日志'),
          ),
        ],
      ),
      const SizedBox(height: AppSpace.md),
      if (_diagnosis == null)
        Text('尚未诊断（日志自动从本机日志读取，发送前脱敏）',
            style: theme.textTheme.bodySmall)
      else
        AiLogDiagnosisView(result: _diagnosis!),
    ],
  );

  Widget _dataTab(ThemeData theme) => ListView(
    padding: const EdgeInsets.all(AppSpace.lg),
    children: [
      Text(
        '反馈、分组规则、去广规则与片名学习都是用户数据：可导出 JSON 随备份迁移；'
        '推荐与画像缓存可随时重建。',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: AppSpace.md),
      Row(
        children: [
          FilledButton(
            onPressed: _exportUserData,
            child: const Text('导出用户数据'),
          ),
        ],
      ),
      if (_userDataFileCount > 0)
        Text(
          '已枚举 $_userDataFileCount 个用户数据文件（导出快照不计入，它是导出产物）',
          style: theme.textTheme.bodySmall,
        ),
    ],
  );
}

