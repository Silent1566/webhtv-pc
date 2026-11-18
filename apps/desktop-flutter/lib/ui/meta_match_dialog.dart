/// 通用「匹配元数据」对话框：TMDB / 豆瓣 / Bangumi 三来源检索，选一条即生效。
///
/// 为什么合并成一个入口：用户的心智是「这条数据不对，我自己指定」，
/// 而不是「我要用哪家的接口去指定」。三家的结论落在各自既有的存储里
/// （TMDB → `TmdbMatchRecord`，外部 → `MetaOverrideStore`），对话框不关心差别。
library;

import 'package:flutter/material.dart';

import '../core/external_meta.dart';
import '../core/meta_source.dart';
import '../core/protocol.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_title.dart';
import '../state/app_state.dart';

class MetaMatchDialog extends StatefulWidget {
  const MetaMatchDialog({
    super.key,
    required this.state,
    required this.vod,
    this.tmdbSearch,
    this.onPickTmdb,
  });

  final AppState state;
  final Vod vod;

  /// TMDB 搜索（未配置时传 null：TMDB 分段置灰）。
  final Future<List<TmdbItem>> Function(String keyword)? tmdbSearch;
  final void Function(TmdbItem item)? onPickTmdb;

  @override
  State<MetaMatchDialog> createState() => _MetaMatchDialogState();
}

class _MetaMatchDialogState extends State<MetaMatchDialog> {
  MetaSourceKind _source = MetaSourceKind.douban;
  late final TextEditingController _query = TextEditingController(
    text: widget.vod.vodName,
  );
  List<MetaCandidate> _external = const [];
  List<TmdbItem> _tmdb = const [];
  bool _busy = false;
  String? _hint;

  bool get _tmdbAvailable => widget.tmdbSearch != null;

  @override
  void initState() {
    super.initState();
    // 有 TMDB 就先给 TMDB：它是原有主源，用户从旧按钮过来时预期一致。
    _source = _tmdbAvailable ? MetaSourceKind.tmdb : MetaSourceKind.douban;
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  MetaQuery get _metaQuery => MetaQuery(
    title: _query.text.trim(),
    year: firstYear(widget.vod.vodYear ?? ''),
    isTv: !'${widget.vod.extra['type_name'] ?? ''}'.contains('电影'),
  );

  Future<void> _search() async {
    final title = _query.text.trim();
    if (title.isEmpty) return;
    setState(() {
      _busy = true;
      _hint = null;
      _external = const [];
      _tmdb = const [];
    });
    if (_source == MetaSourceKind.tmdb) {
      final search = widget.tmdbSearch;
      final results = search == null ? const <TmdbItem>[] : await search(title);
      if (!mounted) return;
      setState(() {
        _tmdb = results;
        _busy = false;
        _hint = results.isEmpty ? 'TMDB 没有找到候选' : null;
      });
      return;
    }
    final results = await widget.state.externalMetaService.candidates(
      _metaQuery,
      _source,
    );
    if (!mounted) return;
    setState(() {
      _external = results;
      _busy = false;
      _hint = results.isEmpty ? '没有找到候选，换个关键词试试' : null;
    });
  }

  Future<void> _pickExternal(MetaCandidate candidate) async {
    final saved = await widget.state.pinMetaOverride(
      widget.vod.vodId,
      candidate.identity,
    );
    if (!mounted) return;
    Navigator.of(context).pop(saved);
  }

  Future<void> _reset() async {
    await widget.state.unpinMetaOverride(widget.vod.vodId);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pinned = widget.state.metaOverrides.of(widget.vod.vodId);
    final rows = _source == MetaSourceKind.tmdb
        ? _tmdb
              .map((item) => _RowData(
                key: 'tmdb-${item.tmdbId}',
                title: item.title,
                subtitle: item.subtitle,
                pick: () {
                  widget.onPickTmdb?.call(item);
                  Navigator.of(context).pop(true);
                },
              ))
              .toList()
        : _external
              .map((candidate) => _RowData(
                key: candidate.identity.key,
                title: candidate.title,
                subtitle: candidate.subtitleForList,
                pick: () => _pickExternal(candidate),
              ))
              .toList();
    return AlertDialog(
      title: const Text('匹配元数据'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final source in const [
                  MetaSourceKind.tmdb,
                  MetaSourceKind.douban,
                  MetaSourceKind.bangumi,
                ])
                  ChoiceChip(
                    key: ValueKey('meta-match-source-${source.key}'),
                    label: Text(
                      source == MetaSourceKind.tmdb && !_tmdbAvailable
                          ? '${source.label}（未配置）'
                          : source.label,
                    ),
                    selected: _source == source,
                    onSelected: source == MetaSourceKind.tmdb && !_tmdbAvailable
                        ? null
                        : (_) => setState(() {
                            _source = source;
                            _external = const [];
                            _tmdb = const [];
                            _hint = null;
                          }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('meta-match-query'),
                    controller: _query,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      labelText: '片名',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('meta-match-search'),
                  onPressed: _busy ? null : _search,
                  child: Text(_busy ? '搜索中…' : '搜索'),
                ),
              ],
            ),
            if (pinned != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '当前已钉住：${pinned.kind.label} ${pinned.id}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (_hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_hint!, style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                key: const ValueKey('meta-match-results'),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  return ListTile(
                    key: ValueKey('meta-match-result-${row.key}'),
                    dense: true,
                    title: Text(row.title),
                    subtitle: Text(row.subtitle),
                    trailing: TextButton(
                      key: ValueKey('meta-match-pick-${row.key}'),
                      onPressed: row.pick,
                      child: const Text('用这个'),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('meta-match-reset'),
          onPressed: _reset,
          child: const Text('恢复自动匹配'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _RowData {
  const _RowData({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.pick,
  });

  final String key;
  final String title;
  final String subtitle;
  final VoidCallback pick;
}