/// UI 偏好持久化（`<configDir>/settings.json` 的 `ui` 段）。
///
/// 为什么单独一段：`settings.json` 已有 `tmdb`（凭据）与 `sync`（同步白名单/设备）
/// 两段，各自有独立的 store。UI 偏好与它们语义无关，混进去会让任何一方保存时
/// 覆盖另一方的键。这里沿用同样的「读改写、只替换自己那一段」模式。
///
/// 当前保存：
/// - `lastSiteKey`：**最近一次使用的站点**；
/// - `videoFitModes`：按 `siteKey + vodId` 记住播放器画面模式；
/// - `trackChoices`：按 `站点 + 影片 + 线路 + 集 + 槽` 记住用户选过的
///   音轨/视频轨/内嵌字幕轨（键由 `core/player_tracks.dart` 的
///   `trackChoiceKey` 统一拼装，上限 500 条）；
/// - `themeMode`：**主题模式**（`dark` / `light` / `system`）；
/// - `searchKeywords`：**搜索历史**（去重、最新在前，上限 10；
///   对齐上游安卓「默影视」`Setting.getKeyword/putKeyword` + `RecordAdapter`
///   的 `checkToAdd`：新词提到最前、超出裁剪）；
/// - `searchSimilarity`：**搜索结果相似度阈值**（0~100，上游
///   `Setting.getSearchSimilarity` 默认 30）；
/// - `searchThread`：**搜索并发线程数**（1~100，上游
///   `Setting.getSearchThread` 默认 20、`clampSearchThread` 夹在 1~100）；
/// - `historyClickAction`：**点击历史记录的行为**（`detail` 进详情页 /
///   `play` 直接播放，上游 `HistoryActivity#onItemClick` 是直接播放，
///   PC 端默认改为进详情页，见 `docs/phase6/design/01` §4.1）；
/// - `historyScope`：**历史记录的可见范围**（`source` 只看当前播放源 /
///   `global` 看全部源）。默认 `source`：多个源（尤其安卓桥接多源）各自
///   有同名影片时，混在一起会让「继续播放」跳错源。对齐上游安卓
///   `Setting.getGlobalHistoryMode`（关闭 / 自动 / 搜索），PC 端只保留
///   「按源」与「全局」两档。
/// - `historyAggregation`：**历史记录的同名聚合**（`none` 每集一条 /
///   `tmdb` 优先 TMDB、缺失时按片名 / `title` 只按片名）。默认 `tmdb`，
///   对齐安卓 `history_aggregation_by_tmdb` 的聚合意图，但保留 `none`
///   让用户能切回 v7 的逐集形态。
/// - `spiderDebugLog`：**详细调试日志开关**（爬虫 IPC 入参/出参）。默认关；
///   打开时日志单文件上限放大到 20MB，见 `LogService.verboseMaxFileBytes`。
///
/// 另外管理 `settings.json` **顶层** `player` 段（Phase 9）：
/// 播放参数（缓冲/硬解/自动连播/失败回退/预加载/片头片尾开关/LUT）。
/// 放在顶层而不是 `ui` 里，是因为它属于播放行为而不是界面偏好，日后
/// 同步到安卓时也是独立键。
library;

import 'dart:convert';
import 'dart:io';

import '../core/external_player_catalog.dart';
import 'external_player.dart';
import '../core/history_aggregation.dart';
import '../core/history_scope.dart';
import '../core/history_view.dart';
import '../core/danmaku_settings.dart';
import '../core/danmaku_style.dart';
import '../core/doh_settings.dart';
import '../core/following.dart';
import '../core/live_settings.dart';
import '../core/subtitle_settings.dart';
import '../core/osd_config.dart';
import '../core/player_buttons.dart';
import '../core/player_tracks.dart';
import '../core/outbound_proxy.dart';
import '../core/parse_failover.dart';
import '../core/player_options.dart';
import '../core/site_group_rules.dart';
import '../core/site_order.dart';
import 'log_service.dart';
import 'settings_file.dart';

/// 主题模式取值。
///
/// 存字符串而不是 Flutter 的 `ThemeMode`：本层是服务层，不依赖 UI 框架
/// （与 `AppPaths`、`LogService` 同样的分层）。转换放在 `AppState`。
///
/// 默认 `dark`：星等星表以暗色为主身份（夜间、坐在电脑前的使用场景），
/// 亮色是独立设计的「昼间星表」。旧设置文件没有这个键时保持原有行为。
abstract final class UiThemeMode {
  static const String dark = 'dark';
  static const String light = 'light';
  static const String system = 'system';

  static const List<String> values = [dark, light, system];

  /// 把任意输入归一化成合法值；不认识的值回落到默认。
  static String normalize(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    return values.contains(value) ? value : dark;
  }
}

/// 选集视图模式取值：网格 / 列表。
///
/// 与 [UiThemeMode] 同一分层理由：存字符串，不依赖 UI 框架。
/// 默认网格——剧集条目多时网格扫读更快，列表是可选项。
abstract final class UiEpisodeViewMode {
  static const String grid = 'grid';
  static const String list = 'list';

  static const List<String> values = [grid, list];

  /// 默认值：未设置或非法值都回落到网格。
  static const String fallback = grid;

  /// 把任意输入归一化成合法值；不认识的值回落到默认。
  static String normalize(String? raw) {
    final value = raw?.trim().toLowerCase() ?? '';
    return values.contains(value) ? value : fallback;
  }
}

class UiPreferencesStore {
  UiPreferencesStore({required this.path, LogService? log}) : _log = log;

  /// `settings.json` 的绝对路径（`AppPaths.settingsPath`）。
  final String path;

  // ignore_for_file: prefer_initializing_formals
  final LogService? _log;

  String _lastSiteKey = '';
  final Map<String, String> _videoFitModes = {};

  /// 记住的轨道选择，键由 `trackChoiceKey` 拼装（本层不认识站点/线路语义）。
  final Map<String, TrackChoice> _trackChoices = {};

  /// 用户**显式选过**的主题模式；`null` = 从未选过。
  ///
  /// 为什么用可空：`ui` 段是「读改写」的，把默认值固化进文件会让
  /// 「从未选过」和「选过暗色」变得无法区分，也会污染既有设置文件。
  /// 缺省不写盘，语义上「缺席 = 用默认」。
  String? _themeMode;

  /// 搜索历史：去重、最新在前。上限 [_maxSearchKeywords]。
  List<String> _searchKeywords = const [];

  /// 搜索结果相似度阈值（0~100）。`null` = 从未设置过，用默认 [_defaultSimilarity]。
  int? _searchSimilarity;

