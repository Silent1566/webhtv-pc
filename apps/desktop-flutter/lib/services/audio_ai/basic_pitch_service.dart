/// Basic Pitch 真实 TFLite 推理：官方 Google LiteRT Windows 原生库（libLiteRt.dll）
/// 的 TfLite C API，模型为源资产 `basic_pitch_nmp.tflite`（204448 字节）。
///
/// 采样参数与源 `BasicPitchTfliteGenerator` 一致：22.05kHz、hop 256、
/// MIDI 40..84 打分；质量不足时抛 [KaraokePitchException]，绝不伪造轨道。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:async';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../ai_completion_client.dart';
import 'windows_audio_capture.dart';

import 'package:ffi/ffi.dart';

import '../../core/audio_ai/pitch_track.dart';

const int kBasicPitchSampleRate = 22050;
const int kBasicPitchHop = 256;

int basicPitchFrameTimeMs(int windowStartSample, int frame) =>
    ((windowStartSample + frame * kBasicPitchHop) * 1000 / kBasicPitchSampleRate).round();
const int kBasicPitchWindow = kBasicPitchSampleRate * 2 - kBasicPitchHop;
const int kBasicPitchMidiOffset = 21;
const int kBasicPitchMinMidi = 40;
const int kBasicPitchMaxMidi = 84;
const int kBasicPitchMaxCandidates = 4;
const double kBasicPitchMinFrameActivation = 0.12;
const double kBasicPitchMinSegmentRatio = 0.06;
const double kBasicPitchMinSegmentScore = 0.015;

/// 官方库来源（下载后按 sha256 校验，再由用户放入程序目录）。
const String kLiteRtWindowsUrl =
    'https://pypi.org/project/ai-edge-litert/2.3.0/#files';
const String kLiteRtWindowsSha256 =
    'fd1ee59560a7aa13d44614bd4344c9a75070c18c9faf29792b1841f22dae6add';

class TfliteUnavailableException implements Exception {
  TfliteUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'TfliteUnavailableException: $message';
}

typedef _CreateModelFromFileC = Pointer<Void> Function(Pointer<Utf8>);
typedef _CreateModelFromFile = Pointer<Void> Function(Pointer<Utf8>);
typedef _PtrVoidC = Pointer<Void> Function();
typedef _PtrVoid = Pointer<Void> Function();
typedef _SetIntC = Void Function(Pointer<Void>, Int32);
typedef _SetInt = void Function(Pointer<Void>, int);
typedef _Ptr2C = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _Ptr2 = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _Int1C = Int32 Function(Pointer<Void>);
typedef _Int1 = int Function(Pointer<Void>);
typedef _PtrIntC = Pointer<Void> Function(Pointer<Void>, Int32);
typedef _PtrInt = Pointer<Void> Function(Pointer<Void>, int);
typedef _CopyC = Int32 Function(Pointer<Void>, Pointer<Void>, IntPtr);
typedef _Copy = int Function(Pointer<Void>, Pointer<Void>, int);
typedef _SizeC = IntPtr Function(Pointer<Void>);
typedef _Size = int Function(Pointer<Void>);
typedef _DimC = Int32 Function(Pointer<Void>, Int32);
typedef _Dim = int Function(Pointer<Void>, int);
typedef _NameC = Pointer<Utf8> Function(Pointer<Void>);
typedef _NameD = Pointer<Utf8> Function(Pointer<Void>);
typedef _DelC = Void Function(Pointer<Void>);
typedef _Del = void Function(Pointer<Void>);

/// 最小 TfLite C API 封装；库找不到时抛明确的可诊断错误。
class TfliteInterpreter {
  TfliteInterpreter._(
    this._model,
    this._interpreter,
    this._options,
    this._dylib,
  );

  final Pointer<Void> _model;
  final Pointer<Void> _interpreter;
  final Pointer<Void> _options;
  final DynamicLibrary _dylib;

