/// HTTP API 站点客户端：请求构造、Header 注入、响应解析（§7.4.6、§7.4.7、§8.1）。
///
/// 覆盖站点类型：
/// - `type=0` XML API：`ac=videolist` / `ac=detail`，返回 XML 的 `rss/list`；
/// - `type=1` JSON API：请求带 `ac=detail` 与 `f={json}`；
/// - `type=2` JSON API 兼容：不追加 `f`；
/// - `type=4` HTTP API + Base64 ext：筛选对象 Base64 URL-Safe 放入 `ext`。
///
/// 请求编码规则必须被请求捕获测试验证（§7.4.7），因此这里把请求参数单独抽出为
/// [HttpApiRequestBuilder]，与网络执行解耦，便于断言 query/form 选择。
library;

import 'dart:async';
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'app_error.dart';
import 'danmaku.dart';
import 'protocol.dart';

/// 站点类型常量。
abstract final class SiteType {
  static const xmlApi = 0;
  static const jsonApi = 1;
  static const jsonApiCompat = 2;
  static const spider = 3;
  static const jsonApiBase64Ext = 4;

  static bool isHttpApi(int type) =>
      type == xmlApi ||
      type == jsonApi ||
      type == jsonApiCompat ||
      type == jsonApiBase64Ext;
}

/// 一次 HTTP API 请求的可断言描述。
class HttpApiCall {
  const HttpApiCall({
    required this.method,
    required this.uri,
    this.formBody,
    required this.headers,
    this.action,
  });

  final String method;
  final Uri uri;

  /// 非空表示使用 `application/x-www-form-urlencoded` 表单 body（§7.4.7）。
  final Map<String, String>? formBody;
  final Map<String, String> headers;
  final String? action;

  String get summary =>
      '$method ${redactUrl(uri.toString())} '
      'form=${formBody == null ? "no" : "yes"} '
      'queryKeys=${uri.queryParametersAll.keys.toList()..sort()} '
      'headerKeys=${headers.keys.toList()..sort()}';
}

/// 请求动作。
enum HttpApiAction { home, category, detail, search, play }
/// 请求构造器。
///
/// 规则来源：
/// - `ext` 长度 ≤ 1000 放 query，> 1000 放表单 body（§7.4.7）；
/// - `type=1` 分类请求把筛选对象 JSON 放入 `f`；
/// - `type=4` 分类请求把筛选对象 Base64 URL-Safe 后放入 `ext`；
/// - `type=0` 使用 `ac=videolist`。
class HttpApiRequestBuilder {
  const HttpApiRequestBuilder({
    required this.site,
    this.globalHeaders = const [],
    this.userAgent = defaultUserAgent,
  });

  static const String defaultUserAgent = 'WebHTV-PC/0.1 (Windows)';

  /// 站点 `ext` 超过该长度时改用表单 body。
  static const int extQueryLimit = 1000;

  final Site site;
  final List<HeaderRule> globalHeaders;
  final String userAgent;

  /// Base64 URL-Safe 编码（§7.4.4）：字符表 `-_`、无换行、去掉填充 `=`。
  static String base64UrlSafe(String input) {
    final encoded = base64Url.encode(utf8.encode(input));
    return encoded.replaceAll('=', '');
  }

  /// 站点 `ext` 的对象形态按稳定 JSON 原始文本传递，不做 Base64（§7.4.5）。
  String? get normalizedExt {
    final ext = site.ext;
    if (ext == null) return null;
    if (ext is String) return ext.trim().isEmpty ? null : ext;
    return jsonEncode(ext);
  }

