import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/episode_aggregation.dart';

Future<EpisodeVersion?> showEpisodeVersionDialog(
  BuildContext context, {
  required EpisodeGroup group,
  String lineName = '',
  String? preferredUrl,
}) {
  if (group.versions.isEmpty) return Future.value();
  return showDialog<EpisodeVersion>(
    context: context,
    builder: (_) => _EpisodeVersionDialog(
      group: group,
      lineName: lineName,
      preferredUrl: preferredUrl,
    ),
  );
}

class _EpisodeVersionDialog extends StatefulWidget {
  const _EpisodeVersionDialog({
    required this.group,
    required this.lineName,
    this.preferredUrl,
  });
  final EpisodeGroup group;
  final String lineName;
  final String? preferredUrl;

  @override
  State<_EpisodeVersionDialog> createState() => _EpisodeVersionDialogState();
}

class _EpisodeVersionDialogState extends State<_EpisodeVersionDialog> {
  late int _selected = _initialSelection();
  late final _optionKeys = List.generate(
    widget.group.versions.length,
    (_) => GlobalKey(),
  );

  @override
  void initState() {
    super.initState();
    _revealSelection();
  }

  void _revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _optionKeys[_selected].currentContext;
      if (target != null) Scrollable.ensureVisible(target, alignment: .5);
    });
  }

  void _select(int index) {
    setState(
      () => _selected = index.clamp(0, widget.group.versions.length - 1),
    );
    _revealSelection();
  }

  int _initialSelection() {
    final index = widget.group.versions.indexWhere(
      (version) => version.episode.url == widget.preferredUrl,
    );
    return index < 0 ? 0 : index;
  }

  void _confirm() =>
      Navigator.of(context).pop(widget.group.versions[_selected]);

  void _activateKeyboard() {
    ButtonStyleButton? action;
    FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
      element,
    ) {
      if (element.widget is ButtonStyleButton) {
        action = element.widget as ButtonStyleButton;
        return false;
      }
      return true;
    });
    if (action != null) {
      action!.onPressed?.call();
    } else {
      _confirm();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
        const SingleActivator(LogicalKeyboardKey.enter): _activateKeyboard,
        const SingleActivator(LogicalKeyboardKey.numpadEnter):
            _activateKeyboard,
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _select(_selected + 1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _select(_selected - 1),
      },
      child: Focus(
        autofocus: true,
        child: AlertDialog(
          key: const ValueKey('episode-version-dialog'),
          title: Text('选择播放版本 · ${widget.group.label}'),
          content: SizedBox(
            width: 600,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .55,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.lineName.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          widget.lineName,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    for (var i = 0; i < widget.group.versions.length; i++)
                      _option(theme, widget.group.versions[i], i),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('episode-version-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('episode-version-confirm'),
              onPressed: _confirm,
              child: const Text('播放所选版本'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _option(ThemeData theme, EpisodeVersion version, int index) {
    final selected = index == _selected;
    return Padding(
      key: _optionKeys[index],
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: InkWell(
          key: ValueKey('episode-version-option-${version.sourceIndex}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => _select(index),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        version.label.isEmpty
                            ? '版本 ${index + 1}'
                            : version.label,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        version.episode.name,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (version.fileSize != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            version.fileSize!.label,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
