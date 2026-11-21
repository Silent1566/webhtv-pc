/// TMDB 不可用时的兜底入口：豆瓣优先，Bangumi 次之。
/// HTTP 缓存/限速由各客户端负责；这里只去重飞行请求并隔离失效结果。
library;

import '../core/external_detail_meta.dart';
import '../core/tmdb_detail_model.dart';
import '../core/tmdb_media.dart';
import '../core/external_meta.dart';
import '../core/meta_pipeline.dart';
import '../core/protocol.dart';
import '../core/source_meta_resolver.dart';
import '../core/meta_source.dart';
import 'bangumi_service.dart';
import 'tmdb_service.dart';
import 'wikidata_service.dart';
import 'douban_recommendation_service.dart';

class MetaFieldSnapshots {
  const MetaFieldSnapshots({this.providers = const {}, this.primary, this.pinnedKind});

  final Map<MetaSourceKind, TmdbDetailData> providers;
  final ExternalDetail? primary;
  final MetaSourceKind? pinnedKind;

  MetaPipeline effectivePipeline(MetaPipeline pipeline) {
    final kind = pinnedKind;
    if (kind == null) return pipeline;
    var result = pipeline;
    for (final field in MetaField.values.where(MetaPipeline.supportsSource)) {
      final rule = result.ruleOf(field);
      if (rule.order.isEmpty) continue;
      result = result.withRule(rule.copyWith(order: [kind, ...rule.order.where((s) => s != kind)]));
    }
    return result;
  }
}

class ExternalMetaService {
  ExternalMetaService({
    DoubanRecommendationService? douban,
    BangumiService? bangumi,
    WikidataService? wikidata,
    TmdbService? tmdb,
    MetaPipeline Function()? pipeline,
    TmdbDetailData? Function()? tmdbDetail,
    MetaIdentity? Function()? tmdbIdentity,
    bool Function()? enabled,
    void Function(String message)? log,
  }) : _douban = douban, // ignore: prefer_initializing_formals
       _log = log, // ignore: prefer_initializing_formals
       _bangumi = bangumi, // ignore: prefer_initializing_formals
       _wikidata = wikidata, // ignore: prefer_initializing_formals
       _tmdb = tmdb, // ignore: prefer_initializing_formals
       _pipeline = pipeline, // ignore: prefer_initializing_formals
       _tmdbDetail = tmdbDetail, // ignore: prefer_initializing_formals
       _tmdbIdentity = tmdbIdentity, // ignore: prefer_initializing_formals
       _enabled = enabled; // ignore: prefer_initializing_formals

  final DoubanRecommendationService? _douban;
  final BangumiService? _bangumi;
  final WikidataService? _wikidata;

  /// TMDB 客户端：只用于「按 IMDb 编号确定性映射」，不参与内容抓取。
  final TmdbService? _tmdb;

  /// 当前这趟解析拿到的 IMDb 编号（确定性映射的唯一输入）。
  String _activeImdbId = '';
  final MetaPipeline Function()? _pipeline;

  /// TMDB 的**已有快照**：只读不请求（抓取与匹配置信由 `TmdbState` 负责）。
  final TmdbDetailData? Function()? _tmdbDetail;
  final MetaIdentity? Function()? _tmdbIdentity;

  /// 当前生效的逐字段规则（默认管线）。
  MetaPipeline get pipeline => _pipeline?.call() ?? MetaPipeline.defaults;
  final bool Function()? _enabled;
  final void Function(String message)? _log;

  /// 最近一次兜底命中的来源（设置页/诊断用）。
  String get lastSourceLabel => _lastSourceLabel;
  String _lastSourceLabel = '';

  void _note(String message, {bool warn = false}) {
    _log?.call('外部元数据${warn ? '（已降级）' : ''}: $message');
  }
  final Map<String, Future<ExternalDetail?>> _details = {};
  final Map<String, Future<ExternalPersonDetail?>> _people = {};

  /// 跨源身份映射缓存（「来源|查询键」→ 身份或 null）。
  final Map<String, MetaIdentity?> _resolved = {};

  /// 当前这一趟解析用的查询（供字段级聚合复用，避免层层传参）。
  MetaQuery? _activeQuery;
  int _generation = 0;
  int _commentsEpoch = 0;
  bool _closed = false;

  bool get isEnabled => !_closed && (_enabled?.call() ?? true);
  bool _current(int generation) => isEnabled && generation == _generation;
  bool _commentsCurrent(int epoch) => isEnabled && epoch == _commentsEpoch;

