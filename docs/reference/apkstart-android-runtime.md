# ApkStart 与可选 Android 爬虫运行环境：可行性调研

- 日期：2026-11-24；本轮只分析，不新增运行时、设置项或站源路由，不构建/启动模拟器。
- PC 基线：`e25e8b854328d5f6d3d5063cec044ad98328280e`；本地安卓上游：`997b0889b`（`/home/maple/Workspace/webhtv/dev1/webhtv`）。
- ApkStart 基线：`7e2c5503b908c0a4d55283c85244a8e09b2725c7`，`package.json` 版本 0.6.4。
- 方法：三个独立调研任务；Lead 复核关键源码、直接读取 Android 官方文档原文。公开项目说明与实现能力分开，未进行目标 JAR 的 Android 环境实跑。
- 路由记录：本 Session 未记录子代理路由 allowlist；三路显式使用 `deepseek-official/deepseek-v4.1-flash`，不是授权白名单保证。

## 1. 结论

**有帮助，但 ApkStart 更适合作为运行时安装/编排的参考，不宜直接作为我们默认托管的底座。**

推荐次序：

1. **优先支持用户指定已有 Android 环境**：已有模拟器、官方 AVD、手机/盒子或用户启动的 Android 容器。通过 ADB 接入并转发 HTTP，或者直接连接已支持的 WebHTV 安卓 T4 网关。
2. **随后提供可选、用户主动安装的本地 Android 运行环境**：Windows/macOS/Linux 以官方 Android Emulator 为跨平台候选；Linux 有条件增加 redroid provider。仍默认关闭，不将完整镜像塞入主安装包。
3. **不把“导入任意安卓镜像文件”当首版目标**：先导入连接配置或 AVD 引用；任意 qcow2/ISO/raw 文件没有统一的可启动、可访问 ADB、可运行爬虫保证。

这些是调研推荐，不是已实现功能，也不替用户决定最终产品交互。

## 2. 我们已经具备什么

### 2.1 PC 并不是完全不能运行 JAR

