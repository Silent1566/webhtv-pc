/// 应用外壳：启动页、侧栏导航与页面路由（§17.1、§17.2、§17.4）。
///
/// 桌面 UI 要求：键盘导航、鼠标拖拽、窗口缩放、深色模式、中文优先、可国际化、
/// 不使用移动端竖屏布局。因此这里固定为「顶栏 + 侧栏 + 内容区」的桌面布局。
library;

import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

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
import '../services/last_config_store.dart';
import '../services/log_service.dart';
import '../services/session_recovery_store.dart';
import '../services/startup_trace.dart';
import '../services/storage.dart';
import '../state/app_state.dart';
import 'app_motion.dart';
import 'browse_pages.dart';
import 'common.dart';
import 'config_pages.dart';
import 'diagnostics_pages.dart';
import 'following_calendar_page.dart';
import 'following_page.dart';
import 'image_header_scope.dart';
import 'library_pages.dart';
import 'live_page.dart';
import 'playback_resume.dart';
import 'recovery_banner.dart';
import 'player_page.dart';
import 'scroll_behavior.dart';
import 'search_page.dart';
import 'spider_page.dart';
import 'theme.dart';
import 'toast.dart';
import 'tokens.dart';

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
  // 图片请求的 User-Agent 必须**在客户端层**替换（见 `core/image_user_agent.dart`）：
  // `Image.network(headers:)` 走的是 `request.headers.add()`，而 `dart:io` 默认已经
  // 有 `Dart/x.y (dart:io)`，add 的结果是两个值拼成一条
  // `Dart/3.13 (dart:io), WebHTV-PC/0.1 (Windows)`——豆瓣的 EdgeOne 照样 418。
  // 只有 `HttpClient.userAgent`（客户端级、`set` 语义）才能真正替换它；
  // 实测同一 URL：add UA → 418，HttpOverrides UA → 200。
  installImageUserAgent();
  WidgetsFlutterBinding.ensureInitialized();
  StartupTrace.mark('binding');
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
    SessionRecoveryStore.appendCrashForPaths(paths ?? AppPaths.resolve(), entry);
  } catch (_) {}
}

class WebHtvApp extends StatefulWidget {
  const WebHtvApp({super.key, this.startup = const StartupArguments()});

  final StartupArguments startup;

  @override
  State<WebHtvApp> createState() => _WebHtvAppState();
}

class _WebHtvAppState extends State<WebHtvApp> with WindowListener {
  final AppState _state = AppState();
  bool _bootstrapped = false;

