/// WebHTV PC 统一错误模型。
///
/// 设计要求（设计文档 §8.4、§10.4）：
/// - 不允许把 HTML 错误页当作 JSON/XML 解析成功；
/// - 单站点失败不得阻塞其他站点；
/// - 播放失败必须可定位到具体阶段，且不能卡死 UI。
///
/// 因此所有跨层错误都归一化为 [AppError]，并携带稳定的 [AppErrorKind]，
/// 让 UI 能给出可定位提示，而不是展示原始异常文本。
library;

enum AppErrorKind {
  // 配置导入
  configSchemeUnsupported,
  configNetwork,
  configHttp,
  configRedirect,
  configTooLarge,
  configDecode,
  configInvalid,
  configMsg,
  configRepository,
  configNotFound,

  // 站点与协议
  siteUnsupported,
  siteNetwork,
  siteHttp,
  siteParse,
  siteTimeout,
  siteCancelled,
  siteBusiness,
  siteEmptyApi,

  // 播放
  playbackUrlMissing,
  playbackParserRequired,
  playbackUnsupportedScheme,

  // 系统
  storage,
  unknown,
}

/// 面向用户的错误分类文案。UI 直接展示该文案 + `detail`。
String describeErrorKind(AppErrorKind kind) {
  switch (kind) {
    case AppErrorKind.configSchemeUnsupported:
      return '配置地址协议不受支持（仅允许 http/https、本地文件或 JSON 文本）';
    case AppErrorKind.configNetwork:
      return '配置下载失败：网络不可达或 DNS 失败';
    case AppErrorKind.configHttp:
      return '配置下载失败：服务器返回非 2xx 状态';
    case AppErrorKind.configRedirect:
      return '配置重定向次数超过限制（最多 5 次）';
    case AppErrorKind.configTooLarge:
      return '配置响应超过大小上限（8 MiB）';
    case AppErrorKind.configDecode:
      return '配置解码失败：编码或压缩格式不受支持';
    case AppErrorKind.configInvalid:
      return '配置内容非法：不是有效的 JSON 配置';
    case AppErrorKind.configMsg:
      return '配置声明了 msg，按兼容语义拒绝加载';
    case AppErrorKind.configRepository:
      return '配置仓库展开失败';
    case AppErrorKind.configNotFound:
      return '配置文件不存在或无法读取';
    case AppErrorKind.siteUnsupported:
      return '站点运行时未安装或未支持';
    case AppErrorKind.siteNetwork:
      return '站点请求失败：网络不可达或 DNS 失败';
    case AppErrorKind.siteHttp:
      return '站点请求失败：上游返回非 2xx 状态';
    case AppErrorKind.siteParse:
      return '站点响应无法解析：不是预期的 JSON/XML/媒体';
    case AppErrorKind.siteTimeout:
      return '站点请求超时';
    case AppErrorKind.siteCancelled:
      return '站点请求已取消';
    case AppErrorKind.siteBusiness:
      return '站点返回业务错误';
    case AppErrorKind.siteEmptyApi:
      return '站点未配置 api 入口';
    case AppErrorKind.playbackUrlMissing:
      return '播放地址缺失';
    case AppErrorKind.playbackParserRequired:
      return '该剧集需要解析器或 Spider 运行时（MVP-A 未实现）';
    case AppErrorKind.playbackUnsupportedScheme:
      return '播放地址协议不受支持';
    case AppErrorKind.storage:
      return '本地存储读写失败';
    case AppErrorKind.unknown:
      return '未知错误';
  }
}

/// 归一化错误。`detail` 只放可安全展示的信息；敏感信息必须先经过脱敏。
class AppError implements Exception {
  AppError(
    this.kind,
    this.message, {
    this.detail,
    this.retryable = false,
    this.cause,
    this.stackTrace,
    this.statusCode,
  });

  final AppErrorKind kind;

  /// 面向用户的简短说明。
  final String message;

  /// 可定位的补充信息，例如站点 key、请求 action 或解析字段。
  final String? detail;

  /// 是否值得重试（超时、网络错误为 true）。
  final bool retryable;

  final Object? cause;
  final StackTrace? stackTrace;
  final int? statusCode;

  bool get isCancellation => kind == AppErrorKind.siteCancelled;

  /// 单行日志文本，不含原始异常堆栈。
  String get logLine {
    final buffer = StringBuffer('${kind.name}: $message');
    if (detail != null && detail!.isNotEmpty) buffer.write(' | detail=$detail');
    if (statusCode != null) buffer.write(' | status=$statusCode');
    return buffer.toString();
  }

  String get userMessage {
    final buffer = StringBuffer(describeErrorKind(kind));
    if (message.isNotEmpty && message != describeErrorKind(kind)) {
      buffer.write('：$message');
    }
    if (detail != null && detail!.isNotEmpty) buffer.write('（$detail）');
    return buffer.toString();
  }

  @override
  String toString() => logLine;
}
