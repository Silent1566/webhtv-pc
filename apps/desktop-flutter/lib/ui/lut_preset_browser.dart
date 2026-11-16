/// LUT 预设浏览器（内置 / 我的 / 在线）。
///
/// 一个组件，两个壳：
/// - 播放中的底部面板（LutPickerSheet）——选完就 pop，不离开画面；
/// - 设置里的三级明细页（LutPresetsPage）——选完就地保存，页面不关。
///
/// 为什么抽出来：三段式内容有 300 多行，抄两份必然分叉（改一处忘一处，
/// 典型结果是「面板能搜、设置页搜不到」）。差异只留在**回调**上：
/// 面板回传结果，页面直接落库。
///
/// 刻意**不自带滚动**：外层是底部面板还是设置页的 ListView 由宿主决定。
/// 自己套 ListView 会和设置页的 formPagePadding 打架（双滚动 + 宽度不居中）。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/lut.dart';
import '../services/lut_store.dart';

/// 浏览器本体。
class LutPresetBrowser extends StatefulWidget {
  const LutPresetBrowser({
    super.key,
    required this.store,
    required this.currentPath,
    required this.currentPresetId,
    required this.onSelect,
    this.onCleared,
    this.pickFile,
    this.showHeader = true,
  });

  final LutStore store;

  /// 当前生效的 LUT 磁盘路径（空串表示未启用）。
  final String currentPath;

  /// 当前生效的内置预设 id（空串表示选的是用户文件）。
  final String currentPresetId;

  /// 选中一项。内置项是「待落盘」的预设，用户项已是磁盘文件。
  final ValueChanged<LutPreset> onSelect;

  /// 清除当前 LUT；为 null 时不显示清除入口。
  final VoidCallback? onCleared;

  /// 注入文件选择器，便于测试；默认走 FilePicker.pickFile。
  final Future<String?> Function()? pickFile;

  /// 面板里需要标题；明细页的标题在 AppBar，正文不再重复。
  final bool showHeader;

  @override
  State<LutPresetBrowser> createState() => _LutPresetBrowserState();
}

class _LutPresetBrowserState extends State<LutPresetBrowser> {
  final TextEditingController _query = TextEditingController();

  List<LutPreset> _userPresets = const <LutPreset>[];
  bool _loadingUser = true;

  String? _busy;
  String? _error;

  List<LutRepoHit> _repos = const <LutRepoHit>[];
  LutRepoHit? _repo;
  List<String> _cubePaths = const <String>[];

