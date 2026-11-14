/// Phase 10：按「站点 + 影片 + 线路 + 集」记住音轨/视频轨/内嵌字幕轨。
///
/// 为什么不断言「播放器页里 setAudioTrack 被调用」：PlayerController 的构造
/// 会碰 MediaKit 原生初始化，flutter test 里起不来
/// （test/phase7_player_advance_test.dart:261 已实测确认）。所以用
/// applyTrackChoice 的注入 setter 断言接线：它收到的 id 就是生产代码交给
/// setAudioTrack / setVideoTrack 的那个 id。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/player_tracks.dart';
import 'package:webhtv_pc/services/ui_preferences_store.dart';

/// 预置 [count] 条轨道记忆（一条一次写入太慢，直接给文件）。
void _seed(String settingsPath, int count) {
  final choices = <String, Object?>{
    for (var i = 0; i < count; i++)
      'key-$i': <String, Object?>{'id': '$i', 'language': '', 'title': ''},
  };
  File(settingsPath).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'ui': <String, Object?>{'trackChoices': choices},
    }),
  );
}

/// 音轨 fixture：两条真实轨（id 会随容器重解析变化，language/title 稳定）。
const List<PlayerTrackInfo> audioTracks = [
  PlayerTrackInfo(id: '1', title: 'Japanese', language: 'jpn'),
  PlayerTrackInfo(id: '2', title: 'Chinese', language: 'chi'),
];

