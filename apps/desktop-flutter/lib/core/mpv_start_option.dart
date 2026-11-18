/// 用 mpv 的 file-local 选项 `start` 做「打开时定位」。
///
/// **为什么必须走 FFI，而不是 `setProperty` / `Media.start`**：`start` 是
/// file-local 选项，只有一个写入通道真正生效——`mpv_set_option_string`
/// **在 `loadfile` 之前**写入。同一时机改用 `mpv_set_property_string` 无效
/// （实测：文件照常从头播），而 media_kit 的 `Media.start` 正是走 property，
/// 所以它在当前内核上不会定位。实测证据见 `.probe/seek-fix-verify`：
///
/// - `loadfile` 前 `set_option('start')` → 落点 1200.032s ✓
/// - `loadfile` 前 `set_property('start')` → 从头播 ✗
/// - `loadfile` 之后再设（两种都）→ 从头播 ✗
///
/// **为什么非要打开时定位**：站点的内网源每客户端只允许 1 条活动流。播放中
/// `seek` 到未缓冲位置需要第二条 HTTP 连接去发 `Range`，会被回 429；ffmpeg
/// 定位失败被判致命后，mpv 置 `eof-reached` 并把 `time-pos` 报成 `duration`
/// （用户看到「拖到缓冲区外就停住 / 跳下一集」）。打开时定位全程只用一条连接。
///
/// 全部失败路径都**静默降级**：拿不到内核句柄或符号缺失时返回 false，调用方
/// 继续按原样播放——一个可选优化不该变成新的播放故障。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _MpvSetOptionStringNative =
    Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _MpvSetOptionString = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);

/// 打开一次 libmpv 并解析 `mpv_set_option_string`；不可用时为 null。
_MpvSetOptionString? _resolveMpvSetOption() {
  DynamicLibrary? library;
  if (Platform.isWindows) {
    try {
      library = DynamicLibrary.open('libmpv-2.dll');
    } catch (_) {
      library = null;
    }
  } else if (Platform.isLinux) {
    for (final name in const ['libmpv.so.2', 'libmpv.so.1', 'libmpv.so']) {
      try {
        library = DynamicLibrary.open(name);
        break;
      } catch (_) {
        library = null;
      }
    }
  } else if (Platform.isMacOS) {
    for (final name in const ['libmpv.2.dylib', 'libmpv.dylib']) {
      try {
        library = DynamicLibrary.open(name);
        break;
      } catch (_) {
        library = null;
      }
    }
  }
  if (library == null) return null;
  try {
    return library
        .lookupFunction<_MpvSetOptionStringNative, _MpvSetOptionString>(
          'mpv_set_option_string',
        );
  } catch (_) {
    return null;
  }
}

/// 起播定位的唯一通道（见文件头）。
class MpvStartOption {
  MpvStartOption() : _setOption = _resolveMpvSetOption();

  final _MpvSetOptionString? _setOption;

  /// 本平台能不能做「打开时定位」。
  bool get isAvailable => _setOption != null;

  /// 把下一个 `loadfile` 的起播位置设为 [position]；null 表示清除（从头开始）。
  ///
  /// [handle] 来自 `NativePlayer.handle`（mpv handle 地址）。
  bool apply(int handle, Duration? position) {
    final setOption = _setOption;
    if (setOption == null || handle == 0) return false;
    final value = position == null || position <= Duration.zero
        ? 'none'
        : (position.inMilliseconds / 1000).toStringAsFixed(4);
    final keyPtr = 'start'.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    try {
      return setOption(
            Pointer<Void>.fromAddress(handle),
            keyPtr,
            valuePtr,
          ) ==
          0;
    } catch (_) {
      return false;
    } finally {
      malloc.free(keyPtr);
      malloc.free(valuePtr);
    }
  }
}
