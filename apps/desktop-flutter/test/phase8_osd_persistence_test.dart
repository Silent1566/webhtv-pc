import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/osd_config.dart';
import 'package:webhtv_pc/core/player_buttons.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  late Directory temp;
  late String settingsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-phase8-prefs');
    settingsPath = '${temp.path}${Platform.pathSeparator}settings.json';
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, Object?> readRaw() {
    final file = File(settingsPath);
    if (!file.existsSync()) return const {};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }

  group('屏显持久化（design/02 §5.2）', () {
    test('从未设置过时返回默认表，且不写盘', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.osdFlags, defaultOsdFlags());
      expect(store.hasExplicitOsd, isFalse);
      await store.rememberSite('muou');
      final raw = readRaw();
      final ui = raw['ui'] as Map<String, Object?>?;
      expect(ui?.containsKey('osd'), isFalse, reason: '缺席 = 默认，不得固化进文件');
    });

    // 关键用例：只写**显式设置过**的项，不得把 7 项默认值一起写盘。
    //
    // 为什么必须有这一条：上面那个用例只走了「从未设置过」路径，
    // 所以「一旦有任一显式项就把 7 项全写盘」的实现能通过它——
    // 而那正好违反 `design/02` §5.2 的「缺席 = 默认，不把默认值固化进文件」。
    // 变异测试实测确认了这个盲点（把全部 7 项写盘，8 个用例仍全绿）。
    test('只写显式设置过的项，不把默认值一起写盘', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag(OsdFlag.mini, true);

      final raw = readRaw();
      final osd = (raw['ui'] as Map)['osd'] as Map;
      expect(osd.keys.toSet(), {OsdFlag.mini}, reason: '只应有显式设置的那一项');
      expect(osd.containsKey(OsdFlag.title), isFalse);
      expect(osd.containsKey(OsdFlag.size), isFalse);
      expect(osd.containsKey(OsdFlag.time), isFalse);
      expect(osd.containsKey(OsdFlag.progress), isFalse);
      expect(osd.containsKey(OsdFlag.traffic), isFalse);
      expect(osd.containsKey(OsdFlag.diagnostics), isFalse);
    });

    test('写入后重新 load 得到同一张表', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag(OsdFlag.mini, true);
      await store.rememberOsdFlag(OsdFlag.title, false);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.osdFlags[OsdFlag.mini], isTrue);
      expect(reloaded.osdFlags[OsdFlag.title], isFalse);
      expect(reloaded.osdFlags[OsdFlag.size], isTrue, reason: '未设置的项用默认');
      expect(reloaded.hasExplicitOsd, isTrue);
    });

    test('非法 id 被忽略，不写坏状态', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag('nonsense', true);
      expect(store.osdFlags.containsKey('nonsense'), isFalse);
    });

    // 关键用例：非法 id 必须在**写入时**被拒绝，而不是靠读取时过滤。
    //
    // 为什么必须有这一条：`osdFlags` getter 本身会过滤未知键，
    // 所以只断言 getter 分不清「写时拒绝」与「读时过滤」——
    // 变异测试实测确认：去掉 `rememberOsdFlag` 的守卫，用例仍绿。
    test('非法 id 在写入时即被拒绝（文件里不得出现该键）', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag('nonsense', true);

      // 先确认内存态没有它。
      expect(store.osdFlags.containsKey('nonsense'), isFalse);
      // 再确认**文件里**也没有它——这才是「写时拒绝」的证据。
      final raw = readRaw();
      final ui = raw['ui'] as Map<String, Object?>?;
      final osd = ui?['osd'];
      // 非法 id 被拒绝时 `_osdFlags` 仍为空，所以 `ui.osd` 可能整个缺席。
      // 这里**显式断言**「要么没有 osd 段，要么有但里面没有该键」，
      // 而不是用 `if (osd is Map)` 把缺席悄悄跳过——后者会让断言在
      // 实现改成「总是写 osd 段」时静默失效。
      if (osd != null) {
        expect(osd, isA<Map>(), reason: 'ui.osd 存在时必须是对象');
        expect(
          (osd as Map).containsKey('nonsense'),
          isFalse,
          reason: '非法 id 不得落盘（不能靠读取时过滤来掩盖）',
        );
      }
      expect(store.hasExplicitOsd, isFalse, reason: '非法 id 不应让 hasExplicitOsd 变真');
    });

    test('只改 ui 段：sync 段保留', () async {
      File(settingsPath).writeAsStringSync(
        jsonEncode({
          'sync': {'token': 'keep-me'},
          'tmdb': {'enabled': true},
        }),
      );
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberOsdFlag(OsdFlag.diagnostics, true);

      final raw = readRaw();
      expect((raw['sync'] as Map)['token'], 'keep-me');
      expect((raw['tmdb'] as Map)['enabled'], isTrue);
    });
  });

  group('按钮配置持久化（design/03 §4.2）', () {
    test('从未设置过时返回默认顺序与空隐藏集', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.buttonOrder, defaultButtonOrder());
      expect(store.buttonHidden, isEmpty);
      expect(store.hasExplicitPlayerButtons, isFalse);
    });

    test('写入顺序与隐藏集后重新 load 得到同一结果', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberButtonOrder(['next', 'play', 'prev']);
      await store.rememberButtonHidden({'speed', 'fullscreen'});

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.buttonOrder.take(3).toList(), ['next', 'play', 'prev']);
      expect(reloaded.buttonOrder.length, kPlayerButtons.length, reason: '缺失项补全到末尾');
      expect(reloaded.buttonHidden, {'speed', 'fullscreen'});
      expect(reloaded.hasExplicitPlayerButtons, isTrue);
    });

    test('恢复默认清除两个键', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberButtonOrder(['next', 'play']);
      await store.rememberButtonHidden({'speed'});
      await store.resetPlayerButtons();

      final raw = readRaw();
      final ui = raw['ui'] as Map<String, Object?>?;
      expect(ui?.containsKey('playerButtons'), isFalse);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.buttonOrder, defaultButtonOrder());
      expect(reloaded.buttonHidden, isEmpty);
    });

    // 关键用例：`order` 为 null 时该键必须**缺席**，而不是写成 null。
    //
    // 为什么必须有这一条：`'order': ?order` 这个 null-aware 值形式
    // 恰恰只在 order == null 时才与旧写法有区别，而 round-trip 用例
    // 走的是「order 已设置」的路径，覆盖不到它。
    // （Task 3 的修复轮用一次性探针验证过，但探针按约定删除了——
    // 这里补成永久用例。）
    test('只设置 hidden 时 order 键缺席（null-aware 值的真实分支）', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberButtonHidden({'speed', 'fullscreen'});

      final raw = readRaw();
      final pb = (raw['ui'] as Map)['playerButtons'] as Map;
      expect(pb.containsKey('order'), isFalse, reason: 'order 为 null 时必须缺席');
      expect(pb['hidden'], ['fullscreen', 'speed'], reason: 'hidden 落盘时排序');

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.hasExplicitPlayerButtons, isTrue);
      expect(reloaded.buttonHidden, {'speed', 'fullscreen'});
      expect(reloaded.buttonOrder, defaultButtonOrder(), reason: '缺席 = 默认顺序');
    });

    // 关键用例：缺失项补全必须**落盘**，而不是只在 getter 里补。
    //
    // 为什么必须有这一条：`buttonOrder` getter 自己会补全缺失项，
    // 所以只断言 getter 分不清「写盘时补全」与「读取时补全」——
    // 变异测试实测确认：去掉 `rememberButtonOrder` 的补全，用例仍绿。
    test('写入时即补全缺失项（文件里的 order 长度就是 8）', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberButtonOrder(['next', 'play']);

      final raw = readRaw();
      final pb = (raw['ui'] as Map)['playerButtons'] as Map;
      final persisted = (pb['order'] as List).cast<String>();
      expect(persisted.length, kPlayerButtons.length, reason: '落盘的必须是补全后的完整顺序');
      expect(persisted.take(2).toList(), ['next', 'play']);
      expect(persisted.toSet(), defaultButtonOrder().toSet());
    });

    test('兼容逗号分隔字符串（上游格式）', () async {
      File(settingsPath).writeAsStringSync(
        jsonEncode({
          'ui': {
            'playerButtons': {'order': 'next,play', 'hidden': 'speed'},
          },
        }),
      );
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.buttonOrder.take(2).toList(), ['next', 'play']);
      expect(store.buttonHidden, {'speed'});
    });
  });
}
