import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'poster_image.dart';

/// 从已解码的provider导出少量启动图片；页面卸载时取消listener与超时计时器。
class HomeHeroStartupImageEncoder {
  final Set<_StartupImageExport> _pending = {};
  bool _disposed = false;

  Future<Uint8List?> encode(String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    if (_disposed) return null;
    final job = _StartupImageExport();
    _pending.add(job);
    job.timer = Timer(timeout, () => job.finish(null));
    try {
      final stream = posterImageProvider(url, headers: headers).resolve(ImageConfiguration.empty);
      var takingFrame = false;
      late ImageStreamListener listener;
      listener = ImageStreamListener((info, _) {
        if (takingFrame || job.done.isCompleted) { info.dispose(); return; }
        takingFrame = true;
        unawaited(() async {
          try {
            final bytes = await info.image.toByteData(format: ui.ImageByteFormat.png);
            job.finish(bytes?.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
          } catch (_) {
            job.finish(null);
          } finally {
            info.dispose();
          }
        }());
      }, onError: (Object error, StackTrace? stack) => job.finish(null), reportErrors: false);
      job.detach = () => stream.removeListener(listener);
      stream.addListener(listener);
      return await job.done.future;
    } catch (_) {
      job.finish(null);
      return null;
    } finally {
      _pending.remove(job);
    }
  }

  void clear() {
    for (final job in _pending.toList()) { job.finish(null); }
    _pending.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}

class _StartupImageExport {
  final done = Completer<Uint8List?>();
  Timer? timer;
  void Function()? detach;

  void finish(Uint8List? bytes) {
    if (done.isCompleted) return;
    timer?.cancel();
    timer = null;
    detach?.call();
    detach = null;
    done.complete(bytes);
  }
}
