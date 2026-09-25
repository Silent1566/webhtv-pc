# Kotlin/JVM + libmpv Phase 0 原型

该原型使用 JVM 21、JNI 和 libmpv 0.40.0 验证播放器边界。当前先提供不依赖 Gradle 的可重复 Debug 构建，以便在 Compose Desktop 工程接入前验证 native 加载、Header、Seek、全屏和事件循环。

```bash
prototypes/compose_libmpv/scripts/run_debug.sh
prototypes/compose_libmpv/scripts/run_debug.sh URL REFERER USER_AGENT [SEEK_SECONDS]
prototypes/compose_libmpv/scripts/run_debug.sh --config-flow packages/protocol/fixtures/config/minimal-tvbox.json
```

libmpv 及其补充运行库由本地工具链目录 `.local/mpv` 提供，不修改系统软件包。生成物位于 `prototypes/compose_libmpv/build/debug`，只属于 Phase 0 Debug 原型。

主窗口内嵌渲染仍需在 Compose Desktop 画布句柄接入后验证，不能用外部 mpv 窗口代替。
