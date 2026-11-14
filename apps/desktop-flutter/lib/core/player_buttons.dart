/// 播放器按钮的排版模型（`docs/phase8/design/03`）。
///
/// 纯数据 + 纯函数：不依赖 Flutter，不碰磁盘。
///
/// 上游依据：`PlayerButtonSetting.java`。**PC 端只取可用子集**——
/// 上游 32 个按钮里，PC 端只沿用 6 个（`speed`/`quality`/`prev`/`next`/`episodes`/
/// `fullscreen`），其余 26 个全部排除——它们没有真实实现，不得为了对齐而伪造入口
/// （`PRODUCT.md` §Product Principles 第 5 条「不承诺能力范围」）。
library;

/// 按钮分组。分组边界在渲染时插入一条发丝竖线（不可配置）。
enum PlayerButtonGroup {
  /// 传输：上一集 / 播放暂停 / 下一集。
  transport('传输'),

  /// 音量：静音 / 音量滑杆。
  volume('音量'),

  /// 速率与选集：倍速 / 剧集。
  ///
  /// 「线路」曾是这一组的第三个成员，现已移除：切线路并入选集面板——
  /// 用户在选集时本来就在看「哪条线路的哪一集」，单独一条线路下拉只是重复入口。
  rate('速率与选集'),

  /// 显示：全屏 / 外部播放器。
  ///
  /// 「外部播放器」归这里而不是「传输」：它和全屏一样是**换一种输出方式**，
  /// 不是播放控制。不新开一组——分组的目的是缩短主列，而只有一项的组没有
  /// 存在价值（本文件 `kPlayerButtons` 的既有取舍）。
  display('显示');

  const PlayerButtonGroup(this.label);

  final String label;
}

/// 一个可配置按钮的静态定义。
class PlayerButtonSpec {
  const PlayerButtonSpec({
    required this.id,
    required this.label,
    required this.group,
  });

  /// 稳定标识，落盘用。**不得改名**。
  final String id;

  /// 配置页显示的中文名。
  final String label;

  final PlayerButtonGroup group;
}

/// PC 端**可配置**的按钮全集（10 个）。
///
/// ## 为什么是 10 个而不是上游的 32 个
///
/// 上游 `PlayerButtonSetting.java:21-52` 定义 32 个 id。PC 端只沿用其中 6 个
/// （`speed` / `quality` / `prev` / `next` / `episodes` / `fullscreen`），其余 26 个全部排除，
/// 因为它们**没有真实实现**——放一个点了没反应的按钮比不放更糟
/// （`DESIGN.md` 关于筛选按钮的同类教训）。
///
/// 排除清单与理由：
/// - `decode` / `player` / `play_params`：PC 只有 media-kit 一个引擎，无解码器切换
/// - `codec_capability`：无硬件解码能力探测
/// - `lut` / `karaoke` / `immersive_audio` / `timer` / `repeat`：未实现
/// - `cast`：无 DLNA / 投屏
/// - `pan_diagnostic`：无网盘专用诊断
/// - `ad_feedback`：无广告反馈
/// - `opening` / `ending`：无片头片尾跳过
/// - `parse`：解析线路由站点配置决定，不暴露手动切换
/// - `multi_thread_proxy`：代理是站点级配置，不是播放器按钮
/// - `scale`：画面比例归顶栏菜单与右键菜单，不占控制栏按钮位
/// - `reset`：PC 端「重置」语义不明确
/// - `search`：播放中搜索是独立流程，不在播放器浮层
/// - `display`：屏显开关归屏显设置（`docs/phase8/design/02` §5）
/// - `title`：标题归顶栏
/// - `change`：换源是详情页动作
/// - `text` / `audio` / `video`：轨道选择归顶栏（字幕轨）与右键菜单，
///   PC 端无独立音轨/视频轨选择 UI
/// - `danmaku`：顶栏常驻（被测试锁定），见下一节
///
/// ## PC 端新增的 3 个 id（上游没有）
///
/// - `play`：上游的播放键是**中央大按钮**（`view_control_vod.xml:219-226`），
///   不在动作行里；PC 端把它放进动作行，因为它是最常碰的按钮。
/// - `mute` / `volume`：上游音量走手势（`PlayerGesture` 的滑动），PC 无手势。
///
/// ## 为什么 `subtitle` / `danmaku` 也不在里面
///
/// 它们现状在**顶栏**，且被集成测试按精确 tooltip 直接 `tap`
/// （`integration_test/subtitle_flow_test.dart:144,153`、
/// `integration_test/danmaku_flow_test.dart:156,175`）。
/// 用户一隐藏，测试就红。且顶栏只有 3 个常驻控件，**没有拥挤问题**，
/// 不需要用户来裁剪。详见 `docs/phase8/design/03` §5.3。
///
/// `video_fit` / `media_info` / `diagnostics` 是**菜单项**而不是按钮，
/// 同样不进这个集合。
const List<PlayerButtonSpec> kPlayerButtons = [
  PlayerButtonSpec(
    id: 'prev',
    label: '上一集',
    group: PlayerButtonGroup.transport,
  ),
  PlayerButtonSpec(
    id: 'play',
    label: '播放/暂停',
    group: PlayerButtonGroup.transport,
  ),
  PlayerButtonSpec(
    id: 'next',
    label: '下一集',
    group: PlayerButtonGroup.transport,
  ),
  PlayerButtonSpec(
    id: 'mute',
    label: '静音',
    group: PlayerButtonGroup.volume,
  ),
  PlayerButtonSpec(
    id: 'volume',
    label: '音量',
    group: PlayerButtonGroup.volume,
  ),
  PlayerButtonSpec(
    id: 'speed',
    label: '倍速',
    group: PlayerButtonGroup.rate,
  ),
  PlayerButtonSpec(
    id: 'quality',
    label: '画质',
    group: PlayerButtonGroup.rate,
  ),
  PlayerButtonSpec(
    id: 'episodes',
    label: '剧集',
    group: PlayerButtonGroup.rate,
  ),
  PlayerButtonSpec(
    id: 'fullscreen',
    label: '全屏',
    group: PlayerButtonGroup.display,
  ),
  PlayerButtonSpec(
    id: 'external_player',
    label: '外部播放器',
    group: PlayerButtonGroup.display,
  ),
];

