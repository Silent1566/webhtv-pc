# WebHTV PC

**WebHTV PC** 是基于 Flutter 的桌面播放器，面向使用鼠标和键盘的 PC 用户，让已有的 WebHTV / TVBox / 猫源配置能够在桌面端完成导入、浏览、搜索和播放。

项目采用 media-kit / mpv 播放内核，并通过独立进程运行 Spider 宿主，提供配置兼容、站源运行、播放与诊断能力，而不是依赖 Android 模拟器。

> 支持 WebHTV / TVBox / 猫源配置协议和 Spider 运行时；单个站源能否使用，以实际测试通过为准。
>
> **不内置影视资源、站点配置或爬虫**，所有内容来源与配置均由用户自行提供。

## 主要功能

- **配置管理**：通过 HTTP(S) 地址、本地文件或 JSON 文本导入配置，支持多配置保存与切换。
- **浏览与搜索**：站点浏览、分类筛选、搜索、站点排序与屏蔽，以及详情页、多线路和多剧集选择。
- **桌面播放**：倍速、全屏、进度恢复、线路切换、画面比例、字幕、弹幕、快捷键及右键菜单。
- **直播**：直播频道、线路切换与 EPG 节目单。
- **元数据与识别**：TMDB 详情、季集、演员与相关推荐，以及 AI 辅助集季识别；相关能力需按需配置。
- **安卓互通**：安卓设备桥接、同步授权与推送。
- **外观与诊断**：暗色 / 亮色 / 跟随系统主题，配置壁纸与 Logo，以及诊断、日志和解析轨迹。
- **解析能力**：支持多类型解析器；Web 嗅探 / Super 解析使用本机 Chromium 内核浏览器，缺失时可从用户提供的本地目录或 ZIP 安装浏览器组件。

不同功能可能依赖站源能力、用户配置、外部服务或本机运行环境；这里不代表全部站源或安卓端功能均可直接使用。

## 平台与下载

| 平台 | 当前情况 |
| --- | --- |
| Windows x64 | 优先支持，提供便携 ZIP 打包与发布流程 |
| Linux x86_64 | 提供 AppImage 与 deb 打包流程，运行依赖见 Linux 指南 |
| macOS / ARM64 | 不属于当前打包目标；仓库未提供对应发布流程 |

