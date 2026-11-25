# PR #127：Windows 原生测试 PID 复用崩溃修复

## 失败现场
- 旧head：8153d0ce0445bff6002d6df872213e4108f99492。
- PR run45594654725七项成功；同head的push run45594636892仅Windows shard3 Unit tests失败，导致Windows汇总失败；其余jobs成功。
- shard3诊断artifact15012924886，stdout行16620的test375使用PID5620；16733分配NativeReferenceHolder；进程退出后17877的test405再次使用PID5620；17908 flutter_tester退出-1073741819（0xC0000005）。
- 失败事件只有audio UI两个testDone:error（221ms/1ms），无Dart错误事件；不是普通断言超时。

## 受控根因复现
media_kit1.2.6在系统临时目录按PID保存NativeReferenceHolder裸指针，文件已存在就从地址恢复。Windows复用已退出进程PID时，旧文件中的地址属于旧进程。

测试前临时为当前PID引用文件写值1，再运行原audio UI coverage四分片中的shard3，稳定复现C0000005和两原case:error/skip0。临时注入只用于本地验证，已移除，原audioUI文件最终零diff。不是用固定等待、重跑或skip宣称修复。

## 修复边界
- test/support/libmpv_guard.dart：Windows且NativeReferenceHolder尚未初始化时，仅移除当前PID的精确引用文件。
- test/support/player_page_harness.dart：原生初始化前调用同一防护。
- test/media_kit_native_reference_lifecycle_test.dart：单个自包含、可独立分片的回归，验证旧引用清理、其他PID文件不动、重复调用幂等、活跃缓冲保留，使用真实Player执行音量写入和回读。

仅测试fixture修改，未更改业务播放器、上游依赖、原音量归一用例断言或CI超时；未跳过原生测试。内部API接缝绑定lockfile media_kit1.2.6，升级时需要复核文件命名与initialized语义。

## 验证证据
- controlled red：原命令CLIexit1，native0xC0000005，两case:error/skip0。
- controlled green：相同陈旧文件和相同命令，防护后CLIexit0，两case:success/skip0。
- 正式生命周期+UI四分片：2/3/2/2，通过9项、skip0、全部exit0。
- Lead独立使用CI pin SHA256=88504ee5560942a955405e99dfb5971368e4cf851321f36565bf2a667271db1b（121789952bytes）内核，并提供test-only ffmpeg：生命周期1+UI8+native4共13项通过、skip0；AC3真实输出spdif-ac3、WAV输出doublep。
- 额外harness回归：click6/doubleclick99/offset3通过。dart analyze --fatal-infos完整分析0issue。
- 本机旧Debug/Release DLL SHA d5f0694b08c124e785d858d00082f3e3b158dd9138bfc48c0382bf1eb443a5fc不属于CI pin；其AC3等待失败不归为产品回归，未据此改native测试。

后续：推送新head后重新跟进PR和push两条完整DesktopCI，最终远端结论以新headchecks为准。

## 监听期间最新 beta 的集成回归

beta在首轮CI监听时推进至0fd7e5a（PR126：原PC配置安卓执行与受管媒体），dev2已无冲突合入97672f1。静态复核确认20个beta新增/更新lib模块中仅AppState保留预期的首页直播关键词与历史TMDB差异，其余语义完整保留。

独立运行新beta的android_managed_environment_startup_test.dart，描述缺失场景出现Duration.zero pending timer，堆栈LogService._enqueue→HomePage._restoreStartup。外层tearDown在testWidgets检查之后才dispose，新增首页日志暴露了夹具未在测试体内释放所有者的集成缺口。最小修法仅该测试文件：三个case改用同一try/finally包装，先卸载真实AppShell，再dispose拥有的AppState；外层只删除临时目录。原横幅/重试/UUID/保留配置/不访问旧端口断言不变，不pump固定时间掩盖问题，不改productionlogger。原版独立2pass1fail，包装版3pass通过；四分片与分析结果另由最终验收记录。

最终刷新beta后的本地验收：测试清理helper3case独立通过；非空分片0/1/3各1case通过，分片2本文件无分配返回79（仅三case不可能覆盖四片，不算通过冒称）；27断言/原三testbody保留。Lead独立执行最新合并树11套首页/原生/安卓执行/状态回归89项通过、零失败，完整dart analyze --fatal-infos为0issue。
