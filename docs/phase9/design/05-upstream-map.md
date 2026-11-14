# 05 · 上游映射表（安卓屏幕 / 对话框 / 设置 / 模块 → 缺口编号）

- 作用：证明分析**没有漏掉**安卓的用户可见面（G9.3），并给出每一项的归属。
- 归属取值：`已对齐`、`N/A（基础设施/平台无关）`、`P0-x`、`P1-x`、`P2-x`、`P3-x`、`N1`–`N8`。
- 基准：`F:/Workspace/webtv2/webhtv` @ `77e2fbefdc`；清点口径见 `design/00` §4。
- 数量随基准演进；运行时以脚本清点结果为准。
- **基准漂移备注**：本地安卓仓库已推进到 `dcf9828cba61`（2026-10-23，merge beta）。相对写作基准，
  仅对话框目录新增 1 个文件（`DialogSafeArea.java`，见下方 §2 表）；其余三类清点（manifest 屏幕去重后
  43 个 activity 名、设置 Fragment 9 个、顶层模块 34 个）**无增减**。§2 已补该行，因此 G9.3 在
  `dcf9828cba61` 上同样全绿（实测 `activities=43 未映射=0，dialogs=85 未映射=0，fragments=9 未映射=0，modules=34 未映射=0`）。
  历史证据文件（`docs/phase9/evidence/`）按原样保留，不回填。

---

## 1. 屏幕（44 个 manifest 屏幕 + 播放宿主 PlaybackActivity，共 45）

| 屏幕 | 归属 | 说明 |
| --- | --- | --- |
| HomeActivity | 已对齐 | 首页/浏览（PC `browse_pages.dart`） |
| HomeActivityCurrent | N/A（别名） | 首页当前实现别名 |
| HomeActivityHistory | N/A（别名） | 首页历史实现别名 |
| VodActivity | 已对齐 | 点播浏览 |
| VideoActivity | 已对齐 | 播放页（PC `player_page.dart`） |
| PlaybackActivity | 已对齐 | 播放宿主/媒体会话 |
| SearchActivity | 已对齐 | 搜索（PC `search_page.dart`） |
| CollectActivity | 已对齐 | 收藏（PC `favorites`） |
| KeepActivity | 已对齐 | 追剧/收藏列表 |
| HistoryActivity | 已对齐 | 历史（PC `library_pages.dart`） |
| LiveActivity | 已对齐 + P0-8 | 直播；回看/设置/源级回退缺失 |
| FollowingActivity | P2-1 | 追番 |
| ViewingReportActivity | P2-2 | 观影报告 |
| TmdbDetailActivity | 已对齐 | TMDB 详情 |
| TmdbPersonActivity | 已对齐 | 人物页 |
| WebThemeDetailActivity | P3-1 | WebHome 主题详情 |
| CatWebActivity | P3-1 | WebHome 容器 |
| GameWebActivity | N6 | 游戏模式 |
| WebReaderActivity | P3-3 | 小说/漫画阅读器 |
| AudioActivity | P3-2 | 听书/音频模式 |
| CastActivity | P3-7 | 投屏 |
| FileActivity | P2-9 | 本地/网盘文件浏览 |
| FolderActivity | P2-9 | 文件夹浏览 |
| ScanActivity | P3-6 | 扫码配对（远程托管信任） |
| PushActivity | N4 | 接收推送/APK 推送 |
| PluginManagerActivity | N/A（新增，未纳入） | 插件管理页；安卓后续新增，PC 无对应物；未纳入 2026-11-12 复核 |
| CrashActivity | P2-8 | 崩溃页 |
| PlaybackRecoveryActivity | P2-8 | 崩溃后播放恢复 |
| AppBrandingActivity | N7 | 品牌设置 |
| SettingActivity | 已对齐 | 通用设置入口 |
| SettingAppearanceActivity | 已对齐 | 外观/主题 |
| SettingPersonalActivity | 已对齐 | 个人偏好（部分项见 P1/P2） |
| SettingPlayerActivity | P0-1、P0-2、P0-3、P0-4、P0-5、N2 | 播放设置 |
| SettingSubtitleActivity | P0-6 | 字幕设置 |
| SettingDanmakuActivity | P0-7 | 弹幕设置 |
| SettingAiActivity | P1-10 | AI 设置（集季已对齐，其余缺失） |
| SettingTmdbActivity | 已对齐 | TMDB 设置 |
| SettingAdActivity | P1-1 | 广告过滤设置 |
| SettingEnhanceActivity | P1-2、P1-6、P1-8、P1-9、P2-4、P2-5、P2-7、P3-4、P3-5、P3-6 | 增强功能聚合入口 |
| LabActivity | N5 | 实验室 |
| LabDetailActivity | N5 | 实验室详情 |
| LabOutputActivity | N5 | 实验室输出 |
| LabTerminalActivity | N5 | 实验室终端 |
| AssPrototypeActivity | N/A（原型） | EXO ASS 渲染原型宿主 |
| TmdbScrimHostActivity | N/A（主题宿主） | 主题 scrim 宿主 |

