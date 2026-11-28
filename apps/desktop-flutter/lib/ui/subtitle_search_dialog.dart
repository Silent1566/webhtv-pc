/// 「搜索在线字幕」窗口（PotPlayer 式独立窗口）。
///
/// 负责：关键词/季集输入 → 调注入的 [search] → 按源分组的候选列表 →
/// 语言筛选 → 选中后 `pop` 返回。四种状态的文案互不相同：初始提示、加载中、
/// 空结果、结果列表；空结果里如实列出「未启用」与「失败」的源，
/// 不把「没有源可用」说成「没有字幕」（计划 §1 不变量 4）。
///
/// **不负责**：触网、落盘、读设置。搜索函数与本地文件选择都由调用方注入，
/// 窗口只搬运数据，因此可以离屏测试与取证。候选的下载/套用（`resolve`）在
/// 调用方那边完成——窗口返回的是候选，不是可播放的字幕文件。
///
/// 设计来源：`docs/superpowers/plans/2026-11-15-subtitle-online-search.md` Task 5。
/// 既有两步流程（关键词对话框 + 结果底部弹窗）见 `player_page.dart:1337-1428`；
/// 本窗口把它们合成一屏，改词重搜不关窗。
library;

import 'package:flutter/material.dart';

import '../core/subtitle_provider.dart';
import '../services/subtitle_match_service.dart';
import 'common.dart';
import 'glass_dialog.dart';
import 'tokens.dart';

/// 窗口尺寸上限（计划 Task 5：最大 720×520）。
const double _kMaxWidth = 720;
const double _kMaxHeight = 520;

/// 语言筛选的一字标签；未登记的语言直接显示代码。
const Map<String, String> _languageShortLabels = {
  'zh-Hans': '简',
  'zh-Hant': '繁',
  'en': '英',
};

/// 打开搜索窗口；选中候选返回它，取消返回 null。
///
/// [preferredLanguages] 同时决定语言筛选条有哪些项（默认即全部/简/繁/英），
/// 所以调用方的语言偏好不需要在这里再存一份。
Future<SubtitleCandidate?> showSubtitleSearchDialog({
  required BuildContext context,
  required SubtitleQuery initialQuery,
  required Future<SubtitleSearchReport> Function(SubtitleQuery query) search,
  List<String> preferredLanguages = kDefaultSubtitleLanguages,
  Future<String?> Function()? pickLocalFile,
  bool blurBackdrop = true,
}) {
  return showGlassDialog<SubtitleCandidate>(
    context: context,
    builder: (context) => SubtitleSearchDialog(
      initialQuery: initialQuery,
      search: search,
      preferredLanguages: preferredLanguages,
      pickLocalFile: pickLocalFile,
      blurBackdrop: blurBackdrop,
    ),
  );
}

class SubtitleSearchDialog extends StatefulWidget {
  const SubtitleSearchDialog({
    super.key,
    required this.initialQuery,
    required this.search,
    this.preferredLanguages = kDefaultSubtitleLanguages,
    this.pickLocalFile,
    this.blurBackdrop = true,
  });

  final SubtitleQuery initialQuery;
  final Future<SubtitleSearchReport> Function(SubtitleQuery query) search;
  final List<String> preferredLanguages;
  final Future<String?> Function()? pickLocalFile;
  final bool blurBackdrop;

  @override
  State<SubtitleSearchDialog> createState() => _SubtitleSearchDialogState();
}

class _SubtitleSearchDialogState extends State<SubtitleSearchDialog> {
  late final TextEditingController _keyword;
  late final TextEditingController _season;
  late final TextEditingController _episode;

  SubtitleSearchReport? _report;
  bool _loading = false;
  bool _failed = false;
  String _languageFilter = '';

  /// 上一次报告里真正应答过的源数；首次搜索时还不知道，就不用假数字。
  int _lastSourceCount = 0;