  /// 搜索并发线程数（1~100）。`null` = 从未设置过，用默认 [_defaultSearchThread]。
  int? _searchThread;

  /// 点击历史记录的行为。`null` = 从未设置过，用默认 [UiHistoryClickAction.detail]。
  String? _historyClickAction;

  /// 历史记录可见范围。`null` = 从未设置过，用默认 [UiHistoryScope.source]。
  String? _historyScope;

  /// 历史记录同名聚合模式。`null` = 从未设置过，用默认 [UiHistoryAggregation.tmdb]。
  String? _historyAggregation;

  /// 选集视图模式。`null` = 从未设置过，用默认 [UiEpisodeViewMode.fallback]。
  String? _episodeViewMode;

  /// 屏显开关的**显式**设置；缺席的 id 用 [defaultOsdFlags] 补齐。
  ///
  /// 为什么只存显式项：与 [_themeMode] 同一理由——把默认值固化进文件会让
  /// 「从未设置过」与「设置成默认值」无法区分，也会污染既有设置文件。
  final Map<String, bool> _osdFlags = {};

  /// 按钮顺序的**显式**设置；空表示从未设置过。
  List<String>? _buttonOrder;

  /// 按钮隐藏集的**显式**设置；null 表示从未设置过。
  Set<String>? _buttonHidden;

  /// 外部播放器可执行文件的**显式**设置；null 表示从未设置过。
  ///
  /// 与 [_themeMode] 同一口径：缺省不写盘，避免把默认值固化进设置文件。
  /// 「配置了路径」即「能力可用」——探测到的候选只有在用户选定后才写进来，
  /// 所以不需要额外的启用开关。
  String? _externalPlayerPath;
  ExternalPlayerCatalog _externalPlayerCatalog = const ExternalPlayerCatalog();

  /// 播放参数的**显式**设置；null 表示从未设置过（用默认值）。
  ///
  /// Phase 9 起新增。默认值必须等价于 Phase 0–8 的行为，见
  /// `docs/phase9/design/01` §5。
  PlayerOptions? _playerOptions;

  /// 直播设置的**显式**设置；null 表示从未设置过（用默认值）。
  LiveSettings? _liveSettings;

  /// 字幕源设置的**显式**设置；null 表示从未设置过（默认全关）。
  SubtitleSettings? _subtitleSettings;

  /// 弹幕库设置的**显式**设置；null 表示从未设置过（默认全关）。
  DanmakuSettings? _danmakuSettings;

  /// 弹幕显示样式的**显式**设置；null 表示从未设置过（等价 Phase 3–8）。
  ///
  /// Phase 9 P0-7 新增。与 `_danmakuSettings`（库地址/自动搜索）分开存：
  /// 一个是「去哪找弹幕」，一个是「怎么画」。
  DanmakuStyle? _danmakuStyle;

  /// 站点排序偏好的**显式**设置；null 表示从未设置过（配置顺序）。
  SiteOrderSettings? _siteOrder;

  /// 站点列表治理（手动顺序 + 屏蔽）的**显式**设置，按配置作用域分开存。
  ///
  /// key 是作用域标识（生产环境是 `config:<配置记录 id>`），值为该配置下的手动
  /// 顺序与屏蔽集合。空覆盖不写盘：缺席 = 从未设置过（配置顺序、无屏蔽）。
  final Map<String, SiteListOverrides> _siteListOverrides = {};

  /// 解析接口失败切换的**显式**设置；null 表示从未设置过（关闭）。
  ParseFailoverSettings? _parseFailover;

  /// 广告过滤总开关的**显式**设置；null 表示从未设置过（默认开启）。
  bool? _adBlockEnabled;

  /// 站点分组规则的**显式**设置；null 表示从未设置过（4 条内置全开）。
  SiteGroupSettings? _siteGroupSettings;

  /// 出站代理的**显式**设置；null 表示从未设置过（关闭）。
  OutboundProxySettings? _outboundProxy;

  /// DoH 的**显式**设置；null 表示从未设置过（关闭）。
  ///
  /// Phase 9 P2-8 新增。与配置文件的 `doh`（服务商列表）分开存。
  DohSettings? _dohSettings;

  /// 隐身模式的**显式**设置；null 表示从未设置过（关闭）。
  bool? _incognito;

  /// 追番设置的**显式**设置；null 表示从未设置过（按默认值：自动检查开启）。
  FollowingSettings? _followingSettings;

  /// 详细调试日志的**显式**设置；null 表示从未设置过（关闭）。
  bool? _spiderDebugLog;

  bool _loaded = false;

  /// 搜索历史上限（上游安卓 `RecordAdapter.checkToAdd` 同为 10）。
  static const int _maxSearchKeywords = 10;

  /// 轨道记忆上限。按剧集维度记（每集每槽一条），电影+长剧很快就会过百，
  /// 500 条足够覆盖真实使用，又不至于让 settings.json 无界膨胀。
  static const int _maxTrackChoices = 500;

  /// 相似度默认值：与上游 `Setting.getSearchSimilarity()` 默认 30 一致。
  static const int _defaultSimilarity = 30;

  /// 搜索并发线程数默认值：与上游 `Setting.getSearchThread()` 默认 20 一致。
  static const int _defaultSearchThread = 20;

  /// 并发线程数下限（上游 `clampSearchThread` 为 1~100）。
  static const int _minSearchThread = 1;

  /// 并发线程数上限（上游 `clampSearchThread` 为 1~100）。
  static const int _maxSearchThread = 100;

  /// 最近一次使用的站点 key；从未选过时为空串。
  String get lastSiteKey => _lastSiteKey;

  /// 生效的主题模式：用户选过就用选的，否则用默认（暗色）。
  String get themeMode => _themeMode ?? UiThemeMode.dark;

  /// 用户是否显式选过主题（决定要不要写盘）。
  bool get hasExplicitThemeMode => _themeMode != null;

  /// 搜索历史（去重、最新在前）。
  List<String> get searchKeywords => List.unmodifiable(_searchKeywords);

  /// 生效的相似度阈值：从未设置过时用默认 30（对齐上游安卓）。
  int get searchSimilarity => _searchSimilarity ?? _defaultSimilarity;

  /// 用户是否显式设置过相似度（决定「不限」是不是用户主动选的）。
  bool get hasExplicitSearchSimilarity => _searchSimilarity != null;

  /// 生效的搜索并发线程数：从未设置过时用默认 20（对齐上游安卓）。
  int get searchThread => _searchThread ?? _defaultSearchThread;

  /// 用户是否显式设置过并发线程数。
  bool get hasExplicitSearchThread => _searchThread != null;

