/// 背景图上的渐变遮罩：让压在上面的文字在任何图片上都读得清。
///
/// 遮罩按内容区域分工，不是同一底板的深浅变体：
/// - [BackdropScrimKind.hero]：首屏 hero。内容贴底，底部必须压到接近不透明，
///   否则白字落在亮画面上就没法读；顶部保留 0.42，让画面仍然看得见。
/// - [BackdropScrimKind.page]：页面级固定背景。整页内容都浮在图上、正文会滚到
///   下半屏，遮罩必须轻且大体均匀，否则滚到下面图就消失了。
/// - [BackdropScrimKind.toolbar]：标题与操作区只留轻薄渐隐，末端透明。
///
/// 为什么要独立成文件：详情页 hero（`tmdb_detail_view.dart`）与首页 hero
/// （`home_hero.dart`）必须给出**同一套数值**——它们看起来是同一个世界的两种用法。
/// 两处各写一份渐变，调其中一处就会漂。
library;

import 'package:flutter/material.dart';

enum BackdropScrimKind {
  /// 首屏 hero：底部压到不透明，保证标题/按钮可读。
  hero,

  /// 页面级固定背景：轻而均匀，保证滚下去正文还在图上。
  page,

  /// 详情顶栏的轻遮罩，末端透明，不形成独立横条。
  toolbar,
}

class BackdropScrim extends StatelessWidget {
  const BackdropScrim({super.key, this.kind = BackdropScrimKind.hero});

  final BackdropScrimKind kind;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final alphas = switch (kind) {
      BackdropScrimKind.hero => const [0.42, 0.40, 0.78, 1.0],
      BackdropScrimKind.page => const [0.62, 0.66, 0.74, 0.84],
      BackdropScrimKind.toolbar => const [0.18, 0.08, 0.0, 0.0],
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            for (final alpha in alphas) surface.withValues(alpha: alpha),
          ],
          stops: const [0, 0.45, 0.78, 1],
        ),
      ),
    );
  }
}
