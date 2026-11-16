/// 字节 → 文本解码：BOM、gzip/br 传输压缩与 GBK/GB18030 声明编码。
///
/// 设计文档 §7.4.1 要求 PC 端目标支持 `gzip`、`br`、UTF-8 BOM，并允许配置明确
/// 声明 GBK/GB18030。这里把“传输层解压”和“字符集解码”分开，便于分别测试。
///
/// 除配置导入外，字幕等第三方文本还会出现 Big5、Shift-JIS、EUC-KR（见
/// [decodeTextAndCharset] 的 `allowLegacyCjk`）。这部分编解码与探测集中在
/// `legacy_charset.dart`，本文件只负责把它接进既有解码链。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brotli/brotli.dart' as brotli_codec;
import 'package:fast_gbk/fast_gbk.dart';

import 'app_error.dart';
import 'legacy_charset.dart';

/// Content-Encoding 处理结果。
class DecodedBody {
  const DecodedBody({required this.bytes, required this.encoding});

  final Uint8List bytes;

  /// 实际使用的压缩/传输编码：`identity`、`gzip`、`br` 或 `deflate`。
  final String encoding;
}

/// 解压 HTTP 响应体。
///
/// `dart:io` 的 HttpClient 默认会自动解压 gzip 并移除头部；本应用显式关闭自动
/// 解压（见 ConfigLoader），因此这里必须自己处理，否则会把已解压内容再解压一次。
/// 为兼容两种上游行为，解压失败时按原样返回，并在 [encoding] 中标注 `identity`。
DecodedBody decodeTransportBody(
  List<int> body, {
  String? contentEncoding,
}) {
  final normalized = (contentEncoding ?? 'identity').trim().toLowerCase();
  if (normalized.isEmpty || normalized == 'identity') {
    return DecodedBody(bytes: Uint8List.fromList(body), encoding: 'identity');
  }
  // 组合编码按“依次反向”处理，例如 `gzip, br`。
  final encodings = normalized
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty && item != 'identity')
      .toList()
      .reversed;
  var current = Uint8List.fromList(body);
  var applied = <String>[];
  for (final encoding in encodings) {
    try {
      switch (encoding) {
        case 'gzip':
        case 'x-gzip':
          current = Uint8List.fromList(gzip.decode(current));
          applied.add('gzip');
          break;
        case 'br':
          current = Uint8List.fromList(brotli_codec.brotli.decode(current));
          applied.add('br');
          break;
        case 'deflate':
          current = Uint8List.fromList(zlib.decode(current));
          applied.add('deflate');
          break;
        default:
          // 未知传输编码：不猜测，交由字符集解码抛出可定位错误。
          applied.add('unknown:$encoding');
      }
    } catch (error) {
      // 上游可能已经由 HTTP 栈自动解压；此时原始字节就是明文。
      if (applied.isEmpty) {
        return DecodedBody(
          bytes: Uint8List.fromList(body),
          encoding: 'identity(assumed:$error)',
        );
      }
      throw AppError(
        AppErrorKind.configDecode,
        '传输编码 $encoding 解压失败',
        cause: error,
      );
    }
  }
  return DecodedBody(bytes: current, encoding: applied.join(','));
}

/// 去掉 UTF-8 / UTF-16 BOM，返回剩余字节与探测到的编码名。
({Uint8List bytes, String? charset}) stripBom(List<int> input) {
  if (input.length >= 3 &&
      input[0] == 0xEF &&
      input[1] == 0xBB &&
      input[2] == 0xBF) {
    return (bytes: Uint8List.fromList(input.sublist(3)), charset: 'utf-8');
  }
  if (input.length >= 2 && input[0] == 0xFF && input[1] == 0xFE) {
    return (bytes: Uint8List.fromList(input.sublist(2)), charset: 'utf-16le');
  }
  if (input.length >= 2 && input[0] == 0xFE && input[1] == 0xFF) {
    return (bytes: Uint8List.fromList(input.sublist(2)), charset: 'utf-16be');
  }
  return (bytes: Uint8List.fromList(input), charset: null);
}

/// 从 `Content-Type` 中解析 charset 参数。
String? charsetFromContentType(String? contentType) {
  if (contentType == null) return null;
  final match = RegExp(
    r'''charset\s*=\s*"?([\w\-]+)"?''',
    caseSensitive: false,
  ).firstMatch(contentType);
  return match?.group(1)?.toLowerCase();
}

