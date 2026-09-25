# Phase 0 对比评分卡

| 验收项 | Flutter + media-kit | Kotlin + Compose + libmpv | 证据 |
| --- | --- | --- | --- |
| 主窗口内嵌播放 | 未执行 | 未执行 | Compose 窗口与渲染句柄尚未接入 |
| 本地 MP4 | 未执行 | 基础播放通过 | 合成 MP4 经 JNI/libmpv 加载并收到 `file-loaded`，尚未验证窗口画面 |
| 本地 HLS | 未执行 | 基础播放通过 | 合成 HLS 经本机 HTTP fixture 加载并收到 `file-loaded` |
| Referer/User-Agent HLS | 未执行 | 基础播放通过 | 正确 Header 时收到 `file-loaded`，缺失 Header 时服务返回 HTTP 403 |
| HLS Seek | 未执行 | 基础验证通过 | 目标 3.000 秒，读取 `playback-time=3.901` 秒 |
| 全屏与恢复窗口 | 未执行 | 接口已实现，未完成窗口测试 | JNI `setFullscreen` 已实现 |
| 异常 URL 错误恢复 | 未执行 | 错误识别通过 | 无效 URL 返回 `error:loading failed`，进程以状态码 1 失败 |
| 配置到 HTTP API 播放闭环 | 未执行 | 基础闭环通过 | TVBox JSON 经首页、分类、详情、播放接口解析后，将 URL 与 Header 交给 libmpv 并收到 `file-loaded` |
| Linux 构建/启动 | 未执行 | 基础层通过 | JVM/JNI Debug 构建成功，libmpv client API 2.5 |
| Windows 构建/启动 | 未执行 | 未执行 | 待补 |
| macOS 构建流程 | 未执行 | 未执行 | 待补 |
| native 依赖自动发现 | 未执行 | 部分通过 | 本地 libmpv 0.40.0 依赖已补齐并成功加载 |

评分仅可引用可复查的日志、录像、测试报告或构建产物。接口已实现、部分通过、未执行和缺少证据均不得计为完整通过。