/// 默认顺序 = 定义顺序。
///
/// 与改造前的实际排布一致（`player_page.dart:2144-2239`）——
/// 可配置性是**新能力**，不是重新设计。
List<String> defaultButtonOrder() =>
    kPlayerButtons.map((spec) => spec.id).toList();

bool _isKnownId(String id) => kPlayerButtons.any((spec) => spec.id == id);

/// 把任意输入拆成 id 字符串列表。
///
/// 接受两种形态：
/// - `List`（PC 端落盘格式）；
/// - 逗号分隔 `String`（上游 `PlayerButtonSetting.java:237-240` 的格式，
///   用于兼容从安卓迁移来的设置或手改过的文件）。
List<String> _splitIds(Object? raw) {
  if (raw is List) {
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
  }
  if (raw is String) {
    return [
      for (final part in raw.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }
  return const [];
}

/// 归一化按钮顺序。
///
/// **返回的是新列表，每次调用都是新实例**——`List` 的 `==` 是身份比较，
/// 所以 `normalizeButtonOrder(x) != normalizeButtonOrder(x)`。
/// 调用方做变更检测时**必须按值比较**（`listEquals` / 逐项比较），
/// 否则 `if (normalized != _order) save()` 会在每次加载时都写盘
/// （本仓库的写盘走 `writeSettingsSectionSync` + 串行队列，代价不低）。
///
/// 规则（对齐上游 `PlayerButtonSetting.getOrder()`，
/// `PlayerButtonSetting.java:210-215`）：
/// 1. 取已存顺序里**合法**的 id，去重，保持原顺序；
/// 2. 把 [kPlayerButtons] 中**不在结果里**的按默认顺序**追加到末尾**。
///
/// 第 2 步是关键：**新增按钮会自动出现在老配置里**，
/// 不会因为用户存过顺序就永久消失。
///
/// 输入为空或非法时回落 [defaultButtonOrder]。
List<String> normalizeButtonOrder(Object? raw) {
  final seen = <String>{};
  final result = <String>[];
  for (final id in _splitIds(raw)) {
    if (!_isKnownId(id)) continue;
    if (seen.add(id)) result.add(id);
  }
  for (final spec in kPlayerButtons) {
    if (seen.add(spec.id)) result.add(spec.id);
  }
  return result;
}

/// 归一化隐藏集：过滤非法 id、去重。
///
/// **只接受 `List` 与逗号分隔 `String`**，不认 `Set`——传 `Set` 会静默返回空集
/// （`_splitIds` 对非 List/String 返回 `const []`）。调用方持 `Set` 时必须先
/// `.toList()`。实测确认：`normalizeButtonHidden({'speed','fullscreen'})` → `{}`。
Set<String> normalizeButtonHidden(Object? raw) => {
  for (final id in _splitIds(raw))
    if (_isKnownId(id)) id,
};

/// 解析出**实际要渲染**的按钮列表：按 [order] 排序，按 [hidden] 过滤。
List<PlayerButtonSpec> resolveVisibleButtons({
  required List<String> order,
  required Set<String> hidden,
}) {
  final byId = {for (final spec in kPlayerButtons) spec.id: spec};
  return [
    for (final id in order)
      if (!hidden.contains(id)) ?byId[id],
  ];
}
