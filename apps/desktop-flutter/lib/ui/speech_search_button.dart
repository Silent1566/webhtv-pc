import 'package:flutter/material.dart';

import '../services/speech_search_service.dart';

/// 可嵌入语音搜索按钮：回调首条识别文本；不可用时显示系统真实错误，不虚构离线。
class SpeechSearchButton extends StatefulWidget {
  const SpeechSearchButton({
    super.key,
    this.service,
    this.language,
    required this.onRecognized,
    this.tooltip = '语音搜索',
  });
  final SpeechSearchService? service;
  final String? language;
  final ValueChanged<String> onRecognized;
  final String tooltip;
  @override
  State<SpeechSearchButton> createState() => _SpeechSearchButtonState();
}

class _SpeechSearchButtonState extends State<SpeechSearchButton> {
  SpeechSearchService? _owned;
  SpeechSearchService get service =>
      widget.service ?? (_owned ??= SpeechSearchService());
  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _SpeechSearchDialog(service: service, language: widget.language),
    );
    if (text != null && text.isNotEmpty && mounted) widget.onRecognized(text);
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: widget.tooltip,
    icon: const Icon(Icons.mic_none),
    onPressed: _start,
  );
}

class _SpeechSearchDialog extends StatefulWidget {
  const _SpeechSearchDialog({required this.service, this.language});
  final SpeechSearchService service;
  final String? language;
  @override
  State<_SpeechSearchDialog> createState() => _SpeechSearchDialogState();
}

class _SpeechSearchDialogState extends State<_SpeechSearchDialog> {
  late Future<String?> _pending;
  @override
  void initState() {
    super.initState();
    _pending = widget.service.listen(language: widget.language);
  }

  @override
  void dispose() {
    widget.service.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('语音搜索'),
      content: FutureBuilder<String?>(
        future: _pending,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Row(
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(),
                ),
                const SizedBox(width: 16),
                Text(widget.service.message),
              ],
            );
          }
          final text = snapshot.data;
          return Text(text ?? widget.service.message);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () async {
            final text = await _pending;
            if (context.mounted && text != null) {
              Navigator.of(context).pop(text);
            }
          },
          child: const Text('使用该文本'),
        ),
      ],
    );
  }
}
