/// 播放打开策略：预取、失败回退与失败分类（迭代 2 Wave 1）。
///
/// 控制一次打开的显式探测、失败重试与回退；下一集的媒体预载不经过此策略。
///
/// 依赖方向：`player_options.dart` → 本文件（[PlayerOptions.openPolicy]）。
/// 本文件不依赖 Flutter，也不依赖播放器；HTTP 探测走注入的
/// [PlaybackPrefetchProbe]，控制器里不出现任何 `HttpClient`。
library;

import 'dart:async';

import 'package:http/http.dart' as http;

/// 播放错误分类（§10.4）。
///
/// 声明放在 core 而不是控制器：失败分类要能被单测直接断言，而且 [PlaybackOpenPolicy]
/// 的「可回退 / 不可回退」判定只以它为准。控制器侧通过 `player_controller.dart`
/// 的 re-export 继续可见，调用点无需改 import。
enum PlayerFailureKind {
  /// 403/404：链接失效，建议换线路。
  notFound,

  /// 401：Header 或 Cookie 丢失。
  unauthorized,

  /// DNS/连接失败。
  network,

  /// 超时。
  timeout,

  /// 格式不支持。
  unsupportedFormat,

  /// 其他加载失败。
  loadFailed,
}

String describePlayerFailure(PlayerFailureKind kind) {
  switch (kind) {
    case PlayerFailureKind.notFound:
      return '播放地址失效（403/404），建议切换线路或更新配置';
    case PlayerFailureKind.unauthorized:
      return '播放地址需要鉴权（401），请检查站点 Header 或 Cookie 是否完整';
    case PlayerFailureKind.network:
      return '网络不可达：请检查网络、代理或 DNS 设置';
    case PlayerFailureKind.timeout:
      return '播放超时：请重试一次或切换线路';
    case PlayerFailureKind.unsupportedFormat:
      return '播放器不支持该格式，请切换线路';
    case PlayerFailureKind.loadFailed:
      return '播放加载失败，请重试或切换线路';
  }
}

/// 从引擎错误文本推断失败分类。
PlayerFailureKind classifyPlayerError(String message) {
  final lowered = message.toLowerCase();
  if (lowered.contains('403') || lowered.contains('404')) {
    return PlayerFailureKind.notFound;
  }
  if (lowered.contains('401')) return PlayerFailureKind.unauthorized;
  if (lowered.contains('timed out') || lowered.contains('timeout')) {
    return PlayerFailureKind.timeout;
  }
  if (lowered.contains('could not resolve') ||
      lowered.contains('name or service not known') ||
      lowered.contains('connection refused') ||
      lowered.contains('no route to host') ||
      lowered.contains('failed to connect')) {
    return PlayerFailureKind.network;
  }
  if (lowered.contains('could not open codec') ||
      lowered.contains('unsupported') ||
      lowered.contains('codec not found')) {
    return PlayerFailureKind.unsupportedFormat;
  }
  return PlayerFailureKind.loadFailed;
}

/// 失败对「回退阶梯」的友好程度（`docs/phase9/design/01` §5）。
enum PlaybackFailureClass {
  /// 解析 / 线路 / 网络层面的失败：换线路、重解析、重试**都可能**成功。
  recoverable('recoverable', '可回退'),

  /// 解码器缺失、格式不支持、其他引擎内部失败：换地址解决不了。
  nonRecoverable('non_recoverable', '不可回退');

  const PlaybackFailureClass(this.id, this.label);

  /// 日志/诊断用的稳定标识，**不得改名**。
  final String id;

  final String label;
}

/// 失败分类 → 是否能靠「换地址」解决。
///
/// 判据只看失败的性质，不看用户设置；「允不允许回退」是 [PlaybackOpenPolicy] 的事：
///
/// - 可回退：403/404（线路失效）、401（换线路或补 Header）、网络不可达、超时；
/// - 不可回退：`could not open codec` / 不支持的格式（同一台机器上再换几条线路
///   也一样打不开），以及其余无法归因的加载失败——盲试只会拖长黑屏时间。
PlaybackFailureClass classifyPlaybackFailureClass(PlayerFailureKind kind) {
  switch (kind) {
    case PlayerFailureKind.notFound:
    case PlayerFailureKind.unauthorized:
    case PlayerFailureKind.network:
    case PlayerFailureKind.timeout:
      return PlaybackFailureClass.recoverable;
    case PlayerFailureKind.unsupportedFormat:
    case PlayerFailureKind.loadFailed:
      return PlaybackFailureClass.nonRecoverable;
  }
}

/// 预取探测：注入点，控制器**只调用**、不关心实现。
///
/// [url] 是即将交给播放器的地址，[headers] 与 `open()` 用的是同一份
/// （Referer/UA/Cookie 缺一不可，否则探测结果没有意义）。
/// 抛异常表示探测失败；控制器只记一笔，不阻断开播。
typedef PlaybackPrefetchProbe =
    Future<void> Function(String url, Map<String, String> headers);

/// 探测失败的原因（地址不可用、状态码异常、超时）。
class PlaybackPrefetchException implements Exception {
  const PlaybackPrefetchException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'PlaybackPrefetchException($message${statusCode == null ? '' : ', status=$statusCode'})';
}

