import 'package:flutter/material.dart';

import '../core/home_feed.dart';
import 'app_motion.dart' show reducedMotionOf;
import 'backdrop_scrim.dart';
import 'poster_image.dart';

/// 页面级背景只跟随 hero 下标，不单独轮播。
class HomeBackdrop extends StatelessWidget {
  const HomeBackdrop({super.key, required this.items, required this.index, this.onImageError});

  final List<HomeItem> items;
  final int index;
  final ValueChanged<HomeItem>? onImageError;

  @override
  Widget build(BuildContext context) {
    final backdrop = items.isEmpty
        ? ''
        : (items[index % items.length].backdrop ?? '').trim();
    return SizedBox.expand(
      key: const ValueKey('home-backdrop'),
      child: AnimatedSwitcher(
        duration: reducedMotionOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 600),
        child: backdrop.isEmpty
            ? SizedBox.expand(
                key: const ValueKey('home-backdrop-plain'),
                child: ColoredBox(color: Theme.of(context).colorScheme.surface),
              )
            : SizedBox.expand(
                key: ValueKey(backdrop),
                // 图与遮罩一起淡出，切到无图条目时也不会闪出未压暗的旧图。
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PosterImage(
                      url: backdrop,
                      onImageError: () => onImageError?.call(items[index % items.length]),
                      fit: BoxFit.cover,
                      alignment: Alignment.topCenter,
                    ),
                    const BackdropScrim(kind: BackdropScrimKind.page),
                  ],
                ),
              ),
      ),
    );
  }
}