  Uri _endpoint() {
    final api = site.api.trim();
    if (api.isEmpty) {
      throw AppError(
        AppErrorKind.siteEmptyApi,
        '站点 ${site.key} 未配置 api',
        detail: site.name,
      );
    }
    final uri = Uri.tryParse(api);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw AppError(
        AppErrorKind.siteEmptyApi,
        '站点 ${site.key} 的 api 不是有效的 http(s) 地址',
        detail: redactUrl(api),
      );
    }
    return uri;
  }

  HttpApiCall build(
    HttpApiAction action, {
    String? typeId,
    int? page,
    String? vodId,
    String? keyword,
    bool quick = false,
    Map<String, String> filters = const {},
  }) {
    final endpoint = _endpoint();
    final parameters = <String, String>{};
    final form = <String, String>{};

    final ext = normalizedExt;
    final extGoesToBody = ext != null && ext.length > extQueryLimit;
    if (ext != null) {
      if (extGoesToBody) {
        form['extend'] = ext;
      } else {
        parameters['extend'] = ext;
      }
    }

    switch (action) {
      case HttpApiAction.home:
        // 首页无额外参数；保留站点 ext。
        break;
      case HttpApiAction.category:
        parameters['ac'] = site.type == SiteType.xmlApi ? 'videolist' : 'detail';
        if (typeId != null && typeId.isNotEmpty) parameters['t'] = typeId;
        parameters['pg'] = (page ?? 1).toString();
        if (filters.isNotEmpty) {
          final filterJson = jsonEncode(filters);
          if (site.type == SiteType.jsonApiBase64Ext) {
            // §7.4.5：`type=4` 的筛选对象 Base64 URL-Safe 放入 ext 参数。
            // 该 ext 与站点 ext 是不同层级字段，站点 ext 已作为 extend 传递。
            parameters['ext'] = base64UrlSafe(filterJson);
          } else {
            parameters['f'] = filterJson;
          }
        }
        break;
      case HttpApiAction.detail:
        parameters['ac'] = site.type == SiteType.xmlApi ? 'detail' : 'detail';
        parameters['ids'] = vodId ?? '';
        break;
      case HttpApiAction.search:
        parameters['wd'] = keyword ?? '';
        parameters['pg'] = (page ?? 1).toString();
        if (quick) parameters['quick'] = 'true';
        break;
      case HttpApiAction.play:
        // 播放请求不是 TVBox HTTP API 的标准动作；它只在站点显式声明了
        // `playUrl` 播放入口时使用，由 [buildPlayRequest] 构造。
        throw StateError('播放请求请使用 buildPlayRequest');
    }

    parameters.removeWhere((key, value) => value.isEmpty && key != 'wd');

    final headers = _headersFor(endpoint);
    if (form.isNotEmpty) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded; charset=utf-8';
    }

    final uri = endpoint.replace(
      queryParameters: {
        ...endpoint.queryParameters,
        ...parameters,
      },
    );
    // 请求走不带 userinfo 的 URI：凭据已由 [_headersFor] 注入 Authorization 头，
    // URI 里再留一份只会让 package:http 再发一次错误编码的凭据（并可能进入日志）。
    final target = uriWithoutUserInfo(uri);

    return HttpApiCall(
      method: form.isEmpty ? 'GET' : 'POST',
      uri: target,
      formBody: form.isEmpty ? null : form,
      headers: headers,
      action: action.name,
    );
  }

  /// Header 注入顺序固定（§7.4.6）：
  /// 1) 全局 `headers` 按目标 host 匹配；2) 站点 `header` 覆盖同名键。
  ///
  /// 另外：站点 `api` 可能带 `user:pass@host` 凭据（TVBox/猫源生态常见）。
  /// `package:http` 与 `dart:io` 一样**不解码** URI userinfo 的百分号编码
  /// （密码里的 `%3A` 会被字面发出 → 401），因此这里解码后显式注入 Basic 头。
  /// 仅在站点未自行声明 Authorization 时注入，不覆盖用户显式配置的凭据。
  Map<String, String> _headersFor(Uri endpoint) {
    final merged = HeaderMap.merge([
      globalHeadersFor(globalHeaders, endpoint.host),
      site.header,
    ]);
    if (!merged.containsKey('User-Agent')) {
      merged.put('User-Agent', userAgent);
    }
    if (!merged.containsKey('Authorization')) {
      final auth = basicAuthHeader(endpoint);
      if (auth != null) merged.put('Authorization', auth);
    }
    return merged.asRequestHeaders;
  }

  /// 构造播放入口请求。
  ///
  /// 站点 `playUrl` 是设计文档 §8.2 保留的字段；§7.4.8 明确它可能是解析入口、
  /// 前缀或备用地址。MVP-A 实现的子集：
  /// - `playUrl` 以 `=` 结尾时按**前缀**处理，直接拼接剧集目标；
  /// - 否则按**播放接口**处理，保留原有 query 并追加 `id=<剧集目标>`。
  ///
  /// 两种形态的最终结果都必须经 [PlaybackResolver] 校验，缺 URL 时明确报错。
  ///
  /// `type=4`（HTTP API + Base64 ext）没有 `playUrl` 概念：播放入口**就是站点
  /// `api` 本身**，按 `play=<剧集目标>&flag=<线路>` 调用（见
  /// [buildBase64ExtPlayRequest]）。
  HttpApiCall buildPlayRequest(String target, {String? flag}) {
    if (site.type == SiteType.jsonApiBase64Ext) {
      return buildBase64ExtPlayRequest(target, flag: flag);
    }
    final playUrl = asNonEmptyString(site.extra['playUrl']) ??
        asNonEmptyString(site.extra['playurl']);
    if (playUrl == null) {
      throw AppError(
        AppErrorKind.playbackParserRequired,
        '站点 ${site.key} 未声明 playUrl，且剧集目标不是直链',
        detail: '需要解析器或 Spider 运行时（MVP-A 未实现）',
      );
    }
    if (playUrl.endsWith('=') || playUrl.contains('{id}')) {
      throw AppError(
        AppErrorKind.playbackParserRequired,
        '站点 ${site.key} 的 playUrl 是前缀形态',
        detail: '前缀形态由 PlaybackResolver 直接拼接，不应走到播放接口',
      );
    }
    final endpoint = Uri.tryParse(playUrl);
    if (endpoint == null ||
        !(endpoint.isScheme('http') || endpoint.isScheme('https'))) {
      throw AppError(
        AppErrorKind.playbackUrlMissing,
        '站点 ${site.key} 的 playUrl 不是有效的 http(s) 地址',
        detail: redactUrl(playUrl),
      );
    }
    final uri = endpoint.replace(
      queryParameters: {...endpoint.queryParameters, 'id': target},
    );
    return HttpApiCall(
      method: 'GET',
      uri: uriWithoutUserInfo(uri),
      headers: _headersFor(endpoint),
      action: 'play',
    );
  }

  /// 构造 `type=4`（HTTP API + Base64 ext）的播放入口请求。
  ///
  /// **契约来源**（Android 参考实现 `SiteApi.playerContent`，`site.getType() == 4`
  /// 分支）：
  ///
  /// ```java
  /// ArrayMap<String, String> params = new ArrayMap<>();
  /// params.put("play", id);
  /// params.put("flag", flag);
  /// String playerContent = call(site, params);   // 即 GET <site.api>?play=…&flag=…
  /// ```
  ///
  /// 也就是说 `type=4` 的剧集目标是**播放入口的输入**，播放入口是站点 `api` 自身
  /// （`?play=<剧集目标>&flag=<线路>`），与 `type=3` 的 `/play` 路由同义。宿主**必须**
  /// 调用它才能拿到真实媒体地址与媒体 Header：
  ///
  /// - 实测 T4 站点（`http://192.168.50.50:3000/video/木偶`）`play=<剧集目标>&flag=a115`
  ///   返回 `{parse:0, jx:0, url:"https://cdnfhnfile.115cdn.net/…mp4",
  ///   header:{"user-agent":"Mozilla/5.0 115Browser/23.9.3.2"}}`——**该 UA 是 115 CDN
  ///   放行的必要条件**，只看详情里的剧集目标（纯 https 直链）拿不到它；
  /// - 平台型 T4 站点（`movie360`/`iqiyi`/`mgtv`/`youku`）播放入口返回 `parse=1` +
  ///   解析器地址，必须继续走 §12 解析器；
  /// - `HanXiaoQuanNight`/`YingHuaDM` 等返回 `parse=0` + 真实 m3u8 + `Referer`/`Origin`。
  ///
  /// 站点 `ext` 的编码规则与 [build] 一致（≤1000 放 query，>1000 放表单 body）。
  /// 缺少 `flag` 时不发送该参数（实测服务端按「无线路」处理，多数站点返回解析器地址
  /// 或业务错误，不会静默成功）。
  HttpApiCall buildBase64ExtPlayRequest(String target, {String? flag}) {
    final endpoint = _endpoint();
    final parameters = <String, String>{};
    final form = <String, String>{};

    final ext = normalizedExt;
    if (ext != null) {
      if (ext.length > extQueryLimit) {
        form['extend'] = ext;
      } else {
        parameters['extend'] = ext;
      }
    }
    parameters['play'] = target;
    final line = flag?.trim() ?? '';
    if (line.isNotEmpty) parameters['flag'] = line;

    final headers = _headersFor(endpoint);
    if (form.isNotEmpty) {
      headers['Content-Type'] =
          'application/x-www-form-urlencoded; charset=utf-8';
    }

    final uri = endpoint.replace(
      queryParameters: {...endpoint.queryParameters, ...parameters},
    );
    return HttpApiCall(
      method: form.isEmpty ? 'GET' : 'POST',
      uri: uriWithoutUserInfo(uri),
      formBody: form.isEmpty ? null : form,
      headers: headers,
      action: 'play',
    );
  }
}

