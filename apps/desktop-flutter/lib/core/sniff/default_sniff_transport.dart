/// 桌面端嗅探传输的默认实现：系统 Chromium 内核浏览器 + 本机 CDP。
///
/// 这一层只做组合，不放逻辑：定位、启动、连接三件事各自可单测，组合处任何
/// 多出来的分支都会变成上层测试要额外覆盖的隐形行为。
library;

import 'dart:io';

import 'browser_locator.dart';
import 'browser_process.dart';
import 'cdp_connection.dart';
import 'sniff_transport.dart';

/// 真实浏览器传输（Windows / Linux / macOS）。
///
/// [componentExecutables] 由服务层接线（`BrowserComponentStore`）：用户在设置里
/// 装进来的浏览器组件要排在系统浏览器之前——「点安装」就是表达偏好（R-G 决策）。
class DefaultSniffTransport implements SniffTransport {
  const DefaultSniffTransport({this.componentExecutables});

  final Future<List<String>> Function()? componentExecutables;

  @override
  Future<BrowserCommand?> locate({String? override}) =>
      locateBrowser(override: override);

  @override
  Future<List<BrowserCommand>> locateAll({String? override}) async {
    final explicit = await locateExplicitBrowser(override: override);
    final components = await _componentCandidates();
    final system = await locateBrowsers(override: override);
    final seen = <String>{};
    final result = <BrowserCommand>[];
    for (final command in [?explicit, ...components, ...system]) {
      if (seen.add(command.executablePath)) result.add(command);
    }
    return result;
  }

  Future<List<BrowserCommand>> _componentCandidates() async {
    final provider = componentExecutables;
    if (provider == null) return const [];
    try {
      final paths = await provider();
      return [
        for (final path in paths)
          if (File(path).existsSync())
            BrowserCommand(
              executablePath: path,
              label: '已安装组件（${File(path).uri.pathSegments.last}）',
            ),
      ];
    } on Object {
      // 组件库损坏不该让系统浏览器也失效：这里静默跳过，由探测结果兜底。
      return const [];
    }
  }

  @override
  Future<String?> probe(BrowserCommand command) => probeChromiumBrowser(command);

  @override
  Future<BrowserSession> launch(
    BrowserCommand command, {
    bool headless = true,
    Duration readyTimeout = const Duration(seconds: 20),
    int? width,
    int? height,
  }) => launchChromiumBrowser(
    command,
    headless: headless,
    readyTimeout: readyTimeout,
    width: width,
    height: height,
  );

  @override
  Future<CdpConnection> connect(
    Uri webSocketUrl, {
    Duration timeout = cdpDefaultTimeout,
  }) => connectCdp(webSocketUrl, timeout: timeout);
}
