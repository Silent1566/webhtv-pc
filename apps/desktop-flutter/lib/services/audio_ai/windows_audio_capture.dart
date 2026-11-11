import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../core/audio_ai/pcm_sync.dart';

enum AudioCaptureState { off, opening, capturing, error }

class AudioCaptureException implements Exception {
  const AudioCaptureException(this.message);
  final String message;
  @override
  String toString() => message;
}

class NativePcmChunk {
  const NativePcmChunk(this.samples, this.sampleRate, this.pts);
  final Float32List samples;
  final int sampleRate;
  final Duration pts;

  Duration get duration => Duration(
    microseconds: (samples.length * Duration.microsecondsPerSecond / sampleRate)
        .round(),
  );
}

/// 读取节奏完全由真实返回的 `pts + count / sampleRate` 驱动。
///
/// 合同（对应审查 F2）：每次 read 返回多少样本、源 PTS 是多少，进度就以真实值
/// 前进；不使用固定的 100ms 虚拟推进。短包（20ms/10ms）在 1x/2x 下都必须被
/// 连续排空，倍速时按 `clock.rate` 提高读取预算，落后则以真实 PTS 判定 seek。
class MediaPcmReadScheduler {
  MediaPcmReadScheduler({
    this.lookahead = const Duration(milliseconds: 400),
    this.catchUp = const Duration(milliseconds: 500),
  });

  /// 允许领先播放时钟的最大解码余量。
  final Duration lookahead;

  /// 真实 PTS 落后多少才允许 catch-up seek。
  final Duration catchUp;

  Duration _nextPts = Duration.zero;
  Duration get nextPts => _nextPts;
  bool _ended = false;
  bool get ended => _ended;

  void reset(Duration position) {
    _nextPts = position;
    _ended = false;
  }

  bool markEnd({required int generation, required int currentGeneration}) {
    if (generation != currentGeneration) return false;
    _ended = true;
    return true;
  }

  /// 记录一次真实 read 结果：`count` 个样本、采样率 `sampleRate`、起点 `pts`。
  bool received({
    required Duration pts,
    required int count,
    required int sampleRate,
    int? generation,
    int? currentGeneration,
  }) {
    if (generation != null && generation != currentGeneration) return false;
    final end = pts + Duration(
      microseconds: sampleRate <= 0
          ? 0
          : (count * Duration.microsecondsPerSecond / sampleRate).round(),
    );
    if (end > _nextPts) _nextPts = end;
    return true;
  }

  bool shouldRead({
    required Duration position,
    required bool playing,
    double rate = 1,
  }) {
    if (!playing || _ended) return false;
    final safeRate = rate <= 0 ? 1.0 : rate;
    final budget = Duration(
      microseconds: (lookahead.inMicroseconds * safeRate).round(),
    );
    return _nextPts < position + budget;
  }

  bool needsSeek(Duration position) => _nextPts < position - catchUp;
}

/// SourceReader independently decodes the current authorized media, not an mpv
/// PCM tap. WASAPI is available only for a dedicated external player PID: the
/// application's own PID is rejected because it can mix reader TTS.
class WindowsAudioCapture {
  WindowsAudioCapture({this.libraryPath});
  final String? libraryPath;
  final _frames = StreamController<PcmFrame>.broadcast();
  final _states = StreamController<AudioCaptureState>.broadcast();
  Stream<PcmFrame> get frames => _frames.stream;
  Stream<AudioCaptureState> get states => _states.stream;
  AudioCaptureState get state => _state;
  AudioCaptureState _state = AudioCaptureState.off;
  String lastError = '';
  String get captureMode =>
      _decoded ? '独立媒体解码（额外带宽/CPU，不含TTS）' : '专属播放器进程 WASAPI';
  AudioSessionClock? _clock;
  Isolate? _worker;
  ReceivePort? _receive;
  SendPort? _commands;
  Timer? _timer;
  AuthorizedMediaProxy? _proxy;
  bool _decoded = true;
  int _inFlight = 0;
  final _pending = <NativePcmChunk>[];
  final MediaPcmReadScheduler _scheduler = MediaPcmReadScheduler();
  int _generation = -1;
  int _epoch = 0;
  int _nativeAddress = 0;
  Completer<void>? _closed;

  /// 一次 tick 内最多发出的 read 数量（背压上限，短包也能追上）。
  static const int kMaxReadsPerTick = 8;

