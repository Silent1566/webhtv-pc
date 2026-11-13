import 'package:flutter/material.dart';

import '../core/protocol.dart';

/// Explicit file-based episodes; no inferred TV or synthetic TMDB metadata.
class FolderEpisodeView extends StatelessWidget {
  const FolderEpisodeView({
    super.key,
    required this.title,
    required this.videos,
    required this.folders,
    required this.controller,
    required this.onOpen,
    required this.footer,
    this.openingKey,
  });

  final String title;
  final List<Vod> videos;
  final List<Vod> folders;
  final ScrollController controller;
  final ValueChanged<Vod> onOpen;
  final Widget footer;
  final String? openingKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scrollbar(
      controller: controller,
      child: CustomScrollView(
        key: const ValueKey('folder-episodes'),
        controller: controller,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    '${videos.length} 个视频 · 按文件名排序',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (folders.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final folder in folders)
                          OutlinedButton.icon(
                            onPressed: openingKey == null
                                ? () => onOpen(folder)
                                : null,
                            icon: const Icon(Icons.folder_outlined, size: 18),
                            label: Text(folder.vodName),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (videos.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('此页暂无视频，可浏览子目录或加载更多。'),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 280,
                mainAxisExtent: 72,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: videos.length,
              itemBuilder: (context, index) {
                final video = videos[index];
                return OutlinedButton(
                  key: ValueKey('folder-episode-${video.vodId}'),
                  onPressed: openingKey == null ? () => onOpen(video) : null,
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        openingKey == video.vodId
                            ? Icons.hourglass_top
                            : Icons.play_arrow,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          video.vodName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          SliverToBoxAdapter(child: footer),
        ],
      ),
    );
  }
}
