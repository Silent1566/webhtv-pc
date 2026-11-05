/// 站点注入管理页（`docs/phase9/README.md` P1-2）。
///
/// 只管理「补充站点」：删除/停用注入不会影响用户配置里的原站点；
/// 配置记录本身永远不被改写。
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'common.dart';
import 'toast.dart';

class InjectedSitesPage extends StatefulWidget {
  const InjectedSitesPage({super.key, required this.state});

  final AppState state;

  @override
  State<InjectedSitesPage> createState() => _InjectedSitesPageState();
}

class _InjectedSitesPageState extends State<InjectedSitesPage> {
  bool _busy = false;

  AppState get _state => widget.state;

  @override
  Widget build(BuildContext context) {
    final entries = _state.injectedSites;
    return Scaffold(
      appBar: AppBar(title: const Text('站点注入')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '粘贴站点 JSON（单个、数组或首尾相接的多个片段），识别后追加到站点列表。'
                    '配置记录不会被修改；删除注入即恢复原配置。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  key: const ValueKey('injected-sites-add'),
                  onPressed: _busy ? null : _add,
                  icon: const Icon(Icons.add),
                  label: const Text('添加站点'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? const EmptyState(
                    icon: Icons.extension_outlined,
                    title: '还没有注入站点',
                    message: '点「添加站点」粘贴站点 JSON；识别成功后立即出现在站点列表。',
                  )
                : ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return ListTile(
                        leading: Icon(
                          entry.enabled
                              ? Icons.extension
                              : Icons.extension_off_outlined,
                        ),
                        title: Text(entry.site.name),
                        subtitle: Text(
                          '${entry.site.key} · type=${entry.site.type}'
                          '${entry.enabled ? '' : ' · 已停用'}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              key: ValueKey('injected-site-toggle-${entry.key}'),
                              value: entry.enabled,
                              onChanged: (value) async {
                                await _state.setInjectedSiteEnabled(
                                  entry.key,
                                  value,
                                );
                                if (mounted) setState(() {});
                              },
                            ),
                            IconButton(
                              key: ValueKey('injected-site-remove-${entry.key}'),
                              tooltip: '删除注入 ${entry.site.name}',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('删除注入站点'),
                                    content: Text(
                                      '确定删除「${entry.site.name}」？'
                                      '不会影响配置里的同名站点。',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(false),
                                        child: const Text('取消'),
                                      ),
                                      FilledButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(true),
                                        child: const Text('删除'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed != true) return;
                                await _state.removeInjectedSite(entry.key);
                                if (mounted) setState(() {});
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('粘贴站点 JSON'),
        content: SizedBox(
          width: 640,
          child: TextField(
            key: const ValueKey('injected-sites-input'),
            controller: controller,
            autofocus: true,
            minLines: 8,
            maxLines: 16,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '{"key":"demo","name":"示例","type":1,"api":"https://..."}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('识别并添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    final input = text?.trim() ?? '';
    if (input.isEmpty || !mounted) return;

    setState(() => _busy = true);
    final count = await _state.addInjectedSites(input);
    if (!mounted) return;
    setState(() => _busy = false);
    if (count == 0) {
      showToast('没有识别到可用站点：需要包含 key、name 与非空 api', kind: ToastKind.error);
      return;
    }
    showToast('已添加/更新 $count 个注入站点', kind: ToastKind.success);
  }
}
