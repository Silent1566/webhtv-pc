import 'dart:ffi';
import 'dart:io';

import 'package:webhtv_pc/services/karaoke/windows_mic_source.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('provide the MSVC-built DLL path');
  final library = DynamicLibrary.open(File(args.single).absolute.path);
  for (final name in [
    'kmic_available',
    'kmic_start',
    'kmic_read',
    'kmic_mix_sample_rate',
    'kmic_stop',
    'kmic_last_error',
  ]) {
    if (library.lookup<Void>(name) == nullptr)
      throw StateError('missing $name');
  }
  final available = library.lookupFunction<Int32 Function(), int Function()>(
    'kmic_available',
  )();
  stdout.writeln(
    'PASS: DLL loaded, six ABI symbols resolved; capture endpoint available=$available',
  );
  final source = WindowsKaraokeMicSource();
  if (source.isAvailable != (available == 1)) {
    throw StateError('production FFI availability differs');
  }
  await source.dispose();
  stdout.writeln('PASS: production lazy FFI adapter resolves actual DLL ABI');
  stdout.writeln(
    'NO kmic_start/read calls; real microphone recording/listening NOT TESTED',
  );
}
