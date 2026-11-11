import 'dart:convert';
import 'dart:io';

/// 语音识别宿主接口；生产实现是 [WindowsSpeechRecognitionHost]，测试注入 fixture。
abstract interface class SpeechRecognitionHost {
  /// language 为 BCP-47 系统语音包名称；指定但未安装时如实失败，不静默选其他语言。
  Future<List<String>> recognize({String? language});
  void cancel();
}

/// Windows 真实 host 语音识别 adapter（PowerShell + .NET Framework System.Speech）。
///
/// 源宿主的系统 SpeechRecognizer 可能把音频送到厂商服务，**不承诺离线**；本 adapter
/// 同样不做离线承诺。机器没有安装识别引擎、没有麦克风、识别超时或进程失败时一律如实
/// 抛错/返回空结果，绝不伪造识别文本。取消即终止进程，不留后台识别任务。
class WindowsSpeechRecognitionHost implements SpeechRecognitionHost {
  WindowsSpeechRecognitionHost({String? executable})
    : executable = executable ?? defaultExecutable();

  /// 直接用绝对路径定位 PowerShell：不依赖 `python`/`powershell` 之类 PATH 名字。
  static String defaultExecutable() =>
      '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}'
      r'\System32\WindowsPowerShell\v1.0\powershell.exe';

  final String executable;
  Process? _process;

  @override
  Future<List<String>> recognize({String? language}) async {
    final encodedLanguage = base64Encode(
      utf8.encode(language?.trim().replaceAll('_', '-') ?? ''),
    );
    final script =
        '''
Add-Type -AssemblyName System.Speech
[Console]::OutputEncoding = [Text.Encoding]::UTF8
\$recognizers = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()
if (\$recognizers.Count -eq 0) { Write-Error 'no recognizer'; exit 2 }
\$recognizer = \$recognizers[0]
\$language = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedLanguage'))
if (-not [String]::IsNullOrWhiteSpace(\$language)) {
  \$recognizer = \$recognizers | Where-Object { \$_.Culture.Name -ieq \$language } | Select-Object -First 1
  if (-not \$recognizer) { Write-Error 'requested language unavailable'; exit 5 }
}
\$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine(\$recognizer)
\$engine.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar))
\$engine.InitialSilenceTimeout = [TimeSpan]::FromSeconds(10)
\$engine.BabbleTimeout = [TimeSpan]::FromSeconds(5)
\$engine.EndSilenceTimeout = [TimeSpan]::FromSeconds(1)
try { \$engine.SetInputToDefaultAudioDevice() } catch { Write-Error 'no microphone'; exit 4 }
\$result = \$engine.Recognize([TimeSpan]::FromSeconds(15))
if (-not \$result) { exit 3 }
Write-Output \$result.Text
''';
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
      final stderr = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          process.kill();
          throw StateError('系统语音识别超时');
        },
      );
      final text = (await stdout).trim();
      final detail = (await stderr).trim();
      switch (exitCode) {
        case 0:
          return text.isEmpty ? const [] : [text];
        case 2:
          throw StateError('没有系统识别引擎');
        case 5:
          throw StateError('没有所请求语言的系统识别引擎：${language?.trim()}');
        case 4:
          throw StateError('没有可用的麦克风输入设备');
        case 3:
          return const []; // 引擎正常但没识别到语音。
        default:
          throw StateError(
            '系统语音识别失败（exit $exitCode）${detail.isEmpty ? '' : '：$detail'}',
          );
      }
    } finally {
      process.kill();
      _process = null;
    }
  }

  @override
  void cancel() {
    _process?.kill();
    _process = null;
  }
}

/// 语音搜索服务：一次识别只消费首条文本；取消后迟到结果不可应用。
class SpeechSearchService {
  SpeechSearchService({SpeechRecognitionHost? host})
    : host = host ?? WindowsSpeechRecognitionHost();

  final SpeechRecognitionHost host;
  bool _listening = false;
  String _message = '';
  Object _generation = Object();

  bool get listening => _listening;

  /// 面向 UI 的提示：引擎不可用、取消或无结果时都由这里如实给出。
  String get message => _message;

  /// 开始一次真实识别，返回首条文本；不可用/取消/无结果时返回 `null`。
  Future<String?> listen({String? language}) async {
    if (_listening) return null;
    _listening = true;
    final generation = _generation = Object();
    _message = '正在聆听…';
    try {
      final results = await host.recognize(language: language);
      if (!identical(generation, _generation)) return null; // 取消后的迟到结果不可应用
      if (results.isEmpty) {
        _message = '未识别到语音，请重试或使用键盘搜索';
        return null;
      }
      _message = '';
      return results.first;
    } on Object catch (error) {
      if (!identical(generation, _generation)) return null;
      _message = _clean(error);
      return null;
    } finally {
      if (identical(generation, _generation)) _listening = false;
    }
  }

  void cancel() {
    _generation = Object();
    host.cancel();
    _listening = false;
    _message = '已取消语音搜索';
  }

  void dispose() => cancel();

  static String _clean(Object error) => '$error'
      .replaceFirst(RegExp(r'^\w+Exception: '), '')
      .replaceFirst('Bad state: ', '');
}
