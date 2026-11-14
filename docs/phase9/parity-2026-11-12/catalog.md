# 站点治理 / 点播详情 / TMDB — Android → PC 迁移对照

基线：Android webhtv@2d8b9977596b（tracked 干净）· PC webhtv-pc@b3c54d7e74f6（tracked 干净）
说明：上一轮已核实条目直接采信（brief 给定行号），本轮只补 配置导入/站点治理/详情多源/追番日历报告/短剧/运行时路由/TMDB 行。

| 能力 | 状态 | Android 证据 | PC 证据 | 缺失的用户动作 |
|---|---|---|---|---|
| 通用站源动作卡（链式输入/结果卡/消息） | 未迁移 | HomeActivity:1317 / TypeFragment:310 → ActionCardHelper:46/94 → spider.action | SiteRuntime/SidecarRuntime 无 action 入口；全仓 actionCard、runAction 零命中 | 完全无法运行站源动作（签到/解析/登录），无入口无结果卡 |
| 点播配置/接口地址失败切换 | 部分 | VodConfig.java:302 起 InterfaceFailoverPolicy：按 Config.urls/接口顺序自动或确认切下一份 | core/parse_failover.dart + advanced_settings_page.dart:288 只重试播放解析器 | 接口失效不会自动/确认切下一份，只能手动重新导入 |
| 站点顺序（手动排序/屏蔽） | 部分 | 站点列表手动排序 + 屏蔽 | core/site_order.dart:3-8 仅健康度搜索排序，注释明示无手动排序/屏蔽 | 不能拖动排序、不能屏蔽站点 |
| 注入站点插入位置与独立首页 | 部分 | 注入站点按位置插入 + 独立首页开关 | core/site_injection.dart 已识别落库；mergeInjectedSites:217-223 只同 key 替换/尾部追加 | 不能指定插入位置，不能单独控制注入站点首页 |
| 站点分组/分类规则 | 已迁移 | setting/GroupRuleTest.java（4 内置 + 自定义） | core/site_group_rules.dart：4 内置可单独开关 + 自定义正则，非法正则跳过 | 无 |
| 首页/分类浏览 + webHome | 已迁移 | HomeActivity 首页/分类；webHome 本地 index.html | ui/browse_pages.dart（首页/分类+详情）、ui/web_home_page.dart（WebView2 + fm/fongmiNative 桥） | 无（桥能力面未逐项比对，见未验证项） |
| 搜索相似度过滤 | 已迁移 | SearchResultFilter.java（阈值默认 30，0=不过滤） | core/search_result_filter.dart 头注释声明逐条移植；PC 不做 t2s，用 NFKC 归一化替代 | 无 |
| 换源（跨站并线） | 已迁移 | TmdbDetailActivity.java:12618 isChangeSourceCandidate；PlaybackActivity:599 自动换源回到起播点 | core/source_swap.dart（flag 唯一性/回站解析分离）+ ui/source_swap_sheet.dart | 无（自动换源策略未逐行比对） |
| 详情多源多集 | 已迁移 | TmdbDetailActivity 线路 chip + 选集 + 换线路/换源 | ui/player_episode_panel.dart、core/episode_range.dart、core/tmdb_season.dart | 无 |
| 追番 | 部分 | following/ 23 类：FollowingMetadataClient 元数据探测 + WorkManager 调度 | core/following.dart 头注释"对齐安卓 following/"，明示无 TMDB 元数据探测，更新判定用站点详情集数 | 更新检测缺 TMDB 元数据（首播/季集），桌面无系统级后台唤醒 |
| 追剧日历 | 已迁移 | FollowingActivity.java | core/following_calendar.dart（real/estimated 双源归日）+ ui/following_calendar_page.dart | 无（无 TMDB 排期时降级为 estimated） |
| 观影报告 | 已迁移 | viewing/ViewingReportGenerator.java（题材/地区/演员/导演偏好 + 跨文化探索者徽章） | core/viewing_report.dart（四维榜单/探索者/各维覆盖率/电影剧集未知/站源分布/7×24 热力图/上一周期对比）+ core/viewing_metadata.dart & services/viewing_report_metadata.dart（schema 11 纯加法式快照，源域隔离，TMDB 本地详情仅补缺、零请求）+ ui/viewing_report_page.dart；[2026-11-14 验证证据](../evidence/10-viewing-report-v2.md) | 无（旧记录缺元数据时如实显示未知与覆盖率；打开报告不联网、不自动调 AI） |
| 短剧 | 部分 | bean/ShortDramaConfig.java:15 `[短]`/`短剧` 默认规则 + enabledSites/disabledSites/configured + isSiteEnabled | state/app_state.dart:1283 仅 `labels.contains('[短]')` 设 isShortDrama（只影响推荐）；无启停名单与规则编辑 | 不能配置短剧站点规则或启停名单 |
| 配置导入/多配置切换/坏配置不覆盖 | 已迁移 | VodConfig 多配置 + 配置记录 | config_loader.dart:8「解析失败或 msg 非空时不得覆盖最后一个可用配置」；config_pages.dart:1051「失败则保留原配置」；app_state.dart:3747 activateConfigRecord、:3642 各条目独立记录 | 无 |
| 配置仓库（urls）条目 | 部分 | 按 urls 顺序回退到下一份 | config_loader.dart:402+ ImportedConfig.isRepository / expandRepository：越界回退第一项，失败抛错不覆盖，但条目由用户手选 | 条目失败不会自动回退下一项，需手动选 |
| JS/Py/JVM 站源运行时分派 | 已迁移 | in-process：quickjs / chaquo / nodejs 随包捆绑 | spider_router.dart:270 classifySite：type=3 → CAT HTTP / sidecar(manifest runtime js|py|jvm) / CspJvmBinding；运行时缺失如实报不可用 | 需先装 Python/Node/Java 运行时，未装则站点不可用 |
| CSP jar + DEX（Android 站源） | 部分 | 直接加载设备 jar（含 dex） | csp_jar_probe.dart:14-19 按配置 URL 取 jar + 静态检测 + 原子落盘，可转译 dex 注入 dex_translate.dart 做导入期转译；含原生库/不可转译 dex 拒装只写 probe.json | 含原生库或不可转译的 dex 站源无法使用（平台专属边界，非缺 UI） |
| TMDB 内嵌 payload（Vod.tmdb） | 已迁移 | TmdbDetailActivity:2647-2686 直接消费 Vod.tmdb，无 API 也先显示 | protocol.dart:1006 类型化 getter；core/tmdb_source_payload.dart:41/169/190 验证/缺口规划/来源优先合并；tmdb_state.dart:475/937 首屏内嵌渲染，季集/视频/单集弹窗复用，完整组零请求；[2026-11-13 验证证据](../evidence/09-tmdb-source-payload-and-key.md) | 无（无凭据可渲染有效内嵌数据；身份型 payload 不伪装完整详情，显式禁用仍遵守） |
| 配置根字段 tmdb_api_key | 已迁移 | VodConfig:190-193 读取清理 + TmdbSourceCredentialIngress:14 按配置接收凭据 | tmdb_credential_ingress.dart:27 → config_parser.dart:49 提取并剥离；app_state.dart:725/731 用户/有效配置分离，当前配置进程内存兜底；本地/Cat/桥接导入刷新、失败/迟到/切换/删除/换库隔离；[2026-11-13 验证证据](../evidence/09-tmdb-source-payload-and-key.md) | 无（用户凭据优先；订阅 key 不持久化/导出，重启或切换作用域后需重新导入/刷新获取） |

