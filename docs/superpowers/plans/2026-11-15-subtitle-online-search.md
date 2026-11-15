# 在线字幕搜索（ASSRT / 迅雷 / 射手）实施计划

> **For agentic workers:** Hybrid 拓扑。核心 seam（模型 / 契约 / 设置 / 资源库 / 注册表）由 dispatcher 落地并冻结；三个适配器、搜索窗口、设置页、播放器接线并行派发。每个任务一个 subagent，边界外文件禁改，报告走 role 契约的 status 协议。

**Goal:** 让 PC 的「在线搜索字幕」开箱可用——内置 ASSRT / 迅雷 / 射手三个源（对标安卓 `app/src/main/assets/subtitle_sources/builtin/manifest.json`），并把只有输入框的两步流程换成 PotPlayer 式独立搜索窗口。

**Architecture:** `SubtitleProvider` 增加 `resolve()` 契约（ZIP/二次跳转只在源内部处理，播放器只拿到本地文件路径）；设置从「一个通用 HTTP 端点」扩成「每源独立开关/token」；搜索窗口只依赖注入的 `search` 函数，不直接触网，因此可离屏测试与取证。

**Tech Stack:** Dart / Flutter 3.47.5；`http`、`archive`（解 ZIP）、`crypto`（md5）、`file_picker`（均已在本仓库 `pubspec.yaml`）；测试用 `http/testing.dart` 的 `MockClient` 与 RepaintBoundary 截图。

**Spec:** 本文件即 spec。三项用户决策：① 三个源全做 ② PotPlayer 式独立窗口 ③ 先出计划、确认后实施。

---

## 0. 参考事实（已核实，实现时不必再读安卓源码）

Android 侧路径：`PY=app/src/main/assets/subtitle_sources/builtin/`，`JAVA=app/src/main/java/com/fongmi/android/tv/subtitle/`。

| 维度 | ASSRT | 迅雷 | 射手 |
| --- | --- | --- | --- |
| search | `GET https://api.assrt.net/v1/sub/search?token=&q=&is_file=1&cnt=15` | `GET https://api-shoulei-ssl.xunlei.com/oracle/subtitle?name=<quote>` | `POST https://www.shooter.cn/api/subapi.php`（form） |
| 鉴权 | token（用户设置 `${ASSRT_TOKEN}`，`PY/manifest.json:15`） | 无 | 无 |
| 必需 header | UA + `Referer: https://assrt.net/` | UA + `Referer: https://sl-m-ssl.xunlei.com/` | **仅 UA** |
| 查询输入 | `query.text` | `query.text` | **本地视频文件 md5 哈希（必须）** |
| 门禁 | `status==0`，数组 `sub.subs` | `code==0` 且 `result` 为空或 `ok`，数组 `data` | 顶层必须是数组，取 `[].Files[]` |
| 下载跳数 | 2（`/sub/detail?id=` → url） | 1 | 1 |
| 可能 ZIP | **是**（`zipfile.is_zipfile` 按魔数判定，`assrt.py:97`） | 否 | 否 |
| 本地视频依赖 | 否 | 否（仅 strict 加分用） | **是**，`mediaPath` 空则零请求（`shooter.py:78-81`） |
| 超时 | 15s | 15s | 15s |

关键逐字规则：

- **ASSRT 格式**（`assrt.py:38-43`）：`value=(subtype+" "+name).lower()`，依次查 `ass`/`ssa`/`vtt`（**不含 srt**），命中条件 `"."+fmt in value or " "+fmt in value`，都不中 → `srt`。
- **ASSRT 语言**：**不归一化**，原样透传 `lang.desc` → 回退 `m_lang`（`assrt.py:160`）。
- **迅雷格式**：`ext`（空则文件名/URL 扩展名）→ lower 去点 → 命中 `ass/ssa/srt/vtt` 否则 `srt`（`xunlei.py:41-44`）。
- **迅雷语言**（`xunlei.py:47-54`）：取 `languages` 首个非空 → 空/「default」/「默认」→ `zh` → 含 `中文|中字|简|繁|chs|cht|zh|english|eng|en|日|ja|jp|韩|韓|ko|kr` 任一子串 → **原样返回** → 否则 `zh`。
- **射手哈希**（`shooter.py:32-44`）：size<12*1024 → 空；offsets `(4*1024, size//3*2, size//3, size-8*1024)` **顺序即如此，不得排序**；每处读 4*1024 取 md5 小写 hex，四段 `;` 连接。
- **射手请求体**：`filehash`、`pathinfo`（绝对路径原样）、`format=json`、`lang`（归一为 `eng` 才是 eng，否则 `chn`）。

