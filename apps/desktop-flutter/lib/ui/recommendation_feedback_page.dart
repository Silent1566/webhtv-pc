import 'dart:async';

import 'package:flutter/material.dart';

import '../services/recommendation_feedback_manager.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'settings_layout.dart';
import 'toast.dart';
import 'tokens.dart';

class RecommendationFeedbackPage extends StatefulWidget {
  const RecommendationFeedbackPage({super.key, required this.state});

  final AppState state;

  @override
  State<RecommendationFeedbackPage> createState() =>
      _RecommendationFeedbackPageState();
}

enum _MutationPhase { confirming, saving }

class _RecommendationFeedbackPageState
    extends State<RecommendationFeedbackPage> {
  late final RecommendationFeedbackManager _manager;
  var _kind = RecommendationFeedbackKind.watched;
  List<RecommendationFeedbackRecord> _records = const [];
  final _selected = <String>{};
  var _loadGeneration = 0;
  var _loading = true;
  var _loadFailed = false;
  _MutationPhase? _phase;

  bool get _canEdit => _phase == null && !_loading && !_loadFailed;

  String get _category => switch (_kind) {
    RecommendationFeedbackKind.watched => '已看',
    RecommendationFeedbackKind.notInterested => '不感兴趣',
  };

  @override
  void initState() {
    super.initState();
    final dependencies = widget.state.recommendationDependencies;
    _manager = RecommendationFeedbackManager(
      watched: dependencies.watched,
      feedback: dependencies.feedback,
      aiData: widget.state.aiIntegration.userData,
    );
    unawaited(_load(_kind));
  }

  Future<bool> _load(RecommendationFeedbackKind kind) async {
    final generation = ++_loadGeneration;
    try {
      final records = await _manager.load(kind);
      if (!mounted || generation != _loadGeneration) return false;
      setState(() {
        _records = records;
        _selected.retainAll(records.map((record) => record.id));
        _loading = false;
        _loadFailed = false;
      });
      return true;
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return false;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      return false;
    }
  }

  void _switchKind(Set<RecommendationFeedbackKind> selection) {
    final kind = selection.single;
    if (_phase != null || kind == _kind) return;
    setState(() {
      _kind = kind;
      _records = const [];
      _selected.clear();
      _loading = true;
      _loadFailed = false;
    });
    unawaited(_load(kind));
  }

  void _retryLoad() {
    setState(() => _loading = true);
    unawaited(_load(_kind));
  }

  Future<void> _confirmChange({required bool clear}) async {
    final count = clear ? _records.length : _selected.length;
    if (!_canEdit || count == 0) return;
    final ids = Set<String>.of(_selected);
    final kind = _kind;
    final category = _category;
    setState(() => _phase = _MutationPhase.confirming);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(clear ? '清空「$category」' : '删除推荐反馈'),
          content: Text(
            '将删除「$category」中'
            '${clear ? '全部' : '选中的'} $count 条推荐反馈。\n'
            '此操作不可撤销，不会影响播放历史。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(clear ? '清空' : '删除'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      setState(() => _phase = _MutationPhase.saving);
      var saved = false;
      try {
        saved = clear
            ? await _manager.clear(kind)
            : await _manager.remove(kind, ids);
      } catch (_) {
        // One store may have saved before the other failed. Always reload.
      }
      if (!mounted) return;
      final refreshed = await _load(kind);
      if (!mounted) return;
      if (!saved) {
        showToast(
          clear ? '未能清空「$category」' : '未能删除全部选中反馈',
          kind: ToastKind.error,
          detail: refreshed ? '已刷新列表，可重试删除剩余记录。' : '请重新加载列表后再试。',
        );
      } else if (!refreshed) {
        showToast('已保存更改，但无法刷新推荐反馈', kind: ToastKind.error);
      } else {
        showToast(
          clear ? '已清空「$category」' : '已删除 $count 条推荐反馈',
          kind: ToastKind.success,
        );
      }
    } finally {
      if (mounted) setState(() => _phase = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasRecords = _records.isNotEmpty;
    final allSelected = hasRecords && _selected.length == _records.length;
    final saving = _phase == _MutationPhase.saving;
    return PopScope(
      canPop: !saving,
      child: SettingsDetailScaffold(
        title: '推荐反馈',
        description: '管理用于推荐的本地记录。删除这些记录不会影响播放历史。',
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: SegmentedButton<RecommendationFeedbackKind>(
              segments: const [
                ButtonSegment(
                  value: RecommendationFeedbackKind.watched,
                  label: Text('已看'),
                ),
                ButtonSegment(
                  value: RecommendationFeedbackKind.notInterested,
                  label: Text('不感兴趣'),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: _phase == null ? _switchKind : null,
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          if (_loading)
            Semantics(
              liveRegion: true,
              child: const SettingsActions(
                children: [
                  LoadingBlock(size: 20, center: false),
                  Text('正在读取推荐反馈…'),
                ],
              ),
            )
          else if (_loadFailed)
            EmptyState(
              title: '无法读取推荐反馈',
              icon: Icons.error_outline,
              action: TextButton(
                onPressed: saving ? null : _retryLoad,
                child: const Text('重新加载'),
              ),
            )
          else ...[
            Semantics(
              liveRegion: true,
              child: Text(
                '共 ${_records.length} 条 · 已选 ${_selected.length} 条',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            SettingsActions(
              children: [
                TextButton(
                  onPressed: _canEdit && hasRecords
                      ? () => setState(() {
                          _selected.clear();
                          if (!allSelected) {
                            _selected.addAll(
                              _records.map((record) => record.id),
                            );
                          }
                        })
                      : null,
                  child: Text(allSelected ? '取消全选' : '全选本类'),
                ),
                OutlinedButton(
                  onPressed: _canEdit && _selected.isNotEmpty
                      ? () => _confirmChange(clear: false)
                      : null,
                  child: const Text('删除选中'),
                ),
                TextButton(
                  onPressed: _canEdit && hasRecords
                      ? () => _confirmChange(clear: true)
                      : null,
                  child: Text('清空$_category记录'),
                ),
                if (saving)
                  Semantics(liveRegion: true, child: const Text('正在保存…')),
              ],
            ),
            const SizedBox(height: AppSpace.lg),
            if (!hasRecords)
              EmptyState(title: '暂无「$_category」记录')
            else
              for (final record in _records) ...[
                const Divider(height: 1),
                CheckboxListTile(
                  key: ValueKey(record.id),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selected.contains(record.id),
                  onChanged: _canEdit
                      ? (selected) => setState(() {
                          if (selected == true) {
                            _selected.add(record.id);
                          } else {
                            _selected.remove(record.id);
                          }
                        })
                      : null,
                  title: Text(record.title),
                  subtitle: Text(record.subtitle),
                ),
              ],
          ],
        ],
      ),
    );
  }
}
