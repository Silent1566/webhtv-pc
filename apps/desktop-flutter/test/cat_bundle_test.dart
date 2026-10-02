/// 猫源 bundle 下载/校验/缓存门禁测试（§9.7、§9.8）。
///
/// 只覆盖不依赖 Node 与公网的部分：地址推导、目录指纹、本地目录/zip 安装、
/// 远端 md5 校验与缓存命中。真实 Node 启动走集成测试（`-d windows`）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/cat_bundle.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('catbundle_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('地址推导', () {
    test('bundleUrl 去掉 .md5 后缀（大小写不敏感）', () {
      expect(
        CatBundle.bundleUrl('http://h/a/index.js.md5'),
        'http://h/a/index.js',
      );
      expect(CatBundle.bundleUrl('http://h/a/index.js'), 'http://h/a/index.js');
      expect(
        CatBundle.bundleUrl('http://h/a/index.js.MD5'),
        'http://h/a/index.js',
      );
    });

    test('md5Url 补 .md5 后缀且不重复补', () {
      expect(CatBundle.md5Url('http://h/a/index.js'), 'http://h/a/index.js.md5');
      expect(
        CatBundle.md5Url('http://h/a/index.js.md5'),
        'http://h/a/index.js.md5',
      );
    });

    test('configUrl 指向同目录 index.config.js', () {
      expect(
        CatBundle.configUrl('http://h/a/index.js.md5'),
        'http://h/a/index.config.js',
      );
      expect(
        CatBundle.configMd5Url('http://h/a/index.js.md5'),
        'http://h/a/index.config.js.md5',
      );
    });

    test('isMd5 只认 32 位十六进制', () {
      expect(CatBundle.isMd5('a' * 32), isTrue);
      expect(CatBundle.isMd5('907d54191dadc9043495a22a9a76b841'), isTrue);
      expect(CatBundle.isMd5('a' * 31), isFalse);
      expect(CatBundle.isMd5('z' * 32), isFalse);
      expect(CatBundle.isMd5(null), isFalse);
    });
  });

  group('本地目录包', () {
    test('含 index.js + index.config.js 的目录可安装并生成缓存标记', () async {
      final source = Directory(p.join(root.path, 'pkg'))..createSync();
      File(p.join(source.path, 'index.js')).writeAsStringSync('module.exports={start(){}}');
      File(p.join(source.path, 'index.config.js')).writeAsStringSync('module.exports={}');

      final bundle = CatBundle(rootDir: p.join(root.path, 'cache'));
      final result = await bundle.ensure(source.path);
      bundle.close();

      expect(result.ok, isTrue, reason: result.error);
      expect(File(result.entryPath).existsSync(), isTrue);
      expect(File(result.configPath).existsSync(), isTrue);
      // source.key 记录本地指纹（local:<bundleMd5>:<configMd5>）。
      final key = File(p.join(result.bundleDir, CatBundle.sourceStamp)).readAsStringSync();
      expect(key.startsWith('local:'), isTrue);
      final expected = md5.convert(utf8.encode('module.exports={start(){}}')).toString();
      expect(key.contains(expected), isTrue);
    });

    test('缺少 index.config.js 明确报错', () async {
      final source = Directory(p.join(root.path, 'pkg2'))..createSync();
      File(p.join(source.path, 'index.js')).writeAsStringSync('x');
      final bundle = CatBundle(rootDir: p.join(root.path, 'cache'));
      final result = await bundle.ensure(source.path);
      bundle.close();
      expect(result.ok, isFalse);
      expect(result.error, contains('index.config.js'));
    });

    test('本地目录内容变化后重新 ensure 会反映新内容', () async {
      // 本地目录是用户可写包：内容改了就要重装，marker 不会跟着更新。
      final source = Directory(p.join(root.path, 'pkg3'))..createSync();
      File(p.join(source.path, 'index.js')).writeAsStringSync('A');
      File(p.join(source.path, 'index.config.js')).writeAsStringSync('B');
      final bundle = CatBundle(rootDir: p.join(root.path, 'cache'));

      final first = await bundle.ensure(source.path);
      expect(File(first.entryPath).readAsStringSync(), 'A');

      File(p.join(source.path, 'index.js')).writeAsStringSync('A2');
      final second = await bundle.ensure(source.path);
      bundle.close();

      expect(second.ok, isTrue);
      expect(File(second.entryPath).readAsStringSync(), 'A2');
    });
  });

  group('dirFor 稳定指纹', () {
    test('同一地址得到同一目录，不同地址不同目录', () {
      final bundle = CatBundle(rootDir: root.path);
      final a = bundle.dirFor('http://h/a/index.js.md5');
      final b = bundle.dirFor('http://h/a/index.js');
      final c = bundle.dirFor('http://h/b/index.js.md5');
      bundle.close();
      expect(a, b); // .md5 后缀不影响身份
      expect(a, isNot(c));
    });
  });

  group('远端包（本地 HTTP 夹具）', () {
    // 夹具服务：按真实猫源约定发布 4 个文件，并把收到的 Authorization 记下来。
    late HttpServer server;
    late String base;
    final seenAuth = <String>[];
    final requestedPaths = <String>[];
    late List<int> jsBytes;
    late List<int> cfgBytes;
    late String jsMd5;
    late String cfgMd5;
    String? requireAuth; // 非空时要求该 Basic 值，否则 401

    setUp(() async {
      seenAuth.clear();
      requestedPaths.clear();
      jsBytes = utf8.encode('module.exports={start(){}}');
      cfgBytes = utf8.encode('var index_config={};');
      jsMd5 = md5.convert(jsBytes).toString();
      cfgMd5 = md5.convert(cfgBytes).toString();
      requireAuth = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requestedPaths.add(req.uri.path);
        final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
        seenAuth.add(auth);
        if (requireAuth != null && auth != requireAuth) {
          req.response.statusCode = 401;
          req.response.write('{"message":"Unauthorized"}');
          await req.response.close();
          return;
        }
        switch (req.uri.path) {
          case '/index.js.md5':
            req.response.write(jsMd5);
          case '/index.config.js.md5':
            req.response.write(cfgMd5);
          case '/index.js':
            req.response.add(jsBytes);
          case '/index.config.js':
            req.response.add(cfgBytes);
          default:
            req.response.statusCode = 404;
        }
        await req.response.close();
      });
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async => server.close(force: true));

    test('校验值取自 .md5 地址，bundle 取自去掉 .md5 的地址', () async {
      final bundle = CatBundle(rootDir: p.join(root.path, 'cache'));
      final result = await bundle.ensure('$base/index.js.md5');
      bundle.close();
      expect(result.ok, isTrue, reason: result.error);
      // 关键断言：必须请求过 .md5（否则会把 1.6MB 的 JS 当校验值）。
      expect(requestedPaths, contains('/index.js.md5'));
      expect(requestedPaths, contains('/index.config.js.md5'));
      expect(requestedPaths, contains('/index.js'));
      expect(requestedPaths, contains('/index.config.js'));
    });

    test('校验值与内容不符时明确报错，不静默装上坏包', () async {
      cfgMd5 = md5.convert(utf8.encode('declared-but-wrong')).toString();
      final bundle = CatBundle(rootDir: p.join(root.path, 'cache'));
      final result = await bundle.ensure('$base/index.js.md5');
      bundle.close();
      expect(result.ok, isFalse);
      expect(result.error, contains('校验失败'));
      expect(File(result.entryPath).existsSync(), isFalse);
    });

    test('userinfo 凭据被百分号解码后以 Basic 头发出', () async {
      // 密码里含 `:`（按 URL 规则编码为 %3A），与用户反馈的真实地址同形态。
      final expected = 'Basic ${base64Encode(utf8.encode('root:pa:ss'))}';
      requireAuth = expected;
      final bundle = CatBundle(rootDir: p.join(root.path, 'cache'));
      final result = await bundle.ensure('http://root:pa%3Ass@127.0.0.1:${server.port}/index.js.md5');
      bundle.close();
      expect(result.ok, isTrue, reason: result.error);
      expect(seenAuth, isNotEmpty);
      expect(seenAuth.every((a) => a == expected), isTrue,
          reason: '每个请求都应带解码后的 Basic 凭据，实际：$seenAuth');
    });

    test('不带凭据的地址不发 Authorization 头', () async {
      final bundle = CatBundle(rootDir: p.join(root.path, 'cache'));
      final result = await bundle.ensure('$base/index.js.md5');
      bundle.close();
      expect(result.ok, isTrue, reason: result.error);
      expect(seenAuth.every((a) => a.isEmpty), isTrue);
    });

    test('302 重定向被跟随（加速镜像）', () async {
      final mirror = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      mirror.listen((req) async {
        req.response.statusCode = 302;
        req.response.headers.set(HttpHeaders.locationHeader, '$base${req.uri.path}');
        await req.response.close();
      });
      final bundle = CatBundle(rootDir: p.join(root.path, 'cache'));
      final result = await bundle.ensure('http://127.0.0.1:${mirror.port}/index.js.md5');
      bundle.close();
      await mirror.close(force: true);
      expect(result.ok, isTrue, reason: result.error);
    });
  });

  group('本地 zip 包', () {
    test('zip 内 index.js.md5 与内容一致时可安装', () async {
      // 用 STORED 方式构造最小 zip（避免依赖 archive 包）。
      final jsBytes = utf8.encode('module.exports={start(){}}');
      final cfgBytes = utf8.encode('module.exports={}');
      final jsMd5 = md5.convert(jsBytes).toString();
      final cfgMd5 = md5.convert(cfgBytes).toString();
      final zipPath = p.join(root.path, 'bundle.zip');
      File(zipPath).writeAsBytesSync(
        _buildStoredZip({
          'index.js': jsBytes,
          'index.js.md5': utf8.encode(jsMd5),
          'index.config.js': cfgBytes,
          'index.config.js.md5': utf8.encode(cfgMd5),
        }),
      );

      final bundle = CatBundle(rootDir: p.join(root.path, 'cache'));
      final result = await bundle.ensure(zipPath);
      bundle.close();
      expect(result.ok, isTrue, reason: result.error);
      expect(File(result.entryPath).readAsStringSync(), 'module.exports={start(){}}');
      final key = File(p.join(result.bundleDir, CatBundle.sourceStamp)).readAsStringSync();
      expect(key.startsWith('local-zip:'), isTrue);
    });

    test('zip 内 index.js.md5 与内容不符时报错', () async {
      final zipPath = p.join(root.path, 'bad.zip');
      File(zipPath).writeAsBytesSync(
        _buildStoredZip({
          'index.js': utf8.encode('real'),
          'index.js.md5': utf8.encode('0' * 32),
          'index.config.js': utf8.encode('cfg'),
          'index.config.js.md5': utf8.encode(md5.convert(utf8.encode('cfg')).toString()),
        }),
      );
      final bundle = CatBundle(rootDir: p.join(root.path, 'cache'));
      final result = await bundle.ensure(zipPath);
      bundle.close();
      expect(result.ok, isFalse);
      expect(result.error, contains('校验失败'));
    });
  });
}

