# Phase 3 计划(直播 · 字幕 · Windows)

- 状态:进行中(直播核心闭环 + 播放诊断 + **外挂字幕** + **弹幕**已完成,见 §3.1)
- 日期:2026-09-29
- 对应设计文档章节:§13(直播功能设计)、§10.3(字幕轨选择/外挂字幕)、§21 Phase 3、§17.2、§23
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
- EPG 可加载(本阶段:清单级 `url-tvg` 解析 + 字段保留)。
- 关闭应用后释放播放资源。

§10.3(播放器,完整版必须项):

- 字幕轨选择。
- 外挂字幕。

§21 Phase 3 验收:

- 字幕/弹幕可开启和关闭。
- 播放诊断能输出引擎、格式、网络和错误。

> 本阶段已实现**字幕(外挂字幕 + 字幕轨选择与开关)**与**弹幕(可开启和关闭)**。
> EPG 展示、回看、**直播弹幕**(需 WebSocket 会话)、直播代理的单独 HLS 会话管理
> 属于后续增强(§13.1 完整版能力),不在本阶段验收范围。

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
| 无回归 | 全量单测 + 静态检查 | `flutter test` + `dart analyze` | **329** 个用例全绿;analyze 无问题 |

> 门禁以 `flutter test` + `flutter test integration_test/*.dart -d windows`
> 为可复现入口,并已封装为一键验收脚本 `tools/phase3/run_windows_acceptance.ps1`
> (结果写入 `docs/phase3/evidence/windows-acceptance.txt`)。
> 单元测试自带进程内 fixture 服务(随机端口),可独立运行;集成测试需要先启动
> 外部 fixture 服务:`py -3 -m tools.fixture_server.server --port 18080`(脚本会自动启动)。

### 3.1 门禁落地状态(2026-09-29,含弹幕)

自动化测试已覆盖上表全部门禁。除 `dart analyze` 外,`apps/desktop-flutter` 的
`flutter test` 共 **329** 个用例(Phase 2 的 203 + 直播 53 + 播放诊断 12 + 字幕 26 + 弹幕 35),
三个集成套件在 Windows 真实窗口 + 真实 media-kit 播放器上 **7** 个用例全绿,
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

一键验收脚本输出 `PHASE3-ACCEPT result=PASS gates=all`(6 道门禁全部通过):
`live-fixture-preflight`、`python-contract-tests`、`schema-validation`、
`dart-analyze`、`flutter-unit-tests`、`windows-integration-tests`。

### 3.2 字幕实现要点(Windows 实测结论)

`SubtitleTrack.data` 在本项目环境下不可靠:media-kit 的 `TempFile` 用 UUID 命名、
**没有扩展名**,mpv 只能靠内容嗅探识别,实测出现「轨已加入但
`state.tracks`/`state.track` 迟迟不刷新」的观测不一致。因此改为:

1. 宿主自己带 Header 拉取字幕文本(不把 Header 泄漏给播放器,§11.3.1);
2. 写入 `%TEMP%\webhtv-pc-subtitles\sub-<ts>.<fmt>`(**带真实扩展名**);
3. 用 `SubtitleTrack.uri(路径)` 交给 mpv,libass 能按扩展名直接解析。

切集/切线会重新拉取,旧的临时文件在选择成功后清理,`dispose` 时全部清理
(§20 资源释放)。

### 3.3 弹幕实现要点(两处非显然结论)

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
`Color(0x00FFFFFF)` 是全透明,表现为「弹幕加载成功但什么都看不见」。

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
5. `lib/core/protocol.dart` / `lib/core/http_api.dart`:播放结果里的 `subs`
   (外挂字幕)完全被丢弃,`AppErrorKind` 也没有字幕分类——字幕无法表达也无法
   提示。现已新增 `SubtitleInfo` + `subs` 解析与六个 `subtitle*` 错误分类。
6. `lib/ui/player_controller.dart`:直接使用 media-kit 的 `SubtitleTrack.data`
   在本项目环境下不可靠(临时文件无扩展名 → mpv 仅靠嗅探 → 轨状态延迟刷新),
   导致「默认字幕已启用」但菜单轨表为空。改为写入带真实扩展名的临时文件 +
   `SubtitleTrack.uri` 后稳定可靠(实测结论见 §3.2)。
7. `lib/core/protocol.dart#PlaybackDecision`:走本地代理时 `headers` 会被清空
   (Header 由代理注入),而字幕/弹幕是宿主自己发请求,必须用**代理前**的原始
   Header。已新增 `upstreamHeaders`/`assetHeaders`,避免字幕/弹幕请求丢
   Referer/UA 而被上游 403。
8. `lib/core/danmaku.dart#_isWideRune` 的宽度比例:原先半角按 0.55 估算,
   破坏了排版上通用的「全角:半角 = 2:1」约定(4 个汉字反而窄于 8 个字母),
   使中英混排的防重叠判定失真。已改为全角 1.0 / 半角 0.5,
   并由 `phase3_danmaku_test.dart` 的「宽度估算遵循全角:半角 = 2:1」用例锁定
   (该断言在 0.55 下会失败,负向对照证实有判别力)。

## 5. 风险与开放问题

1. **直播 Header 语义(§13.1 直播 Header)**:本阶段支持 M3U `#EXTVLCOPT`/`#EXTHTTP`
   与 TXT `url|header` 的**频道级** Header(经 `LiveChannel.header` 携带,播放时注入)。
   「直播源级默认 Header 合并」「直播代理 HLS 会话」尚未实现,放入直播增强。
2. **EPG(§13.1)**:清单级 `url-tvg` 已解析到 `LivePlaylist.epg`,频道 `epgId` 已保留;
   但 EPG 抓取、解析、显示当前节目**不在本阶段**范围。
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
   一键开关、透明度/字号/分类开关与失败隔离。**未实现**:直播弹幕(`ws`/`wss`
   需 WebSocket 会话与增量渲染,现明确报 `danmakuUnsupported`)、弹幕发送、
   弹幕屏蔽词/举报、以及「按标题自动搜索弹幕源」的在线匹配。
7. **解析器(§12)**:`parse=1`/`jx=1` 目前仍明确报「需要解析器」而不执行;
   本阶段不做解析器运行时(属 Phase 3 剩余项)。

## 6. 平台范围声明

本阶段仍**只交付 Windows**。Linux/macOS 的直播、字幕与弹幕验证不在范围内;
发布文案不得声称已支持直播、字幕或弹幕。
