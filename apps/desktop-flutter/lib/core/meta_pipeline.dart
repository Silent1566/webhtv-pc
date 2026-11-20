/// 多来源元数据管线：逐字段决定「优先级链」还是「并行聚合」。
///
/// 用户要求（2026-11-18）：TMDB、豆瓣、Bangumi、Wikidata 等允许同时生效，
/// 由设置决定每个字段的取数方式：
/// - priority（优先）：按顺序逐个来源尝试，取到即停，取不到才轮到下一个；
/// - aggregate（聚合）：所有来源并行取，结果合并（照片、评论这类是加法）。
///
/// 这一层是纯逻辑：不依赖 Flutter、不依赖 dart:io、不发起请求。
library;

import 'meta_source.dart';

/// 可单独配置的元数据字段。
enum MetaField {
  title, overview, poster, backdrop, cast, crew, genres,
  countries, languages, releaseDate, rating, photos, comments,
  personBiography, personPhotos;

  String get label => switch (this) {
    MetaField.title => '标题',
    MetaField.overview => '简介',
    MetaField.poster => '海报',
    MetaField.backdrop => '背景图',
    MetaField.cast => '演职人员',
    MetaField.crew => '制作团队',
    MetaField.genres => '类型',
    MetaField.countries => '地区',
    MetaField.languages => '语言',
    MetaField.releaseDate => '首播/上映',
    MetaField.rating => '评分',
    MetaField.photos => '照片/剧照',
    MetaField.comments => '评论',
    MetaField.personBiography => '人物简介',
    MetaField.personPhotos => '人物照片',
  };

  /// 稳定机器名（settings.json 用，改中文文案不影响它）。
  String get key => name;

  static MetaField? parse(Object? value) {
    if (value is! String) return null;
    for (final field in MetaField.values) {
      if (field.name == value) return field;
    }
    return null;
  }
}

/// 单个字段的取数方式。
enum MetaFieldMode {
  priority,
  aggregate;

  String get label => switch (this) {
    MetaFieldMode.priority => '优先（取到即停）',
    MetaFieldMode.aggregate => '聚合（全部并行）',
  };

  String get key => name;

  static MetaFieldMode? parse(Object? value) {
    if (value is! String) return null;
    for (final mode in MetaFieldMode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }
}

/// 一个字段的规则：模式 + 来源顺序。
class MetaFieldRule {
  const MetaFieldRule({required this.field, required this.mode, required this.order});

  final MetaField field;
  final MetaFieldMode mode;
  final List<MetaSourceKind> order;

  MetaFieldRule copyWith({MetaFieldMode? mode, List<MetaSourceKind>? order}) =>
      MetaFieldRule(field: field, mode: mode ?? this.mode, order: order ?? this.order);

  Map<String, Object?> toJson() => {
    'mode': mode.key,
    'order': [for (final source in order) source.key],
  };

