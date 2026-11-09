/// 选集视图模式偏好（网格/列表）的持久化用例。
///
/// 「选集视图」与主题、历史点击行为一样是全局 UI 偏好：两个详情页共享同一份值，
/// 因此必须落在 `settings.json` 的 `ui` 段，并由 store 负责归一化。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  late Directory temp;
  late String settingsPath;

  setUp(() async {
    // 真实 I/O 一律落在临时目录，绝不碰用户真实配置目录。
    temp = await Directory.systemTemp.createTemp('webhtv-episode-view');
    settingsPath = '${temp.path}${Platform.pathSeparator}settings.json';
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  Future<UiPreferencesStore> openStore() async {
    final store = UiPreferencesStore(path: settingsPath);
    await store.load();
    return store;
  }

  Map<String, Object?> readUiSection() {
    final decoded = jsonDecode(File(settingsPath).readAsStringSync());
    return ((decoded as Map)['ui'] as Map).cast<String, Object?>();
  }

  test('从未设置过时返回默认网格', () async {
    final store = await openStore();

    expect(store.episodeViewMode, UiEpisodeViewMode.grid);
    expect(UiEpisodeViewMode.grid, 'grid');
    expect(UiEpisodeViewMode.list, 'list');
  });

  test('记住列表模式后重新加载能读回', () async {
    final store = await openStore();
    await store.rememberEpisodeViewMode('list');

    final reopened = await openStore();
    expect(reopened.episodeViewMode, UiEpisodeViewMode.list);
  });

  test('大小写与空白归一化，非法值回落到网格', () async {
    final store = await openStore();

    await store.rememberEpisodeViewMode('  LiSt  ');
    expect(store.episodeViewMode, UiEpisodeViewMode.list);

    // 'GRID' 合法（只是大小写不同）→ 归一成 'grid'，不是回落到默认。
    await store.rememberEpisodeViewMode('GRID');
    expect(store.episodeViewMode, UiEpisodeViewMode.grid);

    await store.rememberEpisodeViewMode('abc');
    expect(store.episodeViewMode, UiEpisodeViewMode.grid);

    await store.rememberEpisodeViewMode('');
    expect(store.episodeViewMode, UiEpisodeViewMode.grid);

    expect(UiEpisodeViewMode.normalize(null), UiEpisodeViewMode.grid);
    expect(UiEpisodeViewMode.normalize(' LIST '), UiEpisodeViewMode.list);
  });

  test('写选集模式不破坏 ui 段的其它键', () async {
    final store = await openStore();
    await store.rememberThemeMode(UiThemeMode.light);
    await store.rememberEpisodeViewMode('list');

    final ui = readUiSection();
    expect(ui['episodeViewMode'], 'list');
    expect(ui['themeMode'], 'light', reason: '写选集模式不得覆盖主题键');

    // 内存态与磁盘一起核对：重开只读回自己那一个键。
    final reopened = await openStore();
    expect(reopened.episodeViewMode, UiEpisodeViewMode.list);
    expect(reopened.themeMode, UiThemeMode.light);
  });

  test('显式选网格时首次写入也落盘（非缺省缺席）', () async {
    final store = await openStore();
    // 用户显式选网格：内存里是 null（从未设置），normalize 后是 'grid'，
    // 两者不等，必须真的写盘——否则「显式网格」会被当成「从未设置」。
    await store.rememberEpisodeViewMode(UiEpisodeViewMode.grid);

    expect(store.hasExplicitEpisodeViewMode, isTrue);
    expect(readUiSection()['episodeViewMode'], 'grid');
  });
}
