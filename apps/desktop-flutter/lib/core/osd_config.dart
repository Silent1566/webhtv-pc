/// 屏显（OSD）开关模型（`docs/phase8/design/02` §5）。
///
/// 纯数据 + 纯函数：不依赖 Flutter，不碰磁盘，便于单元测试直接覆盖
/// 「默认值」「归一化」「全关判定」三件事。
///
/// 上游依据：`PlayerSetting.java:562-563` 的 7 项 `getDisplayChecked()`，
/// 默认值见 `PlayerSetting.java:508-560`。
library;

/// 屏显开关的稳定 id。
///
/// 这些字符串会落盘（`settings.json` 的 `ui.osd`），**不得改名**。
abstract final class OsdFlag {
  /// 上左：标题（片名 · 第 N 集）。
  static const String title = 'title';

  /// 上左第二行：分辨率。
  static const String size = 'size';

  /// 上右：时钟。
  ///
  /// **与上游的有意差异**：上游 `display_time` 默认 false，PC 端默认 true。
  /// 理由：PC 是「坐在电脑前」的场景（`PRODUCT.md` §Users），全屏播放时
  /// 任务栏不可见，时钟是真实需求（用户 2026-10-18 确认）。
  static const String time = 'time';

  /// 下左：播放进度。
  static const String progress = 'progress';

  /// 下右：网速。
  ///
  /// **已实现**（`docs/phase8/design/02` §3.6 的原计划是"本轮无实现"，
  /// 现在数据源到位）：单位是字节/秒，由 `PlayerController.sampleNetworkRate`
  /// 在屏显刷新循环里每秒采一次，屏显层用 `formatByteRate` 格式化。
  ///
  /// **数据源是两个 mpv 属性，不是一个**（实测确认，见下）：
  /// 1. `demuxer-cache-state` → 它是 JSON 串，内含 `raw-input-rate` 字段；
  /// 2. 回退 `cache-speed` → 独立属性，double 的字符串形式。
  ///
  /// **`raw-input-rate` 不是独立属性**：`mpv_get_property('raw-input-rate')`
  /// 实测返回 `-8 = MPV_ERROR_PROPERTY_NOT_FOUND`。它只作为
  /// `demuxer-cache-state` 里的**键名**存在——所以在 `libmpv-2.dll` 的字符串表里
  /// 能搜到它，但直接当属性读永远是空串。曾有一版据此写成"取 `raw-input-rate`
  /// 属性"，导致屏显永远显示 `—`（用户实测反馈）。
  ///
  /// **取不到值时显示 `—`（长破折号），不显示 0**：
  /// 非 NativePlayer 平台、属性为空串、解析失败（mpv 会回 `nan` / `inf`）、
  /// 以及**起播头一秒缓存尚未建立**（`demuxer-cache-state` 此时回 NULL）
  /// 都归为 null。0 会被读成"网速为零（卡了）"，而"没有这个数"是另一件事。
  static const String traffic = 'traffic';

  /// 底部 2dp 迷你进度条。
  static const String mini = 'mini';

  /// 顶部诊断面板。
  static const String diagnostics = 'diagnostics';

  /// 全部 id，顺序即配置页的展示顺序。
  static const List<String> values = [
    title,
    size,
    time,
    progress,
    traffic,
    mini,
    diagnostics,
  ];
}

/// 默认开关表。
///
/// 与上游的差异：`time` 默认 true（见 [OsdFlag.time] 的注释）。
Map<String, bool> defaultOsdFlags() => {
  OsdFlag.title: true,
  OsdFlag.size: true,
  OsdFlag.time: true,
  OsdFlag.progress: true,
  OsdFlag.traffic: false,
  OsdFlag.mini: false,
  OsdFlag.diagnostics: false,
};

/// 把任意输入归一化成完整的 7 项开关表。
///
/// 规则（`docs/phase8/design/02` §5.2）：
/// - 未知键**忽略**（不抛异常，不写入结果）；
/// - 缺失键用 [defaultOsdFlags] 补齐；
/// - 非 `bool` 的值回落默认（手改文件写成 `"yes"` / `1` / `null` 时不让状态变脏）；
/// - 非 `Map` 输入整体回落默认。
///
/// 与 `UiThemeMode.normalize` 同一语义：**只接受合法值，其余回落默认**。
Map<String, bool> normalizeOsdFlags(Object? raw) {
  final defaults = defaultOsdFlags();
  if (raw is! Map) return defaults;
  final result = <String, bool>{};
  for (final id in OsdFlag.values) {
    final value = raw[id];
    result[id] = value is bool ? value : defaults[id]!;
  }
  return result;
}

/// 是否至少有一项屏显开启。
///
/// 全关时屏显层完全隐藏且停止刷新循环（`docs/phase8/design/02` §4.3）。
bool anyOsdEnabled(Map<String, bool> flags) => flags.values.any((on) => on);
