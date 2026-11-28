/// 应用外壳：启动页、侧栏导航与页面路由（§17.1、§17.2、§17.4）。
///
/// 桌面 UI 要求：键盘导航、鼠标拖拽、窗口缩放、深色模式、中文优先、可国际化、
/// 不使用移动端竖屏布局。因此这里固定为「顶栏 + 侧栏 + 内容区」的桌面布局。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher, SemanticsRole;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_error.dart';
import '../core/image_user_agent.dart';
import '../core/protocol.dart';
import '../core/session_recovery.dart';
import '../core/site_group.dart';
import '../core/site_group_rules.dart';
import '../core/source_key.dart';
import '../services/app_paths.dart';
import '../services/csp_jar_probe.dart' show ShellUnpackTick;
import '../services/last_config_store.dart';
import '../services/log_service.dart';
import '../services/session_recovery_store.dart';
import '../services/startup_trace.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'app_motion.dart';
import 'app_update_page.dart';
import 'browse_pages.dart';
import 'common.dart';
import 'config_pages.dart';
import 'config_source_status_view.dart';
import 'diagnostics_pages.dart';
import 'desktop_window_frame.dart';
import 'glass_widgets.dart';
import 'following_page.dart';
import 'glass_chrome.dart' show GlassChromeSurface, kShellContentTopInset;
import 'glass_dialog.dart';
import 'glass_surface.dart';
import 'home_page.dart';
import 'image_header_scope.dart';
import 'library_pages.dart';
import 'live_page.dart';
import 'playback_resume.dart';
import 'recovery_banner.dart';
import 'player_page.dart';
import 'push_detail_page.dart';
import 'push_dialog.dart';
import 'scroll_behavior.dart';
import 'shell_unpack_dialogs.dart';
import 'search_page.dart';
import 'startup_arguments.dart';
import 'theme.dart';
import 'toast.dart';
import 'tokens.dart';
import 'wallpaper_backdrop.dart';
import 'web_home_page.dart';
import 'window_mode.dart';

/// 把状态层存的主题字符串映射成 `ThemeMode`。
///
/// 状态层只依赖 `foundation`，因此不认识 `ThemeMode`；映射放在 UI 层。
/// 不认识的值回落到暗色（星等星表的主身份）。
ThemeMode themeModeOf(String raw) {
  switch (raw) {
    case 'light':
      return ThemeMode.light;
    case 'system':
      return ThemeMode.system;
    case 'dark':
    default:
      return ThemeMode.dark;
  }
}

/// `ThemeMode` 回写成状态层存的字符串。
String themeModeName(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.system:
      return 'system';
    case ThemeMode.dark:
      return 'dark';
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

/// 默认 1280×800 逻辑视口，按 DPR 2 保守估算（不扣侧栏、顶栏）：
/// LayoutScale 目标卡宽 185.25，6 列的实际卡宽 198.5；2:3 海报解码成
/// 397×596×4 B ≈ 0.90 MiB。6 列×2 行×3 屏 ≈ 32.5 MiB，加两张
/// 1920×1080 背景 ≈ 15.8 MiB、40 张 200×300 缩略图 ≈ 9.2 MiB，
/// 合计约 57.5 MiB，留余量取 64 MiB，而不是套用其他应用的 48 MiB。
/// 大窗口或 4K 背景（单张约 31.6 MiB）会缩短可回看屏数，由 LRU 淘汰。
/// 这是 keepAlive 缓存预算，不是进程内存硬上限：仍被监听的 live 图片可超出它；
/// 其他未限宽图位仍按源尺寸解码，缩略图估算只是用途预算，不保证源图大小。
const int imageCacheBudgetBytes = 64 * 1024 * 1024;

/// 三屏大网格（9×3×3 = 81）+ 60 张详情图 + 80 张列表缩略图 ≈ 221，
/// 取 256 留余量；张数上限兜住小图片积累，较大的位图先受字节预算约束。
const int imageCacheBudgetCount = 256;

/// 与 main 共用同一入口，测试无需启动桌面窗口或播放器即可验证全局预算。
void installImageCacheBudget() {
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = imageCacheBudgetBytes
    ..maximumSize = imageCacheBudgetCount;
}

Future<void> main(List<String> args) async {
  StartupTrace.mark('entry');
  // 图片请求的 User-Agent 必须**在客户端层**替换（见 `core/image_user_agent.dart`）：
  // `Image.network(headers:)` 走的是 `request.headers.add()`，而 `dart:io` 默认已经
  // 有 `Dart/x.y (dart:io)`，add 的结果是两个值拼成一条
  // `Dart/3.13 (dart:io), WebHTV-PC/0.1 (Windows)`——豆瓣的 EdgeOne 照样 418。
  // 只有 `HttpClient.userAgent`（客户端级、`set` 语义）才能真正替换它；
  // 实测同一 URL：add UA → 418，HttpOverrides UA → 200。
  installImageUserAgent();
  WidgetsFlutterBinding.ensureInitialized();
  StartupTrace.mark('binding');
  // 首张图片解码前就启用预算，避免冷启动先按默认上限保留大图。
  installImageCacheBudget();
  // 崩溃恢复（Phase 9 P2-8）：把未捕获异常写入有界崩溃日志，供下次启动展示。
  // 只写日志，不吞掉 Flutter 的默认报错展示。
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    recordCrashForPaths(
      kind: 'flutter',
      error: details.exceptionAsString(),
      stack: details.stack?.toString(),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    recordCrashForPaths(
      kind: 'uncaught',
      error: '$error',
      stack: stack.toString(),
    );
    return true;
  };
  MediaKit.ensureInitialized();
  StartupTrace.mark('media-kit');
  await windowManager.ensureInitialized();
  StartupTrace.mark('window-manager');

  final startup = StartupArguments.parse([
    ...args,
    ...Platform.executableArguments,
  ]);
  StartupTrace.sinkPath = startup.traceFile;
  StartupTrace.mark('args-parsed');

  const windowOptions = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(1024, 640),
    center: true,
    title: 'WebHTV PC',
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );
  // 注意：`window_manager` 的 `waitUntilReadyToShow` 内部会等待 Flutter
  // 首帧回调后再执行 `then`，而原生 runner 的 `Show()` 也挂在首帧回调上。
  // 因此这里把 `runApp` 放在等待之前：先让 Flutter 开始构建首帧，避免
  // “等首帧 → 才 runApp → 再等首帧”的串行等待放大冷启动时间。
  final readyToShow = windowManager.waitUntilReadyToShow(
    windowOptions,
    () async {
      StartupTrace.mark('window-ready-to-show');
      await windowManager.show();
      await windowManager.focus();
      StartupTrace.mark('window-shown');
    },
  );

  runApp(WebHtvApp(startup: startup));
  StartupTrace.mark('run-app');

  await readyToShow;
  StartupTrace.mark('window-ready-awaited');
}

/// 记录一次崩溃：stderr + 有界崩溃日志文件（Phase 9 · P2-8）。
///
/// stderr 必须先写：日志目录不可写时（FIC 只读现场）那是唯一还看得见的线索。
void recordCrashForPaths({
  required String kind,
  required String error,
  String? stack,
  AppPaths? paths,
}) {
  final entry = formatCrashEntry(
    at: DateTime.now(),
    kind: kind,
    error: error,
    stack: stack,
  );
  try {
    stderr.writeln(entry);
  } catch (_) {}
  try {
    SessionRecoveryStore.appendCrashForPaths(
      paths ?? AppPaths.resolve(),
      entry,
    );
  } catch (_) {}
}

class WebHtvApp extends StatefulWidget {
  const WebHtvApp({
    super.key,
    this.startup = const StartupArguments(),
    this.stateFactory,
  });

  final StartupArguments startup;

  /// Creates a fresh, unbootstrapped state once; the root owns bootstrap/dispose.
  /// Omitted in production, which continues to create the default AppState.
  final AppState Function()? stateFactory;

  @override
  State<WebHtvApp> createState() => _WebHtvAppState();
}

class _WebHtvAppState extends State<WebHtvApp> with WindowListener {
  late final AppState _state;
  late String _observedThemeMode;
  bool _bootstrapped = false;

