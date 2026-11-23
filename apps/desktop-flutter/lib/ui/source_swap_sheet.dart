/// 换源浮层：把「当前详情页这部片在别的站点上的同一个片」列出来、逐条解析
/// 线路、把用户勾选并解析成功的线路交还给调用方去并入线路列表。
///
/// 这个浮层**不认识** app_state / browse_pages：它不持有站点表、不发请求、
/// 也不知道播放地址长什么样。数据只经三个回调进来：
///
/// - [SourceSwapSearch]：发起一次**全局**搜索（接线方接 state.searchAll）；
/// - [SourceSwapOutcomeOf]：读取全局搜索快照（接线方接 state.activeSearch）；
/// - [SourceSwapProbe]：解析一条候选的线路。
///
/// 为什么是「读快照」而不是「等一个完整列表」：全局搜索是逐站点并发投递的，
/// 外面的大搜索能一个站点一个站点地出结果，浮层也必须一样——等全部返回才
/// 显示就是用户实测的「搜索一次后端服务就会卡」。共用同一份快照还顺带解决
/// 了另一个问题：搜索历史、结果页、换源浮层看到的是**同一个批次**。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/app_error.dart';
import '../core/playback_lines.dart';
import '../core/protocol.dart';
import '../core/source_swap.dart';
import '../core/search_result_filter.dart';
import '../state/search_state.dart';
import 'common.dart';
import 'search_result_view.dart';
import 'source_field.dart';
import 'toast.dart';
import 'tokens.dart';

/// 换源候选：某个站点上的某个影片。
class SwapCandidate {
  const SwapCandidate({
    required this.siteKey,
    required this.siteName,
    required this.vodId,
    required this.vodName,
    this.vodYear = '',
    this.vodPic = '',
    this.listing,
  });

  /// 站点在站点表里的键，用来取来源健康状态（见 [SourceStatus]）。
  final String siteKey;

  /// 站点显示名，用于拼「站点名 · 线路名」。
  final String siteName;

  /// 该站点内部给这部片分配的 id——解析线路时要带回去。
  final String vodId;

  final String vodName;
  final String vodYear;
  final String vodPic;
  final Vod? listing;
}

/// 单条候选的解析阶段。
///
/// [failed] 与 [idle] 都能再次解析：用户可能只是那一刻网络抽了一下，
/// 不该逼他关掉浮层重来。
enum SwapStage { idle, probing, ready, failed }

/// 一行候选 + 它自己的解析状态。
///
/// 一行的状态**只属于这一行**：这是「部分成功」能成立的前提——A 站解析成功
/// 的分集不能因为 B 站 404 就被抹掉。
class SwapRow {
  const SwapRow({
    required this.candidate,
    this.stage = SwapStage.idle,
    this.lines = const <VodPlayLine>[],
    this.routes = const {},
    this.warnings = const [],
    this.error,
    this.emptyResult = false,
    this.retryable = true,
    this.selected = false,
  });

  final SwapCandidate candidate;
  final SwapStage stage;
  final List<VodPlayLine> lines;
  final Map<String, SwapLineRoute> routes;
  final List<AppError> warnings;

  /// 解析失败原因（[AppError] 取 userMessage）；部分失败的行也可能有重试失败原因。
  final String? error;

  /// 失败原因是「站点确实没有返回分集」，而不是请求本身失败。
  final bool emptyResult;

  /// 再试一次是否可能成功：目录类不支持的形态重试多少次都不会变。
  final bool retryable;

  final bool selected;

  SwapRow copyWith({
    SwapStage? stage,
    List<VodPlayLine>? lines,
    Map<String, SwapLineRoute>? routes,
    List<AppError>? warnings,
    String? error,
    bool clearError = false,
    bool? emptyResult,
    bool? retryable,
    bool? selected,
  }) {
    return SwapRow(
      candidate: candidate,
      stage: stage ?? this.stage,
      lines: lines ?? this.lines,
      routes: routes ?? this.routes,
      warnings: warnings ?? this.warnings,
      error: clearError ? null : (error ?? this.error),
      emptyResult: emptyResult ?? this.emptyResult,
      retryable: retryable ?? this.retryable,
      selected: selected ?? this.selected,
    );
  }

  /// 这条候选总共解析出多少集（多条线路相加）。
  int get episodeCount {
    var total = 0;
    for (final line in lines) {
      total += line.episodes.length;
    }
    return total;
  }

  /// 真正可以并入的行：解析完成**且**确实有分集。
  /// 空线路算未就绪——并入一条没有分集的线路对用户毫无意义。
  bool get ready =>
      stage == SwapStage.ready && lines.any((line) => line.episodes.isNotEmpty);
}

