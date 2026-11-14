import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/speech_search_service.dart';

class FixtureHost implements SpeechRecognitionHost {
  List<String> results = ['首条电影', '第二条'];
  bool unavailable = false;
  String? requestedLanguage;
  Completer<List<String>>? pending;
  @override
  Future<List<String>> recognize({String? language}) async {
    requestedLanguage = language;
    if (unavailable) throw StateError('没有系统识别引擎');
    return pending == null ? results : pending!.future;
  }

  @override
  void cancel() {}
}

void main() {
  test('指定语言传递到真实宿主边界', () async {
    final host = FixtureHost();
    final service = SpeechSearchService(host: host);
    expect(await service.listen(language: 'en-US'), '首条电影');
    expect(host.requestedLanguage, 'en-US');
  });
  test('Windows未安装指定语言时如实失败且不执行语言中的脚本', () async {
    final executable = WindowsSpeechRecognitionHost.defaultExecutable();
    if (!File(executable).existsSync()) {
      markTestSkipped('本机没有 Windows PowerShell');
      return;
    }
    final probe = await Process.run(executable, [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Add-Type -AssemblyName System.Speech; if ([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers().Count -eq 0) { exit 2 }',
    ]);
    if (probe.exitCode != 0) {
      markTestSkipped('本机没有 System.Speech 识别引擎');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('speech-language-');
    final marker = File('${dir.path}/must-not-exist');
    final host = WindowsSpeechRecognitionHost(executable: executable);
    try {
      for (final language in [
        'zz-ZZ',
        "zz-ZZ'; New-Item '${marker.path}'; #",
      ]) {
        await expectLater(
          host.recognize(language: language),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              '真实语言错误',
              contains('语言'),
            ),
          ),
        );
      }
      expect(marker.existsSync(), isFalse);
    } finally {
      host.cancel();
      dir.deleteSync(recursive: true);
    }
  }, skip: !Platform.isWindows);
  test('语音搜索只消费首条，不伪造空结果', () async {
    final host = FixtureHost();
    final service = SpeechSearchService(host: host);
    expect(await service.listen(), '首条电影');
    host.results = [];
    expect(await service.listen(), isNull);
    expect(service.message, contains('未识别'));
  });
  test('引擎不可用公开错误，无搜索文本', () async {
    final service = SpeechSearchService(
      host: FixtureHost()..unavailable = true,
    );
    expect(await service.listen(), isNull);
    expect(service.message, contains('没有系统识别引擎'));
    expect(service.listening, isFalse);
  });
  test('取消后迟到识别结果不可应用', () async {
    final host = FixtureHost()..pending = Completer<List<String>>();
    final service = SpeechSearchService(host: host);
    final result = service.listen();
    service.cancel();
    host.pending!.complete(['过期电影']);
    expect(await result, isNull);
    expect(service.listening, isFalse);
  });
}
