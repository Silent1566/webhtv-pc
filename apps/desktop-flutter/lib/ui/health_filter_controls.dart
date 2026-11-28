import 'package:flutter/material.dart';

import 'glass_widgets.dart';
import 'tokens.dart';

/// Compact, wrapping filter row shared by the health history table and the
/// manual self-check result list.
class HealthFilterBar extends StatelessWidget {
  const HealthFilterBar({
    super.key,
    required this.summary,
    required this.children,
  });

  final String summary;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Wrap(
        spacing: AppSpace.md,
        runSpacing: AppSpace.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...children,
          Text(
            summary,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

Widget healthFilterNameField({
  required Key key,
  required TextEditingController controller,
  required String hint,
  required ValueChanged<String> onChanged,
}) => SizedBox(
  width: 240,
  child: TextField(
    key: key,
    controller: controller,
    decoration: InputDecoration(
      isDense: true,
      hintText: hint,
      prefixIcon: const Icon(Icons.search, size: 18),
    ),
    onChanged: onChanged,
  ),
);

/// A labelled popup selection. Closed state shows only the current value, so
/// option labels never leak into result-row text assertions.
Widget healthFilterSelect({
  required BuildContext context,
  required Key key,
  required String label,
  required String value,
  required List<String> options,
  required ValueChanged<String> onChanged,
}) => MenuAnchor(
  style: const MenuStyle(
    backgroundColor: WidgetStatePropertyAll(Colors.transparent),
    surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
    elevation: WidgetStatePropertyAll(0),
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
  ),
  builder: (context, menu, _) => Tooltip(
    message: '筛选$label',
    child: TextButton(
      key: key,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.sm,
          vertical: AppSpace.xs,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
      ),
      onPressed: () {
        if (menu.isOpen) {
          menu.close();
        } else {
          menu.open();
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label：$value', style: Theme.of(context).textTheme.bodySmall),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    ),
  ),
  menuChildren: [
    GlassPane(
      borderRadius: AppRadius.mdAll,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final option in options)
              MenuItemButton(
                onPressed: () => onChanged(option),
                child: Text(option),
              ),
          ],
        ),
      ),
    ),
  ],
);
