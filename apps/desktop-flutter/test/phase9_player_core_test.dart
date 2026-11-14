import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/lut.dart';
import 'package:webhtv_pc/core/playback_repeat.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/player_tracks.dart';
import 'package:webhtv_pc/core/skip_segments.dart';
import 'package:webhtv_pc/core/sleep_timer.dart';

void main() {
  group('P0-3 连播/循环裁决（design/01 §4.1）', () {
    PlaybackAdvance decide({
      PlaybackRepeat repeat = PlaybackRepeat.off,
      bool autoNext = true,
      int current = 0,
      int count = 3,
      bool genuine = true,
    }) => decidePlaybackAdvance(
      repeat: repeat,
      autoNext: autoNext,
      currentIndex: current,
      episodeCount: count,
      genuineEnd: genuine,
    );

    test('非真正结束一律停止（失败/提前 EOF 不连播）', () {
      expect(decide(genuine: false).action, PlaybackAdvanceAction.stop);
      expect(
        decide(repeat: PlaybackRepeat.all, genuine: false).action,
        PlaybackAdvanceAction.stop,
      );
    });

    test('off + autoNext：进下一集，末集停止', () {
      final middle = decide(current: 0, count: 3);
      expect(middle.action, PlaybackAdvanceAction.playIndex);
      expect(middle.nextIndex, 1);

      final last = decide(current: 2, count: 3);
      expect(last.action, PlaybackAdvanceAction.stop);
    });

    test('off + autoNext=false：任何位置都停止', () {
      expect(
        decide(autoNext: false, current: 0, count: 3).action,
        PlaybackAdvanceAction.stop,
      );
    });

    test('one：始终重播当前集', () {
      final result = decide(repeat: PlaybackRepeat.one, current: 2, count: 3);
      expect(result.action, PlaybackAdvanceAction.replay);
      expect(result.nextIndex, isNull);
    });

    test('all：末集回到第一集', () {
      final result = decide(repeat: PlaybackRepeat.all, current: 2, count: 3);
      expect(result.action, PlaybackAdvanceAction.playIndex);
      expect(result.nextIndex, 0);
    });

    test('all：autoNext=false 也循环（循环优先）', () {
      final result = decide(
        repeat: PlaybackRepeat.all,
        autoNext: false,
        current: 0,
        count: 3,
      );
      expect(result.nextIndex, 1);
    });

    test('空列表/非法下标不构造非法操作', () {
      expect(decide(count: 0).action, PlaybackAdvanceAction.stop);
      expect(decide(current: 9, count: 3).action, PlaybackAdvanceAction.stop);
      expect(decide(current: -1, count: 3).action, PlaybackAdvanceAction.stop);
    });

    test('落盘标识稳定', () {
      expect(PlaybackRepeat.fromId('one'), PlaybackRepeat.one);
      expect(PlaybackRepeat.fromId('ALL'), PlaybackRepeat.all);
      expect(PlaybackRepeat.fromId('nope'), PlaybackRepeat.off);
      expect(PlaybackRepeat.fromId(null), PlaybackRepeat.off);
      expect(
        PlaybackRepeat.values.map((e) => e.id).toList(),
        ['off', 'one', 'all'],
      );
    });
  });

  group('P0-3 定时关闭（design/01 §4.2）', () {
    final base = DateTime(2026, 10, 21, 12);

    test('空闲不活跃', () {
      const idle = SleepTimerPlan.idle();
      expect(idle.idle, isTrue);
      expect(idle.active, isFalse);
      expect(idle.remaining(base), isNull);
      expect(idle.isExpired(base), isFalse);
      expect(idle.summary, '关闭');
    });

    test('倒计时剩余与到点', () {
      final plan = SleepTimerPlan.forDuration(
        const Duration(minutes: 30),
        now: base,
      );
      expect(plan.active, isTrue);
      expect(
        plan.remaining(base.add(const Duration(minutes: 10))),
        const Duration(minutes: 20),
      );
      expect(plan.isExpired(base.add(const Duration(minutes: 29))), isFalse);
      expect(plan.isExpired(base.add(const Duration(minutes: 30))), isTrue);
      // 过期后剩余不为负。
      expect(
        plan.remaining(base.add(const Duration(hours: 1))),
        Duration.zero,
      );
    });

    test('本集结束模式：不到点，只在剧集结束时停', () {
      const plan = SleepTimerPlan.untilEpisodeEnd();
      expect(plan.active, isTrue);
      expect(plan.isExpired(base), isFalse);
      expect(plan.remaining(base), isNull);
      expect(plan.shouldStopOnEpisodeEnd(), isTrue);
      expect(plan.summary, '本集结束后关闭');
    });

    test('负时长按 0 处理（立即到点）', () {
      final plan = SleepTimerPlan.forDuration(
        const Duration(seconds: -5),
        now: base,
      );
      expect(plan.isExpired(base), isTrue);
    });

    test('预设分钟数稳定', () {
      expect(kSleepTimerMinutes, [15, 30, 60, 90]);
    });
  });

  group('P0-2 片头片尾（design/01 §3）', () {
    const duration = 30 * 60 * 1000;
    const segments = SkipSegments(introEndMs: 90 * 1000, outroStartMs: 28 * 60 * 1000);

    SkipDecision decide(
      int position, {
      bool autoIntro = true,
      bool autoOutro = true,
      bool introDone = false,
      bool outroDone = false,
    }) => segments.decide(
      positionMs: position,
      durationMs: duration,
      autoIntro: autoIntro,
      autoOutro: autoOutro,
      introDone: introDone,
      outroDone: outroDone,
    );

    test('片头区间内跳一次', () {
      final result = decide(5 * 1000);
      expect(result.action, SkipAction.intro);
      expect(result.targetMs, 90 * 1000);
    });

    test('已经跳过/续播在片头之后都不再跳', () {
      expect(decide(5 * 1000, introDone: true).action, SkipAction.none);
      expect(decide(120 * 1000).action, SkipAction.none);
    });

    test('关闭开关不跳', () {
      expect(decide(5 * 1000, autoIntro: false).action, SkipAction.none);
      expect(
        decide(29 * 60 * 1000, autoOutro: false).action,
        SkipAction.none,
      );
    });

    test('片尾区间跳到视频结束', () {
      final result = decide(29 * 60 * 1000);
      expect(result.action, SkipAction.outro);
      expect(result.targetMs, duration);
      expect(decide(29 * 60 * 1000, outroDone: true).action, SkipAction.none);
    });

    test('非法时长/贴边标记一律忽略', () {
      expect(
        const SkipSegments(introEndMs: 1000).normalizedFor(duration).hasIntro,
        isFalse,
      );
      expect(
        const SkipSegments(introEndMs: 4000, outroStartMs: 3000)
            .normalizedFor(duration)
            .hasOutro,
        isFalse,
      );
      expect(
        const SkipSegments(introEndMs: 90000).normalizedFor(0).isEmpty,
        isTrue,
      );
    });

    test('从毫秒字段解析时过滤非正数', () {
      final parsed = SkipSegments.fromMs(openingMs: 90000, endingMs: -1);
      expect(parsed.introEndMs, 90000);
      expect(parsed.outroStartMs, isNull);
      expect(SkipSegments.fromMs(openingMs: 'abc').isEmpty, isTrue);
    });
  });

  group('P0-1 轨道视图（design/01 §2.1）', () {
    test('过滤 no、保留 auto、按引擎顺序', () {
      final options = buildPlayerTrackOptions(
        kind: PlayerTrackKind.audio,
        tracks: const [
          PlayerTrackInfo(id: 'auto'),
          PlayerTrackInfo(id: 'no'),
          PlayerTrackInfo(id: '1', title: '国语', language: 'zh', isDefault: true),
          PlayerTrackInfo(id: '2', title: '', language: 'en'),
        ],
        selectedId: '2',
      );
      expect(options.map((e) => e.id), ['auto', '1', '2']);
      expect(options.first.selected, isFalse);
      expect(options[1].label, '国语 · zh');
      expect(options[2].label, '音轨 2 · en');
      expect(options[2].selected, isTrue);
    });

    test('selectedId 为空时选中 auto', () {
      final options = buildPlayerTrackOptions(
        kind: PlayerTrackKind.video,
        tracks: const [PlayerTrackInfo(id: 'auto'), PlayerTrackInfo(id: '1')],
      );
      expect(options.first.selected, isTrue);
    });

    test('单轨时入口不可切换', () {
      final options = buildPlayerTrackOptions(
        kind: PlayerTrackKind.audio,
        tracks: const [PlayerTrackInfo(id: 'auto'), PlayerTrackInfo(id: '1')],
      );
      expect(hasSwitchableTracks(options), isFalse);
    });

    test('双轨时入口可切换', () {
      final options = buildPlayerTrackOptions(
        kind: PlayerTrackKind.audio,
        tracks: const [
          PlayerTrackInfo(id: 'auto'),
          PlayerTrackInfo(id: '1'),
          PlayerTrackInfo(id: '2'),
        ],
      );
      expect(hasSwitchableTracks(options), isTrue);
      expect(selectedPlayerTrack(options)?.id, 'auto');
    });
  });

  group('P0-4 播放参数（design/01 §5）', () {
    test('默认值等价当前行为', () {
      const options = PlayerOptions.defaults();
      expect(options.hardwareDecoding, isTrue);
      expect(options.cache, isTrue);
      expect(options.autoNext, isTrue);
      expect(options.preloadNext, isFalse);
      expect(options.failureFallback, PlayerFailureFallback.line);
      expect(options.autoSkipIntro, isFalse);
      expect(options.longPressSpeed, 3, reason: '长按倍速默认 3×（2026-11 起）');
    });

    test('长按画面倍速：默认 3×、越界夹取、脏值回落、往返保留', () {
      expect(PlayerOptions.defaults().longPressSpeed, 3);
      expect(PlayerOptions.longPressSpeedChoices, [2, 2.5, 3, 4]);

      expect(
        PlayerOptions.fromJson({'longPressSpeed': 9}).longPressSpeed,
        PlayerOptions.maxLongPressSpeed,
        reason: '越界向上夹到 4×',
      );
      expect(
        PlayerOptions.fromJson({'longPressSpeed': 0}).longPressSpeed,
        PlayerOptions.minLongPressSpeed,
        reason: '越界向下夹到 2×',
      );
      expect(
        PlayerOptions.fromJson({'longPressSpeed': 'fast'}).longPressSpeed,
        PlayerOptions.defaultLongPressSpeed,
        reason: '脏类型回落默认，不抛异常',
      );
      expect(
        PlayerOptions.fromJson({'longPressSpeed': double.nan}).longPressSpeed,
        PlayerOptions.defaultLongPressSpeed,
        reason: 'NaN 夹不了，直接回落默认',
      );

      // 区间内但不在常用档位表里的值必须保留：手改配置不该被静默改写。
      const custom = PlayerOptions(longPressSpeed: 3.5);
      expect(PlayerOptions.fromJson(custom.toJson()), custom);
      expect(custom.copyWith(longPressSpeed: 2.5).longPressSpeed, 2.5);
    });

    test('mpv 属性映射', () {
      const options = PlayerOptions(
        hardwareDecoding: false,
        cache: false,
        demuxerMaxBytesMiB: 128,
        demuxerMaxBackBytesMiB: 32,
        audioPassthrough: true,
      );
      final props = options.mpvProperties;
      expect(props['hwdec'], 'no');
      expect(props['cache'], 'no');
      expect(props['demuxer-max-bytes'], '${128 * 1024 * 1024}');
      expect(props['demuxer-max-back-bytes'], '${32 * 1024 * 1024}');
      expect(props['audio-spdif'], 'ac3,eac3,dts');
    });

    test('越界值被夹住，脏类型回落默认', () {
      final options = PlayerOptions.fromJson({
        'demuxerMaxBytesMiB': 999999,
        'demuxerMaxBackBytesMiB': -1,
        'autoNext': 'yes',
        'failureFallback': 'nonsense',
      });
      expect(options.demuxerMaxBytesMiB, PlayerOptions.maxDemuxerMaxMiB);
      expect(options.demuxerMaxBackBytesMiB, PlayerOptions.minDemuxerBackMiB);
      expect(options.autoNext, isTrue);
      expect(options.failureFallback, PlayerFailureFallback.line);
    });

    test('回退阶梯能力判定', () {
      expect(PlayerFailureFallback.off.allowsParse, isFalse);
      expect(PlayerFailureFallback.line.allowsParse, isFalse);
      expect(PlayerFailureFallback.lineAndParse.allowsParse, isTrue);
      expect(PlayerFailureFallback.lineAndParse.allowsSource, isFalse);
      expect(PlayerFailureFallback.lineAndParseAndSource.allowsSource, isTrue);
    });

    test('序列化往返', () {
      const options = PlayerOptions(
        autoNext: false,
        preloadNext: true,
        autoSkipIntro: true,
        failureFallback: PlayerFailureFallback.off,
      );
      final restored = PlayerOptions.fromJson(options.toJson());
      expect(restored, options);
    });
  });

  group('P0-5 LUT 解析（design/01 §6）', () {
    String cube(int size) {
      final buffer = StringBuffer()
        ..writeln('TITLE "Test LUT"')
        ..writeln('LUT_3D_SIZE $size');
      for (var i = 0; i < size * size * size; i++) {
        buffer.writeln('0.0 0.5 1.0');
      }
      return buffer.toString();
    }

    test('合法 3D LUT 解析成功', () {
      final result = parseCube(cube(2), path: r'C:\luts\test.cube');
      expect(result.ok, isTrue);
      expect(result.preset!.size, 2);
      expect(result.preset!.name, 'Test LUT');
      expect(result.preset!.path, r'C:\luts\test.cube');
    });

    test('数据行数不符要报错', () {
      final text = cube(2).replaceFirst('0.0 0.5 1.0\n', '');
      final result = parseCube(text, path: 'x.cube');
      expect(result.ok, isFalse);
      expect(result.error, contains('数据行数不符'));
    });

    test('缺 LUT_3D_SIZE 报错', () {
      final result = parseCube('0 0 0\n', path: 'x.cube');
      expect(result.ok, isFalse);
      expect(result.error, contains('LUT_3D_SIZE'));
    });

    test('1D LUT 明确不支持', () {
      final result = parseCube(
        'LUT_1D_SIZE 2\n0 0 0\n1 1 1\n',
        path: 'x.cube',
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('1D'));
    });

    test('mpv vf 参数转义 Windows 路径', () {
      expect(buildLutVfArgument(null), '');
      expect(
        buildLutVfArgument(r'C:\luts\a b.cube'),
        "lavfi=[lut3d=file='C:/luts/a b.cube']",
      );
    });
  });
}
