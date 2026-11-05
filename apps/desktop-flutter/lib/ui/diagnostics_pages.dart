/// 设置页、日志页与站点健康页（§17.2 设置页 / 日志页 / 站点健康页）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/history_view.dart';
import '../core/osd_config.dart';
import '../core/playback_diagnostics.dart';
import '../services/log_service.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import '../state/sync_state.dart';
import 'ai_settings_page.dart';
import 'app.dart';
import 'common.dart';
import 'advanced_settings_page.dart';
import 'config_pages.dart';
import 'player_button_config_page.dart';
import 'scroll_behavior.dart';
import 'source_field.dart';
import 'tokens.dart';
import 'toast.dart';

/// 设置页：TMDB、运行信息、目录、缓存维护、合规说明。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final info = state.startupInfo;
    final tmdb = state.tmdbConfig;
    final sync = state.syncState;
    // 设置页是**表单**：收进限宽内容列。
    //
    // 不这么做的话，1440px 窗口下 `SwitchListTile` 会把开关钉到最右边，
    // 与它的标签相距约 1300px——"启用 TMDB 增强"和那个开关的关联就断了
    // （截图复核时发现，2026-10-11）。内容网格与播放器**不用**这个约束。
    return ListView(
      padding: formPagePadding(context),
      children: [
        // 外观：主题模式。
        //
        // 星等星表以**暗色为主身份**（夜间、坐在电脑前的使用场景），
        // 亮色是独立设计的「昼间星表」，不是暗色的自动反转。
        //
        // 本次改造之前这里根本没有开关：`app.dart` 曾硬编码
        // `themeMode: ThemeMode.dark`，亮色主题对用户**完全不可达**。
        Text('外观', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<ThemeMode>(
          key: const ValueKey('settings-theme-mode'),
          segments: const [
            ButtonSegment<ThemeMode>(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode_outlined, size: 18),
              label: Text('暗色'),
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode_outlined, size: 18),
              label: Text('亮色'),
            ),
            ButtonSegment<ThemeMode>(
              value: ThemeMode.system,
              icon: Icon(Icons.brightness_auto_outlined, size: 18),
              label: Text('跟随系统'),
            ),
          ],
          selected: {themeModeOf(state.themeMode)},
          onSelectionChanged: (selection) {
            state.setThemeMode(themeModeName(selection.first));
          },
        ),
        const Divider(height: 32),
        // 历史记录区块（`docs/phase6/design/01` §4.3）。
        //
        // 为什么放在设置页而不是历史页顶部：这是**一次定好、长期生效**的
        // 行为偏好，与主题、搜索线程同类；历史页顶部那排是每次操作的临时控件。
        Text('历史记录', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          key: const ValueKey('settings-history-click-action'),
          segments: const [
            ButtonSegment<String>(
              value: UiHistoryClickAction.detail,
              icon: Icon(Icons.article_outlined, size: 18),
              label: Text('进入详情页'),
            ),
            ButtonSegment<String>(
              value: UiHistoryClickAction.play,
              icon: Icon(Icons.play_arrow, size: 18),
              label: Text('直接播放'),
            ),
          ],
          selected: {state.historyClickAction},
          onSelectionChanged: (selection) {
            state.setHistoryClickAction(selection.first);
          },
        ),
        const SizedBox(height: 8),
        Text(
          '点击历史记录时的行为。长按卡片始终进入删除状态。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 32),
        // AI 助手区块（`docs/phase6/design/04` §7.6）。
        //
        // 与 TMDB 区块同样**无条件可见**：未配置时也要有入口，
        // 否则用户永远进不来（Phase 4 的发布包实测缺陷）。
        Text('AI 助手', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          state.aiReady
              ? '已启用（协议 ${state.aiConfig.protocol}）'
              : '未配置：用于季度弹窗的「AI 识别剧集/季度」',
          key: const ValueKey('settings-ai-summary'),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('settings-ai-open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AiSettingsPage(state: state),
            ),
          ),
          icon: const Icon(Icons.auto_awesome),
          label: const Text('打开 AI 设置'),
        ),
        const Divider(height: 32),
        // 搜索区块。
        //
        // 为什么放在设置页而不是搜索页：搜索页顶部那排筛选是**每次搜索临时调**
        // 的（分组/相似度），而「并发线程数」是**一次定好、长期生效**的容量设置，
        // 和主题一样属于配置项；上游也把它放在设置里
        // （`Setting.getSearchThread()`，label「搜索线程」）。
        Text('搜索', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '并发线程：${state.searchThread}'
          '（同时搜索的站点数上限，1~100；默认 20）',
          key: const ValueKey('settings-search-thread-summary'),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('settings-search-thread'),
          onPressed: () async {
            final value = await showNumberSliderDialog(
              context,
              title: '搜索线程',
              current: state.searchThread,
              minValue: 1,
              maxValue: 100,
              hint: '同时搜索的站点数量上限。调高更快，但更容易触发上游限流',
              keyPrefix: 'search-thread',
            );
            if (value != null) await state.setSearchThread(value);
          },
          icon: const Icon(Icons.speed_outlined),
          label: const Text('调整搜索线程'),
        ),
        const SizedBox(height: 8),
        Text(
          '下一次搜索立即生效；已经在跑的搜索不受影响。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 32),
        // TMDB 区块（`04` §10.3）：设置页必须有独立入口。
        // 只靠详情页状态条会形成死锁——未配置时详情页也可能没有区块，
        // 用户就永远进不来（发布包实测缺陷）。
        Text('TMDB 元数据增强', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          tmdb.isReady
              ? '已启用（站点规则 ${tmdb.disabledSites.length} 条禁用'
                    '${tmdb.enabledSites.isEmpty ? '' : '、${tmdb.enabledSites.length} 条启用'}）'
              : '未配置：填写 API Key 或 Access Token 后启用',
          key: const ValueKey('settings-tmdb-summary'),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('settings-tmdb-open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TmdbSettingsPage(state: state),
            ),
          ),
          icon: const Icon(Icons.movie_filter_outlined),
          label: const Text('打开 TMDB 设置'),
        ),
        const Divider(height: 32),
        // 安卓接入区块（Phase 5）。
        //
        // **必须与 TMDB 解耦**：该入口曾挂在 `TmdbSettingsPage` 底部，而 TMDB
        // 设置页要先点「打开 TMDB 设置」再滚到底才能看到——发布包实测反馈
        // 「没看到打开安卓接入」，用户以为功能没编进去。两层嵌套入口不可接受。
        //
        // 另一层原因：安卓接入与 TMDB 无任何语义关系（一个是站源接入，一个是
        // 元数据增强），寄生在 TMDB 页里会让人以为「先配好 TMDB 才能接安卓」。
        Text('安卓接入', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        // 摘要必须基于**持久化**证据，不能只看 `sync.devices`。
        //
        // `sync.devices` 是**内存态**（本次会话探测到的设备），`load()` 只恢复
        // `deviceHistory`/`peers`，从不恢复它。所以只看 `devices` 时，用户明明
        // 接入过、重启后也自动恢复到了桥接配置，设置页却永远写「未接入」
        // （用户反馈 2026-10-09：「重新打开后是自动接入了但是设置页面的状态
        // 没有及时更新」——实测其 `settings.json` 里 `peers` 已有 1 台，
        // 但 `devices` 为空）。
        // 因此取三者地址的**并集**：本次探测 + 历史接入 + 已授权对端。
        Text(_androidSummary(sync), key: const ValueKey('settings-android-summary')),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('settings-android-open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AndroidSettingsPage(state: state),
            ),
          ),
          icon: const Icon(Icons.android_outlined),
          label: const Text('打开安卓接入'),
        ),
        const Divider(height: 32),
        Text('运行信息', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (info == null)
          const Text('启动信息尚未就绪。')
        else
          SelectableText(info.detailLines),
        const Divider(height: 32),
        Text('本地数据', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SelectableText(
          '配置：${state.paths.configDir}\n'
          '数据：${state.paths.dataDir}\n'
          '缓存：${state.paths.cacheDir}\n'
          '日志：${state.paths.logDir}',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () async {
                await state.resetCache();
                if (context.mounted) {
                  showToast('缓存目录已重建', kind: ToastKind.success);
                }
              },
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清理缓存目录'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: state.log.export()),
                );
                if (context.mounted) {
                  showToast('已复制脱敏日志', kind: ToastKind.success);
                }
              },
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('复制脱敏日志'),
            ),
          ],
        ),
        const Divider(height: 32),
        Text('隐私与合规', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const SelectableText(usageBoundaryNotice),
        const SizedBox(height: 12),
        const Text(
          '• 遥测与崩溃上报：关闭（未实现上报通道）\n'
          '• 站点配置同步：关闭（Phase 4 能力）\n'
          '• 自动更新：不更新站源，仅更新应用本体',
        ),
        const Divider(height: 32),
        // 站点健康：**独立页面**，不在这里铺开。
        //
        // 为什么搬出去（用户反馈 2026-10-12）：这块原本直接铺在设置页底部，
        // 而它是一张 7 列的宽表，把设置页挤得又长又杂；同时它和「外观 / TMDB /
        // 安卓接入」这些**设置项**语义不同——它是**诊断读数**，不是配置项。
        // 现在按 TMDB / 安卓接入同样的模式给一个入口，进独立页看。
        Text('站点健康', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(_healthSummary(state)),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('settings-site-health-open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SiteHealthPage(state: state),
            ),
          ),
          icon: const Icon(Icons.monitor_heart_outlined),
          label: const Text('打开站点健康'),
        ),
        const Divider(height: 32),
        // 播放器区块（`docs/phase8/design/02` §5、`design/03` §6.1）。
        //
        // 为什么放在设置页：屏显开关与按钮排版是**一次定好、长期生效**的偏好，
        // 与主题、历史点击行为同类。同时它们也是**非右键的等价路径**
        // （`docs/phase8/design/00` §5 第 10 条：右键菜单不得成为唯一入口）。
        //
        // **位置必须在最末尾**（Task 11 回归时修正，实测）：
        // 本页是**惰性 `ListView`**，只有进入视口（含 cacheExtent）的条目才会
        // 被构建。新增区块插在中间会把后面所有既有入口整体下推，而
        // `integration_test/ui_redesign_visual_flow_test.dart:991` 用
        // `1440×2400` 视口断言 `settings-site-health-open` 必须被构建——
        // 实测：插在搜索区块之后 → 内容总高 2000 → 2540，站点健康入口落到
        // 视口外，`find` 直接找不到，既有集成测试红。
        // 放到最末尾后，被下推的只有**本区块自己**，既有入口位置不变。
        Text('播放器', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '屏显（OSD）：播放画面上叠加的信息角标。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Column(
          key: const ValueKey('settings-osd'),
          children: [
            // 网速已实现：`PlayerController.sampleNetworkRate` 读 mpv 的
            // `raw-input-rate`，`player_page.dart` 的 `_sampleNetworkRate` 只在
            // **本开关打开时**才去采样，`player_osd.dart` 只在打开时渲染。
            // 所以它和其余 6 项一样可点，点下去真的有效果。
            //
            // 上一版这里是「未实现 → 置灰」，理由是「不得让开关可点却无效果」。
            // 那条纪律继续有效，只是前提变了：能力已经落地，再置灰等于把一个
            // 能用的功能藏起来。将来若要停用某项，先删能力再置灰，别留一个
            // 点了没反应的开关。
            for (final id in OsdFlag.values)
              SwitchListTile(
                key: ValueKey('settings-osd-$id'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(_osdLabel(id)),
                // 副标题只解释**数据来源**，不承诺任何未实现的能力：
                // 用户看到屏显上的 `—` 时需要知道那是「取不到」，而不是「卡了」。
                //
                // 不写具体属性名：数据源是 `demuxer-cache-state` 内含的字段
                // 加 `cache-speed` 回退，对用户没有意义；写一个属性名反而会把
                // 实现细节钉死在一个可能再变的名字上（上一版就写错过）。
                subtitle: id == OsdFlag.traffic
                    ? const Text('取自播放引擎的网络输入速率；取不到时显示 —')
                    : null,
                value: state.osdFlags[id] ?? false,
                onChanged: (value) => state.setOsdFlag(id, value),
              ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('settings-player-buttons'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PlayerButtonConfigPage(state: state),
            ),
          ),
          icon: const Icon(Icons.tune),
          label: const Text('播放器按钮排版'),
        ),
        const SizedBox(height: 8),
        Text(
          '调整底部控制栏的按钮顺序与显示状态。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 32),
        const Divider(height: 32),
        // Phase 9：高级设置（直播/广告/解析/弹幕/字幕/播放参数/站点注入）。
        //
        // 独立成页而不是继续堆在这里：设置页是长表单，既有测试用固定视口且
        // 不带 `ensureVisible`（`docs/phase8/design/05` §5）。收进独立页后
        // 既有入口位置不变。
        Text('高级设置', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
          '直播回退、广告过滤、解析失败切换、站点排序、弹幕源、字幕源、'
          '播放参数与站点注入。',
          key: ValueKey('settings-advanced-summary'),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const ValueKey('settings-advanced-open'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AdvancedSettingsPage(state: state),
            ),
          ),
          icon: const Icon(Icons.tune),
          label: const Text('打开高级设置'),
        ),
      ],
    );
  }

  /// 站点健康摘要：只给一行结论，细节进独立页。
  String _healthSummary(AppState state) {
    final records = state.siteHealth();
    final sites = state.siteItems;
    if (sites.isEmpty) return '当前配置没有站点';
    if (records.isEmpty) {
      return '${sites.length} 个站点 · 尚无实测记录（浏览、搜索或播放后开始累计）';
    }
    return '${sites.length} 个站点 · 已有 ${records.length} 个站点的实测记录';
  }

  /// 安卓接入状态摘要。
  ///
  /// 取三种来源地址的**并集**，任一非空就算「已接入」：
  /// - `devices`：本次会话探测到的设备（内存态）；
  /// - `deviceHistory`：历史接入过的地址（**已落盘**，重启仍在）；
  /// - `peers`：已授权同步的对端（**已落盘**）。
  ///
  /// 为何不能用单一来源：只看 `devices` 时重启后必然显示「未接入」（见 build 里
  /// 的注释）；只看 `deviceHistory` 则用户刚扫到、还没导入时也不显示。
  String _androidSummary(SyncState sync) {
    final addresses = <String>{
      for (final device in sync.devices) device.reachableBase,
      for (final entry in sync.deviceHistory) entry.address,
      for (final peer in sync.peers) peer.address,
    }..removeWhere((value) => value.trim().isEmpty);

    if (addresses.isEmpty) {
      return '未接入：可扫描局域网，或手动输入安卓设备地址';
    }
    final buffer = StringBuffer('已接入 ${addresses.length} 台设备');
    if (sync.peers.isNotEmpty) {
      buffer.write('，已授权 ${sync.peers.length} 台');
    }
    if (sync.serverRunning) {
      buffer.write('，同步服务已开启');
    }
    return buffer.toString();
  }
}

