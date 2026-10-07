# WebHTV PC 播放器完整设计与验收方案

版本：v1.2<br>
日期：2026-09-25<br>
状态：设计文档，待 Phase 0 技术验证<br>
目标平台：Linux、Windows、macOS<br>
产品定位：支持 WebHTV / TVBox / 猫源配置协议的桌面播放器；不内置、不传播、不售卖任何影视资源。

---

## 1. 执行摘要

WebHTV PC 播放器应作为独立桌面应用开发，而不是直接改造当前 WebHTV Android 工程，也不是直接改造 `atv-player`、`CatVodSpider-PC` 或 `PiliPala`。

推荐路线是：

- 新建 `webhtv-pc` 项目。
- 复用 WebHTV 的配置协议、站点模型、Result/Vod 协议、Spider 调用语义、解析器/直播/代理/播放器经验。
- 参考 `atv-player` 的桌面 UI、libmpv 集成、本地 HLS/Range 代理和插件生命周期设计。
- 参考 `CatVodSpider-PC` 的桌面 Java Spider 协议与网络封装。
- 参考 `PiliPala` 的 Flutter/media-kit 播放器交互，仅作交互参考。

必须先澄清一项关键事实：**语言相同不等于运行时可直接复用**。WebHTV Android 的 `Spider` 基类使用 Android `Context`，站点加载依赖 `DexClassLoader`，`Site`、`Result`、`Vod` 等模型还使用 `Parcelable`、Room 和 Android 工具类。因此 PC 端可以复用协议语义和算法经验，但不能直接复用 Android 模块作为桌面运行时。

技术选型不预设唯一答案，必须在 Phase 0 同时验证：

1. **Flutter + media-kit**：优先验证 UI、跨平台播放和打包效率。
2. **Kotlin/JVM + Compose Desktop + libmpv**：优先验证 Java Spider 兼容和 libmpv 深度能力。

Phase 0 的对比结果必须写入 ADR，再冻结主路线。无论选择哪条路线，Spider 都必须进程隔离，主进程不得加载不可信 JAR 或远程脚本。

首个公开测试版（MVP-B）必须以“可验收的垂直闭环”为目标：

1. 导入 WebHTV/TVBox/猫源 JSON 配置。
2. 加载 HTTP API 站点。
3. 展示分类、列表、详情、播放列表。
4. 使用选定播放器引擎播放直链和 HLS。
5. 支持搜索、历史、进度恢复、基础播放控制。
6. 建立安全边界和本地代理。
7. 为后续 JS/Python/Java Spider 运行时提供清晰扩展点。

不应在首个公开测试版（MVP-B）承诺“兼容全部现有 Android TVBox Jar 站源”。PC 端必须定义自己的 Spider ABI，并通过兼容层渐进扩展。MVP-A 内部预览版只承诺 HTTP API；首个公开测试版（MVP-B）增加经过验证的 CatSpider HTTP 子集。

---

## 2. 参考项目评估结论

| 项目 | 参考价值 | 不建议直接采用的原因 |
| --- | --- | --- |
| `power721/atv-player` | PySide6 + libmpv 桌面壳、播放器窗口、本地 HLS/Range 代理、Python/Node Spider 生命周期 | 绑定 alist-tvbox；无明确 LICENSE；运行时与 WebHTV Java/QuickJS/Chaquopy 生态不同 |
| `kknifer7/CatVodSpider-PC` | 桌面 Java Spider ABI、Result/Vod 模型、OkHttp 封装、PC 网盘/B站等通用能力 | 不是完整播放器；无 UI/配置/播放器产品层；不能单独作为项目基底 |
| `guozhigq/pilipala` | Flutter + media-kit 播放器交互、进度/倍速/字幕/弹幕 UI 设计 | B站专用；移动优先；GPL-3.0；与 TVBox/猫源生态无直接关系 |
| WebHTV Android | 配置协议、站点/结果模型、Spider 生命周期、解析器、直播、弹幕、代理、播放策略 | 深度耦合 Android Context、DexClassLoader、Parcelable、Room、Surface、Android Media3/MPV/IJK |

结论：

- 设计和交互参考：`atv-player`
- 桌面 Java Spider 参考：`CatVodSpider-PC`
- 播放器 UI 参考：`PiliPala`
- 协议和功能模型主参考：WebHTV Android

---

## 3. 非目标与产品边界

### 3.1 必须坚持的产品边界

- 不内置影视资源。
- 不内置站点配置。
- 不内置爬虫。
- 不售卖或传播第三方内容。
- 不提供资源搜索聚合的默认来源。
- 不替用户绕过版权、认证、验证码或访问控制。
- 用户自行导入配置和站源，资源可用性由来源决定。

### 3.2 首个公开测试版（MVP-B）非目标

MVP-B 不要求：

- 兼容全部 Android JAR 站源。
- 支持全部 WebHome 能力。
- 支持投屏。
- 支持账号云同步。
- 支持完整远程管理。
- 支持完整移动端 UI。
- 支持插件商店。
- 支持自动更新站源。

### 3.3 可配置承诺

对外描述必须使用：

> 支持 WebHTV / TVBox / 猫源配置协议和 Spider 运行时；单个站源能否使用，以实际测试通过为准。

不得承诺：

> 支持全部 TVBox 或猫源。

---

## 4. 总体架构

### 4.1 顶层架构图

```text
┌─────────────────────────────────────────────┐
│              WebHTV PC UI                    │
│  配置管理 / 站点 / 搜索 / 详情 / 播放器 / 设置  │
└───────────────┬─────────────────────────────┘
                │
┌───────────────▼─────────────────────────────┐
│            Application Service              │
│  ConfigService / SiteService / SearchService │
│  HistoryService / PlaybackCoordinator       │
└───────────────┬─────────────────────────────┘
                │
┌───────────────▼─────────────────────────────┐
│               Core Protocol                 │
│  Config / Site / Result / Vod / Parse / Live │
└───────────────┬─────────────────────────────┘
                │
┌───────────────▼─────────────────────────────┐
│           Spider Runtime Layer             │
│  HTTP API / CatSpider HTTP / Node JS /      │
│  Python / PC Java                           │
└───────────────┬─────────────────────────────┘
                │
┌───────────────▼─────────────────────────────┐
│          Local Proxy & Parse Service        │
│  127.0.0.1 HTTP / HLS Rewrite / Range       │
└───────────────┬─────────────────────────────┘
                │
┌───────────────▼─────────────────────────────┐
│              Player Layer                   │
│      libmpv Player Engine + Controller      │
└─────────────────────────────────────────────┘
```

### 4.2 分层职责

| 层 | 职责 | 禁止事项 |
| --- | --- | --- |
| UI | 展示状态、响应用户操作、输入和输出 | 不直接执行网络请求、Spider、代理逻辑 |
| Application Service | 编排业务流程、状态、失败提示 | 不实现底层协议解析 |
| Core Protocol | 配置、站点、Result/Vod、解析、直播模型 | 不依赖 UI |
| Spider Runtime | 调用各类站源并统一返回 Result | 不访问 UI 对象 |
| Proxy & Parse | HLS、Range、Header、本地代理、嗅探 | 不做开放代理 |
| Player | 播放、暂停、进度、音轨、字幕、倍速 | 不解析站源协议 |

---

## 5. 技术选型与决策门

### 5.1 选型原则

技术路线按以下优先级决策：

1. 先证明播放器闭环和跨平台打包可交付。
2. Spider 必须进程隔离，允许每种运行时不共享宿主语言。
3. 协议兼容性与可维护性优先于形式上的代码复用。
4. 同一阶段只维护一条主 UI 和播放器链路，不做永久双栈。
5. 未通过 Phase 0 决策门的方案不得进入产品开发。

### 5.2 候选 A：Flutter + media-kit

默认推荐用于“尽快交付稳定跨平台产品”的场景。

| 项 | 选择 | 理由 |
| --- | --- | --- |
| 主语言 | Dart 3.x | UI、业务编排和并发模型统一 |
| UI | Flutter Desktop | Linux/Windows/macOS 一致性和开发效率较好 |
| 播放器 | media-kit；特殊流按需增加 mpv/ffmpeg sidecar | 降低原生窗口嵌入风险 |
| HTTP | Dart `http` / Dio | 满足配置、API 和代理请求 |
| JSON/XML | `json_serializable` / `xml` | 覆盖配置与 Result/Vod |
| 本地服务 | Dart Shelf 或独立 sidecar | 提供本机代理和 Spider IPC |
| 存储 | SQLite + drift | 历史、配置、健康统计和迁移 |
| 打包 | Flutter build + platform packaging | Windows MSI/zip、macOS dmg、Linux AppImage/deb |

适用条件：

- 目标是快速形成 UI、播放和打包闭环。
- Java Spider 兼容不是首个发布版本的阻断项。
- 团队接受为 Java/Python/Node 分别维护 sidecar。

风险：

- media-kit 对特殊 HLS、DRM、私有协议的支持可能弱于 libmpv。
- 所有非 Dart Spider 都需要跨进程桥接和发行管理。
- 需要独立验证 media-kit 在 Windows/macOS/Linux 的硬解、Seek、全屏和首帧表现。

### 5.3 候选 B：Kotlin/JVM + Compose Desktop + libmpv

仅在 Java Spider 深度兼容是核心目标，或 media-kit 无法满足播放能力时采用。

| 项 | 选择 | 理由 |
| --- | --- | --- |
| 主语言 | Kotlin 2.x，JVM 21 | 便于构建独立的 Java Spider 子进程宿主 |
| UI | Compose Desktop | Kotlin 原生 UI，不再并行维护 JavaFX |
| 播放器 | libmpv | MPV 能力完整，适合复杂流和 Header 注入 |
| HTTP | OkHttp | 与 TVBox/CatVod 网络语义接近 |
| JSON/XML | Gson + Simple XML 兼容层，内部模型可用 kotlinx.serialization | 降低既有字段适配成本 |
| 本地服务 | Ktor Server | 实现本机代理、Token 和管理 API |
| 存储 | SQLite + Exposed 或 SQLDelight | 历史、配置、健康统计和迁移 |
| 打包 | Compose Desktop packaging + jpackage | Windows MSI、macOS dmg、Linux deb/AppImage |

适用条件：

- Phase 0 已证明确认可嵌入的 libmpv 方案，而不是调用外部 mpv 进程冒充嵌入。
- 团队具备 JNI、native 动态库和跨平台打包能力。
- Java Spider 兼容是 Phase 3 的明确目标。

风险：

- libmpv 与 Compose Desktop 窗口、事件循环、全屏和硬件解码集成难度高。
- Windows/macOS/Linux 的 native 依赖必须分别构建、签名和验证。
- JVM 语言相同并不能直接复用 Android Spider 类，仍需桌面 ABI 和子进程宿主。

### 5.4 对比矩阵

| 维度 | Flutter + media-kit | Kotlin/JVM + Compose + libmpv |
| --- | --- | --- |
| UI 开发效率 | 高 | 中 |
| 三平台 UI 一致性 | 高 | 中 |
| 播放器能力上限 | 中，取决于 media-kit | 高 |
| 原生集成风险 | 中 | 高 |
| Java Spider 适配 | 中，需 sidecar | 高，适合独立 JVM 宿主 |
| 协议模型复用 | 中 | 中，仍需去除 Android 依赖 |
| 打包成熟度 | 高 | 中 |
| 团队技术要求 | Dart/Flutter | Kotlin/JNI/native 构建 |
| 推荐场景 | 默认产品路线 | Java 兼容或复杂播放优先 |

### 5.5 Phase 0 决策门

两条路线都必须完成最小可运行原型，使用同一组测试素材：

- 本地 MP4。
- 本地 HLS。
- 带 Referer/User-Agent 的远程 HLS。
- HLS Seek 与全屏。
- 一份标准 TVBox JSON 配置。
- 一个 HTTP API 站点的分类、详情、播放闭环。
- Windows 和 Linux 至少各完成一次构建与启动；macOS 在可用机器上验证。

决策门：

1. 播放器必须内嵌在主窗口内，不能依赖弹出外部播放器。
2. MP4 和 HLS 均能播放，HLS 支持 Seek 和 Header 注入。
3. 打包后能找到播放器 native 库或运行时，不要求用户手工配置错误路径。
4. HTTP API 站点能从配置导入走到播放，不出现 UI 卡死。
5. 需要可复现的崩溃、黑屏、全屏失败、音频不同步必须记录为阻断风险。
6. 两条路线不得同时进入产品化；Phase 0 结束后必须写 ADR 冻结一条主路线。

默认决策：

- 若两条路线均通过，优先选 **Flutter + media-kit**，以降低 UI、打包和长期平台维护成本。
- 若 media-kit 无法覆盖 HLS/Header/硬解等硬指标，选 **Kotlin/JVM + Compose Desktop + libmpv**。
- 若两条路线都失败，不进入 UI 开发，先解决播放器 native 集成。

### 5.5.1 Phase 0 分层与评分规则

Phase 0 分为两个连续门禁，避免两套候选方案重复实现完整业务层：

1. **P0-A 播放器与发行验证**：两条路线都验证窗口内嵌、MP4、HLS、Header、Seek、全屏、异常 URL、native 依赖发现，以及 Linux/Windows 发行包启动。
2. **P0-B 最小业务闭环**：仅在两条路线都通过 P0-A 后执行；使用同一个语言无关 Mock Server、`config-min.json` 和固定响应，只实现配置导入、首页、详情、播放，不扩展完整协议层。

硬门槛全部通过后才进入评分：