/// 发起一次全局搜索（接线方传 (keyword) => state.searchAll(keyword, quick: true)）。
///
/// 浮层只负责把片名递出去：搜哪些站点、并发多少、是否快速搜索都由接线方决定，
/// 浮层不认识站点表（对齐安卓换源：整表一次提交，靠 quick 限流）。
typedef SourceSwapSearch = Future<void> Function(String keyword);

/// 读取当前的全局搜索结果快照（接线方传 () => state.activeSearch）。
typedef SourceSwapOutcomeOf = MultiSiteSearchOutcome? Function();

/// 解析回调：把一条候选解析成线路。
typedef SourceSwapProbe = Future<PlaybackLines> Function(
  SwapCandidate candidate,
);

/// 打开换源浮层。
///
/// 返回 null = 用户取消（关闭 / Esc / 点遮罩 / 取消按钮）；
/// 返回非空 = 这些行已解析成功且被用户勾选，调用方拿去并入线路列表。
/// **不会**返回空列表：空列表会被上层当成「用户选了 0 条」而静默吞掉一次操作。
Future<List<SwapRow>?> showSourceSwapSheet(
  BuildContext context, {
  required String keyword,
  required Listenable searchListenable,
  required SourceSwapOutcomeOf outcomeOf,
  required SourceSwapSearch onSearch,
  required SourceSwapProbe onProbe,
  int initialSimilarity = 30,
  Future<void> Function(int value)? onSimilarityChanged,
  SourceStatus Function(String siteKey)? statusOf,
}) {
  // 浮层的提交按钮（「并入 N 条线路」）就压在右下角，那是通知栈的地盘：错误通知
  // 哪怕只活 30 秒，也够把按钮盖住一整轮操作。用户既然已经在处理这个错误，
  // 通知的使命就结束了，开浮层时先收走。
  dismissAllToasts();
  return showModalBottomSheet<List<SwapRow>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    // 零阴影：层级只靠表面阶梯与发丝边表达（DESIGN.md）。
    elevation: 0,
    // Material 的底部浮层默认把宽度钉在 640 逻辑像素：窗口越宽，浮层越像
    // 挤在中间的一小条（用户反馈「全屏的时候点击会显得很小」）。清空默认
    // 约束，宽度交给根 Container 按窗口自适应（见 source-swap-sheet）。
    constraints: const BoxConstraints(),
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.42),
    builder: (_) => SourceSwapSheet(
      keyword: keyword,
      searchListenable: searchListenable,
      outcomeOf: outcomeOf,
      onSearch: onSearch,
      onProbe: onProbe,
      initialSimilarity: initialSimilarity,
      onSimilarityChanged: onSimilarityChanged,
      statusOf: statusOf,
    ),
  );
}

String _describe(Object error) =>
    error is AppError ? error.userMessage : '$error';

class SourceSwapSheet extends StatefulWidget {
  const SourceSwapSheet({
    super.key,
    required this.keyword,
    required this.searchListenable,
    required this.outcomeOf,
    required this.onSearch,
    required this.onProbe,
    this.initialSimilarity = 30,
    this.onSimilarityChanged,
    this.statusOf,
  });

  final String keyword;

  /// 全局搜索状态的通知源：每完成一个站点通知一次，浮层据此增量刷新。
  final Listenable searchListenable;

  /// 读取全局搜索快照。
  final SourceSwapOutcomeOf outcomeOf;

  final SourceSwapSearch onSearch;
  final SourceSwapProbe onProbe;
  final int initialSimilarity;
  final Future<void> Function(int value)? onSimilarityChanged;
  final SourceStatus Function(String siteKey)? statusOf;

  @override
  State<SourceSwapSheet> createState() => _SourceSwapSheetState();
}

class _SourceSwapSheetState extends State<SourceSwapSheet> {
  final TextEditingController _query = TextEditingController();

  /// 每行**自己的**解析/勾选状态，按 (siteKey, vodId) 长期保存。
  ///
  /// 为什么不直接存在展示列表里：分组 chip 只是本地筛选，切换分组会改变
  /// 可见行集合；流式刷新更是每来一个站点就重建一次列表。行状态要是跟着
  /// 列表走，用户已经勾选、已经解析好的行就会被下一批结果冲掉——这是流式
  /// 刷新最容易踩的坑，所以「行状态」与「展示行」在这里彻底分开。
  final Map<String, SwapRow> _states = <String, SwapRow>{};

  /// 当前展示的行：由「快照 × 分组筛选」派生，不含任何请求。
  List<SwapRow> _rows = const <SwapRow>[];

