# WebHTV PC 播放器完整设计与验收方案

版本：v1.0  
日期：2026-09-25  
状态：设计文档，尚未实施  
目标平台：Linux、Windows、macOS  
产品定位：支持 WebHTV / TVBox / 猫源配置协议的桌面播放器；不内置、不传播、不售卖任何影视资源。

---

## 1. 执行摘要

WebHTV PC 播放器应作为独立桌面应用开发，而不是直接改造当前 WebHTV Android 工程，也不是直接改造 `atv-player`、`CatVodSpider-PC` 或 `PiliPala`。

正确路线是：

- 新建 `webhtv-pc` 项目。
- 复用 WebHTV 的配置协议、站点模型、Result/Vod 协议、Spider 调用语义、解析器/直播/代理/播放器经验。
- 参考 `atv-player` 的桌面 UI、libmpv 集成、本地 HLS/Range 代理和插件生命周期设计。
- 参考 `CatVodSpider-PC` 的桌面 Java Spider 协议与网络封装。
- 参考 `PiliPala` 的 Flutter/media-kit 播放器交互，仅作交互参考。

首版必须以“可验收的垂直闭环”为目标：

1. 导入 WebHTV/TVBox/猫源 JSON 配置。
2. 加载 HTTP API 站点。
3. 展示分类、列表、详情、播放列表。
4. 使用 libmpv 播放直链和 HLS。
5. 支持搜索、历史、进度恢复、基础播放控制。
6. 建立安全边界和本地代理。
7. 为后续 JS/Python/Java Spider 运行时提供清晰扩展点。

不应在第一版承诺“兼容全部现有 Android TVBox Jar 站源”。PC 端必须定义自己的 Spider ABI，并通过兼容层渐进扩展。

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

### 3.2 第一版非目标

第一版不要求：

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

## 5. 推荐技术选型

### 5.1 首选方案：Kotlin/JVM + libmpv

| 项 | 选择 | 理由 |
| --- | --- | --- |
| 主语言 | Kotlin 2.x，兼容 Java 21 | 最接近 WebHTV 和 CatVodSpider-PC 生态 |
| UI | Compose Desktop 或 JavaFX | 与 JVM 模型复用性强 |
| 播放器 | libmpv | 跨平台、成熟，WebHTV 已有 MPV 经验 |
| HTTP | OkHttp 4.x/5.x | Spider 生态常用，代理和 Header 能力强 |
| JSON | kotlinx.serialization 或 Gson | 配置解析和 Result 解析 |
| 本地服务 | Ktor Server 或 JDK HttpServer | 可控、轻量、易测试 |
| 存储 | SQLite + Repository | 历史、配置、站点健康、缓存 |
| 打包 | jpackage + platform installer | Linux AppImage/deb、Windows MSI/EXE、macOS dmg |

风险：

- native libmpv 与 Java/Compose 窗口集成需要平台验证。
- Compose Desktop/JavaFX 均需处理窗口生命周期差异。
- Windows/macOS 打包需要独立 CI。

### 5.2 备选方案：Flutter + media-kit

适合更重视 UI 一致性，而不是最大化 JVM 复用。

优点：

- UI 开发效率高。
- media-kit 成熟。
- Linux/macOS/Windows runner 成熟。

缺点：

- Dart 无法直接执行 Java Spider，需要进程桥。
- Java/Python/Node 生态都需要桥接。
- WebHTV Java 协议复用降低。

### 5.3 不推荐方案

| 方案 | 原因 |
| --- | --- |
| Electron 作为唯一主体 | native 渲染、安全、桥接复杂，体积大 |
| 直接改造 atv-player | 授权不确定，架构绑定 alist-tvbox |
| 直接改造 PiliPala | GPL、B站专用、移动优先 |
| Android 模拟器包装 | 非真正 PC 版，体验和维护差 |

---

## 6. 项目结构设计

```text
webhtv-pc/
├── app/
│   ├── src/main/kotlin/
│   │   └── com/webhtv/pc/
│   │       ├── App.kt
│   │       ├── ui/
│   │       ├── service/
│   │       ├── player/
│   │       ├── proxy/
│   │       ├── config/
│   │       ├── spider/
│   │       ├── storage/
│   │       └── util/
├── core/
│   ├── src/main/kotlin/com/webhtv/core/
│   │   ├── model/
│   │   ├── config/
│   │   ├── result/
│   │   ├── site/
│   │   ├── parse/
│   │   ├── live/
│   │   └── runtime/
├── runtime-node/
├── runtime-python/
├── runtime-java/
├── resources/
├── packaging/
├── docs/
├── tests/
└── build.gradle.kts
```

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