前往 [GitHub Releases](https://github.com/Silent1566/webhtv-pc/releases) 查看已发布版本与对应平台资产；具体可下载产物以发布页面为准。测试构建也可在 [GitHub Actions](https://github.com/Silent1566/webhtv-pc/actions) 中查看。

- **Windows**：解压完整 ZIP 后运行 `webhtv_pc.exe`，不要只移动 EXE，需保留同目录的动态库、`data/`、`sidecars/` 与 `runtime/`。
- **Linux**：安装 deb 或运行 AppImage，依赖、校验和与安装命令见 [Linux 构建、打包与运行指南](docs/linux-packaging.md)。
- 当前没有自动更新通道。Windows 包是否签名以发布元数据为准；未签名包可能触发 SmartScreen 提示。

### 运行环境

| 能力 | 运行要求 |
| --- | --- |
| JS Spider | 正式 Windows / Linux 包内置 Node 运行时；源码开发需准备 Node.js |
| Python Spider | 当前 Windows 包内置专用离线 Python 与依赖，可在 Python 环境页面检测及离线修复；Linux 对应站源仍需系统 Python 3 |
| JVM Spider | 对应站源需本机 JDK 17+；站源需满足宿主 ABI 或支持的字节码转译路径，兼容性以实测为准 |
| Web 嗅探 / Super 解析 | 需本机 Chromium 内核浏览器，或用户提供的本地浏览器组件；应用不内置、不分发浏览器，也不代为联网下载 |

## 开始使用

1. 准备一份你有权使用的 WebHTV / TVBox / 猫源配置。
2. 启动应用，在配置管理中通过地址、本地文件或 JSON 文本导入。
3. 选择配置与站点，浏览分类或搜索内容，进入详情选择线路和剧集播放。
4. 根据需求配置直播、字幕、弹幕、TMDB 或安卓桥接等能力。
5. 若站源加载或播放失败，先查看诊断、日志与解析轨迹，再检查配置、网络和运行时是否满足要求。

仅导入可信来源的配置和 Spider。进程隔离不等于第三方代码已通过安全审计。

## 兼容性边界

本项目不是“全部 TVBox / 猫源都能运行”的兼容性承诺，也不是安卓端的完整复刻。以下能力不在 PC 端直接提供：

- **Android dex 与完整安卓运行环境**：PC JVM 不能直接执行 dex；宿主包含字节码转译路径，但转译不等于完整支持 Android Context、原生库或安卓系统 API。无法兼容的站源可通过安卓桥接（T4 网关）使用安卓侧能力。
- **Exo / IJK 内核切换**：PC 固定使用 media-kit / mpv，解码与缓冲参数通过播放设置中的 mpv 选项配置。
- **TV / 遥控器焦点、移动端手势、亮度记忆与屏幕旋转设置**：PC 以桌面键鼠交互为主。
- **Android Intent、APK 推送、前台保活与电池适配**：属于安卓系统能力。
- **Lab shell 实验室与游戏模式**：PC 不提供；执行命令请使用系统终端。
- **独立 AppBranding 品牌设置页**：使用用户配置提供的壁纸与 Logo。
- **内置影视资源、站点配置与爬虫**：全部由用户自行导入。

更多差异与阶段性对比见 [安卓能力迁移记录](docs/phase9/README.md) 和 [逐项对照基线](docs/phase9/parity-2026-11-12/README.md)。对照记录是对应提交时的快照，当前行为以代码与实际测试为准。

## 开发与构建

开发工具链与 CI 对齐：**Flutter 3.47.5 / Dart 3.13.4**，以及 **Node.js 22、JDK 21、Python 3.12**（用于构建与测试）。Windows 的随包 Python 版本和依赖由 [运行时锁文件](scripts/python-runtime.lock.json) 单独固定，不等同于 CI 的系统 Python。

从仓库根目录获取代码并准备依赖：

```bash
git clone https://github.com/Silent1566/webhtv-pc.git
cd webhtv-pc
cd sidecars/spider-host-js
npm ci --omit=dev
cd ../../apps/desktop-flutter
flutter --version
flutter pub get
dart analyze
```

Windows 原生构建需安装 Flutter 要求的 Visual Studio C++ 桌面开发工具链。Windows 构建前，在仓库根目录通过 PowerShell 准备校验过的 Python 运行时：

```powershell
./scripts/prepare_python_runtime.ps1
cd apps/desktop-flutter
flutter build windows --release
```

Linux 原生依赖、构建和无显示器测试步骤请按 [Linux 指南](docs/linux-packaging.md) 执行。播放器测试需要原生库，不能把缺失运行环境当作普通测试失败或直接跳过相关测试。

更多开发与打包信息：

- [桌面客户端开发说明](apps/desktop-flutter/README.md)
- [Windows 构建与发布](docs/release/windows.md)
- [Windows CI：原生库准备与测试步骤](.github/workflows/windows-ci.yml)
- [Linux 构建与发布](docs/linux-packaging.md)

### 仓库结构

```text
apps/desktop-flutter/       Flutter 桌面客户端
packages/protocol/         配置与通信协议
packages/spider-abi/       Spider ABI 与能力协商
packages/test-fixtures/    测试数据
sidecars/spider-host-js/   Node.js Spider 宿主
sidecars/spider-host-jvm/  JVM Spider 宿主
sidecars/spider-host-python/ Python Spider 宿主
scripts/                  运行时准备、校验与平台打包脚本
tests/                    仓库级回归测试
tools/                    测试服务与开发工具
docs/                     设计、ADR、发布说明与验收记录
```

架构与协议细节见 [项目设计文档](docs/webhtv-pc-design.md)、[协议说明](packages/protocol/README.md) 和 [Spider ABI 说明](packages/spider-abi/README.md)。

## 致谢与参考项目

感谢以下开源项目及其作者、维护者和贡献者。项目参考与基础组件分别列出，感谢它们为播放器、站源生态与桌面开发积累的经验。

### 借鉴与参考项目

本项目在开发过程中借鉴、参考了以下项目的思路与实践：

| 项目 | 项目简介 | GitHub 地址 |
| --- | --- | --- |
| **webhtv/webhtv（WebHomeTV）** | 基于 FongMi 二次开发的安卓项目，提供 WebHome 自定义首页与 Native 能力 | [https://github.com/webhtv/webhtv](https://github.com/webhtv/webhtv) |
| **FongMi/TV** | 安卓 TV / 播放器项目，WebHomeTV 的上游基础 | [https://github.com/FongMi/TV](https://github.com/FongMi/TV) |
| **power721/atv-player** | alist-tvbox 桌面播放器 | [https://github.com/power721/atv-player](https://github.com/power721/atv-player) |
| **kknifer7/CatVodSpider-PC** | 适配电脑端的猫影视 / TVBox Spider 模板项目 | [https://github.com/kknifer7/CatVodSpider-PC](https://github.com/kknifer7/CatVodSpider-PC) |
| **guozhigq/pilipala（PiliPala）** | 使用 Flutter 开发的 BiliBili 第三方客户端 | [https://github.com/guozhigq/pilipala](https://github.com/guozhigq/pilipala) |
| **yagami-hue/Win-box** | Windows 版 TVBox 项目 | [https://github.com/yagami-hue/Win-box](https://github.com/yagami-hue/Win-box) |

### 使用的开源组件与模型

项目还使用了以下主要框架、运行时、库与模型相关项目；这不是完整的依赖或许可证清单：

| 项目 | 用途 | GitHub 地址 |
| --- | --- | --- |
| **Flutter** | 桌面客户端框架 | [https://github.com/flutter/flutter](https://github.com/flutter/flutter) |
| **media-kit** | Flutter / Dart 音视频播放接口 | [https://github.com/media-kit/media-kit](https://github.com/media-kit/media-kit) |
| **mpv** | 音视频播放内核 | [https://github.com/mpv-player/mpv](https://github.com/mpv-player/mpv) |
| **Node.js** | JS Spider 宿主运行时 | [https://github.com/nodejs/node](https://github.com/nodejs/node) |
| **CPython** | Python Spider 运行时 | [https://github.com/python/cpython](https://github.com/python/cpython) |
| **Cheerio** | JS Spider 的 HTML 解析能力 | [https://github.com/cheeriojs/cheerio](https://github.com/cheeriojs/cheerio) |
| **CryptoJS** | JS Spider 的加解密工具 | [https://github.com/brix/crypto-js](https://github.com/brix/crypto-js) |
| **dex2jar** | JVM 宿主的 dex 字节码转译组件；不代表完整 Android 兼容 | [https://github.com/pxb1988/dex2jar](https://github.com/pxb1988/dex2jar) |
| **Gson / JSON-java** | JVM 站源的 JSON 处理依赖 | [Gson](https://github.com/google/gson) / [JSON-java](https://github.com/stleary/JSON-java) |
| **OkHttp / Okio** | JVM 站源的网络请求与 I/O 依赖 | [OkHttp](https://github.com/square/okhttp) / [Okio](https://github.com/square/okio) |
| **sherpa-onnx** | 音频 AI 与语音识别引擎 | [https://github.com/k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) |
| **ONNX Runtime** | 音频模型推理运行时 | [https://github.com/microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) |
| **LiteRT** | TFLite 音频模型推理 | [https://github.com/google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT) |
| **Silero VAD** | 语音活动检测相关模型 | [https://github.com/snakers4/silero-vad](https://github.com/snakers4/silero-vad) |
| **Basic Pitch** | 音高识别相关项目与模型资产 | [https://github.com/spotify/basic-pitch](https://github.com/spotify/basic-pitch) |

音频引擎与模型权重的许可需分别核对；相关模型的来源、许可状态及尚未确认的信息见 [音频 AI 资源来源说明](apps/desktop-flutter/lib/core/audio_ai/RESOURCE_SOURCES.md)。JVM 宿主的更多依赖与许可登记见 [第三方依赖声明](sidecars/spider-host-jvm/lib/THIRD-PARTY-NOTICES.md)。

致谢不代表上述项目与 WebHTV PC 存在隶属、合作或官方背书关系。参考项目及实际使用的第三方代码、资源均应遵守各自许可证与声明；本节不替代随包第三方许可和 NOTICE 文件。

## 使用与反馈

请仅使用有权访问的配置与内容，遵守适用法律及内容提供方的使用条款。本项目不提供资源、不售卖或传播第三方内容，也不替用户绕过版权、认证、验证码或访问控制。

问题反馈请提交至 [GitHub Issues](https://github.com/Silent1566/webhtv-pc/issues)，附上应用版本、操作系统、复现步骤和脱敏日志；不要公开提交 Token、Cookie、账号信息或含敏感参数的配置地址。
