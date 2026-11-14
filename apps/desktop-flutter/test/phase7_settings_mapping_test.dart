/// Phase 7 · 设置同步的逐键映射与回推保真（`docs/phase7/design/01` §5、`design/04` S23–S29）。
///
/// 本文件锁三类**纯逻辑**契约：
/// 1. 白名单扩展后的分区（`supported` / `unsupportedKeys` / `skippedKeys` 互斥）；
/// 2. `tmdb_config` / `ai_config` 的值是 **JSON 字符串**，必须解字符串再映射
///    （`design/00` §3.1 契约 11）——这是反向验证 #7 的靶子；
/// 3. 回推保真：`ai_config` 的 5 套提示词不得被 PC 的 6 字段覆盖抹掉。
///
/// **不得出现 `testWidgets`**（真实 I/O 用例会因 mock HTTP 拦截静默失效）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/android_sync.dart';
import 'package:webhtv_pc/core/ai_config.dart';

/// 安卓侧 `ai_config` 的真实形态（`design/01` §5.3）：
/// PC 理解的 6 个字段 + 5 套提示词 × 3 字段。
const _androidAiConfigJson = '''
{
  "enabled": true,
  "protocol": "openai_chat",
  "endpoint": "https://api.example.com/v1",
  "apiKey": "sk-android-key",
  "model": "gpt-4o-mini",
  "customUserAgent": "WebHTV/Android",
  "recommendPrompt": "推荐提示词",
  "recommendSystemPrompt": "推荐系统提示词",
  "recommendUserPrompt": "推荐用户提示词",
  "titlePrompt": "标题提示词",
  "titleSystemPrompt": "标题系统提示词",
  "titleUserPrompt": "标题用户提示词",
  "adPrompt": "去广提示词",
  "adSystemPrompt": "去广系统提示词",
  "adUserPrompt": "去广用户提示词"
}
''';

