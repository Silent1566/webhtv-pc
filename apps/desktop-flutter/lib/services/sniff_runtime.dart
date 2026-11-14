/// 嗅探运行时的应用级接线：把「已安装浏览器组件」接进嗅探引擎，并维护
/// 「本机浏览器是否可用」的可观测快照。
///
/// 为什么接线放在服务层：`lib/core/sniff` 不该知道应用数据目录在哪
/// （它在契约层只认 `SniffTransport`）；而组件库需要 AppPaths 与 archive。
/// 两边在这里汇合，解析层只看到 `sharedSniffEngine()`。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../core/sniff/chromium_sniffer.dart';
import '../core/sniff/default_sniff_transport.dart';
import '../core/sniff/sniff_engine_factory.dart';
import '../core/sniff/sniff_transport.dart';
import '../core/sniff/sniff_types.dart';
import 'app_paths.dart';
import 'browser_component_store.dart';

/// 建立并登记进程级嗅探引擎；返回该引擎（便于诊断/测试）。
///
/// 幂等：重复调用只是替换同一个共享实例。启动阶段调用一次即可。
SniffEngine initializeSniffRuntime(AppPaths paths, {BrowserComponentStore? store}) {
  final components = store ?? BrowserComponentStore.forApp(paths);
  _componentsRoot = components.rootDirectory;
  final engine = ChromiumSniffEngine(
    transport: DefaultSniffTransport(
      componentExecutables: components.executablePaths,
    ),
  );
  installSharedSniffEngine(engine);
  return engine;
}

String? _componentsRoot;

/// 组件根目录（由 [initializeSniffRuntime] 记录；探测 isolate 用它重建组件库）。
String get sniffComponentsRootDirectory => _componentsRoot ?? '';

/// 默认探测在独立 isolate 里跑。
///
/// 两个理由：① UI 与测试都可能从 FakeAsync 触发它，`Process` 与其超时定时器
/// 留在那里会让 `pumpAndSettle` 挂死（仓库既有测试多次踩到）；② 探测本身是
/// 几次子进程启动，放在后台 isolate 不会卡住首帧。
Future<SniffBrowserStatus> _probeInIsolate(String componentsRoot) async {
  final raw = await Isolate.run(() async {
    final store = BrowserComponentStore(rootDirectory: componentsRoot);
    final transport = DefaultSniffTransport(
      componentExecutables: store.executablePaths,
    );
    final candidates = await transport.locateAll();
    final usables = <List<String>>[];
    final issues = <String>[];
    for (final candidate in candidates) {
      final issue = await transport.probe(candidate);
      if (issue == null) {
        usables.add([candidate.executablePath, candidate.label]);
      } else {
        issues.add('${candidate.executablePath}：$issue');
      }
    }
    return [usables, issues];
  });
  final usables = <BrowserCommand>[];
  for (final entry in raw[0] as List) {
    final pair = entry as List;
    usables.add(
      BrowserCommand(executablePath: '${pair[0]}', label: '${pair[1]}'),
    );
  }
  return SniffBrowserStatus(
    usables: usables,
    issues: (raw[1] as List).map((item) => '$item').toList(growable: false),
  );
}

/// 系统/组件浏览器的可用性快照。
///
/// 为什么是应用层的可观测状态，而不是让设置页自己探测：设置页在
/// `flutter test` 的 FakeAsync 里渲染，`Process.start` 与它自带的超时定时器
/// 会让 `pumpAndSettle` 永久挂起（仓库既有测试多次踩到
/// 「A Timer is still pending」）。探测属于应用启动/用户点击这类真实事件循环里
/// 的动作，UI 只读快照。
class SniffBrowserStatus {
  const SniffBrowserStatus({required this.usables, required this.issues});

  /// 可用候选（含已装组件与系统浏览器），已按解析优先级排好。
  final List<BrowserCommand> usables;

  /// 每个不可用候选的原因（单行，来自 `probe`）。
  final List<String> issues;

  bool get hasUsable => usables.isNotEmpty;

  String? get firstUsableLabel => usables.isEmpty ? null : usables.first.label;
}

/// 最近一次可用性探测结果；`null` = 尚未探测。
final ValueNotifier<SniffBrowserStatus?> sniffBrowserStatus =
    ValueNotifier<SniffBrowserStatus?>(null);

Future<SniffBrowserStatus?>? _refreshInFlight;

/// 后台探测浏览器可用性并更新 [sniffBrowserStatus]。
///
/// 并发调用共享同一次探测：用户连点「重新检测」不该起一串子进程。
Future<SniffBrowserStatus?> refreshSniffBrowserStatus({
  SniffTransport? transport,
}) async {
  final inFlight = _refreshInFlight;
  if (inFlight != null) {
    await inFlight;
    return sniffBrowserStatus.value;
  }
  final completer = Completer<SniffBrowserStatus?>();
  _refreshInFlight = completer.future;
  try {
    final SniffBrowserStatus status;
    if (transport != null) {
      // 注入的传输（测试）在本线程直接跑：没有真实进程，也就没有待清理的定时器。
      final candidates = await transport.locateAll();
      final usables = <BrowserCommand>[];
      final issues = <String>[];
      for (final candidate in candidates) {
        final issue = await transport.probe(candidate);
        if (issue == null) {
          usables.add(candidate);
        } else {
          issues.add('${candidate.executablePath}：$issue');
        }
      }
      status = SniffBrowserStatus(usables: usables, issues: issues);
    } else {
      status = await _probeInIsolate(sniffComponentsRootDirectory);
    }
    sniffBrowserStatus.value = status;
    if (!completer.isCompleted) completer.complete(status);
    return status;
  } catch (error) {
    if (!completer.isCompleted) completer.complete(null);
    rethrow;
  } finally {
    _refreshInFlight = null;
  }
}

/// 重置快照（测试用）。
void resetSniffBrowserStatus() {
  _refreshInFlight = null;
  sniffBrowserStatus.value = null;
}