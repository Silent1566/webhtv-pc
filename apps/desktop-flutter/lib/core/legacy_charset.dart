/// 旧版 CJK 字符集解码与探测：Big5 / Shift-JIS / EUC-KR。
///
/// 为什么需要：字幕样本除 UTF-8/GBK 外，还有繁体中文（Big5）、日文
/// （Shift-JIS）与韩文（EUC-KR）。dart:convert 不含这三种编码，这里用纯
/// Dart 表实现（enough_convert 的 Big5、charset 的 Shift-JIS、cp949_codec
/// 的 CP949——EUC-KR 的超集），Windows 与 Linux 桌面都不需要原生库。
///
/// 两条硬规则：
/// 1. **严格解码**：解码抛错或结果里出现替换字符（U+FFFD）都算该编码不适用，
///    绝不把替换字符当作“解码成功”写进字幕；
/// 2. **有证据才切换**：未声明 charset 时不能“谁先不报错就用谁”。同一个字节
///    串常常几种编码都能严格解出来：GBK 能把 Shift-JIS/EUC-KR 的字节解成
///    “看起来像汉字”的乱码，CP949 也能把简体中文解成“满是谚文”的乱码。
///    这里用“脚本纯度”（解出的字符有多少落在该编码应有的文字范围内）加
///    假名/谚文证据来区分。
library;

import 'package:charset/charset.dart' as cjk;
import 'package:cp949_codec/cp949_codec.dart' as cp949;
import 'package:enough_convert/big5.dart' show big5;
import 'package:fast_gbk/fast_gbk.dart';

/// 无声明 charset 时的探测顺序：GBK 在前。
///
/// 理由：TVBox 生态的第三方文本（含字幕）以简体中文源为主，GBK 在前的顺序与
/// 既有的 UTF-8 到 GBK 兜底链保持一致；顺序只在证据打平时起决定作用。
const List<String> legacyCjkProbeOrder = <String>[
  'gbk',
  'big5',
  'shift_jis',
  'euc_kr',
];

/// 判定“假名/谚文占主导”所需的最少证据字符数。
///
/// 短样本的占比不稳定（两三个字符就能凑出 100%），因此同时要求出现次数。
const int _minEvidenceChars = 3;

/// 采信韩文证据所需的最少非 ASCII 字符数。
///
/// 极短文本上 GBK 与 CP949 是**对称**的：短中文被 CP949 解成纯谚文，短韩文被
/// GBK 解成纯汉字，两边纯度都是 1.0，任何证据规则都只能二选一。按设计文档
/// “TVBox 生态以简体中文源为主”与“打平按 GBK”的原则，这里让短文本留在 GBK：
/// 宁可一条短韩文落到 GBK（新增能力的边界），也不要把“对不起”“你吃饭了吗”
/// 这类最常见的短中文台词整篇变成韩文乱码（那是相对改动前的回归）。
const int _minHangulEvidenceTotal = 8;

/// 假名（或谚文）占非 ASCII 字符的比例达到该值，才认为文本是日文（或韩文）。
///
/// 真实日文单句的假名占比常在 0.45 上下（「東京都渋谷区に住んでいます」是
/// 6/13），阈值不能压到 0.5 以上；误判靠“假名只算全角 + 汉字占比上限 +
/// 纯度打平”共同排除，而不是靠这一条阈值。
const double _scriptEvidenceRatio = 0.3;

/// 判为日文时允许的汉字占比上限。
///
/// 不能压得太低：真实日文单句（如「明日は学校に行きます」）汉字与假名各占一半，
/// 上限取 0.4 会让它失去日文证据，被 CP949 解成“纯谚文”后抢走。
const double _maxHanRatioForKana = 0.7;

/// 判为韩文时允许的汉字占比上限（韩文正文里汉字很少）。
const double _maxHanRatioForHangul = 0.25;

/// 判定“这是可读文本”允许的乱码占比上限。
///
/// 取 0.2 而不是“过半”：随机字节能让 Shift-JIS 候选凑出 40%–60% 乱码的
/// 混合文本（例如 `dﾚ鴃活夲G｣Uﾎｬ`），阈值放软就会把这类字节当字幕接受。
/// 真实字幕的乱码来自误解码，比例要么接近 0，要么整篇都是；0.2 两边都分得开。
const double _maxJunkRatio = 0.2;

