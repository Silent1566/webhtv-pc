/// 最近观看与收藏页（§17.2 历史页 / 收藏页，§15）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_error.dart';
import '../core/history_aggregation.dart';
import '../core/history_grouping.dart';
import '../core/history_scope.dart';
import '../core/history_view.dart';
import '../services/history_poster_repair.dart';
import '../services/storage.dart';
import '../services/tmdb_history.dart';
import '../state/app_state.dart';
import '../core/protocol.dart';
import 'app.dart';
import 'browse_pages.dart';
import 'common.dart';
import 'history_cross_source.dart';
import 'history_resume_seed.dart';
import 'playback_resume.dart';
import 'tokens.dart';
import 'viewing_report_page.dart';
import 'toast.dart';

// `restoreHistoryPlaybackTarget` 已下沉到服务层（`proxy_server.dart`）；
// 这里重新导出，保持既有测试与调用方的 import 不变。
export '../services/proxy_server.dart' show restoreHistoryPlaybackTarget;

/// 历史卡片的目标列宽。
///
/// 与首页海报墙（`browse_pages.dart` 的 `_poster*`）是**同一套尺度**：
/// `DESIGN.md` 的「内容网格」写明全站共用「目标列宽 150px、列间距 14px、
/// 网格内边距 16px、海报下方文字区高 40px」。首页那份是文件私有常量，这里
/// 只能各自声明——**改动时必须两处一起改**，否则两块海报墙的尺度会分叉。
const double _historyCardTargetWidth = 150;

/// 历史卡片列间距（= 首页海报墙的列间距，见上）。
const double _historyCardSpacing = 14;

/// 历史卡片海报下方的文字区高度（片名 + 集名两行）。
///
/// 给死高度而不是让它自适应：格子高度由「海报 2:3 + 本值」精确算出，文字区
/// 一旦浮动，海报就会被压成非 2:3（与首页 `_posterCaptionHeight` 同理）。
const double _historyCaptionHeight = 40;

/// 文字区允许的**最大**放大倍数（无障碍字号只缩不放）。
///
/// 与首页 `_VodCard` 同值同理由：文字区是固定高度，放大时不让步就会溢出格子。
const double _historyTextScaleMax = 1.25;

/// 历史范围开关：只看当前播放源 / 看全部源。
///
/// 桥接后每台安卓设备上的每个源都是一条独立配置记录，站点 key 会重名
/// （都是 `csp_xxx`），不隔离就会出现跨源串进度。默认按源隔离；
/// 对齐安卓的 `global_history_mode` 开关（用户反馈 2026-10-26）。
class _HistoryScopeSwitch extends StatelessWidget {
  const _HistoryScopeSwitch({required this.state, required this.onChanged});

  final AppState state;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final global = state.historyScopeIsGlobal;
    return Tooltip(
      message: global ? '当前显示全部播放源的历史' : '当前只显示当前播放源的历史',
      child: OutlinedButton.icon(
        key: const ValueKey('history-scope-switch'),
        onPressed: () async {
          await state.setHistoryScope(
            global ? UiHistoryScope.source : UiHistoryScope.global,
          );
          onChanged();
        },
        icon: Icon(global ? Icons.public : Icons.filter_alt_outlined),
        label: Text(global ? '全部来源' : '当前来源'),
      ),
    );
  }
}

/// 历史聚合模式开关：同名作品合并 / 每集独立。
///
/// 用户 2026-10-27：「历史记录需要支持同名聚合……最好是默认这种模式同时保留
/// 现在没集独立的历史记录格式允许用户手动切换」。因此这里做成一个两态开关
/// （聚合 ↔ 逐条），默认聚合，选择落进 preferences。
class _HistoryAggregationSwitch extends StatelessWidget {
  const _HistoryAggregationSwitch({required this.state, required this.onChanged});

