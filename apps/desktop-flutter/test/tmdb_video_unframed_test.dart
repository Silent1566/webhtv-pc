import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/ui/theme.dart';
import 'package:webhtv_pc/ui/tmdb_detail_view.dart';
import 'package:webhtv_pc/ui/toast.dart';
import 'package:webhtv_pc/ui/wallpaper_backdrop.dart';

import 'support/test_fonts.dart';

late List<int> imageBytesForTest;
const _root = ValueKey('video-list-capture');
const _videos = [
  TmdbVideo(
    id: '1',
    key: 'trailer',
    site: 'YouTube',
    name: '官方预告 · 测试影片',
    type: 'Trailer',
  ),
  TmdbVideo(
    id: '2',
    key: 'teaser',
    site: 'YouTube',
    name: '在雨里，遇见更温暖的故事',
    type: 'Teaser',
  ),
  TmdbVideo(
    id: '3',
    key: 'feature',
    site: 'YouTube',
    name: '幕后花絮',
    type: 'Featurette',
  ),
];

Future<List<int>> _thumbnail() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const bounds = Rect.fromLTWH(0, 0, 320, 180);
  canvas.drawRect(
    bounds,
    Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF355268), Color(0xFF936E4B)],
      ).createShader(bounds),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 125, 320, 55),
    Paint()..color = const Color(0xFF162B3C),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(320, 180);
  picture.dispose();
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

class _ImageClient implements HttpClient {
  _ImageClient(this.bytes);
  final List<int> bytes;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _ImageRequest(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageRequest implements HttpClientRequest {
  _ImageRequest(this.bytes);
  final List<int> bytes;
  @override
  Future<HttpClientResponse> close() async => _ImageResponse(bytes);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ImageResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _ImageResponse(List<int> bytes)
    : contentLength = bytes.length,
      super(Stream.value(bytes));
  @override
  final int contentLength;
  @override
  int get statusCode => 200;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _mount(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
  Size size = const Size(1286, 451),
  double scale = 1,
  Future<bool> Function(String)? onOpen,
  Future<void> Function(String)? onCopy,
}) async {
  debugNetworkImageHttpClientProvider = () => _ImageClient(imageBytesForTest);
  try {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = buildAppTheme(brightness);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'FixtureCJK'),
        ),
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: scale,
          maxScaleFactor: scale,
          child: Stack(
            fit: StackFit.expand,
            children: [child!, const ToastHost()],
          ),
        ),
        home: RepaintBoundary(
          key: _root,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const DefaultGlassBackdrop(),
              Material(
                type: MaterialType.transparency,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TmdbDetailSections(
                      data: const TmdbDetailData(
                        tmdbId: 1,
                        title: '测试影片',
                        mediaType: TmdbMediaType.tv,
                      ),
                      videos: _videos,
                      onOpenVideo: onOpen,
                      onCopyVideo: onCopy,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump();
      final images = tester.renderObjectList<RenderImage>(
        find.byType(RawImage),
      );
      if (images.length == 3 && images.every((image) => image.image != null)) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
    expect(
      tester
          .renderObjectList<RenderImage>(find.byType(RawImage))
          .where((image) => image.image != null),
      hasLength(3),
    );
  } finally {
    debugNetworkImageHttpClientProvider = null;
  }
}

Future<List<int>> _pixels(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    final image = await tester
        .renderObject<RenderRepaintBoundary>(find.byKey(_root))
        .toImage();
    try {
      final data = (await image.toByteData())!;
      return data.buffer
          .asUint8List(data.offsetInBytes, data.lengthInBytes)
          .toList();
    } finally {
      image.dispose();
    }
  }))!;
}

Future<void> _capture(WidgetTester tester, String name) async {
  final dir = Platform.environment['VIDEO_TILE_CAPTURE'];
  if (dir == null) return;
  final phase = Platform.environment['VIDEO_TILE_PHASE'] ?? 'after';
  final bounds = <String, List<double>>{};
  for (final video in _videos) {
    for (final key in [
      'tmdb-video-${video.identity}',
      'tmdb-video-open-${video.identity}',
      'tmdb-video-copy-${video.identity}',
    ]) {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      bounds[key] = [rect.left, rect.top, rect.width, rect.height];
    }
  }
  await tester.runAsync(() async {
    final image = await tester
        .renderObject<RenderRepaintBoundary>(find.byKey(_root))
        .toImage();
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('$dir/$name-$phase.png').writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      await File('$dir/$name-$phase.json').writeAsString(jsonEncode(bounds));
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    await loadFixtureFonts();
    imageBytesForTest = await _thumbnail();
  });
  setUp(dismissAllToasts);

  for (final brightness in Brightness.values) {
    for (final compact in [false, true]) {
      final name =
          '${brightness.name}-${compact ? '720x600-1.6x' : '1286x451-1x'}';
      testWidgets('related video rows expose shared backdrop $name', (
        tester,
      ) async {
        await _mount(
          tester,
          brightness: brightness,
          size: compact ? const Size(720, 600) : const Size(1286, 451),
          scale: compact ? 1.6 : 1,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('相关视频（3）'), findsOneWidget);
        for (final video in _videos) {
          expect(
            find
                .byKey(ValueKey('tmdb-video-open-${video.identity}'))
                .hitTestable(),
            findsOneWidget,
          );
          expect(
            find
                .byKey(ValueKey('tmdb-video-copy-${video.identity}'))
                .hitTestable(),
            findsOneWidget,
          );
        }
        await _capture(tester, name);
        expect(
          find.byType(Card),
          findsNothing,
          reason: 'Related videos must not reinstate full-width backing plates',
        );
        for (final video in _videos) {
          final tile = tester.widget<Material>(
            find.byKey(ValueKey('tmdb-video-${video.identity}')),
          );
          expect(tile.type, MaterialType.transparency);
        }
      });
    }
  }

  testWidgets('video actions preserve Tab Enter and visible focus feedback', (
    tester,
  ) async {
    String? opened;
    String? copied;
    await _mount(
      tester,
      onOpen: (url) async {
        opened = url;
        return true;
      },
      onCopy: (url) async {
        copied = url;
      },
    );
    final strategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = strategy);
    final open = find.byKey(const ValueKey('tmdb-video-open-YouTube|trailer'));
    final copy = find.byKey(const ValueKey('tmdb-video-copy-YouTube|trailer'));
    final resting = await _pixels(tester);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(open));
    addTearDown(mouse.removePointer);
    await tester.pumpAndSettle();
    expect(
      listEquals(await _pixels(tester), resting),
      isFalse,
      reason: 'Hover must produce visible feedback',
    );
    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    final unfocused = await _pixels(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
      listEquals(await _pixels(tester), unfocused),
      isFalse,
      reason: 'Keyboard focus must produce visible feedback',
    );
    expect(
      Focus.of(
        tester.element(find.descendant(of: open, matching: find.byType(Icon))),
      ).hasFocus,
      isTrue,
    );
    await _capture(tester, 'dark-keyboard-focus');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, 'https://www.youtube.com/watch?v=trailer');
    expect(copied, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      Focus.of(
        tester.element(find.descendant(of: copy, matching: find.byType(Icon))),
      ).hasFocus,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(copied, 'https://www.youtube.com/watch?v=trailer');
    expect(tester.takeException(), isNull);
  });
}
