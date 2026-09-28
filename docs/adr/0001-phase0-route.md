# ADR-0001：Phase 0 桌面技术路线

- 状态：已冻结（选择 Flutter + media-kit），并于 Phase 1 完成路线收敛
- 日期：2026-09-25，冻结于 2026-09-27
- 决策：Phase 0 主路线采用 **Flutter + media-kit**；Kotlin/JVM + Compose Desktop
  + libmpv 作为已验证的备选方案，不进入产品化。

## Phase 1 执行结果（路线收敛）

冻结后按设计文档 §6 与 Phase 0 任务 10 完成以下动作：

1. Flutter 主线提升为产品工程 `apps/desktop-flutter`（包名 `webhtv_pc`），承载
   MVP-A 实现；原 Phase 0 Flutter 原型目录 `prototypes/flutter_media_kit` 不再保留。
2. 未选路线 `prototypes/compose_libmpv`（Kotlin/JVM + JNI + libmpv）与其专属工具
   （`benchmark_kotlin*.ps1/sh`、`dump_kotlin_windows.py`、`fetch_gradle.py`、
   `fetch_gson.py`、`fetch_mpv_dev.py`、`capture_kotlin_evidence.py`）已从产品仓库
   删除，源码与脚本见 git 历史提交 `cdb9245`，避免设计文档禁止的长期双栈。
3. fixture 从 `packages/protocol/fixtures` 收敛到 `packages/test-fixtures`；
   `packages/protocol` 只保留跨语言 Schema 与文档，`packages/spider-abi` 保留
   ABI 消息与 manifest Schema。
4. Phase 0 证据（`docs/phase0/evidence/` 截图与基准日志）保持原样，作为历史记录
   可复查；其中 Kotlin 路线的证据作为“已验证备选方案”的存档保留。

Phase 0 的选型结论不变：主路线仍为 Flutter + media-kit。

## 背景

设计要求使用同一组素材比较 Flutter/media-kit 与 Kotlin/Compose/libmpv，在进入
MVP-A 前只保留一条产品路线。两条路线都必须完成最小可运行原型，并通过 P0-A 硬门槛
后才进入评分。

## 验证环境

- Windows：Windows 11（10.0.22631）、JDK 21.0.12、Visual Studio 2022 Build Tools
  `14.44.35207`、Flutter 3.47.5 / Dart 3.13.4、libmpv client API 2.5。
- Linux：Ubuntu 22.04.5（容器，WSL2 内核）、JDK 21.0.12.1（Temurin）、GCC 11、
  Flutter 3.47.5 / Dart 3.13.4、libmpv 0.34.1、Xvfb + Openbox + Mesa llvmpipe。

## P0-A 硬门槛结果（两条路线均通过）

| 决策门 | Flutter + media-kit | Kotlin/JVM + libmpv |
| --- | --- | --- |
| 播放器内嵌主窗口 | 通过 | 通过 |
| MP4 / HLS / Seek / Header 注入 | 通过 | 通过 |
| 打包后自动发现 native 库 | 通过 | 通过 |
| 配置导入到播放闭环、无 UI 卡死 | 通过 | 通过 |
| 崩溃/黑屏/全屏/音画问题记录 | 通过 | 通过 |
| Windows 构建与启动 | 通过 | 通过 |
| Linux 构建与启动 | 通过 | 通过 |

P0-B 最小业务闭环（配置导入 → 首页 → 分类 → 详情 → 播放）两条路线均通过；Flutter
侧由 `phase0_playback_test.dart` 的 `配置导入到 HTTP API 播放闭环` 覆盖，Kotlin 侧由
`--headless --config-flow` 覆盖。

## 评分表

权重与评分规则来自设计文档 5.5.1。各项 0–100，加权后：

| 评分项 | 权重 | Flutter + media-kit | Kotlin/JVM + libmpv |
| --- | ---: | ---: | ---: |
| 播放稳定性 | 25% | 82 | 88 |
| 跨平台打包 | 20% | 90 | 55 |
| 首帧与 Seek 表现 | 15% | 78 | 92 |
| native 集成复杂度 | 15% | 92 | 45 |
| Spider sidecar 集成成本 | 10% | 80 | 80 |
| 可测试性 | 10% | 90 | 60 |
| 团队熟悉度 | 5% | 70 | 70 |
| **加权总分** | 100% | **84.5** | **71.1** |