| 评分项 | 权重 | 证据 |
| --- | ---: | --- |
| 播放稳定性 | 25% | 同一媒体集连续播放、Seek、全屏和退出结果 |
| 跨平台打包 | 20% | Linux/Windows 发行包及启动日志 |
| 首帧与 Seek 表现 | 15% | 固定机器、固定素材的中位数和 P95 |
| native 集成复杂度 | 15% | 动态库数量、平台专项代码、签名与升级成本 |
| Spider sidecar 集成成本 | 10% | 最小 IPC 客户端与生命周期验证 |
| 可测试性 | 10% | 自动化覆盖、Mock 能力、故障注入能力 |
| 团队熟悉度 | 5% | ADR 中记录人员经验与维护风险 |

评分要求：

- 使用相同机器、相同 Release 构建、相同媒体和网络条件。
- 每项至少执行 10 次，保留原始日志、失败复现步骤和环境信息。
- 任一硬门槛失败即淘汰，不得用加权分数抵消。
- 两条路线均通过且总分差小于 5 分时，优先选择维护和打包成本更低的路线；差值不小于 5 分时选择高分路线。
- ADR 必须附评分表、证据路径、未通过项和规避方案，不能只给结论。

### 5.6 不推荐方案

| 方案 | 原因 |
| --- | --- |
| Electron 作为唯一主体 | native 渲染、安全、桥接复杂，体积大 |
| 直接改造 `atv-player` | 授权不确定，架构绑定 alist-tvbox |
| 直接改造 `PiliPala` | GPL、B 站专用、移动优先 |
| Android 模拟器包装 | 非真正 PC 版，体验和维护差 |
| 在 UI 主进程加载不可信 JAR/JS/Python | 无法建立可靠安全边界 |

> **补充（ADR-0002）**：上表拒绝的是把 Android 运行时当作**产品形态**（PC 版≈模拟器壳）。
> 对于「运行存量 Android `csp_*.jar`」这一具体诉求，ADR-0002 另设**可选兼容层**：
> 默认关闭、非主路线、走 §9.4 `webhtv-cat-http-v1` 六路由、不进入安装包。
> 主路线仍为 §9.3 的桌面 JVM ABI（`tvbox-java-v1`）。
> 关键事实：**能执行 dex 的只有 ART，不是 JVM**；JVM 只能运行无 Android Context 的桌面 jar。

---

## 6. 项目结构设计

```text
webhtv-pc/
├── apps/
│   ├── desktop-flutter/       # 候选 A，Phase 0 原型或最终产品
│   └── desktop-jvm/           # 候选 B，Phase 0 原型或最终产品
├── packages/
│   ├── protocol/              # Config/Site/Result/Vod 的跨语言 Schema 与文档
│   ├── spider-abi/            # ABI 定义、JSON Schema、测试客户端
│   └── test-fixtures/         # 可公开的协议、配置和媒体 fixture
├── sidecars/
│   ├── spider-host-jvm/       # 独立 JVM Spider 宿主
│   ├── spider-host-node/      # 独立 Node/QuickJS 宿主
│   └── spider-host-python/    # 独立 Python 宿主
├── resources/
├── packaging/
├── docs/
│   └── adr/                   # 技术选型、ABI 和安全决策记录
└── README.md
```

Phase 0 结束后，未选中的 UI 候选目录必须删除或移入独立实验仓库，避免长期双栈。`packages/protocol` 和 `packages/spider-abi` 与 UI 语言无关，是两条路线的共同资产。

### 6.1 关键对象

| 对象 | 职责 |
| --- | --- |
| `ConfigRepository` | 保存配置、读取远端/本地 JSON、校验配置 |
| `ConfigParser` | 解析 WebHTV/TVBox 顶层结构 |
| `SiteRegistry` | 管理站点状态、启停、最近使用、健康信息 |
| `SpiderRouter` | 根据 `type` 与 `api` 分发到运行时 |
| `SiteService` | 首页、分类、详情、搜索、播放编排 |
| `PlaybackCoordinator` | 组合 URL、Header、解析、代理、播放器 |
| `PlayerController` | 暴露播放器状态与控制 API |
| `ProxyServer` | 提供本机 HLS/Range/Spider 代理 |
| `HistoryRepository` | 播放记录、播放进度、删除、查询 |
| `LogService` | 结构化日志与用户诊断 |
| `CompatibilityStore` | 管理真实配置/站点样本的验证结果，不保存敏感凭据 |

---

## 7. 配置协议设计

### 7.1 顶层配置

PC 端必须兼容 WebHTV 当前配置结构：

```json
{
  "spider": "",
  "sites": [],
  "parses": [],
  "lives": [],
  "doh": [],
  "proxy": [],
  "hosts": [],
  "headers": [],
  "rules": [],
  "hlsRules": [],
  "groupRules": [],
  "ads": [],
  "flags": [],
  "wallpaper": "",
  "logo": "",
  "notice": "",
  "home": "",
  "parse": "",
  "urls": [],
  "msg": ""
}
```

### 7.2 字段支持矩阵

| 字段 | MVP-A | MVP-B | 完整版 | 说明 |
| --- | --- | --- | --- | --- |
| `sites` | 必须 | 必须 | 必须 | 点播站点 |
| `spider` | 可选 | 可选 | 必须 | 全局 JAR/Spider 资源；MVP 不承诺 Android JAR |
| `parses` | 解析入口保留 | 可选 | 必须 | 解析器 |
| `lives` | 后置 | 后置 | 必须 | 直播源 |
| `doh` | 后置 | 后置 | 必须 | DNS over HTTPS |
| `proxy` | 后置 | 后置 | 必须 | HTTP/SOCKS 规则 |
| `hosts` | 后置 | 后置 | 必须 | host 覆盖 |
| `headers` | 必须 | 必须 | 必须 | Header 注入 |
| `rules` | 后置 | 后置 | 必须 | 视频嗅探规则 |
| `hlsRules` | 后置 | 后置 | 必须 | HLS 清理规则 |
| `groupRules` | 后置 | 后置 | 必须 | 直播分组规则 |
| `ads` | 后置 | 后置 | 必须 | 广告域名规则 |
| `flags` | 必须 | 必须 | 必须 | 播放标识 |
| `home` | 必须 | 必须 | 必须 | 默认站点 |
| `parse` | 解析入口保留 | 必须 | 必须 | 默认解析器 |
| `msg` | 必须 | 必须 | 必须 | 配置错误提示；按 7.4.3 规则处理 |
| `wallpaper` | 忽略并保留 | 可选 | 必须 | 远程配置主题壁纸 |
| `logo` | 忽略并保留 | 可选 | 必须 | 配置品牌图 |
| `notice` | 忽略并保留 | 必须 | 必须 | 配置加载成功提示 |
| `urls` | 必须 | 必须 | 必须 | 配置仓库或备用配置地址；按 7.4.2 规则展开 |

### 7.3 配置加载流程

```text
用户输入 URL / 本地文件 / JSON 文本
        │
        ▼
ConfigFetcher
  ├─ HTTP 状态、重定向、Content-Type、BOM、gzip/br
  ├─ 大小与超时限制
  └─ URL 外链深度限制
        │
        ▼
JSON/文本校验与解析
  ├─ msg 优先检查
  ├─ urls 仓库展开
  └─ 未知字段保留但不执行
        │
        ▼
站点模型转换与字段归一化
        │
        ▼
合法性与危险能力标记
        │
        ▼
保存 ConfigRecord
        │
        ▼
SiteRegistry 初始化
```

### 7.4 字段语义与优先级

#### 7.4.1 配置入口

- 输入可以是 HTTP(S) URL、本地文件或纯 JSON 文本。
- PC 端目标支持 `gzip`、`br`、UTF-8 BOM，并允许明确声明的 GBK/GB18030。该能力是 PC 端兼容目标，不等同于声称 Android 当前实现已全部支持。
- HTTP 3xx 最多跟随 5 次，禁止降级到 `file://`、`ftp://` 等非 HTTP(S) 方案。
- 配置响应设置大小上限，默认不超过 8 MiB；超限时拒绝并保留原配置。
- 配置解析失败时不得覆盖最后一个可用配置。

#### 7.4.2 单配置对象、仓库对象和 `urls`

当一个 JSON 对象没有 `sites`，但包含 `urls` 时，按“配置仓库”处理：

1. 读取 `urls` 数组，元素至少支持 `{ "name": "...", "url": "..." }`；为兼容旧配置，也可保留纯 URL 字符串入口并给出弃用诊断。
2. 把仓库注册为“配置仓库”，而不是把其中所有配置集合直接合并成单个配置。
3. 仓库条目可按默认第一项和用户选择加载；切换条目时保留各条目独立配置记录。
4. 每个条目使用自己的来源 URL，以支持更新、回滚和错误定位。
5. 仓库展开失败不覆盖已导入配置。
6. 配置对象存在 `msg` 键时先终止行为，不再展开 `urls`，以保持 Android 当前兼容语义。

说明：WebHTV Android 当前实现会选择仓库第一项并替换仓库记录。PC 端允许保留仓库并记住用户选择，但必须确保“默认第一项、失败回退、覆盖更新”的行为有 fixture，避免与 Android 版本产生无法解释的差异。

#### 7.4.3 `msg`

WebHTV 的分类结果中，`msg` 在 `code == 0` 时有效；配置对象中的 `msg` 用于表达配置级失败。当前 Android 实现在配置对象存在 `msg` 键时直接抛出其文本，因此 PC 端 MVP 必须保持该兼容行为。

- 配置对象存在 `msg` 键：按 Android 当前行为拒绝加载；若文本为空，展示通用配置错误。未来如果改为忽略空值，必须作为明确兼容决策并增加版本说明。
- Result 对象 `msg` 非空：把它作为业务错误向上传递，不得转换为空列表。
- HTML 错误页、登录页或 WAF 页面：识别为非预期媒体类型，不当作 JSON/XML 成功响应。

#### 7.4.4 `spider` 与站点 `jar`

解析优先级如下：

1. 站点自身 `jar` 非空时，使用站点 `jar`。
2. 否则使用顶层 `spider`。
3. 两者都为空时，`type=3` 站点只允许由 `api` 明确判定为 HTTP Spider；否则标记为不可运行。

禁止在尚未完成 Spider ABI 与安全隔离前自动下载和执行 JAR。

#### 7.4.5 `ext`

- 站点 `ext` 可以为 JSON 字符串、JSON 对象或空值；对象按稳定 JSON 原始文本保存和传递，不做 Base64。
- 站点 `ext` 在请求中作为 `extend` 参数传递给普通 HTTP API；当前 WebHTV 实现在其长度不超过 1000 时放入 query，超过 1000 时改为表单 body。
- `type=4` 的分类筛选对象单独序列化为 JSON，并用 Base64 URL-Safe 放入 `ext` 参数；它与站点 `ext` 是两个不同层级的字段。
- Base64 URL-Safe 的字符表、填充和无换行要求必须由 fixture 固定，不能由各实现自行猜测。

#### 7.4.6 Header、代理、hosts、DoH 的生效顺序

先区分两类 Header：

- 顶层 `headers` 是 `{ "host": "...", "header": {...} }` 规则数组，由 HTTP 客户端按目标 host 匹配并注入请求。
- 站点对象的 `header` 和播放结果的 `header` 是直接应用于该站点或媒体请求的 Headers。

请求处理顺序必须固定为：

1. 解析 URL、站点基础参数和请求目标 host。
2. 找出所有匹配目标 host 的全局 `headers` 规则，并按配置顺序注入实际 HTTP 请求。
3. 对站点 API 请求，额外应用站点 `header`。
4. 对媒体播放请求，播放结果 `header` 优先；结果未提供 Header 时，以站点 `header` 作为回退。该兼容行为来自 `Result.setHeader` 只在空值时写入。
5. 依次应用 `hosts`、`doh`、`proxy`。
6. 在本地代理中记录脱敏后的最终请求诊断。

Header 名称大小写不敏感，但输出诊断时应保留原始键用于排查。全局 Header 的 host 匹配支持通配或包含规则时，必须与 WebHTV 的行为 fixture 对齐。

#### 7.4.7 HTTP API 请求编码

普通 HTTP API 站点的请求需要区分 query 和表单：

- 站点 `ext` 长度不超过 1000 时，将 `extend` 与其他参数放入 URL query。
- 站点 `ext` 长度超过 1000 时，使用 `application/x-www-form-urlencoded` 表单 body，避免请求头或 URL 过大。
- `type=1` 分类请求把筛选对象 JSON 放入 `f`。
- `type=4` 分类请求把筛选对象 Base64 URL-Safe 后放入 `ext`。
- `type=0/1/2/4` 使用 `ac=videolist` 或 `ac=detail`，并保持 `t`、`pg`、`ids`、`wd`、`quick` 等字段语义。

此行为必须由请求捕获测试验证，不能只测试最终解析结果。

#### 7.4.8 `parse`、`jx`、`flag`、`playUrl`

现有协议同时存在 `url`、`playUrl`、`parse`、`jx` 和 `flag`，不同站点类型的组合语义并不完全一致。PC 端必须用兼容 fixture 固化，而不是靠字段遍历顺序决定：

