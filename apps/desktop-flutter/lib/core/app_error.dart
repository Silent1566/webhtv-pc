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

  // 字幕（§10.3「外挂字幕」「字幕轨选择」）
  // 字幕失败不影响视频播放，因此这些分类只用于提示与日志（§10.4）。
  subtitleNetwork,
  subtitleHttp,
  subtitleTooLarge,
  subtitleDecode,
  subtitleUnsupported,
  subtitleEmpty,

  // 弹幕（§21 Phase 3「字幕/弹幕可开启和关闭」）
  // 同样不得升级为播放失败，只用于提示与日志。
  danmakuNetwork,
  danmakuHttp,
  danmakuTooLarge,
  danmakuDecode,
  danmakuInvalid,
  danmakuEmpty,
  danmakuUnsupported,

  // 直播（§13）
  liveInvalid,
  liveNetwork,
  liveHttp,
  liveDecode,
  liveUnsupported,

  // 解析器（§12「解析器设计」）
  // 解析失败不影响直接换源（§12.3），这些分类只用于提示与日志。
  parseNetwork,
  parseHttp,
  parseDecode,
  parseInvalid,
  parseEmpty,
  parseUnsupportedType,

  // EPG（§13.1「EPG」、§13.3）
  // EPG 失败不影响直播播放，这些分类只用于提示与日志。
  epgNetwork,
  epgHttp,
  epgDecode,
  epgInvalid,
  epgEmpty,
  epgUnsupported,

  // TMDB 元数据增强（§27）。全部属**非致命**类别：失败不得升级为浏览或播放失败。
  // 对齐 Phase 3 字幕/弹幕/EPG 的 `is*Error` 隔离模式（§10.4）。
  tmdbNotConfigured,
  tmdbAuth,
  tmdbNetwork,
  tmdbHttp,
  tmdbDecode,
  tmdbEmpty,
  tmdbUnsupported,

  // 安卓桥接（§28）。站点导入与同步都是**用户显式触发**的操作，
  // 失败必须分类呈现（design/00 P5）：403/404/超时/空结果**不得**折叠成
  // 「导入失败」或「0 个站点」。
  bridgeUnreachable,
  bridgeNotAndroid,
  bridgeNoGateway,
  bridgeEmptySites,
  bridgeHostMismatch,
  bridgeSelfReference,

  // 同步（§28.4）。`syncPartialFailure` 必须携带 applied/skipped/failed 明细。
  syncDisabled,
  syncPeerUnauthorized,
  syncPeerUnreachable,
  syncPayloadInvalid,
  syncPayloadTooLarge,
  syncLocalWriteRejected,
  syncPartialFailure,

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
    case AppErrorKind.subtitleNetwork:
      return '字幕下载失败：网络不可达或 DNS 失败（不影响视频播放）';
    case AppErrorKind.subtitleHttp:
      return '字幕下载失败：服务器返回非 2xx 状态（不影响视频播放）';
    case AppErrorKind.subtitleTooLarge:
      return '字幕文件超过大小上限，已跳过（不影响视频播放）';
    case AppErrorKind.subtitleDecode:
      return '字幕解码失败：编码不受支持（不影响视频播放）';
    case AppErrorKind.subtitleUnsupported:
      return '字幕格式不受支持（不影响视频播放）';
    case AppErrorKind.subtitleEmpty:
      return '字幕文件为空（不影响视频播放）';
    case AppErrorKind.danmakuNetwork:
      return '弹幕下载失败：网络不可达或 DNS 失败（不影响视频播放）';
    case AppErrorKind.danmakuHttp:
      return '弹幕下载失败：服务器返回非 2xx 状态（不影响视频播放）';
    case AppErrorKind.danmakuTooLarge:
      return '弹幕文件超过大小上限，已跳过（不影响视频播放）';
    case AppErrorKind.danmakuDecode:
      return '弹幕解码失败：编码不受支持（不影响视频播放）';
    case AppErrorKind.danmakuInvalid:
      return '弹幕内容非法：既不是 Bilibili XML 也不是行式文本（不影响视频播放）';
    case AppErrorKind.danmakuEmpty:
      return '弹幕文件为空（不影响视频播放）';
    case AppErrorKind.danmakuUnsupported:
      return '弹幕格式不受支持（不影响视频播放）';
    case AppErrorKind.liveInvalid:
      return '直播源内容非法：无法解析为 M3U/TXT/JSON';
    case AppErrorKind.liveNetwork:
      return '直播源下载失败：网络不可达或 DNS 失败';
    case AppErrorKind.liveHttp:
      return '直播源下载失败：服务器返回非 2xx 状态';
    case AppErrorKind.liveDecode:
      return '直播源解码失败：编码不受支持';
    case AppErrorKind.liveUnsupported:
      return '直播源格式不受支持';
    case AppErrorKind.parseNetwork:
      return '解析失败：网络不可达或 DNS 失败';
    case AppErrorKind.parseHttp:
      return '解析失败：解析服务返回非 2xx 状态';
    case AppErrorKind.parseDecode:
      return '解析失败：响应编码或压缩不受支持';
    case AppErrorKind.parseInvalid:
      return '解析失败：解析服务响应非法';
    case AppErrorKind.parseEmpty:
      return '解析失败：解析服务没有返回可用地址';
    case AppErrorKind.parseUnsupportedType:
      return '该解析器类型在 PC 端不支持（支持 type=1/2/3 JSON 类）';
    case AppErrorKind.epgNetwork:
      return 'EPG 下载失败：网络不可达或 DNS 失败（不影响直播播放）';
    case AppErrorKind.epgHttp:
      return 'EPG 下载失败：服务器返回非 2xx 状态（不影响直播播放）';
    case AppErrorKind.epgDecode:
      return 'EPG 解码失败：编码或压缩不受支持（不影响直播播放）';
    case AppErrorKind.epgInvalid:
      return 'EPG 内容非法：不是有效的 XMLTV（不影响直播播放）';
    case AppErrorKind.epgEmpty:
      return 'EPG 没有可用节目数据（不影响直播播放）';
    case AppErrorKind.epgUnsupported:
      return 'EPG 地址协议不受支持（不影响直播播放）';
    case AppErrorKind.tmdbNotConfigured:
      return '未配置 TMDB，请在设置中填写 API Key 或 Access Token（不影响站源浏览与播放）';
    case AppErrorKind.tmdbAuth:
      return 'TMDB 鉴权失败，请检查 API Key / Access Token（不影响站源浏览与播放）';
    case AppErrorKind.tmdbNetwork:
      return 'TMDB 请求失败：网络不可达或 DNS 失败（不影响站源浏览与播放）';
    case AppErrorKind.tmdbHttp:
      return 'TMDB 请求失败：服务器返回非 2xx 状态（不影响站源浏览与播放）';
    case AppErrorKind.tmdbDecode:
      return 'TMDB 响应解析失败（不影响站源浏览与播放）';
    case AppErrorKind.tmdbEmpty:
      return 'TMDB 没有返回可用数据（不影响站源浏览与播放）';
    case AppErrorKind.tmdbUnsupported:
      return '该站点未启用 TMDB 增强（不影响站源浏览与播放）';
    case AppErrorKind.bridgeUnreachable:
      return '安卓设备不可达：连接被拒绝或超时。请确认设备与应用服务正在运行、'
          '且与电脑处于同一局域网';
    case AppErrorKind.bridgeNotAndroid:
      return '该地址不是 WebHTV 安卓服务（/device 返回了非设备信息）';
    case AppErrorKind.bridgeNoGateway:
      return '安卓设备版本过旧：缺少 T4 网关（需要含 T4 网关的版本）';
    case AppErrorKind.bridgeEmptySites:
      return '安卓设备上尚未加载任何点播配置，没有可导入的站点';
    case AppErrorKind.bridgeHostMismatch:
      return '安卓返回的站点地址不属于该设备，已拒绝导入（请确认地址填写正确）';
    case AppErrorKind.bridgeSelfReference:
      return '不能把本机自己当作安卓设备导入';
    case AppErrorKind.syncDisabled:
      return '同步未开启，请先在设置中开启';
    case AppErrorKind.syncPeerUnauthorized:
      return '该设备未授权，请先在设置中添加并确认此设备';
    case AppErrorKind.syncPeerUnreachable:
      return '同步失败：无法连接对端设备（请检查地址与网络）';
    case AppErrorKind.syncPayloadInvalid:
      return '同步数据非法：缺少必需字段或不是合法 JSON';
    case AppErrorKind.syncPayloadTooLarge:
      return '同步数据超过大小上限（8 MiB），请减少同步范围';
    case AppErrorKind.syncLocalWriteRejected:
      return '安卓拒绝写入：需在安卓的「观影记录同步」中开启「本机 API 修改」';
    case AppErrorKind.syncPartialFailure:
      return '同步部分失败（本地数据未被破坏）';
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

// ---------------------------------------------------------------------------
// TMDB 失败隔离（§27.9）
// ---------------------------------------------------------------------------

/// 全部 `tmdb*` 错误类别（均属**非致命**）。
const Set<AppErrorKind> tmdbErrorKinds = {
  AppErrorKind.tmdbNotConfigured,
  AppErrorKind.tmdbAuth,
  AppErrorKind.tmdbNetwork,
  AppErrorKind.tmdbHttp,
  AppErrorKind.tmdbDecode,
  AppErrorKind.tmdbEmpty,
  AppErrorKind.tmdbUnsupported,
};

/// 判断一个错误是否为 TMDB 错误（用于“TMDB 失败不阻断浏览/播放”的隔离判定）。
///
/// 沿用 Phase 3 字幕/弹幕/EPG 的同一模式：**只认前缀**。
bool isTmdbError(Object? error) =>
    error is AppError && tmdbErrorKinds.contains(error.kind);

/// TMDB 失败的用户提示文案（必须说明不影响站源浏览与播放）。
String describeTmdbFailure(Object? error) {
  if (error is AppError) return describeErrorKind(error.kind);
  return 'TMDB 加载失败：${error ?? "未知错误"}（不影响站源浏览与播放）';
}
