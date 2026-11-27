/// 设置页、日志页与站点健康页（§17.2 设置页 / 日志页 / 站点健康页）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/history_view.dart';
import '../core/playback_diagnostics.dart';
import '../services/log_service.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import '../state/sync_state.dart';
import 'ai_settings_page.dart';
import 'ad_block_page.dart';
import 'ai_integration_widgets.dart';
import 'app.dart';
import 'app_update_page.dart';
import 'backup_page.dart';
import 'common.dart';
import 'config_pages.dart';
import 'danmaku_settings_page.dart';
import 'meta_sources_page.dart';
import 'health_filter_controls.dart';
import 'injected_sites_page.dart';
import 'intro_skip_options_page.dart';
import 'lut_presets_page.dart';
import 'local_sources_page.dart';
import 'osd_settings_page.dart';
import 'pan_check_page.dart';
import 'player_button_config_page.dart';
import 'python_environment_page.dart';
import 'scroll_behavior.dart';
import 'source_field.dart';
import 'spider_page.dart';
import 'subtitle_settings_page.dart';
import 'settings_detail_pages.dart';
import 'settings_layout.dart';
import 'site_self_check_panel.dart';
import 'runtime_dependencies_page.dart';
import 'tokens.dart';
import 'toast.dart';

/// 设置分类的稳定标识与显示名。
///
/// 分类 key 是**公开契约**：宽窗左侧分类栏与窄窗顶部分类条使用同一组
/// `settings-category-<id>` key，同一时刻只渲染其中一套，因此**同一页面内**
/// 每个 key 恰好出现一次（测试与自动化按此定位）。
///
/// 「同一页面内」而不是「全局」：播放器 push 出来的「全部设置」页复用同一个
/// 中枢本体，首页那一份仍挂在外壳里，所以整棵树里可以有两份——两者互不同屏，
/// 且默认 `find.byKey` 会跳过离屏那一份。
///
/// 分类只影响**显示**：切换分类不写 `settings.json`，不进 `AppState`。
///
/// 六个类别按**用途**划分，不再有「高级设置」这类兜底页（它原先的 19 个控件
/// 把站点、网络、工具与隐私混在一个入口下面，播放参数要三级才到）：
/// 偏好 = 外观与日常；播放 = 看片时的行为；弹幕 = 显示参数与弹幕库；
/// 站点与内容 = 源与搜索；连接与服务 = 外部账号与出站请求；维护 = 本机运行与排查。
/// 于是任意设置**最多两级可达**。
///
/// 「弹幕」为什么单独成类：它原先只有「播放 → 弹幕源」一行，管的是地址；
/// 显示参数（透明度/字号/速度/行数…）则只存在于播放器弹层里。两件事合并成
/// 一页后，它既不是「播放」也不是「站点」，塞进任何一类都会让那一类的用途变糊。
const List<SettingsCategory> kSettingsCategories = [
  SettingsCategory(SettingsCategory.preferences, '偏好', Icons.tune_outlined),
  SettingsCategory(SettingsCategory.playback, '播放', Icons.play_circle_outline),
  SettingsCategory(SettingsCategory.danmaku, '弹幕', Icons.comment_outlined),
  SettingsCategory(SettingsCategory.sites, '站点与内容', Icons.public_outlined),
  SettingsCategory(SettingsCategory.connections, '连接与服务', Icons.hub_outlined),
  SettingsCategory(SettingsCategory.maintenance, '维护', Icons.build_outlined),
];

/// 一个设置分类：稳定 id + 显示名 + 图标。
class SettingsCategory {
  const SettingsCategory(this.id, this.label, this.icon);

  static const String preferences = 'preferences';
  static const String playback = 'playback';
  static const String danmaku = 'danmaku';
  static const String sites = 'sites';
  static const String connections = 'connections';
  static const String maintenance = 'maintenance';

  final String id;
  final String label;
  final IconData icon;
}

/// 设置首页：分类中枢的宿主（外壳里的一个标签页）。
///
/// 布局（用户截图否定了「两张内容列并排堆叠」的旧形态）：宽窗是
/// **左侧分类导航 + 右侧当前类别单列**，两者以一条发丝线分隔；内容区
/// 窄到放不下分类栏时，分类条移到顶部、正文仍是单列。
///
/// 本页只负责「带页标题」这一件事：分类模型、导航与正文都在
/// [SettingsCategoriesBody]，播放器右键菜单 push 出来的 `SettingsOverviewPage`
/// 用的是同一个 body，两处不会分叉。
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.state,
    this.initialCategory = SettingsCategory.preferences,
  });

  final AppState state;
  final String initialCategory;

  @override
  Widget build(BuildContext context) =>
      SettingsCategoriesBody(state: state, initialCategory: initialCategory);
}

/// 分类中枢本体：[SettingsPage] 与「全部设置」页共用。
///
/// 分类与各分类的滚动位置是本组件自己的 **UI 状态**，不进 `AppState`、
/// 不落盘；返回子页后分类与滚动位置都还在。
/// 本组件**不监听** `AppState`（旧契约不变：由宿主在 `notifyListeners` 后
/// 重建内容区）。
///
/// 类别内排版是行式入口：进入下一级的工具整行可点、成组开关进明细页、
/// 单个开关就地生效，字段用统一的标题—控件—脚注节奏。
/// 字段、默认值、回调与保存时机都没有改。
class SettingsCategoriesBody extends StatefulWidget {
  const SettingsCategoriesBody({
    super.key,
    required this.state,
    this.showHeader = true,
    this.initialCategory = SettingsCategory.preferences,
  });

  final AppState state;

  /// 是否渲染页标题（「设置 + 一句说明」）。
  ///
  /// 独立路由（「全部设置」页）已有 AppBar 标题，再画一次就是同屏两个标题。
  final bool showHeader;

  /// 仅决定首次展示的分类；普通设置入口仍从偏好开始。
  final String initialCategory;

  @override
  State<SettingsCategoriesBody> createState() => _SettingsCategoriesBodyState();
}

