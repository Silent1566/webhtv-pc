/// 测试用临时目录清理：Windows 上「文件仍被占用」不应让用例失败。
///
/// 背景：Linux 允许删除已打开的文件，Windows 会抛 `PathAccessException`。
/// beta 的详情推荐测试在 `addTearDown` 里直接 `deleteSync(recursive: true)`，
/// 于是 Windows 下 SQLite/log 句柄还没释放就整条用例变红——那是环境差异，
/// 不是被测逻辑的问题。
library;

import 'dart:io';

/// 尽力删除；失败先重试几次（给句柄释放一点时间），仍失败就留下目录不报错。
Future<void> deleteTempDirBestEffort(Directory dir) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return;
    } catch (_) {
      await Future<void>.delayed(Duration(milliseconds: 20 * (attempt + 1)));
    }
  }
}

/// 同步版本，签名与 `addTearDown(() => dir.deleteSync(...))` 兼容。
void deleteTempDirBestEffortSync(Directory dir) {
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      return;
    } catch (_) {
      // 句柄未释放：睡一下再试，最后一次失败就放弃（临时目录残留无害）。
      sleep(const Duration(milliseconds: 20));
    }
  }
}