/// 屏显开关的中文名（`docs/phase8/design/02` §5.1）。
///
/// 与 [OsdFlag] 的 id 一一对应；未知 id 回落成 id 本身（不抛异常，
/// 与 `normalizeOsdFlags` 的「只接受合法值」同一口径）。
String _osdLabel(String id) {
  switch (id) {
    case OsdFlag.title:
      return '标题';
    case OsdFlag.size:
      return '分辨率';
    case OsdFlag.time:
      return '时钟';
    case OsdFlag.progress:
      return '播放进度';
    case OsdFlag.traffic:
      return '网速';
    case OsdFlag.mini:
      return '迷你进度条';
    case OsdFlag.diagnostics:
      return '诊断面板';
    default:
      return id;
  }
}

/// 站点健康：源场点阵 + 逐站实测明细。
///
/// 为什么单独一页（用户反馈 2026-10-12）：源场原本放在**首页内容区第一块**，
/// 意图是"先回答哪个源能用，再谈看什么"。真实配置下这个前提不成立——
/// 实测 170 个站源里 **160 个没有采样记录**，于是一大片灰点占了首屏近三分之一
/// 高度，既没有信息量又把海报内容挤了下去。健康度是**按需查看的诊断信息**，
/// 不是每次打开都要读的首页主角。
class SiteHealthPage extends StatelessWidget {
  const SiteHealthPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = state.siteHealth();
    final magnitudes = buildMagnitudes(
      items: state.siteItems,
      health: {for (final record in records) record.siteKey: record},
    );
    final unknown = magnitudes
        .where((item) => item.status == SourceStatus.unknown)
        .length;

