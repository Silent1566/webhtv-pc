# 03 · P0 直播设计（回看 / 直播设置 / 源级回退）

- 覆盖缺口：P0-8（`docs/phase9/README.md` §4.1）
- 上游依据：安卓 `webtv2@77e2fbefdc`（`bean/Catchup.java`、`api/parser/LiveParser.java`、`api/LiveApi.java`、`setting/LiveSetting.java`）
- 涉及 PC 模块：`lib/ui/live_page.dart`、`lib/services/live_service.dart`、`lib/services/epg_service.dart`、`lib/core/live_playlist.dart`、`lib/core/epg.dart`、`lib/state/app_state.dart`

---

## 0. 不变量

1. **直播地址即最终地址**：回看地址由模板生成，不经过站点 `play`；但仍遵守代理与凭据策略，不得绕过安全边界。
2. **没有就是没有**：频道没有 catchup 时不显示「回看」入口，不猜测、不伪造。
3. **失败可切**：回看失败可回直播/切线路/切源；单频道失败不阻塞其他频道。
4. **EPG 是增强项**：EPG 缺失时直播照常播；回看入口依赖 EPG 节目单时，明确提示「无节目单，无法回看」。
5. **设置默认等于现状**：`sourceFallback` 默认开启（与安卓一致），其余缺省不改变当前行为。

---

## 1. 现状

- `live_service.dart` 已解析 M3U（`#EXTINF`/`group-title`/`tvg-*`/`#EXTVLCOPT`/`#EXTHTTP`）、TXT（`分组,#genre#`）、JSON。
- `live_page.dart` 已实现：源/分组/频道树、多线路选择、播放失败按序切线路、EPG 当前节目与节目单。
- `LiveChannel` 有 `urls`、`epgId`、`tvgName` 等字段；无 `catchup`。
- 播放是 `PlaybackRequest(directUrl: true)`，直接给媒体地址。

---

## 2. Catchup 模型（对齐 `Catchup.java`）

### 2.1 字段

| 字段 | 含义 | 示例 |
| --- | --- | --- |
| `type` | `default`（source 即完整地址）或 `append`（在频道地址后追加） | `append` |
| `source` | 时间模板；含 `${(b)fmt}`（开始）、`${(e)fmt}`（结束）、`${utc:}`、`${utcend:}` | `?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}` |
| `regex` | 频道地址匹配（append 时可做替换定位） | `/PLTV/` |
| `replace` | 逗号分隔的 `from,to` 正则替换 | `/PLTV/,/TVOD/` |
| `days` | 可回看天数（信息展示用，不参与拼接） | `7` |

### 2.2 模板求值

```dart
String? formatCatchupUrl({
  required CatchupSpec spec,
  required String channelUrl,
  required int startMs,
  required int endMs,
});
```

规则（必须逐条对齐上游，避免「PC 生成的地址安卓能播、PC 不能播」）：

1. `${(b)fmt}` → `startMs` 按**本地时区**格式化；`${(e)fmt}` → `endMs`；
2. `fmt == "timestamp"` → 秒级时间戳；`${utc:}`/`${utcend:}` → 秒级 UTC 时间戳；
3. `type == "default"` → 直接返回渲染后的 `source`（不拼 `channelUrl`）；
4. `type == "append"`：
   - `replace` 有逗号 → 对 `channelUrl` 做 `from`→`to` 正则替换；
   - 若 `channelUrl` 已有 query，模板里的 `?` 改成 `&`；
   - 返回 `channelUrl + rendered`；
5. 任何一步失败（正则非法、时间缺失）→ 返回 null，UI 不显示回看入口，日志 `scope=live-catchup`。

### 2.3 来源优先级

1. 频道级 `catchup`（M3U 的 `catchup` / `catchup-source` / `catchup-replace` 属性，或 JSON 频道字段）；
2. 源级默认 `catchup`（`lives[].catchup`，若有）；
3. 无 → 不回看。

`days` 只用于展示「可回看 N 天」，不参与 URL。

---

## 3. 回看交互

### 3.1 入口

