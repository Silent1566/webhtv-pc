# Phase 3 计划(直播 · 字幕 · Windows)

- 状态:进行中(直播核心闭环 + 播放诊断 + **外挂字幕** + **弹幕** + **直播弹幕** + **解析器运行时** + **EPG** + **JS Spider 运行时** + **猫源**已完成,见 §3.1)
- 日期:2026-10-01
- 对应设计文档章节:§13(直播功能设计)、§10.3(字幕轨选择/外挂字幕)、§21 Phase 3、§17.2、§23、§9(Spider 运行时设计与猫源)
- 上游:`docs/phase2/README.md`(MVP-B 已完成,6 项门禁全绿)

## 0. 本阶段目标

把直播从「配置里 `lives` 字段的原始透传」升级为可用的**直播页 + 播放**闭环,
把字幕从「完全缺失」升级为**外挂字幕可加载、可选轨、可开关**,并建立可复现的
M3U/TXT/JSON 解析与播放验收。设计文档相关验收原文:

§13.3(直播):

- M3U 可解析(分组与属性解析正确:分组、channel、多线路、Header)。
- TXT 可解析(分组层级正确)。
- JSON 可解析(模型转换正确)。
- 频道支持多线路。
- 播放失败可切线路。
- EPG 可加载、刷新、显示当前节目(§13.3)。
- 关闭应用后释放播放资源。

§10.3(播放器,完整版必须项):

- 字幕轨选择。
- 外挂字幕。

§21 Phase 3 验收:

- 字幕/弹幕可开启和关闭。
- 播放诊断能输出引擎、格式、网络和错误。

> 本阶段已实现**字幕(外挂字幕 + 字幕轨选择与开关)**、**弹幕(可开启和关闭)**与
> **直播弹幕**(`ws://`/`wss://` 实时弹幕,§13.1)、**解析器运行时**(§12 JSON 类
> `type=1/2/3`)、**EPG**(清单 `url-tvg`/源 `epg` → XMLTV 抓取、解析、缓存与刷新,
> 频道当前节目与节目单展示,§13.1、§13.3)。回看、直播代理的单独 HLS 会话管理
> 属于后续增强(§13.1 完整版能力),不在本阶段验收范围。Web 嗅探(`type=0`)与
> Super(`type=4`)需浏览器内核,PC 端**明确不支持**(见 §5.8)。

## 1. 现状盘点

### 1.1 缺口(G1 直播完全缺失)

| 缺口 | 设计文档依据 | 现状 |
| --- | --- | --- |
| **无直播模型** | §13.2 | `AppConfig.lives` 只是 `List<Object?>` 原始透传;无 `LiveSource`/`LiveGroup`/`LiveChannel`/`LivePlaylist` |
| **无直播解析** | §13.3 | 无 M3U(`#EXTINF`/`group-title`/`tvg-*`/`#EXTVLCOPT`/`#EXTHTTP`)、TXT(`分组,#genre#` + `名称,地址`)、JSON(`groups[].channel[]`)解析 |
| **无直播页** | §13.1、§17.2 | 侧栏无直播入口;无分组/频道/线路展示 |
| **无直播播放** | §13.3 多线路 | 无「频道直链播放」与「失败自动切线路」路径 |
| **无字幕模型** | §10.3 | `SiteResult` 无 `subs`;播放结果里的外挂字幕被整段丢弃 |
| **无字幕加载** | §10.3 | 无字幕拉取、编码兜底(GBK 字幕常见)、格式推断 |
| **无字幕轨 UI** | §10.3、§17.3 | 播放器无字幕菜单;无法选择轨、无法开关 |
| **无失败隔离** | §10.4 | 字幕失败会淹没在通用异常里,缺少「不影响播放」的语义 |

### 1.2 已具备(直播可复用的基础)

| 能力 | 位置 |
| --- | --- |
| 播放器(真实 video 画面/快捷键/进度恢复) | `lib/ui/player_page.dart` |
| 本地代理与 Header 合并策略 | `lib/core/proxy_policy.dart`、`lib/services/proxy_server.dart` |
| 编码探测(UTF-8 → GBK 兜底) | `lib/core/text_codec.dart#decodeConfigText` |
| 错误对象化(`AppError` + kind) | `lib/core/app_error.dart` |
| fixture 服务(可扩展新路由) | `tools/fixture_server/server.py` |
| media-kit 字幕 API(`setSubtitleTrack`/`stream.tracks`/`stream.track`) | 引擎侧已具备,可承载字幕轨选择与开关 |

## 2. 实施顺序

