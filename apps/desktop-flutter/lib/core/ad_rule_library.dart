/// 本地用户广告规则库（安卓 UserAdRuleStore + AdRuleManageDialog 的 PC 化）。
///
/// 只做**本地**规则：不订阅远程规则源，也不内置任何通用广告域名——
/// 「什么算广告」是用户的知识，仓库不能替所有站点拍板（同 ad_rules.dart 的
/// 安全约束：规则为空时清洗必须原样返回）。
///
/// 与 AI 去广规则（services/ai_content/ad_rule_service.dart）是两条独立通路：
/// 那边是播放期按会话生成的临时规则，这边是用户长期维护的本地库，
/// 落盘路径与数据格式都不共用，避免一次清理动作把用户的库覆盖掉。
///
/// 本文件只做纯逻辑 + 一个 JSON 存储：不碰 AppState、不碰代理、不做网络请求。
library;

import 'dart:convert';
import 'dart:io';

import '../services/log_service.dart';
import 'ad_rules.dart';
import 'protocol.dart';

/// 文件格式版本。未来版本按「没有记录」处理，绝不猜新语义。
const int adRuleLibraryVersion = 1;

/// 用户手工维护的来源标记。
const String kAdRuleSourceUser = 'user';

/// 规则库的磁盘文件名（数据目录根部）。
const String adRuleLibraryFileName = 'ad_rule_library.json';

/// 从外部 JSON 导入的来源标记：区分「我写的」和「我粘进来的」，
/// 出问题时可整体清掉而不误伤手写规则。
const String kAdRuleSourceImported = 'imported';

/// 一条本地规则集。
///
/// 一条 = 一个可开关的规则单元（安卓 UserAdRule）：ads 是主机清单，
/// hlsRules 是分片级规则原文（保持 JSON 原样，导出/再导入不失真）。
class AdRuleEntry {
  AdRuleEntry({
    required this.id,
    this.name = '',
    this.enabled = true,
    List<String> ads = const [],
    List<Map<String, Object?>> hlsRules = const [],
    this.source = kAdRuleSourceUser,
    this.createdAt = 0,
    this.updatedAt = 0,
  }) : ads = List<String>.of(ads),
       hlsRules = [for (final rule in hlsRules) Map<String, Object?>.of(rule)];

  final String id;
  final String name;
  final bool enabled;
  final List<String> ads;

  /// 分片级规则原文。为什么存 Map 而不是 HlsAdRule：导出要能原样回写，
  /// 用户手写的字段（哪怕当前版本不认识）不该被解析器抹掉。
  final List<Map<String, Object?>> hlsRules;
  final String source;
  final int createdAt;
  final int updatedAt;

  /// 规则条数摘要（列表页一行显示用）。
  String get summary {
    final hostCount = ads.length;
    final ruleCount = hlsRules.length;
    return '$hostCount 个主机 · $ruleCount 条 HLS 规则';
  }

  AdRuleEntry copyWith({
    String? id,
    String? name,
    bool? enabled,
    List<String>? ads,
    List<Map<String, Object?>>? hlsRules,
    String? source,
    int? createdAt,
    int? updatedAt,
  }) => AdRuleEntry(
    id: id ?? this.id,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    ads: ads ?? this.ads,
    hlsRules: hlsRules ?? this.hlsRules,
    source: source ?? this.source,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'enabled': enabled,
    'ads': ads,
    'hlsRules': hlsRules,
    'source': source,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
  };

  /// 宽松解析：缺 id 的条目无法去重也无法更新，只能丢弃（调用方据此记 rejected）。
  ///
  /// ads 里的非字符串/空串静默略过——那是配置作者的手抖，不是语义；
  /// 但 hlsRules 的**规则级**非法条目必须进导入报告，不能在这里吞掉：
  /// 这里只过滤「根本不是对象」的项，语义校验交给 validateHlsRulesJson。
  static AdRuleEntry? fromJson(Object? raw) {
    final map = asMap(raw);
    final id = asNonEmptyString(map['id']);
    if (id == null) return null;
    return AdRuleEntry(
      id: id,
      name: asNonEmptyString(map['name']) ?? '',
      enabled: asFlag(map['enabled'], fallback: true),
      ads: _stringList(map['ads']),
      hlsRules: _ruleMaps(map['hlsRules']),
      source: asNonEmptyString(map['source']) ?? kAdRuleSourceUser,
      createdAt: asInt(map['createdAt']) ?? 0,
      updatedAt: asInt(map['updatedAt']) ?? 0,
    );
  }
}

