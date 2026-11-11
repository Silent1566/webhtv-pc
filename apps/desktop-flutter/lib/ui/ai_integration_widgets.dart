import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/ai_content/ad_rule_validation.dart';
import '../core/ai_content/ai_content_contracts.dart';
import '../core/ai_content/group_rule_validation.dart';
import '../core/ai_content/log_diagnosis.dart';
import '../core/ai_content/recommendation.dart';
import '../core/ai_content/viewing_profile.dart';
import '../core/viewing_report.dart';
import '../core/audio_ai/audio_ai.dart';
import '../ui/audio_ai/audio_ai_controls.dart';
import 'karaoke/karaoke_controls.dart';
import '../services/karaoke/track_repository.dart';
import '../services/ai_content/ad_rule_service.dart';
import '../services/ai_integration.dart';
import '../state/app_state.dart';
import 'ai_content/ai_content_widgets.dart';
import 'ai_settings_page.dart';
import 'reader/reader_page.dart';
import '../services/reader/reader_tts_controller.dart';
import 'search_page.dart';
import 'tokens.dart';

Future<void> openAiBusiness(
  BuildContext context,
  AppState state, {
  RecommendationSource source = RecommendationSource.history,
  String keyword = '',
  String title = '',
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => AiBusinessPage(
      state: state,
      source: source,
      keyword: keyword,
      title: title,
    ),
  ),
);

/// SearchPage 自身不包含 Scaffold/Material（在应用里它由 shell 承载）。
/// 任何**新路由**都必须自己给出真实宿主，否则 PopupMenu/TextField 会 No Material。
Widget aiSearchRouteHost(AppState state, String keyword) => Scaffold(
  appBar: AppBar(title: const Text('搜索')),
  body: SearchPage(
    state: state,
    initialKeyword: keyword,
    useExistingResults: true,
  ),
);

class AiBusinessPage extends StatefulWidget {
  const AiBusinessPage({
    super.key,
    required this.state,
    this.source = RecommendationSource.history,
    this.keyword = '',
    this.title = '',
    this.readerController,
  });
  final AppState state;
  final RecommendationSource source;
  final String keyword;
  final String title;

  /// 既有注入缝：测试用受控 TTS 控制器打开真实 ReaderPage，不造占位引擎。
  final ReaderTtsController? readerController;
  @override
  State<AiBusinessPage> createState() => _AiBusinessPageState();
}

