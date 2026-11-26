# BilibiliSponsorBlock 对 WebHTV PC 跳过片段功能的价值评估

调研日期：**2026-11-26（UTC）**。范围：第一方 README、客户端源码、API wiki、隐私政策与许可证。**没有实现接入，没有调用业务 API，没有提交、投票或发送用户视频/凭据。**

## TL;DR

- **值得借鉴设计，不建议为普通影视立即新增数据源。** 它是 B 站众包片段工具，不是 AI 自动识别模型。README 明说标注来自网友；自动化的是获取标注并执行动作，而非自动分析视频生成标注。[S1]
- **直接数据价值的前提是可靠 BVID + 当前 CID。** av/aid 是解析入口，分 P 的 p 要先解析成 CID；TMDB/IMDb/季集号不是其查询键。PC 当前 SkipQuery 没有这些字段，不能简单注册第四个 provider 就解决。[S3][S4][S5][W]
- **不适合取代 TODB / IntroDB / TheIntroDB。** 当前 API 面向具体 B 站视频及分 P；README 的 YouTube 搬运绑定也不是 TMDB/IMDb 对照表。没有证据证明其覆盖 WebHTV 的非 B 站影视，不能把同名 B 站上传版的时间戳套给本地影视版。[S1][W]
- **优先级：稳定的分类色覆盖层 → 处理/撤销状态分离 → 有 B 站身份后再评估只读适配。** 覆盖层颜色没有“已播比例”输入，对当前双色问题有设计启发；但它不是现成 Flutter 控件，本次也不改 UI。[S7][S8]

## 1. 版本与证据边界