/// 纯度差距小于该值时视为“证据打平”，按 [legacyCjkProbeOrder] 决定。
///
/// GBK 与 Big5 都是双字节汉字编码，同一串字节常常两边都能解出汉字；
/// 没有足够差距时不做切换，避免把既有 GBK 样本改判成繁体乱码。
const double _purityMargin = 0.05;

/// 把 charset 名归一化成 [legacyCjkProbeOrder] 里的名字；未知返回 null。
///
/// 别名覆盖服务端/浏览器的常见写法。cp949/uhc 在字幕语境里按 EUC-KR 解：
/// 扩展区字符解不出来就算该编码不适用，不做猜测。
String? normalizeLegacyCjkCharset(String charsetName) {
  switch (charsetName.trim().toLowerCase()) {
    case 'gbk':
    case 'gb2312':
    case 'gb-2312':
    case 'gb18030':
    case 'gb-18030':
    case 'cp936':
    case 'ms936':
      return 'gbk';
    case 'big5':
    case 'big-5':
    case 'big_5':
    case 'cp950':
      return 'big5';
    case 'shift_jis':
    case 'shift-jis':
    case 'sjis':
    case 'x-sjis':
    case 'ms_kanji':
    case 'cp932':
    case 'windows-31j':
      return 'shift_jis';
    case 'euc-kr':
    case 'euc_kr':
    case 'euckr':
    case 'cp949':
    case 'uhc':
    case 'windows-949':
    case 'ks_c_5601-1987':
      return 'euc_kr';
    default:
      return null;
  }
}

