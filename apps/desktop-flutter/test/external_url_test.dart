import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/external_url.dart';

void main() {
  group('ExternalUrl.open（04 §7.2）', () {
    const url = 'https://www.youtube.com/watch?v=abc123';
    const commands = {
      'windows': 'explorer.exe',
      'linux': 'xdg-open',
      'macos': '/usr/bin/open',
    };

    for (final entry in commands.entries) {
      test('${entry.key} passes URL as one process argument', () async {
        String? executable;
        List<String>? arguments;
        final process = _FakeProcess();
        const target = 'https://example.com/watch?v=abc&name=a%20b';
        final result = await ExternalUrl.open(
          target,
          operatingSystem: entry.key,
          starter: (exe, args) async {
            executable = exe;
            arguments = args;
            return process;
          },
        );
        expect(result.ok, isTrue);
        expect(executable, entry.value);
        expect(arguments, [target]);
        if (entry.key == 'windows') {
          expect(process.exitRead, isFalse);
          expect(process.stdoutListened, isFalse);
          expect(process.stderrListened, isFalse);
        }
      });

      test('${entry.key} reports failure to start', () async {
        final result = await ExternalUrl.open(
          url,
          operatingSystem: entry.key,
          starter: (_, _) async => throw ProcessException(entry.value, []),
        );
        expect(result.ok, isFalse);
        expect(result.error, isNotEmpty);
      });
    }

    for (final os in ['linux', 'macos']) {
      test('$os nonzero opener exit returns failure', () async {
        final result = await ExternalUrl.open(
          url,
          operatingSystem: os,
          starter: (_, _) async => _FakeProcess(exitCode: Future.value(3)),
        );
        expect(result.ok, isFalse);
        expect(result.error, contains('3'));
      });

      test('$os waits for OS handoff and drains attached streams', () async {
        final exit = Completer<int>();
        final process = _FakeProcess(exitCode: exit.future);
        var completed = false;
        final opening =
            ExternalUrl.open(
              url,
              operatingSystem: os,
              starter: (_, _) async => process,
            ).then((result) {
              completed = true;
              return result;
            });
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        expect(process.stdoutListened, isTrue);
        expect(process.stderrListened, isTrue);
        exit.complete(0);
        expect((await opening).ok, isTrue);
        expect(process.stdoutCancelled, isTrue);
        expect(process.stderrCancelled, isTrue);
      });

      test(
        '$os stalled opener fails within six seconds and is killed',
        () async {
          final process = _FakeProcess(exitCode: Completer<int>().future);
          final watch = Stopwatch()..start();
          final result = await ExternalUrl.open(
            url,
            operatingSystem: os,
            starter: (_, _) async => process,
          ).timeout(const Duration(seconds: 6));
          expect(result.ok, isFalse);
          expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
          expect(process.killed, isTrue);
          expect(process.stdoutCancelled, isTrue);
          expect(process.stderrCancelled, isTrue);
        },
      );
    }

    for (final target in [
      '',
      'file:///etc/passwd',
      'javascript:alert(1)',
      'https://',
      'http:///missing-host',
      'https://?v=abc',
      'https://exa mple.com',
      'https://example.com/watch\nv=abc',
      'https://example.com/%zz',
      'https://[broken',
      'https://example.com:bad',
      'https://example.com:65536',
    ]) {
      test(
        'rejects malformed/non-http URL ${target.replaceAll('\n', r'\n')}',
        () async {
          var started = 0;
          final result = await ExternalUrl.open(
            target,
            operatingSystem: 'linux',
            starter: (_, _) async {
              started++;
              return _FakeProcess();
            },
          );
          expect(result.ok, isFalse);
          expect(started, 0);
        },
      );
    }

    test(
      'accepts uppercase HTTP scheme and trims surrounding whitespace',
      () async {
        List<String>? arguments;
        final result = await ExternalUrl.open(
          '  HTTPS://example.com/watch?v=abc  ',
          operatingSystem: 'windows',
          starter: (_, args) async {
            arguments = args;
            return _FakeProcess();
          },
        );
        expect(result.ok, isTrue);
        expect(arguments, ['HTTPS://example.com/watch?v=abc']);
      },
    );

    test('omitted platform uses the host OS command', () async {
      String? executable;
      final result = await ExternalUrl.open(
        url,
        starter: (exe, _) async {
          executable = exe;
          return _FakeProcess();
        },
      );
      expect(result.ok, commands.containsKey(Platform.operatingSystem));
      expect(executable, commands[Platform.operatingSystem]);
    });

    test('unsupported platform rejects without starting a process', () async {
      var started = 0;
      final result = await ExternalUrl.open(
        url,
        operatingSystem: 'android',
        starter: (_, _) async {
          started++;
          return _FakeProcess();
        },
      );
      expect(result.ok, isFalse);
      expect(started, 0);
    });

    test(
      'attached real subprocess can fill both streams and still exit',
      () async {
        final result = await ExternalUrl.open(
          url,
          operatingSystem: Platform.operatingSystem,
          starter: (_, _) => Process.start('/bin/sh', [
            '-c',
            'head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2; exit 0',
          ]),
        );
        expect(result.ok, isTrue);
      },
      skip: Platform.isWindows,
    );
  });
}

class _FakeProcess implements Process {
  _FakeProcess({Future<int>? exitCode})
    : _exitCode = exitCode ?? Future.value(0) {
    _stdout = StreamController<List<int>>(
      onListen: () => stdoutListened = true,
      onCancel: () => stdoutCancelled = true,
    );
    _stderr = StreamController<List<int>>(
      onListen: () => stderrListened = true,
      onCancel: () => stderrCancelled = true,
    );
  }

  final Future<int> _exitCode;
  late final StreamController<List<int>> _stdout;
  late final StreamController<List<int>> _stderr;
  bool exitRead = false;
  bool stdoutListened = false;
  bool stderrListened = false;
  bool stdoutCancelled = false;
  bool stderrCancelled = false;
  bool killed = false;

  @override
  Future<int> get exitCode {
    exitRead = true;
    return _exitCode;
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
