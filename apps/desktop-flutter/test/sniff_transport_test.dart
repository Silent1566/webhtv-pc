/// 传输层单测（不需要浏览器）：浏览器定位、启动参数纪律、CDP 客户端。
///
/// 为什么 CDP 用测试内自建的 WebSocket 服务：真浏览器只会走 happy path，而这一层
/// 真正的风险都在错误路径——错误响应、单条命令超时、socket 断开后 pending 必须失败
/// 而不是挂死；这些状态只能由可控的假服务制造。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/sniff/browser_locator.dart';
import 'package:webhtv_pc/core/sniff/browser_process.dart';
import 'package:webhtv_pc/core/sniff/cdp_connection.dart';
import 'package:webhtv_pc/core/sniff/default_sniff_transport.dart';
import 'package:webhtv_pc/core/sniff/sniff_transport.dart';

void main() {
  group('locateBrowser', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('sniff-locate-');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    /// 造一个真的带可执行位的假浏览器：定位器校验的是文件系统状态，不是名字。
    File fakeExecutable(String name) {
      final file = File('${temp.path}${Platform.pathSeparator}$name')
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      if (!Platform.isWindows) {
        final chmod = Process.runSync('chmod', ['755', file.path]);
        expect(chmod.exitCode, 0, reason: '测试夹具必须真的可执行');
      }
      return file;
    }

    test('override 指定可用浏览器时直接采用', () async {
      final executable = fakeExecutable('chrome');

      final command = await locateBrowser(
        override: executable.path,
        environment: const {},
        candidates: const [],
      );

      expect(command?.executablePath, executable.path);
      expect(command?.label, 'Google Chrome');
    });

    test('环境变量 WEBHTV_SNIFF_BROWSER 优先于平台候选', () async {
      final executable = fakeExecutable('msedge');

      final command = await locateBrowser(
        environment: {sniffBrowserEnvKey: executable.path},
        candidates: const [],
      );

      expect(command?.executablePath, executable.path);
      expect(command?.label, 'Microsoft Edge');
    });

    test('没有任何候选时返回 null 而不是抛异常', () async {
      expect(
        await locateBrowser(environment: const {}, candidates: const []),
        isNull,
      );
    });

    test('普通文件不算找到：没有可执行位就返回 null', () async {
      final plain = File('${temp.path}${Platform.pathSeparator}not-a-browser')
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');

      expect(
        await locateBrowser(
          override: plain.path,
          environment: const {},
          candidates: const [],
        ),
        isNull,
      );
    });

    test('不存在的 override 路径返回 null', () async {
      expect(
        await locateBrowser(
          override: '${temp.path}${Platform.pathSeparator}missing-chrome',
          environment: const {},
          candidates: const [],
        ),
        isNull,
      );
    });

    test('裸命令名按 PATH 解析', () async {
      final executable = fakeExecutable('chromium');

      final command = await locateBrowser(
        override: 'chromium',
        environment: {'PATH': temp.path},
        candidates: const [],
      );

      expect(command?.executablePath, executable.path);
      expect(command?.label, 'Chromium');
    });

    test('失效的 override 不会挡住后续候选', () async {
      final executable = fakeExecutable('google-chrome-stable');

      final command = await locateBrowser(
        override: '${temp.path}${Platform.pathSeparator}gone',
        environment: const {},
        candidates: [executable.path],
      );

      expect(command?.executablePath, executable.path);
    });
  });

  group('启动参数纪律', () {
    test('默认参数包含 DevTools 端点与临时 profile', () {
      final arguments = sniffBrowserArguments(
        userDataDir: '/tmp/a-profile',
        headless: true,
        width: 1280,
        height: 720,
      );

      expect(arguments, contains('--remote-debugging-port=0'));
      expect(arguments, contains('--user-data-dir=/tmp/a-profile'));
      expect(arguments, contains('--headless=new'));
      expect(arguments, contains('--window-size=1280,720'));
      expect(arguments, contains('--no-first-run'));
      expect(arguments, contains('--no-default-browser-check'));
      expect(arguments, contains('--disable-background-networking'));
      expect(arguments, contains('--disable-sync'));
      expect(arguments, contains('--disable-extensions'));
      expect(arguments, contains('--disable-features=Translate,MediaRouter'));
      expect(arguments, contains('--autoplay-policy=no-user-gesture-required'));
      expect(
        arguments.where((argument) => argument == '--no-sandbox'),
        isEmpty,
        reason: '普通用户下关掉 sandbox 等于把解析页的 JS 放到本机权限',
      );
    });

    test('非 headless 时没有 --headless=new，root 才加 --no-sandbox', () {
      final arguments = sniffBrowserArguments(
        userDataDir: '/tmp/a-profile',
        headless: false,
        root: true,
      );

      expect(arguments, isNot(contains('--headless=new')));
      expect(arguments, contains('--no-sandbox'));
      expect(arguments, isNot(contains('--window-size=0,0')));
    });

    test('root 判定只看环境，不看平台猜测', () {
      expect(sniffRunningAsRoot({'USER': 'root'}), Platform.isWindows ? isFalse : isTrue);
      expect(sniffRunningAsRoot({'USER': 'maple', 'LOGNAME': 'maple'}), isFalse);
    });
  });

  group('候选列表与可用性探测（snap 包装脚本场景）', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('sniff-probe-');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    File script(String name, int exitCode) {
      final file = File('${temp.path}${Platform.pathSeparator}$name')
        ..writeAsStringSync('#!/bin/sh\nexit $exitCode\n');
      if (!Platform.isWindows) {
        expect(Process.runSync('chmod', ['755', file.path]).exitCode, 0);
      }
      return file;
    }

    test('chooseBrowserTempRoot：优先短的 XDG_RUNTIME_DIR，其次 /tmp，超长目录绝不选', () {
      final usable = <String>{'/tmp', '/run/user/1000'};
      bool isUsable(String path) => usable.contains(path);
      const longTemp = '/home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3/.local/linux-build/tmp';

      expect(
        chooseBrowserTempRoot(
          systemTemp: longTemp,
          xdgRuntimeDir: '/run/user/1000',
          isUsable: isUsable,
        ),
        '/run/user/1000',
        reason: 'XDG 运行时目录最短且可写',
      );
      expect(
        chooseBrowserTempRoot(systemTemp: longTemp, isUsable: isUsable),
        '/tmp',
        reason: '没有 XDG 时退到 /tmp；本次现场就是长 TMPDIR 导致 Socket path too long',
      );
      expect(
        chooseBrowserTempRoot(
          systemTemp: longTemp,
          isUsable: (path) => false,
        ),
        longTemp,
        reason: '全都不合条件时如实回落系统临时目录，不猜不可写位置',
      );
      expect(
        chooseBrowserTempRoot(systemTemp: '/tmp', isUsable: isUsable),
        '/tmp',
        reason: '本来就短就原样使用',
      );
    });

    test('locateBrowsers 按优先级返回去重候选，override 排最前', () async {
      final first = script('chrome-a', 0);
      final second = script('chrome-b', 0);
      final commands = await locateBrowsers(
        override: first.path,
        environment: const {'PATH': ''},
        candidates: ['/nonexistent/chrome', first.path, second.path],
      );
      expect(commands.map((command) => command.executablePath).toList(), [
        first.path,
        second.path,
      ]);
    });

    test('compactProbeReason：多行 stderr 压成单行，保留第一条原因并给出折叠行数', () {
      const raw = 'snap-confine is packaged without necessary permissions\n'
          'required permitted capability cap_dac_override not found\n'
          '  cap_wake_alarm=i\n';
      final reason = compactProbeReason(raw);
      expect(reason, contains('snap-confine'));
      expect(reason, contains('另有 2 行输出已折叠'));
      expect(reason, isNot(contains('\n')));
    });

    test('已装组件排在系统候选之前，显式 override 仍排第一', () async {
      final component = script('component-chrome', 0);
      final overrideFile = script('override-chrome', 0);
      final transport = DefaultSniffTransport(
        componentExecutables: () async => [component.path],
      );
      final commands = await transport.locateAll(override: overrideFile.path);
      expect(commands.first.executablePath, overrideFile.path);
      expect(commands[1].executablePath, component.path);
    });

    test('probeChromiumBrowser：退出 0 返回 null（可用），退出 1 与不存在返回原因', () async {
      final healthy = script('chrome-ok', 0);
      final broken = script('chrome-broken', 1);
      final healthyCommand = BrowserCommand(
        executablePath: healthy.path,
        label: 'Chromium',
      );
      final brokenCommand = BrowserCommand(
        executablePath: broken.path,
        label: 'Chromium',
      );
      expect(await probeChromiumBrowser(healthyCommand), isNull);
      final brokenIssue = await probeChromiumBrowser(brokenCommand);
      expect(brokenIssue, isNotNull);
      expect(brokenIssue, contains('退出码 1'));
      expect(
        await probeChromiumBrowser(
          const BrowserCommand(executablePath: '/nonexistent/chrome', label: 'x'),
        ),
        isNotNull,
      );
    });
  });

  group('connectCdp', () {
    late _FakeCdpServer server;
    CdpConnection? connection;

    setUp(() async {
      server = await _FakeCdpServer.start();
    });

    tearDown(() async {
      await connection?.close();
      connection = null;
      await server.close();
    });

    test('命令与响应按 id 配对，sessionId 原样透传', () async {
      server.onCommand = (message, socket) {
        final params = message['params'];
        socket.add(
          jsonEncode({
            'id': message['id'],
            'result': {'echo': params is Map ? params['value'] : null},
          }),
        );
      };
      connection = await connectCdp(server.url);

      final results = await Future.wait([
        connection!.send(
          'Runtime.evaluate',
          params: {'value': 'first'},
          sessionId: 'SESSION-A',
        ),
        connection!.send('Runtime.evaluate', params: {'value': 'second'}),
      ]);

      expect(results[0]['echo'], 'first');
      expect(results[1]['echo'], 'second');
      expect(server.received[0]['sessionId'], 'SESSION-A');
      expect(server.received[1].containsKey('sessionId'), isFalse);
      expect(server.received[0]['method'], 'Runtime.evaluate');
    });

    test('事件进入广播流并带上 sessionId', () async {
      connection = await connectCdp(server.url);
      final event = connection!.events.firstWhere(
        (event) => event.method == 'Network.requestWillBeSent',
      );

      server.socket!.add(
        jsonEncode({
          'method': 'Network.requestWillBeSent',
          'params': {
            'request': {'url': 'http://127.0.0.1/stream.m3u8'},
          },
          'sessionId': 'SESSION-B',
        }),
      );

      final received = await event.timeout(const Duration(seconds: 5));
      expect(received.sessionId, 'SESSION-B');
      final request = received.params['request'];
      expect(request, isA<Map>());
      expect((request! as Map)['url'], 'http://127.0.0.1/stream.m3u8');
    });

    test('错误响应转成带 code 的 CdpCallError', () async {
      server.onCommand = (message, socket) => socket.add(
        jsonEncode({
          'id': message['id'],
          'error': {'code': -32601, 'message': 'method not found'},
        }),
      );
      connection = await connectCdp(server.url);

      await expectLater(
        connection!.send('Page.noSuchCommand'),
        throwsA(
          isA<CdpCallError>()
              .having((error) => error.code, 'code', -32601)
              .having((error) => error.message, 'message', contains('method not found')),
        ),
      );
    });

    test('命令超时抛 CdpCallError 而不是挂死', () async {
      connection = await connectCdp(server.url);

      await expectLater(
        connection!.send(
          'Page.neverAnswers',
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<CdpCallError>().having(
            (error) => error.message,
            'message',
            contains('超时'),
          ),
        ),
      );
    });

    test('socket 断开时 pending 以 CdpCallError 失败', () async {
      connection = await connectCdp(server.url);
      final pending = connection!.send(
        'Page.hang',
        timeout: const Duration(seconds: 10),
      );
      final expectation = expectLater(
        pending,
        throwsA(
          isA<CdpCallError>().having(
            (error) => error.message,
            'message',
            contains('关闭'),
          ),
        ),
      );

      await _waitFor(() => server.received.isNotEmpty);
      await server.socket!.close(WebSocketStatus.goingAway);
      await expectation;
    });

    test('关闭后的 send 立即失败，不会静默丢弃', () async {
      connection = await connectCdp(server.url);
      await connection!.close();

      await expectLater(
        connection!.send('Page.afterClose'),
        throwsA(isA<CdpCallError>()),
      );
    });
  });
}