/// 一个规则库（entries 只是容器：读写语义都在 AdRuleLibraryStore）。
class AdRuleLibrary {
  AdRuleLibrary({List<AdRuleEntry> entries = const []})
    : entries = List<AdRuleEntry>.of(entries);

  List<AdRuleEntry> entries;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': adRuleLibraryVersion,
    'entries': [for (final entry in entries) entry.toJson()],
  };
}

/// 导入结果：**必须**能回答「哪几条没进来、为什么」。
class ImportReport {
  ImportReport({
    this.added = 0,
    this.updated = 0,
    this.rejected = 0,
    List<String> reasons = const [],
  }) : reasons = List<String>.of(reasons);

  int added;
  int updated;
  int rejected;

  /// 每条被丢弃条目的原因（含它属于哪个规则集）。
  List<String> reasons;

  bool get changed => added > 0 || updated > 0;

  String get summary => '新增 $added 条、更新 $updated 条、丢弃 $rejected 条';

  @override
  String toString() => 'ImportReport($summary)';
}

/// 一组原始 hlsRules 的校验结果：可用的原文 + 被丢弃的原因。
class HlsRuleValidation {
  const HlsRuleValidation({required this.rules, required this.reasons});

  final List<Map<String, Object?>> rules;
  final List<String> reasons;

  bool get hasRejections => reasons.isNotEmpty;
}

/// 用 HlsAdRule.listFrom 逐条校验原始规则数组。
///
/// 为什么逐条而不是整组一次过：listFrom 会把非法项静默跳过，整组调用后
/// 根本不知道少了几条、少的是哪条——用户存了 5 条只剩 3 条却毫无提示，
/// 那正是最容易在事故里被当成「规则没生效」的假象。
HlsRuleValidation validateHlsRulesJson(Object? raw) {
  final kept = <Map<String, Object?>>[];
  final reasons = <String>[];
  var items = raw;
  if (items == null) {
    return const HlsRuleValidation(rules: [], reasons: []);
  }
  if (items is String) {
    final text = items.trim();
    if (text.isEmpty) {
      return const HlsRuleValidation(rules: [], reasons: []);
    }
    try {
      items = jsonDecode(text);
    } on FormatException catch (error) {
      final message = error.message;
      return HlsRuleValidation(
        rules: const [],
        reasons: ['HLS 规则不是合法 JSON：$message'],
      );
    }
  }
  // 单条规则对象也接受：粘贴时用户经常只剪一条。
  final list = items is List ? items : <Object?>[items];
  for (var index = 0; index < list.length; index++) {
    final position = index + 1;
    final label = '第 $position 条规则';
    final map = asMap(list[index]);
    if (map.isEmpty) {
      reasons.add('$label不是对象，已丢弃');
      continue;
    }
    if (HlsAdRule.listFrom([map]).isNotEmpty) {
      kept.add(map);
      continue;
    }
    final detail = _describeRuleRejection(map);
    reasons.add('$label$detail，已丢弃');
  }
  return HlsRuleValidation(rules: kept, reasons: reasons);
}

/// 本地规则库的 JSON 存储。
///
/// 落盘约定与仓库其它 store 一致：临时文件 + 一次 rename 原子替换、
/// 顶层 version、读失败/版本不认识时记日志并降级为空库
/// （规则库损坏不该让设置页打不开，更不该把用户数据当成空库静默回写）。
class AdRuleLibraryStore {
  AdRuleLibraryStore({required this.path, this.log}) {
    _load();
  }

  /// 由调用方按 AppPaths 拼好；存储层不猜目录。
  final String path;

  final LogService? log;

  List<AdRuleEntry> _entries = const [];
  String? _loadError;

  List<AdRuleEntry> get entries => _entries;

  /// 非 null 表示磁盘上的库有问题（文件损坏 / 版本不认识 / 有记录不认识），
  /// 界面应如实展示：静默空库会让用户以为自己的规则被删了。
  String? get loadError => _loadError;

  AdRuleLibrary get library => AdRuleLibrary(entries: _entries);

