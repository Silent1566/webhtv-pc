/// 「搜索弹幕」大对话框（多弹幕源 S3，`docs/phase9/design/02` §2.3）。
///
/// 与字幕搜索窗口同构：窗口只搬运数据，搜索函数由调用方注入
/// （[DanmakuSearchRunner]），因此可以离屏测试、不触网。
///
/// 与安卓 `DanmakuSearchDialog` 对齐的四件事：来源筛选、倒序、关键词、按剧名
/// 分组折叠。多源之后还必须回答「这条来自哪个源、哪个渠道」——单源时代这两个
/// 问题不存在，所以来源/渠道各占一条筛选行，失败的源在 chip 上带 ⚠ 与原因。
///
/// **视觉层级**（S4）：折叠头、条目、筛选各自承担不同的信息量级，所以三者用
/// 不同底色、不同字号与不同高度的容器区分，而不是靠一行文字的颜色微差——
/// 同色同字号的「折叠头」会被读成一条普通结果，用户扫不出来。
///
/// **逐源增量渲染**（S6）：用户等不起「最慢的那个源」。每个源一回来就把那批
/// 条目并进累计列表并重排重绘，进度条上写「x/N 已完成」；分组/排序仍由
/// `rankDanmakuEntries` + `groupDanmakuEntries` 决定，所以先到的源不会永久霸占
/// 列表顶部，只是先出现在用户眼前。
///
/// **不负责**：拼地址、解析协议、写记忆。协议只有一份实现
/// （`DanmakuLibraryService.searchSources`），分组/渠道/集号只有一份实现
/// （`danmaku_catalog.dart`）——窗口里再抄一遍必然与它们漂移。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/danmaku_catalog.dart';
import '../core/danmaku_match.dart';
import '../core/danmaku_settings.dart';
import '../services/danmaku_library_service.dart';
import 'glass_dialog.dart';
import 'tokens.dart';

/// 设计尺寸：居中大对话框，不是全屏页、不是底部弹层（用户已确认）。
const double _kMaxWidth = 760;
const double _kMaxHeight = 600;

/// 查询行里输入框/按钮/开关的统一高度。
///
/// 底边参差的控件行读起来像没有排版：用户会先注意到「高矮不齐」，
/// 然后才去看控件本身。32 是「点得准、又不比输入框更重」的一档；
/// 搜索按钮、集数排序、仅本集三者共用它，圆角与密度也一并统一。
const double _kControlHeight = 32;

/// 折叠头的高度：它是一条「章节栏」，比条目矮、但要有整块底色。
const double _kGroupHeaderHeight = 36;

/// 条目行高度：标题 + 副标题两行、8px 内边距下的最小可行值。
const double _kEntryRowHeight = 56;

/// 筛选行左侧语义标签的宽度。
///
/// 「来源」「渠道」两个中文字在 labelSmall 下刚好放下；固定宽度让两条筛选行的
/// chip 起点对齐，否则两行看上去是两套不相干的控件。
const double _kFilterLabelWidth = 32;

/// 搜索函数签名。注入它是本窗口不触网的唯一方式。
///
/// [onSourceResult] 与 `DanmakuLibraryService.searchSources` 同名同义：逐源完成
/// 即回调，窗口据此增量渲染。它是可选的——只返回总结果的实现（测试替身、未来的
/// 其它后端）照样能用，窗口会在总结果回来时把状态补齐。
typedef DanmakuSearchRunner = Future<DanmakuLibraryQueryResult> Function({
  required List<DanmakuSourceConfig> sources,
  required String title,
  String? episode,
  void Function(
    DanmakuLibrarySourceResult result,
    List<DanmakuLibraryEntry> entries,
  )?
  onSourceResult,
});

/// 打开搜索对话框；选中条目返回它，取消返回 null。
///
/// 打开即按 [initialKeyword] ?? [query] 的剧名自动搜一次——用户点「搜索弹幕…」
/// 的意图就是「找这一集」，再让人先点一次搜索是多余的一步。
Future<DanmakuLibraryEntry?> showDanmakuSearchDialog({
  required BuildContext context,
  required List<DanmakuSourceConfig> sources,
  required DanmakuQuery query,
  String? initialKeyword,
  DanmakuSearchRunner? runner,
  String? currentUrl,
  bool blurBackdrop = true,
}) {
  return showGlassDialog<DanmakuLibraryEntry>(
    context: context,
    builder: (context) => DanmakuSearchDialog(
      sources: sources,
      query: query,
      initialKeyword: initialKeyword,
      runner: runner ?? _serviceRunner(),
      currentUrl: currentUrl,
      blurBackdrop: blurBackdrop,
    ),
  );
}

/// 默认 runner：每次搜索新建服务并在结束时关闭。
///
/// 不能复用同一个 `DanmakuLibraryService` 实例：[DanmakuLibraryService.close]
/// 会关掉它持有的 http client，第二次搜索只会拿到「client 已关闭」的异常。
DanmakuSearchRunner _serviceRunner() {
  return ({
    required List<DanmakuSourceConfig> sources,
    required String title,
    String? episode,
    void Function(
      DanmakuLibrarySourceResult result,
      List<DanmakuLibraryEntry> entries,
    )?
    onSourceResult,
  }) async {
    final service = DanmakuLibraryService();
    try {
      return await service.searchSources(
        sources: sources,
        title: title,
        episode: episode,
        // 透传而不是在窗口里重写一遍：逐源回调的语义只有服务层一份实现。
        onSourceResult: onSourceResult,
      );
    } finally {
      service.close();
    }
  };
}

