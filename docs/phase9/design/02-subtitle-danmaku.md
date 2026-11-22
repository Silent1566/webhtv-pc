# 02 · P0 字幕与弹幕设计（P0-6 / P0-7）

- 覆盖缺口：P0-6 字幕源/自动匹配/手动搜索/本地字幕；P0-7 弹幕库搜索/手动匹配/记忆/完整显示设置
- 上游依据：安卓 `webtv2@77e2fbefdc`（`subtitle/*`、`player/danmaku/*`、`bean/DanmakuMatchCache.java`）
- 涉及 PC 模块：`lib/services/subtitle_service.dart`、`lib/services/danmaku_service.dart`、`lib/ui/player_page.dart`、`lib/ui/danmaku_overlay.dart`、`lib/core/subtitle.dart`、`lib/core/danmaku.dart`

---

## 0. 不变量

1. **站源给的优先**：播放结果里的 `subs` / 弹幕地址永远先加载；只有缺失或用户主动搜索时才走外部源。
2. **失败不影响播放**：任何字幕/弹幕失败只提示 + 日志（`subtitle*` / `danmaku*` 分类），视频继续。
3. **外部源默认关闭或显式开启**：字幕源与弹幕库都要有总开关；关闭后零外部请求（可断言）。
4. **凭据脱敏**：assrt token、弹幕库 API key 不进日志、不进诊断导出、不进同步设置。
5. **不伪造**：没有匹配结果时显示空态与原因（网络/鉴权/无结果），不得把「0 条」说成「已加载」。

---

## 1. P0-6 字幕源

### 1.1 现状

- `subtitle_service.dart` 已能从 URL 或本地路径（含 Windows 盘符）加载，编码链为 BOM → 声明 charset → UTF-8 严格解码 → 证据探测（GBK / Big5 / Shift-JIS / EUC-KR），格式 `srt/ass/ssa/vtt/sub`。
  - 探测只在**未声明 charset** 时进行，且必须“严格解码 + 脚本证据”双通过：GBK 能把 Shift-JIS/EUC-KR 字节解成看似正常的汉字，只按“谁先不报错”判定会静默产出乱码。规则与边界见 [evidence/12](../evidence/12-subtitle-charset-extension.md)。
  - 配置导入不走探测（§7.4.1 只为 GBK/GB18030 兜底），行为保持不变。
- `player_controller` 已支持内嵌/外挂轨选择与关闭。
- 缺：外部字幕源、自动匹配、首选语言、手动搜索、匹配记忆，以及「选择本地字幕」入口。

### 1.2 模型

```dart
class SubtitleProviderSpec {
  final String id;          // 'assrt' | 'local' | 't3'
  final String name;
  final bool enabled;
  final bool needsToken;
}

class SubtitleCandidate {
  final String providerId;
  final String assetId;     // provider 侧 id 或本地路径
  final String title;
  final String language;    // 'zh-Hans' / 'zh-Hant' / 'en' / ''
  final String format;      // srt/ass/...
  final String downloadUrl; // 本地为 file:// 或路径
  final double score;       // 匹配分 0..1
  final Map<String, String> headers;
}
```

- 匹配键：`(siteKey, vodId, episodeName)`（与安卓 `DanmakuMatchCache`/字幕记忆同构）。
- 语言优先级：`zh-Hans > zh-Hant > en > 其他`，用户可在设置页调整。

### 1.3 自动匹配流程

```text
播放开始
  ├─ 结果有 subs → 直接登记（现状）
  └─ 结果无 subs 且 subtitles.autoMatch 开启
        ├─ 用「标题 + 季 + 集」构造查询（标题清洗复用 tmdb_title 的归一化）
        ├─ 并发查询启用的 provider（超时 8s，单 provider 上限 20 条）
        ├─ rank：标题相似度 × 季集一致 × 语言优先级 × provider 顺序
        ├─ best.score >= 0.75 → 下载并加载；失败则顺延下一个候选（最多 2 次）
        └─ 否则不自动加载，顶栏「字幕」菜单出现「搜索字幕…」
```

