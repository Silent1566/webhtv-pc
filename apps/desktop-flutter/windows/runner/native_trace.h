#ifndef RUNNER_NATIVE_TRACE_H_
#define RUNNER_NATIVE_TRACE_H_

#include <string>

namespace webhtv {

// 启动阶段追踪（原生侧）。
//
// 设计文档 §22.2 要求测量“从进程启动到首个可交互主界面”，并允许把冷启动与首帧
// 分开统计。Dart 侧的 Stopwatch 只能覆盖 Dart 入口之后的阶段，无法解释“进程已创建
// 但 Dart 尚未运行”的空档；实测该空档是冷启动的主要组成部分。因此这里以进程创建
// 时间（`GetProcessTimes`）为零点，记录原生各阶段。
//
// 输出为逐行追加的 `native-trace <stage>=<ms>ms`，与 Dart 侧的
// `startup-trace <stage>=<ms>ms` 写入同一文件，便于对照。
namespace NativeTrace {

// 在 `wWinMain` 最开头调用：确定零点、解析输出路径并记录 `process-start`。
void Start();

// 记录一个阶段。未调用 [Start] 或没有输出路径时为空操作。
void Mark(const std::string& stage);

}  // namespace NativeTrace

}  // namespace webhtv

#endif  // RUNNER_NATIVE_TRACE_H_