  static void validateProcessId(int target, int current) {
    if (target <= 0 || target == current) {
      throw const AudioCaptureException(
        '不能捕获当前进程的混合音频；请使用媒体URL独立解码，避免TTS/系统混录',
      );
    }
  }

  static PcmFrame? frameFor(
    NativePcmChunk chunk,
    AudioSessionClock clock, {
    required bool mediaDecoded,
  }) {
    if (!clock.playing) return null;
    final start = mediaDecoded ? chunk.pts : clock.position;
    return PcmFrame(
      samples: chunk.samples,
      sampleRate: chunk.sampleRate,
      mediaStart: start,
      sessionId: clock.sessionId,
      generation: clock.generation,
      mediaRate: mediaDecoded ? 1 : clock.rate,
    );
  }

  static String resolveLibrary([String? explicit]) {
    final candidates = [
      if (explicit != null) explicit,
      p.join(
        File(Platform.resolvedExecutable).parent.path,
        'audio_ai_native.dll',
      ),
      p.join(
        Directory.current.path,
        '../../.local/audio_ai/native/audio_ai_native.dll',
      ),
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return File(path).absolute.path;
    }
    throw const AudioCaptureException(
      'audio_ai_native.dll 缺失：请先构建 Windows runner；不回退系统混音',
    );
  }

  Future<bool> start({
    required AudioSessionClock clock,
    Uri? mediaUri,
    Map<String, String> headers = const {},
    int? playerProcessId,
  }) async {
    await stop();
    final epoch = ++_epoch;
    _clock = clock;
    _decoded = playerProcessId == null;
    lastError = '';
    _setState(AudioCaptureState.opening);
    try {
      if (!Platform.isWindows) {
        throw const AudioCaptureException('此音频adapter仅支持Windows');
      }
      if (playerProcessId != null) validateProcessId(playerProcessId, pid);
      String source = '';
      if (_decoded) {
        if (mediaUri == null) {
          throw const AudioCaptureException('独立解码需要当前播放 mediaUri 和 headers');
        }
        if (mediaUri.scheme == 'file') {
          source = mediaUri.toFilePath(windows: true);
        } else if (mediaUri.scheme == 'http' || mediaUri.scheme == 'https') {
          _proxy = await AuthorizedMediaProxy.open(mediaUri, headers);
          source = _proxy!.uri.toString();
        } else {
          throw const AudioCaptureException(
            '仅支持本地file/http/https媒体；DRM或unsupported codec仅停止字幕',
          );
        }
      }
      final ready = Completer<void>();
      _receive = ReceivePort();
      _receive!.listen((message) {
        if ((message as Map)['event'] == 'closed') {
          if (_closed?.isCompleted == false) _closed!.complete();
          return;
        }
        if (epoch != _epoch) return;
        final map = message;
        switch (map['event']) {
          case 'ready':
            _commands = map['port'] as SendPort;
            _nativeAddress = map['address'] as int;
            _generation = clock.generation;
            _scheduler.reset(clock.position);
            if (_decoded && clock.position > Duration.zero) {
              _commands!.send({
                'command': 'seek',
                'pts': clock.position.inMicroseconds,
              });
            }
            if (!ready.isCompleted) ready.complete();
          case 'samples':
            if (_inFlight > 0) _inFlight--;
            final data = (map['samples'] as TransferableTypedData)
                .materialize();
            final sampleRate = (map['sampleRate'] as int?) ?? 16000;
            final pts = Duration(microseconds: map['pts'] as int);
            if (_scheduler.received(
              pts: pts,
              count: data.asFloat32List().length,
              sampleRate: sampleRate,
              generation: map['generation'] as int?,
              currentGeneration: clock.generation,
            )) {
              _pending.add(
                NativePcmChunk(data.asFloat32List(), sampleRate, pts),
              );
              if (_pending.length > 64) _pending.removeAt(0);
            }
          case 'empty':
            if (_inFlight > 0) _inFlight--;
          case 'end':
            if (_inFlight > 0) _inFlight--;
            _scheduler.markEnd(
              generation: (map['generation'] as int?) ?? -1,
              currentGeneration: clock.generation,
            );
          case 'error':
            if (map['generation'] != null && map['generation'] != clock.generation) {
              if (_inFlight > 0) _inFlight--;
              break;
            }
            _inFlight = 0;
            lastError = map['message'] as String;
            _setState(AudioCaptureState.error);
            if (!ready.isCompleted) {
              ready.completeError(AudioCaptureException(lastError));
            }
            _timer?.cancel();
        }
      });
      _worker = await Isolate.spawn(_captureWorker, {
        'reply': _receive!.sendPort,
        'library': resolveLibrary(libraryPath),
        'source': source,
        'pid': playerProcessId,
      });
      await ready.future.timeout(const Duration(seconds: 15));
      if (epoch != _epoch) return false;
      _setState(AudioCaptureState.capturing);
      _timer = Timer.periodic(const Duration(milliseconds: 20), (_) => _tick());
      return true;
    } catch (error) {
      lastError = error.toString();
      await stop();
      _setState(AudioCaptureState.error);
      return false;
    }
  }

