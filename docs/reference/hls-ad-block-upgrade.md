# HLS 广告插播处理：一手来源核实与迁移结论

调研日期：2026-11-26（只读侦察，未修改任何代码）
核对基线：`webhtv` dev5 @ `13050a007b`；Win-box `main` @ `80668243a783addda747d89cb4d48ab164966e30`

## 0. 结论：先纠正一个陈旧前提

- 本地 `app/src/main/java/com/fongmi/android/tv/server/process/M3u8.java` **不含 `purify()`**
  （`Select-String -Pattern purify -SimpleMatch` 命中 **0** 次）。它是 m3u8 代理 Process：取上游 →
  `HlsAdblockPipeline.apply(...)`（:100-102）→ URI 重写（:140-175）。
- 所以"本仓库已移植 TVBox `purify()`"的说法不成立。当前安卓侧去广告 = 规则清洗
  （`HlsManifestCleaner`）+ 库级兜底（`HlsAdsParser`，`HlsAdblockPipeline.java:3`，**源码不在本仓库 → 未核实**）。
- `docs/reference/win-box-borrowings.md:370-405` 描述的"五级链 / 三道回退"与 Win-box 源码**一致**（下文逐条给行号），
  但它描述的是 **Win-box**，不是本项目已实现物。

## 1. 三处一手来源

| 来源 | 已确认行为（阈值原值） | 证据 | 误删风险 |
|---|---|---|---|
| 本地安卓 structured cleaner | 4 个闸+整体回退，全部命中即放弃清洗；无启发式猜测 | `HlsManifestCleaner.java:16-21,29-32,56-60,63-77` | 低（只按显式规则删）；但缺 IV 守卫（见 §3） |
| Win-box `m3u8Purify.ts`（MIT） | 五级启发式 + 单级/累计/可播三道回退 | `src/engine/util/m3u8Purify.ts:861,740,773,561,644,476,1010,1015` | 中高（少数派/短组/标记三类都会误删） |
| RFC 8216 | 隐式 IV 依赖媒体序号；MAP/序号/不连续不可随意动 | `rfc8216.txt:2046-2050,905-907,1217,1250,1046` | —（规范约束，不是实现） |

### 1.1 本地安卓 cleaner 的真实契约（`HlsManifestCleaner.java`）

- 常量原值 :16-21：`MAX_REMOVAL_RATIO = 0.35`、`MAX_REMOVED_DURATION_SEC = 90`、
  `MAX_MANIFEST_CHARS = 2*1024*1024`、`MAX_MANIFEST_LINES = 20_000`、
  `MAX_REGEX_COUNT = 32`、`MAX_REGEX_LENGTH = 512`。
- 结构闸 :29-32：`#EXT-X-BYTERANGE`、`#EXT-X-SKIP:`、`#EXT-X-PART:`、`#EXT-X-PRELOAD-HINT:` 任一存在 → `fallback`。
- 整体回退 :56-60：0 段、全删、`removed/total > 0.35`、`removedDuration > 90s` 任一 → 回原文。
- 直播（无 `ENDLIST`）:63-77：只允许删**前缀**（出现"保留段之后仍有删除"即回退），且清单必须已含
  `#EXT-X-MEDIA-SEQUENCE:` / `#EXT-X-DISCONTINUITY-SEQUENCE:` 才允许删（因为要 +序号，:193-210）。
- 分片级标签 :212-229：删分片时连带删其 `#EXT-X-DISCONTINUITY` / `#EXT-X-PROGRAM-DATE-TIME` 前缀；
  `#EXT-X-KEY` / `#EXT-X-MAP` 按"透明状态标签"保留（:226-229）→ 语义上等于"假设删广告不破坏解密/init"。

### 1.2 Win-box 五级链（逐级 + 原值 + 行号）

1. `removeMinorityUrl` :861-951 — 主导者按 `tsUrlPre` 前缀或 host 计票（:848-859，`TIMES_NO_AD = 15` :50）；
   **单级阀 :946 `adCount > 总段数 * 0.3` → 该级作废并清零计数**。
2. `clean` :740-749 — 订阅 `rules[].regex` 中带 `#EXT-X-DISCONTINUITY`/`#EXTINF` 的规则整段删（:744）。
3. `cleanCommonAdMarkers` :773-834 — `#EXT-X-CUE-OUT` 进入 `inAdBreak`（:795-797），`#EXT-X-CUE-IN` 复位（:787-793）；
   **广告期内的媒体行整行丢弃**（:822-826），即"标记 + 其间的分片"一起删。信号标签集 :230-240
   （OATCLS-SCTE35 / X-SCTE35 / SPLICEPOINT-SCTE35 / CUE* / ASSET / VMAP-AD-BREAK / AD）；
   独立广告标签 `DATERANGE` :265-269；广告 URI 正则 :42；广告域名关键词表 10 项 :44-47（按约定不复写）。
4. `cleanDecimalPrecisionGroups` :561-612 — `EXTINF` 小数精度分组；`MAX_FRAME_RATE_AD_BLOCK_SIZE = 12` :49；
   放弃条件 :599：`removableSegments > 该级上限` 或 `> 总段数 * 0.3`。
5. `cleanFrameRateGroups` :644-676 — 同上，按 23.976/24/25/30 帧率特征判定（:353-364）。
6. 末级 `cleanDiscontinuityGroups` :476-495 — `shouldDropGroup` :463-474：`段数 ≤ 2` 或
   `组总时长 < 主导组总时长 * 0.18`，且需 `adLike`（广告特征 / 跨 host / 短组且不同路径）。
