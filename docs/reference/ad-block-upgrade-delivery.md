# 去广告升级交付记录（2026-11-26）

- 状态：已交付（A+B+C+D），局部限制见 §5
- 用户决策（本轮）：范围 = 清洗内核 + 统计日志 + 本地规则库 + 默认关闭启发式；**不含** AI 接口规则学习；
  规则只做本地（配置内联 + 自有规则库），不做远程订阅、不随包内置广告主机；界面落点 = 设置 → 内容与站点
  新增「去广告」二级页，原总开关保留在主列表。
- 对照基准：安卓 `webhtv/dev5` 的 `utils/HlsManifestCleaner.java`（规则清洗）、`AdBlockStats*`、
  `UserAdRuleStore`、`HlsAdblockNotice`；启发式来源与许可核对见 `docs/reference/hls-ad-block-upgrade.md`。

## 1. 清洗内核（Lead）

`lib/core/ad_rules.dart` 由「点播媒体清单的一级规则清洗」扩为与安卓同口径的安全清洗器：

| 能力 | 取值 | 依据 |
| --- | --- | --- |
| 删除比例上限 | 单次 > **35%** 即整次回退 | 安卓 `MAX_REMOVAL_RATIO=0.35` |
| 删除时长上限 | 单次 > **90 秒** 即回退 | 安卓 `MAX_REMOVED_DURATION_SEC=90` |
| 清单体积/行数上限 | 2MB / 20000 行 | 安卓同值 |
| 结构回退 | BYTERANGE、`EXT-X-SKIP/PART/PRELOAD-HINT` | 删一段要重算全部兄弟字段 |
| 直播窗口 | 允许删窗口头部，递增 `MEDIA-SEQUENCE`/`DISCONTINUITY-SEQUENCE`（BigInt，无 32 位截断） | RFC 8216 §4.3.3.2 |
| 加密保护 | 无显式 IV 的 KEY 一律回退；广告分片自带 `EXT-X-MAP` 回退 | RFC 8216 §5.2、§4.3.2.5 |
| 规则合法性 | 正则 ≤32 条/≤512 字符、拒病态回溯；时长区间必须成对且有限；`minimumSignals` 必须是正整数 | 安卓 `MAX_REGEX_*` + 本轮加固 |
| 统计口径 | `ruleCounts` / `removedDurationSec` / `removed`（域名、规则、起始秒、时长） | 统计页与会话提示共用 |

诊断日志新增 `adBlockRollback=<原因>`、`heuristic` 标记与 **`adBlockLevels=<级别>=<段数>,…`**
（启发式五级各自删了几段，按次数降序）；回退时原文与计数同时归零。
各级命中数同时进统计的 `ruleCounts`（键就是级别名），统计页「按规则 Top」因此能看出是哪一级在干活。

两条清洗路径对 `#EXT-X-DISCONTINUITY` 的口径**一致**：都跨过被删分片保留边界标记；
启发式另外把「删除后相邻的重复标记」收成一个（`_collapseDiscontinuities`），语义等价。
实测日志里 `disc 124→119` 就是 5 处这样合并出来的，不是丢标记——排查时别把它当缺陷。

## 2. 启发式清洗（默认关闭）

`lib/core/m3u8_purify.dart`：五级链（少数派地址 → 通用缝合点 → 广告标记 → 小数精度/帧率组 → 短不连续组），
只处理已完结的媒体清单，三道安全阀（单级 30% 作废、累计 50% 整体回退、洗后必须仍可播放）。
与规则清洗**串联**：规则一条都没命中才兜底，且要求用户在设置里显式开启（`adBlock.heuristic`，默认 false）。
真实两轮链无法收敛时整体回退原文，不返回半收敛结果。

## 3. 统计、日志与会话提示

- `lib/core/ad_block_stats.dart` + `lib/services/ad_block_stats_store.dart` + `ad_block_stats_service.dart`：
  新记录在最前、**保留 1000 条**、终身计数不被滚动裁剪；落盘版本 2（终身累计时长单独存），
  写失败回滚内存并原样展示 store 消息；`abandoned`/`!changed` 一条不记。
- `lib/ui/ad_block_stats_page.dart`：摘要 + 站点/规则 Top + 五列可筛选日志 + 清空（二次确认）。
- 播放器屏显附加列新增「去广告 已拦 N 段 · M 秒（启发式）」；`AppState.adBlockSummary` 按会话指纹取。
- **拦截提示**：文案对齐安卓 `HlsAdblockNotice`——`已跳过 N 个广告片段`，能算出时长时追加
  `，总广告时长 X`（先四舍五入到 0.1 秒；<60 秒写「X.Y 秒」，满 60 秒写「N 分钟」/「N 分 M 秒」）；
  呈现复用仓库既有 `showToast` 通道（`ui/app.dart` 的 notice→toast 投影），不新造浮层。
  去重口径与安卓不同并有意如此：安卓按「同一清单 URL + 30 秒」窗口去重，PC 改成**每个播放会话只提示一次**
  ——拖动/重取清单/换码率会反复命中同一份清单，按窗口去重仍会连续弹；换集/换线路会新建会话，
  届时重新提示（`seq` 递增，同文案的两集各弹一次）。安全回退不提示。
