/// 已连接安卓环境 MVP · 连接描述的持久化（`configDir/android_connections.json`）。
///
/// ## 为什么单独一个文件
///
/// 与 `services/last_config_store.dart` 同一条理由：`settings.json` 已经有两个
/// 写盘者（`ui` / `sync` 段），第三个写盘者会把「丢更新」的排查成本再抬一档；
/// 而这份记录与任何设置项都没有关系。也不能进 `deviceHistory`：那里每一条都是
/// **接入成功之后**才写下的可达地址（`DeviceHistoryEntry.address`），而选中的
/// AVD/自动接入目标必须能在 `/device` 从没回过话之前就被重连——第一次使用时
/// 根本没有 uuid。
///
/// ## 为什么只存连接描述
///
/// 转发端口（`adb forward tcp:0` 拿到的本机端口）每次连接都变，存下来就是
/// 一个下次启动必然失效的坐标（spec：「持久化校验过的描述，绝不单独持久化临时
/// 端口」）。[AndroidAdbProfile] 的表达能力本身就容不下转发端口，这里再断言一次
/// 键集合（`test/android_connection_store_test.dart`）。
///
/// ## 去重键
///
/// [AndroidAdbProfile.connectionKey]（描述的规范化 JSON 摘要），**不是 uuid**：
/// 同一台设备可以有两种连接描述（LAN 地址 / USB 序列号），换了描述就该出现第二条
/// 记录；uuid 只是接入成功后回填的附带信息（[AndroidConnectionRecord.deviceUuid]），
/// 用来「下次重启先找那台设备」而不是用来区分描述。
///
/// ## 容错
///
/// 文件缺失、截断、版本不认识、单条记录坏了，一律按「能用的先用，坏的丢掉」处理，
/// 绝不把异常抛进启动流程（同 `LastConfigStore`）。
library;

import 'dart:convert';
import 'dart:io';

import '../core/android_adb_profile.dart';
import 'log_service.dart';

/// 记忆文件名（位于 `AppPaths.configDir`）。
const String androidConnectionsFileName = 'android_connections.json';

/// 文件格式版本。未来版本一律按「没有记录」处理：不认识的新语义不可猜。
const int androidConnectionsFileVersion = 1;

/// 一条已连接环境：连接描述 + 最近一次接入的证据。
class AndroidConnectionRecord {
  const AndroidConnectionRecord({
    required this.profile,
    this.deviceUuid = '',
    this.name = '',
    this.lastUsedMs = 0,
  });

  /// 连接描述（身份的唯一来源）。
  final AndroidAdbProfile profile;

  /// 最近一次成功 `connect()` 证明过的设备 uuid；空串 = 还没接入成功过。
  ///
  /// **只是附带信息**：绝不参与记录的身份/去重（见文件头注释）。
  final String deviceUuid;

  /// 展示名（设备名/AVD 名）；空串时 UI 自己退化显示。
  final String name;

  /// 最近一次使用的时间（毫秒时间戳），越新越优先。
  final int lastUsedMs;

  /// 去重/查找用的稳定键：由描述规范化得出，跨序列化不变。
  String get connectionKey => profile.connectionKey;

  Map<String, Object?> toJson() => {
    'profile': profile.toJson(),
    'deviceUuid': deviceUuid,
    'name': name,
    'lastUsedMs': lastUsedMs,
  };

