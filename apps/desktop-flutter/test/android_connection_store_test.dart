/// 已连接安卓环境 MVP · 连接描述存储（`AndroidConnectionStore`）。
///
/// 合同（spec「Integration decisions」2026-11-24）：
/// - 记录住在自己的文件里（`configDir/android_connections.json`），不进
///   settings.json、不进 deviceHistory：选中的 AVD/自动接入目标必须能在
///   `/device` 从没回过话之前就被重连，而 deviceHistory 只存 reachableBase。
/// - 只存**连接描述**（`AndroidAdbProfile`）+ 附带 uuid/名字/时间，永不存转发端口。
/// - 去重键是 `profile.connectionKey`，不是 uuid：同一台设备可以有两种连接描述
///   （网络地址 / USB 序列号），uuid 只是接入成功后回填的附带信息。
/// - 文件缺失/损坏/版本不认识/单条记录坏了都不许把异常抛进启动流程。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/android_adb_profile.dart';
import 'package:webhtv_pc/services/android_connection_store.dart';
import 'package:webhtv_pc/services/log_service.dart';

/// 一条记录在磁盘上的键集合：多一个字段都算「多存了东西」。
const Set<String> recordKeys = {'profile', 'deviceUuid', 'name', 'lastUsedMs'};

/// `AndroidAdbProfile.toJson()` 的键集合（版本 1 描述，无转发端口）。
const Set<String> profileKeys = {
  'version',
  'mode',
  'target',
  'adbPath',
  'emulatorPath',
  'avdHome',
  'serverPort',
  'gatewayPort',
};