  final AppState state;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final off = state.historyAggregationIsOff;
    return Tooltip(
      message: off
          ? '当前每集一条独立历史；点此改为按同名作品聚合'
          : '当前按同名作品聚合；点此改为每集一条独立历史',
      child: OutlinedButton.icon(
        key: const ValueKey('history-aggregation-switch'),
        onPressed: () async {
          await state.setHistoryAggregation(
            off ? UiHistoryAggregation.tmdb : UiHistoryAggregation.off,
          );
          onChanged();
        },
        icon: Icon(off ? Icons.view_list_outlined : Icons.layers_outlined),
        label: Text(off ? '逐集' : '聚合'),
      ),
    );
  }
}

/// 非当前源的来源角标。
///
/// 为什么用主题色而不是固定色：角标落在海报上，海报画面色彩不可控，
/// 固定的半透明白/黑在某些封面上会不可读（与 [_HistoryBadge] 同一理由）。
class _HistorySourceChip extends StatelessWidget {
  const _HistorySourceChip({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.swap_horiz,
            size: 11,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onTertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.state});

  final AppState state;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String _keyword = '';

  /// 删除模式状态机（`docs/phase6/design/01` §3.1）。
  ///
  /// 纯逻辑在 `core/history_view.dart`（不依赖 Flutter），这里只持有实例。
  HistoryViewState _view = HistoryViewState.initial;

  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_repairMissingPosters());
    });
  }

  /// 当前展示的分组（聚合卡 / 逐条记录，取决于 [AppState.historyAggregation]）。
  ///
  /// 删除态与多选态仍按**记录级 id** 工作（见 [_deleteOne] / [_confirmDeleteSelected]）：
  /// 聚合卡是多条记录的**读视图**，删除必须逐条落到真实记录上，
  /// 否则「删一张卡」会连带抹掉别的集的进度。
  List<HistoryGroup> get _groups => _state.historyGroups(keyword: _keyword);

  /// 当前展示的历史记录（拍平，供既有按条逻辑使用）。
  List<PlaybackHistory> get _items => _keyword.isEmpty
      ? _state.recentHistory()
      : _state.searchHistory(_keyword);

  /// 空态。
  ///
  /// 「当前来源」按源严格过滤（`05` §6.1）之后，页面为空**不等于**没有历史：
  /// 全部来源里可能还有一屏看不见的记录，也可能全是归属不到源的老记录。
  /// 这时还写「暂无播放记录 / 播放任意剧集后会自动记录进度」就是假话，用户
  /// 会反复播放却始终看不到新记录——2026-10-28 反馈的另一面。
  Widget _emptyHistory() {
    final global = _state.historyScopeIsGlobal;
    final total = global ? 0 : _state.historyCount(sourceKey: '');
    if (_keyword.isNotEmpty || global || total == 0) {
      return const EmptyState(
        icon: Icons.history_outlined,
        title: '暂无播放记录',
        message: '播放任意剧集后会自动记录进度。',
      );
    }
    final unclaimed = _state.unclaimedHistoryCount();
    return EmptyState(
      icon: Icons.history_outlined,
      title: '当前来源暂无记录',
      message: unclaimed > 0
          ? '全部来源里还有 $total 条记录，其中 $unclaimed 条归属不到具体播放源'
                '（迁移前的老记录，或同步时判不出来源），只在「全部来源」里显示。'
          : '全部来源里还有 $total 条记录，来自其他播放源。',
      action: TextButton.icon(
        key: const ValueKey('history-empty-show-all'),
        onPressed: () async {
          await _state.setHistoryScope(UiHistoryScope.global);
          if (mounted) setState(() {});
        },
        icon: const Icon(Icons.public, size: 18),
        label: const Text('查看全部来源'),
      ),
    );
  }

  /// 把聚合投影里的代表记录还原成**真实的** PlaybackHistory。
  ///
  /// 为什么需要还原：HistoryGroupInput 是 core/ 的标量投影（不依赖
  /// services/storage.dart），而删除 / 播放 / 详情都要走既有按条 API，
  /// 那些 API 收的是带数据库 id 的 PlaybackHistory。按 id 回查而不是
  /// 重新构造：避免两个模型字段漂移时删错记录。
  PlaybackHistory? _recordOf(HistoryGroupInput input) {
    for (final record in _items) {
      if (record.id == input.id) return record;
    }
    return null;
  }

  /// 旧版本历史没有保存海报：打开历史页时后台补齐，避免用户看到一屏破图占位。
  /// 只处理前 12 条且按作品去重，不阻塞历史页首帧。
  ///
  /// 取图交给 [HistoryPosterRepair] 的三级回退：这里只负责挑候选、写结果、
  /// 重画。**为什么不能只查生效配置**：历史里混着别的播放源，它们的站点在
  /// 自己那份配置里，按生效配置找不到站点时补图就整条被跳过（原缺陷）。
  Future<void> _repairMissingPosters() async {
    final service = _state.siteService;
    if (service == null) return;
    final candidates = <PlaybackHistory>[];
    final seen = <String>{};
    for (final item in _items) {
      if (item.vodPic != null && item.vodPic!.trim().isNotEmpty) continue;
      final key = '${item.siteKey}@@@${item.vodId}';
      if (seen.add(key)) candidates.add(item);
      if (candidates.length >= 12) break;
    }
    if (candidates.isEmpty) return;
    final repair = HistoryPosterRepair(
      siteService: service,
      configForSourceKey: _state.configForSourceKey,
      cachedTmdbPosterUrl: (siteKey, vodId) =>
          _state.cachedTmdbPosterUrl(siteKey: siteKey, vodId: vodId),
      fallbackConfig: _state.config,
    );
    var changed = false;
    for (final item in candidates) {
      // 单条旧记录补图失败不影响历史列表和继续播放。
      final poster = await repair.posterFor(item);
      if (poster == null || poster.trim().isEmpty) continue;
      _state.updateHistoryPoster(item, poster);
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final groups = _groups;
    // Esc 退出删除态（`design/01` §3.1 的「退出方式」列）。
    //
    // 用 `CallbackShortcuts` + `Focus(autofocus: true)`，与播放页同一套写法
    // （`player_page.dart` 的 `buildPlayerShortcuts`）：无需自建 `Intent` 类，
    // 且不需要 `Actions` 映射。
    //
    // 只在非 `none` 态才消费 Esc：否则会把 Esc 从壳层其它控件手里抢走。
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_view.mode != HistoryViewMode.none) _exitDeleteMode();
        },
      },
      child: Focus(
        autofocus: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索片名或剧集名',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() {
                    final next = value.trim();
                    _keyword = next;
                    // 搜索词变化**不退出**模式，但多选态下必须清空已选
                    // （否则会删到看不见的条目，`design/01` §3.2）。
                    // `withKeyword` 在值未变时返回同一实例，所以这里
                    // 无条件调用是安全的——它不会把用户刚勾的项清掉。
                    _view = _view.withKeyword(next);
                  }),
                ),
              ),
              const SizedBox(width: 12),
              // 工具栏按模式渲染（`design/01` §3.1）：
              // 多选态下只留「取消」在工具栏，其余动作在下面的多选工具栏里。
              if (_view.mode == HistoryViewMode.none) ...[
                // 列表为空时**两个删除入口都不渲染**（§3.2）。
                // 历史范围开关（对齐安卓 `global_history_mode`）：默认只看
                // **当前播放源**，开了才看全部源。
                _HistoryScopeSwitch(
                  state: _state,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(width: 8),
                _HistoryAggregationSwitch(
                  state: _state,
                  onChanged: () => setState(() {}),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const ValueKey('history-viewing-report'),
                  onPressed: _openViewingReport,
                  icon: const Icon(Icons.insights_outlined),
                  label: const Text('观影报告'),
                ),
                const SizedBox(width: 8),
                if (items.isNotEmpty)
                  OutlinedButton.icon(
                    key: const ValueKey('history-bulk-delete'),
                    onPressed: () =>
                        setState(() => _view = _view.enterMultiSelect()),
                    icon: const Icon(Icons.checklist_outlined),
                    label: const Text('批量删除'),
                  ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: const ValueKey('history-clear-all'),
                  onPressed: _confirmClearAll,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('清空历史'),
                ),
              ],
            ],
          ),
        ),
        if (_state.database == null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('本地存储不可用，播放历史暂不记录。'),
          ),
        // 删除态提示条（`design/01` §3.1）。
        //
        // 删掉最后一条 → 列表为空 → 自动回到 `none`（§3.2），提示条随之消失。
        if (_view.mode == HistoryViewMode.singleDelete)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text('删除模式：点击卡片即删除该条记录'),
                ),
                TextButton(
                  key: const ValueKey('history-delete-done'),
                  onPressed: _exitDeleteMode,
                  child: const Text('完成'),
                ),
              ],
            ),
          ),
        // 多选态工具栏（`design/01` §3.1、§3.3）。
        if (_view.mode == HistoryViewMode.multiSelect)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _view.selectedIds.isEmpty
                        ? '批量删除：勾选要删除的记录'
                        : '已选 ${_view.selectedIds.length} 条',
                  ),
                ),
                TextButton(
                  key: const ValueKey('history-select-all'),
                  // 只勾**当前可见**的（§3.2）：搜索后被挡住的不得被勾。
                  onPressed: () => setState(
                    () => _view = _view.selectAll([
                      for (final item in items) item.id,
                    ]),
                  ),
                  child: const Text('全选'),
                ),
                TextButton(
                  key: const ValueKey('history-delete-selected'),
                  // 未勾选时**禁用**（`DESIGN.md`：一个点了什么也没有的
                  // 按钮比没有按钮更糟）。
                  onPressed: _view.canDeleteSelected
                      ? _confirmDeleteSelected
                      : null,
                  child: Text('删除选中(${_view.selectedIds.length})'),
                ),
                TextButton(
                  key: const ValueKey('history-cancel-select'),
                  onPressed: () => setState(() => _view = _view.exitMode()),
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        const Divider(height: 1),
        // 季度历史卡片（`02` §7.1）：同一节目的每季一张卡片。
        // 删除语义按 §7.4 分级：删季度卡片不删同节目其他季度；
        // 「删除整部节目」是独立二级操作，需二次确认。
        if (_state.seasonHistoryCards().isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text('季度进度'),
          ),
          for (final card in _state.seasonHistoryCards())
            ListTile(
              key: ValueKey('season-card-${card.displayKey}'),
              dense: true,
              leading: const Icon(Icons.playlist_play),
              title: Text(
                '${card.identity?.key ?? '?'} · ${card.seasonLabel} · '
                '第 ${card.episodeNumber} 集',
              ),
              subtitle: Text(
                '${card.representative.sourceEpisodeName} · '
                '${card.progressPercent}% · 来源 ${card.representative.sourceFlag}'
                '${card.sources.length > 1 ? ' （共 ${card.sources.length} 个来源）' : ''}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '删除该季度进度（不影响同节目其他季度）',
                    onPressed: () {
                      final identity = card.identity;
                      if (identity == null) return;
                      _state.deleteSeasonProgress(
                        media: identity,
                        seasonNumber: card.seasonNumber,
                      );
                      setState(() {});
                    },
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                  IconButton(
                    tooltip: '删除整部节目的全部季度进度（二级操作）',
                    onPressed: () => _confirmDeleteMedia(card),
                    icon: const Icon(Icons.delete_forever_outlined, size: 18),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
        ],
        Expanded(
          child: groups.isEmpty
              ? _emptyHistory()
              // 列数必须由**内容区**宽度推出，而不是 `MediaQuery` 的整窗宽：
              // 壳层左侧有 `NavigationRail`(76) + `VerticalDivider`(1)，整窗宽
              // 会比内容区宽 77px，列数就会比首页海报墙多算（`design/01` §2.2
              // 要求两处共用同一套尺度）。
              : LayoutBuilder(
                  builder: (context, constraints) => GridView.builder(
                    key: const ValueKey('history-grid'),
                    padding: const EdgeInsets.all(AppSpace.lg),
                    gridDelegate: _historyGridDelegate(constraints.maxWidth),
                    itemCount: groups.length,
                    itemBuilder: (context, index) =>
                        _buildHistoryCard(context, groups[index]),
                  ),
                ),
        ),
          ],
        ),
      ),
    );
  }

  /// 网格度量：与首页海报墙同一套算法（`browse_pages.dart#_gridDelegate`）。
  ///
  /// 为什么不用 `SliverGridDelegateWithMaxCrossAxisExtent`：它的
  /// `mainAxisExtent` 是固定值，窗口变窄时列宽变小、高度不变，海报会被
  /// 压成非 2:3 或被裁切。这里列宽已知，格子高度就能精确算成
  /// 「海报 2:3 + 文字区」。
  static SliverGridDelegate _historyGridDelegate(double maxWidth) {
    final usable = maxWidth - AppSpace.lg * 2;
    final columns = (usable / (_historyCardTargetWidth + _historyCardSpacing))
        .round()
        .clamp(2, 12);
    final cellWidth = (usable - (columns - 1) * _historyCardSpacing) / columns;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: _historyCardSpacing,
      mainAxisSpacing: AppSpace.sm,
      mainAxisExtent: cellWidth * 1.5 + AppSpace.sm + _historyCaptionHeight,
    );
  }

  /// 单张历史卡片（对齐上游 `res/layout/adapter_vod.xml`）。
  ///
  /// 卡片渲染的是**一组**（[HistoryGroup]）：聚合模式下是同名作品合并后的
  /// 一张卡，逐集模式下组内恒为一条记录。两种形态共用同一套尺寸，
  /// 只有角标与副标题不同。
  ///
  /// **片名只渲染一次 `Text`**：`integration_test/phase5_sync_flow_test.dart`
  /// 按 `find.text(name)` 断言 `findsOneWidget`。`Tooltip` 的 `message` 是字符串、
  /// 不产生 `Text`，但这里仍然不加 tooltip——片名与集名已各占一行。
  Widget _buildHistoryCard(BuildContext context, HistoryGroup group) {
    final theme = Theme.of(context);
    final item = group.representative;
    // 来源标注（用户 2026-10-27：「标注当前线路和非当前线路」）。
    // 组内成员可能来自多个源：只要**有一个非当前源**就标注，并给出总数。
    final otherSources = [
      for (final sourceKey in group.sourceKeys)
        if (sourceKey.isNotEmpty && sourceKey != _state.activeSourceKey) sourceKey,
    ];
    final unknownSource = group.members.any((m) => m.sourceKey.isEmpty);
    final String? sourceLabel;
    if (otherSources.isNotEmpty) {
      final names = <String>[];
      for (final key in otherSources) {
        final label = _state.historySourceLabel(key);
        if (label != null && !names.contains(label)) names.add(label);
      }
      sourceLabel = names.isEmpty
          ? '其他来源'
          : (names.length == 1 ? names.first : '${names.length} 个其他来源');
    } else if (unknownSource) {
      sourceLabel = '来源未知';
    } else {
      sourceLabel = null;
    }
    final isOtherSource = otherSources.isNotEmpty;
    return InkWell(
      key: ValueKey('history-row-${item.id}'),
      onTap: () => _onCardTap(group),
      onLongPress: _onCardLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // `AspectRatio` 保证海报 2:3：文字区再高也不会把海报压变形。
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PosterImage(url: item.vodPic),
                  // 多选态：左上角复选框（§3.1）。
                  if (_view.mode == HistoryViewMode.multiSelect)
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Icon(
                        key: ValueKey('history-checkbox-${item.id}'),
                        _view.selectedIds.contains(item.id)
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        color: _view.selectedIds.contains(item.id)
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  // 删除态：盖一层删除遮罩（对齐上游 `@id/delete`）。
                  if (_view.mode == HistoryViewMode.singleDelete)
                    Container(
                      key: ValueKey('history-delete-overlay-${item.id}'),
                      color: theme.colorScheme.surface.withValues(alpha: 0.72),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.delete_outline,
                        size: 32,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  // 删除态下隐藏进度角标（对齐上游：删除态是「另一个模式」）。
                  if (_view.mode != HistoryViewMode.singleDelete)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: _HistoryBadge(
                        text: item.completed
                            ? '已看完'
                            : '已看 ${item.progressPercent}%',
                      ),
                    ),
                  // 来源标注（非当前源才显示）：右上角一枚 chip。
                  if (_view.mode != HistoryViewMode.singleDelete &&
                      isOtherSource)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: _HistorySourceChip(
                        key: ValueKey('history-source-chip-${item.id}'),
                        label: sourceLabel ?? '其他来源',
                      ),
                    ),
                  // 聚合数量：组内多于一条时显示「N 集」，
                  // 让用户一眼看出这张卡是合并过的而不是单条记录。
                  if (_view.mode != HistoryViewMode.singleDelete &&
                      group.aggregated)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: _HistoryBadge(
                        key: ValueKey('history-group-count-${item.id}'),
                        text: '${group.members.length} 条',
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 2px 进度条紧贴海报下沿（对齐上游 `@id/progress`）。
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: LinearProgressIndicator(
              value: item.progress,
              minHeight: 2,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          // 文字区与首页 `_VodCard` 同形：`Expanded` + 夹住缩放。
          // `Expanded` 把文字区钉在固定高度上（格子高度已由 `mainAxisExtent`
          // 算死），海报 2:3 不受文字影响。
          //
          // 字号/行高也**照抄首页 `_VodCard`**（13/1.2 与 11/1.2，而不是 M3 默认的
          // 14/1.43 与 12/1.33）：这不是为了「好看」，是 1.25 倍 clamp 能不能成立
          // 的算术前提——40px 文字区在 1.25 倍下只放得下 32px 的本征高度，
          // M3 默认两行要 35.98px（×1.25 = 44.98px，溢出 5px，已实测）。
          // 首页那套 28.8px（×1.25 = 36px）才留得住 4px 余量；两者不一致会让
          // 「同一套尺度」名存实亡（`design/01` §2.2 第 1 条要求取值一致）。
          Expanded(
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: _historyTextScaleMax,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    item.vodName,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13,
                      height: 1.2,
                    ),
                  ),
                  Text(
                    // 非当前源时把来源名并进副标题：用户需要知道「这条是哪个源
                    // 的进度」，而 chip 空间只够写很短的名字。
                    sourceLabel == null
                        ? item.episodeName
                        : '${item.episodeName} · $sourceLabel',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      height: 1.2,
                      color: isOtherSource
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 卡片点击（Task 8 会按设置分流；此处先保持既有行为）。
  /// 卡片点击（`docs/phase6/design/01` §3.2）。
  ///
  /// 删除态下「点谁删谁」（对齐上游 `HistoryAdapter#setClickListener`）；
  /// 多选态下只切换勾选；默认态按设置分流（Task 8 补）。
  void _onCardTap(HistoryGroup group) {
    final record = _recordOf(group.representative);
    if (record == null) return;
    final item = record;
    switch (_view.mode) {
      case HistoryViewMode.singleDelete:
        _deleteOne(item);
      case HistoryViewMode.multiSelect:
        setState(() => _view = _view.toggleSelection(item.id));
      case HistoryViewMode.none:
        unawaited(_openBySetting(group));
    }
  }

  /// 长按：进入 / 退出删除态（对齐上游 `OnClickListener#onLongClick`）。
  ///
  /// 多选态下长按**不切到**删除态：两个模式的入口互斥（§3.1 的状态图里
  /// 没有 `multiSelect → singleDelete` 这条边），否则用户在多选态误长按会
  /// 丢掉已勾选的集合。
  void _onCardLongPress() {
    setState(() {
      _view = switch (_view.mode) {
        HistoryViewMode.singleDelete => _view.exitMode(),
        HistoryViewMode.multiSelect => _view,
        HistoryViewMode.none => _view.enterSingleDelete(),
      };
    });
  }

  /// 删除一条。
  ///
  /// **必须逐条走 `state.deleteHistory`**：它同时写 `history_deletions` 标记，
  /// 否则安卓下次推来旧记录会复活（`docs/phase5/design/02` §4.5）。
  void _deleteOne(PlaybackHistory item) {
    _state.deleteHistory(item.id);
    setState(() {
      // 判定基准是**过滤后的可见列表**：搜索出 1 条、删掉它之后才退出；
      // 全量还有条目但被搜索挡住时**不**退出（`design/01` §3.2）。
      final remaining = _items.where((row) => row.id != item.id).length;
      if (remaining == 0) _view = _view.exitMode();
    });
  }

  /// 退出删除态 / 多选态（顶部「完成」与「取消」共用）。
  ///
  /// 两个模式都用 `exitMode()`：它回到 `none` 并清空选中集（`design/01` §3.2）。
  void _exitDeleteMode() => setState(() => _view = _view.exitMode());

  /// 批量删除确认（`docs/phase6/design/01` §3.3）。
  ///
  /// 必须写明**条数**与**不可撤销**：一次删多条是破坏性操作。
  /// 第二条说明来自 `docs/phase5/design/02` §4.5：删除会写
  /// `history_deletions` 标记，避免远端旧记录复活。
  Future<void> _confirmDeleteSelected() async {
    final ids = _view.selectedInOrder;
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('history-bulk-confirm-dialog'),
        title: const Text('批量删除播放历史'),
        content: Text(
          '将删除选中的 ${ids.length} 条播放历史。\n'
          '该操作不可撤销；已同步到安卓的删除标记会随下次同步生效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('history-bulk-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // **逐条**删除：走既有的 `deleteHistory` 才能写 `history_deletions` 标记
    // （`docs/phase5/design/02` §4.5）。直接改本地列表会让远端旧记录复活。
    for (final id in ids) {
      _state.deleteHistory(id);
    }
    if (!mounted) return;
    setState(() => _view = _view.exitMode());
  }

  /// 打开观影报告（Phase 9 · P2-2）。
  ///
  /// 空列表也允许进入：报告页有自己的空态与范围切换，不需要先有历史。
  Future<void> _openViewingReport() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ViewingReportPage(state: _state),
      ),
    );
  }

  /// 清空历史确认。
  ///
  /// 文案与逻辑**与既有实现一字不差**（`mvp_a_flow_test` 锁定「清空历史」），
  /// 只是从 `onPressed` 内联搬到方法里。
  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空播放历史'),
        content: const Text('该操作只清空播放历史，不会删除配置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _state.clearHistory();
    if (!mounted) return;
    setState(() => _view = _view.exitMode());
  }

  /// 「删除整部节目」二级操作（`02` §7.4）：必须先明确告知将删除的季度数量。
  Future<void> _confirmDeleteMedia(SeasonHistoryCard card) async {
    final identity = card.identity;
    if (identity == null) return;
    final count = _state.seasonProgressFor(identity).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('season-delete-media-confirm'),
        title: const Text('删除整部节目的播放进度'),
        content: Text(
          '将删除「${identity.key}」下全部 $count 个季度的播放进度。\n'
          '该操作不可撤销；同季度的其他来源也会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('season-delete-media-confirm-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除全部'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _state.deleteMediaProgress(identity);
    if (mounted) setState(() {});
  }

  /// 从历史恢复播放（实现见 `playback_resume.dart`：崩溃恢复横幅共用同一条路径）。
  ///
  /// 按「点击历史行为」设置分流（`docs/phase6/design/01` §4.1）：
  /// 默认 `detail`（进详情页），`play` 则是既有行为（直接续播）。
  Future<void> _openBySetting(HistoryGroup group) {
    final record = _recordOf(group.representative);
    if (record == null) return Future<void>.value();
    final item = record;
    // 跨源续播（用户 2026-10-27）：这条记录属于**非当前播放源**时，先按
    // 「在当前源里找可替代站点」解析，而不是直接抛「站点已不在当前配置中」。
    // 逐集模式下 group 恒为单条，行为与既有实现一致。
    if (_state.isHistoryFromOtherSource(item)) {
      return openHistoryFromOtherSource(context, _state, item);
    }
    return _state.historyClickAction == UiHistoryClickAction.play
        ? resumeHistoryEntry(context, _state, item)
        : _openDetail(item);
  }

  /// 打开该条历史对应的详情页。
  ///
  /// **必须先切站点**：`DetailPage` 的详情请求依赖「当前站点」，
  /// 不切会串到别的站点去取详情（与 `search_page.dart#_openResult` 同因）。
  ///
  /// 站点已不在当前配置中时**不静默失败**：历史可能来自旧配置或安卓推送，
  /// 用户需要知道为什么没反应。
  Future<void> _openDetail(PlaybackHistory item) async {
    final state = _state;
    final config = state.config;
    final site = config?.sites
        .where((candidate) => candidate.key == item.siteKey)
        .firstOrNull;
    if (site == null) {
      if (!mounted) return;
      showToast('该记录所属站点已不在当前配置中：${item.siteKey}', kind: ToastKind.error);
      return;
    }
    await state.selectSite(site);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          state: state,
          vod: Vod(
            vodId: item.vodId,
            vodName: item.vodName,
            vodPic: item.vodPic,
          ),
          // **必须传用户点的那一条**的线路与集入口：同一部剧有多条历史时，
          // 点旧记录却续新记录是错的（`docs/phase6/design/02` §7.1）。
          historyFlag: item.flag,
          historyEpisodeId: item.episodeId,
          // 进度也要传：`_play` 里那条"查本机历史"的路子依赖当前站点，
          // 站点被换过（同 url 不同 key、或配置重导入）就落空 → 从头播。
          // 带上原记录进度后由 `resolveResumeStart` 判定同集再迁移。
          resumeSeed: resumeSeedOf(item),
        ),
      ),
    );
  }
}