  void _tick() {
    final clock = _clock;
    if (clock == null ||
        _commands == null ||
        state != AudioCaptureState.capturing) {
      return;
    }
    if (_generation != clock.generation) {
      _generation = clock.generation;
      _pending.clear();
      _scheduler.reset(clock.position);
      if (_decoded) {
        _commands!.send({
          'command': 'seek',
          'pts': clock.position.inMicroseconds,
        });
      }
    }
    if (!clock.playing) return;
    // 真实 PTS 先于时钟超过 100ms 的块留在缓冲里，其余按到达顺序输出。
    while (_pending.isNotEmpty) {
      final chunk = _pending.first;
      if (chunk.pts > clock.position + const Duration(milliseconds: 100)) {
        break;
      }
      _pending.removeAt(0);
      final stale =
          _decoded &&
          chunk.pts + chunk.duration <
              clock.position - const Duration(milliseconds: 250);
      if (stale) continue;
      _frames.add(frameFor(chunk, clock, mediaDecoded: _decoded)!);
    }
    if (_scheduler.ended && _pending.isEmpty && _inFlight == 0) {
      _setState(AudioCaptureState.off);
      _timer?.cancel();
      return;
    }
    if (!_scheduler.ended && _decoded && _scheduler.needsSeek(clock.position)) {
      _commands!.send({
        'command': 'seek',
        'pts': clock.position.inMicroseconds,
      });
      _scheduler.reset(clock.position);
      _pending.clear();
    }
    // 短包也必须排空：一个 tick 内可连续请求多次 read，直到缓冲领先时钟。
    var issued = 0;
    while (issued + _inFlight < kMaxReadsPerTick &&
        _scheduler.shouldRead(
          position: clock.position,
          playing: clock.playing,
          rate: clock.rate,
        )) {
      _inFlight++;
      _commands!.send({'command': 'read', 'generation': clock.generation});
      issued++;
    }
  }

  void _setState(AudioCaptureState value) {
    _state = value;
    if (!_states.isClosed) _states.add(value);
  }

  Future<void> stop() async {
    ++_epoch;
    _timer?.cancel();
    _timer = null;
    await _proxy?.close();
    _proxy = null;
    if (_nativeAddress != 0) {
      final api = NativeAudioApi(resolveLibrary(libraryPath));
      api.cancel(Pointer<Void>.fromAddress(_nativeAddress));
      _nativeAddress = 0;
    }
    _closed = Completer<void>();
    _commands?.send({'command': 'close'});
    if (_commands != null) {
      try {
        await _closed!.future.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    _commands = null;
    _worker?.kill(priority: Isolate.beforeNextEvent);
    _worker = null;
    _receive?.close();
    _receive = null;
    _inFlight = 0;
    _pending.clear();
    _scheduler.reset(Duration.zero);
    _setState(AudioCaptureState.off);
  }

  Future<void> dispose() async {
    await stop();
    await _frames.close();
    await _states.close();
  }
}

/// Fixed-source localhost proxy forwards the *current media* authorization and
/// Range. No arbitrary URL endpoint; no credential logs. Closing destroys all
/// upstream sockets, interrupting native network reads even during opening.
class AuthorizedMediaProxy {
  AuthorizedMediaProxy._(
    this._server,
    this._client,
    this._source,
    this._headers,
  );
  final HttpServer _server;
  final HttpClient _client;
  final Uri _source;
  final Map<String, String> _headers;
  final String _key = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/$_key');

  static Future<AuthorizedMediaProxy> open(
    Uri source,
    Map<String, String> headers,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = AuthorizedMediaProxy._(
      server,
      HttpClient(),
      source,
      Map.of(headers),
    );
    server.listen(proxy._forward);
    return proxy;
  }

  Future<void> _forward(HttpRequest request) async {
    if (request.uri.path != '/$_key' ||
        !['GET', 'HEAD'].contains(request.method)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    try {
      final upstream = await _client.openUrl(request.method, _source);
      _headers.forEach((name, value) {
        if (name.toLowerCase() != 'host') upstream.headers.set(name, value);
      });
      final range = request.headers.value('range');
      if (range != null) upstream.headers.set('Range', range);
      final response = await upstream.close();
      request.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        if (![
          'connection',
          'transfer-encoding',
          'set-cookie',
        ].contains(name.toLowerCase())) {
          request.response.headers.set(name, values);
        }
      });
      await request.response.addStream(response);
    } catch (_) {
      request.response.statusCode = 502;
    } finally {
      await request.response.close();
    }
  }

  Future<void> close() async {
    _client.close(force: true);
    await _server.close(force: true);
  }
}

typedef _OpenC = Pointer<Void> Function(Pointer<Utf16>);
typedef _OpenD = Pointer<Void> Function(Pointer<Utf16>);
typedef _PidC = Pointer<Void> Function(Uint32);
typedef _PidD = Pointer<Void> Function(int);
typedef _ReadC = Int32 Function(
  Pointer<Void>,
  Pointer<Float>,
  Int32,
  Pointer<Int64>,
);
typedef _ReadD = int Function(
  Pointer<Void>,
  Pointer<Float>,
  int,
  Pointer<Int64>,
);
typedef _SeekC = Int32 Function(Pointer<Void>, Int64);
typedef _SeekD = int Function(Pointer<Void>, int);
typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseD = void Function(Pointer<Void>);
typedef _ErrorC = Pointer<Utf16> Function();
typedef _ErrorD = Pointer<Utf16> Function();

class NativeAudioApi {
  NativeAudioApi(String path) : library = DynamicLibrary.open(path);
  final DynamicLibrary library;
  Pointer<Void> openMedia(String path) {
    final name = path.toNativeUtf16();
    try {
      return library.lookupFunction<_OpenC, _OpenD>('aa_open_media')(name);
    } finally {
      calloc.free(name);
    }
  }

