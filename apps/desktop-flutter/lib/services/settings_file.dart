/// `settings.json` 的**共享原子写盘**（修复两个写盘者互相破坏的缺陷）。
///
/// ## 为什么需要这个文件
///
/// `settings.json` 有**两个**独立写盘者，各自做 read-modify-write：
///
/// | 写盘者 | 负责的段 |
/// | --- | --- |
/// | `UiPreferencesStore`（`lib/services/ui_preferences_store.dart`） | `ui` |
/// | `SyncState`（`lib/state/sync_state.dart`） | `sync` |
///
/// 两者原先都用 `'$path.tmp'` 这**同一个**临时文件名，流程都是
/// 「写 tmp → 删旧 → rename」。并发时会出三类破坏（前两类已实测复现）：
///
/// 1. **整个文件消失 / 写盘抛错**：A 删旧 + rename 出文件后，B 的 `delete()`
///    把 A 刚 rename 出来的文件删掉；或 B 的 `rename` 撞上已被 A rename 走的
///    tmp → `PathAccessException: ... errno = 32`（Windows 文件占用）。
/// 2. **互相覆盖**：两者写同一个 tmp，后写的把先写的覆盖掉。
/// 3. **丢更新（最隐蔽）**：A 读到 `root`（含 `sync={a:1}`）→ B 完整写完
///    `sync={a:2}` → A 把自己那份**陈旧**的 `root` 写回 → B 的更新消失。
///    文件没坏、也没报错，只是**用户的设置悄悄回退了**。
///
/// ## 修法：把临界区做成**同步**的
///
/// 关键洞察：Dart 是单线程的，**没有 `await` 的代码段不会被打断**。
/// 所以只要「读 → 改 → 写 tmp → rename」之间**一个 `await` 都没有**，
/// 两个写盘者就不可能交错——第 1/2/3 类问题同时消失，不需要锁、不需要
/// 跨写盘者协调。
///
/// 这比「引入全局异步锁」更可靠：
/// - 异步锁（`Future` 链 / `Completer`）会把回调调度到**创建该 Future 的
///   zone**，而 widget 测试的 fake-async zone 与 `runAsync` 的真实 zone
///   不同——一跳区就永久挂起（本仓库踩过多次，见 `SyncState._persist` 的注释）；
/// - 同步临界区没有 zone 问题，且**确定性**：不存在「时序刚好才复现」。
///
/// 代价是临界区内阻塞事件循环。这里可以接受：`settings.json` 只有几 KB，
/// 同步读写是微秒级；而丢用户设置是不可接受的。
///
/// ## 为什么保留独占临时名
///
/// 同步临界区已经保证了同进程内不交错，但**别的进程**（例如用户同时开了
/// 两个实例）仍可能碰同一个 tmp。独占名让这种跨进程碰撞的概率降到极低，
/// 且不会让两个写盘者互相覆盖。
library;

import 'dart:convert';
import 'dart:io';

/// 写盘者标识：决定临时文件名，必须**每个写盘者唯一**。
enum SettingsWriter {
  /// `UiPreferencesStore`（`ui` 段）。
  uiPreferences('ui'),

  /// `SyncState`（`sync` 段）。
  sync('sync'),

  aiConfig('ai');

  const SettingsWriter(this.tag);

  /// 临时文件名后缀片段。
  final String tag;
}

/// 某写盘者使用的临时文件路径（**唯一**）。
///
/// 单独抽成函数（而不是内联在写盘函数里）是为了让「两个写盘者的临时名
/// 真的不同」可以被直接断言——只比 enum 的 `tag` 是弱断言，
/// 实现里换成 `'$path.tmp'` 也不会转红。
String settingsTempPathFor(String path, SettingsWriter writer) =>
    '$path.${writer.tag}.tmp';

/// 写盘结果（失败不抛：调用方按自己的口径记日志）。
class SettingsWriteResult {
  const SettingsWriteResult({required this.ok, this.error});

  final bool ok;
  final Object? error;

  @override
  String toString() => ok ? 'ok' : 'failed($error)';
}

/// 读取 `settings.json` 的顶层对象；文件缺失/损坏时返回空表。
///
/// 损坏时返回空表而不是抛错：旧文件坏掉不该让整个应用起不来
/// （与两个写盘者原本的「损坏 → 直接覆盖」口径一致）。
Map<String, Object?> readSettingsRootSync(String path) {
  final file = File(path);
  if (!file.existsSync()) return <String, Object?>{};
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry('$key', value));
    }
  } on Object {
    // 损坏或正在被写：当作空表，由调用方写入自己的段。
  }
  return <String, Object?>{};
}

/// 原子写盘（**同步临界区**）：读回 → 交给 [mutate] 改**自己那一段** →
/// 写独占 tmp → rename。
///
/// [mutate] 收到完整 `root`，只应修改自己负责的键；返回 `false` 表示
/// 「本次无需写盘」（例如值没变），此时不触碰文件。
///
/// **`mutate` 必须是同步的**（签名里没有 `Future`）：一旦它内部 `await`，
/// 临界区就被打开，丢更新会回来。这是本函数存在的全部意义。
///
/// 失败（含重试耗尽）返回 [SettingsWriteResult.ok] 为 false，**不抛异常**：
/// 两个调用点都在 fire-and-forget 路径上（`unawaited(_persist())`），
/// 抛出去只会变成未捕获异常。
SettingsWriteResult writeSettingsSectionSync({
  required String path,
  required SettingsWriter writer,
  required bool Function(Map<String, Object?> root) mutate,
  int attempts = 5,
}) {
  final file = File(path);
  // 独占临时名：不同写盘者绝不共用同一个 tmp。
  final temporary = File(settingsTempPathFor(path, writer));
  Object? lastError;

  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      file.parent.createSync(recursive: true);
      // ⚠️ 从这里到 `renameSync` 之间**不得出现任何 `await`**：
      // 这段的原子性正是本函数的全部价值（见文件头注释）。
      final root = readSettingsRootSync(path);
      if (!mutate(root)) {
        return const SettingsWriteResult(ok: true);
      }
      temporary.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(root),
        flush: true,
      );
      if (file.existsSync()) file.deleteSync();
      temporary.renameSync(path);
      return const SettingsWriteResult(ok: true);
    } on FileSystemException catch (error) {
      lastError = error;
      // Windows 上 delete/rename 可能被**别的进程**短暂占用（errno 32）。
      // 同步阻塞几毫秒再试：占用通常是毫秒级的，而失败会让用户丢掉这次设置。
      sleep(Duration(milliseconds: 10 * (attempt + 1)));
    } on Object catch (error) {
      lastError = error;
      break;
    }
  }

  // 兜底清理：留下 tmp 会让下次写盘读到半成品。
  try {
    if (temporary.existsSync()) temporary.deleteSync();
  } on Object {
    // 清理失败无关紧要。
  }
  return SettingsWriteResult(ok: false, error: lastError);
}