/// 海报左下角的进度角标（对齐上游 `@id/playback` 的半透明底胶囊）。
///
/// 底色取 `colorScheme.surface` 而不是写死黑：海报画面色彩不可控，而这里的
/// 文字用主题的 `labelSmall`，底与字必须成对取自同一主题才不会在亮色主题下
/// 变成「深底深字」。
class _HistoryBadge extends StatelessWidget {
  const _HistoryBadge({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }
}

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final items = state.favorites();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Text(
                '收藏（${items.length}）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: 12),
              const Text('收藏站点、影片或分组；数据保存在本地数据库。'),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? const EmptyState(
                  icon: Icons.bookmark_border,
                  title: '暂无收藏',
                  message: '在详情页右上角可以收藏影片。',
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return ListTile(
                      leading: Icon(
                        item.kind == 'vod'
                            ? Icons.movie_outlined
                            : Icons.dns_outlined,
                      ),
                      title: Text(item.title),
                      subtitle: Text(
                        '类型=${item.kind} 站点=${item.siteKey} '
                        '目标=${item.targetId}'
                        '${item.subtitle == null ? "" : " · ${item.subtitle}"}',
                      ),
                      trailing: IconButton(
                        tooltip: '取消收藏',
                        onPressed: () {
                          state.database?.removeFavorite(
                            kind: item.kind,
                            siteKey: item.siteKey,
                            targetId: item.targetId,
                          );
                          (context as Element).markNeedsBuild();
                        },
                        icon: const Icon(Icons.bookmark_remove_outlined),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 本地实现的 firstOrNull，避免为单个用法引入 `package:collection`。
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    for (final item in this) {
      return item;
    }
    return null;
  }
}

/// 便于测试与诊断：把历史列表渲染成纯文本。
String describeHistory(List<PlaybackHistory> items) => items
    .map(
      (item) =>
          '${item.vodName} | ${item.episodeName} | ${item.progressPercent}% | '
          '${item.completed ? "completed" : "in-progress"}',
    )
    .join('\n');

/// 保持对 [AppError] 的显式引用，便于本文件单独测试错误提示。
String describeHistoryError(AppError error) => error.userMessage;