  /// 解析一条规则；非法值回落到默认管线里的同名字段。
  static MetaFieldRule? fromJson(MetaField field, Object? value) {
    if (value is! Map) return null;
    final fallback = MetaPipeline.defaults.ruleOf(field);
    final mode = MetaFieldMode.parse(value['mode']) ?? fallback.mode;
    final rawOrder = value['order'];
    final order = <MetaSourceKind>[];
    if (rawOrder is List) {
      for (final item in rawOrder) {
        final kind = MetaSourceKind.parse(item);
        if (kind != null &&
            (kind != MetaSourceKind.source || MetaPipeline.supportsSource(field)) &&
            !order.contains(kind)) {
          order.add(kind);
        }
      }
    }
    return MetaFieldRule(
      field: field,
      mode: mode,
      // 作品字段保留显式空顺序，避免重新启用用户停用的来源。
      order: order.isEmpty &&
              !(rawOrder is List && rawOrder.isEmpty && MetaPipeline.supportsSource(field))
          ? fallback.order
          : order,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MetaFieldRule &&
      other.field == field &&
      other.mode == mode &&
      _sameOrder(other.order, order);

  @override
  int get hashCode => Object.hash(field, mode, Object.hashAll(order));

  static bool _sameOrder(List<MetaSourceKind> a, List<MetaSourceKind> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'MetaFieldRule($field $mode $order)';
}

/// 整套管线规则。
class MetaPipeline {
  const MetaPipeline._(this.rules);

  final Map<MetaField, MetaFieldRule> rules;

  static const List<MetaSourceKind> _textOrder = [
    MetaSourceKind.tmdb, MetaSourceKind.douban, MetaSourceKind.bangumi,
    MetaSourceKind.wikidata, MetaSourceKind.source,
  ];

  static MetaFieldRule _priority(MetaField field) =>
      MetaFieldRule(field: field, mode: MetaFieldMode.priority, order: _textOrder);

  /// 默认管线：文本类逐字段优先（TMDB → 豆瓣 → Bangumi），
  /// 照片与评论是加法，默认并行聚合。Wikidata 接入后只需加进 order。
  static MetaFieldRule _aggregate(MetaField field, List<MetaSourceKind> order) =>
      MetaFieldRule(field: field, mode: MetaFieldMode.aggregate, order: order);

  /// 默认值（Lead 定，2026-11-18）：
  /// - 文本字段：TMDB → 豆瓣 → Bangumi → Wikidata → 爬虫源，取到即停；
  /// - 人物简介：Bangumi（有 summary）→ Wikidata（最全）→ TMDB → 豆瓣（无简介）；
  /// - 作品剧照：TMDB + 豆瓣 **同类聚合**；人物照片：豆瓣 + Bangumi 同类聚合
  ///   （用户决策 A：横向剧照与竖向写真不混排，所以拆成两个字段）。
  static final MetaPipeline defaults = MetaPipeline._({
    for (final field in MetaField.values)
      field: switch (field) {
        MetaField.photos => _aggregate(field, const [
          MetaSourceKind.tmdb,
          MetaSourceKind.douban,
        ]),
        // 评分是「同时看几家」，不是「挑一家」：默认聚合，TMDB / 豆瓣 / Bangumi
        // 各自的分并列显示（同源去重由页面负责）。
        MetaField.rating => _aggregate(field, const [
          MetaSourceKind.tmdb,
          MetaSourceKind.douban,
          MetaSourceKind.bangumi,
        ]),
        MetaField.comments => _aggregate(field, const [
          MetaSourceKind.douban,
        ]),
        // TMDB 人物照片本来由 TMDB 资料页自取；这一项决定**外部人物**在有跨源
        // 映射时要不要也去 TMDB 取。默认放首位（有就用，取不到静默跳过）。
        MetaField.personPhotos => _aggregate(field, const [
          MetaSourceKind.tmdb,
          MetaSourceKind.douban,
          MetaSourceKind.bangumi,
        ]),
        MetaField.personBiography => MetaFieldRule(
          field: field,
          mode: MetaFieldMode.priority,
          order: const [
            MetaSourceKind.bangumi,
            MetaSourceKind.wikidata,
            MetaSourceKind.tmdb,
            MetaSourceKind.douban,
          ],
        ),
        _ => _priority(field),
      },
  });

  MetaFieldRule ruleOf(MetaField field) => rules[field] ?? defaults.rules[field]!;

  MetaFieldMode modeOf(MetaField field) => ruleOf(field).mode;

  /// 该字段按顺序尝试的来源（聚合模式同样按此顺序拼接）。
  List<MetaSourceKind> orderOf(MetaField field) => ruleOf(field).order;

  /// 爬虫源只提供当前资源自身的十个作品字段。
  static bool supportsSource(MetaField field) =>
      defaults.ruleOf(field).order.contains(MetaSourceKind.source);

  /// 为新增爬虫源之前保存的规则追加末位兜底；存储层负责仅迁移一次。
  MetaPipeline withSourceFallbackAdded() {
    var result = this;
    for (final field in MetaField.values) {
      final rule = ruleOf(field);
      if (supportsSource(field) && !rule.order.contains(MetaSourceKind.source)) {
        result = result.withRule(
          rule.copyWith(order: [...rule.order, MetaSourceKind.source]),
        );
      }
    }
    return result;
  }

  /// 勾选/取消一个来源；作品字段允许全部停用，其余字段保留默认顺序。
  MetaPipeline toggleSource(MetaField field, MetaSourceKind source) {
    if (source == MetaSourceKind.source && !supportsSource(field)) return this;
    final rule = ruleOf(field);
    final order = [...rule.order];
    if (!order.remove(source)) order.add(source);
    return withRule(
      rule.copyWith(
        order: order.isEmpty && !supportsSource(field)
            ? defaults.ruleOf(field).order
            : order,
      ),
    );
  }

  /// 拖动排序：把 from 位置的来源移到 to。
  MetaPipeline moveSource(MetaField field, int from, int to) {
    final rule = ruleOf(field);
    if (from < 0 || from >= rule.order.length) return this;
    final order = [...rule.order];
    final item = order.removeAt(from);
    order.insert(to.clamp(0, order.length), item);
    return withRule(rule.copyWith(order: order));
  }

  MetaPipeline withRule(MetaFieldRule rule) =>
      MetaPipeline._({...rules, rule.field: rule});

  bool get isDefault {
    for (final entry in defaults.rules.entries) {
      if (rules[entry.key] != entry.value) return false;
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    for (final entry in rules.entries) entry.key.key: entry.value.toJson(),
  };

  /// 解析持久化规则：未知字段/非法值一律忽略，缺失字段回落到默认。
  static MetaPipeline fromJson(Object? value) {
    if (value is! Map) return defaults;
    final rules = Map<MetaField, MetaFieldRule>.from(defaults.rules);
    for (final entry in value.entries) {
      final field = MetaField.parse(entry.key);
      if (field == null) continue;
      final rule = MetaFieldRule.fromJson(field, entry.value);
      if (rule != null) rules[field] = rule;
    }
    return MetaPipeline._(rules);
  }
}

/// 按字段规则执行取数（纯函数，不绑定具体客户端）。
abstract final class MetaPipelineResolver {
  /// priority：按顺序尝试，第一个非空结果即为答案；全空返回 null。
  static Future<T?> resolvePriority<T>({
    required MetaPipeline pipeline,
    required MetaField field,
    required Future<T?> Function(MetaSourceKind source) fetch,
  }) async {
    for (final source in pipeline.orderOf(field)) {
      final value = await fetch(source);
      if (_hasValue(value)) return value;
    }
    return null;
  }

  /// aggregate：并行请求所有来源，按顺序拼接并按 dedupeKey 去重。
  static Future<List<T>> resolveAggregate<T>({
    required MetaPipeline pipeline,
    required MetaField field,
    required Future<List<T>> Function(MetaSourceKind source) fetch,
    Object? Function(T item)? dedupeKey,
  }) async {
    final sources = pipeline.orderOf(field);
    final results = await Future.wait([

      for (final source in sources) fetch(source),
    ]);
    final merged = <T>[];
    final seen = <Object>{};
    for (final list in results) {
      for (final item in list) {
        final Object key = dedupeKey?.call(item) ?? item as Object;
        if (!seen.add(key)) continue;
        merged.add(item);
      }
    }
    return merged;
  }

  static bool _hasValue(Object? value) {
    if (value == null) return false;
    if (value is String) return value.trim().isNotEmpty;
    if (value is Iterable) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return true;
  }
}