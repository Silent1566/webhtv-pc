import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/karaoke/karaoke_controller.dart';
import '../../services/karaoke/track_providers.dart';
import '../../services/karaoke/track_repository.dart';

/// 可嵌入的卡拉OK控件：开始/暂停/停止、seek、延迟与难度、自由唱/参考轨切换，
/// 展示当前 snapshot 与最终 result。播放器入口由 Task6 接线，本控件不碰 AppState。
class KaraokeControls extends StatefulWidget {
  const KaraokeControls({super.key, required this.controller, this.compact = false});
  final KaraokeController controller;
  final bool compact;
  @override
  State<KaraokeControls> createState() => _KaraokeControlsState();
}

class _KaraokeControlsState extends State<KaraokeControls> {
  late KaraokeState _state = widget.controller.state;
  StreamSubscription<KaraokeState>? _subscription;
  var _latencyMs = 0;
  var _tolerance = 2.0;

  @override
  void initState() {
    super.initState();
    _subscription = widget.controller.changes.listen((state) {
      if (mounted) setState(() => _state = state);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  String get _statusLabel => switch (_state.status) {
    KaraokeStatus.inactive => '未启用',
    KaraokeStatus.micUnavailable => '麦克风不可用：${widget.controller.micUnavailableReason}',
    KaraokeStatus.scoring => '参考轨评分',
    KaraokeStatus.freeSing => '自由唱评分',
  };

  @override
  Widget build(BuildContext context) {
    final snapshot = _state.snapshot;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(_statusLabel, style: theme.textTheme.bodySmall),
            const Spacer(),
            Text('${snapshot.scorePercent} 分 · ${snapshot.grade}', style: theme.textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: snapshot.scorePercent / 100),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => unawaited(widget.controller.start()),
              icon: const Icon(Icons.mic, size: 18),
              label: const Text('开始'),
            ),
            OutlinedButton(onPressed: widget.controller.pause, child: const Text('暂停')),
            OutlinedButton(onPressed: () => unawaited(widget.controller.stop()), child: const Text('停止')),
            OutlinedButton(
              onPressed: () => widget.controller.seek(Duration(milliseconds: math.max(0, widget.controller.positionMs))),
              child: const Text('回到当前'),
            ),
            OutlinedButton(
              onPressed: () => widget.controller.selectTrack(null),
              child: const Text('自由唱'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('麦克风延迟'),
            Expanded(
              child: Slider(
                value: _latencyMs.toDouble(),
                min: 0,
                max: 500,
                divisions: 50,
                label: '$_latencyMs ms',
                onChanged: (value) => setState(() => _latencyMs = value.round()),
                onChangeEnd: (value) => widget.controller.setScoring(inputLatencyMs: value.round()),
              ),
            ),
            Text('$_latencyMs ms'),
          ],
        ),
        Row(
          children: [
            const Text('音准难度'),
            Expanded(
              child: Slider(
                value: _tolerance,
                min: 0.2,
                max: 6,
                divisions: 29,
                label: _tolerance.toStringAsFixed(1),
                onChanged: (value) => setState(() => _tolerance = value),
                onChangeEnd: (value) => widget.controller.setScoring(toleranceSemitones: value),
              ),
            ),
            Text('±${_tolerance.toStringAsFixed(1)} 半音'),
          ],
        ),
        if (!widget.compact)
          Text(
            '发声 ${snapshot.voicedPercent}% · 完美 ${snapshot.perfectPercent}% · 颤音 ${snapshot.vibratoPercent}% · 连击 ${(snapshot.currentComboMs / 1000).round()}s',
            style: theme.textTheme.bodySmall,
          ),
        if (_state.error.isNotEmpty) Text(_state.error, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
      ],
    );
  }
}

/// 轨选择面板：列举仓库绑定、导入文件文本、检索并导入、导出备份。
class KaraokeTrackPicker extends StatefulWidget {
  const KaraokeTrackPicker({super.key, required this.repository, required this.media, this.onImported});
  final KaraokeTrackRepository repository;
  final KaraokeMedia media;
  final ValueChanged<KaraokeImportResult>? onImported;
  @override
  State<KaraokeTrackPicker> createState() => _KaraokeTrackPickerState();
}

class _KaraokeTrackPickerState extends State<KaraokeTrackPicker> {
  var _keyword = '';
  var _results = const <KaraokeSearchResult>[];
  var _busy = false;
  var _error = '';

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final results = await widget.repository.search(_keyword);
      if (mounted) setState(() => _results = results);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import(String url) async {
    setState(() => _busy = true);
    final result = await widget.repository.importUrl(widget.media, Uri.parse(url));
    if (mounted) setState(() => _busy = false);
    widget.onImported?.call(result);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(hintText: '搜索 UltraStar 轨'),
                onChanged: (value) => _keyword = value,
                onSubmitted: (_) => unawaited(_search()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(onPressed: _busy ? null : () => unawaited(_search()), child: const Text('检索')),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error.isNotEmpty) Text(_error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        for (final result in _results)
          ListTile(
            dense: true,
            title: Text(result.title),
            subtitle: Text('${result.artist} · ${result.source}${result.loginRequired ? ' · 需要登录' : ''}'),
            trailing: TextButton(onPressed: _busy ? null : () => unawaited(_import(result.url)), child: const Text('导入')),
          ),
      ],
    );
  }
}


