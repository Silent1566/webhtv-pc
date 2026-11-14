/// 浏览器与 CDP 传输层契约（嗅探内核的实现边界）。
///
/// 抽这一层的理由有两个：
/// 1. `lib/core` 不得直接碰 `Process`/`WebSocket`——嗅探的编排逻辑必须能用
///    假传输做穷举测试（超时、竞速、进程退出）；
/// 2. 平台差异（Edge/Chrome 路径、`--headless=new` 是否可用）只落在实现里，
///    上层命令与事件保持同一套语义。
library;

/// 一个可启动的 Chromium 内核浏览器。
class BrowserCommand {
  const BrowserCommand({required this.executablePath, required this.label});

  /// 可执行文件绝对路径。
  final String executablePath;

  /// 人类可读名称（`Microsoft Edge` / `Google Chrome` / `Chromium`）。
  final String label;
}

/// 一条 CDP 事件（`method` + `params` + 可选 `sessionId`）。
class CdpEvent {
  const CdpEvent({required this.method, this.params = const {}, this.sessionId});
  final String method;
  final Map<String, Object?> params;
  final String? sessionId;
}

/// CDP 调用失败（错误响应、超时、连接已关闭）。
class CdpCallError implements Exception {
  const CdpCallError(this.method, this.message, {this.code});
  final String method;
  final String message;
  final int? code;

  @override
  String toString() => 'CDP $method 失败：$message${code == null ? '' : '（$code）'}';
}

/// 浏览器进程句柄。
abstract class BrowserSession {
  /// 该浏览器的 DevTools 端点（`ws://127.0.0.1:<port>/devtools/browser/<id>`）。
  Uri get webSocketUrl;

  /// 进程号（诊断与强制回收）。
  int get pid;

  /// 终止进程并清理临时 profile 目录（幂等）。
  Future<void> close();
}

/// 与浏览器的一条 CDP 连接（一次连接多路复用所有 session）。
abstract class CdpConnection {
  /// 全部事件（含各 session 的事件）。
  Stream<CdpEvent> get events;

  /// 调用一条 CDP 命令。[sessionId] 非空时发到对应子 session。
  Future<Map<String, Object?>> send(
    String method, {
    Map<String, Object?>? params,
    String? sessionId,
    Duration timeout,
  });

  Future<void> close();
}

/// 嗅探传输：定位浏览器、启动进程、建立 CDP 连接。
///
/// 三件事必须由同一实现提供：定位结果（`executablePath`）与启动参数、端点
/// 发现方式强耦合，拆开只会让假实现更难写。
abstract class SniffTransport {
  /// 找到本机可用的 Chromium 内核浏览器；找不到返回 `null`。
  ///
  /// [override] 来自 `WEBHTV_SNIFF_BROWSER` 环境变量或设置项，优先级最高。
  Future<BrowserCommand?> locate({String? override});

  /// 按优先级列出**全部**候选。
  ///
  /// 为什么需要列表：本机装着的浏览器可能"存在但跑不起来"（典型是 snap 包装脚本
  /// 在受限环境里 snap-confine 失败，或残留的坏软链）。只认第一个候选，会让一个
  /// 坏包装把整机可用的 Chrome/Edge 挡住。默认实现退化为单候选，假传输无需改动。
  Future<List<BrowserCommand>> locateAll({String? override}) async {
    final single = await locate(override: override);
    return [?single];
  }

  /// 轻量可用性探测（一次 `--version`，不启动窗口）。
  ///
  /// 返回**不可用原因**；`null` 表示可用。为什么要原因而不是 bool：坏候选的
  /// 真实理由（`snap-confine` 权限、架构不匹配）是用户唯一能据以自救的信息，
  /// 只报「不可用」等于把诊断成本推回给用户。
  Future<String?> probe(BrowserCommand command) async => null;

  /// 启动浏览器。[headless] 为 `true` 时离屏运行（`--headless=new`）。
  Future<BrowserSession> launch(
    BrowserCommand command, {
    bool headless,
    Duration readyTimeout,
    int? width,
    int? height,
  });

  /// 连接 [webSocketUrl]。
  Future<CdpConnection> connect(Uri webSocketUrl, {Duration timeout});
}
