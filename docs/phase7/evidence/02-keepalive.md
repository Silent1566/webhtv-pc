# 02 · 保活与唤醒 —— 真机实测（V1 / V2）

> 对应 `docs/phase7/design/02-android-keepalive-and-wake.md` §6.1（O1）、§6.2（O2）。
> 本文件是**真实设备实测**，不是推断。采集于 2026-10-18。

## 设备与前置

| 项 | 值 |
| --- | --- |
| 设备 | `192.168.50.3:5561`（LDPlayer，OnePlus HD1910 / `com.silent.android.webhtv`） |
| 应用 | `5.6.0-202610171140`（含 T19 交付的 A + C） |
| 连接方式 | `adb forward tcp:19981 tcp:9978`（模拟器 NAT，PC 无法直连 9978） |
| 管理页 | 已启动（`ManageService` 在跑，9978 监听） |
| 站点 | `csp_Media`（当前生效配置 cid=1 内的 170 个站点之一） |

> **为什么用 5561 而不是 5555/5557/5559**：那三台装的是 `com.fongmi.android.tv`
> `5.6.0`（更新于 2026-09-27 / 10-08），**不含** `/api/playback/history`
> （实测返回 `200 + application/octet-stream`，正是 `design/01` §4.1 记录的
> 「第二个阻塞性发现」形态）。5561 上的 `com.silent.android.webhtv` 才是 T19 之后
> 的包。**踩坑记录**：webtv4 的 `applicationId` 是 `com.silent.android.webhtv`，
> 不是 `com.fongmi.android.tv`——一开始测错了包，看到的全是旧行为。

## V1（O1）：息屏后 `/api/playback/current` 是否仍可读

| 时点 | 屏幕状态 | `/manage/session` | `/api/playback/history?siteKey=csp_Media&limit=1` | `/api/playback/current?siteKey=csp_Media` |
| --- | --- | --- | --- | --- |
| 息屏前基线 | `Awake` | `200` JSON `8.7 ms` | `200` JSON `60.0 ms` | `404` JSON `45.2 ms` |
| 息屏 60 s 后 | `Asleep` | `200` JSON **`4071.9 ms`** | `200` JSON `7.0 ms` | `404` JSON `6.7 ms` |

**结论（回答 O1）**：✅ **息屏 60 s 后端点仍可读**，且响应时间与息屏前同量级
（读数端点 7 ms 级）。

- `current` 的 `404` 是**合法形态**（「当前没有在播放的记录」），不是失败
  ——`design/00` §3.1 契约 3 已固化这一口径，PC 侧把它排除在退避之外。
- 息屏后的**首**个请求（`/manage/session`）耗时 4.07 s，而紧接着的读数请求
  只要 7 ms：这不是网络抖动，而是**进程从低功耗状态被唤醒**的特征（见 V2）。

## V2（O2）：`/manage/session` 能否唤醒

在同一息屏状态下，`/manage/session` 是**第一个**被发出的请求：

```text
息屏 60s 后：
  1) GET /manage/session   → 200  4071.9 ms   ← 慢：唤醒动作本身
  2) GET /api/playback/history?... → 200   7.0 ms   ← 快：已被唤醒
  3) GET /api/playback/current?... → 404   6.7 ms   ← 快
```

**结论（回答 O2）**：✅ **`/manage/session` 能唤醒**——首个请求付出 4 s 唤醒成本，
之后同一进程内的请求恢复到毫秒级。

推论（`design/02` §5.1 的唤醒阶梯直接可用）：

| 观察 | 含义 | 对设计的支持 |
| --- | --- | --- |
| 首个 `/manage/session` 成功但慢 | 服务活着，进程被降频/浅睡 | **L1**（`touch /manage/session`）足够唤醒，不需要 L2/L3 |
| 后续请求 7 ms | 唤醒确实生效 | 恢复后「立刻补一轮轮询」（§5.2）可行 |
| 全程无 `Connection refused` / 超时 | 未进入 `SERVICE_STOPPED` / `PEER_FROZEN` | 三态判定的「正常」分支被真实覆盖 |

## 会话字段快照（H3 状态采集）

息屏状态下 `GET /manage/session` 的响应（`design/02` §3.2 H3 要采集的字段）：

| 字段 | 值 | 解读 |
| --- | --- | --- |
| `running` | `false` | **管理页 Dialog 未打开**（`ManageService` 仍在跑，见下两行） |
| `serverRunning` | `true` | 局域网 Server 在跑 |
| `wakeLock` | `false` | 未持唤醒锁 |
| `wifiLock` | `false` | 未持 WiFi 锁 |
| `batteryOptimized` | `true` | **仍受电池优化限制** |
| `backgroundSettingsNeeded` | `true` | 需要引导用户去设置 |
| `backgroundGuided` | `false` | 用户尚未处理过 |
| `lastAccess` | `1792288705549` | 被本次请求刷新（保活生效） |
| `idleTimeout` | `600000` | 10 min 空闲自杀（与 `ManageService.IDLE_TIMEOUT` 一致） |
| `backgroundGuide` | `"设置 → 应用 → 本应用 → 电池 → 选择不受限制/不优化；..."` | 安卓侧品牌自适应文案 |

