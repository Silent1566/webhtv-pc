/// 播放器轨道（音轨/视频轨）的视图模型（`docs/phase9/design/01` §2）。
///
/// 为什么不直接暴露 media-kit 的 `AudioTrack`/`VideoTrack`：
/// - 播放器页只该依赖稳定字段（id/label/语言），不该知道 media-kit 的版本细节；
/// - id 必须原样保留——**不能用列表下标**，轨道顺序会随容器变化；
/// - 单测可以在不创建 `Player` 的情况下穷举「0 条 / 1 条 / 多条 / auto / no」。
///
/// 同一层还放「记住用户选过哪条轨」的纯逻辑：记忆键、轨道选择三件套与
/// 三级回落匹配。引擎轨道 id 会随容器/重解析变化，只存 id 会在下次开播
/// 直接失配，所以匹配规则必须和 id 一起演进出 language/title 两级兜底。
library;

import 'mpv_properties.dart';

/// 轨道种类。
enum PlayerTrackKind {
  audio('audio', '音轨'),
  video('video', '视频轨'),

  /// 次字幕轨（双字幕）：mpv 的 `secondary-sid`。
  ///
  /// 与 [PlayerTrackSlot.secondarySubtitle] 一一对应：槽位决定记忆键怎么拼，
  /// 主字幕与次字幕若共用 `subtitle` 槽，同一集里两条选择会互相覆盖。
  secondarySubtitle('secondary_subtitle', '次字幕');

  const PlayerTrackKind(this.id, this.label);

  /// 落盘/日志标识，**不得改名**。
  final String id;

  /// UI 中文名。
  final String label;
}

/// 引擎上报的一条轨道（中性结构）。
class PlayerTrackInfo {
  const PlayerTrackInfo({
    required this.id,
    this.title = '',
    this.language = '',
    this.isDefault = false,
  });

  /// 引擎轨道 id（如 `1`、`auto`、`no`）。**不得用下标替代**。
  final String id;

  /// 引擎给的标题（可能为空）。
  final String title;

  /// 语言标记（可能为空）。
  final String language;

  /// 是否带 default 标记。
  final bool isDefault;
}

/// 菜单里的一行。
class PlayerTrackOption {
  const PlayerTrackOption({
    required this.kind,
    required this.id,
    required this.label,
    this.language = '',
    this.isAuto = false,
    this.isOff = false,
    this.isDefault = false,
    this.selected = false,
  });

  final PlayerTrackKind kind;
  final String id;
  final String label;
  final String language;

  /// 「自动」项。
  final bool isAuto;

  /// 「关闭」项（仅字幕语义；音轨/视频轨不会出现）。
  final bool isOff;

  /// 引擎声明的默认轨。
  final bool isDefault;

  /// 当前是否选中。
  final bool selected;

  /// 是否可以点击切换。
  ///
  /// 列出来的每一项都可点：`auto` 回到自动，`no` 关闭（次字幕的
  /// `secondary-sid=no`）。[isOff] 只表示「这一项代表关闭」，**不等于**
  /// 不可点——次字幕菜单里「关闭」恰恰是最常点的一项。禁用态由界面按自身
  /// 状态决定，这里不猜。
  bool get selectable => true;

  PlayerTrackOption copyWith({bool? selected}) => PlayerTrackOption(
    kind: kind,
    id: id,
    label: label,
    language: language,
    isAuto: isAuto,
    isOff: isOff,
    isDefault: isDefault,
    selected: selected ?? this.selected,
  );

  @override
  bool operator ==(Object other) =>
      other is PlayerTrackOption &&
      other.kind == kind &&
      other.id == id &&
      other.label == label &&
      other.selected == selected;

  @override
  int get hashCode => Object.hash(kind, id, label, selected);

  @override
  String toString() => 'PlayerTrackOption(${kind.id}:$id, "$label", '
      'auto=$isAuto selected=$selected)';
}

