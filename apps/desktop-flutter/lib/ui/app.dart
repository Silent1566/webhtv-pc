/// 应用外壳：启动页、侧栏导航与页面路由（§17.1、§17.2、§17.4）。
///
/// 桌面 UI 要求：键盘导航、鼠标拖拽、窗口缩放、深色模式、中文优先、可国际化、
/// 不使用移动端竖屏布局。因此这里固定为「顶栏 + 侧栏 + 内容区」的桌面布局。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_error.dart';
import '../core/protocol.dart';
import '../core/site_group.dart';
import '../services/log_service.dart';
import '../services/startup_trace.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'browse_pages.dart';
import 'config_pages.dart';
import 'diagnostics_pages.dart';
import 'library_pages.dart';
import 'live_page.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'spider_page.dart';
import 'theme.dart';

/// 命令行为参数，供冒烟验证与自动化使用：
/// - `--media=<url>`：启动后直接播放指定地址；
/// - `--config=<path|url|json>`：启动后自动导入配置；
/// - `--fullscreen=true`：启动即全屏；
/// - `--screenshot-ready-file=<path>`：主界面可交互后写入标记文件，供外部脚本等待。
class StartupArguments {
  const StartupArguments({
    this.media,
    this.config,
    this.fullscreen = false,
    this.readyFile,
    this.headers = const {},
    this.seekSeconds,
    this.traceFile,
  });

  final String? media;
  final String? config;
  final bool fullscreen;
  final String? readyFile;
  final Map<String, String> headers;
  final double? seekSeconds;

  /// `--startup-trace=<path>`：启动阶段追踪输出文件。
  final String? traceFile;

  static StartupArguments parse(List<String> arguments) {
    String? media;
    String? config;
    String? readyFile;
    String? traceFile;
    var fullscreen = false;
    double? seek;
    final headers = <String, String>{};
    for (final argument in arguments) {
      if (argument.startsWith('--media=')) {
        media = argument.substring('--media='.length);
      } else if (argument.startsWith('--config=')) {
        config = argument.substring('--config='.length);
      } else if (argument.startsWith('--screenshot-ready-file=')) {
        readyFile = argument.substring('--screenshot-ready-file='.length);
      } else if (argument.startsWith('--startup-trace=')) {
        traceFile = argument.substring('--startup-trace='.length);
      } else if (argument.startsWith('--header=')) {
        final header = argument.substring('--header='.length);
        final separator = header.indexOf(':');
        if (separator > 0) {
          headers[header.substring(0, separator).trim()] =
              header.substring(separator + 1).trim();
        }
      } else if (argument.startsWith('--seek=')) {
        seek = double.tryParse(argument.substring('--seek='.length));
      } else if (argument == '--fullscreen=true') {
        fullscreen = true;
      }
    }
    return StartupArguments(
      media: media,
      config: config,
      fullscreen: fullscreen,
      readyFile: readyFile,
      headers: headers,
      seekSeconds: seek,
      traceFile: traceFile,
    );
  }
}

/// 首次启动的使用边界提示（§22.4 合规验收）。
const String usageBoundaryNotice = '''
WebHTV PC 是一个通用桌面播放器。

• 应用不内置、不传播、不售卖任何影视资源；
• 应用不内置站点配置，站点配置与播放地址由用户自行导入；
• 应用不替用户绕过版权、认证、验证码或访问控制；
• 资源可用性取决于用户导入的来源，请确保你的使用符合当地法律法规；
• 遥测与崩溃上报默认关闭，应用不采集用户观影数据。
''';

Future<void> main(List<String> args) async {
  StartupTrace.mark('entry');
  WidgetsFlutterBinding.ensureInitialized();
  StartupTrace.mark('binding');
  MediaKit.ensureInitialized();
  StartupTrace.mark('media-kit');
  await windowManager.ensureInitialized();
  StartupTrace.mark('window-manager');

  final startup = StartupArguments.parse([...args, ...Platform.executableArguments]);
  StartupTrace.sinkPath = startup.traceFile;
  StartupTrace.mark('args-parsed');

  const windowOptions = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(1024, 640),
    center: true,
    title: 'WebHTV PC',
    titleBarStyle: TitleBarStyle.normal,
  );
  // 注意：`window_manager` 的 `waitUntilReadyToShow` 内部会等待 Flutter
  // 首帧回调后再执行 `then`，而原生 runner 的 `Show()` 也挂在首帧回调上。
  // 因此这里把 `runApp` 放在等待之前：先让 Flutter 开始构建首帧，避免
  // “等首帧 → 才 runApp → 再等首帧”的串行等待放大冷启动时间。
  final readyToShow = windowManager.waitUntilReadyToShow(windowOptions, () async {
    StartupTrace.mark('window-ready-to-show');
    await windowManager.show();
    await windowManager.focus();
    StartupTrace.mark('window-shown');
  });

  runApp(WebHtvApp(startup: startup));
  StartupTrace.mark('run-app');

  await readyToShow;
  StartupTrace.mark('window-ready-awaited');
}

