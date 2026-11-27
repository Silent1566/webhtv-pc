/// 拦截提示的文案与「每个播放会话只提示一次」的投影逻辑。
///
/// 文案口径对齐安卓 `utils/HlsAdblockNotice.java`（已跳过 N 个广告片段 + 总广告时长），
/// 呈现走仓库既有的 toast 通道（`ui/app.dart` 的 notice 投影），不新造浮层。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ad_block_stats.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  group('提示文案（对齐安卓 HlsAdblockNotice）', () {
    test('只有段数、没有可显示时长时不写时长', () {
      expect(
        adBlockNoticeMessage(segments: 3, durationSec: 0),
        '已跳过 3 个广告片段',
      );
      expect(
        adBlockNoticeMessage(segments: 3, durationSec: double.nan),
        '已跳过 3 个广告片段',
      );
    });

    test('不足 60 秒按 0.1 秒精度显示', () {
      expect(
        adBlockNoticeMessage(segments: 1, durationSec: 5),
        '已跳过 1 个广告片段，总广告时长 5.0 秒',
      );
      expect(
        adBlockNoticeMessage(segments: 2, durationSec: 12.34),
        '已跳过 2 个广告片段，总广告时长 12.3 秒',
      );
    });

    test('满 60 秒改用分钟', () {
      expect(
        adBlockNoticeMessage(segments: 2, durationSec: 120),
        '已跳过 2 个广告片段，总广告时长 2 分钟',
      );
      expect(
        adBlockNoticeMessage(segments: 3, durationSec: 90),
        '已跳过 3 个广告片段，总广告时长 1 分 30 秒',
      );
    });

    test('没有段数就不提示', () {
      expect(adBlockNoticeMessage(segments: 0, durationSec: 30), isNull);
    });
  });

  group('每个播放会话只提示一次', () {
    late Directory temp;
    late AppState state;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('webhtv-ad-notice');
      state = AppState(
        paths: AppPaths.resolve(
          overrides: {
            'config': p.join(temp.path, 'config'),
            'data': p.join(temp.path, 'data'),
            'cache': p.join(temp.path, 'cache'),
            'state': p.join(temp.path, 'logs'),
          },
        ),
        log: LogService(),
      );
    });

    tearDown(() {
      state.dispose();
      temp.deleteSync(recursive: true);
    });

    test('同一会话的第二次拦截不再重复提示', () {
      expect(state.adBlockNotice, isNull);
      state.debugReportAdBlockClean(
        sessionKey: 'token-a',
        removedSegments: 2,
        removedDurationSec: 30,
      );
      final first = state.adBlockNotice!;
      expect(first.message, '已跳过 2 个广告片段，总广告时长 30.0 秒');

      state.debugReportAdBlockClean(
        sessionKey: 'token-a',
        removedSegments: 5,
        removedDurationSec: 60,
      );
      expect(
        state.adBlockNotice!.seq,
        first.seq,
        reason: '同一会话的重取/拖动不该再弹一次',
      );
    });

    test('换到新会话后重新提示，且 seq 递增（同文案也能再弹）', () {
      state.debugReportAdBlockClean(
        sessionKey: 'token-a',
        removedSegments: 2,
        removedDurationSec: 30,
      );
      final first = state.adBlockNotice!;
      state.debugReportAdBlockClean(
        sessionKey: 'token-b',
        removedSegments: 2,
        removedDurationSec: 30,
      );
      final second = state.adBlockNotice!;
      expect(second.message, first.message);
      expect(second.seq, greaterThan(first.seq));
    });

    test('安全回退（没删）不提示', () {
      state.debugReportAdBlockClean(
        sessionKey: 'token-a',
        removedSegments: 0,
        removedDurationSec: 0,
        abandoned: true,
      );
      expect(state.adBlockNotice, isNull);
    });
  });
}