1. `parse=1` 或 `jx=1`：进入解析流程。
2. `parse=0` 且 `jx=0`：优先按直链处理，但仍需检查站点 `playUrl` 和 `flag` 的组合。
3. 对普通 HTTP API 站点，当前 Android 行为会根据请求 URL 是否被识别为媒体格式，以及站点 `playUrl` 是否为空，决定是否设置 `parse=1`。
4. `flag` 参与解析器匹配和线路标识，不单独等同于直链或解析指令。
5. `playUrl` 可能是解析入口、前缀或备用地址，语义必须按站点类型和实际样本验证。
6. 所有冲突组合都要有请求捕获和播放决策测试，测试名称需明确站点类型。
7. **`type=4` 不看 `playUrl`，播放入口就是站点 `api`，参数固定为 `play=<剧集目标>&flag=<线路>`**（对齐 Android `SiteApi.playerContent` 的 `type==4` 分支）。因此：
   - `type=4` 的剧集目标必须先送播放入口（同 §8.1 分发顺序 5），不做直链初判；
   - 播放入口返回的 `parse`/`jx` 决定后续是直链还是进解析流程（`flag` 同时用于解析器匹配，§12.2）；
   - 播放入口返回的 `header` 是**媒体请求 Header**（§7.4.6 步骤 4），必须随决策进入播放请求；
   - 播放入口未给出地址时如实报错，不得回退到剧集目标。

### 7.5 配置验收

- 支持 URL、本地文件、纯 JSON 文本三种导入。
- 支持多个配置并允许切换。
- 能记录配置名称、URL、更新时间、站点数、直播数。
- 无效配置不会影响已有配置。
- `msg` 非空时禁止加载并展示原始错误。
- `urls` 仓库选择、默认第一项、失败回退、覆盖更新和部分条目失效行为符合固定 fixture。
- gzip/br、BOM、GB18030、重定向循环和超大响应都有测试。
- Header 覆盖顺序、`ext` 编码和解析优先级符合测试。
- 重复导入同一配置应覆盖或创建新版本，行为明确。

---

## 8. 站点与协议模型

### 8.1 站点类型与分发优先级

| `type` | 名称 | 阶段 | 说明 |
| --- | --- | --- | --- |
| `0` | XML API | MVP-A | 传统 CMS XML API |
| `1` | JSON API | MVP-A | 请求带 `ac=detail` 和 `f={json}` |
| `2` | JSON API 兼容 | MVP-A | 不追加 `f` |
| `3` | Spider | MVP-B 仅 HTTP 子集 | 依赖 `api` 分发；其他运行时按 Phase 3 |
| `4` | HTTP API + Base64 ext | MVP-A | 首页/分类/播放带扩展参数 |

`type=3` 分发：

| `api` 形态 | 运行时 | 阶段 |
| --- | --- | --- |
| `http.../spider/...` | CatSpider HTTP | MVP-B 候选，必须先通过 Phase 0 契约测试 |
| `*.py` | Python Spider | Phase 3 |
| `*.js` | Node/QuickJS Spider（PC 端已实现 Node 运行时 + `tvbox-js-v1` 沙箱；仍需用户确认后才加载远程脚本） | Phase 3 ✅ |
| `csp_*` | PC Java Spider（桌面 JVM ABI `tvbox-java-v1`） | Phase 3 |
| 其他 | SpiderNull | 必须，返回明确“不支持”错误 |

分发顺序：

1. 先按 `api` 判定具体运行时，而不是只按 `type`。
2. 未匹配的 `type=3` 站点使用 `SpiderNull`，UI 显示“运行时未安装/未支持”，不得显示空列表。
3. 同一配置中存在不可运行站点时，其他站点必须继续加载。
4. **`type=3` 的剧集目标必须先送播放入口（`/play`），不做“直链初判”短路。** 详情 `vod_play_url` 中该集 `$` 之后的值是**播放入口的输入**（`/play` 的 `id`），而不是媒体地址：网盘线路形如 `https://pan.baidu.com/s/…|…|<base64>`，裸 scheme 是 `https`，若按普通 HTTP API 站点那样先判“像直链”就直接给播放器，会把分享页 HTML 当媒体流（实测 `Failed to recognize file format`）。参考实现对 `type=3` 在 `playerContent` 里**无条件**先调 `/play`（`site.recent().spider().playerContent(flag, id, …)`），从不短路；`type=0/1/2` 保留初判以避免多余网络请求。运行时不可用时必须如实报错，不得把剧集目标当直链返回。
5. **`type=4`（HTTP API + Base64 ext）同样必须先送播放入口，且播放入口就是站点 `api` 自身。** 参考实现 `SiteApi.playerContent` 对 `site.getType() == 4` 构造 `play=<剧集目标>` 与 `flag=<线路>` 后调用站点 `api`：

   ```java
   ArrayMap<String, String> params = new ArrayMap<>();
   params.put("play", id);
   params.put("flag", flag);
   String playerContent = call(site, params);   // GET <site.api>?play=…&flag=…
   ```

   要点：

   - **`type=4` 没有 `playUrl` 字段**：实测一份 163 站点配置里 68 个 `type=4` 站点**全部**没有 `playUrl`，播放入口永远是 `api`。宿主不得因 `playUrl` 为空就跳过播放入口（PC 端曾如此，导致**所有** T4 站点播放落 `playbackParserRequired`，用户实测日志 `site=木偶 playbackParserRequired: 站点 木偶 未声明 playUrl，且剧集目标不是直链`）。
   - 剧集目标是**播放入口的输入**，不是媒体地址：既可能是 URL 编码 JSON（网盘：`7b22696422…`）、也可能是形如 `111136494@851839@1` 的站点内 ID。不得用“看起来像直链”来短路。
   - 播放入口返回值必须整体参与决策：`parse=1`/`jx=1` → 继续走 §12 解析器；`parse=0` + 真实地址 → 直链播放；**播放结果 `header` 必须进入媒体请求**（实测 115 CDN 直链靠 `user-agent: Mozilla/5.0 115Browser/…` 取流）。
   - 播放入口没给出地址（或只给出 `url:"1"` 一类占位符 + `msg` 业务错误）时**如实报错**（`playbackUrlMissing` / `siteBusiness`），不得把剧集目标当直链返回。

   实测 T4 站点播放形态分布（真实 AT 配置，68 个 `type=4` 站点抽样 38 个可播站点）：直链 + 媒体 Header 22 个、`parse=1` 走解析器 6 个、平台页/JSON 直链其余；播放入口返回 `url` 为**数组**（多码率/多线路）与字符串两种形态均需兼容。

### 8.2 站点字段

必须支持：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `key` | string | 唯一标识 |
| `name` | string | 显示名 |
| `type` | int | 站点类型 |
| `api` | string | API 或 Spider 入口 |
| `jar` | string | 站点专用 JAR |
| `ext` | string/object | 扩展参数 |
| `header` | object | 站点 Header |
| `timeout` | int | 请求超时秒 |
| `searchable` | int | 搜索能力 |
| `changeable` | int | 换源能力 |
| `quickSearch` | int | 快速搜索 |
| `categories` | string[] | 分类限制 |
| `style` | object | UI 样式 |
| `hide` | int | 隐藏 |
| `indexs` | int | 参与索引搜索 |

可选保留：

- `homePage`
- `chromeMode`
- `webHomeChrome`
- `extensions`
- `click`
- `playUrl`

### 8.3 Result/Vod 协议

列表结果：

```json
{
  "class": [
    { "type_id": "1", "type_name": "电影" }
  ],
  "filters": {
    "1": [
      {
        "key": "area",
        "name": "地区",
        "value": [
          { "n": "全部", "v": "" },
          { "n": "大陆", "v": "大陆" }
        ]
      }
    ]
  },
  "list": [
    {
      "vod_id": "1",
      "vod_name": "示例",
      "vod_pic": "https://example.com/a.jpg",
      "vod_remarks": "更新至 1 集"
    }
  ],
  "page": 1,
  "pagecount": 1,
  "total": 1
}
```

详情结果：

```json
{
  "list": [
    {
      "vod_id": "1",
      "vod_name": "示例",
      "vod_pic": "https://example.com/a.jpg",
      "vod_remarks": "第 1 集",
      "vod_area": "大陆",
      "vod_year": "2026",
      "vod_director": "导演",
      "vod_actor": "演员",
      "vod_content": "简介",
      "vod_play_from": "主线$$$备用线",
      "vod_play_url": "第1集$a#第2集$b$$$第1集$c"
    }
  ]
}
```

播放结果：

```json
{
  "url": "https://example.com/index.m3u8",
  "parse": 0,
  "jx": 0,
  "playUrl": "",
  "header": {
    "User-Agent": "Mozilla/5.0",
    "Referer": "https://example.com/"
  },
  "format": "application/x-mpegURL"
}
```

### 8.4 协议验收

- XML、JSON、兼容 JSON、Base64 ext、HTTP Spider 五种入口的模型输出统一。
- `vod_play_from` 与 `vod_play_url` 必须能解析成多线路、多剧集结构。
- 空列表、非法分页、非法 URL、HTML 错误页必须有统一错误类型。
- 不允许把 HTML 错误页当作 JSON 解析成功。
- 单站点失败不得阻塞其他站点。

---

## 9. Spider 运行时设计

### 9.1 设计目标

- Spider 与 UI/宿主主进程隔离。
- 所有运行时使用统一的逻辑接口，但允许不同进程通信实现。
- 调用可取消、可超时、可限流、可诊断。
- 第三方脚本不能直接访问宿主数据库、配置目录、浏览器 Cookie 和 UI。
- ABI 必须有版本号，以便未来兼容而不依赖猜测。

### 9.2 逻辑接口

PC 内部统一使用以下逻辑接口。Flutter 路线通过 IPC 适配，Kotlin 路线通过子进程客户端适配。

```kotlin
interface PcSpider : AutoCloseable {
    val key: String
    suspend fun init(extend: String): SpiderInitResult
    suspend fun homeContent(filter: Boolean): SpiderResult
    suspend fun homeVideoContent(): SpiderResult
    suspend fun categoryContent(
        tid: String,
        page: String,
        filter: Boolean,
        extend: Map<String, String>
    ): SpiderResult
    suspend fun detailContent(ids: List<String>): SpiderResult
    suspend fun searchContent(
        keyword: String,
        quick: Boolean,
        page: String? = null
    ): SpiderResult
    suspend fun playerContent(
        flag: String,
        id: String,
        vipFlags: List<String>
    ): SpiderResult
    suspend fun liveContent(url: String): SpiderResult
    suspend fun proxy(params: Map<String, String>): ProxyResult
    suspend fun action(action: String): SpiderResult
    override fun close()
}
```

### 9.3 ABI 版本与最低方法集

ABI 名称使用 `<domain>-<runtime>-v<major>`。当前规划：

| ABI | 说明 | 阶段 |
| --- | --- | --- |
| `webhtv-ipc-v1` | 宿主与 sidecar 的 stdio JSON-RPC 通信 | Phase 2 |
| `webhtv-cat-http-v1` | 兼容 `POST <api>/home/category/detail/play/search` 的 HTTP 子集；兼容标签为 `tvbox-http-v1` | MVP-B 候选 |
| `tvbox-js-v1` | Node/QuickJS 脚本协议（PC 端已实现 Node `vm` 沙箱；QuickJS 内核未实现） | Phase 3 ✅ |
| `tvbox-python-v1` | Python 脚本协议 | Phase 3 |
| `tvbox-java-v1` | 无 Android Context 的桌面 JVM Spider 签名（已实现：`sidecars/spider-host-jvm/host.jar`，纯 JDK、零第三方依赖，支持 jar / 类目录 / `.java` / 源码目录四态入口） | Phase 3 ✅ |
| `webhtv-cat-http-v1`（Android 桥接） | Android `csp_*.jar` 兼容层：桥接 APK 暴露 §9.4 六路由，宿主按 cat http 调用；默认关闭、非主路线 | 可选（ADR-0002） |

`major` 不兼容，`minor` 只增加可选能力。宿主和 Spider 必须在初始化时交换版本与 capability，禁止靠方法是否抛异常猜测能力。

最低方法集：

| 方法 | 是否必需 | 说明 |
| --- | --- | --- |
| `init` | 必需 | 传递 extend、权限和宿主能力 |
| `home` | 必需 | 返回分类、筛选、推荐列表 |
| `category` | 必需 | 返回分页分类列表 |
| `detail` | 必需 | 返回详情和多线路/多集 |
| `search` | 必需 | 支持 quick/page 候选参数 |
| `play` | 必需 | 返回播放 URL、Header、parse/jx 语义 |
| `destroy` | 必需 | 释放线程、连接、文件和端口 |
| `homeVod` | 可选 | 没有时回退到 `home` 中的列表 |
| `live` | 可选 | Phase 3 直播能力 |
| `proxy` | 可选 | 必须声明 capability，不能只靠返回 null 判断 |
| `action` | 可选 | 动作卡和交互能力 |

### 9.3.1 IPC 传输与生命周期

`webhtv-ipc-v1` 使用 JSON-RPC 2.0 语义和带长度前缀的消息帧，禁止依赖“一行一个 JSON”。帧格式为 `Content-Length` 头、空行和指定字节数的 UTF-8 JSON；stdout 只承载协议帧，运行时日志只能写入 stderr。

宿主必须实现：

- 启动后先执行 `initialize`，交换 ABI major/minor、capabilities、权限和限制。
- request ID 使用非空字符串；同一进程生命周期内不得复用未完成 ID。
- 支持 `cancel`、`shutdown` 和心跳；超时后依次执行取消、宽限等待、终止进程树。
- 限制单帧、单响应和累计输出大小；非法帧、未知 ID、版本不匹配均返回统一协议错误。
- sidecar 意外退出时记录诊断并指数退避，禁止无限快速重启。
- stderr 日志执行大小限制、轮转和脱敏；stdout 出现非协议数据时终止当前运行时并报告协议污染。
- 二进制代理数据不写入 JSON-RPC；通过宿主签发的短期本地代理会话传输。

统一错误对象至少包含 `code`、`category`、`message`、`retryable`、`userVisible`、`siteKey`、`requestId`、`details` 和 `diagnosticId`。原始异常、敏感 URL 和凭据不得直接展示给用户。

