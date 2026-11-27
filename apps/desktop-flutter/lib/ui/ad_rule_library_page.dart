/// 本地广告规则库管理页（安卓 AdRuleManageDialog 的 PC 化）。
///
/// 只管理**本地**规则库：列表、增删改开关、JSON 导入导出，以及一段样本清单的
/// 命中预览。不做远程订阅，也不内置通用规则——「什么算广告」由用户自己维护。
///
/// 预览为什么必须在这儿：规则写错方向的最直观后果是「删多了」还是「一条没删」，
/// 而这两件事只有把规则套在真实清单上才看得出来。预览**只读**：结果不落盘、
/// 不改库，也不经过播放链路（真正的清洗入口仍是 cleanHlsPlaylist）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/ad_rule_library.dart';
import '../core/ad_rules.dart';
import 'common.dart';
import 'settings_layout.dart';
import 'tokens.dart';

/// 样本清单：足够让 cleanHlsPlaylist 认出这是点播媒体清单。
const String _samplePlaylist =
    '#EXTM3U\n'
    '#EXT-X-VERSION:3\n'
    '#EXT-X-TARGETDURATION:6\n'
    '#EXT-X-MEDIA-SEQUENCE:0\n'
    '#EXTINF:5.0,\n'
    'https://media.example.com/1.ts\n'
    '#EXTINF:5.0,\n'
    'https://media.example.com/2.ts\n'
    '#EXTINF:5.0,\n'
    'https://media.example.com/3.ts\n'
    '#EXTINF:5.0,\n'
    'https://media.example.com/4.ts\n'
    '#EXT-X-ENDLIST\n';

class AdRuleLibraryPage extends StatefulWidget {
  const AdRuleLibraryPage({
    super.key,
    required this.store,
    this.effectiveRules,
  });

  final AdRuleLibraryStore store;

  /// 预览用的「当前生效规则」来源。
  ///
  /// 默认按「库 + 无配置 + 总开关开」解析；接线时注入带 AppConfig 与总开关的
  /// 版本，预览才和播放期真正生效的规则一致（注入方负责读 AppState）。
  final AdRuleSet Function(List<AdRuleEntry> entries)? effectiveRules;

  @override
  State<AdRuleLibraryPage> createState() => _AdRuleLibraryPageState();
}

class _AdRuleLibraryPageState extends State<AdRuleLibraryPage> {
  AdRuleLibraryStore get _store => widget.store;

  /// 最近一次「备份原文件并重新开始」的备份路径；展示出来让人能找回原文。
  String? _backupPath;

  /// 是否接入了「播放期生效规则」解析器。
  ///
  /// 没接入时只能按库预览，而按库预览会把「配置内联规则」「广告过滤总开关」
  /// 都省掉——那样的结果必须标明口径，否则它看起来就像播放期真会删那么多。
  bool get _usesPlaybackRules => widget.effectiveRules != null;

  AdRuleSet _resolvedRules() {
    final resolve = widget.effectiveRules;
    if (resolve != null) return resolve(_store.entries);
    // 仅在未接线时兜底：口径由预览弹窗显式标注（见 _AdRulePreviewDialog）。
    return resolveEffectiveRules(
      config: null,
      library: _store.entries,
      adBlockEnabled: true,
    );
  }

