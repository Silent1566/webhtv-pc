/// 用系统 Chromium 内核浏览器执行解析页嗅探（§12.1 `type=0` / `type=4`）。
///
/// 为什么不是 WebView2：桌面三平台都需要同一套语义，而 WebView2 只存在于
/// Windows，且没有顶层导航 Header 注入与 Cookie 管理。走 CDP 可以同时得到
/// 「真实 Chromium」「网络请求可见」「请求头可注入」，且不新增任何原生依赖。
///
/// 与安卓 `CustomWebView` 的对应：
/// - `shouldInterceptRequest` → `Network.requestWillBeSent`；
/// - `loadUrl(url, headers)` → `setExtraHTTPHeaders` + `setUserAgentOverride`
///   + `setCookie`；
/// - `onPageFinished` 注入 `Sniffer.getScript`/`click` → `Runtime.evaluate`；
/// - `probeDomMedia` → `performance.getEntriesByType('resource')` 轮询；
/// - `WebDialog`（人机校验）→ `Browser.setWindowBounds` 把离屏窗口拉回可见。
///
/// 超时由调用方（`ParseService`）拥有；本类只保留一个兜底计时器，保证不会
/// 因为调用方遗漏 `stop()` 而泄漏浏览器进程。
library;

import 'dart:async';
import 'dart:io';

import 'sniff_transport.dart';
import 'sniff_types.dart';

/// CDP 嗅探引擎。
class ChromiumSniffEngine implements SniffEngine {
  ChromiumSniffEngine({
    required this.transport,
    this.command,
    this.headed,
  });

  /// 传输实现（默认是 `DefaultSniffTransport`，测试可注入假实现）。
  final SniffTransport transport;

  /// 指定浏览器可执行文件；`null` = 按平台自动定位。
  final BrowserCommand? command;

  /// `null` = 有图形会话时用离屏可见窗口，否则 `--headless=new`。
  final bool? headed;

  bool _disposed = false;

  @override
  Future<SniffSession> start(SniffRequest request) async {
    if (_disposed) {
      throw const SniffException('嗅探引擎已释放', detail: 'start() 在 dispose() 之后被调用');
    }
    final candidates = command != null
        ? <BrowserCommand>[command!]
        : await transport.locateAll();
    if (candidates.isEmpty) {
      throw const SniffUnavailableException(
        '没有找到可用的浏览器内核，无法执行 Web 嗅探',
        detail: '需要本机安装 Microsoft Edge / Google Chrome / Chromium；'
            '也可用环境变量 WEBHTV_SNIFF_BROWSER 指定可执行文件',
      );
    }

    // 逐个候选试：本机可能装着"存在但跑不起来"的浏览器（snap 包装脚本在受限
    // 环境里 snap-confine 直接失败、坏软链、架构不匹配的内核）。只认第一个候选
    // 会让一个坏包装把整机可用的 Chrome/Edge 挡住。
    final visible = headed ?? preferVisibleWindow;
    final failures = <String>[];
    for (final candidate in candidates) {
      final issue = await transport.probe(candidate);
      if (issue != null) {
        failures.add('${candidate.executablePath}：$issue');
        continue;
      }
      BrowserSession? browser;
      CdpConnection? connection;
      try {
        browser = await transport.launch(
          candidate,
          headless: !visible,
          readyTimeout: const Duration(seconds: 20),
          width: WindowBounds.offscreen.width,
          height: WindowBounds.offscreen.height,
        );
        connection = await transport.connect(
          browser.webSocketUrl,
          timeout: const Duration(seconds: 10),
        );
      } on Object catch (error) {
        await connection?.close();
        connection = null;
        await browser?.close();
        browser = null;
        failures.add('${candidate.label}（${candidate.executablePath}）：$error');
        continue;
      }
      final session = ChromiumSniffSession(
        command: candidate,
        request: request,
        headed: visible,
        moveOffscreen: visible,
        browser: browser,
        connection: connection,
      );
      await session.open();
      return session;
    }
    // 文案分两层：message 一句话说「缺什么」（进日志/提示的主行），detail 逐个
    // 候选给真实原因 + 一条能照做的处置——用户看不到原因就只能猜。
    final detail = failures.join(' ；');
    final snap = detail.contains('snap-confine');
    throw SniffUnavailableException(
      snap
          ? '本机浏览器都不可用（Chromium 是 snap 版，当前环境无法启动）'
          : '找到的浏览器都不可用，无法执行 Web 嗅探',
      detail:
          '$detail ；处理=${snap ? '安装非 snap 版 Chrome/Chromium，' : '安装 Microsoft Edge / Google Chrome / Chromium，'}'
          '或用 WEBHTV_SNIFF_BROWSER 指定浏览器可执行文件',
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
  }

  /// 默认用**无头模式**：嗅探不该弹出窗口（哪怕是移出屏幕的窗口）。
  ///
  /// 可见窗口的唯一价值，是人机校验时能把窗口亮给用户。
  static bool get preferVisibleWindow =>
      Platform.environment[sniffHeadedEnvKey] == '1' && displayAvailable;

  /// 打开可见窗口模式的环境变量（值 `1`）；设置项接入前由它承担开关。
  static const String sniffHeadedEnvKey = 'WEBHTV_SNIFF_HEADED';

  /// 有图形会话才可能有可见窗口；纯无显示环境只能无头。
  static bool get displayAvailable {
    if (Platform.isWindows || Platform.isMacOS) return true;
    final environment = Platform.environment;
    return (environment['DISPLAY'] ?? '').isNotEmpty ||
        (environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
  }
}

/// 窗口矩形（CDP `Browser.Bounds`）。
class WindowBounds {
  const WindowBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 把窗口挪到任何屏幕之外：页面按真实窗口运行，用户看不到。
  static const offscreen = WindowBounds(
    left: -32000,
    top: -32000,
    width: 960,
    height: 720,
  );

  /// 人机校验时拉回可见的位置。
  static const visible = WindowBounds(left: 120, top: 80, width: 960, height: 720);

  final int left;
  final int top;
  final int width;
  final int height;

  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
    'windowState': 'normal',
  };
}

/// 一次进行中的 CDP 嗅探。
class ChromiumSniffSession implements SniffSession {
  ChromiumSniffSession({
    required this.command,
    required this.request,
    required this.headed,
    required this.moveOffscreen,
    required BrowserSession browser,
    required CdpConnection connection,
  }) {
    _browser = browser;
    _connection = connection;
  }