  @override
  void initState() {
    super.initState();
    _keyword = TextEditingController(text: widget.initialQuery.title)
      ..addListener(_onKeywordChanged);
    _season = TextEditingController(
      text: widget.initialQuery.season?.toString() ?? '',
    );
    _episode = TextEditingController(
      text: widget.initialQuery.episode?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _keyword.dispose();
    _season.dispose();
    _episode.dispose();
    super.dispose();
  }

  /// 只为了「关键词为空时禁用搜索」这一个派生状态。
  void _onKeywordChanged() => setState(() {});

  bool get _canSearch => !_loading && _keyword.text.trim().isNotEmpty;

  int? _intOf(String text) => int.tryParse(text.trim());

  Future<void> _search() async {
    if (!_canSearch) return;
    final query = SubtitleQuery(
      title: _keyword.text.trim(),
      year: widget.initialQuery.year,
      season: _intOf(_season.text),
      episode: _intOf(_episode.text),
      mediaPath: widget.initialQuery.mediaPath,
      siteKey: widget.initialQuery.siteKey,
      vodId: widget.initialQuery.vodId,
      episodeName: widget.initialQuery.episodeName,
    );
    setState(() {
      _loading = true;
      _failed = false;
    });
    SubtitleSearchReport report;
    try {
      report = await widget.search(query);
    } catch (_) {
      // 注入的搜索函数若抛异常，窗口会永远停在「正在搜索」——那不是可见状态。
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _report = const SubtitleSearchReport();
        _lastSourceCount = 0;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _report = report;
      _lastSourceCount = _sourceCountOf(report);
    });
  }

  int _sourceCountOf(SubtitleSearchReport report) {
    final ids = <String>{
      for (final candidate in report.candidates) candidate.providerId,
      ...report.failures.keys,
    };
    return ids.length;
  }

  Future<void> _pickLocal() async {
    final pick = widget.pickLocalFile;
    if (pick == null) return;
    final path = (await pick())?.trim() ?? '';
    if (!mounted || path.isEmpty) return;
    // 与 player_page 的本地字幕流程同一个构造：url 就是文件路径本身。
    Navigator.of(context).pop(
      SubtitleCandidate(
        providerId: 'local',
        assetId: path,
        title: path.split(RegExp(r'[\\/]')).last,
        language: '',
        format: inferSubtitleFormatFromUrl(path),
        url: path,
      ),
    );
  }

  String get _loadingText =>
      _lastSourceCount > 0 ? '正在搜索 $_lastSourceCount 个源' : '正在搜索…';

  /// 空结果的原因行：未启用的源列名字，失败的源列名字 + 原因。
  List<String> get _emptyDetails {
    final report = _report;
    if (report == null) return const [];
    return [
      if (report.unavailable.isNotEmpty)
        '未启用的源：${report.unavailable.map(subtitleProviderLabel).join('、')}',
      if (report.failures.isNotEmpty)
        '失败的源：${report.failures.entries.map((entry) => '${subtitleProviderLabel(entry.key)}（${entry.value}）').join('、')}',
    ];
  }

  List<SubtitleCandidate> get _visibleCandidates {
    final report = _report;
    if (report == null || _languageFilter.isEmpty) {
      return report?.candidates ?? const [];
    }
    final filter = _languageFilter.toLowerCase();
    return [
      for (final candidate in report.candidates)
        if (candidate.language.trim().toLowerCase().startsWith(filter))
          candidate,
    ];
  }

  Map<String, List<SubtitleCandidate>> _groupsOf(
    List<SubtitleCandidate> candidates,
  ) {
    final groups = <String, List<SubtitleCandidate>>{};
    for (final candidate in candidates) {
      groups.putIfAbsent(candidate.providerId, () => []).add(candidate);
    }
    return groups;
  }