**三条对实现的直接含义**：

1. **`running=false` 但 `serverRunning=true` 是正常共存态**（管理页 Dialog 关了、
   服务还在跑）。按 `design/02` §3.3，此时**仍可轮询**，但要提示「管理页未运行，
   息屏后可能失联」——PC 侧不能把 `running=false` 当成整体不可用。
2. **`batteryOptimized=true` + `backgroundSettingsNeeded=true`**：该设备正是
   L5 引导的目标场景，UI 应给出「打开安卓后台设置」按钮（需用户点击）。
3. **`backgroundGuide` 文案必须原样显示**（`design/02` §5.3）——PC 自造文案会让
   用户按错误的菜单名去找。

## 与门禁的关系

本文件是**实测留痕**，不作为门禁（`design/04` §7：真机验证不阻断门禁）。
三态判定的**逻辑**由 `test/phase7_keepalive_test.dart`（L1）与
`integration_test/phase7_keepalive_flow_test.dart`（L3，真实 socket）锁定；
本文件回答的是「真机上到底是哪一种状态」。

---

## 附：V4（提前 EOF 行为）的**部分**观测（未完成，不作结论）

按 `design/03` §3.2（实验 B）尝试在真机上制造「接近片尾时数据源断掉」。
工具：`tools/phase7/v4_cuttable_media.py`（支持 Range + 可中途掐断 + 可限速）。

### 做过的两次尝试

| 轮次 | 设置 | 掐断时机 | logcat 结果 |
| --- | --- | --- | --- |
| 1 | 不限速 | 起播 45 s 后 | **无效**：4.4 MB 在数秒内被一次性拉完（`served bytes=4372373/4372373`），片尾数据早已在本地缓冲，掐断伤不到任何数据。 |
| 2 | 限速 `100 KB/s` | 同一请求传到 `4325376/4372325`（≈98.8%）时 | **有效**：播放器进入 `state=BUFFERING`，随后 `state changed state=2 ... stop=true`；**全程未出现 `state=ENDED`，也未出现 `audio-auto-next ... action=browse-next`**。 |

### 能说到什么程度

- ✅ 该工具已能**可靠掐断传输中**的流（第 2 轮实测）。
- ✅ 在这台设备 + 这个媒体上，掐断后安卓走的是 **`BUFFERING` → `stop`**，
  **没有**误报 `STATE_ENDED`，因此**没有**触发 `audio-auto-next`。
- ❌ **不足以断言** `design/03` §2.2 的推断（"安卓在缓存耗尽时可能报
  `STATE_ENDED`"）被推翻：本次掐断点落在 98.8%，而播放位置并不正好在片尾
  最后一秒；要复现该推断需要「播放位置已到 `duration - 少量` 且此刻回源失败」。
- ❌ V5（PC 侧是否误触发连播）**未做**——它要求同一场景下 PC 侧也在播放并观察
  `_maybeAdvanceOnGenuineEnd` 的行为，本轮没有搭建 PC 侧播放环境。

### 复现方式（留给下一轮）

```bash
# 1) 起可掐断媒体（限速接近「字节数/时长」，否则播放器会一次性拉完）
py -3 tools/phase7/v4_cuttable_media.py --port 18090 --rate-kbps 100 \
      --file <trailer.mp4>

# 2) 让设备可达
adb -s <device> reverse tcp:19991 tcp:18090

# 3) 设备起播
adb -s <device> shell "am start -a android.intent.action.VIEW \
  -d 'http://127.0.0.1:19991/media' -t 'video/mp4' \
  -n <pkg>/com.fongmi.android.tv.ui.activity.HomeActivity"

# 4) 在**播放位置接近 duration** 时掐断（关键：不是按传输进度，而是按播放进度）
curl http://127.0.0.1:18090/__cut

# 5) 抓标签
adb -s <device> logcat -d | grep -E "playback-flow|playback-lifecycle|audio-auto-next"
```

> **诚实标注**：`design/04` §7 要求「未跑真机验证时必须写明未验证，不得用推断
> 冒充实测」。V4/V5 属于**未完成**，上面第 2 轮只记录观测事实，不作为
> 「D1/D2 不存在」的证据。PC 侧的连播闸门仍以
> `test/phase7_player_advance_test.dart` / `phase7_resume_gate_test.dart` 为准。