### 0.1 与 Python 参考实现的**有意偏差**（实现时照此写，并在代码注释里标明）

| # | 参考行为 | 本仓库行为 | 理由 |
| --- | --- | --- | --- |
| D1 | resolve 返回 `candidate.format`，可能与实际挑中文件扩展名不符（`assrt.py:200`） | 用**最终文件扩展名**定 format | 否则 mpv 按错误扩展名建临时文件，轨道识别失败 |
| D2 | ZIP 内无字幕条目时返回 ZIP 路径本身（`assrt.py:123-124`） | 显式抛 `SubtitleResolveException('zip_no_subtitle')` | 把 ZIP 交给播放器等于静默失败 |
| D3 | 下载落盘在脚本目录 | 落 `<paths.cacheDir>/subtitles/`，按数量裁剪（保留最新 100 个） | 桌面端常驻目录，无界增长是缺陷 |
| D4 | 迅雷用本地文件 sha1 给 strict 候选加分（`xunlei.py:64-77,139-141`） | **不做** | 仅影响同源内排序权重，不改变可搜到的集合；换来约 30 行二进制读取逻辑与一个测试面 |
| D5 | ASSRT 从 `videoName` 解析年份（`assrt.py:170`） | **不解析** | `SubtitleCandidate` 没有 year 字段，打分也不用年份；算出来只能塞进 payload 变成没人读的键 |

---

## 1. 不变量

1. **未配置即零请求**：没填 ASSRT token、没开迅雷/射手/HTTP、没配本地目录 → 一次网络请求都不发（可用 MockClient 请求计数器断言）。
2. **失败不影响播放**：任何源的失败 → 该源空结果 + 一行 `scope: 'subtitle'` 日志，视频照常播。
3. **token 不泄漏**：ASSRT token 不进日志、不进诊断导出、不进同步设置（沿用 `docs/phase9/design/02` 不变量 4）。
4. **空态说真话**：必须区分「未配置」「已配置但失败」「无结果」，不得把 0 条说成「已加载」。
5. **射手只对本地文件有效**：UI 必须写明，不能让它看起来像坏了。
6. **站源优先**：播放结果自带的 `subs` 永远先加载，搜索只在用户主动或缺失时发生。

---

## 2. 任务

### Task 1 — 核心 seam（dispatcher，run 1）

**Files:** `lib/core/subtitle_provider.dart`、`lib/core/subtitle_settings.dart`、`lib/services/subtitle_providers.dart`（拆成目录 + 兼容 barrel）、新建 `lib/services/subtitle_providers/provider.dart`、`lib/services/subtitle_asset_store.dart`、`lib/services/subtitle_match_service.dart`，测试 `test/subtitle_settings_sources_test.dart`、`test/subtitle_asset_store_test.dart`。

**Produces：**

```dart
// core/subtitle_provider.dart
class SubtitleQuery {
  final String title; final int? year; final int? season; final int? episode;
  final String siteKey; final String vodId; final String episodeName;
  final String? mediaPath;              // 新增：仅本地文件播放时非空
}

class SubtitleCandidate {
  // …既有字段…
  final Map<String, Object?> payload;   // 源私有：assrt {id,format} / 迅雷·射手 {url,format}
  final bool requiresResolve;           // true = 必须先 resolve 才能播
}

class SubtitleResolvedAsset {
  final String path;                    // 本地绝对路径，扩展名与真实格式一致
  final String format;                  // 由最终扩展名得出（D1）
  final String fileName;
}

String? deriveLocalMediaPath(String? url); // file:// → toFilePath；无 scheme 且绝对 → 原样；其余 null
```

```dart
// services/subtitle_providers/provider.dart
abstract class SubtitleProvider {
  String get id;
  String get name;
  int get priority;                     // local 50 > assrt 30 > xunlei 20 > shooter 10 > http 5
  bool get needsLocalMediaPath => false;
  Future<List<SubtitleCandidate>> search(SubtitleQuery query, SubtitleSettings settings);
  /// 默认 null：直链源不需要 resolve。
  Future<SubtitleResolvedAsset?> resolve(
    SubtitleCandidate candidate, SubtitleQuery query, SubtitleSettings settings,
  ) async => null;
}
```

