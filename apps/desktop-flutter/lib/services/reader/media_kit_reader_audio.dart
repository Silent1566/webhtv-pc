import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

import '../../core/reader/reader_models.dart';
import 'reader_tts_controller.dart';

/// 播放器最小接口：生产实现包 media_kit `Player`，测试注入 fixture（不加载原生播放库）。
abstract interface class ReaderMediaPlayer {
  /// 当前媒体播放结束（`true`）事件。
  Stream<bool> get completed;

  /// 播放错误事件。
  Stream<String> get error;

  Future<void> openFile(String path);

  Future<void> stop();

  Future<void> dispose();
}

/// media_kit `Player` 的适配器：音频字节落地为本地文件后播放。
class MediaKitPlayerAdapter implements ReaderMediaPlayer {
  MediaKitPlayerAdapter({Player? player}) : _player = player ?? Player();

  final Player _player;

  @override
  Stream<bool> get completed => _player.stream.completed;

  @override
  Stream<String> get error => _player.stream.error;

  @override
  Future<void> openFile(String path) => _player.open(Media(path));

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

/// 朗读音频播放输出。
///
/// 合成字节先写成任务专属临时文件（media_kit 以本地文件为输入），播完/停/错误即删除；
/// `play` 在媒体播放结束时完成，朗读控制器据此推进到下一段。
///
/// 幂等约定：完成/停止/错误可能来自多个事件（`completed` 与 `stop()` 交叉），
/// 等待中的 Future 只允许被收尾一次，否则会抛 “Future already completed”。
class MediaKitReaderAudio implements ReaderAudioOutput {
  MediaKitReaderAudio({ReaderMediaPlayer? player})
    : _player = player ?? MediaKitPlayerAdapter();

  final ReaderMediaPlayer _player;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  String? _currentPath;
  Completer<void>? _playing;

  @override
  Future<void> play(TtsAudio audio) async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'webhtv_reader_${DateTime.now().microsecondsSinceEpoch}.${audio.extension}',
    );
    await file.writeAsBytes(audio.bytes, flush: true);
    await _deleteCurrent();
    _currentPath = file.path;

    final completer = _playing = Completer<void>();
    _subscriptions
      ..add(
        _player.completed.listen((done) {
          if (done && _owns(completer)) completer.complete();
        }),
      )
      ..add(
        _player.error.listen((message) {
          if (_owns(completer)) {
            completer.completeError(StateError('音频播放失败：$message'));
          }
        }),
      );
    try {
      await _player.openFile(file.path);
      await completer.future;
    } finally {
      if (identical(_playing, completer)) _playing = null;
      _clearSubscriptions();
      await _deleteCurrent();
    }
  }

  @override
  Future<void> stop() async {
    // 先收尾等待方再停播放器：`stop()` 也可能触发 completed，重复收尾会抛异常。
    _completePlaying();
    _clearSubscriptions();
    await _player.stop();
    await _deleteCurrent();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }

  /// 只有「当前这次播放」且尚未收尾时才允许收尾（`completed`/`error`/`stop` 会交叉触发）。
  bool _owns(Completer<void> completer) =>
      identical(_playing, completer) && !completer.isCompleted;

  void _completePlaying() {
    final playing = _playing;
    _playing = null;
    if (playing != null && !playing.isCompleted) playing.complete();
  }

  void _clearSubscriptions() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }

  Future<void> _deleteCurrent() async {
    final path = _currentPath;
    _currentPath = null;
    if (path == null) return;
    final file = File(path);
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // 播放器可能仍持有句柄，交由 OS 回收。
    }
  }
}