/// 构造菜单项。
///
/// 规则：
/// 1. 过滤 `no`（关闭）——音轨/视频轨没有「关闭」语义，出现会误导；
/// 2. `auto` 保留为「自动」，排在第一位；
/// 3. 其余按引擎顺序，label 取 `title`，缺失时用「音轨 N / 视频轨 N」；
/// 4. 语言非空时附在 label 末尾（`· 国语`），不去重、不翻译；
/// 5. 当前选中项：id 精确匹配；selectedId 为空或 `auto` 时选中「自动」。
List<PlayerTrackOption> buildPlayerTrackOptions({
  required PlayerTrackKind kind,
  required Iterable<PlayerTrackInfo> tracks,
  String? selectedId,
}) {
  final normalizedSelected = (selectedId ?? '').trim();
  final options = <PlayerTrackOption>[];
  var ordinal = 0;

  for (final track in tracks) {
    final id = track.id.trim();
    if (id.isEmpty || id == 'no') continue;
    final isAuto = id == 'auto';
    if (!isAuto) ordinal += 1;

    final title = track.title.trim();
    final fallback = '${kind.label} $ordinal';
    final base = isAuto ? '自动' : (title.isEmpty ? fallback : title);
    final language = track.language.trim();
    final label = language.isEmpty || isAuto ? base : '$base · $language';

    final selected = isAuto
        ? (normalizedSelected.isEmpty || normalizedSelected == 'auto')
        : normalizedSelected == id;

    options.add(
      PlayerTrackOption(
        kind: kind,
        id: id,
        label: label,
        language: language,
        isAuto: isAuto,
        isDefault: track.isDefault,
        selected: selected,
      ),
    );
  }

  return options;
}

/// 当前选中的项；找不到时返回 null（不猜第一个）。
PlayerTrackOption? selectedPlayerTrack(List<PlayerTrackOption> options) {
  for (final option in options) {
    if (option.selected) return option;
  }
  return null;
}

/// 是否值得给用户显示「轨道」入口。
///
/// 「自动」不算一条可切换的轨道：`auto + 1 条真实轨` 时切换没有意义
/// （auto 只是回到引擎默认，不会产生不同音轨）。至少 2 条真实轨道才显示。
bool hasSwitchableTracks(List<PlayerTrackOption> options) {
  final real = options.where((option) => !option.isAuto && !option.isOff);
  return real.length >= 2;
}

/// 次字幕「关闭」的落盘值：mpv 的 `secondary-sid=no`。
///
/// 三个地方必须同一个字面量：菜单里那一行、`PlayerOptions.secondarySubtitleId`
/// 的默认值、以及写内核的取值。散写 `'no'` 就会在某处漏改。
const String secondarySubtitleOffId = 'no';

/// 次字幕的落盘口径：空值、以及「记住的次字幕正好是当前主字幕那条」都归到
/// [secondarySubtitleOffId]。
///
/// 同轨回落是**内容规则**而不是界面规则：同一条轨同时当主、次字幕，只会在画面
/// 上把同一行字显示两遍。所以判定放 core，界面与控制器只调用、不重判。
String normalizeSecondarySubtitleId({String? selectedId, String? primaryId}) {
  final current = (selectedId ?? '').trim();
  if (current.isEmpty) return secondarySubtitleOffId;
  final primary = (primaryId ?? '').trim();
  if (primary.isNotEmpty && current == primary) return secondarySubtitleOffId;
  return current;
}

/// 是否值得给「次字幕」入口。
///
/// 「至少两条真实字幕轨」是硬条件：次字幕天生是**第二条**字幕，只有一条时它
/// 能选的只剩「关闭」，入口点开也只有一项，没有意义；主字幕再占掉一条后，
/// 剩下的候选为空同样不给入口。
///
/// 与 [hasSwitchableTracks] 的口径**不同**（那条要求 ≥2 条候选）：次字幕菜单里
/// 「关闭」本身是可点的一项，所以「2 条字幕轨、主 1 次 2」就是双字幕的完整场景，
/// 此时候选只有一条也该给入口。
bool canOfferSecondarySubtitle({
  required Iterable<PlayerTrackInfo> tracks,
  String? primaryId,
}) {
  final real = <PlayerTrackInfo>[
    for (final track in tracks)
      if (_isRealTrack(track)) track,
  ];
  if (real.length < 2) return false;
  final primary = (primaryId ?? '').trim();
  if (primary.isEmpty) return true;
  for (final track in real) {
    if (track.id.trim() != primary) return true;
  }
  return false;
}

