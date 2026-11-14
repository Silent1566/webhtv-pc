/// 猫源（CatPawOpen 一类的 CatVod T4 服务端 bundle）识别与配置整形。
///
/// 参考实现：`Silent1566/webhtv@beta` 的
/// `app/src/main/java/com/fongmi/android/tv/api/CatSource.java`。
///
/// 猫源与标准 TVBox 配置有两处差异，导入前必须整形，否则会被现有
/// [parseConfigDocument] 判为「配置中没有可用站点」：
/// 1. 配置顶层是**裸站点数组**，或 `{video:{sites:[...]}, read:{...}, comic:{...}}`
///    这种按媒体类型分组的对象，而不是带 `sites` 字段的扁平对象；
/// 2. 站点 `api` 是**服务端上的相对路径**（如 `/video/douban`），需要补上基址。
///
/// 另外，猫源地址（`.../index.js.md5`、`.../index.js`）本指向 Node bundle 本身，
/// 不是可直接解析的配置；见 [CatSource.isBundle]。
library;

import 'dart:convert';
import 'dart:io';

import 'app_error.dart';
import 'protocol.dart';

/// 猫源 bundle 地址识别与配置规范化。
abstract final class CatSource {
  /// 本机跑的 bundle 按媒体类型分组，点播站点在这个键下面。
  static const String videoKey = 'video';

  /// 判断一个地址是否指向猫源 bundle 本身（而不是配置 JSON）。
  ///
  /// 与 CatPawOpen 的发布约定一致：`.../index.js.md5` 或 `.../index.js`。
  /// 本地包（用户自己解压出来的目录或 zip）没有 URL 形态可判，这里额外做磁盘
  /// 探测：非 http(s) 输入若指向含 `index.js` 的目录或 `.zip` 文件也算 bundle。
  /// 探测只对本地输入做，避免把远端地址当本地路径去 stat；`CatBundle` 的
  /// `_localDir`/`_localZip` 会二次确认（含 zip 内 `index.js.md5` 标记校验）。
  static bool isBundle(String? url) {
    if (url == null) return false;
    final value = url.trim().toLowerCase();
    if (value.isEmpty) return false;
    if (value.endsWith('.js.md5')) return true;
    // 去掉 query/fragment 后判断 `/index.js`，避免把 `index.js?v=2` 漏判。
    final path = _pathOnly(value);
    if (path.endsWith('/index.js') ||
        path.endsWith(r'\index.js') ||
        path == 'index.js') {
      return true;
    }
    // 本地包：目录（含 index.js）或 zip 文件。
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      if (value.endsWith('.zip')) return File(value).existsSync();
      final entry = value.endsWith(r'\') || value.endsWith('/')
          ? '${value}index.js'
          : '$value/index.js';
      return File(entry).existsSync();
    }
    return false;
  }