/// HTTP API 响应解析。
abstract final class HttpApiResponseParser {
  /// 把响应体文本解析为统一 [SiteResult]。
  ///
  /// 设计约束：
  /// - 非 2xx 由调用方映射为 [AppErrorKind.siteHttp]，不进入本函数；
  /// - HTML 错误页必须识别为 [AppErrorKind.siteParse]（§7.4.3、§8.4）；
  /// - `{code: 0, data: ...}` 解包 `data`；`{code: 非0, msg}` 返回业务错误（§9.4）；
  /// - `msg` 非空时向上抛出业务错误，不转换为空列表（§7.4.3）。
  static SiteResult parse(String body, {required String siteKey}) {
    final text = body.trimLeft();
    if (text.isEmpty) {
      throw AppError(
        AppErrorKind.siteParse,
        '站点响应为空',
        detail: siteKey,
      );
    }
    if (_looksLikeHtml(text)) {
      throw AppError(
        AppErrorKind.siteParse,
        '站点返回 HTML 页面（可能是错误页、登录页或 WAF 拦截）',
        detail: '$siteKey: ${_htmlHint(text)}',
      );
    }

    if (text.startsWith('{')) {
      return _parseJsonObject(_decodeJson(text, siteKey), siteKey: siteKey);
    }
    if (text.startsWith('[')) {
      final decoded = _decodeJson(text, siteKey);
      return SiteResult(list: _parseVodList(decoded, siteKey: siteKey));
    }
    if (text.startsWith('<')) {
      return _parseXml(text, siteKey: siteKey);
    }
    // 播放入口可能直接返回纯文本 URL。
    if (_looksLikeBareUrl(text)) {
      return SiteResult(playUrl: text.split('\n').first.trim());
    }

    throw AppError(
      AppErrorKind.siteParse,
      '站点响应既不是 JSON 也不是 XML',
      detail: '$siteKey: ${text.substring(0, text.length > 40 ? 40 : text.length)}',
    );
  }