/// 次字幕菜单：一条「关闭」+ 主字幕菜单的同一套规则（mpv `secondary-sid`）。
///
/// 与 [buildPlayerTrackOptions] 的差别只有三处，且都是次字幕独有的语义：
/// 1. 「关闭」是**合法选项**而不是要过滤的噪声——`secondary-sid=no` 就是
///    关掉双字幕，所以它排在第一位（次字幕默认就是关的，见 [selectedId]）；
/// 2. [excludeId]（通常传主字幕当前那条）不出现在候选里：同一条轨同时当主、
///    次字幕只会在画面上把同一行字显示两遍；
/// 3. [selectedId] 为空、或恰好等于 [excludeId] 时，选中项回落到「关闭」——
///    前者是默认态，后者是「记住的次字幕被主字幕占走了」，此时声称次字幕
///    开着就是在骗用户。
///
/// `auto` 只可能来自 [selectedId]，且与其它种类一致：空/auto 都算自动；
/// 这里默认关闭，所以不传 [selectedId] 时不会选中 auto。
List<PlayerTrackOption> buildSecondarySubtitleOptions({
  required Iterable<PlayerTrackInfo> tracks,
  String? selectedId,
  String? excludeId,
}) {
  final excluded = (excludeId ?? '').trim();
  // 选中态与落盘口径同源：主次同轨/空值都由 [normalizeSecondarySubtitleId] 归到
  // 「关闭」，菜单不会再出现「次字幕开着、但和主字幕是同一条」的自相矛盾态。
  final effective = normalizeSecondarySubtitleId(
    selectedId: selectedId,
    primaryId: excludeId,
  );

  return <PlayerTrackOption>[
    PlayerTrackOption(
      kind: PlayerTrackKind.secondarySubtitle,
      id: secondarySubtitleOffId,
      label: '关闭',
      isOff: true,
      selected: effective == secondarySubtitleOffId,
    ),
    ...buildPlayerTrackOptions(
      kind: PlayerTrackKind.secondarySubtitle,
      tracks: <PlayerTrackInfo>[
        for (final track in tracks)
          if (excluded.isEmpty || track.id.trim() != excluded) track,
      ],
      selectedId: effective,
    ),
  ];
}

/// 可被记忆的轨道槽。
///
/// 字幕槽也放这一层：记忆键与三级回落规则对三者完全一致，分开写会让
/// 「线路/集怎么拼进键」这种细节各写一遍，迟早走散。
enum PlayerTrackSlot {
  audio('audio', '音轨'),
  video('video', '视频轨'),
  subtitle('subtitle', '内嵌字幕'),

  /// 次字幕槽（mpv `secondary-sid`）。
  ///
  /// 与 [PlayerTrackSlot.subtitle] 分开是必须的：共用一个槽时，同一集里主字幕
  /// 与次字幕的选择会互相覆盖成同一个键，后写的那次直接顶掉前一次。
  ///
  /// 它只记忆「次字幕是哪条」，**与主字幕的冲突**由 [normalizeSecondarySubtitleId]
  /// 在读写两侧统一回落（见该函数的文档）。
  secondarySubtitle('secondary_subtitle', '次字幕');

  const PlayerTrackSlot(this.id, this.label);

  /// 落盘/日志标识，**不得改名**（改名等于让所有旧记忆失配）。
  final String id;

  /// UI 中文名。
  final String label;
}

/// 用户显式选过的一条轨道。
///
/// 为什么存三件套而不是只存 id：id 是引擎（mpv）给的序号，重开媒体、
/// 换容器封装、重新解析都会变；language 与 title 是内容属性，容器重排
/// 之后仍然稳定，所以它们才是回落依据。
class TrackChoice {
  const TrackChoice({required this.engineId, this.language = '', this.title = ''});

  /// 引擎轨道 id（内嵌字幕为菜单里的 `embedded:<trackId>`）。
  final String engineId;

  /// 引擎给的语言标记（可能为空）。
  final String language;

