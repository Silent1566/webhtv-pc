/// 图片请求的 Header 注入（用户反馈 2026-10-25：「豆瓣的图片出不来，安卓版是正常的」）。
///
/// 实测根因（本机 curl，目标 \`https://img9.doubanio.com/view/photo/.../p*.webp\`）：
/// - 不带 \`Referer\` → **418 I'm a Teapot**（EdgeOne 边缘拦截，size=0）；
/// - 带 \`Referer: https://movie.douban.com\` + 普通 UA → 200；
/// - 带 \`Referer\` 但 UA 是 Dart 默认的 \`Dart/x.y (dart:io)\` → **仍然 418**。
///
/// 所以「只补 Referer」不够：图片链路必须同时注入 Referer 与一个非 Dart 的 UA。
/// 而 \`Image.network\` 此前**完全没带 headers**，顶层 \`headers\` 规则也只作用于
/// 站点 API 与媒体播放。本文件锁定这三件事：
/// 1. \`HeaderRule\` 支持 \`img\\d+.doubanio.com\` 这类正则/包含形态（旧实现只认 \`*\`）；
/// 2. \`imageHeadersFor\` 按图片自身 host 合并全局规则并补 UA，空规则时不返回空表；
/// 3. \`PosterImage\` 在 \`ImageHeaderScope\` 下真的把 header 交给了 \`Image.network\`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/image_headers.dart';
import 'package:webhtv_pc/core/image_user_agent.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/ui/app.dart' show PosterImage;
import 'package:webhtv_pc/ui/image_header_scope.dart';

/// 用户真实配置（AT 配置第 1/11 条）里豆瓣图床的写法。
const String _doubanPattern = r'img\d+.doubanio.com';

HeaderRule _doubanRule() => HeaderRule(
  host: _doubanPattern,
  header: HeaderMap({'Referer': 'https://movie.douban.com'}),
);

