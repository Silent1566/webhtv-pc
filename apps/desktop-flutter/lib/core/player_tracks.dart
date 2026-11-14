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

/// 轨道种类。
enum PlayerTrackKind {
  audio('audio', '音轨'),
  video('video', '视频轨');

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

  /// 是否可以点击切换。`auto` 可点（回到自动），`no` 不出现。
  bool get selectable => !isOff;

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

/// 可被记忆的轨道槽。
///
/// 字幕槽也放这一层：记忆键与三级回落规则对三者完全一致，分开写会让
/// 「线路/集怎么拼进键」这种细节各写一遍，迟早走散。
enum PlayerTrackSlot {
  audio('audio', '音轨'),
  video('video', '视频轨'),
  subtitle('subtitle', '内嵌字幕');

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

/// `auto` 是「回到引擎默认」的伪轨，language/title 上没有意义。
bool _isPseudoTrack(PlayerTrackInfo track) => track.id.trim() == 'auto';
