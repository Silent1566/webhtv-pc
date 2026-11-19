/// libmpv 可用性探测。
///
/// `flutter test` 的默认环境里没有 mpv 内核：任何真的构造 `MediaKit` /
/// `Player` 的用例都会在初始化处抛异常，或者在等内核就绪时挂住。这是
/// 「本机不具备」，不是用例坏了，所以判据独立成一个可复用的跳过理由。
///
/// 判定顺序：
/// 1. 显式设置 `WEBHTV_TEST_LIBMPV` → 视为调用者已声明内核路径（沿用
///    `player_volume_controller_test.dart` 的既有语义；该变量同时传给
///    `MediaKit.ensureInitialized(libmpv:)`）；
/// 2. 否则按平台候选名尝试 `dlopen`，候选与 `lib/core/mpv_start_option.dart`
///    保持一致。
///
/// 返回 null 表示可用；返回字符串表示跳过理由。
library;

import 'dart:ffi';
import 'dart:io';

List<String> _candidateNames() {
  if (Platform.isWindows) return const ['libmpv-2.dll'];
  if (Platform.isMacOS) return const ['libmpv.2.dylib', 'libmpv.dylib'];
  return const ['libmpv.so.2', 'libmpv.so.1', 'libmpv.so'];
}

bool _loads(String name) {
  try {
    DynamicLibrary.open(name);
    return true;
  } catch (_) {
    return false;
  }
}

String? get libmpvUnavailableReason {
  final declared = Platform.environment['WEBHTV_TEST_LIBMPV'];
  if (declared != null && declared.isNotEmpty) return null;
  final names = _candidateNames();
  for (final name in names) {
    if (_loads(name)) return null;
  }
  return '本机没有可加载的 libmpv 内核（${names.join(' / ')} 都打不开；'
      '可用 WEBHTV_TEST_LIBMPV 指定内核路径）';
}
