/// 字幕/音轨时间偏移接到播放器（迭代 2 Wave 2-B）。
///
/// 锁四件事：
/// 1. `PlayerOptions` 的两个偏移字段：缺键即 0（老配置向后兼容）、落盘往返、
///    越界**夹取**而不是拒绝；
/// 2. 偏移跟着整表 mpv 属性一起注入：mpv 的 `sub-delay`/`audio-delay` 是按文件
///    的选项，换集会回到 0，只在界面里记住等于「下一集失效」；
/// 3. 步进与归零：±100 ms 的整数倍累积，到 ±60 s 就夹住；
/// 4. 控制器写入路径 [writeTrackOffsetProperty]：写下去的是**白名单过滤后**的
///    秒值，回读不匹配/写入抛错都降级成 `applied: false`，**不抛**给 UI。
///
/// 第 4 条为什么测顶层函数而不是 `PlayerController.setTrackOffset`：控制器的构造
/// 要 MediaKit 内核（`flutter test` 默认没有 libmpv），而这里要断言的正是编排本身
/// ——过滤、写入、回读判定、失败降级。控制器只是「取 platform → 调这个函数 →
/// 记 rejection」，与 `player_tracks.dart` 的 `applyTrackChoice` 同一手法。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/mpv_properties.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/player_tracks.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

