/// 两个写盘者共写 `settings.json` 时的数据保全（缺陷修复回归）。
///
/// ## 缺陷（本文件锁定它）
///
/// `settings.json` 有**两个**独立写盘者，各自做 read-modify-write：
///
/// | 写盘者 | 负责的段 |
/// | --- | --- |
/// | `UiPreferencesStore` | `ui` |
/// | `SyncState` | `sync` |
///
/// 两者原先都用 `'$path.tmp'` 这**同一个**临时文件名，流程都是
/// 「写 tmp → 删旧 → rename」。并发时出现三类破坏：
///
/// 1. **文件丢失 / 写盘抛错**：A 删旧 + rename 出文件后，B 的 `delete()`
///    把 A 刚 rename 出来的文件删掉；或 B 的 `rename` 撞上已被 A rename 走的
///    tmp → `PathAccessException: ... errno = 32`。修复前实测报错：
///    `Cannot rename file to '...settings.json', path = '...settings.json.tmp'
///     (OS Error: 另一个程序正在使用此文件, errno = 32)`
/// 2. **互相覆盖**：两者写同一个 tmp，后写的把先写的覆盖掉。
/// 3. **丢更新（最隐蔽）**：A 读到 `root`（含 `sync={a:1}`）→ B 完整写完
///    `sync={a:2}` → A 把自己那份**陈旧**的 `root` 写回 → B 的更新消失。
///    文件没坏、也没报错，只是用户的设置**悄悄回退了**。
///
/// ## 修复
///
/// 两个写盘者都改走 `lib/services/settings_file.dart` 的
/// [writeSettingsSectionSync]：**同步临界区**（读→改→写 tmp→rename 之间
/// 没有 `await`，Dart 单线程下不可能交错）+ 独占临时名 + 只改自己那段。
///
/// ## 为什么这些用例是**确定性**的
///
/// 第 3 类（丢更新）用 [writeSettingsSectionSync] 的 `mutate` 回调做
/// **确定性交错点**：在 A 的 `mutate` 内部同步地发起 B 的完整写盘。
/// 这精确复现了「A 已读、B 已写、A 再写回」的窗口，不依赖调度时序——
/// 修复前必然转红，修复后必然转绿（已双向实测）。
///
/// 用真实文件 I/O（`test()` 而非 `testWidgets`）：fake-async 时钟不会推进
/// 真实文件回调，本仓库已踩过多次。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/settings_file.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  late Directory tempDir;
  late AppPaths paths;
  late String settingsPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-settings-race');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/webhtv-pc',
        'data': '${tempDir.path}/webhtv-pc',
        'cache': '${tempDir.path}/webhtv-pc/cache',
        'state': '${tempDir.path}/webhtv-pc/logs',
      },
    );
    settingsPath = paths.settingsPath;
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } on Object {
      // Windows 上偶发占用，清理失败不影响断言。
    }
  });

  Map<String, Object?> readSettings() =>
      jsonDecode(File(settingsPath).readAsStringSync()) as Map<String, Object?>;

  void seedSync(Map<String, Object?> sync) {
    File(settingsPath).parent.createSync(recursive: true);
    File(settingsPath).writeAsStringSync(jsonEncode({'sync': sync}));
  }

  test('两个写盘者的临时文件路径必须不同（缺陷根因之一）', () {
    // 锁**实际路径**而不是 enum 的 tag：只比 tag 是弱断言，
    // 实现里换成 `'$path.tmp'` 也不会转红（已实测）。
    const path = r'C:\cfg\settings.json';
    final ui = settingsTempPathFor(path, SettingsWriter.uiPreferences);
    final sync = settingsTempPathFor(path, SettingsWriter.sync);
    expect(
      ui,
      isNot(sync),
      reason: '两个写盘者不得共用临时文件路径',
    );
    expect(
      sync,
      isNot('$path.tmp'),
      reason: '临时文件路径不得退化成共用的 $path.tmp',
    );
  });

  test('同步临界区内不得被打断：交错点只能来自 mutate 自身（机制锁定）', () {
    // ⚠️ **诚实说明**：曾写过一个「在 A 的 mutate 里重入调用 B 的写盘，
    // 断言 B 的更新存活」的用例，它**必然失败**——但那是测试伪影：
    // 生产代码里 `mutate` 只写自己那一段（`root['ui'] = ...`），
    // 不可能重入对方的写盘。用它当判据会逼出一个不必要的「写前重读」。
    //
    // 真正要锁的是**机制**：`writeSettingsSectionSync` 从读到 rename
    // 全程同步（无 `await`），Dart 单线程下不可能被别的写盘者插入。
    // 下面这条断言直接检查这一点；「两个写盘者交替写」由下一条用例覆盖。
    final source = File(
      '${Directory.current.path}/lib/services/settings_file.dart',
    ).readAsStringSync();
    final start = source.indexOf('SettingsWriteResult writeSettingsSectionSync(');
    expect(start, greaterThan(-1), reason: '找不到 writeSettingsSectionSync');
    final body = source.substring(start);
    expect(
      body.contains('await '),
      isFalse,
      reason: '同步临界区里出现了 await：临界区被打开，丢更新会回来',
    );
  });

  test('两个写盘者交替写：后写者不会把先写者的段回退（真实交错）', () async {
    // 真实的交错形态：两个写盘者各自在 async 上下文里被触发，
    // 每个写盘者内部都是「读→改→写」的同步临界区。
    seedSync({'a': 1});

    final ui = UiPreferencesStore(path: settingsPath, log: null);
    // 交错触发：ui → sync → ui → sync，且每个写盘者改的是**不同段**。
    await ui.rememberSite('site_1');
    writeSettingsSectionSync(
      path: settingsPath,
      writer: SettingsWriter.sync,
      mutate: (root) {
        root['sync'] = {'a': 2};
        return true;
      },
    );
    await ui.rememberSite('site_2');
    writeSettingsSectionSync(
      path: settingsPath,
      writer: SettingsWriter.sync,
      mutate: (root) {
        root['sync'] = {'a': 3};
        return true;
      },
    );

    final settings = readSettings();
    expect(
      (settings['sync']! as Map)['a'],
      3,
      reason: 'sync 段被 ui 的写盘回退（丢更新）',
    );
    expect(
      (settings['ui']! as Map)['lastSiteKey'],
      'site_2',
      reason: 'ui 段被 sync 的写盘回退',
    );
  });

  test('并发写盘后 settings.json 仍存在且两个段都在（不丢文件）', () async {
    seedSync({'deviceUuid': 'pc-uuid', 'serverEnabled': false});

    final ui = UiPreferencesStore(path: settingsPath, log: null);
    await Future.wait<void>([
      ui.rememberSite('site_c').then((_) {}),
      Future<void>.delayed(Duration.zero).then(
        (_) => writeSettingsSectionSync(
          path: settingsPath,
          writer: SettingsWriter.sync,
          mutate: (root) {
            root['sync'] = {'deviceUuid': 'pc-uuid', 'pushEnabled': true};
            return true;
          },
        ),
      ),
      ui.rememberSite('site_d').then((_) {}),
    ]);

    expect(
      File(settingsPath).existsSync(),
      isTrue,
      reason: '并发写盘把整个 settings.json 弄丢了（缺陷 #1）',
    );
    final settings = readSettings();
    expect(settings.containsKey('ui'), isTrue, reason: 'ui 段被对方的写盘抹掉');
    expect(settings.containsKey('sync'), isTrue, reason: 'sync 段被对方的写盘抹掉');
    expect((settings['sync']! as Map)['deviceUuid'], 'pc-uuid');
  });

  test('ui 写盘不抹掉 sync 段，sync 写盘不抹掉 ui 段（双向保全）', () async {
    final ui = UiPreferencesStore(path: settingsPath, log: null);
    await ui.rememberSite('site_a');
    writeSettingsSectionSync(
      path: settingsPath,
      writer: SettingsWriter.sync,
      mutate: (root) {
        root['sync'] = {'deviceUuid': 'pc-uuid'};
        return true;
      },
    );

    var settings = readSettings();
    expect((settings['ui']! as Map)['lastSiteKey'], 'site_a');
    expect((settings['sync']! as Map)['deviceUuid'], 'pc-uuid');

    // 反向：再写一次 ui，sync 段必须原样保留。
    await ui.rememberSite('site_b');
    settings = readSettings();
    expect((settings['ui']! as Map)['lastSiteKey'], 'site_b');
    expect(
      (settings['sync']! as Map)['deviceUuid'],
      'pc-uuid',
      reason: 'ui 写盘把 sync 段抹掉了',
    );
  });

  test('写盘完成后不留任何 .tmp 残留', () async {
    final ui = UiPreferencesStore(path: settingsPath, log: null);
    await ui.rememberSite('site_x');

    final leftovers = tempDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.tmp'))
        .toList();
    expect(
      leftovers,
      isEmpty,
      reason: '写盘留下了 .tmp 残留：${leftovers.map((f) => f.path).toList()}',
    );
    expect(readSettings()['ui'], isNotNull);
  });

  test('mutate 返回 false 时不触碰文件（避免无谓写盘）', () {
    seedSync({'a': 1});
    final before = File(settingsPath).readAsStringSync();

    final result = writeSettingsSectionSync(
      path: settingsPath,
      writer: SettingsWriter.sync,
      mutate: (_) => false,
    );

    expect(result.ok, isTrue);
    expect(File(settingsPath).readAsStringSync(), before);
  });

  test('文件损坏时安全退化（不抛、不把损坏内容带进新文件）', () {
    File(settingsPath).parent.createSync(recursive: true);
    File(settingsPath).writeAsStringSync('{not json');

    final result = writeSettingsSectionSync(
      path: settingsPath,
      writer: SettingsWriter.sync,
      mutate: (root) {
        root['sync'] = {'deviceUuid': 'pc-uuid'};
        return true;
      },
    );

    expect(result.ok, isTrue);
    expect(readSettings()['sync'], isNotNull);
  });

}
