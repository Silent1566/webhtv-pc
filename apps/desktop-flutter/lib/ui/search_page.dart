/// 搜索页：联想、历史、热门推荐、范围限定、多站点并发搜索、结果筛选与分页
/// （§14.1、§14.3、§17.2）。
///
/// 对齐上游安卓「默影视」SearchFragment + CollectFragment 的功能集：
/// - **联想**：输入即取爱奇艺 + 腾讯双源联想，下拉选择即搜（上游 `getSuggest`）；
/// - **搜索历史**：去重、最新在前、上限 10 条，可单条删除 / 全清
///   （上游 `RecordAdapter`），持久化在 `settings.json`；
/// - **热门推荐**：360kan 电影 / 剧集 / 综艺榜单（上游 `getHot`），
///   断网时回退磁盘缓存；
/// - **搜索范围**：全部 / 当前站点 / 某分组（上游 `SearchFragment` 的 scope 菜单）；
/// - **结果筛选**：按分组（站点名方括号标记）与相似度阈值过滤
///   （上游 `CollectFragment` 的 `action_group` / `action_similarity`）；
/// - **结果分页**：滚动到底自动翻下一页 + 「加载更多」兜底，内容重复即判该站点
///   耗尽（上游 `CustomScroller` + `SearchPageState`）；
/// - **站点侧栏**：结果按站点聚合，「全部」合并视图 + 单站点视图点击切换，
///   不用再在混排列表里翻找自己喜欢的站点（上游 `CollectAdapter` 侧栏）。
///
/// 搜索批次本身的多站点并发 / 失败不阻塞 / 可取消语义见 `AppState.searchAll`。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/history_view.dart';
import '../core/hot_rank_layout.dart';
import '../core/protocol.dart';
import '../core/tmdb_identity.dart';
import '../services/search_suggest_service.dart';
import '../state/app_state.dart';
import '../state/search_state.dart';
import 'browse_pages.dart';
import 'common.dart';
import 'search_result_view.dart';
import 'tokens.dart';

