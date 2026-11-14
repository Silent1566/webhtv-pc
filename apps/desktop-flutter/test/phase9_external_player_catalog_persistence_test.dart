import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/external_player.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  late Directory directory;
  late String settings;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('external-persistence-');
    settings = '${directory.path}/settings.json';
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('历史A显式重新新增后可选择、重载及独立编辑，重扫保留两条', () async {
    const a = r'D:\Players\A.exe';
    const b = r'D:\Players\B.exe';
    const c = r'D:\Players\C.exe';
    const scanned = [ExternalPlayer(name: '扫描A', executable: a)];
    final store = UiPreferencesStore(path: settings);
    await store.load();
    expect(
      await store.saveExternalPlayer(
        originalExecutable: a,
        name: '原记录B',
        executable: b,
        scanned: scanned,
        exists: (_) => true,
      ),
      isTrue,
    );
    expect(store.listExternalPlayers(scanned), const [
      ExternalPlayer(name: '原记录B', executable: b),
    ]);
    expect(
      await store.saveExternalPlayer(
        name: '显式新增A',
        executable: a,
        scanned: scanned,
        exists: (_) => true,
      ),
      isTrue,
      reason: '用户明确新增不同的当前exe，不是重扫自动复活',
    );
    expect(await store.rememberExternalPlayerPath(a), isTrue);
    expect(store.externalPlayerPath, a);
    final restored = UiPreferencesStore(path: settings);
    await restored.load();
    expect(restored.externalPlayerPath, a);
    expect(restored.listExternalPlayers(scanned).toSet(), {
      ExternalPlayer(name: '原记录B', executable: b),
      ExternalPlayer(name: '显式新增A', executable: a),
    });
    expect(
      await restored.saveExternalPlayer(
        originalExecutable: a,
        name: '新记录C',
        executable: c,
        scanned: scanned,
        exists: (_) => true,
      ),
      isTrue,
    );
    expect(restored.externalPlayerPath, c);
    final afterEdit = UiPreferencesStore(path: settings);
    await afterEdit.load();
    expect(afterEdit.listExternalPlayers(scanned).toSet(), {
      ExternalPlayer(name: '原记录B', executable: b),
      ExternalPlayer(name: '新记录C', executable: c),
    });
    final beforeCollision = File(settings).readAsStringSync();
    expect(
      await afterEdit.saveExternalPlayer(
        originalExecutable: c,
        name: '碰撞原记录',
        executable: b,
        scanned: scanned,
        exists: (_) => true,
      ),
      isFalse,
    );
    expect(File(settings).readAsStringSync(), beforeCollision);
  });

  test('失败编辑回滚不覆盖紧随微任务的显式选择，保持原选择失败语义', () async {
    const a = r'D:\Players\A.exe';
    const b = r'D:\Players\B.exe';
    const c = r'D:\Players\C.exe';
    final parent = Directory('${directory.path}/blocked')..createSync();
    final file = File('${parent.path}/settings.json')
      ..writeAsStringSync(
        jsonEncode({
          'ui': {'externalPlayerPath': a},
        }),
      );
    final store = UiPreferencesStore(path: file.path);
    await store.load();
    expect(store.externalPlayerPath, a);
    file.deleteSync();
    parent.deleteSync();
    File(parent.path).writeAsStringSync('阻挡设置父目录');
    const scanned = [
      ExternalPlayer(name: '初始A', executable: a),
      ExternalPlayer(name: '独立C', executable: c),
    ];
    final edit = store.saveExternalPlayer(
      originalExecutable: a,
      name: '失败编辑B',
      executable: b,
      scanned: scanned,
      exists: (_) => true,
    );
    Future<bool>? choice;
    String? observed;
    await Future<void>.microtask(() {
      choice = store.rememberExternalPlayerPath(c);
      observed = store.externalPlayerPath;
    });
    expect(observed, c, reason: '较晚选择即时生效');
    expect(await edit, isFalse);
    expect(await choice!, isFalse, reason: '同一存储阻挡，两次写盘都失败');
    expect(store.externalPlayerPath, c, reason: '编辑只能撤回自身变更，不能还原掉后来的选择');
    expect(store.listExternalPlayers(scanned), scanned);
  });

  test('旧设置只读不写，匹配扫描合并；未匹配旧路径可以编辑和重载', () async {
    const old = r'D:\Gone\old.exe';
    final file = File(settings)
      ..writeAsStringSync(
        jsonEncode({
          'ui': {'externalPlayerPath': old},
          'sync': {'deviceName': '保留'},
          'tmdb': {'language': 'zh'},
        }),
      );
    final before = file.readAsStringSync();
    final store = UiPreferencesStore(path: settings);
    await store.load();
    expect(
      store
          .listExternalPlayers(const [
            ExternalPlayer(name: '扫描', executable: r'd:/gone/OLD.EXE'),
          ])
          .single
          .name,
      '扫描',
    );
    expect(store.listExternalPlayers(const []).single.executable, old);
    expect(file.readAsStringSync(), before);
    expect(
      await store.saveExternalPlayer(
        originalExecutable: old,
        name: '修复',
        executable: r'D:\Fixed\player.exe',
        scanned: const [],
        exists: (_) => true,
      ),
      isTrue,
    );
    final restored = UiPreferencesStore(path: settings);
    await restored.load();
    expect(restored.externalPlayerPath, r'D:\Fixed\player.exe');
    expect(restored.listExternalPlayers(const []).single.name, '修复');
    final raw = jsonDecode(file.readAsStringSync()) as Map;
    expect(raw['sync'], {'deviceName': '保留'});
    expect(raw['tmdb'], {'language': 'zh'});
  });

  test('无效和重复输入不写盘、不污染目录或预选', () async {
    final store = UiPreferencesStore(path: settings);
    await store.load();
    const a = r'D:\Players\a.exe';
    const b = r'D:\Players\b.exe';
    const scanned = [ExternalPlayer(name: '扫描', executable: a)];
    expect(
      await store.saveExternalPlayer(
        name: '自定义',
        executable: b,
        scanned: scanned,
        exists: (_) => true,
      ),
      isTrue,
    );
    final before = File(settings).readAsStringSync();
    for (final path in [
      '',
      'player.exe',
      r'D:\Players\a.cmd',
      r'"D:\Players\a.exe"',
      r'D:\Players\a.exe --arg',
      r'd:/players/A.EXE',
      b,
    ]) {
      expect(
        await store.saveExternalPlayer(
          name: '新增',
          executable: path,
          scanned: scanned,
          exists: (_) => true,
        ),
        isFalse,
        reason: path,
      );
    }
    expect(
      await store.saveExternalPlayer(
        originalExecutable: b,
        name: '  ',
        executable: b,
        scanned: scanned,
        exists: (_) => true,
      ),
      isFalse,
    );
    expect(
      await store.saveExternalPlayer(
        originalExecutable: b,
        name: '失效文件',
        executable: r'D:\Missing\x.exe',
        scanned: scanned,
        exists: (_) => false,
      ),
      isFalse,
    );
    expect(
      await store.saveExternalPlayer(
        originalExecutable: r'D:\Unknown\x.exe',
        name: '未知编辑',
        executable: b,
        scanned: scanned,
        exists: (_) => true,
      ),
      isFalse,
    );
    expect(File(settings).readAsStringSync(), before);
    expect(store.externalPlayerPath, isNull);
    expect(store.listExternalPlayers(scanned).map((p) => p.name), [
      '扫描',
      '自定义',
    ]);
  });

  test('磁盘失败返回 false，回滚名称路径与旧预选，之后可重试', () async {
    const a = r'D:\Players\a.exe';
    const b = r'D:\Players\b.exe';
    final blocker = File('${directory.path}/blocker')
      ..writeAsStringSync('file');
    final store = UiPreferencesStore(path: '${blocker.path}/settings.json');
    await store.load();
    const scanned = [ExternalPlayer(name: '扫描', executable: a)];
    expect(
      await store.saveExternalPlayer(
        originalExecutable: a,
        name: '失败修改',
        executable: b,
        scanned: scanned,
        exists: (_) => true,
      ),
      isFalse,
    );
    expect(store.listExternalPlayers(scanned), scanned);
    expect(store.externalPlayerPath, isNull);
    blocker.deleteSync();
    Directory(blocker.path).createSync();
    expect(
      await store.saveExternalPlayer(
        name: '重试',
        executable: b,
        scanned: scanned,
        exists: (_) => true,
      ),
      isTrue,
    );
    expect(store.listExternalPlayers(scanned).map((p) => p.name), ['扫描', '重试']);
  });

  test('未配置时读目录及保存其他设置不固化播放器默认配置', () async {
    final store = UiPreferencesStore(path: settings);
    await store.load();
    store.listExternalPlayers(const []);
    expect(File(settings).existsSync(), isFalse);
    await store.rememberSite('站点');
    final ui =
        (jsonDecode(File(settings).readAsStringSync()) as Map)['ui'] as Map;
    expect(ui.containsKey('externalPlayers'), isFalse);
    expect(ui.containsKey('externalPlayerPath'), isFalse);
  });

  test('并发新增相同路径仅一个成功，不丢其他配置', () async {
    final store = UiPreferencesStore(path: settings);
    await store.load();
    final results = await Future.wait([
      store.saveExternalPlayer(
        name: '第一',
        executable: r'D:\Player\a.exe',
        scanned: const [],
        exists: (_) => true,
      ),
      store.saveExternalPlayer(
        name: '重复',
        executable: r'd:/player/A.EXE',
        scanned: const [],
        exists: (_) => true,
      ),
      store.rememberThemeMode('light'),
    ]);
    expect(results, [true, false, true]);
    final restored = UiPreferencesStore(path: settings);
    await restored.load();
    expect(restored.listExternalPlayers(const []).single.name, '第一');
    expect(restored.themeMode, 'light');
  });

  test('AppState 新增、重命名和连续改路径通过真实临时文件持久化', () async {
    final executable = File('${directory.path}/player.exe')
      ..writeAsStringSync('fake');
    final nextExecutable = File('${directory.path}/next.exe')
      ..writeAsStringSync('fake');
    final store = UiPreferencesStore(path: settings);
    await store.load();
    final state = AppState(externalPlayerDetector: () => const []);
    addTearDown(state.dispose);
    state.attachUiPreferences(store);
    var notifications = 0;
    state.addListener(() => notifications++);
    expect(
      await state.saveExternalPlayer(name: '新增', executable: executable.path),
      isTrue,
    );
    expect(
      await state.saveExternalPlayer(
        originalExecutable: executable.path,
        name: '更名',
        executable: executable.path,
      ),
      isTrue,
    );
    await state.setExternalPlayerPath(executable.path);
    expect(
      await state.saveExternalPlayer(
        originalExecutable: executable.path,
        name: '改路径',
        executable: nextExecutable.path,
      ),
      isTrue,
    );
    expect(state.externalPlayerPath, nextExecutable.path);
    expect(await state.listExternalPlayers(), [
      ExternalPlayer(name: '改路径', executable: nextExecutable.path),
    ]);
    expect(
      await state.saveExternalPlayer(
        name: '文件失效',
        executable: '${directory.path}/gone.exe',
      ),
      isFalse,
    );
    expect(notifications, 4);
    final restored = UiPreferencesStore(path: settings);
    await restored.load();
    expect(
      restored.listExternalPlayers(const []).single.executable,
      nextExecutable.path,
    );
    expect(restored.externalPlayerPath, nextExecutable.path);
  });

  test('已选条目改路径后预选跟随自身，不被较新条目的历史夺走', () async {
    // 审查者实测的交叉序列：R1 A→B；新增 R2 A 再 A→C；显式选 R1 B；
    // 编辑 R1 B→A 成功；再编辑 R1 A→D 成功。预选必须留在 R1 的 D。
    const a = r'D:\Players\A.exe';
    const b = r'D:\Players\B.exe';
    const c = r'D:\Players\C.exe';
    const d = r'D:\Players\D.exe';
    const scanned = [ExternalPlayer(name: '扫描A', executable: a)];
    final store = UiPreferencesStore(path: settings);
    await store.load();
    Future<bool> edit(String? original, String name, String target) =>
        store.saveExternalPlayer(
          originalExecutable: original,
          name: name,
          executable: target,
          scanned: scanned,
          exists: (_) => true,
        );

    expect(await edit(a, 'R1', b), isTrue);
    expect(await edit(null, 'R2', a), isTrue);
    expect(await edit(a, 'R2', c), isTrue);
    expect(await store.rememberExternalPlayerPath(b), isTrue);
    expect(store.externalPlayerPath, b, reason: '预选 B 属于 R1');

    expect(await edit(b, 'R1', a), isTrue);
    expect(store.externalPlayerPath, a);
    expect(await edit(a, 'R1', d), isTrue);
    expect(
      store.externalPlayerPath,
      d,
      reason: 'A 同时是 R1 历史与 R2 历史，预选归属按被编辑条目判断',
    );

    final reloaded = UiPreferencesStore(path: settings);
    await reloaded.load();
    expect(reloaded.listExternalPlayers(scanned).toSet(), {
      const ExternalPlayer(name: 'R1', executable: d),
      const ExternalPlayer(name: 'R2', executable: c),
    }, reason: '两条目录记录本身都要保留');
    expect(reloaded.externalPlayerPath, d, reason: '重启后不得把预选还原成 R2 的 C');
  });

  test('等价写法的原路径也不夺走预选（大小写与斜线归一化）', () async {
    // 与上一条同一序列，只把最后编辑的原路径换成 Windows 等价写法：
    // `d:/players/A.EXE` 与 `D:\Players\A.exe` 是同一条记录，不能因为
    // 字符串不同就判成“编辑的是未选中的记录”。
    const a = r'D:\Players\A.exe';
    const b = r'D:\Players\B.exe';
    const c = r'D:\Players\C.exe';
    const d = r'D:\Players\D.exe';
    const scanned = [ExternalPlayer(name: '扫描A', executable: a)];
    final store = UiPreferencesStore(path: settings);
    await store.load();
    Future<bool> edit(String? original, String name, String target) =>
        store.saveExternalPlayer(
          originalExecutable: original,
          name: name,
          executable: target,
          scanned: scanned,
          exists: (_) => true,
        );

    expect(await edit(a, 'R1', b), isTrue);
    expect(await edit(null, 'R2', a), isTrue);
    expect(await edit(a, 'R2', c), isTrue);
    expect(await store.rememberExternalPlayerPath(b), isTrue);
    expect(await edit(b, 'R1', a), isTrue);
    expect(await edit('d:/players/A.EXE', 'R1', d), isTrue);
    expect(store.externalPlayerPath, d, reason: '等价写法的原路径必须仍判为被选中的那条记录');
    final reloaded = UiPreferencesStore(path: settings);
    await reloaded.load();
    expect(reloaded.externalPlayerPath, d);
    expect(reloaded.listExternalPlayers(scanned).toSet(), {
      const ExternalPlayer(name: 'R1', executable: d),
      const ExternalPlayer(name: 'R2', executable: c),
    });
  });

  test('扫描 A 编辑成 B，选用 B 后编辑成 C，重启重扫仅保留 C 和新增 D', () async {
    final temp = Directory.systemTemp.createTempSync('external-catalog-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}/settings.json';
    const a = r'D:\Players\A.exe';
    const b = r'D:\Players\B.exe';
    const c = r'D:\Players\C.exe';
    const d = r'D:\Players\D.exe';
    const scanned = [ExternalPlayer(name: 'PotPlayer', executable: a)];
    final store = UiPreferencesStore(path: path);
    await store.load();
    expect(
      await store.saveExternalPlayer(
        originalExecutable: a,
        name: '重命名',
        executable: b,
        scanned: scanned,
        exists: (_) => true,
      ),
      isTrue,
    );
    await store.rememberExternalPlayerPath(b);
    expect(
      await store.saveExternalPlayer(
        originalExecutable: b,
        name: '第三次',
        executable: c,
        scanned: scanned,
        exists: (_) => true,
      ),
      isTrue,
    );
    expect(
      await store.saveExternalPlayer(
        name: '自定义',
        executable: d,
        scanned: scanned,
        exists: (_) => true,
      ),
      isTrue,
    );
    await store.rememberThemeMode('light');
    final reloaded = UiPreferencesStore(path: path);
    await reloaded.load();
    expect(reloaded.listExternalPlayers(scanned), const [
      ExternalPlayer(name: '第三次', executable: c),
      ExternalPlayer(name: '自定义', executable: d),
    ]);
    expect(reloaded.externalPlayerPath, c);
    final raw = jsonDecode(File(path).readAsStringSync()) as Map;
    expect((raw['ui'] as Map)['themeMode'], 'light');
  });
}
