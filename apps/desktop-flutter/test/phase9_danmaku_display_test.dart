import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku.dart';
import 'package:webhtv_pc/core/danmaku_style.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  group('DanmakuStyle 归一化（P0-7）', () {
    test('默认值等价 Phase 3–8 的显示行为', () {
      const style = DanmakuStyle.defaults;
      expect(style.enabled, isTrue);
      expect(style.opacity, 0.9);
      expect(style.textScale, 1.0);
      expect(style.strokeWidth, 1.2);
      expect(style.scrollDurationMs, 8000);
      expect(style.fixedDurationMs, 4000);
      expect(style.areaRatio, 0.6);
      expect(style.maxTracks, 0);
      expect(style.timeOffsetMs, 0);
      expect(style.isDefault, isTrue);
    });

    test('越界值被夹取，非法 NaN 回落到下界', () {
      final style = DanmakuStyle.defaults.copyWith(
        opacity: 2.0,
        textScale: 99,
        strokeWidth: -4,
        scrollDurationMs: 99999,
        fixedDurationMs: 0,
        areaRatio: 5,
        maxTracks: 99,
        timeOffsetMs: -99999,
      );
      expect(style.opacity, 1.0);
      expect(style.textScale, 2.5);
      expect(style.strokeWidth, 0);
      expect(style.scrollDurationMs, 20000);
      expect(style.fixedDurationMs, 1000);
      expect(style.areaRatio, 0.9);
      expect(style.maxTracks, 10);
      expect(style.timeOffsetMs, -10000);

      final nan = DanmakuStyle.defaults.copyWith(opacity: double.nan);
      expect(nan.opacity, 0.1);
    });

    test('JSON 往返稳定，脏字段回落到默认值', () {
      final style = DanmakuStyle.defaults.copyWith(
        enabled: false,
        textScale: 1.5,
        scrollDurationMs: 6000,
        areaRatio: 0.45,
        maxTracks: 5,
        timeOffsetMs: 3000,
      );
      final decoded = DanmakuStyle.fromJson(
        jsonDecode(jsonEncode(style.toJson())),
      );
      expect(decoded, style);

      final dirty = DanmakuStyle.fromJson({
        'opacity': 'nope',
        'textScale': 9,
        'scrollDurationMs': 'fast',
        'maxTracks': -3,
        'enabled': 1,
      });
      expect(dirty.opacity, 0.9);
      expect(dirty.textScale, 2.5);
      expect(dirty.scrollDurationMs, 8000);
      expect(dirty.maxTracks, 0);
      expect(dirty.enabled, isTrue);
    });

    test('时间偏移：正数＝延后（查询更早的时间轴），且不为负', () {
      final delayed = DanmakuStyle.defaults.copyWith(timeOffsetMs: 2000);
      expect(delayed.offsetPositionMs(5000), 3000);
      expect(delayed.offsetPositionMs(1000), 0);

      final advanced = DanmakuStyle.defaults.copyWith(timeOffsetMs: -2000);
      expect(advanced.offsetPositionMs(5000), 7000);
    });
  });

  group('轨道与时长参数真正生效', () {
    DanmakuItem item(int timeMs, String text) => DanmakuItem(
      timeMs: timeMs,
      text: text,
      type: DanmakuType.scroll,
      textSizeSp: 16,
      color: 0xFFFFFFFF,
    );

    test('areaRatio 限制滚动轨道数', () {
      // 720 高、28px 轨道、60% 区域 → 15 条；30% → 7 条。
      final wide = DanmakuTrackAllocator(
        width: 1280,
        height: 720,
        trackHeight: 28,
        maxTracksRatio: 0.6,
      );
      final narrow = DanmakuTrackAllocator(
        width: 1280,
        height: 720,
        trackHeight: 28,
        maxTracksRatio: 0.3,
      );
      expect(wide.scrollTrackCount, 15);
      expect(narrow.scrollTrackCount, 7);
      expect(narrow.scrollTrackCount, lessThan(wide.scrollTrackCount));
    });

    test('maxTracks 是硬上限（0 = 不限）', () {
      final capped = DanmakuTrackAllocator(
        width: 1280,
        height: 720,
        trackHeight: 28,
        maxTracksRatio: 0.6,
        maxTracks: 3,
      );
      expect(capped.scrollTrackCount, 3);
      expect(capped.fixedTrackCount, 3);

      final unlimited = DanmakuTrackAllocator(
        width: 1280,
        height: 720,
        trackHeight: 28,
        maxTracks: 0,
      );
      expect(unlimited.scrollTrackCount, 15);
    });

    test('maxTracks=1 时同时刻的三条滚动弹幕只显示一条', () {
      final items = [item(0, '第一条'), item(0, '第二条'), item(0, '第三条')];
      final visible = DanmakuTrackAllocator.visibleAt(
        items: items,
        positionMs: 1000,
        enabled: true,
        maxTracks: 1,
        width: 1280,
        height: 720,
      );
      expect(visible, hasLength(1));
      expect(visible.single.track, 0);
    });

    test('scrollDurationMs 决定滚动弹幕的生命周期', () {
      final items = [item(0, '滚动弹幕')];
      final fast = DanmakuTrackAllocator.visibleAt(
        items: items,
        positionMs: 5000,
        enabled: true,
        scrollDurationMs: 4000,
      );
      final slow = DanmakuTrackAllocator.visibleAt(
        items: items,
        positionMs: 5000,
        enabled: true,
        scrollDurationMs: 8000,
      );
      expect(fast, isEmpty);
      expect(slow, hasLength(1));
      expect(slow.single.progress, closeTo(5000 / 8000, 0.0001));
    });
  });

  group('弹幕显示偏好持久化', () {
    late Directory temp;
    late String settingsPath;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('webhtv-phase9-danmaku');
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

    test('从未设置过：不写 danmakuDisplay', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.danmakuStyle, DanmakuStyle.defaults);
      expect(store.hasExplicitDanmakuStyle, isFalse);
      await store.rememberSite('fixture');
      expect(readRaw().containsKey('danmakuDisplay'), isFalse);
    });

    test('显式设置后写顶层 danmakuDisplay，读回一致', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      final style = store.danmakuStyle.copyWith(
        scrollDurationMs: 6000,
        maxTracks: 5,
        areaRatio: 0.45,
        strokeWidth: 0,
        timeOffsetMs: 2000,
      );
      expect(await store.rememberDanmakuStyle(style), isTrue);

      final raw = readRaw();
      final section = raw['danmakuDisplay'] as Map<String, Object?>;
      expect(section['scrollDurationMs'], 6000);
      expect(section['maxTracks'], 5);
      expect(section['areaRatio'], 0.45);
      expect(section['timeOffsetMs'], 2000);

      final reloaded = UiPreferencesStore(path: settingsPath);
      await reloaded.load();
      expect(reloaded.danmakuStyle, style);
      expect(reloaded.hasExplicitDanmakuStyle, isTrue);
    });

    test('改回默认值不写脏数据（旧版本可安全缺省）', () async {
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      await store.rememberDanmakuStyle(
        DanmakuStyle.defaults.copyWith(textScale: 1.5),
      );
      expect(readRaw().containsKey('danmakuDisplay'), isTrue);

      await store.rememberDanmakuStyle(DanmakuStyle.defaults);
      expect(readRaw().containsKey('danmakuDisplay'), isFalse);
    });

    test('旧文件没有 danmakuDisplay 时保持默认（升级不改变行为）', () async {
      File(settingsPath).writeAsStringSync(jsonEncode({
        'ui': {'lastSiteKey': 'fixture'},
        'player': {'autoNext': true},
        'danmaku': {'autoSearch': true, 'apiUrl': 'http://example.test/api'},
      }));
      final store = UiPreferencesStore(path: settingsPath);
      await store.load();
      expect(store.danmakuStyle, DanmakuStyle.defaults);
      // 弹幕库设置与显示样式互不影响。
      expect(store.danmakuSettings.autoSearch, isTrue);
    });
  });
}
