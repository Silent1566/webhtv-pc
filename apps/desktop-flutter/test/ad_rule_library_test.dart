/// 本地用户广告规则库：落盘、导入去重、导出往返、生效规则合并。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/core/ad_rule_library.dart';
import 'package:webhtv_pc/core/ad_rules.dart';
import 'package:webhtv_pc/core/protocol.dart';
import 'package:webhtv_pc/services/log_service.dart';
import 'package:webhtv_pc/ui/ad_rule_library_page.dart';

/// 一条能用的小规则（有 hostSuffixes 信号，能过 HlsAdRule.listFrom）。
Map<String, Object?> hlsRule({
  String id = 'rule-1',
  String host = 'ad.example.com',
}) => <String, Object?>{
  'id': id,
  'hostSuffixes': <String>[host],
};

AdRuleEntry makeEntry(
  String id, {
  bool enabled = true,
  List<String> ads = const <String>[],
  List<Map<String, Object?>> rules = const <Map<String, Object?>>[],
}) => AdRuleEntry(
  id: id,
  name: id.toUpperCase(),
  enabled: enabled,
  ads: ads,
  hlsRules: rules,
  createdAt: 100,
  updatedAt: 100,
);

void main() {
  late Directory tempDir;
  late String path;
  late LogService log;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('webhtv-ad-rules-');
    path = p.join(tempDir.path, 'ad_rule_library.json');
    log = LogService();
  });

  tearDown(() async {
    await log.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String rawText() => File(path).readAsStringSync();

  test('新建一条规则后按 version 1 落盘，重开仍在', () {
    final store = AdRuleLibraryStore(path: path, log: log);
    expect(store.entries, isEmpty);
    expect(store.add(makeEntry('a', ads: <String>['a.com'])), isTrue);

    final decoded = jsonDecode(rawText()) as Map<String, Object?>;
    expect(decoded['version'], 1);
    final reopened = AdRuleLibraryStore(path: path, log: log);
    expect(reopened.loadError, isNull);
    expect(reopened.entries.single.id, 'a');
    expect(reopened.entries.single.ads, <String>['a.com']);
  });

  test('add 同 id 幂等覆盖，不同 id 追加', () {
    final store = AdRuleLibraryStore(path: path, log: log);
    expect(store.add(makeEntry('a', ads: <String>['first.com'])), isTrue);
    expect(store.add(makeEntry('a', ads: <String>['second.com'])), isTrue);
    expect(store.entries.length, 1);
    expect(store.entries.single.ads, <String>['second.com']);

    expect(store.add(makeEntry('b')), isTrue);
    expect(store.entries.map((entry) => entry.id), <String>['a', 'b']);
    // 幂等不是只体现在内存：磁盘上也不能变成两条。
    expect(
      AdRuleLibraryStore(path: path, log: log).entries.map((e) => e.id),
      <String>['a', 'b'],
    );
  });

  test('update 只覆盖已存在的 id，不存在返回 false', () {
    final store = AdRuleLibraryStore(path: path, log: log);
    store.add(makeEntry('a', ads: <String>['old.com']));
    expect(store.update(makeEntry('missing')), isFalse);
    expect(store.entries.length, 1);

    expect(store.update(makeEntry('a', ads: <String>['new.com'])), isTrue);
    expect(store.entries.single.ads, <String>['new.com']);
    expect(
      AdRuleLibraryStore(path: path, log: log).entries.single.ads,
      <String>['new.com'],
    );
  });

  test('remove 删除指定 id，重复删除返回 false', () {
    final store = AdRuleLibraryStore(path: path, log: log);
    store
      ..add(makeEntry('a'))
      ..add(makeEntry('b'));
    expect(store.remove('a'), isTrue);
    expect(store.entries.map((entry) => entry.id), <String>['b']);
    expect(store.remove('a'), isFalse);
    expect(
      AdRuleLibraryStore(path: path, log: log).entries.map((e) => e.id),
      <String>['b'],
    );
  });

  test('setEnabled 持久化开关，未知 id 返回 false', () {
    final store = AdRuleLibraryStore(path: path, log: log);
    store.add(makeEntry('a'));
    expect(store.setEnabled('missing', false), isFalse);
    expect(store.setEnabled('a', false), isTrue);
    expect(store.entries.single.enabled, isFalse);
    expect(
      AdRuleLibraryStore(path: path, log: log).entries.single.enabled,
      isFalse,
    );
  });

  test('文件损坏时降级为空库并给出 loadError，不覆盖原文件', () {
    File(path).writeAsStringSync('{ this is not json');
    final store = AdRuleLibraryStore(path: path, log: log);
    expect(store.entries, isEmpty);
    expect(store.loadError, isNotNull);
    // 只读降级：构造函数不该顺手把坏文件重写成空库。
    expect(rawText(), '{ this is not json');
  });

  test('版本不认识时按空库处理', () {
    File(path).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'version': 999,
        'entries': [makeEntry('a').toJson()],
      }),
    );
    final store = AdRuleLibraryStore(path: path, log: log);
    expect(store.entries, isEmpty);
    expect(store.loadError, contains('版本'));
  });

  test('add 缺 id 之类的脏记录不会被当成有效记录读回', () {
    File(path).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'version': 1,
        'entries': [
          <String, Object?>{'name': '没有 id'},
          makeEntry('a').toJson(),
        ],
      }),
    );
    final store = AdRuleLibraryStore(path: path, log: log);
    expect(store.entries.map((entry) => entry.id), <String>['a']);
    expect(store.loadError, contains('无法识别'));
  });

  test('导入接受 entries 包裹、数组与单条对象三种顶层形态', () {
    final store = AdRuleLibraryStore(path: path, log: log);
    final wrapped = store.importJson(
      jsonEncode(<String, Object?>{
        'entries': [makeEntry('a').toJson()],
      }),
      source: kAdRuleSourceImported,
    );
    expect(wrapped.added, 1);
    expect(wrapped.rejected, 0);

    final list = store.importJson(
      jsonEncode(<Object?>[
        makeEntry('b', ads: <String>['b.com']).toJson(),
      ]),
      source: kAdRuleSourceImported,
    );
    expect(list.added, 1);

    final single = store.importJson(
      jsonEncode(makeEntry('c', ads: <String>['c.com']).toJson()),
      source: kAdRuleSourceImported,
    );
    expect(single.added, 1);
    expect(store.entries.map((entry) => entry.id), <String>['a', 'b', 'c']);
    expect(store.entries.every((entry) => entry.source == 'imported'), isTrue);
  });

  test('导入去重：同 ads + 同规则视为同一条，更新而不是追加', () {
    final store = AdRuleLibraryStore(path: path, log: log);
    store.add(
      makeEntry(
        'a',
        ads: <String>['b.com', 'a.com'],
        rules: <Map<String, Object?>>[hlsRule()],
      ),
    );
    // ads 顺序不同、规则字段顺序不同，但语义相同 -> 同一条。
    final report = store.importJson(
      jsonEncode(<String, Object?>{
        'entries': [
          <String, Object?>{
            'id': 'other-id',
            'name': '导入的',
            'ads': <String>['a.com', 'B.com'],
            'hlsRules': <Object?>[
              <String, Object?>{
                'hostSuffixes': <String>['ad.example.com'],
                'id': 'rule-1',
              },
            ],
          },
        ],
      }),
      source: kAdRuleSourceImported,
    );
    expect(report.added, 0);
    expect(report.updated, 1);
    expect(report.reasons, isEmpty);
    expect(store.entries.length, 1);
    // 去重命中时保留既有 id（身份），只换内容。
    expect(store.entries.single.id, 'a');
    expect(store.entries.single.name, '导入的');
  });

  test('导入把非法 hlsRules 计入 rejected 并写明原因', () {
    final store = AdRuleLibraryStore(path: path, log: log);
    final report = store.importJson(
      jsonEncode(<String, Object?>{
        'entries': [
          <String, Object?>{
            'id': 'a',
            'ads': <String>['a.com'],
            'hlsRules': <Object?>[
              hlsRule(),
              <String, Object?>{'id': 'empty', 'hostSuffixes': <String>[]},
              <String, Object?>{
                'id': 'bad',
                'segmentUrlRegex': <String>['(.*.*)'],
              },
              'not-an-object',
            ],
          },
        ],
      }),
      source: kAdRuleSourceImported,
    );
    expect(report.added, 1);
    expect(report.rejected, 3);
    expect(report.reasons.length, 3);
    expect(
      report.reasons.any((reason) => reason.contains('没有任何可用的分片信号')),
      isTrue,
    );
    expect(
      report.reasons.any((reason) => reason.contains('无法安全编译的正则')),
      isTrue,
    );
    expect(report.reasons.any((reason) => reason.contains('不是对象')), isTrue);
    // 留下来的只有能用那条：非法规则不能被静默留在库里去滥杀分片。
    expect(store.entries.single.hlsRules.length, 1);
    expect(store.entries.single.hlsRules.single['id'], 'rule-1');
  });

  test('导入缺 id 的条目与非法 JSON 都被拒绝并说明', () {
    final store = AdRuleLibraryStore(path: path, log: log);
    final noId = store.importJson(
      jsonEncode(<Object?>[
        <String, Object?>{
          'name': '匿名',
          'ads': <String>['a.com'],
        },
      ]),
      source: kAdRuleSourceImported,
    );
    expect(noId.added, 0);
    expect(noId.rejected, 1);
    expect(noId.reasons.single, contains('缺少 id'));

    final broken = store.importJson('{ nope', source: kAdRuleSourceImported);
    expect(broken.rejected, 1);
    expect(broken.reasons.single, contains('不是合法 JSON'));

    final wrongShape = store.importJson(
      jsonEncode(<String, Object?>{'foo': 1}),
      source: kAdRuleSourceImported,
    );
    expect(wrongShape.rejected, 1);
    expect(store.entries, isEmpty);
  });

  test('导出可再导入，且第二次导入收敛（往返一致）', () {
    final source = AdRuleLibraryStore(path: path, log: log);
    source.add(
      makeEntry(
        'a',
        ads: <String>['a.com'],
        rules: <Map<String, Object?>>[hlsRule()],
      ),
    );
    source.add(makeEntry('b', ads: <String>['b.com']));
    final exported = source.exportJson();

    final copyPath = p.join(tempDir.path, 'copy.json');
    final copy = AdRuleLibraryStore(path: copyPath, log: log);
    final first = copy.importJson(exported, source: kAdRuleSourceUser);
    expect(first.added, 2);
    expect(first.rejected, 0);
    expect(copy.entries.map((entry) => entry.id), <String>['a', 'b']);
    expect(copy.entries.first.ads, <String>['a.com']);
    expect(copy.entries.first.hlsRules.single['id'], 'rule-1');

    final again = copy.importJson(copy.exportJson(), source: kAdRuleSourceUser);
    expect(again.added, 0);
    expect(again.updated, 2);
    expect(copy.entries.length, 2);
  });

  test('validateHlsRulesJson 逐条给出丢弃原因，合法项原样保留', () {
    final validation = validateHlsRulesJson(<Object?>[
      hlsRule(),
      <String, Object?>{'id': 'no-signal'},
      <String, Object?>{
        'id': 'too-many-signals',
        'hostSuffixes': <String>['a.com'],
        'minimumSignals': 3,
      },
    ]);
    expect(validation.rules.length, 1);
    expect(validation.hasRejections, isTrue);
    expect(validation.reasons.length, 2);
    expect(
      validation.reasons.any((reason) => reason.contains('minimumSignals=3')),
      isTrue,
    );
    expect(validateHlsRulesJson(null).hasRejections, isFalse);
  });

  group('resolveEffectiveRules', () {
    test('总开关关闭时返回空集，不看任何来源', () {
      final rules = resolveEffectiveRules(
        config: AppConfig(ads: <Object?>['cfg.com']),
        library: <AdRuleEntry>[
          makeEntry('a', ads: <String>['a.com']),
        ],
        adBlockEnabled: false,
      );
      expect(rules.isEmpty, isTrue);
      expect(rules.adHosts, isEmpty);
    });

    test('只有配置内联规则时按配置生效', () {
      final rules = resolveEffectiveRules(
        config: AppConfig(
          ads: <Object?>['cfg.com', 'https://cdn.ad.net/x.js'],
          hlsRules: <Object?>[hlsRule()],
        ),
        library: const <AdRuleEntry>[],
        adBlockEnabled: true,
      );
      expect(rules.adHosts, <String>['cfg.com', 'cdn.ad.net']);
      expect(rules.hlsRules.single.id, 'rule-1');
    });

    test('只有本地库时按库生效，停用的条目不算', () {
      final rules = resolveEffectiveRules(
        config: null,
        library: <AdRuleEntry>[
          makeEntry(
            'a',
            ads: <String>['On.com'],
            rules: <Map<String, Object?>>[hlsRule()],
          ),
          makeEntry('b', enabled: false, ads: <String>['off.com']),
        ],
        adBlockEnabled: true,
      );
      expect(rules.adHosts, <String>['on.com']);
      expect(rules.hlsRules.length, 1);
    });

    test('两边都开时合并并按 host / 规则 id 去重', () {
      final rules = resolveEffectiveRules(
        config: AppConfig(
          ads: <Object?>['cfg.com'],
          hlsRules: <Object?>[hlsRule(id: 'shared')],
        ),
        library: <AdRuleEntry>[
          makeEntry(
            'a',
            ads: <String>['CFG.com', 'lib.com'],
            rules: <Map<String, Object?>>[
              hlsRule(id: 'shared', host: 'other.example.com'),
              hlsRule(id: 'lib-only'),
            ],
          ),
        ],
        adBlockEnabled: true,
      );
      expect(rules.adHosts, <String>['cfg.com', 'lib.com']);
      expect(rules.hlsRules.map((rule) => rule.id), <String>[
        'shared',
        'lib-only',
      ]);
      // 同 id 保留先入的配置版本：顺序即优先级。
      expect(rules.hlsRules.first.hostSuffixes, <String>['ad.example.com']);
    });

    test('缺 id 的合成 id 规则不会被误去重掉', () {
      final rules = resolveEffectiveRules(
        config: null,
        library: <AdRuleEntry>[
          makeEntry(
            'a',
            rules: <Map<String, Object?>>[
              <String, Object?>{
                'hostSuffixes': <String>['one.example.com'],
              },
            ],
          ),
          makeEntry(
            'b',
            rules: <Map<String, Object?>>[
              <String, Object?>{
                'hostSuffixes': <String>['two.example.com'],
              },
            ],
          ),
        ],
        adBlockEnabled: true,
      );
      expect(rules.hlsRules.length, 2);
      expect(rules.hlsRules.every((rule) => rule.id == 'hls-0'), isTrue);
    });

    test('合并后的规则真能删掉广告分片（接上 cleanHlsPlaylist）', () {
      final rules = resolveEffectiveRules(
        config: null,
        library: <AdRuleEntry>[
          makeEntry(
            'a',
            rules: <Map<String, Object?>>[
              <String, Object?>{
                'id': 'ad-host',
                // 规则只在声明的清单主机范围内生效（ad_rules.dart 约束 2）。
                'playlistHostSuffixes': <String>['example.com'],
                'hostSuffixes': <String>['ad.example.com'],
              },
            ],
          ),
        ],
        adBlockEnabled: true,
      );
      const playlist =
          '#EXTM3U\n'
          '#EXT-X-VERSION:3\n'
          '#EXT-X-TARGETDURATION:6\n'
          '#EXT-X-MEDIA-SEQUENCE:0\n'
          '#EXTINF:5.0,\n'
          'https://media.example.com/1.ts\n'
          '#EXTINF:5.0,\n'
          'https://ad.example.com/2.ts\n'
          '#EXTINF:5.0,\n'
          'https://media.example.com/3.ts\n'
          '#EXTINF:5.0,\n'
          'https://media.example.com/4.ts\n'
          '#EXTINF:5.0,\n'
          'https://media.example.com/5.ts\n'
          '#EXTINF:5.0,\n'
          'https://media.example.com/6.ts\n'
          '#EXTINF:5.0,\n'
          'https://media.example.com/7.ts\n'
          '#EXTINF:5.0,\n'
          'https://media.example.com/8.ts\n'
          '#EXT-X-ENDLIST\n';
      final result = cleanHlsPlaylist(
        text: playlist,
        playlistUri: Uri.parse('https://media.example.com/index.m3u8'),
        rules: rules,
      );
      expect(result.removedSegments, 1);
      expect(result.ruleCounts['ad-host'], 1);
      expect(result.text.contains('ad.example.com/2.ts'), isFalse);
    });
  });

  group('管理页', () {
    testWidgets('渲染列表、条数摘要与来源标记', (tester) async {
      final store = AdRuleLibraryStore(path: path, log: log);
      store.add(makeEntry('a', ads: <String>['a.com']));
      await tester.pumpWidget(
        MaterialApp(home: AdRuleLibraryPage(store: store)),
      );
      expect(find.text('本地广告规则库'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      final summary = tester.widget<Text>(
        find.byKey(const ValueKey<String>('ad-rule-summary-a')),
      );
      expect(summary.data, contains('1 个主机'));
      expect(find.textContaining('手写'), findsOneWidget);
    });

    testWidgets('开关直接写回规则库', (tester) async {
      final store = AdRuleLibraryStore(path: path, log: log);
      store.add(makeEntry('a'));
      await tester.pumpWidget(
        MaterialApp(home: AdRuleLibraryPage(store: store)),
      );
      await tester.tap(find.byKey(const ValueKey<String>('ad-rule-enabled-a')));
      await tester.pumpAndSettle();
      expect(store.entries.single.enabled, isFalse);
      expect(
        AdRuleLibraryStore(path: path, log: log).entries.single.enabled,
        isFalse,
      );
    });

    testWidgets('样本预览按当前生效规则给出删除段数与命中规则', (tester) async {
      final store = AdRuleLibraryStore(path: path, log: log);
      store.add(
        makeEntry(
          'a',
          rules: <Map<String, Object?>>[
            <String, Object?>{
              'id': 'ad-host',
              'playlistHostSuffixes': <String>['example.com'],
              'hostSuffixes': <String>['ad.example.com'],
            },
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: AdRuleLibraryPage(store: store)),
      );
      await tester.tap(find.text('样本预览'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('ad-rule-preview-text')),
        '#EXTM3U\n'
        '#EXT-X-VERSION:3\n'
        '#EXT-X-TARGETDURATION:6\n'
        '#EXT-X-MEDIA-SEQUENCE:0\n'
        '#EXTINF:5.0,\n'
        'https://media.example.com/1.ts\n'
        '#EXTINF:5.0,\n'
        'https://ad.example.com/2.ts\n'
        '#EXTINF:5.0,\n'
        'https://media.example.com/3.ts\n'
        '#EXTINF:5.0,\n'
        'https://media.example.com/4.ts\n'
        '#EXTINF:5.0,\n'
        'https://media.example.com/5.ts\n'
        '#EXTINF:5.0,\n'
        'https://media.example.com/6.ts\n'
        '#EXTINF:5.0,\n'
        'https://media.example.com/7.ts\n'
        '#EXTINF:5.0,\n'
        'https://media.example.com/8.ts\n'
        '#EXT-X-ENDLIST\n',
      );
      await tester.tap(find.text('运行预览'));
      await tester.pumpAndSettle();
      final summary = tester.widget<Text>(
        find.byKey(const ValueKey<String>('ad-rule-preview-summary')),
      );
      expect(summary.data, contains('删除 1 段'));
      expect(summary.data, contains('剩余 7 段'));
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('ad-rule-preview-rules')),
            )
            .data,
        contains('ad-host × 1'),
      );
    });
  });
  group('R6 回归', () {
    test('损坏库拒绝后续 add 且保留原文', () {
      const original = '{broken';
      File(path).writeAsStringSync(original);
      final store = AdRuleLibraryStore(path: path, log: log);
      expect(store.add(makeEntry('new')), isFalse);
      expect(rawText(), original);
      expect(store.entries, isEmpty);
      expect(store.loadError, isNotNull);
    });

    test('未知版本库拒绝后续 import 且保留原文', () {
      final original = jsonEncode({'version': 999, 'entries': []});
      File(path).writeAsStringSync(original);
      final store = AdRuleLibraryStore(path: path, log: log);
      final report = store.importJson(
        jsonEncode(makeEntry('new').toJson()),
        source: 'imported',
      );
      expect(report.added, 0);
      expect(report.updated, 0);
      expect(report.rejected, 1);
      expect(report.reasons, isNotEmpty);
      expect(rawText(), original);
      expect(store.entries, isEmpty);
    });

    test('同 id 导入更新内容但保留本地开关与来源', () {
      final store = AdRuleLibraryStore(path: path, log: log);
      store.add(makeEntry('same', enabled: false, ads: ['old.example']));
      final report = store.importJson(
        jsonEncode({
          'id': 'same',
          'name': '更新名称',
          'ads': ['new.example'],
        }),
        source: 'imported',
      );
      expect(report.updated, 1);
      expect(store.entries.single.enabled, isFalse);
      expect(store.entries.single.source, 'user');
      expect(store.entries.single.name, '更新名称');
      expect(store.entries.single.ads, ['new.example']);
      expect(store.entries.single.createdAt, 100);
      final reopened = AdRuleLibraryStore(path: path, log: log);
      expect(reopened.entries.single.enabled, isFalse);
      expect(reopened.entries.single.source, 'user');
    });

    test('内容去重命中也保留本地来源', () {
      final store = AdRuleLibraryStore(path: path, log: log);
      store.add(makeEntry('local', enabled: false, ads: ['ad.example']));
      final report = store.importJson(
        jsonEncode({
          'id': 'external',
          'ads': ['ad.example'],
        }),
        source: 'imported',
      );
      expect(report.updated, 1);
      expect(store.entries.single.id, 'local');
      expect(store.entries.single.enabled, isFalse);
      expect(store.entries.single.source, 'user');
    });

    test('导入 URL 与域名按实际 host 规范化去重', () {
      final store = AdRuleLibraryStore(path: path, log: log);
      store.add(makeEntry('local', ads: ['https://AD.example/track.js']));
      final report = store.importJson(
        jsonEncode({
          'id': 'external',
          'ads': ['ad.example'],
        }),
        source: 'imported',
      );
      expect(report.added, 0);
      expect(report.updated, 1);
      expect(store.entries.length, 1);
      expect(store.entries.single.id, 'local');
    });

    testWidgets('读错时锁定新增导入开关，显式重新开始先备份再解锁', (tester) async {
      const original = '{broken';
      File(path).writeAsStringSync(original);
      final store = AdRuleLibraryStore(path: path, log: log);
      await tester.pumpWidget(
        MaterialApp(home: AdRuleLibraryPage(store: store)),
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '新增规则集'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '导入 JSON'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('备份原文件并重新开始'));
      await tester.pumpAndSettle();
      expect(rawText(), original);
      await tester.tap(find.text('确认重新开始'));
      await tester.pumpAndSettle();
      final backups = tempDir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.contains('.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
      expect(backups.single.readAsStringSync(), original);
      // SnackBar 会自己消失，页面上的备份路径必须留在原地方：只断言这条持久提示。
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.textContaining(backups.single.path), findsOneWidget);
      expect(store.loadError, isNull);
      expect(store.entries, isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '新增规则集'))
            .onPressed,
        isNotNull,
      );
      expect(store.add(makeEntry('new')), isTrue);
      expect(backups.single.readAsStringSync(), original);
    });

    testWidgets('读错且有可读条目时开关不可操作', (tester) async {
      File(path).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'entries': [
            makeEntry('a').toJson(),
            {'name': '缺 id'},
          ],
        }),
      );
      final store = AdRuleLibraryStore(path: path, log: log);
      await tester.pumpWidget(
        MaterialApp(home: AdRuleLibraryPage(store: store)),
      );
      expect(
        tester
            .widget<Switch>(
              find.byKey(const ValueKey<String>('ad-rule-enabled-a')),
            )
            .onChanged,
        isNull,
      );
    });

    testWidgets('未接 resolver 的预览明确标注仅按规则库预览', (tester) async {
      final store = AdRuleLibraryStore(path: path, log: log);
      await tester.pumpWidget(
        MaterialApp(home: AdRuleLibraryPage(store: store)),
      );
      await tester.tap(find.text('样本预览'));
      await tester.pumpAndSettle();
      expect(find.textContaining('仅按规则库预览'), findsOneWidget);
      expect(find.textContaining('不代表播放期生效规则'), findsOneWidget);
    });

    testWidgets('已接 resolver 的预览标注播放期规则并尊重关闭开关', (tester) async {
      final store = AdRuleLibraryStore(path: path, log: log);
      store.add(makeEntry('a', ads: ['media.example.com']));
      await tester.pumpWidget(
        MaterialApp(
          home: AdRuleLibraryPage(
            store: store,
            effectiveRules: (entries) => resolveEffectiveRules(
              config: null,
              library: entries,
              adBlockEnabled: false,
            ),
          ),
        ),
      );
      await tester.tap(find.text('样本预览'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前播放期生效规则'), findsOneWidget);
      await tester.tap(find.text('运行预览'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('ad-rule-preview-summary')),
            )
            .data,
        contains('删除 0 段'),
      );
    });
  });
}