### 1.4 手动搜索

- 入口：播放器顶栏字幕菜单底部「搜索字幕…」；详情页不加入口（避免误导：字幕是播放期行为）。
- 对话框：关键词（默认当前标题）+ 季集；结果列表显示 provider / 语言 / 格式 / 匹配分；点击即加载。
- 本地文件：同一对话框提供「选择本地字幕文件…」；用原生文件对话框（P2-9 的组件，未落地前可用路径输入兜底，但必须在 UI 上标明）。

### 1.5 记忆

- DB v5 增 `subtitle_match`：`(site_key, vod_id, episode_name, provider_id, asset_id, title, language, updated_at)`，唯一键前三列。
- 命中记忆时优先于自动匹配；用户手动选择后写入；提供「忘记本片字幕」。
- 记忆不跨站源（`siteKey` 不同不共享），与安卓一致。

### 1.6 失败与边界

| 情况 | 行为 |
| --- | --- |
| 未配置 token | provider 显示「未配置」，不发起请求 |
| 401/403 | 「字幕源鉴权失败」+ 引导到设置页，不重试 |
| 超时/网络 | 「字幕源不可用」+ 可重试；不影响播放 |
| 下载后格式不支持 | 丢弃该候选并记录；继续下一个 |
| 字幕编码非法 | 声明的编码解不出来，或四种旧编码都严格解码失败 → `subtitleDecode` 提示。声明值与字节不符（解出 U+FFFD）时改走证据探测；探测路径**不写入替换字符**，探测无解才沿用声明路径的既有容错 |
| 用户手动关闭字幕 | 自动匹配不得再把字幕装回来（会话级标记） |

### 1.7 测试

- L1：语言优先级、评分函数、季集解析、标题清洗、候选排序稳定性。
- L2：设置页开关与 token 脱敏、搜索对话框空态/错误态、记忆命中。
- L3：fixture provider（本地 HTTP）返回 2 条候选 → 自动加载正确的一条；token 错误 → 提示且不阻塞；本地文件加载。

---

## 2. P0-7 弹幕库

### 2.1 现状

- `danmaku_service.dart` 支持结果内弹幕 URL（xml/text）、编码兜底、直播 `ws/wss` 增量。
- `danmaku_overlay.dart` 支持开关、透明度、字号、滚动/顶部/底部显隐（PC 已有子集）。
- 缺：弹幕库搜索、手动匹配、匹配记忆、速度/行数/区域/描边/时间偏移等显示参数、API 地址配置。
- **注意**：`webtv2` 基线**没有**「弹幕屏蔽词」能力，本阶段不做假对齐；如后续需要，按新增需求另行评估。

### 2.2 模型

```dart
class DanmakuLibraryEntry {
  final String providerId;   // 默认 'default'
  final String id;           // 库内 id
  final String title;        // 库标题
  final String episode;      // 集/话
  final String url;          // 弹幕文件地址
  final int count;           // 条数（可能为 0=未知）
  final double score;
}

class DanmakuMatchRecord {
  final String siteKey, vodId, episodeName;
  final DanmakuLibraryEntry entry;
  final int updatedAt;
}
```

### 2.3 流程

```text
播放开始
  ├─ 结果有弹幕源（http/file/ws）→ 直接加载（现状）
  └─ 结果无弹幕 且 danmaku.autoSearch 开启 且 配置了 apiUrl
        ├─ 命中 danmaku_match → 加载
        ├─ 否则按「标题 + 集」搜索库（超时 6s）
        ├─ 取 score 最高且 >= 阈值 → 加载
        └─ 否则顶栏「弹幕」菜单出现「搜索弹幕…」
```

弹幕库协议（`lib/services/danmaku_library_service.dart`）：