  /// 生效的点击历史行为：用户选过就用选的，否则默认进详情页。
  String get historyClickAction =>
      UiHistoryClickAction.normalize(_historyClickAction);

  /// 用户是否显式设置过（决定要不要写盘，与 `themeMode` 同理）。
  bool get hasExplicitHistoryClickAction => _historyClickAction != null;

  /// 生效的历史范围：用户选过就用选的，否则默认只看当前源。
  String get historyScope => UiHistoryScope.normalize(_historyScope);

  /// 用户是否显式设置过历史范围。
  bool get hasExplicitHistoryScope => _historyScope != null;

  /// 生效的历史聚合模式：用户选过就用选的，否则默认「优先 TMDB」。
  String get historyAggregation =>
      UiHistoryAggregation.normalize(_historyAggregation);

  /// 用户是否显式设置过聚合模式。
  bool get hasExplicitHistoryAggregation => _historyAggregation != null;

  /// 生效的选集视图模式：用户选过就用选的，否则默认网格。
  String get episodeViewMode => UiEpisodeViewMode.normalize(_episodeViewMode);

  /// 用户是否显式设置过选集视图模式。
  bool get hasExplicitEpisodeViewMode => _episodeViewMode != null;

  /// 生效的屏显开关：显式设置过的项用用户值，其余用默认。
  Map<String, bool> get osdFlags => normalizeOsdFlags(_osdFlags);

  /// 用户是否显式设置过任一屏显开关（决定要不要写盘）。
  bool get hasExplicitOsd => _osdFlags.isNotEmpty;

  /// 生效的按钮顺序：显式设置过就用它（并补全缺失项），否则用默认。
  List<String> get buttonOrder => normalizeButtonOrder(_buttonOrder);

  /// 生效的按钮隐藏集。
  ///
  /// 注意必须传 `List`：Task 2 的 [normalizeButtonHidden] 只认 `List` 与
  /// 逗号分隔 `String`（`_splitIds`），直接喂 `Set` 会静默落成空集。
  Set<String> get buttonHidden =>
      normalizeButtonHidden(_buttonHidden?.toList());

  /// 用户是否显式设置过按钮排版（决定要不要写盘）。
  bool get hasExplicitPlayerButtons =>
      _buttonOrder != null || _buttonHidden != null;

  /// 外部播放器路径；`null` = 从未设置过（还没探测或还没手选）。
  String? get externalPlayerPath {
    final path = _externalPlayerPath?.trim() ?? '';
    return path.isEmpty ? null : _externalPlayerCatalog.resolveExecutable(path);
  }

  List<ExternalPlayer> listExternalPlayers(List<ExternalPlayer> scanned) =>
      _externalPlayerCatalog.list(
        scanned,
        legacyExecutable: externalPlayerPath,
      );

  /// 生效的播放参数。
  PlayerOptions get playerOptions =>
      (_playerOptions ?? const PlayerOptions.defaults()).normalized();

  /// 用户是否显式设置过播放参数。
  bool get hasExplicitPlayerOptions => _playerOptions != null;

  /// 生效的直播设置。
  LiveSettings get liveSettings =>
      _liveSettings ?? const LiveSettings.defaults();

  /// 用户是否显式设置过直播设置。
  bool get hasExplicitLiveSettings => _liveSettings != null;

  /// 生效的字幕源设置。
  SubtitleSettings get subtitleSettings =>
      _subtitleSettings ?? SubtitleSettings();

  /// 用户是否显式设置过字幕源。
  bool get hasExplicitSubtitleSettings => _subtitleSettings != null;

  /// 生效的弹幕库设置。
  DanmakuSettings get danmakuSettings =>
      _danmakuSettings ?? const DanmakuSettings.defaults();

  /// 用户是否显式设置过弹幕库。
  bool get hasExplicitDanmakuSettings => _danmakuSettings != null;

  /// 生效的弹幕显示样式。
  DanmakuStyle get danmakuStyle => _danmakuStyle ?? DanmakuStyle.defaults;

  /// 用户是否显式设置过弹幕显示样式。
  bool get hasExplicitDanmakuStyle => _danmakuStyle != null;

  /// 生效的站点排序偏好。
  SiteOrderSettings get siteOrder =>
      _siteOrder ?? const SiteOrderSettings.defaults();

  /// 用户是否显式设置过站点排序。
  bool get hasExplicitSiteOrder => _siteOrder != null;

  /// 指定作用域下的站点列表覆盖（手动顺序 + 屏蔽）。
  SiteListOverrides siteListOverrides(String scopeKey) =>
      _siteListOverrides[scopeKey] ?? SiteListOverrides.empty;

  /// 是否显式设置过任意一份配置的站点顺序或屏蔽。
  bool get hasExplicitSiteListOverrides => _siteListOverrides.isNotEmpty;

  /// 生效的广告过滤开关（默认开启：配置里写了规则才生效，不写就无效果）。
  bool get adBlockEnabled => _adBlockEnabled ?? true;

  /// 生效的站点分组规则。
  SiteGroupSettings get siteGroupSettings =>
      _siteGroupSettings ?? const SiteGroupSettings.defaults();

  /// 生效的出站代理设置。
  OutboundProxySettings get outboundProxy =>
      _outboundProxy ?? const OutboundProxySettings.defaults();

  /// 生效的 DoH 设置（默认关闭）。
  DohSettings get dohSettings => _dohSettings ?? DohSettings.defaults;

  /// 是否显式设置过 DoH。
  bool get hasExplicitDohSettings => _dohSettings != null;

  /// 隐身模式（默认关闭；关闭时行为与 Phase 0–8 一致）。
  bool get incognito => _incognito ?? false;

  /// 是否显式设置过隐身模式。
  bool get hasExplicitIncognito => _incognito != null;

  /// 生效的追番设置。
  FollowingSettings get followingSettings =>
      _followingSettings ?? FollowingSettings.defaults;

  /// 是否显式设置过追番。
  bool get hasExplicitFollowingSettings => _followingSettings != null;

  /// 详细调试日志（默认关闭；关闭时日志量与既有版本一致）。
  bool get spiderDebugLog => _spiderDebugLog ?? false;

  /// 是否显式设置过详细调试日志。
  bool get hasExplicitSpiderDebugLog => _spiderDebugLog != null;

  /// 生效的解析接口失败切换设置。
  ParseFailoverSettings get parseFailover =>
      (_parseFailover ?? const ParseFailoverSettings.defaults()).normalized();

  /// 是否已成功读取过磁盘内容。
  bool get loaded => _loaded;

  String videoFitMode({required String siteKey, required String vodId}) =>
      _videoFitModes[_videoFitKey(siteKey, vodId)] ?? '';

