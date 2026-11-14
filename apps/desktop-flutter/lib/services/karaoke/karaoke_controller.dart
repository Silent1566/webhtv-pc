import 'dart:async';
import 'dart:math' as math;

import '../../core/karaoke/karaoke.dart';
import 'track_repository.dart';
import 'mic_source.dart';
import 'windows_mic_source.dart';
export 'mic_source.dart';

enum KaraokeStatus { inactive, micUnavailable, scoring, freeSing }

class KaraokeState {
  const KaraokeState({
    this.status = KaraokeStatus.inactive,
    this.track,
    this.sample = const KaraokePitchSample.empty(),
    this.snapshot = const KaraokeScoreSnapshot(),
    this.error = '',
  });
  final KaraokeStatus status;
  final KaraokeTrack? track;
  final KaraokePitchSample sample;
  final KaraokeScoreSnapshot snapshot;
  final String error;
  bool get freeSing => status == KaraokeStatus.freeSing;
}

/// 唱声评分控制器：媒体时钟 + 参考轨/自由唱评分 + 麦克风生命周期。
///
/// 状态机：inactive → (start) scoring/freeSing → (pause) 保留分数但不再累计 →
/// (stop) 回到 inactive 并释放设备；seek/换媒体重置评分并丢弃过期轨加载结果。
class KaraokeController {
  KaraokeController({
    required this.clock,
    required this.repository,
    KaraokeMicSource? mic,
  }) : mic = mic ?? WindowsKaraokeMicSource(),
       _ownsMic = mic == null;
  final AudioSessionClock clock;
  final KaraokeTrackRepository repository;
  final KaraokeMicSource mic;
  final bool _ownsMic;
  final _changes = StreamController<KaraokeState>.broadcast();
  final _samples = StreamController<KaraokePitchSample>.broadcast();
  StreamSubscription<KaraokePitchSample>? _micSubscription;

  KaraokeState _state = const KaraokeState();
  KaraokeMedia? _media;
  List<TimedLyricLine> _lyrics = const [];
  KaraokeTrack? _track;
  KaraokeScorer? _scorer;
  KaraokeFreeSingScorer? _freeScorer;
  KaraokeScoringConfig _config = const KaraokeScoringConfig();
  KaraokePitchSample _sample = const KaraokePitchSample.empty();
  bool _active = false;
  bool _userPaused = false;
  bool _wasScoring = false;
  int? _lastScoredPosition;
  int _generation = 0;
  int _lyricsOffsetMs = 0;
  bool _micUnavailable = false;
  String _error = '';

  Stream<KaraokeState> get changes => _changes.stream;
  Stream<KaraokePitchSample> get pitches => _samples.stream;
  KaraokeState get state => _state;
  KaraokePitchSample get sample => _sample;
  KaraokeScoreSnapshot get snapshot =>
      _scorer?.snapshot ?? _freeScorer?.snapshot ?? _state.snapshot;
  KaraokeResult get result => KaraokeResult.from(_track, snapshot);
  bool get isActive => _active;
  bool get isPaused => _userPaused;
  bool get _canScore =>
      _active && !_userPaused && clock.playing && !_micUnavailable;
  KaraokeTrack? get track => _track;
  String get micUnavailableReason => mic.unavailableReason;

  /// 绑定当前媒体：身份变化即重置，旧代的加载结果按代际丢弃。
  Future<void> bindMedia(
    KaraokeMedia media, {
    List<TimedLyricLine> lyrics = const [],
    KaraokeTrack? track,
  }) async {
    final generation = ++_generation;
    _wasScoring = false;
    _lastScoredPosition = null;
    _media = media;
    _lyrics = lyrics;
    _track = track;
    _scorer = track != null && track.hasScoredNotes
        ? KaraokeScorer(track, _config)
        : null;
    _freeScorer = _scorer == null ? KaraokeFreeSingScorer(_config) : null;
    _emit();
    if (track != null) return;
    final loaded = await repository.load(media);
    if (generation != _generation) return;
    _applyTrack(loaded);
    _emit();
  }

  /// 直接选择参考轨；传 null 进入自由唱。
  void selectTrack(KaraokeTrack? track) {
    _generation++;
    _wasScoring = false;
    _lastScoredPosition = null;
    _track = track;
    _scorer = track != null && track.hasScoredNotes
        ? KaraokeScorer(track, _config)
        : null;
    _freeScorer = _scorer == null ? KaraokeFreeSingScorer(_config) : null;
    _emit();
  }

  /// 生成轨（BasicPitch 等）导入后替换当前评分轨。
  Future<KaraokeImportResult> importGenerated(
    KaraokePitchTrack pitchTrack,
  ) async {
    final media = _media;
    if (media == null) return KaraokeImportResult.fail('no media bound');
    final generation = _generation,
        session = clock.sessionId,
        clockGeneration = clock.generation;
    final result = await repository.importGenerated(media, pitchTrack);
    if (generation != _generation ||
        !identical(media, _media) ||
        session != clock.sessionId ||
        clockGeneration != clock.generation ||
        !_active)
      return KaraokeImportResult.fail('stale generated track');
    if (result.success && result.track != null && result.track!.hasScoredNotes)
      selectTrack(result.track);
    return result;
  }

  void configure(KaraokeScoringConfig config) {
    _config = config;
    _wasScoring = false;
    _lastScoredPosition = null;
    if (_track != null)
      _scorer = KaraokeScorer(_track!, config);
    else
      _freeScorer = KaraokeFreeSingScorer(config);
    _emit();
  }

