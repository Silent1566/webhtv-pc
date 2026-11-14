# TMDB 源内嵌 payload 与订阅凭据设计

用户确认：payload 安卓同构（含按缺口补齐合并）；根 tmdb_api_key 当前配置兜底且用户设置优先；导入即从普通配置剥离。

## 数据与行为
- schema=1、正数 id、media_type movie/tv、非负 season_number（movie 只能 0）；detail 内身份冲突拒绝。
- 验证/安全裁剪采用安卓 TmdbSourcePayloadParser；complete 规范化并按安卓现有规则去除无支持的静态/季 claims；episode/episode_videos 空数据完整性声明保持安卓语义，不额外发明拒收规则。
- 可渲染 payload 在任何网络等待之前发布；身份型 payload 无 key 不伪装成完整详情。
- 配置缺失只阻止网络，不阻止来源数据展示；显式 TMDB 总开关与站点禁用沿已有策略，不绕过用户选择。
- 来源优先 fill-only；complete 空数组/0 值有语义，不能被补齐覆盖。语言不兼容时按安卓 display-language 规则补标题/简介。不同身份结果拒绝。
- 初屏 core/credits/images、季集、视频/相关推荐按用户可达需求进行缺口规划；无缺口不请求相应网络。补齐失败保留来源首屏。
- 元数据不是播放事实源；不得增加/删除/覆盖站源播放集。代际/配置作用域防迟到串剧。
- 单集详情弹窗（ui/tmdb_episode_detail.dart）纳入本轮：payload 声明 episode/episode_videos complete 时从 payload 渲染并零请求；未 complete 时保留现有网络补齐。
- tmdb_api_key 只接收字符串，trim 后 16..256 ASCII 可见无空白字符；重复根字段拒收，非法 JSON 不泄露 key。
- key 在成功导入配置后才接受，作用域含配置记录 id/来源/代际；失败导入保留现配置，不准迟到导入污染新配置。
- 用户 apiKey/accessToken 优先；用户 enabled=false 不因订阅 key 自动开启。订阅 key 是内存作用域值（安卓 SubscriptionTmdbCredentialStore:12），不进入 settings/config/导出/日志。切换、删除、重启后失效，重新导入/刷新再接收。
- 桌面工具链 Flutter 3.47.5 / Dart 3.13.4；不增加依赖、不提交/推送、不重构无关代码。

## 冻结公共接口
文件 core/tmdb_source_payload.dart（不依赖 protocol，避免循环）：

```dart
class TmdbSourcePayload {
  static TmdbSourcePayload? fromJson(Object? value);
  final int schema, id, seasonNumber;
  final TmdbMediaType mediaType;
  final String language, fetchedAt;
  final Set<String> complete;
  final Map<String,Object?> detail;
  TmdbIdentity get identity;
  Map<String,Object?> toJson();
}
class TmdbSourcePlan {
  final Set<String> required, available, missing;
  bool get needsNetwork;
}
TmdbSourcePlan planTmdbSource(TmdbSourcePayload payload,
    {required Set<String> required, String targetLanguage = ''});
Map<String,Object?> mergeTmdbSourceDetail(TmdbSourcePayload payload,
    Map<String,Object?> lower, {String targetLanguage = ''});
```
Vod.tmdb 是由 extra['tmdb'] 解析的类型化 getter，保留现有构造/extra/toJson 往返约定。B 不写 protocol；C 不写 protocol 或源核心。配置核心与详情核心只经 AppState.tmdbConfig 的有效配置 getter 相接；设置编辑使用新增 AppState.tmdbUserConfig（手动持久化配置），不得读取订阅凭据。
手动结论只读 seam：TmdbMatchRecord? TmdbIdentityService.cachedManual({required String siteKey, required String vodId, required String sourceTitle})；复用 store.find 的键/范围，只返回 isManual，零网络/搜索；source 自动身份不得覆盖它。

## 验收
单测协议/安全/complete/语言/身份/缺口与合并；状态测无 key/全量零请求/部分定向补齐/失败保底/季集/串剧；配置测优先级/作用域/剥离/失败导入/重复字段/导出日志不泄漏；真实现有详情渲染 Before/After 同 fixture/视口/主题。独立审阅与复跑测试后更新 catalog。
