/// 图片请求 Header 的作用域（§7.4.6）。
///
/// 为什么用 `InheritedWidget` 而不是逐点传参：`PosterImage` 有 20 个调用点，
/// 其中 13 个在 TMDB 系列（`tmdb_detail_view.dart` / `tmdb_widgets.dart`），
/// 那些 widget 只接收纯数据与回调（`TmdbDetailView` 的构造参数里没有 `AppState`），
/// 逐点透传要把规则一路穿过 5+ 层 widget 与 `showDialog` 弹出层。
///
/// 挂在 `MaterialApp.builder` 上即可覆盖全部图片位：builder 位于 **Navigator 之上**，
/// 所有 push 出来的路由、`showDialog`、`showModalBottomSheet` 都是它的后代。
///
/// 没有作用域时（例如既有单测直接 pump `PosterImage`）[maybeRules] 返回 null，
/// 调用方退回「不传 headers」，行为与改造前**完全一致**。
library;

import 'package:flutter/widgets.dart';

import '../core/image_headers.dart';
import '../core/protocol.dart';

class ImageHeaderScope extends InheritedWidget {
  const ImageHeaderScope({
    super.key,
    required this.rules,
    required super.child,
  });

  /// 顶层 `headers` 规则（配置顺序，后匹配者覆盖同名键）。
  final List<HeaderRule> rules;

  /// 取当前作用域的规则；不在作用域内返回 null。
  static List<HeaderRule>? maybeRules(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ImageHeaderScope>()?.rules;

  /// 按 **List 身份**比较即可：规则列表来自稳定配置对象（`AppConfig.headers`），
  /// 普通状态变更不会产生新实例，避免无谓重建依赖者。
  @override
  bool updateShouldNotify(ImageHeaderScope oldWidget) =>
      !identical(rules, oldWidget.rules);
}

/// 图片位的统一入口：算出可直接交给 `Image.network(headers:)` 的表。
///
/// 返回 `null` 表示**不要传 `headers`**——`NetworkImage` 的相等/哈希包含 headers，
/// 传空表与不传是两个缓存键，无条件传空表会击穿既有图片缓存
/// （详见 `core/image_headers.dart` 中 [imageHeadersFor] 的说明）。
Map<String, String>? imageHeadersOrNull(
  BuildContext context,
  String url, {
  Map<String, String> extra = const {},
}) {
  final headers = imageHeadersFor(
    ImageHeaderScope.maybeRules(context) ?? const <HeaderRule>[],
    url,
    extra: extra,
  );
  return headers.isEmpty ? null : headers.asRequestHeaders;
}