class _AiBusinessPageState extends State<AiBusinessPage> {
  AiContentCancellation? _cancellation;
  bool _busy = false;
  String _message = '';
  List<RecommendationCard> _cards = const [];
  GroupRuleValidation? _groups;
  LogDiagnosisResult? _diagnosis;
  ViewingProfile? _profile;
  String _narrative = '';
  ViewingReportRange _range = ViewingReportRange.all;
  int _run = 0;
  String _scope = '';
  String get _scopeKey =>
      '${widget.state.tmdbConfigId}|${widget.state.activeSourceKey}|${widget.state.historyScope}';
  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _scope = _scopeKey;
    state.addListener(_changed);
  }

  void _changed() {
    if (_scope != _scopeKey) {
      _scope = _scopeKey;
      _cancellation?.cancel();
      _run++;
      _busy = false;
      _cards = const [];
      _groups = null;
      _profile = null;
      _narrative = '';
      _message = '';
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    state.removeListener(_changed);
    _cancellation?.cancel();
    _run++;
    super.dispose();
  }

  Future<void> _work(
    Future<void> Function(AiContentCancellation cancellation, int run) action,
  ) async {
    if (_busy) return;
    final run = ++_run;
    final cancellation = AiContentCancellation();
    _cancellation = cancellation;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await action(cancellation, run);
    } catch (error) {
      if (_valid(run)) setState(() => _message = '$error');
    } finally {
      if (_valid(run)) setState(() => _busy = false);
    }
  }

  bool _valid(int run) =>
      mounted && run == _run && !(_cancellation?.isCancelled ?? false);
  void _cancel() {
    _cancellation?.cancel();
    _run++;
    setState(() {
      _busy = false;
      _message = '已取消；未应用结果';
    });
  }

  List<WatchContextItem> _contexts() => [
    for (final row in state.recentHistory(limit: 24))
      WatchContextItem(
        title: row.vodName,
        mediaType: row.mediaType == 'movie'
            ? RecommendationMediaType.movie
            : RecommendationMediaType.tv,
        year: int.tryParse(row.vodYear),
        lastWatchedAtMs: row.updatedAt,
        sourceLabel: row.siteKey,
      ),
  ];

  Future<void> _recommend() => _work((cancellation, run) async {
    final result = await state.aiIntegration.recommendation.recommend(
      request: RecommendationRequest(
        source: widget.source,
        keyword: widget.keyword,
        siteKey: state.selectedSite?.key ?? '',
        seed: widget.title.isEmpty
            ? null
            : WatchContextItem(
                title: widget.title,
                mediaType: state.tmdb.identity?.mediaType.name == 'movie'
                    ? RecommendationMediaType.movie
                    : RecommendationMediaType.tv,
              ),
        contexts: _contexts(),
      ),
      cancellation: cancellation,
    );
    if (!_valid(run)) return;
    setState(() {
      _cards = result.value ?? const [];
      _message = result.ok ? '推荐已生成，点击按当前源搜索；无结果时全局搜索' : result.message;
    });
  });

  Future<void> _openCard(RecommendationCard card) async {
    final outcome = await state.searchRecommendation(card.title);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => aiSearchRouteHost(state, card.title),
      ),
    );
    if (!mounted) return;
    if (outcome == null) setState(() => _message = '当前未配置可搜索站点');
  }

  Future<void> _feedback(RecommendationCard card) async {
    final result = await state.aiIntegration.recommendation.markNotInterested(
      card,
    );
    if (!mounted) return;
    setState(() {
      if (result.ok) _cards = _cards.where((c) => c != card).toList();
      _message = result.ok ? '不感兴趣已保存，后续推荐和缓存都会过滤' : result.message;
    });
  }

  Future<void> _analyzeGroups() => _work((cancellation, run) async {
    final result = await state.aiIntegration.group.analyze(
      sourceNames: state.siteItems.map((item) => item.site.name).toList(),
      cancellation: cancellation,
    );
    if (!_valid(run)) return;
    setState(() {
      _groups = result.value;
      _message = result.message;
    });
  });
  Future<void> _applyGroups() async {
    if (_groups == null || _groups!.accepted.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认应用分组规则'),
        content: const Text('只替换AI分组规则；手工规则与内置开关保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认应用'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await state.applyAiGroupRules(_groups!.accepted);
    if (mounted) {
      setState(() => _message = ok ? '规则已应用到站点分组并保存' : '规则保存失败，未确认业务应用');
    }
  }

  Future<void> _diagnose() => _work((cancellation, run) async {
    final result = await state.aiIntegration.diagnosis.diagnose(
      cancellation: cancellation,
    );
    if (!_valid(run)) return;
    setState(() {
      _diagnosis = result.value;
      _message = result.message;
    });
  });
  Future<void> _buildProfile() => _work((cancellation, run) async {
    final records = state.recentHistory(limit: 10000);
    final report = generateViewingReport(records: records, range: _range);
    final latest = records.fold<int>(
      0,
      (a, r) => r.updatedAt > a ? r.updatedAt : a,
    );
    final structured = await state.aiIntegration.profile.profile(
      report: report,
      latestUpdatedAtMs: latest,
    );
    final narrative = await state.aiIntegration.profile.narrative(
      report: report,
      cancellation: cancellation,
    );
    if (!_valid(run)) return;
    setState(() {
      _profile = structured.value;
      _narrative = narrative.value ?? '';
      _message = narrative.ok ? '画像已生成' : '本地画像可用；AI解读：${narrative.message}';
    });
  });

  Future<String?> _pickPath(String label) async {
    final controller = TextEditingController(
      text: '${state.paths.dataDir}${Platform.pathSeparator}ai-user-data.json',
    );
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: SizedBox(
          width: 600,
          child: TextField(
            controller: controller,
            decoration: InputDecoration(labelText: label),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return path == null || path.isEmpty ? null : path;
  }

  Future<void> _export() async {
    final location = await _pickPath('导出路径');
    if (location == null) return;
    try {
      final raw = await exportAiUserFiles(state.paths);
      final output = File(location);
      await output.parent.create(recursive: true);
      await output.writeAsString(raw, flush: true);
      if (mounted) setState(() => _message = '用户反馈、学习与规则已导出（不含缓存/模型）');
    } catch (error) {
      if (mounted) setState(() => _message = '导出失败：$error');
    }
  }

  Future<void> _import() async {
    final path = await _pickPath('导入路径');
    final file = path == null ? null : File(path);
    if (file == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入AI用户数据'),
        content: const Text('替换文件中的用户域。广告规则仅导入候选，播放时仍须重新校验并确认。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await state.importAiUserData(await file.readAsString());
      if (mounted) {
        setState(() {
          _cards = const [];
          _groups = null;
          _message = '已导入；广告候选尚未应用';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = '导入失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI业务与阅读器'),
        actions: [
          IconButton(
            tooltip: 'AI设置',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => AiSettingsPage(state: state),
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Text(
            state.aiReady ? 'AI已配置；只有明确点击才发起请求' : 'AI未配置：原播放行为不变，配置后可使用智能业务',
          ),
          SwitchListTile(
            key: const ValueKey('ai-title-switch'),
            title: const Text('AI片名提取与失败回退'),
            subtitle: const Text('用于TMDB身份、字幕与弹幕重试；默认关闭'),
            value: state.aiTitleExtractionEnabled,
            onChanged: state.setAiTitleExtractionEnabled,
          ),
          SwitchListTile(
            key: const ValueKey('ai-ad-switch'),
            title: const Text('AI广告规则分析'),
            subtitle: const Text('必须当前播放证据与人工确认；默认关闭'),
            value: state.aiAdDetectionEnabled,
            onChanged: state.setAiAdDetectionEnabled,
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('ai-reader-open'),
                onPressed: () =>
              openReaderInput(context, readerController: widget.readerController),
                icon: const Icon(Icons.menu_book_outlined),
                label: const Text('阅读器'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _export,
                child: const Text('导出AI用户数据'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _import,
                child: const Text('导入AI用户数据'),
              ),
              if (_busy)
                TextButton(onPressed: _cancel, child: const Text('取消当前请求')),
            ],
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_message),
            ),
          const Divider(height: 32),
          Text(
            '推荐 · ${widget.title.isNotEmpty
                ? widget.title
                : widget.keyword.isNotEmpty
                ? widget.keyword
                : '观看历史'}',
            style: theme.textTheme.titleMedium,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const ValueKey('ai-recommend-run'),
              onPressed: _busy || !state.aiReady ? null : _recommend,
              child: const Text('生成推荐'),
            ),
          ),
          for (final card in _cards)
            AiRecommendationCardTile(
              card: card,
              onOpen: () => _openCard(card),
              onNotInterested: () => _feedback(card),
            ),
          const Divider(height: 32),
          Text('站点分组', style: theme.textTheme.titleMedium),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy || !state.aiReady ? null : _analyzeGroups,
              child: const Text('分析当前站点分组'),
            ),
          ),
          if (_groups != null)
            AiGroupRulePreview(
              rules: _groups!.accepted,
              rejected: _groups!.rejected,
              onConfirm: _busy ? null : _applyGroups,
            ),
          const Divider(height: 32),
          Text('日志诊断（读取真实日志，发送前脱敏）', style: theme.textTheme.titleMedium),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy || !state.aiReady ? null : _diagnose,
              child: const Text('诊断日志'),
            ),
          ),
          if (_diagnosis != null) AiLogDiagnosisView(result: _diagnosis!),
          const Divider(height: 32),
          DropdownButton<ViewingReportRange>(
            value: _range,
            items: [
              for (final range in ViewingReportRange.values)
                DropdownMenuItem(value: range, child: Text(range.label)),
            ],
            onChanged: (range) {
              if (range == null) return;
              _cancellation?.cancel();
              _run++;
              setState(() {
                _range = range;
                _profile = null;
                _narrative = '';
                _busy = false;
                _message = '';
              });
            },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy ? null : _buildProfile,
              child: const Text('生成画像与观影解读'),
            ),
          ),
          if (_profile != null)
            Text(
              '${_range.label} · ${_profile!.recordCount}条 · ${_profile!.totalWatchMinutes}分钟 · 完播${(_profile!.completionRate * 100).round()}%',
            ),
          if (_narrative.isNotEmpty) SelectableText(_narrative),
        ],
      ),
    );
  }
}

