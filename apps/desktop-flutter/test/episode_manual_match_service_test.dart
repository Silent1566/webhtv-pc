/// 集级手动匹配的持久化层（`episode_manual_match_service`）。
///
/// 合同见 `docs/superpowers/specs/2026-11-21-episode-manual-match-design.md` §4：
/// 五元键（配置/站点/影片/标题/线路）唯一，同键覆盖不新增行；`anchors` 为
/// JSON 数组，读取坏数据不抛（一律 `const []`）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:webhtv_pc/core/episode_manual_match.dart';
import 'package:webhtv_pc/services/episode_manual_match_service.dart';
import 'package:webhtv_pc/services/storage.dart';

const List<EpisodeMatchAnchor> _anchors = [
  EpisodeMatchAnchor(
    sourceIndex: 10,
    sourceName: '第10期',
    seasonNumber: 1,
    episodeNumber: 10,
  ),
  EpisodeMatchAnchor(
    sourceIndex: 13,
    sourceName: '第13期 下',
    seasonNumber: 2,
    episodeNumber: 3,
    spread: false,
  ),
];

void main() {
  late AppDatabase db;
  late EpisodeManualMatchService service;

  setUp(() {
    db = AppDatabase.inMemory();
    service = EpisodeManualMatchService(database: db);
  });
  tearDown(() => db.dispose());

  List<EpisodeMatchAnchor> load({
    int configId = 3,
    String siteKey = 'site-a',
    String vodId = 'vod-1',
    String sourceTitle = '中文片名',
    String flagKey = 'flag-a',
  }) => service.load(
    configId: configId,
    siteKey: siteKey,
    vodId: vodId,
    sourceTitle: sourceTitle,
    flagKey: flagKey,
  );

  void save({
    int configId = 3,
    String siteKey = 'site-a',
    String vodId = 'vod-1',
    String sourceTitle = '中文片名',
    String flagKey = 'flag-a',
    int tmdbId = 95396,
    String mediaType = 'tv',
    List<EpisodeMatchAnchor> anchors = _anchors,
  }) => service.save(
    configId: configId,
    siteKey: siteKey,
    vodId: vodId,
    sourceTitle: sourceTitle,
    flagKey: flagKey,
    tmdbId: tmdbId,
    mediaType: mediaType,
    anchors: anchors,
  );

  void clear({
    int configId = 3,
    String siteKey = 'site-a',
    String vodId = 'vod-1',
    String sourceTitle = '中文片名',
    String flagKey = 'flag-a',
  }) => service.clear(
    configId: configId,
    siteKey: siteKey,
    vodId: vodId,
    sourceTitle: sourceTitle,
    flagKey: flagKey,
  );

  test('save → load 往返保真（含 spread:false 与中文 sourceName）', () {
    save();
    final loaded = load();
    expect(loaded, equals(_anchors));
    expect(loaded, hasLength(2));
    expect(loaded.first.sourceName, '第10期');
    expect(loaded.first.spread, isTrue);
    expect(loaded.last.sourceName, '第13期 下');
    expect(loaded.last.spread, isFalse);
    expect(loaded.last.seasonNumber, 2);
    expect(loaded.last.episodeNumber, 3);
    expect(db.count('episode_manual_bindings'), 1);
  });

  test('同键二次 save 是覆盖而非新增行', () {
    save();
    const replaced = [
      EpisodeMatchAnchor(
        sourceIndex: 2,
        sourceName: '正片 02',
        seasonNumber: 1,
        episodeNumber: 2,
      ),
    ];
    save(tmdbId: 42, mediaType: 'movie', anchors: replaced);

    expect(db.count('episode_manual_bindings'), 1);
    expect(load(), equals(replaced));
    expect(service.loadScope(
      configId: 3,
      siteKey: 'site-a',
      vodId: 'vod-1',
      sourceTitle: '中文片名',
      flagKey: 'flag-a',
    ), (tmdbId: 42, mediaType: 'movie'));
  });

  test('按 flag_key / vod_id / site_key / config_id / source_title 隔离', () {
    save();
    const otherLine = [
      EpisodeMatchAnchor(
        sourceIndex: 1,
        sourceName: '线路二 01',
        seasonNumber: 3,
        episodeNumber: 1,
      ),
    ];
    save(flagKey: 'flag-b', anchors: otherLine);
    save(vodId: 'vod-2', anchors: otherLine);
    save(siteKey: 'site-b', anchors: otherLine);
    save(configId: 4, anchors: otherLine);
    save(sourceTitle: '另一部', anchors: otherLine);

    expect(db.count('episode_manual_bindings'), 6);
    expect(load(), equals(_anchors));
    expect(load(flagKey: 'flag-b'), equals(otherLine));
    expect(load(vodId: 'vod-2'), equals(otherLine));
    expect(load(siteKey: 'site-b'), equals(otherLine));
    expect(load(configId: 4), equals(otherLine));
    expect(load(sourceTitle: '另一部'), equals(otherLine));
    // 未写过的键：无行即空列表
    expect(load(flagKey: 'flag-never'), isEmpty);
    expect(load(vodId: 'vod-never'), isEmpty);
  });

  test('clear 后 load 为空且行被删除（可重复调用）', () {
    save();
    clear();
    expect(load(), isEmpty);
    expect(db.count('episode_manual_bindings'), 0);
    expect(
      service.loadScope(
        configId: 3,
        siteKey: 'site-a',
        vodId: 'vod-1',
        sourceTitle: '中文片名',
        flagKey: 'flag-a',
      ),
      isNull,
    );
    clear();
    expect(load(), isEmpty);
  });

  test('空 anchors 存的是空列表，读回不抛', () {
    save(anchors: const []);
    expect(load(), isEmpty);
    expect(db.count('episode_manual_bindings'), 1);
  });

  test('tmdb_id / media_type 原样存储，loadScope 无行返回 null', () {
    expect(
      service.loadScope(
        configId: 3,
        siteKey: 'site-a',
        vodId: 'vod-1',
        sourceTitle: '中文片名',
        flagKey: 'flag-a',
      ),
      isNull,
    );
    save(tmdbId: 0, mediaType: '');
    expect(service.loadScope(
      configId: 3,
      siteKey: 'site-a',
      vodId: 'vod-1',
      sourceTitle: '中文片名',
      flagKey: 'flag-a',
    ), (tmdbId: 0, mediaType: ''));
    save(tmdbId: 1399, mediaType: 'tv');
    expect(service.loadScope(
      configId: 3,
      siteKey: 'site-a',
      vodId: 'vod-1',
      sourceTitle: '中文片名',
      flagKey: 'flag-a',
    ), (tmdbId: 1399, mediaType: 'tv'));
  });

  group('坏数据读取', () {
    late Directory tempDir;

    setUp(() => tempDir = Directory.systemTemp.createTempSync('webhtv_emb_'));
    tearDown(() => tempDir.deleteSync(recursive: true));

    List<EpisodeMatchAnchor> loadFrom(AppDatabase database) =>
        EpisodeManualMatchService(database: database).load(
          configId: 3,
          siteKey: 'site-a',
          vodId: 'vod-1',
          sourceTitle: '中文片名',
          flagKey: 'flag-a',
        );

    void saveInto(AppDatabase database) => EpisodeManualMatchService(
      database: database,
    ).save(
      configId: 3,
      siteKey: 'site-a',
      vodId: 'vod-1',
      sourceTitle: '中文片名',
      flagKey: 'flag-a',
      tmdbId: 1,
      mediaType: 'tv',
      anchors: _anchors,
    );

    for (final broken in ['{not json', 'null', '{"a":1}', '[]', '']) {
      test('anchors 列是「$broken」时返回空列表而不抛', () {
        final path = p.join(tempDir.path, 'raw.db');
        final seeded = AppDatabase.open(path).database!;
        saveInto(seeded);
        seeded.dispose();

        final raw = sqlite3.open(path);
        raw.execute('UPDATE episode_manual_bindings SET anchors=?;', [broken]);
        raw.close();

        final reopened = AppDatabase.open(path).database!;
        try {
          expect(loadFrom(reopened), isEmpty);
        } finally {
          reopened.dispose();
        }
      });
    }
  });
}