/// 默认探测实现：对地址发一次 `HEAD`，**不下载媒体数据**。
///
/// 一次探测只关心的三件事：能不能建连、返回码是不是「地址还在」、耗时是否离谱。
/// 405/501 表示服务端不支持 HEAD——那时地址本身是通的，不算失败。
/// 每次调用自建并关闭 client，因此可以无状态复用，也不会把连接留在池子里。
Future<void> httpPlaybackPrefetchProbe(
  String url,
  Map<String, String> headers,
) async {
  final Uri uri;
  try {
    uri = Uri.parse(url);
  } on FormatException catch (error) {
    throw PlaybackPrefetchException('地址不可解析：${error.message}');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw PlaybackPrefetchException('不是 http(s) 地址：${uri.scheme}');
  }
  final client = http.Client();
  try {
    final request = http.Request('HEAD', uri)
      ..headers.addAll(headers)
      ..followRedirects = true;
    final response = await client.send(request).timeout(defaultPrefetchTimeout);
    // 取出并丢弃响应体：HEAD 通常没有体，但代理偶尔会带，留着会占住连接。
    await response.stream.drain<void>();
    final status = response.statusCode;
    if (status == 405 || status == 501) return;
    if (status < 200 || status >= 400) {
      throw PlaybackPrefetchException(
        '探测返回 HTTP $status',
        statusCode: status,
      );
    }
  } on TimeoutException catch (error) {
    throw PlaybackPrefetchException('探测超时：${error.message ?? ''}');
  } on http.ClientException catch (error) {
    throw PlaybackPrefetchException('探测请求失败：${error.message}');
  } finally {
    client.close();
  }
}

/// 单次探测的时间上限（内置实现与策略默认值共用）。
const Duration defaultPrefetchTimeout = Duration(seconds: 8);

/// 一次「打开播放地址」的策略。
///
/// 三个字段各自对应一个真实决定，没有多余的开关：
/// - [preload]：调用方是否显式要求开播前探测；
/// - [fallbackOnFailure]：失败后是否允许重试/回退（`PlayerOptions.failureFallback`
///   不是「不自动回退」时为真）；
/// - [retryLimit]：同 URL 原地重试的上限，默认 1（= 历史行为「重试一次」）。
///
/// **默认值与历史行为逐项一致**：`retryLimit = 1`、只对超时/网络重试
/// （[shouldRetryInPlace]），预取默认关。
class PlaybackOpenPolicy {
  const PlaybackOpenPolicy({
    this.preload = false,
    this.fallbackOnFailure = true,
    this.retryLimit = defaultRetryLimit,
    this.prefetch,
    this.prefetchTimeout = defaultPrefetchTimeout,
  });

  /// 出厂策略：等价于 `openWithRetry` 在此前的固定行为。
  const PlaybackOpenPolicy.defaults() : this();

  /// 原地重试上限的默认值（历史行为：只重试一次）。
  static const int defaultRetryLimit = 1;

  /// 允许配置的最大重试次数；超过这个数只是把黑屏时间拉长。
  static const int maxRetryLimit = 3;

  /// 是否先发探测（覆盖「解析预取」的地址可用性检查）。
  final bool preload;

  /// 失败后是否允许重试 / 回退。false 表示把错误原样交给调用方。
  final bool fallbackOnFailure;

  /// 同 URL 原地重试上限（不是回退阶梯的层数）。
  final int retryLimit;

  /// 预取探测实现；null 时控制器用自己注入的，再退到 [httpPlaybackPrefetchProbe]。
  final PlaybackPrefetchProbe? prefetch;

  /// 单次预取的时间上限；超时按「探测失败」处理，不阻断开播。
  final Duration prefetchTimeout;

  /// 该失败值得在本控制器内**原地**重试吗（同一地址、同一线路）。
  ///
  /// 只治瞬时失败：403/404、401 再打同一个地址不会变好，那是回退阶梯的活
  /// （见 [allowsFallback]）。[fallbackOnFailure] 关掉时一律不重试。
  bool shouldRetryInPlace(PlayerFailureKind? kind) {
    // 原地重试与「自动换线」是两件事：重试只针对瞬时故障（超时/网络），
    // 在回退档位为 off 时也必须保留——否则把回退默认关掉会顺手把
    // 「超时重试一次」这个既有行为一起关掉，属默认行为变更。
    if (kind == null || retryLimit <= 0) return false;
    return kind == PlayerFailureKind.timeout || kind == PlayerFailureKind.network;
  }

  /// 调用方（播放页）该不该跑「线路 → 解析 → 换源」的阶梯。
  ///
  /// 只看两件事：用户开没开回退，以及这个失败是不是换地址能解决的。
  bool allowsFallback(PlayerFailureKind? kind) =>
      fallbackOnFailure &&
      kind != null &&
      classifyPlaybackFailureClass(kind) == PlaybackFailureClass.recoverable;

  PlaybackOpenPolicy copyWith({
    bool? preload,
    bool? fallbackOnFailure,
    int? retryLimit,
    PlaybackPrefetchProbe? prefetch,
    Duration? prefetchTimeout,
  }) => PlaybackOpenPolicy(
    preload: preload ?? this.preload,
    fallbackOnFailure: fallbackOnFailure ?? this.fallbackOnFailure,
    retryLimit: retryLimit ?? this.retryLimit,
    prefetch: prefetch ?? this.prefetch,
    prefetchTimeout: prefetchTimeout ?? this.prefetchTimeout,
  );

  @override
  bool operator ==(Object other) =>
      other is PlaybackOpenPolicy &&
      other.preload == preload &&
      other.fallbackOnFailure == fallbackOnFailure &&
      other.retryLimit == retryLimit &&
      identical(other.prefetch, prefetch) &&
      other.prefetchTimeout == prefetchTimeout;

  @override
  int get hashCode => Object.hash(
    preload,
    fallbackOnFailure,
    retryLimit,
    prefetch,
    prefetchTimeout,
  );

  @override
  String toString() =>
      'PlaybackOpenPolicy(preload=$preload fallback=$fallbackOnFailure '
      'retry=$retryLimit probe=${prefetch == null ? 'default' : 'injected'})';
}