    return Scaffold(
      appBar: AppBar(title: const Text('站点健康')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          if (magnitudes.isNotEmpty) ...[
            SourceField(magnitudes: magnitudes),
            const SizedBox(height: AppSpace.lg),
          ],
          if (unknown > 0)
            // 未知占比高时把原因说清楚：不是"这些源坏了"，而是**还没用过**。
            // 不解释的话，一大片灰点会被读成"我的源全挂了"。
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.lg),
              child: Text(
                '其中 $unknown 个站点尚无实测记录：它们是还没调用过的站点，'
                '不代表不可用。浏览、搜索或播放之后会开始累计成功率。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Text('逐站明细', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpace.md),
          _HealthTable(items: records),
        ],
      ),
    );
  }
}

class _HealthTable extends StatelessWidget {
  const _HealthTable({required this.items});

  final List<SiteHealth> items;

  String _rate(int ok, int total) {
    if (total == 0) return '暂无数据';
    return '$ok/$total (${(ok / total * 100).toStringAsFixed(0)}%)';
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Text('还没有调用记录。浏览、搜索或播放后会累计成功率与耗时。');
    }
    return HorizontalMouseDrag(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('站点')),
            DataColumn(label: Text('首页')),
            DataColumn(label: Text('分类')),
            DataColumn(label: Text('详情')),
            DataColumn(label: Text('播放')),
            DataColumn(label: Text('平均耗时')),
            DataColumn(label: Text('最近错误')),
          ],
          rows: [
            for (final item in items)
              DataRow(
                cells: [
                  DataCell(Text(item.siteKey)),
                  DataCell(Text(_rate(item.homeOk, item.homeTotal))),
                  DataCell(Text(_rate(item.categoryOk, item.categoryTotal))),
                  DataCell(Text(_rate(item.detailOk, item.detailTotal))),
                  DataCell(Text(_rate(item.playOk, item.playTotal))),
                  DataCell(Text('${item.avgLatencyMs}ms')),
                  DataCell(
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Text(
                        item.lastError ?? '-',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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

/// 日志页：结构化日志、级别过滤、导出（§17.2 日志页，§18.2 日志脱敏）。
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.state});

  final AppState state;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  LogLevel? _filter;

  @override
  Widget build(BuildContext context) {
    final entries = widget.state.log.entries
        .where((entry) => _filter == null || entry.level == _filter)
        .toList()
        .reversed
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.state.lastDiagnostics != null)
          _PlaybackDiagnosticsCard(diagnostics: widget.state.lastDiagnostics!),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Text('级别过滤：'),
              const SizedBox(width: 8),
              DropdownButton<LogLevel?>(
                underline: const SizedBox.shrink(),
                value: _filter,
                items: [
                  const DropdownMenuItem(value: null, child: Text('全部')),
                  for (final level in LogLevel.values)
                    DropdownMenuItem(
                      value: level,
                      child: Text(level.name.toUpperCase()),
                    ),
                ],
                onChanged: (value) => setState(() => _filter = value),
              ),
              const Spacer(),
              Text('${entries.length} 条'),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: widget.state.log.export()),
                  );
                  if (context.mounted) {
                    showToast('已复制脱敏日志', kind: ToastKind.success);
                  }
                },
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                label: const Text('复制全部'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: '暂无日志',
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return SelectableText(
                      entry.line,
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        fontFamilyFallback: const ['monospace'],
                        fontSize: 12,
                        color: switch (entry.level) {
                          LogLevel.error => Theme.of(context).colorScheme.error,
                          LogLevel.warning => Colors.orangeAccent,
                          LogLevel.info => Theme.of(context).colorScheme.primary,
                          LogLevel.debug => Theme.of(context).textTheme.bodySmall
                              ?.color,
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 最近一次播放诊断卡片（§23：输出引擎/格式/网络/错误）。
///
/// 在日志页顶部展示，提供“一眼可定位”的关键字段与完整的可复制报告。
class _PlaybackDiagnosticsCard extends StatelessWidget {
  const _PlaybackDiagnosticsCard({required this.diagnostics});

  final PlaybackDiagnostics diagnostics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = diagnostics.succeeded == false;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: failed
              ? theme.colorScheme.error
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.monitor_heart_outlined,
                size: 18,
                color: failed ? theme.colorScheme.error : null,
              ),
              const SizedBox(width: 8),
              Text('最近播放诊断', style: theme.textTheme.titleSmall),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: diagnostics.report),
                  );
                  if (context.mounted) {
                    showToast('已复制播放诊断', kind: ToastKind.success);
                  }
                },
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: const Text('复制'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _chip('引擎', PlaybackEngine.displayName(diagnostics.engine)),
              _chip('格式', diagnostics.format.label),
              if (diagnostics.target.host.isNotEmpty)
                _chip('主机', diagnostics.target.host),
              if (diagnostics.flag != null && diagnostics.flag!.isNotEmpty)
                _chip('线路', diagnostics.flag!),
              _chip(
                '网络',
                diagnostics.target.scheme.isEmpty
                    ? '未知'
                    : '${diagnostics.target.scheme}'
                        '${diagnostics.target.isSecure ? '（加密）' : ''}',
              ),
              _chip(
                '结果',
                switch (diagnostics.succeeded) {
                  true => '成功',
                  false => '失败',
                  null => '进行中',
                },
              ),
              for (final stage in PlaybackStage.values)
                if (diagnostics.elapsedOf(stage) != null)
                  _chip(
                    stage.label,
                    '${diagnostics.elapsedOf(stage)!.inMilliseconds}ms',
                  ),
            ],
          ),
          if (failed) ...[
            const SizedBox(height: 8),
            Text(
              diagnostics.failureHint ?? '播放失败',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, String value) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: Text('$label：$value'),
  );
}
