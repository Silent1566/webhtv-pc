// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:webhtv_pc/services/player_thumbnail_service.dart';

class NavigationMediaIO extends PlatformPlayer {
  NavigationMediaIO() : super(configuration: const PlayerConfiguration());

  Media? media;
  int seeks = 0;
  bool released = false;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    media = playable as Media;
    report(
      duration: const Duration(seconds: 100),
      position: const Duration(seconds: 1),
      playing: play,
    );
  }

  void report({
    required Duration duration,
    required Duration position,
    bool playing = false,
  }) {
    state = state.copyWith(
      duration: duration,
      position: position,
      playing: playing,
    );
    durationController.add(duration);
    positionController.add(position);
    playingController.add(playing);
  }

  @override
  Future<void> seek(Duration duration) async {
    seeks++;
    state = state.copyWith(position: duration);
    positionController.add(duration);
  }

  @override
  Future<void> dispose() async {
    released = true;
    await super.dispose();
  }
}

class ThumbnailIO implements PlayerThumbnailSession {
  Media? media;
  final targets = <Duration>[];
  Completer<void>? openGate;
  Completer<Uint8List?>? extractionGate;
  int active = 0;
  int maxActive = 0;
  Completer<void>? disposalGate;
  Object? error;
  int releases = 0;
  bool cancelled = false;
  final bytes = Uint8List.fromList([1, 2, 3]);

  @override
  Future<void> open(Media source) async {
    media = source;
    await openGate?.future;
  }

  @override
  Future<Uint8List?> extract(Duration target) async {
    targets.add(target);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (error case final value?) throw value;
      if (target == const Duration(seconds: 7)) return Uint8List.fromList([7]);
      return extractionGate == null ? bytes : await extractionGate!.future;
    } finally {
      active--;
    }
  }

  @override
  Future<void> dispose() async {
    cancelled = true;
    releases++;
    await disposalGate?.future;
  }
}

class NavigationNativeIO implements NativePlayer {
  final media = NavigationMediaIO();
  @override
  bool isVideoControllerAttached = false;
  @override
  PlayerState get state => media.state;
  @override
  PlayerStream get stream => media.stream;
  final properties = <String, String>{
    'seekable': 'yes',
    'time-pos': '2.0',
    'seeking': 'no',
  };
  final propertyGates = <String, Completer<String>>{};
  final requested = <String, Completer<void>>{};
  int commands = 0;
  @override
  late final generated.MPV mpv = _NavigationCommands(() {
    commands++;
    properties['time-pos'] = '4.0';
  });
  @override
  Pointer<generated.mpv_handle> get ctx => nullptr;
  @override
  bool get disposed => media.released;
  @override
  Future<void> get waitForPlayerInitialization => Future.value();
  @override
  Future<void> get waitForVideoControllerInitializationIfAttached =>
      Future.value();
  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    final signal = requested[property];
    if (signal != null && !signal.isCompleted) signal.complete();
    return propertyGates[property]?.future ??
        Future.value(properties[property] ?? '');
  }

  @override
  Future<void> open(
    Playable playable, {
    bool play = true,
    bool synchronized = true,
  }) => media.open(playable, play: play);
  @override
  Future<void> seek(Duration target, {bool synchronized = true}) =>
      media.seek(target);
  @override
  Future<void> dispose({bool synchronized = true}) => media.dispose();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NavigationCommands implements generated.MPV {
  _NavigationCommands(this.command);
  final void Function() command;
  @override
  // ignore: non_constant_identifier_names
  int mpv_command(
    Pointer<generated.mpv_handle> ctx,
    Pointer<Pointer<Int8>> args,
  ) {
    command();
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