void main() {
  late Directory temp;
  late String settingsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-phase10-tracks');
    settingsPath = '${temp.path}${Platform.pathSeparator}settings.json';
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, Object?> readRaw() {
    final file = File(settingsPath);
    if (!file.existsSync()) return const {};
    return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  }

  /// 模拟播放页的「读记忆 → 应用」两步。
  ///
  /// 生产代码在 player_page.dart 的 _loadRememberedTrackChoices /
  /// _applyRememberedTrackChoices 里，但那要 pump 整个播放器页；这里用同样的
  /// 键函数 + 同样的 applyTrackChoice，把「哪一集、哪条线路、命中什么」
  /// 这一层断死。
  Future<List<String>> reopen({
    required UiPreferencesStore store,
    String flag = 'lineA',
    String episodeId = 'https://site/play/1',
    String episodeName = '第1集',
    List<PlayerTrackInfo> tracks = audioTracks,
    PlayerTrackSlot slot = PlayerTrackSlot.audio,
  }) async {
    final choice = store.trackChoice(
      trackChoiceKey(
        siteKey: 'bili',
        vodId: '42',
        flag: flag,
        episodeId: episodeId,
        episodeName: episodeName,
        slot: slot,
      ),
    );
    final calls = <String>[];
    if (choice == null) return calls;
    // 自动回落的结果**不**写回：这里也不写盘，写入只发生在用户显式选择时。
    await applyTrackChoice(
      tracks: tracks,
      choice: choice,
      setTrack: (id) async {
        calls.add(id);
        return true;
      },
    );
    return calls;
  }

  Future<UiPreferencesStore> openStore() async {
    final store = UiPreferencesStore(path: settingsPath);
    await store.load();
    return store;
  }

  Future<void> remember(
    UiPreferencesStore store,
    TrackChoice choice, {
    String flag = 'lineA',
    String episodeId = 'https://site/play/1',
    String episodeName = '第1集',
    PlayerTrackSlot slot = PlayerTrackSlot.audio,
  }) => store.rememberTrackChoice(
    trackChoiceKey(
      siteKey: 'bili',
      vodId: '42',
      flag: flag,
      episodeId: episodeId,
      episodeName: episodeName,
      slot: slot,
    ),
    choice,
  );

  group('记忆键', () {
    test('键含站点/影片/线路/集/槽，flag 为空时用空串占位且结构不变', () {
      final key = trackChoiceKey(
        siteKey: 'bili',
        vodId: '42',
        flag: '',
        episodeId: 'https://site/play/1',
        episodeName: '第1集',
        slot: PlayerTrackSlot.audio,
      );
      expect(key, 'bili\x0042\x00\x00https://site/play/1\x00audio');
      expect(key.split('\x00').length, 5, reason: '空线路只占位，不塌掉分隔结构');
    });

    test('集标识优先 episodeId，为空时退回 episodeName', () {
      final byId = trackChoiceKey(
        siteKey: 's',
        vodId: 'v',
        flag: 'f',
        episodeId: 'https://site/play/1',
        episodeName: '第1集',
        slot: PlayerTrackSlot.audio,
      );
      final byName = trackChoiceKey(
        siteKey: 's',
        vodId: 'v',
        flag: 'f',
        episodeId: '  ',
        episodeName: '第1集',
        slot: PlayerTrackSlot.audio,
      );
      expect(byId, contains('https://site/play/1'));
      expect(byName, endsWith('\x00第1集\x00audio'));
      expect(byId, isNot(byName));
    });

    test('换集、换线路、换槽都得到不同的键', () {
      String key({
        String flag = 'lineA',
        String episodeId = 'https://site/play/1',
        PlayerTrackSlot slot = PlayerTrackSlot.audio,
      }) => trackChoiceKey(
        siteKey: 'bili',
        vodId: '42',
        flag: flag,
        episodeId: episodeId,
        episodeName: '第1集',
        slot: slot,
      );

      final base = key();
      expect(key(episodeId: 'https://site/play/2'), isNot(base));
      expect(key(flag: 'lineB'), isNot(base));
      expect(key(slot: PlayerTrackSlot.video), isNot(base));
      expect(key(slot: PlayerTrackSlot.subtitle), isNot(base));
    });
  });

  group('三级回落匹配', () {
    test('没有记录（空 choice）时一条都不选', () {
      expect(
        matchTrackChoice(
          tracks: audioTracks,
          choice: const TrackChoice(engineId: ''),
        ),
        isNull,
      );
    });

    test('① id 精确命中', () {
      expect(
        matchTrackChoice(
          tracks: audioTracks,
          choice: const TrackChoice(
            engineId: '2',
            language: 'jpn',
            title: 'Japanese',
          ),
        ),
        '2',
        reason: 'id 命中优先于 language/title',
      );
    });

    test('② id 不在新列表里但 language 唯一命中', () {
      expect(
        matchTrackChoice(
          tracks: audioTracks,
          choice: const TrackChoice(engineId: '9', language: 'chi'),
        ),
        '2',
      );
    });

    test('② language 在该类轨道里不唯一时不猜', () {
      const tracks = [
        PlayerTrackInfo(id: '1', title: 'A', language: 'und'),
        PlayerTrackInfo(id: '2', title: 'B', language: 'und'),
      ];
      expect(
        matchTrackChoice(
          tracks: tracks,
          choice: const TrackChoice(engineId: '9', language: 'und'),
        ),
        isNull,
        reason: '多轨共用 und 很常见，猜一次就是切错轨',
      );
    });

    test('③ id/language 都不中时按 title 精确命中', () {
      expect(
        matchTrackChoice(
          tracks: audioTracks,
          choice: const TrackChoice(
            engineId: '9',
            language: 'ko',
            title: 'Chinese',
          ),
        ),
        '2',
      );
    });

    test('④ 三级都不中返回 null（回落 auto），不抛错', () {
      expect(
        matchTrackChoice(
          tracks: audioTracks,
          choice: const TrackChoice(
            engineId: '9',
            language: 'ko',
            title: 'Korean',
          ),
        ),
        isNull,
      );
    });

    test('auto/no 伪轨不参与 language/title 匹配', () {
      const tracks = [
        PlayerTrackInfo(id: 'auto', title: 'Chinese', language: 'chi'),
        PlayerTrackInfo(id: 'no'),
        PlayerTrackInfo(id: '3', title: 'Chinese', language: 'chi'),
      ];
      expect(
        matchTrackChoice(
          tracks: tracks,
          choice: const TrackChoice(
            engineId: '9',
            language: 'chi',
            title: 'Chinese',
          ),
        ),
        '3',
        reason: '唯一命中被伪轨抢走会落到 no（关闭音轨）',
      );
    });
  });

  group('应用到引擎（applyTrackChoice 的接线）', () {
    test('命中时把记录里的 id 交给 setTrack', () async {
      final calls = <String>[];
      final hit = await applyTrackChoice(
        tracks: audioTracks,
        choice: const TrackChoice(
          engineId: '2',
          language: 'chi',
          title: 'Chinese',
        ),
        setTrack: (id) async {
          calls.add(id);
          return true;
        },
      );
      expect(hit, isTrue);
      expect(calls, ['2'], reason: '参数必须与记录一致，不能是列表下标');
    });

    test('未命中时根本不调用 setTrack，保持引擎默认', () async {
      final calls = <String>[];
      final hit = await applyTrackChoice(
        tracks: audioTracks,
        choice: const TrackChoice(
          engineId: '9',
          language: 'ko',
          title: 'Korean',
        ),
        setTrack: (id) async {
          calls.add(id);
          return true;
        },
      );
      expect(hit, isFalse);
      expect(calls, isEmpty);
    });
  });

  group('重试判定（轨道集合变了才重试）', () {
    test('空表不尝试：引擎一条都没上报时尝试必然空转', () {
      expect(
        shouldAttemptTrackChoice(currentIds: const [], lastTriedIds: null),
        isFalse,
      );
      expect(
        shouldAttemptTrackChoice(
          currentIds: const [],
          lastTriedIds: const ['auto'],
        ),
        isFalse,
        reason: '表被清空（切集/换片）时不该拿旧记录去 set',
      );
    });

    test('上次为 null 且表非空时尝试', () {
      expect(
        shouldAttemptTrackChoice(
          currentIds: const ['auto'],
          lastTriedIds: null,
        ),
        isTrue,
      );
      expect(
        shouldAttemptTrackChoice(
          currentIds: const ['1', '2'],
          lastTriedIds: null,
        ),
        isTrue,
      );
    });

    test('与上次完全相同的集合不重复尝试', () {
      expect(
        shouldAttemptTrackChoice(
          currentIds: const ['auto'],
          lastTriedIds: const ['auto'],
        ),
        isFalse,
        reason: '同样的输入只会得到同样的结论，再 set 一次还会顶掉手动切换',
      );
      expect(
        shouldAttemptTrackChoice(
          currentIds: const ['1', '2'],
          lastTriedIds: const ['1', '2'],
        ),
        isFalse,
      );
    });

    test('集合变了就重试：补轨、条数变化、顺序变化都算', () {
      expect(
        shouldAttemptTrackChoice(
          currentIds: const ['auto', '1', '2'],
          lastTriedIds: const ['auto'],
        ),
        isTrue,
        reason: '首帧只有伪轨、之后补齐真实轨——正是这条要修',
      );
      expect(
        shouldAttemptTrackChoice(
          currentIds: const ['1'],
          lastTriedIds: const ['1', '2'],
        ),
        isTrue,
      );
      expect(
        shouldAttemptTrackChoice(
          currentIds: const ['2', '1'],
          lastTriedIds: const ['1', '2'],
        ),
        isTrue,
        reason: '顺序变了 id 归属就可能变，按顺序比较而不是集合比较',
      );
    });

    test('伪轨首帧失配 → 补齐后重试并命中（回归本修复）', () async {
      const choice = TrackChoice(
        engineId: '9',
        language: 'chi',
        title: 'Chinese',
      );
      const firstFrame = [PlayerTrackInfo(id: 'auto', title: 'auto')];
      final fullFrame = [
        const PlayerTrackInfo(id: 'auto', title: 'auto'),
        ...audioTracks,
      ];

      List<String> ids(List<PlayerTrackInfo> tracks) => [
        for (final track in tracks) track.id,
      ];

      // 模拟 widget 侧的两个槽状态：已应用标记 + 上次试过的 id 列表。
      var applied = false;
      List<String>? lastTried;

      Future<bool> pumpFrame(List<PlayerTrackInfo> tracks) async {
        if (applied) return false;
        if (!shouldAttemptTrackChoice(
          currentIds: ids(tracks),
          lastTriedIds: lastTried,
        )) {
          return false;
        }
        lastTried = ids(tracks);
        final hit = await applyTrackChoice(
          tracks: tracks,
          choice: choice,
          setTrack: (id) async => true,
        );
        if (hit) {
          applied = true;
          lastTried = null;
        }
        return hit;
      }

      expect(await pumpFrame(firstFrame), isFalse, reason: '首帧只有伪轨，matchTrackChoice 必落空');
      expect(applied, isFalse, reason: '未命中绝不能标记已应用');
      expect(await pumpFrame(firstFrame), isFalse, reason: '同一份伪轨表不重复尝试');

      expect(await pumpFrame(fullFrame), isTrue);
      expect(applied, isTrue, reason: '命中后才允许标记已应用');
      // 已应用之后，任何后续上报都不再动引擎。
      expect(await pumpFrame(fullFrame), isFalse);
    });
  });

  group('持久化', () {
    test('写入后重新 load 得到同一条；落盘形如 {id,language,title}', () async {
      final store = await openStore();
      await remember(
        store,
        const TrackChoice(engineId: '2', language: 'chi', title: 'Chinese'),
      );

      final raw = readRaw();
      final choices = (raw['ui'] as Map)['trackChoices'] as Map;
      expect(choices.length, 1);
      expect(
        choices.keys.single,
        'bili\x0042\x00lineA\x00https://site/play/1\x00audio',
      );
      expect(choices.values.single, {
        'id': '2',
        'language': 'chi',
        'title': 'Chinese',
      });

      final reloaded = await openStore();
      expect(
        reloaded.trackChoice(
          'bili\x0042\x00lineA\x00https://site/play/1\x00audio',
        ),
        const TrackChoice(engineId: '2', language: 'chi', title: 'Chinese'),
      );
    });

    test('不覆盖 ui 段的其它键', () async {
      final store = await openStore();
      await store.rememberVideoFitMode(
        siteKey: 'bili',
        vodId: '42',
        mode: 'cover',
      );
      await remember(store, const TrackChoice(engineId: '2'));

      final ui = (readRaw()['ui'] as Map);
      expect(ui['videoFitModes'], isNotEmpty);
      expect(ui['trackChoices'], isNotEmpty);
      expect(store.videoFitMode(siteKey: 'bili', vodId: '42'), 'cover');
    });

    test('上限 500 条：再写一条按插入顺序丢最旧', () async {
      // 预置 500 条而不是真跑 501 次写入：每次写入都是一次 tmp+rename，
      // Windows 上要 30 秒，全套测试会因此被拖到超时。
      _seed(settingsPath, 500);
      final store = await openStore();
      expect(store.trackChoice('key-0'), isNotNull);

      await store.rememberTrackChoice(
        'key-500',
        const TrackChoice(engineId: '500'),
      );
      expect(store.trackChoice('key-0'), isNull, reason: '最旧的被裁掉');
      expect(store.trackChoice('key-500'), isNotNull);
      final choices = ((readRaw()['ui'] as Map)['trackChoices'] as Map);
      expect(choices.length, 500);
    });

    test('恢复手改的超量文件时同样按上限裁剪', () async {
      _seed(settingsPath, 505);
      final store = await openStore();
      expect(store.trackChoice('key-4'), isNull);
      expect(store.trackChoice('key-5'), isNotNull);
      final choices = ((readRaw()['ui'] as Map)['trackChoices'] as Map);
      expect(choices.length, 505, reason: '读不该写盘，裁剪等下次写入再落盘');
    });

    test('重选同一条只挪位置，不吃掉别的记录', () async {
      final store = await openStore();
      await store.rememberTrackChoice('a', const TrackChoice(engineId: '1'));
      await store.rememberTrackChoice('b', const TrackChoice(engineId: '2'));
      await store.rememberTrackChoice('a', const TrackChoice(engineId: '3'));
      final choices = ((readRaw()['ui'] as Map)['trackChoices'] as Map);
      expect(choices.keys.toList(), ['b', 'a'], reason: 'Map 迭代顺序就是插入顺序');
      expect(store.trackChoice('a'), const TrackChoice(engineId: '3'));
    });
  });

  group('剧集维度：不跨集、不跨线路共享', () {
    test('无记录时不用任何已存选择（走引擎默认）', () async {
      final store = await openStore();
      expect(await reopen(store: store), isEmpty);
    });

    test('选了音轨 X，重开同一线路同一集自动恢复到 X', () async {
      final store = await openStore();
      await remember(
        store,
        const TrackChoice(engineId: '2', language: 'chi', title: 'Chinese'),
      );
      expect(await reopen(store: store), ['2']);
      // 重新 load 一次也还在（真的落盘了）。
      expect(await reopen(store: await openStore()), ['2']);
    });

    test('换集不沿用上一集的选择', () async {
      final store = await openStore();
      await remember(store, const TrackChoice(engineId: '2'));
      expect(
        await reopen(
          store: store,
          episodeId: 'https://site/play/2',
          episodeName: '第2集',
        ),
        isEmpty,
      );
    });

    test('换线路（flag 不同）不沿用', () async {
      final store = await openStore();
      await remember(store, const TrackChoice(engineId: '2'));
      expect(await reopen(store: store, flag: 'lineB'), isEmpty);
    });

    test('记录的 id 在新加载里不存在，但 language 唯一 → 按 language 恢复', () async {
      final store = await openStore();
      await remember(store, const TrackChoice(engineId: '9', language: 'chi'));
      expect(await reopen(store: store), ['2']);
    });

    test('id/language/title 都不中 → 回落 auto，且不覆盖已存记录', () async {
      final store = await openStore();
      const remembered = TrackChoice(
        engineId: '9',
        language: 'ko',
        title: 'Korean',
      );
      await remember(store, remembered);
      expect(await reopen(store: store), isEmpty);
      expect(
        store.trackChoice(
          'bili\x0042\x00lineA\x00https://site/play/1\x00audio',
        ),
        remembered,
        reason: '自动回落绝不写回，否则一次失配就把用户选择冲掉',
      );
    });
  });

  group('视频轨与内嵌字幕轨同样生效', () {
    test('视频轨按 id 恢复', () async {
      final store = await openStore();
      await remember(
        store,
        const TrackChoice(engineId: '2', language: 'und', title: '1080p'),
        slot: PlayerTrackSlot.video,
      );
      expect(
        await reopen(
          store: store,
          slot: PlayerTrackSlot.video,
          tracks: const [
            PlayerTrackInfo(id: '1', title: '720p', language: 'und'),
            PlayerTrackInfo(id: '2', title: '1080p', language: 'und'),
          ],
        ),
        ['2'],
      );
    });

    test('内嵌字幕轨按 language 恢复（id 是 embedded:<trackId>）', () async {
      final store = await openStore();
      await remember(
        store,
        const TrackChoice(engineId: 'embedded:7', language: 'chi'),
        slot: PlayerTrackSlot.subtitle,
      );
      expect(
        await reopen(
          store: store,
          slot: PlayerTrackSlot.subtitle,
          tracks: const [
            PlayerTrackInfo(id: 'embedded:1', title: 'Chinese', language: 'chi'),
            PlayerTrackInfo(id: 'embedded:2', title: 'English', language: 'eng'),
          ],
        ),
        ['embedded:1'],
      );
    });

    test('三个槽的记忆互不干扰', () async {
      final store = await openStore();
      await remember(store, const TrackChoice(engineId: '2'));
      await remember(
        store,
        const TrackChoice(engineId: 'embedded:2'),
        slot: PlayerTrackSlot.subtitle,
      );
      expect(await reopen(store: store), ['2']);
      expect(
        await reopen(store: store, slot: PlayerTrackSlot.video),
        isEmpty,
        reason: '视频轨槽没记过，不能借音轨的记录来填',
      );
      expect(
        await reopen(
          store: store,
          slot: PlayerTrackSlot.subtitle,
          tracks: const [
            PlayerTrackInfo(id: 'embedded:1', title: 'English', language: 'eng'),
            PlayerTrackInfo(id: 'embedded:2', title: 'Chinese', language: 'chi'),
          ],
        ),
        ['embedded:2'],
      );
    });
  });

  group('TrackChoice 序列化', () {
    test('缺 id 的记录视为无效，多余字段忽略', () {
      expect(TrackChoice.fromJson(null), isNull);
      expect(TrackChoice.fromJson('x'), isNull);
      expect(TrackChoice.fromJson({'language': 'chi'}), isNull);
      expect(
        TrackChoice.fromJson({'id': ' 2 ', 'language': 'chi', 'extra': 1}),
        const TrackChoice(engineId: '2', language: 'chi'),
      );
    });

    test('手改文件写坏 language/title 类型时降级为空串', () {
      expect(
        TrackChoice.fromJson({'id': '2', 'language': 3, 'title': null}),
        const TrackChoice(engineId: '2'),
      );
    });
  });
}
