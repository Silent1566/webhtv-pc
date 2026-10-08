/// Phase 4 · TMDB 详情展示模型（`docs/phase4/design/04` §3、§4.2、§6）。
///
/// 对应门禁（用户反馈 2026-10-07 的三条缺陷）：
/// 1. 每集要有对应的海报卡片（剧照 + 集号 + 标题 + 播出日期）；
/// 2. 头部要有海报、导演、类型、时长、季集数等信息；
/// 3. 剧照 / 演职人员 / 相关推荐必须**可点击**（查看器定位、人物页、作品跳转）。
///
/// 本文件是**纯逻辑**层，不依赖 Flutter 与 `dart:io`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/tmdb_detail_model.dart';
import 'package:webhtv_pc/core/tmdb_identity.dart';
import 'package:webhtv_pc/core/tmdb_media.dart';

const String _imageBase = 'https://images.tmdb.org/t/p/w342';
const String _backdropBase = 'https://images.tmdb.org/t/p/w780';

/// 与 `packages/test-fixtures/tmdb/detail-tv.json` 同构的最小详情响应。
Map<String, Object?> _detailTv() => {
  'id': 1399,
  'name': '示例剧集',
  'original_name': 'Sample Show',
  'overview': '这是简介',
  'tagline': '一句标语',
  'first_air_date': '2024-03-01',
  'vote_average': 8.2,
  'vote_count': 321,
  'number_of_seasons': 2,
  'number_of_episodes': 22,
  'episode_run_time': [45],
  'status': 'Returning Series',
  'original_language': 'zh',
  'poster_path': '/tv-poster.jpg',
  'backdrop_path': '/tv-backdrop.jpg',
  'genres': [
    {'id': 18, 'name': '剧情'},
    {'id': 10765, 'name': '科幻'},
  ],
  'production_countries': [
    {'iso_3166_1': 'CN', 'name': '中国'},
  ],
  'spoken_languages': [
    {'iso_639_1': 'zh', 'name': '普通话'},
  ],
  'images': {
    'posters': [
      {'file_path': '/p1.jpg', 'width': 680, 'height': 1020},
      {'file_path': '/p2.jpg', 'width': 342, 'height': 513},
    ],
    'backdrops': [
      {'file_path': '/b1.jpg', 'width': 1920, 'height': 1080},
      {'file_path': '/b2.jpg', 'width': 1280, 'height': 720},
    ],
  },
  'seasons': [
    {
      'season_number': 0,
      'name': '特别篇',
      'episode_count': 3,
      'air_date': '2021-01-10',
      'poster_path': '/s0.jpg',
    },
    {
      'season_number': 1,
      'name': '第 1 季',
      'episode_count': 12,
      'air_date': '2024-03-01',
      'poster_path': '/s1.jpg',
    },
    {
      'season_number': 2,
      'name': '第 2 季',
      'episode_count': 10,
      'air_date': '2025-04-05',
      'poster_path': '/s2.jpg',
    },
  ],
  'aggregate_credits': {
    'cast': [
      {
        'id': 287,
        'name': '示例演员',
        'roles': [
          {'character': '主角', 'episode_count': 12},
        ],
        'profile_path': '/person.jpg',
      },
    ],
  },
  'credits': {
    'cast': [
      {'id': 287, 'name': '示例演员', 'character': '主角', 'order': 0},
    ],
    'crew': [
      {
        'id': 500,
        'name': '示例导演',
        'job': 'Director',
        'department': 'Directing',
        'profile_path': '/crew.jpg',
      },
      {
        'id': 501,
        'name': '示例编剧',
        'job': 'Writer',
        'department': 'Writing',
      },
    ],
  },
  'created_by': [
    {'id': 500, 'name': '示例导演', 'profile_path': '/crew.jpg'},
  ],
};

Map<String, Object?> _detailMovie() => {
  'id': 550,
  'media_type': 'movie',
  'title': '示例电影',
  'original_title': 'Sample Movie',
  'release_date': '2019-10-15',
  'runtime': 112,
  'vote_average': 7.9,
  'poster_path': '/m-poster.jpg',
  'backdrop_path': '/m-backdrop.jpg',
  'images': {
    'stills': [
      {'file_path': '/still1.jpg', 'width': 1920, 'height': 1080},
    ],
  },
};

