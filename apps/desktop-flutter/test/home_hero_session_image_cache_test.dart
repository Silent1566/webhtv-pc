import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/home_hero_startup_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Uint8List hd;
  late HomeHeroStartupCache session;
  late HomeHeroStartupCache startup;

  setUpAll(() async {
    hd = await png(1920, 1080);
  });
  setUp(() {
    root = Directory.systemTemp.createTempSync('hero-session-cache-test-');
    session = HomeHeroStartupCache.session(directory: root);
    startup = HomeHeroStartupCache(directory: root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<HomeHeroStartupCandidate> twelve() => [
    for (var index = 0; index < 12; index++)
      HomeHeroStartupCandidate(
        key: 'key-$index',
        sourceUrl: 'https://public.invalid/hero-$index.png',
        title: 'Title $index',
        bytes: hd,
      ),
  ];

  List<String> keys() => [for (var index = 0; index < 12; index++) 'key-$index'];

  test('session retains twelve entries and restores decodable HD bytes', () async {
    await session.save('hero', twelve());
    final restored = session.read('hero');
    expect(restored.map((entry) => entry.key), keys());
    expect(restored, hasLength(12));
    final first = restored.first;
    expect([first.width, first.height], [1920, 1080]);
    final bytes = File(first.filePath).readAsBytesSync();
    expect(bytes, hd);
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final image = (await codec.getNextFrame()).image;
      try {
        expect([image.width, image.height], [1920, 1080]);
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  });

  test('background readback preserves twelve-entry namespace and scope', () async {
    await session.save('hero', twelve());
    await startup.save('hero', twelve());
    expect((await session.readAsync('hero')).map((entry) => entry.key), keys());
    expect(await session.readAsync('other'), isEmpty);
    expect((await startup.readAsync('hero')), hasLength(3));
  });

  test('default instance retains only three of the same twelve entries', () async {
    await startup.save('hero', twelve());
    expect(startup.read('hero').map((entry) => entry.key), [
      'key-0',
      'key-1',
      'key-2',
    ]);
    await session.save('hero', twelve());
    expect(session.read('hero'), hasLength(12));
  });

  test('session and default namespaces stay independent', () async {
    await session.save('hero', twelve());
    await startup.save('hero', twelve());
    final directories = root
        .listSync()
        .whereType<Directory>()
        .map((directory) => directory.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toSet();
    expect(directories, {'home-hero-session-v1', 'home-hero-startup-v1'});
    expect(session.read('hero'), hasLength(12));
    expect(startup.read('hero'), hasLength(3));

    await session.clear();
    expect(session.read('hero'), isEmpty);
    expect(startup.read('hero').map((entry) => entry.key), [
      'key-0',
      'key-1',
      'key-2',
    ]);

    await startup.clear();
    expect(startup.read('hero'), isEmpty);
  });
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
