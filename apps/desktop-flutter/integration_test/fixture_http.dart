/// Phase 5 集成测试的 fixture 服务辅助（`docs/phase5/design/03` §2.3）。
///
/// 只做三件事：查统计、重置统计、切换故障注入模式。用 `dart:io` 的
/// `HttpClient` 直连回环，不引入额外依赖。
library;

import 'dart:convert';
import 'dart:io';

/// fixture 服务基址（与 `tools/fixture_server` 的默认端口一致）。
String get fixtureBaseUrl =>
    Platform.environment['WEBHTV_FIXTURE_BASE'] ?? 'http://127.0.0.1:18080';

/// 安卓 fixture 命名空间的基址。
String get fixtureAndroidUrl => '$fixtureBaseUrl/android';

/// 把用户输入的地址规范化成 PC 实际使用的可达基址。
///
/// 与 `normalizeBase` 的规则一致（缺端口补 9978 之外的情况由调用方保证）。
String fixtureAndroidBase(String base) {
  var text = base.trim();
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.parse(text);
  final port = uri.hasPort ? uri.port : 80;
  return '${uri.scheme}://${uri.host}:$port';
}

Future<Map<String, Object?>> _getJson(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('fixture $url 返回 ${response.statusCode}');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw StateError('fixture $url 不是 JSON 对象');
    return decoded.map((key, value) => MapEntry('$key', value));
  } finally {
    client.close();
  }
}

/// 读取 fixture 的路由统计与最近一次请求形态。
Future<Map<String, Object?>> fixtureStats([String prefix = '']) =>
    _getJson('$fixtureBaseUrl$prefix/__stats');

/// 清空统计（用例隔离）。
Future<void> fixtureReset([String prefix = '']) async {
  await _getJson('$fixtureBaseUrl$prefix/__reset');
}

/// 设置故障注入模式（`ok` / `404` / `empty` / `mismatch` / `loopback` /
/// `repo` / `notandroid` / `slow` / `403`）。
Future<void> fixtureMode(String prefix, String mode) async {
  await _getJson('$fixtureBaseUrl$prefix/__mode?config=$mode');
}