  /// 延迟校准与难度：只改配置，不影响麦克风与当前已得分数之外的会话。
  void setScoring({
    double? toleranceSemitones,
    bool? ignoreOctave,
    int? inputLatencyMs,
  }) => configure(
    KaraokeScoringConfig(
      toleranceSemitones: toleranceSemitones ?? _config.toleranceSemitones,
      ignoreOctave: ignoreOctave ?? _config.ignoreOctave,
      minVolume: _config.minVolume,
      minConfidence: _config.minConfidence,
      inputLatencyMs: inputLatencyMs ?? _config.inputLatencyMs,
      maxSliceMs: _config.maxSliceMs,
    ),
  );

  Future<bool> start() async {
    if (_active && !_micUnavailable) {
      resume();
      return true;
    }
    _active = true;
    _userPaused = false;
    if (_micSubscription == null) {
      _micSubscription = mic.samples.listen(
        _onSample,
        onError: (Object error) {
          _micUnavailable = true;
          _wasScoring = false;
          _lastScoredPosition = null;
          _error = '$error';
          _emit();
        },
      );
    }
    final started = await mic.start();
    _micUnavailable = !started;
    _error = started ? '' : mic.unavailableReason;
    _syncScoringGate();
    _emit();
    return started;
  }

  void pause() {
    _userPaused = true;
    _wasScoring = false;
    _lastScoredPosition = null;
    _emit();
  }

  void resume() {
    _userPaused = false;
    _syncScoringGate();
    _emit();
  }

  /// 释放评分资源并保留结果，不修改共享播放器时钟。
  Future<void> stop() async {
    _active = false;
    _userPaused = true;
    _wasScoring = false;
    _lastScoredPosition = null;
    await _micSubscription?.cancel();
    _micSubscription = null;
    await mic.stop();
    _emit();
  }

  /// seek：位置重设、代际 +1，评分清零，旧结果不再应用。
  void seek(Duration position) {
    clock.reset(position: position);
    _wasScoring = false;
    _lastScoredPosition = null;
    _scorer?.reset();
    _freeScorer?.reset();
    _emit();
  }

  void updateClock({
    Duration? position,
    bool? playing,
    double? rate,
    int? lyricsOffsetMs,
  }) {
    if (lyricsOffsetMs != null) _lyricsOffsetMs = lyricsOffsetMs;
    clock.update(position: position, playing: playing, rate: rate);
    advance();
    _emit();
  }

  void updateLyrics(List<TimedLyricLine> lyrics) {
    _lyrics = lyrics;
    _emit();
  }

  int get positionMs =>
      math.max(0, clock.position.inMilliseconds + _lyricsOffsetMs);

  void _syncScoringGate() {
    if (!_canScore) {
      _wasScoring = false;
      _lastScoredPosition = null;
      return;
    }
    if (!_wasScoring) {
      if (_scorer != null) {
        _scorer!.reanchor(positionMs);
      } else {
        (_freeScorer ??= KaraokeFreeSingScorer(_config)).reanchor(positionMs);
      }
      _lastScoredPosition = positionMs;
      _wasScoring = true;
    }
  }

  /// 所有入口共用双闸门；恢复先重锚，不允许直接调用绕过暂停或禁用状态。
  KaraokeScoreSnapshot advance() {
    _syncScoringGate();
    if (!_canScore) return snapshot;
    final position = positionMs;
    if (_lastScoredPosition == position) return snapshot;
    _lastScoredPosition = position;
    final scorer = _scorer;
    final next = scorer != null
        ? scorer.update(
            position,
            _sample.frequencyHz,
            _sample.volume,
            _sample.confidence,
          )
        : (_freeScorer ??= KaraokeFreeSingScorer(
            _config,
          )).update(position, _sample, _lyrics);
    _emit();
    return next;
  }

  /// 注入一帧音高（真实麦克风或测试合成 PCM 都走这里）。
  void pushSample(
    KaraokePitchSample sample, {
    int? sessionId,
    int? generation,
  }) {
    if (generation != null && generation != clock.generation) return;
    if (sessionId != null && sessionId != clock.sessionId) return;
    _onSample(sample);
  }

  void _onSample(KaraokePitchSample sample) {
    if (!sample.frequencyHz.isFinite ||
        !sample.volume.isFinite ||
        !sample.confidence.isFinite)
      return;
    _sample = sample;
    _micUnavailable = false;
    _samples.add(sample);
    _emit();
  }

  void _applyTrack(KaraokeTrack? track) {
    _wasScoring = false;
    _lastScoredPosition = null;
    _track = track != null && track.hasScoredNotes ? track : null;
    _scorer = _track == null ? null : KaraokeScorer(_track!, _config);
    _freeScorer = _scorer == null ? KaraokeFreeSingScorer(_config) : null;
  }

  void _emit() {
    final status = !_active
        ? KaraokeStatus.inactive
        : _micUnavailable
        ? KaraokeStatus.micUnavailable
        : _scorer != null
        ? KaraokeStatus.scoring
        : KaraokeStatus.freeSing;
    _state = KaraokeState(
      status: status,
      track: _track,
      sample: _sample,
      snapshot: snapshot,
      error: _error,
    );
    if (!_changes.isClosed) _changes.add(_state);
  }

  Future<void> dispose() async {
    await stop();
    if (_ownsMic && mic is WindowsKaraokeMicSource)
      await (mic as WindowsKaraokeMicSource).dispose();
    await _samples.close();
    await _changes.close();
  }
}
