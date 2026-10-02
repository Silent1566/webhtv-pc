/// 猫源（CatVod T4 服务端 bundle）识别与配置整形门禁测试。
///
/// 覆盖 §9 猫源导入的三个关键点：
/// - **地址识别**：`.../index.js.md5`、`.../index.js` 判为 bundle，普通配置 URL 不误判；
/// - **配置整形**：裸站点数组 / `{video:{sites:[...]}}` → 标准 `{sites:[...]}`，
///   相对 `api` 补基址，错误信封明确报错；
/// - **搜索默认**：猫源站点缺 `searchable` 时补 `1`（对齐 TVBox 生态），
///   但站点自己声明的值一律保留。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/cat_source.dart';
import 'package:webhtv_pc/core/config_parser.dart';

void main() {
  group('isBundle 地址识别', () {
    test('index.js.md5 / index.js 判为 bundle', () {
      expect(CatSource.isBundle('http://h/a/index.js.md5'), isTrue);
      expect(CatSource.isBundle('https://h/x/index.js'), isTrue);
      expect(CatSource.isBundle('http://h/index.js?v=2'), isTrue);
      expect(CatSource.isBundle('  HTTP://H/A/INDEX.JS.MD5  '), isTrue);
    });

    test('普通配置地址不误判', () {
      expect(CatSource.isBundle('http://h/config.json'), isFalse);
      expect(CatSource.isBundle('http://h/sub/2024/buye-0'), isFalse);
      expect(CatSource.isBundle('http://h/index.js.md5.bak'), isFalse);
      expect(CatSource.isBundle(''), isFalse);
      expect(CatSource.isBundle(null), isFalse);
    });

    test('本地包路径：含 index.js 的目录、index.js 本身、zip 都判为 bundle', () async {
      final temp = await Directory.systemTemp.createTemp('webhtv-cat-isbundle');
      addTearDown(() => temp.deleteSync(recursive: true));
      final dir = Directory(p.join(temp.path, 'catpkg'))..createSync();
      File(p.join(dir.path, 'index.js')).writeAsStringSync('// entry');

      // 目录形态（正斜杠/反斜杠/尾分隔符）
      expect(CatSource.isBundle(dir.path), isTrue);
      expect(CatSource.isBundle('${dir.path}${Platform.pathSeparator}'), isTrue);
      // 直接指向 index.js
      expect(CatSource.isBundle(p.join(dir.path, 'index.js')), isTrue);
      // 目录不含 index.js 时不算 bundle
      final empty = Directory(p.join(temp.path, 'empty'))..createSync();
      expect(CatSource.isBundle(empty.path), isFalse);
      // 不存在的路径不算 bundle（否则会把普通配置文件误判）
      expect(CatSource.isBundle(p.join(temp.path, 'missing')), isFalse);
    });

    test('远端地址不做磁盘探测（避免误判与多余 stat）', () {
      expect(CatSource.isBundle('http://h/index.js'), isTrue);
      expect(CatSource.isBundle('http://h/some/dir'), isFalse);
      expect(CatSource.isBundle('https://h/some/dir/'), isFalse);
    });
  });

  group('isConfig 形状判定', () {
    test('裸站点数组与 video.sites 都算配置', () {
      expect(CatSource.isConfig('[{"key":"a"}]'), isTrue);
      expect(CatSource.isConfig('{"sites":[]}'), isTrue);
      expect(CatSource.isConfig('{"video":{"sites":[]}}'), isTrue);
    });

    test('401 信封、欢迎页、空响应都不算配置', () {
      expect(CatSource.isConfig('{"code":401,"message":"Unauthorized"}'), isFalse);
      expect(CatSource.isConfig('<!DOCTYPE html><html>'), isFalse);
      expect(CatSource.isConfig('[]'), isFalse);
      expect(CatSource.isConfig(''), isFalse);
      expect(CatSource.isConfig(null), isFalse);
    });
  });

  group('normalize 配置整形', () {
    test('裸站点数组补 sites 字段并补基址', () {
      final root = jsonDecode('''
        [{"key":"douban","name":"豆瓣","type":4,"api":"/video/douban"}]
      ''');
      final out = CatSource.normalize('http://127.0.0.1:5000/config', root);
      final sites = out['sites'] as List;
      expect(sites.length, 1);
      expect((sites.first as Map)['api'], 'http://127.0.0.1:5000/video/douban');
    });

    test('video.sites 提升为顶层 sites，其余分组不接入', () {
      final root = jsonDecode('''
        {"video":{"sites":[{"key":"k","name":"n","type":3,"api":"/spider/k/3"}]},
         "read":{"sites":[{"key":"r"}]}}
      ''');
      final out = CatSource.normalize('http://127.0.0.1:8080', root);
      final sites = out['sites'] as List;
      expect(sites.length, 1);
      expect((sites.first as Map)['key'], 'k');
      expect((sites.first as Map)['api'], 'http://127.0.0.1:8080/spider/k/3');
    });

    test('绝对 api 不被改写', () {
      final root = jsonDecode('''
        {"sites":[{"key":"k","name":"n","type":3,"api":"http://other/x"}]}
      ''');
      final out = CatSource.normalize('http://127.0.0.1:8080', root);
      expect((out['sites'] as List).first['api'], 'http://other/x');
    });

    test('错误信封明确报错，而不是解析出空站点', () {
      final root = jsonDecode('{"code":401,"message":"订阅无效"}');
      expect(
        () => CatSource.normalize('http://127.0.0.1:1/config', root),
        throwsA(
          isA<AppError>().having((e) => e.message, 'message', contains('订阅无效')),
        ),
      );
    });

    test('保留 userinfo 的基址（避免每请求吃 401）', () {
      final root = jsonDecode('{"sites":[{"key":"k","name":"n","api":"/v"}]}');
      final out = CatSource.normalize(
        'http://root:pw@192.168.1.9:3000/config',
        root,
      );
      expect(
        (out['sites'] as List).first['api'],
        'http://root:pw@192.168.1.9:3000/v',
      );
    });
  });

  group('searchable 默认值（对齐 TVBox 生态）', () {
    test('缺失 searchable 的猫源站点补 1', () {
      final root = jsonDecode('''
        {"video":{"sites":[{"key":"k","name":"n","type":3,"api":"/spider/k/3"}]}}
      ''');
      final out = CatSource.normalize('http://127.0.0.1:8080', root);
      expect((out['sites'] as List).first['searchable'], 1);
    });

    test('站点自己声明的 searchable=0 保留', () {
      final root = jsonDecode('''
        {"sites":[{"key":"k","name":"n","type":3,"api":"/s/k","searchable":0}]}
      ''');
      final out = CatSource.normalize('http://127.0.0.1:8080', root);
      expect((out['sites'] as List).first['searchable'], 0);
    });

    test('补齐后能被 parseConfigDocument 解析为可搜索站点', () {
      final root = jsonDecode('''
        {"video":{"sites":[{"key":"nodejs_k","name":"K","type":3,"api":"/spider/k/3"}]}}
      ''');
      final normalized = CatSource.normalize('http://127.0.0.1:8080', root);
      final document = parseConfigDocument(jsonEncode(normalized));
      expect(document.config!.sites.length, 1);
      expect(document.config!.sites.first.searchable, isTrue);
      expect(document.config!.sites.first.api, 'http://127.0.0.1:8080/spider/k/3');
      expect(document.config!.sites.first.type, 3);
    });
  });
}
