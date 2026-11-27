/// 站点给的「本机 /proxy?do=…」地址要映射进本会话的作用域代理（对齐安卓的
/// 「App 内置 /proxy 转发给 spider.proxy()」能力）。
///
/// 实测来源：http://127.0.0.1:0/proxy?do=danmu&name=…&episode=1&season=1
/// ——端口是未绑定时的默认值 0（安卓写死 9978 的同一种写法）。旧实现要求
/// authority 与 JVM 数据面完全相同，于是这类地址被当成外站地址原样放行，
/// 最终打到一个不存在的端口，报成「网络不可达」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/spider_proxy_session.dart';

void main() {
  final entry = Uri.parse('http://127.0.0.1:51234/s/tok123/proxy');

  final ownBase = Uri.parse('http://127.0.0.1:51234');
  String scope(String url) => SpiderProxySession.scopeLocalProxyUrl(
    url,
    entryUrl: entry,
    ownBase: ownBase,
  );

  test('本机 /proxy 不写端口（0）也能映射进会话作用域', () {
    const source =
        'http://127.0.0.1:0/proxy?do=danmu&name=%E9%80%90%E7%8E%89'
        '&episode=1&season=1';
    expect(
      scope(source),
      'http://127.0.0.1:51234/s/tok123/proxy?do=danmu'
      '&name=%E9%80%90%E7%8E%89&episode=1&season=1',
    );
  });

  test('安卓写死的 9978 与其他本机端口同样映射', () {
    expect(
      scope('http://127.0.0.1:9978/proxy?do=danmu'),
      'http://127.0.0.1:51234/s/tok123/proxy?do=danmu',
    );
    expect(
      scope('http://localhost:8080/proxy?do=ck'),
      'http://127.0.0.1:51234/s/tok123/proxy?do=ck',
    );
  });

  test('本会话数据面的精确地址即使没有 do 也照旧接管', () {
    const query = 'a=%2f%2B&sig=x+y&x=%252F';
    expect(scope('http://127.0.0.1:51234/proxy?$query'), '$entry?$query');
  });

  test('没有 do 的本机 /proxy 不接管（可能是用户自己的本地服务）', () {
    expect(scope('http://127.0.0.1:0/proxy'), 'http://127.0.0.1:0/proxy');
    expect(
      scope('http://127.0.0.1:9978/proxy?a=%2f%2B&sig=x+y'),
      'http://127.0.0.1:9978/proxy?a=%2f%2B&sig=x+y',
      reason: '媒体形态（无 do）保持旧契约：只重写本会话数据面的精确地址',
    );
  });

  test('非本机地址、非 /proxy 路径、带凭据或片段的地址一律不动', () {
    for (final url in [
      'http://192.168.1.5:8080/proxy?do=danmu',
      'https://media.test/proxy?do=danmu',
      'http://127.0.0.1:9000/notproxy?do=danmu',
      'http://u:p@127.0.0.1:9000/proxy?do=danmu',
      'http://127.0.0.1:9000/proxy#frag',
      'not a url',
      '',
    ]) {
      expect(scope(url), url, reason: url);
    }
  });

  test('已经在本会话作用域内的地址保持原样（幂等）', () {
    const scoped = 'http://127.0.0.1:51234/s/tok123/proxy?do=danmu';
    expect(scope(scoped), scoped);
  });
}
