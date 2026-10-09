/// 安卓设备探测与 T4 配置拉取（`docs/phase5/design/01` §4/§6）。
///
/// 职责（`design/01` §2）：网络请求、错误分类、脱敏日志、进度回调。
/// **不做** UI、不直接改 `AppState`。
///
/// 关键契约：
/// - 请求必须发到 **PC 视角的可达地址**，并把 `Host` 头设为该地址，让网关
///   派生出的站点 `api` 直接可用（`design/00` §3.2 实测）；
/// - 6 类错误必须分类呈现（`design/00` P5），不得折叠成「0 个站点」；
/// - 设备指纹只输出前 4 位（`design/01` §7）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/android_bridge.dart';
import '../core/app_error.dart';
import '../core/protocol.dart';
import 'log_service.dart';

/// 探测/拉取的进度事件（供 UI 展示）。
enum BridgeStage {
  /// 正在校验设备（`/device`）。
  probingDevice,

  /// 正在拉取站点清单（`/vod/api?ac=config`）。
  fetchingConfig,

  /// 正在转换（纯逻辑，通常瞬时）。
  converting,

  done,
}

/// 一次扫描中发现的设备。
class BridgeDiscovery {
  const BridgeDiscovery({
    required this.base,
    this.device,
    this.error,
  });

  final String base;

  /// 识别成功时的设备；失败时为 `null`。
  final AndroidDevice? device;

  /// 失败原因（用于诊断，不阻断其它地址）。
  final AppError? error;

  bool get isDevice => device != null;
}

