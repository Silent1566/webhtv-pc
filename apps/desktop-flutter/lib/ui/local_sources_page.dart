/// 本地爬虫源管理页：扫描文件夹 → 预览勾选 → 导入 → 长期保留。
///
/// 与安卓「增强功能 → 站点注入」的关系：形态对齐（本地源 + 启停 + 删除），
/// 但交互按桌面重做——左侧先选文件夹（原生目录选择器或手输），扫描出候选后
/// **逐条预览**（类型、大小、最后修改时间、警告），可全选/取消全选后批量导入；
/// 已导入的源单独成区，可单独停用、打开或删除；也可以直接登记在线 HTML 网址。
///
/// 安全约定（页面上必须如实可见）：
/// - 扫描**不执行**任何文件，只读字节与文本特征；
/// - 登记在线网址**不联网、不下载**，打开时才由内嵌浏览器加载；
/// - 导入后 Python/JS 源在独立 sidecar 中运行，HTML 源在 WebView2 中运行，
///   都不是沙箱；来源与路径对用户可见；
/// - 同名 key 一律拒绝导入，避免覆盖既有源。
///
/// 时间语义：候选区显示**原文件最后修改时间**（`File.lastModified`）；已导入的
/// 本地 HTML 显示导入时保存的原文件时间；在线 HTML 没有本地文件时间，一律显示
/// 「更新时间：未知」——绝不用导入时间冒充文件修改时间。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/local_source_import.dart';
import '../services/local_spider_scanner.dart';
import '../services/web_home_store.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'settings_layout.dart';
import 'tokens.dart';
import 'web_home_page.dart';

/// 本地时区的 `yyyy-MM-dd HH:mm`；候选与已导入源共用同一种时间写法。
String formatLocalTimestamp(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year.toString().padLeft(4, '0')}-${two(value.month)}-'
      '${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}

class LocalSourcesPage extends StatefulWidget {
  const LocalSourcesPage({super.key, required this.state});

  final AppState state;

  @override
  State<LocalSourcesPage> createState() => _LocalSourcesPageState();
}

class _LocalSourcesPageState extends State<LocalSourcesPage> {
  final TextEditingController _folderController = TextEditingController();
  final TextEditingController _onlineUrlController = TextEditingController();
  final TextEditingController _onlineNameController = TextEditingController();
  final Set<String> _selected = <String>{};