void main() {
  group('HeaderRule host 匹配（§7.4.6）', () {
    test('正则形态 host 命中 imgN.doubanio.com（旧实现只认 * ，会漏掉）', () {
      final rule = _doubanRule();
      expect(rule.matches('img9.doubanio.com'), isTrue);
      expect(rule.matches('img1.doubanio.com'), isTrue);
      expect(rule.matches('img12.doubanio.com'), isTrue);
      expect(rule.matches('IMG9.DoubanIO.com'), isTrue, reason: '大小写不敏感');
    });

    test('正则形态不误伤：\\d+ 至少一位数字，且必须整串域名匹配', () {
      final rule = _doubanRule();
      expect(rule.matches('img.doubanio.com'), isFalse, reason: '没有数字');
      expect(rule.matches('imgxdoubanio.com'), isFalse, reason: '点必须字面匹配');
      expect(rule.matches('img9.doubanio.com.evil.com'), isFalse);
      expect(rule.matches('notimg9.doubanio.com'), isFalse);
    });

    test('字面 host 仍然只做「完全相同或子域后缀」，不匹配 notexample.com', () {
      expect(
        HeaderRule(host: 'example.com', header: HeaderMap()).matches('cdn.example.com'),
        isTrue,
      );
      expect(
        HeaderRule(host: 'example.com', header: HeaderMap()).matches('notexample.com'),
        isFalse,
      );
      // 字面 img1 不会命中 img10（旧行为不变，避免扩大影响面）。
      expect(
        HeaderRule(host: 'img1.doubanio.com', header: HeaderMap())
            .matches('img10.doubanio.com'),
        isFalse,
      );
    });

    test('通配 host 行为不变', () {
      expect(HeaderRule(host: '*', header: HeaderMap()).matches('any.host'), isTrue);
      expect(
        HeaderRule(host: '*.example.com', header: HeaderMap()).matches('cdn.example.com'),
        isTrue,
      );
    });
  });

  group('图片请求 Header（imageHeadersFor）', () {
    test('无匹配规则时返回空表（调用方据此不传 headers，保住既有缓存键）', () {
      final headers = imageHeadersFor(const [], 'https://img9.doubanio.com/a.webp');
      expect(headers.isEmpty, isTrue);
    });

    test('命中豆瓣规则时给出 Referer；UA 不放在 headers 里（改由 HttpOverrides 替换）', () {
      final headers = imageHeadersFor([_doubanRule()], 'https://img9.doubanio.com/a.webp');
      expect(headers['Referer'], 'https://movie.douban.com');
      // 关键：NetworkImage 用 headers.add() 写头，若在这里放 UA 会与 dart:io 默认的
      // `Dart/x.y (dart:io)` 拼成多值，豆瓣仍 418。UA 必须客户端级 set。
      expect(headers.containsKey('User-Agent'), isFalse);
      expect(imageUserAgent.contains('Dart/'), isFalse);
    });

    test('非图片域名不受影响；URL 非法/无 host 时不注入', () {
      final rules = [_doubanRule()];
      expect(imageHeadersFor(rules, 'https://example.com/a.png').isEmpty, isTrue);
      expect(imageHeadersFor(rules, 'not a url').isEmpty, isTrue);
      expect(imageHeadersFor(rules, '').isEmpty, isTrue);
    });

    test('extra 与全局规则合并，且不覆盖调用方显式声明的同名键', () {
      final rules = [
        HeaderRule(host: '127.0.0.1', header: HeaderMap({'Accept': 'image/png'})),
      ];
      final headers = imageHeadersFor(
        rules,
        'http://127.0.0.1:5000/logo.png',
        extra: {'Accept': 'image/*,*/*;q=0.8', 'X-Extra': '1'},
      );
      expect(headers['Accept'], 'image/png', reason: '全局规则优先于调用方兜底');
      expect(headers['X-Extra'], '1');
    });

    test('配置里显式声明的 User-Agent 会原样透传（用户可自行覆盖 UA）', () {
      final rules = [
        HeaderRule(host: 'img.doubanio.com', header: HeaderMap({'User-Agent': 'Custom/1'})),
      ];
      final headers = imageHeadersFor(rules, 'https://img.doubanio.com/a.webp');
      expect(headers['User-Agent'], 'Custom/1');
    });
  });

  group('PosterImage 真的把 header 交给 Image.network', () {
    testWidgets('在 ImageHeaderScope 下按 host 注入 Referer + UA', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ImageHeaderScope(
            rules: [_doubanRule()],
            child: const SizedBox(
              width: 120,
              height: 180,
              child: PosterImage(url: 'https://img9.doubanio.com/a.webp'),
            ),
          ),
        ),
      );

      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image;
      expect(provider, isA<NetworkImage>());
      final headers = (provider as NetworkImage).headers;
      expect(headers?['Referer'], 'https://movie.douban.com');
      expect(headers?.containsKey('User-Agent'), isFalse, reason: 'UA 由 HttpOverrides 负责');
    });

    testWidgets('不在作用域内时不传 headers（既有单测与缓存键不受影响）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 120,
            height: 180,
            child: PosterImage(url: 'https://img9.doubanio.com/a.webp'),
          ),
        ),
      );

      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as NetworkImage).headers, isNull);
    });
  });

  group('图片 User-Agent 覆盖（HttpOverrides）', () {
    test('HttpOverrides 创建的客户端 UA 被真正替换，不再含 Dart/', () {
      final client = ImageHttpOverrides().createHttpClient(null);
      expect(client.userAgent, imageUserAgent);
      expect(client.userAgent!.contains('Dart/'), isFalse);
      client.close(force: true);
    });

    test('installImageUserAgent 安装覆盖并生效（main 在 runApp 前调用）', () {
      // 说明：flutter_test 会在测试 zone 里装 `_MockHttpOverrides`，它优先于全局值，
      // 因此不能直接断言 `HttpOverrides.current`；改为断言安装记录 + 实际客户端行为。
      expect(installedImageHttpOverrides, isNull, reason: '前置：测试里尚未安装');
      installImageUserAgent();
      final installed = installedImageHttpOverrides;
      expect(installed, isNotNull);
      expect(installed!.createHttpClient(null).userAgent, imageUserAgent);
    });
  });
}