class DanmakuSearchDialog extends StatefulWidget {
  const DanmakuSearchDialog({
    super.key,
    required this.sources,
    required this.query,
    required this.runner,
    this.initialKeyword,
    this.currentUrl,
    this.blurBackdrop = true,
  });

  /// 参与搜索的源（调用方已过滤 enabled + 地址合法）。
  final List<DanmakuSourceConfig> sources;

  /// 当前播放的查询：提供打分用的剧名与「本集」用的集名。
  final DanmakuQuery query;

  final DanmakuSearchRunner runner;
  final String? initialKeyword;

  /// 播放器当前已加载的那条弹幕地址；命中就标「当前」。空 = 没有正在使用的弹幕。
  final String? currentUrl;
  final bool blurBackdrop;

  @override
  State<DanmakuSearchDialog> createState() => _DanmakuSearchDialogState();
}

class _DanmakuSearchDialogState extends State<DanmakuSearchDialog> {
  late final TextEditingController _keyword;

  /// 累计条目（按 url 去重），**增量**追加：哪个源先回来，它那批就先在这里。
  ///
  /// 不直接存 `DanmakuLibraryQueryResult`：总结果是「全部源都回来」之后才有的，
  /// 存它等于把渲染时机又绑回最慢的那个源。
  final List<DanmakuLibraryEntry> _entries = <DanmakuLibraryEntry>[];

  /// [_entries] 已收录的 url，去重用它做 O(1) 判定（同一个地址可能出现在多个源里）。
  final Set<String> _entryUrls = <String>{};

  /// 逐源记账（源 id → 结果），供来源 chip 的「· N / ⚠」与失败提示带使用。
  final Map<String, DanmakuLibrarySourceResult> _statuses =
      <String, DanmakuLibrarySourceResult>{};

  /// 已完成的源数 / 本次参与搜索的源数；进度条与「全部完成」判定都读它们。
  int _completed = 0;
  int _total = 0;

  /// 已打分的条目：排名只在条目集合变化时算一次，筛选/折叠/倒序都复用它。
  List<DanmakuLibraryEntry> _ranked = const [];

  bool _searching = false;
  String? _error;

  /// 倒序（集号降序）；默认正序。
  bool _reverse = false;

  /// 仅本集；默认关（看到整部剧的分布才知道「本集确实没有」还是「搜错了片」）。
  bool _currentOnly = false;

  /// 来源筛选：源 id；null = 全部来源。
  String? _sourceFilter;

  /// 渠道筛选：归一化后的渠道名；null = 全部渠道。
  String? _channelFilter;

  /// 用户手动点过的分组（组标题 → 是否展开）；优先于默认展开。
  ///
  /// 记「展开状态」而不是「折叠集合」：默认展开是「只展开当前那一组」，
  /// 用折叠集合表达时，「用户把它点开」与「它本来就不在折叠集合里」分不开。
  final Map<String, bool> _expanded = <String, bool>{};

  /// 本次搜索的默认展开组；null = 没有命中「当前」条目，全部展开。
  Set<String>? _defaultExpanded;

  /// 默认展开是否已经定过：每次搜索只定一次（第一批结果到达时）。
  bool _defaultResolved = false;

  /// 「当前」那条所在行，滚动定位用；行本身另有稳定的 ValueKey。
  final GlobalKey _currentRowKey = GlobalKey();

  /// 本次搜索是否已经为「当前」那条滚过一次：只滚一次，不打断用户后续滚动。
  bool _scrolledToCurrent = false;

