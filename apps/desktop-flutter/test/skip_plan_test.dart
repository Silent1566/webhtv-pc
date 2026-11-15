/// 片头/片尾核心契约测试（`lib/core/skip_plan.dart`）。
///
/// 锁死三件事：
/// 1. 尾部段按「距文件结尾的距离」折算，而不是照抄数据源时间戳；
/// 2. 同一段被两家重复标注时只留一个；
/// 3. 每段每集只自动处理一次，且手动标记优先于远端。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/skip_plan.dart';
import 'package:webhtv_pc/core/skip_segments.dart';

void main() {
  const hour = 60 * 60 * 1000;

  group('开头段折算', () {
    test('start=null 视为 0（TheIntroDB 的 intro 常只给 end_ms）', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.intro,
            provider: 'theintrodb',
            startMs: null,
            endMs: 90000,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.startMs, 0);
      expect(plan.segments.single.endMs, 90000);
    });

    test('end 超出本集时长时被钳到时长', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.recap,
            provider: 'introdb',
            startMs: 0,
            endMs: hour + 5000,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.segments.single.endMs, hour);
    });

    test('end <= start 的非法区间被丢弃', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.intro,
            provider: 'introdb',
            startMs: 50000,
            endMs: 50000,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.isEmpty, isTrue);
    });

    test('起点已超过本集时长的段被丢弃', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.intro,
            provider: 'introdb',
            startMs: hour + 1,
            endMs: hour + 30000,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  group('尾部段时间轴折算', () {
    test('片源比参考版本长 60s 时，片尾整体后移 60s', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'theintrodb',
            startMs: 3300000,
            endMs: 3360000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour + 60000,
      );
      expect(plan.segments.single.startMs, 3300000 + 60000);
      expect(plan.segments.single.endMs, 3360000 + 60000);
      expect(plan.segments.single.openEnded, isFalse);
    });

    test('时长差在容差内不折算（几百毫秒抖动不该挪片尾）', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'theintrodb',
            startMs: 3300000,
            endMs: 3360000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour + 900,
      );
      expect(plan.segments.single.startMs, 3300000);
    });

    test('参考时长与本集差超过 5 分钟时放弃折算，保留原始时间戳', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'theintrodb',
            startMs: 3300000,
            endMs: 3360000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour + 6 * 60 * 1000,
      );
      expect(plan.segments.single.startMs, 3300000);
    });

    test('end 落在参考结尾 5s 内 => 无界段，目标就是文件结尾', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'theintrodb',
            startMs: 3500000,
            endMs: 3599000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour,
      );
      final outro = plan.segments.single;
      expect(outro.openEnded, isTrue);
      expect(outro.endMs, hour);
      final decision = plan.decide(
        positionMs: 3500000,
        durationMs: hour,
        kinds: SkipKindBits.all,
        mode: SkipMode.auto,
      );
      expect(decision.shouldSeek, isTrue);
      expect(decision.targetMs, hour);
      expect(decision.openEnd, isTrue);
    });

    test('end=null 且无参考时长时按有界处理（无界会误切集）', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'introdb',
            startMs: 3300000,
            endMs: null,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.segments.single.openEnded, isFalse);
    });

    test('end 超过参考结尾 5s 以上视为错配，整段丢弃', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'theintrodb',
            startMs: 3300000,
            endMs: 3700000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.isEmpty, isTrue);
    });

    test('尾部段起点为 0 必是错配（整集当片尾），丢弃', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'theintrodb',
            startMs: 0,
            endMs: 30000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  group('去重与优先级', () {
    test('两家标同一段（起点差 1s）只留一个，取有界段', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'theintrodb',
            startMs: 3300000,
            endMs: null,
            referenceDurationMs: hour,
          ),
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'introdb',
            startMs: 3301000,
            endMs: 3360000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.provider, 'introdb');
      expect(plan.segments.single.openEnded, isFalse);
    });

    test('跨类型的同段标注合并（回顾 vs 片头），不连跳两次', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.recap,
            provider: 'introdb',
            startMs: 0,
            endMs: 60000,
            confidence: 0.9,
          ),
          RawSkipSegment(
            kind: SkipKind.intro,
            provider: 'todb',
            startMs: 0,
            endMs: 60000,
            confidence: 0.5,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.segments, hasLength(1));
      expect(plan.segments.single.provider, 'introdb');
    });

    test('开头段与尾部段绝不合并（物理上相隔整集）', () {
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.intro,
            provider: 'introdb',
            startMs: 0,
            endMs: 90000,
          ),
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'introdb',
            startMs: 90000,
            endMs: 120000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.segments, hasLength(2));
      expect(plan.openings, hasLength(1));
      expect(plan.endings, hasLength(1));
    });
  });

  group('播放决策', () {
    SkipPlan plan() => SkipPlan.resolve(
      const [
        RawSkipSegment(
          kind: SkipKind.intro,
          provider: 'introdb',
          startMs: 0,
          endMs: 90000,
        ),
        RawSkipSegment(
          kind: SkipKind.outro,
          provider: 'theintrodb',
          startMs: 3400000,
          endMs: null,
          referenceDurationMs: hour,
        ),
      ],
      durationMs: hour,
    );

    test('off 模式一律不跳', () {
      expect(
        plan()
            .decide(
              positionMs: 0,
              durationMs: hour,
              kinds: SkipKindBits.all,
              mode: SkipMode.off,
            )
            .shouldSeek,
        isFalse,
      );
    });

    test('类型未勾选时不跳', () {
      expect(
        plan()
            .decide(
              positionMs: 0,
              durationMs: hour,
              kinds: SkipKindBits.outro,
              mode: SkipMode.auto,
            )
            .shouldSeek,
        isFalse,
      );
    });

    test('片头内触发，目标为段末；已越过不触发', () {
      final p = plan();
      final inside = p.decide(
        positionMs: 10000,
        durationMs: hour,
        kinds: SkipKindBits.all,
        mode: SkipMode.auto,
      );
      expect(inside.segment?.kind, SkipKind.intro);
      expect(inside.targetMs, 90000);
      expect(
        p
            .decide(
              positionMs: 90000,
              durationMs: hour,
              kinds: SkipKindBits.all,
              mode: SkipMode.auto,
            )
            .shouldSeek,
        isFalse,
      );
    });

    test('续播位置已在片头之后 => 不把用户拉回开头', () {
      expect(
        plan()
            .decide(
              positionMs: 5000,
              durationMs: hour,
              kinds: SkipKindBits.all,
              mode: SkipMode.auto,
              resumeMs: 600000,
            )
            .shouldSeek,
        isFalse,
      );
    });

    test('已处理过的段不再触发（用户拖回片头不会被再跳走）', () {
      expect(
        plan()
            .decide(
              positionMs: 10000,
              durationMs: hour,
              kinds: SkipKindBits.all,
              mode: SkipMode.auto,
              handled: const <String>{'intro|introdb|0|90000'},
            )
            .shouldSeek,
        isFalse,
      );
    });

    test('confirm 模式标记 needsConfirm', () {
      final decision = plan().decide(
        positionMs: 10000,
        durationMs: hour,
        kinds: SkipKindBits.all,
        mode: SkipMode.confirm,
      );
      expect(decision.needsConfirm, isTrue);
    });

    test('时长未知 / 已到结尾时不跳', () {
      final p = plan();
      expect(
        p
            .decide(
              positionMs: 1000,
              durationMs: 0,
              kinds: SkipKindBits.all,
              mode: SkipMode.auto,
            )
            .shouldSeek,
        isFalse,
      );
      expect(
        p
            .decide(
              positionMs: hour,
              durationMs: hour,
              kinds: SkipKindBits.all,
              mode: SkipMode.auto,
            )
            .shouldSeek,
        isFalse,
      );
    });

    test('落点离当前位置不足 1.5s 就不值得 seek', () {
      expect(
        plan()
            .decide(
              positionMs: 89000,
              durationMs: hour,
              kinds: SkipKindBits.all,
              mode: SkipMode.auto,
            )
            .shouldSeek,
        isFalse,
      );
    });
  });

  group('手动标记优先', () {
    test('手动片头覆盖远端片头，但远端的回顾段保留', () {
      final remote = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.recap,
            provider: 'introdb',
            startMs: 0,
            endMs: 30000,
          ),
          RawSkipSegment(
            kind: SkipKind.intro,
            provider: 'introdb',
            startMs: 30000,
            endMs: 120000,
          ),
        ],
        durationMs: hour,
      );
      final merged = remote.withManualOverride(
        manual: const SkipSegments(introEndMs: 95000),
        durationMs: hour,
      );
      expect(merged.openings, hasLength(2));
      final intro = merged.segments.firstWhere((s) => s.kind == SkipKind.intro);
      expect(intro.provider, SkipSegment.manualProvider);
      expect(intro.endMs, 95000);
      expect(merged.openings.any((s) => s.kind == SkipKind.recap), isTrue);
    });

    test('手动片尾是 openEnded，目标为文件结尾', () {
      final merged = SkipPlan.empty.withManualOverride(
        manual: const SkipSegments(outroStartMs: 3300000),
        durationMs: hour,
      );
      final decision = merged.decide(
        positionMs: 3300000,
        durationMs: hour,
        kinds: SkipKindBits.all,
        mode: SkipMode.auto,
      );
      expect(decision.segment?.provider, SkipSegment.manualProvider);
      expect(decision.targetMs, hour);
      expect(decision.openEnd, isTrue);
    });

    test('无手动标记时原样返回（不复制、不改动）', () {
      final remote = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.intro,
            provider: 'introdb',
            startMs: 0,
            endMs: 90000,
          ),
        ],
        durationMs: hour,
      );
      final merged = remote.withManualOverride(
        manual: const SkipSegments.none(),
        durationMs: hour,
      );
      expect(identical(merged, remote), isTrue);
    });
  });

  group('marker_type 映射', () {
    test('认识的别名映射到四类', () {
      expect(SkipKind.fromWire('intro'), SkipKind.intro);
      expect(SkipKind.fromWire('credits'), SkipKind.outro);
      expect(SkipKind.fromWire('Recap'), SkipKind.recap);
      expect(SkipKind.fromWire('next_episode'), SkipKind.preview);
    });

    test('chapter 不是可跳过段，返回 null（否则会把正片当片尾跳掉）', () {
      expect(SkipKind.fromWire('chapter'), isNull);
      expect(SkipKind.fromWire(null), isNull);
      expect(SkipKind.fromWire(''), isNull);
    });
  });

  group('彩蛋（片尾之后）与预告是两类', () {
    test('post_credits 映射到彩蛋，不并进预告', () {
      expect(SkipKind.fromWire('post_credits'), SkipKind.postCredits);
      expect(SkipKind.fromWire('postcredits'), SkipKind.postCredits);
      expect(SkipKind.fromWire('preview'), SkipKind.preview);
      expect(SkipKind.postCredits.isEnding, isTrue);
      expect(SkipKind.postCredits.label, '彩蛋');
    });

    test('出厂默认不含彩蛋与预告（它们排在最末尾，误跳等于切走一集）', () {
      expect(SkipKindBits.defaults & SkipKindBits.postCredits, 0);
      expect(SkipKindBits.defaults & SkipKindBits.preview, 0);
      expect(
        SkipKindBits.all & SkipKindBits.postCredits,
        SkipKindBits.postCredits,
      );
    });

    test('彩蛋按尾部段折算：片源长 60s 时整体后移 60s', () {
      const hour = 60 * 60 * 1000;
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.postCredits,
            provider: 'introdb',
            startMs: 3500000,
            endMs: 3550000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour + 60000,
      );
      expect(plan.segments.single.startMs, 3500000 + 60000);
      expect(plan.segments.single.endMs, 3550000 + 60000);
    });

    test('关掉彩蛋位就不跳，打开才跳（与预告互不影响）', () {
      const hour = 60 * 60 * 1000;
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'introdb',
            startMs: 3300000,
            endMs: 3480000,
            referenceDurationMs: hour,
          ),
          RawSkipSegment(
            kind: SkipKind.postCredits,
            provider: 'introdb',
            startMs: 3500000,
            endMs: 3550000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour,
      );
      const at = 3500000;
      final onlyOutro = plan.decide(
        positionMs: at,
        durationMs: hour,
        kinds: SkipKindBits.outro,
        mode: SkipMode.auto,
      );
      expect(onlyOutro.shouldSeek, isFalse);
      final withCredits = plan.decide(
        positionMs: at,
        durationMs: hour,
        kinds: SkipKindBits.outro | SkipKindBits.postCredits,
        mode: SkipMode.auto,
      );
      expect(withCredits.segment?.kind, SkipKind.postCredits);
      expect(withCredits.targetMs, 3550000);
    });

    test('片尾与彩蛋不互相吞并（起点相差 20s，超出合并容差）', () {
      const hour = 60 * 60 * 1000;
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.outro,
            provider: 'introdb',
            startMs: 3300000,
            endMs: 3480000,
            referenceDurationMs: hour,
          ),
          RawSkipSegment(
            kind: SkipKind.postCredits,
            provider: 'introdb',
            startMs: 3500000,
            endMs: 3550000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.endings, hasLength(2));
    });
  });

  group('广告与中场休息（TODB 的 advertisement / intermission）', () {
    test('marker_type 全枚举都能映射，chapter 仍然不认', () {
      // 枚举来自 TODB 官方文档「响应字段取值」一节。
      expect(SkipKind.fromWire('intro'), SkipKind.intro);
      expect(SkipKind.fromWire('credits'), SkipKind.outro);
      expect(SkipKind.fromWire('recap'), SkipKind.recap);
      expect(SkipKind.fromWire('advertisement'), SkipKind.advertisement);
      expect(SkipKind.fromWire('post_credits'), SkipKind.postCredits);
      expect(SkipKind.fromWire('intermission'), SkipKind.intermission);
      expect(SkipKind.fromWire('preview'), SkipKind.preview);
      // 章节是导航书签，不是可跳过段。
      expect(SkipKind.fromWire('chapter'), isNull);
    });

    test('出厂默认不含广告与休息，但全开位含', () {
      expect(SkipKindBits.defaults & SkipKindBits.advertisement, 0);
      expect(SkipKindBits.defaults & SkipKindBits.intermission, 0);
      expect(
        SkipKindBits.all & SkipKindBits.advertisement,
        SkipKindBits.advertisement,
      );
      expect(
        SkipKindBits.all & SkipKindBits.intermission,
        SkipKindBits.intermission,
      );
    });

    test('广告走绝对时间轴：参考时长不同也不平移（它不在尾部）', () {
      const hour = 60 * 60 * 1000;
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.advertisement,
            provider: 'todb',
            startMs: 1800000,
            endMs: 1830000,
            referenceDurationMs: hour,
          ),
        ],
        // 片源比参考版本长 60s：尾部段会被平移，广告不该被平移。
        durationMs: hour + 60000,
      );
      expect(plan.segments.single.startMs, 1800000);
      expect(plan.segments.single.endMs, 1830000);
    });

    test('中场休息同样走绝对时间轴', () {
      const hour = 60 * 60 * 1000;
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.intermission,
            provider: 'todb',
            startMs: 2400000,
            endMs: 2430000,
            referenceDurationMs: hour,
          ),
        ],
        durationMs: hour + 60000,
      );
      expect(plan.segments.single.startMs, 2400000);
    });

    test('广告与片头不互相吞并（同起点也不同分组）', () {
      const hour = 60 * 60 * 1000;
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.advertisement,
            provider: 'todb',
            startMs: 0,
            endMs: 30000,
          ),
          RawSkipSegment(
            kind: SkipKind.intro,
            provider: 'introdb',
            startMs: 0,
            endMs: 90000,
          ),
        ],
        durationMs: hour,
      );
      expect(plan.segments, hasLength(2));
    });

    test('片中广告：位置落进段内才跳，目标为段末', () {
      const hour = 60 * 60 * 1000;
      final plan = SkipPlan.resolve(
        const [
          RawSkipSegment(
            kind: SkipKind.advertisement,
            provider: 'todb',
            startMs: 1800000,
            endMs: 1830000,
          ),
        ],
        durationMs: hour,
      );
      expect(
        plan
            .decide(
              positionMs: 1799000,
              durationMs: hour,
              kinds: SkipKindBits.advertisement,
              mode: SkipMode.auto,
            )
            .shouldSeek,
        isFalse,
      );
      final inside = plan.decide(
        positionMs: 1800000,
        durationMs: hour,
        kinds: SkipKindBits.advertisement,
        mode: SkipMode.auto,
      );
      expect(inside.segment?.kind, SkipKind.advertisement);
      expect(inside.targetMs, 1830000);
      // 不是尾部段，所以不会被当成「本集看完」。
      expect(inside.openEnd, isFalse);
    });
  });
}
