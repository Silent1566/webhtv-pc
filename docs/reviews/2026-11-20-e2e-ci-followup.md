# e2e / CI 后续修复记录（2026-11-20）

## 范围与基线

- 前序评估：[项目评估与迭代记录](2026-11-20-project-evaluation.md)。本文件追加后续事实，不改写历史快照。
- PR #82 已合并（`77f5169`）；本补丁独立基于后续 `beta @ b6928bf`，包含 PR #83 的元数据/详情页变更后再验收。
- 本地工作分支：`dev-e2e-desktop-lifecycle`。发布前不修改已合并的 PR，不自动合并后续 PR。

## 已证实的前序 CI 结果

运行 [44673421072](https://github.com/Silent1566/webhtv-pc/actions/runs/44673421072)，head `350a34f`：

| Job | 结果 | 证据边界 |
| --- | --- | --- |
| Linux x64 | success | 分析、单测、构建、打包、烟测均完成 |
| Windows x64 | success | runner exit 0、JSON `done.success=true`、0 error 事件、lcov 640624 字节 |
| 试用 e2e | failure | 构建/fixture 服务成功，剩余错误已进入用例与真实生命周期/桌面环境 |

更早运行 `44664887168` 的 Windows 曾在通过汇总之后退出 1；本轮没有复现。GitHub reporter 的通过汇总不足以证明底层 runner 成功，coverage 收尾也可能返回非零。诊断旁路已保留，但不能把一次成功称为该偶发问题的根因修复。

## 本次修复与证据

### 1. 保留真实 root 与启动契约

首版测试隔离将 `WebHtvApp` 换成已 bootstrap 的 `AppShell`，独立审查判为 P1：未创建 Splash 却断言其不存在，是空洞通过。该版本未提交。

返工后：`WebHtvApp` 新增可选 `stateFactory`，仅在 root 的 `initState` 调用；默认仍创建原 `AppState()`。root 继续拥有 bootstrap、完整生产根布局和 dispose。首条与全屏 e2e 使用未 bootstrap 的隔离 state，并通过 gate 验证真实 Splash 出现、随后 AppShell 出现、bootstrap 恰一次。

helper 记录所有权：状态交付 root 后不由环境重复 dispose；针对用例验证 root 卸载一次、环境清理后仍只 dispose 一次。原生 e2e 没有启用 unit-only 的受控假 bootstrap。

### 2. 三处真实生产生命周期缺陷

| 缺陷 | 修改 | 红灯 / 回归 |
| --- | --- | --- |
| root 卸载后全局 toast 保留旧状态回调，下一 ToastHost 会话触发 after-dispose | root `dispose()` 在状态仍存活时 `dismissAllToasts()`，再结束 session/dispose state | 真实 root 卸载后重新挂 ToastHost，推进 31 秒；旧实现复现 `clearNotice → ToastCenter._remove → _ToastCardState._beginExit` |
| `_checkBoundary()` 的文件读取返回后更新已卸载页面 | await 后检查 `mounted` | 控制 pending `File.exists()`，卸载后完成读取，旧实现 `setState after dispose` |
| `_acceptBoundary()` 的文件写入返回后更新已卸载页面 | write/catch 后检查 `mounted` | 控制 pending 写入，卸载后完成，旧实现同样报错；存活页面写失败时的当次放行语义不变 |

没有新增全局异常处理器、跳过用例或清空框架异常来换取通过。

### 3. 测试数据、网络与旧断言

- 每个 e2e 用例都有独立 config/data/cache/log 目录；不再使用宿主用户已有资料。
- optional metadata 通过现有偏好开关关闭；豆瓣推荐仅通过原有 `doubanClient` 接缝提供合法空结果。站源 loopback HTTP、SQLite 和原生播放器未替换。新增用例使用真实 `HttpServer` 验证站源搜索仍经过回环网络。
- runtime 断言改为真实 availability 契约 `Node Spider (tvbox-js-v1)`、`Phase 3` 与未注册原因，而非错误的大写 `JS` 子串。
- 详情线路位于惰性 ListView：先滚动，再验证名称、可选择/选中状态、首集可命中且启用。
- 首帧、真实 `Player` / `Video`、seek、历史、12 秒续播、数据库重建与全屏 `entered && restored` 断言保留。
- 外置 state 的测试清理先执行活跃通知回调、卸载页面、再 dispose；`pythonEnvironmentIdle` 只代表 Python/sidecar 屏障，不是全部异步资源屏障。

### 4. Xvfb 与 EWMH 窗口管理器

`window_manager` Linux 插件通过 GTK 发全屏请求并读取 GDK 状态。显式 `GDK_BACKEND=x11` 的独立 Xvfb 探针复现：没有 WM 时 FULLSCREEN client message 已发送但状态仍 False；临时 EWMH handler 响应后状态变 True，退出后回 False。最初误连宿主 Wayland 的探针结果已撤回，不能作为反证。

仅 e2e job 额外安装 Openbox，在同一 `xvfb-run` DISPLAY 启动；有界探测 root WM 标识、自引用及全屏支持后才运行原 Flutter 命令。退出/终止信号时 trap 回收 WM，保留测试真实退出码。既有 apt 网络超时、重试、5 分钟步骤预算和 job 总时限不变。

原 `fullscreen-restored=true` 不能单独证明恢复：未进入全屏时该值也会为 true。原断言仍要求进入与恢复同时成功。

## 审核与本地验证

- 独立代码复审：run1 **request changes**（P1 启动契约被绕过）；run2 **accept**，P1 关闭，未发现剩余 must-fix。
- `350a34f + 稳定 run2 补丁`：Lead 独立执行 9 个相关测试文件，**104 条通过**，全包 `flutter analyze --no-pub --fatal-infos` 0 issue。
- WM shell / apt / Windows 诊断 / 既有 workflow 契约：Lead 独立执行 **32 条通过**，覆盖同 DISPLAY、ready 失败不启动 Flutter、测试退出码 37 不变、SIGTERM 退出 143、WM 回收。
- 最新 `beta @ b6928bf + 补丁`：首轮组合分析发现 PR #83 的 `external_metadata_service_test.dart` 原有多行 if 缺花括号；已只补该处花括号，不改断言或分析规则。重跑分析通过；随后完整测试在 1800 秒预算到期时退出 **124**，最后进度 **4866 passed / 29 skipped / 5 failures**，因此本地全量验收尚未通过。
- 5 个失败分布：设置持久化契约 2 条（UI 多出 `metaPipelineVersion: 1`、只读旧设置被重写），本地源搜索刷新 1 条，本地源启停/握手 2 条（30 秒 timeout、临时目录 release 文件已不存在）。终止时 Flutter listener 删除报错仅记录为收尾现象，不能据此定责。已安排串行定向复现与两路只读根因分析，不扩大预算、不加 skip，也不拿旧基线的成功替代组合树验收。
- 完整 Python 契约套件：`python3 -m unittest discover -s tests -p 'test_*.py'` → **Ran 123 tests, OK (skipped=1)**，exit 0。

## 仍待远端验收

本机缺少 pkg-config / GTK dev 头，也未安装 Openbox；没有声称原生 e2e 已通过。本地 shell harness 不等价于真实 Openbox 的全屏状态，widget/unit 用例也不替代真实媒体首帧/seek。后续独立 PR 与 GitHub CI 负责验证完整桌面闭环。

若隔离与正确卸载后仍有 SocketException 或 after-dispose，必须按真实日志重新定位，不能继续吞异常或弱化断言。
## 组合 `beta` 验收中发现并修掉的问题（同日）

把补丁带到 `beta @ b6928bf` 后跑全量，另暴露两组失败。它们不是“机器慢”，而是真实契约/生命周期问题：

### 1. 元数据迁移把「没有规则」当成「旧规则」写盘

- 现象：`phase9_external_player_catalog_persistence_test.dart` 的“旧设置只读不写”失败——文件里只有 `externalPlayerPath`，`load()` 却重写了它并注入 `metaPipeline` + `metaPipelineVersion: 1`。
- 根因：`ui_preferences_store.dart` 只凭“版本缺失/`<1`”就置 `migrateMetaPipeline`，没有检查是否真的存在需要补 `source` 的旧规则；`MetaPipeline.defaults` 本身已含末位 source，`withSourceFallbackAdded()` 此时不改变规则。
- 修法：两个入口（`load` 与同步迁移 mutator）都用 `withSourceFallbackAdded()` 的**归一化结果 `identical`** 判定是否真的需要迁移；无实际变化不写盘、不物化默认规则或版本。普通显式保存仍写版本 1。
- 测试：`crawler_meta_resolution_test` 新增 11 个真实文件 no-op 场景（无 UI、无规则、空/非法规则、仅未知字段…）断言两次 load 后**文件原字节不变**；`phase2_last_site_test` 的精确期望同步为含 `metaPipelineVersion: 1`（普通保存确实会写它）；`tmdb`/`sync` 保留断言未动；`phase9` 的字节级断言**一行未改**。
- 证据：先红 `+1 -10`，修后 17/17；设置相关 9 文件 77 passed；全包 analysis 0。

### 2. Python 环境准备在 `dispose()` 之后继续写盘

- 现象：`local_source_enable_test` 的“停用再启用”在清理处 30 秒超时；遗留临时目录日志显示 `bundle.json`/`active.json` 比 dispose 相关日志晚约 **38 秒**落盘。
- 根因：`Isolate.run` 的环境准备没有取消通道，`dispose()` 只置位并关 sidecar，准备任务继续解包/校验/提交；`pythonEnvironmentIdle` 因此等不到真实结束。
- 修法（协作式取消，非强杀）：worker 接收取消端口；`python_bundle_store` 在解包循环、摘要分块、probe 之后/提交之前检查 checkpoint；未提交的 stage 由原 `finally` 回滚；`python_environment` 负责取消通知与子进程收束，`idle` 只等真实 worker/子进程结束。
- 子进程收束：`cancel()` 先 SIGTERM，2 秒有界升级 SIGKILL；最终**无超时等待 `exitCode`**——超时不能替代“进程已退出”这一证据（本轮复审打回过“超时即放弃等待”的写法）。
- 关闭后的契约：`dispose` 之后不再接受 `repair/custom/default`（返回 false）；在途的一轮以取消结束、不发布状态。`python_environment_test` 的原断言据此更新（旧断言要求 dispose 后仍成功，与“不得在关闭后写盘/发布”冲突）。
- 另一处遗漏：`_invalidateLocalSites` 在 dispose 后仍直接 `notifyListeners()`（迭代 0 的 `_notifyIfAlive()` 没覆盖到），已改为判活出口。

### 3. 测试夹具的两处假绿/假红

- 页面测试用真实 `AppState`（未注入 Python 替身）挂载，widget 测试的 fake-async 区无法推进真实 `Isolate`，teardown 的“idle 必须完成”只能碰运气；改为注入仓库既有的 `LocalSourceTestPythonEnvironment`，取消语义仍由 `local_source_enable_test` 用真实夹具覆盖。
- 该替身在 `probeDelay == Duration.zero` 时不再排 `Future.delayed`（零延迟也创建真实 Timer，fake-async 里不会被 `pump()` 推进），只走微任务。
- 搜索用例的根因是**测试路径随机**：`local_sources_page` 的匹配把绝对路径纳入 term 匹配，临时目录名恰好含 `js` 时 `search js` 会匹配全部候选。改为受控目录名，并另加一条“祖先路径同时含 search/js 时四项全匹配”的**生产契约**用例——生产过滤规则未改。

### 4. 本轮验证口径

- `flutter analyze --no-pub --fatal-infos`：**0 issue**。
- 合流 9 文件（设置 + 生命周期 + 页面 + 站点）：**161 passed / 13 skipped / 0 failed**。
- 取消实测：probe **49ms**、解包 **7ms 且 entries=0**、提交前取消 **250ms 且 entries=0**；正常 prepare 仍完成校验并原子提交。
- 全量 `flutter test` 曾在旧修复前 1800 秒超时（`+4866 -5`），那些失败即上面两组；修复后最终全量结果见下。

### 5. 仍未闭合的边界（不要当成已解决）

- **跨 isolate 提交窗口**：最后一次 checkpoint 通过后到 `_atomicJson` 是同步的、没有 await。`close` 若恰好在这个窗口之后到达，消息只能排队，`active.json` 仍可能被提交；主端只保证不再发布 `status`。取消的线性化边界是“进入同步 commit 之前”。
- **注入钩子不可取消**：`injectedProbe` / `launcherRunner` 是 trusted/finite 测试钩子，回调本身不响应取消；生产路径只在回调返回后的 checkpoint 检查。
- **timeout 分支未显式 join stdout/stderr**：正常路径会 join，取消/超时路径只等 `exitCode`，不宣称所有输出流已收束。
- **原生 e2e 未验证**：本机缺 GTK dev / Openbox，真实全屏与桌面闭环仍需 CI。
## 持久化分片验收（后续，不与旧全量混算）

旧全量在 `history_source_label_ui` 收尾出现 stream sink 错误后任务记录丢失，退出码无法恢复，按未完成处理。该文件与相邻 `reader_ai_protocol` 单跑 16 条全绿；不能据此证明旧中断原因。

改用 systemd 用户服务 + 本地完成收集任务：每片 stdout、JSON 事件、退出码、源补丁快照与开始/结束时间均落在 `/var/tmp/webhtv-full-gate.3RD3MD`，不再只依赖 DSH 任务列表。四片串行，单片内部并发 2，整次预算 2400 秒。

首轮收据：

| 分片 | 时间 | 退出码 / JSON |
| --- | --- | --- |
| 0 | 17:51:24–17:59:45 | 0，`done.success=true`，0 error |
| 1 | 17:59:45–18:13:09 | 0，`done.success=true`，0 error |
| 2 | 18:13:09–18:26:12 | 1，`done.success=false`，1 error |
| 3 | 未执行 | 失败即停 |

第 2 片唯一失败是 `phase7_pull_endpoint_test` 的纯 `limit` 解析用例：未创建服务器，却由混合 group 的 teardown 无条件访问 `late server`，抛 `LateInitializationError`。单跑该纯用例稳定 exit 1；将四个真实 HTTP 用例的服务器改为本地变量、创建后登记 `addTearDown(server.stop)`，所有端点断言保留，整文件 **43 条通过**，全包分析 **0 issue**。

补跑只执行第 2、3 片，另立收据目录 `/var/tmp/webhtv-full-gate-resume.jOtBF3`，该轮合计预算仍为 2400 秒而不是每片 2400。初轮失败记录保留，不覆盖成成功。已对照初轮源补丁快照：除该端点测试与测试自动生成的 PNG 外，没有其它 tracked 源码变化；补跑完成后还须检查四片覆盖、最终 JSON 和退出码，才能报告完整套件验收。
## 最后一片揭示的 Python 宿主并发回收缺陷

第 2 片修正测试清理后成功（18:32:37–18:51:17，exit 0、JSON success）。第 3 片完成但 exit 1，唯一失败是 `sidecar_idle_recycle_test` 的“并发请求中一次超时不误杀进程”：slow 超时后 Python 的 1 秒宽限到期，宿主直接 `os._exit(4)`，fast 健康请求收到 `SPIDER_CRASHED`。这是实际宿主行为冲突，不能用缩短 Dart 等待或加长 grace 规避。

修复只涉及 `sidecars/spider-host-python/webhtv_ipc.py` 与 `selftest_deadline.py`，Dart 的原有等待、断言和 grace=1.0 都未改变：

- 只在没有健康在途调用时回收挂死进程；排队的健康请求、已认领但未写完响应的请求同样受保护。
- 回复超时帧后重锁复核候选仍在，封闭 snapshot 与接收新请求之间的退出窗口；移除调用后通知监视线程，成熟 grace 不参与忙轮询。
- run1 自测 86 项和真实 IPC 曾通过，但独立审查判 **request_changes**，发现两处 P1：无 deadline 控制调用排入已挂死业务池，会永久挡住回收；拒绝回复在 write/flush 之前 pop，会被进程退出抢走错误帧。旧 gate 因此由 Lead 主动停止并明确记录 **143**，不计成功。
- run2：heartbeat 在读循环本地应答；其它无 deadline 的控制调用只在原子预留到空闲 worker 时执行，否则完整返回既有 `SPIDER_RESOURCE_LIMIT`，不无限排队、不伪装成功；空闲时仍调用原 initialize/destroy/hold/shutdown handlers。
- 拒绝调用直至完整 write/flush 返回才在 finally 中 pop + notify；写入异常仍向上传播，未吞掉失败。
- Lead 独立复跑 **155 项自测全部通过、sidecar 契约 4/4**；真实子进程探针证实控制应答/超时帧完整送达后才 exit 4，默认宽限不变。锁顺序与两条 P1 的最终独立复审正在进行；9 文件真实 IPC 消费者回归正在本地串行运行，原生 e2e 仍未验。

前述本机默认发现的 suite 为 447 个；另四个 `audio_ai_*_test.dart` 明确标注 `@TestOn('windows')`，不把 Linux gate 当作 Windows 原生音频验证。

## 本地四片验收最终收据

| 分片 | 最终通过 / 跳过 | 错误事件 | JSON / 退出码 |
| --- | --- | --- | --- |
| 0 | 1671 / 7 | 0 | success=true / 0 |
| 1 | 1696 / 12 | 0 | success=true / 0 |
| 2（修清理后） | 1545 / 12 | 0 | success=true / 0 |
| 3（宿主 run2 修复后） | 1584 / 6 | 0 | success=true / 0 |
| 合计 | **6496 / 37** | **0** | 四片均成功 |

第 3 片最终完成时间为 20:21:36（systemd exit 0）。在发布前已核对与该片源码补丁快照完全一致，没有边跑边改。涉及 Python 宿主变化的额外 9 文件消费者回归 **114 passed / 2 skipped**、全包分析 0 issue；其测试夹具明确使用真实系统 Python 而非顺带安装发行版离线包，结果/启停断言保留。

这是 base `b6928bf + 本补丁` 的本地 Linux 套件结果，不是 Windows 音频原生测试或 `integration_test/` 的通过记录。新发现 `beta` 已前进到 `636c3bb`（PR #84/#85 首页元数据与启动通知布局），发布前须同步该快照并对交集另行回归，不把旧基线通过冒充新合并树通过。
## 发布前同步最新 beta（固定到 `636c3bb`）

四片收据通过后先按 root、桌面环境、设置迁移、Python 准备、宿主回收、测试资源清理分别提交，再显式合并 `636c3bb`，不追着移动中的 beta 无限重跑。新上游主要是首页追剧元数据与启动通知布局；不是四片原基线结果。

发生的唯一文本冲突为 `phase2_last_site_test`：上游改成 `containsPair`，本分支保留精确 Map（站点键 + 版本键），保留 `tmdb/sync` 不受污染的断言。

另有无文本冲突的语义交集：上游把旧外部播放器配置的只读检查放到 `load()` 之后，允许先发生元数据迁移。但该 fixture 根本没有元数据规则，而本分支已修复无规则/no-op `load` 不应写盘。因此保留**load 之前原字节快照**，新增立即校验 load 字节不变，后续目录合并/重载语义仍验证。不能因为两个分支都改过同一失败用例，就把精确断言降成宽松容忍。

合并后的接缝验证单独覆盖 root、启动通知、首页追剧元数据、metadata service/持久化、窗口/图片 Header/上次配置；Lead 独立运行 **192 条全部通过**（45 秒），全包 `flutter analyze --no-pub --fatal-infos` **0 issue**。本地 Linux 四片 6496/37 是之前固定基线的完整套件结果，后续接缝测试不会被表述为新基线“又完整全量一次”。
