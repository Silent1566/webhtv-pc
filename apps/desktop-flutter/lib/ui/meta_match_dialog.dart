/// 通用「匹配元数据」对话框：TMDB / 豆瓣 / Bangumi 三来源检索，选一条即生效。
///
/// 为什么合并成一个入口：用户的心智是「这条数据不对，我自己指定」，
/// 而不是「我要用哪家的接口去指定」。三家的结论落在各自既有的存储里
/// （TMDB → TmdbMatchRecord，外部 → MetaOverrideStore），对话框不关心差别。
///
/// 为什么没有「用这个」按钮：手动匹配是**认条目**，不是**按按钮**。整行都是
/// 命中区之后，用户不必先找到右侧那个只属于这一行的按钮；行内直接给出海报、
/// 年份、类型、集数、评分、原名、一行事实与简介（对齐安卓 TmdbSearchDialog
/// 的候选行），一个对话框里就能确认「是不是同一部片」。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/external_meta.dart';
import '../core/meta_source.dart';
import '../core/protocol.dart';
import '../core/tmdb_identity.dart';
import '../core/tmdb_title.dart';
import '../state/app_state.dart';
import 'poster_image.dart';
import 'glass_dialog.dart';
import 'tokens.dart';

class MetaMatchDialog extends StatefulWidget {
  const MetaMatchDialog({
    super.key,
    required this.state,
    required this.vod,
    this.tmdbSearch,
    this.onPickTmdb,
    this.currentTmdb,
    this.allowExternal = true,
  });

  final AppState state;
  final Vod vod;

  /// TMDB 搜索（未配置时传 null：TMDB 分段置灰）。
  final Future<List<TmdbItem>> Function(String keyword)? tmdbSearch;
  final void Function(TmdbItem item)? onPickTmdb;

  /// 当前生效的 TMDB 身份（未匹配时 null），用来在结果里标出「当前」。
  ///
  /// 为什么由调用方传：推送记录的当前匹配不在 `state.tmdb` 里，对话框自己读
  /// 会把别的页面/上一条记录的匹配当成这一条的「当前」。
  final TmdbIdentity? currentTmdb;

  /// 是否允许外部来源（豆瓣/Bangumi）。
  ///
  /// 默认 true：既有入口（详情页）行为完全不变。推送记录传 false——
  /// 外部来源的结论落在 MetaOverrideStore，推送的元数据只认 TmdbMatchRecord，
  /// 让用户点到一条「选了也白选」的结果比不给他这个选项更糟。
  final bool allowExternal;

  @override
  State<MetaMatchDialog> createState() => _MetaMatchDialogState();
}

class _MetaMatchDialogState extends State<MetaMatchDialog> {
  MetaSourceKind _source = MetaSourceKind.douban;
  late final TextEditingController _query = TextEditingController(
    text: widget.vod.vodName,
  );

  /// 本次对话框生命周期内每个来源最近一次搜索的结果。
  ///
  /// 为什么保留：切来源只为对比「三家谁认对了」，切回来还要再点一次搜索、
  /// 再看一遍加载，等于把同一个问题问两遍。缓存只在对话框内有效，不落盘。
  final Map<MetaSourceKind, _SourceResults> _results = {};

  /// TMDB 候选的演员行：`tmdb-<id>` → `主演：…`。
  ///
  /// 只有 TMDB 需要额外请求：它的搜索响应没有演职员；豆瓣在 card_subtitle、
  /// Bangumi 在 infobox 里本来就有。
  final Map<String, String> _tmdbPeople = {};
  int _tmdbPeopleEpoch = 0;

  bool _busy = false;
  String? _hint;

  bool get _tmdbAvailable => widget.tmdbSearch != null;

