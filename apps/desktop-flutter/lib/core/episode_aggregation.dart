import 'protocol.dart';
import 'tmdb_title.dart' show parseChineseNumber;

class EpisodeFileSize {
  const EpisodeFileSize({required this.label, required this.bytes});

  final String label;
  final double bytes;

  static EpisodeFileSize? parse(String input) {
    final tokens = _sizeTokens(input);
    return tokens.length == 1 ? tokens.single.size : null;
  }

  static String strip(String input) {
    final tokens = _sizeTokens(input);
    if (tokens.isEmpty) return input;
    var text = input;
    for (final token in tokens.reversed) {
      text = text.replaceRange(token.start, token.end, '');
    }
    return text
        .replaceAll(RegExp(r'\[\s*\]|【\s*】|\(\s*\)|（\s*）'), '')
        .replaceAllMapped(RegExp(r'\s+([\]】)）])'), (match) => match.group(1)!)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

final _sizePattern = RegExp(
  r'(?<![a-zA-Z0-9.+-])(\d+(?:\.\d+)?)\s*(KiB|MiB|GiB|TiB|KB|MB|GB|TB|M|G|T)(?![a-zA-Z0-9])',
  caseSensitive: false,
);

List<({int start, int end, EpisodeFileSize size})> _sizeTokens(String input) {
  final tokens = <({int start, int end, EpisodeFileSize size})>[];
  for (final match in _sizePattern.allMatches(input)) {
    if (RegExp(
      r'^\s*/\s*s',
      caseSensitive: false,
    ).hasMatch(input.substring(match.end))) {
      continue;
    }
    final value = double.tryParse(match.group(1)!);
    if (value == null || !value.isFinite || value <= 0) continue;
    final rawUnit = match.group(2)!.toUpperCase();
    final unit = switch (rawUnit) {
      'M' => 'MB',
      'G' => 'GB',
      'T' => 'TB',
      'KIB' => 'KiB',
      'MIB' => 'MiB',
      'GIB' => 'GiB',
      'TIB' => 'TiB',
      _ => rawUnit,
    };
    final bytes = value * _sizeUnits[unit]!;
    if (!bytes.isFinite) continue;
    tokens.add((
      start: match.start,
      end: match.end,
      size: EpisodeFileSize(label: '${_number(value)} $unit', bytes: bytes),
    ));
  }
  return tokens;
}

const _sizeUnits = <String, double>{
  'KB': 1e3,
  'MB': 1e6,
  'GB': 1e9,
  'TB': 1e12,
  'KiB': 1024,
  'MiB': 1048576,
  'GiB': 1073741824,
  'TiB': 1099511627776,
};

String _number(double value) =>
    value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

class EpisodeVersion {
  const EpisodeVersion({
    required this.episode,
    required this.sourceIndex,
    this.fileSize,
  });

  final VodEpisode episode;
  final int sourceIndex;
  final EpisodeFileSize? fileSize;

  String get label => _profile(episode.name).values.join(' · ');
}

class EpisodeGroup {
  EpisodeGroup({
    required this.key,
    required this.seasonNumber,
    required this.episodeNumber,
    required List<EpisodeVersion> versions,
  }) : versions = List.unmodifiable(versions);

  final String key;
  final int seasonNumber;
  final int episodeNumber;
  final List<EpisodeVersion> versions;

  bool get isMultiple => versions.length > 1;

  String get label {
    if (episodeNumber <= 0) {
      return versions.isEmpty
          ? ''
          : EpisodeFileSize.strip(versions.first.episode.name);
    }
    final base = seasonNumber >= 0
        ? 'S${seasonNumber}E$episodeNumber'
        : '第$episodeNumber集';
    final part = versions.isEmpty
        ? ''
        : _contentPart(versions.first.episode.name);
    return part.isEmpty ? base : '$base $part';
  }

  String get sizeSummary {
    final sizes = versions
        .map((v) => v.fileSize)
        .whereType<EpisodeFileSize>()
        .toList();
    if (sizes.isEmpty) return '';
    if (sizes.length != versions.length) return '大小不全';
    if (sizes.length == 1) return sizes.single.label;
    var min = sizes.first.bytes;
    var max = min;
    for (final size in sizes.skip(1)) {
      if (size.bytes < min) min = size.bytes;
      if (size.bytes > max) max = size.bytes;
    }
    final units = sizes.map((s) => s.label.split(' ').last).toSet();
    final unit = units.length == 1
        ? units.single
        : max >= 1e12
        ? 'TB'
        : max >= 1e9
        ? 'GB'
        : max >= 1e6
        ? 'MB'
        : 'KB';
    final scale = _sizeUnits[unit]!;
    final low = _number(min / scale);
    final high = _number(max / scale);
    return min == max ? '$low $unit' : '$low–$high $unit';
  }
}

abstract final class EpisodeAggregation {
  static List<EpisodeGroup> build(
    List<VodEpisode> episodes, {
    String scope = '',
    List<int>? sourceIndices,
  }) {
    final grouped = <String, List<EpisodeVersion>>{};
    final identities = <String, ({int season, int episode})>{};
    for (var i = 0; i < episodes.length; i++) {
      final episode = episodes[i];
      final sourceIndex = sourceIndices != null && i < sourceIndices.length
          ? sourceIndices[i]
          : i;
      final identity = _identity(episode);
      var key = identity == null
          ? '$scope|unknown:$sourceIndex'
          : '$scope|S${identity.season}E${identity.episode}|${_contentPart(episode.name)}';
      if (identity == null && grouped.containsKey(key)) {
        key = '$key:$i';
      }
      identities[key] =
          identity ?? (season: _explicitSeason(episode.name), episode: 0);
      (grouped[key] ??= []).add(
        EpisodeVersion(
          episode: episode,
          sourceIndex: sourceIndex,
          fileSize: EpisodeFileSize.parse(episode.name),
        ),
      );
    }
    return List.unmodifiable([
      for (final entry in grouped.entries)
        EpisodeGroup(
          key: entry.key,
          seasonNumber: identities[entry.key]!.season,
          episodeNumber: identities[entry.key]!.episode,
          versions: entry.value,
        ),
    ]);
  }

  static EpisodeVersion? preferredVersion(
    EpisodeGroup group,
    VodEpisode previous,
  ) {
    final previousFeatures = _versionFeatures(previous.name);
    if (previousFeatures == null) return null;
    final previousProfile = previousFeatures.profile;
    final previousEdition = _edition(previous, previousFeatures.remainder);
    if (previousEdition.conflicting) return null;
    if (previousProfile.isEmpty && previousEdition.key == null) return null;
    EpisodeVersion? selected;
    for (final version in group.versions) {
      final features = _versionFeatures(version.episode.name);
      if (features == null) continue;
      final edition = _edition(version.episode, features.remainder);
      if (edition.conflicting ||
          (previousEdition.key != null && edition.key != previousEdition.key)) {
        continue;
      }
      final profile = features.profile;
      if (!previousProfile.entries.every((e) => profile[e.key] == e.value)) {
        continue;
      }
      if (selected != null) return null;
      selected = version;
    }
    return selected;
  }

  static EpisodeGroup? adjacentGroup(
    List<EpisodeGroup> groups, {
    required int currentSourceIndex,
    required int direction,
    bool stayInSeason = true,
  }) {
    if ((direction != -1 && direction != 1) || currentSourceIndex < 0) {
      return null;
    }
    final current = groups.indexWhere(
      (g) => g.versions.any((v) => v.sourceIndex == currentSourceIndex),
    );
    if (current < 0) return null;
    final target = current + direction;
    if (target < 0 || target >= groups.length) return null;
    if (stayInSeason &&
        groups[current].seasonNumber != groups[target].seasonNumber) {
      return null;
    }
    return groups[target];
  }
}

({int season, int episode})? _identity(VodEpisode episode) {
  final text = EpisodeFileSize.strip(episode.name)
      .replaceFirst(
        RegExp(
          r'\.(?:mkv|mp4|avi|ts|m2ts|mov|wmv|flv|webm|m4v)$',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  if (_ancillary.hasMatch(text) || _parts(text).length > 1) return null;
  final numbers = <int>{};
  final seasons = <int>{};
  for (final match in _seasonEpisode.allMatches(text)) {
    seasons.add(int.parse(match.group(1)!));
    numbers.add(int.parse(match.group(2)!));
  }
  for (final match in _chineseEpisode.allMatches(text)) {
    final number = parseChineseNumber(match.group(1)!);
    if (number != null) numbers.add(number);
  }
  for (final match in _englishEpisode.allMatches(text)) {
    numbers.add(int.parse(match.group(1)!));
  }
  for (final match in _season.allMatches(text)) {
    final number = parseChineseNumber(
      match.group(1) ?? match.group(2) ?? match.group(3)!,
    );
    if (number != null) seasons.add(number);
  }
  if (RegExp(r'^\d{1,3}$').hasMatch(text)) {
    final number = int.parse(text);
    if (!const {480, 576, 720}.contains(number)) numbers.add(number);
  }
  if (numbers.length > 1 ||
      seasons.length > 1 ||
      _episodeRange.hasMatch(text)) {
    return null;
  }
  final sourceNumber = numbers.length == 1 ? numbers.single : 0;
  if (sourceNumber < 0) return null;
  final sourceSeason = seasons.isEmpty ? -1 : seasons.single;
  final extra = episode.extra;
  if (extra['episode_identity_confirmed'] == true) {
    final season = extra['tmdb_season_number'];
    final number = extra['tmdb_episode_number'];
    if (season is! int || season < 0 || number is! int || number <= 0) {
      return null;
    }
    if ((numbers.isNotEmpty && sourceNumber != number) ||
        (sourceSeason >= 0 && sourceSeason != season)) {
      return null;
    }
    return (season: season, episode: number);
  }
  if (sourceNumber <= 0) return null;
  return (season: sourceSeason, episode: sourceNumber);
}

int _explicitSeason(String name) {
  final seasons = <int>{};
  for (final match in _season.allMatches(EpisodeFileSize.strip(name))) {
    final number = parseChineseNumber(
      match.group(1) ?? match.group(2) ?? match.group(3)!,
    );
    if (number != null) seasons.add(number);
  }
  return seasons.length == 1 ? seasons.single : -1;
}

final _seasonEpisode = RegExp(
  r'(?<![a-z0-9])s(\d{1,2})[-._\s]*e(\d{1,3})(?!\d)',
  caseSensitive: false,
);
final _chineseEpisode = RegExp(r'第\s*([0-9零〇一二三四五六七八九十两百]+)\s*[集话話回期章节節]');
final _englishEpisode = RegExp(
  r'(?<![a-z])(?:episode|ep|e)\s*(\d{1,3})(?!\d)',
  caseSensitive: false,
);
final _season = RegExp(
  r'第\s*([0-9零〇一二三四五六七八九十两百]+)\s*[季部]|\bseason\s*(\d{1,2})(?!\d)|(?<![a-z0-9])s(\d{1,2})(?!\d)',
  caseSensitive: false,
);
final _episodeRange = RegExp(
  r'(?:第\s*\d+\s*[-~至到/]\s*\d+\s*[集话話]|(?:(?:episode|ep|e)\s*\d+|第\d+集)\s*[-~至到&+/]\s*(?:(?:episode|ep|e)?\s*\d+|第\d+集))',
  caseSensitive: false,
);
final _ancillary = RegExp(
  r'预告|預告|花絮|特典|番外|彩蛋|采访|採訪|制作特辑|製作特輯|(?<![a-z0-9])(?:trailer|preview|extra|featurette|teaser|behind[ ._-]the[ ._-]scenes|op|ed|opening|ending)(?![a-z0-9])',
  caseSensitive: false,
);

String _contentPart(String text) => _parts(text).join(' ');

Set<String> _parts(String text) {
  text = text
      .replaceAll(RegExp(r'[【「『〔［]'), '[')
      .replaceAll(RegExp(r'[】」』〕］]'), ']');
  final parts = <String>{};
  for (final match in _seasonEpisode.allMatches(text)) {
    final suffix = RegExp(
      r'^([上中下])(?=$|[\s._\-\[\]()（）]|(?:480|576|720|1080|2160|4320)[pi](?![a-z0-9])|(?:4k|8k|uhd|fhd)(?![a-z0-9]))',
      caseSensitive: false,
    ).firstMatch(text.substring(match.end));
    if (suffix != null) {
      parts.add(switch (suffix.group(1)!) {
        '上' => '上篇',
        '中' => '中篇',
        _ => '下篇',
      });
    }
  }
  for (final row in <(RegExp, String)>[
    (
      RegExp(
        r'上(?:篇|部|半)|[（(\[]\s*上\s*[）)\]]|[集话話]\s*上|(?:^|[\s._-])上(?:$|[\s._-])',
      ),
      '上篇',
    ),
    (
      RegExp(
        r'中(?:篇|部)|[（(\[]\s*中\s*[）)\]]|[集话話]\s*中|(?:^|[\s._-])中(?:$|[\s._-])',
      ),
      '中篇',
    ),
    (
      RegExp(
        r'下(?:篇|部|半)|[（(\[]\s*下\s*[）)\]]|[集话話]\s*下|(?:^|[\s._-])下(?:$|[\s._-])',
      ),
      '下篇',
    ),
  ]) {
    if (row.$1.hasMatch(text)) parts.add(row.$2);
  }
  for (final match in RegExp(
    r'(?<![a-z0-9])(?:part|pt|cd|disc)\s*[._-]?\s*(\d+|[ivxlcdm]+|[a-z])(?![a-z0-9])',
    caseSensitive: false,
  ).allMatches(text)) {
    final raw = match.group(1)!;
    parts.add('Part ${int.tryParse(raw) ?? raw.toUpperCase()}');
  }
  return parts;
}

Map<String, String> _profile(String name) =>
    _versionFeatures(name)?.profile ?? const {};

({String? key, bool conflicting}) _edition(
  VodEpisode episode,
  String remainder,
) {
  final markers =
      [
        ..._seasonEpisode.allMatches(remainder),
        ..._chineseEpisode.allMatches(remainder),
        ..._englishEpisode.allMatches(remainder),
      ]..sort((a, b) {
        final position = a.start.compareTo(b.start);
        return position != 0 ? position : b.end.compareTo(a.end);
      });
  final prefix = markers.isEmpty
      ? ''
      : _editionLabel(
          remainder.substring(0, markers.first.start).replaceAll(_season, ''),
        );
  final explicit = RegExp(
    r'(?:^|[\s._\-\[\]【】()（）])((?:番综|番綜|特别版|特別版|正片))(?=$|[\s._\-\[\]【】()（）])',
  ).allMatches(remainder).map((match) => _editionLabel(match.group(1)!)).toSet();
  if (const {'正片', '番综', '特别版'}.contains(prefix)) explicit.add(prefix);
  if (explicit.length > 1) return (key: null, conflicting: true);
  if (_identity(episode) == null) return (key: null, conflicting: false);
  if (markers.isEmpty) {
    return (
      key: RegExp(r'^\d{1,3}$').hasMatch(EpisodeFileSize.strip(episode.name))
          ? ''
          : null,
      conflicting: false,
    );
  }
  // 集号后的自由标题不参与匹配；显式版别先验冲突，再归一正片。
  final labels = {
    if (prefix.isNotEmpty && prefix != '正片') prefix,
    ...explicit.where((label) => label != '正片'),
  };
  return (key: labels.join('|'), conflicting: false);
}

String _editionLabel(String text) {
  final label = text
      .replaceAll(RegExp(r'[\s._\-\[\]【】()（）]+'), '')
      .replaceAll('番綜', '番综')
      .replaceAll('特別版', '特别版')
      .toLowerCase();
  return label;
}

({Map<String, String> profile, String remainder})? _versionFeatures(
  String name,
) {
  final text = EpisodeFileSize.strip(name);
  final profile = <String, String>{};
  final recognized = <RegExp>[];
  var ambiguous = false;
  void feature(String field, List<(RegExp, String)> patterns) {
    final found = <String>{};
    for (final row in patterns) {
      recognized.add(row.$1);
      if (row.$1.hasMatch(text)) found.add(row.$2);
    }
    if (found.length == 1) profile[field] = found.single;
    if (found.length > 1) ambiguous = true;
  }

  RegExp token(String value) =>
      RegExp('(?<![a-z0-9])(?:$value)(?![a-z0-9])', caseSensitive: false);
  feature('resolution', [
    (token('480p'), '480p'),
    (token('720p'), '720p'),
    (token('1080[pi]|full[ ._-]?hd|fhd'), '1080p'),
    (token('2160p|4k|uhd'), '2160p'),
    (token('4320p|8k'), '4320p'),
  ]);
  feature('codec', [
    (token(r'h[._-]?264|x264|avc'), 'H.264'),
    (token(r'h[._-]?265|x265|hevc'), 'H.265'),
    (token('av1'), 'AV1'),
  ]);
  feature('dynamicRange', [
    (token(r'hdr10\+|hdr10plus'), 'HDR10+'),
    (token(r'hdr10(?!\+)'), 'HDR10'),
    (token('hdr'), 'HDR'),
    (token(r'dv|dolby[ ._-]?vision'), 'Dolby Vision'),
    (token('sdr'), 'SDR'),
  ]);
  feature('source', [
    (token(r'web[ ._-]?dl'), 'WEB-DL'),
    (token(r'web[ ._-]?rip'), 'WEBRip'),
    (token(r'bluray|blu[ ._-]?ray|bdrip'), 'BluRay'),
  ]);
  feature('packaging', [(token('remux'), 'REMUX')]);
  RegExp language(String chinese, String english) => RegExp(
    '(?:$chinese)|(?<![a-z0-9])(?:$english)(?![a-z0-9])',
    caseSensitive: false,
  );
  feature('language', [
    (language('国语|國語|普通话|普通話', 'mandarin'), '国语'),
    (language('粤语|粵語', 'cantonese'), '粤语'),
    (language('日语|日語', 'japanese|jpn'), '日语'),
    (language('英语|英語', 'english|eng'), '英语'),
    (language('韩语|韓語', 'korean|kor'), '韩语'),
    (language('法语|法語', 'french|fra'), '法语'),
    (language('德语|德語', 'german|deu'), '德语'),
    (language('西班牙语|西班牙語', 'spanish|spa'), '西班牙语'),
    (language('俄语|俄語', 'russian|rus'), '俄语'),
    (language('泰语|泰語', 'thai'), '泰语'),
    (language('台语|台語|闽南语|閩南語', 'hokkien'), '闽南语'),
  ]);
  if (RegExp(
    r'双语|雙語|多语|多語|双音轨|雙音軌|多音轨|多音軌|\b(?:dual|multi)[ ._-]*audio\b',
    caseSensitive: false,
  ).hasMatch(text)) {
    ambiguous = true;
  }
  final revisionPattern = RegExp(
    r'(?<![a-z0-9])v(?:er(?:sion)?)?[ ._-]?(\d{1,2})(?![a-z0-9])',
    caseSensitive: false,
  );
  recognized.add(revisionPattern);
  final revisions = revisionPattern
      .allMatches(text)
      .map((match) => int.parse(match.group(1)!))
      .toSet();
  if (revisions.length == 1) profile['revision'] = 'v${revisions.single}';
  if (revisions.length > 1) ambiguous = true;
  final releasePattern = RegExp(
    r'-([a-z][a-z0-9]{1,23})\.(?:mkv|mp4|avi|ts|m2ts|mov|webm)$',
    caseSensitive: false,
  );
  final release = releasePattern.firstMatch(text);
  if (release != null) {
    final name = release.group(1)!.toUpperCase();
    if (!const {
      'DL',
      'RIP',
      'WEBRIP',
      'BLURAY',
      'REMUX',
      'HDR',
      'HDR10',
      'SDR',
      'AVC',
      'HEVC',
      'AV1',
      'X264',
      'X265',
      'H264',
      'H265',
    }.contains(name)) {
      profile['release'] = name;
      recognized.add(releasePattern);
    }
  }
  if (ambiguous) return null;
  var remainder = text;
  for (final pattern in recognized) {
    remainder = remainder.replaceAll(pattern, ' ');
  }
  return (profile: profile, remainder: remainder);
}
