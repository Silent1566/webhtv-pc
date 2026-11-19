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
        expect(restored.mpvProperties['af'], enabled ? audioNormalizationAf : '');
      }
    });

    test('更新其他参数和归一化不丢失开关，不修改直通偏好', () {
      final options = PlayerOptions.fromJson({
        'audioNormalization': true,
        'audioPassthrough': true,
      }).normalized().copyWith(cache: false);
      expect(options.toJson()['audioNormalization'], true);
      expect(options.mpvProperties['af'], audioNormalizationAf);
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
      for (final value in [audioNormalizationAf, '']) {
        final result = filterMpvProperties({'af': value});
        expect(result.accepted, {'af': value});
        expect(result.rejected, isEmpty);
      }
      // lavfi 形态既能把任意 ffmpeg 滤镜图挂上来（movie= 能读本地文件），
      // 在随包 Windows 内核上还会因为滤镜表是空的而让音轨整条丢失
      // （见 core/mpv_properties.dart 的 audioNormalizationAf），所以一律不收。
      for (final value in [
        'lavfi=[dynaudnorm]',
        'lavfi=[dynaudnorm,movie=/tmp/x]',
        'lavfi=[volume=100]',
        'dynaudnorm=m=99',
        'dynaudnorm,volume=100',
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
      // 内核拒绝写入时回读是空串（NativePlayer.getProperty 读失败也返回空串），
      // 当成功处理就会把"静默没生效"洗成成功——随包 Windows 内核正是这种。
      expect(mpvPropertyReadbackMatches(audioNormalizationAf, ''), false);
      expect(mpvPropertyReadbackMatches('', audioNormalizationAf), false);
      expect(mpvPropertyReadbackMatches(audioNormalizationAf, audioNormalizationAf), true);
    });
  });
}