/// 轮询等待测试内的服务端状态；时间上限只是防止测试挂死。
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('等待测试前置条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// 测试内自建的 CDP 服务：只做 JSON 收发，响应策略由每个用例给。
class _FakeCdpServer {
  _FakeCdpServer._(this._server);

  final HttpServer _server;
  final List<Map<String, Object?>> received = [];
  WebSocket? socket;

  /// 收到命令后的应答动作（null 表示不应答，用于超时用例）。
  void Function(Map<String, Object?> message, WebSocket socket)? onCommand;

  static Future<_FakeCdpServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeCdpServer._(server);
    server.listen((request) async {
      final webSocket = await WebSocketTransformer.upgrade(request);
      fake.socket = webSocket;
      webSocket.listen(
        (data) {
          if (data is! String) return;
          final decoded = jsonDecode(data);
          if (decoded is! Map) return;
          final message = decoded.cast<String, Object?>();
          fake.received.add(message);
          fake.onCommand?.call(message, webSocket);
        },
        onError: (Object _) {},
        onDone: () {},
        cancelOnError: false,
      );
    });
    return fake;
  }

  Uri get url =>
      Uri.parse('ws://127.0.0.1:${_server.port}/devtools/browser/fake-id');

  Future<void> close() async {
    await socket?.close();
    socket = null;
    await _server.close(force: true);
  }
}
