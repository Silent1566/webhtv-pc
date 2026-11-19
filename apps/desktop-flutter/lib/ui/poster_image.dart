/// 图片位：站点图床可能失效，用占位符而不是抛错（§7.4.6）。
///
/// 为什么单独成文件：`PosterImage` 在首页、TMDB 与详情页共有 20+ 个引用点，
/// 留在 `app.dart`（2300 行的壳文件）里意味着任何图位改动都要动壳；
/// 它与外壳的路由/导航无关，唯一依赖是 image_header_scope.dart 里的头规则入口。
library;

import 'package:flutter/material.dart';

import 'image_header_scope.dart';

/// 图片加载：站点图床可能失效，用占位符而不是抛错。
/// 图片占位底色。
///
/// 刻意选 `surfaceContainerLow`（紧贴页面底色）而**不是** `surfaceContainerHigh`：
/// 后者在深色主题下比背景亮得多（≈#333 对 ≈#111），图上不来时就是一块突兀的
/// 灰块（用户反馈 2026-10-09：「大量地方存在这种无效的阴影或背景色区域太丑了」，
/// 截图里海报墙、缺失头像甚至网格里都是这种灰块）。换成低一档的容器色后，
/// 占位仍然存在（不会退化成「与页面同色的空洞」），但不会再抢视线。
Color _posterPlaceholderColor(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerLow;

class PosterImage extends StatelessWidget {
  const PosterImage({
    super.key,
    this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.cacheWidth,
    this.background = true,
    this.fallbackUrl,
    this.placeholder,
  });

  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// `BoxFit.cover` 裁切时保留图片的哪一块，默认居中。
  ///
  /// 只转发给 `Image.network` 的同名参数——**不会**引入外层 `Align`
  /// （见 [build] 里那条「绝不能给 Container 加 alignment」的注释），
  /// 因此不影响 cover 的铺满语义。
  ///
  /// 详情页背景轮播传 `Alignment.topCenter`：窗口比素材更高时（全屏 2.35:1
  /// 对 16:9 素材）cover 会纵向裁掉约 24%，居中裁等于上下各切一半，人物头顶
  /// 常被切到；改成顶部对齐后裁切全部落在底部——底部本来就被渐变遮罩压暗、
  /// 被标题/简介盖住，观感损失最小（用户反馈 2026-10-23：「同一个海报背景
  /// 全屏的时候被截取了不好看」）。
  final Alignment alignment;

  /// 解码宽度（物理像素）；固定尺寸图位应传逻辑宽度 × DPR，避免保留原尺寸位图。
  /// 只转发给 `Image.network`，不影响布局尺寸或 `fit`。
  final int? cacheWidth;

  /// 是否绘制占位底色，默认 `true`（普通图位需要它兜住"图还没到"的状态）。
  ///
  /// **叠层背景的上层必须传 `false`。** 这个底色是**不透明**的，而且这里的
  /// `Container` 会撑满父级给的紧约束——放在 `Stack` 里就会把下层的模糊垫底
  /// **整块盖住**。实测（2026-10-13）：详情页背景的"模糊延伸"因此**从来没有
  /// 渲染过**，屏幕上只有一块纯色信箱边加一个硬边图片，用户看到的就是这个
  /// （「怎么变得这么丑了」）。单元测试只断言了 `fit`，断言不到"谁盖住了谁"，
  /// 所以全绿也没拦住它。
  final bool background;

  /// 主图失败时**只重试一次**的后备图（剧集卡片的剧照 → 本剧海报）。
  ///
  /// 只在 [url] 加载失败、或 [url] 为空时换用；两者相同或后备为空时直接落占位，
  /// 因此不会出现同址递归。默认 `null`，其余调用方行为不变。
  final String? fallbackUrl;

  /// 无图/坏图时替代默认图标的占位内容（人物头像用姓名字标）。
  ///
  /// 默认 `null` → 沿用既有「灰底 + 图标」，其余调用方观感不变。
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    final target = url?.trim() ?? '';
    // 图片请求也要按目标 host 注入顶层 `headers` 规则（§7.4.6）：豆瓣图床这类
    // 防盗链站点不带 `Referer` 直接返回 418，而 `Image.network` 默认连 UA 都不带
    // （`dart:io` 的 `Dart/x.y (dart:io)` 同样被边缘节点拦掉，见 `core/image_headers.dart`）。
    //
    // 没有作用域时（单测直接 pump）返回 null，与改造前行为完全一致。
    // 底层永远是占位底色 + 图标，图片叠在上面。
    //
    // 为什么不能只靠 `loadingBuilder` 兜底（实测 2026-10-09，网盘聚合站慢图床）：
    // 慢速图床在**首帧产出之前**会走到 `progress == null` 分支，此时 `child` 是
    // 一个还没有图像的 `RawImage`（什么都不画），而占位符已经被跳过——结果整个
    // 格子与页面同色，看上去像「少了一部片」，实测要等 25s 图才出现。
    // 把占位符当底而不是当分支，就不存在“两个分支都画空”的窗口。
    //
    // **绝不能给这个 Container 加 `alignment`**（2026-10-10 实测根因）：
    // `Container(alignment:)` 会在子节点外包一层 `Align`，而 `Align` 给子节点的是
    // **松约束**；`Image` 在松约束且未给 width/height 时会退回**图片固有尺寸**，
    // 于是 `BoxFit.cover` 根本没有“盒子”可以铺——背景图与人物头像就变成
    // 「按原始尺寸居中、两侧露底色」（用户反馈「都没铺满」的真实根因）。
    // 去掉 alignment 后子节点拿到父级传入的**紧约束**，cover 才真正生效。
    // 占位图标需要居中，各自用 `Center` 包。
    //
    // 剧照缺失（空串）时**直接**用后备海报，不必先发一次注定失败的请求。
    final fallback = fallbackUrl?.trim() ?? '';
    final resolved = target.isEmpty ? fallback : target;
    final canFallback = fallback.isNotEmpty && fallback != resolved;
    final headers = imageHeadersOrNull(context, resolved);
    return Container(
      width: width,
      height: height,
      color: background ? _posterPlaceholderColor(context) : null,
      child: resolved.isEmpty
          ? _emptyPlaceholder(context)
          : Image.network(
              resolved,
              width: width,
              height: height,
              fit: fit,
              alignment: alignment,
              cacheWidth: cacheWidth,
              headers: headers,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : Center(child: _placeholderIcon(context, loading: true)),
              // 主图加载失败时换后备图**重试一次**；后备也没有（或与主图同址）
              // 就落回占位。后备图的 errorBuilder 直接给占位，不再递归。
              errorBuilder: (context, error, stackTrace) => canFallback
                  ? _fallbackImage(context, fallback)
                  : _emptyPlaceholder(context),
            ),
    );
  }

  /// 无图/坏图的占位。默认是居中图标；调用方给了 [placeholder] 时
  /// **原样**放进盒子（不包 `Center`），让人物字标这类整块面板能铺满。
  Widget _emptyPlaceholder(BuildContext context) =>
      placeholder ?? Center(child: _placeholderIcon(context));

  Widget _fallbackImage(BuildContext context, String target) {
    return Image.network(
      target,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      cacheWidth: cacheWidth,
      headers: imageHeadersOrNull(context, target),
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : Center(child: _placeholderIcon(context, loading: true)),
      errorBuilder: (context, error, stackTrace) => _emptyPlaceholder(context),
    );
  }

  Widget _placeholderIcon(BuildContext context, {bool loading = false}) {
    return Icon(
      loading ? Icons.downloading : Icons.image_not_supported_outlined,
      size: 20,
      color: Theme.of(context).disabledColor,
    );
  }
}
