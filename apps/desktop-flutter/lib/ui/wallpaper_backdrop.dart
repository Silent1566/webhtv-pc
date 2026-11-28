import 'package:flutter/material.dart';

import 'image_header_scope.dart';
import 'tokens.dart';

/// Static art keeps glass visible without shipping a content source or animation.
class DefaultGlassBackdrop extends StatelessWidget {
  const DefaultGlassBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: const [0, .48, 1],
            colors: dark
                ? [
                    scheme.surfaceContainerHighest,
                    scheme.surface,
                    scheme.surfaceContainerLow,
                  ]
                : [
                    scheme.surfaceContainerHighest,
                    scheme.surface,
                    scheme.surfaceContainer,
                  ],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-.85, -.6),
                  radius: 1.25,
                  colors: [
                    scheme.primary.withValues(alpha: dark ? .13 : .09),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(.85, .65),
                  radius: 1.05,
                  colors: [
                    scheme.surfaceContainerHighest.withValues(alpha: .85),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Configured art wins; missing, loading and failed art use the static backing.
class WallpaperBackdrop extends StatefulWidget {
  const WallpaperBackdrop({
    super.key,
    required this.url,
    required this.builder,
  });

  final String? url;
  final Widget Function(BuildContext, bool hasArtwork) builder;

  @override
  State<WallpaperBackdrop> createState() => _WallpaperBackdropState();
}

class _WallpaperBackdropState extends State<WallpaperBackdrop> {
  final _shellKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final target = widget.url?.trim() ?? '';
    Widget shellOver(Widget? image) => Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(child: DefaultGlassBackdrop()),
        if (image != null) ...[
          Positioned.fill(child: image),
          Positioned.fill(
            child: ColoredBox(color: context.semanticColors.wallpaperVeil),
          ),
        ],
        KeyedSubtree(key: _shellKey, child: widget.builder(context, true)),
      ],
    );
    if (target.isEmpty) return shellOver(null);
    return Image.network(
      target,
      fit: BoxFit.cover,
      excludeFromSemantics: true,
      headers: imageHeadersOrNull(context, target),
      frameBuilder: (_, image, frame, _) =>
          shellOver(frame == null ? null : image),
      errorBuilder: (_, _, _) => shellOver(null),
    );
  }
}
