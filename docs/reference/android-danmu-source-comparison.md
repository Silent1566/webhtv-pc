# Android `/proxy` 与弹幕选源对比笔记

源码基线：Android `13050a007ba71c3e6be94a895dc250458778759c`。引用缩写：`main/`、`mobile/`、`leanback/` 分别对应 `app/src/{main,mobile,leanback}/java/com/fongmi/android/tv/`；`catvod/` 对应 `catvod/src/main/java/com/github/catvod/`；`media3/` 对应仓库 `third_party/maven/androidx/media3/media3-ui-danmaku/1.11.0-alpha01-fongmi/media3-ui-danmaku-1.11.0-alpha01-fongmi-sources.jar` 内的 `androidx/media3/ui/danmaku/`。该版本是构建依赖（`app/build.gradle:175`、`gradle/libs.versions.toml:50,135,167`、`settings.gradle:18`）；未核对 emulator-5554 安装包与此提交是否一致。

**已观察（Lead 提供）**：相同参数的独立 HTTP 请求在 Android 与 PC 真实 AppRJ jar 上均返回 `200 application/xml`、45 字节 `<?xml version="1.0" encoding="UTF-8"?><i></i>`。下面是源码推导，不把这次探测当作播放会话实际请求或来源相同的证明。

## 1. `/proxy?do=danmu` 由谁接收

- **无 `siteKey` 键：走 jar 的全局路由，不调用当前站源实例。** Android HTTP handler 把参数、headers 和 files 合并，交给单例 `BaseLoader`；只有 `do=js/py` 分给对应 loader，其余（包括 `danmu`）交给 `JarLoader`（`main/server/process/Proxy.java:30-46`、`main/api/loader/BaseLoader.java:42-44,176-185`）。后者按 jar 键缓存插件类 `com.github.catvod.spider.Proxy.proxy(Map)`，用 `invoke(null, params)` 调用静态方法：先试 `recent`，缺方法、抛异常或返回 `null` 才试其它已注册 jar；第一个非 `null` 即停止，不判状态、MIME 或正文（`main/api/loader/JarLoader.java:52-57,172-182,321-338`）。因此即使某个 jar 返回合法空 XML，也不会继续找其它 jar。
- **有 `siteKey` 键：调用站源实例 `Spider.proxy(params)`，不是上述静态路由。** 非空 `configKey` 用目录配置和命名空间取实例，找不到会抛错而不回激活配置；否则 `getSpider(siteKey)` 在当前 VOD、再在 Live 查找。基类 `Spider.proxy` 默认 `null`；插件有无覆盖及内部是否转调静态入口，宿主不能替它回答（`main/api/loader/BaseLoader.java:146-151,176-199`、`main/bean/Site.java:499-509`、`catvod/crawler/Spider.java:73-75`）。
- type 3 播放结果来自 `site.recent().spider().playerContent(...)`。`recent` 是共享 loader 状态：初始化 VOD 配置 jar 可写入它，调用 CSP 站源的 `recent()` 也会把 jar 字符串的 MD5 写入；它不是站源实例 ID，也不是最终命中 jar 的回执（`main/api/SiteApi.java:292-312`、`main/api/config/VodConfig.java:535-538`、`main/bean/Site.java:499-509`、`main/api/loader/BaseLoader.java:170-174,202-207`、`main/api/loader/JarLoader.java:85-87,321-329`）。
- `catvod/Proxy.java:7-19` 管服务器端口和 URL，不是插件的 `com.github.catvod.spider.Proxy`。主服务尝试端口 `9978..9998`、启动成功才设置；`proxy://` 经转换使用当前服务地址，现成的 HTTP URL 不经过这条换端口分支。因此只凭端口、`do=danmu` 或 XML 不能判当前站源（`main/server/Server.java:48-54,66-79`、`main/utils/UrlUtil.java:46-52`、`main/bean/Danmaku.java:194-196`）。

## 2. 站源与配置 API：先看候选，再看实际加载

