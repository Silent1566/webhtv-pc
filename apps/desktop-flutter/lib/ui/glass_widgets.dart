import 'package:flutter/material.dart';

import 'glass_surface.dart';
import 'tokens.dart';

/// A readable panel. Video overlays disable sampling rather than filtering video.
class GlassPane extends StatelessWidget {
  const GlassPane({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = AppRadius.lgAll,
    this.blurBackdrop = true,
    this.showRim = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final bool blurBackdrop;
  final bool showRim;

  @override
  Widget build(BuildContext context) => GlassSurface(
    padding: padding,
    borderRadius: borderRadius,
    rimAlpha: showRim ? null : 0,
    blurSigma: blurBackdrop ? null : 0,
    saturation: blurBackdrop ? null : 1,
    tintAlpha: Theme.of(context).brightness == Brightness.dark
        ? (blurBackdrop ? AppGlass.tintAlphaDenseDark : .88)
        : (blurBackdrop ? .78 : .92),
    child: child,
  );
}
