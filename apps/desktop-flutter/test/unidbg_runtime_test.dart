import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/unidbg_runtime.dart';

/// 与实现内的镜像顺序一致，只用于断言回退次序（测试全程不联网）。
const List<String> _mirrors = <String>[
  'https://maven.aliyun.com/repository/public/',
  'https://mirrors.huaweicloud.com/repository/maven/',
  'https://mirrors.cloud.tencent.com/nexus/repository/maven-public/',
  'https://repo1.maven.org/maven2/',
];

const int _fileCount = 18;

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// 替身锚表：18 个合成文件。
///
/// 真实 pin 的字节内容无法在测试里构造（否则就是把 39MB 塞进仓库），
/// 因此用注入的 pins 覆盖**同一套**校验/回退/幂等逻辑；真实 18 条 pin
/// 只在生产构造里生效。
class _Jars {
  _Jars() {
    for (var index = 0; index < _fileCount; index++) {
      final slug = index.toString().padLeft(2, '0');
      final name = 'fake-lib$slug-1.0.$index.jar';
      final path = 'com/example/lib$slug/1.0.$index/$name';
      final body = utf8.encode('unidbg fake jar #$index');
      bodies[name] = body;
      pins.add(
        UnidbgJarPin(
          path: path,
          fileName: name,
          bytes: body.length,
          sha256: _sha(body),
        ),
      );
    }
  }

  final List<UnidbgJarPin> pins = <UnidbgJarPin>[];
  final Map<String, List<int>> bodies = <String, List<int>>{};
}

http.Client _server(
  _Jars jars, {
  List<String>? requested,
  bool Function(String base, String fileName)? allow,
  Map<String, List<int>>? bodies,
}) {
  final served = bodies ?? jars.bodies;
  return MockClient((request) async {
    final url = request.url.toString();
    requested?.add(url);
    String? base;
    for (final candidate in _mirrors) {
      if (url.startsWith(candidate)) {
        base = candidate;
        break;
      }
    }
    if (base == null) return http.Response('', 404);
    final relative = url.substring(base.length);
    UnidbgJarPin? pin;
    for (final candidate in jars.pins) {
      if (candidate.path == relative) {
        pin = candidate;
        break;
      }
    }
    if (pin == null) return http.Response('', 404);
    if (allow != null && !allow(base, pin.fileName)) {
      return http.Response('', 404);
    }
    final body = served[pin.fileName];
    if (body == null) return http.Response('', 404);
    return http.Response.bytes(body, 200);
  });
}