/// 热门推荐区的头部高度（标题行 24 + 间距 8 + 类目 tab 32）。
///
/// 必须是**与实际布局一致**的精确值：网格可用高度用
/// `maxHeight - _hotHeaderHeight` 算，而头部又被强制放在这个高度的盒子里，
/// 两边一致才能保证「列 × 行」恰好铺满而不是溢出或空一行。
const double _hotHeaderHeight = 64;

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.state,
    this.initialKeyword,
    this.identityHint,
    this.resumeSeed,
  });

  final AppState state;

  /// 预填关键词（纯 TMDB 详情页「搜索站源」入口带入标题，`04` §6.2）。
  final String? initialKeyword;

  /// 身份提示（`tmdbId`），便于搜索结果自动匹配（`04` §6.2）。
  final TmdbIdentity? identityHint;

  /// 待迁移的续播种子（跨源续播的降级入口带入，`design/05` §7.4）。
  ///
  /// 不带的话，用户从「未找到可可靠续播的播放源」点进全局搜索、挑中一条结果后，
  /// 进度上下文就丢了，只能从头播——而这正是他点「继续观看」想避免的事。
  final ResumeSeed? resumeSeed;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// 联想层可见性：输入非空且获得焦点时展开。
  bool _suggestVisible = false;

  /// 联想词（保序去重后）。null = 尚未请求（不发联想请求时恢复热搜区）。
  List<SearchSuggestItem>? _suggestions;

  /// 上一次已响应的输入文本。
  ///
  /// 为什么需要它：`TextEditingController` 在**选区变化**时也会通知监听者，
  /// 而 `controller.text = x` 会把 selection 置为 -1（同样是「值变化」）——
  /// 于是提交搜索后重设文本又触发一次 `_onInputChanged`，把刚收起的联想面板
  /// 重新打开（实测：点「搜索」后结果区被联想下拉盖住）。只按文本内容变化
  /// 响应，选区抖动一律忽略。
  String _lastInput = '';

  /// 联想防抖计时器。
  Timer? _suggestDebounce;

  /// 联想请求序号：输入变化后旧响应作废（上游 `mSuggestSeq`）。
  int _suggestSeq = 0;

  /// 热门推荐：电影 / 剧集 / 综艺。
  Map<HotRankCategory, List<SearchSuggestItem>> _hotRanks = const {};

  /// 热门区当前展开的类目（默认电影）。
  HotRankCategory _hotTab = HotRankCategory.movie;

  /// 各个类目的「换一批」窗口起点（候选池下标；`hotRankWindow` 会回绕）。
  ///
  /// 按类目分开记：切回某个类目时应接着上次那一批，而不是跳回第一批。
  final Map<HotRankCategory, int> _hotOffsets = {};

  // ---- 搜索范围（对齐上游 SearchFragment 的 scope 菜单）----

  /// 范围：限定站点 key；空串 = 不限定。
  String _scopeSiteKey = '';

  /// 范围：限定分组；空串 = 不限定。与 [_scopeSiteKey] 互斥。
  String _scopeGroup = '';

  // ---- 结果筛选状态（对齐上游 CollectFragment）----
  //
  // 站点选中态、滚动位置、自动续翻重入锁都归 `SearchResultView` 自己的
  // State（它按 `outcome.runId` 换代重建）；页面只持有「跨批次要记住」的
  // 两项：分组筛选与相似度阈值（后者持久化在 `AppState`）。

  /// 分组筛选；空串 = 全部分组。
  String _filterGroup = '';

  /// 相似度阈值（页面快照；保存走 `state.setSearchSimilarity`）。
  int _similarity = 30;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    _similarity = widget.state.searchSimilarity;
    _controller.addListener(_onInputChanged);
    final keyword = widget.initialKeyword?.trim() ?? '';
    if (keyword.isNotEmpty) {
      // 带入标题后**自动执行一次搜索**（对齐手动匹配弹窗「打开即搜索」）。
      _controller.text = keyword;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submit();
      });
    } else {
      // 不带关键词进来（切回搜索页/首次进入）→ 把上一轮残留的结果丢掉，
      // 否则再输入时会先闪出旧结果（`_activeSearch` 跨页面存活）。
      // 放 post-frame：`clearSearch` 会 notifyListeners，而此刻还在父级 build 中。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.state.clearSearch();
      });
      _loadHotRanks();
    }
  }

  @override
  void dispose() {
    // 离开页面必须取消在途搜索，避免结果投递到已销毁的页面（§14.1）。
    _suggestDebounce?.cancel();
    widget.state.removeListener(_onStateChanged);
    widget.state.cancelSearch();
    _controller.removeListener(_onInputChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  AppState get _state => widget.state;

  MultiSiteSearchOutcome? get _outcome => _state.activeSearch;

  // ---------------------------------------------------------------------------
  // 输入、联想、提交
  // ---------------------------------------------------------------------------

  void _onInputChanged() {
    final text = _controller.text.trim();
    // 选区变化（含 `text = x` 把 selection 置 -1）不是输入变化，不得重开联想。
    if (text == _lastInput) return;
    _lastInput = text;
    _suggestDebounce?.cancel();
    if (text.isEmpty) {
      // 清空输入 → 收起联想、丢掉残留结果、回到历史 + 热门（上游 `getWord` 分支）。
      _suggestSeq++;
      _state.clearSearch();
      if (_suggestions != null || _suggestVisible) {
        setState(() {
          _suggestions = null;
          _suggestVisible = false;
        });
      }
      return;
    }
    // 防抖 250ms：联想接口按击键打太多没意义（上游也是文本变化即发，但桌面端
    // 键盘输入频率更高，防抖能砍掉绝大多数中间态请求）。
    _suggestDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _suggestVisible = true);
      _fetchSuggestions(text);
    });
  }

  Future<void> _fetchSuggestions(String text) async {
    final seq = ++_suggestSeq;
    final items = await _state.searchSuggest(text);
    if (!mounted || seq != _suggestSeq) return;
    if (_controller.text.trim() != text) return;
    setState(() => _suggestions = items);
  }

  Future<void> _loadHotRanks() async {
    final categories = HotRankCategory.values;
    final results = await Future.wait([
      for (final category in categories) _state.searchHotRank(category),
    ]);
    if (!mounted) return;
    setState(() {
      _hotRanks = {
        for (var i = 0; i < categories.length; i++)
          categories[i]: results[i],
      };
    });
  }

  Future<void> _submit([String? keyword]) async {
    final text = (keyword ?? _controller.text).trim();
    if (text.isEmpty) return;
    _suggestDebounce?.cancel();
    _suggestSeq++;
    // 先登记文本再赋值：赋值会因 selection 变化触发监听，登记后那次通知会被
    // `_lastInput` 相等判定忽略（否则结果区会被联想面板盖住）。
    _lastInput = text;
    _controller.text = text;
    _focusNode.requestFocus();
    _focusNode.unfocus();
    setState(() {
      _suggestVisible = false;
      _suggestions = null;
      _filterGroup = '';
    });
    await _state.searchAll(
      text,
      siteKey: _scopeSiteKey,
      group: _scopeGroup,
    );
  }

  /// 搜索页回到「未搜索」状态：清空输入 → 收起联想 → 丢掉结果。
  ///
  /// 清空输入会走 `_onInputChanged` 的空分支（收起联想 + `clearSearch`），
  /// 这里只需把结果区自己的筛选态一并复位。
  void _backToLanding() {
    _suggestDebounce?.cancel();
    _suggestSeq++;
    _controller.clear();
    setState(() {
      _suggestVisible = false;
      _suggestions = null;
      _filterGroup = '';
    });
  }

  /// 联想 / 历史 / 热门点击 → 直接搜该词。
  void _searchFrom(String keyword) => _submit(keyword);

  // ---------------------------------------------------------------------------
  // 搜索范围（上游 SearchFragment 的 scope 菜单）
  // ---------------------------------------------------------------------------

  String? _siteNameOf(String key) {
    for (final item in _state.siteItems) {
      if (item.site.key == key) return item.site.name;
    }
    return null;
  }

  String get _scopeLabel {
    if (_scopeGroup.isNotEmpty) return '分组：$_scopeGroup';
    if (_scopeSiteKey.isNotEmpty) {
      final name = _siteNameOf(_scopeSiteKey);
      return name == null ? _scopeSiteKey : '当前站点：$name';
    }
    return '全部站点';
  }

  bool get _scopeScoped => _scopeSiteKey.isNotEmpty || _scopeGroup.isNotEmpty;

  /// 范围选择器（全部 / 当前站点 / 各分组）。
  Widget _buildScopeButton() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectedSite = _state.selectedSite;
    final groups = _state.searchScopeGroups;
    final scoped = _scopeScoped;
    return PopupMenuButton<String>(
      key: const ValueKey('search-scope'),
      tooltip: '搜索范围',
      position: PopupMenuPosition.under,
      onSelected: _onScopeSelected,
      itemBuilder: (context) => [
        const PopupMenuItem(
          key: ValueKey('search-scope-all'),
          value: 'all',
          child: Text('全部站点'),
        ),
        if (selectedSite != null && selectedSite.searchable)
          PopupMenuItem(
            key: const ValueKey('search-scope-site'),
            value: 'site',
            child: Text('当前站点：${selectedSite.name}'),
          ),
        for (final group in groups)
          PopupMenuItem(
            key: ValueKey('search-scope-group-$group'),
            value: 'group:$group',
            child: Text('分组：$group'),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.md,
        ),
        decoration: BoxDecoration(
          border: Border.all(
            color: scoped ? scheme.primary : scheme.outlineVariant,
          ),
          borderRadius: AppRadius.mdAll,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_alt_outlined,
              size: 18,
              color: scoped ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpace.sm),
            Text(_scopeLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }

  void _onScopeSelected(String value) {
    setState(() {
      if (value == 'all') {
        _scopeSiteKey = '';
        _scopeGroup = '';
      } else if (value == 'site') {
        _scopeSiteKey = _state.selectedSite?.key ?? '';
        _scopeGroup = '';
      } else if (value.startsWith('group:')) {
        _scopeSiteKey = '';
        _scopeGroup = value.substring('group:'.length);
      }
    });
    // 范围变了就必须重搜——否则用户看到的是旧范围的旧结果（上游是回上一页
    // 重新进搜索页，PC 端直接按新范围重搜更直接）。
    if (_outcome != null) unawaited(_submit());
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
        // 续播上下文原样带下去：没有它，从「未找到可可靠续播的播放源」
        // 走全局搜索选中的结果会从头播（`design/05` §7.4）。
        builder: (_) => DetailPage(
          state: _state,
          vod: vod,
          resumeSeed: widget.resumeSeed,
        ),
      ),
    );
  }


  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final outcome = _outcome;
    final searching = outcome != null && !outcome.finished;
    final hasKeyword = _controller.text.trim().isNotEmpty;
    // 落地页（搜索历史 + 热门推荐）只由**输入框**决定。
    //
    // 不能用「`outcome == null`」当条件（用户 2026-10-14 实测反馈）：
    // `_activeSearch` 是**跨页面存活**的状态，搜过一次后就一直存在，
    // 于是清空输入框、甚至切走再切回搜索页，都再也回不到推荐落地页。
    // 输入框为空 = 「还没开始搜」，就该看到推荐。（清空时同时会调用
    // `state.clearSearch()` 把残留结果丢掉，避免回到落地页后残留状态又在下一轮
    // 输入时冒出来。）
    final showLanding = !hasKeyword;

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInputRow(searching, hasKeyword, outcome != null),
              const SizedBox(height: AppSpace.md),
              if (searching)
                const Padding(
                  padding: EdgeInsets.only(bottom: AppSpace.sm),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              Expanded(
                child: showLanding
                    ? _buildLanding()
                    : _buildResultsArea(outcome),
              ),
            ],
          ),
        ),
        // 联想下拉层：覆盖在输入框正下方。
        //
        // 必须包一层 `TextFieldTapRegion`：它把面板归入输入框的「点击区域组」，
        // 于是点面板不会被 `TextField.onTapOutside` 当成「点外部」——否则面板会
        // 在点击的落下与抬起之间被卸载，`ListTile.onTap` 永远收不到
        // （实测缺陷，用户 2026-10-14）。
        if (_suggestVisible && _suggestions != null)
          Positioned(
            top: AppSpace.lg + 56,
            left: AppSpace.lg,
            right: AppSpace.lg,
            child: TextFieldTapRegion(child: _buildSuggestPanel()),
          ),
      ],
    );
  }

  Widget _buildInputRow(bool searching, bool hasKeyword, bool hasOutcome) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('search-input'),
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '搜索影片',
              hintText: '输入片名后回车,或点击搜索',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (value) => _submit(value),
            // 收起联想面板靠**点击外部**，而**不是**靠失焦。
            //
            // 为什么不能用 `_focusNode` 的失焦（实测缺陷，用户 2026-10-14：
            // 「点击联想结果没有反应也没有输入到输入框中」）：点击面板里的
            // `ListTile` 本身就会让输入框失焦，于是失焦处理先把面板卸载，
            // 点击的抬起事件就再也落不到那个 ListTile 上——`onTap` 永远不会触发。
            // 鼠标点击的按下/抬起跨越两帧，而 widget 测试的 down+up 在同一帧
            // 内完成，所以这个缺陷能躲过 widget 测试。
            onTapOutside: (_) {
              if (_suggestVisible) setState(() => _suggestVisible = false);
            },
          ),
        ),
        const SizedBox(width: AppSpace.md),
        _buildScopeButton(),
        const SizedBox(width: AppSpace.md),
        FilledButton.icon(
          onPressed: searching ? null : _submit,
          icon: const Icon(Icons.search),
          label: const Text('搜索'),
        ),
        const SizedBox(width: AppSpace.sm),
        OutlinedButton.icon(
          // 按钮在两种情形下都要**可用**（用户 2026-10-14：「取消按钮也没办法
          // 点击」）：
          // - 搜索在途 → 「取消」（丢掉在途批次，对齐上游可取消搜索）；
          // - 搜索已结束但还停在结果页 → 「返回推荐」（清空输入 + 清掉结果，
          //   回到搜索历史/热门推荐）。
          // 之前只写了 `searching ? cancel : null`，搜索一结束按钮就变灰，
          // 而那时恰好是用户最需要一个「回去」入口的时候。
          key: const ValueKey('search-cancel'),
          onPressed: searching
              ? _state.cancelSearch
              : (hasKeyword || hasOutcome ? _backToLanding : null),
          icon: Icon(
            searching ? Icons.cancel_outlined : Icons.arrow_back_outlined,
          ),
          label: Text(searching ? '取消' : '返回推荐'),
        ),
      ],
    );
  }

  /// 未搜索时的落地页：历史 + 热门推荐（上游 SearchFragment 的主界面）。
  ///
  /// 用 `Column` + `Expanded` 而不是整体 `ListView`：热门区要「按可用宽高恰好
  /// 铺满」，就必须拿到**有限的**高度约束（`LayoutBuilder` 在无限高的滚动列表里
  /// 只能得到 infinity）。因此历史区按自然高度、热门区吃掉剩下全部空间。
  Widget _buildLanding() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHistorySection(),
        const SizedBox(height: AppSpace.lg),
        Expanded(child: _buildHotSection()),
      ],
    );
  }

  /// 搜索历史：chips + 单条删除 + 全部清空。
  Widget _buildHistorySection() {
    final history = _state.recentSearchKeywords;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.history, size: 18),
            const SizedBox(width: AppSpace.sm),
            Text('搜索历史', style: Theme.of(context).textTheme.titleSmall),
            const Spacer(),
            if (history.isNotEmpty)
              TextButton.icon(
                onPressed: () async {
                  await _state.clearSearchHistory();
                },
                icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                label: const Text('清空'),
              ),
          ],
        ),
        if (history.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
            child: Text(
              '暂无搜索记录',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                for (final keyword in history)
                  InputChip(
                    key: ValueKey('search-history-$keyword'),
                    label: Text(keyword),
                    onPressed: () => _searchFrom(keyword),
                    onDeleted: () => _state.removeSearchKeyword(keyword),
                    deleteIconColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// 热门推荐：类目 tab + **按可用宽高恰好铺满**的榜单海报卡片（360kan 榜单）。
  ///
  /// 为什么用卡片而不是词 chips（用户 2026-10-14：「能找到对应的图片吗？
  /// 显示成卡片是否更好看点」）：榜单接口本身就带竖版海报（`cover`）、集数
  /// （`upinfo`）与评分（`doubanscore`），词条把这三样全丢了。
  ///
  /// 为什么条数由布局算（用户 2026-10-14：「能否自动基于高宽计算显示多少个推荐
  /// 条目也就是刚好铺满的那种」）：固定 10 条时，窄窗口一行放 7 个就会出现
  /// 「第一行 7 个 + 第二行 3 个 + 右侧一大片空白」的半行。现在显示条数恒为
  /// `列 × 行`，由 `HotRankLayout` 从可用宽高算出；候选池取接口全量 30 条，
  /// 于是还能「换一批」轮换出一屏之外的条目。
  ///
  /// 点击语义**不是播放**：360kan 不是本应用可播放的站源，点卡片执行的是
  /// 「拿这个片名去各站点搜索」——与原来的词 chips 完全一致，只是换了呈现。
  Widget _buildHotSection() {
    final pool = _hotRanks[_hotTab] ?? const <SearchSuggestItem>[];
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = HotRankLayout.resolve(
          availableWidth: constraints.maxWidth,
          // 头部（标题行 + 类目 tab）占固定高度，网格只能用剩下的。头部被强制成
          // `_hotHeaderHeight`，这个减法才是精确的（否则多算/少算一行）。
          availableHeight: constraints.maxHeight - _hotHeaderHeight,
          poolSize: pool.length,
        );
        final window = hotRankWindow(
          pool,
          offset: _hotOffsets[_hotTab] ?? 0,
          count: layout.itemCount,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: _hotHeaderHeight, child: _buildHotHeader(layout)),
            Expanded(child: _buildHotGrid(layout, window)),
          ],
        );
      },
    );
  }

  /// 头部：标题 + 语义说明 + 「换一批」 + 类目 tab。
  Widget _buildHotHeader(HotRankLayout layout) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 24,
          child: Row(
            children: [
              const Icon(Icons.local_fire_department_outlined, size: 18),
              const SizedBox(width: AppSpace.sm),
              Text('热门推荐', style: theme.textTheme.titleSmall),
              const SizedBox(width: AppSpace.sm),
              // 必须写清楚点卡片是「搜」而不是「播」：卡片带海报很容易被当成
              // 可播条目（本页结果区确实点开即详情），不说明就会误导。
              Expanded(
                child: Text(
                  '点击卡片搜索该片名',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // 「换一批」：从候选池里轮换出**一屏之外**的条目。
              // 池子不比一屏大时换不出新内容，按钮直接不显示（而不是点了没反应）。
              if (layout.canShuffle)
                TextButton.icon(
                  key: const ValueKey('search-hot-shuffle'),
                  onPressed: () => _shuffleHot(layout),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('换一批'),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        SizedBox(
          height: 32,
          child: Row(
            children: [
              for (final category in HotRankCategory.values) ...[
                TagChip(
                  key: ValueKey('search-hot-tab-${category.name}'),
                  label: category.label,
                  selected: _hotTab == category,
                  onTap: () => setState(() => _hotTab = category),
                  selectable: true,
                ),
                const SizedBox(width: AppSpace.sm),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 网格：`columns × rows` 个卡片，恰好铺满可用空间。
  Widget _buildHotGrid(HotRankLayout layout, List<SearchSuggestItem> window) {
    final theme = Theme.of(context);
    if (window.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Text(
            '热门榜单加载失败或为空（断网时可稍后重试）',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return GridView.builder(
      padding: EdgeInsets.zero,
      // 固定行高：铺满计算按 `HotRankMetrics.cardHeight` 算，这里必须用同一个值，
      // 否则算出来的行数与实际显示的行数会不一致（又出现半行/溢出）。
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: layout.columns,
        mainAxisExtent: HotRankMetrics.cardHeight,
        crossAxisSpacing: HotRankMetrics.spacing,
        mainAxisSpacing: HotRankMetrics.spacing,
      ),
      itemCount: window.length,
      itemBuilder: (context, index) {
        final item = window[index];
        return PosterCard(
          key: ValueKey('search-hot-${_hotTab.name}-$index'),
          title: item.title,
          imageUrl: item.cover,
          subtitle: item.subtitle,
          rank: item.rank,
          score: item.score,
          onTap: () => _searchFrom(item.title),
        );
      },
    );
  }

  /// 换一批：把窗口在候选池里前移一屏（`hotRankWindow` 会回绕）。
  void _shuffleHot(HotRankLayout layout) {
    final current = _hotOffsets[_hotTab] ?? 0;
    setState(() => _hotOffsets[_hotTab] = current + layout.itemCount);
  }

  /// 联想下拉面板。
  Widget _buildSuggestPanel() {
    final items = _suggestions ?? const <SearchSuggestItem>[];
    return Material(
      elevation: 6,
      borderRadius: AppRadius.mdAll,
      // Material 的 borderRadius 只圆化自身背景，**不裁剪子控件**：不套
      // ClipRRect 时 ListView 的最后一行会画到圆角外面（实测下拉底部有方角残留）。
      child: ClipRRect(
        borderRadius: AppRadius.mdAll,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(AppSpace.md),
                  child: Text('暂无联想词'),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      key: ValueKey('search-suggest-$index'),
                      dense: true,
                      leading: const Icon(Icons.search, size: 16),
                      title: Text(item.title, maxLines: 1),
                      onTap: () => _searchFrom(item.title),
                    );
                  },
                ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 结果区
  // ---------------------------------------------------------------------------

  Widget _buildResultsArea(MultiSiteSearchOutcome? outcome) {
    if (outcome == null) {
      // 有关键字但还没触发搜索（例如输入了但没回车）。
      return const EmptyState(
        icon: Icons.manage_search_outlined,
        title: '输入关键词开始搜索',
        message: '结果会按站点分组显示，单个站点失败不影响其他站点。',
      );
    }
    if (outcome.cancelled) {
      return const EmptyState(icon: Icons.search_off_outlined, title: '搜索已取消');
    }
    if (outcome.results.isEmpty) {
      if (!outcome.finished) return const LoadingBlock();
      return EmptyState(
        icon: Icons.search_off_outlined,
        title: outcome.succeededCount == 0 && outcome.results.isEmpty
            ? outcome.scoped
                  ? '该范围内没有可搜索的站点'
                  : '当前配置没有可搜索的站点'
            : '没有搜索结果',
        message: outcome.succeededCount == 0 && outcome.results.isEmpty
            ? '或搜索已被取消。'
            : null,
      );
    }
    return SearchResultView(
      // 关键词换代就重建：站点选中态与滚动位置不能跨批次留着，否则换词后
      // 还停在上一批的站点上（这个 State 内的 `_activeSiteKey` 靠 key 换代复位）。
      key: ValueKey('search-results-${outcome.runId}'),
      outcome: outcome,
      keyPrefix: 'search',
      itemKeyOf: (siteKey, vodId) => 'search-result-$siteKey-$vodId',
      subtitleOf: (siteKey, vod) => vod.vodRemarks,
      siteNameOf: _siteNameOf,
      group: _filterGroup,
      onGroupChanged: (value) => setState(() => _filterGroup = value),
      onLoadMore: _state.loadMoreSearch,
      onSimilarityChanged: _persistSimilarity,
      initialSimilarity: _similarity,
      onTapItem: _openItem,
    );
  }

  /// 相似度阈值改了就落盘，同时更新页面侧快照——下一批搜索重建视图时
  /// 要以用户刚选的档位初始化，而不是回到默认值。
  Future<void> _persistSimilarity(int value) async {
    await _state.setSearchSimilarity(value);
    if (!mounted || _similarity == value) return;
    setState(() => _similarity = value);
  }

  /// 结果卡片点开：先按站点 key 取出条目，再走既有的「切站点 + 进详情」。
  Future<void> _openItem(String siteKey, Vod vod) async {
    final entry = _state.activeSearch?.entryOf(siteKey);
    if (entry == null) return;
    await _openResult(entry, vod);
  }
}