/// 安卓桥接服务（`design/01` §2 的「服务」层）。
class AndroidBridgeService {
  AndroidBridgeService({
    required this.log,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
    this.scanTimeout = const Duration(milliseconds: 400),
    this.scanConcurrency = 16,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// 日志服务（脱敏口径见 `design/01` §7）。
  final LogService log;

  /// 常规请求超时（探测与拉配置）。
  final Duration timeout;

  /// 扫描时单地址超时。上游 `ScanTask` 用 500 ms；PC 侧收紧到 400 ms 并把
  /// 并发从 64 降到 16（`design/00` §5 取舍表）。
  final Duration scanTimeout;

  /// 扫描并发上限。
  final int scanConcurrency;

  void close() => _client.close();

  /// 探测一台设备（`design/01` §4.3）。
  ///
  /// [base] 可以是用户手输或扫描候选；会先经 [normalizeBase] 规范化。
  Future<AndroidDevice> probeDevice(String base) async {
    final normalized = normalizeBase(base);
    final body = await _getText(
      Uri.parse('$normalized/device'),
      base: normalized,
      timeout: timeout,
    );
    final decoded = _decodeJson(body, normalized);
    return AndroidDevice.fromJson(decoded, reachableBase: normalized);
  }

  /// 拉取并转换 T4 站点清单（`design/01` §5）。
  ///
  /// [selfBase] 为 PC 自己监听的地址（可选），用于 P4 自引用防护。
  Future<BridgeConversion> fetchGatewayConfig(
    String base, {
    String? selfBase,
    void Function(BridgeStage stage)? onStage,
  }) async {
    final normalized = normalizeBase(base);
    onStage?.call(BridgeStage.fetchingConfig);
    final body = await _getText(
      Uri.parse('$normalized/vod/api?ac=config'),
      base: normalized,
      timeout: timeout,
      notFoundKind: AppErrorKind.bridgeNoGateway,
      notFoundMessage: '安卓设备版本过旧：缺少 T4 网关（/vod/api 不存在）',
    );
    onStage?.call(BridgeStage.converting);
    final conversion = convertGatewayConfig(
      jsonText: body,
      reachableBase: normalized,
      selfBase: selfBase,
    );
    onStage?.call(BridgeStage.done);
    _logInfo(
      '安卓桥接：拉取站点 sites=${conversion.siteCount} '
      'rewrites=${conversion.hostRewrites.length} '
      'skipped=${conversion.skippedSites.length} base=$normalized',
    );
    return conversion;
  }

  /// 拉取安卓设备**当前启用的直播源**（`lives`）。
  ///
  /// 为什么要单独取：T4 网关的 `configJson` 把 `lives` 写死为 `new JsonArray()`
  /// （`VodApi.java`），所以 `/vod/api?ac=config` 的 `lives` **恒为空**；而安卓的
  /// 直播源实际存在它自己的直播配置（`Config.type=1`）里。
  ///
  /// 两条信息源，先试更直接的：
  /// 1. `/manage/configs` 找出 `type==1 && active==true` 的直播配置地址；
  /// 2. 直接拉那个地址（通常是站点订阅 JSON），从中抽取 `lives`。
  ///
  /// 任何一步失败都返回空列表：**直播源是增强而非必需**，不能因为它取不到就
  /// 把整个桥接导入判为失败（站点导入本身已成功）。
  Future<List<LiveSource>> fetchLiveSources(String base) async {
    final normalized = normalizeBase(base);
    try {
      final activeUrl = await _activeLiveConfigUrl(normalized);
      if (activeUrl == null) {
        _logInfo('安卓桥接：设备未启用任何直播配置，跳过直播源同步');
        return const [];
      }
      final text = await _getText(
        Uri.parse(activeUrl),
        base: normalized,
        timeout: timeout,
      );
      final sources = extractLiveSources(text);
      _logInfo(
        '安卓桥接：拉取直播源 lives=${sources.length} '
        'config=${redactUrl(activeUrl)}',
      );
      return sources;
    } on AppError catch (error) {
      _logWarning('安卓桥接：拉取直播源失败（不影响站点导入）：${error.logLine}');
      return const [];
    } catch (error) {
      _logWarning('安卓桥接：拉取直播源失败（不影响站点导入）：$error');
      return const [];
    }
  }

  /// 从 `/manage/configs` 里找出当前启用的直播配置地址（`type=1 && active`）。
  ///
  /// 返回 `null` 表示设备没有启用直播配置（或该接口不可用）——两者都按「没有
  /// 直播源」处理，不报错。
  Future<String?> _activeLiveConfigUrl(String base) async {
    final body = await _getText(
      Uri.parse('$base/manage/configs'),
      base: base,
      timeout: timeout,
    );
    final decoded = _decodeJson(body, base);
    if (decoded is! Map) return null;
    final items = decoded['items'];
    if (items is! List) return null;
    for (final item in items) {
      final map = item is Map ? item : const {};
      if (asInt(map['type']) != 1) continue;
      if (map['active'] != true) continue;
      final url = asNonEmptyString(map['url']);
      if (url != null) return url;
    }
    return null;
  }

  /// 扫描局域网（`design/01` §4.4）。
  ///
  /// 扫描范围：本机各网段的 `/24` × 端口 [androidDefaultPort]–[androidPortRangeEnd]，
  /// 并发 [scanConcurrency]。**仅用户显式触发**，不后台自动跑。
  ///
  /// 每发现一台设备就通过 [onFound] 回调；返回全部成功识别的设备。
  Future<List<AndroidDevice>> scan({
    void Function(AndroidDevice device)? onFound,
    void Function(int done, int total)? onProgress,
    Future<bool> Function()? shouldStop,
  }) async {
    final hosts = _localSubnetHosts();
    if (hosts.isEmpty) {
      _logWarning('安卓桥接：未找到可扫描的局域网地址');
      return const [];
    }
    final candidates = <String>[
      for (final host in hosts)
        for (var port = androidDefaultPort; port <= androidPortRangeEnd; port++)
          'http://$host:$port',
    ];

    final found = <AndroidDevice>[];
    final seen = <String>{};
    var done = 0;

    for (var start = 0; start < candidates.length; start += scanConcurrency) {
      if (shouldStop != null && await shouldStop()) break;
      final batch = candidates.skip(start).take(scanConcurrency);
      final results = await Future.wait(
        batch.map((candidate) => _probeQuietly(candidate)),
      );
      for (final device in results) {
        done++;
        if (device == null) continue;
        if (!seen.add(device.uuid)) continue;
        found.add(device);
        _logInfo(
          '安卓桥接：发现设备 ${device.name} ${device.maskedUuid} '
          '@ ${device.reachableBase} type=${device.type}',
        );
        onFound?.call(device);
      }
      onProgress?.call(done, candidates.length);
    }
    return found;
  }

  /// 逐个尝试手动输入的地址（不做全网段扫描）。
  Future<BridgeDiscovery> probeOne(String base) async {
    try {
      final device = await probeDevice(base);
      return BridgeDiscovery(base: normalizeBase(base), device: device);
    } on AppError catch (error) {
      return BridgeDiscovery(base: base, error: error);
    }
  }

  // ------------------------------------------------------------------ 内部

  void _logInfo(String message) => log.info(message, scope: 'bridge');

  void _logWarning(String message) => log.warning(message, scope: 'bridge');

  Future<AndroidDevice?> _probeQuietly(String candidate) async {
    try {
      final body = await _getText(
        Uri.parse('$candidate/device'),
        base: candidate,
        timeout: scanTimeout,
      );
      return AndroidDevice.fromJson(
        _decodeJson(body, candidate),
        reachableBase: candidate,
      );
    } on AppError {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 发起 GET 并返回文本。
  ///
  /// **关键**：`Host` 头显式设为 [base] 的 `host:port`。真实网关用请求的
  /// `Host` 现算站点 `api`（`design/00` §3.2 实测），显式设置可避免中间层
  /// （隧道、反向代理、`adb forward`）改写后得到不可用的地址。
  Future<String> _getText(
    Uri uri, {
    required String base,
    required Duration timeout,
    AppErrorKind? notFoundKind,
    String? notFoundMessage,
  }) async {
    final hostPort = hostPortOf(base);
    final http.Response response;
    try {
      response = await _client.get(uri, headers: {
        'Host': hostPort,
        'Accept': 'application/json',
      }).timeout(timeout);
    } on TimeoutException catch (error) {
      throw AppError(
        AppErrorKind.bridgeUnreachable,
        '安卓设备响应超时（${timeout.inMilliseconds}ms）',
        detail: hostPort,
        retryable: true,
        cause: error,
      );
    } on SocketException catch (error) {
      throw AppError(
        AppErrorKind.bridgeUnreachable,
        '安卓设备不可达：${error.osError?.message ?? '连接失败'}',
        detail: hostPort,
        retryable: true,
        cause: error,
      );
    } catch (error) {
      throw AppError(
        AppErrorKind.bridgeUnreachable,
        '安卓设备不可达：${error.runtimeType}',
        detail: hostPort,
        retryable: true,
        cause: error,
      );
    }

    if (response.statusCode == 404 && notFoundKind != null) {
      throw AppError(
        notFoundKind,
        notFoundMessage ?? '安卓设备未提供该接口',
        detail: hostPort,
        statusCode: 404,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppError(
        AppErrorKind.bridgeUnreachable,
        '安卓设备返回 HTTP ${response.statusCode}',
        detail: hostPort,
        statusCode: response.statusCode,
        retryable: response.statusCode >= 500,
      );
    }
    return _decodeBody(response, hostPort);
  }

  String _decodeBody(http.Response response, String hostPort) {
    try {
      return utf8.decode(response.bodyBytes);
    } on FormatException {
      throw AppError(
        AppErrorKind.bridgeNotAndroid,
        '安卓设备响应不是 UTF-8 文本',
        detail: hostPort,
      );
    }
  }

  Object? _decodeJson(String body, String hostPort) {
    try {
      return jsonDecode(body);
    } on FormatException catch (error) {
      throw AppError(
        AppErrorKind.bridgeNotAndroid,
        '安卓设备响应不是合法 JSON',
        detail: '$hostPort（${error.message}）',
      );
    }
  }

  /// 本机各网段的 `/24` 主机地址（不含本机与网络/广播地址）。
  List<String> _localSubnetHosts() {
    final prefixes = <String>{};
    try {
      for (final interface in NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      ).timeout(const Duration(seconds: 3)) as List<NetworkInterface>) {
        for (final address in interface.addresses) {
          final parts = address.address.split('.');
          if (parts.length != 4) continue;
          prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
        }
      }
    } catch (error) {
      _logWarning('安卓桥接：枚举网络接口失败 $error');
      return const [];
    }
    return [
      for (final prefix in prefixes)
        for (var host = 1; host <= 254; host++) '$prefix.$host',
    ];
  }
}