class WebHtvApp extends StatefulWidget {
  const WebHtvApp({super.key, this.startup = const StartupArguments()});

  final StartupArguments startup;

  @override
  State<WebHtvApp> createState() => _WebHtvAppState();
}

class _WebHtvAppState extends State<WebHtvApp> {
  final AppState _state = AppState();
  bool _bootstrapped = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      StartupTrace.mark('first-frame');
    });
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _state.bootstrap();
    if (!mounted) return;
    setState(() => _bootstrapped = true);
    // 主界面在 `_bootstrapped` 置位这一刻已经可交互（§22.2 “首个可交互主界面”），
    // 因此必须先打点、再写标记文件，否则阶段汇总里看不到 `interactive`。
    StartupTrace.mark('interactive');

    final startup = widget.startup;
    if (startup.fullscreen) {
      await windowManager.setFullScreen(true);
    }
    if (startup.config != null) {
      await _state.importConfig(startup.config!);
    }
    if (startup.readyFile != null) {
      try {
        await File(startup.readyFile!).writeAsString(
          'ready ${DateTime.now().toIso8601String()}\n'
          '${_state.startupInfo?.oneLine ?? "startup-info-unavailable"}\n'
          '${StartupTrace.summary}\n',
        );
      } catch (_) {
        // 标记文件写入失败不影响应用运行。
      }
    }
    StartupTrace.mark('ready-file-written');
    _state.log.info('启动阶段 ${StartupTrace.summary}', scope: 'startup');
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebHTV PC',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      home: !_bootstrapped
          ? const _SplashPage()
          : AppShell(state: _state, startup: widget.startup),
    );
  }
}

/// 启动页：展示版本与平台信息，并等待初始化完成（§17.2 启动页）。
class _SplashPage extends StatelessWidget {
  const _SplashPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'WebHTV PC',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text('版本 $appVersion · $appBuildFlavor'),
            const SizedBox(height: 24),
            const SizedBox(
              width: 220,
              child: LinearProgressIndicator(minHeight: 3),
            ),
            const SizedBox(height: 12),
            const Text('正在初始化…'),
          ],
        ),
      ),
    );
  }
}