  Pointer<Void> openLoopback(int pid) =>
      library.lookupFunction<_PidC, _PidD>('aa_open_loopback')(pid);
  int read(
    Pointer<Void> handle,
    Pointer<Float> samples,
    int capacity,
    Pointer<Int64> pts,
  ) => library.lookupFunction<_ReadC, _ReadD>('aa_read')(
    handle,
    samples,
    capacity,
    pts,
  );
  int seek(Pointer<Void> handle, int pts) =>
      library.lookupFunction<_SeekC, _SeekD>('aa_seek')(handle, pts);
  void close(Pointer<Void> handle) =>
      library.lookupFunction<_CloseC, _CloseD>('aa_close')(handle);
  void cancel(Pointer<Void> handle) =>
      library.lookupFunction<_CloseC, _CloseD>('aa_cancel')(handle);
  String get error =>
      library.lookupFunction<_ErrorC, _ErrorD>('aa_error')().toDartString();
}

void _captureWorker(Map<String, Object?> args) {
  final reply = args['reply'] as SendPort;
  final commands = ReceivePort();
  final api = NativeAudioApi(args['library'] as String);
  final target = args['pid'] as int?;
  final handle = target == null
      ? api.openMedia(args['source'] as String)
      : api.openLoopback(target);
  if (handle == nullptr) {
    reply.send({'event': 'error', 'message': api.error});
    commands.close();
    return;
  }
  final samples = calloc<Float>(1600);
  final pts = calloc<Int64>();
  reply.send({
    'event': 'ready',
    'port': commands.sendPort,
    'address': handle.address,
  });
  commands.listen((raw) {
    final command = raw as Map;
    switch (command['command']) {
      case 'seek':
        if (api.seek(handle, command['pts'] as int) < 0) {
          reply.send({'event': 'error', 'message': api.error});
        }
      case 'read':
        final count = api.read(handle, samples, 1600, pts);
        if (count > 0) {
          final data = Float32List.fromList(samples.asTypedList(count));
          reply.send({
            'event': 'samples',
            'samples': TransferableTypedData.fromList([
              data.buffer.asUint8List(),
            ]),
            'pts': pts.value,
            'sampleRate': 16000,
            'generation': command['generation'],
          });
        } else {
          reply.send({
            'event': count == -2
                ? 'end'
                : count < 0
                ? 'error'
                : 'empty',
            'message': api.error,
            'generation': command['generation'],
          });
        }
      case 'close':
        api.close(handle);
        calloc.free(samples);
        calloc.free(pts);
        reply.send({'event': 'closed'});
        commands.close();
    }
  });
}