  /// 解析磁盘上的一条记录；任何无法识别的输入都返回 `null`（丢掉这一条）。
  static AndroidConnectionRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    final profile = AndroidAdbProfile.fromJson(value['profile']);
    if (profile == null) return null;
    final uuid = value['deviceUuid'];
    final name = value['name'];
    final lastUsedMs = value['lastUsedMs'];
    return AndroidConnectionRecord(
      profile: profile,
      deviceUuid: uuid is String ? uuid.trim() : '',
      name: name is String ? name.trim() : '',
      lastUsedMs: lastUsedMs is int && lastUsedMs > 0 ? lastUsedMs : 0,
    );
  }

  AndroidConnectionRecord copyWith({
    String? deviceUuid,
    String? name,
    int? lastUsedMs,
  }) => AndroidConnectionRecord(
    profile: profile,
    deviceUuid: deviceUuid ?? this.deviceUuid,
    name: name ?? this.name,
    lastUsedMs: lastUsedMs ?? this.lastUsedMs,
  );

  /// 只打印诊断需要的元数据：模式、展示名、使用时间；uuid 打码，**target 不打印**。
  ///
  /// 为什么不打印 target：它可能是 USB 序列号或局域网地址，是硬件身份；
  /// uuid 是设备唯一标识。两者进了日志/错误详情就等于把设备指纹写进诊断包。
  /// 仓库既有口径一致：`SyncPeer.toString()` 用 `maskedUuid`，地址一律走
  /// `redactUrl`（`design/02` §7）。名字是用户可见的展示信息，可以留。
  @override
  String toString() {
    final label = name.isEmpty ? '' : ' name=$name';
    return 'AndroidConnectionRecord(${profile.mode.name}$label '
        'uuid=${_maskedUuid(deviceUuid)} used=$lastUsedMs)';
  }

  /// 打码保留前 4 位（同 `SyncPeer.maskedUuid`）：够区分「哪台」，不够指向设备。
  static String _maskedUuid(String uuid) =>
      uuid.length <= 4 ? '****' : '${uuid.substring(0, 4)}****';
}

/// 提交一步的注入点（默认 = `File.renameSync`）。
///
/// 单独一个函数类型，是为了让「提交失败」这条路径可测（只有测试会注入失败）；
/// 生产实现就是同一目录内的一次 rename。
typedef ConnectionFileReplace = void Function(File temp, String path);

void _renameOver(File temp, String path) => temp.renameSync(path);

/// `<configDir>/android_connections.json` 的读写（同步 IO + 原子写）。
class AndroidConnectionStore {
  AndroidConnectionStore({
    required this.path,
    required this.log,
    this.replace = _renameOver,
  });

  /// 提交这一步（默认 = 同一目录内一次 `File.renameSync`，覆盖式原子提交）。
  ///
  /// 生产路径永远用默认值；只有测试会注入一个会失败的替换，用来验证
  /// 「提交失败不动旧文件」。
  final ConnectionFileReplace replace;

  /// 记录文件路径（由调用方按 `AppPaths` 拼好，存储层不猜目录）。
  final String path;

  /// 读写失败的日志出口。
  final LogService log;

  /// 按「最近使用在前」排好序的记录；未调用 [load] 前为空。
  List<AndroidConnectionRecord> _records = const [];

  List<AndroidConnectionRecord> get records => _records;

  /// 最近使用的那一条（没有记录时为 `null`）。
  AndroidConnectionRecord? get latest =>
      _records.isEmpty ? null : _records.first;

  /// 按设备 uuid 找记录：只用于「上次那台设备用哪种描述接的」，取最近的一条。
  AndroidConnectionRecord? forUuid(String uuid) {
    final key = uuid.trim();
    if (key.isEmpty) return null;
    for (final record in _records) {
      if (record.deviceUuid == key) return record;
    }
    return null;
  }

  /// 按连接描述身份找记录（去重键即此）。
  AndroidConnectionRecord? forKey(String connectionKey) {
    final key = connectionKey.trim();
    if (key.isEmpty) return null;
    for (final record in _records) {
      if (record.connectionKey == key) return record;
    }
    return null;
  }

