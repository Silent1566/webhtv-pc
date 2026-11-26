import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _ShellExecuteWNative = IntPtr Function(
  Pointer<Void> hwnd,
  Pointer<Utf16> operation,
  Pointer<Utf16> file,
  Pointer<Utf16> parameters,
  Pointer<Utf16> directory,
  Int32 showCommand,
);

typedef _ShellExecuteW = int Function(
  Pointer<Void> hwnd,
  Pointer<Utf16> operation,
  Pointer<Utf16> file,
  Pointer<Utf16> parameters,
  Pointer<Utf16> directory,
  int showCommand,
);

final _shellExecuteW = DynamicLibrary.open('shell32.dll')
    .lookupFunction<_ShellExecuteWNative, _ShellExecuteW>('ShellExecuteW');

/// 将 URL 交给 Windows 的真实默认关联；返回值大于 32 表示交接成功。
int windowsShellOpen(String url) {
  Pointer<Utf16> operation = nullptr;
  Pointer<Utf16> target = nullptr;
  try {
    operation = 'open'.toNativeUtf16();
    target = url.toNativeUtf16();
    return _shellExecuteW(
      nullptr,
      operation,
      target,
      nullptr,
      nullptr,
      1, // SW_SHOWNORMAL
    );
  } finally {
    if (target != nullptr) malloc.free(target);
    if (operation != nullptr) malloc.free(operation);
  }
}