  @override
  void initState() {
    super.initState();
    _loadUserPresets();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _isCurrent(LutPreset preset) {
    if (preset.isBundled) return preset.id == widget.currentPresetId;
    return preset.path == widget.currentPath;
  }

  Future<void> _loadUserPresets() async {
    try {
      final presets = await widget.store.listUserPresets();
      if (!mounted) return;
      setState(() {
        _userPresets = presets;
        _loadingUser = false;
      });
    } on LutStoreException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingUser = false;
        _error = error.message;
      });
    }
  }

  Future<void> _importFile() async {
    String? path;
    try {
      if (widget.pickFile != null) {
        path = await widget.pickFile!();
      } else {
        final picked = await FilePicker.pickFile(
          dialogTitle: '选择 LUT 文件',
          type: FileType.custom,
          allowedExtensions: const ['cube'],
        );
        path = picked?.path;
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '选择文件失败：$error');
      return;
    }
    if (path == null || path.trim().isEmpty || !mounted) return;
    final source = path;
    await _run('正在导入…', () async {
      final preset = await widget.store.importFile(source);
      if (!mounted) return;
      widget.onSelect(preset);
    });
  }

  Future<void> _deletePreset(LutPreset preset) async {
    await _run('正在删除…', () async {
      await widget.store.deleteUserPreset(preset);
      await _loadUserPresets();
    });
  }

  Future<void> _searchOnline() async {
    final query = _query.text.trim();
    await _run('正在搜索…', () async {
      final hits = await widget.store.searchRepositories(query);
      if (!mounted) return;
      setState(() {
        _repos = hits;
        _repo = null;
        _cubePaths = const <String>[];
        if (hits.isEmpty) _error = '没有找到带 .cube 的仓库，换个关键词试试';
      });
    });
  }

  Future<void> _openRepo(LutRepoHit hit) async {
    await _run('正在列出文件…', () async {
      final paths = await widget.store.listCubePaths(hit);
      if (!mounted) return;
      setState(() {
        _repo = hit;
        _cubePaths = paths;
        if (paths.isEmpty) _error = '${hit.fullName} 里没有 .cube 文件';
      });
    });
  }

  Future<void> _downloadFromRepo(LutRepoHit hit, String path) async {
    await _run('正在下载…', () async {
      final preset = await widget.store.downloadFromRepo(hit, path);
      if (!mounted) return;
      widget.onSelect(preset);
    });
  }

  Future<void> _importFromUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从链接导入 LUT'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'https://…/something.cube',
            helperText: '直接下载并校验，最多 8 MiB',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('下载'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.trim().isEmpty || !mounted) return;
    await _run('正在下载…', () async {
      final preset = await widget.store.download(url);
      if (!mounted) return;
      widget.onSelect(preset);
    });
  }

  /// 统一处理「忙 / 错」状态，避免每个入口重复一遍 try/catch。
  Future<void> _run(String label, Future<void> Function() action) async {
    if (!mounted) return;
    setState(() {
      _busy = label;
      _error = null;
    });
    try {
      await action();
    } on LutStoreException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '出错了：$error');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader) _header(context),
        if (_busy != null) const LinearProgressIndicator(minHeight: 2),
        if (_error != null) _errorBanner(context),
        ..._sections(context),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('LUT 滤镜', style: theme.textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(
            _busy ?? '只支持 3D .cube；由 mpv 的 lut3d 滤镜应用',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _busy == null ? null : theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            onPressed: () => setState(() => _error = null),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final canAct = _busy == null;
    return <Widget>[
      if (widget.currentPath.isNotEmpty && widget.onCleared != null)
        ListTile(
          leading: const Icon(Icons.clear),
          title: const Text('清除 LUT'),
          subtitle: Text(
            widget.currentPath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: canAct ? widget.onCleared : null,
        ),
      _sectionTitle(context, '内置预设'),
      for (final preset in builtinLutPresets)
        ListTile(
          dense: true,
          key: ValueKey('lut-browser-builtin-${preset.id}'),
          leading: Icon(
            _isCurrent(preset) ? Icons.check_circle : Icons.palette_outlined,
            color: _isCurrent(preset)
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          title: Text(preset.name),
          trailing: Text(preset.sizeLabel),
          onTap: canAct ? () => widget.onSelect(preset) : null,
        ),
      _sectionTitle(context, '我的 LUT'),
      ListTile(
        dense: true,
        leading: const Icon(Icons.add),
        title: const Text('导入 .cube 文件…'),
        enabled: canAct,
        onTap: _importFile,
      ),
      if (_loadingUser)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('正在扫描本地目录…'),
        )
      else if (_userPresets.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('还没有导入过 LUT'),
        )
      else
        for (final preset in _userPresets)
          ListTile(
            dense: true,
            key: ValueKey('lut-browser-user-${preset.id}'),
            leading: Icon(
              _isCurrent(preset)
                  ? Icons.check_circle
                  : Icons.movie_filter_outlined,
              color: _isCurrent(preset)
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: Text(preset.name),
            subtitle: Text(
              preset.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: canAct ? () => _deletePreset(preset) : null,
            ),
            onTap: canAct ? () => widget.onSelect(preset) : null,
          ),
      ..._onlineSection(context),
    ];
  }

  List<Widget> _onlineSection(BuildContext context) {
    final canAct = _busy == null;
    return <Widget>[
      _sectionTitle(context, '在线'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _query,
                enabled: canAct,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '关键词，例如 film / cyberpunk',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _searchOnline(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: canAct ? _searchOnline : null,
              child: const Text('搜索'),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          '搜索走 GitHub 公开接口（无需登录，未授权额度 60 次/小时）。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      ListTile(
        dense: true,
        leading: const Icon(Icons.link),
        title: const Text('从链接导入…'),
        subtitle: const Text('粘贴任意 .cube 直链'),
        enabled: canAct,
        onTap: _importFromUrl,
      ),
      if (_repo != null) ..._cubeList(context) else ..._repoList(context),
    ];
  }

  List<Widget> _repoList(BuildContext context) {
    final canAct = _busy == null;
    if (_repos.isEmpty) return const <Widget>[];
    return <Widget>[
      for (final hit in _repos)
        ListTile(
          dense: true,
          leading: const Icon(Icons.folder_outlined),
          title: Text(hit.fullName),
          subtitle: Text(
            hit.subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: canAct ? () => _openRepo(hit) : null,
        ),
    ];
  }

  List<Widget> _cubeList(BuildContext context) {
    final canAct = _busy == null;
    final repo = _repo!;
    return <Widget>[
      ListTile(
        dense: true,
        leading: const Icon(Icons.arrow_back),
        title: Text('返回搜索（${repo.fullName}）'),
        onTap: canAct ? () => setState(() => _repo = null) : null,
      ),
      if (_cubePaths.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('这个仓库里没有 .cube'),
        )
      else
        for (final path in _cubePaths)
          ListTile(
            dense: true,
            leading: const Icon(Icons.download_outlined),
            title: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: canAct ? () => _downloadFromRepo(repo, path) : null,
          ),
    ];
  }

  Widget _sectionTitle(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