Future<void> openReaderInput(
  BuildContext context, {
  String initialText = '',
  String title = '阅读器',
  ReaderTtsController? readerController,
}) async {
  final text = await showDialog<String>(
    context: context,
    builder: (context) =>
        _ReaderTextDialog(initialText: initialText, title: title),
  );
  if (text == null || text.trim().isEmpty || !context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ReaderPage(
        initialText: text,
        title: title,
        controller: readerController,
      ),
    ),
  );
}

/// 正文输入对话框：控制器由本 State 持有并在自身 dispose 时释放。
///
/// 不能在外层 `await showDialog` 之后立刻 dispose：对话框退场动画期间
/// TextField 仍会重建并访问该 controller（实测 "used after being disposed"）。
class _ReaderTextDialog extends StatefulWidget {
  const _ReaderTextDialog({required this.initialText, required this.title});

  final String initialText;
  final String title;

  @override
  State<_ReaderTextDialog> createState() => _ReaderTextDialogState();
}

class _ReaderTextDialogState extends State<_ReaderTextDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 560,
      child: TextField(
        key: const ValueKey('ai-reader-text'),
        controller: _controller,
        minLines: 6,
        maxLines: 12,
        decoration: const InputDecoration(
          labelText: '阅读正文',
          hintText: '粘贴文字；不自动访问网页',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('ai-reader-confirm'),
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('打开阅读器'),
      ),
    ],
  );
}