| 字段 | MVP | 完整版 | 说明 |
| --- | --- | --- | --- |
| `sites` | 必须 | 必须 | 点播站点 |
| `spider` | 可选 | 必须 | 全局 JAR/Spider 资源 |
| `parses` | 可选 | 必须 | 解析器 |
| `lives` | 后置 | 必须 | 直播源 |
| `doh` | 后置 | 必须 | DNS over HTTPS |
| `proxy` | 后置 | 必须 | HTTP/SOCKS 规则 |
| `hosts` | 后置 | 必须 | host 覆盖 |
| `headers` | MVP | 必须 | Header 注入 |
| `rules` | 后置 | 必须 | 视频嗅探规则 |
| `hlsRules` | 后置 | 必须 | HLS 清理规则 |
| `groupRules` | 后置 | 必须 | 直播分组规则 |
| `ads` | 后置 | 必须 | 广告域名规则 |
| `flags` | MVP | 必须 | 播放标识 |
| `home` | MVP | 必须 | 默认站点 |
| `parse` | MVP | 必须 | 默认解析器 |
| `msg` | MVP | 必须 | 配置错误提示 |

### 7.3 配置加载流程

```text
用户输入 URL / 本地文件 / JSON 文本
        │
        ▼
ConfigFetcher
        │
        ▼
JSON 校验与解析
        │
        ▼
站点模型转换
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

### 7.4 配置验收

- 支持 URL、本地文件、纯 JSON 文本三种导入。
- 支持多个配置并允许切换。
- 能记录配置名称、URL、更新时间、站点数、直播数。
- 无效配置不会影响已有配置。
- `msg` 非空时禁止加载并展示原始错误。
- 重复导入同一配置应覆盖或创建新版本，行为明确。

---

## 8. 站点与协议模型

### 8.1 站点类型

| `type` | 名称 | MVP | 说明 |
| --- | --- | --- | --- |
| `0` | XML API | 必须 | 传统 CMS XML API |
| `1` | JSON API | 必须 | 请求带 `ac=detail` 和 `f={json}` |
| `2` | JSON API 兼容 | 必须 | 不追加 `f` |
| `3` | Spider | 分阶段 | 依赖 `api` 分发 |
| `4` | HTTP API + Base64 ext | 必须 | 首页/分类/播放带扩展参数 |

`type=3` 分发：

| `api` 形态 | 运行时 | MVP |
| --- | --- | --- |
| `http.../spider/...` | CatSpider HTTP | 建议 |
| `*.py` | Python Spider | 后置 |
| `*.js` | QuickJS/Node Spider | 后置 |
| `csp_*` | PC Java Spider | 后置 |
| 其他 | SpiderNull | 必须 |

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

### 9.1 统一接口

PC 内部统一使用：

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

### 9.2 Spider ABI 策略

PC 版必须明确三种 ABI：

| ABI | 说明 | 是否 MVP |
| --- | --- | --- |
| `pc-spider-v1` | 无 Android Context，桌面 JVM 签名 | 否，后置 |
| `tvbox-http-v1` | CatSpider HTTP 协议 | 建议 MVP |
| `tvbox-js-v1` | Node/QuickJS JS 协议 | 后置 |
| `tvbox-python-v1` | Python Spider 协议 | 后置 |

必须提供 manifest：

```json
{
  "abi": "pc-spider-v1",
  "key": "demo",
  "name": "Demo Spider",
  "runtime": "jvm-21",
  "permissions": {
    "network": true,
    "localProxy": false,
    "ui": false,
    "storage": "cache-only"
  }
}
```

### 9.3 进程隔离原则

- JS/Python/Java Spider 默认运行在独立子进程。
- 主进程不能直接加载不可信 Java 类。
- Spider 与 UI 进程完全隔离。
- 每个站点必须设置内存、CPU 时间、超时和并发限制。
- Spider 崩溃只影响该站点。
- Spider 不得直接访问主进程数据库、配置文件、Cookie、系统浏览器。

### 9.4 兼容层设计

PC Java Spider 可尝试以下调用：

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

### 9.5 Spider 验收

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

---

## 10. 播放器设计

### 10.1 引擎选择

首版只实现一个稳定引擎：

> libmpv

后续可选：

| 引擎 | 用途 |
| --- | --- |
| libmpv | 主播放器 |
| 系统 mpv | 外部播放器备选 |
| FFplay | 调试备选 |
| media-kit | Flutter 路线 |
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
libmpv loadfile
        │
        ▼
播放器状态监听 / 进度保存 / 错误恢复
```