两条路线总分差 13.4 分，不小于 5 分，按规则选择高分路线；该结论与设计文档“两条均
通过则优先 Flutter 以降低 UI、打包与长期平台维护成本”的默认决策一致，因此
**冻结 Flutter + media-kit**，决策不存在冲突。

### 评分依据

- **播放稳定性**：两条路线均无崩溃、无黑屏（所有截图非黑占比 ≥ 0.62）；异常 URL 均
  明确报错而非静默成功。Kotlin 直接驱动 libmpv，边界更少；Flutter 通过 media-kit
  封装，Phase 0 中暴露并修复了 3 处平台差异（见下），扣分。
- **跨平台打包**：Flutter 由 `media_kit_libs_windows_video` /
  `media_kit_libs_linux` 自动带入播放库，`flutter build <platform> --release` 单命令
  产出 23 MB Linux bundle；Kotlin 需 MSVC/GCC、手工 JNI、`dlopen` 候选路径与
  （Linux）系统 libmpv 依赖，打包与签名成本显著更高。
- **首帧与 Seek 表现**：见下方采样表；Kotlin 在两平台、各指标上一致更快，Seek 快约
  一个数量级。
- **native 集成复杂度**：Flutter 侧零自定义 native 代码；Kotlin 侧含 22 KB 手写
  JNI C（`webhtv_mpv_jni.c`）与窗口内嵌逻辑（`HostWindow.java`）。
- **可测试性**：Flutter 侧有 `flutter test`、`flutter analyze`、
  `integration_test` 与 10 次重复采样基准；Kotlin 侧目前只有 headless CLI，无单元
  测试框架接入。
- **团队熟悉度**：Phase 0 未获得人员经验数据，两条路线均按中性 70 记录，作为后续
  风险项。

## 重复采样证据（每项 10 次）

原始日志（含逐次 `PHASE0-EVIDENCE` 行）：

- Windows：`docs/phase0/evidence/flutter-benchmark.txt`、
  `docs/phase0/evidence/kotlin-benchmark.txt`
- Linux：`docs/phase0/evidence/flutter-linux-benchmark.txt`、
  `docs/phase0/evidence/kotlin-linux-benchmark.txt`

首帧统一采用“播放位置首次大于 0”作为已出画的可观测代理；加载耗时与首帧耗时分开
统计，不使用加载耗时冒充首帧。

Windows 11：

| 指标 | Flutter + media-kit | Kotlin/JVM + libmpv |
| --- | --- | --- |
| 本地 MP4 加载 | median 116ms / p95 177ms | median 14ms / p95 27ms |
| 本地 MP4 首帧 | median 246ms / p95 500ms | median 35ms / p95 57ms |
| 本地 HLS 加载 | median 128ms / p95 144ms | median 19ms / p95 37ms |
| 本地 HLS 首帧 | median 240ms / p95 268ms | median 39ms / p95 62ms |
| Header HLS 加载 | median 145ms / p95 169ms | median 41ms / p95 47ms |
| Header HLS 首帧 | median 262ms / p95 420ms | median 61ms / p95 94ms |
| HLS Seek 到达 | median 252ms / p95 253ms | median 11ms / p95 22ms |

Linux（软件渲染）：

| 指标 | Flutter + media-kit | Kotlin/JVM + libmpv |
| --- | --- | --- |
| 本地 MP4 加载 | median 89ms / p95 177ms | median 39ms / p95 70ms |
| 本地 MP4 首帧 | median 203ms / p95 491ms | median 60ms / p95 95ms |
| 本地 HLS 加载 | median 91ms / p95 102ms | median 49ms / p95 120ms |
| 本地 HLS 首帧 | median 214ms / p95 250ms | median 68ms / p95 166ms |
| Header HLS 加载 | median 123ms / p95 166ms | median 106ms / p95 140ms |
| Header HLS 首帧 | median 253ms / p95 455ms | median 131ms / p95 168ms |
| HLS Seek 到达 | median 253ms / p95 254ms | median 5ms / p95 6ms |