  /// 能否安全写盘。
  ///
  /// 读错（文件损坏 / 版本不认识 / 有记录不认识）时库里的内容是**不完整**的，
  /// 此时哪怕只追加一条也会把用户原文件覆盖成「空库 + 新条目」——那是静默销毁。
  /// 仓库先例：local_source_enable_store.dart 在读错时同样拒绝写入。
  bool get writable => _loadError == null;

  /// 显式「重新开始」：先把读不懂的原文件改名成 .corrupt-<时间戳> 备份，
  /// 再以空库重建。返回备份文件路径；没有原文件或改名失败返回 null。
  ///
  /// 为什么不直接删：用户那份文件里可能还有他能认出的规则，
  /// 覆盖之前必须留一份可找回的原文，并把路径告诉用户。
  String? backupAndStartOver() {
    final file = File(path);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    String? backupPath;
    try {
      if (file.existsSync()) {
        backupPath = '$path.corrupt-$stamp';
        file.renameSync(backupPath);
      }
    } catch (error) {
      log?.warning('备份损坏的本地规则库失败：$error', scope: 'ad-rules');
      return null;
    }
    _loadError = null;
    _entries = const [];
    if (!_commit(const [])) {
      // 备份成功但新空库没写进去：保持不可写状态，别让界面以为已经好了。
      _loadError = '重新开始后写入空库失败';
      log?.warning(_loadError!, scope: 'ad-rules');
    }
    return backupPath;
  }

  /// 同 id 覆盖（幂等：重复添加同一条不会变成两条），不同 id 追加。
  bool add(AdRuleEntry entry) {
    final next = List<AdRuleEntry>.of(_entries);
    final index = next.indexWhere((existing) => existing.id == entry.id);
    if (index >= 0) {
      next[index] = entry;
    } else {
      next.add(entry);
    }
    return _commit(next);
  }

  /// 按 id 覆盖首个匹配；不存在返回 false（不造新记录）。
  bool update(AdRuleEntry entry) {
    final next = List<AdRuleEntry>.of(_entries);
    final index = next.indexWhere((existing) => existing.id == entry.id);
    if (index < 0) return false;
    next[index] = entry;
    return _commit(next);
  }

  bool remove(String id) {
    final next = [
      for (final entry in _entries)
        if (entry.id != id) entry,
    ];
    if (next.length == _entries.length) return false;
    return _commit(next);
  }

  bool setEnabled(String id, bool enabled) {
    final index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return false;
    // 值没变就不写盘：开关被界面连点时不该产生一串无意义的 rename。
    if (_entries[index].enabled == enabled) return true;
    final next = List<AdRuleEntry>.of(_entries);
    next[index] = next[index].copyWith(enabled: enabled, updatedAt: _now());
    return _commit(next);
  }