  @override
  void initState() {
    super.initState();
    // 窗口关闭时标记「正常退出」（崩溃恢复靠它区分强杀）。
    windowManager.addListener(this);
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
    windowManager.removeListener(this);
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
      // （它自己 `addListener`）重建，本 State **没有**监听 `_state`；不监听的话
      // 配置导入后 builder 不会重跑，规则永远是空表，图片依旧 418。
      // 代价可控：`child` 是 MaterialApp 传下来的同一个 Widget 实例，
      // Flutter 对同一实例会跳过子树重建。
      builder: (context, child) => ListenableBuilder(
        listenable: _state,
        builder: (context, _) => ImageHeaderScope(
          rules: _state.effectiveConfig?.headers ?? const <HeaderRule>[],
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
enum ShellSection {
  browse,
  live,
  search,
  history,
  favorites,
  following,
  calendar,
  spiders,
  settings,
  logs,
}

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

  /// 桥接源恢复失败的横幅状态（`null` = 不显示）。
  BridgeRestoreFailure? _bridgeBanner;

  /// 横幅对应的那条记忆。
  ///
  /// 没有 last-config.json 时横幅来自兜底推断的记忆，而 lastConfigRecord 是
  /// null——「重试」必须沿用它，否则按钮点了没反应。
  LastConfigRecord? _bannerMemory;

  /// 「重试」进行中：按钮置忙，避免连点触发重复探测。
  bool _restoringBridge = false;

  /// 两条横幅通道上一次"已经推成通知"的值。
  ///
  /// 状态层是唯一事实来源，通知只是它的投影：拿上一次投影过的值做对比，
  /// 只在值**变成另一个非 null 值**时推一条，因此状态不变时不会重复弹。
  ///
  /// `detailError` 不在这里：它的动作（「换源」）是详情页的私有方法，只能由
  /// `_DetailPageState` 自己投影——见 `browse_pages.dart` 的 `_syncDetailErrorToast`。
  AppError? _shownLastError;
  String? _shownNotice;

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
  }

  AppState get _state => widget.state;

  void _onStateChanged() {
    _syncToasts();
    _syncFollowingOpenRequest();
    if (mounted) setState(() {});
    _maybeAutoPlayMedia();
  }

  /// 系统通知被点击时把侧栏切到「追番」页。
  ///
  /// **只切页，不清 `followingOpenRequest`**：真正的消费方是 `FollowingPage`
  /// （`_consumeOpenRequest` 取到身份键后打开最新集，再原子地清空）。壳层要是
  /// 提前清掉，追番页拿不到 key，点通知就只跳到列表、不打开那一集。
  /// 只判「当前是否已在追番页」而不记历史值：清空不触发 notify，记历史值会让
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
          detail: '错误码：${lastError.kind.name}'
              '${lastError.retryable ? " · 可重试" : ""}',
          onDismiss: _state.clearError,
        );
      }
    }
    final notice = _state.notice;
    if (notice != _shownNotice) {
      _shownNotice = notice;
      if (notice != null) {
        showToast(notice, kind: ToastKind.info, onDismiss: _state.clearNotice);
      }
    }
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
      setState(() => _section = ShellSection.browse);
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

  /// 探测 + 重新导入 + 精确激活一条桥接源；失败时置横幅状态。
  Future<void> _tryRestoreBridge(String address, LastConfigRecord memory) async {
    final sync = _state.syncState;
    final device = await sync.probeAutoConnectTarget(address);
    if (!mounted) return;
    if (device == null) {
      _showBridgeBanner(
        memory,
        address: address,
        deviceName: _state.lastConfigDevice?.name ??
            _state.deviceNameForUuid(memory.deviceUuid),
        error: sync.lastError ??
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
        error: sync.lastError ??
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
      _section = ShellSection.browse;
      _bridgeBanner = null;
      _bannerMemory = null;
    });
    _state.log.info(
      '已恢复上次使用的桥接配置（${memory.sourceKey}）',
      scope: 'bridge',
    );
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

  /// 顶栏「配置：xxx」的点击：**换配置**，不是管理配置。
  ///
  /// 用户点这几个字的意图几乎总是「我要用另一个源」（用户反馈 2026-11-05）。
  /// 原来它直接冲进配置管理页，而那一页首屏是一大块导入表单，换配置的列表
  /// 被压到下面——想做最常做的事，反而要先在管理页里找到列表。
  ///
  /// 只有一条配置时没有可换的东西，直接进管理页（那里才有「导入」）。
  Future<void> _openConfigSwitcher() async {
    if (_state.savedConfigs.length <= 1) {
      await _openConfigPage();
      return;
    }
    final targetId = await showDialog<int>(
      context: context,
      builder: (_) => ConfigSwitcherDialog(
        records: _state.savedConfigs,
        activeId: _state.activeRecord?.id,
      ),
    );
    if (targetId == null || !mounted) return;
    if (targetId == _state.activeRecord?.id) return;
    await _state.activateConfigRecord(targetId);
    if (mounted) setState(() {});
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
        rules: _state.siteGroupSettings.enabledRules,
        // 把"当前站点"传进去：换源对话框必须能标出你现在在哪个源上。
        selectedKey: _state.selectedSite?.key,
      ),
    );
    if (selected != null) {
      _section = ShellSection.browse;
      await _state.selectSite(selected);
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
      builder: (context) => AlertDialog(
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

    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            state: _state,
            onOpenConfig: _openConfigSwitcher,
            onManageConfig: _openConfigPage,
            onOpenSitePicker: _openSitePicker,
          ),
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
          if (_state.pendingRecovery != null)
            RecoveryBanner(
              marker: _state.pendingRecovery!,
              hasCrashLog: _state.recoveryCrashLog != null,
              onResume: _resumeRecovered,
              onShowLog: _showCrashLog,
              onDismiss: () => _state.dismissRecovery(),
            ),
          Expanded(
            child: Row(
              children: [
                _SideBar(
                  section: _section,
                  updateCount: _state.followingUpdateCount,
                  onSelect: (value) => setState(() => _section = value),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _WallpaperBackdrop(
                    url: _state.config?.wallpaper,
                    child: AppShellTransition(
                      sectionIndex: _section.index,
                      child: _buildContent(),
                    ),
                  ),
                ),
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
      case ShellSection.following:
        return FollowingPage(state: _state);
      case ShellSection.calendar:
        return FollowingCalendarPage(state: _state);
      case ShellSection.spiders:
        return SpiderPage(state: _state);
      case ShellSection.settings:
        return SettingsPage(state: _state);
      case ShellSection.logs:
        return LogsPage(state: _state);
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
          Icon(Icons.folder_off_outlined, size: 18, color: scheme.onErrorContainer),
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
    required this.onOpenConfig,
    required this.onManageConfig,
    required this.onOpenSitePicker,
  });

  final AppState state;
  final VoidCallback onOpenConfig;
  final VoidCallback onManageConfig;
  final VoidCallback onOpenSitePicker;

  @override
  Widget build(BuildContext context) {
    final site = state.selectedSite;
    final record = state.activeRecord;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
      decoration: BoxDecoration(
        // 顶栏是世界的"外壳"：比内容低一档的表面，靠发丝线分隔。
        color: scheme.surfaceContainerLowest,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.55)),
        ),
      ),
      child: Row(
        children: [
          _BrandMark(logo: state.config?.logo),
          const SizedBox(width: AppSpace.md),
          Text('WebHTV', style: theme.textTheme.titleMedium),
          const SizedBox(width: AppSpace.xl),
          // 配置名可能很长，顶栏不能被它挤爆：限宽 + 省略号，
          // 完整名字走 Tooltip。
          ConstrainedBox(
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
          // 管理（导入/编辑/刷新/删除）与换配置分开两个入口：前者低频且是
          // 「维护」心智，后者高频且是「使用」心智，混在一个按钮里必然有一方
          // 被埋（用户反馈 2026-11-05）。
          //
          // 这里**必须带文字**：初版只放了一个无标签图标，用户截图反馈
          // 「不太明显」——纯图标在顶栏一排字形中间分不出它是入口还是装饰。
          TextButton.icon(
            key: const ValueKey('topbar-manage-config'),
            onPressed: onManageConfig,
            icon: const Icon(Icons.settings_ethernet, size: 18),
            label: const Text('管理'),
          ),
          const SizedBox(width: AppSpace.xs),
          TextButton.icon(
            onPressed: state.siteItems.isEmpty ? null : onOpenSitePicker,
            icon: const Icon(Icons.dns_outlined, size: 18),
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

/// 配置壁纸背景 + 一层纱。
///
/// 用户确认「配置提供的 `wallpaper` 必须真的生效」。但壁纸是**任意图片**，
/// 深浅不可预知，而内容必须始终可读——所以壁纸之上永远有一层由底色染出的纱，
/// 它的不透明度是设计决定，不是图片的属性。
///
/// 只铺在内容区：顶栏与侧栏保持实底，保证导航在任何壁纸上都清晰。
class _WallpaperBackdrop extends StatelessWidget {
  const _WallpaperBackdrop({required this.url, required this.child});

  final String? url;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final target = url?.trim() ?? '';
    if (target.isEmpty) return child;
    final semantic = context.semanticColors;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          target,
          fit: BoxFit.cover,
          // 壁纸同样是外部图片：按 host 注入顶层 `headers` 规则。
          headers: imageHeadersOrNull(context, target),
          // 取不到壁纸时安静退回纯底色：它只是背景。
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : const SizedBox.shrink(),
        ),
        ColoredBox(color: semantic.wallpaperVeil),
        child,
      ],
    );
  }
}

