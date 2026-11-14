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

- `subtitle_service.dart` 已能从 URL 或本地路径（含 Windows 盘符）加载，编码兜底（BOM → charset → UTF-8 → GBK），格式 `srt/ass/ssa/vtt/sub`。
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
| 字幕编码非法 | 沿用现有 `subtitleDecode` 语义，提示 |
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

- 手动搜索：关键词 + 结果列表（标题/集/条数/来源）；选择后加载并写记忆。
- 记忆表 `danmaku_match`：唯一键 `(site_key, vod_id, episode_name)`；提供「忘记本集/本片」。
- 关闭自动搜索后：不发起任何库请求（fixture 计数断言）。

### 2.4 显示参数（对齐 `DanmakuSetting`）

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
- 弹幕库同样采用通用 HTTP 契约；自动搜索受 `autoSearch` 与 `apiUrl` 双开关约束。
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
