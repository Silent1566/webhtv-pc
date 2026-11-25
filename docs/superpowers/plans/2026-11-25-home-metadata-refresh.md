# 首页与详情元数据一致性修复计划

> For agentic workers: use executing-plans or subagent-driven-development; Lead-Core owns the coupled service/page seam and its acceptance.

**Goal:** 同一作品详情页已有元数据时，首页按相同逐字段规则展示并正确刷新背景。
**Architecture:** 将续播接入既有 HomeMetaService 的字段解析 worker，而非再写一套 TMDB/外部源/站源规则；页面按输入身份、配置、管线及详情返回事件失效，并阻止过期请求写回。
**Tech Stack:** Dart / Flutter / Puro webhtv / SQLite / HTTP test doubles.
**Spec:** 用户本轮截图与反馈；docs/phase11/design/02-home-feed-contract.md §12；详情 SourceMetaResolver (browse_pages.dart:3665)。

## Constraints / decisions
- 保留原始历史源、vodId、线路、分集、进度及日期，不因补图切站点。
- 首页首帧不等待网络；标题/海报/背景/简介/类型/年份按同一 MetaPipeline 解析，字段关闭时不复活旧图。
- 未绑定身份的匹配仍限 hero 续播预算6；保留2个worker、超时和迟到结果守卫；已有身份使用缓存而非再按标题搜索。
- 详情页的既有背景字段与素材兜底为验收标准，不新增第三方、不修改凭据、不开新的视觉方向。

## Task book
### 1. Tight feedback loop (Lead, run 1)
- [x] 在 home_resume_metadata_test.dart 补：身份回写后同一 HomePage 更新、已加载字段关闭、先前失败后再次匹配。
- [x] 运行真实 HomePage：3项红（背景 Actual null / 关闭后旧背景仍在），现有6项绿。
- [ ] 只读子代理核实详情使用的真实图片字段/缓存来源（home-detail-evidence run1/1）。

### 2. Common resolver / lifecycle (Lead-Core)
Files: services/home_art_service.dart; ui/home_page.dart; 必要时仅扩展 state/app_state.dart 的匹配通知；对应 home metadata 测试。
- [ ] 复用字段解析worker扩展续播适配，不伪装成 Following。
- [ ] 移除续播只取一次的缓存前提，以明确输入签名/详情返回事件刷新。
- [ ] 按当前管线应用结果，旧generation不得覆盖新配置。
- [ ] 加外部源优先级、禁用字段、跨源记录及详情返回的回归测试。

### 3. Lead acceptance
- [ ] 审查本轮增量 diff + 回归历史/推荐/追剧/关键词行为。
- [ ] 同一作品 Before/After（若只改逻辑可用原始用户Before + 合成数据After注明场景）。
- [ ] Puro webhtv analyzer、相关测试、Windows debug build。
- [ ] 同步旧文档，不声称全部通过直到实际验证。