void main() {
  late Directory tempDir;
  late String path;
  late LogService log;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('webhtv-adb-conn-');
    path = p.join(tempDir.path, 'android_connections.json');
    log = LogService();
  });

  tearDown(() async {
    await log.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 显式构造 AVD 描述（含借用 ADB 服务器端口 5038），不用默认值糊过去。
  AndroidAdbProfile avdProfile() => AndroidAdbProfile(
    mode: AndroidAdbMode.avd,
    target: 'Pixel_7_API_34',
    adbPath: '/home/u/sdk/platform-tools/adb',
    emulatorPath: '/home/u/sdk/emulator/emulator',
    avdHome: '/home/u/.android/avd',
    serverPort: 5038,
    gatewayPort: 9978,
  );

  /// 把磁盘内容读成 Map（测试自己解析，不信存储层给的解析结果）。
  Map<String, Object?> readFile() =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

  void writeFile(String text) => File(path).writeAsStringSync(text);

  /// 一条手写的记录字面量（模拟历史版本写下的文件内容）。
  Map<String, Object?> recordLiteral({
    required String mode,
    required String target,
    required int lastUsedMs,
    String adbPath = '',
    String emulatorPath = '',
    String avdHome = '',
    int serverPort = 5037,
    int gatewayPort = 9978,
    String deviceUuid = '',
    String name = '',
  }) => {
    'profile': {
      'version': 1,
      'mode': mode,
      'target': target,
      'adbPath': adbPath,
      'emulatorPath': emulatorPath,
      'avdHome': avdHome,
      'serverPort': serverPort,
      'gatewayPort': gatewayPort,
    },
    'deviceUuid': deviceUuid,
    'name': name,
    'lastUsedMs': lastUsedMs,
  };

  group('往返（AVD 描述 + 借用服务器端口）', () {
    test('remember 落盘，新实例 load 后描述逐字段相同', () async {
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();
      final profile = avdProfile();

      final saved = await store.remember(
        profile,
        deviceUuid: 'uuid-avd-1',
        name: 'Pixel 7',
      );
      expect(saved, isNotNull);
      expect(store.records.length, 1);
      expect(identical(store.latest, saved), isTrue);
      // 原子写：不留 .tmp
      expect(File('$path.tmp').existsSync(), isFalse);

      final reopened = AndroidConnectionStore(path: path, log: log);
      await reopened.load();
      expect(reopened.records.length, 1);
      final record = reopened.records.single;
      expect(record.profile.mode, AndroidAdbMode.avd);
      expect(record.profile.target, 'Pixel_7_API_34');
      expect(record.profile.adbPath, '/home/u/sdk/platform-tools/adb');
      expect(record.profile.emulatorPath, '/home/u/sdk/emulator/emulator');
      expect(record.profile.avdHome, '/home/u/.android/avd');
      expect(record.profile.serverPort, 5038);
      expect(record.profile.gatewayPort, 9978);
      expect(record.deviceUuid, 'uuid-avd-1');
      expect(record.name, 'Pixel 7');
      expect(record.lastUsedMs, saved!.lastUsedMs);
      // 连接身份跨序列化不变（去重键稳定）
      expect(record.profile.connectionKey, profile.connectionKey);
      expect(reopened.forKey(profile.connectionKey), isNotNull);
      expect(reopened.forUuid('uuid-avd-1'), isNotNull);
    });

    test('网络模式默认端口规范化后写进文件的 target 是 host:5555', () async {
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();
      final profile = AndroidAdbProfile(
        mode: AndroidAdbMode.network,
        target: '192.168.50.3',
      );
      await store.remember(profile, name: '客厅盒子');

      final raw = readFile();
      final records = raw['records'] as List;
      final profileJson = (records.single as Map)['profile'] as Map;
      expect(profileJson['target'], '192.168.50.3:5555');
      expect(profileJson['mode'], 'network');
      expect(profileJson['serverPort'], 5037);
    });
  });

  group('去重与最近使用', () {
    test('同一 connectionKey 只留一条，deviceUuid/名字更新、lastUsedMs 变大', () async {
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();
      final profile = avdProfile();

      final first = await store.remember(profile, name: '旧名字');
      expect(first, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final second = await store.remember(
        profile,
        deviceUuid: 'uuid-avd-1',
        name: '新名字',
      );

      expect(store.records.length, 1);
      expect(second!.lastUsedMs, greaterThan(first!.lastUsedMs));
      expect(store.records.single.deviceUuid, 'uuid-avd-1');
      expect(store.records.single.name, '新名字');

      final reopened = AndroidConnectionStore(path: path, log: log);
      await reopened.load();
      expect(reopened.records.length, 1);
      expect(reopened.records.single.lastUsedMs, second.lastUsedMs);
    });

    test('uuid 只是附带信息：同一设备两种连接描述是两条记录，forUuid 取最近', () async {
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();
      final network = AndroidAdbProfile(
        mode: AndroidAdbMode.network,
        target: '192.168.50.3:5555',
      );
      final usb = AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M1234XY',
      );
      await store.remember(network, deviceUuid: 'dev-1', name: '盒子（Wi-Fi）');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.remember(usb, deviceUuid: 'dev-1', name: '盒子（USB）');

      expect(store.records.length, 2);
      expect(store.forKey(network.connectionKey), isNotNull);
      expect(store.forKey(usb.connectionKey), isNotNull);
      expect(store.forUuid('dev-1')!.profile.mode, AndroidAdbMode.device);
      expect(store.latest!.profile.mode, AndroidAdbMode.device);
      // uuid 从不当作 profile 的键
      expect(store.forKey('dev-1'), isNull);
      expect(store.forUuid(''), isNull);
      expect(store.forUuid('unknown-uuid'), isNull);
    });

    test('remember 未显式给 uuid/名字时保留已有记录的身份', () async {
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();
      final profile = avdProfile();
      await store.remember(profile, deviceUuid: 'uuid-avd-1', name: 'Pixel 7');
      await store.remember(profile);

      expect(store.records.single.deviceUuid, 'uuid-avd-1');
      expect(store.records.single.name, 'Pixel 7');
    });
  });

  group('读取：latest / forUuid / forKey / forget', () {
    test('latest 取 lastUsedMs 最大的记录，与文件里先后顺序无关', () async {
      writeFile(
        jsonEncode({
          'version': 1,
          'records': [
            recordLiteral(
              mode: 'device',
              target: 'OLDER-SERIAL',
              lastUsedMs: 1000,
              deviceUuid: 'uuid-old',
            ),
            recordLiteral(
              mode: 'network',
              target: '192.168.50.3:5555',
              lastUsedMs: 2000,
              deviceUuid: 'uuid-new',
            ),
          ],
        }),
      );
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();

      expect(store.records.length, 2);
      expect(store.records.first.deviceUuid, 'uuid-new');
      expect(store.latest!.lastUsedMs, 2000);
      expect(store.forUuid('uuid-old')!.profile.target, 'OLDER-SERIAL');
      expect(store.forUuid('uuid-new')!.profile.target, '192.168.50.3:5555');
    });

    test('文件里同一描述出现两次时只保留 lastUsedMs 更大的那条', () async {
      writeFile(
        jsonEncode({
          'version': 1,
          'records': [
            recordLiteral(
              mode: 'avd',
              target: 'Pixel_7_API_34',
              lastUsedMs: 300,
              name: '旧',
            ),
            recordLiteral(
              mode: 'avd',
              target: 'Pixel_7_API_34',
              lastUsedMs: 900,
              name: '新',
            ),
          ],
        }),
      );
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();

      expect(store.records.length, 1);
      expect(store.records.single.name, '新');
      expect(store.records.single.lastUsedMs, 900);
    });

    test('forget 按 connectionKey 删除并落盘，删不存在的键不抛异常', () async {
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();
      final keep = AndroidAdbProfile(
        mode: AndroidAdbMode.network,
        target: '192.168.50.3:5555',
      );
      final drop = AndroidAdbProfile(
        mode: AndroidAdbMode.device,
        target: 'R58M1234XY',
      );
      await store.remember(keep, name: '保留');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.remember(drop, name: '删除');

      await store.forget(drop.connectionKey);
      expect(store.records.length, 1);
      expect(store.forKey(drop.connectionKey), isNull);
      expect(store.latest!.name, '保留');

      await store.forget('不存在的键');
      expect(store.records.length, 1);

      final reopened = AndroidConnectionStore(path: path, log: log);
      await reopened.load();
      expect(reopened.records.length, 1);
      expect(reopened.records.single.name, '保留');
    });
  });

  group('容错：启动流程绝不因这份文件抛异常', () {
    test('文件缺失 → 空列表', () async {
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();
      expect(store.records, isEmpty);
      expect(store.latest, isNull);
    });

    test('JSON 截断/不是对象/版本不认识 → 视为没有记录', () async {
      final broken = [
        '{"version":1,"records":[{"profile":',
        '[]',
        '不是 JSON',
        jsonEncode({'version': 2, 'records': <Object?>[]}),
        jsonEncode({'version': '1', 'records': <Object?>[]}),
        jsonEncode({'records': <Object?>[]}),
      ];
      for (final text in broken) {
        writeFile(text);
        final store = AndroidConnectionStore(path: path, log: log);
        await store.load();
        expect(store.records, isEmpty, reason: '文件内容：$text');
      }
    });

    test('单条记录坏了只丢那一条，好的照旧可用', () async {
      writeFile(
        jsonEncode({
          'version': 1,
          'records': [
            'not-a-record',
            <String, Object?>{},
            {'profile': 'not-a-map', 'lastUsedMs': 5},
            {
              'profile': {
                'version': 1,
                'mode': 'usb',
                'target': 'X',
                'serverPort': 5037,
                'gatewayPort': 9978,
              },
              'lastUsedMs': 6,
            },
            {
              'profile': {
                'version': 2,
                'mode': 'device',
                'target': 'FUTURE',
                'serverPort': 5037,
                'gatewayPort': 9978,
              },
              'lastUsedMs': 7,
            },
            recordLiteral(
              mode: 'device',
              target: 'R58M1234XY',
              lastUsedMs: 800,
              deviceUuid: 'uuid-good',
            ),
          ],
        }),
      );
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();

      expect(store.records.length, 1);
      expect(store.records.single.profile.target, 'R58M1234XY');
      expect(store.forUuid('uuid-good'), isNotNull);
    });

    test('记录缺 lastUsedMs/名字/uuid 时仍可用（默认 0/空串）', () async {
      writeFile(
        jsonEncode({
          'version': 1,
          'records': [
            {
              'profile': {
                'version': 1,
                'mode': 'device',
                'target': 'R58M1234XY',
                'serverPort': 5037,
                'gatewayPort': 9978,
              },
            },
          ],
        }),
      );
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();

      expect(store.records.length, 1);
      expect(store.records.single.lastUsedMs, 0);
      expect(store.records.single.deviceUuid, '');
      expect(store.records.single.name, '');
    });
  });

  group('不存转发端口', () {
    test('文件里只有 profile/deviceUuid/name/lastUsedMs，描述里没有转发端口', () async {
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();
      await store.remember(
        avdProfile(),
        deviceUuid: 'uuid-avd-1',
        name: 'Pixel 7',
      );

      final raw = File(path).readAsStringSync();
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      expect(decoded.keys.toSet(), {'version', 'records'});
      expect(decoded['version'], 1);

      final records = decoded['records'] as List;
      final record = records.single as Map<String, Object?>;
      expect(record.keys.toSet(), recordKeys);
      final profileJson = record['profile'] as Map<String, Object?>;
      expect(profileJson.keys.toSet(), profileKeys);

      // 转发端口是运行期 adb 分配的本机端口，永远不进这份文件。
      expect(raw.contains('forward'), isFalse);
      expect(raw.contains('127.0.0.1'), isFalse);
      expect(raw.contains('localhost'), isFalse);
      expect(profileJson['gatewayPort'], 9978);
      expect(profileJson['serverPort'], 5038);

      // 序列化 + 重读完全相等（含 connectionKey）
      final reopened = AndroidConnectionStore(path: path, log: log);
      await reopened.load();
      expect(
        reopened.records.single.profile.connectionKey,
        store.records.single.profile.connectionKey,
      );
      expect(
        jsonEncode(reopened.records.single.toJson()),
        jsonEncode(store.records.single.toJson()),
      );
    });

    test('copyWith 只改给定字段，profile 与身份保持不变', () async {
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();
      final saved = await store.remember(avdProfile(), name: 'Pixel 7');

      final renamed = saved!.copyWith(name: 'Pixel 7（改名）', lastUsedMs: 42);
      expect(renamed.name, 'Pixel 7（改名）');
      expect(renamed.lastUsedMs, 42);
      expect(renamed.deviceUuid, saved.deviceUuid);
      expect(renamed.profile.connectionKey, saved.profile.connectionKey);
      expect(renamed.toJson().keys.toSet(), recordKeys);
    });
  });

  group('原子替换：提交前旧文件不消失，失败不动旧文件', () {
    AndroidAdbProfile deviceProfile(String serial) =>
        AndroidAdbProfile(mode: AndroidAdbMode.device, target: serial);

    test('替换失败：旧文件字节不变、remember 返回 null、内存与磁盘都不变', () async {
      var failReplace = false;
      FileSystemException? injected;
      final store = AndroidConnectionStore(
        path: path,
        log: log,
        replace: (temp, target) {
          if (failReplace) {
            injected = FileSystemException('注入的替换失败', target);
            throw injected!;
          }
          // 生产语义：一次 rename 覆盖，旧文件在提交那一刻才被替换。
          temp.renameSync(target);
        },
      );
      await store.load();
      await store.remember(deviceProfile('R58M1234XY'), name: '盒子');
      final before = File(path).readAsStringSync();

      failReplace = true;
      final failed = await store.remember(
        deviceProfile('NEW-SERIAL'),
        name: '新盒子',
      );

      expect(injected, isNotNull);
      expect(failed, isNull);
      expect(store.records.length, 1);
      expect(store.records.single.name, '盒子');
      expect(store.forKey(deviceProfile('NEW-SERIAL').connectionKey), isNull);
      // 磁盘上的旧记录一个字节都没变（不是「被自己删掉了」）
      expect(File(path).readAsStringSync(), before);
      // 临时文件不留在磁盘上
      expect(File('$path.tmp').existsSync(), isFalse);
      // 失败必须留下可查日志，不能静默
      expect(
        log.entries.any((entry) => entry.message.contains('写入安卓连接记录失败')),
        isTrue,
      );

      // 重开：仍是那一条旧记录（旧文件真的还在）
      final reopened = AndroidConnectionStore(path: path, log: log);
      await reopened.load();
      expect(reopened.records.length, 1);
      expect(reopened.records.single.name, '盒子');

      // 同一失败条件下 forget 也不改内存/磁盘
      await store.forget(deviceProfile('R58M1234XY').connectionKey);
      expect(store.records.length, 1);
      expect(File(path).readAsStringSync(), before);

      // 失败恢复后照常可写
      failReplace = false;
      final ok = await store.remember(deviceProfile('NEW-SERIAL'), name: '新盒子');
      expect(ok, isNotNull);
      expect(store.records.length, 2);
    });

    test('提交那一刻旧文件仍在磁盘上（不存在「先删旧文件」的空窗）', () async {
      final commits = <({bool existed, String? content})>[];
      final store = AndroidConnectionStore(
        path: path,
        log: log,
        replace: (temp, target) {
          final existing = File(target);
          final present = existing.existsSync();
          commits.add((
            existed: present,
            content: present ? existing.readAsStringSync() : null,
          ));
          temp.renameSync(target); // 真正的提交：一次 rename 覆盖
        },
      );
      await store.load();
      await store.remember(deviceProfile('R58M1234XY'), name: '盒子');
      final before = File(path).readAsStringSync();
      await store.remember(deviceProfile('NEW-SERIAL'), name: '新盒子');

      expect(commits, hasLength(2));
      expect(commits.first.existed, isFalse); // 第一次写：还没有旧文件
      expect(commits.last.existed, isTrue, reason: '提交时旧文件必须还在磁盘上');
      expect(commits.last.content, before, reason: '旧内容必须完整保留到提交时刻');
      // 覆盖生效：文件里是两条记录（没有预删除也一样能替换）
      final now =
          jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
      expect(now['records'], hasLength(2));
    });

    test('临时文件写不进去（.tmp 是目录）：旧文件不变、返回 null、内存不变', () async {
      final store = AndroidConnectionStore(path: path, log: log);
      await store.load();
      await store.remember(deviceProfile('R58M1234XY'), name: '盒子');
      final before = File(path).readAsStringSync();

      final blocker = Directory('$path.tmp')..createSync();
      addTearDown(() {
        if (blocker.existsSync()) blocker.deleteSync(recursive: true);
      });

      final failed = await store.remember(
        deviceProfile('NEW-SERIAL'),
        name: '新盒子',
      );
      expect(failed, isNull);
      expect(store.records.length, 1);
      expect(File(path).readAsStringSync(), before);

      blocker.deleteSync(recursive: true);
      final ok = await store.remember(deviceProfile('NEW-SERIAL'), name: '新盒子');
      expect(ok, isNotNull);
      expect(store.records.length, 2);
    });
  });

  group('toString 不外泄私有身份', () {
    test('不打印 target（序列号/LAN 地址/AVD 名）与完整 uuid，保留模式/名字/时间', () {
      final record = AndroidConnectionRecord(
        profile: AndroidAdbProfile(
          mode: AndroidAdbMode.device,
          target: 'R58M1234XY',
        ),
        deviceUuid: 'a1b2c3d4e5f6',
        name: 'Pixel 7',
        lastUsedMs: 1700000000123,
      );

      final text = record.toString();
      // 缺失断言（不是把 toString 的格式再抄一遍）：私有身份不得出现
      expect(text.contains('R58M1234XY'), isFalse, reason: 'target 是硬件身份');
      expect(text.contains('a1b2c3d4e5f6'), isFalse);
      // 仍有诊断价值
      expect(text.contains('a1b2****'), isTrue);
      expect(text.contains('device'), isTrue);
      expect(text.contains('Pixel 7'), isTrue);
      expect(text.contains('1700000000123'), isTrue);
    });

    test('网络地址与 AVD 名同样不外泄；未命名时不出现空 name=', () {
      final network = AndroidConnectionRecord(
        profile: AndroidAdbProfile(
          mode: AndroidAdbMode.network,
          target: '192.168.50.3:5555',
        ),
        deviceUuid: 'dev-1',
      );
      expect(network.toString().contains('192.168.50.3'), isFalse);
      expect(network.toString().contains('dev-1'), isFalse);
      expect(network.toString(), contains('network'));

      final avd = AndroidConnectionRecord(
        profile: AndroidAdbProfile(
          mode: AndroidAdbMode.avd,
          target: 'Pixel_7_API_34',
        ),
      );
      expect(avd.toString().contains('Pixel_7_API_34'), isFalse);
      expect(avd.toString().contains('****'), isTrue, reason: '空 uuid 也要打码');
      expect(avd.toString().contains('name='), isFalse);
    });
  });
}
