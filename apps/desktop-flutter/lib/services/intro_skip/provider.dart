/// 片头片尾**远端标定**的数据源接口（对齐安卓 `IntroSkipService` 的多源查询）。
///
/// 边界：
/// - provider 只产出 [RawSkipSegment]：数据源自己那条时间轴上的**原始**段。
///   折算到本地片源、去重、排序都是 `SkipPlan.resolve` 的事，这里一件不做。
/// - 不抛异常：网络、状态码、JSON 结构任何一环出问题都折成返回值，调用方按
///   「三态」区分（见 [IntroSkipProvider.fetch]）。
/// - 不碰全局状态、不打日志：一次 fetch 的输入只有 [SkipQuery] 与注入的
///   `http.Client`，测试可以完全不联网。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/skip_plan.dart';

/// 一家远端数据源。
abstract class IntroSkipProvider {
  const IntroSkipProvider();

  /// 稳定 id（`introdb` / `theintrodb` / `todb`）：既是 `SkipSourceBits` 的
  /// 键，也是 [RawSkipSegment.provider] 的值。
  String get id;

  /// 展示名。
  String get name;

  /// 在 `SkipSourceBits` 里占的位。
  int get sourceBit;

  /// 查一集的原始段。
  ///
  /// 返回值是**三态**，不是「有/无」两态：
  /// - `null`：这家**没答上来**（超时、非 2xx、坏 JSON、结构不认识）。不能当
  ///   结论缓存，下次还得再问；
  /// - 空列表：明确的「这集没数据」（404，或 200 但没有任何可用标记）。可以
  ///   缓存，因为这一家确实被问过并答完了；
  /// - 非空：解析出的原始段，可能混着多源多版本的重复段，去重交给
  ///   `SkipPlan.resolve`。
  Future<List<RawSkipSegment>?> fetch(
    SkipQuery query, {
    required http.Client client,
  });
}

// --- 三家共用的解析工具 -------------------------------------------------------
//
// 外部 JSON 一律当不可信输入：字段缺失、类型不对、数值离谱都不得抛出，只降级。

/// 2xx 视为成功。
bool skipIsSuccessStatus(int statusCode) =>
    statusCode >= 200 && statusCode < 300;

/// 解出响应体的 JSON 对象；不是 JSON、不是对象都返回 null（= 这家没答上来）。
///
/// 走 `bodyBytes` 自己按 UTF-8 解码，而不是 `response.body`：后者按
/// `content-type` 的 charset 猜，缺 charset 时按 latin1 解，中文版本名会变乱码。
Map<String, Object?>? skipDecodeJsonObject(http.Response response) {
  try {
    final decoded = jsonDecode(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
    if (decoded is Map<String, Object?>) return decoded;
    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value as Object?),
      );
    }
    return null;
  } catch (_) {
    // JSON 语法错误、编码被截断：都属于「这家没答上来」。
    return null;
  }
}

/// 读出 JSON 里的数值；不是数值或 NaN/Infinity 都当坏值丢弃。
num? skipJsonNumber(Object? raw) => raw is num && raw.isFinite ? raw : null;

/// 毫秒字段（数据源本来就按毫秒给）。
int? skipJsonMs(Object? raw) {
  final value = skipJsonNumber(raw);
  if (value == null) return null;
  return _clampMs(value);
}

/// 秒字段 → 毫秒（IntroDB 的 `*_sec`、TODB 的 `time_start`/`time_end`）。
int? skipJsonSecondsToMs(Object? raw) {
  final value = skipJsonNumber(raw);
  if (value == null) return null;
  return _clampMs(value * 1000);
}

/// 夹取而不是截断绕回：负值夹到 0，超上限夹到 `skipMaxMediaTimeMs`。
///
/// 先在 double 域夹住再 `round()`，避免离谱到超出 int64 的值在取整时溢出。
int _clampMs(num milliseconds) {
  if (milliseconds <= 0) return 0;
  if (milliseconds >= skipMaxMediaTimeMs) return skipMaxMediaTimeMs;
  return milliseconds.round();
}

/// 置信度，夹到 0..1；缺省与 [RawSkipSegment.confidence] 的默认值一致。
double skipJsonConfidence(Object? raw) {
  final value = skipJsonNumber(raw);
  if (value == null) return 0.5;
  if (value <= 0) return 0;
  if (value >= 1) return 1;
  return value.toDouble();
}

/// 提交次数，夹到 0..`skipMaxSubmissionCount`。
int skipJsonSubmissionCount(Object? raw) {
  final value = skipJsonNumber(raw);
  if (value == null) return 0;
  if (value <= 0) return 0;
  if (value >= skipMaxSubmissionCount) return skipMaxSubmissionCount;
  return value.round();
}

/// 读一个 JSON 对象字段；不是对象就返回 null（IntroDB 的顶层四段就是对象）。
Map<String, Object?>? skipJsonObject(Object? raw) {
  if (raw is! Map) return null;
  return raw.map((key, value) => MapEntry(key.toString(), value as Object?));
}

/// 把 JSON 数组读成一串对象；非对象元素逐个丢弃，不连累整个数组。
List<Map<String, Object?>> skipJsonObjects(Object? raw) {
  if (raw is! List) return const <Map<String, Object?>>[];
  final result = <Map<String, Object?>>[];
  for (final item in raw) {
    final object = skipJsonObject(item);
    if (object != null) result.add(object);
  }
  return result;
}