  /// 某来源的检索候选（手动匹配对话框用）。失败返回空列表，不抛。
  ///
  /// [enrich] 由对话框传 `true`：候选行要显示评分/主创事实；自动匹配链路
  /// 不传，避免为即将被详情覆盖的字段多打一次请求。
  Future<List<MetaCandidate>> candidates(
    MetaQuery query,
    MetaSourceKind source, {
    bool enrich = false,
  }) async {
    if (!isEnabled) return const [];
    try {
      return switch (source) {
        MetaSourceKind.douban =>
          await _douban?.searchMeta(query, enrich: enrich) ?? const [],
        MetaSourceKind.bangumi => await _bangumi?.search(query) ?? const [],
        MetaSourceKind.tmdb || MetaSourceKind.wikidata || MetaSourceKind.source => const [],
      };
    } catch (_) {
      _note('候选检索失败：${source.label}', warn: true);
      return const [];
    }
  }

  /// 取详情。[pinned] 非空表示用户手动钉住了某条身份：**跳过检索**直接取那一条。
  Future<ExternalDetail?> detail(MetaQuery query, {MetaIdentity? pinned}) {
    if (!isEnabled || query.queries.isEmpty) return Future.value(null);
    final existing = _details[query.key];
    if (existing != null) return existing;
    final pending = _loadDetail(query, _generation, pinned: pinned);
    _details[query.key] = pending;
    pending.whenComplete(() {
      if (identical(_details[query.key], pending)) _details.remove(query.key);
    });
    return pending;
  }

  /// Raw snapshots for configurable work fields, independent of the legacy
  /// mixed primary detail used by ratings/comments.
  Future<MetaFieldSnapshots> resolveFields(
    MetaQuery query, {
    required Vod source,
    required MetaPipeline pipeline,
    TmdbDetailData? tmdb,
    MetaIdentity? tmdbIdentity,
    MetaIdentity? pinned,
  }) async {
    if (!isEnabled) return const MetaFieldSnapshots();
    final generation = _generation;
    final raw = <MetaSourceKind, ExternalDetail?>{};
    bool needsPeople(MetaPipeline rules, MetaSourceKind kind) =>
        rules.orderOf(MetaField.cast).contains(kind) ||
        rules.orderOf(MetaField.crew).contains(kind);
    MetaSourceKind? pinnedKind;
    if (pinned != null) {
      try {
        final pinnedPipeline = MetaFieldSnapshots(pinnedKind: pinned.kind).effectivePipeline(pipeline);
        final direct = await _detailByIdentity(pinned, generation,
          includePeople: needsPeople(pinnedPipeline, pinned.kind));
        if (direct != null) { raw[pinned.kind] = direct; pinnedKind = pinned.kind; }
      } catch (_) { /* An unavailable pin falls back to configured matching. */ }
    }
    if (!_current(generation)) return const MetaFieldSnapshots();
    final effective = MetaFieldSnapshots(pinnedKind: pinnedKind).effectivePipeline(pipeline);
    final snapshots = await SourceMetaResolver.loadProviders(
      pipeline: effective, source: source, tmdb: tmdb,
      load: (kind) async {
        if (!_current(generation)) return null;
        if (!raw.containsKey(kind)) {
          raw[kind] = switch (kind) {
            MetaSourceKind.douban => await _doubanDetail(query, generation,
              includePeople: needsPeople(effective, kind)),
            MetaSourceKind.bangumi => await _bangumiDetail(query, generation,
              includePeople: needsPeople(effective, kind)),
            _ => null,
          };
        }
        return raw[kind]?.data;
      },
    );
    if (!_current(generation)) return const MetaFieldSnapshots();
    ExternalDetail? primary = pinnedKind == null ? null : raw[pinnedKind];
    if (primary == null && tmdb != null && tmdbIdentity != null) {
      primary = ExternalDetail(identity: tmdbIdentity, data: tmdb);
    }
    primary ??= raw.values.whereType<ExternalDetail>().firstOrNull;
    final photoOnly = primary == null;
    if (photoOnly) primary = await _photoOnlyDetail(query, generation, pipeline);
    if (!_current(generation)) return const MetaFieldSnapshots();
    if (primary != null) {
      _activeQuery = query;
      _activeImdbId = primary.imdbId;
      if (!photoOnly) {
        primary = await _withAggregatedPhotos(primary, generation, rules: pipeline);
      }
      if (!_current(generation)) return const MetaFieldSnapshots();
      _lastSourceLabel = primary.sourceLabel;
    }
    return MetaFieldSnapshots(providers: snapshots, primary: primary, pinnedKind: pinnedKind);
  }

