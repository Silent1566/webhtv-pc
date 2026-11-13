/// 嗅探引擎的进程级入口。
///
/// 解析层只依赖本函数，不关心引擎怎么实现。返回 `null` 表示**本机不可用**：
/// 没有找到 Chromium 内核浏览器，或平台没有可用后端。此时解析层必须抛
/// `parseSniffUnavailable` 并给出补充指引，不得静默降级（§12.3）。
///
/// 引擎不持有浏览器进程（每次嗅探起一个、结束即回收），所以这里可以安全地
/// 共享同一个实例；探测代价只是一次文件系统检查，不必缓存"有没有浏览器"。
library;

import 'chromium_sniffer.dart';
import 'default_sniff_transport.dart';
import 'sniff_types.dart';

SniffEngine? _shared;
bool _probed = false;

/// 取当前进程共享的嗅探引擎；不可用返回 `null`。
SniffEngine? sharedSniffEngine() {
  if (!_probed) {
    _probed = true;
    _shared = _build();
  }
  return _shared;
}

/// 注入引擎（测试与「引擎可用性」诊断用）。传 `null` 表示已知不可用。
void installSharedSniffEngine(SniffEngine? engine) {
  _probed = true;
  _shared = engine;
}

/// 重置探测状态（测试用）。
void resetSharedSniffEngine() {
  _probed = false;
  _shared = null;
}

SniffEngine? _build() => ChromiumSniffEngine(transport: const DefaultSniffTransport());