### 9.4 HTTP Spider ABI

`webhtv-cat-http-v1`（兼容标签：`tvbox-http-v1`）是当前 WebHTV `CatSpider` 可验证的 HTTP 子集。该名称表示 WebHTV PC 固化的兼容契约，不代表通用或官方 TVBox ABI。基础地址为 `api`，所有请求使用 `POST` 和 `Content-Type: application/json; charset=utf-8`。

| 路由 | 请求体 | 响应 |
| --- | --- | --- |
| `/init` | `{}` | 初始化状态或空对象 |
| `/home` | `{}` | 标准首页 Result |
| `/category` | `{ "id": "...", "page": 1, "filters": {} }` | 标准分类 Result |
| `/detail` | `{ "id": "..." }` | 标准详情 Result |
| `/search` | `{ "wd": "...", "page": 1 }` | 标准搜索 Result |
| `/play` | `{ "flag": "...", "id": "..." }` | 标准播放 Result |

兼容规则：

- `api` 以 `/` 结尾时先归一化，再追加具体路由。
- HTTP 状态非 2xx 必须映射为 `SPIDER_HTTP_ERROR`，不能返回空字符串冒充成功。
- 响应为 `{ "code": 0, "data": {...} }` 时解包 `data`；`data` 为数组时包装为 `{ "list": [...] }`。
- 响应为 `{ "code": 非 0, "msg": "..." }` 时返回业务错误。
- `filters` 是分类扩展条件的对象，字段名和值按上游配置原样传递。
- `page` 统一为整数；空值或非法值按 1 处理，但应记录诊断。
- `/play` 的 `id` 是**剧集目标串**，即 `/detail` 返回的 `vod_play_url` 中该集 `$` 之后的值（猫源形如 URL 编码 JSON `%7B%22vodId%22...%7D`）；`flag` 是该集所属线路（`vod_play_from` 的对应段）。**不得**把纯 `vod_id` 当 `id` 传——实测猫源部分子站（如 jinpai/muou/huban）只会返回空 `url`（§9.4 契约，PC 端 `CatHttpSiteRuntime.play` 与 sidecar 运行时一致）。
- **该目标必须先送 `/play`，不得被“直链初判”短路**（§8.1 分发顺序 4）。剧集目标是播放入口的输入，不是媒体地址；网盘线路裸 scheme 为 `https` 会被误判成直链，导致分享页 HTML 被当流（`Failed to recognize file format`）。
- **播放入口未返回地址时必须如实报错，不得回退到剧集目标。** 上游对部分网盘线路（如夸克）就是返回空地址（bundle 回 `{urls:[], header:{}}`），回退会把分享页 HTML 交给播放器，且比直接报错更难排查。宿主抛 `playbackUrlMissing`，UI 据此引导换源。
- 播放入口返回的多码率列表形态极宽松：`url` 可为**「名称/地址」交替的平铺数组**（对齐 CatVod `UrlAdapter`，如 `["RAW","https://…","super","https://…"]`，网盘线路实测即此形态），也可为 `{ "values": [{"n":"RAW","v":"…"}] }` 对象形态。宿主取**第一个**可播放地址，`RAW` 优先；纯字符串 `url`/`playUrl` 保持兼容。顶层 `urls`（复数）不是播放入口字段（它是配置仓库键，§7.4.2），不参与地址提取。
- 未实现的 `/live`、`/proxy`、`/action` 不伪装成功。HTTP 客户端应把 404/501 或明确的业务错误映射为 `SPIDER_UNSUPPORTED`，不得把它转换为空列表。

当前 WebHTV Android 客户端只覆盖上述 HTTP 子集，不包含 live、proxy、action。PC 端如需扩展，必须新开 ABI 版本或 capability，不能悄悄改变 `tvbox-http-v1` 语义。

### 9.5 进程通信 ABI

所有 sidecar 使用同一基础 envelope。编码固定为 UTF-8 JSON，一行一消息，最大帧大小默认 16 MiB。

请求：

```json
{
  "jsonrpc": "2.0",
  "id": "req-1",
  "method": "search",
  "params": {
    "keyword": "示例",
    "quick": false,
    "page": "1"
  },
  "deadlineMs": 15000,
  "traceId": "trace-123"
}
```

成功响应：

```json
{
  "jsonrpc": "2.0",
  "id": "req-1",
  "result": {
    "list": []
  }
}
```

错误响应：

```json
{
  "jsonrpc": "2.0",
  "id": "req-1",
  "error": {
    "code": "SPIDER_TIMEOUT",
    "message": "spider deadline exceeded",
    "retryable": true,
    "details": {}
  }
}
```

统一错误码至少包括：

| 错误码 | 含义 |
| --- | --- |
| `SPIDER_INIT_FAILED` | 初始化或权限协商失败 |
| `SPIDER_UNSUPPORTED` | 方法或 ABI 不可用 |
| `SPIDER_BAD_REQUEST` | 参数或协议字段非法 |
| `SPIDER_HTTP_ERROR` | 上游 HTTP 状态错误 |
| `SPIDER_PARSE_ERROR` | 上游响应不是预期 JSON/XML/媒体 |
| `SPIDER_TIMEOUT` | 请求或整体截止时间已到 |
| `SPIDER_CANCELLED` | 用户取消或换任务 |
| `SPIDER_CRASHED` | 子进程崩溃 |
| `SPIDER_RESOURCE_LIMIT` | 超过内存、CPU、并发或响应大小限制 |

取消机制：

- 宿主可发送 `$/cancelRequest` 并携带原 `id`。
- sidecar 必须在安全点检查取消；不支持中断的阻塞调用必须可被进程级超时兜底。
- UI 取消后不得再向已取消页面投递结果。
- 超时不是一个泛用值，应按初始化、网络请求、详情、播放分别配置。

### 9.6 代理数据通道

`proxy` 不能只返回一个普通 JSON 字符串，否则无法传递二进制大流。Phase 2 采用以下约束：

1. sidecar 返回 `ProxyResult`，包含状态码、Header、`streamId` 或本地回环 URL。
2. 宿主只接受 sidecar 自己监听的 `127.0.0.1` 地址，或由宿主建立的数据通道。
3. 代理 URL 必须带短期、随机会话 token 和过期时间。
4. 数据流必须支持 Range、分片、背压、取消和连接关闭。
5. 禁止把任意远程 URL 原样注册为可访问代理目标。
6. 代理日志记录目标主机、状态、字节量、耗时；查询签名和 Cookie 必须脱敏。

### 9.7 Manifest

每种可分发的 Spider 必须提供 manifest，与代码分离并可被宿主校验：

```json
{
  "abi": "webhtv-ipc-v1",
  "abiMinor": 0,
  "key": "demo",
  "name": "Demo Spider",
  "runtime": "node-22",
  "entry": "dist/index.js",
  "capabilities": ["home", "category", "detail", "search", "play"],
  "permissions": {
    "network": true,
    "localProxy": false,
    "ui": false,
    "storage": "cache-only",
    "process": false,
    "clipboard": false,
    "browser": false
  },
  "limits": {
    "memoryMiB": 256,
    "cpuSeconds": 30,
    "concurrency": 2,
    "responseMiB": 8
  },
  "hashes": {
    "entrySha256": ""
  },
  "signature": null
}
```

规则：

- 未声明 capability 的方法返回 `SPIDER_UNSUPPORTED`。
- 未声明权限的能力在进程层拒绝，不能只在 UI 中隐藏。
- 首次执行远程脚本前必须由用户确认来源和权限。
- 不要求 MVP 实现完整签名，但 manifest 必须为后续签名验证保留字段。

### 9.8 进程隔离与资源限制

- JS/Python/Java Spider 默认运行在独立子进程。
- 主进程不能直接加载不可信 Java 类。
- Spider 与 UI 进程完全隔离。
- 每个站点必须设置内存、CPU 时间、超时和并发限制。
- Spider 崩溃只影响该站点。
- Spider 不得直接访问主进程数据库、配置文件、Cookie、系统浏览器。
- sidecar 工作目录为每站点独立临时目录，退出后清理。
- 子进程不得继承宿主的完整环境变量；只传递白名单变量。
- 下载、缓存和日志都必须限制大小。

### 9.9 兼容层设计

TVBox Java Spider 常见入口如下，但它们不是可直接复用的桌面 ABI：

```text
init(String extend)
init(Context context, String extend)   // 仅在兼容运行时中支持
init()
```

规则：

- PC 原生运行时只承诺 `init(String)` 或 `init()`。
- Android `Context` 兼容需要独立兼容运行时，不能进入 MVP。
- 反射失败必须给出明确诊断：缺方法、类缺失、Android 依赖缺失、签名不匹配。
- 不得静默把失败站点显示为空列表。
- 只有能在独立 JVM sidecar 中加载的 JAR 才允许进入桌面兼容路径。
- 任何 JAR 都不得在 UI 主进程中反射加载。

**已实现（Phase 3）**：桌面 JVM 路径由 `sidecars/spider-host-jvm/host.jar` 承担
（§9.3 `tvbox-java-v1`），主程序按 manifest 的 `runtime` 为 `jvm*`/`java*` 时启动
`java -jar host.jar --entry … --manifest …`。要点：

- 入口支持 `.jar` / 类目录 / `.java` / 源码目录；`.java` 用 JDK 自带
  `javax.tools` 编译器，因此需要 **JDK 17+**（不是 JRE）；
- **JVM 堆参数必须显式给出**：宿主用 Windows 作业对象把内存限制为 manifest 的
  `limits.memoryMiB`（默认 256 MiB），而 JVM 默认按物理内存 1/4 预留堆（实测
  640 MiB）会直接 `os::commit_memory failed` 退出。主程序按 manifest 推导
  `-Xmx{memoryMiB/2}` 等参数；
- **Java 运行时按版本探测，不按 PATH 顺序取第一个**：实测本机 PATH 上
  `jre1.8.0_501` 排在 JDK 21 之前，直接取第一个会因
  `UnsupportedClassVersionError` 启动即崩；探测同时要求同目录有 `javac`；
- `csp_*` 站点（TVBox 生态的 Java 站源类名形态）映射到 `jvm` 运行时，但只接受
  **无 Android Context 的桌面 jar**；含 `classes.dex` 的 Android jar 会明确报
  「JVM 无法加载」，而不是启动后崩溃（ADR-0002 §1.1）。

Android `csp_*.jar` 本身仍不在桌面路径内（dex 只能由 ART 执行），如需运行存量
Android 站源请走 ADR-0002 的可选兼容层（默认关闭、非主路线）。

### 9.10 Spider 验收

| 能力 | 验收 |
| --- | --- |
| 初始化 | 成功/失败/超时都有状态 |
| 首页 | 返回分类、筛选、推荐 |
| 分类 | 支持分页和筛选 |
| 详情 | 支持多线路和多集 |
| 搜索 | 支持 quick/page |
| 播放 | 返回可播放 JSON |
| 代理 | 返回状态、Content-Type、流/Header |
| 销毁 | 进程退出、资源释放、端口释放 |
| 崩溃隔离 | 一个 Spider 崩溃不影响主应用 |
| 超时 | 请求不会永久挂起 |
| 取消 | 已取消请求不投递结果，进程能回到空闲状态 |
| 资源限制 | 内存、响应大小、并发或 CPU 超限被拒绝 |
| ABI 协商 | 不兼容 major 版本拒绝加载，缺少 capability 返回明确错误 |
| 日志脱敏 | Cookie/Authorization/签名参数不明文出现 |

---

## 10. 播放器设计

### 10.1 引擎选择

播放器引擎由 Phase 0 ADR 决定：

- 候选 A 默认使用 **media-kit**。
- 候选 B 使用 **libmpv**。

无论选哪条路线，首版只实现一个稳定主引擎；其他引擎只作为诊断或后续兼容，不并行进入产品主路径。

| 引擎 | 用途 |
| --- | --- |
| media-kit | Flutter 路线主播放器 |
| libmpv | JVM 路线主播放器，亦可作为 Flutter 特殊流 sidecar |
| 系统 mpv | 外部播放器备选 |
| FFplay | 调试备选 |
| VLC | 格式兼容备选 |

### 10.2 播放流程

```text
用户选择剧集
        │
        ▼
SiteService.playerContent()
        │
        ├── parse=0：准备直链播放
        ├── parse=1/jx=1：执行解析器
        └── Spider proxy：生成本地代理 URL
        │
        ▼
PlaybackRequest Builder
  ├─ URL
  ├─ Header
  ├─ Referer
  ├─ Cookie
  ├─ User-Agent
  ├─ Range
  └─ DRM/ClearKey
        │
        ▼
PlayerEngine.load()
        │
        ▼
播放器状态监听 / 进度保存 / 错误恢复
```

### 10.3 基础播放功能

| 功能 | MVP-A | MVP-B | 完整版 |
| --- | --- | --- | --- |
| 播放/暂停 | 必须 | 必须 | 必须 |
| 进度条 | 必须 | 必须 | 必须 |
| 拖动 Seek | 必须 | 必须 | 必须 |
| 音量 | 必须 | 必须 | 必须 |
| 静音 | 必须 | 必须 | 必须 |
| 全屏 | 必须 | 必须 | 必须 |
| 上一集/下一集 | 必须 | 必须 | 必须 |
| 播放列表 | 必须 | 必须 | 必须 |
| 倍速 | 后置 | 必须 | 必须 |
| 自动连播 | 后置 | 必须 | 必须 |
| 播放恢复 | 后置 | 必须 | 必须 |
| 线路切换 | 后置 | 必须 | 必须 |
| 快捷键 | 后置 | 必须 | 必须 |
| 音轨选择 | 后置 | 后置 | 必须 |
| 字幕轨选择 | 后置 | 后置 | 必须 |
| 外挂字幕 | 后置 | 后置 | 必须 |
| 截图 | 后置 | 后置 | 必须 |
| 画面比例 | 后置 | 后置 | 必须 |
| 硬解/软解 | 后置 | 后置 | 必须 |
| 网络缓存 | 后置 | 后置 | 必须 |
| 播放诊断 | 后置 | 后置 | 必须 |