| # | 任务 | 产出 | 验收 |
| --- | --- | --- | --- |
| 直播 1 | 直播数据模型(`LiveSource`/`LiveChannel`/`LiveGroup`/`LivePlaylist`) | `lib/core/protocol.dart` + `lib/core/config_parser.dart`;`lives` 解析为 `List<LiveSource>` | 模型解析/序列化往返;未知字段保留;缺 name 跳过并记诊断 |
| 直播 2 | 直播清单解析(M3U/TXT/JSON) | `lib/core/live_playlist.dart`;fixture `packages/test-fixtures/live/{live.m3u,live.txt,live.json}` | §13.3 三格式解析正确;同名频道合并线路;不可播放地址丢弃;元频道行跳过 |
| 直播 3 | 直播源加载服务(HTTP/本地 + 编码 + 缓存) | `lib/services/live_service.dart` | HTTP/本地加载;GBK 兜底;缓存 TTL/失效;非 2xx→`liveHttp` 不空列表化 |
| 直播 4 | 直播页 UI(源 → 分组 → 频道 → 线路) | `lib/ui/live_page.dart` + 侧栏「直播」入口 | 空态说明;多线路展示;单源失败不阻塞其他源 |
| 直播 5 | 直播播放接入 + 失败切线路 | `lib/ui/player_page.dart` `directUrl` + `_fallbackLiveLine` | 频道直链播放;线路失败自动按顺序切换 |
| 直播 6 | 测试与验收证据 | `test/phase3_*.dart` + `integration_test/live_flow_test.dart` + `tools/phase3/` | 门禁全绿;证据写入 `docs/phase3/evidence/` |
| 字幕 1 | 字幕模型(`SubtitleInfo`)与 `SiteResult.subs` | `lib/core/protocol.dart` + `lib/core/http_api.dart`;`PlaybackDecision.subs` | `subs` 解析/往返;缺 url 丢弃;`flag` 位语义;决策透传 |
| 字幕 2 | 字幕纯逻辑(格式/候选/选择) | `lib/core/subtitle.dart` | 格式推断;外挂+内嵌候选;菜单顺序;默认/强制选择;切集沿用 |
| 字幕 3 | 字幕加载服务(HTTP/本地 + 编码 + 上限) | `lib/services/subtitle_service.dart` | 带 Header 拉取;GBK 兜底;大小上限;错误归一化为 `subtitle*` |
| 字幕 4 | 播放器接入(轨选择/开关/临时文件) | `lib/ui/player_controller.dart` | 默认自动启用;关闭/重开;`.srt` 扩展名落盘;临时文件清理 |
| 字幕 5 | 播放器 UI(字幕菜单 + 失败提示不影响播放) | `lib/ui/player_page.dart` + `PlaybackRequest.subtitles` | 菜单可选;失败 SnackBar 提示且视频照常播 |
| 弹幕 1 | 弹幕模型与源解析(`DanmakuSource` + `SiteResult.danmaku`) | `lib/core/protocol.dart` + `lib/core/danmaku.dart` + `lib/core/http_api.dart` | 字符串/对象/信封/内嵌 JSON 四态兼容;按 url 去重;防深嵌套;`ws/wss` 判定为直播 |
| 弹幕 2 | 弹幕解析(XML/文本) | `lib/core/danmaku.dart` | 逐条对齐 media3 `BiliParser`/`TxtParser`:类型 1/4/5/6、Bili mode 映射、行正则、参数位置、字号 12/18 档 |
| 弹幕 3 | 弹幕加载服务(HTTP/本地 + 编码 + 上限 + 缓存) | `lib/services/danmaku_service.dart` | 带 Header 拉取;GBK 兜底;大小上限;缓存 TTL;错误归一化为 `danmaku*` |
| 弹幕 4 | 渲染层(滚动/顶部/底部轨道 + 开关/透明度/字号) | `lib/ui/danmaku_overlay.dart` | 轨道在活动窗口内独占防重叠;关闭时不绘制任何内容 |
| 弹幕 5 | 播放器接入(开关 + 设置菜单 + 失败隔离) | `lib/ui/player_page.dart` + `PlaybackRequest.danmaku` | AppBar 一键开关;设置面板;失败 SnackBar 提示且视频照常播 |
| 直播弹幕 1 | 帧解析与重连策略(纯逻辑) | `lib/core/live_danmaku.dart` | 对齐 Android `LiveDanmakuParser`/`RetryPolicy`:chat/superchat/online、文本规范化、`#RRGGBB` 颜色、64KiB/120 码点上限、250ms~30s 指数退避 |
| 直播弹幕 2 | WebSocket 会话(连接/重连/生命周期) | `lib/services/live_danmaku_session.dart` | 代次防串帧;指数退避重连;待机停止;释放时关连接;失败不阻断 |
| 直播弹幕 3 | 播放器接入(实时上屏 + 在线人数 + 状态) | `lib/ui/player_page.dart` + `DanmakuOverlay.liveItems` | 收到即上屏;online 帧更新人数;控制栏连接状态;失败只提示 |
| 解析器 1 | 解析器选择与类型策略(纯逻辑) | `lib/core/parse_runtime.dart` | type 0/1/2/3/4 映射;flag 匹配;`preferName`;不支持类型的明确错误 |
| 解析器 2 | JSON 解析运行时(type=1/2/3) | `lib/services/parse_service.dart` | 对齐 Android `ParseJob`:`url+webUrl`、`{url,data.url}`、完整 Result、响应头注入、超时、上限、错误归一化 |
| 解析器 3 | 播放链路接入(parse=1/jx=1 → 解析器) | `lib/core/playback.dart` + `lib/services/site_service.dart` | `needParser` 决策;解析后校验媒体类型;失败可回退换源 |
| EPG 1 | XMLTV 解析与节目模型(纯逻辑) | `lib/core/epg.dart` | `<tv>`/`<channel>`/`<programme>` 解析;频道三级匹配(epgId/tvgName/name→display-name);时间戳 4 种形态;当前/下一个/进度;异常条目丢弃并计数 |
| EPG 2 | EPG 加载服务(HTTP/本地 + gzip + 编码 + 缓存) | `lib/services/epg_service.dart` | `.xml.gz` 魔数解压;GBK 兜底;缓存当天 + 6h TTL;`forceRefresh`;错误归一化为 `epg*` |
| EPG 3 | 直播页接入(当前节目 + 节目单 + 刷新) | `lib/ui/live_page.dart` + `AppState.epgService` | 列表显示当前/下一节目;详情「节目单/线路」页签;刷新按钮;EPG 失败只提示不影响直播 |
| JS 1 | Node sidecar 传输层(`webhtv-ipc-v1` 第三份实现) | `sidecars/spider-host-js/host.js` | 帧编解码/握手(initialize)/取消/capability 校验/错误信封/并发控制;stdout 只走协议帧 |
| JS 2 | TVBox 脚本沙箱(`tvbox-js-v1`) | `sidecars/spider-host-js/sandbox_worker.js` | `node:vm` + worker 线程;同步 `req` 阻塞沙箱、宿主主线程做 HTTP;`homeContent`/`categoryContent`/`detailContent`/`searchContent`/`playerContent` 桥接;未实现全局明确报错 |
| JS 3 | 宿主接线(`runtime=node` 命令解析与站点判定) | `lib/services/spider_registry.dart` + `lib/services/spider_router.dart` + `lib/state/app_state.dart` | `node host.js --entry … --manifest …`;Windows 用 `node.exe`;JS 宿主路径可显式覆盖或按发行包布局推导;`spider-local:` + `runtime=node` 判为可用 |
| JS 4 | JS fixture、门禁测试与集成测试 | `sidecars/spider-host-js/` + `test/phase3_js_spider_test.dart` + `integration_test/js_spider_flow_test.dart` | 真实 Node 子进程 + 真实帧握手 + 真实 fixture 浏览;启动失败隔离;证据写入 `docs/phase3/evidence/` |
| 猫源 1 | 猫源地址识别与配置整形 | `lib/core/cat_source.dart` | `.../index.js.md5`、`.../index.js`、本地包目录/zip 判为 bundle;裸站点数组 / `{video:{sites}}` → 标准 `{sites}`;相对 `api` 补基址;错误信封明确报错;缺 `searchable` 补 `1` |
| 猫源 2 | bundle 下载、校验与本地缓存 | `lib/services/cat_bundle.dart` | `.md5` 先取校验值(32 字节,短超时)再决定是否下载 1.6 MB bundle;本地目录/zip 安装;内容指纹与缓存标记;缺 `index.config.js` 报可定位错误 |
| 猫源 3 | Node 运行时(boot.js 注入 + 端口认准 + 进程树回收) | `lib/services/cat_runtime.dart` | 注入 `catServerFactory`/`catDartServerPort` 后 `require(bundle).start(config)`;轮询候选端口用配置形状(`/config` 非 401/欢迎页)认准猫源服务;换源与退出终止进程树 |
| 猫源 4 | 导入门面接线与重启重拉 | `lib/services/cat_runtime.dart#CatImportPipeline` + `lib/core/config_loader.dart` + `lib/state/app_state.dart` | 猫源地址先跑 bundle 取 `/config` 再进同一套解析;`origin` 保留原始猫源地址,重启/换源时按原地址重拉新端口;Node 缺失时如实报错不静默跳过 |
| 猫源 5 | 门禁测试与真实 bundle 端到端 | `test/cat_source_test.dart` + `test/cat_bundle_test.dart` + `integration_test/cat_source_flow_test.dart` + `tools/phase3/verify_cat_source.py` | 真实 bundle + 真实 Node 子进程:导入 → 站点 → home/search/detail/play 全链路;证据写入 `docs/phase3/evidence/` |

## 3. 验收门禁(本阶段完成判据)

