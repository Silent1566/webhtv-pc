/// 图片请求的 Header 注入（§7.4.6 步骤 2 的图片侧）。
///
/// 为什么单独一层：顶层 `headers` 规则此前只作用于站点 API（[HttpApiRequestBuilder]）
/// 与媒体播放（`PlaybackResolver`），图片链路（`Image.network`）**完全没有匹配过**，
/// 于是像豆瓣图床这种要 `Referer` 防盗链的站点在 PC 端全是破图（用户反馈
/// 2026-10-25：「豆瓣的图片出不来，安卓版是正常的」；实测 `curl` 不带 Referer
/// 返回 418，带 `Referer: https://movie.douban.com` 返回 200）。
///
/// 这里保持与 API 侧同一套语义（`globalHeadersFor` 按 host 匹配、大小写不敏感），
/// 只是把结果交给 `Image.network(headers:)`。
library;

import 'protocol.dart';

/// 图片请求使用的 `User-Agent`（**仅供展示/对照**；真正生效的替换发生在
/// `HttpOverrides` 里，见 `image_user_agent.dart`）。
///
/// 为什么不能靠 `Image.network(headers:)` 设 UA：`NetworkImage` 用
/// `request.headers.add()` 写入，`dart:io` 默认头已存在 `Dart/x.y (dart:io)`，
/// `add` 会拼成 `Dart/3.13 (dart:io), WebHTV-PC/0.1 (Windows)` —— 豆瓣照样 418。
const String imageUserAgent = 'WebHTV-PC/0.1 (Windows)';

/// 计算某个图片 URL 应当携带的请求 Header。
///
/// 返回**空 [HeaderMap]** 的含义是「不要给 `Image.network` 传 `headers`」：
/// `NetworkImage` 的相等/哈希包含 headers（`MapEquality`），传 `{}` 与不传是
/// 两个不同的缓存键——无条件传空表会白白击穿既有图片缓存。因此只有在真的
/// 有 Header 要注入时才返回非空表。
///
/// `extra` 是**兜底层**：只在全局规则没给出同名键时生效。用户配置里显式写下的
/// 值永远优先，不会被调用方的兜底 Header 悄悄覆盖。
HeaderMap imageHeadersFor(
  List<HeaderRule> rules,
  String url, {
  Map<String, String> extra = const {},
}) {
  final uri = Uri.tryParse(url.trim());
  final host = uri?.host ?? '';
  if (host.isEmpty) return HeaderMap();
  // `extra` 在前、全局规则在后：用户配置必须压过调用方的兜底值。
  final merged = HeaderMap.merge([
    if (extra.isNotEmpty) HeaderMap(extra),
    globalHeadersFor(rules, host),
  ]);
  // 刻意**不**在这里补 `User-Agent`：`NetworkImage` 用 `headers.add()` 写入，
  // 会与 `dart:io` 默认的 `Dart/x.y (dart:io)` 拼成多值，反被防盗链拒绝。
  // UA 由 `image_user_agent.dart` 的 `HttpOverrides` 在客户端层替换。
  return merged;
}
