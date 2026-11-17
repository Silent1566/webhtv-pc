import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// media-kit command() discards libmpv's return code; navigation must not.
Future<bool> runNativeNavigationCommand(
  NativePlayer player,
  List<String> command,
) async {
  // Callers have awaited native properties before issuing this synchronous command.
  if (player.disposed) return false;
  final strings = command.map((value) => value.toNativeUtf8()).toList();
  final arguments = calloc<Pointer<Utf8>>(strings.length + 1);
  try {
    for (var index = 0; index < strings.length; index++) {
      arguments[index] = strings[index];
    }
    return player.mpv.mpv_command(player.ctx, arguments.cast()) >= 0;
  } finally {
    calloc.free(arguments);
    for (final string in strings) {
      calloc.free(string);
    }
  }
}

abstract interface class PlayerThumbnailSession {
  Future<void> open(Media source);
  Future<Uint8List?> extract(Duration target);
  Future<void> dispose();
}

/// One lazy, isolated decoder; timed-out work must drain before another starts.
class PlayerThumbnailService {
  PlayerThumbnailService({
    PlayerThumbnailSession Function()? sessionFactory,
    Duration extractionTimeout = const Duration(seconds: 5),
  }) : _sessionFactory = sessionFactory ?? NativePlayerThumbnailSession.new,
       _timeout = extractionTimeout > const Duration(seconds: 5)
           ? const Duration(seconds: 5)
           : extractionTimeout;

  final PlayerThumbnailSession Function() _sessionFactory;
  final Duration _timeout;
  final _cache = <int, Uint8List>{};
  Media? _media;
  PlayerThumbnailSession? _session;
  Future<void>? _retiring;
  _ThumbnailJob? _job;
  _ThumbnailJob? _pending;
  bool _enabled = false;
  bool _disposed = false;
  int _generation = 0;
  int get generation => _generation;

  void setMedia(String url, {Map<String, String> headers = const {}}) {
    if (_disposed) return;
    _invalidate();
    _media = Media(url, httpHeaders: Map<String, String>.unmodifiable(headers));
  }

  void setEnabled(bool enabled) {
    if (_disposed || _enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) _invalidate();
  }

  void _invalidate() {
    _generation++;
    _cache.clear();
    _job?.cancel();
    _pending?.cancel();
    _pending = null;
    _retire();
  }

  void _retire() {
    final session = _session;
    if (session == null) return;
    _session = null;
    final release = Future<void>.sync(session.dispose)
        .catchError((Object _) {});
    _retiring = release;
    unawaited(
      release.then((_) {
        if (identical(_retiring, release)) _retiring = null;
        _startPending();
      }),
    );
  }

  Future<Uint8List?> thumbnailAt(Duration target) {
    if (_disposed || !_enabled || _media == null || target < Duration.zero) {
      return Future.value();
    }
    final key = target.inMilliseconds;
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      _pending?.cancel();
      _pending = null;
      return Future.value(cached);
    }
    final active = _job;
    if (active != null &&
        !active.cancelled &&
        active.generation == _generation &&
        active.key == key) {
      _pending?.cancel();
      _pending = null;
      return active.result.future;
    }
    final pending = _pending;
    if (pending != null &&
        pending.generation == _generation &&
        pending.key == key) {
      return pending.result.future;
    }
    _pending?.cancel();
    final job = _ThumbnailJob(_generation, target);
    job.timer = Timer(_timeout, () {
      job.cancel();
      if (identical(_job, job)) _retire();
      if (identical(_pending, job)) _pending = null;
    });
    _pending = job;
    _startPending();
    return job.result.future;
  }

  void _startPending() {
    final next = _pending;
    if (next == null || _job != null || _retiring != null) return;
    _pending = null;
    if (_disposed ||
        !_enabled ||
        next.cancelled ||
        next.generation != _generation ||
        _media == null) {
      next.cancel();
      return;
    }
    _job = next;
    unawaited(_extract(next, _media!, next.target));
  }

  Future<void> _extract(
    _ThumbnailJob job,
    Media source,
    Duration target,
  ) async {
    Uint8List? bytes;
    bool current() =>
        !_disposed &&
        _enabled &&
        !job.cancelled &&
        job.generation == _generation;
    try {
      var session = _session;
      if (session == null) {
        session = _sessionFactory();
        _session = session;
        await session.open(source);
      }
      if (current()) bytes = await session.extract(target);
      if (bytes == null || bytes.isEmpty) {
        bytes = null;
        _retire();
      }
    } catch (_) {
      _retire();
    } finally {
      if (!current()) bytes = null;
      if (bytes != null) {
        _cache[job.key] = bytes;
        if (_cache.length > 32) _cache.remove(_cache.keys.first);
      }
      if (bytes == null && !job.result.isCompleted) job.result.complete();
      await _retiring;
      job.timer?.cancel();
      if (identical(_job, job)) _job = null;
      if (!job.result.isCompleted) job.result.complete(bytes);
      job.settled.complete();
      _startPending();
    }
  }

  Future<void> dispose() async {
    if (!_disposed) {
      _disposed = true;
      _enabled = false;
      _media = null;
      _invalidate();
    }
    await _job?.settled.future;
    await _retiring;
  }
}