- **归因链路**：`PlaybackRequest.adBlockLabelsFor` 从「本次播的地址 + 线路 flag」纯函数式解析出
  片名/线路名/分集名（对不上就留空，绝不套用别的集名）；播放器在**解析成功后**登记
  （`AppState.noteAdBlockPlayback`），代理记账时读取；每次撤销代理会话都会清零，
  所以换集/换线路不会继承上一集的标签。统计页与屏显因此能看到「哪一集被拦了几段」。

## 4. 本地规则库与界面

- `lib/core/ad_rule_library.dart`：`ad_rule_library.json`（用户数据目录），导入/导出/编辑/启停；
  损坏或未知版本的库**拒绝写入**并锁定操作，用户须显式「备份原文件并重新开始」；
  同 id 导入保留本地开关与来源；host 去重走 `AdRuleSet.fromConfig` 的规范化。
- `resolveEffectiveRules`：总开关关闭→空集；否则配置内联 + 启用条目合并去重。
- `lib/ui/ad_block_page.dart`（设置 → 内容与站点 → 去广告）：总开关、启发式开关（带误删说明）、
  本地规则库入口、拦截统计入口；主列表保留原开关行作为总开关。

## 5. 验证与已知限制

- `dart analyze lib test`：**No issues found**。
- 去广告相关套件 **177 条全绿**（清洗 10 + 回归 19 + 规则 20 + 启发式 39 + 统计 26 + 规则库 32 +
  代理端到端 4 + 页面 3 + 归因 6 + 偏好 18）；设置/代理/备份/屏显回归 **253 条全绿**；
  播放器集成（排队/历史线路/画质）**86 条全绿**。
- After 截图：`.impeccable/review/ad-block-page-after.png`（1280×800 暗色）。**测试环境无中文字体**，
  截图中文字渲染为方框；布局、层级与开关状态可判，文案不可判——文案由页面测试断言兜住。
- 归因边界：站点来自当前代理会话；片名/线路/分集由**播放器页那次解析**提供。
  外部播放器、目录队列、跨源续播这些路径没有线路表可查，按设计留空（页面渲染「—」），不伪造。
- **已纳入备份（2026-11-26 第二轮）**：`ad_rule_library.json`/`ad_block_stats.json` 现在随备份打包
  （包内名 `ad-rule-library.json`/`ad-block-stats.json`），恢复时写回并**重建内存视图**，
  备份回滚副本也覆盖它们；「重置本地数据」会一并删除。旧备份（没有这两个条目）恢复时不动本地文件，
  向后兼容。
- 未做：AI 接口规则学习（E）；远程规则包订阅；随包内置广告主机。

## 6. 附带修复：站点给的「本机 /proxy?do=…」地址（2026-11-26）

站点播放数据里的弹幕源常写成 Android 那套本机中转：`http://127.0.0.1:0/proxy?do=danmu&…`
（端口是未绑定时的默认值 0，Android 写死 9978 的同一种写法）。旧 `SpiderProxySession.scopeUrl`
要求 authority 与 JVM 数据面**完全相等**，于是这类地址被当成外站地址放行，请求打到不存在的端口，
报成「网络不可达或 DNS 失败」。

现在的接管判据是两类并集（`services/spider_proxy_session.dart: scopeLocalProxyUrl`）：

1. 本会话数据面的精确地址（既有契约不变）；
2. 回环主机 + `/proxy` + 带 `do=` 参数（安卓在 `/proxy` 上按 `do` 分发的形态）。

无 `do` 的本机 `/proxy` 仍不劫持（可能是用户自己的本地服务）；非回环地址一律不动。
命中后地址被映射成 `<jvm base>/s/<token>/proxy?do=…`，由 JVM 宿主转给站源的
`proxy(Map)`（`sidecars/spider-host-jvm/.../SpiderProxyHttpServer.java:248`），
与安卓 `server/process/Proxy.java` → `BaseLoader.get().proxy(params)` 同一条链路。
**前提**：该站点跑在 JVM 宿主且已授权 `localProxy`+`proxy` 能力；站源自身要真的实现
`do=danmu`，否则仍会失败，但会是一个结构性错误而不是"网络不可达"。
