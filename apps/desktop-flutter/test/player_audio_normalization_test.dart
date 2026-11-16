import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/mpv_properties.dart';
import 'package:webhtv_pc/core/player_options.dart';

void main() {
  group('全局实时音量归一', () {
    test('默认和旧配置显式清除滤镜而不改变音量相关偏好', () {
      for (final raw in [
        null,
        <String, Object?>{'cache': false},
      ]) {
        final options = PlayerOptions.fromJson(raw);
        expect(options.toJson()['audioNormalization'], false);
        expect(options.mpvProperties['af'], '');
        expect(options.audioPassthrough, false);
      }
      expect(const PlayerOptions.defaults().mpvProperties['af'], '');
    });

    test('只接受布尔值，脏类型不会意外打开归一', () {
      for (final invalid in [null, 'true', 1, <Object>[], <String, Object>{}]) {
        final options = PlayerOptions.fromJson({'audioNormalization': invalid});
        expect(options.toJson()['audioNormalization'], false);
        expect(options.mpvProperties['af'], '');
      }
    });

    test('开关序列化往返分别启用或显式清除实时滤镜', () {
      for (final enabled in [true, false]) {
        final options = PlayerOptions.fromJson({'audioNormalization': enabled});
        final restored = PlayerOptions.fromJson(options.toJson());
        expect(restored.toJson()['audioNormalization'], enabled);
        expect(restored.mpvProperties['af'], enabled ? 'dynaudnorm' : '');
      }
    });

    test('更新其他参数和归一化不丢失开关，不修改直通偏好', () {
      final options = PlayerOptions.fromJson({
        'audioNormalization': true,
        'audioPassthrough': true,
      }).normalized().copyWith(cache: false);
      expect(options.toJson()['audioNormalization'], true);
      expect(options.mpvProperties['af'], 'dynaudnorm');
      expect(options.mpvProperties['audio-spdif'], 'ac3,eac3,dts');
      expect(options.cache, false);
    });

    test('开关参与相等性以便真实更新能落盘和通知', () {
      const defaults = PlayerOptions.defaults();
      final enabled = PlayerOptions.fromJson({'audioNormalization': true});
      final enabledAgain = PlayerOptions.fromJson({'audioNormalization': true});
      expect(enabled, isNot(defaults));
      expect(enabledAgain, enabled);
      expect(enabledAgain.hashCode, enabled.hashCode);
      expect({defaults, enabled, enabledAgain}, hasLength(2));
    });

    test('白名单仅接受默认 dynaudnorm 或清空，不开放任意音频滤镜', () {
      for (final value in ['dynaudnorm', '']) {
        final result = filterMpvProperties({'af': value});
        expect(result.accepted, {'af': value});
        expect(result.rejected, isEmpty);
      }
      for (final value in [
        'dynaudnorm=m=99',
        'dynaudnorm,volume=100',
        'lavfi=[dynaudnorm]',
        'loudnorm',
        'dynaudnorm\n',
      ]) {
        final result = filterMpvProperties({'af': value});
        expect(result.accepted, isEmpty);
        expect(result.rejected, hasLength(1));
      }
    });

    test('音频滤镜写入仍需回读，不忽略内核的静默拒绝', () {
      expect(mpvPropertyRule('af')?.verifiable, true);
      expect(mpvPropertyReadbackMatches('dynaudnorm', ''), false);
      expect(mpvPropertyReadbackMatches('', 'dynaudnorm'), false);
    });
  });
}
