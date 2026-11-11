import 'dart:convert';
import 'dart:io';

import '../../core/reader/reader_models.dart';
import 'edge_tts_engine.dart';
import 'http_tts_engine.dart';
import 'media_kit_reader_audio.dart';
import 'reader_preferences_store.dart';
import 'reader_tts_controller.dart';

abstract interface class TtsEngine {
  Future<List<TtsVoice>> voices();
  Future<TtsAudio> synthesize(String text, TtsOptions options);
  void cancel();
  Future<void> dispose();
}

/// system音源：真实Windows host（PowerShell + .NET Framework System.Speech）。
///
/// 合成结果写任务专属临时WAV并立即由调用方消费；失败/取消/超时都终止进程并清理该WAV。
class WindowsSystemTtsEngine implements TtsEngine {
  WindowsSystemTtsEngine({String? executable})
    : executable = executable ?? defaultExecutable();
  static String defaultExecutable() =>
      '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  final String executable;
  Process? _process;
  final _temporaryWaves = <String>{};

  @override
  Future<List<TtsVoice>> voices() async {
    const script = r'''
Add-Type -AssemblyName System.Speech
[Console]::OutputEncoding=[Text.Encoding]::UTF8
(New-Object System.Speech.Synthesis.SpeechSynthesizer).GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name + '|' + $_.VoiceInfo.Culture.Name }
''';
    final stdout = await _run(script);
    return stdout.trim().split('\n').where((line) => line.contains('|')).map((
      line,
    ) {
      final parts = line.trim().split('|');
      return TtsVoice(
        parts.first.trim(),
        parts.first.trim(),
        parts.length > 1 ? parts[1].trim() : 'zh-CN',
      );
    }).toList();
  }

  @override
  Future<TtsAudio> synthesize(String text, TtsOptions options) async {
    if (text.trim().isEmpty) throw StateError('该片段没有可朗读内容');
    final wave = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}webhtv_reader_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    _temporaryWaves.add(wave.path);
    final payload = base64Encode(utf8.encode(text));
    final voice = options.voice.replaceAll("'", "''");
    final rate = ((options.rate - 1) * 5).round().clamp(-5, 5);
    final script =
        '''
Add-Type -AssemblyName System.Speech
\$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
\$text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload'))
\$voice = '$voice'
if (\$voice) { \$s.SelectVoice(\$voice) }
\$s.Rate = $rate
\$s.SetOutputToWaveFile('${wave.path.replaceAll(r'\', r'\\')}')
\$s.Speak(\$text)
\$s.Dispose()
''';
    try {
      _process = await Process.start(executable, [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]);
      final stderr = _process!.stderr.transform(utf8.decoder).join();
      final stdout = _process!.stdout.transform(utf8.decoder).join();
      final exit = await _process!.exitCode.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          _process!.kill();
          throw StateError('系统TTS合成超时');
        },
      );
      await stdout;
      final error = await stderr;
      if (exit != 0) {
        final detail = error.trim().split('\n').take(2).join(' ').trim();
        throw StateError(
          '系统TTS不可用（PowerShell exit $exit）${detail.isEmpty ? '' : '：$detail'}',
        );
      }
      if (!wave.existsSync() || wave.lengthSync() == 0) {
        throw StateError('系统TTS没有产出音频');
      }
      return TtsAudio(wave.readAsBytesSync(), 'wav');
    } finally {
      _process = null;
      _deleteWaves();
    }
  }

  Future<String> _run(String script) async {
    final process = await Process.start(executable, [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
    _process = process;
    try {
      final stdout = process.stdout.transform(utf8.decoder).join();
      final error = process.stderr.transform(utf8.decoder).join();
      final exit = await process.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          process.kill();
          throw StateError('Windows系统TTS探测超时');
        },
      );
      final output = await stdout;
      final detail = (await error).trim();
      if (exit != 0) {
        throw StateError(
          'Windows系统TTS不可用：${detail.isEmpty ? 'exit $exit' : detail}',
        );
      }
      return output;
    } finally {
      _process = null;
    }
  }

  void _deleteWaves() {
    for (final path in _temporaryWaves) {
      final file = File(path);
      try {
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException {
        /* 已被系统占用，交由OS清理。 */
      }
    }
    _temporaryWaves.clear();
  }

  @override
  void cancel() {
    _process?.kill();
    _process = null;
    _deleteWaves();
  }

  @override
  Future<void> dispose() async => cancel();
}

/// 引擎注册表：按来源构造真实引擎；测试可注入factory。
class TtsEngines {
  TtsEngines({
    TtsEngine Function(ReaderPreferences settings)? factory,
    String? systemExecutable,
  }) : factory =
           factory ??
           ((settings) =>
               createEngine(settings, systemExecutable: systemExecutable));
  final TtsEngine Function(ReaderPreferences settings) factory;

  static TtsEngine createEngine(
    ReaderPreferences settings, {
    String? systemExecutable,
  }) {
    switch (settings.source) {
      case TtsSource.edge:
        return EdgeTtsEngine();
      case TtsSource.baidu:
        return BaiduTtsEngine();
      case TtsSource.custom:
        final custom = settings.custom;
        if (custom == null) throw const FormatException('请先配置在线朗读引擎');
        return HttpTtsEngine(custom);
      case TtsSource.system:
        return WindowsSystemTtsEngine(executable: systemExecutable);
    }
  }

  /// Task6接线工厂：给真实configDir即可得到带持久化偏好/引擎/播放输出的controller。
  static ReaderTtsController create({
    required String configDir,
    ReaderAudioOutput? audio,
    String? systemExecutable,
  }) => ReaderTtsController(
    engines: TtsEngines(systemExecutable: systemExecutable),
    store: ReaderPreferencesStore(
      '$configDir${Platform.pathSeparator}reader_tts.json',
    ),
    audio: audio ?? MediaKitReaderAudio(),
  );
}
