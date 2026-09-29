/// 浏览页：首页/分类 + 详情（§17.2 首页/分类页、详情页）。
library;

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../services/spider_router.dart';
import '../state/app_state.dart';
import 'app.dart';
import 'player_page.dart';

class BrowsePage extends StatelessWidget {
  const BrowsePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (!state.hasConfig) {
      return const _EmptyHint(
        title: '还没有导入配置',
        message: '请点击顶栏「导入配置」，支持 URL、本地文件和 JSON 文本三种方式。',
      );
    }
    final site = state.selectedSite;
    if (site == null) {
      return const _EmptyHint(
        title: '请选择站点',
        message: '点击顶栏「选择站点」挑选一个可运行的站点。',
      );
    }
    final availability = state.siteItems
        .where((item) => item.site.key == site.key)
        .map((item) => item.availability)
        .firstWhereOrNull();
    if (availability != null && !availability.available) {
      return _UnsupportedSiteHint(
        site: site,
        availability: availability,
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 280,
          child: _CategoryPanel(state: state, site: site),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: _VodGrid(state: state, site: site),
        ),
      ],
    );
  }
}

/// 左侧分类筛选区 + 分类列表（§17.1 侧栏 + 分类筛选区）。
class _CategoryPanel extends StatelessWidget {
  const _CategoryPanel({required this.state, required this.site});

  final AppState state;
  final Site site;

  @override
  Widget build(BuildContext context) {
    final home = state.homeResult;
    final classes = home?.classes ?? const <VodClass>[];
    final selected = state.selectedTypeId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                site.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'type=${site.type} · key=${site.key}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: state.contentPhase == LoadPhase.loading
                        ? null
                        : () => state.loadHome(site),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('刷新首页'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: state.contentPhase == LoadPhase.loading && classes.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    ListTile(
                      dense: true,
                      selected: selected == null,
                      title: const Text('默认推荐'),
                      onTap: () {
                        state.selectDefaultListing();
                      },
                    ),
                    for (final item in classes)
                      ListTile(
                        dense: true,
                        selected: selected == item.typeId,
                        title: Text(item.typeName),
                        subtitle: Text('type_id=${item.typeId}'),
                        onTap: () => state.loadCategory(item.typeId),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// 右侧海报网格（§17.1 海报网格）。
class _VodGrid extends StatelessWidget {
  const _VodGrid({required this.state, required this.site});

  final AppState state;
  final Site site;

  @override
  Widget build(BuildContext context) {
    final result = state.selectedTypeId == null
        ? state.homeResult
        : state.categoryResult;
    final vods = result?.list ?? const <Vod>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.lastError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: ErrorBanner(
              error: state.lastError!,
              onDismiss: state.clearError,
            ),
          ),
        if (state.notice != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _NoticeBanner(
              message: state.notice!,
              onDismiss: state.clearNotice,
            ),
          ),
        Expanded(
          child: state.contentPhase == LoadPhase.loading && vods.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : vods.isEmpty
                  ? const _EmptyHint(
                      title: '没有内容',
                      message: '该分类返回空列表。若站点不可用，请切换站点或更新配置。',
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 200,
                            mainAxisExtent: 300,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                          ),
                      itemCount: vods.length,
                      itemBuilder: (context, index) => _VodCard(
                        vod: vods[index],
                        onTap: () => _openDetail(context, vods[index]),
                      ),
                    ),
        ),
        if (state.selectedTypeId != null && result != null)
          _PaginationBar(state: state, result: result),
      ],
    );
  }

  Future<void> _openDetail(BuildContext context, Vod vod) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(state: state, vod: vod),
      ),
    );
  }
}

class _VodCard extends StatelessWidget {
  const _VodCard({required this.vod, required this.onTap});

  final Vod vod;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: PosterImage(url: vod.vodPic),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            vod.vodName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (vod.vodRemarks != null && vod.vodRemarks!.isNotEmpty)
            Text(
              vod.vodRemarks!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _PaginationBar extends StatelessWidget {
  const _PaginationBar({required this.state, required this.result});

  final AppState state;
  final SiteResult result;

  @override
  Widget build(BuildContext context) {
    final current = result.page ?? 1;
    final total = result.pageCount ?? 1;
    final typeId = state.selectedTypeId;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          OutlinedButton(
            onPressed: typeId == null || current <= 1
                ? null
                : () => state.loadCategory(typeId, page: current - 1),
            child: const Text('上一页'),
          ),
          const SizedBox(width: 12),
          Text('第 $current / $total 页 · 共 ${result.total ?? "-"} 条'),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: typeId == null || current >= total
                ? null
                : () => state.loadCategory(typeId, page: current + 1),
            child: const Text('下一页'),
          ),
        ],
      ),
    );
  }
}

