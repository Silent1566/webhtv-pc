/// 迭代 3-C：`failureFallback` 的默认值从 `line` 改成 `off` 的回归。
///
/// 两件事都必须同时成立，缺一条就是产品事故：
/// 1. **新用户/缺键** → `off`：默认不自动换线路、换解析源；
/// 2. **老配置显式存了 `line`** → 仍然 `line`：那是用户在设置页做过的选择，
///    升级不能静默把它关掉。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/playback_open_policy.dart';
import 'package:webhtv_pc/core/player_options.dart';

void main() {
  group('默认档 off', () {
    test('构造默认值与 defaults() 都是 off', () {
      expect(const PlayerOptions().failureFallback, PlayerFailureFallback.off);
      expect(
        PlayerOptions.defaults().failureFallback,
        PlayerFailureFallback.off,
      );
    });

    test('落盘也只写 off', () {
      expect(
        PlayerOptions.defaults().toJson()['failureFallback'],
        PlayerFailureFallback.off.id,
      );
    });

    test('默认策略不含回退：可回退的失败也不换地址', () {
      final policy = PlayerOptions.defaults().openPolicy;
      expect(policy.fallbackOnFailure, isFalse);
      expect(policy.allowsFallback(PlayerFailureKind.timeout), isFalse);
      expect(policy.allowsFallback(PlayerFailureKind.notFound), isFalse);
      // 原地重试不属于「回退」：超时/网络仍重试一次（接线前的既有行为）。
      expect(policy.shouldRetryInPlace(PlayerFailureKind.timeout), isTrue);
      expect(policy.shouldRetryInPlace(PlayerFailureKind.unsupportedFormat), isFalse);
    });
  });

  group('老配置：显式值不被改写', () {
    test('缺键（老配置从没存过）→ off', () {
      expect(
        PlayerOptions.fromJson(const <String, Object?>{}).failureFallback,
        PlayerFailureFallback.off,
      );
      // 只存了别的键的旧 settings.json 同样落到 off。
      expect(
        PlayerOptions.fromJson(const <String, Object?>{
          'hardwareDecoding': false,
          'autoNext': false,
        }).failureFallback,
        PlayerFailureFallback.off,
      );
    });

    test('显式 line 仍然是 line', () {
      expect(
        PlayerOptions.fromJson(const <String, Object?>{
          'failureFallback': 'line',
        }).failureFallback,
        PlayerFailureFallback.line,
      );
    });

    test('其余显式档位照旧', () {
      expect(
        PlayerOptions.fromJson(const <String, Object?>{
          'failureFallback': 'off',
        }).failureFallback,
        PlayerFailureFallback.off,
      );
      expect(
        PlayerOptions.fromJson(const <String, Object?>{
          'failureFallback': 'line_parse',
        }).failureFallback,
        PlayerFailureFallback.lineAndParse,
      );
      expect(
        PlayerOptions.fromJson(const <String, Object?>{
          'failureFallback': 'line_parse_source',
        }).failureFallback,
        PlayerFailureFallback.lineAndParseAndSource,
      );
      // 落盘标识的大小写/空白容错不受影响。
      expect(
        PlayerOptions.fromJson(const <String, Object?>{
          'failureFallback': '  LINE ',
        }).failureFallback,
        PlayerFailureFallback.line,
      );
    });

    test('无法识别的值按缺省 off 处理（脏值不等于用户开启过）', () {
      for (final raw in <Object?>['unknown', 'nonsense', 3, null, '']) {
        expect(
          PlayerOptions.fromJson(<String, Object?>{'failureFallback': raw})
              .failureFallback,
          PlayerFailureFallback.off,
          reason: '脏值 $raw 不得替用户打开自动回退',
        );
      }
    });

    test('显式 line 的策略照旧允许回退（可回退的失败才走阶梯）', () {
      final policy = PlayerOptions.fromJson(const <String, Object?>{
        'failureFallback': 'line',
      }).openPolicy;
      expect(policy.fallbackOnFailure, isTrue);
      expect(policy.allowsFallback(PlayerFailureKind.timeout), isTrue);
      expect(policy.allowsFallback(PlayerFailureKind.notFound), isTrue);
      // 不可回退的失败连策略这一层都过不去。
      expect(
        policy.allowsFallback(PlayerFailureKind.unsupportedFormat),
        isFalse,
      );
    });

    test('往返：显式 line 存下去读回来还是 line', () {
      const options = PlayerOptions(failureFallback: PlayerFailureFallback.line);
      final restored = PlayerOptions.fromJson(options.toJson());
      expect(restored.failureFallback, PlayerFailureFallback.line);
      expect(restored, options);
    });
  });
}
