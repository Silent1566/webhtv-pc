# Product

<!-- impeccable:product-schema 1 -->

## Platform

desktop (Flutter, Windows 优先；Linux/macOS 为同代码库目标)

<!-- init.md 把 Platform 约束为 web|ios|android|adaptive 四值之一。Flutter 桌面不属于
     其中任何一个，因此如实记录为 desktop，而不是错填 web（会启用 web-only 的
     live/generate/detect 路径）或 adaptive（会加载不适用的移动原生指引）。 -->

## Users

主要用户是**已经拥有自己的 TVBox / 猫源 / WebHTV 配置**的进阶用户——他们自己找源、自己维护
配置，不需要产品替他们提供内容。

使用场景：**坐在电脑前，用鼠标 + 键盘操作**。不是沙发大屏场景，也不是遥控器/手柄场景。

他们要做的事：把自己已有的配置导入 PC 端，然后浏览、搜索、播放，并使用直播、弹幕、EPG、
字幕等能力；同时和安卓端互通（桥接与同步）。

## Product Purpose

WebHTV PC 是一个**桌面播放器**，支持 WebHTV / TVBox / 猫源配置协议和 Spider 运行时。

它存在的理由：让用户已有的配置生态在 PC 上有一个原生、可用、可诊断的宿主，而不是把安卓
App 塞进模拟器壳里。

成功的样子：用户导入一份自己的配置，从站点列表一路走到能播的闭环，失败时能看懂为什么失败。

对外口径固定为：

> 支持 WebHTV / TVBox / 猫源配置协议和 Spider 运行时；单个站源能否使用，以实际测试通过为准。

不得表述为"支持全部 TVBox 或猫源"。

## Positioning

真正不可被邻近产品复制的是**协议兼容层 + 进程隔离的安全边界 + 分层的 Spider 运行时 ABI**：

- 主进程永不加载不可信 JAR/JS/Python；每种运行时各自进程隔离，崩溃只影响单个站点。
- 桌面原生 ABI（`tvbox-java-v1` 无 Android Context 的 JVM 签名、`tvbox-js-v1` Node 沙箱、
  `webhtv-cat-http-v1` HTTP 子集），带 major/minor 版本协商，不靠"抛不抛异常"猜能力。
- 关键事实：能执行 dex 的只有 ART，不是 JVM——所以 PC 端定义自己的 ABI，不做 Android 运行时包装。

Android 模拟器壳、单站点播放器都无法诚实地复制这套机制。

## Operating Context

- 目标平台 Windows / Linux / macOS，Windows 优先。
- 配置入口三种：HTTP(S) URL、本地文件、纯 JSON 文本。支持多配置并存与切换。
- 站点分五类（`type` 0/1/2/3/4），其中 `type=3` 按 `api` 形态分发到 HTTP / Node JS / JVM /
  Python 运行时，未匹配的必须显式报"运行时不支持"，不得显示空列表。
- 本地回环代理承担 HLS 改写、Range、Header 注入（默认只监听 `127.0.0.1`，禁止开放代理）。
- TMDB 用于元数据补全（详情、季集、演员、相关推荐）。
- 诊断与日志页面是真实排查工作流的一部分，不是装饰。
- 与安卓端互通：桥接设备、同步授权与推送。

## Capabilities and Constraints

已实现（Phase 0–8）：配置导入与多配置、站点浏览/分类/筛选、搜索、详情与多线路多剧集、
播放器（media-kit，含倍速/全屏/进度恢复/线路切换/字幕/弹幕/画面比例/四层浮层/屏显/
右键菜单/按钮排版）、直播与 EPG、TMDB 元数据、AI 集季识别、安卓桥接与实时同步、诊断与日志、
主题开关与配置品牌字段（wallpaper/logo）呈现、解析器全部类型（`type=0` Web 嗅探与
`type=4` Super 用**本机已安装的 Chromium 内核浏览器**执行，不内置也不分发浏览器；
本机没装时如实报能力缺失，不静默降级，见设计文档 §12.4）。缺浏览器时用户可在设置里
**从本地目录或 zip 一键安装浏览器组件**（§12.5）：组件是用户自己给的来源，安装 = 复制
到应用数据目录 + `--version` 校验 + 登记，不联网、不改系统。

**已确认的缺口**：与安卓版 `webhtv` 的逐项对比见 `docs/phase9/parity-2026-11-12/README.md`
（基线 Android `2d8b99775` / PC `b3c54d7e`，2026-11-12）。当前判定 108 条用户可见能力中
已迁移 43、部分迁移 30、未迁移 24、证据不足 7、平台专属 3；另有 8 类明确不迁移（见
`docs/phase9/README.md` §5）。不迁移项必须在 UI 与对外说明中如实披露，不得用「对齐安卓」
含糊带过。

硬约束（产品边界，不得突破）：

- 不内置影视资源、不内置站点配置、不内置爬虫。
- 不售卖或传播第三方内容，不提供资源搜索聚合的默认来源。
- 不替用户绕过版权、认证、验证码或访问控制。
- Spider 必须进程隔离；UI 层不得直接执行网络请求、Spider 或代理逻辑。
- 配置解析失败时不得覆盖最后一个可用配置；`msg` 非空时必须如实拒绝加载并展示原始错误。

UI 相关约束：

- 配置协议携带 `wallpaper` / `logo` / `notice` 三个品牌字段；`wallpaper` 与 `logo`
  已真正生效（`lib/ui/app.dart`），配置提供的品牌优先级高于 PC 端自身身份。
- 主题开关已实现（暗色 / 亮色 / 跟随系统）并持久化（`services/ui_preferences_store.dart`），
  默认暗色。

## Brand Commitments

- 应用名：WebHTV PC。版本 0.1.0。无正式品牌资产、无 VI 手册、无授权字体。
- **中文优先**是已确认需求（已实现字体回退链：微软雅黑 → Noto Sans CJK → 苹方 → Segoe UI）。
- 配置提供的 `wallpaper` / `logo` 属于**用户**的品牌，其优先级高于 PC 端自身的视觉身份。

## Evidence on Hand

- 各阶段验收证据与真实渲染截图：`docs/phase0/evidence/` … `docs/phase5/evidence/`（PNG，
  由集成测试的 `RepaintBoundary → toImage → PNG` harness 产出，不是 widget 树的重描述）。
- 协议与 ABI 定义：`packages/protocol/`、`packages/spider-abi/`。
- 本地 fixture：`tools/fixture_server/`、`apps/desktop-flutter/test/support/test_fixture_server.dart`、
  `packages/test-fixtures/`。
- 设计文档与 ADR：`docs/webhtv-pc-design.md`、`docs/adr/`。
- 测试规模：69 个单测文件 + 25 个集成测试文件。

不得编造：真实站点名称或内容、真实用户量、未经测量的性能基准、任何商业模式声明。

## Product Principles

1. **用户的配置是唯一事实来源。** PC 端不替用户决定看什么，也不隐藏配置里的事实。
2. **失败必须如实、可诊断。** 宁可显式报错，也不静默返回空列表或把错误当成功。
3. **安全边界优先于便利。** 不可信代码永不进入 UI 进程；进程隔离不是可选项。
4. **中文与桌面键鼠优先。** 排版、密度、快捷键、焦点态都按这个前提设计。
5. **不承诺能力范围。** 单站点可用性以实测为准，UI 不暗示"全都能播"。

## Accessibility & Inclusion

没有外部标准或法务要求被确认。已确认的产品内需求：

- 中文优先的排版与字体回退（缺少字体时不得出现方块字）。
- 键盘可达：桌面键鼠是主要输入方式，播放器已承诺快捷键能力。