- 直播页频道行右侧「回看」按钮；播放器内右键「回看节目单」。
- 点击后打开节目单：按 EPG 节目列表（`EpgChannelGuide.programs`）展示，已结束且在过去 `days` 天内的节目可点；正在播出的节目显示「直播中」不可回看。
- 无 EPG：按钮显示但禁用 + 说明「无节目单，无法回看」；无 catchup：入口不渲染。

### 3.2 播放

- 生成 `catchupUrl` 后构造 `PlaybackRequest(directUrl: true, title: '<频道> <节目名>')`。
- 支持 seek：回看地址是点播语义（通常 HLS/TS），沿用 `player_page` 的 seek 与进度条；不得强制 `live` 模式隐藏进度条。
- 播放器 OSD 标注「回看 · <节目名>」，避免用户误以为直播延时。

### 3.3 失败

- 回看失败 → 提示 + 「回到直播」按钮（切回原频道当前地址）。
- 连续两个节目失败 → 记录该频道「回看不可用」，本会话不再自动推荐（用户仍可手点）。

---

## 4. 源级回退

现状只有「同一频道多线路按序切」。新增源级：

```text
当前源的所有线路都失败
  └─ sourceFallback 开启？
        ├─ 是 → 按配置顺序尝试下一个直播源中的同名频道（名称归一化匹配）
        └─ 否 → 如实报错，停在当前源
```

- 名称归一化：去空白、全角转半角、去掉「高清/HD/4K」等后缀后再比；匹配不到则不跨源。
- 每次跨源记录日志（从哪个源到哪个源、原因），UI 提示「已切换到 <源名>」。
- 跨源不改变用户当前选中的源（会话级临时切换）；退出直播页恢复。

---

## 5. 直播设置

`lib/core/live_settings.dart`，落 `settings.json` 的 `live` 区块：

| 键 | 默认 | 说明 | 是否迁移 |
| --- | --- | --- | --- |
| `sourceFallback` | true | 源级回退 | 是 |
| `changeLine` | true | 当前线路失败自动换线（现状已硬编码为开） | 是（已暴露开关并接线） |
| `acrossGroups` | true | 快捷键切台时是否跨分组 | **否**（桌面暂无跨分组切台 UI，避免设置项无行为） |
| `scale` | 继承播放器 | 直播画面比例 | 是 |
| `bootLive` | false | 开机进直播 | 否（桌面无开机自启语义） |
| `listStyle` | classic | 列表皮肤 | 否（PC 有自己的设计系统，不迁移皮肤） |
| `invert` | false | 上下键反向 | 否（桌面用滚轮/方向键语义不同，避免误映射） |

---

## 6. 数据与设置

- 频道/分组/线路模型扩展：`LiveChannel` 增 `CatchupSpec? catchup`；`LiveSource` 增 `CatchupSpec? catchup`。
- 不需要新表；收藏（如后续要做）另立需求，不在本阶段（`webtv2` 基线没有直播收藏）。
- `settings.json` 增 `live` 区块，缺省等价现状。

---

## 7. 测试

| 层 | 用例 |
| --- | --- |
| L1 | 模板渲染：`${(b)yyyyMMddHHmmss}`、`timestamp`、`utc:`、`utcend:`；`default` 不拼接；`append` 的 `?`→`&`；`replace` 正则；非法正则/缺时间返回 null |
| L2 | 无 catchup 不渲染入口；无 EPG 时入口禁用并给原因；设置持久化 |
| L3 | fixture M3U（带 catchup）→ 选节目 → 回看地址请求命中 fixture → 可播放并 seek；全线路失败 → 跨源切换生效（fixture 两源同名频道） |

反向验证（≥2）：把 `${(e)` 渲染成开始时间应红；把 `default` 也拼接频道地址应红。

---

## 8. 风险

| 风险 | 缓解 |
| --- | --- |
| 时区/格式差异导致回看地址不可用 | L1 锁定格式；L3 用 fixture 断言完整 URL 字符串 |
| catchup 地址绕过代理/凭据策略 | 回看请求仍走现有 HTTP 客户端与代理策略，不新增旁路 |
| EPG 节目单缺失 | 明确禁用与提示，不猜时间段 |
| 跨源同名频道误匹配 | 归一化 + 只在本会话内临时切换 + 日志可追溯 |
