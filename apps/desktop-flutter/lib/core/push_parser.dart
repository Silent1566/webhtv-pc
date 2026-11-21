/// 推送文本解析与推送播放请求构造（安卓 `utils/PushParser.java` 的 Dart 移植）。
///
/// 为什么移植：安卓把三件事写在这个类里——`播放地址|剧名` 的末尾剧名语法、
/// `push://` 前缀剥离、"从一段夹杂说明的文字里嗅出播放地址"。PC 接收端必须
/// 接受安卓已经能接受的输入，否则同一个链接在两端行为不一致。
///
/// 纯逻辑：不依赖 Flutter、不碰磁盘、不发网络请求。
library;

import 'playback_request.dart';
import 'protocol.dart';

/// PC 侧推送的合成站点键（对齐安卓 `SiteApi.PUSH = "push_agent"` 的语义）。
///
/// 历史记录按站点分组，推送内容集中在这一个合成站点下，不会混进任何真实配置。
const String pushSiteKey = 'push_agent';

/// 推送合成的线路名（历史卡片的来源标签）。
const String pushSourceName = '推送';

/// 推送手填剧名的传递键（放进 Vod.extra，详情加载时用它压过站源片名）。
///
/// 为什么用 extra 而不是给 loadDetail 加参数：详情页在 7 个测试里被覆写，加一个
/// 公开参数会让这些替身全部编译失败；extra 是既有协议里的自由字段，不破坏签名。
const String pushDisplayNameExtraKey = 'push_display_name';

/// 没有任何可用片名时的兜底标题。
const String pushFallbackTitle = '推送媒体';

/// 播放地址嗅探（安卓 `PUSH_URL`）。
final RegExp _pushUrlPattern = RegExp(r'(https?|thunder|magnet|ed2k|video):\S+');

/// 请求头行（安卓 `COMMON_HEADER`）：带 `|` 的整段文字里，这类后缀不是片名。
final RegExp _commonHeaderPattern = RegExp(
  r'^(user-agent|referer|referrer|cookie|origin|authorization|range|accept|content-type)\s*[:=].+',
  caseSensitive: false,
);

/// 明显的媒体位置（安卓 `NETWORK_LOCATION`）。
final RegExp _networkLocationPattern = RegExp(
  r'^(https?|file|content|smb|nfs|ftp|rtsp|video)://\S+$',
  caseSensitive: false,
);

/// Windows 盘符路径（安卓 `WINDOWS_PATH`）。
final RegExp _windowsPathPattern = RegExp(r'^[a-z]:[\\/].+', caseSensitive: false);

/// 一次推送解析结果。
class PushParsed {
  const PushParsed({required this.url, this.title = ''});

  /// 播放地址（已剥离 `push://`、已嗅探出裸链接）。
  final String url;

  /// 显式剧名：只有 `url|剧名` 语法或独立剧名字段才有值。
  final String title;

  bool get hasExplicitTitle => title.isNotEmpty;

  /// 安卓 `Parsed.getName()`：有剧名用剧名，否则用地址。
  String get name => hasExplicitTitle ? title : url;

  /// 安卓 `Parsed.getId()`：`地址|剧名` 的往返形式。
  String get id => hasExplicitTitle ? '$url|$title' : url;

  /// 安卓 `Parsed.shouldSkipAutoTmdbMatch()`：没给剧名且是明显的地址/路径时，
  /// 不要去拿地址当片名搜 TMDB（搜不到，还白烧一次请求）。
  bool get shouldSkipAutoTmdbMatch =>
      !hasExplicitTitle && isObviousMediaLocation(name);

  @override
  String toString() => 'PushParsed(url=$url, title=$title)';
}

/// 解析一段推送文本（安卓 `PushParser.fromText`）。
///
/// 接受：裸地址、`push://地址`、`地址|剧名`、夹在说明文字里的地址、
/// 以及结构化 JSON（`{...}` 或含 `$` 的站点播放串，原样透传给播放器）。
PushParsed parsePushText(String text) {
  final split = _splitTitle(text);
  return PushParsed(
    url: _sniffUrl(_stripPushScheme(split.url)),
    title: split.title,
  );
}

/// 解析两个独立字段（PC 推送页 / 推送对话框的形态）。
///
/// 独立剧名字段优先于 `地址|剧名` 里的后缀；没给剧名时仍按
/// [parsePushText] 解析地址字段（安卓的粘贴框就是这么用的）。
PushParsed parsePushFields({String? url, String? title}) {
  final parsed = parsePushText(url ?? '');
  final explicit = (title ?? '').trim();
  if (explicit.isEmpty) return parsed;
  return PushParsed(url: parsed.url, title: explicit);
}

/// 这条位置是否像本地媒体路径（盘符、UNC、POSIX 绝对路径、`file://`）。
///
/// 只做字符串判定：磁盘是否存在由状态层检查，纯逻辑层不碰 I/O。
bool looksLikeLocalMediaPath(String value) {
  final text = value.trim();
  if (text.isEmpty) return false;
  if (text.toLowerCase().startsWith('file://')) return true;
  if (text.startsWith('/')) return true;
  if (text.startsWith(r'\\')) return true;
  return _windowsPathPattern.hasMatch(text);
}