### 10.4 播放错误策略

| 场景 | 处理 |
| --- | --- |
| 403/404 | 提示链接失效，建议换线路 |
| HLS 401 | 提示 Header 或 Cookie 丢失 |
| DNS 失败 | 提示网络/代理/DNS 配置 |
| 超时 | 支持重试一次，不无限循环 |
| 格式不支持 | 提示格式详情；只有 Phase 0 已确定的备用路径可使用 |
| 解析失败 | 提示解析器失败原因 |
| 代理失败 | 提示本地代理日志入口 |

### 10.5 播放器验收

- MP4 直链播放成功。
- HLS 播放成功。
- 支持 Range 播放。
- 支持 Header 注入。
- 支持进度恢复。
- 支持倍速。
- 支持上一集/下一集。
- 支持全屏。
- 支持自动连播。
- 播放 30 分钟无崩溃。
- 异常 URL 有明确错误，不卡死 UI。
- 播放器关闭后释放进程/端口/缓存。

---

## 11. 本地代理设计

### 11.1 基础原则

- 默认只监听 `127.0.0.1`。
- 默认随机端口，也允许用户固定端口。
- 不允许开放代理。
- 限制代理目标必须来自当前站点授权列表。
- 所有请求必须记录来源、状态、耗时和错误。
- 响应流必须正确关闭。
- Range、多线程、HLS 会话必须保持一致性。

### 11.2 功能矩阵

| 功能 | MVP-A | MVP-B | 完整版 |
| --- | --- | --- | --- |
| Spider proxy | 后置 | Phase 2 | 必须 |
| HLS 清单重写 | 后置 | Phase 2 | 必须 |
| HLS 分片代理 | 后置 | Phase 2 | 必须 |
| Header 注入 | 必须 | 必须 | 必须 |
| Range 代理 | 后置 | Phase 2 | 必须 |
| 多线程下载代理 | 后置 | Phase 2 | 可选 |
| 广告过滤 | 后置 | Phase 3 | 必须 |
| CENC/DRM 辅助 | 后置 | 后置 | 后置 |
| 请求日志 | 必须 | 必须 | 必须 |
| 端口冲突处理 | 必须 | 必须 | 必须 |

### 11.3 安全要求

1. 只接受本机请求。
2. 校验请求 token。
3. 校验目标 URL 白名单。
4. 不转发内网地址，除非用户显式开启并确认。
5. 不保存 Cookie/Token 到日志。
6. 限制单请求大小和总并发。
7. 请求失败返回明确 4xx/5xx。
8. 不允许把 HTML 错误页伪装成 200 媒体响应。

### 11.3.1 代理会话与凭据传播

- 每次播放创建独立 `sessionId` 和高熵随机 token，token 只授权当前站点、当前播放请求和派生的 HLS 清单、分片、密钥及字幕目标。
- token 必须有短有效期；停止播放、会话超时或应用退出后立即失效，应用重启不得恢复旧 token。
- 每次 DNS 解析、连接和重定向后都重新校验 scheme、主机、端口和解析 IP；默认拒绝 loopback、链路本地、私网及云元数据地址，用户明确授权的本地源除外。
- 日志仅记录 token 指纹、目标主机、状态、字节数和耗时，不记录完整 token、签名 query、Cookie 或 Authorization。
- `Cookie` 和 `Authorization` 默认仅同源传播；跨 origin 重定向必须移除敏感 Header。`Referer`、自定义签名 Header 和 HLS Key 请求按显式域名授权传播。
- `User-Agent` 可在会话内继承，但不得借此覆盖宿主诊断和安全 Header。

### 11.4 代理验收

- 本机播放器可访问代理 URL。
- 非本机请求默认拒绝。
- 无 token 请求拒绝。
- Range 请求返回 206 和正确 Content-Range。
- HLS 主清单、子清单、分片 URL 保持同一会话。
- 代理关闭后端口释放。
- 并发 20 个分片请求不崩溃。
- 异常流被关闭。
- 日志不泄露 Cookie、Authorization 和签名参数。

---

## 12. 解析器设计

### 12.1 支持类型

必须兼容的类型与 PC 端支持情况（与 §5.8、`lib/core/parse_runtime.dart` 一致）：

| 类型 | 说明 | PC 端 |
| --- | --- | --- |
| `type=0` | Web 嗅探（需浏览器内核/WebView 嗅探页面） | ❌ 明确报错 |
| `type=1` | JSON 解析（`GET 解析器url + 目标url`，取 `{url}`/`{data.url}`） | ✅ |
| `type=2` | JSON 扩展解析（携带全部 type=1 解析器为查找表） | ✅ |
| `type=3` | JSON Mix（携带 flag 与全部解析器 `ext`） | ✅ |
| `type=4` | Super（多解析器并发，含 Web 嗅探竞争，依赖 WebView） | ❌ 明确报错 |

> 类型编号以 TVBox/WebHTV 生态与 Android 参考实现为准（`type=0` 为 Web 嗅探、
> `type=1` 为 JSON 解析）。选中 PC 端不支持的 `type=0`/`type=4` 时抛
> `ParseSelectionException`，UI 展示可定位文案，**不静默降级**为直链（§5.8）。

### 12.2 解析流程

```text
播放结果 parse=1 / jx=1
        │
        ▼
选择解析器
  ├─ 默认解析器
  ├─ flag 匹配
  └─ 手动选择
        │
        ▼
构造解析 URL
        │
        ▼
执行解析
        │
        ▼
识别媒体 URL
  ├─ m3u8
  ├─ mp4
  ├─ dash
  └─ 其他媒体格式
        │
        ▼
PlaybackRequest
```

### 12.3 验收

- `parse=0` 不走解析器。
- `parse=1` 或 `jx=1` 必须走解析器。
- `flag` 命中解析器。
- 解析失败不影响直接换源。
- 解析结果必须校验媒体类型。
- 解析过程有超时。
- 不允许无限嗅探。
- 解析日志不记录完整 Cookie/Token。

---

## 13. 直播功能设计

### 13.1 功能范围

完整版必须支持：

- TXT/M3U/JSON 直播源。
- 分组。
- 频道。
- 多线路。
- EPG。
- 回看。
- 直播 Header。
- 直播代理。
- 直播弹幕。

### 13.2 直播模型

```kotlin
data class LiveSource(
    val name: String,
    val url: String,
    val epg: String? = null,
    val proxy: String? = null,
    val referer: String? = null,
    val userAgent: String? = null
)

data class LiveGroup(
    val name: String,
    val channels: List<LiveChannel>
)

data class LiveChannel(
    val name: String,
    val number: Int?,
    val logo: String?,
    val epgId: String?,
    val urls: List<String>
)
```

### 13.3 直播验收

- M3U 可解析。
- TXT 可解析。

| 直播格式 | 支持格式 | 验收 |
| --- | --- | --- |
| M3U | `#EXTM3U`、`#EXTINF`、`group-title`、`tvg-logo`、`tvg-id` | 分组和属性解析正确 |
| TXT | `分组,#c:v:name` 或兼容格式 | 分组层级正确 |
| JSON | WebHTV/TVBox 直播 JSON | 模型转换正确 |

- 频道支持多线路。
- 播放失败可切线路。
- EPG 可加载、刷新、显示当前节目。
- 关闭应用后释放播放资源。

---

## 14. 搜索与站点健康

### 14.1 搜索设计

搜索能力：

- 单站点搜索。
- 多站点并发搜索。
- 快速搜索。
- 分页搜索。
- 搜索结果缓存。
- 搜索取消。
- 搜索结果按站点分组。
- 失败站点显示错误状态，不阻塞其他站点。

### 14.2 站点健康

记录：

- 首页成功率。
- 分类成功率。
- 搜索成功率。
- 详情成功率。

| 指标 | 说明 |
| --- | --- |
| `home_ok / home_total` | 首页成功率 |
| `search_ok / search_total` | 搜索成功率 |
| `detail_ok / detail_total` | 详情成功率 |
| `play_ok / play_total` | 播放成功率 |
| `avg_latency` | 平均耗时 |
| `last_error` | 最近错误 |

TMDB 元数据增强（§27）额外记录：

| 指标 | 说明 |
| --- | --- |
| `tmdb_match_ok / tmdb_match_total` | TMDB 媒体身份匹配成功率 |
| `tmdb_season_resolved / tmdb_season_total` | 季度可确证率（`ambiguous` 不计入成功） |
| `tmdb_cache_hit / tmdb_cache_total` | 缓存命中率（含陈旧兜底命中） |
| `tmdb_auth_blocks` | 鉴权熔断开启次数 |
| `tmdb_stale_fallback` | 陈旧缓存兜底次数 |

### 14.3 搜索验收

- 一个站点失败不影响其他站点。
- 可取消搜索。
- 搜索并发不超过配置上限。
- 结果排序稳定。
- 重复搜索可使用短缓存。
- 搜索无结果时提示准确。

---

## 15. 历史记录与收藏

### 15.1 数据模型

```kotlin
data class PlaybackHistory(
    val id: Long,
    val siteKey: String,
    val vodId: String,
    val vodName: String,
    val vodPic: String?,
    val flag: String,
    val episodeName: String,
    val episodeId: String,
    val positionMs: Long,
    val durationMs: Long,
    val updatedAt: Long,
    val completed: Boolean
)
```

### 15.2 功能要求

- 最近观看列表。
- 继续播放。
- 单条删除。
- 清空历史。
- 历史搜索。
- 收藏站点。
- 收藏影片。
- 收藏分组。

### 15.3 验收

- 播放中写入进度。
- 退出后可恢复。
- 删除后不再出现。
- 清空历史不可误删配置。
- 进度百分比正确。
- 已播完内容可标记完成。
- 数据库异常不影响播放器启动。

---

## 16. 存储设计

### 16.1 存储分区

| 路径 | 内容 |
| --- | --- |
| `~/.config/webhtv-pc/` 或平台配置目录 | 配置、设置 |
| `~/.local/share/webhtv-pc/` | SQLite、历史、收藏 |
| `~/.cache/webhtv-pc/` | 图片、HLS 缓存、Spider 缓存 |
| `~/.local/state/webhtv-pc/logs/` | 日志 |

Windows/macOS 使用平台标准目录。

### 16.2 数据库表

| 表 | 用途 |
| --- | --- |
| `configs` | 配置记录 |
| `sites` | 站点状态 |
| `history` | 播放历史 |
| `favorites` | 收藏 |
| `search_cache` | 搜索缓存 |
| `site_health` | 健康统计 |
| `spider_logs` | Spider 日志摘要 |
| `tmdb_matches` | TMDB 媒体身份匹配结论（§27.4） |
| `tmdb_season_bindings` | 线路级季度绑定（§27.5） |
| `tmdb_route_bindings` | 季度→线路索引（换源候选） |
| `tmdb_season_progress` | 季度进度快照（§27.6） |

### 16.3 验收

- 删除缓存目录后应用可重建。
- 删除数据库后应用可初始化默认库。
- 日志自动轮转。
- 敏感 Header 不明文入库。
- 数据库损坏时启动不被阻塞。

---

## 17. UI 设计

### 17.1 主界面

```text
┌────────────────────────────────────────────────────┐
│ 顶栏：配置 / 站点 / 搜索 / 设置                      │
├──────────────┬─────────────────────────────────────┤
│              │ 分类筛选区                           │
│  侧栏         │ ─────────────────────────────────── │
│  首页         │ 海报网格                             │
│  最近观看     │                                     │
│  收藏         │                                     │
│  直播         │                                     │
│  设置         │                                     │
└──────────────┴─────────────────────────────────────┘
```

### 17.2 页面清单

| 页面 | MVP-A | MVP-B | 完整版 |
| --- | --- | --- | --- |
| 启动页 | 必须 | 必须 | 必须 |
| 配置导入页 | 必须 | 必须 | 必须 |
| 配置管理页 | 后置 | 必须 | 必须 |
| 站点列表 | 必须 | 必须 | 必须 |
| 首页/分类页 | 必须 | 必须 | 必须 |
| 详情页 | 必须 | 必须 | 必须 |
| 播放器页 | 必须 | 必须 | 必须 |
| 搜索页 | 后置 | 必须 | 必须 |
| 历史页 | 后置 | 必须 | 必须 |
| 收藏页 | 后置 | 必须 | 必须 |
| 设置页 | 后置 | 必须 | 必须 |
| 日志页 | 后置 | 必须 | 必须 |
| 直播页 | 后置 | 后置 | 必须 |
| 站点健康页 | 后置 | 后置 | 必须 |
| Spider 管理页 | 后置 | 必须 | 必须 |
| TMDB 详情页 | 后置 | 后置 | 必须 |
| TMDB 设置页 | 后置 | 后置 | 必须 |
### 17.3 播放器界面

包含：

- 播放器画面。
- 标题。
- 线路选择。
- 剧集列表。
- 播放/暂停。
- 进度条。
- 音量。
- 倍速。
- 全屏。
- 上一集/下一集。
- 加载状态。
- 错误提示。

### 17.4 桌面 UI 要求

- 支持键盘导航。
- 支持鼠标拖拽。
- 支持窗口缩放。
- 支持深色模式。
- 支持中文优先。
- 支持国际化框架。
- 不把移动端手势作为唯一交互。
- 不使用移动端竖屏布局。

