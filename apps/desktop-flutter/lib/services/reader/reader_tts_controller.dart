import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/reader/reader_models.dart';
import 'reader_preferences_store.dart';
import 'tts_engines.dart';

/// 播放层接口：生产实现是media_kit，测试注入fixture。
///
/// 暂停/停止统一走 [stop]：合成与播放的进度由控制器的段落游标重放，避免半句残留。
abstract interface class ReaderAudioOutput {
  Future<void> play(TtsAudio audio);
  Future<void> stop();
  Future<void> dispose();
}

/// 朗读编排器：段落推进、暂停/停止、上一段/下一段、跳段、定时、偏好持久化。
class ReaderTtsController extends ChangeNotifier {
  ReaderTtsController({
    required this.engines,
    required this.store,
    required this.audio,
  });
  final TtsEngines engines;
  final ReaderPreferencesStore store;
  final ReaderAudioOutput audio;

  ReaderPreferences _settings = ReaderPreferences();
  List<TtsChunk> _chunks = const [];
  int _index = -1;
  ReaderTtsState _state = ReaderTtsState.stopped;
  String _message = '';
  String _title = '';
  Timer? _timer;
  TtsEngine? _engine;
  Object _generation = Object();
  bool _closed = false;

  /// 章末回调：必须在落 STOPPED 之前触发（对齐源 ReaderTtsController）。
  void Function()? onChapterEnd;

  ReaderTtsState get state => _state;
  String get message => _message;
  String get title => _title;
  bool get isActive =>
      _state == ReaderTtsState.playing || _state == ReaderTtsState.paused;
  int get currentParagraph =>
      _index < 0 || _index >= _chunks.length ? -1 : _chunks[_index].paragraph;
  int get paragraphCount => _chunks.isEmpty ? 0 : _chunks.last.paragraph + 1;
  int get timerMinutes => _settings.timerMinutes;
  TtsSource get source => _settings.source;
  TtsOptions get options => _settings.options;
  ReaderPreferences get settings => _settings;

  /// 重启恢复：从任务专属文件读回来源/语速/音调/音色/定时。
  void loadPreferences() => _settings = store.load();

  /// 当前音源的真实音色列表；引擎不可用或探测失败时返回空表 + 如实提示。
  Future<(List<TtsVoice>, String?)> availableVoices() async {
    TtsEngine? engine;
    try {
      engine = engines.factory(_settings);
      final voices = await engine.voices();
      return (voices, voices.isEmpty ? '当前音源没有可用音色（或系统未安装语音包）' : null);
    } on Object catch (error) {
      return (const <TtsVoice>[], _clean(error));
    } finally {
      await engine?.dispose();
    }
  }

  Future<void> start({
    required List<String> paragraphs,
    int startIndex = 0,
    String title = '',
  }) async {
    if (_closed) throw StateError('朗读控制器已关闭');
    await stop();
    _title = title;
    _chunks = splitTtsText(
      paragraphs,
      online: _settings.source != TtsSource.system,
    );
    if (_chunks.isEmpty) {
      _setState(ReaderTtsState.error, '没有可朗读的内容');
      return;
    }
    _index = _firstChunkOfParagraph(
      startIndex.clamp(0, paragraphs.isEmpty ? 0 : paragraphs.length - 1),
    );
    if (_index < 0) {
      _setState(ReaderTtsState.error, '没有可朗读的内容');
      return;
    }
    _generation = Object();
    try {
      _engine = engines.factory(_settings);
    } on Object catch (error) {
      _setState(ReaderTtsState.error, _clean(error));
      return;
    }
    _setState(ReaderTtsState.playing, null);
    _scheduleTimer();
    unawaited(_pump());
  }

  Future<void> _pump() async {
    final engine = _engine;
    final generation = _generation;
    if (_state != ReaderTtsState.playing || engine == null) return;
    if (_index < 0 || _index >= _chunks.length) {
      await _finishChapter();
      return;
    }
    try {
      final audioBytes = await engine
          .synthesize(_chunks[_index].text, _settings.options)
          .timeout(const Duration(seconds: 60));
      if (!identical(generation, _generation)) return; // 过期代际结果不可播放
      await audio.play(audioBytes);
      if (!identical(generation, _generation)) return;
      if (_state == ReaderTtsState.stopped || _state == ReaderTtsState.error) {
        return;
      }
      _index++;
      if (_index >= _chunks.length) {
        await _finishChapter();
        return;
      }
      unawaited(_pump());
    } on Object catch (error) {
      if (!identical(generation, _generation)) return;
      _engine = null;
      await engine.dispose();
      if (!identical(generation, _generation)) return;
      _setState(ReaderTtsState.error, _clean(error));
    }
  }