```dart
// core/subtitle_settings.dart —— 新增字段，JSON 键平铺在既有 subtitles 段内
final String assrtToken;    // 空 = 该源不启用（与安卓 isEnabled 同语义）
final bool xunleiEnabled;   // 默认 false
final bool shooterEnabled;  // 默认 false
bool get hasAssrt => assrtToken.trim().isNotEmpty;
// hasAnyProvider / 序列化 / == / copyWith / fromJson 全部覆盖新字段
```

```dart
// services/subtitle_match_service.dart
class SubtitleSearchReport {
  final List<SubtitleCandidate> candidates;   // 已打分排序
  final Map<String, String> failures;         // providerId → 可读原因
  final List<String> unavailable;             // 未配置/未启用的源 id
}
Future<SubtitleSearchReport> searchReport({required SubtitleQuery query, required SubtitleSettings settings});
Future<SubtitleResolvedAsset?> resolve(SubtitleCandidate candidate, {required SubtitleQuery query, required SubtitleSettings settings});
```

- [ ] 先写 `test/subtitle_settings_sources_test.dart`（新字段默认关、往返、`hasAnyProvider` 计入新源），跑出失败。
- [ ] 实现设置与模型字段；`copyWithScore` 携带 `payload`/`requiresResolve`（漏了会让打分后的候选丢掉下载信息）。
- [ ] 写 `test/subtitle_asset_store_test.dart`：纯文本下载按扩展名落盘；ZIP 取 `.ass` 优先、其余按小写路径字典序；路径穿越（`../`、绝对路径、盘符）拒绝；单条目 >32MB、累计 >64MB 拒绝；ZIP 内无字幕 → 抛 `zip_no_subtitle`；裁剪到最新 100 个。
- [ ] 实现 `SubtitleAssetStore`：`http.Client` 注入、15s 超时、非 2xx 抛 `SubtitleResolveException('http_<code>')`、魔数 `PK\x03\x04` 判 ZIP（不看文件名）。
- [ ] `subtitle_providers.dart` 改为 barrel（`export` 新目录），既有 `LocalSubtitleProvider`/`HttpSubtitleProvider` 迁入 `provider.dart` 同目录文件，**测试导入路径不变**。
- [ ] `rankSubtitleCandidates` 改为 分数降序 → `priority` 降序 → `providerId` 升序（保持稳定，避免列表跳动）。
- [ ] 跑 `test/phase9_subtitle_provider_test.dart` + 两个新测试，冻结 seam，广播契约给后续任务。

### Task 2 — ASSRT 适配器（subagent A）

**Boundary:** `lib/services/subtitle_providers/assrt_provider.dart`、`test/subtitle_assrt_provider_test.dart`。

**Consumes:** Task 1 的 `SubtitleProvider`/`SubtitleAssetStore`。

- [ ] 搜索：门禁 `status==0`；数组 `sub.subs`；`id` 取 `["id","fileid"]` 首个非空（空则跳过）；`name` 取 `["name","sub_name","m_version","m_title"]`；季/集解析复用 `core/tmdb_title.dart:332,350`（`sourceSeasonNumber`/`sourceEpisodeNumber`），年份复用 `:302`（`firstYear`）——**不要新写解析器**。
- [ ] 语言原样透传（D 见 §0），格式按 §0 逐字规则。
- [ ] 候选带 `requiresResolve: true`、`payload={id,format}`。
- [ ] resolve：`/sub/detail?id=` → `sub.subs[0].url` → `SubtitleAssetStore.download`；detail 非 0 → `detail_api_failed`，取不到 url → `download_url_missing`。
- [ ] 无 token / 空关键词 → **零请求**返回空。
- [ ] 测试用 `MockClient`：正常 2 条、`status!=0`、非 2xx、detail+ZIP 全链路（内存构造 zip）、无 token 时请求计数为 0。

### Task 3 — 迅雷适配器（subagent B）

**Boundary:** `lib/services/subtitle_providers/xunlei_provider.dart`、`test/subtitle_xunlei_provider_test.dart`。

