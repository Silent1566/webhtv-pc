# MisaTV 对照与借鉴清单（Flutter 同栈版）

- 作用：判定 `github.com/yagami-hue/MisaTV` 对本项目**是否有帮助**，并把结论落成可执行清单——
  每项给出「MisaTV 怎么做 → 本仓库落点 → 优先级 → 前置条件/风险」。
- 与 `docs/reference/win-box-borrowings.md` 的关系：那份评估的是 **Electron 版 Win-box**。
  MisaTV 是同一作者用 **Flutter 重写**的版本（包名 `kniephos`，前身 Kniephos），
  因此它对我们**同栈**，能给出 Electron 版给不了的答案；反过来，Electron 版已判过的项本文不重复，
  只在结论发生变化时显式标注「差异」。
- 初始调研方式：将公开仓库浅克隆到 `/tmp/misatv`，随后只读核对源码；未构建或运行 MisaTV。
  下文“我们现状”和零命中记录均为调研基线，不是实施后状态。PC 修复与测试记录见 [P0 与问题修复验收](evidence/misatv-p0-fixes.md)。
- 调研基准：本仓库 `9ff8bbb`（调研开始时工作树干净）；MisaTV `f91cc41`。本轮不升级播放器内核、不引入网盘/BT 或其他 P1 功能。
- 复查记录：2026-11 MisaTV 的三次 jar 相关更新（原生 jar/DEX 运行器、加固壳修复、JVM 垫片补全）
  的采纳与回绝见文末「复查：2026-11 MisaTV 近期 jar 更新的采纳与回绝」一节。

---

## 0. 结论：有帮助，但只在很窄的几层

一句话：**MisaTV 对本项目最大的价值不是功能清单，而是「同一架构下别人怎么把坑踩完」的对照答案。**

三条结构性判断，决定了后面所有取舍：

1. **它技术更深的两个方向（网盘 + BT）恰好被我们的产品边界挡住。** 不是能力差距，是既定选择的不同。
   `drive/`(3,813 行) + `torrent/`(2,661 行) 合计 6,474 行里，有 1,381 行是**硬编码第三方客户端密钥**
   （`xunlei_cloud.dart:26-31`、`uc_tv_token.dart:12-14`），直接对撞 `PRODUCT.md:81`。
2. **我们在多个维度已经领先，照抄会退步。** dex 栈帧重算、ESM→CJS 转换、字幕源数量、
   时钟注入面、测试规模、CI 产物校验、代理安全策略——逐项有证据（见 §2）。
3. **真正该拿的是 3 条 P0（§3）+ 10 条 P1（§4），全部是纯机制项**——无许可成本、无产品决策、改动可单测。
   另有 5 条是本次调研顺带查出的**我们自己的问题**（§5），与是否借鉴 MisaTV 无关。

### 0.1 许可红线（先读这条）

| 侧 | 事实 |
| --- | --- |
| MisaTV | **GPL-3.0**（`LICENSE` 首行 "GNU GENERAL PUBLIC LICENSE Version 3"） |
| 本仓库 | **根目录没有 LICENSE 文件**（`ls LICENSE* COPYING*` → No such file） |

**复制、改编或分发 MisaTV 的 GPL 代码前，需要核对 GPL-3.0 的适用条件与分发义务**，不能仅凭“改写成 Dart”或代码行数判断许可已经消失，也不能直接断言任何一个函数都会使所有文件自动改用 GPL。
本文的实施选择是依据公开协议与抽象机制独立实现，不复制 MisaTV 代码或第三方凭据；抽象算法与公开 URL 也不等于完整免除来源、服务条款和资源授权审查。

另外两条随源码分发的义务，也一并记在这里：

- MisaTV 的「加固壳纯 Java 快路径」依赖一批**它自己都不入库**的第三方解包产物
  （`assets/jvm/shell-real/<壳名>.jar`）——它的「覆盖率」里有一块**法务上不可分发**。
- 它的 BT 用 **aria2c（GPLv2）** 二进制（`assets/aria2/README.md` 自述「不随源码仓库分发」）。
  我们连 LICENSE 都还没有，分发 GPLv2 二进制要在发行包里补 NOTICE 与源码提供承诺。

---

## 1. 基线对照

| 项 | MisaTV | 本仓库 |
| --- | --- | --- |
| 定位 | 轻量、本地优先的 TVBox 客户端，单进程、无账号、无遥测 | 桌面播放器，协议兼容层 + 进程隔离 + 分层 Spider ABI |
| 技术栈 | Flutter 桌面 + `fvp`(libmdk/FFmpeg) + `shared_preferences` | Flutter 桌面 + media-kit/mpv + SQLite + JSON |
| 规模 | 414 dart / 11.0 万行（`lib` 313 文件 9.5 万行） | `apps/desktop-flutter/lib` 352 文件 / 15.6 万行 |
| Spider 隔离 | **单进程**：QuickJS isolate + JVM 子进程（按站点常驻，池上限 3） | **进程隔离**：三套 sidecar（js/jvm/python）+ Windows 作业对象 |
| 测试 | 101 单测 / 0 集成 / 测试:源码 ≈ **15.8%** | 366 单测 + 38 集成 / 测试:源码 ≈ **105%** |
| CI | `build.yml` 73 行 | `desktop-ci.yml` 548 行（含真实启动烟测 + SHA256SUMS） |
| 状态管理 | `AppState : ChangeNotifier`，`lib/state/` **1 个文件** / 3,981 行 | 同样是裸 ChangeNotifier，`lib/state/` **10 个文件** / 12,552 行 |

**结论**：同栈、同形态、同用户群，但**工程重心的选择不同**——它把成本压在「网盘/BT/壳源」的深度上，
我们把成本压在「隔离边界/诊断/测试」的密度上。这就是为什么「有没有帮助」的答案是分层的。

---

## 2. 我们已在另一档（明确不要抄的）

这一节比 §3 更重要：**防止照着抄反而变差。**