### 10.3 基础播放功能

| 功能 | MVP | 完整版 |
| --- | --- | --- |
| 播放/暂停 | 必须 | 必须 |
| 进度条 | 必须 | 必须 |
| 拖动 Seek | 必须 | 必须 |
| 音量 | 必须 | 必须 |
| 静音 | 必须 | 必须 |
| 倍速 | 必须 | 必须 |
| 全屏 | 必须 | 必须 |
| 上一集/下一集 | 必须 | 必须 |
| 自动连播 | 必须 | 必须 |
| 播放恢复 | 必须 | 必须 |
| 播放列表 | 必须 | 必须 |
| 线路切换 | 必须 | 必须 |
| 快捷键 | 必须 | 必须 |
| 音轨选择 | 后置 | 必须 |
| 字幕轨选择 | 后置 | 必须 |
| 外挂字幕 | 后置 | 必须 |
| 截图 | 后置 | 必须 |
| 画面比例 | 后置 | 必须 |
| 硬解/软解 | 后置 | 必须 |
| 网络缓存 | 后置 | 必须 |
| 播放诊断 | 后置 | 必须 |

### 10.4 播放错误策略

| 场景 | 处理 |
| --- | --- |
| 403/404 | 提示链接失效，建议换线路 |
| HLS 401 | 提示 Header 或 Cookie 丢失 |
| DNS 失败 | 提示网络/代理/DNS 配置 |
| 超时 | 支持重试一次，不无限循环 |
| 格式不支持 | 提示格式详情和可切换引擎 |
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

| 功能 | MVP | 完整版 |
| --- | --- | --- |
| Spider proxy | 后置 | 必须 |
| HLS 清单重写 | 后置 | 必须 |
| HLS 分片代理 | 后置 | 必须 |
| Header 注入 | 必须 | 必须 |
| Range 代理 | 后置 | 必须 |
| 多线程下载代理 | 后置 | 可选 |
| 广告过滤 | 后置 | 必须 |
| CENC/DRM 辅助 | 后置 | 后置 |
| 请求日志 | 必须 | 必须 |
| 端口冲突处理 | 必须 | 必须 |

### 11.3 安全要求

1. 只接受本机请求。
2. 校验请求 token。
3. 校验目标 URL 白名单。
4. 不转发内网地址，除非用户显式开启并确认。
5. 不保存 Cookie/Token 到日志。
6. 限制单请求大小和总并发。
7. 请求失败返回明确 4xx/5xx。
8. 不允许把 HTML 错误页伪装成 200 媒体响应。

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

必须兼容：

| 类型 | 说明 |
| --- | --- |
| `type=0` | JSON 解析 |
| `type=1` | Web 嗅探/解析 |
| `type=2` | JSON 扩展解析 |
| `type=3` | Spider 解析 |

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
| --- | --- | --- |
| `configs` | 配置记录 |
| `sites` | 站点状态 |
| `history` | 播放历史 |
| `favorites` | 收藏 |
| `search_cache` | 搜索缓存 |
| `site_health` | 健康统计 |
| `spider_logs` | Spider 日志摘要 |

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

| 页面 | MVP | 完整版 |
| --- | --- | --- |
| 启动页 | 必须 | 必须 |
| 配置导入页 | 必须 | 必须 |
| 配置管理页 | 必须 | 必须 |
| 站点列表 | 必须 | 必须 |
| 首页/分类页 | 必须 | 必须 |
| 搜索页 | 必须 | 必须 |
| 详情页 | 必须 | 必须 |
| 播放器页 | 必须 | 必须 |
| 历史页 | 必须 | 必须 |
| 收藏页 | 必须 | 必须 |
| 直播页 | 后置 | 必须 |
| 设置页 | 必须 | 必须 |
| 站点健康页 | 后置 | 必须 |
| 日志页 | 后置 | 必须 |
| Spider 管理页 | 后置 | 必须 |

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