- [ ] URL `quote` 编码关键词（空格 → `%20`，**不要**用 `+编码`）。
- [ ] 门禁 `code==0` 且 `result` 为空或 `ok`；数组 `data`；`url` 必填否则跳过。
- [ ] 语言归一与格式规则按 §0 逐字实现；测试用表驱动覆盖 `默认`/`简体中文`/`English`/`Bengali`（后者会命中 `en` 子串，属参考行为，照抄并写注释）。
- [ ] `id` 取 `["cid","gcid"]` 首个非空再回退 url；`score = max(score, fingerprintf_score)`；`payload={url,name,format}`；`requiresResolve: true`。
- [ ] resolve 单跳下载；扩展名取 `payload.name` 后缀，不在白名单则用 `format`。
- [ ] 空关键词零请求；非 2xx / `code!=0` → 空结果不外抛。

### Task 4 — 射手适配器（subagent C）

**Boundary:** `lib/services/subtitle_providers/shooter_provider.dart`、`test/subtitle_shooter_provider_test.dart`。

- [ ] `needsLocalMediaPath => true`；`query.mediaPath` 为空/非文件/`size < 12*1024` → **零请求**空结果。
- [ ] 哈希：offsets `[4096, size~/3*2, size~/3, size-4096*2]`（顺序照抄，注释写明「不得排序」），各读 4096 字节取 md5 小写 hex，`;` 连接。
- [ ] POST form 字段顺序 `filehash,pathinfo,format=json,lang`；`lang` 为 `eng` 当且仅当归一后语言是 `eng`，否则 `chn`；**只有 UA，无 Referer**。
- [ ] 解析：顶层必须是数组；遍历 `[].Files[]` 取 `Link`/`Ext`；`name = basename(mediaPath) + " | 射手 | " + format`；`score=120`；`payload={url,format}`。
- [ ] 测试用临时文件构造已知大小/内容，断言哈希逐字等于预期值（先用 Python 版算出常量写进测试，避免自证）。

### Task 5 — 搜索窗口 + 视觉取证（subagent D）

**Boundary:** 新建 `lib/ui/subtitle_search_dialog.dart`、`test/subtitle_search_dialog_test.dart`、`test/p0_6b_search_visual_capture_test.dart`、`docs/reference/evidence/p0-6b-search/README.md` + 该目录下的 PNG。

**Consumes:** `SubtitleSearchReport`、`SubtitleQuery`、`SubtitleCandidate`。

```dart
Future<SubtitleCandidate?> showSubtitleSearchDialog({
  required BuildContext context,
  required SubtitleQuery initialQuery,
  required Future<SubtitleSearchReport> Function(SubtitleQuery query) search,
  List<String> preferredLanguages = kDefaultSubtitleLanguages,
  Future<String?> Function()? pickLocalFile,   // 注入，测试不触原生窗口
});
```

- [ ] 窗口：`Dialog` 最大 720×520；首行关键词 + 季/集两格 + 「搜索」；语言筛选 ChoiceChip（全部 / 简 / 繁 / 英）；主体按源分组的候选列表，每行显示标题、`源 · 语言 · 格式 · 匹配分`；窗口内改词重搜不关窗。
- [ ] 四态可区分：初始（「输入关键词开始搜索」）、加载（「正在搜索 N 个源」）、空（列出未配置源与失败源及原因）、结果。
- [ ] 底部「选择本地文件…」走注入的 `pickLocalFile`；取消返回 null 不报错。
- [ ] 选中即 `Navigator.pop(candidate)`，下载/套用由调用方负责（窗口不触网、不写盘）。
- [ ] 视觉取证：复刻 `test/p1_4_menu_visual_capture_test.dart` 的口径——1280×720、`buildAppTheme(Brightness.dark)`、`test/support/test_fonts.dart` 注册 CJK、环境变量 `P0_6B_CAPTURE=1` 才写图。
  - **Before**：改动前两步流程（关键词对话框 + 结果底部弹窗），用 `git stash push -u -- apps/desktop-flutter/lib` 暂存实现后跑 `--plain-name 'A '`；**After**：同一 `search` 假数据下的新窗口。同场景、同视口、同主题。
  - README 记录：场景表、生成命令、Before 的来源方式。

### Task 6 — 设置页（subagent E）

**Boundary:** `lib/ui/subtitle_settings_page.dart`、`test/subtitle_settings_page_test.dart`。

- [ ] 新增三段：**ASSRT**（token，`obscureText` + 显示/隐藏切换，说明「留空则不启用」）、**迅雷**（开关，说明「免 token，按片名搜索」）、**射手**（开关，说明「只对本地文件播放有效」）。
- [ ] 保存沿用 `state.setSubtitleSettings`；保存后状态行如实反映「已启用 N 个源」。
- [ ] token 不回显进任何日志/提示；`test/subtitle_settings_page_test.dart` 覆盖三态（默认全关、填写后启用、清空后回到未配置）。

