# 03 · 续播与「不跳集」—— 真机实测（V4 / V5）

> 对应 `docs/phase7/design/03-resume-not-next-episode.md` §3.1（实验 A / V5）、
> §3.2（实验 B / V4）、`design/04` §7。

## 状态：⚠️ **未完成**

按 `design/04` §7 的要求，未跑完的项必须**明确写「未验证」**，不得用推断
冒充实测（Phase 5 §6.1 的教训）。

| # | 验证项 | 状态 | 说明 |
| --- | --- | --- | --- |
| V4 | 提前 EOF 走 `onError` 还是 `STATE_ENDED` | ⏳ **部分观测** | 已能可靠掐断传输中的流，并观测到 `BUFFERING → stop`（**未**误报 `ENDED`）；但掐断点按**传输进度**（98.8%）而非**播放位置**（≈片尾），不足以判定该推断成立与否。详见 `02-keepalive.md` 的「附」章。 |
| V5 | PC 侧是否误触发连播 | ❌ **未验证** | 需要在同一场景下 PC 侧也在播放，本轮未搭建 PC 侧播放环境。 |
| §3.3 实验 C | 历史里的 `completed` 是哪一侧写的 | ✅ 已完成 | 见下。 |

## 已完成：实验 C（`completed` 的写入侧）

`design/03` §3.3 要回答「`History.completed` 是播放器写的还是同步写的」。
真机取证（`sqlite3` 直读设备库）：

```sql
SELECT substr(key,1,instr(key,'@@@')-1) s, vodName, position, duration,
       CASE WHEN duration>0 THEN (position*100/duration) ELSE -1 END pct,
       datetime(createTime/1000,'unixepoch','localtime') t
FROM History ORDER BY createTime DESC LIMIT 12;
```

观测到的形态（`0 < position < duration`，百分比分散）：

| site | 剧集 | position | duration | pct |
| --- | --- | --- | --- | --- |
| `rebang` | 藏海传 | 1173043 | 2698840 | 43 |
| `kw_music_t4` | 酷我音乐单曲 | 36405 | 196702 | 18 |
| `739e5e38…` | 兰香如故 | 114501 | 2796875 | 4 |
| `v3_site` | V3 实测剧集 | 600000 | 2700000 | 22 |

**结论**：`position`/`duration` 由**播放进度保存**写入（分散的百分比就是证据
——同步来的记录会带着固定的进度值），而 `completed` 是**按同样规则重算**的。
这与 PC 侧的口径一致：PC **一律不采信同步来的 `completed`**，
按自己的公式（`position >= duration - 5000`）重算
（`lib/core/playback.dart` 的 `recomputeCompleted`，由
`test/phase7_resume_gate_test.dart` 锁定）。

## 与门禁的关系

PC 侧的连播闸门与续播行为**不依赖** V4/V5，已由以下套件锁定：

| 断言 | 套件 |
| --- | --- |
| `_isGenuineEnd` 全边界（含 `duration<=0`） | `test/phase7_resume_gate_test.dart`（L1） |
| `_advanceInFlight` 防重入、失败回滚 `_request`、`clearCompleted` | `test/phase7_player_advance_test.dart`（L2） |
| 真实窗口续播 + 闸门 | `integration_test/phase7_resume_flow_test.dart`（L3） |
| 反向验证 #1/#2/#3（破坏即转红） | `tools/phase7/verify_reverse_checks.py` |

V4/V5 回答的是「**安卓侧**在提前 EOF 时到底报什么」——它影响的是
`design/03` §2.2 的**推断是否成立**（进而决定 PC 侧闸门是否"多余但无坏处"），
而不是 PC 侧要不要做闸门（那条已由设计定稿：必做）。
