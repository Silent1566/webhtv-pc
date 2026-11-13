/// 解析器 Web 嗅探内核契约（设计文档 §12.1 的 `type=0` Web 嗅探与
/// `type=4` Super）。
///
/// # 为什么需要这一层
///
/// `type=1/2/3` 都是「发一个 HTTP 请求、从响应里取地址」，纯 HTTP 层就能
/// 完成（`lib/services/parse_service.dart`）。`type=0`/`type=4` 不同：地址
/// 是解析页自己用 JS 算出来并请求的，必须让一个真正的浏览器把页面跑起来，
/// 再从它发出的网络请求里把媒体地址捞出来。安卓对应实现是
/// `CustomWebView.shouldInterceptRequest` + `Sniffer.getScript` + DOM 探测。
///
/// # 分层
///
/// - 本文件：与实现无关的**契约**（请求、事件、结果、规则、媒体判定、超时）；
/// - `sniff_transport.dart`：浏览器进程与 CDP 传输的**契约**；
/// - `chromium_sniffer.dart`：用系统 Chromium 内核浏览器执行嗅探；
/// - `sniff_engine_factory.dart`：平台选择与不可用时的明确失败。
///
/// 契约里不出现 `dart:io`/`dart:ui`：解析层与测试只依赖这些类型。
library;

/// 嗅探超时档位（对齐安卓 `Constant`）。
///
/// 安卓三个常量：`TIMEOUT_PARSE_DEF=15s`、`TIMEOUT_PARSE_WEB=30s`、
/// `TIMEOUT_PARSE_SUPER=90s`；Super 内单次 Web 尝试为
/// `max(20s, TIMEOUT_PARSE_WEB - 5s)`（`ParseJob.superParse`）。
abstract final class SniffTimeouts {
  /// `Constant.TIMEOUT_PARSE_DEF`：`type=1/2/3` 请求上限。
  static const Duration parseDefault = Duration(seconds: 15);

  /// `type=0` 嗅探上限。
  ///
  /// 180s（用户 2026-11-13 指定）：真实解析页要跑完签名脚本、多次 XHR，甚至
  /// 播放器初始化才产出地址；30s 对慢站（TTFB 高 + 多跳）会被误判成超时。
  static const Duration parseWeb = Duration(seconds: 180);

  /// `type=4` 整体上限（与单次嗅探同量级：Super 把多条腿放进这一个预算里）。
  static const Duration parseSuper = Duration(seconds: 180);

  /// Super 内单个 Web 嗅探尝试的上限。
  ///
  /// 不照搬安卓 `parseWeb - 5s`（180s 预算下会变成 175s，只够试一条 web 腿）。
  /// 取 60s：180s 内还能轮到后面两条，「xmflv → hls.one → m3u8.tv」的优先级
  /// 顺序才有意义。
  static const Duration superWebAttempt = Duration(seconds: 60);
}

/// 配置里的嗅探规则（安卓 `bean/Rule`：`hosts`/`regex`/`exclude`/`script`
/// 的可用子集）。
///
/// 为什么需要：部分解析页算出的地址没有 `.m3u8` 之类的后缀，默认判定抓不到，
/// 只有配置给出的 `regex` 能命中；`script` 则是让页面「点一下/播一下」的注入。
class SniffRule {
  const SniffRule({
    this.hosts = const [],
    this.regexes = const [],
    this.excludes = const [],
    this.scripts = const [],
  });

  /// 规则生效的主机（后缀或包含匹配，对齐安卓 `Util.containOrMatch`）。
  final List<String> hosts;

  /// 命中即认为是被嗅探目标（包含或正则匹配，对齐 `Sniffer.isVideoFormat`）。
  final List<String> regexes;

  /// 命中即排除（优先于 [regexes]）。
  final List<String> excludes;

  /// 页面加载后注入的脚本（对齐 `Sniffer.getScript`）。
  final List<String> scripts;

  bool get isEmpty =>
      hosts.isEmpty && regexes.isEmpty && excludes.isEmpty && scripts.isEmpty;

  /// 该规则是否作用于 [host]：任一 host 模式后缀匹配或包含匹配。
  bool matchesHost(String host) {
    if (hosts.isEmpty) return false;
    final lower = host.toLowerCase();
    for (final pattern in hosts) {
      final normalized = pattern.trim().toLowerCase();
      if (normalized.isEmpty) continue;
      if (_containsOrMatch(lower, normalized)) return true;
    }
    return false;
  }