  static Object? _decodeJson(String text, String siteKey) {
    try {
      return jsonDecode(text);
    } on FormatException catch (error) {
      throw AppError(
        AppErrorKind.siteParse,
        '站点 JSON 解析失败',
        detail: '$siteKey: ${error.message}',
        cause: error,
      );
    }
  }

  static SiteResult _parseJsonObject(
    Object? decoded, {
    required String siteKey,
  }) {
    final map = asMap(decoded);

    // §9.4：`{code, data}` 信封解包。
    if (map.containsKey('code')) {
      final code = asInt(map['code']) ?? 0;
      final message = asNonEmptyString(map['msg']);
      if (code != 0) {
        throw AppError(
          AppErrorKind.siteBusiness,
          message ?? '站点返回业务错误 code=$code',
          detail: siteKey,
        );
      }
      final data = map['data'];
      if (data is List) {
        return SiteResult(
          list: _parseVodList(data, siteKey: siteKey),
          msg: message,
        );
      }
      if (data is Map) {
        final result = _parseJsonObject(
          data,
          siteKey: siteKey,
        );
        return message == null ? result : result.copyWith(msg: message);
      }
    }

    // §7.4.3：Result 的 `msg` 非空视为业务错误，不得转为空列表。
    final message = asNonEmptyString(map['msg']);
    final hasList = map.containsKey('list');
    final hasClass = map.containsKey('class');
    if (message != null && !hasList && !hasClass) {
      throw AppError(
        AppErrorKind.siteBusiness,
        message,
        detail: siteKey,
      );
    }

    final classes = asList(map['class'])
        .map(VodClass.fromJson)
        .whereType<VodClass>()
        .toList();
    final list = _parseVodList(map['list'], siteKey: siteKey);
    final filters = _parseFilters(map['filters']);

    return SiteResult(
      classes: classes,
      filters: filters,
      list: list,
      page: asInt(map['page']),
      pageCount: asInt(map['pagecount']) ?? asInt(map['page_count']),
      total: asInt(map['total']),
      msg: message,
      header: map.containsKey('header') ? HeaderMap(asMap(map['header'])) : null,
      format: asNonEmptyString(map['format']),
      parse: asInt(map['parse']),
      jx: asInt(map['jx']),
      playUrl: _playUrlFrom(map),
      // 外挂字幕（§10.3）：`subs` 数组仅在播放结果里有意义，其他结果为空。
      subs: SubtitleInfo.listFromJson(map['subs']),
      // 弹幕源（§21 Phase 3）：形态极宽松，由 danmaku.dart 的兼容层解析。
      danmaku: danmakuSourcesFromJson(map['danmaku']),
    );
  }

