# 06 · 详情身份兜底：上游漏填 `vod_id`/`vod_name` 时不再整条丢弃

- 状态：**已实现**（PC `webhtv-pc/dev1`；安卓侧**无需改动**）
- 日期：2026-10-28
- 适用工程：`apps/desktop-flutter`
- 上游参考：`app/src/main/java/com/fongmi/android/tv/server/process/VodApi.java`（`handle` / `formatContent` / `vodJson`）、`app/src/main/java/com/fongmi/android/tv/api/SiteApi.java`（`detailContent`）
- 主设计文档：`docs/webhtv-pc-design.md` §28（安卓桥接）
- 关联：`01`（T4 网关契约 §3）、`04`（多源化）
- 触发：用户真机日志（2026-10-28 10:51）

---

## 1. 问题：一条详情失败，整部剧打不开

用户在「嗷呜」配置下点开一部韩剧，详情页空白，日志原文：

```text
[site] 详情加载失败 site=Hxq vod=Bkp_OaNRYo16PHUsPQWv5 folder=false
  siteParse: 列表条目缺少 vod_id/vod_name | detail=Hxq | action=detail
  GET http://127.0.0.1:19978/vod/api?... form=no queryKeys=[ac, configKey, ids, key]
```

同一条重试 3 次全失败；同一站点的**首页与搜索都正常**（`首页加载成功 site=Hxq class=3 list=27`）。
也就是说：不是网络、不是网关、不是站点整体不可用，**只有详情这一条响应被判无效**。

---

## 2. 根因（实测，两条证据闭合）

### 2.1 现场抓包：上游详情条目本身缺 id/name

直接打网关（`adb forward tcp:19978 tcp:9978` 之后）：

```text
GET /vod/api?ac=detail&ids=Bkp_OaNRYo16PHUsPQWv5&key=Hxq&configKey=425e3994-…
→ HTTP 200，3490 字节
```

`list[0]` 的取值：

| 字段 | 值 |
| --- | --- |
| `vod_id` / `vod_name` / `vod_pic` | **空串** |
| `vod_remarks` | `更新至第8集·共12集` |
| `vod_actor` / `vod_content` | 齐全 |
| `vod_play_from` | `免费分享` |
| `vod_play_url` | 3003 字（`1$<base64>#2$<base64>…`） |

同站点搜索响应里 `vod_id`/`vod_name` 是**正常**的。所以缺身份只发生在 detail 分支。

### 2.2 上游定义：Hxq 是 T3 spider，网关把它外化成 T4

上游配置源（`https://9763.kstore.vip/aowu.json`）里：

```json
{"name":"🚀韩剧┃秒播","key":"Hxq","type":3,"api":"csp_HxqAmns","searchable":1}
```

`type=3` 是**爬虫**，它的详情由 `spider.detailContent(ids)` 返回，
上游那个 `Vod` 对象没有写 `vod_id`/`vod_name`（`Vod.java` 的两个字段都是 `@SerializedName`，缺就是 `null`）。
安卓网关的 `vodJson()` 用 `prop(item, "vod_id", vod.getId())` 逐字段写 JSON，`null` → 空串，
于是 T4 形态的响应里 `vod_id: ""`、`vod_name: ""`。

### 2.3 PC 侧：一条不合法 → 整个列表判失败

`Vod.fromJson` 要求 `vod_id` 与 `vod_name` **都非空**，否则返回 `null`：

```dart
final id = asNonEmptyString(map['vod_id']) ?? asNonEmptyString(map['vodId']);
final name = asNonEmptyString(map['vod_name']) ?? asNonEmptyString(map['vodName']);
if (id == null || name == null) return null;
```

`_parseVodList` 把 `null` 的条目 `continue` 掉，随后发现「非空数组但一条都没解析出来」，抛
`AppError(AppErrorKind.siteParse, '列表条目缺少 vod_id/vod_name')`。
**列表/分类场景这条守卫是对的**（响应里每条都该有身份），但**详情只有一条**、而这条的身份
恰恰就在请求参数 `ids=` 里——信息不缺，只是没被用上。

---

## 3. 取舍

| 备选 | 做法 | 结论 |
| --- | --- | --- |
| A | 改安卓 `formatContent`，用请求 `ids` 回填 `vod_id` | 能修，但**要动上游工程**；且 `vod_name` 仍空，同样得猜 |
| **B** | PC 解析层用**请求上下文**兜底 | **采纳**。改动全在 PC，且信息本来就是请求方提供的，不引入猜测 |
| C | 详情失败时用「搜索片名」再找一次 | 否决：多一跳网络、可能匹配到别的剧，等于把「解析问题」变成「匹配问题」 |
| D | 放宽 `Vod.fromJson`，允许空 id/name | 否决：空 `vod_id` 会让「归属校验」（`result.list.first.vodId == widget.vod.vodId`）与历史写入全部失真 |

B 的关键是**只在安全的时候回填**，见 §4.2。

---

## 4. 实现：`VodIdentityHint` 沿调用链穿透

### 4.1 数据载体（`lib/core/protocol.dart`）

```dart
class VodIdentityHint {
  const VodIdentityHint({required this.vodId, this.vodName = ''});
  final String vodId;
  final String vodName;
  bool get isEmpty => vodId.trim().isEmpty && vodName.trim().isEmpty;
}
```

顶层纯函数 `withVodIdentity(Object? value, VodIdentityHint hint)`：返回**新 Map**（不改入参），
只在对应字段为空时写入 `hint` 的值——**已填的值永不覆盖**。

### 4.2 触发条件：详情 + 恰好一条