void main() {
  late Directory tmp;
  late _Jars jars;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('unidbg-runtime-test');
    jars = _Jars();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  UnidbgRuntime runtimeFor(http.Client client) =>
      UnidbgRuntime(client: client, dirProvider: () => tmp, pins: jars.pins);

  test('happy path：18 个 jar 全部下载且校验通过', () async {
    final runtime = runtimeFor(_server(jars));
    final progress = <UnidbgRuntimeProgress>[];
    final result = await runtime.install(onProgress: progress.add);

    expect(result.error, isNull);
    expect(result.installed, isTrue);
    expect(result.dir, p.join(tmp.path, 'runtime', UnidbgRuntime.dirName));
    expect(UnidbgRuntime.version, '0.9.9');
    expect(UnidbgRuntime.dirName, 'unidbg-0.9.9');
    expect(runtime.dir, result.dir);
    expect(runtime.classpathWildcard, endsWith('/*'));
    expect(runtime.classpathWildcard, startsWith(result.dir));

    final jarsOnDisk = Directory(result.dir)
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.jar'))
        .toList();
    expect(jarsOnDisk.length, _fileCount);
    expect(result.bytes, _expectedBytes(jars));
    expect(runtime.isInstalledSync, isTrue);

    expect(progress.length, _fileCount + 1);
    expect(progress.first.fileIndex, 1);
    expect(progress.last.fileIndex, _fileCount);
    expect(progress.last.fileCount, _fileCount);
    expect(progress.last.bytesDone, result.bytes);
    expect(progress.last.bytesTotal, result.bytes);

    final status = await runtime.status(refresh: true);
    expect(status.installed, isTrue);
    expect(status.missing, isEmpty);
    expect(status.bytes, result.bytes);
    expect(status.dir, result.dir);
  });

  test('SHA-256 不符：installed:false、error 非空、不留坏文件', () async {
    final bad = jars.pins[3].fileName;
    final tampered = <String, List<int>>{
      ...jars.bodies,
      bad: utf8.encode('tampered payload'),
    };
    final runtime = runtimeFor(_server(jars, bodies: tampered));
    final result = await runtime.install();

    expect(result.installed, isFalse);
    expect(result.error, isNotNull);
    expect(result.error, isNotEmpty);
    expect(File(p.join(result.dir, bad)).existsSync(), isFalse);
    expect(
      Directory(result.dir)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.part')),
      isEmpty,
    );
    expect(runtime.isInstalledSync, isFalse);
  });

  test('镜像回退：aliyun 404、huaweicloud 命中', () async {
    final requested = <String>[];
    final runtime = runtimeFor(
      _server(
        jars,
        requested: requested,
        allow: (base, fileName) => base == _mirrors[1],
      ),
    );
    final result = await runtime.install();

    expect(result.installed, isTrue);
    expect(requested.first.startsWith(_mirrors[0]), isTrue);
    expect(requested.any((url) => url.startsWith(_mirrors[1])), isTrue);
    // 每个镜像每个文件只试一次：aliyun 恰好 18 次，腾讯云一次都不该碰。
    expect(
      requested.where((url) => url.startsWith(_mirrors[0])).length,
      _fileCount,
    );
    expect(
      requested.where((url) => url.startsWith(_mirrors[2])).length,
      0,
    );
  });

  test('部分文件已存在且校验通过：只补缺失（幂等）', () async {
    final requested = <String>[];
    final runtime = runtimeFor(_server(jars, requested: requested));
    final dir = runtime.dir;
    await Directory(dir).create(recursive: true);
    final keep = jars.pins.take(3).toList();
    for (final pin in keep) {
      await File(
        p.join(dir, pin.fileName),
      ).writeAsBytes(jars.bodies[pin.fileName]!);
    }
    final stale = jars.pins[4];
    await File(p.join(dir, stale.fileName)).writeAsBytes(utf8.encode('stale'));

    final result = await runtime.install();

    expect(result.installed, isTrue);
    expect(requested.length, _fileCount - keep.length);
    for (final pin in keep) {
      expect(requested.any((url) => url.endsWith(pin.fileName)), isFalse);
    }
    expect(requested.any((url) => url.endsWith(stale.fileName)), isTrue);
    expect(await File(p.join(dir, stale.fileName)).length(), stale.bytes);
    expect(runtime.isInstalledSync, isTrue);
  });

  test('remove() 后 isInstalledSync 为 false 且目录消失', () async {
    final runtime = runtimeFor(_server(jars));
    final result = await runtime.install();
    expect(result.installed, isTrue);
    expect(runtime.isInstalledSync, isTrue);

    await runtime.remove();

    expect(runtime.isInstalledSync, isFalse);
    expect(Directory(result.dir).existsSync(), isFalse);
    final status = await runtime.status(refresh: true);
    expect(status.installed, isFalse);
    expect(status.bytes, 0);
    expect(status.missing.length, _fileCount);
  });

  test('全镜像网络失败：install 不抛异常，error 非空', () async {
    final runtime = runtimeFor(
      MockClient((request) async => throw SocketException('offline')),
    );
    final result = await runtime.install();

    expect(result.installed, isFalse);
    expect(result.error, isNotNull);
    expect(result.error, isNotEmpty);
    expect(
      Directory(result.dir)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.jar')),
      isEmpty,
    );
    expect(runtime.isInstalledSync, isFalse);
  });

  test('并发：重复调用返回同一个进行中的 Future', () async {
    final runtime = runtimeFor(_server(jars));
    final first = runtime.install();
    final second = runtime.install();

    expect(identical(first, second), isTrue);
    final result = await first;
    expect(result.installed, isTrue);
    expect(await second, same(result));
  });
}

int _expectedBytes(_Jars jars) =>
    jars.pins.fold<int>(0, (sum, pin) => sum + pin.bytes);