void main() {
  group('TmdbDetailData 头部信息（用户反馈 2：海报/导演/其他信息）', () {
    test('剧集：标题、原名、标语、海报、背景图、评分、时长、季集数、类型、地区', () {
      final data = TmdbDetailData.fromDetail(
        _detailTv(),
        imageBase: _imageBase,
        backdropBase: _backdropBase,
      );

      expect(data.title, '示例剧集');
      expect(data.originalTitle, 'Sample Show');
      expect(data.tagline, '一句标语');
      // 海报：`images.posters` 优先于根级 `poster_path`，组内按像素面积降序。
      expect(data.posterUrl, '$_imageBase/p1.jpg');
      // 背景图：`images.backdrops` 优先，组内按像素面积降序，再回退根级。
      expect(data.backdropUrls.first, '$_backdropBase/b1.jpg');
      expect(data.backdropUrls, [
        '$_backdropBase/b1.jpg',
        '$_backdropBase/b2.jpg',
        '$_backdropBase/tv-backdrop.jpg',
      ]);
      expect(data.ratingLabel, 'TMDB 8.2');
      expect(data.yearLabel, '2024');
      expect(data.runtimeLabel, '45 分钟');
      expect(data.seasonEpisodeLabel, '2 季 · 22 集');
      expect(data.genres, ['剧情', '科幻']);
      expect(data.countries, ['中国']);
      expect(data.isTv, isTrue);
    });

    test('导演取 credits.crew 的 Director；缺失时回退 created_by', () {
      final data = TmdbDetailData.fromDetail(
        _detailTv(),
        imageBase: _imageBase,
        backdropBase: _backdropBase,
      );
      expect(data.directorLabel, '示例导演');
      expect(data.writers, ['示例编剧']);
      expect(data.crew, hasLength(2));

      // 只去掉 credits.crew：`created_by` 必须接管导演位。
      final credits = Map<String, Object?>.from(
        (_detailTv()['credits'] as Map).cast<String, Object?>(),
      )..remove('crew');
      final withoutCrew = Map<String, Object?>.from(_detailTv())
        ..['credits'] = credits;
      final fallback = TmdbDetailData.fromDetail(
        withoutCrew,
        imageBase: _imageBase,
        backdropBase: _backdropBase,
      );
      expect(
        fallback.directorLabel,
        '示例导演',
        reason: '剧集无 credits.crew 时必须回退 created_by',
      );
    });

    test('电影：时长取 runtime，小时文案正确', () {
      final data = TmdbDetailData.fromDetail(
        _detailMovie(),
        imageBase: _imageBase,
        backdropBase: _backdropBase,
      );
      expect(data.isTv, isFalse);
      expect(data.runtimeLabel, '1 小时 52 分钟');
      expect(data.ratingLabel, 'TMDB 7.9');
      expect(data.posterUrl, '$_imageBase/m-poster.jpg');
    });

    test('季度列表按季号升序，含特别篇与季海报', () {
      final data = TmdbDetailData.fromDetail(
        _detailTv(),
        imageBase: _imageBase,
        backdropBase: _backdropBase,
      );
      expect(data.seasons.map((s) => s.number), [0, 1, 2]);
      expect(data.seasons[0].label, '特别篇');
      expect(data.seasons[1].label, '第 1 季');
      expect(data.seasons[1].subtitle, '12 集 · 2024');
      expect(data.seasons[1].posterUrl, '$_imageBase/s1.jpg');
      expect(data.seasonOf(2)?.episodeCount, 10);
      expect(data.seasonOf(9), isNull);
    });

    test('无背景图时回退海报，保证动态背景不留白', () {
      // 只去掉背景图来源（`images.backdrops` 与根级 `backdrop_path`），
      // 海报仍在：此时动态背景必须回退到海报，而不是空白。
      final images = Map<String, Object?>.from(
        (_detailTv()['images'] as Map).cast<String, Object?>(),
      )..remove('backdrops');
      final detail = _detailTv()
        ..['images'] = images
        ..remove('backdrop_path');
      final data = TmdbDetailData.fromDetail(
        detail,
        imageBase: _imageBase,
        backdropBase: _backdropBase,
      );
      expect(data.backdropUrls, ['$_imageBase/p1.jpg']);
      expect(data.heroBackdrop, '$_imageBase/p1.jpg');
    });

    test('剧照只取 images.stills；无剧照时剧照墙回退背景图', () {
      final withStills = TmdbDetailData.fromDetail(
        _detailMovie(),
        imageBase: _imageBase,
        backdropBase: _backdropBase,
      );
      expect(withStills.stillUrls, ['$_imageBase/still1.jpg']);
      expect(withStills.photoUrls, ['$_imageBase/still1.jpg']);

      final withoutStills = TmdbDetailData.fromDetail(
        _detailTv(),
        imageBase: _imageBase,
        backdropBase: _backdropBase,
      );
      expect(withoutStills.stillUrls, isEmpty);
      expect(
        withoutStills.photoUrls,
        withoutStills.backdropUrls,
        reason: '没有剧照时剧照墙回退背景图，避免整块隐藏',
      );
    });

    test('未加载详情时退化为 item 快照（头部不空白）', () {
      const item = TmdbItem(
        tmdbId: 1399,
        mediaType: TmdbMediaType.tv,
        title: '示例剧集',
        posterUrl: '$_imageBase/tv-poster.jpg',
        backdropUrl: '$_backdropBase/tv-backdrop.jpg',
        tmdbRating: 8.2,
      );
      final data = TmdbDetailData.fromItem(item);
      expect(data.title, '示例剧集');
      expect(data.posterUrl, '$_imageBase/tv-poster.jpg');
      expect(data.backdropUrls, ['$_backdropBase/tv-backdrop.jpg']);
      expect(data.ratingLabel, 'TMDB 8.2');
    });
  });

  group('动态背景轮播策略（用户反馈：用海报/剧照当动态背景）', () {
    test('单张不轮播，多张轮播', () {
      expect(TmdbBackdropRotation.shouldRotate(0), isFalse);
      expect(TmdbBackdropRotation.shouldRotate(1), isFalse);
      expect(TmdbBackdropRotation.shouldRotate(2), isTrue);
    });

    test('环形推进与下标夹取', () {
      expect(TmdbBackdropRotation.next(0, 3), 1);
      expect(TmdbBackdropRotation.next(2, 3), 0);
      expect(TmdbBackdropRotation.next(0, 0), -1);
      expect(TmdbBackdropRotation.next(5, 1), 0);
      expect(TmdbBackdropRotation.clamp(7, 3), 1);
      expect(TmdbBackdropRotation.clamp(-3, 3), 0);
      expect(TmdbBackdropRotation.clamp(0, 0), -1);
    });

    test('节奏与上游一致：5 秒一张', () {
      expect(TmdbBackdropRotation.interval, const Duration(seconds: 5));
    });

    test('shouldRotateBackdrop 直接来自背景图数量', () {
      final data = TmdbDetailData.fromDetail(
        _detailTv(),
        imageBase: _imageBase,
        backdropBase: _backdropBase,
      );
      expect(data.shouldRotateBackdrop, isTrue);
    });
  });

  group('每集的海报卡片（用户反馈 1）', () {
    Map<int, TmdbEpisode> metadata() => {
      1: const TmdbEpisode(
        number: 1,
        title: '开端',
        date: '2024-03-01',
        overview: '第一集简介',
        stillUrl: '$_imageBase/s1e1.jpg',
        runtime: 45,
        voteAverage: 7.3,
        seasonNumber: 1,
      ),
      2: const TmdbEpisode(
        number: 2,
        title: '发展',
        date: '2024-03-08',
        stillUrl: '$_imageBase/s1e2.jpg',
        seasonNumber: 1,
      ),
    };

    test('按集号对齐：每集拿到对应剧照与标题', () {
      final cards = TmdbEpisodeCards.build(
        sourceNames: const ['第1集', '第2集'],
        metadataByNumber: metadata(),
        seasonNumber: 1,
      );
      expect(cards, hasLength(2));
      expect(cards[0].number, 1);
      expect(cards[0].title, 'E1 开端');
      expect(cards[0].stillUrl, '$_imageBase/s1e1.jpg');
      expect(cards[0].subtitle, 'S1E1 · 2024-03-01');
      expect(cards[0].hasStill, isTrue);
      expect(cards[1].number, 2);
      expect(cards[1].runtime, 0);
    });

    test('不补集：TMDB 有 10 集但线路 8 集 → 只有 8 张卡片', () {
      final cards = TmdbEpisodeCards.build(
        sourceNames: List.generate(8, (i) => '第${i + 1}集'),
        metadataByNumber: {
          for (var i = 1; i <= 10; i++)
            i: TmdbEpisode(
              number: i,
              title: '第 $i 集',
              stillUrl: '$_imageBase/s1e$i.jpg',
              seasonNumber: 1,
            ),
        },
        seasonNumber: 1,
      );
      expect(cards, hasLength(8));
      expect(
        TmdbEpisodeCards.matchesSourceCount(
          cards: cards,
          sourceEpisodeCount: 8,
        ),
        isTrue,
      );
    });

    test('不丢集：无元数据的集仍产出卡片（用来源集名）', () {
      final cards = TmdbEpisodeCards.build(
        sourceNames: const ['第1集', '第2集', '第3集'],
        metadataByNumber: metadata(),
        seasonNumber: 1,
      );
      expect(cards, hasLength(3));
      expect(cards[2].title, '第3集', reason: '无元数据时必须保留来源集名');
      expect(cards[2].stillUrl, isNull);
    });

    test('集号不可靠时按原始顺序对齐（02 §9.3）', () {
      final cards = TmdbEpisodeCards.build(
        sourceNames: const ['第1集', '第1集', '第1集'],
        metadataByNumber: metadata(),
        usePosition: true,
        seasonNumber: 1,
      );
      expect(cards.map((c) => c.number), [1, 2, 3]);
      expect(cards[1].title, 'E2 发展');
    });

    test('元数据缺失剧照时按顺序回退（每集仍有画面）', () {
      final cards = TmdbEpisodeCards.build(
        sourceNames: const ['第1集', '第2集'],
        metadataByNumber: const {},
        seasonNumber: 1,
        fallbackStills: const ['$_imageBase/f1.jpg', '$_imageBase/f2.jpg'],
      );
      expect(cards[0].stillUrl, '$_imageBase/f1.jpg');
      expect(cards[1].stillUrl, '$_imageBase/f2.jpg');
    });

    test('纯 TMDB 页：直接由元数据生成卡片', () {
      final cards = TmdbEpisodeCards.fromMetadata(metadata().values.toList());
      expect(cards, hasLength(2));
      expect(cards.first.seasonNumber, 1);
    });
  });

  group('剧照查看器（用户反馈 3：剧照点击无效）', () {
    const urls = [
      'https://img/a.jpg',
      'https://img/b.jpg',
      'https://img/c.jpg',
    ];

    test('点击第 N 张定位到第 N 张，而不是永远第一张', () {
      final viewer = TmdbPhotoViewer.open(urls: urls, url: urls[2]);
      expect(viewer.index, 2);
      expect(viewer.currentUrl, urls[2]);
    });

    test('URL 不在列表时定位第一张（不崩）', () {
      final viewer = TmdbPhotoViewer.open(urls: urls, url: 'https://img/x.jpg');
      expect(viewer.index, 0);
    });

    test('翻页首尾环绕，且单张时不可翻页', () {
      final viewer = TmdbPhotoViewer.open(urls: urls, url: urls[2]);
      expect(viewer.next().index, 0);
      expect(viewer.previous().index, 1);

      final single = TmdbPhotoViewer.open(urls: [urls.first], url: urls.first);
      expect(single.hasPrevious, isFalse);
      expect(single.hasNext, isFalse);
      expect(single.next().index, 0);
    });

    test('空列表安全', () {
      const viewer = TmdbPhotoViewer(urls: []);
      expect(viewer.isEmpty, isTrue);
      expect(viewer.currentUrl, isNull);
      expect(viewer.index, -1);
    });
  });

  group('人物作品（演职人员点击 → 人物页）', () {
    test('combined_credits 的 cast/crew 解析为作品并按身份去重', () {
      final works = TmdbPersonWork.listFrom(
        [
          {
            'id': 1399,
            'media_type': 'tv',
            'name': '示例剧集',
            'first_air_date': '2024-01-01',
            'poster_path': '/p.jpg',
            'character': '主角',
          },
          {
            'id': 1399,
            'media_type': 'tv',
            'name': '示例剧集',
            'first_air_date': '2024-01-01',
            'poster_path': '/p.jpg',
            'character': '主角',
          },
          {
            'id': 550,
            'media_type': 'movie',
            'title': '示例电影',
            'release_date': '2019-10-15',
            'job': 'Director',
            'department': 'Directing',
          },
          {'id': 0, 'name': ''},
        ],
        image: TmdbImageSelector.image,
        imageBase: _imageBase,
        backdropBase: _backdropBase,
      );
      expect(works, hasLength(2), reason: '同一身份只保留一条');
      expect(works[0].item.title, '示例剧集');
      expect(works[0].subtitle, contains('饰 主角'));
      expect(works[0].item.posterUrl, '$_imageBase/p.jpg');
      expect(works[1].subtitle, contains('Director'));
      expect(works[1].isCast, isFalse);
    });
  });
}
