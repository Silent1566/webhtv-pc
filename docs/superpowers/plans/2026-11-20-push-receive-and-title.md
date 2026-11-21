# 2026-11-20 · 推送接收 + 剧名匹配（PC）

## 目标

对齐安卓 `PushActivity`：手机/安卓 App 经局域网把播放地址推给 PC，PC 立即起播；
在此之上新增**剧名填写**，让推送内容有真实片名并参与元数据匹配。

顶栏「打开本地文件」按钮移除，文件选择能力并入「推送…」对话框（用户 2026-11-20 指示）。

## 决策（用户已确认）

| 编号 | 决策 |
| --- | --- |
| D1 | 只做 PC 接收端（`/action?do=push` + `/` 推送页）与 PC 内「推送…」输入；不做 PC→安卓发送 |
| D2 | 复用现有局域网服务（同一端口/实现）；「接收推送」是独立子开关，默认关闭；总开关默认关闭不变 |
| D3 | 剧名进标题与历史 + 一次自动 TMDB 匹配（先过推送标题守卫）；未配置/未命中保留手动匹配入口 |
| D4 | 推送地址用文本 + 复制，不引入二维码依赖 |
| D5 | 顶栏「打开本地文件」入口删除，能力并入推送对话框；本地文件播放语义不变（不写历史） |

## 边界

改：`apps/desktop-flutter/lib/core/push_parser.dart`（新）、`lib/services/push_page.dart`（新）、
`lib/services/sync_server.dart`、`lib/state/sync_state.dart`、`lib/state/app_state.dart`、
`lib/ui/push_dialog.dart`（新）、`lib/ui/app.dart`、`lib/ui/config_pages.dart`、
`lib/ui/history_entry_detail.dart`、`lib/ui/meta_match_dialog.dart`（加可选参数）、
`test/*`（新增/更新）。

不改：安卓仓库、播放器内核与 `player_page.dart` 的播放契约、TMDB 匹配算法本身、
同步协议字段、`PlaybackRequest.localFile` 语义。

## 契约（冻结）

```dart
// core/push_parser.dart
class PushParsed { final String url; final String title; bool get hasExplicitTitle; }
const String pushSiteKey = 'push_agent';   // 合成站点键，对齐安卓 SiteApi.PUSH 语义
const String pushSourceName = '推送';
PushParsed parsePushText(String text);                       // url|剧名 / push:// / 裸地址 / 嗅探
PushParsed parsePushFields({String? url, String? title});    // 两栏独立字段优先
String pushDisplayTitle({required String url, String title = ''});
bool looksLikeLocalMediaPath(String value);                  // 纯字符串判定，不碰磁盘
PlaybackRequest pushPlaybackRequest({required PushParsed parsed, String? localPath});

// services/sync_server.dart · SyncServerHost 新增
final bool Function() isPushEnabled;
final Future<bool> Function(PushParsed parsed) onPush;

// state/sync_state.dart
bool get receivePushEnabled;                 // 默认 false，落 settings.json 的 sync 段
Future<bool> setReceivePushEnabled(bool);    // 开启时若服务未启动则先启动
String? get pushPageUrl;                     // serverRunning ? '${serverBaseUrl}/' : null

// state/sync_state.dart · SyncStateHost 新增
Future<bool> onPushReceived(PushParsed parsed);

// state/app_state.dart
PlaybackRequest? get pendingPush;            // 壳层消费后 clear
void clearPendingPush();
Future<bool> submitPush({required String url, String title = ''});
Future<void> manualMatchPush({required String vodId, required String title, required TmdbItem item});
```

端点行为（与安卓一致，另有本机页面）：

| 请求 | 条件 | 结果 |
| --- | --- | --- |
| `GET /` `GET /index.html` | 接收推送开 | 200 `text/html` 推送页（播放地址 + 剧名） |
| 同上 | 未开 | 404 纯文本提示「接收推送未开启」 |
| `POST /action?do=push`（form `url`,`title`） | 接收推送开 + 来源为私有/回环地址 | 200 `OK push`；缺 url → 400 |
| 同上 | 未开 | 403 |
| 同上 | 非局域网来源 | 403 |
| `/action?do=sync` | 既有语义 | 不变 |

## 波次

