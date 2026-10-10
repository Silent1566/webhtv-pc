/// 人物作品筛选（对齐默影视 `TmdbPersonWorkFilters`）。
///
/// 用户反馈 2026-10-10：「人员介绍页也不支持按分类筛选：电视，电影，参演，导演等」。
///
/// 默影视的做法是**两个正交维度**同时筛选，每个选项带计数：
///
/// - **部门**（该人在这部作品里干什么）：全部部门 / 出演 / 导演 / 编剧 / 制片 / …；
/// - **类型**（作品本身是什么）：全部类型 / 电影 / 剧集。
///
/// 两者的交集就是结果。部门取自 TMDB 的 `department`（归一成中文，与
/// `tmdbCreatorJobLabel` 同一套词表），类型取自条目的 `mediaType`。
///
/// 放在 `core/` 而不是 UI 里：这是**纯逻辑**（无 Flutter 依赖），可以脱离 widget
/// 单独测，也正是缺陷最容易出错的地方（计数、去重、交集）。
library;

import 'tmdb_detail_model.dart';
import 'tmdb_identity.dart';

/// 部门筛选键：`all` 表示「全部部门」。
abstract final class PersonWorkDepartment {
  static const String all = 'all';

  /// 出演（`department == Acting` 或该条目来自 `cast` 列表）。
  static const String cast = 'cast';

  /// 部门键前缀，避免与 [all] / [cast] 撞名。
  static const String prefix = 'department:';

  /// 由中文身份标签生成键（与 `tmdbCreatorJobLabel` 输出对齐）。
  static String of(String label) => '$prefix$label';

  /// 键 → 展示名。
  static String label(String key) {
    if (key == all) return '全部部门';
    if (key == cast) return '出演';
    if (key.startsWith(prefix)) return key.substring(prefix.length);
    return key;
  }
}

/// 类型筛选键。
abstract final class PersonWorkMedia {
  static const String all = 'all';
  static const String movie = 'movie';
  static const String tv = 'tv';

  static String label(String key) => switch (key) {
    movie => '电影',
    tv => '剧集',
    _ => '全部类型',
  };
}

/// 一个筛选选项（键 + 展示名 + 命中数量）。
class PersonWorkFilterOption {
  const PersonWorkFilterOption({
    required this.key,
    required this.label,
    required this.count,
  });

  final String key;
  final String label;
  final int count;
}

/// 人物作品的筛选器。
///
/// 构造时按 `(mediaType, tmdbId)` 去重（同一作品可能既在 `cast` 又在 `crew`，
/// 也可能同时是「导演」与「编剧」）；一个人在同一作品里的多个身份会合并成多个
/// 部门归属，因此 `部门计数之和` 可能大于 `全部` 的数量——这与默影视一致。
class PersonWorkFilters {
  PersonWorkFilters._({
    required this.all,
    required this.departmentWorks,
    required this.mediaWorks,
  });

  /// 全部作品（去重后，保持原始顺序）。
  final List<TmdbPersonWork> all;

  /// 部门键 → 作品（仅供 [departmentOptions] / [filter] 使用）。
  final Map<String, List<TmdbPersonWork>> departmentWorks;

  /// 类型键 → 作品（仅供 [mediaOptions] / [filter] 使用）。
  final Map<String, List<TmdbPersonWork>> mediaWorks;