  final BrowserCommand command;
  final SniffRequest request;
  final bool headed;
  final bool moveOffscreen;

  final StreamController<SniffEvent> _controller =
      StreamController<SniffEvent>.broadcast();
  final List<SniffEvent> _pending = [];
  final Completer<void> _closed = Completer<void>();

  StreamSubscription<CdpEvent>? _subscription;
  BrowserSession? _browser;
  CdpConnection? _connection;
  Timer? _deadline;
  Timer? _probeTimer;
  String _targetId = '';
  String? _sessionId;
  int? _windowId;
  bool _finished = false;
  bool _stopping = false;
  bool _closeWhenListened = false;
  bool _retriedNavigation = false;
  String? _referrer;
  int _probeAttempts = 0;

  /// 主文档请求：`requestId -> url`，用于把 `Network.loadingFailed` 归因到导航本身。
  final Map<String, String> _documentRequests = {};

  /// 首个订阅者到达：重放缓冲事件；若嗅探已结束，重放后立刻关闭。
  void _onListen() {
    if (_controller.isClosed) return;
    _flushPending();
    if (_closeWhenListened) unawaited(_controller.close());
  }

  void _flushPending() {
    if (_pending.isEmpty) return;
    final buffered = List<SniffEvent>.from(_pending);
    _pending.clear();
    for (final event in buffered) {
      _controller.add(event);
    }
  }

  @override
  Stream<SniffEvent> get events => _controller.stream;

  Future<void> open() async {
    // 事件可能早于订阅到达（chrome 一启动就会发请求），先缓冲、订阅时重放。
    _controller.onListen = _onListen;
    try {
      final connection = _connection!;
      _subscription = connection.events.listen(
        _onEvent,
        onError: (Object _) {},
      );

      _targetId = await _createTarget(connection);
      await _attach(connection);
      await _call('Network.enable');
      await _call('Page.enable');
      await _call('Runtime.enable');
      await _call('Network.setCacheDisabled', {'cacheDisabled': true});
      _referrer = await _applyHeaders();
      if (moveOffscreen) unawaited(_moveWindow(WindowBounds.offscreen));

      _deadline = Timer(
        request.timeout + const Duration(seconds: 2),
        () => _fail('嗅探超时（${request.timeout.inSeconds}s）'),
      );

      await _navigate();
    } catch (error) {
      await stop();
      if (error is SniffUnavailableException || error is SniffException) {
        rethrow;
      }
      throw SniffException('浏览器嗅探启动失败', detail: '$error');
    }
  }