/// 侧栏入口。
///
/// §17.2 的「搜索页」在 MVP-B 是必须项，因此与首页同级放在侧栏。
enum ShellSection { browse, live, search, history, favorites, spiders, settings, logs }

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.state, required this.startup});

  final AppState state;
  final StartupArguments startup;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  ShellSection _section = ShellSection.browse;
  bool? _boundaryAccepted;
  String? _handledAutoMedia;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChanged);
    _checkBoundary();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoPlayMedia());
    // 启动时尝试自动接入最近使用的桥接线路（用户需求 2026-10-09）。
    // 放到 post-frame 之后：不能在首帧前做网络请求，否则会把启动变慢。
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoConnect());
  }

  AppState get _state => widget.state;

  void _onStateChanged() {
    if (mounted) setState(() {});
    _maybeAutoPlayMedia();
  }

  /// 首次启动展示使用边界提示，确认结果写入配置目录（§22.4）。
  Future<void> _checkBoundary() async {
    final marker = File(
      '${_state.paths.configDir}${Platform.pathSeparator}usage-boundary-accepted',
    );
    final exists = await marker.exists();
    if (exists) {
      setState(() => _boundaryAccepted = true);
      return;
    }
    setState(() => _boundaryAccepted = false);
  }

  Future<void> _acceptBoundary() async {
    final marker = File(
      '${_state.paths.configDir}${Platform.pathSeparator}usage-boundary-accepted',
    );
    try {
      await marker.writeAsString(DateTime.now().toIso8601String());
    } catch (_) {
      // 无法写入时本次会话内仍然放行，但下次启动会再次提示。
    }
    setState(() => _boundaryAccepted = true);
    _state.log.info('用户已确认使用边界提示', scope: 'compliance');
  }

  /// 启动时自动接入最近使用的桥接线路（用户需求 2026-10-09）。
  ///
  /// 只做一件事：**探测**历史里最近使用的地址。探不通就安静放弃——不扫描、
  /// 不轮询、不弹错误（扫描是用户显式动作，`design/01` §4.4）。
  ///
  /// 探通后导入站点并切到该配置：用户上次用的就是这条线路，现在还能连上，
  /// 直接给他可用状态而不需要重走一遍「选站点 → 接入 → 导入」。
  ///
  /// 两个必须的守卫：
  /// - 命令行媒体冒烟路径不跑（那是无配置的截图/验证场景）；
  /// - 不曾有历史时不跑。
  Future<void> _maybeAutoConnect() async {
    if (!mounted) return;
    if (widget.startup.media != null) return;
    final sync = _state.syncState;
    if (sync.deviceHistory.isEmpty) {
      // 没有接入历史（或自动接入不适用）时仍必须把当前站点的首页拉起来，
      // 否则启动后停在「没有内容」空态，要用户手动点分类或刷新才有数据
      // （用户反馈 2026-10-09：「刚启动时没有默认加载数据」）。
      await _loadInitialHome();
      return;
    }
    final device = await sync.tryAutoConnect();
    if (!mounted) return;
    if (device == null) {
      // 最近那条线路连不上：不影响用户用当前配置，照常加载首页。
      await _loadInitialHome();
      return;
    }
    final ok = await sync.importSites(device.reachableBase);
    if (!mounted) return;
    if (!ok) {
      await _loadInitialHome();
      return;
    }
    // 导入产生的是**新配置记录**（`makeActive: false`，Q10 不覆盖当前配置）。
    // 自动接入的目的是「开箱可用」，因此这里显式激活刚导入的那条记录。
    ConfigRecord? record;
    for (final item in _state.configs) {
      if (item.origin == device.reachableBase) record = item;
    }
    if (record == null) {
      await _loadInitialHome();
      return;
    }
    await _state.activateConfigRecord(record.id);
    if (!mounted) return;
    setState(() => _section = ShellSection.browse);
    _state.log.info(
      '已自动接入最近使用的桥接线路并切换配置 #${record.id}',
      scope: 'bridge',
    );
    // `activateConfigRecord` 只恢复配置不拉首页（它是给「配置管理页」用的），
    // 因此这里仍需显式加载，否则切过去还是空页。
    await _loadInitialHome();
  }

  /// 启动时把当前站点的首页拉起来（幂等：已有内容或正在加载就不重复）。
  ///
  /// 为什么必须有：`bootstrap()` 只恢复配置与 `_selectedSite`（`config.defaultSite()`），
  /// **从不发首页请求**；而浏览页在无 `homeResult` 时只渲染空态。
  /// 于是冷启动后用户看到的是「没有内容」，必须手动点分类或刷新。
  Future<void> _loadInitialHome() async {
    if (!mounted) return;
    final site = _state.selectedSite;
    if (site == null) return;
    if (_state.homeResult != null) return;
    if (_state.contentPhase == LoadPhase.loading) return;
    await _state.loadHome(site);
  }

  /// 自动播放命令行指定的媒体（冒烟验证路径）。
  ///
  /// 命令行媒体不依赖站点配置：只要应用壳层已就绪就直接打开播放器，
  /// 供 Windows 冒烟与截图验证使用。
  void _maybeAutoPlayMedia() {
    final media = widget.startup.media;
    if (media == null || _handledAutoMedia == media) return;
    _handledAutoMedia = media;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            state: _state,
            request: PlaybackRequest(
              url: media,
              headers: widget.startup.headers,
              title: '命令行媒体',
              siteKey: 'cli',
              vodId: 'cli',
              vodName: '命令行媒体',
              episodeName: '媒体',
              flag: 'cli',
              startPosition: widget.startup.seekSeconds == null
                  ? null
                  : Duration(
                      milliseconds:
                          (widget.startup.seekSeconds! * 1000).round(),
                    ),
            ),
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    super.dispose();
  }

  Future<void> _openConfigPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ConfigPage(state: _state)),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openSitePicker() async {
    final selected = await showDialog<Site>(
      context: context,
      builder: (_) => SitePickerDialog(
        items: _state.siteItems,
        log: _state.log,
      ),
    );
    if (selected != null) {
      _section = ShellSection.browse;
      await _state.selectSite(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final boundaryAccepted = _boundaryAccepted;
    if (boundaryAccepted == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            state: _state,
            onOpenConfig: _openConfigPage,
            onOpenSitePicker: _openSitePicker,
          ),
          Expanded(
            child: Row(
              children: [
                _SideBar(
                  section: _section,
                  onSelect: (value) => setState(() => _section = value),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _buildContent()),
              ],
            ),
          ),
        ],
      ),
      // 首次启动的边界提示不可跳过。
      bottomSheet: boundaryAccepted
          ? null
          : _BoundarySheet(onAccept: _acceptBoundary),
    );
  }

  Widget _buildContent() {
    switch (_section) {
      case ShellSection.browse:
        return BrowsePage(state: _state);
      case ShellSection.live:
        return LivePage(state: _state);
      case ShellSection.search:
        return SearchPage(state: _state);
      case ShellSection.history:
        return HistoryPage(state: _state);
      case ShellSection.favorites:
        return FavoritesPage(state: _state);
      case ShellSection.spiders:
        return SpiderPage(state: _state);
      case ShellSection.settings:
        return SettingsPage(state: _state);
      case ShellSection.logs:
        return LogsPage(state: _state);
    }
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.state,
    required this.onOpenConfig,
    required this.onOpenSitePicker,
  });

  final AppState state;
  final VoidCallback onOpenConfig;
  final VoidCallback onOpenSitePicker;

  @override
  Widget build(BuildContext context) {
    final site = state.selectedSite;
    final record = state.activeRecord;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          const Text(
            'WebHTV PC',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: onOpenConfig,
            icon: const Icon(Icons.settings_ethernet, size: 18),
            label: Text(record == null ? '导入配置' : '配置：${record.name}'),
          ),
          TextButton.icon(
            onPressed: state.siteItems.isEmpty ? null : onOpenSitePicker,
            icon: const Icon(Icons.dns, size: 18),
            label: Text(site == null ? '选择站点' : '站点：${site.name}'),
          ),
          const Spacer(),
          if (state.importDiagnosticsSummary != null)
            Tooltip(
              message: state.importDiagnosticsSummary!,
              child: const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Icon(Icons.info_outline, size: 18),
              ),
            ),
          Text('v$appVersion', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _SideBar extends StatelessWidget {
  const _SideBar({required this.section, required this.onSelect});

  final ShellSection section;
  final ValueChanged<ShellSection> onSelect;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      selectedIndex: section.index,
      onDestinationSelected: (index) => onSelect(ShellSection.values[index]),
      labelType: NavigationRailLabelType.all,
      destinations: const [
        NavigationRailDestination(
          icon: Icon(Icons.grid_view),
          label: Text('首页'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.live_tv),
          label: Text('直播'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.search),
          label: Text('搜索'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.history),
          label: Text('最近观看'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.bookmark_border),
          label: Text('收藏'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.extension),
          label: Text('Spider'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.tune),
          label: Text('设置'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.receipt_long),
          label: Text('日志'),
        ),
      ],
    );
  }
}

