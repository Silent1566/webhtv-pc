/// 外部兜底元数据 → 展示模型（TMDB 不可用时）。
///
/// 只做一件事：把豆瓣 / Bangumi 的原始 JSON 拼成详情页与人物页**已经在用**的
/// 形状（[TmdbDetailData] / [TmdbPerson] / [TmdbPersonWork]），从而让 UI 一行
/// 都不用为「数据来自哪家」分叉。
///
/// 关键契约（用户决策 2026-11-17）：
/// - 原始字段由管线选择，也可参与已匹配 TMDB 页面的逐字段解析；
/// - 外部作品一律 `TmdbItem(tmdbId: 0)`：`identity` 因此为 `null`，
///   任何"打开 TMDB 详情"的入口都会自然失效，不会拿着豆瓣 id 去请求 TMDB；
/// - 人物带上 [MetaPersonRef]，人物页据此决定用哪个客户端取简介/作品；
/// - 字段缺失就是缺失：**不补占位文案、不编评分**（`PRODUCT.md` 第 5 条）。
///
/// 这一层是**纯逻辑**：不依赖 Flutter、不依赖 `dart:io`、不发起请求。
library;

import 'external_meta.dart';
import 'meta_source.dart';
import 'protocol.dart';
import 'meta_pipeline.dart';
import 'source_meta_resolver.dart';
import 'tmdb_detail_model.dart';
import 'tmdb_identity.dart';
import 'tmdb_media.dart';

// ---------------------------------------------------------------------------
// §1 详情
// ---------------------------------------------------------------------------

/// 一次兜底详情：身份 + 可直接喂给 [TmdbDetailSections] 的展示数据。
class ExternalDetail {
  const ExternalDetail({
    required this.identity,
    required this.data,
    this.imdbId = '',
  });

  final MetaIdentity identity;
  final TmdbDetailData data;

  /// 该作品在 IMDb 的编号（`tt4574334`）；取不到为空串。
  ///
  /// 为什么要它：这是**确定性跨源映射**的唯一凭据。按标题猜会认错续作与翻拍，
  /// 而 IMDb 编号是全局唯一的，三家（豆瓣/Bangumi/TMDB）都能对上。
  final String imdbId;

  /// 展示用的来源名（`豆瓣` / `Bangumi`），供状态条标注真实出处。
  String get sourceLabel => identity.kind.label;

  TmdbDetailData forSource(Vod vod, {MetaPipeline? pipeline}) =>
      SourceMetaResolver.resolve(
        pipeline: pipeline ?? MetaPipeline.defaults,
        source: vod,
        providers: {identity.kind: data},
        primary: data,
      );
}

/// 原始载荷 → [ExternalDetail] 的适配器。
abstract final class ExternalDetailMeta {
  /// 豆瓣作品详情 + 演职员 → 详情数据。
  ///
  /// [subject] 是 `/rexxar/api/v2/{tv|movie}/{id}`，[credits] 是 `/credits` 的
  /// `items[]`。两者任一为空都能出数据（只有详情没有演职员也照样能渲染）。
  static ExternalDetail? douban({
    required MetaIdentity identity,
    required Map<String, Object?> subject,
    List<Map<String, Object?>> credits = const [],
  }) {
    if (subject.isEmpty) return null;
    final title = _text(subject, const ['title']);
    if (title.isEmpty) return null;

    final poster = _doubanCover(subject);
    final cast = <TmdbPerson>[];
    final crew = <TmdbPerson>[];
    for (final item in credits) {
      final person = _doubanCreditPerson(item);
      if (person == null) continue;
      if (_isCastCredit(item)) {
        cast.add(person);
      } else {
        crew.add(person);
      }
    }
    final directors = <String>[
      for (final raw in _list(subject['directors']))
        if (_text(_mapOf(raw), const ['name']) case final name
            when name.isNotEmpty)
          name,
    ];
    final writers = <String>[
      for (final person in crew)
        if (person.subtitle.contains('编剧')) person.name,
    ];

    return ExternalDetail(
      identity: identity,
      imdbId: _imdbOf(subject),
      data: TmdbDetailData(
        mediaType: identity.mediaType,
        title: title,
        originalTitle: _text(subject, const ['original_title']),
        overview: _nullIfEmpty(_text(subject, const ['intro'])),
        posterUrl: poster.isEmpty ? null : poster,
        // 豆瓣不提供横版剧照：用海报当唯一背景，至少不是空白页。
        backdropUrls: [if (poster.isNotEmpty) poster],
        posterUrls: [if (poster.isNotEmpty) poster],
        cast: cast,
        crew: crew,
        creatorTeam: crew,
        directors: directors,
        writers: writers,
        genres: _strings(subject['genres']),
        countries: _strings(subject['countries']),
        languages: _strings(subject['languages']),
        rating: _doubanRating(subject),
        ratingSourceLabel: identity.kind.label,
        releaseDate: _doubanDate(subject),
        runtime: _minutesOf(_first(subject['durations'])),
        episodeCount: _int(subject['episodes_count']) ?? 0,
      ),
    );
  }

