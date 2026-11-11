import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/audio_ai/model_catalog.dart';
import '../../core/audio_ai/pcm_sync.dart';
import '../../core/audio_ai/pitch_track.dart';
import '../../services/ai_completion_client.dart';
import '../../services/audio_ai/audio_model_manager.dart';
import '../../services/audio_ai/basic_pitch_service.dart';
import '../../services/audio_ai/realtime_subtitle_controller.dart';
import '../../services/audio_ai/srt_translation_service.dart';
import '../../services/audio_ai/windows_audio_capture.dart';
import '../tokens.dart';

Widget _error(BuildContext context, String message) => Semantics(
  liveRegion: true,
  child: Text(
    message,
    style: TextStyle(
      color:
          Theme.of(context).extension<AppSemanticColors>()?.statusFailed ??
          Theme.of(context).colorScheme.error,
    ),
  ),
);
Widget _progress(double? value, String label) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    LinearProgressIndicator(value: value),
    const SizedBox(height: 8),
    Semantics(liveRegion: true, child: Text(label)),
  ],
);

class AudioModelControls extends StatefulWidget {
  const AudioModelControls({
    super.key,
    required this.manager,
    required this.onSelected,
    this.modelId = 'zh',
    this.catalog = RealtimeModelCatalog.models,
  });
  final AudioModelManager manager;
  final ValueChanged<RealtimeModelSpec> onSelected;
  final String modelId;
  final List<RealtimeModelSpec> catalog;
  @override
  State<AudioModelControls> createState() => _AudioModelControlsState();
}

class _AudioModelControlsState extends State<AudioModelControls> {
  late RealtimeModelSpec _model;
  final _directory = TextEditingController();
  AiCancellationToken? _cancel;
  bool _busy = false;
  String _message = '', _errorText = '';
  double? _progressValue;
  @override
  void initState() {
    super.initState();
    _model = widget.catalog.firstWhere(
      (m) => m.id == widget.modelId,
      orElse: () => widget.catalog.first,
    );
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _directory.dispose();
    super.dispose();
  }

  Future<void> _execute(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _errorText = '';
      _message = '校验模型文件…';
      _progressValue = null;
    });
    try {
      await action();
      if (mounted) setState(() => _message = '模型文件已通过 SHA256 校验');
    } catch (error) {
      if (mounted) {
        setState(
          () => _errorText = _cancel?.isCancelled == true
              ? '下载已取消，保留断点'
              : error.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _download() {
    _cancel = AiCancellationToken();
    _execute(
      () => widget.manager.download(
        _model,
        cancellationToken: _cancel,
        onProgress: (value) {
          if (mounted) {
            setState(() {
              _progressValue = value.value;
              _message = '${value.file} · ${(value.value * 100).round()}%';
            });
          }
        },
      ),
    );
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型？'),
        content: Text('仅删除 ${_model.name} 的本地文件，不改变播放器。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await _execute(() => widget.manager.delete(_model));
    }
  }

  void _import() {
    if (_directory.text.trim().isEmpty) {
      setState(() => _errorText = '请输入本地模型目录');
      return;
    }
    _execute(
      () => widget.manager.importLocal(_model, {
        for (final file in _model.downloads)
          file.relativePath: p.join(_directory.text.trim(), file.relativePath),
      }),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('音频AI模型', style: Theme.of(context).textTheme.titleMedium),
      const Text('默认关闭；未配置模型不改变已有播放。权重按需下载或本地导入。'),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _model.id,
        decoration: const InputDecoration(labelText: '识别语言 / 模型'),
        items: [
          for (final model in widget.catalog)
            DropdownMenuItem(value: model.id, child: Text(model.name)),
        ],
        onChanged: _busy
            ? null
            : (id) {
                if (id != null) {
                  setState(
                    () => _model = widget.catalog.firstWhere((m) => m.id == id),
                  );
                  widget.onSelected(_model);
                }
              },
      ),
      const SizedBox(height: 8),
      Text(
        '${_model.minRamMb} MiB RAM建议 · SHA256固定 · 当前${widget.manager.isReadySync(_model) ? '文件齐全（启用前再次验签）' : '未下载'}',
      ),
      const Text('当前权重许可未核验（官方资料请求超时）；不能以引擎许可证代替。'),
      TextButton(
        onPressed: () async {
          final sources = await rootBundle.loadString(
            'lib/core/audio_ai/RESOURCE_SOURCES.md',
          );
          if (!context.mounted) return;
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('官方资源与权重许可'),
              content: SizedBox(
                width: 640,
                child: SingleChildScrollView(child: SelectableText(sources)),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            ),
          );
        },
        child: const Text('查看逐模型官方来源 / 许可'),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _directory,
        enabled: !_busy,
        decoration: const InputDecoration(
          labelText: '本地模型目录',
          hintText: r'C:\models\selected-model',
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
            onPressed: _busy ? null : _download,
            child: const Text('下载模型'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _import,
            child: const Text('本地导入'),
          ),
          TextButton(
            onPressed: _busy ? null : _delete,
            child: const Text('删除模型'),
          ),
          if (_busy)
            TextButton(
              onPressed: () => _cancel?.cancel(),
              child: const Text('取消下载'),
            ),
        ],
      ),
      if (_busy)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _progress(_progressValue, _message),
        ),
      if (!_busy && _message.isNotEmpty) Text(_message),
      if (_errorText.isNotEmpty) _error(context, _errorText),
    ],
  );
}