两条路线的加载与首帧均远低于 5 秒门槛。

## 画面与内嵌证据

Windows：`flutter-header-hls.png`（48999 色 / 非黑 0.904）、`flutter-local-mp4.png`
（54929 / 0.902）、`flutter-fullscreen.png`（164048 / 0.704）、
`kotlin-embedded-header-hls.png`（77291 / 0.924）、`kotlin-embedded-mp4.png`
（77305 / 0.924）、`kotlin-fullscreen.png`（236135 / 0.751，视频区高 1080）。

Linux：`flutter-linux-header-hls.png`（52735 色 / 非黑 0.624），证明 HLS Seek 到
3.000 秒后画面内嵌渲染在主窗口内，非黑屏。

## Phase 0 中发现并修复的平台差异

1. **libmpv 要求 `LC_NUMERIC=C`**：中文 Linux 环境下 JVM 会把 locale 设为非 C，导致
   `mpv_initialize` 直接失败。JNI 侧在 `load_api()` 中于加载动态库前显式
   `setlocale(LC_NUMERIC, "C")`。
2. **Linux media-kit 需要 `Player` 绑定到已挂载的 `Video` 控件**后才推进播放管线；
   裸 `Player` 的 `position` 恒为 0。集成测试与基准测试已改为复现真实应用路径。
3. **非致命 `stream.error` 被误判为加载失败**：无声卡/无 GPU 环境会上报音频/解码
   告警但视频已加载成功（duration 非零）。加载结果改为以 `duration` 判定，错误仅作
   记录。
4. **构建脚本选中 0 字节占位 DLL**：`.local/mpv-win/extracted` 含空文件，构建脚本改为
   只接受非空 `libmpv-2.dll`。
5. **Kotlin 全屏视频未铺满**：`HostWindow.resizeVideoToWindow()` 硬编码 `height * 0.7`，
   全屏后视频只占 70% 高度（实测 1344×756，非黑 0.389）。改为全屏时用整个客户区高度、
   窗口模式用 `videoArea` 实际布局高度；修复后全屏视频区高 1080、非黑 0.751。

## 未通过项与规避方案

- **macOS**：无可用机器，完全未执行。规避：在获得 macOS 机器后按同一套
  `integration_test` 与基准脚本补测；在此之前不发布 macOS 包。
- **Linux 硬件加速**：本机 Linux 由容器 + 软件渲染提供，仅验证了“能构建、能启动、
  能播放、能 Seek”。规避：在物理 Linux 机器上复测硬解与真实 GPU 输出。
- **Spider sidecar 最小 IPC 客户端与生命周期验证**：两条路线均未实现，仅冻结了
  `packages/spider-abi` 的消息信封、能力声明与错误形状契约并通过契约测试。该评分项
  两条路线均按中性基线 80 记录，属于未验证项而非已通过项，需在 MVP-A 前补齐。
- **团队熟悉度**：无人员经验数据，两条路线均按中性 70 记录，作为后续风险项。

## 决策

**冻结 Flutter + media-kit 作为 Phase 0 主路线。**

理由：两条路线都通过了全部硬门槛，但 Flutter 在跨平台打包、native 集成复杂度和可
测试性上优势明显，加权总分领先 13.4 分（≥ 5 分），且与设计文档“两条均通过则优先
Flutter”的默认决策一致。Kotlin/JVM + libmpv 在首帧与 Seek 性能上更优，但性能差距
（毫秒级，远低于门槛）不足以抵消其打包与 native 维护成本；保留为已验证备选方案。

按设计文档 6 节要求，未选中的 UI 候选目录应删除或移入独立实验仓库以避免长期双栈。
`prototypes/` 下两份原型当前均未被 git 跟踪，删除不可恢复，因此本 ADR 将该清理动作
列为待执行项，需在确认后执行。