  Future<String> _createTarget(CdpConnection connection) async {
    final target = await connection.send('Target.createTarget', params: {
      'url': 'about:blank',
    });
    final targetId = '${target['targetId'] ?? ''}';
    if (targetId.isEmpty) {
      throw const SniffException(
        '浏览器没有创建页面',
        detail: 'Target.createTarget 未返回 targetId',
      );
    }
    return targetId;
  }

  Future<void> _attach(CdpConnection connection) async {
    final attached = await connection.send('Target.attachToTarget', params: {
      'targetId': _targetId,
      'flatten': true,
    });
    final sessionId = '${attached['sessionId'] ?? ''}';
    if (sessionId.isEmpty) {
      throw const SniffException(
        '无法附着到页面',
        detail: 'Target.attachToTarget 未返回 sessionId',
      );
    }
    _sessionId = sessionId;
  }

  /// 把解析器 `ext.header` 落到浏览器上，返回要用作页面 Referer 的值。
  ///
  /// 三条约束都来自真实浏览器行为，不是洁癖：
  /// 1. UA 只能走 `setUserAgentOverride`（改 Header 不生效）；
  /// 2. Cookie 走 `setCookie`，否则页面脚本读不到，导航也带不上；
  /// 3. **Referer/Origin 跨 scheme 不能走 `setExtraHTTPHeaders`**：http 解析页 + https
  ///    Referer 会被 Chromium 以 `net::ERR_BLOCKED_BY_CLIENT` 拦掉，连页面都不加载
  ///    （表现为嗅探超时，而不是可诊断的错误）。跨 scheme 时只通过 `Page.navigate`
  ///    的 `referrer` 传递，由浏览器的 referrer policy 决定是否降级。
  Future<String?> _applyHeaders() async {
    final headers = request.headers;
    if (headers.isEmpty) return null;
    String? userAgent;
    String? cookie;
    String? referrer;
    final extra = <String, String>{};
    for (final entry in headers.entries) {
      final lower = entry.key.toLowerCase();
      if (lower == 'user-agent') {
        userAgent = entry.value;
      } else if (lower == 'cookie') {
        cookie = entry.value;
      } else if (lower == 'referer') {
        referrer = entry.value;
        if (_sameSchemeAsPage(entry.value)) extra['Referer'] = entry.value;
      } else if (lower == 'origin') {
        if (_sameSchemeAsPage(entry.value)) extra[entry.key] = entry.value;
      } else {
        extra[entry.key] = entry.value;
      }
    }
    if (userAgent != null && userAgent.isNotEmpty) {
      await _call('Network.setUserAgentOverride', {
        'userAgent': userAgent,
        'acceptLanguage': 'zh-CN,zh;q=0.9',
      });
    }
    if (extra.isNotEmpty) {
      await _call('Network.setExtraHTTPHeaders', {'headers': extra});
    }
    if (cookie != null && cookie.isNotEmpty) {
      for (final pair in cookie.split(';')) {
        final index = pair.indexOf('=');
        if (index <= 0) continue;
        await _call('Network.setCookie', {
          'name': pair.substring(0, index).trim(),
          'value': pair.substring(index + 1).trim(),
          'url': _originOf(request.pageUrl),
        });
      }
    }
    return referrer;
  }

  /// 页面的 `Page.navigate`（Referer 走协议参数，不混进全局 Header）。
  Future<void> _navigate() async {
    final params = <String, Object?>{'url': request.pageUrl};
    final referrer = _referrer;
    if (referrer != null && referrer.isNotEmpty) params['referrer'] = referrer;
    await _call('Page.navigate', params);
  }

  bool _sameSchemeAsPage(String candidate) {
    final pageScheme = Uri.tryParse(request.pageUrl)?.scheme.toLowerCase() ?? '';
    final candidateScheme = Uri.tryParse(candidate)?.scheme.toLowerCase() ?? '';
    if (pageScheme.isEmpty || candidateScheme.isEmpty) return true;
    return pageScheme == candidateScheme;
  }