  /// 从播放结果的 `url`/`playUrl` 字段提取第一个可播放地址。
  ///
  /// 猫源 bundle 的播放入口（`/play`）会返回**多码率列表**，`url` 是
  /// 「名称/地址」交替的平铺数组（对齐 CatVod 生态与参考实现的 `UrlAdapter`）：
  ///   ["RAW", "https://…", "super", "https://…", "high", "https://…"]
  /// 也兼容参考实现 Result 的 `url` 对象形态 `{"values":[{n,v},…]}` 与
  /// 数组对象形态 `[{name,url},…]`。取**第一个**作为可播放地址（RAW 优先）。
  ///
  /// 注意：顶层 `urls`（复数）**不是**播放入口字段——它是配置仓库键（§7.4.2），
  /// 猫源 bundle 只在无法产出地址时回 `{urls:[], header:{}}`，永不填充。
  /// 因此这里不从 `urls` 取值，取不到就交给调用方按「上游没给地址」处理
  /// （`site_service.resolvePlayback` 对 `type=3` 会明确报错，不回退到分享页）。
  static String? _playUrlFrom(Map<String, Object?> map) {
    final url = map['url'];
    if (url is List) {
      // 平铺数组：两两配对（名称/地址），先找裸地址（RAW）；否则用第一个。
      final names = <String>[];
      final values = <String>[];
      for (var i = 0; i + 1 < url.length; i += 2) {
        final name = asNonEmptyString(url[i]);
        final value = asNonEmptyString(url[i + 1]);
        if (name != null && value != null) {
          names.add(name);
          values.add(value);
        }
      }
      if (values.isNotEmpty) {
        final rawIndex = names.indexWhere((n) => n.toLowerCase() == 'raw');
        return rawIndex >= 0 ? values[rawIndex] : values.first;
      }
      // 退化为纯地址数组（无名称）：取第一个非空 http(s)。
      for (final item in url) {
        final text = asNonEmptyString(item);
        if (text != null && text.startsWith('http')) return text;
      }
      return null;
    }
    if (url is Map) {
      // 参考实现 Result 形态：`{"values":[{"n":"RAW","v":"…"},…]}`。
      final values = asList(url['values']);
      for (final item in values) {
        final map2 = asMap(item);
        final value = asNonEmptyString(map2['v']) ?? asNonEmptyString(map2['url']);
        if (value != null) return value;
      }
      return null;
    }
    return asNonEmptyString(url) ?? asNonEmptyString(map['playUrl']);
  }