Future<void> openAiAdReview(
  BuildContext context,
  AppState state, {
  required String siteKey,
  required String title,
  required String flag,
  required String episode,
}) async {
  final evidence = state.aiPlaylistFor(siteKey);
  if (evidence == null) {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('无法应用AI广告规则'),
        content: const Text('当前播放没有真实HLS媒体切片证据；不分析、不安装导入候选。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _AiAdReviewDialog(
      state: state,
      snapshot: evidence,
      context: AdDetectionContext(
        siteKey: siteKey,
        vodName: title,
        flagName: flag,
        episodeName: episode,
        urlHost: evidence.playlist.host,
        urlPath: evidence.playlist.path,
      ),
    ),
  );
}

class _AiAdReviewDialog extends StatefulWidget {
  const _AiAdReviewDialog({
    required this.state,
    required this.snapshot,
    required this.context,
  });
  final AppState state;
  final AiPlaylistSnapshot snapshot;
  final AdDetectionContext context;
  @override
  State<_AiAdReviewDialog> createState() => _AiAdReviewDialogState();
}

class _AiAdReviewDialogState extends State<_AiAdReviewDialog> {
  final _cancel = AiContentCancellation();
  bool _busy = false;
  String _message = '';
  AdRuleAssessment? _assessment;
  List<AdRuleAssessment> _candidates = const [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final candidates = await widget.state.aiIntegration.ad.loadCandidates();
    if (mounted) {
      setState(
        () => _candidates = [
          for (final proposal in candidates)
            widget.state.aiIntegration.ad.assessForApplication(
              proposal,
              context: widget.context,
              evidence: widget.snapshot.evidence,
            ),
        ],
      );
    }
  }

  Future<void> _analyze() async {
    setState(() => _busy = true);
    final result = await widget.state.aiIntegration.ad.analyze(
      context: widget.context,
      evidence: widget.snapshot.evidence,
      cancellation: _cancel,
    );
    if (mounted && !_cancel.isCancelled) {
      setState(() {
        _assessment = result.value;
        _message = result.message;
        _busy = false;
      });
    }
  }