  /// [url] 是否被本规则接受：先用 [excludes] 否决，再要求命 [regexes]。
  bool accepts(String url) {
    for (final exclude in excludes) {
      final pattern = exclude.trim();
      if (pattern.isEmpty) continue;
      if (url.contains(pattern) || _regexMatches(pattern, url)) return false;
    }
    for (final regex in regexes) {
      final pattern = regex.trim();
      if (pattern.isEmpty) continue;
      if (url.contains(pattern) || _regexMatches(pattern, url)) return true;
    }
    return false;
  }

  static bool _containsOrMatch(String value, String pattern) {
    if (value.contains(pattern)) return true;
    return _regexMatches(pattern, value);
  }

  static bool _regexMatches(String pattern, String value) {
    try {
      return RegExp(pattern).hasMatch(value);
    } on FormatException {
      return false;
    }
  }

  static List<SniffRule> fromConfig(Object? raw) {
    if (raw is! List) return const [];
    final rules = <SniffRule>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final rule = SniffRule(
        hosts: _stringList(item['hosts']),
        regexes: _stringList(item['regex']),
        excludes: _stringList(item['exclude']),
        scripts: _stringList(item['script']),
      );
      if (!rule.isEmpty) rules.add(rule);
    }
    return rules;
  }

  static List<String> _stringList(Object? raw) {
    if (raw is String) return raw.trim().isEmpty ? const [] : [raw];
    if (raw is! List) return const [];
    return raw
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
  }
}

/// 一次嗅探请求。
class SniffRequest {
  const SniffRequest({
    required this.pageUrl,
    required this.timeout,
    this.headers = const {},
    this.clickScript,
    this.rules = const [],
    this.revealWindow = true,
    this.source,
  });

  /// 要打开的解析页地址（安卓：`parse.url + webUrl`）。
  final String pageUrl;

  /// 本次嗅探的上限（[SniffTimeouts.parseWeb] 或 [SniffTimeouts.superWebAttempt]）。
  final Duration timeout;

  /// 解析器 `ext.header`（UA / Referer / Cookie），对齐安卓
  /// `WebSniffHeaders.forPage`。实现方应把它落到浏览器的请求头上。
  final Map<String, String> headers;

  /// 站点/结果自带的 `click` JS（安卓 `ParseJob.getClick`），页面加载后先执行。
  final String? clickScript;

  /// 配置给出的嗅探规则（`config.rules`）。
  final List<SniffRule> rules;

  /// 遇到人机校验（Cloudflare 等）时是否允许把窗口拉到可见（R-G 决策：
  /// 离屏优先，需要人机交互时再弹出）。
  final bool revealWindow;

  /// 诊断来源标记（`parse:<name>` / `jx:<name>`）。
  final String? source;
}

/// 嗅探过程中发生的事件。实现方按发现顺序发出，最后一个事件结束本次嗅探。
sealed class SniffEvent {
  const SniffEvent();
}

/// 解析页已加载（用于诊断与 click 注入时机）。
class SniffPageLoaded extends SniffEvent {
  const SniffPageLoaded({required this.pageUrl, this.title});
  final String pageUrl;
  final String? title;
}

/// 抓到了候选媒体地址——本次嗅探成功。
class SniffCandidate extends SniffEvent {
  const SniffCandidate({
    required this.url,
    this.headers = const {},
    this.via = 'network',
  });

  final String url;

  /// 该媒体请求自身携带的 UA / Referer / Cookie（对齐安卓
  /// `shouldInterceptRequest` 的 request headers）。只保留这三类，避免把
  /// Cookie/Token 全量写进日志（§12.3）。
  final Map<String, String> headers;

  /// 发现途径：`network`（请求拦截）/ `dom`（DOM/performance 探测）/
  /// `script`（规则脚本回调）。
  final String via;
}

/// 页面出现人机校验（Cloudflare 等）。实现方可在 [SniffSession.reveal] 后继续。
class SniffChallenge extends SniffEvent {
  const SniffChallenge({this.reason});
  final String? reason;
}

/// 本次嗅探失败（页面错误、进程崩溃、被停止等）。
class SniffFailed extends SniffEvent {
  const SniffFailed({required this.message, this.detail});
  final String message;
  final String? detail;
}

/// 嗅探成功产物。
class SniffResult {
  const SniffResult({required this.url, required this.headers, required this.via});
  final String url;
  final Map<String, String> headers;
  final String via;
}

/// 一次进行中的嗅探。
///
/// 生命周期：`start` → 若干 [SniffEvent] → 成功/失败事件 → [stop]（调用方
/// 必须在 `finally` 里 stop，失败不得泄漏浏览器进程）。
abstract class SniffSession {
  /// 事件流。成功事件是 [SniffCandidate]；失败是 [SniffFailed]；两者之后流关闭。
  Stream<SniffEvent> get events;