  Future<void> _startOver() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新开始？'),
        content: const Text(
          '会把当前读不懂的规则库文件改名成一份 .corrupt-<时间戳> 备份，'
          '然后以空库重建。备份文件会留在同目录，可以手动找回原文。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认重新开始'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final backupPath = _store.backupAndStartOver();
    setState(() => _backupPath = backupPath);
    if (!mounted) return;
    _toast(backupPath == null ? '重新开始失败，规则库未改动' : '已重新开始，原文件备份在 $backupPath');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _addEntry() async {
    final created = await showDialog<AdRuleEntry>(
      context: context,
      builder: (context) => const _AdRuleEntryDialog(),
    );
    if (!mounted || created == null) return;
    final ok = _store.add(created);
    setState(() {});
    final label = created.name.isEmpty ? created.id : created.name;
    _toast(ok ? '已新增「$label」' : '保存失败，规则库未改动');
  }

  Future<void> _editEntry(AdRuleEntry entry) async {
    final edited = await showDialog<AdRuleEntry>(
      context: context,
      builder: (context) => _AdRuleEntryDialog(entry: entry),
    );
    if (!mounted || edited == null) return;
    final ok = _store.update(edited);
    setState(() {});
    _toast(ok ? '已保存' : '保存失败，规则库未改动');
  }

  Future<void> _deleteEntry(AdRuleEntry entry) async {
    final label = entry.name.isEmpty ? entry.id : entry.name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除规则集？'),
        content: Text('「$label」将从本地规则库中移除，无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final ok = _store.remove(entry.id);
    setState(() {});
    _toast(ok ? '已删除' : '删除失败，规则库未改动');
  }

  void _toggle(AdRuleEntry entry, bool enabled) {
    final ok = _store.setEnabled(entry.id, enabled);
    setState(() {});
    if (!ok) _toast('开关未能保存');
  }

  Future<void> _import() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _AdRuleImportDialog(store: _store),
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _export() async {
    final text = _store.exportJson();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    final count = _store.entries.length;
    _toast('已复制 $count 条规则集的 JSON 到剪贴板');
  }

  Future<void> _preview() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _AdRulePreviewDialog(
        rules: _resolvedRules,
        playbackRules: _usesPlaybackRules,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _store.entries;
    final loadError = _store.loadError;
    // 读错即锁定写操作：此时库里的内容是残缺的，任何保存都会覆盖用户原文。
    final locked = loadError != null;
    final backupPath = _backupPath;
    final entriesCount = entries.length;
    final enabledCount = entries.where((entry) => entry.enabled).length;
    return Scaffold(
      key: const ValueKey<String>('ad-rule-library-page'),
      appBar: AppBar(title: const Text('本地广告规则库')),
      body: ListView(
        padding: formPagePadding(context),
        children: [
          Text(
            '这些规则只存在本机，不会上传也不会自动更新。生效范围是「广告过滤」'
            '总开关打开时的代理请求与 HLS 清单清洗；总开关关闭时任何规则都不生效。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          if (loadError != null) ...[
            _NoticeBar(message: loadError, icon: Icons.warning_amber_rounded),
            const SizedBox(height: AppSpace.sm),
            Text(
              '为避免覆盖还读得出来的内容，新增、编辑、删除、开关与导入都已停用。'
              '确认要放弃原文件时再重新开始（会先留一份备份）。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _startOver,
                icon: const Icon(Icons.restore_page_outlined),
                label: const Text('备份原文件并重新开始'),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
          ],
          if (backupPath != null) ...[
            _NoticeBar(
              message: '原文件已备份到 $backupPath',
              icon: Icons.info_outline,
              tone: _NoticeTone.info,
            ),
            const SizedBox(height: AppSpace.lg),
          ],
          SettingsSection(
            title: '规则集',
            description: entries.isEmpty
                ? null
                : '共 $entriesCount 条，其中启用 $enabledCount 条。',
            children: [
              SettingsActions(
                children: [
                  FilledButton.icon(
                    onPressed: locked ? null : _addEntry,
                    icon: const Icon(Icons.add),
                    label: const Text('新增规则集'),
                  ),
                  OutlinedButton.icon(
                    onPressed: locked ? null : _import,
                    icon: const Icon(Icons.file_download_outlined),
                    label: const Text('导入 JSON'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _export,
                    icon: const Icon(Icons.copy_all_outlined),
                    label: const Text('导出到剪贴板'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _preview,
                    icon: const Icon(Icons.play_circle_outline),
                    label: const Text('样本预览'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.lg),
              if (entries.isEmpty)
                const EmptyState(
                  title: '还没有本地规则',
                  message: '新增一条规则集，或从剪贴板粘贴 JSON 导入。规则为空时不做任何过滤。',
                  icon: Icons.rule_folder_outlined,
                )
              else
                for (final entry in entries)
                  _EntryTile(
                    entry: entry,
                    locked: locked,
                    onToggle: (value) => _toggle(entry, value),
                    onEdit: () => _editEntry(entry),
                    onDelete: () => _deleteEntry(entry),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.locked,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final AdRuleEntry entry;

  /// 读错状态下停用一切写入控件（回调传 null，开关置灰）。
  final bool locked;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final id = entry.id;
    final title = entry.name.isEmpty ? id : entry.name;
    final sourceLabel = entry.source == kAdRuleSourceImported ? '导入' : '手写';
    return Card(
      key: ValueKey<String>('ad-rule-entry-$id'),
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        child: Row(
          children: [
            Switch(
              key: ValueKey<String>('ad-rule-enabled-$id'),
              value: entry.enabled,
              onChanged: locked ? null : onToggle,
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    entry.summary,
                    key: ValueKey<String>('ad-rule-summary-$id'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    '$sourceLabel · $id',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey<String>('ad-rule-edit-$id'),
              tooltip: '编辑',
              onPressed: locked ? null : onEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              key: ValueKey<String>('ad-rule-delete-$id'),
              tooltip: '删除',
              onPressed: locked ? null : onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

enum _NoticeTone { error, info }

class _NoticeBar extends StatelessWidget {
  const _NoticeBar({
    required this.message,
    required this.icon,
    this.tone = _NoticeTone.error,
  });

  final String message;
  final IconData icon;

  /// 红底只留给「出事了」；备份路径这类提示用中性底色，否则界面满屏都是错。
  final _NoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isError = tone == _NoticeTone.error;
    final background = isError
        ? scheme.errorContainer
        : scheme.surfaceContainerHighest;
    final foreground = isError ? scheme.onErrorContainer : scheme.onSurface;
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppRadius.mdAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// 新增/编辑一条规则集。
class _AdRuleEntryDialog extends StatefulWidget {
  const _AdRuleEntryDialog({this.entry});

  final AdRuleEntry? entry;

  @override
  State<_AdRuleEntryDialog> createState() => _AdRuleEntryDialogState();
}

class _AdRuleEntryDialogState extends State<_AdRuleEntryDialog> {
  late final TextEditingController _name;
  late final TextEditingController _ads;
  late final TextEditingController _rules;

  /// 第一次点保存时如果规则有被丢弃的条目，先只展示原因：
  /// 「保存成功」但库里少了几条规则，是最难查的一类差异。
  HlsRuleValidation? _pending;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _name = TextEditingController(text: entry?.name ?? '');
    _ads = TextEditingController(text: entry?.ads.join('\n') ?? '');
    final rules = entry?.hlsRules ?? const <Map<String, Object?>>[];
    _rules = TextEditingController(
      text: rules.isEmpty
          ? ''
          : const JsonEncoder.withIndent('  ').convert(rules),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _ads.dispose();
    _rules.dispose();
    super.dispose();
  }

  List<String> _parsedAds() => [
    for (final line in _ads.text.split(RegExp(r'\r?\n')))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  void _save() {
    final validation = validateHlsRulesJson(_rules.text);
    if (validation.hasRejections) {
      setState(() => _pending = validation);
      return;
    }
    _finish(validation);
  }

  void _finish(HlsRuleValidation validation) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = widget.entry;
    Navigator.of(context).pop(
      AdRuleEntry(
        id: existing?.id ?? 'user-$now',
        name: _name.text.trim(),
        enabled: existing?.enabled ?? true,
        ads: _parsedAds(),
        hlsRules: validation.rules,
        source: existing?.source ?? kAdRuleSourceUser,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.entry != null;
    final pending = _pending;
    final rejectionCount = pending?.reasons.length ?? 0;
    final rejectionText = pending?.reasons.join('\n') ?? '';
    return AlertDialog(
      title: Text(editing ? '编辑规则集' : '新增规则集'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey<String>('ad-rule-entry-name'),
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如：某站短视频广告',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey<String>('ad-rule-entry-ads'),
                controller: _ads,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '广告主机（每行一个）',
                  hintText: 'ad.example.com',
                  helperText: '写域名即可；命中该主机或其子域的请求会被拦下。',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey<String>('ad-rule-entry-hls'),
                controller: _rules,
                minLines: 5,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'HLS 规则 JSON（数组）',
                  hintText:
                      '[{"id":"rule-1","hostSuffixes":["ad.example.com"]}]',
                  helperText: '保存前逐条校验；无法生效的规则会被丢弃并列出原因。',
                ),
              ),
              if (pending != null) ...[
                const SizedBox(height: AppSpace.md),
                _NoticeBar(
                  message: '有 $rejectionCount 条规则无法生效：\n$rejectionText',
                  icon: Icons.error_outline,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        if (pending == null)
          FilledButton(onPressed: _save, child: const Text('保存'))
        else ...[
          TextButton(
            onPressed: () => setState(() => _pending = null),
            child: const Text('返回修改'),
          ),
          FilledButton(
            onPressed: () => _finish(pending),
            child: const Text('仍然保存'),
          ),
        ],
      ],
    );
  }
}

/// 导入 JSON 并当场展示 ImportReport。
class _AdRuleImportDialog extends StatefulWidget {
  const _AdRuleImportDialog({required this.store});

  final AdRuleLibraryStore store;

  @override
  State<_AdRuleImportDialog> createState() => _AdRuleImportDialogState();
}

class _AdRuleImportDialogState extends State<_AdRuleImportDialog> {
  final TextEditingController _text = TextEditingController();
  ImportReport? _report;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _run() {
    setState(() {
      _report = widget.store.importJson(
        _text.text,
        source: kAdRuleSourceImported,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report;
    return AlertDialog(
      title: const Text('导入规则 JSON'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey<String>('ad-rule-import-text'),
                controller: _text,
                minLines: 6,
                maxLines: 12,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: '粘贴 JSON',
                  hintText:
                      '可以是 {"entries":[…]}、[…规则集] 或单个规则集对象；'
                      '与库里相同的条目会被更新而不是重复添加。',
                ),
              ),
              if (report != null) ...[
                const SizedBox(height: AppSpace.md),
                Text(
                  report.summary,
                  key: const ValueKey<String>('ad-rule-import-summary'),
                ),
                if (report.reasons.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.sm),
                  for (final reason in report.reasons)
                    Text(
                      '· $reason',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton(onPressed: _run, child: const Text('导入')),
      ],
    );
  }
}

/// 样本清单预览：只读，结果不落盘。
class _AdRulePreviewDialog extends StatefulWidget {
  const _AdRulePreviewDialog({
    required this.rules,
    required this.playbackRules,
  });

  final AdRuleSet Function() rules;

  /// true = rules() 来自 AppState 的播放期解析（含配置内联规则与总开关）。
  final bool playbackRules;

  @override
  State<_AdRulePreviewDialog> createState() => _AdRulePreviewDialogState();
}

class _AdRulePreviewDialogState extends State<_AdRulePreviewDialog> {
  final TextEditingController _url = TextEditingController(
    text: 'https://media.example.com/live/index.m3u8',
  );
  final TextEditingController _text = TextEditingController(
    text: _samplePlaylist,
  );
  HlsCleanResult? _result;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _text.dispose();
    super.dispose();
  }

  void _run() {
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() {
        _error = '清单地址不是合法 URL';
        _result = null;
      });
      return;
    }
    setState(() {
      _error = null;
      _result = cleanHlsPlaylist(
        text: _text.text,
        playlistUri: uri,
        rules: widget.rules(),
      );
    });
  }

  /// 剩余段数：媒体清单里非空、非 '#' 开头的行就是分片地址。
  int _segmentCount(String text) {
    var count = 0;
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      count += 1;
    }
    return count;
  }

  String _countLabel(MapEntry<String, int> item) {
    final ruleId = item.key;
    final count = item.value;
    return '$ruleId × $count';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    final error = _error;
    final removed = result?.removedSegments ?? 0;
    final removedSeconds = (result?.removedDurationSec ?? 0).toStringAsFixed(1);
    final remaining = result == null ? 0 : _segmentCount(result.text);
    final hits = result == null
        ? ''
        : result.ruleCounts.entries.map(_countLabel).join('、');
    final abandonReason = result?.abandonReason;
    return AlertDialog(
      title: const Text('样本预览'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _NoticeBar(
                message: widget.playbackRules
                    ? '预览口径：当前播放期生效规则（含站点配置内联规则与广告过滤总开关）'
                    : '预览口径：仅按规则库预览，不代表播放期生效规则'
                          '（未含站点配置内联规则，也未考虑广告过滤总开关）',
                icon: widget.playbackRules
                    ? Icons.verified_outlined
                    : Icons.info_outline,
                tone: widget.playbackRules
                    ? _NoticeTone.info
                    : _NoticeTone.error,
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey<String>('ad-rule-preview-url'),
                controller: _url,
                decoration: const InputDecoration(
                  labelText: '清单地址',
                  helperText: '用于解析相对分片与判断跨域，不会真的发起请求。',
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey<String>('ad-rule-preview-text'),
                controller: _text,
                minLines: 6,
                maxLines: 12,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(labelText: 'm3u8 文本'),
              ),
              if (error != null) ...[
                const SizedBox(height: AppSpace.md),
                _NoticeBar(message: error, icon: Icons.error_outline),
              ],
              if (result != null) ...[
                const SizedBox(height: AppSpace.md),
                Text(
                  '删除 $removed 段，合计 $removedSeconds 秒；剩余 $remaining 段。',
                  key: const ValueKey<String>('ad-rule-preview-summary'),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpace.sm),
                if (result.ruleCounts.isEmpty)
                  Text(
                    '没有规则命中：核对清单主机范围（playlistHostSuffixes），'
                    '或检查规则是否被停用。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  Text(
                    '命中规则：$hits',
                    key: const ValueKey<String>('ad-rule-preview-rules'),
                    style: theme.textTheme.bodySmall,
                  ),
                if (abandonReason != null) ...[
                  const SizedBox(height: AppSpace.sm),
                  _NoticeBar(
                    message: '已放弃清洗：$abandonReason',
                    icon: Icons.warning_amber_rounded,
                  ),
                ],
                const SizedBox(height: AppSpace.md),
                Container(
                  constraints: const BoxConstraints(maxHeight: 160),
                  padding: const EdgeInsets.all(AppSpace.sm),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: AppRadius.smAll,
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      result.text,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton(onPressed: _run, child: const Text('运行预览')),
      ],
    );
  }
}