  @override
  void dispose() {
    // 关闭对话框等同撤销：在途 approve 完成后不得再安装规则。
    widget.state.cancelAiAdApply();
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _apply(AdRuleAssessment assessment) async {
    final current = widget.state.aiPlaylistFor(widget.context.siteKey);
    if (current == null || current.signature != widget.snapshot.signature) {
      setState(() => _message = '播放/切片证据已变化，请关闭后重新分析');
      return;
    }
    setState(() => _busy = true);
    final ticket = widget.state.startAiAdApply();
    final ok = await widget.state.applyAiAdRule(
      assessment,
      context: widget.context,
      evidence: current.evidence,
      playlist: current.playlist,
      ticket: ticket,
    );
    if (mounted) {
      setState(() {
        _message = ok ? '规则已应用到当前播放代理；其他播放不生效' : '规则被拒绝或保存失败，未应用';
        _busy = false;
      });
    }
  }

  Widget _preview(AdRuleAssessment assessment) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text([...assessment.reasons, ...assessment.warnings].join('；')),
      if (assessment.proposal != null) AiAdRulePreview(assessment: assessment),
      FilledButton(
        onPressed: _busy || !assessment.applicable
            ? null
            : () => _apply(assessment),
        child: const Text('人工确认应用到当前播放'),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('AI广告规则 · 当前播放证据'),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.context.urlHost}${widget.context.urlPath} · ${widget.snapshot.evidence.totalSegments}个真实切片',
            ),
            Text(_message),
            if (_busy) const LinearProgressIndicator(),
            OutlinedButton(
              onPressed:
                  _busy ||
                      !widget.state.aiReady ||
                      !widget.state.aiAdDetectionEnabled
                  ? null
                  : _analyze,
              child: const Text('分析广告证据'),
            ),
            if (_assessment != null) _preview(_assessment!),
            for (final candidate in _candidates) _preview(candidate),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          // 先撤销在途提交，再关闭：await 之后不会再安装代理规则。
          widget.state.cancelAiAdApply();
          _cancel.cancel();
          Navigator.pop(context);
        },
        child: const Text('关闭 / 取消'),
      ),
    ],
  );
}

class PlayerAudioAiPanel extends StatefulWidget {
  const PlayerAudioAiPanel({
    super.key,
    required this.state,
    required this.session,
    required this.mediaUri,
    required this.headers,
    required this.title,
    required this.karaokeMedia,
    required this.language,
    required this.onSettingsChanged,
    required this.onPickSrt,
    required this.onTranslated,
    required this.onTrack,
    this.currentSrt,
  });
  final AppState state;
  final PlayerAudioAiSession session;
  final Uri mediaUri;
  final Map<String, String> headers;
  final String title, language;
  final KaraokeMedia karaokeMedia;
  final SrtDocument? currentSrt;
  final Future<void> Function(String modelId, String language)
  onSettingsChanged;
  final Future<SrtDocument?> Function() onPickSrt;
  final ValueChanged<SrtTranslationResult> onTranslated;
  final void Function(KaraokePitchTrack track, List<TimedLyricLine> lines)
  onTrack;
  @override
  State<PlayerAudioAiPanel> createState() => _PlayerAudioAiPanelState();
}

class _PlayerAudioAiPanelState extends State<PlayerAudioAiPanel> {
  SrtDocument? _selectedSrt;
  BasicPitchService? _pitch;
  String _target = 'zh';
  String _message = '';
  int _concurrency = 2, _chunks = 2;
  SrtDocument? get _srt => _selectedSrt ?? widget.currentSrt;
  Future<void> _pickSrt() async {
    try {
      final value = await widget.onPickSrt();
      if (mounted) setState(() => _selectedSrt = value);
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    }
  }