  /// Bangumi 作品详情 + 演职员 → 详情数据。
  ///
  /// [subject] 是 `/v0/subjects/{id}`，[persons] 是 `/v0/subjects/{id}/persons`
  /// 的裸数组。Bangumi 的结构化字段几乎都在 `infobox` 里（键值对列表），
  /// 因此这里先把 infobox 摊成 Map 再取值。
  static ExternalDetail? bangumi({
    required MetaIdentity identity,
    required Map<String, Object?> subject,
    List<Map<String, Object?>> persons = const [],
  }) {
    if (subject.isEmpty) return null;
    final info = _bangumiInfobox(subject);
    final nameCn = _text(subject, const ['name_cn']);
    final name = _text(subject, const ['name']);
    final title = nameCn.isNotEmpty ? nameCn : name;
    if (title.isEmpty) return null;

    final cast = <TmdbPerson>[];
    final crew = <TmdbPerson>[];
    for (final person in persons) {
      final mapped = _bangumiPerson(person);
      if (mapped == null) continue;
      final relation = _text(person, const ['relation']);
      if (_bangumiCastRelations.any(relation.contains)) {
        cast.add(mapped);
      } else {
        crew.add(mapped);
      }
    }
    if (cast.isEmpty) {
      cast.addAll(_namedPeople(_bangumiNames(info['主演']), '演员'));
    }
    final directors = _bangumiNames(info['导演']);

    final images = _mapOf(subject['images']);
    final poster = _text(images, const ['large', 'common', 'medium', 'grid']);
    return ExternalDetail(
      identity: identity,
      imdbId: _imdbOf(info),
      data: TmdbDetailData(
        mediaType: identity.mediaType,
        title: title,
        originalTitle: name == title ? '' : name,
        overview: _nullIfEmpty(_text(subject, const ['summary'])),
        posterUrl: poster.isEmpty ? null : poster,
        backdropUrls: [if (poster.isNotEmpty) poster],
        posterUrls: [if (poster.isNotEmpty) poster],
        cast: cast,
        crew: crew,
        creatorTeam: crew,
        directors: directors,
        writers: _bangumiNames(info['编剧']),
        genres: _splitSlash(info['类型']),
        countries: _splitSlash(info['国家/地区']),
        languages: _splitSlash(info['语言']),
        rating: _double(_mapOf(subject['rating'])['score']),
        ratingSourceLabel: identity.kind.label,
        releaseDate: _bangumiDate(subject, info),
        runtime: _minutesOf(info['每集长']),
        episodeCount: _positiveInt([subject['eps'], subject['total_episodes'], info['集数']]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// §2 人物
// ---------------------------------------------------------------------------

/// 一条外部短评。
///
/// 带 [source] 而不是固定豆瓣：后续接第三家（Bangumi 之外的社区、IMDb 等）
/// 只要产出同一个模型，UI 一行都不用改。
class ExternalComment {
  const ExternalComment({
    required this.source,
    required this.author,
    required this.text,
    this.rating = 0,
    this.maxRating = 10,
    this.date = '',
    this.votes = 0,
    this.url = '',
  });

  final MetaSourceKind source;
  final String author;
  final String text;

  /// 作者评分；`0` 表示未评分。[maxRating] 是该来源的量纲（豆瓣短评 5 星）。
  final double rating;
  final double maxRating;
  final String date;
  final int votes;
  final String url;

  String get sourceLabel => source.label;

  /// 统一到 10 分制，供 UI 用同一套星条渲染。
  double get ratingOutOfTen =>
      rating <= 0 || maxRating <= 0 ? 0 : (rating / maxRating * 10).clamp(0, 10).toDouble();

  /// 半星步进（0..10）：一步 = 半颗星。0 表示未评分。
  int get ratingHalfStars =>
      rating <= 0 || maxRating <= 0 ? 0 : ratingOutOfTen.round().clamp(0, 10);
}

/// 一页短评。
class ExternalCommentPage {
  const ExternalCommentPage({
    this.comments = const [],
    this.total = 0,
    this.hasMore = false,
    this.nextOffset = 0,
  });

  final List<ExternalComment> comments;

  /// 该来源声称的总数（可能是近似值：豆瓣给的是全站短评量级）。
  final int total;
  final bool hasMore;
  final int nextOffset;

  bool get isEmpty => comments.isEmpty;
}

/// 人物页需要的全部数据（简介/基本信息/照片/作品）。
class ExternalPersonDetail {
  const ExternalPersonDetail({
    required this.ref,
    required this.name,
    this.biography = '',
    this.department = '',
    this.imdbId = '',
    this.photos = const [],
    this.castWorks = const [],
    this.crewWorks = const [],
  });

  final MetaPersonRef ref;
  final String name;

  /// 简介；豆瓣拿不到（其载荷无 intro），只有 Bangumi 有。
  final String biography;

  /// 身份（`导演 / 演员` 之类），用于标题下那行小字。
  final String department;

  /// 人物在 IMDb 的编号（`nm1234567`）；这是人物级确定性映射的凭据。
  final String imdbId;

  final List<String> photos;
  final List<TmdbPersonWork> castWorks;
  final List<TmdbPersonWork> crewWorks;
}

/// 人物载荷 → [ExternalPersonDetail]。
abstract final class ExternalPersonMeta {
  /// 豆瓣：`/celebrity/{id}` + `/celebrity/{id}/works`。
  ///
  /// 豆瓣**不返回简介**，[ExternalPersonDetail.biography] 因此恒为空串：
  /// 页面会自然跳过「简介」区块，而不是显示一句假话。
  static ExternalPersonDetail? douban({
    required MetaPersonRef ref,
    required Map<String, Object?> celebrity,
    List<Map<String, Object?>> works = const [],
  }) {
    final name = _text(celebrity, const ['title', 'name']);
    if (name.isEmpty) return null;
    final photos = _doubanPhotoUrls(celebrity);
    final castWorks = <TmdbPersonWork>[];
    final crewWorks = <TmdbPersonWork>[];
    for (final raw in works) {
      final work = _doubanWork(raw);
      if (work == null) continue;
      final roles = _strings(raw['roles']);
      if (roles.any((role) => role.contains('演员'))) {
        castWorks.add(work);
      } else {
        crewWorks.add(work);
      }
    }
    return ExternalPersonDetail(
      ref: ref,
      name: name,
      department: _doubanDepartment(celebrity),
      imdbId: _imdbOf(_doubanExtraInfo(celebrity)),
      photos: photos,
      castWorks: castWorks,
      crewWorks: crewWorks,
    );
  }

  /// Bangumi：`/v0/persons/{id}` + `/v0/persons/{id}/subjects`。
  static ExternalPersonDetail? bangumi({
    required MetaPersonRef ref,
    required Map<String, Object?> person,
    List<Map<String, Object?>> subjects = const [],
    List<String> extraPhotos = const [],
  }) {
    final name = _text(person, const ['name']);
    if (name.isEmpty) return null;
    final info = _bangumiInfobox(person);
    final images = _mapOf(person['images']);
    final photo = _text(images, const ['large', 'medium', 'grid']);
    final castWorks = <TmdbPersonWork>[];
    final crewWorks = <TmdbPersonWork>[];
    for (final raw in subjects) {
      final work = _bangumiWork(raw);
      if (work == null) continue;
      final staff = _text(raw, const ['staff']);
      if (_bangumiCastRelations.any(staff.contains)) {
        castWorks.add(work);
      } else {
        crewWorks.add(work);
      }
    }
    return ExternalPersonDetail(
      ref: ref,
      name: (info['简体中文名'] ?? '').isNotEmpty ? info['简体中文名']! : name,
      biography: _text(person, const ['summary']),
      department: _bangumiDepartment(person, info),
      imdbId: _imdbOf(info),
      photos: [if (photo.isNotEmpty) photo, ...extraPhotos],
      castWorks: castWorks,
      crewWorks: crewWorks,
    );
  }
}

// ---------------------------------------------------------------------------
// §3 内部工具
// ---------------------------------------------------------------------------

/// Bangumi 里算「出演」的关系词。
const List<String> _bangumiCastRelations = ['主演', '配角', '演员', '声优', '配音'];

int _positiveInt(List<Object?> values) {
  for (final value in values) {
    final count = _int(value) ?? 0;
    if (count > 0) return count;
  }
  return 0;
}

List<TmdbPerson> _namedPeople(List<String> names, String role) => [
  for (var index = 0; index < names.length && index < 20; index++)
    TmdbPerson(personId: -index - 1, name: names[index], subtitle: role),
];

Map<Object?, Object?> _mapOf(Object? value) =>
    value is Map ? value.cast<Object?, Object?>() : const {};

List<Object?> _list(Object? value) => value is List ? value : const [];

/// 取第一个非空字符串。
String _text(Map<Object?, Object?> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return value.toString();
  }
  return '';
}

String? _nullIfEmpty(String value) => value.isEmpty ? null : value;

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double _double(Object? value) {
  final parsed = value is num
      ? value.toDouble()
      : double.tryParse('${value ?? ''}');
  if (parsed == null || !parsed.isFinite || parsed <= 0) return 0;
  return parsed > 10 ? 10 : parsed;
}

Object? _first(Object? value) {
  final list = _list(value);
  return list.isEmpty ? null : list.first;
}

List<String> _strings(Object? value) => [
  for (final item in _list(value))
    if (item is String && item.trim().isNotEmpty) item.trim(),
];

List<String> _splitSlash(Object? value) {
  final text = value is String ? value : '';
  if (text.trim().isEmpty) return const [];
  return [
    for (final part in text.split(RegExp(r'[/、,，|]')))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

/// `50分钟` / `1小时30分钟` → 分钟数；解析不出返回 0。
int _minutesOf(Object? value) {
  final text = value is String ? value : '';
  if (text.trim().isEmpty) return 0;
  final hours = RegExp(r'(\d+)\s*(?:小时|h)').firstMatch(text);
  final minutes = RegExp(r'(\d+)\s*(?:分钟|min)').firstMatch(text);
  final total =
      (int.tryParse(hours?.group(1) ?? '') ?? 0) * 60 +
      (int.tryParse(minutes?.group(1) ?? '') ?? 0);
  if (total > 0) return total;
  // 只给了裸数字（`50`）时按分钟算。
  return int.tryParse(text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
}

String _doubanCover(Map<String, Object?> subject) {
  final direct = _text(subject, const ['cover_url']);
  if (direct.isNotEmpty) return direct;
  for (final key in ['cover', 'pic']) {
    final cover = _mapOf(subject[key]);
    final url = _text(cover, const ['url', 'large', 'normal']);
    if (url.isNotEmpty) return url;
    for (final size in ['large', 'normal']) {
      final nested = _text(_mapOf(cover[size]), const ['url']);
      if (nested.isNotEmpty) return nested;
    }
  }
  return '';
}

double _doubanRating(Map<String, Object?> subject) =>
    _double(_mapOf(subject['rating'])['value']);

/// 豆瓣首播日期：`pubdate` 形如 `2016-07-15(美国)`，只留日期部分。
String _doubanDate(Map<String, Object?> subject) {
  // `pubdate` / `release_date` 在豆瓣是**数组**（`['2016-07-15(美国)']`），
  // 也可能是纯字符串，两种都要认。
  final candidates = <String>[
    _text(subject, const ['pubdate', 'release_date']),
    '${_first(subject['pubdate']) ?? ''}',
    '${_first(subject['release_date']) ?? ''}',
  ];
  for (final raw in candidates) {
    final match = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(raw);
    if (match != null) return match.group(1)!;
  }
  return _text(subject, const ['year']);
}

bool _isCastCredit(Map<String, Object?> item) {
  final character = _text(item, const ['character']);
  final roles = _strings(item['roles']);
  if (character.isNotEmpty) {
    return character.contains('演员') || character.contains('饰') || character.contains('配音');
  }
  return roles.isNotEmpty && (roles.first.contains('演员') || roles.first.contains('配音'));
}

/// 豆瓣演职员条目 → 人物；`character` 形如 `演员 Actor (饰 王响)`。
TmdbPerson? _doubanCreditPerson(Map<String, Object?> item) {
  final id = _int(item['id']);
  final name = _text(item, const ['name']);
  if (id == null || id <= 0 || name.isEmpty) return null;
  final character = _text(item, const ['character']);
  final role = RegExp(r'饰\s*([^)）]+)').firstMatch(character)?.group(1)?.trim();
  final subtitle = role != null && role.isNotEmpty
      ? role
      : (character.isNotEmpty
          ? character.replaceAll(RegExp(r'\s+[A-Za-z].*'), '').trim()
          : _strings(item['roles']).firstOrNull ?? '');
  final avatar = _text(_mapOf(item['avatar']), const ['large', 'normal']);
  return TmdbPerson(
    personId: id,
    name: name,
    subtitle: subtitle,
    profileUrl: avatar.isEmpty ? null : avatar,
    ref: MetaPersonRef(kind: MetaSourceKind.douban, id: id, name: name),
  );
}

Map<Object?, Object?> _doubanExtraInfo(Map<String, Object?> celebrity) {
  final extra = _mapOf(celebrity['extra']);
  final result = <Object?, Object?>{};
  for (final entry in _list(extra['info'])) {
    final pair = _list(entry);
    if (pair.length == 2) result['${pair[0]}'] = pair[1];
  }
  for (final key in ['IMDb编号', 'IMDb', 'imdb']) {
    final value = extra[key];
    if (value != null) result[key] = value;
  }
  return result;
}

String _doubanDepartment(Map<String, Object?> celebrity) {
  final extra = _mapOf(celebrity['extra']);
  final short = _text(extra, const ['short_info']);
  final details = <String>[
    if (short.isNotEmpty) short.split(RegExp(r'[/／]')).first.trim(),
  ];
  final info = _list(extra['info']);
  for (final entry in info) {
    final pair = _list(entry);
    if (pair.length == 2 && ['性别', '出生日期', '出生地', 'IMDB编号', '职业'].contains('${pair[0]}')) {
      details.add('${pair[0]}：${pair[1]}');
    }
  }
  return details.join(' · ');
}

/// 豆瓣相册：`/celebrity/{id}/photos` 的 `photos[].image.large.url`。
List<String> _doubanPhotoUrls(Map<String, Object?> celebrity) {
  final raw = _list(celebrity['photos']);
  final urls = <String>[];
  for (final item in raw) {
    final image = _mapOf(_mapOf(item)['image']);
    final url = _text(_mapOf(image['large']), const ['url']);
    final fallback = _text(_mapOf(image['normal']), const ['url']);
    final chosen = url.isNotEmpty ? url : fallback;
    if (chosen.isNotEmpty && !urls.contains(chosen)) urls.add(chosen);
  }
  return urls;
}

/// 豆瓣短评列表 `/interests` → [ExternalComment]。
/// 解析一页短评。[source] 决定徽标与分数量纲。
ExternalCommentPage externalComments(
  List<Map<String, Object?>> interests, {
  required MetaSourceKind source,
  int offset = 0,
  int total = 0,
  int pageSize = 12,
}) {
  final result = <ExternalComment>[];
  for (final item in interests) {
    final text = _text(item, const ['comment']);
    if (text.isEmpty) continue;
    final user = _mapOf(item['user']);
    final rating = _mapOf(item['rating']);
    final maxRating = _double(rating['max']) > 0
        ? _double(rating['max'])
        : (source == MetaSourceKind.douban ? 5.0 : 10.0);
    result.add(
      ExternalComment(
        source: source,
        author: _text(user, const ['name']),
        text: text,
        rating: _double(rating['value']),
        maxRating: maxRating,
        date: _text(item, const ['create_time']),
        votes: _int(item['vote_count']) ?? 0,
        url: _text(item, const ['sharing_url']),
      ),
    );
  }
  final next = offset + result.length;
  return ExternalCommentPage(
    comments: result,
    total: total > 0 ? total : next,
    hasMore: result.length >= pageSize && (total <= 0 || next < total),
    nextOffset: next,
  );
}

/// 豆瓣作品条目 → 人物作品（`work` 是嵌套对象）。
TmdbPersonWork? _doubanWork(Map<String, Object?> raw) {
  final work = _mapOf(raw['work']);
  final title = _text(work, const ['title']);
  if (title.isEmpty) return null;
  final year = _text(work, const ['year']);
  final rating = _double(_mapOf(work['rating'])['value']);
  final type = _text(work, const ['type']);
  final poster = _doubanCover(Map<String, Object?>.from(work));
  final item = TmdbItem(
    // 兜底源作品没有 TMDB 身份：`identity` 为 null，点开不会误开 TMDB 页。
    tmdbId: 0,
    mediaType: type == 'tv' ? TmdbMediaType.tv : TmdbMediaType.movie,
    title: title,
    subtitle: TmdbItem.buildSubtitle(year, rating),
    posterUrl: poster.isEmpty ? null : poster,
  );
  final roles = _strings(raw['roles']);
  final role = roles.isEmpty ? '' : roles.first;
  final character = RegExp(r'饰\s*([^)）]+)').firstMatch(role)?.group(1)?.trim() ?? '';
  return TmdbPersonWork(
    item: item,
    character: character,
    job: character.isNotEmpty ? '' : role,
    department: role.contains('演员') ? 'Acting' : '',
    sortDate: year,
  );
}

/// Bangumi 人物作品条目（扁平结构）。
TmdbPersonWork? _bangumiWork(Map<String, Object?> raw) {
  final nameCn = _text(raw, const ['name_cn']);
  final name = _text(raw, const ['name']);
  final title = nameCn.isNotEmpty ? nameCn : name;
  if (title.isEmpty) return null;
  final image = _text(raw, const ['image']);
  final item = TmdbItem(
    tmdbId: 0,
    mediaType: TmdbMediaType.tv,
    title: title,
    subtitle: '',
    posterUrl: image.isEmpty ? null : image,
  );
  final staff = _text(raw, const ['staff']);
  return TmdbPersonWork(
    item: item,
    job: _bangumiCastRelations.any(staff.contains) ? '' : staff,
    department: _bangumiCastRelations.any(staff.contains) ? 'Acting' : '',
    episodeCount: _int(raw['eps']) ?? 0,
  );
}

/// Bangumi 演职员条目 → 人物。
TmdbPerson? _bangumiPerson(Map<String, Object?> person) {
  final id = _int(person['id']);
  final name = _text(person, const ['name']);
  if (id == null || id <= 0 || name.isEmpty) return null;
  final images = _mapOf(person['images']);
  final avatar = _text(images, const ['grid', 'small', 'medium']);
  return TmdbPerson(
    personId: id,
    name: name,
    subtitle: _text(person, const ['relation']),
    profileUrl: avatar.isEmpty ? null : avatar,
    ref: MetaPersonRef(kind: MetaSourceKind.bangumi, id: id, name: name),
  );
}

String _bangumiDepartment(
  Map<String, Object?> person,
  Map<String, String> info,
) {
  final gender = _text(person, const ['gender']);
  final career = _strings(person['career']);
  final parts = <String>[
    if (career.isNotEmpty) career.join(' / '),
    if (gender.isNotEmpty) gender,
    if ((info['生日'] ?? '').isNotEmpty) info['生日']!,
  ];
  return parts.join(' · ');
}

/// Bangumi `infobox`（`[{key, value}]`）摊平成 `key → 文本`。
///
/// `value` 既可能是字符串，也可能是 `[{v: '...'}]` 列表（别名/主演常用后者），
/// 两种都要能读成一行文本。
Map<String, String> _bangumiInfobox(Map<String, Object?> subject) {
  final result = <String, String>{};
  for (final raw in _list(subject['infobox'])) {
    final entry = _mapOf(raw);
    final key = _text(entry, const ['key']);
    if (key.isEmpty) continue;
    final value = entry['value'];
    final text = value is String
        ? value.trim()
        : _list(value)
              .map((item) => _text(_mapOf(item), const ['v', 'name']))
              .where((item) => item.isNotEmpty)
              .join(' / ');
    if (text.isNotEmpty) result[key] = text;
  }
  return result;
}

List<String> _bangumiNames(String? value) => _splitSlash(value);

String _bangumiDate(Map<String, Object?> subject, Map<String, String> info) {
  final date = _text(subject, const ['date']);
  if (date.isNotEmpty) return date;
  final start = info['开始'] ?? '';
  if (start.isNotEmpty) return start;
  return info['放送开始'] ?? '';
}

/// 从载荷里找 IMDb 编号：豆瓣在顶层 `imdb`/`imdb_id`，Bangumi 在 infobox；
/// 两种形状都接受，取到第一个形如 `tt1234567` 的值。
String _imdbOf(Map<Object?, Object?> source) {
  final direct = [
    source['imdb'],
    source['imdb_id'],
    source['IMDb'],
    source['IMDb编号'],
  ];
  for (final value in direct) {
    final text = '${value ?? ''}'.trim();
    if (RegExp(r'^tt\d{6,}$').hasMatch(text)) return text;
  }
  return '';
}