/// 把字节解码为文本，并返回实际使用的字符集。
///
/// 顺序固定为：BOM 优先 → 显式声明的 charset → UTF-8 严格解码 → GBK 兜底。
/// 声明阶段额外接受 Big5、Shift-JIS、EUC-KR（见 [decodeLegacyCjkStrict]）。
///
/// [allowLegacyCjk] 为 true 时，声明阶段额外接受 Big5 / Shift-JIS / EUC-KR，
/// 且 UTF-8 失败后不是“只试 GBK”，而是在 GBK / Big5 / Shift-JIS / EUC-KR 之间
/// 按文本证据选择（见 [probeLegacyCjkCharset]）：字幕这类第三方文本的编码不会
/// 写在文件里，只按“谁先不报错”判定会把日韩字幕静默解成汉字乱码。
/// 配置导入保持默认 false——§7.4.1 只要求配置支持 utf-8/utf-16/gbk，
/// 不能被字幕的字符集与探测规则改写。
///
/// 与 [decodeConfigText] 是同一套规则，区别只是把“用了哪个字符集”也返回，
/// 供字幕等需要把编码写进日志/诊断的调用方使用。
({String text, String charset}) decodeTextAndCharset(
  List<int> input, {
  String? declaredCharset,
  bool allowLegacyCjk = false,
}) {
  final stripped = stripBom(input);
  final charset = (declaredCharset ?? stripped.charset)?.trim().toLowerCase();
  final bytes = stripped.bytes;

  if (charset != null && charset.isNotEmpty) {
    final decoded = _decodeWithCharset(
      bytes,
      charset,
      allowLegacyCjk: allowLegacyCjk,
    );
    if (decoded != null) {
      // 声明与实际字节不符时（例如服务端声明 utf-8 却发 GBK 字节），声明路径
      // 只能解出替换字符；字幕改按证据探测，探测也无解才保留既有容错文本。
      if (allowLegacyCjk && decoded.contains('�')) {
        final match = probeLegacyCjkCharset(bytes);
        if (match != null) return (text: match.text, charset: match.charset);
      }
      // 只把新接入的三种编码归一化（cp950 → big5）；GBK 家族保留声明原样
      // （gb2312/gb18030/cp936），否则弹幕等调用方记录的编码会被悄悄改写。
      final normalized = normalizeLegacyCjkCharset(charset);
      return (
        text: decoded,
        charset: normalized == null || normalized == 'gbk' ? charset : normalized,
      );
    }
    // 名字认识、但按它解不出来：说“解不出来”，而不是“不支持”。
    final supported = allowLegacyCjk && normalizeLegacyCjkCharset(charset) != null;
    throw AppError(
      AppErrorKind.configDecode,
      supported ? '按声明的 $charset 无法解码内容' : '不支持的字符集：$charset',
      detail: supported
          ? '字节与该字符集不匹配，或内容已损坏'
          : allowLegacyCjk
          ? '支持 utf-8、utf-16le/be、gbk/gb2312/gb18030、big5、shift-jis、euc-kr'
          : '支持 utf-8、utf-16le/be、gbk/gb2312/gb18030',
    );
  }

  try {
    return (text: utf8.decode(bytes), charset: 'utf-8');
  } on FormatException {
    if (allowLegacyCjk) {
      // 字幕等第三方文本：GBK 能把日韩字节解成“像汉字”的乱码，必须比证据。
      final match = probeLegacyCjkCharset(bytes);
      if (match != null) return (text: match.text, charset: match.charset);
      throw AppError(
        AppErrorKind.configDecode,
        '无法按 UTF-8、GBK、Big5、Shift-JIS 或 EUC-KR 解码内容',
        detail: '请在响应中声明 charset（如 big5、shift_jis、euc-kr）',
      );
    }
    // 配置/清单等：未声明编码但包含非 UTF-8 字节，按兼容目标尝试 GBK。
    try {
      return (text: gbk.decode(bytes, allowMalformed: false), charset: 'gbk');
    } on FormatException {
      throw AppError(
        AppErrorKind.configDecode,
        '无法按 UTF-8 或 GBK 解码配置内容',
        detail: '请在响应中声明 charset（如 gb18030）',
      );
    }
  }
}

/// 把字节解码为文本。
///
/// 顺序固定为：BOM 优先 → 显式声明的 charset → UTF-8 严格解码 → GBK 兜底。
/// 任何一步失败都返回可定位的 [AppError]，不静默替换成乱码文本。
String decodeConfigText(
  List<int> input, {
  String? declaredCharset,
}) {
  if (input.isEmpty) {
    throw AppError(AppErrorKind.configInvalid, '配置内容为空');
  }
  return decodeTextAndCharset(input, declaredCharset: declaredCharset).text;
}

String? _decodeWithCharset(
  Uint8List bytes,
  String charset, {
  required bool allowLegacyCjk,
}) {
  switch (charset) {
    case 'utf-8':
    case 'utf8':
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return utf8.decode(bytes, allowMalformed: true);
      }
    case 'utf-16':
    case 'utf-16le':
      return _decodeUtf16(bytes, littleEndian: true);
    case 'utf-16be':
      return _decodeUtf16(bytes, littleEndian: false);
    case 'gbk':
    case 'gb2312':
    case 'gb-2312':
    case 'gb18030':
    case 'gb-18030':
    case 'cp936':
    case 'ms936':
      // GB18030 是 GBK 的超集；GBK 能覆盖常见配置文本的 BMP 字符。
      // 4 字节 GB18030 补充平面序列极少数出现在配置里，fast_gbk 会按
      // 允许畸形的方式替换，而不是让整份配置导入失败。
      try {
        return gbk.decode(bytes, allowMalformed: false);
      } on FormatException {
        return gbk.decode(bytes, allowMalformed: true);
      }
    case 'iso-8859-1':
    case 'latin1':
      return latin1.decode(bytes);
    default:
      // Big5 / Shift-JIS / EUC-KR 及其别名。默认不认：§7.4.1 只要求配置支持
      // utf-8/utf-16/gbk，字幕等第三方文本才显式开启。
      if (!allowLegacyCjk) return null;
      return decodeLegacyCjkStrict(charset, bytes);
  }
}

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final codeUnits = <int>[];
  for (var index = 0; index + 1 < bytes.length; index += 2) {
    final first = bytes[index];
    final second = bytes[index + 1];
    codeUnits.add(littleEndian ? first | (second << 8) : (first << 8) | second);
  }
  return String.fromCharCodes(codeUnits);
}