  /// 从 `cast` / `crew` 两组作品构造。
  ///
  /// [castWorks] 一律归入「出演」；[crewWorks] 按其 `job`/`department` 归一后的
  /// 中文身份归入对应部门（认不出身份的归入「其他」，与默影视 `department:Other` 一致）。
  static PersonWorkFilters from(
    List<TmdbPersonWork> castWorks,
    List<TmdbPersonWork> crewWorks,
  ) {
    final all = <String, TmdbPersonWork>{};
    final byDepartment = <String, List<TmdbPersonWork>>{};
    final byMedia = <String, List<TmdbPersonWork>>{};

    void add(String departmentKey, TmdbPersonWork work) {
      final item = work.item;
      final key = _keyOf(item);
      all.putIfAbsent(key, () => work);
      _putUnique(byDepartment, departmentKey, work, key);
      if (item.isMovie) {
        _putUnique(byMedia, PersonWorkMedia.movie, work, key);
      } else if (item.isTv) {
        _putUnique(byMedia, PersonWorkMedia.tv, work, key);
      }
    }

    for (final work in castWorks) {
      add(PersonWorkDepartment.cast, work);
    }
    for (final work in crewWorks) {
      add(_departmentKeyOf(work), work);
    }

    return PersonWorkFilters._(
      all: all.values.toList(growable: false),
      departmentWorks: byDepartment,
      mediaWorks: byMedia,
    );
  }

  /// 部门选项（含「全部部门」，计数为全部作品数；无作品的选项不出现）。
  List<PersonWorkFilterOption> departmentOptions() => [
    PersonWorkFilterOption(
      key: PersonWorkDepartment.all,
      label: PersonWorkDepartment.label(PersonWorkDepartment.all),
      count: all.length,
    ),
    for (final entry in departmentWorks.entries)
      if (entry.value.isNotEmpty)
        PersonWorkFilterOption(
          key: entry.key,
          label: PersonWorkDepartment.label(entry.key),
          count: entry.value.length,
        ),
  ];

  /// 类型选项（含「全部类型」，无作品的类型不出现）。
  List<PersonWorkFilterOption> mediaOptions() => [
    PersonWorkFilterOption(
      key: PersonWorkMedia.all,
      label: PersonWorkMedia.label(PersonWorkMedia.all),
      count: all.length,
    ),
    for (final key in const [PersonWorkMedia.movie, PersonWorkMedia.tv])
      if ((mediaWorks[key] ?? const []).isNotEmpty)
        PersonWorkFilterOption(
          key: key,
          label: PersonWorkMedia.label(key),
          count: mediaWorks[key]!.length,
        ),
  ];

  /// 取两个维度的**交集**；任一维度为「全部」时即退化为另一个维度。
  List<TmdbPersonWork> filter({
    String department = PersonWorkDepartment.all,
    String media = PersonWorkMedia.all,
  }) {
    final departments = departmentWorks[department];
    final medias = mediaWorks[media];
    final departmentAll = department == PersonWorkDepartment.all;
    final mediaAll = media == PersonWorkMedia.all;
    if (departmentAll && mediaAll) return List<TmdbPersonWork>.of(all);
    if (departmentAll) return List<TmdbPersonWork>.of(medias ?? const []);
    if (mediaAll) return List<TmdbPersonWork>.of(departments ?? const []);

    final allowed = <String>{
      for (final work in medias ?? const <TmdbPersonWork>[]) _keyOf(work.item),
    };
    return [
      for (final work in departments ?? const <TmdbPersonWork>[])
        if (allowed.contains(_keyOf(work.item))) work,
    ];
  }

  static String _departmentKeyOf(TmdbPersonWork work) {
    final label = tmdbCreatorJobLabel(
      work.job.isEmpty ? null : work.job,
      work.department.isEmpty ? null : work.department,
    );
    if (label != null) return PersonWorkDepartment.of(label);
    // 演员条目（`character` 非空）即使混在 crew 里也归「出演」。
    if (work.isCast) return PersonWorkDepartment.cast;
    return PersonWorkDepartment.of('其他');
  }

  static String _keyOf(TmdbItem item) => '${item.mediaType.name}:${item.tmdbId}';

  static void _putUnique(
    Map<String, List<TmdbPersonWork>> map,
    String key,
    TmdbPersonWork work,
    String itemKey,
  ) {
    final list = map.putIfAbsent(key, () => <TmdbPersonWork>[]);
    for (final existing in list) {
      if (_keyOf(existing.item) == itemKey) return;
    }
    list.add(work);
  }
}
