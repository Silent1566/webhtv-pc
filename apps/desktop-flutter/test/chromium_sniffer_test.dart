/// CDP 嗅探引擎的编排测试（§12.1 `type=0`/`type=4`）。
///
/// 这里用**假传输**复述 CDP 的真实事件形状（`Network.requestWillBeSent`、
/// `Page.loadEventFired`、`Runtime.evaluate` 返回值），不需要浏览器即可穷举：
/// 命中判定、页面文档忽略、DOM 补采、超时兜底、stop 幂等、订阅前事件不丢。
/// 真实浏览器路径由 `test/parse_sniff_chromium_test.dart` 覆盖。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/sniff/chromium_sniffer.dart';
import 'package:webhtv_pc/core/sniff/sniff_transport.dart';
import 'package:webhtv_pc/core/sniff/sniff_types.dart';

void main() {
  const pageUrl = 'https://parse.example.com/jx?url=https%3A%2F%2Fv.example.com%2F1';

  SniffRequest request({
    Duration timeout = const Duration(seconds: 5),
    Map<String, String> headers = const {},
    String? clickScript,
    List<SniffRule> rules = const [],
  }) => SniffRequest(
    pageUrl: pageUrl,
    timeout: timeout,
    headers: headers,
    clickScript: clickScript,
    rules: rules,
  );

  test('定位不到浏览器时抛 SniffUnavailableException（不静默降级）', () async {
    final engine = ChromiumSniffEngine(
      transport: FakeTransport(locateResult: null),
      headed: false,
    );
    await expectLater(
      engine.start(request()),
      throwsA(isA<SniffUnavailableException>()),
    );
  });

  test('默认走无头模式（不再创建可见窗口）', () async {
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport);
    final session = await engine.start(request());
    expect(transport.launchHeadless, [true], reason: '默认必须 headless=true');
    await session.stop();
  });

  test('显式 headed 时才用可见窗口', () async {
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport, headed: true);
    final session = await engine.start(request());
    expect(transport.launchHeadless, [false]);
    await session.stop();
  });

  test('坏候选（snap 包装脚本）被跳过，换下一个可用浏览器', () async {
    const broken = BrowserCommand(
      executablePath: '/snap/bin/chromium',
      label: 'Chromium',
    );
    const working = BrowserCommand(
      executablePath: '/usr/bin/google-chrome',
      label: 'Google Chrome',
    );
    final transport = FakeTransport(
      candidates: [broken, working],
      badProbePaths: {'/snap/bin/chromium'},
    );
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request());
    expect(transport.probed.map((c) => c.executablePath), [
      '/snap/bin/chromium',
      '/usr/bin/google-chrome',
    ]);
    expect(transport.launched.map((c) => c.executablePath), [
      '/usr/bin/google-chrome',
    ]);
    await session.stop();
  });

  test('候选探测通过但启动失败时也换下一个', () async {
    const flaky = BrowserCommand(
      executablePath: '/usr/bin/chromium-freeworld',
      label: 'Chromium',
    );
    const working = BrowserCommand(
      executablePath: '/usr/bin/google-chrome',
      label: 'Google Chrome',
    );
    final transport = FakeTransport(
      candidates: [flaky, working],
      failingLaunchPaths: {'/usr/bin/chromium-freeworld'},
    );
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request());
    expect(transport.launched.length, 2);
    expect(transport.launched.last.executablePath, '/usr/bin/google-chrome');
    await session.stop();
  });

  test('全部候选不可用 → SniffUnavailableException，并逐个列出原因', () async {
    const broken = BrowserCommand(
      executablePath: '/snap/bin/chromium',
      label: 'Chromium',
    );
    const failing = BrowserCommand(
      executablePath: '/opt/dead/chrome',
      label: 'Google Chrome',
    );
    final transport = FakeTransport(
      candidates: [broken, failing],
      badProbePaths: {'/snap/bin/chromium'},
      failingLaunchPaths: {'/opt/dead/chrome'},
    );
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    await expectLater(
      engine.start(request()),
      throwsA(
        isA<SniffUnavailableException>()
            .having((error) => error.message, 'message', contains('snap'))
            .having((error) => error.detail, 'detail', contains('/snap/bin/chromium'))
            .having((error) => error.detail, 'detail', contains('snap-confine'))
            .having(
              (error) => error.detail,
              'detail',
              contains('WEBHTV_SNIFF_BROWSER'),
            )
            .having(
              (error) => error.detail,
              'detail',
              isNot(contains('\n')),
            ),
      ),
    );
  });

  test('网络请求命中媒体地址即成功，只带回 UA/Referer/Cookie', () async {
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request());
    final collected = <SniffEvent>[];
    session.events.listen(collected.add);

    transport.connection.emit(CdpEvent(
      method: 'Network.requestWillBeSent',
      params: {
        'request': {
          'url': 'https://cdn.example.com/vod/master.m3u8',
          'headers': {
            'User-Agent': 'Mozilla/5.0',
            'Referer': 'https://parse.example.com/',
            'X-Trace': 'should-be-dropped',
          },
        },
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final candidate = collected.whereType<SniffCandidate>().single;
    expect(candidate.url, 'https://cdn.example.com/vod/master.m3u8');
    expect(candidate.via, 'network');
    expect(candidate.headers, {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://parse.example.com/'});
    await session.stop();
  });

  test('页面文档与普通资源不误判', () async {
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request());
    final collected = <SniffEvent>[];
    session.events.listen(collected.add);

    for (final url in <String>[pageUrl, 'https://cdn.example.com/app.js', 'https://cdn.example.com/x.html']) {
      transport.connection.emit(CdpEvent(
        method: 'Network.requestWillBeSent',
        params: {
          'request': {'url': url, 'headers': <String, String>{}},
        },
      ));
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(collected.whereType<SniffCandidate>(), isEmpty);
    await session.stop();
  });

  test('无后缀地址靠配置规则 regex 命中', () async {
    const rule = SniffRule(regexes: ['/hs/']);
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request(rules: const [rule]));
    final collected = <SniffEvent>[];
    session.events.listen(collected.add);

    transport.connection.emit(CdpEvent(
      method: 'Network.requestWillBeSent',
      params: {
        'request': {'url': 'https://cdn.example.com/hs/abcdef0123456789', 'headers': <String, String>{}},
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(collected.whereType<SniffCandidate>().single.url,
        'https://cdn.example.com/hs/abcdef0123456789');
    await session.stop();
  });

  test('页面加载后注入 click 脚本，DOM 探测补采媒体地址', () async {
    final transport = FakeTransport();
    transport.connection.evaluateValues = (expression) {
      if (expression.contains('querySelectorAll')) {
        return ['https://cdn.example.com/vod/from-dom.m3u8'];
      }
      return '';
    };
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request(clickScript: 'document.querySelector("#play").click()'));

    // 等候选事件，而不是固定 sleep：DOM 探测是 1s 一次的定时器，固定 1.4s
    // 在并发跑整套测试时会因为机器负载而偶发失败（实测踩到）。
    final candidateFuture = session.events
        .where((event) => event is SniffCandidate)
        .cast<SniffCandidate>()
        .first
        .timeout(const Duration(seconds: 8));

    transport.connection.emit(CdpEvent(method: 'Page.loadEventFired', params: const {}));
    final candidate = await candidateFuture;

    expect(
      transport.connection.evaluated.any((expression) => expression.contains('document.querySelector("#play").click()')),
      isTrue,
      reason: 'click 脚本必须在页面加载后注入',
    );
    expect(candidate.via, 'dom');
    expect(candidate.url, 'https://cdn.example.com/vod/from-dom.m3u8');
    await session.stop();
  });

  test('始终无候选时由兜底计时器报超时，并回收浏览器', () async {
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request(timeout: const Duration(milliseconds: 50)));
    final future = session.events.where((event) => event is SniffFailed).first;
    final failed = await future.timeout(const Duration(seconds: 5));
    expect((failed as SniffFailed).message, contains('超时'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(transport.browser.closeCount, greaterThanOrEqualTo(1));
  });

  test('stop 幂等：重复调用只关闭一次连接与进程', () async {
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request());
    await session.stop();
    await session.stop();
    expect(transport.browser.closeCount, 1);
    expect(transport.connection.closeCount, 1);
  });

  test('订阅晚于事件到达时仍能拿到成功事件', () async {
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request());
    transport.connection.emit(CdpEvent(
      method: 'Network.requestWillBeSent',
      params: {
        'request': {'url': 'https://cdn.example.com/vod/late.m3u8', 'headers': <String, String>{}},
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final events = await session.events.toList();
    expect(events.whereType<SniffCandidate>().single.url,
        'https://cdn.example.com/vod/late.m3u8');
  });

  test('跨 scheme 的 Referer 不塞进全局 Header（否则导航被浏览器拦掉），改走 navigate.referrer', () async {
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(SniffRequest(
      pageUrl: 'http://parse.example.com/jx?url=https%3A%2F%2Fv.example.com%2F1',
      timeout: const Duration(seconds: 5),
      headers: {
        'Referer': 'https://ref.example.com/',
        'Origin': 'https://ref.example.com',
        'X-Token': 'keep-me',
      },
    ));
    final extra = transport.connection.calls
        .where((call) => call.method == 'Network.setExtraHTTPHeaders');
    final headers = (extra.single.params?['headers'] as Map?) ?? const {};
    expect(headers.containsKey('Referer'), isFalse, reason: 'http 页 + https Referer 会被 ERR_BLOCKED_BY_CLIENT 拦掉');
    expect(headers.containsKey('Origin'), isFalse);
    expect(headers['X-Token'], 'keep-me');
    final navigate = transport.connection.calls.where((call) => call.method == 'Page.navigate');
    expect(navigate.single.params?['referrer'], 'https://ref.example.com/');
    await session.stop();
  });

  test('主文档被拦时先去 Header 重试一次，仍失败则报可诊断错误而不是超时', () async {
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request(headers: {'Referer': 'https://parse.example.com/'}));
    final failures = <SniffFailed>[];
    session.events.listen((event) {
      if (event is SniffFailed) failures.add(event);
    });

    transport.connection.emit(CdpEvent(
      method: 'Network.requestWillBeSent',
      params: {
        'requestId': 'doc-1',
        'type': 'Document',
        'request': {'url': pageUrl, 'headers': <String, String>{}},
      },
    ));
    transport.connection.emit(CdpEvent(
      method: 'Network.loadingFailed',
      params: {
        'requestId': 'doc-1',
        'errorText': 'net::ERR_BLOCKED_BY_CLIENT',
        'canceled': false,
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final navigations = transport.connection.calls.where((call) => call.method == 'Page.navigate');
    expect(navigations.length, 2, reason: '第一次被拦后应清空全局 Header 重试一次');
    final cleared = transport.connection.calls
        .where((call) => call.method == 'Network.setExtraHTTPHeaders')
        .last;
    expect((cleared.params?['headers'] as Map), isEmpty);

    transport.connection.emit(CdpEvent(
      method: 'Network.loadingFailed',
      params: {
        'requestId': 'doc-1',
        'errorText': 'net::ERR_BLOCKED_BY_CLIENT',
        'canceled': false,
      },
    ));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(failures.single.message, contains('解析页加载失败'));
    expect(failures.single.detail, contains('ERR_BLOCKED_BY_CLIENT'));
  });

  test('请求头落到 CDP：UA 走 setUserAgentOverride，Referer 走 extra headers', () async {
    final transport = FakeTransport();
    final engine = ChromiumSniffEngine(transport: transport, headed: false);
    final session = await engine.start(request(headers: {
      'User-Agent': 'UA/1.0',
      'Referer': 'https://ref.example.com/',
    }));
    final ua = transport.connection.calls.where((call) => call.method == 'Network.setUserAgentOverride');
    final extra = transport.connection.calls.where((call) => call.method == 'Network.setExtraHTTPHeaders');
    expect(ua.single.params?['userAgent'], 'UA/1.0');
    expect((extra.single.params?['headers'] as Map)['Referer'], 'https://ref.example.com/');
    await session.stop();
  });
}

/// CDP 调用记录。
class RecordedCall {
  const RecordedCall(this.method, this.params, this.sessionId);
  final String method;
  final Map<String, Object?>? params;
  final String? sessionId;
}

class FakeTransport implements SniffTransport {
  FakeTransport({
    this.locateResult = const BrowserCommand(
      executablePath: '/usr/bin/fake-chrome',
      label: 'Fake Chrome',
    ),
    this.candidates,
    this.badProbePaths = const {},
    this.failingLaunchPaths = const {},
  });

  final BrowserCommand? locateResult;

  /// 覆盖 `locateAll`（模拟「本机装了多个浏览器」）。
  final List<BrowserCommand>? candidates;

  /// 这些路径的 `--version` 探测返回失败（模拟 snap 包装脚本）。
  final Set<String> badProbePaths;

  /// 这些路径能探测通过但启动即失败（模拟端点起不来）。
  final Set<String> failingLaunchPaths;

  late final FakeBrowserSession browser = FakeBrowserSession();
  late final FakeCdpConnection connection = FakeCdpConnection();
  final List<BrowserCommand> probed = [];
  final List<BrowserCommand> launched = [];
  final List<bool> launchHeadless = [];

  @override
  Future<BrowserCommand?> locate({String? override}) async => locateResult;

  @override
  Future<List<BrowserCommand>> locateAll({String? override}) async =>
      candidates ?? [?locateResult];

  @override
  Future<String?> probe(BrowserCommand command) async {
    probed.add(command);
    if (!badProbePaths.contains(command.executablePath)) return null;
    return '退出码 1；snap-confine is packaged without necessary permissions';
  }

  @override
  Future<BrowserSession> launch(
    BrowserCommand command, {
    bool headless = true,
    Duration readyTimeout = const Duration(seconds: 20),
    int? width,
    int? height,
  }) async {
    launched.add(command);
    launchHeadless.add(headless);
    if (failingLaunchPaths.contains(command.executablePath)) {
      throw const SniffException(
        '浏览器在 DevTools 端点就绪前退出',
        detail: '退出码 1；snap-confine is packaged without necessary permissions',
      );
    }
    return browser;
  }

  @override
  Future<CdpConnection> connect(Uri webSocketUrl, {Duration timeout = const Duration(seconds: 10)}) async => connection;
}

class FakeBrowserSession implements BrowserSession {
  int closeCount = 0;

  @override
  int get pid => 4242;

  @override
  Uri get webSocketUrl => Uri.parse('ws://127.0.0.1:9222/devtools/browser/fake');

  @override
  Future<void> close() async => closeCount++;
}

class FakeCdpConnection implements CdpConnection {
  final StreamController<CdpEvent> _events = StreamController<CdpEvent>.broadcast();
  final List<RecordedCall> calls = [];
  final List<String> evaluated = [];
  int closeCount = 0;

  Object? Function(String expression)? evaluateValues;

  void emit(CdpEvent event) => _events.add(event);

  @override
  Stream<CdpEvent> get events => _events.stream;

  @override
  Future<Map<String, Object?>> send(
    String method, {
    Map<String, Object?>? params,
    String? sessionId,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    calls.add(RecordedCall(method, params, sessionId));
    switch (method) {
      case 'Target.createTarget':
        return {'targetId': 'TARGET-1'};
      case 'Target.attachToTarget':
        return {'sessionId': 'SESSION-1'};
      case 'Browser.getWindowForTarget':
        return {'windowId': 7};
      case 'Runtime.evaluate':
        final expression = '${params?['expression'] ?? ''}';
        evaluated.add(expression);
        final value = evaluateValues?.call(expression);
        return {
          'result': {'value': value ?? ''},
        };
    }
    return const {};
  }

  @override
  Future<void> close() async {
    closeCount++;
    await _events.close();
  }
}
