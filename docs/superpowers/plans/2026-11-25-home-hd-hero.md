# 首页高清宽图轮播筛选与补位

**Goal:** 顶部轮播只展示实际加载成功的高清横图；缺图项由后续作品补位，轨道不因图片资格被过滤。
**Settled:** 用户选择 hero-only；尺寸按当前1280px后景档要求实际解码宽≥1280、高≥720、宽>高。来源优先级沿用MetaPipeline；无合格素材不改历史/追剧身份，不伪造高清。
**Architecture:** 图像资格由独立ImageProvider探针验证（与PosterImage同headers/缓存键），页面按稳定候选池分批解析元数据/验证图片，成功才进入HomeHero；失败继续后补，池耗尽时折叠顶部，不留空背景。图片probe结果缓存、有限并发、超时清理及generation守卫。
**Tech stack:** Dart/Flutter，Puro webhtv，ImageProvider.decode真实像素，现有MetaPipeline与HomeWorkClaimer。

## Task book / boundaries
- Lead-Core：lib/ui/home_page.dart 候选编排/增量metadata/稳定显示；core/home_feed.dart 候选纯逻辑扩展与对应测试；home_art_service.dart 保留可尝试的背景候选（如需）。
- Image-probe child run1/3：仅新 core/home_hero_art.dart、ui/home_hero_image_probe.dart、test/home_hero_image_probe_test.dart。接口先冻结，禁止动page。
- Test adapters child（seam冻结后）：现有metadata测试注入可解码的高清夹具；规则/探针真实解码另有门禁，不用生产开关绕过。

## Implementation / acceptance
1. probe先测试：1920×1080可用；241×330竖图、1279×720、加载失败/超时不合格；成功/失败缓存不重复请求；headers进入NetworkImage；listener清理/迟到不写回。
2. 候选池先原hero再后续轨道，作品去重，先展示已通过项；最多12张，候选检查分批、最大池按轨道现有容量封顶，不卡首帧。
3. 宽图未过时不展示破图/文本hero；其轨道卡仍在。后续第7条/第13条等能入选，不被原hero截断。
4. 全部缺图/全部失败→hero折叠，已有轨道可见；无任何内容保留现有引导。
5. 新图地址/字段规则/详情返回失效；过期probe/metadata不能复活不合格候选；已验证图片用相同provider缓存避免二次下载。
6. Lead审查diff、真实像素widget测试、边界尺寸/HTTP错误/超过首批补位、Before(user)/After、analyze与Windows build。

## Review / evidence log
- probe run1/3 ready25tests; Lead new6candidate/backfilltests green.
- Following时间戳必须进资格签名，否则旧_candidateMeta遮新值：已修。
- batch领取数不得超过剩余hero槽，否则满12时提前标记的第13项永失补位机会：已修。
- 热门轨道不得按已合格hero过滤（hero-only）：已修。
- 保留真正零内容/未配置页面的220px紧凑引导；有轨道却无HD图时hero0高。