  /// 引擎给的标题（可能为空）。
  final String title;

  bool get isEmpty =>
      engineId.trim().isEmpty && language.trim().isEmpty && title.trim().isEmpty;

  /// 解析落盘格式；没有 id 的记录视为无效（没有 id 就没有任何匹配依据）。
  static TrackChoice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final engineId = raw['id'];
    if (engineId is! String) return null;
    final language = raw['language'];
    final title = raw['title'];
    return TrackChoice(
      engineId: engineId.trim(),
      language: language is String ? language.trim() : '',
      title: title is String ? title.trim() : '',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': engineId,
    'language': language,
    'title': title,
  };

  @override
  bool operator ==(Object other) =>
      other is TrackChoice &&
      other.engineId == engineId &&
      other.language == language &&
      other.title == title;

  @override
  int get hashCode => Object.hash(engineId, language, title);

  @override
  String toString() =>
      'TrackChoice(id=$engineId, language=$language, title=$title)';
}

/// 轨道记忆键：`站点 + 影片 + 线路 + 集 + 槽`。
///
/// **线路必须在键里**（用户明确要求）：同一部剧不同线路的资源本身可能不同
/// （音轨/字幕条数不一样），跨线路沿用会把 A 线路的 id 甩到 B 线路，
/// 匹配必然落空，用户还得再选一次。
///
/// 集标识优先 [episodeId]（站点入口目标，稳定），为空才退回 [episodeName]：
/// 集名会重复（两条线路下都叫「第 1 集」），入口目标不会。
///
/// 用 `\x00` 分隔：集名/线路名里 `|`、`-`、空格都可能出现，可见字符
/// 做分隔符会造成两个不同键拼出同一个串。
String trackChoiceKey({
  required String siteKey,
  required String vodId,
  required String flag,
  required String episodeId,
  required String episodeName,
  required PlayerTrackSlot slot,
}) {
  final episode = episodeId.trim().isNotEmpty
      ? episodeId.trim()
      : episodeName.trim();
  return <String>[
    siteKey.trim(),
    vodId.trim(),
    flag.trim(),
    episode,
    slot.id,
  ].join('\x00');
}

/// 按「id → language → title」三级回落挑出该用的轨道 id。
///
/// 返回 null 表示三级都不中：调用方必须保持引擎默认，**不得**把它写成
/// 「用户选了 auto」——一次失败匹配就会把用户的选择冲掉。
///
/// language 只在**唯一命中**时才用：多国语轨共用 `und`/空标记很常见，
/// 猜一次就是切错轨，比不切更糟。
String? matchTrackChoice({
  required Iterable<PlayerTrackInfo> tracks,
  required TrackChoice choice,
}) {
  // `no`（关闭）不是可切换的轨，音轨/视频轨菜单里也没有它。
  final candidates = <PlayerTrackInfo>[
    for (final track in tracks)
      if (track.id.trim().isNotEmpty && track.id.trim() != 'no') track,
  ];

  final wantedId = choice.engineId.trim();
  if (wantedId.isNotEmpty) {
    for (final track in candidates) {
      if (track.id.trim() == wantedId) return track.id;
    }
  }

  final wantedLanguage = choice.language.trim().toLowerCase();
  if (wantedLanguage.isNotEmpty) {
    final matched = <PlayerTrackInfo>[
      for (final track in candidates)
        if (!_isPseudoTrack(track) &&
            track.language.trim().toLowerCase() == wantedLanguage)
          track,
    ];
    if (matched.length == 1) return matched.single.id;
  }

  final wantedTitle = choice.title.trim();
  if (wantedTitle.isNotEmpty) {
    for (final track in candidates) {
      if (_isPseudoTrack(track)) continue;
      if (track.title.trim() == wantedTitle) return track.id;
    }
  }
  return null;
}

