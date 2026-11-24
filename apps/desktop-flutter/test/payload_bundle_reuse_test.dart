/// 加固壳 payload 产物的**共享缓存回收**契约。
///
/// 2026-11-24 真机事故：开站点路径与启动批量预热各自起了一次 DexIntakeCli，
/// 同一份 Douban 产物被转译两遍（17.1 s + 16.7 s），前台首页 elapsed 24.8 s。
/// 修复后的分工必须锁死：
/// - 开站点前只允许**复制已有共享产物**，绝不许再起一次 CLI 转译；
/// - JVM 自己转出来的产物，由 rememberPayloadBundle 收进共享缓存，供同 payload
///   的其余站点复用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/csp_jar_probe.dart';
import 'package:webhtv_pc/services/dex_translate.dart';

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

Directory _writeBundle(Directory siteDir, List<int> payloadBytes) {
  final bundleDir = Directory(p.join(siteDir.path, 'payload-dex', 'dexBundles'))
    ..createSync(recursive: true);
  File(p.join(siteDir.path, 'payload.jar')).writeAsBytesSync(payloadBytes);
  final jar = File(p.join(bundleDir.path, 'classes.jar'))
    ..writeAsBytesSync(List<int>.generate(4096, (i) => i % 251));
  File(p.join(bundleDir.path, 'intake-dex.json')).writeAsStringSync(
    jsonEncode({
      'repairVersion': DexTranslate.repairVersion,
      'classCount': 12,
      'sourceSha256': _sha(payloadBytes),
      'bundleSha256': _sha(jar.readAsBytesSync()),
      'bundle': jar.path,
    }),
  );
  return bundleDir;
}

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-payload-bundle');
  });
  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('共享缓存缺席时不生成转译产物', () {
    final siteDir = Directory(p.join(temp.path, 'csp', 'Douban'))
      ..createSync(recursive: true);
    File(p.join(siteDir.path, 'payload.jar')).writeAsBytesSync([1, 2, 3, 4]);
    final shared = p.join(temp.path, 'probe-cache', 'dex');

    CspJarProbe.preparePayloadDex(siteDir: siteDir.path, sharedDir: shared);

    expect(
      File(p.join(siteDir.path, 'payload-dex', 'dexBundles', 'classes.jar'))
          .existsSync(),
      isFalse,
      reason: '这条路径只允许复制共享产物；起 CLI 会让同一 payload 被写两遍',
    );
    expect(Directory(shared).existsSync(), isFalse);
  });

  test('JVM 产物回收进共享缓存后，下一站只做复制即可命中', () {
    final sourceSite = Directory(p.join(temp.path, 'csp', 'Douban'))
      ..createSync(recursive: true);
    _writeBundle(sourceSite, [9, 8, 7]);
    final shared = p.join(temp.path, 'probe-cache', 'dex');

    CspJarProbe.rememberPayloadBundle(sourceSite.path, sharedDir: shared);
    expect(
      DexTranslate.recordUsable(
        p.join(shared, _sha([9, 8, 7]), 'intake-dex.json'),
      ),
      isTrue,
      reason: 'JVM 转好的产物必须能被别的站点复用',
    );

    final otherSite = Directory(p.join(temp.path, 'csp', 'csp~other'))
      ..createSync(recursive: true);
    File(p.join(otherSite.path, 'payload.jar')).writeAsBytesSync([9, 8, 7]);
    CspJarProbe.preparePayloadDex(siteDir: otherSite.path, sharedDir: shared);

    expect(
      File(p.join(otherSite.path, 'payload-dex', 'dexBundles', 'classes.jar'))
          .existsSync(),
      isTrue,
      reason: '同 payload 的第二个站点应当只复制共享产物（毫秒级），不再转译',
    );
  });

  for (final scenario in ['stale-source', 'missing-bundle', 'corrupt-bundle']) {
    test('共享缓存修复无效本地产物：$scenario', () {
      const payloadBytes = [9, 8, 7];
      final sourceSite = Directory(p.join(temp.path, 'csp', 'source'))
        ..createSync(recursive: true);
      final sourceBundle = _writeBundle(sourceSite, payloadBytes);
      final shared = p.join(temp.path, 'probe-cache', 'dex');
      CspJarProbe.rememberPayloadBundle(sourceSite.path, sharedDir: shared);

      final targetSite = Directory(p.join(temp.path, 'csp', 'target'))
        ..createSync(recursive: true);
      final targetBundle = _writeBundle(
        targetSite,
        scenario == 'stale-source' ? [1, 2, 3] : payloadBytes,
      );
      final targetJar = File(p.join(targetBundle.path, 'classes.jar'));
      if (scenario == 'stale-source') {
        File(p.join(targetSite.path, 'payload.jar'))
            .writeAsBytesSync(payloadBytes);
      } else if (scenario == 'missing-bundle') {
        targetJar.deleteSync();
      } else {
        targetJar.writeAsBytesSync([0]);
      }

      CspJarProbe.preparePayloadDex(
        siteDir: targetSite.path,
        sharedDir: shared,
      );

      expect(targetJar.existsSync(), isTrue);
      expect(
        targetJar.readAsBytesSync(),
        File(p.join(sourceBundle.path, 'classes.jar')).readAsBytesSync(),
      );
      final record = jsonDecode(
        File(p.join(targetBundle.path, 'intake-dex.json')).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(record['sourceSha256'], _sha(payloadBytes));
      expect(record['bundleSha256'], _sha(targetJar.readAsBytesSync()));
    });
  }
}
