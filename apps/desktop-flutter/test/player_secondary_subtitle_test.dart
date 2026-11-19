/// 次字幕（`secondary-sid`）的落盘与写入通道（迭代 3-A）。
///
/// 锁三件事：
/// 1. `PlayerOptions.secondarySubtitleId`：缺键即「关闭」（老配置向后兼容）、
///    落盘往返、白名单不认的脏值回落「关闭」而不是留在内存里假装生效；
/// 2. 主次同轨的回落：判定在 core（`normalizeSecondarySubtitleId`），
///    `withSecondarySubtitle` 只是把它接到 `copyWith` 上；
/// 3. 写入通道 [writeMpvPropertyValue]：写下去的是**白名单过滤后**的值，
///    回读不匹配/写入抛错/回读抛错都降级成 `applied: false`，**不抛**给 UI。
///
/// 第 3 条为什么测顶层函数而不是 `PlayerController.selectSecondarySubtitle`：
/// 控制器的构造要 MediaKit 内核（`flutter test` 默认没有 libmpv），而这里要断言
/// 的正是编排本身——过滤、写入、回读判定、失败降级。控制器只做「取主字幕 id →
/// 调 core 归一 → 取 platform → 调这个函数 → 记 rejection」，手法与
/// `player_offset_ui_test.dart` 的偏移路径完全一致。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_options.dart';
import 'package:webhtv_pc/core/player_tracks.dart';
import 'package:webhtv_pc/ui/player_controller.dart';

void main() {
  group('次字幕落盘（PlayerOptions）', () {
    test('缺键即关闭：老 settings.json 读出来不会突然开双字幕', () {
      expect(
        PlayerOptions.fromJson(<String, Object?>{'cache': false})
            .secondarySubtitleId,
        'no',
      );
      expect(PlayerOptions.fromJson(null).secondarySubtitleId, 'no');
      expect(const PlayerOptions.defaults().secondarySubtitleId, 'no');
    });

    test('落盘往返：auto 与轨道号原样读回', () {
      for (final id in <String>['auto', '2', '12']) {
        final options = const PlayerOptions().copyWith(
          secondarySubtitleId: id,
        );
        expect(options.toJson()['secondarySubtitleId'], id);
        expect(PlayerOptions.fromJson(options.toJson()), options);
        expect(
          PlayerOptions.fromJson(options.toJson()).secondarySubtitleId,
          id,
        );
      }
    });

    test('脏值回落关闭：白名单不认的形态一个都留不下来', () {
      for (final value in <Object?>[
        'embedded:1',
        '0',
        'srt.srt',
        'sid=2',
        2,
        '',
        '  ',
      ]) {
        expect(
          PlayerOptions.fromJson(<String, Object?>{
            'secondarySubtitleId': value,
          }).secondarySubtitleId,
          'no',
          reason: 'secondarySubtitleId=$value 应回落关闭',
        );
      }
      expect(
        const PlayerOptions(
          secondarySubtitleId: 'embedded:1',
        ).normalized().secondarySubtitleId,
        'no',
      );
    });

    test('主次同轨在 core 回落：withSecondarySubtitle 不写同一条', () {
      const base = PlayerOptions(secondarySubtitleId: '2');
      expect(
        base.withSecondarySubtitle(id: '2', primaryId: '2').secondarySubtitleId,
        'no',
      );
      expect(
        base.withSecondarySubtitle(id: '2', primaryId: '1').secondarySubtitleId,
        '2',
      );
      expect(
        base.withSecondarySubtitle(id: 'auto').secondarySubtitleId,
        'auto',
      );
      expect(
        base
            .withSecondarySubtitle(id: 'embedded:1', primaryId: '1')
            .secondarySubtitleId,
        'no',
        reason: '菜单 id 带前缀，写内核非法，回落关闭而不是写个脏值',
      );
      expect(
        base.withSecondarySubtitle(id: '', primaryId: '1').secondarySubtitleId,
        'no',
      );
    });
  });

  group('写入通道（白名单 + 回读降级，永不抛）', () {
    test('白名单过滤：非法值不写内核，原因可读', () async {
      for (final value in <String>['embedded:1', '0', 'sid=2', '']) {
        final written = <String, String>{};
        final result = await writeMpvPropertyValue(
          key: 'secondary-sid',
          value: value,
          setProperty: (key, value) async => written[key] = value,
          getProperty: (key) async => 'no',
        );
        expect(result.applied, isFalse, reason: 'secondary-sid=$value 不该生效');
        expect(result.rejection, isNotNull);
        expect(result.rejection!.key, 'secondary-sid');
        expect(result.rejection!.reason, contains('轨道号'));
        expect(written, isEmpty, reason: '被拒的值一个都不该到内核');
      }
    });

    test('写下去的就是白名单放行的那一个值，回读一致即生效', () async {
      final written = <String, String>{};
      final result = await writeMpvPropertyValue(
        key: 'secondary-sid',
        value: '2',
        setProperty: (key, value) async => written[key] = value,
        getProperty: (key) async => '2',
      );
      expect(result.applied, isTrue);
      expect(result.rejection, isNull);
      expect(written, <String, String>{'secondary-sid': '2'});
    });

    test('回读不匹配：降级为 false + 可读原因，不抛', () async {
      final result = await writeMpvPropertyValue(
        key: 'secondary-sid',
        value: '2',
        setProperty: (key, value) async {},
        getProperty: (key) async => 'no',
      );
      expect(result.applied, isFalse);
      expect(result.rejection!.key, 'secondary-sid');
      expect(result.rejection!.value, '2');
      expect(result.rejection!.reason, contains('回读'));
      expect(result.rejection!.reason, contains('no'));
    });

    test('内核不支持（回读空串）：不抛，如实说「空」', () async {
      final result = await writeMpvPropertyValue(
        key: 'secondary-sid',
        value: 'no',
        setProperty: (key, value) async {},
        getProperty: (key) async => '',
      );
      expect(result.applied, isFalse);
      expect(result.rejection!.reason, contains('回读 空'));
      expect(result.rejection!.reason, isNot(contains('未接受写入（回读 ）')));
    });

    test('写入抛错不外抛：原因带原始错误', () async {
      final result = await writeMpvPropertyValue(
        key: 'secondary-sid',
        value: '2',
        setProperty: (key, value) async =>
            throw StateError('mpv: property not found'),
        getProperty: (key) async => '',
      );
      expect(result.applied, isFalse);
      expect(result.rejection!.reason, contains('写入失败'));
      expect(result.rejection!.reason, contains('mpv: property not found'));
    });

    test('回读抛错不外抛：原因带原始错误', () async {
      final result = await writeMpvPropertyValue(
        key: 'secondary-sid',
        value: '2',
        setProperty: (key, value) async {},
        getProperty: (key) async => throw StateError('getProperty failed'),
      );
      expect(result.applied, isFalse);
      expect(result.rejection!.reason, contains('回读失败'));
      expect(result.rejection!.reason, contains('getProperty failed'));
    });
  });

  group('主次同轨 → 写 no（控制器口径的最小取证）', () {
    test('归一之后写下去的是 no，回读 no 即生效', () async {
      final written = <String, String>{};
      final target = normalizeSecondarySubtitleId(
        selectedId: '2',
        primaryId: '2',
      );
      final result = await writeMpvPropertyValue(
        key: 'secondary-sid',
        value: target,
        setProperty: (key, value) async => written[key] = value,
        getProperty: (key) async => 'no',
      );
      expect(target, secondarySubtitleOffId);
      expect(result.applied, isTrue);
      expect(written, <String, String>{'secondary-sid': 'no'});
    });
  });
}