  /// 当前生效的关键词（回车重搜后要跟着变）。
  late String _keyword = widget.keyword;

  /// 当前生效的分组（null = 全部）。**只**影响本地筛选，绝不触发搜索。
  String? _group;
  late int _similarity = widget.initialSimilarity;
  bool _batchProbing = false;
  bool _confirming = false;
  int _probingDone = 0;
  int _probingTotal = 0;

  /// 勾选跨相似度/分组筛选保留：筛选只改可见集，不能悄悄丢掉用户已选的行。
  List<SwapRow> get _selected => [
    for (final row in _states.values)
      if (row.selected) row,
  ];

  bool get _busy =>
      _batchProbing ||
      _confirming ||
      _selected.any((row) => row.stage == SwapStage.probing);

  @override
  void initState() {
    super.initState();
    _query.text = widget.keyword;
    widget.searchListenable.addListener(_onSearchChanged);
    // 浮层可能是从「已经搜过的批次」里打开的：先把现有快照铺一次。
    _syncRows();
    // **不 await**：结果会经 searchListenable 陆续到达，等它返回就等于退回
    // 「搜完才显示」。
    //
    // 但也不能**在当前帧就调**：`_startSearch` → `onSearch`（调用方接的是
    // `AppState.searchAll`）会同步 `notifyListeners()`，而宿主详情页正是它的
    // 监听者。此刻本浮层还在 `initState`、同一帧的 build 尚未结束，于是详情页的
    // `setState` 直接撞上
    // `setState() or markNeedsBuild() called during build`（生产环境同样会炸，
    // 不只是测试环境）。因此把这一次自动搜索推迟到当前帧之后：搜索语义完全不变
    // （不 await、不加 debounce 延迟），只是不打断这一帧的构建。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_startSearch(widget.keyword));
    });
  }

  @override
  void dispose() {
    widget.searchListenable.removeListener(_onSearchChanged);
    _query.dispose();
    super.dispose();
  }

  /// 发起全局搜索。
  ///
  /// 单站点失败由快照里的 [SiteSearchEntry.error] 逐条呈现（见 [_failureNote]）；
  /// 这里只兜住「批次本身抛错」的未处理异步异常，不让它变成 zone 错误。
  Future<void> _startSearch(String keyword) async {
    try {
      await widget.onSearch(keyword);
    } catch (_) {
      // 见上：失败信息来自快照，不在 UI 里重复一套错误语义。
    }
  }

  void _onSearchChanged() {
    if (!mounted) return;
    setState(_syncRows);
  }

  /// 把全局搜索快照同步成展示行。
  ///
  /// 三条规矩：
  /// 1. 行按 (siteKey, vodId) 复用既有状态，只换 candidate；
  /// 2. 快照里已不存在的候选连同状态一起删除（否则越搜越胖）；
  /// 3. 分组筛选**先过滤 entry 再展开**，只影响展示，不影响保活。
  void _syncRows() {
    final outcome = widget.outcomeOf();
    final alive = <String>{};
    for (final entry in _entriesOf(outcome)) {
      for (final vod in entry.result?.list ?? const <Vod>[]) {
        alive.add(_stateKeyOf(entry.siteKey, vod.vodId));
      }
    }
    _states.removeWhere((key, _) => !alive.contains(key));

    final pending = <String>{};
    final rows = <SwapRow>[];
    final group = _group;
    for (final entry in _entriesOf(outcome)) {
      if (group != null && !entry.groups.contains(group)) continue;
      for (final vod in entry.result?.list ?? const <Vod>[]) {
        final candidate = _candidateOf(entry, vod);
        final key = _stateKey(candidate);
        // 同一站点可能把同一条目投递两次（分页重叠），按 key 去重。
        if (!pending.add(key)) continue;
        final state = _states[key];
        final row = SwapRow(
          candidate: candidate,
          stage: state?.stage ?? SwapStage.idle,
          lines: state?.lines ?? const <VodPlayLine>[],
          routes: state?.routes ?? const {},
          warnings: state?.warnings ?? const [],
          error: state?.error,
          emptyResult: state?.emptyResult ?? false,
          retryable: state?.retryable ?? true,
          selected: state?.selected ?? false,
        );
        _states[key] = row;
        rows.add(row);
      }
    }
    _rows = rows;
  }

  /// 结果里真正有候选的站点条目（succeeded 且 itemCount > 0）。
  ///
  /// 保留原始候选；相似度筛选只影响共享视图，不删除已选状态。
  Iterable<SiteSearchEntry> _entriesOf(MultiSiteSearchOutcome? outcome) sync* {
    if (outcome == null) return;
    for (final entry in outcome.results) {
      if (!entry.succeeded || entry.itemCount == 0) continue;
      yield entry;
    }
  }

  SwapCandidate _candidateOf(SiteSearchEntry entry, Vod vod) => SwapCandidate(
    siteKey: entry.siteKey,
    siteName: entry.siteName,
    vodId: vod.vodId,
    vodName: vod.vodName,
    vodYear: vod.vodYear?.trim() ?? '',
    vodPic: vod.vodPic?.trim() ?? '',
    listing: vod,
  );

  /// 行身份键：站点 + 站点内 id。
  ///
  /// 用 NUL 分隔而不是连字符：siteKey / vodId 都可能带连字符，拼起来会出现
  /// 「a-b」+「c」与「a」+「b-c」撞车。
  String _stateKeyOf(String siteKey, String vodId) => '$siteKey\u0000$vodId';

  String _stateKey(SwapCandidate candidate) =>
      _stateKeyOf(candidate.siteKey, candidate.vodId);

  Future<void> _probeSelected() => _probeBatch([
    for (final row in _selected)
      if (row.stage == SwapStage.idle ||
          (row.stage == SwapStage.failed && row.retryable))
        row,
  ]);

  /// 与 [_confirmPartial] 的 issues 同条件：只重探 failed 或带 warnings 的行，
  /// 所以 ready+error 一定伴随 warnings 出现，不会漏进对话框。
  Future<void> _retryFailed() => _probeBatch([
    for (final row in _selected)
      if ((row.stage == SwapStage.failed && row.retryable) ||
          row.warnings.isNotEmpty)
        row,
  ]);

  Future<void> _probeBatch(List<SwapRow> targets) async {
    if (_busy || targets.isEmpty) return;
    setState(() {
      _batchProbing = true;
      _probingDone = 0;
      _probingTotal = targets.length;
    });
    try {
      await Future.wait([
        for (final row in targets) _probe(row, trackProgress: true),
      ]);
    } finally {
      if (mounted) {
        setState(() {
          _batchProbing = false;
          _probingDone = 0;
          _probingTotal = 0;
        });
      }
    }
    if (!mounted) return;
    final selected = _selected;
    if (selected.any((row) => row.ready) &&
        selected.any(
          (row) => row.stage == SwapStage.failed || row.warnings.isNotEmpty,
        )) {
      await _confirmPartial();
    }
  }

  Future<void> _probe(SwapRow row, {bool trackProgress = false}) async {
    final key = _stateKey(row.candidate);
    if (_states[key]?.stage == SwapStage.probing) return;
    // 已解析出线路的行重试时先保留旧结果：站点抖动让这次重试失败，不能把
    // 用户本来就能播的线路一起清掉（那是部分失败最常见的场景）。
    final previous = _states[key];
    final preserved = previous != null && previous.ready ? previous : null;
    _patch(
      row.candidate,
      (current) => current.copyWith(
        stage: SwapStage.probing,
        clearError: true,
        emptyResult: false,
      ),
    );
    try {
      final parsed = await widget.onProbe(row.candidate);
      final lines = parsed.lines
          .where((line) => line.episodes.isNotEmpty)
          .toList();
      if (!mounted) return;
      if (lines.isEmpty) {
        _patch(
          row.candidate,
          (current) => preserved == null
              ? current.copyWith(
                  stage: SwapStage.failed,
                  lines: const [],
                  routes: const {},
                  warnings: const [],
                  error: '目标站点没有解析到分集',
                  emptyResult: true,
                )
              : preserved.copyWith(
                  stage: SwapStage.ready,
                  error: '重试失败：目标站点没有解析到分集',
                  emptyResult: true,
                ),
        );
        return;
      }
      _patch(
        row.candidate,
        (current) => current.copyWith(
          stage: SwapStage.ready,
          lines: lines,
          routes: {
            for (final line in lines)
              if (parsed.routes[line.flag] != null)
                line.flag: parsed.routes[line.flag]!,
          },
          warnings: parsed.warnings,
          clearError: true,
          emptyResult: false,
          retryable: true,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final retryable =
          !(error is AppError && error.kind == AppErrorKind.siteUnsupported);
      final message = preserved == null
          ? _describe(error)
          : '重试失败：${_describe(error)}';
      _patch(
        row.candidate,
        (current) => preserved == null
            ? current.copyWith(
                stage: SwapStage.failed,
                lines: const [],
                routes: const {},
                warnings: const [],
                error: message,
                retryable: retryable,
              )
            : preserved.copyWith(
                stage: SwapStage.ready,
                error: message,
                retryable: retryable,
              ),
      );
    } finally {
      if (trackProgress && mounted) {
        setState(() => _probingDone += 1);
      }
    }
  }

  /// 按 candidate 定位行状态并替换，然后重建展示行。
  /// **不**按对象 identity 定位：勾选、流式刷新都会重建 SwapRow 实例。
  void _patch(
    SwapCandidate candidate,
    SwapRow Function(SwapRow current) change,
  ) {
    if (!mounted) return;
    final key = _stateKey(candidate);
    final current = _states[key];
    if (current == null) return;
    setState(() {
      _states[key] = change(current);
      _syncRows();
    });
  }

  void _toggle(SwapRow row) {
    if (_busy) return;
    _patch(
      row.candidate,
      (current) => current.copyWith(selected: !current.selected),
    );
  }

  /// 切换分组 = **纯本地筛选**。
  ///
  /// 这里绝不能调 widget.onSearch：重搜会让已经勾选/已经解析好的行整批消失，
  /// 而且每点一下 chip 就打一轮后端（用户实测：搜索一次后端服务就会卡）。
  void _selectGroup(String? group) {
    if (group == _group) return;
    setState(() {
      _group = group;
      _syncRows();
    });
  }

  void _submitQuery() {
    if (_busy) return;
    final text = _query.text.trim();
    if (text.isEmpty || text == _keyword) return;
    setState(() {
      _keyword = text;
      // 新关键词 = 新一批结果，旧的本地筛选没有意义。清掉分组后必须重建
      // 展示行，否则被筛掉的行要等下一站通知才回来。
      _group = null;
      _syncRows();
    });
    unawaited(_startSearch(text));
  }

  int _lineCount(List<SwapRow> rows) => rows.fold(
    0,
    (count, row) =>
        count + row.lines.where((line) => line.episodes.isNotEmpty).length,
  );

  Future<void> _changeSimilarity(int value) async {
    if (_similarity == value) return;
    setState(() => _similarity = value);
    await widget.onSimilarityChanged?.call(value);
  }

  Future<void> _confirmPartial() async {
    if (_busy) return;
    final selected = _selected;
    final ready = selected.where((row) => row.ready).toList();
    final failed = selected
        .where((row) => row.stage == SwapStage.failed)
        .toList();
    final issues = selected
        .where(
          (row) => row.stage == SwapStage.failed || row.warnings.isNotEmpty,
        )
        .toList();
    final warningCount = selected.fold<int>(
      0,
      (count, row) => count + row.warnings.length,
    );
    if (ready.isEmpty || issues.isEmpty) return;
    final lineCount = _lineCount(ready);
    final retryableIssue = issues.any(
      (row) => row.warnings.isNotEmpty || row.retryable,
    );
    setState(() => _confirming = true);
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          final theme = Theme.of(dialogContext);
          return AlertDialog(
            key: const ValueKey('source-swap-partial-dialog'),
            title: const Text('部分来源未完整解析'),
            content: SizedBox(
              width: 520,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.5,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${failed.isEmpty ? '${ready.length} 个来源可用。' : '${ready.length} 个来源可用，${failed.length} 个来源失败。'}'
                        '${warningCount > 0 ? '另有 $warningCount 条线路加载失败。' : ''}'
                        '确认后仅并入 $lineCount 条可用线路。',
                      ),
                      const SizedBox(height: AppSpace.lg),
                      for (final row in issues)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpace.md),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${row.candidate.siteName} · ${row.candidate.vodName}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: AppWeight.title,
                                ),
                              ),
                              const SizedBox(height: AppSpace.xs),
                              Text(
                                _issueTextOf(row),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Text(
                        retryableIssue
                            ? '返回检查可保留已选项，并重试失败来源。'
                            : '返回检查可保留已选项；目录类结果请进入详情选择条目。',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                key: const ValueKey('source-swap-partial-cancel'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('返回检查'),
              ),
              FilledButton(
                key: const ValueKey('source-swap-partial-commit'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text('确认并入 $lineCount 条线路'),
              ),
            ],
          );
        },
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (confirmed == true && mounted) {
      final currentReady = _selected.where((row) => row.ready).toList();
      if (currentReady.isNotEmpty) _commit(currentReady);
    }
  }

  void _commit(List<SwapRow> rows) {
    if (rows.isNotEmpty) Navigator.of(context).pop(rows);
  }

  void _cancel() {
    // pop() 不带结果 = null = 取消；绝不能 pop 空列表冒充成功。
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = _selected;
    final readySelected = <SwapRow>[
      for (final row in selected)
        if (row.ready) row,
    ];
    final hairline = scheme.outlineVariant.withValues(alpha: 0.72);
    // 证据采集锚点：浮层是独立路由，默认取树里第一个 RepaintBoundary 只会拍到
    // 页面本身；与 ai-season-preview-boundary / tmdb-photo-viewer-boundary 同一约定。
    return RepaintBoundary(
      key: const ValueKey('source-swap-sheet-boundary'),
      // 自适应宽度：桌面窗口越宽浮层越宽（上限 1120），不再被 Material 默认的
      // 640 逻辑像素夹住。
      //
      // 用横向撑满、纵向贴合内容的 Row 居中，而不是 Center：Center 会撑满整块
      // 路由区域，浮层就会被竖直居中悬在屏幕中间、而不是贴底，且它的透明区域
      // 会盖住遮罩，点遮罩关不掉。
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            key: const ValueKey('source-swap-sheet'),
            width: math.min(
              MediaQuery.sizeOf(context).width - AppSpace.xxl * 2,
              1120.0,
            ),
            // 高度按 0.86 视口 + 820 封顶：结果区要与搜索页同尺寸的 140×190
            // 标准海报卡（一屏能摆下多行多列），640 的老高度只够单列小行。
            height: math.min(MediaQuery.sizeOf(context).height * 0.86, 820),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.lg),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 顶部发丝线：1px，把浮层与页面切开，不靠阴影。
                  Container(height: 1, color: hairline),
                  _header(theme, scheme),
                  _queryField(theme, scheme),
                  Expanded(child: _body(theme, scheme)),
                  if (selected.isNotEmpty)
                    _actionBar(
                      theme,
                      scheme,
                      selected,
                      readySelected,
                      hairline,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme, ColorScheme scheme) {
    return Padding(
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
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '换源',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: AppWeight.title,
                  ),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  '当前：$_keyword',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('source-swap-close'),
            tooltip: '关闭',
            onPressed: _cancel,
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _queryField(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.xs,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: TextField(
        key: const ValueKey('source-swap-query'),
        controller: _query,
        enabled: !_busy,
        textInputAction: TextInputAction.search,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索其它来源',
          hintStyle: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: AppSpace.xxl,
            minHeight: AppSpace.xxl,
          ),
          suffixIcon: IconButton(
            tooltip: '搜索',
            onPressed: _submitQuery,
            icon: const Icon(Icons.arrow_forward, size: 16),
          ),
        ),
        onSubmitted: (_) => _submitQuery(),
      ),
    );
  }

  /// 行 key：`source-swap-row-<siteKey>-<vodId>`（测试与集成用例按这个名字点）。
  /// 海报盒子由共享视图按 `keyPrefix` 生成 `source-swap-poster-<site>-<id>`，
  /// 这两个命名必须与既有测试逐字一致。
  String _rowKeyOf(String siteKey, String vodId) =>
      'source-swap-row-$siteKey-$vodId';

  Widget _body(ThemeData theme, ColorScheme scheme) {
    final outcome = widget.outcomeOf();
    if (outcome == null) {
      // 只有「首次搜索还没建批次」才是整块加载态：一旦有快照，已有结果
      // 就必须能立刻勾选，不能被遮罩挡住。
      return const LoadingBlock(padding: EdgeInsets.all(AppSpace.xl));
    }
    final failures = outcome.results.where((entry) => !entry.succeeded).length;
    final rowsBy = <String, SwapRow>{
      for (final row in _rows)
        _stateKeyOf(row.candidate.siteKey, row.candidate.vodId): row,
    };
    SwapRow? rowOf(String siteKey, String vodId) =>
        rowsBy[_stateKeyOf(siteKey, vodId)];
    // 结果区与搜索页共用同一套视图（侧栏 + 分组条 + 标准海报墙）。
    // 相似度与搜索页共用；快速搜索不分页，卡片额外呈现勾选与解析状态。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 进行中只在列表上方占一小块：不做遮罩，已有行照常可勾选。
        if (!outcome.finished) _searchProgress(outcome, theme, scheme),
        if (failures > 0) _failureNote(failures, theme, scheme),
        Expanded(
          child: SearchResultView(
            key: ValueKey('source-swap-results-${outcome.runId}'),
            outcome: outcome,
            keyPrefix: 'source-swap',
            itemKeyOf: (siteKey, vodId) => _rowKeyOf(siteKey, vodId),
            subtitleOf: (siteKey, vod) {
              final year = vod.vodYear?.trim() ?? '';
              final name = rowOf(siteKey, vod.vodId)?.candidate.siteName ?? '';
              return [name, if (year.isNotEmpty) year].join(' · ');
            },
            group: _group ?? '',
            onGroupChanged: (value) =>
                _selectGroup(value.isEmpty ? null : value),
            initialSimilarity: _similarity,
            onSimilarityChanged: _changeSimilarity,
            showSummary: false,
            onTapItem: (siteKey, vod) {
              final row = rowOf(siteKey, vod.vodId);
              if (row != null) _toggle(row);
            },
            isSelected: (siteKey, vod) =>
                rowOf(siteKey, vod.vodId)?.selected ?? false,
            overlayOf: (siteKey, vod) {
              final row = rowOf(siteKey, vod.vodId);
              if (row == null) return null;
              return _rowOverlay(row, theme, scheme);
            },
            emptyState: _emptyState(outcome),
          ),
        ),
      ],
    );
  }

  Widget _searchProgress(
    MultiSiteSearchOutcome outcome,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    final done = outcome.results.length;
    final total = outcome.totalSites;
    final value = total > 0 ? (done / total).clamp(0.0, 1.0).toDouble() : null;
    return Padding(
      key: const ValueKey('source-swap-search-progress'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  total > 0
                      ? '正在搜索 · 已完成 $done / $total 个站点'
                      : '正在搜索 · 已返回 $done 个站点',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              key: const ValueKey('source-swap-search-progress-bar'),
              value: value,
              minHeight: 4,
              color: scheme.primary,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }

  /// 失败站点如实可诊断：不静默丢弃，否则用户以为「这个站源没有这部片」。
  Widget _failureNote(int count, ThemeData theme, ColorScheme scheme) {
    return Padding(
      key: const ValueKey('source-swap-search-failures'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        0,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Text(
              '另有 $count 个站点搜索失败',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(MultiSiteSearchOutcome outcome) {
    if (_similarity > 0 &&
        _rows.isNotEmpty &&
        filterSearchResults(
          _rows,
          outcome.keyword,
          _similarity,
          titleOf: (row) => row.candidate.vodName,
        ).isEmpty) {
      return const EmptyState(
        key: ValueKey('source-swap-empty'),
        title: '当前相似度下没有结果',
        message: '降低相似度或选择「不过滤」，即可查看被隐藏的候选',
        icon: Icons.filter_alt_off_outlined,
      );
    }
    if (!outcome.finished) {
      return const EmptyState(
        key: ValueKey('source-swap-empty'),
        title: '还在搜索中',
        message: '返回一个站点就显示一个站点',
        icon: Icons.search,
      );
    }
    if (_group != null) {
      return const EmptyState(
        key: ValueKey('source-swap-empty'),
        title: '这个分组没有结果',
        message: '点「全部」看所有来源，或者换一个关键词',
        icon: Icons.filter_alt_off_outlined,
      );
    }
    return const EmptyState(
      key: ValueKey('source-swap-empty'),
      title: '没有找到其它来源',
      message: '换个关键词再试一次',
      icon: Icons.search_off,
    );
  }

  /// 叠在海报上的状态层：勾选框（左上）+ 来源健康色点（右上）+ 解析状态角标
  /// （底部）。140×190 的标准卡没有多余纵向空间，第四行塞不下来，所以状态全部
  /// 压进海报区域，而不是另起一行。
  Widget _rowOverlay(SwapRow row, ThemeData theme, ColorScheme scheme) {
    final candidate = row.candidate;
    final suffix = '${candidate.siteKey}-${candidate.vodId}';
    final status =
        widget.statusOf?.call(candidate.siteKey) ?? SourceStatus.unknown;
    final badge = _rowBadge(row, suffix, theme);
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          child: Checkbox(
            key: ValueKey('source-swap-check-$suffix'),
            value: row.selected,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: _busy ? null : (_) => _toggle(row),
          ),
        ),
        // 来源健康度用来源色，不是强调色。
        Positioned(
          right: AppSpace.sm,
          top: AppSpace.sm,
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: sourceStatusColor(context, status),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        if (badge != null)
          Positioned(
            left: AppSpace.xs,
            right: AppSpace.xs,
            bottom: AppSpace.xs,
            child: badge,
          ),
      ],
    );
  }

  String _issueTextOf(SwapRow row) => [
    if (row.error != null && row.error!.trim().isNotEmpty) row.error!,
    for (final warning in row.warnings) warning.userMessage,
  ].join('；');

  /// 解析进度角标：解析中… / N 集 / 无分集 + 重试。
  Widget? _rowBadge(SwapRow row, String suffix, ThemeData theme) {
    if (row.stage == SwapStage.probing) {
      return _badgeShell(
        theme,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              key: ValueKey('source-swap-spinner-$suffix'),
              width: 12,
              height: 12,
              child: const CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: AppSpace.xs),
            const Text('解析中…'),
          ],
        ),
      );
    }
    if (row.stage == SwapStage.failed) {
      return _badgeShell(
        theme,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: row.error ?? '解析失败',
              child: Text(
                row.emptyResult ? '无分集' : '解析失败',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: sourceStatusColor(context, SourceStatus.failed),
                ),
              ),
            ),
            if (row.retryable)
              TextButton(
                key: ValueKey('source-swap-retry-$suffix'),
                onPressed: _busy ? null : () => _probe(row),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, AppSpace.lg),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: theme.textTheme.bodySmall,
                ),
                child: const Text('重试'),
              ),
          ],
        ),
      );
    }
    if (row.ready) {
      if (row.warnings.isNotEmpty || row.error != null) {
        return Tooltip(
          message: _issueTextOf(row),
          child: _badgeShell(theme, Text('${row.episodeCount} 集 · 部分失败')),
        );
      }
      return _badgeShell(theme, Text('${row.episodeCount} 集'));
    }
    return null;
  }

  Widget _badgeShell(ThemeData theme, Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DefaultTextStyle.merge(
        style:
            theme.textTheme.bodySmall ?? const TextStyle(color: Colors.white),
        child: child,
      ),
    );
  }

  Widget _actionBar(
    ThemeData theme,
    ColorScheme scheme,
    List<SwapRow> selected,
    List<SwapRow> readySelected,
    Color hairline,
  ) {
    final failedCount = selected
        .where((row) => row.stage == SwapStage.failed)
        .length;
    final pendingCount = selected
        .where((row) => row.stage == SwapStage.idle)
        .length;
    final lineCount = _lineCount(readySelected);
    final allReady = readySelected.length == selected.length;
    final warnedCount = selected.where((row) => row.warnings.isNotEmpty).length;
    final retryableFailedCount = selected
        .where((row) => row.stage == SwapStage.failed && row.retryable)
        .length;
    final retryCount = retryableFailedCount + warnedCount;
    final canProbe = pendingCount > 0 || retryableFailedCount > 0;
    final hasPartial =
        readySelected.isNotEmpty &&
        (failedCount > 0 || warnedCount > 0) &&
        pendingCount == 0;
    // 还有未解析的行时必须先解析它们；只重试失败会让按钮永远停在原地。
    final retryOnly = !hasPartial && pendingCount == 0 && retryCount > 0;
    final canProbeCount = pendingCount + retryableFailedCount;
    final probing = _batchProbing && _probingTotal > 0;
    final busyLabel = probing ? '正在解析 $_probingDone/$_probingTotal' : '正在解析…';
    final label = _confirming
        ? '等待确认…'
        : _busy
        ? busyLabel
        : hasPartial
        ? '并入可用 · $lineCount 条线路'
        : allReady
        ? '并入 $lineCount 条线路'
        : retryOnly
        ? '重试失败 · $retryCount 个'
        : canProbe
        ? '解析所选 · $canProbeCount 条'
        : '无可用线路';
    final summary = readySelected.isEmpty && failedCount == 0
        ? '已选 ${selected.length} 条候选'
        : '已选 ${selected.length} 个来源 · 可用 ${readySelected.length}'
              '${failedCount > 0 ? ' · 解析失败 $failedCount' : ''}'
              '${warnedCount > 0 ? ' · 内部线路失败 $warnedCount' : ''}'
              '${pendingCount > 0 ? ' · 待解析 $pendingCount' : ''}';
    final actions = Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      alignment: WrapAlignment.end,
      children: [
        if (hasPartial && retryCount > 0)
          TextButton(
            key: const ValueKey('source-swap-retry-failed'),
            onPressed: _busy ? null : _retryFailed,
            child: Text('重试失败 · $retryCount 个'),
          ),
        FilledButton(
          key: const ValueKey('source-swap-commit'),
          onPressed: _busy
              ? null
              : hasPartial
              ? _confirmPartial
              : allReady
              ? () => _commit(readySelected)
              : retryOnly
              ? _retryFailed
              : canProbe
              ? _probeSelected
              : null,
          child: Text(label),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(height: 1, color: hairline),
        if (probing)
          LinearProgressIndicator(
            key: const ValueKey('source-swap-probe-progress'),
            value: _probingTotal > 0 ? _probingDone / _probingTotal : null,
            minHeight: 4,
            color: scheme.primary,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final note = Text(
                summary,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              );
              if (constraints.maxWidth < 680) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    note,
                    const SizedBox(height: AppSpace.sm),
                    actions,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: note),
                  const SizedBox(width: AppSpace.md),
                  actions,
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
