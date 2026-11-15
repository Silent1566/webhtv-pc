import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/subtitle_settings.dart';

void main() {
  group('三源设置（计划 Task 1）', () {
    test('默认全关：三个内置源都不启用', () {
      final settings = SubtitleSettings();
      expect(settings.assrtToken, '');
      expect(settings.hasAssrt, isFalse);
      expect(settings.hasXunlei, isFalse);
      expect(settings.hasShooter, isFalse);
      expect(settings.hasAnyProvider, isFalse);
      expect(settings.disabledSourceIds, [
        'local',
        'http',
        'assrt',
        'xunlei',
        'shooter',
      ]);
    });

    test('序列化往返：新字段平铺在既有 subtitles 段内', () {
      final settings = SubtitleSettings(
        assrtToken: '  tok  ',
        xunleiEnabled: true,
        shooterEnabled: true,
      );
      final json = settings.toJson();
      expect(json['assrtToken'], 'tok');
      expect(json['xunleiEnabled'], true);
      expect(json['shooterEnabled'], true);

      final restored = SubtitleSettings.fromJson(
        jsonDecode(jsonEncode(json)),
      );
      // 字段在写盘时被 trim（与 httpEndpoint/httpToken 同口径），所以逐字段比，
      // 不要拿构造时的原始对象比相等。
      expect(restored.assrtToken, 'tok');
      expect(restored.xunleiEnabled, isTrue);
      expect(restored.shooterEnabled, isTrue);
      expect(restored.hasAnyProvider, isTrue);
    });

    test('默认值不写进 JSON：恢复默认后键消失', () {
      final json = SubtitleSettings().toJson();
      expect(json.containsKey('assrtToken'), isFalse);
      expect(json.containsKey('xunleiEnabled'), isFalse);
      expect(json.containsKey('shooterEnabled'), isFalse);
    });

    test('旧版本 JSON 缺新字段时回落默认，不抛', () {
      final restored = SubtitleSettings.fromJson({
        'autoMatch': true,
        'httpEndpoint': 'https://a.test/s',
      });
      expect(restored.hasHttpProvider, isTrue);
      expect(restored.hasXunlei, isFalse);
      expect(restored.hasShooter, isFalse);
      expect(restored.disabledSourceIds, isNot(contains('http')));
    });

    test('只开迅雷也算「有源」', () {
      expect(SubtitleSettings(xunleiEnabled: true).hasAnyProvider, isTrue);
      expect(SubtitleSettings(shooterEnabled: true).hasAnyProvider, isTrue);
      expect(SubtitleSettings(assrtToken: 't').hasAnyProvider, isTrue);
    });

    test('copyWith 只改指定字段', () {
      final base = SubtitleSettings(assrtToken: 't', xunleiEnabled: true);
      final next = base.copyWith(shooterEnabled: true);
      expect(next.assrtToken, 't');
      expect(next.xunleiEnabled, isTrue);
      expect(next.shooterEnabled, isTrue);
      expect(next.autoMatch, base.autoMatch);
      expect(next.preferredLanguages, base.preferredLanguages);
    });
  });
}