  @override
  void initState() {
    super.initState();
    _keyword = TextEditingController(
      text: widget.initialKeyword ?? widget.query.title,
    );
    // 打开即搜一次。起始 loading 直接置位：initState 里设它没有 setState 的意义
    // （本帧尚未构建），结果回来时才需要通知界面。
    if (widget.sources.isNotEmpty && _keyword.text.trim().isNotEmpty) {
      _resetSearchState();
      unawaited(_fetch());
    }
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  /// 清空上一次搜索的累计状态。
  ///
  /// 必须清：重搜时若把上一次的条目留在 [_entries] 里，用户会看到新旧两批混在
  /// 一起，而且旧条目还带着旧关键词的匹配分。
  void _resetSearchState() {
    _entries.clear();
    _entryUrls.clear();
    _statuses.clear();
    _completed = 0;
    _total = widget.sources.length;
    _ranked = const [];
    _error = null;
    _searching = true;
    // 默认展开属于**这一次**搜索：换关键词后用户面对的是另一批候选，
    // 上一次「只展开当前那一组」的结论不能带过来。
    _expanded.clear();
    _defaultExpanded = null;
    _defaultResolved = false;
    _scrolledToCurrent = false;
  }

  /// 该组此刻是否折叠。
  ///
  /// 用户点过的组以 [_expanded] 为准；没点过的组回到本次搜索的默认展开——
  /// [_defaultExpanded] 为 null 表示「没有当前条目，全部展开」，否则只展开命中的
  /// 那一组。默认值只定一次，所以增量到达的新组不会把用户已经点开的组又收起来。
  bool _isCollapsed(String title) {
    final manual = _expanded[title];
    if (manual != null) return !manual;
    final defaults = _defaultExpanded;
    if (defaults == null) return false;
    return !defaults.contains(title);
  }

  /// 第一批结果到达后定下默认展开状态（每次搜索只定一次）。
  ///
  /// 命中「当前」那条时**只**展开它所在组：同名不同年的另一部剧不是「我此刻在听
  /// 的那条」，默认展开会让用户以为候选都跟当前这条同源，还得自己一组组收起。
  /// 没命中就全部展开（保持旧行为）——此时没有「哪一组更重要」的依据，藏起来只会
  /// 让用户以为没搜到。
  void _resolveDefaultExpansion() {
    if (_defaultResolved) return;
    _defaultResolved = true;
    final url = _currentUrl;
    if (url == null) return;
    for (final entry in _entries) {
      if (entry.url != url) continue;
      _defaultExpanded = {
        danmakuTitleKeyOf(entry.title) ?? kDanmakuUnclassifiedTitle,
      };
      _scrollToCurrent();
      return;
    }
  }

  /// 把「当前」那条滚进可见区域；每次搜索只滚一次。
  ///
  /// 必须等这一帧渲染完：此刻行还没建出来，[GlobalKey.currentContext] 是空的。
  /// 只滚一次是因为这之后视口属于用户——再滚就是抢他的滚动条。
  void _scrollToCurrent() {
    if (_scrolledToCurrent) return;
    _scrolledToCurrent = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rowContext = _currentRowKey.currentContext;
      if (!mounted || rowContext == null) return;
      // alignment 0.3：命中行落在视口偏上三分之一处，上方还留着分组头，
      // 用户一眼能看出「这一条属于哪部剧」，而不是一条孤零零的行贴着顶边。
      Scrollable.ensureVisible(rowContext, alignment: 0.3);
    });
  }

  Future<void> _submit() async {
    if (_searching) return;
    if (_keyword.text.trim().isEmpty) return;
    setState(_resetSearchState);
    await _fetch();
  }

  /// 逐源回调：一个源回来就把它那批并进累计列表，并立刻重排重绘。
  ///
  /// 排序/分组仍走 [rankDanmakuEntries]/[groupDanmakuEntries]，所以「先到的源」
  /// 只影响出现时间，不影响列表顺序——否则每次搜索的列表顺序都会随网络抖动而变。
  void _onSourceResult(
    DanmakuLibrarySourceResult result,
    List<DanmakuLibraryEntry> entries,
  ) {
    if (!mounted) return;
    setState(() {
      _statuses[result.id] = result;
      if (_completed < _total) _completed++;
      _mergeEntries(entries);
      _ranked = rankDanmakuEntries(entries: _entries, query: widget.query);
      _resolveDefaultExpansion();
    });
  }

  /// 把一批条目并入累计列表（按 url 去重）；已存在的 url 原样保留先到的那条。
  void _mergeEntries(Iterable<DanmakuLibraryEntry> entries) {
    for (final entry in entries) {
      if (!_entryUrls.add(entry.url)) continue;
      _entries.add(entry);
    }
  }

  /// 真正发请求：调用注入的 runner，把总结果并入累计状态。
  Future<void> _fetch() async {
    final keyword = _keyword.text.trim();
    DanmakuLibraryQueryResult? result;
    String? failure;
    try {
      result = await widget.runner(
        sources: widget.sources,
        title: keyword,
        episode: widget.query.episode,
        onSourceResult: _onSourceResult,
      );
    } catch (error) {
      // 注入的 runner 抛异常时必须落回一个可见状态，否则窗口永远停在「正在搜索」。
      failure = error.toString();
    }
    if (!mounted) return;
    // 总结果仍是权威：runner 没调 onSourceResult（测试替身/其它后端）时，界面
    // 只能靠它补齐状态，否则进度条会永远停在 x/N 上。
    final queryResult = result;
    if (queryResult != null) {
      for (final source in queryResult.sources) {
        _statuses[source.id] = source;
      }
      _mergeEntries(queryResult.entries);
      if (_total < _statuses.length) _total = _statuses.length;
      _completed = _total;
      _ranked = rankDanmakuEntries(entries: _entries, query: widget.query);
      _resolveDefaultExpansion();
    }
    setState(() {
      _searching = false;
      _error = failure;
    });
  }

  /// 「仅本集」用的目标集号；query 没有集名或解析不出时为 null（= 不筛）。
  int? get _targetEpisode => danmakuEpisodeOf(widget.query.episode ?? '');

  /// 条目的集号；优先 episode 字段（标题里的年份会被数字兜底误读成集号）。
  int? _episodeOf(DanmakuLibraryEntry entry) {
    final text = entry.episode.trim().isNotEmpty ? entry.episode : entry.title;
    return danmakuEpisodeOf(text);
  }

  /// 通过来源/渠道/仅本集三重筛选后的条目。
  List<DanmakuLibraryEntry> get _visible {
    final target = _currentOnly ? _targetEpisode : null;
    final visible = <DanmakuLibraryEntry>[];
    for (final entry in _ranked) {
      if (_sourceFilter != null && entry.libraryId != _sourceFilter) continue;
      if (_channelFilter != null && entry.channel != _channelFilter) continue;
      if (target != null) {
        final episode = _episodeOf(entry);
        // 任一侧解析不出集号时不排除：解析失败不等于「不是本集」，
        // 拿解析失败当过滤依据会把能用的候选静默藏掉。
        if (episode != null && episode != target) continue;
      }
      visible.add(entry);
    }
    return visible;
  }

  /// 渠道筛选项：取自**全部**结果而不是筛选后的结果，否则选中一个源之后
  /// 其它渠道的 chip 会整排消失，用户再也切不回去。
  List<String> get _channels {
    final channels = <String>{};
    for (final entry in _ranked) {
      final channel = entry.channel.trim();
      if (channel.isNotEmpty) channels.add(channel);
    }
    return channels.toList()..sort();
  }

  DanmakuLibrarySourceResult? _statusOf(String id) => _statuses[id];

  /// 本次失败的源（按**配置顺序**遍历而不是回调顺序：提示条里的源名次序
  /// 不能随网络的快慢跳动）。
  List<DanmakuLibrarySourceResult> get _failedSources {
    final failures = <DanmakuLibrarySourceResult>[];
    for (final source in widget.sources) {
      final status = _statuses[source.id];
      if (status != null && !status.ok) failures.add(status);
    }
    return failures;
  }

  /// 当前正在使用的弹幕地址；空串/未配置时视为「没有」。
  String? get _currentUrl {
    final url = widget.currentUrl?.trim() ?? '';
    return url.isEmpty ? null : url;
  }

  /// 当前在用的那条弹幕所属的源 id（来源 chip 上补「· 当前」用）。
  String? get _currentLibraryId {
    final url = _currentUrl;
    if (url == null) return null;
    for (final entry in _entries) {
      if (entry.url == url) return entry.libraryId;
    }
    return null;
  }

  /// 空结果时的失败说明：把「哪个源为什么没回」写出来，
  /// 而不是把「源挂了」说成「没有弹幕」。
  String? get _failureDetails {
    final failures = _failedSources;
    if (failures.isEmpty) return null;
    final items = [
      for (final source in failures)
        '${source.name}（${source.error ?? '未知原因'}）',
    ];
    return '失败的源：${items.join('、')}';
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // 小屏收缩而不是溢出：insetPadding 已留出一份边距，这里按屏幕再算一份。
    final width = media.size.width - AppSpace.xl * 2 < _kMaxWidth
        ? media.size.width - AppSpace.xl * 2
        : _kMaxWidth;
    final height = media.size.height - AppSpace.xl * 2 < _kMaxHeight
        ? media.size.height - AppSpace.xl * 2
        : _kMaxHeight;
    final visible = _visible;
    // 分组在这里算**一次**：标题行的「展开全部/折叠全部」要知道「现在是不是全都
    // 折叠了」，结果列表要知道怎么摆，各算一份就会在两处漂移。
    final groups = visible.isEmpty
        ? const <DanmakuGroup>[]
        : groupDanmakuEntries(
            entries: visible,
            reverse: _reverse,
            // 传 query：组间按多维相似度（名称/年份/季/类型）排序——用户第一屏
            // 看到的就该是最像本集的那部剧，而不是先到的源先占位。
            query: widget.query,
          );
    return glassDialogShell(
      context,
      blurBackdrop: widget.blurBackdrop,
      insetPadding: const EdgeInsets.all(AppSpace.xl),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _titleRow(context, groups),
            _queryRow(context),
            if (_searching) _loadingStrip(context),
            _filters(context),
            const Divider(height: 1),
            Expanded(child: _body(context, visible, groups)),
          ],
        ),
      ),
    );
  }

  Widget _titleRow(BuildContext context, List<DanmakuGroup> groups) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.sm,
        0,
      ),
      child: Row(
        children: [
          Text(
            '搜索弹幕',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: AppWeight.title,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            // 规模概览是「这次搜索的上下文」，不是结果本身：做小做淡、右对齐，
            // 不与条目的视觉权重竞争。
            child: Text(
              // 跟着增量实时更新：用户在等结果时要能看出「还在进来」，
              // 而不是盯着一句不动的话猜是不是卡住了。
              _total == 0
                  ? ''
                  : '${widget.sources.length} 个源 · ${_entries.length} 条结果',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _toggleAllButton(context, groups),
          IconButton(
            key: const ValueKey('danmaku-search-close'),
            tooltip: '关闭',
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// 一键「全部展开 ↔ 全部折叠」。
  ///
  /// 默认只展开「当前」那一组时，用户想通读全部候选就得一组一组点，这里给一次
  /// 点击的出口。它只覆盖**当前可见的分组**，既不改本次搜索的默认展开，也不影响
  /// 下一次搜索——「默认」与「临时全开」是两件事，混用会让下次打开莫名全折叠。
  Widget _toggleAllButton(BuildContext context, List<DanmakuGroup> groups) {
    final allCollapsed =
        groups.isNotEmpty && groups.every((group) => _isCollapsed(group.title));
    return IconButton(
      key: const ValueKey('danmaku-search-toggle-all'),
      tooltip: allCollapsed ? '展开全部' : '折叠全部',
      // 与查询行同高一档（32）并压掉 IconButton 默认的 48 点击区：
      // 它是标题行里的次要便利操作，不能把标题行撑高、也不能抢关闭按钮的位置。
      constraints: const BoxConstraints.tightFor(
        width: _kControlHeight,
        height: _kControlHeight,
      ),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      onPressed: groups.isEmpty
          ? null
          : () => setState(() {
              for (final group in groups) {
                _expanded[group.title] = allCollapsed;
              }
            }),
      // 图标表示「点了会发生什么」：全折叠时给展开（unfold_more），否则给折叠。
      icon: Icon(allCollapsed ? Icons.unfold_more : Icons.unfold_less),
    );
  }

  Widget _queryRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: Row(
        // 三个控件同高、同一圆角、同一密度：之前一个实心按钮、一个纯文字、
        // 一个深色胶囊，底边参差且视觉重量差三档，读起来像三套不相干的控件。
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: SizedBox(
              height: _kControlHeight,
              child: TextField(
                key: const ValueKey('danmaku-search-keyword'),
                controller: _keyword,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '剧名 / 关键词',
                  // 上下各 AppSpace.xs：isDense + 这一档内边距才刚好落在
                  // _kControlHeight 里，输入框与旁边按钮的底边对齐。
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: AppSpace.xs,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          SizedBox(
            height: _kControlHeight,
            child: FilledButton(
              key: const ValueKey('danmaku-search-submit'),
              onPressed: _searching ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size(72, _kControlHeight),
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                shape: const RoundedRectangleBorder(
                  borderRadius: AppRadius.smAll,
                ),
              ),
              child: const Text('搜索'),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          _orderChip(context),
          const SizedBox(width: AppSpace.sm),
          _currentOnlyChip(context),
        ],
      ),
    );
  }

  /// 集数排序开关：文案直接写出排的是什么。
  ///
  /// 「正序/倒序」没说排的是什么，也没说默认是哪种——用户的第一反应是
  /// 「集数没默认排序吗」。所以标签写成「集数 ↑」（默认，数值升序）与
  /// 「集数 ↓」，选中态用实心底表示当前是倒序，箭头与底色两处同向表达。
  Widget _orderChip(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _kControlHeight,
      child: Tooltip(
        message: '按集号排序',
        child: FilterChip(
          key: const ValueKey('danmaku-search-order'),
          label: Text(_reverse ? '集数 ↓' : '集数 ↑'),
          labelStyle: theme.textTheme.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          selectedColor: theme.colorScheme.primaryContainer,
          selected: _reverse,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
          onSelected: (_) => setState(() => _reverse = !_reverse),
        ),
      ),
    );
  }

  /// 「仅本集」：与排序开关同形同高，但语义是筛选，所以默认不选中。
  Widget _currentOnlyChip(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: _kControlHeight,
      child: FilterChip(
        key: const ValueKey('danmaku-search-current-only'),
        label: const Text('仅本集'),
        labelStyle: theme.textTheme.labelLarge,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
        selectedColor: theme.colorScheme.primaryContainer,
        selected: _currentOnly,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        onSelected: (_) => setState(() => _currentOnly = !_currentOnly),
      ),
    );
  }

  Widget _loadingStrip(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('danmaku-search-loading'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        AppSpace.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 2,
            child: LinearProgressIndicator(
              minHeight: 2,
              // 逐源完成是离散事件，给的进度就是真的 x/N，不必用无限滚动条。
              value: _total == 0 ? null : _completed / _total,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            '正在搜索 ${widget.sources.length} 个源… $_completed/'
            '${_total == 0 ? widget.sources.length : _total} 已完成',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _filters(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _filterLine(context, '来源', [
            _chip(
              keyName: 'danmaku-search-source-all',
              label: '全部来源',
              selected: _sourceFilter == null,
              onTap: () => setState(() => _sourceFilter = null),
            ),
            for (final source in widget.sources) _sourceChip(source),
          ]),
          const SizedBox(height: AppSpace.xs),
          _filterLine(context, '渠道', [
            _chip(
              keyName: 'danmaku-search-channel-all',
              label: '全部渠道',
              selected: _channelFilter == null,
              onTap: () => setState(() => _channelFilter = null),
            ),
            for (final channel in _channels)
              _chip(
                keyName: 'danmaku-search-channel-$channel',
                label: channel,
                selected: _channelFilter == channel,
                onTap: () => setState(() => _channelFilter = channel),
              ),
          ]),
        ],
      ),
    );
  }

  /// 一条筛选行：固定宽度的语义标签 + 横向滚动的 chip 轨道。
  ///
  /// 横向滚动而不是 Wrap 换行：源多起来以后换行会把结果区挤没，
  /// 而且「来源」「渠道」一旦各占两三行，标签就对不上各自那一排 chip 了。
  Widget _filterLine(BuildContext context, String label, List<Widget> chips) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: _kFilterLabelWidth,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < chips.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpace.sm),
                  chips[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _chip({
    required String keyName,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    // 固定 28 高：两排 chip 是同一层的「筛选器」，靠 chip 自身的内边距让高度
    // 上下浮动，会让同一排里出现高矮差；也和查询行的 32 拉开一档层级。
    return SizedBox(
      height: 28,
      child: ChoiceChip(
        key: ValueKey(keyName),
        label: ConstrainedBox(
          // 源 id 常常就是一条地址：不设上限会把整排 chip 撑成一行超长文本。
          constraints: const BoxConstraints(maxWidth: 180),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        labelStyle: theme.textTheme.labelSmall,
        // 选中态用实心 primaryContainer：全站 chipTheme 的 18% primary 淡染在
        // 这个对话框的 surfaceContainerHigh 底上几乎看不出「已选」，
        // 而这两排 chip 一按就换掉整份结果，选中态必须一眼可见。
        selectedColor: theme.colorScheme.primaryContainer,
        selected: selected,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: (_) => onTap(),
      ),
    );
  }

  /// 来源 chip 上带该源的结果数与失败标记。
  ///
  /// 「失败」和「0 条」是两件事：源超时说明配置有问题，0 条说明这个源确实没有
  /// 这部剧。只看一个空的候选列表分不开它们，所以两个信息都摆在 chip 上。
  Widget _sourceChip(DanmakuSourceConfig source) {
    final status = _statusOf(source.id);
    final failed = status != null && !status.ok;
    final label = StringBuffer(source.name);
    if (status != null) label.write(failed ? ' ⚠' : ' · ${status.count}');
    // 当前在用的那条挂在这个源上时补一句：只标行不标源，用户还得自己回头
    // 比对「这条到底来自哪个源」。
    if (_currentLibraryId == source.id) label.write(' · 当前');
    final chip = _chip(
      keyName: 'danmaku-search-source-${source.id}',
      label: label.toString(),
      selected: _sourceFilter == source.id,
      onTap: () => setState(() => _sourceFilter = source.id),
    );
    if (!failed) return chip;
    return Tooltip(
      message: '${source.name}：${status.error ?? '搜索失败'}',
      child: chip,
    );
  }

  Widget _body(
    BuildContext context,
    List<DanmakuLibraryEntry> visible,
    List<DanmakuGroup> groups,
  ) {
    if (widget.sources.isEmpty) {
      return _hintState(
        context,
        stateKey: const ValueKey('danmaku-search-empty'),
        icon: Icons.dns_outlined,
        title: '未配置弹幕源',
        message: '可在「设置 → 弹幕 → 弹幕源」填写地址，或由站点配置 danmaku 字段提供。',
      );
    }
    final error = _error;
    if (error != null) {
      return _hintState(
        context,
        stateKey: const ValueKey('danmaku-search-empty'),
        icon: Icons.error_outline,
        title: '搜索失败，请稍后重试',
        message: error,
      );
    }
    // 一次都还没搜过（关键词为空）：此时连「完成了几个源」都没有意义。
    if (_total == 0 && !_searching) {
      return _hintState(
        context,
        stateKey: const ValueKey('danmaku-search-empty'),
        icon: Icons.search,
        title: '输入关键词开始搜索',
      );
    }
    final failures = _failedSources;
    // 全部失败和「没有弹幕」是两件事，混成一句会把配置问题说成片源问题。
    // 只在「全部源都已完成」时才成立：增量渲染时先回来的一个源失败了，
    // 不等于其它还在路上的源也会失败。
    if (!_searching &&
        _completed >= _total &&
        failures.isNotEmpty &&
        failures.length == _statuses.length) {
      return _hintState(
        context,
        stateKey: const ValueKey('danmaku-search-empty'),
        icon: Icons.cloud_off,
        title: '所有弹幕源都失败了',
        details: [
          for (final source in failures.take(4))
            '${source.name}：${source.error ?? '未知原因'}',
        ],
      );
    }
    // 还在搜、且一个源都还没回来：这一块是空的，但不能写「没有找到弹幕」——
    // 「还没回来」不是结论。进度条已经在上方说明状态。
    if (_entries.isEmpty) {
      if (_searching) return const SizedBox.shrink();
      return _hintState(
        context,
        stateKey: const ValueKey('danmaku-search-empty'),
        icon: Icons.search_off,
        title: '没有找到弹幕',
        message: _failureDetails ?? '换个关键词，或检查弹幕源配置',
      );
    }
    if (visible.isEmpty) {
      return _hintState(
        context,
        stateKey: const ValueKey('danmaku-search-empty'),
        icon: Icons.filter_alt_off,
        title: '当前筛选无结果',
      );
    }
    final list = _results(context, groups);
    if (failures.isEmpty) return list;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _failureBanner(context, failures),
        Expanded(child: list),
      ],
    );
  }

  /// 部分失败：成功结果的列表照常，只在上面留一条 28px 的提示带——
  /// 少一个源的结果会让用户误判「就这些」，但也不该把剩余结果顶掉。
  Widget _failureBanner(
    BuildContext context,
    List<DanmakuLibrarySourceResult> failures,
  ) {
    final theme = Theme.of(context);
    // 间距放在外层 Padding 上：提示条本身保持 28 高的整条色块，
    // 一旦用 margin 撑开，色块的可见高度就不是 28 了。
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.xs,
        AppSpace.lg,
        AppSpace.xs,
      ),
      child: Container(
        key: const ValueKey('danmaku-search-failures'),
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: AppRadius.smAll,
        ),
        child: Text(
          '${failures.length} 个源失败：${failures.map((s) => s.name).join('、')}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }

  /// 对话框内的空/错误/全失败态：32 的图标 + 一行结论 + 可选的说明。
  ///
  /// 不用 `EmptyState`：那是页面级空态（40 图标 + titleMedium），
  /// 放进对话框比标题还重，层级就反了。
  Widget _hintState(
    BuildContext context, {
    required Key stateKey,
    required IconData icon,
    required String title,
    String? message,
    List<String> details = const [],
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      key: stateKey,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 32,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: AppWeight.title,
                color: scheme.onSurface,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpace.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            for (final line in details) ...[
              const SizedBox(height: AppSpace.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Text(
                  line,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _results(BuildContext context, List<DanmakuGroup> groups) {
    // 行索引跨组连续：折叠只隐藏行、不改变其余行的 key，
    // 否则每次折叠都会让下半屏的 key 整体错位。
    var index = 0;
    final children = <Widget>[];
    for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
      final group = groups[groupIndex];
      if (groupIndex > 0) children.add(const SizedBox(height: AppSpace.sm));
      children.add(_groupHeader(context, groupIndex, group));
      if (_isCollapsed(group.title)) {
        index += group.entries.length;
        continue;
      }
      for (var i = 0; i < group.entries.length; i++) {
        // 1px 分隔线：行高 56 已经够松，靠线而不是靠更多空白维持每行一档的节奏。
        if (i > 0) children.add(const SizedBox(height: 1));
        // 传整组而不是单条：集名清洗要靠组名剥掉重复的剧名前缀。
        children.add(_entryRow(context, index++, group, group.entries[i]));
      }
    }
    return ListView(
      key: const ValueKey('danmaku-search-results'),
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      children: children,
    );
  }

  /// 分组头：整行底色 + 折叠箭头 + 加粗标题 + 尾部「· N 集」。
  ///
  /// 它和条目必须一眼可辨：底色（surfaceContainerHigh）、字号（titleSmall）、
  /// 高度（36）三处都不同，只靠颜色微差是不够的。
  Widget _groupHeader(BuildContext context, int index, DanmakuGroup group) {
    final theme = Theme.of(context);
    final collapsed = _isCollapsed(group.title);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      child: InkWell(
        key: ValueKey('danmaku-search-group-$index'),
        borderRadius: AppRadius.smAll,
        onTap: () => setState(() {
          // 一次点击就把这一组钉在用户选的状态上：增量结果陆续到达时，
          // 用户刚点开的组不能被「默认展开」又收回去。
          _expanded[group.title] = _isCollapsed(group.title);
        }),
        child: Ink(
          height: _kGroupHeaderHeight,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: AppRadius.smAll,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
            child: Row(
              children: [
                Icon(
                  collapsed ? Icons.expand_more : Icons.expand_less,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: Text(
                    group.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: AppWeight.title,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Text(
                  '· ${group.entries.length} 集',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_allEpisodesUnknown(group)) ...[
                  const SizedBox(width: AppSpace.xs),
                  // 一条集号都解析不出来时，组内只能按原顺序摆——不说一句
                  // 用户会以为是排序坏了。做淡：它是说明，不是结论。
                  Text(
                    '· 未识别集号',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 组内是否一条集号都解析不出来。
  ///
  /// 判据与组内排序一致（优先 episode 字段，其次标题）：这里说「全都没集号」
  /// 而排序那边认出了集号，用户就会看到「有集号却说未识别」的自相矛盾。
  bool _allEpisodesUnknown(DanmakuGroup group) {
    if (group.entries.isEmpty) return false;
    for (final entry in group.entries) {
      if (_episodeOf(entry) != null) return false;
    }
    return true;
  }

  /// 条目行：清洗后的集名 + [渠道徽章 · 来源库 · N 条 … 分数]。
  Widget _entryRow(
    BuildContext context,
    int index,
    DanmakuGroup group,
    DanmakuLibraryEntry entry,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final library = entry.libraryName.trim().isEmpty
        ? (entry.libraryId.trim().isEmpty ? '未知来源' : entry.libraryId.trim())
        : entry.libraryName.trim();
    final channel = entry.channel.trim();
    final isCurrent = _currentUrl != null && entry.url == _currentUrl;
    return Padding(
      // 「当前」这行额外挂一个 GlobalKey：滚动定位需要能取到具体 RenderObject 的
      // 句柄，而它自身的 ValueKey（行索引）是给测试与重建用的，不能兼作定位。
      key: isCurrent ? _currentRowKey : null,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      child: InkWell(
        key: ValueKey('danmaku-search-entry-$index'),
        borderRadius: AppRadius.smAll,
        hoverColor: scheme.surfaceContainerHighest,
        onTap: () => Navigator.of(context).pop(entry),
        child: SizedBox(
          height: _kEntryRowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _cleanEpisode(
                    entry.episode,
                    // 「未分类」的组名是一个兜底桶，不是剧名：拿它当剧名去剥
                    // 前缀只会误伤，所以那一档退回条目自己的清洗结果。
                    groupTitle: group.isUnclassified ? null : group.title,
                    entryTitle: entry.title,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.2),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (channel.isNotEmpty) ...[
                      _channelBadge(context, channel),
                      const SizedBox(width: AppSpace.sm),
                    ],
                    // 库名用 Expanded 吃掉剩余宽度：Flexible 与 Spacer 会按 flex
                    // 平分剩余空间，分数就被推到行中间而不是右端（截图实测）。
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              library,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (entry.count > 0)
                            Text(
                              ' · ${entry.count} 条',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    // 「当前」贴在分数左侧：分数是行的右端锚点，徽章挤到它右边
                    // 会让每行的右边界参差。
                    if (isCurrent) ...[
                      _currentBadge(context, index),
                      const SizedBox(width: AppSpace.xs),
                    ],
                    // 分数只在有值时出现：它是排序依据，不是每行都要念一遍的字段。
                    if (entry.score > 0)
                      Text(
                        entry.score.toStringAsFixed(1),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「当前」徽章：播放器已经加载的那一条。
  ///
  /// 用 primary 实心而不是又一个 secondaryContainer 小胶囊：它回答的是
  /// 「我此刻在听哪条弹幕」，比渠道这种分类标签更高一档，不能被扫成一类东西。
  Widget _currentBadge(BuildContext context, int index) {
    final theme = Theme.of(context);
    return Container(
      key: ValueKey('danmaku-search-current-$index'),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        '当前',
        maxLines: 1,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimary,
        ),
      ),
    );
  }

  /// 渠道徽章：渠道是「分类标签」而不是一行正文，用小胶囊把它和来源库分开。
  Widget _channelBadge(BuildContext context, String channel) {
    final theme = Theme.of(context);
    return Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        channel,
        maxLines: 1,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

/// 年份括注：(2026)/(（2026）)——组名里的年份是「同名不同剧」的区分依据，
/// 但集名里只会写剧名本身，剥前缀时要先把它去掉。
final RegExp _yearAnnotationPattern = RegExp(r'[(（]\s*(?:19|20)\d{2}\s*[)）]');

/// 剧名与集名之间可能残留的分隔符。
final RegExp _leadingSeparatorPattern = RegExp(r'^[\s\-－—~～·:：、]+');

/// 任何数字：用来判断「剥完剧名之后还剩没剩下集号」。
final RegExp _digitPattern = RegExp(r'\d');

/// 显式集号标记（第N集/话/期、EP03、S02E07）：有它就不必再按数字切。
final RegExp _episodeMarkPattern = RegExp(
  r'第\s*\d+\s*[集话期]|EP\s*\d+|S\d+\s*E\d+',
  caseSensitive: false,
);

/// 去掉集名开头的【…】/[…] 渠道标签与重复的剧名前缀。
///
/// 弹幕库的集名常常是 `【bilibili1】 第001话` 或 `一马当先 第1集`：渠道已经在
/// 副标题的徽章里出现、剧名已经在折叠头上出现，同一行里说三遍只是噪声。
///
/// 两处回退都是为了「不要把有意义的名字剥空」：
/// - 整行都是标签 → 回退原值（宁可重复，也不要一行空白）；
/// - 剥掉剧名后不含任何数字 → 回退剥之前（`幕后花絮` 剥成空串反而看不懂）。
String _cleanEpisode(String raw, {String? groupTitle, String? entryTitle}) {
  final original = raw.trim();
  var text = _stripLeadingMarks(original);
  if (text.isEmpty) return original;

  // 没有组上下文（未分类）时退回条目自己的清洗结果：那才是这一行所属的剧名。
  final title = _titleWithoutYear(
    groupTitle ?? danmakuTitleKeyOf(entryTitle ?? ''),
  );
  if (title != null && text.startsWith(title)) {
    var rest = text
        .substring(title.length)
        .replaceFirst(_leadingSeparatorPattern, '');
    if (!_digitPattern.hasMatch(rest)) return text;
    // `一马当先行大运01`：剧名之后先是一段集名、集号在数字处。已经带「第N集」
    // 这类标记时保留原样——标记本身就是集号，从数字切会把「第」也切掉。
    if (!_episodeMarkPattern.hasMatch(rest)) {
      final digit = _digitPattern.firstMatch(rest)!;
      if (digit.start > 0) rest = rest.substring(digit.start);
    }
    text = rest.trim();
  }
  return text.isEmpty ? original : text;
}

/// 反复剥掉开头连续的【…】/[…] 标记（一条名字前可能挂好几个）。
String _stripLeadingMarks(String text) {
  var value = text;
  while (true) {
    final stripped = value.replaceFirst(
      RegExp(r'^(?:【[^】]*】|\[[^\]]*\])\s*'),
      '',
    );
    if (stripped == value) break;
    value = stripped;
  }
  return value.trim();
}

/// 去掉年份括注后的剧名；空串返回 null（没有可剥的前缀）。
String? _titleWithoutYear(String? title) {
  final value = (title ?? '').trim();
  if (value.isEmpty) return null;
  final bare = value.replaceAll(_yearAnnotationPattern, '').trim();
  return bare.isEmpty ? null : bare;
}
