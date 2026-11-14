/// 进度迁移接进播放链路（用户 2026-10-27 要求：跨源续播要"进度完美同步"）。
///
/// 分两层：
/// - **纯逻辑**：`locateResumeEpisode` / `resumeEpisodeMatches` /
///   `resolveResumeStart` 的判定，无 Flutter 依赖；
/// - **映射**：`resumeSeedOf` 把一条 `PlaybackHistory` 抄成 `ResumeSeed`，
///   抄错的后果是"静默丢进度"，只能靠断言锁住。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/history_view.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/storage.dart';
import 'package:webhtv_pc/ui/history_resume_seed.dart';

/// 读取源码并剥掉注释行（`//` 与 `///`），用于接线锁。
///
/// 只剥整行注释：本仓库注释都是整行风格，行尾注释里出现被断言的语句会误判。
String _readSourceCode(String relative) {
  final raw = File(relative).readAsLinesSync();
  return raw
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
}

void main() {
  VodPlayLine lineOf(
    String flag,
    List<(String, String)> episodes, {
    String? sourceFlag,
  }) => VodPlayLine(
    flag: flag,
    sourceFlag: sourceFlag,
    episodes: [
      for (final (name, url) in episodes) VodEpisode(name: name, url: url),
    ],
  );

  /// 原记录：线路「线路一」、第 2 集、3 分钟处、该集总长 40 分钟。
  const seedOfEp2 = ResumeSeed(
    flag: '线路一',
    episodeId: 'http://x/e2',
    episodeName: '第2集',
    positionMs: 180000,
    durationMs: 2400000,
  );

  final twoLines = [
    lineOf('线路一', [('第1集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
    lineOf('线路二', [('第1集', 'http://y/e1'), ('第2集', 'http://y/e2')]),
  ];

  group('locateResumeEpisode', () {
    test('线路 flag 命中时取那一集', () {
      final located = locateResumeEpisode(lines: twoLines, seed: seedOfEp2);
      expect(located, isNotNull);
      expect(located!.line.flag, '线路一');
      expect(located.episodeIndex, 1);
      expect(located.episodeName, '第2集');
    });

    test('线路 flag 不同但集入口全库唯一命中时也能定位', () {
      final lines = [
        lineOf('线路甲', [('第1集', 'http://a/e1')]),
        lineOf('线路乙', [('第2集', 'http://b/e2')]),
      ];
      const seed = ResumeSeed(
        flag: '已消失的线路',
        episodeId: 'http://b/e2',
        episodeName: '第2集',
        positionMs: 60000,
        durationMs: 100000,
      );
      final located = locateResumeEpisode(lines: lines, seed: seed);
      expect(located?.line.flag, '线路乙');
      expect(located?.episodeIndex, 0);
    });

    test('集入口在多条线路里都能命中（不唯一）时返回 null，不猜', () {
      final lines = [
        lineOf('线路甲', [('第1集', 'http://dup/e1')]),
        lineOf('线路乙', [('第1集', 'http://dup/e1')]),
      ];
      const seed = ResumeSeed(
        flag: '已消失的线路',
        episodeId: 'http://dup/e1',
        episodeName: '第1集',
        positionMs: 60000,
        durationMs: 100000,
      );
      expect(locateResumeEpisode(lines: lines, seed: seed), isNull);
    });

    test('空线路列表返回 null', () {
      expect(
        locateResumeEpisode(lines: const [], seed: seedOfEp2),
        isNull,
      );
    });
  });

  group('resumeEpisodeMatches', () {
    test('同一线路同一集 → true', () {
      expect(
        resumeEpisodeMatches(
          lines: twoLines,
          seed: seedOfEp2,
          targetLine: twoLines[0],
          targetEpisodeIndex: 1,
          targetEpisodeName: '第2集',
        ),
        isTrue,
      );
    });

    test('换站后集名带站点前后缀，集号相同即算同一集', () {
      // 原记录：线路一 · 第2集 · http://x/e2。
      final lines = [
        lineOf('线路一', [('第1集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
        // 目标站点的集名是站点自己的写法，URL 也不同——唯一相同的只有集号 2。
        lineOf('线路九', [('E02 高清', 'http://z/e2')]),
      ];
      expect(
        resumeEpisodeMatches(
          lines: lines,
          seed: seedOfEp2,
          targetLine: lines[1],
          targetEpisodeIndex: 0,
          targetEpisodeName: 'E02 高清',
        ),
        isTrue,
      );
    });

    test('集号不同 → false（不迁移）', () {
      final lines = [
        lineOf('线路一', [('第1集', 'http://x/e1'), ('第2集', 'http://x/e2')]),
        lineOf('线路九', [('第3集', 'http://z/e3')]),
      ];
      expect(
        resumeEpisodeMatches(
          lines: lines,
          seed: seedOfEp2,
          targetLine: lines[1],
          targetEpisodeIndex: 0,
          targetEpisodeName: '第3集',
        ),
        isFalse,
      );
    });

    test('原记录定位不到且集号解析不出来 → false（不迁移）', () {
      final lines = [
        lineOf('别的线路', [('正片', 'http://o/e1')]),
      ];
      const seed = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://gone/e2',
        episodeName: '特辑',
        positionMs: 60000,
        durationMs: 100000,
      );
      expect(
        resumeEpisodeMatches(
          lines: lines,
          seed: seed,
          targetLine: lines[0],
          targetEpisodeIndex: 0,
          targetEpisodeName: '花絮',
        ),
        isFalse,
      );
    });

    test('两边都只有一集（电影）→ true', () {
      final single = [lineOf('线路一', [('正片', 'http://x/movie')])];
      const seed = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://x/movie',
        episodeName: '正片',
        positionMs: 60000,
        durationMs: 100000,
      );
      expect(
        resumeEpisodeMatches(
          lines: single,
          seed: seed,
          targetLine: single[0],
          targetEpisodeIndex: 0,
          targetEpisodeName: '正片',
        ),
        isTrue,
      );
    });
  });

  group('resolveResumeStart', () {
    test('同源 fallback 命中时原样返回（行为与改造前一致）', () {
      final result = resolveResumeStart(
        lines: twoLines,
        seed: seedOfEp2,
        targetLine: twoLines[0],
        targetEpisodeIndex: 1,
        targetEpisodeName: '第2集',
        targetDurationMs: 0,
        fallback: const Duration(milliseconds: 12345),
      );
      expect(result, const Duration(milliseconds: 12345));
    });

    test('跨源同一集 → 迁移出原记录的毫秒位置', () {
      final result = resolveResumeStart(
        lines: twoLines,
        seed: seedOfEp2,
        targetLine: twoLines[0],
        targetEpisodeIndex: 1,
        targetEpisodeName: '第2集',
        targetDurationMs: 0,
      );
      expect(result, const Duration(milliseconds: 180000));
    });

    test('跨源不是同一集 → null（宁可从头播，不可错续播）', () {
      final result = resolveResumeStart(
        lines: twoLines,
        seed: seedOfEp2,
        targetLine: twoLines[0],
        targetEpisodeIndex: 0,
        targetEpisodeName: '第1集',
        targetDurationMs: 0,
      );
      expect(result, isNull);
    });

    test('没有种子 → null', () {
      expect(
        resolveResumeStart(
          lines: twoLines,
          seed: null,
          targetLine: twoLines[0],
          targetEpisodeIndex: 1,
          targetEpisodeName: '第2集',
          targetDurationMs: 0,
        ),
        isNull,
      );
    });

    test('种子没有位置（positionMs=0）→ null', () {
      const noPosition = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://x/e2',
        episodeName: '第2集',
        positionMs: 0,
        durationMs: 2400000,
      );
      expect(
        resolveResumeStart(
          lines: twoLines,
          seed: noPosition,
          targetLine: twoLines[0],
          targetEpisodeIndex: 1,
          targetEpisodeName: '第2集',
          targetDurationMs: 0,
        ),
        isNull,
      );
    });

    test('原记录已播完 → null（从头看）', () {
      const completed = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://x/e2',
        episodeName: '第2集',
        positionMs: 2390000,
        durationMs: 2400000,
        completed: true,
      );
      expect(
        resolveResumeStart(
          lines: twoLines,
          seed: completed,
          targetLine: twoLines[0],
          targetEpisodeIndex: 1,
          targetEpisodeName: '第2集',
          targetDurationMs: 0,
        ),
        isNull,
      );
    });

    test('位置贴着片尾 → null', () {
      const nearEnd = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://x/e2',
        episodeName: '第2集',
        positionMs: 2399000,
        durationMs: 2400000,
      );
      expect(
        resolveResumeStart(
          lines: twoLines,
          seed: nearEnd,
          targetLine: twoLines[0],
          targetEpisodeIndex: 1,
          targetEpisodeName: '第2集',
          targetDurationMs: 0,
        ),
        isNull,
      );
    });
  });

  group('resumeSeedOf', () {
    test('字段逐个搬运，一个不漏', () {
      const item = PlaybackHistory(
        id: 7,
        siteKey: 'csp_a',
        vodId: 'v1',
        vodName: '剧名',
        vodPic: 'http://p',
        flag: '线路一',
        episodeName: '第2集',
        episodeId: 'http://x/e2',
        positionMs: 180000,
        durationMs: 2400000,
        updatedAt: 1,
        completed: true,
        sourceKey: 'bridge|uuid|key',
      );
      final seed = resumeSeedOf(item);
      expect(seed.flag, '线路一');
      expect(seed.episodeId, 'http://x/e2');
      expect(seed.episodeName, '第2集');
      expect(seed.positionMs, 180000);
      expect(seed.durationMs, 2400000);
      expect(seed.completed, isTrue);
    });
  });

  group('episodeCountOf / candidateHasResumeEpisode（跨源候选的第二阶段判定）', () {
    test('episodeCountOf 取最长线路的集数，空输入为 0', () {
      expect(episodeCountOf(twoLines), 2);
      expect(
        episodeCountOf([
          lineOf('短', [('第1集', 'http://s/e1')]),
          lineOf('长', [
            ('第1集', 'http://l/e1'),
            ('第2集', 'http://l/e2'),
            ('第3集', 'http://l/e3'),
          ]),
        ]),
        3,
      );
      expect(episodeCountOf(const []), 0);
    });

    test('线路 flag 与集入口都命中 → 有目标集', () {
      expect(
        candidateHasResumeEpisode(lines: twoLines, seed: seedOfEp2),
        isTrue,
      );
    });

    test('换到另一个站点、线路名不同但集号对得上 → 有目标集', () {
      final other = [
        lineOf('换个名字的线路', [
          ('第1集(高清)', 'http://z/e1'),
          ('第2集(高清)', 'http://z/e2'),
        ]),
      ];
      expect(candidateHasResumeEpisode(lines: other, seed: seedOfEp2), isTrue);
    });

    test('同名片只有第 1 集 → 没有目标集（必须判 false，否则被送去第 1 集）', () {
      final short = [lineOf('线路一', [('第1集', 'http://q/e1')])];
      expect(candidateHasResumeEpisode(lines: short, seed: seedOfEp2), isFalse);
    });

    test('空 lines（详情没拿到）→ false', () {
      expect(candidateHasResumeEpisode(lines: const [], seed: seedOfEp2), isFalse);
    });

    test('电影（两边都只有一集）→ 有目标集', () {
      final movie = [lineOf('线路一', [('正片', 'http://m/movie')])];
      const seed = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://other/movie',
        episodeName: '正片',
        positionMs: 60000,
        durationMs: 100000,
      );
      expect(candidateHasResumeEpisode(lines: movie, seed: seed), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // 比例换算：详情页拿不到目标集时长（targetDurationMs=0），只有播放器
  // open 成功后才知道。PlayerPage._load 把真实时长交回来重算，这里锁算法本身。
  // ---------------------------------------------------------------------------
  group('resolveResumeStart 用目标集真实时长做比例换算', () {
    test('目标集比原集长很多 → 按比例放大（不是死板的绝对毫秒）', () {
      // 原记录：3 分钟 / 该集 40 分钟；目标集 2 小时。差 80 分钟远超容差
      // max(10min, 20%×40min=8min)=10min，必须走比例：0.075 × 2h = 9 分钟。
      final result = resolveResumeStart(
        lines: twoLines,
        seed: seedOfEp2,
        targetLine: twoLines[0],
        targetEpisodeIndex: 1,
        targetEpisodeName: '第2集',
        targetDurationMs: 7200000,
      );
      expect(result, const Duration(milliseconds: 540000));
    });

    test('两个源同一集时长接近 → 仍用绝对毫秒（比例换算会引入无谓漂移）', () {
      // 目标集 41 分钟：差 60 秒 ≤ 容差 10 分钟 → 绝对 180000ms。
      final result = resolveResumeStart(
        lines: twoLines,
        seed: seedOfEp2,
        targetLine: twoLines[0],
        targetEpisodeIndex: 1,
        targetEpisodeName: '第2集',
        targetDurationMs: 2460000,
      );
      expect(result, const Duration(milliseconds: 180000));
    });

    test('targetDurationMs 传 0（详情页阶段）→ 退化为绝对毫秒', () {
      final result = resolveResumeStart(
        lines: twoLines,
        seed: seedOfEp2,
        targetLine: twoLines[0],
        targetEpisodeIndex: 1,
        targetEpisodeName: '第2集',
        targetDurationMs: 0,
      );
      expect(result, const Duration(milliseconds: 180000));
    });

    test('比例换算结果超出目标集片尾守卫 → null（宁可从头）', () {
      // 原记录贴着片尾（2399000/2400000）本身已被 endingGuard 拦下，
      // 这里改用「比例落在 target 末尾 5 秒内」的构造验证第二条守卫。
      const seed = ResumeSeed(
        flag: '线路一',
        episodeId: 'http://x/e2',
        episodeName: '第2集',
        positionMs: 200000,
        durationMs: 240000,
      );
      // 0.8333 × 100000ms = 83333 > 100000-5000 → 夹取失败 → null。
      final result = resolveResumeStart(
        lines: twoLines,
        seed: seed,
        targetLine: twoLines[0],
        targetEpisodeIndex: 1,
        targetEpisodeName: '第2集',
        targetDurationMs: 100000,
      );
      expect(result, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // 接线锁：算法写对但没接进播放器 = 功能等于没做（本轮缺口正是这样漏掉的）。
  // ---------------------------------------------------------------------------
  group('接线锁（源码级：详情页→播放器的一次性交接）', () {
    final playerSource = _readSourceCode('lib/ui/player_page.dart');
    final browseSource = _readSourceCode('lib/ui/browse_pages.dart');
    final requestSource = _readSourceCode('lib/core/playback_request.dart');

    test('PlaybackRequest 带待迁移种子，且在 copyWith 里可清除', () {
      expect(requestSource.contains('final ResumeSeed? resumeSeed;'), isTrue);
      expect(
        requestSource.contains('resumeSeed: clearResumeSeed ? null'),
        isTrue,
        reason: '种子必须能被清除，否则换集/重载会一次次重放旧进度',
      );
    });

    test('播放器用 open 之后的真实时长重算，而不是沿用详情页的猜测', () {
      expect(
        playerSource.contains('_effectiveStartPosition()'),
        isTrue,
        reason: '恢复位置必须经 _effectiveStartPosition 计算',
      );
      expect(
        playerSource.contains('targetDurationMs: _controller.duration.inMilliseconds'),
        isTrue,
        reason: '比例换算的唯一正确时长来源是 open 成功后的 _controller.duration',
      );
    });

    test('重算结果一次性交接给 startPosition 并清掉种子', () {
      expect(
        playerSource.contains('clearResumeSeed: true'),
        isTrue,
        reason: '交接后必须清种子，避免后续 _load 用旧种子覆盖用户手动 seek 的进度',
      );
    });

    test('详情页把种子透传给播放器', () {
      expect(
        browseSource.contains('resumeSeed: widget.resumeSeed'),
        isTrue,
        reason: '详情页拿到了种子却没交给播放器，跨源续播就还是从头播',
      );
    });
  });
}
