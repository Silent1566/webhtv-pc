/// Phase 4 · TMDB 剧集/人物/相关视频模型与图片选择（`docs/phase4/design/03` §4.3/§4.4、
/// `04` §7.1）。
///
/// 对应门禁：`docs/phase4/design/05` §3.10「排序键 4 条 / 方向回退 / 去重 /
/// limit / URL 拼接」与 §4.4 用例组 9（相关视频非法 key 被过滤）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';

void main() {
  group('TmdbEpisode.displayTitle（§4.3）', () {
    test('1. title 非空且非占位 → E{number} {title}', () {
      const episode = TmdbEpisode(number: 3, title: '真相');
      expect(episode.displayTitle, 'E3 真相');
    });

    test('1. 占位标题被跳过', () {
      for (final placeholder in ['Episode 3', 'EP3', 'E3', 'episode 03', 'E 3']) {
        expect(
          TmdbEpisode(number: 3, title: placeholder, date: '2024-03-01')
              .displayTitle,
          'E3 · 2024-03-01',
          reason: placeholder,
        );
      }
    });

    test('2. title 为空但 date 非空 → E{number} · {date}', () {
      const episode = TmdbEpisode(number: 3, date: '2024-03-01');
      expect(episode.displayTitle, 'E3 · 2024-03-01');
    });

    test('3. 都为空 → 第 {number} 集', () {
      const episode = TmdbEpisode(number: 3);
      expect(episode.displayTitle, '第 3 集');
    });

    test('空白 title 视为空', () {
      const episode = TmdbEpisode(number: 3, title: '   ');
      expect(episode.displayTitle, '第 3 集');
    });
  });

  group('TmdbEpisode.fromJson（§4.3）', () {
    test('正常解析', () {
      final episode = TmdbEpisode.fromJson({
        'id': 100101,
        'episode_number': 1,
        'season_number': 1,
        'name': '第 1 集',
        'overview': '简介',
        'air_date': '2024-03-01',
        'still_path': '/s1e1.jpg',
        'vote_average': 7.3,
        'runtime': 45,
      }, image: (base, path) => path == null ? '' : '$base$path', imageBase: 'https://img');
      expect(episode, isNotNull);
      expect(episode!.number, 1);
      expect(episode.seasonNumber, 1);
      expect(episode.title, '第 1 集');
      expect(episode.overview, '简介');
      expect(episode.date, '2024-03-01');
      expect(episode.stillUrl, 'https://img/s1e1.jpg');
      expect(episode.voteAverage, 7.3);
      expect(episode.runtime, 45);
      expect(episode.tmdbId, 100101);
    });

    test('缺 episode_number 或 <= 0 → null', () {
      expect(TmdbEpisode.fromJson({'name': 'x'}), isNull);
      expect(TmdbEpisode.fromJson({'episode_number': 0}), isNull);
      expect(TmdbEpisode.fromJson(null), isNull);
    });

    test('season_number 缺失时回退 fallbackSeasonNumber', () {
      final episode = TmdbEpisode.fromJson(
        {'episode_number': 1, 'name': 'x'},
        fallbackSeasonNumber: 3,
      );
      expect(episode!.seasonNumber, 3);
    });

    test('listFromSeason 解析 episodes 数组并跳过非法条目', () {
      final episodes = TmdbEpisode.listFromSeason({
        'season_number': 2,
        'episodes': [
          {'episode_number': 1, 'name': 'A'},
          {'episode_number': 2, 'name': 'B'},
          {'name': '缺集号'},
          'not-a-map',
        ],
      });
      expect(episodes.length, 2);
      expect(episodes.map((e) => e.number), [1, 2]);
      expect(episodes.every((e) => e.seasonNumber == 2), isTrue);
    });

    test('listFromSeason 非法输入返回空', () {
      expect(TmdbEpisode.listFromSeason(null), isEmpty);
      expect(TmdbEpisode.listFromSeason({}), isEmpty);
      expect(TmdbEpisode.listFromSeason({'episodes': 'x'}), isEmpty);
    });
  });

  group('TmdbPerson（§4.3）', () {
    test('演员取 character', () {
      final person = TmdbPerson.fromJson({
        'id': 287,
        'name': '示例演员',
        'character': '主角',
        'profile_path': '/p.jpg',
        'known_for_department': 'Acting',
        'biography': '传记',
      }, image: (base, path) => path == null ? '' : '$base$path', imageBase: 'https://img');
      expect(person!.personId, 287);
      expect(person.name, '示例演员');
      expect(person.subtitle, '主角');
      expect(person.profileUrl, 'https://img/p.jpg');
      expect(person.knownForDepartment, 'Acting');
      expect(person.biography, '传记');
    });

    test('剧集聚合演职员取 roles[0].character', () {
      final person = TmdbPerson.fromJson({
        'id': 287,
        'name': '示例演员',
        'roles': [
          {'character': '主角', 'episode_count': 12},
        ],
      });
      expect(person!.subtitle, '主角');
    });

    test('职员取 job', () {
      final person = TmdbPerson.fromJson({
        'id': 500,
        'name': '示例导演',
        'job': 'Director',
      });
      expect(person!.subtitle, 'Director');
    });

    test('无 character / roles / job → 空副标题', () {
      final person = TmdbPerson.fromJson({'id': 500, 'name': 'X'});
      expect(person!.subtitle, '');
    });

    test('缺 id / name → null', () {
      expect(TmdbPerson.fromJson({'name': 'X'}), isNull);
      expect(TmdbPerson.fromJson({'id': 0, 'name': 'X'}), isNull);
      expect(TmdbPerson.fromJson({'id': 1}), isNull);
      expect(TmdbPerson.fromJson(null), isNull);
    });

    test('相等性按 personId', () {
      expect(
        const TmdbPerson(personId: 1, name: 'A'),
        const TmdbPerson(personId: 1, name: 'B'),
      );
      expect(
        const TmdbPerson(personId: 1, name: 'A') ==
            const TmdbPerson(personId: 2, name: 'A'),
        isFalse,
      );
    });

    test('listFrom 解析列表', () {
      final people = TmdbPerson.listFrom([
        {'id': 1, 'name': 'A'},
        {'id': 2, 'name': 'B'},
        {'name': 'C'},
      ]);
      expect(people.length, 2);
      expect(TmdbPerson.listFrom(null), isEmpty);
      expect(TmdbPerson.listFrom('x'), isEmpty);
    });
  });

  group('TmdbVideo 安全过滤（§7.1）', () {
    test('合法 key 通过', () {
      final video = TmdbVideo.fromJson(
        {
          'id': 'v1',
          'key': 'dQw4w9WgXcQ',
          'site': 'YouTube',
          'name': '预告',
          'type': 'Trailer',
          'official': true,
          'size': 1080,
          'iso_639_1': 'zh',
          'iso_3166_1': 'CN',
          'published_at': '2024-02-01T00:00:00.000Z',
        },
        scope: TmdbVideoScope.tv,
      );
      expect(video, isNotNull);
      expect(video!.key, 'dQw4w9WgXcQ');
      expect(video.site, 'YouTube');
      expect(video.official, isTrue);
      expect(video.size, 1080);
      expect(video.watchUrl, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(video.thumbnailUrl, 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg');
      expect(video.identity, 'YouTube|dQw4w9WgXcQ');
    });

    test('非法 key（含空格）被拒绝', () {
      expect(
        TmdbVideo.fromJson(
          {'key': 'bad key with spaces', 'site': 'YouTube', 'name': 'X'},
          scope: TmdbVideoScope.tv,
        ),
        isNull,
      );
    });

    test('超长 key（> 128）被拒绝', () {
      expect(
        TmdbVideo.fromJson(
          {'key': 'x' * 200, 'site': 'YouTube', 'name': 'X'},
          scope: TmdbVideoScope.tv,
        ),
        isNull,
      );
    });

    test('key 含非法字符（注入尝试）被拒绝', () {
      for (final key in [
        '../../etc/passwd',
        'a;b',
        'a b',
        'a<b>',
        "a'b",
        'a"b',
        'a/b',
        'a\\b',
        'a\nb',
        'a?b',
        'a&b',
        'a=b',
      ]) {
        expect(
          TmdbVideo.fromJson(
            {'key': key, 'site': 'YouTube', 'name': 'X'},
            scope: TmdbVideoScope.tv,
          ),
          isNull,
          reason: key,
        );
      }
    });

    test('缺 name / site 被拒绝', () {
      expect(
        TmdbVideo.fromJson({'key': 'abc', 'site': 'YouTube'}, scope: TmdbVideoScope.tv),
        isNull,
      );
      expect(
        TmdbVideo.fromJson({'key': 'abc', 'name': 'X'}, scope: TmdbVideoScope.tv),
        isNull,
      );
    });

    test('字段长度被截断', () {
      final video = TmdbVideo.fromJson(
        {
          'key': 'abc',
          'site': 'YouTube',
          'name': 'x' * 500,
          'type': 'y' * 200,
          'iso_639_1': 'z' * 100,
          'iso_3166_1': 'w' * 100,
        },
        scope: TmdbVideoScope.tv,
      )!;
      expect(video.name.length, tmdbVideoMaxNameLength);
      expect(video.type.length, tmdbVideoMaxTypeLength);
      expect(video.iso6391.length, tmdbVideoMaxLanguageLength);
      expect(video.iso31661.length, tmdbVideoMaxCountryLength);
    });

    test('listFrom 过滤非法条目', () {
      final videos = TmdbVideo.listFrom({
        'results': [
          {'key': 'good1', 'site': 'YouTube', 'name': 'A'},
          {'key': 'bad key', 'site': 'YouTube', 'name': 'B'},
          {'key': 'x' * 200, 'site': 'YouTube', 'name': 'C'},
          {'key': 'good2', 'site': 'YouTube', 'name': 'D'},
          'not-a-map',
        ],
      }, scope: TmdbVideoScope.tv);
      expect(videos.length, 2);
      expect(videos.map((v) => v.key), ['good1', 'good2']);
    });

    test('listFrom 非法输入返回空', () {
      expect(TmdbVideo.listFrom(null, scope: TmdbVideoScope.tv), isEmpty);
      expect(TmdbVideo.listFrom({}, scope: TmdbVideoScope.tv), isEmpty);
      expect(
        TmdbVideo.listFrom({'results': 'x'}, scope: TmdbVideoScope.tv),
        isEmpty,
      );
    });
  });

  group('TmdbVideo.mergeAndRank（§7.1）', () {
    TmdbVideo make({
      required String key,
      required String type,
      required String iso6391,
      required bool official,
      required int size,
      TmdbVideoScope scope = TmdbVideoScope.tv,
    }) => TmdbVideo(
      id: key,
      key: key,
      site: 'YouTube',
      name: key,
      type: type,
      official: official,
      size: size,
      iso6391: iso6391,
      scope: scope,
    );

    test('scopeRank：episode/movie > season > tv', () {
      final ranked = TmdbVideo.mergeAndRank(
        [
          make(key: 'tv1', type: 'Trailer', iso6391: 'zh', official: true, size: 1080, scope: TmdbVideoScope.tv),
          make(key: 'sea1', type: 'Trailer', iso6391: 'zh', official: true, size: 1080, scope: TmdbVideoScope.season),
          make(key: 'epi1', type: 'Trailer', iso6391: 'zh', official: true, size: 1080, scope: TmdbVideoScope.episode),
          make(key: 'mov1', type: 'Trailer', iso6391: 'zh', official: true, size: 1080, scope: TmdbVideoScope.movie),
        ],
        preferredLanguage: 'zh',
      );
      expect(ranked.first.key, anyOf('epi1', 'mov1'));
      expect(ranked.last.key, 'tv1');
    });

    test('languageRank：偏好语言匹配 > 空 > 其他', () {
      final ranked = TmdbVideo.mergeAndRank(
        [
          make(key: 'other', type: 'Trailer', iso6391: 'en', official: true, size: 1080),
          make(key: 'empty', type: 'Trailer', iso6391: '', official: true, size: 1080),
          make(key: 'zh', type: 'Trailer', iso6391: 'zh', official: true, size: 1080),
        ],
        preferredLanguage: 'zh',
      );
      expect(ranked.map((v) => v.key), ['zh', 'empty', 'other']);
    });

    test('typeRank：Trailer > Teaser > Clip > Featurette > 其他', () {
      final ranked = TmdbVideo.mergeAndRank(
        [
          make(key: 'f', type: 'Featurette', iso6391: 'zh', official: true, size: 1080),
          make(key: 't', type: 'Trailer', iso6391: 'zh', official: true, size: 1080),
          make(key: 'c', type: 'Clip', iso6391: 'zh', official: true, size: 1080),
          make(key: 'ts', type: 'Teaser', iso6391: 'zh', official: true, size: 1080),
          make(key: 'o', type: 'Other', iso6391: 'zh', official: true, size: 1080),
        ],
        preferredLanguage: 'zh',
      );
      expect(ranked.map((v) => v.key), ['t', 'ts', 'c', 'f', 'o']);
    });

    test('official 优先于非官方', () {
      final ranked = TmdbVideo.mergeAndRank(
        [
          make(key: 'unofficial', type: 'Trailer', iso6391: 'zh', official: false, size: 1080),
          make(key: 'official', type: 'Trailer', iso6391: 'zh', official: true, size: 720),
        ],
        preferredLanguage: 'zh',
      );
      expect(ranked.first.key, 'official');
    });

    test('size 降序作为末位排序键', () {
      final ranked = TmdbVideo.mergeAndRank(
        [
          make(key: 'small', type: 'Trailer', iso6391: 'zh', official: true, size: 480),
          make(key: 'large', type: 'Trailer', iso6391: 'zh', official: true, size: 1080),
        ],
        preferredLanguage: 'zh',
      );
      expect(ranked.first.key, 'large');
    });

    test('去重按 identity（site|key）', () {
      final ranked = TmdbVideo.mergeAndRank(
        [
          make(key: 'same', type: 'Trailer', iso6391: 'zh', official: true, size: 1080),
          make(key: 'same', type: 'Teaser', iso6391: 'zh', official: false, size: 480),
        ],
        preferredLanguage: 'zh',
      );
      expect(ranked.length, 1);
    });

    test('limit 截断；limit <= 0 不限制', () {
      final videos = List.generate(
        5,
        (i) => make(key: 'k$i', type: 'Trailer', iso6391: 'zh', official: true, size: 1080 - i),
      );
      expect(TmdbVideo.mergeAndRank(videos, preferredLanguage: 'zh', limit: 2).length, 2);
      expect(TmdbVideo.mergeAndRank(videos, preferredLanguage: 'zh', limit: 0).length, 5);
      expect(TmdbVideo.mergeAndRank(videos, preferredLanguage: 'zh', limit: -1).length, 5);
      expect(TmdbVideo.mergeAndRank(videos, preferredLanguage: 'zh', limit: 99).length, 5);
    });

    test('空输入返回空', () {
      expect(TmdbVideo.mergeAndRank(const [], preferredLanguage: 'zh'), isEmpty);
    });
  });

  group('TmdbVideo 展示字段', () {
    test('scopeLabel 四种作用域', () {
      expect(
        const TmdbVideo(id: 'a', key: 'a', site: 'YouTube', name: 'n', type: 'Trailer')
            .scopeLabel,
        '剧集',
      );
      expect(
        const TmdbVideo(
          id: 'a',
          key: 'a',
          site: 'YouTube',
          name: 'n',
          type: 'Trailer',
          scope: TmdbVideoScope.season,
          seasonNumber: 2,
        ).scopeLabel,
        '第 2 季',
      );
      expect(
        const TmdbVideo(
          id: 'a',
          key: 'a',
          site: 'YouTube',
          name: 'n',
          type: 'Trailer',
          scope: TmdbVideoScope.episode,
          seasonNumber: 2,
          episodeNumber: 3,
        ).scopeLabel,
        '第 2 季第 3 集',
      );
      expect(
        const TmdbVideo(
          id: 'a',
          key: 'a',
          site: 'YouTube',
          name: 'n',
          type: 'Trailer',
          scope: TmdbVideoScope.movie,
        ).scopeLabel,
        '电影',
      );
    });

    test('displayType 映射', () {
      TmdbVideo make(String type) => TmdbVideo(
        id: 'a',
        key: 'a',
        site: 'YouTube',
        name: 'n',
        type: type,
      );
      expect(make('Trailer').displayType, '预告');
      expect(make('Teaser').displayType, '先导');
      expect(make('Clip').displayType, '片段');
      expect(make('Featurette').displayType, '花絮');
      expect(make('Behind the Scenes').displayType, '幕后');
      expect(make('Bloopers').displayType, '花絮');
      expect(make('').displayType, '视频');
      expect(make('Weird').displayType, 'Weird');
    });
  });

  group('图片 URL 拼接（§4.4）', () {
    test('base 或 path 为空 → 空串', () {
      expect(TmdbImageSelector.image('', '/a.jpg'), '');
      expect(TmdbImageSelector.image('https://img', ''), '');
      expect(TmdbImageSelector.image('https://img', null), '');
      expect(TmdbImageSelector.image('', ''), '');
    });

    test('path 已是 http(s) → 原样返回', () {
      expect(
        TmdbImageSelector.image('https://img', 'https://cdn.example.com/a.jpg'),
        'https://cdn.example.com/a.jpg',
      );
      expect(
        TmdbImageSelector.image('https://img', 'http://cdn.example.com/a.jpg'),
        'http://cdn.example.com/a.jpg',
      );
    });

    test('base 末尾斜杠去重', () {
      expect(TmdbImageSelector.image('https://img/', '/a.jpg'), 'https://img/a.jpg');
      expect(TmdbImageSelector.image('https://img///', '/a.jpg'), 'https://img/a.jpg');
      expect(TmdbImageSelector.image('https://img', '/a.jpg'), 'https://img/a.jpg');
      expect(TmdbImageSelector.image('https://img', 'a.jpg'), 'https://img/a.jpg');
    });
  });

  group('stripImageSize（§4.4）', () {
    test('反复剥离尺寸段', () {
      expect(
        TmdbImageSelector.stripImageSize('https://images.tmdb.org/t/p/w342'),
        'https://images.tmdb.org/t/p',
      );
      expect(
        TmdbImageSelector.stripImageSize('https://images.tmdb.org/t/p/original'),
        'https://images.tmdb.org/t/p',
      );
      expect(
        TmdbImageSelector.stripImageSize('https://images.tmdb.org/t/p/h632'),
        'https://images.tmdb.org/t/p',
      );
      // 多重尺寸段
      expect(
        TmdbImageSelector.stripImageSize('https://images.tmdb.org/t/p/w342/original'),
        'https://images.tmdb.org/t/p',
      );
      // 无尺寸段时不变
      expect(
        TmdbImageSelector.stripImageSize('https://images.tmdb.org/t/p'),
        'https://images.tmdb.org/t/p',
      );
    });
  });

  group('候选排序 4 条键（§4.4）', () {
    TmdbImageCandidate make({
      required String url,
      int sourceRank = 0,
      int width = 100,
      int height = 100,
      double voteAverage = 0,
      int voteCount = 0,
    }) => TmdbImageCandidate(
      url: url,
      sourceRank: sourceRank,
      width: width,
      height: height,
      voteAverage: voteAverage,
      voteCount: voteCount,
    );

    test('1. sourceRank 优先于其他所有键', () {
      final urls = TmdbImageSelector.urls([
        make(url: 'root', sourceRank: 1, width: 9999, height: 9999, voteAverage: 9.9, voteCount: 999),
        make(url: 'images', sourceRank: 0, width: 1, height: 1),
      ], 0);
      expect(urls, ['images', 'root']);
    });

    test('2. 像素面积降序', () {
      final urls = TmdbImageSelector.urls([
        make(url: 'small', width: 100, height: 100),
        make(url: 'large', width: 1920, height: 1080),
        make(url: 'medium', width: 500, height: 500),
      ], 0);
      expect(urls, ['large', 'medium', 'small']);
    });

    test('3. vote_average 降序（面积相同时）', () {
      final urls = TmdbImageSelector.urls([
        make(url: 'low', width: 100, height: 100, voteAverage: 1.0),
        make(url: 'high', width: 100, height: 100, voteAverage: 9.0),
      ], 0);
      expect(urls, ['high', 'low']);
    });

    test('4. vote_count 降序（面积与评分相同时）', () {
      final urls = TmdbImageSelector.urls([
        make(url: 'few', width: 100, height: 100, voteAverage: 5.0, voteCount: 1),
        make(url: 'many', width: 100, height: 100, voteAverage: 5.0, voteCount: 100),
      ], 0);
      expect(urls, ['many', 'few']);
    });

    test('去重按 URL', () {
      final urls = TmdbImageSelector.urls([
        make(url: 'same', width: 100, height: 100),
        make(url: 'same', width: 200, height: 200),
      ], 0);
      expect(urls, ['same']);
    });

    test('limit：<= 0 不限，> 0 截断', () {
      final candidates = List.generate(
        5,
        (i) => make(url: 'u$i', width: 1000 - i, height: 1000),
      );
      expect(TmdbImageSelector.urls(candidates, 0).length, 5);
      expect(TmdbImageSelector.urls(candidates, -1).length, 5);
      expect(TmdbImageSelector.urls(candidates, 2).length, 2);
      expect(TmdbImageSelector.urls(candidates, 99).length, 5);
    });

    test('空 URL 被跳过', () {
      final urls = TmdbImageSelector.urls([
        make(url: ''),
        make(url: 'ok'),
      ], 0);
      expect(urls, ['ok']);
    });
  });

  group('candidates 提取（§4.4）', () {
    test('images.<kind> 优先于根级 path（sourceRank 0 vs 1）', () {
      final candidates = TmdbImageSelector.candidates(
        {
          'poster_path': '/root.jpg',
          'images': {
            'posters': [
              {'file_path': '/p1.jpg', 'width': 680, 'height': 1020, 'vote_average': 5.6, 'vote_count': 12},
            ],
          },
        },
        kind: 'posters',
        base: 'https://img',
        orientation: TmdbImageOrientation.portrait,
      );
      expect(candidates.length, 2);
      expect(candidates[0].url, 'https://img/p1.jpg');
      expect(candidates[0].sourceRank, 0);
      expect(candidates[1].url, 'https://img/root.jpg');
      expect(candidates[1].sourceRank, 1);
    });

    test('非 Map 输入返回空', () {
      expect(
        TmdbImageSelector.candidates(
          null,
          kind: 'posters',
          base: 'https://img',
          orientation: TmdbImageOrientation.portrait,
        ),
        isEmpty,
      );
    });

    test('缺 images 但有根级 path', () {
      final candidates = TmdbImageSelector.candidates(
        {'poster_path': '/root.jpg'},
        kind: 'posters',
        base: 'https://img',
        orientation: TmdbImageOrientation.portrait,
      );
      expect(candidates.length, 1);
      expect(candidates[0].url, 'https://img/root.jpg');
    });
  });

  group('posters / backdrops / backgrounds（§4.4）', () {
    const detail = {
      'poster_path': '/root-poster.jpg',
      'backdrop_path': '/root-backdrop.jpg',
      'images': {
        'posters': [
          {'file_path': '/p1.jpg', 'width': 680, 'height': 1020},
        ],
        'backdrops': [
          {'file_path': '/b1.jpg', 'width': 1920, 'height': 1080},
        ],
      },
    };

    test('posters 优先 images.posters', () {
      expect(
        TmdbImageSelector.posters(detail, 'https://img'),
        ['https://img/p1.jpg', 'https://img/root-poster.jpg'],
      );
    });

    test('backdrops 优先 images.backdrops', () {
      expect(
        TmdbImageSelector.backdrops(detail, 'https://img'),
        ['https://img/b1.jpg', 'https://img/root-backdrop.jpg'],
      );
    });

    test('backgrounds：preferLandscape=true 优先背景图', () {
      expect(
        TmdbImageSelector.backgrounds(
          detail,
          imageBase: 'https://img/w342',
          backdropBase: 'https://img/w780',
          preferLandscape: true,
        ),
        ['https://img/w780/b1.jpg', 'https://img/w780/root-backdrop.jpg'],
      );
    });

    test('backgrounds：preferLandscape=false 优先海报', () {
      expect(
        TmdbImageSelector.backgrounds(
          detail,
          imageBase: 'https://img/w342',
          backdropBase: 'https://img/w780',
          preferLandscape: false,
        ),
        ['https://img/w342/p1.jpg', 'https://img/w342/root-poster.jpg'],
      );
    });

    test('backgrounds 方向回退：首选为空 → 另一方向', () {
      // 只有海报，无背景图
      const posterOnly = {
        'images': {
          'posters': [
            {'file_path': '/p1.jpg', 'width': 680, 'height': 1020},
          ],
        },
      };
      expect(
        TmdbImageSelector.backgrounds(
          posterOnly,
          imageBase: 'https://img/w342',
          backdropBase: 'https://img/w780',
          preferLandscape: true,
        ),
        ['https://img/w342/p1.jpg'],
      );

      // 只有背景图，无海报
      const backdropOnly = {
        'images': {
          'backdrops': [
            {'file_path': '/b1.jpg', 'width': 1920, 'height': 1080},
          ],
        },
      };
      expect(
        TmdbImageSelector.backgrounds(
          backdropOnly,
          imageBase: 'https://img/w342',
          backdropBase: 'https://img/w780',
          preferLandscape: false,
        ),
        ['https://img/w780/b1.jpg'],
      );
    });

    test('两者都空 → 空列表', () {
      expect(
        TmdbImageSelector.backgrounds(
          const {},
          imageBase: 'https://img',
          backdropBase: 'https://img',
          preferLandscape: true,
        ),
        isEmpty,
      );
    });
  });

  group('辅助函数', () {
    test('tmdbYearLabel', () {
      expect(tmdbYearLabel('2024-03-01'), '2024');
      expect(tmdbYearLabel(''), '');
      expect(tmdbYearLabel(null), '');
    });

    test('dedupeItems 按身份去重，保留无身份项', () {
      final items = [
        const TmdbItem(tmdbId: 1, mediaType: TmdbMediaType.tv, title: 'A'),
        const TmdbItem(tmdbId: 1, mediaType: TmdbMediaType.tv, title: 'A2'),
        const TmdbItem(tmdbId: 1, mediaType: TmdbMediaType.movie, title: 'B'),
        const TmdbItem(tmdbId: 0, mediaType: TmdbMediaType.tv, title: 'C'),
      ];
      final deduped = dedupeItems(items);
      expect(deduped.length, 3);
      expect(deduped[0].title, 'A');
      expect(deduped[1].title, 'B');
      expect(deduped[2].title, 'C');
    });
  });
}
