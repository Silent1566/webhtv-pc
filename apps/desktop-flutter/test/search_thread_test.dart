/// 搜索线程（并发数）设置测试（对齐上游安卓「默影视」`Setting.getSearchThread`）。
///
/// 上游语义：默认 **20**、`clampSearchThread` 夹在 **1~100**，值直接决定
/// `Task.newSearchExecutor(threads)` 的并发度。PC 端对应
/// `UiPreferencesStore.searchThread` + `AppState.searchAll(maxConcurrency:)`。
///
/// 用**真实 HTTP 探针**观测并发度（不是只看参数有没有传下去）：并发度是这套
/// 设置的**唯一**用户价值，只看字段值无法证明它真的影响在途请求数。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

import 'support/concurrency_probe.dart';

void main() {
  late Directory tempDir;
  late AppPaths paths;
  late AppState state;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('webhtv-search-thread');
    paths = AppPaths.resolve(
      overrides: {
        'config': '${tempDir.path}/webhtv-pc',
        'data': '${tempDir.path}/webhtv-pc',
        'cache': '${tempDir.path}/webhtv-pc/cache',
        'state': '${tempDir.path}/webhtv-pc/logs',
      },
    );
    // bootstrap 会装配 UiPreferencesStore（`setSearchThread` 依赖它），
    // 同时建出数据库；真实的临时目录 I/O 必须在这里做（testWidgets 体内是
    // fake-async 区，推不动真实文件 I/O）。
    state = AppState(
      paths: paths,
      log: LogService(),
      httpClient: http.Client(),
    );
    await state.bootstrap();
  });

  tearDown(() async {
    state.dispose();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  /// 导入 [count] 个都指向 [api] 的可搜索站点。
  Future<void> importSites(String api, int count) async {
    final ok = await state.importConfig(
      jsonEncode({
        'name': '搜索线程测试',
        'sites': [
          for (var i = 0; i < count; i++)
            {
              'key': 's-$i',
              'name': '站点 $i',
              'type': 1,
              'api': api,
              'searchable': 1,
              'quickSearch': 1,
            },
        ],
      }),
    );
    expect(ok, isTrue, reason: '配置导入应成功');
  }

  /// 直接读盘上的 `ui.searchThread`（证明真的落盘，而不是只有内存值）。
  Object? searchThreadOnDisk() {
    final file = File(paths.settingsPath);
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final ui = decoded['ui'];
    return ui is Map ? ui['searchThread'] : null;
  }

  // ---------------------------------------------------------------------------
  // 取值、夹取、持久化
  // ---------------------------------------------------------------------------
  group('搜索线程设置（上游对齐）', () {
    test('默认 20（与上游 Setting.getSearchThread 一致）', () {
      expect(state.searchThread, 20);
    });

    test('设置后立即生效并落盘，重建 store 可恢复', () async {
      await state.setSearchThread(7);

      expect(state.searchThread, 7);
      expect(searchThreadOnDisk(), 7, reason: '必须落到 ui.searchThread');

      final reopened = UiPreferencesStore(path: paths.settingsPath);
      await reopened.load();
      expect(reopened.searchThread, 7);
      expect(reopened.hasExplicitSearchThread, isTrue);
    });

    test('夹到 1~100：0 与负数 → 1，超大 → 100（上游 clampSearchThread）', () async {
      await state.setSearchThread(0);
      expect(state.searchThread, 1, reason: '并发 0 会让搜索一个请求都不发');

      await state.setSearchThread(-5);
      expect(state.searchThread, 1);

      await state.setSearchThread(999);
      expect(state.searchThread, 100);
      expect(searchThreadOnDisk(), 100);
    });

    test('手改文件写坏的并发值在读取时也会被夹住', () async {
      final file = File(paths.settingsPath);
      await file.parent.create(recursive: true);
      await file.writeAsString('{"ui":{"searchThread":0}}');

      final store = UiPreferencesStore(path: paths.settingsPath);
      await store.load();
      expect(store.searchThread, 1);
    });

    test('并发线程数不影响相似度与历史（同一段偏好互不覆盖）', () async {
      await state.setSearchThread(9);
      await state.setSearchSimilarity(60);
      await state.searchAll('样本'); // 无站点，仅触发历史写入

      // 历史落盘是 unawaited（fire-and-forget），所以这里**有界轮询**等它完成，
      // 而不是固定 sleep（固定值在负载下会脆——本仓库已有同类教训）。
      Map<Object?, Object?> uiSection() {
        final file = File(paths.settingsPath);
        if (!file.existsSync()) return const {};
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is! Map) return const {};
        final ui = decoded['ui'];
        return ui is Map ? ui : const {};
      }

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline) &&
          (uiSection()['searchKeywords'] as List? ?? const []).isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      // 三个键必须共存于同一份 ui 段：任一方落盘时若整段覆盖，另外两个就丢了。
      final ui = uiSection();
      expect(ui['searchThread'], 9);
      expect(ui['searchSimilarity'], 60);
      expect(ui['searchKeywords'], ['样本']);
    });
  });

  // ---------------------------------------------------------------------------
  // 真的改变在途并发数（探针观测）
  // ---------------------------------------------------------------------------
  group('searchAll 的并发度由设置决定', () {
    test('未设置时用默认 20：25 个站点峰值 20', () async {
      final probe = await ConcurrencyProbe.start(holdMs: 300);
      addTearDown(probe.stop);
      await importSites(probe.api, 25);

      final outcome = await state.searchAll('样本');

      expect(outcome.succeededCount, 25);
      expect(
        probe.maxInFlight,
        20,
        reason: '默认 20（上游同默认）：25 个站点时同时在途的应为 20',
      );
    });

    test('设为 3 时峰值不超过 3', () async {
      final probe = await ConcurrencyProbe.start(holdMs: 300);
      addTearDown(probe.stop);
      await importSites(probe.api, 8);
      await state.setSearchThread(3);

      final outcome = await state.searchAll('样本');

      expect(outcome.succeededCount, 8);
      expect(probe.maxInFlight, 3, reason: '并发度必须等于设置值');
    });

    test('设为 1 时完全串行', () async {
      final probe = await ConcurrencyProbe.start(holdMs: 120);
      addTearDown(probe.stop);
      await importSites(probe.api, 4);
      await state.setSearchThread(1);

      await state.searchAll('样本');

      expect(probe.maxInFlight, 1, reason: '线程 1 必须是一次一个');
    });

    test('线程数大于站点数时峰值等于站点数', () async {
      final probe = await ConcurrencyProbe.start(holdMs: 300);
      addTearDown(probe.stop);
      await importSites(probe.api, 3);
      await state.setSearchThread(50);

      await state.searchAll('样本');

      expect(probe.maxInFlight, 3, reason: '没必要为 3 个站点开 50 个 worker');
    });

    test('显式 maxConcurrency 覆盖设置值（测试与调用方可指定）', () async {
      final probe = await ConcurrencyProbe.start(holdMs: 300);
      addTearDown(probe.stop);
      await importSites(probe.api, 8);
      await state.setSearchThread(2);

      await state.searchAll('样本', maxConcurrency: 5);

      expect(probe.maxInFlight, 5, reason: '显式参数优先于设置');
    });

    test('改设置影响下一次搜索，不影响已在跑的批次', () async {
      final probe = await ConcurrencyProbe.start(holdMs: 500);
      addTearDown(probe.stop);
      await importSites(probe.api, 6);
      await state.setSearchThread(2);

      final running = state.searchAll('第一批');
      // 批次在途时改并发：它已经按 2 开了 worker，不应被中途改变。
      await state.setSearchThread(6);
      await running;
      expect(probe.maxInFlight, 2, reason: '在途批次不受影响');

      probe.resetPeak();
      await state.searchAll('第二批');
      expect(probe.maxInFlight, 6, reason: '下一次搜索用新设置');
    });
  });
}
