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

  /// 猫源 JS bundle 需要本机 Node 运行时，但当前进程没解析到 node。
  ///
  /// **只用于猫源分支**：普通 JSON / T4 配置不依赖 Node，不得用本类拒绝导入
  /// （2026-10-31 用户截图的缺陷就是把这个缺失提前套在全部导入上）。
  configCatRuntimeMissing,

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

  /// Web 嗅探在本机不可用：没有找到 Chromium 内核浏览器，或平台不支持。
  ///
  /// 这是**能力缺失**，不是解析失败：文案要说清「缺什么、怎么补」，
  /// 不得静默降级成直链（§12.3）。
  parseSniffUnavailable,

  /// 解析页嗅探超时（`type=0` 的 30s，或 Super 内的单次 Web 尝试）。
  parseSniffTimeout,

  /// 解析页出现人机校验（Cloudflare 等）且未能通过。
  parseSniffChallenge,

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
  syncPeerError,
  syncPortUnavailable,
  syncPayloadInvalid,
  syncPayloadTooLarge,
  syncLocalWriteRejected,
  syncPartialFailure,

  // 实时同步（`design/01` §8）。
  // 命名约定：`realtime*` 属同步协议层，`keepAlive*` 属保活/可达性层
  // （`design/02` §7）。两层必须可区分——前者指向「开关 / 安卓版本 / 游标」，
  // 后者指向「服务未运行 / 进程被冻结 / 网络不通」。合为一类会让用户
  // 无法判断该去开开关、还是去改安卓电池设置。
  realtimeSyncDisabled,
  realtimePullUnsupported,
  realtimePullDegraded,
  realtimeCursorStale,
  realtimePartialFailure,
  // 安卓 `/api/playback/history` 不返回记录更新时间（`design/01` §4.1
  // 「阻塞性发现」）。只有 `timestamp`（= 响应生成时刻）可用时置此状态：
  // 「旧不覆盖新」不可用，必须常驻披露。
  realtimePullTimestampUnreliable,
  keepAliveServiceStopped,
  keepAlivePeerFrozen,
  keepAliveNetworkUnreachable,
  keepAliveUnsupported,
  keepAliveUnauthorized,

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
    case AppErrorKind.configCatRuntimeMissing:
      // 产品策略：发行包随包内置 Node，用户无需自己安装；缺失即安装不完整。
      return '猫源配置未找到随包 Node 运行时（发行包自带 Node，缺失说明安装不完整：'
          '请重新下载/解压完整发行包，或设置 WEBHTV_NODE_RUNTIME 指向 node.exe）；'
          '普通 JSON / T4 配置无需 Node';
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
      return '该解析器类型未知，无法执行（已知类型：type=0/1/2/3/4）';
    case AppErrorKind.parseSniffUnavailable:
      return 'Web 嗅探不可用：本机没有找到 Chromium 内核浏览器'
          '（Microsoft Edge / Google Chrome / Chromium），或当前平台不支持。'
          'type=0（Web 嗅探）与 type=4（Super）需要它；'
          '可安装上述任一浏览器，或用 WEBHTV_SNIFF_BROWSER 指定浏览器路径';
    case AppErrorKind.parseSniffTimeout:
      return '解析页嗅探超时：页面在限定时间内没有产出媒体地址';
    case AppErrorKind.parseSniffChallenge:
      return '解析页出现人机校验（Cloudflare 等），未能通过验证';
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
    case AppErrorKind.syncPeerError:
      return '同步失败：对端返回错误（响应正文见详情）';
    case AppErrorKind.syncPortUnavailable:
      return '同步服务无法启动：9978–9998 端口全被占用（请先关闭占用该端口的程序）';
    case AppErrorKind.syncPayloadInvalid:
      return '同步数据非法：缺少必需字段或不是合法 JSON';
    case AppErrorKind.syncPayloadTooLarge:
      return '同步数据超过大小上限（8 MiB），请减少同步范围';
    case AppErrorKind.syncLocalWriteRejected:
      return '安卓拒绝写入：需在安卓的「观影记录同步」中开启「本机 API 修改」';
    case AppErrorKind.syncPartialFailure:
      return '同步部分失败（本地数据未被破坏）';
    case AppErrorKind.realtimeSyncDisabled:
      return '实时同步未开启，请在「安卓设置 → 实时同步」中打开总开关';
    case AppErrorKind.realtimePullUnsupported:
      // 不得说成「同步成功」或「0 条记录」——那会把「安卓端不支持」伪装成
      // 「安卓端没有数据」，用户会以为自己的历史丢了（Phase 5 P5 延续）。
      return '安卓端不支持按站点读取历史（/api/playback/history 不存在），'
          '且当前无正在播放的记录。请升级安卓端';
    case AppErrorKind.realtimePullDegraded:
      return '安卓端不支持按站点读取历史，已降级为「仅同步正在播放的记录」——'
          '息屏或未播放时无法同步';
    case AppErrorKind.realtimeCursorStale:
      return '同步游标比安卓端最新记录还新（安卓可能已重装或清数据），已自动重置游标';
    case AppErrorKind.realtimePartialFailure:
      return '实时同步部分失败（本地数据未被破坏，游标未推进，下轮重试）';
    case AppErrorKind.realtimePullTimestampUnreliable:
      return '安卓端未提供记录更新时间（只给了响应生成时刻），'
          '「旧不覆盖新」不可用——已改用内容比对保证不重复，'
          '但两端进度不一致时可能无法判定谁更新';
    case AppErrorKind.keepAliveServiceStopped:
      return '安卓的局域网服务未运行。请在安卓打开「管理页」并保持它运行';
    case AppErrorKind.keepAlivePeerFrozen:
      return '安卓进程被系统冻结（端口可连但无响应）。'
          '请在安卓设置中允许本应用后台运行（电池 → 不受限制 / 允许自启动）';
    case AppErrorKind.keepAliveNetworkUnreachable:
      return '网络不可达：请确认 PC 与安卓在同一局域网，且安卓未切换 WiFi';
    case AppErrorKind.keepAliveUnsupported:
      return '安卓端不支持保活探测（/manage/session 与 /device 都不存在），已停止心跳。'
          '请升级安卓端';
    case AppErrorKind.keepAliveUnauthorized:
      return '拉取端点鉴权失败：请检查 token 与白名单设置';
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
    this.diagnostic,
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

  /// 只进日志的请求上下文（动作、脱敏 URL、query 参数名）。
  ///
  /// **为什么不放 [detail]**：`detail` 会进 [userMessage] 显示在横幅里，
  /// 请求上下文只对排障有用，对用户是噪声。
  final String? diagnostic;

  bool get isCancellation => kind == AppErrorKind.siteCancelled;

  /// 单行日志文本，不含原始异常堆栈。
  String get logLine {
    final buffer = StringBuffer('${kind.name}: $message');
    if (detail != null && detail!.isNotEmpty) buffer.write(' | detail=$detail');
    if (statusCode != null) buffer.write(' | status=$statusCode');
    return buffer.toString();
  }

  /// 多行诊断块：单行摘要 + 请求上下文 + 堆栈（有则带）。
  ///
  /// **为什么需要**：用户反馈「详情加载失败」只有一句站源文案，看不到是哪次
  /// 请求、也没有堆栈（2026-10-20）。[logLine] 保持单行不变，避免高频日志膨胀；
  /// 失败路径改用本 getter 记录可复现的证据。
  String get logBlock {
    final buffer = StringBuffer(logLine);
    if (diagnostic != null && diagnostic!.isNotEmpty) {
      buffer.write(' | $diagnostic');
    }
    final stack = stackTrace;
    if (stack != null) {
      const maxFrames = 12;
      final frames = stack
          .toString()
          .trimRight()
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .take(maxFrames)
          .join('\n');
      if (frames.isNotEmpty) buffer.write('\n$frames');
    }
    return buffer.toString();
  }

  /// 补上排障信息（请求上下文 / 堆栈）。已有的不覆盖，返回新实例。
  AppError withDiagnostics({String? diagnostic, StackTrace? stackTrace}) =>
      AppError(
        kind,
        message,
        detail: detail,
        retryable: retryable,
        cause: cause,
        stackTrace: this.stackTrace ?? stackTrace,
        statusCode: statusCode,
        diagnostic: this.diagnostic ?? diagnostic,
      );

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

