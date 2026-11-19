/// 次字幕轨与字幕/音轨时间偏移（迭代 2 Wave 1 的纯核心能力）。
///
/// 锁三件事：
/// 1. 偏移模型：±60 s **夹取**（超限夹住而不是拒绝）、毫秒↔秒换算、落盘往返；
/// 2. mpv 白名单：`sub-delay` / `audio-delay` / `secondary-sid` 的值域，
///    非法值到不了内核；
/// 3. 回读容差：mpv 打印 double 的末位噪声不能把「写进去了」判成失败。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/mpv_properties.dart';
import 'package:webhtv_pc/core/player_tracks.dart';

void main() {
  group('偏移模型（TrackOffset）', () {
    test('区间内原样保留', () {
      expect(
        TrackOffset(
          kind: TrackOffsetKind.subtitle,
          milliseconds: 500,
        ).milliseconds,
        500,
      );
      expect(
        TrackOffset(
          kind: TrackOffsetKind.subtitle,
          milliseconds: -500,
        ).milliseconds,
        -500,
      );
      expect(
        TrackOffset(
          kind: TrackOffsetKind.audio,
          milliseconds: TrackOffset.maxMilliseconds,
        ).milliseconds,
        60000,
      );
      expect(
        TrackOffset(
          kind: TrackOffsetKind.audio,
          milliseconds: -TrackOffset.maxMilliseconds,
        ).milliseconds,
        -60000,
      );
    });

    test('超限夹到 ±60 s，不抛也不拒绝', () {
      final cases = <int, int>{
        60001: 60000,
        -60001: -60000,
        90000: 60000,
        -90000: -60000,
        2147483647: 60000,
        -2147483648: -60000,
      };
      cases.forEach((input, expected) {
        final offset = TrackOffset(
          kind: TrackOffsetKind.subtitle,
          milliseconds: input,
        );
        expect(
          offset.milliseconds,
          expected,
          reason: '输入 $input 应被夹到 $expected 而不是被拒绝',
        );
      });
      expect(
        TrackOffset.clampMilliseconds(123456),
        TrackOffset.maxMilliseconds,
      );
      expect(
        TrackOffset.clampMilliseconds(-123456),
        -TrackOffset.maxMilliseconds,
      );
      expect(TrackOffset.clampMilliseconds(250), 250);
    });

    test('毫秒 → mpv 秒：固定 3 位小数、正负号原样', () {
      const expected = <int, String>{
        0: '0.000',
        1: '0.001',
        -1: '-0.001',
        500: '0.500',
        -250: '-0.250',
        1100: '1.100',
        60000: '60.000',
        -60000: '-60.000',
      };
      expected.forEach((milliseconds, seconds) {
        expect(
          TrackOffset(
            kind: TrackOffsetKind.subtitle,
            milliseconds: milliseconds,
          ).mpvValue,
          seconds,
          reason: '$milliseconds ms 应写成 $seconds 秒',
        );
        expect(mpvSecondsFromMilliseconds(milliseconds), seconds);
      });
    });

    test('注入 mpv 的属性名跟着 kind 走', () {
      final subtitle = TrackOffset(
        kind: TrackOffsetKind.subtitle,
        milliseconds: 500,
      );
      final audio = TrackOffset(
        kind: TrackOffsetKind.audio,
        milliseconds: -250,
      );
      expect(subtitle.toMpvProperty(), {'sub-delay': '0.500'});
      expect(audio.toMpvProperty(), {'audio-delay': '-0.250'});
      // 产出的属性必须能过自家白名单——否则「有偏移」等于「静默丢弃」。
      expect(
        filterMpvProperties({
          ...subtitle.toMpvProperty(),
          ...audio.toMpvProperty(),
        }).rejected,
        isEmpty,
      );
    });

    test('copyWith 改值后仍受夹取约束', () {
      final base = TrackOffset(
        kind: TrackOffsetKind.subtitle,
        milliseconds: 200,
      );
      expect(base.copyWith(milliseconds: 90000).milliseconds, 60000);
      expect(base.copyWith(milliseconds: -90000).milliseconds, -60000);
      final moved = base.copyWith(kind: TrackOffsetKind.audio);
      expect(moved.kind, TrackOffsetKind.audio);
      expect(moved.milliseconds, 200, reason: '只改 kind 不该动数值');
      expect(base.copyWith().milliseconds, 200);
    });

    test('落盘往返：kind + ms，越界读回被夹取', () {
      final offset = TrackOffset(
        kind: TrackOffsetKind.audio,
        milliseconds: -250,
      );
      expect(offset.toJson(), {'kind': 'audio', 'ms': -250});
      expect(TrackOffset.fromJson(offset.toJson()), offset);

      final clamped = TrackOffset.fromJson({'kind': 'subtitle', 'ms': 999999});
      expect(clamped, isNotNull);
      expect(clamped!.milliseconds, 60000, reason: '越界值夹取而不是丢弃');
      expect(clamped.kind, TrackOffsetKind.subtitle);

      expect(
        TrackOffset.fromJson({'kind': 'subtitle', 'ms': 500.4})!.milliseconds,
        500,
        reason: '浮点毫秒按四舍五入落成整数',
      );
    });

    test('落盘解析：缺 kind / 未知 kind / 非数字 ms 一律 null', () {
      for (final raw in <Object?>[
        null,
        'subtitle',
        42,
        <String, Object?>{},
        {'ms': 500},
        {'kind': 'subtitle'},
        {'kind': 'subtitle', 'ms': '500'},
        {'kind': 'video', 'ms': 500},
      ]) {
        expect(TrackOffset.fromJson(raw), isNull, reason: 'raw=$raw');
      }
    });

    test('零偏移与相等语义', () {
      final zero = TrackOffset(kind: TrackOffsetKind.subtitle);
      expect(zero.milliseconds, 0);
      expect(zero.isZero, isTrue);
      expect(zero.mpvValue, '0.000');
      expect(zero, TrackOffset(kind: TrackOffsetKind.subtitle, milliseconds: 0));
      expect(
        zero,
        isNot(TrackOffset(kind: TrackOffsetKind.audio, milliseconds: 0)),
        reason: 'kind 参与相等判定',
      );
      expect(zero.hashCode, TrackOffset(kind: TrackOffsetKind.subtitle).hashCode);
    });
  });

  group('mpv 白名单：偏移与次字幕（mpv_properties）', () {
    test('三个新键进表且可回读验证', () {
      expect(mpvPropertyWhitelistKeys, containsAll(<String>[
        'sub-delay',
        'audio-delay',
        'secondary-sid',
      ]));
      for (final key in ['sub-delay', 'audio-delay', 'secondary-sid']) {
        expect(isWhitelistedMpvProperty(key), isTrue, reason: key);
        expect(mpvPropertyRule(key)!.verifiable, isTrue, reason: key);
        expect(mpvPropertyRule(key)!.key, key);
      }
    });

    test('合法偏移放行（含边界与 3 位小数）', () {
      for (final value in <String>[
        '0',
        '0.000',
        '0.500',
        '-0.250',
        '60',
        '60.000',
        '-60.000',
        '-0.001',
      ]) {
        final result = filterMpvProperties({'sub-delay': value});
        expect(result.rejected, isEmpty, reason: 'sub-delay=$value 应放行');
        expect(result.accepted, {'sub-delay': value});
        expect(
          filterMpvProperties({'audio-delay': value}).rejected,
          isEmpty,
          reason: 'audio-delay=$value 应放行',
        );
      }
    });

    test('非法偏移被拒：越界、非数值、非本应用形态', () {
      const rejected = <String>[
        '61', // 越上界
        '-60.001', // 越下界（1 ms）
        '999', // 数量级不对
        '0.5s',
        '+0.5',
        '1e3',
        '0.1234', // 4 位小数不是本应用写出去的形态
        '',
        'nan',
        'inf',
        ' -0.250', // 带前导空格是拼串的痕迹
      ];
      for (final value in rejected) {
        expect(
          filterMpvProperties({'sub-delay': value}).rejected.single.reason,
          contains('±60'),
          reason: 'sub-delay=$value 应被拒',
        );
      }
    });

    test('次字幕 id：auto / no / 轨道号放行', () {
      for (final value in <String>['auto', 'no', '1', '12', '9999']) {
        final requested = {'secondary-sid': value};
        final result = filterMpvProperties(requested);
        expect(result.rejected, isEmpty, reason: 'secondary-sid=$value 应放行');
        expect(result.accepted, requested);
      }
    });

    test('次字幕 id：其余形态一律拒', () {
      const rejected = <String>[
        '0', // 轨道号从 1 开始
        '-1',
        '1.0',
        '10000', // 5 位不是轨道号
        'auto1',
        'no-auto',
        'none', // 只认 no（本应用只写这一种）
        ' 1',
        '',
        'sid=1',
      ];
      for (final value in rejected) {
        final result = filterMpvProperties({'secondary-sid': value});
        expect(
          result.rejected.single.reason,
          contains('轨道号'),
          reason: 'secondary-sid=$value 应被拒',
        );
      }
    });

    test('空白与脏值不因新规则而放宽', () {
      final result = filterMpvProperties({
        'sub-delay': '0.500',
        'audio-delay': '0.500\n',
        'secondary-sid': 'no',
        'secondary-sid2': 'no',
      });
      expect(result.accepted, {'sub-delay': '0.500', 'secondary-sid': 'no'});
      expect(result.rejected.map((item) => item.key), [
        'audio-delay',
        'secondary-sid2',
      ]);
    });
  });

  group('回读容差', () {
    test('浮点往返：0.5 读回 0.500 算成功', () {
      expect(mpvPropertyReadbackMatches('0.5', '0.500'), isTrue);
      expect(mpvPropertyReadbackMatches('0.500', '0.500000'), isTrue);
      expect(mpvPropertyReadbackMatches('-0.25', '-0.250000'), isTrue);
      expect(mpvPropertyReadbackMatches('0', '0.000000'), isTrue);
      expect(mpvPropertyReadbackMatches('60.000', '60'), isTrue);
    });

    test('末位噪声：严格相等会误判，偏移口径不能误判', () {
      const noise = '0.09999999999999999';
      expect(
        mpvPropertyReadbackMatches('0.100', noise),
        isFalse,
        reason: '默认口径是数值相等——这正是偏移不能直接用它的原因',
      );
      expect(
        mpvPropertyReadbackMatches(
          '0.100',
          noise,
          tolerance: mpvDelayToleranceSeconds,
        ),
        isTrue,
      );
      expect(mpvDelayReadbackMatches(100, noise), isTrue);
    });

    test('mpvDelayReadbackMatches：1 ms 容差的边界与失败形态', () {
      expect(mpvDelayReadbackMatches(500, '0.500000'), isTrue);
      expect(mpvDelayReadbackMatches(500, '0.499999'), isTrue);
      expect(mpvDelayReadbackMatches(-250, '-0.250000'), isTrue);
      expect(mpvDelayReadbackMatches(0, '0.001'), isTrue, reason: '差值等于容差');
      expect(mpvDelayReadbackMatches(0, '0.0011'), isFalse);
      expect(mpvDelayReadbackMatches(500, '0.600'), isFalse);
      expect(mpvDelayReadbackMatches(500, '-0.500'), isFalse);
      expect(
        mpvDelayReadbackMatches(0, ''),
        isFalse,
        reason: 'getProperty 读失败返回空串，不能当成功',
      );
      expect(mpvDelayReadbackMatches(500, 'abc'), isFalse);
    });

    test('整数属性不因新增容差参数而放宽', () {
      expect(mpvPropertyReadbackMatches('268435456', '268435457'), isFalse);
      expect(mpvPropertyReadbackMatches('268435456', '268435456.000000'), isTrue);
    });
  });

  group('次字幕轨（PlayerTrackKind / 菜单）', () {
    test('次字幕种类的落盘 id 与中文名', () {
      expect(PlayerTrackKind.secondarySubtitle.id, 'secondary_subtitle');
      expect(PlayerTrackKind.secondarySubtitle.label, '次字幕');
      expect(PlayerTrackKind.audio.id, 'audio', reason: '既有 id 不得改名');
      expect(PlayerTrackKind.video.id, 'video');
    });

    const tracks = <PlayerTrackInfo>[
      PlayerTrackInfo(id: 'auto'),
      PlayerTrackInfo(id: '1', title: '中文', language: 'zh'),
      PlayerTrackInfo(id: '2', title: '英文', language: 'en'),
    ];

    test('默认关闭：关闭排第一且被选中，auto 不被同时选中', () {
      final options = buildSecondarySubtitleOptions(tracks: tracks);
      expect(options.map((option) => option.id), ['no', 'auto', '1', '2']);
      expect(options.first.isOff, isTrue);
      expect(options.first.label, '关闭');
      expect(options.first.selected, isTrue);
      expect(
        options.where((option) => option.selected).length,
        1,
        reason: '同时选中两条会让菜单不知道回显哪一项',
      );
      expect(selectedPlayerTrack(options)?.id, 'no');
      expect(
        options.every((option) => option.kind == PlayerTrackKind.secondarySubtitle),
        isTrue,
      );
      expect(
        options.every((option) => option.selectable),
        isTrue,
        reason: '关闭是可点的一项，不能被当成禁用项',
      );
    });

    test('记住的次字幕 id 被选中，关闭项让位', () {
      final options = buildSecondarySubtitleOptions(
        tracks: tracks,
        selectedId: '2',
      );
      expect(options.first.selected, isFalse);
      expect(selectedPlayerTrack(options)?.id, '2');
      expect(options.last.label, '英文 · en');
    });

    test('主字幕那条不出现在候选里', () {
      final options = buildSecondarySubtitleOptions(
        tracks: tracks,
        selectedId: '2',
        excludeId: '1',
      );
      expect(options.map((option) => option.id), ['no', 'auto', '2']);
    });

    test('记住的次字幕就是主字幕那条 → 回落关闭', () {
      final options = buildSecondarySubtitleOptions(
        tracks: tracks,
        selectedId: '1',
        excludeId: '1',
      );
      expect(options.map((option) => option.id), ['no', 'auto', '2']);
      expect(options.first.selected, isTrue);
      expect(selectedPlayerTrack(options)?.id, 'no');
    });

    test('无标题轨按序号兜底命名，且关闭不算可切换轨道', () {
      final options = buildSecondarySubtitleOptions(
        tracks: const [PlayerTrackInfo(id: '4')],
      );
      expect(options.map((option) => option.label), ['关闭', '次字幕 1']);
      expect(
        hasSwitchableTracks(options),
        isFalse,
        reason: '只有一条真实轨 + 关闭，切换没有意义',
      );
      expect(
        hasSwitchableTracks(buildSecondarySubtitleOptions(tracks: tracks)),
        isTrue,
      );
    });
  });
}
