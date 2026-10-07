/// Phase 4 · TMDB 标题清洗、年份与季度信号（`docs/phase4/design/01` §3）。
///
/// 对应门禁：`docs/phase4/design/05` §3.1「标题清洗 13 步 / 年份提取 / 季度信号 /
/// 排序键顺序 / 相似度公式 / 语言偏好」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_title.dart';

void main() {
  group('TMDB 标题清洗（§3.3）', () {
    test('步骤 1：去掉文件扩展名', () {
      expect(cleanTitle('剧名.mkv'), '剧名');
      expect(cleanTitle('剧名.MP4'), '剧名');
      expect(cleanTitle('剧名.rmvb'), '剧名');
      expect(cleanTitle('剧名.m2ts'), '剧名');
    });

    test('步骤 2：去掉噪声括号段', () {
      expect(cleanTitle('剧名[1080P]'), '剧名');
      expect(cleanTitle('剧名【国语】'), '剧名');
      expect(cleanTitle('剧名「高码」'), '剧名');
      expect(cleanTitle('剧名（臻彩）'), '剧名');
      expect(cleanTitle('剧名 (2024)'), '剧名');
    });

    test('步骤 2 例外：《书名》内容被提取而不是丢弃', () {
      expect(cleanTitle('《庆余年》 第1季'), '庆余年');
      expect(cleanTitle('《庆余年》第2季'), '庆余年');
      expect(cleanTitle('[国产]《庆余年》'), '庆余年');
    });

    test('步骤 3：去掉季集标记', () {
      expect(cleanTitle('剧名 S01E02'), '剧名');
      expect(cleanTitle('剧名 Season 3'), '剧名');
      expect(cleanTitle('剧名 第1季'), '剧名');
      expect(cleanTitle('剧名 第12集'), '剧名');
      expect(cleanTitle('剧名 第一季'), '剧名');
      expect(cleanTitle('剧名 第十二話'), '剧名');
      expect(cleanTitle('剧名 EP05'), '剧名');
      expect(cleanTitle('剧名 Episode 12'), '剧名');
    });

    test('步骤 4：去掉清晰度/编码标记', () {
      expect(cleanTitle('剧名 1080P'), '剧名');
      expect(cleanTitle('剧名 4K HDR'), '剧名');
      expect(cleanTitle('剧名 BluRay x265'), '剧名');
      expect(cleanTitle('剧名 WEB-DL HEVC'), '剧名');
      expect(cleanTitle('剧名 Atmos'), '剧名');
      expect(cleanTitle('剧名 Netflix'), '剧名');
    });

    test('步骤 5：去掉帧率标记', () {
      expect(cleanTitle('剧名 60fps'), '剧名');
      expect(cleanTitle('剧名 24 帧'), '剧名');
      // 非帧率语义的数字不应被误删（`(?<!\\d)` 与结尾断言）。
      expect(cleanTitle('剧名 120'), '剧名 120');
    });

    test('步骤 6：去掉更新尾巴', () {
      expect(cleanTitle('剧名 更新至'), '剧名');
      expect(cleanTitle('剧名 连载至'), '剧名');
      expect(cleanTitle('剧名 更至'), '剧名');
    });

    test('步骤 7：去掉版本/语言尾巴', () {
      expect(cleanTitle('剧名 国语版'), '剧名');
      expect(cleanTitle('剧名 粤语版'), '剧名');
      expect(cleanTitle('剧名 台版'), '剧名');
      expect(cleanTitle('剧名 韩版'), '剧名');
      expect(cleanTitle('剧名 泰國版'), '剧名');
    });

    test('步骤 8：去掉质量词', () {
      expect(cleanTitle('剧名 无水印'), '剧名');
      expect(cleanTitle('剧名 全集'), '剧名');
      expect(cleanTitle('剧名 未删减'), '剧名');
      expect(cleanTitle('剧名 高码率'), '剧名');
      expect(cleanTitle('剧名 双语'), '剧名');
    });

    test('步骤 9：去掉 # 与 ＃', () {
      // 步骤 12 会把中日韩字符之间的空格压掉，所以 `#` 两侧的空白不会保留。
      expect(cleanTitle('剧名 #预告'), '剧名预告');
      expect(cleanTitle('剧名＃＃'), '剧名');
    });

    test('步骤 10：去掉独立出现的体裁词', () {
      expect(cleanTitle('剧名 电视剧'), '剧名');
      expect(cleanTitle('动漫 剧名'), '剧名');
      expect(cleanTitle('剧名 电影'), '剧名');
      // 作为词内一部分时不得误删。
      expect(cleanTitle('剧名电影版'), '剧名电影版');
    });

    test('步骤 11：分隔符归一与空白压缩', () {
      // `第二部` 已在步骤 3 被季集标记规则移除；这里只验证分隔符与空白。
      // 步骤 12 会把中日韩字符之间的空格压掉。
      expect(cleanTitle('剧名...二'), '剧名二');
      expect(cleanTitle('剧  名'), '剧名');
      expect(cleanTitle('剧名__-_'), '剧名');
      // 纯拉丁空白保留；但含 CJK 时步骤 12 会去掉结尾的单字母。
      expect(cleanTitle('ab cd'), 'ab cd');
      expect(cleanTitle('剧名 a b'), '剧名 a');
    });

    test('步骤 12：中英混排清理', () {
      expect(cleanTitle('a 剧名'), '剧名');
      expect(cleanTitle('剧名 a'), '剧名');
      expect(cleanTitle('剧 名'), '剧名');
    });

    test('步骤 13：去掉首尾标点', () {
      expect(cleanTitle(':剧名,'), '剧名');
      expect(cleanTitle('  /剧名|  '), '剧名');
      expect(cleanTitle('·剧名。'), '剧名');
    });

    test('兜底：清洗结果为空时返回原始输入，不得返回空串', () {
      expect(cleanTitle('1080P'), '1080P');
      expect(cleanTitle('国语版'), '国语版');
      expect(cleanTitle('[1080P]'), '[1080P]');
      expect(cleanTitle(''), '');
    });

    test('步骤顺序敏感：先剥扩展名再剥括号', () {
      // 若顺序颠倒，扩展名会被括号规则先吃掉而留下错误结果。
      expect(cleanTitle('剧名[1080P].mkv'), '剧名');
    });

    test('组合清洗：真实站源标题', () {
      expect(
        cleanTitle('【国产】庆余年 第二季 更新至 1080P 国语版.mkv'),
        '庆余年',
      );
      expect(
        cleanTitle('剧名.S01E02.2160P.WEB-DL.x265.HDR.国语版'),
        '剧名',
      );
    });
  });

  group('TMDB 归一化（§5.4）', () {
    test('去掉分隔与标点后小写', () {
      expect(normalizeTitle('剧 名·副标:题'), '剧名副标题');
      expect(normalizeTitle('A-B_C'), 'abc');
      expect(normalizeTitle('剧名（二）【三】'), '剧名二三');
    });
  });

  group('TMDB 年份提取（§3.4）', () {
    test('括号与独立年份', () {
      expect(firstYear('剧名 (2024)'), 2024);
      expect(firstYear('剧名 2024'), 2024);
      // `(?<!\d)` 只排除**紧邻的数字**，中文字符前的年份仍然匹配。
      expect(firstYear('剧名1999'), 1999);
      expect(firstYear('1899'), 0); // 超出范围
      expect(firstYear('2100'), 0); // 超出范围
    });

    test('完整日期形态识别（不把 20240115 的 2024 当成普通年份而丢失）', () {
      expect(firstYear('剧名 20240115'), 2024);
      expect(firstYear('剧名 2024-01-15'), 2024);
      expect(firstYear('剧名 2024.01.15'), 2024);
      expect(firstYear('20240115'), 2024);
      // 非法月日不得被当成日期。
      expect(firstYear('20241315'), 0);
    });

    test('sourceYear 优先级：vodYear → sourceTitle → keyword', () {
      expect(
        sourceYear(vodYear: '2020', sourceTitle: '剧名 2021', keyword: '剧名 2022'),
        2020,
      );
      expect(
        sourceYear(sourceTitle: '剧名 2021', keyword: '剧名 2022'),
        2021,
      );
      expect(sourceYear(keyword: '剧名 2022'), 2022);
      expect(sourceYear(), 0);
    });

    test('removeYearFromTitle 去掉年份并再走一次清洗', () {
      expect(removeYearFromTitle('剧名 2024', 2024), '剧名');
      expect(removeYearFromTitle('剧名 (2024)', 2024), '剧名');
      expect(removeYearFromTitle('剧名2024', 2024), '剧名');
    });

    test('splitYearQuery 生成与拒绝规则', () {
      expect(
        splitYearQuery(keyword: '剧名 2024'),
        const SplitYearQuery('剧名', 2024),
      );
      // 源里没有年份 → 无法拆分
      expect(splitYearQuery(keyword: '剧名'), isNull);
      // 拆分后与原文一致 → 拒绝
      expect(splitYearQuery(keyword: '剧名'), isNull);
      // expectedYear 覆盖
      expect(
        splitYearQuery(keyword: '剧名 2024', expectedYear: 2024),
        const SplitYearQuery('剧名', 2024),
      );
    });
  });

  group('TMDB 季度信号（§3.5）', () {
    test('中文数字归一', () {
      expect(parseChineseNumber('一'), 1);
      expect(parseChineseNumber('十'), 10);
      expect(parseChineseNumber('十二'), 12);
      expect(parseChineseNumber('二十'), 20);
      expect(parseChineseNumber('二十三'), 23);
      expect(parseChineseNumber('〇'), 0);
      expect(parseChineseNumber('零'), 0);
      expect(parseChineseNumber('两'), 2);
      expect(parseChineseNumber('12'), 12);
      expect(parseChineseNumber('abc'), isNull);
    });

    test('三种信号形态', () {
      expect(sourceSeasonNumber('剧名 第2季'), 2);
      expect(sourceSeasonNumber('剧名 第十二季'), 12);
      expect(sourceSeasonNumber('剧名 第2部'), 2);
      expect(sourceSeasonNumber('剧名 Season 3'), 3);
      expect(sourceSeasonNumber('剧名 season 03'), 3);
      expect(sourceSeasonNumber('剧名 S01E02'), 1);
      expect(sourceSeasonNumber('剧名 s3'), 3);
    });

    test('无信号返回 -1 而不是 0', () {
      expect(sourceSeasonNumber('剧名'), -1);
      expect(sourceSeasonNumber(''), -1);
      expect(sourceSeasonNumber(null), -1);
      // 「第0季」不是 > 0，视为无信号。
      expect(sourceSeasonNumber('剧名 第〇季'), -1);
    });

    test('多个信号取第一个 > 0', () {
      expect(sourceSeasonNumber('剧名 第0季 S03E01'), 3);
      expect(sourceSeasonNumber('剧名 S02 S05'), 2);
    });
  });

  group('TMDB 相似度与排序（§5.6）', () {
    test('完全相等 1000', () {
      expect(titleSimilarityScore('剧名', '剧名'), 1000);
      expect(titleSimilarityScore('剧 名', '剧名'), 1000);
    });

    test('包含关系 800 + round(200*min/max)', () {
      // '剧名' 长度 2 包含于 '剧名第二季' 长度 5 → 800 + round(80) = 880
      expect(titleSimilarityScore('剧名第二季', '剧名'), 880);
      // 反向包含同样成立
      expect(titleSimilarityScore('剧名', '剧名第二季'), 880);
    });

    test('编辑距离档 max(0, 700 - round(700*d/max))', () {
      // 用互不包含的等长串，避免落到「包含」分支：距离 2，max 4 → 350
      expect(titleSimilarityScore('剧名甲乙', '剧名丙丁'), 350);
      // 完全不同的等长串
      expect(titleSimilarityScore('abcd', 'wxyz'), 0);
    });

    test('空输入返回 0', () {
      expect(titleSimilarityScore('', '剧名'), 0);
      expect(titleSimilarityScore('剧名', ''), 0);
    });

    test('levenshteinDistance 基础', () {
      expect(levenshteinDistance('abc', 'abc'), 0);
      expect(levenshteinDistance('abc', 'abd'), 1);
      expect(levenshteinDistance('', 'abc'), 3);
      expect(levenshteinDistance('abc', ''), 3);
      expect(levenshteinDistance('kitten', 'sitting'), 3);
    });

    test('yearDistance 未知年份记 9999', () {
      expect(yearDistance(2024, 2024), 0);
      expect(yearDistance(2023, 2024), 1);
      expect(yearDistance(0, 2024), 9999);
    });

    test('语言/地区偏好：40 / 25 / 20', () {
      // 地区完全匹配
      expect(
        localePreferenceScore(
          originalLanguage: 'zh',
          originCountry: 'CN',
          preferredLanguage: 'zh',
          preferredCountry: 'CN',
        ),
        85, // 40 + 25 + 20
      );
      // 偏好语种区但地区不同
      expect(
        localePreferenceScore(
          originalLanguage: 'zh',
          originCountry: 'HK',
          preferredLanguage: 'zh',
          preferredCountry: 'CN',
        ),
        45, // 25 + 20
      );
      // 只有语言匹配
      expect(
        localePreferenceScore(
          originalLanguage: 'zh',
          originCountry: 'US',
          preferredLanguage: 'zh',
          preferredCountry: 'CN',
        ),
        20,
      );
      // 都不匹配
      expect(
        localePreferenceScore(
          originalLanguage: 'en',
          originCountry: 'US',
          preferredLanguage: 'zh',
          preferredCountry: 'CN',
        ),
        0,
      );
    });

    test('偏好语种区映射：zh→CN/HK/TW/MO/SG，ja→JP，ko→KR', () {
      for (final country in ['CN', 'HK', 'TW', 'MO', 'SG']) {
        expect(
          localePreferenceScore(
            originalLanguage: 'zh',
            originCountry: country,
            preferredLanguage: 'zh',
            preferredCountry: '',
          ),
          45, // 25（地区）+ 20（语言）
          reason: '$country 应属 zh 偏好区',
        );
      }
      expect(
        localePreferenceScore(
          originalLanguage: 'ja',
          originCountry: 'JP',
          preferredLanguage: 'ja',
          preferredCountry: '',
        ),
        45,
      );
      expect(
        localePreferenceScore(
          originalLanguage: 'ko',
          originCountry: 'KR',
          preferredLanguage: 'ko',
          preferredCountry: '',
        ),
        45,
      );
      // zh 偏好下 JP 不加地区分，也不加语言分
      expect(
        localePreferenceScore(
          originalLanguage: 'ja',
          originCountry: 'JP',
          preferredLanguage: 'zh',
          preferredCountry: '',
        ),
        0,
      );
    });

    test('preferredLanguageOf / preferredCountryOf 从 language 推导', () {
      expect(preferredLanguageOf('zh-CN'), 'zh');
      expect(preferredCountryOf('zh-CN'), 'CN');
      expect(preferredLanguageOf('zh'), 'zh');
      expect(preferredCountryOf('zh'), '');
      expect(preferredLanguageOf(null), '');
      expect(preferredCountryOf(''), '');
    });
  });
}
