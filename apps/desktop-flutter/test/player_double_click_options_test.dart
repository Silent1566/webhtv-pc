import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

void main() {
  test('默认与旧配置均保留左右双击只切全屏', () {
    for (final raw in [
      null,
      <String, Object?>{'cache': false},
    ]) {
      final json = PlayerOptions.fromJson(raw).toJson();
      expect(json['doubleClickLeft'], 'toggleFullscreen');
      expect(json['doubleClickRight'], 'toggleFullscreen');
    }
    final defaults = const PlayerOptions.defaults().toJson();
    expect(defaults['doubleClickLeft'], 'toggleFullscreen');
    expect(defaults['doubleClickRight'], 'toggleFullscreen');
  });

  test('所有动作以稳定 ID 独立往返，不依赖枚举序号', () {
    const ids = [
      'toggleFullscreen',
      'togglePlayback',
      'seekBackward',
      'seekForward',
      'volumeUp',
      'volumeDown',
      'none',
    ];
    for (final left in ids) {
      for (final right in ids) {
        final restored = PlayerOptions.fromJson({
          'doubleClickLeft': left,
          'doubleClickRight': right,
        }).toJson();
        expect(restored['doubleClickLeft'], left);
        expect(restored['doubleClickRight'], right);
      }
    }
  });

  test('无效动作独立回落全屏，不覆盖另一侧的合法配置', () {
    for (final invalid in [null, '', 'unknown', 1, true, <Object>[]]) {
      final restored = PlayerOptions.fromJson({
        'doubleClickLeft': invalid,
        'doubleClickRight': 'none',
      }).toJson();
      expect(restored['doubleClickLeft'], 'toggleFullscreen');
      expect(restored['doubleClickRight'], 'none');
    }
    final restored = PlayerOptions.fromJson({
      'doubleClickLeft': 'volumeDown',
      'doubleClickRight': 'unknown',
    }).toJson();
    expect(restored['doubleClickLeft'], 'volumeDown');
    expect(restored['doubleClickRight'], 'toggleFullscreen');
  });

  test('normalized 与更新其他设置不丢失左右动作', () {
    final options = PlayerOptions.fromJson({
      'doubleClickLeft': 'seekBackward',
      'doubleClickRight': 'volumeUp',
    }).normalized().copyWith(cache: false);
    final json = options.toJson();
    expect(json['doubleClickLeft'], 'seekBackward');
    expect(json['doubleClickRight'], 'volumeUp');
    expect(json['cache'], false);
    expect(options.mpvProperties.containsKey('doubleClickLeft'), isFalse);
    expect(options.mpvProperties.containsKey('doubleClickRight'), isFalse);
  });

  test('左右动作均参与相等性，更新才会通知并落盘', () {
    const defaults = PlayerOptions.defaults();
    final left = PlayerOptions.fromJson({'doubleClickLeft': 'none'});
    final right = PlayerOptions.fromJson({'doubleClickRight': 'none'});
    expect(left, isNot(defaults));
    expect(right, isNot(defaults));
    expect(left, isNot(right));
    expect({defaults, left, right}.length, 3);
    final restored = PlayerOptions.fromJson(left.toJson());
    expect(restored, left);
    expect(restored.hashCode, left.hashCode);
  });

  test('真实偏好存储保存左右配置并保留其他设置', () async {
    final temp = await Directory.systemTemp.createTemp('webhtv-double-click-');
    final path = '${temp.path}${Platform.pathSeparator}settings.json';
    try {
      await File(path).writeAsString(
        jsonEncode({
          'ui': {'themeMode': 'dark'},
          'unrelated': {'keep': true},
        }),
      );
      final store = UiPreferencesStore(path: path);
      await store.load();
      final saved = await store.rememberPlayerOptions(
        PlayerOptions.fromJson({
          'doubleClickLeft': 'seekBackward',
          'doubleClickRight': 'seekForward',
          'cache': false,
        }),
      );
      expect(saved, isTrue);
      final disk = jsonDecode(await File(path).readAsString()) as Map;
      expect((disk['player'] as Map)['doubleClickLeft'], 'seekBackward');
      expect((disk['player'] as Map)['doubleClickRight'], 'seekForward');
      expect(disk['unrelated'], {'keep': true});
      final reopened = UiPreferencesStore(path: path);
      await reopened.load();
      final json = reopened.playerOptions.toJson();
      expect(json['doubleClickLeft'], 'seekBackward');
      expect(json['doubleClickRight'], 'seekForward');
      expect(json['cache'], false);
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
