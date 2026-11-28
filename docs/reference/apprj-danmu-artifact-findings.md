# AppRJ 工件：`proxy(Map)` 弹幕契约

**结论：此版本明确支持 `do=danmu`。** 站源可将缺参或上游失败转换为 HTTP 200 和 45 字节的空 XML；这个响应不能用来判定弹幕能力不受支持。

## 工件与取证范围

目标：`%APPDATA%/webhtv-pc/spiders/csp/src~50615206394da70ec3db3a74ca7681ca17caa4eee231edf0dda84a3fa1ce9047/`。

| 文件 | SHA-256 | 证据 |
| --- | --- | --- |
| `index.jar` | `ecd497ec1f3314b2bd9267ce74d1c3ca8eadde971d67fe69648d3b85868f9418` | ZIP 包含 `classes.dex` |
| `dexBundles/classes.jar` | `6361e95b489f29fe813faf13ec91a85458b3cede9786c6a99196f180d6fd522b` | 实际 JVM 类所在工件；下文偏移均为此文件的 JVM 方法内字节码偏移 |

REA 工具未挂载；按 recovery 指南，改用现有 JDK 21.0.12 的 `javap -classpath <classes.jar> -c -p <class>`。离线读取 `AppRJ`、`DanmuApi` 的 `<clinit>` @0–5 字符串表：`decode_S` @10–19 按 little-endian 读取 short，解码工具方法 @23–27 执行 `(char)(table[start+i] ^ key)`；只解码相关调用，不加载或运行站源类。未调用上游、未读取账户数据。下文省略 `com.github.catvod.` 公共类名前缀。

## 分派与参数

- `spider.AppRJ.proxy(Map)`：@0–1 检查 map 非空引用；@15 解码 `(696,2,1395)` → `do`，@18 取 `Map.get`；@32 解码 `(698,5,2963)` → `danmu`，@36 通过 `api.Ooo0OOO.00o00OO`（@11 `String.equals`）精确、区分大小写地比较；匹配则 @43 调 `spider.00OoOoO.0Ooo0O0`（@10 转调 `api.DanmuApi.proxy(Map)`）。null map 或未匹配从 @49 返回 null，不是空 XML。原 `apprj.txt:2205–2245` 的分派与该工件重跑一致。
- `DanmuApi.proxy` 读取 `url`（@11 解码、@14 读 map）、`name`（@33/@36）、`episode`（@56/@59）、`season`（@79/@82）。`DanmuApi.genUrl` @61、@129、@159、@184 独立佐证两种 query：`?do=danmu&url=<encoded-url>` 或 `?do=danmu&name=<encoded-name>&episode=<int>&season=<int>`。
- **URL 优先**（`proxy` @89–122）：非空且符合“官方 URL”判定便直接抓取；失败不会继续按名称查找，即使 `name` 有值。不满足判定才到按名称分支。判定是 `spider.merge.o0OO0O0.oOoOOO0.o0ooOoO(String)` @0–75 的站点字符串列表和 @104 的 `String.contains`，不是 URI host 校验。例如列表包括 `iqiyi.com`、`v.qq.com`、`youku.com`、`mgtv.com`、`bilibili.com`。
- **名称查询**（`proxy` @125–299）：要求 `name` 非 null 且非空串（`api.O0000Oo.OOo00OO` @10 调 `TextUtils.isEmpty`）；`episode`/`season` 用 `Integer.parseInt`（`spider.o00o00O.oOooooo` @10），缺省或解析异常均回退为 1（`proxy` @135–153、@309–319）。两路搜索都接收 `name`、`episode`，等待最多 4500 ms（@191–254；该时限只覆盖这一段等待），从共享引用取搜索结果；有 URL 则先抓弹幕（@255–282）。没有 URL 或抓取返回 null，则尝试 `name`/`episode`/`season` 匹配（@285–299）。

## 上游依赖

以下均为程序内置字面量／调用路径，并非对服务在线或成功的验证。弹幕服务路径前缀的一个固定段已脱敏。