### 19.1 测试分层

| 层 | 测试类型 | 工具 |
| --- | --- | --- |
| 协议 | 单元测试 | JUnit/Kotlin Test |
| 站点 | 契约测试 | Mock HTTP + fixture |
| 搜索 | 并发/取消测试 | coroutines test |
| 播放器 | 手动 + 自动烟测 | libmpv + 本地媒体 |
| 代理 | HTTP 集成测试 | Ktor test / OkHttp |
| UI | 自动化 + 截图 | Compose UI test / TestFX |
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
| `live.m3u` | 直播源 |
| `live.txt` | TXT 直播源 |
| `hls/index.m3u8` | 本地 HLS |
| `media/sample.mp4` | 本地 MP4 |

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

### 19.4 手动验收环境

| 系统 | 最低分辨率 | 验收重点 |
| --- | --- | --- |
| Linux X11 | 1920×1080 | libmpv、AppImage/deb |
| Windows 10/11 | 1920×1080 | 安装包、播放、路径 |
| macOS | 1280×800 | 窗口、快捷键、签名 |
| Linux Wayland | 1920×1080 | 窗口/全屏 |

---

## 20. 构建与打包

### 20.1 构建矩阵

| 目标 | 类型 |
| --- | --- |
| Linux x86_64 | AppImage、deb |
| Windows x86_64 | MSI、便携 zip |
| macOS aarch64 | dmg |
| macOS x86_64 | 可选 |

### 20.2 打包内容

- 主程序。
- libmpv 或清晰的系统依赖提示。
- JS/Python 运行时可选下载。
- 默认不打包站点源。
- 默认不打包用户配置。

### 20.3 打包验收

- 空配置首次启动可进入导入页。
- 安装后可启动。
- 卸载不删除用户数据，另提供明确清理入口。
- 便携版不写系统注册表。
- 安装包无站点源和用户数据。
- 启动日志记录版本、平台、运行时。

---

## 21. 实施阶段

### Phase 0：技术验证

目标：验证技术路线，不追求功能完整。

任务：

1. 搭建 JVM/Kotlin 项目。
2. 集成 libmpv。
3. 播放本地 MP4。
4. 播放本地 HLS。
5. 实现最小 JSON 配置解析。
6. 加载一个 HTTP API 站点。
7. 完成分类/详情/播放闭环。

验收：

- Linux/Windows 至少一端能稳定播放。
- MP4 和 HLS 均可播放。
- HTTP API 站点从配置到播放成功。

### Phase 1：MVP

功能：

- 配置导入。
- 站点列表。
- 分类浏览。
- 详情页。
- 搜索。
- 播放历史。
- 播放器基础控制。
- Header 注入。
- 错误提示。
- 设置页。
- 日志。

验收：

- 使用一份标准 TVBox 配置完成导入。
- HTTP API 源可浏览、搜索、播放。
- 播放进度可恢复。
- 主流程无阻塞式崩溃。

### Phase 2：Spider 与代理

功能：

- CatSpider HTTP。
- JS/Node Spider。
- Python Spider。
- PC Java Spider。
- Spider 进程隔离。
- Spider 管理页。
- Spider proxy。
- HLS 代理。
- Range 代理。

验收：

- 每类 Spider 有至少一个可重复测试 fixture。
- Spider 崩溃/超时被隔离。
- 代理安全测试通过。
- 播放可依赖 Header 和本地代理。

### Phase 3：播放增强

功能：

- 字幕。
- 弹幕。
- 解析器。
- 换源。
- 线路切换。
- 自动连播。
- 直播。
- EPG。
- 播放诊断。

验收：

- 字幕/弹幕可开启和关闭。
- 解析器可按 flag 选择。
- 直播 M3U/TXT 可播放。
- 播放诊断能输出引擎、格式、网络和错误。

### Phase 4：生态与同步

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

---

## 22. 总验收清单

### 22.1 功能验收

