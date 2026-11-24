import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/config_parser.dart';

const carrierPlain =
    '{"sites":[{"key":"a","name":"A","type":1,"api":"https://example.test/api"}]}';
// OpenSSL enc -aes-128-cbc: key demo and IV 1234567890123, ASCII-0 padded.
const carrierCiphertext =
    '9e9d93573cc48868d200761553b9bc1fc33e1d23493a51268894583ba8bc21e75'
    '257dd709de6699c83e9892e721418731a45119fd3a2dc509ff9ee5a7f8a552ef'
    'dd09e4162e2916eb4ffba0fdd137be9';
String encodeCarrier(String text) => base64Encode(utf8.encode(text));
String aesCarrier(String ciphertext) =>
    '242364656d6f2324${ciphertext}31323334353637383930313233';

void main() {
  test('strict JSON fields containing Base64 and ** remain data', () {
    final map = jsonDecode(carrierPlain) as Map<String, dynamic>;
    map['marker'] = 'arbitrary**${encodeCarrier(carrierPlain)}';
    map['encoded'] = encodeCarrier(carrierPlain);
    expect(parseConfigDocument(jsonEncode(map)).raw, map);
  });
  final valid = <String, String>{
    'plain': carrierPlain,
    'pre attributes':
        '<pre class="config" data-note=\'a>b\'>$carrierPlain</pre>',
    'whole Base64': encodeCarrier(carrierPlain),
    'url safe unpadded': base64Url
        .encode(utf8.encode(carrierPlain))
        .replaceAll('=', ''),
    'arbitrary last marker': 'first**任意前缀**${encodeCarrier(carrierPlain)}',
    'AES independent OpenSSL vector': aesCarrier(carrierCiphertext),
    'lenient data': "/*head*/{sites:[{key:'a',name:'A',type:1,api:'https://example.test/api',},], // line\n extra:{bare_key:true,\$key:null,},}",
    'three carriers':
        '<pre>${encodeCarrier(aesCarrier(carrierCiphertext))}</pre>',
    'BOM in decoded layer': encodeCarrier('\ufeff$carrierPlain'),
  };
  for (final entry in valid.entries) {
    test('accepts ${entry.key}', () {
      expect(parseConfigDocument(entry.value).config!.sites.single.key, 'a');
    });
  }
  final invalid = <String, String>{
    'four carriers': encodeCarrier(
      '<pre>${encodeCarrier(aesCarrier(carrierCiphertext))}</pre>',
    ),
    'pre trailing text': '<pre>$carrierPlain</pre>trailing',
    'multiple pre': '<pre>$carrierPlain</pre><pre>{}</pre>',
    'pre embedded HTML': '<pre><script>$carrierPlain</script></pre>',
    'pre incomplete': '<pre>$carrierPlain',
    'bare value': '{sites: unquoted}',
    'NaN': '{sites:[], extra:NaN}',
    'Infinity': '{sites:[], extra:Infinity}',
    'nonfinite exponent': '{sites:[], extra:1e9999}',
    'expression': '{sites:[], extra:1+2}',
    'function': '{sites:[], extra:function(){}}',
    'assignment': 'var config = $carrierPlain',
    'trailing code': '$carrierPlain;run()',
    'trailing value': '$carrierPlain {}',
    'incomplete object': '{sites:[',
    'incomplete comment': '$carrierPlain /*',
    'incomplete quote': "{sites:[], extra:'unfinished}",
    'invalid escape': r"{sites:[], extra:'bad\q'}",
    'hex odd': '${aesCarrier(carrierCiphertext)}a',
    'hex nonhex': '${aesCarrier(carrierCiphertext)}zz',
    'AES missing delimiter':
        '242364656d6f2325${carrierCiphertext}31323334353637383930313233',
    'AES incomplete block': aesCarrier(carrierCiphertext.substring(2)),
    'AES bad padding': aesCarrier(
      '${carrierCiphertext.substring(0, carrierCiphertext.length - 2)}00',
    ),
    'AES invalid UTF8': aesCarrier('3194c1584c8a60e2d283611cfa79ea97'),
    'Base64 invalid UTF8': '/w==',
    'Base64 invalid padding': 'prefix**a===',
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key}', () {
      expect(() => parseConfigDocument(entry.value), throwsA(isA<AppError>()));
    });
  }
  test('container depth 64 accepted and 65 rejected, strict and lenient', () {
    for (final lenient in [false, true]) {
      String nested(int arrays) => '${'[' * arrays}0${']' * arrays}';
      final prefix = lenient ? '{sites:' : '{"sites":';
      final sites = (jsonDecode(carrierPlain) as Map)['sites'];
      final body = '$prefix${jsonEncode(sites)},"extra":';
      expect(parseConfigDocument('$body${nested(63)}}').config, isNotNull);
      expect(
        () => parseConfigDocument('$body${nested(64)}}'),
        throwsA(isA<AppError>()),
      );
    }
  });
  test('strict depth error names the limit without echoing the document', () {
    final sites = (jsonDecode(carrierPlain) as Map)['sites'];
    final input =
        '{"sites":${jsonEncode(sites)},"extra":${List.filled(64, "[").join()}0${List.filled(64, "]").join()}}';
    try {
      parseConfigDocument(input);
      fail('depth 65 must fail');
    } on AppError catch (error) {
      expect(error.kind, AppErrorKind.configInvalid);
      expect(error.message, 'JSON 容器深度超过 64');
      for (final detail in [
        error.detail ?? '',
        error.toString(),
        error.logLine,
        error.cause.toString(),
      ]) {
        expect(detail, isNot(contains(input)));
      }
    }
  });

  test('8 MiB input bound counts UTF8, including plaintext JSON', () {
    final oversize = jsonEncode({
      'sites': (jsonDecode(carrierPlain) as Map)['sites'],
      'extra': '界' * (8 * 1024 * 1024 ~/ 3),
    });
    expect(
      () => parseConfigDocument(oversize),
      throwsA(
        isA<AppError>().having(
          (e) => e.kind,
          'kind',
          AppErrorKind.configTooLarge,
        ),
      ),
    );
  });
  test('duplicate root credentials survive lenient normalization and carriers', () {
    const secret = 'subscription-secret-123456789';
    final sites = jsonEncode((jsonDecode(carrierPlain) as Map)['sites']);
    final documents = [
      '{tmdb_api_key: "$secret", "tmdb_\\u0061pi_key":"other-secret-123456",sites:$sites,}',
      '{"tmdb_api_key":"$secret","tmdb_\\u0061pi_key":"other-secret-123456","sites":$sites}',
    ];
    for (final document in documents) {
      for (final text in [
        document,
        '<pre>$document</pre>',
        encodeCarrier(document),
        'any**${encodeCarrier(document)}',
      ]) {
        final result = parseConfigDocument(text);
        expect(result.tmdbApiKeyCandidate, isEmpty);
        expect(jsonEncode(result.raw), isNot(contains(secret)));
        expect(result.raw, isNot(contains('tmdb_api_key')));
      }
    }
    for (final value in [
      '1234567890123456',
      'null',
      "'short'",
      "'bad space-123456789'",
    ]) {
      final result = parseConfigDocument('{tmdb_api_key:$value,sites:$sites,}');
      expect(result.tmdbApiKeyCandidate, isEmpty);
      expect(result.raw, isNot(contains('tmdb_api_key')));
    }
    final single = parseConfigDocument(
      "{tmdb_api_key:'$secret',sites:$sites,}",
    );
    expect(single.tmdbApiKeyCandidate, secret);
    expect(jsonEncode(single.config!.toJson()), isNot(contains(secret)));
  });
  test('lenient msg still uses the existing configuration error', () {
    expect(
      () => parseConfigDocument("{msg:'订阅已过期',sites:[],}"),
      throwsA(
        isA<AppError>()
            .having((e) => e.kind, 'kind', AppErrorKind.configMsg)
            .having((e) => e.message, 'message', '订阅已过期'),
      ),
    );
  });

  test('AES failure errors echo neither carrier nor plaintext', () {
    final carrier = aesCarrier(
      '\${carrierCiphertext.substring(0, carrierCiphertext.length - 2)}00',
    );
    try {
      parseConfigDocument(carrier);
      fail('bad padding must fail');
    } on AppError catch (error) {
      for (final detail in [
        error.toString(),
        error.logLine,
        error.cause.toString(),
      ]) {
        expect(detail, isNot(contains(carrier.substring(0, 48))));
      }
    }
  });

  test('malformed carrier errors expose neither plaintext nor raw source', () {
    const secret = 'subscription-secret-123456789';
    for (final plain in [
      "{tmdb_api_key:'$secret',sites:[",
      '{"tmdb_api_key":"$secret", bad',
    ]) {
      for (final text in [
        plain,
        '<pre>$plain</pre>',
        'secret**${encodeCarrier(plain)}',
      ]) {
        try {
          parseConfigDocument(text);
          fail('must reject malformed input');
        } on AppError catch (error) {
          for (final detail in [
            error.toString(),
            error.logLine,
            error.cause.toString(),
          ]) {
            expect(detail, isNot(contains(secret)));
            expect(detail, isNot(contains(text)));
          }
        }
      }
    }
  });
}