/// 严格解码 charsetName；该编码不适用时返回 null。
///
/// 适用 = 没有抛错，且结果不含 U+FFFD。Big5 的查表解码遇到未映射的双字节会
/// 静默写入 U+FFFD，因此不能只靠异常判定。
String? decodeLegacyCjkStrict(String charsetName, List<int> bytes) {
  final name = normalizeLegacyCjkCharset(charsetName);
  if (name == null) return null;
  final String text;
  try {
    text = switch (name) {
      'big5' => big5.decode(bytes),
      'shift_jis' => cjk.shiftJis.decode(bytes),
      // EUC-KR 用 CP949（UHC）表解码：CP949 是 EUC-KR 的超集，真实韩文字幕
      // 常常就是 CP949。charset 包自带的 EucKR 表与标准不一致（0xC7D1 解错），
      // 不能用。
      'euc_kr' => cp949.cp949.decode(bytes),
      _ => gbk.decode(bytes, allowMalformed: false),
    };
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
  if (text.contains('\uFFFD')) return null;
  return text;
}

/// 未声明 charset 时，按文本证据在 GBK / Big5 / Shift-JIS / EUC-KR 中选择。
///
/// 返回 null 表示没有任何候选能严格解码，调用方据此给出可定位的解码错误，
/// 而不是把乱码当成功。
({String text, String charset})? probeLegacyCjkCharset(List<int> bytes) {
  final decoded = <String, _Candidate>{};
  for (final name in legacyCjkProbeOrder) {
    final text = decodeLegacyCjkStrict(name, bytes);
    if (text == null) continue;
    decoded[name] = _Candidate(
      name: name,
      text: text,
      stats: _ScriptStats.of(text),
    );
  }
  if (decoded.isEmpty) return null;

  final plausible = decoded.values
      .where((candidate) => candidate.stats.isPlausible)
      .toList();
  if (plausible.isEmpty) {
    // 唯一例外：整段半角片假名的旧日文样本。半角片假名在别的编码里都是乱码，
    // 只有 Shift-JIS 能把它们解成文字；但仍要求它是唯一能解的候选——随机字节
    // 若也能“解出点东西”，宁可返回 null 让调用方如实报错，也不静默给乱码。
    final japanese = decoded['shift_jis'];
    if (japanese != null &&
        japanese.stats.isHalfwidthKanaOnly &&
        decoded.length == 1) {
      return (text: japanese.text, charset: japanese.name);
    }
    return null;
  }

  // 取脚本纯度最高的候选；差距在 _purityMargin 以内的算打平。
  final ranked = plausible..sort((a, b) => b.purity.compareTo(a.purity));
  final bestPurity = ranked.first.purity;
  final tied = ranked
      .where((candidate) => bestPurity - candidate.purity <= _purityMargin)
      .toList();

  // 日文优先于韩文：Shift-JIS 字节按 CP949 解常常“全是谚文”，看起来比中文
  // 还干净；只有先把假名证据判掉，韩文分支才不会抢走日文字幕。
  for (final candidate in tied) {
    if (candidate.name == 'shift_jis' && candidate.stats.isKanaDominant) {
      return (text: candidate.text, charset: candidate.name);
    }
  }
  for (final candidate in tied) {
    if (candidate.name == 'euc_kr' && candidate.stats.isHangulDominant) {
      return (text: candidate.text, charset: candidate.name);
    }
  }

  // 其余按探测顺序决定（GBK 优先，与既有兜底一致）：打平区间里纯度可能
  // 相差零点几个百分点，但“打平”就意味着没有证据支持改判，顺序说了算。
  for (final name in legacyCjkProbeOrder) {
    for (final candidate in tied) {
      if (candidate.name == name) {
        return (text: candidate.text, charset: candidate.name);
      }
    }
  }
  // tied 里的名字都来自 legacyCjkProbeOrder，上面的循环必然命中；这一行只是
  // 防御性兜底，正常路径不可达。
  return (text: tied.first.text, charset: tied.first.name);
}

class _Candidate {
  const _Candidate({
    required this.name,
    required this.text,
    required this.stats,
  });

  final String name;
  final String text;
  final _ScriptStats stats;

  /// 该编码下的脚本纯度：落在“应有文字范围”内的非 ASCII 字符占比。
  double get purity => stats.purityFor(name);
}

/// 非 ASCII 字符的脚本统计，用来给候选编码打分。
class _ScriptStats {
  const _ScriptStats({
    required this.total,
    required this.han,
    required this.kana,
    required this.hangul,
    required this.halfwidthKana,
    required this.junk,
    required this.hangulLines,
    required this.hangulLinesSpaced,
  });

  factory _ScriptStats.of(String text) {
    var total = 0;
    var han = 0;
    var kana = 0;
    var hangul = 0;
    var halfwidthKana = 0;
    var junk = 0;
    var hangulLines = 0;
    var hangulLinesSpaced = 0;
    for (final rune in text.runes) {
      if (rune < 0x80) continue;
      total++;
      if (_isHan(rune)) {
        han++;
      } else if (rune >= 0x3040 && rune <= 0x30FF) {
        kana++;
      } else if (_isHangul(rune)) {
        hangul++;
      } else if (_isHalfwidthKana(rune)) {
        // 半角片假名：在 Shift-JIS 里合法，在中文/韩文里是乱码。按乱码计，
        // 只有“整段都是它”时才单独放行（见 isHalfwidthKanaOnly）。
        halfwidthKana++;
        junk++;
      } else if (!_isAllowedPunctuation(rune)) {
        junk++;
      }
    }
    // 只有韩文候选才需要按行看分词；大文件里其余候选不该为此付出一次扫描。
    if (hangul > 0) {
      for (final line in text.split('\n')) {
        if (!line.runes.any(_isHangul)) continue;
        hangulLines++;
        // 韩文按词空格分词；被误解成韩文的中文是一串连续谚文，行内没有空格。
        if (line.contains(' ') || line.contains('\u3000')) hangulLinesSpaced++;
      }
    }
    return _ScriptStats(
      total: total,
      han: han,
      kana: kana,
      hangul: hangul,
      halfwidthKana: halfwidthKana,
      junk: junk,
      hangulLines: hangulLines,
      hangulLinesSpaced: hangulLinesSpaced,
    );
  }

  /// 非 ASCII 字符总数（占比的分母）。
  final int total;
  final int han;
  final int kana;
  final int hangul;

  /// 半角片假名（U+FF61–FF9F）：已计入 [junk]，这里单独记一份供放行判断。
  final int halfwidthKana;

  /// 既不是汉字/假名/谚文，也不是中日韩标点的字符（含 U+FFFD、私用区）。
  final int junk;

  /// 含谚文的行数，以及其中行内有空格（含全角空格）的行数。
  ///
  /// 韩文按词空格分词；中文被 CP949 误解码成谚文后，整行是一串连续谚文，
  /// 没有任何空格。歌词式字幕（同一句短台词重复多行）靠这一条区分。
  final int hangulLines;
  final int hangulLinesSpaced;

  double get hanRatio => total == 0 ? 0 : han / total;
  double get kanaRatio => total == 0 ? 0 : kana / total;
  double get hangulRatio => total == 0 ? 0 : hangul / total;
  double get junkRatio => total == 0 ? 0 : junk / total;

  bool get isKanaDominant =>
      kana >= _minEvidenceChars &&
      kanaRatio >= _scriptEvidenceRatio &&
      hanRatio <= _maxHanRatioForKana;

  bool get isHangulDominant =>
      total >= _minHangulEvidenceTotal &&
      hangul >= _minEvidenceChars &&
      hangulRatio >= _scriptEvidenceRatio &&
      hanRatio <= _maxHanRatioForHangul &&
      // 每一行含谚文的文本都要有空格分词，否则更可能是中文被误解成谚文
      // （重复台词的歌词式字幕正是这种形态）。
      hangulLines > 0 &&
      hangulLinesSpaced == hangulLines;

  /// 汉字 + 假名 + 谚文的个数：真正“像文本”的字符。
  int get scriptCount => han + kana + hangul;

  /// 这个候选像不像可读文本。
  ///
  /// 两条同时成立才算：乱码占比不超过 [_maxJunkRatio]，且至少有一个真正的
  /// 文字字符。只有符号的候选（随机字节常见）不算文本——把 `｢ｻ` 这种
  /// 孤立符号当成功，等于把随机字节当字幕。
  bool get isPlausible =>
      total > 0 && junkRatio <= _maxJunkRatio && scriptCount > 0;

  /// 整段只有半角片假名（可夹 ASCII）：这是 Shift-JIS 的合法写法，但在
  /// 中文/韩文编码里是乱码。只有在没有别的候选可用时才放行。
  bool get isHalfwidthKanaOnly =>
      total > 0 &&
      halfwidthKana > 0 &&
      han == 0 &&
      kana == 0 &&
      hangul == 0 &&
      junk == halfwidthKana;

  /// 该编码下“不该出现”的字符数。
  ///
  /// - 日文：汉字、假名都合法，谚文算异常；
  /// - 韩文：谚文合法；汉字（hanja）在字幕里极少、假名不合法，按异常计，
  ///   以拉开与“中文被误解成韩文”的差距；
  /// - GBK：**含 176 个假名**（A4/A5 行），假名必须算合法，否则一份带日文
  ///   歌词的简体字幕会被判给 Big5；谚文仍算异常；
  /// - Big5：假名、谚文都算异常。
  int foreignFor(String charset) {
    switch (charset) {
      case 'shift_jis':
        return junk + hangul;
      case 'euc_kr':
        return junk + han + kana;
      case 'gbk':
        return junk + hangul;
      default:
        return junk + kana + hangul;
    }
  }

  /// 落在该编码应有文字范围内的字符占非 ASCII 字符的比例（0..1）。
  double purityFor(String charset) {
    if (total == 0) return 0;
    return 1 - foreignFor(charset) / total;
  }
}

bool _isHan(int rune) =>
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0xF900 && rune <= 0xFAFF);