  /// 读取记录。任何异常都只记日志：这份文件坏了不该挡住应用启动。
  Future<void> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) {
        _records = const [];
        return;
      }
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map ||
          decoded['version'] != androidConnectionsFileVersion) {
        log.warning('安卓连接记录版本不认识（按没有记录处理）', scope: 'android');
        _records = const [];
        return;
      }
      final raw = decoded['records'];
      final kept = <AndroidConnectionRecord>[];
      var dropped = 0;
      if (raw is List) {
        for (final item in raw) {
          final record = AndroidConnectionRecord.fromJson(item);
          if (record == null) {
            dropped++;
          } else {
            kept.add(record);
          }
        }
      } else if (raw != null) {
        dropped++;
      }
      if (dropped > 0) {
        log.warning('安卓连接记录有 $dropped 条无法识别（已丢弃，其余照常读取）', scope: 'android');
      }
      _records = _normalize(kept);
    } catch (error) {
      log.warning('读取安卓连接记录失败（按没有记录处理）：$error', scope: 'android');
      _records = const [];
    }
  }

  /// 记住一条连接描述（同一 `connectionKey` 覆盖旧记录并刷新使用时间）。
  ///
  /// 返回落盘后的记录；写盘失败返回 `null`（内存状态不变，调用方当作没记住）。
  Future<AndroidConnectionRecord?> remember(
    AndroidAdbProfile profile, {
    String deviceUuid = '',
    String name = '',
  }) async {
    final key = profile.connectionKey;
    final previous = forKey(key);
    final record = AndroidConnectionRecord(
      profile: profile,
      // 空值不抹掉已知身份：接入失败/未探测到 uuid 时仍要保住上次的绑定。
      deviceUuid: deviceUuid.trim().isEmpty
          ? (previous?.deviceUuid ?? '')
          : deviceUuid.trim(),
      name: name.trim().isEmpty ? (previous?.name ?? '') : name.trim(),
      lastUsedMs: DateTime.now().millisecondsSinceEpoch,
    );
    // 新记录一定在「最近使用」的最前面：remember 的语义就是「刚刚用过」。
    final next = [
      record,
      for (final item in _records)
        if (item.connectionKey != key) item,
    ];
    if (!_write(next)) return null;
    _records = List.unmodifiable(next);
    return record;
  }

  /// 忘掉一条连接描述（用户删除/设备已不可用）。
  Future<void> forget(String connectionKey) async {
    final key = connectionKey.trim();
    if (key.isEmpty) return;
    final next = [
      for (final item in _records)
        if (item.connectionKey != key) item,
    ];
    if (next.length == _records.length) return;
    if (_write(next)) _records = List.unmodifiable(next);
  }

  /// 排序（使用时间倒序，同一毫秒保持文件顺序）+ 按 `connectionKey` 去重留最新。
  static List<AndroidConnectionRecord> _normalize(
    List<AndroidConnectionRecord> input,
  ) {
    final indexed = [
      for (var index = 0; index < input.length; index++)
        (index: index, record: input[index]),
    ];
    indexed.sort((left, right) {
      final byTime = right.record.lastUsedMs.compareTo(left.record.lastUsedMs);
      return byTime != 0 ? byTime : left.index.compareTo(right.index);
    });
    final seen = <String>{};
    final ordered = <AndroidConnectionRecord>[];
    for (final entry in indexed) {
      if (seen.add(entry.record.connectionKey)) ordered.add(entry.record);
    }
    return List.unmodifiable(ordered);
  }

  /// 原子写：`.tmp` 写完，再用**一次 rename** 提交。
  ///
  /// 为什么**不先删旧文件**（本文件早期版本是 `delete + rename`，
  /// `settings_file.dart` / `session_recovery_store.dart` 里也是同一写法）：
  /// 那两步之间有两个真实缺口——
  /// 1. 目标文件在提交前不存在：此刻崩溃/断电就丢了下一次启动要用的重连目标；
  /// 2. 旧文件删掉之后 rename 才失败：磁盘上的好记录已经被自己删了，而
  ///    `remember` 只返回 `null`，调用方会以为「只是这次没记住」。
  ///
  /// 同一目录内的 rename 是**覆盖式**提交：旧文件直到提交那一刻才被替换，
  /// 写临时文件失败或提交失败都不动旧文件（注入失败的行为见
  /// `test/android_connection_store_test.dart` 的「原子替换」组）。
  ///
  /// 平台差异：Linux/macOS 是 POSIX `rename(2)`（原子替换）；Windows 走
  /// `MoveFileEx(MOVEFILE_REPLACE_EXISTING)`，目标被别的进程以不共享删除的
  /// 方式打开时会失败——失败同样不动旧文件，这里按写失败返回 `null`。
  bool _write(List<AndroidConnectionRecord> records) {
    final temp = File('$path.tmp');
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      temp.writeAsStringSync(
        jsonEncode({
          'version': androidConnectionsFileVersion,
          'records': [for (final record in records) record.toJson()],
        }),
        flush: true,
      );
      replace(temp, path);
      return true;
    } catch (error) {
      log.warning('写入安卓连接记录失败（旧文件保持不变）：$error', scope: 'android');
      // 半成品不留在磁盘上；删不掉也**不改**「这次写失败」这个结论。
      try {
        if (temp.existsSync()) temp.deleteSync();
      } catch (_) {}
      return false;
    }
  }
}