| 门禁 | 判据 | 覆盖位置 | 关键断言 |
| --- | --- | --- | --- |
| 直播模型 | `LiveSource`/`LiveChannel`/`LiveGroup`/`LivePlaylist` 解析与往返 | `test/phase3_live_test.dart`「直播数据模型（§13.2）」 | 未知字段保留、往返不失真、缺 name 记诊断 |
| M3U 解析 | `#EXTINF`/`group-title`/`tvg-*`/`tvg-chno`/`#EXTVLCOPT`/`#EXTHTTP` | `test/phase3_live_test.dart`「直播解析：格式识别与 M3U」 | 分组顺序、频道属性、`#EXTVLCOPT` Header 注入、元频道行跳过、未分组归拢 |
| TXT 解析 | `分组,#genre#` + `名称,地址1#地址2` | `test/phase3_live_test.dart`「直播解析：TXT」 | 分组层级、多线路 `#` 拆分、`\|header参数` |
| JSON 解析 | `groups[].channel[]` + `{code,data}` 信封 | `test/phase3_live_test.dart`「直播解析：JSON」 | 频道号生成、非 URL 丢弃、信封形态 |
| 错误路径 | §8.4 不许把错误页当成功 | `test/phase3_live_test.dart`「错误路径」 | 申明 JSON 内容非法→`liveInvalid`,不空列表化 |
| 加载服务 | HTTP/本地/编码/缓存/错误 | `test/phase3_live_service_test.dart` | GBK 兜底中文不乱码;缓存命中不重复请求;`liveHttp`/`liveUnsupported`;单源失败不阻塞其他源 |
| 直播页 UI | 渲染+交互+单源隔离 | `test/phase3_live_page_test.dart` | 空态;源/分组/频道渲染;多线路展示;失败源错误态+重试;其他源不受影响 |
| 直播播放 | 直链 + 多线路 + 失败切线路 + 频道 Header | `test/phase3_live_page_test.dart` `requestForChannel` + 纯函数 | `directUrl=true`、线路映射、越界安全、频道级 Header 注入直链 |
| 播放诊断 | 引擎/格式/网络/错误 + 阶段耗时（§23） | `test/phase3_diagnostics_test.dart` | 格式识别、地址脱敏、错误分类与提示、敏感 Header 脱敏、JSON 往返 |
| 直播集成 | 真实窗口 + 真实播放器 + 直播直链出画 + 诊断落定 | `integration_test/live_flow_test.dart` (-d windows) | 直播页渲染;失效源隔离;带 Header 频道真实出画;播放后诊断含引擎/格式/主机/结果 |
| 字幕模型 | `SubtitleInfo` 字段/往返/`flag` 位语义;决策透传 | `test/phase3_subtitle_test.dart`「字幕模型」「播放决策携带字幕」 | 字段与 WebHTV `Sub` 对齐;`flag==0` 视为默认;缺 url 丢弃;代理场景仍能拿到代理前 Header |
| 字幕解析 | 格式推断/MIME/候选构建/菜单顺序/默认选择/切集沿用 | `test/phase3_subtitle_test.dart`「字幕格式推断」「字幕候选与选择」 | 扩展名优先且忽略 query;丢弃并上报缺地址/不支持格式;外挂→内嵌→关闭;default→forced→不自动开 |
| 字幕加载 | HTTP(带 Header)/本地/GBK/上限/错误分类 | `test/phase3_subtitle_test.dart`「SubtitleService 加载」 | 缺 Header 的 `/media/` → 403 → `subtitleHttp`;GBK 中文不乱码;`subtitleTooLarge`/`subtitleEmpty`/`subtitleUnsupported`/`subtitleNetwork` |
| 字幕失败隔离 | §10.4 字幕失败不得升级为播放失败 | `test/phase3_subtitle_test.dart`「字幕失败隔离」 | `isSubtitleError` 只认 `subtitle*`;提示文案含「不影响视频播放」 |
| 字幕集成 | 真实窗口 + 真实播放器 + 真实外挂字幕 | `integration_test/subtitle_flow_test.dart` (-d windows) | 默认启用;关闭(`id=no`);重新开启;失败时视频照常出画 |
| 弹幕模型 | 源解析四态兼容/去重/防深嵌套/源类型判定 | `test/phase3_danmaku_test.dart`「弹幕源模型」 | 字符串/对象/信封/内嵌 JSON;缺 url 丢弃;`ws/wss`→live;畸形输入不抛异常 |
| 弹幕解析 | XML 与文本逐条对齐 media3 | `test/phase3_danmaku_test.dart`「Bilibili XML 解析」「行式文本解析」 | 类型映射 1/2/3→滚动・4→底部・5→顶部・6→反向・7 丢弃;字号 <=18→12 / >=36→18;`&amp;` 实体还原 |
| 弹幕加载 | HTTP(带 Header)/本地/GBK/上限/缓存/错误 | `test/phase3_danmaku_test.dart`「DanmakuService 加载」 | 缺 Header → 403 → `danmakuHttp`;GBK 中文不乱码;缓存命中不重复请求;`ws/wss`→`danmakuUnsupported` |
| 弹幕布局 | 轨道分配/可见窗口/防重叠/关闭为空 | `test/phase3_danmaku_test.dart`「弹幕轨道布局」 | 同刻多条分不同轨道;关闭 → 空集合;CJK 宽于 ASCII |
| 弹幕渲染 | widget 层绘制/开关/类型过滤/样式夹紧 | `test/phase3_danmaku_overlay_test.dart` | 开启渲染 CustomPaint;关闭零绘制;滚动/顶部/底部可分别隐藏 |
| 弹幕失败隔离 | §10.4 同语义:弹幕失败不得升级为播放失败 | `test/phase3_danmaku_test.dart`「弹幕失败隔离」 | `isDanmakuError` 只认 `danmaku*`;提示文案含「不影响视频播放」 |
| 弹幕集成 | 真实窗口 + 真实播放器 + 真实弹幕渲染 | `integration_test/danmaku_flow_test.dart` (-d windows) | 加载→渲染→关闭→重开;失败时视频照常出画 |
| 解析器选择 | type 映射/flag 匹配/默认选择/不支持类型报错 | `test/phase3_parser_test.dart`「解析器类型映射」「解析器选择」 | 仅 type=1/2/3 支持;flag 命中优先;noneConfigured/unsupportedOnly/selectedUnsupported |
| 解析器执行 | type=1/2/3 响应解析/响应头/错误/超时/上限 | `test/phase3_parser_test.dart`「JSON 解析执行」 | `{url}`/`{data.url}`/完整 Result;parseHttp/parseInvalid/parseEmpty/parseNetwork;超时可定位 |
| 解析器端到端 | 配置 parses → resolvePlayback → 真实调解析器 | `test/config_and_site_test.dart`「§12 全链路」+ `integration_test/parser_flow_test.dart` | 解析出可播放地址并真实出画;失败可定位且可回退 |
| 直播弹幕解析 | 帧解析/文本规范化/颜色/重连退避逐条对齐 Android | `test/phase3_live_danmaku_test.dart` | chat/superchat/online/非法帧四类;控制字符丢弃/空白折叠/码点截断;`#RRGGBB` 补 alpha;退避有界且随尝试增长 |
| 直播弹幕集成 | 真实窗口 + 真实播放器 + 真实 WS 连接 | `integration_test/live_danmaku_flow_test.dart` (-d windows) | 收到 chat/superchat 上屏;online 更新在线;非法帧丢弃;关闭弹幕;连接失败不影响播放 |
| EPG 解析 | XMLTV 时间/频道三级匹配/当前节目/边界/异常条目 | `test/phase3_epg_test.dart`「XMLTV 时间解析」「XMLTV 解析与频道匹配」「当前节目判定」 | 4 种时间形态;`epgId`→`tvgName`→`name`→`display-name`;未匹配丢弃计数;`<tv>` 外根元素→`epgInvalid`;左闭右开边界 |
| EPG 加载 | HTTP/本地/gzip/GBK/缓存 TTL/刷新/错误分类 | `test/phase3_epg_test.dart`「EpgService 加载与缓存」 | `.xml.gz` 魔数解压;GBK 中文不乱码;缓存当天 + 6h;`forceRefresh` 绕过缓存;404→`epgHttp`、坏内容→`epgInvalid`、空→`epgEmpty`、超限→`epgDecode`;清理递归删 `epg/` 子目录 |
| EPG 展示 | 直播页当前节目 + 节目单页签 + 刷新 + 失败隔离 | `test/phase3_live_page_test.dart`「EPG…」 | 清单 `url-tvg` 自动拉取;列表显示当前节目（不伪造）;详情「节目单/线路」页签;刷新重拉;`epgInvalid`/`epgHttp` 只提示且频道与播放入口照常 |
| EPG 集成 | 真实窗口 + 真实 HTTP + 真实 XMLTV | `integration_test/epg_flow_test.dart` (-d windows) | 真实拉取 EPG 并显示当前节目;点击频道展示节目单;刷新;坏 EPG 地址不影响直播频道 |
| JS Spider 宿主 | `runtime=node` 命令解析（node/node.exe、JS 宿主缺失不静默） | `test/phase3_js_spider_test.dart`「resolve…」 | 解析出 `node host.js --entry … --manifest …`;Windows 严格 `node.exe`;JS 宿主缺失→null;`jsHostPath` 缺省时按发行包布局推导 |
| JS Spider 契约 | 真实 Node 子进程 + `webhtv-ipc-v1` 帧/握手/capability/错误信封 | `test/phase3_js_spider_test.dart`「Node sidecar 可用」「home…」「五方法…」「站源异常…」 | ABI major 兼容;capabilities 含 home/play;未声明 capability→`SPIDER_UNSUPPORTED`;home/category/detail/search/play 返回结构化 Result;站源异常→`SPIDER_PARSE_ERROR`;启动失败隔离(主程序存活) |
| JS Spider 集成 | 真实窗口 + 真实 Node 侧车 + 真实 fixture 服务 | `integration_test/js_spider_flow_test.dart` (-d windows) | `spider-local:` + `runtime=node` 真实启动握手;home/category/detail/search 返回真实数据;入口缺失→可用性明确原因;失败站点隔离且主程序存活 |
| 猫源识别与整形 | bundle 地址识别、配置整形、基址与 `searchable` 默认 | `test/cat_source_test.dart` | URL 形态(`.js.md5`/`index.js`)、本地包目录/zip 均判为 bundle 而普通配置不误判;裸站点数组/`{video:{sites}}`→`{sites}`;相对 `api` 补基址且绝对地址不改写;错误信封明确报错;缺 `searchable` 补 `1` 而显式 `0` 保留 |
| 猫源 bundle 缓存 | 地址推导/本地目录/zip/校验不一致/稳定指纹 | `test/cat_bundle_test.dart` | `bundleUrl` 去 `.md5`;`md5Url` 不重复补;`configUrl` 指向同目录;内容指纹稳定;缺 `index.config.js` 明确报错;zip 内 `index.js.md5` 不符时报错 |
| 猫源真实端到端 | 真实 bundle + 真实 Node 子进程 + 真实站点浏览 | `tools/phase3/verify_cat_source.py` + `integration_test/cat_source_flow_test.dart` (-d windows) | 本地包安装→起 Node→认准 `/config`→126 站点全可用;`init`/`home`/`search`/`detail`/`play` 全链路 HTTP 200 且返回真实数据;证据写入 `docs/phase3/evidence/` |
| 无回归 | 全量单测 + 静态检查 | `flutter test` + `dart analyze` | **441** 个用例全绿;analyze 无问题 |

