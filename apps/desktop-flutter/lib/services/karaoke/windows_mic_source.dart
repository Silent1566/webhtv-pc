import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/karaoke/karaoke.dart';
import 'mic_source.dart';
import 'mic_analysis.dart';

abstract class KaraokeMicBackend {
  bool get isAvailable;
  String get error;
  int get sampleRate;
  bool start(int frameSize);
  int read(Float32List buffer);
  void stop();
}

class _FfiMicBackend implements KaraokeMicBackend {
  DynamicLibrary? _library;
  Pointer<Float>? _pcm;
  int Function()? _available;
  int Function(int)? _start;
  int Function(Pointer<Float>, int)? _read;
  void Function()? _stop;
  int Function()? _rate;
  Pointer<Utf8> Function()? _error;
  String _reason = '';
  bool _bind() {
    if (_library != null) return true;
    if (!Platform.isWindows) {
      _reason = '当前平台不支持 Windows 麦克风';
      return false;
    }
    for (final path in [
      'karaoke_mic_native.dll',
      'runner/karaoke_mic_native.dll',
      'data/flutter_assets/karaoke_mic_native.dll',
    ]) {
      try {
        final lib = DynamicLibrary.open(path);
        _available = lib.lookupFunction<Int32 Function(), int Function()>(
          'kmic_available',
        );
        _start = lib.lookupFunction<Int32 Function(Int32), int Function(int)>(
          'kmic_start',
        );
        _read = lib
            .lookupFunction<
              Int32 Function(Pointer<Float>, Int32),
              int Function(Pointer<Float>, int)
            >('kmic_read');
        _stop = lib.lookupFunction<Void Function(), void Function()>(
          'kmic_stop',
        );
        _rate = lib.lookupFunction<Int32 Function(), int Function()>(
          'kmic_mix_sample_rate',
        );
        _error = lib
            .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
              'kmic_last_error',
            );
        _library = lib;
        return true;
      } catch (_) {}
    }
    _reason = '未找到 karaoke_mic_native.dll';
    return false;
  }

  @override
  bool get isAvailable => _bind() && _available!() == 1;
  @override
  String get error {
    final pointer = _error?.call();
    return pointer == null || pointer == nullptr
        ? _reason
        : pointer.toDartString();
  }

  @override
  int get sampleRate => _rate?.call() ?? 0;
  @override
  bool start(int frameSize) {
    if (!isAvailable || _start!(44100) == 0) return false;
    _pcm = calloc<Float>(frameSize);
    return true;
  }

  @override
  int read(Float32List buffer) {
    final count = _read!(_pcm!, buffer.length);
    if (count > 0 && count <= buffer.length)
      buffer.setRange(0, count, _pcm!.asTypedList(count));
    return count;
  }

  @override
  void stop() {
    _stop?.call();
    if (_pcm != null) calloc.free(_pcm!);
    _pcm = null;
  }
}

/// 懒真实设备 + 完整窗后台YIN；一轮最多一个输入包，不堆积 isolate 工作。
class WindowsKaraokeMicSource implements KaraokeMicSource {
  WindowsKaraokeMicSource({
    this.frameSize = 2048,
    this.pollInterval = const Duration(milliseconds: 21),
    KaraokeMicBackend? backend,
    this.automaticPolling = true,
    DateTime Function()? now,
  }) : _backend = backend ?? _FfiMicBackend(),
       _now = now ?? DateTime.now;
  final int frameSize;
  final Duration pollInterval;
  final bool automaticPolling;
  final KaraokeMicBackend _backend;
  final DateTime Function() _now;
  final _samples = StreamController<KaraokePitchSample>.broadcast();
  Timer? _timer;
  Isolate? _worker;
  ReceivePort? _receive;
  StreamSubscription<dynamic>? _receiveSubscription;
  SendPort? _commands;
  Completer<void>? _ready, _pending;
  Float32List? _buffer;
  bool _running = false, _busy = false;
  int _generation = 0, _sampleRate = 0;
  String _reason = '';
  @override
  bool get isAvailable => _backend.isAvailable;
  @override
  String get unavailableReason => _reason.isNotEmpty
      ? _reason
      : _backend.error.isNotEmpty
      ? _backend.error
      : '未检测到可用录音设备';
  @override
  Stream<KaraokePitchSample> get samples => _samples.stream;
  @override
  Future<bool> start() async {
    if (_running) return true;
    final generation = ++_generation;
    try {
      if (!_backend.start(frameSize)) {
        _reason = _backend.error;
        _backend.stop();
        return false;
      }
      _sampleRate = _backend.sampleRate;
      if (_sampleRate < 8000 || _sampleRate > 192000)
        throw StateError('invalid microphone sample rate');
      _buffer = Float32List(frameSize);
      _ready = Completer<void>();
      _receive = ReceivePort();
      _receiveSubscription = _receive!.listen((dynamic message) {
        if (generation != _generation) return;
        if (message is SendPort) {
          _commands = message;
          _ready?.complete();
          return;
        }
        if (_running && message is List) {
          for (final row in message) {
            _samples.add(
              KaraokePitchSample(
                timestampMs: row[0] as int,
                frequencyHz: row[1] as double,
                volume: row[2] as double,
                confidence: row[3] as double,
              ),
            );
          }
        } else if (message is String && _running) {
          _reason = message;
          _samples.addError(StateError(message));
          unawaited(stop());
        }
        if (!(_pending?.isCompleted ?? true)) _pending!.complete();
      });
      _worker = await Isolate.spawn(karaokeMicAnalysisWorker, <Object>[
        _receive!.sendPort,
        _sampleRate,
        frameSize,
      ]);
      await _ready!.future.timeout(const Duration(seconds: 5));
      if (generation != _generation) {
        _worker?.kill(priority: Isolate.immediate);
        return false;
      }
      _running = true;
      if (automaticPolling)
        _timer = Timer.periodic(pollInterval, (_) => unawaited(poll()));
      return true;
    } catch (error) {
      _reason = '麦克风启动失败: $error';
      await stop();
      return false;
    }
  }

  Future<void> poll() async {
    if (!_running || _busy) return;
    _busy = true;
    try {
      final count = _backend.read(_buffer!);
      if (count < 0 || count > frameSize)
        throw StateError(
          _backend.error.isEmpty
              ? 'invalid microphone read length'
              : _backend.error,
        );
      if (count == 0) return;
      _pending = Completer<void>();
      _commands!.send([
        Float32List.fromList(_buffer!.sublist(0, count)),
        _now().millisecondsSinceEpoch,
      ]);
      await _pending!.future.timeout(const Duration(seconds: 5));
    } catch (error) {
      if (_running) {
        _reason = '麦克风读取失败: $error';
        _samples.addError(StateError(_reason));
        await stop();
      }
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    _running = false;
    _timer?.cancel();
    _timer = null;
    if (!(_ready?.isCompleted ?? true)) _ready!.complete();
    if (!(_pending?.isCompleted ?? true)) _pending!.complete();
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    _commands = null;
    _receive?.close();
    _receive = null;
    await _receiveSubscription?.cancel();
    _receiveSubscription = null;
    _backend.stop();
    _buffer = null;
    _sampleRate = 0;
  }

  Future<void> dispose() async {
    await stop();
    await _samples.close();
  }

  int msForFrames(int frames) =>
      _sampleRate <= 0 ? 0 : math.max(0, frames * 1000 ~/ _sampleRate);
}
