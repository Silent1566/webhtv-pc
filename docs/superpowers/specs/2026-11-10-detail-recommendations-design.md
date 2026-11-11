# 详情页非 AI 推荐设计

## 已确认范围
站源 DetailPage 与纯 TmdbDetailPage 最底部：猜你喜欢、个性推荐·TMDB、个性推荐·豆瓣。排除 AI、豆列和标签推荐。沿用 DESIGN.md 主题、现有海报卡片及导航。各行独立加载与行内去重；允许跨行重复。空行隐藏，单行网络失败不影响播放/其他区块。

## 行为
- 猜你喜欢：来源详情已有 recommendations/similar 优先，首见顺序、40 条上限；普通网络详情按安卓版权重排序并分页。
- TMDB 个性推荐：观看历史种子优先，再以当前作品填余位，排除当前/历史已看标题；历史缺少身份时走现有 TMDB 搜索匹配。
- 豆瓣：当前作品及观看历史种子，subject_suggest -> mobile related_items，空关联回退 suggest；保留豆瓣身份与评分，不能假造 TMDB 正数 ID。尽可能补 TMDB 元数据，匹配失败仍可按标题搜索站源。
- 分页每页 12；横向临近末尾或明确加载更多入口；历史变化刷新。右键/长按打开推荐说明与不感兴趣，90 天反馈持久化，所有行即时移除。
- 豆瓣无需凭据；7 天缓存、750ms 请求间隔、限流/反爬后 30 分钟冷却，失败退陈旧缓存。源内置详情可保留相关行；TMDB 未配置不请求 TMDB，不牵连豆瓣请求。
- TMDB 作品点击保留 PC 作品详情 -> 搜索站源的可达流程；豆瓣无匹配直接标题搜索，无虚假播放入口。

## 验收
真实数据逻辑单测（网络用可注入 HTTP）、两页组件测试、失败/无身份/历史变更/分页/反馈覆盖，相关既有回归通过；1280x800 同主题同固定作品 fixture 的 Before/After PNG 对比。

## 参考证据
Android root /home/maple/Workspace/webhtv/dev1/webhtv。TmdbDetailActivity.java:3154-3215,6737-6753；service/PersonalRecommendationService.java:416-437,627-669,1290-1308；TmdbSourceAdapter.java:226-231；TmdbHeaderView.java:542-617；RecommendationFeedbackStore.java:24-37。