- 主协议是 FongMi/TVBox 弹幕中转（对齐安卓 `DanmakuApi`）：`POST <apiUrl>/danmaku`，
  表单 `name=<片名>&episode=<集名>`，响应为弹幕源数组 `[{"name","url",...}]`；
  地址含 `{name}`/`{episode}` 占位符时改走 GET 并做编码替换。huangxd-/danmu_api
  一类部署暴露的就是这个接口。
- 地址自动补齐：末段已是 `danmaku` 或路径段数 > 1 时原样使用，否则追加一段 `danmaku`
  （用户通常只填 `http://192.168.1.10:9321/TOKEN`）。规则与安卓 `getSearchUrl` 一致。
- 兜底保留旧通用契约 `GET <apiUrl>?title=&episode=`（`{code,data:[...]}` 或裸数组）：
  仅在中转非 2xx / 响应不是 JSON / 网络异常时回落。中转返回合法 JSON（含空数组 `[]`）
  即权威结果，不得再补发第二个请求。
- 中转条目按**最后一个** ` - ` 拆成片名与集名（片名自身可能含该分隔符），按 url 去重保序。
- 超时分两档：中转（含占位符 GET）30s，旧通用契约回落仍 6s。danmu_api 冷搜索要现场
  聚合各平台源再落缓存，实测 6.65s（孤独摇滚）/ 10.89s（进击的巨人）/ 21.08s（火影忍者）；
  用 6s 会把慢但有效的响应判成超时 → 回落只拿到 text/html → 空结果 → 被当成「没有弹幕」。

- 手动搜索：见下文「搜索界面」；选择后加载并写记忆。
- 记忆表 `danmaku_match`：唯一键 `(site_key, vod_id, episode_name)`；提供「忘记本集/本片」。
- 关闭自动搜索后：不发起任何库请求（fixture 计数断言）。
- 自动搜索会跳过不可用候选（空源 / 解析出 0 条），最多试 3 个，全部失败才提示一次；
  手动选择按用户选择、不换源（用户明确点了哪一条就用哪一条）。

#### 搜索界面（多弹幕源 S3）

播放器顶栏「弹幕 → 搜索弹幕…」打开的是**居中大对话框**（760×600，小屏按
`MediaQuery` 收缩而不是溢出），不再是「关键词弹窗 + 底部平铺列表」两步
（`lib/ui/danmaku_search_dialog.dart`，对齐安卓 `DanmakuSearchDialog`）：

- 顶部：关键词（预填当前剧名，打开即自动搜一次）+ 搜索按钮 + 「集数 ↑/↓」排序开关
  （默认 ↑）。三者同高 32、同圆角 `AppRadius.sm`、同视觉密度，文案直接写出排的是
  **集号**——「正序/倒序」不说排什么，用户第一反应会是「没默认排序吧」。
- 筛选：**来源** chip（每个源带本次结果数与失败标记「⚠」+ 失败原因 tooltip——
  「源挂了」和「这个源确实没有这部剧」是两件事，只看一份空列表分不开）、
  **渠道** chip（bilibili/dandan/qq…，取自 `danmakuChannelOf`）、**仅本集**开关。
- 结果：先 `rankDanmakuEntries` 按 `DanmakuQuery` 打分，再交给
  `groupDanmakuEntries` 按剧名折叠（点标题折叠/展开）；
  每行显示集名、渠道、来源库、匹配分，点击即选中并载入。
- 分组键**保留年份括注**（`danmakuTitleKeyOf`）：`一马当先(2026)【电视剧】` 与
  `一马当先(2023)【短剧】` 各自成组（同名不同剧混进一组，看着就是「排序乱了」），
  同一年同一部剧的多来源仍合并。「未分类」永远最后；
  集号在**协议转换时**就算成数值字段 `DanmakuLibraryEntry.episodeNumber`（入口解析一次，
  对齐安卓 `DanmakuTitle.parseEpisode` 的「第N集/话/回、EP N、SxxExx」，并把全角数字归一），
  排序/「仅本集」只读这个字段；现场解析展示串一旦格式变化就会退化成「按上游原始顺序」，
  看起来就像按字符串排序。
  组内 = **集号数值**升序（第10集排在第2集之后，不是按字符串比），同集号按原输入
  顺序，解析不出集号的排末尾并在组名后标「· 未识别集号」——静默乱序会被读成排序坏了。