  /// A photo rule can need an external identity even when every text/list
  /// field stopped at the local resource. Do not load unused subject fields.
  Future<ExternalDetail?> _photoOnlyDetail(
    MetaQuery query,
    int generation,
    MetaPipeline pipeline,
  ) async {
    final douban = _douban;
    if (douban == null ||
        !pipeline.orderOf(MetaField.photos).contains(MetaSourceKind.douban)) {
      return null;
    }
    try {
      final identity = await resolveIdentity(query, MetaSourceKind.douban, generation);
      if (identity == null || !_current(generation)) return null;
      final photos = await douban.metaSubjectPhotos(identity.id, isTv: identity.isTv);
      if (!_current(generation) || photos.isEmpty) return null;
      return ExternalDetail(
        identity: identity,
        data: TmdbDetailData(
          mediaType: identity.mediaType,
          photoUrls: photos,
          stillUrls: photos,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<ExternalDetail?> _loadDetail(
    MetaQuery query,
    int generation, {
    MetaIdentity? pinned,
  }) async {
    _activeQuery = query;
    _activeImdbId = '';
    _note('检索《${query.title}》 year=${query.year}');
    if (pinned != null) {
      final direct = await _detailByIdentity(pinned, generation);
      if (!_current(generation)) return null;
      if (direct != null) {
        _lastSourceLabel = direct.sourceLabel;
        _note('按手动指定取详情 ${pinned.key}');
        return _withAggregatedPhotos(direct, generation);
      }
      _note('手动指定 ${pinned.key} 取不到，回退自动匹配', warn: true);
    }
    // TMDB 排第一且确有快照时直接当主来源（只读，不发请求）。
    final tmdb = _tmdbPrimary();
    if (tmdb != null) {
      _lastSourceLabel = tmdb.sourceLabel;
      _note('命中 TMDB ${tmdb.identity.key}');
      return _withAggregatedPhotos(
        await _fillFromNext(tmdb, query, generation),
        generation,
      );
    }
    final douban = await _doubanDetail(query, generation);
    if (!_current(generation)) return null;
    if (douban != null) {
      _lastSourceLabel = douban.sourceLabel;
      _note('命中豆瓣 ${douban.identity.key}');
      return _withAggregatedPhotos(
        await _fillFromNext(douban, query, generation),
        generation,
      );
    }
    _note('豆瓣未命中，改试 Bangumi');
    final bangumi = await _bangumiDetail(query, generation);
    if (bangumi == null) {
      _note('两家都没命中，保留站源字段');
      return null;
    }
    if (!_current(generation)) return null;
    _lastSourceLabel = bangumi.sourceLabel;
    _note('命中 Bangumi ${bangumi.identity.key}');
    return bangumi;
  }

  Future<ExternalPersonDetail?> person(MetaPersonRef ref) {
    if (!isEnabled || ref.id <= 0 || !ref.kind.isFallback) return Future.value(null);
    final existing = _people[ref.key];
    if (existing != null) return existing;
    final pending = _loadPerson(ref, _generation).then(
      (value) => _withWikidataBio(value, ref, _generation),
    ).then((value) => _withTmdbPhotos(value, _generation),
    );
    _people[ref.key] = pending;
    pending.whenComplete(() {
      if (identical(_people[ref.key], pending)) _people.remove(ref.key);
    });
    return pending;
  }

  Future<ExternalPersonDetail?> _loadPerson(MetaPersonRef ref, int generation) async {
    try {
      if (ref.kind == MetaSourceKind.douban && _douban != null) {
        final celebrity = await _douban.metaCelebrity(ref.id);
        if (!_current(generation) || celebrity.isEmpty) return null;
        final works = await _douban.metaCelebrityWorks(ref.id);
        if (!_current(generation)) return null;
        final photos = await _optionalStrings(() => _douban.metaCelebrityPhotos(ref.id));
        _note('人物相册：豆瓣返回 ${photos.length} 张（${ref.key}）');
        if (!_current(generation)) return null;
        _lastSourceLabel = MetaSourceKind.douban.label;
        _note('人物 ${ref.key} 作品 ${works.length} 张照片 ${photos.length}');
        return ExternalPersonMeta.douban(
          ref: ref,
          celebrity: {...celebrity, 'photos': photos.map((url) => {'image': {'large': {'url': url}}}).toList()},
          works: works,
        );
      }
      if (ref.kind == MetaSourceKind.wikidata && _wikidata != null) {
        final bio = await _wikidata.biography(ref.id);
        if (!_current(generation) || bio.isEmpty) return null;
        return ExternalPersonDetail(
          ref: ref,
          name: ref.name,
          biography: bio,
          photos: const [],
        );
      }
      if (ref.kind == MetaSourceKind.bangumi && _bangumi != null) {
        final value = await _bangumi.person(ref.id);
        if (!_current(generation) || value.isEmpty) return null;
        final works = await _optional(() => _bangumi.personSubjects(ref.id));
        if (!_current(generation)) return null;
        _lastSourceLabel = MetaSourceKind.bangumi.label;
        _note('人物 ${ref.key} 作品 ${works.length}');
        return ExternalPersonMeta.bangumi(ref: ref, person: value, subjects: works);
      }
    } catch (_) {
      // 补全失败不能升级成站源详情的致命错误。
    }
    return null;
  }

  /// 人物简介为空时，按 `personBiography` 规则向下一顺位（Wikidata）补一句。
  ///
  /// 只补简介：照片、作品仍来自主来源，不混两家的数据。
  Future<ExternalPersonDetail?> _withWikidataBio(
    ExternalPersonDetail? person,
    MetaPersonRef ref,
    int generation,
  ) async {
    final wikidata = _wikidata;
    if (person == null || wikidata == null) return person;
    if (person.biography.trim().isNotEmpty) return person;
    final field = MetaField.personBiography;
    final order = pipeline.orderOf(field);
    final index = order.indexOf(ref.kind);
    if (!order.contains(MetaSourceKind.wikidata)) return person;
    // 只有当前来源**排在 Wikidata 之前**（它已经优先）时才不补；
    // 豆瓣排在最后，因此它的空简介该由 Wikidata 补上。
    if (index >= 0 && index < order.indexOf(MetaSourceKind.wikidata)) {
      return person;
    }
    final name = person.name.trim().isEmpty ? ref.name : person.name;
    if (name.trim().isEmpty) return person;
    final hit = await wikidata.searchPerson(name);
    if (hit == null || !_current(generation)) return person;
    final bio = await wikidata.biography(hit.id);
    if (!_current(generation) || bio.trim().isEmpty) return person;
    _note('人物简介来自 Wikidata ${hit.key}');
    return ExternalPersonDetail(
      ref: person.ref,
      name: person.name,
      biography: bio,
      department: person.department,
      imdbId: person.imdbId,
      photos: person.photos,
      castWorks: person.castWorks,
      crewWorks: person.crewWorks,
    );
  }

  /// 人物级确定性映射：用 IMDb 人物编号找 TMDB 人物，把相册并进来。
  ///
  /// 只在 `personPhotos` 规则包含 TMDB 时做；编号缺失或未配置 TMDB 时原样返回，
  /// 失败也原样返回——照片是附加信息，不该影响人物页。
  Future<ExternalPersonDetail?> _withTmdbPhotos(
    ExternalPersonDetail? person,
    int generation,
  ) async {
    final tmdb = _tmdb;
    if (person == null || tmdb == null) return person;
    if (!pipeline.orderOf(MetaField.personPhotos).contains(MetaSourceKind.tmdb)) {
      return person;
    }
    final imdb = person.imdbId;
    if (imdb.isEmpty) {
      _note('人物照片跨源：${person.name} 无 IMDb 编号，跳过');
      return person;
    }
    _note('人物照片跨源：${person.name} imdb=$imdb');
    try {
      final personId = await tmdb.findPersonByImdbId(imdb);
      if (personId == null || !_current(generation)) return person;
      final detail = await tmdb.person(personId);
      if (!_current(generation) || detail.isEmpty) return person;
      final photos = TmdbImageSelector.profiles(
        detail,
        tmdb.config.imageBase,
        limit: 12,
      );
      if (photos.isEmpty) return person;
      final merged = <String>[...person.photos];
      for (final url in photos) {
        if (!merged.contains(url)) merged.add(url);
      }
      _note('人物照片跨源：+${merged.length - person.photos.length} 张（TMDB）');
      return ExternalPersonDetail(
        ref: person.ref,
        name: person.name,
        biography: person.biography,
        department: person.department,
        imdbId: person.imdbId,
        photos: merged,
        castWorks: person.castWorks,
        crewWorks: person.crewWorks,
      );
    } catch (_) {
      _note('TMDB 人物照片获取失败', warn: true);
      return person;
    }
  }

  void clearCache({bool preserveComments = false}) {
    _generation++;
    if (!preserveComments) _commentsEpoch++;
    _resolved.clear();
    _details.clear();
    _people.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    clearCache();
    _douban?.close();
    _bangumi?.close();
  }

  /// 直接按身份取详情（手动指定用）：不检索、不猜，id 不存在就返回 null。
  Future<ExternalDetail?> _detailByIdentity(
    MetaIdentity identity,
    int generation, {
    bool includePeople = true,
  }) async {
    switch (identity.kind) {
      case MetaSourceKind.douban:
        final douban = _douban;
        if (douban == null) return null;
        final subject = await douban.metaSubject(
          identity.id,
          isTv: identity.isTv,
        );
        if (!_current(generation) || subject.isEmpty) return null;
        final credits = includePeople
            ? await douban.metaCredits(identity.id, isTv: identity.isTv)
            : const <Map<String, Object?>>[];
        if (!_current(generation)) return null;
        return ExternalDetailMeta.douban(
          identity: identity,
          subject: subject,
          credits: credits,
        );
      case MetaSourceKind.bangumi:
        final bangumi = _bangumi;
        if (bangumi == null) return null;
        final subject = await bangumi.subject(identity.id);
        if (!_current(generation) || subject.isEmpty) return null;
        final persons = includePeople
            ? await _optional(() => bangumi.persons(identity.id))
            : const <Map<String, Object?>>[];
        if (!_current(generation)) return null;
        return ExternalDetailMeta.bangumi(
          identity: identity,
          subject: subject,
          persons: persons,
        );
      case MetaSourceKind.tmdb:
      case MetaSourceKind.wikidata:
      case MetaSourceKind.source:
        return null;
    }
  }

  /// TMDB 快照 → 主来源；没有快照、或 TMDB 不排在简介链首位时返回 null。
  ExternalDetail? _tmdbPrimary() {
    final order = pipeline.orderOf(MetaField.overview);
    if (order.isEmpty || order.first != MetaSourceKind.tmdb) return null;
    final data = _tmdbDetail?.call();
    final identity = _tmdbIdentity?.call();
    if (data == null || identity == null) return null;
    return ExternalDetail(identity: identity, data: data);
  }

  Future<ExternalDetail?> _doubanDetail(
    MetaQuery query,
    int generation, {
    bool includePeople = true,
  }) async {
    final douban = _douban;
    if (douban == null) return null;
    try {
      final candidates = await douban.searchMeta(query);
      if (!_current(generation)) return null;
      final chosen = MetaMatchRules.choose(candidates, query: query);
      if (chosen == null) return null;
      final subject = await douban.metaSubject(chosen.identity.id, isTv: chosen.identity.isTv);
      if (!_current(generation) || subject.isEmpty) return null;
      final credits = includePeople
          ? await douban.metaCredits(chosen.identity.id, isTv: chosen.identity.isTv)
          : const <Map<String, Object?>>[];
      if (!_current(generation)) return null;
      return ExternalDetailMeta.douban(identity: chosen.identity, subject: subject, credits: credits);
    } catch (_) {
      return null;
    }
  }

  /// 按「照片」规则聚合各来源的剧照。
  ///
  /// 聚合模式下把各来源的图片按顺序拼接去重（用户决策 A：只混同类，
  /// 作品剧照不与人物写真混）；「优先」模式直接原样返回，一次都不多发请求。
  /// 跨源身份映射：把同一部作品在别的来源里的身份解析出来。
  ///
  /// 优先级：**用户手动指定 > 自动按标题检索**。自动匹配复用
  /// `MetaMatchRules.choose`（标题 + 年份 + 季号），认不准返回 null ——
  /// 与 TMDB 匹配层「歧义即未匹配」同一取向，宁可不映射也不猜错。
  ///
  /// 结果按「来源|查询键」会话内缓存；`clearCache()` 一并作废。
  Future<MetaIdentity?> resolveIdentity(
    MetaQuery query,
    MetaSourceKind source,
    int generation,
  ) async {
    if (!isEnabled || source == MetaSourceKind.source) return null;
    final key = '${source.key}|${query.key}';
    if (_resolved.containsKey(key)) return _resolved[key];
    MetaIdentity? resolved;
    try {
      switch (source) {
        case MetaSourceKind.douban:
          final douban = _douban;
          if (douban != null) {
            resolved = MetaMatchRules.choose(
              await douban.searchMeta(query),
              query: query,
            )?.identity;
          }
        case MetaSourceKind.bangumi:
          final bangumi = _bangumi;
          if (bangumi != null) {
            resolved = MetaMatchRules.choose(
              await bangumi.search(query),
              query: query,
            )?.identity;
          }
        case MetaSourceKind.tmdb:
          // 确定性映射：有 IMDb 编号就**只**用它，绝不退回按标题猜。
          final tmdb = _tmdb;
          final imdb = _activeImdbId;
          if (tmdb != null && imdb.isNotEmpty) {
            final identity = await tmdb.findByImdbId(imdb);
            resolved = identity == null
                ? null
                : MetaIdentity.of(
                    MetaSourceKind.tmdb,
                    identity.mediaType,
                    identity.tmdbId,
                  );
          }
        case MetaSourceKind.wikidata:
        case MetaSourceKind.source:
          resolved = null;
      }
    } catch (_) {
      resolved = null;
    }
    if (!_current(generation)) return null;
    _resolved[key] = resolved;
    _note(resolved == null
        ? '跨源映射：${source.label} 未能确认身份'
        : '跨源映射：${source.label} → ${resolved.key}');
    return resolved;
  }

  Future<ExternalDetail> _withAggregatedPhotos(
    ExternalDetail detail,
    int generation, {
    MetaPipeline? rules,
  }) async {
    // 三条返回路径都会经过这里：在这里记录 IMDb 编号，供确定性映射使用。
    _activeImdbId = detail.imdbId;
    final field = MetaField.photos;
    final activePipeline = rules ?? pipeline;
    if (activePipeline.modeOf(field) != MetaFieldMode.aggregate) return detail;
    final douban = _douban;
    final order = activePipeline.orderOf(field);
    if (douban == null || !order.contains(MetaSourceKind.douban)) return detail;
    final List<String> extra;
    try {
      // 豆瓣照片端点只认豆瓣 subject id：主来源不是豆瓣时，先用跨源映射
      // 解析出豆瓣身份；解析不到就不取（不猜、不发请求）。
      final query = _activeQuery;
      final doubanIdentity = detail.identity.kind == MetaSourceKind.douban
          ? detail.identity
          : query == null
          ? null
          : await resolveIdentity(query, MetaSourceKind.douban, generation);
      if (doubanIdentity == null) return detail;
      extra = await douban.metaSubjectPhotos(
        doubanIdentity.id,
        isTv: doubanIdentity.isTv,
      );
    } catch (_) {
      return detail;
    }
    if (!_current(generation) || extra.isEmpty) return detail;
    final merged = <String>[...detail.data.photoUrls];
    for (final url in extra) {
      if (!merged.contains(url)) merged.add(url);
    }
    if (merged.length == detail.data.photoUrls.length) return detail;
    _note('剧照聚合：${detail.data.photoUrls.length} → ${merged.length} 张');
    final data = detail.data;
    return ExternalDetail(
      identity: detail.identity,
      imdbId: detail.imdbId,
      data: TmdbDetailData(
        tmdbId: data.tmdbId,
        networks: data.networks,
        mediaType: data.mediaType,
        title: data.title,
        originalTitle: data.originalTitle,
        overview: data.overview,
        tagline: data.tagline,
        posterUrl: data.posterUrl,
        backdropUrls: data.backdropUrls,
        posterUrls: data.posterUrls,
        photoUrls: merged,
        stillUrls: data.stillUrls.isEmpty ? merged : data.stillUrls,
        seasons: data.seasons,
        cast: data.cast,
        crew: data.crew,
        creators: data.creators,
        creatorTeam: data.creatorTeam,
        directors: data.directors,
        writers: data.writers,
        genres: data.genres,
        countries: data.countries,
        languages: data.languages,
        rating: data.rating,
        ratingSourceLabel: data.ratingSourceLabel,
        voteCount: data.voteCount,
        releaseDate: data.releaseDate,
        runtime: data.runtime,
        seasonCount: data.seasonCount,
        episodeCount: data.episodeCount,
        status: data.status,
        homepage: data.homepage,
      ),
    );
  }

  /// 用下一顺位补当前来源缺的「优先字段」。
  ///
  /// 只补简介与演职员：这两样在豆瓣经常缺失，而 Bangumi 的 summary 与 persons
  /// 恰好补得上。主来源已有的字段一律不动 —— 这就是「取到即停」。
  Future<ExternalDetail> _fillFromNext(
    ExternalDetail primary,
    MetaQuery query,
    int generation,
  ) async {
    final needsOverview = (primary.data.overview ?? '').trim().isEmpty &&
        pipeline.modeOf(MetaField.overview) == MetaFieldMode.priority;
    final needsCast = primary.data.cast.isEmpty &&
        pipeline.modeOf(MetaField.cast) == MetaFieldMode.priority;
    if (!needsOverview && !needsCast) return primary;
    if (!_hasMoreSources(MetaField.overview, primary.identity.kind)) {
      return primary;
    }
    final fallback = await _bangumiDetail(query, generation);
    if (fallback == null || !_current(generation)) return primary;
    final data = primary.data;
    final merged = TmdbDetailData(
      mediaType: data.mediaType,
      title: data.title,
      originalTitle: data.originalTitle,
      overview: needsOverview ? fallback.data.overview : data.overview,
      tagline: data.tagline,
      posterUrl: data.posterUrl ?? fallback.data.posterUrl,
      backdropUrls: data.backdropUrls,
      posterUrls: data.posterUrls,
      photoUrls: data.photoUrls,
      stillUrls: data.stillUrls,
      seasons: data.seasons,
      cast: needsCast ? fallback.data.cast : data.cast,
      crew: data.crew,
      creators: data.creators,
      creatorTeam: needsCast ? fallback.data.creatorTeam : data.creatorTeam,
      directors: data.directors.isEmpty
          ? fallback.data.directors
          : data.directors,
      writers: data.writers,
      genres: data.genres,
      countries: data.countries,
      languages: data.languages,
      rating: data.rating,
      ratingSourceLabel: data.ratingSourceLabel,
      voteCount: data.voteCount,
      releaseDate: data.releaseDate,
      runtime: data.runtime,
      seasonCount: data.seasonCount,
      episodeCount: data.episodeCount,
      status: data.status,
      homepage: data.homepage,
    );
    _note('字段级补齐：简介与演职员按优先链取自 Bangumi');
    return ExternalDetail(identity: primary.identity, data: merged);
  }

  /// 该字段的顺序里，current 之后还有别的来源吗。
  bool _hasMoreSources(MetaField field, MetaSourceKind current) {
    final order = pipeline.orderOf(field);
    final index = order.indexOf(current);
    return index >= 0 && index < order.length - 1;
  }

  Future<ExternalDetail?> _bangumiDetail(
    MetaQuery query,
    int generation, {
    bool includePeople = true,
  }) async {
    final bangumi = _bangumi;
    if (bangumi == null) return null;
    try {
      final candidates = await bangumi.search(query);
      if (!_current(generation)) return null;
      final chosen = MetaMatchRules.choose(candidates, query: query);
      if (chosen == null) return null;
      final subject = await bangumi.subject(chosen.identity.id);
      if (!_current(generation) || subject.isEmpty) return null;
      final persons = includePeople
          ? await _optional(() => bangumi.persons(chosen.identity.id))
          : const <Map<String, Object?>>[];
      if (!_current(generation)) return null;
      return ExternalDetailMeta.bangumi(identity: chosen.identity, subject: subject, persons: persons);
    } catch (_) {
      return null;
    }
  }

  /// 按标题取**豆瓣**那份演职员表（带 celebrity ref），供人物级映射使用。
  ///
  /// 为什么单独一条：TMDB 匹配时 `detail()` 返回的是 TMDB 那份数据（用于合并
  /// 剧照），它的 cast 来自 TMDB、没有豆瓣 ref，无法用于「同片姓名匹配」。
  Future<List<TmdbPerson>> doubanCastByTitle(
    MetaQuery query,
    int generation,
  ) async {
    final douban = _douban;
    if (douban == null || !isEnabled) return const [];
    try {
      final identity = await resolveIdentity(query, MetaSourceKind.douban, generation);
      if (identity == null || !_current(generation)) return const [];
      final subject = await douban.metaSubject(identity.id, isTv: identity.isTv);
      if (!_current(generation) || subject.isEmpty) return const [];
      final credits = await douban.metaCredits(identity.id, isTv: identity.isTv);
      if (!_current(generation)) return const [];
      final detail = ExternalDetailMeta.douban(
        identity: identity,
        subject: subject,
        credits: credits,
      );
      return detail?.data.cast ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// 按 `rating` 字段的来源顺序逐个取分，**与 TMDB 是否匹配无关**。
  ///
  /// 返回 `source → 10 分制分值`（>0 才算取到）。优先链语义：同一字段只需要
  /// 一个值，因此按顺序**取到即停**，但会返回**所有**取到的来源以便同时展示
  /// （TMDB 分与豆瓣分本来就是两件事，不是替代关系）。
  Future<Map<MetaSourceKind, double>> ratingsByTitle(MetaQuery query) async {
    final result = <MetaSourceKind, double>{};
    if (!isEnabled) return result;
    for (final source in pipeline.orderOf(MetaField.rating)) {
      if (source == MetaSourceKind.tmdb) continue; // TMDB 分由 TmdbState 提供
      if (source == MetaSourceKind.bangumi) {
        final bangumi = _bangumi;
        if (bangumi == null) continue;
        try {
          final candidates = await bangumi.search(query);
          if (!_current(_generation)) return result;
          final chosen = MetaMatchRules.choose(candidates, query: query);
          if (chosen == null) continue;
          final subject = await bangumi.subject(chosen.identity.id);
          if (!_current(_generation) || subject.isEmpty) continue;
          final rating = _ratingOf(subject);
          if (rating > 0) result[MetaSourceKind.bangumi] = rating;
        } catch (_) {
          _note('Bangumi 评分获取失败', warn: true);
        }
        continue;
      }
      if (source == MetaSourceKind.douban) {
        final douban = _douban;
        if (douban == null) continue;
        try {
          final candidates = await douban.searchMeta(query);
          if (!_current(_generation)) return result;
          final chosen = MetaMatchRules.choose(candidates, query: query);
          if (chosen == null) continue;
          final subject = await douban.metaSubject(
            chosen.identity.id,
            isTv: chosen.identity.isTv,
          );
          if (!_current(_generation) || subject.isEmpty) continue;
          final rating = _ratingOf(subject);
          if (rating > 0) result[MetaSourceKind.douban] = rating;
        } catch (_) {
          _note('豆瓣评分获取失败', warn: true);
        }
      }
    }
    if (result.isNotEmpty) {
      _note('评分：${result.entries.map((e) => '${e.key.label} ${e.value}').join(' / ')}');
    }
    return result;
  }

  double _ratingOf(Map<String, Object?> subject) {
    final raw = subject['rating'];
    if (raw is! Map) return 0;
    final value = raw['value'];
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    if (parsed == null || !parsed.isFinite || parsed <= 0) return 0;
    return parsed > 10 ? 10 : parsed;
  }

  /// 按标题直接取短评：**不依赖 TMDB 是否匹配**。
  ///
  /// 为什么单独一条：短评是 `comments` 字段的聚合来源（现只有豆瓣），
  /// TMDB 匹配成功时页面根本不会走兜底，但它同样没有短评可显示。
  Future<ExternalCommentPage> commentsByTitle(
    MetaQuery query, {
    int offset = 0,
    int limit = 5,
  }) async {
    final generation = _commentsEpoch;
    final order = pipeline.orderOf(MetaField.comments);
    if (!order.contains(MetaSourceKind.douban)) {
      return const ExternalCommentPage();
    }
    final douban = _douban;
    if (douban == null || !isEnabled) return const ExternalCommentPage();
    try {
      final candidates = await douban.searchMeta(query);
      if (!_commentsCurrent(generation)) return const ExternalCommentPage();
      final chosen = MetaMatchRules.choose(candidates, query: query);
      if (chosen == null) {
        _note('短评：豆瓣未命中，跳过');
        return const ExternalCommentPage();
      }
      return await comments(chosen.identity, offset: offset, limit: limit);
    } catch (_) {
      _note('短评检索失败', warn: true);
      return const ExternalCommentPage();
    }
  }

  /// 详情页短评（多来源 + 分页）。
  ///
  /// 来源按 [MetaSourceKind] 顺序尝试，第一个给出条目的来源就作为本页来源；
  /// 现阶段只有豆瓣有公开接口（Bangumi 无 comments 端点，实测 404），
  /// 但接口形状按「可加第三家」设计：新增来源只需在这里多一行。
  Future<ExternalCommentPage> comments(
    MetaIdentity identity, {
    int offset = 0,
    int limit = 5,
  }) async {
    if (!isEnabled || identity.kind != MetaSourceKind.douban) {
      return const ExternalCommentPage();
    }
    final generation = _commentsEpoch;
    final douban = _douban;
    if (douban == null) return const ExternalCommentPage();
    try {
      final page = await douban.metaInterests(
        identity.id,
        isTv: identity.isTv,
        start: offset,
        count: limit,
      );
      if (!_commentsCurrent(generation)) return const ExternalCommentPage();
      final parsed = externalComments(
        page.items,
        source: MetaSourceKind.douban,
        offset: offset,
        total: page.total,
        pageSize: limit,
      );
      if (parsed.comments.isNotEmpty) {
        _note('短评 ${parsed.comments.length}/${parsed.total} 来源=豆瓣');
      }
      return parsed;
    } catch (_) {
      _note('短评获取失败', warn: true);
      return const ExternalCommentPage();
    }
  }

  Future<List<String>> _optionalStrings(Future<List<String>> Function() load) async {
    try { return await load(); } catch (_) { return const []; }
  }

  Future<List<Map<String, Object?>>> _optional(
    Future<List<Map<String, Object?>>> Function() load,
  ) async {
    try { return await load(); } catch (_) { return const []; }
  }
}