class _SettingsCategoriesBodyState extends State<SettingsCategoriesBody> {
  /// 内容区宽度门槛：低于它就把分类栏挪到顶部（逻辑像素）。
  ///
  /// 取值理由：分类栏 196 + 两处 16 间距 + 1 发丝线 = 229。门槛 720 时
  /// 正文还剩约 490，是设置表单还能读的下限；再窄就该把导航让出来。
  /// 于是 1024 及以上的宽窗走左栏，720 与 480 走顶部分类条。
  static const double _navMinWidth = 720;

  /// 左侧分类栏宽度（设计稿 180–200）。
  static const double _navWidth = 196;

  late String _category;

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
  }

  /// 每类别一个滚动控制器：切走再回来时用它恢复位置。
  final Map<String, ScrollController> _scrollControllers = {};

  /// 每类别最后已知的滚动位置（控制器在列表被替换后会脱离，位置存这里）。
  final Map<String, double> _scrollOffsets = {};

  AppState get state => widget.state;

  ScrollController _controllerFor(String id) =>
      _scrollControllers.putIfAbsent(id, () {
        final controller = ScrollController();
        controller.addListener(() {
          if (controller.hasClients) {
            _scrollOffsets[id] = controller.offset;
          }
        });
        return controller;
      });

  @override
  void dispose() {
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _selectCategory(String id) {
    if (id == _category) return;
    setState(() => _category = id);
  }

  @override
  Widget build(BuildContext context) {
    final tmdb = state.tmdbConfig;
    final sync = state.syncState;

    // 每个类别的正文都直接从字段/行开始：类别名已经在左栏（或顶部分类条）
    // 写过一次，正文再套一层同名 SettingsSection 只是把标题读两遍。
    final preferences = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsField(
          label: '外观',
          child: SegmentedButton<ThemeMode>(
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
        ),
        SettingsField(
          label: '历史记录',
          hint: '点击历史记录时的行为。长按卡片始终进入删除状态。',
          child: SegmentedButton<String>(
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
        ),
        SettingsField(
          label: '搜索',
          hint: '下一次搜索立即生效；已经在跑的搜索不受影响。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '并发线程：${state.searchThread}'
                '（同时搜索的站点数上限，1~100；默认 20）',
                key: const ValueKey('settings-search-thread-summary'),
              ),
              const SizedBox(height: AppSpace.md),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
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
              ),
            ],
          ),
        ),
      ],
    );

    // 「播放」= 看片时的行为。整类都是「一行入口」：原本就地摊在这里的
    // 屏显（7 个开关）已经进独立页，同屏不再有第二种行形态。
    final playback = SettingsRowList(
      children: [
        SettingsNavRow(
          key: const ValueKey('settings-player-buttons'),
          icon: Icons.view_week_outlined,
          title: '播放器按钮排版',
          subtitle: '调整底部控制栏的按钮顺序与显示状态。',
          onTap: () => _push(context, PlayerButtonConfigPage(state: state)),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-player-options-open'),
          icon: Icons.tune,
          title: '播放参数',
          // 片头片尾与屏显现在各自有一行，不再写进这一行的副标题。
          subtitle:
              '硬件解码 ${_onOff(state.playerOptions.hardwareDecoding)}'
              ' · 自动连播 ${_onOff(state.playerOptions.autoNext)}'
              ' · 缓存 ${state.playerOptions.demuxerMaxBytesMiB} MiB',
          onTap: () => _push(context, PlaybackOptionsPage(state: state)),
        ),
        // LUT 此前只挂在播放画面右键菜单上，设置里没有等价入口（DESIGN.md：
        // 右键菜单不是唯一入口）。它管的是「内置 / 我的 / 在线」三类预设，
        // 不是一个开关，所以放明细页而不是就地摊开。
        SettingsNavRow(
          key: const ValueKey('settings-lut-open'),
          icon: Icons.palette_outlined,
          title: 'LUT 滤镜',
          subtitle: LutPresetsPage.summary(state.playerOptions),
          onTap: () => _push(
            context,
            LutPresetsPage(
              store: state.lutStore,
              options: state.playerOptions,
              onChanged: (value) => state.setPlayerOptions(value),
            ),
          ),
        ),
        // 片头片尾跳过留在这一级：原先埋在「播放参数」第二层，用户反馈两次找不到。
        // 入口的可见性比开关本身更重要。
        SettingsNavRow(
          key: const ValueKey('settings-skip-open'),
          icon: Icons.skip_next_outlined,
          title: '跳过片段',
          subtitle: IntroSkipOptionsPage.summary(state.playerOptions),
          onTap: () => _push(context, IntroSkipOptionsPage(state: state)),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-osd-open'),
          icon: Icons.ondemand_video_outlined,
          title: '屏显（OSD）',
          subtitle: osdSummary(state),
          onTap: () => _push(context, OsdSettingsPage(state: state)),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-subtitle-open'),
          icon: Icons.subtitles_outlined,
          title: '字幕源',
          subtitle: state.subtitleSettings.hasAnyProvider
              ? '已配置${state.subtitleSettings.autoMatch ? " · 自动匹配已开" : ""}'
              : '未配置：播放结果没有字幕时不会自动匹配',
          subtitleKey: const ValueKey('settings-subtitle-summary'),
          onTap: () => _push(
            context,
            SubtitleSettingsPage(state: state, paths: state.paths),
          ),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-live-open'),
          icon: Icons.live_tv_outlined,
          title: '直播',
          subtitle: _liveSummary(),
          onTap: () => _push(context, LiveSettingsPage(state: state)),
        ),
      ],
    );

    // 「弹幕」= 显示参数 + 弹幕库，合并成一页（`DanmakuSettingsPage`）。
    // 这一类只有一行入口：设置项全部在明细页里，分类页不该再摊第二层。
    final danmaku = SettingsRowList(
      children: [
        SettingsNavRow(
          key: const ValueKey('settings-danmaku-open'),
          icon: Icons.comment_outlined,
          title: '弹幕设置',
          // 副标题口径只写在 `DanmakuSettingsPage.summary` 一处：地址来源有三档，
          // 只按手填值判断会把「站点配置/本地猫源提供了地址」误报成未配置。
          subtitle: DanmakuSettingsPage.summary(state),
          subtitleKey: const ValueKey('settings-danmaku-summary'),
          onTap: () => _push(context, DanmakuSettingsPage(state: state)),
        ),
      ],
    );

    // 「站点与内容」= 站源、搜索顺序与站点请求链。成组开关进明细页，
    // 单个开关就地生效：一个开关再套一层页面只是多一次点击。
    final sites = SettingsRowList(
      children: [
        SettingsNavRow(
          key: const ValueKey('settings-config-management-open'),
          icon: Icons.settings_outlined,
          title: '配置管理',
          subtitleKey: const ValueKey('settings-config-management-summary'),
          subtitle: _configSummary(),
          onTap: () => _push(context, ConfigPage(state: state)),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-site-health-open'),
          icon: Icons.monitor_heart_outlined,
          title: '站点健康',
          subtitle: _healthSummary(state),
          onTap: () => _push(context, SiteHealthPage(state: state)),
        ),
        // 加固壳解包运行时与 Python 运行时是**同一类东西**（本地程序运行时、
        // 按需获取、只影响对应站源类型），原来前者在本组、后者在「维护」组：
        // 用户从站源错误信息找过来时要先猜它在哪一组。现在收成一个区块入口，
        // 后续同类依赖（Node/JRE）只在该区块里加一行。
        SettingsNavRow(
          key: const ValueKey('settings-runtime-dependencies-open'),
          icon: Icons.memory_outlined,
          title: '运行时与外部依赖',
          subtitleKey: const ValueKey('settings-runtime-dependencies-summary'),
          subtitle: _runtimeDependenciesSummary(),
          onTap: () => _push(context, RuntimeDependenciesPage(state: state)),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-group-rules-open'),
          icon: Icons.account_tree_outlined,
          title: '分组规则',
          subtitle:
              '${state.siteGroupSettings.rules.length} 条规则'
              ' · ${state.siteGroupSettings.rules.where((e) => e.enabled).length} 条启用',
          onTap: () => _push(context, SiteGroupRulesPage(state: state)),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-injected-sites-open'),
          icon: Icons.code_outlined,
          title: '站点注入',
          subtitle: state.injectedSites.isEmpty
              ? '未注入站点：可粘贴站点 JSON 追加到站点列表'
              : '已注入 ${state.injectedSites.length} 个站点'
                    '（启用 ${state.injectedSites.where((e) => e.enabled).length}）',
          subtitleKey: const ValueKey('settings-injected-sites-summary'),
          onTap: () => _push(context, InjectedSitesPage(state: state)),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-local-sources-open'),
          icon: Icons.folder_open_outlined,
          title: '本地源',
          subtitle: '扫描本机媒体目录，按文件名匹配剧集',
          onTap: () => _push(context, LocalSourcesPage(state: state)),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-pan-check-open'),
          icon: Icons.link_outlined,
          title: '网盘检测',
          subtitle: '粘贴分享链接检测有效性',
          onTap: () => _push(context, PanCheckPage(state: state)),
        ),
        _switch(
          key: const ValueKey('settings-ad-block'),
          icon: Icons.block,
          title: '启用配置中的广告规则',
          subtitle:
              '${state.config?.ads.length ?? 0} 个广告主机 · '
              '${state.config?.hlsRules.length ?? 0} 条 HLS 规则；规则为空时无效果',
          value: state.adBlockEnabled,
          onChanged: state.setAdBlockEnabled,
        ),
        SettingsNavRow(
          key: const ValueKey('settings-ad-block-open'),
          icon: Icons.shield_outlined,
          title: '去广告',
          subtitleKey: const ValueKey('settings-ad-block-summary'),
          subtitle: _adBlockSummary(state),
          onTap: () => _push(context, AdBlockPage(state: state)),
        ),
        _switch(
          key: const ValueKey('settings-parse-failover'),
          icon: Icons.swap_calls,
          title: '解析接口失败时尝试其他接口',
          subtitle: '按配置顺序最多再试一个；只尝试 JSON 类接口',
          value: state.parseFailoverSettings.enabled,
          onChanged: (value) => state.setParseFailoverSettings(
            state.parseFailoverSettings.copyWith(enabled: value),
          ),
        ),
        _switch(
          key: const ValueKey('settings-site-health-sort'),
          icon: Icons.sort,
          title: '按站点健康排序搜索结果',
          subtitle: '成功的站点优先；没有实测记录的站点排在最后',
          value: state.siteOrder.healthSort,
          onChanged: (value) =>
              state.setSiteOrder(state.siteOrder.copyWith(healthSort: value)),
        ),
      ],
    );

    // 「连接与服务」= 需要外部账号或外部系统的部分；出站代理与 DoH 也在这一类：
    // 它们改的都是本站**发出**的请求，与站源无关。
    final connections = SettingsRowList(
      children: [
        SettingsNavRow(
          key: const ValueKey('settings-ai-open'),
          icon: Icons.auto_awesome,
          title: 'AI 助手',
          subtitle: state.aiReady
              ? '已启用（协议 ${state.aiConfig.protocol}）· 端点、密钥与提示词'
              : '未配置：先填端点/密钥/模型；内容智能与阅读器共用这套配置',
          subtitleKey: const ValueKey('settings-ai-summary'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AiSettingsPage(state: state),
            ),
          ),
        ),
        // AI 迁移新增：内容智能 / 推荐 / 阅读器 / 唱声评分都在这一个页面里。
        SettingsNavRow(
          key: const ValueKey('settings-ai-business-open'),
          icon: Icons.auto_awesome_outlined,
          title: 'AI 业务与阅读器',
          subtitle: '内容智能、推荐、阅读器与唱声评分（用「AI 助手」那套配置）',
          onTap: () => openAiBusiness(context, state),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-tmdb-open'),
          icon: Icons.movie_filter_outlined,
          title: 'TMDB 凭据与站点规则',
          subtitle: tmdb.isReady
              ? '已启用（站点规则 ${tmdb.disabledSites.length} 条禁用'
                    '${tmdb.enabledSites.isEmpty ? '' : '、${tmdb.enabledSites.length} 条启用'}）'
              : '未配置：填写 API Key 或 Access Token 后启用',
          subtitleKey: const ValueKey('settings-tmdb-summary'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TmdbSettingsPage(state: state),
            ),
          ),
        ),
        // 元数据来源与 TMDB 凭据是两件事：前者管「用哪家、谁优先、聚合什么」，
        // 后者只管 TMDB 自己的 Key 与站点规则。合并成一个条目会让用户找不到
        // 「数据来源」这项设置（用户反馈 2026-11-18）。
        SettingsNavRow(
          key: const ValueKey('settings-meta-sources-open'),
          icon: Icons.hub_outlined,
          title: '元数据来源与优先级',
          subtitle: state.externalMetaEnabled
              ? 'TMDB / 豆瓣 / Bangumi / Wikidata / 爬虫源，逐字段设优先或聚合'
              : '外部请求已关闭：仍按规则使用 TMDB 与爬虫源',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MetaSourcesPage(state: state),
            ),
          ),
        ),
        // 摘要必须基于**持久化**证据，不能只看 `sync.devices`。
        //
        // `sync.devices` 是**内存态**（本次会话探测到的设备），`load()` 只恢复
        // `deviceHistory`/`peers`，从不恢复它。所以只看 `devices` 时，用户明明
        // 接入过、重启后也自动恢复到了桥接配置，设置页却永远写「未接入」
        // （用户反馈 2026-10-09：「重新打开后是自动接入了但是设置页面的状态
        // 没有及时更新」——实测其 `settings.json` 里 `peers` 已有 1 台，
        // 但 `devices` 为空）。
        // 因此取三者地址的**并集**：本次探测 + 历史接入 + 已授权对端。
        SettingsNavRow(
          key: const ValueKey('settings-android-open'),
          icon: Icons.android_outlined,
          title: '安卓接入',
          subtitle: _androidSummary(sync),
          subtitleKey: const ValueKey('settings-android-summary'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AndroidSettingsPage(state: state),
            ),
          ),
        ),
        // 出站代理与 DoH 改的是本站**发出**的请求，与站源无关：原来埋在
        // 「高级设置 → 网络」，与账号类入口分在两处，现在和它们同屏。
        SettingsNavRow(
          key: const ValueKey('settings-outbound-proxy-open'),
          icon: Icons.hub_outlined,
          title: '出站代理',
          subtitle: _outboundProxySummary(),
          onTap: () => _push(context, OutboundProxyPage(state: state)),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-doh-open'),
          icon: Icons.dns_outlined,
          title: '加密 DNS（DoH）',
          subtitle: dohStatusText(state),
          onTap: () => _push(context, DohSettingsPage(state: state)),
        ),
      ],
    );

    // 「维护」= 本机运行、排查与一次性动作。长文本都进了「关于与数据」。
    final maintenance = SettingsRowList(
      children: [
        SettingsNavRow(
          key: const ValueKey('settings-python-environment-open'),
          icon: Icons.terminal_outlined,
          title: '运行环境',
          subtitle: '内置 Python 与依赖；可检测、离线修复、选择自定义解释器。',
          subtitleKey: const ValueKey('settings-python-environment-summary'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PythonEnvironmentPage(state: state),
            ),
          ),
        ),
        // Spider 运行时与日志原来是侧栏的两个常驻入口（2026-11-22 用户决策：
        // 侧栏不再单独占位）。它们与本类同一个用途——本机进程在不在跑、坏了看什么。
        SettingsNavRow(
          key: const ValueKey('settings-spider-open'),
          icon: Icons.extension,
          title: 'Spider 运行时',
          subtitle: '运行时状态、本地 Spider 清单、强制停止与重置',
          onTap: () => openSpiderPage(context, state),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-logs-open'),
          icon: Icons.receipt_long,
          title: '日志与诊断',
          subtitle: '结构化日志、播放诊断、级别过滤与导出',
          onTap: () => openLogsPage(context, state),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-backup-open'),
          icon: Icons.settings_backup_restore,
          title: '备份与恢复',
          subtitle: '导出设置与数据库，或从备份恢复',
          onTap: () => _push(context, BackupPage(state: state)),
        ),
        SettingsNavRow(
          key: const ValueKey('settings-browser-open'),
          icon: Icons.web_asset_outlined,
          title: '浏览器内核',
          subtitle: 'Web 嗅探使用本机 Chromium 内核',
          onTap: () => _push(context, BrowserEnginePage(paths: state.paths)),
        ),
        // 应用本体的版本与更新：它和「本机进程在不在跑」同属「这一台机器的
        // 运行状态」，所以落在维护类，而不是「关于与数据」（那里是长文本说明）。
        SettingsNavRow(
          key: const ValueKey('settings-update-open'),
          icon: Icons.system_update_alt,
          title: '软件更新',
          // 摘要口径只写在 AppUpdatePage.summary 一处：行上写「已是最新」、
          // 进页面却看到「发现新版本」这种自相矛盾，源头就是两处各推一次文案。
          subtitle: AppUpdatePage.summary(state),
          subtitleKey: const ValueKey('settings-update-summary'),
          onTap: () => _push(context, AppUpdatePage(state: state)),
        ),
        // 目录、启动信息与合规说明都是「查一次就够」的长文本：进独立页，
        // 分类页只留一行入口（原来三块长文本把这一类结尾拉得很长）。
        SettingsNavRow(
          key: const ValueKey('settings-about-data-open'),
          icon: Icons.info_outline,
          title: '关于与数据',
          subtitle: '本机目录、缓存维护、运行信息与隐私说明',
          onTap: () => _push(context, AboutDataPage(state: state)),
        ),
        _switch(
          key: const ValueKey('settings-incognito'),
          icon: Icons.visibility_off_outlined,
          title: '隐身模式',
          subtitle: '不写播放历史与搜索记录；季度进度等历史投影同样不写',
          value: state.incognito,
          onChanged: state.setIncognito,
        ),
        _switch(
          key: const ValueKey('settings-spider-debug-log'),
          icon: Icons.bug_report_outlined,
          title: '详细调试日志（爬虫入参/出参）',
          subtitle:
              '记录每次爬虫 IPC 调用的完整请求参数与响应结果（落盘前脱敏），'
              '单份日志上限放大到 20MB。切换即时生效；日志量很大，排查完请关掉',
          value: state.spiderDebugLog,
          onChanged: state.setSpiderDebugLog,
        ),
      ],
    );

    final contents = <String, Widget>{
      SettingsCategory.preferences: preferences,
      SettingsCategory.playback: playback,
      SettingsCategory.danmaku: danmaku,
      SettingsCategory.sites: sites,
      SettingsCategory.connections: connections,
      SettingsCategory.maintenance: maintenance,
    };

    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        // 表单列限宽：宽窗下正文居中，与明细页同一个 900 宽度口径。
        padding: EdgeInsets.symmetric(
          horizontal:
              AppSpace.lg +
              (constraints.maxWidth > kFormMaxWidth
                  ? (constraints.maxWidth - kFormMaxWidth) / 2
                  : 0),
          vertical: AppSpace.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showHeader)
              const SettingsPageHeader(
                title: '设置',
                description: '调整日常偏好、播放体验与连接服务。',
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, inner) {
                  // 只把**当前类别**放进树里：其余类别的内容不渲染，
                  // 于是「两列内容同时展开」这个旧形态在结构上不可能出现。
                  final body = _categoryContent(contents[_category]!);
                  if (inner.maxWidth < _navMinWidth) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _categoryStrip(context),
                        const SizedBox(height: AppSpace.md),
                        const Divider(height: 1),
                        const SizedBox(height: AppSpace.md),
                        Expanded(child: body),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: _navWidth, child: _categoryRail(context)),
                      const SizedBox(width: AppSpace.lg),
                      const VerticalDivider(width: 1, thickness: 1),
                      const SizedBox(width: AppSpace.lg),
                      Expanded(child: body),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 分类页里的一行开关：与 [SettingsNavRow] 同一个图标槽与标题字号。
  ///
  /// 为什么不用默认 `ListTile`：它的 leading 槽位比自绘行宽 4px，
  /// `horizontalTitleGap` 取 8（不是 12）标题列才与行对齐；标题字号也用
  /// bodyLarge，否则同一列表里两种字重读起来就是「有的行重、有的行轻」。
  Widget _switch({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    return SwitchListTile(
      key: key,
      horizontalTitleGap: AppSpace.sm,
      secondary: SizedBox(width: 20, child: Icon(icon, size: 20)),
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: theme.textTheme.bodyLarge),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      value: value,
      onChanged: onChanged,
    );
  }

  String _configSummary() {
    final count = state.savedConfigs.length;
    if (count == 0) return '尚未保存配置 · 导入 URL、本地文件或 JSON';
    final current = state.activeRecord;
    final active = current == null ? '未启用配置' : '当前：${current.name}';
    return '$active · 已保存 $count 个配置';
  }

  String _onOff(bool value) => value ? '开' : '关';

  /// 「去广告」一行的摘要：只写用户要判断的两件事——开没开、有没有规则。
  String _adBlockSummary(AppState state) {
    if (!state.adBlockEnabled) return '已关闭';
    final library = state.adRuleLibrary;
    final enabled = library.entries.where((entry) => entry.enabled).length;
    return '规则 ${library.entries.length} 组（$enabled 启用）'
        '${state.adBlockHeuristicEnabled ? ' · 启发式开' : ''}';
  }

  /// 直播回退开关的一句话摘要（副标题用）。
  String _liveSummary() {
    final live = state.liveSettings;
    return '换源 ${_onOff(live.sourceFallback)} · 换线 ${_onOff(live.changeLine)}';
  }

  /// 「运行时与外部依赖」的一句话摘要：两类可选组件的当前状态各占一截。
  ///
  /// 只写「已装/未装」与「能不能用」：装了什么版本、缺哪个包属于区块页，
  /// 分类页这一行只负责让用户看出「这里有没有东西要处理」。
  String _runtimeDependenciesSummary() {
    final status = state.pythonEnvironmentStatus;
    final python = status == null ? '未检测' : (status.ready ? '已就绪' : '不可用');
    return '加固壳解包运行时（${state.shellRuntimeInstalled ? '已装' : '未装'}）'
        ' · Python 运行时（$python）';
  }

  /// 出站代理的一句话摘要（副标题用）。
  String _outboundProxySummary() {
    final proxy = state.outboundProxy;
    if (!proxy.enabled) return '未启用';
    return proxy.isEffective
        ? '${proxy.validRules.length} 条规则'
        : '未生效（没有规则或地址不合法）';
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  /// 当前类别的单列内容区（滚动位置按类别恢复）。
  Widget _categoryContent(Widget section) {
    final id = _category;
    final saved = _scrollOffsets[id] ?? 0;
    final controller = _controllerFor(id);
    if (saved > 0) {
      // 列表是按类别重建的（key 随类别变化），滚动位置由自己记录后补回。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !controller.hasClients) return;
        final position = controller.position;
        final target = saved.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((position.pixels - target).abs() > 0.5) {
          controller.jumpTo(target);
        }
      });
    }
    return ListView(
      key: ValueKey('settings-category-content-$id'),
      controller: controller,
      padding: EdgeInsets.zero,
      children: [section],
    );
  }

  /// 宽窗：左侧分类栏（竖排）。
  ///
  /// 可滚动：分类从 4 类增到 5 类后，「16 上内边距 + 页标题 + 5×(48 行 + 4 间距)」
  /// 在矮窗里放不下，直接 Column 会 RenderFlex overflow（480×340 即可复现）。
  /// 让栏自己滚比隐藏第 5 类或压字号更诚实：每个分类都还在，滚一下就看得到。
  Widget _categoryRail(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final category in kSettingsCategories)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.xs),
            child: _categoryControl(context, category, compact: false),
          ),
      ],
    ),
  );

  /// 窄窗：顶部分类条（横向换行，仍用同一组 key）。
  Widget _categoryStrip(BuildContext context) => Wrap(
    spacing: AppSpace.sm,
    runSpacing: AppSpace.sm,
    children: [
      for (final category in kSettingsCategories)
        _categoryControl(context, category, compact: true),
    ],
  );

  /// 一个分类控件：原生可聚焦控件（Tab 可达、回车/空格激活），
  /// 选中态同时体现在**表面层级**（填充）与**公开语义**（`selected`）上。
  Widget _categoryControl(
    BuildContext context,
    SettingsCategory category, {
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = category.id == _category;
    // 星等琥珀是这个世界唯一强调色，选中态正是它该出现的地方。
    final accent = selected
        ? context.semanticColors.magnitude
        : scheme.onSurfaceVariant;
    final textStyle =
        (compact ? theme.textTheme.labelLarge : theme.textTheme.bodyLarge)
            ?.copyWith(
              color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
              fontWeight: selected ? AppWeight.title : AppWeight.body,
            );
    return Semantics(
      key: ValueKey('settings-category-${category.id}'),
      button: true,
      selected: selected,
      label: category.label,
      onTap: () => _selectCategory(category.id),
      excludeSemantics: true,
      child: Material(
        color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
        shape: compact
            ? RoundedRectangleBorder(
                borderRadius: AppRadius.pillAll,
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.72),
                ),
              )
            : const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _selectCategory(category.id),
          child: Padding(
            padding: compact
                ? const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: AppSpace.sm,
                  )
                : const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: AppSpace.md,
                  ),
            child: Row(
              mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
              children: [
                Icon(category.icon, size: compact ? 16 : 18, color: accent),
                const SizedBox(width: AppSpace.sm),
                if (compact)
                  Text(category.label, style: textStyle)
                else
                  Expanded(
                    child: Text(
                      category.label,
                      style: textStyle,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 站点健康摘要：只给一行结论，细节进独立页。
  String _healthSummary(AppState state) {
    final records = state.siteHealth();
    final sites = state.siteItems;
    if (sites.isEmpty) return '当前配置没有站点';
    if (records.isEmpty) {
      return '${sites.length} 个站点 · 尚无实测记录（浏览、搜索、播放或手动体检后开始累计）';
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

/// 站点健康：源场点阵 + 逐站实测明细。
///
/// 为什么单独一页（用户反馈 2026-10-12）：源场原本放在**首页内容区第一块**，
/// 意图是"先回答哪个源能用，再谈看什么"。真实配置下这个前提不成立——
/// 实测 170 个站源里 **160 个没有采样记录**，于是一大片灰点占了首屏近三分之一
/// 高度，既没有信息量又把海报内容挤了下去。健康度是**按需查看的诊断信息**，
/// 不是每次打开都要读的首页主角。
enum _HealthStageFilter {
  any,
  hasSuccess,
  hasFailure,
  allSuccess,
  allFailure,
  noData,
}

const Map<_HealthStageFilter, String> _healthStageFilterLabels = {
  _HealthStageFilter.any: '全部状态',
  _HealthStageFilter.hasSuccess: '有成功',
  _HealthStageFilter.hasFailure: '有失败',
  _HealthStageFilter.allSuccess: '全部成功',
  _HealthStageFilter.allFailure: '全部失败',
  _HealthStageFilter.noData: '暂无数据',
};

String _healthStageLabel(HealthAction action) => switch (action) {
  HealthAction.home => '首页',
  HealthAction.category => '分类',
  HealthAction.detail => '详情',
  HealthAction.play => '播放',
};

_HealthStageFilter _healthStageFilterFrom(String label) =>
    _healthStageFilterLabels.entries
        .firstWhere((entry) => entry.value == label)
        .key;

class SiteHealthPage extends StatefulWidget {
  const SiteHealthPage({super.key, required this.state});

  final AppState state;

  @override
  State<SiteHealthPage> createState() => _SiteHealthPageState();
}

class _SiteHealthPageState extends State<SiteHealthPage> {
  AppState get state => widget.state;
  final TextEditingController _nameFilter = TextEditingController();
  final Map<HealthAction, _HealthStageFilter> _stageFilters = {
    for (final action in HealthAction.values) action: _HealthStageFilter.any,
  };

  @override
  void dispose() {
    _nameFilter.dispose();
    super.dispose();
  }

  bool get _hasHealthFilters =>
      _nameFilter.text.trim().isNotEmpty ||
      _stageFilters.values.any((filter) => filter != _HealthStageFilter.any);

  Map<String, String> get _siteNames => {
    for (final item in state.siteItems) item.site.key: item.site.name,
  };

  bool _stageMatches(
    SiteHealth record,
    HealthAction action,
    _HealthStageFilter filter,
  ) {
    final (ok, total) = switch (action) {
      HealthAction.home => (record.homeOk, record.homeTotal),
      HealthAction.category => (record.categoryOk, record.categoryTotal),
      HealthAction.detail => (record.detailOk, record.detailTotal),
      HealthAction.play => (record.playOk, record.playTotal),
    };
    return switch (filter) {
      _HealthStageFilter.any => true,
      _HealthStageFilter.hasSuccess => ok > 0,
      _HealthStageFilter.hasFailure => total > 0 && ok < total,
      _HealthStageFilter.allSuccess => total > 0 && ok == total,
      _HealthStageFilter.allFailure => total > 0 && ok == 0,
      _HealthStageFilter.noData => total == 0,
    };
  }

  List<SiteHealth> _visibleHealth(List<SiteHealth> records) {
    final query = _nameFilter.text.trim().toLowerCase();
    final names = _siteNames;
    return records.where((record) {
      final name = names[record.siteKey] ?? record.siteKey;
      final nameMatches =
          query.isEmpty ||
          name.toLowerCase().contains(query) ||
          record.siteKey.toLowerCase().contains(query);
      return nameMatches &&
          _stageFilters.entries.every(
            (entry) => _stageMatches(record, entry.key, entry.value),
          );
    }).toList();
  }

  void _resetHealthFilters() {
    _nameFilter.clear();
    _stageFilters.updateAll((_, _) => _HealthStageFilter.any);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => _build(context),
  );

  Future<void> _openSelfCheck(BuildContext context) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AnimatedBuilder(
          animation: state,
          builder: (context, _) => Scaffold(
            appBar: AppBar(title: const Text('手动站点体检')),
            body: ListView(
              padding: formPagePadding(context),
              children: [
                SiteSelfCheckPanel(
                  service: state.siteService,
                  sites: [for (final item in state.siteItems) item.site],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final records = state.siteHealth();
    final visibleRecords = _visibleHealth(records);
    final siteNames = _siteNames;
    final magnitudes = buildMagnitudes(
      items: state.siteItems,
      health: {for (final record in records) record.siteKey: record},
    );
    final unknown = magnitudes
        .where((item) => item.status == SourceStatus.unknown)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('站点健康'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.lg),
            child: Center(
              child: FilledButton.icon(
                key: const ValueKey('site-health-self-check-open'),
                onPressed: () => _openSelfCheck(context),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('手动体检'),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.xl),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpace.xl),
            child: Text('浏览、搜索、播放或手动体检之后会开始累计成功率。'),
          ),
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
                '不代表不可用。浏览、搜索、播放或手动体检之后会开始累计成功率。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          SettingsSection(
            title: '逐站明细',
            children: [
              if (records.isEmpty)
                const Text('还没有调用记录。浏览、搜索、播放或手动体检后会累计成功率与耗时。')
              else ...[
                HealthFilterBar(
                  summary:
                      '显示 ${visibleRecords.length} / ${records.length} 条记录',
                  children: [
                    healthFilterNameField(
                      key: const ValueKey('health-filter-name'),
                      controller: _nameFilter,
                      hint: '搜索站点名称或标识',
                      onChanged: (_) => setState(() {}),
                    ),
                    for (final action in HealthAction.values)
                      healthFilterSelect(
                        context: context,
                        key: ValueKey('health-filter-${action.name}'),
                        label: _healthStageLabel(action),
                        value: _healthStageFilterLabels[_stageFilters[action]]!,
                        options: _healthStageFilterLabels.values.toList(),
                        onChanged: (value) => setState(
                          () => _stageFilters[action] = _healthStageFilterFrom(
                            value,
                          ),
                        ),
                      ),
                    if (_hasHealthFilters)
                      TextButton.icon(
                        key: const ValueKey('health-filter-reset'),
                        onPressed: _resetHealthFilters,
                        icon: const Icon(
                          Icons.filter_alt_off_outlined,
                          size: 18,
                        ),
                        label: const Text('重置筛选'),
                      ),
                  ],
                ),
                if (visibleRecords.isEmpty)
                  const Text('没有匹配的站点记录。')
                else
                  _HealthTable(items: visibleRecords, siteNames: siteNames),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _HealthTable extends StatefulWidget {
  const _HealthTable({required this.items, required this.siteNames});

  final List<SiteHealth> items;
  final Map<String, String> siteNames;

  @override
  State<_HealthTable> createState() => _HealthTableState();
}

class _HealthTableState extends State<_HealthTable> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _rate(int ok, int total) {
    if (total == 0) return '暂无数据';
    return '$ok/$total (${(ok / total * 100).toStringAsFixed(0)}%)';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const Text('还没有调用记录。浏览、搜索、播放或手动体检后会累计成功率与耗时。');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < 1120
            ? 1120.0
            : constraints.maxWidth;
        final contentWidth = width - AppSpace.lg * 2 - AppSpace.lg * 6;
        final widths = [
          contentWidth * 0.22,
          for (var i = 0; i < 4; i++) contentWidth * 0.11,
          contentWidth * 0.08,
          contentWidth * 0.26,
        ];
        Widget cell(
          String text,
          int column, {
          String? tooltip,
          int maxLines = 1,
        }) => SizedBox(
          width: widths[column],
          child: Tooltip(
            message: tooltip ?? text,
            child: Text(
              text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
        const headers = ['站点', '首页', '分类', '详情', '播放', '平均耗时', '最近错误'];
        return HorizontalMouseDrag(
          child: Scrollbar(
            key: const ValueKey('site-health-table-scrollbar'),
            controller: _scroll,
            thumbVisibility: true,
            trackVisibility: true,
            scrollbarOrientation: ScrollbarOrientation.top,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(top: AppSpace.md),
              child: DataTable(
                columnSpacing: AppSpace.lg,
                horizontalMargin: AppSpace.lg,
                dataRowMinHeight: 48,
                dataRowMaxHeight: 48,
                columns: [
                  for (var i = 0; i < headers.length; i++)
                    DataColumn(
                      label: SizedBox(
                        width: widths[i],
                        child: Text(headers[i]),
                      ),
                    ),
                ],
                rows: [
                  for (final item in widget.items)
                    DataRow(
                      cells: [
                        DataCell(
                          cell(
                            widget.siteNames[item.siteKey] ?? item.siteKey,
                            0,
                            tooltip:
                                '${widget.siteNames[item.siteKey] ?? item.siteKey}\n站点标识：${item.siteKey}',
                            maxLines: 2,
                          ),
                        ),
                        DataCell(cell(_rate(item.homeOk, item.homeTotal), 1)),
                        DataCell(
                          cell(_rate(item.categoryOk, item.categoryTotal), 2),
                        ),
                        DataCell(
                          cell(_rate(item.detailOk, item.detailTotal), 3),
                        ),
                        DataCell(cell(_rate(item.playOk, item.playTotal), 4)),
                        DataCell(cell('${item.avgLatencyMs} ms', 5)),
                        DataCell(cell(item.lastError ?? '-', 6, maxLines: 2)),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 从设置页 push 打开日志页。
///
/// 与 [openSpiderPage] 同一个理由：本页原先是外壳标签页的裸 body，收进设置后
/// 是一条独立路由，宿主（标题 + 返回）必须自己给。
Future<void> openLogsPage(BuildContext context, AppState state) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('日志与诊断')),
          body: LogsPage(state: state),
        ),
      ),
    );

/// 日志页：结构化日志、级别过滤、导出（§17.2 日志页，§18.2 日志脱敏）。
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, required this.state});

  final AppState state;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  /// 等宽字体：日志行要对齐，比例字体会让同名列错位。
  static const TextStyle _mono = TextStyle(
    fontFamily: 'Consolas',
    fontFamilyFallback: ['monospace'],
    fontSize: 12,
  );

  LogLevel? _filter;
  final TextEditingController _keyword = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _busy = false;

  @override
  void dispose() {
    _keyword.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _query => _keyword.text.trim().toLowerCase();

  @override
  Widget build(BuildContext context) {
    final all = widget.state.log.entries;
    final entries = all
        .where((entry) => _filter == null || entry.level == _filter)
        .where(
          (entry) =>
              _query.isEmpty || entry.line.toLowerCase().contains(_query),
        )
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
              const SizedBox(width: 20),
              // 用 `Expanded` 而不是固定宽度：窗口收到最小宽度（1024）时搜索框
              // 先收缩，工具栏不会溢出。
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: TextField(
                      key: const ValueKey('logs-search'),
                      controller: _keyword,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '搜索关键字',
                        prefixIcon: Icon(Icons.search, size: 18),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                tooltip: 'AI日志诊断',
                onPressed: () => openAiBusiness(context, widget.state),
                icon: const Icon(Icons.auto_awesome_outlined),
              ),
              Text(
                entries.length == all.length
                    ? '${entries.length} 条'
                    : '${entries.length} / ${all.length} 条',
              ),
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
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const ValueKey('logs-download'),
                onPressed: _busy ? null : _download,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('下载'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const ValueKey('logs-clear'),
                onPressed: _busy ? null : _clear,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('清理'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: all.isEmpty ? '暂无日志' : '没有匹配的日志',
                )
              : Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  // 整块日志是**一个**可选中文本：跨行拖拽即可选中任意多行，
                  // 逐行 `SelectableText` 只能选中一行（用户反馈 2026-11-06）。
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    child: SelectableText.rich(_logSpan(context, entries)),
                  ),
                ),
        ),
      ],
    );
  }

  /// 把当前可见日志拼成一个富文本：按级别着色，搜索命中处加底色。
  TextSpan _logSpan(BuildContext context, List<LogEntry> entries) {
    final theme = Theme.of(context);
    final highlight = theme.colorScheme.primary.withValues(alpha: 0.28);
    final children = <TextSpan>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final style = _mono.copyWith(
        color: switch (entry.level) {
          LogLevel.error => theme.colorScheme.error,
          LogLevel.warning => Colors.orangeAccent,
          LogLevel.info => theme.colorScheme.primary,
          LogLevel.debug => theme.textTheme.bodySmall?.color,
        },
      );
      _appendLine(children, entry.line, style, highlight);
      if (index != entries.length - 1) children.add(const TextSpan(text: '\n'));
    }
    return TextSpan(style: _mono, children: children);
  }

  void _appendLine(
    List<TextSpan> out,
    String line,
    TextStyle style,
    Color highlight,
  ) {
    final needle = _query;
    final lower = line.toLowerCase();
    // `toLowerCase` 可能改变长度（如 'İ'），索引就会错位：此时放弃高亮而不是截错字。
    if (needle.isEmpty || lower.length != line.length) {
      out.add(TextSpan(text: line, style: style));
      return;
    }
    var cursor = 0;
    while (true) {
      final hit = lower.indexOf(needle, cursor);
      if (hit < 0) break;
      if (hit > cursor) {
        out.add(TextSpan(text: line.substring(cursor, hit), style: style));
      }
      out.add(
        TextSpan(
          text: line.substring(hit, hit + needle.length),
          style: style.copyWith(backgroundColor: highlight),
        ),
      );
      cursor = hit + needle.length;
    }
    if (cursor == 0) {
      out.add(TextSpan(text: line, style: style));
    } else if (cursor < line.length) {
      out.add(TextSpan(text: line.substring(cursor), style: style));
    }
  }

  /// 下载目录：优先系统「下载」，取不到时退回日志目录。
  Future<String> _downloadDirectory() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads.path;
    } catch (_) {
      // 无平台实现（测试/精简构建）时静默降级。
    }
    return widget.state.log.directory ?? Directory.systemTemp.path;
  }

  Future<void> _download() async {
    setState(() => _busy = true);
    try {
      final file = await widget.state.log.exportToDirectory(
        await _downloadDirectory(),
      );
      if (!mounted) return;
      showToast('日志已导出', detail: file.path, kind: ToastKind.success);
    } catch (error) {
      if (!mounted) return;
      showToast('导出日志失败：$error', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理日志？'),
        content: const Text('会删除内存中的日志与已落盘的日志文件（含轮转历史），无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('logs-clear-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.state.log.clear();
      if (!mounted) return;
      showToast('日志已清理', kind: ToastKind.success);
    } catch (error) {
      if (!mounted) return;
      showToast('清理日志失败：$error', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              _chip('结果', switch (diagnostics.succeeded) {
                true => '成功',
                false => '失败',
                null => '进行中',
              }),
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