### Task 7 — 播放器接线与总验收（dispatcher，run 1）

**Boundary:** `lib/ui/player_page.dart`（仅字幕相关方法）、`lib/core/subtitle_provider.dart` 的 `deriveLocalMediaPath` 测试 `test/subtitle_query_media_path_test.dart`。

- [ ] `_subtitleQuery()` 增加 `mediaPath: deriveLocalMediaPath(_request.url)`（`player_page.dart:1204`）。
- [ ] `_showSubtitleSearch`（`:1329`）改为调用新窗口；自动匹配保持 8s 超时，手动搜索 15s。
- [ ] `_applySubtitleCandidate`（`:1274`）在 `requiresResolve` 时先 `resolve` 再装载，失败走既有 `_showSubtitleError`；记住匹配时存最终格式。
- [ ] `_showLocalSubtitlePicker`（`:1442`）改 `file_picker`，保留路径输入作为注入兜底（测试不触原生）。
- [ ] `_autoMatchSubtitle` 的 provider 集合自动包含新源（`buildSubtitleProviders` 已覆盖），无需改逻辑。

---

## 3. 验收标准（逐条可测）

| # | 标准 | 判据 |
| --- | --- | --- |
| A1 | 未配置零请求 | 三源全关 + 无 HTTP/本地 → `searchReport` 的 `unavailable` 含全部 id，MockClient 请求数 = 0 |
| A2 | 空态说真话 | 窗口在「全未配置」「有源失败」「无结果」三态下文案互不相同 |
| A3 | ASSRT 全链路 | MockClient 两次请求（search+detail），ZIP 解出 `.ass` 且最终 `format=ass`（D1） |
| A4 | ZIP 防护 | `../`、绝对路径、>32MB 条目、>64MB 累计各有一个拒绝用例 |
| A5 | 迅雷语言表 | `默认`→zh、`简体中文`→原样、`English`→原样、`Bengali`→原样（子串命中，注释说明） |
| A6 | 射手哈希 | 已知夹具算出定值哈希，与 Python 参考实现算出的常量逐字一致 |
| A7 | 射手不误伤 | 网络流播放（`mediaPath=null`）→ 零请求、空结果，UI 说明「仅本地文件」 |
| A8 | token 脱敏 | 捕获 LogService 输出，全流程不出现 token 明文 |
| A9 | 视觉证据 | `docs/reference/evidence/p0-6b-search/` 有 Before/After 各 ≥1 张，同场景同视口同主题 |
| A10 | 无回归 | `phase9_subtitle_provider_test`、`phase3_subtitle_test`、`subtitle_style_test` 全绿；`flutter analyze` 对改动文件无告警 |

运行方式（PATH 无 flutter）：

```bash
FL=/home/maple/.dsh/worktrees/webhtv-pc-d700b86c/dev3/.local/linux-build/flutter/bin/flutter
cd apps/desktop-flutter && $FL test test/subtitle_*.dart test/phase9_subtitle_provider_test.dart
```

---

## 4. 拓扑与派发

| 任务 | 归属 | 理由 |
| --- | --- | --- |
| Task 1 核心 seam | dispatcher（Lead-Core） | 契约同时被 4 个下游消费，先冻结合约再分叉 |
| Task 7 播放器接线 | dispatcher | 与 UI 子代理共用 `player_page` 语义，避免边界打架 |
| Task 2/3/4 三个适配器 | 3 个 subagent 并行 | 文件互不重叠、接口已冻结、协议已逐字给出 |
| Task 5 搜索窗口 | 1 个 subagent | 自包含 UI + 自取证 |
| Task 6 设置页 | 1 个 subagent | 自包含表单 |

每个 brief 的 Limits 默认为：尝试 3 次、编辑文件 ≤ 8 个、命令不限（测试运行不限）、仅限 Boundary 内。

---

## 5. 风险与明确不做