| 分类 | 验收项 | Phase |
| --- | --- | --- |
| 配置 | URL/文件/JSON 导入 | 1 |
| 配置 | 多配置管理 | 1 |
| 配置 | 无效配置提示 | 1 |
| 站点 | HTTP API 首页 | 1 |
| 站点 | 分类和分页 | 1 |
| 站点 | 详情 | 1 |
| 站点 | 搜索 | 1 |
| 站点 | 播放 | 1 |
| 播放器 | 播放/暂停/Seek | 1 |
| 播放器 | 倍速/音量/全屏 | 1 |
| 播放器 | 上一集/下一集 | 1 |
| 历史 | 播放记录 | 1 |
| 历史 | 恢复进度 | 1 |
| 安全 | 日志脱敏 | 1 |
| Spider | CatSpider HTTP | 2 |
| Spider | JS Spider | 2 |
| Spider | Python Spider | 2 |
| Spider | PC Java Spider | 2 |
| 代理 | Spider proxy | 2 |
| 代理 | HLS 代理 | 2 |
| 代理 | Range 代理 | 2 |
| 播放器 | 字幕 | 3 |
| 播放器 | 弹幕 | 3 |
| 直播 | M3U/TXT/JSON | 3 |
| 直播 | EPG | 3 |
| 同步 | 配置/历史/收藏同步 | 4 |

### 22.2 质量验收

- 单元测试通过。
- 协议 fixture 全部通过。
- 代理安全测试通过。
- UI 冒烟测试通过。
- Linux/Windows/macOS 至少各完成一轮手动验收。
- 无 P0/P1 缺陷。
- 30 分钟播放稳定性测试通过。
- 冷启动时间低于 3 秒。
- 播放首帧时间不超过 5 秒（受网络影响时显示原因）。
- 内存无持续增长异常。
- 退出后进程全部结束。

### 22.3 合规验收

- 应用不内置站点配置。
- 应用不内置站源。
- 应用不内置影视资源。
- 首次启动展示使用边界提示。
- README 明确用户责任。
- 不采集用户观影数据。
- 不上传用户配置，除非用户显式开启同步。

---

## 23. 关键决策记录

| 决策 | 结论 | 原因 |
| --- | --- | --- |
| 新建项目还是改造 | 新建项目 | Android/Qt/Flutter 项目均存在架构或授权限制 |
| 首版语言 | Kotlin/JVM | 与 WebHTV Java 生态和 CatVodSpider-PC 兼容性最好 |
| 首版 UI | Compose Desktop 或 JavaFX | 需 Phase 0 验证 |
| 首版播放器 | libmpv | 跨平台、成熟、与 WebHTV 经验一致 |
| 首版站源 | HTTP API + CatSpider | 风险低、易验收 |
| Android Jar 兼容 | 后置 | Dex/Context/Android 类依赖复杂 |
| 本地代理 | 默认仅本机 | 安全是硬要求 |
| PiliPala | 只参考交互 | GPL 与产品定位限制 |
| atv-player | 只参考设计 | 授权不明确且绑定 alist-tvbox |

---

## 24. 最小实施顺序

```text
1. 建 Gradle/Kotlin 项目骨架
2. 定义 Config/Site/Result/Vod 模型
3. 写协议 fixture 测试
4. 实现 JSON API type=1
5. 实现 XML API type=0
6. 实现站点列表/分类/详情/搜索
7. 集成 libmpv
8. 实现播放请求 Header 注入
9. 实现历史记录
10. 实现设置页
11. 实现 CatSpider HTTP
12. 实现本地代理
13. 实现 JS/Python/PC Java Spider
14. 实现字幕/弹幕/直播
15. 实现同步与生态能力
```

---

## 25. 完成定义

PC 播放器只有同时满足以下条件才可称为完整可发布：

1. 配置协议覆盖 WebHTV/TVBox/猫源核心字段。
2. HTTP API、CatSpider、JS、Python、PC Java 运行时全部通过对应 fixture。
3. libmpv 播放稳定，支持直链/HLS/Header/进度恢复。
4. 本地代理安全测试通过。
5. 搜索、详情、播放、历史闭环可用。
6. 字幕、弹幕、解析器、直播、EPG 完整版验收通过。
7. Linux/Windows/macOS 打包可安装、可运行。
8. 自动化测试和手动验收全部记录。
9. 无 P0/P1 缺陷。
10. 不内置资源，合规边界清晰。

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

