# ADR-0001：Phase 0 桌面技术路线

- 状态：进行中
- 日期：2026-09-25

## 背景

设计要求使用同一组素材比较 Flutter/media-kit 与 Kotlin/Compose/libmpv，并在进入 MVP-A 前只保留一条产品路线。

## 当前环境事实

- Linux x86_64、JVM 21、GCC 15 和 FFmpeg 7.1.1 可用。
- 当前 PATH 中仍没有 Flutter、Dart、Gradle或 Kotlin 编译器。
- 未修改系统软件包；libmpv 0.40.0 及补充运行库已解压到忽略提交的 `.local/mpv` 目录。
- JVM/JNI Debug 原型已能编译、加载 libmpv，并读取 client API 2.5。
- 上述结果仅证明 native 依赖发现、JNI 构建和 libmpv 初始化可行，不等于 Compose 主窗口内嵌播放已经通过。

## 已收集证据

- 配置协议、Spider manifest 和四种 IPC 消息契约验证通过。
- 本地 fixture HTTP 服务的 health、home、category、detail、play 端点验证通过。
- Kotlin/JVM JNI Debug 原型在 Linux 上编译并成功初始化 libmpv 0.40.0。
- 同一组合成媒体 fixture 已生成：6 秒本地 MP4、HLS 清单与 TS 分片。
- Kotlin/JVM + libmpv 原型成功加载本地 MP4，并收到 `file-loaded`。
- Kotlin/JVM + libmpv 原型成功加载要求 Referer 与 User-Agent 的本地 HTTP HLS，并收到 `file-loaded`；缺少 Header 的请求被 fixture 服务以 HTTP 403 拒绝。
- HLS Seek 已执行验证：目标位置为 3.000 秒，读取到的 `playback-time` 为 3.901 秒。
- 异常媒体 URL 已返回 `error:loading failed`，测试进程以状态码 1 明确失败，没有静默转为空结果。
- 最小 TVBox JSON 配置已完成 HTTP API 播放闭环：依次解析站点、首页、分类、详情和播放响应，将播放 URL、Referer 与 User-Agent 交给 libmpv，并收到 `file-loaded`。
- 当前环境出现 EGL、DRI3、Zink 和 VDPAU 警告，但未阻止解封装与文件加载；这不构成硬件加速、画面渲染或窗口内嵌通过的证据。
- Debug 构建产物和测试进程已在执行后清理。

## 仍需收集的证据

两条候选路线分别记录：内嵌播放、本地 MP4、本地 HLS、带 Header 的远程 HLS、Seek、全屏、异常 URL、HTTP API 闭环、Linux/Windows 构建和运行时依赖发现。

Flutter SDK 尚未准备，因此 Flutter/media-kit 原型仍未开始。Kotlin/JVM 路线还没有 Compose Desktop 主窗口和内嵌渲染句柄，不能将当前 JNI 初始化结果记作播放器验收通过。

## 决策

尚未冻结。两条路线未按同组素材完成验证前，不进入 MVP-A，不删除任一原型目录。
