import 'package:flutter/material.dart';

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
      border: const OutlineInputBorder(),
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
}) => PopupMenuButton<String>(
  key: key,
  tooltip: '筛选$label',
  initialValue: value,
  onSelected: onChanged,
  itemBuilder: (context) => [
    for (final option in options)
      PopupMenuItem<String>(value: option, child: Text(option)),
  ],
  child: Container(
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.sm,
      vertical: AppSpace.xs,
    ),
    decoration: BoxDecoration(
      borderRadius: AppRadius.smAll,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label：$value', style: Theme.of(context).textTheme.bodySmall),
        const Icon(Icons.arrow_drop_down, size: 18),
      ],
    ),
  ),
);