/// 详情页（§17.2 详情页）。
class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.state, required this.vod});

  final AppState state;
  final Vod vod;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.state.loadDetail(widget.vod);
    });
  }

  Future<void> _play(Vod vod, VodPlayLine line, int episodeIndex) async {
    final episode = line.episodes[episodeIndex];
    final state = widget.state;
    try {
      final decision = await state.resolvePlayback(
        episodeTarget: episode.url,
        flag: line.flag,
        vodId: vod.vodId,
      );
      if (decision == null || decision.url == null) {
        throw AppError(
          AppErrorKind.playbackUrlMissing,
          '播放决策没有返回可用地址',
          detail: 'line=${line.flag} episode=${episode.name}',
        );
      }
      if (!mounted) return;
      // §15.2「继续播放」：进入播放器时从历史位置续播（无有效历史则为 null）。
      final resume = state.resumePositionFor(
        siteKey: state.selectedSite?.key ?? '',
        vodId: vod.vodId,
        flag: line.flag,
        episodeId: episode.url,
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            state: state,
            request: PlaybackRequest(
              url: decision.url!,
              headers: decision.headers?.asRequestHeaders ?? const {},
              title: vod.vodName,
              siteKey: state.selectedSite?.key ?? '',
              vodId: vod.vodId,
              vodName: vod.vodName,
              episodeName: episode.name,
              flag: line.flag,
              playLines: state.playLinesOf(vod),
              episodeIndex: episodeIndex,
              vodPic: vod.vodPic,
              startPosition: resume,
              // 外挂字幕（§10.3）与弹幕（§21 Phase 3）：播放结果 + 代理前 Header。
              subtitles: decision.subs,
              danmaku: decision.danmaku,
              subtitleHeaders:
                  decision.assetHeaders?.asRequestHeaders ?? const {},
            ),
          ),
        ),
      );
    } catch (error) {
      final failure = error is AppError
          ? error
          : AppError(AppErrorKind.unknown, '$error', cause: error);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failure.userMessage)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final vod = state.detailResult?.list.isNotEmpty == true
        ? state.detailResult!.list.first
        : widget.vod;
    final lines = state.playLinesOf(vod);

    return Scaffold(
      appBar: AppBar(
        title: Text(vod.vodName),
        actions: [
          IconButton(
            tooltip: state.isFavorite(kind: 'vod', targetId: vod.vodId)
                ? '取消收藏'
                : '收藏该影片',
            onPressed: () => state.toggleFavorite(
              kind: 'vod',
              targetId: vod.vodId,
              title: vod.vodName,
              subtitle: vod.vodRemarks,
            ),
            icon: Icon(
              state.isFavorite(kind: 'vod', targetId: vod.vodId)
                  ? Icons.bookmark
                  : Icons.bookmark_border,
            ),
          ),
          IconButton(
            tooltip: '刷新详情',
            onPressed: () => state.loadDetail(widget.vod),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: state.detailPhase == LoadPhase.loading && lines.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (state.lastError != null)
                  ErrorBanner(
                    error: state.lastError!,
                    onDismiss: state.clearError,
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: PosterImage(
                        url: vod.vodPic,
                        width: 160,
                        height: 220,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            vod.vodName,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          _MetaRow(label: '备注', value: vod.vodRemarks),
                          _MetaRow(label: '年份', value: vod.vodYear),
                          _MetaRow(label: '地区', value: vod.vodArea),
                          _MetaRow(label: '导演', value: vod.vodDirector),
                          _MetaRow(label: '演员', value: vod.vodActor),
                          const SizedBox(height: 8),
                          if (vod.vodContent != null)
                            Text(
                              vod.vodContent!,
                              maxLines: 6,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Divider(height: 32),
                if (lines.isEmpty)
                  const Text('该影片没有可播放的剧集（vod_play_url 为空）。')
                else
                  for (final line in lines) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        '${line.displayName}（${line.episodes.length} 集）',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var index = 0; index < line.episodes.length; index++)
                          OutlinedButton(
                            onPressed: () => _play(vod, line, index),
                            child: Text(
                              line.episodes[index].name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ],
              ],
            ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    if (value == null || value!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text('$label：$value'),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 40,
            color: Theme.of(context).disabledColor,
          ),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 站点运行时未支持时的明确提示（§8.1 “不得显示空列表”）。
class _UnsupportedSiteHint extends StatelessWidget {
  const _UnsupportedSiteHint({required this.site, required this.availability});

  final Site site;
  final SiteAvailability availability;

  @override
  Widget build(BuildContext context) {
    return _EmptyHint(
      title: '站点运行时未安装或不支持',
      message: '站点「${site.name}」需要 ${availability.runtimeName} 运行时'
          '${availability.stage == null ? "" : "（计划阶段：${availability.stage}）"}。\n'
          '${availability.reason ?? ""}\n'
          '请在站点列表中选择其他可运行站点。',
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.notifications_none, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
          IconButton(
            tooltip: '关闭提示',
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }
}

/// 与 `package:collection` 的 `firstOrNull` 等价的本地实现，避免为此新增依赖。
extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull() {
    for (final item in this) {
      return item;
    }
    return null;
  }
}
