import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/utils/native_reference_holder.dart';

import 'support/libmpv_guard.dart';
import 'support/player_page_harness.dart';

File _reference(String owner) => File(
  '${Directory.systemTemp.path}/com.alexmercerind.media_kit.NativeReferenceHolder.$owner',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // These phases must share one process and stay together when tests are sharded.
  testWidgets(
    'stale PID cleanup preserves other PIDs and initialized native buffers',
    (tester) async {
      if (Platform.isWindows) {
        expect(NativeReferenceHolder.initialized, isFalse);
        final current = _reference('$pid');
        final other = _reference('${pid}9999999999');
        addTearDown(() {
          if (other.existsSync()) other.deleteSync();
        });
        current.writeAsStringSync('1');
        other.writeAsStringSync('other process reference');

        clearStaleMediaKitNativeReference();
        expect(current.existsSync(), isFalse);
        expect(other.readAsStringSync(), 'other process reference');
        clearStaleMediaKitNativeReference();
        expect(current.existsSync(), isFalse);
        expect(other.readAsStringSync(), 'other process reference');

        current.writeAsStringSync('1');
        expect(libmpvUnavailableReason, isNull);
        expect(current.existsSync(), isFalse);
      }

      await tester.runAsync(() async {
        expect(libmpvUnavailableReason, isNull, reason: 'Requires real libmpv');
        MediaKit.ensureInitialized(
          libmpv: Platform.environment['WEBHTV_TEST_LIBMPV'],
        );
        final player = Player();
        try {
          final native = player.platform! as NativePlayer;
          expect(await native.handle, isPositive);
          if (Platform.isWindows) {
            expect(NativeReferenceHolder.initialized, isTrue);
            final current = _reference('$pid');
            final address = current.readAsStringSync();
            expect(int.parse(address), isPositive);

            clearStaleMediaKitNativeReference();
            expect(libmpvUnavailableReason, isNull);
            clearStaleMediaKitNativeReference();
            installMediaKitMocks(tester);
            installMediaKitMocks(tester);

            expect(current.readAsStringSync(), address);
          }
          await native.setProperty('volume', '37');
          expect(double.parse(await native.getProperty('volume')), 37);
        } finally {
          await player.dispose();
        }
      });
    },
  );
}
