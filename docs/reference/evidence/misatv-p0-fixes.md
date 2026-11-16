# MisaTV P0 与发现问题修复验收

- 日期：2026-11-16
- 基线：PC HEAD `9ff8bbb`；本轮为工作区修复，尚未提交。
- 范围：对照清单 §3 的 3 个 P0 + §5 的 5 个问题；不新增 WebDAV/网盘/BT/预热/Impeller/独立窗口等 P1 功能，不复制 MisaTV GPL 代码。
- 工具链：仓库 `.tools/flutter`，Flutter 3.47.5 / Dart 3.13.4；不以 PATH 中缺少 flutter 断言本机没有 SDK。
- 状态：**整合验收进行中**。下表通过项有独立运行证据；待验收项不能据 child 通知当作完成。

## 任务与证据

| 项 | 实施/验收状态 | 核查重点 |
| --- | --- | --- |
| P0-1 HLS 安全回退 | Lead 独立 scoped 回归 71 passed | 累计移除 >50% 回原文；EXTINF/URI 对齐；直播/主清单不清洗；全局标签和 KEY/MAP 保留；AES-128 隐式 IV、BYTERANGE 清单不改变原分片依赖 |
| P0-2 图片缓存/解码 | Lead 复核 5 passed + analyze 干净 | 64 MiB / 256 张，启动期安装；网格 cacheWidth = 实际列宽 × DPR；`mainAxisExtent`/列数/间距与基线逐字相同（无视觉改动） |
| P0-3 加固壳识别 | Lead 独立 jar_shell_guard + jar_intake，37 passed | dex 特征/guard 资源；bin/说明文本不能误拒；native 优先；扫描累计预算不足不宣称可转译；不执行代码；拒绝不调用转译或覆盖旧入口；router 也拒绝旧缓存壳 |
| 问题1 直播 UA | Lead 审查 diff + 独立相关回归 86 passed | M3U 属性/行级 Header 优先级，JSON explicit header > ua/referer/origin fallback，大小写不敏感；保留 extras/tvgName；播放请求透传 |
| 问题2 过期预热理由 | 已修 docs/phase9/README.md P1-6 | 常驻池已经存在；未实现的是主动预热调度，不借修文档加入无消费者开关 |
| 问题3 LAN 代理隔离 | Lead 独立复跑 59 passed（LAN guards 11 + sync 21 + bridge 27） | 新增 `createLanHttpClient` 显式 `DIRECT`；只有未注入 client 时才生效；订阅文档拉取保留普通出站 client；注入同一实例时 close 只关一次；严格 TLS 与超时不变 |
| 问题4 sidecar 空闲回收 | Lead 复跑 95 passed（含 12 个真实子进程用例）+ analyze 干净 | 默认 5 分钟、可注入时钟/调度器；`_canRecycle` 要求进程存活、非停止、无在途请求、无已交付环回播放依赖、manifest 未声明 `localProxy`；单飞启动 + 停止代际；`SidecarRuntime._ensureHost` 向 supervisor 复核 `_host` 而非信任缓存 |
| 问题5 同毫秒历史冲突 | Lead 审查 diff；child 复跑 151 passed | 同时间戳按 `(positionMs, durationMs, vodName, episodeName, vodPic)` 取字典序最大；批内重复先收敛再裁决；内容等价仍 skip；未改 Android JSON/schema/身份键；`design/02` §4.4 与 `design/03` #14 已同步更新 |

## 已运行的独立验证（阶段证据）

工作目录 `apps/desktop-flutter`，所有命令使用 `../../.tools/flutter/bin/flutter test --no-pub --reporter expanded`。

1. `test/hls_clean_rollback_test.dart` 在原基线先 red：2 passed / 7 failed，退出1；修复后通过。另添加隐式 IV/BYTERANGE 两个用例先 red（9 passed / 2 failed，退出1），加入保护后 green。
2. `test/hls_clean_rollback_test.dart test/phase9_ad_rules_test.dart test/phase2_proxy_test.dart test/phase10_hls_playlist_shape_test.dart`：`+71 All tests passed!`，退出0。
3. `test/jar_shell_guard_test.dart` 原基线先 red：2 passed / 10 failed，退出1；与 `test/jar_intake_test.dart` 合跑 green：`+37 All tests passed!`，退出0。
4. `test/hls_clean_rollback_test.dart test/phase9_ad_rules_test.dart test/live_channel_ua_test.dart test/phase3_live_test.dart test/phase3_live_page_test.dart test/phase9_live_catchup_test.dart`：阶段合跑 `+86 All tests passed!`，退出0（此时 HLS 为最初9个测试，后续又增加两个密码/偏移安全用例）。

上述批次有重叠，不能把次数相加当作独立测试总数。

5. **最终随本轮改动一起跑的 9 个新/改测试文件**（`hls_clean_rollback`、`jar_shell_guard`、`jar_intake`、`phase9_ad_rules`、`live_channel_ua`、`image_decode_budget`、`lan_http_direct`、`history_merge_convergence`、`sidecar_idle_recycle`）：`+131 All tests passed!`，退出0。
6. 各模块回归：LAN 59、sidecar/蜘蛛 95、HLS 与代理 79、历史同步 151、jar 40 —— 均为 scoped 运行，不重复计入上面的 131。

## 全量测试与基线对照（重要）

