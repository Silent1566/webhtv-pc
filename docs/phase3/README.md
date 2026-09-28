# Phase 3 计划(直播 · Windows)

- 状态:进行中(直播核心闭环已完成,见 §3.1)
- 日期:2026-09-28
- 对应设计文档章节:§13(直播功能设计)、§21 Phase 3、§17.2
- 上游:`docs/phase2/README.md`(MVP-B 已完成,6 项门禁全绿)

## 0. 本阶段目标

把直播从「配置里 `lives` 字段的原始透传」升级为可用的**直播页 + 播放**闭环,
并建立可复现的 M3U/TXT/JSON 解析与播放验收。设计文档 §13.3 的验收原文:

- M3U 可解析(分组与属性解析正确:分组、channel、多线路、Header)。
- TXT 可解析(分组层级正确)。
- JSON 可解析(模型转换正确)。
- 频道支持多线路。
- 播放失败可切线路。
- EPG 可加载(本阶段:清单级 `url-tvg` 解析 + 字段保留)。
- 关闭应用后释放播放资源。

> 本阶段**只实现直播核心闭环**。EPG 展示、回看、直播弹幕、直播代理的单独
> HLS 会话管理属于后续直播增强(§13.1 完整版能力),不在本阶段验收范围。

## 1. 现状盘点

### 1.1 缺口(G1 直播完全缺失)

| 缺口 | 设计文档依据 | 现状 |
| --- | --- | --- |
| **无直播模型** | §13.2 | `AppConfig.lives` 只是 `List<Object?>` 原始透传;无 `LiveSource`/`LiveGroup`/`LiveChannel`/`LivePlaylist` |
| **无直播解析** | §13.3 | 无 M3U(`#EXTINF`/`group-title`/`tvg-*`/`#EXTVLCOPT`/`#EXTHTTP`)、TXT(`分组,#genre#` + `名称,地址`)、JSON(`groups[].channel[]`)解析 |
| **无直播页** | §13.1、§17.2 | 侧栏无直播入口;无分组/频道/线路展示 |
| **无直播播放** | §13.3 多线路 | 无「频道直链播放」与「失败自动切线路」路径 |

### 1.2 已具备(直播可复用的基础)

| 能力 | 位置 |
| --- | --- |
| 播放器(真实 video 画面/快捷键/进度恢复) | `lib/ui/player_page.dart` |
| 本地代理与 Header 合并策略 | `lib/core/proxy_policy.dart`、`lib/services/proxy_server.dart` |
| 编码探测(UTF-8 → GBK 兜底) | `lib/core/text_codec.dart#decodeConfigText` |
| 错误对象化(`AppError` + kind) | `lib/core/app_error.dart` |
| fixture 服务(可扩展新路由) | `tools/fixture_server/server.py` |

## 2. 实施顺序

| # | 任务 | 产出 | 验收 |
| --- | --- | --- | --- |
| 直播 1 | 直播数据模型(`LiveSource`/`LiveChannel`/`LiveGroup`/`LivePlaylist`) | `lib/core/protocol.dart` + `lib/core/config_parser.dart`;`lives` 解析为 `List<LiveSource>` | 模型解析/序列化往返;未知字段保留;缺 name 跳过并记诊断 |
| 直播 2 | 直播清单解析(M3U/TXT/JSON) | `lib/core/live_playlist.dart`;fixture `packages/test-fixtures/live/{live.m3u,live.txt,live.json}` | §13.3 三格式解析正确;同名频道合并线路;不可播放地址丢弃;元频道行跳过 |
| 直播 3 | 直播源加载服务(HTTP/本地 + 编码 + 缓存) | `lib/services/live_service.dart` | HTTP/本地加载;GBK 兜底;缓存 TTL/失效;非 2xx→`liveHttp` 不空列表化 |
| 直播 4 | 直播页 UI(源 → 分组 → 频道 → 线路) | `lib/ui/live_page.dart` + 侧栏「直播」入口 | 空态说明;多线路展示;单源失败不阻塞其他源 |
| 直播 5 | 直播播放接入 + 失败切线路 | `lib/ui/player_page.dart` `directUrl` + `_fallbackLiveLine` | 频道直链播放;线路失败自动按顺序切换 |
| 直播 6 | 测试与验收证据 | `test/phase3_*.dart` + `integration_test/live_flow_test.dart` + `tools/phase3/` | 门禁全绿;证据写入 `docs/phase3/evidence/` |

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
| 直播播放 | 直链 + 多线路 + 失败切线路 | `test/phase3_live_page_test.dart` `requestForChannel` + 纯函数 | `directUrl=true`、线路映射、越界安全 |
| 直播集成 | 真实窗口 + 真实播放器 + 直播直链出画 | `integration_test/live_flow_test.dart` (-d windows) | 直播页渲染;失效源隔离;带 Header 频道真实出画(PHASE3-EVIDENCE) |
| 无回归 | 全量单测 + 静态检查 | `flutter test` + `dart analyze` | 255 个用例全绿;analyze 无问题 |

> 门禁以 `flutter test` + `flutter test integration_test/live_flow_test.dart -d windows`
> 为可复现入口,并已封装为一键验收脚本 `tools/phase3/run_windows_acceptance.ps1`
> (结果写入 `docs/phase3/evidence/windows-acceptance.txt`)。
> 单元测试自带进程内 fixture 服务(随机端口),可独立运行;集成测试需要先启动
> 外部 fixture 服务:`py -3 -m tools.fixture_server.server --port 18080`(脚本会自动启动)。

### 3.1 门禁落地状态(2026-09-28)

自动化测试已覆盖上表全部门禁。除 `dart analyze` 外,`apps/desktop-flutter` 的
`flutter test` 共 **255** 个用例(Phase 2 的 203 + 直播 52),
`integration_test/live_flow_test.dart` 在 Windows 真实窗口 + 真实 media-kit
播放器上 **3** 个用例全绿,并产出可复查事实行:

- `PHASE3-EVIDENCE live-page rendered sources=2 channels=yes live-configured=2`
- `PHASE3-EVIDENCE live-source-fail isolated=true retry-visible=true`
- `PHASE3-EVIDENCE live-request direct=true lines=1`
- `PHASE3-EVIDENCE live-playback first-frame=yes`

一键验收脚本输出 `PHASE3-ACCEPT result=PASS gates=all`(6 道门禁全部通过):
`live-fixture-preflight`、`python-contract-tests`、`schema-validation`、
`dart-analyze`、`flutter-unit-tests`、`windows-integration-tests`。

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

## 5. 风险与开放问题

1. **直播 Header 语义(§13.1 直播 Header)**:本阶段支持 M3U `#EXTVLCOPT`/`#EXTHTTP`
   与 TXT `url|header` 的**频道级** Header(经 `LiveChannel.header` 携带,播放时注入)。
   「直播源级默认 Header 合并」「直播代理 HLS 会话」尚未实现,放入直播增强。
2. **EPG(§13.1)**:清单级 `url-tvg` 已解析到 `LivePlaylist.epg`,频道 `epgId` 已保留;
   但 EPG 抓取、解析、显示当前节目**不在本阶段**范围。
3. **直播 JSON 的真实形态**:WebHTV/TVBox 直播 JSON 既有 `groups[].channel[]`
   (当前实现的主形态),也有 `{code,data}`、`{data:{groups:[...]}}` 信封。
   本阶段兼容数组/信封/顶层 map 三态;发现其他形态应在兼容性样本库记录。

## 6. 平台范围声明

本阶段仍**只交付 Windows**。Linux/macOS 的直播验证不在范围内;
发布文案不得声称已支持直播。