> 门禁以 `flutter test` + `flutter test integration_test/*.dart -d windows`
> 为可复现入口,并已封装为一键验收脚本 `tools/phase3/run_windows_acceptance.ps1`
> (结果写入 `docs/phase3/evidence/windows-acceptance.txt`)。
> 单元测试自带进程内 fixture 服务(随机端口),可独立运行;集成测试需要先启动
> 外部 fixture 服务:`py -3 -m tools.fixture_server.server --port 18080`(脚本会自动启动)。

### 3.1 门禁落地状态(2026-10-02,含 EPG、JS Spider 与猫源)

自动化测试已覆盖上表全部门禁。除 `dart analyze` 外,`apps/desktop-flutter` 的
`flutter test` 共 **445** 个用例(Phase 2 的 203 + 直播 53 + 播放诊断 12 + 字幕 26 + 弹幕 35 + 直播弹幕 14 + 解析器 22 + EPG 31 + 直播页 EPG 4 + JS Spider 8 + 猫源 37),
八个集成套件在 Windows 真实窗口 + 真实 media-kit 播放器上 **17** 个用例全绿,
并产出可复查事实行:

直播(`integration_test/live_flow_test.dart`):

- `PHASE3-EVIDENCE live-page rendered sources=2 channels=yes live-configured=2`
- `PHASE3-EVIDENCE live-source-fail isolated=true retry-visible=true`
- `PHASE3-EVIDENCE live-request direct=true lines=1`
- `PHASE3-EVIDENCE live-playback first-frame=yes`
- `PHASE3-EVIDENCE live-diagnostics engine=media-kit/mpv format=hls host=127.0.0.1 succeeded=true`

字幕(`integration_test/subtitle_flow_test.dart`):

- `PHASE3-EVIDENCE subtitle-default-on uri=true title=简体中文（zh） lines=1`
- `PHASE3-EVIDENCE subtitle-off id=no`
- `PHASE3-EVIDENCE subtitle-reselected uri=true`
- `PHASE3-EVIDENCE subtitle-failure isolated=true playing=true`

弹幕(`integration_test/danmaku_flow_test.dart`):

- `PHASE3-EVIDENCE danmaku-rendered items=8 selected=true`
- `PHASE3-EVIDENCE danmaku-off enabled=false painted=false`
- `PHASE3-EVIDENCE danmaku-resumed enabled=true`
- `PHASE3-EVIDENCE danmaku-playback-kept playing=true`
- `PHASE3-EVIDENCE danmaku-failure isolated=true items=0 playing=true`

直播弹幕(`integration_test/live_danmaku_flow_test.dart`,WS 由测试内 Dart 服务提供):

- `PHASE3-EVIDENCE live-danmaku-received chat=yes`
- `PHASE3-EVIDENCE live-danmaku-valid items=4 invalid-dropped=true`
- `PHASE3-EVIDENCE live-danmaku-off enabled=false`
- `PHASE3-EVIDENCE live-danmaku-playback-kept playing=true`
- `PHASE3-EVIDENCE live-danmaku-failure isolated=true playing=true`

解析器(`integration_test/parser_flow_test.dart`):

- `PHASE3-EVIDENCE parser-resolved url=sample.m3u8 media-ok=true source=parsed-by:Fixture JSON 解析器`
- `PHASE3-EVIDENCE parser-playback first-frame=yes`
- `PHASE3-EVIDENCE parser-failure isolated=true kind=parseHttp`

EPG(`integration_test/epg_flow_test.dart`):

- `PHASE3-EVIDENCE epg-loaded channels=yes now-playing=新闻直播间`
- `PHASE3-EVIDENCE epg-detail programs=yes tab=节目单`
- `PHASE3-EVIDENCE epg-refresh ok=true`
- `PHASE3-EVIDENCE epg-failure isolated=true channel-visible=true`

JS Spider(`integration_test/js_spider_flow_test.dart`,真实 Node 子进程 + 真实 fixture):

- `PHASE3-EVIDENCE js-unavailable isolated=true runtime=本地 Spider (webhtv-ipc-v1)`
- `PHASE3-EVIDENCE js-manifest runtime=node capabilities=category,detail,home,play,search`
- `PHASE3-EVIDENCE js-available runtime=本地 Spider (webhtv-ipc-v1)`
- `PHASE3-EVIDENCE js-home list=1`
- `PHASE3-EVIDENCE js-category list=1`
- `PHASE3-EVIDENCE js-detail episodes=1`
- `PHASE3-EVIDENCE js-search sites=1`
- `PHASE3-EVIDENCE js-runtime running isolation=Instance of 'ProcessIsolationReport'`
- `PHASE3-EVIDENCE js-stopped state=stopped`
- `PHASE3-EVIDENCE js-broken isolated=true reason=entry-missing`
- `PHASE3-EVIDENCE js-ok-after-failure list=1`

猫源(`integration_test/cat_source_flow_test.dart`,真实本地 bundle + 真实 Node 子进程):

- `PHASE3-EVIDENCE cat-package package=F:\temp\catpkg`
- `PHASE3-EVIDENCE cat-import sites=126`
- `PHASE3-EVIDENCE cat-available available=126 runtime=CatSpider HTTP (webhtv-cat-http-v1)`
- `PHASE3-EVIDENCE cat-search site=nodejs_omnibox_豆瓣推荐 keyword=寒战 items=609`
- `PHASE3-EVIDENCE cat-search-total items=609`

猫源真实 bundle 端到端脚本(`tools/phase3/verify_cat_source.py`,与 Dart 侧同一份 boot 语义):