- **W1（Lead）** 纯逻辑 + 服务端 + 状态层：`push_parser`、`push_page`、`sync_server` 路由、
  `sync_state` 子开关与回调、`app_state` 待播队列/自动匹配/手动匹配；配套单测。
- **W2（子代理 A，UI）** `push_dialog.dart`、顶栏去「打开本地文件」、壳层消费 `pendingPush`、
  历史页点击推送记录 → 匹配元数据；更新 `local_file_playback_test.dart`。
- **W3（子代理 B，设置 + 文档）** `config_pages.dart` 子开关与地址展示；
  `docs/webhtv-pc-design.md`、`docs/phase9/README.md` N4、`docs/phase9/design/05-upstream-map.md`、
  `PRODUCT.md` 已实现清单。

W2/W3 只消费 W1 冻结的契约，不得改 W1 文件。

## 验收门

1. `dart analyze` 干净；全量 `flutter test` 通过（含既有 474 个测试文件不回归）。
2. 推送页含「播放地址」「剧名」两栏；`/action?do=push` 在开关关时 403、开时回调被调用且解析正确。
3. 推送播放历史记录名 = 剧名（非裸地址）；`url|剧名` 语法与 `push://` 前缀与安卓一致。
4. 剧名通过守卫且 TMDB 已配置 → 恰好一次匹配请求，命中后写 `TmdbMatchRecord`（含海报）；
   未配置或守卫不放行 → **零**请求。
5. 顶栏不再有 `topbar-open-local-file`；「推送…」对话框可选本地文件并沿用 `PlaybackRequest.localFile`。
6. 顶栏改动的 Before/After 截图（同视口/同主题），以及推送对话框 After 截图。

## 交付结果（2026-11-20）

### 已交付

- **W1 核心（Lead）**：`core/push_parser.dart`、`services/push_page.dart`、
  `services/sync_server.dart`（`GET /` + `do=push` + 网段门禁 + 日志脱敏）、
  `state/sync_state.dart`（接收推送子开关）、`state/app_state.dart`（待播队列 / 自动匹配 / 手动匹配）。
- **W2 UI（子代理 push-ui）**：`ui/push_dialog.dart`、顶栏「推送」替换「打开本地文件」、
  壳层消费 `pendingPush`、历史页推送记录 → 手动匹配、`MetaMatchDialog.allowExternal`。
- **W3 设置（子代理 push-settings-docs）**：`ui/config_pages.dart` 子开关 + 地址展示 + 复制；
  文档由 Lead 补齐：`docs/webhtv-pc-design.md` §30、`docs/phase9/README.md` N4 变更说明、
  `docs/phase9/design/05-upstream-map.md` PushActivity → 已对齐、`PRODUCT.md` 已实现清单。

### 验收证据

- `dart analyze apps/desktop-flutter` → **No issues found**。
- 推送相关 7 个测试文件（parser/server/playback/dialog/settings/local_file/capture）→
  **60 passed / 5 skipped**（skip = 本机无 libmpv，播放页断言留给 CI）。
- 全量 `flutter test` → **6462 passed / 69 skipped / 335 failed**：其中 333 条为本机缺
  libmpv 的既有播放器 UI 用例（与本次改动无关），另 2 条（`topbar_config_entry_test`、
  `local_source_enable_test`）在并行负载下 settle 5s / 30s 超时，**单独跑全绿**
  （3 passed / 20 passed）。推送相关文件在全量里 **0 失败**。
- 视觉证据：`docs/phase9/evidence/screenshots/push-receive/`
  （`before-topbar.png` / `after-topbar.png` / `after-dialog.png`，1280×800、dark、同一采集脚本，
  Before 来自 HEAD 的独立 worktree）。

### 复核中修复的缺陷

1. `setReceivePushEnabled(true)` 自动拉起服务未置 `_serverEnabled` → 服务开关显示关闭、
   重启后子开关丢失（子代理复核发现）；改为 `_startServer` 成功后置真。
2. `push_dialog_test` 无条件 `installMediaKitMocks` 在本机直接抛 → 按 libmpv 可用性装载。
3. `push_settings_test` 开启后未停服务 → HttpServer idle 定时器触发
   「A Timer is still pending」→ 用例末尾停服务。