  static Map<String, List<VodFilterGroup>> _parseFilters(Object? value) {
    final result = <String, List<VodFilterGroup>>{};
    for (final entry in asMap(value).entries) {
      final groups = asList(entry.value)
          .map(VodFilterGroup.fromJson)
          .whereType<VodFilterGroup>()
          .toList();
      if (groups.isNotEmpty) result[entry.key] = groups;
    }
    return result;
  }

  static List<Vod> _parseVodList(Object? value, {required String siteKey}) {
    final list = <Vod>[];
    for (final item in asList(value)) {
      final vod = Vod.fromJson(item);
      if (vod == null) continue;
      list.add(vod);
    }
    if (list.isEmpty && asList(value).isNotEmpty) {
      throw AppError(
        AppErrorKind.siteParse,
        '列表条目缺少 vod_id/vod_name',
        detail: siteKey,
      );
    }
    return list;
  }

  /// XML API（`type=0`）：结构为 `<rss><class>…</class><list>…</list></rss>`。
  static SiteResult _parseXml(String text, {required String siteKey}) {
    XmlDocument document;
    try {
      document = XmlDocument.parse(text);
    } on XmlException catch (error) {
      throw AppError(
        AppErrorKind.siteParse,
        '站点 XML 解析失败',
        detail: '$siteKey: ${error.message}',
        cause: error,
      );
    }

    final root = document.rootElement;
    // 播放入口 XML：`<rss><url>…</url></rss>` 或 `<url>…</url>`。
    final bareUrl = root.getElement('url')?.innerText.trim() ??
        (root.localName == 'url' ? root.innerText.trim() : null);
    if (bareUrl != null && bareUrl.isNotEmpty) {
      return SiteResult(playUrl: bareUrl);
    }

    final classes = <VodClass>[];
    for (final element in root.findElements('class')) {
      final cls = VodClass.fromJson({
        'type_id': element.getAttribute('id') ?? element.innerText,
        'type_name': element.innerText,
      });
      if (cls != null) classes.add(cls);
    }

    final list = <Vod>[];
    for (final element in root.findElements('list')) {
      // XML API 字段名与 Result JSON 字段名不同，这里显式映射，
      // 避免用 `vod_<xml标签>` 的机械拼接把 note/des 丢成未知字段。
      final attributes = <String, Object?>{
        'vod_id': element.getAttribute('id'),
        'vod_name': element.getElement('name')?.innerText ?? element.innerText,
        'vod_pic': element.getElement('pic')?.innerText,
        'vod_remarks':
            element.getElement('note')?.innerText ?? element.getElement('state')?.innerText,
        'vod_content': element.getElement('des')?.innerText,
        'vod_year': element.getElement('year')?.innerText,
        'vod_area': element.getElement('area')?.innerText,
        'vod_director': element.getElement('director')?.innerText,
        'vod_actor': element.getElement('actor')?.innerText,
      };
      // 详情播放地址：`<dt>`/`<dd flag="线路">剧集名$地址#…</dd>`。
      final dt = element.getElement('dt')?.innerText.trim();
      if (dt != null && dt.isNotEmpty) {
        attributes['vod_play_from'] = element.getAttribute('flag') ?? 'xml';
        attributes['vod_play_url'] = dt;
      }
      final ddElements = element.findElements('dd').toList();
      if (ddElements.isNotEmpty) {
        final flags = <String>[];
        final urls = <String>[];
        for (final dd in ddElements) {
          final text = dd.innerText.trim();
          if (text.isEmpty) continue;
          flags.add(dd.getAttribute('flag') ?? '线路${flags.length + 1}');
          urls.add(text);
        }
        if (urls.isNotEmpty) {
          attributes['vod_play_from'] = flags.join(r'$$$');
          attributes['vod_play_url'] = urls.join(r'$$$');
        }
      }
      final vod = Vod.fromJson(attributes);
      if (vod != null) list.add(vod);
    }

    if (classes.isEmpty && list.isEmpty) {
      throw AppError(
        AppErrorKind.siteParse,
        'XML 响应没有 class/list 节点',
        detail: siteKey,
      );
    }

    return SiteResult(classes: classes, list: list);
  }