`_parseVodList` 与 `_parseXml` 各自计算：

```dart
final hint = identity != null && !identity.isEmpty && items.length == 1 ? identity : null;
```

两个条件缺一不可：

- `identity != null` —— 只有 `detail` 调用点会传；列表/分类/搜索一律传 `null`，所以**不可能**把多条
  写成同一个 `vod_id`。
- `items.length == 1` —— 即便将来有人误传，一条响应里有多条也不会被批量回填。

### 4.3 穿透链

```text
SiteService.detail(site, vodId, identity:)
  ├─ HttpApiRuntime.detail  → HttpApiClient.execute(call, identity:)
  │                             → HttpApiResponseParser.parse(identity:)
  ├─ SidecarRuntime.detail  → _invoke → _toSiteResult → parse(identity:)
  └─ CatHttpSiteRuntime.detail → CatHttpClient.call → decode → _toResult → parse(identity:)
                                  └─ _parseJsonObject / _parseJsonList / _parseXml → _parseVodList
```

`identity` 全程是**可选**命名参数，`SiteRuntime` 接口的 4 个实现签名统一为
`detail(Site site, String vodId, {VodIdentityHint? identity})`。

### 4.4 四个调用点（`lib` 下仅这 4 处）

| 调用点 | 传什么 | 为什么 |
| --- | --- | --- |
| `AppState.loadDetail` | `vod.vodId` / `vod.vodName` | 详情页主路径，用户点的就是这个条目 |
| `AppState._resolveFollowingLines` | `Following.vodId` / `vodName` | 追番续播同样拿详情 |
| `library_pages.dart`（历史补海报） | 历史行的 id/name | 只补图，但也有同样风险 |
| `history_cross_source.dart`（候选探测） | 候选的 id/name | 探测失败会退回 `hasTargetEpisode: false`，宁可让用户手选 |

`SiteService.folderDetail` 内部**不传**：网盘聚合的条目是自造的，id/name 来自 parent。

---

## 5. 边界：本轮**不**做什么

| 不做 | 理由 |
| --- | --- |
| 给列表/分类/搜索也回填身份 | 那是**推断**而不是**已知**；多条写成同一 id 会让整页崩掉（§4.2 的第二个守卫正是防这个） |
| 为 `vod_name` 空的情况去猜片名 | 详情请求没有片名参数，猜只能来自 TMDB 或搜索，两者都会引入错配 |
| 改安卓 `formatContent` | 方案 B 已足够；安卓端是运行容器，改它还得再走一次发版 |
| 放宽 `Vod.fromJson` | 破坏归属校验与历史写入（§3 方案 D） |

---

## 6. 验收

### 6.1 新增用例

| 位置 | 覆盖 |
| --- | --- |
| `test/core_protocol_test.dart` 新 group「详情身份兜底（VodIdentityHint）」7 例 | 详情一条且 id/name 空 → 回填且 `vod_remarks`/`vod_play_from`/`vod_play_url` 保留；已填值不被覆盖；只缺一个字段只补那个；条目数 >1 时报 `siteParse`；不带 identity 行为与改造前一致；`{code:0,data:{list}}` 信封内单条也回填；XML 路径也回填 |
| `test/support/test_fixture_server.dart` | 新增 `ids=blank-1` 路由，复刻真机响应形态（空 id/name + 齐全的其余字段） |
| `test/config_and_site_test.dart`「站点服务闭环」追加 1 例 | **Hxq 回归锁**：不带 identity → `siteParse`；带 `VodIdentityHint` → id/name/remarks 正确且 `SiteService.playLinesOf` 非空 |

### 6.2 回归

| 项 | 结果 |
| --- | --- |
| `flutter analyze lib test integration_test` | `No issues found!` |
| 全量单测（151 文件，3 批 × `-j 4`） | `1218 + 1054 + 684` 全绿 |

### 6.3 反向验证（防回归靶子）

| 靶子（改坏哪里） | 实际失败的断言 |
| --- | --- |
| `_parseVodList` 的 `withVodIdentity(item, hint)` 改回 `item` | `core_protocol_test` `+74 -3`（信封内单条 / 只缺一个字段 / 基础回填三条同时失败） |
| 去掉 `items.length == 1` 守卫 | `+76 -1`（「条目数 >1 时不回填」失败） |
| `HttpApiRuntime.detail` 不把 identity 传给 `execute` | `config_and_site_test` `+40 -1`（Hxq 回归锁失败） |
| `AppState.loadDetail` 不传 identity | **只验证了 `analyze` 仍 exit 0** |

第 4 条是这一轮最值钱的教训：`identity` 是**可选**参数，漏传在编译期**完全无声**。
因此这一层不能只靠类型系统，必须靠「调用点 grep + 端到端断言」两道锁
（§4.4 的表格就是 grep 结果，§6.1 的回归锁就是端到端）。

---

## 7. 已知限制

| 限制 | 影响 | 后续 |
| --- | --- | --- |
| 只补 `vod_id`/`vod_name`，不补 `vod_pic` | Hxq 这类站点详情页无海报（列表页的图仍在） | 若要补，得先确认「用搜索结果的图」不会错配 |
| 兜底依赖调用方传对 `vodName` | 传错片名会写进一条错误的名字（id 是对的，仍能播放） | 调用方都是「用户点的那个条目」，风险低 |
| 只在 T4/HTTP 解析层生效 | sidecar 与猫源走同一条 `parse`，因此同样受益；但**纯本地爬虫**若返回空身份仍报错 | 无（同样的兜底已覆盖） |
