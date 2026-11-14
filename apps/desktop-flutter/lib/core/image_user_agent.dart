/// 图片请求的 User-Agent 覆盖（`HttpOverrides`）。
///
/// 为什么必须在这一层做：`Image.network(headers:)` 最终由 `NetworkImage` 通过
/// `request.headers.add(name, value)` 写入请求头。而 `dart:io` 的 `HttpClient`
/// **默认已带** `User-Agent: Dart/x.y (dart:io)`，`add` 是**追加**语义，于是发出去的
/// 是单个头的多值拼接：`Dart/3.13 (dart:io), WebHTV-PC/0.1 (Windows)`。
///
/// 豆瓣图床（EdgeOne 边缘）会对含 `Dart/` 的 UA 直接 418——即使用户配置里的
/// `Referer` 已经正确注入。实测（同一 URL，本机 dart run）：
/// - `headers.add('User-Agent', 'WebHTV-PC/0.1 (Windows)')` → 418；
/// - `HttpClient.userAgent = 'WebHTV-PC/0.1 (Windows)'`（set 语义）→ **200**。
///
/// 所以 UA 必须由客户端级设置替换，而 `Referer`/签名头等继续走 `Image.network`
/// 的 headers（那些头没有默认值，`add` 不会冲突）。
library;

import 'dart:io';

/// 与 `HttpApiRequestBuilder.defaultUserAgent` / `imageUserAgent` 同值。
const String _userAgent = 'WebHTV-PC/0.1 (Windows)';

/// 给所有 `dart:io` `HttpClient`（含 Flutter 的图片加载器）设置应用 UA。
class ImageHttpOverrides extends HttpOverrides {
  ImageHttpOverrides();

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.userAgent = _userAgent;
    return client;
  }
}

/// 已安装的覆盖实例（`installImageUserAgent` 之后非 null）。
///
/// `HttpOverrides` 只有写入口 `global`、没有对应 getter（读的是 `current`，会被测试
/// zone 的 mock 遮蔽），因此保留一份引用供断言与排查。
ImageHttpOverrides? installedImageHttpOverrides;

/// 安装全局图片 UA 覆盖。必须在 `runApp` 之前调用一次。
void installImageUserAgent() {
  final overrides = ImageHttpOverrides();
  installedImageHttpOverrides = overrides;
  HttpOverrides.global = overrides;
}