  Future<Map<String, Object?>> _call(
    String method, [
    Map<String, Object?>? params,
  ]) => _connection!.send(
    method,
    params: params,
    sessionId: _sessionId,
    timeout: const Duration(seconds: 15),
  );

  void _onEvent(CdpEvent event) {
    if (_finished) return;
    switch (event.method) {
      case 'Network.requestWillBeSent':
        final raw = event.params['request'];
        if (raw is! Map) return;
        final url = '${raw['url'] ?? ''}';
        if ('${event.params['type'] ?? ''}' == 'Document') {
          _documentRequests['${event.params['requestId'] ?? ''}'] = url;
        }
        _inspectMedia(url, _headersOf(raw['headers']));
      case 'Network.loadingFailed':
        _onLoadingFailed(event.params);
      case 'Network.responseReceived':
        final raw = event.params['response'];
        if (raw is! Map) return;
        _inspectMedia('${raw['url'] ?? ''}', const {});
      case 'Page.loadEventFired':
        _onPageLoaded();
      case 'Inspector.targetCrashed':
        _fail('浏览器页面崩溃');
    }
  }

  /// 主文档加载失败：先去掉全局 Header 重试一次（跨 scheme 的 Referer/Origin 会把
  /// 导航直接拦掉），仍然失败就如实报错——不允许退化成「嗅探超时」。
  void _onLoadingFailed(Map<String, Object?> params) {
    if (params['canceled'] == true) return;
    final errorText = '${params['errorText'] ?? ''}';
    if (errorText.isEmpty) return;
    final requestId = '${params['requestId'] ?? ''}';
    if (_documentRequests[requestId] != request.pageUrl) return;
    if (_retriedNavigation) {
      _fail('解析页加载失败', detail: errorText);
      return;
    }
    _retriedNavigation = true;
    unawaited(_retryNavigationWithoutExtraHeaders(errorText));
  }

  Future<void> _retryNavigationWithoutExtraHeaders(String reason) async {
    if (_finished) return;
    try {
      await _call('Network.setExtraHTTPHeaders', {'headers': <String, String>{}});
      await _navigate();
    } catch (_) {
      _fail('解析页加载失败', detail: reason);
    }
  }

