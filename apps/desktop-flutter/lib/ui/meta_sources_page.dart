/// 元数据来源设置：逐字段配置「优先 / 聚合」，支持多选与拖拽排序。
///
/// 为什么按字段而不是按来源：一个来源往往只擅长少数几样（豆瓣有演职员与相册、
/// Bangumi 有简介、Wikidata 有传记），全局开关表达不了这种分工。
library;

import 'package:flutter/material.dart';

import '../core/meta_pipeline.dart';
import '../core/meta_source.dart';
import '../state/app_state.dart';
import 'common.dart';

class MetaSourcesPage extends StatelessWidget {
  const MetaSourcesPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('元数据来源'),
        actions: [
          TextButton(
            key: const ValueKey('meta-sources-reset'),
            onPressed: () => state.setMetaPipeline(MetaPipeline.defaults),
            child: const Text('恢复默认'),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(
        padding: formPagePadding(context),
        children: [
          SwitchListTile(
            key: const ValueKey('external-meta-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('外部元数据兜底'),
            subtitle: const Text('关闭后停止外部请求，仍按规则使用 TMDB 与爬虫源'),
            value: state.externalMetaEnabled,
            onChanged: (value) => state.setExternalMetaEnabled(value),
          ),
          Text(
            '「优先」按顺序取、取到即停；「聚合」全部并行取并合并。拖动手柄排序，勾选框启用或停用来源。爬虫源是当前资源自身字段，默认最后兜底。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          for (final field in MetaField.values)
            _FieldTile(state: state, pipeline: state.metaPipeline, field: field),
        ],
        ),
      ),
    );
  }
}

class _FieldTile extends StatelessWidget {
  const _FieldTile({
    required this.state,
    required this.pipeline,
    required this.field,
  });

  final AppState state;
  final MetaPipeline pipeline;
  final MetaField field;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = pipeline.ruleOf(field);
    final enabled = rule.order;
    final disabled = [
      for (final source in MetaSourceKind.values)
        if (!enabled.contains(source) &&
            (source != MetaSourceKind.source || MetaPipeline.supportsSource(field))) source,
    ];
    String keyOf(MetaSourceKind source) =>
        'meta-source-${field.key}-${source.key}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(field.label, style: theme.textTheme.titleSmall),
                  ),
                  SegmentedButton<MetaFieldMode>(
                    key: ValueKey('meta-mode-${field.key}'),
                    segments: const [
                      ButtonSegment(
                        value: MetaFieldMode.priority,
                        label: Text('优先'),
                      ),
                      ButtonSegment(
                        value: MetaFieldMode.aggregate,
                        label: Text('聚合'),
                      ),
                    ],
                    selected: {rule.mode},
                    showSelectedIcon: false,
                    onSelectionChanged: (value) => state.setMetaPipeline(
                      pipeline.withRule(rule.copyWith(mode: value.first)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ReorderableListView.builder(
                key: ValueKey('meta-order-${field.key}'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: enabled.length,
                onReorderItem: (from, to) => state.setMetaPipeline(
                  pipeline.moveSource(field, from, to),
                ),
                itemBuilder: (context, index) {
                  final source = enabled[index];
                  return ListTile(
                    key: ValueKey(keyOf(source)),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(Icons.drag_handle, size: 18),
                    ),
                    title: Text(source.label),
                    trailing: Checkbox(
                      value: true,
                      onChanged: (_) => state.setMetaPipeline(
                        pipeline.toggleSource(field, source),
                      ),
                    ),
                  );
                },
              ),
              for (final source in disabled)
                ListTile(
                  key: ValueKey(keyOf(source)),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const SizedBox(width: 18),
                  title: Text(source.label),
                  trailing: Checkbox(
                    value: false,
                    onChanged: (_) => state.setMetaPipeline(
                      pipeline.toggleSource(field, source),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}