  /// 导出成可直接再导入的 JSON（version + entries）。
  String exportJson() =>
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'version': adRuleLibraryVersion,
        'entries': [for (final entry in _entries) entry.toJson()],
      });

  /// 导入外部 JSON：接受 {entries:[…]}、[…AdRuleEntry] 或单条对象。
  ///
  /// 去重口径：ads（排序后）+ hlsRules（规范化 JSON）相同视为同一条，
  /// 命中就**更新**而不是再追加一份——否则同一个站点被导入三次就多三份
  /// 一模一样的规则，用户看不出哪份才是有效的那份。
  ImportReport importJson(String text, {required String source}) {
    final report = ImportReport();
    if (_loadError != null) {
      // 读错时导入等于把原文件覆盖成「导入内容 + 丢掉读不出来的部分」。
      report.rejected += 1;
      report.reasons.add('本地规则库读取失败，已拒绝写入：$_loadError');
      return report;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      final message = error.message;
      report.rejected += 1;
      report.reasons.add('不是合法 JSON：$message');
      return report;
    }
    final rawEntries = _extractEntries(decoded);
    if (rawEntries == null) {
      report.rejected += 1;
      report.reasons.add('顶层必须是含 entries 数组的对象、规则数组或单个规则对象');
      return report;
    }
    final now = _now();
    final working = List<AdRuleEntry>.of(_entries);
    for (var index = 0; index < rawEntries.length; index++) {
      final position = index + 1;
      final raw = rawEntries[index];
      final entry = AdRuleEntry.fromJson(raw);
      if (entry == null) {
        report.rejected += 1;
        report.reasons.add('第 $position 条缺少 id，无法保存');
        continue;
      }
      // 语义校验走原始 JSON：fromJson 已经滤掉了非对象项，
      // 在这里直接读原文才能把它们计入 rejected 并说明原因。
      final validation = validateHlsRulesJson(asMap(raw)['hlsRules']);
      if (validation.hasRejections) {
        report.rejected += validation.reasons.length;
        final entryId = entry.id;
        for (final reason in validation.reasons) {
          report.reasons.add('$entryId：$reason');
        }
      }
      final candidate = entry.copyWith(
        hlsRules: validation.rules,
        source: source,
        createdAt: entry.createdAt == 0 ? now : entry.createdAt,
        updatedAt: now,
      );
      final key = _dedupeKey(candidate);
      final duplicate = working.indexWhere(
        (existing) => _dedupeKey(existing) == key,
      );
      if (duplicate >= 0) {
        final existing = working[duplicate];
        // 保留既有 id 与本地开关：id 是别处可能引用的身份，开关是用户当前的
        // 取舍——导入新内容不该顺手把用户关掉的一条重新打开。
        working[duplicate] = candidate.copyWith(
          id: existing.id,
          enabled: existing.enabled,
          // 来源也保留：这条规则是用户在本机手写的，导入只是改了它的内容，
          // 不该把它伪装成「导入的」——那会让「清空导入规则」误伤手写规则。
          source: existing.source,
          createdAt: existing.createdAt == 0 ? now : existing.createdAt,
        );
        report.updated += 1;
        continue;
      }
      final sameId = working.indexWhere((existing) => existing.id == entry.id);
      if (sameId >= 0) {
        final existing = working[sameId];
        final createdAt = existing.createdAt;
        // 同 id 命中只更新内容：本地开关是用户当前的取舍（导入不该把它重新
        // 打开），来源也要留住（见上）。
        working[sameId] = candidate.copyWith(
          enabled: existing.enabled,
          source: existing.source,
          createdAt: createdAt == 0 ? now : createdAt,
        );
        report.updated += 1;
        continue;
      }
      working.add(candidate);
      report.added += 1;
    }
    if (!report.changed) return report;
    if (!_commit(working)) {
      // 写盘失败时报告不能声称「已导入」：界面照着它去列表里找会找不到。
      report.rejected += report.added + report.updated;
      report.added = 0;
      report.updated = 0;
      report.reasons.add('写入本地规则库失败，本次导入未保存');
    }
    return report;
  }

  void _load() {
    final file = File(path);
    try {
      if (!file.existsSync()) {
        _entries = const [];
        return;
      }
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map || decoded['version'] != adRuleLibraryVersion) {
        _loadError = '本地规则库版本不认识，已按空库处理';
        log?.warning(_loadError!, scope: 'ad-rules');
        _entries = const [];
        return;
      }
      final kept = <AdRuleEntry>[];
      final seen = <String>{};
      var dropped = 0;
      for (final item in asList(decoded['entries'])) {
        final entry = AdRuleEntry.fromJson(item);
        // 同 id 只留第一条：文件里出现两份同 id 意味着它被手改过，
        // 认哪条都算猜，留第一条并如实报出来。
        if (entry == null || !seen.add(entry.id)) {
          dropped += 1;
          continue;
        }
        kept.add(entry);
      }
      _entries = List<AdRuleEntry>.unmodifiable(kept);
      if (dropped > 0) {
        _loadError = '本地规则库有 $dropped 条记录无法识别（已跳过）';
        log?.warning(_loadError!, scope: 'ad-rules');
      }
    } catch (error) {
      _loadError = '读取本地规则库失败，已按空库处理';
      log?.warning('$_loadError：$error', scope: 'ad-rules');
      _entries = const [];
    }
  }

  /// 原子写：.tmp 写完 flush，再用**一次 rename** 覆盖旧文件。
  bool _commit(List<AdRuleEntry> next) {
    if (_loadError != null) {
      // 兜底闸门：任何写入路径（add/update/remove/setEnabled/import）都不许
      // 在「读不懂原文件」时覆盖它，解除只能走 backupAndStartOver()。
      log?.warning('本地规则库处于读错状态，拒绝写入：$_loadError', scope: 'ad-rules');
      return false;
    }
    final temp = File('$path.tmp');
    try {
      final target = File(path);
      if (!target.parent.existsSync()) {
        target.parent.createSync(recursive: true);
      }
      temp.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'version': adRuleLibraryVersion,
          'entries': [for (final entry in next) entry.toJson()],
        }),
        flush: true,
      );
      temp.renameSync(path);
    } catch (error) {
      log?.warning('写入本地规则库失败（内存与旧文件保持不变）：$error', scope: 'ad-rules');
      try {
        if (temp.existsSync()) temp.deleteSync();
      } catch (_) {
        // 临时文件清理失败不该盖住真正的写入错误。
      }
      return false;
    }
    _entries = List<AdRuleEntry>.unmodifiable(next);
    return true;
  }
}

