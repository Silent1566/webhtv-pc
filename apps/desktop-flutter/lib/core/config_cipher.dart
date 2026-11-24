import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart'
    show AESEngine, CBCBlockCipher, KeyParameter, ParametersWithIV;

import 'app_error.dart';

/// Closed 2423 AES-128-CBC carrier format.
///
/// Layout: hex('$#' + key + '#$') + hex(ciphertext) + hex(iv13).
/// Key and IV are UTF-8, right-padded or truncated to 16 bytes. This decrypts
/// only the declared wire format; it does not attempt to break arbitrary
/// ciphertexts. Errors never echo the carrier or plaintext.
class ConfigCipher {
  static String decrypt2423(String input) {
    final text = input.replaceAll(RegExp(r'\s+'), '');
    if (!text.startsWith('2423')) throw _failure('缺少 2423 前缀');
    final delimiter = text.indexOf('2324', 4);
    if (delimiter < 0) throw _failure('缺少 2423 分隔符');
    final keyHex = text.substring(4, delimiter);
    final rest = text.substring(delimiter + 4);
    if (keyHex.isEmpty || keyHex.length.isOdd) throw _failure('密钥不是合法 hex');
    if (rest.length < 26 + 32 || rest.length.isOdd) {
      throw _failure('密文长度非法');
    }
    final cipherLength = rest.length - 26;
    if (cipherLength.isOdd || cipherLength % 32 != 0) {
      throw _failure('密文不是完整 AES 块');
    }
    final key = _asciiKey(keyHex);
    final iv = _asciiKey(rest.substring(cipherLength));
    final cipherBytes = _hexBytes(rest.substring(0, cipherLength));
    final engine = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final plain = Uint8List(cipherBytes.length);
    final block = Uint8List(16);
    for (var offset = 0; offset < cipherBytes.length; offset += 16) {
      block.setRange(0, 16, cipherBytes, offset);
      engine.processBlock(block, 0, plain, offset);
    }
    final padding = plain.last;
    if (padding < 1 || padding > 16 || padding > plain.length) {
      throw _failure('PKCS7 padding 非法');
    }
    for (var index = plain.length - padding; index < plain.length; index++) {
      if (plain[index] != padding) throw _failure('PKCS7 padding 非法');
    }
    try {
      return utf8.decode(plain.sublist(0, plain.length - padding));
    } on FormatException {
      throw _failure('明文不是 UTF-8');
    }
  }

  static Uint8List _asciiKey(String hex) {
    final bytes = _hexBytes(hex);
    final key = Uint8List(16)..fillRange(0, 16, 0x30);
    key.setRange(0, bytes.length > 16 ? 16 : bytes.length, bytes);
    return key;
  }

  static Uint8List _hexBytes(String hex) {
    if (hex.isEmpty || hex.length.isOdd) throw _failure('hex 长度非法');
    final result = Uint8List(hex.length ~/ 2);
    for (var index = 0; index < hex.length; index += 2) {
      final high = _hexDigit(hex.codeUnitAt(index));
      final low = _hexDigit(hex.codeUnitAt(index + 1));
      result[index ~/ 2] = (high << 4) | low;
    }
    return result;
  }

  static int _hexDigit(int unit) {
    if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
    if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
    if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
    throw _failure('hex 含非法字符');
  }

  static AppError _failure(String reason) =>
      AppError(AppErrorKind.configInvalid, '配置载体解码失败', detail: reason);
}