- **匹配用多维相似度**（`titleScoreForDanmaku` / `danmakuEntrySimilarity`，
  `core/danmaku_match.dart`）：名称 0.70 + 年份 0.12 + 季 0.10 + 类型 0.08 组成
  **题分**，再按「题分 0.7 + 集号一致性 0.3」得出条目相似度（权重常量集中在
  一处并写明为什么是这个分配）。名称沿用旧阶梯：相等 1 / 候选包含查询 0.9 /
  查询包含候选 0.85 / 最长公共子串占查询长度的比例 × 0.8。年份、季、类型只有
  一侧有值时给**中性分**而不是 0（年份缺失 0.5、季只有一侧 0.6、查询无类型 0.5）：
  上游漏标是常态，当成「不匹配」会把大半候选一棍子打到阈值以下，自动匹配随之失灵。
  年份有两个来源：详情页 `Vod.vodYear` 经 `PlaybackRequest.vodYear` 带进播放器
  （站点结构化字段比库标题里的括号更权威），缺失时才回退到从标题解析
  `(2026)`/`（2026）`/`【2026】`；季认 `第二季`/`第2季`/`Season 2`/`S2`，但
  `S02E07` 里的 `S02` 不算季——那里的数字首先是集号（`extractEpisodeNumber` 的职责）。
- **分组按相似度排序**（`groupDanmakuEntries(query: …)`）：组相似度 = 组内最高
  `danmakuEntrySimilarity`，组内存在与查询集号相同的条目时再 +0.05（只够做同分
  裁决，加多了会让「集号对上但片名不像」的组反超真正的主组）；组间 = 组相似度
  降序 → 同分组内**条目数多者优先**（库里给每集建一条记录，撞名的另一部片往往
  只被零散收录几集）→ 剧名升序，「未分类」永远最后。旧调用方不传 `query` 时仍是
  「最高分降序 → 剧名升序」，顺序不会因为这次改动而抖动。对话框把本次 `DanmakuQuery`
  原样传进来（年份优先取 `PlaybackRequest.vodYear`，缺失才回退片名括注），所以年份
  参与组间比较；逐源增量渲染的每一批都用同一个 query 重算，先后到达只改变出现时机。
- **默认只展开「当前」那一组**：每次搜索重新定默认展开，第一批结果到达后若 `currentUrl`
  命中某条，就只展开它所在组并用 `Scrollable.ensureVisible`（`alignment: 0.3`，每次搜索
  只滚一次且不打断用户后续滚动）把它带进视口，其余组折叠——同名不同年的另一部剧默认
  收起来，用户第一屏看到的就是「我正在听的那条」；没有命中则全部展开（保持旧行为）。
  用户点过的组以手动状态为准，增量更新不会把它重置回去；标题行的
  `danmaku-search-toggle-all`（`unfold_more`/`unfold_less`）在「全部展开 ↔ 全部折叠」
  之间一键切换，只覆盖当前可见的分组，不改默认展开、也不影响下一次搜索。
- 视觉层级（S4）：三档容器各司其职——**分组头**是 36 高的整行
  `surfaceContainerHigh` 底色 + 折叠箭头（折叠时朝右）+ 加粗标题 + 尾部做淡的
  「· N 集」；**条目行**是 56 高、悬停 `surfaceContainerHighest`、行间 1px
  `outlineVariant`（50% 透明）分隔线，副标题里渠道做成 `secondaryContainer`
  小徽章、来源库名做淡、分数右对齐留一位小数，集名开头的 `【渠道】` 标签在渲染时
  剥掉（渠道已由徽章表达一次）；**筛选区**每行左侧是 32 宽的中性标签
  「来源」「渠道」（`labelSmall`），右侧是横向滚动的紧凑 chip 轨道——滚动而不是换行，
  源多起来也不会把结果区挤没，两行标签也始终对得上各自那一排 chip。
  状态一并分级：加载是查询行下的 2px `LinearProgressIndicator` + 「正在搜索 N 个源…」，
  空结果是 `search_off` + 换词提示，全失败是 `cloud_off` + 逐源原因（最多 4 行），
  部分失败则在结果上方压一条 28 高的 `secondaryContainer` 提示带而不顶掉成功结果。
