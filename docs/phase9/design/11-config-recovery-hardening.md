# 配置恢复与测试隔离加固

## 决策记录
- 已定：正式库恢复至可用接口，备份已确认可回滚；用户选择修测试隔离与本地来源失效提示。
- 假设：失效本地源仍可用缓存，不自动删记录/历史、不自动替换配置；用户关闭提示或进入配置管理自行处理。
- 排除：修改播放协议、网络探测所有源、清理其它测试夹具、复制改动到另一个工作树（未经要求）。
- 完成：原 Windows-style 参数在 Linux 不再落真实目录；无隔离测试第一次 IO 失败闭锁；失效来源在列表和启动时有明确可操作提示，Before/After+隔离回归通过。

## 已确认事实
正式数据库 /home/maple/.local/share/webhtv-pc/webhtv-pc.sqlite3 已从 active17 改为 active1，删除失效临时17，history24未变；备份 backup-before-config-repair-20261114-162654 内 active17/history24，两库 quick_check=ok。接口 http://192.168.50.50:4567/t4/2024/buye-0 返回200。
旧验证目录 apppaths-red.log 证明 POSIX 忽略 roaming/local 而回落 HOME；当前 dev3 app_paths.dart:54-69 仍有这个缺口。另一个 checkout 的 app_paths.dart 已有同构 fallback，可作为只读参考，不复制其他更改。
Flutter tester 由 .tools/flutter/packages/flutter_tools/lib/src/test/runner.dart:717-726 注入 FLUTTER_TEST=true（除非调用方显式覆盖）。当前启动：app_state.dart:2725 先 await paths.ensureDirectories，随后2822打开DB；在第一处封锁可以避免DB和后续settings/cache写入。

## 固定约束
- 仅编辑 dev3 指定边界；保留已完成观影报告及所有现有未提交改动。不提交、不推送、不操作主 checkout。
- 不修改真实用户配置/数据库/设置（已完成一次授权修复）；所有测试工具进程使用独立 HOME 和四个 XDG 根，TMPDIR/PUB_CACHE 也显式指定。
- 零新增依赖；路径平台默认值在正常生产中保持现有约定；别把 Windows 驱动器路径/HTTP/inline://json/桥接源当本地失效文件。
- 本地文件检测仅 filesystem，不发网络。不存在与访问失败分别表达；不自动删来源/缓存/历史、不自动选其它记录。
- UI沿用 PRODUCT.md/DESIGN.md/tokens；配置点击切换、编辑、刷新仍保留；明确“使用缓存，刷新不可用，恢复文件/编辑来源或切换配置”。
- 新状态异步返回不能贴到用户已经切换的配置上。来源URL按既有脱敏方法显示，不显示凭据。

## 模块A：路径解析和测试写入防护
文件 lib/services/app_paths.dart + test/app_paths_write_probe_test.dart + test/app_paths_isolation_test.dart。
POSIX 优先顺序：最终目录 config/data/cache/state > xdg* > 同构 roaming/local > XDG环境 > HOME默认。仅 roaming/local 时 config=roaming/app，data=local/app，cache=local/app/cache，log=local/app/logs。不能因为提供Windows键就把cache/log默默落进用户目录。macOS显式覆盖不能被后续默认分支抹掉。
测试环境 FLUTTER_TEST=true：保留 AppPaths.resolve 默认返回供纯mock/只读测试使用，但没有覆盖所有可写目录的有效显式参数时，ensureDirectories 必须在任何 mkdir/写入之前抛 StateError，消息要求提供隔离目录；不能报告失败后仍打开真实库。显式跨平台完整根覆盖及完整最终目录覆盖允许正常创建。部分/空/拼错 overrides 不得悄悄形成混合真实目录。生产（非FLUTTER_TEST）默认行为不变。
只在写入边界加闸，避免所有使用AppState()的纯UI/mocked测试在构造时崩溃。无需全局临时目录、进程共享测试画像、或无限制清理策略。

## 模块B：冻结接口与启动状态（B定义，C消费）
lib/services/config_source_status.dart，引用现有 ConfigSource.parse 和 ConfigRecord，不复制协议判断逻辑。



a) enum ConfigSourceAvailability { notLocal, available, missing, unreadable }
b) class ConfigSourceStatus {
 const ConfigSourceStatus({required this.recordId, required this.name,
   required this.availability, this.path});
 final int recordId;
 final String name;
 final ConfigSourceAvailability availability;
 final String? path;
 bool get needsAttention; // missing||unreadable
}
c) Future<ConfigSourceStatus> inspectConfigSource(ConfigRecord record);
d) AppState: ConfigSourceStatus? get restoredConfigSourceStatus;
e) AppState: void dismissRestoredConfigSourceWarning();

真实file存在→available；HTTP(S)/inline/桥接网络origin→notLocal且零网络；本地不存在→missing；FS抛权限/其他访问异常→unreadable，不能一律冒充已删除。
bootstrap恢复缓存后若检测active本地来源失效，继续缓存配置并发布restoredConfigSourceStatus；启动不静默丢弃旧配置。记录切换/删除/刷新成功清掉对应警告（含异步过期检查）；用户关闭提示只影响提示，不删除数据。不能设置共享lastError让首页正常成功吞掉警告。
B文件 lib/state/app_state.dart + lib/services/config_source_status.dart + test/config_source_status_test.dart + test/config_source_restore_test.dart。不改A路径模块或C UI。

## 模块C：页面提示与视觉验证
lib/ui/config_pages.dart：已保存配置列表+切换选择器对本地来源异步检测并显示“来源文件已丢失/无法读取 · 使用缓存”。检测不可在每次build重新扫描所有文件，单行组件按id+origin绑定future并在origin变化时刷新；晚返回不得贴错行。正常HTTP和inline不出现假警告。缓存切换不禁用。
lib/ui/app.dart：启动后restoredConfigSourceStatus为needsAttention时出现紧凑提示：保留当前缓存，刷新前恢复文件/编辑来源或切换配置；动作“管理配置”走已有ConfigPage入口，“关闭提示”调用冻结dismiss方法；不覆盖既有恢复banner职责。
可新增 lib/ui/config_source_status_view.dart 封装两个使用点的状态展示，避免复制文件检测逻辑。
Before与After同场景fixture、亮暗主题/1280x950DPR1/字体，截图来自真实widgets；至少列表+启动警告配对。没有现成启动警告时Before展示同场景旧UI，不伪造DOM/页面。

## 测试与验收
A：roaming/local同构Linux；xdg优先；最终目录优先；默认/部分override在FLUTTER_TEST第一次IO失败且HOME下零新文件；完整isolatedoverride允许；非test默认值保持；原probeWritable回归。
B：删来源文件后DB缓存启动仍工作；警告正确且可关闭；创建/恢复来源后成功刷新清警告；切换配置晚响应不污染；本地file:///HTTP/inline辨识；历史/更新时间未被提示流程改动。
C：同名配置清晰区分；失效/正常文件/网络源；长路径与窄屏；启动警告按钮可达；真实同场景Before/After。
最后独立复跑A/B/C + config_record_edit_refresh_test/config_page_switch_ui_test/phase10_last_config_test/phase6_local_config_source_identity_test/phase8_app_state_config_test + 报告回归，并analyze。所有命令必须先隔离HOME/XDG，不能再用默认生产路径作测试。

## 构建交付
用户的 PROJECT_ROOT=git rev-parse 顶层会随终端cwd变化。提供显式 PROJECT_ROOT=/home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3 的命令；不擅自把代码复制到 /home/maple/orca/webhtv-pc。默认启动仍使用修复过的正式用户profile，测试profile不用于正式启动。