/// 命中就把 id 交给 [setTrack]，未命中什么都不做（保持引擎默认）。
///
/// 抽成顶层函数是为了让「匹配 → 调引擎」这条链路能在没有 MediaKit 的
/// 单测里断言：`PlayerController` 的构造需要真引擎，测不了。
Future<bool> applyTrackChoice({
  required Iterable<PlayerTrackInfo> tracks,
  required TrackChoice choice,
  required Future<bool> Function(String id) setTrack,
}) async {
  final id = matchTrackChoice(tracks: tracks, choice: choice);
  if (id == null) return false;
  return setTrack(id);
}

/// 这次上报的轨道表是否值得再尝试一次恢复。
///
/// 引擎的轨道表是**分次上报**的（先空表、再补齐，切轨还会再报），而某些
/// 容器/慢源首帧只报 `auto` 这类伪轨：此时「表非空」并不等于「可以匹配」，
/// 三级回落会过滤掉伪轨返回 null。把这种「尝试过但没命中」当成「已应用」，
/// 用户记住的轨道就永远不会恢复——所以去重依据必须是**轨道 id 列表**本身，
/// 而不是「是否尝试过一次」。
///
/// 返回 false 的两种情形：
/// - [currentIds] 为空：引擎还没上报任何轨，此时尝试必然空转；
/// - 与 [lastTriedIds] 完全一致：同样的输入重算只会得到同样的结论，再 set 一次
///   还会把用户的手动切换顶回去。
bool shouldAttemptTrackChoice({
  required List<String> currentIds,
  required List<String>? lastTriedIds,
}) {
  if (currentIds.isEmpty) return false;
  if (lastTriedIds == null) return true;
  if (lastTriedIds.length != currentIds.length) return true;
  for (var i = 0; i < currentIds.length; i++) {
    if (lastTriedIds[i] != currentIds[i]) return true;
  }
  return false;
}

// ------------------------------------------------------------ 时间偏移

/// 偏移作用的对象。
///
/// 只到「哪一条 mpv 延迟属性」这一层：`sub-delay` 与 `audio-delay` 都是
/// **秒（双精度）**、正负双向、以「把时间轴对回去」为目的，规则完全一样，
/// 所以用同一个模型而不是两个只差一个字符串的类。
enum TrackOffsetKind {
  subtitle('subtitle', '字幕', 'sub-delay'),
  audio('audio', '音轨', 'audio-delay');

  const TrackOffsetKind(this.id, this.label, this.mpvPropertyKey);

  /// 落盘/日志标识，**不得改名**。
  final String id;

  /// UI 中文名。
  final String label;

  /// 注入 mpv 的属性名（值是秒，见 [TrackOffset.mpvValue]）。
  final String mpvPropertyKey;

  /// 按 mpv 属性名反查偏移类型；不是偏移属性时返回 null。
  ///
  /// 调用方（控制器）靠它决定回读口径：偏移是双精度秒，写 `0.1` 回读可能差
  /// 一个 ulp，必须按 1 ms 容差比；其它属性仍走严格相等。
  static TrackOffsetKind? fromMpvPropertyKey(String key) {
    final wanted = key.trim();
    for (final item in values) {
      if (item.mpvPropertyKey == wanted) return item;
    }
    return null;
  }
}

/// 一条轨的时间偏移，**单位毫秒**，正负双向，|值| ≤ [maxMilliseconds]。
///
/// 为什么内部用毫秒整数而不是秒（double）：界面的步进是 50/100 ms 这种整数，
/// 用 double 连加会攒出 `0.30000000000000004`，落盘再读回来就不相等了；
/// 整数毫秒在内存里精确、在 JSON 里也可读。**换算成秒只在写 mpv 时做**
/// （[mpvValue] 走 `mpv_properties.dart` 的换算），界面不做单位换算。
///
/// **超限夹取，不拒绝**：
/// - 取值只可能来自本应用的步进/滑条与旧配置文件，越限不是「另一个合法
///   意图」而是噪声（手滑、改配置写错位数）；
/// - 拒绝需要错误通道，而仓库里的 `fromJson` 一律返回模型（[TrackChoice]
///   这类缺了 key 就无法匹配的除外）；夹取保证「记住的就还生效」，最多顶到
///   ±60 s，用户仍能在界面上看见并调回来；
/// - 夹取不是唯一防线：白名单侧对秒数另有独立的值域校验
///   （`filterMpvProperties` 会拒掉 |秒| > 60 的写入），脏数据依然到不了内核。
class TrackOffset {
  TrackOffset({required this.kind, int milliseconds = 0})
    : milliseconds = clampMilliseconds(milliseconds);