- 分级删除上限 `getAdSegmentLimit` :338-349：总时长 ≤30min→**18**，≤60→**24**，≤90→**30**，否则 **36** 段。

三道回退（原值）：

| 回退 | 触发条件 | 行号 |
|---|---|---|
| 累计上限 | `adCount > 总段数 * 0.5` → 整体回原文 | :1010-1014 |
| 可播性 | `!isPlayableMediaPlaylist(result)` → 整体回原文 | :1015-1019；判定 :522-540（须有段、不得连续两个 `EXTINF`、`EXTINF` 不得紧跟 `ENDLIST`、不得以悬挂 `EXTINF` 结束） |
| 清单补全 | `keepVodEndList` :542-546，原文有 `ENDLIST` 而结果丢了就补回 | :1007 |

入口自律：`purifyVodM3u8` :1031-1039 只处理**含 `ENDLIST` 的点播清单**（注释 :1026-1030 说明直播不参与）。

## 2. 三类策略对比（含误删风险）

| 策略 | 代表实现（已确认） | 误删风险 |
|---|---|---|
| 少数派 URL（删非主导域名/路径前缀的段） | Win-box :861-951；单级 30% 阀 :946 | **高**：真正的多 CDN 回源、灰度切流、加密与非加密段混排都会被判"少数派"；`0.3` 只是经验值，无公开统计依据 |
| 短不连续组（≤2 段或 <主导 18%、12 段上限、18/24/30/36 段） | Win-box :463-474,338-349,49 | **中高**：正片里的短插叙/片头/回看片段同样短；0.18 与 12 无出处分 |
| 广告标记（CUE-OUT/CUE-IN、SCTE35、DATERANGE） | Win-box :773-834,230-269；RFC :1046,1108 | **中**：删"标记"本身基本无害（播放器只是少了提示），但 Win-box 连广告期内的媒体行一起删（:822-826），一旦 CUE-IN 缺失（:832 直接丢弃 pending）就会删掉后面整段正片 |

## 3. 规范层面的硬约束（三个实现都踩过或绕过的点）

- **隐式 IV**：RFC 8216 §5.2（:2046-2050）规定无 `IV` 属性时 **用媒体序号当 IV**。删任何一个分片都会改变后随分片的序号 → 解密错位。
  - Win-box：只把 `#EXT-X-KEY` 当行类型（:31-32），**无 IV 检查**；本地安卓 `HlsManifestCleaner` 也只"保留"KEY/MAP（:226-229），**无 IV 检查**。
  - PC 侧 `apps/desktop-flutter/lib/core/ad_rules.dart:250-268` 是三者中唯一有 IV 闸的（`METHOD != NONE` 且无 `IV` → 放弃清洗），`:327-333` 再有 50% + 可播兜底。**迁移时不得把这个闸丢掉**。
- **MAP**：§4.3.2.5（:905-907）`EXT-X-MAP` 对后随所有分片生效；删广告分片却留其 MAP 会让正片用广告 init 段。
- **序号/不连续**：§4.3.3.2（:1217）、§4.3.3.3（:1250）；安卓实现只在"删前缀"时才 +序号（:63-77），这是比 Win-box 更保守也更正确的取舍。
- **DATERANGE**：§4.3.2.7（:978）`SCTE35-OUT` 是 `EXT-X-DATERANGE` 的属性（:1046,1108），不是独立标签；把它当"整段广告"依据需要同时看 `DURATION`/`END-ON-NEXT`，Win-box 只做标签存在性判断（:265-269）。

## 4. 迁移结论（最小改动口径）

1. **不要移植 Win-box 码**：0.3 / 0.18 / 12 / 18-36 全是无统计依据的魔法数，且缺 IV/序号守卫。只把它当"算法参考 + 已实现清单"。
2. 若要启发式，最多移植两级：③ 广告标记块（需要 CUE-IN 存在性检查，缺失即放弃）+ ① 少数派 URL（需要 ≥3 个 host 且单级 30% 阀）。
3. 真正低风险增量是**规则语料与格式**，不是启发式：现有 `HlsAdRule`（`ad_rules.dart:21-71`）已能承载 host/URL/时长/不连续/跨域信号，把 CUE-OUT/DATERANGE 作为**信号**（提高 `minimumSignals`）而不是删除依据。
4. 串联顺序建议：IV/BYTERANGE/低延迟闸 → 规则清洗（现状）→（可选，默认关）启发式 → `isPlayable` + 50% 累计兜底。三道回退是这类功能唯一的安全阀。

## 5. 未核实 / to verify

- **media3 `HlsAdsParser`**：`HlsAdblockPipeline.java:3` 只导入，源码不在本仓库，行为与版本 **未核实**；不得描述为"TVBox purify 移植"。
- **TVBox 原始 `util/M3u8.java`**：`CatVodTVOfficial/TVBoxOSC` 已不可访问（`git ls-remote` → `Repository not found`），
  `j4Uq/TVBoxOSC` 候选路径（`com/github/tvbox/osc/util/M3u8.java` 等）全部 404 → 原值只能间接引用 Win-box 注释里的
  `M3u8.java:NN`（:46/:50/:106/:233-243/:249-364/:522-584 等），**to verify**。
- **FongMi/TV@fongmi**：`app/src/main/java/com/fongmi/android/tv/{utils,server/process}/M3u8.java` 三个候选路径均 404
  （`README.md` 可取，说明网络正常）→ 上游是否存在 `purify()` **未确认**；本地 fork 该文件命中 0 次。
- **许可**：Win-box `LICENSE` = MIT（已取原文，Copyright (c) 2026 yagami-hue）；TVBox 上游许可未核实。
  故本笔记只记录算法与 URL，不复制任何实现代码。
