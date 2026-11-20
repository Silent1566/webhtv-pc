/// 外部元数据源的标识与人物引用。
///
/// 这一层**不依赖任何其它 core 文件**：`tmdb_media.dart`（`TmdbPerson` 要带上
/// 来源）与 `external_meta.dart`（身份/候选/打分）都要引用它，若把
/// [MetaSourceKind] 放进后者，`tmdb_media.dart` 就会反向依赖「外部元数据」整层。
///
/// 关键契约：
/// - 来源顺序由逐字段管线决定；爬虫源是当前资源自身的数据，默认排最后；
/// - 站点名只在这里定义一次，UI 不得各处拼字符串（对齐 `RatingBrand` 的做法）。
library;

/// 元数据来源；爬虫源不发请求，只提供当前资源已有的字段。
enum MetaSourceKind {
  tmdb,
  douban,
  bangumi,
  wikidata,
  source;

  /// 用户可见的站点名。
  String get label => switch (this) {
    MetaSourceKind.tmdb => 'TMDB',
    MetaSourceKind.douban => '豆瓣',
    MetaSourceKind.bangumi => 'Bangumi',
    MetaSourceKind.wikidata => 'Wikidata',
    MetaSourceKind.source => '爬虫源',
  };

  /// 稳定的机器名（缓存键、widget key、日志用）。
  String get key => switch (this) {
    MetaSourceKind.tmdb => 'tmdb',
    MetaSourceKind.douban => 'douban',
    MetaSourceKind.bangumi => 'bangumi',
    MetaSourceKind.wikidata => 'wikidata',
    MetaSourceKind.source => 'source',
  };

  /// 可按外部身份请求的兜底源；爬虫源只读取当前资源，不具备外部身份。
  bool get isFallback => this != MetaSourceKind.tmdb && this != MetaSourceKind.source;

  /// 从机器名反解；无法识别返回 `null`。
  static MetaSourceKind? parse(Object? value) {
    if (value is! String) return null;
    switch (value.trim().toLowerCase()) {
      case 'tmdb':
        return MetaSourceKind.tmdb;
      case 'douban':
        return MetaSourceKind.douban;
      case 'bangumi':
        return MetaSourceKind.bangumi;
      case 'wikidata':
        return MetaSourceKind.wikidata;
      case 'source':
        return MetaSourceKind.source;
      default:
        return null;
    }
  }
}

// ---------------------------------------------------------------------------
// 人物引用
// ---------------------------------------------------------------------------

/// 一个人的外部来源引用（豆瓣 `celebrity/{id}` / Bangumi `person/{id}`）。
///
/// 为什么不是复用 `TmdbPerson.personId`：TMDB 的 personId 是它自己的号段，
/// 两家外部站的 id 与它**没有任何关系**，混在一个 int 里迟早串人。这里显式带上
/// 来源，详情页据此决定「用哪个客户端去取简介/作品」。
class MetaPersonRef {
  const MetaPersonRef({required this.kind, required this.id, this.name = ''});

  /// 唯一合法入口：`id <= 0` 或来源为 TMDB/爬虫源时返回 `null`
  /// （TMDB 人物不应该走这条兜底链路）。
  static MetaPersonRef? of(MetaSourceKind? kind, int? id, {String name = ''}) {
    if (kind == null || !kind.isFallback) return null;
    if (id == null || id <= 0) return null;
    return MetaPersonRef(kind: kind, id: id, name: name);
  }

  final MetaSourceKind kind;

  /// 该来源内的**原始**人物 id。
  ///
  /// Wikidata 用 Q 号的数字部分（Q42 → 42），[wikidataId] 负责还原成 `Q42`：
  /// 三个来源的 id 都是正整数，混在一个 int 里靠 [kind] 区分，不必再加一层
  /// 字符串 id 字段。
  final int id;

  /// Wikidata 实体的 Q 号（`Q42`）；其它来源返回空串。
  String get wikidataId => kind == MetaSourceKind.wikidata ? 'Q$id' : '';

  /// 人物姓名（可能是空串：兜底链路只拿到名字时就够用了）。
  final String name;

  /// 稳定字符串键，形如 `douban:1051526`。
  String get key => '${kind.key}:$id';

  /// 该人物的来源页面地址；没有可打开的地址时为空串。
  String get url => switch (kind) {
    MetaSourceKind.douban => 'https://movie.douban.com/celebrity/$id/',
    MetaSourceKind.bangumi => 'https://bgm.tv/person/$id',
    MetaSourceKind.wikidata => 'https://www.wikidata.org/wiki/$id',
    MetaSourceKind.tmdb || MetaSourceKind.source => '',
  };

  @override
  bool operator ==(Object other) =>
      other is MetaPersonRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'MetaPersonRef($key $name)';
}