4. 截图脚本三处：边界弹窗未关、RepaintBoundary 只包 home（拍不到对话框）、
   组件主题字体 tofu → 逐项修正（只影响证据脚本，不影响产品代码）。

### 如实披露的限制

- 本机无 libmpv：真正构造 `PlayerPage` 的断言在本地 skip；实际播放/导航断言由 CI 覆盖。
- 推送端点无凭据（安卓同样如此），安全边界只有「开关 + 私有网段」；**不宣称认证**。
- Windows 防火墙可能拦截局域网访问，UI 与 §30 均已提示。
- 按决策 D4/D1 不做二维码、不做 PC→安卓发送。


## 第二轮（2026-11-21）：修「点了没反应」+ 改为「先详情后播放」

### 缺陷根因与修复

- 现象：推送对话框点主按钮后按钮停在「处理中…」，播放页没出现。
- 根因：`submitPush` 成功时状态层同步 `notifyListeners()`，壳层立刻
  `Navigator.push(PlayerPage)`；对话框在 `await` 返回后又 `pop()` 自己，pop 掉的
  其实是刚压入的播放页，对话框因此留在忙态。
- 修复：`AppShell._consumePendingPush` 改为 `addPostFrameCallback` 延到下一帧再导航；
  对话框成功路径先落回忙态再关窗。

### 流程改为「推送 → 详情 → 播放」（用户决策）

- 匹配到 TMDB → 复用既有 `TmdbDetailPage`（新增可选 `onPlayPush` / `pushAddress`，
  标题栏「播放推送地址」+ 地址常驻行）；
- 未匹配/未配置/匹配超时（4 秒）→ 极简「推送详情」页（`ui/push_detail_page.dart`），
  手动匹配成功后自动换到 TMDB 详情页；
- 历史里的推送记录回到同一个落点；
- 主按钮文案：「打开详情」（忙态「打开中…」）。

### 本轮验证

- 推送相关 8 个测试文件：**73 passed / 3 skipped**（skip = 本机无 libmpv）。
- 定向回归：`topbar_config_entry`、`phase4_tmdb_ui`、`phase4_tmdb_detail_hero`、
  `phase4_tmdb_entry_reachability`、`history_local_source`、`history_source_label_ui`、
  `phase6_history_entry_order`、`phase5_history_aggregation_ui` → 全绿。
- `dart analyze apps/desktop-flutter` → 待最终复跑（见交付总结）。
- 视觉：`docs/phase9/evidence/screenshots/push-receive/after-detail.png`（推送详情页）。


## 第三轮（2026-11-21）：按安卓契约改回“普通站点 vod”

用户实测反馈：推送打开的是 TMDB 元数据页、没有播放按钮——没按安卓契约实现。

- 安卓契约（SiteApi.detailContent）：key = push_agent 时，若配置里存在该站点，就用
  该站点解析（ids 传推送地址）；站点缺失才由 App 合成单集。即“推送 = push_agent
  站点上的一条普通 vod”，详情页与点播无差别。
- 修复：openPushLanding 先查 siteInActiveSource(pushSiteKey)：
  1. 有站点 → 选中它 + 普通 DetailPage（线路/剧集/TMDB 全走既有管线）；
  2. 无站点且已匹配 → TmdbDetailPage（带「播放推送地址」）；
  3. 无站点且未匹配 → 极简推送详情页，并明确提示“配置里没有可用的推送源”。
- 落地不再等匹配（有源时）；selectSite 不 await（不把首页加载拖进落地）。
- 历史记录：推送源还在时走标准详情路径；源被删掉才用兜底页。
- 新增测试：配置里有推送源 → 选中该源并进普通详情页（用既有 ExternalMetaOff 接缝，
  bootstrap 放 setUp，避免 fake-async 挂死）。

验收：推送 8 个测试文件 74 passed / 3 skipped；定向回归 63 passed；dart analyze
（lib / test）零 issue；截图 after-detail.png 已更新（兜底页含“没有推送源”提示）。


## 第四轮（2026-11-21）：没有推送源时也要「像点播」——合成推送站点

用户再次实测：打开的是 TMDB 元数据页、没有播放按钮；并指出「推送的详情应该和普通
点播没区别，播放源是用户配置的推送爬虫源」。

