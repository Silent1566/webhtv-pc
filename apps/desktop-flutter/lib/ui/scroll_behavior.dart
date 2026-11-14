/// 桌面端滚动行为：让**鼠标**也能拖拽横向滚动容器。
///
/// 为什么需要这一层：Flutter 的 `ScrollBehavior.dragDevices` 默认**不含**
/// `PointerDeviceKind.mouse`（`scroll_configuration.dart` 的
/// `_kTouchLikeDeviceTypes` 只有 touch / stylus / invertedStylus / trackpad /
/// unknown）。桌面端因此**所有**滚动容器都收不到鼠标拖拽。
///
/// 用户反馈（2026-10-20）：「列表模式的集数卡片，剧照，包含等卡片都没办法
/// 左右拖拽显示更多内容」。根因就是上面这个默认值：详情页的剧集卡片条、
/// 剧照墙、海报墙、演职人员、相关推荐、线路 chip 条都只能靠「Shift + 滚轮」
/// 或拖滚动条才能看到右侧内容。而 `docs/webhtv-pc-design.md` §17.4 明确
/// 要求「支持鼠标拖拽」。
///
/// 为什么**不**挂到 `MaterialApp.scrollBehavior` 一次解决：实测（本仓库的
/// widget 测试，鼠标事件 `PointerDeviceKind.mouse`）把 mouse 加进全局
/// `dragDevices` 后，竖直列表里的
/// 1. `SelectableText` 拖动选中变成滚动页面（配置页/日志页会把用户选中的文字
///    滚走）；
/// 2. `ReorderableDragStartListener`（播放器按钮排序手柄）拖不动了。
/// 这两处都是「鼠标拖拽」本来必须保留给内容的手势。用户真正拖不动的只有
/// 横向媒体条，所以只在这类容器上局部生效：见 [HorizontalMouseDrag]。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 启用了鼠标拖拽的滚动行为（其余设备沿用框架默认）。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  /// 与 `_kTouchLikeDeviceTypes` 一致，只多一个鼠标。
  static const Set<PointerDeviceKind> _dragDevices = <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.mouse,
    PointerDeviceKind.unknown,
  };

  @override
  Set<PointerDeviceKind> get dragDevices => _dragDevices;
}

/// 给**横向**滚动容器开启鼠标拖拽（竖直滚动保持框架默认）。
///
/// 用法：直接包住横向的 `ListView` / `SingleChildScrollView`。
/// 只影响被包住的那棵子树——外层竖直列表、同页 `SelectableText` 的
/// 文字选中与排序手柄都不受影响（原因见文件头）。
class HorizontalMouseDrag extends StatelessWidget {
  const HorizontalMouseDrag({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: const AppScrollBehavior(),
      child: child,
    );
  }
}