/// 合并「配置内联规则」与「本地规则库」得到当前生效规则。
///
/// 顺序即优先级：配置内联的规则先入，库里的同名 host / 同 id 规则不再重复加入。
/// adBlockEnabled=false 一律返回空集——总开关关掉时任何来源的规则都不该生效，
/// 否则「关了广告过滤却还在删分片」是最难解释的一类 bug。
AdRuleSet resolveEffectiveRules({
  required AppConfig? config,
  required List<AdRuleEntry> library,
  required bool adBlockEnabled,
}) {
  if (!adBlockEnabled) return const AdRuleSet.empty();
  final hosts = <String>[];
  final seenHosts = <String>{};
  final rules = <HlsAdRule>[];
  final seenRules = <String>{};
  void merge(AdRuleSet source) {
    for (final host in source.adHosts) {
      if (seenHosts.add(host)) hosts.add(host);
    }
    for (final rule in source.hlsRules) {
      if (seenRules.add(_ruleKey(rule))) rules.add(rule);
    }
  }

  // 配置内联规则照旧走 AdRuleSet.fromConfig：ADS 既接受域名也接受 URL，
  // 这套归一化只该有一份实现，重复实现迟早和清洗端判得不一样。
  if (config != null) merge(_rulesOfConfig(config));
  for (final entry in library) {
    if (!entry.enabled) continue;
    merge(_rulesOfEntry(entry));
  }
  return AdRuleSet(
    adHosts: List<String>.unmodifiable(hosts),
    hlsRules: List<HlsAdRule>.unmodifiable(rules),
  );
}

/// 单个规则集条目解析成 AdRuleSet，与配置走同一套归一化。
AdRuleSet _rulesOfEntry(AdRuleEntry entry) =>
    AdRuleSet.fromConfig(AppConfig(ads: entry.ads, hlsRules: entry.hlsRules));

AdRuleSet _rulesOfConfig(AppConfig config) => AdRuleSet.fromConfig(config);

/// 规则去重键。
///
/// 显式 id 就是身份（跨配置与库的同 id 视为同一条）。但 HlsAdRule.listFrom
/// 会给缺 id 的规则补 hls-序号，两个规则集里各有一条无名规则就会撞上同一个
/// 假 id——按 id 去重会**误删**一条真规则，所以这类合成 id 改用结构指纹。
///
/// 已知代价：用户显式写成 hls-<数字> 的 id 也会被当成合成 id 处理——解析器
/// 补 id 的形态与用户的写法在解析后完全一致，无从区分。内容相同仍会去重，
/// 只是「同 id 不同内容」的两条不会互相覆盖，这比误删一条真规则安全。
String _ruleKey(HlsAdRule rule) {
  final id = rule.id;
  if (!_syntheticRuleId.hasMatch(id)) return 'id:$id';
  final shape = _canonicalJson(<String, Object?>{
    'playlistHostSuffixes': rule.playlistHostSuffixes,
    'playlistHostRegex': rule.playlistHostRegex,
    'hostSuffixes': rule.hostSuffixes,
    'segmentUrlRegex': rule.segmentUrlRegex,
    'minDuration': rule.minDuration,
    'maxDuration': rule.maxDuration,
    'requireDiscontinuity': rule.requireDiscontinuity,
    'requireCrossDomain': rule.requireCrossDomain,
    'minimumSignals': rule.minimumSignals,
    'playlistPath': rule.playlistPath,
    'excludeUrlRegex': rule.excludeUrlRegex,
  });
  return 'shape:$shape';
}

final RegExp _syntheticRuleId = RegExp(r'^hls-\d+$');