| 项目 | 核实结果 |
| --- | --- |
| 官方仓库 | hanydd/BilibiliSponsorBlock（小电视空降助手） |
| 当前默认分支 | GitHub 仓库页内嵌元数据：master |
| 固定源码版本 | [c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa](https://github.com/hanydd/BilibiliSponsorBlock/commit/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa) |
| 提交时间/标题 | committedDate = 2026-11-23T21:31:42+08:00（13:31:42 UTC）；feat: add contribution calendar and impact dashboard |
| 取证时间 | 仓库页 HTTP Date：Thu, 26 Nov 2026 01:03:28 GMT；后续同日完成 |
| README | 读取 HEAD/README.md，仓库页固定 OID 的 README 渲染核对关键结论；引用固定到该提交 |
| API wiki | 官方 raw API.md 返回 HTTP 200；**独立可变 wiki，未取得 revision hash**，不属于上述客户端 commit |
| 外部读取 | 30 次：28 次 HTTP 200、GitHub REST 元数据一次 403 rate limit、src/content/cidReplacement.ts 一次超时；未超额重试 |

REST 403 后通过官方仓库页/commit 页内嵌 JSON 核实分支与提交，不用搜索摘要猜版本。仅小范围读取文本/目录页，没有 clone、安装依赖、运行第三方代码、下载数据库或启动服务。**没有实测线上业务 API 的响应、限流、覆盖率或 SLA；源码只证明客户端行为/意图。**

## 2. 已核实身份、API、分类与动作

### 2.1 身份粒度

- 页面/播放器 manifest 提供 bvid 或 aid；无 bvid 时转换 aid。/video/av… 也先解析成 BVID，片段 API 不是直接接收 av/aid。[S3]
- 内部 NewVideoID 组合为 **BVID + “+” + CID**。URL 的 ?p=N 先通过 BVID + page 取得 CID；**p 不是 CID，也不是片段主键**。[S3]
- 后台对 BVID 做 hash-prefix lookup 并匹配返回的 videoID；content 层再按 segment.cid === 当前 cid 筛选。只匹配 BV 就会混入其他分 P 的标注。[S4][S5]
- 解析器支持部分番剧等页面，不代表它接受任意 TMDB/IMDb 影视身份；最终仍需 BVID/CID。[S3][W]

### 2.2 API wiki 与当前源码对照

| 项目 | Wiki 契约 | 当前源码与限制 |
| --- | --- | --- |
| 基地址 | 正式 https://bsbsb.top/api/**；测试 https://bsbsb.top/test/api/**，数据分开 | 配置示例默认 https://bsbsb.top，不是 YouTube SponsorBlock 服务。[S2][W] |
| 明文查询 | GET /api/skipSegments?videoID=BVID，可选 cid；缺 cid 返回所有 CID | 本次未发该请求；不能把 TMDB/IMDb 填进 videoID。[W] |
| 哈希查询 | GET /api/skipSegments/:sha256HashPrefix，建议 BVID SHA-256 前 4 字符 | 后台 getVideoIDHash(bvId).slice(0,4)；不带分类/action 参数，回包后本地筛 BVID、启用分类/动作。[S4][W] |
| 返回 | 哈希查询返回视频数组：videoID + segments；段含 segment:[start,end]（秒）、cid、UUID、category、actionType、locked、votes、videoDuration | 不应把顶层视频数组当片段数组；秒数按数值处理，不只收整数；当前后台按段起点排序。[S4][S5][W] |
| 状态/缓存 | 无数据 404；400 参数错误；写入还有 403/409/429 等；x-skip-cache:1 强刷 | 后台只缓存 200/404；网络错误不等于确定无数据，不应每次播放强刷。[S4][W] |
| 来源标识 | 文档要求 origin 与 x-ext-version | 原生 Flutter 接入前应核实合法客户端标识/频率，不能冒用扩展 Origin；本次未审计代理层实际 headers。[W] |
| 参考时长 | videoDuration 单位秒，0 未知；要求误差 ±2 秒，用于换源/过期判断 | 提交发送 video.duration；已读普通查询/发布路径**没有证明每段执行 ±2 秒拒绝**。文档要求不等于线上/客户端已验证保证。[S4][S5][W] |

**版本差异：** wiki 统计示例仍列 chapter action/category，当前配置的 categoryList 与动作支持表不含 chapter；部分文字还残留 YouTube 用语。不能照旧 wiki 的所有枚举直接扩展 PC。接入需固定契约、以离线 fixture 验证，再核实线上响应。[S2][W]

### 2.3 分类不等于动作

当前配置共 **12 类**：sponsor、selfpromo、exclusive_access、interaction、poi_highlight、intro、outro、preview、padding、filler、jumpscare、music_offtopic。[S2]

| actionType | 已核实意义 | 对 PC 的边界 |
| --- | --- | --- |
| skip | 有界片段跳到段末，可自动或手动 | 才可能转换为可跳过 RawSkipSegment |
| mute | 静音片段；例如 jumpscare 只支持 mute | 不能当 skip，否则删掉画面 |
| full | 整条视频的标签；exclusive_access 只支持 full | 不能当片尾或整片跳过 |
| poi | 高光位置导航；poi_highlight 只支持 poi | 不是应删除的内容，不自动跳过 |

处理方式有 Disabled / ShowOverlay / ManualSkip / AutoSkip；当前默认 intro/outro 为手动、preview 仅标记，并非默认自动跳过所有片头片尾。[S2][S6][S9]

**保守映射建议（未实施）：** 首轮只评估 actionType=skip 且 sponsor → advertisement、intro → intro、outro → outro，仍需场景语义和时轴校验。preview 指南名是 Preview Recap Hook，不能未经核对就等同 PC 的“下集预告”或“前情回顾”。其他类别保持 unsupported，不把 selfpromo/filler/padding 强塞进七类，不为尚无对应数据的分类增加设置。[S2]

## 3. 跳过、去重、撤销与错误段安全策略

当前默认 skipEngineMode 为 legacy，同时存在另一规则引擎路径；下述具体机制来自默认调度器，**未验证两条引擎完全等价**。[S9]

1. **调度代际与身份复核：** scheduleGeneration 使旧异步调用失效；incorrectVideoCheck 执行前重新检查视频身份与片段。与 PC media key + lookup epoch 同方向，不必搬浏览器调度循环。[S6]
2. **三种去重分开：** 自动 skip 可把相交/相邻的可自动段合并到更远末端；executedSkipRanges 合并已执行范围以抑制重复提示；统计/上报另用稳定 UUID 集合，不用会变化的数组 index。主动 seek 会清理本轮执行范围，UUID 统计仍独立去重。[S6]
3. **撤销/再跳：** unskip 回到保存位置或段起点附近，mute 可恢复；reskip 再跳至末端。它不是对已发送服务器副作用提供事务式撤销。[S6]
4. **刷新保留用户排除：** 按 UUID 继承 hidden/category、本地踩过/隐藏状态后再发布新段，防止刷新重新激活被排除内容。[S5]

PC 已有 SkipSegment.identity + handled，并刻意规定“一段每集只自动处理一次，手动拖回不再次跳走”（skip_plan.dart:237、394）。这与上游主动 seek 后允许重新处理的细节不同，**不能直接替换语义**。若以后做撤销，应明确“撤销后不立即再自动跳、仍可手动再跳”，将“已提示”“已跳过”“统计已上报”分开。

### 社区纠错与安全边界

- 提交 POST /api/skipSegments 需要 BVID、CID、私人 userID、参考时长、客户端版本与片段。源码一致，且要求部分场景先预览、裁剪提交末端到视频时长、对短段询问确认。[S5][W]
- 投票 POST /api/voteOnSponsorTime：0 踩 / 1 赞 / 20 撤销投票，也可改类别；私人 userID 用于鉴权。**撤销投票不是撤销播放跳过**。[S5][W]
- Wiki 明确警告 searchSegments 未做最佳片段匹配/过滤，不应用来播放跳过；使用 skipSegments。votes/locked 不等于准确性保证，votes 也不是 PC 的 submissionCount 或置信度。[W]
- 已核实精确 BVID/CID 筛选、异步身份复核、用户排除保留；渲染层还拒绝非有限数、倒序、无效时长并裁剪越界。**渲染校验不等于执行器已安全处理全部坏数据。**[S4][S5][S6][S7]
- ±2 秒是 wiki 要求；换 CID 有专门迁移路径，但其 content 判定文件本次超时，服务端实现未审。**没有证据保证换源/剪辑变化自动正确修复。** WebHTV 若接入应自己拒绝身份/时长不匹配，而非套同名视频时间戳或盲目缩放。

## 4. 时间轴绘制对“已播片头双色”的启发

SegmentOverlayRenderer 添加独立 ul.sbSegmentOverlay，每段为绝对定位 li；按 start/duration、end/duration 定左右边界，分类 CSS 变量设背景色，配置控制 opacity；颜色计算**没有 currentTime / played 输入**。[S7]

- CSS 覆盖层 position:absolute、width/height:100%、z-index:1、pointer-events:none，保留原生 seek/预览事件。
- mini/PiP 以 inset:0 固定；CSS 特别注明 mini 的原生 played/buffered 层不应盖住分类色；选中段 opacity:1 !important、z-index:100、scaleY(1.5)。[S8]
- renderer 提供裁剪/长度降序函数；若调用方按其结果绘制且没有其他堆叠规则，后画的短段更显眼。这是**长度/选中态的视觉层次**，不是“广告永远高于片头”等业务优先级。[S7]
- 普通 opacity 可以小于 1，底层仍可能改变实际观感；**不能据源码保证所有播放器/主题都绝无双色/混色**。本次没有运行扩展或截图验证。[S7][S8]

**PC 可借鉴而无需接 API：** 分类色单独稳定成层，不因播放头经过切成两种分类色；要同色须保证最终合成层的已播/未播走同一颜色规则，不能只改 RGB。保留 seek 命中/播放头，重叠顺序用 PC 自己明确的规则。验证半播/播完、暂停、拖回、相邻/重叠段、亮暗主题。**这是 UI 任务的建议，不是本调研的代码变更或 UI 验收结果。**

## 5. 服务器、隐私、自托管与许可证

### 5.1 哈希前缀不等于匿名

配置示例默认 https://bsbsb.top；镜像包括 https://bsbsb.cc 和一个 **HTTP** 地址，运行配置另有跟随官方服务器列表偏好。发行构建/用户设置可能不同；本次未审完整路由/切换/动态列表。[S2][S9]

- GET 只发 BVID hash 前 4 字符，在本地精确筛视频，比直传 BV 暴露粒度小；但服务器仍看到网络请求，前缀不等于不可关联/不可枚举的匿名化承诺。[S4][W]
- 默认 trackViewCount=true、trackViewCountInPrivate=true；完整跳过按 UUID 调 POST /api/viewedVideoSponsorTime，并独立去重。**不能把“GET 不带私人 ID”说成“不上报观看行为”。**[S6][S9]
- 提交/投票传私人 userID（不是 B 站 cookie）。Wiki 将其比作密码，公开 ID 为多次 SHA-256 的结果；私人 ID 不应公开。只读片段查询在文档及已读后台调用没有 userID 参数。[S4][S5][W]
- [仓库隐私政策:66–103](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/PrivacyPolicy.html#L66-L103) 写可能收集 User ID、Usage Data、IP、浏览器/诊断信息等，但仍引用旧 IP 站点且定义 Service 为 Website，不能据此证明所有扩展/API/镜像的实际日志/保留期。

未来建议 **默认关闭/显式 opt-in、只读 GET、仅 HTTPS，不自动沿用 HTTP 镜像，不带 cookie/私人 ID，不做 viewed/投票/提交 POST**；先向维护者确认原生客户端 headers/使用条件。这是 WebHTV 的建议，不是对上游全部实现的指控。

### 5.2 自托管与覆盖范围

README 给出 database.zip 下载链接；配置可修改服务器地址。可证明“数据可下载、客户端可改端点”，**不能证明本仓库提供开箱即用服务端部署，更不能证明数据能匹配非 B 站影视**。[S1][S2][S9]

未下载 dump、未核 schema/独立数据许可、未审服务端、未验证自托管。即使导入，仍需媒体身份、精确版本与时轴；换服务器 URL 不会产生 TMDB/IMDb 映射或新覆盖率。普通影视适配会成为另一个数据采集/治理项目，不是直接用这个客户端就完成。

### 5.3 GPL：设计参考与实现复用分开

README 声明 GNU GPL v3；LICENSE 是 GPL version 3（2007-06-29）。原文第 4–6 节涉及保留版权/许可/免责声明、修改标记/日期、适用作品整体许可、目标码分发时提供 Corresponding Source 等条件。[S1][S10]

- 阅读设计后独立实现，与直接复制/翻译 TypeScript、CSS、资源是不同工程选择；后者先做版权、依赖、来源与分发兼容审查，不能当 MIT/BSD 代码随取随用。
- 不作“HTTP 调 API 就绝对无 GPL 义务”或“WebHTV 全部必然变 GPL”的法律保证；实际影响取决于复用/组合/分发方式，交项目负责人及必要专业审查。
- 仓库树还列 LICENSE-APPSTORE.txt，本次未审其范围，不据此推导 WebHTV 获例外；**数据/API 使用授权、dump 许可也不能仅凭客户端 GPL 推定**。

## 6. 与 WebHTV PC 架构对照

本地依据：[intro-skip-data-sources.md](intro-skip-data-sources.md)；以下路径均从仓库根开始：apps/desktop-flutter/lib/core/skip_plan.dart:48、183、219、327、349、394、444、620；apps/desktop-flutter/lib/services/intro_skip/provider.dart:1、registry.dart:18。播放页的 lookup epoch/media identity 核对见 apps/desktop-flutter/lib/ui/player_page.dart:1279–1292（研究时工作区行号，UI 正在变动）。

| 维度 | PC 现状 | 上游价值 / 不兼容点 |
| --- | --- | --- |
| 身份 | SkipQuery 仅 TMDB/IMDb、媒体类型、季集、时长；缓存键不含时长 | 需 BVID + CID 命名空间，不可冒充 TMDB ID |
| provider/计划 | provider 只产 RawSkipSegment；registry 并发/三态/缓存；SkipPlan 折算、去重、手动覆盖 | 可考虑专用只读源，不替代三源，不让 provider 直接 seek |
| 分类 | 回顾/片头/片尾/预告/彩蛋/广告/休息七类 | 十二类不一一对应，只取约定的 skip，其余 unsupported |
| 动作/设置 | auto / off / confirm、七类开关和 RGB | 上游另有仅标记/手动/自动及 mute/full/poi，无需为追平它重构模型 |
| 时轴 | 开头/片中绝对时间，尾部可按参考时长距结尾平移 | B 站绑定具体上传版；先校验版本/时长，不能自动继承尾部平移假设 |
| 状态 | identity、handled、media key + epoch | UUID/代际/执行范围/统计分离可作清单；保留 PC 已有安全语义 |
| 用户控制 | 手动覆盖、已处理段不再次自动跳 | 隐藏随刷新保留、撤销/再跳可作后续交互参考 |
| UI | Flutter 原生时间轴、七类自定义色 | 参考独立覆盖层/稳定分类色，不移植 DOM/CSS |

## 7. 可执行建议与接入最小前提

| 优先级 | 建议 | 完成标准 / 启动条件 |
| --- | --- | --- |
| **P0：现在有价值** | 分类色稳定、已播层不染色、装饰不抢 seek、重叠顺序确定 | 不引网络依赖；UI 任务验证半播/播完/拖回/重叠/主题，本调研不改 UI |
| **P1：后续独立任务** | 评估“已跳过 → 撤销/再跳”、刷新保留用户排除 | 先定交互；media key + epoch + 稳定 ID；撤销后不立即重跳；不强带社区账号 |
| **P2：有条件 PoC** | 仅真实 B 站播放的只读片段 adapter | 满足下列六项；不改变影视三源默认行为 |
| **暂不做** | 替换影视库、加全十二类、接 mute/full/poi、自动写入/上报、自建全站数据库 | 身份/语义/授权/维护收益不明确，当前不扩大范围 |

**未来只读 B 站适配的六项门槛（尚未实施）：**

1. **身份可证明：** 播放请求可靠提供 platform=bilibili、BVID、当前 CID；av/aid/p 已规范化，分 P/换源更新 key。没有身份就不查询，不凭片名/TMDB 猜 BV。
2. **时轴可证明：** 当前分 P 时长稳定；秒→毫秒、有限数/顺序/边界均校验。参考时长未知或超出建议 ±2 秒阈值时先不自动跳；时长相同也不单独证明同版本；换 CID 不擅迁移。
3. **先批准模型 seam：** 明确平台身份 query/cache/media-key 扩展；B 站版本绑定绝对时间不得被尾部平移误处理。保持 provider → RawSkipSegment → SkipPlan → 播放决策分工。
4. **范围保守：** 只支持约定 skip 分类；provider + UUID 稳定 ID，CID/版本隔离与手动覆盖保留；未知分类/动作拒收，不猜测。先标记或 confirm 试用；votes 不直接换算置信度。
5. **服务/隐私明确：** 核实原生客户端标识、限流/缓存、API/数据授权与 HTTPS 端点；用户 opt-in；无默认私人 ID/cookie/观看上报/写操作。
6. **先离线契约测试：** 自建 fixture 覆盖同 prefix 多 BV、同 BV 多 CID、404/超时/坏 JSON、未知 action、倒序/越界/非有限值、时长错配、换身份迟到响应、刷新/撤销不重跳。之后仅以公开测试视频核实线上契约与命中率，不承诺覆盖率。

**未知与结论触发条件：** 线上服务版本、实际 headers/限流/SLA、时长过滤保证、CID 迁移 content 判定、规则引擎等价性/完整路由均未完整验证；片库命中率、dump 格式/许可、自托管可复现路径未知。若已有可靠 BVID/CID 源且用户确需 B 站广告片段，P2 收益会上升；若仍主要按 TMDB/IMDb 播影视，维持“借鉴设计，不立即接入”。

## 8. 第一方关键引用索引

下列 **10 项关键源码/仓库文件**固定到同一提交；同文件多个锚点避免泛指全仓。另列可变 wiki 与前文隐私文档。

- **[S1]** [README:30–38 众包/功能](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/README.md#L30-L38)、[120–144 搬运绑定/数据/API](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/README.md#L120-L144)、[156–158 GPL 声明](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/README.md#L156-L158)。
- **[S2]** [config.json.example:2–35 服务器/分类/动作/指南](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/config.json.example#L2-L35)。
- **[S3]** [parseVideoID.ts:98–162 aid/BV、分 P→CID、组合身份](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/utils/parseVideoID.ts#L98-L162)。
- **[S4]** [segmentRequest.ts:21–79 哈希查询/缓存/本地筛选](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/requests/background/segmentRequest.ts#L21-L79)。
- **[S5]** [segmentSubmission.ts:480–538 CID/UUID/刷新](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/content/segmentSubmission.ts#L480-L538)、[738–789 投票/隐藏](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/content/segmentSubmission.ts#L738-L789)、[868–930 提交校验/时长/私人 ID](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/content/segmentSubmission.ts#L868-L930)。
- **[S6]** [skipScheduler.ts:64–111 代际/执行范围](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/content/skipScheduler.ts#L64-L111)、[798–828 身份复核](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/content/skipScheduler.ts#L798-L828)、[933–959 自动段末端合并](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/content/skipScheduler.ts#L933-L959)、[1028–1078 UUID/上报](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/content/skipScheduler.ts#L1028-L1078)、[1221–1397 执行/撤销/再跳](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/content/skipScheduler.ts#L1221-L1397)。
- **[S7]** [SegmentOverlayRenderer.ts:15–75 裁剪/排序/分类色覆盖层](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/player/SegmentOverlayRenderer.ts#L15-L75)。
- **[S8]** [content.css:43–80 原生层/mini/选中态优先级](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/public/content.css#L43-L80)。
- **[S9]** [config.ts:417–454 默认引擎/隐私/服务器](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/config.ts#L417-L454)、[521–567 分类默认处理](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/src/config.ts#L521-L567)。
- **[S10]** [LICENSE:195–286 GPLv3 第 4–6 节原文](https://github.com/hanydd/BilibiliSponsorBlock/blob/c5e0bd8d1f7cf9ce0805b0af9cedbd0f967e71aa/LICENSE#L195-L286)。
- **[W]** [官方 API wiki](https://github.com/hanydd/BilibiliSponsorBlock/wiki/API) / [实际读取的 raw](https://raw.githubusercontent.com/wiki/hanydd/BilibiliSponsorBlock/API.md)：地址/headers/缓存、片段查询/提交/投票/观看上报、搜索警告、搬运绑定。读取 2026-11-26，未固定 wiki revision。

**交付状态：研究完成，未接入；未改生产代码、测试、配置或用户数据，未替代进行中的 UI 验收。**