- `[cat-verify] OK 猫源服务 port=3709 candidates=[3709]`
- `[cat-verify] OK /config sites=126`
- `[cat-verify] OK 站点 api 已补基址 searchable=126/126`
- `[cat-verify] OK [try=1/5] init HTTP=200` / `home HTTP=200 classes=4`
- `[cat-verify] FAIL [try=1/5] search wd=寒战 items=0`(单站点数据波动)
- `[cat-verify] OK [try=2/5] search wd=寒战 HTTP=200 items=12`
- `[cat-verify] OK detail id=/v/hanzhan6.html HTTP=200 flags=线路168$$$…`
- `[cat-verify] OK play flag=线路168 HTTP=200 url=['默认', 'https://play.xluuss.com/play/ejR09Gle/index.m3u8']`
- `[cat-verify] RESULT OK 猫源导入 / 站点 / 搜索 / 播放 全链路通过`

> 脚本对搜索/播放做**站点轮换**:单个站点对某关键词返回空列表(HTTP 200 但
> items=0)属于上游站点数据波动,不应当作协议失败;最多依次尝试 5 个可搜索站点,
> 任一命中即继续 detail → play,全部试完仍无命中才判 FAIL。

一键验收脚本输出 `PHASE3-ACCEPT result=PASS gates=all`(7 道门禁全部通过):
`live-fixture-preflight`、`python-contract-tests`、`schema-validation`、
`dart-analyze`、`flutter-unit-tests`、`cat-source-real-bundle`、
`windows-integration-tests`。

### 3.2 JS Spider 实现要点(实测结论)

**a) 沙箱必须跑在 worker 线程,HTTP 必须在宿主主线程。** TVBox 站源把 `req()`
当**同步**函数用(`var html = req(url)`),而 Dart 宿主发来的 `$/cancelRequest`
和心跳都靠同一事件循环处理。若沙箱在主线程阻塞,取消/超时/心跳全部失效。
因此:沙箱跑在 worker 线程(`Atomics.wait` 只阻塞它自己),HTTP 由宿主主线程
异步完成,再 `Atomics.notify` 唤醒沙箱。

**b) `Atomics` 只能存 32 位整数,状态码必须用整数。** 最初用字符串状态码
(`'ok'`/`'network-error'`)存入 `Int32Array`,`ToInt32('ok')` 静默得到 `0`,
表现为**所有 `req` 都报「未知状态：0」**——空手回一个成功响应都做不到。
这是本次端到端实测直接抓到的真实缺陷(单看代码不会发现)。

**c) `main()` 的返回值必须转成 `process.exit(code)`。** 否则站源入口不存在 /
manifest 非法时 Node 以 **exit 0** 结束,被宿主判为「正常退出」而非启动失败,
把真实的启动错误伪装成成功(§8.4 禁止把错误当成功)。

**d) JS 宿主路径不能从 manifest 目录解析 entry。** 随包 fixture 的 `manifest.json`
在 `manifests/` 而 `entry` 写作 `spiders/fixture_spider.js`(与 Python fixture 同布局);
产品路径下 manifest 与 `spiders/` 同目录。测试需显式给出服务器级 `entryPath`,
产品路径由 `SpiderManifestRegistry` 按 manifest 目录解析。

### 3.3 字幕实现要点(Windows 实测结论)

`SubtitleTrack.data` 在本项目环境下不可靠:media-kit 的 `TempFile` 用 UUID 命名、
**没有扩展名**,mpv 只能靠内容嗅探识别,实测出现「轨已加入但
`state.tracks`/`state.track` 迟迟不刷新」的观测不一致。因此改为:

1. 宿主自己带 Header 拉取字幕文本(不把 Header 泄漏给播放器,§11.3.1);
2. 写入 `%TEMP%\webhtv-pc-subtitles\sub-<ts>.<fmt>`(**带真实扩展名**);
3. 用 `SubtitleTrack.uri(路径)` 交给 mpv,libass 能按扩展名直接解析。

切集/切线会重新拉取,旧的临时文件在选择成功后清理,`dispose` 时全部清理
(§20 资源释放)。

### 3.4 弹幕实现要点(两处非显然结论)

**a) `testWidgets` 与真实 HTTP 不能同文件。** `testWidgets` 会初始化 flutter_test
的 binding,而该 binding 会拦截**本进程内所有 HTTP 请求**并统一返回 400,报错文本
为 `TestWidgetsFlutterBinding, all HTTP requests will return status code 400`。
因此需要真实 HTTP 的弹幕加载测试(`phase3_danmaku_test.dart`)与 widget 渲染测试
(`phase3_danmaku_overlay_test.dart`)**必须拆成两个文件**;否则服务测试会拿到假
400 而不是真实响应(这是实测确认的,不是推测:同一套 DanmakuService 在无
`testWidgets` 的文件里能正常拉到 8 条弹幕)。

**b) 轨道分配用「活动窗口独占」而非「追尾检测」。** 同一轨道的弹幕共享同一 y
坐标,同刻出现在屏幕上必然水平重叠;精确判定「上一条是否已完全移入画面左侧」
需要按时间推算每条的位置与宽度,代价高且易错。因此轨道在
`[开始时, 开始时+滚动窗口)` 内独占,满了就丢弃该条(不阻塞后续弹幕)。
轨道分配在**弹幕开始时刻**一次算定,与查询的播放位置无关,保证逐帧查询结果稳定
且互不重叠(media3 等同模型)。

**c) 颜色必须补 alpha。** WebHTV/TVBox 弹幕文件的颜色字段是 RGB 十进制
(如 `16777215` = `0xFFFFFF`)。Android 侧 `DanmakuData.param` 用
`(0x00000000FF000000L | value) & 0xFFFFFFFF` 强制补上不透明 alpha;若不补,
`Color(0x00FFFFFF)` 是全透明,表现为「弹幕加载成功但什么都看不见」。直播弹幕
的 `#RRGGBB` 同理(`LiveDanmakuParser.parseColor` 补 `0xFF000000`)。

**d) 直播弹幕渲染不做播放位置过滤。** 静态弹幕按播放进度驱动;直播弹幕是实时
流,没有起点——收到即入队,用**墙钟接收时刻**作为伪时间轴,叠加层每 250ms
重绘(通过会话建立的 ticker),弹幕在滚动窗口内完成后自然消失。切集/切线时
必须断开旧会话(`generation` 代次递增防串帧),否则上一路的弹幕会继续推到新画面上。

### 3.5 EPG 实现要点

**a) 频道匹配键必须与解析期一致。** XMLTV 的 `<programme channel="x">` 先按直播频道的
`epgId`(`tvg-id`)→ `tvgName`(`tvg-name`)→ 频道名依次匹配;都匹配不上再用
XML 侧 `<channel id>` 的 `<display-name>` 反查直播频道名。**匹配成功时存的键**
是 `epgId`(非空)否则频道名,因此 UI 侧 `epgGuideForChannel` 必须用同一规则
查表,否则会出现「节目单已加载但列表看不到当前节目」。

**b) 缓存目录必须递归删。** 缓存文件落在 `<cacheDir>/epg/<hash>.epg`,而
`clearCache()` 最初只列了 `<cacheDir>` 一层,导致清理是**空操作**(测试直接暴露)。
已改为 `list(recursive: true)`,只删本服务写的 `.epg`。

**c) 当前节目判定左闭右开。** `isLiveAt(t)` 为 `start <= t < stop`,相邻节目
不会同时算作当前;数据重叠时取开始时间最晚的(更符合「现在在放什么」)。
列表对**无当前节目**的频道不伪造标题(已结束节目只出现在节目单并置灰)。

**d) EPG 失败是增强项失败。** 所有 `epg*` 错误在直播页只写入状态条提示 +
日志,频道列表与播放入口完全不受影响——与字幕/弹幕的失败隔离同一语义(§10.4)。
`_loadGuideFor` 捕 `catch (error)` 而非仅 `on AppError`,避免任何非预期异常
升级为未捕获错误。

### 3.6 猫源实现要点(真实 bundle 实测结论)