### 17.5 UI 验收

- 1280×720 下无关键 UI 被遮挡。
- 1920×1080 下布局稳定。
- 缩放窗口不崩溃。
- 全屏进入/退出正常。
- 键盘可完成核心播放操作。
- 深色/浅色模式均可用。
- 中文文案不截断。

---

## 18. 安全与权限设计

### 18.1 权限分级

| 权限 | 默认 | 说明 |
| --- | --- | --- |
| `network` | 询问或源声明 | 允许网络请求 |
| `localProxy` | 禁止 | 可申请开启 |
| `storage` | cache-only | 默认只允许缓存 |
| `clipboard` | 禁止 | 不建议开放 |
| `browser` | 禁止 | 不允许访问系统浏览器 Cookie |
| `ui` | 禁止 | 不允许直接操作主 UI |
| `process` | 询问 | 是否可启动子进程 |

### 18.2 用户安全策略

- 配置导入时展示风险提示。
- Spider 运行时展示权限。
- 本地代理默认仅本机。
- 日志脱敏。
- 配置内容不自动执行任意本地脚本。
- 远程脚本只在工作目录内运行。
- 每个站点运行时可随时强制停止。
- 每个站点可随时禁用网络、代理、存储权限。

### 18.2.1 平台隔离边界

独立子进程只提供崩溃隔离，不自动提供文件系统和网络沙箱。各平台必须验证实际隔离机制：

- Linux：优先使用 bubblewrap、Landlock、mount namespace、`no_new_privs`、rlimit 或 cgroup 的组合。
- Windows：评估 Restricted Token、AppContainer、Job Object、文件 ACL 和子进程树终止。
- macOS：评估 App Sandbox、hardened runtime、sidecar 签名、公证和动态库加载限制。

若某个平台无法可靠阻止读取同一用户可访问的文件，产品文案和验收报告必须明确标记为“尽力隔离”，不得宣称强隔离；该平台默认禁用不可信远程 Spider，直到风险由用户明确确认。

网络权限必须使用结构化策略，至少声明允许的 scheme、域名、子域名、端口、重定向次数，以及是否允许 loopback、私网和本地代理；单个布尔值 `network=true` 只表示申请网络能力，不能替代目标访问控制。

### 18.3 安全验收

| 测试 | 预期 |
| --- | --- |
| Spider 无限循环 | 超时或被终止，不影响主程序 |
| Spider 崩溃 | 主程序继续运行 |
| Spider 尝试读配置目录 | 拒绝 |
| Spider 尝试访问系统浏览器 | 拒绝 |
| 本地代理被局域网访问 | 默认拒绝 |
| 日志输出 Cookie | Cookie 被脱敏 |
| 无效配置 | 不执行 |
| 远程 JAR/脚本损坏 | 明确失败，不影响其他站点 |

---

## 19. 测试策略

测试资产和测试名称必须与 UI 语言无关。Phase 0 选型后，测试实现可选择 Flutter test、Kotlin Test 或语言无关的 CLI 测试，但 fixture 和预期结果不能分叉。

### 19.1 测试分层

| 层 | 测试类型 | 建议工具 |
| --- | --- | --- |
| 协议 | 单元/契约测试 | Dart test 或 Kotlin Test，以选定路线为准 |
| 站点 | 契约测试 | Mock HTTP + fixture |
| 搜索 | 并发/取消测试 | 所选语言的异步测试框架 |
| 播放器 | 手动 + 自动烟测 | media-kit 或 libmpv + 本地媒体 |
| 代理 | HTTP 集成测试 | 对应平台 HTTP 测试框架 |
| UI | 自动化 + 截图 | Flutter integration test 或 Compose UI test |
| 打包 | CI 矩阵 | Linux/Windows/macOS runner |

### 19.2 必备 fixture

| 名称 | 用途 |
| --- | --- |
| `config-min.json` | 最小合法配置 |
| `config-full.json` | 全字段配置 |
| `config-invalid-msg.json` | 错误配置 |
| `result-home.json` | 首页 |
| `result-category.json` | 分类 |
| `result-detail.json` | 详情 |
| `result-play.json` | 播放 |
| `config-repository.json` | `urls` 配置仓库 |
| `config-msg-empty.json` | 空 `msg` |
| `config-msg-error.json` | 非空 `msg` |
| `config-ext-base64.json` | `ext` 对象与 URL-Safe Base64 |
| `result-multi-flag.json` | 多线路 |
| `result-multi-episode.json` | 多剧集 |
| `result-error-html.json` | HTML 错误页 |
| `result-msg.json` | 业务错误 `msg` |
| `live.m3u` | 直播源 |
| `live.txt` | TXT 直播源 |
| `hls/index.m3u8` | 本地 HLS |
| `media/sample.mp4` | 本地 MP4 |
| `tmdb/config/tmdb-config-full.json` | TMDB 配置全字段（§27） |
| `tmdb/config/tmdb-config-alias.json` | TMDB 配置兼容别名键 |
| `tmdb/config/tmdb-config-invalid.json` | TMDB 非法配置（反向校验） |
| `tmdb/detail-tv.json` | TMDB 剧集详情 |
| `tmdb/detail-tv-next-air.json` | 含未播集的剧集详情（动态 TTL） |
| `tmdb/detail-movie.json` | TMDB 电影详情 |
| `tmdb/season-{0,1,2}.json` | TMDB 分季（特别篇/第 1 季/第 2 季） |
| `tmdb/season-empty.json` | 空季度（退化用例） |
| `tmdb/search-multi.json` | TMDB 多类型搜索 |
| `tmdb/search-split-season.json` | 含分季变体的搜索（防护用例） |
| `tmdb/videos-tv.json` | 相关视频（含非法 key） |
| `tmdb/error-{401,500}.json` | TMDB 鉴权/服务端错误 |
| `tmdb/malformed.json` | TMDB 非法 JSON 响应 |

### 19.3 自动化测试范围

必须覆盖：

- JSON/XML 配置解析。
- Result/Vod 转换。
- 多线路/多剧集解析。
- URL/Base64/相对路径解析。
- Header 合并。
- 解析器选择。
- 搜索并发和取消。
- 历史写入/恢复。
- HLS 代理。
- Range 代理。
- 权限拦截。
- 日志脱敏。
- `urls` 仓库展开和嵌套更新。
- gzip/br、BOM、GB18030、重定向、超大响应。
- `ext` Base64 URL-Safe 编解码。
- 解析优先级 `parse`/`jx`/`flag`/`playUrl`。
- Spider ABI 版本协商、capability、取消和错误码。
- TMDB 标题清洗、年份与季度信号解析。
- TMDB 匹配评分与分季变体防护。
- TMDB 站点策略（黑/白/启用三张规则表与括号归一）。
- TMDB 匹配缓存三层键与手动选择排他性。
- TMDB 季度解析优先级与可播放季度退化。
- TMDB 季度绑定分段校验与失效。
- TMDB 季度进度写入/读取/换源/删除语义。
- TMDB 缓存 TTL、陈旧兜底、鉴权熔断与错误分类。

### 19.4 兼容性样本库

fixture 只能证明解析逻辑正确，不能证明现实站点可用。必须额外维护兼容性样本库：

| 类别 | 最低样本 | 记录内容 |
| --- | --- | --- |
| XML API | 10 | 站点标识、验证时间、网络地区、结果 |
| JSON API | 10 | 站点标识、验证时间、网络地区、结果 |
| HTTP Spider | 3 | ABI 版本、验证时间、结果、崩溃/超时 |
| JS Spider | 3 | 运行时版本、权限、验证结果 |
| Python Spider | 3 | 运行时版本、依赖、验证结果 |
| Java Spider | 3 | JVM 版本、Android 依赖情况、结果 |
| TMDB 真实作品 | 10 | TMDB 作品 ID、匹配来源标题、季度解析结论、验证时间 |

规则：

- 不把含凭据、付费地址或用户 Cookie 的完整配置提交到仓库。
- CI 默认只运行本地 fixture 和匿名样本。
- 真实源验证默认手动触发，结果本地保存。
- 每个样本必须区分“协议失败”“站点失效”“地区限制”“播放器失败”。
- 发布前提供最近一次分层兼容性报告：公开 fixture 必须有可复现结果，私有真实源只记录脱敏后的统计和验证时间，禁止只写“支持 TVBox 配置”而没有样本数据。

### 19.5 手动验收环境

| 系统 | 最低分辨率 | 验收重点 |
| --- | --- | --- |
| Linux X11 | 1920×1080 | 播放器、AppImage/deb |
| Windows 10/11 | 1920×1080 | 安装包、播放、路径 |
| macOS | 1280×800 | 窗口、快捷键、签名 |
| Linux Wayland | 1920×1080 | 窗口/全屏 |

---

## 20. 构建与打包

### 20.1 构建原则

- Phase 0 必须同时验证开发和发行包，不允许最后阶段才处理 native 依赖。
- 主程序、播放器 native 库、sidecar runtime 和用户数据必须分层管理。
- 开发包不得包含真实站点源、用户配置、Cookie、日志或测试凭据。
- 同一版本必须能输出可复现的版本号、构建时间、Git revision 和平台标识。
- 未选择的 UI 候选路线不得进入正式构建矩阵。

### 20.2 构建矩阵

| 目标 | 类型 | Phase 0 | 正式发布 |
| --- | --- | --- | --- |
| Linux x86_64 | AppImage、deb | 必须 | 必须 |
| Windows x86_64 | MSI、便携 zip | 必须 | 必须 |
| macOS aarch64 | dmg | 可用时验证 | 必须 |
| macOS x86_64 | dmg | 可选 | 可选 |
| Linux Wayland | 同一 Linux 包 | 手动烟测 | 必须记录兼容性 |

### 20.3 打包内容

- 主程序。
- 选定播放器引擎及所需 native 库。
- 按需下载或内置的 JS/Python/JVM sidecar。
- 默认不打包站点源。
- 默认不打包用户配置。
- 许可证、第三方 NOTICE 和动态库版本清单。
- 发布校验文件：SHA256、版本、平台、架构、签名状态。

### 20.4 平台专项要求

#### Windows

- 安装包支持覆盖升级，用户数据默认保留。
- 便携版不写系统注册表。
- 路径支持非 ASCII 和空格。
- 代码签名在正式发布前完成；未签名包必须明确标识。

#### macOS

- 需要 arm64 原生构建和签名、公证流程验证。
- Spider sidecar 必须按 Apple 要求处理签名、路径和权限。
- 若使用 libmpv，必须验证动态库依赖路径和 Gatekeeper 行为。

#### Linux

- 验证 AppImage、deb 和不同 glibc 环境。
- 验证 X11 与 Wayland 下全屏、窗口缩放和输入。
- native 依赖必须通过 rpm/deb 或 AppImage 明确声明，不允许依赖开发机环境。

### 20.5 打包验收

- 空配置首次启动可进入导入页。
- 安装、覆盖安装、卸载均符合用户数据保留策略。
- 安装包无站点源、用户配置、测试凭据和开发日志。
- 启动日志记录版本、平台、架构、播放器引擎和运行时版本。
- 不依赖开发机上的 PATH、HOME 或预装 libmpv 才能启动。
- Release 包必须通过签名/公证或输出明确的降级说明。

---

## 21. 实施阶段

### 版本层级定义

- **Phase 0 原型**：不发布，仅用于技术路线比较和 ADR 冻结。
- **MVP-A 内部预览版**：仅供内部验证 HTTP API 配置导入、浏览、详情和播放闭环，不作为首个公开版本。
- **MVP-B 首个公开测试版**：加入搜索、历史、进度恢复、CatSpider HTTP 子集、基本代理和 Spider 安全边界。
- **正式版**：满足 22.5 节发布门禁；不要求 Phase 5 同步能力全部完成，但所有未支持能力必须明确披露。

后续章节中的“首版”统一指 MVP-B；“内部预览版”专指 MVP-A。

### Phase 0：技术验证与冻结

目标：证明技术路线可交付，并冻结主 UI、播放器和 ABI。

任务：

1. 建立 `packages/protocol` 和 `packages/spider-abi` 雏形。
2. 搭建 Flutter/media-kit 原型。
3. 搭建 Kotlin/Compose/libmpv 原型。
4. 两条路线各自播放本地 MP4 和本地 HLS。
5. 两条路线各自验证带 Header 的远程 HLS、Seek、全屏和异常 URL。
6. 实现最小 JSON 配置解析和 HTTP API 站点闭环。
7. 验证 Linux 与 Windows 至少各一端可构建、启动和播放。
8. 验证 macOS 构建流程或有明确阻塞记录。
9. 完成两套原型对比矩阵和 ADR。
10. 冻结主路线，删除未选路线或移出产品仓库。

验收：

- 5.5 节所有决策门通过。
- 至少一条路线完成配置导入到播放闭环。
- 未通过项有复现步骤、影响范围和规避方案。
- ADR 明确主语言、UI、播放器、代理、sidecar 发行和打包方案。
- 未冻结技术路线前不进入 MVP-A。

### Phase 1：MVP-A 单站点垂直闭环

目标：用最少功能证明“配置导入 → 浏览 → 详情 → 播放”。

功能：

- 启动页。
- URL/文件/JSON 文本配置导入。
- 一个可用 HTTP API 站点。
- 站点列表。
- 首页/分类。
- 详情。
- 单线路、单剧集播放。
- 播放/暂停、Seek、音量、静音、全屏、上一集/下一集。
- Header 注入。
- 基础错误提示。
- 最小日志和诊断。

验收：