/// 这条位置是否"明显是媒体地址/路径"（安卓 `isObviousMediaLocation`）。
bool isObviousMediaLocation(String value) {
  final location = value.trim();
  if (location.isEmpty) return false;
  return _networkLocationPattern.hasMatch(location) ||
      location.startsWith('/') ||
      location.startsWith(r'\\') ||
      _windowsPathPattern.hasMatch(location);
}

/// 展示标题：剧名优先；没剧名时用地址/路径里的文件名；再不行用兜底标题。
///
/// 为什么不照抄安卓的"没剧名就用裸地址"：历史卡片与播放器屏显会变成一整条
/// URL，用户认不出是哪部片。文件名至少是可读的。
String pushDisplayTitle({required String url, String title = ''}) {
  final explicit = title.trim();
  if (explicit.isNotEmpty) return explicit;
  final name = _fileNameFromLocation(url);
  return name.isEmpty ? pushFallbackTitle : name;
}

/// 推送 → 一次播放请求。
///
/// [localPath] 非空表示这条推送指向本地文件：交给既有
/// [PlaybackRequest.localFile]（本地语义不变：无 Header、不写历史）。
/// 否则构造推送合成站点的远程请求，历史按 [pushSiteKey] 归组。
PlaybackRequest pushPlaybackRequest({
  required PushParsed parsed,
  String? localPath,
}) {
  final path = (localPath ?? '').trim();
  if (path.isNotEmpty) {
    return PlaybackRequest.localFile(
      path: path,
      title: parsed.hasExplicitTitle ? parsed.title : null,
    );
  }
  final display = pushDisplayTitle(url: parsed.url, title: parsed.title);
  return PlaybackRequest(
    url: parsed.url,
    title: display,
    siteKey: pushSiteKey,
    vodId: parsed.url,
    vodName: display,
    episodeName: display,
    flag: pushSourceName,
  );
}

/// 配置里的「推送」站点：key 精确命中 push_agent 优先，其次 key/名字像推送。
///
/// 为什么允许"像推送"：不同配置生态里推送源的 key 不统一（实测有 push_agent、
/// nodejs_push，名字都叫「推送」）。精确 key 永远优先，避免误选。
Site? pushSiteInConfig(AppConfig config) {
  Site? exact;
  Site? loose;
  for (final site in config.sites) {
    if (site.key == pushSiteKey) {
      exact = site;
      break;
    }
    final blob = '${site.key} ${site.name}'.toLowerCase();
    if (loose == null && (blob.contains('push') || blob.contains('推送'))) {
      loose = site;
    }
  }
  return exact ?? loose;
}