**a) 猫源不是「配置地址」,而是「自起服务的 Node 包」,必须先跑起来再取配置。**
用户填的 `.../index.js.md5` 只返回 32 字节校验值,真正的 bundle 在去掉 `.md5` 的地址上
(实测 1.6 MB)。因此导入顺序是:**拉 md5 比对 → 命中缓存就不重复下载 → 写 boot.js →
`Process.start(node,[boot.js])` → 轮询候选端口 → 取 `/config` → `CatSource.normalize`**。
直接把 `index.js.md5` 当配置文本抓会因「不是 JSON」失败(所以未注入 resolver 时
报错而非静默空站点)。

**b) bundle 靠注入的全局与 `index.config.js` 才能 start()。** bundle 自己起 HTTP 服务,
需要宿主提供 `globalThis.catServerFactory=(handler)=>http.createServer(handler)` 与
`process.env.DEV_HTTP_PORT`;并且**必须有** `index.config.js`(脚本形态
`var index_config = {...}`,内含 `server.url` 与 `authorization`)——缺失时 bundle
start() 抛 `Cannot read properties of undefined (reading 'url')`(实测)。因此
`CatBundle._ensureLocal` 对缺 `index.config.js` 的目录报可定位错误,不落入
「地址不可访问」的兜底文案。

**c) 端口必须落盘且要**逐个探测**——一见端口就收工是错的。** 魔改 bundle 会额外起
自己的 HTTP 服务(如内置弹幕服务器),那些服务对 `/config` 返回 401 信封或欢迎页——
**都是非空响应**,只判空会把它们当成就绪。所以:boot.js 把所有候选端口写入
`<bundleDir>/port`,Dart 侧逐个探 `/config` 并用 `CatSource.isConfig`(按配置形状)
认准猫源服务(附带服务可能比猫源晚绑定,不能一见端口就收工)。

**d) 站点 `api` 指向本机随机端口,重启后必变,所以持久化必须存原始猫源地址。**
猫源站点 `api` 形如 `http://127.0.0.1:9505/spider/omnibox_4KVM/3`;端口每次不同,
**禁止**把 `127.0.0.1:<port>` 写进站点持久化并直接复用。参考实现 VodConfig 正是
存用户填的**原始猫源 URL**,每次配置加载时重跑 bundle 再读 `/config`。因此
`ImportedConfig.origin` 保留原始猫源地址,`AppState._reserveCatConfig` 在启动恢复
与换源时按原地址重拉新端口;重拉失败才回退到旧 JSON(由站点页如实报不可用,
不把整次启动拖垮)。

**e) 猫源站点缺 `searchable` 默认**可搜**。** TVBox 生态(含参考实现
`Site.searchable == null ? 1 : …`)按可搜索处理,而本仓库标准配置路径对缺失字段
默认**不可**搜索(§8.4),两者语义相反。所以只在 `CatSource.normalize` 里补
(缺失就写 `1`,站点自己声明的值包括 `0` 一律保留),不改 `Site.fromJson` 的默认值
——既符合猫源生态,也不破坏标准配置语义。

**f) 本地包与远端走同一套链路,但 `isBundle` 要同时认两者。** 门禁
`ConfigImportService.import()` 只用 `CatSource.isBundle(source.value)` 判是否走猫源分支,
而它最初只认 URL 形态(`.js.md5`/`index.js`),导致本地目录包(如 `F:\temp\catpkg`)
被漏判而走普通抓取路径失败。已补齐:非 http(s) 输入额外做磁盘探测(含 `index.js` 的
目录、`.zip` 文件),且**只对本地输入做**(避免把远端地址当本地路径去 stat)。
远端探测后由 `CatBundle._localDir`/`_localZip` 二次确认(zip 还要校验内含 `index.js.md5` 标记)。

**g) 校验值必须从 `.md5` 地址取,不能从去掉 `.md5` 的地址取。** 远端导入第一版写成
`_remoteMd5(bundleUrl(url))`,而 `bundleUrl` 是**去掉** `.md5` 的地址——那返回的是
1~10 MB 的**JS 源码**而非 32 字节校验值,`isMd5` 恒假,于是**所有**远端猫源都报
「猫源校验值不可用,且没有该地址的本地缓存」。正确写法是 `_remoteMd5(md5Url(bundleUrl(url)))`
与 `_remoteMd5(configMd5Url(url))`(参考实现 `remoteMd5()` 内部同样用 `md5Url(url)`)。
本地包路径不经过这段,所以只有**真实远端源**才能暴露它——已由
`cat_bundle_test.dart`「校验值取自 .md5 地址」在本地 HTTP 夹具上锁定。

**h) `dart:io`/`package:http` 都不解码 URI userinfo,必须自己解码。** 猫源地址大量
写作 `user:pass@host`,而密码里含 `:` 时按 URL 规则编码为 `%3A`(用户实测的四个源全部
如此)。**curl 会先解码再发**(`root:eXi6S:jgdv22!N6` → 200),但 Dart 把 userinfo
**原样**塞进 Basic 凭据,发的是字面 `%3A` → 服务端 401(实测:同一地址 Dart 401 /
curl 200,抓包确认两者 base64 不同)。修复:`protocol.dart` 新增
`basicAuthHeader`(先 `Uri.decodeComponent(userInfo)` 再 base64)与
`uriWithoutUserInfo`,凡走 `HttpClient`/`package:http` 的出站请求
(`CatBundle`、`ConfigLoader`、`HttpApiRequestBuilder`、`CatHttpRequestBuilder`)
都改成「解码后显式设 Authorization 头 + 请求 URI 去掉 userinfo」;
只在站点未自行声明 `Authorization` 时注入,不覆盖用户显式凭据。
加速镜像的 302 由 `CatBundle._openGet` 自己跟随(**跨主机时丢弃凭据**,
避免把账号密码泄给镜像站),`ghfast.top` 这类地址因此可用。

**i) 宿主 `catDartServerPort()` 对应的 `/msg` 服务必须真实应答,不能只 bind 端口。**
bundle 用 `catDartServerPort()` 拼出 `http://127.0.0.1:<port>/msg`,通过 `messageToDart`
读写自己的 profile(`saveProfile`/`queryProfile`)。早先只 `ServerSocket.bind(0)` 后
对每个连接 `socket.destroy()`(以为「bundle 多数不真正 POST,只为端口不悬空」),
结果 bundle 每次 POST 都 `read ECONNRESET`(被 `try/catch` 吞掉返回 `null`,
不崩但 profile 永远读不回来),Node 日志刷错误。已改为**最小 HTTP 服务**:
读到请求头结束(`\r\n\r\n`)即回 `200 {"success":true}` 并关闭连接。
真实 `F:\temp\catpkg` 实测 `POST /msg` = `HTTP 200 {"success":true}`。

> 附注:用户实测的四个源中有一个(`.../catvod/index.js.md5`)其服务端
> `index.config.js.md5` 声明值与实际内容不符(实测 8809 字节,md5
> `b95c…` ≠ 声明 `497a…`)。这是**服务端数据不一致**,参考实现同样硬校验并报错,
> 不属于本仓库缺陷;其余三个源修复后均能真实启动并拉到站点(69/57/42 个)。

## 4. 本轮修复的缺陷(均有测试锁定)

1. `lib/core/protocol.dart`:`LiveChannel` 缺 `header` 字段、`LivePlaylist` 缺 `epg`
   字段、`AppErrorKind` 缺直播错误分类——直播线路的 `#EXTVLCOPT`/`url|header`
   无从放置,清单级 EPG 无从携带。
2. `lib/services/live_service.dart`:Windows 盘符路径(`C:\...`)被 `Uri.parse` 误判为
   URI scheme(`c`),导致本地直播文件全部报「协议不受支持」。现将盘符路径/裸路径
   在 URI 解析前判定为本地文件(与配置导入 `file` 分支同语义)。
3. `lib/ui/live_page.dart` 导航前实例化 `PlayerPage` 触发 media-kit 初始化:
   `testWidgets`(fake-async 区)无法安全初始化原生库。已将直播播放请求构造
   提取为 `LivePage.requestForChannel` 纯函数,UI 测试覆盖渲染与交互,
   播放请求逻辑由纯函数测试覆盖。