  static String? resolveLibrary({String? explicitPath}) {
    if (explicitPath != null && explicitPath.isNotEmpty) {
      return File(explicitPath).existsSync() ? explicitPath : null;
    }
    final candidates = <String>[
      if (Platform.environment['WEBHTV_LITERT_DLL'] != null)
        Platform.environment['WEBHTV_LITERT_DLL']!,
      '${File(Platform.resolvedExecutable).parent.path}\\libLiteRt.dll',
      '${Directory.current.path}\\.local\\audio_ai\\litert\\ai_edge_litert\\libLiteRt.dll',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static TfliteInterpreter open(
    String modelPath, {
    String? libraryPath,
    int numThreads = 2,
  }) {
    final resolved = resolveLibrary(explicitPath: libraryPath);
    if (resolved == null) {
      throw TfliteUnavailableException(
        'libLiteRt.dll not found; download Google LiteRT 2.3.0 Windows wheel from '
        '$kLiteRtWindowsUrl, verify sha256 $kLiteRtWindowsSha256, extract '
        'ai_edge_litert/libLiteRt.dll next to the executable',
      );
    }
    if (!File(modelPath).existsSync()) {
      throw TfliteUnavailableException('model not found: $modelPath');
    }
    if (sha256.convert(File(resolved).readAsBytesSync()).toString() !=
        kLiteRtWindowsSha256) {
      throw TfliteUnavailableException('Official LiteRT DLL SHA256 mismatch');
    }
    final modelFile = File(modelPath);
    if (modelFile.lengthSync() != 204448 ||
        sha256.convert(modelFile.readAsBytesSync()).toString() !=
            '3db297d54af8e01c6e5618245c956b1d71b6a2b978cb2dedb527173186552676') {
      throw TfliteUnavailableException(
        'BasicPitch source asset size/SHA256 mismatch',
      );
    }
    final lib = DynamicLibrary.open(resolved);
    final createModel = lib
        .lookupFunction<_CreateModelFromFileC, _CreateModelFromFile>(
          'TfLiteModelCreateFromFile',
        );
    final optionsCreate = lib.lookupFunction<_PtrVoidC, _PtrVoid>(
      'TfLiteInterpreterOptionsCreate',
    );
    final setThreads = lib.lookupFunction<_SetIntC, _SetInt>(
      'TfLiteInterpreterOptionsSetNumThreads',
    );
    final interpreterCreate = lib.lookupFunction<_Ptr2C, _Ptr2>(
      'TfLiteInterpreterCreate',
    );
    final modelPathNative = modelPath.toNativeUtf8();
    final model = createModel(modelPathNative);
    calloc.free(modelPathNative);
    if (model == nullptr) {
      throw TfliteUnavailableException(
        'TfLiteModelCreateFromFile failed: $modelPath',
      );
    }
    final options = optionsCreate();
    setThreads(options, numThreads);
    final interpreter = interpreterCreate(model, options);
    if (interpreter == nullptr) {
      throw TfliteUnavailableException('TfLiteInterpreterCreate failed');
    }
    final allocated = lib.lookupFunction<_Int1C, _Int1>(
      'TfLiteInterpreterAllocateTensors',
    )(interpreter);
    if (allocated != 0) {
      throw TfliteUnavailableException('AllocateTensors failed: $allocated');
    }
    return TfliteInterpreter._(model, interpreter, options, lib);
  }

  String outputName(int index) => _dylib
      .lookupFunction<_NameC, _NameD>('TfLiteTensorName')(outputTensor(index))
      .toDartString();

  int inputCount() => _dylib.lookupFunction<_Int1C, _Int1>(
    'TfLiteInterpreterGetInputTensorCount',
  )(_interpreter);

  int outputCount() => _dylib.lookupFunction<_Int1C, _Int1>(
    'TfLiteInterpreterGetOutputTensorCount',
  )(_interpreter);

  List<int> shapeOf(Pointer<Void> tensor) {
    final numDims = _dylib.lookupFunction<_Int1C, _Int1>('TfLiteTensorNumDims')(
      tensor,
    );
    final dim = _dylib.lookupFunction<_DimC, _Dim>('TfLiteTensorDim');
    return [for (var i = 0; i < numDims; i++) dim(tensor, i)];
  }

  Pointer<Void> inputTensor() => _dylib.lookupFunction<_PtrIntC, _PtrInt>(
    'TfLiteInterpreterGetInputTensor',
  )(_interpreter, 0);

  Pointer<Void> outputTensor(int index) =>
      _dylib.lookupFunction<_PtrIntC, _PtrInt>(
        'TfLiteInterpreterGetOutputTensor',
      )(_interpreter, index);

  void setInput(Float32List values) {
    final tensor = inputTensor();
    final bytes = values.length * 4;
    final pointer = calloc<Float>(values.length);
    pointer.asTypedList(values.length).setAll(0, values);
    final status = _dylib.lookupFunction<_CopyC, _Copy>(
      'TfLiteTensorCopyFromBuffer',
    )(tensor, pointer.cast(), bytes);
    calloc.free(pointer);
    if (status != 0) {
      throw TfliteUnavailableException('copy input failed: $status');
    }
  }

  void invoke() {
    final status = _dylib.lookupFunction<_Int1C, _Int1>(
      'TfLiteInterpreterInvoke',
    )(_interpreter);
    if (status != 0) throw TfliteUnavailableException('invoke failed: $status');
  }

  Float32List readOutput(int index) {
    final tensor = outputTensor(index);
    final size = _dylib.lookupFunction<_SizeC, _Size>('TfLiteTensorByteSize')(
      tensor,
    );
    final buffer = calloc<Uint8>(size);
    final status = _dylib.lookupFunction<_CopyC, _Copy>(
      'TfLiteTensorCopyToBuffer',
    )(tensor, buffer.cast(), size);
    if (status != 0) {
      calloc.free(buffer);
      throw TfliteUnavailableException('copy output failed: $status');
    }
    final result = Float32List(size ~/ 4);
    for (var i = 0; i < result.length; i++) {
      result[i] = buffer.cast<Float>()[i];
    }
    calloc.free(buffer);
    return result;
  }

  List<int> outputShape(int index) => shapeOf(outputTensor(index));

  void dispose() {
    final delInterpreter = _dylib.lookupFunction<_DelC, _Del>(
      'TfLiteInterpreterDelete',
    );
    final delOptions = _dylib.lookupFunction<_DelC, _Del>(
      'TfLiteInterpreterOptionsDelete',
    );
    final delModel = _dylib.lookupFunction<_DelC, _Del>('TfLiteModelDelete');
    delInterpreter(_interpreter);
    delOptions(_options);
    delModel(_model);
  }
}

class BasicPitchProgress {
  const BasicPitchProgress({
    required this.percent,
    required this.stage,
    required this.elapsed,
  });

  final int percent;
  final String stage;
  final Duration elapsed;
}

class BasicPitchService {
  BasicPitchService({required this.modelPath, this.libraryPath});

  final String modelPath;
  final String? libraryPath;

  static Future<BasicPitchService> fromBundledAsset(
    Directory directory, {
    String? libraryPath,
  }) async {
    await directory.create(recursive: true);
    final bytes = await rootBundle.load('assets/models/basic_pitch_nmp.tflite');
    final file = File('${directory.path}/basic_pitch_nmp.tflite');
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    return BasicPitchService(modelPath: file.path, libraryPath: libraryPath);
  }

  /// Authorized source decoding and real TFLite inference run in a worker isolate.
  Future<KaraokePitchTrack> generateFromMedia({
    required Uri mediaUri,
    Map<String, String> headers = const {},
    required List<TimedLyricLine> lines,
    String keyword = '',
    String artist = '',
    AiCancellationToken? cancellationToken,
    void Function(BasicPitchProgress)? onProgress,
  }) async {
    buildKaraokeSegments(lines);
    final token = cancellationToken ?? AiCancellationToken();
    final receive = ReceivePort(), result = Completer<KaraokePitchTrack>();
    AuthorizedMediaProxy? proxy;
    Isolate? worker;
    SendPort? commands;
    int address = 0;
    final apiPath = WindowsAudioCapture.resolveLibrary();
    try {
      final source = mediaUri.scheme == 'file'
          ? mediaUri.toFilePath(windows: true)
          : ((proxy = await AuthorizedMediaProxy.open(
              mediaUri,
              headers,
            )).uri.toString());
      receive.listen((raw) {
        final map = raw as Map;
        switch (map['event']) {
          case 'commands':
            commands = map['port'] as SendPort;
            if (token.isCancelled) commands!.send('cancel');
          case 'audio':
            address = map['address'] as int;
          case 'audioClosed':
            address = 0;
          case 'progress':
            onProgress?.call(map['progress'] as BasicPitchProgress);
          case 'result':
            if (!result.isCompleted) {
              result.complete(map['track'] as KaraokePitchTrack);
            }
          case 'error':
            if (!result.isCompleted) {
              result.completeError(
                KaraokePitchException(map['message'] as String),
              );
            }
        }
      });
      worker = await Isolate.spawn(_pitchWorker, {
        'reply': receive.sendPort,
        'source': source,
        'model': File(modelPath).absolute.path,
        'library': TfliteInterpreter.resolveLibrary(explicitPath: libraryPath),
        'native': apiPath,
        'lines': lines,
        'title': keyword,
        'artist': artist,
      });
      return await Future.any<KaraokePitchTrack>([
        result.future,
        token.whenCancelled.then((_) async {
          commands?.send('cancel');
          await proxy?.close();
          if (address != 0) {
            NativeAudioApi(apiPath).cancel(Pointer<Void>.fromAddress(address));
          }
          throw KaraokePitchException('cancelled');
        }),
      ]);
    } finally {
      await proxy?.close();
      receive.close();
      // Native decode owns its handle and disposes it in finally before returning.
      if (token.isCancelled) commands?.send('cancel');
      if (worker != null && !token.isCancelled) {
        worker.kill(priority: Isolate.beforeNextEvent);
      }
    }
  }

  static const String stagePrepare = 'prepare';
  static const String stageAnalyze = 'analyze';
  static const String stageFinish = 'finish';

  /// 真实推理：读 WAV → 22.05kHz → 逐窗口 TFLite → 逐歌词片段打分 → 评分轨。
  Future<KaraokePitchTrack> generate({
    required String wavPath,
    required List<TimedLyricLine> lines,
    String keyword = '',
    String artist = '',
    void Function(BasicPitchProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final started = DateTime.now();
    onProgress?.call(
      BasicPitchProgress(
        percent: 1,
        stage: stagePrepare,
        elapsed: Duration.zero,
      ),
    );
    final samples = decodeWavPcm(File(wavPath).readAsBytesSync());
    final resampled = _resample(samples.$1, samples.$2, kBasicPitchSampleRate);
    if (resampled.length < kBasicPitchSampleRate) {
      throw KaraokePitchException('audio too short');
    }
    final durationMs = (resampled.length * 1000 / kBasicPitchSampleRate).floor();
    final segments = buildKaraokeSegments(lines, durationMs: durationMs);
    final scores = List.generate(segments.length, (_) => _SegmentScore());
    final interpreter = TfliteInterpreter.open(
      modelPath,
      libraryPath: libraryPath,
    );
    final noteIndex = _findNoteOutput(interpreter);
    final onsetIndex = _findOnsetOutput(interpreter, noteIndex);
    final window = Float32List(kBasicPitchWindow);
    try {
      final totalWindows = (resampled.length / kBasicPitchWindow).ceil();
      for (var w = 0; w < totalWindows; w++) {
        if (isCancelled?.call() ?? false) {
          throw KaraokePitchException('cancelled');
        }
        final start = w * kBasicPitchWindow;
        window.fillRange(0, kBasicPitchWindow, 0);
        for (var i = 0; i < kBasicPitchWindow; i++) {
          final index = start + i;
          if (index < resampled.length) window[i] = resampled[index];
        }
        await Future<void>.delayed(Duration.zero);
        interpreter.setInput(window);
        interpreter.invoke();
        final shape = interpreter.outputShape(noteIndex);
        final note = interpreter.readOutput(noteIndex);
        _collect(
          note: note,
          onset: onsetIndex == null ? null : interpreter.readOutput(onsetIndex),
          frames: shape.length >= 3 ? shape[1] : 0,
          bins: shape.isEmpty ? 0 : shape[shape.length - 1],
          windowStartSample: start,
          segments: segments,
          scores: scores,
        );
        onProgress?.call(
          BasicPitchProgress(
            percent: (10 + 70 * (w + 1) / totalWindows).round(),
            stage: stageAnalyze,
            elapsed: DateTime.now().difference(started),
          ),
        );
      }
    } finally {
      interpreter.dispose();
    }
    final candidates = <List<PitchCandidate>>[
      for (var i = 0; i < segments.length; i++) scores[i].candidates(),
    ];
    final track = buildKaraokePitchTrackFromCandidates(
      title: keyword,
      artist: artist,
      segments: segments,
      candidates: candidates,
    );
    onProgress?.call(
      BasicPitchProgress(
        percent: 100,
        stage: stageFinish,
        elapsed: DateTime.now().difference(started),
      ),
    );
    return track;
  }

  static int? _findOnsetOutput(TfliteInterpreter interpreter, int noteIndex) {
    for (var i = 0; i < interpreter.outputCount(); i++) {
      if (i != noteIndex &&
          interpreter.outputShape(i).last == 88 &&
          interpreter.outputName(i).toLowerCase().contains('onset')) {
        return i;
      }
    }
    for (var i = 0; i < interpreter.outputCount(); i++) {
      if (i != noteIndex && interpreter.outputShape(i).last == 88) return i;
    }
    return null;
  }

  /// 每帧只保留与源 FramePitch 相同的 3 个候选（片段候选上限另为 4）。
  static const int _frameTopK = 3;

  static int _findNoteOutput(TfliteInterpreter interpreter) {
    for (var i = 0; i < interpreter.outputCount(); i++) {
      if (interpreter.outputShape(i).last == 88 &&
          interpreter.outputName(i).toLowerCase().contains('note')) {
        return i;
      }
    }
    for (var i = 0; i < interpreter.outputCount(); i++) {
      final shape = interpreter.outputShape(i);
      if (shape.isNotEmpty && shape.last == 88) return i;
    }
    throw TfliteUnavailableException('Basic Pitch note output not found');
  }

  static void _collect({
    required Float32List note,
    Float32List? onset,
    required int frames,
    required int bins,
    required int windowStartSample,
    required List<KaraokeLyricSegment> segments,
    required List<_SegmentScore> scores,
  }) {
    var segmentIndex = 0;
    for (var frame = 0; frame < frames; frame++) {
      final timeMs = basicPitchFrameTimeMs(windowStartSample, frame);
      while (segmentIndex < segments.length &&
          timeMs >= segments[segmentIndex].endMs + 70) {
        segmentIndex++;
      }
      final offset = frame * bins;
      if (offset + bins > note.length) break;
      final candidates = <(int, double)>[];
      for (var midi = kBasicPitchMinMidi; midi <= kBasicPitchMaxMidi; midi++) {
        final bin = midi - kBasicPitchMidiOffset;
        if (bin < 0 || bin >= bins) continue;
        final activation =
            note[offset + bin] +
            (onset == null || offset + bin >= onset.length
                ? 0
                : onset[offset + bin] * 0.25);
        candidates.add((midi, activation));
      }
      candidates.sort((a, b) => b.$2.compareTo(a.$2));
      final top = candidates.take(_frameTopK).toList();
      var cursor = segmentIndex;
      while (cursor < segments.length) {
        final segment = segments[cursor];
        if (timeMs < segment.startMs - 70) break;
        if (timeMs < segment.endMs + 70) {
          scores[cursor].addCandidates(top);
        }
        cursor++;
      }
    }
  }

  static Float32List _resample(
    Float32List input,
    int sourceRate,
    int targetRate,
  ) {
    if (sourceRate == targetRate) return input;
    final length = (input.length * targetRate / sourceRate).round();
    final output = Float32List(length);
    final step = sourceRate / targetRate;
    for (var i = 0; i < length; i++) {
      final position = i * step;
      final index = position.floor();
      final fraction = position - index;
      final a = input[index.clamp(0, input.length - 1)];
      final b = input[(index + 1).clamp(0, input.length - 1)];
      output[i] = a + (b - a) * fraction;
    }
    return output;
  }
}

/// 解析 16-bit/32-bit float PCM WAV，返回单声道浮点与采样率。
(Float32List, int) decodeWavPcm(Uint8List bytes) {
  if (bytes.length < 44) throw KaraokePitchException('wav too short');
  final data = ByteData.sublistView(bytes);
  var offset = 12;
  int? sampleRate;
  int channels = 1;
  int bits = 16;
  int audioFormat = 1;
  var dataOffset = -1;
  var dataLength = 0;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ') {
      audioFormat = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      dataOffset = body;
      dataLength = math.min(size, bytes.length - body);
      break;
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  if (sampleRate == null || dataOffset < 0) {
    throw KaraokePitchException('wav header missing fmt/data');
  }
  final bytesPerSample = bits ~/ 8;
  final frames = dataLength ~/ (bytesPerSample * channels);
  final mono = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      final position = dataOffset + (i * channels + c) * bytesPerSample;
      if (audioFormat == 3 && bits == 32) {
        sum += data.getFloat32(position, Endian.little);
      } else if (bits == 16) {
        sum += data.getInt16(position, Endian.little) / 32768.0;
      } else {
        sum += 0;
      }
    }
    mono[i] = (sum / channels).clamp(-1.0, 1.0);
  }
  return (mono, sampleRate);
}

class _SegmentScore {
  final List<double> scores = List.filled(kBasicPitchMaxMidi + 1, 0);
  int totalFrames = 0;
  int activeFrames = 0;

  void addCandidates(List<(int, double)> values) {
    totalFrames++;
    if (values.isEmpty || values.first.$2 < kBasicPitchMinFrameActivation) {
      return;
    }
    activeFrames++;
    for (final item in values) {
      final midi = item.$1, value = item.$2;
      if (midi < kBasicPitchMinMidi ||
          midi > kBasicPitchMaxMidi ||
          value < kBasicPitchMinFrameActivation * 0.55) {
        continue;
      }
      scores[midi] += value;
      if (midi > kBasicPitchMinMidi) scores[midi - 1] += value * 0.12;
      if (midi < kBasicPitchMaxMidi) scores[midi + 1] += value * 0.12;
    }
  }

  List<PitchCandidate> candidates() {
    if (totalFrames <= 0 || activeFrames < 2) return const [];
    final ratio = activeFrames / totalFrames;
    var best = 0.0;
    for (var midi = kBasicPitchMinMidi; midi <= kBasicPitchMaxMidi; midi++) {
      best = math.max(best, scores[midi]);
    }
    final average = best / totalFrames;
    if (ratio < kBasicPitchMinSegmentRatio ||
        average < kBasicPitchMinSegmentScore) {
      return const [];
    }
    final result = <PitchCandidate>[];
    final used = List.filled(kBasicPitchMaxMidi + 1, false);
    for (var count = 0; count < kBasicPitchMaxCandidates; count++) {
      var bestPitch = -1;
      var bestScore = 0.0;
      for (var midi = kBasicPitchMinMidi; midi <= kBasicPitchMaxMidi; midi++) {
        if (used[midi]) continue;
        if (scores[midi] > bestScore) {
          bestScore = scores[midi];
          bestPitch = midi;
        }
      }
      if (bestPitch < 0 || bestScore < best * 0.18) break;
      final quality = math.max(
        0.05,
        math.min(1.0, ratio * 0.70 + (bestScore / totalFrames) * 2.20),
      );
      result.add(PitchCandidate(midi: bestPitch, quality: quality));
      for (var midi = bestPitch - 1; midi <= bestPitch + 1; midi++) {
        if (midi >= kBasicPitchMinMidi && midi <= kBasicPitchMaxMidi) {
          used[midi] = true;
        }
      }
      for (var midi = bestPitch - 24; midi <= bestPitch + 24; midi += 12) {
        if (midi >= kBasicPitchMinMidi && midi <= kBasicPitchMaxMidi) {
          used[midi] = true;
        }
      }
    }
    return result;
  }
}

void _pitchWorker(Map<String, Object?> args) async {
  final reply = args['reply'] as SendPort, commands = ReceivePort();
  var cancelled = false;
  commands.listen((message) {
    if (message == 'cancel') cancelled = true;
  });
  reply.send({'event': 'commands', 'port': commands.sendPort});
  final api = NativeAudioApi(args['native'] as String);
  Pointer<Void> audio = nullptr;
  Directory? temp;
  final samples = calloc<Float>(1600), pts = calloc<Int64>();
  try {
    audio = api.openMedia(args['source'] as String);
    if (audio == nullptr) throw KaraokePitchException(api.error);
    reply.send({'event': 'audio', 'address': audio.address});
    final lines = (args['lines'] as List).cast<TimedLyricLine>();
    final endUs = (lines.map((l) => l.endMs).reduce(math.max) + 1000) * 1000;
    final data = BytesBuilder(copy: false);
    while (!cancelled) {
      final count = api.read(audio, samples, 1600, pts);
      if (count == -2) break;
      if (count < 0) throw KaraokePitchException(api.error);
      if (count > 0) {
        data.add(
          Float32List.fromList(samples.asTypedList(count)).buffer.asUint8List(),
        );
      }
      if (pts.value >= endUs) break;
      await Future<void>.delayed(Duration.zero);
    }
    api.close(audio);
    audio = nullptr;
    reply.send({'event': 'audioClosed'});
    if (cancelled) throw KaraokePitchException('cancelled');
    final bytes = data.takeBytes();
    temp = await Directory.systemTemp.createTemp('webhtv_basic_pitch_');
    final wav = File('${temp.path}/decoded.wav');
    final header = ByteData(44);
    void text(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    text(0, 'RIFF');
    header.setUint32(4, bytes.length + 36, Endian.little);
    text(8, 'WAVEfmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 3, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 16000, Endian.little);
    header.setUint32(28, 64000, Endian.little);
    header.setUint16(32, 4, Endian.little);
    header.setUint16(34, 32, Endian.little);
    text(36, 'data');
    header.setUint32(40, bytes.length, Endian.little);
    final sink = wav.openWrite();
    sink.add(header.buffer.asUint8List());
    sink.add(bytes);
    await sink.close();
    final service = BasicPitchService(
      modelPath: args['model'] as String,
      libraryPath: args['library'] as String?,
    );
    final track = await service.generate(
      wavPath: wav.path,
      lines: lines,
      keyword: args['title'] as String,
      artist: args['artist'] as String,
      isCancelled: () => cancelled,
      onProgress: (value) =>
          reply.send({'event': 'progress', 'progress': value}),
    );
    if (cancelled) throw KaraokePitchException('cancelled');
    reply.send({'event': 'result', 'track': track});
  } catch (error) {
    reply.send({'event': 'error', 'message': error.toString()});
  } finally {
    if (audio != nullptr) {
      api.close(audio);
      reply.send({'event': 'audioClosed'});
    }
    calloc.free(samples);
    calloc.free(pts);
    commands.close();
    if (temp != null && await temp.exists()) await temp.delete(recursive: true);
  }
}