/// 导入去重键：主机清单排序去重 + 规则的规范化 JSON。
///
/// 主机走 AdRuleSet.fromConfig 归一化（URL 取 host、去端口、小写）而不是只
/// lowercase：ads:['https://AD.example/track.js'] 与 ads:['ad.example'] 指的是
/// 同一个广告主机，按原文比较会把同一条规则变成两条。
String _dedupeKey(AdRuleEntry entry) {
  final sortedAds = AdRuleSet.fromConfig(
    AppConfig(ads: entry.ads),
  ).adHosts.toList()..sort();
  return _canonicalJson(<String, Object?>{
    'ads': sortedAds,
    'hlsRules': entry.hlsRules,
  });
}

/// 键排序、去空值的 JSON：字段顺序或空数组写法不同但语义相同的两份规则，
/// 必须落到同一个去重键上。
String _canonicalJson(Object? value) => jsonEncode(_canonicalize(value));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final source = <String, Object?>{};
    value.forEach((key, item) => source[key.toString()] = item);
    final keys = source.keys.toList()..sort();
    return <String, Object?>{
      for (final key in keys)
        if (!_isCanonicalEmpty(source[key])) key: _canonicalize(source[key]),
    };
  }
  if (value is List) {
    final items = [
      for (final item in value)
        if (!_isCanonicalEmpty(item)) _canonicalize(item),
    ];
    // 字符串数组的顺序对判定无意义，排序后比较能让「hostSuffixes 换个写法」
    // 不再被当成另一条规则。
    if (items.every((item) => item is String)) {
      items.sort((a, b) => (a! as String).compareTo(b! as String));
    }
    return items;
  }
  if (value is String) return value.trim();
  return value;
}

bool _isCanonicalEmpty(Object? value) {
  if (value == null) return true;
  if (value is String) return value.trim().isEmpty;
  if (value is Iterable) return value.isEmpty;
  if (value is Map) return value.isEmpty;
  return false;
}

/// 「哪一条、为什么」——校验失败时给用户看的理由。
String _describeRuleRejection(Map<String, Object?> map) {
  for (final field in const [
    'playlistHostRegex',
    'segmentUrlRegex',
    'excludeUrlRegex',
  ]) {
    for (final pattern in _stringList(map[field])) {
      if (safeRuleRegex(pattern) == null) {
        return '的 $field 含无法安全编译的正则（$pattern）';
      }
    }
  }
  final hostSuffixes = _stringList(map['hostSuffixes']);
  final segmentUrlRegex = _stringList(map['segmentUrlRegex']);
  final minDuration = HlsAdRule.asDouble(map['minDuration']);
  final maxDuration = HlsAdRule.asDouble(map['maxDuration']);
  final requireDiscontinuity = map['requireDiscontinuity'] == true;
  final requireCrossDomain = map['requireCrossDomain'] == true;
  if (hostSuffixes.isEmpty &&
      segmentUrlRegex.isEmpty &&
      minDuration == null &&
      maxDuration == null &&
      !requireDiscontinuity &&
      !requireCrossDomain) {
    return '没有任何可用的分片信号（hostSuffixes / segmentUrlRegex / 时长 / '
        '不连续 / 跨域都为空）';
  }
  var signals = 0;
  if (hostSuffixes.isNotEmpty) signals += 1;
  if (segmentUrlRegex.isNotEmpty) signals += 1;
  if (minDuration != null && maxDuration != null) signals += 1;
  if (requireDiscontinuity) signals += 1;
  if (requireCrossDomain) signals += 1;
  final minimumSignals = asInt(map['minimumSignals']) ?? 1;
  if (minimumSignals < 1 || minimumSignals > signals) {
    return '的 minimumSignals=$minimumSignals 与声明的 $signals 个信号不匹配';
  }
  return '未能通过规则校验';
}

List<Object?>? _extractEntries(Object? decoded) {
  if (decoded is List) return decoded;
  if (decoded is Map) {
    final entries = decoded['entries'];
    if (entries is List) return entries;
    // 单条对象：有 id 就当成一个规则集。
    if (decoded.containsKey('id')) return <Object?>[decoded];
    return null;
  }
  return null;
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  final values = <String>[];
  for (final item in raw) {
    if (item is! String) continue;
    final text = item.trim();
    if (text.isEmpty) continue;
    if (!values.contains(text)) values.add(text);
  }
  return values;
}

List<Map<String, Object?>> _ruleMaps(Object? raw) {
  final rules = <Map<String, Object?>>[];
  for (final item in asList(raw)) {
    final map = asMap(item);
    if (map.isEmpty) continue;
    rules.add(map);
  }
  return rules;
}

int _now() => DateTime.now().millisecondsSinceEpoch;