4. `lib/ui/live_page.dart`:`requestForChannel` 未把**频道级 Header** 写入
   `PlaybackRequest.headers`,使 M3U `#EXTVLCOPT` / TXT `url|header` 声明的
   Referer/UA 全部丢失,需鉴权的直播线路无法播放(§13.1 直播 Header)。
   已修复并由 `phase3_live_page_test.dart` 断言锁定(负向对照证实有判别力)。
5. `lib/services/epg_service.dart`:`clearCache()` 只列了 `<cacheDir>` 一层,而缓存
   落在 `<cacheDir>/epg/`,导致清理**恒为空操作**。已改为递归列举(`phase3_epg_test.dart`
   「缓存清理」直接锁定:清理前后 `epg/` 下文件从非空变空)。
6. `tools/fixture_server/server.py` 与 Dart 测试 fixture server:`/live/` 路由对**所有**
   文件固定返回 `audio/x-mpegurl`(`.xml` 的 EPG 也如此)。已按扩展名分派
   (`.xml`→`application/xml`、`.json`→`application/json`、`.gz`→`application/gzip`)。
5. `lib/core/protocol.dart` / `lib/core/http_api.dart`:播放结果里的 `subs`
   (外挂字幕)完全被丢弃,`AppErrorKind` 也没有字幕分类——字幕无法表达也无法
   提示。现已新增 `SubtitleInfo` + `subs` 解析与六个 `subtitle*` 错误分类。
6. `lib/ui/player_controller.dart`:直接使用 media-kit 的 `SubtitleTrack.data`
   在本项目环境下不可靠(临时文件无扩展名 → mpv 仅靠嗅探 → 轨状态延迟刷新),
   导致「默认字幕已启用」但菜单轨表为空。改为写入带真实扩展名的临时文件 +
   `SubtitleTrack.uri` 后稳定可靠(实测结论见 §3.3)。
7. `lib/core/protocol.dart#PlaybackDecision`:走本地代理时 `headers` 会被清空
   (Header 由代理注入),而字幕/弹幕是宿主自己发请求,必须用**代理前**的原始
   Header。已新增 `upstreamHeaders`/`assetHeaders`,避免字幕/弹幕请求丢
   Referer/UA 而被上游 403。
8. `lib/core/danmaku.dart#_isWideRune` 的宽度比例:原先半角按 0.55 估算,
   破坏了排版上通用的「全角:半角 = 2:1」约定(4 个汉字反而窄于 8 个字母),
   使中英混排的防重叠判定失真。已改为全角 1.0 / 半角 0.5,
   并由 `phase3_danmaku_test.dart` 的「宽度估算遵循全角:半角 = 2:1」用例锁定
   (该断言在 0.55 下会失败,负向对照证实有判别力)。
9. `lib/services/cat_bundle.dart#_ensureRemote`:**远端校验值取错了地址**——写成
   `_remoteMd5(bundleUrl(url))`(去掉 `.md5`,拿到的是 1~10 MB 的 JS 源码),
   于是 `isMd5` 恒假,**所有**远端猫源都报「猫源校验值不可用,且没有该地址的
   本地缓存」(用户实测四个源全部无法导入)。本地包路径不经过这段,所以过去的
   本地包验收掩盖了它。已改为 `md5Url(bundleUrl(url))` / `configMd5Url(url)`
   (与参考实现 `remoteMd5()` 内部用 `md5Url(url)` 一致),并由 `cat_bundle_test.dart`
   「校验值取自 .md5 地址」在本地 HTTP 夹具上锁定请求路径。
10. `lib/core/protocol.dart` + 四处出站请求(`cat_bundle`/`config_loader`/
    `http_api`/`cat_http`):**URI userinfo 的百分号编码未解码**。`dart:io` 的
    `HttpClient` 与 `package:http` 都把 `userInfo` 原样塞进 Basic 凭据,而猫源
    地址的密码常含 `:`(按 URL 规则编码为 `%3A`)——curl 先解码再发(200),
    Dart 发字面 `%3A` → 401(实测同一地址 Dart 401 / curl 200,抓包确认 base64
    不同)。已新增 `basicAuthHeader`(先解码再 base64)与 `uriWithoutUserInfo`,
    并在四处统一改为「显式设 Authorization 头 + 请求 URI 去掉 userinfo」;
    站点未自行声明 Authorization 时不注入。同时 `CatBundle._openGet` 自己跟随
    302(跨主机丢弃凭据),使 `ghfast.top` 一类加速镜像可用。由 `cat_source_test.dart`
    「userinfo 凭据」与 `cat_bundle_test.dart`「userinfo 凭据被百分号解码后以
    Basic 头发出」锁定。
11. `lib/services/cat_runtime.dart#_startBacking`:**宿主 `/msg` 占位服务掐断连接**——
    早先实现接受 socket 后直接 `socket.destroy()`,只求「端口不悬空」。但 CatVod
    bundle 用 `catDartServerPort()` 构造 `http://127.0.0.1:<port>/msg` 回调,靠它
    读写自己的 profile(`messageToDart` → `saveProfile`/`queryProfile`);连接被掐
    断后 bundle 每次 POST 都拿到 `read ECONNRESET`(`try/catch` 吞掉返回 `null`,
    所以不崩,只是 profile 永远拿不回来),Node 日志刷错误。实测 5908b22c 包每导入
    一次配置就报两次。已改为**正常应答的最小 HTTP 服务**:读到请求头结束即回
    `200 {"success":true}`;`Object.keys(c).length > 0` 才应用 profile,空对象
    语义等同「宿主没存过任何 profile」。真实 F:\temp\catpkg 实测 `POST /msg`
    返回 `HTTP 200 {"success":true}`(修复前 ECONNRESET)。
12. `lib/state/app_state.dart#_attachSiteService`:**导入新配置后选中站点串到旧配置**
    ——原用 `_selectedSite ??= config.defaultSite()`,只在选中为 null 时补默认值,于是
    导入新配置仍选中上一个配置的站点。实测导入猫源(57 个 catHttp 站点)后仍选中旧
    配置的 `csp_PianDan`(JVM Spider,Phase 3 未实现),首页直接 `siteUnsupported`,
    用户看到「一个站点都加载不出数据」。已改为按 key 校验选中站点是否属于当前配置
    (不属于则退回新配置默认站点),并在站点变化时清掉上一个配置的首页/分类/详情/
    搜索/选中分类结果(浏览结果绑定在选中站点上);重新导入**同一份**配置(站点未变)
    时保留选中与结果。由 `test/phase3_cat_switch_test.dart` 四条不变量锁定。
13. `lib/ui/browse_pages.dart#_VodGrid`:**「有分类、空列表」被误报成空站**——猫源/
    部分站点首页只返回分类(`class` 非空)而 `list` 为空,需用户先点分类。原空态
    无条件显示「没有内容」,把正常站点误报成空站(实测 126 站点里 40 个如此)。已按
    「有无分类」区分两种空态文案:有分类提示「请选择左侧分类」,无分类才提示
    「没有内容」。

## 5. 风险与开放问题

1. **直播 Header 语义(§13.1 直播 Header)**:本阶段支持 M3U `#EXTVLCOPT`/`#EXTHTTP`
   与 TXT `url|header` 的**频道级** Header(经 `LiveChannel.header` 携带,播放时注入)。
   「直播源级默认 Header 合并」「直播代理 HLS 会话」尚未实现,放入直播增强。
2. **EPG(§13.1)**:已实现——清单级 `url-tvg`(M3U)与直播源 `epg` 字段作为 EPG 地址,
   拉取 XMLTV(`.xml`/`.xml.gz`,HTTP/本地)、按频道三级匹配节目、当天 + 6 小时缓存与
   手动刷新,直播页列表显示当前/下一节目、详情展示节目单页签。
   **未实现**:频道 logo 之外的 EPG 图标、回看(`catchup`)、多日节目导航、
   以及 XMLTV 之外的 EPG 格式(如 TVBox 的独立 EPG 接口)。