  static bool _looksLikeHtml(String text) {
    final head = text.length > 400 ? text.substring(0, 400) : text;
    final lowered = head.toLowerCase();
    return lowered.startsWith('<!doctype html') ||
        lowered.startsWith('<html') ||
        lowered.contains('<head>') ||
        lowered.contains('<body') ||
        lowered.contains('<title>');
  }

  static bool _looksLikeBareUrl(String text) {
    final singleLine = text.split('\n').first.trim();
    return singleLine.startsWith('http://') ||
        singleLine.startsWith('https://') ||
        singleLine.startsWith('rtsp://') ||
        singleLine.startsWith('rtmp://') ||
        singleLine.startsWith('//');
  }

  static String _htmlHint(String text) {
    final match = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(text);
    final title = match?.group(1)?.trim();
    if (title != null && title.isNotEmpty) return 'title=$title';
    return '前 60 字节：${text.substring(0, text.length > 60 ? 60 : text.length)}';
  }
}

/// 带 Header 注入与环境约束的 HTTP API 客户端。
class HttpApiClient {
  HttpApiClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.userAgent = HttpApiRequestBuilder.defaultUserAgent,
    this.maxResponseBytes = 16 * 1024 * 1024,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;
  final String userAgent;

  /// 单个站点响应大小上限，避免异常站点把内存打满（§9.8）。
  final int maxResponseBytes;

  void close() => _client.close();

  Future<SiteResult> execute(HttpApiCall call, {required String siteKey}) async {
    final http.Response response;
    try {
      http.Response received;
      if (call.formBody != null) {
        received = await _client
            .post(call.uri, headers: call.headers, body: call.formBody)
            .timeout(timeout);
      } else {
        received = await _client.get(call.uri, headers: call.headers).timeout(timeout);
      }
      response = received;
    } on TimeoutException catch (error) {
      throw AppError(
        AppErrorKind.siteTimeout,
        '站点请求超时（${timeout.inSeconds}s）',
        detail: '$siteKey ${call.action}',
        retryable: true,
        cause: error,
      );
    } catch (error) {
      throw AppError(
        AppErrorKind.siteNetwork,
        '站点请求失败：${error.runtimeType}',
        detail: '$siteKey ${redactUrl(call.uri.toString())}',
        retryable: true,
        cause: error,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppError(
        AppErrorKind.siteHttp,
        '上游返回 HTTP ${response.statusCode}',
        detail: '$siteKey ${call.action}',
        statusCode: response.statusCode,
        retryable: response.statusCode >= 500,
      );
    }

    if (response.bodyBytes.length > maxResponseBytes) {
      throw AppError(
        AppErrorKind.siteParse,
        '站点响应超过大小上限',
        detail: '$siteKey ${response.bodyBytes.length} bytes',
      );
    }

    final body = _decodeResponseText(response);
    return HttpApiResponseParser.parse(body, siteKey: siteKey);
  }

  /// 站点响应可能返回 GBK/GB2312（老式 CMS），因此不能直接信任 `http` 包的
  /// latin1 回退解码结果。
  String _decodeResponseText(http.Response response) {
    final contentType = response.headers['content-type'];
    final declared = RegExp(
      r'''charset\s*=\s*"?([\w\-]+)"?''',
      caseSensitive: false,
    ).firstMatch(contentType ?? '')?.group(1);
    final bytes = response.bodyBytes;

    if (declared != null) {
      final charset = declared.toLowerCase();
      if (charset.startsWith('gb')) {
        try {
          return gbk.decode(bytes, allowMalformed: false);
        } on FormatException {
          // 落到下方 UTF-8 判定。
        }
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      try {
        return gbk.decode(bytes, allowMalformed: true);
      } on FormatException {
        throw AppError(
          AppErrorKind.siteParse,
          '站点响应无法按 UTF-8 或 GBK 解码',
          detail: 'charset=${declared ?? "未声明"}',
        );
      }
    }
  }
}