  @override
  void initState() {
    super.initState();
    _state = widget.stateFactory?.call() ?? AppState();
    _observedThemeMode = _state.themeMode;
    _state.addListener(_onThemeModeChanged);
    // 窗口关闭时标记「正常退出」（崩溃恢复靠它区分强杀）。
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      StartupTrace.mark('first-frame');
    });
    _bootstrap();
  }

  void _onThemeModeChanged() {
    final mode = _state.themeMode;
    if (mode == _observedThemeMode) return;
    setState(() => _observedThemeMode = mode);
  }

  Future<void> _bootstrap() async {
    await _state.bootstrap();
    // 自动线路测速放在主界面起来之后：启动阶段别和首屏抢网络。
    // 非自动配置这个方法一次请求都不发（直接返回「当前不是自动线路」）。
    // 测试都直接 pump 具体页面、不走这个入口，因此不会打真网络。
    if (_state.warmAutoRoutes) unawaited(_state.refreshTmdbAutoRoutes());
    if (!mounted) return;
    setState(() => _bootstrapped = true);
    // 主界面在 `_bootstrapped` 置位这一刻已经可交互（§22.2 “首个可交互主界面”），
    // 因此必须先打点、再写标记文件，否则阶段汇总里看不到 `interactive`。
    StartupTrace.mark('interactive');

    final startup = widget.startup;
    if (startup.fullscreen) {
      await enterPlayerFullscreen();
    }
    if (startup.config != null) {
      await _state.importConfig(startup.config!);
    }
    if (startup.readyFile != null) {
      try {
        // 先写临时文件再原子改名：外部脚本（烟测、截图自动化）的约定是
        // 「文件出现 = 内容完整」，直接 writeAsString 会先建空文件再写，
        // 慢 runner 上读到的就是空内容（实测 CI 烟测偶发）。
        final readyFile = File(startup.readyFile!);
        final temp = File('${readyFile.path}.tmp');
        await temp.writeAsString(
          'ready ${DateTime.now().toIso8601String()}\n'
          '${_state.startupInfo?.oneLine ?? "startup-info-unavailable"}\n'
          '${StartupTrace.summary}\n',
          flush: true,
        );
        await temp.rename(readyFile.path);
      } catch (_) {
        // 标记文件写入失败不影响应用运行。
      }
    }
    StartupTrace.mark('ready-file-written');
    _state.log.info('启动阶段 ${StartupTrace.summary}', scope: 'startup');
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _state.removeListener(_onThemeModeChanged);
    // Toast callbacks can retain this root state across the next app session.
    // Finish them while AppState is still alive, before releasing its owner.
    dismissAllToasts();
    // 正常退出：删除会话标记（同步写，进程可能马上结束）。
    _state.endSessionCleanly();
    _state.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() {
    // 窗口关闭路径不一定会走到 `dispose`，这里必须再标一次。
    _state.endSessionCleanly();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebHTV PC',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      // 主题由用户偏好驱动（设置页可切换并持久化）。
      // 状态层存原始字符串、这里映射成 `ThemeMode`，避免状态层依赖 material。
      themeMode: themeModeOf(_state.themeMode),
      // 图片请求 Header 的全局作用域（§7.4.6 的图片侧，见 `image_headers.dart`）。
      //
      // 为什么挂在这里：`builder` 位于 **Navigator 之上**，因此所有 push 出来
      // 的路由与 `showDialog`/`showModalBottomSheet` 弹出层都是它的后代——
      // 海报墙、演职人员头像、剧照查看器等图片位才能统一拿到顶层 `headers` 规则。
      //
      // 为什么要再包一层 `ListenableBuilder`：状态变更只会触发 `AppShell`
      // （它自己 `addListener`）重建，本 State 仅对主题值的变化重建；不监听配置的话
      // 导入后 builder 不会重跑，规则永远是空表，图片依旧 418。
      // 代价可控：`child` 是 MaterialApp 传下来的同一个 Widget 实例，
      // Flutter 对同一实例会跳过子树重建。
      builder: (context, child) => WindowEscapeShortcuts(
        child: ListenableBuilder(
          listenable: _state,
          builder: (context, _) => ImageHeaderScope(
            rules: _state.effectiveConfig?.headers ?? const <HeaderRule>[],
            child: WallpaperBackdrop(
              url: _state.config?.wallpaper,
              builder: (context, _) => DesktopWindowFrame(
                child: Stack(
                  // 通知宿主是 `builder` 的第二个孩子：它因此位于 **Navigator 之上**，
                  // 任何 push 出来的路由与弹出层都盖不住它——"浮在所有页面与对话框之上"
                  // 只有这一个位置成立。
                  //
                  // `StackFit.expand`：`child` 原本拿到的是整屏紧约束，Stack 默认会把
                  // 非定位子节点放松，那会让 Navigator 的尺寸取决于内容。
                  fit: StackFit.expand,
                  children: [
                    AppMotionScope(child: child ?? const SizedBox.shrink()),
                    const ToastHost(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
/// **侧栏只放看片链路 + 设置**（2026-11-22 用户决策）：Spider 运行时、日志与
/// AI / 阅读器都是低频的配置与排查，一律收进设置，于是从 11 项收敛到 8 项。
/// 判据沿用 §17.2 的「入口数量按概念算，不按视角算」——Spider/日志/AI 都不是
/// 又一个「要看什么」，而是「怎么把它弄好」，它们属于设置的六个分类。
///
/// §17.2 的「搜索页」在 MVP-B 是必须项，因此与首页同级放在侧栏。
enum ShellSection {
  /// 首页：首屏（hero + 续播/推荐轨道）。
  ///
  /// **必须**排在第一位并与 `_SideBar.destinations` 的顺序一致：
  /// `NavigationRail` 的 `selectedIndex` 直接取 `section.index`。
  home,

  /// 点播：按站点浏览（原「首页」，改名不改行为）。
  browse,
  live,
  search,
  history,
  favorites,
  following,
  settings,
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.state,
    required this.startup,
    this.pickLocalMediaFile,
  });

  final AppState state;
  final StartupArguments startup;

  /// 推送对话框里「选择本地文件…」用的文件选择器；`null` = 走原生 `file_picker`。
  ///
  /// 与 `PlayerPage.externalPlayerStarter` 同一个理由：原生窗口在测试里起不来，
  /// 注入一个返回固定路径的替身，才能验证「选文件 → 构造本地请求 → 交给既有
  /// 播放器入口」这条链路本身。
  final Future<String?> Function()? pickLocalMediaFile;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  // 启动落在首页（用户 2026-11-19 决策）：第一屏回答「今晚看什么」，不是「挑分类」。
  ShellSection _section = ShellSection.home;
  Widget? _homeHeroBackdrop;
  String _settingsInitialCategory = SettingsCategory.preferences;
  Key _settingsEntryKey = UniqueKey();

  /// 首页「热门」点进来的搜索词。
  ///
  /// `SearchPage` 用构造参数 `initialKeyword` 自动搜索一次；用户在侧栏手动点
  /// 「搜索」时**清空**它，否则每次进搜索页都会重跑上一次的热门搜索。
  String? _pendingSearchKeyword;
  bool? _boundaryAccepted;
  String? _handledAutoMedia;

  /// 桥接源恢复失败的横幅状态（`null` = 不显示）。
  BridgeRestoreFailure? _bridgeBanner;

  /// 横幅对应的那条记忆。
  ///
  /// 没有 last-config.json 时横幅来自兜底推断的记忆，而 lastConfigRecord 是
  /// null——「重试」必须沿用它，否则按钮点了没反应。
  LastConfigRecord? _bannerMemory;

  /// 「重试」进行中：按钮置忙，避免连点触发重复探测。
  bool _restoringBridge = false;

  /// 加固壳解包流程是否已经开着：同一个站点连点、连选两次不许叠出第二个框。
  bool _shellUnpackFlowOpen = false;

  /// 两条横幅通道上一次"已经推成通知"的值。
  ///
  /// 状态层是唯一事实来源，通知只是它的投影：拿上一次投影过的值做对比，
  /// 只在值**变成另一个非 null 值**时推一条，因此状态不变时不会重复弹。
  ///
  /// `detailError` 不在这里：它的动作（「换源」）是详情页的私有方法，只能由
  /// `_DetailPageState` 自己投影——见 `browse_pages.dart` 的 `_syncDetailErrorToast`。
  AppError? _shownLastError;
  String? _shownNotice;

  /// 已弹过的去广告提示（按 seq 去重：同文案的两集也要各弹一次）。
  ({int seq, String message})? _shownAdBlockNotice;

  /// 上一次已经推成通知的「发现新版本」tag（见 [_syncToasts]）。
  String? _shownUpdateNotice;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChanged);
    // 首次投影放在首帧之后：`initState` 跑在本 State 的挂载过程里，
    // 此时 `notifyListeners` 会去标记一个**已经建好**的 `ToastHost` 元素为脏，
    // 那属于 build 期间的重入。首帧后再投影没有这个风险，也不会漏掉启动期的错误。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncToasts();
    });
    _checkBoundary();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoPlayMedia());
    // 启动时恢复「上一次使用的配置」（Phase 10）。
    // 放到 post-frame 之后：不能在首帧前做网络请求，否则会把启动变慢。
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreLastConfig());
    // 启动后台增量刷新各条配置（§7.5）：首帧之后才动网络，本地缓存先顶上；
    // 与上面的启动恢复并行，两者互不等待。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_state.startupConfigRefresh()),
    );
    // 启动时按 24 小时闸门查一次更新（ADR-0015）：与上面同一位置风格，首帧之后
    // 才动网络；闸门关着（没开自动检查、或 24 小时内查过）时一个请求都不发，
    // 这个判断在 AppState 里。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_state.maybeAutoCheckForUpdates()),
    );
  }

  AppState get _state => widget.state;

  void _onStateChanged() {
    _syncToasts();
    _syncFollowingOpenRequest();
    _consumePendingPush();
    if (mounted) setState(() {});
    _maybeAutoPlayMedia();
    _scheduleShellUnpackOffer();
  }

  void _scheduleShellUnpackOffer() {
    if (_section != ShellSection.browse ||
        _state.pendingShellUnpackForSite == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _section == ShellSection.browse) {
        unawaited(_maybeOfferShellUnpack());
      }
    });
  }

  void _enterBrowse() {
    _state.enterCurrentVod();
    _scheduleShellUnpackOffer();
  }

  /// 把待播推送投影成播放页路由（本机输入与局域网推送共用这一条）。
  ///
  /// **先清再导航**：`clearPendingPush` 会再 notify 一次，若不等清空就 push，
  /// 同一条推送会在下一次状态变化时又起播一遍。已在播放页时仍然压新页——
  /// 与命令行媒体一致，用户推新的东西就该看到新的画面。
  void _consumePendingPush() {
    final request = _state.pendingPush;
    if (request == null || !mounted) return;
    final parsed = _state.pendingPushParsed;
    _state.clearPendingPush();
    // 必须延到下一帧再压栈：提交动作（对话框里 `await submitPush`）在同一个
    // 同步段里随后会 `pop()` 自己，立刻压栈会让它把**详情页**当成对话框关掉
    // ——现象就是"点了没反应、按钮停在处理中"（2026-11-21 用户实测）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 有 TMDB 匹配就复用 TMDB 详情页，否则用极简推送页兜底。
      unawaited(openPushLanding(context, _state, request, parsed: parsed));
    });
  }

  /// 系统通知被点击时把侧栏切到「追剧」页（页面自己会切到列表视角）。
  ///
  /// **只切页，不清 `followingOpenRequest`**：真正的消费方是 `FollowingPage`
  /// （`_consumeOpenRequest` 取到身份键后打开最新集，再原子地清空）。壳层要是
  /// 提前清掉，追剧页拿不到 key，点通知就只跳到列表、不打开那一集。
  /// 只判「当前是否已在追剧页」而不记历史值：清空不触发 notify，记历史值会让
  /// 同一条通知的第二次点击失去跳转。
  void _syncFollowingOpenRequest() {
    if (_state.followingOpenRequest.isEmpty) return;
    if (_section == ShellSection.following) return;
    _section = ShellSection.following;
  }

  /// 把状态层的两条横幅通道投影成右下角通知。
  ///
  /// 通知的 `onDismiss` 负责清状态（计时器超时或用户点 ×），**反过来不成立**：
  /// 推通知时不清状态——错误仍然在状态里，页面读它做别的判断时不该看到空洞。
  void _syncToasts() {
    final lastError = _state.lastError;
    if (lastError != _shownLastError) {
      _shownLastError = lastError;
      if (lastError != null) {
        showToast(
          lastError.userMessage,
          kind: ToastKind.error,
          detail:
              '错误码：${lastError.kind.name}'
              '${lastError.retryable ? " · 可重试" : ""}',
          onDismiss: () {
            if (mounted) _state.clearError();
          },
        );
      }
    }
    // 去广告：拦到广告就弹一条（文案对齐安卓 HlsAdblockNotice，通道复用上面的 showToast）。
    // 按 seq 判断而不是按文案：同一句「已跳过 2 个广告片段」在两集里都要能弹。
    final adBlockNotice = _state.adBlockNotice;
    if (adBlockNotice != null &&
        adBlockNotice.seq != _shownAdBlockNotice?.seq) {
      _shownAdBlockNotice = adBlockNotice;
      showToast(
        adBlockNotice.message,
        kind: ToastKind.info,
        onDismiss: () {
          if (mounted) _state.clearAdBlockNotice();
        },
      );
    }
    final notice = _state.notice;
    if (notice != _shownNotice) {
      _shownNotice = notice;
      if (notice != null) {
        showToast(
          notice,
          kind: ToastKind.info,
          onDismiss: () {
            if (mounted) _state.clearNotice();
          },
        );
      }
    }
    // 自动检查发现新版本：只提示一次，动作直达「软件更新」页。
    //
    // 与上面两条同一套投影规则（值变了才推），但多一个 [AppToastAction]：
    // 提示的价值在「点一下就能装」，让用户自己去设置里找那一行就是白提示。
    final updateNotice = _state.updateNotice;
    if (updateNotice != _shownUpdateNotice) {
      _shownUpdateNotice = updateNotice;
      if (updateNotice != null) {
        showToast(
          '发现新版本 $updateNotice',
          detail: '点「查看」打开软件更新',
          action: AppToastAction(
            label: '查看',
            onPressed: () {
              if (!mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AppUpdatePage(state: _state),
                ),
              );
            },
          ),
          onDismiss: () {
            if (mounted) _state.clearUpdateNotice();
          },
        );
      }
    }
  }

  /// 首次启动展示使用边界提示，确认结果写入配置目录（§22.4）。
  Future<void> _checkBoundary() async {
    final marker = File(
      '${_state.paths.configDir}${Platform.pathSeparator}usage-boundary-accepted',
    );
    final exists = await marker.exists();
    if (!mounted) return;
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
    if (!mounted) return;
    setState(() => _boundaryAccepted = true);
    _state.log.info('用户已确认使用边界提示', scope: 'compliance');
  }

  /// 启动时恢复「上一次使用的配置」（Phase 10）。
  ///
  /// 三条分支，与 `last-config.json` 的内容一一对应：
  /// - **没有记忆且当前配置是本地源**：与升级前完全一致（加载当前站点首页，
  ///   不探测任何设备）；
  /// - **没有记忆但 is_active 是桥接源**（从旧版本升级上来的真实场景）：按它的
  ///   设备 uuid 兜底推断一条等价记忆，照样探一次——遗漏这条分支时这类用户的
  ///   站点 api 会一直停在旧网关地址上，而且连横幅都看不到；
  /// - **本地源**：内容就在库里，直接恢复，不发起任何网络请求；
  /// - **桥接源**：本机只有上次落库的副本，先探一次设备；探通则重新拉取
  ///   **该源**并用 sourceKey 精确激活（同一台设备可能有多个源，按 origin
  ///   挑只会命中最后导入的那条）；探不通则给出非阻塞横幅，把失败分类
  ///   原样呈现，并提供「重试」「切换播放源」。
  ///
  /// 全程只探测一次：不扫描、不轮询、不延时重试（扫描是用户显式动作，
  /// `design/01` §4.4；重试由用户点击触发）。
  Future<void> _restoreLastConfig() async {
    if (!mounted) return;
    if (widget.startup.media != null) return;
    final executionRecord = _state.activeRecord;
    if (executionRecord != null &&
        _state.androidExecutionForRecord(executionRecord) != null) {
      try {
        await _state.refreshAndroidConfigExecution(executionRecord.id);
        if (mounted) await _loadInitialHome();
      } on AppError {
        // AppState keeps the binding selected and clears the stale service;
        // its actionable error is shown through the existing toast host.
      }
      return;
    }
    // 兜底推断（不写盘）：没有 last-config.json 不代表「没有上次使用的源」——
    // 旧版本升级上来的用户本来就没有这份文件，而库里的 is_active 仍在指向一条
    // 桥接记录。推断只用于这一次探测，记忆仍只由显式选择写入。
    final remembered = _state.lastConfigRecord;
    final memory = remembered ?? _inferBridgeMemoryFromActive();
    if (memory == null) {
      // 没有接入历史（或自动接入不适用）时仍必须把当前站点的首页拉起来，
      // 否则启动后停在「没有内容」空态，要用户手动点分类或刷新才有数据
      // （用户反馈 2026-10-09：「刚启动时没有默认加载数据」）。
      await _loadInitialHome();
      return;
    }
    if (memory.isLocal) {
      await _state.restoreLastConfig();
      if (!mounted) return;
      // **不切段**：启动落点是「首页」（用户 2026-11-19 反馈：启动后停在点播
      // 而不是新首页）。恢复配置是后台动作，不是「用户要看这个站点」。
      await _loadInitialHome();
      return;
    }
    if (!memory.isBridge) {
      await _loadInitialHome();
      return;
    }
    // 记录已被用户删掉：静默回落默认配置并留一条日志，不弹窗。
    if (!_state.lastConfigRecordAliveFor(memory)) {
      _state.log.info(
        '上次使用的桥接配置已不存在（${memory.sourceKey}），保持当前配置',
        scope: 'config',
      );
      // 兜底推断出来的记忆从没落过盘，没有可清的东西。
      if (remembered != null) _state.forgetLastConfig();
      await _loadInitialHome();
      return;
    }
    // 管理型（ADB）记录：它的 origin 是上次连接时 adb 分配的本机转发端口，重启
    // 后必然失效。绝不能拿它去探测（旧端口 = 静默失败 + 站源地址停在死端口），
    // 改为按**已保存的连接描述**重连、按 interfaceKey 重导入、再按坐标激活。
    final managed = _state.managedRecordFor(
      recordId: memory.recordId,
      sourceKey: memory.sourceKey,
    );
    if (managed != null) {
      final restored = await _restoreManagedBridge(memory, managed);
      // 恢复失败时不拉首页：站源 api 还停在旧回环端口，拉只会打向死端口。
      if (restored) await _loadInitialHome();
      return;
    }
    final address = _state.deviceAddressForUuid(memory.deviceUuid);
    if (address.isEmpty) {
      _state.log.warning(
        '上次使用的桥接设备不在接入历史里（device=${memory.deviceUuid}），'
        '无法自动重连',
        scope: 'bridge',
      );
      // 连地址都没有就无从探测：直接给横幅，让用户手动切源或去接入页重接。
      _showBridgeBanner(
        memory,
        address: '',
        deviceName: _state.deviceNameForUuid(memory.deviceUuid),
        error: AppError(
          AppErrorKind.bridgeUnreachable,
          '找不到上次使用的安卓设备地址（设备接入历史里没有这台设备）',
          detail: memory.deviceUuid,
        ),
      );
      await _loadInitialHome();
      return;
    }
    await _tryRestoreBridge(address, memory);
    await _loadInitialHome();
  }

  /// 没有记忆时按库里的 is_active 兜底推断一条等价记忆（不写盘）。
  ///
  /// 只因**桥接源**才推断：本地源的内容就在库里，零探测直接加载首页即可，
  /// 推断它对用户没有任何收益，反而多出一个可能出错的环节。
  LastConfigRecord? _inferBridgeMemoryFromActive() {
    final record = _state.activeRecord;
    if (record == null) return null;
    final interfaceKey = record.bridgeInterfaceKey.trim();
    if (interfaceKey.isEmpty) return null;
    final sourceKey = AppState.sourceKeyOfRecord(record);
    final deviceUuid = record.bridgeDevice.trim();
    if (deviceUuid.isEmpty || sourceKey.isEmpty) return null;
    return LastConfigRecord(
      sourceKey: sourceKey,
      recordId: record.id,
      kind: sourceKeyKindBridge,
      deviceUuid: deviceUuid,
      interfaceKey: interfaceKey,
      // 推断记录不入库也不落盘，时间戳只用来满足构造要求。
      savedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// 管理型记录启动恢复：重连已保存的安卓环境 + 重导入该源 + 按坐标激活。
  ///
  /// 失败（描述缺失 / 设备不符 / 离线）走同一条非阻塞横幅，文案直接用 AppState
  /// 的分类错误：用户需要的是「去安卓环境里重连那次保存」，不是一句「连不上」。
  /// 全程不碰记录里的旧回环端口。
  /// 返回 `true` = 端点已刷新且配置已激活（可以继续拉首页）。
  Future<bool> _restoreManagedBridge(
    LastConfigRecord memory,
    ConfigRecord record,
  ) async {
    final saved = _state.androidConnectionForUuid(record.bridgeDevice);
    final deviceName = (saved?.name.trim().isNotEmpty ?? false)
        ? saved!.name.trim()
        : record.name;
    final address = saved == null ? '' : saved.profile.target;
    // 1) 先按描述重连并刷新端点。不能只靠 activateConfigBySourceKey：记录可能
    //    已经是「生效配置」，那条路径会直接返回 true 而一次都不重连。
    final attached = await _state.reattachManagedRecord(record.id);
    if (!mounted) return false;
    if (!attached) {
      _showBridgeBanner(
        memory,
        address: address,
        deviceName: deviceName,
        error:
            _state.lastError ??
            AppError(
              AppErrorKind.bridgeUnreachable,
              '重连已保存的安卓环境失败',
              detail: record.name,
            ),
      );
      return false;
    }
    // 2) 再按坐标激活（已经是生效配置时立即成功，且内容已由重接刷新）。
    final activated = await _state.activateConfigBySourceKey(
      memory.sourceKey,
      recordId: memory.recordId,
    );
    if (!mounted) return false;
    if (!activated) {
      _showBridgeBanner(
        memory,
        address: address,
        deviceName: deviceName,
        error:
            _state.lastError ??
            AppError(
              AppErrorKind.bridgeUnreachable,
              '重连已保存的安卓环境失败',
              detail: record.name,
            ),
      );
      return false;
    }
    setState(() {
      _bridgeBanner = null;
      _bannerMemory = null;
    });
    _state.log.info('已按已保存的安卓环境恢复管理型配置（${memory.sourceKey}）', scope: 'bridge');
    return true;
  }

  /// 探测 + 重新导入 + 精确激活一条桥接源；失败时置横幅状态。
  Future<void> _tryRestoreBridge(
    String address,
    LastConfigRecord memory,
  ) async {
    final sync = _state.syncState;
    final device = await sync.probeAutoConnectTarget(address);
    if (!mounted) return;
    if (device == null) {
      _showBridgeBanner(
        memory,
        address: address,
        deviceName:
            _state.lastConfigDevice?.name ??
            _state.deviceNameForUuid(memory.deviceUuid),
        error:
            sync.lastError ??
            AppError(
              AppErrorKind.bridgeUnreachable,
              '设备探测失败：$address',
              detail: address,
            ),
      );
      return;
    }
    _state.pinLastConfigDevice(device);
    final ok = await sync.importSites(
      device.reachableBase,
      interfaceKey: memory.interfaceKey,
    );
    if (!mounted) return;
    if (!ok) {
      // 探通了但源拉不下来（设备上该源被删/网关版本过旧）：仍然给横幅，
      // 分类由 `importSites` 写进 `lastError`，不折叠成一句「连不上」。
      _showBridgeBanner(
        memory,
        address: device.reachableBase,
        deviceName: device.name,
        error:
            sync.lastError ??
            AppError(
              AppErrorKind.bridgeUnreachable,
              '该播放源导入失败',
              detail: device.reachableBase,
            ),
      );
      return;
    }
    // 按记忆自带的坐标激活：兜底推断出来的记忆不在 lastConfigRecord 里。
    final activated = await _state.activateConfigBySourceKey(
      memory.sourceKey,
      recordId: memory.recordId,
    );
    if (!mounted) return;
    if (!activated) {
      _showBridgeBanner(
        memory,
        address: device.reachableBase,
        deviceName: device.name,
        error: AppError(
          AppErrorKind.configNotFound,
          '上次使用的配置记录已不存在',
          detail: memory.sourceKey,
        ),
      );
      return;
    }
    setState(() {
      // 同上：恢复桥接配置不改变当前段（启动时应停在首页）。
      _bridgeBanner = null;
      _bannerMemory = null;
    });
    _state.log.info('已恢复上次使用的桥接配置（${memory.sourceKey}）', scope: 'bridge');
  }

  void _showBridgeBanner(
    LastConfigRecord memory, {
    required String address,
    required String deviceName,
    required AppError error,
  }) {
    setState(() {
      _bannerMemory = memory;
      _bridgeBanner = BridgeRestoreFailure(
        sourceKey: memory.sourceKey,
        deviceName: deviceName,
        address: address,
        error: error,
      );
    });
  }

  /// 横幅「重试」：只在用户点击时重探一次（复用同一条恢复路径，带 busy 态）。
  Future<void> _retryBridgeRestore() async {
    final banner = _bridgeBanner;
    // 没有记忆的兜底恢复：横幅自带那条推断出来的记忆。
    final memory = _state.lastConfigRecord ?? _bannerMemory;
    if (banner == null || memory == null || _restoringBridge) return;
    setState(() => _restoringBridge = true);
    try {
      // 管理型记录的重试是「按描述重连」，不是重探旧地址。
      final managed = _state.managedRecordFor(
        recordId: memory.recordId,
        sourceKey: memory.sourceKey,
      );
      if (managed != null) {
        final restored = await _restoreManagedBridge(memory, managed);
        if (restored) await _loadInitialHome();
        return;
      }
      final address = banner.address.isNotEmpty
          ? banner.address
          : _state.deviceAddressForUuid(memory.deviceUuid);
      if (address.isEmpty) {
        setState(() {
          _bridgeBanner = BridgeRestoreFailure(
            sourceKey: banner.sourceKey,
            deviceName: banner.deviceName,
            address: '',
            error: AppError(
              AppErrorKind.bridgeUnreachable,
              '找不到上次使用的安卓设备地址（设备接入历史里没有这台设备）',
              detail: banner.deviceName,
            ),
          );
        });
        return;
      }
      await _tryRestoreBridge(address, memory);
      await _loadInitialHome();
    } finally {
      if (mounted) setState(() => _restoringBridge = false);
    }
  }

  /// 横幅「切换播放源」：复用现有站点选择器，不另造一个选择器。
  Future<void> _openSitePickerFromBanner() async {
    setState(() {
      _bridgeBanner = null;
      _bannerMemory = null;
    });
    await _openSitePicker();
  }

  /// 启动时把当前站点的首页拉起来（幂等：已有内容或正在加载就不重复）。
  ///
  /// 为什么必须有：`bootstrap()` 只恢复配置与 `_selectedSite`（`config.defaultSite()`），
  /// **从不发首页请求**；而浏览页在无 `homeResult` 时只渲染空态。
  /// 于是冷启动后用户看到的是「没有内容」，必须手动点分类或刷新。
  Future<void> _loadInitialHome() async {
    if (!mounted) return;
    final site = _state.selectedSite;
    if (site == null || _state.webHomeSourceForSite(site) != null) return;
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
          builder: (_) =>
              PlayerPage(state: _state, request: _commandLineRequest(media)),
        ),
      );
    });
  }

  /// 命令行媒体 → 播放请求。
  ///
  /// 本地文件走 [PlaybackRequest.localFile]（不带 Header、siteKey 固定为
  /// `local-file`），其余仍是原来的 `cli` 合成站点。判据来自
  /// [StartupArguments.mediaIsLocal]，UI 层不重新猜路径形状。
  PlaybackRequest _commandLineRequest(String media) {
    final seek = widget.startup.seekSeconds == null
        ? null
        : Duration(milliseconds: (widget.startup.seekSeconds! * 1000).round());
    if (widget.startup.mediaIsLocal) {
      final local = PlaybackRequest.localFile(path: media);
      return seek == null ? local : local.copyWith(startPosition: seek);
    }
    return PlaybackRequest(
      url: media,
      headers: widget.startup.headers,
      title: '命令行媒体',
      siteKey: 'cli',
      vodId: 'cli',
      vodName: '命令行媒体',
      episodeName: '媒体',
      flag: 'cli',
      startPosition: seek,
    );
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    super.dispose();
  }

  /// 顶栏「配置：xxx」的点击：**换配置**，不是管理配置。
  ///
  /// 用户点这几个字的意图几乎总是「我要用另一个源」（用户反馈 2026-11-05）。
  /// 原来它直接冲进配置管理页，而那一页首屏是一大块导入表单，换配置的列表
  /// 被压到下面——想做最常做的事，反而要先在管理页里找到列表。
  ///
  /// 单条配置仍展示当前项与管理入口；无配置时直接进入导入与管理。
  Future<void> _openConfigSwitcher() async {
    if (_state.savedConfigs.isEmpty) {
      await _openConfigPage();
      return;
    }
    var manageRequested = false;
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<int>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      // 第 4 个键：遮罩是玻璃的采样底。Material 默认的 `Colors.black54` 先把
      // 页面压暗 54%，玻璃再染底，12px 说明文字只剩 2.76:1（pilot-1 §4-1）。
      // 亮色因此换成 0.18；暗色 `glassBarrierColor` 返回的就是 `Colors.black54`，
      // 与 Material 默认完全相同 —— 暗色这一处逐像素不变。
      barrierColor:
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          glassBarrierColor(context),
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      builder: (_) => ConfigSwitcherDialog(
        records: _state.savedConfigs,
        activeId: _state.activeRecord?.id,
        onManage: () => manageRequested = true,
      ),
    );
    final targetId = await navigator.push(route);
    if (manageRequested) {
      // 等遮罩与退出动画真正移除，再让管理页成为新的前景路由。
      await route.completed;
      if (mounted) await _openConfigPage();
      return;
    }
    if (targetId == null || !mounted) return;
    if (targetId == _state.activeRecord?.id) return;
    await _state.activateConfigRecord(targetId);
    if (mounted) setState(() {});
  }

  /// 首页「热门」卡片 → 带着这个词进搜索页。
  ///
  /// 只切段 + 传词，不复用搜索页的内部方法：搜索的提交/分页/范围都属于
  /// `SearchPage` 自己的状态机，壳层只负责「去哪、带什么」。
  void _searchFor(String keyword) {
    setState(() {
      _pendingSearchKeyword = keyword;
      _section = ShellSection.search;
    });
  }

  Future<void> _openConfigPage() async {
    setState(() {
      _section = ShellSection.settings;
      _settingsInitialCategory = SettingsCategory.sites;
      _settingsEntryKey = UniqueKey();
    });
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ConfigPage(state: _state)));
    if (mounted) setState(() {});
  }

  Future<void> _openSitePicker() async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<Site>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor:
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          glassBarrierColor(context),
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      builder: (_) => SitePickerDialog(
        items: _state.siteItems,
        log: _state.log,
        rules: _state.siteGroupSettings.enabledRules,
        // 把"当前站点"传进去：换源对话框必须能标出你现在在哪个源上。
        selectedKey: _state.selectedSite?.key,
        // 手动排序 + 屏蔽（参照安卓 SiteOrderStore / SiteBlockSetting）：
        // 打开时带当前配置的状态进去，改动立刻回写并落盘。
        blockedKeys: _state.blockedSiteKeys,
        defaultOrderKeys: _state.siteConfigOrderKeys,
        onReorder: _state.setSiteManualOrder,
        onBlockedChanged: _state.setSiteBlocked,
      ),
    );
    final selected = await navigator.push(route);
    if (selected == null) return;
    // 本地/在线 HTML 首页条目：它不是爬虫，`selectSite` 会走 [AppState.loadHome]
    // 并得到一次假「站点不可用」。这里直接打开页面宿主（WebView2）。
    final webHome = _state.webHomeSourceForSite(selected);
    if (webHome != null) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => WebHomePage(state: _state, source: webHome),
        ),
      );
      if (mounted) setState(() {});
      return;
    }
    _section = ShellSection.browse;
    final loading = _state.selectSite(selected);
    _scheduleShellUnpackOffer();
    await loading;
    // 加固壳：站点进入后 state 会登记「要不要确认解包」，这里负责问。
    await _maybeOfferShellUnpack();
  }

  /// 选完站点后：若该站点还要解包，弹多选（默认勾选它所属的 jar）。
  ///
  /// 取消 = 什么都不做：不下载运行时、不下载 jar。自动弹出来的东西必须能安静退场。
  Future<void> _maybeOfferShellUnpack() async {
    if (_shellUnpackFlowOpen) return;
    final siteKey = _state.takePendingShellUnpackForSite();
    if (siteKey == null || !mounted || _state.selectedSite?.key != siteKey) {
      return;
    }
    final site = _state.selectedSite;
    final items = _state.shellUnpackItems(preferSiteKey: siteKey);
    if (items.isEmpty) return;
    _shellUnpackFlowOpen = true;
    try {
      final selected = await showShellUnpackSelection(
        context,
        items: items,
        runtimeStateLabel: _state.shellUnpackRuntimeStateLabel,
      );
      if (selected == null ||
          selected.isEmpty ||
          !mounted ||
          !identical(site, _state.selectedSite)) {
        return;
      }
      final ticks = StreamController<ShellUnpackTick>();
      final progress = showShellUnpackProgress(
        context,
        jarCount: selected.length,
        ticks: ticks.stream,
      );
      try {
        await _state.unpackShellTargets(
          selected,
          onTick: (tick) {
            if (!ticks.isClosed) ticks.add(tick);
          },
        );
      } catch (error) {
        // 失败要落在对话框里（阶段 + 原因），不许静默关掉。
        if (!ticks.isClosed) ticks.addError(error);
      } finally {
        if (!ticks.isClosed) await ticks.close();
      }
      await progress;
    } finally {
      _shellUnpackFlowOpen = false;
    }
    if (mounted) setState(() {});
  }

  /// 顶栏「推送」：地址粘贴与本地文件选择都从这个对话框起播。
  ///
  /// 本地文件不再由壳层自己构造 `PlaybackRequest.localFile`，而是走
  /// `submitPush`（本地路径在状态层被识别）——起播与历史/匹配因此只有一条链路。
  Future<void> _openPushDialog() async {
    await showDialog<void>(
      context: context,
      barrierColor:
          DialogTheme.of(context).barrierColor ??
          Theme.of(context).dialogTheme.barrierColor ??
          glassBarrierColor(context),
      builder: (_) =>
          PushDialog(state: _state, pickLocalFile: _pickLocalMediaPath),
    );
    if (mounted) setState(() {});
  }

  /// 原生文件对话框；测试经 [AppShell.pickLocalMediaFile] 注入替身。
  Future<String?> _pickLocalMediaPath() async {
    final injected = widget.pickLocalMediaFile;
    if (injected != null) return injected();
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '打开本地视频文件',
        type: FileType.video,
      );
      return file?.path;
    } catch (error) {
      _state.log.warning('选择本地视频文件失败 $error', scope: 'player');
      return null;
    }
  }

  /// 崩溃恢复：用标记里的标识信息按历史续播路径重新解析并播放。
  ///
  /// 标记里**没有** URL/Header（见 `core/session_recovery.dart`），
  /// 因此这里必须走 `resumeHistoryEntry` 重新解析，而不是直接起播。
  Future<void> _resumeRecovered(SessionPlaybackContext context_) async {
    final item = PlaybackHistory(
      id: 0,
      siteKey: context_.siteKey,
      vodId: context_.vodId,
      vodName: context_.vodName,
      flag: context_.flag,
      episodeName: context_.episodeName,
      episodeId: context_.episodeId,
      positionMs: context_.positionMs,
      durationMs: context_.durationMs,
      updatedAt: context_.updatedAtMs,
    );
    await _state.dismissRecovery();
    if (!mounted) return;
    await resumeHistoryEntry(context, _state, item);
  }

  Future<void> _showCrashLog() async {
    final text = _state.recoveryCrashLog;
    await showDialog<void>(
      context: context,
      builder: (context) => GlassAlertDialog(
        constraints: const BoxConstraints(maxWidth: 688),
        title: const Text('崩溃日志（最近一段）'),
        content: SizedBox(
          width: 640,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(
              text ?? '没有可用的崩溃日志。',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final boundaryAccepted = _boundaryAccepted;
    if (boundaryAccepted == null) {
      return const Scaffold(body: LoadingBlock());
    }

    final startupNotifications = <Widget>[
      if (_state.storageWarnings.isNotEmpty)
        _StorageWarningBanner(warnings: _state.storageWarnings),
      if (_bridgeBanner != null)
        BridgeRestoreBanner(
          key: const ValueKey('bridge-restore-banner'),
          failure: _bridgeBanner!,
          busy: _restoringBridge,
          onRetry: _retryBridgeRestore,
          onSwitchSource: _openSitePickerFromBanner,
          onDismiss: () => setState(() => _bridgeBanner = null),
        ),
      if (_state.restoredConfigSourceStatus?.needsAttention ?? false)
        RestoredConfigSourceBanner(
          status: _state.restoredConfigSourceStatus!,
          onManage: _openConfigPage,
          onDismiss: _state.dismissRestoredConfigSourceWarning,
        ),
      if (_state.pendingRecovery != null)
        RecoveryBanner(
          marker: _state.pendingRecovery!,
          hasCrashLog: _state.recoveryCrashLog != null,
          onResume: _resumeRecovered,
          onShowLog: _showCrashLog,
          onDismiss: () => _state.dismissRecovery(),
        ),
    ];

    if (_section != ShellSection.home) _homeHeroBackdrop = null;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        bottomSheetTheme: theme.bottomSheetTheme.copyWith(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      child: Scaffold(
        body: WallpaperBackdrop(
          url: _state.config?.wallpaper,
          builder: (context, hasWallpaper) {
            final heroBackdrop = _homeHeroBackdrop;
            final hasArtwork = heroBackdrop != null || hasWallpaper;
            const topInset = EdgeInsets.only(top: kShellContentTopInset);
            return Stack(
              children: [
                // backdrop 和页面先画，顶栏在最后采样并拥有整个条带的命中。
                Positioned.fill(child: IgnorePointer(child: heroBackdrop)),
                Positioned.fill(
                  child: Row(
                    children: [
                      Padding(
                        padding: topInset,
                        child: AppSideBar(
                          section: _section,
                          updateCount: _state.followingUpdateCount,
                          onSelect: (value) => setState(() {
                            // 手动进搜索页 = 一次全新的搜索，丢掉首页带过来的词。
                            if (value == ShellSection.search) {
                              _pendingSearchKeyword = null;
                            }
                            if (value == ShellSection.settings &&
                                _section != ShellSection.settings) {
                              _settingsInitialCategory =
                                  SettingsCategory.preferences;
                              _settingsEntryKey = UniqueKey();
                            }
                            _section = value;
                            if (value == ShellSection.browse) _enterBrowse();
                          }),
                        ),
                      ),
                      const SizedBox(width: 1),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final noticeInset = startupNotifications.isEmpty
                                ? 0.0
                                : kShellContentTopInset;
                            return Padding(
                              padding: EdgeInsets.only(top: noticeInset),
                              child: Column(
                                children: [
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxHeight:
                                          (constraints.maxHeight -
                                              noticeInset) /
                                          3,
                                    ),
                                    child: SingleChildScrollView(
                                      primary: false,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: startupNotifications,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: ClipRect(
                                      child: LayoutBuilder(
                                        builder: (context, page) {
                                          // Pages retain their own shell inset;
                                          // reclaim it above this clipped body.
                                          final height =
                                              page.maxHeight + noticeInset;
                                          return OverflowBox(
                                            alignment: Alignment.bottomCenter,
                                            minHeight: height,
                                            maxHeight: height,
                                            child: AppShellTransition(
                                              sectionIndex: _section.index,
                                              child: _buildContent(
                                                hasArtwork: hasArtwork,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Listener(
                    key: const ValueKey('shell-top-bar-hit-region'),
                    behavior: HitTestBehavior.opaque,
                    child: _TopBar(
                      state: _state,
                      backdrop: hasArtwork
                          ? GlassTopBarBackdrop.content
                          : GlassTopBarBackdrop.flatSurface,
                      onOpenConfig: _openConfigSwitcher,
                      onOpenSitePicker: _openSitePicker,
                      onOpenPush: _openPushDialog,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        // 首次启动的边界提示不可跳过。
        bottomSheet: boundaryAccepted
            ? null
            : _BoundarySheet(onAccept: _acceptBoundary),
      ),
    );
  }

  Widget _buildContent({required bool hasArtwork}) {
    switch (_section) {
      case ShellSection.home:
        return Padding(
          padding: const EdgeInsets.only(top: kShellContentTopInset),
          child: HomePage(
            state: _state,
            hasShellArtwork: hasArtwork,
            onHeroBackdropChanged: (backdrop) {
              if (!mounted ||
                  _section != ShellSection.home ||
                  _homeHeroBackdrop == backdrop) {
                return;
              }
              setState(() => _homeHeroBackdrop = backdrop);
            },
            onOpenBrowse: () => setState(() {
              _section = ShellSection.browse;
              _enterBrowse();
            }),
            onOpenHistory: () =>
                setState(() => _section = ShellSection.history),
            onOpenFollowing: () =>
                setState(() => _section = ShellSection.following),
            onImportConfig: _openConfigPage,
            onSearch: _searchFor,
          ),
        );
      case ShellSection.browse:
        return BrowsePage(state: _state, shellUnderlap: true);
      case ShellSection.live:
        return LivePage(state: _state, shellUnderlap: true);
      case ShellSection.search:
        return SearchPage(
          // 换词必须换 State：`initialKeyword` 只在 initState 读一次。
          key: ValueKey('search-${_pendingSearchKeyword ?? ''}'),
          state: _state,
          initialKeyword: _pendingSearchKeyword,
          shellUnderlap: true,
        );
      case ShellSection.history:
        return HistoryPage(state: _state, shellUnderlap: true);
      case ShellSection.favorites:
        return FavoritesPage(state: _state, shellUnderlap: true);
      case ShellSection.following:
        return FollowingPage(state: _state, shellUnderlap: true);
      case ShellSection.settings:
        return SettingsPage(
          key: _settingsEntryKey,
          state: _state,
          initialCategory: _settingsInitialCategory,
          shellUnderlap: true,
        );
    }
  }
}

/// 桥接源恢复失败的描述（横幅只做展示，判定留在 `_AppShellState`）。
class BridgeRestoreFailure {
  const BridgeRestoreFailure({
    required this.sourceKey,
    required this.deviceName,
    required this.address,
    required this.error,
  });

  final String sourceKey;

  /// 设备名（设备历史里没有这台时退化成 uuid）。
  final String deviceName;

  /// 当时探测的地址；空串表示连地址都没找到。
  final String address;

  /// 失败分类与文案，**原样**呈现给用户。
  final AppError error;
}

/// 桥接源恢复失败横幅。
///
/// 为什么必须是**非阻塞**横幅而不是弹窗：启动恢复是应用自己的动作，用户没有
/// 发起任何操作，不应该被一个对话框拦在首屏之前。横幅同时承担「解释原因」与
/// 「给出下一个动作」——只解释不给出路，等于让用户自己去配置页翻。
class BridgeRestoreBanner extends StatelessWidget {
  const BridgeRestoreBanner({
    super.key,
    required this.failure,
    required this.onRetry,
    required this.onSwitchSource,
    required this.onDismiss,
    this.busy = false,
  });

  final BridgeRestoreFailure failure;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback onSwitchSource;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.onTertiaryContainer;
    final address = failure.address;
    // 分类必须原样出现（bridgeUnreachable / bridgeNoGateway / hostMismatch
    // 是三种完全不同的处置），所以文案由分类决定，而不是笼统的「连不上」。
    final reason =
        '${failure.error.message.isEmpty ? describeErrorKind(failure.error.kind) : failure.error.message}'
        '（${failure.error.kind.name}）';
    return Container(
      key: const ValueKey('bridge-restore-banner-body'),
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.xl,
        vertical: AppSpace.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.link_off, size: 18, color: color),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              '上次使用的安卓播放源连不上：'
              '${failure.deviceName.isEmpty ? '未知设备' : failure.deviceName}'
              '${address.isEmpty ? '' : ' @ $address'}'
              ' · $reason'
              '${address.isEmpty ? '。请到「安卓设备接入」重新接入该设备' : ''}',
              key: const ValueKey('bridge-restore-banner-text'),
              style: TextStyle(color: color, fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            key: const ValueKey('bridge-restore-retry'),
            onPressed: busy ? null : onRetry,
            child: Text(busy ? '重试中…' : '重试'),
          ),
          TextButton(
            key: const ValueKey('bridge-restore-switch-source'),
            onPressed: onSwitchSource,
            child: const Text('切换播放源'),
          ),
          IconButton(
            key: const ValueKey('bridge-restore-dismiss'),
            tooltip: '关闭',
            onPressed: onDismiss,
            icon: Icon(Icons.close, size: 16, color: color),
          ),
        ],
      ),
    );
  }
}

/// 数据目录不可写横幅。
///
/// 为什么必须上屏：这类故障以前是**静默降级**——用户只会发现「历史记录没了」，
/// 而唯一的线索（`PathAccessException` / `SQLITE_READONLY`）恰好写不进日志文件；
/// 能看见的那条 SQLite 报错又会把人引向「删库重建」，而真正的原因是**整个数据
/// 目录不可写**（Windows 低完整性进程对中等完整性目录只读）。
class _StorageWarningBanner extends StatelessWidget {
  const _StorageWarningBanner({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = TextStyle(color: scheme.onErrorContainer, fontSize: 12);
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.xl,
        vertical: AppSpace.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.folder_off_outlined,
            size: 18,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: SelectableText(
              '数据目录不可写，本次运行不会保存历史与设置：${warnings.join("；")}',
              style: textStyle,
              maxLines: 3,
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.state,
    required this.backdrop,
    required this.onOpenConfig,
    required this.onOpenSitePicker,
    required this.onOpenPush,
  });

  final AppState state;
  final GlassTopBarBackdrop backdrop;
  final VoidCallback onOpenConfig;
  final VoidCallback onOpenSitePicker;
  final VoidCallback onOpenPush;

  @override
  Widget build(BuildContext context) {
    final site = state.selectedSite;
    final record = state.activeRecord;
    final theme = Theme.of(context);
    return GlassTopBar(
      backdrop: backdrop,
      child: Row(
        children: [
          _BrandMark(logo: state.config?.logo),
          const SizedBox(width: AppSpace.md),
          Text('WebHTV', style: theme.textTheme.titleMedium),
          const SizedBox(width: AppSpace.xl),
          Expanded(
            child: Row(
              children: [
                // 配置名可能很长，顶栏不能被它挤爆：限宽 + 省略号，
                // 完整名字走 Tooltip。
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Tooltip(
                      message: record == null ? '未导入配置' : '当前配置：${record.name}',
                      child: TextButton.icon(
                        onPressed: onOpenConfig,
                        icon: const Icon(Icons.swap_horiz, size: 18),
                        label: Text(
                          record == null ? '导入配置' : '配置：${record.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.xs),
                Flexible(
                  child: Tooltip(
                    message: site == null ? '选择站点' : '站点：${site.name}',
                    child: TextButton.icon(
                      onPressed: state.siteItems.isEmpty
                          ? null
                          : onOpenSitePicker,
                      icon: const Icon(Icons.dns_outlined, size: 18),
                      label: Text(
                        site == null ? '选择站点' : '站点：${site.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.xs),
                // 本地文件与推送地址是同一件事的两种来源（用户 2026-11-20 决策）：
                // 合并成一个「推送」，选文件在对话框里。入口仍独立于「站点：xxx」——
                // 放自己硬盘上的文件或粘贴地址，都不该要求先选站点。
                TextButton.icon(
                  key: const ValueKey('topbar-push'),
                  onPressed: onOpenPush,
                  icon: const Icon(Icons.send_outlined, size: 18),
                  label: const Text('推送'),
                ),
                if (state.webHomeLoadError != null)
                  Tooltip(
                    key: const ValueKey('webhome-load-error'),
                    message: state.webHomeLoadError!,
                    child: Text(
                      '载入HTML源失败',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
          if (state.importDiagnosticsSummary != null)
            Tooltip(
              message: state.importDiagnosticsSummary!,
              child: const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Icon(Icons.info_outline, size: 18),
              ),
            ),
          Text('v$appVersion', style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// 顶栏品牌标记：配置提供 `logo` 时用它，否则用应用自身图标。
///
/// 用户确认「配置提供的 `logo` 必须真的生效」——这是**用户的**品牌，
/// 优先级高于 PC 端自身身份（`PRODUCT.md` 的 Brand Commitments）。
///
/// 与 `PosterImage` 同一个教训：外层 `Container` **不能加 `alignment`**，
/// 否则子节点拿到松约束、`BoxFit.cover` 没有盒子可铺。这里用紧约束 + `clipBehavior`。
class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.logo});

  final String? logo;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final target = logo?.trim() ?? '';
    Widget fallback() =>
        Icon(Icons.movie_filter_outlined, color: scheme.primary, size: 18);
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: AppRadius.smAll,
      ),
      clipBehavior: Clip.antiAlias,
      child: target.isEmpty
          ? fallback()
          : Image.network(
              target,
              fit: BoxFit.cover,
              // 配置 logo 也是外部图片：同样按 host 注入顶层 `headers` 规则；
              // `Accept` 只作兜底——用户用本地 flask 图床当 logo 时，缺它会被 406。
              headers: imageHeadersOrNull(
                context,
                target,
                extra: const {'Accept': 'image/*,*/*;q=0.8'},
              ),
              // logo 是用户提供的外部资源：取不到时**安静退回应用图标**，
              // 不留破图。它只是标记，不该影响可用性。
              errorBuilder: (_, _, _) => fallback(),
              loadingBuilder: (context, child, progress) =>
                  progress == null ? child : fallback(),
            ),
    );
  }
}

/// 侧栏。公开而不是私有：它的容量（8 项能否放进最小窗口）与入口集合都是
/// 回归风险，必须能单独挂载并断言（test/shell_rail_capacity_test.dart）。
class AppSideBar extends StatelessWidget {
  const AppSideBar({
    super.key,
    required this.section,
    required this.onSelect,
    this.updateCount = 0,
  });

  final ShellSection section;
  final ValueChanged<ShellSection> onSelect;
  final int updateCount;

  @override
  Widget build(BuildContext context) {
    return GlassChromeSurface(
      showRim: false,
      child: NavigationRail(
        backgroundColor: Colors.transparent,
        selectedIndex: section.index,
        onDestinationSelected: (index) => onSelect(ShellSection.values[index]),
        minWidth: 76,
        groupAlignment: -0.9,
        labelType: NavigationRailLabelType.all,
        // 8 个入口在最小窗口（1024×640，内容区 576px）下放得下。`scrollable` 留着
        // 当兜底：2026-11-19 实测 11 项溢出 72px、10 项也溢出 8px——导航不该因为
        // 以后再引入口就无声破图。
        scrollable: true,
        destinations: [
          const NavigationRailDestination(
            icon: Icon(Icons.home_outlined),
            label: Text('首页'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.grid_view),
            label: Text('点播'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.live_tv),
            label: Text('直播'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.search),
            label: Text('搜索'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.history),
            label: Text('最近观看'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.bookmark_border),
            label: Text('收藏'),
          ),
          // 追番列表与追剧日历合并成一个入口（页面内用「列表 / 日历」切换）。
          NavigationRailDestination(
            icon: Badge(
              isLabelVisible: updateCount > 0,
              label: Text('$updateCount'),
              child: const Icon(Icons.star_border),
            ),
            label: const Text('追剧'),
          ),
          const NavigationRailDestination(
            icon: Icon(Icons.tune),
            label: Text('设置'),
          ),
        ],
      ),
    );
  }
}

class _BoundarySheet extends StatelessWidget {
  const _BoundarySheet({required this.onAccept});

  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    return GlassPane(
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('使用边界提示', style: Theme.of(context).textTheme.titleLarge),
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
  const SitePickerDialog({
    super.key,
    required this.items,
    required this.log,
    this.selectedKey,
    this.rules = builtinSiteGroupRules,
    this.blockedKeys = const <String>{},
    this.defaultOrderKeys = const <String>[],
    this.onReorder,
    this.onBlockedChanged,
  });

  final List<SiteListItem> items;

  /// 站点清单的内部字段（key/type/运行时/阶段/不可用原因）不再上屏，
  /// 改为写日志：排查「某站点为何不可用」时仍然拿得到。
  final LogService log;

  /// 当前正在使用的站点 key。
  ///
  /// 为什么必须传进来：这是**换源**对话框，而它此前完全不知道当前用的是哪个源——
  /// 用户配置里有上百个站点时，没有任何东西告诉他"你现在在哪个上面"，
  /// 只能靠记忆（截图复核时发现，2026-10-11）。
  final String? selectedKey;

  /// 生效的分组规则（Phase 9 P1-5）；默认 4 条内置规则。
  final List<SiteGroupRule> rules;

  /// 当前配置下被屏蔽的站点 key（列表默认不显示它们）。
  final Set<String> blockedKeys;

  /// 配置原始顺序的站点 key：只给排序模式的「恢复默认」用。
  ///
  /// 不能从 [items] 反推：传进来的 [items] 已经按用户的手动顺序排过。
  final List<String> defaultOrderKeys;

  /// 拖动排序后回写（传空列表 = 恢复默认）。null 表示不提供排序入口。
  final Future<bool> Function(List<String> orderedKeys)? onReorder;

  /// 屏蔽/取消屏蔽回写。null 表示不提供屏蔽入口。
  final Future<bool> Function(String siteKey, bool blocked)? onBlockedChanged;

  @override
  State<SitePickerDialog> createState() => _SitePickerDialogState();
}

class _SitePickerDialogState extends State<SitePickerDialog> {
  final TextEditingController _keyword = TextEditingController();

  /// 当前选中的分组；空串 = 全部。
  String _group = '';

  /// 站点 key 的当前顺序（含被屏蔽站点）。
  ///
  /// 与 [widget.items] 分开存：排序模式拖动后必须立刻反映到网格，而
  /// [widget.items] 是打开对话时的快照。被屏蔽站点也留在顺序里——解除屏蔽后
  /// 它应该回到原来的位置，而不是排到最后。
  late List<String> _order;

  late final Map<String, SiteListItem> _byKey;

  /// 本对话框内的屏蔽集合（初值来自 [SitePickerDialog.blockedKeys]）。
  late Set<String> _blocked;

  /// 排序模式：单列 + 拖动手柄。
  bool _sorting = false;

  /// 屏蔽管理：显示全部站点，点击一行即切换屏蔽。
  bool _blockedEditing = false;

  @override
  void initState() {
    super.initState();
    _byKey = {for (final item in widget.items) item.site.key: item};
    _order = [for (final item in widget.items) item.site.key];
    _blocked = {...widget.blockedKeys};
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
        'groups=${siteGroupsOf(site.name, rules: widget.rules).join("|")} '
        'reason=${availability.reason ?? "-"}',
        scope: 'site',
      );
    }
  }

  /// 当前可见的分组（按站点顺序去重，只统计当前关键字命中的站点）。
  ///
  /// 屏蔽管理模式下被屏蔽的站点也在列——否则「把只属于该分组的所有站点都屏蔽了」
  /// 之后，分组标签会先消失，用户没法在同一个界面里取消屏蔽。
  List<String> get _groups {
    final seen = <String>[];
    for (final item in _keywordMatched) {
      if (!_blockedEditing && _blocked.contains(item.site.key)) continue;
      for (final group in siteGroupsOf(item.site.name, rules: widget.rules)) {
        if (!seen.contains(group)) seen.add(group);
      }
    }
    return seen;
  }

  List<SiteListItem> get _keywordMatched {
    final items = <SiteListItem>[];
    // 按 [_order] 走：手动顺序对搜索命中的结果同样生效。
    for (final key in _order) {
      final item = _byKey[key];
      if (item == null) continue;
      if (!siteMatchesQuery(
        name: item.site.name,
        key: item.site.key,
        query: _keyword.text,
      )) {
        continue;
      }
      items.add(item);
    }
    return items;
  }

  List<SiteListItem> get _visible => [
    for (final item in _keywordMatched)
      if (_group.isEmpty || siteInGroup(item.site.name, _group))
        if (_blockedEditing || !_blocked.contains(item.site.key)) item,
  ];

  /// 把顺序回写给 AppState（失败只记日志，不回滚界面：拖动已经发生）。
  void _persistOrder([List<String>? keys]) {
    final callback = widget.onReorder;
    if (callback == null) return;
    unawaited(
      callback(keys ?? List<String>.of(_order)).then(
        (_) => true,
        onError: (Object error) {
          widget.log.warning('保存站点顺序失败：$error', scope: 'site');
          return false;
        },
      ),
    );
  }

  /// 恢复默认顺序：界面回到配置顺序，并清掉已保存的手动顺序。
  void _resetOrder() {
    if (widget.defaultOrderKeys.isEmpty) return;
    setState(() => _order = List<String>.of(widget.defaultOrderKeys));
    _persistOrder(const <String>[]);
  }

  /// 分组在当前筛选结果里消失时复位（对齐安卓 `SiteDialog.setGroupView`）。
  ///
  /// 典型场景：在屏蔽管理里把某个分组的站点全屏蔽了，退出后那个 chip 已经不
  /// 存在——继续按它过滤只会得到空列表，而且没有任何 chip 处于选中态可解释。
  void _normalizeGroup() {
    if (_group.isEmpty || _groups.contains(_group)) return;
    _group = '';
  }

  void _toggleBlocked(SiteListItem item) {
    final key = item.site.key;
    final blocked = !_blocked.contains(key);
    setState(() {
      if (blocked) {
        _blocked.add(key);
      } else {
        _blocked.remove(key);
      }
      _normalizeGroup();
    });
    final callback = widget.onBlockedChanged;
    if (callback == null) return;
    unawaited(
      callback(key, blocked).then(
        (_) => true,
        onError: (Object error) {
          widget.log.warning('保存站点屏蔽状态失败：$error', scope: 'site');
          return false;
        },
      ),
    );
  }

  void _toggleSorting() {
    setState(() {
      _sorting = !_sorting;
      if (_sorting) _blockedEditing = false;
    });
  }

  void _toggleBlockedEditing() {
    setState(() {
      _blockedEditing = !_blockedEditing;
      if (_blockedEditing) _sorting = false;
      // 进出屏蔽管理都会改变可见站点集合，分组候选随之变化。
      _normalizeGroup();
    });
  }

  /// 单个站点行（两列网格里的一格）。
  ///
  /// 抽成方法而不是内联在 `itemBuilder` 里：两列网格与单列列表共用同一套行渲染，
  /// 也便于单独读这一行的语义（状态色 / 当前标记 / 可搜索标记）。
  Widget _siteRow(BuildContext context, SiteListItem item) {
    final theme = Theme.of(context);
    final availability = item.availability;
    final available = availability.available;
    final blocked = _blocked.contains(item.site.key);
    final isCurrent =
        widget.selectedKey != null && item.site.key == widget.selectedKey;
    final semantic = context.semanticColors;
    // 屏蔽管理模式下每一行的点击都是「切换屏蔽」，不再进入站点（对齐安卓
    // `SiteDialog.onTextClick`：block 为真时只 toggle，不 dismiss）。
    final onTap = _blockedEditing
        ? () => _toggleBlocked(item)
        : (available ? () => Navigator.of(context).pop(item.site) : null);
    return Opacity(
      // 被屏蔽但仍显示（屏蔽管理）的行压暗：与安卓 adapter 的 0.55 alpha 同一意图。
      opacity: _blockedEditing && blocked ? 0.55 : 1,
      child: ListTile(
        key: ValueKey('site-option-${item.site.key}'),
        dense: true,
        selected: isCurrent,
        leading: Icon(
          available ? Icons.check_circle_outline : Icons.block,
          // 用设计系统的状态色，不用 `Colors.greenAccent` 与框架的
          // `disabledColor`——那两个不属于这个世界（craft-floor：散落的框架默认值）。
          color: available ? semantic.statusOk : semantic.statusUnknown,
        ),
        // 只显示名称：key/type/运行时属协议内部字段，已写日志。
        title: Text(
          item.site.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: available
            ? null
            : Text(
                availability.reason ?? '当前不可用',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (blocked && _blockedEditing) ...[
              Text(
                '已屏蔽',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: AppSpace.sm),
            ],
            if (isCurrent) ...[
              Text(
                '当前',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: semantic.magnitude,
                ),
              ),
              const SizedBox(width: AppSpace.sm),
            ],
            if (item.site.searchable) const Icon(Icons.search, size: 16),
          ],
        ),
        enabled: _blockedEditing || available,
        onTap: onTap,
      ),
    );
  }

  /// 空列表提示：区分「配置里就没有站点」「都被屏蔽了」「只是没命中关键字」。
  String _emptyHint() {
    if (widget.items.isEmpty) return '当前配置没有可用站点';
    if (_blocked.isNotEmpty && _keyword.text.trim().isEmpty && _group.isEmpty) {
      return '站点都被屏蔽了：点右上角眼睛图标可管理屏蔽';
    }
    return '没有匹配的站点';
  }

  /// 排序模式：单列 + 拖动手柄。
  ///
  /// 为什么不在两列网格里直接拖：Flutter 的 `ReorderableListView` 只支持单列，
  /// 网格拖动要自己维护 `Draggable`/`DragTarget` 交换与边缘滚动，而桌面鼠标也
  /// 没有安卓「长按条目拖动」的心智。显式排序模式复用播放器按钮排版那套既有引擎
  /// （`player_button_config_page`），行为可单测、鼠标可达。
  Widget _sortPanel(BuildContext context) {
    final theme = Theme.of(context);
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      itemCount: _order.length,
      // 默认 proxyDecorator 会把 elevation 从 0 动到 6，违反 The Zero-Elevation
      // Rule；这里改用表面阶梯表达层级。
      proxyDecorator: (child, index, animation) => Material(
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHigh,
        child: child,
      ),
      // `onReorderItem` 已由框架做掉「移除一项后下标左移」的 -1 调整，直接插入即可。
      onReorderItem: (oldIndex, newIndex) {
        setState(() {
          final moved = _order.removeAt(oldIndex);
          _order.insert(newIndex, moved);
        });
        _persistOrder();
      },
      itemBuilder: (context, index) {
        final key = _order[index];
        final item = _byKey[key];
        if (item == null) {
          return SizedBox.shrink(key: ValueKey('site-sort-$key'));
        }
        return ListTile(
          key: ValueKey('site-sort-row-$key'),
          dense: true,
          title: Text(
            item.site.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: _blocked.contains(key) ? const Text('已屏蔽') : null,
          trailing: ReorderableDragStartListener(
            index: index,
            child: const Icon(Icons.drag_handle, size: 18),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _visible;
    final groups = _groups;
    final canSort = widget.onReorder != null;

    final ink = glassSecondaryInkOf(theme);
    final dialogTheme = DialogTheme.of(context);
    final actionStyle = TextButton.styleFrom(foregroundColor: ink);
    final title = _sorting
        ? '站点顺序'
        : _blockedEditing
        ? '管理屏蔽站点'
        : '选择站点';
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_sorting)
          Text(
            '拖动右侧手柄调整顺序，改动自动保存（共 ${_order.length} 个站点）',
            style: theme.textTheme.bodySmall?.copyWith(color: ink),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: TextField(
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
              ),
              if (canSort) ...[
                const SizedBox(width: AppSpace.xs),
                IconButton(
                  key: const ValueKey('site-sort-toggle'),
                  tooltip: '手动排序',
                  icon: const Icon(Icons.swap_vert),
                  onPressed: _toggleSorting,
                ),
              ],
              if (widget.onBlockedChanged != null)
                IconButton(
                  key: const ValueKey('site-block-toggle'),
                  tooltip: _blockedEditing ? '退出屏蔽管理' : '管理屏蔽站点',
                  isSelected: _blockedEditing,
                  icon: Icon(
                    _blockedEditing
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: _toggleBlockedEditing,
                ),
            ],
          ),
          if (groups.isNotEmpty) ...[
            const SizedBox(height: 10),
            // 分组 chip 行：横向可滚，命中关键字时只列出现存的分组。
            SizedBox(
              height: 34,
              child: HorizontalMouseDrag(
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
            ),
          ],
          const SizedBox(height: 8),
        ],
        Expanded(
          child: _sorting
              ? _sortPanel(context)
              : items.isEmpty
              ? Center(
                  child: Text(
                    _emptyHint(),
                    style: theme.textTheme.bodyMedium?.copyWith(color: ink),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) => GridView.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      // 窄窗保留站点名称和状态标记的可用宽度。
                      crossAxisCount: constraints.maxWidth < 400 ? 1 : 2,
                      mainAxisExtent: 48,
                      crossAxisSpacing: 8,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) =>
                        _siteRow(context, items[index]),
                  ),
                ),
        ),
      ],
    );
    final actions = <Widget>[
      if (_sorting)
        TextButton(
          key: const ValueKey('site-sort-reset'),
          style: actionStyle,
          onPressed: _resetOrder,
          child: const Text('恢复默认'),
        ),
      TextButton(
        style: actionStyle,
        // 排序模式只退出模式，不关对话框：关闭对话框会把用户刚排好的列表一起
        // 藏起来，想接着选站点还得重新打开一次（单向门）。
        onPressed: _sorting
            ? () => setState(() => _sorting = false)
            : () => Navigator.of(context).pop(),
        child: Text(_sorting ? '完成排序' : '关闭'),
      ),
    ];
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      semanticsRole: SemanticsRole.alertDialog,
      child: GlassSurface(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Theme(
          data: theme.copyWith(
            colorScheme: theme.colorScheme.copyWith(onSurfaceVariant: ink),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: 760,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    namesRoute: true,
                    child: Text(
                      title,
                      style:
                          dialogTheme.titleTextStyle ??
                          (theme.useMaterial3
                              ? theme.textTheme.headlineSmall
                              : theme.textTheme.titleLarge),
                    ),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  // Give the lazy grid a finite height before it lays out.
                  Flexible(child: SizedBox(height: 560, child: content)),
                  const SizedBox(height: AppSpace.xl),
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: AppSpace.sm,
                    children: actions,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
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
    return TagChip(
      label: label,
      selected: selected,
      onTap: onTap,
      // 站点分组同样是可选控件：禁用时保留选中态。
      selectable: true,
    );
  }
}

/// 供各页面复用：键盘快捷键帮助（§17.4 支持键盘导航）。
const List<(String, String)> playerShortcuts = [
  ('空格', '播放 / 暂停'),
  ('← / →', '后退 / 前进 10 秒'),
  ('Ctrl+Shift+← / →', '前一个 / 后一个关键帧（点播且时长已知）'),
  ('↑ / ↓', '音量 +5 / -5'),
  ('M', '静音切换'),
  ('[ / ]', '上一集 / 下一集'),
  ('Alt + [ / ]', '跳过片头 / 片尾'),
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
  VoidCallback? previousKeyframe,
  VoidCallback? nextKeyframe,
}) {
  return {
    const SingleActivator(LogicalKeyboardKey.space): togglePlay,
    const SingleActivator(LogicalKeyboardKey.arrowLeft): seekBackward,
    const SingleActivator(LogicalKeyboardKey.arrowRight): seekForward,
    const SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      control: true,
      shift: true,
    ): ?previousKeyframe,
    const SingleActivator(
      LogicalKeyboardKey.arrowRight,
      control: true,
      shift: true,
    ): ?nextKeyframe,
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
