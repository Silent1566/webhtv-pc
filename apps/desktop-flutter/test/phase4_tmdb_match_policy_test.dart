/// Phase 4 · TMDB 分季变体防护与推送守卫（`docs/phase4/design/01` §5.4）。
///
/// 对应门禁：`docs/phase4/design/05` §3.2。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_title.dart';

void main() {
  group('分季变体四档得分（§5.4）', () {
    test('详情不含「分季」+ 源不允许分季 → +140（NON_SPLIT_BONUS）', () {
      expect(splitSeasonDetailScore('剧名', '剧名'), 140);
      expect(splitSeasonDetailScore('', '剧名'), 140);
      expect(splitSeasonDetailScore('剧名', ''), 140);
    });

    test('详情不含「分季」+ 源允许分季（显式季度）→ 0', () {
      expect(splitSeasonDetailScore('剧名 第1季', '剧名'), 0);
      expect(splitSeasonDetailScore('剧名 S01E02', '剧名'), 0);
      expect(splitSeasonDetailScore('剧名 Season 2', '剧名'), 0);
    });

    test('详情含「分季」+ 源显式提到分季 → +160（EXPLICIT_SPLIT_BONUS）', () {
      expect(splitSeasonDetailScore('剧名 分季', '剧名 分季版'), 160);
      expect(splitSeasonDetailScore('剧名分季', '某剧 分季版'), 160);
    });

    test('详情含「分季」+ 源未提分季（但有显式季度）→ 0', () {
      expect(splitSeasonDetailScore('剧名 第1季', '剧名 分季版'), 0);
    });

    test('详情含「分季」+ 源不允许分季 → -240（SPLIT_SEASON_PENALTY）', () {
      expect(splitSeasonDetailScore('剧名', '剧名 分季版'), -240);
      expect(splitSeasonDetailScore('', '某剧 分季版'), -240);
    });
  });

  group('isSplitSeasonDetail / mentionsSplitSeason（§5.4）', () {
    test('归一后判定，标点与空格不影响', () {
      expect(isSplitSeasonDetail('剧名 分季'), isTrue);
      expect(isSplitSeasonDetail('剧名·分-季'), isTrue);
      expect(isSplitSeasonDetail('剧名'), isFalse);
      expect(isSplitSeasonDetail(null), isFalse);
      expect(mentionsSplitSeason('剧名分季版'), isTrue);
      expect(mentionsSplitSeason('剧名'), isFalse);
    });

    test('detailTitle 由四个字段拼接后判定', () {
      // 上游 `detailTitle` = name + original_name + title + original_title
      const detailTitle = '剧名 Fixture Show 剧名 Fixture Show';
      expect(isSplitSeasonDetail(detailTitle), isFalse);
      expect(isSplitSeasonDetail('$detailTitle 分季'), isTrue);
    });
  });

  group('mentionsExplicitSeason / allowsSplitSeasonVariant（§5.4）', () {
    test('三种显式季度形态', () {
      expect(mentionsExplicitSeason('第1季'), isTrue);
      expect(mentionsExplicitSeason('第 12 季'), isTrue);
      expect(mentionsExplicitSeason('第2部'), isTrue);
      expect(mentionsExplicitSeason('season 3'), isTrue);
      expect(mentionsExplicitSeason('SEASON 03'), isTrue);
      expect(mentionsExplicitSeason('s01e02'), isTrue);
      expect(mentionsExplicitSeason('S1'), isTrue);
      expect(mentionsExplicitSeason('剧名'), isFalse);
    });

    test('allowsSplitSeasonVariant = 提分季 或 显式季度', () {
      expect(allowsSplitSeasonVariant('剧名 分季'), isTrue);
      expect(allowsSplitSeasonVariant('剧名 第1季'), isTrue);
      expect(allowsSplitSeasonVariant('剧名'), isFalse);
    });
  });

  group('isUnwantedSplitSeasonVariant：直接丢弃而不是降分（§5.4）', () {
    test('含分季 + 源不允许 → true（该候选被丢弃）', () {
      expect(isUnwantedSplitSeasonVariant('剧名', '剧名 分季版'), isTrue);
      expect(isUnwantedSplitSeasonVariant('', '分季版'), isTrue);
    });

    test('源显式提到分季 → false（允许）', () {
      expect(isUnwantedSplitSeasonVariant('剧名 分季', '剧名 分季版'), isFalse);
    });

    test('源有显式季度 → false（允许）', () {
      expect(isUnwantedSplitSeasonVariant('剧名 第1季', '剧名 分季版'), isFalse);
    });

    test('详情不含分季 → false（与分季无关）', () {
      expect(isUnwantedSplitSeasonVariant('剧名', '剧名'), isFalse);
    });
  });

  group('推送标题守卫（§5.4）', () {
    test('URL 形态一律拒绝', () {
      for (final url in [
        'https://example.com/video',
        'http://example.com/video',
        'rtsp://example.com/live',
        'rtmp://example.com/live',
        'mms://example.com/live',
        'magnet:?xt=urn:btih:abc',
        'ed2k://|file|a.avi|1|hash|/',
        'thunder://QUFodHRwOi8v',
        'video://abc',
        'file:///tmp/a.mp4',
      ]) {
        expect(shouldAutoMatchPushTitle(url), isFalse, reason: url);
      }
    });

    test('通用标题一律拒绝', () {
      for (final title in [
        'Online Video',
        'online video 1',
        'Network Video',
        'Web Video',
        'Video',
        'video 12',
        'Push',
        'Cast',
        '在线视频',
        '网络视频',
        '网页视频',
        '推送',
        '投屏',
        '视频',
        '视频 12',
      ]) {
        expect(shouldAutoMatchPushTitle(title), isFalse, reason: title);
      }
    });

    test('无中英文字符 → 拒绝', () {
      expect(shouldAutoMatchPushTitle('1234'), isFalse);
      expect(shouldAutoMatchPushTitle('···'), isFalse);
    });

    test('归一后长度 < 2 或纯数字 → 拒绝', () {
      expect(shouldAutoMatchPushTitle('a'), isFalse);
      expect(shouldAutoMatchPushTitle('007'), isFalse);
      expect(shouldAutoMatchPushTitle('1234'), isFalse);
    });

    test('正常标题 → 允许', () {
      expect(shouldAutoMatchPushTitle('庆余年'), isTrue);
      expect(shouldAutoMatchPushTitle('Fixture Show'), isTrue);
      expect(shouldAutoMatchPushTitle('剧名 第二季'), isTrue);
      expect(shouldAutoMatchPushTitle('ab'), isTrue);
    });

    test('空输入 → 拒绝', () {
      expect(shouldAutoMatchPushTitle(null), isFalse);
      expect(shouldAutoMatchPushTitle(''), isFalse);
      expect(shouldAutoMatchPushTitle('   '), isFalse);
    });
  });

  group('归一化规则（§5.4）', () {
    test('剥离全部分隔与标点后小写', () {
      const raw = 'A b·c•d:e：f-g_h/i\\j|k(l)m（n）[o]p【q】';
      expect(normalizeTitle(raw), 'abcdefghijklmnopq');
    });
  });
}
