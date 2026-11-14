/// 「最后一次使用的配置」记忆（Phase 10）。
///
/// ## 为什么单独一个文件而不是塞进 `settings.json`
///
/// `settings.json` 已经有 **两个** 写盘者（`ui` 与 `sync` 段，见
/// `services/settings_file.dart`）。第三个写盘者会把「丢更新」这类缺陷的
/// 排查成本再抬一档，而这份记录只有 6 个字段、与任何设置项都没有关系。
///
/// ## 为什么用同步 IO + 原子写
///
/// 对齐 [SessionRecoveryStore]：文件 < 1 KiB，同步读写是微秒级；而这条记录
/// 决定下次启动要不要探测设备，半写状态会让用户看到一个莫名其妙的横幅。
/// 损坏（截断/手改坏）时按「没有记录」处理——那退回升级前的启动行为，是安全的。
library;

import 'dart:convert';
import 'dart:io';

import '../core/source_key.dart';
import 'log_service.dart';

/// 记忆文件名（位于 `AppPaths.dataDir`）。
const String lastConfigFileName = 'last-config.json';

/// 一条「最后一次使用」的记录。
///
/// 只存**身份**，不存站点内容：内容本来就在 `configs` 表里，再存一份就是
/// 两份真相，迟早对不上。
class LastConfigRecord {
  const LastConfigRecord({
    required this.sourceKey,
    required this.recordId,
    required this.kind,
    required this.savedAt,
    this.deviceUuid = '',
    this.interfaceKey = '',
  });

  /// 播放源标识（`core/source_key.dart`）：`local|<origin>`
  /// 或 `bridge|<deviceUuid>|<interfaceKey>`。**这是恢复时唯一可信的坐标**。
  final String sourceKey;

  /// 当时那条配置记录的 id（本地源记录可能没有 `source_key`，靠它兜底）。
  final int recordId;

  /// [sourceKeyKindLocal] 或 [sourceKeyKindBridge]。
  final String kind;

  /// 桥接源所属设备 uuid；本地源为空串。
  final String deviceUuid;

  /// 桥接源在安卓端的 `interfaceKey`；本地源为空串。
  final String interfaceKey;

  final DateTime savedAt;

  bool get isBridge => kind == sourceKeyKindBridge;

  bool get isLocal => kind == sourceKeyKindLocal;

  Map<String, Object?> toJson() => {
    'sourceKey': sourceKey,
    'recordId': recordId,
    'kind': kind,
    'deviceUuid': deviceUuid,
    'interfaceKey': interfaceKey,
    'savedAt': savedAt.millisecondsSinceEpoch,
  };

  /// 解析磁盘内容；任何无法识别的输入都返回 `null`（当没有记录）。
  ///
  /// 身份以 [sourceKey] 为准，不采信文件里单独的 `kind`/`deviceUuid`：
  /// 两个字段一旦手改出矛盾，按 sourceKey 解析才只有一种解释。
  static LastConfigRecord? tryParse(Object? value) {
    if (value is! Map) return null;
    final sourceKey = (value['sourceKey'] as String? ?? '').trim();
    final parsed = parseSourceKey(sourceKey);
    if (!parsed.isKnown) return null;
    final recordId = value['recordId'];
    if (recordId is! int || recordId <= 0) return null;
    final savedAtMs = value['savedAt'];
    return LastConfigRecord(
      sourceKey: sourceKey,
      recordId: recordId,
      kind: parsed.kind,
      deviceUuid: parsed.deviceUuid,
      interfaceKey: parsed.interfaceKey,
      savedAt: DateTime.fromMillisecondsSinceEpoch(
        savedAtMs is int ? savedAtMs : 0,
      ),
    );
  }

  @override
  String toString() =>
      'LastConfigRecord($kind $recordId $sourceKey)';
}

/// `<dataDir>/last-config.json` 的读写。
class LastConfigStore {
  LastConfigStore({
    required this.dataDir,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String dataDir;

  /// 失败日志（可为 null）。
  final LogService? log;
  final DateTime Function() _now;

  String get path => '$dataDir${Platform.pathSeparator}$lastConfigFileName';

  /// 读取记忆；文件不存在/损坏时返回 `null`。
  LastConfigRecord? read() {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return LastConfigRecord.tryParse(jsonDecode(file.readAsStringSync()));
    } catch (error) {
      log?.warning('读取上次使用的配置失败（按没有记录处理）：$error',
          scope: 'config');
      return null;
    }
  }

  /// 写入记忆；返回是否真的落到磁盘。
  bool write(LastConfigRecord record) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      final temp = File('$path.tmp');
      temp.writeAsStringSync(jsonEncode(record.toJson()), flush: true);
      if (file.existsSync()) file.deleteSync();
      temp.renameSync(path);
      return true;
    } catch (error) {
      log?.warning('写入上次使用的配置失败：$error', scope: 'config');
      return false;
    }
  }

  /// 用一条现成的来源信息记录（`savedAt` 取当前时间）。
  LastConfigRecord? remember({
    required String sourceKey,
    required int recordId,
  }) {
    final parsed = parseSourceKey(sourceKey);
    if (!parsed.isKnown) return null;
    final record = LastConfigRecord(
      sourceKey: sourceKey.trim(),
      recordId: recordId,
      kind: parsed.kind,
      deviceUuid: parsed.deviceUuid,
      interfaceKey: parsed.interfaceKey,
      savedAt: _now(),
    );
    return write(record) ? record : null;
  }

  /// 删除记忆（记录已失效/用户已删除）。
  void clear() {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (error) {
      log?.warning('清理上次使用的配置失败：$error', scope: 'config');
    }
  }
}
