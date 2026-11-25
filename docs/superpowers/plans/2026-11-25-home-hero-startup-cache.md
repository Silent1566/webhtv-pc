# 首页启动推荐位缓存与稳定布局

**Goal:** 顶部从第一帧固定占位，上次成功的前3张高清宽图和文案从本地恢复，后台刷新不把轨道推上推下。
**Decisions:** 沿用实际解码≥1280×720横图规则；只缓存已验证图片本体，不缓存凭据/播放URL；缓存项展示绑定当前候选的原始身份，不能凭过期快照播放。配置、字段规则、headers和直播排除规则影响scope；错误/过期缓存降级为同高占位。
**Architecture:** 小型磁盘快照服务（最多3项、有文件哈希/体积/图片质量校验、原子index提交）；UI first-frame固定heroHeight，缓存图走本地FileImage，后台结果替换内容而非改变高度。已显示的缓存不在后台检查开始时清空；有效缓存失败才撤销。未知无缓存显示同高骨架。真正无配置/无任何内容可保留紧凑引导；有候选但全部不合格在本次会话也保留同高空态，避免反复塌陷。

## Task book
1. Cache module child (run1/3): only new services/home_hero_startup_cache.dart + test/home_hero_startup_cache_test.dart. Interface frozen by brief. Max3 files<=6MiB each<=18MiB total, SHA256, decodeHD, scope/restart/offline/corrupt/atomic tests.
2. Lead-Core: HomePage startup restore/placeholder/background update; PosterImage/HomeHero localfileprovider support; same rawcandidate identities/clicks; page tests for pending→cached/fresh/empty no vertical jump. No active child boundary edits.
3. Lead acceptance: coldstart/warmrestart/offline/corrupt/scope invalidation, rawprogress unchanged, first3cache, backgroundrefreshstable; before(user)/aftercaptures; read-only review and Puro tests/analyze/build.