class RealtimeSubtitleControls extends StatefulWidget {
  const RealtimeSubtitleControls({
    super.key,
    required this.controller,
    required this.capture,
    required this.clock,
    required this.model,
    required this.mediaUri,
    this.headers = const {},
    this.playerProcessId,
  });
  final RealtimeSubtitleController controller;
  final WindowsAudioCapture capture;
  final AudioSessionClock clock;
  final RealtimeModelSpec model;
  final Uri mediaUri;
  final Map<String, String> headers;
  final int? playerProcessId;
  @override
  State<RealtimeSubtitleControls> createState() =>
      _RealtimeSubtitleControlsState();
}

class _RealtimeSubtitleControlsState extends State<RealtimeSubtitleControls> {
  bool _busy = false, _enabled = false;
  String _errorText = '';
  StreamSubscription? _stateSubscription, _captureSubscription;
  int _toggleEpoch = 0;
  @override
  void initState() {
    super.initState();
    _stateSubscription = widget.controller.states.listen((_) {
      if (mounted) setState(() {});
    });
    _captureSubscription = widget.capture.states.listen((state) {
      if (mounted) {
        setState(() {
          if (state == AudioCaptureState.error) {
            _errorText = widget.capture.lastError;
          }
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant RealtimeSubtitleControls old) {
    super.didUpdateWidget(old);
    if (old.mediaUri != widget.mediaUri ||
        old.clock.sessionId != widget.clock.sessionId ||
        old.model.id != widget.model.id) {
      _toggleEpoch++;
      _enabled = false;
      _busy = false;
      unawaited(widget.controller.stop());
      unawaited(widget.capture.stop());
    }
  }

  @override
  void dispose() {
    _toggleEpoch++;
    _stateSubscription?.cancel();
    _captureSubscription?.cancel();
    unawaited(widget.controller.stop());
    unawaited(widget.capture.stop());
    super.dispose();
  }

  /// 取消启用：推进 toggle epoch，使迟到的 verify/factory/capture 结果全部作废。
  void _cancelToggle() {
    _toggleEpoch++;
    _enabled = false;
    unawaited(widget.controller.stop());
    unawaited(widget.capture.stop());
    if (mounted) {
      setState(() {
        _busy = false;
        _errorText = '';
      });
    }
  }

  Future<void> _toggle() async {
    final epoch = ++_toggleEpoch;
    setState(() {
      _busy = true;
      _errorText = '';
    });
    try {
      if (_enabled) {
        await widget.controller.stop();
        await widget.capture.stop();
        if (epoch != _toggleEpoch || !mounted) return;
        _enabled = false;
      } else {
        // Verify/load before requesting extra media. Subscription is bound before capture emits.
        final ready = await widget.controller.start(
          spec: widget.model,
          pcm: widget.capture.frames,
          clock: widget.clock,
        );
        if (epoch != _toggleEpoch || !mounted) {
          await widget.controller.stop();
          return;
        }
        if (!ready) throw StateError(widget.controller.lastError);
        final capturing = await widget.capture.start(
          clock: widget.clock,
          mediaUri: widget.mediaUri,
          headers: widget.headers,
          playerProcessId: widget.playerProcessId,
        );
        if (epoch != _toggleEpoch || !mounted) {
          await widget.capture.stop();
          await widget.controller.stop();
          return;
        }
        if (!capturing) {
          await widget.controller.stop();
          throw StateError(widget.capture.lastError);
        }
        _enabled = true;
      }
    } catch (error) {
      if (mounted && epoch == _toggleEpoch) {
        setState(() => _errorText = error.toString());
      }
    } finally {
      if (mounted && epoch == _toggleEpoch) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '实时字幕 · ${widget.model.name}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      Text(widget.capture.captureMode),
      const Text('暂停不读取；seek/换集取消旧代际；外语译文8秒失败回原文。只停止字幕，不影响播放。'),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: _busy ? null : _toggle,
            child: Text(_enabled ? '关闭实时字幕' : '启用实时字幕'),
          ),
          if (_busy)
            TextButton(
              onPressed: _cancelToggle,
              child: const Text('取消启用'),
            ),
        ],
      ),
      Semantics(
        liveRegion: true,
        child: Text('状态：${widget.controller.state.name}'),
      ),
      if (_errorText.isNotEmpty) _error(context, _errorText),
      RealtimeSubtitleOverlay(
        controller: widget.controller,
        clock: widget.clock,
      ),
    ],
  );
}

/// Embeddable subtitle/search text, independent of existing track and danmaku controls.
///
/// 只显示呈现时钟落在 `[start, end]` 内的字幕：窗口到期、seek/换集或停止后
/// 立即消失；搜索候选取当前显示文本，不取过期缓存。
class RealtimeSubtitleOverlay extends StatefulWidget {
  const RealtimeSubtitleOverlay({
    super.key,
    required this.controller,
    required this.clock,
    this.onSearchText,
    this.tick = const Duration(milliseconds: 20),
  });
  final RealtimeSubtitleController controller;
  final AudioSessionClock clock;
  final ValueChanged<String>? onSearchText;
  final Duration tick;
  @override
  State<RealtimeSubtitleOverlay> createState() =>
      _RealtimeSubtitleOverlayState();
}

class _RealtimeSubtitleOverlayState extends State<RealtimeSubtitleOverlay> {
  RealtimeSubtitleCue? _shown;
  final List<RealtimeSubtitleCue> _pending = [];
  StreamSubscription<RealtimeSubtitleCue?>? _displaySubscription;
  StreamSubscription<int>? _clockSubscription;
  Timer? _ticker;
  int _clockSession = -1;
  int _clockGeneration = -1;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _bind() {
    _displaySubscription = widget.controller.display.listen(_onCue);
    _clockSession = widget.clock.sessionId;
    _clockGeneration = widget.clock.generation;
    _clockSubscription = widget.clock.changes.listen((_) {
      if (_clockSession != widget.clock.sessionId ||
          _clockGeneration != widget.clock.generation) {
        _clockSession = widget.clock.sessionId;
        _clockGeneration = widget.clock.generation;
        _clear();
      } else {
        _refresh();
      }
    });
    _ticker = Timer.periodic(widget.tick, (_) {
      widget.controller.tickDisplay();
      _refresh();
    });
  }

  void _onCue(RealtimeSubtitleCue? cue) {
    if (!mounted) return;
    if (cue == null) {
      _clear();
      return;
    }
    if (!widget.clock.isCurrent(
      sessionId: cue.sessionId,
      generation: cue.generation,
    )) {
      return;
    }
    _pending.add(cue);
    if (_pending.length > 8) _pending.removeAt(0);
    _refresh();
  }

  /// 只按呈现时钟选择窗口内的 cue；未到期不上屏，到期即清屏。
  void _refresh() {
    if (!mounted) return;
    final position = widget.clock.position;
    _pending.removeWhere((cue) => position >= cue.end);
    RealtimeSubtitleCue? selected;
    for (final cue in _pending) {
      if (position >= cue.start && position < cue.end) selected = cue;
    }
    if (selected != _shown) setState(() => _shown = selected);
  }

  void _clear() {
    if (!mounted) return;
    _pending.clear();
    if (_shown != null) setState(() => _shown = null);
  }

  void _unbind() {
    _displaySubscription?.cancel();
    _clockSubscription?.cancel();
    _ticker?.cancel();
    _displaySubscription = null;
    _clockSubscription = null;
    _ticker = null;
  }

  @override
  void didUpdateWidget(covariant RealtimeSubtitleOverlay old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller || old.clock != widget.clock) {
      _unbind();
      _pending.clear();
      _shown = null;
      _bind();
    }
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cue = _shown;
    if (cue == null) return const SizedBox.shrink();
    final text = cue.translatedText.isEmpty ? cue.text : cue.translatedText;
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(text),
          if (cue.translatedText.isNotEmpty && cue.translatedText != cue.text)
            Text(cue.text),
          if (widget.onSearchText != null)
            TextButton(
              onPressed: () => widget.onSearchText!(text),
              child: const Text('用当前字幕搜索'),
            ),
        ],
      ),
    );
  }
}

