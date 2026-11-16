import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show ByteData, CachingAssetBundle, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/lut.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/lut_store.dart';

/// 造一份合法的 3D .cube（默认 2³，只要 8 行数据）。
List<int> cubeBytes({int size = 2, String title = 'Test'}) {
  final buffer = StringBuffer('TITLE "$title"\nLUT_3D_SIZE $size\n');
  for (var i = 0; i < size * size * size; i++) {
    buffer.writeln('0.0 0.0 0.0');
  }
  return utf8.encode(buffer.toString());
}

/// 只读内存里的 asset，避免测试依赖真实安装包。
class _MemoryBundle extends CachingAssetBundle {
  _MemoryBundle(this.files);

  final Map<String, List<int>> files;

  @override
  Future<ByteData> load(String key) async {
    final bytes = files[key];
    if (bytes == null) throw FlutterError('Unable to load asset: $key');
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppPaths paths;

  setUp(() {
    root = Directory.systemTemp.createTempSync('webhtv_lut_test');
    paths = AppPaths.resolve(
      overrides: {
        'config': p.join(root.path, 'config'),
        'data': p.join(root.path, 'data'),
        'cache': p.join(root.path, 'cache'),
        'state': p.join(root.path, 'state'),
      },
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  LutStore storeWith({Map<String, List<int>>? assets, http.Client? client}) {
    return LutStore(
      paths: paths,
      bundle: _MemoryBundle(assets ?? const <String, List<int>>{}),
      httpClient: client ?? MockClient((_) async => http.Response('', 404)),
    );
  }

  group('内置落盘', () {
    test('写进 cacheDir/lut 并返回真实路径', () async {
      final store = storeWith(
        assets: {'assets/lut/utopia.cube': cubeBytes(title: '乌托邦')},
      );
      const preset = LutPreset(
        id: 'utopia',
        path: 'assets/lut/utopia.cube',
        name: '乌托邦',
        size: 2,
        source: LutSource.bundled,
      );
      final path = await store.materialize(preset);
      expect(path, p.join(paths.cacheDir, 'lut', 'utopia.cube'));
      expect(await File(path).length(), cubeBytes(title: '乌托邦').length);
    });

    test('重复调用复用同一份文件', () async {
      final store = storeWith(assets: {'assets/lut/a.cube': cubeBytes()});
      const preset = LutPreset(
        id: 'a',
        path: 'assets/lut/a.cube',
        name: 'A',
        size: 2,
        source: LutSource.bundled,
      );
      final first = await store.materialize(preset);
      final stamp = await File(first).lastModified();
      final second = await store.materialize(preset);
      expect(second, first);
      expect(await File(second).lastModified(), stamp);
    });

    test('资源缺失报 lut_asset_missing 而不是写空文件', () async {
      final store = storeWith();
      const preset = LutPreset(
        id: 'ghost',
        path: 'assets/lut/ghost.cube',
        name: 'Ghost',
        size: 2,
        source: LutSource.bundled,
      );
      await expectLater(
        store.materialize(preset),
        throwsA(
          isA<LutStoreException>().having((e) => e.code, 'code', 'lut_asset_missing'),
        ),
      );
      expect(
        File(p.join(paths.cacheDir, 'lut', 'ghost.cube')).existsSync(),
        isFalse,
      );
    });

    test('真实 asset 已在 pubspec 注册（rootBundle 能读到）', () async {
      final data = await rootBundle.load('assets/lut/utopia.cube');
      expect(data.lengthInBytes, greaterThan(1024));
    });

    test('用户预设文件被删后报 lut_missing', () async {
      final store = storeWith();
      const preset = LutPreset(path: '/nope/gone.cube', name: 'Gone', size: 2);
      await expectLater(
        store.materialize(preset),
        throwsA(isA<LutStoreException>().having((e) => e.code, 'code', 'lut_missing')),
      );
    });
  });

  group('导入与删除', () {
    test('合法文件入库并采用 TITLE 作名字', () async {
      final store = storeWith();
      final source = File(p.join(root.path, 'my_look.cube'));
      await source.writeAsBytes(cubeBytes(title: '胶片感'));
      final preset = await store.importFile(source.path);
      expect(preset.source, LutSource.user);
      expect(preset.name, '胶片感');
      expect(preset.size, 2);
      expect(File(preset.path).existsSync(), isTrue);
      expect(p.dirname(preset.path), p.join(paths.dataDir, 'lut'));
    });

    test('同名不覆盖，第二次变成 (2)', () async {
      final store = storeWith();
      final source = File(p.join(root.path, 'dup.cube'));
      await source.writeAsBytes(cubeBytes());
      final first = await store.importFile(source.path);
      final second = await store.importFile(source.path);
      expect(second.path, isNot(first.path));
      expect(p.basename(second.path), 'dup (2).cube');
    });

    test('非法内容不入库', () async {
      final store = storeWith();
      final source = File(p.join(root.path, 'bad.cube'));
      await source.writeAsString('LUT_1D_SIZE 32\n');
      await expectLater(
        store.importFile(source.path),
        throwsA(
          isA<LutStoreException>().having((e) => e.code, 'code', 'lut_invalid'),
        ),
      );
      expect(Directory(p.join(paths.dataDir, 'lut')).existsSync(), isFalse);
    });

    test('删除用户预设；内置预设拒绝删除', () async {
      final store = storeWith();
      final source = File(p.join(root.path, 'del.cube'));
      await source.writeAsBytes(cubeBytes());
      final preset = await store.importFile(source.path);
      await store.deleteUserPreset(preset);
      expect(File(preset.path).existsSync(), isFalse);

      await expectLater(
        store.deleteUserPreset(builtinLutPresets.first),
        throwsA(
          isA<LutStoreException>().having((e) => e.code, 'code', 'lut_bundled'),
        ),
      );
    });

    test('列目录只认 .cube 并按名字排序', () async {
      final store = storeWith();
      final dir = Directory(p.join(paths.dataDir, 'lut'))
        ..createSync(recursive: true);
      await File(p.join(dir.path, 'b.cube')).writeAsBytes(
        cubeBytes(title: 'Bravo'),
      );
      await File(p.join(dir.path, 'a.cube')).writeAsBytes(
        cubeBytes(title: 'Alpha'),
      );
      await File(p.join(dir.path, 'note.txt')).writeAsString('ignore me');

      final presets = await store.listUserPresets();
      expect(presets.map((e) => e.name).toList(), ['Alpha', 'Bravo']);
      expect(presets.every((e) => e.source == LutSource.user), isTrue);
    });
  });

  group('在线', () {
    test('从链接下载并入库', () async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('.cube')) {
          return http.Response.bytes(cubeBytes(title: 'Online'), 200);
        }
        return http.Response('not found', 404);
      });
      final store = storeWith(client: client);
      final preset = await store.download(
        'https://example.com/looks/online.cube',
      );
      expect(preset.name, 'Online');
      expect(p.basename(preset.path), 'online.cube');
      expect(File(preset.path).existsSync(), isTrue);
    });

    test('非 http(s) 链接直接拒绝', () async {
      final store = storeWith();
      await expectLater(
        store.download('file:///etc/passwd'),
        throwsA(
          isA<LutStoreException>().having((e) => e.code, 'code', 'lut_bad_url'),
        ),
      );
    });

    test('超过 8 MiB 的声明长度在读取前就被拦下', () async {
      final client = MockClient((request) async {
        return http.Response.bytes(
          cubeBytes(),
          200,
          headers: {'content-length': '${lutFileBytesLimit + 1}'},
        );
      });
      final store = storeWith(client: client);
      await expectLater(
        store.download('https://example.com/big.cube'),
        throwsA(
          isA<LutStoreException>().having((e) => e.code, 'code', 'lut_too_large'),
        ),
      );
    });

    test('403 被翻译成限流提示', () async {
      final client = MockClient(
        (request) async => http.Response('rate limited', 403),
      );
      final store = storeWith(client: client);
      await expectLater(
        store.searchRepositories('film'),
        throwsA(
          isA<LutStoreException>()
              .having((e) => e.code, 'code', 'lut_rate_limited'),
        ),
      );
    });

    test('搜索解析仓库字段并补默认分支', () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'api.github.com');
        expect(request.url.query, contains('film'));
        return http.Response(
          jsonEncode({
            'items': [
              {
                'name': 'luts',
                'owner': {'login': 'someone'},
                'default_branch': '',
                'description': 'free luts',
                'stargazers_count': 42,
              },
              {'name': 'broken'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final store = storeWith(client: client);
      final hits = await store.searchRepositories('film');
      expect(hits.length, 1);
      expect(hits.single.fullName, 'someone/luts');
      expect(hits.single.branch, 'main');
      expect(hits.single.stars, 42);
      expect(hits.single.subtitle, contains('free luts'));
    });

    test('列 .cube 只收 blob 且按路径排序', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'tree': [
              {'type': 'blob', 'path': 'z/Last.cube'},
              {'type': 'blob', 'path': 'a/First.cube'},
              {'type': 'tree', 'path': 'not-a-file.cube'},
              {'type': 'blob', 'path': 'readme.md'},
            ],
          }),
          200,
        );
      });
      final store = storeWith(client: client);
      const hit = LutRepoHit(
        owner: 'o',
        repo: 'r',
        branch: 'main',
        description: '',
        stars: 0,
      );
      final paths = await store.listCubePaths(hit);
      expect(paths, ['a/First.cube', 'z/Last.cube']);
    });
  });
}