bool _isHalfwidthKana(int rune) => rune >= 0xFF61 && rune <= 0xFF9F;

bool _isHangul(int rune) =>
    (rune >= 0xAC00 && rune <= 0xD7A3) ||
    (rune >= 0x1100 && rune <= 0x11FF) ||
    (rune >= 0x3130 && rune <= 0x318F);

/// 中日韩文本会出现的标点、全角符号与字幕常用符号：不算乱码，也不证明是
/// 哪种脚本。
///
/// 字幕里 ★ ☆ ♪ → ─ │ 这类符号很常见，GBK/Big5 也收录了它们；把它们算乱码
/// 会让真实字幕（例如 `★ 我等你 ★`）被误判成别的编码。
///
/// 刻意**不**收 U+2460–U+24FF（①②③、⒀）：Big5 的汉字被 CP949 误解时正好落在
/// 这一段，收进来会让繁体字幕被判给 EUC-KR。
bool _isAllowedPunctuation(int rune) =>
    (rune >= 0x3000 && rune <= 0x303F) ||
    (rune >= 0xFE30 && rune <= 0xFE4F) ||
    (rune >= 0xFF01 && rune <= 0xFF60) ||
    (rune >= 0xFFE0 && rune <= 0xFFE6) ||
    (rune >= 0x2000 && rune <= 0x206F) ||
    (rune >= 0x00A0 && rune <= 0x00FF) ||
    (rune >= 0xFE10 && rune <= 0xFE1F) ||
    // 箭头、框线、几何图形（★☆■）、杂项符号（♪☀）。
    (rune >= 0x2190 && rune <= 0x21FF) ||
    (rune >= 0x2500 && rune <= 0x257F) ||
    (rune >= 0x25A0 && rune <= 0x25FF) ||
    (rune >= 0x2600 && rune <= 0x26FF);