  @override
  void initState() {
    super.initState();
    // 有 TMDB 就先给 TMDB：它是原有主源，用户从旧按钮过来时预期一致。
    // 只开 TMDB 时没有第二个可选来源，初始值必须是它。
    _source = _tmdbAvailable || !widget.allowExternal
        ? MetaSourceKind.tmdb
        : MetaSourceKind.douban;
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  MetaQuery get _metaQuery => MetaQuery(
    title: _query.text.trim(),
    year: firstYear(widget.vod.vodYear ?? ''),
    isTv: !'${widget.vod.extra['type_name'] ?? ''}'.contains('电影'),
  );

  Future<void> _search() async {
    final title = _query.text.trim();
    if (title.isEmpty) return;
    final source = _source;
    setState(() {
      _busy = true;
      _hint = null;
      _results.remove(source);
    });
    if (source == MetaSourceKind.tmdb) {
      final search = widget.tmdbSearch;
      final results = search == null ? const <TmdbItem>[] : await search(title);
      if (!mounted) return;
      final hint = results.isEmpty ? 'TMDB 没有找到候选' : null;
      setState(() {
        _busy = false;
        _results[source] = _SourceResults(
          query: title,
          tmdb: results,
          hint: hint,
        );
        // 搜索期间用户可能已经切走：迟到的结果只进缓存，不改当前页的提示。
        if (_source == source) _hint = hint;
      });
      unawaited(_loadTmdbPeople(results));
      return;
    }
    final results = await widget.state.externalMetaService.candidates(
      _metaQuery,
      source,
      // 手动匹配的唯一目的就是「让用户确认」，候选行要评分与主创信息。
      enrich: true,
    );
    if (!mounted) return;
    final hint = results.isEmpty ? '没有找到候选，换个关键词试试' : null;
    setState(() {
      _busy = false;
      _results[source] = _SourceResults(
        query: title,
        external: results,
        hint: hint,
      );
      if (_source == source) _hint = hint;
    });
  }

  /// 切换来源：有缓存就连查询词一起还原，没有就保留当前查询词。
  void _selectSource(MetaSourceKind source) {
    setState(() {
      _source = source;
      final cached = _results[source];
      _hint = cached?.hint;
      if (cached == null) return;
      final text = cached.query;
      _query.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    });
  }

  /// 只给 TMDB 候选补演员：搜索接口不返回演职员，详情接口会（详情页随后
  /// 复用同一份缓存）。限制条数，避免一次搜索把整页详情全部拉一遍。
  Future<void> _loadTmdbPeople(List<TmdbItem> items) async {
    final epoch = ++_tmdbPeopleEpoch;
    final service = widget.state.tmdbService;
    for (final item in items.take(_tmdbPeopleLimit)) {
      final key = 'tmdb-${item.tmdbId}';
      if (_tmdbPeople.containsKey(key)) continue;
      if (!mounted || epoch != _tmdbPeopleEpoch) return;
      try {
        final detail = await service.detail(item, includeRelated: false);
        final names = service
            .cast(detail)
            .map((person) => person.name.trim())
            .where((name) => name.isNotEmpty)
            .take(5)
            .toList();
        if (names.isEmpty) continue;
        if (!mounted || epoch != _tmdbPeopleEpoch) return;
        setState(() => _tmdbPeople[key] = '主演：${names.join(' / ')}');
      } catch (_) {
        // 未配置 / 网络失败 / 被限流：这一行没有演员信息，不影响选择。
      }
    }
  }

  Future<void> _pickExternal(MetaCandidate candidate) async {
    final saved = await widget.state.pinMetaOverride(
      widget.vod.vodId,
      candidate.identity,
    );
    if (!mounted) return;
    Navigator.of(context).pop(saved);
  }

  Future<void> _reset() async {
    await widget.state.unpinMetaOverride(widget.vod.vodId);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 只开 TMDB 时不碰外部分支：metaOverrides 是外部来源的状态，
    // 读它对「这一个来源」没有任何意义。
    final pinned = widget.allowExternal
        ? widget.state.metaOverrides.of(widget.vod.vodId)
        : null;
    final cached = _results[_source];
    final rows = _source == MetaSourceKind.tmdb
        ? (cached?.tmdb ?? const <TmdbItem>[])
              .map(
                (item) => _RowData(
                  key: 'tmdb-${item.tmdbId}',
                  title: item.title,
                  metaLine: _metaLine(year: item.year, isTv: item.isTv),
                  people: _tmdbPeople['tmdb-${item.tmdbId}'] ?? '',
                  overview: _flatten(item.overview),
                  posterUrl: item.posterUrl,
                  rating: item.tmdbRating > 0 ? item.tmdbRating : item.rating,
                  current:
                      widget.currentTmdb != null &&
                      item.identity == widget.currentTmdb,
                  pick: () {
                    widget.onPickTmdb?.call(item);
                    Navigator.of(context).pop(true);
                  },
                ),
              )
              .toList()
        : (cached?.external ?? const <MetaCandidate>[])
              .map(
                (candidate) => _RowData(
                  key: candidate.identity.key,
                  title: candidate.title,
                  metaLine: _metaLine(
                    year: candidate.year,
                    isTv: candidate.identity.isTv,
                    episodeCount: candidate.episodeCount,
                    seasonLabel: candidate.seasonLabel,
                  ),
                  originalTitle: candidate.originalTitle,
                  facts: candidate.facts ?? '',
                  people: candidate.people ?? '',
                  overview: _flatten(candidate.overview),
                  posterUrl: candidate.posterUrl,
                  rating: candidate.rating,
                  current:
                      pinned != null && pinned.key == candidate.identity.key,
                  pick: () => _pickExternal(candidate),
                ),
              )
              .toList();
    // 桌面窗口可缩放：宽度 900 封顶，高度扣掉标题与动作条。写死更高会让
    // AlertDialog 在 800×600 这类窗口里把内容硬裁掉（测试视口正是这一档）。
    // 最小高度是刻意的：一两条候选时对话框缩成一条小窗，海报、主创、简介
    // 全挤在一起，反而更难扫。
    final media = MediaQuery.sizeOf(context);
    final width = math.max(420.0, math.min(900.0, media.width - 120));
    final maxHeight = math.max(320.0, math.min(680.0, media.height - 220));
    final minHeight = math.min(320.0, maxHeight);
    return GlassAlertDialog(
      constraints: BoxConstraints(maxWidth: width + 2 * AppSpace.xl),
      title: const Text('匹配元数据'),
      content: SizedBox(
        width: width,
        // 结果少时对话框跟着变矮，但不会缩到比 minHeight 更小；结果多时
        // 到 maxHeight 封顶，列表自己滚动。
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: minHeight,
            maxHeight: maxHeight,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: AppSpace.sm,
                  children: [
                    for (final source
                        in widget.allowExternal
                            ? const [
                                MetaSourceKind.tmdb,
                                MetaSourceKind.douban,
                                MetaSourceKind.bangumi,
                              ]
                            : const [MetaSourceKind.tmdb])
                      ChoiceChip(
                        key: ValueKey('meta-match-source-${source.key}'),
                        label: Text(
                          source == MetaSourceKind.tmdb && !_tmdbAvailable
                              ? '${source.label}（未配置）'
                              : source.label,
                        ),
                        selected: _source == source,
                        onSelected:
                            source == MetaSourceKind.tmdb && !_tmdbAvailable
                            ? null
                            : (_) => _selectSource(source),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('meta-match-query'),
                      controller: _query,
                      onSubmitted: (_) => _search(),
                      decoration: const InputDecoration(
                        labelText: '片名',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  FilledButton(
                    key: const ValueKey('meta-match-search'),
                    onPressed: _busy ? null : _search,
                    child: Text(_busy ? '搜索中…' : '搜索'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              if (rows.isEmpty)
                _emptyHint(theme)
              else
                Flexible(
                  child: ListView.separated(
                    key: const ValueKey('meta-match-results'),
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                    itemCount: rows.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return _CandidateRow(
                        key: ValueKey('meta-match-result-${row.key}'),
                        data: row,
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        // 「恢复自动匹配」清的是外部来源的钉住（unpinMetaOverride）；
        // 只开 TMDB 时没有那个状态可清，按钮留着只会让人点了以为恢复了。
        if (widget.allowExternal)
          TextButton(
            key: const ValueKey('meta-match-reset'),
            onPressed: _reset,
            child: const Text('恢复自动匹配'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _emptyHint(ThemeData theme) {
    final hint = _hint ?? (_busy ? '' : '输入片名后点「搜索」，点任意一条即生效。');
    if (hint.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topLeft,
      child: Text(
        hint,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 一个来源最近一次搜索的快照：切回来时连查询词一起还原。
class _SourceResults {
  const _SourceResults({
    required this.query,
    this.tmdb = const [],
    this.external = const [],
    this.hint,
  });

  final String query;
  final List<TmdbItem> tmdb;
  final List<MetaCandidate> external;
  final String? hint;
}

/// TMDB 每次搜索最多补多少条详情的演员；详情请求有配额，且详情页随后还会再用。
const int _tmdbPeopleLimit = 6;

/// 一行候选的展示数据：三个来源都先拼成这一种形状，行渲染不再分叉。
class _RowData {
  const _RowData({
    required this.key,
    required this.title,
    required this.metaLine,
    required this.pick,
    this.originalTitle = '',
    this.facts = '',
    this.people = '',
    this.overview = '',
    this.posterUrl,
    this.rating = 0,
    this.current = false,
  });

  final String key;
  final String title;

  /// 年份 · 类型 · 集数 · 季号；缺项自动省略。
  final String metaLine;
  final String originalTitle;

  /// 一行补充事实（豆瓣的地区 / 类型）；没有时为空串。
  final String facts;

  /// 一行主创（`主演：… · 导演：…`）；没有时为空串。
  final String people;
  final String overview;
  final String? posterUrl;

  /// 10 分制评分；0 表示该来源没有给分（不显示，不补占位）。
  final double rating;

  /// 是否是当前已钉住的那一条（只有外部来源有这个概念）。
  final bool current;

  final VoidCallback pick;
}

/// 单个候选行：整行是命中区，点一下就应用并关闭对话框。
class _CandidateRow extends StatelessWidget {
  const _CandidateRow({super.key, required this.data});

  final _RowData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = context.semanticColors;
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Ink(
      // 选中的那一条自带底色（对齐安卓的当前匹配行），扫一眼就能认出哪条在用；
      // 没有「当前」的来源不画，避免把自动匹配猜的结果说成「已采用」。
      decoration: data.current
          ? BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.06),
              borderRadius: AppRadius.mdAll,
            )
          : null,
      child: InkWell(
        onTap: data.pick,
        borderRadius: AppRadius.mdAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.xs,
            vertical: AppSpace.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: AppRadius.smAll,
                child: PosterImage(
                  url: data.posterUrl,
                  width: 56,
                  height: 84,
                  cacheWidth: 112,
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            data.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        if (data.rating > 0) ...[
                          const SizedBox(width: AppSpace.sm),
                          Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: semantic.magnitude,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            data.rating.toStringAsFixed(1),
                            style: tabular(
                              theme.textTheme.labelMedium!.copyWith(
                                color: semantic.magnitude,
                              ),
                            ),
                          ),
                        ],
                        if (data.current) ...[
                          const SizedBox(width: AppSpace.sm),
                          const _CurrentBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(data.metaLine, style: secondary),
                    if (data.originalTitle.isNotEmpty)
                      Text(
                        '原名：${data.originalTitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: secondary,
                      ),
                    if (data.facts.isNotEmpty)
                      Text(
                        data.facts,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: secondary,
                      ),
                    if (data.people.isNotEmpty)
                      Text(
                        data.people,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: secondary,
                      ),
                    if (data.overview.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          data.overview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: secondary,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「当前」标记：钉住的那一条在结果里就地标出来，用户不必去别处对照 id。
class _CurrentBadge extends StatelessWidget {
  const _CurrentBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 1),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.14),
        borderRadius: AppRadius.pillAll,
      ),
      child: Text(
        '当前',
        style: theme.textTheme.labelSmall?.copyWith(color: primary),
      ),
    );
  }
}

String _metaLine({
  required int year,
  required bool isTv,
  int episodeCount = 0,
  String seasonLabel = '',
}) => [
  if (year > 0) '$year',
  isTv ? '剧集' : '电影',
  if (episodeCount > 0) '$episodeCount 集',
  if (seasonLabel.isNotEmpty) seasonLabel,
].join(' · ');

/// 简介折成一行：Bangumi 的 summary 带 CRLF，直接喂多行文本会先吃掉一行空行。
String _flatten(String? text) =>
    (text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