class _BoundarySheet extends StatelessWidget {
  const _BoundarySheet({required this.onAccept});

  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '使用边界提示',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(usageBoundaryNotice),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onAccept,
                child: const Text('我已了解并继续'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 站点选择对话框（§17.2 站点列表）。
/// 站点选择器：搜索 + 分组 chip + 站点列表（对齐上游「默影视」`SiteDialog`）。
///
/// 为什么需要搜索/分组（用户反馈 2026-10-09）：
/// - 实测「安卓桥接」配置有 **170 个站点**，只能一路滚动找目标，效率极低；
/// - 列表原先每行显示 `key=… type=… 运行时=… (MVP-A)` 这类**协议内部字段**，
///   对用户毫无价值（用户原话：「名称即可提高易用性」）。
/// 因此只展示站点名称 + 可用状态；key/type/运行时/阶段改为写日志，便于定位问题。
class SitePickerDialog extends StatefulWidget {
  const SitePickerDialog({super.key, required this.items, required this.log});

  final List<SiteListItem> items;

  /// 站点清单的内部字段（key/type/运行时/阶段/不可用原因）不再上屏，
  /// 改为写日志：排查「某站点为何不可用」时仍然拿得到。
  final LogService log;

  @override
  State<SitePickerDialog> createState() => _SitePickerDialogState();
}

class _SitePickerDialogState extends State<SitePickerDialog> {
  final TextEditingController _keyword = TextEditingController();

  /// 当前选中的分组；空串 = 全部。
  String _group = '';

  @override
  void initState() {
    super.initState();
    // 打开时把站点清单（含运行时与不可用原因）写日志：UI 不再展示这些内部字段，
    // 但排查「某站点为何不可用」时仍然需要它们。
    _logInventory();
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  void _logInventory() {
    final unavailable = widget.items.where((i) => !i.availability.available);
    widget.log.info(
      '站点选择器打开：共 ${widget.items.length} 个站点，'
      '可用 ${widget.items.length - unavailable.length}，'
      '不可用 ${unavailable.length}',
      scope: 'site',
    );
    for (final item in widget.items) {
      final site = item.site;
      final availability = item.availability;
      widget.log.debug(
        '站点 name=${site.name} key=${site.key} type=${site.type} '
        'runtime=${availability.runtimeName} '
        'stage=${availability.stage ?? "-"} '
        'available=${availability.available} '
        'searchable=${site.searchable} '
        'groups=${siteGroupsOf(site.name).join("|")} '
        'reason=${availability.reason ?? "-"}',
        scope: 'site',
      );
    }
  }

  /// 当前可见的分组（按站点顺序去重，只统计当前关键字命中的站点）。
  List<String> get _groups {
    final seen = <String>[];
    for (final item in _keywordMatched) {
      for (final group in siteGroupsOf(item.site.name)) {
        if (!seen.contains(group)) seen.add(group);
      }
    }
    return seen;
  }

  List<SiteListItem> get _keywordMatched => [
    for (final item in widget.items)
      if (siteMatchesQuery(
        name: item.site.name,
        key: item.site.key,
        query: _keyword.text,
      ))
        item,
  ];

  List<SiteListItem> get _visible {
    if (_group.isEmpty) return _keywordMatched;
    return [
      for (final item in _keywordMatched)
        if (siteInGroup(item.site.name, _group)) item,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _visible;
    final groups = _groups;

    return AlertDialog(
      title: const Text('选择站点'),
      content: SizedBox(
        width: 640,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('site-search'),
              controller: _keyword,
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: '搜索站点名称',
                suffixIcon: _keyword.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(_keyword.clear),
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (groups.isNotEmpty) ...[
              const SizedBox(height: 10),
              // 分组 chip 行：横向可滚，命中关键字时只列出现存的分组。
              SizedBox(
                height: 34,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _GroupChip(
                        label: '全部',
                        selected: _group.isEmpty,
                        onTap: () => setState(() => _group = ''),
                      ),
                      for (final group in groups)
                        _GroupChip(
                          key: ValueKey('site-group-$group'),
                          label: group,
                          selected: _group == group,
                          onTap: () => setState(() => _group = group),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text(
                        widget.items.isEmpty ? '当前配置没有可用站点' : '没有匹配的站点',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final availability = item.availability;
                        final available = availability.available;
                        return ListTile(
                          key: ValueKey('site-option-${item.site.key}'),
                          dense: true,
                          leading: Icon(
                            available
                                ? Icons.check_circle_outline
                                : Icons.block,
                            color: available
                                ? Colors.greenAccent
                                : theme.disabledColor,
                          ),
                          // 只显示名称：key/type/运行时属协议内部字段，已写日志。
                          title: Text(item.site.name),
                          subtitle: available
                              ? null
                              : Text(
                                  availability.reason ?? '当前不可用',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: item.site.searchable
                              ? const Icon(Icons.search, size: 16)
                              : null,
                          enabled: available,
                          onTap: available
                              ? () => Navigator.of(context).pop(item.site)
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 分组 chip（选中态主色淡底，与筛选条同一视觉语言）。
class _GroupChip extends StatelessWidget {
  const _GroupChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: dark ? 0.22 : 0.12)
            : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 13,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一错误提示条（§10.4、§17.3 错误提示）。
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.error, this.onDismiss});

  final AppError error;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            color: Theme.of(context).colorScheme.onErrorContainer,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  error.userMessage,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  '错误码：${error.kind.name}'
                  '${error.retryable ? " · 可重试" : ""}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: '关闭提示',
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 18),
            ),
        ],
      ),
    );
  }
}

/// 供各页面复用：键盘快捷键帮助（§17.4 支持键盘导航）。
const List<(String, String)> playerShortcuts = [
  ('空格', '播放 / 暂停'),
  ('← / →', '后退 / 前进 10 秒'),
  ('↑ / ↓', '音量 +5 / -5'),
  ('M', '静音切换'),
  ('[ / ]', '上一集 / 下一集'),
  ('F11 / F', '全屏切换'),
  ('Esc', '退出全屏'),
];

/// 全局快捷键激活器集合，供页面复用。
Map<ShortcutActivator, VoidCallback> buildPlayerShortcuts({
  required VoidCallback togglePlay,
  required VoidCallback seekBackward,
  required VoidCallback seekForward,
  required VoidCallback volumeUp,
  required VoidCallback volumeDown,
  required VoidCallback toggleMute,
  required VoidCallback previousEpisode,
  required VoidCallback nextEpisode,
  required VoidCallback toggleFullscreen,
  required VoidCallback exitFullscreen,
}) {
  return {
    const SingleActivator(LogicalKeyboardKey.space): togglePlay,
    const SingleActivator(LogicalKeyboardKey.arrowLeft): seekBackward,
    const SingleActivator(LogicalKeyboardKey.arrowRight): seekForward,
    const SingleActivator(LogicalKeyboardKey.arrowUp): volumeUp,
    const SingleActivator(LogicalKeyboardKey.arrowDown): volumeDown,
    const SingleActivator(LogicalKeyboardKey.keyM): toggleMute,
    const SingleActivator(LogicalKeyboardKey.bracketLeft): previousEpisode,
    const SingleActivator(LogicalKeyboardKey.bracketRight): nextEpisode,
    const SingleActivator(LogicalKeyboardKey.f11): toggleFullscreen,
    const SingleActivator(LogicalKeyboardKey.keyF): toggleFullscreen,
    const SingleActivator(LogicalKeyboardKey.escape): exitFullscreen,
  };
}

/// 图片加载：站点图床可能失效，用占位符而不是抛错。
/// 图片占位底色。
///
/// 刻意选 `surfaceContainerLow`（紧贴页面底色）而**不是** `surfaceContainerHigh`：
/// 后者在深色主题下比背景亮得多（≈#333 对 ≈#111），图上不来时就是一块突兀的
/// 灰块（用户反馈 2026-10-09：「大量地方存在这种无效的阴影或背景色区域太丑了」，
/// 截图里海报墙、缺失头像甚至网格里都是这种灰块）。换成低一档的容器色后，
/// 占位仍然存在（不会退化成「与页面同色的空洞」），但不会再抢视线。
Color _posterPlaceholderColor(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerLow;

class PosterImage extends StatelessWidget {
  const PosterImage({
    super.key,
    this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final target = url?.trim() ?? '';
    // 底层永远是占位底色 + 图标，图片叠在上面。
    //
    // 为什么不能只靠 `loadingBuilder` 兜底（实测 2026-10-09，网盘聚合站慢图床）：
    // 慢速图床在**首帧产出之前**会走到 `progress == null` 分支，此时 `child` 是
    // 一个还没有图像的 `RawImage`（什么都不画），而占位符已经被跳过——结果整个
    // 格子与页面同色，看上去像「少了一部片」，实测要等 25s 图才出现。
    // 把占位符当底而不是当分支，就不存在“两个分支都画空”的窗口。
    return Container(
      width: width,
      height: height,
      color: _posterPlaceholderColor(context),
      alignment: Alignment.center,
      child: target.isEmpty
          ? _placeholderIcon(context)
          : Image.network(
              target,
              width: width,
              height: height,
              fit: fit,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : _placeholderIcon(context, loading: true),
              errorBuilder: (context, error, stackTrace) =>
                  _placeholderIcon(context),
            ),
    );
  }

  Widget _placeholderIcon(BuildContext context, {bool loading = false}) {
    return Icon(
      loading ? Icons.downloading : Icons.image_not_supported_outlined,
      size: 20,
      color: Theme.of(context).disabledColor,
    );
  }
}