1. 站源 `Result.danmaku` 在 `danmaku_load` 开启时进入 `PlaySpec`；应用播放项时 `PlayerManager` 取列表第一个，不遍历试下一条。空 URL 才是 `Danmaku.isEmpty()`；支持的静态 URL 会先赋给 `currentDanmakuUrl`，再交控制器下载（`main/bean/Result.java:65-67,316-318`、`main/player/engine/PlaySpec.java:44-63`、`main/player/PlayerManager.java:6305-6309,7007-7009,7019-7065`、`main/bean/Danmaku.java:190-196`）。
2. 配置 API 自动搜不检查站源有无条目：`canAutoSearch` 只要求 `danmaku_load`、`danmaku_auto`、有效 API。API 地址优先级为用户填写 `danmaku_api_url` → 激活订阅顶层 `danmaku` → 仅当前为猫源 bundle 时取其运行时地址；先选非空再验证 HTTP(S)，不会因前一档非空但无效而改试下一档（`main/api/DanmakuApi.java:32-40`、`main/setting/DanmakuSetting.java:16-45,309-360`）。
3. 自动搜先按 `siteKey + vodId + 规范化集名` 取手动匹配缓存，命中就返回而不发搜索请求；否则依次尝试含手动关键词的候选标题、清洗标题、AI 兜底标题。请求失败、解析异常或无搜索候选才换标题；第一个非空结果列表只取首项，不等最终 XML 下载或渲染（`main/api/DanmakuApi.java:103-126,135-173`、`main/bean/DanmakuMatchCache.java:35-44,96-98,117-120`）。
4. API/缓存回调命中后，若“站源优先”且站源列表非空，则 `addDanmaku`，只有当前 URL 为 `null` 才实际加载该候选；否则 `setDanmaku` 主动选择回调项。Mobile、Leanback、TMDB 内嵌的选择条件一致（`mobile/ui/activity/VideoActivity.java:3268-3289`、`leanback/ui/activity/VideoActivity.java:3453-3476`、`main/ui/activity/TmdbDetailActivity.java:8017-8036`、`main/player/PlayerManager.java:7249-7253`）。这是回调时的 URL 状态判断，不是按弹幕条数兜底；`PlaySpec.addDanmaku` 甚至会同步列表 `selected` 标志，因此列表勾选不能单独证明控制器请求了该 URL（`main/player/engine/PlaySpec.java:201-211`）。

## 3. 45 字节正文：成功加载 0 条，不触发换源

- **源码推导**：若播放控制器实际收到上述 loopback HTTP 响应，`DanmakuController` 的 HTTP 数据源读取正文，首个 Bili parser 去掉 XML 声明并识别 `<i>`；只从 `<d>` 节点产出条目。这个正文没有 `<d>`，返回空列表，控制器发 `onLoadCompleted(uri, 0)`，不是 `onLoadError`（`media3/DanmakuController.java:144-156,329-364,829-854`、`media3/parser/ParserUtil.java:38-64`、`media3/parser/BiliParser.java:34-66`）。HTTP handler 本身只校验响应形状，不解析弹幕（`main/server/process/Proxy.java:50-77`）。
- `PlayerManager` 的完成/错误回调只记录结果并结算加载状态，不清空 `currentDanmakuUrl`、不重搜配置 API、不加载站源下一条（`main/player/PlayerManager.java:1350-1361,7075-7087`）。所以在站源优先且站源 URL 已被设置的情况下，空 XML **不会**把控制器切到已找到的 API 候选。未启用站源优先时，API 独立搜索命中仍可能替换站源；不是空 XML 导致。

## 4. Lead 最小运行时取证