| 项 | 处理 |
| --- | --- |
| 三个第三方端点随时可能改协议/下线 | 每源独立适配器 + 失败隔离；空态如实报告失败原因，不静默 |
| ASSRT 需用户自行注册免费 token | 设置页写明获取方式；未填即不启用（不替用户猜） |
| 射手对网络流恒无结果 | UI 文案写明「仅本地文件」；不开 `autoMatch` 时也不打扰 |
| 缓存字幕文件增长 | D3 裁剪到最新 100 个 |
| **不做**：Python 脚本运行时 | 三个源各 <300 行 Dart 即可覆盖，引入 sidecar 是负债 |
| **不做**：迅雷 strict 内容 ID 加分 | §0.1 D4 |
| **不做**：ASSRT 之外的订阅/脚本源导入 UI | 安卓侧也未做（`docs/phase9/parity-2026-11-12/playback.md:15`） |

---

## 6. 实施结果（已落地）

| 任务 | 归属 | 落点 | 验收 |
| --- | --- | --- | --- |
| Task 1 核心 seam | dispatcher | `core/subtitle_provider.dart`、`core/subtitle_settings.dart`、`services/subtitle_providers/{provider,local_provider,http_provider,registry}.dart`、`services/subtitle_asset_store.dart`、`services/subtitle_match_service.dart` | `subtitle_settings_sources_test.dart`（6）+ `subtitle_asset_store_test.dart`（9）全绿 |
| Task 2 ASSRT | subagent | `services/subtitle_providers/assrt_provider.dart` | `subtitle_assrt_provider_test.dart`（13） |
| Task 3 迅雷 | subagent | `services/subtitle_providers/xunlei_provider.dart` | `subtitle_xunlei_provider_test.dart`（11） |
| Task 4 射手 | subagent | `services/subtitle_providers/shooter_provider.dart` | `subtitle_shooter_provider_test.dart`（17） |
| Task 5 搜索窗口 | subagent | `ui/subtitle_search_dialog.dart` | `subtitle_search_dialog_test.dart`（12）+ 视觉取证 |
| Task 6 设置页 | subagent | `ui/subtitle_settings_page.dart` | `subtitle_settings_page_test.dart`（5） |
| Task 7 播放器接线 | dispatcher | `ui/player_page.dart`：`mediaPath` 推导、`_subtitleService()` 口径、`requiresResolve` 时先 resolve、搜索窗口入口、原生文件选择 | 全量 126 用例绿；`p0_6b_after_entry_capture_test.dart` |

### 复核中修掉的缺陷（都是「与参考实现不一致」，不是口味）

1. **射手 `pathinfo` 未 form-encode**：Python 参考用 `requests` 的 `data=`，本身就百分号编码；不编码时含空格/& 的 Windows 路径会被截断或注入额外字段。已改为 `Uri.encodeComponent` 并加断言（无裸空格、`&` 只剩 3 个分隔符）。
2. **射手 format 未过白名单**：`shooter.py:27-29` 对**最终值**（含 Ext 分支）过白名单，非 `ass/ssa/srt/vtt` 一律 `srt`。原实现让 `Ext='zip'` 穿透，会落出非字幕文件让 mpv 建不出轨。已修并加 4 条断言。
3. **视觉证据两次假通过**：`find.byType(RepaintBoundary).first` 拍到的是视频层（图上没有对话框，但断言过了）；以及默认字族 `FlutterTest` 把数字/部分 CJK 画成实心方块。两处都改为显式根边界 + 主字族注入，证据与复现步骤见 `docs/reference/evidence/p0-6b-search/README.md`。

### 实现期间确认的事实（供后续维护）

- 迅雷的编码不能写成 `Uri(queryParameters:)`——那是 form 编码，空格变 `+`。参考实现用 `quote`（%20），必须 `Uri.encodeComponent` + `replace(query:)`。
- ASSRT 用 `Uri.https(host, path, queryParameters)`（空格 → `+`）与参考实现的 `urlencode` 一致，**不要**"统一"成 %20。
- `SubtitleProvider` 用 `implements` 时会连具体成员一起要求实现（`priority`/`needsLocalMediaPath`/`resolve`）；`test/phase9_subtitle_provider_test.dart` 的 `_FakeProvider` 因此补了三个成员。

### 未做（与计划的偏差账）

- §0.1 D1–D5 全部按计划执行；D5（不解析年份）已在上表登记。
- 迅雷的 `lang` 在 form 里恒为 `chn`：`SubtitleQuery` 没有语言字段，参考实现的 eng 分支在当前契约下不可达（已导出 `shooterLanguageOf`/`shooter` 侧的归一函数并单测覆盖）。