- 复查安卓：SiteApi.detailContent 在 key=push_agent 且配置里**没有**该站点时，由
  App 自己合成一条单集结果（pushDetail），所以安卓永远进普通详情页。
- PC 补齐同一层：新增 PushSiteService（SiteService 子类）——
  detail() 返回 pushSiteDetail(parsed)：一条线路「推送」、一集（集名=剧名/推送内容、
  地址=推送地址）；resolvePlayback() 把地址直出给播放器。
  AppState.pushSiteContext(parsed) 把这份服务包成 PlaybackSourceContext（配置里补一个
  push_agent 站点）。
- 落点顺序：配置有 push_agent 源 → 选中它进普通详情页；没有源但有配置 → 用合成站点
  服务进**同一个普通详情页**；连配置都没有 → 极简兜底页。
- 删除上一轮的「匹配到 TMDB → 纯 TMDB 详情页」分支与 TmdbDetailPage 的推送参数
  （那页天然没有线路与播放按钮，正是用户指出的问题）。
- 剧名匹配不再挡落地（详情页自己跑 TMDB 管线），只作为历史/海报的结论。

验收：推送 8 个测试文件 **75 passed / 3 skipped**；dart analyze（lib + test）零 issue；
新增用例覆盖：有推送源 → 普通详情页 / 无推送源但有配置 → 合成站点普通详情页 /
完全无配置 → 兜底页 / pushSiteDetail 的单线路单集形状；截图 after-detail.png 现在是
普通详情页（标题 + 推送剧名 + 播放第一集）。


## 第五轮（2026-11-21）：推送源跨配置选择

用户反馈"只有一集"，并问推送爬虫源是否不兼容。查本机数据库确认：

- 当前生效配置 AT-不夜-T4-内网（config_sites 189 行）**没有任何推送站点**；
- 推送源在别的配置里：王二小/王二小放牛娃 → push_agent（type 3，Android JAR，
  PC 判定不可用）；唐三的猫源 → nodejs_push（type 4，http://127.0.0.1:9988/spider/push/4）。

改动：

- 新增 AppState.pushSourceCandidate()：先当前配置、再其它已保存配置；配置内 key 精确
  push_agent 优先，其次 key/名字像推送；候选按「PC 可用优先 → 当前配置优先 → 最近更新
  优先」排序；跨配置时带其 PlaybackSourceContext（service/sourceKey），历史写回那份源。
- 落点：选到推送源 → 普通 DetailPage（跨配置时用 sourceContext）；没有源才合成详情；
  连配置都没有才用兜底页。
- 纯函数 pushSiteInConfig(config) 下沉到 core/push_parser.dart，补 3 条单测。

验收：推送 8 个测试文件 78 passed / 3 skipped；dart analyze（lib + test）零 issue。


## 第六轮（2026-11-21）：片名优先级与 TMDB 覆盖

用户实测：推送源（配置 不夜-T佬 的 push_agent，type 4）已成功解析并播放，但详情页标题
被推送源返回的网盘地址覆盖，TMDB 数据被清掉。

根因：mergeSourceDetailDisplay 无条件用**详情返回的** vodName；随后第二轮 TMDB 用这个
URL 名再匹配一次 → 与手填剧名的那次匹配（store 里 sourceTitle 不同）对不上，TMDB 状态
被清空（日志 tmdb=12/0 → 0/0）。

修复：
- 手填剧名经 Vod.extra[pushDisplayNameExtraKey] 带进详情页；loadDetail 合并时用它压过
  站源片名（mergeSourceDetailDisplay 新增 nameOverride，纯函数，3 条单测）。
- 选择用 extra 而不是给 loadDetail 加参数：7 个测试替身覆写了该签名，加参数全部编译失败。
- 预匹配只在外填剧名时触发；管线侧对 push_agent 加推送标题守卫（URL/垃圾名不自动匹配），
  但已有手动结论仍放行。
- 没填剧名时按用户规则：采用推送源解析出的名字，交给常规 TMDB 管线（含清理）。

验收：推送 8 个测试文件 + TMDB/详情 6 个回归文件共 235 passed / 3 skipped；
dart analyze（lib + test）零 issue。


## 第七轮（2026-11-21）：历史卡片用刮削后的海报与集名