1. **锁定同次播放**：Android 记录安装版本/构建、激活配置 ID 或脱敏指纹、`siteKey`、线路与集、type 3 `player` 日志里的 `Result.danmaku` 候选数和 URL 指纹（`main/api/SiteApi.java:292-305`）。对照同会话 PC 的对应信息。读取默认 SharedPreferences 的 `danmaku_load`、`danmaku_auto`、`danmaku_spider_first`、`danmaku_show`、`danmaku_api_url`（URL 只留脱敏摘要）与当集 `danmaku_match_cache` 命中，区别配置 API 请求和缓存。订阅顶层 `danmaku` 应看当前解析结果：`Config.danmaku` 是 Room `@Ignore`，并非独立 DB 列（`catvod/utils/Prefers.java:11-24`、`main/setting/DanmakuSetting.java:16-53`、`main/setting/Setting.java:1042-1047`、`main/ui/dialog/DanmakuSearchDialog.java:353-368`、`main/api/config/VodConfig.java:249-260`、`main/bean/Config.java:58-63`）。这些字段解释选源倾向，不代表实际加载。
2. **记录控制器实际消费的 URL 与结果**：同一时间线的 `danmaku load/reload` 或 `select live source`，加 `load completed count=N` / `load error`；若走 API，有 `search`/标题日志时关联它，不能把无 `search` 日志当作无配置候选（缓存或 URL 模板分支可不打该日志）。只保留类型、脱敏 host/path、端口、参数键和敏感值指纹；不外传原始 URL、查询值、headers 或 token（`main/player/PlayerManager.java:7047-7065,7220-7227`、`main/player/danmaku/DanmakuUrlPolicy.java:47-65`、`main/api/DanmakuApi.java:42-57,103-126`）。
3. **若实际 URL 是 `/proxy`，关联同一请求的调度与结果**：比对 Android `proxy request/response` 的 `do`、`siteKey/configKey` 是否存在、状态及 MIME，再测响应字节数/摘要。显式配置分支有 `catalog proxy`；全局 jar 分支可用 `jar-loader recent`、`proxy method ready`、`spider init ... site/api/jar/class` 缩小候选，但现有 `JarLoader.proxy/tryOthers` 无逐请求命中日志。若不能唯一排除其它候选，需另有插件侧调用证据才能证明最终 handler/jar 身份；`recent`、相同 HTTP 元组及设置项均不够。日志受 debug/tag 开关限制（`main/server/process/Proxy.java:36-42,50-76`、`main/api/loader/BaseLoader.java:194-199`、`main/api/loader/JarLoader.java:85-87,172-182,232-249,321-338`、`catvod/crawler/SpiderDebug.java:14-16,55-61`）。

## 5. 5554 与 PC 的实测对照

- Android 5.6.0（versionCode 560）的播放界面为《逐玉》第 1 集。弹幕面板当时勾选本机 `/proxy`，读取到的查询恰为 `do=danmu&name=逐玉&episode=1&season=1`，无 `siteKey`。勾选不等于实际加载成功，也不能凭此确定命中的 jar。设备安装包与上面源码提交的对应关系未核验。
- 重放 Android 面板中的地址：HTTP 200、`application/xml; charset=utf-8`、45 字节、0 条，约 9.5 秒。独立启动 PC JVM sidecar，使用已安装的 `AppRJ` 和正常播放会话控制，重放相同查询：同状态、MIME、长度、条数，约 16.5 秒。两次正文 SHA-256 都为 `dc22626a7738931b0f4f56c2f207c0075831fe8662b9c261a68ae458143b1ae2`。这些耗时是单次观察，不是稳定性能对比；临时 ADB 端口转发已移除。
- PC JVM 的响应匹配 [AppRJ 工件的固定空回退](apprj-danmu-artifact-findings.md)，不是不支持该动作。仍无法从回退正文判定上游是未匹配、响应失败还是其它异常；也不能用相同正文证明 Android 全局分发命中同一个 jar。
- 45 字节正文复现 PC 原先把同一行的 XML 声明和根元素一起跳过，误报 `danmakuInvalid`。PC 现仅在关闭声明后还有标签时把该行认作 XML，随后将 0 条归为 `danmakuEmpty`，并沿用已有的弹幕库兜底（`lib/core/danmaku.dart`、`test/phase3_danmaku_test.dart`）。没有延长 15 秒请求超时、扩大代理权限或修改 Android 代码。
