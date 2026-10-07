/// 搜索页:多站点并发搜索、结果按站点分组、可取消（§14.1、§14.3、§17.2）。
///
/// 设计要点：
/// - 结果按站点分组展示，失败站点显示可定位错误而**不阻塞**其他站点；
/// - 搜索中可取消，取消后不再显示迟到结果；
/// - 点击结果先切到该结果所属站点，再打开详情页，保证详情/播放用的是同一条线路上下文；
/// - 未声明 `searchable` 或运行时不可用的站点会被跳过，并在页面上说明原因。
library;

import 'package:flutter/material.dart';

import '../core/protocol.dart';
import '../core/tmdb_identity.dart';
import '../state/app_state.dart';
import '../state/search_state.dart';
import 'app.dart';
import 'browse_pages.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.state,
    this.initialKeyword,
    this.identityHint,
  });

  final AppState state;

  /// 预填关键词（纯 TMDB 详情页「搜索站源」入口带入标题，`04` §6.2）。
  final String? initialKeyword;

  /// 身份提示（`tmdbId`），便于搜索结果自动匹配（`04` §6.2）。
  final TmdbIdentity? identityHint;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    final keyword = widget.initialKeyword?.trim() ?? '';
    if (keyword.isNotEmpty) {
      // 带入标题后**自动执行一次搜索**（对齐手动匹配弹窗「打开即搜索」）。
      _controller.text = keyword;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submit();
      });
    }
  }

  @override
  void dispose() {
    // 离开页面必须取消在途搜索，避免结果投递到已销毁的页面（§14.1）。
    widget.state.removeListener(_onStateChanged);
    widget.state.cancelSearch();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  AppState get _state => widget.state;

  Future<void> _submit() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    _focusNode.requestFocus();
    await _state.searchAll(keyword);
  }

  Future<void> _openResult(SiteSearchEntry entry, Vod vod) async {
    final site = _state.siteItems
        .where((item) => item.site.key == entry.siteKey)
        .map((item) => item.site)
        .firstOrNull;
    if (site == null) return;
    // 先切站点：详情与播放解析都依赖「当前站点」，否则会串到别的站点去取详情。
    await _state.selectSite(site);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(state: _state, vod: vod),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final outcome = _state.activeSearch;
    final searching = outcome != null && !outcome.finished;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '搜索影片',
                    hintText: '输入片名后回车,或点击搜索',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: searching ? null : _submit,
                icon: const Icon(Icons.search),
                label: const Text('搜索'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: searching ? _state.cancelSearch : null,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('取消'),
              ),
            ],
          ),
          if (_state.recentSearchKeywords.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('最近:'),
                for (final keyword in _state.recentSearchKeywords)
                  ActionChip(
                    label: Text(keyword),
                    onPressed: () {
                      _controller.text = keyword;
                      _submit();
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          if (searching)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (outcome != null) _buildSummary(outcome),
          const SizedBox(height: 8),
          Expanded(child: _buildResults(outcome)),
        ],
      ),
    );
  }

  Widget _buildSummary(MultiSiteSearchOutcome outcome) {
    final parts = <String>[
      '“${outcome.keyword}”',
      '命中站点 ${outcome.succeededCount}/${outcome.results.length}',
      '条目 ${outcome.totalItems}',
    ];
    if (outcome.failedCount > 0) parts.add('失败 ${outcome.failedCount}');
    if (outcome.skippedUnsupported > 0) {
      parts.add('跳过不可运行站点 ${outcome.skippedUnsupported}');
    }
    if (outcome.skippedNotSearchable > 0) {
      parts.add('跳过不可搜索站点 ${outcome.skippedNotSearchable}');
    }
    if (outcome.cancelled) {
      parts.add('已取消');
    } else if (outcome.finished) {
      parts.add('耗时 ${outcome.totalElapsed.inMilliseconds}ms');
    } else {
      parts.add('搜索中…');
    }
    return Text(
      parts.join(' · '),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  Widget _buildResults(MultiSiteSearchOutcome? outcome) {
    if (outcome == null) {
      return const Center(
        child: Text('输入关键词开始搜索。结果会按站点分组显示,单个站点失败不影响其他站点。'),
      );
    }
    if (outcome.cancelled) {
      return const Center(child: Text('搜索已取消。'));
    }
    if (outcome.results.isEmpty) {
      if (!outcome.finished) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Text(
          outcome.succeededCount == 0 && outcome.results.isEmpty
              ? '当前配置没有可搜索的站点,或搜索已被取消。'
              : '没有搜索结果。',
        ),
      );
    }
    return ListView(
      children: [
        for (final entry in outcome.results) _buildSiteSection(entry),
      ],
    );
  }

  Widget _buildSiteSection(SiteSearchEntry entry) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${entry.siteName}(key=${entry.siteKey})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (entry.fromCache)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Chip(label: Text('缓存'), visualDensity: VisualDensity.compact),
                  ),
                if (entry.succeeded)
                  Text('${entry.itemCount} 条 · ${entry.latency.inMilliseconds}ms')
                else
                  Text(
                    '失败',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (!entry.succeeded)
              // 失败站点给出可定位错误,并保留其他站点结果（§14.3）。
              ErrorBanner(error: entry.error!)
            else if (entry.itemCount == 0)
              const Text('该站点没有匹配结果。')
            else
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final vod in entry.result!.list)
                    SizedBox(
                      width: 140,
                      child: InkWell(
                        onTap: () => _openResult(entry, vod),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            PosterImage(
                              url: vod.vodPic,
                              width: 140,
                              height: 190,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              vod.vodName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (vod.vodRemarks != null)
                              Text(
                                vod.vodRemarks!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}