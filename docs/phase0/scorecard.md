# Phase 0 对比评分卡

评分只引用可复查的证据：命令输出的 `PHASE0-EVIDENCE` 行，以及
`docs/phase0/evidence/` 下的截图像素统计。接口已实现、部分通过、未执行、缺少证据
均不计为完整通过。

## 1. 实测证据

Windows 侧：Windows 11（10.0.22631）、JDK 21.0.12、Visual Studio 2022 Build Tools
`14.44.35207`、Flutter 3.47.5 / Dart 3.13.4、libmpv client API 2.5。

Linux 侧：Ubuntu 22.04.5（容器，WSL2 内核）、JDK 21.0.12.1（Temurin）、GCC 11、
Flutter 3.47.5 / Dart 3.13.4、libmpv 0.34.1，Xvfb + Openbox + Mesa llvmpipe
软件渲染。

| 验收项 | Flutter + media-kit | Kotlin/JVM + libmpv | 证据 |
| --- | --- | --- | --- |
| 主窗口内嵌播放 | 通过 | 通过 | Flutter：`docs/phase0/evidence/flutter-header-hls.png`；Kotlin：`kotlin-embedded-header-hls.png`，libmpv 的 `mpv` 子窗口挂在 `WebHTVPhase0VideoHost` 下、后者挂在 `SunAwtFrame` 客户区内 |
| 本地 MP4 | 通过 | 通过 | Flutter：`flutter-local-mp4.png`；Kotlin：`kotlin-embedded-mp4.png`；`duration=6021ms`/`6.000` |
| 本地 HLS | 通过 | 通过 | Flutter：`flutter-local-hls.png`；Kotlin：`kotlin-embedded-local-hls.png`；`duration=6000ms` |
| Referer/User-Agent HLS | 通过 | 通过 | Flutter：`flutter-header-hls.png`；Kotlin：`kotlin-embedded-header-hls.png`；缺失 Header 时 fixture 返回 403 |
| HLS Seek | 通过 | 通过 | Flutter：`hls-seek target=3000ms reached=true final=2999ms elapsed=273ms samples=[2999]`；Kotlin：`embedded seek-target=3.000 playback-time=3.021` |
| 全屏与恢复窗口 | 通过 | 通过 | Flutter：`flutter-fullscreen.png` + `fullscreen-entered=true/fullscreen-restored=true`；Kotlin：`kotlin-fullscreen.png`，全屏后视频区高度铺满 1080（修复前仅占 70% 高度，见 `HostWindow.resizeVideoToWindow`） |
| 异常 URL 错误恢复 | 通过 | 通过 | Flutter：`invalid-url ... reason=Failed to open ...`；Kotlin：`headless result=error:loading failed`，进程以非 0 退出 |
| 配置到 HTTP API 播放闭环 | 通过 | 通过 | Flutter：`config-flow-playback ok ... duration=6000ms`；Kotlin：`headless result=file-loaded ... seek-target=3.000 playback-time=3.021` |
| 契约与 fixture 测试 | 通过 | 通过 | `py -m unittest tests.test_contracts -v` → 4 passed；`scripts/validate_contracts.py` |
| native 依赖自动发现 | 通过 | 通过 | Flutter Release 目录自带 `libmpv-2.dll` 等 72.9 MB 运行库；Kotlin JNI 通过 `LoadLibrary`/`dlopen` 解析，构建不绑定导入库 |
| Windows 构建/启动 | 通过 | 通过 | `flutter build windows --release` → `webhtv_phase0.exe`；`build_windows.ps1` → `webhtv_mpv_jni.dll` + JVM 类 |
| Linux 构建/启动 | 通过 | 通过 | Flutter：`flutter build linux --release` → `build/linux/x64/release/bundle/webhtv_phase0`，Xvfb 下创建 960×640 主窗口并内嵌播放 HLS（`flutter-linux-header-hls.png`，非黑 0.624）；Kotlin：`build_debug.sh` + `java ... --headless`，MP4/HLS/Header/Seek/异常 URL/配置闭环全部通过，日志 `kotlin-linux-benchmark.txt` |
| macOS 构建流程 | 未执行 | 未执行 | 无可用 macOS 机器 |

## 2. 可复现命令

> Phase 1 结构整理后，Flutter 主线已提升为产品工程 `apps/desktop-flutter`，
> 未选路线（Kotlin/JVM + libmpv）的原型与其专属工具已按 Phase 0 任务 10 从产品
> 仓库移除（源码见 git 历史），fixture 统一收敛到 `packages/test-fixtures`。
> 因此下表的命令与路径反映整理后的状态；历史原始日志
> （`docs/phase0/evidence/*.txt`）保持原样不动，它们记录的是当时的真实输出。

```powershell
# 契约与 fixture
py -m unittest tests.test_contracts -v

# 本机 fixture 服务（Header 门禁依赖它），产品阶段已扩展到 type=0/1/2/4
py -m tools.fixture_server.server

# 产品工程：静态检查、单元与集成测试
cd apps/desktop-flutter
& $puro -e webhtv flutter analyze
& $puro -e webhtv flutter test
& $puro -e webhtv flutter test integration_test/mvp_a_flow_test.dart -d windows
& $puro -e webhtv flutter build windows --release

# 画面渲染证据（截窗口 + 像素统计），产品阶段工具
py tools/phase1/capture_windows_evidence.py --exe apps/desktop-flutter/build/windows/x64/runner/Release/webhtv_pc.exe --media http://127.0.0.1:18080/media/sample.m3u8 --header Referer:http://127.0.0.1:18080/ --header User-Agent:WebHTV-PC/0.1\ \(Windows\) --output docs/phase1/evidence/windows-header-hls.png
```

