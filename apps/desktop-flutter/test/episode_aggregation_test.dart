import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/episode_aggregation.dart';
import 'package:webhtv_pc/core/protocol.dart';

VodEpisode episode(
  String name, {
  String? url,
  Map<String, Object?> extra = const {},
}) => VodEpisode(name: name, url: url ?? name, extra: extra);

void main() {
  group('file sizes', () {
    for (final row in <(String, double, String)>[
      ('[5.37G] 01.mkv', 5370000000, '5.37 GB'),
      ('(1.2 TB) Episode 03', 1200000000000, '1.2 TB'),
      ('E01 [700MB]', 700000000, '700 MB'),
      ('E01 [2GiB]', 2147483648, '2 GiB'),
      ('E01 [1.5MiB]', 1572864, '1.5 MiB'),
      ('E01 [2KiB]', 2048, '2 KiB'),
      ('E01 [1KB]', 1000, '1 KB'),
      ('E01 [2M]', 2000000, '2 MB'),
      ('E01 [0.5T]', 500000000000, '0.5 TB'),
    ]) {
      test('parses ${row.$1}', () {
        final size = EpisodeFileSize.parse(row.$1);
        expect(size, isNotNull);
        expect(size!.bytes, row.$2);
        expect(size.label, row.$3);
      });
    }
    for (final name in [
      '1080p 2024',
      '剧名',
      'S01E02 10Mbps',
      'S01E02 2MB/s',
      'S01E02 2GBps',
      'S01E02 2 Mb/s',
      'S01E02 2mbps',
      'S01E02 -2GB',
      'S01E02 [0GB]',
    ]) {
      test('does not treat $name as file size', () {
        expect(EpisodeFileSize.parse(name), isNull);
        expect(EpisodeFileSize.strip(name), name);
      });
    }
    test('strips only valid size tokens and their empty brackets', () {
      expect(EpisodeFileSize.strip('[5.37G] 01.mkv'), '01.mkv');
      expect(EpisodeFileSize.strip('(1.2 TB) Episode 03'), 'Episode 03');
      expect(EpisodeFileSize.strip('S01E01.1080p [1GB]'), 'S01E01.1080p');
      expect(EpisodeFileSize.strip('第1集 [1080p 1GB]'), '第1集 [1080p]');
    });
  });

  group('identity and conservation', () {
    test('groups explicit season episode and reports a range not a total', () {
      final first = episode('S01E01.1080p [1GB]', url: 'original-a');
      final second = episode('S01E01.2160p [3GB]', url: 'original-b');
      final groups = EpisodeAggregation.build([first, second]);
      expect(groups, hasLength(1));
      expect(groups.single.label, 'S1E1');
      expect(groups.single.seasonNumber, 1);
      expect(groups.single.episodeNumber, 1);
      expect(groups.single.isMultiple, isTrue);
      expect(groups.single.versions.map((v) => v.sourceIndex), [0, 1]);
      expect(groups.single.versions.first.episode, same(first));
      expect(groups.single.versions.last.episode, same(second));
      expect(groups.single.sizeSummary, '1–3 GB');
      expect(groups.single.versions.first.fileSize!.label, '1 GB');
      expect(groups.single.versions.first.label, contains('1080p'));
    });
    test(
      'strips sizes and media extensions before numeric identity parsing',
      () {
        final groups = EpisodeAggregation.build([
          episode('[5.37G] 01.mkv'),
          episode('[1.2G] 01.mp4'),
          episode('(1.2 TB) Episode 03'),
          episode('EP03 [800MB]'),
        ]);
        expect(groups.map((g) => g.versions.length), [2, 2]);
        expect(groups.map((g) => g.episodeNumber), [1, 3]);
        expect(groups.first.label, '第1集');
      },
    );
    test(
      'preserves first appearance, original source indices and immutability',
      () {
        final episodes = [
          episode('第2集 1080p'),
          episode('第1集'),
          episode('第2集 2160p'),
        ];
        final groups = EpisodeAggregation.build(
          episodes,
          sourceIndices: [7, 4, 9],
          scope: 'line-a',
        );
        expect(groups.map((g) => g.episodeNumber), [2, 1]);
        expect(groups.first.versions.map((v) => v.sourceIndex), [7, 9]);
        expect(groups.last.versions.single.episode, same(episodes[1]));
        expect(() => groups.clear(), throwsUnsupportedError);
        expect(() => groups.first.versions.clear(), throwsUnsupportedError);
        episodes.clear();
        expect(groups.first.versions, hasLength(2));
        expect(
          EpisodeAggregation.build([
            episode('第2集'),
          ], scope: 'line-b').single.key,
          isNot(groups.first.key),
        );
      },
    );
    test(
      'unknown names, guessed extras and equal display titles remain separate',
      () {
        final extras = {
          'tmdb_season_number': 1,
          'tmdb_episode_number': 1,
          'display_name': '同名',
        };
        final groups = EpisodeAggregation.build([
          episode('文件甲', extra: extras),
          episode('文件乙', extra: extras),
          episode('同名'),
          episode('同名'),
          episode('1080p'),
          episode('2024'),
          episode('2160'),
          episode('720'),
          episode('[1GB]'),
          episode('1080'),
        ]);
        expect(groups, hasLength(10));
        expect(
          groups.every((g) => g.episodeNumber == 0 && !g.isMultiple),
          isTrue,
        );
        expect(groups.map((g) => g.key).toSet(), hasLength(10));
      },
    );
    test('different seasons, parts, previews and extras cannot merge', () {
      final groups = EpisodeAggregation.build([
        episode('S01E01'),
        episode('S02E01'),
        episode('第1集 上篇'),
        episode('第1集 下篇'),
        episode('第1集 预告'),
        episode('第1集 花絮'),
        episode('第1集 Part 1'),
        episode('第1集 Part 2'),
        episode('第1集'),
      ]);
      expect(groups, hasLength(9));
      expect(groups[2].label, contains('上'));
      expect(groups[3].label, contains('下'));
    });
    test('ambiguous episode tokens and ranges stay independent', () {
      final groups = EpisodeAggregation.build([
        episode('S01E01E02 1080p'),
        episode('S01E01E02 2160p'),
        episode('第1-2集'),
        episode('第1-2集'),
        episode('S01E01 第2集'),
        episode('S01E01 第2集'),
        episode('S01E01-E02'),
        episode('S01E01-E02'),
      ]);
      expect(groups, hasLength(8));
      expect(groups.every((g) => !g.isMultiple), isTrue);
    });
    test(
      'only literal confirmed AI identity can group otherwise unknown files',
      () {
        final extra = {
          'episode_identity_confirmed': true,
          'tmdb_season_number': 0,
          'tmdb_episode_number': 2,
        };
        final groups = EpisodeAggregation.build([
          episode('文件甲', extra: extra),
          episode('文件乙', extra: extra),
          episode(
            '文件丙',
            extra: {...extra, 'episode_identity_confirmed': 'true'},
          ),
        ]);
        expect(groups.map((g) => g.versions.length), [2, 1]);
        expect(groups.first.label, 'S0E2');
      },
    );
    test(
      'conflicting explicit and confirmed identities remain independent',
      () {
        final extra = {
          'episode_identity_confirmed': true,
          'tmdb_season_number': 2,
          'tmdb_episode_number': 3,
        };
        final groups = EpisodeAggregation.build([
          episode('S01E03 1080p', extra: extra),
          episode('S01E03 2160p', extra: extra),
          episode('S02E03 1080p'),
          episode('S02E03 2160p'),
        ]);
        expect(groups.map((g) => g.versions.length), [1, 1, 2]);
      },
    );
  });

  group('size summaries', () {
    for (final row in <(List<String>, String)>[
      (['第1集 [1GB]', '第1集 [1000MB]'], '1 GB'),
      (['第1集 [1GiB]', '第1集 [2GB]'], '1.07–2 GB'),
      (['第1集 [1GB]', '第1集'], '大小不全'),
      (['第1集', '第1集'], ''),
      (['第1集 [750MB]'], '750 MB'),
    ]) {
      test('summarizes ${row.$1}', () {
        expect(
          EpisodeAggregation.build(row.$1.map(episode).toList())
              .single
              .sizeSummary,
          row.$2,
        );
      });
    }
  });

  group('preferred version', () {
    test('single version returns original despite empty prior profile', () {
      final next = episode('第2集');
      final group = EpisodeAggregation.build([next]).single;
      expect(
        EpisodeAggregation.preferredVersion(group, episode('第1集'))!.episode,
        same(next),
      );
    });
    test('requires unique match of every reliable previous feature', () {
      final group = EpisodeAggregation.build([
        episode('S01E02 1080p HEVC HDR10 WEB-DL [1GB]'),
        episode('S01E02 2160p HEVC HDR10 WEB-DL [2GB]'),
        episode('S01E02 1080p AVC HDR10 WEB-DL [3GB]'),
      ]).single;
      final previous = episode('S01E01 1080p x265 HDR10 WEB-DL [8GB]');
      expect(
        EpisodeAggregation.preferredVersion(group, previous)!.sourceIndex,
        0,
      );
      expect(
        EpisodeAggregation.preferredVersion(
          group,
          episode('S01E01 1080p HEVC Dolby Vision WEB-DL'),
        ),
        isNull,
      );
    });
    test(
      'empty profile, size, order, or duplicate matches cannot auto-select',
      () {
        final group = EpisodeAggregation.build([
          episode('第2集 1080p [1GB]'),
          episode('第2集 1080p [3GB]'),
        ]).single;
        expect(
          EpisodeAggregation.preferredVersion(
            group,
            episode('第1集 1080p [1GB]'),
          ),
          isNull,
        );
        expect(
          EpisodeAggregation.preferredVersion(group, episode('第1集 [3GB]')),
          isNull,
        );
        expect(group.versions.every((v) => v.label == '1080p'), isTrue);
      },
    );
    test('missing candidate fields do not satisfy a previous full profile', () {
      final group = EpisodeAggregation.build([
        episode('第2集 1080p'),
        episode('第2集 2160p HEVC'),
      ]).single;
      expect(
        EpisodeAggregation.preferredVersion(group, episode('第1集 1080p HEVC')),
        isNull,
      );
    });
  });

  group('compound language boundaries', () {
    test(
      'joined language mismatch does not select a same-resolution candidate',
      () {
        final group = EpisodeAggregation.build([
          episode('S01E02.1080p粤语.mkv', url: 'wrong'),
          episode('S01E02.2160p国语.mkv', url: 'other'),
        ]).single;
        expect(
          EpisodeAggregation.preferredVersion(
            group,
            episode('S01E01.1080p国语.mkv', url: 'old'),
          ),
          isNull,
        );
      },
    );
    for (final row in <(String, String)>[
      ('国语', 'Mandarin'),
      ('國語', 'Mandarin'),
      ('普通话', 'Mandarin'),
      ('普通話', 'Mandarin'),
      ('粤语', 'Cantonese'),
      ('粵語', 'Cantonese'),
      ('日语', 'Japanese'),
      ('日語', 'Japanese'),
      ('英语', 'English'),
      ('英語', 'English'),
      ('韩语', 'Korean'),
      ('韓語', 'Korean'),
    ]) {
      test(
        'Chinese alias ${row.$1} remains reliable beside ASCII features',
        () {
          final group = EpisodeAggregation.build([
            episode('S01E02.1080p.${row.$2}.mkv'),
            episode('S01E02.1080p.法语.mkv'),
          ]).single;
          expect(
            EpisodeAggregation.preferredVersion(
              group,
              episode('S01E01.1080p${row.$1}.mkv'),
            )?.sourceIndex,
            0,
          );
          expect(
            EpisodeAggregation.preferredVersion(
              group,
              episode('S01E01.${row.$1}1080p.mkv'),
            )?.sourceIndex,
            0,
          );
        },
      );
    }
    test('joined Chinese language labels remain ambiguous', () {
      final group = EpisodeAggregation.build([
        episode('S01E02.1080p粤语.mkv'),
        episode('S01E02.2160p国语.mkv'),
      ]).single;
      expect(
        EpisodeAggregation.preferredVersion(
          group,
          episode('S01E01.1080p国语粤语.mkv'),
        ),
        isNull,
      );
    });
    for (final embedded in [
      'xEnglish',
      'Englishx',
      'English2',
      'xMandarin',
      'Mandarin2',
    ]) {
      test('English aliases keep strict word guards for $embedded', () {
        final group = EpisodeAggregation.build([
          episode('S01E02.1080p.$embedded.mkv'),
          episode('S01E02.2160p.English.mkv'),
        ]).single;
        final prior = embedded.contains('Mandarin') ? 'Mandarin' : 'English';
        expect(
          EpisodeAggregation.preferredVersion(
            group,
            episode('S01E01.1080p.$prior.mkv'),
          ),
          isNull,
        );
        expect(group.versions.first.label, '1080p');
      });
    }
  });

  group('language and release profile', () {
    test('different explicit language cannot match by resolution alone', () {
      final group = EpisodeAggregation.build([
        episode('S01E02.1080p.粤语'),
        episode('S01E02.2160p.国语'),
      ]).single;
      expect(
        EpisodeAggregation.preferredVersion(group, episode('S01E01.1080p.国语')),
        isNull,
      );
    });
    for (final row in <(String, String)>[
      ('国语', 'Mandarin'),
      ('粤语', 'Cantonese'),
      ('日语', 'Japanese'),
      ('英语', 'English'),
      ('韩语', 'Korean'),
    ]) {
      test('matches an explicit language alias ${row.$1}', () {
        final group = EpisodeAggregation.build([
          episode('S01E02 1080p ${row.$2}'),
          episode('S01E02 1080p 法语'),
        ]).single;
        expect(
          EpisodeAggregation.preferredVersion(
            group,
            episode('S01E01 1080p ${row.$1}'),
          )?.sourceIndex,
          0,
        );
        expect(group.versions.first.label, contains(row.$1));
      });
    }
    for (final marker in [
      '国语 粤语',
      '国粤双语',
      '国粤双音轨',
      'dual audio',
      'multi-audio',
    ]) {
      test('ambiguous audio $marker never partially matches', () {
        final group = EpisodeAggregation.build([
          episode('S01E02 1080p 国语'),
          episode('S01E02 2160p 英语'),
        ]).single;
        expect(
          EpisodeAggregation.preferredVersion(
            group,
            episode('S01E01 1080p $marker'),
          ),
          isNull,
        );
      });
    }
    test(
      'unknown candidate language does not fulfill known prior language',
      () {
        final group = EpisodeAggregation.build([
          episode('S01E02 1080p'),
          episode('S01E02 2160p 国语'),
        ]).single;
        expect(
          EpisodeAggregation.preferredVersion(
            group,
            episode('S01E01 1080p 国语'),
          ),
          isNull,
        );
      },
    );
    test('explicit release markers distinguish otherwise equal versions', () {
      final group = EpisodeAggregation.build([
        episode('S01E02.1080p.HEVC-GROUPA.mkv'),
        episode('S01E02.1080p.HEVC-GROUPB.mkv'),
      ]).single;
      expect(
        EpisodeAggregation.preferredVersion(
          group,
          episode('S01E01.1080p.HEVC-GROUPB.mkv'),
        )?.sourceIndex,
        1,
      );
      expect(group.versions.last.label, contains('GROUPB'));
    });
    test('explicit v2 cannot silently switch to v1 or unmarked version', () {
      final group = EpisodeAggregation.build([
        episode('S01E02.1080p.v1'),
        episode('S01E02.2160p.v2'),
      ]).single;
      expect(
        EpisodeAggregation.preferredVersion(group, episode('S01E01.1080p.v2')),
        isNull,
      );
    });
  });

  group('content identity separators', () {
    for (final separator in ['_', '.', '-']) {
      test('part numbers separated by $separator retain distinct content', () {
        final groups = EpisodeAggregation.build([
          episode('Show${separator}S01E01${separator}Part1${separator}1080p'),
          episode('Show${separator}S01E01${separator}Part2${separator}2160p'),
        ]);
        expect(groups, hasLength(2));
        expect(groups.map((g) => g.label), ['S1E1 Part 1', 'S1E1 Part 2']);
      });
      test(
        'same part separated by $separator retains alternative versions',
        () {
          final groups = EpisodeAggregation.build([
            episode('Show${separator}S01E01${separator}Part1${separator}1080p'),
            episode('Show${separator}S01E01${separator}Part1${separator}2160p'),
          ]);
          expect(groups, hasLength(1));
          expect(groups.single.versions, hasLength(2));
          expect(groups.single.label, 'S1E1 Part 1');
        },
      );
      test(
        'ancillary marker separated by $separator is not a full episode',
        () {
          final groups = EpisodeAggregation.build([
            episode('S01E01${separator}trailer${separator}1080p'),
            episode('S01E01${separator}2160p'),
          ]);
          expect(groups, hasLength(2));
        },
      );
      test('OP marker separated by $separator is not a full episode', () {
        final groups = EpisodeAggregation.build([
          episode('S01E01${separator}OP${separator}1080p'),
          episode('S01E01${separator}2160p'),
        ]);
        expect(groups, hasLength(2));
      });
    }
    test(
      'repeated identical episode signal is still an alternative version',
      () {
        final groups = EpisodeAggregation.build([
          episode('S01E01_S01E01_1080p'),
          episode('S01E01_2160p'),
        ]);
        expect(groups, hasLength(1));
        expect(groups.single.versions, hasLength(2));
      },
    );
  });

  group('content identity delimiters', () {
    for (final brackets in <(String, String)>[
      ('【', '】'),
      ('「', '」'),
      ('『', '』'),
      ('〔', '〕'),
      ('［', '］'),
      ('（', '）'),
      ('[', ']'),
      ('(', ')'),
    ]) {
      test(
        'Chinese part brackets ${brackets.$1}${brackets.$2} distinguish content',
        () {
          final groups = EpisodeAggregation.build([
            episode('第1集${brackets.$1}上${brackets.$2}1080p'),
            episode('第1集${brackets.$1}下${brackets.$2}2160p'),
          ]);
          expect(groups, hasLength(2));
          expect(groups.map((g) => g.versions.length), [1, 1]);
          expect(groups.first.label, '第1集 上篇');
          expect(groups.last.label, '第1集 下篇');
        },
      );
      test(
        'same bracketed part ${brackets.$1}${brackets.$2} still groups versions',
        () {
          final groups = EpisodeAggregation.build([
            episode('第1集${brackets.$1} 上 ${brackets.$2}1080p'),
            episode('第1集${brackets.$1} 上 ${brackets.$2}2160p'),
          ]);
          expect(groups, hasLength(1));
          expect(groups.single.versions, hasLength(2));
          expect(groups.single.label, '第1集 上篇');
        },
      );
    }
    test(
      'tight season episode part suffixes distinguish upper middle lower',
      () {
        final groups = EpisodeAggregation.build([
          episode('S01E01上.1080p'),
          episode('S01E01上.2160p'),
          episode('S01E01中.1080p'),
          episode('S01E01下.2160p'),
          episode('S01E02.1080p'),
        ]);
        expect(groups.map((g) => g.versions.length), [2, 1, 1, 1]);
        expect(groups.map((g) => g.label), [
          'S1E1 上篇',
          'S1E1 中篇',
          'S1E1 下篇',
          'S1E2',
        ]);
        expect(
          EpisodeAggregation.adjacentGroup(
            groups,
            currentSourceIndex: 1,
            direction: 1,
          ),
          same(groups[1]),
        );
        expect(
          EpisodeAggregation.adjacentGroup(
            groups,
            currentSourceIndex: 3,
            direction: -1,
          ),
          same(groups[1]),
        );
      },
    );
    test('bracketed next part remains reachable instead of skipping to next episode', () {
      final groups = EpisodeAggregation.build([
        episode('第1集【上】1080p'),
        episode('第1集【上】2160p'),
        episode('第1集【下】1080p'),
        episode('第2集1080p'),
      ]);
      expect(groups.map((g) => g.versions.length), [2, 1, 1]);
      expect(
        EpisodeAggregation.adjacentGroup(
          groups,
          currentSourceIndex: 0,
          direction: 1,
        )?.label,
        '第1集 下篇',
      );
    });
    for (final marker in ['OP', 'ED', 'opening', 'ending', 'op', 'ed']) {
      test('explicit $marker is not a main episode alternative', () {
        final groups = EpisodeAggregation.build([
          episode('第1集 $marker 1080p'),
          episode('第1集 正片2160p'),
        ]);
        expect(groups, hasLength(2));
        expect(groups.map((g) => g.versions.length), [1, 1]);
      });
    }
    test(
      'opening and ending word guards do not reject ordinary episode titles',
      () {
        final groups = EpisodeAggregation.build([
          episode('Episode 01 hoped 1080p'),
          episode('Episode 01 hoped 2160p'),
        ]);
        expect(groups, hasLength(1));
        expect(groups.single.versions, hasLength(2));
      },
    );
  });

  group('conservative edge cases', () {
    test(
      'unknown keys remain tied to original indices when view order changes',
      () {
        final first = episode('文件甲');
        final second = episode('文件乙');
        final forward = EpisodeAggregation.build(
          [first, second],
          sourceIndices: [5, 8],
        );
        final reverse = EpisodeAggregation.build(
          [second, first],
          sourceIndices: [8, 5],
        );
        expect(forward.first.key, reverse.last.key);
        expect(forward.last.key, reverse.first.key);
      },
    );
    test('contradictory part signals do not qualify as duplicates', () {
      final groups = EpisodeAggregation.build([
        episode('第1集 上篇 下篇 1080p'),
        episode('第1集 上篇 下篇 2160p'),
      ]);
      expect(groups, hasLength(2));
    });
    test('part suffixes and named parts remain distinct', () {
      final groups = EpisodeAggregation.build([
        episode('S01E01 上'),
        episode('S01E01 下'),
        episode('S01E01 Part A'),
        episode('S01E01 Part B'),
        episode('S01E01 Part I'),
        episode('S01E01 Part II'),
      ]);
      expect(groups, hasLength(6));
      expect(groups.every((g) => !g.isMultiple), isTrue);
      expect(groups[0].label, contains('上'));
      expect(groups[3].label, contains('Part B'));
    });
    test('tight part suffix followed by resolution remains distinct', () {
      final groups = EpisodeAggregation.build([
        episode('S01E01上1080p'),
        episode('S01E01下2160p'),
      ]);
      expect(groups, hasLength(2));
      expect(groups[0].label, contains('上'));
      expect(groups[1].label, contains('下'));
    });

    test('English episode ranges are not a single episode', () {
      final groups = EpisodeAggregation.build([
        episode('EP01-03 1080p'),
        episode('EP01-03 2160p'),
        episode('S01E01/02 1080p'),
        episode('S01E01/02 2160p'),
      ]);
      expect(groups, hasLength(4));
    });
    test(
      'explicit zero conflicts with confirmed positive episode identity',
      () {
        final extra = {
          'episode_identity_confirmed': true,
          'tmdb_season_number': 1,
          'tmdb_episode_number': 1,
        };
        final groups = EpisodeAggregation.build([
          episode('S01E00 1080p', extra: extra),
          episode('S01E00 2160p', extra: extra),
        ]);
        expect(groups, hasLength(2));
      },
    );
    test('strip leaves text without sizes unchanged', () {
      expect(EpisodeFileSize.strip('  第1集   10Mbps  '), '  第1集   10Mbps  ');
    });
    test('HDR and HDR10 are not interchangeable profiles', () {
      final group = EpisodeAggregation.build([
        episode('第2集 1080p HDR'),
        episode('第2集 2160p HDR10'),
      ]).single;
      expect(
        EpisodeAggregation.preferredVersion(group, episode('第1集 1080p HDR10')),
        isNull,
      );
    });
    test(
      'contradictory prior features cannot trigger a partial auto-match',
      () {
        final group = EpisodeAggregation.build([
          episode('第2集 1080p HEVC'),
          episode('第2集 2160p AVC'),
        ]).single;
        expect(
          EpisodeAggregation.preferredVersion(
            group,
            episode('第1集 1080p 2160p HEVC'),
          ),
          isNull,
        );
      },
    );
    test('packaging is retained alongside source in the match profile', () {
      final group = EpisodeAggregation.build([
        episode('第2集 1080p BluRay REMUX'),
        episode('第2集 1080p WEB-DL'),
      ]).single;
      expect(
        EpisodeAggregation.preferredVersion(
          group,
          episode('第1集 1080p BluRay REMUX'),
        )?.sourceIndex,
        0,
      );
      expect(group.versions.first.label, contains('BluRay'));
      expect(group.versions.first.label, contains('REMUX'));
    });
  });

  group('adjacency', () {
    final groups = EpisodeAggregation.build(
      [
        episode('S01E01 1080p'),
        episode('S01E01 2160p'),
        episode('S01E02 1080p'),
        episode('S01E02 2160p'),
        episode('S02E01'),
      ],
      sourceIndices: [10, 11, 20, 21, 30],
    );
    test(
      'skips variants forwards and backwards using original source index',
      () {
        expect(
          EpisodeAggregation.adjacentGroup(
            groups,
            currentSourceIndex: 10,
            direction: 1,
          )!.versions.first.sourceIndex,
          20,
        );
        expect(
          EpisodeAggregation.adjacentGroup(
            groups,
            currentSourceIndex: 21,
            direction: -1,
          )!.versions.first.sourceIndex,
          10,
        );
      },
    );
    test('rejects invalid direction, missing index and list boundaries', () {
      expect(
        EpisodeAggregation.adjacentGroup(
          groups,
          currentSourceIndex: 10,
          direction: 0,
        ),
        isNull,
      );
      expect(
        EpisodeAggregation.adjacentGroup(
          groups,
          currentSourceIndex: 10,
          direction: 2,
        ),
        isNull,
      );
      expect(
        EpisodeAggregation.adjacentGroup(
          groups,
          currentSourceIndex: -1,
          direction: 1,
        ),
        isNull,
      );
      expect(
        EpisodeAggregation.adjacentGroup(
          groups,
          currentSourceIndex: 999,
          direction: 1,
        ),
        isNull,
      );
      expect(
        EpisodeAggregation.adjacentGroup(
          groups,
          currentSourceIndex: 10,
          direction: -1,
        ),
        isNull,
      );
      expect(
        EpisodeAggregation.adjacentGroup(
          groups,
          currentSourceIndex: 30,
          direction: 1,
        ),
        isNull,
      );
    });
    test('unaggregated ancillary files retain explicit season boundaries', () {
      final ancillary = EpisodeAggregation.build([
        episode('S01E01 Trailer'),
        episode('S02E01 Trailer'),
      ]);
      expect(ancillary.map((g) => g.seasonNumber), [1, 2]);
      expect(
        EpisodeAggregation.adjacentGroup(
          ancillary,
          currentSourceIndex: 0,
          direction: 1,
        ),
        isNull,
      );
    });
    test('stops at season boundary unless explicitly allowed', () {
      expect(
        EpisodeAggregation.adjacentGroup(
          groups,
          currentSourceIndex: 20,
          direction: 1,
        ),
        isNull,
      );
      expect(
        EpisodeAggregation.adjacentGroup(
          groups,
          currentSourceIndex: 30,
          direction: -1,
        ),
        isNull,
      );
      expect(
        EpisodeAggregation.adjacentGroup(
          groups,
          currentSourceIndex: 20,
          direction: 1,
          stayInSeason: false,
        )!.seasonNumber,
        2,
      );
    });
  });
}