- 「仅本集」只保留集号与当前集相同的条目；**任一侧解析不出集号时不排除**——
  解析失败不等于「不是本集」，拿它当过滤依据会把能用的候选静默藏掉。
- 没有可用源时直接显示「未配置弹幕源」，不发任何请求。

多源并行搜索走 `DanmakuLibraryService.searchSources`：固定 worker 数并行、
逐源记账 `ok/count/elapsedMs/error`、按**用户配置的源顺序**合并并按 url 去重。
协议实现仍然只有一份，对话框只消费结果，不复制任何协议或解析逻辑。

搜索是**逐源增量渲染**：`searchSources` 每完成一个源就通过 `onSourceResult` 回调一次
（回调顺序 = **完成顺序**，不是配置顺序），对话框把那批条目并入累计列表后立刻重排重绘，
进度条写「x/N 已完成」，只要已有条目就不再显示整块空白；最终返回值仍是「按源顺序合并
+ 按 url 去重」——回调只改变**出现时机**，不改变最终顺序。

列表标注**当前正在使用**的那条弹幕（`currentUrl`，播放器把已加载那条的地址传进对话框）：
命中行在分数左侧挂一个 primary 色「当前」小徽章，所属来源 chip 后缀「· 当前」；没有正在
使用的弹幕（未加载 / 加载失败 / 已切集）时不渲染任何标记。

自动搜索同步改为**多源择优**：`searchSources` 拿全部源的条目 →
`rankDanmakuEntries` 按阈值（0.6）过滤 → `autoLoadDanmakuCandidates`
依序试载，最多试 3 个，第一个真的载入弹幕的候选胜出；只有成功才写记忆，
全部失败才提示一次（空源/解析出 0 条不算成功）。

#### 弹幕库地址来源与优先级（对齐安卓 `DanmakuSetting.getConfiguredApiUrl()`）

**手填 > 站点配置 `danmaku` 字段 > 本地猫源**，三档依次尝试：

1. 手填：设置 → 弹幕 → 弹幕设置 里的「弹幕库地址」（`DanmakuSettings.apiUrl`）。
2. 站点配置：配置 JSON 根对象的 `danmaku`（安卓 `VodConfig.getConfig().getDanmaku()`）。
   解析进 `AppConfig.danmaku`，导入/导出/云端同步原样回写一次；它不再是 `extra`
   里的未知字段（不可解析为非空字符串时仍留 `extra`，保证导入不丢字段）。
3. 本地猫源：随本地源装入的弹幕服务地址。实现见
   `CatNodeRuntime.discoverDanmakuBaseUrl`（对齐安卓
   `NodeRuntime.resolveDanmakuPort` / `isDanmakuService`）：bundle 的 `port`
   文件列出它起的全部端口，**每轮重读**（弹幕服务往往比猫源本体晚起、稍后才把
   第二个端口追加进去，只读一次必然错过），跳过已认准的猫源本体端口（本体的
   `/danmaku` 回 404，探它纯粹白等一次超时），其余候选逐个 `GET /danmaku`，
   要求 200 且 body 去空白后以 `[` 或 `{` 开头——弹幕服务的 `/config` 回 401，
   两者正反都区分得开。每个候选 2s 超时、每 500ms 轮询、整体 20s deadline；
   探测在后台跑，不阻塞启动，超时只当「这个包没有弹幕」，不报错。命中后回填
   `AppState.setBundleDanmakuApiUrl`，猫源一停（换源/退出/切到普通 JSON 配置）
   立刻清空：地址指到已关掉的旧进程，比没有弹幕更糟。也不能只靠固定端口——
   该端口由 Node 每次启动随机分配（`port` 文件的全部意义就在此），写死一个
   端口在多数机器上只会指向别的进程或无人监听的地址。