  Future<void> _finishChapter() async {
    final generation = _generation = Object();
    final engine = _engine;
    _engine = null;
    _timer?.cancel();
    _timer = null;
    _index = -1;
    engine?.cancel();
    onChapterEnd?.call(); // 先发章末再落 STOPPED
    await audio.stop();
    await engine?.dispose();
    if (!identical(generation, _generation)) return;
    _setState(ReaderTtsState.stopped, null);
  }

  Future<void> pause() async {
    if (_state != ReaderTtsState.playing || _engine == null || _index < 0) return;
    _generation = Object();
    _setState(ReaderTtsState.paused, null);
    _engine?.cancel();
    _timer?.cancel();
    await audio.stop();
  }

  Future<void> resume() async {
    if (_state != ReaderTtsState.paused || _engine == null || _index < 0) return;
    _setState(ReaderTtsState.playing, null);
    _scheduleTimer();
    unawaited(_pump());
  }

  Future<void> toggle() async {
    _state == ReaderTtsState.playing ? await pause() : await resume();
  }

  Future<void> previous() async {
    if (!isActive) return;
    final paragraph = currentParagraph;
    if (paragraph < 0) return;
    final firstOfCurrent = _firstChunkOfParagraph(paragraph);
    final target = _index > firstOfCurrent
        ? firstOfCurrent
        : _firstChunkOfParagraph(paragraph - 1);
    await _seek(target);
  }

  Future<void> next() async {
    if (!isActive || _engine == null || _index < 0) return;
    final target = _firstChunkOfParagraph(currentParagraph + 1);
    if (target < 0) {
      await _finishChapter();
      return;
    }
    await _seek(target);
  }

  Future<void> seekParagraph(int paragraph) async {
    if (!isActive || paragraph < 0) return;
    final target = _firstChunkOfParagraph(paragraph);
    if (target >= 0) await _seek(target);
  }

  Future<void> _seek(int index) async {
    if (_engine == null || index < 0 || index >= _chunks.length) return;
    _generation = Object();
    await audio.stop();
    _index = index;
    _setState(ReaderTtsState.playing, null);
    _scheduleTimer();
    unawaited(_pump());
  }

  Future<void> setSource(TtsSource source) async =>
      _persist(_settings.copyWith(source: source));
  Future<void> setRate(double value) async => _persist(
    _settings.copyWith(options: _settings.options.copyWith(rate: value)),
  );
  Future<void> setPitch(double value) async => _persist(
    _settings.copyWith(options: _settings.options.copyWith(pitch: value)),
  );
  Future<void> setVoice(String voice) async => _persist(
    _settings.copyWith(options: _settings.options.copyWith(voice: voice)),
  );
  Future<void> setCustom(TtsCustomConfig? config) async =>
      _persist(_settings.copyWith(custom: config));

  Future<void> setTimer(int minutes) async {
    final settings = _settings.copyWith(timerMinutes: minutes);
    _message = settings.timerMinutes > 0
        ? '朗读定时 ${settings.timerMinutes} 分钟'
        : '';
    _persist(settings);
    if (isActive) _scheduleTimer();
  }

  /// 在现有定时上追加（通知/面板「+30 分钟」）。
  Future<void> addTimer(int delta) async => setTimer(timerMinutes + delta);

  void _persist(ReaderPreferences value) {
    _settings = value;
    store.save(_settings);
    notifyListeners();
  }

  void _scheduleTimer() {
    _timer?.cancel();
    if (_settings.timerMinutes <= 0 || !isActive) return;
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_state != ReaderTtsState.playing || _engine == null || _index < 0) return;
      final settings = _settings.copyWith(
        timerMinutes: _settings.timerMinutes - 1,
      );
      _message = '朗读定时剩余 ${settings.timerMinutes} 分钟';
      _persist(settings);
      if (_settings.timerMinutes <= 0) unawaited(stop('定时朗读结束'));
    });
  }

  Future<void> stop([String? reason]) async {
    final generation = _generation = Object();
    final engine = _engine;
    _engine = null;
    _timer?.cancel();
    _timer = null;
    engine?.cancel();
    await audio.stop();
    await engine?.dispose();
    if (!identical(generation, _generation)) return;
    _chunks = const [];
    _index = -1;
    _setState(ReaderTtsState.stopped, reason ?? '');
  }

  Future<void> close() async {
    _closed = true;
    await stop();
    await audio.dispose();
  }

  void _setState(ReaderTtsState value, String? reason) {
    _state = value;
    if (reason != null) _message = reason;
    notifyListeners();
  }

  int _firstChunkOfParagraph(int paragraph) {
    for (var index = 0; index < _chunks.length; index++) {
      if (_chunks[index].paragraph >= paragraph) return index;
    }
    return -1;
  }

  static String _clean(Object error) {
    final text = '$error';
    return text
        .replaceFirst(RegExp(r'^\w+Exception: '), '')
        .replaceFirst('Bad state: ', '')
        .replaceFirst('FormatException: ', '');
  }
}

