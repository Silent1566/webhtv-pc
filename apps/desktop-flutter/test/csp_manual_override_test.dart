import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/jar_intake.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/spider_registry.dart';
import 'package:webhtv_pc/state/app_state.dart';

class _NoHomeState extends AppState {
  _NoHomeState(AppPaths paths)
    : super(
        paths: paths,
        log: LogService(),
        httpClient: MockClient((request) async => http.Response('', 404)),
      );
  @override
  Future<void> loadHome(Site site) async {}
}

void main() {
  test('manual import overrides an automatic cache without deleting its source record', () async {
    final temp = Directory.systemTemp.createTempSync('csp-manual-override-');
    final state = _NoHomeState(
      AppPaths.resolve(
        overrides: {
          'config': temp.path,
          'data': temp.path,
          'cache': p.join(temp.path, 'cache'),
          'state': p.join(temp.path, 'logs'),
        },
      ),
    );
    state.debugCspProbeOverride = (_) async => const CspProbeReport();
    try {
      final base = CspJvmBinding(root: p.join(temp.path, 'spiders', 'csp'));
      final legacy = base.directoryFor('Douban');
      Directory(legacy).createSync(recursive: true);
      final archive = Archive()
        ..addFile(ArchiveFile('com/github/catvod/spider/Douban.class', 1, [1]));
      final bytes = ZipEncoder().encode(archive);
      File(p.join(legacy, 'index.jar')).writeAsBytesSync(bytes);
      final oldRecord = {
        'siteKey': 'Douban',
        'sourceUrl': 'https://old.test/spider.jar',
        'installed': true,
        'verdict': 'desktopReady',
      };
      File(p.join(legacy, 'probe.json'))
          .writeAsStringSync(jsonEncode(oldRecord));
      final config = jsonEncode({
        'spider': 'https://new.test/spider.jar',
        'sites': [
          {'key': 'Douban', 'name': 'Douban', 'type': 3, 'api': 'csp_Douban'},
        ],
      });
      expect(await state.importConfig(config), isTrue);
      expect(state.cspDirectoryFor('Douban'), isNot(legacy));
      final manual = File(p.join(temp.path, 'manual.jar'))
        ..writeAsBytesSync(bytes);
      final result = await state.importCspJar(
        siteKey: 'Douban',
        sourcePath: manual.path,
      );
      expect(result.ok, isTrue);
      expect(
        state.cspDirectoryFor('Douban'),
        legacy,
        reason: 'explicit manual import must supersede the old source identity',
      );
      expect(JarIntake.intakeRecord(legacy)?['manualOverride'], isTrue);
      expect(
        JarIntake.probeRecord(legacy)?['sourceUrl'],
        'https://old.test/spider.jar',
      );
    } finally {
      state.dispose();
      await Future<void>.delayed(Duration.zero);
      temp.deleteSync(recursive: true);
    }
  });
}