- 使用一份标准 TVBox 配置完成导入。
- HTTP API `type=0`、`type=1`、`type=2`、`type=4` 每种类型至少使用一个固定 fixture 完成自动契约测试，并各使用至少一个真实样本完成首页、分类、详情、播放闭环；真实样本不稳定时保存脱敏请求与响应快照用于回归。
- 分类、分页、详情、播放能用。
- 播放失败不会卡死 UI，错误可定位。
- 不要求搜索、历史、设置、收藏、直连 Spider 运行时。

### Phase 2：MVP-B 产品基础和 Spider ABI

目标：形成可日常使用的 MVP，并建立可验证的 Spider 兼容基础。

功能：

- 多配置管理。
- 搜索与并发取消。
- 播放历史与进度恢复。
- 收藏。
- 播放倍速、自动连播、线路切换、快捷键。
- 设置页。
- 日志页。
- `webhtv-ipc-v1` 和 `webhtv-cat-http-v1` 契约。
- CatSpider HTTP 子集。
- Spider 进程隔离、超时、取消、资源限制。
- Spider 管理页。
- Spider proxy。
- HLS 代理、Range 代理。

验收：

- HTTP API 源可浏览、搜索、播放。
- 播放进度可恢复。
- CatSpider HTTP 有至少 3 个可重复测试样本。
- Spider 崩溃、超时、取消和资源超限被隔离。
- 代理安全测试通过。
- 主流程无阻塞式崩溃。

### Phase 3：Spider 运行时与播放增强

目标：扩充生态兼容和播放入口。

功能：

- JS/Node Spider。
- Python Spider。
- PC Java Spider。
- 字幕。
- 弹幕。
- 解析器。
- 换源。
- 直播。
- EPG。
- 广告过滤。
- 播放诊断增强。

验收：

- JS/Python/Java 每类至少 3 个可重复测试样本，或明确列出不支持的共同特征。
- 字幕/弹幕可开启和关闭。
- 解析器可按 `flag`、`parse`、`jx` 选择。
- 直播 M3U/TXT/JSON 可播放。
- 播放诊断能输出引擎、格式、网络和错误。

### Phase 4：TMDB 元数据增强

目标：参考 `webhtv/默影视` 的 TMDB 能力，用 TMDB 作为**元数据源**（而非播放事实源）
完成「匹配 → 详情 → 季度/选集 → 续播 → 换源」闭环。

功能：

- TMDB 配置与鉴权（API Key / v4 Access Token，站点规则）。
- 媒体身份匹配与持久化缓存（含手动匹配）。
- 标题清洗、年份与季度信号解析、匹配评分与分季变体防护。
- 季度解析与线路级绑定（显式三态 `SeasonScope`）。
- 可播放季度解析与选集过滤（不创建播放项）。
- 季度进度快照与跨源续播。
- 详情页元数据增强（头部补位、季度选择器、剧集标题/剧照）。
- 演职人员、剧照墙、相关推荐与相关视频。
- 纯 TMDB 详情页（无播放能力，可跳搜索站源）。

验收：

- TMDB 匹配、季度解析、可播放季度、季度进度的自动化门禁全绿。
- 真实窗口集成：详情增强、季度切换、续播、换源续播、手动匹配持久化。
- TMDB 失败不影响站源浏览与播放，且不阻塞 UI。
- 选集区不出现无线路地址的播放项；未确证季度不伪造“第一季”。
- TMDB 凭据在日志与诊断导出中脱敏。
- 门禁与证据写入 `docs/phase4/evidence/windows-acceptance.txt`。

实施状态：**已完成**。一键验收 `PHASE4-ACCEPT result=PASS gates=all`
（单元 1122 例 + 16 个 `phase4_tmdb_*` 套件 + 5 个 `-d windows` 集成套件 +
契约 9 例 + 脱敏门禁；三项反向验证均按预期失败后还原）。

> 详细设计指导见 `docs/phase4/design/00`–`design/05`，阶段计划见 `docs/phase4/README.md`，
> 主设计文档摘要见 §27。

---

### Phase 5：生态与同步

目标：建立与 WebHTV 和其他设备的可选协同能力。

功能：

- 与 WebHTV 配置同步。
- 播放历史同步。
- 收藏同步。
- 站点健康同步。
- WebHome/管理页复用。
- 远程管理。
- 多设备协同。

验收：

- PC 与 Android 配置可互导。
- 历史同步不产生重复记录。
- 删除有墓碑机制。
- 同步失败不破坏本地数据。
- 所有同步默认关闭并需要用户明确开启。

## 22. 总验收清单

### 22.1 功能验收

| 分类 | 验收项 | 阶段 |
| --- | --- | --- |
| 技术 | Phase 0 路线 ADR | 0 |
| 技术 | 播放器内嵌、HLS、Header、全屏 | 0 |
| 技术 | Windows/Linux 构建烟测 | 0 |
| 配置 | URL/文件/JSON 导入 | 1 |
| 配置 | 无效配置提示 | 1 |
| 配置 | 多配置管理 | 2 |
| 站点 | HTTP API 首页 | 1 |
| 站点 | 分类和分页 | 1 |
| 站点 | 详情 | 1 |
| 站点 | 播放 | 1 |
| 站点 | 搜索 | 2 |
| 播放器 | 播放/暂停/Seek | 1 |
| 播放器 | 音量/全屏/上一集/下一集 | 1 |
| 播放器 | 倍速/自动连播/线路切换 | 2 |
| 历史 | 播放记录 | 2 |
| 历史 | 恢复进度 | 2 |
| 设置 | 设置页和日志页 | 2 |
| 安全 | 日志脱敏 | 2 |
| Spider | ABI v1 协商 | 2 |
| Spider | CatSpider HTTP | 2 |
| Spider | JS Spider | 3 |
| Spider | Python Spider | 3 |
| Spider | PC Java Spider | 3 |
| 代理 | Spider proxy | 2 |
| 代理 | HLS 代理 | 2 |
| 代理 | Range 代理 | 2 |
| 播放器 | 字幕 | 3 |
| 播放器 | 弹幕 | 3 |
| 直播 | M3U/TXT/JSON | 3 |
| 直播 | EPG | 3 |
| TMDB | 配置与鉴权 | 4 |
| TMDB | 媒体身份匹配与缓存 | 4 |
| TMDB | 手动匹配与持久化 | 4 |
| TMDB | 季度解析与线路级绑定 | 4 |
| TMDB | 可播放季度与选集过滤 | 4 |
| TMDB | 季度进度与跨源续播 | 4 |
| TMDB | 详情页元数据增强 | 4 |
| TMDB | 相关推荐与相关视频 | 4 |
| TMDB | 纯 TMDB 详情页 | 4 |
| 同步 | 配置/历史/收藏同步 | 5 |

### 22.2 质量验收

- 单元测试通过。
- 协议 fixture 全部通过。
- 兼容性样本库有最近一次报告。
- 代理安全测试通过。
- UI 冒烟测试通过。
- 选定主路线在 Linux/Windows 完成一轮手动验收；macOS 发布前必须完成。
- 无 P0/P1 缺陷。
- 30 分钟播放稳定性测试通过。
- 冷启动在固定参考机器、Release 发行包上测试 10 次；从进程启动到首个可交互主界面，报告中位数和 P95，P95 低于 3 秒。
- 本地 MP4 首帧从调用 `load` 到第一帧实际呈现，固定素材测试 10 次，报告中位数和 P95，P95 不超过 5 秒。
- 远程 HLS 使用固定 Mock Server 和受控延迟/带宽，分别记录 DNS、连接、响应、缓冲和解码耗时；网络异常必须展示具体阶段，不与本地首帧指标混算。
- 内存无持续增长异常。
- 退出后主进程、sidecar 和代理端口全部释放。

### 22.3 安全与隐私验收

- Spider 不可读取宿主数据库、配置目录、Cookie 和系统浏览器。
- 远程脚本执行前有来源和权限确认。
- 日志默认不记录 Cookie、Authorization、完整 query 和媒体签名。
- 崩溃上报默认关闭，启用后必须展示上传内容。
- 代理默认仅监听 `127.0.0.1` 并校验 token。
- 用户数据删除有明确入口。
- 自动更新只更新应用，不自动更新站源。

### 22.4 合规验收

- 应用不内置站点配置。
- 应用不内置站源。
- 应用不内置影视资源。
- 首次启动展示使用边界提示。
- README 明确用户责任。
- 不采集用户观影数据。
- 不上传用户配置，除非用户显式开启同步。

### 22.5 发布门禁

任一条件不满足时不得标记为正式发布：

1. Phase 0 ADR 未冻结主技术路线。
2. 正式安装包来自未选择的候选路线或依赖开发机环境。
3. 配置、代理或 Spider 测试存在未处理的敏感信息泄露。
4. 主平台播放器无法内嵌、无法全屏或退出后残留进程。
5. Spider 能绕过权限访问宿主文件或网络代理。
6. 兼容性报告缺失，或只覆盖 fixture 没有真实样本。
7. 发布包包含站点源、用户配置、Cookie、日志或测试凭据。

---

## 23. 关键决策记录

| 决策 | 当前结论 | 冻结条件 |
| --- | --- | --- |
| 新建项目还是改造 | 新建项目 | 已确认，不直接改造 Android/Qt/Flutter 项目 |
| 首版语言 | 待 Phase 0 ADR | Flutter/Dart 与 Kotlin/JVM 双原型对比后冻结 |
| 首版 UI | 待 Phase 0 ADR | 同一阶段只保留一条路线 |
| 首版播放器 | 待 Phase 0 ADR | media-kit 与 libmpv 通过同组媒体验收后选择 |
| 首版站源 | HTTP API + CatSpider HTTP 子集 | HTTP API 先通过，CatSpider 需 ABI 契约 |
| Android Jar 兼容 | 后置到 Phase 3 | 独立 JVM sidecar 与安全隔离完成后 |
| Spider 进程模型 | 独立 sidecar | 主进程不得加载不可信代码 |
| 本地代理 | 默认仅本机 | 安全测试通过 |
| PiliPala | 只参考交互 | GPL 与产品定位限制 |
| atv-player | 只参考设计 | 授权不明确且绑定 alist-tvbox |
| 双路线维护 | 禁止长期并存 | Phase 0 结束必须冻结并清理 |
| TMDB 定位 | 元数据增强，不改变播放事实源 | §27 设计指导评审通过 |
| TMDB 配置位置 | 应用设置（`settings.json` 的 `tmdb` 段），**不进配置 JSON** | §27.3 |
| TMDB 凭据导出 | 不导出、不写日志、不入诊断包 | §22.3、§27.3 |
| 季度身份表达 | 显式三态 `SeasonScope`，禁止整数默认值兼表 | §27.5 |
| 季度绑定粒度 | 线路级（`siteKey + vodId + flagKey`） | §27.5 |
| 自动季度落盘 | 仅结果唯一时落盘；多候选进入手动匹配 | §27.5 |
| 历史展示键 | 已确证季度按季度聚合，未确证按来源键隔离 | §27.6 |
| 详情页形态 | 新建 TMDB 详情页，不改造成站点详情页 | §27.7 |
| 相关视频入口 | 浏览器打开 + 复制链接，不做应用内播放 | §27.7 |
| 未知季度处理 | 不默认第一季、不伪造季度标签 | §27.5 |

---

## 24. 最小实施顺序

```text
1. 建立协议 Schema、fixture 和 ADR 目录
2. 建立 Flutter/media-kit Phase 0 原型
3. 建立 Kotlin/Compose/libmpv Phase 0 原型
4. 验证 MP4/HLS/Header/Seek/全屏/打包
5. 验证 HTTP API 配置到播放闭环
6. 写 Phase 0 对比报告并冻结主路线
7. 实现 MVP-A：导入/分类/详情/播放
8. 实现 MVP-B：搜索/历史/设置/多配置
9. 实现 ABI v1、sidecar、CatSpider HTTP 和代理
10. 实现 JS/Python/Java Spider
11. 实现字幕/弹幕/解析器/直播/EPG
12. 实现 TMDB 元数据增强（匹配/季度/进度/详情页）
13. 实现同步与生态能力
14. 执行发布门禁和兼容性报告
```

---

## 25. 完成定义

PC 播放器只有同时满足以下条件才可称为完整可发布：

1. Phase 0 ADR 已冻结主 UI、播放器和 Spider 发行方案。
2. 配置协议覆盖 WebHTV/TVBox/猫源核心字段，并按 7.4、7.5 节通过边界测试。
3. HTTP API、CatSpider HTTP、JS、Python、PC Java 运行时在声明支持的范围内通过对应 fixture 和真实样本验证。
4. 选定播放器稳定支持直链、HLS、Header、Range、Seek、全屏和进度恢复。
5. 本地代理和 Spider 安全测试通过，无越权文件、网络和日志泄露。
6. 搜索、详情、播放、历史闭环可用。
7. 字幕、弹幕、解析器、直播、EPG 完整版验收通过，或明确列为未支持能力。
8. TMDB 元数据增强的匹配/季度/进度/详情页验收通过，或明确列为未支持能力；
   未确证季度不得被降级为第一季，选集区不得出现无线路地址的播放项。
9. Linux/Windows/macOS 打包可安装、可运行，签名和公证状态明确。
10. 自动化测试、手动验收和兼容性报告全部记录并可复查。
11. 无 P0/P1 缺陷。
12. 不内置资源，合规边界清晰。
13. 发布包通过 22.5 节全部门禁。

---

## 26. 附录：术语

