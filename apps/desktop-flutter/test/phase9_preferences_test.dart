import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku_settings.dart';
import 'package:webhtv_pc/core/live_settings.dart';
import 'package:webhtv_pc/core/outbound_proxy.dart';
import 'package:webhtv_pc/core/parse_failover.dart';
import 'package:webhtv_pc/core/site_group_rules.dart';
import 'package:webhtv_pc/core/site_order.dart';
import 'package:webhtv_pc/core/subtitle_settings.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  late Directory temp;
  late String settingsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-phase9-prefs');
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

  group('播放参数持久化（design/01 §7）', () {
    test('从未设置过：返回默认且不写盘', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.playerOptions, const PlayerOptions.defaults());
      expect(store.hasExplicitPlayerOptions, isFalse);
      await store.rememberSite('muou');
      expect(readRaw().containsKey('player'), isFalse);
    });

    test('显式设置后写顶层 player 段，并能读回', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberPlayerOptions(
        store.playerOptions.copyWith(
          autoNext: false,
          preloadNext: true,
          autoSkipIntro: true,
          failureFallback: PlayerFailureFallback.off,
          lutPath: r'C:\luts\a.cube',
        ),
      );

      final raw = readRaw();
      final player = raw['player'] as Map<String, Object?>;
      expect(player['autoNext'], isFalse);
      expect(player['preloadNext'], isTrue);
      expect(player['autoSkipIntro'], isTrue);
      expect(player['failureFallback'], 'off');
      expect(player['lutPath'], r'C:\luts\a.cube');

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.playerOptions.autoNext, isFalse);
      expect(reloaded.playerOptions.autoSkipIntro, isTrue);
      expect(reloaded.playerOptions.failureFallback, PlayerFailureFallback.off);
      expect(reloaded.playerOptions.lutPath, r'C:\luts\a.cube');
    });

    test('脏数据回落默认，不抛异常', () async {
      File(settingsPath).writeAsStringSync(jsonEncode({
        'player': {
          'autoNext': 'nope',
          'demuxerMaxBytesMiB': 999999,
          'failureFallback': 'unknown',
          'longPressSpeed': 'fast',
        },
      }));
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.playerOptions.autoNext, isTrue);
      expect(store.playerOptions.demuxerMaxBytesMiB, PlayerOptions.maxDemuxerMaxMiB);
      expect(store.playerOptions.failureFallback, PlayerFailureFallback.line);
      expect(
        store.playerOptions.longPressSpeed,
        PlayerOptions.defaultLongPressSpeed,
        reason: '长按倍速的脏值回落默认 3×，而不是写死 2×',
      );
    });

    test('写入不覆盖既有 sync 段', () async {
      File(settingsPath).writeAsStringSync(jsonEncode({
        'sync': {'enabled': true},
      }));
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberPlayerOptions(
        store.playerOptions.copyWith(autoNext: false),
      );
      final raw = readRaw();
      expect((raw['sync'] as Map)['enabled'], isTrue);
    });

    test('长按画面倍速写盘并读回（默认 3×）', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(
        store.playerOptions.longPressSpeed,
        PlayerOptions.defaultLongPressSpeed,
        reason: '从未设置过时默认 3×',
      );
      expect(PlayerOptions.defaultLongPressSpeed, 3);

      await store.rememberPlayerOptions(
        store.playerOptions.copyWith(longPressSpeed: 2.5),
      );
      final player = readRaw()['player'] as Map<String, Object?>;
      expect(player['longPressSpeed'], 2.5);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.playerOptions.longPressSpeed, 2.5);
    });
  });

  group('直播设置持久化（design/03 §5）', () {
    test('默认不写盘；显式设置后写顶层 live 段', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.liveSettings, const LiveSettings.defaults());
      expect(store.hasExplicitLiveSettings, isFalse);

      await store.rememberLiveSettings(
        store.liveSettings.copyWith(sourceFallback: false, changeLine: false),
      );
      final live = readRaw()['live'] as Map<String, Object?>;
      expect(live['sourceFallback'], isFalse);
      expect(live['changeLine'], isFalse);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.liveSettings.sourceFallback, isFalse);
      expect(reloaded.liveSettings.changeLine, isFalse);
    });
  });

  group('字幕源 / 弹幕库设置持久化（design/02 §3）', () {
    test('默认不写盘；显式设置后写顶层 subtitles / danmaku 段', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.subtitleSettings.hasAnyProvider, isFalse);
      expect(store.danmakuSettings.isEnabled, isFalse);
      expect(readRaw().containsKey('subtitles'), isFalse);
      expect(readRaw().containsKey('danmaku'), isFalse);

      await store.rememberSubtitleSettings(
        store.subtitleSettings.copyWith(
          autoMatch: true,
          httpEndpoint: 'https://example.test/s',
          localDirectories: const [r'C:\subs'],
        ),
      );
      await store.rememberDanmakuSettings(
        store.danmakuSettings.copyWith(
          autoSearch: true,
          apiUrl: 'https://example.test/d',
        ),
      );

      final raw = readRaw();
      expect((raw['subtitles'] as Map)['autoMatch'], isTrue);
      expect((raw['danmaku'] as Map)['apiUrl'], 'https://example.test/d');

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.subtitleSettings.autoMatch, isTrue);
      expect(reloaded.subtitleSettings.localDirectories, [r'C:\subs']);
      expect(reloaded.danmakuSettings.autoSearch, isTrue);
    });

    test('字幕/弹幕默认对象的布尔值', () {
      expect(SubtitleSettings().autoMatch, isFalse);
      expect(const DanmakuSettings.defaults().autoSearch, isFalse);
    });
  });

  group('站点排序偏好（P1-3）', () {
    test('默认关闭且不写盘；显式开启后写顶层 siteOrder', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.siteOrder.healthSort, isFalse);
      expect(readRaw().containsKey('siteOrder'), isFalse);

      await store.rememberSiteOrder(
        store.siteOrder.copyWith(healthSort: true),
      );
      expect((readRaw()['siteOrder'] as Map)['healthSort'], isTrue);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.siteOrder.healthSort, isTrue);
    });
  });

  group('站点列表覆盖（手动顺序 + 屏蔽，P1-3）', () {
    test('默认空覆盖且不写盘', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.siteListOverrides('config:1'), SiteListOverrides.empty);
      expect(store.hasExplicitSiteListOverrides, isFalse);
      expect(readRaw().containsKey('siteList'), isFalse);
    });

    test('按配置作用域分别保存，互不影响', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberSiteListOverrides(
        'config:1',
        const SiteListOverrides(order: ['b', 'a'], blocked: {'a'}),
      );
      await store.rememberSiteListOverrides(
        'config:2',
        const SiteListOverrides(order: ['c']),
      );

      final siteList = readRaw()['siteList'] as Map<String, Object?>;
      final first = siteList['config:1'] as Map<String, Object?>;
      expect(first['order'], ['b', 'a']);
      expect(first['blocked'], ['a']);
      expect(
        (siteList['config:2'] as Map<String, Object?>).containsKey('blocked'),
        isFalse,
        reason: '空屏蔽集合不写键',
      );

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.siteListOverrides('config:1').order, ['b', 'a']);
      expect(reloaded.siteListOverrides('config:1').blocked, {'a'});
      expect(reloaded.siteListOverrides('config:2').order, ['c']);
      expect(reloaded.siteListOverrides('config:2').blocked, isEmpty);
      expect(reloaded.siteListOverrides('config:3').isEmpty, isTrue);
    });

    test('清空最后一项后整段消失', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberSiteListOverrides(
        'config:1',
        const SiteListOverrides(blocked: {'a'}),
      );
      expect(readRaw().containsKey('siteList'), isTrue);

      await store.rememberSiteListOverrides(
        'config:1',
        SiteListOverrides.empty,
      );
      expect(
        readRaw().containsKey('siteList'),
        isFalse,
        reason: '空覆盖不得留下空段',
      );

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.siteListOverrides('config:1').isEmpty, isTrue);
    });

    test('空作用域拒绝写入', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(
        await store.rememberSiteListOverrides(
          '  ',
          const SiteListOverrides(order: ['a']),
        ),
        isFalse,
      );
      expect(readRaw().containsKey('siteList'), isFalse);
    });
  });

  group('解析失败切换偏好（P1-4）', () {
    test('默认关闭且不写盘；显式开启后写顶层 parseFailover', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.parseFailover.enabled, isFalse);
      expect(readRaw().containsKey('parseFailover'), isFalse);

      await store.rememberParseFailover(
        const ParseFailoverSettings(enabled: true, maxAttempts: 2),
      );
      expect((readRaw()['parseFailover'] as Map)['enabled'], isTrue);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.parseFailover.enabled, isTrue);
      expect(reloaded.parseFailover.maxAttempts, 2);
    });

    test('maxAttempts 夹在 1~5', () {
      expect(
        const ParseFailoverSettings(enabled: true, maxAttempts: 99)
            .normalized()
            .maxAttempts,
        5,
      );
      expect(
        const ParseFailoverSettings(enabled: true, maxAttempts: 0)
            .normalized()
            .maxAttempts,
        1,
      );
    });
  });

  group('广告过滤开关（P1-1）', () {
    test('默认开启且不写盘；显式关闭后写顶层 adBlock', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.adBlockEnabled, isTrue);
      expect(readRaw().containsKey('adBlock'), isFalse);

      await store.rememberAdBlockEnabled(false);
      expect((readRaw()['adBlock'] as Map)['enabled'], isFalse);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.adBlockEnabled, isFalse);
    });
  });

  group('站点分组规则偏好（P1-5）', () {
    test('默认不写盘；显式关闭内置规则后写顶层 siteRules', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.siteGroupSettings.rules, hasLength(4));
      expect(readRaw().containsKey('siteRules'), isFalse);

      final rules = [
        for (final rule in store.siteGroupSettings.rules)
          if (rule.id == 'builtin_bracket_tag')
            rule.copyWith(enabled: false)
          else
            rule,
      ];
      await store.rememberSiteGroupSettings(
        SiteGroupSettings(rules: rules),
      );
      final stored = readRaw()['siteRules'] as Map;
      expect((stored['rules'] as List).length, 4);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(
        reloaded.siteGroupSettings.rules
            .firstWhere((r) => r.id == 'builtin_bracket_tag')
            .enabled,
        isFalse,
      );
      expect(
        reloaded.siteGroupSettings.rules
            .firstWhere((r) => r.id == 'builtin_pipe_quality')
            .enabled,
        isTrue,
      );
    });
  });

  group('出站代理偏好（P1-9）', () {
    test('默认关闭且不写盘；显式开启后写顶层 outboundProxy', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.outboundProxy.enabled, isFalse);
      expect(readRaw().containsKey('outboundProxy'), isFalse);

      await store.rememberOutboundProxy(
        const OutboundProxySettings(
          enabled: true,
          defaultProxyUrl: 'http://127.0.0.1:7890',
        ),
      );
      expect(
        (readRaw()['outboundProxy'] as Map)['enabled'],
        isTrue,
      );

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.outboundProxy.enabled, isTrue);
      expect(reloaded.outboundProxy.defaultProxyUrl, 'http://127.0.0.1:7890');
    });
  });
}
