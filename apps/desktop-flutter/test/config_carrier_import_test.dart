import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/config_loader.dart';
import 'package:webhtv_pc/core/config_parser.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/state/app_state.dart';

const _plain =
    '{"name":"载体配置","sites":[{"key":"carrier","name":"Carrier","type":1,"api":"https://example.test/api"}]}';
// Independent OpenSSL AES-128-CBC vector, see config_carrier_decoder_test.
const _cipher =
    '9e9d93573cc48868d200761553b9bc1fc33e1d23493a51268894583ba8bc21e75'
    '257dd709de6699c83e9892e721418731a45119fd3a2dc509ff9ee5a7f8a552ef'
    'dd09e4162e2916eb4ffba0fdd137be9';
String b64(String text) => base64Encode(utf8.encode(text));
const _aes = '242364656d6f2324${_cipher}31323334353637383930313233';

void main() {
  test('pasted carriers are inline data while normal paths stay files', () {
    expect(ConfigSource.parse(_plain).kind, ConfigSourceKind.inlineJson);
    expect(
      ConfigSource.parse('<pre class=x>$_plain</pre>').kind,
      ConfigSourceKind.inlineJson,
    );
    expect(ConfigSource.parse(b64(_plain)).kind, ConfigSourceKind.inlineJson);
    expect(ConfigSource.parse(_aes).kind, ConfigSourceKind.inlineJson);
    expect(
      ConfigSource.parse('// header\n$_plain').kind,
      ConfigSourceKind.inlineJson,
    );
    for (final path in [
      'config.json',
      '/tmp/config.json',
      r'C:\configs\a.json',
      '../fixtures/config.json',
      'configs/live.txt',
      '//server/share',
    ]) {
      expect(
        ConfigSource.parse(path).kind,
        ConfigSourceKind.file,
        reason: path,
      );
    }
    expect(ConfigSource.parse('<pref').kind, ConfigSourceKind.file);
    expect(
      ConfigSource.parse('https://example.test/config.json').kind,
      ConfigSourceKind.url,
    );
  });

  test('incomplete explicit carriers are inline data for error reporting', () {
    for (final input in ['<pre>{"sites":[]}', '2423zz', '242364656d6f2325']) {
      expect(
        ConfigSource.parse(input).kind,
        ConfigSourceKind.inlineJson,
        reason: input,
      );
    }
  });

  test('incomplete explicit carriers fail with bounded carrier errors', () {
    for (final input in ['<pre>{"sites":[]}', '2423zz', '242364656d6f2325']) {
      try {
        parseConfigDocument(input);
        fail('incomplete carrier must not parse: $input');
      } on AppError catch (error) {
        expect(error.kind, AppErrorKind.configInvalid, reason: input);
        for (final detail in [
          error.message,
          error.detail ?? '',
          error.toString(),
          error.logLine,
          error.cause.toString(),
        ]) {
          expect(detail, isNot(contains(input)), reason: input);
        }
      }
    }
  });

  group('carriers reach every import entry', () {
    late Directory temp;
    late HttpServer server;
    late String baseUrl;
    late String body;
    late ConfigLoader loader;
    late ConfigImportService service;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('carrier-import');
      body = _aes;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        request.response.write(body);
        await request.response.close();
      });
      loader = ConfigLoader();
      service = ConfigImportService(loader: loader);
    });
    tearDown(() async {
      service.close();
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    test('file and URL accept AES; Base64 remains URL compatible', () async {
      final file = File('${temp.path}/carrier.json');
      await file.writeAsString(b64(_plain));
      expect(
        (await service.import(ConfigSource.parse(file.path))).siteCount,
        1,
      );
      expect(
        (await service.import(ConfigSource.parse('$baseUrl/config'))).siteCount,
        1,
      );
      body = 'legacy-prefix**${b64(_plain)}';
      expect(
        (await service.import(ConfigSource.parse('$baseUrl/config'))).siteCount,
        1,
      );
    });

    test(
      'manual and background refresh accept carriers; failure keeps data',
      () async {
        final paths = AppPaths.resolve(
          overrides: {
            'config': '${temp.path}/webhtv-pc',
            'data': '${temp.path}/webhtv-pc',
            'cache': '${temp.path}/webhtv-pc/cache',
            'state': '${temp.path}/webhtv-pc/logs',
          },
        );
        final state = AppState(paths: paths, log: LogService());
        addTearDown(state.dispose);
        await state.bootstrap();
        final id = state.database!.saveConfig(
          name: '旧配置',
          origin: '$baseUrl/config',
          json: const {'sites': <Object?>[]},
          siteCount: 0,
        );

        expect(await state.refreshConfigRecord(id), isTrue);
        final manual = state.database!.listConfigs().single;
        expect(manual.id, id);
        expect((manual.json['sites'] as List).single['key'], 'a');

        final background = {
          'name': '后台载体',
          'sites': [
            {
              'key': 'b',
              'name': 'B',
              'type': 1,
              'api': 'https://example.test/b',
            },
          ],
        };
        body = b64(jsonEncode(background));
        await state.refreshConfigsInBackground();
        final refreshed = state.database!.listConfigs().single;
        expect(refreshed.id, id);
        expect(refreshed.siteCount, 1);
        expect((refreshed.json['sites'] as List).single['key'], 'b');
        expect(refreshed.json['name'], '后台载体');

        body =
            '242364656d6f2324${_cipher.substring(2)}31323334353637383930313233';
        await state.refreshConfigsInBackground();
        final failed = state.database!.listConfigs().single;
        expect(failed.id, id);
        expect(failed.siteCount, 1);
        expect(failed.json, refreshed.json);
        expect(failed.lastCheckError, isNotNull);
      },
    );
  });
}
