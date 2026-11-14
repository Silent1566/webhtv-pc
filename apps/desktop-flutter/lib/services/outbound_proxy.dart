/// 出站 HTTP 客户端的传输层接线（`docs/phase9/README.md` P1-9、P2-8）。
///
/// 用 `IOClient` 包一个 `dart:io HttpClient`：
/// - P1-9：设置 `findProxy`，按域名分流到 HTTP 代理；
/// - P2-8：设置 `connectionFactory`，先走 DoH/hosts 映射解析，再建连接。
///
/// 为什么统一在这一层：各服务自己 new `http.Client()` 的地方太多，
/// 逐个注入容易漏；集中提供一个工厂，由 `AppState` 在设置变化时替换。
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/outbound_proxy.dart';
import 'doh_resolver.dart';

/// 按设置构造 HTTP 客户端。
///
/// - 代理与 DoH 都不生效时返回普通 `http.Client()`，行为与 Phase 0–8 一致；
/// - 代理生效时 `findProxy` 逐请求按域名裁决；
/// - DoH/hosts 生效时 `connectionFactory` 接管 DNS（失败自动回落系统 DNS）。
http.Client createOutboundHttpClient(
  OutboundProxySettings settings, {
  DohResolver? doh,
}) {
  final proxyEffective = settings.isEffective;
  final dohUsable = doh != null && doh.isUsable;
  if (!proxyEffective && !dohUsable) return http.Client();

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30);
  if (proxyEffective) {
    client.findProxy = (uri) => findProxyValue(settings, uri);
  }
  if (dohUsable) {
    client.connectionFactory = doh.createConnection;
  }
  return IOClient(client);
}
