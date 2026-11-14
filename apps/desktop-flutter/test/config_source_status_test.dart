import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/config_source_status.dart';
import 'package:webhtv_pc/services/storage.dart';

ConfigRecord record(String origin, {String contentType = ''}) => ConfigRecord(
  id: 7,
  name: '本地来源',
  origin: origin,
  updatedAt: DateTime.utc(2026, 1, 1),
  siteCount: 0,
  liveCount: 0,
  contentType: contentType,
);

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('source-status-');
  });
  tearDown(() async => root.delete(recursive: true));

  test('missing file retains record identity and needs attention', () async {
    final status = await inspectConfigSource(record('${root.path}/gone.json'));
    expect(status.recordId, 7);
    expect(status.name, '本地来源');
    expect(status.availability, ConfigSourceAvailability.missing);
    expect(status.needsAttention, isTrue);
    expect(status.path, '${root.path}/gone.json');
  });

  test(
    'existing path and file URI are available without changing file',
    () async {
      final file = File('${root.path}/source config.json');
      await file.writeAsString('{}');
      for (final origin in [file.path, file.uri.toString()]) {
        final status = await inspectConfigSource(record(origin));
        expect(status.availability, ConfigSourceAvailability.available);
        expect(status.path, file.path);
        expect(status.needsAttention, isFalse);
      }
      expect(await file.readAsString(), '{}');
    },
  );

  test('non-file sources never perform filesystem or network IO', () async {
    await HttpOverrides.runZoned(
      () => IOOverrides.runZoned(() async {
        for (final origin in [
          'http://127.0.0.1:1/offline.json',
          'https://example.invalid/config.json',
          'inline://json',
          '{"sites":[]}',
          'http://127.0.0.1:1/bridge',
          if (!Platform.isWindows) r'C:\Users\someone\config.json',
          if (!Platform.isWindows) 'file:///C:/Users/someone/config.json',
        ]) {
          final status = await inspectConfigSource(record(origin));
          expect(status.availability, ConfigSourceAvailability.notLocal);
          expect(status.needsAttention, isFalse);
          expect(status.path, isNull);
        }
      }, createFile: (_) => throw StateError('unexpected filesystem IO')),
      createHttpClient: (_) => throw StateError('unexpected network IO'),
    );
  });

  test('filesystem access failure is unreadable, not missing', () async {
    if (Platform.isWindows) return;
    final link = Link('${root.path}/loop.json');
    await link.create(link.path);
    final status = await inspectConfigSource(record(link.path));
    expect(status.availability, ConfigSourceAvailability.unreadable);
    expect(status.needsAttention, isTrue);
  });

  test('directory cannot be used as an available source file', () async {
    final status = await inspectConfigSource(record(root.path));
    expect(status.availability, ConfigSourceAvailability.unreadable);
    expect(status.needsAttention, isTrue);
  });
}