  Future<void> _importKaraokeText() async {
    final input = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入UltraStar参考评分轨'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: input,
            minLines: 6,
            maxLines: 12,
            decoration: const InputDecoration(labelText: '原始评分轨文本'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('校验并导入'),
          ),
        ],
      ),
    );
    input.dispose();
    if (text == null || !mounted) return;
    final result = await widget.session.karaokeRepository.importText(
      widget.karaokeMedia,
      widget.title,
      text,
    );
    if (!mounted) return;
    setState(
      () => _message = result.success ? '评分轨已绑定当前媒体并保存（非生成缓存）' : result.error,
    );
    if (result.success) widget.session.karaoke.selectTrack(result.track);
  }

  Future<void> _importKaraokeFile() async {
    final input = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入本地TXT / MIDI评分轨'),
        content: TextField(
          controller: input,
          decoration: const InputDecoration(labelText: '本地文件路径'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('读取并校验'),
          ),
        ],
      ),
    );
    input.dispose();
    if (path == null || path.isEmpty || !mounted) return;
    try {
      final file = File(path);
      final result = await widget.session.karaokeRepository.importFile(
        widget.karaokeMedia,
        file.uri.pathSegments.last,
        await file.readAsBytes(),
      );
      if (!mounted) return;
      setState(() => _message = result.success ? '本地评分轨已导入并绑定' : result.error);
      if (result.success) widget.session.karaoke.selectTrack(result.track);
    } catch (error) {
      if (mounted) setState(() => _message = '读取评分轨失败：$error');
    }
  }

  Future<void> _preparePitch() async {
    try {
      final service = await BasicPitchService.fromBundledAsset(
        Directory('${widget.state.paths.cacheDir}/audio_ai/basic_pitch'),
      );
      if (mounted) setState(() => _pitch = service);
    } catch (error) {
      if (mounted) setState(() => _message = 'BasicPitch模型不可用：$error');
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    padding: const EdgeInsets.all(16),
    children: [
      const Text('音频AI：默认关闭；模型/解码失败不改变原播放'),
      TextFormField(
        initialValue: widget.language,
        decoration: const InputDecoration(labelText: '原音语言代码'),
        onFieldSubmitted: (value) =>
            widget.onSettingsChanged(widget.session.model.id, value.trim()),
      ),
      AudioModelControls(
        manager: widget.session.models,
        modelId: widget.session.model.id,
        onSelected: (model) =>
            widget.onSettingsChanged(model.id, widget.language),
      ),
      RealtimeSubtitleControls(
        key: ObjectKey(widget.session),
        controller: widget.session.realtime,
        capture: widget.session.capture,
        clock: widget.session.clock,
        model: widget.session.model,
        mediaUri: widget.mediaUri,
        headers: widget.headers,
      ),
      const Divider(height: 24),
      const Text('翻译当前SRT / 搜索字幕候选（保留原字幕文件和轨道）'),
      OutlinedButton(onPressed: _pickSrt, child: const Text('选择字幕候选用于翻译 / 歌词')),
      TextFormField(
        initialValue: _target,
        decoration: const InputDecoration(labelText: '翻译目标语言'),
        onFieldSubmitted: (value) => setState(() => _target = value.trim()),
      ),
      Row(
        children: [
          const Text('并发'),
          DropdownButton<int>(
            value: _concurrency,
            items: [
              for (var i = 1; i <= 8; i++)
                DropdownMenuItem(value: i, child: Text('$i')),
            ],
            onChanged: (value) => setState(() => _concurrency = value ?? 2),
          ),
          const Text('分块'),
          DropdownButton<int>(
            value: _chunks,
            items: [
              for (var i = 1; i <= 32; i++)
                DropdownMenuItem(value: i, child: Text('$i')),
            ],
            onChanged: (value) => setState(() => _chunks = value ?? 2),
          ),
        ],
      ),
      if (_srt == null) const Text('当前无可导出的SRT；内嵌字幕不可假装已读取，请选择真实SRT候选'),
      if (_srt != null && widget.state.aiReady)
        SrtTranslationControls(
          key: ValueKey(
            '${_srt!.source.hashCode}|$_target|$_chunks|$_concurrency',
          ),
          service: SrtTranslationService.fromConfig(
            widget.state.aiConfig,
            cacheDir: Directory(
              '${widget.state.paths.cacheDir}/audio_ai/translations',
            ),
            maxConcurrency: _concurrency,
            chunkCount: _chunks,
          ),
          request: SrtTranslationRequest(
            document: _srt!,
            sourceLanguage: widget.language,
            targetLanguage: _target,
          ),
          onTranslated: widget.onTranslated,
        ),
      const Divider(height: 24),
      const Text('BasicPitch生成参考轨与真实麦克风演唱评分'),
      KaraokeControls(controller: widget.session.karaoke),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: _importKaraokeText,
            child: const Text('粘贴评分轨'),
          ),
          OutlinedButton(
            onPressed: _importKaraokeFile,
            child: const Text('导入TXT / MIDI'),
          ),
        ],
      ),
      KaraokeTrackPicker(
        repository: widget.session.karaokeRepository,
        media: widget.karaokeMedia,
        onImported: (result) {
          if (mounted && result.success) {
            widget.session.karaoke.selectTrack(result.track);
          }
        },
      ),
      if (_srt != null && _pitch == null)
        OutlinedButton(
          onPressed: _preparePitch,
          child: const Text('准备已打包BasicPitch模型'),
        ),
      if (_srt != null && _pitch != null)
        BasicPitchControls(
          service: _pitch!,
          mediaUri: widget.mediaUri,
          headers: widget.headers,
          lines: lyricLinesFromSrt(_srt!),
          title: widget.title,
          onGenerated: (track) =>
              widget.onTrack(track, lyricLinesFromSrt(_srt!)),
        ),
      if (_message.isNotEmpty) Text(_message),
    ],
  );
}
