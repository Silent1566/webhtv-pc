/// AI 配置模型与端点归一化（`docs/phase6/design/04` §3）。
///
/// 纯逻辑：不依赖 Flutter，也不发任何网络请求。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ai_config.dart';
import 'package:webhtv_pc/services/app_paths.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/services/ai_config_store.dart';
import 'package:webhtv_pc/state/app_state.dart';

void main() {
  group('协议常量', () {
    test('4 种协议与上游一致', () {
      expect(AiProtocol.values, [
        'openai_responses',
        'openai_chat',
        'anthropic_messages',
        'gemini_native',
      ]);
    });

    test('默认协议是 openai_responses', () {
      expect(AiProtocol.defaultProtocol, 'openai_responses');
    });

    test('默认端点按协议区分', () {
      expect(
        AiProtocol.defaultEndpoint('openai_responses'),
        'https://api.openai.com/v1/responses',
      );
      expect(
        AiProtocol.defaultEndpoint('openai_chat'),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(
        AiProtocol.defaultEndpoint('anthropic_messages'),
        'https://api.anthropic.com/v1/messages',
      );
      expect(
        AiProtocol.defaultEndpoint('gemini_native'),
        'https://generativelanguage.googleapis.com/v1beta',
      );
    });

    test('isSupported 只认 4 个值', () {
      expect(AiProtocol.isSupported('openai_chat'), isTrue);
      expect(AiProtocol.isSupported('OPENAI_CHAT'), isFalse);
      expect(AiProtocol.isSupported(null), isFalse);
      expect(AiProtocol.isSupported('nonsense'), isFalse);
    });
  });

  group('sanitized：归一化', () {
    test('非法协议回落默认', () {
      final config = const AiConfig(protocol: 'nonsense').sanitized();
      expect(config.protocol, AiProtocol.defaultProtocol);
    });

    test('端点为空时按协议填默认', () {
      final config = const AiConfig(protocol: 'openai_chat').sanitized();
      expect(config.endpoint, AiProtocol.defaultEndpoint('openai_chat'));
    });

    test('模型为空时填默认', () {
      final config = const AiConfig().sanitized();
      expect(config.model, AiProtocol.defaultModel);
    });

    test('apiKey 去空白', () {
      final config = const AiConfig(apiKey: '  sk-abc  ').sanitized();
      expect(config.apiKey, 'sk-abc');
    });

    test('已填的端点不被默认值覆盖', () {
      final config = const AiConfig(
        endpoint: 'https://api.deepseek.com/v1',
      ).sanitized();
      expect(config.endpoint, 'https://api.deepseek.com/v1');
    });
  });

  group('isReady / isModelFetchReady', () {
    test('未启用 → 未就绪', () {
      final config = const AiConfig(
        endpoint: 'https://x/v1',
        apiKey: 'k',
        model: 'm',
      ).sanitized();
      expect(config.isReady, isFalse);
    });

    test('缺 key → 未就绪', () {
      final config = const AiConfig(
        enabled: true,
        endpoint: 'https://x/v1',
        model: 'm',
      ).sanitized();
      expect(config.isReady, isFalse);
    });

    test('四项齐备 → 就绪', () {
      final config = const AiConfig(
        enabled: true,
        endpoint: 'https://x/v1',
        apiKey: 'k',
        model: 'm',
      ).sanitized();
      expect(config.isReady, isTrue);
    });

    test('拉模型列表不需要 model，但需要 key', () {
      final config = const AiConfig(
        endpoint: 'https://x/v1',
        apiKey: 'k',
      ).sanitized();
      expect(config.isModelFetchReady, isTrue);
      final noKey = const AiConfig(endpoint: 'https://x/v1').sanitized();
      expect(noKey.isModelFetchReady, isFalse);
    });

    // **锁住 `sanitized()` 与就绪判定的真实交互**（变异自检发现）：
    //
    // `isReady` 里对 `endpoint` / `model` 的非空检查是**永真**的——
    // 因为它先调 `sanitized()`，而 `sanitized()` 会按协议填默认端点、
    // 并填默认模型（`AiProtocol.defaultModel`），两者都不可能为空。
    // 因此 `isReady` 实际只取决于 `enabled` 与 `apiKey`（`isModelFetchReady`
    // 只取决于 `apiKey`）。
    //
    // 这条用例把「端点/模型留空也照样就绪」这个**真实语义**钉住：
    // 若将来有人改掉 `sanitized()` 的默认值填充，这条会失败并提醒他
    // 重新审查 `isReady`/`isModelFetchReady` 那两行永真条件。
    test('enabled+key 齐备但端点/模型留空 → 默认值填充后仍就绪', () {
      final config = const AiConfig(enabled: true, apiKey: 'k').sanitized();
      expect(config.endpoint, isNotEmpty, reason: 'sanitized 按协议填默认端点');
      expect(config.model, isNotEmpty, reason: 'sanitized 填默认模型');
      expect(
        config.isReady,
        isTrue,
        reason:
            '端点与模型都有默认值，用户只需 enabled + 填 key。'
            '这也意味着 isReady 里的 endpoint/model 非空检查是永真的。',
      );
      // 反过来：只有 enabled 没有 key 就不行（key 没有默认值）。
      expect(const AiConfig(enabled: true).sanitized().isReady, isFalse);
    });
  });

  group('cleanBaseEndpoint', () {
    test('去掉 query 与 fragment', () {
      expect(
        cleanBaseEndpoint('https://x/v1?a=1#frag'),
        'https://x/v1',
      );
    });

    test('去掉尾部斜杠', () {
      expect(cleanBaseEndpoint('https://x/v1///'), 'https://x/v1');
    });
  });

  group('completionUrl：端点归一化（§3.5）', () {
    test('openai_responses：基址补 /v1/responses', () {
      final config = const AiConfig(
        protocol: 'openai_responses',
        endpoint: 'https://api.openai.com',
      ).sanitized();
      expect(config.completionUrl, 'https://api.openai.com/v1/responses');
    });

    test('openai_responses：已是 /v1 只补路径段', () {
      final config = const AiConfig(
        protocol: 'openai_responses',
        endpoint: 'https://api.openai.com/v1',
      ).sanitized();
      expect(config.completionUrl, 'https://api.openai.com/v1/responses');
    });

    test('openai_responses：已是完整端点原样', () {
      final config = const AiConfig(
        protocol: 'openai_responses',
        endpoint: 'https://api.openai.com/v1/responses',
      ).sanitized();
      expect(config.completionUrl, 'https://api.openai.com/v1/responses');
    });

    test('openai_chat：补 chat/completions', () {
      final config = const AiConfig(
        protocol: 'openai_chat',
        endpoint: 'https://api.deepseek.com/v1',
      ).sanitized();
      expect(
        config.completionUrl,
        'https://api.deepseek.com/v1/chat/completions',
      );
    });

    test('anthropic_messages：补 messages', () {
      final config = const AiConfig(
        protocol: 'anthropic_messages',
        endpoint: 'https://api.anthropic.com/v1',
      ).sanitized();
      expect(config.completionUrl, 'https://api.anthropic.com/v1/messages');
    });

    test('gemini_native：补 /v1beta/models/<model>:generateContent', () {
      final config = const AiConfig(
        protocol: 'gemini_native',
        endpoint: 'https://generativelanguage.googleapis.com',
        model: 'gemini-2.0-flash',
      ).sanitized();
      expect(
        config.completionUrl,
        'https://generativelanguage.googleapis.com/v1beta/'
        'models/gemini-2.0-flash:generateContent',
      );
    });

    test('gemini_native：端点已含 :generateContent 原样', () {
      const url =
          'https://x/v1beta/models/gemini-2.0-flash:generateContent';
      final config = const AiConfig(
        protocol: 'gemini_native',
        endpoint: url,
      ).sanitized();
      expect(config.completionUrl, url);
    });

    test('gemini_native：端点以 /models 结尾只补模型段', () {
      final config = const AiConfig(
        protocol: 'gemini_native',
        endpoint: 'https://x/v1beta/models',
        model: 'gemini-2.0-flash',
      ).sanitized();
      expect(
        config.completionUrl,
        'https://x/v1beta/models/gemini-2.0-flash:generateContent',
      );
    });

    test('model 带 models/ 前缀时不重复', () {
      final config = const AiConfig(
        protocol: 'gemini_native',
        endpoint: 'https://x',
        model: 'models/gemini-2.0-flash',
      ).sanitized();
      expect(
        config.completionUrl,
        'https://x/v1beta/models/gemini-2.0-flash:generateContent',
      );
    });
  });

  group('脱敏', () {
    test('redactedApiKey 不含完整 key', () {
      final config = const AiConfig(apiKey: 'sk-1234567890abcdef').sanitized();
      expect(config.redactedApiKey, isNot(contains('1234567890abcdef')));
    });

    test('toJson 保留原 key（落盘需要），但 redactedApiKey 用于展示', () {
      final config = const AiConfig(apiKey: 'sk-abc').sanitized();
      expect(config.toJson()['apiKey'], 'sk-abc');
      expect(config.redactedApiKey, isNot('sk-abc'));
    });
  });

  group('fromJson 往返', () {
    test('缺字段用默认', () {
      final config = AiConfig.fromJson(const {});
      expect(config.protocol, AiProtocol.defaultProtocol);
      expect(config.enabled, isFalse);
    });

    test('完整往返', () {
      const original = AiConfig(
        enabled: true,
        protocol: 'anthropic_messages',
        endpoint: 'https://api.anthropic.com/v1',
        apiKey: 'sk-x',
        model: 'claude-3-5-sonnet',
        customUserAgent: 'MyUA/1.0',
      );
      final restored = AiConfig.fromJson(original.toJson());
      expect(restored.enabled, original.enabled);
      expect(restored.protocol, original.protocol);
      expect(restored.endpoint, original.endpoint);
      expect(restored.apiKey, original.apiKey);
      expect(restored.model, original.model);
      expect(restored.customUserAgent, original.customUserAgent);
    });

    test('非法类型不抛异常', () {
      final config = AiConfig.fromJson(const {
        'enabled': 'yes',
        'protocol': 42,
        'apiKey': ['x'],
      });
      expect(config.enabled, isFalse);
      expect(config.protocol, AiProtocol.defaultProtocol);
      expect(config.apiKey, '');
    });
  });

  group('AiConfigStore：settings.json 的 ai 段（§4）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-ai-store');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    String pathOf() => p.join(dir.path, 'settings.json');

    test('文件不存在时用默认配置，不抛异常', () async {
      final store = AiConfigStore(path: pathOf());
      await store.load();
      expect(store.config.protocol, AiProtocol.defaultProtocol);
      expect(store.config.enabled, isFalse);
      expect(store.loaded, isTrue);
    });

    test('保存后可重新读回', () async {
      final store = AiConfigStore(path: pathOf());
      await store.load();
      await store.save(
        const AiConfig(
          enabled: true,
          protocol: 'openai_chat',
          endpoint: 'https://api.deepseek.com/v1',
          apiKey: 'sk-abc',
          model: 'deepseek-chat',
        ),
      );

      final again = AiConfigStore(path: pathOf());
      await again.load();
      expect(again.config.enabled, isTrue);
      expect(again.config.protocol, 'openai_chat');
      expect(again.config.apiKey, 'sk-abc');
      expect(again.config.model, 'deepseek-chat');
    });

    test('不污染其他段', () async {
      final file = File(pathOf());
      await file.writeAsString(
        '{"ui":{"themeMode":"light"},"tmdb":{"enabled":true},'
        '"sync":{"serverEnabled":true}}',
      );
      final store = AiConfigStore(path: pathOf());
      await store.load();
      await store.save(const AiConfig(enabled: true, apiKey: 'k'));

      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      expect(raw.containsKey('ai'), isTrue);
      expect((raw['ui']! as Map)['themeMode'], 'light');
      expect(raw.containsKey('tmdb'), isTrue);
      expect(raw.containsKey('sync'), isTrue);
    });

    test('文件损坏时不抛异常，回落默认', () async {
      final file = File(pathOf());
      await file.writeAsString('{ not json');
      final store = AiConfigStore(path: pathOf());
      await store.load();
      expect(store.config.protocol, AiProtocol.defaultProtocol);
    });

    test('连续两次保存都生效（串行化写盘）', () async {
      final store = AiConfigStore(path: pathOf());
      await store.load();
      // **两次 save 必须都返回 true**：并行写盘没有队列时，两个 `_doPersist`
      // 会在同一个 `.tmp` 上互踩（Windows 上 delete/rename 原子性差），
      // 其中一个会失败。原断言只检查「文件里有 k1 或 k2」，
      // 即使**只有一个成功**也绿——变异自检抓到的缺口。
      final results = await Future.wait([
        store.save(const AiConfig(apiKey: 'k1')),
        store.save(const AiConfig(apiKey: 'k2')),
      ]);
      expect(
        results,
        everyElement(isTrue),
        reason: '串行化后两次写盘都应成功（无队列时并发会互相踩 .tmp）',
      );
      // 且落盘结果必须是**一份可解析的完整 JSON**（不是两个半截文件）。
      final raw = jsonDecode(await File(pathOf()).readAsString());
      expect(raw, isA<Map<String, Object?>>());
      final ai = (raw as Map<String, Object?>)['ai']! as Map;
      expect(ai['apiKey'], anyOf('k1', 'k2'), reason: '最后一次写盘胜出');

      final again = AiConfigStore(path: pathOf());
      await again.load();
      expect(again.config.apiKey, isNotEmpty);
      expect(again.config.apiKey, anyOf('k1', 'k2'));
    });

    // `save` 必须把配置归一化后再落盘（与 `load` 同一口径）。
    //
    // **必须直接读原始 JSON**：`AiConfig.fromJson` 末尾会调 `sanitized()`，
    // 因此「save → 新建 store 读回」这条路经会把脏值屏蔽掉，
    // 测不出 `save` 是否归一化（变异 M1 正是这样存活的）。
    test('save 落盘前归一化（非法协议不写入磁盘）', () async {
      final store = AiConfigStore(path: pathOf());
      await store.load();
      await store.save(
        const AiConfig(enabled: true, protocol: 'nonsense', apiKey: 'k'),
      );

      final raw = jsonDecode(await File(pathOf()).readAsString())
          as Map<String, Object?>;
      final ai = (raw['ai']! as Map).cast<String, Object?>();
      expect(
        ai['protocol'],
        AiProtocol.defaultProtocol,
        reason: '磁盘上的值必须已归一化（否则旧值会被写进 settings.json）',
      );
    });

    // 同理：空端点/空模型也必须在落盘前就被默认值填上。
    test('save 落盘前把空端点与空模型填成默认值', () async {
      final store = AiConfigStore(path: pathOf());
      await store.load();
      await store.save(const AiConfig(enabled: true, apiKey: 'k'));

      final raw = jsonDecode(await File(pathOf()).readAsString())
          as Map<String, Object?>;
      final ai = (raw['ai']! as Map).cast<String, Object?>();
      expect(ai['endpoint'], isNotEmpty);
      expect(ai['model'], AiProtocol.defaultModel);
    });

    // 旧文件损坏时**不得**把损坏内容带进新文件（否则整份 settings.json 失效）。
    test('旧文件损坏时保存会覆盖它，不让损坏内容扩散', () async {
      final file = File(pathOf());
      await file.writeAsString('{ not json');
      final store = AiConfigStore(path: pathOf());
      await store.load();
      await store.save(const AiConfig(enabled: true, apiKey: 'k'));

      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      expect(raw.containsKey('ai'), isTrue);
      expect(
        (raw['ai']! as Map)['apiKey'],
        'k',
        reason: '保存后必须是一份可解析的新文件',
      );
    });

    // 写盘是「写 tmp → 删旧 → 改名」三步，因此磁盘上不得残留 `.tmp`。
    test('保存后不残留 .tmp 临时文件', () async {
      final store = AiConfigStore(path: pathOf());
      await store.load();
      await store.save(const AiConfig(enabled: true, apiKey: 'k'));

      expect(
        File('${pathOf()}.tmp').existsSync(),
        isFalse,
        reason: '临时文件必须已被 rename 掉',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // AppState 接线（`docs/phase6/design/04` §4、§7）
  //
  // 本文件**没有** `testWidgets`，因此可以放心做真实文件 I/O
  // （与 `phase2_last_site_test` 同一约定）。
  // ---------------------------------------------------------------------------
  group('AppState 接线（§4）', () {
    late Directory dir;
    late AppPaths paths;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('webhtv-ai-appstate');
      paths = AppPaths.resolve(
        overrides: {
          'config': '${dir.path}/webhtv-pc',
          'data': '${dir.path}/webhtv-pc',
          'cache': '${dir.path}/webhtv-pc/cache',
          'state': '${dir.path}/webhtv-pc/logs',
        },
      );
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    /// 不调 `bootstrap`（它会开数据库与日志）；只装配 AI store，
    /// 与 `attachUiPreferences` 同一模式。
    Future<AppState> build() async {
      final state = AppState(paths: paths, log: LogService());
      final store = AiConfigStore(path: paths.settingsPath, log: state.log);
      await store.load();
      state.attachAiConfigStore(store);
      return state;
    }

    test('aiConfig 暴露 store 的值', () async {
      final state = await build();
      addTearDown(state.dispose);
      expect(state.aiConfig.protocol, AiProtocol.defaultProtocol);
      expect(state.aiConfig.enabled, isFalse);
    });

    test('saveAiConfig 真的落盘（同一份 settings.json）', () async {
      final state = await build();
      addTearDown(state.dispose);
      final ok = await state.saveAiConfig(
        const AiConfig(enabled: true, apiKey: 'sk-live'),
      );
      expect(ok, isTrue, reason: '保存应当成功');
      expect(state.aiConfig.enabled, isTrue);
      expect(state.aiConfig.apiKey, 'sk-live');

      // 同一路径新建 store → 读回（证明真的写了磁盘，不是只改内存）。
      final again = AiConfigStore(path: paths.settingsPath);
      await again.load();
      expect(again.config.apiKey, 'sk-live');
      expect(again.config.enabled, isTrue);
    });

    test('saveAiConfig 通知监听者（UI 必须立刻重建）', () async {
      final state = await build();
      addTearDown(state.dispose);
      var notified = 0;
      state.addListener(() => notified++);

      await state.saveAiConfig(const AiConfig(enabled: true, apiKey: 'k'));
      expect(notified, greaterThan(0));
    });

    test('saveAiConfig 后 getter 已是新值（通知时读到的是新值而非旧值）', () async {
      final state = await build();
      addTearDown(state.dispose);
      String? seenDuringNotify;
      state.addListener(() => seenDuringNotify = state.aiConfig.apiKey);

      await state.saveAiConfig(const AiConfig(enabled: true, apiKey: 'k-new'));
      expect(
        seenDuringNotify,
        'k-new',
        reason: 'store 的内存值在 notifyListeners 之前已更新（否则 UI 用旧值重建）',
      );
    });
  });
}