  /// 判断一段响应文本是不是猫源配置（而不是 401 信封、欢迎页等）。
  ///
  /// 用来在多个本机端口里认出真正的猫源服务：魔改 bundle 会额外起自己的 HTTP 服务
  /// （如内置弹幕服务器），那些服务对 `/config` 会返回 401 信封或欢迎页——都是非空
  /// 响应，只判空会把它们当成就绪。所以这里按配置形状判定。
  static bool isConfig(String? text) {
    if (text == null || text.trim().isEmpty) return false;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return false;
    }
    if (decoded is List) return decoded.isNotEmpty;
    if (decoded is! Map) return false;
    final map = asMap(decoded);
    if (map.containsKey('sites')) return true;
    final video = map[videoKey];
    return video is Map && asMap(video).containsKey('sites');
  }

  /// 把猫源返回的配置整形为标准 TVBox 配置对象。
  ///
  /// [url] 是最终读配置的地址（本机 `http://127.0.0.1:port/config`，或远端配置地址），
  /// 用于给相对 `api` 补基址；[root] 是已解析的 JSON。
  ///
  /// 抛出 [AppError.kind=configInvalid]，错误文本可直接展示给用户：
  /// 服务端返回空响应、HTML 错误页、纯文本或错误信封都会明确报错，而不是解析出空站点。
  static Map<String, Object?> normalize(String url, Object? root) {
    if (root == null) {
      throw AppError(AppErrorKind.configInvalid, '猫源配置为空');
    }
    if (root is! List && root is! Map) {
      throw AppError(
        AppErrorKind.configInvalid,
        '猫源配置格式不是 JSON 对象或数组',
        detail: '实际类型：${root.runtimeType}',
      );
    }

    if (root is Map) {
      _rejectErrorEnvelope(asMap(root));
    }

    final object = root is List
        ? _wrap(root)
        : _lift(asMap(root));

    _rebase(object, base(url));
    _defaultSearchable(object);
    return object;
  }

  /// 服务端的错误信封（如 `{code:401,message:"..."}`）照常是合法 JSON 对象，
  /// 往下走会解析出空 sites，用户只看到「订阅无效」而没有任何原因。这里如实报错。
  ///
  /// 判定刻意收窄到「有错误文本且没有任何配置内容」——[normalize] 对所有点播配置都跑，
  /// 不能把恰好带这些字段的正常配置和仓库配置（`urls`）误判掉。
  static void _rejectErrorEnvelope(Map<String, Object?> object) {
    if (object.containsKey('sites') ||
        object.containsKey(videoKey) ||
        object.containsKey('urls')) {
      return;
    }
    final message = asNonEmptyString(object['errorMessage']) ??
        asNonEmptyString(object['message']);
    if (message == null) return;
    final code = object['errorCode'] ?? object['code'];
    throw AppError(
      AppErrorKind.configInvalid,
      message,
      detail: code == null ? '猫源错误信封' : '猫源错误信封 code=$code',
    );
  }

  static Map<String, Object?> _wrap(List<dynamic> sites) {
    return <String, Object?>{'sites': sites};
  }

  /// 猫源有两种 config 形态：远端服务给的是扁平站点数组；本机跑 bundle 时是
  /// `{video:{sites:[...]}, read:{...}, comic:{...}, ...}`。后者把 video.sites 提上来，
  /// 其余分组（小说/漫画/音乐/网盘）当前不接入点播列表。
  static Map<String, Object?> _lift(Map<String, Object?> object) {
    if (object.containsKey('sites') || !object.containsKey(videoKey)) {
      return object;
    }
    final video = object[videoKey];
    if (video is! Map) return object;
    final sites = asMap(video)['sites'];
    if (sites is! List) return object;
    return <String, Object?>{'sites': sites};
  }

  /// 相对 api 单独存在没有意义，所以对任何配置都补基址，不只猫源。
  static void _rebase(Map<String, Object?> object, String base) {
    if (base.isEmpty) return;
    final sites = object['sites'];
    if (sites is! List) return;
    for (final element in sites) {
      if (element is! Map) continue;
      final map = element;
      final api = asString(map['api']) ?? '';
      if (api.startsWith('/')) {
        map['api'] = '$base$api';
      }
    }
  }

  /// 猫源 bundle 的站点通常不写 `searchable` 字段，而 TVBox 生态（含参考实现
  /// `Site.searchable == null ? 1 : ...`）按**可搜索**处理。本仓库标准配置路径
  /// 对缺失字段默认不可搜索（§8.4），两者语义相反，因此只在猫源整形时补齐：
  /// 缺失就写 `1`，站点自己声明的值（包括 `0`）一律保留。
  static void _defaultSearchable(Map<String, Object?> object) {
    final sites = object['sites'];
    if (sites is! List) return;
    for (final element in sites) {
      if (element is! Map) continue;
      final map = element;
      if (!map.containsKey('searchable')) {
        map['searchable'] = 1;
      }
    }
  }

  /// `scheme://userinfo@host:port`——保留 userinfo，免得每次请求都先吃一个 401。
  ///
  /// 纯字符串处理（不用 `Uri`）：只需要截到 authority 结束，且能让 [normalize]
  /// 在普通单元测试里跑，不依赖平台网络栈。
  static String base(String? url) {
    if (url == null) return '';
    final mark = url.indexOf('://');
    if (mark <= 0) return '';
    final start = mark + 3;
    var end = url.length;
    for (var i = start; i < url.length; i++) {
      final c = url[i];
      if (c == '/' || c == '?' || c == '#') {
        end = i;
        break;
      }
    }
    return end == start ? '' : url.substring(0, end);
  }

  /// 去掉 query/fragment，只留路径部分（小写）。
  static String _pathOnly(String value) {
    var end = value.length;
    for (var i = 0; i < value.length; i++) {
      final c = value[i];
      if (c == '?' || c == '#') {
        end = i;
        break;
      }
    }
    return value.substring(0, end);
  }
}