class _SideBar extends StatelessWidget {
  const _SideBar({
    required this.section,
    required this.onSelect,
    this.updateCount = 0,
  });

  final ShellSection section;
  final ValueChanged<ShellSection> onSelect;
  final int updateCount;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      selectedIndex: section.index,
      onDestinationSelected: (index) => onSelect(ShellSection.values[index]),
      minWidth: 76,
      groupAlignment: -0.9,
      labelType: NavigationRailLabelType.all,
      destinations: [
        const NavigationRailDestination(
          icon: Icon(Icons.grid_view),
          label: Text('首页'),
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
        NavigationRailDestination(
          icon: Badge(
            isLabelVisible: updateCount > 0,
            label: Text('$updateCount'),
            child: const Icon(Icons.star_border),
          ),
          label: const Text('追番'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.calendar_month),
          label: Text('追剧日历'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.extension),
          label: Text('Spider'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.tune),
          label: Text('设置'),
        ),
        const NavigationRailDestination(
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
  const SitePickerDialog({
    super.key,
    required this.items,
    required this.log,
    this.selectedKey,
    this.rules = builtinSiteGroupRules,
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
        'groups=${siteGroupsOf(site.name, rules: widget.rules).join("|")} '
        'reason=${availability.reason ?? "-"}',
        scope: 'site',
      );
    }
  }

  /// 当前可见的分组（按站点顺序去重，只统计当前关键字命中的站点）。
  List<String> get _groups {
    final seen = <String>[];
    for (final item in _keywordMatched) {
      for (final group in siteGroupsOf(item.site.name, rules: widget.rules)) {
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

  /// 单个站点行（两列网格里的一格）。
  ///
  /// 抽成方法而不是内联在 `itemBuilder` 里：两列网格与单列列表共用同一套行渲染，
  /// 也便于单独读这一行的语义（状态色 / 当前标记 / 可搜索标记）。
  Widget _siteRow(BuildContext context, SiteListItem item) {
    final theme = Theme.of(context);
    final availability = item.availability;
    final available = availability.available;
    final isCurrent =
        widget.selectedKey != null && item.site.key == widget.selectedKey;
    final semantic = context.semanticColors;
    return ListTile(
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
      title: Text(item.site.name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
      enabled: available,
      onTap: available ? () => Navigator.of(context).pop(item.site) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _visible;
    final groups = _groups;

    return AlertDialog(
      title: const Text('选择站点'),
      content: SizedBox(
        // 宽一点、高一点：站点数实测可达 170+。
        //
        // 原来 640x480 + 每行约 54px，一屏只看得见 7 个站点，找第 100 个要滚很久，
        // 而对话框右侧又空着一大片（截图复核时发现，2026-10-11）。
        // 桌面端对话框没有移动端那种宽度压力，用两列排布把滚动距离砍半。
        width: 760,
        height: 560,
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
                  : GridView.builder(
                      // **两列**排布：站点数实测可达 170+，单列一屏只看得到 7 个。
                      // 对话框有 760px 宽，单列时右半边整片空着——两列把滚动距离
                      // 砍半，也让"扫一眼找站点"成为可能（截图复核时发现，2026-10-11）。
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisExtent: 48,
                            crossAxisSpacing: 8,
                          ),
                      itemCount: items.length,
                      itemBuilder: (context, index) =>
                          _siteRow(context, items[index]),
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
    this.alignment = Alignment.center,
    this.cacheWidth,
    this.background = true,
  });

  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// `BoxFit.cover` 裁切时保留图片的哪一块，默认居中。
  ///
  /// 只转发给 `Image.network` 的同名参数——**不会**引入外层 `Align`
  /// （见 [build] 里那条「绝不能给 Container 加 alignment」的注释），
  /// 因此不影响 cover 的铺满语义。
  ///
  /// 详情页背景轮播传 `Alignment.topCenter`：窗口比素材更高时（全屏 2.35:1
  /// 对 16:9 素材）cover 会纵向裁掉约 24%，居中裁等于上下各切一半，人物头顶
  /// 常被切到；改成顶部对齐后裁切全部落在底部——底部本来就被渐变遮罩压暗、
  /// 被标题/简介盖住，观感损失最小（用户反馈 2026-10-23：「同一个海报背景
  /// 全屏的时候被截取了不好看」）。
  final Alignment alignment;

  /// 解码宽度上限（转发给 `Image.network` 的 `cacheWidth`）。
  ///
  /// 给**已经确定会被放大/糊掉**的用途用（如详情页背景的模糊垫底层）：
  /// 那种层看不出细节，按满宽解码只是白白吃内存与解码时间
  /// （TMDB `w1280` 后景约 121KB，`original` 约 983KB）。
  final int? cacheWidth;

  /// 是否绘制占位底色，默认 `true`（普通图位需要它兜住"图还没到"的状态）。
  ///
  /// **叠层背景的上层必须传 `false`。** 这个底色是**不透明**的，而且这里的
  /// `Container` 会撑满父级给的紧约束——放在 `Stack` 里就会把下层的模糊垫底
  /// **整块盖住**。实测（2026-10-13）：详情页背景的"模糊延伸"因此**从来没有
  /// 渲染过**，屏幕上只有一块纯色信箱边加一个硬边图片，用户看到的就是这个
  /// （「怎么变得这么丑了」）。单元测试只断言了 `fit`，断言不到"谁盖住了谁"，
  /// 所以全绿也没拦住它。
  final bool background;

  @override
  Widget build(BuildContext context) {
    final target = url?.trim() ?? '';
    // 图片请求也要按目标 host 注入顶层 `headers` 规则（§7.4.6）：豆瓣图床这类
    // 防盗链站点不带 `Referer` 直接返回 418，而 `Image.network` 默认连 UA 都不带
    // （`dart:io` 的 `Dart/x.y (dart:io)` 同样被边缘节点拦掉，见 `core/image_headers.dart`）。
    //
    // 没有作用域时（单测直接 pump）返回 null，与改造前行为完全一致。
    final headers = imageHeadersOrNull(context, target);
    // 底层永远是占位底色 + 图标，图片叠在上面。
    //
    // 为什么不能只靠 `loadingBuilder` 兜底（实测 2026-10-09，网盘聚合站慢图床）：
    // 慢速图床在**首帧产出之前**会走到 `progress == null` 分支，此时 `child` 是
    // 一个还没有图像的 `RawImage`（什么都不画），而占位符已经被跳过——结果整个
    // 格子与页面同色，看上去像「少了一部片」，实测要等 25s 图才出现。
    // 把占位符当底而不是当分支，就不存在“两个分支都画空”的窗口。
    //
    // **绝不能给这个 Container 加 `alignment`**（2026-10-10 实测根因）：
    // `Container(alignment:)` 会在子节点外包一层 `Align`，而 `Align` 给子节点的是
    // **松约束**；`Image` 在松约束且未给 width/height 时会退回**图片固有尺寸**，
    // 于是 `BoxFit.cover` 根本没有“盒子”可以铺——背景图与人物头像就变成
    // 「按原始尺寸居中、两侧露底色」（用户反馈「都没铺满」的真实根因）。
    // 去掉 alignment 后子节点拿到父级传入的**紧约束**，cover 才真正生效。
    // 占位图标需要居中，各自用 `Center` 包。
    return Container(
      width: width,
      height: height,
      color: background ? _posterPlaceholderColor(context) : null,
      child: target.isEmpty
          ? Center(child: _placeholderIcon(context))
          : Image.network(
              target,
              width: width,
              height: height,
              fit: fit,
              alignment: alignment,
              cacheWidth: cacheWidth,
              headers: headers,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : Center(child: _placeholderIcon(context, loading: true)),
              errorBuilder: (context, error, stackTrace) =>
                  Center(child: _placeholderIcon(context)),
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
