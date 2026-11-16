/// 局域网发现/同步专用的 HTTP 传输。
///
/// `HttpClient()` 的默认 `findProxy` 会查环境变量，也受 `HttpOverrides`
/// 影响；局域网设备探测与同步必须显式直连，不能把设备请求静默送往代理。
/// 应用的公网站点/出站传输继续使用自己的工厂，不复用这里。
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 创建明确 DIRECT 的局域网 HTTP 客户端。
///
/// 只覆盖代理选择，保留 `dart:io` 默认的严格 TLS 校验；各调用方的请求超时
/// 仍由服务自身施加。注入 `http.Client` 的调用方不经过该工厂。
http.Client createLanHttpClient() {
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  return IOClient(client);
}