  String _subtitleOf(SubtitleCandidate candidate) {
    final language = candidate.language.trim();
    final format = candidate.format.trim();
    return '${subtitleProviderLabel(candidate.providerId)} · '
        '${language.isEmpty ? '未知语言' : language} · '
        '${format.isEmpty ? '未知格式' : format} · '
        '${candidate.score.toStringAsFixed(2)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return glassDialogShell(
      context,
      blurBackdrop: widget.blurBackdrop,
      insetPadding: const EdgeInsets.all(AppSpace.xl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: _kMaxWidth,
          maxHeight: _kMaxHeight,
        ),
        child: SizedBox(
          width: _kMaxWidth,
          height: _kMaxHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.lg,
                  AppSpace.lg,
                  0,
                ),
                child: Text('搜索字幕', style: theme.textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.md,
                  AppSpace.lg,
                  0,
                ),
                child: _queryRow(context),
              ),
              _filterRow(context),
              const SizedBox(height: AppSpace.md),
              const Divider(height: 1),
              Expanded(child: _body(context)),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.md,
                  AppSpace.xs,
                  AppSpace.md,
                  AppSpace.xs,
                ),
                child: Row(
                  children: [
                    TextButton.icon(
                      key: const ValueKey('subtitle-search-local'),
                      onPressed: widget.pickLocalFile == null
                          ? null
                          : _pickLocal,
                      icon: const Icon(Icons.folder_open_outlined, size: 18),
                      label: const Text('选择本地文件…'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _queryRow(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('subtitle-search-keyword'),
            controller: _keyword,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '剧名 / 关键词',
            ),
          ),
        ),
        const SizedBox(width: AppSpace.md),
        _numberField(
          keyName: 'subtitle-search-season',
          controller: _season,
          label: '季',
        ),
        const SizedBox(width: AppSpace.sm),
        _numberField(
          keyName: 'subtitle-search-episode',
          controller: _episode,
          label: '集',
        ),
        const SizedBox(width: AppSpace.md),
        FilledButton(
          key: const ValueKey('subtitle-search-submit'),
          onPressed: _canSearch ? _search : null,
          child: const Text('搜索'),
        ),
      ],
    );
  }

  Widget _numberField({
    required String keyName,
    required TextEditingController controller,
    required String label,
  }) {
    return SizedBox(
      width: 64,
      child: TextField(
        key: ValueKey(keyName),
        controller: controller,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(isDense: true, labelText: label),
      ),
    );
  }

  Widget _filterRow(BuildContext context) {
    // 「全部」永远是第一项；其余由 preferredLanguages 决定，默认即简/繁/英。
    final codes = <String>['', ...widget.preferredLanguages];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        0,
      ),
      child: Wrap(
        spacing: AppSpace.sm,
        runSpacing: AppSpace.sm,
        children: [
          for (final code in codes)
            ChoiceChip(
              key: ValueKey(
                'subtitle-search-filter-${code.isEmpty ? 'all' : code}',
              ),
              label: Text(
                code.isEmpty ? '全部' : (_languageShortLabels[code] ?? code),
              ),
              selected: _languageFilter == code,
              // 默认 48 的点击热区会把筛选条撑成两倍高，挤出结果列表的空间。
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onSelected: (_) => setState(() => _languageFilter = code),
            ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              _loadingText,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    final report = _report;
    if (report == null) {
      return const EmptyState(
        icon: Icons.search,
        title: '输入关键词开始搜索',
        message: '也可以点「选择本地文件…」装载自己的字幕文件。',
      );
    }
    if (report.isEmpty) {
      final details = _emptyDetails;
      return EmptyState(
        icon: Icons.subtitles_off_outlined,
        title: _failed ? '搜索失败，请稍后重试' : '没有找到字幕，换个关键词试试',
        message: details.isEmpty ? null : details.join('\n'),
      );
    }
    final visible = _visibleCandidates;
    if (visible.isEmpty) {
      return const EmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: '当前筛选无结果',
        message: '把语言切回「全部」可以看到其余候选。',
      );
    }
    return _results(context, visible);
  }

  Widget _results(BuildContext context, List<SubtitleCandidate> candidates) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      children: [
        for (final entry in _groupsOf(candidates).entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.xs,
              AppSpace.lg,
              0,
            ),
            child: Text(
              '${subtitleProviderLabel(entry.key)} · ${entry.value.length} 条',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final candidate in entry.value)
            _candidateRow(context, candidate),
        ],
      ],
    );
  }

  /// 两行紧凑行。
  ///
  /// 不用 `ListTile`：它在 `dense` + `VisualDensity.compact` 下按单行高度收口，
  /// 两行内容会互相压住；而默认高度的两行 tile 又让 520 高的窗口装不下 5 条
  /// 候选（`docs/reference/evidence/p0-6b-search/` 的取证图就是这一屏）。
  Widget _candidateRow(BuildContext context, SubtitleCandidate candidate) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey(
        'subtitle-search-row-${candidate.providerId}-${candidate.assetId}',
      ),
      onTap: () => Navigator.of(context).pop(candidate),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: AppSpace.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              candidate.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              _subtitleOf(candidate),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