/// 推送集名清洗：把站源返回的原始标签换成可读的集号。
///
/// 推送源返回的集名常常带大小/画质前缀（实测 "[2.44G] S01E01"、"[6.17G] 1"），
/// 直接写进历史卡片既不可读也不"刮削"。这里剥掉方括号标签，再识别
/// SxxExx / 第N集 / 纯数字，统一成「第N集」；识别不出时返回清洗后的原文。
String pushEpisodeLabel(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  text = text
      .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
      .replaceAll(RegExp(r'【[^】]*】'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty) return '';
  final seasonEpisode = RegExp(
    r's(\d{1,2})[ ._-]*e(\d{1,4})',
    caseSensitive: false,
  ).firstMatch(text);
  if (seasonEpisode != null) {
    final episode = int.tryParse(seasonEpisode.group(2) ?? '') ?? 0;
    if (episode > 0) return '第$episode集';
  }
  final chinese = RegExp(
    r'第\s*([0-9零〇一二三四五六七八九十百两]+)\s*[集话話]',
  ).firstMatch(text);
  final chineseNumber = chinese?.group(1) ?? '';
  if (chineseNumber.isNotEmpty) return '第$chineseNumber集';
  final bare = RegExp(
    r'^(?:e|ep|episode)?\s*(\d{1,4})$',
    caseSensitive: false,
  ).firstMatch(text);
  if (bare != null) {
    final episode = int.tryParse(bare.group(1) ?? '') ?? 0;
    if (episode > 0) return '第$episode集';
  }
  return text;
}

/// 推送的"详情结果"：安卓 `SiteApi.pushDetail` 的 PC 对应物。
///
/// 配置里没有「推送」源时，安卓自己合成一条单集结果，让推送照样进普通详情页。
/// PC 用同一个形状：一条线路、一集，地址就是推送地址——这样详情页、播放按钮、
/// 历史与 TMDB 全部走既有管线，而不是另起一套"推送地址页"。
SiteResult pushSiteDetail(PushParsed parsed) {
  final address = parsed.url;
  final name = pushDisplayTitle(url: address, title: parsed.title);
  final explicitTitle = parsed.title;
  final episodeName = parsed.hasExplicitTitle ? explicitTitle : '推送内容';
  return SiteResult(
    list: [
      Vod(
        vodId: address,
        vodName: name,
        vodContent: parsed.hasExplicitTitle ? '推送剧名：$explicitTitle' : null,
        vodPlayFrom: pushSourceName,
        // 协议约定：`剧集名$地址`；用插值拼接，避免字符串里的转义歧义。
        vodPlayUrl: episodeName + r'$' + address,
      ),
    ],
  );
}

/// 从位置里取可读文件名；取不到返回空串。
String _fileNameFromLocation(String value) {
  final text = _stripPushScheme(value.trim());
  if (text.isEmpty) return '';
  // 有 host 的按 URL 处理：`https://host/` 没有文件可分，`https://cdn/a.mkv` 有。
  // 直接按斜杠切会把域名当文件名（`cdn.example` → `cdn`）。
  final uri = Uri.tryParse(text);
  if (uri != null && uri.host.isNotEmpty) {
    final segments = uri.pathSegments.where((s) => s.trim().isNotEmpty).toList();
    if (segments.isEmpty) return '';
    return _stemOf(segments.last);
  }
  final cut = text.indexOf(RegExp(r'[?#]'));
  final path = cut >= 0 ? text.substring(0, cut) : text;
  final parts = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  return _stemOf(parts.last);
}

/// 去扩展名、去控制字符；`magnet:`/`ed2k://|file|…` 这类没有文件名的返回空串。
String _stemOf(String raw) {
  var name = raw.trim();
  if (name.isEmpty || name.contains('|') || name.contains(':')) return '';
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  return name.replaceAll(RegExp(r'[_\s]+'), ' ').trim();
}

/// 末尾 `|剧名` 拆分（安卓 `PushParser.splitTitle`）。
///
/// 必须按**最后一个** `|` 拆：剧名里本身可能带 `|`。
PushParsed _splitTitle(String text) {
  final value = text.trim();
  if (value.isEmpty) return const PushParsed(url: '');
  if (_isStructured(value)) return PushParsed(url: value);
  final index = value.lastIndexOf('|');
  if (index <= 0 || index >= value.length - 1) return PushParsed(url: value);
  final url = value.substring(0, index).trim();
  final title = value.substring(index + 1).trim();
  if (url.isEmpty || !_isTitleSuffix(title)) return PushParsed(url: value);
  return PushParsed(url: url, title: title);
}

/// 后缀是否真的是剧名（不是第二个地址、不是请求头行、得有文字）。
bool _isTitleSuffix(String value) {
  if (value.isEmpty) return false;
  if (_pushUrlPattern.hasMatch(value)) return false;
  if (_commonHeaderPattern.hasMatch(value)) return false;
  return _hasTitleText(value);
}

/// 文字判定（Java `Character.isLetterOrDigit`）：拉丁字母/数字 + 中文。
///
/// 必须显式覆盖 CJK：Dart 没有 `isLetterOrDigit`，而"庆余年"这类片名如果只认
/// ASCII，`地址|庆余年` 会被当成没有剧名，剧名就被丢掉。
final RegExp _titleTextPattern = RegExp(
  r'[A-Za-z0-9\u4e00-\u9fff\u3400-\u4dbf]',
);

bool _hasTitleText(String value) => _titleTextPattern.hasMatch(value);

/// 结构化播放串（安卓 `isStructured`）：`{...}` 或含 `$` 的站点播放串。
bool _isStructured(String value) =>
    (value.startsWith('{') && value.endsWith('}')) || value.contains(r'$');

/// 嗅探地址（安卓 `sniffUrl`）：结构化串原样返回，否则取文本里的第一个链接。
String _sniffUrl(String value) {
  if (_isStructured(value)) return value;
  final match = _pushUrlPattern.firstMatch(value);
  return _stripTrailingHeader(match?.group(0) ?? value);
}

/// 请求头名字前缀（`User-Agent:` / `Referer=` …）。
final RegExp _headerPrefixPattern = RegExp(
  r'^(user-agent|referer|referrer|cookie|origin|authorization|range|accept|content-type)\s*[:=]',
  caseSensitive: false,
);

/// 去掉嗅探结果尾巴上的 `|请求头`。
///
/// 安卓在这里会把 `|User-Agent:` 一起当成地址（上游 `PushParserTest` 只覆盖了
/// 没有空格的 `User-Agent=` 形态，且断言的正是"保留整段"）；那样的串播不了。
/// PC 只保留地址本身——头部信息不进 `do=push` 的载荷，留着只会让播放失败。
String _stripTrailingHeader(String value) {
  final index = value.indexOf('|');
  if (index <= 0) return value;
  final suffix = value.substring(index + 1);
  if (!_headerPrefixPattern.hasMatch(suffix)) return value;
  return value.substring(0, index);
}

/// 剥离 `push://` 前缀（安卓 `stripPushScheme`）。
String _stripPushScheme(String value) =>
    value.length > 7 && value.substring(0, 7).toLowerCase() == 'push://'
    ? value.substring(7)
    : value;
