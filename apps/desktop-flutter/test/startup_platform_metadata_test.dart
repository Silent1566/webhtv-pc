import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

/// 启动诊断的平台/架构必须来自运行时，而不是写死的文案或 Dart 版本串。
/// 无回归时会出现的两个现场错误：Linux 上显示 `MVP-A (Windows)`，
/// 以及 `arch` 取到 Dart 版本号（如 3.13.4）。
void main() {
  test('启动 flavor 随运行时平台变化', () {
    final label = switch (Platform.operatingSystem) {
      'windows' => 'Windows',
      'linux' => 'Linux',
      'macos' => 'macOS',
      final other => other,
    };
    expect(appBuildFlavor, 'MVP-A ($label)');
  });

  test('启动 architecture 取自 ABI，不是 Dart 版本串', () async {
    final temp = Directory.systemTemp.createTempSync('webhtv-startup-metadata');
    final state = AppState(
      paths: AppPaths.resolve(
        overrides: {
          'config': temp.path,
          'data': temp.path,
          'cache': temp.path,
          'state': temp.path,
        },
      ),
      log: LogService(),
    );
    addTearDown(() {
      state.dispose();
      temp.deleteSync(recursive: true);
    });

    await state.bootstrap();

    final expected = switch (Abi.current()) {
      Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => Platform.isWindows
          ? _windowsArchitecture()
          : 'x64',
      Abi.linuxArm64 || Abi.macosArm64 || Abi.windowsArm64 => 'arm64',
      _ => 'unknown',
    };
    final info = state.startupInfo!;
    expect(info.architecture, expected);
    expect(info.architecture, isNot(contains('.')));
    expect(info.platform, Platform.operatingSystem);
  });
}

String _windowsArchitecture() {
  final env = Platform.environment['PROCESSOR_ARCHITECTURE']?.toLowerCase();
  return switch (env) {
    null || '' || 'amd64' => 'x64',
    final value => value,
  };
}