  /// 让页面获得一次真实用户点击（安卓 `click` 之外的兜底）：用于必须点
  /// 「播放」按钮才产出地址的解析页。
  Future<void> click();

  /// 把离屏窗口拉到前台，供用户完成人机校验。
  Future<void> reveal();

  /// 当前会话是否具备「把窗口亮出来」的能力（无头模式下为 `false`）。
  ///
  /// 解析层据此决定：遇到人机校验是「亮窗口继续等」，还是**立刻**如实失败——
  /// 无头模式硬等只会把一次明确的能力缺失拖成 180s 超时。
  bool get canReveal => false;

  /// 结束并清理（幂等）。
  Future<void> stop();
}

/// 嗅探引擎：把一次 [SniffRequest] 变成 [SniffSession]。
abstract class SniffEngine {
  /// 启动一次嗅探。平台/环境不满足时抛 [SniffUnavailableException]。
  Future<SniffSession> start(SniffRequest request);

  /// 释放引擎持有的长期资源（实现可空实现）。
  Future<void> dispose();
}

/// 嗅探在本机不可用（没有可用的浏览器内核、平台不支持）。
///
/// 这是**能力缺失**，不是解析失败：文案必须告诉用户「缺什么、怎么补」，
/// 不得静默降级为直链（§12.3）。
class SniffUnavailableException implements Exception {
  const SniffUnavailableException(this.message, {this.detail});
  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}

/// 嗅探执行失败（浏览器启动失败、进程退出、页面错误）。
class SniffException implements Exception {
  const SniffException(this.message, {this.detail});
  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}

/// 安卓 `Sniffer.SNIFFER` 的等价正则。
final RegExp _mediaPattern = RegExp(
  r'https?://[^\s]{12,}\.(?:m3u8|mp4|mkv|flv|mp3|m4a|aac|mpd)(?:\?.*)?'
  r'|https?://.*?video/tos[^\s]*'
  r'|rtmp:[^\s]+',
);

/// 占位/错误地址（安卓 `CustomWebView.isPlaceholderVideoUrl`）。
bool _isPlaceholder(String lowerUrl) =>
    lowerUrl.contains('/404_') ||
    lowerUrl.contains('/404.mp4') ||
    lowerUrl.contains('/error.mp4');

/// 判定 [url] 是否是本次要嗅探的媒体地址（对齐安卓
/// `Sniffer.isVideoFormat` + `CustomWebView` 的占位过滤）。
///
/// 顺序与安卓一致：规则 `exclude` 否决 → 规则 `regex` 命中 → 结构否决
/// （`url=http`/`v=http`/`.html`）→ 默认后缀正则。
bool isSniffMediaUrl(String url, {List<SniffRule> rules = const []}) {
  final trimmed = url.trim();
  if (trimmed.length < 12) return false;
  final lower = trimmed.toLowerCase();
  if (_isPlaceholder(lower)) return false;
  final matched = _matchingRules(trimmed, rules);
  for (final rule in matched) {
    if (!rule.accepts(trimmed)) return false;
  }
  for (final rule in matched) {
    for (final regex in rule.regexes) {
      final pattern = regex.trim();
      if (pattern.isEmpty) continue;
      if (trimmed.contains(pattern)) return true;
      try {
        if (RegExp(pattern).hasMatch(trimmed)) return true;
      } on FormatException {
        continue;
      }
    }
  }
  if (lower.contains('url=http') || lower.contains('v=http')) return false;
  if (lower.contains('.html')) return false;
  return _mediaPattern.hasMatch(trimmed);
}

/// 命中的规则（按页面主机或候选地址主机判定）。
List<SniffRule> _matchingRules(String url, List<SniffRule> rules) {
  if (rules.isEmpty) return const [];
  final host = Uri.tryParse(url)?.host ?? '';
  final matched = <SniffRule>[];
  for (final rule in rules) {
    if (rule.hosts.isEmpty || rule.matchesHost(host)) matched.add(rule);
  }
  return matched;
}

/// 从原始请求头里只保留播放需要的三类（§12.3 不落完整 Cookie/Token）。
Map<String, String> sniffHeadersOf(Map<String, String> raw) {
  final result = <String, String>{};
  for (final entry in raw.entries) {
    final key = entry.key.toLowerCase();
    if (key == 'user-agent') result['User-Agent'] = entry.value;
    if (key == 'referer') result['Referer'] = entry.value;
    if (key == 'cookie') result['Cookie'] = entry.value;
  }
  return result;
}