  Map<String, String> _headersOf(Object? raw) {
    final result = <String, String>{};
    if (raw is! Map) return result;
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is String) result['${entry.key}'] = value;
    }
    return result;
  }

  void _inspectMedia(String url, Map<String, String> headers) {
    if (_finished || url.isEmpty) return;
    if (url == request.pageUrl) return;
    if (!isSniffMediaUrl(url, rules: request.rules)) return;
    _succeed(url, sniffHeadersOf(headers), 'network');
  }

  void _onPageLoaded() {
    if (_finished) return;
    _emit(SniffPageLoaded(pageUrl: request.pageUrl));
    unawaited(_injectScripts());
    _scheduleProbe();
    unawaited(_detectChallenge());
  }

  Future<void> _injectScripts() async {
    final scripts = <String>[];
    final click = request.clickScript;
    if (click != null && click.trim().isNotEmpty) scripts.add(click);
    final host = Uri.tryParse(request.pageUrl)?.host ?? '';
    for (final rule in request.rules) {
      if (rule.hosts.isEmpty || rule.matchesHost(host)) {
        scripts.addAll(rule.scripts);
      }
    }
    for (final script in scripts) {
      await _evaluate(script);
    }
  }

  /// 页面要求人机校验时不硬闯：把窗口拉回可见交给人（R-G 决策）。
  Future<void> _detectChallenge() async {
    final value = await _evaluate(
      "document.title + ' ' + (document.body ? document.body.innerText.slice(0, 400) : '')",
    );
    final text = '$value'.toLowerCase();
    const markers = [
      'just a moment',
      'attention required',
      'verify you are human',
      'checking your browser',
      '人机验证',
      '请完成验证',
    ];
    for (final marker in markers) {
      if (!text.contains(marker)) continue;
      _emit(SniffChallenge(reason: '页面要求人机校验'));
      if (request.revealWindow) await reveal();
      return;
    }
  }

  /// DOM/performance 补采（对齐安卓 `probeDomMedia`）。
  void _scheduleProbe() {
    _probeTimer?.cancel();
    _probeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_finished) {
        timer.cancel();
        return;
      }
      _probeAttempts++;
      if (_probeAttempts > 6) {
        timer.cancel();
        return;
      }
      unawaited(_probe());
    });
  }

  Future<void> _probe() async {
    final value = await _evaluate(
      "(function(){var out=[];try{document.querySelectorAll('video,audio,video source,audio source')"
      ".forEach(function(v){var u=v.currentSrc||v.src;if(u)out.push(u);});}catch(e){}"
      "try{performance.getEntriesByType('resource').forEach(function(e){"
      "if(e.initiatorType==='video'||e.initiatorType==='audio'||"
      "e.name.indexOf('.m3u8')>=0||e.name.indexOf('.mp4')>=0)out.push(e.name);});}catch(e){}"
      'return out.slice(0,20);})()',
    );
    if (value is! List) return;
    for (final item in value) {
      if (item is! String) continue;
      if (!isSniffMediaUrl(item, rules: request.rules)) continue;
      _succeed(item, const {}, 'dom');
      return;
    }
  }

  /// `Runtime.evaluate` 并取回值；脚本报错不升级为嗅探失败（页面跳转是常态）。
  Future<Object?> _evaluate(String expression) async {
    final connection = _connection;
    final sessionId = _sessionId;
    if (connection == null || sessionId == null) return null;
    try {
      final result = await connection.send(
        'Runtime.evaluate',
        params: {
          'expression': expression,
          'returnByValue': true,
          'awaitPromise': false,
          'userGesture': true,
        },
        sessionId: sessionId,
        timeout: const Duration(seconds: 10),
      );
      final raw = result['result'];
      return raw is Map ? raw['value'] : null;
    } on CdpCallError {
      return null;
    }
  }

  Future<void> _moveWindow(WindowBounds bounds) async {
    final connection = _connection;
    if (connection == null || _targetId.isEmpty) return;
    try {
      final window = await connection.send(
        'Browser.getWindowForTarget',
        params: {'targetId': _targetId},
        timeout: const Duration(seconds: 5),
      );
      final windowId = window['windowId'];
      if (windowId is! num) return;
      _windowId = windowId.toInt();
      await connection.send(
        'Browser.setWindowBounds',
        params: {'windowId': _windowId, 'bounds': bounds.toJson()},
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {
      // headless 没有窗口；嗅探本身不依赖窗口，忽略即可。
    }
  }

  void _succeed(String url, Map<String, String> headers, String via) {
    if (_finished) return;
    _finished = true;
    _emit(SniffCandidate(url: url, headers: headers, via: via));
    unawaited(stop());
  }

  void _fail(String message, {String? detail}) {
    if (_finished) return;
    _finished = true;
    _emit(SniffFailed(message: message, detail: detail));
    unawaited(stop());
  }

  void _emit(SniffEvent event) {
    if (_closed.isCompleted) return;
    if (_controller.hasListener) {
      _controller.add(event);
    } else {
      _pending.add(event);
    }
  }

  @override
  Future<void> click() async {
    await _evaluate(
      "(function(){try{var v=document.querySelector('video,audio');"
      'if(v){v.muted=true;v.play&&v.play();}'
      "var target=document.querySelector('[class*=play],[id*=play],.vjs-big-play-button,[class*=btn]');"
      'if(target&&target.click)target.click();}catch(e){}})()',
    );
  }

  @override
  bool get canReveal => headed;

  @override
  Future<void> reveal() async {
    if (!headed) return;
    await _moveWindow(WindowBounds.visible);
    if (_targetId.isEmpty) return;
    try {
      await _connection?.send(
        'Target.activateTarget',
        params: {'targetId': _targetId},
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    if (_stopping) {
      if (!_closed.isCompleted) await _closed.future;
      return;
    }
    _stopping = true;
    _finished = true;
    _deadline?.cancel();
    _probeTimer?.cancel();
    try {
      await _subscription?.cancel();
    } catch (_) {}
    _subscription = null;
    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
    try {
      await _browser?.close();
    } catch (_) {}
    _browser = null;
    if (!_closed.isCompleted) _closed.complete();
    if (!_controller.isClosed) {
      if (_controller.hasListener) {
        _flushPending();
        await _controller.close();
      } else {
        // `start()` 与 `listen()` 之间有异步间隙：把关闭推迟到首个订阅，
        // 否则成功/失败事件会被静默丢掉。
        _closeWhenListened = true;
      }
    }
  }

  String _originOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return url;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port/';
  }
}