全量 `flutter test` 在本机跑出 **+5445 / ~36 / -185**，其中失败集中在三个**本轮未改动**的文件：`player_history_lines_test.dart`、`player_quality_ui_test.dart`、`phase8_player_page_overlay_test.dart`。

为判断归属，做了基线对照：`git stash push -- apps/desktop-flutter/lib` 后在同一工作区重跑这三个文件，得 **65 个失败**；恢复改动后重跑，得 **65 个失败**（差距来自运行时统计行，不是新增用例）。**结论：这三个文件的失败是既有问题，与本轮改动无关。** 恢复后 `git diff` 与备份补丁逐字节一致（`PATCH_IDENTICAL`），未丢改动。

另一次全量运行在 `phase2_ipc_test.dart` 处停滞 30 分钟（计数器不动）。该文件单独跑是通过的，停滞发生在全量并行 + 大量真实子进程（Python/JVM/aria）争用 CPU 时；这是本机环境的并行不稳定性，不是断言失败。**因此本机全量测试不作为验收门槛**，验收依据是 touched-area scoped 套件 + 逐文件回归；仓库 CI（`.github/workflows/desktop-ci.yml:195` 的 `flutter test`）仍是最终门禁。

### 独立安全复核（只读子代理）与其处置

复核用真实 zip 夹具复现了 4 类 HLS 与 3 类 JAR 缺陷，已全部修复并补测试：

| 发现 | 处置 |
| --- | --- |
| JAR：`maxEntries` 截断使 `lib/*.so` 落在第 50001 条后即被漏判，含 `.so` 的 jar 被写成可转译并交给转译器 | 改为自己解析**中央目录**（不再用 `ZipDecoder`），拿到完整清单；中央目录不完整/含符号链接条目时按「无法确认」拒绝 |
| JAR：32 MiB 预算只约束 zip 头里**声明**的大小，声明 1 字节也能解出 40 MiB | 预算改为约束**真正读到的字节**；解压走有界 sink，超限即放弃；`raw: true` 解裸 deflate |
| JAR：archive 在 `decodeStream` 时急切解压符号链接条目 | 不再使用 archive 解码器；符号链接条目直接拒绝(注:符号链接检测为拒绝而非解压) |
| JAR：条目大小声明与实际不符时检测只读声明量却宣称「已检查」 | 校验数据区之后必须是下一个本地头/中央目录/数据描述符，否则拒绝 |
| HLS：SAMPLE-AES / SAMPLE-AES-CTR 隐式 IV 仍被删片 | 任何非 `NONE` 且无显式 `IV` 的 `METHOD` 一律回退 |
| HLS：非白名单清单级标签（`DEFINE`/`DISCONTINUITY`/`I-FRAMES-ONLY`/`GAP`）被一并删除，破坏仍保留的分片 | 改为「只删描述被删分片本身的标签」（`EXTINF`/`BYTERANGE`/`PROGRAM-DATE-TIME`/`BITRATE`），其余一律保留 |
| HLS：无条件保留 `EXT-X-MAP` 会把广告的初始化段接到正片上 | 被删分片自带 `MAP` 时整次放弃清洗 |
| HLS：带 UTF-8 BOM 的清单永远不清洗 | 分析时去 BOM，回写补回 |

## 设计取舍与复核路由

- 当前只有规则级 HLS 清洗。MisaTV 的“单级30%”用于部分启发式，不直接套在规则层；保持现有1/3或1/2广告可删的规则行为，以累计50%和结构/密码/字节偏移安全阀兜底。五级启发式仍不在本轮范围。
- [RFC 8216 §5.2](https://www.rfc-editor.org/rfc/rfc8216.html#section-5.2) 确认未显式 IV 的 AES-128 依赖媒体序号；因此仅保留 KEY 文本不够，安全做法是保留原加密清单。本轮不实现隐式 IV 重写或 Range 偏移重算。
- UA 第一次 child 报告还发现 JSON header 未解析，直接破坏显式优先级。已在原 child run2 返工并纳入测试，不能作为“已知但不处理”发货。
- LAN 同步客户端与应用出站设置并非同一个实例：`SyncState` 自建独立客户端（`sync_state.dart:229-230`），`AppState` 的出站工厂（`app_state.dart:1985-1988`）不会到达它们。真正会泄漏的是 Dart SDK 默认 `HttpClient.findProxyFromEnvironment`（`http_impl.dart:2795`，经 `HttpOverrides.current` 生效）。因此本条按“环境代理隔离”验收，不声称修复了应用代理设置注入；`fetchLiveSources` 的订阅地址仍走普通出站客户端。
- 图片解码为逻辑/内存优化，不改视觉布局；不把 MisaTV 的内存测量套到本项目。全局预算不是整个进程内存的硬上限。
- 同毫秒合并的变更仅在 PC 合并层；本轮不修改 Android peer，不能宣称任意旧 Android 客户端也已采用相同冲突规则。
- 安全复核提醒的两条**残留风险**（非缺陷、方向保守）已知悉：dex 标记是大小写敏感的子串匹配，理论上存在误拒（拒绝方向安全）；`shellGuard` 之外的未知壳形态仍按 `translatableDex` 处理，转译后可能在加载期失败。

## 剩余验收门槛

- 独立读取剩余 child 的最终 diff；发现缺陷必须返工并重跑，不仅记录风险。
- 只读安全 reviewer 检查 HLS/JAR 反例，Lead 核验并处置。
- 所有任务冻结后运行综合风险回归、完整 analyze、契约校验；不在 peers 编辑时启动全量测试。
