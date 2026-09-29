/// 直播弹幕测试（设计文档 §13.1「直播弹幕」、§21 Phase 3）。
///
/// 覆盖两层（均为纯逻辑/无真实网络）：
/// 1. 帧解析：逐条对齐 Android `LiveDanmakuParser`——chat/superchat/online、
///    文本规范化（控制字符/空白折叠/代码点上限）、`#RRGGBB` 颜色、帧大小上限；
/// 2. 重连策略：对齐 Android `LiveDanmakuRetryPolicy`——指数退避 + 抖动、
///    关闭码与失败类型的可重试判定。
///
/// 说明：本文件**不含** `testWidgets`，因为 flutter_test 的 binding 会拦截进程内
/// 所有 HTTP/WS 连接（详见 docs/phase3/README.md §3.3）。真实 WS 会话在
/// `integration_test/live_danmaku_flow_test.dart` 里验证。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/live_danmaku.dart';

void main() {
  group('直播弹幕帧解析（对齐 Android LiveDanmakuParser）', () {
    LiveDanmakuParseResult parse(String frame, {int generation = 1}) =>
        parseLiveDanmakuFrame(
          frame,
          receivedAtMs: 1000,
          generation: generation,
        );

    test('chat → 普通弹幕，颜色与文本正确', () {
      final result = parse(
        '{"type":"chat","message":"你好世界","color":"#FFAA00"}',
      );
      expect(result.kind, LiveDanmakuFrameKind.message);
      expect(result.isAccepted, isTrue);
      final frame = result.frame!;
      expect(frame.type, LiveDanmakuMessageType.normal);
      expect(frame.text, '你好世界');
      // #FFAA00 补不透明 alpha。
      expect(frame.color, 0xFFFFAA00);
      expect(frame.receivedAtMs, 1000);
      expect(frame.generation, 1);
    });

    test('superchat → 醒目弹幕，字号大于普通弹幕', () {
      final normal = parse('{"type":"chat","message":"a"}').frame!;
      final superChat = parse('{"type":"superchat","message":"a"}').frame!;
      expect(superChat.type, LiveDanmakuMessageType.superChat);
      expect(superChat.textSizeSp, greaterThan(normal.textSizeSp));
    });

    test('type 大小写不敏感（对齐 Android toLowerCase）', () {
      expect(
        parse('{"type":"CHAT","message":"a"}').kind,
        LiveDanmakuFrameKind.message,
      );
      expect(
        parse('{"type":"SuperChat","message":"a"}').frame!.type,
        LiveDanmakuMessageType.superChat,
      );
    });

    test('online → 在线人数，不上屏', () {
      final result = parse('{"type":"online","data":12345}');
      expect(result.kind, LiveDanmakuFrameKind.online);
      expect(result.online, 12345);
      expect(result.frame, isNull);
      // 负数人数非法。
      expect(parse('{"type":"online","data":-1}').kind, LiveDanmakuFrameKind.invalid);
      // 非数字 data 非法。
      expect(
        parse('{"type":"online","data":"123"}').kind,
        LiveDanmakuFrameKind.invalid,
      );
      expect(parse('{"type":"online"}').kind, LiveDanmakuFrameKind.invalid);
    });

    test('无效输入一律 invalid：非 JSON/非对象/未知类型/空 message/非字符串 message', () {
      expect(parse('').kind, LiveDanmakuFrameKind.invalid);
      expect(parse('   ').kind, LiveDanmakuFrameKind.invalid);
      expect(parse('not-json').kind, LiveDanmakuFrameKind.invalid);
      expect(parse('[1,2,3]').kind, LiveDanmakuFrameKind.invalid);
      expect(parse('{"type":"unknown","message":"a"}').kind, LiveDanmakuFrameKind.invalid);
      expect(parse('{"type":"chat"}').kind, LiveDanmakuFrameKind.invalid);
      expect(parse('{"type":"chat","message":""}').kind, LiveDanmakuFrameKind.invalid);
      expect(parse('{"type":"chat","message":"   "}').kind, LiveDanmakuFrameKind.invalid);
      expect(parse('{"type":"chat","message":123}').kind, LiveDanmakuFrameKind.invalid);
      // 缺 type。
      expect(parse('{"message":"a"}').kind, LiveDanmakuFrameKind.invalid);
      expect(parse('{"type":123,"message":"a"}').kind, LiveDanmakuFrameKind.invalid);
    });

    test('颜色只接受 #RRGGBB，其余回落到默认白', () {
      expect(parse('{"type":"chat","message":"a","color":"#123456"}').frame!.color,
          0xFF123456);
      // 缺色 / 非字符串 / 错误格式 / 简写 → 默认白。
      expect(parse('{"type":"chat","message":"a"}').frame!.color, 0xFFFFFFFF);
      expect(parse('{"type":"chat","message":"a","color":123}').frame!.color,
          0xFFFFFFFF);
      expect(parse('{"type":"chat","message":"a","color":"#FFF"}').frame!.color,
          0xFFFFFFFF);
      expect(parse('{"type":"chat","message":"a","color":"red"}').frame!.color,
          0xFFFFFFFF);
      expect(parse('{"type":"chat","message":"a","color":"#GGGGGG"}').frame!.color,
          0xFFFFFFFF);
    });

    test('帧大小超过 64 KiB → invalid（对齐 MAX_FRAME_BYTES）', () {
      // 构造一个合法 JSON 但超过 64KiB 的帧。
      final big = 'x' * (maxLiveDanmakuFrameBytes + 10);
      final frame = '{"type":"chat","message":"$big"}';
      expect(parse(frame).kind, LiveDanmakuFrameKind.invalid);
      // 刚好小于上限但文本会被截断到 120 代码点。
      final small = 'y' * 100;
      final ok = parse('{"type":"chat","message":"$small"}').frame!;
      expect(ok.text, small);
    });
  });

  group('弹幕文本规范化（对齐 Android normalizeText）', () {
    test('控制字符被丢弃', () {
      expect(normalizeLiveDanmakuText('a\u0000b\u0007c'), 'abc');
      expect(normalizeLiveDanmakuText('好的\u001F'), '好的');
    });

    test('连续空白折叠为单个空格，首尾空白去除', () {
      expect(normalizeLiveDanmakuText('  a   b  '), 'a b');
      // 注意：制表符/换行在 Android 里先被 isISOControl 命中 → **丢弃**（不折叠成
      // 空格），只有真正的空白字符（空格、U+3000）才折叠。此处对齐该顺序。
      expect(normalizeLiveDanmakuText('a\t\tb\n\nc'), 'abc');
      expect(normalizeLiveDanmakuText('a  b'), 'a b');
      expect(normalizeLiveDanmakuText('    '), '');
      // 中文全角空格（U+3000）也是空白，折叠为普通空格。
      expect(normalizeLiveDanmakuText('a\u3000\u3000b'), 'a b');
    });

    test('截断到 120 个代码点（按代码点而非 UTF-16 单元）', () {
      final long = 'a' * 200;
      expect(normalizeLiveDanmakuText(long).length, maxLiveDanmakuCodePoints);

      // emoji 是补充平面字符（2 个 UTF-16 单元）：按代码点截断不应把一个
      // emoji 劈成半个代理对（否则渲染出乱码方块）。
      final emojis = '😀' * 200;
      final truncated = normalizeLiveDanmakuText(emojis);
      expect(truncated.runes.length, maxLiveDanmakuCodePoints);
      expect(truncated.runes.every((rune) => rune == 0x1F600), isTrue);
      // UTF-16 长度是代码点的两倍，证明截断按代码点计算。
      expect(truncated.length, maxLiveDanmakuCodePoints * 2);
    });
  });

  group('重连退避策略（对齐 Android LiveDanmakuRetryPolicy）', () {
    test('退避随尝试次数增长并有上限 30s', () {
      // randomUnit=0 取下界（= MIN_DELAY_MS），randomUnit 接近 1 取上界。
      for (var attempt = 0; attempt < 8; attempt++) {
        final low = LiveDanmakuRetryPolicy.nextDelayMs(attempt, 0.0);
        final high = LiveDanmakuRetryPolicy.nextDelayMs(attempt, 0.999999);
        expect(low, LiveDanmakuRetryPolicy.minDelayMs);
        expect(high, greaterThanOrEqualTo(low));
        expect(high, lessThanOrEqualTo(LiveDanmakuRetryPolicy.maxDelayMs));
      }
      // 高尝试次数被 clamp 到上限。
      expect(
        LiveDanmakuRetryPolicy.nextDelayMs(999, 0.999999),
        lessThanOrEqualTo(LiveDanmakuRetryPolicy.maxDelayMs),
      );
    });

    test('退避窗口按 2^attempt 增长（1s/2s/4s…）', () {
      // attempt=3 → cap = 8s，取满抖动应接近 8s。
      final delay = LiveDanmakuRetryPolicy.nextDelayMs(3, 0.999999);
      expect(delay, greaterThan(7000));
      expect(delay, lessThanOrEqualTo(8000));
      // attempt=0 → cap = 1s。
      expect(LiveDanmakuRetryPolicy.nextDelayMs(0, 0.999999),
          lessThanOrEqualTo(1000));
    });

    test('关闭码：1001/1006/1011/1012/1013 可重试，1000/1008 不重试', () {
      for (final code in [1001, 1006, 1011, 1012, 1013]) {
        expect(LiveDanmakuRetryPolicy.shouldRetryClose(code), isTrue,
            reason: 'close=$code 应可重试');
      }
      for (final code in [1000, 1002, 1003, 1008, 1015]) {
        expect(LiveDanmakuRetryPolicy.shouldRetryClose(code), isFalse,
            reason: 'close=$code 不应重试');
      }
    });

    test('失败判定：客户端错误不重试，网络/5xx/429 重试', () {
      // 鉴权与不存在类错误不重试（重试也不会变好）。
      for (final code in [400, 401, 403, 404, 410, 422]) {
        expect(
          LiveDanmakuRetryPolicy.shouldRetryFailure(httpCode: code),
          isFalse,
          reason: 'http=$code 不应重试',
        );
      }
      // 限流与服务端错误重试。
      expect(LiveDanmakuRetryPolicy.shouldRetryFailure(httpCode: 429), isTrue);
      expect(LiveDanmakuRetryPolicy.shouldRetryFailure(httpCode: 500), isTrue);
      expect(LiveDanmakuRetryPolicy.shouldRetryFailure(httpCode: 503), isTrue);
      // 网络层失败重试。
      expect(
        LiveDanmakuRetryPolicy.shouldRetryFailure(networkFailure: true),
        isTrue,
      );
      // 无信息的失败不重试（避免无意义重连风暴）。
      expect(LiveDanmakuRetryPolicy.shouldRetryFailure(), isFalse);
    });
  });
}
