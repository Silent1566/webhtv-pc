/// 播放结果里的「本机 /proxy」地址映射：计数与字段路径（诊断用）。
///
/// 为什么需要它：弹幕源写成 http://127.0.0.1:0/proxy?do=danmu… 时，失败日志只说
/// 「网络不可达」。要么是会话不在（没映射），要么是映射了但站源不实现 do=danmu——
/// 这两种情况的修法完全不同，日志里必须能分开。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/sidecar_runtime.dart';

void main() {
  final touched = <String>[];
  String scope(String url) => url.contains('/proxy?do=')
      ? url.replaceFirst('127.0.0.1:0', '127.0.0.1:51234/s/tok/proxy-host')
      : url;

  setUp(touched.clear);

  test('弹幕源被映射时记下它的字段路径', () {
    final scoped = SidecarRuntime.scopeProxyUrlsWith(
      {
        'danmaku': ['http://127.0.0.1:0/proxy?do=danmu&name=x'],
        'url': 'https://cdn.test/a.m3u8',
      },
      scope,
      touched: touched,
    );
    expect((scoped as Map)['danmaku'], [
      'http://127.0.0.1:51234/s/tok/proxy-host/proxy?do=danmu&name=x',
    ]);
    expect((scoped)['url'], 'https://cdn.test/a.m3u8');
    expect(touched, ['danmaku.0']);
  });

  test('嵌套列表/对象里的地址同样计数，且路径可读', () {
    SidecarRuntime.scopeProxyUrlsWith(
      {
        'lines': [
          {
            'episodes': [
              {'url': 'http://127.0.0.1:0/proxy?do=danmu'},
            ],
          },
        ],
      },
      scope,
      touched: touched,
    );
    expect(touched, ['lines.0.episodes.0.url']);
  });

  test('没有可映射地址时一条都不记（据此判断会话是否生效）', () {
    final value = {
      'danmaku': ['https://danmaku.test/api?name={name}'],
      'url': 'https://cdn.test/a.m3u8',
      'n': 1,
      'b': true,
    };
    final scoped = SidecarRuntime.scopeProxyUrlsWith(value, scope, touched: touched);
    expect(touched, isEmpty);
    expect(scoped, value);
  });
}