  LocalScanReport? _report;
  LocalImportResult? _result;
  bool _busy = false;
  bool _newestFirst = true;
  String _busyNote = '';
  String? _message;
  String? _urlError;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    final last = _state.lastLocalScanFolder;
    if (last.isNotEmpty) _folderController.text = last;
  }

  @override
  void dispose() {
    _folderController.dispose();
    _onlineUrlController.dispose();
    _onlineNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    List<WebHomeSource>? webHome;
    String? webHomeError;
    try {
      webHome = _state.webHomeSources;
    } catch (error) {
      webHomeError = '载入 HTML 源失败：$error';
    }
    // 只列本地导入的（`spiders/local/`）；远端直连源在 Spider 页统一展示。
    final localRoot = p.join(_state.spiderRoot, 'local');
    final localSpiders = _state.localSpiders
        .where((spider) => spider.rootDir.startsWith(localRoot))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('本地爬虫源'),
        actions: [
          IconButton(
            key: const ValueKey('local-sources-rescan'),
            tooltip: '重新载入已导入源',
            icon: const Icon(Icons.restart_alt),
            onPressed: _busy ? null : _reload,
          ),
        ],
      ),
      body: ListView(
        padding: formPagePadding(context),
        children: [
          SettingsSection(
            title: '扫描文件夹',
            description:
                '本地文件导入仅支持 Windows。支持 .py / .js / .html。扫描只读取文件，不执行任何脚本；'
                '导入后 Python 与 JavaScript 源在独立进程运行，HTML 源在内嵌浏览器中运行。',
            children: [
              TextField(
                key: const ValueKey('local-sources-folder'),
                controller: _folderController,
                decoration: InputDecoration(
                  labelText: '扫描文件夹',
                  hintText: r'例如 D:\spiders',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    key: const ValueKey('local-sources-pick'),
                    tooltip: '选择文件夹',
                    icon: const Icon(Icons.folder_open),
                    onPressed: _busy ? null : _pickFolder,
                  ),
                ),
                onSubmitted: (_) => _scan(),
              ),
              const SizedBox(height: AppSpace.md),
              SettingsActions(
                children: [
                  FilledButton.icon(
                    key: const ValueKey('local-sources-scan'),
                    onPressed: _busy ? null : _scan,
                    icon: const Icon(Icons.search),
                    label: const Text('扫描'),
                  ),
                  if (_selected.isNotEmpty)
                    FilledButton.tonalIcon(
                      key: const ValueKey('local-sources-import'),
                      onPressed: _busy ? null : _import,
                      icon: const Icon(Icons.download_done),
                      label: Text('导入所选（${_selected.length}）'),
                    ),
                ],
              ),
              if (_busy) ...[
                const SizedBox(height: AppSpace.sm),
                Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(_busyNote),
                  ],
                ),
              ],
              if (_message != null) ...[
                const SizedBox(height: AppSpace.sm),
                Text(_message!, key: const ValueKey('local-sources-message')),
              ],
            ],
          ),
          if (_report != null) ...[
            const Divider(height: AppSpace.xl),
            _buildCandidates(context),
          ],
          const Divider(height: AppSpace.xl),
          SettingsSection(
            title: '添加在线 HTML 网址',
            description:
                '只登记网址，添加时不联网、不下载、不执行任何脚本；'
                '打开时才由内嵌浏览器加载该页面。',
            children: [
              TextField(
                key: const ValueKey('online-html-url'),
                controller: _onlineUrlController,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: '网页地址',
                  hintText: 'https://example.com/page',
                  border: const OutlineInputBorder(),
                  errorText: _urlError,
                ),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const ValueKey('online-html-name'),
                controller: _onlineNameController,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '名称（可选）',
                  hintText: '留空则用网址本身命名',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              SettingsActions(
                children: [
                  FilledButton.icon(
                    key: const ValueKey('online-html-add'),
                    onPressed: _busy ? null : _addOnline,
                    icon: const Icon(Icons.add_link),
                    label: const Text('添加'),
                  ),
                ],
              ),
            ],
          ),
          const Divider(height: AppSpace.xl),
          SettingsSection(
            title: '已导入的本地源',
            description:
                'HTML 源可在此打开或停用；Python / JavaScript 源在「Spider」页查看运行状态。',
            children: [
              if (webHomeError != null)
                Text(webHomeError, key: const ValueKey('webhome-load-error')),
              if (webHome != null && webHome.isEmpty && localSpiders.isEmpty)
                const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: '还没有本地源',
                  message: '选一个文件夹扫描，勾选后点「导入所选」。',
                ),
              for (final source in webHome ?? const <WebHomeSource>[])
                ListTile(
                  key: ValueKey('webhome-row-${source.key}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    source.enabled
                        ? Icons.web_asset
                        : Icons.web_asset_off_outlined,
                  ),
                  title: Text(source.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.isRemote
                            ? '${source.key} · 在线 HTML'
                            : '${source.key} · HTML 首页 · 入口 ${source.entry}',
                      ),
                      Text(
                        source.isRemote
                            ? source.remoteUrl
                            : '本地文件：${source.entry}',
                        key: ValueKey('webhome-origin-${source.key}'),
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _webHomeTimeLabel(source),
                        key: ValueKey('webhome-time-${source.key}'),
                        style: tabular(theme.textTheme.bodySmall!),
                      ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: ValueKey('webhome-open-${source.key}'),
                        onPressed: source.enabled
                            ? () => _openWebHome(source)
                            : null,
                        child: const Text('打开'),
                      ),
                      Switch(
                        key: ValueKey('webhome-toggle-${source.key}'),
                        value: source.enabled,
                        onChanged: _busy
                            ? null
                            : (value) => _setWebHomeEnabled(source, value),
                      ),
                      IconButton(
                        key: ValueKey('webhome-remove-${source.key}'),
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _busy ? null : () => _removeWebHome(source),
                      ),
                    ],
                  ),
                ),
              for (final spider in localSpiders)
                ListTile(
                  key: ValueKey('localspider-row-${spider.key}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.extension_outlined),
                  title: Text(spider.manifest.name),
                  subtitle: Text(
                    '${spider.key} · ${spider.manifest.runtime} · '
                    '${spider.manifest.entry}',
                  ),
                  trailing: IconButton(
                    key: ValueKey('local-remove-${spider.key}'),
                    tooltip: '删除本地源',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy
                        ? null
                        : () => _removeLocalSpider(
                            spider.key,
                            spider.manifest.name,
                          ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          Text(
            '说明：本地源与远端直连源共用同一套 Spider 运行时；'
            'HTML 源依赖 Microsoft Edge WebView2 运行时。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildCandidates(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report!;
    return SettingsSection(
      title: '扫描结果（${report.candidates.length} 个候选）',
      description: report.folder,
      children: [
        if (report.truncated)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpace.sm),
            child: Text('候选已达上限，部分文件未列出；请缩小文件夹范围。'),
          ),
        if (report.candidates.isNotEmpty) _buildSelectionHeader(context),
        for (final candidate in _orderedCandidates)
          CheckboxListTile(
            key: ValueKey('candidate-${candidate.key}'),
            value: _selected.contains(candidate.absPath),
            onChanged: _busy
                ? null
                : (value) {
                    setState(() {
                      if (value ?? false) {
                        _selected.add(candidate.absPath);
                      } else {
                        _selected.remove(candidate.absPath);
                      }
                    });
                  },
            contentPadding: EdgeInsets.zero,
            title: Text('${candidate.name}（${candidate.key}）'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${candidate.kind.label} · '
                  '${(candidate.bytes / 1024).toStringAsFixed(1)} KiB · '
                  'runtime=${candidate.suggestedRuntime}',
                ),
                Text(
                  '最后修改：${formatLocalTimestamp(candidate.modified)}',
                  key: ValueKey('candidate-modified-${candidate.key}'),
                  style: tabular(theme.textTheme.bodySmall!)
                      .copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                for (final warning in candidate.warnings)
                  Text(
                    '⚠ $warning',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.statusDegraded,
                    ),
                  ),
                Text(
                  candidate.absPath,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            isThreeLine: true,
          ),
        if (report.skipped.isNotEmpty)
          ExpansionTile(
            key: const ValueKey('local-sources-skipped'),
            tilePadding: EdgeInsets.zero,
            title: Text('已跳过 ${report.skipped.length} 项'),
            children: [
              for (final item in report.skipped)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(item),
                ),
            ],
          ),
        if (_result != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '导入结果：成功 ${_result!.importedCount}，'
                  '失败 ${_result!.rejectedCount}',
                  key: const ValueKey('local-sources-result'),
                ),
                for (final outcome in _result!.outcomes)
                  Text(
                    '${outcome.ok ? '✓' : '✗'} ${outcome.key}：${outcome.message}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// 全选/取消全选 + 选择计数 + 排序方向。只作用于**当前报告**里的候选。
  Widget _buildSelectionHeader(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report!;
    final total = report.candidates.length;
    final all = report.candidates.every(
      (candidate) => _selected.contains(candidate.absPath),
    );
    final none = report.candidates.every(
      (candidate) => !_selected.contains(candidate.absPath),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: CheckboxListTile(
                key: const ValueKey('local-sources-select-all'),
                // 部分选择时显示中间态；点一下清空当前选择。
                value: all
                    ? true
                    : none
                    ? false
                    : null,
                tristate: true,
                onChanged: _busy ? null : (value) => _selectAll(value == true),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: const Text('全选当前扫描结果'),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('local-sources-sort-toggle'),
              onPressed: _busy
                  ? null
                  : () => setState(() => _newestFirst = !_newestFirst),
              icon: const Icon(Icons.swap_vert),
              label: Text(_newestFirst ? '最新优先' : '默认顺序'),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpace.xs,
            bottom: AppSpace.sm,
          ),
          child: Text(
            '已选 ${_selected.length} / $total',
            key: const ValueKey('local-sources-selection-count'),
            style: tabular(theme.textTheme.bodySmall!)
                .copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// 默认「最新优先」按原文件修改时间降序，时间相同按报告原顺序（稳定）；
  /// 切到「默认顺序」即扫描报告自身的顺序。
  List<LocalSourceCandidate> get _orderedCandidates {
    final report = _report;
    if (report == null) return const [];
    final indexed = report.candidates.indexed.toList();
    indexed.sort((a, b) {
      if (_newestFirst) {
        final byTime = b.$2.modified.compareTo(a.$2.modified);
        if (byTime != 0) return byTime;
      }
      return a.$1.compareTo(b.$1);
    });
    return indexed.map((entry) => entry.$2).toList(growable: false);
  }

  String _webHomeTimeLabel(WebHomeSource source) {
    // 在线源没有本地文件时间，导入时间不是"更新时间"——必须显示未知。
    if (source.isRemote) return '更新时间：未知';
    final modified = DateTime.tryParse(source.modifiedAt);
    if (modified == null) return '原文件修改时间：未知';
    return '原文件修改时间：${formatLocalTimestamp(modified.toLocal())}';
  }

  void _selectAll(bool select) {
    final report = _report;
    if (report == null) return;
    setState(() {
      if (select) {
        _selected.addAll(
          report.candidates.map((candidate) => candidate.absPath),
        );
      } else {
        _selected.clear();
      }
    });
  }

  Future<void> _pickFolder() async {
    try {
      final picked = await FilePicker.getDirectoryPath(
        dialogTitle: '选择包含爬虫源的文件夹',
      );
      if (picked == null || picked.isEmpty) return;
      if (!mounted) return;
      setState(() => _folderController.text = picked);
      await _scan();
    } catch (error) {
      if (mounted) setState(() => _message = '无法打开目录选择器：$error');
    }
  }

  Future<void> _scan() async {
    if (_busy) return;
    final folder = _folderController.text.trim();
    if (folder.isEmpty) {
      setState(() => _message = '请先选择或输入文件夹路径');
      return;
    }
    setState(() {
      _busy = true;
      _busyNote = '正在扫描（不执行任何文件）…';
      _message = null;
      _result = null;
      // 重扫即换了一批候选：上一轮的勾选一律作废，避免旧选择带到新报告。
      _selected.clear();
    });
    try {
      final report = await _state.scanLocalSources(folder);
      if (!mounted) return;
      setState(() {
        _report = report;
        _message = report.isEmpty ? '没有找到可导入的源（支持 .py / .js / .html）' : null;
      });
    } catch (error) {
      if (mounted) setState(() => _message = '扫描失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final report = _report;
    if (report == null || _selected.isEmpty) return;
    final picked = report.candidates
        .where((candidate) => _selected.contains(candidate.absPath))
        .toList();
    setState(() {
      _busy = true;
      _busyNote = '正在导入…';
    });
    try {
      final result = await _state.importLocalSources(picked);
      if (!mounted) return;
      setState(() {
        _result = result;
        _selected.clear();
        _message = null;
      });
    } catch (error) {
      if (mounted) setState(() => _message = '导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _busyNote = '正在重新载入已导入源…';
    });
    try {
      await _state.reloadLocalSources();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => _message = '重新载入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 登记一个在线 HTML 网址：只做地址校验与登记，**不联网、不执行**任何内容。
  Future<void> _addOnline() async {
    final raw = _onlineUrlController.text.trim();
    final name = _onlineNameController.text.trim();
    final uri = Uri.tryParse(raw);
    final valid =
        uri != null &&
        (uri.isScheme('http') || uri.isScheme('https')) &&
        uri.host.isNotEmpty;
    if (!valid) {
      setState(() {
        _urlError = '请输入以 http:// 或 https:// 开头的有效网址';
        _message = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _busyNote = '正在登记在线地址（不联网）…';
      _urlError = null;
      _message = null;
    });
    try {
      await _state.addOnlineWebHome(raw, name: name.isEmpty ? null : name);
      if (!mounted) return;
      setState(() {
        _onlineUrlController.clear();
        _onlineNameController.clear();
        _message = '已添加在线 HTML：$raw';
      });
    } catch (error) {
      // 失败必须如实展示具体原因，绝不改写成成功。
      if (mounted) setState(() => _message = '添加失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openWebHome(WebHomeSource source) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebHomePage(state: _state, source: source),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _removeLocalSpider(String key, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地源'),
        content: Text(
          '确定删除「$name」？将永久删除本地源目录及其中的文件。'
          '如源仍在运行，请先在「Spider」页停止。',
        ),
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
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _busyNote = '正在删除本地源…';
      _message = null;
    });
    try {
      final ok = await _state.removeLocalSpider(key);
      if (mounted) {
        setState(() {
          if (!ok) {
            _message =
                '删除本地源失败：源不存在、目录不安全或仍在运行。'
                '如源仍在运行，请先在「Spider」页停止后重试。';
          }
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = '删除本地源失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setWebHomeEnabled(WebHomeSource source, bool enabled) async {
    setState(() {
      _busy = true;
      _busyNote = '正在更新启用状态…';
      _message = null;
    });
    try {
      final ok = await _state.setWebHomeEnabled(source.key, enabled);
      if (mounted) {
        setState(() {
          if (!ok) _message = '更新启用状态失败：源不存在或未能保存';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = '更新启用状态失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeWebHome(WebHomeSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地源'),
        content: Text(
          source.isRemote
              ? '确定删除「${source.name}」？只移除网址登记，不会删除本地文件。'
              : '确定删除「${source.name}」？其目录会被一并清除。',
        ),
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
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _busyNote = '正在删除源…';
      _message = null;
    });
    try {
      final ok = await _state.removeWebHome(source.key);
      if (mounted) {
        setState(() {
          if (!ok) _message = '删除失败：源不存在或未能移除';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = '删除失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