每档候选都必须通过校验：scheme 为 http/https **且** host 非空（对齐安卓
`isValidApiUrl`）。非法/空白候选直接跳过、落到下一档——不报错、也不把坏地址
发给服务；全部落空才算「未配置」。

解析只有一处实现（`lib/core/danmaku_settings.dart` 的 `resolveDanmakuApi`）：
播放器与设置页统一读 `AppState.resolvedDanmakuApi` / `danmakuApiUrl` /
`canAutoSearchDanmaku`，不再各自读 `DanmakuSettings.apiUrl` 判断「有没有配置」。
`DanmakuSettings.hasLibrary` 的语义保持不变，仍只表示「手填过」。

### 2.4 显示参数（对齐 `DanmakuSetting`）

> **P1 起：显示参数与弹幕库已合并为独立页**「设置 → 弹幕 → 弹幕设置」
> （`lib/ui/danmaku_settings_page.dart`）：上半区是弹幕库（自动搜索开关 + 地址，
> 沿用 `settings-danmaku-auto-search` / `settings-danmaku-api` 两个旧 key），
> 下半区是下表里的显示参数（滑块给连续区间、档位走下拉开，不再用播放器弹层那套
> 「点一下跳下一档」）。播放器内的入口是右键菜单 → **弹幕 → 弹幕设置…（整页）**
> （顶栏「更多 → 弹幕设置」同源）；返回后播放器重新读 `state.danmakuStyle`，
> 页内改动立即在画面上生效。分类页副标题口径只写在
> `DanmakuSettingsPage.summary(state)` 一处——「自动搜索已开/已关 · 已配置地址
> （来源 label）/ 未配置地址」，与页内弹幕库分区同一口径。

| 参数 | 取值 | 默认 | PC 现状 |
| --- | --- | --- | --- |
| `enabled` | bool | true | 有 |
| `opacity` | 0–1 | 0.9 | 有 |
| `textScale` | 0.5–2.0 | 1.0 | 有 |
| `textBold` | bool | false | 无 |
| `styleMode` | stroke / shadow | stroke | 无 |
| `strokeWidth` | 0–0.3（相对字号） | 0.12 | 无 |
| `durationMs` | 3000–15000 | 8000 | 无（写死） |
| `fixedDurationMs` | 2000–10000 | 5000 | 无（写死） |
| `timeOffsetMs` | -5000–5000 | 0 | 无 |
| `maxOnScreen` | 1–200 | 按分辨率 | 无 |
| `scrollAreaRatio` | 0.1–1.0 | 0.5 | 无 |
| `maxScrollLines` / `maxTopLines` / `maxBottomLines` | 0=自动 | 0 | 无 |
| `lineSpacing` | 1.0–2.5 | 1.4 | 无 |
| `showScroll/Top/Bottom/Reverse/Positioned/Subtitle/Special` | bool | true | 部分（scroll/top/bottom） |

- 参数变化即时生效（不重建 player），由 `danmaku_overlay.dart` 的 `DanmakuStyle` 承载。
- `maxOnScreen` 必须有上限，防止低配机被弹幕压垮；渲染层做「超限丢弃并计数」。

### 2.5 失败与边界

| 情况 | 行为 |
| --- | --- |
| 未配置 apiUrl | 搜索入口置灰 + 「未配置弹幕库地址」 |
| 库返回 0 条 | 明确空态，不自动重试 |
| 文件解析 0 条 | 提示「弹幕文件为空/格式不支持」，保留原弹幕 |
| 直播 ws 断线 | 沿用现有重连与状态展示 |
| 一条弹幕时间戳越界 | 丢弃并计数（沿用 `skipped`） |