void main() {
  group('S28 · 白名单分区（design/01 §5.1/§5.2）', () {
    test('白名单含 Phase 5 的两个键（不得丢）', () {
      expect(pcSettingsWhitelist, contains('tmdb_enabled'));
      expect(pcSettingsWhitelist, contains('tmdb_config'));
    });

    test('白名单追加 AI 段四个键', () {
      for (final key in [
        'tmdb_model',
        'ai_config',
        'ai_title_extraction',
        'ai_ad_detection',
      ]) {
        expect(pcSettingsWhitelist, contains(key), reason: '缺 $key');
      }
    });

    test('ai_config 与 tmdb_config 同列含凭据项', () {
      expect(pcSensitiveSettingsKeys, contains('tmdb_config'));
      expect(pcSensitiveSettingsKeys, contains('ai_config'));
      // 三个「安卓有、PC 无」的标量键不含凭据。
      expect(pcSensitiveSettingsKeys, isNot(contains('tmdb_model')));
      expect(pcSensitiveSettingsKeys, isNot(contains('ai_title_extraction')));
      expect(pcSensitiveSettingsKeys, isNot(contains('ai_ad_detection')));
    });

    test('S28 · unsupportedKeys 与 skippedKeys 互斥', () {
      final settings = SyncSettings.fromBackup({
        'prefers': {
          'tmdb_enabled': true,
          'tmdb_model': 1,
          'ai_config': _androidAiConfigJson,
          'ai_title_extraction': true,
          'ai_ad_detection': false,
          'viewing_record_sync_enabled': true,
        },
      }, allowSensitive: true);

      // 落库的：PC 有对应语义的键。
      //
      // `ai_title_extraction` / `ai_ad_detection` 现在**真的**被消费
      // （迁移后 AI 片名与 AI 去广开关有实际业务接线），因此它们从
      // 「白名单内但不落库」升级为落库键，只剩 `tmdb_model` 仍是
      // 「安卓有、PC 无」。
      expect(settings.values.keys.toSet(), {
        'tmdb_enabled',
        'ai_config',
        'ai_title_extraction',
        'ai_ad_detection',
      });
      // 白名单内但 PC 仍不支持落库的。
      expect(settings.unsupportedKeys.toSet(), {'tmdb_model'});
      // 白名单外的。
      expect(settings.skippedKeys, ['viewing_record_sync_enabled']);

      // 互斥性：任一个键不能同时出现在两个集合里。
      final overlap = settings.unsupportedKeys
          .toSet()
          .intersection(settings.skippedKeys.toSet());
      expect(overlap, isEmpty);
      // 且 unsupportedKeys 里的键都不在 values 里（不落库）。
      for (final key in settings.unsupportedKeys) {
        expect(settings.values.containsKey(key), isFalse, reason: key);
      }
    });

    test('S29 · 含凭据项默认不参与（allowSensitive=false）', () {
      final settings = SyncSettings.fromBackup({
        'prefers': {
          'tmdb_enabled': true,
          'tmdb_config': '{"apiKey":"x"}',
          'ai_config': _androidAiConfigJson,
        },
      });

      expect(settings.values.containsKey('tmdb_config'), isFalse);
      expect(settings.values.containsKey('ai_config'), isFalse);
      // 两者都进 skippedKeys（未授权同步），而不是 unsupportedKeys。
      expect(settings.skippedKeys, containsAll(['tmdb_config', 'ai_config']));
      expect(settings.unsupportedKeys, isEmpty);
      expect(settings.sensitiveIncluded, isFalse);
      // 标量键仍参与。
      expect(settings.values['tmdb_enabled'], isTrue);
    });

    test('未授权时含凭据项不进 raw（不得被回推）', () {
      final settings = SyncSettings.fromBackup({
        'prefers': {'ai_config': _androidAiConfigJson},
      });
      expect(settings.raw.containsKey('ai_config'), isFalse);
    });

    test('已授权时 unsupportedKeys 的键进 raw（推送不丢）', () {
      final settings = SyncSettings.fromBackup({
        'prefers': {'tmdb_model': 2},
      }, allowSensitive: true);
      expect(settings.unsupportedKeys, ['tmdb_model']);
      expect(settings.raw['tmdb_model'], 2);
      expect(settings.values.containsKey('tmdb_model'), isFalse);
    });

    test('isEmpty 语义：只有 unsupported 键时不算空', () {
      final onlyUnsupported = SyncSettings.fromBackup({
        'prefers': {'tmdb_model': 1},
      }, allowSensitive: true);
      expect(onlyUnsupported.isEmpty, isFalse);
      expect(SyncSettings.empty().isEmpty, isTrue);
    });
  });

  group('S24/S25 · JSON 字符串解包（design/00 §3.1 契约 11，反向验证 #7 靶子）', () {
    test('字符串形态能被解开', () {
      final decoded = decodeAndroidJsonSetting('{"apiKey":"k","model":"m"}');
      expect(decoded, isNotNull);
      expect(decoded!['apiKey'], 'k');
      expect(decoded['model'], 'm');
    });

    test('已是对象时原样返回（兼容第三方服务端）', () {
      final decoded = decodeAndroidJsonSetting({'apiKey': 'k'});
      expect(decoded, {'apiKey': 'k'});
    });

    test('空串 / 非 JSON / 非对象 一律返回 null（不抛异常）', () {
      expect(decodeAndroidJsonSetting(''), isNull);
      expect(decodeAndroidJsonSetting('   '), isNull);
      expect(decodeAndroidJsonSetting('not json'), isNull);
      expect(decodeAndroidJsonSetting('[1,2]'), isNull);
      expect(decodeAndroidJsonSetting(null), isNull);
      expect(decodeAndroidJsonSetting(42), isNull);
    });

    test('S25 · ai_config 的 6 个字段被映射', () {
      const local = AiConfigLike(
        enabled: false,
        protocol: 'openai_responses',
        endpoint: '',
        apiKey: '',
        model: '',
        customUserAgent: '',
      );
      final mapped = mapAiConfigFromAndroid(_androidAiConfigJson, local: local);
      expect(mapped, isNotNull);
      expect(mapped!.enabled, isTrue);
      expect(mapped.protocol, 'openai_chat');
      expect(mapped.endpoint, 'https://api.example.com/v1');
      expect(mapped.apiKey, 'sk-android-key');
      expect(mapped.model, 'gpt-4o-mini');
      expect(mapped.customUserAgent, 'WebHTV/Android');
    });

    test('S25 · 协议别名 apiFormat / format 被接受', () {
      const local = AiConfigLike(
        enabled: false,
        protocol: 'openai_responses',
        endpoint: '',
        apiKey: '',
        model: '',
        customUserAgent: '',
      );
      expect(
        mapAiConfigFromAndroid('{"apiFormat":"anthropic_messages"}', local: local)!
            .protocol,
        'anthropic_messages',
      );
      expect(
        mapAiConfigFromAndroid('{"format":"gemini_native"}', local: local)!.protocol,
        'gemini_native',
      );
    });

    test('S25 · UA 别名 userAgent / ua 被接受', () {
      const local = AiConfigLike(
        enabled: false,
        protocol: 'openai_responses',
        endpoint: '',
        apiKey: '',
        model: '',
        customUserAgent: '',
      );
      expect(
        mapAiConfigFromAndroid('{"userAgent":"UA-1"}', local: local)!.customUserAgent,
        'UA-1',
      );
      expect(
        mapAiConfigFromAndroid('{"ua":"UA-2"}', local: local)!.customUserAgent,
        'UA-2',
      );
    });

    test('凭据为空时保留本地（清空可用凭据比不同步更糟）', () {
      const local = AiConfigLike(
        enabled: true,
        protocol: 'openai_chat',
        endpoint: 'https://local/v1',
        apiKey: 'sk-local-key',
        model: 'local-model',
        customUserAgent: '',
      );
      final mapped = mapAiConfigFromAndroid(
        '{"enabled":false,"apiKey":"","model":""}',
        local: local,
      )!;
      expect(mapped.apiKey, 'sk-local-key');
      expect(mapped.model, 'local-model');
      expect(mapped.endpoint, 'https://local/v1');
      // enabled 是显式布尔，直传（不保留本地）。
      expect(mapped.enabled, isFalse);
    });

    test('解不开时返回 null（调用方保留本地）', () {
      const local = AiConfigLike(
        enabled: true,
        protocol: 'openai_chat',
        endpoint: 'e',
        apiKey: 'k',
        model: 'm',
        customUserAgent: '',
      );
      expect(mapAiConfigFromAndroid('not json', local: local), isNull);
      expect(mapAiConfigFromAndroid(null, local: local), isNull);
    });

    test('反向验证 #7 靶子：当对象读会拿不到任何字段', () {
      // 若实现里不做 jsonDecode（把字符串当 Map 读），
      // 这里会得到全空 → 与「设置同步成功但什么都没变」的用户现象一致。
      final asObject = decodeAndroidJsonSetting(_androidAiConfigJson);
      expect(asObject, isNotNull);
      // 关键：解出来的 Map 里**没有** `apiKey` 之外的顶层字符串键形态。
      expect(asObject!['apiKey'], 'sk-android-key');
    });
  });

  group('S26/S27 · ai_config 回推保真（design/01 §5.3）', () {
    test('S26 · 安卓原值含 5 套提示词', () {
      final decoded = decodeAndroidJsonSetting(_androidAiConfigJson)!;
      for (final key in [
        'recommendPrompt',
        'recommendSystemPrompt',
        'recommendUserPrompt',
        'titlePrompt',
        'titleSystemPrompt',
        'titleUserPrompt',
        'adPrompt',
        'adSystemPrompt',
        'adUserPrompt',
      ]) {
        expect(decoded.containsKey(key), isTrue, reason: 'fixture 缺 $key');
      }
    });

    test('S27 · 回推不丢提示词，且 PC 字段被覆盖', () {
      const pc = AiConfigLike(
        enabled: false,
        protocol: 'anthropic_messages',
        endpoint: 'https://pc/v1',
        apiKey: 'sk-pc-key',
        model: 'pc-model',
        customUserAgent: 'WebHTV/PC',
      );
      final merged = mergeAiConfigForPush(
        androidRaw: _androidAiConfigJson,
        pcConfig: pc,
      );
      expect(merged, isNotNull);

      // PC 理解的 6 个字段被覆盖。
      expect(merged!['enabled'], isFalse);
      expect(merged['protocol'], 'anthropic_messages');
      expect(merged['endpoint'], 'https://pc/v1');
      expect(merged['apiKey'], 'sk-pc-key');
      expect(merged['model'], 'pc-model');
      expect(merged['customUserAgent'], 'WebHTV/PC');

      // 安卓的 5 套提示词**逐字节保留**。
      for (final key in [
        'recommendPrompt',
        'recommendSystemPrompt',
        'recommendUserPrompt',
        'titlePrompt',
        'titleSystemPrompt',
        'titleUserPrompt',
        'adPrompt',
        'adSystemPrompt',
        'adUserPrompt',
      ]) {
        expect(merged.containsKey(key), isTrue, reason: '回推丢了 $key');
      }
      expect(merged['recommendPrompt'], '推荐提示词');
      expect(merged['adSystemPrompt'], '去广系统提示词');
    });

    test('S27 · 回推结果可再被安卓解析（往返一致）', () {
      const pc = AiConfigLike(
        enabled: true,
        protocol: 'openai_chat',
        endpoint: 'https://pc/v1',
        apiKey: 'sk-pc',
        model: 'm',
        customUserAgent: '',
      );
      final merged = mergeAiConfigForPush(
        androidRaw: _androidAiConfigJson,
        pcConfig: pc,
      )!;
      // 序列化后再解，字段仍在。
      final roundTrip = decodeAndroidJsonSetting(jsonEncode(merged))!;
      expect(roundTrip['apiKey'], 'sk-pc');
      expect(roundTrip['recommendPrompt'], '推荐提示词');
    });

    test('没有安卓原值时返回 null（宁可不推，也不抹掉提示词）', () {
      const pc = AiConfigLike(
        enabled: true,
        protocol: 'openai_chat',
        endpoint: 'e',
        apiKey: 'k',
        model: 'm',
        customUserAgent: '',
      );
      expect(mergeAiConfigForPush(androidRaw: null, pcConfig: pc), isNull);
      expect(mergeAiConfigForPush(androidRaw: '', pcConfig: pc), isNull);
      expect(mergeAiConfigForPush(androidRaw: 'not json', pcConfig: pc), isNull);
    });
  });

  group('S23/S24 · TMDB 段映射（design/01 §5.2）', () {
    test('S24 · tmdb_config 是 JSON 字符串，解字符串后映射', () {
      final settings = SyncSettings.fromBackup({
        'prefers': {
          'tmdb_config': '{"apiKey":"tmdb-key","language":"zh-CN"}',
        },
      }, allowSensitive: true);
      // 解析阶段保留原字符串（不在这里解，落库时才解）。
      final raw = settings.values['tmdb_config'];
      expect(raw, isA<String>());
      final decoded = decodeAndroidJsonSetting(raw)!;
      expect(decoded['apiKey'], 'tmdb-key');
      expect(decoded['language'], 'zh-CN');
    });

    test('S23 · tmdb_enabled 是标量，直传', () {
      final settings = SyncSettings.fromBackup({
        'prefers': {'tmdb_enabled': true},
      });
      expect(settings.values['tmdb_enabled'], isTrue);
    });

    test('sensitiveIncluded 只在真的带上了凭据项时为真', () {
      final withCredential = SyncSettings.fromBackup({
        'prefers': {'tmdb_config': '{}'},
      }, allowSensitive: true);
      expect(withCredential.sensitiveIncluded, isTrue);

      final scalarOnly = SyncSettings.fromBackup({
        'prefers': {'tmdb_enabled': true},
      }, allowSensitive: true);
      expect(scalarOnly.sensitiveIncluded, isFalse);
    });
  });

  group('脱敏（design/02 §7）', () {
    test('describe 只报键名与数量，永不输出值', () {
      final settings = SyncSettings.fromBackup({
        'prefers': {
          'tmdb_config': '{"apiKey":"super-secret-key"}',
          'ai_config': _androidAiConfigJson,
          'tmdb_model': 1,
        },
      }, allowSensitive: true);

      final text = settings.describe();
      expect(text, contains('tmdb_config'));
      expect(text, contains('ai_config'));
      expect(text, contains('unsupported=tmdb_model'));
      // 凭据原文绝不能出现在描述里。
      expect(text, isNot(contains('super-secret-key')));
      expect(text, isNot(contains('sk-android-key')));
    });

    test('toJson 保留值（要同步），但 describe 不泄露', () {
      // 契约与 Phase 5 一致（`phase5_android_sync_test.dart` 已锁定）：
      // `toJson()` 是**数据载体**，值必须保留（否则没法同步）；
      // 只有 `describe()` 是**日志载体**，必须脱敏。
      // 因此这里的断言不是「toJson 不含凭据」，而是「两者职责不混」。
      final settings = SyncSettings.fromBackup({
        'prefers': {'ai_config': _androidAiConfigJson},
      }, allowSensitive: true);

      // 数据载体：值在，且新增的 unsupported 分区也在。
      final json = jsonEncode(settings.toJson());
      expect(json, contains('sk-android-key'), reason: '值必须保留才能同步');
      expect(json, contains('unsupported'));

      // 日志载体：绝不出现凭据原文。
      expect(settings.describe(), isNot(contains('sk-android-key')));
      expect(settings.describe(), isNot(contains('推荐提示词')));
    });
  });

  group('与 AiConfig 的字段对齐（design/01 §5.3）', () {
    test('AiConfigLike 覆盖 AiConfig 的全部字段', () {
      const config = AiConfig(
        enabled: true,
        protocol: 'openai_chat',
        endpoint: 'https://e/v1',
        apiKey: 'k',
        model: 'm',
        customUserAgent: 'ua',
      );
      // 逐字段构造视图：字段名必须一一对应，否则映射会静默丢字段。
      final view = AiConfigLike(
        enabled: config.enabled,
        protocol: config.protocol,
        endpoint: config.endpoint,
        apiKey: config.apiKey,
        model: config.model,
        customUserAgent: config.customUserAgent,
      );
      expect(view.enabled, config.enabled);
      expect(view.protocol, config.protocol);
      expect(view.endpoint, config.endpoint);
      expect(view.apiKey, config.apiKey);
      expect(view.model, config.model);
      expect(view.customUserAgent, config.customUserAgent);
    });

    test('映射结果可构造回 AiConfig 且字段不丢', () {
      const local = AiConfigLike(
        enabled: false,
        protocol: 'openai_responses',
        endpoint: '',
        apiKey: '',
        model: '',
        customUserAgent: '',
      );
      final mapped = mapAiConfigFromAndroid(_androidAiConfigJson, local: local)!;
      final config = AiConfig(
        enabled: mapped.enabled,
        protocol: mapped.protocol,
        endpoint: mapped.endpoint,
        apiKey: mapped.apiKey,
        model: mapped.model,
        customUserAgent: mapped.customUserAgent,
      );
      expect(config.enabled, isTrue);
      expect(config.protocol, 'openai_chat');
      expect(config.model, 'gpt-4o-mini');
      expect(config.isReady, isTrue);
    });
  });
}