3. **直播 JSON 的真实形态**:WebHTV/TVBox 直播 JSON 既有 `groups[].channel[]`
   (当前实现的主形态),也有 `{code,data}`、`{data:{groups:[...]}}` 信封。
   本阶段兼容数组/信封/顶层 map 三态;发现其他形态应在兼容性样本库记录。
4. **播放诊断增强(§23)**:已实现引擎/格式/网络/错误与阶段耗时的诊断快照,
   并在播放器页与日志页提供可复制报告。**硬解/软解切换、网络缓存、截图、
   画面比例、音轨选择**等 §10.3 后置播放能力仍未实现;
   诊断已预留字段位,但未接入这些开关。
5. **字幕范围(§10.3)**:已实现外挂字幕(SRT/ASS/SSA/VTT/SUB)、内嵌轨选择、
   开关与失败隔离。**字幕样式/字号/位置、双字幕、在线字幕搜索与自动匹配、
   字幕翻译**均不在本阶段范围。内嵌轨目前只能按语言/默认位支持,
   因为 media-kit 未暴露 `forced` 位(已在外挂字幕上支持 `forced`)。
6. **弹幕范围(§21 Phase 3)**:`字幕/弹幕可开启和关闭` 已完成——支持 XML(Bilibili
   格式)与行式文本两种弹幕文件的**静态**弹幕加载、渲染(滚动/顶部/底部/反向)、
   一键开关、透明度/字号/分类开关与失败隔离;也支持 **`ws`/`wss` 直播弹幕**
   (§13.1):WebSocket 会话按指数退避重连,chat/superchat 实时上屏,
   online 帧更新在线人数,非法帧丢弃,连接失败只提示不影响播放。
   **未实现**:弹幕发送、弹幕屏蔽词/举报、以及「按标题自动搜索弹幕源」的
   在线匹配。
7. **解析器范围(§12)**:已实现 JSON 类解析器运行时——`parse=1`/`jx=1` 会按 §12.2
   选择解析器并真实执行:`type=1`(`GET url+webUrl`,取 `{url}`/`{data.url}`)、
   `type=2`(JSON 扩展,携带全部 type=1 解析器)、`type=3`(JSON Mix,携带 flag);
   `flag` 可命中解析器;解析结果校验媒体类型;超时/失败归一化为 `parse*` 错误,
   由上层回退换源。**未实现**:`type=0` Web 嗅探与 `type=4` Super——两者都需
   浏览器内核/WebView 嗅探页面(Android 用 `CustomWebView`,PC 端无等价物),
   选中时给出明确错误(不静默)。

### 5.8 解析器不支持类型(§12.1)

| 类型 | 名称 | PC 端 | 原因 |
| --- | --- | --- | --- |
| 0 | Web 嗅探 | ❌ | 需浏览器内核/WebView 嗅探页面(Android `CustomWebView`),桌面环境无等价物 |
| 1 | JSON | ✅ | 纯 HTTP + JSON,已实现 |
| 2 | JSON 扩展 | ✅ | 纯 HTTP + JSON,已实现 |
| 3 | JSON Mix | ✅ | 纯 HTTP + JSON,已实现 |
| 4 | Super | ❌ | 多解析器并发含 Web 嗅探竞争,依赖 WebView |

选择到不支持类型时抛 `ParseSelectionException`(unsupportedOnly/
selectedUnsupported),UI 展示可定位文案,**不静默降级**为直链。

8. **JS Spider 范围(§9.1、§9.3、§9.7、§9.8)**:已实现 `tvbox-js-v1` 的
   **Node 运行时**——`runtime=node` 的本地 manifest 会真启动
   `sidecars/spider-host-js/host.js`,在 `node:vm` 沙箱内以 worker 线程执行
   TVBox 站源(`homeContent`/`categoryContent`/`detailContent`/`searchContent`/
   `playerContent` 与同步 `req`/`log`/`setItem`/`getItem`),由宿主主线程
   异步完成 HTTP 并唤醒沙箱(因此取消/超时/心跳仍可用)。它是 `webhtv-ipc-v1`
   的第三份实现,与 Dart 侧 `ipc_protocol.dart`、Python 侧 `webhtv_ipc.py`
   帧格式/握手/错误信封一致。
   **未实现**:`*.js` 站点地址的**远程脚本自动下载**(§9.8 要求下载前由用户
   确认来源与权限,该确认流程待做;当前只加载本机已存在的 manifest 与脚本);
   **QuickJS 编译器内核**(当前只用 Node `vm` 做隔离,不是安全沙箱);
   沙箱内**定时器**(`setTimeout` 等不注入,异步站源会明确报错);
   本地代理会话(`getProxyUrl`/`js2Proxy`)未开放给 JS 站源(同 Python 侧)。
   已实测**:同一个 JS sidecar 在原生驱动与 Dart 宿主下行为一致(16 项驱动器断言 + 8 项 Dart 门禁用例全绿)。   **重点缺陷修复**:`host.js` 原先用字符串作 `Atomics` 状态码(ToInt32('ok')=0),
   导致所有 `req` 都报「未知状态」;且 `main()` 的退出码未传给 `process.exit`,
   使站源入口/manifest 非法被误报为「正常退出」(exit 0)。两者均已修复并由
   `test/phase3_js_spider_test.dart` 锁定。

9. **猫源范围(§9 猫源、§9.7、§9.8)**:已实现 CatVod T4 bundle(`index.js` 自起
   Node HTTP 服务)的**完整导入链路**——`.../index.js.md5` / `.../index.js` /
   本地包目录 / 本地 zip 四态识别;md5 比对 + 本地缓存;写 boot.js 注入
   `catServerFactory`/`catDartServerPort` 后起真实 Node 子进程;候选端口逐个探测并用
   配置形状认准猫源服务;取 `/config` → `CatSource.normalize`(裸站点数组 /
   `{video:{sites}}` → 标准 `{sites}`,相对 `api` 补基址,缺 `searchable` 补 1)
   → 与标准 TVBox 配置同一套解析/站点/搜索/播放路径。实测本机真实 bundle:
   `/config` 126 站点全可用(CatSpider HTTP),搜索命中真实数据(如「寒战」440 条)。
   **未实现**:猫源的**远程脚本自动下载确认流程**(§9.8 要求下载前由用户确认
   来源与权限,当前只加载本机已存在/已缓存的 bundle);**非点播分组**(小说/漫画/
   音乐/网盘,`read`/`comic`/`music` 等分组当前不接入点播列表);**QuickJS 内核**
   (与 JS Spider 同,当前仅用 Node `vm` 隔离,不是安全沙箱)。
   **重点缺陷修复**:`CatSource.isBundle` 原先只认 URL 形态,本地目录包被漏判导致
   `ConfigImportService` 走普通抓取路径失败(集成测试直接暴露,参考实现
   `NodeBundle.isLocal` 也检查本地包);已补齐本地目录/zip 探测并由
   `cat_source_test.dart` 锁定。另修复三处实测缺陷:①宿主 `/msg` 占位服务
   接受连接就 `socket.destroy()`,bundle 每次 POST 拿 `read ECONNRESET`、profile
   读写必落空——改为回 `200 {"success":true}` 的最小 HTTP 服务;②导入新配置后
   仍选中上一个配置的站点(`_selectedSite ??= …`),实测导入猫源后仍选中旧配置的
   `csp_PianDan`,首页直接 `siteUnsupported`——改为按 key 校验归属并在站点变化时
   清掉旧浏览结果;③猫源首页「有分类、空列表」被空态文案误报成空站(126 站点里
   40 个如此)——按「有无分类」区分两种文案。后两者由
   `test/phase3_cat_switch_test.dart` 锁定。

## 6. 平台范围声明

本阶段仍**只交付 Windows**。Linux/macOS 的直播、字幕、弹幕、直播弹幕、
解析器、JS Spider 与猫源运行时验证不在范围内;
发布文案不得声称已支持直播、字幕、弹幕、解析器、JS Spider 或猫源。