| 能力 | MisaTV | 我们 | 判定 |
| --- | --- | --- | --- |
| dex→class 后的**栈帧重算** | 无。用 `DexJarRepair` 修两类具体误译 | `sidecars/spider-host-jvm/src/webhtv/spider/DexIntake.java:374` 用 ASM `COMPUTE_FRAMES` 通用重算，实测 1227 类 / 0 失败 | **我们更稳**：它是「发现一类修一类」，我们是按 JVM 校验器规则重算 |
| 产物缓存校验 | 源 jar 哈希 + 产物版本号 | 源 SHA-256 **与**产物 SHA-256 双校验（`:145-149`） | 我们多一道「产物自己没被改坏」 |
| ESM→CJS 转换 | `esm_transform.dart` 正则级（163 行），`export * from` **直接抛异常** | `sidecars/spider-host-js/esm_shim.js`（453 行）支持该档 | **我们更全** |
| 字幕源 | 3 源（SubtitleCat/assrt/custom） | 5 源（assrt/shooter/xunlei/本地/HTTP） | 我们更多；不引入 SubtitleCat（网页抓取、无 API 契约、失效形态与「没有字幕」不可区分） |
| 单测可注入时钟 | `grep 'DateTime Function()'` → 8 行 | **47 行**，测试侧 147 处注入 | **我们领先一个量级** |
| 运行时时序 | 按需下载 JRE 17(85MB)+dex2jar+unidbg(39MB)，四镜像测速 | 不下载，要求本机 JDK 17+ | 刻意的产品决策，不是缺口 |
| 代理安全模型 | `relay_origin.dart` 同源 + `relay_access.dart` `?rt=` 令牌 | `core/proxy_policy.dart`(706 行)：目标白名单、逐跳重定向重校验、会话字节/请求上限、私网与云元数据拒绝、Set-Cookie 不外泄 | **我们更严**。加路由时沿用我们的策略，不要照抄它的宽松度 |
| 窗口键镜像兼容 | 钉死 `windows-2022` 镜像避开 VS 2026 的 `/await` 问题 | `windows/CMakeLists.txt:35-39` 用官方过渡宏 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` | 我们随镜像升级自动可用，它会在镜像退役日集中爆发 |
| 播放器页分层 | 3,209 行拆 5 个 `part` + `extension ... on _PlayerPageState`，靠 `setStateFromPart` 访问私有成员 | 拆成真正的独立文件（controller/overlay/osd/context_menu/episode_panel，合计 3,532 行），边界靠构造参数 | **抄它会退步**：part 与主文件共享同一 library 作用域，编译期没有边界 |
| 沉浸观影 / 大屏焦点树 | `lib/ui/immersive/` 9 文件 3,789 行，Hero 铺满整屏 + 焦点记忆 | `PRODUCT.md:18`「坐在电脑前，用鼠标 + 键盘操作」；密度由 `LayoutScale` 按窗口短边推导 | **产品决策已定**，互斥而非互补。唯一可搬的是 `focus_memory.dart` 的三条簿记规则（若将来做 TV 模式） |
| 状态管理形态 | 裸 ChangeNotifier + 全部 `shared_preferences` | 同样裸 ChangeNotifier，但历史/收藏走 SQLite（墓碑可查） | 它的「全部 shared_preferences」我们**做不了也不该做**（`PRODUCT.md:82` 要求进程隔离，7.5k 行状态挂纯 JSON 会失去索引与墓碑） |
| 编译期平台三件套 | `foo.dart/foo_io.dart/foo_web.dart` 34 个文件 | `grep 'dart.library'` → **0**，无 `*_io.dart/*_web.dart`，仓库无 web 目标 | 不适用：它需要是因为有个只做界面预览的 Web 版，我们没有 |

---

## 3. P0：三件小改动，先做

共同特征：无许可成本、无产品决策、改动可单测、**且都在修真实问题**（不是加功能）。

### P0-1 · m3u8 去广告先装「安全阀」，启发式缓一步

- **MisaTV 怎么做**（`lib/services/relay/m3u8_purify.dart`，1,168 行，逐函数移植 TVBox `M3u8.java`）：
  五级启发式（少数派 URL / 规则段 / SCTE-35 与 CUE-OUT / 小数精度与帧率 / 非主导短组），
  **外加三道回退保护**：
  ```dart
  // :663-666  单级作废
  if (removableSegments == 0 || removableSegments > _getAdSegmentLimit(content) ||
      removableSegments > totalSegments * 0.3) { return content; }
  // :1143-1150  累计回退 + 可播性回退
  if (total > 0 && st.adCount > total * 0.5) { st.adCount = 0; out = text; }
  if (st.adCount > 0 && !_isPlayableMediaPlaylist(out)) { st.adCount = 0; out = text; }
  ```
  `_isPlayableMediaPlaylist`（`:577`）判据：必须有段、不得连续两个 `EXTINF`、不得 `EXTINF` 紧跟 `ENDLIST`。
  配 19 个单测逐条钉住回退（`test/m3u8_purify_test.dart`）。
- **我们现状**：`lib/core/ad_rules.dart:223-287` `cleanHlsPlaylist` 只有**规则驱动的一级**
  （`_isAdBlock` 用 hostSuffixes / segmentUrlRegex / 时长区间 / requireDiscontinuity / minimumSignals 打分），
  在 `lib/services/proxy_server.dart:473-477` + `:520-522` 接线。
  **唯一的保护是 `ad_rules.dart:285` `if (removed == 0) return ...`——只保护「没删」，不保护「删多了」。**
  零启发式、零比例守卫（`grep '0\.3|0\.5|totalSegments|ratio'` → 无比例命中）。
- **判定：分两步走，先做安全阀。**
  - **第一步（P0，已实施）**：现有规则路径采用累计移除大于 50% 和媒体清单结构校验回退；30% 是多级启发式的单级限额，不生硬套到用户规则级（否则现有 1/3 广告清洗也会被取消）。规则写宽了可能删到正片，
    而且症状是「少了一段」而不是「报错」，用户根本归因不到是去广告干的。
    同时借它「只对点播清单生效」的口径（含 `ENDLIST` 才清，直播清单显式挡掉）。
  - **第二步（P1）**：新增 `lib/core/m3u8_purify.dart` 放五级启发式，规则级优先、启发式兜底，**默认关**。
- **不要丢我们更强的地方**：`ad_rules.dart:271-275` 显式保留 `KEY/MAP/SESSION-KEY`，比它的 `_isSegmentTag` 白名单更明确，保留。
- **风险**：`docs/reference/win-box-borrowings.md:405-406` 已写过同一风险（「默认关是刻意设计，必须照抄」）。
  MisaTV 的 Flutter 版把那条 TS 注释变成了 19 个可跑单测，**结论不变、证据更硬**。

### P0-2 · 图片缓存上限 + 网格海报按卡片宽解码

- **MisaTV 怎么做**：`lib/main.dart:61-65` 全局 `maximumSizeBytes = 48MB` / `maximumSize = 220`；
  并在**每个图片位按用途定档**：卡片 `poster_card.dart:283 cacheWidth: 320`、详情背景 `960`、历史 `200`、台标 `128`。
  注释写明理由：Flutter 默认 100MB/1000 张对桌面浏览过大，按卡片尺寸解码可让长浏览后内存不持续攀升。
- **我们现状**：`grep -rn 'imageCache' lib/` → **零命中**（跑的是默认 100MB/1000 张）。
  `PosterImage` **已支持** `cacheWidth`（`lib/ui/app.dart:2097,2126,2190`），但 25 个调用点里只有
  `recommendation_info_dialog.dart:221` 和 `search_result_view.dart:115` 传了值；
  **首页/分类/搜索的主网格没传**（`lib/ui/browse_pages.dart:1094` `PosterImage(url: vod.vodPic)`）。
- **判定：借鉴（机制）。** 这不是架构差异，是一个遗漏。网格卡宽由 `lib/ui/layout_scale.dart:45` 给出
  （185~263 逻辑像素 × DPI），而海报源普遍 1000px 以上；不设 `cacheWidth` 时按原图解码，单张位图内存差一个数量级。
- **落点**：`main.dart` 设上限（数值按我们自己的浏览深度定，不照抄 48MB）；`browse_pages.dart` 网格补
  `cacheWidth: (cellWidth * devicePixelRatio).round()`，与 `DESIGN.md:304-312`「列宽由可用宽度推出」是同一套数值。
- **风险**：低。上限设太小会让滚动回退到重复解码，需要一次真实滚动手感确认。

### P0-3 · 补一档「加固壳」判定——这条在修我们现有的错误结论

- **MisaTV 怎么做**：不看扩展名，看**壳的形状**（`jar_spider.dart:1804-1826`）：
  `.so`/`.guard` → 是壳；无 `.so` 但 `assets/*.bin` + dex 里有入口 → 也是壳；
  只有 `classes.dex` 但 dex 字节里有 `DexNative|BaseSpiderGuard|Shinidie` → 还是壳。
  识别出来之后才决定走 4 档降级。
- **我们现状**：`lib/services/jar_intake.dart:333` 只看 `base.endsWith('.so')`；
  `JarVerdict` 七档（`:32-60`：desktopReady/sourceReady/translatableDex/androidJar/nativeLibrary/missingEntryClass/malformed）
  **没有「加固壳」这一档**。`grep 'DexNative|BaseSpiderGuard|Shinidie|aowu'` 于 `lib`+`sidecars` → **全 0**。
- **这是一处导入判定风险（另有直播 Header 等问题，见 §5）**：无 `.so` 的新壳（`assets/*.bin` + dex 里的 DexNative）
  会落进 `translatableDex` → 转译成功 → 加载时才炸 `UnsatisfiedLinkError`。
  **这比直接拒绝更差**：用户看到的是「转译过了然后崩」，而不是「这个源 PC 端不支持，原因：加固壳」。
- **判定：借鉴「识别 + 分档」这一层，不借鉴 unidbg 本体。** 改动只是判定函数 + 一档枚举 + 文案 + 单测。
- **不借鉴 unidbg 的理由**（与 Electron 版 §7.1 一致，Flutter 版没推翻）：换来的是 ~39MB 按需下载 +
  每只 768MB 模拟器进程 + **x64 已知崩溃**（`jar_spider.dart:3144` 自述 `toIntPeer(null)`、
  `:4129` 认 `EXCEPTION_ACCESS_VIOLATION`）+ 必须串行闸门（`:3417-3423`）；
  而它换来的站点集合恰好是 `PRODUCT.md` 口径里「以实际测试为准」那一段。
  **且它的快路径依赖不入库的第三方解包产物**（见 §0.1），我们无法在许可清晰前提下复制。

---

## 4. P1：低成本功能补齐（按 ROI 排序）

| # | 项 | MisaTV 落点 | 我们现状 | 成本 |
| --- | --- | --- | --- | --- |
| 1 | **直播导出 TXT/M3U** | `live/live_export.dart` 53 行纯格式化；UI 在 `live_page.dart:249-262` | `core/live_playlist.dart` **只读不写**；`grep '导出' lib/ui/live_page.dart` → **0** | 53 行 |
| 2 | **直播回看补 3 种类型** | `live/catchup.dart:50,58,63`：`shift|timeshift` / `xc|xtream` / `flussonic` | `core/live_catchup.dart` 只有 default 与 append 两态（`:39,:155`） | ~60 行 |
| 3 | **字幕「疑似 AI 摘要」体检** | `subtitle/subtitle_health.dart` 134 行纯函数：`kSummaryGapSeconds = 15`，判平均间隔不判条数 | 零命中。用户拿到 36 秒一条的摘要字幕时界面与正常字幕完全一样 | 134 行 |
| 4 | **屏显网速平滑** | `player/network_speed_smoother.dart` 52 行：7 次采样取中位数 + 非对称 EMA（升 0.22 / 降 0.45）+ >1Gbps 视为单位异常 | `lib/ui/player_controller.dart:477+` 原始值直上屏（格式化讲究，无滤波） | 52 行 |
| 5 | **常量时间比较 token** | `lan/lan_server_io.dart:148-161` 逐字节 XOR 累加 | `lib/core/realtime_sync.dart:1430` 用 `!=` 直接比较 | 几行 |
| 6 | **WebDAV 只读直连** | `services/webdav/dav.dart`(166)+`dav_service.dart`(275)：**列目录走 Dart，取流走中继注 `Authorization`**（`local_relay_io.dart:454-458`） | 全仓 **零命中**；但前置件齐备（`xml` 依赖、`ProxySession.authorization`、DPAPI vault） | ~450 行 + 测试 |
| 7 | **启动预热（jar 源）** | `jar_spider/warmup_plan.dart:32-59` + `app_state.dart:1601-1631`：上限 3、按失败次数升序、**串行**、运行时未装整段跳过、失败静默不写健康度 | 零命中；但 `docs/phase9/README.md:249` 里 P1-6 的暂缓理由「没有常驻进程池」**已过期**（见 §5-2） | ~100 行 |
| 8 | **蜘蛛调试会话** | `spider_debug/spider_debug_service.dart` 363 行纯状态机：**注入时钟** + generation 递增丢弃旧回调 + 单飞行（idle 检查） | 只有被动诊断（站点健康历史、播放诊断、屏显），**没有「对某源跑一次看原始返回」** | 中 |
| 9 | **弹幕多源：28 个内置接口 + danmaku-api v2 三段式** | `danmaku/danmaku_models.dart:44-96`（28 条公开 URL）+ `danmaku_service.dart:1-3` 三段式协议 + 会话级源健康冷却（首次 2 分钟 / 重复 10 分钟）+ 限并发 4 | `core/danmaku_settings.dart:7,15` 只有**单一 `apiUrl`**；`grep 'cynnsq|danmu\.'` → 0；协议是自建单跳 JSON | 中 |
| 10 | **关闭 Windows Impeller** | `windows/runner/main.cpp:22-27` 实测注释：空载 600MB+ → Skia ~140MB | `grep -i impeller` 于 `windows/ lib/ pubspec.yaml` → **零命中**；CI `FLUTTER_VERSION: "3.47.5"` 同属默认 Impeller 的那一版 | 一行 + **必须先量基线** |

**逐条的前置条件与差异点（不能只说「类似」）**

- **#1 直播导出**：它是**双向对称**的——解析能读 `#genre#`，导出能写回同格式，导出物可被自己再导入（导出即备份）。
  我们只读不写，用户整理好的分组无法落盘分享/编辑。自己写 53 行，无需借它的代码。
- **#2 回看类型**：缺它们的直接后果是 Xtream / Flussonic 系直播源**回看按钮永远不出**
  （`live_page.dart:287-300` 生成失败就 toast「回看参数不完整」）。
- **#3 字幕体检**：关键是**判「平均间隔」而不是「条数」**（104 条 / 3753 秒照样能抓）。
  且它是「加载成功但内容不对」，我们现有的 `AppErrorKind.subtitle*` 失败提示机制**覆盖不到**。
  顺带可借 `pick_entry.dart` 的包内挑条打分（扩展名分 40/30/20/5 + 片名匹配 + 集号匹配），
  我们 `subtitle_asset_store.dart:179-185` **只按 ass 优先 + 文件名排序**，明显更粗。
- **#4 网速平滑**：我们解决的是「没有数据」与「单位口径」，它解决的是「有数据但抖」。
  mpv 的 `cache-speed` 在关键帧突发时会瞬间冲高，没有中位数过滤必然出现「4000M/s」。
- **#5 token 比较**：注意我们的安全模型**比它强**（白名单 **或** token 双门槛，它只有 XOR token 一档），
  所以这一项提升的绝对值小于它那次改动；但同一个文件 4 个端点共用这段逻辑，改一处即可统一。
- **#6 WebDAV**：**这是性价比最高的一项**。411 行里没有可争议的独创算法，真正有价值的是职责切分
  ——「列目录走 Dart，取流走中继注 header」，正是我们已有的架构（`core/proxy_policy.dart:266` 已有 `authorization` 字段）。
  不越产品边界（用户自己的 OpenList/AList/Nextcloud/群晖，只读，凭据走已有 DPAPI）。
  **一处必须自己判断而不是照搬**：它的 `parseDavMultistatus` 解析失败**返回空数组**（`dav.dart:79`），
  与 `PRODUCT.md:113`「宁可显式报错，也不静默返回空列表」冲突——我们应返回可诊断失败，
  「空目录」与「解析失败」必须分开。
- **#7 预热**：该借的**只有调度层**（延迟 N 秒 → 按健康度排序 → 串行拉前 K 个 → 失败静默）。
  **不要借它的池形态**：它上限 3 只且必须串行，是因为「加固壳在池化线程上解析不出站点基址」
  （`spider_host.dart:153-155`）——这是它自己的病理；我们的 `SidecarServer` 有固定线程池，
  照搬「3 只」会白削并发。**我们真正缺的是空闲回收**（见 §5-4）。
- **#8 调试会话**：三条设计要点值得照搬（注入时钟 / generation / 单飞行），
  但**落地形态必须改**：做成 `diagnostics_pages.dart` 里的本地页面直接调 `SourceService`，
  **不要做成 HTTP 路由**——我们没有也不打算给 jar 任何 loopback 端点（见 §6-1），省掉整层鉴权。
- **#9 弹幕多源**：分层借——① **28 条接口清单是公开 URL，非可版权表达，可直接采用**；
  ② 但**必须连 danmaku-api v2 三段式协议一起借**（`{base}/api/v2/search/anime` → `/api/v2/bangumi/{id}` →
  `/api/v2/comment/{epId}?format=xml`），否则拿到清单也没用（我们的是自建单跳 JSON）；
  ③ **必须补 B 站新版 JSON 弹幕格式**（`{count, comments:[{p,m}]}`）——我们的 `sniffDanmakuFormat`
  （`core/danmaku.dart:328-341`）只认 `<` 开头与行式文本，认不出 `{`，28 个源里返回 JSON 的会全部解析失败；
  ④ 源健康冷却 + 限并发 4 要一起上，否则多源「死源拖慢整次搜索」立刻出现
  （站源侧的同类坑见 `win-box-borrowings.md:159`）。
  **不要借轨道分配**：我们的 `DanmakuTrackAllocator`（`core/danmaku.dart:517-600`）有「活动窗口独占」模型，
  比它的 `danmakuLaneCount`（纯除法）更完整。另：**它有 0 处直播弹幕，我们有**
  （`core/live_danmaku.dart` 299 行 + `live_danmaku_session.dart` 359 行）。
- **#10 Impeller（未实施）**：**必须带三个前提，不能当「一行代码直接合并」。**
  ① `flutter::ImpellerSwitch::Disabled` 是 Windows C++ wrapper 的符号，**本机没有 Flutter SDK，
  `windows/flutter/ephemeral` 是空的，符号存在性未验证**（只能查到 Linux GTK 侧同名能力的头文件）；
  ② **必须先量基线**——`docs/webhtv-pc-design.md` §22.2 的验收项只有「内存无持续增长异常」，
  我们**没有任何绝对基线记录**；
  ③ 我们的 UI 明显更「平」（`BoxShadow` 1 vs 7、`LinearGradient` 3 vs 21，`DESIGN.md:368`「精确、平坦、信息优先」），
  它的 600→140MB **不能按同比例套到我们身上**；但 `ClipRRect` 数量相当（25 vs 23），
  SDF 离屏缓冲按**整窗尺寸**分配，仍有收益空间，幅度未知。
  另：它特意写了「注释必须 ASCII，否则 `/WX` + C4819 编译失败」——**我们这条不适用**
  （`windows/runner/CMakeLists.txt:24-28` 已给 runner 加 `/utf-8`），抄的时候别连这条一起抄。

---

## 5. 顺带查出的我们自己的问题（不是借鉴项）

这一节是本次调研的副产品，**独立于是否借鉴 MisaTV**。

| # | 问题 | 证据 | 严重度 |
| --- | --- | --- | --- |
| 1 | **`extras['ua']` 是只写字段**：M3U 里的 `http-user-agent` 被解析后无人消费 | 写：`core/live_playlist.dart`；播放读 `header.asRequestHeaders`（`live_playback_session.dart:149`、`live_page.dart:67`），`extras` 从未合并。已改为声明值同时落成请求头，并补上 JSON `header` 对象解析与 `ua`/`referer`/`origin` 兜底 | **中 → 已修** |
| 2 | **`docs/phase9/README.md:249` P1-6 的暂缓理由已过期** | 原文「PC 的 `csp_*` 走按次启动的 JVM sidecar，没有常驻进程池」；实际 `spider_process.dart:1247 hostFor` 按 siteKey 常驻、`:1270 shutdownAll` 仅在 `app_state.dart:7518` 退出时调用 | **低**（文档误导排期） |
| 3 | **局域网客户端受环境代理影响**（原判据部分不成立，已修正） | 应用自己的出站设置**不会**流到这两个客户端（`sync_state.dart:229-230` 自建实例）；真正的泄漏源是 Dart SDK 默认 `HttpClient.findProxyFromEnvironment`（经 `HttpOverrides`）。已改为 `createLanHttpClient()` 显式 `DIRECT`，`fetchLiveSources` 仍走普通出站客户端 | **中 → 已修** |
| 4 | **sidecar host 无空闲回收** | host 原本活到应用退出。已加 5 分钟空闲回收，且只回收「进程存活、无在途请求、未交付环回播放依赖、manifest 未声明 `localProxy`」的宿主 | **低 → 已修** |
| 5 | **历史合并的平局策略不收敛** | `core/android_sync.dart` 同毫秒原本一律 skip，`A←B` 与 `B←A` 各自保留自己那份。已改为按 `(positionMs, durationMs, vodName, episodeName, vodPic)` 规范化内容序破平（不用 `eventId`，避免改 Android wire 契约），批内重复先收敛再裁决 | **低 → 已修**（PC 侧；Android 对端逻辑未改） |

---

## 6. 待决策（产品/法务，必须由人拍）

### 6-1 · 加固壳 / unidbg 整条线路：做还是不做？

**这两条必须一起拍，否则白做。**

- 做 = 必须同时做三件：**常驻 JVM** + **宿主代理端口回写** + **payload 候选信任分级**。
  理由（MisaTV 实证）：壳源的 `playerContent` 返回的播放地址是**指向它自己 JVM 的本机地址**
  （`spider_host.dart:5-11`「一次性进程打完结果就 `System.exit`，地址随即失效」），
  且壳会硬编码 `127.0.0.1:9978` 甚至吐 `-1`（`:332-360` 用 `-?\d+` 正则改写）。
  **我们三套 sidecar 目前不监听任何端口**（`grep 'HttpServer|ServerSocket|bind('` → 全空），
  这个架构里没有「站源自建本地流」的概念。
- 不做 = 建议在 `docs/adr/0002-android-csp-jar-compat.md` 补一句边界：
  「本 ABI 不承载站源自建的本地流服务，依赖 `127.0.0.1:<壳内端口>` 播放地址的源在 PC 端明确不支持」。
- **我方建议：不做。** 成本（39MB 下载 + 768MB/只 + x64 已知崩溃 + 串行闸门 + 不可分发的第三方产物）
  与收益（一小段「以实际测试为准」的长尾源）不匹配。**但 P0-3 无论选哪边都要做**——它修的是错误结论，不是缺功能。

### 6-2 · jar 源的网盘凭据通道，算不算「绕过访问控制」？

MisaTV 的 `spider_env.dart` 把用户已登录的 cookie **写给它自己的 spider** 读（5 条通道，
`<spiderCache>/files/TV/.quarkcookie`、SharedPreferences 种子、`tvbox-ext`、`tvfan/Cloud-drive.txt`、
`TVBox/{bili_cookie,115}.txt`），并有一条反直觉的纪律：**解绑要写空文件，不能删文件**
（文件缺失时中继回 404 + 中文正文「文件不存在」，蜘蛛不校验状态码，把那段中文当 Cookie 拼进请求头）。

- 若**不算**越界：可借通道清单与那条「写空文件」纪律。补上后，**用户自己配了网盘 cookie 的 jar 源**就能工作。
- 若**算**越界：整条线保持现状，只保留 `core/pan_check.dart` 的「如实说判不出来」。
- **无论哪种，都不借「原生解链」（quark/uc/baidu_native，2,442 行）与「UC TV Token OAuth」（257 行）**——
  它们同时越过产品边界与 `pan_check.dart:9-10` 的工程边界，且硬编码客户端密钥换版即废。

### 6-3 · 要不要支持「壳内硬编码 `127.0.0.1:9978` 的 jar 蜘蛛」？

MisaTV 的中继路由表里，只有两条是 jar 的**硬编码依赖**（其余 `/img` `/media` `/pkg` `/ext` 都是服务它自己的功能，可选）：

- **`/file`**：哔哩系蜘蛛的 ext 直接写 `http://127.0.0.1:9978/file/TVBox/bili_cookie.txt`，由中继读走这段文本当 Cookie
  （`spider_env.dart:153-171`）。还有一条反直觉纪律：**未配置时也要写成空文件**——文件缺失时中继回 404 + 中文正文，
  蜘蛛不校验状态码，会把那段中文当 Cookie 拼进请求头。
- **`/proxy?do=ck`**：小白/加固壳启动时探 9978~9999 的这个路由，**应答体必须等于 `ok`** 才认宿主代理
  （2026-11-21 复核：硬编码只在**没有宿主钩子**时才会走。Wex 的 `ProxyOrigin.init()` 会先反射宿主
  `com.github.catvod.Proxy.getPort()` / `getUrl(boolean)`，失败后才扫描 **8964..9998**，最后兜底 9978。
  所以 PC 端不必抢 9978——提供会话级钩子即可，端口可协商；此前「必须占 9978」的结论过强。）
  （`local_relay_io.dart:1079-1083`；之前这里回 400，壳拿到的端口是 -1，播放器随后报 invalid or unsupported media）。

我们现状：`services/proxy_server.dart:95` 只有 `/p/` 一类改前缀路由（`:205-208` 非该前缀一律 404）；
`grep "'/file'|'/proxy'"` → 0；`grep 'tvbox.proxy|proxy.entry|proxy.port'` 于 `sidecars`+`lib` → 0；
三套 sidecar 不监听任何端口。即**我们的桌面 JVM ABI 目前不给 jar 任何「中继地址」概念**。

- **要**：按站源实际 ABI 接通代理发现与流式取流；Wex 可用宿主 `Proxy.getPort/getUrl` 钩子注入真实随机端口，
  不要求抢 9978。`/file` 是另一条凭据通道，不是每个壳源播放的必要条件，本轮代理扩展不据此开放文件读取。
  对确实没有钩子、只吐旧端口的其它站源，才需要在已验证的来源/会话范围内重写地址——
  MisaTV 的做法是**先试 9978、失败回落临时端口**并**改写壳吐出来的宿主地址**（`spider_host.dart:332-360`
  用 `-?\d+` 连 `-1` 也认），这说明「抢到 9978」不是唯一解。
  **端口归属要先定**：`services/sync_server.dart:143` `startPort` 从 9978 起、`:145 bindAddress = '0.0.0.0'`，
  但同步服务默认关闭（`state/sync_state.dart:272`），所以平时 9978 是空的——冲突只在用户开了安卓接入时发生。
- **不要**（继续 ADR-0002 的「只吃桌面 jar / 可转译 dex」）：这两条路由**没有任何收益**，只会扩大攻击面。
- **注意**：加路由时沿用我们自己的安全层（`core/proxy_policy.dart`），**不要照抄 MisaTV 的宽松度**——见 §2 末行。

### 6-4 · 独立播放窗口 / 「一起看」，做不做？

- **独立播放窗口**：MisaTV 用 `desktop_multi_window` 开第二套引擎，代价是 199 行 session 序列化 +
  两条 IPC 通道 + 载荷落文件 + **历史双写**（`sync/history_sync.dart:3` 自述）。
  我们 `grep 'desktop_multi_window'` → 零命中，全屏是单窗内四层浮层。
  **ROI 为负**：要在一套单例 `AppState` 上劈出第二套引擎生命周期。**不是「沉浸观影」的必要条件**
  （沉浸 = 无干扰，已由全屏 + 控制栏自动隐藏 + 浮层实现；独立窗口卖的是「主界面同时可用」）。
- **一起看**：**先纠正一个前提——我们已经有 LAN 面，不是没有。**
  `services/sync_server.dart:145 bindAddress = '0.0.0.0'`、`:189 HttpServer.bind`、
  `:376-379` 明确对用户披露监听范围；默认关闭、白名单 **或** token 双门槛、天然不回 CORS 头。
  同看只是在这个已存在的端口上多一个 `/party` 类端点，**不撞 `PRODUCT.md:55`**（那条约束的是回环代理）。
  撞的是 `PRODUCT.md:18` 的用户假设（单人 vs 多人同看）。
  若做，可直接照搬三组经验参数：发布 800ms 节流 / 位置差 <1200ms 视为无变化 / 观众 4s 与 8s 双死区。

### 6-5 · Kazumi 规则源 + 按源家族放宽 TLS？

MisaTV 有 `type=5` Kazumi 规则源（1,308 行）与配套的 `createKazumiHttpClient`
（`badCertificateCallback = (_,_,_) => true`，只对该源家族放开坏证书）。
我们零命中，且 `core/config_loader.dart:297-303` 现在把 `HandshakeException` 一律转成可重试错误并如实上报——**刻意的保守**。
**建议不在本次推进**：单独存在一个坏证书客户端没有调用方，必须先决定「要不要接 Kazumi 规则源」。

---

## 7. 明确不做

| 项 | 理由 |
| --- | --- |
| unidbg / 加固壳解包本体 | §6-1 |
| 原生解链（quark/uc/baidu_native）、UC TV Token、迅雷云盘 | 越过 `PRODUCT.md:79-81`；硬编码密钥换版即废 |
| BT / 磁力整条线（aria2c + piece 门控 2,661 行） | Electron 版 §7.2 已判（版权边界），Flutter 版没改变它，只是把同一件事做得深得多。**若将来做「本地取流」**，唯一不可绕过的一步是 **piece 门控**（喂字节前必须确认该区间 piece 已校验落盘，否则读到稀疏零 = 「能打开但花屏」，比打不开更难诊断）——这条应写进将来的设计文档，不是现在做 |
| `hyms_native.dart`（饭太硬补链，337 行，硬编码签名密钥） | 单站点专有加密，正是它自己 README 承认的「无解源」那一类；换站即废 |
| `bili_dash_fallback.dart`（135 行） | 是「它内核没有 DASH 解复用器」的补救。我们走 media-kit，DASH 支持面必须按自己的内核实测；照搬最坏会把本来能播的 DASH 主动降级。**记一条待验证**：我们内核遇到那类 URL 是什么行为 |
| `part` + `extension` 拆播放器页 | 绕过可见性而非分层（§2 末） |
| 台词（一言）/ 老板键 / 托盘 | 台词撞 `PRODUCT.md:108`「不得编造内容」与 `DESIGN.md:368`「信息优先」；老板键 Electron 版 `:505` 已判「纯产品偏好」 |
| 沉浸观影 / 大屏焦点树 | 产品决策已定（§2）；仅 `focus_memory.dart` 三条簿记规则值得留档备将来 |
| 按源家族放宽 TLS（单独做） | §6-4，无调用方 |

---

## 8. 建议顺序

1. **P0-1 安全阀** → **P0-3 壳判定** → **P0-2 图片内存**（三件都独立、可单测、无决策依赖）
2. 顺手修 §5 的 5 条（1、2、3 是真实缺陷，4、5 只记录）
3. P1 按 ROI：#1 导出 → #2 回看 → #3 字幕体检 → #4 网速平滑 → #5 token 比较（都是小改动）
4. 再做 #6 WebDAV 与 #7 预热（中等改动，各自需要一个设计）
5. #8 调试面板与 #9 Impeller 放最后：#9 先量基线再说
6. §6 的四个决策项，等产品/法务拍

---

## 9. 证据与可复现检索

三份完整调研报告（含逐条 `file:line` 与命令输出）：

- `/tmp/misatv-notes/spider-runtime-pan-bt.md`（718 行：Spider 运行时 / 加固壳 / 网盘 / BT / WebDAV）
- `/tmp/misatv-notes/player-relay-live-subtitle-danmaku.md`（529 行：中继路由 / m3u8 / 直播 / 字幕 / 弹幕）
- `/tmp/misatv-notes/misatv-product-findings.md`（331 行：状态分层 / Impeller / LAN / CI / UI 形态）

关键零命中检索（本文所有「我们缺」结论的可复现命令，均在本仓库根执行，排除 `node_modules`）：

```bash
grep -rIn 'webdav\|PROPFIND' apps packages sidecars docs --exclude-dir=node_modules | wc -l   # 0
grep -rn 'imageCache' apps/desktop-flutter/lib/                                                  # 无输出
grep -rni 'impeller' apps/desktop-flutter/{windows,lib} apps/desktop-flutter/pubspec.yaml         # 无输出
grep -rn 'purify\|minority\|SCTE\|CUE-OUT\|isPlayableMediaPlaylist' apps/desktop-flutter/lib/    # 0
grep -rn '导出' apps/desktop-flutter/lib/ui/live_page.dart                                       # 0
grep -rni 'LiveUaPolicy' apps/desktop-flutter/lib/                                               # 0
grep -rni 'desktop_multi_window' apps/desktop-flutter/lib apps/desktop-flutter/pubspec.yaml       # 0
grep -rn 'DexNative\|BaseSpiderGuard\|Shinidie' apps sidecars --include=*.dart --include=*.java   # 0
grep -rn 'HttpServer\|ServerSocket\|bind(' sidecars/spider-host-jvm/src/ sidecars/spider-host-js/host.js sidecars/spider-host-python/*.py  # 空
grep -rn 'warmUp\|预热' apps/desktop-flutter/lib sidecars --include=*.dart --include=*.py          # 仅 1 处注释
```

**未验证项（本文不做断言的部分）**：

1. `flutter::ImpellerSwitch::Disabled` 在 Flutter 3.47.5 的 Windows C++ wrapper 中是否可构建、以及它对 Windows 实包的影响仍未验证；本机实际上有 `.tools/flutter` Linux SDK，不能以“没有 SDK”解释。Impeller 属于本轮明确不扩展的 P1。
2. 我们的真实内存基线（无任何测量记录）；
3. 关窗是否真的残留进程（无 `0xc0000409`/APPCRASH 记录，症状未观测到）；
4. LAN 同步在开启出站代理时是否真被代理带走（只从 `http.Client()` 与 `findProxy` 的装配关系推断）；
5. 弹幕 28 个内置接口的当前可达性；
6. MisaTV 的 `/file` 在我们的 Windows 作业对象隔离与只读 sidecar 目录模型下是否可行。

---

## 复查：2026-11 MisaTV 近期 jar 更新的采纳与回绝

一句话：**三次提交里只有「JVM 垫片补全」这一层进得来**——加固壳修复与 Android 原生运行器都被本项目自己的边界挡在外面，
并发与诊断增强我们已有等价或更强的机制。

- 复查范围：基线 `f91cc41`（§1）之后与 jar 源相关的三次提交。播放器、网盘/BT、直播/弹幕等章节结论**不变**（见 §2–§8）。
- 结论口径不变：依旧**依据公开协议独立实现，不复制 MisaTV（GPL-3.0）代码**（许可红线见 §0.1）。

### A. 三次提交的采纳 / 不采纳对照

| 提交 | 做了什么 | 判定 | 理由 | 落点 |
| --- | --- | --- | --- | --- |
| [`adb37b8`](https://github.com/yagami-hue/MisaTV/commit/adb37b8462b07f55b9817e85cd5767b021fa36c6)`feat(android): 原生 jar/DEX 蜘蛛运行器`（2026-11-18） | Android 端用原生运行器跑 jar/DEX 蜘蛛，改动集中在 `android/` 与 `lib/services/jar_spider/jar_spider_android.dart` | **不采纳** | 移动端形态：依赖 Android 运行时与原生装载，与 PC 端的进程隔离模型无关 | 无 |
| [`dd34424`](https://github.com/yagami-hue/MisaTV/commit/dd344243f80bfbd20a0a3756b62d47ce122734df)`fix(shell): 修复加固壳两个缺陷：播放卡住、站点只剩分类`（2026-11-18） | 改 `assets/jvm/src/SpiderHost.java`：翻正 fty 壳的 `merge.uA.yq` 布尔门控（旧写法翻的是非布尔的 `merge.cn.yq`，静默 no-op）；探测 stubs.jar 里的 `com.github.catvod.spider.HideUtils`；对 wex/AiNew 系载荷的 `<spiderCacheDir>/files/AiWex/siteconfig` 做域名预检（只保留 2xx 且含 module-item 的候选，避免竞速选中 403 域名） | **不采纳** | 本项目不运行加固壳：壳 jar 判 `JarVerdict.shellGuard` 且不落盘（`apps/desktop-flutter/lib/services/jar_intake.dart:454`、`apps/desktop-flutter/lib/services/spider_router.dart:560`；ADR-0002 §3.4.3） | 无 |
| [`90e7b65`](https://github.com/yagami-hue/MisaTV/commit/90e7b654281ff1ec981759c19770b8bd7abe4a23)`chore: 进程回收、JVM 垫片补全与网盘/搜索增强`（2026-11-20） | 新增 `assets/jvm/src/stubs/android/net/Uri.java`、`assets/jvm/src/stubs/android/util/LruCache.java` 与 `assets/jvm/stubs.jar`；另加 JvmStderrFilter、一次性 JVM 全局并发闸门（`_oneShotMax=4`）+ 搜索轮次作废 | **部分采纳** | 垫片补全采纳（见 §B）；诊断与并发增强不采纳（见下表） | `sidecars/spider-host-jvm/src-android-shim/src/android/` 下的 `net/Uri.java`、`util/LruCache.java` 等 |

`90e7b65` 按条拆开：

| 子项 | 判定 | 理由 / 落点 |
| --- | --- | --- |
| `android/net/Uri`、`android/util/LruCache` 垫片 | **采纳**，并按引用扫描扩到 6 个类 | 见 §B |
| JvmStderrFilter（折叠 JVM 堆栈、异常降频） | **不采纳，留作后续可选** | 诊断增强，不是 jar 源能力；现在动它会改日志口径与既有诊断链路，属于独立改动 |
| 一次性 JVM 全局并发闸门（`_oneShotMax=4`）+ 搜索轮次作废 | **不采纳** | 本项目已有等价或更强的机制：`apps/desktop-flutter/lib/services/spider_process.dart` 的 idle 回收 + 播放 pin、按 siteKey 常驻、`shutdownAll` |
| 进程回收 | **不采纳** | 同上，已由 idle 回收覆盖 |

### B. 采纳的部分：垫片补全，按「实测可达闭包」扩

- 新增 6 个类：`android/util/Pair`、`android/net/Uri`、`android/util/LruCache`、`android/os/Build`、
  `android/os/Bundle`、`android/os/SystemClock`；落点 `sidecars/spider-host-jvm/src-android-shim/src/android/`（按包路径分目录）。
- 依据三条，缺一条都不补：
  1. MisaTV `90e7b65` 的 `Uri` / `LruCache`——同一形态的缺失已经被人踩过；
  2. 真实转译包 **1227 个类**的引用扫描：出现 `android/net/Uri`、`android/os/Build$VERSION`、`android/os/Bundle`、`android/os/SystemClock`；
  3. 仓库内既有登记：`sidecars/spider-host-jvm/src-android-shim/src/android/database/Cursor.java:82-83`
     写着「`android.os.Bundle` … 需补」「`android.net.Uri`、`android.content.ContentResolver` 需补」。
- MisaTV 侧的两个症状值得留档，正是 ADR-0002 §3.4.3 第 1 条「点名缺失类、不静默降级」要拦住的东西：
  `Uri.getUserInfo` 缺失 → `csp_Eighteen` 的 `homeContent` 直接 `NoSuchMethodError`；
  `LruCache` 缺失 → `com.github.catvod.parser.merge.Y` 静态初始化 `NoClassDefFoundError`，异常被吞后首页 `items=0`。
- **独立实现**：只对齐「类名 + 被调用到的签名够用」这一层，按公开的 Android SDK 语义自己写，不复制 MisaTV 源码（§0.1）。
  这与 §0.1 的立场一致：抽象接口是公开事实，实现是自己的。

### C. 样例源实测：wex/shinidie 系加固壳，PC 端维持不支持

- 配置：`https://9280.kstore.vip/aiwex.json`。顶层 `spider` 为
  `http://oss4liview.moji.com/thd_file/2026/11/17/ff5af105e608d6389b89d59586515c70.jpg;md5;5a934007fb34ec762c2e7d25dbdc865d`
  ——伪装成 `.jpg` 的 jar，加 TVBox 的 `;md5;` 校验后缀；站点 `api` 全是 `csp_*Guard` 形态。
- 实下载该地址，是一个含 5 个条目的 zip：
  - `classes.dex`（40,024 B）
  - `META-INF/MANIFEST.MF`
  - `assets/wexguard_v7.so`
  - `assets/wexguard_v8.so`
  - `assets/wexshinidie.guard`（983,479 B）
- 该文件 md5 = `5a934007fb34ec762c2e7d25dbdc865d`，与配置声明的 `;md5;` 一致——拿到的是配置指向的那一份，不是被替换/截断的内容。
- 判读：这是 **wex/shinidie 系加固壳**。`classes.dex` 只是壳的加载层，真实 Spider 在加密的
  `assets/wexshinidie.guard` 里（零明文，非 zlib/gzip）。
- MisaTV 自己在 `assets/jvm/src/shell-shim/com/github/catvod/spider/DexNative.java` 的注释里也写明：
  这类加密载荷「只能由 ARM native 解密」，纯 Java 影子类只在已拿到解密产物时可用。**它的快路径同样绕不开这条**（§0.1）。
- 结论：PC 端维持「**如实判为 `shellGuard`、不落盘、不运行**」，与 **ADR-0002 §3.4.3** 一致；
  本轮**不改 ADR 状态**，§6-1「加固壳 / unidbg 整条线路」的待决策项不因这次实测推进——
  反而多了一条正向证据：壳内是加密载荷，纯 Java 转译没有输入。
- 未验证：`MANIFEST.MF` 与两个 `.so` 的字节数未取；`.guard` 的加密算法未逆向，本文不对其做任何断言。
### D. 后续实际落地（2026-11-21 更新，**修正 §A、§C 与 §6-1 的判定**）

- **加固壳 ARM 解包桥：已采纳并落地**。§6-1 与 §C 的原结论是「不做 / 维持不运行」，本轮在真实 wex 源上
  完成了可行性验证与产品化，形态与 MisaTV 一致：由用户点按钮**按需下载** unidbg 0.9.9（18 个 jar、
  约 40.7 MB、四镜像回退 + 逐文件 SHA-256 校验），解包器以 **JDK 单文件源码模式**运行、只解一次，
  payload 按壳 jar 的 SHA-256 缓存。决策、边界与代价见 [ADR-0002 附录 A](../../adr/0002-android-csp-jar-compat.md)。
- 因此 §A 表里 `dd34424`（加固壳修复）与 §C 末段「不运行」判定**部分作废**：我们仍然不复制其实现，
  但「PC 端不运行加固壳」不再是产品边界。
- 仍不采纳：`adb37b8`（Android 原生 jar/DEX 运行器，移动端形态）、JvmStderrFilter（诊断增强）、
  `_oneShotMax` 闸门与搜索轮次作废（本项目已有 idle 回收 + 播放 pin）。
- 新证据：真实 wex 源（`AiNewHuaJuan`）在桌面 JVM 上 `homeContent` 返回 5 个分类 + 条目；
  `--selfcheck` 1193 类 / 22 个加载失败（全是 Android UI 垫片缺口，未越 P1-2 边界）；
  `-noverify` 是这条通路的必要取舍（进程内校验网失效，隔离靠独立 sidecar + 作业对象）。
