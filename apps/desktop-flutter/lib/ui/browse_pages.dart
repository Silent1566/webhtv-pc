/// 浏览页：首页/分类 + 详情（§17.2 首页/分类页、详情页）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_media.dart';
import '../core/tmdb_playback.dart';
import '../core/tmdb_title.dart';
import '../services/spider_router.dart';import '../state/app_state.dart';
import '../state/tmdb_state.dart';
import 'app.dart';
import 'config_pages.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'tmdb_detail_page.dart';
import 'tmdb_detail_view.dart';
import 'tmdb_widgets.dart';

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
    // 猫源/部分站点首页只返回分类（`class` 非空）而 `list` 为空，需要用户先点分类。
    // 直接显示「没有内容」会把正常站点误报成空站（实测 126 站点里 40 个如此），
    // 因此按“有无分类”区分两种空态文案。
    final hasClasses = result?.classes.isNotEmpty ?? false;

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
                  ? (hasClasses
                      ? const _EmptyHint(
                          title: '请选择左侧分类',
                          message: '该站点首页只返回分类列表（未提供推荐内容）。'
                              '点左侧任一分类即可加载影片；若分类也为空，再切换站点或更新配置。',
                        )
                      : const _EmptyHint(
                          title: '没有内容',
                          message: '该分类返回空列表。若站点不可用，请切换站点或更新配置。',
                        ))
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
    // 必须监听 AppState：详情请求在页面挂载后才完成，不重建就永远停在加载中
    // （实测「第一次进去说没有线路、第二次一直转圈」的直接成因）。
    // 搜索页、Spider 管理页同样监听了各自的状态变更。
    widget.state.addListener(_onStateChanged);
    // TMDB 区块也需监听（异步匹配/详情完成后重建，`04` §3.3）。
    widget.state.tmdb.addListener(_onStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.state.loadDetail(widget.vod);
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    widget.state.tmdb.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  void _closeDetail() {
    // 离开详情页时清掉全局详情状态（§8.3）：结果与所选影片是页面级临时状态，
    // 不清理会让下一次进入详情页先渲染上一部剧的线路（实测串剧）。
    widget.state.clearDetail();
    Navigator.of(context).pop();
  }

  /// 打开手动匹配弹窗（`04` §5.1）。
  Future<void> _openMatchDialog() async {
    final state = widget.state;
    final vod = _currentVod;
    final item = await showDialog<TmdbItem>(
      context: context,
      builder: (_) => TmdbMatchDialog(
        initialQuery: state.tmdb.item?.title ?? vod?.vodName ?? '',
        search: state.searchTmdb,
        resolveProviderId: state.resolveTmdbProviderId,
      ),
    );
    if (item == null || !mounted) return;
    await state.matchTmdbManual(item: item, sourceTitle: vod?.vodName);
  }

  /// 打开季度绑定弹窗（`04` §5.2）。
  Future<void> _openSeasonDialog() async {
    final state = widget.state;
    final tmdb = state.tmdb;
    final counts = tmdb.seasonEpisodeCounts;
    final seasons = counts.keys.toList()..sort();
    if (seasons.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('TMDB 未返回季度信息，暂时无法手动绑定季度')),
      );
      return;
    }
    final line = tmdb.sourceLine;
    final choice = await showDialog<TmdbSeasonChoice>(
      context: context,
      builder: (_) => TmdbSeasonDialog(
        tmdbSeasons: seasons,
        seasonCounts: counts,
        sourceEpisodeCount: line?.episodeCount ?? 0,
        currentSeason: tmdb.selectedSeason >= 0 ? tmdb.selectedSeason : null,
        canAutoSlice: tmdb.canAutoSlice,
      ),
    );
    if (choice == null || !mounted) return;
    await state.bindTmdbSeason(choice);
    if (!mounted) return;
    await state.reloadTmdb();
  }

  Vod? get _currentVod {
    final result = widget.state.detailResult;
    if (result != null &&
        result.list.isNotEmpty &&
        result.list.first.vodId == widget.vod.vodId) {
      return result.list.first;
    }
    return widget.vod;
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
      // TMDB 季度身份（`04` §8.1）：已确证季度时透传；未确证时只传 URL/集名。
      final tmdb = state.tmdb;
      final identity = TmdbPlaybackIdentity.of(
        identity: tmdb.identity,
        episode: episode,
        flagKey: tmdb.sourceLine?.flagKey ?? line.flag,
        seasonNumber: tmdb.hasMatch && tmdb.selectedSeason >= 0
            ? tmdb.selectedSeason
            : -1,
        episodeNumber: _tmdbEpisodeNumberOf(episode),
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
              tmdb: identity.hasIdentity ? identity : null,
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

  static int _tmdbEpisodeNumberOf(VodEpisode episode) {
    final raw = episode.extra['tmdb_episode_number'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    // 只有「结果属于本页影片」才允许渲染（§8.3）。
    //
    // 详情结果是 AppState 上的全局字段，用户「返回列表 → 点另一部剧」时，前一个
    // 请求可能还在飞行（本机实测 3.9~7.1s），若直接取 `detailResult.list.first`，
    // 新页面会先套用上一部剧的线路与简介，点播即串剧。这里以 vod_id 判归属，
    // 不属于本页时退回列表页传入的条目（其线路可能已由列表数据携带）。
    final result = state.detailResult;
    final belongs = result != null &&
        result.list.isNotEmpty &&
        result.list.first.vodId == widget.vod.vodId;
    final vod = belongs ? result.list.first : widget.vod;
    final lines = state.playLinesOf(vod);
    final loading = state.detailPhase == LoadPhase.loading;
    final tmdb = state.tmdb;
    // 头部补位（`04` §3.2）：**仅补位不覆盖**来源已有字段。
    final display = tmdb.hasMatch ? tmdb.enrich(vod).vod : vod;

    return Scaffold(
      appBar: AppBar(
        title: Text(vod.vodName),
        leading: IconButton(
          tooltip: '返回',
          onPressed: _closeDetail,
          icon: const Icon(Icons.arrow_back),
        ),
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
      body: loading && lines.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 详情错误只在「确实是在拉本页详情且没有可用线路」时提示，
                // 避免上一个条目的失败信息干扰当前页面（§8.3、§8.4）。
                if (state.detailError != null && lines.isEmpty)
                  ErrorBanner(
                    error: state.detailError!,
                    onDismiss: state.clearDetailError,
                  ),
                // 动态背景头部（`04` §3.1 ①）：用 TMDB 海报/剧照当背景，
                // 未匹配时回退到来源海报，保证头部不空白。
                TmdbDetailHeader(
                  data: tmdb.detailData ??
                      TmdbDetailData(
                        title: display.vodName,
                        overview: display.vodContent,
                        posterUrl: display.vodPic,
                        backdropUrls: [
                          if ((display.vodPic ?? '').isNotEmpty) display.vodPic!,
                        ],
                        rating: 0,
                      ),
                  statusBar: TmdbStatusBar(
                    state: tmdb,
                    onConfigure: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TmdbSettingsPage(state: state),
                      ),
                    ),
                    onMatch: _openMatchDialog,
                    onRematch: _openMatchDialog,
                    onSelectSeason: _openSeasonDialog,
                    onRetry: () => state.reloadTmdb(),
                  ),
                ),
                const SizedBox(height: 12),
                // 来源事实行（不覆盖来源字段，§3.2）。
                Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    if ((display.vodRemarks ?? '').isNotEmpty)
                      _MetaRow(label: '备注', value: display.vodRemarks),
                    if ((display.vodYear ?? '').isNotEmpty)
                      _MetaRow(label: '年份', value: display.vodYear),
                    if ((display.vodArea ?? '').isNotEmpty)
                      _MetaRow(label: '地区', value: display.vodArea),
                    if ((display.vodDirector ?? '').isNotEmpty)
                      _MetaRow(label: '导演', value: display.vodDirector),
                    if ((display.vodActor ?? '').isNotEmpty)
                      _MetaRow(label: '演员', value: display.vodActor),
                    if (tmdb.ratingText.isNotEmpty)
                      _MetaRow(label: '评分', value: tmdb.ratingText),
                  ],
                ),
                if (display.vodContent != null &&
                    display.vodContent!.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    display.vodContent!,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                // 季度选择器（`04` §4.1）：仅 tv 且已匹配时渲染。
                TmdbSeasonSelector(
                  state: tmdb,
                  onChanged: (season) {
                    tmdb.selectSeason(season);
                    unawaited(tmdb.loadEpisodes(generation: tmdb.generation));
                  },
                  onSelectManual: _openSeasonDialog,
                ),
                // 纯 TMDB 详情页入口（`04` §6.1）。
                if (tmdb.hasMatch && tmdb.identity != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('tmdb-open-detail'),
                      onPressed: () => _openTmdbDetail(tmdb.identity!),
                      icon: const Icon(Icons.movie_outlined, size: 18),
                      label: const Text('在 TMDB 中查看'),
                    ),
                  ),
                const Divider(height: 32),
                if (loading && lines.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (lines.isEmpty)
                  const Text('该影片没有可播放的剧集（vod_play_url 为空）。')
                else
                  for (var lineIndex = 0;
                      lineIndex < lines.length;
                      lineIndex++) ...[
                    _buildLine(
                      context,
                      vod,
                      lines[lineIndex],
                      lineIndex,
                      lines.length,
                    ),
                  ],
                // ⑥⑦⑧⑨ TMDB 附加区块（`04` §3.1）：失败时整块隐藏（不显示空态占位）。
                ..._buildTmdbBlocks(context, tmdb),
              ],
            ),
    );
  }

  /// 剧照墙 / 演职人员 / 相关推荐 / 相关视频（`04` §3.1 ⑥–⑨）。
  ///
  /// 全部**可点击**（用户反馈：之前点击无效）：
  /// - 剧照 → 大图查看器（可翻页）；
  /// - 演职人员 → 人物页（简介/照片/作品）；
  /// - 相关推荐 → 该作品的 TMDB 详情页；
  /// - 相关视频 → 浏览器打开 / 复制链接。
  List<Widget> _buildTmdbBlocks(BuildContext context, TmdbState tmdb) {
    final data = tmdb.detailData;
    if (data == null) return const [];
    return [
      const Divider(height: 32),
      TmdbDetailSections(
        data: data,
        recommendations: tmdb.recommendations,
        videos: tmdb.videos,
        onPersonTap: _openPerson,
        onRecommendationTap: _openItemDetail,
        onOpenVideo: widget.state.openExternalUrl,
        onCopyVideo: copyToClipboard,
      ),
    ];
  }

  /// 打开人物页（演职人员点击）。
  void _openPerson(TmdbPerson person) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbPersonPage(
          service: widget.state.tmdbService,
          person: person,
          onOpenItem: _openItemDetail,
        ),
      ),
    );
  }

  /// 打开某个 TMDB 作品详情（相关推荐 / 人物作品点击）。
  void _openItemDetail(TmdbItem item) {
    final identity = item.identity;
    if (identity == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbDetailPage(
          service: widget.state.tmdbService,
          identity: identity,
          initialItem: item,
          onSearchSource: (title, hint) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SearchPage(
                  state: widget.state,
                  initialKeyword: title,
                  identityHint: hint,
                ),
              ),
            );
          },
          onOpenVideo: widget.state.openExternalUrl,
          onCopyVideo: copyToClipboard,
        ),
      ),
    );
  }

  /// 渲染一条线路（含 TMDB 剧集元数据增强，`04` §4.2）。
  Widget _buildLine(
    BuildContext context,
    Vod vod,
    VodPlayLine rawLine,
    int lineIndex,
    int lineCount,
  ) {
    final state = widget.state;
    final tmdb = state.tmdb;
    final flagKey = TmdbState.flagKeyOf(
      rawLine,
      lineIndex,
      unique: lineCount == 1,
    );
    // 仅对**当前线路**应用 TMDB 剧集元数据（`04` §4.3 线路隔离）。
    //
    // `tmdb.sourceLine?.flagKey` 可能带 `#index` 后缀（同 flag 重复时），
    // 而这里的 `flagKey` 只在「整页只有一条线路」时才不带后缀。用
    // `selectLine` 的**同名判定规则**（`lineByFlag(flag)?.flagKey == 本条 flagKey`）
    // 比较，否则「重新匹配 / 换源」后 TMDB 侧选中的线路与本条渲染线路对不上，
    // 剧集剧照与 TMDB 集标题整块不生效（实测：卡片只剩来源集名 + 占位图）。
    final isActiveLine =
        tmdb.flagKeyForLine(rawLine) == (tmdb.sourceLine?.flagKey ?? '');
    final line = isActiveLine ? tmdb.applyEpisodesToLine(rawLine).line : rawLine;

    final available = isActiveLine ? tmdb.availableSeasons : const <int>[];
    final selected = isActiveLine ? tmdb.selectedSeason : -1;
    final episodes = TmdbEpisodeRenderPolicy.filter(
      episodes: line.episodes,
      availableSeasons: available,
      selectedSeason: selected,
      seasonOf: _seasonOfEpisode,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Row(
            children: [
              Text(
                '${line.displayName}（${episodes.length} 集）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (lineCount > 1 && !isActiveLine) ...[
                const SizedBox(width: 8),
                TextButton(
                  key: ValueKey('tmdb-line-select-$flagKey'),
                  onPressed: () async {
                    // 切换线路必须重新解析该线路的可播放季度（`04` §4.3）。
                    tmdb.selectLine(rawLine.flag);
                    await state.reloadTmdb();
                  },
                  child: const Text('按此线路解析季度'),
                ),
              ],
            ],
          ),
        ),
        // 剧集海报卡片（用户反馈 2026-10-07：每集要有对应的海报卡片）。
        //
        // 这是本线路**唯一**的选集入口：有卡片就不再渲染文字版集按钮
        // （用户反馈 2026-10-08：二者取其一，不要重复两套控件）。
        // 卡片数量恒等于本线路渲染的集数；未匹配 TMDB 时用来源剧照/海报兑底，
        // 保证「每集都有画面」。
        TmdbEpisodeStrip(
          key: ValueKey('tmdb-episode-strip-${line.flag}'),
          cards: tmdb.episodeCardsForEpisodes(
            episodes,
            seasonNumber: selected >= 0 ? selected : null,
            includeMetadata: isActiveLine,
          ),
          keyPrefix: 'tmdb-episode-card-${line.flag}',
          actionLabel: '播放',
          cardWidth: _episodeCardWidth(context, episodes.length),
          onTap: (index, _) => _playEpisodeAt(
            vod,
            rawLine,
            line,
            episodes,
            index,
          ),
        ),
      ],
    );
  }

  /// 剧集卡片宽度（`04` §4.4 列数策略的卡片版）。
  ///
  /// 集数多的线路把卡做窄，使一行能看到更多集，减少横向滚动；集数少时保持
  /// 大卡以突出剧照。窗口很窄时兜底到最小宽度，不得为负或过小。
  static double _episodeCardWidth(BuildContext context, int episodeCount) {
    final width = MediaQuery.sizeOf(context).width;
    final targetColumns = switch (episodeCount) {
      <= 8 => 5,
      <= 20 => 7,
      _ => 9,
    };
    final available = width - 32 - (targetColumns - 1) * 10;
    final raw = available / targetColumns;
    return raw.clamp(150.0, 300.0);
  }

  /// 按**渲染下标**播放（卡片与按钮共用，保证「点哪一集就播哪一集」）。
  void _playEpisodeAt(
    Vod vod,
    VodPlayLine rawLine,
    VodPlayLine line,
    List<VodEpisode> episodes,
    int index,
  ) {
    if (index < 0 || index >= episodes.length) return;
    final episode = episodes[index];
    // 播放必须用**线路原始下标**（TMDB 只丰富展示，不改变播放事实源）。
    final rawIndex = line.episodes.indexWhere(
      (candidate) =>
          identical(candidate, episode) || candidate.url == episode.url,
    );
    _play(vod, rawLine, rawIndex < 0 ? index : rawIndex);
  }

  /// 剧集所在季度。
  ///
  /// 优先取 TMDB 富集写入的 `tmdb_season_number`；否则回退到**来源集名**里的
  /// 季度信号（`第 N 季` / `SxxExx`）。
  ///
  /// 为什么必须回退：富集只为**当前选中季度**写 `tmdb_season_number`，其余
  /// 季度的集不会被标记。若只看 `extra`，多季线路的季度过滤就会失效
  /// （所有集都被当成「未分类」而保留，选集数永不缩小）。
  /// 来源集名是**事实源**（§27 原则 1），用它分类不引入任何猜测。
  static int _seasonOfEpisode(VodEpisode episode) {
    final raw = episode.extra['tmdb_season_number'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return sourceSeasonNumber(episode.name);
  }

  /// 打开纯 TMDB 详情页（`04` §6）。
  ///
  /// 该页面**没有播放按钮**；剧集卡片点击后跳搜索页并带入标题与身份提示。
  Future<void> _openTmdbDetail(TmdbIdentity identity) async {
    final state = widget.state;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TmdbDetailPage(
          service: state.tmdbService,
          identity: identity,
          initialItem: state.tmdb.item,
          onSearchSource: (title, hint) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SearchPage(
                  state: state,
                  initialKeyword: title,
                  identityHint: hint,
                ),
              ),
            );
          },
        ),
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