class SrtTranslationControls extends StatefulWidget {
  const SrtTranslationControls({
    super.key,
    required this.service,
    required this.request,
    required this.onTranslated,
  });
  final SrtTranslationService service;
  final SrtTranslationRequest request;
  final ValueChanged<SrtTranslationResult> onTranslated;
  @override
  State<SrtTranslationControls> createState() => _SrtTranslationControlsState();
}

class _SrtTranslationControlsState extends State<SrtTranslationControls> {
  bool _busy = false;
  AiCancellationToken? _token;
  SrtTranslationResult? _result;
  SrtTranslationProgress? _progressValue;
  late int _concurrency, _chunks;
  @override
  void initState() {
    super.initState();
    _concurrency = widget.service.maxConcurrency;
    _chunks = widget.service.chunkCount;
  }

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SrtTranslationControls old) {
    super.didUpdateWidget(old);
    if (old.request.document.source != widget.request.document.source) {
      _token?.cancel();
      _result = null;
    }
  }

  Future<void> _translate() async {
    final token = AiCancellationToken();
    _token = token;
    setState(() {
      _busy = true;
      _result = null;
      _progressValue = null;
    });
    final service = SrtTranslationService(
      runner: widget.service.runner,
      config: widget.service.config,
      cacheDir: widget.service.cacheDir,
      maxConcurrency: _concurrency,
      chunkCount: _chunks,
    );
    final result = await service.translateSrt(
      widget.request,
      cancellationToken: token,
      onProgress: (value) {
        if (mounted && !token.isCancelled) {
          setState(() => _progressValue = value);
        }
      },
    );
    if (mounted) {
      setState(() {
        _busy = false;
        _result = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('SRT字幕翻译', style: Theme.of(context).textTheme.titleMedium),
      const Text('原SRT保持只读；整包成功才写缓存和提供译文，序号与时轴不变。'),
      Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _concurrency,
              decoration: const InputDecoration(labelText: '并发请求'),
              items: [
                for (var i = 1; i <= 8; i++)
                  DropdownMenuItem(value: i, child: Text('$i')),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _concurrency = v!),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<int>(
              initialValue: _chunks,
              decoration: const InputDecoration(labelText: '初始分块'),
              items: [
                for (var i = 1; i <= 32; i++)
                  DropdownMenuItem(value: i, child: Text('$i')),
              ],
              onChanged: _busy ? null : (v) => setState(() => _chunks = v!),
            ),
          ),
        ],
      ),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: _busy ? null : _translate,
            child: const Text('翻译SRT'),
          ),
          if (_busy)
            TextButton(
              onPressed: () => _token?.cancel(),
              child: const Text('取消翻译'),
            ),
          if (_result?.ok == true)
            OutlinedButton(
              onPressed: () => widget.onTranslated(_result!),
              child: const Text('应用独立译文'),
            ),
        ],
      ),
      if (_busy)
        _progress(
          _progressValue?.value,
          '${_progressValue?.completedChunks ?? 0}/${_progressValue?.totalChunks ?? _chunks} 块完成',
        ),
      if (_result != null && !_result!.ok) _error(context, _result!.reason),
      if (_result?.ok == true)
        Text('${_result!.cueCount} 条字幕 · ${_result!.status.name} · 原文保留'),
    ],
  );
}