Phase 0 当时的可复现命令（Kotlin 路线）保留在 git 历史提交 `cdb9245` 与其工具
脚本中；本仓库不再保留对应原型目录，以避免设计文档 §6 明确禁止的长期双栈。

## 3. 截图统计（证明不是黑屏）

| 截图 | 色数 | 非黑占比 | 尺寸 | 视频区 |
| --- | ---: | ---: | --- | --- |
| flutter-header-hls.png | 48999 | 0.904 | 960×640 | 960×640 |
| flutter-local-mp4.png | 54929 | 0.902 | 960×640 | 960×640 |
| flutter-fullscreen.png | 164048 | 0.704 | 2560×1080 | 2560×1080 |
| flutter-linux-header-hls.png | 52735 | 0.624 | 1280×720 | 960×640 |
| kotlin-embedded-header-hls.png | 77291 | 0.924 | 960×640 | 960×640 |
| kotlin-embedded-mp4.png | 77305 | 0.924 | 960×640 | 960×640 |
| kotlin-fullscreen.png | 236135 | 0.751 | 2560×1080 | 1920×1080 |

## 4. 重复采样统计（每项 10 次）

原始日志：Windows 侧 `docs/phase0/evidence/flutter-benchmark.txt`、
`docs/phase0/evidence/kotlin-benchmark.txt`；Linux 侧
`docs/phase0/evidence/flutter-linux-benchmark.txt`、
`docs/phase0/evidence/kotlin-linux-benchmark.txt`（均含逐次 `PHASE0-EVIDENCE`）。
首帧采用统一代理定义：media-kit / libmpv 均无独立首帧回调，因此用
“播放位置首次大于 0”作为已出画的可观测代理；加载耗时与首帧耗时分开统计，
不使用加载耗时冒充首帧。

Windows 11（每项 n=10）：

| 指标 | Flutter + media-kit | Kotlin/JVM + libmpv |
| --- | --- | --- |
| 本地 MP4 加载 | median 116ms / p95 177ms | median 14ms / p95 27ms |
| 本地 MP4 首帧 | median 246ms / p95 500ms | median 35ms / p95 57ms |
| 本地 HLS 加载 | median 128ms / p95 144ms | median 19ms / p95 37ms |
| 本地 HLS 首帧 | median 240ms / p95 268ms | median 39ms / p95 62ms |
| Header HLS 加载 | median 145ms / p95 169ms | median 41ms / p95 47ms |
| Header HLS 首帧 | median 262ms / p95 420ms | median 61ms / p95 94ms |
| HLS Seek 到达 | median 252ms / p95 253ms | median 11ms / p95 22ms |
| 启动到可交互 | 550ms（单次，见日志） | 不适用（headless CLI） |

Linux（Ubuntu 22.04 容器，软件渲染，每项 n=10）：

| 指标 | Flutter + media-kit | Kotlin/JVM + libmpv |
| --- | --- | --- |
| 本地 MP4 加载 | median 89ms / p95 177ms | median 39ms / p95 70ms |
| 本地 MP4 首帧 | median 203ms / p95 491ms | median 60ms / p95 95ms |
| 本地 HLS 加载 | median 91ms / p95 102ms | median 49ms / p95 120ms |
| 本地 HLS 首帧 | median 214ms / p95 250ms | median 68ms / p95 166ms |
| Header HLS 加载 | median 123ms / p95 166ms | median 106ms / p95 140ms |
| Header HLS 首帧 | median 253ms / p95 455ms | median 131ms / p95 168ms |
| HLS Seek 到达 | median 253ms / p95 254ms | median 5ms / p95 6ms |
| 启动到可交互 | 361ms（单次，见日志） | 不适用（headless CLI） |

结论：两条路线在固定素材、固定机器上的加载与首帧均稳定在数百毫秒内，远低于
Phase 0 设定的 5 秒门槛；Kotlin/JVM + libmpv 在加载、首帧与 Seek 上一致更快。

## 5. 硬门槛结论

| 决策门 | Flutter + media-kit | Kotlin/JVM + libmpv |
| --- | --- | --- |
| 1. 播放器内嵌主窗口 | 通过 | 通过 |
| 2. MP4/HLS/Seek/Header | 通过 | 通过 |
| 3. 打包后能发现 native 库 | 通过 | 通过 |
| 4. 配置导入到播放不卡死 | 通过 | 通过 |
| 5. 崩溃/黑屏/全屏/音画问题已记录 | 通过 | 通过 |
| Linux + Windows 构建/启动 | 通过 | 通过 |

两条路线均通过 P0-A 硬门槛。

## 6. 当前阻塞与未通过项

- macOS 完全未执行，需要可用 macOS 机器；不影响 Windows/Linux 的硬门槛判定。
- 本机 Windows 只能通过容器提供 Linux 环境，因此 Linux 侧采样使用 Xvfb + Openbox +
  Mesa llvmpipe 软件渲染。结论对“能构建、能启动、能播放、能 Seek”有效；Linux 上的
  硬件加速与真实 GPU 输出仍需在物理 Linux 机器上复测。
- 已记录并修复的环境相关风险：
  - Linux（无声卡/无 GPU 容器）media-kit 会上报非致命的音频/解码告警；控制器已改为
    以 duration 判定加载结果，避免把可播放媒体误判为失败。
  - Linux 上 media-kit 需要 Player 绑定到已挂载的 Video 控件后才推进播放管线；集成
    测试与基准测试均已按真实应用路径挂载 Video。
  - libmpv 要求 LC_NUMERIC=C，中文 Linux 环境会导致 mpv_initialize 直接失败；JNI 侧
    已在加载动态库前显式归位 locale。
- 无崩溃、黑屏：所有截图非黑占比 >= 0.62；异常 URL 明确报错而非静默成功。
