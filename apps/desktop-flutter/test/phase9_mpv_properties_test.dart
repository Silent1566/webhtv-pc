/// mpv 属性白名单与 HDR 色调映射（`docs/phase9/design/01` §5.1、§5.2）。
///
/// 锁两件事：
/// 1. 注入通道收窄到本应用自己产出的属性——表外的键、非法的值到不了内核；
/// 2. HDR 新选项的默认值等价于内核默认（改造前行为），且映射名与 mpv 一致。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/lut.dart';
import 'package:webhtv_pc/core/mpv_properties.dart';
import 'package:webhtv_pc/core/player_options.dart';

void main() {
  group('mpv 属性白名单（design/01 §5.2）', () {
    test('放行本应用产出的全部属性', () {
      const options = PlayerOptions(
        hardwareDecoding: false,
        cache: true,
        demuxerMaxBytesMiB: 256,
        demuxerMaxBackBytesMiB: 64,
        audioPassthrough: true,
      );
      final requested = <String, String>{
        ...options.mpvProperties,
        'vf': buildLutVfArgument('/tmp/lut/a.cube'),
      };
      final result = filterMpvProperties(requested);
      expect(result.rejected, isEmpty, reason: '自家产出的属性不许被自家白名单拦下');
      expect(result.accepted, requested);
    });

    test('表外键一律拒绝', () {
      final result = filterMpvProperties({
        'script-opts': 'x=1',
        'input-conf': '/tmp/input.conf',
        'load-script': '/tmp/x.lua',
        'vo': 'gpu',
        'gpu-api': 'vulkan',
        'hwdec': 'no',
      });
      expect(
        result.rejected.map((item) => item.key).toSet(),
        {'script-opts', 'input-conf', 'load-script', 'vo', 'gpu-api'},
      );
      expect(
        result.accepted,
        {'hwdec': 'no'},
        reason: '合法项必须照常注入，不因同批有脏键而全丢',
      );
      expect(result.rejected.first.reason, contains('白名单'));
    });

    test('值域校验：非法值不注入，同批合法项照常注入', () {
      final result = filterMpvProperties({
        'cache': 'maybe',
        'demuxer-max-bytes': '-1',
        'audio-spdif': 'flac',
        'tone-mapping': 'bogus',
        'hdr-compute-peak': 'sometimes',
        'hwdec': 'auto-safe',
      });
      expect(result.accepted, {'hwdec': 'auto-safe'});
      expect(result.rejected, hasLength(5));
      expect(result.hasRejections, isTrue);
    });

    test('vf 只接受空串或 LUT 形态', () {
      expect(
        filterMpvProperties({'vf': ''}).accepted['vf'],
        '',
        reason: '空串表示清除滤镜',
      );
      expect(
        filterMpvProperties({'vf': buildLutVfArgument('/movies/a b.cube')})
            .rejected,
        isEmpty,
      );
      // 追加/替换成别的滤镜＝任意表达式，必须拒绝
      final chained = '${buildLutVfArgument('/tmp/a.cube')},format=yuv420p';
      expect(filterMpvProperties({'vf': chained}).rejected.single.key, 'vf');
      expect(
        filterMpvProperties({'vf': 'format=yuv420p'}).rejected,
        hasLength(1),
      );
      expect(
        filterMpvProperties({"vf": "lavfi=[lut3d=file='a'] ,scale=2"}).rejected,
        hasLength(1),
      );
    });

    test('白名单键枚举与判定一致', () {
      expect(mpvPropertyWhitelistKeys, isNotEmpty);
      for (final key in mpvPropertyWhitelistKeys) {
        expect(isWhitelistedMpvProperty(key), isTrue);
      }
      expect(isWhitelistedMpvProperty('script-opts'), isFalse);
    });
  });

  group('HDR 色调映射（design/01 §5.1）', () {
    test('默认值等价于内核默认（改造前行为）', () {
      const options = PlayerOptions.defaults();
      expect(options.toneMapping, HdrToneMapping.auto);
      expect(options.hdrPeakCompute, HdrPeakCompute.auto);
      expect(options.mpvProperties['tone-mapping'], 'auto');
      expect(options.mpvProperties['hdr-compute-peak'], 'auto');
    });

    test('选项映射到 mpv 取值', () {
      const options = PlayerOptions(
        toneMapping: HdrToneMapping.bt2390,
        hdrPeakCompute: HdrPeakCompute.on,
      );
      expect(options.mpvProperties['tone-mapping'], 'bt.2390');
      expect(options.mpvProperties['hdr-compute-peak'], 'yes');
      expect(
        const PlayerOptions(
          hdrPeakCompute: HdrPeakCompute.off,
        ).mpvProperties['hdr-compute-peak'],
        'no',
      );
    });

    test('落盘往返与脏值回落', () {
      const options = PlayerOptions(
        toneMapping: HdrToneMapping.spline,
        hdrPeakCompute: HdrPeakCompute.off,
      );
      expect(PlayerOptions.fromJson(options.toJson()), options);
      expect(
        PlayerOptions.fromJson({'toneMapping': 'nope'}).toneMapping,
        HdrToneMapping.auto,
      );
      expect(
        PlayerOptions.fromJson({'hdrPeakCompute': 42}).hdrPeakCompute,
        HdrPeakCompute.auto,
      );
      expect(
        PlayerOptions.fromJson({'toneMapping': ' BT.2390 '}).toneMapping,
        HdrToneMapping.bt2390,
      );
    });

    test('copyWith 只改指定项', () {
      const base = PlayerOptions();
      final changed = base.copyWith(hdrPeakCompute: HdrPeakCompute.on);
      expect(changed.hdrPeakCompute, HdrPeakCompute.on);
      expect(changed.toneMapping, HdrToneMapping.auto);
      expect(changed, isNot(base));
    });
  });

  group('属性通道的边界（回归）', () {
    test('vf 不接受追加滤镜或 lut3d 附加参数', () {
      const base = "lavfi=[lut3d=file='/tmp/a.cube']";
      expect(filterMpvProperties({'vf': base}).rejected, isEmpty);

      for (final injected in [
        "lavfi=[lut3d=file='/tmp/a.cube'],format=yuv420p",
        "lavfi=[lut3d=file='/tmp/a.cube':interp=trilinear,movie=/unused/test]",
        '$base\n',
      ]) {
        expect(
          filterMpvProperties({'vf': injected}).rejected.single.key,
          'vf',
          reason: '必须拒绝：$injected',
        );
      }

      // 引号内的逗号是路径的一部分（mpv 实测原样保留），不能误杀。
      expect(
        filterMpvProperties({
          'vf': "lavfi=[lut3d=file='/tmp/a,b.cube']",
        }).rejected,
        isEmpty,
      );
      // 分号在引号外是滤镜链分隔符 —— 必须拒绝。
      expect(
        filterMpvProperties({
          'vf': "lavfi=[lut3d=file='/tmp/a.cube';movie=x]",
        }).rejected,
        hasLength(1),
      );
      // 引号内的分号是路径的一部分（mpv 实测原样保留），不能误杀。
      expect(
        filterMpvProperties({
          'vf': "lavfi=[lut3d=file='/tmp/a;b.cube']",
        }).rejected,
        isEmpty,
      );
      // 主平台是 Windows：反斜杠路径与路径里的引号都必须照常放行。
      expect(
        filterMpvProperties({
          'vf': buildLutVfArgument(r'C:\Movies\a.cube'),
        }).rejected,
        isEmpty,
        reason: 'Windows 反斜杠路径必须通过白名单',
      );
      expect(
        filterMpvProperties({
          'vf': buildLutVfArgument("/movies/it's a cube.cube"),
        }).rejected,
        isEmpty,
        reason: '路径里的单引号由 lut.dart 转义，白名单要认',
      );
    });

    test('值含控制字符一律拒绝', () {
      final result = filterMpvProperties({
        'tone-mapping': 'auto\n',
        'cache': 'yes\r',
        'hwdec': 'no',
      });
      expect(result.accepted, {'hwdec': 'no'});
      expect(
        result.rejected.map((item) => item.reason),
        everyElement('值含控制字符'),
      );
    });

    test('回读比较：数字按数值、其余忽略大小写，空回读不算匹配', () {
      expect(
        mpvPropertyReadbackMatches('268435456', '268435456.000000'),
        isTrue,
      );
      expect(mpvPropertyReadbackMatches('auto-safe', 'AUTO-SAFE'), isTrue);
      expect(mpvPropertyReadbackMatches('yes', 'no'), isFalse);
      expect(
        mpvPropertyReadbackMatches('auto', ''),
        isFalse,
        reason: 'getProperty 读失败返回空串，不能当成功',
      );
      expect(
        mpvPropertyReadbackMatches('', ''),
        isTrue,
        reason: '清空 audio-spdif 是合法写入',
      );
    });

    test('白名单与选项枚举不漂移', () {
      // 新增一个算法却忘了放行，就会在这里红——不是等到播放时才静默丢弃。
      for (final mode in HdrToneMapping.values) {
        expect(
          filterMpvProperties({'tone-mapping': mode.mpvValue}).rejected,
          isEmpty,
          reason: 'tone-mapping 必须放行枚举值 ${mode.id}',
        );
      }
      for (final mode in HdrPeakCompute.values) {
        expect(
          filterMpvProperties({'hdr-compute-peak': mode.mpvValue}).rejected,
          isEmpty,
          reason: 'hdr-compute-peak 必须放行枚举值 ${mode.id}',
        );
      }
    });

    test('vf 不可回读验证，其余属性可验证', () {
      expect(mpvPropertyRule('vf')!.verifiable, isFalse);
      for (final key in ['cache', 'hwdec', 'tone-mapping', 'hdr-compute-peak']) {
        expect(mpvPropertyRule(key)!.verifiable, isTrue, reason: key);
      }
      expect(mpvPropertyRule('script-opts'), isNull);
    });
  });
}
