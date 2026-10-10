/// 记住最近使用的站点（用户需求 2026-10-10）。
///
/// >「记住用户最好一次使用的站点，重启应用后默认加载最近一次使用的，
/// >  第一次使用才加载排第一个站点。」
///
/// 规则（三条守卫，缺一不可）：
/// 1. 选过站点 → 写进 `settings.json` 的 `ui.lastSiteKey`；
/// 2. 重启后 → 默认回到**最近一次使用**的站点（而不是配置里的第一个）；
/// 3. 但该 key 必须**仍存在于当前配置**——换了配置/站点被删就作废，
///    退回第一个站点（否则首页必然 `siteUnsupported`）。
///
/// 首次使用（从未选过）时 `lastSiteKey` 为空，自然走第一个站点。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

/// 三个站点：默认（第一个）是 `site_a`，另有 `site_b` / `site_c`。
const String _config = '''
{
  "name": "站点记忆测试",
  "sites": [
    {"key": "site_a", "name": "甲站", "type": 4, "api": "http://127.0.0.1:1/vod/api?key=site_a"},
    {"key": "site_b", "name": "乙站", "type": 4, "api": "http://127.0.0.1:1/vod/api?key=site_b"},
    {"key": "site_c", "name": "丙站", "type": 4, "api": "http://127.0.0.1:1/vod/api?key=site_c"}
  ]
}
''';

void main() {
  late Directory temp;
  late AppPaths paths;

  setUp(() async {
    // 真实 I/O 必须在 setUp（`testWidgets` 的 fake-async 区里 await 会挂住；
    // 纯 `test()` 不受此限，这里统一放 setUp 更稳）。
    temp = await Directory.systemTemp.createTemp('webhtv-last-site');
    paths = AppPaths.resolve(
      overrides: {'roaming': temp.path, 'local': temp.path},
    );
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  AppState build() =>
      AppState(paths: paths, log: LogService(), httpClient: _NoNetwork());

  /// 首次使用：导入配置（会选默认站点），再清掉记住的站点，模拟「全新用户」。
  Future<void> seedConfigOnly() async {
    final state = build();
    await state.bootstrap();
    await state.importConfig(_config, displayName: '站点记忆测试');
    state.dispose();
    // 清掉导入时可能记下的站点，构造「从未选过」的初始态。
    final store = UiPreferencesStore(path: paths.settingsPath, log: LogService());
    await store.load();
    await store.rememberSite('');
  }

  String? lastSiteKeyOnDisk() {
    final file = File(paths.settingsPath);
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final ui = decoded['ui'];
    if (ui is! Map) return null;
    final value = ui['lastSiteKey'];
    return value is String ? value : null;
  }

  test('首次使用：无记录 → 选中配置里的第一个站点', () async {
    await seedConfigOnly();

    final state = build();
    addTearDown(state.dispose);
    await state.bootstrap();

    expect(
      state.selectedSite?.key,
      'site_a',
      reason: '从未选过站点时应退回配置里的第一个（defaultSite）',
    );
  });

  test('选过站点 → 写入 settings.json 的 ui.lastSiteKey', () async {
    await seedConfigOnly();

    final state = build();
    addTearDown(state.dispose);
    await state.bootstrap();
    final siteC = state.config!.sites.firstWhere((s) => s.key == 'site_c');
    await state.selectSite(siteC);

    // 写盘是异步的，给它一点真实时间。
    for (var i = 0; i < 40 && lastSiteKeyOnDisk() != 'site_c'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(
      lastSiteKeyOnDisk(),
      'site_c',
      reason: '选择站点后必须落盘（否则重启无从恢复）',
    );
  });

  test('重启后默认回到最近使用的站点（而不是第一个）', () async {
    await seedConfigOnly();

    // 第一次会话：选 site_c。
    final first = build();
    await first.bootstrap();
    await first.selectSite(
      first.config!.sites.firstWhere((s) => s.key == 'site_c'),
    );
    // 等落盘完成再 dispose，模拟正常退出。
    for (var i = 0; i < 40 && lastSiteKeyOnDisk() != 'site_c'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    first.dispose();

    // 重启：同一数据目录重新打开。
    final reopened = build();
    addTearDown(reopened.dispose);
    await reopened.bootstrap();

    expect(
      reopened.selectedSite?.key,
      'site_c',
      reason: '重启后应恢复最近一次使用的站点（用户需求）',
    );
    expect(
      reopened.selectedSite?.key,
      isNot('site_a'),
      reason: '不应被重置回配置里的第一个站点',
    );
  });

  test('记住的站点已不在当前配置里 → 退回第一个（不产生不可用站点）', () async {
    await seedConfigOnly();

    // 先选 site_c 并落盘。
    final first = build();
    await first.bootstrap();
    await first.selectSite(
      first.config!.sites.firstWhere((s) => s.key == 'site_c'),
    );
    for (var i = 0; i < 40 && lastSiteKeyOnDisk() != 'site_c'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    first.dispose();

    // 换成一份**不含 site_c** 的配置（模拟换配置/站点被删）。
    final second = build();
    await second.bootstrap();
    await second.importConfig('''
{
  "name": "另一份配置",
  "sites": [
    {"key": "site_x", "name": "X 站", "type": 4, "api": "http://127.0.0.1:1/vod/api?key=site_x"},
    {"key": "site_y", "name": "Y 站", "type": 4, "api": "http://127.0.0.1:1/vod/api?key=site_y"}
  ]
}
''', displayName: '另一份配置');
    second.dispose();

    // 重启：记住的是 site_c，但它不在当前配置里。
    final reopened = build();
    addTearDown(reopened.dispose);
    await reopened.bootstrap();

    expect(
      reopened.selectedSite?.key,
      'site_x',
      reason: '记住的站点不存在时必须退回当前配置的第一个，'
          '否则首页会 siteUnsupported（用户曾实测过这类空站）',
    );
  });

  test('UiPreferencesStore：读改写不破坏 settings.json 的其它段', () async {
    // 先写一个含 tmdb/sync 段的文件。
    final file = File(paths.settingsPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'tmdb': {'enabled': true, 'apiKey': 'KEEP-ME'},
        'sync': {'deviceUuid': 'KEEP-ME-TOO'},
      }),
    );

    final store = UiPreferencesStore(path: paths.settingsPath, log: LogService());
    await store.load();
    await store.rememberSite('site_b');

    final decoded = jsonDecode(file.readAsStringSync()) as Map;
    expect(decoded['ui'], {'lastSiteKey': 'site_b'});
    expect(
      (decoded['tmdb'] as Map)['apiKey'],
      'KEEP-ME',
      reason: '写 ui 段不得覆盖 tmdb 段',
    );
    expect(
      (decoded['sync'] as Map)['deviceUuid'],
      'KEEP-ME-TOO',
      reason: '写 ui 段不得覆盖 sync 段',
    );
  });

  test('UiPreferencesStore：文件损坏时退回默认且不抛', () async {
    final file = File(paths.settingsPath);
    await file.parent.create(recursive: true);
    await file.writeAsString('{ this is not json');

    final store = UiPreferencesStore(path: paths.settingsPath, log: LogService());
    await store.load();
    expect(store.lastSiteKey, '');
    expect(store.loaded, isTrue, reason: '损坏也要标记为已读，避免重复尝试');
  });
}

/// 不发任何站点请求（本用例只关心站点选择与持久化）。
class _NoNetwork extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw StateError('本用例不应发起站点请求：${request.url}');
  }
}
