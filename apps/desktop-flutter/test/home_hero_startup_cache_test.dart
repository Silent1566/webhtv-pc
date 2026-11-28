import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/home_hero_startup_cache.dart';

class _ObservedReadFile implements File {
  _ObservedReadFile(this.file, this.onOpen);
  final File file;
  final void Function() onOpen;

  @override
  String get path => file.path;

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    onOpen();
    return file.openSync(mode: mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HomeHeroStartupCache cache;
  late Uint8List hd;
  late Uint8List low;
  late Uint8List portrait;

  setUpAll(() async {
    hd = await png(1280, 720);
    low = await png(241, 330);
    portrait = await png(1280, 1600);
  });
  setUp(() {
    root = Directory.systemTemp.createTempSync('hero-startup-test-');
    cache = HomeHeroStartupCache(directory: root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  HomeHeroStartupCandidate entry(
    String key, {
    Uint8List? bytes,
    String? url,
    String title = 'Display title',
    String subtitle = '2026',
    String overview = 'Display overview',
    List<String> tags = const ['Drama'],
  }) => HomeHeroStartupCandidate(
    key: key,
    sourceUrl: url ?? 'https://public.invalid/$key.png',
    title: title,
    subtitle: subtitle,
    overview: overview,
    tags: tags,
    bytes: bytes ?? hd,
  );

  File index() => root
      .listSync(recursive: true)
      .whereType<File>()
      .singleWhere((file) => file.path.endsWith('index.json'));
  Map<String, dynamic> metadata() =>
      jsonDecode(index().readAsStringSync()) as Map<String, dynamic>;
  void mutate(void Function(Map<String, dynamic>) change) {
    final value = metadata();
    change(value);
    index().writeAsStringSync(jsonEncode(value));
  }

  test(
    'restores real HD bytes and display text offline from a new instance',
    () async {
      await cache.save('scope-a', [
        entry('one', url: 'https://public.invalid/one.png?w=1280#private'),
      ]);
      final restored = HomeHeroStartupCache(directory: root).read('scope-a');
      expect(restored, hasLength(1));
      final hero = restored.single;
      expect(hero.key, 'one');
      expect(hero.sourceUrl, 'https://public.invalid/one.png?w=1280');
      expect(
        [hero.title, hero.subtitle, hero.overview],
        ['Display title', '2026', 'Display overview'],
      );
      expect(hero.tags, ['Drama']);
      expect([hero.width, hero.height], [1280, 720]);
      expect(File(hero.filePath).readAsBytesSync(), hd);
      expect(cache.read('scope-b'), isEmpty);
    },
  );

  test(
    'rejects low resolution, portrait, invalid and non-PNG/JPEG bytes',
    () async {
      await cache.save('scope-a', [
        entry('low', bytes: low),
        entry('portrait', bytes: portrait),
        entry('corrupt', bytes: Uint8List.fromList([1, 2, 3])),
      ]);
      expect(cache.read('scope-a'), isEmpty);
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );

  test(
    'keeps first three eligible entries with bounded display text',
    () async {
      await cache.save('scope-a', [
        entry('low', bytes: low),
        entry(
          'one',
          title: 't' * 300,
          subtitle: 's' * 200,
          overview: 'o' * 3000,
          tags: ['a' * 80, 'b', 'c', 'd'],
        ),
        entry('two'),
        entry('three'),
        entry('four'),
      ]);
      final restored = cache.read('scope-a');
      expect(restored.map((e) => e.key), ['one', 'two', 'three']);
      expect(restored.first.title.length, 256);
      expect(restored.first.subtitle.length, 128);
      expect(restored.first.overview.length, 2000);
      expect(restored.first.tags, ['a' * 64, 'b', 'c']);
      expect(index().lengthSync(), lessThanOrEqualTo(64 * 1024));
      expect(root.listSync(recursive: true).whereType<File>().length, 4);
    },
  );

  test('refuses credential URLs and retains only public URL queries', () async {
    await cache.save('scope-a', [
      entry('file', url: 'file:///private/image.png'),
      entry('ftp', url: 'ftp://public.invalid/image.png'),
      entry('userinfo', url: 'https://user:password@public.invalid/image.png'),
      entry(
        'token',
        url: 'https://public.invalid/image.png?access_token=secret',
      ),
      entry('key', url: 'https://public.invalid/image.png?API-Key=secret'),
      entry(
        'signed',
        url: 'https://public.invalid/image.png?X-Amz-Signature=secret',
      ),
      entry('good', url: 'http://public.invalid/image.png?width=1280'),
    ]);
    expect(cache.read('scope-a').map((e) => e.key), ['good']);
    expect(index().readAsStringSync(), isNot(contains('secret')));
  });

  test('rejects oversized image bytes and preserves a good index on failed refresh', () async {
    await cache.save('scope-a', [entry('good')]);
    final before = index().readAsBytesSync();
    final oversized = Uint8List(6 * 1024 * 1024 + 1)
      ..setRange(0, hd.length, hd);
    await cache.save('scope-a', [
      entry('big', bytes: oversized),
      entry('bad', bytes: low),
    ]);
    await cache.save('scope-a', []);
    expect(index().readAsBytesSync(), before);
    expect(cache.read('scope-a').single.key, 'good');
  });

  test('rejects missing and SHA-mismatched files independently', () async {
    await cache.save('scope-a', [entry('one'), entry('two'), entry('three')]);
    final files = cache.read('scope-a');
    File(files[0].filePath).deleteSync();
    final changed = File(files[1].filePath).readAsBytesSync();
    changed[changed.length - 1] ^= 1;
    File(files[1].filePath).writeAsBytesSync(changed);
    expect(cache.read('scope-a').map((e) => e.key), ['three']);
  });

  test(
    'rejects path traversal and source binding mismatches independently',
    () async {
      await cache.save('scope-a', [entry('one'), entry('two'), entry('three')]);
      mutate((value) {
        value['entries'][0]['file'] = '../outside.png';
        value['entries'][1]['sourceUrl'] =
            'https://public.invalid/different.png';
      });
      expect(cache.read('scope-a').map((e) => e.key), ['three']);
    },
  );

  test('rejects non-HD stored dimensions and oversized display metadata independently', () async {
    await cache.save('scope-a', [entry('one'), entry('two'), entry('three')]);
    mutate((value) {
      value['entries'][0]['width'] = 241;
      value['entries'][1]['title'] = 't' * 257;
    });
    expect(cache.read('scope-a').map((e) => e.key), ['three']);
  });

  test(
    'invalid scopes, corrupt or oversized JSON never throw or leak entries',
    () async {
      await cache.save('scope-a', [entry('good')]);
      final original = index().readAsBytesSync();
      for (final scope in ['', '..', '../scope-a', 'a/b', 'a\\b', 'a' * 257]) {
        expect(cache.read(scope), isEmpty);
        await cache.save(scope, [entry('invalid')]);
        expect(index().readAsBytesSync(), original);
      }
      index().writeAsStringSync('{');
      expect(cache.read('scope-a'), isEmpty);
      index().writeAsStringSync(' ' * (64 * 1024 + 1));
      expect(cache.read('scope-a'), isEmpty);
    },
  );

  test('failed filesystem write leaves the prior index intact', () async {
    await cache.save('scope-a', [entry('good')]);
    final before = index().readAsBytesSync();
    final other = HomeHeroStartupCache(
      directory: Directory(cache.read('scope-a').single.filePath),
    );
    await other.save('scope-a', [entry('bad')]);
    expect(index().readAsBytesSync(), before);
    expect(cache.read('scope-a').single.key, 'good');
  });

  test(
    'latest concurrent scope wins, including across cache instances',
    () async {
      final old = cache.save('old-scope', [entry('old')]);
      final latest = HomeHeroStartupCache(directory: root)
          .save('new-scope', [entry('new')]);
      await Future.wait([old, latest]);
      expect(cache.read('old-scope'), isEmpty);
      expect(cache.read('new-scope').single.key, 'new');
    },
  );

  test('clear invalidates pending saves without resurrection or touching other data', () async {
    final unrelated = File('${root.path}/unrelated.json')
      ..writeAsStringSync('keep');
    final saving = cache.save('scope-a', [entry('one'), entry('two')]);
    final clearing = HomeHeroStartupCache(directory: root).clear();
    await Future.wait([saving, clearing]);
    expect(cache.read('scope-a'), isEmpty);
    expect(unrelated.readAsStringSync(), 'keep');
    expect(root.listSync(recursive: true).whereType<File>().length, 1);
    await cache.save('scope-a', [entry('new')]);
    expect(cache.read('scope-a').single.key, 'new');
  });

  test('accepts real HD JPEG bytes without fetching its URL', () async {
    final jpeg = Uint8List.fromList(zlib.decode(base64Decode(_jpegFixture)));
    await cache.save('scope-a', [entry('jpeg', bytes: jpeg)]);
    final restored = cache.read('scope-a').single;
    expect([restored.width, restored.height], [1280, 720]);
    expect(restored.filePath.endsWith('.jpg'), isTrue);
    expect(File(restored.filePath).readAsBytesSync(), jpeg);
  });

  test('background readback validates bytes without opening files on the caller', () async {
    await cache.save('scope-a', [entry('one'), entry('two')]);
    final files = {
      for (final file in root.listSync(recursive: true).whereType<File>())
        file.path: file,
    };
    var callerReads = 0;
    final restored = await IOOverrides.runZoned(
      () => cache.readAsync('scope-a'),
      createFile: (path) => _ObservedReadFile(files[path]!, () => callerReads++),
    );
    expect(restored.map((item) => item.key), ['one', 'two']);
    expect(callerReads, 0,
        reason: 'post-save SHA validation and disk reads must not block UI');
    final damaged = File(restored.first.filePath);
    damaged.writeAsBytesSync([1, 2, 3]);
    expect((await cache.readAsync('scope-a')).map((item) => item.key), ['two']);
  });

  test('background readback shares the save queue and rejects stale generations', () async {
    final save = cache.save('scope-a', [entry('one')]);
    final restored = cache.readAsync('scope-a');
    await save;
    expect((await restored).single.key, 'one');
    final old = cache.readAsync('scope-a');
    final clear = HomeHeroStartupCache(directory: root).clear();
    expect(await old, isEmpty);
    await clear;
    expect(await cache.readAsync('scope-a'), isEmpty);
  });

  test('three maximum-size images stay within eighteen MiB', () async {
    final padded = Uint8List(6 * 1024 * 1024)..setRange(0, hd.length, hd);
    await cache.save('scope-a', [
      entry('one', bytes: padded),
      entry('two', bytes: padded),
      entry('three', bytes: padded),
      entry('four', bytes: padded),
    ]);
    final restored = cache.read('scope-a');
    expect(restored.map((e) => e.key), ['one', 'two', 'three']);
    expect(
      restored.fold<int>(0, (sum, e) => sum + File(e.filePath).lengthSync()),
      18 * 1024 * 1024,
    );
  });

  test(
    'clear cancels a save already awaiting image decode without sleeps',
    () async {
      final started = Completer<void>();
      Iterable<HomeHeroStartupCandidate> pending() sync* {
        started.complete();
        yield entry('pending');
      }

      final saving = cache.save('scope-a', pending());
      await started.future;
      await cache.clear();
      await saving;
      expect(cache.read('scope-a'), isEmpty);
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );

  test('a newer scope supersedes an in-flight decoded save', () async {
    final started = Completer<void>();
    Iterable<HomeHeroStartupCandidate> pending() sync* {
      started.complete();
      yield entry('old');
    }

    final saving = cache.save('old-scope', pending());
    await started.future;
    final latest = cache.save('new-scope', [entry('new')]);
    await Future.wait([saving, latest]);
    expect(cache.read('old-scope'), isEmpty);
    expect(cache.read('new-scope').single.key, 'new');
  });

  test(
    'read inspects only the first three records even when one is corrupt',
    () async {
      await cache.save('scope-a', [entry('one'), entry('two'), entry('three')]);
      mutate((value) {
        value['entries'].add(
          Map<String, dynamic>.from(value['entries'][0] as Map),
        );
        value['entries'][0] = null;
      });
      expect(cache.read('scope-a').map((e) => e.key), ['two', 'three']);
    },
  );

  test('read rejects low-resolution bytes even with forged HD index dimensions', () async {
    await cache.save('scope-a', [entry('one')]);
    final value = metadata();
    final record = value['entries'][0] as Map<String, dynamic>;
    final digest = sha256.convert(low).toString();
    record['sha256'] = digest;
    record['size'] = low.length;
    final name =
        '${sha256.convert(utf8.encode(jsonEncode([value['scope'], 'one', 'https://public.invalid/one.png', digest, 1280, 720])))}.png';
    record['file'] = name;
    File('${index().parent.path}/$name').writeAsBytesSync(low);
    index().writeAsStringSync(jsonEncode(value));
    expect(cache.read('scope-a'), isEmpty);
  });

  test(
    'failed initial index publication removes all prepared orphan images',
    () async {
      final owned = Directory('${root.path}/home-hero-startup-v1')
        ..createSync();
      Directory('${owned.path}/index.json').createSync();
      await cache.save('scope-a', [entry('one'), entry('two'), entry('three')]);
      expect(cache.read('scope-a'), isEmpty);
      expect(owned.listSync().whereType<File>(), isEmpty);
    },
  );

  test('read save and clear refuse linked cache directories without touching targets', () async {
    await cache.save('scope-a', [entry('one')]);
    final owned = index().parent;
    final external = Directory('${root.path}/external')..createSync();
    for (final file in owned.listSync().whereType<File>()) {
      file.copySync('${external.path}/${file.uri.pathSegments.last}');
    }
    final originals = {
      for (final file in external.listSync().whereType<File>())
        file.path: file.readAsBytesSync(),
    };
    owned.deleteSync(recursive: true);
    if (Platform.isWindows) {
      final result = Process.runSync('cmd', [
        '/c',
        'mklink',
        '/J',
        owned.path.replaceAll('/', r'\'),
        external.path.replaceAll('/', r'\'),
      ]);
      expect(
        result.exitCode,
        0,
        reason: 'Junction creation: ${result.stdout} ${result.stderr}',
      );
    } else {
      Link(owned.path).createSync(external.path);
    }
    try {
      expect(cache.read('scope-a'), isEmpty);
      expect(await cache.readAsync('scope-a'), isEmpty);
      await cache.save('scope-a', [entry('two')]);
      await cache.clear();
      for (final original in originals.entries) {
        expect(File(original.key).readAsBytesSync(), original.value);
      }
      expect(external.listSync().whereType<File>().length, 2);
    } finally {
      Link(owned.path).deleteSync();
    }
  });

  test('strict scope rejects trailing line separators', () async {
    await cache.save('scope-a', [entry('one')]);
    final before = index().readAsBytesSync();
    await cache.save('scope-a\n', [entry('two')]);
    expect(cache.read('scope-a\n'), isEmpty);
    expect(index().readAsBytesSync(), before);
  });

  test(
    'refresh prunes owned orphan images but preserves unrelated files',
    () async {
      await cache.save('scope-a', [
        entry('old-one'),
        entry('old-two'),
        entry('old-three'),
      ]);
      final owned = index().parent;
      final unrelated = File('${owned.path}/keep.txt')
        ..writeAsStringSync('keep');
      await cache.save('scope-a', [entry('new')]);
      expect(cache.read('scope-a').single.key, 'new');
      expect(owned.listSync().whereType<File>().length, 3);
      expect(unrelated.readAsStringSync(), 'keep');
    },
  );
}

Future<Uint8List> png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff2468ab), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

const _jpegFixture =
    'eJztz0lME3EYxuHvP/u008C0BUszWLpgiyHETkcBozGAVuEG7p4Ad2/ggpp4AHduuOtJXNEbKm4n0bqexBXwIu56Anc8OKbE5eJBPZr3TZ7bly/52b32Y8qsSlYmiTFGtVRLZD+iClIkSZZERZZlVVUcmtelOZ1ajtuT4c31B0bn+g0jL1IUzQsVhg0jVlxQOC5uWVYgWjq5xJxUlLDM9BOmqqrm1Hwul88MGkHzr2dfIl3hbovEsxBxOuN1ZqcoQMRENjL6PsbxgijJiupw2inqyiSO8Twn8KIoCERsA+N4EnTRHYyXSZ7qOjnU4DWb29qVcHlnd1ZNz2AkUd/YojqyR/ly/PljorGCsdb4CcUlpRMrpk5LTp9RWTVz1uw5c+fNX7Bw0eIlS5ctX7Fy1eo1TWvXrd+4afOWrdu2t+7YuWv3nr379h84dPjI0WPHO06cPHX6TNfZc+cvXLx8JXX12vUbN2/duXvv/oOHvX39A0+ePnv+4uWr12+G3r57/+Hjp8/DX9JdjHj2Y7/t0oljnCDwgpzuYlxT+kAXxGBccpdVy3UNnpDZrHjL29o7u9VwomYwq76xx5EdsQbyh9JpI2V/FtbyT2U/w3519ZPGM+J0XqcpNPy1NXaQAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgP9Kht33Df8dfP4=';
