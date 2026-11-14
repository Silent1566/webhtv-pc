import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/playback_queue.dart';
import '../core/protocol.dart';
import 'tokens.dart';

class PlayerQueuePanel extends StatefulWidget {
  const PlayerQueuePanel({
    super.key,
    required this.title,
    required this.queue,
    required this.currentKey,
    required this.onSelect,
    required this.playLines,
    required this.lineFlag,
    required this.onSelectLine,
  });
  final String title;
  final PlaybackQueue queue;
  final String? currentKey;
  final ValueChanged<String> onSelect;
  final List<VodPlayLine> playLines;
  final String lineFlag;
  final ValueChanged<String> onSelectLine;
  @override
  State<PlayerQueuePanel> createState() => _PlayerQueuePanelState();
}

class _PlayerQueuePanelState extends State<PlayerQueuePanel> {
  final _scroll = ScrollController();
  bool _scrolled = false;
  bool _loading = false;
  String? _error;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _select(String key) {
    Navigator.of(context).pop();
    widget.onSelect(key);
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.queue.loadMore();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(AppSpace.lg),
      child: Container(
        key: const ValueKey('player-queue-panel'),
        width: math.min(980, size.width * 0.86),
        height: math.min(640, size.height * 0.82),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: AppRadius.lgAll,
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: AnimatedBuilder(
          animation: widget.queue,
          builder: (context, _) {
            final snapshot = widget.queue.snapshot;
            final busy = snapshot.loading || _loading;
            final error = snapshot.error?.userMessage ?? _error;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.lg,
                    AppSpace.md,
                    AppSpace.sm,
                    AppSpace.xs,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '同目录 · ${snapshot.items.length} 集${snapshot.hasMore ? ' · 还有更多' : ''}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                if (widget.playLines.length > 1)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.lg,
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final line in widget.playLines)
                            Padding(
                              padding: const EdgeInsets.only(
                                right: AppSpace.sm,
                              ),
                              child: ChoiceChip(
                                label: Text(line.displayName),
                                selected: line.flag == widget.lineFlag,
                                onSelected: (_) {
                                  if (line.flag == widget.lineFlag) return;
                                  Navigator.of(context).pop();
                                  widget.onSelectLine(line.flag);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.md),
                    child: snapshot.items.isEmpty
                        ? Center(child: Text(busy ? '正在读取目录…' : '暂无可播放文件'))
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final columns = math.max(
                                1,
                                (constraints.maxWidth / 240).ceil(),
                              );
                              const gap = AppSpace.sm;
                              final width =
                                  (constraints.maxWidth - gap * (columns - 1)) /
                                  columns;
                              if (!_scrolled) {
                                _scrolled = true;
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (!mounted || !_scroll.hasClients) return;
                                  final index = widget.queue.snapshot.items
                                      .indexWhere(
                                        (item) => item.key == widget.currentKey,
                                      );
                                  if (index < 0) return;
                                  final target =
                                      ((index ~/ columns) * (width / 1.2 + gap))
                                          .clamp(
                                            0.0,
                                            _scroll.position.maxScrollExtent,
                                          );
                                  _scroll.jumpTo(target);
                                });
                              }
                              return GridView.builder(
                                controller: _scroll,
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      crossAxisSpacing: gap,
                                      mainAxisSpacing: gap,
                                      childAspectRatio: 1.2,
                                    ),
                                itemCount: snapshot.items.length,
                                findChildIndexCallback: (key) {
                                  final index = snapshot.items.indexWhere(
                                    (item) =>
                                        ValueKey(
                                          'player-queue-item-${item.key}',
                                        ) ==
                                        key,
                                  );
                                  return index < 0 ? null : index;
                                },
                                itemBuilder: (context, index) {
                                  final item = snapshot.items[index];
                                  final current = item.key == widget.currentKey;
                                  final accent =
                                      context.semanticColors.magnitude;
                                  return Semantics(
                                    key: ValueKey(
                                      'player-queue-item-${item.key}',
                                    ),
                                    selected: current,
                                    button: true,
                                    label: item.title,
                                    child: Material(
                                      color: scheme.surfaceContainerHigh,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: AppRadius.mdAll,
                                        side: BorderSide(
                                          color: current
                                              ? accent
                                              : scheme.outlineVariant,
                                          width: current ? 2 : 1,
                                        ),
                                      ),
                                      clipBehavior: Clip.antiAlias,
                                      child: InkWell(
                                        onTap: () => _select(item.key),
                                        child: Padding(
                                          padding: const EdgeInsets.all(
                                            AppSpace.md,
                                          ),
                                          child: Center(
                                            child: Text(
                                              item.title,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.center,
                                              style: theme.textTheme.bodyMedium
                                                  ?.copyWith(
                                                    color: current
                                                        ? accent
                                                        : scheme.onSurface,
                                                    fontWeight: current
                                                        ? AppWeight.title
                                                        : AppWeight.body,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.lg,
                    ),
                    child: Text(
                      error,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                if (snapshot.hasMore || busy || error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.lg,
                      AppSpace.sm,
                      AppSpace.lg,
                      AppSpace.md,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const ValueKey('player-queue-load-more'),
                        onPressed: busy ? null : _loadMore,
                        icon: busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                error == null
                                    ? Icons.expand_more
                                    : Icons.refresh,
                              ),
                        label: Text(
                          busy
                              ? '正在加载…'
                              : error == null
                              ? '加载更多'
                              : '重试加载',
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
