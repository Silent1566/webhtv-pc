# 观影报告 v2 设计与验收

用户已确认：四维偏好 + 跨文化探索者徽章 + 站源分布 + 7×24 热力图 + 上一周期对比；站点元数据优先、本地 TMDB 详情仅补缺。参考清单 docs/phase9/parity-2026-11-12/catalog.md:19。基线 7b6f3f7，基线观影报告/AI 测试 23/23。

## 不变约束
- 离线基础报告；打开报告零网络请求，不自动调用 AI。不新增依赖。
- 不更改已有历史的进度、更新时间、主键或来源归属；加法式数据库升级，旧行继续可用。
- 隐身模式不采集观影元数据。不改 Android 同步、备份格式、播放器请求协议。
- 元数据按 sourceKey/siteKey/vodId 隔离并校验作品标题；不能把另一个配置相同 site/vod 的信息用作兜底。
- 无可靠身份/元数据即未知；不得从混合 credit 字符串猜演员/导演，也不能把缺类型的记录默认为电视剧。
- 热力图/周末/时段按历史 updatedAt；时长是历史 position 累计，不是实际观看会话计时。四维频数按历史记录，每条记录每个标签只计一次；页面说明不是作品级投票。
- 各偏好维度独立覆盖率；未知不进入榜单/探索者徽章。地区满 4 个真实不同地区获得 explorer。
- 统计/页面沿用现有默认构造参数兼容老测试和其他调用者。新功能只扩展，不改变基础统计既有定义。
- 保留现有夜空/星等配色、Material 桌面组件和 tokens，不改 DESIGN.md 或设置页。
- 不提交、不推送、不创建新 worktree。实现/测试可自行使用 native tools；不得派生子代理。

## 冻结接口（供三个并行模块使用）
core/viewing_metadata.dart:
class ViewingMetadata {
  const ViewingMetadata({this.genres = const [], this.areas = const [],
    this.actors = const [], this.directors = const [], this.mediaType = ''});
  final List<String> genres, areas, actors, directors;
  final String mediaType; // movie/tv/''
}
// A 负责实现；可以增加纯转换/归一化方法，不改变上述签名。

state/app_state.dart:
Map<int, ViewingMetadata> viewingReportMetadata(List<PlaybackHistory> records);
// A 负责实现：只读本地元数据/缓存，key 为 record.id。
// 每个来源作品/可靠 TMDB 身份只查一次；捕获损坏/无库/未 bootstrap，降级空 Map。

core/viewing_report.dart:
ViewingReport generateViewingReport({required List<PlaybackHistory> records,
  ViewingReportRange range = ViewingReportRange.all, DateTime? now,
  Map<int, ViewingMetadata> metadata = const {}});
class ViewingPreferenceStat {
  const ViewingPreferenceStat({required this.name, required this.count});
  final String name; final int count;
}
class ViewingSourceStat {
  const ViewingSourceStat({required this.sourceKey, required this.siteKey,
    required this.count});
  final String sourceKey, siteKey; final int count;
}
class ViewingReportComparison {
  const ViewingReportComparison({required this.startMs, required this.endMs,
    required this.recordCount, required this.totalWatchMs,
    required this.uniqueVodCount});
  final int startMs, endMs, recordCount, totalWatchMs, uniqueVodCount;
}
// B 负责实现；ViewingReport 新增以下可选参数与字段：
// List<ViewingPreferenceStat> topGenres/topAreas/topActors/topDirectors (默认 [])
// Map<String,int> metadataCoverage (默认 {}，keys genre/area/actor/director/type)
// int movieCount/tvCount/unknownTypeCount (默认 0)
// List<ViewingSourceStat> sources (默认 [])
// List<List<int>> weekdayHourCounts (默认 []，生成结果固定 7×24 周一到周日)
// ViewingReportComparison? comparison (默认 null)

ui/viewing_report_page.dart:
// C 新增可选测试注入 final Map<int,ViewingMetadata>? metadataOverride;
// 没有 override 则 state.viewingReportMetadata(_records)，传给 generateViewingReport。

## 数据链路
A 为来源详情新增独立本地元数据表（可在新 service 用 AppDatabase 原生 execute/query seam，或按既有模式在 storage.dart 中封装），schema 10→11，只加表。loadDetail 成功且运行号/来源仍对应本次请求后，缓存站点真实元数据；不创建历史。recordProgress 自带完整 Vod 时也可补快照。已有历史再次查看同作品详情可覆盖缺失维度，不能因为海报补齐/同步空字段清掉快照。
TMDB 兜底只读取历史已有 movie/tv+ID 或严格当前记录源域的已绑定匹配；从完整 details/credits/aggregate_credits 获得分维名单，源内嵌 TMDB 也需验证身份。只补缺，不覆盖站点值；ISO 地区码可用已有映射，未知码保留如实标识。读取缓存不得调用 detail() 发网；若确需新增 cache-only 方法，A 可在 tmdb_service/tmdb_cache 内封装，不暴露 token。

## 统计与环比
题材/地区/导演 top5、演员 top8；同数按名称稳定排序。未知占比由各维覆盖数/recordCount 显示。站源分布以 sourceKey+siteKey 分组，UI 不展示 sourceKey 中的配置 URL。
全部不提供上一期；滑动 7/30 天比较紧邻的等长区间。周/月/季/年/半年比较上一日历周期的同期（从对应起点到相同已过时长，最多截到上一周期结束，不纳入未来）。firstHalf 在下半年已结束时仍比较上个完整半年；secondHalf 当前尚未开始时空态，不构造反向范围。零基数只显示新增/无记录，不显示无穷百分比。端点不得双计；DST 使用本地日历构造。当前基础统计保留安卓快照口径。
AI prompt 增加已知偏好/覆盖率但视为不可信数据；范围切换立即清除旧解读，旧响应不准覆盖新范围，新请求不被旧响应解除 loading。

## 页面方向（Operate / Read，现有世界的局部扩展）
顶部范围、摘要 KPI 和口径提示；其后为周期对比、观看习惯（时段+7×24 热力图）、内容偏好（四维+覆盖率+已知电影/剧集/未知）、站源与最常看，最后可选 AI。宽屏四维双列、窄屏单列；禁止固定宽度溢出。热力图有星期/小时轴、图例、每格 tooltip/语义文本（周几/小时/记录数）；不用单纯颜色表达值。无元数据时保留清晰未知/如何增加覆盖提示，基础报告仍可用。长中英文标题/人物名截断或换行，不覆盖数值。

## 验收与证据
A：新/旧库迁移、重开保留、不更改历史、空字段不抹除、跨源同 ID、过期详情、隐身、损坏缓存、无凭据/无网降级、源与 TMDB 各维补缺。
B：黄金四维、去重/未知/覆盖率/稳定排序、explorer 真值阈值、7×24 边界、跨源分布、全部/滑动/月季年半年/DST/零基数对比、AI prompt 注入、23 条基线保持通过。
C：空历史/全未知/有元数据/长文/窄屏/亮暗主题/范围切换及延迟 AI 响应；同 fixture、now、theme、viewport 的 Before/After 截图，真实 widget 渲染，中文与图标字体加载；至少暗色 1280×950 顶部与下半报告配对，补窄屏/亮色检查。
最终独立复跑三模块 + 原报告/AI + 历史/同步/隐身/源内嵌 TMDB 相关回归，flutter analyze；精确记录运行范围，未做联网/真实 Windows 播放不得宣称完成。