### 2.6 测试

- L1：记忆命中/失效、评分与阈值、样式参数归一化、超限丢弃计数。
- L2：设置面板所有参数可改且持久化；搜索对话框空态/错误态。
- L3：fixture 弹幕库返回候选 → 自动加载并显示；关闭自动搜索后零请求；记忆跨重启。

---

## 3. 数据与设置

- DB：v4 一起新增 `subtitle_match`、`danmaku_match`（与 P0-2 的 `history.opening_ms/ending_ms`、P1-2 的 `injected_sites` 同一次迁移，避免多次改 schema）。
- settings.json：

```json
{
  "subtitles": {
    "autoMatch": false,
    "preferredLanguages": ["zh-Hans", "zh-Hant", "en"],
    "providers": {"assrt": {"enabled": false, "token": ""}, "local": {"enabled": true}}
  },
  "danmaku": {
    "autoSearch": false,
    "apiUrl": "",
    "style": {"opacity": 0.9, "textScale": 1.0, "durationMs": 8000, "maxOnScreen": 80}
  }
}
```

- 缺省值 = 现状（外部源关闭，站源字幕/弹幕照旧）。

---

## 3.1 实施说明（W1）

- 字幕源落地为 **本地目录 + 通用 HTTP 源**（`GET <endpoint>?q=&season=&episode=&token=`）。
  assrt 等第三方服务未内置专有协议适配：把兼容端点填入即可；不做未经实测的接口猜测。
- 字幕匹配记忆写入 `subtitle_match`；播放结果自带 `subs` 时优先，不触发外部搜索。
- 弹幕库按「FongMi 中转为主 + 旧通用契约兜底」实现，自动搜索仍受 `autoSearch` 与
  `apiUrl` 双开关约束，`apiUrl` 为空时零请求。
- 实测对照（danmu_api）：`POST http://<host>:9321/<TOKEN>/danmaku`，表单
  `name=灵笼&episode=第1话` → 200 `application/json`，返回
  `[{"name":"灵笼 第二季(2025)【动漫】from bilibili - 【bilibili1】 第1话 末世桃源","url":"…/api/v2/comment/120952?format=xml"}, …]`，
  其中的 url 是 Bilibili XML，`danmaku_service.dart` 可直接拉取解析。
  同一地址发旧 `GET http://<host>:9321/<TOKEN>?title=…&episode=…` 得到的是 danmu_api
  的网页（`text/html`），JSON 解析失败 → 候选恒为空，这就是修复前「没有找到弹幕」的成因。
- 集号抽取按可信度择序（`第N集/话/回` → `EP N` → 紧跟集单位的整数 → 首个整数），
  避免中转标题里的 `bilibili1`、季号把集号带偏；同分候选保持来源顺序（中转顺序即相关度）。
- 弹幕显示参数扩展（速度/行数/区域/描边/防挡）尚未实现，列为 W1 后续，不在本轮验收内。

## 4. 与 P1/P3 的边界

- 字幕脚本源（`SubtitleSourceManager` / 订阅 / 实时翻译）→ P3-2 与 AI 扩展（P1-10），不在 W1。
- 弹幕库鉴权与多 provider → 先做单 provider（可配 URL），多 provider 视真实需求再加。
- 字幕/弹幕的「屏蔽词」不在 `webtv2` 基线内，不纳入本阶段。

---

## 5. 风险

| 风险 | 缓解 |
| --- | --- |
| 第三方字幕源接口不稳定 | provider 适配层 + 明确错误分类；fixture 锁定协议 |
| 弹幕渲染性能 | `maxOnScreen` 上限 + 超限丢弃计数 + 真实窗口帧率抽查 |
| 记忆表膨胀 | 只存最近 N 条（如 5000）+ 定期清理；不存完整弹幕内容 |
| token 泄漏 | 日志/诊断/同步三处脱敏，测试断言 |