class _ThumbnailJob {
  _ThumbnailJob(this.generation, this.target);
  final int generation;
  final Duration target;
  int get key => target.inMilliseconds;
  final result = Completer<Uint8List?>();
  final settled = Completer<void>();
  Timer? timer;
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    timer?.cancel();
    if (!result.isCompleted) result.complete();
  }
}

/// Native resources belong exclusively to the preview, never the main player.
class NativePlayerThumbnailSession implements PlayerThumbnailSession {
  NativePlayerThumbnailSession()
    : _player = Player(configuration: const PlayerConfiguration(muted: true)) {
    _video = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        width: 320,
        height: 180,
      ),
    );
  }

  final Player _player;
  late final VideoController _video;
  bool _disposed = false;
  Future<void>? _disposal;
  final _closed = Completer<void>();

  @override
  Future<void> open(Media source) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) {
      throw UnsupportedError('Native preview unavailable');
    }
    await _player.setVolume(0);
    for (final property in const {
      'aid': 'no',
      'sid': 'no',
      'audio': 'no',
      'sub-auto': 'no',
      'audio-file-auto': 'no',
      'vf': 'scale=320:180:force_original_aspect_ratio=decrease',
    }.entries) {
      if (_disposed) return;
      await platform.setProperty(property.key, property.value);
    }
    if (_disposed) return;
    // media-kit resolves headers through a URI-keyed global Media cache in on_load.
    await _player.open(
      Media(source.uri, httpHeaders: source.httpHeaders),
      play: false,
    );
    while (!_disposed) {
      final duration = double.tryParse(await platform.getProperty('duration'));
      final width = int.tryParse(await platform.getProperty('video-params/w'));
      if (duration != null &&
          duration.isFinite &&
          duration > 0 &&
          width != null &&
          width > 0 &&
          await platform.getProperty('seekable') == 'yes') {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_disposed) return;
    await Future.any([_video.waitUntilFirstFrameRendered, _closed.future]);
  }

  @override
  Future<Uint8List?> extract(Duration target) async {
    if (_disposed) return null;
    final platform = _player.platform;
    if (platform is! NativePlayer) return null;
    if (!await runNativeNavigationCommand(platform, [
      'seek',
      (target.inMicroseconds / Duration.microsecondsPerSecond).toString(),
      'absolute+keyframes',
    ])) {
      return null;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    while (!_disposed && await platform.getProperty('seeking') == 'yes') {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_disposed) return null;
    return _player.screenshot(format: 'image/jpeg');
  }

  @override
  Future<void> dispose() {
    _disposed = true;
    if (!_closed.isCompleted) _closed.complete();
    return _disposal ??= _player.dispose();
  }
}