  /// 读取某个记忆键下的轨道选择；没有记录返回 null。
  TrackChoice? trackChoice(String key) => _trackChoices[key];

  /// 从磁盘读取。文件不存在或解析失败时保持默认值并记日志（不阻塞启动）。
  Map<String, Object?> _aiIntegrationSettings = {};
  bool get aiTitleExtractionEnabled =>
      _aiIntegrationSettings['ai_title_extraction'] == true;
  bool get aiAdDetectionEnabled =>
      _aiIntegrationSettings['ai_ad_detection'] == true;
  Map<String, Object?> get androidAiRaw =>
      Map.unmodifiable(_aiIntegrationSettings);

  Future<bool> rememberAiIntegrationSettings(Map<String, Object?> values) {
    _aiIntegrationSettings = {..._aiIntegrationSettings, ...values};
    return _persist();
  }

  Future<void> load() async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        _loaded = true;
        return;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        _loaded = true;
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final aiSettings = decoded['aiIntegration'];
        _aiIntegrationSettings = aiSettings is Map
            ? Map<String, Object?>.from(aiSettings)
            : {};
        final ui = decoded['ui'];
        if (ui is Map) {
          final value = ui['lastSiteKey'];
          if (value is String) _lastSiteKey = value.trim();
          // 只接受合法值；文件里被手改成别的字符串时回落到默认，不写坏状态。
          final mode = ui['themeMode'];
          if (mode is String &&
              UiThemeMode.values.contains(mode.trim().toLowerCase())) {
            _themeMode = mode.trim().toLowerCase();
          }
          final modes = ui['videoFitModes'];
          if (modes is Map) {
            for (final entry in modes.entries) {
              if (entry.key is String && entry.value is String) {
                _videoFitModes[entry.key as String] = entry.value as String;
              }
            }
          }
          // 轨道记忆：只接受有 id 的记录，手改文件写坏的条目直接丢弃。
          final choices = ui['trackChoices'];
          if (choices is Map) {
            for (final entry in choices.entries) {
              if (entry.key is! String) continue;
              final choice = TrackChoice.fromJson(entry.value);
              if (choice != null) _trackChoices[entry.key as String] = choice;
            }
            // 手改文件可能塞进超量条目，恢复时同样按上限裁剪。
            _trimTrackChoices();
          }
          final keywords = ui['searchKeywords'];
          if (keywords is List) {
            final restored = <String>[
              for (final item in keywords)
                if (item is String && item.trim().isNotEmpty) item.trim(),
            ];
            // 恢复时同样去重裁剪，防止手改文件塞进超长列表。
            _searchKeywords = _dedupeKeywords(restored);
          }
          final similarity = ui['searchSimilarity'];
          if (similarity is int && similarity >= 0 && similarity <= 100) {
            _searchSimilarity = similarity;
          } else if (similarity is num &&
              similarity.toInt() >= 0 &&
              similarity.toInt() <= 100) {
            // 手改文件写成 30.0 这类浮点时也接受。
            _searchSimilarity = similarity.toInt();
          }
          final thread = ui['searchThread'];
          if (thread is num) {
            // 手改文件写坏的值（0、-5、999）一律夹到合法区间，
            // 与上游 `putSearchThread` 的 `clampSearchThread` 同语义：
            // 并发度 0 会让搜索一个站点都不发。
            _searchThread = _clampSearchThread(thread.toInt());
          }
          final clickAction = ui['historyClickAction'];
          if (clickAction is String) {
            // 只接受合法值；手改成别的字符串时回落到默认，不写坏状态。
            if (UiHistoryClickAction.values.contains(
              clickAction.trim().toLowerCase(),
            )) {
              _historyClickAction = clickAction.trim().toLowerCase();
            }
          }
          final scope = ui['historyScope'];
          if (scope is String) {
            // 只接受合法值；手改成别的字符串时回落到默认（按源）。
            if (UiHistoryScope.values.contains(scope.trim().toLowerCase())) {
              _historyScope = scope.trim().toLowerCase();
            }
          }
          final aggregation = ui['historyAggregation'];
          if (aggregation is String) {
            // 只接受合法值；手改成别的字符串时回落到默认（优先 TMDB）。
            if (UiHistoryAggregation.values.contains(
              aggregation.trim().toLowerCase(),
            )) {
              _historyAggregation = aggregation.trim().toLowerCase();
            }
          }
          final viewMode = ui['episodeViewMode'];
          if (viewMode is String) {
            // 只接受合法值；手改成别的字符串时回落到默认（网格）。
            if (UiEpisodeViewMode.values.contains(
              viewMode.trim().toLowerCase(),
            )) {
              _episodeViewMode = viewMode.trim().toLowerCase();
            }
          }
          // 屏显开关：只接受 bool；非法值忽略（该项回落默认）。
          final osd = ui['osd'];
          if (osd is Map) {
            for (final id in OsdFlag.values) {
              final value = osd[id];
              if (value is bool) _osdFlags[id] = value;
            }
          }
          // 按钮排版：顺序与隐藏集各自独立；格式兼容 List 与逗号分隔字符串。
          final buttons = ui['playerButtons'];
          if (buttons is Map) {
            final order = buttons['order'];
            if (order != null) {
              final parsed = normalizeButtonOrder(order);
              // 只有真的解析出内容才视为「显式设置过」，
              // 否则一个空数组会把「从未设置」误判成「设置成默认」。
              if (_hasAnyKnownId(order)) _buttonOrder = parsed;
            }
            final hidden = buttons['hidden'];
            if (hidden != null && _hasAnyKnownId(hidden)) {
              _buttonHidden = normalizeButtonHidden(hidden);
            }
          }
          // 外部播放器：路径只接受非空字符串（空串 = 未设置）。
          final externalPath = ui['externalPlayerPath'];
          if (externalPath is String && externalPath.trim().isNotEmpty) {
            _externalPlayerPath = externalPath.trim();
          }
          _externalPlayerCatalog = ExternalPlayerCatalog.fromJson(
            ui['externalPlayers'],
          );
          _externalPlayerPath = _externalPlayerCatalog.resolveExecutable(
            _externalPlayerPath,
          );
        }
        // 顶层段（Phase 9）：与 `ui` 段同级，不能被 `ui` 是否存在影响。
        final player = decoded['player'];
        if (player is Map && player.isNotEmpty) {
          _playerOptions = PlayerOptions.fromJson(player);
        }
        final live = decoded['live'];
        if (live is Map && live.isNotEmpty) {
          _liveSettings = LiveSettings.fromJson(live);
        }
        final subtitles = decoded['subtitles'];
        if (subtitles is Map && subtitles.isNotEmpty) {
          _subtitleSettings = SubtitleSettings.fromJson(subtitles);
        }
        final danmaku = decoded['danmaku'];
        if (danmaku is Map && danmaku.isNotEmpty) {
          _danmakuSettings = DanmakuSettings.fromJson(danmaku);
        }
        final danmakuDisplay = decoded['danmakuDisplay'];
        if (danmakuDisplay is Map && danmakuDisplay.isNotEmpty) {
          _danmakuStyle = DanmakuStyle.fromJson(danmakuDisplay);
        }
        final siteOrder = decoded['siteOrder'];
        if (siteOrder is Map && siteOrder.isNotEmpty) {
          _siteOrder = SiteOrderSettings.fromJson(siteOrder);
        }
        // 站点列表治理：按配置作用域逐个解析；空覆盖不入内存（缺席 = 默认）。
        final siteList = decoded['siteList'];
        if (siteList is Map) {
          for (final entry in siteList.entries) {
            final scope = entry.key;
            if (scope is! String || scope.trim().isEmpty) continue;
            final overrides = SiteListOverrides.fromJson(entry.value);
            if (overrides.isEmpty) continue;
            _siteListOverrides[scope] = overrides;
          }
        }
        final parseFailover = decoded['parseFailover'];
        if (parseFailover is Map && parseFailover.isNotEmpty) {
          _parseFailover = ParseFailoverSettings.fromJson(parseFailover);
        }
        final adBlock = decoded['adBlock'];
        if (adBlock is Map && adBlock['enabled'] is bool) {
          _adBlockEnabled = adBlock['enabled'] as bool;
        }
        final siteGroup = decoded['siteRules'];
        if (siteGroup is Map && siteGroup.isNotEmpty) {
          _siteGroupSettings = SiteGroupSettings.fromJson(siteGroup);
        }
        final outbound = decoded['outboundProxy'];
        if (outbound is Map && outbound.isNotEmpty) {
          _outboundProxy = OutboundProxySettings.fromJson(outbound);
        }
        final doh = decoded['doh'];
        if (doh is Map && doh.isNotEmpty) {
          _dohSettings = DohSettings.fromJson(doh);
        }
        final incognito = decoded['incognito'];
        if (incognito is bool) _incognito = incognito;
        final following = decoded['following'];
        if (following is Map && following.isNotEmpty) {
          _followingSettings = FollowingSettings.fromJson(following);
        }
        // 详细调试日志：只接受 bool；非法值忽略（回落默认「关闭」）。
        // 注意它在 `ui` 段内，与上面顶层段不同源。
        final spiderDebugLog = ui is Map ? ui['spiderDebugLog'] : null;
        if (spiderDebugLog is bool) _spiderDebugLog = spiderDebugLog;
      }
      _loaded = true;
    } catch (error) {
      _log?.warning('读取 UI 偏好失败，使用默认值：$error', scope: 'ui');
      _lastSiteKey = '';
      _loaded = true;
    }
  }

  /// 记住最近使用的站点。key 为空时视为「清除记录」。
  ///
  /// 写入失败**不影响**当前会话（内存里已生效），只记日志。
  Future<bool> rememberSite(String key) async {
    final normalized = key.trim();
    if (normalized == _lastSiteKey) return true;
    _lastSiteKey = normalized;
    return _persist();
  }

  Future<bool> rememberVideoFitMode({
    required String siteKey,
    required String vodId,
    required String mode,
  }) async {
    final key = _videoFitKey(siteKey, vodId);
    if (_videoFitModes[key] == mode) return true;
    _videoFitModes[key] = mode;
    // 偏好是缓存，不允许无限增长。
    if (_videoFitModes.length > 200) {
      _videoFitModes.remove(_videoFitModes.keys.first);
    }
    return _persist();
  }

  /// 记住一次显式轨道选择。
  ///
  /// 只允许用户显式选择调用：自动回落的结果写进来，一次失配就会把用户的
  /// 选择永久冲掉。与 `rememberVideoFitMode` 一样，写盘失败**不影响**当前
  /// 会话（内存里已生效），只记日志。
  Future<bool> rememberTrackChoice(String key, TrackChoice choice) {
    final normalized = key.trim();
    if (normalized.isEmpty || choice.isEmpty) return Future.value(true);
    if (_trackChoices[normalized] == choice) return Future.value(true);
    // 先删再插：Map 的迭代顺序就是插入顺序，重选要把这条挪到队尾，
    // 否则它会被当成"最旧的"在下一次裁剪时丢掉。
    _trackChoices.remove(normalized);
    _trackChoices[normalized] = choice;
    _trimTrackChoices();
    return _persist();
  }

  /// 记住主题模式。非法值归一化为默认。
  ///
  /// 与 `rememberVideoFitMode` 一样，写盘失败**不影响**当前会话（内存里已生效），
  /// 只记日志。
  Future<bool> rememberThemeMode(String mode) async {
    final normalized = UiThemeMode.normalize(mode);
    if (normalized == _themeMode) return true;
    _themeMode = normalized;
    return _persist();
  }

  /// 记住一次搜索关键词：提到最前、去重、裁剪到上限 10
  /// （上游安卓 `RecordAdapter.add` 同语义）。空词忽略。
  Future<bool> rememberSearchKeyword(String keyword) {
    final text = keyword.trim();
    if (text.isEmpty) return Future.value(true);
    final next = _dedupeKeywords([
      text,
      ..._searchKeywords.where((item) => item != text),
    ]);
    if (_listEquals(next, _searchKeywords)) return Future.value(true);
    _searchKeywords = next;
    return _persist();
  }

  /// 删除单条搜索历史（长按/删除按钮，上游 `RecordAdapter` 长按删除）。
  Future<bool> removeSearchKeyword(String keyword) {
    final next = [
      for (final item in _searchKeywords)
        if (item != keyword) item,
    ];
    if (next.length == _searchKeywords.length) return Future.value(true);
    _searchKeywords = next;
    return _persist();
  }

  /// 清空搜索历史。
  Future<bool> clearSearchKeywords() {
    if (_searchKeywords.isEmpty) return Future.value(true);
    _searchKeywords = const [];
    return _persist();
  }

  /// 记住相似度阈值（0~100，超范围归一到默认）。
  Future<bool> rememberSearchSimilarity(int value) {
    final normalized = value < 0
        ? _defaultSimilarity
        : (value > 100 ? 100 : value);
    if (_searchSimilarity == normalized) return Future.value(true);
    _searchSimilarity = normalized;
    return _persist();
  }

  /// 记住搜索并发线程数（夹到 1~100，上游 `clampSearchThread`）。
  Future<bool> rememberSearchThread(int value) {
    final normalized = _clampSearchThread(value);
    if (_searchThread == normalized) return Future.value(true);
    _searchThread = normalized;
    return _persist();
  }

  /// 记住点击历史记录的行为。非法值归一化为默认。
  Future<bool> rememberHistoryClickAction(String mode) {
    final normalized = UiHistoryClickAction.normalize(mode);
    if (normalized == _historyClickAction) return Future.value(true);
    _historyClickAction = normalized;
    return _persist();
  }

  /// 记住历史记录可见范围。非法值归一化为默认（按源）。
  Future<bool> rememberHistoryScope(String scope) {
    final normalized = UiHistoryScope.normalize(scope);
    if (normalized == _historyScope) return Future.value(true);
    _historyScope = normalized;
    return _persist();
  }

  /// 记住历史聚合模式。非法值归一化为默认（优先 TMDB）。
  Future<bool> rememberHistoryAggregation(String mode) {
    final normalized = UiHistoryAggregation.normalize(mode);
    if (normalized == _historyAggregation) return Future.value(true);
    _historyAggregation = normalized;
    return _persist();
  }

  /// 记住选集视图模式。非法值归一化为默认（网格）。
  Future<void> rememberEpisodeViewMode(String mode) async {
    final normalized = UiEpisodeViewMode.normalize(mode);
    if (normalized == _episodeViewMode) return;
    _episodeViewMode = normalized;
    await _persist();
  }

  /// 记住单项屏显开关。非法 id 忽略（不写坏状态）。
  Future<bool> rememberOsdFlag(String id, bool enabled) {
    if (!OsdFlag.values.contains(id)) return Future.value(true);
    if (_osdFlags[id] == enabled) return Future.value(true);
    _osdFlags[id] = enabled;
    return _persist();
  }

  /// 记住按钮顺序。输入的非法 id 会被过滤、缺失项会在**写入时**补全
  /// （`normalizeButtonOrder` 就把缺失项追加到末尾，所以落盘的 order 长度恒为 9）。
  Future<bool> rememberButtonOrder(List<String> order) {
    final normalized = normalizeButtonOrder(order);
    if (_listEquals(normalized, _buttonOrder ?? const [])) {
      return Future.value(true);
    }
    _buttonOrder = normalized;
    return _persist();
  }

  /// 记住按钮隐藏集。非法 id 会被过滤。
  Future<bool> rememberButtonHidden(Set<String> hidden) {
    final normalized = normalizeButtonHidden(hidden.toList());
    if (_setEquals(normalized, _buttonHidden ?? const <String>{})) {
      return Future.value(true);
    }
    _buttonHidden = normalized;
    return _persist();
  }

  /// 记住外部播放器路径。传空串等于清除（回到「未设置」）。
  Future<bool> rememberExternalPlayerPath(String? path) {
    final normalized =
        _externalPlayerCatalog.resolveExecutable(path?.trim()) ?? '';
    if (normalized == (_externalPlayerPath ?? '')) return Future.value(true);
    _externalPlayerPath = normalized.isEmpty ? null : normalized;
    return _persist();
  }

  /// 本次编辑后「上次所选」应指向哪里。
  ///
  /// 历史路径可能被多条记录共有（A→B 与 A→C 都留 A），按路径反查只能猜一条，
  /// 且创建顺序不等于最后拥有者。因此预选只跟随**被编辑的那条记录**：编辑前
  /// 预选解析到它，编辑后就指向本次目标；否则预选原样不动，不被历史夺走。
  String? _selectedPathAfterEdit({
    required ExternalPlayerCatalog previousCatalog,
    required String? previousPath,
    required String? originalExecutable,
    required String target,
    required ExternalPlayerCatalog next,
  }) {
    if (previousPath == null) return null;
    if (originalExecutable == null) return next.resolveExecutable(previousPath);
    // 比较必须走 Windows 路径归一化：`d:/players/A.EXE` 与
    // `D:\Players\A.exe` 是同一条记录，裸字符串比较会把它们判成两条。
    final wasSelected = _samePath(
      previousCatalog.resolveExecutable(previousPath),
      originalExecutable,
    );
    return wasSelected ? target.trim() : next.resolveExecutable(previousPath);
  }

  static bool _samePath(String? left, String? right) {
    if (left == null || right == null) return false;
    return ExternalPlayers.normalizeExecutablePath(left) ==
        ExternalPlayers.normalizeExecutablePath(right);
  }

  Future<bool> saveExternalPlayer({
    String? originalExecutable,
    required String name,
    required String executable,
    required List<ExternalPlayer> scanned,
    bool Function(String)? exists,
  }) {
    final result = _persistQueue.then((_) {
      final next = _externalPlayerCatalog.save(
        originalExecutable: originalExecutable,
        name: name,
        executable: executable,
        scanned: scanned,
        legacyExecutable: externalPlayerPath,
      );
      if (next == null) return false;
      try {
        if (!(exists ?? (path) => File(path).existsSync())(executable.trim())) {
          return false;
        }
      } catch (_) {
        return false;
      }
      final previous = _externalPlayerCatalog;
      final previousPath = _externalPlayerPath;
      _externalPlayerCatalog = next;
      _externalPlayerPath = _selectedPathAfterEdit(
        previousCatalog: previous,
        previousPath: previousPath,
        originalExecutable: originalExecutable,
        target: executable,
        next: next,
      );
      final ok = _doPersist();
      if (!ok) {
        _externalPlayerCatalog = previous;
        _externalPlayerPath = previousPath;
      }
      return ok;
    });
    _persistQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// 记住出站代理设置。
  Future<bool> rememberOutboundProxy(OutboundProxySettings settings) {
    if (_outboundProxy == settings) return Future.value(true);
    _outboundProxy = settings;
    return _persist();
  }

  /// 记住 DoH 设置。
  Future<bool> rememberDohSettings(DohSettings settings) {
    if (_dohSettings == settings) return Future.value(true);
    _dohSettings = settings;
    return _persist();
  }

  /// 记住隐身模式。
  Future<bool> rememberIncognito(bool incognito) {
    if (_incognito == incognito) return Future.value(true);
    _incognito = incognito;
    return _persist();
  }

  /// 记住追番设置。
  Future<bool> rememberFollowingSettings(FollowingSettings settings) {
    if (_followingSettings == settings) return Future.value(true);
    _followingSettings = settings;
    return _persist();
  }

  /// 记住详细调试日志开关。
  ///
  /// 与其它偏好一样：写盘失败**不影响**当前会话（内存里已生效）。
  Future<bool> rememberSpiderDebugLog(bool enabled) {
    if (_spiderDebugLog == enabled) return Future.value(true);
    _spiderDebugLog = enabled;
    return _persist();
  }

  /// 记住站点分组规则。
  Future<bool> rememberSiteGroupSettings(SiteGroupSettings settings) {
    if (_siteGroupSettings == settings) return Future.value(true);
    _siteGroupSettings = settings;
    return _persist();
  }

  /// 记住广告过滤开关。
  Future<bool> rememberAdBlockEnabled(bool enabled) {
    if (_adBlockEnabled == enabled) return Future.value(true);
    _adBlockEnabled = enabled;
    return _persist();
  }

  /// 记住解析接口失败切换设置。
  Future<bool> rememberParseFailover(ParseFailoverSettings settings) {
    final normalized = settings.normalized();
    if (_parseFailover == normalized) return Future.value(true);
    _parseFailover = normalized;
    return _persist();
  }

  /// 记住站点排序偏好。
  Future<bool> rememberSiteOrder(SiteOrderSettings settings) {
    if (_siteOrder == settings) return Future.value(true);
    _siteOrder = settings;
    return _persist();
  }

  /// 记住一份配置的站点列表覆盖（手动顺序 + 屏蔽）。
  ///
  /// [scopeKey] 为空说明当前没有可归属的配置（例如还没导入配置）：拒绝写入，
  /// 而不是把不同配置的顺序混到同一个桶里。
  Future<bool> rememberSiteListOverrides(
    String scopeKey,
    SiteListOverrides overrides,
  ) {
    final key = scopeKey.trim();
    if (key.isEmpty) return Future.value(false);
    if (siteListOverrides(key) == overrides) return Future.value(true);
    if (overrides.isEmpty) {
      _siteListOverrides.remove(key);
    } else {
      _siteListOverrides[key] = overrides;
    }
    return _persist();
  }

  /// 记住弹幕库设置。
  Future<bool> rememberDanmakuSettings(DanmakuSettings settings) {
    if (_danmakuSettings == settings) return Future.value(true);
    _danmakuSettings = settings;
    return _persist();
  }

  /// 记住弹幕显示样式。
  Future<bool> rememberDanmakuStyle(DanmakuStyle style) {
    if (_danmakuStyle == style) return Future.value(true);
    _danmakuStyle = style;
    return _persist();
  }

  /// 记住字幕源设置。
  Future<bool> rememberSubtitleSettings(SubtitleSettings settings) {
    if (_subtitleSettings == settings) return Future.value(true);
    _subtitleSettings = settings;
    return _persist();
  }

  /// 记住直播设置。
  Future<bool> rememberLiveSettings(LiveSettings settings) {
    if (_liveSettings == settings) return Future.value(true);
    _liveSettings = settings;
    return _persist();
  }

  /// 记住播放参数。归一化后比较，避免大小写/空格造成无意义写盘。
  Future<bool> rememberPlayerOptions(PlayerOptions options) {
    final normalized = options.normalized();
    if (_playerOptions == normalized) return Future.value(true);
    _playerOptions = normalized;
    return _persist();
  }

  /// 恢复按钮排版默认：清除两个键（对齐上游 `PlayerButtonSetting.reset()`，
  /// `PlayerButtonSetting.java:140-144`）。
  ///
  /// 上游还会清 `HIDDEN_SEEDED`；PC 端没有播种机制（无默认隐藏项），
  /// 所以只清两个键。详见 `docs/phase8/design/03` §4.5。
  Future<bool> resetPlayerButtons() {
    if (_buttonOrder == null && _buttonHidden == null) {
      return Future.value(true);
    }
    _buttonOrder = null;
    _buttonHidden = null;
    return _persist();
  }

  /// 夹到 1~100：0 或负数会让搜索一个请求都不发，超大值会打满对端。
  static int _clampSearchThread(int value) {
    if (value < _minSearchThread) return _minSearchThread;
    if (value > _maxSearchThread) return _maxSearchThread;
    return value;
  }

  /// 去重 + 裁剪到上限（保持传入顺序）。
  List<String> _dedupeKeywords(List<String> items) {
    final seen = <String>[];
    for (final item in items) {
      if (item.isEmpty || seen.contains(item)) continue;
      seen.add(item);
      if (seen.length >= _maxSearchKeywords) break;
    }
    return seen;
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.every(b.contains);

  /// 输入里是否至少有一个合法的按钮 id。
  ///
  /// 用于区分「文件里有个空壳对象」与「真的存过内容」：
  /// `playerButtons: {}`、`order: []`、`order: ""` **一律视为未设置**，
  /// 这样就不会把默认值固化进文件（`design/03` §4.5 的「缺席 = 默认」）。
  ///
  /// 注意语义方向：**空集不算「显式存过」**。因此用户手写一个空数组
  /// 表达「全部显示」的意图会被忽略——这与「缺席 = 默认」的既有语义一致。
  bool _hasAnyKnownId(Object? raw) {
    final ids = <String>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is String) ids.add(item.trim());
      }
    } else if (raw is String) {
      for (final part in raw.split(',')) {
        ids.add(part.trim());
      }
    }
    return ids.any(
      (id) => id.isNotEmpty && kPlayerButtons.any((spec) => spec.id == id),
    );
  }

  String _videoFitKey(String siteKey, String vodId) =>
      '${siteKey.trim()}\\n${vodId.trim()}';

  /// 偏好是缓存，不允许无限增长：超出上限按插入顺序丢最旧的。
  void _trimTrackChoices() {
    while (_trackChoices.length > _maxTrackChoices) {
      _trackChoices.remove(_trackChoices.keys.first);
    }
  }

  /// 写盘队列尾：串行化所有 `_persist` 调用。
  ///
  /// 为什么必须串行：`_persist` 是「写 tmp → 删旧 → 改名」三步，并发时两个
  /// 调用会在**同一个** `.tmp` 上互相踩（A 刚删掉 tmp，B 的 rename 就撞空
  /// 抛异常），最终 settings.json 可能被整个弄丢——实测连续搜索的 unawaited
  /// 历史落盘就触发了这个竞态（Windows 上 delete/rename 原子性比 POSIX 差）。
  /// 生产影响不止测试：任何连续两次偏好写入都可能丢掉全部 UI 设置。
  Future<void> _persistQueue = Future<void>.value();

  /// 串行化后的 `_persist`：本次写入在上一次完成后才开始。
  Future<bool> _persist() {
    final result = _persistQueue.then((_) => _doPersist());
    // 队列推进不能被单次失败阻塞：吞掉错误后继续接受下一次写盘。
    _persistQueue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  bool _doPersist() {
    // 写盘经共享工具（`settings_file.dart`）：
    // - **同步临界区**：`SyncState` 同时也在写同一个 `settings.json`。
    //   Dart 单线程，所以「读→改→写 tmp→rename」之间只要没有 `await`
    //   就不可能交错——这同时堵住了「文件丢失」与更隐蔽的「丢更新」
    //   （对方刚写的段被自己的陈旧读覆盖回去）。
    // - **独占临时名**：两者原先共用 `$path.tmp`，会互相覆盖。
    // - **只改 `ui` 段**：读回时保留 `sync` 段。
    final result = writeSettingsSectionSync(
      path: path,
      writer: SettingsWriter.uiPreferences,
      mutate: (root) {
        final ui = <String, Object?>{'lastSiteKey': _lastSiteKey};
        if (_videoFitModes.isNotEmpty) ui['videoFitModes'] = _videoFitModes;
        if (_trackChoices.isNotEmpty) {
          ui['trackChoices'] = <String, Object?>{
            for (final entry in _trackChoices.entries)
              entry.key: entry.value.toJson(),
          };
        }
        // 只有用户显式选过才写：缺席 = 默认，避免把默认值固化进文件。
        final mode = _themeMode;
        if (mode != null) ui['themeMode'] = mode;
        if (_searchKeywords.isNotEmpty) ui['searchKeywords'] = _searchKeywords;
        // 相似度同上：只有显式设置过才写，缺席 = 默认 30。
        final similarity = _searchSimilarity;
        if (similarity != null) ui['searchSimilarity'] = similarity;
        // 并发线程数：同样缺席 = 默认 20。
        final thread = _searchThread;
        if (thread != null) ui['searchThread'] = thread;
        // 点击行为同上：只有显式设置过才写，缺席 = 默认 detail。
        final clickAction = _historyClickAction;
        if (clickAction != null) ui['historyClickAction'] = clickAction;
        // 历史范围：只有显式设置过才写，缺席 = 默认 source。
        final scope = _historyScope;
        if (scope != null) ui['historyScope'] = scope;
        // 历史聚合：只有显式设置过才写，缺席 = 默认 tmdb（优先 TMDB）。
        final aggregation = _historyAggregation;
        if (aggregation != null) ui['historyAggregation'] = aggregation;
        // 选集视图：只有显式设置过才写，缺席 = 默认 grid。
        final viewMode = _episodeViewMode;
        if (viewMode != null) ui['episodeViewMode'] = viewMode;
        // 详细调试日志：显式切过就写（含 false），从未设置过则缺席 = 默认关闭。
        final spiderDebugLog = _spiderDebugLog;
        if (spiderDebugLog != null) ui['spiderDebugLog'] = spiderDebugLog;
        // 屏显：只有显式设置过的项才写（缺席 = 默认）。
        if (_osdFlags.isNotEmpty) ui['osd'] = _osdFlags;
        // 按钮排版：两个键各自独立；都缺席时整个 playerButtons 不写。
        final order = _buttonOrder;
        final hidden = _buttonHidden;
        if (order != null || hidden != null) {
          ui['playerButtons'] = <String, Object?>{
            // 用 null-aware 值 `?order` 而不是 `if (order != null) 'order': order,`：
            // 后者在本仓库工具链下触发 `use_null_aware_elements`（实测确认）。
            'order': ?order,
            if (hidden != null) 'hidden': hidden.toList()..sort(),
          };
        }
        // 外部播放器：缺席 = 未配置（与按钮排版同一口径）。
        final externalPath = _externalPlayerPath;
        if (externalPath != null) ui['externalPlayerPath'] = externalPath;
        if (!_externalPlayerCatalog.isEmpty) {
          ui['externalPlayers'] = _externalPlayerCatalog.toJson();
        }
        root['ui'] = ui;
        if (_aiIntegrationSettings.isNotEmpty) {
          root['aiIntegration'] = _aiIntegrationSettings;
        }
        // 播放参数：只有显式设置过才写（缺席 = 默认，与 ui 段同一口径）。
        final player = _playerOptions;
        if (player != null) root['player'] = player.normalized().toJson();
        final live = _liveSettings;
        if (live != null) root['live'] = live.toJson();
        final subtitles = _subtitleSettings;
        if (subtitles != null) root['subtitles'] = subtitles.toJson();
        final danmaku = _danmakuSettings;
        if (danmaku != null) root['danmaku'] = danmaku.toJson();
        final danmakuStyle = _danmakuStyle;
        if (danmakuStyle != null) {
          // 显式改回默认时把旧段删掉，避免留下「看起来设置过」的脏数据。
          if (danmakuStyle.isDefault) {
            root.remove('danmakuDisplay');
          } else {
            root['danmakuDisplay'] = danmakuStyle.toJson();
          }
        }
        final siteOrder = _siteOrder;
        if (siteOrder != null) root['siteOrder'] = siteOrder.toJson();
        // 空覆盖在写入前过滤，并在整段为空时删键：删掉最后一项屏蔽后不留
        // 「看起来设置过」的脏数据（与 danmakuDisplay 同口径）。
        final siteList = <String, Object?>{
          for (final entry in _siteListOverrides.entries)
            if (!entry.value.isEmpty) entry.key: entry.value.toJson(),
        };
        if (siteList.isEmpty) {
          root.remove('siteList');
        } else {
          root['siteList'] = siteList;
        }
        final parseFailover = _parseFailover;
        if (parseFailover != null) {
          root['parseFailover'] = parseFailover.toJson();
        }
        final adBlockEnabled = _adBlockEnabled;
        if (adBlockEnabled != null) {
          root['adBlock'] = <String, Object?>{'enabled': adBlockEnabled};
        }
        final siteGroup = _siteGroupSettings;
        if (siteGroup != null) root['siteRules'] = siteGroup.toJson();
        final outbound = _outboundProxy;
        if (outbound != null) root['outboundProxy'] = outbound.toJson();
        final doh = _dohSettings;
        if (doh != null) {
          // 显式改回默认（关闭且无端点）时删段，避免留下「看起来设置过」的脏数据。
          if (doh.isDefault) {
            root.remove('doh');
          } else {
            root['doh'] = doh.toJson();
          }
        }
        final following = _followingSettings;
        if (following != null) {
          if (following.isDefault) {
            root.remove('following');
          } else {
            root['following'] = following.toJson();
          }
        }
        final incognito = _incognito;
        if (incognito != null) {
          // 默认值不写盘（缺席 = false）；显式关掉时删掉旧键。
          if (incognito) {
            root['incognito'] = true;
          } else {
            root.remove('incognito');
          }
        }
        return true;
      },
    );
    if (!result.ok) {
      _log?.error('保存 UI 偏好失败：${result.error}', scope: 'ui');
      return false;
    }
    return true;
  }
}