class BasicPitchControls extends StatefulWidget {
  const BasicPitchControls({
    super.key,
    required this.service,
    required this.mediaUri,
    required this.lines,
    required this.onGenerated,
    this.headers = const {},
    this.title = '',
    this.artist = '',
  });
  final BasicPitchService service;
  final Uri mediaUri;
  final Map<String, String> headers;
  final List<TimedLyricLine> lines;
  final ValueChanged<KaraokePitchTrack> onGenerated;
  final String title, artist;
  @override
  State<BasicPitchControls> createState() => _BasicPitchControlsState();
}

class _BasicPitchControlsState extends State<BasicPitchControls> {
  bool _busy = false;
  AiCancellationToken? _token;
  BasicPitchProgress? _progressValue;
  KaraokePitchTrack? _track;
  String _errorText = '';
  int _inputEpoch = 0;
  late String _fingerprint;
  String? _resultFingerprint;

  /// 一次生成所绑定的输入身份：换歌/换歌词/换媒体必须让旧结果不可应用。
  String _fingerprintOf(BasicPitchControls widget) {
    final headers = (widget.headers.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
        .map((entry) => '${entry.key}=${entry.value}')
        .join('&');
    final lines = widget.lines
        .map(
          (line) =>
              '${line.startMs}-${line.endMs}:${line.text}:'
              '${line.words.map((w) => '${w.text}@${w.startOffsetMs}+${w.durationMs}').join('|')}',
        )
        .join(';');
    return '${widget.mediaUri}|${widget.title}|${widget.artist}|$headers|$lines';
  }

  @override
  void initState() {
    super.initState();
    _fingerprint = _fingerprintOf(widget);
  }

  @override
  void didUpdateWidget(covariant BasicPitchControls old) {
    super.didUpdateWidget(old);
    final next = _fingerprintOf(widget);
    if (next == _fingerprint) return;
    _fingerprint = next;
    _inputEpoch++;
    _token?.cancel();
    _token = null;
    _progressValue = null;
    _track = null;
    _resultFingerprint = null;
    _errorText = '';
    _busy = false;
  }

  @override
  void dispose() {
    _inputEpoch++;
    _token?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    final token = AiCancellationToken();
    final epoch = ++_inputEpoch;
    final fingerprint = _fingerprint;
    _token = token;
    setState(() {
      _busy = true;
      _errorText = '';
      _track = null;
      _resultFingerprint = null;
      _progressValue = null;
    });
    try {
      final track = await widget.service.generateFromMedia(
        mediaUri: widget.mediaUri,
        headers: widget.headers,
        lines: widget.lines,
        keyword: widget.title,
        artist: widget.artist,
        cancellationToken: token,
        onProgress: (value) {
          if (mounted && epoch == _inputEpoch) {
            setState(() => _progressValue = value);
          }
        },
      );
      if (mounted && !token.isCancelled && epoch == _inputEpoch) {
        setState(() {
          _track = track;
          _resultFingerprint = fingerprint;
        });
      }
    } catch (error) {
      if (mounted && epoch == _inputEpoch) {
        setState(
          () =>
              _errorText = token.isCancelled ? '生成已取消，未写评分轨' : error.toString(),
        );
      }
    } finally {
      if (mounted && epoch == _inputEpoch) {
        setState(() => _busy = false);
      }
    }
  }

  bool get _applicable => _track != null && _resultFingerprint == _fingerprint;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('BasicPitch 音高评分轨', style: Theme.of(context).textTheme.titleMedium),
      const Text(
        '本地真实TFLite推理 · 22.05kHz / hop256 · MIDI40..84；必须有歌词时间戳，质量不足不伪造轨道。',
      ),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: _busy ? null : _generate,
            child: const Text('生成音高评分轨'),
          ),
          if (_busy)
            TextButton(
              onPressed: () => _token?.cancel(),
              child: const Text('取消生成'),
            ),
          if (_applicable)
            OutlinedButton(
              onPressed: () => widget.onGenerated(_track!),
              child: const Text('应用评分轨'),
            ),
        ],
      ),
      if (_busy)
        _progress(
          _progressValue == null ? null : _progressValue!.percent / 100,
          '${_progressValue?.stage ?? 'prepare'} · ${_progressValue?.percent ?? 0}%',
        ),
      if (_applicable)
        Text(
          '${_track!.noteCount}音符 · ${_track!.observed}实测音高 · ${_track!.pitched}评分音符',
        ),
      if (_errorText.isNotEmpty) _error(context, _errorText),
    ],
  );
}
