#include "native_trace.h"

#include <windows.h>

#include <cstdio>
#include <string>

namespace webhtv {
namespace NativeTrace {
namespace {

// 进程创建时刻（100ns 单位），作为所有阶段的时间零点。
unsigned long long g_process_start_100ns = 0;
// 追踪输出路径；为空时所有打点都是空操作。
std::string g_path;

// 把 FILETIME 转换为 100ns 单位的 64 位整数。
unsigned long long ToHundredNs(const FILETIME& value) {
  ULARGE_INTEGER combined;
  combined.LowPart = value.dwLowDateTime;
  combined.HighPart = value.dwHighDateTime;
  return combined.QuadPart;
}

// 当前相对进程创建时刻的毫秒数。
unsigned long long ElapsedMilliseconds() {
  FILETIME now;
  ::GetSystemTimeAsFileTime(&now);
  const unsigned long long current = ToHundredNs(now);
  if (current < g_process_start_100ns) {
    return 0;
  }
  return (current - g_process_start_100ns) / 10000ULL;
}

// 本进程累计占用的 CPU 时间（内核 + 用户），单位毫秒。
//
// 与墙钟并列记录是定位冷启动的关键手段：CPU 时间接近墙钟说明受计算（VM 初始化、
// 着色器编译）限制；CPU 时间远小于墙钟说明在等待 I/O 或等待某个超时/重试。
unsigned long long CpuMilliseconds() {
  FILETIME creation;
  FILETIME exit_time;
  FILETIME kernel;
  FILETIME user;
  if (!::GetProcessTimes(::GetCurrentProcess(), &creation, &exit_time, &kernel,
                         &user)) {
    return 0;
  }
  return (ToHundredNs(kernel) + ToHundredNs(user)) / 10000ULL;
}

// 从命令行取出 `--startup-trace=<path>`。
//
// 有意不用 `CommandLineToArgvW`：此处只需要一个前缀匹配，且必须能在 Flutter 引擎
// 任何初始化之前运行（`wWinMain` 的第一行），因此保持零依赖。
std::string TracePathFromCommandLine() {
  const std::wstring command_line = ::GetCommandLineW();
  const wchar_t* const prefix = L"--startup-trace=";
  const size_t prefix_length = ::wcslen(prefix);

  const wchar_t* cursor = command_line.c_str();
  while ((cursor = ::wcsstr(cursor, prefix)) != nullptr) {
    cursor += prefix_length;
    const wchar_t* end = cursor;
    while (*end != L'\0' && *end != L' ' && *end != L'"') {
      ++end;
    }
    if (end == cursor) {
      continue;
    }
    const int required = ::WideCharToMultiByte(CP_UTF8, 0, cursor,
                                               static_cast<int>(end - cursor),
                                               nullptr, 0, nullptr, nullptr);
    if (required <= 0) {
      continue;
    }
    // `WideCharToMultiByte` 的输出缓冲是 `LPSTR`（可写）。这里多分配 1 字节让函数
    // 写入结尾 NUL（`cbMultiByte` 不含 NUL，但写缓冲区会需要它），转换后再收缩。
    std::string path(static_cast<size_t>(required) + 1, '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, cursor, static_cast<int>(end - cursor),
                          path.data(), required, nullptr, nullptr);
    path.resize(static_cast<size_t>(required));
    return path;
  }
  return std::string();
}

// 以追加方式写一行，进程被强杀时已写内容仍然保留。
void AppendLine(const std::string& line) {
  if (g_path.empty()) {
    return;
  }
  FILE* file = nullptr;
  if (::fopen_s(&file, g_path.c_str(), "ab") != 0 || file == nullptr) {
    return;
  }
  ::fwrite(line.data(), 1, line.size(), file);
  ::fclose(file);
}

}  // namespace

void Start() {
  FILETIME creation;
  FILETIME exit_time;
  FILETIME kernel;
  FILETIME user;
  if (::GetProcessTimes(::GetCurrentProcess(), &creation, &exit_time, &kernel,
                        &user)) {
    g_process_start_100ns = ToHundredNs(creation);
  } else {
    FILETIME now;
    ::GetSystemTimeAsFileTime(&now);
    g_process_start_100ns = ToHundredNs(now);
  }

  g_path = TracePathFromCommandLine();
  Mark("process-start");
}

void Mark(const std::string& stage) {
  if (g_process_start_100ns == 0) {
    return;
  }
  char buffer[320];
  const int written =
      ::snprintf(buffer, sizeof(buffer), "native-trace %s=%llums cpu=%llums\n",
                 stage.c_str(), ElapsedMilliseconds(), CpuMilliseconds());
  if (written > 0) {
    AppendLine(std::string(buffer, static_cast<size_t>(written)));
  }
}

}  // namespace NativeTrace
}  // namespace webhtv
