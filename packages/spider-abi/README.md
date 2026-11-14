# WebHTV Spider ABI

Spider 必须在独立进程运行。宿主通过逐行 JSON 消息通信，不在 UI 主进程加载远程脚本或 JAR。

Phase 0 冻结 `webhtv-ipc-v1` 的消息信封、能力声明和错误形状；具体运行时适配在后续阶段实现。