## 2026-11-14 补核

「观影报告」由部分迁移更新为已迁移：新增本地作品元数据链路（schema 11，纯加法式）、四维偏好与跨文化探索者徽章，并额外提供站源分布、7×24 热力图、上一周期对比。实现与验证证据见 [10-viewing-report-v2](../evidence/10-viewing-report-v2.md)。

## 2026-11-13 补核

本轮仅更新上述两项 TMDB 能力；已实现并通过确定性 fixture 的协议、状态、配置安全与 Before/After 验证。最后独立复跑凭据 24/24、合并回归 359/359；全仓分析 0 error / 0 warning，保留 95 条既有 info。未做真实 TMDB 联网、全量测试或 Windows 构建；其余行与下述未验证项仍属于原基线。

## 原基线检索范围 / 模式
- 只读。Android：/home/maple/Workspace/webhtv/dev1/webhtv（app/src/main/java 等，排除 .scratch-goal/）。
- PC：/home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3（apps/desktop-flutter/lib 的 core/ services/ state/ ui/）。
- 模式：`grep -rn` 定点检索 + `sed -n` 读关键片段；未做全仓通读，未跑任何测试/构建。

## 未验证项
- 未运行应用、未联网、未实机验证；以上状态均由源码/注释与既有证据推定。
- UI 层未逐页比对：webHome 桥能力面、自动换源策略、追剧日历降级观感、详情页多集排序。
- 短剧行只按站点名标签口径判定，未核 Android 短剧专属播放/UI 链路是否还有 PC 缺失项。