| 阶段 | 工件证据 |
| --- | --- |
| 按名称查 URL：360 影视 | `DanmuApi$1.run` @8 → `spider.o00o00O.OoO00OO` @11 → `DanmuApi.OO000oo` @2 → `0o0oooo` @11 → `getUrlFrom360`。后者 @185、@213 解码 `https://api.so.360kan.com/index?force_v=1&kw=<name>&from=&pageno=1&v_ap=1&tab=all`。 |
| 按名称查 URL：金蝉采集 | `DanmuApi$2.run` @8 → `spider.oooo0oO.oOO00oO` @11 → `DanmuApi.oOoO0o0` @2 → `o00oooo` @11 → `getDanmuFromJinchan`。后者 @28 解码 `https://zy.jinchancaiji.com/api.php/provide/vod/?ac=detail&wd=<name>`，@248、@281 解码结果的 `vod_name`、`vod_play_url`。 |
| 标题/季/集匹配 | `DanmuApi.fetchByMatchStrategy` @91–122 先检查 ID 缓存，有 ID 就尝试抓取；抓不到才继续。@146 解码 `https://logo.saodu.work:8888/[REDACTED]/api/v2/match`，@331–402 构造 `fileName` JSON 并 POST（`o0oOOo0` @14）；@488–548 检查 `matches` 并从首项取 `episodeId`，@570 缓存、@576 按 ID 抓取。 |
| 抓弹幕 XML | `DanmuApi.fetchComment(String,boolean)` @38、@67 解码 URL 方式 `/api/v2/comment?url=<encoded-url>&format=xml`（官方 URL 先经 `cleanOfficialUrl`），@211、@236 解码 ID 方式 `/api/v2/comment/<episodeId>?format=xml`；两者同属上述弹幕服务。@79–106 通过 OkHttp 请求；@110–190 在响应成功且 body 存在时读取并处理弹幕颜色，返回 200、`text/xml; charset=utf-8` 和字节流；非成功、无 body 或捕获到异常返回 null（@114、@121、@251–259）。未见按弹幕条数判定成功的分支。 |

## 何时得到空 XML

`DanmuApi.proxy` 在下列路径调用 `o0000Oo`（其 @6 调 `emptyDanmu()`）：

1. 官方 URL 分支直接抓取返回 null（@108–122）。
2. 未走官方 URL 分支且 `name` 缺失/为空（@125–132 → @302）。
3. 名称两路搜索未能给出可返回的 XML，并且匹配链也未产出响应（@255–302）；匹配非成功状态（`fetchByMatchStrategy` @413–427）、没有可用 `episodeId` 或捕获到异常（@488–562、@588–596）、以及按 ID 抓取也失败（@574–580）均能落入该路径。等待超时本身不直接返回空 XML，仍可继续匹配。
4. `proxy` 内一般异常的处理器（@322–328 → @302）；解析季/集失败默认 1，等待被中断会继续读搜索结果（分别 @309–319、@331–333），不直接触发空 XML。

`emptyDanmu()` @0–61 固定返回 `[200, "application/xml; charset=utf-8", ByteArrayInputStream]`，@22 解码的正文是 `<?xml version="1.0" encoding="UTF-8"?><i></i>`（末尾无换行，UTF-8 45 字节）。@25 通过 `String.getBytes()` 取字节；对本次探针对应的环境，长度与实测一致。成功抓取也可能收到上游本身的无弹幕内容；单看正文不能区分两者，若保留原 MIME，`application/xml` 和 `text/xml` 可区分上述固定回退与抓取成功返回路径。

PC 的同参数探针得到 200、`application/xml; charset=utf-8`、45 字节空 XML；状态、MIME 与正文同时匹配该工件的固定回退，而非宿主伪造。JVM 侧 `CatVodSpiderAdapter.java:80–95` 可调用站源实例，`SpiderProxyHttpServer.java:248–250,323–363` 转发并解析其返回，在此路径不合成空 XML。仍不能区分此次是搜索未匹配、上游网络/响应失败还是其它异常。Android 的同参响应逐字节相同，但其全局分发的命中工件未核验，见 [实测对照](android-danmu-source-comparison.md#5-5554-与-pc-的实测对照)。
