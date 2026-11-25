import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/spider_registry.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('csp-callback-'));
  tearDown(() => temp.deleteSync(recursive: true));
  AppConfig config() => AppConfig(
    spider: 'https://fixture.test/spider.jar',
    sites: [Site(key: 'Demo', name: 'Demo', type: 3, api: 'csp_Demo')],
  );
  List<int> jar({bool dex = false}) => ZipEncoder().encode(
    Archive()..addFile(
      dex
          ? ArchiveFile('classes.dex', 8, [100, 101, 120, 10, 48, 51, 53, 0])
          : ArchiveFile('com/github/catvod/spider/Demo.class', 1, [1]),
    ),
  );

  test(
    'an entry observer failure does not change a successful installation',
    () async {
      var calls = 0;
      final probe = CspJarProbe(
        root: temp.path,
        binding: CspJvmBinding(root: p.join(temp.path, 'csp')),
        client: MockClient((request) async => http.Response.bytes(jar(), 200)),
      );
      final report = await probe.materialize(
        config(),
        onEntry: (entry) {
          calls++;
          throw StateError('observer failure');
        },
      );
      expect(report.installed, 1);
      expect(report.failed, 0);
      expect(calls, 1);
    },
  );

  test(
    'ordinary dex preparation reports actual download and translation stages',
    () async {
      final stages = <String>[];
      String? stageAtTranslation;
      final probe = CspJarProbe(
        root: temp.path,
        binding: CspJvmBinding(root: p.join(temp.path, 'csp')),
        client: MockClient(
          (request) async => http.Response.bytes(jar(dex: true), 200),
        ),
        dexTranslate: ({required siteDir, required archive}) async {
          stageAtTranslation = stages.last;
          return <String, Object?>{
            'ok': true,
            'classCount': 1,
            'cached': false,
          };
        },
      );
      final report = await probe.materialize(
        config(),
        onProgress: (tick) => stages.add(tick.stage),
      );
      expect(report.installed, 1);
      expect(stages, contains('下载站源'));
      expect(stages, contains('检查站源'));
      expect(stages, contains('转译 Android 站源'));
      expect(stageAtTranslation, '转译 Android 站源');
    },
  );
}