/// 实时同步层错误类别（`design/01` §8）。
///
/// 与 [keepAliveErrorKinds] **互斥**：两者指向的用户动作完全不同
/// （开开关/升级安卓 vs 修安卓后台设置/查网络），合并会丢掉可操作性。
const Set<AppErrorKind> realtimeErrorKinds = {
  AppErrorKind.realtimeSyncDisabled,
  AppErrorKind.realtimePullUnsupported,
  AppErrorKind.realtimePullDegraded,
  AppErrorKind.realtimeCursorStale,
  AppErrorKind.realtimePartialFailure,
  AppErrorKind.realtimePullTimestampUnreliable,
};

/// 保活/可达性层错误类别（`design/02` §7）。
const Set<AppErrorKind> keepAliveErrorKinds = {
  AppErrorKind.keepAliveServiceStopped,
  AppErrorKind.keepAlivePeerFrozen,
  AppErrorKind.keepAliveNetworkUnreachable,
  AppErrorKind.keepAliveUnsupported,
  AppErrorKind.keepAliveUnauthorized,
};

/// 判断是否为实时同步错误。
bool isRealtimeError(Object? error) =>
    error is AppError && realtimeErrorKinds.contains(error.kind);

/// 判断是否为保活错误。
bool isKeepAliveError(Object? error) =>
    error is AppError && keepAliveErrorKinds.contains(error.kind);

/// TMDB 失败的用户提示文案（必须说明不影响站源浏览与播放）。
String describeTmdbFailure(Object? error) {
  if (error is AppError) return describeErrorKind(error.kind);
  return 'TMDB 加载失败：${error ?? "未知错误"}（不影响站源浏览与播放）';
}
