/// 弹幕内容诊断：把响应的开头压成一行，用于失败日志（绝不进用户提示）。
///
/// 为什么要它：站源 /proxy?do=danmu 返回的不是弹幕时，现在只说「内容非法」，
/// 看不出是 HTML 错误页、JSON、还是别的编码——这一行就是用来分辨的。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/danmaku.dart';

void main() {
  test('压缩空白并截断', () {
    final preview = danmakuPayloadPreview(
      '  <html>\n\n  <body>error</body>  </html>  ',
    );
    expect(preview, '<html> <body>error</body> </html>');
  });

  test('长内容按上限截断并加省略号', () {
    final preview = danmakuPayloadPreview('a' * 300, maxChars: 40);
    expect(preview.length, 41);
    expect(preview.endsWith('…'), isTrue);
  });

  test('URL 与查询串被抹掉，避免把带 token 的地址写进日志', () {
    final preview = danmakuPayloadPreview(
      'redirect: https://dm.test/api?token=secret&ep=1 then body',
    );
    expect(preview, isNot(contains('secret')));
    expect(preview, contains('redirect: '));
  });

  test('空内容返回空串', () {
    expect(danmakuPayloadPreview('   '), '');
  });
}
