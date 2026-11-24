/// 共享 dex 产物缓存的准入条件：口径版本、类数、两个 SHA 都得对。
///
/// 这里守的是一个真实事故面：旧口径的 classes.jar 文件完好、SHA 也自洽，
/// 只因为「文件存在」被复用，新修复永远跑不到真实 payload 上。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/dex_translate.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('webhtv-dex-shared');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  final sha = 'a' * 64;
  final bundleSha = crypto.sha256.convert(const [0x50, 0x4b, 3, 4]).toString();

  Map<String, Object?> record({
    int classCount = 1227,
    bool withVersion = true,
    bool withSourceSha = true,
    bool withBundleSha = true,
  }) => <String, Object?>{
    if (withVersion) 'repairVersion': DexTranslate.repairVersion,
    'classCount': classCount,
    if (withSourceSha) 'sourceSha256': sha,
    if (withBundleSha) 'bundleSha256': bundleSha,
  };

  /// 在共享缓存里放一份「payload sha → 产物」；[recordJson] 直接写原文，用来造畸形记录。
  String seed({
    Map<String, Object?>? data,
    String? recordJson,
    bool withJar = true,
  }) {
    final dir = Directory(p.join(root.path, sha))..createSync(recursive: true);
    if (withJar) {
      File(p.join(dir.path, 'classes.jar'))
          .writeAsBytesSync(const [0x50, 0x4b, 3, 4]);
    }
    File(p.join(dir.path, 'intake-dex.json')).writeAsStringSync(
      recordJson ?? jsonEncode(data ?? record()),
      flush: true,
    );
    return root.path;
  }

  Directory site(String name) =>
      Directory(p.join(root.path, name))..createSync(recursive: true);

  test('当前口径的共享产物被复用，且记录里的 bundle 改写成站点路径', () {
    final shared = seed();
    final target = site('site-a');
    final reused = DexTranslate.copySharedBundle(
      sharedDir: shared,
      sha: sha,
      siteDir: target.path,
    );

    expect(reused, isNotNull);
    expect(reused!['cached'], isTrue);
    expect(reused['repairVersion'], DexTranslate.repairVersion);
    final jar = p.join(target.path, 'dexBundles', 'classes.jar');
    expect(File(jar).existsSync(), isTrue);
    expect(reused['bundle'], jar);
    final written = jsonDecode(
      File(p.join(target.path, 'dexBundles', 'intake-dex.json'))
          .readAsStringSync(),
    ) as Map<String, Object?>;
    expect(written['bundle'], jar);
    expect(written['cached'], isTrue);
  });

  test('同一份 payload 跨站点共享：两个站点都能复用同一份产物', () {
    final shared = seed();
    for (final name in const ['site-a', 'site-b']) {
      final reused = DexTranslate.copySharedBundle(
        sharedDir: shared,
        sha: sha,
        siteDir: site(name).path,
      );
      expect(reused, isNotNull, reason: name);
    }
  });

  test('旧修复口径（无当前 repairVersion）的共享产物不被复用，也不被删除', () {
    final shared = seed(data: record(withVersion: false));
    final target = site('site-a');

    expect(
      DexTranslate.copySharedBundle(
        sharedDir: shared,
        sha: sha,
        siteDir: target.path,
      ),
      isNull,
    );
    expect(
      File(p.join(target.path, 'dexBundles', 'classes.jar')).existsSync(),
      isFalse,
      reason: '不合格产物不能落到站点目录',
    );
    expect(
      File(p.join(shared, sha, 'classes.jar')).existsSync(),
      isTrue,
      reason: '缓存准入是跳过，不是删用户缓存',
    );
  });

  for (final version in [4, 5]) {
    test('v$version 共享产物必须重新转译，原始缓存文件和记录保留', () {
      final old = record()..['repairVersion'] = version;
      final shared = seed(data: old);
      final originalJar = File(p.join(shared, sha, 'classes.jar'));
      final originalRecord = File(p.join(shared, sha, 'intake-dex.json'));
      final jarBytes = originalJar.readAsBytesSync();
      final recordText = originalRecord.readAsStringSync();
      final target = site('site-v$version');

      expect(DexTranslate.recordUsable(originalRecord.path), isFalse);
      expect(
        DexTranslate.copySharedBundle(
          sharedDir: shared,
          sha: sha,
          siteDir: target.path,
        ),
        isNull,
      );
      expect(
        File(p.join(target.path, 'dexBundles', 'classes.jar')).existsSync(),
        isFalse,
      );
      expect(originalJar.readAsBytesSync(), jarBytes);
      expect(originalRecord.readAsStringSync(), recordText);
    });
  }

  test('缺失 repairVersion / 类数为 0 / 缺 SHA / 畸形 JSON 都不被复用', () {
    final cases = <String, String>{
      'no-version': jsonEncode(record(withVersion: false)),
      'zero-classes': jsonEncode(record(classCount: 0)),
      'no-source-sha': jsonEncode(record(withSourceSha: false)),
      'no-bundle-sha': jsonEncode(record(withBundleSha: false)),
      'malformed': '{not json',
      'not-object': '[1,2,3]',
    };
    var index = 0;
    for (final entry in cases.entries) {
      final shared = seed(recordJson: entry.value);
      final target = site('site-${index++}');
      expect(
        DexTranslate.copySharedBundle(
          sharedDir: shared,
          sha: sha,
          siteDir: target.path,
        ),
        isNull,
        reason: entry.key,
      );
    }
  });

  test('产物文件缺失时即使记录合格也不复用', () {
    final shared = seed(withJar: false);
    expect(
      DexTranslate.copySharedBundle(
        sharedDir: shared,
        sha: sha,
        siteDir: site('site-a').path,
      ),
      isNull,
    );
  });

  test('recordUsable 只看口径与自洽性，不看文件是否存在', () {
    final good = File(p.join(seed(), sha, 'intake-dex.json')).path;
    expect(DexTranslate.recordUsable(good), isTrue);
    expect(
      DexTranslate.recordUsable(p.join(root.path, 'missing.json')),
      isFalse,
    );
    expect(DexTranslate.repairVersion, 6);
  });

  test('shared record must belong to requested source SHA', () {
    final shared = seed(data: {...record(), 'sourceSha256': 'c' * 64});
    expect(
      DexTranslate.copySharedBundle(
        sharedDir: shared,
        sha: sha,
        siteDir: site('mismatch').path,
      ),
      isNull,
    );
  });

  test('shared bundle hash must match actual bytes', () {
    final shared = seed();
    File(p.join(shared, sha, 'classes.jar')).writeAsBytesSync([9]);
    expect(
      DexTranslate.copySharedBundle(
        sharedDir: shared,
        sha: sha,
        siteDir: site('corrupt').path,
      ),
      isNull,
    );
  });
}
