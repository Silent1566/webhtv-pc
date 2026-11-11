import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  late Directory temp;
  late AppState state;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'webhtv-startup-architecture-',
    );
    state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': p.join(temp.path, 'config'),
          'data': p.join(temp.path, 'data'),
          'cache': p.join(temp.path, 'cache'),
          'state': p.join(temp.path, 'logs'),
        },
      ),
      log: LogService(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    LogService.logDirectoryOverride = null;
    await temp.delete(recursive: true);
  });

  test(
    'Linux startup reports the current CPU ABI instead of the Dart version',
    () {
      final expected = {
        Abi.linuxX64: 'x64',
        Abi.linuxArm64: 'arm64',
        Abi.linuxArm: 'arm',
        Abi.linuxIA32: 'x86',
        Abi.linuxRiscv32: 'riscv32',
        Abi.linuxRiscv64: 'riscv64',
      }[Abi.current()];
      expect(expected, isNotNull);
      final info = state.startupInfo!;
      expect(info.platform, 'linux');
      expect(info.architecture, expected);
      expect(info.architecture, isNot(Platform.version.split(' ').first));
      expect(info.dartVersion, Platform.version);
      expect(info.oneLine, contains('platform=linux arch=$expected '));
    },
    skip: !Platform.isLinux,
  );

  test('Windows startup preserves PROCESSOR_ARCHITECTURE normalization', () {
    final env = Platform.environment['PROCESSOR_ARCHITECTURE'];
    final expected = env == null || env.isEmpty
        ? 'x64'
        : {'amd64': 'x64', 'arm64': 'arm64', 'x86': 'x86'}[env.toLowerCase()] ??
              env.toLowerCase();
    expect(state.startupInfo!.platform, 'windows');
    expect(state.startupInfo!.architecture, expected);
  }, skip: !Platform.isWindows);
}