| 术语 | 定义 |
| --- | --- |
| TVBox 配置 | 以 `sites/parses/lives/spider` 为核心的 JSON 配置 |
| 猫源 | CatVod 生态 Spider/站点源协议 |
| Result | Spider/API 返回的首页、分类、详情、搜索结构 |
| Vod | 影视条目模型 |
| Spider | 可执行站源，返回统一协议 |
| CatSpider | HTTP 协议 Spider |
| Spider ABI | 站源与宿主之间的二进制/调用接口约定 |
| HLS | HTTP Live Streaming，M3U8 清单和分片 |
| Range | HTTP 分段请求 |
| EPG | 电子节目指南 |
| 媒体身份（MediaIdentity） | `mediaType + tmdbId`；同一剧集的不同季度共享该身份 |
| 季度身份（SeasonIdentity） | `MediaIdentity + KnownSeasonNumber`；用于历史展示、续播、进度与删除边界 |
| 季度范围（SeasonScope） | 显式三态：`Known(n)` / `Multi(segments)` / `Unknown` |
| 来源线路绑定（SourceBinding） | `siteKey + vodId + flagKey` → `SeasonScope` |
| 元数据季度 | TMDB 返回的完整季度，仅用于标题/剧照/日期等丰富 |
| 可播放季度 | 依据当前线路剧集能可靠确证的季度，用于季度导航与选集过滤 |
| 季度进度快照 | 按 `mediaType + tmdbId + seasonNumber` 记录的可恢复播放位置 |
| 来源指纹（SourceFingerprint） | 线路剧集结构的稳定摘要，用于判断旧绑定是否失效 |
| 分季变体（SplitSeasonVariant） | TMDB 中把一部剧拆成多个独立条目的形态，需惩罚以避免误匹配 |
| 元数据源 vs 播放事实源 | TMDB 只丰富线路已有的播放项，不创建播放项 |

---

## 27. TMDB 元数据增强

- 定位：参考 `webhtv/默影视` 的 TMDB 能力，在 PC 端提供**元数据增强**，不改变播放事实源。
- 状态：设计指导已补齐（`docs/phase4/design/00`–`design/05`），**实施已完成**（T1–T18），
  一键验收 `PHASE4-ACCEPT result=PASS gates=all`（`docs/phase4/evidence/windows-acceptance.txt`）。
- 完整设计指导：`docs/phase4/design/00-tmdb-design-index.md`（索引）、
  `01`（身份与匹配）、`02`（季度与进度）、`03`（服务/配置/存储）、
  `04`（详情页与播放）、`05`（测试与验收）。
- 阶段计划：`docs/phase4/README.md`。

### 27.1 四条不可退让的原则

1. **元数据源 ≠ 播放事实源**：选集区只展示当前线路真实存在的剧集；TMDB 只丰富播放项，
   **不创建播放项**。TMDB 有某集而线路没有时，不生成该集卡片。
2. **不确定即未知**：季度用显式三态 `SeasonScope = Known(n) | Multi(segments) | Unknown`
   表达，禁止用整数默认值兼表“特别篇”和“未解析”，禁止默认第一季。
3. **安全退化优先**：TMDB 失败时保留来源标题、来源历史与原线路，不改变已保存绑定；
   可以暂时重复展示，但不能跨季度恢复错误进度。
4. **主进程不加载不可信代码，凭据不外泄**：TMDB 只走主进程 HTTP 客户端，不进 sidecar、
   不新增 ABI；API Key / Access Token 在日志与诊断导出中必须脱敏。

### 27.2 分层与模块边界

| 层 | 模块 | 职责 |
| --- | --- | --- |
| 纯逻辑 | `lib/core/tmdb_title.dart` | 标题清洗、年份、季度信号、匹配评分 |
| 纯逻辑 | `lib/core/tmdb_identity.dart` | 媒体身份、匹配记录、缓存三层键 |
| 纯逻辑 | `lib/core/tmdb_config.dart` | 配置归一化、站点策略 |
| 纯逻辑 | `lib/core/tmdb_season.dart` | `SeasonScope`、季度解析、可播放季度、分段校验、指纹 |
| 纯逻辑 | `lib/core/tmdb_media.dart` | 剧集/人物/图片/相关视频模型 |
| 服务 | `lib/services/tmdb_service.dart` | 端点封装、TTL、熔断、错误映射 |
| 服务 | `lib/services/tmdb_cache.dart` | 文件缓存与陈旧兜底 |
| 服务 | `lib/services/tmdb_identity_service.dart` | 匹配编排 + 缓存读写 |
| 服务 | `lib/services/tmdb_season_service.dart` | 季度解析编排 + 绑定读写 |
| 服务 | `lib/services/tmdb_enrichment_service.dart` | 元数据应用到 `Vod`/线路/剧集 |
| 状态 | `lib/state/tmdb_state.dart` | `ChangeNotifier`，含代际防迟到响应 |
| UI | `lib/ui/tmdb_widgets.dart`、`lib/ui/tmdb_detail_page.dart` | 详情增强、季度选择器、手动匹配、纯 TMDB 详情页 |

约束：`lib/core/**` 不得依赖 Flutter 或 `dart:io`（纯逻辑必须可在 `flutter test` 无副作用运行）。
不继承上游 `TmdbDetailActivity`（12667 行）与 `TmdbUIAdapter`（2451 行）的单体结构。

### 27.3 配置与凭据

TMDB 配置放在应用设置 `<configDir>/settings.json` 的 `tmdb` 段，**不进入站源配置 JSON**。

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关 |
| `apiBase` | `https://api.tmdb.org/3` | 归一化为以 `/3` 结尾 |
| `apiKey` | `""` | v3 Key；与 `accessToken` 至少其一非空 |
| `accessToken` | `""` | v4 Token；非空时用 `Authorization: Bearer`，不再附加 `api_key` |
| `language` | `zh-CN` | |
| `imageBase` / `backdropBase` | `w342` / `w780` | 图片基址 |
| `enabledSites` / `allowedSites` / `disabledSites` | 见 §27.4 | 站点规则三张表 |
| `smartMatch` | `true` | 智能匹配开关 |
| `heuristicSeasonGuessing` | `true` | 启发式季度推断开关 |

凭据保护：日志只输出末 4 位；诊断包内替换为 `<redacted>`；不随配置同步/导出；
设置页默认掩码。凭据泄露即视为发布门禁不通过（§22.5 第 3 项）。

### 27.4 媒体身份匹配

```text
MediaIdentity = mediaType + tmdbId
```

匹配流程：缓存查询 → 标题清洗 → 候选查询（上限 3）→ 结果过滤 → 三级选择
（`strict` → `containedYear` → `smart`）→ 年份拆分重试（仅一次）→ 落盘。

- **分季变体防护**：TMDB 详情标题含“分季”且源文本不允许分季时，该候选**直接丢弃**；
  四档得分 `+140 / 0 / +160 / -240` 用于多候选裁决。
- **站点策略**判定顺序：`disabledSites` 精确 → `allowedSites` 精确 → `enabledSites` 精确
  → `disabledSites` 子串 → `enabledSites` 为空则允许 → `enabledSites` 子串 → 拒绝。
- **括号归一**：`「」【】〔〕［］` 统一为 `[]`；不做归一则猫源（全角括号）默认规则一条也匹配不上。
- **匹配缓存三层键**：条目级 / 条目+标题 / 全局标题域；**手动结论不被自动匹配覆盖**。
- **手动匹配**：支持 `tmdb:12345` / `movie:12345` / `tv:12345` 直达；剧集需继续选择季度。

未配置或站点被禁用时**零网络请求**。

### 27.5 季度解析、绑定与可播放季度

```text
SeasonIdentity = MediaIdentity + KnownSeasonNumber
SourceBinding  = siteKey + vodId + flagKey  →  SeasonScope
```

- 绑定粒度必须下沉到**线路**（`flagKey`），否则同详情多季线路会互相污染进度。
- 季度解析按固定优先级（请求 → 手动 → 显式 → 标题 → 单季 → 集数 → 扁平集号 → 未知），
  **后级不得覆盖前级**；只有结果**唯一**时才允许自动落盘，多候选进入手动匹配。
- 可播放季度按 6 级顺序解析（显式完整映射 → 标题 → 唯一 TMDB 季 → 精确切片 → 扁平集号 →
  单季兼容），无法可靠映射时返回空并**退化为扁平列表**。
- `MultiSeason` 分段必须通过 8 条有效性校验（连续无空洞、完整覆盖、不越界等）。
- 未知季度**不应用** TMDB 剧集元数据（不默认第 1 季、不尝试第 0 季兜底）。

### 27.6 季度进度、历史与换源

```text
TmdbSeasonProgressKey = mediaType + tmdbId + seasonNumber
```

- 只有已确证季度（`Known` 或 `Multi` 的实际段）才写季度进度；`Unknown` 只更新来源历史。
- 播放另一季度**不覆盖**当前季度快照。
- 历史展示键：已确证季度按 `mediaType:tmdbId:season:N` 聚合；未知按来源键隔离；
  电影按 `mediaType:tmdbId`。同一节目的不同季度生成**不同**历史卡片。
- 自动换源必须通过季度兼容判定：`Known(N)` 接受 `Known(N)` 与含 N 的 `Multi`，
  拒绝其他 `Known(M)` 与 `Unknown`。
- 删除分级：删除季度历史不影响同节目其他季度；删除整部节目是独立的二级操作。
- 现有 `history` 表**主键与字段不变**，季度进度是新增的加法式结构。

### 27.7 详情页与播放入口

- 站点详情页新增 TMDB 区块，按 6 种状态渲染（未配置 / 站点禁用 / 未匹配 / 匹配中 /
  已匹配 / 失败）；站点禁用时整块不渲染。
- 头部增强严格遵守“**仅补位不覆盖**”：来源已有非空字段一律不改。
- 季度选择器与选集联动，**强制断言** `episodesToRender.length == 该季线路剧集数`。
- 纯 TMDB 详情页（无站源）的剧集卡片**不可播**，点击跳转到按标题搜索站源。
- 相关视频用浏览器打开 + 复制链接，**不做应用内播放**（避免隐式内置站源与合规风险）。
- 播放入口透传季度身份（`tmdbId`/`mediaType`/`seasonNumber`/`episodeNumber`/`flagKey`）
  与 `episodeUrl`；剧集匹配优先级固定为 `episodeUrl` → `episodeName` → TMDB 季集号。
  季度身份**不进入** `PlaybackDecision`，`PlaybackDecision` 的产生逻辑不变。

### 27.8 存储

新增四张表（全部为加法式，不改动既有表）：

| 表 | 用途 |
| --- | --- |
| `tmdb_matches` | 媒体身份匹配结论（含手动标记与标题别名） |
| `tmdb_season_bindings` | 线路级季度绑定（含指纹与分段） |
| `tmdb_route_bindings` | 季度→线路索引（换源候选，上限 512） |
| `tmdb_season_progress` | 季度进度快照 |

- `schemaVersion` 由 `1` 升至 `2`；`CREATE TABLE IF NOT EXISTS` 保证迁移幂等。
- 文件缓存位于 `<cacheDir>/tmdb/<type>_<md5>.json`；目录不可写时降级为不缓存。
- 清理边界：重置缓存不动 SQLite；“清空历史”清季度进度但保留匹配与绑定。

### 27.9 错误分类与失败隔离

新增 `AppErrorKind`：`tmdbNotConfigured` / `tmdbAuth` / `tmdbNetwork` / `tmdbHttp` /
`tmdbDecode` / `tmdbEmpty` / `tmdbUnsupported`。

- 全部 `tmdb*` 错误均为**非致命**类别，用户文案必须含“不影响站源浏览与播放”。
- `isTmdbError` 只认 `tmdb*` 前缀，沿用 Phase 3 字幕/弹幕的失败隔离模式。
- 鉴权失败触发 5 分钟熔断，熔断期内**零请求**；熔断按凭据隔离，换 Key 后立即可用。

### 27.10 验收

门禁表见 `docs/phase4/README.md` §3 与 `docs/phase4/design/05` §6，一键验收入口：

```powershell
pwsh -File tools/phase4/run_windows_acceptance.ps1
```

证据写入 `docs/phase4/evidence/windows-acceptance.txt`。至少包含三条**反向验证**：

1. 把未知季度的元数据候选改回 `[1, 0]` → 对应用例必须失败；
2. 把分季惩罚改为 `0` → 分季变体用例必须失败；
3. 去掉括号归一 → 猫源站点策略用例必须失败。

**实施状态（2026-10-07）**：T1–T18 已全部落地；一键验收结果为
`PHASE4-ACCEPT result=PASS gates=all`（事实行与三条反向验证记录见证据文件）。
集成测试（L3）在真实窗口下额外暴露并修复了 6 个缺陷（含季度切换不刷新元数据、
剧集元数据未按季度过滤、可播放季度未优先采用手动绑定、含特别篇时默认季度错误），
详见 `docs/phase4/README.md` §3.1。

### 27.11 与上游 `webhtv/默影视` 的取舍

**复用**：`TmdbConfig` 归一化与默认禁用规则、`TmdbService` 的 TTL 与陈旧兜底、
鉴权熔断、`TmdbMatcher` 评分公式、`TmdbMatchPolicy` 分季四档、`TmdbSeasonResolver`
解析优先级、可播放季度 6 级顺序、标题三态模型。

**改写**：OkHttp/Gson → `package:http` + `dart:convert`；`Prefers` → `settings.json`；
Room → SQLite 新表；`TmdbUIAdapter` 上帝类 → 分层服务与纯逻辑模块。

**不抄**：`TmdbDetailActivity` 单体、AI 刮削与 AI 推荐、豆瓣评分富集、
个人推荐画像、WebHome 内联/短剧/小说/漫画路由、应用内 YouTube 播放、
Android 特有的多套详情页形态。
