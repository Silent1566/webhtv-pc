# 详情页同集多版本聚合设计

状态：已实现并验收（2026-11-20）。最终约束：仅当前线路有可聚合的同集多版本才显示聚合开关，关闭聚合后开关仍显示；实现与验收记录见同日期 plan。

## 已定要求
- 当前作品/线路内部聚合，默认开启，保存为 UI 偏好；不跨线路、跨来源合并。纯 TMDB 导航页不显示开关。
- 开关在名称切换按钮之后，仅在完整当前线路存在多版本组时显示；名称、列表/网格、顺倒序不改变分组身份。
- 一集一张聚合卡，多个版本显示版本数角标；单版本直接播放，多版本必须弹窗选中后确认。
- 弹窗逐版本显示可识别版本特征、完整源名、大小，优先选择上次同组播放的具体 URL，其他按源顺序；取消不解析、不写历史。
- 标题和大小分离；单版本显示大小，多版本全部可比较显示最小至最大或相同值，部分缺失显示「大小不全」，全缺失不显示；不相加、不拿最大值代表整组。原始名称保留原文于弹窗，卡面移除已单独展示的大小 token 防重复；多版本原名卡用组 label。
- 文件大小参考安卓源标题提取，不额外请求、不探测网盘，不凭大小选版本；KB/MB/GB 及 M/G/T 别名按十进制，KiB/MiB/GiB 按二进制，不能识别则不显示摘要。
- 明确季集号或已确认 AI 绑定可聚合；来源位置推断、同显示标题、普通 TMDB extra 猜号不能作为聚合证明。未知条目独立保留；季、上下篇、正片/预告/花絮等不同内容不可误并。
- 每条原始 VodEpisode/URL/sourceIndex 保留；播放和历史继续使用原资源身份，不修改站源协议，不丢资源，不引入依赖。
- 聚合开启时上下集按逻辑组推进，跳过同集其他版本、不自动跨季；选定版本的可识别特征唯一匹配下一集时自动播放，否则暂停并弹窗。关闭弹窗保留当前媒体；不借用其他版本的进度。
- 全局 UI 偏好与版本偏好分离：聚合开关持久化，版本偏好只由当前作品/线路的所选具体文件推导，不跨作品记忆。
- 保留直播、回看、显式队列、纯 TMDB 导航、外部来源路由、原始 flag、URL、续播种子规则及已有无聚合体验。

## 共享接口（冻结）
`lib/core/episode_aggregation.dart`：
```dart
class EpisodeFileSize {
  final String label;
  final double bytes;
  static EpisodeFileSize? parse(String input);
  static String strip(String input);
}
class EpisodeVersion {
  final VodEpisode episode;
  final int sourceIndex;
  final EpisodeFileSize? fileSize;
  String get label; // 可靠特征摘要，无信息时空串
}
class EpisodeGroup {
  final String key;
  final int seasonNumber; // -1 未知；0 特典（若确认）
  final int episodeNumber; // 0 未知，不用于合并
  final List<EpisodeVersion> versions;
  bool get isMultiple;
  String get label; // S1E1 / 第1集 / 未知源名；保留上下篇类别
  String get sizeSummary;
}
abstract final class EpisodeAggregation {
  static List<EpisodeGroup> build(List<VodEpisode> episodes, {String scope = '', List<int>? sourceIndices});
  static EpisodeVersion? preferredVersion(EpisodeGroup group, VodEpisode previous);
  static EpisodeGroup? adjacentGroup(List<EpisodeGroup> groups, {required int currentSourceIndex, required int direction, bool stayInSeason = true});
}
```
构建输出为不可变视图、按组第一次出现顺序保留、版本保持源顺序；sourceIndices 映射原始线路下标，缺省使用输入位置。相邻组方向只接受 -1/+1；无相邻组、季边界、非法当前位置返回 null。preferredVersion：单版本直接返回；多个版本只在 previous 的非空可靠特征全部匹配且候选唯一时返回，否则 null。不能用 URL 猜下一集、大小接近、源排列顺序或空特征作为自动选版依据。

已确认绑定采用唯一显式来源标识：`applyAiEpisodeBindings` 在已有季集字段旁写 `episode_identity_confirmed: true`，分组只信这一标识的 extra；不信仅有 TMDB 季集字段的猜号结果。若显式源季集与绑定相互矛盾，保守独立显示。

`lib/ui/episode_version_dialog.dart`：
```dart
Future<EpisodeVersion?> showEpisodeVersionDialog(BuildContext context, {required EpisodeGroup group, String lineName = '', String? preferredUrl});
```
只选择并返回原 EpisodeVersion，不解析网络；调用者在返回且 mounted/请求仍有效时才播放。

`AppState`：`bool get episodeAggregateVersions`（默认 true）、`Future<void> setEpisodeAggregateVersions(bool enabled)`；`UiPreferencesStore` 对应 getter/rememberEpisodeAggregateVersions。

## 验收
每一资源仍可访问；按钮有重复才显示且关闭后可重开；保留普通1:1卡片契约、在详情额外投影视图层聚合，不改全局 TmdbEpisodeCards 数量不变量。大小解析覆盖安卓样例、防误判、不同单位与缺失。上下集覆盖同版本唯一匹配、歧义弹窗、取消、跨季与非聚合回退。深浅主题同场景 Before/After（1024宽、包含长名和多版本）及弹窗 After；文字放大1.5无溢出。