/// 构造最小合法 zip（全部 STORED，无压缩、无数据描述符）。
List<int> _buildStoredZip(Map<String, List<int>> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var offset = 0;
  for (final entry in entries.entries) {
    final name = utf8.encode(entry.key);
    final data = entry.value;
    final crc = _crc32(data);
    final local = BytesBuilder()
      ..add(_u32(0x04034b50))
      ..add(_u16(20))
      ..add(_u16(0)) // flags
      ..add(_u16(0)) // method = stored
      ..add(_u16(0))
      ..add(_u16(0)) // time/date
      ..add(_u32(crc))
      ..add(_u32(data.length))
      ..add(_u32(data.length))
      ..add(_u16(name.length))
      ..add(_u16(0))
      ..add(name)
      ..add(data);
    final localBytes = local.takeBytes();
    out.add(localBytes);

    central
      ..add(_u32(0x02014b50))
      ..add(_u16(20))
      ..add(_u16(20))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(crc))
      ..add(_u32(data.length))
      ..add(_u32(data.length))
      ..add(_u16(name.length))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(0))
      ..add(_u32(offset))
      ..add(name);
    offset += localBytes.length;
  }
  final centralBytes = central.takeBytes();
  final eocd = BytesBuilder()
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(entries.length))
    ..add(_u16(entries.length))
    ..add(_u32(centralBytes.length))
    ..add(_u32(offset))
    ..add(_u16(0));
  out.add(centralBytes);
  out.add(eocd.takeBytes());
  return out.takeBytes();
}

List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

List<int> _u32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (~crc) & 0xFFFFFFFF;
}
