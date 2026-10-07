/// Phase 4 · TMDB 入口可达性（发布包缺陷回归门禁）。
///
/// 背景（真实发布包实测缺陷）：早期实现里 `TmdbState.shouldRender` 对
/// 「未配置」也返回 `false`，`TmdbStatusBar` 直接 `SizedBox.shrink()`；
/// 而全应用唯一引用 `TmdbSettingsPage` 的地方就是状态条上那个从未被渲染的
/// `onConfigure` 回调。后果是：
///
/// 1. 全新安装（无凭据）→ 详情页没有任何 TMDB 区块；
/// 2. `TmdbSettingsPage` 成为死代码，AOT 编译时被 tree-shaking 整体剔除
///    （字节级证据：发布包 `app.so` 中 `TmdbSettingsPage` / `tmdb-api-key`
///    符号不存在，而 `TmdbStatusBar` 存在）；
/// 3. 于是正式版 exe 里既看不到 TMDB 设置，也看不到任何 TMDB 效果。
///
/// 既有的 L1/L2/L3 门禁都发现不了：widget 用例只断言「未配置 → 整块不渲染」
/// （把缺陷当契约），集成用例则直接写 `settings.json` 绕过 UI 入口。
///
/// 本文件用**真实 `AppState` + 真实路由**断言入口可达，是本缺陷的回归门禁。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/core/tmdb_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/tmdb_enrichment_service.dart';
import 'package:webhtv_pc/services/tmdb_identity_service.dart';
import 'package:webhtv_pc/services/tmdb_season_service.dart';
import 'package:webhtv_pc/services/tmdb_service.dart';
import 'package:webhtv_pc/state/app_state.dart';
import 'package:webhtv_pc/state/tmdb_state.dart';
import 'package:webhtv_pc/ui/diagnostics_pages.dart';
import 'package:webhtv_pc/ui/tmdb_widgets.dart';

/// 不发任何请求的客户端：用于「零请求」类断言。
class _NoNetworkClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw StateError('不应发起网络请求：${request.url}');
  }
}

TmdbState _state(TmdbConfig Function() config) => TmdbState(
  config: config,
  service: TmdbService(config: config, client: _NoNetworkClient()),
  identityService: TmdbIdentityService(
    config: config,
    service: TmdbService(config: config, client: _NoNetworkClient()),
    store: InMemoryTmdbMatchStore(),
  ),
  seasonService: TmdbSeasonService(store: InMemoryTmdbSeasonStore()),
  enrichmentService: TmdbEnrichmentService(
    service: TmdbService(config: config, client: _NoNetworkClient()),
    config: config,
  ),
);

TmdbSourceLine _line() => const TmdbSourceLine(
  flagKey: 'f#0',
  sourceFlag: '线路一',
  episodeNames: ['第1集'],
);

Vod _vod() => Vod(vodId: 'v', vodName: '剧名');

void main() {
  group('设置页 TMDB 入口（§17.2、design/04 §10.3）', () {
    late Directory temp;
    late AppState state;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('webhtv-tmdb-entry');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {'roaming': temp.path, 'local': temp.path},
        ),
        log: LogService(),
      );
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    testWidgets('未配置时设置页仍提供入口，点击后进入 TMDB 设置页', (tester) async {
      // 前置：全新安装没有凭据。
      expect(state.tmdbConfig.isReady, isFalse, reason: '前置条件：未配置');

      // 放大测试窗口，让整个设置表单一次性渲染（默认 800x600 会截断）。
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SettingsPage(state: state))),
      );
      await tester.pumpAndSettle();

      final entry = find.byKey(const ValueKey('settings-tmdb-open'));
      expect(
        entry,
        findsOneWidget,
        reason: '设置页必须有无条件可见的 TMDB 入口（否则全新安装无法启用 TMDB）',
      );

      await tester.tap(entry);
      await tester.pumpAndSettle();

      // 真正进入 TMDB 设置页：断言页内特征控件，而非仅断言路由类型。
      expect(find.text('TMDB 设置'), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-enabled')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-api-key')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-test')), findsOneWidget);
      expect(find.byKey(const ValueKey('tmdb-save')), findsOneWidget);
    });
  });

  group('详情页状态条入口（design/04 §3.1 ②）', () {
    testWidgets('未配置 → 渲染「未配置 TMDB」与可用的「去设置」', (tester) async {
      final state = _state(() => const TmdbConfig());
      addTearDown(state.dispose);

      state.beginLoad(
        siteKey: 's',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      // 未配置：零请求，但必须仍可渲染入口。
      expect(state.notConfigured, isTrue);
      expect(state.siteDisabled, isFalse);
      expect(
        state.shouldRender,
        isTrue,
        reason: '未配置必须渲染，否则用户永远进不了 TMDB 设置页',
      );

      var configured = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TmdbStatusBar(state: state, onConfigure: () => configured++),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('tmdb-status-unconfigured')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('tmdb-configure')));
      expect(configured, 1, reason: '「去设置」必须可用');
    });
  });

  group('站点禁用仍不渲染（design/04 §3.1，反向验证）', () {
    testWidgets('站点被规则禁用 → 状态条整块不渲染，无任何入口', (tester) async {
      // 站点禁用判定在「凭据就绪」之后，因此配置里必须有凭据。
      const config = TmdbConfig(apiKey: 'k', disabledSites: ['[书]']);
      final state = _state(() => config);
      addTearDown(state.dispose);

      state.beginLoad(
        siteKey: '[书]站',
        vodId: 'v',
        sourceTitle: '剧名',
        vod: _vod(),
        line: _line(),
      );
      expect(state.siteDisabled, isTrue);
      expect(state.shouldRender, isFalse);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TmdbStatusBar(state: state))),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('tmdb-status-unconfigured')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('tmdb-configure')), findsNothing);
      expect(find.byType(Row), findsNothing);
    });
  });
}