  /// 上下限 ±60 s。实测对轴需求都落在 ±5 s 内，60 s 已经是「离谱但还能用」；
  /// 再大就不叫偏移了（那是选错了片源/版本）。
  static const int maxMilliseconds = 60000;

  final TrackOffsetKind kind;

  /// 已夹进 ±[maxMilliseconds] 的毫秒数。
  final int milliseconds;

  /// 把任意毫秒数夹进 ±[maxMilliseconds]（滑条/输入框可直接用它）。
  static int clampMilliseconds(int milliseconds) =>
      milliseconds.clamp(-maxMilliseconds, maxMilliseconds);

  bool get isZero => milliseconds == 0;

  /// 注入 mpv 的取值：秒，固定 3 位小数（1 ms = 0.001 s）。
  String get mpvValue => mpvSecondsFromMilliseconds(milliseconds);

  /// 要注入的属性对，如 `{'sub-delay': '0.500'}` / `{'audio-delay': '-0.250'}`。
  Map<String, String> toMpvProperty() => <String, String>{
    kind.mpvPropertyKey: mpvValue,
  };

  TrackOffset copyWith({TrackOffsetKind? kind, int? milliseconds}) =>
      TrackOffset(
        kind: kind ?? this.kind,
        milliseconds: milliseconds ?? this.milliseconds,
      );

  /// 落盘：`{'kind': 'subtitle', 'ms': 500}`。
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.id,
    'ms': milliseconds,
  };

  /// 解析落盘格式。
  ///
  /// kind 不认识、或 `ms` 不是数字时返回 null——没有 kind 就不知道该写哪条
  /// 属性，没有毫秒就没有可用的值。数值越界**不丢弃**，按 [clampMilliseconds]
  /// 夹取（见类文档）。
  static TrackOffset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kindId = raw['kind'];
    if (kindId is! String) return null;
    final wanted = kindId.trim().toLowerCase();
    TrackOffsetKind? kind;
    for (final item in TrackOffsetKind.values) {
      if (item.id == wanted) kind = item;
    }
    if (kind == null) return null;
    final ms = raw['ms'];
    if (ms is! num) return null;
    return TrackOffset(kind: kind, milliseconds: ms.round());
  }

  @override
  bool operator ==(Object other) =>
      other is TrackOffset &&
      other.kind == kind &&
      other.milliseconds == milliseconds;

  @override
  int get hashCode => Object.hash(kind, milliseconds);

  @override
  String toString() => 'TrackOffset(${kind.id}, ${milliseconds}ms)';
}

/// 偏移的界面文案：**秒**、一位小数、带符号（`+0.5 秒` / `-0.3 秒` / `0.0 秒`）。
///
/// 内部一律毫秒（见 [TrackOffset]），只在展示时换成秒：界面步进是 100 ms 的
/// 整数倍，一位小数既够用又不会露出 `0.30000000000000004` 这类浮点尾巴。
/// 零不带符号——写 `+0.0 秒` 会让人以为「偏了一点点」。
String formatTrackOffsetSeconds(int milliseconds) {
  final seconds = (milliseconds / 1000).toStringAsFixed(1);
  // -40 ms 会渲染成 `-0.0`：那一位小数已经把「有没有偏」抹平了，按 0 显示。
  if (seconds == '-0.0') return '0.0 秒';
  if (milliseconds > 0) return '+$seconds 秒';
  return '$seconds 秒';
}

/// `auto` 是「回到引擎默认」的伪轨，language/title 上没有意义。
bool _isPseudoTrack(PlayerTrackInfo track) => track.id.trim() == 'auto';

/// 真实轨：伪轨（`auto`）与「关闭」（`no`）都不是可被选中的轨道。
bool _isRealTrack(PlayerTrackInfo track) {
  final id = track.id.trim();
  return id.isNotEmpty && id != secondarySubtitleOffId && !_isPseudoTrack(track);
}