---

## 2. 对话框（86）

| 对话框 | 归属 | 说明 |
| --- | --- | --- |
| AboutDialog | 已对齐 | 关于/版本（PC 运行信息） |
| AdBlockLogFilterDialog | P1-1 | 广告过滤日志筛选 |
| AiAnalysisDialog | P1-10 | AI 分析 |
| AiConfigDialog | 已对齐 | AI 配置 |
| AiGroupRulePreviewSizing | P1-10 | AI 分组规则预览（辅助） |
| AiRecommendationInfoDialog | P1-10 | AI 推荐说明 |
| ApkPushProgressDialog | N4 | APK 推送进度 |
| AudioCommentDialog | P3-2 | 听书评论 |
| AudioSourceDialog | P3-2 | 听书源配置 |
| BackupProgressDialog | P2-7 | 备份进度 |
| BaseAlertDialog | N/A（基础设施） | 对话框基类 |
| BaseBottomSheetDialog | N/A（基础设施） | 底部弹层基类 |
| BaseSideSheetDialog | N/A（基础设施） | 侧边弹层基类 |
| CacheManagementDialog | P2-7 | 缓存管理（PC 仅清缓存目录） |
| ChoiceDialog | N/A（基础设施） | 单选对话框 |
| CodecCapabilityDialog | N2 | 解码能力探测 |
| ComicSourceDialog | P3-3 | 漫画源配置 |
| CspWarmupDialog | P1-6 | CSP 预热配置 |
| CustomCspDialog | P1-2 | 自定义站点注入 |
| DanmakuDialog | P0-7 | 弹幕选择 |
| DanmakuSearchDialog | P0-7 | 弹幕库搜索 |
| DanmakuSearchInputDialog | P0-7 | 弹幕搜索输入 |
| DanmakuSearchIntent | P0-7 | 弹幕搜索意图（辅助） |
| DanmakuSettingDialog | P0-7 | 弹幕显示设置 |
| DanmakuSettingPanel | P0-7 | 弹幕设置面板 |
| DebugLogDialog | 已对齐 | 调试日志 |
| DialogSafeArea | N/A（平台无关） | 弹窗可见区计算：安卓端用 WindowInsets 从全屏尺寸里扣掉状态栏/导航栏/手势条。**Flutter 侧不需要对应实现**——桌面窗口没有系统栏，且本仓库弹窗走 Material `Dialog`，安全区内边距由 `SafeArea`/`MediaQuery` 承担（现有 `SafeArea` 用于 `player_page.dart`、`tmdb_detail_view.dart`） |
| DiscMenuDialog | N2 | 蓝光菜单（MPV 专属） |
| DisplayDialog | 已对齐 | 屏显设置（Phase 8） |
| GitCloudDialog | P3-4 | 云备份 |
| GroupRuleDialog | P1-5 | 分组规则 |
| LightDialog | N/A（基础设施） | 轻量对话框构造器 |
| LoginStateLearnDialog | P2-5 | 登录态学习 |
| LoginStatePathDialog | P2-5 | 登录态路径 |
| LutDialog | P0-5 | LUT 选择 |
| ManagePageDialog | P3-5 | 管理页入口 |
| MpvConfigCreateDialog | N2 | MPV 配置档案 |
| MpvConfigDialog | N2 | MPV 配置档案 |
| MpvConfigEditorDialog | N2 | MPV 配置编辑 |
| MpvConfigHistoryDialog | N2 | MPV 配置历史 |
| MpvConfigRenameDialog | N2 | MPV 配置重命名 |
| MpvCustomButtonDialog | N2 | MPV 自定义按钮 |
| MultiThreadProxyDialog | P1-9 | 多线程代理 |
| NovelSourceDialog | P3-3 | 小说源配置 |
| OffsetDialog | P0-1、P0-6 | 音轨/字幕时间偏移 |
| OffsetPanel | P0-1、P0-6 | 偏移面板（辅助） |
| OneKeySyncDialog | P2-4 | 一键同步 |
| PanNetworkDiagnosticDialog | P1-8 | 网盘诊断 |
| PhotoViewerDialog | 已对齐 | 剧照查看 |
| PlaybackPerformanceDialog | N2 | 播放性能档位 |
| PlaybackPerformanceModal | N2 | 性能档位弹层 |
| PlaybackRemoteSyncDialog | P2-6 | 观影记录远端同步 |
| PluginPanelDialog | N/A（新增，未纳入） | 插件面板；安卓后续新增，PC 无对应物；未纳入 2026-11-12 复核 |
| PlaybackSpeedDialog | 已对齐 | 倍速 |
| PlaybackWebhookDialog | P2-6 | Webhook 上报 |
| PlayerButtonConfigDialog | 已对齐 | 按钮排版（Phase 8） |
| PlayerKernelDialog | N2 | 内核切换 |
| RemoteTrustDialog | P3-6 | 远程信任 |
| ShellProxyDialog | P1-9 | 出站代理规则 |
| ShortDramaSourceDialog | P2-3 | 短剧源 |
| SiteHealthDialog | P1-3 | 站点健康排序 |
| SiteHealthReportDialog | P1-3 | 健康报告 |
| SiteNameDialog | P1-5 | 站点名称规则 |
| SliderNumberDialog | N/A（基础设施） | 数值滑杆 |
| SpeedSettingDialog | 已对齐 | 默认倍速 |
| SubtitleDialog | 已对齐 | 字幕轨选择 |
| SubtitleManualSearchDialog | P0-6 | 字幕手动搜索 |
| SubtitleSettingsDialog | P0-6 | 字幕源/语言设置 |
| SyncPathDialog | P2-4 | 同步路径 |
| ThemeDialogLayout | N/A（基础设施） | 主题对话框布局 |
| ThemeImportDialog | P3-1 | 主题导入 |
| TitleDialog | P1-10 | 标题识别/修正 |
| TmdbPersonDialog | 已对齐 | 人物弹窗 |
| TmdbSearchDialog | 已对齐 | 手动匹配 |
| TmdbSourceDialog | 已对齐 | TMDB 源配置 |
| TmdbVideoPlayerDialog | 已对齐 | 相关视频播放 |
| TrackDialog | P0-1 | 轨道选择 |
| UpdateSettingsDialog | P2-7 | 更新设置 |
| VideoAspectModeDialog | 已对齐 | 画面比例 |
| VideoAspectRatioDialog | 已对齐 | 画面比例 |
| ViewingRecordSyncDialog | P2-6 | 观影记录同步 |
| ViewingReportRangeDialog | P2-2 | 报告时间范围 |
| WebHomeExtensionDebugDialog | P3-1 | 扩展调试台 |
| WebHomeExtensionDialog | P3-1 | 扩展管理 |
| WebHomeThemeDialog | P3-1 | WebHome 主题 |
| WebThemeImageViewer | P3-1 | 主题图片查看 |