- 桌面 Java JAR 走 JVM；部分 Android dex JAR 已通过 dex2jar + Android shim 跑在 JVM 中（[ADR-0002 §3.4](../adr/0002-android-csp-jar-compat.md#34-方案-b-的实施边界p1-2)）。
- 已有特定加固壳的按需 ARM 解包与 payload 接入，不等于具备完整 ART/Android 环境。当前 `spider_router.dart:696–711` 明确：依赖壳内 native 能力的调用仍会报错。
- 普通 Android 原生库 JAR 仍被拒绝：`apps/desktop-flutter/lib/services/spider_router.dart:684–694`。
- 真实 Android API/UI、WebView、无法转译的 dex、其它壳族等是完整运行环境的主要潜在增量。不能因为文件后缀是 .jar 就把它们全部归入一种执行能力。

### 2.2 安卓端执行 JAR → PC 用结果：已有路径

本地安卓上游 `app/src/main/java/com/fongmi/android/tv/server/process/VodApi.java:152–167`：

- 明确对 `site.getType() == 3` 取 `site.spider()`；
- 调用 `homeContent/categoryContent/detailContent/searchContent/playerContent`；
- `:535–539` 把这些站点导出成指向网关自身的 type=4 HTTP 站点。

PC 端 `apps/desktop-flutter/lib/services/android_bridge_service.dart:119–142` 拉取 `/vod/api?ac=config`，复用现有桥接配置流程。

**因此：安卓设备自己已经配置好的 JAR 源，已有机制能供 PC 使用；新增模拟器不是补“type=3 一概不能用”，而是补“PC 单机自足”。** 这条结论来自代码与历史仓库证据，本轮没有重新连接真机测其当前可用性。

边界：既有 `/vod/api` 按配置/站点 key 查找源（`VodApi.java:128–139`），不提供“PC 发一个 jar + api + ext 就创建站点”的控制协议。后者需要新管理能力，不能把已有网关误当任意 JAR 执行器。

## 3. ApkStart 有什么价值、缺什么

| 方面 | 源码事实 | 对我们的判断 |
|---|---|---|
| 引擎 | 自管 Google Android Emulator/QEMU、platform-tools、Android 14 x86_64 镜像（`src/core/provision.js:92`）；加速探测涉及 WHPX/AEHD | 是真实 Android 环境编排，不是 JVM JAR 兼容库 |
| 安装启动 | 标准 `adb install` 与 `am start`（`src/core/adb.js:468–478,650–668`） | 可安装爬虫宿主 APK，不限于游戏；仍受 SDK/ABI/包条件限制 |
| 安装器 | 下载、校验、AVD/用户数据、快照、故障诊断 | 最值得借鉴的部分；无需搬应用图标、窗口嵌入或游戏键位系统 |
| 平台 | Electron + Windows exe/PowerShell/Win32 SetParent 等（`package.json:3–6`，`src/core/appwin.js`） | 不能当已验证跨平台方案；声明 linux 不代表核心路径已移植 |
| HTTP 通道 | 没有管理 guest HTTP 的 `adb forward`；QEMU 回退仅映射 ADB | 缺少现成通道，不等于技术不可行：我们可另建 ADB 转发 |
| 后台 | ApkStart 产品有意关闭 headless（`src/core/store.js:286`）；底层模拟器支持 `-no-window` | 不适合直接当无窗口守护进程，但不能推导“Android HTTP/JAR 服务一定需要窗口” |
| 外部环境 | `src/core/backends/index.js:5–17` 明确移除了第三方模拟器/已有环境接管 | 不是实现“用户指定已有模拟器”的最佳现成模板 |
| 许可证 | ApkStart 本体 MIT，第三方模拟器/镜像/驱动分别有自己的条款 | 可以研究/按条件复用 MIT 部分；不能把 MIT 视为整个运行环境的分发授权 |

它作为**用户自行安装的外部环境**，原则上可以通过 ADB 接入。需要核验它选中的 ADB server/设备、安装桥接 APK、端口转发与生命周期。默认 server 端口 5044 会被空闲端口探测修改（`src/core/emulator.js:1230–1232`），不应硬编码。

底层官方 Emulator 原文明确 `-no-window` 可在无显示服务器上运行，并通过 ADB/console 访问。ApkStart 的 VSYNC/渲染经验只说明其图形产品的取舍；涉及 WebView/UI 的具体爬虫仍需实测。

源码入口：[ApkStart 固定基线](https://github.com/RoutineMiku/apkstart/tree/7e2c5503b908c0a4d55283c85244a8e09b2725c7)。

## 4. 完整 Android 能扩大哪些场景

| 今天容易卡住的源 | 新环境带来的机会 | 不能省略的条件 |
|---|---|---|
| dex 转译失败、运行时加载 dex | 直接使用 ART/DexClassLoader，不再走 dex→class | guest API 版本、类依赖、动态下载路径仍须匹配 |
| `.so`、非已支持加固壳、native 辅助能力 | 在 Android 内使用真实原生加载链 | ARM32/ARM64/x86_64 ABI 必须匹配，或实际验证 native bridge；不是有 x86 镜像就能跑全部 ARM 库 |
| Context、SharedPreferences、资源等真实 Android 行为 | 不再依赖有限桌面 shim | 宿主 APK 必须正确初始化资源、权限、依赖与 App 级状态 |
| WebView 嗅探、登录、扫码或验证 | 可给用户显示安卓窗口并持久化 cookie | 不保证纯 headless；需要主线程、WebView 环境、活动生命周期与用户交互 |
| 设备 cookie/账号绑定的解析和网盘源 | 可在专用环境内保留会话并执行解析 | 登录态、签名 URL、出口 IP、播放器请求头、代理链路必须联测 |

**不能承诺全面兼容。** 设备完整性/DRM/模拟器检测、专有 SDK、ABI、特定 Android 版本和真实用户行为都可能形成新的限制。

尤其要把“搜索/详情返回成功”和“可稳定播放”分开：部分源还要访问 guest 内 `/proxy` 或中转分段内容；六个控制路由本身不解决媒体数据面。

## 5. 推荐的接入结构

`PC 现有站源路由 → HTTP 适配/会话 → Android 宿主 APK → ART 执行用户 JAR`

ADB 是安装、设备选择、启动与端口转发的**控制工具**，不是另一个 JAR 执行器。完整环境也不会自动把 JAR 变成 APK：还需要懂 CatVod Spider 基类、`csp_` 入口及 `ext` 初始化的宿主 APK。

可分两条落地路径：

- **先验证路径**：用户指定环境 → 安装/启动现有 WebHTV 安卓 APK → 安卓加载用户配置 → 复用已有 T4 网关导入到 PC。可以先验证价值，不必立即裁剪一个全新 APK。
- **更完整产品路径**：独立爬虫宿主 APK，加受控的 jar/api/ext 导入与会话管理。执行结果复用现有 `/init /home /category /detail /search /play` 契约（`lib/core/cat_http.dart:26–35,146–170`）；新增管理接口或 `proxyHttp` 必须显式协商，不能静默改变已有 ABI。当前 `proxyHttp={version:1,baseUrl,sessionControl:true}` 被严格限制在 JVM + localProxy + 双端 proxy capability（`lib/core/ipc_protocol.dart:489–515`，`lib/services/spider_process.dart:1419–1425`），不能不加适配就当 Android 数据面使用。T4 的现有流式 `/proxy` 则是另一条可参考路径（上游 `server/process/Proxy.java:31–79`）。

上游 `api/loader/JarLoader.java:236–244` 已有 DexClassLoader + `spider.init(App.get(), ext)`。这是**候选复用点**，不是零行代码/零成本：App、BaseLoader、Proxy、配置和 cookie 等依赖的裁剪仍未验证。

### 5.1 “导入本地环境”应分清三层

1. **连接已经运行的设备**：指定 ADB 路径/server + serial，或 IP/调试端口。使用 `adb devices -l` 枚举，所有操作指明设备；Android 11+ 现代无线调试需要配对，而传统 TCP 5555 不等于统一的无线调试协议。
2. **引用可启动的已有 AVD**：用户指定 Emulator/SDK 路径、AVD 名称及必要的 AVD 根目录。官方 `emulator -list-avds` 可枚举，`-avd` 可启动；数据仍属于用户，不擅自 wipe/覆盖。
3. **引用用户已启动的容器/虚拟机**：接入 ADB 或受支持的 HTTP 地址，不必接管 Docker/第三方模拟器内部文件格式。

可以用环境描述文件记录以上连接信息，但这是建议，不是“任意镜像格式”的承诺。raw/qcow2/vmdk/ISO 还依赖 kernel、boot/system/vendor/userdata、启动参数、网络和 adbd；容器 rootfs、AVD、虚拟机磁盘不能互换。[Device Manager](https://developer.android.com/studio/run/managing-avds) 的 Import Hardware Profiles 导入的是 XML 硬件描述，也不能作为“导入任意安卓系统镜像”的先例。

对“用户自备”与“我们安装并拥有”的环境区分所有权：前者只管理我们建立的会话/转发，不退出设备、不杀共享 ADB server、不删除用户镜像。

## 6. 更适合参考的项目

| 项目 | 能借鉴什么 | 定位/边界 |
|---|---|---|
| [scrcpy](https://github.com/Genymobile/scrcpy/blob/master/doc/connection.md) | serial/USB/TCP 设备选择、已有设备连接；需要登录时可显示安卓画面 | 跨平台设备接入/UI 工具，不提供 Android 系统，不执行 JAR 协议 |
| [Appium UiAutomator2 Driver](https://github.com/appium/appium-uiautomator2-driver) | 官方 [capabilities](https://appium.github.io/appium-uiautomator2-driver/latest/reference/capabilities/) 的 `udid/avd/adbPort/remoteAdbHost`：明确设备、已有 AVD 和 ADB server | `deviceName` 不负责选设备；借鉴能力模型即可，不必打包整个测试自动化栈 |
| [官方 Android Emulator](https://developer.android.com/studio/run/emulator-commandline) | AVD 枚举/启动、`-no-window`、ADB 访问与平台加速探测 | 本地可选运行时的跨平台候选；镜像/API/架构与许可需选择 |
| [redroid](https://github.com/remote-android/redroid-doc) | Linux 容器 Android、ADB TCP、amd64/arm64 镜像及 native bridge | 更适合已具备 Docker/内核条件的 Linux 用户，不作为 Windows 普通用户默认安装项 |
| [Waydroid](https://github.com/waydroid/waydroid) | 用户已有 Linux/Wayland 安卓桌面的复用 | Linux/LXC 路线，不能当 Windows/macOS 原生通用底座 |
| [Google Emulator 容器脚本](https://github.com/google/android-emulator-container-scripts) | 无头部署、自动化测试/CI 环境 | 官方指出 Docker Desktop on Windows/macOS 不支持该路径的 KVM 加速；这不是对全部嵌套虚拟化方案的否定 |
| [WebHTV 安卓上游](../phase5/design/01-android-t4-site-bridge.md) | 真实 Spider 加载、T4 站点配置导出与播放代理 | 与我们协议最贴近；本文代码事实来自本地修改版，不能自动外推到每一个 TVBox/FongMi 分支 |

Genymotion、Cuttlefish、docker-android、Android-x86 可研究，但本轮不建议作为首版默认底座：分别有商业授权/支持范围、开发测试型工具链、额外组件和部署条件、系统/ABI/镜像集成成本。尤其 [docker-android 的 LICENSE](https://github.com/budtmo/docker-android/blob/master/LICENSE.md) 明确为 Custom Apache 2.0，含 fork/数据处理附加条款，不能按标准 Apache-2.0 判断。缺少某平台官方部署说明不等于数学上的“不可能”。

redroid 官方说明已发布镜像含 `libndk_translation`，是有价值的候选；依然必须实测目标 JAR/native 壳。不同镜像压缩下载大小不等于安装占用，更不能据此臆测冷启动和常驻内存。

## 7. 最小验证计划，而非立即开发全部底座

1. 选一台已有 Android（优先现成 AVD/设备），安装现有安卓 APK，建立仅本机可访问的 HTTP 转发，走现有 T4 导入。
2. 对比桌面 JVM 与 Android：一个普通 dex 源、一个 native/壳源、一个 WebView/交互源、一个走代理的数据源。以用户实际目标源为准，不以虚拟 fixture 成功推断全部兼容。
3. 验证首页、分类、详情、搜索、解析以及完整播放；同时测试 cookie/请求头、分段请求、取消、断线重连、多站点并发和配置隔离。
4. 记录冷启动、恢复启动、常驻内存、磁盘占用、代理吞吐与 CPU；本轮没有这些实测数字，不承诺性能。
5. 证明新增覆盖和成本可接受后，再做用户点击安装与环境检测。核心执行/HTTP 接口先稳定，安装器不和站源业务耦合。

## 8. 不可跳过的安全和许可门槛

- ADB/HTTP 只暴露在受控连接上；redroid 官方明确不要将 ADB 端口暴露公网。单纯同源检查或固定端口不是强认证，管理和媒体面需要真实会话/token。
- 安装/启动操作要明确目标设备；用户自备环境可能含个人数据。不要连接到“碰巧扫到的设备”，不复用用户的敏感共享目录。
- APK 内运行不可信 JAR 仍具有该 App 的权限；进程/VM 隔离不是无条件的安全保证。账号/cookie/快照与 jar/ext 不提交到仓库。
- 不固定写死 9978：本地安卓上游 `server/Server.java:68` 从 9978 开始探测端口；服务地址应由配置/设备返回或受控探测确定。
- ApkStart 的 MIT 与 QEMU、Google Emulator、platform-tools、系统镜像、驱动许可分别核对。其 README 分发说明与部分构建材料不一致，不代替授权判断。
- Android SDK 条款 **2.1/2.2** 涉及接受协议与使用，**3.1** 还限定 SDK 授权用途；**3.4** 限制 SDK 部分复制/再分发，**3.5** 规定开源组件由各自开源许可约束。不能笼统认为所有组件都禁止分发，也不能认为改成“用户本地下载”就自动合规。

## 9. 核验记录与来源

- 官方原文已直接 HTTP 200 核对（不是只读搜索摘要）：[ADB](https://developer.android.com/tools/adb?hl=en) 的 `forward`、`-s/ANDROID_SERIAL`、`pair`；[Emulator 命令行](https://developer.android.com/studio/run/emulator-commandline?hl=en) 的 `-list-avds/-avd/-no-window`；[SDK 许可](https://developer.android.com/studio/terms?hl=en) 的 2.1、3.4、3.5。
- Lead 源码复核：ApkStart `package.json`、backend registry、headless 设置、ADB/server 与 QEMU 参数；本地 `VodApi` 的 type=3 分支和 type=4 导出、`JarLoader` 初始化、PC T4 拉取及 HTTP 契约、native/payload 判定。
- 外部源码抽样：scrcpy 连接文档、redroid README 的 ADB/native bridge/安全说明；Lead 已直接读取 Appium capabilities 原文，核对四个能力项及 `deviceName` 不选设备。docker-android 的自定义许可已直接 HTTP 200 核对。
- 任务验收：ApkStart、本地执行链、替代方案三个 brief 均为 run 2/3 接受；对首次过度结论退回同一代理修订，再独立复核。未消耗第三次运行，没有将子代理完成通知等同于通过。
- 发现并退回的结论风险：把“无内置转发”写成“不可能集成”；把“无官方路径”写成“不可行”；把 ARM/UI/登录/媒体链路写成无条件兼容或无条件不兼容；低估 APK 裁剪/路由成本。最终采用条件化判断，不提供无证据工期。

**结论仍待实跑验证的部分**：目标 JAR 覆盖率、具体 ARM native bridge、APK 后台/UI 行为、代理性能，以及要分发的每个第三方二进制/镜像的授权。