void main() {
  group('偏移字段落盘（PlayerOptions）', () {
    test('缺键即 0：老 settings.json 读出来没有偏移', () {
      final restored = PlayerOptions.fromJson(<String, Object?>{
        'hardwareDecoding': false,
        'cache': true,
      });
      expect(restored.subtitleOffsetMs, 0);
      expect(restored.audioOffsetMs, 0);
      expect(const PlayerOptions.defaults().subtitleOffsetMs, 0);
      expect(const PlayerOptions.defaults().audioOffsetMs, 0);
    });

    test('落盘往返：两个偏移原样读回', () {
      const custom = PlayerOptions(subtitleOffsetMs: 500, audioOffsetMs: -250);
      final json = custom.toJson();
      expect(json['subtitleOffsetMs'], 500);
      expect(json['audioOffsetMs'], -250);
      expect(PlayerOptions.fromJson(json), custom);
      expect(PlayerOptions.fromJson(json).subtitleOffsetMs, 500);
      expect(PlayerOptions.fromJson(json).audioOffsetMs, -250);
    });

    test('越界夹进 ±60 s，脏类型回落 0（都不拒绝）', () {
      final restored = PlayerOptions.fromJson(<String, Object?>{
        'subtitleOffsetMs': 999999,
        'audioOffsetMs': -999999,
      });
      expect(restored.subtitleOffsetMs, TrackOffset.maxMilliseconds);
      expect(restored.audioOffsetMs, -TrackOffset.maxMilliseconds);

      final dirty = PlayerOptions.fromJson(<String, Object?>{
        'subtitleOffsetMs': 'abc',
        'audioOffsetMs': null,
      });
      expect(dirty.subtitleOffsetMs, 0);
      expect(dirty.audioOffsetMs, 0);

      // 构造出来的越界值也会被 normalized() 夹住（落盘前必走这一步）。
      expect(
        const PlayerOptions(subtitleOffsetMs: 70000)
            .normalized()
            .subtitleOffsetMs,
        TrackOffset.maxMilliseconds,
      );
    });

    test('copyWith 只改点名的那一项', () {
      const base = PlayerOptions(subtitleOffsetMs: 300, audioOffsetMs: -200);
      final next = base.copyWith(subtitleOffsetMs: 100);
      expect(next.subtitleOffsetMs, 100);
      expect(next.audioOffsetMs, -200);
      expect(next, isNot(base));
      // 不带参数时整体相等：hashCode 也得跟着一致。
      expect(base.copyWith(), base);
      expect(base.copyWith().hashCode, base.hashCode);
    });
  });

  group('偏移注入 mpv 属性', () {
    test('按秒写，且通过白名单', () {
      const options = PlayerOptions(subtitleOffsetMs: 500, audioOffsetMs: -250);
      final props = options.mpvProperties;
      expect(props['sub-delay'], '0.500');
      expect(props['audio-delay'], '-0.250');
      final filtered = filterMpvProperties(props);
      expect(filtered.rejected, isEmpty, reason: '自家产出的属性不许被自家白名单拦下');
      expect(filtered.accepted['sub-delay'], '0.500');
      expect(filtered.accepted['audio-delay'], '-0.250');
    });

    test('默认 0 也写出 0.000：换集后不会残留上一集的偏移', () {
      final props = const PlayerOptions.defaults().mpvProperties;
      expect(props['sub-delay'], '0.000');
      expect(props['audio-delay'], '0.000');
    });

    test('mpv 属性名能反查回偏移类型（回读口径靠它）', () {
      expect(
        TrackOffsetKind.fromMpvPropertyKey('sub-delay'),
        TrackOffsetKind.subtitle,
      );
      expect(
        TrackOffsetKind.fromMpvPropertyKey('audio-delay'),
        TrackOffsetKind.audio,
      );
      expect(TrackOffsetKind.fromMpvPropertyKey('hwdec'), isNull);
      expect(TrackOffsetKind.fromMpvPropertyKey(''), isNull);
    });
  });

  group('步进夹取与文案', () {
    /// 与菜单里的步进同一条算式：取当前值 → 加一步 → 夹取 → 写回。
    PlayerOptions step(PlayerOptions options, TrackOffsetKind kind, int delta) {
      final current = options.trackOffset(kind);
      return options.withTrackOffset(
        current.copyWith(milliseconds: current.milliseconds + delta),
      );
    }

    test('100 ms 整数倍累积，两类偏移互不干扰', () {
      var options = const PlayerOptions.defaults();
      for (var i = 0; i < 5; i++) {
        options = step(options, TrackOffsetKind.subtitle, 100);
      }
      expect(options.subtitleOffsetMs, 500);
      expect(options.audioOffsetMs, 0);

      options = step(options, TrackOffsetKind.audio, -100);
      expect(options.audioOffsetMs, -100);
      expect(options.subtitleOffsetMs, 500);
      expect(
        options.trackOffset(TrackOffsetKind.subtitle).mpvValue,
        '0.500',
        reason: '内部毫秒、走出去才是秒',
      );
    });

    test('顶到 ±60 s 就夹住，再按也不越界', () {
      var options = const PlayerOptions(subtitleOffsetMs: 59900);
      options = step(options, TrackOffsetKind.subtitle, 100);
      expect(options.subtitleOffsetMs, TrackOffset.maxMilliseconds);
      options = step(options, TrackOffsetKind.subtitle, 100);
      expect(options.subtitleOffsetMs, TrackOffset.maxMilliseconds);

      var low = const PlayerOptions(
        audioOffsetMs: -TrackOffset.maxMilliseconds,
      );
      low = step(low, TrackOffsetKind.audio, -100);
      expect(low.audioOffsetMs, -TrackOffset.maxMilliseconds);
    });

    test('重置回 0', () {
      final reset = const PlayerOptions(
        subtitleOffsetMs: -1200,
        audioOffsetMs: 300,
      ).withTrackOffset(TrackOffset(kind: TrackOffsetKind.subtitle));
      expect(reset.subtitleOffsetMs, 0);
      expect(reset.audioOffsetMs, 300);
    });

    test('文案统一用秒、一位小数、带符号', () {
      expect(formatTrackOffsetSeconds(500), '+0.5 秒');
      expect(formatTrackOffsetSeconds(-300), '-0.3 秒');
      expect(formatTrackOffsetSeconds(0), '0.0 秒');
      // -40 ms 四舍五入到一位小数是 -0.0：不能显示成「偏了一点点」。
      expect(formatTrackOffsetSeconds(-40), '0.0 秒');
      expect(formatTrackOffsetSeconds(TrackOffset.maxMilliseconds), '+60.0 秒');
      expect(formatTrackOffsetSeconds(-TrackOffset.maxMilliseconds), '-60.0 秒');
    });
  });

  group('控制器写入路径（白名单 + 回读降级）', () {
    final offset = TrackOffset(
      kind: TrackOffsetKind.subtitle,
      milliseconds: 500,
    );

    test('写的是白名单过滤之后的那一个值', () async {
      final written = <String, String>{};
      final result = await writeTrackOffsetProperty(
        offset: TrackOffset(kind: TrackOffsetKind.audio, milliseconds: -250),
        setProperty: (key, value) async {
          written[key] = value;
        },
        getProperty: (key) async => '-0.250000',
      );
      expect(result.applied, isTrue);
      expect(result.rejection, isNull);
      // 对照组：把同一个模型过一遍白名单，写下去的值必须逐字相同。
      final filtered = filterMpvProperties(
        TrackOffset(
          kind: TrackOffsetKind.audio,
          milliseconds: -250,
        ).toMpvProperty(),
      ).accepted;
      expect(written, filtered);
      expect(written['audio-delay'], '-0.250');
    });

    test('回读不匹配：降级为 false + 可读原因，不抛', () async {
      final result = await writeTrackOffsetProperty(
        offset: offset,
        setProperty: (key, value) async {},
        getProperty: (key) async => '0.000000',
      );
      expect(result.applied, isFalse);
      expect(result.rejection, isNotNull);
      expect(result.rejection!.key, 'sub-delay');
      expect(result.rejection!.value, '0.500');
      expect(result.rejection!.reason, contains('回读'));
      expect(result.rejection!.reason, contains('0.000000'));
    });

    test('内核不支持（回读为空串）：不抛，按未生效报告', () async {
      final result = await writeTrackOffsetProperty(
        offset: offset,
        setProperty: (key, value) async {},
        getProperty: (key) async => '',
      );
      expect(result.applied, isFalse);
      expect(result.rejection!.reason, contains('回读 空'));
      // 空串不能被当成「写进去了」——读失败与静默拒绝都长这样。
      expect(result.rejection!.reason, isNot(contains('未接受写入（回读 ）')));
    });

    test('写入抛错：不抛，原因带原始错误', () async {
      final result = await writeTrackOffsetProperty(
        offset: offset,
        setProperty: (key, value) async =>
            throw StateError('mpv: property not found'),
        getProperty: (key) async => '',
      );
      expect(result.applied, isFalse);
      expect(result.rejection!.reason, contains('写入失败'));
      expect(result.rejection!.reason, contains('mpv: property not found'));
    });

    test('回读抛错：不抛，原因带原始错误', () async {
      final result = await writeTrackOffsetProperty(
        offset: offset,
        setProperty: (key, value) async {},
        getProperty: (key) async => throw StateError('getProperty failed'),
      );
      expect(result.applied, isFalse);
      expect(result.rejection!.reason, contains('回读失败'));
      expect(result.rejection!.reason, contains('getProperty failed'));
    });
  });
}