---

## 3. 设置 Fragment（9）

| Fragment | 归属 | 说明 |
| --- | --- | --- |
| SettingFragment | 已对齐 | 通用设置（配置/直播/壁纸/DoH/隐身/缓存） |
| SettingAdFragment | P1-1 | 广告过滤 |
| SettingAiFragment | P1-10 | AI 能力（集季已对齐，其余缺失） |
| SettingDanmakuFragment | P0-7 | 弹幕 |
| SettingEnhanceFragment | P1-2、P1-6、P1-8、P1-9、P2-4、P2-5、P2-7、P3-4、P3-5、P3-6 | 增强功能 |
| SettingPersonalFragment | 已对齐 | 搜索线程/主题/备份/重置/品牌（部分项见 P2-7） |
| SettingPlayerFragment | P0-1、P0-2、P0-3、P0-4、P0-5、N2 | 播放设置 |
| SettingSubtitleFragment | P0-6 | 字幕源与语言 |
| SettingTmdbFragment | 已对齐 | TMDB |

---

## 4. 顶层模块（35）

| 模块 | 归属 | 说明 |
| --- | --- | --- |
| api | 已对齐 + P1-7 | 配置/加载器；直连 js&py 缺失 |
| bean | 已对齐 | 数据模型 |
| browse | 已对齐 | 浏览/分页 |
| cache | P2-7 | 缓存中心/清理策略 |
| content | P3-2、P3-3、N6 | 内容分发（音频/阅读/游戏） |
| db | 已对齐 | Room 数据库 |
| dlna | P3-7 | 投屏 |
| event | 已对齐 | 事件总线 |
| exception | 已对齐 | 异常分类 |
| following | P2-1 | 追番 |
| gitcloud | P3-4 | 云备份 |
| gson | N/A（基础设施） | JSON 适配 |
| history | 已对齐 | 历史展示策略 |
| impl | N/A（基础设施） | 回调接口 |
| lab | N5 | 实验室 |
| model | 已对齐 | UI 模型 |
| node | 已对齐 | 猫源 Node 运行时（PC `cat_runtime.dart`） |
| playback | 已对齐 + P2-6 | 播放 API/墓碑；远端同步缺失 |
| player | 已对齐 + P0-1、P0-4、P0-5 | 播放器；轨道/参数/LUT 缺失 |
| plugin | N/A（新增，未纳入） | 插件运行时；安卓后续新增，PC 无对应物；未纳入 2026-11-12 复核 |
| receiver | N4 | 系统广播 |
| remote | P3-6、P3-7 | 远程托管/遥控 |
| server | P3-5 | 本地 HTTP 服务/管理页 |
| service | 已对齐 + P1-10 | 后台服务；AI 扩展缺失 |
| setting | 已对齐 + P0/P1/P2 各项 | 设置存储（被多个缺口复用） |
| subtitle | P0-6 | 字幕匹配/源 |
| theme | 已对齐 | 主题系统 |
| title | P1-10 | 标题识别/学习 |
| tts | P3-2 | 语音合成 |
| ui | 已对齐 | 界面 |
| update | P2-7 | 应用更新 |
| utils | N/A（基础设施） | 工具 |
| viewing | P2-2 | 观影报告 |
| web | P3-1 | WebHome |
| widget | N/A（基础设施） | 自定义控件 |

---

## 5. 覆盖结论

| 类别 | 行数 | 已对齐 | 缺口 | 不迁移/基础设施 |
| --- | ---: | ---: | ---: | ---: |
| 屏幕 | 45 | 14 | 19 | 12 |
| 对话框 | 86 | 15 | 50 | 21 |
| 设置 Fragment | 9 | 3 | 6 | 0 |
| 顶层模块 | 35 | 11 | 17 | 7 |

- 缺口行数为「映射到至少一个 P/N 编号」的条目数；`LiveActivity` 因 P0-8 计入缺口，但它的主体能力已对齐。
- 统计随基准变化；本表的作用是**逐项有归属**，而不是数字本身。脚本 G9.3 以运行时清点结果校验「每个名字至少出现一次」。
- 同一能力会跨多个类别重复出现（例如 P0-8 同时命中 LiveActivity、Catchup 模块与 3 个对话框），这是预期行为。
- `PluginManagerActivity`、`PluginPanelDialog`、`plugin`（共 3 行）是安卓侧后续新增的能力，PC 无对应物且未纳入 2026-11-12 复核（见 `docs/phase9/parity-2026-11-12/`），暂计入「不迁移/基础设施」列；它们的归属要在做插件相关方案时重新判定，不能据此当作已对齐。
