import 'dart:async';

import 'package:flutter/painting.dart';

import '../core/home_hero_art.dart';

typedef HomeHeroImageLoader = Future<HomeHeroArtEvidence?> Function(
  ImageProvider<Object> provider,
  ImageConfiguration configuration,
);

class HomeHeroImageProbe {
  HomeHeroImageProbe({
    HomeHeroImageLoader? loader,
    Duration timeout = const Duration(seconds: 5),
    int maxEntries = 160,
  }) : assert(maxEntries >= 0),
       // ignore: prefer_initializing_formals
       _loader = loader,
       // ignore: prefer_initializing_formals
       _timeout = timeout,
       _maxEntries = maxEntries;

  final HomeHeroImageLoader? _loader;
  final Duration _timeout;
  final int _maxEntries;
  final _cache = <Object, HomeHeroArtEvidence?>{};
  final _inFlight = <Object, _ProbeCheck>{};
  int _generation = 0;
  bool _disposed = false;

  Future<HomeHeroArtEvidence?> check(
    String url, {
    Map<String, String>? headers,
    ImageConfiguration configuration = ImageConfiguration.empty,
  }) async {
    if (_disposed) return null;
    final generation = _generation;
    final provider = NetworkImage(
      url,
      headers: headers == null || headers.isEmpty
          ? null
          : Map<String, String>.unmodifiable(headers),
    );
    final Object key;
    try {
      key = await provider.obtainKey(configuration);
    } catch (_) {
      return null;
    }
    if (_disposed || generation != _generation) return null;
    if (_cache.containsKey(key)) {
      final cached = _cache.remove(key);
      _cache[key] = cached;
      return cached;
    }
    final existing = _inFlight[key];
    if (existing != null) return existing.result.future;

    late final _ProbeCheck pending;
    pending = _ProbeCheck((evidence) {
      if (_disposed ||
          generation != _generation ||
          !identical(_inFlight[key], pending)) {
        return;
      }
      _inFlight.remove(key);
      if (_maxEntries <= 0) return;
      _cache[key] = evidence;
      while (_cache.length > _maxEntries) {
        _cache.remove(_cache.keys.first);
      }
    });
    _inFlight[key] = pending;
    pending.timer = Timer(_timeout, () => pending.finish(null));
    final loader = _loader;
    if (loader == null) {
      _loadDecoded(pending, provider, configuration);
    } else {
      unawaited(
        Future<HomeHeroArtEvidence?>.sync(() => loader(provider, configuration))
            .then<void>(
              pending.finish,
              onError: (Object error, StackTrace stack) => pending.finish(null),
            ),
      );
    }
    return pending.result.future;
  }

  void _loadDecoded(
    _ProbeCheck pending,
    ImageProvider<Object> provider,
    ImageConfiguration configuration,
  ) {
    try {
      final stream = provider.resolve(configuration);
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, synchronousCall) {
          try {
            pending.finish(
              HomeHeroArtEvidence(
                width: info.image.width,
                height: info.image.height,
              ),
            );
          } finally {
            info.dispose();
          }
        },
        onError: (Object error, StackTrace? stack) => pending.finish(null),
        // Late stream errors must stay handled after timeout/disposal detaches us.
        reportErrors: false,
      );
      pending.detach = () => stream.removeListener(listener);
      stream.addListener(listener);
    } catch (_) {
      pending.finish(null);
    }
  }

  void clear() {
    _generation++;
    _cache.clear();
    final pending = _inFlight.values.toList();
    _inFlight.clear();
    for (final check in pending) {
      check.finish(null);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clear();
  }
}

class _ProbeCheck {
  _ProbeCheck(this.onComplete);

  final void Function(HomeHeroArtEvidence?) onComplete;
  final result = Completer<HomeHeroArtEvidence?>();
  Timer? timer;
  void Function()? detach;

  void finish(HomeHeroArtEvidence? evidence) {
    if (result.isCompleted) return;
    timer?.cancel();
    timer = null;
    final removeListener = detach;
    detach = null;
    removeListener?.call();
    onComplete(evidence);
    result.complete(evidence);
  }
}
