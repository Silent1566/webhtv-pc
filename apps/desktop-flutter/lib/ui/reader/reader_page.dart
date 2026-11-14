import 'package:flutter/material.dart';

import '../../core/reader/reader_models.dart';
import '../../services/app_paths.dart';
import '../../services/reader/reader_tts_controller.dart';
import '../../services/reader/tts_engines.dart';

/// 音源显示名（面板与状态栏共用，避免两处文案漂移）。
String readerSourceLabel(TtsSource source) => switch (source) {
  TtsSource.system => '系统语音',
  TtsSource.edge => 'Edge Neural',
  TtsSource.baidu => '百度在线',
  TtsSource.custom => '自定义在线',
};

/// 必要阅读文本入口 + 段落朗读面板。
///
/// 默认构造自建持久化偏好、引擎与播放输出（[TtsEngines.create]），因此 Task6 只需
/// `ReaderPage(initialText: ..., title: ...)` 即可进入；也允许显式注入 controller 复用。
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    this.controller,
    this.initialText = '',
    this.title = '阅读器',
  });

  final ReaderTtsController? controller;
  final String initialText;
  final String title;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  ReaderTtsController? _owned;

  ReaderTtsController get _controller =>
      widget.controller ??
      (_owned ??= TtsEngines.create(configDir: AppPaths.resolve().configDir));

  @override
  void initState() {
    super.initState();
    _controller.loadPreferences();
  }

  @override
  void dispose() {
    // 只关闭自己创建的 controller；注入方负责自己的生命周期。
    _owned?.close();
    super.dispose();
  }

  List<String> get _paragraphs => widget.initialText
      .split(RegExp(r'\n+'))
      .map((paragraph) => paragraph.trim())
      .where((paragraph) => paragraph.isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final paragraphs = _paragraphs;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: '开始朗读',
            onPressed: paragraphs.isEmpty
                ? null
                : () => controller.start(
                    paragraphs: paragraphs,
                    title: widget.title,
                  ),
          ),
          AnimatedBuilder(
            animation: controller,
            builder: (context, _) => IconButton(
              icon: Icon(
                controller.state == ReaderTtsState.paused
                    ? Icons.play_arrow
                    : Icons.pause,
              ),
              tooltip: controller.state == ReaderTtsState.paused
                  ? '继续朗读'
                  : '暂停',
              onPressed: controller.isActive ? controller.toggle : null,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.stop),
            tooltip: '停止',
            onPressed: () => controller.stop(),
          ),
          IconButton(
            icon: const Icon(Icons.skip_previous),
            tooltip: '上一段',
            onPressed: controller.previous,
          ),
          IconButton(
            icon: const Icon(Icons.skip_next),
            tooltip: '下一段',
            onPressed: controller.next,
          ),
          IconButton(
            icon: const Icon(Icons.timer_outlined),
            tooltip: '定时朗读',
            onPressed: _pickTimer,
          ),
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '朗读设置',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusBar(controller: controller),
            Expanded(
              child: paragraphs.isEmpty
                  ? const Center(child: Text('没有可朗读的内容'))
                  : SelectionArea(
                      child: ListView.builder(
                        itemCount: paragraphs.length,
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 8,
                          ),
                          child: Text(
                            paragraphs[index],
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(
                                  color: index == controller.currentParagraph
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTimer() async {
    var minutes = _controller.timerMinutes == 0 ? 15 : _controller.timerMinutes;
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('定时朗读'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => RadioGroup<int>(
            groupValue: minutes,
            onChanged: (value) =>
                setDialogState(() => minutes = value ?? minutes),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in const [15, 30, 60, 120])
                  RadioListTile<int>(value: option, title: Text('$option 分钟')),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 0),
            child: const Text('取消定时'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, minutes),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (selected != null) await _controller.setTimer(selected);
  }

  Future<void> _openSettings() => showDialog<void>(
    context: context,
    builder: (dialogContext) =>
        ReaderTtsSettingsDialog(controller: _controller),
  );
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller});

  final ReaderTtsController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = controller.paragraphCount;
    final current = controller.currentParagraph;
    final parts = <String>[
      '音源：${readerSourceLabel(controller.source)}',
      if (controller.state == ReaderTtsState.paused) '已暂停',
      if (total > 0) '段落：${current < 0 ? '-' : current + 1}/$total',
      if (controller.timerMinutes > 0) '定时：${controller.timerMinutes} 分钟',
      if (controller.message.isNotEmpty) controller.message,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Text(
        parts.join('　'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: controller.state == ReaderTtsState.error
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 朗读设置：音源、音色、语速、音调、自定义在线引擎规则；改动即落盘（重启恢复）。
class ReaderTtsSettingsDialog extends StatefulWidget {
  const ReaderTtsSettingsDialog({super.key, required this.controller});

  final ReaderTtsController controller;

  @override
  State<ReaderTtsSettingsDialog> createState() =>
      _ReaderTtsSettingsDialogState();
}

class _ReaderTtsSettingsDialogState extends State<ReaderTtsSettingsDialog> {
  late final TextEditingController _customUrl;
  List<TtsVoice> _voices = const [];
  String? _voiceNotice;

  ReaderTtsController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _customUrl = TextEditingController(
      text: controller.settings.custom?.url ?? '',
    );
    _loadVoices();
  }

  @override
  void dispose() {
    _customUrl.dispose();
    super.dispose();
  }

  Future<void> _loadVoices() async {
    final (voices, notice) = await controller.availableVoices();
    if (!mounted) return;
    setState(() {
      _voices = voices;
      _voiceNotice = notice;
    });
  }

  @override
  Widget build(BuildContext context) {
    final options = controller.options;
    return AlertDialog(
      title: const Text('朗读设置'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('音源'),
              Wrap(
                spacing: 8,
                children: [
                  for (final source in TtsSource.values)
                    ChoiceChip(
                      label: Text(readerSourceLabel(source)),
                      selected: controller.source == source,
                      onSelected: (_) async {
                        await controller.setSource(source);
                        await _loadVoices();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _sourceHint(controller.source),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (controller.source == TtsSource.custom) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _customUrl,
                  decoration: const InputDecoration(
                    labelText: '自定义在线引擎规则',
                    helperText: '仅支持 GET/POST 与 {{speakText}}/{{speakSpeed}}/java.encodeURI/算术',
                  ),
                  onSubmitted: _saveCustom,
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _voices.any((voice) => voice.id == options.voice)
                    ? options.voice
                    : null,
                decoration: InputDecoration(
                  labelText: '音色',
                  helperText: _voiceNotice,
                ),
                items: [
                  for (final voice in _voices)
                    DropdownMenuItem(
                      value: voice.id,
                      child: Text('${voice.name}（${voice.language}）'),
                    ),
                ],
                onChanged: (value) => controller.setVoice(value ?? ''),
              ),
              const SizedBox(height: 12),
              Text('语速 ${options.rate.toStringAsFixed(2)}x'),
              Slider(
                value: options.rate,
                min: 0.5,
                max: 2,
                divisions: 15,
                label: '${options.rate.toStringAsFixed(2)}x',
                onChanged: controller.setRate,
              ),
              Text('音调 ${options.pitch.toStringAsFixed(2)}x（仅 Edge Neural 生效）'),
              Slider(
                value: options.pitch,
                min: 0.5,
                max: 1.5,
                divisions: 10,
                label: '${options.pitch.toStringAsFixed(2)}x',
                onChanged: controller.setPitch,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Future<void> _saveCustom(String value) async {
    final url = value.trim();
    await controller.setCustom(url.isEmpty ? null : TtsCustomConfig(url: url));
    await _loadVoices();
  }

  static String _sourceHint(TtsSource source) => switch (source) {
    TtsSource.system => '使用 Windows 已安装的系统语音；是否离线取决于该语音包本身。',
    TtsSource.edge => '微软 Edge 大声朗读协议，需联网；协议非公开，可能随上游变化。',
    TtsSource.baidu => '百度翻译发音接口，需联网，音色单一、无音调。',
    TtsSource.custom => '自定义在线引擎按你的规则联网合成；不会执行脚本或启动进程。',
  };
}
