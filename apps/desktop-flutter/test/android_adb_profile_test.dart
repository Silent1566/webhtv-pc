import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_adb_profile.dart';

void main() {
  test(
    'network descriptor normalizes endpoint and survives literal v1 metadata',
    () {
      final profile = AndroidAdbProfile.fromJson({
        'version': 1,
        'mode': 'network',
        'target': ' 192.168.50.3 ',
        'adbPath': '/sdk/platform-tools/adb',
        'gatewayPort': 9990,
      });
      expect(profile, isNotNull);
      expect(profile!.target, '192.168.50.3:5555');
      expect(profile.gatewayPort, 9990);
      expect(profile.toJson(), {
        'version': 1,
        'mode': 'network',
        'target': '192.168.50.3:5555',
        'adbPath': '/sdk/platform-tools/adb',
        'emulatorPath': '',
        'avdHome': '',
        'serverPort': 5037,
        'gatewayPort': 9990,
      });
    },
  );

  test(
    'device descriptor keeps explicit serial and borrowed server identity',
    () {
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'emulator-5558',
        adbPath: '/sdk/adb',
        serverPort: 5044,
      );
      final restored = AndroidAdbProfile.fromJson(profile.toJson())!;
      expect(restored.target, 'emulator-5558');
      expect(restored.mode, AndroidAdbMode.device);
      expect(restored.serverPort, 5044);
    },
  );

  test('AVD description preserves existing SDK executable and AVD home', () {
    final profile = AndroidAdbProfile.fromJson({
      'version': 1,
      'mode': 'avd',
      'target': 'Pixel_9_API_34',
      'adbPath': r'C:\Android\platform-tools\adb.exe',
      'emulatorPath': r'C:\Android\emulator\emulator.exe',
      'avdHome': r'C:\Users\viewer\.android\avd',
    })!;
    expect(profile.mode, AndroidAdbMode.avd);
    expect(profile.target, 'Pixel_9_API_34');
    expect(profile.avdHome, r'C:\Users\viewer\.android\avd');
    expect(profile.emulatorPath, r'C:\Android\emulator\emulator.exe');
  });

  test(
    'descriptor rejects ambiguous URLs credentials controls and invalid ports',
    () {
      for (final target in [
        '',
        'http://192.168.50.3:9978',
        'user:secret@host:5555',
        'host:5555/path',
        'host:5555?token=secret',
        '-s attacker',
        'host:0',
        'host:0000',
        '[::1]:0',
        'host:',
        'host:65536',
        'host\nsecond',
      ]) {
        expect(
          () => AndroidAdbProfile(mode: AndroidAdbMode.network, target: target),
          throwsFormatException,
          reason: target,
        );
      }
      expect(
        () => AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'serial',
          serverPort: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => AndroidAdbProfile(
          mode: AndroidAdbMode.avd,
          target: 'Pixel',
          gatewayPort: 65536,
        ),
        throwsFormatException,
      );
      expect(
        () => AndroidAdbProfile(
          mode: AndroidAdbMode.network,
          target: 'host',
          adbPath: 'https://example.test/adb',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'future or malformed profile metadata cannot become a live connection',
    () {
      for (final value in [
        null,
        'text',
        {},
        {'version': 2, 'mode': 'network', 'target': 'host'},
        {'version': 1, 'mode': 'unknown', 'target': 'host'},
        {
          'version': 1,
          'mode': 'network',
          'target': 'host',
          'gatewayPort': 'bad',
        },
      ]) {
        expect(AndroidAdbProfile.fromJson(value), isNull);
      }
    },
  );

  test('connection key merges equivalent endpoints but separates different tools and ports', () {
    final first = AndroidAdbProfile(
      mode: AndroidAdbMode.network,
      target: 'host',
    );
    final same = AndroidAdbProfile(
      mode: AndroidAdbMode.network,
      target: 'host:5555',
    );
    expect(first.connectionKey, same.connectionKey);
    expect(
      first.connectionKey,
      isNot(
        AndroidAdbProfile(
          mode: AndroidAdbMode.network,
          target: 'host:5556',
        ).connectionKey,
      ),
    );
    expect(
      first.connectionKey,
      isNot(
        AndroidAdbProfile(
          mode: AndroidAdbMode.network,
          target: 'host',
          adbPath: '/other/adb',
        ).connectionKey,
      ),
    );
  });

  test(
    'network profile accepts bracketed IPv6 without losing the explicit port',
    () {
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.network,
        target: '[::1]:5556',
      );
      expect(profile.target, '[::1]:5556');
      expect(
        AndroidAdbProfile(mode: AndroidAdbMode.network, target: '[::1]').target,
        '[::1]:5555',
      );
    },
  );
}
