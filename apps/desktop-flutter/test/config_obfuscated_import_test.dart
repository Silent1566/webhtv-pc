import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/config_loader.dart';

void main() {
  const configJson =
      '{"name":"混淆订阅","sites":[{"key":"demo","name":"中文站点",'
      '"type":1,"api":"https://example.com/api"}],'
      '"extra":{"marker":"keep**unchanged"}}';
  final payload = base64Encode(utf8.encode(configJson));
  late HttpServer server;
  late ConfigLoader loader;
  late ConfigImportService service;
  late String body;
  late bool compressed;

  setUp(() async {
    body = configJson;
    compressed = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.text;
      final bytes = utf8.encode(body);
      if (compressed) {
        request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        request.response.add(gzip.encode(bytes));
      } else {
        request.response.add(bytes);
      }
      await request.response.close();
    });
    loader = ConfigLoader();
    service = ConfigImportService(loader: loader);
  });

  tearDown(() async {
    service.close();
    await server.close(force: true);
  });

  ConfigSource source() =>
      ConfigSource.parse('http://127.0.0.1:${server.port}/config');

  group('URL 混淆订阅导入（#114）', () {
    test('前缀 ** Base64 解码后保留中文、未知字段与来源', () async {
      body = '7oej1tRM**$payload';

      final imported = await service.import(source());

      expect(imported.config!.name, '混淆订阅');
      expect(imported.config!.sites.single.key, 'demo');
      expect(imported.config!.sites.single.name, '中文站点');
      expect(imported.document.raw['extra'], {'marker': 'keep**unchanged'});
      expect(imported.origin, source().value);
    });

    test('使用最后一个 **，不限制前缀长度', () async {
      body = 'first**随机前缀**$payload';
      expect((await service.import(source())).siteCount, 1);
    });

    test('没有前缀的纯 Base64 同样支持', () async {
      body = payload;
      expect((await service.import(source())).config!.name, '混淆订阅');
    });

    test('允许 Base64 内换行、空白与缺失的 padding', () async {
      final unpadded = payload.replaceAll('=', '');
      body =
          ' \ufeff prefix**\n ${unpadded.substring(0, 24)} \t\r\n'
          '${unpadded.substring(24)} \n';
      expect((await service.import(source())).siteCount, 1);
    });

    test('gzip 与 UTF-8 BOM 解码后再解包', () async {
      body = '\ufeff7oej1tRM**$payload';
      compressed = true;

      final imported = await service.import(source());

      expect(imported.siteCount, 1);
      expect(imported.contentEncoding, 'gzip');
    });

    test('合法明文 JSON 即使含 ** 与 Base64 字段也原样返回', () async {
      final plainConfig = jsonDecode(configJson) as Map<String, dynamic>;
      plainConfig['encoded'] = payload;
      body = jsonEncode(plainConfig);
      final fetched = await loader.fetch(source());
      expect(fetched.text, body);
      expect((await service.import(source())).siteCount, 1);
    });

    test('合法 JSON 字符串不会被当成混淆配置', () async {
      body = jsonEncode('prefix**$payload');
      expect((await loader.fetch(source())).text, body);
      await expectLater(
        service.import(source()),
        throwsA(
          isA<AppError>().having(
            (error) => error.message,
            'message',
            '配置根节点必须是 JSON 对象',
          ),
        ),
      );
    });

    test('解码后的 urls 仓库和条目均能导入', () async {
      final repository = jsonEncode({
        'urls': [
          {'name': '子配置', 'url': source().value},
        ],
      });
      body = 'repository**${base64Encode(utf8.encode(repository))}';
      final imported = await service.import(source());
      expect(imported.isRepository, isTrue);
      expect(imported.repositoryEntries.single.name, '子配置');

      body = 'child**$payload';
      final expanded = await service.expandRepository(imported);
      expect(expanded.siteCount, 1);
    });

    test('解码后仍通过凭据剥离流程', () async {
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      config['tmdb_api_key'] = 'subscription-test-key';
      body = 'secret**${base64Encode(utf8.encode(jsonEncode(config)))}';

      final imported = await service.import(source());

      expect(imported.tmdbApiKeyCandidate, 'subscription-test-key');
      expect(imported.document.raw, isNot(contains('tmdb_api_key')));
      expect(imported.config!.toJson(), isNot(contains('tmdb_api_key')));
    });

    test('解码后的 msg 仍按既有配置错误上报', () async {
      body = 'prefix**${base64Encode(utf8.encode('{"msg":"订阅已过期"}'))}';
      await expectLater(
        service.import(source()),
        throwsA(
          isA<AppError>()
              .having((error) => error.kind, 'kind', AppErrorKind.configMsg)
              .having((error) => error.message, 'message', '订阅已过期'),
        ),
      );
    });

    test('解码后的根节点和站点仍须通过原有校验', () async {
      for (final entry in {
        '[1,2,3]': '配置根节点必须是 JSON 对象',
        '{"sites":[]}': '配置中没有可用站点',
      }.entries) {
        body = 'prefix**${base64Encode(utf8.encode(entry.key))}';
        await expectLater(
          service.import(source()),
          throwsA(
            isA<AppError>()
                .having(
                  (error) => error.kind,
                  'kind',
                  AppErrorKind.configInvalid,
                )
                .having((error) => error.message, 'message', entry.value),
          ),
        );
      }
    });

    for (final invalid in [
      'prefix**',
      'prefix**not!base64',
      'prefix**a',
      'prefix**/w==',
      'prefix**${base64Encode(utf8.encode('<html>not JSON</html>'))}',
      'prefix**${base64Encode(utf8.encode('{"sites":['))}',
      '<html>upstream error</html>',
    ]) {
      test('无效内容保留原文并沿用 JSON 错误：$invalid', () async {
        body = invalid;
        expect((await loader.fetch(source())).text, invalid);
        await expectLater(
          service.import(source()),
          throwsA(
            isA<AppError>()
                .having(
                  (error) => error.kind,
                  'kind',
                  AppErrorKind.configInvalid,
                )
                .having((error) => error.message, 'message', 'JSON 解析失败'),
          ),
        );
      });
    }
  });
}