用户实测：继续观看里两条推送记录的海报是百度网盘 logo，集名是 "[2.44G] S01E01" /
"[6.17G] 1" 这类原始标签；安卓版显示的是刮削后的（历史图取页面/TMDB artwork）。

- 写入侧：recordProgress 对 push_agent 行改用 TMDB 匹配海报；集名经 pushEpisodeLabel
  清洗（剥方括号标签，SxxExx/纯数字/第N集 → 第N集）。
- 展示侧：历史卡片对推送行展示清洗后的集名（旧行立即改善）。
- 补图：HistoryPosterRepair 对推送行优先用 TMDB 缓存海报，且历史页的补图候选不再
  跳过"已有图"的推送行（站源给的是网盘 logo）。
- 纯函数 pushEpisodeLabel + 3 条单测。

验收：推送 + 历史相关 6 个测试文件 62 passed；dart analyze（lib + test）零 issue。


## 第八轮（2026-11-21）：历史点回推送详情被覆盖

用户实测：在「继续观看」点开推送记录，详情页又变回百度网盘 logo + 英文名 LIANGCHEN。

根因两条：
1. 历史里的推送记录走的是普通站点路径，没有带"手填剧名"覆盖；
2. 推送源把 https://pan.baidu.com/... 改写成 pan.baidu.com/...（去掉 scheme）返回，
   而 mergeSourceDetailDisplay 用**详情返回的** vodId。身份变了，TMDB 归属门判成换片 →
   清空已匹配数据（日志 剧照 tmdb=11/0 → 0/0）。

修复：
- mergeSourceDetailDisplay 新增 idOverride；loadDetail 对 push_agent 固定用 listing 的
  vodId（推送身份稳定），TMDB 归属判定与缓存键因此不再漂移；
- 历史里的推送记录一律走 openPushLanding，并把记录里的剧名作为 parsed 传下去
  （→ Vod.extra 覆盖），标题/海报保持刮削后的值；
- 新增 id 稳定性单测。

验收：推送 + 历史 8 个测试文件 76 passed / 2 skipped；dart analyze（lib + test）零 issue。


## 第九轮（2026-11-21）：历史卡片海报仍不更新

用户实测：历史卡片集名已变「第1集」，海报仍是推送源给的图（小红书/网盘 logo）。

查本机数据库确认：tmdb_matches 里记录存在且 vod_id 带 scheme（https://pan.baidu.com/...），
而历史行 vod_id 是站源改写后的 pan.baidu.com/...（无 scheme）；另一行片名带后缀
"罪蓝之路 4K内嵌中字"，与 source_title "罪蓝之路" 也不相等。两处都对不上 → 补图回落到站源图。

修复：
- pushMatchedItem 查找兼容 id 变体（补 https://）与片名变体（首个空格前的部分），
  写盘（recordProgress）、详情页展示、历史补图三处共用；
- 历史补图：推送行先用匹配记录的刮削海报（updateHistoryPoster），命中就不再走站源详情；
- 详情页首屏按钮对推送集名做 pushEpisodeLabel 清洗（继续播放 · 第N集）；
- 新增单测：id 少 scheme + 片名带后缀仍能命中。

验收：推送 + 历史 4 个测试文件 54 passed；dart analyze（lib + test）零 issue。


## 第十轮（2026-11-21）：其它格式的落点 + 首页续播缺背景/简介

用户两个问题：
1. 识别方案对磁力/本地文件等格式是否成立；
2. 首页「继续观看」的推送记录没有大海报（背景）与简介。

处理：
- 明确并文档化识别口径（设计文档新增 §30.3.1 表）：解析只取"播放地址"，不猜类型；
  magnet/ed2k/thunder 原串交给推送源；本地路径走 PlaybackRequest.localFile；
- 修复一处越界：openPushLanding 之前会把**本地文件路径**也送进站点详情（当 ids）。
  现在本地请求直接进极简推送详情页，再走本地播放，不会发给任何站点；
- 首页取图：推送行没有内嵌身份（旧记录 tmdb_id=0 / 播放时未匹配）时，用匹配记录补
  身份 → 16:9 背景、简介、类型标签与点播一致；
- 新增单测：磁力链原样交给推送源 / 本地路径不进站点详情 / 本地播放语义不变。

验收：推送 + 历史 8 个测试文件 82 passed / 3 skipped；dart analyze（lib + test）零 issue。

